import ActivityKit
import Foundation

/// Puts the drive on the Lock Screen and in the Dynamic Island.
///
/// A route can run for half an hour with the phone in a pocket, and until now
/// the only way to know it was still going was to open Locus. This is the one
/// place in the app where iOS will show that for free.
///
/// The interesting constraint is the update budget. ActivityKit rate-limits
/// updates, and a route emits a fix up to four times a second — pushing all of
/// them would get the activity throttled and then ignored. So updates go out at
/// most every couple of seconds, *except* for the ones that matter: pausing,
/// stopping, and crossing the limit, which are exactly the moments someone
/// glancing at the Lock Screen wants to see immediately.
@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()

    private var activity: Activity<DriveActivityAttributes>?
    private var lastPush = Date.distantPast
    private var lastState: DriveActivityAttributes.ContentState?

    /// Anything faster than this gets coalesced.
    private let minimumInterval: TimeInterval = 2

    private init() {}

    var isSupported: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    func start(routeName: String, profileName: String, state: DriveActivityAttributes.ContentState) {
        guard isSupported else { return }
        end()

        let attributes = DriveActivityAttributes(routeName: routeName, profileName: profileName)
        activity = try? Activity.request(
            attributes: attributes,
            content: ActivityContent(state: state, staleDate: nil),
            pushType: nil
        )
        lastState = state
        lastPush = Date()
    }

    /// Sends `state` if enough has changed, or enough time has passed.
    func update(_ state: DriveActivityAttributes.ContentState) {
        guard let activity else { return }

        let elapsed = Date().timeIntervalSince(lastPush)
        let notable = lastState.map { Self.isNotable(from: $0, to: state) } ?? true
        guard notable || elapsed >= minimumInterval else { return }

        lastState = state
        lastPush = Date()
        Task {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    func end(finalState: DriveActivityAttributes.ContentState? = nil) {
        guard let activity else { return }
        self.activity = nil
        lastState = nil
        Task {
            await activity.end(
                finalState.map { ActivityContent(state: $0, staleDate: nil) },
                dismissalPolicy: .immediate
            )
        }
    }

    /// Changes worth spending an update on straight away, rather than waiting
    /// out the interval: they change what the glance *says*, not just its
    /// numbers.
    private static func isNotable(
        from old: DriveActivityAttributes.ContentState,
        to new: DriveActivityAttributes.ContentState
    ) -> Bool {
        old.isPaused != new.isPaused
            || old.isStopped != new.isStopped
            || old.isOverLimit != new.isOverLimit
            || old.limit != new.limit
    }
}
