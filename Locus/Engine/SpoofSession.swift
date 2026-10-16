import Combine
import CoreLocation
import Foundation
import MapKit
import UIKit
import UserNotifications

enum SpoofStatus: Equatable {
    case idle
    case connecting
    case active
    case reconnecting
    case dropped(String)

    var label: String {
        switch self {
        case .idle: return "Not Spoofing"
        case .connecting: return "Starting…"
        case .active: return "Spoofing"
        case .reconnecting: return "Reconnecting…"
        case .dropped: return "Interrupted"
        }
    }

    var isDropped: Bool {
        if case .dropped = self { return true }
        return false
    }
}

/// Live state of the joystick, for its readout.
struct JoystickTelemetry: Equatable {
    var speed: CLLocationSpeed = 0
    /// Degrees clockwise from north; `nil` when the stick is centred.
    var course: CLLocationDirection?
    /// Metres covered since the joystick was switched on.
    var distance: CLLocationDistance = 0
    var isMoving: Bool { speed > 0.05 }
}

/// What a finished drive amounted to.
///
/// The numbers were all being computed and none of them were ever shown: the
/// HUD went away and that was the end of it. `tripEconomy` in particular had a
/// consumption slider, a toggle, and nowhere at all to appear.
struct TripSummary: Identifiable, Equatable {
    let id = UUID()
    var routeName: String
    var distance: CLLocationDistance
    /// Seconds of simulated time — what the drive would have taken in the world.
    var simulatedSeconds: TimeInterval
    /// Seconds you actually waited, which differs whenever the time scale isn't 1×.
    var wallClockSeconds: TimeInterval
    var laps: Int
    var profileName: String
    /// How it was covered. Kept on the trip rather than read off the session,
    /// so the summary of a drive still reads as a drive after the mode is
    /// switched with the card still up — and so a walk never reports litres of
    /// petrol burnt.
    var mode: TravelMode = .drive

    var averageSpeed: CLLocationSpeed {
        simulatedSeconds > 1 ? distance / simulatedSeconds : 0
    }
}

@MainActor
final class SpoofSession: ObservableObject {
    @Published var status: SpoofStatus = .idle
    @Published var pin: CLLocationCoordinate2D?
    @Published var simulated: CLLocationCoordinate2D?
    @Published var travelMode: TravelMode = .walk
    @Published var mapStyleIndex: Int = 0
    @Published var lastError: String?
    /// A short confirmation for something that worked.
    ///
    /// Failures get an alert; successes shouldn't — a teleport that lands is
    /// not worth a modal — but they were getting nothing at all, on a screen
    /// where the pin was already sitting where you asked for it.
    @Published private(set) var toast: String?
    @Published var isBusy = false
    @Published var joystickActive = false

    @Published var favorites: [SavedPlace] = []
    @Published var recents: [SavedPlace] = []

    /// The active driving profile — a working copy of whichever one is selected
    /// in `profiles`. Views bind straight to it; every change is written back to
    /// the named list, so there is no save step to forget.
    @Published var drive: DriveProfile {
        didSet {
            guard drive != oldValue else { return }
            profiles.update(drive)
            // Covers the "keep the screen on" toggle being flipped mid-drive,
            // and switching to a profile that answers it differently.
            refreshIdleTimer()
        }
    }

    /// Parameters to drive with instead of `drive`, while something other than
    /// the Pro sheet is in charge of them.
    ///
    /// Fun mode sets this to the profile behind its four chips and clears it on
    /// the way out. Everything that reads driving parameters reads
    /// `activeProfile`, so a Fun-mode drive never writes to — or is shaped by —
    /// the named profiles someone tuned in Pro mode. Nil is the whole of the
    /// old behaviour.
    @Published var profileOverride: DriveProfile? {
        didSet {
            guard profileOverride != oldValue else { return }
            refreshIdleTimer()
        }
    }

    /// The parameters in force: whatever has taken charge, else the selected
    /// profile.
    var activeProfile: DriveProfile { profileOverride ?? drive }

    /// How fast the joystick moves, when a dial rather than a profile is
    /// setting it. Nil leaves `joystickTopSpeed` exactly as it was.
    @Published var joystickSpeed: CLLocationSpeed?

    /// Named driving profiles. Switching between them beats retuning thirty
    /// parameters every time the kind of journey changes.
    let profiles: DriveProfileStore

    /// Saved routes, and where an interrupted one got to.
    let routeStore = RouteStore()

    /// Non-nil while a route is playing.
    @Published private(set) var telemetry: DriveTelemetry?
    /// Non-nil while the joystick is on. The route HUD's smaller sibling: the
    /// joystick moved you at a speed you set and never showed you either it or
    /// how far you'd gone.
    @Published private(set) var joystick: JoystickTelemetry?
    @Published private(set) var isRoutePaused = false
    /// Countdown before the first fix, when `drive.startDelaySeconds` is set.
    @Published private(set) var routeCountdown: Int?
    /// Set when a drive reaches its end, cleared when the summary is dismissed.
    @Published var lastTrip: TripSummary?
    /// Whether the direct engine has been seen to move the location — see
    /// `DirectSimulationCheck`. Checked once per launch, on the first teleport.
    @Published private(set) var directCheck: DirectCheckResult = .notRun

    /// Kept so the summary can report wall-clock time, which is not the same as
    /// simulated time whenever the scale isn't 1×.
    private var routeStartedAt: Date?
    private var lastRouteName = "Route"

    private var resendTimer: Timer?
    private var healthTimer: Timer?
    private var joystickTimer: Timer?
    private var routeTask: Task<Void, Never>?
    /// Bumped whenever a route starts or is cancelled. A finishing task only
    /// tears down shared state if it is still the current one — otherwise
    /// restarting a route would have the outgoing task clear the incoming
    /// route's telemetry a moment after it began.
    private var routeGeneration = 0
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private var joystickVector: CGVector = .zero
    private var toastTask: Task<Void, Never>?
    private let locationKeeper = BackgroundKeepAlive()
    /// The engine the location currently set was set through, so Stop clears
    /// it with the same one. `nil` when nothing is set.
    private var activeBackend: LocationBackend?
    /// Whether the last fix sent carried a speed. The direct engine hands
    /// `locationd` a whole `CLLocation`, and `locationd` keeps replaying the
    /// last one — so a joystick let go or a drive stopped mid-route has to say
    /// "stationary" once, or every app goes on reading 50 km/h from a phone
    /// that has stopped.
    private var lastFixWasMoving = false
    /// Where the time zone was last asked to follow. A drive asks again only
    /// once it has gone far enough to be somewhere else.
    private var timeZoneAnchor: CLLocationCoordinate2D?
    /// The keeper is paused in the background when nothing needs it — see
    /// `sceneDidEnterBackground`.
    private var keeperPausedForBackground = false
    private let directChecker = DirectSimulationCheck()

    /// Kept rather than built per fix: a generator is an object with a Taptic
    /// Engine connection behind it, and making one for every buzz is both an
    /// allocation and the reason `prepare()` exists.
    private let limitHaptic = UIImpactFeedbackGenerator(style: .rigid)
    /// Whether the last fix was over the limit, so the haptic fires on the
    /// crossing — which is what `hapticOnLimitChange` says it does. It was
    /// firing on *every* fix while over the limit instead: four buzzes a second
    /// for as long as you were speeding, which is a battery drain and, on a
    /// motorway stretch, several thousand of them.
    private var wasOverLimit = false

    /// Reverse-geocodes the pin so coordinates aren't the only thing on screen.
    /// Owned here rather than by a view so a starred favourite can be named
    /// after the place instead of its latitude.
    let places = PlaceResolver()

    private let favoritesKey = "locus.favorites"
    private let recentsKey = "locus.recents"

    private var cancellables = Set<AnyCancellable>()

    /// Shared so App Intents — which run in this process but outside the view
    /// hierarchy — can reach the same session the UI is showing.
    static let shared = SpoofSession()

    init() {
        // Built locally first: `drive` is a working copy of the store's active
        // profile, and Swift wants every stored property set before `self` is
        // touched.
        let store = DriveProfileStore()
        profiles = store
        drive = store.active
        favorites = SavedPlace.load(key: favoritesKey)
        recents = SavedPlace.load(key: recentsKey)

        // The store keeps routes; it doesn't know how to name a place. Handed
        // the geocoder here so a saved route can say where it runs between.
        routeStore.nameResolver = { await PlaceNamer.shared.name(for: $0) }

        // Nested ObservableObjects don't propagate: views watching the session
        // would never redraw when an address resolves or a profile is renamed.
        for nested in [
            places.objectWillChange,
            profiles.objectWillChange,
            routeStore.objectWillChange,
        ] as [ObservableObjectPublisher] {
            nested
                .sink { [weak self] in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }

        // The direct engine's simulation outlives the app. Opening on "Not
        // Spoofing" over a phone that is still somewhere else would leave no
        // Stop button to end it.
        if LocationBackend.current == .direct, let record = DirectSimulationRecord.load() {
            simulated = record.coordinate
            pin = record.coordinate
            status = .active
            activeBackend = .direct
            timeZoneAnchor = record.coordinate
        }
    }

    /// Holds the display awake while there is something moving on it.
    ///
    /// Called from every place that starts or ends a drive or the joystick, and
    /// again when the profile's toggle changes — iOS resets this on its own when
    /// the app is backgrounded, so it costs nothing to set more often than
    /// strictly needed and everything to set it less.
    private func refreshIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = activeProfile.keepScreenAwake && (isRouting || joystickActive)
    }

    /// Shows `message` briefly, replacing whatever was there. Cancelling the
    /// previous timer matters: two teleports in a row would otherwise have the
    /// first one's timer clear the second one's message early.
    func flash(_ message: String) {
        toastTask?.cancel()
        toast = message
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    func dismissToast() {
        toastTask?.cancel()
        toast = nil
    }

    /// Switches the active profile, replacing the live working copy.
    func selectProfile(_ id: UUID) {
        guard let profile = profiles.profile(id) else { return }
        profiles.select(id)
        drive = profile
    }

    /// Sets the pin from a deliberate action — a map tap, a search result, a
    /// favourite — and asks what's there.
    ///
    /// Separate from assigning `pin` because `apply` rewrites `pin` on every
    /// simulated fix; routing that through a geocoder would mean a request per
    /// second for the length of a route.
    func setPin(_ coordinate: CLLocationCoordinate2D?) {
        pin = coordinate
        places.resolve(coordinate)
    }

    /// The address of the pin, when one has been resolved for where it is now.
    var pinAddress: String? { places.address(for: pin) }

    /// The address of the fix currently being simulated.
    var simulatedAddress: String? { places.address(for: simulated) }

    var isSpoofing: Bool {
        if case .active = status { return true }
        if case .reconnecting = status { return true }
        return false
    }

    var isRouting: Bool { routeTask != nil }

    /// The engine a teleport would use right now.
    var backend: LocationBackend { LocationBackend.current }

    /// Whether everything a teleport needs is in place, short of the tunnel —
    /// which `prepareTunnel` raises on demand. For callers that report rather
    /// than act, like the Siri intents.
    func canSpoof(pairing: PairingStore) -> Bool {
        !backend.needsPairing || pairing.hasPairingFile
    }

    /// The pairing file only matters to the tunnel engine. A TrollStore copy
    /// using the direct one has never needed it and never will.
    private func isReady(_ pairing: PairingStore) -> Bool {
        guard !canSpoof(pairing: pairing) else { return true }
        lastError = "Import an RPPairing file in Settings first."
        return false
    }

    // MARK: - Teleport

    func teleport(to coordinate: CLLocationCoordinate2D, pairing: PairingStore) {
        guard isReady(pairing) else { return }
        setPin(coordinate)
        Task { [weak self] in
            guard let self else { return }
            guard await self.prepareTunnel() else { return }
            await self.apply(coordinate, pairing: pairing, markRecent: true, interactive: true)
        }
    }

    /// Clears the simulated location.
    ///
    /// Kicks the work off and returns, so the Stop button doesn't sit pressed
    /// while the engine tears the session down. `isBusy` covers the gap.
    func stop(pairing: PairingStore) {
        Task { [weak self] in
            await self?.stopAndWait(pairing: pairing)
        }
    }

    /// The same, awaited. For callers that report an outcome — the Siri intent
    /// shouldn't say "back to your real location" before it is.
    func stopAndWait(pairing: PairingStore) async {
        // No settling here: a "stationary" fix sent on the way out could land
        // after the clear and put the location straight back.
        cancelRoute(settle: false)
        stopJoystick(settle: false)
        stopResend()
        stopHealth()
        isBusy = true
        // Cleared through whichever engine set it — the Settings switch is
        // locked while spoofing, but a location restored from a previous launch
        // was set by the direct engine whatever the switch says now.
        let engine = activeBackend ?? backend
        let result: Result<Void, LocationEngineError>
        switch engine {
        case .direct: result = await DirectLocationEngine.clear()
        case .tunnel: result = await LocationEngine.clear()
        }
        finishStop(result, engine: engine)
    }

    private func finishStop(_ result: Result<Void, LocationEngineError>, engine: LocationBackend) {
        isBusy = false
        switch result {
        case .success:
            simulated = nil
            status = .idle
            activeBackend = nil
            lastFixWasMoving = false
            if engine == .direct { DirectSimulationRecord.clear() }
            // Back to the real place, so back to its time zone.
            timeZoneAnchor = nil
            TimeZoneFollower.requestUpdate()
            endBackground()
            // Keep location updates running so the map puck / locate button
            // can return to the real GPS fix (not the leftover pin).
            locationKeeper.start()
        case .failure(let error):
            lastError = error.localizedDescription
            status = .dropped(error.localizedDescription)
            postDropNotification(error.localizedDescription)
        }
    }

    /// Best-known real device coordinate (not the teleport pin).
    ///
    /// CoreLocation reports WGS-84; the map is GCJ-02 in mainland China, so the
    /// fix is moved into map space before anything draws or starts from it.
    var realCoordinate: CLLocationCoordinate2D? {
        locationKeeper.lastKnownCoordinate.map { MapDatumMode.current.fromWGS84($0) }
    }

    /// Sends the location being simulated again, through the same path a
    /// teleport takes. For settings that change what a fix *says* — altitude,
    /// the China map offset — so they take effect now rather than on the next
    /// teleport. Left alone while something is moving: the next fix is a
    /// fraction of a second away anyway.
    func reapplyCurrentLocation() {
        guard isSpoofing, !isRouting, !joystickActive, let here = simulated else { return }
        Task { [weak self] in
            await self?.apply(here, pairing: PairingStore.shared, markRecent: false)
        }
    }

    /// Adds bookmarks from Geranium or Mika's LocSim to favourites, skipping
    /// any spot already starred. Returns how many were new.
    @discardableResult
    func importLegacyBookmarks(_ bookmarks: [LegacyBookmarks.Bookmark]) -> Int {
        var added = 0
        // Reversed because each new favourite goes on top: this way the list
        // ends up in the order the other app kept it.
        for bookmark in bookmarks.reversed() {
            // Both apps stored what they handed `locationd`: WGS-84. Favourites
            // are kept in map space, like everything else the map touches.
            let wgs = CLLocationCoordinate2D(latitude: bookmark.latitude, longitude: bookmark.longitude)
            let coordinate = MapDatumMode.current.fromWGS84(wgs)
            guard !isFavorite(coordinate) else { continue }
            _ = addFavorite(name: bookmark.name, coordinate: coordinate)
            added += 1
        }
        return added
    }

    /// Asks CoreLocation whether the direct engine's location took.
    ///
    /// The entitlement can be present and `locationd` still not listen, and
    /// nothing in `CLSimulationManager`'s API would say so. Rather than leave
    /// that to be discovered in Maps, a "not taking" verdict says it here and
    /// points at the tunnel, which works regardless of how Locus was installed.
    func checkDirectSimulation() {
        guard activeBackend == .direct, let here = simulated else {
            directCheck = .notRun
            return
        }
        directCheck = .checking
        let wire = MapDatumMode.current.toWGS84(here)
        Task { [weak self] in
            guard let self else { return }
            let result = await self.directChecker.verify(wire)
            // Stopped, or moved on to the tunnel, while the check ran.
            guard self.activeBackend == .direct || result == .working else {
                self.directCheck = .notRun
                return
            }
            self.directCheck = result
            if result == .notTaking, !self.isRouting, !self.joystickActive {
                self.lastError = "iOS is still reporting your real location. This copy of Locus holds the location-simulation entitlement, "
                    + "but locationd isn’t accepting it here. Settings → Location → turn off “Set the location directly” to use the developer tunnel instead."
            }
        }
    }

    // MARK: - App lifecycle

    /// The keeper's background location updates are what keep a tunnel session
    /// alive behind the lock screen. The direct engine's simulation needs no
    /// keeping alive, so when nothing is moving there is no reason to keep the
    /// GPS and the app running in the background for it.
    func sceneDidEnterBackground() {
        guard backend.persistsOnItsOwn, !isRouting, !joystickActive else { return }
        locationKeeper.stop()
        keeperPausedForBackground = true
    }

    func sceneWillEnterForeground() {
        guard keeperPausedForBackground else { return }
        keeperPausedForBackground = false
        locationKeeper.start()
    }

    /// Start lightweight GPS updates for the map puck / locate button.
    func startLocationUpdates() {
        locationKeeper.start()
    }

    /// Brings Locus' own tunnel up if it isn't already, so a teleport doesn't
    /// fail with "could not open the developer tunnel" when one tap could have
    /// fixed it. Silent when the tunnel is already reachable.
    ///
    /// Returns `false` only when there is no usable tunnel *and* none can be
    /// raised — a sideloaded build without the VPN entitlement, LiveContainer,
    /// or a refused configuration. The caller stops there rather than letting
    /// the location engine fail several layers down with an error that blames
    /// the wrong thing.
    @discardableResult
    private func prepareTunnel() async -> Bool {
        // The direct engine talks to `locationd` from this process. There is
        // no tunnel to raise, and raising one anyway would be a VPN prompt for
        // nothing.
        guard backend.needsTunnel else { return true }

        let controller = TunnelController.shared

        if controller.autoConnect {
            if await controller.ensureConnected() { return true }
        } else if TunnelController.loopbackReachable {
            return true
        }

        guard !TunnelController.loopbackReachable else { return true }

        if let blocker = controller.blocker ?? TunnelController.staticBlocker {
            // The explanation sheet says all of this properly, with the button
            // that fixes it — an alert on top would just be the same words twice.
            NotificationCenter.default.post(name: .locusShowTunnelTrouble, object: blocker)
            return false
        }

        lastError = "The tunnel to \(TunnelConfig.targetIP) isn’t up. Start it from the status bar, or connect the LocalDevVPN app."
        return false
    }

    // MARK: - Joystick

    func startJoystick(pairing: PairingStore) {
        guard isReady(pairing) else { return }
        let start = simulated ?? pin ?? realCoordinate
        guard let start else {
            lastError = "Drop a pin or teleport somewhere before using the joystick."
            return
        }
        cancelRoute(settle: false)
        Task { [weak self] in
            guard let self else { return }
            guard await self.prepareTunnel() else { return }
            if self.simulated == nil {
                await self.apply(start, pairing: pairing, markRecent: false, interactive: true)
            }
            self.joystickActive = true
            self.joystick = JoystickTelemetry()
            self.refreshIdleTimer()
            self.joystickTimer?.invalidate()
            self.joystickTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    await self?.tickJoystick(pairing: pairing)
                }
            }
        }
    }

    func updateJoystick(vector: CGVector) {
        joystickVector = vector
    }

    /// - Parameter settle: report the location as stationary once the stick is
    ///   gone. Off when something else is about to send a fix of its own.
    func stopJoystick(settle: Bool = true) {
        joystickActive = false
        joystickVector = .zero
        joystick = nil
        joystickTimer?.invalidate()
        joystickTimer = nil
        refreshIdleTimer()
        if settle { settleMotion() }
    }

    /// Sends the current spot again with no speed, if the last fix had one.
    ///
    /// Only the direct engine carries speed and heading at all; the developer
    /// service takes coordinates and nothing else, so there is nothing to undo.
    private func settleMotion() {
        guard lastFixWasMoving, activeBackend == .direct, let here = simulated else { return }
        lastFixWasMoving = false
        Task { [weak self] in
            guard let self, self.simulated != nil, !self.isRouting, !self.joystickActive else { return }
            await self.apply(here, pairing: PairingStore.shared, markRecent: false, motion: .stationary)
        }
    }

    /// Top speed the joystick moves at. A fixed speed set for routes is an
    /// explicit "go this fast" and applies here too; otherwise the travel mode
    /// decides, as before.
    ///
    /// `joystickSpeed` beats both. Fun mode's Move dial is a speed *for
    /// walking around*, and tying it to the profile made it change when a trip
    /// on the next tab switched the travel mode to driving.
    private var joystickTopSpeed: CLLocationSpeed {
        if let joystickSpeed { return max(0.3, joystickSpeed) }
        return activeProfile.speedSource == .fixed
            ? max(0.3, activeProfile.fixedSpeedMetresPerSecond)
            : travelMode.baseSpeed
    }

    private func tickJoystick(pairing: PairingStore) async {
        guard joystickActive, let current = simulated else { return }
        let magnitude = hypot(joystickVector.dx, joystickVector.dy)

        // Stick centred: still report, so the readout says "stopped" instead of
        // freezing on the last speed it happened to be moving at.
        guard magnitude > 0.08 else {
            joystick?.speed = 0
            joystick?.course = nil
            // Released: one stationary fix, so apps stop reading the last speed.
            if lastFixWasMoving {
                await apply(current, pairing: pairing, markRecent: false, motion: .stationary)
            }
            return
        }

        let nx = joystickVector.dx / magnitude
        let ny = -joystickVector.dy / magnitude
        // Clamped exactly as the route walker clamps the same parameter. Left
        // open, a stored jitter above 1 makes the multiplier negative, and the
        // joystick drives you backwards at random.
        let jitter = (1 + Double.random(in: -1...1) * activeProfile.speedJitter).clamped(to: 0.5...1.5)
        let speed = joystickTopSpeed * min(1.0, magnitude) * jitter
        let dt = 0.25
        let meters = speed * dt
        let next = Geo.offset(current, east: nx * meters, north: ny * meters)

        let course = Geo.bearing(from: current, to: next)
        joystick?.speed = speed
        joystick?.course = course
        joystick?.distance += meters

        await apply(next, pairing: pairing, markRecent: false, motion: Motion(speed: speed, course: course))
    }

    // MARK: - Routes

    /// Plays `coordinates` using the current `DriveProfile`.
    ///
    /// - Parameter expectedSpeed: `MKRoute.distance / expectedTravelTime` when
    ///   the path came from Apple's directions. Without it the road-limit
    ///   estimate has nothing to scale off and falls back to the travel mode.
    func startRoute(
        _ coordinates: [CLLocationCoordinate2D],
        pairing: PairingStore,
        expectedSpeed: CLLocationSpeed? = nil,
        name: String = "Route",
        overrides: [LimitOverride] = [],
        recordedSpeed: ((CLLocationDistance) -> CLLocationSpeed)? = nil,
        // The timestamps behind `recordedSpeed`, kept only so the resume file
        // can carry them. A closure can't be written to disk, so without this
        // an interrupted "As recorded" drive came back at a generic pace.
        recordedTimes: [Date]? = nil,
        startingAt startDistance: CLLocationDistance = 0,
        roads: [RoadSegment] = []
    ) {
        guard isReady(pairing) else { return }
        guard coordinates.count >= 2 else {
            lastError = "Build or draw a route first."
            return
        }

        cancelRoute(settle: false)
        stopJoystick(settle: false)
        // The pin is about to move every second; an address for where it
        // started would only go stale and mislead.
        places.clear()

        let profile = activeProfile
        let mode = travelMode
        let basePlan = RouteSimulator.plan(
            coordinates: coordinates,
            profile: profile,
            mode: mode,
            routeExpectedSpeed: expectedSpeed,
            overrides: overrides,
            recordedSpeed: recordedSpeed,
            roads: roads
        )
        guard !basePlan.isEmpty else {
            lastError = "That route is too short to drive."
            return
        }

        isRoutePaused = false
        routeStartedAt = Date()
        lastRouteName = name
        lastTrip = nil
        let opening = DriveTelemetry(totalDistance: basePlan.totalDistance)
        telemetry = opening

        if profile.showLiveActivity {
            LiveActivityController.shared.start(
                routeName: name,
                profileName: profile.name,
                state: Self.activityState(for: opening, profile: profile, paused: false)
            )
        }

        routeGeneration += 1
        let generation = routeGeneration

        routeTask = Task { [weak self] in
            // Set inside the task, after `routeTask` is assigned: `isRouting`
            // reads that, so calling this any earlier would ask about a route
            // that doesn't exist yet.
            self?.refreshIdleTimer()
            guard let self else { return }
            guard await self.prepareTunnel() else {
                self.finishRoute(generation: generation)
                return
            }
            await self.countDown(seconds: profile.startDelaySeconds)
            if !Task.isCancelled {
                await self.run(
                    plan: basePlan,
                    profile: profile,
                    pairing: pairing,
                    resume: RouteResumeState(
                        routeName: name,
                        coordinates: coordinates.codable,
                        expectedTravelTime: expectedSpeed.map { basePlan.totalDistance / max($0, 0.1) } ?? 0,
                        distance: basePlan.totalDistance,
                        recordedTimes: recordedTimes,
                        roads: roads,
                        overrides: overrides,
                        travelled: 0,
                        lap: 1,
                        profileID: profile.id
                    ),
                    startDistance: startDistance
                )
            }
            self.finishRoute(generation: generation)
        }
    }

    private func finishRoute(generation: Int) {
        guard generation == routeGeneration else { return }

        // Arriving is the one moment of a drive worth marking, and it used to
        // be the one that showed nothing: the HUD simply vanished after forty
        // minutes. Only for a drive that actually reached the end — a cancel
        // bumps the generation and never gets here.
        if let telemetry, telemetry.distanceTravelled > 50 {
            lastTrip = TripSummary(
                routeName: lastRouteName,
                distance: telemetry.distanceTravelled,
                simulatedSeconds: telemetry.elapsed,
                wallClockSeconds: routeStartedAt.map { Date().timeIntervalSince($0) } ?? telemetry.elapsed,
                laps: telemetry.lap,
                profileName: activeProfile.name,
                mode: travelMode
            )
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        routeStartedAt = nil

        routeTask = nil
        telemetry = nil
        isRoutePaused = false
        routeCountdown = nil
        LiveActivityController.shared.end()
        // A route that reached its end has nothing left to resume.
        routeStore.clearResume()
        refreshIdleTimer()
        settleMotion()
    }

    func pauseRoute() { isRoutePaused = true }
    func resumeRoute() { isRoutePaused = false }

    func toggleRoutePause() {
        isRoutePaused.toggle()
        // Pausing is one of the few changes worth an immediate Live Activity
        // push rather than waiting out the throttle.
        if let telemetry, activeProfile.showLiveActivity {
            LiveActivityController.shared.update(
                Self.activityState(for: telemetry, profile: activeProfile, paused: isRoutePaused)
            )
        }
    }

    /// Stops the drive.
    ///
    /// - Parameter keepResumePoint: a deliberate stop discards where it got to;
    ///   starting a different route also does. The progress file is only there
    ///   for the drive nobody chose to end.
    /// - Parameter settle: report the location as stationary where the drive
    ///   stopped. Off when something else is about to send a fix of its own.
    func cancelRoute(keepResumePoint: Bool = false, settle: Bool = true) {
        routeGeneration += 1
        routeTask?.cancel()
        routeTask = nil
        telemetry = nil
        isRoutePaused = false
        routeCountdown = nil
        wasOverLimit = false
        LiveActivityController.shared.end()
        if !keepResumePoint { routeStore.clearResume() }
        refreshIdleTimer()
        if settle { settleMotion() }
    }

    /// Picks an interrupted drive back up from where the progress file says it
    /// stopped.
    func resumeSavedRoute(pairing: PairingStore) {
        guard let state = routeStore.resumable else { return }
        if let profileID = state.profileID, profileID != drive.id {
            selectProfile(profileID)
        }
        // `built` rebuilds the sampler from the stored timestamps, so a drive
        // that was replaying a recorded pace comes back replaying it — before,
        // resuming quietly dropped to the estimator's guess.
        let route = state.built
        startRoute(
            state.coordinates.clLocations,
            pairing: pairing,
            expectedSpeed: route.expectedSpeed,
            name: state.routeName,
            overrides: state.overrides,
            recordedSpeed: route.recordedSpeedSampler(),
            recordedTimes: state.recordedTimes,
            startingAt: state.travelled,
            roads: state.roads
        )
    }

    private func countDown(seconds: Double) async {
        guard seconds >= 1 else { return }
        var remaining = Int(seconds.rounded())
        while remaining > 0, !Task.isCancelled {
            routeCountdown = remaining
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            remaining -= 1
        }
        routeCountdown = nil
    }

    /// One pass over `plan`, repeated or reversed per `endBehavior`.
    private func run(
        plan: RoutePlan,
        profile: DriveProfile,
        pairing: PairingStore,
        resume template: RouteResumeState,
        startDistance: CLLocationDistance
    ) async {
        let dt = profile.updateInterval

        var current = plan
        var lap = 1
        var offset = startDistance
        var lastProgressWrite = Date.distantPast

        while !Task.isCancelled {
            let walker = DriveWalker(plan: current, profile: profile, startDistance: offset)
            offset = 0

            while !Task.isCancelled, let fix = walker.step(dt: dt) {
                while isRoutePaused, !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                guard !Task.isCancelled else { return }

                // Read from the live profile rather than the snapshot taken at
                // the start: the time scale is the one dial worth moving while
                // watching a drive, and it used to do nothing until the route
                // was restarted. Everything else is baked into the plan and
                // can't change under a walker mid-route, so it stays snapshotted.
                let scale = activeProfile.timeScaleClamped

                // Speed as the phone experiences it: at 4× playback the fixes
                // cover ground four times as fast, and a reported speed that
                // disagreed with the distance between them would be the
                // inconsistency an app notices.
                await apply(
                    fix.coordinate,
                    pairing: pairing,
                    markRecent: false,
                    motion: fix.isStopped ? .stationary : Motion(speed: fix.speed * scale, course: fix.course)
                )
                telemetry = DriveTelemetry(
                    speed: fix.speed,
                    speedLimit: fix.speedLimit,
                    course: fix.course,
                    progress: walker.progress,
                    distanceTravelled: fix.distanceTravelled,
                    distanceRemaining: fix.distanceRemaining,
                    elapsed: fix.elapsed,
                    isStopped: fix.isStopped,
                    isOverLimit: fix.isOverLimit,
                    lap: lap,
                    totalDistance: walker.totalDistance
                )

                if fix.isOverLimit != wasOverLimit {
                    wasOverLimit = fix.isOverLimit
                    if fix.isOverLimit, profile.hapticOnLimitChange {
                        limitHaptic.impactOccurred(intensity: 0.4)
                    }
                }

                if profile.showLiveActivity, let telemetry {
                    // Throttled inside the controller: a route emits fixes far
                    // faster than ActivityKit's update budget allows.
                    LiveActivityController.shared.update(
                        Self.activityState(
                            for: telemetry,
                            profile: profile,
                            paused: isRoutePaused,
                            timeScale: scale
                        )
                    )
                }

                // Written every few seconds rather than on a clean exit, so a
                // crash or a swipe-away can still be picked up where it left off.
                if Date().timeIntervalSince(lastProgressWrite) >= 5 {
                    lastProgressWrite = Date()
                    var state = template
                    state.travelled = fix.distanceTravelled
                    state.lap = lap
                    state.savedAt = Date()
                    routeStore.recordProgress(state)
                }

                try? await Task.sleep(nanoseconds: UInt64((dt / scale) * 1_000_000_000))
            }

            guard !Task.isCancelled else { return }

            switch profile.endBehavior {
            case .stop:
                return
            case .loop:
                lap += 1
                // Straight back to the start line — the jump is a teleport, the
                // same as pressing play again.
                continue
            case .pingPong:
                lap += 1
                current = current.reversed()
                continue
            case .reverseOnce:
                guard lap == 1 else { return }
                lap += 1
                current = current.reversed()
                continue
            }
        }
    }

    /// Formats telemetry for the Live Activity.
    ///
    /// The widget receives text, not numbers: it is a separate module, and
    /// giving it `DriveProfile` and `SpeedUnit` just to render "48 km/h" would
    /// drag half the engine over a target boundary and split unit handling in
    /// two.
    /// - Parameter timeScale: the scale in force right now, which is not
    ///   necessarily the one `profile` was snapshotted with — the dial moves
    ///   mid-drive, and an ETA computed at the old scale would be wrong on the
    ///   Lock Screen while the HUD showed the right one.
    private static func activityState(
        for telemetry: DriveTelemetry,
        profile: DriveProfile,
        paused: Bool,
        timeScale: Double? = nil
    ) -> DriveActivityAttributes.ContentState {
        let unit = profile.units
        return DriveActivityAttributes.ContentState(
            speed: "\(Int(unit.fromMetresPerSecond(telemetry.speed).rounded()))",
            unit: unit.short,
            limit: telemetry.speedLimit.map { "\(Int(unit.fromMetresPerSecond($0).rounded()))" },
            progress: telemetry.progress,
            remaining: DriveFormat.distance(telemetry.distanceRemaining) + " left",
            eta: DriveFormat.eta(telemetry: telemetry, timeScale: timeScale ?? profile.timeScale),
            isPaused: paused,
            isStopped: telemetry.isStopped,
            isOverLimit: telemetry.isOverLimit && profile.warnWhenOverLimit
        )
    }

    /// Fuel and CO₂ for a distance driven. Garnish — it is the profile's flat
    /// L/100 km figure times the distance, not anything the simulation measured,
    /// and the UI says so.
    func tripEconomy(distance: CLLocationDistance) -> (litres: Double, gramsCO2: Double) {
        let litres = (distance / 1000) * (drive.consumption / 100)
        // ~2.31 kg CO₂ per litre of petrol burnt.
        return (litres, litres * 2310)
    }

    // MARK: - Places

    @discardableResult
    func addFavorite(name: String, coordinate: CLLocationCoordinate2D, emoji: String? = nil) -> SavedPlace {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = SavedPlace(
            name: trimmed.isEmpty ? Self.coordinateLabel(coordinate) : trimmed,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            emoji: emoji
        )

        // Matching on coordinate rather than id: ids are unique now, so
        // "already starred this spot" is a question about where it is.
        if let existing = favorites.first(where: { $0.isAt(coordinate) }) {
            // Don't let a generic star overwrite a named favourite for the same spot.
            if Self.isGenericFavoriteName(place.name), !Self.isGenericFavoriteName(existing.name) {
                return existing
            }
            // Starring the same spot again from the Pro map carries no emoji;
            // keeping the one it already had beats blanking it because the tap
            // came from a screen that doesn't show them.
            if place.emoji == nil, let kept = existing.emoji {
                return replace(existing, with: SavedPlace(
                    name: place.name,
                    latitude: place.latitude,
                    longitude: place.longitude,
                    emoji: kept,
                    id: existing.id
                ))
            }
            favorites.removeAll { $0.isAt(coordinate) }
        }

        favorites.insert(place, at: 0)
        SavedPlace.save(favorites, key: favoritesKey)
        return place
    }

    /// True when this spot is already starred — so the map can show a filled
    /// star instead of offering to save it twice.
    func isFavorite(_ coordinate: CLLocationCoordinate2D) -> Bool {
        favorites.contains { $0.isAt(coordinate) }
    }

    func removeFavorite(at coordinate: CLLocationCoordinate2D) {
        favorites.removeAll { $0.isAt(coordinate) }
        SavedPlace.save(favorites, key: favoritesKey)
    }

    /// Favourites are an ordered list people curate; the order should be theirs.
    func moveFavorites(from offsets: IndexSet, to destination: Int) {
        favorites.move(fromOffsets: offsets, toOffset: destination)
        SavedPlace.save(favorites, key: favoritesKey)
    }

    func renameFavorite(_ place: SavedPlace, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = favorites.firstIndex(where: { $0.id == place.id }) else { return }
        favorites[index].name = trimmed
        SavedPlace.save(favorites, key: favoritesKey)
    }

    /// Renames a favourite and sets the emoji Fun mode shows it with, together.
    ///
    /// The spot sheet edits both at once, and an empty name means "leave it" —
    /// clearing the field shouldn't be able to leave a place called nothing.
    func updateFavorite(_ place: SavedPlace, name: String, emoji: String?) {
        guard let index = favorites.firstIndex(where: { $0.id == place.id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { favorites[index].name = trimmed }
        favorites[index].emoji = emoji
        SavedPlace.save(favorites, key: favoritesKey)
    }

    /// Swaps a favourite for an edited copy, keeping its place in the list.
    @discardableResult
    private func replace(_ existing: SavedPlace, with place: SavedPlace) -> SavedPlace {
        guard let index = favorites.firstIndex(where: { $0.id == existing.id }) else {
            favorites.insert(place, at: 0)
            SavedPlace.save(favorites, key: favoritesKey)
            return place
        }
        favorites[index] = place
        SavedPlace.save(favorites, key: favoritesKey)
        return place
    }

    func removeFavorite(_ place: SavedPlace) {
        favorites.removeAll { $0.id == place.id }
        SavedPlace.save(favorites, key: favoritesKey)
    }

    func removeRecent(_ place: SavedPlace) {
        recents.removeAll { $0.id == place.id }
        SavedPlace.save(recents, key: recentsKey)
    }

    /// Best display name for starring the current pin (search title, matching recent, etc.).
    func suggestedFavoriteName(for coordinate: CLLocationCoordinate2D, fallback: String? = nil) -> String {
        if let fallback, !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // A resolved address beats every other guess here, and beats the
        // coordinate label by a mile.
        if let address = places.address(for: coordinate) {
            return address
        }
        if let favorite = favorites.first(where: { $0.isAt(coordinate) }),
           !Self.isGenericFavoriteName(favorite.name) {
            return favorite.name
        }
        if let recent = recents.first(where: { $0.isAt(coordinate) }),
           !Self.isGenericFavoriteName(recent.name) {
            return recent.name
        }
        return Self.coordinateLabel(coordinate)
    }

    private static func coordinateLabel(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
    }

    private static func isGenericFavoriteName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "Favorite" { return true }
        // Coordinate-looking labels from older teleports.
        let parts = trimmed.split(separator: ",")
        if parts.count == 2,
           Double(parts[0].trimmingCharacters(in: .whitespaces)) != nil,
           Double(parts[1].trimmingCharacters(in: .whitespaces)) != nil {
            return true
        }
        return false
    }

    // MARK: - Engine

    /// How the simulated phone is moving, for the engine that can say so.
    struct Motion {
        var speed: CLLocationSpeed
        var course: CLLocationDirection?

        static let stationary = Motion(speed: 0, course: nil)
    }

    /// One fix through whichever engine is in use.
    ///
    /// `coordinate` is in map space; this is the one place it leaves the app,
    /// so this is where a GCJ-02 map coordinate becomes the WGS-84 the
    /// location system expects.
    private func send(
        _ coordinate: CLLocationCoordinate2D,
        through engine: LocationBackend,
        motion: Motion?,
        pairing: PairingStore
    ) async -> Result<Void, LocationEngineError> {
        let wire = MapDatumMode.current.toWGS84(coordinate)
        switch engine {
        case .direct:
            return await DirectLocationEngine.set(DirectLocationEngine.Fix(
                coordinate: wire,
                altitude: DirectSimulationOptions.altitude,
                speed: motion?.speed,
                course: motion?.course
            ))
        case .tunnel:
            return await LocationEngine.set(
                latitude: wire.latitude,
                longitude: wire.longitude,
                pairingPath: pairing.pairingPath,
                deviceIP: TunnelConfig.targetIP
            )
        }
    }

    /// Sends one fix and folds the outcome back into the session's state.
    ///
    /// The suspension is the whole point: the engine call is a round trip over
    /// the tunnel, and it used to run synchronously from the main actor — so
    /// the map froze for its duration on every fix.
    /// - Parameter interactive: whether this fix is one somebody is waiting on.
    ///   `isBusy` only disables the Teleport button, and a route or the joystick
    ///   sets it true and false again several times a second — two published
    ///   changes per fix, each of which invalidates every view watching the
    ///   session, including the map and its route overlay.
    private func apply(
        _ coordinate: CLLocationCoordinate2D,
        pairing: PairingStore,
        markRecent: Bool,
        interactive: Bool = false,
        motion: Motion? = nil
    ) async {
        if status == .idle || status.isDropped {
            status = .connecting
        }
        let engine = backend
        if interactive { isBusy = true }
        let result = await send(coordinate, through: engine, motion: motion, pairing: pairing)
        if interactive { isBusy = false }
        switch result {
        case .success:
            simulated = coordinate
            pin = coordinate
            status = .active
            lastError = nil
            activeBackend = engine
            lastFixWasMoving = engine == .direct && (motion?.speed ?? 0) > 0.05
            locationKeeper.start()
            followTimeZone(to: coordinate, force: markRecent)
            switch engine {
            case .direct:
                // Nothing to keep alive and nothing that can drop: the
                // simulation is `locationd`'s now. Remembered so the next
                // launch knows it is still running.
                DirectSimulationRecord.save(coordinate)
                if interactive, directCheck == .notRun {
                    checkDirectSimulation()
                }
            case .tunnel:
                beginBackground()
                startResend(pairing: pairing)
                startHealth(pairing: pairing)
            }
            // Ask now, while it is working, rather than at the moment it breaks.
            requestDropAlertsIfNeeded()
            if markRecent {
                pushRecent(coordinate)
                // Only for a deliberate teleport: the health timer and the route
                // walker both come through here, and buzzing once a second for
                // an hour is not confirmation, it's a fault.
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                flash("Now at \(suggestedFavoriteName(for: coordinate))")
            }
        case .failure(let error):
            lastError = error.localizedDescription
            if simulated != nil {
                status = .dropped(error.localizedDescription)
                postDropNotification(error.localizedDescription)
            } else {
                status = .idle
            }
        }
    }

    /// Both timers are started from `apply`, which runs up to four times a
    /// second for the length of a route — so they used to be torn down and
    /// rebuilt eight times a second, each rebuild an allocation and two run-loop
    /// edits. The one already running is the one we want; `stopResend` /
    /// `stopHealth` are what end them.
    private func startResend(pairing: PairingStore) {
        guard resendTimer == nil else { return }
        resendTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let sim = self.simulated else { return }
                // A route re-sends far more often than this on its own; resending
                // underneath it would fight the walker for the current fix.
                guard !self.isRouting else { return }
                _ = await self.send(sim, through: .tunnel, motion: nil, pairing: pairing)
            }
        }
    }

    /// Asks iOS to move the clock to wherever the location now is — on every
    /// deliberate teleport, and during a drive only once it has crossed enough
    /// ground to plausibly be in another zone. Asking four times a second for
    /// an hour would be asking `timed` to do nothing else.
    private func followTimeZone(to coordinate: CLLocationCoordinate2D, force: Bool) {
        if !force, let anchor = timeZoneAnchor, Geo.distance(anchor, coordinate) < 25_000 { return }
        timeZoneAnchor = coordinate
        TimeZoneFollower.requestUpdate()
    }

    private func stopResend() {
        resendTimer?.invalidate()
        resendTimer = nil
    }

    private func startHealth(pairing: PairingStore) {
        guard healthTimer == nil else { return }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let sim = self.simulated else { return }
                // Only the tunnel engine's session can die under it.
                guard self.activeBackend == .tunnel else { return }
                if case .dropped = self.status {
                    self.status = .reconnecting
                    await self.apply(sim, pairing: pairing, markRecent: false)
                } else if !LocationEngine.isSessionActive, self.isSpoofing {
                    self.status = .reconnecting
                    await self.apply(sim, pairing: pairing, markRecent: false)
                }
            }
        }
    }

    private func stopHealth() {
        healthTimer?.invalidate()
        healthTimer = nil
    }

    private func pushRecent(_ coordinate: CLLocationCoordinate2D) {
        // The best name there is for this spot, not its latitude. Teleporting
        // to somewhere you had searched for by name used to rewrite that recent
        // as "48.85837, 2.29448".
        pushNamedRecent(name: suggestedFavoriteName(for: coordinate), coordinate: coordinate)
    }

    func pushNamedRecent(name: String, coordinate: CLLocationCoordinate2D) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var label = trimmed.isEmpty ? Self.coordinateLabel(coordinate) : trimmed
        // A coordinate label never wins against a name this spot already had.
        if Self.isGenericFavoriteName(label),
           let existing = recents.first(where: { $0.isAt(coordinate) }),
           !Self.isGenericFavoriteName(existing.name) {
            label = existing.name
        }

        let place = SavedPlace(
            name: label,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
        recents.removeAll { $0.isAt(coordinate) }
        recents.insert(place, at: 0)
        if recents.count > 20 { recents = Array(recents.prefix(20)) }
        SavedPlace.save(recents, key: recentsKey)
    }

    private func beginBackground() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.endBackground()
        }
    }

    private func endBackground() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// Asks for notification permission once, while something is working.
    ///
    /// It used to be requested at the moment of a drop, with the alert posted
    /// immediately after and without waiting for an answer — so the very first
    /// drop, the one that teaches you the feature exists, was always silent.
    /// Asking here means the prompt arrives with context ("this app just
    /// started spoofing") and the alert lands the first time it is needed.
    private static var hasAskedAboutNotifications = false

    private func requestDropAlertsIfNeeded() {
        guard !Self.hasAskedAboutNotifications else { return }
        Self.hasAskedAboutNotifications = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func postDropNotification(_ message: String) {
        let content = UNMutableNotificationContent()
        content.title = "Locus spoof dropped"
        content.body = message
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                center.add(request)
            case .notDetermined:
                // Belt and braces: if the ask above never happened, do it now
                // and post only once there is an answer.
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { center.add(request) }
                }
            default:
                // Denied. The status bar and the in-app alert still say so.
                break
            }
        }
    }
}
