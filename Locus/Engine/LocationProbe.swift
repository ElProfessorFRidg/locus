import CoreLocation
import Foundation

/// What an app on this phone actually receives from Core Location right now.
///
/// Locus sets a location; this reads it back the way any other app would, so
/// "did it work?" has an answer that doesn't depend on Locus' own opinion. The
/// part worth reading is `sourceInformation`: iOS itself marks a fix as
/// simulated when it comes from the developer location service.
///
/// Reads only. Nothing here changes what is reported.
@MainActor
final class LocationProbe: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationProbe()

    struct Reading: Equatable {
        var coordinate: CLLocationCoordinate2D
        var horizontalAccuracy: CLLocationAccuracy
        var verticalAccuracy: CLLocationAccuracy
        var altitude: CLLocationDistance
        var speed: CLLocationSpeed
        var course: CLLocationDirection
        var timestamp: Date
        /// `nil` when iOS gives no source information for this fix.
        var isSimulatedBySoftware: Bool?
        var isProducedByAccessory: Bool?

        static func == (lhs: Reading, rhs: Reading) -> Bool {
            lhs.coordinate.latitude == rhs.coordinate.latitude
                && lhs.coordinate.longitude == rhs.coordinate.longitude
                && lhs.timestamp == rhs.timestamp
        }
    }

    @Published private(set) var reading: Reading?
    @Published private(set) var authorization: CLAuthorizationStatus
    @Published private(set) var isRunning = false

    private let manager = CLLocationManager()

    private override init() {
        authorization = .notDetermined
        super.init()
        authorization = manager.authorizationStatus
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        // Foreground only: this is a readout, not a reason to keep the radios up.
        manager.allowsBackgroundLocationUpdates = false
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        manager.startUpdatingLocation()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        manager.stopUpdatingLocation()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let source = location.sourceInformation
        let reading = Reading(
            coordinate: location.coordinate,
            horizontalAccuracy: location.horizontalAccuracy,
            verticalAccuracy: location.verticalAccuracy,
            altitude: location.altitude,
            speed: location.speed,
            course: location.course,
            timestamp: location.timestamp,
            isSimulatedBySoftware: source?.isSimulatedBySoftware,
            isProducedByAccessory: source?.isProducedByAccessory
        )
        Task { @MainActor in self.reading = reading }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.authorization = status }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
