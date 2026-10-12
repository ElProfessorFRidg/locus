import Foundation
import Network
import Security

/// The app's side of network mode: keeps the tunnel extension told where "here"
/// is, and checks that the whole path — DNS, the packet loop, the proxy's TLS —
/// actually works on this device.
///
/// There is no session to hold open the way the developer service has one. The
/// extension keeps answering with whatever coordinate it was last given, so
/// "setting a location" is one small message and "stopping" is another.
@MainActor
final class NetworkSpoofer: ObservableObject {
    static let shared = NetworkSpoofer()

    /// Accuracy written into every rewritten location, in metres. Tight enough
    /// to look like a good fix, loose enough not to look like a lab.
    static let accuracy = 30

    @Published private(set) var status: InterceptStatus?
    @Published private(set) var checks: [Check] = []
    @Published private(set) var isChecking = false

    enum Check: Identifiable, Equatable {
        case passed(String, String)
        case failed(String, String)

        var id: String {
            switch self {
            case .passed(let title, _), .failed(let title, _): return title
            }
        }
    }

    /// Whether a spoof is in force, readable from any thread — the engine's
    /// `isSessionActive` is.
    nonisolated static let active = Flag()

    /// Which certificate the extension was last given (by creation date), so a
    /// regenerated one is sent again instead of the extension carrying on with
    /// a leaf iOS no longer trusts. Cleared whenever a reply says the listener
    /// isn't up — a restarted extension has no certificate at all.
    private var sentIdentity: Date?

    // MARK: - Setting and clearing

    /// When the coordinate last changed, to tell a reply rewritten for *this*
    /// spoof from one rewritten for the last.
    private var targetChangedAt: Date?
    private var lastTarget: (latitude: Double, longitude: Double)?

    /// Whether iOS has fetched — and been given — a rewritten reply since the
    /// coordinate was last set. Until then the phone hasn't moved, whatever the
    /// app has asked for.
    var hasTakenEffect: Bool {
        guard let rewrite = status?.lastRewrite else { return false }
        guard let changed = targetChangedAt else { return true }
        return rewrite >= changed
    }

    /// Set and clear run one at a time, in the order asked. Each awaits the
    /// extension, so on the main actor they would otherwise interleave, and a
    /// late reply from an old `set` could mark the spoof active after `clear`.
    private var queueTail: Task<Void, Never>?
    /// Bumped by `clear`, so a `set` that was already waiting its turn (the
    /// resend timer's, typically) doesn't switch the spoof back on after Stop.
    private var clearGeneration = 0

    private func serialized<T>(_ work: @escaping @MainActor () async -> T) async -> T {
        let previous = queueTail
        let task = Task { @MainActor () -> T in
            await previous?.value
            return await work()
        }
        queueTail = Task { _ = await task.value }
        return await task.value
    }

    func set(latitude: Double, longitude: Double) async -> Result<Void, LocationEngineError> {
        let generation = clearGeneration
        return await serialized { [self] in
            guard generation == clearGeneration else { return .failure(.network("Stopped.")) }
            return await performSet(latitude: latitude, longitude: longitude)
        }
    }

    private func performSet(latitude: Double, longitude: Double) async -> Result<Void, LocationEngineError> {
        if lastTarget?.latitude != latitude || lastTarget?.longitude != longitude {
            lastTarget = (latitude, longitude)
            targetChangedAt = Date()
        }
        do {
            try InterceptIdentity.shared.ensureCreated()
        } catch {
            return .failure(.network("Couldn’t create the certificate: \(error.localizedDescription)"))
        }
        let identity = InterceptIdentity.shared
        identity.refreshTrust()
        guard identity.trust == .trusted, let material = identity.material else {
            return .failure(.network("iOS doesn’t trust the Locus certificate yet. Settings → Network mode walks through it."))
        }
        guard await TunnelController.shared.ensureOwnTunnel() else {
            return .failure(.network(
                "Locus’ own tunnel isn’t running. Network mode can’t use LocalDevVPN — it needs the tunnel built into Locus."
            ))
        }

        // Twice: a fresh extension has no certificate yet, which only shows up
        // as a reply saying the listener isn't running.
        for _ in 0..<2 {
            var command = InterceptCommand(enabled: true, latitude: latitude, longitude: longitude, accuracy: Self.accuracy)
            if sentIdentity != material.created {
                command.leafCertificate = material.leaf
                command.leafPrivateKey = material.leafKey
            }
            guard let reply = await TunnelController.shared.exchange(InterceptEnvelope(intercept: command)) else {
                sentIdentity = nil
                Self.active.value = false
                let why = await explainSilence()
                return .failure(.network("The tunnel didn’t answer. \(why)"))
            }
            status = reply.intercept
            if Self.isInForce(reply) {
                sentIdentity = material.created
                Self.active.value = true
                return .success(())
            }
            lastReplyError = reply.commandError
            sentIdentity = nil
        }
        Self.active.value = false
        return .failure(.network(lastReplyError ?? status?.lastError ?? "The tunnel’s proxy didn’t start."))
    }

    private var lastReplyError: String?

    /// No reply at all almost always means iOS ended the extension mid-command.
    /// Bring it back up and ask the new run what the old one was doing.
    private func explainSilence() async -> String {
        let fallback = TunnelController.shared.lastExchangeFailure ?? ""
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        guard await TunnelController.shared.ensureOwnTunnel(),
              let reply = await TunnelController.shared.exchange(InterceptEnvelope(intercept: nil)) else {
            return fallback
        }
        status = reply.intercept
        guard let step = reply.previousRunStoppedDuring else { return fallback }
        let memory = reply.memoryAvailableMB.map { " It now has \($0) MB to spare." } ?? ""
        return "iOS stopped the tunnel extension while \(step).\(memory)"
    }

    /// Listening alone isn't a spoof: the DNS override has to be in force too.
    /// Replies from an older extension don't say, and are judged on listening.
    private static func isInForce(_ reply: TunnelReply) -> Bool {
        reply.intercept?.listening == true
            && reply.intercepting != false
            && reply.dnsApplied != false
    }

    func clear() async -> Result<Void, LocationEngineError> {
        Self.active.value = false
        clearGeneration += 1
        return await serialized { [self] in
            Self.active.value = false
            guard TunnelController.shared.ownTunnelRunning else { return .success(()) }
            let command = InterceptCommand(enabled: false, latitude: 0, longitude: 0, accuracy: Self.accuracy)
            if let reply = await TunnelController.shared.exchange(InterceptEnvelope(intercept: command)) {
                status = reply.intercept
            }
            return .success(())
        }
    }

    /// A spoof the extension is still carrying from before the app was closed:
    /// it doesn't need the app to keep going, so on launch the app asks rather
    /// than reporting "not spoofing" over one that is in force.
    func adoptRunning() async -> (latitude: Double, longitude: Double)? {
        await refreshStatus()
        guard let status, status.listening, lastIsInForce,
              let latitude = status.latitude, let longitude = status.longitude else { return nil }
        // The extension keeps the identity it was given; only the app forgot.
        sentIdentity = InterceptIdentity.shared.material?.created
        lastTarget = (latitude, longitude)
        targetChangedAt = nil
        Self.active.value = true
        return (latitude, longitude)
    }

    /// Re-reads the extension's counters, for the live numbers on the setup page.
    func refreshStatus() async {
        guard TunnelController.shared.ownTunnelRunning,
              let reply = await TunnelController.shared.exchange(InterceptEnvelope(intercept: nil)) else { return }
        status = reply.intercept
        lastIsInForce = Self.isInForce(reply)
    }

    private var lastIsInForce = false

    // MARK: - Self-test

    /// Walks the path a location request takes and says where it breaks, which
    /// is the difference between "it doesn't work" and something to act on.
    func runChecks() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        var results: [Check] = []

        let identity = InterceptIdentity.shared
        identity.refreshTrust()
        switch identity.trust {
        case .trusted:
            results.append(.passed("Certificate", "Installed and trusted by iOS."))
        case .notTrusted:
            results.append(.failed("Certificate", "Created but not trusted. Install it, then switch it on under Settings › General › About › Certificate Trust Settings."))
        case .notCreated:
            results.append(.failed("Certificate", "Not created yet."))
        }

        let tunnelUp = await TunnelController.shared.ensureOwnTunnel()
        results.append(tunnelUp
            ? .passed("Tunnel", "Locus’ own tunnel is running.")
            : .failed("Tunnel", "Locus’ own tunnel isn’t running — LocalDevVPN can’t do network mode."))

        if tunnelUp, identity.trust == .trusted, let material = identity.material {
            // Interception on, rewriting off: the proxy exists to be tested, and
            // any reply iOS happens to fetch meanwhile goes through untouched.
            if !Self.active.value {
                var command = InterceptCommand(enabled: true, latitude: nil, longitude: nil, accuracy: Self.accuracy)
                // Only what the extension doesn't already hold: resending an
                // unchanged certificate rewrites its keychain items and restarts
                // the listener for nothing.
                if sentIdentity != material.created {
                    command.leafCertificate = material.leaf
                    command.leafPrivateKey = material.leafKey
                }
                if let reply = await TunnelController.shared.exchange(InterceptEnvelope(intercept: command)) {
                    status = reply.intercept
                    sentIdentity = Self.isInForce(reply) ? material.created : nil
                }
            }

            let resolved = await Self.resolve(InterceptConfig.hosts[0])
            let tunnelAddress = TunnelConfig.targetIP
            if resolved == tunnelAddress {
                results.append(.passed("DNS", "\(InterceptConfig.hosts[0]) resolves to the tunnel."))
            } else {
                results.append(.failed("DNS", "\(InterceptConfig.hosts[0]) resolves to \(resolved ?? "nothing"), not \(tunnelAddress). If network mode was only just switched on, wait a few seconds — iOS caches answers briefly."))
            }

            if await Self.handshakeSucceeds(host: tunnelAddress, serverName: InterceptConfig.hosts[0]) {
                results.append(.passed("Proxy", "A TLS connection through the tunnel reached the proxy."))
            } else {
                results.append(.failed("Proxy", "Couldn’t reach the proxy through the tunnel. Try another tunnel method in Settings → Tunnel."))
            }

            if !Self.active.value { _ = await clear() }
        }

        await refreshStatus()
        checks = results
    }

    private nonisolated static func resolve(_ host: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo()
                hints.ai_family = AF_INET
                hints.ai_socktype = SOCK_STREAM
                var result: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
                    continuation.resume(returning: nil)
                    return
                }
                defer { freeaddrinfo(result) }
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                first.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                    var address = pointer.pointee.sin_addr
                    inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN))
                }
                continuation.resume(returning: String(cString: buffer))
            }
        }
    }

    /// Completes a TLS handshake with whatever answers on `host:443`, accepting
    /// any certificate: this tests the path, not the trust, which has its own row.
    private nonisolated static func handshakeSucceeds(host: String, serverName: String) async -> Bool {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, serverName)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, .global())
        let connection = NWConnection(
            host: NWEndpoint.Host(host), port: 443,
            using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        )
        let ok: Bool = await withCheckedContinuation { continuation in
            let once = Flag()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume(returning: true) }
                case .failed, .waiting, .cancelled:
                    if once.claim() { continuation.resume(returning: false) }
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 6) {
                if once.claim() { continuation.resume(returning: false) }
            }
        }
        connection.cancel()
        return ok
    }

    /// A lock-protected Bool, readable and settable from any thread.
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = false

        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }

        /// `true` for the first caller only.
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if stored { return false }
            stored = true
            return true
        }
    }
}
