import MapKit
import SwiftUI

/// A route stop on the map: lettered, draggable, and removable in place.
///
/// The route used to be built from a sheet that could only borrow the single
/// teleport pin, so setting both ends meant closing the sheet, moving the pin
/// and coming back. Putting every stop on the map as its own object is what
/// removes that loop — you drag the end of the route to where you want it and
/// watch the road follow, which is the only way anyone has ever wanted to do
/// this.
struct RouteStopMarker: View {
    let label: String
    /// Start and end get their own colours; stops along the way share one.
    let role: Role
    var isFocused: Bool
    var isDragging: Bool
    var name: String?
    var onTap: () -> Void
    var onRemove: () -> Void
    var onDragBegan: () -> Void
    var onDragMoved: (CGPoint) -> Void
    var onDragEnded: () -> Void

    enum Role {
        case start
        case waypoint
        case end

        var tint: Color {
            switch self {
            case .start: return LocusTheme.statusGood
            case .waypoint: return LocusTheme.accentSecondary
            case .end: return LocusTheme.accent
            }
        }

        var title: String {
            switch self {
            case .start: return "Start"
            case .waypoint: return "Stop"
            case .end: return "End"
            }
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            if isFocused, !isDragging {
                Button(action: onRemove) {
                    Label("Remove", systemImage: "trash.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LocusTheme.danger)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .locusGlass(.regular, in: Capsule())
                .contentShape(Capsule())
                .transition(.scale(scale: 0.9, anchor: .bottom).combined(with: .opacity))
            }

            // The name sits above the marker rather than inside it: a stop is
            // only right or wrong by where it is, and "Rue de Rivoli" answers
            // that where a letter cannot.
            if let name, !name.isEmpty, !isDragging {
                Text(name)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .locusGlass(.clear, in: Capsule())
                    .fixedSize()
            }

            ZStack {
                Circle()
                    .fill(role.tint)
                    .frame(width: isDragging ? 34 : 28, height: isDragging ? 34 : 28)
                    .shadow(color: .black.opacity(0.35), radius: isDragging ? 8 : 3, y: 2)

                Circle()
                    .strokeBorder(.white, lineWidth: isFocused ? 3 : 2)
                    .frame(width: isDragging ? 34 : 28, height: isDragging ? 34 : 28)

                Text(label)
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            }
            .scaleEffect(isDragging ? 1.1 : 1)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .gesture(dragGesture)
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: isFocused)
        .animation(.easeOut(duration: 0.15), value: isDragging)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(role.title) \(label)\(name.map { ", \($0)" } ?? "")")
        .accessibilityHint("Tap to select. Touch and hold to drag it somewhere else.")
    }

    private var dragGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .onChanged { value in
                guard case .second(true, let drag) = value, let drag else { return }
                if !isDragging {
                    onDragBegan()
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
                onDragMoved(drag.location)
            }
            .onEnded { _ in onDragEnded() }
    }
}
