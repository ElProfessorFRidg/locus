import Foundation

/// What `locus-state.json` and `locus-routes.json` say, as plain values.
///
/// Kept apart from the session so the JSON shape — which a web UI on the other
/// end depends on — is pinned by tests rather than by whatever the session
/// happens to publish this week. Optionals are written as explicit `null`s, not
/// left out: a reader should be able to tell "no route" from "an older build".
struct RemoteState: Equatable, Encodable {
    struct Position: Equatable, Encodable {
        var lat: Double
        var lon: Double
    }

    struct Route: Equatable, Encodable {
        var name: String
        /// 0 ... 100.
        var progressPct: Double
        var paused: Bool
    }

    struct LastCommand: Equatable, Encodable {
        var name: String
        var ts: Int
        var ok: Bool
        var error: String?

        enum CodingKeys: String, CodingKey { case name, ts, ok, error }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            try c.encode(ts, forKey: .ts)
            try c.encode(ok, forKey: .ok)
            try c.encode(error, forKey: .error)
        }
    }

    /// Epoch seconds.
    var ts: Int
    /// `direct` or `tunnel`.
    var engine: String
    /// `idle`, `connecting`, `active`, `reconnecting` or `dropped`.
    var status: String
    var simulating: Bool
    /// `idle`, `teleport`, `route` or `joystick`.
    var mode: String
    /// WGS-84, as handed to the engine.
    var position: Position?
    var route: Route?
    var speedKmh: Double?
    /// 0 none, 1 loop, 2 back and forth, 3 return once.
    var loop: Int?
    var timeScale: Double?
    var profile: String?
    /// `direct`, `up`, `down` or `n/a`.
    var tunnel: String
    var lastCommand: LastCommand?
    var error: String?
    var version: String

    enum CodingKeys: String, CodingKey {
        case ts, engine, status, simulating, mode, position, route, speedKmh, loop
        case timeScale, profile, tunnel, lastCommand, error, version
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ts, forKey: .ts)
        try c.encode(engine, forKey: .engine)
        try c.encode(status, forKey: .status)
        try c.encode(simulating, forKey: .simulating)
        try c.encode(mode, forKey: .mode)
        try c.encode(position, forKey: .position)
        try c.encode(route, forKey: .route)
        try c.encode(speedKmh, forKey: .speedKmh)
        try c.encode(loop, forKey: .loop)
        try c.encode(timeScale, forKey: .timeScale)
        try c.encode(profile, forKey: .profile)
        try c.encode(tunnel, forKey: .tunnel)
        try c.encode(lastCommand, forKey: .lastCommand)
        try c.encode(error, forKey: .error)
        try c.encode(version, forKey: .version)
    }

    /// The same state a moment later, ignoring the clock — what decides whether
    /// a rewrite would say anything new.
    func sameContent(as other: RemoteState) -> Bool {
        var a = self
        a.ts = other.ts
        return a == other
    }

    func jsonData() throws -> Data {
        try RemoteJSON.encoder.encode(self)
    }
}

/// One entry of `locus-routes.json`.
struct RemoteRouteEntry: Equatable, Encodable {
    var id: String
    var name: String
    var journey: String?
    var distanceM: Double
    var timesDriven: Int
    /// Epoch seconds.
    var lastDriven: Int?

    enum CodingKeys: String, CodingKey { case id, name, journey, distanceM, timesDriven, lastDriven }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(journey, forKey: .journey)
        try c.encode(distanceM, forKey: .distanceM)
        try c.encode(timesDriven, forKey: .timesDriven)
        try c.encode(lastDriven, forKey: .lastDriven)
    }

    static func jsonData(_ entries: [RemoteRouteEntry]) throws -> Data {
        try RemoteJSON.encoder.encode(entries)
    }
}

/// `results/<id>.json`: what became of one inbox file.
struct RemoteResult: Equatable, Encodable {
    var id: String
    var cmd: String
    var ok: Bool
    var error: String?
    var ts: Int
    /// The same object as `locus-state.json`, after the command settled.
    var state: RemoteState?

    enum CodingKeys: String, CodingKey { case id, cmd, ok, error, ts, state }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(cmd, forKey: .cmd)
        try c.encode(ok, forKey: .ok)
        try c.encode(error, forKey: .error)
        try c.encode(ts, forKey: .ts)
        try c.encode(state, forKey: .state)
    }

    func jsonData() throws -> Data { try RemoteJSON.encoder.encode(self) }
}

enum RemoteJSON {
    /// Sorted keys so the files diff cleanly and tests can compare text.
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
