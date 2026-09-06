import CoreLocation
import Foundation
import MapKit

/// The route being put together on the map: endpoints, whatever Apple returned
/// for them, and anything drawn or imported by hand.
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

    func clearRoutes() {
        routes = []
        selectedRouteID = nil
    }

    func adopt(_ built: [BuiltRoute]) {
        routes = built
        selectedRouteID = built.first?.id
    }

    /// Replaces the road route with an imported or drawn path so the rest of the
    /// app has one place to look for "the route".
    func adoptRawPath(_ coordinates: [CLLocationCoordinate2D], named name: String) {
        guard coordinates.count > 1 else { return }
        var distance: CLLocationDistance = 0
        for (a, b) in zip(coordinates, coordinates.dropFirst()) {
            distance += Geo.distance(a, b)
        }
        // expectedTravelTime 0 marks "no timing data", which is what makes
        // `expectedSpeed` nil and sends the estimator back to the travel mode.
        routes = [BuiltRoute(
            name: name,
            coordinates: coordinates,
            distance: distance,
            expectedTravelTime: 0
        )]
        selectedRouteID = routes.first?.id
    }

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
