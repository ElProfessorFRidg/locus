import CoreLocation
import SwiftUI
import UIKit

/// Fake or real, at a glance — and the raw numbers behind it.
///
/// Always on screen, because "is this phone currently lying?" is the question
/// everything else in the app depends on, and the answer used to be a small
/// dot. It reads Locus' own state *and* what Core Location reports, so it stays
/// honest after a headless run, a relaunch or a remote command.
struct LocationReadoutPanel: View {
    @EnvironmentObject private var session: SpoofSession
    @ObservedObject private var probe = LocationProbe.shared
    @ObservedObject private var readout = LocationReadout.shared
    @ObservedObject private var remote = RemoteControl.shared
    @State private var copied = false

    var body: some View {
        let badge = readout.badge(session: session)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(badge.rawValue)
                    .font(.system(.subheadline, design: .rounded).weight(.heavy))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(color(for: badge), in: Capsule())
                    .foregroundStyle(.black)
                Spacer(minLength: 4)
                if let source {
                    Text(source)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            if let shown {
                Button {
                    UIPasteboard.general.string = ReadoutVerdict.coordinateText(shown)
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        copied = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(ReadoutVerdict.coordinateText(shown))
                            .font(.system(.callout, design: .monospaced).weight(.semibold))
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy coordinates")
            } else {
                Text("No fix yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let details {
                Text(details)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if let note = badge.explanation {
                Text(note.prefix(1).uppercased() + note.dropFirst())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LocusTheme.statusWarn)
            }

            if let comparison {
                Text(comparison)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if let command = remote.lastCommand {
                Text(commandText(command))
                    .font(.caption2)
                    .foregroundStyle(command.ok ? Color.secondary : LocusTheme.statusBad)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .locusGlass(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onAppear { probe.start() }
        .onDisappear { probe.stop() }
    }

    // MARK: - What is shown

    private var simulating: Bool {
        switch session.status {
        case .active, .reconnecting, .connecting, .dropped: return session.lastFix != nil
        case .idle: return false
        }
    }

    /// The simulated spot while there is one; otherwise what Core Location says.
    private var shown: RemotePoint? {
        if simulating, let fix = session.lastFix { return fix.point }
        return probe.reading.map { RemotePoint(lat: $0.coordinate.latitude, lon: $0.coordinate.longitude) }
    }

    private var source: String? {
        let mode: String
        if session.isRouting { mode = "route" }
        else if session.joystickActive { mode = "joystick" }
        else if session.isSpoofing { mode = "teleport" }
        else { return nil }
        return session.startedRemotely ? "\(mode) · remote command" : mode
    }

    private var details: String? {
        var parts: [String] = []
        if simulating, let fix = session.lastFix {
            parts.append("±\(Int(fix.horizontalAccuracy)) m")
            if let altitude = fix.altitude { parts.append("alt \(Int(altitude.rounded())) m") }
            if let speed = fix.speed { parts.append(String(format: "%.0f km/h", speed * 3.6)) }
            if let course = fix.course, course >= 0 { parts.append("\(Int(course.rounded()))°") }
            parts.append("fix " + Self.clock.string(from: fix.timestamp))
        } else if let reading = probe.reading {
            if reading.horizontalAccuracy >= 0 { parts.append("±\(Int(reading.horizontalAccuracy)) m") }
            if reading.verticalAccuracy >= 0 { parts.append("alt \(Int(reading.altitude.rounded())) m") }
            if reading.speed >= 0 { parts.append(String(format: "%.0f km/h", reading.speed * 3.6)) }
            if reading.course >= 0 { parts.append("\(Int(reading.course.rounded()))°") }
            parts.append("fix " + Self.clock.string(from: reading.timestamp))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The real fix, when it isn't the number already on screen.
    private var comparison: String? {
        guard simulating, let fix = session.lastFix else { return nil }
        if let reading = probe.reading, reading.isSimulatedBySoftware != true,
           ReadoutVerdict.distance(
               fix.point, RemotePoint(lat: reading.coordinate.latitude, lon: reading.coordinate.longitude)
           ) > 50 {
            let point = RemotePoint(lat: reading.coordinate.latitude, lon: reading.coordinate.longitude)
            return "CoreLocation: \(ReadoutVerdict.coordinateText(point)) · \(Self.distanceText(ReadoutVerdict.distance(fix.point, point))) away"
        }
        if let real = readout.lastReal {
            let point = RemotePoint(lat: real.lat, lon: real.lon)
            return "Real (last known): \(ReadoutVerdict.coordinateText(point)) · \(Self.distanceText(ReadoutVerdict.distance(fix.point, point))) away"
        }
        return nil
    }

    private func commandText(_ command: RemoteState.LastCommand) -> String {
        let time = Self.clock.string(from: Date(timeIntervalSince1970: TimeInterval(command.ts)))
        if command.ok { return "Remote \(command.name) ✓ \(time)" }
        return "Remote \(command.name) ✗ \(time): \(command.error ?? "failed")"
    }

    private func color(for badge: ReadoutBadge) -> Color {
        switch badge {
        case .simulated: return LocusTheme.statusWarn
        case .real: return LocusTheme.statusGood
        case .interrupted, .uncertain: return LocusTheme.statusBad
        }
    }

    private static func distanceText(_ metres: Double) -> String {
        metres >= 1000 ? String(format: "%.1f km", metres / 1000) : "\(Int(metres.rounded())) m"
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
