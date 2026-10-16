import XCTest

/// Network mode lives or dies on one property: a reply iOS can still parse, with
/// the coordinates swapped and nothing else disturbed. These build replies the
/// way Apple's server shapes them — a protobuf of Wi-Fi devices and cell towers,
/// each carrying a location in 1e-8 degrees — and check both halves of that.
final class WLocRewriterTests: XCTestCase {
    private let target = WLocRewriter.Target(latitude: 48.85837, longitude: 2.29448, accuracy: 39)

    // MARK: Building replies

    private func varint(_ value: UInt64) -> [UInt8] {
        var v = value
        var out = [UInt8]()
        while v >= 0x80 { out.append(UInt8(v & 0x7F) | 0x80); v >>= 7 }
        out.append(UInt8(v))
        return out
    }

    private func varintField(_ number: Int, _ value: Int64) -> [UInt8] {
        varint(UInt64(number << 3)) + varint(UInt64(bitPattern: value))
    }

    private func lengthField(_ number: Int, _ content: [UInt8]) -> [UInt8] {
        varint(UInt64(number << 3 | 2)) + varint(UInt64(content.count)) + content
    }

    private func location(lat: Int64, lon: Int64, accuracy: Int64 = 25) -> [UInt8] {
        varintField(1, lat) + varintField(2, lon) + varintField(3, accuracy)
            + varintField(4, 3) + varintField(5, 12) + varintField(6, 1000)
    }

    private func wifiDevice(_ bssid: String, _ location: [UInt8]) -> [UInt8] {
        lengthField(2, lengthField(1, Array(bssid.utf8)) + lengthField(2, location))
    }

    private func cellTower(field: Int, _ location: [UInt8]) -> [UInt8] {
        lengthField(field, varintField(1, 310) + varintField(2, 410) + lengthField(5, location))
    }

    private let london = (lat: Int64(5_150_720_000), lon: Int64(-12_770_000))

    private func apple(_ payload: [UInt8]) -> Data {
        // 00 01 00 00 00 01 00 00, u16 length, payload
        Data([0, 1, 0, 0, 0, 1, 0, 0, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)] + payload)
    }

    private func payload(of reply: Data) -> [UInt8] { Array(reply.dropFirst(10)) }

    // MARK: Rewriting

    func testWifiDeviceCoordinatesAreReplaced() throws {
        let body = apple(wifiDevice("aa:bb:cc:dd:ee:01", location(lat: london.lat, lon: london.lon)))
        let out = try XCTUnwrap(WLocRewriter.rewrite(body, to: target))

        XCTAssertEqual(out.wifi, 1)
        XCTAssertEqual(out.cell, 0)
        let expected = wifiDevice("aa:bb:cc:dd:ee:01", location(lat: 4_885_837_000, lon: 229_448_000, accuracy: 39))
        XCTAssertEqual(payload(of: out.body), expected)
    }

    func testEveryDeviceAndTowerIsReplaced() throws {
        let body = apple(
            wifiDevice("aa:bb:cc:dd:ee:01", location(lat: london.lat, lon: london.lon))
            + wifiDevice("aa:bb:cc:dd:ee:02", location(lat: 4_000_000_000, lon: 1_000_000_000))
            + cellTower(field: 22, location(lat: london.lat, lon: london.lon))
            + cellTower(field: 24, location(lat: london.lat, lon: london.lon))
        )
        let out = try XCTUnwrap(WLocRewriter.rewrite(body, to: target))
        XCTAssertEqual(out.wifi, 2)
        XCTAssertEqual(out.cell, 2)
    }

    /// Apple answers "I don't know this access point" with latitude -180°, and
    /// those must resolve too — otherwise a lone unknown AP drags the fix home.
    func testUnknownAccessPointSentinelIsReplacedToo() throws {
        let unknown = location(lat: -18_000_000_000, lon: -18_000_000_000, accuracy: -1)
        let out = try XCTUnwrap(WLocRewriter.rewrite(apple(wifiDevice("aa:bb:cc:dd:ee:03", unknown)), to: target))
        XCTAssertEqual(out.wifi, 1)
        XCTAssertEqual(payload(of: out.body),
                       wifiDevice("aa:bb:cc:dd:ee:03", location(lat: 4_885_837_000, lon: 229_448_000, accuracy: 39)))
    }

    func testSouthernAndWesternHemispheresEncodeAsNegativeVarints() throws {
        let south = WLocRewriter.Target(latitude: -33.86882, longitude: -151.2093, accuracy: 10)
        let out = try XCTUnwrap(WLocRewriter.rewrite(apple(wifiDevice("x", location(lat: 1, lon: 1))), to: south))
        XCTAssertEqual(payload(of: out.body),
                       wifiDevice("x", location(lat: -3_386_882_000, lon: -15_120_930_000, accuracy: 10)))
    }

    func testFieldsOutsideTheLocationAreCarriedAcrossUntouched() throws {
        let extra = varintField(9, 77) + lengthField(30, [1, 2, 3])
        let body = apple(extra + wifiDevice("a", location(lat: london.lat, lon: london.lon)) + extra)
        let out = try XCTUnwrap(WLocRewriter.rewrite(body, to: target))
        let rewritten = payload(of: out.body)
        XCTAssertEqual(Array(rewritten.prefix(extra.count)), extra)
        XCTAssertEqual(Array(rewritten.suffix(extra.count)), extra)
    }

    func testLengthPrefixIsUpdatedWhenTheReplyGrows() throws {
        // A one-byte varint becomes a five-byte one, so the reply gets longer.
        let body = apple(wifiDevice("a", location(lat: 1, lon: 1)))
        let out = try XCTUnwrap(WLocRewriter.rewrite(body, to: target))
        let length = Int(out.body[8]) << 8 | Int(out.body[9])
        XCTAssertEqual(length, out.body.count - 10)
        XCTAssertGreaterThan(out.body.count, body.count)
    }

    func testBytesAfterThePayloadSurvive() throws {
        let body = apple(wifiDevice("a", location(lat: london.lat, lon: london.lon))) + Data([0xDE, 0xAD])
        let out = try XCTUnwrap(WLocRewriter.rewrite(body, to: target))
        XCTAssertEqual(Array(out.body.suffix(2)), [0xDE, 0xAD])
    }

    // MARK: Other framings

    func testARPCEnvelope() throws {
        let inner = wifiDevice("a", location(lat: london.lat, lon: london.lon))
        func pascal(_ s: String) -> [UInt8] { [0, UInt8(s.utf8.count)] + Array(s.utf8) }
        var frame: [UInt8] = [0, 1] + pascal("en_US") + pascal("com.apple.locationd") + pascal("17.0")
        frame += [0, 0, 0, 1]
        frame += [0, 0, UInt8(inner.count >> 8), UInt8(inner.count & 0xFF)]
        frame += inner

        let out = try XCTUnwrap(WLocRewriter.rewrite(Data(frame), to: target))
        XCTAssertEqual(out.wifi, 1)
        let newPayload = wifiDevice("a", location(lat: 4_885_837_000, lon: 229_448_000, accuracy: 39))
        XCTAssertEqual(Array(out.body.suffix(newPayload.count)), newPayload)
        let lengthAt = frame.count - inner.count - 4
        let length = Int(out.body[lengthAt]) << 24 | Int(out.body[lengthAt + 1]) << 16
            | Int(out.body[lengthAt + 2]) << 8 | Int(out.body[lengthAt + 3])
        XCTAssertEqual(length, newPayload.count)
    }

    func testBareProtobuf() throws {
        let bare = Data(wifiDevice("a", location(lat: london.lat, lon: london.lon)))
        let out = try XCTUnwrap(WLocRewriter.rewrite(bare, to: target))
        XCTAssertEqual(Array(out.body), wifiDevice("a", location(lat: 4_885_837_000, lon: 229_448_000, accuracy: 39)))
    }

    // MARK: Refusals

    /// A reply with nothing locatable in it is Apple's to send, not ours to edit.
    func testReplyWithNoLocationsIsLeftAlone() {
        XCTAssertNil(WLocRewriter.rewrite(apple(varintField(9, 1) + lengthField(30, [1, 2])), to: target))
    }

    /// A location with no latitude/longitude isn't one of ours to fill in.
    func testLocationWithoutCoordinatesIsNotTouched() {
        let hollow = varintField(3, 25) + varintField(4, 1)
        XCTAssertNil(WLocRewriter.rewrite(apple(wifiDevice("a", hollow)), to: target))
    }

    func testGarbageIsRefused() {
        XCTAssertNil(WLocRewriter.rewrite(Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]), to: target))
        XCTAssertNil(WLocRewriter.rewrite(Data(), to: target))
        XCTAssertNil(WLocRewriter.rewrite(Data("<html>502 Bad Gateway</html>".utf8), to: target))
    }

    func testTruncatedReplyIsRefused() {
        let whole = apple(wifiDevice("a", location(lat: london.lat, lon: london.lon)))
        XCTAssertNil(WLocRewriter.rewrite(whole.prefix(whole.count - 5), to: target))
    }

    func testImpossibleCoordinatesAreRefused() {
        let body = apple(wifiDevice("a", location(lat: london.lat, lon: london.lon)))
        XCTAssertNil(WLocRewriter.rewrite(body, to: .init(latitude: 91, longitude: 0, accuracy: 10)))
        XCTAssertNil(WLocRewriter.rewrite(body, to: .init(latitude: 0, longitude: .nan, accuracy: 10)))
    }
}
