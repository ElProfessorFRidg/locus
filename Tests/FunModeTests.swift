import CoreLocation
import XCTest

/// Fun mode's whole model is a dial and two enums, and every one of them is a
/// number the engine is then driven by.
///
/// The dial in particular is the one place in the app where a speed is set by
/// dragging rather than typed: nothing downstream re-reads what it meant, so a
/// band that overlaps or a unit that doesn't convert is a walk at 40 km/h with
/// no visible cause.
final class FunModeTests: XCTestCase {

    // MARK: - The dial

    func testEachPaceLandsInItsOwnBand() {
        for pace in FunPace.allCases {
            XCTAssertEqual(
                FunPace.nearest(to: pace.speed),
                pace,
                "tapping \(pace.title) must light \(pace.title) up, not its neighbour"
            )
        }
    }

    func testBandsCoverTheWholeDialWithoutAGap() {
        // Walked in 0.1 m/s steps: every point on the dial has to answer with
        // something, and a `switch` with a wrong bound would fall through to
        // the default and report a bike for a shuffle.
        var speed = FunPace.dialRange.lowerBound
        while speed <= FunPace.dialRange.upperBound {
            let pace = FunPace.nearest(to: speed)
            if speed < 1.0 {
                XCTAssertEqual(pace, .stroll, "\(speed) m/s is a stroll")
            }
            if speed > 6.0 {
                XCTAssertEqual(pace, .bike, "\(speed) m/s is a bike")
            }
            speed += 0.1
        }
    }

    func testBandsAreOrderedTheSameWayTheSpeedsAre() {
        let order: [FunPace] = [.stroll, .walk, .jog, .bike]
        XCTAssertEqual(order.map(\.speed), order.map(\.speed).sorted())
    }

    func testDialClampsAStoredSpeedFromOutsideItsRange() {
        XCTAssertEqual(FunPlan.clampedSpeed(-5), FunPace.dialRange.lowerBound)
        XCTAssertEqual(FunPlan.clampedSpeed(900), FunPace.dialRange.upperBound)
        XCTAssertEqual(FunPlan.clampedSpeed(2.0), 2.0)
    }

    // MARK: - The profile it drives with

    func testOnFootTheDialIsTheSpeed() {
        let profile = FunPlan.profile(
            speed: 2.0,
            trip: .normal,
            mode: .walk,
            units: .kph,
            keepScreenOn: true,
            buzz: true
        )
        XCTAssertEqual(profile.speedSource, .fixed)
        // 2 m/s is 7.2 km/h, and the profile stores km/h.
        XCTAssertEqual(profile.fixedSpeed, 7.2, accuracy: 0.05)
        XCTAssertEqual(profile.fixedSpeedMetresPerSecond, 2.0, accuracy: 0.01)
        XCTAssertFalse(profile.stopAtJunctions, "there are no traffic lights on a pavement")
    }

    func testTheDialConvertsWhenTheUnitDoes() {
        let profile = FunPlan.profile(
            speed: 2.0,
            trip: .normal,
            mode: .walk,
            units: .mph,
            keepScreenOn: true,
            buzz: true
        )
        XCTAssertEqual(profile.units, .mph)
        // 2 m/s is 4.47 mph. Stored in the unit it is shown in, so the number
        // under the dial and the number in the profile are the same number.
        XCTAssertEqual(profile.fixedSpeed, 4.47, accuracy: 0.05)
        XCTAssertEqual(profile.fixedSpeedMetresPerSecond, 2.0, accuracy: 0.01)
    }

    func testDrivingTakesTheRoadsOwnEstimateWithNoToleranceDialled_in() {
        let profile = FunPlan.profile(
            speed: 2.0,
            trip: .normal,
            mode: .drive,
            units: .kph,
            keepScreenOn: true,
            buzz: true
        )
        XCTAssertEqual(profile.speedSource, .roadLimit)
        XCTAssertEqual(profile.speedTolerance, 0, "Fun mode never offers a +10%, so it must not apply one")
        XCTAssertTrue(profile.stopAtJunctions)
    }

    func testPlaybackSpeedIsTheOnlyThingTheTripChipsMove() {
        for trip in FunTripSpeed.allCases {
            let profile = FunPlan.profile(
                speed: 1.4,
                trip: trip,
                mode: .drive,
                units: .kph,
                keepScreenOn: true,
                buzz: true
            )
            XCTAssertEqual(profile.timeScale, trip.timeScale)
            // Clamped where the engine reads it, so a chip can never ask for a
            // scale the drive loop refuses.
            XCTAssertEqual(profile.timeScaleClamped, trip.timeScale)
        }
    }

    func testTripSpeedsGetFasterInTheOrderTheyreShownIn() {
        let order: [FunTripSpeed] = [.chill, .normal, .zoom]
        XCTAssertEqual(order.map(\.timeScale), order.map(\.timeScale).sorted())
        XCTAssertEqual(FunTripSpeed.chill.timeScale, 1, "\"real time\" has to mean 1×")
    }

    func testFunModeNeverAsksForTheProHUDOrTheLimitWarnings() {
        let profile = FunPlan.profile(
            speed: 1.4,
            trip: .normal,
            mode: .drive,
            units: .kph,
            keepScreenOn: false,
            buzz: false
        )
        XCTAssertFalse(profile.showHUD, "Fun mode draws its own progress card")
        XCTAssertFalse(profile.warnWhenOverLimit, "there is no limit sign on screen to be over")
        XCTAssertFalse(profile.keepScreenAwake)
        XCTAssertFalse(profile.hapticOnLimitChange)
    }

    func testEveryStoredParameterSurvivesTheEnginesOwnClamps() {
        // The engine clamps what it reads, so a profile built here that needs
        // clamping is a profile that would drive differently from what the
        // chips say.
        for pace in FunPace.allCases {
            for trip in FunTripSpeed.allCases {
                let profile = FunPlan.profile(
                    speed: pace.speed,
                    trip: trip,
                    mode: pace.travelMode,
                    units: .kph,
                    keepScreenOn: true,
                    buzz: true
                )
                XCTAssertEqual(profile.timeScale, profile.timeScaleClamped)
                XCTAssertEqual(profile.speedTolerance, profile.speedToleranceClamped)
                XCTAssertGreaterThan(profile.ceilingMetresPerSecond, profile.fixedSpeedMetresPerSecond)
            }
        }
    }

    // MARK: - Which mode a pace routes as

    func testPacesRouteAsSomethingThatUsesTheRightPaths() {
        XCTAssertEqual(FunPace.stroll.travelMode, .walk)
        XCTAssertEqual(FunPace.walk.travelMode, .walk)
        XCTAssertEqual(FunPace.jog.travelMode, .run)
        XCTAssertEqual(FunPace.bike.travelMode, .cycle)
        for pace in FunPace.allCases {
            XCTAssertFalse(pace.travelMode.isMotorVehicle, "no pace on this dial is a car")
        }
    }

    // MARK: - The two interfaces

    func testProIsTheDefaultInterface() {
        // An existing install has nothing at this key, and must land where it
        // always did.
        XCTAssertNil(LocusInterfaceMode(rawValue: ""))
        XCTAssertEqual(LocusInterfaceMode.allCases.first, .pro)
    }

    func testBothInterfacesSayWhatTheyAre() {
        for mode in LocusInterfaceMode.allCases {
            XCTAssertFalse(mode.title.isEmpty)
            XCTAssertFalse(mode.summary.isEmpty)
            XCTAssertFalse(mode.emoji.isEmpty)
        }
    }
}
