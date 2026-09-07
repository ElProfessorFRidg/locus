import CoreGraphics
import CoreLocation
import Foundation

// MARK: - Output

/// One simulated position, with everything the HUD needs to describe it.
struct DriveFix {
    let coordinate: CLLocationCoordinate2D
    /// Metres per second actually being driven.
    let speed: CLLocationSpeed
    /// Estimated posted limit here, metres per second. `nil` when the profile
    /// isn't driving to limits at all.
    let speedLimit: CLLocationSpeed?
    /// Degrees clockwise from north.
    let course: CLLocationDirection
    let distanceTravelled: CLLocationDistance
    let distanceRemaining: CLLocationDistance
    /// Simulated seconds since the route started (not wall-clock — `timeScale`
    /// makes those differ).
    let elapsed: TimeInterval
    let isStopped: Bool
    /// True while the car is above the limit it is meant to be respecting.
    let isOverLimit: Bool
}

// MARK: - Static analysis of a path

/// A route reduced to what the driving model needs: evenly-walkable points,
/// cumulative distance, an estimated speed limit per point, and where the car
/// has to be at a standstill.
///
/// This is deliberately separate from the walker so the expensive part — corner
/// radii, limit estimation, junction detection — happens once, off the tick.
struct RoutePlan {
    struct Point {
        let coordinate: CLLocationCoordinate2D
        /// Metres from the start of the route.
        let distance: CLLocationDistance
        /// Heading of the segment leaving this point, degrees from north.
        let course: CLLocationDirection
        /// Estimated posted limit, m/s.
        let limit: CLLocationSpeed
        /// Fastest the car may go here: the limit with tolerance applied,
        /// further capped by what the corner can physically take.
        let ceiling: CLLocationSpeed
        /// The car must come to a halt here — a junction it didn't get through,
        /// a waypoint dwell, or the end of the route.
        let isStop: Bool
        /// Seconds to sit still on arrival. 0 almost everywhere.
        let dwell: TimeInterval
    }

    let points: [Point]
    let totalDistance: CLLocationDistance
    /// True when limits were estimated rather than fixed by the profile — the
    /// UI says so out loud, because MapKit exposes no posted-limit data.
    let usesEstimatedLimits: Bool

    var isEmpty: Bool { points.count < 2 }

    /// A run of the route carrying one limit.
    ///
    /// The plan has a point every 8 m, which is the right resolution for
    /// driving and hopeless for showing someone: "the limit here" is a property
    /// of a stretch of road, not of a sample. Grouping gives both the coloured
    /// overlay and the list you correct a limit from.
    struct Stretch: Identifiable, Equatable {
        let id: Int
        let coordinates: [CLLocationCoordinate2D]
        let limit: CLLocationSpeed
        let startDistance: CLLocationDistance
        let endDistance: CLLocationDistance

        var length: CLLocationDistance { endDistance - startDistance }

        static func == (lhs: Stretch, rhs: Stretch) -> Bool {
            lhs.id == rhs.id && lhs.limit == rhs.limit
                && lhs.startDistance == rhs.startDistance && lhs.endDistance == rhs.endDistance
        }
    }

    /// What driving this plan will actually involve, in the terms you'd want
    /// before committing forty minutes to it.
    ///
    /// Every number here was already computed and thrown away — the planner
    /// decided the stops and the ceilings, and the only way to find out how many
    /// there were was to drive it and count.
    struct Outline: Equatable {
        /// Junctions the car will sit at, excluding the arrival stop.
        var stops: Int
        /// Total seconds it will spend stationary at them.
        var waiting: TimeInterval
        /// Fastest and slowest the plan permits, m/s.
        var fastest: CLLocationSpeed
        var slowest: CLLocationSpeed
        /// Corners tight enough that the grip budget, not the limit, decides
        /// the speed — the bends you will actually feel.
        var gripLimitedCorners: Int
    }

    func outline() -> Outline {
        // The final point is always a stop because you arrive; counting it
        // would report a junction that isn't one.
        let junctions = points.dropLast().filter(\.isStop)
        let ceilings = points.map(\.ceiling).filter { $0 > 0.1 && $0 < .greatestFiniteMagnitude }

        // A ceiling meaningfully under the limit means the corner won, not the
        // sign. The plan holds a point every 8 m, so a single sweeping bend is
        // dozens of qualifying points: a new corner is only counted after 80 m
        // of road that isn't one. The marker advances on every qualifying
        // sample rather than only on a counted one — anchoring it to the bend's
        // first point instead splits any corner longer than 80 m in two.
        var corners = 0
        var lastCornerDistance = -Double.greatestFiniteMagnitude
        for point in points where point.ceiling < point.limit * 0.85 {
            if point.distance - lastCornerDistance > 80 { corners += 1 }
            lastCornerDistance = point.distance
        }

        return Outline(
            stops: junctions.count,
            waiting: junctions.reduce(0) { $0 + $1.dwell },
            fastest: ceilings.max() ?? 0,
            slowest: ceilings.min() ?? 0,
            gripLimitedCorners: corners
        )
    }

    /// Consecutive points sharing a limit, with short runs folded into their
    /// neighbour — a 20 m blip between two 90 stretches is sampling noise, not
    /// a road anyone would describe.
    func stretches(minimumLength: CLLocationDistance = 120) -> [Stretch] {
        guard points.count > 1 else { return [] }

        var groups: [(limit: CLLocationSpeed, from: Int, to: Int)] = []
        for (index, point) in points.enumerated() {
            if var last = groups.last, abs(last.limit - point.limit) < 0.01 {
                last.to = index
                groups[groups.count - 1] = last
            } else {
                groups.append((point.limit, index, index))
            }
        }

        // Fold anything too short into whichever neighbour it is closer to in
        // speed, repeatedly, until only real stretches remain.
        var changed = true
        while changed, groups.count > 1 {
            changed = false
            for index in groups.indices where
                points[groups[index].to].distance - points[groups[index].from].distance < minimumLength {
                let previous = index > 0 ? groups[index - 1] : nil
                let next = index < groups.count - 1 ? groups[index + 1] : nil
                guard previous != nil || next != nil else { break }

                let mergeWithPrevious: Bool
                switch (previous, next) {
                case (nil, _): mergeWithPrevious = false
                case (_, nil): mergeWithPrevious = true
                case let (p?, n?):
                    mergeWithPrevious = abs(p.limit - groups[index].limit) <= abs(n.limit - groups[index].limit)
                }

                if mergeWithPrevious {
                    groups[index - 1].to = groups[index].to
                } else {
                    groups[index + 1].from = groups[index].from
                }
                groups.remove(at: index)
                changed = true
                break
            }
        }

        return groups.enumerated().map { position, group in
            Stretch(
                id: position,
                coordinates: Array(points[group.from...group.to]).map(\.coordinate),
                limit: group.limit,
                startDistance: points[group.from].distance,
                endDistance: points[group.to].distance
            )
        }
    }

    /// Same route driven the other way, for `pingPong` / `reverseOnce`.
    func reversed() -> RoutePlan {
        guard points.count > 1 else { return self }
        let source = Array(points.reversed())
        var rebuilt: [Point] = []
        rebuilt.reserveCapacity(source.count)

        var travelled: CLLocationDistance = 0
        for (index, point) in source.enumerated() {
            if index > 0 {
                travelled += Geo.distance(source[index - 1].coordinate, point.coordinate)
            }
            let course = index < source.count - 1
                ? Geo.bearing(from: point.coordinate, to: source[index + 1].coordinate)
                : (rebuilt.last?.course ?? point.course)
            rebuilt.append(Point(
                coordinate: point.coordinate,
                distance: travelled,
                course: course,
                limit: point.limit,
                ceiling: point.ceiling,
                // Whatever the original direction stopped for, the far end is
                // now the start line and the start is the finish.
                isStop: index == source.count - 1 ? true : (point.isStop && index > 0),
                dwell: index == 0 ? 0 : point.dwell
            ))
        }
        return RoutePlan(
            points: rebuilt,
            totalDistance: travelled,
            usesEstimatedLimits: usesEstimatedLimits
        )
    }
}

// MARK: - Builder

enum RouteSimulator {

    /// Resamples and annotates `coordinates` into a plan the walker can drive.
    ///
    /// - Parameters:
    ///   - routeExpectedSpeed: `MKRoute.distance / expectedTravelTime` when the
    ///     path came from Apple's directions. It is the only real signal about
    ///     how fast these particular roads are; without it the travel mode's
    ///     base speed stands in.
    static func plan(
        coordinates: [CLLocationCoordinate2D],
        profile: DriveProfile,
        mode: TravelMode,
        routeExpectedSpeed: CLLocationSpeed? = nil,
        overrides: [LimitOverride] = [],
        recordedSpeed: ((CLLocationDistance) -> CLLocationSpeed)? = nil
    ) -> RoutePlan {
        // ~8 m spacing keeps corner geometry meaningful without making the
        // arrays huge on a long motorway leg.
        let resampled = RouteBuilder.sample(coordinates: coordinates, every: 8)
        guard resampled.count > 1 else {
            return RoutePlan(points: [], totalDistance: 0, usesEstimatedLimits: false)
        }

        var cumulative: [CLLocationDistance] = [0]
        cumulative.reserveCapacity(resampled.count)
        for index in 1..<resampled.count {
            cumulative.append(cumulative[index - 1] + Geo.distance(resampled[index - 1], resampled[index]))
        }
        let total = cumulative[cumulative.count - 1]

        var courses: [CLLocationDirection] = []
        courses.reserveCapacity(resampled.count)
        for index in resampled.indices {
            if index < resampled.count - 1 {
                courses.append(Geo.bearing(from: resampled[index], to: resampled[index + 1]))
            } else {
                courses.append(courses.last ?? 0)
            }
        }

        // Replaying a recording only makes sense when there is one; falling
        // back keeps a GPX without timestamps from driving at zero.
        let replaying = profile.speedSource == .recorded && recordedSpeed != nil
        let usesLimits = profile.speedSource == .roadLimit
        let baseline = baselineSpeed(
            profile: profile,
            mode: mode,
            routeExpectedSpeed: routeExpectedSpeed
        )

        var limits = usesLimits
            ? estimateLimits(
                coordinates: resampled,
                cumulative: cumulative,
                baseline: baseline,
                units: profile.units
            )
            : Array(repeating: baseline, count: resampled.count)

        if replaying, let recordedSpeed {
            for index in limits.indices {
                // A recorded stop is a real zero; keep a floor so the walker
                // still creeps out of it rather than parking there forever.
                limits[index] = max(0.4, recordedSpeed(cumulative[index]))
            }
        }

        // Hand corrections win over the estimate, which is the whole point of
        // being able to make them: the estimate reads the road's shape, and a
        // road can be shaped like one limit and signed as another.
        if usesLimits, !overrides.isEmpty {
            for index in limits.indices {
                if let override = overrides.first(where: { $0.contains(cumulative[index]) }) {
                    limits[index] = override.limit
                }
            }
        }

        let lateral = profile.cornering.lateralAcceleration
        let ceilingCap = profile.ceilingMetresPerSecond
        let tolerance = usesLimits ? (1 + profile.speedToleranceClamped) : 1

        // Stops are chosen in their own pass. Rolling the dice per sampled point
        // would fire several times across one junction — the turn spans half a
        // dozen 8 m samples — and leave the car stopping every few metres round
        // a single corner.
        let (stopFlags, dwells) = junctionStops(
            courses: courses,
            cumulative: cumulative,
            profile: profile,
            total: total
        )

        var points: [RoutePlan.Point] = []
        points.reserveCapacity(resampled.count)

        for index in resampled.indices {
            let target = min(limits[index] * tolerance, ceilingCap)

            // Corner speed from the lateral-acceleration budget: v = √(a·r).
            let radius = cornerRadius(
                coordinates: resampled,
                cumulative: cumulative,
                index: index,
                window: 18
            )
            let cornerCap: CLLocationSpeed = radius.isFinite
                ? (lateral * radius).squareRoot()
                : .greatestFiniteMagnitude

            points.append(RoutePlan.Point(
                coordinate: resampled[index],
                distance: cumulative[index],
                course: courses[index],
                limit: limits[index],
                ceiling: max(0, min(target, cornerCap)),
                // Always arrive stopped.
                isStop: stopFlags[index] || index == resampled.count - 1,
                dwell: dwells[index]
            ))
        }

        return RoutePlan(points: points, totalDistance: total, usesEstimatedLimits: usesLimits)
    }

    // MARK: Speed baseline

    private static func baselineSpeed(
        profile: DriveProfile,
        mode: TravelMode,
        routeExpectedSpeed: CLLocationSpeed?
    ) -> CLLocationSpeed {
        switch profile.speedSource {
        case .fixed:
            return max(0.5, profile.fixedSpeedMetresPerSecond)
        case .travelMode:
            return mode.baseSpeed
        case .recorded:
            // Only reached when the track had no usable timing; the mode's pace
            // is a better guess than nothing.
            return mode.baseSpeed
        case .roadLimit:
            // Apple's expected travel time already folds in junctions, lights
            // and typical traffic, so the average it implies runs well under the
            // posted limit. Scaling it back up recovers something close to the
            // sign — it is an estimate and labelled as one.
            guard let observed = routeExpectedSpeed, observed > 0.5 else {
                return mode.baseSpeed
            }
            let correction = mode == .drive || mode == .cycle ? 1.25 : 1.05
            return observed * correction
        }
    }

    /// Per-point limit estimate.
    ///
    /// MapKit has no posted-limit API, so this reads the road's *shape* instead:
    /// long-radius, low-turn stretches carry more speed than tight, junction-dense
    /// ones. The result is scaled off `baseline` and snapped to the values roads
    /// are actually signed at, so the HUD reads 50 or 90 rather than 63.
    private static func estimateLimits(
        coordinates: [CLLocationCoordinate2D],
        cumulative: [CLLocationDistance],
        baseline: CLLocationSpeed,
        units: SpeedUnit
    ) -> [CLLocationSpeed] {
        let ladder = units.speedLadder.map { units.toMetresPerSecond($0) }
        guard let slowest = ladder.first, let fastest = ladder.last else {
            return Array(repeating: baseline, count: coordinates.count)
        }

        var raw: [CLLocationSpeed] = []
        raw.reserveCapacity(coordinates.count)

        for index in coordinates.indices {
            // Wide window: the sweep of the road, not the sampling wobble.
            let radius = cornerRadius(
                coordinates: coordinates,
                cumulative: cumulative,
                index: index,
                window: 80
            )
            // 40 m radius is a junction turn, 400 m is a motorway curve.
            let radiusScore = radius.isFinite
                ? ((radius - 40) / 360).clamped(to: 0...1)
                : 1.0

            let density = turnDensity(
                coordinates: coordinates,
                cumulative: cumulative,
                index: index,
                window: 250
            )
            // 12 direction changes per km is town centre; 0 is open road.
            let densityScore = 1 - (density / 12).clamped(to: 0...1)

            let openness = 0.55 + 0.95 * (0.6 * radiusScore + 0.4 * densityScore)
            raw.append((baseline * openness).clamped(to: slowest...fastest))
        }

        // Smooth before snapping so a single noisy vertex can't drop the whole
        // stretch a rung.
        let smoothed = movingAverage(raw, cumulative: cumulative, window: 120)
        return smoothed.map { value in
            ladder.min(by: { abs($0 - value) < abs($1 - value) }) ?? value
        }
    }

    // MARK: Geometry

    /// Radius of the circle through the points roughly `window` metres either
    /// side of `index`. `.infinity` for a straight.
    ///
    /// Sampling either side rather than using immediate neighbours matters: at
    /// 8 m spacing the immediate triangle is dominated by rounding in the source
    /// polyline, which reads as a hairpin on a straight road.
    static func cornerRadius(
        coordinates: [CLLocationCoordinate2D],
        cumulative: [CLLocationDistance],
        index: Int,
        window: CLLocationDistance
    ) -> CLLocationDistance {
        guard coordinates.count > 2, index > 0, index < coordinates.count - 1 else { return .infinity }

        let here = cumulative[index]
        var back = index
        while back > 0, here - cumulative[back] < window { back -= 1 }
        var forward = index
        while forward < coordinates.count - 1, cumulative[forward] - here < window { forward += 1 }
        guard back < index, forward > index else { return .infinity }

        // Local east/north metres around the middle point: flat-Earth is exact
        // enough over a few hundred metres and avoids any projection surprises.
        let origin = coordinates[index]
        let a = Geo.localOffset(of: coordinates[back], from: origin)
        let b = CGPoint.zero
        let c = Geo.localOffset(of: coordinates[forward], from: origin)

        let ab = hypot(b.x - a.x, b.y - a.y)
        let bc = hypot(c.x - b.x, c.y - b.y)
        let ca = hypot(a.x - c.x, a.y - c.y)
        guard ab > 0.01, bc > 0.01, ca > 0.01 else { return .infinity }

        // Twice the triangle area, via the cross product.
        let cross = abs((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x))
        guard cross > 0.5 else { return .infinity }

        // Circumradius is abc / 4K. `cross` is 2K, so the divisor is 2·cross —
        // dividing by `cross` alone returned twice the real radius, which made
        // every bend read as twice as open as it is. See the tests: a circle
        // drawn at 200 m measured 400.
        return Double(ab * bc * ca / (2 * cross))
    }

    /// Direction changes above `threshold` degrees per kilometre, within
    /// `window` metres either side of `index`.
    private static func turnDensity(
        coordinates: [CLLocationCoordinate2D],
        cumulative: [CLLocationDistance],
        index: Int,
        window: CLLocationDistance,
        threshold: Double = 25
    ) -> Double {
        guard coordinates.count > 2 else { return 0 }
        let here = cumulative[index]
        var lower = index
        while lower > 0, here - cumulative[lower] < window { lower -= 1 }
        var upper = index
        while upper < coordinates.count - 1, cumulative[upper] - here < window { upper += 1 }
        guard upper - lower > 2 else { return 0 }

        var turns = 0
        var previousCourse = Geo.bearing(from: coordinates[lower], to: coordinates[lower + 1])
        var accumulated: Double = 0

        for i in (lower + 1)..<upper {
            let course = Geo.bearing(from: coordinates[i], to: coordinates[i + 1])
            let delta = Geo.angleDelta(previousCourse, course)
            // Accumulate so a turn spread over several 8 m samples still counts
            // once, rather than not at all.
            accumulated += delta
            if abs(accumulated) >= threshold {
                turns += 1
                accumulated = 0
            }
            previousCourse = course
        }

        let span = max(1, cumulative[upper] - cumulative[lower])
        return Double(turns) / (span / 1000)
    }

    /// How much the road turns across roughly 15 m either side of `index`. The
    /// model's stand-in for a junction, since there is no junction data to read.
    private static func turnMagnitude(
        courses: [CLLocationDirection],
        cumulative: [CLLocationDistance],
        index: Int
    ) -> Double {
        let here = cumulative[index]
        var lower = index
        while lower > 0, here - cumulative[lower] < 15 { lower -= 1 }
        var upper = index
        while upper < courses.count - 1, cumulative[upper] - here < 15 { upper += 1 }
        guard lower < upper else { return 0 }
        return abs(Geo.angleDelta(courses[lower], courses[upper]))
    }

    /// Picks where the car comes to a halt.
    ///
    /// Two rules keep this sane. Stops are at least `minSpacing` apart, so one
    /// junction spread over half a dozen 8 m samples produces one stop rather
    /// than six; and none are placed within that distance of either end, where
    /// they would collide with setting off or with the final stop.
    private static func junctionStops(
        courses: [CLLocationDirection],
        cumulative: [CLLocationDistance],
        profile: DriveProfile,
        total: CLLocationDistance
    ) -> (stops: [Bool], dwells: [TimeInterval]) {
        let count = cumulative.count
        var stops = [Bool](repeating: false, count: count)
        var dwells = [TimeInterval](repeating: 0, count: count)

        let wantsJunctionStops = profile.stopAtJunctions && profile.junctionStopChance > 0
        let wantsWaypointDwell = profile.waypointDwellSeconds > 0
        guard count > 2, wantsJunctionStops || wantsWaypointDwell else { return (stops, dwells) }

        let minSpacing: CLLocationDistance = 60
        var lastStop: CLLocationDistance = 0

        for index in 1..<(count - 1) {
            let here = cumulative[index]
            guard here >= minSpacing,
                  total - here >= minSpacing,
                  here - lastStop >= minSpacing else { continue }

            let turn = turnMagnitude(courses: courses, cumulative: cumulative, index: index)

            // A near-U-turn is a waypoint you were meant to pause at; a merely
            // sharp corner is a junction you might be held at.
            if wantsWaypointDwell, turn >= 55 {
                stops[index] = true
                dwells[index] = profile.waypointDwellClamped
                lastStop = here
                continue
            }

            if wantsJunctionStops, turn >= 35,
               Double.random(in: 0...1) < profile.junctionStopChance {
                stops[index] = true
                dwells[index] = profile.junctionStopSeconds.randomValue()
                lastStop = here
            }
        }

        return (stops, dwells)
    }

    private static func movingAverage(
        _ values: [Double],
        cumulative: [CLLocationDistance],
        window: CLLocationDistance
    ) -> [Double] {
        guard values.count > 2 else { return values }
        var output = values
        for index in values.indices {
            let here = cumulative[index]
            var lower = index
            while lower > 0, here - cumulative[lower] < window { lower -= 1 }
            var upper = index
            while upper < values.count - 1, cumulative[upper] - here < window { upper += 1 }
            let slice = values[lower...upper]
            output[index] = slice.reduce(0, +) / Double(slice.count)
        }
        return output
    }
}

// MARK: - Walker

/// Drives a `RoutePlan`, one tick at a time.
///
/// The longitudinal model is a look-ahead controller rather than a precomputed
/// speed table, because traffic moves the target while the car is driving:
///
/// 1. Desired speed = the plan's ceiling here × the current traffic factor.
/// 2. Look ahead as far as the current stopping distance and reduce that to
///    whatever lets the car still meet every ceiling in between —
///    `v ≤ √(v_ahead² + 2·brake·Δs)`. This is what makes it brake *into* a
///    corner instead of snapping speed at the apex.
/// 3. Rate-limit the change by the profile's acceleration and braking.
///
/// Nothing here sleeps or touches the location engine; the caller decides how
/// fast simulated time runs.
final class DriveWalker {
    private let plan: RoutePlan
    private let profile: DriveProfile

    private var distance: CLLocationDistance = 0
    private var speed: CLLocationSpeed = 0
    private var elapsed: TimeInterval = 0
    private var dwellRemaining: TimeInterval = 0
    /// Stops already sat through. Their ceiling goes back to normal afterwards —
    /// without this the car reaches the junction, brakes to zero, and has
    /// nothing above zero to accelerate back into.
    private var servedStops: Set<Int> = []
    private var trafficFactor: Double
    private var noise = GaussianSource()

    private(set) var isFinished = false

    /// - Parameter startDistance: where to pick the drive up, in metres from the
    ///   start. Stops before that point are marked served, so resuming halfway
    ///   doesn't brake for junctions that were already sat through.
    init(plan: RoutePlan, profile: DriveProfile, startDistance: CLLocationDistance = 0) {
        self.plan = plan
        self.profile = profile
        self.trafficFactor = profile.traffic.meanFactor
        self.distance = startDistance.clamped(to: 0...max(0, plan.totalDistance))

        if self.distance > 0 {
            for (index, point) in plan.points.enumerated() where point.isStop && point.distance <= self.distance {
                servedStops.insert(index)
            }
        }
    }

    var totalDistance: CLLocationDistance { plan.totalDistance }
    var progress: Double {
        plan.totalDistance > 0 ? (distance / plan.totalDistance).clamped(to: 0...1) : 0
    }

    /// Advances by `dt` simulated seconds and returns the fix to publish, or
    /// `nil` once the route is done.
    func step(dt: TimeInterval) -> DriveFix? {
        guard !isFinished, !plan.isEmpty else { return nil }

        elapsed += dt
        advanceTraffic(dt: dt)

        if dwellRemaining > 0 {
            dwellRemaining -= dt
            speed = 0
            return fix(at: distance, index: indexBefore(distance: distance), stopped: true)
        }

        let desired = interpolatedCeiling(at: distance) * trafficFactor
        let allowed = max(0, min(desired, brakingLimitedSpeed(from: distance)))

        if speed < allowed {
            speed = min(allowed, speed + profile.accelerationClamped * dt)
        } else {
            speed = max(allowed, speed - profile.brakingClamped * dt)
        }
        // Creep away from a standstill: without this the acceleration ramp is
        // multiplied by a speed of exactly zero and the car never sets off.
        if speed < 0.2, allowed > 0.2 { speed = 0.2 }
        speed = max(0, speed)

        let jitter = profile.speedJitter > 0
            ? (1 + noise.next() * profile.speedJitter * 0.5).clamped(to: 0.5...1.5)
            : 1
        let travelled = max(0, speed * jitter) * dt

        let previousDistance = distance
        distance += travelled

        // Reached something that wants a halt: sit exactly on it.
        if let stop = nextStop(after: previousDistance, upTo: distance) {
            servedStops.insert(stop)
            distance = plan.points[stop].distance
            speed = 0
            dwellRemaining = plan.points[stop].dwell
            if stop == plan.points.count - 1 {
                isFinished = true
            }
            return fix(at: distance, index: stop, stopped: true)
        }

        if distance >= plan.totalDistance {
            distance = plan.totalDistance
            isFinished = true
            return fix(at: distance, index: plan.points.count - 1, stopped: true)
        }

        return fix(
            at: distance,
            index: indexBefore(distance: distance),
            stopped: speed < 0.3
        )
    }

    // MARK: Controller pieces

    /// The fastest the car may be going *here* and still respect every ceiling
    /// within its stopping distance. This is what turns a hard ceiling change
    /// into a brake pedal applied early rather than a speed that teleports.
    private func brakingLimitedSpeed(from position: CLLocationDistance) -> CLLocationSpeed {
        let brake = profile.brakingClamped
        // At least 30 m, so a stop is never discovered too late at low speed,
        // and v²/2a beyond that.
        let horizon = max(30, (speed * speed) / (2 * brake) + 25)
        var limit = CLLocationSpeed.greatestFiniteMagnitude

        var index = indexBefore(distance: position)
        while index < plan.points.count {
            let gap = plan.points[index].distance - position
            if gap > horizon { break }
            if gap >= 0 {
                let ahead = effectiveCeiling(at: index)
                // v ≤ √(v_ahead² + 2·a·Δs)
                limit = min(limit, (ahead * ahead + 2 * brake * gap).squareRoot())
            }
            index += 1
        }
        return limit
    }

    private func advanceTraffic(dt: TimeInterval) {
        guard profile.traffic != .none else {
            trafficFactor = 1
            return
        }
        // Mean-reverting random walk: traffic thickens and clears over tens of
        // seconds rather than flickering every tick.
        let mean = profile.traffic.meanFactor
        let theta = 0.08
        trafficFactor += theta * (mean - trafficFactor) * dt
            + profile.traffic.volatility * dt.squareRoot() * noise.next()
        trafficFactor = trafficFactor.clamped(to: 0.12...1.05)
    }

    // MARK: Sampling

    /// A stop's ceiling is zero only until it has been sat through; afterwards
    /// the point goes back to its normal speed so the car can pull away.
    private func effectiveCeiling(at index: Int) -> CLLocationSpeed {
        let point = plan.points[index]
        if point.isStop, !servedStops.contains(index) { return 0 }
        return point.ceiling
    }

    private func indexBefore(distance target: CLLocationDistance) -> Int {
        var low = 0
        var high = plan.points.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if plan.points[mid].distance <= target { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// First unserved stop strictly within the step just taken.
    private func nextStop(
        after start: CLLocationDistance,
        upTo end: CLLocationDistance
    ) -> Int? {
        guard end >= start else { return nil }
        var index = indexBefore(distance: start)
        while index < plan.points.count {
            let point = plan.points[index]
            if point.distance > end { return nil }
            if point.distance >= start, point.isStop, !servedStops.contains(index) {
                return index
            }
            index += 1
        }
        return nil
    }

    private func interpolatedCeiling(at position: CLLocationDistance) -> CLLocationSpeed {
        let index = indexBefore(distance: position)
        let here = effectiveCeiling(at: index)
        guard index < plan.points.count - 1 else { return here }
        let a = plan.points[index]
        let b = plan.points[index + 1]
        let span = b.distance - a.distance
        guard span > 0.001 else { return here }
        let t = ((position - a.distance) / span).clamped(to: 0...1)
        return here + (effectiveCeiling(at: index + 1) - here) * t
    }

    private func coordinate(at position: CLLocationDistance, index: Int) -> (CLLocationCoordinate2D, CLLocationDirection) {
        let a = plan.points[index]
        guard index < plan.points.count - 1 else { return (a.coordinate, a.course) }
        let b = plan.points[index + 1]
        let span = b.distance - a.distance
        let t = span > 0.001 ? ((position - a.distance) / span).clamped(to: 0...1) : 0
        let coord = CLLocationCoordinate2D(
            latitude: a.coordinate.latitude + (b.coordinate.latitude - a.coordinate.latitude) * t,
            longitude: a.coordinate.longitude + (b.coordinate.longitude - a.coordinate.longitude) * t
        )
        return (coord, a.course)
    }

    private func fix(at position: CLLocationDistance, index: Int, stopped: Bool) -> DriveFix {
        let (base, course) = coordinate(at: position, index: index)
        let point = plan.points[min(index, plan.points.count - 1)]

        var coordinate = base

        // Sit in a lane rather than on the centreline: offset perpendicular to
        // the direction of travel, right-hand side unless told otherwise.
        if profile.laneOffsetMetres != 0 {
            let side = profile.driveOnLeft ? -1.0 : 1.0
            let perpendicular = (course + 90) * .pi / 180
            coordinate = Geo.offset(
                coordinate,
                east: sin(perpendicular) * profile.laneOffsetMetres * side,
                north: cos(perpendicular) * profile.laneOffsetMetres * side
            )
        }

        // Receiver scatter, applied to the reported fix only — the car itself
        // stays on the road, so noise never accumulates into drift.
        if profile.gpsNoiseMetres > 0 {
            coordinate = Geo.offset(
                coordinate,
                east: noise.next() * profile.gpsNoiseMetres,
                north: noise.next() * profile.gpsNoiseMetres
            )
        }

        let limit: CLLocationSpeed? = plan.usesEstimatedLimits ? point.limit : nil
        let over: Bool = {
            guard let limit, limit > 0 else { return false }
            return speed > limit * (1 + max(0, profile.speedToleranceClamped)) + 0.3
        }()

        return DriveFix(
            coordinate: coordinate,
            speed: speed,
            speedLimit: limit,
            course: course,
            distanceTravelled: position,
            distanceRemaining: max(0, plan.totalDistance - position),
            elapsed: elapsed,
            isStopped: stopped,
            isOverLimit: over
        )
    }
}

// MARK: - Helpers

/// Standard normal samples, Box–Muller. Kept as a value the walker owns so a
/// route replays with fresh noise rather than a shared global sequence.
private struct GaussianSource {
    private var spare: Double?

    mutating func next() -> Double {
        if let spare {
            self.spare = nil
            return spare
        }
        var u: Double = 0
        var v: Double = 0
        var s: Double = 0
        repeat {
            u = Double.random(in: -1...1)
            v = Double.random(in: -1...1)
            s = u * u + v * v
        } while s >= 1 || s == 0
        let factor = (-2 * Foundation.log(s) / s).squareRoot()
        spare = v * factor
        return u * factor
    }
}

/// Small flat-Earth helpers. Everything here works over hundreds of metres,
/// which is all the driving model ever spans in one calculation.
enum Geo {
    static let earthRadius = 6_378_137.0

    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    static func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> CLLocationDirection {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let degrees = atan2(y, x) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    /// Signed smallest angle from `a` to `b`, in degrees (−180…180).
    static func angleDelta(_ a: CLLocationDirection, _ b: CLLocationDirection) -> Double {
        var delta = b - a
        while delta > 180 { delta -= 360 }
        while delta < -180 { delta += 360 }
        return delta
    }

    static func offset(
        _ coordinate: CLLocationCoordinate2D,
        east: Double,
        north: Double
    ) -> CLLocationCoordinate2D {
        let dLat = north / earthRadius * (180 / .pi)
        let cosLat = max(0.01, cos(coordinate.latitude * .pi / 180))
        let dLon = east / (earthRadius * cosLat) * (180 / .pi)
        return CLLocationCoordinate2D(
            latitude: coordinate.latitude + dLat,
            longitude: coordinate.longitude + dLon
        )
    }

    /// `coordinate` expressed as metres east/north of `origin`.
    static func localOffset(
        of coordinate: CLLocationCoordinate2D,
        from origin: CLLocationCoordinate2D
    ) -> CGPoint {
        let cosLat = max(0.01, cos(origin.latitude * .pi / 180))
        let east = (coordinate.longitude - origin.longitude) * .pi / 180 * earthRadius * cosLat
        let north = (coordinate.latitude - origin.latitude) * .pi / 180 * earthRadius
        return CGPoint(x: east, y: north)
    }
}
