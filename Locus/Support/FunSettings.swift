import Combine
import CoreLocation
import Foundation

/// Everything Fun mode lets you change — six values, against the Pro sheet's
/// thirty-odd.
///
/// Kept apart from `DriveProfileStore` on purpose. These are not a profile
/// anyone named or will switch between; they are the state of four chips and a
/// dial, and mixing them into the Pro list would put "Fun" in a picker nobody
/// asked to see.
@MainActor
final class FunSettings: ObservableObject {

    /// The Move dial, in metres per second.
    @Published var speed: CLLocationSpeed {
        didSet { store(speed, at: Keys.speed) }
    }

    @Published var tripSpeed: FunTripSpeed {
        didSet { store(tripSpeed.rawValue, at: Keys.tripSpeed) }
    }

    /// How a trip is covered. Separate from the Move dial's pace: walking to
    /// school and driving there are different trips, and the dial is about how
    /// fast you walk, not about which one you meant.
    @Published var tripMode: TravelMode {
        didSet { store(tripMode.rawValue, at: Keys.tripMode) }
    }

    @Published var units: SpeedUnit {
        didSet { store(units.rawValue, at: Keys.units) }
    }

    @Published var buzz: Bool {
        didSet { store(buzz, at: Keys.buzz) }
    }

    @Published var keepScreenOn: Bool {
        didSet { store(keepScreenOn, at: Keys.keepScreenOn) }
    }

    /// Which pace chip is lit — read from the dial rather than stored beside
    /// it, so the two can never disagree.
    var pace: FunPace { FunPace.nearest(to: speed) }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let stored = defaults.object(forKey: Keys.speed) as? Double
        speed = FunPlan.clampedSpeed(stored ?? FunPace.walk.speed)
        tripSpeed = FunTripSpeed(rawValue: defaults.string(forKey: Keys.tripSpeed) ?? "") ?? .normal
        tripMode = TravelMode(rawValue: defaults.string(forKey: Keys.tripMode) ?? "") ?? .drive
        units = SpeedUnit(rawValue: defaults.string(forKey: Keys.units) ?? "") ?? .locale
        // Both default on: a buzz on arrival is the confirmation that the thing
        // you started has finished, and a route you are watching is a route the
        // screen should stay on for.
        buzz = defaults.object(forKey: Keys.buzz) as? Bool ?? true
        keepScreenOn = defaults.object(forKey: Keys.keepScreenOn) as? Bool ?? true
    }

    /// The speed on the dial, in whichever unit is being shown.
    var displaySpeed: Double { units.fromMetresPerSecond(speed) }

    /// Moves the dial to a pace's own speed.
    func select(_ pace: FunPace) {
        speed = pace.speed
    }

    /// The parameters the engine should drive with right now.
    func profile(for mode: TravelMode) -> DriveProfile {
        FunPlan.profile(
            speed: speed,
            trip: tripSpeed,
            mode: mode,
            units: units,
            keepScreenOn: keepScreenOn,
            buzz: buzz
        )
    }

    // MARK: - Storage

    private let defaults: UserDefaults

    private enum Keys {
        static let speed = "locus.fun.speed"
        static let tripSpeed = "locus.fun.tripSpeed"
        static let tripMode = "locus.fun.tripMode"
        static let units = "locus.fun.units"
        static let buzz = "locus.fun.buzz"
        static let keepScreenOn = "locus.fun.keepScreenOn"
    }

    private func store(_ value: Any, at key: String) {
        defaults.set(value, forKey: key)
    }
}

extension FunSettings {
    /// Everything the engine's profile is built from, in one comparable value.
    ///
    /// Six `onChange` modifiers watching six properties is six chances to add a
    /// seventh setting and forget one of them.
    var stamp: String {
        [
            String(format: "%.3f", speed),
            tripSpeed.rawValue,
            tripMode.rawValue,
            units.rawValue,
            buzz ? "1" : "0",
            keepScreenOn ? "1" : "0"
        ].joined(separator: "|")
    }
}
