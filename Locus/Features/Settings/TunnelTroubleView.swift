import SwiftUI

/// The full explanation for "the built-in tunnel can't run here", with the one
/// thing that actually fixes it right at the top.
///
/// Locus is sideloaded, so this is a normal outcome rather than an edge case: a
/// free signing profile can't carry the Network Extension entitlement, and
/// LiveContainer can't load app extensions at all. The point of this screen is
/// that nobody has to work that out from a "permission denied".
struct TunnelTroubleView: View {
    let blocker: TunnelBlocker
    var onRetry: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var localDevVPNInstalled = LocalDevVPN.isInstalled
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header

                    if blocker.suggestsLocalDevVPN {
                        localDevVPNCard
                    }

                    steps

                    if !blocker.isPermanent, let onRetry {
                        Button {
                            dismiss()
                            onRetry()
                        } label: {
                            Label("Try the built-in tunnel again", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .locusSecondaryButton()
                    }

                    buildDetails
                }
                .padding(20)
            }
            .navigationTitle("Tunnel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { localDevVPNInstalled = LocalDevVPN.isInstalled }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { localDevVPNInstalled = LocalDevVPN.isInstalled }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(LocusTheme.statusWarn)

            Text(blocker.title)
                .font(.title2.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)

            Text(blocker.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The way out, given its own card because it is the answer in every case
    /// that isn't the Simulator.
    private var localDevVPNCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Use LocalDevVPN instead", systemImage: "arrow.triangle.branch")
                .font(.headline)

            Text("LocalDevVPN raises exactly the same loopback tunnel on \(TunnelConfig.targetIP). Connect it once and Locus uses it — teleport, joystick, routes and everything else work the same way.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                LocalDevVPN.openOrInstall()
            } label: {
                Label(
                    localDevVPNInstalled ? "Open LocalDevVPN" : "Get LocalDevVPN",
                    systemImage: localDevVPNInstalled ? "lock.shield.fill" : "arrow.down.app.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .locusPrimaryButton()

            if !localDevVPNInstalled {
                Text("Locus can’t always tell whether LocalDevVPN is installed — older versions of it don’t declare a URL scheme. If you already have it, just open it from the Home Screen.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .locusGlass(.regular, in: RoundedRectangle(cornerRadius: LocusMetrics.panelRadius, style: .continuous))
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What you can do")
                .font(.headline)

            ForEach(Array(blocker.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 12) {
                    Text("\(index + 1)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.black)
                        .frame(width: 22, height: 22)
                        .background(LocusTheme.accent, in: Circle())
                    Text(step)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The facts someone would otherwise have to guess at, or ask for in an
    /// issue. Free profiles expire in a week; paid ones in a year — that gap is
    /// the clearest signal of which kind of account signed this build.
    private var buildDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("This build")
                .font(.headline)

            detailRow("Tunnel extension", TunnelController.isEmbedded ? "Present" : "Not in the bundle")
            detailRow("Network Extension", describe(AppEntitlements.hasPacketTunnelProvider))
            detailRow("VPN configurations", describe(AppEntitlements.hasVPNAPI))
            detailRow("App Group", AppEntitlements.appGroupWorks ? "Reachable" : "Not reachable")

            if let name = AppEntitlements.profileName {
                detailRow("Profile", name)
            }
            if let team = AppEntitlements.teamName {
                detailRow("Signed by", team)
            }
            if let expiry = AppEntitlements.expirationDate {
                detailRow("Profile expires", expiry.formatted(date: .abbreviated, time: .omitted))
            }

            if AppEntitlements.looksLikeFreeAccount {
                Text("That expiry is about a week away, which means a free Apple developer account. Those can’t be granted the Network Extension entitlement, so the built-in tunnel will never work on this build — LocalDevVPN is the way.")
                    .font(.caption)
                    .foregroundStyle(LocusTheme.statusWarn)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            } else if !AppEntitlements.hasProfile {
                Text("No provisioning profile in the bundle, so Locus can’t read what this copy was signed with — the checks above fall back to what actually happens when the tunnel is started.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .locusGlass(.clear, in: RoundedRectangle(cornerRadius: LocusMetrics.panelRadius, style: .continuous))
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.caption.weight(.medium))
                .multilineTextAlignment(.trailing)
        }
    }

    private func describe(_ answer: AppEntitlements.Answer) -> String {
        switch answer {
        case .yes: return "Granted"
        case .no: return "Not granted"
        case .unknown: return "Can’t tell"
        }
    }
}

/// Compact version for Settings and the setup walkthrough: says the thing, and
/// opens the full explanation.
struct TunnelTroubleBanner: View {
    let blocker: TunnelBlocker
    var onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(LocusTheme.statusWarn)

                VStack(alignment: .leading, spacing: 3) {
                    Text(blocker.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    Text(blocker.suggestsLocalDevVPN
                         ? "Connect the LocalDevVPN app instead — tap for the details."
                         : "Tap for the details.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A degraded-but-working note, for things that don't warrant sending anyone off
/// to install a second app.
struct TunnelWarningRow: View {
    let warning: TunnelWarning

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: warning.icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(warning.title)
                    .font(.subheadline.weight(.semibold))
                Text(warning.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }
}
