import SwiftUI

enum FunTab: String, CaseIterable, Identifiable {
    case spots
    case move
    case trip
    case you

    var id: String { rawValue }

    var title: String {
        switch self {
        case .spots: return "Spots"
        case .move: return "Move"
        case .trip: return "Trip"
        case .you: return "You"
        }
    }

    var icon: String {
        switch self {
        case .spots: return "mappin.and.ellipse"
        case .move: return "dot.circle.and.hand.point.up.left.fill"
        case .trip: return "point.topleft.down.to.point.bottomright.curvepath"
        case .you: return "person.fill"
        }
    }
}

/// Fun mode's shell: four tabs over the same engine the Pro map drives.
///
/// The structural break from Pro is here. Pro is one map with everything
/// floating on top of it, because someone who knows what they want wants it all
/// within reach. This is four screens that each do one thing, because the way
/// to make something usable by someone who has never seen it is to only ever
/// ask them one question at a time.
struct FunRootView: View {
    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var pairing: PairingStore

    @StateObject private var settings = FunSettings()
    @StateObject private var connection = FunConnection()

    @State private var tab: FunTab = .spots
    @State private var trouble: TunnelBlocker?

    var body: some View {
        ZStack(alignment: .bottom) {
            FunTheme.night.ignoresSafeArea()

            Group {
                switch tab {
                case .spots:
                    FunSpotsView(settings: settings, connection: connection, onStuck: { trouble = $0 })
                case .move:
                    FunMoveView(settings: settings, connection: connection, onStuck: { trouble = $0 })
                case .trip:
                    FunTripView(settings: settings, connection: connection, onStuck: { trouble = $0 })
                case .you:
                    FunYouView(settings: settings, connection: connection, onStuck: { trouble = $0 })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
            // Attached here rather than beside the trouble sheet below: SwiftUI
            // presents one sheet per view, and two on the same one means the
            // second silently replaces the first.
            .sheet(item: Binding(
                get: { session.lastTrip },
                set: { session.lastTrip = $0 }
            )) { trip in
                FunArrivedSheet(trip: trip)
                    .environmentObject(session)
                    .environmentObject(pairing)
                    .presentationDetents([.medium])
            }

            FunTabBar(selection: $tab)
        }
        .preferredColorScheme(.dark)
        .animation(.snappy(duration: 0.22), value: tab)
        // Fun mode drives with its own parameters and never writes to the
        // profiles someone tuned in Pro mode. Cleared on the way out, so Pro is
        // exactly as it was left.
        .task { syncProfile() }
        .onChange(of: settings.stamp) { _, _ in syncProfile() }
        .onChange(of: session.travelMode) { _, _ in syncProfile() }
        .onDisappear {
            session.profileOverride = nil
            session.joystickSpeed = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .locusShowTunnelTrouble)) { note in
            guard let blocker = note.object as? TunnelBlocker else { return }
            trouble = blocker
        }
        .sheet(item: $trouble) { blocker in
            FunTroubleSheet(blocker: blocker) {
                Task { await connection.switchOn() }
            }
        }
        // A route in flight takes the whole screen: while you are watching a
        // car cross a city there is nothing else on this phone to tap.
        .fullScreenCover(isPresented: Binding(
            get: { session.telemetry != nil },
            set: { if !$0, session.telemetry != nil { session.cancelRoute() } }
        )) {
            FunTripRunningView(settings: settings)
                .environmentObject(session)
        }
        .alert("Hm", isPresented: Binding(
            get: { session.lastError != nil },
            set: { if !$0 { session.lastError = nil } }
        )) {
            Button("OK", role: .cancel) { session.lastError = nil }
        } message: {
            Text(session.lastError ?? "")
        }
    }

    private func syncProfile() {
        session.profileOverride = settings.profile(for: session.travelMode)
    }
}

/// Four tabs, drawn rather than borrowed: `TabView`'s bar is a system grey
/// strip that would sit under this palette looking like part of another app.
struct FunTabBar: View {
    @Binding var selection: FunTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(FunTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 20, weight: .semibold))
                        Text(tab.title)
                            .font(.fun(11, selection == tab ? .heavy : .bold))
                    }
                    .foregroundStyle(selection == tab ? FunTheme.punch : FunTheme.mist)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selection == tab ? [.isSelected] : [])
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .background(
            FunTheme.night.opacity(0.94)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 1)
                }
                .ignoresSafeArea(edges: .bottom)
        )
    }
}
