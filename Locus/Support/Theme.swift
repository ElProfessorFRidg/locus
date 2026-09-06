import CoreLocation
import SwiftUI

enum LocusTheme {
    static let accent = Color(red: 0.35, green: 0.78, blue: 0.72)
    static let accentSecondary = Color(red: 0.95, green: 0.55, blue: 0.28)
    static let danger = Color(red: 0.92, green: 0.32, blue: 0.36)
    static let panelStroke = Color.white.opacity(0.12)
    static let statusGood = Color(red: 0.30, green: 0.86, blue: 0.55)
    static let statusWarn = Color(red: 0.98, green: 0.78, blue: 0.28)
    static let statusBad = Color(red: 0.92, green: 0.32, blue: 0.36)

    /// Speed-limit sign red, for the HUD ring when you're over the limit.
    static let overLimit = Color(red: 0.94, green: 0.27, blue: 0.27)

    /// Colour for a stretch of road carrying `limit` (m/s), on a scale running
    /// from residential to motorway.
    ///
    /// Teal → green → amber → orange, which reads as "slow to fast" without
    /// anyone needing the legend, and stays distinguishable on both the standard
    /// and satellite map styles.
    static func speedColor(forLimit limit: CLLocationSpeed, unit: SpeedUnit) -> Color {
        let ladder = unit.speedLadder
        guard let slowest = ladder.first, let fastest = ladder.last, fastest > slowest else {
            return accent
        }
        let value = unit.fromMetresPerSecond(limit)
        let t = ((value - slowest) / (fastest - slowest)).clamped(to: 0...1)
        // 0.47 (teal) down to 0.06 (orange-red). Saturation lifts slightly with
        // speed so the fast end reads as emphatic rather than merely different.
        return Color(hue: 0.47 - 0.41 * t, saturation: 0.62 + 0.24 * t, brightness: 0.95)
    }
}

enum LocusMetrics {
    static let trayRadius: CGFloat = 28
    static let panelRadius: CGFloat = 20
    static let barRadius: CGFloat = 18
    static let controlSide: CGFloat = 44
    /// Distance below which two glass shapes in the same container merge.
    static let glassSpacing: CGFloat = 18
}

enum LocusGlassStyle {
    case regular
    case clear
    case interactive
}

/// Liquid Glass on iOS 26+; a layered material that reads similarly on 18–25.
///
/// The fallback is not just `.ultraThinMaterial`: real Liquid Glass has a bright
/// top edge and a hairline rim, and without them the pre-26 build looks flat
/// next to screenshots of the 26 one.
struct LocusGlassModifier<S: Shape>: ViewModifier {
    var style: LocusGlassStyle
    var shape: S
    var tint: Color?

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(glass, in: shape)
                // Glass draws outside the layout bounds; expand hit-testing to match.
                .contentShape(shape)
        } else {
            content
                .background {
                    shape.fill(style == .clear ? .thinMaterial : .ultraThinMaterial)
                    if let tint {
                        shape.fill(tint.opacity(0.55))
                    }
                    shape.fill(
                        LinearGradient(
                            colors: [.white.opacity(0.18), .clear, .black.opacity(0.06)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
                .overlay(shape.stroke(LocusTheme.panelStroke, lineWidth: 1))
                .contentShape(shape)
        }
    }

    @available(iOS 26.0, *)
    private var glass: Glass {
        var g: Glass = style == .clear ? .clear : .regular
        if style == .interactive { g = g.interactive() }
        if let tint { g = g.tint(tint) }
        return g
    }
}

/// A shared sampling region for several glass elements.
///
/// Glass cannot sample other glass — two `.glassEffect` views that overlap
/// outside a container each try to refract the map underneath and end up
/// muddy. Inside one container they share a region, blend where they are close,
/// and can morph into each other when paired with `locusGlassID`.
struct LocusGlassGroup<Content: View>: View {
    var spacing: CGFloat = LocusMetrics.glassSpacing
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

extension View {
    func locusGlass<S: Shape>(
        _ style: LocusGlassStyle = .regular,
        tint: Color? = nil,
        in shape: S
    ) -> some View {
        modifier(LocusGlassModifier(style: style, shape: shape, tint: tint))
    }

    func locusGlass(_ style: LocusGlassStyle = .regular, tint: Color? = nil) -> some View {
        locusGlass(
            style,
            tint: tint,
            in: RoundedRectangle(cornerRadius: LocusMetrics.panelRadius, style: .continuous)
        )
    }

    /// Ties this glass shape to an identity so it morphs, rather than fades,
    /// when it appears, moves or is replaced inside the same `LocusGlassGroup`.
    @ViewBuilder
    func locusGlassID(_ id: some Hashable, in namespace: Namespace.ID) -> some View {
        if #available(iOS 26.0, *) {
            glassEffectID(id, in: namespace)
        } else {
            matchedGeometryEffect(id: id, in: namespace)
        }
    }

    /// The one loud action on a screen: Teleport, Drive, Connect.
    func locusPrimaryButton(tint: Color = LocusTheme.accent) -> some View {
        modifier(LocusPrimaryButton(tint: tint))
    }

    /// Everything else that still needs to read as a button on top of the map.
    func locusSecondaryButton() -> some View {
        modifier(LocusSecondaryButton())
    }
}

struct LocusPrimaryButton: ViewModifier {
    var tint: Color

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .buttonStyle(.glassProminent)
                .tint(tint)
                .controlSize(.large)
        } else {
            content.buttonStyle(LegacyPrimaryButtonStyle(tint: tint))
        }
    }
}

struct LocusSecondaryButton: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .buttonStyle(.glass)
                .controlSize(.large)
        } else {
            content.buttonStyle(LegacySecondaryButtonStyle())
        }
    }
}

private struct LegacyPrimaryButtonStyle: ButtonStyle {
    var tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.black)
            .padding(.vertical, 14)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
            .background(Capsule().fill(tint))
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

private struct LegacySecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.primary)
            .padding(.vertical, 14)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
            .locusGlass(.interactive, in: Capsule())
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

/// A round glass control sized for a thumb, used all over the map chrome.
struct GlassIconButton: View {
    let systemName: String
    var tint: Color?
    var isOn: Bool = false
    var accessibilityLabel: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.body.weight(.semibold))
                .frame(width: LocusMetrics.controlSide, height: LocusMetrics.controlSide)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isOn ? (tint ?? LocusTheme.accent) : .primary)
        .locusGlass(.interactive, tint: isOn ? (tint ?? LocusTheme.accent).opacity(0.35) : nil, in: Circle())
        .accessibilityLabel(accessibilityLabel ?? systemName)
    }
}
