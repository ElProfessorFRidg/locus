//
//  InterceptDNS.swift
//  Shared between the LocusTunnel extension and the logic tests.
//
//  A resolver small enough to live in the packet loop. The tunnel tells iOS to
//  ask `10.7.0.1` about the location hosts and nothing else; those questions
//  arrive as ordinary UDP packets, and are answered here by building the reply
//  packet by hand. No socket, no port 53, nothing to bind.
//

import Foundation

enum InterceptDNS {
    /// If `packet` is a DNS question for one of `hosts` sent to `server`, the
    /// IPv4 packet that answers it. `nil` for everything else.
    ///
    /// `A` questions get `answer`. Every other type (AAAA, HTTPS/SVCB, …) gets an
    /// empty "no such data" reply: nothing else is listening for these names, so
    /// staying silent would make the client wait out a timeout, and answering
    /// AAAA would let it route around the tunnel over IPv6.
    static func reply(to packet: Data, server: UInt32, hosts: [String], answer: UInt32, ttl: UInt32) -> (packet: Data, name: String)? {
        let p = [UInt8](packet)
        guard p.count >= 28, p[0] >> 4 == 4 else { return nil }
        let ihl = Int(p[0] & 0x0F) * 4
        guard ihl >= 20, p.count >= ihl + 8, p[9] == 17 else { return nil }
        guard be32(p, 16) == server else { return nil }

        let sourcePort = be16(p, ihl)
        guard be16(p, ihl + 2) == 53 else { return nil }
        let udpLength = Int(be16(p, ihl + 4))
        guard udpLength >= 8 + 12, ihl + udpLength <= p.count else { return nil }

        let dns = Array(p[(ihl + 8)..<(ihl + udpLength)])
        // QR must be 0 (a question), opcode 0, exactly the one question.
        guard dns[2] & 0x80 == 0, dns[2] & 0x78 == 0, be16(dns, 4) == 1 else { return nil }

        guard let (name, afterName) = readName(dns, from: 12), afterName + 4 <= dns.count else { return nil }
        let type = be16(dns, afterName)
        let lowered = name.lowercased()
        guard hosts.contains(where: { lowered == $0 || lowered.hasSuffix("." + $0) }) else { return nil }
        let question = Array(dns[12..<(afterName + 4)])

        let answering = type == 1
        var body = [UInt8]()
        body += [dns[0], dns[1]]                        // id
        body += [0x81, 0x80]                            // response, recursion desired + available
        body += [0, 1, 0, answering ? 1 : 0, 0, 0, 0, 0]
        body += question
        if answering {
            body += [0xC0, 0x0C, 0, 1, 0, 1]            // pointer to the name, A, IN
            body += be32Bytes(ttl)
            body += [0, 4]
            body += be32Bytes(answer)
        }

        let udp = be16Bytes(53) + be16Bytes(sourcePort) + be16Bytes(UInt16(8 + body.count)) + [0, 0] + body
        var ip: [UInt8] = [0x45, 0, 0, 0, 0, 0, 0x40, 0, 64, 17, 0, 0]
        ip += be32Bytes(server)
        ip += p[12..<16]
        let total = ip.count + udp.count
        ip[2] = UInt8(total >> 8)
        ip[3] = UInt8(total & 0xFF)
        let ipSum = checksum(ip)
        ip[10] = UInt8(ipSum >> 8)
        ip[11] = UInt8(ipSum & 0xFF)

        var pseudo = Array(ip[12..<20]) + [0, 17] + be16Bytes(UInt16(udp.count))
        pseudo += udp
        var udpSum = checksum(pseudo)
        if udpSum == 0 { udpSum = 0xFFFF }
        var full = ip + udp
        full[ip.count + 6] = UInt8(udpSum >> 8)
        full[ip.count + 7] = UInt8(udpSum & 0xFF)
        return (Data(full), name)
    }

    // MARK: - Asking a real resolver

    /// An `A` question, for resolving the real address of an intercepted host
    /// through a public resolver instead of the system one (which would answer
    /// with this very tunnel and send the proxy round in a circle).
    static func query(name: String, id: UInt16) -> Data {
        var out: [UInt8] = be16Bytes(id) + [0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in name.split(separator: ".") {
            out.append(UInt8(label.utf8.count))
            out += Array(label.utf8)
        }
        out += [0, 0, 1, 0, 1]
        return Data(out)
    }

    /// The IPv4 addresses in an `A` response, host-order, in the order given.
    static func addresses(in response: Data, id: UInt16) -> [UInt32] {
        let d = [UInt8](response)
        guard d.count >= 12, be16(d, 0) == id, d[2] & 0x80 != 0, d[3] & 0x0F == 0 else { return [] }
        var i = 12
        for _ in 0..<Int(be16(d, 4)) {
            guard let (_, next) = readName(d, from: i) else { return [] }
            i = next + 4
        }
        var found = [UInt32]()
        for _ in 0..<Int(be16(d, 6)) {
            guard let (_, next) = readName(d, from: i), next + 10 <= d.count else { break }
            let type = be16(d, next)
            let length = Int(be16(d, next + 8))
            let data = next + 10
            guard data + length <= d.count else { break }
            if type == 1, length == 4 { found.append(be32(d, data)) }
            i = data + length
        }
        return found
    }

    // MARK: - Wire format

    /// A (possibly compressed) name starting at `start`, and where the bytes
    /// after it begin.
    private static func readName(_ d: [UInt8], from start: Int) -> (String, Int)? {
        var labels = [String]()
        var i = start
        var next: Int?
        var hops = 0
        while i < d.count {
            let length = Int(d[i])
            if length == 0 {
                return (labels.joined(separator: "."), next ?? i + 1)
            }
            if length & 0xC0 == 0xC0 {
                guard i + 1 < d.count, hops < 8 else { return nil }
                if next == nil { next = i + 2 }
                i = (length & 0x3F) << 8 | Int(d[i + 1])
                hops += 1
                continue
            }
            guard length < 64, i + 1 + length <= d.count else { return nil }
            labels.append(String(decoding: d[(i + 1)..<(i + 1 + length)], as: UTF8.self))
            i += 1 + length
        }
        return nil
    }

    private static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < bytes.count {
            sum += UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1])
            i += 2
        }
        if i < bytes.count { sum += UInt32(bytes[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return UInt16(~sum & 0xFFFF)
    }

    private static func be16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) << 8 | UInt16(b[i + 1]) }

    private static func be32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }

    private static func be16Bytes(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }

    private static func be32Bytes(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
    }
}
