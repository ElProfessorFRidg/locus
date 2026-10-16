import CoreLocation
import Foundation

/// Whether the direct engine is actually moving the location, checked by
/// asking CoreLocation where it now thinks the phone is.
///
/// `CLSimulationManager` answers nothing: every call returns void, and a
/// `locationd` that refuses the caller refuses silently. Holding the
/// entitlement is necessary, not sufficient — a jailbreak whose AMFI patches
/// don't cover it, a TrollStore install on a build whose `locationd` checks
/// something more, a re-sign that kept the entitlement blob but not its
/// validity. Each of those looks exactly like success from in here, and the
/// only symptom is Maps not moving.
///
/// So the first direct teleport of each launch is checked against the one
/// witness there is: the location every other app is about to be told.
enum DirectCheckResult: Equatable {
    case notRun
    case checking
    /// CoreLocation reported the simulated spot.
    case working
    /// CoreLocation kept reporting somewhere else after the teleport.
    case notTaking
    /// No fresh fix arrived to compare against — location permission off, or
    /// `locationd` slow to answer. Says nothing either way.
    case inconclusive

    var title: String {
        switch self {
        case .notRun: return "Not checked yet"
        case .checking: return "Checking…"
        case .working: return "Working — iOS reports the simulated location"
        case .notTaking: return "Not taking effect"
        case .inconclusive: return "Couldn’t tell"
        }
    }
}

@MainActor
final class DirectSimulationCheck: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var target: CLLocation?
    private var startedAt = Date.distantPast
    private var sawFreshFix = false
    private var continuation: CheckedContinuation<DirectCheckResult, Never>?
    private var timeout: Task<Void, Never>?

    /// How close counts as "there". Generous on purpose: GPS scatter and the
    /// China offset are both well inside it, a failed spoof almost never is.
    private let tolerance: CLLocationDistance = 250

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
    }

    /// Watches for up to `seconds` for a fix near `wgs84`.
    func verify(_ wgs84: CLLocationCoordinate2D, within seconds: Double = 8) async -> DirectCheckResult {
        finish(.inconclusive)
        switch manager.authorizationStatus {
        case .denied, .restricted:
            return .inconclusive
        default:
            break
        }

        target = CLLocation(latitude: wgs84.latitude, longitude: wgs84.longitude)
        // Fixes stamped before the teleport are the real location, cached.
        // A second of slack for the clock `locationd` stamps with.
        startedAt = Date().addingTimeInterval(-1)
        sawFreshFix = false

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            manager.startUpdatingLocation()
            timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.finish(self.sawFreshFix ? .notTaking : .inconclusive)
            }
        }
    }

    private func finish(_ result: DirectCheckResult) {
        timeout?.cancel()
        timeout = nil
        manager.stopUpdatingLocation()
        target = nil
        let pending = continuation
        continuation = nil
        pending?.resume(returning: result)
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in self.consider(locations) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // `locationUnknown` is transient and the watch goes on; anything else
        // ends it without a verdict.
        guard (error as? CLError)?.code != .locationUnknown else { return }
        Task { @MainActor in self.finish(.inconclusive) }
    }

    private func consider(_ locations: [CLLocation]) {
        guard let target else { return }
        for location in locations where location.timestamp >= startedAt {
            sawFreshFix = true
            if location.distance(from: target) <= tolerance {
                finish(.working)
                return
            }
        }
        // A fresh fix somewhere else is not yet a verdict: the first one after
        // a teleport can still be the old position on its way out. The timeout
        // decides, with `sawFreshFix` saying a fix did arrive.
    }
}
