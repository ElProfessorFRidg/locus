import CoreLocation
import Foundation
import MapKit

/// One routing result, kept with the numbers the driving model needs.
///
/// `expectedSpeed` is the only real signal Apple gives about how fast these
/// particular roads are — MapKit exposes no posted speed limits at all — so it
/// is carried through to `RouteSimulator` rather than thrown away with the rest
/// of the `MKRoute`.
struct BuiltRoute: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let coordinates: [CLLocationCoordinate2D]
    let distance: CLLocationDistance
    let expectedTravelTime: TimeInterval

    /// Timestamps from an imported GPX track, one per coordinate. Present only
    /// when the file recorded them — which is what makes replaying a real trip
    /// at the pace it was actually ridden possible.
    var recordedTimes: [Date]?

    /// Which road each stretch is on, from MapKit's own step instructions.
    ///
    /// This is the difference between guessing a limit from the shape of the
    /// tarmac and knowing you are on an autoroute. Empty for a drawn or
    /// imported path, which has no steps to read.
    var roads: [RoadSegment] = []

    init(
        name: String,
        coordinates: [CLLocationCoordinate2D],
        distance: CLLocationDistance,
        expectedTravelTime: TimeInterval,
        recordedTimes: [Date]? = nil,
        roads: [RoadSegment] = []
    ) {
        self.name = name
        self.coordinates = coordinates
        self.distance = distance
        self.expectedTravelTime = expectedTravelTime
        self.recordedTimes = recordedTimes
        self.roads = roads
    }

    /// Average speed Apple expects over this route, m/s.
    var expectedSpeed: CLLocationSpeed? {
        expectedTravelTime > 1 ? distance / expectedTravelTime : nil
    }

    /// Speed as a function of distance along the track, from the recorded
    /// timestamps.
    ///
    /// Returned as a closure rather than an array because the planner resamples
    /// to its own spacing: handing it a lookup by distance sidesteps having to
    /// keep two differently-sampled arrays in step, which is exactly the kind of
    /// off-by-one that produces a route that drives at the wrong speed in the
    /// wrong places.
    func recordedSpeedSampler() -> ((CLLocationDistance) -> CLLocationSpeed)? {
        guard let times = recordedTimes, times.count == coordinates.count, coordinates.count > 1 else {
            return nil
        }

        var marks: [(distance: CLLocationDistance, speed: CLLocationSpeed)] = []
        var travelled: CLLocationDistance = 0
        marks.reserveCapacity(coordinates.count)

        for index in 1..<coordinates.count {
            let segment = Geo.distance(coordinates[index - 1], coordinates[index])
            let seconds = times[index].timeIntervalSince(times[index - 1])
            travelled += segment
            // A GPS track can log two points with the same timestamp, or out of
            // order after a pause; either would divide by ~zero.
            let speed = seconds > 0.05 ? segment / seconds : 0
            marks.append((travelled, min(speed, 90)))
        }

        guard !marks.isEmpty else { return nil }

        return { distance in
            // Marks are sorted by distance; a binary search keeps this cheap
            // even on a track with tens of thousands of points.
            var low = 0
            var high = marks.count - 1
            while low < high {
                let mid = (low + high) / 2
                if marks[mid].distance < distance { low = mid + 1 } else { high = mid }
            }
            return marks[low].speed
        }
    }
}

/// Why one alternative is worth picking over the others.
///
/// Apple hands back two or three ways to the same place and the list showed
/// three near-identical rows of numbers. The fastest one was identifiable only
/// by being the one with no "+4 min" after it — a fact you had to work out from
/// an absence. And the shortest route is often a *different* row, which nothing
/// said at all.
enum RouteBadge: String, CaseIterable, Identifiable {
    case fastest
    case shortest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fastest: return "Fastest"
        case .shortest: return "Shortest"
        }
    }
}

enum RouteComparison {
    /// A route has to beat the field by this much to be worth calling out.
    /// Below it the rows are the same journey and a badge is decoration.
    static let meaningfulSeconds: TimeInterval = 30
    static let meaningfulMetres: CLLocationDistance = 100

    /// Which of these routes deserve a badge, keyed by route id.
    ///
    /// Nothing is badged when there is only one route, or when the winner isn't
    /// meaningfully ahead — a "Fastest" label on a route eight seconds quicker
    /// is a claim the numbers don't support.
    static func badges(for routes: [BuiltRoute]) -> [UUID: [RouteBadge]] {
        guard routes.count > 1 else { return [:] }
        var result: [UUID: [RouteBadge]] = [:]

        let timed = routes.filter { $0.expectedTravelTime > 1 }
        if timed.count > 1,
           let quickest = timed.min(by: { $0.expectedTravelTime < $1.expectedTravelTime }),
           let runnerUp = timed.filter({ $0.id != quickest.id })
               .min(by: { $0.expectedTravelTime < $1.expectedTravelTime }),
           runnerUp.expectedTravelTime - quickest.expectedTravelTime >= meaningfulSeconds {
            result[quickest.id, default: []].append(.fastest)
        }

        if let nearest = routes.min(by: { $0.distance < $1.distance }),
           let runnerUp = routes.filter({ $0.id != nearest.id })
               .min(by: { $0.distance < $1.distance }),
           runnerUp.distance - nearest.distance >= meaningfulMetres {
            result[nearest.id, default: []].append(.shortest)
        }

        return result
    }
}

enum RouteBuilderError: LocalizedError {
    case notEnoughStops
    case noRoute
    /// Apple could route the rest but not this one, numbered from 1 — which is
    /// the only part of a multi-stop failure anyone can act on.
    case legFailed(Int)

    var errorDescription: String? {
        switch self {
        case .notEnoughStops:
            return "A route needs a start and an end."
        case .noRoute:
            return "No route found between those points."
        case .legFailed(let leg):
            return "Couldn’t route leg \(leg). Move that stop nearer a road and try again."
        }
    }
}

enum RouteBuilder {
    /// Routes `start` → `end` on real roads/footpaths, newest result first.
    ///
    /// Returns every alternative Apple offers when `alternatives` is on, so the
    /// route sheet can let you take the scenic one instead of silently driving
    /// whichever came back first.
    static func roadRoutes(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        mode: TravelMode,
        alternatives: Bool = true
    ) async throws -> [BuiltRoute] {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end))
        request.transportType = mode.mkTransportType
        request.requestsAlternateRoutes = alternatives

        let response = try await MKDirections(request: request).calculate()
        guard !response.routes.isEmpty else {
            throw NSError(
                domain: "Locus",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No route found between those two points."]
            )
        }

        return response.routes.enumerated().map { index, route in
            BuiltRoute(
                name: route.name.isEmpty ? "Route \(index + 1)" : route.name,
                coordinates: sample(polyline: route.polyline, every: 12),
                distance: route.distance,
                expectedTravelTime: route.expectedTravelTime,
                roads: roadSegments(of: route)
            )
        }
    }

    /// Where each road starts and ends along the route.
    ///
    /// `MKRoute.Step` carries the instruction text and its own length, and the
    /// steps tile the route in order — so running the lengths up gives each
    /// named road a distance range without having to match polylines.
    ///
    /// A step whose instruction names no road ("Turn left") is skipped rather
    /// than guessed at: the estimator falls back to the road's shape there,
    /// which is what it always did.
    static func roadSegments(of route: MKRoute) -> [RoadSegment] {
        var travelled: CLLocationDistance = 0
        var segments: [RoadSegment] = []

        for step in route.steps {
            let end = travelled + step.distance
            if step.distance > 0, let roadClass = RoadClass.parse(step.instructions) {
                // Merged with the previous run when it is the same class, so a
                // motorway split across eight steps is one segment.
                if let last = segments.last, last.roadClass == roadClass,
                   abs(last.endDistance - travelled) < 1 {
                    segments[segments.count - 1] = RoadSegment(
                        startDistance: last.startDistance,
                        endDistance: end,
                        roadClass: roadClass
                    )
                } else {
                    segments.append(RoadSegment(
                        startDistance: travelled, endDistance: end, roadClass: roadClass
                    ))
                }
            }
            travelled = end
        }
        return segments
    }

    /// Routes through an ordered list of stops, one leg at a time.
    ///
    /// `MKDirections` only ever answers one origin and one destination, which is
    /// why Locus could only ever build A → B. A real commute has a school and a
    /// petrol station in it, and a lap round a park is three corners — so the
    /// legs are routed separately and joined.
    ///
    /// Alternatives are offered for a plain A → B only. Past that the choice is
    /// between 3ⁿ combinations of legs, which is not a choice anyone can act on,
    /// so each leg quietly takes the quickest way.
    ///
    /// - Parameter onProgress: called on the main actor with legs finished and
    ///   legs total, so a ten-leg snap can say where it has got to instead of
    ///   spinning silently for the better part of a minute.
    static func roadRoute(
        through stops: [CLLocationCoordinate2D],
        mode: TravelMode,
        alternatives: Bool = true,
        onProgress: (@MainActor @Sendable (Int, Int) -> Void)? = nil
    ) async throws -> [BuiltRoute] {
        guard stops.count >= 2 else {
            throw RouteBuilderError.notEnoughStops
        }
        if stops.count == 2 {
            return try await roadRoutes(from: stops[0], to: stops[1], mode: mode, alternatives: alternatives)
        }

        let pairs = Array(zip(stops, stops.dropFirst()))
        let legs = try await routeLegs(pairs, mode: mode, onProgress: onProgress)

        var coordinates: [CLLocationCoordinate2D] = []
        var distance: CLLocationDistance = 0
        var travelTime: TimeInterval = 0
        var roads: [RoadSegment] = []

        for (index, leg) in legs.enumerated() {
            // Every leg after the first starts where the previous one ended.
            // Keeping both copies would leave a zero-length step for the walker
            // to divide by when it works out a bearing.
            coordinates += index == 0 ? leg.coordinates : Array(leg.coordinates.dropFirst())
            // Each leg numbers its roads from its own zero, so they are shifted
            // by everything already travelled before being joined.
            let offset = distance
            roads += leg.roads.map {
                RoadSegment(
                    startDistance: $0.startDistance + offset,
                    endDistance: $0.endDistance + offset,
                    roadClass: $0.roadClass
                )
            }
            distance += leg.distance
            travelTime += leg.expectedTravelTime
        }

        guard coordinates.count > 1 else { throw RouteBuilderError.noRoute }

        let intermediate = stops.count - 2
        return [BuiltRoute(
            name: "Via \(intermediate) stop\(intermediate == 1 ? "" : "s")",
            coordinates: coordinates,
            distance: distance,
            expectedTravelTime: travelTime,
            roads: roads
        )]
    }

    /// How many legs are routed at once.
    ///
    /// They don't depend on each other, so routing them one at a time made a
    /// ten-leg snap ten round trips deep — the better part of a minute of
    /// spinner. Not unbounded, though: `MKDirections` is rate-limited per app,
    /// and ten simultaneous requests is the shape of traffic that trips it.
    /// Three in flight is roughly a third of the wall-clock time and still
    /// reads as one client working, not a flood.
    private static let concurrentLegs = 3

    /// The quickest way to cover one leg, tagged with where it belongs.
    ///
    /// A free function rather than a closure inside the group below, so nothing
    /// has to capture the group itself.
    private static func bestLeg(
        index: Int,
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        mode: TravelMode
    ) async throws -> (Int, BuiltRoute) {
        let legs = try await roadRoutes(from: from, to: to, mode: mode, alternatives: false)
        guard let best = legs.min(by: { $0.expectedTravelTime < $1.expectedTravelTime }) else {
            throw RouteBuilderError.legFailed(index + 1)
        }
        return (index, best)
    }

    /// Routes each pair independently, keeping the results in the order given.
    ///
    /// A sliding window rather than one big group: the window bounds how many
    /// requests Apple sees at once, and results are placed by index so a leg
    /// finishing early can't reorder the route.
    private static func routeLegs(
        _ pairs: [(CLLocationCoordinate2D, CLLocationCoordinate2D)],
        mode: TravelMode,
        onProgress: (@MainActor @Sendable (Int, Int) -> Void)?
    ) async throws -> [BuiltRoute] {
        try await withThrowingTaskGroup(of: (Int, BuiltRoute).self) { group in
            var results = [BuiltRoute?](repeating: nil, count: pairs.count)
            var next = 0
            var finished = 0

            while next < min(concurrentLegs, pairs.count) {
                let index = next
                let pair = pairs[index]
                group.addTask {
                    try await bestLeg(index: index, from: pair.0, to: pair.1, mode: mode)
                }
                next += 1
            }

            while let (index, leg) = try await group.next() {
                results[index] = leg
                finished += 1
                await onProgress?(finished, pairs.count)

                if next < pairs.count {
                    let queued = next
                    let pair = pairs[queued]
                    group.addTask {
                        try await bestLeg(index: queued, from: pair.0, to: pair.1, mode: mode)
                    }
                    next += 1
                }
            }

            // A leg that came back with nothing throws above, so a nil here
            // would mean the group ended early — which cancellation does.
            return try results.enumerated().map { index, leg in
                guard let leg else { throw RouteBuilderError.legFailed(index + 1) }
                return leg
            }
        }
    }

    /// Pulls a finger-drawn line onto real roads.
    ///
    /// A drawn path is a rough intention — it cuts corners, crosses buildings
    /// and wanders off the carriageway, and driving it produces a GPS trace no
    /// phone has ever produced. Routing between points taken along it keeps the
    /// shape you drew and puts it on roads that exist.
    ///
    /// - Parameter maximumLegs: one routing request per leg, and Apple throttles
    ///   `MKDirections` hard, so the anchors are capped rather than following
    ///   every wiggle. The road network fills in the detail between them.
    static func snapToRoads(
        path: [CLLocationCoordinate2D],
        mode: TravelMode,
        maximumLegs: Int = 10,
        onProgress: (@MainActor @Sendable (Int, Int) -> Void)? = nil
    ) async throws -> BuiltRoute {
        let stops = anchors(along: path, maximum: maximumLegs + 1)
        guard stops.count >= 2 else { throw RouteBuilderError.notEnoughStops }

        let built = try await roadRoute(
            through: stops, mode: mode, alternatives: false, onProgress: onProgress
        )
        guard let route = built.first else { throw RouteBuilderError.noRoute }
        return BuiltRoute(
            name: "Drawn path, on roads",
            coordinates: route.coordinates,
            distance: route.distance,
            expectedTravelTime: route.expectedTravelTime,
            roads: route.roads
        )
    }

    /// Evenly spaced points along a path, first and last always kept.
    static func anchors(along path: [CLLocationCoordinate2D], maximum: Int) -> [CLLocationCoordinate2D] {
        guard path.count > 2, maximum >= 2 else { return path }
        guard let first = path.first, let last = path.last else { return path }

        let total = zip(path, path.dropFirst()).reduce(0.0) { $0 + Geo.distance($1.0, $1.1) }
        guard total > 1 else { return [first, last] }

        let step = total / Double(maximum - 1)
        var result = [first]
        var travelled: CLLocationDistance = 0
        var nextMark = step

        for (a, b) in zip(path, path.dropFirst()) {
            travelled += Geo.distance(a, b)
            while travelled >= nextMark, result.count < maximum - 1 {
                result.append(b)
                nextMark += step
            }
        }

        // The loop may already have landed on the end; routing a leg from a
        // point to itself returns nothing useful.
        if Geo.distance(result[result.count - 1], last) > 5 {
            result.append(last)
        }
        return result
    }

    static func sample(polyline: MKPolyline, every meters: CLLocationDistance) -> [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](repeating: .init(), count: polyline.pointCount)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: polyline.pointCount))
        return sample(coordinates: coords, every: meters)
    }

    static func sample(coordinates: [CLLocationCoordinate2D], every meters: CLLocationDistance) -> [CLLocationCoordinate2D] {
        guard coordinates.count > 1 else { return coordinates }
        var sampled = [coordinates[0]]
        for (a, b) in zip(coordinates, coordinates.dropFirst()) {
            let dist = CLLocation(latitude: a.latitude, longitude: a.longitude)
                .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
            let steps = max(1, Int(ceil(dist / meters)))
            for i in 1...steps {
                let t = Double(i) / Double(steps)
                sampled.append(CLLocationCoordinate2D(
                    latitude: a.latitude + (b.latitude - a.latitude) * t,
                    longitude: a.longitude + (b.longitude - a.longitude) * t
                ))
            }
        }
        return sampled
    }
}

enum GPXCodec {
    static func parse(_ url: URL) throws -> [CLLocationCoordinate2D] {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        var coords: [CLLocationCoordinate2D] = []
        let pattern = #"lat="([^"]+)"[^>]*lon="([^"]+)""#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match,
                  let latR = Range(match.range(at: 1), in: text),
                  let lonR = Range(match.range(at: 2), in: text),
                  let lat = Double(text[latR]),
                  let lon = Double(text[lonR]),
                  let point = Geo.validCoordinate(latitude: lat, longitude: lon) else { return }
            coords.append(point)
        }
        // Also support lon before lat
        if coords.isEmpty {
            let alt = #"lon="([^"]+)"[^>]*lat="([^"]+)""#
            let altRegex = try NSRegularExpression(pattern: alt)
            altRegex.enumerateMatches(in: text, range: range) { match, _, _ in
                guard let match,
                      let lonR = Range(match.range(at: 1), in: text),
                      let latR = Range(match.range(at: 2), in: text),
                      let lon = Double(text[lonR]),
                      let lat = Double(text[latR]),
                      let point = Geo.validCoordinate(latitude: lat, longitude: lon) else { return }
                coords.append(point)
            }
        }
        guard !coords.isEmpty else {
            throw NSError(domain: "Locus", code: 2, userInfo: [NSLocalizedDescriptionKey: "No track points found in GPX"])
        }
        return coords
    }

    /// A GPX track with its timestamps, when it has any.
    ///
    /// Most GPX files come out of a device that was actually moving, and carry a
    /// `<time>` per point. Ignoring that threw away the one thing that makes a
    /// recording different from a drawn line: the pace it was really done at,
    /// including where it stopped.
    struct Track {
        let coordinates: [CLLocationCoordinate2D]
        /// One per coordinate, or empty when the file has no times.
        let times: [Date]

        var duration: TimeInterval {
            guard let first = times.first, let last = times.last else { return 0 }
            return max(0, last.timeIntervalSince(first))
        }

        var distance: CLLocationDistance {
            zip(coordinates, coordinates.dropFirst()).reduce(0) { $0 + Geo.distance($1.0, $1.1) }
        }

        var hasTiming: Bool { times.count == coordinates.count && duration > 1 }
    }

    /// Parses points *with* their timestamps.
    ///
    /// Deliberately matches per `<trkpt>` element rather than scanning for
    /// attributes and `<time>` separately: a file with a `<metadata><time>` at
    /// the top, or a missing time on one point, would otherwise shift every
    /// timestamp onto the wrong coordinate.
    static func parseTrack(_ url: URL) throws -> Track {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)

        // One match per track point, capturing its attributes and its body.
        let pattern = #"<trkpt\b([^>]*)>(.*?)</trkpt>|<trkpt\b([^>]*)/>"#
        let regex = try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        let range = NSRange(text.startIndex..<text.endIndex, in: text)

        var coordinates: [CLLocationCoordinate2D] = []
        var times: [Date] = []
        var everyPointHasTime = true

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainFormatter = ISO8601DateFormatter()

        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match else { return }

            let attributesRange = match.range(at: 1).location != NSNotFound
                ? match.range(at: 1)
                : match.range(at: 3)
            guard let attributes = Range(attributesRange, in: text).map({ String(text[$0]) }),
                  let coordinate = coordinateFrom(attributes: attributes) else { return }

            coordinates.append(coordinate)

            guard match.range(at: 2).location != NSNotFound,
                  let bodyRange = Range(match.range(at: 2), in: text),
                  let stamp = timeFrom(
                      body: String(text[bodyRange]),
                      formatter: formatter,
                      fallback: plainFormatter
                  ) else {
                everyPointHasTime = false
                return
            }
            times.append(stamp)
        }

        // Fall back to the attribute-only parser for files this doesn't match.
        if coordinates.isEmpty {
            return Track(coordinates: try parse(url), times: [])
        }

        return Track(coordinates: coordinates, times: everyPointHasTime ? times : [])
    }

    /// Compiled once each, not once per track point.
    ///
    /// These three were being built inside the per-point parse: a GPX with ten
    /// thousand points compiled thirty thousand `NSRegularExpression` objects,
    /// which is most of what made importing a long recorded track feel like the
    /// app had hung. Import runs on the main thread.
    private static let latPattern = try? NSRegularExpression(pattern: "lat\\s*=\\s*\"([^\"]+)\"")
    private static let lonPattern = try? NSRegularExpression(pattern: "lon\\s*=\\s*\"([^\"]+)\"")
    private static let timePattern = try? NSRegularExpression(
        pattern: "<time>([^<]+)</time>",
        options: [.caseInsensitive]
    )

    private static func coordinateFrom(attributes: String) -> CLLocationCoordinate2D? {
        func number(_ regex: NSRegularExpression?) -> Double? {
            guard let regex,
                  let match = regex.firstMatch(
                      in: attributes,
                      range: NSRange(attributes.startIndex..<attributes.endIndex, in: attributes)
                  ),
                  let range = Range(match.range(at: 1), in: attributes) else { return nil }
            return Double(attributes[range])
        }
        guard let lat = number(latPattern), let lon = number(lonPattern) else { return nil }
        return Geo.validCoordinate(latitude: lat, longitude: lon)
    }

    private static func timeFrom(
        body: String,
        formatter: ISO8601DateFormatter,
        fallback: ISO8601DateFormatter
    ) -> Date? {
        guard let regex = timePattern,
              let match = regex.firstMatch(
                  in: body,
                  range: NSRange(body.startIndex..<body.endIndex, in: body)
              ),
              let range = Range(match.range(at: 1), in: body) else { return nil }

        let raw = String(body[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        // Fractional seconds are optional in GPX, and one formatter can't take
        // both forms.
        return formatter.date(from: raw) ?? fallback.date(from: raw)
    }

    /// - Parameter times: one per coordinate. Written as `<time>` when present,
    ///   so exporting a recorded track and importing it back gets the pace back
    ///   too — before, the round trip silently flattened it to a bare line.
    static func export(
        _ coordinates: [CLLocationCoordinate2D],
        name: String = "Locus Route",
        times: [Date]? = nil
    ) -> String {
        let stamps = times?.count == coordinates.count ? times : nil
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        var body = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Locus" xmlns="http://www.topografix.com/GPX/1/1">
          <trk>
            <name>\(escaped(name))</name>
            <trkseg>

        """
        for (index, c) in coordinates.enumerated() {
            let point = String(format: "      <trkpt lat=\"%.6f\" lon=\"%.6f\">", c.latitude, c.longitude)
            if let stamps {
                body += point + "<time>\(formatter.string(from: stamps[index]))</time></trkpt>\n"
            } else {
                body += point + "</trkpt>\n"
            }
        }
        body += """
            </trkseg>
          </trk>
        </gpx>
        """
        return body
    }

    /// A route named "Bob & Alice's <run>" would otherwise produce a GPX no
    /// parser will open.
    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
