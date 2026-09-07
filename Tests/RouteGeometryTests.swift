import CoreLocation
import XCTest

/// Geometry and the route-shaping that sits on it. All of this is pure maths
/// with an answer you can work out by hand, which is exactly the code worth
/// pinning down before anyone tunes it again.
final class RouteGeometryTests: XCTestCase {
    private let paris = CLLocationCoordinate2D(latitude: 48.85837, longitude: 2.29448)

    // MARK: Geo

    func testOffsetThenDistanceAgree() {
        let moved = Geo.offset(paris, east: 300, north: 400)
        // 3-4-5: 300 m east and 400 m north is 500 m away.
        XCTAssertEqual(Geo.distance(paris, moved), 500, accuracy: 2)
    }

    func testOffsetRoundTripsThroughLocalOffset() {
        let moved = Geo.offset(paris, east: -250, north: 125)
        let local = Geo.localOffset(of: moved, from: paris)
        XCTAssertEqual(Double(local.x), -250, accuracy: 1)
        XCTAssertEqual(Double(local.y), 125, accuracy: 1)
    }

    func testBearingCardinals() {
        XCTAssertEqual(Geo.bearing(from: paris, to: Geo.offset(paris, east: 0, north: 100)), 0, accuracy: 1)
        XCTAssertEqual(Geo.bearing(from: paris, to: Geo.offset(paris, east: 100, north: 0)), 90, accuracy: 1)
        XCTAssertEqual(Geo.bearing(from: paris, to: Geo.offset(paris, east: 0, north: -100)), 180, accuracy: 1)
        XCTAssertEqual(Geo.bearing(from: paris, to: Geo.offset(paris, east: -100, north: 0)), 270, accuracy: 1)
    }

    /// The signed shortest turn, which is what tells a corner from a straight.
    func testAngleDeltaTakesTheShortWayRound() {
        XCTAssertEqual(Geo.angleDelta(350, 10), 20, accuracy: 0.001)
        XCTAssertEqual(Geo.angleDelta(10, 350), -20, accuracy: 0.001)
        XCTAssertEqual(Geo.angleDelta(0, 180), 180, accuracy: 0.001)
    }

    // MARK: Corner radius

    func testStraightRoadHasInfiniteRadius() {
        let line = (0..<40).map { Geo.offset(paris, east: 0, north: Double($0) * 10) }
        let cumulative = Self.cumulative(line)
        let radius = RouteSimulator.cornerRadius(
            coordinates: line, cumulative: cumulative, index: 20, window: 80
        )
        XCTAssertFalse(radius.isFinite, "A dead straight road should not read as a corner")
    }

    /// A known circle: the measured radius should be the one it was drawn with.
    func testCircleRadiusIsRecovered() {
        let radius: Double = 200
        let arc = (0..<60).map { step -> CLLocationCoordinate2D in
            let angle = Double(step) / 60 * 2 * .pi
            return Geo.offset(paris, east: radius * cos(angle), north: radius * sin(angle))
        }
        let measured = RouteSimulator.cornerRadius(
            coordinates: arc, cumulative: Self.cumulative(arc), index: 30, window: 80
        )
        XCTAssertEqual(measured, radius, accuracy: radius * 0.15)
    }

    // MARK: Anchors for snapping a drawn path

    func testAnchorsKeepBothEnds() {
        let path = (0..<200).map { Geo.offset(paris, east: Double($0) * 25, north: 0) }
        let anchors = RouteBuilder.anchors(along: path, maximum: 6)
        XCTAssertEqual(anchors.first?.latitude, path.first?.latitude)
        XCTAssertEqual(anchors.last?.longitude ?? 0, path.last?.longitude ?? 0, accuracy: 1e-9)
    }

    /// One routing request per gap, and Apple throttles hard — so the cap is
    /// load-bearing, not a nicety.
    func testAnchorsRespectTheCap() {
        let path = (0..<500).map { Geo.offset(paris, east: Double($0) * 12, north: 0) }
        for maximum in [2, 3, 6, 11] {
            let anchors = RouteBuilder.anchors(along: path, maximum: maximum)
            XCTAssertLessThanOrEqual(anchors.count, maximum, "maximum \(maximum)")
            XCTAssertGreaterThanOrEqual(anchors.count, 2, "maximum \(maximum)")
        }
    }

    func testAnchorsAreSpreadNotBunched() {
        let path = (0..<300).map { Geo.offset(paris, east: Double($0) * 20, north: 0) }
        let anchors = RouteBuilder.anchors(along: path, maximum: 5)
        for (a, b) in zip(anchors, anchors.dropFirst()) {
            XCTAssertGreaterThan(Geo.distance(a, b), 100, "anchors should not sit on top of each other")
        }
    }

    func testShortPathIsLeftAlone() {
        let pair = [paris, Geo.offset(paris, east: 100, north: 0)]
        XCTAssertEqual(RouteBuilder.anchors(along: pair, maximum: 8).count, 2)
    }

    // MARK: Resampling

    func testSamplingSubdividesLongLegs() {
        let sparse = [paris, Geo.offset(paris, east: 0, north: 1000)]
        let dense = RouteBuilder.sample(coordinates: sparse, every: 50)
        XCTAssertGreaterThan(dense.count, 15)
        for (a, b) in zip(dense, dense.dropFirst()) {
            XCTAssertLessThanOrEqual(Geo.distance(a, b), 60)
        }
    }

    func testSamplingKeepsTheEndpoints() {
        let sparse = [paris, Geo.offset(paris, east: 500, north: 500)]
        let dense = RouteBuilder.sample(coordinates: sparse, every: 40)
        XCTAssertEqual(Geo.distance(dense[0], paris), 0, accuracy: 0.5)
        XCTAssertEqual(Geo.distance(dense[dense.count - 1], sparse[1]), 0, accuracy: 0.5)
    }

    func testSamplingASinglePointIsHarmless() {
        XCTAssertEqual(RouteBuilder.sample(coordinates: [paris], every: 10).count, 1)
        XCTAssertEqual(RouteBuilder.sample(coordinates: [], every: 10).count, 0)
    }

    // MARK: Helpers

    private static func cumulative(_ path: [CLLocationCoordinate2D]) -> [CLLocationDistance] {
        var total: CLLocationDistance = 0
        var out: [CLLocationDistance] = [0]
        for (a, b) in zip(path, path.dropFirst()) {
            total += Geo.distance(a, b)
            out.append(total)
        }
        return out
    }
}
