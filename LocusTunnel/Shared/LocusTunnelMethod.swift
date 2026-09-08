//
//  LocusTunnelMethod.swift
//  Shared between the Locus app and the LocusTunnel extension.
//
//  BASED ON / USES CODE FROM LocalDevVPN (formerly StosVPN) by Stossy11 and the
//  SideStore Team — https://github.com/ElProfessorFRidg/LocalDevVPN — used under
//  the StosVPN License, which requires this attribution.
//

import Foundation

/// Strategies for making the loopback tunnel work on cellular, not just Wi-Fi.
/// Each targets a distinct hypothesis for why a plain address swap times out on
/// cellular; only the `rawValue` crosses the process boundary (it is passed to
/// `startVPNTunnel(options:)`).
///
/// Order matters: `LocusTunnel` walks this list top to bottom when auto-picking
/// a method, so the cheapest/most-likely fix comes first and the odd ones last.
enum LocusTunnelMethod: String, CaseIterable, Codable, Identifiable {
    /// Swap source/destination IPv4 addresses only. Leaves the IP and TCP/UDP
    /// checksums (both of which cover the address fields) invalid. Wi-Fi
    /// hardware checksum offload can mask that; some cellular basebands drop the
    /// packet instead, which reads as a timeout.
    case checksumCorrectedRewrite

    /// checksumCorrectedRewrite plus a conservative 1280-byte MTU (the IPv6
    /// minimum, safe on any path), targeting MTU/fragmentation rather than
    /// checksums as the cause.
    case conservativeMTU

    /// checksumCorrectedRewrite plus clamping the TCP MSS option on SYN packets,
    /// for when TCP negotiated a segment size larger than the path actually
    /// delivers cleanly before the interface MTU took effect.
    case mssClamp

    /// checksumCorrectedRewrite plus a static ULA IPv6 block on the tunnel
    /// interface (never a default IPv6 route). Carriers handing out IPv6-only
    /// bearers with 464XLAT leave the physical interface without a real IPv4
    /// address; giving the utun *some* IPv6 config can be what lets it bind.
    case dualStackV6Present

    /// Leaves `excludedRoutes` empty instead of explicitly excluding the default
    /// route. Never puts `.default()` in `includedRoutes` — that would push every
    /// app's traffic into a tunnel that forwards nothing, i.e. a black hole.
    case noExplicitRouteExclusion

    /// The original address-swap-only behaviour, checksums left invalid. Kept
    /// last as a baseline: if this is the only one that works, the problem is
    /// something other than packet contents.
    case legacyRewrite

    var id: String { rawValue }

    static var `default`: LocusTunnelMethod { .checksumCorrectedRewrite }

    var title: String {
        switch self {
        case .checksumCorrectedRewrite: return "Checksum repair"
        case .conservativeMTU: return "Conservative MTU"
        case .mssClamp: return "TCP MSS clamp"
        case .dualStackV6Present: return "IPv6 present"
        case .noExplicitRouteExclusion: return "No route exclusion"
        case .legacyRewrite: return "Address swap only"
        }
    }

    var detail: String {
        switch self {
        case .checksumCorrectedRewrite:
            return "Swaps the loopback addresses and repairs the IP and TCP/UDP checksums. Works on most networks."
        case .conservativeMTU:
            return "Checksum repair plus a 1280-byte MTU, for links that drop or badly fragment larger packets."
        case .mssClamp:
            return "Checksum repair plus a smaller TCP segment size, when TCP negotiated more than the path delivers."
        case .dualStackV6Present:
            return "Checksum repair plus an IPv6 address on the tunnel itself, for IPv6-only cellular bearers."
        case .noExplicitRouteExclusion:
            return "Stops excluding the default route, in case that exclusion is what deprioritises the tunnel."
        case .legacyRewrite:
            return "Address swap with no checksum repair — the original behaviour, kept as a baseline."
        }
    }
}
