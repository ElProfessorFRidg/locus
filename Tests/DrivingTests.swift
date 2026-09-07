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
}
