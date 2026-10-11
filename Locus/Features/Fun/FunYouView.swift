import SwiftUI

/// Six things, one of which is the way out.
///
/// The Pro settings screen is eight sections deep and includes a packet-rewrite
/// method picker, an editable IPv4 address and a raw log. All of that is the
/// right answer for whoever sideloaded this app. None of it belongs on a screen
/// whose job is "make it work, and let me leave".
struct FunYouView: View {
    @ObservedObject var settings: FunSettings
    @ObservedObject var connection: FunConnection
    var onStuck: (TunnelBlocker) -> Void

    @EnvironmentObject private var session: SpoofSession

    @AppStorage(LocusInterfaceMode.defaultsKey) private var interface = LocusInterfaceMode.pro
    @State private var confirmingPro = false
    @State private var showAbout = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                FunTitle(text: "You")

                interfaceCard

                settingsCard

                Button {
                    showAbout = true
                } label: {
                    HStack(spacing: 14) {
                        Text("💜").font(.system(size: 22))
                        Text("About Locus")
                            .font(.fun(16, .bold))
                            .foregroundStyle(FunTheme.ink)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .heavy))
                            .foregroundStyle(FunTheme.mist)
                    }
                    .padding(.horizontal, 18)
                    .frame(minHeight: 60)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .funCard(24)

                Text("Everything stays on this iPhone. Nothing is uploaded.")
                    .font(.fun(12, .semibold))
                    .foregroundStyle(FunTheme.mist.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, FunMetrics.tabBar + 20)
        }
        .sheet(isPresented: $showAbout) {
            FunAboutSheet()
        }
        .confirmationDialog(
            "Switch to Pro?",
            isPresented: $confirmingPro,
            titleVisibility: .visible
        ) {
            Button("Switch to Pro") { interface = .pro }
            Button("Stay here", role: .cancel) {}
        } message: {
            Text("Pro is the whole app — the map, route planning and every driving parameter. Your spots come with you, and Fun mode is one tap away in its Settings.")
        }
    }

    // MARK: - Which app this is

    private var interfaceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            FunSectionLabel(text: "Interface")

            HStack(spacing: 12) {
                ForEach(LocusInterfaceMode.allCases) { mode in
                    Button {
                        guard mode != interface else { return }
                        confirmingPro = true
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(mode.emoji)
                                .font(.system(size: 26))
                            Text(mode.title)
                                .font(.fun(17, .heavy))
                                .foregroundStyle(FunTheme.ink)
                            Text(mode.summary)
                                .font(.fun(12, .semibold))
                                .foregroundStyle(mode == interface ? FunTheme.punch.opacity(0.9) : FunTheme.mist)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .fill(mode == interface ? FunTheme.punch.opacity(0.16) : Color.white.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(mode == interface ? FunTheme.punch : FunTheme.line,
                                        lineWidth: mode == interface ? 1.5 : 1)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(mode == interface ? [.isSelected] : [])
                }
            }
        }
        .padding(18)
        .funCard()
    }

    // MARK: - The rest

    private var settingsCard: some View {
        VStack(spacing: 0) {
            FunRow(emoji: "🔌", title: "Connection") {
                Button {
                    switch connection.state {
                    case .stuck(let blocker): onStuck(blocker)
                    case .off: Task { if let blocker = await connection.switchOn() { onStuck(blocker) } }
                    case .ready, .starting: break
                    }
                } label: {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(connection.state.colour)
                            .frame(width: 8, height: 8)
                        Text(connection.state.label)
                            .font(.fun(15, .bold))
                            .foregroundStyle(connection.state.colour)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            FunRow(emoji: "📏", title: "Speed in") {
                FunSegment(
                    options: SpeedUnit.allCases.map { FunSegmentOption(value: $0, label: $0.short) },
                    selection: Binding(
                        get: { settings.units },
                        set: { settings.units = $0 }
                    )
                )
            }

            FunRow(emoji: "📳", title: "Buzz when you arrive") {
                Toggle("", isOn: Binding(
                    get: { settings.buzz },
                    set: { settings.buzz = $0 }
                ))
                .labelsHidden()
                .tint(FunTheme.go)
            }

            FunRow(emoji: "💡", title: "Keep the screen on", showsDivider: false) {
                Toggle("", isOn: Binding(
                    get: { settings.keepScreenOn },
                    set: { settings.keepScreenOn = $0 }
                ))
                .labelsHidden()
                .tint(FunTheme.go)
            }
        }
        .funCard()
        .onAppear { connection.refresh() }
    }
}

/// Short, and carrying the one thing the licence requires be carried.
struct FunAboutSheet: View {
    @Environment(\.dismiss) private var dismiss

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }

    var body: some View {
        ZStack {
            FunTheme.night.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 20) {
                    Text("💜").font(.system(size: 56)).padding(.top, 30)

                    Text("Locus \(version)")
                        .font(.fun(24, .heavy))
                        .foregroundStyle(FunTheme.ink)

                    VStack(spacing: 14) {
                        Text("Free and open source, under the MIT licence. Nothing about you leaves this iPhone: no account, no analytics, nothing uploaded.")
                        Text("The built-in connection is based on and uses code from LocalDevVPN (StosVPN) by Stossy11 and the SideStore Team, used under the StosVPN License.")
                        Text("Location injection uses the MIT-licensed idevice FFI.")
                    }
                    .font(.fun(14, .semibold))
                    .foregroundStyle(FunTheme.mist)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(18)
                    .funCard()

                    Spacer(minLength: 10)

                    FunPrimaryButton(title: "Done", systemImage: nil) { dismiss() }
                        .padding(.bottom, 24)
                }
                .padding(.horizontal, 20)
            }
        }
        .preferredColorScheme(.dark)
    }
}
