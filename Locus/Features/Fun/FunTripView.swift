import CoreLocation
import MapKit
import SwiftUI

/// Going somewhere, rather than being somewhere.
///
/// The Pro planner is a workspace: lettered stops you drag, alternatives to
/// compare, per-stretch limit corrections, saved routes with filters and an
/// order. This is two ends and a speed. Everything the planner can do that this
/// can't is one tap away in Pro, and none of it is the thing a first-timer
/// wanted.
struct FunTripView: View {
    @ObservedObject var settings: FunSettings
    @ObservedObject var connection: FunConnection
    var onStuck: (TunnelBlocker) -> Void

    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var pairing: PairingStore

    @State private var destination: SavedPlace?
    @State private var route: BuiltRoute?
    @State private var building = false
    @State private var picking = false

    private static let modes: [TravelMode] = [.walk, .cycle, .drive]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack(alignment: .center, spacing: 12) {
                    FunTitle(text: "Take a trip")
                    FunConnectionPill(connection: connection, onStuck: onStuck)
                }

                endpoints

                modePicker

                if let route {
                    summary(route)
                }

                VStack(spacing: 10) {
                    FunSectionLabel(text: "How fast?")
                    HStack(spacing: 10) {
                        ForEach(FunTripSpeed.allCases) { speed in
                            FunChip(
                                emoji: speed.emoji,
                                title: speed.title,
                                detail: speed.detail,
                                selected: settings.tripSpeed == speed
                            ) {
                                withAnimation(.snappy) { settings.tripSpeed = speed }
                                UISelectionFeedbackGenerator().selectionChanged()
                            }
                        }
                    }
                }

                FunPrimaryButton(
                    title: route == nil ? "Find the way" : "Start the trip",
                    systemImage: route == nil ? "point.topleft.down.to.point.bottomright.curvepath" : "play.fill",
                    enabled: destination != nil && !building
                ) {
                    route == nil ? build() : start()
                }

                if building {
                    HStack(spacing: 8) {
                        ProgressView().tint(FunTheme.mist)
                        Text("Looking for a way there…")
                            .font(.fun(13, .semibold))
                            .foregroundStyle(FunTheme.mist)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, FunMetrics.tabBar + 20)
        }
        .animation(.snappy(duration: 0.25), value: route?.id)
        .animation(.snappy(duration: 0.2), value: building)
        .sheet(isPresented: $picking) {
            FunDestinationPicker { place in
                destination = place
                route = nil
                picking = false
            }
            .environmentObject(session)
        }
    }

    // MARK: - Where from, where to

    private var endpoints: some View {
        HStack(spacing: 12) {
            VStack(spacing: 5) {
                Circle().fill(FunTheme.go).frame(width: 12, height: 12)
                ForEach(0..<3, id: \.self) { _ in
                    Circle().fill(Color.white.opacity(0.28)).frame(width: 2, height: 4)
                }
                Circle().fill(FunTheme.punch).frame(width: 12, height: 12)
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 14) {
                endpointRow(caption: "From", emoji: "📍", title: fromTitle, action: nil)
                endpointRow(
                    caption: "To",
                    emoji: destination?.emoji ?? "🏁",
                    title: destination?.name ?? "Pick a spot",
                    action: { picking = true }
                )
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .funCard()
    }

    private func endpointRow(caption: String, emoji: String, title: String, action: (() -> Void)?) -> some View {
        let content = HStack(spacing: 10) {
            Text(emoji).font(.system(size: 22))
            VStack(alignment: .leading, spacing: 1) {
                Text(caption.uppercased())
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .tracking(1)
                    .foregroundStyle(FunTheme.mist)
                Text(title)
                    .font(.fun(16, .heavy))
                    .foregroundStyle(FunTheme.ink)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if action != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(FunTheme.mist)
            }
        }
        .frame(minHeight: FunMetrics.tap)
        .contentShape(Rectangle())

        return Group {
            if let action {
                Button(action: action) { content }.buttonStyle(.plain)
            } else {
                content
            }
        }
    }

    private var fromTitle: String {
        if session.simulated != nil {
            return session.simulatedAddress ?? "Where you are now"
        }
        return session.realCoordinate == nil ? "Finding you…" : "Where you really are"
    }

    private var startCoordinate: CLLocationCoordinate2D? {
        session.simulated ?? session.pin ?? session.realCoordinate
    }

    // MARK: - How

    private var modePicker: some View {
        HStack(spacing: 10) {
            ForEach(Self.modes, id: \.self) { mode in
                FunChip(
                    emoji: Self.emoji(for: mode),
                    title: mode.title,
                    selected: settings.tripMode == mode
                ) {
                    withAnimation(.snappy) {
                        settings.tripMode = mode
                        route = nil
                    }
                    session.travelMode = mode
                    UISelectionFeedbackGenerator().selectionChanged()
                }
            }
        }
    }

    private static func emoji(for mode: TravelMode) -> String {
        switch mode {
        case .walk: return "🚶"
        case .run: return "🏃"
        case .cycle: return "🚴"
        case .drive: return "🚗"
        }
    }

    // MARK: - What it comes to

    private func summary(_ route: BuiltRoute) -> some View {
        VStack(spacing: 0) {
            FunRouteMap(coordinates: route.coordinates)
                .frame(height: 138)

            HStack(spacing: 22) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(DriveFormat.distance(route.distance))
                        .font(.fun(20, .semibold))
                        .foregroundStyle(FunTheme.ink)
                    Text("distance")
                        .font(.fun(12, .bold))
                        .foregroundStyle(FunTheme.mist)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(waitLabel(route))
                        .font(.fun(20, .semibold))
                        .foregroundStyle(FunTheme.ink)
                    Text("you'll wait")
                        .font(.fun(12, .bold))
                        .foregroundStyle(FunTheme.mist)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .funCard()
    }

    /// How long *you* sit there, which is the journey divided by the playback
    /// speed. Apple's own estimate is how long the journey takes; at 6× that is
    /// not the number anyone is waiting for.
    private func waitLabel(_ route: BuiltRoute) -> String {
        let seconds = route.expectedTravelTime / max(0.05, settings.tripSpeed.timeScale)
        if seconds < 60 { return "under a min" }
        return "about \(Int((seconds / 60).rounded())) min"
    }

    // MARK: - Doing it

    private func build() {
        guard let start = startCoordinate, let destination else {
            session.lastError = "Pick where you're going first."
            return
        }
        session.travelMode = settings.tripMode
        building = true
        Task {
            defer { building = false }
            do {
                let built = try await RouteBuilder.roadRoute(
                    through: [start, destination.coordinate],
                    mode: settings.tripMode
                )
                guard let best = built.first else {
                    session.lastError = "No way to get there by \(settings.tripMode.gerund)."
                    return
                }
                route = best
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } catch {
                session.lastError = "Couldn't find a way there. Try somewhere closer?"
            }
        }
    }

    private func start() {
        guard let route, let destination else { return }
        session.travelMode = settings.tripMode
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        session.startRoute(
            route.coordinates,
            pairing: pairing,
            expectedSpeed: route.expectedTravelTime > 1 ? route.distance / route.expectedTravelTime : nil,
            name: destination.name,
            roads: route.roads
        )
    }
}

// MARK: - Picking a destination

/// Spots first, search second — the destination someone means is almost always
/// one they already saved.
struct FunDestinationPicker: View {
    var onPick: (SavedPlace) -> Void

    @EnvironmentObject private var session: SpoofSession
    @Environment(\.dismiss) private var dismiss

    @StateObject private var search = PlaceSearchCompleter()
    @State private var query = ""

    var body: some View {
        ZStack {
            FunTheme.night.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    Text("Where to?")
                        .font(.fun(26, .semibold))
                        .foregroundStyle(FunTheme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(FunTheme.mist)
                        TextField("", text: $query, prompt: Text("Search somewhere else")
                            .foregroundColor(FunTheme.mist))
                            .font(.fun(16, .semibold))
                            .foregroundStyle(FunTheme.ink)
                            .autocorrectionDisabled()
                            .onChange(of: query) { _, value in
                                search.query = CoordinateParser.looksLikeCoordinate(value) ? "" : value
                            }
                    }
                    .padding(.horizontal, 18)
                    .frame(height: 56)
                    .funCard(999)

                    if let match = CoordinateParser.parse(query) {
                        row(emoji: "📌", title: match.name ?? "These coordinates",
                            detail: CoordinateParser.text(match.coordinate)) {
                            onPick(SavedPlace(
                                name: match.name ?? "Dropped spot",
                                latitude: match.coordinate.latitude,
                                longitude: match.coordinate.longitude,
                                emoji: "📌"
                            ))
                        }
                    }

                    ForEach(Array(search.results.prefix(4).enumerated()), id: \.offset) { _, item in
                        row(emoji: "🔎", title: item.title, detail: item.subtitle) {
                            resolve(item)
                        }
                    }

                    if search.results.isEmpty, query.isEmpty {
                        ForEach(session.favorites) { place in
                            row(emoji: place.emoji ?? "📍",
                                title: place.name,
                                detail: CoordinateParser.text(place.coordinate)) {
                                onPick(place)
                            }
                        }

                        if session.favorites.isEmpty {
                            Text("Save a spot first, or search for somewhere.")
                                .font(.fun(14, .semibold))
                                .foregroundStyle(FunTheme.mist)
                                .padding(.top, 20)
                        }
                    }

                    Spacer(minLength: 20)
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .preferredColorScheme(.dark)
    }

    private func row(emoji: String, title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Text(emoji).font(.system(size: 26))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.fun(16, .heavy))
                        .foregroundStyle(FunTheme.ink)
                        .lineLimit(1)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.fun(12, .semibold))
                            .foregroundStyle(FunTheme.mist)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .frame(minHeight: 66)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .funCard(22)
    }

    private func resolve(_ completion: MKLocalSearchCompletion) {
        Task { @MainActor in
            let request = MKLocalSearch.Request(completion: completion)
            guard let response = try? await MKLocalSearch(request: request).start(),
                  let item = response.mapItems.first else {
                session.lastError = "Couldn't find that one."
                return
            }
            let coordinate = item.placemark.coordinate
            onPick(SavedPlace(
                name: item.name ?? completion.title,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                emoji: "🔎"
            ))
        }
    }
}

/// The route, drawn once and not touchable — the same rule as `FunMiniMap`.
struct FunRouteMap: View {
    let coordinates: [CLLocationCoordinate2D]

    var body: some View {
        Map(position: .constant(.rect(region)), interactionModes: []) {
            if coordinates.count > 1 {
                MapPolyline(coordinates: coordinates)
                    .stroke(FunTheme.go, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            }
            if let first = coordinates.first {
                Annotation("", coordinate: first) {
                    Circle().fill(FunTheme.go).frame(width: 16, height: 16)
                        .overlay(Circle().stroke(FunTheme.night, lineWidth: 3))
                }
            }
            if let last = coordinates.last {
                Annotation("", coordinate: last) {
                    Circle().fill(FunTheme.punch).frame(width: 16, height: 16)
                        .overlay(Circle().stroke(FunTheme.night, lineWidth: 3))
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// A box round the whole route with a little air, so neither end sits on
    /// the edge of the card.
    private var region: MKMapRect {
        guard let first = coordinates.first else { return MKMapRect.world }
        var rect = MKMapRect(origin: MKMapPoint(first), size: MKMapSize(width: 0, height: 0))
        for coordinate in coordinates.dropFirst() {
            let point = MKMapPoint(coordinate)
            rect = rect.union(MKMapRect(origin: point, size: MKMapSize(width: 0, height: 0)))
        }
        return rect.insetBy(dx: -rect.size.width * 0.15 - 200, dy: -rect.size.height * 0.15 - 200)
    }
}
