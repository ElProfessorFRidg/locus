import Foundation
import idevice

enum LocationEngineError: LocalizedError {
    case invalidIP
    case pairingRead
    case tunnelCreate
    case remoteServer
    case simulationCreate
    case locationSet
    case locationClear
    case notActive
    /// The direct engine was asked to work in a copy that can't: no
    /// `com.apple.locationd.simulation` entitlement, or no `CLSimulationManager`.
    case directUnavailable
    /// The direct engine asked `locationd` and got no answer in time.
    case directTimedOut
    /// Network mode: the message is already a sentence.
    case network(String)

    var errorDescription: String? {
        switch self {
        case .invalidIP: return "Tunnel IP is invalid. Check Settings → Tunnel IP (usually 10.7.0.1)."
        case .pairingRead: return "Could not read the RPPairing file. Generate one with idevice_pair in RPPairing mode."
        case .tunnelCreate: return "Could not open the developer tunnel. Check that the loopback tunnel is connected — Locus' own, or the LocalDevVPN app — and try the first teleport on Wi‑Fi."
        case .remoteServer: return "Connected to the tunnel but RemoteXPC handshake failed."
        case .simulationCreate: return "Could not open Apple’s location simulation service."
        case .locationSet: return "Failed to set simulated coordinates."
        case .locationClear: return "Failed to clear simulated location."
        case .notActive: return "No active simulation session."
        case .directUnavailable: return "This copy of Locus can’t set the location directly — it wasn’t installed with the location-simulation entitlement (TrollStore or a jailbreak). Turn off direct simulation in Settings to use the developer tunnel instead."
        case .directTimedOut: return "locationd didn’t answer in time. Try again — this is usually momentary, right after install or around a lock/unlock."
        case .network(let message): return message
        }
    }

    static func from(code: Int32) -> LocationEngineError {
        switch code {
        case 1: return .invalidIP
        case 2: return .pairingRead
        case 3: return .tunnelCreate
        case 9: return .remoteServer
        case 10: return .simulationCreate
        case 11: return .locationSet
        case 12: return .locationClear
        default: return .locationSet
        }
    }
}

/// Sets and clears the simulated location, through whichever method
/// `SpoofBackend.current` names: idevice's DVT location simulation (injects into
/// locationd), or network mode's rewrite of Apple's positioning replies.
enum LocationEngine {
    private static let queue = DispatchQueue(label: "com.chrismack.locus.location", qos: .userInitiated)

    private static var adapter: OpaquePointer?
    private static var handshake: OpaquePointer?
    private static var remoteServer: OpaquePointer?
    private static var locationSimulation: OpaquePointer?

    private static let ok: Int32 = 0
    private static let invalidIP: Int32 = 1
    private static let pairingRead: Int32 = 2
    private static let tunnelCreate: Int32 = 3
    private static let remoteServerCode: Int32 = 9
    private static let simulationCreate: Int32 = 10
    private static let locationSet: Int32 = 11
    private static let locationClear: Int32 = 12

    static var isSessionActive: Bool {
        switch SpoofBackend.current {
        case .developer: return locationSimulation != nil
        case .network: return NetworkSpoofer.active.value
        case .both: return locationSimulation != nil || NetworkSpoofer.active.value
        }
    }

    /// In `both`, where network mode last pointed and when. A route sends a fix
    /// up to four times a second; network mode only matters for where iOS next
    /// asks Apple, so it is told about a move only when the fix has gone far
    /// enough, or long enough, to matter.
    private static let networkPush = NetworkPush()

    final class NetworkPush: @unchecked Sendable {
        private let lock = NSLock()
        private var last: (latitude: Double, longitude: Double, at: Date)?

        func isDue(latitude: Double, longitude: Double) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard let last else { return true }
            let metresPerDegree = 111_000.0
            let dLat = (latitude - last.latitude) * metresPerDegree
            let dLon = (longitude - last.longitude) * metresPerDegree * cos(latitude * .pi / 180)
            return (dLat * dLat + dLon * dLon).squareRoot() > 150 || Date().timeIntervalSince(last.at) > 30
        }

        func record(latitude: Double, longitude: Double) {
            lock.lock()
            last = (latitude, longitude, Date())
            lock.unlock()
        }

        func reset() {
            lock.lock()
            last = nil
            lock.unlock()
        }
    }

    /// Sends a coordinate to the device.
    ///
    /// Async, and that is the point. This is a network round trip over the
    /// tunnel — and the *first* call is the whole handshake: pairing file,
    /// tunnel, RemoteXPC, the simulation service. It used to run under
    /// `queue.sync` from a `@MainActor` caller, so every fix blocked the main
    /// thread for the length of that round trip, up to four times a second
    /// while a route played, and the first teleport froze the UI for as long as
    /// the handshake took. Hopping onto the queue and suspending instead leaves
    /// the main thread free to draw the map it is being asked to move.
    ///
    /// The serial queue still serialises the FFI, so the C-side session state is
    /// touched by exactly one caller at a time, exactly as before.
    static func set(latitude: Double, longitude: Double, pairingPath: String, deviceIP: String) async -> Result<Void, LocationEngineError> {
        let backend = SpoofBackend.current
        if backend == .network {
            return await NetworkSpoofer.shared.set(latitude: latitude, longitude: longitude)
        }
        let developer: Result<Void, LocationEngineError> = await withCheckedContinuation { continuation in
            queue.async {
                let code = setLocked(latitude: latitude, longitude: longitude, pairingPath: pairingPath, deviceIP: deviceIP)
                continuation.resume(returning: code == ok ? .success(()) : .failure(.from(code: code)))
            }
        }
        // In `both` the developer service is what the fix depends on, so its
        // result is the answer; network mode is best-effort underneath and its
        // failures show up in Settings › Network mode rather than stopping a
        // spoof that is working.
        if backend == .both, case .success = developer,
           networkPush.isDue(latitude: latitude, longitude: longitude) {
            networkPush.record(latitude: latitude, longitude: longitude)
            if case .failure = await NetworkSpoofer.shared.set(latitude: latitude, longitude: longitude) {
                networkPush.reset()
            }
        }
        return developer
    }

    /// - Parameters: where to reconnect if the developer session has gone —
    ///   without them, a Stop after the session dropped could only report an
    ///   error while the phone stayed wherever it was last sent.
    static func clear(pairingPath: String? = nil, deviceIP: String = TunnelConfig.targetIP) async -> Result<Void, LocationEngineError> {
        // Both, whatever is selected: a person who switched method mid-spoof
        // still expects Stop to stop it.
        networkPush.reset()
        let backend = SpoofBackend.current
        let networkInvolved = NetworkSpoofer.active.value || backend.usesNetwork
        if backend == .network {
            return await NetworkSpoofer.shared.clear()
        }

        // The developer service first: it is what puts the real position back,
        // and it answers in a moment. Turning network mode off waits out the DNS
        // cache on purpose (several seconds), so in `both` it finishes behind
        // the Stop rather than holding the button up.
        let developer: Result<Void, LocationEngineError> = await withCheckedContinuation { continuation in
            queue.async {
                let code = clearLocked(pairingPath: pairingPath, deviceIP: deviceIP)
                continuation.resume(returning: code == ok ? .success(()) : .failure(.from(code: code)))
            }
        }
        if networkInvolved {
            Task { _ = await NetworkSpoofer.shared.clear() }
        }
        return developer
    }

    private static func cleanup() {
        if let locationSimulation {
            location_simulation_free(locationSimulation)
            self.locationSimulation = nil
        }
        if let remoteServer {
            remote_server_free(remoteServer)
            self.remoteServer = nil
        }
        if let handshake {
            rsd_handshake_free(handshake)
            self.handshake = nil
        }
        if let adapter {
            adapter_free(adapter)
            self.adapter = nil
        }
    }

    private static func setLocked(latitude: Double, longitude: Double, pairingPath: String, deviceIP: String) -> Int32 {
        if let locationSimulation {
            if let err = location_simulation_set(locationSimulation, latitude, longitude) {
                idevice_error_free(err)
                cleanup()
            } else {
                return ok
            }
        }

        let connected = connectLocked(pairingPath: pairingPath, deviceIP: deviceIP)
        guard connected == ok else { return connected }

        if let setError = location_simulation_set(locationSimulation, latitude, longitude) {
            idevice_error_free(setError)
            cleanup()
            return locationSet
        }
        return ok
    }

    /// A fresh developer session: tunnel handshake, RemoteXPC, the simulation
    /// service. Leaves `locationSimulation` set on success.
    private static func connectLocked(pairingPath: String, deviceIP: String) -> Int32 {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(49152).bigEndian
        let inetResult = deviceIP.withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
        guard inetResult == 1 else { return invalidIP }

        var pairingHandle: OpaquePointer?
        if let pairingError = pairingPath.withCString({ rp_pairing_file_read($0, &pairingHandle) }) {
            idevice_error_free(pairingError)
            return pairingRead
        }
        guard let pairingHandle else { return pairingRead }
        defer { rp_pairing_file_free(pairingHandle) }

        let providerError = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                tunnel_create_rppairing(
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.stride),
                    "LocusLocation",
                    pairingHandle,
                    nil,
                    nil,
                    &adapter,
                    &handshake
                )
            }
        }
        if let providerError {
            idevice_error_free(providerError)
            cleanup()
            return tunnelCreate
        }

        if let remoteServerError = remote_server_connect_rsd(adapter, handshake, &remoteServer) {
            idevice_error_free(remoteServerError)
            cleanup()
            return remoteServerCode
        }

        if let simError = location_simulation_new(remoteServer, &locationSimulation) {
            idevice_error_free(simError)
            cleanup()
            return simulationCreate
        }
        // Dropped rather than freed. `location_simulation_new` is *not* documented
        // as consuming its server — the header says so explicitly where it is
        // true (`remote_server_new`: "It is consumed and may not be used again")
        // and says nothing of the sort here — so this most likely leaks one
        // `RemoteServerHandle`, and the connection behind it, per handshake. It
        // is left alone deliberately: freeing a handle the Rust side did take
        // ownership of is a double free rather than a leak, and that cannot be
        // settled from the header alone. Check it against the idevice revision
        // this library was built from before changing it; if it borrows, the fix
        // is to keep the pointer and let `cleanup()` free it after the
        // simulation, which is already the order it frees in.
        remoteServer = nil
        return ok
    }

    /// Clears the simulated location, reconnecting when it has to. The session
    /// handle goes stale whenever the tunnel restarts or the app is relaunched
    /// mid-spoof, but the device keeps simulating — so "no handle" or "the
    /// handle failed" mean "connect and clear", not "nothing to do".
    private static func clearLocked(pairingPath: String?, deviceIP: String) -> Int32 {
        if let locationSimulation {
            let err = location_simulation_clear(locationSimulation)
            cleanup()
            guard let err else { return ok }
            idevice_error_free(err)
        }
        guard let pairingPath else { return locationClear }

        let connected = connectLocked(pairingPath: pairingPath, deviceIP: deviceIP)
        guard connected == ok, let locationSimulation else { return connected == ok ? locationClear : connected }
        let err = location_simulation_clear(locationSimulation)
        cleanup()
        if let err {
            idevice_error_free(err)
            return locationClear
        }
        return ok
    }
}
