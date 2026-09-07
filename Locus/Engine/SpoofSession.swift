import Combine
import CoreLocation
import Foundation
import MapKit
import UIKit
import UserNotifications

enum TravelMode: String, CaseIterable, Identifiable {
    case walk, run, cycle, drive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .walk: return "Walk"
        case .run: return "Run"
        case .cycle: return "Cycle"
        case .drive: return "Drive"
        }
    }

    var icon: String {
        switch self {
        case .walk: return "figure.walk"
        case .run: return "figure.run"
        case .cycle: return "bicycle"
        case .drive: return "car.fill"
        }
    }

    /// Base metres per second before natural variation.
    var baseSpeed: CLLocationSpeed {
        switch self {
        case .walk: return 1.4
        case .run: return 3.3
        case .cycle: return 6.5
        case .drive: return 13.4
        }
    }

    var mkTransportType: MKDirectionsTransportType {
        switch self {
        case .walk, .run: return .walking
        case .cycle, .drive: return .automobile
        }
    }

    /// Only driving gets the full parameter set; the rest borrow the physics but
    /// the UI leads with different defaults.
    var usesRoadLimits: Bool { self == .drive || self == .cycle }
}

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

    var averageSpeed: CLLocationSpeed {
        simulatedSeconds > 1 ? distance / simulatedSeconds : 0
    }
}

/// Live state of a route being driven, for the HUD.
struct DriveTelemetry: Equatable {
    var speed: CLLocationSpeed = 0
    /// Estimated posted limit here, or `nil` when not driving to limits.
    var speedLimit: CLLocationSpeed?
    var course: CLLocationDirection = 0
    var progress: Double = 0
    var distanceTravelled: CLLocationDistance = 0
    var distanceRemaining: CLLocationDistance = 0
    /// Simulated seconds — with `timeScale` above 1 this runs ahead of the clock.
    var elapsed: TimeInterval = 0
    var isStopped = false
    var isOverLimit = false
    /// 1 on the first pass, 2 on the way back, and so on.
    var lap: Int = 1
    var totalDistance: CLLocationDistance = 0
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
    }

    /// Holds the display awake while there is something moving on it.
    ///
    /// Called from every place that starts or ends a drive or the joystick, and
    /// again when the profile's toggle changes — iOS resets this on its own when
    /// the app is backgrounded, so it costs nothing to set more often than
    /// strictly needed and everything to set it less.
    private func refreshIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = drive.keepScreenAwake && (isRouting || joystickActive)
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

    // MARK: - Teleport

    func teleport(to coordinate: CLLocationCoordinate2D, pairing: PairingStore) {
        guard pairing.hasPairingFile else {
            lastError = "Import an RPPairing file in Settings first."
            return
        }
        setPin(coordinate)
        Task { [weak self] in
            guard let self else { return }
            guard await self.prepareTunnel() else { return }
            await self.apply(coordinate, pairing: pairing, markRecent: true)
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
        cancelRoute()
        stopJoystick()
        stopResend()
        stopHealth()
        isBusy = true
        finishStop(await LocationEngine.clear())
    }

    private func finishStop(_ result: Result<Void, LocationEngineError>) {
        isBusy = false
        switch result {
        case .success:
            simulated = nil
            status = .idle
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
    var realCoordinate: CLLocationCoordinate2D? {
        locationKeeper.lastKnownCoordinate
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
        guard pairing.hasPairingFile else {
            lastError = "Import an RPPairing file in Settings first."
            return
        }
        let start = simulated ?? pin ?? locationKeeper.lastKnownCoordinate
        guard let start else {
            lastError = "Drop a pin or teleport somewhere before using the joystick."
            return
        }
        cancelRoute()
        Task { [weak self] in
            guard let self else { return }
            guard await self.prepareTunnel() else { return }
            if self.simulated == nil {
                await self.apply(start, pairing: pairing, markRecent: false)
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

    func stopJoystick() {
        joystickActive = false
        joystickVector = .zero
        joystick = nil
        joystickTimer?.invalidate()
        joystickTimer = nil
        refreshIdleTimer()
    }

    /// Top speed the joystick moves at. A fixed speed set for routes is an
    /// explicit "go this fast" and applies here too; otherwise the travel mode
    /// decides, as before.
    private var joystickTopSpeed: CLLocationSpeed {
        drive.speedSource == .fixed
            ? max(0.3, drive.fixedSpeedMetresPerSecond)
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
            return
        }

        let nx = joystickVector.dx / magnitude
        let ny = -joystickVector.dy / magnitude
        let jitter = 1 + Double.random(in: -1...1) * drive.speedJitter
        let speed = joystickTopSpeed * min(1.0, magnitude) * jitter
        let dt = 0.25
        let meters = speed * dt
        let next = Geo.offset(current, east: nx * meters, north: ny * meters)

        joystick?.speed = speed
        joystick?.course = Geo.bearing(from: current, to: next)
        joystick?.distance += meters

        await apply(next, pairing: pairing, markRecent: false)
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
        startingAt startDistance: CLLocationDistance = 0
    ) {
        guard pairing.hasPairingFile else {
            lastError = "Import an RPPairing file in Settings first."
            return
        }
        guard coordinates.count >= 2 else {
            lastError = "Build or draw a route first."
            return
        }

        cancelRoute()
        stopJoystick()
        // The pin is about to move every second; an address for where it
        // started would only go stale and mislead.
        places.clear()

        let profile = drive
        let mode = travelMode
        let basePlan = RouteSimulator.plan(
            coordinates: coordinates,
            profile: profile,
            mode: mode,
            routeExpectedSpeed: expectedSpeed,
            overrides: overrides,
            recordedSpeed: recordedSpeed
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
                profileName: drive.name
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
    }

    func pauseRoute() { isRoutePaused = true }
    func resumeRoute() { isRoutePaused = false }

    func toggleRoutePause() {
        isRoutePaused.toggle()
        // Pausing is one of the few changes worth an immediate Live Activity
        // push rather than waiting out the throttle.
        if let telemetry, drive.showLiveActivity {
            LiveActivityController.shared.update(
                Self.activityState(for: telemetry, profile: drive, paused: isRoutePaused)
            )
        }
    }

    /// Stops the drive.
    ///
    /// - Parameter keepResumePoint: a deliberate stop discards where it got to;
    ///   starting a different route also does. The progress file is only there
    ///   for the drive nobody chose to end.
    func cancelRoute(keepResumePoint: Bool = false) {
        routeGeneration += 1
        routeTask?.cancel()
        routeTask = nil
        telemetry = nil
        isRoutePaused = false
        routeCountdown = nil
        LiveActivityController.shared.end()
        if !keepResumePoint { routeStore.clearResume() }
        refreshIdleTimer()
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
            startingAt: state.travelled
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
                let scale = max(0.05, drive.timeScale)

                await apply(fix.coordinate, pairing: pairing, markRecent: false)
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

                if fix.isOverLimit, profile.hapticOnLimitChange {
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.4)
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
    func addFavorite(name: String, coordinate: CLLocationCoordinate2D) -> SavedPlace {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = SavedPlace(
            name: trimmed.isEmpty ? Self.coordinateLabel(coordinate) : trimmed,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )

        // Matching on coordinate rather than id: ids are unique now, so
        // "already starred this spot" is a question about where it is.
        if let existing = favorites.first(where: { $0.isAt(coordinate) }) {
            // Don't let a generic star overwrite a named favourite for the same spot.
            if Self.isGenericFavoriteName(place.name), !Self.isGenericFavoriteName(existing.name) {
                return existing
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

    /// Sends one fix and folds the outcome back into the session's state.
    ///
    /// The suspension is the whole point: the engine call is a round trip over
    /// the tunnel, and it used to run synchronously from the main actor — so
    /// the map froze for its duration on every fix.
    private func apply(_ coordinate: CLLocationCoordinate2D, pairing: PairingStore, markRecent: Bool) async {
        if status == .idle || status.isDropped {
            status = .connecting
        }
        isBusy = true
        let result = await LocationEngine.set(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            pairingPath: pairing.pairingPath,
            deviceIP: TunnelConfig.targetIP
        )
        isBusy = false
        switch result {
        case .success:
            simulated = coordinate
            pin = coordinate
            status = .active
            lastError = nil
            beginBackground()
            locationKeeper.start()
            startResend(pairing: pairing)
            startHealth(pairing: pairing)
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

    private func startResend(pairing: PairingStore) {
        resendTimer?.invalidate()
        resendTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let sim = self.simulated else { return }
                // A route re-sends far more often than this on its own; resending
                // underneath it would fight the walker for the current fix.
                guard !self.isRouting else { return }
                _ = await LocationEngine.set(
                    latitude: sim.latitude,
                    longitude: sim.longitude,
                    pairingPath: pairing.pairingPath,
                    deviceIP: TunnelConfig.targetIP
                )
            }
        }
    }

    private func stopResend() {
        resendTimer?.invalidate()
        resendTimer = nil
    }

    private func startHealth(pairing: PairingStore) {
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let sim = self.simulated else { return }
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
