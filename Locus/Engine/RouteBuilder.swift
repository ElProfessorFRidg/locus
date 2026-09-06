import CoreLocation
import Foundation
import MapKit

/// One routing result, kept with the numbers the driving model needs.
///
/// `expectedSpeed` is the only real signal Apple gives about how fast these
/// particular roads are — MapKit exposes no posted speed limits at all — so it
/// is carried through to `RouteSimulator` rather than thrown away with the rest
/// of the `MKRoute`.
struct BuiltRoute: Identifiable {
    let id = UUID()
    let name: String
    let coordinates: [CLLocationCoordinate2D]
    let distance: CLLocationDistance
    let expectedTravelTime: TimeInterval

    /// Timestamps from an imported GPX track, one per coordinate. Present only
    /// when the file recorded them — which is what makes replaying a real trip
    /// at the pace it was actually ridden possible.
    var recordedTimes: [Date]?

    init(
        name: String,
        coordinates: [CLLocationCoordinate2D],
        distance: CLLocationDistance,
        expectedTravelTime: TimeInterval,
        recordedTimes: [Date]? = nil
    ) {
        self.name = name
        self.coordinates = coordinates
        self.distance = distance
        self.expectedTravelTime = expectedTravelTime
        self.recordedTimes = recordedTimes
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
                expectedTravelTime: route.expectedTravelTime
            )
        }
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
                  let lon = Double(text[lonR]) else { return }
            coords.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
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
                      let lat = Double(text[latR]) else { return }
                coords.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
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

    private static func coordinateFrom(attributes: String) -> CLLocationCoordinate2D? {
        func number(_ key: String) -> Double? {
            guard let regex = try? NSRegularExpression(pattern: "\(key)\\s*=\\s*\"([^\"]+)\""),
                  let match = regex.firstMatch(
                      in: attributes,
                      range: NSRange(attributes.startIndex..<attributes.endIndex, in: attributes)
                  ),
                  let range = Range(match.range(at: 1), in: attributes) else { return nil }
            return Double(attributes[range])
        }
        guard let lat = number("lat"), let lon = number("lon") else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private static func timeFrom(
        body: String,
        formatter: ISO8601DateFormatter,
        fallback: ISO8601DateFormatter
    ) -> Date? {
        guard let regex = try? NSRegularExpression(
            pattern: "<time>([^<]+)</time>",
            options: [.caseInsensitive]
        ),
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

    static func export(_ coordinates: [CLLocationCoordinate2D], name: String = "Locus Route") -> String {
        var body = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Locus" xmlns="http://www.topografix.com/GPX/1/1">
          <trk>
            <name>\(name)</name>
            <trkseg>

        """
        for c in coordinates {
            body += String(format: "      <trkpt lat=\"%.6f\" lon=\"%.6f\"></trkpt>\n", c.latitude, c.longitude)
        }
        body += """
            </trkseg>
          </trk>
        </gpx>
        """
        return body
    }
}
