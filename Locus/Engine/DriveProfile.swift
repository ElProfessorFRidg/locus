import CoreLocation
import Foundation

// MARK: - Units

enum SpeedUnit: String, Codable, CaseIterable, Identifiable {
    case kph
    case mph

    var id: String { rawValue }

    var short: String { self == .kph ? "km/h" : "mph" }

    /// What the roads where this phone lives are actually signed in.
    ///
    /// The UK is the reason this isn't just `usesMetricSystem`: it is metric for
    /// nearly everything and still posts speed limits in mph, and Apple models
    /// that as its own measurement system.
    static var locale: SpeedUnit {
        switch Locale.current.measurementSystem {
        case .us, .uk: return .mph
        default: return .kph
        }
    }

    /// Metres per second in one unit.
    var metresPerSecond: Double { self == .kph ? 1000.0 / 3600.0 : 1609.344 / 3600.0 }

    func fromMetresPerSecond(_ value: CLLocationSpeed) -> Double { value / metresPerSecond }
    func toMetresPerSecond(_ value: Double) -> CLLocationSpeed { value * metresPerSecond }

    /// The signposted values a road actually gets in this unit. Estimated limits
    /// are snapped to these so the HUD reads like a real sign instead of "83".
    var speedLadder: [Double] {
        self == .kph
            ? [20, 30, 50, 70, 80, 90, 110, 130]
            : [15, 20, 25, 30, 35, 45, 55, 65, 70]
    }
}

// MARK: - Speed source

enum SpeedSource: String, Codable, CaseIterable, Identifiable {
    /// Old behaviour: the travel mode's base speed, lightly randomised.
    case travelMode
    /// Estimate what the road is posted at, then apply `speedTolerance`.
    case roadLimit
    /// Exactly `fixedSpeed`, traffic and corners aside.
    case fixed
    /// The pace an imported GPX track was actually recorded at, stops included.
    case recorded

    var id: String { rawValue }

    /// Only offered when the loaded route has timestamps to replay.
    static var selectable: [SpeedSource] { [.travelMode, .roadLimit, .fixed] }

    var title: String {
        switch self {
        case .travelMode: return "Travel mode"
        case .roadLimit: return "Road limit"
        case .fixed: return "Fixed speed"
        case .recorded: return "As recorded"
        }
    }

    var detail: String {
        switch self {
        case .travelMode:
            return "One speed for the whole route, from the walk/run/cycle/drive picker."
        case .roadLimit:
            return "Estimates each road's limit from the route's own pace and shape, then applies your tolerance."
        case .fixed:
            return "Holds the speed you set, still slowing for corners and traffic."
        case .recorded:
            return "Replays the imported track at the pace it was recorded at, including where it stopped."
        }
    }
}

// MARK: - Style presets

/// How hard the car is willing to corner, as a lateral acceleration budget.
/// A corner is taken at `sqrt(budget × radius)`, so this is what decides whether
/// a roundabout is a gentle arc or a screech.
enum CorneringStyle: String, Codable, CaseIterable, Identifiable {
    case chauffeur
    case normal
    case brisk
    case reckless

    var id: String { rawValue }

    /// Lateral acceleration budget, m/s². 0.2 g is limousine-smooth, 0.5 g is
    /// the point where unsecured things slide across the back seat.
    var lateralAcceleration: Double {
        switch self {
        case .chauffeur: return 1.8
        case .normal: return 3.0
        case .brisk: return 4.2
        case .reckless: return 5.6
        }
    }

    var title: String {
        switch self {
        case .chauffeur: return "Chauffeur"
        case .normal: return "Normal"
        case .brisk: return "Brisk"
        case .reckless: return "Reckless"
        }
    }
}

enum TrafficDensity: String, Codable, CaseIterable, Identifiable {
    case none
    case light
    case normal
    case heavy
    case gridlock

    var id: String { rawValue }

    /// Long-run average fraction of the target speed actually achieved.
    var meanFactor: Double {
        switch self {
        case .none: return 1.0
        case .light: return 0.93
        case .normal: return 0.82
        case .heavy: return 0.62
        case .gridlock: return 0.35
        }
    }

    /// How far the traffic factor wanders around its mean.
    var volatility: Double {
        switch self {
        case .none: return 0.0
        case .light: return 0.05
        case .normal: return 0.12
        case .heavy: return 0.20
        case .gridlock: return 0.28
        }
    }

    var title: String {
        switch self {
        case .none: return "Clear"
        case .light: return "Light"
        case .normal: return "Normal"
        case .heavy: return "Heavy"
        case .gridlock: return "Gridlock"
        }
    }
}

enum RouteEndBehavior: String, Codable, CaseIterable, Identifiable {
    case stop
    case loop
    case pingPong
    case reverseOnce

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stop: return "Stop"
        case .loop: return "Loop"
        case .pingPong: return "Back and forth"
        case .reverseOnce: return "Return once"
        }
    }

    var icon: String {
        switch self {
        case .stop: return "stop.circle"
        case .loop: return "repeat"
        case .pingPong: return "arrow.left.arrow.right"
        case .reverseOnce: return "arrow.uturn.backward"
        }
    }
}

/// Ready-made cars. Each is only a bundle of the physics values below — picking
/// one writes them, and editing any of them afterwards moves you to `.custom`.
enum VehiclePreset: String, Codable, CaseIterable, Identifiable {
    case cityCar
    case sedan
    case sportsCar
    case van
    case bus
    case scooter
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cityCar: return "City car"
        case .sedan: return "Sedan"
        case .sportsCar: return "Sports car"
        case .van: return "Van"
        case .bus: return "Bus"
        case .scooter: return "Scooter"
        case .custom: return "Custom"
        }
    }

    var icon: String {
        switch self {
        case .cityCar: return "car.fill"
        case .sedan: return "car.side.fill"
        case .sportsCar: return "bolt.car.fill"
        case .van: return "truck.box.fill"
        case .bus: return "bus.fill"
        case .scooter: return "scooter"
        case .custom: return "slider.horizontal.3"
        }
    }

    /// Acceleration (m/s²), braking (m/s²), top speed in km/h, litres per 100 km.
    var physics: (acceleration: Double, braking: Double, topSpeedKph: Double, consumption: Double)? {
        switch self {
        case .cityCar: return (1.9, 3.0, 155, 5.4)
        case .sedan: return (2.4, 3.4, 210, 6.8)
        case .sportsCar: return (4.6, 5.2, 290, 11.2)
        case .van: return (1.5, 2.8, 160, 8.9)
        case .bus: return (1.0, 2.2, 110, 28.0)
        case .scooter: return (2.0, 3.2, 95, 2.6)
        case .custom: return nil
        }
    }

    var corneringStyle: CorneringStyle {
        switch self {
        case .sportsCar: return .brisk
        case .bus, .van: return .chauffeur
        default: return .normal
        }
    }
}

// MARK: - Profile

/// Everything that shapes how Locus drives a route.
///
/// Split into three groups on purpose:
///
/// - **Speed** — what the car is aiming for. `speedTolerance` is the "limit +10%"
///   dial; it multiplies whatever `speedSource` produced.
/// - **Physics** — how it gets there. These feed a real speed-profile solver
///   (`RouteSimulator`), so a corner is braked *into* rather than snapped to.
/// - **Texture** — the things that make a trace look driven rather than
///   generated: traffic, junction stops, GPS scatter, staying in a lane.
///
/// Everything persists to `UserDefaults` as one JSON blob.
struct DriveProfile: Codable, Equatable, Identifiable {

    // MARK: Identity

    var id = UUID()
    var name: String = "Default"

    // MARK: Speed

    var speedSource: SpeedSource = .roadLimit

    /// Fraction added to the estimated limit. `0.10` is the "+10%" everyone
    /// actually drives; the range allows −30% (cautious) to +50%.
    var speedTolerance: Double = 0.10

    /// Used when `speedSource == .fixed`, in `units`.
    var fixedSpeed: Double = SpeedUnit.locale == .kph ? 50 : 30

    /// Never exceed this, whatever the limit estimate says. In `units`.
    var speedCeiling: Double = SpeedUnit.locale == .kph ? 130 : 80

    /// Follows the phone's locale on a fresh install — an mph device showing a
    /// 130 ceiling would read as nonsense, so the two speeds above follow it too.
    var units: SpeedUnit = .locale

    /// Wall-clock multiplier. 1 = real time, 4 = a four-minute commute in one.
    var timeScale: Double = 1.0

    /// Fixes emitted per simulated second. Real GPS is 1 Hz; 2 Hz looks smoother
    /// on a map, 0.5 Hz is gentler on the tunnel.
    var updateRateHz: Double = 1.0

    // MARK: Physics

    var vehicle: VehiclePreset = .sedan

    /// m/s². 2.4 is an unhurried sedan; 4.5 is enthusiastic.
    var acceleration: Double = 2.4

    /// m/s². Comfortable braking is 2–3.5; 8 is emergency.
    var braking: Double = 3.4

    var cornering: CorneringStyle = .normal

    /// ± fraction of random wobble on the achieved speed, so it isn't a
    /// perfectly held needle.
    var speedJitter: Double = 0.06

    // MARK: Texture

    var traffic: TrafficDensity = .light

    /// Pause at junctions sharp enough to be a real turn.
    var stopAtJunctions: Bool = true

    /// Chance of actually stopping at one of those junctions (a red light you
    /// caught, versus one you didn't).
    var junctionStopChance: Double = 0.35

    /// Seconds spent stationary at a junction stop.
    var junctionStopSeconds: ClosedRangeBox = ClosedRangeBox(lower: 4, upper: 22)

    /// Seconds spent at each waypoint of an imported/drawn track.
    var waypointDwellSeconds: Double = 0

    /// Radius of the random scatter added to each emitted fix, in metres. Real
    /// phone GPS is rarely better than 3–5 m in a street.
    var gpsNoiseMetres: Double = 2.5

    /// Sideways offset from the centre of the road, in metres — a car sits in a
    /// lane, not on the dividing line.
    var laneOffsetMetres: Double = 1.8

    /// Which side of the centreline that offset goes.
    var driveOnLeft: Bool = false

    var endBehavior: RouteEndBehavior = .stop

    /// Countdown before the first fix, so you can switch apps first.
    var startDelaySeconds: Double = 0

    // MARK: Gadgets

    /// Live speedometer over the map.
    var showHUD: Bool = true

    /// Speed and progress on the Lock Screen and in the Dynamic Island, so a
    /// route running in a pocket doesn't need the app opened to check on.
    var showLiveActivity: Bool = true

    /// Haptic tap when the estimated limit changes.
    var hapticOnLimitChange: Bool = false

    /// Colour the HUD red past the limit + tolerance.
    var warnWhenOverLimit: Bool = true

    /// L/100 km, used only for the trip readout.
    var consumption: Double = 6.8

    /// Show a fuel/CO₂ estimate in the trip summary. Pure garnish.
    var showTripEconomy: Bool = true

    // MARK: - Derived

    var accelerationClamped: Double { acceleration.clamped(to: 0.4...8.0) }
    var brakingClamped: Double { braking.clamped(to: 0.8...9.0) }

    var fixedSpeedMetresPerSecond: CLLocationSpeed {
        units.toMetresPerSecond(fixedSpeed)
    }

    var ceilingMetresPerSecond: CLLocationSpeed {
        units.toMetresPerSecond(speedCeiling)
    }

    var updateInterval: TimeInterval {
        1.0 / updateRateHz.clamped(to: 0.25...5.0)
    }

    /// Human-readable summary for the collapsed row in the route sheet.
    func summary(for mode: TravelMode) -> String {
        var parts: [String] = []
        // Worth leading with once there are several profiles; "Default" says
        // nothing, so it stays out of the way.
        if name != "Default", !name.isEmpty { parts.append(name) }
        switch speedSource {
        case .travelMode:
            parts.append(mode.title)
        case .roadLimit:
            let sign = speedTolerance >= 0 ? "+" : "−"
            parts.append("Limit \(sign)\(Int((abs(speedTolerance) * 100).rounded()))%")
        case .fixed:
            parts.append("\(Int(fixedSpeed.rounded())) \(units.short)")
        case .recorded:
            parts.append("recorded pace")
        }
        if traffic != .none { parts.append(traffic.title.lowercased() + " traffic") }
        if timeScale != 1 { parts.append(String(format: "%.4g×", timeScale)) }
        if endBehavior != .stop { parts.append(endBehavior.title.lowercased()) }
        return parts.joined(separator: " · ")
    }

    /// Applies a vehicle preset's physics. Called when the user picks a car;
    /// editing any of those values afterwards flips `vehicle` back to `.custom`.
    mutating func apply(_ preset: VehiclePreset) {
        vehicle = preset
        guard let physics = preset.physics else { return }
        acceleration = physics.acceleration
        braking = physics.braking
        consumption = physics.consumption
        cornering = preset.corneringStyle
        speedCeiling = min(
            speedCeiling,
            units == .kph ? physics.topSpeedKph : physics.topSpeedKph * 0.621371
        )
    }

    /// Switches display units, converting the stored speeds so the numbers keep
    /// meaning the same thing.
    mutating func convert(to newUnits: SpeedUnit) {
        guard newUnits != units else { return }
        let fixedMS = units.toMetresPerSecond(fixedSpeed)
        let ceilingMS = units.toMetresPerSecond(speedCeiling)
        units = newUnits
        fixedSpeed = (newUnits.fromMetresPerSecond(fixedMS) / 5).rounded() * 5
        speedCeiling = (newUnits.fromMetresPerSecond(ceilingMS) / 5).rounded() * 5
    }

    // MARK: - Decoding

    init() {}

    init(name: String) {
        self.name = name
    }

    /// Decodes field by field, falling back to the default for anything absent.
    ///
    /// Synthesised `Codable` throws if a single key is missing, and `load()`
    /// answers a throw with a fresh profile — so adding one parameter to this
    /// struct would silently reset everyone's other thirty. Every new field is
    /// simply absent from every stored profile, which makes that the normal
    /// case, not an edge one.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = DriveProfile()

        func value<T: Decodable>(_ key: CodingKeys, _ whenAbsent: T) -> T {
            (try? container.decode(T.self, forKey: key)) ?? whenAbsent
        }

        // A profile stored before these existed gets a fresh id, which is what
        // makes the migration in DriveProfileStore work at all.
        id = value(.id, UUID())
        name = value(.name, fallback.name)

        speedSource = value(.speedSource, fallback.speedSource)
        speedTolerance = value(.speedTolerance, fallback.speedTolerance)
        fixedSpeed = value(.fixedSpeed, fallback.fixedSpeed)
        speedCeiling = value(.speedCeiling, fallback.speedCeiling)
        units = value(.units, fallback.units)
        timeScale = value(.timeScale, fallback.timeScale)
        updateRateHz = value(.updateRateHz, fallback.updateRateHz)

        vehicle = value(.vehicle, fallback.vehicle)
        acceleration = value(.acceleration, fallback.acceleration)
        braking = value(.braking, fallback.braking)
        cornering = value(.cornering, fallback.cornering)
        speedJitter = value(.speedJitter, fallback.speedJitter)

        traffic = value(.traffic, fallback.traffic)
        stopAtJunctions = value(.stopAtJunctions, fallback.stopAtJunctions)
        junctionStopChance = value(.junctionStopChance, fallback.junctionStopChance)
        junctionStopSeconds = value(.junctionStopSeconds, fallback.junctionStopSeconds)
        waypointDwellSeconds = value(.waypointDwellSeconds, fallback.waypointDwellSeconds)

        gpsNoiseMetres = value(.gpsNoiseMetres, fallback.gpsNoiseMetres)
        laneOffsetMetres = value(.laneOffsetMetres, fallback.laneOffsetMetres)
        driveOnLeft = value(.driveOnLeft, fallback.driveOnLeft)
        endBehavior = value(.endBehavior, fallback.endBehavior)
        startDelaySeconds = value(.startDelaySeconds, fallback.startDelaySeconds)

        showHUD = value(.showHUD, fallback.showHUD)
        showLiveActivity = value(.showLiveActivity, fallback.showLiveActivity)
        hapticOnLimitChange = value(.hapticOnLimitChange, fallback.hapticOnLimitChange)
        warnWhenOverLimit = value(.warnWhenOverLimit, fallback.warnWhenOverLimit)
        consumption = value(.consumption, fallback.consumption)
        showTripEconomy = value(.showTripEconomy, fallback.showTripEconomy)
    }

}

/// `ClosedRange` is `Codable` but not editable field-by-field from SwiftUI
/// without risking `lower > upper` crashing the range initialiser. This keeps
/// the two bounds independent and clamps only when the range is read.
struct ClosedRangeBox: Codable, Equatable {
    var lower: Double
    var upper: Double

    var range: ClosedRange<Double> {
        let low = min(lower, upper)
        return low...max(low, upper)
    }

    func randomValue() -> Double {
        let r = range
        return r.lowerBound == r.upperBound ? r.lowerBound : Double.random(in: r)
    }
}

extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}
