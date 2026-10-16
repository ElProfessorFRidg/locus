import CoreLocation
import SwiftUI

enum ProMode {
    static let defaultsKey = "locus.proMode"
}

/// Pro mode: what Core Location is telling apps right now, next to what Locus
/// asked for. The "simulated" flag is the headline because it is the one thing
/// that differs between the two methods.
struct ProReadoutView: View {
    @EnvironmentObject private var session: SpoofSession
    @StateObject private var probe = LocationProbe.shared
    @StateObject private var spoofer = NetworkSpoofer.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            List {
                verdictSection
                if let reading = probe.reading { fixSection(reading) }
                requestedSection
                if SpoofBackend.current.usesNetwork, let status = spoofer.status { networkSection(status) }
                notesSection
            }
            .navigationTitle("What apps see")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            // Paired start/stop only: in the background iOS stops delivering
            // foreground-only updates by itself, so scene phase needn't be tracked.
            .onAppear { probe.start() }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    if SpoofBackend.current.usesNetwork { await spoofer.refreshStatus() }
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
            .onDisappear { probe.stop() }
        }
    }

    // MARK: - Sections

    private var verdictSection: some View {
        Section {
            if probe.authorization == .denied || probe.authorization == .restricted {
                Label("Location access is off for Locus — turn it on in Settings to read the fix.", systemImage: "location.slash")
                    .foregroundStyle(LocusTheme.statusWarn)
            } else if let reading = probe.reading {
                row("Simulated by software", flag(reading.isSimulatedBySoftware), tint: tint(for: reading.isSimulatedBySoftware))
                row("Produced by accessory", flag(reading.isProducedByAccessory), tint: nil)
                row("Fix age", ageText(reading.timestamp), tint: nil)
            } else {
                HStack {
                    Text("Waiting for a fix…")
                    Spacer()
                    ProgressView()
                }
            }
        } header: {
            Text("Flags iOS attaches")
        } footer: {
            Text("These come from iOS, not from Locus. The Developer method uses Apple’s simulated-location service, which iOS marks as simulated. Network mode changes the Wi‑Fi/cell answer instead, which shouldn’t be marked — this readout is how you check on your own phone.")
        }
    }

    private func fixSection(_ reading: LocationProbe.Reading) -> some View {
        Section {
            row("Latitude", String(format: "%.6f", reading.coordinate.latitude), tint: nil)
            row("Longitude", String(format: "%.6f", reading.coordinate.longitude), tint: nil)
            row("Horizontal accuracy", accuracy(reading.horizontalAccuracy), tint: nil)
            row("Vertical accuracy", accuracy(reading.verticalAccuracy), tint: nil)
            row("Altitude", String(format: "%.1f m", reading.altitude), tint: nil)
            row("Speed", reading.speed >= 0 ? String(format: "%.1f m/s", reading.speed) : "—", tint: nil)
            row("Course", reading.course >= 0 ? String(format: "%.0f°", reading.course) : "—", tint: nil)
        } header: {
            Text("The fix")
        } footer: {
            // Wi‑Fi positioning is metres-to-tens-of-metres; a tight accuracy
            // means GPS is in the mix, which is the thing that can disagree.
            Text("Accuracy under ~10 m usually means GPS is contributing — in network mode that’s the part that can still say where you really are.")
        }
    }

    private var requestedSection: some View {
        Section {
            row("Method", SpoofBackend.current.title, tint: nil)
            row("Locus is spoofing", session.isSpoofing ? "Yes" : "No",
                tint: session.isSpoofing ? LocusTheme.statusGood : nil)
            if let target = session.simulated {
                row("Asked for", String(format: "%.5f, %.5f", target.latitude, target.longitude), tint: nil)
                if let reading = probe.reading {
                    let distance = CLLocation(latitude: target.latitude, longitude: target.longitude)
                        .distance(from: CLLocation(latitude: reading.coordinate.latitude, longitude: reading.coordinate.longitude))
                    row("Apps are", distanceText(distance) + " from it", tint: distance < 100 ? LocusTheme.statusGood : LocusTheme.statusWarn)
                }
            }
        } header: {
            Text("What Locus asked for")
        }
    }

    private func networkSection(_ status: InterceptStatus) -> some View {
        Section {
            row("Proxy listening", status.listening ? "Yes" : "No", tint: status.listening ? LocusTheme.statusGood : LocusTheme.statusWarn)
            row("Replies rewritten", "\(status.rewritten)", tint: nil)
            row("Relayed unchanged", "\(status.relayed)", tint: nil)
            row("Lookups answered", "\(status.dnsAnswered)", tint: nil)
            row("Handshakes refused", "\(status.handshakeFailures)",
                tint: status.handshakeFailures > 0 ? LocusTheme.statusBad : nil)
            if let error = status.lastError {
                Text(error).font(.footnote).foregroundStyle(LocusTheme.statusBad)
            }
        } header: {
            Text("Network mode")
        } footer: {
            Text("No “replies rewritten” after turning Location Services off and on usually means iOS isn’t reaching the tunnel, or doesn’t trust the certificate.")
        }
    }

    private var notesSection: some View {
        Section {
            Text("Updates live while this sheet is open.")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    // MARK: - Formatting

    private func row(_ title: String, _ value: String, tint: Color?) -> some View {
        LabeledContent(title) {
            Text(value)
                .foregroundStyle(tint ?? .primary)
                .monospacedDigit()
        }
    }

    private func flag(_ value: Bool?) -> String {
        switch value {
        case .some(true): return "Yes"
        case .some(false): return "No"
        case .none: return "Not reported"
        }
    }

    private func tint(for simulated: Bool?) -> Color? {
        switch simulated {
        case .some(true): return LocusTheme.statusWarn
        case .some(false): return LocusTheme.statusGood
        case .none: return nil
        }
    }

    private func accuracy(_ value: CLLocationAccuracy) -> String {
        value < 0 ? "invalid" : String(format: "±%.0f m", value)
    }

    private func ageText(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        return seconds < 2 ? "now" : "\(seconds) s ago"
    }

    private func distanceText(_ meters: CLLocationDistance) -> String {
        meters < 1000 ? String(format: "%.0f m", meters) : String(format: "%.1f km", meters / 1000)
    }
}

/// The same headline in one line, for the map while Pro mode is on.
struct ProChip: View {
    @StateObject private var probe = LocationProbe.shared
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(summary)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                Image(systemName: "chevron.up")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .onAppear { probe.start() }
        .onDisappear { probe.stop() }
    }

    private var summary: String {
        guard let reading = probe.reading else { return "Waiting for fix…" }
        let simulated: String
        switch reading.isSimulatedBySoftware {
        case .some(true): return "SIMULATED · " + accuracy(reading)
        case .some(false): simulated = "not simulated"
        case .none: simulated = "source n/a"
        }
        return "\(simulated) · \(accuracy(reading))"
    }

    private func accuracy(_ reading: LocationProbe.Reading) -> String {
        reading.horizontalAccuracy < 0 ? "no fix" : String(format: "±%.0f m", reading.horizontalAccuracy)
    }

    private var color: Color {
        switch probe.reading?.isSimulatedBySoftware {
        case .some(true): return LocusTheme.statusWarn
        case .some(false): return LocusTheme.statusGood
        case .none: return .secondary
        }
    }
}
