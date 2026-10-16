//
//  X509Builder.swift
//
//  Security.framework can parse a certificate but has no way to make one, and
//  network mode needs two: an authority the user installs, and a leaf for the
//  location hosts that the authority has signed. So this writes the DER by hand
//  — a handful of ASN.1 shapes, ECDSA P-256 only.
//
//  Signing is injected, so this file imports nothing but Foundation and the
//  logic tests can check its output with OpenSSL.
//

import Foundation

enum DER {
    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        [tag] + length(content.count) + content
    }

    static func length(_ n: Int) -> [UInt8] {
        if n < 0x80 { return [UInt8(n)] }
        var bytes = [UInt8]()
        var v = n
        while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    static func sequence(_ items: [[UInt8]]) -> [UInt8] { tlv(0x30, items.flatMap { $0 }) }
    static func set(_ items: [[UInt8]]) -> [UInt8] { tlv(0x31, items.flatMap { $0 }) }
    static func octetString(_ content: [UInt8]) -> [UInt8] { tlv(0x04, content) }
    static func boolean(_ value: Bool) -> [UInt8] { tlv(0x01, [value ? 0xFF : 0x00]) }
    static func utf8String(_ text: String) -> [UInt8] { tlv(0x0C, Array(text.utf8)) }
    static func bitString(_ content: [UInt8], unusedBits: UInt8 = 0) -> [UInt8] { tlv(0x03, [unusedBits] + content) }
    static func explicit(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] { tlv(0xA0 | tag, content) }

    /// A non-negative INTEGER from big-endian bytes.
    static func integer(_ magnitude: [UInt8]) -> [UInt8] {
        var bytes = Array(magnitude.drop { $0 == 0 })
        if bytes.isEmpty { bytes = [0] }
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return tlv(0x02, bytes)
    }

    static func oid(_ dotted: String) -> [UInt8] {
        let parts = dotted.split(separator: ".").compactMap { UInt64($0) }
        precondition(parts.count >= 2)
        var out: [UInt8] = [UInt8(parts[0] * 40 + parts[1])]
        for part in parts.dropFirst(2) {
            var chunk = [UInt8(part & 0x7F)]
            var v = part >> 7
            while v > 0 { chunk.insert(UInt8(v & 0x7F) | 0x80, at: 0); v >>= 7 }
            out += chunk
        }
        return tlv(0x06, out)
    }

    /// UTCTime until 2049, GeneralizedTime after, as RFC 5280 requires.
    static func time(_ date: Date) -> [UInt8] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = c.year ?? 1970
        func two(_ v: Int?) -> String { String(format: "%02d", v ?? 0) }
        let rest = two(c.month) + two(c.day) + two(c.hour) + two(c.minute) + two(c.second) + "Z"
        if year < 2050 {
            return tlv(0x17, Array((two(year % 100) + rest).utf8))
        }
        return tlv(0x18, Array((String(format: "%04d", year) + rest).utf8))
    }
}

enum X509Builder {
    enum Role {
        /// A certificate authority that may only vouch for these DNS names.
        case authority(permittedDNS: [String])
        case server(dnsNames: [String])
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// ANSI X9.63 uncompressed point: `04 || X || Y`.
    static func isUncompressedP256(_ key: Data) -> Bool { key.count == 65 && key.first == 0x04 }

    /// Builds and signs a certificate. `sign` receives the to-be-signed bytes and
    /// returns a DER ECDSA signature (what `SecKeyCreateSignature` with
    /// `.ecdsaSignatureMessageX962SHA256` produces).
    static func certificate(
        role: Role,
        serial: [UInt8],
        subjectCN: String,
        issuerCN: String,
        notBefore: Date,
        notAfter: Date,
        subjectPublicKey: Data,
        subjectKeyID: [UInt8],
        authorityKeyID: [UInt8]?,
        sign: ([UInt8]) throws -> [UInt8]
    ) throws -> Data {
        guard isUncompressedP256(subjectPublicKey) else { throw Failure(description: "not a P-256 public key") }

        let ecdsaSHA256 = DER.sequence([DER.oid("1.2.840.10045.4.3.2")])
        let spki = DER.sequence([
            DER.sequence([DER.oid("1.2.840.10045.2.1"), DER.oid("1.2.840.10045.3.1.7")]),
            DER.bitString([UInt8](subjectPublicKey)),
        ])

        let tbs = DER.sequence([
            DER.explicit(0, DER.integer([2])),                 // v3
            DER.integer(serial),
            ecdsaSHA256,
            name(issuerCN),
            DER.sequence([DER.time(notBefore), DER.time(notAfter)]),
            name(subjectCN),
            spki,
            DER.explicit(3, DER.sequence(extensions(role, subjectKeyID: subjectKeyID, authorityKeyID: authorityKeyID))),
        ])

        let signature = try sign(tbs)
        return Data(DER.sequence([tbs, ecdsaSHA256, DER.bitString(signature)]))
    }

    private static func name(_ commonName: String) -> [UInt8] {
        DER.sequence([DER.set([DER.sequence([DER.oid("2.5.4.3"), DER.utf8String(commonName)])])])
    }

    private static func extensions(_ role: Role, subjectKeyID: [UInt8], authorityKeyID: [UInt8]?) -> [[UInt8]] {
        func ext(_ oid: String, critical: Bool = false, _ value: [UInt8]) -> [UInt8] {
            DER.sequence([DER.oid(oid)] + (critical ? [DER.boolean(true)] : []) + [DER.octetString(value)])
        }
        func dnsName(_ text: String) -> [UInt8] { DER.tlv(0x82, Array(text.utf8)) }

        var list = [ext("2.5.29.14", DER.octetString(subjectKeyID))]
        if let authorityKeyID {
            list.append(ext("2.5.29.35", DER.sequence([DER.tlv(0x80, authorityKeyID)])))
        }

        switch role {
        case .authority(let permitted):
            list.append(ext("2.5.29.19", critical: true, DER.sequence([DER.boolean(true)])))
            // keyCertSign | cRLSign
            list.append(ext("2.5.29.15", critical: true, DER.bitString([0x06], unusedBits: 1)))
            // Even if this authority's key were ever extracted, a certificate
            // chaining to it is only valid for the location hosts.
            let subtrees = permitted.map { DER.sequence([dnsName($0)]) }
            list.append(ext("2.5.29.30", critical: true, DER.sequence([DER.tlv(0xA0, subtrees.flatMap { $0 })])))
        case .server(let names):
            list.append(ext("2.5.29.19", critical: true, DER.sequence([])))
            list.append(ext("2.5.29.15", critical: true, DER.bitString([0x80], unusedBits: 7)))
            list.append(ext("2.5.29.37", DER.sequence([DER.oid("1.3.6.1.5.5.7.3.1")])))
            list.append(ext("2.5.29.17", DER.sequence(names.map(dnsName))))
        }
        return list
    }
}
