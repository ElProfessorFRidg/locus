import AppIntents
import CoreLocation
import Foundation

/// Siri, Shortcuts and the Action button.
///
/// Every intent here sets `openAppWhenRun`, which is not laziness: the location
/// engine is a C FFI holding a live tunnel session, a background task and a
/// resend timer, all in the app's process. Running a teleport anywhere else
/// would mean standing that whole stack up in an extension, tearing it down,
/// and leaving the app's own session out of sync with what the phone is
/// actually reporting.
///
/// The trade is that Locus comes to the foreground. For "teleport to work
/// before I leave", that's the right shape anyway — you want to see it worked.

// MARK: - Entities

/// A saved place, as something Siri can name.
struct FavoritePlaceEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Saved place"
    static var defaultQuery = FavoritePlaceQuery()

    var id: UUID
    var name: String
    var latitude: Double
    var longitude: Double

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(String(format: "%.4f, %.4f", latitude, longitude))"
        )
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init(_ place: SavedPlace) {
        id = place.id
        name = place.name
        latitude = place.latitude
        longitude = place.longitude
    }
}

struct FavoritePlaceQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [FavoritePlaceEntity] {
        await MainActor.run { Self.all().filter { identifiers.contains($0.id) } }
    }

    func suggestedEntities() async throws -> [FavoritePlaceEntity] {
        await MainActor.run { Self.all() }
    }

    /// Favourites first, then recents — both are places you've been, and Siri
    /// having only the starred ones would make "teleport to the last place"
    /// impossible.
    @MainActor
    private static func all() -> [FavoritePlaceEntity] {
        let session = SpoofSession.shared
        // Deduplicated by position, not by id: a place that is both starred and
        // recently visited is two entries with two ids and one location, and
        // Siri offering it twice under the same name is unusable.
        var kept: [SavedPlace] = []
        for place in session.favorites + session.recents
        where !kept.contains(where: { $0.isAt(place.coordinate) }) {
            kept.append(place)
        }
        return kept.map(FavoritePlaceEntity.init)
    }
}

/// A driving profile, so a shortcut can pick one before setting off.
struct DriveProfileEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Driving profile"
    static var defaultQuery = DriveProfileQuery()

    var id: UUID
    var name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    init(_ profile: DriveProfile) {
        id = profile.id
        name = profile.name
    }
}

struct DriveProfileQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [DriveProfileEntity] {
        await MainActor.run {
            SpoofSession.shared.profiles.profiles
                .filter { identifiers.contains($0.id) }
                .map(DriveProfileEntity.init)
        }
    }

    func suggestedEntities() async throws -> [DriveProfileEntity] {
        await MainActor.run {
            SpoofSession.shared.profiles.profiles.map(DriveProfileEntity.init)
        }
    }
}

// MARK: - Intents

struct TeleportIntent: AppIntent {
    static var title: LocalizedStringResource = "Teleport"
    static var description = IntentDescription("Sets your simulated location to a saved place.")
    static var openAppWhenRun = true

    @Parameter(title: "Place", requestValueDialog: "Where to?")
    var place: FavoritePlaceEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Teleport to \(\.$place)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let session = SpoofSession.shared

        guard PairingStore.shared.hasPairingFile else {
            throw LocusIntentError.notPaired
        }

        // A stale error from an earlier failure would otherwise be read as
        // this teleport failing.
        session.lastError = nil
        session.teleport(to: place.coordinate, pairing: PairingStore.shared)

        // `teleport` does its work in a Task — wait for it to land or fail, so
        // Siri says what actually happened rather than always "done".
        let outcome = await LocusIntentSupport.waitForTeleport(session: session)
        switch outcome {
        case .active:
            return .result(dialog: "Now in \(place.name).")
        case .failed(let reason):
            throw LocusIntentError.failed(reason)
        }
    }
}

struct StopSpoofingIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop spoofing"
    static var description = IntentDescription("Returns your location to the real one.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let session = SpoofSession.shared
        guard session.isSpoofing || session.isRouting else {
            return .result(dialog: "Locus wasn’t spoofing.")
        }
        session.stop(pairing: PairingStore.shared)
        return .result(dialog: "Back to your real location.")
    }
}

struct ConnectTunnelIntent: AppIntent {
    static var title: LocalizedStringResource = "Connect the Locus tunnel"
    static var description = IntentDescription("Brings up the loopback tunnel Locus needs before it can set a location.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        if TunnelController.loopbackReachable {
            return .result(dialog: "The tunnel is already up.")
        }
        if let blocker = TunnelController.staticBlocker {
            throw LocusIntentError.failed(blocker.title)
        }
        let connected = await TunnelController.shared.connect()
        guard connected else {
            throw LocusIntentError.failed("The tunnel didn’t come up.")
        }
        return .result(dialog: "Tunnel connected.")
    }
}

struct SelectDriveProfileIntent: AppIntent {
    static var title: LocalizedStringResource = "Use a driving profile"
    static var description = IntentDescription("Switches which set of driving parameters routes are played with.")
    static var openAppWhenRun = false

    @Parameter(title: "Profile", requestValueDialog: "Which profile?")
    var profile: DriveProfileEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Drive using \(\.$profile)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        SpoofSession.shared.selectProfile(profile.id)
        return .result(dialog: "Driving with \(profile.name).")
    }
}

// MARK: - Support

enum LocusIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notPaired
    case failed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notPaired:
            return "Locus has no pairing file yet. Open it and finish setup first."
        case .failed(let reason):
            return "\(reason)"
        }
    }
}

enum LocusIntentSupport {
    enum TeleportOutcome {
        case active
        case failed(String)
    }

    /// Polls the session until the teleport it just started resolves.
    ///
    /// `SpoofSession.teleport` is fire-and-forget — it has to be, since it waits
    /// on the tunnel — so an intent that returned immediately would report
    /// success for something that hadn't happened yet.
    @MainActor
    static func waitForTeleport(
        session: SpoofSession,
        timeout: TimeInterval = 20
    ) async -> TeleportOutcome {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case .active = session.status { return .active }
            if let error = session.lastError { return .failed(error) }
            if case .dropped(let reason) = session.status { return .failed(reason) }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return .failed("Locus didn’t get a location set in time.")
    }
}

// MARK: - Shortcuts

struct LocusShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TeleportIntent(),
            phrases: [
                "Teleport with \(.applicationName)",
                "Set my location in \(.applicationName)",
                "\(.applicationName) teleport",
            ],
            shortTitle: "Teleport",
            systemImageName: "location.north.circle.fill"
        )
        AppShortcut(
            intent: StopSpoofingIntent(),
            phrases: [
                "Stop \(.applicationName)",
                "Stop spoofing with \(.applicationName)",
            ],
            shortTitle: "Stop spoofing",
            systemImageName: "stop.circle.fill"
        )
        AppShortcut(
            intent: ConnectTunnelIntent(),
            phrases: [
                "Connect the \(.applicationName) tunnel",
                "Start the \(.applicationName) tunnel",
            ],
            shortTitle: "Connect tunnel",
            systemImageName: "bolt.fill"
        )
        AppShortcut(
            intent: SelectDriveProfileIntent(),
            phrases: [
                "Change \(.applicationName) driving profile",
                "Use a \(.applicationName) profile",
            ],
            shortTitle: "Driving profile",
            systemImageName: "gauge.with.dots.needle.50percent"
        )
    }
}
