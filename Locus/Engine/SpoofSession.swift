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
    @Published var isBusy = false
    @Published var joystickActive = false

    @Published var favorites: [SavedPlace] = []
    @Published var recents: [SavedPlace] = []

    /// Everything about how a route is driven. Persisted on every change so the
    /// sheet can bind straight to it.
    @Published var drive: DriveProfile {
        didSet { if drive != oldValue { drive.save() } }
    }

    /// Non-nil while a route is playing.
    @Published private(set) var telemetry: DriveTelemetry?
    /// Non-nil while the joystick is on. The route HUD's smaller sibling: the
    /// joystick moved you at a speed you set and never showed you either it or
    /// how far you'd gone.
    @Published private(set) var joystick: JoystickTelemetry?
    @Published private(set) var isRoutePaused = false
    /// Countdown before the first fix, when `drive.startDelaySeconds` is set.
    @Published private(set) var routeCountdown: Int?

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
    private let locationKeeper = BackgroundKeepAlive()

    /// Reverse-geocodes the pin so coordinates aren't the only thing on screen.
    /// Owned here rather than by a view so a starred favourite can be named
    /// after the place instead of its latitude.
    let places = PlaceResolver()

    private let favoritesKey = "locus.favorites"
    private let recentsKey = "locus.recents"

    private var cancellables = Set<AnyCancellable>()

    init() {
        drive = DriveProfile.load()
        favorites = SavedPlace.load(key: favoritesKey)
        recents = SavedPlace.load(key: recentsKey)

        // A nested ObservableObject doesn't propagate: views watching the
        // session would never redraw when an address resolves.
        places.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
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
            self.apply(coordinate, pairing: pairing, markRecent: true)
        }
    }

    func stop(pairing: PairingStore) {
        cancelRoute()
        stopJoystick()
        stopResend()
        stopHealth()
        isBusy = true
        let result = LocationEngine.clear()
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
                self.apply(start, pairing: pairing, markRecent: false)
            }
            self.joystickActive = true
            self.joystick = JoystickTelemetry()
            self.joystickTimer?.invalidate()
            self.joystickTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.tickJoystick(pairing: pairing)
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
    }

    /// Top speed the joystick moves at. A fixed speed set for routes is an
    /// explicit "go this fast" and applies here too; otherwise the travel mode
    /// decides, as before.
    private var joystickTopSpeed: CLLocationSpeed {
        drive.speedSource == .fixed
            ? max(0.3, drive.fixedSpeedMetresPerSecond)
            : travelMode.baseSpeed
    }

    private func tickJoystick(pairing: PairingStore) {
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

        apply(next, pairing: pairing, markRecent: false)
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
        expectedSpeed: CLLocationSpeed? = nil
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
            routeExpectedSpeed: expectedSpeed
        )
        guard !basePlan.isEmpty else {
            lastError = "That route is too short to drive."
            return
        }

        isRoutePaused = false
        telemetry = DriveTelemetry(totalDistance: basePlan.totalDistance)

        routeGeneration += 1
        let generation = routeGeneration

        routeTask = Task { [weak self] in
            guard let self else { return }
            guard await self.prepareTunnel() else {
                self.finishRoute(generation: generation)
                return
            }
            await self.countDown(seconds: profile.startDelaySeconds)
            if !Task.isCancelled {
                await self.run(plan: basePlan, profile: profile, pairing: pairing)
            }
            self.finishRoute(generation: generation)
        }
    }

    private func finishRoute(generation: Int) {
        guard generation == routeGeneration else { return }
        routeTask = nil
        telemetry = nil
        isRoutePaused = false
        routeCountdown = nil
    }

    func pauseRoute() { isRoutePaused = true }
    func resumeRoute() { isRoutePaused = false }

    func toggleRoutePause() {
        isRoutePaused.toggle()
    }

    func cancelRoute() {
        routeGeneration += 1
        routeTask?.cancel()
        routeTask = nil
        telemetry = nil
        isRoutePaused = false
        routeCountdown = nil
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
    private func run(plan: RoutePlan, profile: DriveProfile, pairing: PairingStore) async {
        let dt = profile.updateInterval
        let scale = max(0.05, profile.timeScale)
        let realInterval = UInt64((dt / scale) * 1_000_000_000)

        var current = plan
        var lap = 1

        while !Task.isCancelled {
            let walker = DriveWalker(plan: current, profile: profile)

            while !Task.isCancelled, let fix = walker.step(dt: dt) {
                while isRoutePaused, !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                guard !Task.isCancelled else { return }

                apply(fix.coordinate, pairing: pairing, markRecent: false)
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

                try? await Task.sleep(nanoseconds: realInterval)
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

    /// Fuel and CO₂ for a distance driven. Garnish — it is the profile's flat
    /// L/100 km figure times the distance, not anything the simulation measured,
    /// and the UI says so.
    func tripEconomy(distance: CLLocationDistance) -> (litres: Double, gramsCO2: Double) {
        let litres = (distance / 1000) * (drive.consumption / 100)
        // ~2.31 kg CO₂ per litre of petrol burnt.
        return (litres, litres * 2310)
    }

    // MARK: - Places

    func addFavorite(name: String, coordinate: CLLocationCoordinate2D) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = SavedPlace(
            name: trimmed.isEmpty ? Self.coordinateLabel(coordinate) : trimmed,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
        // Don't let a generic star overwrite a named favorite for the same spot.
        if let existing = favorites.first(where: { $0.id == place.id }),
           Self.isGenericFavoriteName(place.name),
           !Self.isGenericFavoriteName(existing.name) {
            return
        }
        favorites.removeAll { $0.id == place.id }
        favorites.insert(place, at: 0)
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
        if let favorite = favorites.first(where: { $0.id == SavedPlace(name: "", latitude: coordinate.latitude, longitude: coordinate.longitude).id }),
           !Self.isGenericFavoriteName(favorite.name) {
            return favorite.name
        }
        if let recent = recents.first(where: {
            abs($0.latitude - coordinate.latitude) < 0.00015 && abs($0.longitude - coordinate.longitude) < 0.00015
        }), !Self.isGenericFavoriteName(recent.name) {
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

    private func apply(_ coordinate: CLLocationCoordinate2D, pairing: PairingStore, markRecent: Bool) {
        if status == .idle || status.isDropped {
            status = .connecting
        }
        isBusy = true
        let result = LocationEngine.set(
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
            if markRecent {
                pushRecent(coordinate)
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
                _ = LocationEngine.set(
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
                    self.apply(sim, pairing: pairing, markRecent: false)
                } else if !LocationEngine.isSessionActive, self.isSpoofing {
                    self.status = .reconnecting
                    self.apply(sim, pairing: pairing, markRecent: false)
                }
            }
        }
    }

    private func stopHealth() {
        healthTimer?.invalidate()
        healthTimer = nil
    }

    private func pushRecent(_ coordinate: CLLocationCoordinate2D) {
        pushNamedRecent(
            name: Self.coordinateLabel(coordinate),
            coordinate: coordinate
        )
    }

    func pushNamedRecent(name: String, coordinate: CLLocationCoordinate2D) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = SavedPlace(
            name: trimmed.isEmpty ? Self.coordinateLabel(coordinate) : trimmed,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
        recents.removeAll {
            abs($0.latitude - place.latitude) < 0.00015 && abs($0.longitude - place.longitude) < 0.00015
        }
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

    private func postDropNotification(_ message: String) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = "Locus spoof dropped"
        content.body = message
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
