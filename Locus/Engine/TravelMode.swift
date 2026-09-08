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

    /// The fastest this mode plausibly moves, m/s — a ceiling on what a *road
    /// limit* is allowed to ask for, not on what the rider may be told to do.
    ///
    /// A cyclist follows the road, so `usesRoadLimits` includes them, but the
    /// road's sign is not a cyclist's speed: a D road outside a village is
    /// posted at 80 and the bike on it is doing 25. Worse, MapKit routes a
    /// bicycle as a car, so nothing stopped a cycle route being sent down the
    /// A1 and simulated at 130.
    ///
    /// Driving is uncapped here on purpose: the driver's ceiling is the
    /// profile's "never exceed", which is theirs to set.
    var topSpeed: CLLocationSpeed {
        switch self {
        case .walk: return 2.2      // 8 km/h, a walk you'd call brisk
        case .run: return 5.6       // 20 km/h
        case .cycle: return 11.1    // 40 km/h, downhill on a road bike
        case .drive: return .infinity
        }
    }

    /// Whether the car presets and the grip budget describe this mode.
    ///
    /// Only driving. A bicycle is not a hatchback with a smaller engine, and
    /// offering someone on foot a choice between a van and a bus is offering
    /// them nothing.
    var isMotorVehicle: Bool { self == .drive }
}
