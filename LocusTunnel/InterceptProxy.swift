//
//  InterceptProxy.swift
//  LocusTunnel
//
//  The other half of network mode. The tunnel steers iOS' "where is this Wi-Fi
//  access point?" HTTPS requests to `10.7.0.1:443`, which the packet loop turns
//  into a connection to this listener. Here the request is answered by being
//  forwarded to the real Apple server, and the reply — and only the reply to
//  `/clls/wloc` — has its coordinates rewritten on the way back.
//
//  Three rules keep it from being more than that:
//    - it only ever talks to the hosts in `InterceptConfig.hosts`, so it cannot
//      be used as an open relay by whatever else on the device finds the port;
//    - it never trusts the system resolver, which is the very thing pointing at
//      this tunnel; the real address comes from a public resolver instead;
//    - anything it cannot parse, it passes through untouched.
//

import Foundation
import Network
import os.log
import Security

// MARK: - Proxy

final class InterceptProxy: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.chrismack.locus.tunnel.intercept")
    private let lock = NSLock()
    private let resolver = UpstreamResolver()
    private let log: (String) -> Void

    private var listener: NWListener?
    private var target: WLocRewriter.Target?
    private var status = InterceptStatus()
    private var reportedUnparsed = false

    init(log: @escaping (String) -> Void) {
        self.log = log
    }

    var isRunning: Bool { locked { listener != nil } }

    func snapshot() -> InterceptStatus { locked { status } }

    func setTarget(_ target: WLocRewriter.Target?) {
        locked {
            self.target = target
            status.latitude = target?.latitude
            status.longitude = target?.longitude
        }
    }

    func noteDNSAnswered() {
        locked { status.dnsAnswered += 1 }
    }

    /// Addresses the real hosts resolve to, found through the system resolver
    /// *before* the tunnel starts answering for them.
    func primeResolver() async {
        await resolver.prime(hosts: InterceptConfig.hosts)
    }

    /// Starts listening with `identity` as the server certificate. Returns once
    /// the listener is ready or has failed.
    func start(identity: SecIdentity, bindAddress: String) async -> Bool {
        if isRunning { return true }
        guard let secIdentity = sec_identity_create(identity) else {
            fail("couldn't wrap the certificate identity")
            return false
        }

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.allowLocalEndpointReuse = true

        // Bound to the tunnel's own address, not every interface: the packet loop
        // delivers the steered connections there, and nothing else on the Wi-Fi
        // should be able to reach (or relay through) this port.
        guard let port = NWEndpoint.Port(rawValue: InterceptConfig.listenPort),
              let address = IPv4Address(bindAddress) else {
            fail("bad listen address \(bindAddress)")
            return false
        }
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(address), port: port)

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            fail("couldn't listen on \(InterceptConfig.listenPort): \(error.localizedDescription)")
            return false
        }

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            Task { await self.serve(connection) }
        }

        let ready = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let gate = OnceGate()
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                switch state {
                case .ready:
                    if gate.claim() { continuation.resume(returning: true) }
                case .failed(let error):
                    self?.fail("listener failed: \(error.localizedDescription)")
                    // Only this listener's own failure may take the running state
                    // away: a different one that never became current must not
                    // orphan the one that did.
                    self?.locked {
                        guard let self, let listener, self.listener === listener else { return }
                        self.listener = nil
                        self.status.listening = false
                    }
                    if gate.claim() { continuation.resume(returning: false) }
                case .cancelled:
                    if gate.claim() { continuation.resume(returning: false) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 5) {
                if gate.claim() { continuation.resume(returning: false) }
            }
        }

        if ready {
            locked {
                self.listener = listener
                status.listening = true
                status.lastError = nil
            }
            log("Intercept listener ready on :\(InterceptConfig.listenPort)")
        } else {
            listener.cancel()
            if snapshot().lastError == nil { fail("listener didn't become ready") }
        }
        return ready
    }

    func stop() {
        let old: NWListener? = locked {
            let l = listener
            listener = nil
            status.listening = false
            return l
        }
        old?.cancel()
    }

    // MARK: - One client

    private func serve(_ client: NWConnection) async {
        let watchdog = DispatchWorkItem { client.cancel() }
        queue.asyncAfter(deadline: .now() + 45, execute: watchdog)
        defer { watchdog.cancel(); client.cancel() }

        client.start(queue: queue)
        do {
            try await client.waitUntilReady(timeout: 10)
        } catch {
            // The usual cause: the phone doesn't trust our certificate (yet) and
            // hung up during the handshake.
            locked { status.handshakeFailures += 1 }
            log("Client handshake failed: \(error.localizedDescription)")
            return
        }

        do {
            try await relay(client)
        } catch {
            log("Relay ended: \(error.localizedDescription)")
        }
    }

    private func relay(_ client: NWConnection) async throws {
        // Request head, then however much body it announces.
        var buffer = Data()
        var parsed = HTTPHead.parse(buffer)
        while parsed == nil {
            let chunk = try await client.receiveChunk()
            if chunk.data.isEmpty && chunk.done { return }
            buffer.append(chunk.data)
            parsed = HTTPHead.parse(buffer)
            guard parsed != nil || buffer.count < 64 * 1024 else { return }
        }
        guard var request = parsed?.head, let headLength = parsed?.length,
              let line = request.requestTarget else { return }

        var body = buffer.dropFirst(headLength)
        let maxBody = 2 * 1024 * 1024
        if request.isChunked {
            while HTTPChunked.decode(Data(body)) == nil {
                let chunk = try await client.receiveChunk()
                if chunk.data.isEmpty && chunk.done { return }
                body.append(chunk.data)
                guard body.count < maxBody else { return }
            }
        } else if let length = request.contentLength {
            guard length <= maxBody else { return }
            while body.count < length {
                let chunk = try await client.receiveChunk()
                if chunk.data.isEmpty && chunk.done { return }
                body.append(chunk.data)
            }
        }

        let host = Self.hostName(from: request.value("Host"))
        guard let host, Self.isAllowed(host) else {
            try await client.sendData(Self.simpleResponse(status: "403 Forbidden"))
            return
        }

        request.remove(["Connection", "Proxy-Connection", "Keep-Alive", "Accept-Encoding", "Upgrade"])
        request.set("Accept-Encoding", "identity")
        request.set("Connection", "close")

        guard let address = await resolver.address(for: host) else {
            log("No address for \(host)")
            try await client.sendData(Self.simpleResponse(status: "502 Bad Gateway"))
            return
        }

        let upstream = Self.upstreamConnection(to: address, serverName: host)
        defer { upstream.cancel() }
        upstream.start(queue: queue)
        try await upstream.waitUntilReady(timeout: 10)
        try await upstream.sendData(request.serialized() + body)

        // Reply head.
        var reply = Data()
        var replyParsed = HTTPHead.parse(reply)
        var upstreamDone = false
        while replyParsed == nil {
            let chunk = try await upstream.receiveChunk()
            reply.append(chunk.data)
            replyParsed = HTTPHead.parse(reply)
            if chunk.done { upstreamDone = true; break }
            guard reply.count < 64 * 1024 else { return }
        }
        guard var head = replyParsed?.head, let replyHeadLength = replyParsed?.length else { return }
        var replyBody = reply.dropFirst(replyHeadLength)
        head.set("Connection", "close")

        let currentTarget = locked { target }
        let encoding = head.value("Content-Encoding")?.lowercased()
        let rewritable = currentTarget != nil
            && line.path.hasPrefix(InterceptConfig.rewrittenPath)
            && head.statusCode == 200
            && (encoding == nil || encoding == "identity")

        guard rewritable, let currentTarget else {
            // Not ours to touch: forward the head, then pipe the rest through.
            try await client.sendData(head.serialized() + replyBody)
            while !upstreamDone {
                let chunk = try await upstream.receiveChunk()
                if !chunk.data.isEmpty { try await client.sendData(chunk.data) }
                upstreamDone = chunk.done
            }
            locked { status.relayed += 1 }
            return
        }

        // The positioning reply: collect all of it.
        let maxReply = 4 * 1024 * 1024
        var decoded: Data?
        while decoded == nil {
            if head.isChunked {
                decoded = HTTPChunked.decode(Data(replyBody))
            } else if let length = head.contentLength {
                if replyBody.count >= length { decoded = Data(replyBody.prefix(length)) }
            } else if upstreamDone {
                decoded = Data(replyBody)
            }
            if decoded != nil || upstreamDone { break }
            guard replyBody.count < maxReply else { return }
            let chunk = try await upstream.receiveChunk()
            replyBody.append(chunk.data)
            upstreamDone = chunk.done
        }
        guard let original = decoded else { return }

        let outgoing: Data
        if let rewritten = WLocRewriter.rewrite(original, to: currentTarget) {
            outgoing = rewritten.body
            locked {
                status.rewritten += 1
                status.lastRewrite = Date()
            }
            log("Rewrote a positioning reply (\(rewritten.wifi) Wi-Fi, \(rewritten.cell) cell)")
        } else {
            outgoing = original
            let first: Bool = locked {
                status.relayed += 1
                defer { reportedUnparsed = true }
                return !reportedUnparsed
            }
            if first {
                let prefix = original.prefix(24).map { String(format: "%02x", $0) }.joined()
                log("Positioning reply had nothing to rewrite (\(original.count) bytes, starts \(prefix))")
            }
        }

        head.remove(["Transfer-Encoding"])
        head.set("Content-Length", String(outgoing.count))
        try await client.sendData(head.serialized() + outgoing)
    }

    // MARK: - Helpers

    /// For the provider to record a failure that isn't the proxy's own.
    func noteError(_ message: String) { fail(message) }

    private func fail(_ message: String) {
        locked { status.lastError = message }
        log("Intercept error: \(message)")
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    static func isAllowed(_ host: String) -> Bool {
        let lowered = host.lowercased()
        return InterceptConfig.hosts.contains { lowered == $0 || lowered.hasSuffix("." + $0) }
    }

    /// `Host: gs-loc.apple.com:443` → `gs-loc.apple.com`.
    static func hostName(from header: String?) -> String? {
        guard let header, !header.isEmpty else { return nil }
        return header.split(separator: ":").first.map(String.init)
    }

    static func upstreamConnection(to address: UInt32, serverName: String) -> NWConnection {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, serverName)
        let ip = IPv4Address(Data([UInt8(address >> 24), UInt8(address >> 16 & 0xFF), UInt8(address >> 8 & 0xFF), UInt8(address & 0xFF)]))!
        return NWConnection(host: .ipv4(ip), port: 443, using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
    }

    static func simpleResponse(status: String) -> Data {
        Data("HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
    }
}

// MARK: - Upstream resolution

/// Finds the real address of an intercepted host without asking the system
/// resolver, which — while network mode is on — answers with this tunnel.
private final class UpstreamResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: (address: UInt32, expires: Date)] = [:]
    private let queue = DispatchQueue(label: "com.chrismack.locus.tunnel.resolver")

    /// Resolver choice: mainland-China hosts are best answered by a resolver
    /// that can see them.
    private func servers(for host: String) -> [String] {
        host.hasSuffix("autonavi.com") || host.hasSuffix("gds.alibabadns.com") || host.contains("-cn.")
            ? ["223.5.5.5", "119.29.29.29", "1.1.1.1"]
            : ["1.1.1.1", "8.8.8.8", "9.9.9.9"]
    }

    /// Asked while the system resolver still gives real answers.
    func prime(hosts: [String]) async {
        await withTaskGroup(of: Void.self) { group in
            for host in hosts {
                group.addTask { [weak self] in
                    guard let self, let address = await self.systemLookup(host) else { return }
                    self.store(host, address, ttl: 3600)
                }
            }
        }
    }

    func address(for host: String) async -> UInt32? {
        let key = host.lowercased()
        let hit: (address: UInt32, expires: Date)? = lock.withLock { cache[key] }
        if let hit, hit.expires > Date() { return hit.address }

        for server in servers(for: key) {
            if let address = await publicLookup(key, via: server) {
                store(key, address, ttl: 120)
                return address
            }
        }
        // Better a stale address than none: Apple's don't move often.
        return hit?.address
    }

    private func store(_ host: String, _ address: UInt32, ttl: TimeInterval) {
        lock.withLock { cache[host.lowercased()] = (address, Date().addingTimeInterval(ttl)) }
    }

    private func systemLookup(_ host: String) async -> UInt32? {
        await withCheckedContinuation { (outer: CheckedContinuation<UInt32?, Never>) in
            // A host the system resolver can't find (the mainland-China names, off
            // a Chinese network) can take a long time to fail; the whole command
            // that is waiting on this must not.
            let gate = OnceGate()
            let continuation = BoundedResume(gate: gate, continuation: outer)
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { continuation.resume(returning: nil) }
            DispatchQueue.global(qos: .utility).async {
                var hints = addrinfo()
                hints.ai_family = AF_INET
                hints.ai_socktype = SOCK_STREAM
                var result: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
                    continuation.resume(returning: nil)
                    return
                }
                defer { freeaddrinfo(result) }
                let value = first.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
                }
                // Our own tunnel's address means the question was already hijacked.
                continuation.resume(returning: value & 0xFFFF_FF00 == 0x0A07_0000 ? nil : value)
            }
        }
    }

    private struct BoundedResume {
        let gate: OnceGate
        let continuation: CheckedContinuation<UInt32?, Never>
        func resume(returning value: UInt32?) {
            if gate.claim() { continuation.resume(returning: value) }
        }
    }

    private func publicLookup(_ host: String, via server: String) async -> UInt32? {
        guard let ip = IPv4Address(server) else { return nil }
        let id = UInt16.random(in: 1...UInt16.max)
        let connection = NWConnection(host: .ipv4(ip), port: 53, using: .udp)
        defer { connection.cancel() }
        connection.start(queue: queue)
        do {
            try await connection.waitUntilReady(timeout: 3)
            try await connection.sendData(InterceptDNS.query(name: host, id: id))
            let reply = try await connection.receiveChunk(timeout: 3)
            return InterceptDNS.addresses(in: reply.data, id: id).first
        } catch {
            return nil
        }
    }
}

// MARK: - Identity

enum InterceptIdentityLoader {
    private static let label = "Locus Intercept"
    private static let tag = Data("com.chrismack.locus.intercept".utf8)

    /// Turns the leaf certificate and key the app generated into a `SecIdentity`.
    /// SecIdentity only exists as a pairing of a certificate and key in a
    /// keychain, so both are (re)added to this extension's own keychain.
    static func load(certificate der: Data, privateKey x963: Data) -> SecIdentity? {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else { return nil }
        let keyAttributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: 256,
        ]
        guard let key = SecKeyCreateWithData(x963 as CFData, keyAttributes as CFDictionary, nil) else { return nil }

        SecItemDelete([kSecClass: kSecClassKey, kSecAttrApplicationTag: tag] as CFDictionary)
        SecItemDelete([kSecClass: kSecClassCertificate, kSecAttrLabel: label] as CFDictionary)

        let addedKey = SecItemAdd([
            kSecClass: kSecClassKey,
            kSecValueRef: key,
            kSecAttrApplicationTag: tag,
            kSecAttrLabel: label,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ] as CFDictionary, nil)
        let addedCertificate = SecItemAdd([
            kSecClass: kSecClassCertificate,
            kSecValueRef: certificate,
            kSecAttrLabel: label,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ] as CFDictionary, nil)
        guard addedKey == errSecSuccess, addedCertificate == errSecSuccess else { return nil }

        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassIdentity,
            kSecAttrLabel: label,
            kSecReturnRef: true,
        ] as CFDictionary, &item)
        guard status == errSecSuccess, let item else { return nil }
        // swiftlint:disable:next force_cast
        return (item as! SecIdentity)
    }
}

// MARK: - NWConnection as async

final class OnceGate: @unchecked Sendable {
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

private struct ConnectionError: LocalizedError {
    let errorDescription: String?
}

extension NWConnection {
    /// Returns once the connection (and its TLS handshake, if it has one) is
    /// established; throws if it fails or takes longer than `timeout`.
    func waitUntilReady(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = OnceGate()
            stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if gate.claim() { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    if gate.claim() { continuation.resume(throwing: error) }
                case .cancelled:
                    if gate.claim() { continuation.resume(throwing: ConnectionError(errorDescription: "cancelled")) }
                default:
                    break
                }
            }
            // Re-check: a connection can already be ready by the time we look.
            if case .ready = state, gate.claim() { continuation.resume() }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                if gate.claim() {
                    continuation.resume(throwing: ConnectionError(errorDescription: "timed out"))
                    self?.cancel()
                }
            }
        }
    }

    /// The next chunk of bytes, and whether the peer has finished sending.
    func receiveChunk(max: Int = 64 * 1024, timeout: TimeInterval = 30) async throws -> (data: Data, done: Bool) {
        try await withCheckedThrowingContinuation { continuation in
            let gate = OnceGate()
            receive(minimumIncompleteLength: 1, maximumLength: max) { data, _, isComplete, error in
                guard gate.claim() else { return }
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (data ?? Data(), isComplete))
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                if gate.claim() {
                    continuation.resume(throwing: ConnectionError(errorDescription: "read timed out"))
                    self?.cancel()
                }
            }
        }
    }

    func sendData(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
}
