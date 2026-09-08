import CoreLocation
import XCTest

/// Picking a saved route out of a list of thirty.
///
/// Filtering and ordering look like view code, which is where they used to
/// live and where nothing could test them. They aren't: "which route does
/// 'office' find" and "what sits at the top" are the two questions the whole
/// saved list exists to answer.
final class RouteSelectionTests: XCTestCase {
    private func route(
        _ name: String,
        start: String? = nil,
        end: String? = nil,
        distance: CLLocationDistance = 1000,
        created: TimeInterval = 0,
        driven: TimeInterval? = nil,
        driveCount: Int = 0
    ) -> SavedRoute {
        var saved = SavedRoute(
            name: name,
            route: BuiltRoute(
                name: name,
                coordinates: [
                    CLLocationCoordinate2D(latitude: 48.1, longitude: 2.1),
                    CLLocationCoordinate2D(latitude: 48.2, longitude: 2.2),
                ],
                distance: distance,
                expectedTravelTime: 60
            )
        )
        saved.startName = start
        saved.endName = end
        saved.createdAt = Date(timeIntervalSince1970: created)
        saved.lastDrivenAt = driven.map(Date.init(timeIntervalSince1970:))
        saved.driveCount = driveCount
        return saved
    }

    // MARK: Filtering

    func testEmptyFilterKeepsEverything() {
        let all = [route("A"), route("B"), route("C")]
        XCTAssertEqual(all.matching("").count, 3)
        XCTAssertEqual(all.matching("   ").count, 3, "whitespace is not a search")
    }

    /// The reason endpoint names are stored at all: you remember where a route
    /// goes far more reliably than what you called it.
    func testFilterMatchesEndpointNamesNotJustTheRouteName() {
        let all = [
            route("Monday", start: "Home", end: "Office"),
            route("Weekend", start: "Home", end: "Coast"),
        ]
        XCTAssertEqual(all.matching("office").map(\.name), ["Monday"])
        XCTAssertEqual(all.matching("coast").map(\.name), ["Weekend"])
        XCTAssertEqual(all.matching("home").count, 2)
    }

    func testFilterIsCaseInsensitiveAndTrimmed() {
        let all = [route("Commute", start: "Gare du Nord")]
        XCTAssertEqual(all.matching("  GARE  ").count, 1)
        XCTAssertEqual(all.matching("nord").count, 1)
    }

    func testFilterWithNoMatchReturnsNothing() {
        XCTAssertTrue([route("Commute", start: "Home")].matching("airport").isEmpty)
    }

    func testRouteWithNoEndpointNamesStillMatchesOnItsOwnName() {
        XCTAssertEqual([route("Airport run")].matching("airport").count, 1)
    }

    // MARK: Undoing a delete

    /// Deleting a route destroys its limit corrections, its recorded pace and
    /// its endpoint names. Putting it back at the end of the list would be a
    /// different route as far as a list you scan is concerned.
    func testUndoRestoresARouteWhereItWas() {
        let routes = [route("A"), route("C"), route("D")]
        let restored = routes.reinserting(route("B"), at: 1)
        XCTAssertEqual(restored.map(\.name), ["A", "B", "C", "D"])
    }

    func testUndoAtEitherEndOfTheList() {
        let routes = [route("B"), route("C")]
        XCTAssertEqual(routes.reinserting(route("A"), at: 0).map(\.name), ["A", "B", "C"])
        XCTAssertEqual(routes.reinserting(route("D"), at: 2).map(\.name), ["B", "C", "D"])
    }

    /// The index came from before the deletion, and the list can have moved on
    /// since — something else saved, something else deleted.
    func testUndoClampsAnIndexTheListHasOutgrown() {
        let routes = [route("A")]
        XCTAssertEqual(routes.reinserting(route("X"), at: 99).map(\.name), ["A", "X"])
        XCTAssertEqual(routes.reinserting(route("X"), at: -4).map(\.name), ["X", "A"])
    }

    func testUndoIntoAnEmptyListWorks() {
        XCTAssertEqual([SavedRoute]().reinserting(route("Only"), at: 3).map(\.name), ["Only"])
    }

    // MARK: Unique names

    func testAFreeNameIsLeftAlone() {
        let taken = [route("Commute"), route("Weekend")]
        XCTAssertEqual(RouteStore.uniqueName("Commute copy", among: taken), "Commute copy")
    }

    /// Duplicating twice used to give two rows both called "Commute copy", in
    /// the one list whose whole job is telling routes apart.
    func testATakenNameGetsANumber() {
        var taken = [route("Commute"), route("Commute copy")]
        XCTAssertEqual(RouteStore.uniqueName("Commute copy", among: taken), "Commute copy 2")

        taken.append(route("Commute copy 2"))
        XCTAssertEqual(RouteStore.uniqueName("Commute copy", among: taken), "Commute copy 3")
    }

    func testGapsInTheNumberingAreReused() {
        let taken = [route("Trip copy"), route("Trip copy 3")]
        XCTAssertEqual(RouteStore.uniqueName("Trip copy", among: taken), "Trip copy 2")
    }

    func testUniqueNameTerminatesOnAFullyTakenRun() {
        // Every candidate up to the bound is taken, which the search has to
        // survive rather than run off the end of.
        var taken = [route("X")]
        for suffix in 2...6 { taken.append(route("X \(suffix)")) }
        let result = RouteStore.uniqueName("X", among: taken)
        XCTAssertFalse(result.isEmpty)
        XCTAssertFalse(taken.map(\.name).contains(result), "the search must find a free name, not give up on one")
    }

    // MARK: Ordering

    /// Driven beats saved. A commute kept in January and driven this morning
    /// belongs at the top, which is exactly what sorting on `createdAt` got
    /// wrong.
    func testRecentPrefersLastDrivenOverCreated() {
        let old = route("Old commute", created: 100, driven: 9_000)
        let new = route("Saved yesterday", created: 5_000)
        XCTAssertEqual(SavedRouteOrder.recent.sort([new, old]).map(\.name), ["Old commute", "Saved yesterday"])
    }

    func testRecentFallsBackToCreatedWhenNothingWasDriven() {
        let older = route("Older", created: 100)
        let newer = route("Newer", created: 200)
        XCTAssertEqual(SavedRouteOrder.recent.sort([older, newer]).map(\.name), ["Newer", "Older"])
    }

    func testMostDrivenLeadsWithTheCount() {
        let routes = [
            route("Once", created: 300, driveCount: 1),
            route("Never", created: 400),
            route("Daily", created: 100, driveCount: 40),
        ]
        XCTAssertEqual(SavedRouteOrder.mostDriven.sort(routes).map(\.name), ["Daily", "Once", "Never"])
    }

    /// `sorted` is not stable, so an all-zero drive count used to reshuffle the
    /// list on every redraw — the list moving under your finger as you reach
    /// for a row.
    func testMostDrivenBreaksTiesDeterministically() {
        let routes = [
            route("A", created: 100),
            route("B", created: 300),
            route("C", created: 200),
        ]
        let once = SavedRouteOrder.mostDriven.sort(routes).map(\.name)
        XCTAssertEqual(once, ["B", "C", "A"])
        XCTAssertEqual(SavedRouteOrder.mostDriven.sort(routes.reversed()).map(\.name), once)
    }

    func testLongestOrdersByDistance() {
        let routes = [route("Short", distance: 500), route("Long", distance: 40_000), route("Mid", distance: 9_000)]
        XCTAssertEqual(SavedRouteOrder.longest.sort(routes).map(\.name), ["Long", "Mid", "Short"])
    }

    /// Duplicating a route copies its distance exactly, so identical distances
    /// are reachable — and `sorted` is not stable.
    func testLongestBreaksDistanceTiesDeterministically() {
        let routes = [
            route("Original", distance: 12_000, created: 100),
            route("Original copy", distance: 12_000, created: 300),
            route("Elsewhere", distance: 40_000, created: 200),
        ]
        let once = SavedRouteOrder.longest.sort(routes).map(\.name)
        XCTAssertEqual(once, ["Elsewhere", "Original copy", "Original"])
        XCTAssertEqual(SavedRouteOrder.longest.sort(routes.reversed()).map(\.name), once)
    }

    /// Two routes made in the same instant still have to land in the same order
    /// every redraw, which needs a tie-break below the timestamp.
    func testOrderingIsTotalEvenWithIdenticalTimestamps() {
        let routes = (0..<6).map { route("R\($0)", distance: 1_000, created: 0) }
        for order in SavedRouteOrder.allCases {
            let once = order.sort(routes).map(\.name)
            XCTAssertEqual(order.sort(routes.reversed()).map(\.name), once, "\(order)")
            XCTAssertEqual(Set(once).count, routes.count, "\(order) must not drop a route")
        }
    }

    func testOrderingAnEmptyListIsHarmless() {
        for order in SavedRouteOrder.allCases {
            XCTAssertTrue(order.sort([]).isEmpty, "\(order)")
            XCTAssertFalse(order.title.isEmpty, "\(order) needs a label")
        }
    }

    func testSortingNeverLosesOrDuplicatesARoute() {
        let routes = (0..<12).map { route("R\($0)", distance: Double($0) * 100, created: Double($0), driveCount: $0 % 3) }
        for order in SavedRouteOrder.allCases {
            let sorted = order.sort(routes)
            XCTAssertEqual(Set(sorted.map(\.id)), Set(routes.map(\.id)), "\(order)")
            XCTAssertEqual(sorted.count, routes.count, "\(order)")
        }
    }
}

/// What the planner already knew and used to throw away.
///
/// Every number in an outline was computed to drive the route and then
/// discarded, so the only way to learn a plan had eleven junctions in it was to
/// drive it and count.
final class RoutePlanOutlineTests: XCTestCase {
    private func point(
        at distance: CLLocationDistance,
        limit: CLLocationSpeed = 25,
        ceiling: CLLocationSpeed = 25,
        isStop: Bool = false,
        dwell: TimeInterval = 0
    ) -> RoutePlan.Point {
        RoutePlan.Point(
            coordinate: CLLocationCoordinate2D(latitude: 48.1, longitude: 2.1),
            distance: distance,
            course: 0,
            limit: limit,
            ceiling: ceiling,
            isStop: isStop,
            dwell: dwell
        )
    }

    private func plan(_ points: [RoutePlan.Point]) -> RoutePlan {
        RoutePlan(
            points: points,
            totalDistance: points.last?.distance ?? 0,
            usesEstimatedLimits: true
        )
    }

    /// You always stop at the end because you arrive. Counting that would
    /// report a junction that isn't one, on every route ever planned.
    func testArrivalIsNotCountedAsAStop() {
        let outline = plan([
            point(at: 0),
            point(at: 100, isStop: true, dwell: 12),
            point(at: 200),
            point(at: 300, isStop: true, dwell: 999),
        ]).outline()

        XCTAssertEqual(outline.stops, 1)
        XCTAssertEqual(outline.waiting, 12, accuracy: 1e-9, "the arrival dwell must not be added to the waiting total")
    }

    func testWaitingSumsEveryJunctionDwell() {
        let outline = plan([
            point(at: 0),
            point(at: 100, isStop: true, dwell: 20),
            point(at: 200, isStop: true, dwell: 35),
            point(at: 300, isStop: true, dwell: 5),
        ]).outline()

        XCTAssertEqual(outline.stops, 2)
        XCTAssertEqual(outline.waiting, 55, accuracy: 1e-9)
    }

    func testSpeedBandComesFromTheCeilingsNotTheLimits() {
        let outline = plan([
            point(at: 0, limit: 50, ceiling: 13),
            point(at: 100, limit: 50, ceiling: 36),
            point(at: 200, limit: 50, ceiling: 25),
        ]).outline()

        XCTAssertEqual(outline.slowest, 13, accuracy: 1e-9)
        XCTAssertEqual(outline.fastest, 36, accuracy: 1e-9)
    }

    /// A ceiling well under the limit means the corner decided the speed, not
    /// the sign — the bends you actually feel.
    /// A real bend spans dozens of 8 m samples. Counting each of them would
    /// report a route with eleven corners as having four hundred.
    func testOneLongBendCountsOnce() {
        // 200 m of open road, then a bend held over 300 m of samples — longer
        // than the 80 m separation window, which is exactly the case that used
        // to split one corner into four.
        var points = (0..<10).map { point(at: Double($0) * 20) }
        points += (10..<25).map { point(at: Double($0) * 20, limit: 25, ceiling: 9) }
        points += (25..<40).map { point(at: Double($0) * 20) }

        XCTAssertEqual(plan(points).outline().gripLimitedCorners, 1, "one bend is one bend, however many samples it spans")
    }

    func testTwoSeparateBendsCountTwice() {
        var points: [RoutePlan.Point] = []
        for step in 0...30 {
            let distance = Double(step) * 40
            let tight = step == 5 || step == 25
            points.append(point(at: distance, limit: 25, ceiling: tight ? 8 : 25))
        }
        XCTAssertEqual(plan(points).outline().gripLimitedCorners, 2)
    }

    func testAStraightPlanReportsNoBends() {
        let points = (0...20).map { point(at: Double($0) * 50) }
        let outline = plan(points).outline()
        XCTAssertEqual(outline.gripLimitedCorners, 0)
        XCTAssertEqual(outline.stops, 0)
        XCTAssertEqual(outline.waiting, 0, accuracy: 1e-9)
    }

    /// An empty or single-point plan is real — it is what a cleared workspace
    /// holds — and it must not trap on `dropLast` or an empty `max`.
    func testDegeneratePlansProduceAnEmptyOutline() {
        XCTAssertEqual(plan([]).outline(), RoutePlan.Outline(stops: 0, waiting: 0, fastest: 0, slowest: 0, gripLimitedCorners: 0))
        XCTAssertEqual(plan([point(at: 0, isStop: true, dwell: 30)]).outline().stops, 0)
    }
}
