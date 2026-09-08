import CoreLocation
import XCTest

/// Choosing between the two or three ways Apple offers to the same place.
///
/// The rows are near-identical by construction — same start, same end — so the
/// badge is most of what a reader has to go on. Which makes a badge that is
/// wrong, or one that appears when the routes are effectively the same journey,
/// actively worse than none.
final class RouteComparisonTests: XCTestCase {
    private func route(
        _ name: String,
        distance: CLLocationDistance,
        time: TimeInterval
    ) -> BuiltRoute {
        BuiltRoute(
            name: name,
            coordinates: [
                CLLocationCoordinate2D(latitude: 48.1, longitude: 2.1),
                CLLocationCoordinate2D(latitude: 48.2, longitude: 2.2),
            ],
            distance: distance,
            expectedTravelTime: time
        )
    }

    func testASingleRouteIsNotBadged() {
        let only = route("Only way", distance: 12_000, time: 900)
        XCTAssertTrue(RouteComparison.badges(for: [only]).isEmpty, "there is nothing to compare it to")
        XCTAssertTrue(RouteComparison.badges(for: []).isEmpty)
    }

    /// The interesting case, and the one nothing used to say: the quickest way
    /// and the shortest way are usually different roads.
    func testFastestAndShortestCanBeDifferentRoutes() {
        let motorway = route("Via A4", distance: 22_000, time: 900)
        let backRoads = route("Via D14", distance: 14_000, time: 1_500)
        let badges = RouteComparison.badges(for: [motorway, backRoads])

        XCTAssertEqual(badges[motorway.id], [.fastest])
        XCTAssertEqual(badges[backRoads.id], [.shortest])
    }

    func testOneRouteCanWinBoth() {
        let best = route("Via A4", distance: 12_000, time: 800)
        let worse = route("Via N7", distance: 18_000, time: 1_400)
        XCTAssertEqual(RouteComparison.badges(for: [best, worse])[best.id], [.fastest, .shortest])
        XCTAssertNil(RouteComparison.badges(for: [best, worse])[worse.id])
    }

    /// A "Fastest" label on a route eight seconds quicker is a claim the
    /// numbers don't support, and on three near-identical alternatives it is
    /// the difference between a badge that decides and a badge that decorates.
    func testNoBadgeWhenTheWinIsTooSmallToMatter() {
        let a = route("Via A4", distance: 12_000, time: 900)
        let b = route("Via A4 bis", distance: 12_050, time: 910)
        XCTAssertTrue(RouteComparison.badges(for: [a, b]).isEmpty)
    }

    func testTheMarginIsMeasuredAgainstTheRunnerUpNotTheWorst() {
        // Two near-identical quick routes and one slow one. Neither quick route
        // has beaten the field, so neither is the fastest in any useful sense —
        // measuring against the slowest would badge one of them anyway.
        let a = route("Via A4", distance: 12_000, time: 900)
        let b = route("Via A4 bis", distance: 12_020, time: 905)
        let slow = route("Via town", distance: 13_000, time: 2_400)

        let badges = RouteComparison.badges(for: [a, b, slow])
        XCTAssertFalse(badges[a.id]?.contains(.fastest) ?? false)
        XCTAssertFalse(badges[b.id]?.contains(.fastest) ?? false)
        XCTAssertTrue(badges.isEmpty, "neither near-identical route has beaten the field")
    }

    /// A drawn or imported path carries no timing, and calling it the fastest
    /// because zero is the smallest number would be a lie with a badge on it.
    func testRoutesWithoutTimingAreNeverCalledFastest() {
        let drawn = route("Drawn path", distance: 9_000, time: 0)
        let real = route("Via A4", distance: 12_000, time: 900)
        let badges = RouteComparison.badges(for: [drawn, real])

        XCTAssertEqual(badges[drawn.id], [.shortest], "distance is still real without timing")
        XCTAssertNil(badges[real.id])
    }

    func testExactlyAtTheThresholdCounts() {
        let a = route("Via A4", distance: 12_000, time: 900)
        let b = route("Via N7", distance: 12_000 + RouteComparison.meaningfulMetres, time: 900 + RouteComparison.meaningfulSeconds)
        let badges = RouteComparison.badges(for: [a, b])
        XCTAssertEqual(badges[a.id], [.fastest, .shortest])
    }

    func testEveryBadgeHasALabel() {
        for badge in RouteBadge.allCases {
            XCTAssertFalse(badge.title.isEmpty, "\(badge)")
        }
    }
}
