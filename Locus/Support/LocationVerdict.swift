import Foundation

/// Fake or real? The answer behind the badge on the map and the `badge` field
/// of `locus-state.json`.
///
/// Locus' own opinion ("I am simulating") is not enough on its own: the direct
/// engine's simulation lives in `locationd` and outlives the app, so after a
/// headless run, a crash or a relaunch the in-memory state can say "idle" over
/// a phone that is still somewhere else. So the verdict also looks at what
/// Core Location itself reports, compared with the last fix known to be real.
enum ReadoutBadge: String, Equatable {
    case simulated = "SIMULATED"
    case real = "REAL"
    case interrupted = "INTERRUPTED"
    /// Locus says idle, but Core Location says otherwise.
    case uncertain = "MAYBE SIMULATED"

    var explanation: String? {
        self == .uncertain ? "location may still be simulated by locationd" : nil
    }
}

enum ReadoutVerdict {
    /// How far Core Location's fix may be from the last real one before an idle
    /// session stops being believed. Generous: a phone really can have moved.
    static let suspiciousDistance: Double = 1000

    /// - Parameter status: `idle`, `connecting`, `active`, `reconnecting` or
    ///   `dropped`, as in `locus-state.json`.
    static func badge(
        status: String,
        reportedBySoftware: Bool?,
        reported: RemotePoint?,
        lastReal: RemotePoint?
    ) -> ReadoutBadge {
        switch status {
        case "dropped": return .interrupted
        case "active", "reconnecting", "connecting": return .simulated
        default: break
        }
        if reportedBySoftware == true { return .uncertain }
        if let reported, let lastReal, distance(reported, lastReal) > suspiciousDistance {
            return .uncertain
        }
        return .real
    }

    /// Great-circle distance in metres.
    static func distance(_ a: RemotePoint, _ b: RemotePoint) -> Double {
        let radius = 6_371_000.0
        let p1 = a.lat * .pi / 180, p2 = b.lat * .pi / 180
        let dLat = (b.lat - a.lat) * .pi / 180
        let dLon = (b.lon - a.lon) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(p1) * cos(p2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * radius * asin(min(1, sqrt(h)))
    }

    /// `48.858370, 2.294480` — what the panel shows and copies.
    static func coordinateText(_ point: RemotePoint) -> String {
        String(format: "%.6f, %.6f", point.lat, point.lon)
    }
}

struct RemotePoint: Equatable {
    var lat: Double
    var lon: Double
}

/// The last fix handed to the engine, in WGS-84, with what was said about it.
struct SentFix: Equatable {
    var lat: Double
    var lon: Double
    var altitude: Double?
    /// m/s
    var speed: Double?
    var course: Double?
    var horizontalAccuracy: Double
    var timestamp: Date

    var point: RemotePoint { RemotePoint(lat: lat, lon: lon) }
}
