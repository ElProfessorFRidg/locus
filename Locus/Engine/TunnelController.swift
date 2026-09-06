import Darwin
import Foundation
import Network
import NetworkExtension

/// Drives Locus' own packet-tunnel extension (`LocusTunnel.appex`) so the
/// loopback tunnel the developer service needs can be brought up from inside
/// Locus, without launching LocalDevVPN by hand.
///
/// Three things make this more than a thin `startVPNTunnel` wrapper:
///
/// 1. **It finds its own extension at runtime.** The provider bundle ID is read
///    out of the embedded `.appex`, not hardcoded, so a re-signing tool that
///    rewrites bundle identifiers (ESign, Sideloadly, a wildcard profile) does
///    not silently leave the app looking for a manager that will never exist.
/// 2. **"Connected" means traffic actually flows.** `NEVPNStatus == .connected`
///    only says iOS accepted the tunnel; it says nothing about whether the utun
///    is bound to the current interface. Every connect is confirmed with a real
///    TCP probe to the loopback endpoint — the same thing the location engine is
///    about to do.
/// 3. **It walks the method ladder.** If the probe fails, the next packet-rewrite
///    strategy is tried automatically instead of leaving the user to guess which
///    one their carrier needs.
///
/// When the extension is missing entirely — LiveContainer, or a build stripped
/// of its plug-ins — `state` reports `.unavailable` and Locus falls back to
/// handing off to the LocalDevVPN app.
@MainActor
final class TunnelController: ObservableObject {
    static let shared = TunnelController()

    enum State: Equatable {
        case unavailable(String)
        case idle
        case connecting
        /// Tunnel is up *and* the probe confirmed traffic passes over `interface`.
        case connected(method: LocusTunnelMethod, interface: String)
        /// Tunnel reports connected but nothing goes through it, or it never came up.
        case failed(String)

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }

        var isBusy: Bool {
            if case .connecting = self { return true }
            return false
        }

        var isUnavailable: Bool {
            if case .unavailable = self { return true }
            return false
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastDiagnostics: [String] = []

    /// Bring the tunnel up on launch and whenever a teleport needs it.
    @Published var autoConnect: Bool {
        didSet { UserDefaults.standard.set(autoConnect, forKey: Keys.autoConnect) }
    }

    /// Let iOS keep the tunnel up on demand instead of only while Locus runs.
    /// Off by default: it is the difference between a VPN badge that shows up
    /// during a teleport and one that never goes away.
    @Published var onDemand: Bool {
        didSet {
            UserDefaults.standard.set(onDemand, forKey: Keys.onDemand)
            Task { await applyOnDemand() }
        }
    }

    /// The strategy to try first. The auto-search overwrites this with whatever
    /// actually worked, so the next launch starts from a known-good method.
    @Published var method: LocusTunnelMethod {
        didSet { UserDefaults.standard.set(method.rawValue, forKey: Keys.method) }
    }

    private enum Keys {
        static let autoConnect = "locus.tunnel.autoConnect"
        static let onDemand = "locus.tunnel.onDemand"
        static let method = "locus.tunnel.method"
    }

    private var manager: NETunnelProviderManager?

    private init() {
        autoConnect = UserDefaults.standard.object(forKey: Keys.autoConnect) as? Bool ?? true
        onDemand = UserDefaults.standard.bool(forKey: Keys.onDemand)
        method = UserDefaults.standard.string(forKey: Keys.method)
            .flatMap(LocusTunnelMethod.init(rawValue:)) ?? .default

        if let reason = Self.unavailableReason {
            state = .unavailable(reason)
        }
    }

    // MARK: - Availability

    /// The embedded extension's bundle identifier, read from the `.appex` itself
    /// rather than assumed, so re-signing that rewrites bundle IDs still works.
    static let providerBundleIdentifier: String? = {
        guard let plugins = Bundle.main.builtInPlugInsURL,
              let contents = try? FileManager.default.contentsOfDirectory(
                  at: plugins,
                  includingPropertiesForKeys: nil
              ) else { return nil }

        for url in contents where url.pathExtension == "appex" {
            guard let bundle = Bundle(url: url),
                  let info = bundle.infoDictionary?["NSExtension"] as? [String: Any],
                  info["NSExtensionPointIdentifier"] as? String == "com.apple.networkextension.packet-tunnel"
            else { continue }
            return bundle.bundleIdentifier
        }
        return nil
    }()

    nonisolated static var isEmbedded: Bool { providerBundleIdentifier != nil }

    nonisolated private static var unavailableReason: String? {
        #if targetEnvironment(simulator)
        return "Network extensions don’t run in the Simulator."
        #else
        if providerBundleIdentifier == nil {
            return "The built-in tunnel isn’t in this build. LiveContainer can’t load app extensions — use the LocalDevVPN app instead."
        }
        return nil
        #endif
    }

    /// True when the loopback address is already reachable, whoever put it there
    /// — Locus' own tunnel or the LocalDevVPN app. This is what the rest of the
    /// app asks before deciding a teleport can go ahead.
    nonisolated static var loopbackReachable: Bool {
        let addresses = ipv4InterfaceAddresses()
        let target = TunnelConfig.targetIP
        if addresses.contains(target) { return true }

        let parts = target.split(separator: ".")
        guard parts.count == 4 else { return false }
        let prefix = parts.dropLast().joined(separator: ".") + "."
        return addresses.contains { $0.hasPrefix(prefix) }
    }

    // MARK: - Connecting

    /// Ensures the loopback tunnel is usable, returning `true` if it is.
    ///
    /// Fast path first: if something already answers on the loopback subnet
    /// (LocalDevVPN, or a tunnel left up from an earlier run), nothing is started.
    @discardableResult
    func ensureConnected() async -> Bool {
        if Self.loopbackReachable {
            if !state.isConnected && !state.isUnavailable {
                state = .connected(method: method, interface: currentInterfaceLabel())
            }
            return true
        }
        guard Self.isEmbedded, !state.isUnavailable else { return false }
        return await connect()
    }

    /// Starts the tunnel and confirms it passes traffic, walking the method
    /// ladder when the first choice comes up connected-but-dead.
    @discardableResult
    func connect(autoSearch: Bool = true) async -> Bool {
        guard !state.isUnavailable, Self.isEmbedded else {
            state = .unavailable(Self.unavailableReason ?? "No embedded tunnel in this build.")
            return false
        }
        guard !state.isBusy else { return false }

        state = .connecting

        // Preferred method first, then the rest — never the same one twice.
        let ladder: [LocusTunnelMethod] = autoSearch
            ? [method] + LocusTunnelMethod.allCases.filter { $0 != method }
            : [method]

        for candidate in ladder {
            guard await start(method: candidate) else { continue }

            if await probe() {
                method = candidate
                state = .connected(method: candidate, interface: currentInterfaceLabel())
                refreshDiagnostics()
                return true
            }

            refreshDiagnostics()
            // Connected but nothing goes through: tear down before the next try,
            // or iOS keeps the dead utun and the next probe fails identically.
            await stop()
        }

        state = .failed(
            "The tunnel started but nothing reached \(TunnelConfig.targetIP). "
            + "Check that Locus is allowed to add a VPN configuration under "
            + "Settings › General › VPN & Device Management."
        )
        return false
    }

    func disconnect() async {
        await stop()
        if !state.isUnavailable { state = .idle }
    }

    // MARK: - Manager plumbing

    private func loadManager() async -> NETunnelProviderManager? {
        guard let providerID = Self.providerBundleIdentifier else { return nil }

        let existing: [NETunnelProviderManager]
        do {
            existing = try await NETunnelProviderManager.loadAllFromPreferences()
        } catch {
            state = .failed("Couldn’t read VPN configurations: \(error.localizedDescription)")
            return nil
        }

        let ours = existing.filter {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerID
        }

        // More than one saved configuration for the same provider makes the
        // status lookup ambiguous — keep the first, drop the rest.
        for duplicate in ours.dropFirst() {
            try? await duplicate.removeFromPreferences()
        }

        let manager = ours.first ?? NETunnelProviderManager()
        manager.localizedDescription = "Locus Tunnel"

        let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = providerID
        proto.serverAddress = "Locus loopback tunnel (\(TunnelConfig.targetIP))"
        proto.disconnectOnSleep = false
        manager.protocolConfiguration = proto
        manager.isEnabled = true
        manager.onDemandRules = onDemand ? Self.onDemandRules() : []
        manager.isOnDemandEnabled = onDemand

        do {
            // Save then reload: the connection object is only valid against a
            // freshly loaded manager, and starting from a stale one throws
            // NEVPNError.configurationInvalid.
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
        } catch {
            state = .failed(Self.describe(configurationError: error))
            return nil
        }

        self.manager = manager
        return manager
    }

    private static func onDemandRules() -> [NEOnDemandRule] {
        // This tunnel carries nothing but the device's own loopback traffic, so
        // "always" here is not the usual always-on VPN: it costs a VPN badge,
        // not any real routing. Still opt-in.
        let rule = NEOnDemandRuleConnect()
        rule.interfaceTypeMatch = .any
        return [rule]
    }

    private func applyOnDemand() async {
        guard Self.isEmbedded, let manager else { return }
        manager.onDemandRules = onDemand ? Self.onDemandRules() : []
        manager.isOnDemandEnabled = onDemand
        try? await manager.saveToPreferences()
        try? await manager.loadFromPreferences()
    }

    private func start(method candidate: LocusTunnelMethod) async -> Bool {
        guard let manager = await loadManager() else { return false }

        if manager.connection.status == .connected {
            return true
        }

        let options: [String: NSObject] = [
            "TunnelDeviceIP": TunnelConfig.deviceIP as NSObject,
            "TunnelFakeIP": TunnelConfig.targetIP as NSObject,
            "TunnelSubnetMask": TunnelConfig.subnetMask as NSObject,
            "TunnelMethod": candidate.rawValue as NSObject,
        ]

        do {
            try manager.connection.startVPNTunnel(options: options)
        } catch {
            state = .failed(Self.describe(configurationError: error))
            return false
        }

        return await waitForStatus(in: [.connected], timeout: 12)
    }

    private func stop() async {
        guard let manager, manager.connection.status != .disconnected else { return }
        manager.connection.stopVPNTunnel()
        _ = await waitForStatus(in: [.disconnected], timeout: 6)
    }

    /// Polls rather than listening for `NEVPNStatusDidChange`: the notification
    /// does not always fire for a manager this process just created, and the
    /// poll is bounded and cheap.
    private func waitForStatus(in targets: [NEVPNStatus], timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let manager else { return false }
            let status = manager.connection.status
            if targets.contains(status) { return true }
            if status == .invalid { return false }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }

    // MARK: - Probe

    /// Opens a real TCP connection to the loopback endpoint the location engine
    /// uses. `NEVPNStatus == .connected` is not evidence the utun is bound to the
    /// active interface; a completed handshake is.
    func probe(port: UInt16 = 49152, timeout: TimeInterval = 5) async -> Bool {
        let host = TunnelConfig.targetIP
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }

        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let gate = ProbeGate()

        let reachable = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if gate.claim() { continuation.resume(returning: true) }
                case .failed, .cancelled:
                    if gate.claim() { continuation.resume(returning: false) }
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if gate.claim() { continuation.resume(returning: false) }
            }
        }

        connection.cancel()
        return reachable
    }

    // MARK: - Diagnostics

    func refreshDiagnostics() {
        guard LocusTunnelStatusFile.isAvailable else {
            lastDiagnostics = [
                "The App Group isn’t reachable from this build, so the tunnel extension’s own log can’t be read. "
                + "Re-signing tools often strip App Group entitlements; everything else still works."
            ]
            return
        }
        lastDiagnostics = Array(LocusTunnelStatusFile.readAll().suffix(60))
    }

    func currentInterfaceLabel() -> String {
        let names = Self.ipv4InterfaceNames()
        if names.contains(where: { $0.hasPrefix("pdp_ip") }) { return "Cellular" }
        if names.contains(where: { $0.hasPrefix("en") }) { return "Wi-Fi" }
        return "Unknown"
    }

    private static func describe(configurationError error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NEVPNErrorDomain,
           ns.code == NEVPNError.Code.configurationReadWriteFailed.rawValue {
            return "iOS refused to save the VPN profile. Approve the Locus VPN configuration when prompted, "
                + "or remove an old one under Settings › General › VPN & Device Management."
        }
        return error.localizedDescription
    }

    // MARK: - Interface enumeration

    nonisolated static func ipv4InterfaceAddresses() -> [String] {
        enumerateIPv4 { addr, _ in
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                addr,
                socklen_t(MemoryLayout<sockaddr_in>.size),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else { return nil }
            return String(cString: host)
        }
    }

    nonisolated static func ipv4InterfaceNames() -> [String] {
        enumerateIPv4 { _, name in name }
    }

    nonisolated private static func enumerateIPv4(
        _ transform: (UnsafeMutablePointer<sockaddr>, String) -> String?
    ) -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, head != nil else { return [] }
        defer { freeifaddrs(head) }

        var results: [String] = []
        var cursor = head
        while let current = cursor {
            let interface = current.pointee
            cursor = interface.ifa_next

            guard let addr = interface.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            if let value = transform(addr, String(cString: interface.ifa_name)) {
                results.append(value)
            }
        }
        return results
    }
}

/// Resumes-once guard for the tunnel probe. `stateUpdateHandler` and the timeout
/// race each other, and resuming a continuation twice is a crash rather than a
/// warning — so the winner is decided under a lock. File scope, not nested, so
/// it carries no actor isolation into the background queue the probe runs on.
private final class ProbeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
