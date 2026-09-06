import CoreLocation
import SwiftUI

/// Speed, heading and distance while the joystick is on.
///
/// The joystick has always moved you at a speed derived from the travel mode or
/// the drive profile, and never showed you either it or how far you'd gone —
/// which made "am I actually moving?" a question you answered by watching the
/// map. Deliberately smaller than the route HUD: there is no route to progress
/// through, so there's nothing to put a bar under.
struct JoystickReadout: View {
    let telemetry: JoystickTelemetry
    let units: SpeedUnit

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(Int(units.fromMetresPerSecond(telemetry.speed).rounded()))")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: telemetry.speed))
                    .foregroundStyle(telemetry.isMoving ? .primary : .secondary)
                Text(units.short)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                if let course = telemetry.course, telemetry.isMoving {
                    HStack(spacing: 3) {
                        Image(systemName: "location.north.fill")
                            .font(.caption2)
                            .rotationEffect(.degrees(course))
                            .animation(.easeOut(duration: 0.2), value: course)
                        Text(Self.compass(course))
                            .font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(LocusTheme.accent)
                }

                Text(DriveFormat.distance(telemetry.distance))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .locusGlass(.clear, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Moving at \(Int(units.fromMetresPerSecond(telemetry.speed).rounded())) \(units.short), \(DriveFormat.distance(telemetry.distance)) covered")
    }

    /// Eight points is as precise as anyone reads a heading at a glance.
    private static func compass(_ degrees: CLLocationDirection) -> String {
        let points = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let index = Int((degrees / 45).rounded()) % points.count
        return points[(index + points.count) % points.count]
    }
}

struct JoystickPad: View {
    var onChange: (CGVector) -> Void

    @State private var dragOffset: CGSize = .zero
    private let radius: CGFloat = 52

    var body: some View {
        ZStack {
            Circle()
                .frame(width: radius * 2 + 28, height: radius * 2 + 28)
                .locusGlass(.clear, in: Circle())

            Circle()
                .stroke(LocusTheme.accent.opacity(0.4), lineWidth: 2)
                .frame(width: radius * 2, height: radius * 2)

            Circle()
                .fill(LocusTheme.accent)
                .frame(width: 44, height: 44)
                .shadow(color: LocusTheme.accent.opacity(0.45), radius: 8)
                .offset(dragOffset)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let limited = clamp(value.translation, radius: radius)
                            dragOffset = limited
                            onChange(CGVector(dx: limited.width / radius, dy: limited.height / radius))
                        }
                        .onEnded { _ in
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                                dragOffset = .zero
                            }
                            onChange(.zero)
                        }
                )
        }
        .accessibilityLabel("Movement joystick")
    }

    private func clamp(_ translation: CGSize, radius: CGFloat) -> CGSize {
        let length = sqrt(translation.width * translation.width + translation.height * translation.height)
        guard length > radius else { return translation }
        let scale = radius / length
        return CGSize(width: translation.width * scale, height: translation.height * scale)
    }
}
