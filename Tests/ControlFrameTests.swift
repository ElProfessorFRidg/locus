import XCTest

final class ControlFrameTests: XCTestCase {
    func testRoundTrip() {
        let payload = Data("{\"intercept\":null}".utf8)
        var buffer = ControlFrame.wrap(payload)
        XCTAssertEqual(ControlFrame.take(&buffer), payload)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testIncompleteFrameWaits() {
        let full = ControlFrame.wrap(Data(repeating: 7, count: 10))
        var buffer = Data(full.prefix(8))
        XCTAssertNil(ControlFrame.take(&buffer))
        buffer.append(full.dropFirst(8))
        XCTAssertEqual(ControlFrame.take(&buffer), Data(repeating: 7, count: 10))
    }

    func testOversizedLengthStopsReading() {
        var buffer = Data([0x7F, 0xFF, 0xFF, 0xFF, 1, 2, 3])
        XCTAssertEqual(ControlFrame.take(&buffer), Data())
        XCTAssertTrue(buffer.isEmpty)
    }

    func testEnvelopeCarriesToken() throws {
        let envelope = InterceptEnvelope(intercept: nil, token: "secret")
        let decoded = try JSONDecoder().decode(InterceptEnvelope.self, from: JSONEncoder().encode(envelope))
        XCTAssertEqual(decoded.token, "secret")
        XCTAssertNil(decoded.intercept)
    }
}
