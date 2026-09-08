import CoreLocation
import SwiftUI

/// What the drive came to, shown when it reaches the end.
///
/// A route used to finish by having the HUD disappear. Forty minutes of
/// simulation, and the app said nothing about it — while `tripEconomy` sat in
/// the session with a consumption slider and a toggle and nowhere to appear.
/// Arriving is the one moment worth marking, and it is also the moment you know
/// whether the route was worth keeping.
struct TripSummaryView: View {
    let trip: TripSummary
    let profile: DriveProfile
    /// Litres and grams of CO₂, when the profile asks for them.
    let economy: (litres: Double, gramsCO2: Double)?
    var canSave: Bool
    var onDriveAgain: () -> Void
    var onReverse: () -> Void
    var onSave: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            header

            HStack(spacing: 0) {
                stat(DriveFormat.distance(trip.distance), "distance")
                divider
                stat(DriveFormat.clock(trip.simulatedSeconds), "driven")
                divider
                stat(DriveFormat.speed(trip.averageSpeed, unit: profile.units), "average")
            }

            if let detail = secondLine {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            actions
        }
        .padding(18)
        .locusGlass(.regular, in: RoundedRectangle(cornerRadius: LocusMetrics.trayRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: LocusMetrics.trayRadius, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "flag.pattern.checkered")
                .font(.title3.weight(.semibold))
                .foregroundStyle(LocusTheme.statusGood)
            VStack(alignment: .leading, spacing: 1) {
                Text("Arrived")
                    .font(.headline)
                Text(trip.routeName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
    }

    private func stat(_ value: String, _ caption: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: 28)
    }

    /// Laps, real time waited, and the fuel garnish — each only when it says
    /// something the three numbers above don't.
    private var secondLine: String? {
        var parts: [String] = []

        if trip.laps > 1 {
            parts.append("\(trip.laps) laps")
        }
        // Only when the clock and the simulation disagree, which is exactly
        // when the time scale wasn't 1×.
        if abs(trip.wallClockSeconds - trip.simulatedSeconds) > 30 {
            parts.append("\(DriveFormat.clock(trip.wallClockSeconds)) of your time")
        }
        if let economy, economy.litres > 0.01 {
            parts.append(String(
                format: "≈ %.1f L, %.1f kg CO₂",
                economy.litres,
                economy.gramsCO2 / 1000
            ))
        }
        parts.append("on “\(trip.profileName)”")

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button(action: onDriveAgain) {
                Label("Again", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .background(Capsule().fill(Color.primary.opacity(0.08)))

            // The commonest thing to want next: you drove there, now go back.
            Button(action: onReverse) {
                Label("Back", systemImage: "arrow.uturn.left")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.black)
            .background(Capsule().fill(LocusTheme.accent))

            if canSave {
                Button(action: onSave) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 44, height: 40)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
                .accessibilityLabel("Save this route")
            }
        }
    }
}
