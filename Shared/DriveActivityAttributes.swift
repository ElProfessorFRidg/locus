import ActivityKit
import Foundation

/// What the Live Activity shows while a route is playing.
///
/// Everything here is **pre-formatted text**, not raw numbers. The widget
/// extension is a separate module, and sharing `DriveProfile`, `SpeedUnit` and
/// the formatters with it would drag most of the engine across a target
/// boundary for the sake of rendering "48 km/h". Formatting in the app keeps the
/// widget to SwiftUI and ActivityKit, and keeps unit handling in one place.
struct DriveActivityAttributes: ActivityAttributes {
    /// The parts that change as the route plays.
    struct ContentState: Codable, Hashable {
        /// e.g. "48"
        var speed: String
        /// e.g. "km/h"
        var unit: String
        /// The estimated limit here, e.g. "50". Absent when not driving to limits.
        var limit: String?
        /// 0…1 along the route.
        var progress: Double
        /// e.g. "4.2 km left"
        var remaining: String
        /// Wall-clock time left at the current speed, e.g. "6:31". Absent when stopped.
        var eta: String?
        var isPaused: Bool
        var isStopped: Bool
        var isOverLimit: Bool
    }

    /// Fixed for the life of the activity.
    var routeName: String
    var profileName: String
}
