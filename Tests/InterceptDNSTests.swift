import XCTest

/// The tunnel answers DNS by building the reply packet itself, so the packet
/// has to be right down to the checksums — the kernel drops a bad one silently,
/// and "silently" is how a whole feature turns into a timeout.
final class InterceptDNSTests: XCTestCase {
    private let server: UInt32 = 0x0A07_0001   // 10.7.0.1
    private let device: UInt32 = 0x0A07_0000   // 10.7.0.0
    private let hosts = ["gs-loc.apple.com", "gsp-ssl.ls.apple.com"]

    private func question(_ name: String, type: UInt16, id: UInt16 = 0xBEEF) -> [UInt8] {
        var dns: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in name.split(separator: ".") { dns.append(UInt8(label.count)); dns += Array(label.utf8) }
        dns += [0, UInt8(type >> 8), UInt8(type & 0xFF), 0, 1]
        return dns
    }

    private func packet(dns: [UInt8], to dst: UInt32? = nil, port: UInt16 = 53) -> Data {
        let udpLength = 8 + dns.count
        let total = 20 + udpLength
        var p: [UInt8] = [0x45, 0, UInt8(total >> 8), UInt8(total & 0xFF), 0, 0, 0, 0, 64, 17, 0, 0]
        p += [10, 7, 0, 0]
        let d = dst ?? server
        p += [UInt8(d >> 24), UInt8(d >> 16 & 0xFF), UInt8(d >> 8 & 0xFF), UInt8(d & 0xFF)]
        p += [0xC3, 0x50, UInt8(port >> 8), UInt8(port & 0xFF), UInt8(udpLength >> 8), UInt8(udpLength & 0xFF), 0, 0]
        return Data(p + dns)
    }

    private func checksumIsValid(_ bytes: [UInt8], range: Range<Int>, pseudo: [UInt8] = []) -> Bool {
        var data = pseudo + Array(bytes[range])
        if data.count % 2 == 1 { data.append(0) }
        var sum: UInt32 = 0
        for i in stride(from: 0, to: data.count, by: 2) { sum += UInt32(data[i]) << 8 | UInt32(data[i + 1]) }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return sum == 0xFFFF
    }

    private func answer(_ name: String, type: UInt16) -> (packet: Data, name: String)? {
        InterceptDNS.reply(to: packet(dns: question(name, type: type)), server: server, hosts: hosts, answer: server, ttl: 5)
    }

    func testAQuestionIsAnsweredWithTheTunnelAddress() throws {
        let reply = try XCTUnwrap(answer("gs-loc.apple.com", type: 1))
        XCTAssertEqual(reply.name, "gs-loc.apple.com")
        let p = [UInt8](reply.packet)

        XCTAssertEqual(Array(p[12..<16]), [10, 7, 0, 1], "comes from the resolver")
        XCTAssertEqual(Array(p[16..<20]), [10, 7, 0, 0], "goes back to whoever asked")
        XCTAssertEqual(Array(p[20..<22]), [0, 53])
        XCTAssertEqual(Array(p[22..<24]), [0xC3, 0x50], "to the asking port")
        XCTAssertEqual(Int(p[2]) << 8 | Int(p[3]), p.count)

        let dns = Data(p[28...])
        XCTAssertEqual(InterceptDNS.addresses(in: dns, id: 0xBEEF), [server])
    }

    func testReplyChecksumsAreValid() throws {
        let p = [UInt8](try XCTUnwrap(answer("gs-loc.apple.com", type: 1)).packet)
        XCTAssertTrue(checksumIsValid(p, range: 0..<20), "IP header")
        let udpLength = p.count - 20
        let pseudo = Array(p[12..<20]) + [0, 17, UInt8(udpLength >> 8), UInt8(udpLength & 0xFF)]
        XCTAssertTrue(checksumIsValid(p, range: 20..<p.count, pseudo: pseudo), "UDP")
    }

    func testOtherRecordTypesGetAnEmptyAnswer() throws {
        for type: UInt16 in [28, 65, 15] {
            let p = [UInt8](try XCTUnwrap(answer("gs-loc.apple.com", type: type)).packet)
            XCTAssertEqual(Int(p[28 + 6]) << 8 | Int(p[28 + 7]), 0, "type \(type) must have no answers")
            XCTAssertEqual(p[28 + 3] & 0x0F, 0, "…but still be a success, not NXDOMAIN")
            XCTAssertEqual(p[28 + 2] & 0x80, 0x80)
        }
    }

    func testSubdomainsOfAHostAreAnsweredAndLookalikesAreNot() {
        XCTAssertNotNil(answer("edge.gs-loc.apple.com", type: 1))
        XCTAssertNotNil(answer("GS-LOC.APPLE.COM", type: 1))
        XCTAssertNil(answer("apple.com", type: 1))
        XCTAssertNil(answer("evilgs-loc.apple.com", type: 1))
        XCTAssertNil(answer("gs-loc.apple.com.example.org", type: 1))
    }

    func testOnlyQuestionsToTheResolverOnPort53AreTouched() {
        let dns = question("gs-loc.apple.com", type: 1)
        XCTAssertNil(InterceptDNS.reply(to: packet(dns: dns, to: 0x0808_0808), server: server, hosts: hosts, answer: server, ttl: 5))
        XCTAssertNil(InterceptDNS.reply(to: packet(dns: dns, port: 5353), server: server, hosts: hosts, answer: server, ttl: 5))
    }

    func testResponsesAndJunkAreIgnored() {
        var response = question("gs-loc.apple.com", type: 1)
        response[2] |= 0x80
        XCTAssertNil(InterceptDNS.reply(to: packet(dns: response), server: server, hosts: hosts, answer: server, ttl: 5))
        XCTAssertNil(InterceptDNS.reply(to: Data([0x45, 0, 0]), server: server, hosts: hosts, answer: server, ttl: 5))
        XCTAssertNil(InterceptDNS.reply(to: Data(), server: server, hosts: hosts, answer: server, ttl: 5))
        XCTAssertNil(InterceptDNS.reply(to: packet(dns: [UInt8](repeating: 0xFF, count: 20)), server: server, hosts: hosts, answer: server, ttl: 5))
    }

    func testQueryBuildsAWellFormedQuestion() {
        let q = [UInt8](InterceptDNS.query(name: "gs-loc.apple.com", id: 0x1234))
        XCTAssertEqual(Array(q[0..<4]), [0x12, 0x34, 0x01, 0x00])
        XCTAssertEqual(Array(q[4..<6]), [0, 1])
        XCTAssertEqual(q[12], 6)
        XCTAssertEqual(Array(q.suffix(5)), [0, 0, 1, 0, 1])
    }

    /// A reply as a real resolver sends it: the answer's name is a compression
    /// pointer back to the question, and a CNAME may come first.
    func testAddressesAreReadOutOfARealisticResponse() {
        var r: [UInt8] = [0x12, 0x34, 0x81, 0x80, 0, 1, 0, 3, 0, 0, 0, 0]
        r += Array(InterceptDNS.query(name: "gs-loc.apple.com", id: 0).dropFirst(12))
        r += [0xC0, 0x0C, 0, 5, 0, 1, 0, 0, 0, 60, 0, 2, 0xC0, 0x0C]              // CNAME (rdata a pointer)
        r += [0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 17, 253, 1, 2]
        r += [0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 17, 253, 1, 3]
        XCTAssertEqual(InterceptDNS.addresses(in: Data(r), id: 0x1234), [0x11FD_0102, 0x11FD_0103])
        XCTAssertEqual(InterceptDNS.addresses(in: Data(r), id: 0x9999), [], "someone else's answer")
    }
}
