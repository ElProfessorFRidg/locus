import CoreLocation
import Foundation

/// Numbers as people read them: distances, clock times, speeds, nudge steps.
///
/// Extracted from the HUD it was first written for. Half the app formats these
/// — the planner, the trip summary, the Live Activity — and none of that is a
/// reason to compile a SwiftUI view, or to be unable to test the rounding.
enum DriveFormat {
    static func distance(_ metres: CLLocationDistance) -> String {
        if metres < 1000 {
            return "\(Int(metres.rounded())) m"
        }
        return String(format: "%.1f km", metres / 1000)
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// Remaining time at the current speed. Reported in *wall-clock* seconds, so
    /// a 4× time scale says how long you actually have to wait.
    static func eta(telemetry: DriveTelemetry, timeScale: Double) -> String? {
        guard telemetry.speed > 0.5, telemetry.distanceRemaining > 1 else { return nil }
        let simulatedSeconds = telemetry.distanceRemaining / telemetry.speed
        let realSeconds = simulatedSeconds / max(0.05, timeScale)
        return clock(realSeconds)
    }

    static func speed(_ metresPerSecond: CLLocationSpeed, unit: SpeedUnit) -> String {
        "\(Int(unit.fromMetresPerSecond(metresPerSecond).rounded())) \(unit.short)"
    }

    /// A nudge step, short enough to sit inside a 36-point button.
    static func stepLabel(_ metres: Double) -> String {
        metres < 1
            ? String(format: "%.1f m", metres)
            : "\(Int(metres.rounded())) m"
    }
}
