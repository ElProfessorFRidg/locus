import MapKit
import SwiftUI

struct MapHomeView: View {
    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var pairing: PairingStore

    @StateObject private var search = PlaceSearchCompleter()
    @StateObject private var workspace = RouteWorkspace()

    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool
    @State private var showRouteSheet = false
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
                .onTapGesture { point in
                    searchFocused = false
                    guard !suppressNextMapTap, !isDraggingPin else { return }
                    pinSelected = false
                    placePin(at: point, proxy: proxy)
                }
            }
            .background(Color.black.ignoresSafeArea())

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
            .presentationDetents([.medium, .large])
            .environmentObject(session)
            // The corrections list is the preview's output, so make sure it
            // exists before the sheet that edits it opens.
            .onAppear { refreshPreview() }
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

    private func placePin(at point: CGPoint, proxy: MapProxy) {
        guard let coord = proxy.convert(point, from: .local) else { return }
        if workspace.drawMode {
            workspace.drawnPath.append(coord)
        } else {
            session.setPin(coord)
            pinPlaceName = nil
            pinSelected = false
        }
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

                if !searchText.isEmpty && !search.results.isEmpty {
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
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search places", text: $searchText)
                .textInputAutocapitalization(.words)
                .focused($searchFocused)
                .submitLabel(.search)
                .onSubmit { searchFocused = false }
                .onChange(of: searchText) { _, value in
                    search.query = value
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
            }
        }
        .padding(12)
        .locusGlass(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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

            if session.pin != nil {
                chromeIconButton("star.circle", label: "Save this place") {
                    if let pin = session.pin {
                        let name = session.suggestedFavoriteName(for: pin, fallback: pinPlaceName)
                        session.addFavorite(name: name, coordinate: pin)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                }
            }
        }
        .padding(6)
        .locusGlass(.clear, in: Capsule())
        .contentShape(Capsule())
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
            accessibilityLabel: "Current location"
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
                session.setPin(coord)
                pinPlaceName = title
                position = .region(MKCoordinateRegion(
                    center: coord,
                    latitudinalMeters: 1200,
                    longitudinalMeters: 1200
                ))
                searchText = ""
                search.query = ""
                searchFocused = false
                session.addFavorite(name: title, coordinate: coord)
                session.pushNamedRecent(name: title, coordinate: coord)
            }
        }
    }

    private func refreshPreview() {
        workspace.refreshPreview(profile: session.drive, mode: session.travelMode)
    }

    private func playRoute() {
        guard workspace.hasPlayablePath else {
            session.lastError = "Find a route, draw one, or import a GPX file first."
            return
        }
        showRouteSheet = false
        followsDrive = true
        session.startRoute(
            workspace.activeCoordinates,
            pairing: pairing,
            expectedSpeed: workspace.activeExpectedSpeed,
            name: workspace.selectedRoute?.name ?? "Route",
            overrides: workspace.overrides,
            recordedSpeed: workspace.recordedSpeedSampler
        )
    }

    private func focus(on coordinates: [CLLocationCoordinate2D]) {
        guard let region = Self.region(covering: coordinates) else { return }
        followsDrive = false
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
        let gpx = GPXCodec.export(path)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Locus-Route.gpx")
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
        }
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

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.results = [] }
    }
}
