import CoreLocation
import SwiftUI
import UIKit

/// A spot being created or edited.
struct FunSpotDraft: Identifiable {
    let id = UUID()
    /// Nil when this is a new spot.
    var existing: SavedPlace?
    var coordinate: CLLocationCoordinate2D
    var name: String
    var emoji: String

    init(coordinate: CLLocationCoordinate2D, suggestedName: String?) {
        self.existing = nil
        self.coordinate = coordinate
        self.name = suggestedName ?? ""
        self.emoji = "📍"
    }

    init(place: SavedPlace) {
        self.existing = place
        self.coordinate = place.coordinate
        self.name = place.name
        self.emoji = place.emoji ?? "📍"
    }
}

/// Name it, pick a picture for it, keep it.
///
/// The emoji is the point. A grid of nine places called "Home", "School" and
/// "Nan's" is nine identical rows to read; a grid of 🏠 🏫 👵 is recognised
/// before it is read.
struct FunSpotEditor: View {
    @State var draft: FunSpotDraft

    @EnvironmentObject private var session: SpoofSession
    @Environment(\.dismiss) private var dismiss
    @FocusState private var naming: Bool

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 7)

    /// Shared with Pro's Places list, so both interfaces offer the same set.
    private static let palette = SavedPlace.emojiPalette

    var body: some View {
        ZStack {
            FunTheme.night.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 22) {
                    HStack(spacing: 14) {
                        Text(draft.emoji)
                            .font(.system(size: 34))
                            .frame(width: 66, height: 66)
                            .background(
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .fill(FunTheme.punchGradient)
                            )

                        VStack(alignment: .leading, spacing: 3) {
                            Text(draft.existing == nil ? "New spot" : "Edit spot")
                                .font(.fun(24, .semibold))
                                .foregroundStyle(FunTheme.ink)
                            Text(CoordinateParser.text(draft.coordinate))
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(FunTheme.mist)
                        }

                        Spacer(minLength: 0)
                    }

                    TextField("", text: $draft.name, prompt: Text("Call it something")
                        .foregroundColor(FunTheme.mist))
                        .font(.fun(17, .heavy))
                        .foregroundStyle(FunTheme.ink)
                        .focused($naming)
                        .submitLabel(.done)
                        .textInputAutocapitalization(.words)
                        .padding(.horizontal, 18)
                        .frame(height: 56)
                        .background(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(FunTheme.cardLift)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(naming ? FunTheme.grape : FunTheme.line, lineWidth: naming ? 1.5 : 1)
                        )

                    VStack(spacing: 12) {
                        FunSectionLabel(text: "Pick an emoji")

                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(Self.palette, id: \.self) { emoji in
                                Button {
                                    withAnimation(.snappy(duration: 0.15)) { draft.emoji = emoji }
                                    UISelectionFeedbackGenerator().selectionChanged()
                                } label: {
                                    Text(emoji)
                                        .font(.system(size: 24))
                                        .frame(maxWidth: .infinity)
                                        .frame(height: FunMetrics.tap)
                                        .background(
                                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                .fill(draft.emoji == emoji
                                                      ? FunTheme.punch.opacity(0.22)
                                                      : Color.white.opacity(0.06))
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                .stroke(FunTheme.punch, lineWidth: draft.emoji == emoji ? 1.5 : 0)
                                        )
                                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(emoji)
                                .accessibilityAddTraits(draft.emoji == emoji ? [.isSelected] : [])
                            }
                        }
                    }

                    VStack(spacing: 12) {
                        FunPrimaryButton(title: "Save this spot", systemImage: "checkmark") {
                            save()
                        }

                        if let existing = draft.existing {
                            Button(role: .destructive) {
                                session.removeFavorite(existing)
                                dismiss()
                            } label: {
                                Text("Remove it")
                                    .font(.fun(16, .heavy))
                                    .foregroundStyle(FunTheme.punch)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 56)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Spacer(minLength: 10)
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 20)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .preferredColorScheme(.dark)
    }

    private func save() {
        if let existing = draft.existing {
            session.updateFavorite(existing, name: draft.name, emoji: draft.emoji)
        } else {
            session.addFavorite(
                name: draft.name.isEmpty ? "Spot" : draft.name,
                coordinate: draft.coordinate,
                emoji: draft.emoji
            )
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        session.flash("\(draft.emoji) \(draft.name.isEmpty ? "Spot" : draft.name) saved")
        dismiss()
    }
}
