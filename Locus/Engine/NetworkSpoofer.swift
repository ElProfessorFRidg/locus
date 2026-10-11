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

    /// Whether the extension has been given the certificate since it last
    /// started. Re-sent whenever a reply says the listener isn't up.
    private var identitySent = false

    // MARK: - Setting and clearing

    func set(latitude: Double, longitude: Double) async -> Result<Void, LocationEngineError> {
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
            if !identitySent {
                command.leafCertificate = material.leaf
                command.leafPrivateKey = material.leafKey
            }
            guard let reply = await TunnelController.shared.exchange(InterceptEnvelope(intercept: command)) else {
                identitySent = false
                Self.active.value = false
                return .failure(.network("The tunnel didn’t answer."))
            }
            status = reply.intercept
            if reply.intercept?.listening == true {
                identitySent = true
                Self.active.value = true
                return .success(())
            }
            identitySent = false
        }
        Self.active.value = false
        return .failure(.network(status?.lastError ?? "The tunnel’s proxy didn’t start."))
    }

    func clear() async -> Result<Void, LocationEngineError> {
        Self.active.value = false
        guard TunnelController.shared.ownTunnelRunning else { return .success(()) }
        let command = InterceptCommand(enabled: false, latitude: 0, longitude: 0, accuracy: Self.accuracy)
        if let reply = await TunnelController.shared.exchange(InterceptEnvelope(intercept: command)) {
            status = reply.intercept
        }
        return .success(())
    }

    /// Re-reads the extension's counters, for the live numbers on the setup page.
    func refreshStatus() async {
        guard TunnelController.shared.ownTunnelRunning,
              let reply = await TunnelController.shared.exchange(InterceptEnvelope(intercept: nil)) else { return }
        status = reply.intercept
    }

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
            // A harmless position, only so the proxy exists to be tested. The
            // real coordinate replaces it on the next set.
            if !Self.active.value {
                let command = InterceptCommand(
                    enabled: true, latitude: 0, longitude: 0, accuracy: Self.accuracy,
                    leafCertificate: material.leaf, leafPrivateKey: material.leafKey
                )
                if let reply = await TunnelController.shared.exchange(InterceptEnvelope(intercept: command)) {
                    status = reply.intercept
                    identitySent = reply.intercept?.listening == true
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
