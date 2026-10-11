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

    /// Name of the certificate authority and leaf in the keychain / UI.
    static let authorityName = "Locus Location Authority"
}

/// App → extension.
struct InterceptCommand: Codable {
    var enabled: Bool
    var latitude: Double
    var longitude: Double
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
}

/// What a provider message from the app may carry. Messages without an
/// `intercept` key (the older "which method are you using?" ping) still work.
struct InterceptEnvelope: Codable {
    var intercept: InterceptCommand?
}

/// The extension's answer to any provider message.
struct TunnelReply: Codable {
    var method: String
    var fakeIP: String
    var intercept: InterceptStatus?
}
