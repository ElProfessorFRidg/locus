import SwiftUI
import UIKit

/// Everything network mode needs from a person, in the order they need to do it:
/// install a certificate, switch it on, check it works.
struct NetworkModeView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var identity = InterceptIdentity.shared
    @StateObject private var spoofer = NetworkSpoofer.shared
    @StateObject private var tunnel = TunnelController.shared

    @State private var message: String?
    @State private var shareURL: URL?
    @State private var confirmReset = false

    var body: some View {
        NavigationStack {
            List {
                introSection
                certificateSection
                checkSection
                if let status = spoofer.status { activitySection(status) }
                limitsSection
            }
            .navigationTitle("Network mode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                identity.refreshTrust()
                prepareShareFile()
            }
            // Coming back from Settings after trusting the certificate is the
            // moment the answer changes.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { identity.refreshTrust() }
            }
            .confirmationDialog(
                "Make a new certificate?",
                isPresented: $confirmReset,
                titleVisibility: .visible
            ) {
                Button("New certificate", role: .destructive) { regenerate() }
            } message: {
                Text("The installed one stops matching, so you'll install and trust the new one. Remove the old one under Settings › General › VPN & Device Management.")
            }
        }
    }

    // MARK: - Sections

    private var introSection: some View {
        Section {
            Text("Instead of asking iOS for a fake location, Locus answers the question iOS asks Apple — “where is this Wi-Fi network?” — with the place you chose. It does that on this iPhone, through Locus’ own tunnel, with a certificate you install once. Nothing is sent anywhere.")
                .font(.callout)
        }
    }

    private var certificateSection: some View {
        Section {
            Label {
                Text(trustTitle)
            } icon: {
                Image(systemName: trustIcon)
                    .foregroundStyle(trustColor)
            }

            if identity.trust == .notTrusted, let failure = identity.trustFailure {
                Text("iOS says: \(failure)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if identity.trust != .trusted {
                Button {
                    Task { await installCertificate() }
                } label: {
                    Label(identity.trust == .notCreated ? "Create and install certificate" : "Install certificate again",
                          systemImage: "square.and.arrow.down")
                }

                if identity.trust == .notTrusted {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Label("Open Settings", systemImage: "gear")
                    }
                    Button {
                        identity.refreshTrust()
                    } label: {
                        Label("Check again", systemImage: "arrow.clockwise")
                    }
                }
            }

            if let shareURL, identity.material != nil {
                ShareLink(item: shareURL) {
                    Label("Share the certificate file", systemImage: "square.and.arrow.up")
                }
            }

            if identity.material != nil {
                Button(role: .destructive) {
                    confirmReset = true
                } label: {
                    Label("Make a new certificate", systemImage: "arrow.triangle.2.circlepath")
                }
            }

            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("1 · Certificate")
        } footer: {
            Text("Tap install, allow the download, then Settings › General › VPN & Device Management › install “Locus Location Authority”. Finally switch it on under Settings › General › About › Certificate Trust Settings.\n\nThe certificate can only vouch for Apple’s location servers — it is limited to those names, and Locus keeps no key that could issue another.")
        }
    }

    private var checkSection: some View {
        Section {
            Button {
                Task { await spoofer.runChecks() }
            } label: {
                HStack {
                    Label("Test network mode", systemImage: "checkmark.circle")
                    Spacer()
                    if spoofer.isChecking { ProgressView() }
                }
            }
            .disabled(spoofer.isChecking)

            ForEach(spoofer.checks) { check in
                checkRow(check)
            }
        } header: {
            Text("2 · Check")
        } footer: {
            Text("Walks the path a request takes: certificate, Locus’ tunnel, DNS and the on-device proxy. Network mode needs the tunnel built into Locus — LocalDevVPN can’t provide it.")
        }
    }

    private func activitySection(_ status: InterceptStatus) -> some View {
        Section {
            LabeledContent("Replies rewritten", value: "\(status.rewritten)")
            LabeledContent("Relayed unchanged", value: "\(status.relayed)")
            LabeledContent("Lookups answered", value: "\(status.dnsAnswered)")
            LabeledContent("Handshakes refused", value: "\(status.handshakeFailures)")
            if let error = status.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(LocusTheme.statusBad)
            }
            Button {
                Task { await spoofer.refreshStatus() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        } header: {
            Text("Activity")
        } footer: {
            Text("“Replies rewritten” going up is the sign it is working. “Handshakes refused” going up means iOS is rejecting the certificate — check step 1.")
        }
    }

    private var limitsSection: some View {
        Section {
            Text("• Only Wi-Fi and cell-tower positioning is changed. With a clear sky, GPS may still say where you really are; indoors it usually follows.")
            Text("• iOS asks again only now and then. After teleporting, turn Location Services off and on (or toggle Airplane Mode) to make it ask straight away.")
            Text("• It teleports; it doesn’t move. Routes and the joystick work best with the Developer method.")
        } header: {
            Text("Good to know")
        }
        .font(.footnote)
    }

    // MARK: - Rows

    @ViewBuilder
    private func checkRow(_ check: NetworkSpoofer.Check) -> some View {
        switch check {
        case .passed(let title, let detail):
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(LocusTheme.statusGood)
            }
        case .failed(let title, let detail):
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(LocusTheme.statusBad)
            }
        }
    }

    private var trustTitle: String {
        switch identity.trust {
        case .notCreated: return "No certificate yet"
        case .notTrusted: return "Created — not trusted by iOS yet"
        case .trusted: return "Installed and trusted"
        }
    }

    private var trustIcon: String {
        switch identity.trust {
        case .notCreated: return "circle.dashed"
        case .notTrusted: return "exclamationmark.triangle.fill"
        case .trusted: return "checkmark.seal.fill"
        }
    }

    private var trustColor: Color {
        switch identity.trust {
        case .notCreated: return .secondary
        case .notTrusted: return LocusTheme.statusWarn
        case .trusted: return LocusTheme.statusGood
        }
    }

    // MARK: - Actions

    private func installCertificate() async {
        message = nil
        do {
            try identity.ensureCreated()
        } catch {
            message = "Couldn’t create the certificate: \(error.localizedDescription)"
            return
        }
        prepareShareFile()
        guard let der = identity.authorityCertificate,
              let url = await CertificateServer.shared.publish(der) else {
            message = "Couldn’t hand the certificate to Safari. Use “Share the certificate file” and open it from Files."
            return
        }
        message = "Safari will ask to download a profile — allow it, then follow the steps below."
        await UIApplication.shared.open(url)
    }

    private func regenerate() {
        do {
            try identity.regenerate()
            prepareShareFile()
            message = "New certificate made. Install and trust it to continue."
        } catch {
            message = "Couldn’t create the certificate: \(error.localizedDescription)"
        }
    }

    /// A `.cer` on disk for the share sheet / Files route, which is the way in
    /// when Safari can't be used.
    private func prepareShareFile() {
        guard let der = identity.authorityCertificate else {
            shareURL = nil
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(CertificateServer.fileName)
        do {
            try der.write(to: url, options: .atomic)
            shareURL = url
        } catch {
            shareURL = nil
        }
    }
}
