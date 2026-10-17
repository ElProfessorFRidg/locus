import Combine
import Darwin
import Foundation

/// Mirrors the session into `/var/jb/var/locate-ipad/` for whatever is
/// driving the phone from outside.
///
/// Best effort in every direction: the directory may not exist, may not be
/// writable (a copy without the entitlement exception), or may vanish under
/// us, and in every case the app carries on exactly as before. Nothing here
/// ever reaches the UI.
@MainActor
final class RemoteStateWriter {
    static let shared = RemoteStateWriter()

    private var session: SpoofSession?
    private var cancellables = Set<AnyCancellable>()
    private var heartbeat: Timer?
    private var last: RemoteState?

    /// Serial, off the main thread, and in order: writes are small but a file
    /// system is allowed to be slow.
    private let queue = DispatchQueue(label: "com.chrismack.locus.remotestate", qos: .utility)

    func start(session: SpoofSession) {
        guard self.session == nil else { return }
        self.session = session

        // Any change to the session — status, the simulated position, a route
        // starting or stopping. Hopped to the next main-queue turn first:
        // `objectWillChange` fires *before* the value changes. At most once a
        // second, with the latest, which is what bounds the position updates.
        session.objectWillChange
            .receive(on: DispatchQueue.main)
            .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in self?.write(force: false) }
            .store(in: &cancellables)

        // Even when nothing changes: a reader tells "idle" from "the app is
        // gone" by `ts` going stale.
        heartbeat = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.write(force: true) }
        }

        session.routeStore.$routes
            .receive(on: DispatchQueue.main)
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] routes in self?.writeRoutes(routes) }
            .store(in: &cancellables)

        write(force: true)
    }

    /// For events that should reach the file without waiting out the throttle,
    /// like a command's result.
    func writeNow() { write(force: true) }

    /// The state as it is this instant, written out too.
    func currentState() -> RemoteState? {
        guard let session else { return nil }
        let state = snapshot(session)
        last = state
        if let data = try? state.jsonData() { persist(data, as: "locus-state.json") }
        return state
    }

    /// A file under `results/`, created on demand; silent on failure.
    func persistResult(_ data: Data, id: String) {
        persist(data, as: "results/\(id).json")
    }

    // MARK: - state

    private func write(force: Bool) {
        guard let session else { return }
        let state = snapshot(session)
        if !force, let last, last.sameContent(as: state) { return }
        last = state
        guard let data = try? state.jsonData() else { return }
        persist(data, as: "locus-state.json")
    }

    private func snapshot(_ session: SpoofSession) -> RemoteState {
        let status: String
        switch session.status {
        case .idle: status = "idle"
        case .connecting: status = "connecting"
        case .active: status = "active"
        case .reconnecting: status = "reconnecting"
        case .dropped: status = "dropped"
        }

        let mode: String
        if session.isRouting {
            mode = "route"
        } else if session.joystickActive {
            mode = "joystick"
        } else if session.isSpoofing {
            mode = "teleport"
        } else {
            mode = "idle"
        }

        // As sent to the engine: the map's datum undone, so this is WGS-84.
        let position = session.simulated.map { coordinate -> RemoteState.Position in
            let wire = MapDatumMode.current.toWGS84(coordinate)
            return RemoteState.Position(lat: Self.round(wire.latitude, places: 7), lon: Self.round(wire.longitude, places: 7))
        }

        let profile = session.activeProfile
        var route: RemoteState.Route?
        var speed: Double?
        if session.isRouting, let telemetry = session.telemetry {
            route = RemoteState.Route(
                name: session.lastRouteName,
                progressPct: Self.round((telemetry.progress * 100).clamped(to: 0...100), places: 1),
                paused: session.isRoutePaused
            )
            // What the phone is told: the walker's speed at playback pace.
            speed = Self.round(telemetry.speed * profile.timeScaleClamped * 3.6, places: 1)
        } else if let joystick = session.joystick {
            speed = Self.round(joystick.speed * 3.6, places: 1)
        }

        let direct = session.backend == .direct
        let tunnel: String
        if direct {
            tunnel = "direct"
        } else if session.backend.needsTunnel {
            tunnel = TunnelController.loopbackReachable ? "up" : "down"
        } else {
            tunnel = "n/a"
        }

        let probe = LocationProbe.shared.reading
        let readout = LocationReadout.shared
        let badge = readout.badge(session: session)
        let reported = probe.map {
            RemoteState.Reported(
                lat: Self.round($0.coordinate.latitude, places: 7),
                lon: Self.round($0.coordinate.longitude, places: 7),
                accuracy: $0.horizontalAccuracy,
                isSimulatedBySoftware: $0.isSimulatedBySoftware
            )
        }
        let real = readout.lastReal.map {
            RemoteState.RealFix(
                lat: Self.round($0.lat, places: 7), lon: Self.round($0.lon, places: 7), accuracy: $0.accuracy
            )
        }

        return RemoteState(
            ts: Int(Date().timeIntervalSince1970),
            engine: direct ? "direct" : "tunnel",
            status: status,
            simulating: session.isSpoofing,
            mode: mode,
            position: position,
            route: route,
            speedKmh: speed,
            loop: route == nil ? nil : Self.loopCode(profile.endBehavior),
            timeScale: route == nil ? nil : profile.timeScaleClamped,
            profile: route == nil ? nil : profile.name,
            tunnel: tunnel,
            lastCommand: RemoteControl.shared.lastCommand,
            error: session.lastError,
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            badge: badge.rawValue,
            real: real,
            reportedByCoreLocation: reported
        )
    }

    private static func loopCode(_ end: RouteEndBehavior) -> Int {
        switch end {
        case .stop: return 0
        case .loop: return 1
        case .pingPong: return 2
        case .reverseOnce: return 3
        }
    }

    private static func round(_ value: Double, places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (value * factor).rounded() / factor
    }

    // MARK: - routes

    private func writeRoutes(_ routes: [SavedRoute]) {
        let entries = routes.map { route in
            RemoteRouteEntry(
                id: route.id.uuidString,
                name: route.name,
                journey: route.journey,
                distanceM: Self.round(route.distance, places: 1),
                timesDriven: route.driveCount,
                lastDriven: route.lastDrivenAt.map { Int($0.timeIntervalSince1970) }
            )
        }
        guard let data = try? RemoteRouteEntry.jsonData(entries) else { return }
        persist(data, as: "locus-routes.json")
    }

    // MARK: - files

    /// Temp file, then `rename(2)`: a reader never sees half a file. Silent on
    /// every failure.
    private func persist(_ data: Data, as name: String) {
        queue.async {
            let directory = RemoteKey.directory
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return }
            let destination = directory + name
            let temporary = destination + ".tmp"
            if let slash = name.lastIndex(of: "/") {
                // One level down, made when missing.
                let sub = directory + name[..<slash]
                if !FileManager.default.fileExists(atPath: sub) {
                    try? FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: false,
                                                             attributes: [.posixPermissions: 0o755])
                }
            }
            do {
                try data.write(to: URL(fileURLWithPath: temporary))
            } catch {
                return
            }
            chmod(temporary, 0o644)
            if rename(temporary, destination) != 0 {
                unlink(temporary)
            }
        }
    }
}
