import CoreLocation
import Foundation

/// Live state of a route being driven, for the HUD.
struct DriveTelemetry: Equatable {
    var speed: CLLocationSpeed = 0
    /// Estimated posted limit here, or `nil` when not driving to limits.
    var speedLimit: CLLocationSpeed?
    var course: CLLocationDirection = 0
    var progress: Double = 0
    var distanceTravelled: CLLocationDistance = 0
    var distanceRemaining: CLLocationDistance = 0
    /// Simulated seconds — with `timeScale` above 1 this runs ahead of the clock.
    var elapsed: TimeInterval = 0
    var isStopped = false
    var isOverLimit = false
    /// 1 on the first pass, 2 on the way back, and so on.
    var lap: Int = 1
    var totalDistance: CLLocationDistance = 0
}
