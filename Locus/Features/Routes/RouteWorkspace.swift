import CoreLocation
import Foundation
import MapKit

/// One point a route passes through: its start, its end, or somewhere between.
///
/// Modelled as a list rather than a `start`/`end` pair because a real journey
/// has a school and a petrol station in it, and because two fixed fields forced
/// the planner into "set one, close, move the pin, reopen, set the other".
struct RouteStop: Identifiable, Equatable {
    let id: UUID
    var coordinate: CLLocationCoordinate2D
    /// Resolved address or the name it was searched under. Coordinates tell you
    /// nothing about whether the stop is the right one.
    var name: String?

    init(coordinate: CLLocationCoordinate2D, name: String? = nil, id: UUID = UUID()) {
        self.id = id
        self.coordinate = coordinate
        self.name = name
    }

    static func == (lhs: RouteStop, rhs: RouteStop) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
    }

    /// A, B, C… — short enough for a map marker, and the labels people already
    /// use when they talk about a route.
    static func label(at index: Int) -> String {
        guard index >= 0, index < 26 else { return "\(index + 1)" }
        return String(UnicodeScalar(UInt8(65 + index)))
    }
}

/// The route being put together on the map: its stops, whatever Apple returned
/// for them, anything drawn or imported by hand, and the corrections made to it.
///
/// Held by `MapHomeView` and handed to the planner sheet, so the sheet edits the
/// same state the map is drawing rather than a copy of it.
@MainActor
final class RouteWorkspace: ObservableObject {
    /// Ordered: first is the origin, last is the destination, the rest are stops
    /// along the way.
    @Published var stops: [RouteStop] = []

    /// Which stop a search result, a map tap or a favourite lands on.
    ///
    /// This is what removes the close-the-sheet-and-come-back loop: the planner
    /// says which stop it is waiting for, and the map fills that one in.
    @Published var focusedStopID: UUID?

    /// Every alternative Apple offered, newest search first.
    @Published var routes: [BuiltRoute] = []
    @Published var selectedRouteID: UUID?

    /// A path traced on the map with the pencil tool.
    @Published var drawnPath: [CLLocationCoordinate2D] = []
    @Published var drawMode = false

    @Published var isBuilding = false

    /// Hand corrections to the estimated limits, for the selected route.
    @Published private(set) var overrides: [LimitOverride] = []

    /// The selected route split into stretches by limit — what the coloured
    /// overlay draws and what the corrections list edits.
    @Published private(set) var stretches: [RoutePlan.Stretch] = []
    @Published private(set) var previewUsesLimits = false

    /// Set when the current route came from the saved list, so corrections can
    /// be written back to it.
    @Published private(set) var savedRouteID: UUID?

    // MARK: - Stops

    var start: CLLocationCoordinate2D? { stops.first?.coordinate }
    var end: CLLocationCoordinate2D? { stops.count >= 2 ? stops[stops.count - 1].coordinate : nil }
    var canRoute: Bool { stops.count >= 2 }

    /// The stop the next map tap or search result fills in.
    ///
    /// Falls back to the first empty slot, then to appending — so tapping the
    /// map twice on a fresh route gives you a start and an end without anyone
    /// having to explain the rule.
    var focusedStop: RouteStop? {
        guard let focusedStopID else { return nil }
        return stops.first { $0.id == focusedStopID }
    }

    func index(of id: UUID) -> Int? { stops.firstIndex { $0.id == id } }

    /// Puts a coordinate into the focused stop, or adds one at the end.
    @discardableResult
    func place(_ coordinate: CLLocationCoordinate2D, name: String? = nil) -> RouteStop {
        if let focusedStopID, let index = index(of: focusedStopID) {
            stops[index].coordinate = coordinate
            stops[index].name = name
            advanceFocus(after: index)
            invalidateRoutes()
            return stops[index]
        }

        let stop = RouteStop(coordinate: coordinate, name: name)
        stops.append(stop)
        // Two stops is a route; stop asking for more until someone says so.
        focusedStopID = stops.count < 2 ? stop.id : nil
        invalidateRoutes()
        return stop
    }

    @discardableResult
    func addStop(_ coordinate: CLLocationCoordinate2D, name: String? = nil) -> RouteStop {
        let stop = RouteStop(coordinate: coordinate, name: name)
        // A new stop belongs before the destination: "add a stop" means on the
        // way, not instead of where you were going.
        if stops.count >= 2 {
            stops.insert(stop, at: stops.count - 1)
        } else {
            stops.append(stop)
        }
        invalidateRoutes()
        return stop
    }

    func setStop(_ id: UUID, to coordinate: CLLocationCoordinate2D, name: String? = nil) {
        guard let index = index(of: id) else { return }
        stops[index].coordinate = coordinate
        if let name { stops[index].name = name }
        invalidateRoutes()
    }

    /// Moves a stop without discarding the route — used while dragging, where
    /// throwing the drawn line away on every frame would make the map blink.
    func dragStop(_ id: UUID, to coordinate: CLLocationCoordinate2D) {
        guard let index = index(of: id) else { return }
        stops[index].coordinate = coordinate
        stops[index].name = nil
    }

    func removeStop(_ id: UUID) {
        stops.removeAll { $0.id == id }
        if focusedStopID == id { focusedStopID = nil }
        invalidateRoutes()
    }

    func moveStops(from offsets: IndexSet, to destination: Int) {
        stops.move(fromOffsets: offsets, toOffset: destination)
        invalidateRoutes()
    }

    func clearStops() {
        stops = []
        focusedStopID = nil
        invalidateRoutes()
    }

    /// There and back again, which is most of what "swap" was ever used for.
    func reverseStops() {
        stops.reverse()
        invalidateRoutes()
    }

    /// Names a stop from a reverse geocode, without disturbing anything else.
    func nameStop(_ id: UUID, _ name: String) {
        guard let index = index(of: id), stops[index].name != name else { return }
        stops[index].name = name
    }

    /// After filling a stop in, ask for the next one that still needs a point —
    /// so tap, tap gives you A and B rather than A twice.
    private func advanceFocus(after index: Int) {
        if index == 0, stops.count < 2 {
            let stop = RouteStop(coordinate: stops[0].coordinate)
            stops.append(stop)
            focusedStopID = stop.id
        } else {
            focusedStopID = nil
        }
    }

    /// The stops moved, so whatever Apple returned for the old ones is stale.
    /// Kept as a separate step from clearing the drawn path: a drawn line is
    /// independent of the stops.
    private func invalidateRoutes() {
        guard !routes.isEmpty || savedRouteID != nil else { return }
        routes = []
        selectedRouteID = nil
        savedRouteID = nil
        overrides = []
        stretches = []
        previewUsesLimits = false
    }

    // MARK: - Selection

    var selectedRoute: BuiltRoute? {
        guard let selectedRouteID else { return routes.first }
        return routes.first { $0.id == selectedRouteID } ?? routes.first
    }

    /// The quickest of the alternatives, which is what the others are compared
    /// against in the list.
    var fastestRoute: BuiltRoute? {
        routes.filter { $0.expectedTravelTime > 1 }.min { $0.expectedTravelTime < $1.expectedTravelTime }
    }

    /// What "play" would drive: the chosen road route, or the drawn path when
    /// there is no route.
    var activeCoordinates: [CLLocationCoordinate2D] {
        if let selectedRoute, selectedRoute.coordinates.count > 1 {
            return selectedRoute.coordinates
        }
        return drawnPath
    }

    /// Apple's expected average speed for the active route — the only real
    /// signal the limit estimator has. Nil for a drawn or imported path.
    var activeExpectedSpeed: CLLocationSpeed? {
        guard let selectedRoute, selectedRoute.coordinates.count > 1 else { return nil }
        return selectedRoute.expectedSpeed
    }

    var hasPlayablePath: Bool { activeCoordinates.count >= 2 }

    var summary: String? {
        if let route = selectedRoute, route.coordinates.count > 1 {
            return "\(DriveFormat.distance(route.distance)) · \(route.name)"
        }
        if drawnPath.count > 1 {
            return "Drawn path · \(drawnPath.count) points"
        }
        return nil
    }

    func clearRoutes() {
        routes = []
        selectedRouteID = nil
        savedRouteID = nil
        overrides = []
        stretches = []
    }

    func adopt(_ built: [BuiltRoute]) {
        routes = built
        selectedRouteID = built.first?.id
        savedRouteID = nil
        overrides = []
    }

    /// Replaces the road route with an imported or drawn path so the rest of the
    /// app has one place to look for "the route".
    ///
    /// - Parameter recordedTimes: timestamps from a GPX track, one per
    ///   coordinate. When present they give both a real `expectedTravelTime`
    ///   and the per-point pace that "As recorded" replays.
    func adoptRawPath(
        _ coordinates: [CLLocationCoordinate2D],
        named name: String,
        recordedTimes: [Date]? = nil
    ) {
        guard coordinates.count > 1 else { return }
        var distance: CLLocationDistance = 0
        for (a, b) in zip(coordinates, coordinates.dropFirst()) {
            distance += Geo.distance(a, b)
        }

        // expectedTravelTime 0 marks "no timing data", which is what makes
        // `expectedSpeed` nil and sends the estimator back to the travel mode.
        var duration: TimeInterval = 0
        if let recordedTimes, recordedTimes.count == coordinates.count,
           let first = recordedTimes.first, let last = recordedTimes.last {
            duration = max(0, last.timeIntervalSince(first))
        }

        routes = [BuiltRoute(
            name: name,
            coordinates: coordinates,
            distance: distance,
            expectedTravelTime: duration,
            recordedTimes: duration > 1 ? recordedTimes : nil
        )]
        selectedRouteID = routes.first?.id
        savedRouteID = nil
        overrides = []
        // The stops describe a road route; an imported track isn't one, and
        // leaving them on the map would claim this path runs between them.
        stops = []
        focusedStopID = nil
    }

    /// True when the loaded route carries timestamps worth replaying.
    var hasRecordedPace: Bool { selectedRoute?.recordedTimes != nil }

    /// Speed by distance along the recorded track, or nil when there isn't one.
    var recordedSpeedSampler: ((CLLocationDistance) -> CLLocationSpeed)? {
        selectedRoute?.recordedSpeedSampler()
    }

    func adopt(saved: SavedRoute) {
        routes = [saved.built]
        selectedRouteID = routes.first?.id
        savedRouteID = saved.id
        overrides = saved.overrides
        drawnPath.removeAll()
        // A saved route carries its shape, not its stops — pin the ends so the
        // map still shows where it runs between and either end can be dragged.
        if let first = saved.coordinates.first, let last = saved.coordinates.last {
            stops = [
                RouteStop(coordinate: first.clLocation, name: "\(saved.name) start"),
                RouteStop(coordinate: last.clLocation, name: "\(saved.name) end"),
            ]
        }
        focusedStopID = nil
    }

    // MARK: - Preview

    /// Rebuilds the stretch breakdown for the selected route.
    ///
    /// Runs the same planner the drive uses, so what the map colours and what
    /// the car will actually do are the same numbers rather than two estimates
    /// that can disagree.
    func refreshPreview(profile: DriveProfile, mode: TravelMode) {
        let coordinates = activeCoordinates
        guard coordinates.count > 1 else {
            stretches = []
            previewUsesLimits = false
            return
        }

        let plan = RouteSimulator.plan(
            coordinates: coordinates,
            profile: profile,
            mode: mode,
            routeExpectedSpeed: activeExpectedSpeed,
            overrides: overrides,
            recordedSpeed: recordedSpeedSampler
        )
        stretches = plan.stretches()
        previewUsesLimits = plan.usesEstimatedLimits
    }

    // MARK: - Overrides

    /// Corrects the limit over one stretch. Passing `nil` removes the correction
    /// and hands the stretch back to the estimator.
    func setOverride(_ limit: CLLocationSpeed?, for stretch: RoutePlan.Stretch) {
        overrides.removeAll { $0.startDistance == stretch.startDistance && $0.endDistance == stretch.endDistance }
        if let limit {
            overrides.append(LimitOverride(
                startDistance: stretch.startDistance,
                endDistance: stretch.endDistance,
                limit: limit
            ))
        }
    }

    func override(for stretch: RoutePlan.Stretch) -> LimitOverride? {
        overrides.first { $0.startDistance == stretch.startDistance && $0.endDistance == stretch.endDistance }
    }

    func clearOverrides() {
        overrides = []
    }

    // MARK: - Routing

    /// Builds the road route through every stop.
    ///
    /// - Parameter fallbackStart: where you are, used when no stops have been
    ///   placed yet. Starting from your current position is what almost every
    ///   route wants, and it used to have to be set by hand.
    func buildRoadRoute(
        fallbackStart: CLLocationCoordinate2D?,
        mode: TravelMode
    ) async -> String? {
        if stops.isEmpty, let fallbackStart {
            stops = [RouteStop(coordinate: fallbackStart, name: "Where you are")]
        }
        guard stops.count >= 2 else {
            return stops.isEmpty
                ? "Tap the map to set where the route starts and ends."
                : "Set where the route ends — tap the map, or search for a place."
        }

        isBuilding = true
        defer { isBuilding = false }

        do {
            let built = try await RouteBuilder.roadRoute(
                through: stops.map(\.coordinate),
                mode: mode
            )
            adopt(built)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Turns the current route round so it can be driven back.
    ///
    /// The commonest thing to want after arriving. Corrections are dropped
    /// rather than carried: they are keyed by distance along the route, and
    /// distance 400 m going one way is not distance 400 m coming back.
    func reverseSelectedRoute() {
        guard let route = selectedRoute, route.coordinates.count > 1 else { return }
        let back = BuiltRoute(
            name: route.name.hasSuffix(", back") ? String(route.name.dropLast(6)) : "\(route.name), back",
            coordinates: Array(route.coordinates.reversed()),
            distance: route.distance,
            expectedTravelTime: route.expectedTravelTime,
            // A recorded pace played backwards is not a recording of anything.
            recordedTimes: nil
        )
        routes = [back]
        selectedRouteID = back.id
        savedRouteID = nil
        overrides = []
        stops.reverse()
    }

    /// Puts the drawn path onto real roads, keeping its shape.
    func snapDrawnPath(mode: TravelMode) async -> String? {
        guard drawnPath.count >= 2 else { return "Draw a path on the map first." }

        isBuilding = true
        defer { isBuilding = false }

        do {
            let route = try await RouteBuilder.snapToRoads(path: drawnPath, mode: mode)
            adopt([route])
            drawnPath.removeAll()
            drawMode = false
            if let first = route.coordinates.first, let last = route.coordinates.last {
                stops = [
                    RouteStop(coordinate: first),
                    RouteStop(coordinate: last),
                ]
                focusedStopID = nil
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

extension SpoofSession {
    /// Drives whatever the workspace is currently holding.
    ///
    /// Lives here rather than in the map view because three places now start a
    /// drive — the planner, the map, and the trip summary's "again" and "back"
    /// — and each one assembling the same six arguments is three chances to
    /// forget the recorded pace.
    func driveRoute(_ workspace: RouteWorkspace, pairing: PairingStore) {
        guard workspace.hasPlayablePath else {
            lastError = "Find a route, draw one, or import a GPX file first."
            return
        }
        startRoute(
            workspace.activeCoordinates,
            pairing: pairing,
            expectedSpeed: workspace.activeExpectedSpeed,
            name: workspace.selectedRoute?.name ?? "Route",
            overrides: workspace.overrides,
            recordedSpeed: workspace.recordedSpeedSampler,
            recordedTimes: workspace.selectedRoute?.recordedTimes
        )
    }
}
