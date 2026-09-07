import CoreLocation
import Foundation
import MapKit

/// How the route is being covered.
///
/// Extracted from `SpoofSession` so it can be reasoned about — and tested —
/// without dragging in the location FFI, UIKit and UserNotifications behind it.
/// It is four cases and a table of constants; nothing about it needs a device.
enum TravelMode: String, CaseIterable, Identifiable, Sendable {
    case walk, run, cycle, drive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .walk: return "Walk"
        case .run: return "Run"
        case .cycle: return "Cycle"
        case .drive: return "Drive"
        }
    }

    var icon: String {
        switch self {
        case .walk: return "figure.walk"
        case .run: return "figure.run"
        case .cycle: return "bicycle"
        case .drive: return "car.fill"
        }
    }

    /// Base metres per second before natural variation.
    var baseSpeed: CLLocationSpeed {
        switch self {
        case .walk: return 1.4
        case .run: return 3.3
        case .cycle: return 6.5
        case .drive: return 13.4
        }
    }

    var mkTransportType: MKDirectionsTransportType {
        switch self {
        case .walk, .run: return .walking
        case .cycle, .drive: return .automobile
        }
    }

    /// Only driving gets the full parameter set; the rest borrow the physics but
    /// the UI leads with different defaults.
    var usesRoadLimits: Bool { self == .drive || self == .cycle }
}
