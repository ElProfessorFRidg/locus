import CoreLocation
import Foundation

/// A latitude/longitude pair that survives being written to disk.
/// `CLLocationCoordinate2D` is a C struct with no `Codable` conformance.
struct Coordinate2D: Codable, Equatable, Hashable {
    var latitude: Double
    var longitude: Double

    init(_ coordinate: CLLocationCoordinate2D) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }

    var clLocation: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

extension Array where Element == Coordinate2D {
    var clLocations: [CLLocationCoordinate2D] { map(\.clLocation) }
}

extension Array where Element == CLLocationCoordinate2D {
    var codable: [Coordinate2D] { map(Coordinate2D.init) }
}

/// A hand-corrected speed limit over a stretch of a route.
///
/// Locus estimates limits from the road's shape and the pace Apple expects,
/// because MapKit publishes none — so it will sometimes be wrong, and being
/// wrong about the thing the whole drive is keyed to is worth being able to fix.
/// Ranges are distances along the route rather than coordinates, which keeps
/// them stable when the plan is rebuilt at a different sampling.
struct LimitOverride: Codable, Equatable, Identifiable, Hashable {
    var id = UUID()
    var startDistance: CLLocationDistance
    var endDistance: CLLocationDistance
    /// Metres per second, so the stored value doesn't depend on display units.
    var limit: CLLocationSpeed

    func contains(_ distance: CLLocationDistance) -> Bool {
        distance >= startDistance && distance <= endDistance
    }
}

/// A route kept for next time.
///
/// Places could be saved and routes couldn't, which made a daily commute
/// something you rebuilt every morning.
struct SavedRoute: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var coordinates: [Coordinate2D]
    var distance: CLLocationDistance
    /// Apple's estimate, kept because it is what the limit estimator scales off.
    var expectedTravelTime: TimeInterval
    /// Timestamps from the GPX this came from, one per coordinate.
    ///
    /// Saving used to drop these, which meant "As recorded" — the whole point
    /// of importing a track with timing — silently stopped working the moment
    /// you kept the route for tomorrow.
    var recordedTimes: [Date]?
    var overrides: [LimitOverride] = []
    var createdAt = Date()

    var expectedSpeed: CLLocationSpeed? {
        expectedTravelTime > 1 ? distance / expectedTravelTime : nil
    }

    init(name: String, route: BuiltRoute, overrides: [LimitOverride] = []) {
        self.name = name
        coordinates = route.coordinates.codable
        distance = route.distance
        expectedTravelTime = route.expectedTravelTime
        recordedTimes = route.recordedTimes
        self.overrides = overrides
    }

    /// Routes saved before this field existed have no key for it; decoding it
    /// leniently keeps them rather than throwing the whole list away.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? container.decode(String.self, forKey: .name)) ?? "Route"
        coordinates = try container.decode([Coordinate2D].self, forKey: .coordinates)
        distance = (try? container.decode(CLLocationDistance.self, forKey: .distance)) ?? 0
        expectedTravelTime = (try? container.decode(TimeInterval.self, forKey: .expectedTravelTime)) ?? 0
        recordedTimes = try? container.decodeIfPresent([Date].self, forKey: .recordedTimes)
        overrides = (try? container.decode([LimitOverride].self, forKey: .overrides)) ?? []
        createdAt = (try? container.decode(Date.self, forKey: .createdAt)) ?? Date()
    }

    var built: BuiltRoute {
        BuiltRoute(
            name: name,
            coordinates: coordinates.clLocations,
            distance: distance,
            expectedTravelTime: expectedTravelTime,
            // Only when there is one per point: a pace mapped onto the wrong
            // places is worse than no pace at all.
            recordedTimes: recordedTimes?.count == coordinates.count ? recordedTimes : nil
        )
    }
}

/// Where a drive got to, so closing the app doesn't mean starting over.
struct RouteResumeState: Codable, Equatable {
    var routeName: String
    var coordinates: [Coordinate2D]
    var expectedTravelTime: TimeInterval
    var distance: CLLocationDistance
    /// Carried for the same reason `SavedRoute` carries it: a drive replaying a
    /// recorded pace should come back replaying that pace, not a generic one.
    var recordedTimes: [Date]?
    var overrides: [LimitOverride]
    /// How far along the drive had got, in metres.
    var travelled: CLLocationDistance
    var lap: Int
    var profileID: UUID?
    var savedAt = Date()

    /// Old enough that offering to resume would be strange rather than helpful.
    var isStale: Bool { Date().timeIntervalSince(savedAt) > 60 * 60 * 12 }

    /// Not worth offering to resume something that had barely started, or had
    /// all but finished.
    var isWorthResuming: Bool {
        travelled > 50 && distance - travelled > 100 && !isStale
    }

    var built: BuiltRoute {
        BuiltRoute(
            name: routeName,
            coordinates: coordinates.clLocations,
            distance: distance,
            expectedTravelTime: expectedTravelTime,
            recordedTimes: recordedTimes?.count == coordinates.count ? recordedTimes : nil
        )
    }
}

/// Saved routes and the one interrupted drive, kept as files.
///
/// A route is a few thousand coordinates; a handful of them in `UserDefaults`
/// would put hundreds of kilobytes into a plist that is read in full on every
/// launch. Application Support is the right place for this.
@MainActor
final class RouteStore: ObservableObject {
    @Published private(set) var routes: [SavedRoute] = []
    @Published private(set) var resumable: RouteResumeState?

    private let directory: URL
    private let routesURL: URL
    private let resumeURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("Locus", isDirectory: true)
        routesURL = directory.appendingPathComponent("routes.json")
        resumeURL = directory.appendingPathComponent("resume.json")

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        routes = Self.decode([SavedRoute].self, from: routesURL) ?? []

        if let state = Self.decode(RouteResumeState.self, from: resumeURL), state.isWorthResuming {
            resumable = state
        } else {
            clearResume()
        }
    }

    // MARK: Saved routes

    @discardableResult
    func save(_ route: BuiltRoute, named name: String, overrides: [LimitOverride]) -> SavedRoute {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = SavedRoute(
            name: trimmed.isEmpty ? route.name : trimmed,
            route: route,
            overrides: overrides
        )
        routes.insert(saved, at: 0)
        persistRoutes()
        return saved
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = routes.firstIndex(where: { $0.id == id }) else { return }
        routes[index].name = trimmed
        persistRoutes()
    }

    func delete(_ id: UUID) {
        routes.removeAll { $0.id == id }
        persistRoutes()
    }

    /// Updates the stored overrides for a route that's already saved.
    func updateOverrides(_ overrides: [LimitOverride], for id: UUID) {
        guard let index = routes.firstIndex(where: { $0.id == id }) else { return }
        routes[index].overrides = overrides
        persistRoutes()
    }

    // MARK: Resume

    /// Called as a route plays. Cheap enough at the rate it's called (every few
    /// seconds, not every fix) and the only thing that makes resume possible
    /// after a crash rather than only after a clean exit.
    func recordProgress(_ state: RouteResumeState) {
        resumable = state
        Self.encode(state, to: resumeURL)
    }

    func clearResume() {
        resumable = nil
        try? FileManager.default.removeItem(at: resumeURL)
    }

    // MARK: Files

    private func persistRoutes() {
        Self.encode(routes, to: routesURL)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func encode<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
