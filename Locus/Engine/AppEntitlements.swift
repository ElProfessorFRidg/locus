import Foundation

/// What this particular *copy* of Locus is actually allowed to do.
///
/// Locus is sideloaded, not shipped through the App Store, so the entitlements
/// in the source tree are a request, not a fact. Whatever re-signed the IPA —
/// AltStore, SideStore, Feather, Sideloadly, ESign — provisions it with its own
/// profile, and free Apple developer accounts cannot be granted
/// `packet-tunnel-provider` at all. The built-in tunnel then fails at the point
/// iOS is asked to save a VPN configuration, with an error that says nothing
/// about why.
///
/// Reading the embedded provisioning profile turns that into something the app
/// can say up front: *this build can't run the tunnel, use LocalDevVPN.*
///
/// It is a best-effort read. Ad-hoc and TrollStore installs carry no profile at
/// all — `unknown` is an honest answer there, and the runtime failure path still
/// catches the problem the first time a connect is attempted.
enum AppEntitlements {

    /// Three-state on purpose: "we looked and it isn't there" and "we couldn't
    /// look" lead to different UI. Only `.no` is worth warning about before
    /// anything has been tried.
    enum Answer: Equatable {
        case yes
        case no
        case unknown

        var isDefinitelyMissing: Bool { self == .no }
    }

    /// Parsed once — the profile can't change while the app is running.
    private static let profile: [String: Any]? = loadProfile()

    private static var entitlements: [String: Any]? {
        profile?["Entitlements"] as? [String: Any]
    }

    /// Whether this build carries the packet-tunnel entitlement the embedded
    /// extension needs. Without it iOS refuses to save the VPN configuration.
    static var hasPacketTunnelProvider: Answer {
        guard let entitlements else { return .unknown }
        guard let values = entitlements["com.apple.developer.networking.networkextension"] as? [String] else {
            return .no
        }
        return values.contains("packet-tunnel-provider") ? .yes : .no
    }

    /// The plain "may create VPN configurations" entitlement. Some profiles grant
    /// one of the pair and not the other, and either one missing is fatal to the
    /// built-in tunnel.
    static var hasVPNAPI: Answer {
        guard let entitlements else { return .unknown }
        guard let values = entitlements["com.apple.developer.networking.vpn.api"] as? [String] else {
            return .no
        }
        return values.contains("allow-vpn") ? .yes : .no
    }

    /// App Groups the profile grants. Locus only uses one, and only for the
    /// tunnel's diagnostic log — a missing group degrades the log, nothing else.
    static var applicationGroups: [String]? {
        entitlements?["com.apple.security.application-groups"] as? [String]
    }

    static var hasLocusAppGroup: Answer {
        guard let groups = applicationGroups else {
            return entitlements == nil ? .unknown : .no
        }
        return groups.contains(LocusTunnelStatusFile.appGroup) ? .yes : .no
    }

    /// True when the App Group container is genuinely reachable — the only test
    /// that matters, since the entitlement can be present and the container
    /// still absent (and vice versa on some re-signers).
    static var appGroupWorks: Bool { LocusTunnelStatusFile.isAvailable }

    // MARK: Provenance, for the diagnostics screen

    /// Name of the provisioning profile, e.g. "iOS Team Provisioning Profile: *".
    static var profileName: String? { profile?["Name"] as? String }

    static var teamName: String? { profile?["TeamName"] as? String }

    static var expirationDate: Date? { profile?["ExpirationDate"] as? Date }

    /// A free Apple developer account gets a 7-day profile; a paid one gets a
    /// year. That gap is the single most reliable signal of which kind of
    /// account re-signed this build, and free accounts can never be granted
    /// Network Extension.
    static var looksLikeFreeAccount: Bool {
        guard let expiry = expirationDate else { return false }
        return expiry.timeIntervalSinceNow < 60 * 60 * 24 * 14
    }

    static var hasProfile: Bool { profile != nil }

    /// `TEAMID.com.chrismack.locus`, when the profile says so.
    static var applicationIdentifier: String? {
        entitlements?["application-identifier"] as? String
    }

    // MARK: - Parsing

    /// `embedded.mobileprovision` is a CMS (PKCS#7) blob with an XML plist in the
    /// middle. Verifying the signature would need Security framework APIs that
    /// aren't public on iOS, and it isn't the point here — this is a diagnostic
    /// read of our own bundle, not a trust decision. So the plist is sliced out
    /// between its opening declaration and closing tag and parsed directly.
    private static func loadProfile() -> [String: Any]? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return nil }

        guard let start = data.firstRange(of: Data("<?xml".utf8)),
              let end = data.lastRange(of: Data("</plist>".utf8)) else { return nil }

        let slice = data[start.lowerBound..<end.upperBound]
        return (try? PropertyListSerialization.propertyList(
            from: slice,
            options: [],
            format: nil
        )) as? [String: Any]
    }
}

private extension Data {
    /// `Data.firstRange(of:)` exists on newer SDKs but not as far back as this
    /// project targets in every configuration; a plain scan is small and avoids
    /// the availability question entirely.
    func firstRange(of pattern: Data) -> Range<Index>? {
        guard !pattern.isEmpty, count >= pattern.count else { return nil }
        let limit = count - pattern.count
        for offset in 0...limit {
            let start = startIndex + offset
            if self[start..<(start + pattern.count)].elementsEqual(pattern) {
                return start..<(start + pattern.count)
            }
        }
        return nil
    }

    func lastRange(of pattern: Data) -> Range<Index>? {
        guard !pattern.isEmpty, count >= pattern.count else { return nil }
        let limit = count - pattern.count
        for offset in stride(from: limit, through: 0, by: -1) {
            let start = startIndex + offset
            if self[start..<(start + pattern.count)].elementsEqual(pattern) {
                return start..<(start + pattern.count)
            }
        }
        return nil
    }
}
