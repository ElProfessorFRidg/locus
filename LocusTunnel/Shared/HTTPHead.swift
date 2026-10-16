//
//  HTTPHead.swift
//  Shared between the LocusTunnel extension and the logic tests.
//
//  Just enough HTTP/1.1 for a relay: read a message head, find out how long the
//  body is, and write the head back out. Nothing here interprets a body.
//

import Foundation

struct HTTPHead {
    var startLine: String
    var headers: [(name: String, value: String)]

    /// The head at the front of `data`, and how many bytes it occupied
    /// (including the blank line). `nil` until the whole head has arrived.
    static func parse(_ data: Data) -> (head: HTTPHead, length: Int)? {
        let terminator = Data([13, 10, 13, 10])
        guard let end = data.range(of: terminator) else { return nil }
        let text = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        let start = lines.removeFirst()
        let headers: [(String, String)] = lines.compactMap { line in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : (name, value)
        }
        return (HTTPHead(startLine: start, headers: headers), data.distance(from: data.startIndex, to: end.upperBound))
    }

    func value(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    var contentLength: Int? { value("Content-Length").flatMap { Int($0) } }

    var isChunked: Bool { value("Transfer-Encoding")?.lowercased().contains("chunked") == true }

    /// `POST /clls/wloc HTTP/1.1` → `("POST", "/clls/wloc")`.
    var requestTarget: (method: String, path: String)? {
        let parts = startLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    var statusCode: Int? {
        let parts = startLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        return Int(parts[1])
    }

    mutating func remove(_ names: [String]) {
        headers.removeAll { header in names.contains { header.name.caseInsensitiveCompare($0) == .orderedSame } }
    }

    mutating func set(_ name: String, _ value: String) {
        remove([name])
        headers.append((name, value))
    }

    func serialized() -> Data {
        var text = startLine + "\r\n"
        for header in headers { text += "\(header.name): \(header.value)\r\n" }
        text += "\r\n"
        return Data(text.utf8)
    }
}

enum HTTPChunked {
    /// The decoded body once `data` holds every chunk through the terminating
    /// zero-length one, `nil` while more is still to come (or if it is malformed).
    static func decode(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        var body = Data()
        var i = 0
        while true {
            guard let lineEnd = findCRLF(bytes, from: i) else { return nil }
            let sizeText = String(decoding: bytes[i..<lineEnd], as: UTF8.self)
                .split(separator: ";").first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            guard let size = Int(sizeText, radix: 16), size >= 0 else { return nil }
            i = lineEnd + 2
            if size == 0 { return body }
            guard i + size + 2 <= bytes.count else { return nil }
            body.append(contentsOf: bytes[i..<i + size])
            i += size + 2
        }
    }

    private static func findCRLF(_ b: [UInt8], from: Int) -> Int? {
        var i = from
        while i + 1 < b.count {
            if b[i] == 13, b[i + 1] == 10 { return i }
            i += 1
        }
        return nil
    }
}
