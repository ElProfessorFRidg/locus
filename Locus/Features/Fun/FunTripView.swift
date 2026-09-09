import CoreLocation
import MapKit
import SwiftUI
import UIKit

// MARK: - Where a trip goes

/// One end of a trip, or somewhere it passes through.
enum FunTripStop: Equatable {
    /// Wherever you are when the trip starts. Kept as an intention rather than
    /// a coordinate so a route planned before a teleport still sets off from
    /// the right place.
    case here
    case place(SavedPlace)
}

/// A row in the trip: a stop, or an empty slot waiting for one.
struct FunTripPoint: Identifiable, Equatable {
    let id: UUID
    var stop: FunTripStop?

    init(_ stop: FunTripStop? = nil, id: UUID = UUID()) {
        self.id = id
        self.stop = stop
    }

    var name: String {
        switch stop {
        case .here: return "Where I am now"
        case .place(let place): return place.name
        case nil: return "Pick a place"
        }
    }

    var emoji: String {
        switch stop {
        case .here: return "🧍"
        case .place(let place): return place.emoji ?? "📍"
        case nil: return "❔"
        }
    }

    var isSet: Bool { stop != nil }
}

// MARK: - The screen

/// Going somewhere, rather than being somewhere.
///
/// It started as two fixed ends with the start hardcoded to wherever you were —
/// which meant you couldn't plan tomorrow's walk from anywhere but where you
/// were standing, and couldn't route past the shop on the way. Both ends are
/// now rows you tap, and there can be stops between them.
struct FunTripView: View {
    @ObservedObject var settings: FunSettings
    @ObservedObject var connection: FunConnection
    var onStuck: (TunnelBlocker) -> Void

    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var pairing: PairingStore

    @State private var points: [FunTripPoint] = [FunTripPoint(.here), FunTripPoint()]
    @State private var route: BuiltRoute?
    @State private var building = false
    @State private var progress: String?
    /// Which row the picker is filling.
    @State private var editing: UUID?

    private static let modes: [TravelMode] = [.walk, .cycle, .drive]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack(alignment: .center, spacing: 12) {
                    FunTitle(text: "Take a trip")
                    FunConnectionPill(connection: connection, onStuck: onStuck)
                }

                itinerary

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
                    enabled: ready && !building
                ) {
                    route == nil ? build() : start()
                }

                if building {
                    HStack(spacing: 8) {
                        ProgressView().tint(FunTheme.mist)
                        Text(progress ?? "Looking for a way there…")
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
        .animation(.snappy(duration: 0.25), value: points)
        .animation(.snappy(duration: 0.2), value: building)
        .onAppear { session.startLocationUpdates() }
        .sheet(isPresented: Binding(
            get: { editing != nil },
            set: { if !$0 { editing = nil } }
        )) {
            FunPlacePicker(allowsHere: allowsHereForEditingRow) { stop in
                fill(stop)
            }
            .environmentObject(session)
        }
    }

    // MARK: - The itinerary

    private var itinerary: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                FunSectionLabel(text: "The way")
                Spacer(minLength: 0)
                Button {
                    withAnimation(.snappy) {
                        points.reverse()
                        route = nil
                    }
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundStyle(FunTheme.ink)
                        .frame(width: FunMetrics.tap, height: FunMetrics.tap)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Turn the trip round")
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)

            ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                row(index: index, point: point)
            }

            Button {
                withAnimation(.snappy) {
                    points.insert(FunTripPoint(), at: max(1, points.count - 1))
                    route = nil
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .heavy))
                    Text("Add a stop on the way")
                        .font(.fun(15, .bold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(FunTheme.mist)
                .padding(.horizontal, 18)
                .frame(height: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .funCard()
    }

    private func row(index: Int, point: FunTripPoint) -> some View {
        HStack(spacing: 12) {
            VStack(spacing: 3) {
                Circle()
                    .fill(dotColour(at: index))
                    .frame(width: 11, height: 11)
                if index < points.count - 1 {
                    Circle().fill(Color.white.opacity(0.26)).frame(width: 2, height: 2)
                    Circle().fill(Color.white.opacity(0.26)).frame(width: 2, height: 2)
                    Circle().fill(Color.white.opacity(0.26)).frame(width: 2, height: 2)
                }
            }
            .frame(width: 12)

            Button {
                editing = point.id
            } label: {
                HStack(spacing: 10) {
                    Text(point.emoji).font(.system(size: 21))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(label(at: index).uppercased())
                            .font(.system(size: 10, weight: .heavy, design: .rounded))
                            .tracking(1)
                            .foregroundStyle(FunTheme.mist)
                        Text(point.name)
                            .font(.fun(16, .heavy))
                            .foregroundStyle(point.isSet ? FunTheme.ink : FunTheme.mist)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(FunTheme.mist)
                }
                .frame(minHeight: FunMetrics.tap)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Only what's between the ends can be dropped: a trip with one end
            // is not a shorter trip, it is not a trip.
            if points.count > 2, index > 0, index < points.count - 1 {
                Button {
                    withAnimation(.snappy) {
                        points.removeAll { $0.id == point.id }
                        route = nil
                    }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(FunTheme.mist)
                        .frame(width: 34, height: FunMetrics.tap)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove this stop")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
    }

    private func label(at index: Int) -> String {
        if index == 0 { return "From" }
        if index == points.count - 1 { return "To" }
        return "Stop \(index)"
    }

    private func dotColour(at index: Int) -> Color {
        if index == 0 { return FunTheme.go }
        if index == points.count - 1 { return FunTheme.punch }
        return FunTheme.grape
    }

    /// "Where I am now" belongs at the start of a trip, not in the middle of
    /// one — you cannot pass through where you will be standing later.
    private var allowsHereForEditingRow: Bool {
        guard let editing, let index = points.firstIndex(where: { $0.id == editing }) else { return true }
        return index == 0 || index == points.count - 1
    }

    private func fill(_ stop: FunTripStop) {
        guard let editing, let index = points.firstIndex(where: { $0.id == editing }) else { return }
        points[index].stop = stop
        route = nil
        self.editing = nil
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
            FunLocationMap(
                real: session.realCoordinate,
                simulated: session.simulated,
                route: route.coordinates,
                stops: middleCoordinates,
                showsGap: false
            )
            .frame(height: 150)

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
    /// speed. Apple's estimate is how long the journey takes; at 6× that is not
    /// the number anyone is waiting for.
    private func waitLabel(_ route: BuiltRoute) -> String {
        let seconds = route.expectedTravelTime / max(0.05, settings.tripSpeed.timeScale)
        if seconds < 60 { return "under a min" }
        return "about \(Int((seconds / 60).rounded())) min"
    }

    // MARK: - Doing it

    private var ready: Bool { points.count >= 2 && points.allSatisfy(\.isSet) }

    private var middleCoordinates: [CLLocationCoordinate2D] {
        guard points.count > 2 else { return [] }
        return points.dropFirst().dropLast().compactMap { point in
            if case .place(let place) = point.stop { return place.coordinate }
            return nil
        }
    }

    /// Every point as a coordinate, with "where I am now" resolved at the last
    /// possible moment.
    private func coordinates() -> [CLLocationCoordinate2D]? {
        var resolved: [CLLocationCoordinate2D] = []
        for point in points {
            switch point.stop {
            case .here:
                guard let here = session.simulated ?? session.pin ?? session.realCoordinate else { return nil }
                resolved.append(here)
            case .place(let place):
                resolved.append(place.coordinate)
            case nil:
                return nil
            }
        }
        return resolved.count >= 2 ? resolved : nil
    }

    private func build() {
        guard let stops = coordinates() else {
            session.lastError = points.contains(where: { $0.stop == .here }) && session.realCoordinate == nil
                ? "Locus doesn't know where you are yet. Give it a moment, or pick a spot to start from."
                : "Fill in both ends first."
            return
        }
        session.travelMode = settings.tripMode
        building = true
        // Said up front rather than counted down from a progress callback: the
        // number of legs is known before the first request goes out, and a
        // `@Sendable` callback writing view state is a concurrency warning for
        // a label nobody reads twice.
        progress = stops.count > 2
            ? "Working out \(stops.count - 1) legs…"
            : "Looking for a way there…"
        Task {
            defer {
                building = false
                progress = nil
            }
            do {
                let built = try await RouteBuilder.roadRoute(
                    through: stops,
                    mode: settings.tripMode
                )
                guard let best = built.first else {
                    session.lastError = "No way to get there by \(settings.tripMode.gerund)."
                    return
                }
                route = best
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } catch {
                session.lastError = "Couldn't find a way there. Try somewhere closer, or a different way of getting there?"
            }
        }
    }

    private func start() {
        guard let route else { return }
        session.travelMode = settings.tripMode
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        session.startRoute(
            route.coordinates,
            pairing: pairing,
            expectedSpeed: route.expectedTravelTime > 1 ? route.distance / route.expectedTravelTime : nil,
            name: points.last?.name ?? "Trip",
            roads: route.roads
        )
    }
}

// MARK: - Picking a place

/// Spots first, search second — the place someone means is almost always one
/// they already saved.
struct FunPlacePicker: View {
    var allowsHere: Bool = true
    var onPick: (FunTripStop) -> Void

    @EnvironmentObject private var session: SpoofSession
    @Environment(\.dismiss) private var dismiss

    @StateObject private var search = PlaceSearchCompleter()
    @State private var query = ""

    var body: some View {
        ZStack {
            FunTheme.night.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 12) {
                    Text("Which place?")
                        .font(.fun(26, .semibold))
                        .foregroundStyle(FunTheme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 4)

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

                    if allowsHere, query.isEmpty {
                        row(emoji: "🧍", title: "Where I am now",
                            detail: "Wherever you happen to be when it starts") {
                            pick(.here)
                        }
                    }

                    if let match = CoordinateParser.parse(query) {
                        row(emoji: "📌",
                            title: match.name ?? "These coordinates",
                            detail: CoordinateParser.text(match.coordinate)) {
                            pick(.place(SavedPlace(
                                name: match.name ?? "Dropped spot",
                                latitude: match.coordinate.latitude,
                                longitude: match.coordinate.longitude,
                                emoji: "📌"
                            )))
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
                                pick(.place(place))
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

    private func pick(_ stop: FunTripStop) {
        onPick(stop)
        dismiss()
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
            pick(.place(SavedPlace(
                name: item.name ?? completion.title,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                emoji: "🔎"
            )))
        }
    }
}
