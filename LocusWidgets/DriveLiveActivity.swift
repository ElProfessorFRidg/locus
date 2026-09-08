import ActivityKit
import SwiftUI
import WidgetKit

/// The drive, on the Lock Screen and in the Dynamic Island.
///
/// Deliberately reads like an instrument rather than a notification: the speed
/// is the biggest thing on it, the limit sits next to it as the round sign it is
/// on a road, and the progress bar is the only other element. Everything here
/// arrives pre-formatted from the app, so this target stays free of the engine.
struct DriveLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DriveActivityAttributes.self) { context in
            lockScreen(context)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    speed(context.state, size: 30)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let limit = context.state.limit {
                        LimitSign(value: limit)
                            .frame(width: 40, height: 40)
                            .padding(.trailing, 4)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        ProgressView(value: context.state.progress)
                            .tint(accent)
                        HStack {
                            Text(context.state.remaining)
                            Spacer()
                            Text(subtitle(context))
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: icon(context.state))
                    .foregroundStyle(accent)
            } compactTrailing: {
                Text(context.state.speed)
                    .monospacedDigit()
                    .foregroundStyle(context.state.isOverLimit ? overLimit : .primary)
            } minimal: {
                Image(systemName: icon(context.state))
                    .foregroundStyle(context.state.isOverLimit ? overLimit : accent)
            }
        }
    }

    // MARK: - Lock Screen

    private func lockScreen(_ context: ActivityViewContext<DriveActivityAttributes>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                speed(context.state, size: 38)

                if let limit = context.state.limit {
                    LimitSign(value: limit)
                        .frame(width: 44, height: 44)
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(context.attributes.routeName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text(subtitle(context))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            ProgressView(value: context.state.progress)
                .tint(accent)

            HStack {
                Text(context.state.remaining)
                Spacer()
                if let eta = context.state.eta, !context.state.isPaused {
                    Text("\(eta) to go")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    // MARK: - Pieces

    private func speed(_ state: DriveActivityAttributes.ContentState, size: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(state.speed)
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(state.isOverLimit ? overLimit : .primary)
            Text(state.unit)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func subtitle(_ context: ActivityViewContext<DriveActivityAttributes>) -> String {
        if context.state.isPaused { return "Paused" }
        if context.state.isStopped { return "Stopped" }
        return context.attributes.profileName
    }

    private func icon(_ state: DriveActivityAttributes.ContentState) -> String {
        if state.isPaused { return "pause.circle.fill" }
        if state.isStopped { return "hand.raised.fill" }
        return "location.north.circle.fill"
    }

    // Matches LocusTheme, duplicated because the widget is its own module and
    // importing the app's theme would drag SwiftUI-only helpers with it.
    private var accent: Color { Color(red: 0.35, green: 0.78, blue: 0.72) }
    private var overLimit: Color { Color(red: 0.94, green: 0.27, blue: 0.27) }
}

/// The round limit sign, same as the one in the app's HUD.
struct LimitSign: View {
    let value: String

    var body: some View {
        ZStack {
            Circle().fill(.white)
            Circle().strokeBorder(Color(red: 0.94, green: 0.27, blue: 0.27), lineWidth: 4)
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.black)
                .minimumScaleFactor(0.5)
                .padding(4)
        }
        .accessibilityLabel("Speed limit \(value)")
    }
}
