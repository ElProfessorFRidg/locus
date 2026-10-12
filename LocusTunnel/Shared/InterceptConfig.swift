//
//  InterceptConfig.swift
//  Shared between the Locus app and the LocusTunnel extension.
//
//  What the app tells the extension for "network mode", and what it answers.
//  The only thing that crosses the process boundary is JSON in a provider
//  message, so neither side needs the App Group for this to work.
//

import Foundation

enum InterceptConfig {
    /// The hosts iOS asks "where is this access point?" on. The first two are the
    /// positioning service proper; the last three are the same endpoint under
    /// the names Maps and mainland-China builds use. Kept to exact names rather
    /// than `*.apple.com`, so nothing else Apple sends is ever decrypted.
    static let hosts = [
        "gs-loc.apple.com",
        "gs-loc-cn.apple.com",
        "gsp-ssl.ls.apple.com",
        "bluedot.is.autonavi.com",
        "bluedot.is.autonavi.com.gds.alibabadns.com",
    ]

    /// The only path whose reply is rewritten. Everything else on those hosts is
    /// relayed byte for byte.
    static let rewrittenPath = "/clls/wloc"

    /// Where the extension's TLS listener sits. Packets for `443` on the
    /// tunnel's fake address are steered here, and answers steered back.
    static let listenPort: UInt16 = 8443

    /// Short, so that once the spoof is switched off the real addresses come
    /// back within seconds rather than when a cached answer finally expires.
    static let dnsTTL: UInt32 = 5

    /// Bumped whenever the app ↔ extension messages change, and echoed in every
    /// reply, so a message can say which extension actually answered.
    static let protocolVersion = 5

    /// Where the extension listens for the app when provider messages don't get
    /// through: on the tunnel's own address only, reached through the tunnel
    /// like everything else it carries.
    static let controlPort: UInt16 = 8445

    /// Name of the certificate authority and leaf in the keychain / UI.
    static let authorityName = "Locus Location Authority"
}

/// App → extension.
struct InterceptCommand: Codable {
    var enabled: Bool
    /// Where to say the phone is. `nil` with `enabled` means "intercept, but
    /// relay every reply unchanged" — what the self-test uses, so testing never
    /// moves anyone to 0,0.
    var latitude: Double?
    var longitude: Double?
    var accuracy: Int
    /// Sent when the extension has no identity yet (first start, or after the
    /// certificate was regenerated); omitted for plain coordinate updates.
    var leafCertificate: Data?
    var leafPrivateKey: Data?
}

/// Extension → app.
struct InterceptStatus: Codable, Equatable {
    var listening = false
    /// Replies whose coordinates were rewritten.
    var rewritten = 0
    /// Replies on the intercepted hosts that were relayed unchanged.
    var relayed = 0
    /// DNS questions answered with the tunnel's address.
    var dnsAnswered = 0
    /// TLS handshakes that never completed — the signature of a certificate iOS
    /// does not trust (yet).
    var handshakeFailures = 0
    var lastError: String?
    /// The coordinate replies are being rewritten to, if any. Lets the app pick
    /// a spoof back up after it was closed: the extension kept going without it.
    var latitude: Double?
    var longitude: Double?
    /// When a reply was last rewritten — the one sign iOS actually asked.
    var lastRewrite: Date?
}

/// What a provider message from the app may carry. Messages without an
/// `intercept` key (the older "which method are you using?" ping) still work.
struct InterceptEnvelope: Codable {
    var intercept: InterceptCommand?
    /// The secret the app put in the tunnel's configuration. Required on the
    /// control channel, which — unlike provider messages — another process on
    /// the device could also open.
    var token: String?
}

/// A 4-byte big-endian length, then that many bytes. One frame each way per
/// control connection.
enum ControlFrame {
    static let maxPayload = 512 * 1024

    static func wrap(_ payload: Data) -> Data {
        let n = UInt32(payload.count)
        return Data([UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]) + payload
    }

    /// The first complete frame in `buffer`, removed from it; `nil` while it is
    /// still incomplete. A length over `maxPayload` empties the buffer and
    /// returns an empty frame, so the reader stops.
    static func take(_ buffer: inout Data) -> Data? {
        guard buffer.count >= 4 else { return nil }
        let b = [UInt8](buffer.prefix(4))
        let length = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
        guard length <= maxPayload else { buffer = Data(); return Data() }
        guard buffer.count >= 4 + length else { return nil }
        let payload = Data(buffer.dropFirst(4).prefix(length))
        buffer = Data(buffer.dropFirst(4 + length))
        return payload
    }
}

/// The extension's answer to any provider message.
struct TunnelReply: Codable {
    var method: String
    var fakeIP: String
    var intercept: InterceptStatus?
    /// Whether packets are being intercepted, and whether the DNS override that
    /// sends the location hosts here is actually in force. `nil` from an older
    /// extension.
    var intercepting: Bool?
    var dnsApplied: Bool?
    /// Why the last command couldn't be carried out, if it couldn't.
    var commandError: String?
    /// The network-mode step the previous run of the extension was in the middle
    /// of when it stopped — set only when it never finished, which means iOS
    /// ended the extension (a crash, or the memory limit) at that point.
    var previousRunStoppedDuring: String?
    /// Memory the extension may still allocate before iOS ends it, in MB.
    var memoryAvailableMB: Int?
    /// `InterceptConfig.protocolVersion` of the extension that answered.
    var protocolVersion: Int?
    /// Seconds since this run of the extension started.
    var uptimeSeconds: Int?
}
