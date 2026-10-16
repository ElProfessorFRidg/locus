import XCTest

final class HTTPHeadTests: XCTestCase {
    private func data(_ s: String) -> Data { Data(s.utf8) }

    func testParsesARequestHead() throws {
        let raw = data("POST /clls/wloc HTTP/1.1\r\nHost: gs-loc.apple.com\r\ncontent-length: 12\r\nAccept-Encoding: gzip\r\n\r\nBODYBODYBODY")
        let (head, length) = try XCTUnwrap(HTTPHead.parse(raw))
        XCTAssertEqual(head.requestTarget?.method, "POST")
        XCTAssertEqual(head.requestTarget?.path, "/clls/wloc")
        XCTAssertEqual(head.value("HOST"), "gs-loc.apple.com")
        XCTAssertEqual(head.contentLength, 12)
        XCTAssertEqual(String(decoding: raw.dropFirst(length), as: UTF8.self), "BODYBODYBODY")
    }

    func testParsesAStatusLine() throws {
        let (head, _) = try XCTUnwrap(HTTPHead.parse(data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n")))
        XCTAssertEqual(head.statusCode, 200)
        XCTAssertTrue(head.isChunked)
        XCTAssertNil(head.contentLength)
    }

    func testIncompleteHeadWaitsForMore() {
        XCTAssertNil(HTTPHead.parse(data("POST / HTTP/1.1\r\nHost: x\r\n")))
        XCTAssertNil(HTTPHead.parse(Data()))
    }

    func testEditingAndSerialising() throws {
        var (head, _) = try XCTUnwrap(HTTPHead.parse(data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: keep-alive\r\n\r\n")))
        head.set("Content-Length", "9")
        head.set("connection", "close")
        head.remove(["Transfer-Encoding"])
        let text = String(decoding: head.serialized(), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n"))
        XCTAssertEqual(text.components(separatedBy: "\r\n").filter { $0.lowercased().hasPrefix("connection") }, ["connection: close"])
        XCTAssertTrue(text.contains("Content-Length: 9\r\n"))
        XCTAssertFalse(text.contains("Content-Length: 5"))
    }

    func testChunkedBodyIsDecodedOnceComplete() {
        let whole = data("5\r\nhello\r\n6;ext=1\r\n world\r\n0\r\n\r\n")
        XCTAssertEqual(HTTPChunked.decode(whole).map { String(decoding: $0, as: UTF8.self) }, "hello world")
        XCTAssertNil(HTTPChunked.decode(whole.prefix(whole.count - 5)), "last chunk not here yet")
        XCTAssertNil(HTTPChunked.decode(data("zz\r\nnope\r\n0\r\n\r\n")), "not hex")
    }
}
