//
//  WLocRewriter.swift
//  Shared between the Locus app, the LocusTunnel extension and the logic tests.
//
//  Network mode in one function: iOS works out where it is by reading the Wi-Fi
//  access points and cell towers around it and asking Apple (`/clls/wloc`) where
//  each one is. Apple's answer is a protobuf full of coordinates. Rewrite every
//  coordinate in it and the phone concludes it is wherever the rewrite says.
//
//  Deliberately conservative, because a reply iOS finds malformed makes Location
//  Services report "unavailable" rather than just ignoring the spoof:
//    - only latitude (1), longitude (2) and accuracy (3) of a location are
//      replaced, every other byte of the reply is carried across untouched;
//    - anything that doesn't parse cleanly is returned as `nil`, and the caller
//      passes Apple's original reply through.
//

import Foundation

enum WLocRewriter {
    struct Target: Equatable {
        var latitude: Double
        var longitude: Double
        /// Horizontal accuracy in metres, written into every rewritten location.
        var accuracy: Int
    }

    struct Output {
        let body: Data
        /// Locations actually rewritten, split by where they came from.
        let wifi: Int
        let cell: Int
    }

    /// Rewrites `body`, or returns `nil` when there is nothing in it to rewrite.
    static func rewrite(_ body: Data, to target: Target) -> Output? {
        guard target.latitude.isFinite, target.longitude.isFinite,
              abs(target.latitude) <= 90, abs(target.longitude) <= 180 else { return nil }
        let bytes = [UInt8](body)
        guard bytes.count >= 4 else { return nil }

        return rewritePrefixed(bytes, target)
            ?? rewriteARPC(bytes, target)
            ?? rewriteBare(bytes, target)
            ?? scan(bytes, target)
    }

    // MARK: - Envelopes

    /// `00 01 00 00 00 0N 00 00 <u16 length> <protobuf>` — what Apple's live
    /// replies look like (N has been both 1 and 3).
    private static func rewritePrefixed(_ b: [UInt8], _ t: Target) -> Output? {
        guard b.count >= 10, b[0] == 0, b[1] == 1, b[6] == 0, b[7] == 0 else { return nil }
        let length = Int(b[8]) << 8 | Int(b[9])
        guard length > 0, 10 + length <= b.count else { return nil }
        guard let patched = patch(Array(b[10..<10 + length]), t),
              patched.bytes.count <= 0xFFFF else { return nil }

        var out = Array(b[0..<8])
        out += [UInt8(patched.bytes.count >> 8), UInt8(patched.bytes.count & 0xFF)]
        out += patched.bytes
        out += b[(10 + length)...]
        return Output(body: Data(out), wifi: patched.wifi, cell: patched.cell)
    }

    /// The request framing, which some replies reuse: version, three
    /// length-prefixed strings, a function id, then a u32-length payload.
    private static func rewriteARPC(_ b: [UInt8], _ t: Target) -> Output? {
        var i = 2
        guard b.count >= 2 else { return nil }
        for _ in 0..<3 {
            guard i + 2 <= b.count else { return nil }
            i += 2 + (Int(b[i]) << 8 | Int(b[i + 1]))
        }
        i += 4 // function id
        guard i + 4 <= b.count else { return nil }
        let length = Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
        let start = i + 4
        guard length > 0, start + length <= b.count else { return nil }
        guard let patched = patch(Array(b[start..<start + length]), t) else { return nil }

        let n = patched.bytes.count
        var out = Array(b[0..<i])
        out += [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]
        out += patched.bytes
        out += b[(start + length)...]
        return Output(body: Data(out), wifi: patched.wifi, cell: patched.cell)
    }

    /// The protobuf with no framing at all.
    private static func rewriteBare(_ b: [UInt8], _ t: Target) -> Output? {
        guard let patched = patch(b, t) else { return nil }
        return Output(body: Data(patched.bytes), wifi: patched.wifi, cell: patched.cell)
    }

    /// Last resort for a framing this doesn't know: look for a protobuf that
    /// parses and holds locations anywhere near the start, and send it back in
    /// the plain prefixed form.
    private static func scan(_ b: [UInt8], _ t: Target) -> Output? {
        for offset in 1...max(1, min(256, b.count - 4)) {
            let tag = b[offset]
            guard tag >> 3 > 0, tag & 7 == 0 || tag & 7 == 2 else { continue }
            guard let patched = patch(Array(b[offset...]), t), patched.bytes.count <= 0xFFFF else { continue }
            let n = patched.bytes.count
            let out: [UInt8] = [0, 1, 0, 0, 0, 1, 0, 0, UInt8(n >> 8), UInt8(n & 0xFF)] + patched.bytes
            return Output(body: Data(out), wifi: patched.wifi, cell: patched.cell)
        }
        return nil
    }

    // MARK: - Protobuf

    private struct Field {
        let number: Int
        let wire: Int
        /// The whole field, key included.
        let raw: Range<Int>
        /// Just the value (after the length prefix, for length-delimited).
        let value: Range<Int>
    }

    private static let wifiDevice = 2
    private static let cellFields: Set<Int> = [22, 24]
    private static let wifiLocation = 2
    private static let cellLocation = 5

    /// The whole payload patched, or `nil` if it isn't a protobuf or holds
    /// nothing to rewrite.
    private static func patch(_ payload: [UInt8], _ t: Target) -> (bytes: [UInt8], wifi: Int, cell: Int)? {
        guard let fields = parse(payload) else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(payload.count + 64)
        var wifi = 0
        var cell = 0

        for field in fields {
            let isWifi = field.number == wifiDevice
            let isCell = cellFields.contains(field.number)
            guard field.wire == 2, isWifi || isCell,
                  let inner = patchNested(Array(payload[field.value]),
                                          locationField: isWifi ? wifiLocation : cellLocation, t)
            else {
                out += payload[field.raw]
                continue
            }
            out += varint(UInt64(field.number << 3 | 2))
            out += varint(UInt64(inner.bytes.count))
            out += inner.bytes
            if isWifi { wifi += inner.replaced } else { cell += inner.replaced }
        }
        guard wifi + cell > 0 else { return nil }
        return (out, wifi, cell)
    }

    /// A device or tower message: rewrite the location sub-message, keep the rest.
    private static func patchNested(_ message: [UInt8], locationField: Int, _ t: Target) -> (bytes: [UInt8], replaced: Int)? {
        guard let fields = parse(message) else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(message.count + 32)
        var replaced = 0

        for field in fields {
            guard field.number == locationField, field.wire == 2,
                  let location = patchLocation(Array(message[field.value]), t) else {
                out += message[field.raw]
                continue
            }
            out += varint(UInt64(locationField << 3 | 2))
            out += varint(UInt64(location.count))
            out += location
            replaced += 1
        }
        return (out, replaced)
    }

    /// Only a location that already carries a latitude *and* a longitude is
    /// touched. Stuffing coordinates into one that has none is how a reply
    /// becomes something iOS refuses.
    private static func patchLocation(_ location: [UInt8], _ t: Target) -> [UInt8]? {
        guard let fields = parse(location) else { return nil }
        let hasLat = fields.contains { $0.number == 1 && $0.wire == 0 }
        let hasLon = fields.contains { $0.number == 2 && $0.wire == 0 }
        guard hasLat, hasLon else { return nil }

        var out = [UInt8]()
        out.reserveCapacity(location.count + 16)
        for field in fields {
            guard field.wire == 0 else { out += location[field.raw]; continue }
            switch field.number {
            case 1: out += varintField(1, signed(t.latitude))
            case 2: out += varintField(2, signed(t.longitude))
            case 3: out += varintField(3, Int64(max(0, t.accuracy)))
            default: out += location[field.raw]
            }
        }
        return out
    }

    /// Degrees ×1e8, truncated toward zero — the units Apple's replies use.
    private static func signed(_ degrees: Double) -> Int64 {
        Int64((degrees * 100_000_000).rounded(.towardZero))
    }

    /// Fields in order, or `nil` unless the buffer is a well-formed protobuf that
    /// ends exactly where its last field does.
    private static func parse(_ b: [UInt8]) -> [Field]? {
        var fields = [Field]()
        var i = 0
        while i < b.count {
            let start = i
            guard let key = readVarint(b, &i), key >> 3 > 0, key >> 3 < 1 << 29 else { return nil }
            let number = Int(key >> 3)
            let wire = Int(key & 7)
            let valueStart: Int
            let end: Int
            switch wire {
            case 0:
                valueStart = i
                guard readVarint(b, &i) != nil else { return nil }
                end = i
            case 1:
                valueStart = i
                end = i + 8
            case 2:
                guard let length = readVarint(b, &i), length <= UInt64(b.count) else { return nil }
                valueStart = i
                end = i + Int(length)
            case 5:
                valueStart = i
                end = i + 4
            default:
                return nil
            }
            guard end <= b.count else { return nil }
            fields.append(Field(number: number, wire: wire, raw: start..<end, value: valueStart..<end))
            i = end
        }
        return fields
    }

    private static func readVarint(_ b: [UInt8], _ i: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while i < b.count, shift < 70 {
            let byte = b[i]
            i += 1
            if shift < 64 { result |= UInt64(byte & 0x7F) << shift }
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }

    private static func varint(_ value: UInt64) -> [UInt8] {
        var v = value
        var out = [UInt8]()
        while v >= 0x80 {
            out.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        out.append(UInt8(v))
        return out
    }

    /// Negative values are sent as ten-byte two's-complement varints, as
    /// protobuf `int64` does.
    private static func varintField(_ number: Int, _ value: Int64) -> [UInt8] {
        varint(UInt64(number << 3)) + varint(UInt64(bitPattern: value))
    }
}
