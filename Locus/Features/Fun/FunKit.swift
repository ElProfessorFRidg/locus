import SwiftUI

// MARK: - Palette

/// Fun mode's own palette.
///
/// It shares nothing with `LocusTheme`, deliberately. That one is built for
/// glass floating over a dark map: translucent, low-contrast, teal. This is a
/// solid app with a ground, cards on it, and three colours that each mean one
/// thing — pink is the action, green is live, violet is what you picked.
enum FunTheme {
    /// The ground. Everything sits on it; nothing else is this dark.
    static let night = Color(red: 0.082, green: 0.063, blue: 0.180)
    static let card = Color(red: 0.133, green: 0.102, blue: 0.278)
    static let cardLift = Color(red: 0.180, green: 0.145, blue: 0.376)
    static let line = Color.white.opacity(0.10)

    static let ink = Color.white
    static let mist = Color(red: 0.655, green: 0.612, blue: 0.847)

    /// The one action on the screen.
    static let punch = Color(red: 1.0, green: 0.310, blue: 0.639)
    /// What you picked.
    static let grape = Color(red: 0.545, green: 0.420, blue: 1.0)
    /// Live, connected, arrived.
    static let go = Color(red: 0.239, green: 0.863, blue: 0.592)

    static let punchGradient = LinearGradient(
        colors: [punch, grape],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

enum FunMetrics {
    static let card: CGFloat = 28
    static let tile: CGFloat = 24
    static let chip: CGFloat = 22
    /// Nothing on a Fun screen is smaller than this.
    static let tap: CGFloat = 44
    static let primary: CGFloat = 60
    /// How much room the tab bar wants under a scrolling screen.
    static let tabBar: CGFloat = 96
}

extension Font {
    /// Fun mode is rounded throughout — on device that is SF Rounded, which is
    /// the closest thing iOS has to a friendly voice.
    static func fun(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

// MARK: - Building blocks

extension View {
    /// A card: the one container Fun mode has.
    func funCard(_ radius: CGFloat = FunMetrics.card, fill: Color = FunTheme.card) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(fill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(FunTheme.line, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// A screen title. Every tab has exactly one.
struct FunTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.fun(34, .semibold))
            .foregroundStyle(FunTheme.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The label over a group. Small, wide, and never a sentence.
struct FunSectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .heavy, design: .rounded))
            .tracking(1.1)
            .foregroundStyle(FunTheme.mist)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The one action on a screen, and it is always this shape.
struct FunPrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 17, weight: .bold))
                }
                Text(title)
                    .font(.fun(18, .heavy))
            }
            .foregroundStyle(FunTheme.ink)
            .frame(maxWidth: .infinity)
            .frame(height: FunMetrics.primary)
            .background(
                Capsule().fill(FunTheme.punchGradient)
            )
            .shadow(color: FunTheme.punch.opacity(enabled ? 0.35 : 0), radius: 16, y: 8)
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// A quieter button, for the second thing on a screen.
struct FunSecondaryButton: View {
    let title: String
    var systemImage: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .bold))
                }
                Text(title)
                    .font(.fun(16, .heavy))
            }
            .foregroundStyle(FunTheme.ink)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(Capsule().fill(Color.white.opacity(0.10)))
            .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// An emoji chip: a picture, a word, and whether it's the one that's on.
struct FunChip: View {
    let emoji: String
    let title: String
    var detail: String? = nil
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(emoji)
                    .font(.system(size: 26))
                Text(title)
                    .font(.fun(13, selected ? .heavy : .bold))
                    .foregroundStyle(selected ? FunTheme.ink : FunTheme.mist)
                if let detail {
                    Text(detail)
                        .font(.fun(11, .bold))
                        .foregroundStyle(selected ? FunTheme.punch : FunTheme.mist)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: detail == nil ? 80 : 100)
            .background(
                RoundedRectangle(cornerRadius: FunMetrics.chip, style: .continuous)
                    .fill(selected ? FunTheme.punch.opacity(0.16) : FunTheme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: FunMetrics.chip, style: .continuous)
                    .stroke(selected ? FunTheme.punch : FunTheme.line, lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: FunMetrics.chip, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(detail.map { "\(title), \($0)" } ?? title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// A row inside a settings card: emoji, label, and whatever answers it.
struct FunRow<Trailing: View>: View {
    let emoji: String
    let title: String
    var showsDivider: Bool = true
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text(emoji)
                    .font(.system(size: 22))
                Text(title)
                    .font(.fun(16, .bold))
                    .foregroundStyle(FunTheme.ink)
                Spacer(minLength: 8)
                trailing
            }
            .frame(minHeight: FunMetrics.tap)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            if showsDivider {
                Rectangle()
                    .fill(Color.white.opacity(0.07))
                    .frame(height: 1)
                    .padding(.leading, 18)
            }
        }
    }
}

/// One option in a `FunSegment`. A struct rather than a tuple because Swift has
/// no key paths into tuple elements, and `ForEach` needs one.
struct FunSegmentOption<Value: Hashable>: Identifiable {
    let value: Value
    let label: String

    var id: Value { value }
}

/// A two-or-three-way choice, as a pill of pills.
struct FunSegment<Value: Hashable>: View {
    let options: [FunSegmentOption<Value>]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options) { option in
                Button {
                    withAnimation(.snappy) { selection = option.value }
                } label: {
                    Text(option.label)
                        .font(.fun(13, selection == option.value ? .heavy : .bold))
                        .foregroundStyle(selection == option.value ? FunTheme.ink : FunTheme.mist)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 8)
                        .background(
                            Capsule().fill(selection == option.value ? FunTheme.grape : .clear)
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == option.value ? [.isSelected] : [])
            }
        }
        .padding(4)
        .background(Capsule().fill(Color.white.opacity(0.07)))
    }
}
