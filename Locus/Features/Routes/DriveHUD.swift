import CoreLocation
import SwiftUI

/// Live readout while a route plays: speed, the limit being respected, how far
/// is left, and the two controls you actually want mid-drive.
///
/// It sits in the same `LocusGlassGroup` as the status bar so the two blend
/// into one pane of glass when they are close, and morphs in rather than fading
/// when a route starts.
struct DriveHUDView: View {
    let telemetry: DriveTelemetry
    let profile: DriveProfile
    let isPaused: Bool
    var onTogglePause: () -> Void
    var onStop: () -> Void

    private var unit: SpeedUnit { profile.units }

    private var speedValue: Int {
        Int(unit.fromMetresPerSecond(telemetry.speed).rounded())
    }

    private var limitValue: Int? {
        guard let limit = telemetry.speedLimit else { return nil }
        return Int(unit.fromMetresPerSecond(limit).rounded())
    }

    /// The number the driver is actually allowed to hit — the sign plus the
    /// tolerance they set. Shown under the sign so "+10%" is not invisible.
    private var toleratedValue: Int? {
        guard let limit = telemetry.speedLimit, profile.speedTolerance != 0 else { return nil }
        return Int(unit.fromMetresPerSecond(limit * (1 + profile.speedTolerance)).rounded())
    }

    private var speedColor: Color {
        if telemetry.isStopped { return .secondary }
        if telemetry.isOverLimit && profile.warnWhenOverLimit { return LocusTheme.overLimit }
        return .primary
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                speedBlock

                if let limitValue {
                    SpeedLimitSign(value: limitValue, tolerated: toleratedValue)
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                }

                Spacer(minLength: 0)

                controls
            }

            progress
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .locusGlass(.regular, in: RoundedRectangle(cornerRadius: LocusMetrics.panelRadius, style: .continuous))
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: limitValue)
        .animation(.easeOut(duration: 0.2), value: telemetry.isOverLimit)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Driving at \(speedValue) \(unit.short)")
    }

    // MARK: - Pieces

    private var speedBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(speedValue)")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(speedValue)))
                    .foregroundStyle(speedColor)
                Text(unit.short)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var subtitle: String {
        if isPaused { return "Paused" }
        if telemetry.isStopped { return "Stopped" }
        var parts = [DriveFormat.distance(telemetry.distanceRemaining) + " left"]
        if let eta = DriveFormat.eta(telemetry: telemetry, timeScale: profile.timeScale) {
            parts.append(eta)
        }
        if telemetry.lap > 1 { parts.append("lap \(telemetry.lap)") }
        return parts.joined(separator: " · ")
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button(action: onTogglePause) {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .font(.body.weight(.semibold))
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .locusGlass(.interactive, in: Circle())
            .accessibilityLabel(isPaused ? "Resume route" : "Pause route")

            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.body.weight(.semibold))
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(LocusTheme.danger)
            .locusGlass(.interactive, tint: LocusTheme.danger.opacity(0.25), in: Circle())
            .accessibilityLabel("Stop route")
        }
    }

    private var progress: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.12))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [LocusTheme.accent, LocusTheme.accentSecondary],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(4, geo.size.width * telemetry.progress))
                }
            }
            .frame(height: 5)

            HStack {
                Text(DriveFormat.distance(telemetry.distanceTravelled))
                Spacer()
                Text(DriveFormat.clock(telemetry.elapsed))
                Spacer()
                Text(DriveFormat.distance(telemetry.totalDistance))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }
}

/// The round European limit sign — white face, red ring, black number. It reads
/// instantly at a glance in a way "limit: 50" never does.
struct SpeedLimitSign: View {
    let value: Int
    /// The tolerated number (limit + tolerance), shown beneath when set.
    var tolerated: Int?

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle()
                    .fill(.white)
                Circle()
                    .strokeBorder(LocusTheme.overLimit, lineWidth: 5)
                Text("\(value)")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.black)
                    .minimumScaleFactor(0.6)
                    .padding(4)
            }
            .frame(width: 46, height: 46)
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)

            if let tolerated, tolerated != value {
                Text("→ \(tolerated)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tolerated.map { "Speed limit \(value), driving to \($0)" } ?? "Speed limit \(value)")
    }
}

// MARK: - Formatting

enum DriveFormat {
    static func distance(_ metres: CLLocationDistance) -> String {
        if metres < 1000 {
            return "\(Int(metres.rounded())) m"
        }
        return String(format: "%.1f km", metres / 1000)
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// Remaining time at the current speed. Reported in *wall-clock* seconds, so
    /// a 4× time scale says how long you actually have to wait.
    static func eta(telemetry: DriveTelemetry, timeScale: Double) -> String? {
        guard telemetry.speed > 0.5, telemetry.distanceRemaining > 1 else { return nil }
        let simulatedSeconds = telemetry.distanceRemaining / telemetry.speed
        let realSeconds = simulatedSeconds / max(0.05, timeScale)
        return clock(realSeconds)
    }

    static func speed(_ metresPerSecond: CLLocationSpeed, unit: SpeedUnit) -> String {
        "\(Int(unit.fromMetresPerSecond(metresPerSecond).rounded())) \(unit.short)"
    }

    /// A nudge step, short enough to sit inside a 36-point button.
    static func stepLabel(_ metres: Double) -> String {
        metres < 1
            ? String(format: "%.1f m", metres)
            : "\(Int(metres.rounded())) m"
    }
}
