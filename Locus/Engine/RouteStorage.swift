import CoreLocation
import Foundation

/// A latitude/longitude pair that survives being written to disk.
/// `CLLocationCoordinate2D` is a C struct with no `Codable` conformance.
struct Coordinate2D: Codable, Equatable, Hashable, Sendable {
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

/// How the saved list is ordered.
///
/// "Recent" means recently *driven*, falling back to when it was saved — the
/// list should lead with what you use, and what you saved last is only a proxy
/// for that on the first day.
enum SavedRouteOrder: String, CaseIterable, Identifiable {
    case recent
    case mostDriven
    case longest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recent: return "Recent"
        case .mostDriven: return "Most driven"
        case .longest: return "Longest"
        }
    }

    func sort(_ routes: [SavedRoute]) -> [SavedRoute] {
        switch self {
        case .recent:
            return routes.sorted { $0.lastUsedAt > $1.lastUsedAt }
        case .mostDriven:
            // Ties broken by recency rather than left to `sorted`, which is not
            // stable — otherwise a list of never-driven routes reshuffles itself
            // every time the sheet redraws.
            return routes.sorted {
                $0.driveCount == $1.driveCount
                    ? $0.lastUsedAt > $1.lastUsedAt
                    : $0.driveCount > $1.driveCount
            }
        case .longest:
            return routes.sorted { $0.distance > $1.distance }
        }
    }
}

extension Array where Element == SavedRoute {
    func matching(_ filter: String) -> [SavedRoute] {
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return needle.isEmpty ? self : self.filter { $0.matches(needle) }
    }

    /// Puts a route back where it was, or as near as the list still allows.
    ///
    /// The index came from before the deletion and the list can have moved on
    /// since — something saved, something else deleted — so it is clamped
    /// rather than trusted. Restoring to the wrong place is a much smaller
    /// problem than trapping on an index that no longer exists.
    func reinserting(_ route: SavedRoute, at index: Int) -> [SavedRoute] {
        var copy = self
        copy.insert(route, at: Swift.min(Swift.max(0, index), copy.count))
        return copy
    }
}

/// A hand-corrected speed limit over a stretch of a route.
///
/// Locus estimates limits from the road's shape and the pace Apple expects,
/// because MapKit publishes none — so it will sometimes be wrong, and being
/// wrong about the thing the whole drive is keyed to is worth being able to fix.
/// Ranges are distances along the route rather than coordinates, which keeps
/// them stable when the plan is rebuilt at a different sampling.
struct LimitOverride: Codable, Equatable, Identifiable, Hashable, Sendable {
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
struct SavedRoute: Codable, Identifiable, Equatable, Sendable {
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
    /// Where it runs between, in words.
    ///
    /// The saved list showed a name, a distance and a date, and none of those
    /// answer the only question you ask of it: is this the one to the office or
    /// the one to my mother's? Resolved once when the route is saved, because
    /// geocoding a list on every appearance is how you get rate-limited.
    var startName: String?
    var endName: String?
    var overrides: [LimitOverride] = []
    var createdAt = Date()
    /// Bumped every time the route is driven, so the list can lead with what
    /// you actually use rather than what you saved most recently.
    var lastDrivenAt: Date?
    var driveCount: Int = 0

    /// When this route last mattered. Driven beats saved: a commute kept in
    /// January and driven this morning belongs at the top, not at the bottom.
    var lastUsedAt: Date { lastDrivenAt ?? createdAt }

    /// "Home → Office" when both ends are known, one end when only one is.
    var journey: String? {
        switch (startName, endName) {
        case let (start?, end?): return "\(start) → \(end)"
        case let (start?, nil): return "from \(start)"
        case let (nil, end?): return "to \(end)"
        default: return nil
        }
    }

    /// Whether this route answers a search of the saved list.
    ///
    /// The endpoint names count as well as the route's own name, which is the
    /// whole point: you remember where a route goes far more reliably than what
    /// you called it, and "office" should find the one you named "Monday".
    func matches(_ needle: String) -> Bool {
        guard !needle.isEmpty else { return true }
        return [name, startName, endName]
            .compactMap { $0?.lowercased() }
            .contains { $0.contains(needle) }
    }

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
        startName = try? container.decodeIfPresent(String.self, forKey: .startName)
        endName = try? container.decodeIfPresent(String.self, forKey: .endName)
        overrides = (try? container.decode([LimitOverride].self, forKey: .overrides)) ?? []
        createdAt = (try? container.decode(Date.self, forKey: .createdAt)) ?? Date()
        lastDrivenAt = try? container.decodeIfPresent(Date.self, forKey: .lastDrivenAt)
        driveCount = (try? container.decode(Int.self, forKey: .driveCount)) ?? 0
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
struct RouteResumeState: Codable, Equatable, Sendable {
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
/// A route that was deleted, and where in the list it sat.
struct DeletedRoute: Identifiable, Equatable {
    let route: SavedRoute
    let index: Int
    var id: UUID { route.id }
}

@MainActor
final class RouteStore: ObservableObject {
    @Published private(set) var routes: [SavedRoute] = []
    @Published private(set) var resumable: RouteResumeState?

    /// The route deleted most recently, offered back until you do something
    /// else with the list.
    ///
    /// Deleting a saved route destroys its limit corrections, its recorded
    /// pace and its endpoint names — work that took a drive to produce and one
    /// swipe to lose. Kept in memory only: an undo still available tomorrow
    /// isn't an undo, it's a bin, and a bin is a bigger idea than this list
    /// needs.
    @Published private(set) var lastDeleted: DeletedRoute?

    private let directory: URL
    private let routesURL: URL
    private let resumeURL: URL

    /// How a coordinate becomes a place name. Injected rather than called
    /// directly so this file stays free of MapKit: the store is persistence,
    /// and the geocoder is somebody else's job. The app wires in `PlaceNamer`
    /// at launch; tests hand it a closure that answers instantly.
    var nameResolver: (@Sendable (CLLocationCoordinate2D) async -> String?)?

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
    func save(
        _ route: BuiltRoute,
        named name: String,
        overrides: [LimitOverride],
        startName: String? = nil,
        endName: String? = nil
    ) -> SavedRoute {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Uniquified here rather than at the call sites: saving happens from the
        // planner, the trip summary and "Save a copy", and the last of those
        // pre-fills the name of the route it is copying. Doing it once in the
        // store means no path can put two identical rows in the list.
        var saved = SavedRoute(
            name: Self.uniqueName(trimmed.isEmpty ? route.name : trimmed, among: routes),
            route: route,
            overrides: overrides
        )
        saved.startName = startName
        saved.endName = endName
        routes.insert(saved, at: 0)
        lastDeleted = nil
        persistRoutes()

        // Named in the background when the caller didn't already know. One
        // request per end, once in the route's life — the list itself never
        // geocodes, which is what keeps it off Apple's rate limiter.
        if startName == nil || endName == nil {
            resolveEndpointNames(for: saved.id)
        }
        return saved
    }

    /// Fills in whichever endpoint names are still missing.
    func resolveEndpointNames(for id: UUID) {
        guard let resolve = nameResolver,
              let route = routes.first(where: { $0.id == id }),
              let first = route.coordinates.first,
              let last = route.coordinates.last else { return }

        Task { [weak self] in
            let start = route.startName ?? await resolve(first.clLocation)
            let end = route.endName ?? await resolve(last.clLocation)
            // Re-found by id: the list can have been edited while the geocoder
            // was out, and writing back to a stale index renames a stranger.
            guard let self, let index = self.routes.firstIndex(where: { $0.id == id }) else { return }
            self.routes[index].startName = start
            self.routes[index].endName = end
            self.persistRoutes()
        }
    }

    /// Records that a saved route was driven, so the list can lead with what
    /// gets used rather than what was saved last.
    func markDriven(_ id: UUID) {
        guard let index = routes.firstIndex(where: { $0.id == id }) else { return }
        routes[index].lastDrivenAt = Date()
        routes[index].driveCount += 1
        persistRoutes()
    }

    /// A copy to experiment on, so a commute with corrections you trust isn't
    /// the thing you edit to try something.
    @discardableResult
    func duplicate(_ id: UUID) -> SavedRoute? {
        guard let original = routes.first(where: { $0.id == id }) else { return nil }
        var copy = original
        copy.id = UUID()
        copy.name = Self.uniqueName("\(original.name) copy", among: routes)
        copy.createdAt = Date()
        copy.lastDrivenAt = nil
        copy.driveCount = 0
        routes.insert(copy, at: 0)
        lastDeleted = nil
        persistRoutes()
        return copy
    }

    /// `name`, or `name 2`, `name 3`… until nothing else is called that.
    ///
    /// Duplicating twice used to give two rows both called "Commute copy", in
    /// the one list whose entire job is telling routes apart.
    ///
    /// `nonisolated` because it touches nothing on the store — the class is
    /// `@MainActor`, which would otherwise make a pure function unreachable
    /// from anywhere that isn't.
    nonisolated static func uniqueName(_ name: String, among routes: [SavedRoute]) -> String {
        let taken = Set(routes.map(\.name))
        guard taken.contains(name) else { return name }
        // Bounded by the number of routes plus one: with n names taken, one of
        // the first n + 1 candidates is always free.
        for suffix in 2...(routes.count + 2) {
            let candidate = "\(name) \(suffix)"
            if !taken.contains(candidate) { return candidate }
        }
        return name
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = routes.firstIndex(where: { $0.id == id }) else { return }
        // Compared against the others, not itself: renaming a route to the name
        // it already has should be a no-op, not a promotion to "Commute 2".
        routes[index].name = Self.uniqueName(trimmed, among: routes.filter { $0.id != id })
        persistRoutes()
    }

    func delete(_ id: UUID) {
        guard let index = routes.firstIndex(where: { $0.id == id }) else { return }
        lastDeleted = DeletedRoute(route: routes[index], index: index)
        routes.remove(at: index)
        persistRoutes()
    }

    /// Puts the last deleted route back.
    @discardableResult
    func undoDelete() -> SavedRoute? {
        guard let deleted = lastDeleted else { return nil }
        lastDeleted = nil
        routes = routes.reinserting(deleted.route, at: deleted.index)
        persistRoutes()
        return deleted.route
    }

    /// Updates the stored overrides for a route that's already saved.
    func updateOverrides(_ overrides: [LimitOverride], for id: UUID) {
        guard let index = routes.firstIndex(where: { $0.id == id }) else { return }
        routes[index].overrides = overrides
        persistRoutes()
    }

    // MARK: Resume

    /// Called as a route plays, so an interrupted drive can be picked up rather
    /// than only after a clean exit.
    func recordProgress(_ state: RouteResumeState) {
        resumable = state
        Self.write(state, to: resumeURL)
    }

    func clearResume() {
        resumable = nil
        // Through the same queue as the writes: deleting the file directly
        // could land before a write already in flight, which would put it
        // straight back.
        let url = resumeURL
        Self.diskQueue.async { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: Files

    private func persistRoutes() {
        Self.write(routes, to: routesURL)
    }

    /// Every write goes here, and none of them happen on the main thread.
    ///
    /// `recordProgress` runs every few seconds for the whole length of a drive,
    /// and the resume state carries the route's entire coordinate list — a
    /// 40 km route resampled for driving is several thousand points. Encoding
    /// that to JSON and writing it while the map, the HUD and the Live Activity
    /// are all animating is a stutter you can feel, and it was being done on the
    /// main thread. `persistRoutes` had the same problem on a colder path,
    /// until "most driven" put it on the one where you press Drive.
    ///
    /// Serial, so writes land in the order they were made, and atomic, so being
    /// killed mid-write leaves the previous file intact rather than half a one.
    private static let diskQueue = DispatchQueue(
        label: "com.chrismack.locus.routestore", qos: .utility
    )

    private static func write<T: Encodable & Sendable>(_ value: T, to url: URL) {
        diskQueue.async {
            guard let data = try? JSONEncoder().encode(value) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Reads stay synchronous: both happen in `init`, and the first render has
    /// to have the answer.
    private static func decode<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
