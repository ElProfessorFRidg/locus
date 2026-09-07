import MapKit
import SwiftUI

struct MapHomeView: View {
    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var pairing: PairingStore

    /// Owned by `RootView`: the bottom chrome acts on it too.
    @ObservedObject var workspace: RouteWorkspace

    @StateObject private var search = PlaceSearchCompleter()

    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool
    @State private var showRouteSheet = false
    /// Driven rather than free so arming a stop can drop the sheet off the map
    /// it is asking you to tap.
    @State private var routeDetent: PresentationDetent = .medium
    @State private var showGPXImporter = false
    @State private var pinSelected = false
    @State private var isDraggingPin = false
    @State private var suppressNextMapTap = false
    /// Set when the pin comes from search / a named place so starring keeps the title.
    @State private var pinPlaceName: String?
    /// Keeps the camera on the car while a route plays.
    @State private var followsDrive = true
    /// Set after importing a GPX that carried timestamps, so the offer to
    /// replay it at its recorded pace appears where the import happened.
    @State private var importedPaceHint: String?
    /// Crosshair placement and metre-at-a-time nudging.
    @State private var precisionMode = false
    @State private var nudgeStep: Double = 5
    /// Where the crosshair is pointing. Only tracked while precision mode is
    /// on — otherwise every frame of every pan would redraw this view.
    @State private var mapCenter: CLLocationCoordinate2D?
    /// Roughly how much ground the map is showing, used to size tap targets
    /// that have to mean the same thing at every zoom.
    @State private var mapSpanMetres: CLLocationDistance = 2000
    /// The stop being dragged, so the map knows not to treat the gesture as a
    /// tap and the marker knows to grow.
    @State private var draggingStopID: UUID?
    /// Set while a stop is waiting for a point, which turns the next map tap
    /// into "put it here" rather than "move the teleport pin".
    @State private var routePlacementHint: String?

    /// Coalesces preview rebuilds — see `refreshPreview`.
    @State private var previewTask: Task<Void, Never>?

    @Namespace private var chromeGlass

    private var mapStyle: MapStyle {
        switch session.mapStyleIndex {
        case 1: return .hybrid(elevation: .realistic)
        case 2: return .imagery(elevation: .realistic)
        default: return .standard(elevation: .realistic)
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Keep Map inside the safe layout bounds so MapProxy.convert matches
            // finger position. Ignoring the safe area makes the tiles full-bleed but
            // shifts convert() upward by ~status-bar height.
            MapReader { proxy in
                Map(position: $position) {
                    UserAnnotation()
                    pinAnnotation(proxy: proxy)
                    spoofAnnotation
                    routeOverlays
                    stopAnnotations(proxy: proxy)
                }
                .mapStyle(mapStyle)
                // Declaring the two we want replaces the default set, so the
                // built-in locate button stays gone (Locus has its own) while a
                // rotated map still gets a compass to straighten it with.
                .mapControls {
                    MapCompass()
                    MapScaleView()
                }
                .mapControlVisibility(.automatic)
                .onMapCameraChange(frequency: precisionMode ? .continuous : .onEnd) { context in
                    mapCenter = context.region.center
                    // A degree of latitude is ~111 km everywhere, which is all
                    // the precision this needs: it sizes a tap target, not a
                    // measurement.
                    mapSpanMetres = max(50, context.region.span.latitudeDelta * 111_000)
                    // Rank completions against what you're looking at. Without
                    // this the completer searches the whole world, so "Gare"
                    // over Lyon offered stations anywhere but Lyon.
                    search.region = context.region
                }
                .onTapGesture { point in
                    // A tap on the map while the keyboard is up is a tap to put
                    // the keyboard away. Dropping a pin under the thumb at the
                    // same time moved the place you had just searched for, at
                    // the exact moment you went to look at it.
                    let wasTyping = searchFocused
                    searchFocused = false
                    guard !wasTyping, !suppressNextMapTap, !isDraggingPin,
                          draggingStopID == nil else { return }
                    // In precision mode the map is the thing being moved, not
                    // the pin: a tap is part of aiming, not a placement.
                    guard !precisionMode else { return }
                    pinSelected = false
                    handleMapTap(at: point, proxy: proxy)
                }
            }
            .background(Color.black.ignoresSafeArea())

            if precisionMode {
                // Filling the stack is what centres it: the crosshair has to sit
                // on the middle of the map, which is what the camera reports.
                MapCrosshair()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }

            topChrome
        }
        .onAppear {
            session.startLocationUpdates()
            refreshPreview()
        }
        .onChange(of: session.pin?.latitude) { _, newValue in
            if newValue == nil { pinSelected = false }
        }
        // The preview is the planner's own output, so it has to be rebuilt
        // whenever anything the planner reads changes — the route, the profile,
        // the mode, or a hand correction.
        .onChange(of: workspace.selectedRouteID) { _, _ in refreshPreview() }
        .onChange(of: workspace.overrides) { _, _ in refreshPreview() }
        .onChange(of: session.drive) { _, _ in refreshPreview() }
        .onChange(of: session.travelMode) { _, _ in refreshPreview() }
        .onChange(of: session.telemetry?.distanceTravelled) { _, _ in
            guard followsDrive, let simulated = session.simulated, session.isRouting else { return }
            position = .region(MKCoordinateRegion(
                center: simulated,
                latitudinalMeters: 500,
                longitudinalMeters: 500
            ))
        }
        .onReceive(NotificationCenter.default.publisher(for: .locusImportGPX)) { note in
            guard let url = note.object as? URL else { return }
            importGPX(url)
        }
        .onReceive(NotificationCenter.default.publisher(for: .locusOpenLocation)) { note in
            guard let link = note.object as? LocusLocationLink else { return }
            go(to: link.match)
            if link.teleports {
                session.teleport(to: link.match.coordinate, pairing: pairing)
            }
        }
        .fileImporter(
            isPresented: $showGPXImporter,
            allowedContentTypes: [.xml, .data],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                importGPX(url)
            }
        }
        .sheet(isPresented: $showRouteSheet) {
            RoutePlannerSheet(
                workspace: workspace,
                onPlay: playRoute,
                onImportGPX: { showGPXImporter = true },
                onExportGPX: exportGPX,
                onFocus: focus(on:)
            )
            .presentationDetents([.medium, .large], selection: $routeDetent)
            // The map underneath stays live at the medium detent. Without this
            // the planner is a modal over the thing it is planning on: you set
            // a stop, close the sheet to look, and reopen it — which is the
            // loop this whole rework exists to remove.
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            .environmentObject(session)
            // The corrections list is the preview's output, so make sure it
            // exists before the sheet that edits it opens.
            .onAppear { refreshPreview() }
            .onChange(of: workspace.focusedStopID) { _, id in
                // Arming a stop means "the next map tap is this one", and at
                // the large detent the sheet covers the map that tap has to
                // land on. The row says "Tap the map or search to set this
                // one" — so get out of the way of the map.
                if id != nil, routeDetent == .large { routeDetent = .medium }
            }
        }
    }

    // MARK: - Map content

    @MapContentBuilder
    private func pinAnnotation(proxy: MapProxy) -> some MapContent {
        if let pin = session.pin {
            Annotation("", coordinate: pin, anchor: .bottom) {
                MapDropPin(
                    selected: pinSelected,
                    isDragging: isDraggingPin,
                    onSelect: {
                        searchFocused = false
                        suppressNextMapTap = true
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                            pinSelected.toggle()
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            suppressNextMapTap = false
                        }
                    },
                    onRemove: {
                        suppressNextMapTap = true
                        withAnimation {
                            session.setPin(nil)
                            pinSelected = false
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            suppressNextMapTap = false
                        }
                    },
                    onDragBegan: {
                        searchFocused = false
                        suppressNextMapTap = true
                        pinSelected = false
                        isDraggingPin = true
                    },
                    onDragMoved: { globalPoint in
                        if let coord = proxy.convert(globalPoint, from: .global) {
                            session.setPin(coord)
                        }
                    },
                    onDragEnded: {
                        isDraggingPin = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            suppressNextMapTap = false
                        }
                    }
                )
            }
        }
    }

    /// One lettered marker per stop, each draggable.
    @MapContentBuilder
    private func stopAnnotations(proxy: MapProxy) -> some MapContent {
        ForEach(Array(workspace.stops.enumerated()), id: \.element.id) { index, stop in
            Annotation("", coordinate: stop.coordinate, anchor: .bottom) {
                stopMarker(index: index, stop: stop, proxy: proxy)
            }
        }
    }

    /// Built outside the `MapContentBuilder`: eight arguments, five of them
    /// multi-statement closures, inline in a result builder is the shape that
    /// sends Swift's type-checker away for several minutes.
    private func stopMarker(index: Int, stop: RouteStop, proxy: MapProxy) -> some View {
        RouteStopMarker(
            label: RouteStop.label(at: index),
            role: role(at: index),
            isFocused: workspace.focusedStopID == stop.id,
            isDragging: draggingStopID == stop.id,
            name: stop.name,
            onTap: { focusStop(stop.id) },
            onRemove: { removeStop(stop.id) },
            onDragBegan: {
                searchFocused = false
                suppressNextMapTap = true
                draggingStopID = stop.id
            },
            onDragMoved: { globalPoint in
                if let coordinate = proxy.convert(globalPoint, from: .global) {
                    workspace.dragStop(stop.id, to: coordinate)
                }
            },
            onDragEnded: { finishStopDrag() }
        )
    }

    /// Tapping a stop asks for it: the next tap on the map moves this one
    /// rather than adding another. Tapping it again lets go.
    private func focusStop(_ id: UUID) {
        suppressNextMapTap = true
        withAnimation(.snappy) {
            workspace.focusedStopID = workspace.focusedStopID == id ? nil : id
        }
        updatePlacementHint()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            suppressNextMapTap = false
        }
    }

    private func removeStop(_ id: UUID) {
        suppressNextMapTap = true
        withAnimation { workspace.removeStop(id) }
        updatePlacementHint()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            suppressNextMapTap = false
        }
    }

    private func finishStopDrag() {
        draggingStopID = nil
        // Rebuild once, on release. Routing on every frame of a drag would be a
        // request per pixel, and Apple would throttle it into uselessness.
        rebuildRouteIfPossible()
        resolveStopNames()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            suppressNextMapTap = false
        }
    }

    private func role(at index: Int) -> RouteStopMarker.Role {
        if index == 0 { return .start }
        if index == workspace.stops.count - 1 { return .end }
        return .waypoint
    }

    @MapContentBuilder
    private var spoofAnnotation: some MapContent {
        if let sim = session.simulated {
            Annotation("Spoof", coordinate: sim) {
                SpoofMarker(
                    course: session.telemetry?.course,
                    isMoving: session.isRouting && !(session.telemetry?.isStopped ?? true)
                )
            }
        }
    }

    /// Alternatives are drawn faintly underneath so picking between them is a
    /// map decision, not a list decision.
    @MapContentBuilder
    private var routeOverlays: some MapContent {
        ForEach(workspace.routes) { route in
            if route.id != workspace.selectedRoute?.id, route.coordinates.count > 1 {
                MapPolyline(coordinates: route.coordinates)
                    .stroke(Color.primary.opacity(0.28), lineWidth: 4)
            }
        }

        if let selected = workspace.selectedRoute, selected.coordinates.count > 1 {
            if workspace.previewUsesLimits, !workspace.stretches.isEmpty {
                // One polyline per stretch, coloured by the limit it carries.
                // The estimate is the thing the whole drive is keyed to, so it
                // is worth being able to see it before committing forty minutes
                // to it — and worth spotting a wrong one on the map rather than
                // halfway down a motorway.
                ForEach(workspace.stretches) { stretch in
                    MapPolyline(coordinates: stretch.coordinates)
                        .stroke(
                            LocusTheme.speedColor(forLimit: stretch.limit, unit: session.drive.units),
                            style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round)
                        )
                }
            } else {
                MapPolyline(coordinates: selected.coordinates)
                    .stroke(LocusTheme.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            }
        }

        if workspace.drawnPath.count > 1 {
            MapPolyline(coordinates: workspace.drawnPath)
                .stroke(LocusTheme.accentSecondary, style: StrokeStyle(lineWidth: 4, dash: [6, 4]))
        }
    }

    /// What a tap on the map means, in the order the meanings win.
    ///
    /// Drawing takes it, then a stop that is waiting for a point, then an
    /// alternative route close enough to be what the finger was aiming at, and
    /// only then the teleport pin. Every branch is something someone has just
    /// asked for; the pin is the default because it is what you get when you
    /// have asked for nothing.
    private func handleMapTap(at point: CGPoint, proxy: MapProxy) {
        guard let coordinate = proxy.convert(point, from: .local) else { return }

        if workspace.drawMode {
            workspace.drawnPath.append(coordinate)
            return
        }

        if workspace.focusedStopID != nil {
            workspace.place(coordinate)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            updatePlacementHint()
            rebuildRouteIfPossible()
            resolveStopNames()
            return
        }

        // Picking between alternatives on the map beats picking from a list:
        // the difference between them is a shape, and the list can only
        // describe it. They are drawn faintly underneath for exactly this.
        if let alternative = alternativeRoute(near: coordinate) {
            withAnimation(.snappy) { workspace.selectedRouteID = alternative }
            UISelectionFeedbackGenerator().selectionChanged()
            refreshPreview()
            return
        }

        session.setPin(coordinate)
        pinPlaceName = nil
        pinSelected = false
    }

    /// The unselected alternative running closest to `coordinate`, if one passes
    /// near enough to have been the target.
    ///
    /// The threshold scales with the zoom: forty metres is a fat finger on a
    /// street map and invisible on a country one, so it is measured in screen
    /// terms — a fixed fraction of what the map is currently showing.
    private func alternativeRoute(near coordinate: CLLocationCoordinate2D) -> UUID? {
        let candidates = workspace.routes.filter {
            $0.id != workspace.selectedRoute?.id && $0.coordinates.count > 1
        }
        guard !candidates.isEmpty else { return nil }

        let threshold = max(25, mapSpanMetres * 0.03)

        var best: (id: UUID, distance: CLLocationDistance)?
        for route in candidates {
            // Sampled rather than exhaustive: the polyline is already resampled
            // to about 12 m, so every fourth point is a ~50 m sieve — plenty to
            // decide which of two roads a thumb was on.
            for point in stride(from: 0, to: route.coordinates.count, by: 4) {
                let distance = Geo.distance(route.coordinates[point], coordinate)
                if distance < (best?.distance ?? .greatestFiniteMagnitude) {
                    best = (route.id, distance)
                }
            }
        }
        guard let best, best.distance <= threshold else { return nil }
        return best.id
    }

    /// Rebuilds the road route when there is something to route between.
    private func rebuildRouteIfPossible() {
        guard workspace.canRoute else { return }
        Task {
            if let error = await workspace.buildRoadRoute(
                fallbackStart: session.simulated ?? session.pin,
                mode: session.travelMode
            ) {
                session.lastError = error
            } else {
                refreshPreview()
            }
        }
    }

    /// Names each stop from a reverse geocode, so the planner lists places
    /// rather than latitudes.
    private func resolveStopNames() {
        for stop in workspace.stops where stop.name == nil {
            Task { @MainActor in
                if let name = await PlaceNamer.shared.name(for: stop.coordinate) {
                    workspace.nameStop(stop.id, name)
                }
            }
        }
    }

    /// The one-line prompt above the map while a stop is waiting for a point.
    private func updatePlacementHint() {
        guard let stop = workspace.focusedStop, let index = workspace.index(of: stop.id) else {
            routePlacementHint = nil
            return
        }
        let role = role(at: index)
        routePlacementHint = "Tap the map to set \(role.title.lowercased()) \(RouteStop.label(at: index))."
    }

    // MARK: - Chrome

    /// One glass container for the whole top stack: the bar, its results and the
    /// control chips sample the map once and blend where they meet, instead of
    /// each trying to refract the others.
    private var topChrome: some View {
        LocusGlassGroup(spacing: 14) {
            VStack(spacing: 10) {
                StatusBarView()
                    .locusGlassID("status", in: chromeGlass)

                searchBar
                    .locusGlassID("search", in: chromeGlass)

                // A coordinate beats the place search outright — it is not a
                // guess about what you meant, it is the answer.
                if let match = typedCoordinate {
                    coordinateResult(match)
                        .locusGlassID("coordinate", in: chromeGlass)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else if !searchText.isEmpty && !search.results.isEmpty {
                    searchResults
                        .locusGlassID("results", in: chromeGlass)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                HStack(alignment: .center, spacing: 10) {
                    mapChromeButtons
                        .locusGlassID("chips", in: chromeGlass)

                    if session.isRouting {
                        followChip
                            .locusGlassID("follow", in: chromeGlass)
                            .transition(.scale(scale: 0.85).combined(with: .opacity))
                    }

                    Spacer(minLength: 0)
                    locateButton
                        .locusGlassID("locate", in: chromeGlass)
                }

                if precisionMode {
                    PinPrecisionBar(
                        center: mapCenter,
                        pin: session.pin,
                        step: $nudgeStep,
                        onSetHere: setPinAtCrosshair,
                        onNudge: nudgePin,
                        onDone: { withAnimation(.snappy) { precisionMode = false } }
                    )
                    .locusGlassID("precision", in: chromeGlass)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
                }

                if let hint = routePlacementHint {
                    routePlacementBanner(hint)
                        .locusGlassID("placing", in: chromeGlass)
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                }

                if workspace.drawMode {
                    drawModeBanner
                        .locusGlassID("draw", in: chromeGlass)
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                }

                if let hint = importedPaceHint {
                    recordedPaceBanner(duration: hint)
                        .locusGlassID("pace", in: chromeGlass)
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 2)
        .safeAreaPadding(.top, 8)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: search.results.count)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: workspace.drawMode)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: importedPaceHint)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: precisionMode)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: routePlacementHint)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search places", text: $searchText)
                .textInputAutocapitalization(.words)
                .focused($searchFocused)
                .submitLabel(.search)
                .onSubmit(submitSearch)
                .onChange(of: searchText) { _, value in
                    // Don't ask MapKit to find a business called
                    // "48.8584, 2.2945" — and clear any results still on
                    // screen from before the coordinate was pasted in.
                    search.query = CoordinateParser.looksLikeCoordinate(value) ? "" : value
                }
            if searchFocused || !searchText.isEmpty {
                Button {
                    searchText = ""
                    search.query = ""
                    searchFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear and dismiss keyboard")
            }
            if searchFocused {
                Button("Done") { searchFocused = false }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(LocusTheme.accent)
            } else if searchText.isEmpty {
                // A coordinate copied out of a chat is the commonest way of
                // being told where to go, and pasting it used to mean tapping
                // the field, holding, picking Paste, then reading it back to
                // check it survived. `PasteButton` also asks iOS for the
                // clipboard without the "Locus pasted from…" banner.
                PasteButton(payloadType: String.self) { strings in
                    guard let text = strings.first else { return }
                    Task { @MainActor in acceptPasted(text) }
                }
                .labelStyle(.iconOnly)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .tint(LocusTheme.accent)
                .accessibilityLabel("Paste a location")
            }
        }
        .padding(12)
        .locusGlass(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// The Search key used to do nothing but put the keyboard away.
    ///
    /// The field is labelled Search and every other app in the world takes you
    /// to the top hit when you press it. Here you typed a place, pressed
    /// Search, watched the keyboard go, and then had to reach back up to the
    /// list that was already on screen.
    private func submitSearch() {
        searchFocused = false
        if let match = typedCoordinate {
            go(to: match)
        } else if let first = search.results.first {
            select(completion: first)
        }
    }

    /// What is in the search field, when it is a location rather than the name
    /// of one — coordinates, a `geo:` link, an Apple/Google/OSM maps URL.
    private var typedCoordinate: CoordinateParser.Match? {
        CoordinateParser.parse(searchText)
    }

    private func coordinateResult(_ match: CoordinateParser.Match) -> some View {
        Button {
            go(to: match)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(LocusTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(match.name ?? "Go to these coordinates")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(CoordinateParser.text(match.coordinate))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.forward")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .locusGlass(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(search.results.prefix(5), id: \.self) { item in
                Button {
                    select(completion: item)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        if !item.subtitle.isEmpty {
                            Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider().opacity(0.3)
            }
        }
        .locusGlass(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var mapChromeButtons: some View {
        HStack(spacing: 4) {
            chromeIconButton("square.3.layers.3d", label: "Map style") {
                session.mapStyleIndex = (session.mapStyleIndex + 1) % 3
            }

            chromeIconButton(
                "point.topleft.down.to.point.bottomright.curvepath",
                label: "Routes",
                isOn: workspace.hasPlayablePath
            ) {
                showRouteSheet = true
            }

            chromeIconButton(
                workspace.drawMode ? "pencil.tip.crop.circle.badge.minus" : "pencil.tip.crop.circle",
                label: workspace.drawMode ? "Stop drawing" : "Draw a path",
                isOn: workspace.drawMode
            ) {
                workspace.drawMode.toggle()
                if !workspace.drawMode { workspace.drawnPath.removeAll() }
            }

            chromeIconButton(
                "dot.viewfinder",
                label: precisionMode ? "Leave precision mode" : "Place the pin precisely",
                isOn: precisionMode
            ) {
                togglePrecisionMode()
            }

            favoriteButton
        }
        .padding(6)
        .locusGlass(.clear, in: Capsule())
        .contentShape(Capsule())
    }

    /// Stars the pin, and un-stars it again. It used to only ever add, so an
    /// accidental star had to be undone from the Settings list — three taps and
    /// a screen away from where it happened.
    @ViewBuilder
    private var favoriteButton: some View {
        if let pin = session.pin {
            let starred = session.isFavorite(pin)
            chromeIconButton(
                starred ? "star.circle.fill" : "star.circle",
                label: starred ? "Remove from saved places" : "Save this place",
                isOn: starred
            ) {
                if starred {
                    session.removeFavorite(at: pin)
                } else {
                    let name = session.suggestedFavoriteName(for: pin, fallback: pinPlaceName)
                    session.addFavorite(name: name, coordinate: pin)
                }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }
    }

    /// While a route plays the camera tracks the car. This is the way out of
    /// that, so the map can be panned somewhere else mid-drive without the next
    /// fix yanking it back.
    private var followChip: some View {
        Button {
            withAnimation(.snappy) { followsDrive.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: followsDrive ? "location.viewfinder" : "location.slash")
                Text(followsDrive ? "Following" : "Free")
                    .lineLimit(1)
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(followsDrive ? LocusTheme.accent : .secondary)
        .locusGlass(.clear, in: Capsule())
        .accessibilityLabel(followsDrive ? "Stop following the drive" : "Follow the drive")
    }

    /// A GPX with timestamps is a recording of something someone actually did.
    /// Offering to replay it at that pace is the one thing you can do with the
    /// timing data, so it's offered here rather than buried in the parameters.
    private func recordedPaceBanner(duration: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.path.ecg")
                .foregroundStyle(LocusTheme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Track recorded over \(duration)")
                    .font(.caption.weight(.semibold))
                Text(session.drive.speedSource == .recorded
                     ? "Replaying at that pace."
                     : "Replay it at that pace?")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if session.drive.speedSource == .recorded {
                Button("Dismiss") { importedPaceHint = nil }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            } else {
                Button("Use it") {
                    session.drive.speedSource = .recorded
                    refreshPreview()
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(LocusTheme.accent)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .locusGlass(.clear, in: Capsule())
        .contentShape(Capsule())
    }

    /// Says which stop the next map tap fills in, and gets out of the way.
    ///
    /// Modes that silently change what a tap does are how you lose a pin you
    /// spent a minute placing. This one announces itself and can be cancelled
    /// from the same place it appears.
    private func routePlacementBanner(_ hint: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "smallcircle.filled.circle")
                .foregroundStyle(LocusTheme.accent)
            Text(hint)
                .font(.caption.weight(.medium))
                .lineLimit(2)
            Spacer(minLength: 0)
            Button("Cancel") {
                workspace.focusedStopID = nil
                updatePlacementHint()
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .locusGlass(.clear, in: Capsule())
        .contentShape(Capsule())
    }

    private var drawModeBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.tap.fill")
                .foregroundStyle(LocusTheme.accentSecondary)
            Text(workspace.drawnPath.isEmpty
                 ? "Tap the map to lay down a path."
                 : "\(workspace.drawnPath.count) points — open Routes to drive it.")
                .font(.caption.weight(.medium))
            Spacer(minLength: 0)
            if !workspace.drawnPath.isEmpty {
                Button("Undo") { workspace.drawnPath.removeLast() }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(LocusTheme.accent)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .locusGlass(.clear, in: Capsule())
        .contentShape(Capsule())
    }

    private var locateButton: some View {
        GlassIconButton(
            systemName: "location.fill",
            accessibilityLabel: session.isSpoofing
                ? "Go to the simulated location. Long press for the real one."
                : "Current location",
            onLongPress: session.isSpoofing ? goToRealLocation : nil
        ) {
            searchFocused = false
            followsDrive = true
            goToCurrentLocation()
        }
    }

    /// Centers on the spoofed fix while spoofing, otherwise the real GPS —
    /// never the leftover teleport pin (`.automatic` would frame that marker).
    private func goToCurrentLocation() {
        let meters: CLLocationDistance = 900
        withAnimation(.easeInOut(duration: 0.35)) {
            if session.isSpoofing, let sim = session.simulated {
                position = .region(MKCoordinateRegion(
                    center: sim,
                    latitudinalMeters: meters,
                    longitudinalMeters: meters
                ))
            } else if let real = session.realCoordinate {
                position = .region(MKCoordinateRegion(
                    center: real,
                    latitudinalMeters: meters,
                    longitudinalMeters: meters
                ))
            } else {
                position = .userLocation(
                    followsHeading: false,
                    fallback: .region(MKCoordinateRegion(
                        center: CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090),
                        latitudinalMeters: 2000,
                        longitudinalMeters: 2000
                    ))
                )
            }
        }
    }

    // MARK: - Precision placement

    /// Entering centres the map on the pin, so the crosshair starts on the
    /// thing being adjusted rather than wherever the map happened to be left.
    private func togglePrecisionMode() {
        searchFocused = false
        let entering = !precisionMode
        withAnimation(.snappy) { precisionMode = entering }
        guard entering else { return }
        followsDrive = false
        if workspace.drawMode {
            // Both want the map taps. Precision mode wins, since it was just
            // asked for.
            workspace.drawMode = false
        }
        if let pin = session.pin {
            mapCenter = pin
            withAnimation(.easeInOut(duration: 0.3)) {
                position = .region(MKCoordinateRegion(
                    center: pin,
                    latitudinalMeters: 220,
                    longitudinalMeters: 220
                ))
            }
        }
    }

    private func setPinAtCrosshair() {
        guard let center = mapCenter else { return }
        session.setPin(center)
        pinPlaceName = nil
        pinSelected = false
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    }

    /// Moves the pin by metres east and north. The map stays where it is: the
    /// point of nudging is to watch the pin move against fixed ground.
    private func nudgePin(east: Double, north: Double) {
        guard let pin = session.pin else { return }
        session.setPin(Geo.offset(pin, east: east, north: north))
        pinPlaceName = nil
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Long press on the locate button: show where the phone actually is.
    ///
    /// While spoofing, the locate button follows the simulated fix — the right
    /// default, and also the reason there was no way to check what the real GPS
    /// was doing without turning the spoof off first.
    private func goToRealLocation() {
        guard let real = session.realCoordinate else {
            session.lastError = "No real GPS fix yet. Give Locus a moment with Location Services on."
            return
        }
        followsDrive = false
        withAnimation(.easeInOut(duration: 0.35)) {
            position = .region(MKCoordinateRegion(
                center: real,
                latitudinalMeters: 900,
                longitudinalMeters: 900
            ))
        }
    }

    private func chromeIconButton(
        _ systemName: String,
        label: String,
        isOn: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.body.weight(.semibold))
                .frame(width: LocusMetrics.controlSide, height: LocusMetrics.controlSide)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isOn ? LocusTheme.accentSecondary : .primary)
        .accessibilityLabel(label)
    }

    // MARK: - Actions

    private func select(completion: MKLocalSearchCompletion) {
        Task { @MainActor in
            let request = MKLocalSearch.Request(completion: completion)
            if let response = try? await MKLocalSearch(request: request).start(),
               let item = response.mapItems.first {
                let coord = item.placemark.coordinate
                let title = item.name ?? completion.title
                searchText = ""
                search.query = ""
                searchFocused = false

                // Recent, not favourite. Searching for a place is not the same
                // as starring it — this used to do both, so the favourites list
                // filled up with everything anyone had ever looked up, and the
                // star button next to the pin was already lit before it was
                // ever pressed.
                session.pushNamedRecent(name: title, coordinate: coord)

                // Searching while the planner is waiting for a stop fills that
                // stop in. Routing to a named place used to mean finding it,
                // reading its coordinates off the pin and setting the endpoint
                // by hand.
                if workspace.focusedStopID != nil {
                    workspace.place(coord, name: title)
                    updatePlacementHint()
                    rebuildRouteIfPossible()
                } else {
                    session.setPin(coord)
                    pinPlaceName = title
                }

                position = .region(MKCoordinateRegion(
                    center: coord,
                    latitudinalMeters: 1200,
                    longitudinalMeters: 1200
                ))
            }
        }
    }

    /// Drops the pin on a parsed location and frames it. Deliberately stops
    /// short of teleporting: a pasted link is a suggestion, and the Teleport
    /// button is right there.
    private func go(to match: CoordinateParser.Match) {
        searchText = ""
        search.query = ""
        searchFocused = false
        followsDrive = false
        if let name = match.name {
            session.pushNamedRecent(name: name, coordinate: match.coordinate)
        }

        // Same rule as a search result: a stop that is waiting for a point gets
        // it, so a pasted coordinate can be a route endpoint.
        if workspace.focusedStopID != nil {
            workspace.place(match.coordinate, name: match.name)
            updatePlacementHint()
            rebuildRouteIfPossible()
        } else {
            session.setPin(match.coordinate)
            pinPlaceName = match.name
            pinSelected = false
        }
        withAnimation(.easeInOut(duration: 0.35)) {
            position = .region(MKCoordinateRegion(
                center: match.coordinate,
                latitudinalMeters: 1200,
                longitudinalMeters: 1200
            ))
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Pasted text that is a location goes straight to the map; anything else
    /// is a search term, and lands in the field where a search term belongs.
    private func acceptPasted(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let match = CoordinateParser.parse(trimmed) {
            go(to: match)
        } else {
            searchText = trimmed
            search.query = trimmed
            searchFocused = true
        }
    }

    /// Rebuilds the coloured stretches and the route outline, once the changes
    /// stop arriving.
    ///
    /// This runs the whole planner — resample, corner radius and turn density at
    /// every point, junction stops, the moving average over all of it — across
    /// the entire route, on the main actor. And it is wired to `session.drive`,
    /// which changes on *every frame* of a slider drag in the driving settings:
    /// a forty-kilometre route was being replanned sixty times a second while a
    /// finger moved, for one picture at the end of it. Coalescing collapses that
    /// to a single rebuild without changing what finally gets drawn.
    private func refreshPreview() {
        previewTask?.cancel()
        previewTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            workspace.refreshPreview(profile: session.drive, mode: session.travelMode)
        }
    }

    private func playRoute() {
        guard workspace.hasPlayablePath else {
            session.lastError = "Find a route, draw one, or import a GPX file first."
            return
        }
        showRouteSheet = false
        followsDrive = true
        session.driveRoute(workspace, pairing: pairing)
    }

    private func focus(on coordinates: [CLLocationCoordinate2D]) {
        guard let region = Self.region(covering: coordinates) else { return }
        followsDrive = false
        // Every caller of this is a row in the planner — pick an alternative,
        // load a saved route, tap a stretch of limits — and every one of them
        // means "show me this". At the large detent the sheet is over the map
        // it just moved, so the answer arrives somewhere you can't see.
        if showRouteSheet, routeDetent == .large { routeDetent = .medium }
        withAnimation(.easeInOut(duration: 0.4)) {
            position = .region(region)
        }
    }

    private func importGPX(_ url: URL) {
        do {
            let track = try GPXCodec.parseTrack(url)
            guard track.coordinates.count > 1 else {
                session.lastError = "That GPX file has no track to follow."
                return
            }

            // Timestamps are kept only when there is one per point: resampling
            // the coordinates without them would leave the two arrays out of
            // step, and a pace mapped onto the wrong places is worse than none.
            workspace.adoptRawPath(
                track.coordinates,
                named: url.deletingPathExtension().lastPathComponent,
                recordedTimes: track.hasTiming ? track.times : nil
            )
            workspace.drawnPath.removeAll()
            session.setPin(track.coordinates[0])
            refreshPreview()
            focus(on: track.coordinates)

            if track.hasTiming {
                importedPaceHint = DriveFormat.clock(track.duration)
            }
        } catch {
            session.lastError = error.localizedDescription
        }
    }

    private func exportGPX() {
        let path = workspace.activeCoordinates
        guard !path.isEmpty else {
            session.lastError = "Nothing to export."
            return
        }
        let name = workspace.selectedRoute?.name ?? "Locus Route"
        // Timestamps too, when the route has them: exporting a recorded track
        // and importing it back used to flatten it to a bare line, losing the
        // one thing that made it a recording.
        let gpx = GPXCodec.export(
            path,
            name: name,
            times: workspace.selectedRoute?.recordedTimes
        )
        // Named after the route. Exporting three routes in a row used to write
        // three files called Locus-Route.gpx, which Files and Mail then keep
        // apart with "(1)" and "(2)" — leaving you to guess which is which.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(Self.exportFilename(for: name))
        do {
            try gpx.data(using: .utf8)?.write(to: url)
            let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let root = scene.keyWindow?.rootViewController {
                root.present(activity, animated: true)
            }
        } catch {
            session.lastError = error.localizedDescription
        }
    }

    /// A filename that survives Files, AirDrop and Mail: no path separators, no
    /// leading dot, never empty, and short enough to read on a share sheet.
    static func exportFilename(for routeName: String?) -> String {
        var cleaned = (routeName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        for bad in ["/", ":", "\\", "\u{0}"] {
            cleaned = cleaned.replacingOccurrences(of: bad, with: "-")
        }
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count > 60 { cleaned = String(cleaned.prefix(60)).trimmingCharacters(in: .whitespaces) }
        return "\(cleaned.isEmpty ? "Locus Route" : cleaned).gpx"
    }

    /// Region that frames a whole path, with a little breathing room.
    static func region(covering coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion? {
        guard let first = coordinates.first else { return nil }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for coordinate in coordinates {
            minLat = min(minLat, coordinate.latitude)
            maxLat = max(maxLat, coordinate.latitude)
            minLon = min(minLon, coordinate.longitude)
            maxLon = max(maxLon, coordinate.longitude)
        }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (minLat + maxLat) / 2,
                longitude: (minLon + maxLon) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: max(0.004, (maxLat - minLat) * 1.4),
                longitudeDelta: max(0.004, (maxLon - minLon) * 1.4)
            )
        )
    }
}

/// The spoofed fix. While a route plays it points the way the car is going, so
/// the map reads as motion rather than a jumping dot.
struct SpoofMarker: View {
    var course: CLLocationDirection?
    var isMoving: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(LocusTheme.accent.opacity(0.22))
                .frame(width: 44, height: 44)

            if let course, isMoving {
                Image(systemName: "location.north.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(Circle().fill(LocusTheme.accent))
                    .rotationEffect(.degrees(course))
                    .animation(.easeOut(duration: 0.3), value: course)
            } else {
                Circle()
                    .fill(LocusTheme.accent)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
            }
        }
        .accessibilityLabel("Simulated location")
    }
}

private extension UIWindowScene {
    var keyWindow: UIWindow? { windows.first { $0.isKeyWindow } }
}

@MainActor
final class PlaceSearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    var query: String = "" {
        didSet {
            completer.queryFragment = query
            if query.isEmpty { results = [] }
        }
    }

    /// Where to look. `MKLocalSearchCompleter` defaults to the whole world, so
    /// without this "Gare" over Lyon offered stations anywhere but Lyon, and
    /// every high-street name in the country outranked the one on screen.
    ///
    /// Written straight through rather than debounced: the camera reports on
    /// gesture end, and the completer treats a region change as a re-rank of
    /// the query it already has, not a new request.
    var region: MKCoordinateRegion {
        get { completer.region }
        set { completer.region = newValue }
    }

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let items = completer.results
        Task { @MainActor in self.results = items }
    }

    /// Deliberately keeps whatever is on screen.
    ///
    /// The completer cancels its in-flight request on every keystroke and
    /// reports that as a failure, so clearing here made the list flicker out
    /// from under a finger already reaching for it. An empty query is the one
    /// thing that genuinely means "no results", and `query` handles that.
    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {}
}
