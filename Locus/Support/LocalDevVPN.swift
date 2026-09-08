import Foundation
import UIKit

/// Hand-off to the standalone **LocalDevVPN** app.
///
/// Locus ships its own copy of the loopback tunnel now (see `TunnelController`),
/// so this is the fallback for the one case the built-in tunnel can't cover:
/// LiveContainer, which cannot load app extensions at all. Everything here is
/// deliberately best-effort — `isInstalled` depends on LocalDevVPN declaring a
/// URL scheme, which older App Store builds do not, so a `false` here means
/// "couldn't confirm", not "definitely absent".
enum LocalDevVPN {
    static let appStoreURL = URL(string: "https://apps.apple.com/us/app/localdevvpn/id6755608044")!
    static let detectURL = URL(string: "localdevvpn://")!

    /// Starts the tunnel, then returns to Locus via `locus://`.
    static let enableURL = URL(string: "localdevvpn://enable?scheme=locus")!

    static var isInstalled: Bool {
        UIApplication.shared.canOpenURL(detectURL)
    }

    /// The loopback subnet is up, whoever raised it.
    static var isConnected: Bool {
        TunnelController.loopbackReachable
    }

    static func openInstalled() {
        // Older LocalDevVPN builds don't handle `enable`; opening the bare
        // scheme at least gets the user to the connect button.
        UIApplication.shared.open(enableURL, options: [:]) { opened in
            if !opened {
                UIApplication.shared.open(detectURL)
            }
        }
    }

    static func openAppStore() {
        UIApplication.shared.open(appStoreURL)
    }

    /// Open LocalDevVPN to connect if installed; otherwise the App Store.
    static func openOrInstall() {
        if isInstalled {
            openInstalled()
        } else {
            openAppStore()
        }
    }
}
