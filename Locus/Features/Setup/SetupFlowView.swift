import SwiftUI
import UniformTypeIdentifiers

/// First-run walkthrough: welcome → pairing → LocalDevVPN → map.
/// Skipped when `SetupGate.isComplete` (see `LocusApp`).
struct SetupFlowView: View {
    @EnvironmentObject private var pairing: PairingStore
    @EnvironmentObject private var session: SpoofSession

    var onFinished: () -> Void

    @State private var step: Step
    @State private var appear = false
    @State private var showImporter = false
    @State private var localDevVPNInstalled = LocalDevVPN.isInstalled
    @State private var tunnelUp = TunnelController.loopbackReachable
    @State private var isConnectingTunnel = false
    @State private var troubleBlocker: TunnelBlocker?
    @StateObject private var tunnel = TunnelController.shared
    @Environment(\.scenePhase) private var scenePhase

    enum Step: Int, CaseIterable {
        case welcome
        case pairing
        case vpn
    }

    init(initialStep: Step = .welcome, onFinished: @escaping () -> Void) {
        _step = State(initialValue: initialStep)
        self.onFinished = onFinished
    }

    private var supportsOnDevicePairing: Bool {
        if #available(iOS 27.0, *) { return true }
        return false
    }

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                progressBar
                    .padding(.horizontal, 24)
                    .padding(.top, 12)

                Group {
                    switch step {
                    case .welcome:
                        welcomePage
                    case .pairing:
                        pairingPage
                    case .vpn:
                        vpnPage
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(step)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
            }
            .padding(.bottom, 8)
        }
        .preferredColorScheme(.dark)
        .animation(.spring(response: 0.45, dampingFraction: 0.86), value: step)
        .onAppear {
            withAnimation(.easeOut(duration: 0.7)) { appear = true }
            localDevVPNInstalled = LocalDevVPN.isInstalled
            tunnelUp = TunnelController.loopbackReachable
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                localDevVPNInstalled = LocalDevVPN.isInstalled
                tunnelUp = TunnelController.loopbackReachable
            }
        }
        .onChange(of: step) { _, newStep in
            if newStep == .vpn {
                localDevVPNInstalled = LocalDevVPN.isInstalled
                tunnelUp = TunnelController.loopbackReachable
            }
        }
        .onChange(of: pairing.hasPairingFile) { _, hasFile in
            if hasFile, step == .welcome || step == .pairing {
                SetupGate.markInProgress()
                withAnimation { step = .vpn }
            }
        }
        .sheet(isPresented: $showImporter) {
            PairingDocumentPicker(
                onPick: { url in
                    showImporter = false
                    do {
                        try pairing.importPairing(from: url)
                        withAnimation { step = .vpn }
                    } catch {
                        session.lastError = error.localizedDescription
                    }
                },
                onCancel: { showImporter = false }
            )
            .ignoresSafeArea()
        }
        .sheet(item: $troubleBlocker) { blocker in
            TunnelTroubleView(blocker: blocker) { connectTunnel() }
        }
        .alert("Locus", isPresented: Binding(
            get: { session.lastError != nil },
            set: { if !$0 { session.lastError = nil } }
        )) {
            Button("OK", role: .cancel) { session.lastError = nil }
        } message: {
            Text(session.lastError ?? "")
        }
    }

    // MARK: - Chrome

    private var background: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Soft map-adjacent atmosphere (no flat fill).
            RadialGradient(
                colors: [
                    LocusTheme.accent.opacity(0.22),
                    Color.clear
                ],
                center: .topTrailing,
                startRadius: 40,
                endRadius: 420
            )
            .ignoresSafeArea()

            RadialGradient(
                colors: [
                    Color(red: 0.12, green: 0.18, blue: 0.28).opacity(0.9),
                    Color.clear
                ],
                center: .bottomLeading,
                startRadius: 20,
                endRadius: 380
            )
            .ignoresSafeArea()

            // Subtle grid suggestion of a map without competing with copy.
            GeometryReader { geo in
                Path { path in
                    let spacing: CGFloat = 44
                    for x in stride(from: 0, through: geo.size.width, by: spacing) {
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: geo.size.height))
                    }
                    for y in stride(from: 0, through: geo.size.height, by: spacing) {
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                }
                .stroke(Color.white.opacity(0.04), lineWidth: 1)
            }
            .ignoresSafeArea()
        }
    }

    private var progressBar: some View {
        HStack(spacing: 8) {
            ForEach(Step.allCases, id: \.rawValue) { s in
                Capsule()
                    .fill(s.rawValue <= step.rawValue ? LocusTheme.accent : Color.white.opacity(0.12))
                    .frame(height: 3)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
    }

    // MARK: - Welcome

    private var welcomePage: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            VStack(spacing: 20) {
                Image(systemName: "location.north.circle.fill")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(LocusTheme.accent)
                    .symbolEffect(.pulse, options: .repeating.speed(0.4), isActive: appear)
                    .opacity(appear ? 1 : 0)
                    .scaleEffect(appear ? 1 : 0.85)

                VStack(spacing: 10) {
                    Text("Locus")
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .tracking(-0.5)

                    Text("Teleport your location.\nNo computer required.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .opacity(appear ? 1 : 0)
                .offset(y: appear ? 0 : 12)
            }
            .padding(.horizontal, 28)

            Spacer()

            VStack(spacing: 14) {
                Text("A short setup — about two minutes.")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)

                primaryButton("Get started") {
                    SetupGate.markInProgress()
                    withAnimation { step = .pairing }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
            .opacity(appear ? 1 : 0)
        }
    }

    // MARK: - Pairing

    private var pairingPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Connect this iPhone")
                    .font(.title.weight(.bold))
                Text(supportsOnDevicePairing
                     ? "Locus needs a one-time pairing so it can set your location. You’ll confirm a short code in Settings."
                     : "Import a pairing file from your computer — Locus uses it to set your location securely on this device.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 16)

            if supportsOnDevicePairing {
                PairOnDeviceView(mode: .embedded) {
                    withAnimation { step = .vpn }
                }
                .environmentObject(pairing)
            } else {
                importPairingCard
                    .padding(.horizontal, 24)
                Spacer()
                VStack(spacing: 12) {
                    primaryButton("Import pairing file") {
                        showImporter = true
                    }
                    Button {
                        do {
                            try pairing.importPairingFromClipboard()
                            withAnimation { step = .vpn }
                        } catch {
                            session.lastError = error.localizedDescription
                        }
                    } label: {
                        Text("Paste from clipboard")
                            .frame(maxWidth: .infinity)
                    }
                    .locusSecondaryButton()
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
            }
        }
    }

    private var importPairingCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepRow(1, "On a Mac, run idevice_pair and create an RPPairing file.")
            stepRow(2, "AirDrop / Share into Locus, or copy the plist text.")
            stepRow(3, "Tap Import, or Paste from clipboard if the picker doesn’t work (LiveContainer).")
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .locusGlass(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func stepRow(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.black)
                .frame(width: 22, height: 22)
                .background(LocusTheme.accent, in: Circle())
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Tunnel

    /// Locus carries its own loopback tunnel now, so this step is one button
    /// rather than a trip to another app. The LocalDevVPN hand-off is kept for
    /// LiveContainer, where app extensions can't load at all.
    private var vpnPage: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)

            VStack(spacing: 22) {
                Image(systemName: tunnelUp ? "checkmark.shield.fill" : "lock.shield.fill")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(tunnelUp ? LocusTheme.statusGood : LocusTheme.accent)
                    .id(tunnelUp)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))

                VStack(spacing: 10) {
                    Text(vpnTitle)
                        .font(.title.weight(.bold))
                        .multilineTextAlignment(.center)

                    Text(vpnBody)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 12) {
                    if tunnelUp {
                        tipRow(systemImage: "checkmark.circle.fill", title: "Tunnel up", detail: "Locus can reach your iPhone's own developer service. You're ready.")
                    } else if let blocker = activeBlocker {
                        tipRow(systemImage: "exclamationmark.triangle.fill", title: blocker.title, detail: blocker.summary)
                        tipRow(systemImage: "arrow.down.app.fill", title: "Use LocalDevVPN", detail: "It raises the same tunnel on \(TunnelConfig.targetIP), and Locus uses whichever one is up.")
                    } else {
                        tipRow(systemImage: "bolt.fill", title: "One tap", detail: "Locus starts its own loopback tunnel. iOS will ask once to allow the VPN configuration.")
                        tipRow(systemImage: "hand.raised.fill", title: "Nothing leaves the phone", detail: "It only lets this iPhone talk to itself at \(TunnelConfig.targetIP). It forwards no traffic anywhere.")
                    }
                    tipRow(systemImage: "wifi", title: "First teleport on Wi\u{2011}Fi", detail: "Start your first teleport while on Wi\u{2011}Fi. After that, it can keep working on cellular.")
                }
                .padding(18)
                .locusGlass(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .padding(.horizontal, 24)

            Spacer()

            VStack(spacing: 12) {
                if !tunnelUp, activeBlocker == nil {
                    Button(action: connectTunnel) {
                        HStack(spacing: 8) {
                            if isConnectingTunnel {
                                ProgressView().tint(.black)
                            } else {
                                Image(systemName: "bolt.fill")
                            }
                            Text(isConnectingTunnel ? "Starting the tunnel…" : "Turn on the tunnel")
                                .fontWeight(.semibold)
                        }
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Capsule().fill(LocusTheme.accent))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isConnectingTunnel)
                } else if !tunnelUp, let blocker = activeBlocker, blocker.suggestsLocalDevVPN {
                    Button {
                        LocalDevVPN.openOrInstall()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: localDevVPNInstalled ? "lock.shield.fill" : "apple.logo")
                            Text(localDevVPNInstalled ? "Open LocalDevVPN" : "Get LocalDevVPN")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .locusPrimaryButton()

                    Button("Why can’t Locus do this itself?") {
                        troubleBlocker = blocker
                    }
                    .font(.subheadline)
                    .buttonStyle(.plain)
                    .foregroundStyle(LocusTheme.accent)
                    .frame(maxWidth: .infinity)
                }

                if tunnelUp || activeBlocker == nil {
                    primaryButton(tunnelUp ? "Start teleporting" : "Skip for now") {
                        onFinished()
                    }
                } else {
                    Button("I’ve connected it — continue") {
                        onFinished()
                    }
                    .locusSecondaryButton()
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: tunnelUp)
    }

    /// Whether this copy of Locus can raise its own tunnel at all. Sideloaded
    /// builds signed with a free profile can't, and that has to be said here
    /// rather than three screens later when a teleport fails.
    private var activeBlocker: TunnelBlocker? {
        tunnel.blocker ?? TunnelController.staticBlocker
    }

    private var vpnTitle: String {
        if tunnelUp { return "You're all set" }
        if let blocker = activeBlocker {
            return blocker.suggestsLocalDevVPN ? "One more app" : blocker.title
        }
        return "Turn on the tunnel"
    }

    private var vpnBody: String {
        if tunnelUp {
            return "The tunnel is up and Locus can talk to your iPhone's location system."
        }
        if let blocker = activeBlocker {
            guard blocker.suggestsLocalDevVPN else { return blocker.summary }
            return "This copy of Locus can't create the tunnel itself, so LocalDevVPN does it. Install it, turn it on, and come back — everything else works exactly the same."
        }
        return "Locus needs a private loopback tunnel to reach your iPhone's own developer service. It carries one built in — this just switches it on."
    }

    private func connectTunnel() {
        isConnectingTunnel = true
        Task {
            let connected = await tunnel.connect()
            isConnectingTunnel = false
            tunnelUp = TunnelController.loopbackReachable || connected
            if !connected, case .failed(let reason) = tunnel.state {
                session.lastError = reason
            }
        }
    }

    private func tipRow(systemImage: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(LocusTheme.accent)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Shared

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity)
        }
        .locusPrimaryButton()
    }
}

// MARK: - Gate

enum SetupGate {
    static let defaultsKey = "locus.setupComplete"
    static let inProgressKey = "locus.setupInProgress"

    static var isComplete: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }

    static var isInProgress: Bool {
        UserDefaults.standard.bool(forKey: inProgressKey)
    }

    static func markInProgress() {
        UserDefaults.standard.set(true, forKey: inProgressKey)
    }

    static func markComplete() {
        UserDefaults.standard.set(true, forKey: defaultsKey)
        UserDefaults.standard.set(false, forKey: inProgressKey)
    }

    /// Already paired *during* this walkthrough → LocalDevVPN page.
    /// Fresh install → welcome. Already-paired upgrades are handled in `LocusApp`.
    static func initialStep(hasPairingFile: Bool) -> SetupFlowView.Step {
        if hasPairingFile, isInProgress { return .vpn }
        return .welcome
    }
}
