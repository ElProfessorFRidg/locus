import CoreLocation
import Foundation

// MARK: - Pace

/// How fast you move under your own steam, as one dial rather than a speed
/// source, a fixed speed, a unit picker and a travel mode.
///
/// The four cases are chips on the dial, not separate settings: the dial itself
/// is continuous, and the chip that lights up is whichever band the speed falls
/// in. Tapping a chip is a shortcut to the middle of its band.
enum FunPace: String, CaseIterable, Identifiable, Codable {
    case stroll
    case walk
    case jog
    case bike

    var id: String { rawValue }

    var emoji: String {
        switch self {
        case .stroll: return "🐢"
        case .walk: return "🚶"
        case .jog: return "🏃"
        case .bike: return "🚴"
        }
    }

    var title: String {
        switch self {
        case .stroll: return "Stroll"
        case .walk: return "Walk"
        case .jog: return "Jog"
        case .bike: return "Bike"
        }
    }

    /// The mode routes are built for at this pace, so a jog gets footpaths and
    /// a bike gets roads.
    var travelMode: TravelMode {
        switch self {
        case .stroll, .walk: return .walk
        case .jog: return .run
        case .bike: return .cycle
        }
    }

    /// Where the dial lands when the chip is tapped, in metres per second.
    ///
    /// Held in m/s rather than km/h because that is what the engine moves you
    /// at; km/h and mph are both a division away, and neither is more true.
    var speed: CLLocationSpeed {
        switch self {
        case .stroll: return 0.9   // ~3 km/h
        case .walk: return 1.4     // ~5 km/h, and `TravelMode.walk`'s own pace
        case .jog: return 2.8      // ~10 km/h
        case .bike: return 5.6     // ~20 km/h
        }
    }

    /// Which chip lights up for a dial set to `speed`.
    ///
    /// The bands meet where one pace stops being a fair description of what you
    /// are doing: 4 km/h is a walk, 8 is not, and 15 is a bike whatever the
    /// chip above it says.
    static func nearest(to speed: CLLocationSpeed) -> FunPace {
        switch speed {
        case ..<1.15: return .stroll
        case ..<2.1: return .walk
        case ..<3.9: return .jog
        default: return .bike
        }
    }

    /// What the dial spans, in m/s — a shuffle to a fast descent, about
    /// 1 km/h to 40.
    static let dialRange: ClosedRange<CLLocationSpeed> = 0.3...11.1
}

// MARK: - Trip speed

/// How fast a trip is played back — the one playback control Fun mode has.
///
/// This is `timeScale` under a name that says what it does to the person
/// watching. Nothing here touches how fast the car is driven; a trip at 6× is
/// the same drive, watched in a sixth of the time.
enum FunTripSpeed: String, CaseIterable, Identifiable, Codable {
    case chill
    case normal
    case zoom

    var id: String { rawValue }

    var emoji: String {
        switch self {
        case .chill: return "🐢"
        case .normal: return "🚗"
        case .zoom: return "⚡"
        }
    }

    var title: String {
        switch self {
        case .chill: return "Chill"
        case .normal: return "Normal"
        case .zoom: return "Zoom"
        }
    }

    /// The line under the chip. "1×" means nothing to someone who has never
    /// seen a playback control.
    var detail: String {
        switch self {
        case .chill: return "real time"
        case .normal: return "2× faster"
        case .zoom: return "6× faster"
        }
    }

    var timeScale: Double {
        switch self {
        case .chill: return 1
        case .normal: return 2
        case .zoom: return 6
        }
    }
}

// MARK: - The profile Fun mode drives with

/// Builds the `DriveProfile` behind Fun mode's three or four choices.
///
/// Fun mode never writes to the profiles someone tuned in Pro mode: this is
/// handed to `SpoofSession` as an override, used while Fun mode is on screen
/// and dropped when it isn't. So a commute profile with a hand-set tolerance
/// and a lane offset survives a teenager borrowing the phone.
enum FunPlan {

    /// - Parameters:
    ///   - speed: the Move dial, in m/s. Used as the speed on foot and by bike;
    ///     ignored when driving, where the road's own estimate is better than
    ///     anything a dial could say.
    ///   - trip: how fast the playback runs.
    ///   - mode: what the route is being covered by.
    static func profile(
        speed: CLLocationSpeed,
        trip: FunTripSpeed,
        mode: TravelMode,
        units: SpeedUnit,
        keepScreenOn: Bool,
        buzz: Bool
    ) -> DriveProfile {
        var profile = DriveProfile()
        profile.name = "Fun"
        // Converts `fixedSpeed` and the ceiling as well as the label, so the
        // numbers below are set in the unit they will be read back in.
        profile.convert(to: units)

        profile.timeScale = trip.timeScale

        if mode.isMotorVehicle {
            // The road's estimate, taken at its word. A tolerance dial is the
            // first thing Fun mode has no business asking about.
            profile.speedSource = .roadLimit
            profile.speedTolerance = 0
            profile.stopAtJunctions = true
        } else {
            // On foot and by bike the dial *is* the speed, and there are no
            // junctions to sit at.
            profile.speedSource = .fixed
            profile.fixedSpeed = units.fromMetresPerSecond(clampedSpeed(speed)).clamped(to: 1...400)
            profile.stopAtJunctions = false
        }

        // Fun mode draws its own progress card, and a limit sign it never shows
        // is not something to warn about.
        profile.showHUD = false
        profile.warnWhenOverLimit = false
        profile.showTripEconomy = false

        profile.showLiveActivity = true
        profile.keepScreenAwake = keepScreenOn
        profile.hapticOnLimitChange = buzz

        return profile
    }

    /// The dial can only be set inside its own range, but a stored value from
    /// an older build — or a hand-edited one — has no such promise.
    static func clampedSpeed(_ speed: CLLocationSpeed) -> CLLocationSpeed {
        speed.clamped(to: FunPace.dialRange)
    }
}
