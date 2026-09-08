import Foundation

/// Why Locus' built-in tunnel can't run on this particular copy of the app.
///
/// This exists because Locus is sideloaded. The entitlements in the repo are a
/// request; whatever re-signed the IPA decides whether they were granted, and a
/// free Apple developer account can never be granted `packet-tunnel-provider` at
/// all. Left alone, that surfaces as a VPN save failing with "permission
/// denied", which tells nobody anything.
///
/// Every case here has the same way out — connect the LocalDevVPN app, which
/// raises the same `10.7.0.1` loopback tunnel Locus would have — so the UI can
/// always offer one concrete next step instead of an apology.
enum TunnelBlocker: Equatable, Identifiable, Hashable {
    /// Network extensions don't run in the Simulator.
    case simulator
    /// No `.appex` in the bundle: LiveContainer, or a build stripped of plug-ins.
    case noExtension
    /// The provisioning profile doesn't carry the Network Extension entitlement.
    case missingEntitlement
    /// iOS refused to save the VPN configuration at runtime.
    case vpnConfigurationRefused(String)

    var id: String {
        switch self {
        case .simulator: return "simulator"
        case .noExtension: return "noExtension"
        case .missingEntitlement: return "missingEntitlement"
        case .vpnConfigurationRefused: return "vpnRefused"
        }
    }

    /// Short enough for a status row.
    var shortTitle: String {
        switch self {
        case .simulator: return "Simulator — no tunnel"
        case .noExtension: return "Use LocalDevVPN"
        case .missingEntitlement: return "Use LocalDevVPN"
        case .vpnConfigurationRefused: return "Use LocalDevVPN"
        }
    }

    var title: String {
        switch self {
        case .simulator:
            return "No tunnel in the Simulator"
        case .noExtension:
            return "This build has no built-in tunnel"
        case .missingEntitlement:
            return "This build can’t create a VPN"
        case .vpnConfigurationRefused:
            return "iOS refused the VPN configuration"
        }
    }

    var summary: String {
        switch self {
        case .simulator:
            return "Network extensions only run on a real device. Everything else in Locus works here."
        case .noExtension:
            return "Locus normally carries its own loopback tunnel as an app extension. This copy doesn’t have one — LiveContainer can’t load app extensions, and some re-signing tools drop them."
        case .missingEntitlement:
            return "Creating a VPN needs the Network Extension entitlement, and this copy of Locus wasn’t signed with it. Apple only grants it to paid developer accounts, so a build re-signed with a free Apple ID will never have it."
        case .vpnConfigurationRefused(let reason):
            return "iOS wouldn’t save Locus’ VPN profile.\n\n\(reason)"
        }
    }

    /// What to actually do, most likely first.
    var steps: [String] {
        switch self {
        case .simulator:
            return ["Run Locus on a real iPhone to use the tunnel."]
        case .noExtension:
            return [
                "Install LocalDevVPN and connect it. Locus uses whichever tunnel is up, so everything else works exactly the same.",
                "If you’re in LiveContainer, this is expected and there’s no way around it — extensions don’t load there.",
                "If you sideloaded the IPA directly, re-signing with a tool that keeps app extensions will bring the built-in tunnel back.",
            ]
        case .missingEntitlement:
            return [
                "Install LocalDevVPN and connect it. It raises the same loopback tunnel, and Locus will use it.",
                "To get the built-in one instead, re-sign Locus with a paid Apple developer account whose App ID has the Network Extension capability.",
            ]
        case .vpnConfigurationRefused:
            return [
                "If you declined the “Locus would like to add VPN configurations” prompt, tap Connect again and allow it.",
                "Check Settings › General › VPN & Device Management for an old Locus profile and delete it, then try again.",
                "If it keeps failing, this build almost certainly wasn’t signed with the VPN entitlement — install LocalDevVPN and connect that instead.",
            ]
        }
    }

    /// True when installing / opening LocalDevVPN is the real answer.
    var suggestsLocalDevVPN: Bool { self != .simulator }

    /// Permanent for this copy of the app, so there is no point offering a retry.
    var isPermanent: Bool {
        switch self {
        case .simulator, .noExtension, .missingEntitlement: return true
        case .vpnConfigurationRefused: return false
        }
    }
}

/// Something that degrades the tunnel without stopping it.
///
/// Kept apart from `TunnelBlocker` deliberately. A stripped App Group costs the
/// extension's diagnostic log and nothing else; telling someone to go install
/// another app over that would be wrong, and burying it entirely would leave an
/// empty log screen with no explanation.
enum TunnelWarning: Equatable, Identifiable, Hashable {
    case appGroupUnavailable

    var id: String {
        switch self {
        case .appGroupUnavailable: return "appGroup"
        }
    }

    var title: String {
        switch self {
        case .appGroupUnavailable: return "Tunnel log unavailable"
        }
    }

    var detail: String {
        switch self {
        case .appGroupUnavailable:
            return "The App Group (\(LocusTunnelStatusFile.appGroup)) isn’t reachable from this build, usually because a re-signing tool dropped the entitlement. The tunnel itself works normally — only the extension’s own diagnostic log can’t be read."
        }
    }

    var icon: String {
        switch self {
        case .appGroupUnavailable: return "doc.text.magnifyingglass"
        }
    }
}
