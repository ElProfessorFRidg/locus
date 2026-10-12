//
//  PacketTunnelProvider.swift
//  LocusTunnel
//
//  Locus' built-in loopback tunnel. Same job LocalDevVPN does as a separate app:
//  give the device a utun it can reach itself on (10.7.0.1), so idevice's
//  RemotePairing client can talk to this iPhone's own RemotePairing daemon
//  without a computer. Shipping it in-process means Locus can bring the tunnel
//  up itself instead of asking the user to go launch another app first.
//
//  BASED ON / USES CODE FROM LocalDevVPN (formerly StosVPN) by Stossy11 and the
//  SideStore Team - https://github.com/ElProfessorFRidg/LocalDevVPN - used under
//  the StosVPN License, which requires this attribution. The packet-rewrite
//  strategies below (and the reasoning in their doc comments) come from that
//  project; LocusTunnelMethod and LocusTunnelStatusFile live in Shared/ because
//  the app target needs them too.
//

import Network
import NetworkExtension
import os
import os.log
import Security

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var tunnelDeviceIP = "10.7.0.0"
    private var tunnelFakeIP = "10.7.0.1"
    private var tunnelSubnetMask = "255.255.255.0"
    private var method: LocusTunnelMethod = .checksumCorrectedRewrite

    private var deviceIPValue: UInt32 = 0
    private var fakeIPValue: UInt32 = 0

    private let pathMonitor = Network.NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "com.chrismack.locus.tunnel.path")
    private let osLog = OSLog(subsystem: "com.chrismack.locus.tunnel", category: "PacketTunnelProvider")

    /// Kept so the path monitor can reapply the exact settings iOS already
    /// accepted once cellular is confirmed up — see `rebindOnCellularAttach`.
    private var lastAppliedSettings: NEPacketTunnelNetworkSettings?
    private var didRebindForCellular = false

    // MARK: Network mode

    /// Network mode (see `InterceptProxy`): iOS is told to ask this tunnel about
    /// the location hosts, the packet loop answers with its own address, and
    /// connections to port 443 there are steered to the proxy's listener.
    /// Off until the app asks, so the plain loopback tunnel is unchanged.
    private lazy var proxy = InterceptProxy { [weak self] message in self?.log(message) }
    private let interceptLock = NSLock()
    private var interceptActive = false
    /// Whether the DNS override is part of the settings iOS has accepted. Kept
    /// apart from `interceptActive` so turning off can drop the override while
    /// the packet loop is still answering for the hosts.
    private var dnsOverrideWanted = false
    private var dnsOverrideApplied = false
    private var lastCommandError: String?
    /// Read once at start: the step a previous run died in, if one did.
    private var previousRunStoppedDuring: String?
    private var startedAt = Date()
    /// Commands run one after another, in the order they arrived.
    private var commandTail: Task<Void, Never>?
    private var interceptIdentity: SecIdentity?

    /// The last path line written to the log. Path updates arrive in bursts every
    /// time the radio changes state, and each one used to cost an App Group file
    /// append from a process iOS holds to a small memory ceiling. Only a path that
    /// actually reads differently is worth a line. `pathMonitorQueue`-confined.
    private var lastPathDescription: String?

    /// Fixed table, built once rather than rebuilt on every path update.
    private static let interfaceKinds: [(Network.NWInterface.InterfaceType, String)] = [
        (.wifi, "wifi"), (.cellular, "cellular"), (.wiredEthernet, "wired"),
        (.loopback, "loopback"), (.other, "other"),
    ]

    // MARK: - Lifecycle

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        if let value = options?["TunnelDeviceIP"] as? String { tunnelDeviceIP = value }
        if let value = options?["TunnelFakeIP"] as? String { tunnelFakeIP = value }
        if let value = options?["TunnelSubnetMask"] as? String { tunnelSubnetMask = value }
        if let raw = options?["TunnelMethod"] as? String,
           let parsed = LocusTunnelMethod(rawValue: raw) {
            method = parsed
        }

        deviceIPValue = ipToUInt32(tunnelDeviceIP)
        fakeIPValue = ipToUInt32(tunnelFakeIP)
        didRebindForCellular = false
        lastPathDescription = nil

        LocusTunnelStatusFile.clear()
        startedAt = Date()
        previousRunStoppedDuring = Breadcrumb.takeLeftover()
        if let step = previousRunStoppedDuring {
            log("The previous run stopped while \(step)", isError: true)
        }
        log("Starting Locus tunnel method=\(method.rawValue) device=\(tunnelDeviceIP) fake=\(tunnelFakeIP)")
        startPathMonitoring()

        let settings = makeSettings()

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { return }
            if let error {
                self.log("setTunnelNetworkSettings failed: \(error)", isError: true)
                completionHandler(error)
                return
            }
            self.log("Loopback route \(self.tunnelDeviceIP)/\(self.tunnelSubnetMask) active (method=\(self.method.rawValue))")
            self.lastAppliedSettings = settings
            self.readPacketsLoop()
            completionHandler(nil)
        }
    }

    /// The network settings for the current method, with the DNS override added
    /// while network mode is on. Rebuilt rather than patched so switching network
    /// mode on and off can't leave one behind the other.
    private func makeSettings() -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: tunnelDeviceIP)
        let ipv4 = NEIPv4Settings(addresses: [tunnelDeviceIP], subnetMasks: [tunnelSubnetMask])
        ipv4.includedRoutes = [NEIPv4Route(destinationAddress: tunnelDeviceIP, subnetMask: tunnelSubnetMask)]

        switch method {
        case .legacyRewrite, .checksumCorrectedRewrite, .conservativeMTU, .mssClamp, .dualStackV6Present:
            ipv4.excludedRoutes = [.default()]
        case .noExplicitRouteExclusion:
            // Deliberately no exclusion. includedRoutes already scopes the tunnel
            // to the loopback subnet; this only tests whether an *explicit*
            // exclusion changes how iOS prioritizes the route on cellular.
            break
        }
        settings.ipv4Settings = ipv4

        if method == .conservativeMTU {
            settings.mtu = 1280
        }

        if method == .dualStackV6Present {
            let ipv6 = NEIPv6Settings(addresses: ["fd00:7:7::1"], networkPrefixLengths: [64 as NSNumber])
            ipv6.includedRoutes = [NEIPv6Route(destinationAddress: "fd00:7:7::", networkPrefixLength: 64)]
            settings.ipv6Settings = ipv6
        }

        if isDNSOverrideWanted {
            // Only the location hosts are sent here; every other name resolves
            // exactly as it did before.
            let dns = NEDNSSettings(servers: [tunnelFakeIP])
            dns.matchDomains = InterceptConfig.hosts
            dns.matchDomainsNoSearch = true
            settings.dnsSettings = dns
        }
        return settings
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        log("Stopping tunnel, reason=\(reason.rawValue)")
        // Drop the handler as well as the monitor: it captures `self`, and a
        // stopped provider has no reason to keep the settings object it applied
        // alive either.
        pathMonitor.pathUpdateHandler = nil
        pathMonitor.cancel()
        setIntercepting(false)
        setDNSOverrideWanted(false)
        proxy.stop()
        proxy.setTarget(nil)
        lastAppliedSettings = nil
        lastPathDescription = nil
        completionHandler()
    }

    /// Locus asks the running tunnel which method it came up with, so Settings
    /// can show the one that actually worked rather than the one last requested.
    /// The same message channel carries network-mode commands, and the reply
    /// always says how the proxy is getting on.
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        let command = (try? JSONDecoder().decode(InterceptEnvelope.self, from: messageData))?.intercept
        // One at a time: `apply` waits in several places, and two messages
        // interleaving there (a resend overlapping a stop) can leave the DNS
        // override on with nothing listening, or the reverse.
        interceptLock.lock()
        let previous = commandTail
        commandTail = Task { [weak self] in
            await previous?.value
            guard let self else { completionHandler?(nil); return }
            if let command { await self.apply(command) }
            let reply = self.makeReply()
            completionHandler?(try? JSONEncoder().encode(reply))
        }
        interceptLock.unlock()
    }

    private func makeReply() -> TunnelReply {
        interceptLock.lock()
        let intercepting = interceptActive
        let dnsApplied = dnsOverrideApplied
        let error = lastCommandError
        let stoppedDuring = previousRunStoppedDuring
        interceptLock.unlock()
        return TunnelReply(
            method: method.rawValue, fakeIP: tunnelFakeIP, intercept: proxy.snapshot(),
            intercepting: intercepting, dnsApplied: dnsApplied, commandError: error,
            previousRunStoppedDuring: stoppedDuring,
            memoryAvailableMB: Breadcrumb.availableMB(),
            protocolVersion: InterceptConfig.protocolVersion,
            uptimeSeconds: Int(Date().timeIntervalSince(startedAt))
        )
    }

    // MARK: - Network mode

    private var isIntercepting: Bool {
        interceptLock.lock()
        defer { interceptLock.unlock() }
        return interceptActive
    }

    private func setIntercepting(_ value: Bool) {
        interceptLock.lock()
        interceptActive = value
        interceptLock.unlock()
    }

    private var isDNSOverrideWanted: Bool {
        interceptLock.lock()
        defer { interceptLock.unlock() }
        return dnsOverrideWanted
    }

    private func setDNSOverrideWanted(_ value: Bool) {
        interceptLock.lock()
        dnsOverrideWanted = value
        if !value { dnsOverrideApplied = false }
        interceptLock.unlock()
    }

    /// Synchronous on purpose: `NSLock` can't be taken from an async function.
    private func markDNSOverrideApplied() {
        interceptLock.lock()
        dnsOverrideApplied = dnsOverrideWanted
        interceptLock.unlock()
    }

    private func setCommandError(_ message: String?) {
        interceptLock.lock()
        lastCommandError = message
        interceptLock.unlock()
        if let message { proxy.noteError(message) }
    }

    private func apply(_ command: InterceptCommand) async {
        setCommandError(nil)
        // Each step marks itself before it starts and the mark is cleared once the
        // command is done. If iOS ends the extension part-way (a crash, or the
        // memory limit), the next run finds the mark and reports which step it
        // was — the only trace there is when the App Group log isn't available.
        defer { Breadcrumb.end() }

        guard command.enabled else {
            guard isIntercepting || isDNSOverrideWanted else { proxy.setTarget(nil); proxy.stop(); return }
            // Order matters. Take the override out first and let answers already
            // cached on the phone expire while the packet loop and proxy still
            // serve them; only then stop answering. The other way round, lookups
            // time out and cached connections are reset.
            Breadcrumb.begin("removing the DNS override")
            setDNSOverrideWanted(false)
            _ = await applySettings()
            try? await Task.sleep(nanoseconds: UInt64(InterceptConfig.dnsTTL + 1) * 1_000_000_000)
            setIntercepting(false)
            proxy.setTarget(nil)
            proxy.stop()
            log("Network mode off")
            return
        }

        if let cert = command.leafCertificate, let key = command.leafPrivateKey {
            Breadcrumb.begin("loading the certificate into the keychain")
            guard let identity = InterceptIdentityLoader.load(certificate: cert, privateKey: key) else {
                setCommandError("The certificate identity couldn't be loaded.")
                log("Network mode: the certificate identity couldn't be loaded", isError: true)
                return
            }
            // A new identity needs a new listener to present it.
            if interceptIdentity != nil { proxy.stop() }
            interceptIdentity = identity
        }
        if let latitude = command.latitude, let longitude = command.longitude {
            proxy.setTarget(.init(latitude: latitude, longitude: longitude, accuracy: command.accuracy))
        } else {
            proxy.setTarget(nil)
        }

        guard let identity = interceptIdentity else {
            setCommandError("No certificate has reached the tunnel yet.")
            log("Network mode: no certificate yet", isError: true)
            return
        }
        Breadcrumb.begin("starting the TLS listener")
        guard await proxy.start(identity: identity, bindAddress: tunnelDeviceIP) else { return }

        if !isDNSOverrideWanted {
            Breadcrumb.begin("looking up the real addresses of the location hosts")
            await proxy.primeResolver()
            Breadcrumb.begin("switching the DNS override on")
            setIntercepting(true)
            setDNSOverrideWanted(true)
            if await applySettings() {
                log("Network mode on: \(InterceptConfig.hosts.count) hosts now resolve to \(tunnelFakeIP)")
            } else {
                // Not in force, so don't claim it is: back out to the plain tunnel.
                setDNSOverrideWanted(false)
                setIntercepting(false)
                _ = await applySettings()
                setCommandError("iOS refused the DNS settings that send the location hosts to the tunnel.")
            }
        }
    }

    /// Applies the current settings; `true` if iOS accepted them.
    private func applySettings() async -> Bool {
        let settings = makeSettings()
        // Bounded: commands run one after another, so one that never comes back
        // would hold up every later one.
        let error: Error? = await withCheckedContinuation { continuation in
            let gate = OnceGate()
            setTunnelNetworkSettings(settings) { error in
                if gate.claim() { continuation.resume(returning: error) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 12) {
                if gate.claim() {
                    continuation.resume(returning: NSError(domain: "LocusTunnel", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "iOS didn't answer the network settings in 12 seconds",
                    ]))
                }
            }
        }
        if let error {
            log("Reapplying tunnel settings failed: \(error)", isError: true)
            return false
        }
        lastAppliedSettings = settings
        markDNSOverrideApplied()
        return true
    }

    // MARK: - Path monitoring

    private func startPathMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let interfaces = self.describeInterfaces(path)
            // supportsIPv4 == false on cellular means an IPv6-only bearer with
            // 464XLAT — the documented cause of "tunnel connects but its utun
            // never binds to cellular".
            let description = "Path: status=\(path.status) interfaces=\(interfaces) expensive=\(path.isExpensive) v4=\(path.supportsIPv4) v6=\(path.supportsIPv6)"
            if description != self.lastPathDescription {
                self.lastPathDescription = description
                self.log(description)
            }
            self.rebindOnCellularAttach(path: path, interfaces: interfaces)
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    /// `NWPath`/`NWInterface` are module-qualified because NetworkExtension
    /// declares conflicting symbols with the same names in an extension target.
    private func describeInterfaces(_ path: Network.NWPath) -> String {
        let active = Self.interfaceKinds.filter { path.usesInterfaceType($0.0) }.map { $0.1 }
        return active.isEmpty ? "unknown" : active.joined(separator: "+")
    }

    /// The programmatic equivalent of the manual "toggle Airplane Mode after
    /// connecting" workaround: the utun can be accepted by iOS before the
    /// cellular PDP context is stable, leaving its route unbound even though
    /// `setTunnelNetworkSettings` reported success. Reapplying the same settings
    /// once cellular is satisfied forces iOS to rebuild the routing table with
    /// the tunnel already present.
    private func rebindOnCellularAttach(path: Network.NWPath, interfaces: String) {
        guard !didRebindForCellular,
              path.status == .satisfied,
              interfaces.contains("cellular"),
              let settings = lastAppliedSettings else { return }

        didRebindForCellular = true
        log("Cellular path satisfied — reapplying tunnel settings to rebind the utun route")
        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error {
                self?.log("Cellular rebind failed: \(error)", isError: true)
            } else {
                self?.log("Cellular rebind succeeded")
            }
        }
    }

    private func log(_ message: String, isError: Bool = false) {
        os_log("%{public}@", log: osLog, type: isError ? .error : .info, message)
        LocusTunnelStatusFile.write(message)
    }

    // MARK: - Packet rewriting

    private func readPacketsLoop() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self else { return }
            self.forward(packets, protocols: protocols)
            self.readPacketsLoop()
        }
    }

    /// Rewrites what needs rewriting and hands the batch straight back.
    ///
    /// The address check happens through a *read-only* view of each packet
    /// first. `Data.withUnsafeMutableBytes` triggers copy-on-write the moment it
    /// is called, so the previous version malloc'd and memcpy'd every IPv4 packet
    /// on the tunnel — including the ones it then decided not to touch — and a
    /// batch where nothing matched still rebuilt the whole array.
    private func forward(_ packets: [Data], protocols: [NSNumber]) {
        if isIntercepting {
            forwardIntercepting(packets, protocols: protocols)
            return
        }

        var modified = packets
        var didRewriteAny = false

        for index in packets.indices where protocols[index].int32Value == AF_INET {
            guard needsRewrite(packets[index]) else { continue }
            rewritePacket(&modified[index])
            didRewriteAny = true
        }

        packetFlow.writePackets(didRewriteAny ? modified : packets, withProtocols: protocols)
    }

    /// The same, with network mode's DNS questions answered on the spot (the
    /// question never reaches the rewrite) and port 443 steered to the proxy.
    private func forwardIntercepting(_ packets: [Data], protocols: [NSNumber]) {
        var out = [Data]()
        out.reserveCapacity(packets.count)

        for index in packets.indices {
            guard protocols[index].int32Value == AF_INET else { out.append(packets[index]); continue }

            if let answer = InterceptDNS.reply(
                to: packets[index], server: fakeIPValue, hosts: InterceptConfig.hosts,
                answer: fakeIPValue, ttl: InterceptConfig.dnsTTL
            ) {
                proxy.noteDNSAnswered()
                out.append(answer.packet)
                continue
            }

            var packet = packets[index]
            if needsRewrite(packet) { rewritePacket(&packet) }
            out.append(packet)
        }
        // One packet out for every packet in — a DNS answer takes its question's
        // place — so the protocol list still lines up.
        packetFlow.writePackets(out, withProtocols: protocols)
    }

    /// Whether either address field is one of the two this tunnel swaps, decided
    /// without taking a mutable reference to the packet.
    private func needsRewrite(_ packet: Data) -> Bool {
        packet.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) -> Bool in
            guard let base = rawBuffer.baseAddress, rawBuffer.count >= 20 else { return false }
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            let ihl = Int(bytes[0] & 0x0F) * 4
            guard ihl >= 20, rawBuffer.count >= ihl else { return false }
            return readBE32(bytes, 12) == deviceIPValue || readBE32(bytes, 16) == fakeIPValue
        }
    }

    /// Rewrites one IPv4 packet in place. Every method swaps the src/dst address
    /// bytes (IPv4 header offsets 12–19); they differ only in whether and how
    /// they repair the checksums that swap invalidates.
    private func rewritePacket(_ packet: inout Data) {
        guard packet.count >= 20 else { return }

        packet.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            let bufferCount = rawBuffer.count

            let ihl = Int(bytes[0] & 0x0F) * 4
            guard ihl >= 20, bufferCount >= ihl else { return }

            let srcOffset = 12
            let dstOffset = 16
            var didRewrite = false
            var fromDevice = false
            var toFake = false

            if readBE32(bytes, srcOffset) == deviceIPValue {
                writeBE32(bytes, srcOffset, fakeIPValue)
                didRewrite = true
                fromDevice = true
            }
            if readBE32(bytes, dstOffset) == fakeIPValue {
                writeBE32(bytes, dstOffset, deviceIPValue)
                didRewrite = true
                toFake = true
            }
            guard didRewrite else { return }

            // Network mode: HTTPS aimed at the fake address lands on the proxy's
            // port, and what the proxy says back is relabelled as coming from
            // 443. Stateless in both directions, so there is nothing to track.
            if isIntercepting, bytes[9] == 6, bufferCount >= ihl + 20 {
                let listenPort = InterceptConfig.listenPort
                if toFake, readBE16(bytes, ihl + 2) == 443 {
                    writeBE16(bytes, ihl + 2, listenPort)
                }
                if fromDevice, readBE16(bytes, ihl) == listenPort {
                    writeBE16(bytes, ihl, 443)
                }
            }

            if method == .legacyRewrite {
                // Left with an invalid checksum on purpose, so this method stays a
                // true baseline for the corrected ones.
                return
            }

            writeBE16(bytes, 10, 0)
            let ipChecksum = internetChecksum(bytes, count: ihl)
            writeBE16(bytes, 10, ipChecksum)

            let totalLength = Int(readBE16(bytes, 2))
            guard totalLength <= bufferCount else { return }
            let payloadStart = ihl
            let payloadLength = totalLength - ihl
            guard payloadLength >= 0, payloadStart + payloadLength <= bufferCount else { return }

            let newSrc = readBE32(bytes, srcOffset)
            let newDst = readBE32(bytes, dstOffset)

            switch bytes[9] {
            case 6: // TCP
                if method == .mssClamp {
                    clampMSSIfPresent(bytes, payloadStart: payloadStart, payloadLength: payloadLength)
                }
                fixTransportChecksum(bytes, payloadStart: payloadStart, payloadLength: payloadLength,
                                     checksumOffset: 16, src: newSrc, dst: newDst, protocolNumber: 6)
            case 17: // UDP
                // A UDP checksum of 0 means "no checksum" and must stay 0 rather
                // than being recomputed into a wrong-but-plausible value.
                if readBE16(bytes, payloadStart + 6) != 0 {
                    fixTransportChecksum(bytes, payloadStart: payloadStart, payloadLength: payloadLength,
                                         checksumOffset: 6, src: newSrc, dst: newDst, protocolNumber: 17)
                }
            default:
                break
            }
        }
    }

    /// Rewrites the TCP MSS option (kind 2, length 4) down to `clampedMSS` when
    /// present. TCP options start right after the fixed 20-byte header.
    private func clampMSSIfPresent(_ bytes: UnsafeMutablePointer<UInt8>, payloadStart: Int, payloadLength: Int) {
        let clampedMSS: UInt16 = 1200
        guard payloadLength >= 20 else { return }

        let tcpHeaderLength = Int(bytes[payloadStart + 12] >> 4) * 4
        guard tcpHeaderLength > 20, tcpHeaderLength <= payloadLength else { return }

        var offset = payloadStart + 20
        let end = payloadStart + tcpHeaderLength

        while offset < end {
            let kind = bytes[offset]
            if kind == 0 { break }           // End of Option List
            if kind == 1 { offset += 1; continue } // No-Operation, no length byte

            guard offset + 1 < end else { break }
            let length = Int(bytes[offset + 1])
            guard length >= 2, offset + length <= end else { break }

            if kind == 2, length == 4 {
                if readBE16(bytes, offset + 2) > clampedMSS {
                    writeBE16(bytes, offset + 2, clampedMSS)
                }
                return
            }
            offset += length
        }
    }

    private func fixTransportChecksum(
        _ bytes: UnsafeMutablePointer<UInt8>,
        payloadStart: Int,
        payloadLength: Int,
        checksumOffset: Int,
        src: UInt32,
        dst: UInt32,
        protocolNumber: UInt8
    ) {
        guard payloadLength >= checksumOffset + 2 else { return }
        writeBE16(bytes, payloadStart + checksumOffset, 0)

        var sum: UInt32 = 0
        sum += (src >> 16) & 0xFFFF
        sum += src & 0xFFFF
        sum += (dst >> 16) & 0xFFFF
        sum += dst & 0xFFFF
        sum += UInt32(protocolNumber)
        sum += UInt32(payloadLength)

        var i = payloadStart
        let end = payloadStart + payloadLength
        while i + 1 < end {
            sum += UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1])
            i += 2
        }
        if i < end {
            sum += UInt32(bytes[i]) << 8
        }
        while sum >> 16 != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }

        let checksum = UInt16(~sum & 0xFFFF)
        writeBE16(bytes, payloadStart + checksumOffset,
                  checksum == 0 && protocolNumber == 17 ? 0xFFFF : checksum)
    }

    private func internetChecksum(_ bytes: UnsafeMutablePointer<UInt8>, count: Int) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < count {
            sum += UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1])
            i += 2
        }
        if i < count {
            sum += UInt32(bytes[i]) << 8
        }
        while sum >> 16 != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }
        return UInt16(~sum & 0xFFFF)
    }

    /// `UnsafePointer`, not `UnsafeMutablePointer`, so `needsRewrite` can read a
    /// packet through a read-only buffer. Swift converts a mutable pointer to a
    /// const one implicitly, so the rewrite path is unchanged.
    private func readBE16(_ bytes: UnsafePointer<UInt8>, _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    private func writeBE16(_ bytes: UnsafeMutablePointer<UInt8>, _ offset: Int, _ value: UInt16) {
        bytes[offset] = UInt8(value >> 8)
        bytes[offset + 1] = UInt8(value & 0xFF)
    }

    private func readBE32(_ bytes: UnsafePointer<UInt8>, _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    private func writeBE32(_ bytes: UnsafeMutablePointer<UInt8>, _ offset: Int, _ value: UInt32) {
        bytes[offset] = UInt8((value >> 24) & 0xFF)
        bytes[offset + 1] = UInt8((value >> 16) & 0xFF)
        bytes[offset + 2] = UInt8((value >> 8) & 0xFF)
        bytes[offset + 3] = UInt8(value & 0xFF)
    }

    private func ipToUInt32(_ ip: String) -> UInt32 {
        let parts = ip.split(separator: ".")
        guard parts.count == 4,
              let b1 = UInt32(parts[0]), let b2 = UInt32(parts[1]),
              let b3 = UInt32(parts[2]), let b4 = UInt32(parts[3]) else { return 0 }
        return (b1 << 24) | (b2 << 16) | (b3 << 8) | b4
    }
}

/// A note that survives the extension being ended mid-step. A plain file in
/// the extension's own Caches, written synchronously: once `write` returns the
/// bytes are the kernel's, so they outlive a crash or a memory kill. (Standard
/// defaults were the first try, but they reach disk asynchronously.)
private enum Breadcrumb {
    private static let url: URL? = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("intercept-step.txt")

    static func begin(_ step: String) {
        guard let url else { return }
        try? Data("\(step) (\(availableMB()) MB free)".utf8).write(to: url)
    }

    static func end() {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func takeLeftover() -> String? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        end()
        return String(decoding: data, as: UTF8.self)
    }

    static func availableMB() -> Int {
        Int(os_proc_available_memory() / 1_048_576)
    }
}
