import CoreLocation
import Foundation

/// Turns the pin's coordinates into something worth reading.
///
/// "48.85837, 2.29448" is the correct answer to *where* and a useless one to
/// *what*. Every place Locus shows a coordinate — the status bar, a starred
/// favourite, the recents list — reads better as an address, so this resolves
/// one and hands it around.
///
/// Two things it is careful about. `SpoofSession.apply` writes `pin` on every
/// simulated fix, so resolving on pin changes alone would fire a geocode a
/// second for the whole of a route; and `CLGeocoder` is rate-limited by Apple,
/// so being sloppy here gets requests silently dropped for everyone. Resolution
/// is therefore explicit, debounced, and skipped entirely when the new pin is
/// close to one already resolved.
@MainActor
final class PlaceResolver: ObservableObject {
    /// The address for `resolvedCoordinate`, when one was found.
    @Published private(set) var address: String?
    @Published private(set) var isResolving = false

    private var resolvedCoordinate: CLLocationCoordinate2D?
    private let geocoder = CLGeocoder()
    private var task: Task<Void, Never>?

    /// Distance beyond which a cached address no longer describes the pin.
    private let staleDistance: CLLocationDistance = 40

    /// The address, but only if it still describes `coordinate`. Anything
    /// further away than a street corner gets nil rather than a plausible lie.
    func address(for coordinate: CLLocationCoordinate2D?) -> String? {
        guard let coordinate, let address, let resolvedCoordinate,
              Geo.distance(coordinate, resolvedCoordinate) < staleDistance else { return nil }
        return address
    }

    /// Asks for the address of `coordinate`. Cheap to call repeatedly: a pin
    /// dragged across the map only produces one request, after it settles.
    func resolve(_ coordinate: CLLocationCoordinate2D?) {
        task?.cancel()

        guard let coordinate else {
            address = nil
            resolvedCoordinate = nil
            isResolving = false
            return
        }

        // Already know this one.
        if let resolvedCoordinate, Geo.distance(coordinate, resolvedCoordinate) < staleDistance {
            return
        }

        address = nil
        isResolving = true

        task = Task { [weak self] in
            // Settle first: dragging a pin fires this continuously, and only the
            // coordinate it lands on is worth a request.
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, !Task.isCancelled else { return }

            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let placemarks = try? await self.geocoder.reverseGeocodeLocation(location)

            guard !Task.isCancelled else { return }
            self.isResolving = false
            guard let placemark = placemarks?.first else { return }

            self.address = Self.describe(placemark)
            self.resolvedCoordinate = coordinate
        }
    }

    func clear() {
        task?.cancel()
        task = nil
        address = nil
        resolvedCoordinate = nil
        isResolving = false
    }

    /// A line someone would actually say out loud: the specific part, then the
    /// town. Not the postal address, which is too long for a status bar and
    /// mostly redundant on a map.
    /// `nonisolated` because it is a pure reading of a placemark and nothing
    /// else — `PlaceNamer` is a separate actor and has the same question.
    nonisolated static func describe(_ placemark: CLPlacemark) -> String? {
        let specific = placemark.name
            ?? [placemark.subThoroughfare, placemark.thoroughfare]
                .compactMap { $0 }
                .joined(separator: " ")
                .nilIfEmpty

        let area = placemark.locality ?? placemark.subAdministrativeArea ?? placemark.administrativeArea

        switch (specific, area) {
        case let (specific?, area?):
            // "Rue de Rivoli, Paris" — but not "Paris, Paris".
            return specific.caseInsensitiveCompare(area) == .orderedSame ? specific : "\(specific), \(area)"
        case let (specific?, nil):
            return specific
        case let (nil, area?):
            return area
        default:
            return placemark.country
        }
    }
}

/// Names a handful of fixed points, one request at a time.
///
/// The resolver above tracks a single moving pin. Route stops are a different
/// shape of problem: a small set that changes rarely and wants naming all at
/// once. `CLGeocoder` serves one request per instance — a second cancels the
/// first — and Apple rate-limits per app, so an actor is doing real work here
/// rather than decorating: it queues the requests and remembers the answers.
actor PlaceNamer {
    static let shared = PlaceNamer()

    private let geocoder = CLGeocoder()
    private var cache: [String: String] = [:]

    func name(for coordinate: CLLocationCoordinate2D) async -> String? {
        // ~11 m of precision. Two stops that round to the same key are the same
        // doorway, and asking twice would spend a request to learn that.
        let key = String(format: "%.4f,%.4f", coordinate.latitude, coordinate.longitude)
        if let cached = cache[key] { return cached }

        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let placemark = try? await geocoder.reverseGeocodeLocation(location).first,
              let described = PlaceResolver.describe(placemark) else { return nil }

        if cache.count > 300 { cache.removeAll() }
        cache[key] = described
        return described
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
