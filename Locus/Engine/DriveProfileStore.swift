import Foundation

/// The named set of driving profiles, and which one is in use.
///
/// One profile made sense when there were four parameters. There are thirty
/// now, and they pull in incompatible directions — a commute wants road limits,
/// heavy traffic and junction stops; walking a park wants a fixed 1.4 m/s and
/// none of it. Retuning a dozen sliders to switch between those is not a
/// settings screen, it's a chore, so profiles are named and switched instead.
@MainActor
final class DriveProfileStore: ObservableObject {
    @Published private(set) var profiles: [DriveProfile] = []
    @Published private(set) var activeID: UUID

    private enum Keys {
        static let profiles = "locus.driveProfiles"
        static let activeID = "locus.driveProfile.active"
        /// The single-profile key this replaced. Read once, then left alone.
        static let legacyProfile = "locus.driveProfile"
    }

    init() {
        let stored = Self.loadProfiles()
        let resolved = stored.isEmpty ? [Self.migratedOrDefault()] : stored
        let savedID = UserDefaults.standard.string(forKey: Keys.activeID).flatMap(UUID.init(uuidString:))

        // Both are computed from `resolved` rather than from `profiles`: reading
        // a @Published property goes through its wrapper, which counts as using
        // `self` — not allowed until every stored property is initialised, and
        // `activeID` has no default to fall back on.
        activeID = resolved.first { $0.id == savedID }?.id ?? resolved[0].id
        profiles = resolved

        if stored.isEmpty { persist() }
    }

    /// The profile in use. Setting it writes through, so an edit in the settings
    /// sheet is saved without anyone having to remember to call `save()`.
    var active: DriveProfile {
        get { profiles.first { $0.id == activeID } ?? profiles[0] }
        set { update(newValue) }
    }

    func profile(_ id: UUID) -> DriveProfile? {
        profiles.first { $0.id == id }
    }

    func select(_ id: UUID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        activeID = id
        UserDefaults.standard.set(id.uuidString, forKey: Keys.activeID)
    }

    /// Writes a profile back into the list, matching on id.
    func update(_ profile: DriveProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        guard profiles[index] != profile else { return }
        profiles[index] = profile
        persist()
    }

    @discardableResult
    func add(named name: String, from template: DriveProfile? = nil) -> DriveProfile {
        var profile = template ?? DriveProfile()
        profile.id = UUID()
        profile.name = Self.uniqueName(name, among: profiles)
        profiles.append(profile)
        persist()
        select(profile.id)
        return profile
    }

    @discardableResult
    func duplicate(_ profile: DriveProfile) -> DriveProfile {
        add(named: "\(profile.name) copy", from: profile)
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].name = Self.uniqueName(trimmed, among: profiles.filter { $0.id != id })
        persist()
    }

    /// Removing the last profile would leave nothing to drive with, so the list
    /// never empties — deleting the only one resets it instead.
    func delete(_ id: UUID) {
        guard profiles.count > 1 else {
            profiles = [DriveProfile(name: "Default")]
            select(profiles[0].id)
            persist()
            return
        }
        profiles.removeAll { $0.id == id }
        persist()
        if activeID == id {
            select(profiles[0].id)
        }
    }

    /// Profiles worth having on a fresh install, offered rather than imposed —
    /// the point is that switching beats retuning, which only shows if there is
    /// something to switch to.
    static let starters: [(name: String, build: () -> DriveProfile)] = [
        ("Commute", {
            var p = DriveProfile(name: "Commute")
            p.speedSource = .roadLimit
            p.speedTolerance = 0.10
            p.traffic = .normal
            p.stopAtJunctions = true
            p.apply(.sedan)
            return p
        }),
        ("Motorway", {
            var p = DriveProfile(name: "Motorway")
            p.speedSource = .roadLimit
            p.speedTolerance = 0.05
            p.traffic = .light
            p.stopAtJunctions = false
            p.junctionStopChance = 0
            p.cornering = .brisk
            return p
        }),
        ("On foot", {
            var p = DriveProfile(name: "On foot")
            p.speedSource = .travelMode
            p.traffic = .none
            p.stopAtJunctions = false
            p.gpsNoiseMetres = 4
            p.laneOffsetMetres = 0
            p.speedJitter = 0.12
            p.vehicle = .custom
            p.acceleration = 1.0
            p.braking = 1.4
            p.cornering = .chauffeur
            return p
        }),
        ("Delivery round", {
            var p = DriveProfile(name: "Delivery round")
            p.speedSource = .roadLimit
            p.speedTolerance = -0.05
            p.traffic = .heavy
            p.stopAtJunctions = true
            p.junctionStopChance = 0.7
            p.junctionStopSeconds = ClosedRangeBox(lower: 20, upper: 90)
            p.apply(.van)
            return p
        }),
    ]

    // MARK: - Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: Keys.profiles)
        UserDefaults.standard.set(activeID.uuidString, forKey: Keys.activeID)
    }

    private static func loadProfiles() -> [DriveProfile] {
        guard let data = UserDefaults.standard.data(forKey: Keys.profiles),
              let decoded = try? JSONDecoder().decode([DriveProfile].self, from: data),
              !decoded.isEmpty else { return [] }
        return decoded
    }

    /// Carries over the settings from before profiles existed, rather than
    /// resetting anyone who had tuned them.
    private static func migratedOrDefault() -> DriveProfile {
        guard let data = UserDefaults.standard.data(forKey: Keys.legacyProfile),
              var migrated = try? JSONDecoder().decode(DriveProfile.self, from: data) else {
            return DriveProfile(name: "Default")
        }
        migrated.name = "Default"
        return migrated
    }

    private static func uniqueName(_ name: String, among others: [DriveProfile]) -> String {
        let taken = Set(others.map(\.name))
        guard taken.contains(name) else { return name }
        var suffix = 2
        while taken.contains("\(name) \(suffix)") { suffix += 1 }
        return "\(name) \(suffix)"
    }
}
