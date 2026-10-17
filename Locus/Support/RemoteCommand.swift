import Foundation

/// `locus://drive`, `locus://route` and `locus://stop` — the URLs a jailbroken
/// device's owner can fire at the app over ssh (`uiopen "locus://…"`).
///
/// Everything here is pure on purpose: the grammar, the validation and the key
/// check are the part that decides whether a stray link can move a phone, so
/// they live apart from the session and the filesystem and are unit-tested
/// without either. `RemoteControl` is what acts on the result.
///
/// The grammar is strict. Unknown parameters, repeated parameters, empty values,
/// non-finite numbers and out-of-range numbers are all refused rather than
/// repaired — a command that quietly drives somewhere other than what was asked
/// is worse than one that says no.
struct RemoteCoordinate: Equatable {
    var latitude: Double
    var longitude: Double
}

struct RemoteDriveRequest: Equatable {
    var destination: RemoteCoordinate
    /// `nil`: start from where the phone currently is.
    var origin: RemoteCoordinate?
    var mode: TravelMode
    /// Name of an existing driving profile, as typed. Resolved by the caller,
    /// which owns the list.
    var profileName: String?
    /// Playback time scale, 0.5 ... 8.
    var timeScale: Double?
    var endBehavior: RouteEndBehavior?
}

enum RemoteCommand: Equatable {
    case drive(RemoteDriveRequest)
    case route(name: String)
    case stop
    /// Teleport, without needing a map on screen.
    case go(RemoteCoordinate)

    var name: String {
        switch self {
        case .drive: return "drive"
        case .route: return "route"
        case .stop: return "stop"
        case .go: return "go"
        }
    }
}

struct RemoteInboxCommand: Equatable {
    var id: String
    var command: RemoteCommand
}

struct RemoteCommandError: Error, Equatable {
    var message: String
    init(_ message: String) { self.message = message }
}

enum RemoteCommandParser {
    static let scheme = "locus"
    /// The commands that move (or stop) the phone, and so need the key. `teleport`
    /// and `pin` are not here: they keep their old behaviour untouched.
    static let commandNames: Set<String> = ["drive", "route", "stop", "go"]

    static let maxNameLength = 120
    static let maxKeyLength = 256
    static let speedRange: ClosedRange<Double> = 0.5...8

    private static let allowedParameters: [String: Set<String>] = [
        "drive": ["to", "from", "mode", "profile", "speed", "loop", "key"],
        "route": ["name", "key"],
        "stop": ["key"],
        "go": ["lat", "lon", "key"],
    ]

    /// The command a URL names, or `nil` when it is not one of ours.
    static func commandName(of url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme, let host = url.host?.lowercased(),
              commandNames.contains(host) else { return nil }
        return host
    }

    /// The `key=` value, percent-decoded, or `nil` when absent.
    static func key(in url: URL) -> String? {
        queryItems(url)?.first(where: { $0.name == "key" })?.value
    }

    static func parse(_ url: URL) -> Result<RemoteCommand, RemoteCommandError> {
        guard let command = commandName(of: url) else {
            return .failure(RemoteCommandError("not a remote command"))
        }
        guard let items = queryItems(url) else {
            return .failure(RemoteCommandError("malformed URL"))
        }

        // One value per parameter, and only the ones this command takes.
        var values: [String: String] = [:]
        let allowed = allowedParameters[command] ?? []
        for item in items {
            guard allowed.contains(item.name) else {
                return .failure(RemoteCommandError("unknown parameter for \(command)"))
            }
            guard values[item.name] == nil else {
                return .failure(RemoteCommandError("repeated parameter '\(item.name)'"))
            }
            guard let value = item.value, !value.isEmpty else {
                return .failure(RemoteCommandError("empty value for '\(item.name)'"))
            }
            values[item.name] = value
        }
        // Checked by the gate before this is reached, but a parser that is also
        // handed a key-less URL should say so rather than succeed.
        guard let key = values["key"], key.count <= maxKeyLength else {
            return .failure(RemoteCommandError("missing or oversized key"))
        }

        _ = key
        return build(command, values)
    }

    /// Turns validated-for-shape parameters into a typed command. Shared by the
    /// URL grammar and the inbox's JSON, so the two can't drift apart.
    private static func build(_ command: String, _ values: [String: String]) -> Result<RemoteCommand, RemoteCommandError> {
        switch command {
        case "stop":
            return .success(.stop)

        case "go":
            guard let rawLat = values["lat"], let rawLon = values["lon"] else {
                return .failure(RemoteCommandError("go needs lat= and lon="))
            }
            guard let latitude = number(rawLat), let longitude = number(rawLon),
                  (-90...90).contains(latitude), (-180...180).contains(longitude) else {
                return .failure(RemoteCommandError("lat=/lon= out of range or not a number"))
            }
            return .success(.go(RemoteCoordinate(latitude: latitude, longitude: longitude)))

        case "route":
            guard let raw = values["name"] else {
                return .failure(RemoteCommandError("route needs name="))
            }
            switch validatedName(raw, field: "name") {
            case .success(let name): return .success(.route(name: name))
            case .failure(let error): return .failure(error)
            }

        default:
            return parseDrive(values)
        }
    }

    // MARK: - Inbox (JSON files)

    static let maxInboxBytes = 4096

    /// 6-32 lowercase hex characters.
    static func isValidInboxID(_ id: String) -> Bool {
        (6...32).contains(id.utf8.count) && id.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }

    /// Best-effort command name of a file that may not be valid, for its result.
    static func inboxCommandName(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cmd = object["cmd"] as? String, commandNames.contains(cmd) else { return "unknown" }
        return cmd
    }

    /// `{"id":"<hex>","cmd":"go|drive|route|stop","args":{…}}`.
    ///
    /// No key: whoever can write the inbox directory could already read the key
    /// file, since both sit behind the same sandbox exception. Everything else is
    /// held to the URL grammar's rules by feeding the same builder.
    static func parseInbox(_ data: Data, fileID: String) -> Result<RemoteInboxCommand, RemoteCommandError> {
        guard isValidInboxID(fileID) else { return .failure(RemoteCommandError("bad file name")) }
        guard data.count <= maxInboxBytes else { return .failure(RemoteCommandError("file too large")) }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(RemoteCommandError("not a JSON object"))
        }
        guard object["id"] as? String == fileID else {
            return .failure(RemoteCommandError("id does not match the file name"))
        }
        guard let cmd = object["cmd"] as? String, commandNames.contains(cmd) else {
            return .failure(RemoteCommandError("unknown cmd"))
        }
        if let extra = object.keys.first(where: { !["id", "cmd", "args"].contains($0) }) {
            _ = extra
            return .failure(RemoteCommandError("unknown field"))
        }
        let args: [String: Any]
        if let given = object["args"] {
            guard let dictionary = given as? [String: Any] else {
                return .failure(RemoteCommandError("args must be an object"))
            }
            args = dictionary
        } else {
            args = [:]
        }

        let allowed = (allowedParameters[cmd] ?? []).subtracting(["key"])
        var values: [String: String] = [:]
        for (name, value) in args {
            guard allowed.contains(name) else {
                return .failure(RemoteCommandError("unknown arg for \(cmd)"))
            }
            let text: String?
            switch name {
            case "to", "from": text = coordinateText(value)
            case "lat", "lon", "speed": text = numberText(value)
            case "loop": text = integerText(value)
            default: text = value as? String
            }
            guard let text, !text.isEmpty else {
                return .failure(RemoteCommandError("bad value for '\(name)'"))
            }
            values[name] = text
        }
        switch build(cmd, values) {
        case .success(let command): return .success(RemoteInboxCommand(id: fileID, command: command))
        case .failure(let error): return .failure(error)
        }
    }

    private static func isBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// A JSON number (or an already-textual one), as the plain decimal the URL
    /// grammar expects. Not-a-finite-number ends up as text `number()` refuses.
    private static func numberText(_ value: Any) -> String? {
        if let text = value as? String { return text }
        guard let number = value as? NSNumber, !isBoolean(number) else { return nil }
        let double = number.doubleValue
        return double.isFinite ? String(format: "%.10f", double) : "nan"
    }

    private static func integerText(_ value: Any) -> String? {
        if let text = value as? String { return text }
        guard let number = value as? NSNumber, !isBoolean(number) else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double == double.rounded(), abs(double) < 1000 else { return "x" }
        return String(Int(double))
    }

    /// `{"lat":…,"lon":…}` and nothing else, as `<lat>,<lon>`.
    private static func coordinateText(_ value: Any) -> String? {
        guard let object = value as? [String: Any], Set(object.keys) == ["lat", "lon"],
              let lat = numberText(object["lat"]!), let lon = numberText(object["lon"]!) else { return nil }
        return "\(lat),\(lon)"
    }

    // MARK: - drive

    private static func parseDrive(_ values: [String: String]) -> Result<RemoteCommand, RemoteCommandError> {
        guard let rawTo = values["to"] else {
            return .failure(RemoteCommandError("drive needs to=<lat>,<lon>"))
        }
        guard let destination = coordinate(rawTo) else {
            return .failure(RemoteCommandError("to= is not a valid <lat>,<lon>"))
        }

        var origin: RemoteCoordinate?
        if let rawFrom = values["from"] {
            guard let parsed = coordinate(rawFrom) else {
                return .failure(RemoteCommandError("from= is not a valid <lat>,<lon>"))
            }
            origin = parsed
        }

        var mode = TravelMode.drive
        if let raw = values["mode"] {
            switch raw.lowercased() {
            case "drive": mode = .drive
            case "walk": mode = .walk
            // MapKit routes a bicycle as a car (see TravelMode.mkTransportType),
            // but the speed model has a cycle mode of its own, so it is used as is.
            case "cycle": mode = .cycle
            default: return .failure(RemoteCommandError("mode must be drive, walk or cycle"))
            }
        }

        var profileName: String?
        if let raw = values["profile"] {
            switch validatedName(raw, field: "profile") {
            case .success(let name): profileName = name
            case .failure(let error): return .failure(error)
            }
        }

        var timeScale: Double?
        if let raw = values["speed"] {
            guard let value = number(raw), speedRange.contains(value) else {
                return .failure(RemoteCommandError("speed must be a number from 0.5 to 8"))
            }
            timeScale = value
        }

        var endBehavior: RouteEndBehavior?
        if let raw = values["loop"] {
            switch raw {
            case "0": endBehavior = .stop
            case "1": endBehavior = .loop
            // "Back and forth": out, then back along the same road, repeatedly.
            case "2": endBehavior = .pingPong
            default: return .failure(RemoteCommandError("loop must be 0, 1 or 2"))
            }
        }

        return .success(.drive(RemoteDriveRequest(
            destination: destination,
            origin: origin,
            mode: mode,
            profileName: profileName,
            timeScale: timeScale,
            endBehavior: endBehavior
        )))
    }

    // MARK: - Pieces

    private static func queryItems(_ url: URL) -> [URLQueryItem]? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        return components.queryItems ?? []
    }

    /// A plain decimal number: digits, one optional leading sign, one point.
    /// `Double("0x1p3")`, `"1e400"`, `"nan"` and `"inf"` all parse, and none of
    /// them is a coordinate.
    static func number(_ raw: String) -> Double? {
        guard !raw.isEmpty, raw.count <= 24,
              raw.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "." || $0 == "-") }),
              let value = Double(raw), value.isFinite else { return nil }
        return value
    }

    /// `lat,lon`, in range, with nothing else around it.
    static func coordinate(_ raw: String) -> RemoteCoordinate? {
        let parts = raw.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let latitude = number(String(parts[0])), let longitude = number(String(parts[1])),
              (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        return RemoteCoordinate(latitude: latitude, longitude: longitude)
    }

    /// A name from outside: trimmed, non-empty, bounded, no control characters.
    /// It is only ever compared with stored names — never interpolated into a
    /// path, a command or markup.
    static func validatedName(_ raw: String, field: String) -> Result<String, RemoteCommandError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(RemoteCommandError("\(field)= is empty"))
        }
        guard trimmed.count <= maxNameLength else {
            return .failure(RemoteCommandError("\(field)= is too long"))
        }
        guard !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return .failure(RemoteCommandError("\(field)= contains control characters"))
        }
        return .success(trimmed)
    }
}

// MARK: - The key

/// Why a command was turned away before it was even read.
enum RemoteAuthFailure: Error, Equatable {
    /// No key file, an unreadable one, or an empty one: remote control is off.
    case disabled
    case badKey

    var message: String {
        switch self {
        case .disabled: return "remote control disabled"
        case .badKey: return "bad key"
        }
    }
}

enum RemoteKey {
    /// Where the owner keeps the key. Readable only through the entitlement
    /// exception for this directory, so an app without it can't find out what
    /// the key is — which is the point.
    static let directory = "/var/jb/var/locate-ipad/"
    static let keyPath = directory + "locus.key"

    /// Checks the key a URL carried against the key file's contents.
    static func authorize(provided: String?, keyFile: String?) -> Result<Void, RemoteAuthFailure> {
        let expected = keyFile?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !expected.isEmpty else { return .failure(.disabled) }
        guard let provided, !provided.isEmpty,
              constantTimeEqual(Array(provided.utf8), Array(expected.utf8)) else {
            return .failure(.badKey)
        }
        return .success(())
    }

    /// Compares every byte of the longer input whatever the first difference is,
    /// so how long a guess takes says nothing about how much of it was right.
    static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        var difference = a.count ^ b.count
        for index in 0..<max(a.count, b.count) {
            let x: UInt8 = index < a.count ? a[index] : 0
            let y: UInt8 = index < b.count ? b[index] : 0
            difference |= Int(x ^ y)
        }
        return difference == 0
    }
}
