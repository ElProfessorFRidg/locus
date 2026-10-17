import CoreLocation
import Darwin
import Foundation

/// Sets the location by talking to `locationd` directly — Geranium's LocSim,
/// brought over as a second engine.
///
/// The tunnel engine reaches Apple's developer location service over a loopback
/// VPN, a pairing file and a RemoteXPC handshake, and that service then calls
/// `CLSimulationManager` inside `locationd` on our behalf. An app that holds
/// `com.apple.locationd.simulation` itself can skip every one of those steps
/// and make the same calls from its own process. Nothing to pair, no tunnel,
/// no handshake to drop — and because the simulation lives in `locationd`
/// rather than in a connection Locus has to keep open, it survives Locus being
/// backgrounded or swiped away, exactly as it does in Geranium.
///
/// No sideloader can grant that entitlement. TrollStore can, and so can a
/// jailbreak; those are the "compatible devices". Everywhere else this engine
/// reports itself unavailable and Locus carries on with the tunnel.
///
/// `CLSimulationManager` is private, so it is reached through the Objective-C
/// runtime rather than a bridging header: the class is looked up by name and
/// every selector checked before it is sent. A future iOS that renames
/// something degrades to "unavailable" instead of crashing on an unrecognised
/// selector.
enum DirectLocationEngine {

    /// One simulated fix, already in WGS-84.
    struct Fix {
        var coordinate: CLLocationCoordinate2D
        /// Metres above sea level, or `nil` to report altitude as unknown.
        var altitude: CLLocationDistance?
        /// Metres per second, or `nil` when there is no movement to report.
        var speed: CLLocationSpeed?
        /// Degrees clockwise from true north, or `nil` when not moving.
        var course: CLLocationDirection?
    }

    /// The entitlement `locationd` checks before it accepts any of this.
    static let entitlement = "com.apple.locationd.simulation"

    /// Whether this copy was signed with the entitlement. Read from the running
    /// process's own code signature, so it is the truth, not the request.
    static let hasEntitlement: Bool = SelfEntitlements.bool(entitlement)

    /// Whether the private class is there to talk to.
    static let hasManagerClass: Bool = managerClass != nil

    /// Both, and every selector the engine sends answered.
    static let isAvailable: Bool = hasEntitlement && managerIsUsable

    private static let managerClass: NSObject.Type? = NSClassFromString("CLSimulationManager") as? NSObject.Type

    private enum Selectors {
        static let stop = NSSelectorFromString("stopLocationSimulation")
        static let start = NSSelectorFromString("startLocationSimulation")
        static let clear = NSSelectorFromString("clearSimulatedLocations")
        static let append = NSSelectorFromString("appendSimulatedLocation:")
        static let flush = NSSelectorFromString("flush")
        static let all = [stop, start, clear, append, flush]
    }

    private static let managerIsUsable: Bool = {
        guard let managerClass else { return false }
        return Selectors.all.allSatisfy { managerClass.instancesRespond(to: $0) }
    }()

    /// Serialises every call into `locationd`, as the tunnel engine's queue does
    /// for the FFI. They are synchronous XPC round trips, so they stay off the
    /// main thread.
    private static let queue = DispatchQueue(label: "com.chrismack.locus.direct", qos: .userInitiated)

    /// Created lazily, on `queue`, and only ever touched there.
    private static var manager: NSObject?

    /// How long `locationd` gets to answer before a call gives up on it.
    ///
    /// `perform(_:)` is a synchronous Objective-C message send, and the
    /// selectors it sends are documented (by every other project that uses
    /// this private API) as synchronous XPC round trips into `locationd`. If
    /// `locationd` is ever slow to answer — observed right after installing a
    /// fresh build, plausibly also while the daemon is busy around a lock/
    /// unlock — nothing before this bounded the wait, so `apply()` sat on
    /// `await send(...)` forever: `status` stuck at "connecting", `isBusy`
    /// stuck `true`, no error anywhere. This does not unstick `queue` itself —
    /// if the stuck call never returns, `queue` stays blocked and every later
    /// call queued behind it times out in turn — but no caller hangs past it.
    private static let commandTimeout: TimeInterval = 6

    // MARK: - Engine

    static func set(_ fix: Fix) async -> Result<Void, LocationEngineError> {
        guard isAvailable else { return .failure(.directUnavailable) }
        let location = makeLocation(fix)
        return await withTimeout(commandTimeout) { resume in
            queue.async {
                guard let manager = currentManager() else {
                    resume(.failure(.directUnavailable))
                    return
                }
                // The exact sequence Geranium, udevs' `locsim` and Xcode's own
                // device-side service all use: drop whatever was being played,
                // queue the one new fix, push it to `locationd`, play it.
                // Restarting rather than appending to a running simulation is
                // what makes the newest fix win immediately.
                _ = manager.perform(Selectors.stop)
                _ = manager.perform(Selectors.clear)
                _ = manager.perform(Selectors.append, with: location)
                _ = manager.perform(Selectors.flush)
                _ = manager.perform(Selectors.start)
                resume(.success(()))
            }
        }
    }

    /// Hands the location back to the real GPS.
    ///
    /// Sent three times, a moment apart. Geranium grew a setting for this —
    /// "try stopping LocSim multiple times" — because a single stop sometimes
    /// doesn't stick; the repeats cost nothing, so they simply happen here.
    static func clear() async -> Result<Void, LocationEngineError> {
        guard isAvailable else { return .failure(.directUnavailable) }
        // Three round trips plus two 150ms sleeps of slack on top of `set`'s own.
        return await withTimeout(commandTimeout * 2) { resume in
            queue.async {
                guard let manager = currentManager() else {
                    resume(.failure(.directUnavailable))
                    return
                }
                for attempt in 0..<3 {
                    if attempt > 0 { usleep(150_000) }
                    _ = manager.perform(Selectors.stop)
                    _ = manager.perform(Selectors.clear)
                    _ = manager.perform(Selectors.flush)
                }
                resume(.success(()))
            }
        }
    }

    /// Races `work` against a timeout, resuming with `.directTimedOut` if
    /// `work` hasn't called its callback by then. The timeout runs on the
    /// Swift concurrency clock, not on `queue` — so it fires even when `queue`
    /// itself is the thing stuck.
    private static func withTimeout(
        _ seconds: TimeInterval,
        _ work: @escaping (@escaping (Result<Void, LocationEngineError>) -> Void) -> Void
    ) async -> Result<Void, LocationEngineError> {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            work { once.resume($0) }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                once.resume(.failure(.directTimedOut))
            }
        }
    }

    /// A `CheckedContinuation` resumed from two races at once must still only
    /// resume once — a second `resume` is a crash, not a no-op.
    private final class ResumeOnce {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Result<Void, LocationEngineError>, Never>?
        init(_ continuation: CheckedContinuation<Result<Void, LocationEngineError>, Never>) {
            self.continuation = continuation
        }
        func resume(_ value: Result<Void, LocationEngineError>) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }

    private static func currentManager() -> NSObject? {
        if let manager { return manager }
        guard isAvailable, let managerClass else { return nil }
        let created = managerClass.init()
        manager = created
        return created
    }

    private static func makeLocation(_ fix: Fix) -> CLLocation {
        // A vertical accuracy of -1 is how CoreLocation says "no altitude", which
        // is more honest than Geranium's default of exactly sea level everywhere.
        let altitude = fix.altitude ?? 0
        let verticalAccuracy: CLLocationAccuracy = fix.altitude == nil ? -1 : 5
        let speed = fix.speed.map { max(0, $0) } ?? 0
        let course = fix.course.map { $0.truncatingRemainder(dividingBy: 360) }.map { $0 < 0 ? $0 + 360 : $0 } ?? -1
        return CLLocation(
            coordinate: fix.coordinate,
            altitude: altitude,
            horizontalAccuracy: 5,
            verticalAccuracy: verticalAccuracy,
            course: course,
            courseAccuracy: course < 0 ? -1 : 5,
            speed: speed,
            speedAccuracy: fix.speed == nil ? -1 : 0.5,
            timestamp: Date()
        )
    }
}

// MARK: - Time zone

/// Asks iOS to re-derive the time zone from the location it now believes in.
///
/// With Date & Time set automatically, iOS follows the location — eventually.
/// Geranium posts this after every start and stop so the clock changes with
/// the teleport rather than whenever the system next gets round to it; a phone
/// in Tokyo still telling Paris time is the first thing that gives a spoof
/// away. A no-op when the time zone is set by hand.
enum TimeZoneFollower {
    static let defaultsKey = "locus.timeZoneFollows"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    static func requestUpdate() {
        guard isEnabled else { return }
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("AutomaticTimeZoneUpdateNeeded" as CFString),
            nil,
            nil,
            true
        )
    }
}

// MARK: - Reading our own signature

/// Entitlements of the running process, from the kernel's view of its code
/// signature.
///
/// `AppEntitlements` reads `embedded.mobileprovision`, which says what a
/// provisioning profile *allowed*. A TrollStore or jailbreak install has no
/// profile at all, and what counts there is what was actually signed in — so
/// this asks the Security framework about the task itself. The two functions
/// are public on macOS and present but undeclared on iOS, hence `dlsym`.
enum SelfEntitlements {
    private typealias CreateFromSelf = @convention(c) (OpaquePointer?) -> OpaquePointer?
    private typealias CopyValue = @convention(c) (OpaquePointer, OpaquePointer, OpaquePointer?) -> OpaquePointer?

    private static let functions: (CreateFromSelf, CopyValue)? = {
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW),
              let create = dlsym(handle, "SecTaskCreateFromSelf"),
              let copy = dlsym(handle, "SecTaskCopyValueForEntitlement") else { return nil }
        return (unsafeBitCast(create, to: CreateFromSelf.self), unsafeBitCast(copy, to: CopyValue.self))
    }()

    /// The entitlement's value, or `nil` when it isn't held or can't be read.
    static func value(_ name: String) -> Any? {
        guard let functions, let task = functions.0(nil) else { return nil }
        let copy = functions.1
        defer { Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(task)).release() }

        let key = name as CFString
        return withExtendedLifetime(key) { () -> Any? in
            let keyPointer = OpaquePointer(Unmanaged.passUnretained(key).toOpaque())
            guard let raw = copy(task, keyPointer, nil) else { return nil }
            return Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(raw)).takeRetainedValue()
        }
    }

    static func bool(_ name: String) -> Bool {
        (value(name) as? NSNumber)?.boolValue ?? false
    }
}

// MARK: - How this copy got here

/// What installed this copy, as far as it can tell. For the settings screen —
/// "direct mode is on because…" reads better with a reason, and "why isn't
/// it?" is answered by the same row.
///
/// Best effort throughout: a sandboxed app is not always allowed to look at
/// the paths that give a jailbreak away, and an unanswerable question falls
/// through to the plainer description rather than guessing.
enum InstallProvenance: Equatable {
    case trollStore
    case trollStoreLite
    /// Installed as a package into a rootless jailbreak's `/var/jb`.
    case jailbreakPackageRootless
    /// Installed as a package into a rootful jailbreak's `/Applications`.
    case jailbreakPackageRootful
    /// A jailbroken phone, the app installed some other way (AppSync, Filza).
    case jailbreakRootless
    case jailbreakRootful
    /// Holds the entitlement, and nothing says how it got it.
    case otherEntitled
    case sideloaded

    static let current: InstallProvenance = {
        let fm = FileManager.default
        let bundlePath = Bundle.main.bundleURL.resolvingSymlinksInPath().path

        // TrollStore drops a marker file beside the .app in the bundle
        // container — on a jailbroken phone too, when it was TrollStore that
        // installed it.
        let container = Bundle.main.bundleURL.deletingLastPathComponent()
        if fm.fileExists(atPath: container.appendingPathComponent("_TrollStore").path) { return .trollStore }
        if fm.fileExists(atPath: container.appendingPathComponent("_TrollStoreLite").path) { return .trollStoreLite }

        // A .deb puts the app where the package manager keeps applications.
        if bundlePath.hasPrefix("/var/jb/") || bundlePath.hasPrefix("/private/var/jb/") {
            return .jailbreakPackageRootless
        }
        if bundlePath.hasPrefix("/Applications/") { return .jailbreakPackageRootful }

        guard DirectLocationEngine.hasEntitlement else { return .sideloaded }

        // Rootless jailbreaks (Dopamine, palera1n, nathanlr) live under /var/jb.
        if fm.fileExists(atPath: "/var/jb/usr/bin") || fm.fileExists(atPath: "/var/jb/.installed_dopamine") {
            return .jailbreakRootless
        }
        // Rootful ones bootstrap into the root filesystem.
        for marker in ["/.bootstrapped", "/.installed_palera1n", "/Applications/Sileo.app", "/Applications/Cydia.app", "/Applications/Zebra.app"]
        where fm.fileExists(atPath: marker) {
            return .jailbreakRootful
        }
        return .otherEntitled
    }()

    var title: String {
        switch self {
        case .trollStore: return "TrollStore"
        case .trollStoreLite: return "TrollStore Lite"
        case .jailbreakPackageRootless: return "Jailbreak package (rootless)"
        case .jailbreakPackageRootful: return "Jailbreak package (rootful)"
        case .jailbreakRootless: return "Jailbroken (rootless)"
        case .jailbreakRootful: return "Jailbroken (rootful)"
        case .otherEntitled: return "Signed with the simulation entitlement"
        case .sideloaded: return "Sideloaded"
        }
    }

    var isJailbreak: Bool {
        switch self {
        case .jailbreakPackageRootless, .jailbreakPackageRootful, .jailbreakRootless, .jailbreakRootful: return true
        default: return false
        }
    }
}
