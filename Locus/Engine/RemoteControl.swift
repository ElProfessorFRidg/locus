import CoreLocation
import Foundation

/// Acts on `locus://drive`, `locus://route` and `locus://stop`.
///
/// Talks to `SpoofSession.shared` and `PairingStore.shared` directly rather than
/// through a notification to the map: the URL can arrive before any view exists
/// (a cold launch from `uiopen`), and the map is not who owns a drive anyway.
///
/// The grammar and the key check are in `RemoteCommand.swift`, where they are
/// tested. This file is the part that needs a device.
@MainActor
final class RemoteControl {
    static let shared = RemoteControl()

    /// The outcome of the most recent command, for `locus-state.json`.
    private(set) var lastCommand: RemoteState.LastCommand?

    /// Commands run one at a time, in the order they arrived: two `uiopen`s in
    /// quick succession must not interleave their route building.
    private var tail: Task<Void, Never>?

    func handle(_ url: URL) async {
        let previous = tail
        let task = Task { @MainActor [weak self] in
            await previous?.value
            await self?.execute(url)
        }
        tail = task
        await task.value
    }

    private func execute(_ url: URL) async {
        let name = RemoteCommandParser.commandName(of: url) ?? "unknown"

        // The gate comes first and says nothing about the rest of the URL: a
        // caller without the key learns neither the grammar nor the state.
        // The key is never logged or echoed anywhere.
        switch RemoteKey.authorize(provided: RemoteCommandParser.key(in: url), keyFile: Self.readKeyFile()) {
        case .failure(let failure):
            record(name, error: failure.message)
            return
        case .success:
            break
        }

        switch RemoteCommandParser.parse(url) {
        case .failure(let error):
            record(name, error: error.message)
        case .success(let command):
            do {
                try await run(command)
                record(name, error: nil)
            } catch let error as RemoteCommandError {
                record(name, error: error.message)
            } catch {
                record(name, error: error.localizedDescription)
            }
        }
    }

    private func record(_ name: String, error: String?) {
        lastCommand = RemoteState.LastCommand(
            name: name,
            ts: Int(Date().timeIntervalSince1970),
            ok: error == nil,
            error: error
        )
        RemoteStateWriter.shared.writeNow()
    }

    /// The key file's text, or `nil` if it isn't there or can't be read — which
    /// is how remote control is switched off.
    private static func readKeyFile() -> String? {
        guard let handle = FileHandle(forReadingAtPath: RemoteKey.keyPath) else { return nil }
        defer { try? handle.close() }
        // A key is a line of text; anything bigger is not one.
        guard let data = try? handle.read(upToCount: 1024) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Commands

    private func run(_ command: RemoteCommand) async throws {
        let session = SpoofSession.shared
        let pairing = PairingStore.shared

        switch command {
        case .stop:
            // Nothing running is already the state asked for.
            guard session.isSpoofing || session.isRouting || session.joystickActive else { return }
            await session.stopAndWait(pairing: pairing)
            if let error = session.lastError { throw RemoteCommandError(error) }

        case .route(let name):
            try requireReady(session, pairing)
            // Several routes can share a name; the one driven most recently wins.
            let matches = session.routeStore.routes.filter {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }
            guard let saved = SavedRouteOrder.recent.sort(matches).first else {
                throw RemoteCommandError("no saved route named '\(name)'")
            }
            session.lastError = nil
            let built = saved.built
            session.startRoute(
                built.coordinates,
                pairing: pairing,
                expectedSpeed: built.expectedSpeed,
                name: saved.name,
                overrides: saved.overrides,
                recordedSpeed: built.recordedSpeedSampler(),
                recordedTimes: built.recordedTimes,
                roads: built.roads
            )
            try await confirmStarted(session)
            session.routeStore.markDriven(saved.id)

        case .drive(let request):
            try await drive(request, session: session, pairing: pairing)
        }
    }

    private func drive(_ request: RemoteDriveRequest, session: SpoofSession, pairing: PairingStore) async throws {
        try requireReady(session, pairing)

        // Unknown profile is an error, never a quiet fall back to another one.
        var named: DriveProfile?
        if let wanted = request.profileName {
            guard let found = session.profiles.profiles.first(where: {
                $0.name.caseInsensitiveCompare(wanted) == .orderedSame
            }) else {
                throw RemoteCommandError("unknown profile '\(wanted)'")
            }
            named = found
        }

        // A copy for this drive alone. The named profile in the store, and the
        // one selected in the app, are not touched.
        var transient: DriveProfile?
        if named != nil || request.timeScale != nil || request.endBehavior != nil {
            var profile = named ?? session.activeProfile
            if let scale = request.timeScale { profile.timeScale = scale }
            if let end = request.endBehavior { profile.endBehavior = end }
            transient = profile
        }

        // Same coordinate space as `locus://teleport`: the map's. Only differs
        // from WGS-84 inside mainland China.
        let start: CLLocationCoordinate2D
        if let origin = request.origin {
            start = CLLocationCoordinate2D(latitude: origin.latitude, longitude: origin.longitude)
        } else if let simulated = session.simulated {
            start = simulated
        } else if let real = session.realCoordinate {
            start = real
        } else {
            throw RemoteCommandError("no start position: nothing is simulated and there is no real fix; pass from=")
        }
        let end = CLLocationCoordinate2D(
            latitude: request.destination.latitude,
            longitude: request.destination.longitude
        )

        let routes: [BuiltRoute]
        do {
            routes = try await RouteBuilder.roadRoutes(from: start, to: end, mode: request.mode, alternatives: false)
        } catch {
            throw RemoteCommandError("routing failed: \(error.localizedDescription)")
        }
        guard let built = routes.min(by: { $0.expectedTravelTime < $1.expectedTravelTime }) else {
            throw RemoteCommandError("no route found")
        }

        session.lastError = nil
        session.startRoute(
            built.coordinates,
            pairing: pairing,
            expectedSpeed: built.expectedSpeed,
            name: "Remote drive",
            roads: built.roads,
            transientProfile: transient,
            transientMode: request.mode
        )
        try await confirmStarted(session)
    }

    private func requireReady(_ session: SpoofSession, _ pairing: PairingStore) throws {
        if let problem = session.readinessProblem(pairing: pairing) {
            throw RemoteCommandError(problem)
        }
    }

    /// `startRoute` refuses synchronously for most things, and for the rest (the
    /// tunnel engine failing to come up) a moment later. Waits long enough to
    /// tell the two apart from a drive that is simply under way.
    private func confirmStarted(_ session: SpoofSession) async throws {
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if let error = session.lastError { throw RemoteCommandError(error) }
            guard session.isRouting else { throw RemoteCommandError("the route did not start") }
            if session.routeCountdown != nil || session.status == .active { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        throw RemoteCommandError("no location fix was confirmed in time")
    }
}
