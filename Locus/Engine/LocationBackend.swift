import CoreLocation
import Darwin
import Foundation

/// Which of the two engines sets the location.
///
/// - `tunnel`: idevice over the loopback tunnel to Apple's developer service.
///   Works on any sideloaded copy, needs a pairing file and a tunnel.
/// - `direct`: `CLSimulationManager` from this process, as Geranium does. Needs
///   nothing at all, but only exists where the copy was installed with the
///   `com.apple.locationd.simulation` entitlement — TrollStore, or a jailbreak.
///
/// Direct wins whenever it is available, unless turned off in Settings.
enum LocationBackend: String, Equatable {
    case direct
    case tunnel

    static let preferDirectKey = "locus.direct.enabled"

    /// Whether this copy can use the direct engine at all.
    static var directAvailable: Bool { DirectLocationEngine.isAvailable }

    /// The Settings switch. On unless turned off, so a TrollStore install needs
    /// no configuration to skip pairing and the tunnel entirely.
    static var prefersDirect: Bool {
        get { UserDefaults.standard.object(forKey: preferDirectKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: preferDirectKey) }
    }

    static var current: LocationBackend {
        directAvailable && prefersDirect ? .direct : .tunnel
    }

    /// Whether a teleport needs an RPPairing file before it can work.
    var needsPairing: Bool { self == .tunnel }

    /// Whether a teleport needs the loopback tunnel up before it can work.
    var needsTunnel: Bool { self == .tunnel }

    /// Whether the location stays put on its own once set. The tunnel engine's
    /// session dies with its connection, so it is kept alive and re-sent; the
    /// direct one lives in `locationd` until it is cleared.
    var persistsOnItsOwn: Bool { self == .direct }

    var title: String {
        switch self {
        case .direct: return "Direct (locationd)"
        case .tunnel: return "Developer tunnel"
        }
    }

    /// For the About row: what is actually doing the work.
    var engineDescription: String {
        switch self {
        case .direct: return "CLSimulationManager, in-process"
        case .tunnel: return "idevice DVT location simulation"
        }
    }
}

/// The extra fields only the direct engine can send. The developer service
/// takes a latitude and a longitude and nothing else; `CLSimulationManager`
/// takes a whole `CLLocation`.
enum DirectSimulationOptions {
    static let altitudeKey = "locus.direct.altitude"

    /// Metres, or `nil` to report altitude as unknown.
    static var altitude: CLLocationDistance? {
        get {
            guard let value = UserDefaults.standard.object(forKey: altitudeKey) as? Double, value.isFinite else { return nil }
            return value
        }
        set {
            if let newValue, newValue.isFinite {
                UserDefaults.standard.set(newValue.clamped(to: -500...9_000), forKey: altitudeKey)
            } else {
                UserDefaults.standard.removeObject(forKey: altitudeKey)
            }
        }
    }
}

/// The direct simulation outlives Locus — that is its whole advantage — so a
/// fresh launch has to be told it is still running, or it opens saying "Not
/// Spoofing" over a phone that very much is, with no Stop button to end it.
///
/// Remembered with the boot it was set in: `locationd` forgets the simulation
/// on a restart, and a record from before one would show a spoof that isn't
/// there any more.
struct DirectSimulationRecord: Codable, Equatable {
    var latitude: Double
    var longitude: Double
    var bootTime: Double

    private static let defaultsKey = "locus.direct.active"

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// The record for this boot, if there is one.
    static func load() -> DirectSimulationRecord? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let record = try? JSONDecoder().decode(DirectSimulationRecord.self, from: data) else { return nil }
        guard record.isFromThisBoot(currentBoot: bootTime()) else {
            clear()
            return nil
        }
        return record
    }

    static func save(_ coordinate: CLLocationCoordinate2D) {
        let record = DirectSimulationRecord(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            bootTime: bootTime() ?? 0
        )
        if let data = try? JSONEncoder().encode(record) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    /// `kern.boottime` moves by a second or so as the clock is disciplined, so
    /// a match is anything close. An unreadable boot time on either side is
    /// taken on trust — a stale Stop button is the cheaper mistake.
    func isFromThisBoot(currentBoot: Double?) -> Bool {
        guard let currentBoot, currentBoot > 0, bootTime > 0 else { return true }
        return abs(currentBoot - bootTime) < 5
    }

    static func bootTime() -> Double? {
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        var value = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctl(&mib, 2, &value, &size, nil, 0) == 0, value.tv_sec > 0 else { return nil }
        return Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
    }
}
