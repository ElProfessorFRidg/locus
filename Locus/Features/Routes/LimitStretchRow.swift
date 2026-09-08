import CoreLocation
import SwiftUI

/// One stretch of road, its estimated limit, and a way to say the estimate is
/// wrong.
///
/// The correction snaps to the values roads are actually signed at rather than
/// offering a free slider: nobody wants to set a limit of 83, and a ladder makes
/// the whole thing two taps.
struct LimitStretchRow: View {
    let stretch: RoutePlan.Stretch
    let unit: SpeedUnit
    let override: LimitOverride?
    var onChange: (CLLocationSpeed?) -> Void
    /// Show this stretch on the map. "1.2 km–2.4 km" says where along the route
    /// it is and nothing about which road that is, which is the one thing you
    /// need to know before deciding the estimate is wrong.
    var onFocus: () -> Void

    private var displayed: Double {
        unit.fromMetresPerSecond(override?.limit ?? stretch.limit)
    }

    private var isCorrected: Bool { override != nil }

    /// The rungs either side of the current value, for the two arrows.
    private var ladder: [Double] { unit.speedLadder }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                Rectangle()
                    .fill(LocusTheme.speedColor(forLimit: override?.limit ?? stretch.limit, unit: unit))
                    .frame(width: 4)
                    .clipShape(Capsule())

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Int(displayed.rounded())) \(unit.short)")
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(isCorrected ? LocusTheme.accent : .primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)
            }
            // Only this half taps: the +/− buttons live in the same row and a
            // tappable row would swallow them.
            .contentShape(Rectangle())
            .onTapGesture(perform: onFocus)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Shows this stretch on the map")

            HStack(spacing: 2) {
                step(down: true)
                step(down: false)
                if isCorrected {
                    Button {
                        onChange(nil)
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.footnote.weight(.semibold))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Undo this correction")
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        // Its length as well as where it starts and ends: "1.2 km–2.4 km" makes
        // you do the subtraction to learn the one number that says whether this
        // stretch is worth correcting.
        var parts = [
            "\(DriveFormat.distance(stretch.startDistance))–\(DriveFormat.distance(stretch.endDistance))",
            "\(DriveFormat.distance(stretch.length)) long",
        ]
        if isCorrected {
            parts.append("was \(Int(unit.fromMetresPerSecond(stretch.limit).rounded()))")
        }
        return parts.joined(separator: " · ")
    }

    private func step(down: Bool) -> some View {
        Button {
            guard let next = nextRung(down: down) else { return }
            onChange(unit.toMetresPerSecond(next))
        } label: {
            Image(systemName: down ? "minus" : "plus")
                .font(.footnote.weight(.bold))
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .foregroundStyle(nextRung(down: down) == nil ? .tertiary : .primary)
        .background(Circle().fill(Color.primary.opacity(0.08)))
        .disabled(nextRung(down: down) == nil)
        .accessibilityLabel(down ? "Lower the limit here" : "Raise the limit here")
    }

    /// Next signed value below or above the current one. Nil at either end,
    /// which disables the arrow rather than silently doing nothing.
    private func nextRung(down: Bool) -> Double? {
        let current = displayed
        return down
            ? ladder.last { $0 < current - 0.5 }
            : ladder.first { $0 > current + 0.5 }
    }
}
