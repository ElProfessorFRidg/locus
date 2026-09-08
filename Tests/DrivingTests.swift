import CoreLocation
import XCTest

/// The driving model and the numbers it puts on screen.
final class DrivingTests: XCTestCase {
    private let paris = CLLocationCoordinate2D(latitude: 48.85837, longitude: 2.29448)

    // MARK: Formatting

    func testDistanceSwitchesToKilometres() {
        XCTAssertEqual(DriveFormat.distance(0), "0 m")
        XCTAssertEqual(DriveFormat.distance(999), "999 m")
        XCTAssertEqual(DriveFormat.distance(1000), "1.0 km")
        // Not 12_450: that is 12.45, which no binary double holds exactly — the
        // stored value is a hair below, so `%.1f` gives 12.4. The formatter is
        // right and the expectation was the thing that was wrong.
        XCTAssertEqual(DriveFormat.distance(12_460), "12.5 km")
        XCTAssertEqual(DriveFormat.distance(12_440), "12.4 km")
    }

    func testClockGrowsAnHoursFieldOnlyWhenNeeded() {
        XCTAssertEqual(DriveFormat.clock(0), "0:00")
        XCTAssertEqual(DriveFormat.clock(65), "1:05")
        XCTAssertEqual(DriveFormat.clock(3600), "1:00:00")
        XCTAssertEqual(DriveFormat.clock(3661), "1:01:01")
    }

    func testClockDoesNotGoNegative() {
        XCTAssertEqual(DriveFormat.clock(-40), "0:00")
    }

    func testSpeedUsesTheChosenUnit() {
        XCTAssertEqual(DriveFormat.speed(13.888, unit: .kph), "50 km/h")
        XCTAssertEqual(DriveFormat.speed(13.4112, unit: .mph), "30 mph")
    }

    func testStepLabel() {
        XCTAssertEqual(DriveFormat.stepLabel(1), "1 m")
        XCTAssertEqual(DriveFormat.stepLabel(25), "25 m")
        XCTAssertEqual(DriveFormat.stepLabel(0.5), "0.5 m")
    }

    /// The ETA is reported in wall-clock seconds, so an 8× drive says how long
    /// you actually have to wait rather than how long the journey "takes".
    func testETADividesByTheTimeScale() {
        var telemetry = DriveTelemetryStub.make()
        telemetry.speed = 10
        telemetry.distanceRemaining = 1000
        XCTAssertEqual(DriveFormat.eta(telemetry: telemetry, timeScale: 1), "1:40")
        XCTAssertEqual(DriveFormat.eta(telemetry: telemetry, timeScale: 4), "0:25")
    }

    func testETAIsNilWhenStopped() {
        var telemetry = DriveTelemetryStub.make()
        telemetry.speed = 0
        telemetry.distanceRemaining = 1000
        XCTAssertNil(DriveFormat.eta(telemetry: telemetry, timeScale: 1))
    }

    // MARK: Speed units

    func testUnitConversionRoundTrips() {
        for unit in SpeedUnit.allCases {
            let metresPerSecond = unit.toMetresPerSecond(90)
            XCTAssertEqual(unit.fromMetresPerSecond(metresPerSecond), 90, accuracy: 1e-6)
        }
    }

    func testKilometresPerHourIsTheFamiliarNumber() {
        XCTAssertEqual(SpeedUnit.kph.toMetresPerSecond(36), 10, accuracy: 1e-6)
    }

    /// Changing the display unit must not change how fast the car goes.
    func testChangingUnitsPreservesTheActualSpeed() {
        var profile = DriveProfile()
        profile.units = .kph
        profile.fixedSpeed = 90
        let before = profile.fixedSpeedMetresPerSecond

        profile.convert(to: .mph)
        XCTAssertEqual(profile.units, .mph)
        // `convert` snaps to the nearest 5 in the new unit, so the true speed
        // can move by up to half a step — about 1.1 m/s for mph.
        XCTAssertEqual(profile.fixedSpeedMetresPerSecond, before, accuracy: 1.2)
    }

    // MARK: Travel modes

    func testTravelModeSpeedsAreOrdered() {
        XCTAssertLessThan(TravelMode.walk.baseSpeed, TravelMode.run.baseSpeed)
        XCTAssertLessThan(TravelMode.run.baseSpeed, TravelMode.cycle.baseSpeed)
        XCTAssertLessThan(TravelMode.cycle.baseSpeed, TravelMode.drive.baseSpeed)
    }

    func testOnlyWheeledModesUseRoadLimits() {
        XCTAssertTrue(TravelMode.drive.usesRoadLimits)
        XCTAssertTrue(TravelMode.cycle.usesRoadLimits)
        XCTAssertFalse(TravelMode.walk.usesRoadLimits)
        XCTAssertFalse(TravelMode.run.usesRoadLimits)
    }

    func testTravelModeIsStableAcrossEncoding() {
        for mode in TravelMode.allCases {
            XCTAssertEqual(TravelMode(rawValue: mode.rawValue), mode)
        }
    }

    // MARK: The plan

    /// A route planned at a fixed speed should be driven at about that speed.
    func testFixedSpeedPlanDrivesAtThatSpeed() {
        var profile = DriveProfile()
        profile.speedSource = .fixed
        profile.units = .kph
        profile.fixedSpeed = 50
        // Set explicitly: the defaults follow the phone's locale, and a US
        // runner would otherwise bring an mph ceiling to a kph test.
        profile.speedCeiling = 130
        profile.traffic = .none
        profile.stopAtJunctions = false
        profile.speedJitter = 0
        profile.gpsNoiseMetres = 0

        let straight = (0..<400).map { Geo.offset(paris, east: 0, north: Double($0) * 10) }
        let plan = RouteSimulator.plan(
            coordinates: straight, profile: profile, mode: .drive, routeExpectedSpeed: nil
        )
        XCTAssertFalse(plan.isEmpty)

        let walker = DriveWalker(plan: plan, profile: profile)
        var last: DriveFix?
        // Long enough to be up to speed and well clear of the finish.
        for _ in 0..<120 { last = walker.step(dt: 1) ?? last }

        let target = SpeedUnit.kph.toMetresPerSecond(50)
        XCTAssertEqual(last?.speed ?? 0, target, accuracy: target * 0.15)
    }

    /// The whole point of the look-ahead controller: it brakes *into* the end
    /// rather than snapping to zero at it.
    func testTheCarStopsAtTheEndOfTheRoute() {
        var profile = DriveProfile()
        profile.speedSource = .fixed
        profile.units = .kph
        profile.fixedSpeed = 50
        profile.speedCeiling = 130
        profile.traffic = .none
        profile.stopAtJunctions = false
        profile.speedJitter = 0

        let straight = (0..<60).map { Geo.offset(paris, east: 0, north: Double($0) * 10) }
        let plan = RouteSimulator.plan(
            coordinates: straight, profile: profile, mode: .drive, routeExpectedSpeed: nil
        )
        let walker = DriveWalker(plan: plan, profile: profile)

        var steps = 0
        while walker.step(dt: 1) != nil, steps < 5000 { steps += 1 }
        XCTAssertTrue(walker.isFinished)
        XCTAssertEqual(walker.progress, 1, accuracy: 0.01)
    }

    /// Resuming halfway must start halfway, which is what makes an interrupted
    /// forty-minute drive worth picking up.
    func testResumingStartsWhereItLeftOff() {
        var profile = DriveProfile()
        profile.speedSource = .fixed
        profile.units = .kph
        profile.fixedSpeed = 50
        profile.speedCeiling = 130
        profile.stopAtJunctions = false

        let straight = (0..<200).map { Geo.offset(paris, east: 0, north: Double($0) * 10) }
        let plan = RouteSimulator.plan(
            coordinates: straight, profile: profile, mode: .drive, routeExpectedSpeed: nil
        )
        let half = plan.totalDistance / 2
        let walker = DriveWalker(plan: plan, profile: profile, startDistance: half)
        XCTAssertEqual(walker.progress, 0.5, accuracy: 0.02)
    }

    /// A hand-corrected limit is the user overruling an estimate, so it has to
    /// win over the estimate everywhere it applies.
    func testAnOverrideBeatsTheEstimate() {
        var profile = DriveProfile()
        profile.speedSource = .roadLimit
        profile.units = .kph
        profile.speedTolerance = 0
        profile.speedCeiling = 130
        profile.traffic = .none
        profile.stopAtJunctions = false
        profile.speedJitter = 0

        let straight = (0..<400).map { Geo.offset(paris, east: 0, north: Double($0) * 10) }
        let slow = SpeedUnit.kph.toMetresPerSecond(30)
        let plan = RouteSimulator.plan(
            coordinates: straight,
            profile: profile,
            mode: .drive,
            routeExpectedSpeed: SpeedUnit.kph.toMetresPerSecond(90),
            overrides: [LimitOverride(startDistance: 0, endDistance: 100_000, limit: slow)]
        )

        let walker = DriveWalker(plan: plan, profile: profile)
        var last: DriveFix?
        for _ in 0..<200 { last = walker.step(dt: 1) ?? last }
        XCTAssertLessThanOrEqual(last?.speed ?? 99, slow * 1.2)
    }

    func testEmptyPathPlansToNothing() {
        let plan = RouteSimulator.plan(
            coordinates: [], profile: DriveProfile(), mode: .drive, routeExpectedSpeed: nil
        )
        XCTAssertTrue(plan.isEmpty)
    }

    /// Reversing is offered from the trip summary, so it has to give back a
    /// route of the same length rather than a broken one.
    func testReversingAPlanKeepsItsLength() {
        var profile = DriveProfile()
        profile.stopAtJunctions = false
        let path = (0..<120).map { Geo.offset(paris, east: Double($0) * 8, north: Double($0) * 3) }
        let plan = RouteSimulator.plan(
            coordinates: path, profile: profile, mode: .drive, routeExpectedSpeed: nil
        )
        let back = plan.reversed()
        XCTAssertEqual(back.totalDistance, plan.totalDistance, accuracy: 1)
        XCTAssertFalse(back.isEmpty)
    }

    // MARK: Stretches

    /// A 20 m blip between two 90 stretches is sampling noise, not a road.
    func testShortStretchesFoldIntoTheirNeighbours() {
        var profile = DriveProfile()
        profile.speedSource = .roadLimit
        profile.stopAtJunctions = false

        let path = (0..<600).map { Geo.offset(paris, east: 0, north: Double($0) * 10) }
        let plan = RouteSimulator.plan(
            coordinates: path,
            profile: profile,
            mode: .drive,
            routeExpectedSpeed: SpeedUnit.kph.toMetresPerSecond(70)
        )
        let stretches = plan.stretches(minimumLength: 120)
        for stretch in stretches.dropLast() {
            XCTAssertGreaterThanOrEqual(
                stretch.endDistance - stretch.startDistance, 100,
                "a stretch shorter than the minimum survived the fold"
            )
        }
    }

    func testStretchesCoverTheWholeRouteWithoutGaps() {
        var profile = DriveProfile()
        profile.speedSource = .roadLimit
        profile.stopAtJunctions = false

        let path = (0..<400).map { Geo.offset(paris, east: Double($0) * 9, north: 0) }
        let plan = RouteSimulator.plan(
            coordinates: path,
            profile: profile,
            mode: .drive,
            routeExpectedSpeed: SpeedUnit.kph.toMetresPerSecond(50)
        )
        let stretches = plan.stretches()
        guard let first = stretches.first, let last = stretches.last else {
            return XCTFail("a 3.6 km route should produce at least one stretch")
        }
        XCTAssertEqual(first.startDistance, 0, accuracy: 1)
        XCTAssertEqual(last.endDistance, plan.totalDistance, accuracy: 30)
        for (a, b) in zip(stretches, stretches.dropFirst()) {
            XCTAssertEqual(a.endDistance, b.startDistance, accuracy: 1, "gap between stretches")
        }
    }
}

/// `DriveTelemetry` has defaults for everything, but spelling that out at each
/// call site buries the one or two fields a test actually cares about.
private enum DriveTelemetryStub {
    static func make() -> DriveTelemetry { DriveTelemetry() }
}

/// The stored profile is not the slider.
///
/// Sliders bound these values; the file on disk does not. A profile written by
/// another build, restored from a backup, or hand-edited comes back as whatever
/// it says — and the engine consumed some of them raw.
final class DriveProfileClampTests: XCTestCase {
    private func profile(tolerance: Double = 0.10, scale: Double = 1) -> DriveProfile {
        var p = DriveProfile()
        p.speedTolerance = tolerance
        p.timeScale = scale
        return p
    }

    func testOrdinaryValuesPassThroughUntouched() {
        let p = profile(tolerance: 0.10, scale: 4)
        XCTAssertEqual(p.speedToleranceClamped, 0.10, accuracy: 1e-9)
        XCTAssertEqual(p.timeScaleClamped, 4, accuracy: 1e-9)
    }

    func testNegativeToleranceIsAllowedButKeptAboveMinusOne() {
        // Driving under the limit is a real setting — the "Careful" starter
        // profile ships at −5%.
        XCTAssertEqual(profile(tolerance: -0.05).speedToleranceClamped, -0.05, accuracy: 1e-9)
        XCTAssertEqual(profile(tolerance: -0.30).speedToleranceClamped, -0.30, accuracy: 1e-9)
    }

    /// The planner computes its ceiling as `limit * (1 + tolerance)`. Below −1
    /// that is a negative target speed, which is not a slow car — it is a car
    /// the model cannot describe.
    func testToleranceBelowMinusOneCannotProduceANegativeCeiling() {
        for stored in [-1.0, -1.5, -40.0, -.greatestFiniteMagnitude] {
            let tolerance = profile(tolerance: stored).speedToleranceClamped
            XCTAssertGreaterThan(1 + tolerance, 0, "stored \(stored) still yields a positive ceiling")
        }
    }

    func testAbsurdToleranceIsCappedRatherThanTrusted() {
        XCTAssertEqual(profile(tolerance: 50).speedToleranceClamped, 2.0, accuracy: 1e-9)
        XCTAssertEqual(profile(tolerance: .infinity).speedToleranceClamped, 2.0, accuracy: 1e-9)
    }

    /// A zero or negative time scale divides the ETA by zero and stalls the
    /// walker; the ceiling keeps a corrupted file from asking for 10000×.
    func testTimeScaleIsHeldInsideTheRangeThePlaybackOffers() {
        XCTAssertEqual(profile(scale: 0).timeScaleClamped, 0.05, accuracy: 1e-9)
        XCTAssertEqual(profile(scale: -3).timeScaleClamped, 0.05, accuracy: 1e-9)
        XCTAssertEqual(profile(scale: 10_000).timeScaleClamped, 8.0, accuracy: 1e-9)
        XCTAssertGreaterThan(profile(scale: 0).timeScaleClamped, 0)
    }

    func testEveryScaleTheUIOffersSurvivesUnchanged() {
        for scale in [0.5, 1.0, 2.0, 4.0, 8.0] {
            XCTAssertEqual(profile(scale: scale).timeScaleClamped, scale, accuracy: 1e-9, "\(scale)×")
        }
    }

    /// A ceiling of zero is the dangerous one: every point's ceiling becomes 0,
    /// so the car's maximum speed is 0 everywhere. It never advances, never
    /// reaches the end, and the drive runs until someone stops it — which reads
    /// as a hang rather than as a setting.
    func testACeilingOfZeroCannotStallTheDrive() {
        var p = DriveProfile()
        p.units = .kph
        for stored in [0.0, -50.0, 0.4] {
            p.speedCeiling = stored
            XCTAssertGreaterThan(p.ceilingMetresPerSecond, 1, "a stored ceiling of \(stored) must still let the car move")
        }
    }

    func testCeilingAndFixedSpeedKeepEveryValueTheirControlsOffer() {
        var p = DriveProfile()
        p.units = .kph
        for stored in [10.0, 50.0, 130.0, 400.0] {
            p.speedCeiling = stored
            XCTAssertEqual(
                p.ceilingMetresPerSecond,
                SpeedUnit.kph.toMetresPerSecond(stored),
                accuracy: 1e-9,
                "\(stored) is inside the stepper's own 10…400 range"
            )
        }
        for stored in [1.0, 30.0, 400.0] {
            p.fixedSpeed = stored
            XCTAssertEqual(
                p.fixedSpeedMetresPerSecond,
                SpeedUnit.kph.toMetresPerSecond(stored),
                accuracy: 1e-9,
                "\(stored) is inside the stepper's own 1…400 range"
            )
        }
    }

    /// The car sits at a stop for exactly as long as this says, so a stored
    /// value in the millions is a drive that never ends. Its controls stop at
    /// 120 seconds; the ceiling is well past that and still finite.
    func testWaitingTimesCannotParkTheCarForever() {
        XCTAssertEqual(
            ClosedRangeBox(lower: 0, upper: 9_999_999).range.upperBound,
            ClosedRangeBox.secondsCeiling,
            accuracy: 1e-9
        )
        XCTAssertLessThanOrEqual(ClosedRangeBox(lower: 1e9, upper: 1e9).randomValue(), ClosedRangeBox.secondsCeiling)

        var p = DriveProfile()
        p.waypointDwellSeconds = 1e9
        XCTAssertEqual(p.waypointDwellClamped, ClosedRangeBox.secondsCeiling, accuracy: 1e-9)
    }

    func testWaitingTimesTheControlsOfferSurviveUnchanged() {
        let box = ClosedRangeBox(lower: 4, upper: 22)
        XCTAssertEqual(box.range.lowerBound, 4, accuracy: 1e-9)
        XCTAssertEqual(box.range.upperBound, 22, accuracy: 1e-9)

        var p = DriveProfile()
        p.waypointDwellSeconds = 120
        XCTAssertEqual(p.waypointDwellClamped, 120, accuracy: 1e-9)
    }

    /// A negative wait is not a wait.
    func testNegativeWaitsBecomeNoWait() {
        XCTAssertEqual(ClosedRangeBox(lower: -50, upper: -5).range.upperBound, 0, accuracy: 1e-9)
        XCTAssertEqual(ClosedRangeBox(lower: -50, upper: -5).randomValue(), 0, accuracy: 1e-9)
    }

    func testAnAbsurdStoredCeilingIsCapped() {
        var p = DriveProfile()
        p.units = .kph
        p.speedCeiling = 99_999
        XCTAssertEqual(p.ceilingMetresPerSecond, SpeedUnit.kph.toMetresPerSecond(400), accuracy: 1e-9)
    }
}

/// The travel mode decides what MapKit is asked for, and the engine has to
/// agree with it afterwards.
///
/// Reported from the field: a 259 km route between two French towns showed
/// "81:36:04 · avg 3 km/h". That is MapKit's honest answer to *walk* from one
/// to the other — the app defaults to Walk — but the sheet around it said
/// "How it drives", offered a speed-limit dial, and the planner then anchored
/// every estimated "limit" on the route to a pedestrian's pace.
final class TravelModeAgreementTests: XCTestCase {
    private let paris = CLLocationCoordinate2D(latitude: 48.85837, longitude: 2.29448)

    /// A straight 4 km road, so the shape can't be what decides the answer.
    private var road: [CLLocationCoordinate2D] {
        (0..<160).map { Geo.offset(paris, east: 0, north: Double($0) * 25) }
    }

    private func plan(mode: TravelMode, expected: CLLocationSpeed?) -> RoutePlan {
        var profile = DriveProfile()
        profile.speedSource = .roadLimit
        profile.units = .kph
        return RouteSimulator.plan(
            coordinates: road,
            profile: profile,
            mode: mode,
            routeExpectedSpeed: expected
        )
    }

    /// `TravelMode.usesRoadLimits` existed to say exactly this and nothing had
    /// ever asked it.
    func testWalkingDoesNotEstimateRoadLimits() {
        // 0.88 m/s is what a 259 km / 81 h walking route reports.
        let walking = plan(mode: .walk, expected: 0.88)
        XCTAssertFalse(walking.usesEstimatedLimits, "roads are not signed for pedestrians")
    }

    /// The summary under "Driving parameters" is what most people ever read
    /// about the profile, and on foot it claimed a limit tolerance the engine
    /// was already ignoring.
    func testTheSummaryDoesNotClaimALimitItIgnores() {
        var profile = DriveProfile()
        profile.speedSource = .roadLimit
        profile.speedTolerance = 0.10

        XCTAssertTrue(profile.summary(for: .drive).contains("Limit"))
        XCTAssertTrue(profile.summary(for: .cycle).contains("Limit"))
        XCTAssertFalse(profile.summary(for: .walk).contains("Limit"))
        XCTAssertFalse(profile.summary(for: .run).contains("Limit"))
        XCTAssertTrue(profile.summary(for: .walk).contains(TravelMode.walk.title))
    }

    /// Every mode's top speed has to be above the pace it is planned at, or the
    /// cap would be quietly slowing down the mode it is meant to protect.
    func testEveryModeCanReachItsOwnBaseSpeed() {
        for mode in TravelMode.allCases {
            XCTAssertGreaterThan(mode.topSpeed, mode.baseSpeed, "\(mode.title)")
        }
        XCTAssertEqual(TravelMode.drive.topSpeed, Double.infinity,
                       "the driver's ceiling is theirs to set, not the mode's")
    }

    /// The whole reason this isn't `title + "ing"`.
    func testEveryModeHasAGerundThatIsAWord() {
        XCTAssertEqual(TravelMode.walk.gerund, "walking")
        XCTAssertEqual(TravelMode.run.gerund, "running")
        XCTAssertEqual(TravelMode.cycle.gerund, "cycling")
        XCTAssertEqual(TravelMode.drive.gerund, "driving")
    }

    func testDrivingStillEstimatesRoadLimits() {
        let driving = plan(mode: .drive, expected: 13.4)
        XCTAssertTrue(driving.usesEstimatedLimits)
    }

    /// The bug in one assertion: Apple's walking average was being scaled up as
    /// though it were a driving average, so the whole ladder anchored to it.
    func testWalkingPaceIsNotScaledUpIntoARoadLimit() {
        let walking = plan(mode: .walk, expected: 0.88)
        guard let first = walking.points.first else { return XCTFail("no plan") }
        XCTAssertEqual(first.limit, TravelMode.walk.baseSpeed, accuracy: 0.01,
                       "a walk should be planned at walking pace, not at whatever Apple's estimate implies")
    }

    /// And the mode a walking route *should* be planned at is its own, whatever
    /// Apple reported — including an absurdly slow long-distance estimate.
    func testWalkingIgnoresTheReportedAverageEntirely() {
        for reported: CLLocationSpeed in [0.3, 0.88, 1.4, 40] {
            let walking = plan(mode: .walk, expected: reported)
            XCTAssertEqual(walking.points.first?.limit ?? 0, TravelMode.walk.baseSpeed, accuracy: 0.01,
                           "reported \(reported) m/s")
        }
    }

    func testRunningIsTreatedTheSameWayAsWalking() {
        let running = plan(mode: .run, expected: 0.88)
        XCTAssertFalse(running.usesEstimatedLimits)
        XCTAssertEqual(running.points.first?.limit ?? 0, TravelMode.run.baseSpeed, accuracy: 0.01)
    }

    /// Cycling shares the road, so it keeps the estimate.
    func testCyclingKeepsRoadLimits() {
        XCTAssertTrue(plan(mode: .cycle, expected: 6.5).usesEstimatedLimits)
    }
}

/// What the road number buys the limit estimator.
///
/// Reported from the field: on a route that is mostly town with some autoroute
/// in it, the A1 came out at 110 instead of 130 and everything else sat on 30
/// or 50. The cause was that the estimator read only the road's *shape* and
/// scaled it off a single average for the whole journey — so an autoroute and a
/// straight départementale were indistinguishable, and the town at one end
/// dragged the motorway at the other down with it.
final class RoadClassLimitTests: XCTestCase {
    private let paris = CLLocationCoordinate2D(latitude: 48.85837, longitude: 2.29448)

    /// Four kilometres of dead straight road, so shape can't be what varies.
    private var straightRoad: [CLLocationCoordinate2D] {
        (0..<160).map { Geo.offset(paris, east: 0, north: Double($0) * 25) }
    }

    private func plan(roads: [RoadSegment], units: SpeedUnit = .kph) -> RoutePlan {
        var profile = DriveProfile()
        profile.speedSource = .roadLimit
        profile.units = units
        return RouteSimulator.plan(
            coordinates: straightRoad,
            profile: profile,
            mode: .drive,
            // 50 km/h — a whole-route average dragged down by town driving,
            // which is exactly the situation that produced the report.
            routeExpectedSpeed: 13.9,
            roads: roads
        )
    }

    private func kph(_ plan: RoutePlan) -> Double {
        let middle = plan.points[plan.points.count / 2]
        return SpeedUnit.kph.fromMetresPerSecond(middle.limit)
    }

    private func covering(_ roadClass: RoadClass) -> [RoadSegment] {
        [RoadSegment(startDistance: 0, endDistance: 100_000, roadClass: roadClass)]
    }

    /// The headline: an autoroute reads as an autoroute even when the journey's
    /// average says 50 km/h.
    func testAnAutorouteIsNotDraggedDownByTheRestOfTheRoute() {
        XCTAssertEqual(kph(plan(roads: covering(.motorway))), 130, accuracy: 0.5)
    }

    /// Same geometry, four classes, four answers — proof the number is what
    /// decides, not the shape.
    func testTheRoadNumberDecidesTheBandOnIdenticalGeometry() {
        XCTAssertEqual(kph(plan(roads: covering(.motorway))), 130, accuracy: 0.5)
        XCTAssertEqual(kph(plan(roads: covering(.national))), 110, accuracy: 0.5)
        XCTAssertEqual(kph(plan(roads: covering(.departmental))), 90, accuracy: 0.5)
        XCTAssertEqual(kph(plan(roads: covering(.street))), 50, accuracy: 0.5)
    }

    /// Without a road number nothing changes — the shape heuristic is still
    /// there, and it is still anchored to the journey's average. This is the
    /// behaviour that produced the bad estimate, kept as the fallback because
    /// it is all there is when MapKit names no road.
    func testWithoutARoadNumberTheOldHeuristicStillRuns() {
        let estimated = kph(plan(roads: []))
        XCTAssertLessThan(estimated, 130, "a 50 km/h average can't reach 130 on shape alone")
        XCTAssertGreaterThan(estimated, 0)
    }

    /// A cyclist follows the road, so `usesRoadLimits` includes them — but the
    /// sign is the road's, not the rider's, and MapKit routes a bicycle as a
    /// car. Nothing stopped a cycle route down the A1 being ridden at 130.
    func testACyclistIsNotGivenMotorwaySpeed() {
        var profile = DriveProfile()
        profile.speedSource = .roadLimit
        profile.units = .kph
        profile.speedCeiling = 130
        let roads = covering(.motorway)

        func middle(_ mode: TravelMode) -> RoutePlan.Point {
            let plan = RouteSimulator.plan(
                coordinates: straightRoad,
                profile: profile,
                mode: mode,
                routeExpectedSpeed: 13.9,
                roads: roads
            )
            return plan.points[plan.points.count / 2]
        }

        let cycling = middle(.cycle)
        // The road is still read truthfully: it is an autoroute, and the
        // estimate says so. What changes is what the rider is asked to do on it.
        XCTAssertEqual(SpeedUnit.kph.fromMetresPerSecond(cycling.limit), 130, accuracy: 0.5)
        XCTAssertLessThanOrEqual(cycling.ceiling, TravelMode.cycle.topSpeed + 0.001)

        // And driving is left exactly as it was.
        XCTAssertGreaterThan(middle(.drive).ceiling, TravelMode.cycle.topSpeed)
    }

    /// The cap is on the *limit*, not on a speed someone typed. Asking for a
    /// fixed 60 km/h on a bicycle is a deliberate choice and Locus honours it.
    func testAFixedSpeedIsNotCappedByTheMode() {
        var profile = DriveProfile()
        profile.speedSource = .fixed
        profile.units = .kph
        profile.fixedSpeed = 60
        profile.speedCeiling = 130

        let plan = RouteSimulator.plan(
            coordinates: straightRoad, profile: profile, mode: .cycle, routeExpectedSpeed: nil
        )
        let middle = plan.points[plan.points.count / 2]
        XCTAssertEqual(SpeedUnit.kph.fromMetresPerSecond(middle.ceiling), 60, accuracy: 0.5)
    }

    /// `A` means autoroute in France and a trunk road in Britain. The
    /// classification is only trusted where the units say the numbering holds.
    func testRoadClassesAreIgnoredInMilesPerHourCountries() {
        let metric = kph(plan(roads: covering(.motorway), units: .kph))
        let imperial = plan(roads: covering(.motorway), units: .mph)
        let imperialKph = SpeedUnit.kph.fromMetresPerSecond(
            imperial.points[imperial.points.count / 2].limit
        )
        XCTAssertEqual(metric, 130, accuracy: 0.5)
        XCTAssertLessThan(imperialKph, 130, "an mph route falls back to the shape heuristic")
    }
}
