import NetworkExtension
import SwiftUI

/// Whether Locus can set a location right now, said in four states.
///
/// The Pro status bar reports a loopback tunnel, the packet-rewrite method
/// carrying it, the interface it went over, and whether this copy was signed
/// with an entitlement Apple only grants paid accounts. Every word of that is
/// true, and none of it is answerable by someone who wants to be in Tokyo. So
/// Fun mode says one of four things, and each one is something you can act on.
enum FunConnectionState: Equatable {
    case ready
    case starting
    case off
    /// This build can never switch itself on — sideloaded without the
    /// entitlement, or running somewhere extensions don't load.
    case stuck(TunnelBlocker)

    var label: String {
        switch self {
        case .ready: return "Ready"
        case .starting: return "Switching on…"
        case .off: return "Tap to switch on"
        case .stuck: return "Needs a hand"
        }
    }

    var colour: Color {
        switch self {
        case .ready: return FunTheme.go
        case .starting: return FunTheme.mist
        case .off, .stuck: return FunTheme.punch
        }
    }

    var isReady: Bool { self == .ready }
}

/// Watches the tunnel and reports it in Fun mode's four states.
///
/// Polls on the same two-second beat the Pro status bar does, for the same
/// reason: a tunnel raised by LocalDevVPN sends no notification Locus can hear,
/// so the only way to notice it is to look.
@MainActor
final class FunConnection: ObservableObject {
    @Published private(set) var state: FunConnectionState = .off
    @Published var isWorking = false

    private let tunnel = TunnelController.shared

    func refresh() {
        let next = read()
        if next != state { state = next }
    }

    private func read() -> FunConnectionState {
        if TunnelController.loopbackReachable { return .ready }
        if isWorking { return .starting }

        switch tunnel.state {
        case .connecting:
            return .starting
        case .unavailable(let blocker):
            return .stuck(blocker)
        case .idle, .connected, .failed:
            if let blocker = tunnel.blocker ?? TunnelController.staticBlocker {
                return .stuck(blocker)
            }
            return .off
        }
    }

    /// - Returns: the blocker discovered on the way, if switching on turned one
    ///   up. A stripped entitlement only shows itself when iOS is asked to save
    ///   the configuration, so this can fail in a way `read()` could not have
    ///   predicted a moment earlier.
    @discardableResult
    func switchOn() async -> TunnelBlocker? {
        isWorking = true
        _ = await tunnel.connect()
        isWorking = false
        refresh()
        return tunnel.blocker
    }
}

// MARK: - The pill

/// The connection, top right of every Fun screen that needs one.
struct FunConnectionPill: View {
    @ObservedObject var connection: FunConnection
    var onStuck: (TunnelBlocker) -> Void

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Button {
            switch connection.state {
            case .stuck(let blocker):
                onStuck(blocker)
            case .off:
                Task {
                    if let blocker = await connection.switchOn() { onStuck(blocker) }
                }
            case .ready, .starting:
                break
            }
        } label: {
            HStack(spacing: 7) {
                if case .starting = connection.state {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(FunTheme.mist)
                } else {
                    Circle()
                        .fill(connection.state.colour)
                        .frame(width: 8, height: 8)
                }
                Text(connection.state.label)
                    .font(.fun(13, .bold))
                    .foregroundStyle(connection.state.colour)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Capsule().fill(connection.state.colour.opacity(0.14)))
            .overlay(Capsule().stroke(connection.state.colour.opacity(0.35), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(minHeight: FunMetrics.tap)
        .onAppear { connection.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { connection.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NEVPNStatusDidChange)) { _ in
            connection.refresh()
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                connection.refresh()
            }
        }
        .accessibilityLabel("Connection: \(connection.state.label)")
    }
}

// MARK: - When it can't switch on

/// What Fun mode says when the built-in tunnel can never work on this build.
///
/// The Pro sheet for this reads out the provisioning profile, the expiry that
/// gives away a free Apple account, and which of three checks failed. That is
/// the right answer for whoever sideloaded the app — and it is still one tap
/// away here — but the first screen is the one thing to actually do.
struct FunTroubleSheet: View {
    let blocker: TunnelBlocker
    var onRetry: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showDetail = false
    @State private var installed = LocalDevVPN.isInstalled

    var body: some View {
        ZStack {
            FunTheme.night.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 22) {
                    Text("🔌")
                        .font(.system(size: 56))
                        .padding(.top, 34)

                    VStack(spacing: 10) {
                        Text("Locus needs a hand here")
                            .font(.fun(26, .heavy))
                            .foregroundStyle(FunTheme.ink)
                            .multilineTextAlignment(.center)

                        Text(blocker.suggestsLocalDevVPN
                             ? "This copy of Locus can't switch itself on. A free app called LocalDevVPN does that part, and then everything here works normally."
                             : "This copy of Locus can't switch itself on, and there's nothing to install that would change it.")
                            .font(.fun(16, .semibold))
                            .foregroundStyle(FunTheme.mist)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 8)

                    VStack(spacing: 12) {
                        if blocker.suggestsLocalDevVPN {
                            FunPrimaryButton(
                                title: installed ? "Open LocalDevVPN" : "Get LocalDevVPN",
                                systemImage: installed ? "arrow.up.forward.app.fill" : "arrow.down.app.fill"
                            ) {
                                LocalDevVPN.openOrInstall()
                            }
                        }

                        if !blocker.isPermanent {
                            FunSecondaryButton(title: "Try again", systemImage: "arrow.clockwise") {
                                onRetry()
                                dismiss()
                            }
                        }

                        Button {
                            withAnimation(.snappy) { showDetail.toggle() }
                        } label: {
                            HStack(spacing: 6) {
                                Text(showDetail ? "Hide the details" : "What's going on?")
                                    .font(.fun(15, .bold))
                                Image(systemName: showDetail ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 12, weight: .bold))
                            }
                            .foregroundStyle(FunTheme.mist)
                            .frame(maxWidth: .infinity)
                            .frame(height: FunMetrics.tap)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    if showDetail {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(blocker.title)
                                .font(.fun(15, .heavy))
                                .foregroundStyle(FunTheme.ink)
                            Text(blocker.summary)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(FunTheme.mist)
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach(Array(blocker.steps.enumerated()), id: \.offset) { index, step in
                                HStack(alignment: .top, spacing: 10) {
                                    Text("\(index + 1)")
                                        .font(.fun(12, .heavy))
                                        .foregroundStyle(FunTheme.night)
                                        .frame(width: 20, height: 20)
                                        .background(Circle().fill(FunTheme.grape))
                                    Text(step)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(FunTheme.mist)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .funCard()
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    Spacer(minLength: 20)
                }
                .padding(.horizontal, 20)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { installed = LocalDevVPN.isInstalled }
    }
}
