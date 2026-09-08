import CoreLocation
import SwiftUI
import UIKit

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
    /// Steps the playback speed. Nil hides the control — the HUD is also drawn
    /// in contexts that don't own the profile.
    var onChangeTimeScale: ((Double) -> Void)?

    /// The stops the ×-control snaps to, matching the parameter sheet's slider.
    private static let scales: [Double] = [0.5, 1, 2, 4, 8]

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
        return Int(unit.fromMetresPerSecond(limit * (1 + profile.speedToleranceClamped)).rounded())
    }

    private var speedColor: Color {
        if telemetry.isStopped { return .secondary }
        if telemetry.isOverLimit && profile.warnWhenOverLimit { return LocusTheme.overLimit }
        return .primary
    }

    var body: some View {
        // Three rows rather than two, because the previous single row asked the
        // speed, the sign, the playback control, pause and stop to share one
        // line: on a phone that left the speed about sixty points to draw three
        // digits at forty, so "135" wrapped into a column reading 1 / 3 / 5, and
        // "257.1 km left" was squeezed to "257.1 k…". The two things that must
        // never shrink — the speed and the two big buttons — get the top row to
        // themselves; everything flexible moved down.
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 12) {
                speedBlock

                if let limitValue {
                    SpeedLimitSign(value: limitValue, tolerated: toleratedValue)
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                }

                Spacer(minLength: 4)

                transportControls
            }

            secondaryRow

            progress
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .locusGlass(.regular, in: RoundedRectangle(cornerRadius: LocusMetrics.panelRadius, style: .continuous))
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: limitValue)
        .animation(.easeOut(duration: 0.2), value: telemetry.isOverLimit)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Driving at \(speedValue) \(unit.short)")
    }

    // MARK: - Pieces

    /// The number, and nothing that can push it out of shape.
    ///
    /// `fixedSize` is the load-bearing part: without it the digits are treated as
    /// wrappable text, and a row that runs out of width breaks them one per line
    /// rather than letting anything else give.
    private var speedBlock: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text("\(speedValue)")
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .contentTransition(.numericText(value: Double(speedValue)))
                .foregroundStyle(speedColor)
            Text(unit.short)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .layoutPriority(1)
    }

    /// What the drive is doing, and the one dial worth having mid-drive.
    ///
    /// Full width rather than stacked under the speed, so the controls beside it
    /// can no longer squeeze it into an ellipsis.
    private var secondaryRow: some View {
        HStack(spacing: 10) {
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Spacer(minLength: 4)

            if onChangeTimeScale != nil {
                timeScaleControl
            }
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

    /// Pause and stop only. The playback dial moved to `secondaryRow`, where it
    /// has room that isn't taken from the speed.
    private var transportControls: some View {
        HStack(spacing: 8) {
            Button(action: onTogglePause) {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .font(.body.weight(.semibold))
                    .frame(width: 38, height: 38)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .locusGlass(.interactive, in: Circle())
            .accessibilityLabel(isPaused ? "Resume route" : "Pause route")

            // A red glyph, but not a red button. Ending the route is not
            // destructive — you keep spoofing, at wherever the car got to — and
            // it was drawn as a filled red disc a few hundred points above the
            // filled red "Stop" in the tray, which leaves your real location.
            // Two identical-looking red controls meaning different things.
            // Filled red now belongs to that one alone.
            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.body.weight(.semibold))
                    .frame(width: 38, height: 38)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(LocusTheme.danger)
            .locusGlass(.interactive, in: Circle())
            .accessibilityLabel("End the route")
        }
    }

    /// Playback speed, where you are when you want it.
    ///
    /// It lives in the parameter sheet too, but wanting a route to hurry up is
    /// something you discover four minutes into watching it — two screens away
    /// from the dial, and until now it needed the route restarted to take.
    private var timeScaleControl: some View {
        HStack(spacing: 2) {
            scaleStep("minus", label: "Slower", delta: -1)

            Text(Self.scaleLabel(profile.timeScale))
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(profile.timeScale == 1 ? .secondary : LocusTheme.accentSecondary)
                .frame(minWidth: 28)
                .contentTransition(.numericText(value: profile.timeScale))

            scaleStep("plus", label: "Faster", delta: 1)
        }
        .padding(.horizontal, 4)
        .frame(height: 30)
        .locusGlass(.interactive, in: Capsule())
        .animation(.snappy, value: profile.timeScale)
    }

    private func scaleStep(_ systemName: String, label: String, delta: Int) -> some View {
        let index = Self.nearestScaleIndex(profile.timeScale)
        let next = index + delta
        let available = Self.scales.indices.contains(next)

        return Button {
            guard available, let onChangeTimeScale else { return }
            onChangeTimeScale(Self.scales[next])
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            Image(systemName: systemName)
                .font(.caption.weight(.bold))
                .frame(width: 26, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(available ? Color.primary : Color.secondary.opacity(0.5))
        .disabled(!available)
        .accessibilityLabel("\(label), playback speed")
    }

    /// "1×", "0.5×" — the half-speed stop is the only one needing a decimal.
    static func scaleLabel(_ scale: Double) -> String {
        scale < 1 ? String(format: "%.1f×", scale) : "\(Int(scale.rounded()))×"
    }

    /// The stop a freely-set scale sits closest to, so stepping from a value
    /// typed on the slider still lands somewhere sensible.
    static func nearestScaleIndex(_ scale: Double) -> Int {
        var best = 0
        for (index, candidate) in scales.enumerated()
        where abs(candidate - scale) < abs(scales[best] - scale) {
            best = index
        }
        return best
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
