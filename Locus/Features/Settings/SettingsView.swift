import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var pairing: PairingStore
    @EnvironmentObject private var session: SpoofSession
    @StateObject private var tunnel = TunnelController.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var showImporter = false
    @State private var showPairOnDevice = false
    @State private var showNameEasterEgg = false
    @State private var showDriveSettings = false
    @State private var showTunnelAdvanced = false
    @State private var showDiagnostics = false
    @State private var tunnelIP = TunnelConfig.targetIP
    @State private var localDevVPNInstalled = LocalDevVPN.isInstalled
    @State private var loopbackUp = TunnelController.loopbackReachable

    private var supportsOnDevicePairing: Bool {
        if #available(iOS 27.0, *) { return true }
        return false
    }

    private var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                pairingSection
                tunnelSection
                if showTunnelAdvanced { tunnelAdvancedSection }
                drivingSection
                privacySection
                aboutSection
                easterEggSection
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        saveTunnelIP()
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showImporter) {
                PairingDocumentPicker(
                    onPick: { url in
                        showImporter = false
                        do {
                            try pairing.importPairing(from: url)
                        } catch {
                            session.lastError = error.localizedDescription
                        }
                    },
                    onCancel: { showImporter = false }
                )
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showPairOnDevice) {
                PairOnDeviceView()
                    .environmentObject(pairing)
            }
            .sheet(isPresented: $showDriveSettings) {
                DriveSettingsView(profile: $session.drive, mode: session.travelMode)
            }
            .sheet(isPresented: $showDiagnostics) {
                TunnelDiagnosticsView()
            }
            .fullScreenCover(isPresented: $showNameEasterEgg) {
                LocusEasterEggView()
            }
            .onAppear { refresh() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { refresh() }
            }
        }
    }

    // MARK: - Pairing

    private var pairingSection: some View {
        Section {
            Label {
                Text(pairing.hasPairingFile ? "RPPairing file installed" : "No pairing file")
            } icon: {
                Image(systemName: pairing.hasPairingFile ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(pairing.hasPairingFile ? LocusTheme.statusGood : LocusTheme.statusWarn)
            }

            if supportsOnDevicePairing {
                Button {
                    showPairOnDevice = true
                } label: {
                    Label("Pair on this iPhone", systemImage: "iphone.gen3.radiowaves.left.and.right")
                }
            }

            Button("Import RPPairing file…") { showImporter = true }
            Button("Paste RPPairing from clipboard") {
                do {
                    try pairing.importPairingFromClipboard()
                } catch {
                    session.lastError = error.localizedDescription
                }
            }
            if pairing.hasPairingFile {
                Button("Remove pairing file", role: .destructive) {
                    try? pairing.removePairing()
                }
            }
        } header: {
            Text("Developer pairing")
        } footer: {
            Text(supportsOnDevicePairing
                 ? "On iOS 27, use Pair on this iPhone — no computer. Locus advertises a pairable host; confirm the 6-digit code under Settings › Privacy & Security › Developer Mode › Pair with Host. On older iOS, import an RPPairing file from idevice_pair (not a SideStore lockdown .mobiledevicepairing). LiveContainer: enable Fix File Picker on Locus, or use Paste / Share → LiveContainer → Locus."
                 : "Import an RPPairing file from idevice_pair (not a SideStore lockdown .mobiledevicepairing). If the file picker fails (common in LiveContainer), enable Fix File Picker on the app, share the file into LiveContainer → Locus, or copy the plist and use Paste.")
        }
    }

    // MARK: - Tunnel

    private var tunnelSection: some View {
        Section {
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(tunnelColor)
                        .frame(width: 8, height: 8)
                    Text(tunnelStatusText)
                        .foregroundStyle(tunnelColor)
                }
            }

            if TunnelController.isEmbedded {
                Toggle("Connect automatically", isOn: $tunnel.autoConnect)

                Button {
                    Task {
                        if loopbackUp || tunnel.state.isConnected {
                            await tunnel.disconnect()
                        } else {
                            await tunnel.connect()
                        }
                        refresh()
                    }
                } label: {
                    if tunnel.state.isBusy {
                        HStack {
                            Text("Connecting…")
                            Spacer()
                            ProgressView()
                        }
                    } else {
                        Label(
                            loopbackUp ? "Disconnect tunnel" : "Connect tunnel now",
                            systemImage: loopbackUp ? "bolt.slash.fill" : "bolt.fill"
                        )
                    }
                }
                .disabled(tunnel.state.isBusy)

                Toggle("Keep it up on demand", isOn: $tunnel.onDemand)

                Picker("Method", selection: $tunnel.method) {
                    ForEach(LocusTunnelMethod.allCases) { method in
                        Text(method.title).tag(method)
                    }
                }

                Text(tunnel.method.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button {
                    tunnel.refreshDiagnostics()
                    showDiagnostics = true
                } label: {
                    Label("Tunnel log", systemImage: "text.alignleft")
                }
            } else {
                Button {
                    LocalDevVPN.openOrInstall()
                } label: {
                    Label(
                        localDevVPNInstalled ? "Open LocalDevVPN" : "Get LocalDevVPN (App Store)",
                        systemImage: localDevVPNInstalled ? "lock.shield.fill" : "arrow.down.app.fill"
                    )
                }
            }

            Toggle("Advanced addresses", isOn: $showTunnelAdvanced.animation(.snappy))
        } header: {
            Text("Tunnel")
        } footer: {
            Text(tunnelFooter)
        }
    }

    private var tunnelFooter: String {
        if TunnelController.isEmbedded {
            return "Locus carries its own loopback tunnel, so it can bring one up without LocalDevVPN. "
                + "iOS asks once to allow the VPN configuration; nothing leaves the device — the tunnel only lets "
                + "this iPhone reach its own developer service at \(TunnelConfig.targetIP). "
                + "If the first method can't pass traffic, Locus tries the others and keeps the one that works."
        }
        return "This build has no built-in tunnel — LiveContainer can't load app extensions. "
            + "Connect LocalDevVPN instead, then come back. Default tunnel IP is \(TunnelConfig.defaultTargetIP)."
    }

    private var tunnelStatusText: String {
        if loopbackUp {
            if case .connected(let method, let interface) = tunnel.state {
                return "Connected · \(method.title) · \(interface)"
            }
            return "Connected"
        }
        switch tunnel.state {
        case .connecting: return "Connecting…"
        case .failed: return "Failed"
        case .unavailable: return "Not built in"
        case .idle, .connected: return "Not connected"
        }
    }

    private var tunnelColor: Color {
        if loopbackUp { return LocusTheme.statusGood }
        switch tunnel.state {
        case .connecting: return LocusTheme.statusWarn
        case .failed: return LocusTheme.statusBad
        default: return LocusTheme.statusWarn
        }
    }

    private var tunnelAdvancedSection: some View {
        Section {
            TextField("Device tunnel IP", text: $tunnelIP)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.numbersAndPunctuation)
                .onSubmit(saveTunnelIP)

            Button("Save tunnel IP", action: saveTunnelIP)
                .disabled(!TunnelConfig.isValidIPv4(tunnelIP))

            if !TunnelConfig.isValidIPv4(tunnelIP) {
                Label("That isn’t a valid IPv4 address.", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(LocusTheme.statusWarn)
            }

            Button("Reset to \(TunnelConfig.defaultTargetIP)") {
                TunnelConfig.resetToDefaults()
                tunnelIP = TunnelConfig.targetIP
            }
        } header: {
            Text("Addresses")
        } footer: {
            Text("Only change this if you run the tunnel on a different subnet. Locus and LocalDevVPN default to \(TunnelConfig.defaultTargetIP), which is what makes a tunnel raised by either one usable by both.")
        }
    }

    // MARK: - Driving

    private var drivingSection: some View {
        Section {
            Button {
                showDriveSettings = true
            } label: {
                HStack {
                    Label("Driving parameters", systemImage: "gauge.with.dots.needle.50percent")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            LabeledContent("Now", value: session.drive.summary(for: session.travelMode))
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("Routes")
        } footer: {
            Text("Speed limits, tolerance, traffic, junction stops, GPS scatter and playback speed — all of it applies the next time a route is driven.")
        }
    }

    // MARK: - Rest

    private var privacySection: some View {
        Section("Privacy") {
            Text("Fully on-device. Favorites, recents and driving parameters stay in UserDefaults. The tunnel is a loopback interface, not a VPN service — it forwards nothing anywhere. No analytics, no accounts, nothing uploaded.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: appVersion)
            LabeledContent("Engine", value: "idevice DVT location simulation")
            Text("Locus is free and open source (MIT). Location injection uses the MIT-licensed idevice FFI.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            // The StosVPN License requires this to be somewhere prominent.
            Text("The built-in tunnel is based on and uses code from LocalDevVPN (StosVPN) by Stossy11 and the SideStore Team, used under the StosVPN License.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var easterEggSection: some View {
        Section {
            Button {
                showNameEasterEgg = true
            } label: {
                Text("locus, n. — a place. From the Latin for where you are.")
                    .font(.footnote.italic())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    private func saveTunnelIP() {
        guard TunnelConfig.isValidIPv4(tunnelIP) else { return }
        TunnelConfig.setTargetIP(tunnelIP)
    }

    private func refresh() {
        localDevVPNInstalled = LocalDevVPN.isInstalled
        loopbackUp = TunnelController.loopbackReachable
        tunnelIP = TunnelConfig.targetIP
    }
}

/// What the tunnel extension itself logged, read out of the App Group. Without
/// this the only symptom of a tunnel that comes up but passes nothing is a
/// teleport that fails for no stated reason.
struct TunnelDiagnosticsView: View {
    @StateObject private var tunnel = TunnelController.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if tunnel.lastDiagnostics.isEmpty {
                        Text("Nothing logged yet. Connect the tunnel and come back.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(tunnel.lastDiagnostics.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
            }
            .navigationTitle("Tunnel log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh") { tunnel.refreshDiagnostics() }
                }
            }
            .onAppear { tunnel.refreshDiagnostics() }
        }
    }
}

struct PlacesView: View {
    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var pairing: PairingStore
    @Environment(\.dismiss) private var dismiss

    @State private var placeToRename: SavedPlace?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Favorites") {
                    if session.favorites.isEmpty {
                        Text("Star a pin from the map to save it.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(session.favorites) { place in
                        placeButton(place)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    session.removeFavorite(place)
                                } label: {
                                    Label("Delete", systemImage: "trash.fill")
                                }
                                Button {
                                    placeToRename = place
                                    renameText = place.name
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                .tint(.gray)
                            }
                    }
                }

                Section("Recents") {
                    if session.recents.isEmpty {
                        Text("Teleports show up here.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(session.recents) { place in
                        placeButton(place)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    session.removeRecent(place)
                                } label: {
                                    Label("Delete", systemImage: "trash.fill")
                                }
                            }
                    }
                }
            }
            .navigationTitle("Places")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Rename Favorite", isPresented: Binding(
                get: { placeToRename != nil },
                set: { if !$0 { placeToRename = nil } }
            )) {
                TextField("Name", text: $renameText)
                Button("Cancel", role: .cancel) {
                    placeToRename = nil
                }
                Button("Save") {
                    if let place = placeToRename {
                        session.renameFavorite(place, to: renameText)
                    }
                    placeToRename = nil
                }
            } message: {
                Text("Choose a name you’ll recognize later.")
            }
        }
    }

    private func placeButton(_ place: SavedPlace) -> some View {
        Button {
            session.teleport(to: place.coordinate, pairing: pairing)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name).foregroundStyle(.primary)
                Text(String(format: "%.5f, %.5f", place.latitude, place.longitude))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }
}
