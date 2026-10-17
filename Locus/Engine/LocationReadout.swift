import Combine
import CoreLocation
import Foundation

/// Keeps what the readout panel and `locus-state.json` need that the session
/// doesn't: the last fix known to be *real*, and the verdict.
///
/// "Real" is harder than it sounds. Core Location reports the simulated spot
/// while a simulation is on, so its fix only counts as real while Locus isn't
/// simulating and no simulation record is waiting from earlier. That fix is
/// remembered across launches, so a phone that wakes up reporting somewhere
/// else can be compared with where it last honestly was.
@MainActor
final class LocationReadout: ObservableObject {
    static let shared = LocationReadout()

    struct RealFix: Codable, Equatable {
        var lat: Double
        var lon: Double
        var accuracy: Double
        var timestamp: Date
    }

    @Published private(set) var lastReal: RealFix?

    private weak var session: SpoofSession?
    private var cancellables = Set<AnyCancellable>()
    private static let defaultsKey = "locus.lastRealFix"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let stored = try? JSONDecoder().decode(RealFix.self, from: data) {
            lastReal = stored
        }
    }

    func start(session: SpoofSession) {
        guard self.session == nil else { return }
        self.session = session
        LocationProbe.shared.start()
        LocationProbe.shared.$reading
            .receive(on: DispatchQueue.main)
            .sink { [weak self] reading in self?.consider(reading) }
            .store(in: &cancellables)
    }

    private func consider(_ reading: LocationProbe.Reading?) {
        guard let reading, let session else { return }
        // Only while nothing is being simulated, and nothing left over from a
        // run that was: either would make this somebody's idea of "here".
        guard session.status == .idle, !session.isRouting, !session.joystickActive,
              DirectSimulationRecord.load() == nil,
              reading.isSimulatedBySoftware != true,
              reading.horizontalAccuracy >= 0 else { return }
        // A fix far from the last real one is only believed once this launch
        // has cleared a simulation itself; until then it may be one that
        // `locationd` is still holding, and adopting it would hide exactly
        // the case the badge is for.
        if let lastReal,
           ReadoutVerdict.distance(
               RemotePoint(lat: reading.coordinate.latitude, lon: reading.coordinate.longitude),
               RemotePoint(lat: lastReal.lat, lon: lastReal.lon)
           ) > ReadoutVerdict.suspiciousDistance,
           !session.clearedSimulationThisLaunch { return }
        let fix = RealFix(
            lat: reading.coordinate.latitude,
            lon: reading.coordinate.longitude,
            accuracy: reading.horizontalAccuracy,
            timestamp: reading.timestamp
        )
        guard fix != lastReal else { return }
        lastReal = fix
        if let data = try? JSONEncoder().encode(fix) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    // MARK: - Verdict

    static func statusName(_ status: SpoofStatus) -> String {
        switch status {
        case .idle: return "idle"
        case .connecting: return "connecting"
        case .active: return "active"
        case .reconnecting: return "reconnecting"
        case .dropped: return "dropped"
        }
    }

    func badge(session: SpoofSession) -> ReadoutBadge {
        let reading = LocationProbe.shared.reading
        return ReadoutVerdict.badge(
            status: Self.statusName(session.status),
            reportedBySoftware: reading?.isSimulatedBySoftware,
            reported: reading.map { RemotePoint(lat: $0.coordinate.latitude, lon: $0.coordinate.longitude) },
            lastReal: lastReal.map { RemotePoint(lat: $0.lat, lon: $0.lon) }
        )
    }
}
