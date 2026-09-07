import SwiftUI

@main
struct LocusApp: App {
    // Shared instances rather than fresh ones: App Intents run in this process
    // but outside the view hierarchy, and need to reach the same session and
    // pairing store the UI is showing.
    @StateObject private var session = SpoofSession.shared
    @StateObject private var pairing = PairingStore.shared
    @AppStorage(SetupGate.defaultsKey) private var setupComplete = false
    @AppStorage(LocusAppearance.defaultsKey) private var appearance = LocusAppearance.dark

    /// Map when setup finished, or when already paired outside this walkthrough.
    private var showMap: Bool {
        setupComplete || (pairing.hasPairingFile && !SetupGate.isInProgress)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if showMap {
                    RootView()
                } else {
                    SetupFlowView(initialStep: SetupGate.initialStep(hasPairingFile: pairing.hasPairingFile)) {
                        SetupGate.markComplete()
                        setupComplete = true
                    }
                }
            }
            .environmentObject(session)
            .environmentObject(pairing)
            // `nil` for .system, which hands the choice back to iOS.
            .preferredColorScheme(appearance.colorScheme)
            .onOpenURL { url in
                handleIncoming(url)
            }
            .onAppear {
                if !setupComplete, pairing.hasPairingFile, !SetupGate.isInProgress {
                    SetupGate.markComplete()
                    setupComplete = true
                }
            }
        }
    }

    private func handleIncoming(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        if ["plist", "mobiledevicepairing", "mobiledevicepair"].contains(ext) {
            try? pairing.importPairing(from: url)
            return
        }
        if ext == "gpx" {
            NotificationCenter.default.post(name: .locusImportGPX, object: url)
            return
        }
        // locus://teleport?lat=…&lon=…&name=…, and anything else that spells a
        // location out: a geo: link, a shared Apple/Google/OSM maps URL.
        //
        // The pin is dropped either way, but only `teleport` moves you — a link
        // from a web page shouldn't be able to quietly change where a phone
        // says it is, and `locus://pin` covers "look at this" without that.
        if let match = CoordinateParser.fromURL(url) {
            NotificationCenter.default.post(
                name: .locusOpenLocation,
                object: LocusLocationLink(
                    match: match,
                    teleports: url.host?.lowercased() == "teleport"
                )
            )
        }
    }
}

/// A location arriving from outside the app, and what to do with it.
struct LocusLocationLink {
    var match: CoordinateParser.Match
    var teleports: Bool
}

extension Notification.Name {
    static let locusImportGPX = Notification.Name("locusImportGPX")
    /// Posted with a `LocusLocationLink` when an incoming URL names a place.
    static let locusOpenLocation = Notification.Name("locusOpenLocation")
    /// Posted with a `TunnelBlocker` when something that needed the tunnel found
    /// that this build can't raise one, so the map can open the explanation.
    static let locusShowTunnelTrouble = Notification.Name("locusShowTunnelTrouble")
}
