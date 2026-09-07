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
    @State private var saving = false
    @State private var draftName = ""
    /// Non-nil while a saved route is being renamed.
    @State private var renamingRouteID: UUID?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            Form {
                if let resumable = session.routeStore.resumable { resumeSection(resumable) }
                endpointsSection
                if !workspace.routes.isEmpty { routesSection }
                drivingSection
                if !workspace.stretches.isEmpty, workspace.previewUsesLimits { limitsSection }
                playSection
                savedSection
                pathSection
            }
            .navigationTitle("Route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if workspace.stops.count >= 2 {
                    ToolbarItem(placement: .primaryAction) {
                        EditButton()
                    }
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

    /// The stops, in order, each one a row you can point at.
    ///
    /// This replaced a fixed Start/End pair whose only way to receive a
    /// coordinate was a "Use pin" button — which meant closing the sheet,
    /// moving the single teleport pin, and coming back. Tapping a row here arms
    /// it instead: the next map tap, search result or pasted coordinate lands
    /// on that stop, with the sheet still open over a live map.
    private var endpointsSection: some View {
        Section {
            ForEach(Array(workspace.stops.enumerated()), id: \.element.id) { index, stop in
                stopRow(index: index, stop: stop)
            }
            .onDelete { offsets in
                for index in offsets.sorted(by: >) where workspace.stops.indices.contains(index) {
                    workspace.removeStop(workspace.stops[index].id)
                }
            }
            .onMove { workspace.moveStops(from: $0, to: $1) }

            addStopRow

            if workspace.stops.count >= 2 {
                Button("Reverse the route", systemImage: "arrow.up.arrow.down") {
                    workspace.reverseStops()
                    buildRoute()
                }
            }

            Button {
                buildRoute()
            } label: {
                HStack {
                    Label(
                        workspace.stops.count > 2 ? "Route through the stops" : "Find route on roads",
                        systemImage: "road.lanes"
                    )
                    Spacer()
                    if workspace.isBuilding { ProgressView() }
                }
            }
            .disabled(workspace.isBuilding || workspace.stops.count < 2)
        } header: {
            Text("Where it goes")
        } footer: {
            Text(endpointsFooter)
        }
    }

    /// Built as a `String` rather than inline in the `Text`: a ternary between
    /// two literals where one interpolates is one of the slower things you can
    /// hand SwiftUI's type-checker.
    private var endpointsFooter: String {
        guard workspace.stops.isEmpty else {
            return "Drag any marker on the map to move it. Reorder or swipe to delete here."
        }
        let mode = session.travelMode.title.lowercased()
        return "Tap a row, then tap the map — or search for a place. "
            + "Routes follow Apple Maps' roads and footpaths for the current travel mode (\(mode))."
    }

    private func stopRow(index: Int, stop: RouteStop) -> some View {
        let focused = workspace.focusedStopID == stop.id
        let role = index == 0
            ? "Start"
            : (index == workspace.stops.count - 1 ? "End" : "Stop")

        return Button {
            // Tapping an armed row disarms it, so this can't become a mode you
            // are stuck in.
            workspace.focusedStopID = focused ? nil : stop.id
        } label: {
            HStack(spacing: 12) {
                Text(RouteStop.label(at: index))
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(stopTint(index)))

                VStack(alignment: .leading, spacing: 2) {
                    Text(stop.name ?? role)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(focused
                         ? "Tap the map or search to set this one"
                         : Self.coordinateText(stop.coordinate))
                        .font(focused ? .caption : .caption.monospaced())
                        .foregroundStyle(focused ? LocusTheme.accent : .secondary)
                }

                Spacer(minLength: 0)

                if focused {
                    Image(systemName: "scope")
                        .foregroundStyle(LocusTheme.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func stopTint(_ index: Int) -> Color {
        if index == 0 { return LocusTheme.statusGood }
        if index == workspace.stops.count - 1 { return LocusTheme.accent }
        return LocusTheme.accentSecondary
    }

    /// Adds a stop and arms it in one tap — the two things you always wanted
    /// together.
    private var addStopRow: some View {
        Menu {
            Button("Where I am now", systemImage: "location.fill") {
                guard let here = session.simulated ?? session.pin ?? session.realCoordinate else {
                    session.lastError = "No position yet — drop a pin, or wait for a GPS fix."
                    return
                }
                arm(workspace.addStop(here, name: "Where you are"))
                buildRoute()
            }
            Button("The current pin", systemImage: "mappin") {
                guard let pin = session.pin else {
                    session.lastError = "Tap the map to drop a pin first."
                    return
                }
                arm(workspace.addStop(pin, name: session.places.address(for: pin)))
                buildRoute()
            }
            .disabled(session.pin == nil)

            if !session.favorites.isEmpty {
                Menu("A saved place") {
                    ForEach(session.favorites) { place in
                        Button(place.name) {
                            arm(workspace.addStop(place.coordinate, name: place.name))
                            buildRoute()
                        }
                    }
                }
            }

            Divider()

            Button("Pick it on the map", systemImage: "hand.tap") {
                // Placed with no coordinate yet: arming it makes the next map
                // tap the answer.
                let anchor = session.simulated ?? session.pin ?? session.realCoordinate
                guard let anchor else {
                    session.lastError = "No position yet — tap the map to drop a pin first."
                    return
                }
                arm(workspace.addStop(anchor))
            }
        } label: {
            Label(
                workspace.stops.count < 2 ? "Add a point" : "Add a stop along the way",
                systemImage: "plus.circle"
            )
        }
    }

    private func arm(_ stop: RouteStop) {
        workspace.focusedStopID = stop.id
    }

    private func buildRoute() {
        guard workspace.stops.count >= 2 else { return }
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

    /// Distance and time, plus how this one differs from the quickest.
    ///
    /// "12.4 km · 18:20 · avg 41 km/h" on three near-identical rows is a
    /// reading exercise. What decides it is "+4 min, −1.2 km" — the comparison,
    /// stated rather than left to be worked out.
    private func routeSubtitle(_ route: BuiltRoute) -> String {
        var parts = [DriveFormat.distance(route.distance)]
        if route.expectedTravelTime > 1 {
            parts.append(DriveFormat.clock(route.expectedTravelTime))
        }
        if let speed = route.expectedSpeed {
            parts.append("avg " + DriveFormat.speed(speed, unit: session.drive.units))
        }
        if let delta = comparison(for: route) {
            parts.append(delta)
        }
        return parts.joined(separator: " · ")
    }

    private func comparison(for route: BuiltRoute) -> String? {
        guard let fastest = workspace.fastestRoute, fastest.id != route.id,
              route.expectedTravelTime > 1 else { return nil }

        let seconds = route.expectedTravelTime - fastest.expectedTravelTime
        let metres = route.distance - fastest.distance

        var parts: [String] = []
        if abs(seconds) >= 30 {
            let minutes = Int((abs(seconds) / 60).rounded())
            parts.append("\(seconds > 0 ? "+" : "−")\(max(1, minutes)) min")
        }
        if abs(metres) >= 100 {
            parts.append("\(metres > 0 ? "+" : "−")\(DriveFormat.distance(abs(metres)))")
        }
        return parts.isEmpty ? "about the same" : parts.joined(separator: ", ")
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
            case .recorded:
                // The recording's own average is exactly this estimate, and it
                // is the one number here that isn't a guess.
                return route.expectedSpeed ?? session.travelMode.baseSpeed
            }
        }()
        let effective = max(0.5, base * profile.traffic.meanFactor)
        let seconds = route.distance / effective / max(0.05, profile.timeScale)
        return " · about " + DriveFormat.clock(seconds) + " to play"
    }

    // MARK: - Resume

    /// A drive that was interrupted rather than finished.
    ///
    /// The progress file is written every few seconds while a route plays, so
    /// this survives a crash or a swipe-away — the two cases where losing forty
    /// minutes of a route was most annoying.
    private func resumeSection(_ state: RouteResumeState) -> some View {
        Section {
            Button {
                session.resumeSavedRoute(pairing: PairingStore.shared)
                dismiss()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(LocusTheme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Resume “\(state.routeName)”")
                            .foregroundStyle(.primary)
                        Text("\(DriveFormat.distance(state.travelled)) of \(DriveFormat.distance(state.distance)) done")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button("Discard it", role: .destructive) {
                session.routeStore.clearResume()
            }
        } header: {
            Text("Unfinished drive")
        }
    }

    // MARK: - Limits

    /// The route's estimated limits, stretch by stretch, each correctable.
    ///
    /// Correcting from a list rather than by tapping the map is deliberate: a
    /// 6-point line is a hard target on a phone, and this also shows the whole
    /// route's estimate at once, which is where a wrong one is easiest to spot.
    private var limitsSection: some View {
        Section {
            ForEach(workspace.stretches) { stretch in
                LimitStretchRow(
                    stretch: stretch,
                    unit: session.drive.units,
                    override: workspace.override(for: stretch),
                    onChange: { workspace.setOverride($0, for: stretch) }
                )
            }

            if !workspace.overrides.isEmpty {
                Button("Clear \(workspace.overrides.count) correction\(workspace.overrides.count == 1 ? "" : "s")", role: .destructive) {
                    workspace.clearOverrides()
                }
            }
        } header: {
            Text("Speed limits along the way")
        } footer: {
            Text("Estimated from the road's shape and the pace Apple expects — MapKit publishes no posted limits. Where it's wrong, set it here and the drive uses your number instead. Colours on the map match.")
        }
    }

    // MARK: - Saved routes

    private var savedSection: some View {
        Section {
            Button {
                draftName = workspace.selectedRoute?.name ?? "Route"
                saving = true
            } label: {
                Label(
                    workspace.savedRouteID == nil ? "Save this route" : "Save a copy",
                    systemImage: "square.and.arrow.down.on.square"
                )
            }
            .disabled(workspace.selectedRoute == nil)

            if let id = workspace.savedRouteID, !workspace.overrides.isEmpty {
                Button {
                    session.routeStore.updateOverrides(workspace.overrides, for: id)
                } label: {
                    Label("Update its saved corrections", systemImage: "arrow.triangle.2.circlepath")
                }
            }

            ForEach(session.routeStore.routes) { saved in
                Button {
                    workspace.adopt(saved: saved)
                    onFocus(saved.coordinates.clLocations)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(saved.name).foregroundStyle(.primary)
                            Text(savedSubtitle(saved))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if workspace.savedRouteID == saved.id {
                            Image(systemName: "checkmark")
                                .foregroundStyle(LocusTheme.accent)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        session.routeStore.delete(saved.id)
                    } label: {
                        Label("Delete", systemImage: "trash.fill")
                    }
                    // Profiles could be renamed and routes couldn't, so a
                    // commute saved as "Route" stayed "Route" — or had to be
                    // deleted and rebuilt to get a name that meant something.
                    Button {
                        renamingRouteID = saved.id
                        renameText = saved.name
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    .tint(.gray)
                }
            }
        } header: {
            Text("Saved routes")
        } footer: {
            if session.routeStore.routes.isEmpty {
                Text("A commute you drive every morning is worth keeping — corrections and all.")
            }
        }
        .alert("Save route", isPresented: $saving) {
            TextField("Name", text: $draftName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                guard let route = workspace.selectedRoute else { return }
                session.routeStore.save(route, named: draftName, overrides: workspace.overrides)
            }
        }
        .alert("Rename route", isPresented: Binding(
            get: { renamingRouteID != nil },
            set: { if !$0 { renamingRouteID = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renamingRouteID = nil }
            Button("Save") {
                if let id = renamingRouteID {
                    session.routeStore.rename(id, to: renameText)
                }
                renamingRouteID = nil
            }
        }
    }

    private func savedSubtitle(_ saved: SavedRoute) -> String {
        var parts = [DriveFormat.distance(saved.distance)]
        if saved.recordedTimes != nil {
            parts.append("recorded pace")
        }
        if !saved.overrides.isEmpty {
            parts.append("\(saved.overrides.count) correction\(saved.overrides.count == 1 ? "" : "s")")
        }
        parts.append(saved.createdAt.formatted(date: .abbreviated, time: .omitted))
        return parts.joined(separator: " · ")
    }

    // MARK: - Paths

    private var pathSection: some View {
        Section {
            Button {
                workspace.adoptRawPath(workspace.drawnPath, named: "Drawn path")
                workspace.drawnPath.removeAll()
                workspace.drawMode = false
            } label: {
                Label("Use the drawn path as-is", systemImage: "pencil.tip")
            }
            .disabled(workspace.drawnPath.count < 2)

            // A finger-drawn line cuts corners, crosses buildings and wanders
            // off the carriageway; driving it produces a trace no phone has
            // ever produced. This keeps the shape and puts it on real roads.
            Button {
                Task {
                    if let error = await workspace.snapDrawnPath(mode: session.travelMode) {
                        session.lastError = error
                    } else if let route = workspace.selectedRoute {
                        onFocus(route.coordinates)
                    }
                }
            } label: {
                HStack {
                    Label("Snap the drawn path to roads", systemImage: "point.topleft.down.to.point.bottomright.curvepath.fill")
                    Spacer()
                    if workspace.isBuilding { ProgressView() }
                }
            }
            .disabled(workspace.drawnPath.count < 2 || workspace.isBuilding)

            Button(action: onImportGPX) {
                Label("Import GPX", systemImage: "square.and.arrow.down")
            }
            Button(action: onExportGPX) {
                Label("Export GPX", systemImage: "square.and.arrow.up")
            }
            .disabled(!workspace.hasPlayablePath)
        } header: {
            Text("Draw & files")
        } footer: {
            if workspace.drawnPath.count >= 2 {
                Text("Snapping routes between points taken along what you drew, so the line follows roads that exist.")
            }
        }
    }

    private static func coordinateText(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
    }
}
