import CoreLocation
import SwiftUI

/// Plan a route, choose between Apple's alternatives, tune how it's driven, and
/// set it going — in that order, because that's the order you do it in.
struct RoutePlannerSheet: View {
    @ObservedObject var workspace: RouteWorkspace
    var onPlay: () -> Void
    var onImportGPX: () -> Void
    var onExportGPX: () -> Void
    var onFocus: ([CLLocationCoordinate2D]) -> Void

    @EnvironmentObject private var session: SpoofSession
    @Environment(\.dismiss) private var dismiss

    @State private var showDriveSettings = false

    var body: some View {
        NavigationStack {
            Form {
                endpointsSection
                if !workspace.routes.isEmpty { routesSection }
                drivingSection
                playSection
                pathSection
            }
            .navigationTitle("Route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showDriveSettings) {
                DriveSettingsView(
                    profile: $session.drive,
                    mode: session.travelMode,
                    store: session.profiles,
                    onSelect: { session.selectProfile($0) }
                )
            }
        }
    }

    // MARK: - Endpoints

    private var endpointsSection: some View {
        Section {
            endpointRow(
                title: "Start",
                coordinate: workspace.start,
                placeholder: session.simulated == nil ? "Current pin" : "Where you are now"
            ) {
                workspace.start = session.simulated ?? session.pin
            }

            endpointRow(title: "End", coordinate: workspace.end, placeholder: "Drop a pin") {
                workspace.end = session.pin
            }

            if workspace.start != nil || workspace.end != nil {
                Button("Swap ends", systemImage: "arrow.up.arrow.down") {
                    let previous = workspace.start
                    workspace.start = workspace.end
                    workspace.end = previous
                }
            }

            Button {
                Task {
                    if let error = await workspace.buildRoadRoute(
                        fallbackStart: session.simulated ?? session.pin,
                        mode: session.travelMode
                    ) {
                        session.lastError = error
                    } else if let route = workspace.selectedRoute {
                        onFocus(route.coordinates)
                    }
                }
            } label: {
                HStack {
                    Label("Find route on roads", systemImage: "road.lanes")
                    Spacer()
                    if workspace.isBuilding { ProgressView() }
                }
            }
            .disabled(workspace.isBuilding)
        } header: {
            Text("From and to")
        } footer: {
            Text("Routes follow Apple Maps' roads and footpaths for the current travel mode (\(session.travelMode.title.lowercased())).")
        }
    }

    private func endpointRow(
        title: String,
        coordinate: CLLocationCoordinate2D?,
        placeholder: String,
        set: @escaping () -> Void
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(coordinate.map(Self.coordinateText) ?? placeholder)
                    .font(.caption.monospaced())
                    .foregroundStyle(coordinate == nil ? .tertiary : .secondary)
            }
            Spacer()
            Button("Use pin", action: set)
                .buttonStyle(.borderless)
                .font(.subheadline.weight(.semibold))
        }
    }

    // MARK: - Alternatives

    private var routesSection: some View {
        Section("Which way") {
            ForEach(workspace.routes) { route in
                Button {
                    workspace.selectedRouteID = route.id
                    onFocus(route.coordinates)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: workspace.selectedRoute?.id == route.id
                              ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(workspace.selectedRoute?.id == route.id
                                             ? LocusTheme.accent : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(route.name)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(routeSubtitle(route))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func routeSubtitle(_ route: BuiltRoute) -> String {
        var parts = [DriveFormat.distance(route.distance)]
        if route.expectedTravelTime > 1 {
            parts.append("Apple: " + DriveFormat.clock(route.expectedTravelTime))
        }
        if let speed = route.expectedSpeed {
            parts.append("avg " + DriveFormat.speed(speed, unit: session.drive.units))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Driving parameters

    private var drivingSection: some View {
        Section {
            Button {
                showDriveSettings = true
            } label: {
                HStack {
                    Label("Driving parameters", systemImage: "gauge.with.dots.needle.50percent")
                    Spacer()
                    Text(session.drive.summary(for: session.travelMode))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // The one dial worth having without opening the sheet.
            if session.drive.speedSource == .roadLimit {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Speed limit tolerance")
                            .font(.subheadline)
                        Spacer()
                        Text(toleranceLabel)
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(LocusTheme.accent)
                    }
                    Slider(value: $session.drive.speedTolerance, in: -0.30...0.50, step: 0.01)
                        .tint(LocusTheme.accent)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("How it drives")
        }
    }

    private var toleranceLabel: String {
        let percent = Int((session.drive.speedTolerance * 100).rounded())
        return percent > 0 ? "+\(percent)%" : "\(percent)%"
    }

    // MARK: - Play

    private var playSection: some View {
        Section {
            Button(action: onPlay) {
                Label(
                    session.isRouting ? "Restart route" : "Drive this route",
                    systemImage: "play.fill"
                )
            }
            .disabled(!workspace.hasPlayablePath)

            if session.isRouting {
                Button(role: .destructive) {
                    session.cancelRoute()
                } label: {
                    Label("Stop driving", systemImage: "stop.fill")
                }
            }
        } footer: {
            if let summary = workspace.summary {
                Text(summary + estimatedDurationSuffix)
            } else {
                Text("Find a route above, draw one on the map, or import a GPX file.")
            }
        }
    }

    /// How long the playback will actually take, which is not Apple's estimate
    /// once traffic, stops and the time scale are in play.
    private var estimatedDurationSuffix: String {
        guard let route = workspace.selectedRoute, route.distance > 0 else { return "" }
        let profile = session.drive
        let base: CLLocationSpeed = {
            switch profile.speedSource {
            case .fixed: return profile.fixedSpeedMetresPerSecond
            case .travelMode: return session.travelMode.baseSpeed
            case .roadLimit:
                let observed = route.expectedSpeed ?? session.travelMode.baseSpeed
                return observed * (1 + profile.speedTolerance)
            }
        }()
        let effective = max(0.5, base * profile.traffic.meanFactor)
        let seconds = route.distance / effective / max(0.05, profile.timeScale)
        return " · about " + DriveFormat.clock(seconds) + " to play"
    }

    // MARK: - Paths

    private var pathSection: some View {
        Section("Draw & files") {
            Button {
                workspace.adoptRawPath(workspace.drawnPath, named: "Drawn path")
                workspace.drawnPath.removeAll()
                workspace.drawMode = false
            } label: {
                Label("Use the drawn path", systemImage: "pencil.tip")
            }
            .disabled(workspace.drawnPath.count < 2)

            Button(action: onImportGPX) {
                Label("Import GPX", systemImage: "square.and.arrow.down")
            }
            Button(action: onExportGPX) {
                Label("Export GPX", systemImage: "square.and.arrow.up")
            }
            .disabled(!workspace.hasPlayablePath)
        }
    }

    private static func coordinateText(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
    }
}
