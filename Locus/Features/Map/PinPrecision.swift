import CoreLocation
import SwiftUI
import UIKit

/// The reticle over the middle of the map in precision mode.
///
/// Placing a pin by tapping it is placing it under your own thumb: the target
/// is the one part of the map you cannot see while you aim at it, and at a
/// street zoom a thumb is thirty metres wide. Panning the map under a fixed
/// crosshair puts the target in the open instead, which is how every map tool
/// that cares about metres does it.
struct MapCrosshair: View {
    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.9), lineWidth: 1.5)
                .frame(width: 26, height: 26)
                .shadow(color: .black.opacity(0.5), radius: 2)

            // The gap in the middle is the point: a solid cross would hide the
            // very pixel it is naming.
            ForEach(0..<4, id: \.self) { index in
                Capsule()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 1.5, height: 10)
                    .offset(y: -22)
                    .rotationEffect(.degrees(Double(index) * 90))
                    .shadow(color: .black.opacity(0.5), radius: 2)
            }

            Circle()
                .fill(LocusTheme.accent)
                .frame(width: 4, height: 4)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Coordinate readout, a pad that moves the pin a fixed number of metres, and
/// the button that drops it under the crosshair.
///
/// The two halves are for the two different problems: the crosshair gets you to
/// the right building, the pad gets you to the right side of the doorway. A
/// drag gesture can do neither — one pixel is several metres, and the pin is
/// under your finger the whole time.
struct PinPrecisionBar: View {
    /// Where the crosshair is pointing — the map's centre.
    var center: CLLocationCoordinate2D?
    var pin: CLLocationCoordinate2D?
    @Binding var step: Double
    var onSetHere: () -> Void
    var onNudge: (_ east: Double, _ north: Double) -> Void
    var onDone: () -> Void

    /// One, five, twenty-five. A doorway, a driveway, a building.
    static let steps: [Double] = [1, 5, 25]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "dot.viewfinder")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(LocusTheme.accent)
                Text(readout)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                Button("Done", action: onDone)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(LocusTheme.accent)
            }

            HStack(spacing: 14) {
                nudgePad

                VStack(alignment: .leading, spacing: 6) {
                    Button(action: onSetHere) {
                        Label("Set pin here", systemImage: "mappin.and.ellipse")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .frame(maxWidth: .infinity)
                            .background(Capsule().fill(LocusTheme.accent.opacity(0.22)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(LocusTheme.accent)

                    Text(pin == nil
                         ? "Pan the map, then drop the pin under the crosshair."
                         : "Arrows move the pin \(DriveFormat.stepLabel(step)) at a time.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .locusGlass(.clear, in: RoundedRectangle(cornerRadius: LocusMetrics.panelRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: LocusMetrics.panelRadius, style: .continuous))
    }

    /// What is under the crosshair — that is what "Set pin here" will use — and
    /// how far that is from the pin, which is the number you are actually
    /// trying to close.
    private var readout: String {
        guard let center else {
            return pin.map(CoordinateParser.text) ?? "No pin yet"
        }
        guard let pin else { return CoordinateParser.text(center) }
        let away = Geo.distance(pin, center)
        guard away >= 1 else { return CoordinateParser.text(center) }
        return "\(CoordinateParser.text(center))  ·  pin \(DriveFormat.distance(away))"
    }

    private var nudgePad: some View {
        VStack(spacing: 3) {
            arrow("chevron.up", label: "Move north", east: 0, north: 1)
            HStack(spacing: 3) {
                arrow("chevron.left", label: "Move west", east: -1, north: 0)
                Button {
                    let index = Self.steps.firstIndex(of: step) ?? 0
                    step = Self.steps[(index + 1) % Self.steps.count]
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: {
                    Text(DriveFormat.stepLabel(step))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(LocusTheme.accentSecondary)
                        .frame(width: 36, height: 32)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Step size, \(DriveFormat.stepLabel(step)). Tap to change.")
                arrow("chevron.right", label: "Move east", east: 1, north: 0)
            }
            arrow("chevron.down", label: "Move south", east: 0, north: -1)
        }
    }

    private func arrow(
        _ systemName: String,
        label: String,
        east: Double,
        north: Double
    ) -> some View {
        Button {
            onNudge(east * step, north * step)
        } label: {
            Image(systemName: systemName)
                .font(.caption.weight(.bold))
                .frame(width: 36, height: 32)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(pin == nil ? Color.secondary : Color.primary)
        .disabled(pin == nil)
        .accessibilityLabel("\(label) \(DriveFormat.stepLabel(step))")
    }
}
