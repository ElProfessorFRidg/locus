import CoreLocation
import Foundation
import MapKit

/// The route being put together on the map: endpoints, whatever Apple returned
/// for them, anything drawn or imported by hand, and the corrections made to it.
///
/// Held by `MapHomeView` and handed to the planner sheet, so the sheet edits the
/// same state the map is drawing rather than a copy of it.
@MainActor
final class RouteWorkspace: ObservableObject {
    @Published var start: CLLocationCoordinate2D?
    @Published var end: CLLocationCoordinate2D?

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

    var selectedRoute: BuiltRoute? {
        guard let selectedRouteID else { return routes.first }
        return routes.first { $0.id == selectedRouteID } ?? routes.first
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

    // MARK: - Selection

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

    func buildRoadRoute(
        fallbackStart: CLLocationCoordinate2D?,
        mode: TravelMode
    ) async -> String? {
        guard let origin = start ?? fallbackStart else {
            return "Set a route start — tap the map, then “Use pin as start”."
        }
        guard let destination = end else {
            return "Set a route end — drop a pin, then “Use pin as end”."
        }

        isBuilding = true
        defer { isBuilding = false }

        do {
            let built = try await RouteBuilder.roadRoutes(
                from: origin,
                to: destination,
                mode: mode
            )
            adopt(built)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
