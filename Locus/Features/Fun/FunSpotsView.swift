import CoreLocation
import MapKit
import SwiftUI

/// The home tab: where you are, and every place you've saved, one tap away.
///
/// A search result here *teleports*. In Pro mode it drops a pin, because a pin
/// is a thing you then route from, correct, star or drag. Nothing in Fun mode
/// does any of that, so the extra step is a step to nowhere.
struct FunSpotsView: View {
    @ObservedObject var settings: FunSettings
    @ObservedObject var connection: FunConnection
    var onStuck: (TunnelBlocker) -> Void

    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var pairing: PairingStore

    @StateObject private var search = PlaceSearchCompleter()
    @State private var query = ""
    @FocusState private var searching: Bool
    @State private var draft: FunSpotDraft?

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                HStack(alignment: .center, spacing: 12) {
                    FunTitle(text: "Where to?")
                    FunConnectionPill(connection: connection, onStuck: onStuck)
                }

                searchField

                if let match = typedCoordinate {
                    coordinateRow(match)
                } else if !search.results.isEmpty {
                    resultsCard
                }

                nowCard

                spots
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, FunMetrics.tabBar + 20)
        }
        .scrollDismissesKeyboard(.interactively)
        .animation(.snappy(duration: 0.25), value: search.results.count)
        .animation(.snappy(duration: 0.25), value: session.simulated?.latitude)
        .sheet(item: $draft) { draft in
            FunSpotEditor(draft: draft)
                .environmentObject(session)
        }
        .onAppear { session.startLocationUpdates() }
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(FunTheme.mist)

            TextField("", text: $query, prompt: Text("Search a place, or paste a link")
                .foregroundColor(FunTheme.mist))
                .font(.fun(16, .semibold))
                .foregroundStyle(FunTheme.ink)
                .focused($searching)
                .submitLabel(.go)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .onSubmit(submit)
                .onChange(of: query) { _, value in
                    // Don't ask MapKit to find a business called "48.85, 2.29".
                    search.query = CoordinateParser.looksLikeCoordinate(value) ? "" : value
                }

            if !query.isEmpty {
                Button {
                    query = ""
                    search.query = ""
                    searching = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(FunTheme.mist)
                        .frame(width: FunMetrics.tap, height: FunMetrics.tap)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            } else {
                PasteButton(payloadType: String.self) { strings in
                    guard let text = strings.first else { return }
                    Task { @MainActor in accept(pasted: text) }
                }
                .labelStyle(.iconOnly)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .tint(FunTheme.punch)
                .accessibilityLabel("Paste a place")
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
        .funCard(999)
    }

    private var typedCoordinate: CoordinateParser.Match? {
        CoordinateParser.parse(query)
    }

    private func coordinateRow(_ match: CoordinateParser.Match) -> some View {
        Button {
            go(to: match.coordinate, named: match.name)
        } label: {
            HStack(spacing: 14) {
                Text("📌")
                    .font(.system(size: 26))
                VStack(alignment: .leading, spacing: 2) {
                    Text(match.name ?? "Go here")
                        .font(.fun(16, .heavy))
                        .foregroundStyle(FunTheme.ink)
                    Text(CoordinateParser.text(match.coordinate))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(FunTheme.mist)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(FunTheme.punch)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .funCard()
    }

    private var resultsCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(search.results.prefix(4).enumerated()), id: \.offset) { index, item in
                Button {
                    resolve(item)
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.fun(15, .heavy))
                                .foregroundStyle(FunTheme.ink)
                                .lineLimit(1)
                            if !item.subtitle.isEmpty {
                                Text(item.subtitle)
                                    .font(.fun(12, .semibold))
                                    .foregroundStyle(FunTheme.mist)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.forward")
                            .font(.system(size: 13, weight: .heavy))
                            .foregroundStyle(FunTheme.punch)
                    }
                    .padding(.horizontal, 18)
                    .frame(minHeight: 56)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if index < min(search.results.count, 4) - 1 {
                    Rectangle()
                        .fill(Color.white.opacity(0.07))
                        .frame(height: 1)
                        .padding(.leading, 18)
                }
            }
        }
        .padding(.vertical, 4)
        .funCard()
    }

    // MARK: - Right now

    private var nowCard: some View {
        let faking = session.simulated
        let coordinate = faking ?? session.pin ?? session.realCoordinate
        let saved = coordinate.flatMap { spot(at: $0) }

        return VStack(spacing: 0) {
            if coordinate != nil {
                // Both positions, always. The pin is deliberately not drawn as
                // a fake one: until you teleport, the only place you are is
                // where you really are, and a second marker saying otherwise
                // is the one thing this map must not do.
                FunLocationMap(
                    real: session.realCoordinate,
                    simulated: faking,
                    emoji: saved?.emoji ?? "📍"
                )
                .frame(height: 132)
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(faking == nil ? "Really here" : "Faking it")
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                        .tracking(1.1)
                        .foregroundStyle(faking == nil ? FunTheme.mist : FunTheme.punch)
                    Text(title(for: coordinate, saved: saved))
                        .font(.fun(19, .heavy))
                        .foregroundStyle(FunTheme.ink)
                        .lineLimit(1)
                    if let coordinate {
                        Text(CoordinateParser.text(coordinate))
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(FunTheme.mist)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)

                if faking != nil {
                    Button {
                        session.stop(pairing: pairing)
                        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                        session.flash("Back to your real spot")
                    } label: {
                        Text("Stop")
                            .font(.fun(15, .heavy))
                            .foregroundStyle(FunTheme.ink)
                            .padding(.horizontal, 20)
                            .frame(height: FunMetrics.tap)
                            .background(Capsule().fill(Color.white.opacity(0.12)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                } else if let coordinate, spot(at: coordinate) == nil {
                    Button {
                        draft = FunSpotDraft(coordinate: coordinate, suggestedName: session.suggestedFavoriteName(for: coordinate))
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .heavy))
                            .foregroundStyle(FunTheme.ink)
                            .frame(width: FunMetrics.tap, height: FunMetrics.tap)
                            .background(Circle().fill(Color.white.opacity(0.12)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Save this spot")
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .funCard()
    }

    private func title(for coordinate: CLLocationCoordinate2D?, saved: SavedPlace?) -> String {
        if let saved { return saved.name }
        if session.simulated != nil, let address = session.simulatedAddress { return address }
        if coordinate == nil { return "Looking…" }
        return session.simulated == nil ? "Your real spot" : "Somewhere new"
    }

    private func spot(at coordinate: CLLocationCoordinate2D) -> SavedPlace? {
        session.favorites.first { $0.isAt(coordinate) }
    }

    // MARK: - Spots

    private var spots: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Your spots")
                    .font(.fun(20, .semibold))
                    .foregroundStyle(FunTheme.ink)
                Spacer()
                if !session.favorites.isEmpty {
                    Text("Hold one to change it")
                        .font(.fun(12, .bold))
                        .foregroundStyle(FunTheme.mist)
                }
            }

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(session.favorites) { place in
                    FunSpotTile(place: place, active: session.simulated.map { place.isAt($0) } ?? false) {
                        beam(to: place)
                    }
                    .contextMenu {
                        Button {
                            draft = FunSpotDraft(place: place)
                        } label: {
                            Label("Rename or change the emoji", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            session.removeFavorite(place)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }

                Button {
                    let coordinate = session.pin ?? session.simulated ?? session.realCoordinate
                    guard let coordinate else {
                        session.lastError = "Search for a place first, then save it as a spot."
                        return
                    }
                    draft = FunSpotDraft(coordinate: coordinate, suggestedName: session.suggestedFavoriteName(for: coordinate))
                } label: {
                    VStack(spacing: 7) {
                        Image(systemName: "plus")
                            .font(.system(size: 24, weight: .heavy))
                        Text("Add")
                            .font(.fun(13, .bold))
                    }
                    .foregroundStyle(FunTheme.mist)
                    .frame(maxWidth: .infinity)
                    .frame(height: 104)
                    .background(
                        RoundedRectangle(cornerRadius: FunMetrics.tile, style: .continuous)
                            .fill(Color.white.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: FunMetrics.tile, style: .continuous)
                            .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                            .foregroundStyle(Color.white.opacity(0.20))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: FunMetrics.tile, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add a spot")
            }

            if session.favorites.isEmpty {
                Text("Search for somewhere, then tap ＋ to keep it here.")
                    .font(.fun(14, .semibold))
                    .foregroundStyle(FunTheme.mist)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }

            recents
        }
    }

    /// Where you've been lately.
    ///
    /// The session has kept these all along and Fun mode never showed them, so
    /// going back somewhere you visited an hour ago meant searching for it
    /// again — or saving a spot you only ever wanted once.
    @ViewBuilder
    private var recents: some View {
        if !session.recents.isEmpty {
            VStack(spacing: 10) {
                HStack {
                    Text("Lately")
                        .font(.fun(20, .semibold))
                        .foregroundStyle(FunTheme.ink)
                    Spacer(minLength: 0)
                }
                .padding(.top, 6)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(session.recents.prefix(8)) { place in
                            Button {
                                beam(to: place)
                            } label: {
                                HStack(spacing: 8) {
                                    Text(place.emoji ?? "🕘")
                                        .font(.system(size: 18))
                                    Text(place.name)
                                        .font(.fun(14, .heavy))
                                        .foregroundStyle(FunTheme.ink)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 14)
                                .frame(height: 48)
                                .background(Capsule().fill(FunTheme.card))
                                .overlay(Capsule().stroke(FunTheme.line, lineWidth: 1))
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    draft = FunSpotDraft(coordinate: place.coordinate, suggestedName: place.name)
                                } label: {
                                    Label("Keep it as a spot", systemImage: "star")
                                }
                                Button(role: .destructive) {
                                    session.removeRecent(place)
                                } label: {
                                    Label("Forget it", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - Going places

    private func beam(to place: SavedPlace) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        session.setPin(place.coordinate)
        session.teleport(to: place.coordinate, pairing: pairing)
        session.flash("Off to \(place.name)\(place.emoji.map { " " + $0 } ?? "")…")
    }

    private func go(to coordinate: CLLocationCoordinate2D, named name: String?) {
        query = ""
        search.query = ""
        searching = false
        if let name { session.pushNamedRecent(name: name, coordinate: coordinate) }
        session.setPin(coordinate)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        session.teleport(to: coordinate, pairing: pairing)
        session.flash(name.map { "Off to \($0)…" } ?? "On your way…")
    }

    private func submit() {
        if let match = typedCoordinate {
            go(to: match.coordinate, named: match.name)
        } else if let first = search.results.first {
            resolve(first)
        }
    }

    private func resolve(_ completion: MKLocalSearchCompletion) {
        Task { @MainActor in
            let request = MKLocalSearch.Request(completion: completion)
            guard let response = try? await MKLocalSearch(request: request).start(),
                  let item = response.mapItems.first else {
                session.lastError = "Couldn't find that one. Try another name?"
                return
            }
            go(to: item.placemark.coordinate, named: item.name ?? completion.title)
        }
    }

    private func accept(pasted text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let match = CoordinateParser.parse(trimmed) {
            go(to: match.coordinate, named: match.name)
        } else {
            query = trimmed
            search.query = trimmed
            searching = true
        }
    }
}

// MARK: - Pieces

/// One saved spot: its emoji, its name, and whether you are standing on it.
struct FunSpotTile: View {
    let place: SavedPlace
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Text(place.emoji ?? "📍")
                    .font(.system(size: 34))
                Text(place.name)
                    .font(.fun(13, .heavy))
                    .foregroundStyle(FunTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.horizontal, 6)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 104)
            .background(
                RoundedRectangle(cornerRadius: FunMetrics.tile, style: .continuous)
                    .fill(active ? FunTheme.punch.opacity(0.16) : FunTheme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: FunMetrics.tile, style: .continuous)
                    .stroke(active ? FunTheme.punch : FunTheme.line, lineWidth: active ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: FunMetrics.tile, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(active ? "\(place.name), you are here" : place.name)
    }
}
