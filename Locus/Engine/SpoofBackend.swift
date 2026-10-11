import Foundation

/// How Locus makes the phone believe it is somewhere else.
///
/// - `developer`: Apple's developer location service, reached over the loopback
///   tunnel with an RPPairing file — what Xcode does. Overrides the whole
///   location stack, GPS included, and moves smoothly, so routes and the joystick
///   work. Needs pairing.
/// - `network`: rewrites Apple's Wi-Fi/cell positioning replies on the device
///   itself, through Locus' own tunnel and a certificate the user trusts. Needs
///   no pairing and no Developer Mode, but only steers Wi-Fi/cell positioning:
///   a good GPS sky view can still win, and iOS only asks again now and then, so
///   it is for teleporting rather than for moving.
enum SpoofBackend: String, CaseIterable, Identifiable {
    case developer
    case network

    var id: String { rawValue }

    private static let defaultsKey = "locus.spoofBackend"

    static var current: SpoofBackend {
        get {
            UserDefaults.standard.string(forKey: defaultsKey).flatMap(SpoofBackend.init(rawValue:)) ?? .developer
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }

    var title: String {
        switch self {
        case .developer: return "Developer"
        case .network: return "Network"
        }
    }

    var detail: String {
        switch self {
        case .developer:
            return "Apple’s developer location service, like Xcode. Overrides GPS too and moves smoothly, so routes and the joystick work. Needs an RPPairing file."
        case .network:
            return "Rewrites Apple’s Wi-Fi and cell-tower positioning replies on this iPhone. No pairing needed, but GPS can still disagree and iOS only re-asks now and then — best for teleporting."
        }
    }

    /// Why this method can't be used right now, or `nil` if it can. Spoken to
    /// the person: it ends up in the error banner.
    @MainActor
    func readinessProblem(pairing: PairingStore) -> String? {
        switch self {
        case .developer:
            return pairing.hasPairingFile ? nil : "Import an RPPairing file in Settings first."
        case .network:
            if let blocker = TunnelController.staticBlocker {
                return "Network mode needs Locus’ own tunnel, and this build can’t run it (\(blocker.title.lowercased()))."
            }
            switch InterceptIdentity.shared.trust {
            case .trusted:
                return nil
            case .notCreated, .notTrusted:
                return "Install and trust the Locus certificate first: Settings → Network mode."
            }
        }
    }
}
