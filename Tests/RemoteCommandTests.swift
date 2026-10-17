import XCTest

/// The URL grammar behind `uiopen "locus://drive?…"`, the key gate in front of
/// it, and the JSON a remote reader depends on. A false accept here moves a
/// phone for whoever sent a link; a false reject only costs a retry — so the
/// tests lean on the refusals.
final class RemoteCommandTests: XCTestCase {
    private func parse(_ string: String) -> Result<RemoteCommand, RemoteCommandError> {
        RemoteCommandParser.parse(URL(string: string)!)
    }

    private func command(_ string: String, file: StaticString = #filePath, line: UInt = #line) -> RemoteCommand? {
        if case .success(let command) = parse(string) { return command }
        XCTFail("expected \(string) to parse", file: file, line: line)
        return nil
    }

    private func refusal(_ string: String) -> String? {
        if case .failure(let error) = parse(string) { return error.message }
        return nil
    }

    // MARK: drive

    func testMinimalDrive() {
        guard case .drive(let request)? = command("locus://drive?to=48.8584,2.2945&key=k") else { return }
        XCTAssertEqual(request.destination, RemoteCoordinate(latitude: 48.8584, longitude: 2.2945))
        XCTAssertNil(request.origin)
        XCTAssertEqual(request.mode, .drive)
        XCTAssertNil(request.profileName)
        XCTAssertNil(request.timeScale)
        XCTAssertNil(request.endBehavior)
    }

    func testFullDrive() {
        let url = "locus://drive?to=-33.8688,151.2093&from=-33.9,151.1&mode=walk&profile=On%20foot&speed=2.5&loop=2&key=abc"
        guard case .drive(let request)? = command(url) else { return }
        XCTAssertEqual(request.destination.latitude, -33.8688, accuracy: 1e-9)
        XCTAssertEqual(request.origin, RemoteCoordinate(latitude: -33.9, longitude: 151.1))
        XCTAssertEqual(request.mode, .walk)
        XCTAssertEqual(request.profileName, "On foot")
        XCTAssertEqual(request.timeScale, 2.5)
        XCTAssertEqual(request.endBehavior, .pingPong)
    }

    func testModes() {
        for (text, mode) in [("drive", TravelMode.drive), ("walk", .walk), ("cycle", .cycle), ("CYCLE", .cycle)] {
            guard case .drive(let request)? = command("locus://drive?to=1,2&mode=\(text)&key=k") else { return }
            XCTAssertEqual(request.mode, mode)
        }
        XCTAssertNotNil(refusal("locus://drive?to=1,2&mode=fly&key=k"))
        XCTAssertNotNil(refusal("locus://drive?to=1,2&mode=run&key=k"))
    }

    func testLoopValues() {
        for (text, end) in [("0", RouteEndBehavior.stop), ("1", .loop), ("2", .pingPong)] {
            guard case .drive(let request)? = command("locus://drive?to=1,2&loop=\(text)&key=k") else { return }
            XCTAssertEqual(request.endBehavior, end)
        }
        for bad in ["3", "-1", "yes", "1.0", "01"] {
            XCTAssertNotNil(refusal("locus://drive?to=1,2&loop=\(bad)&key=k"), bad)
        }
    }

    func testSpeedIsClampedByRefusalNotRepair() {
        for good in ["0.5", "1", "8", "7.99"] {
            guard case .drive(let request)? = command("locus://drive?to=1,2&speed=\(good)&key=k") else { return }
            XCTAssertEqual(request.timeScale, Double(good))
        }
        for bad in ["0.49", "0", "8.01", "-2", "100", "nan", "inf", "1e1", "0x4", "fast"] {
            XCTAssertNotNil(refusal("locus://drive?to=1,2&speed=\(bad)&key=k"), bad)
        }
    }

    func testCoordinatesAreStrict() {
        for bad in ["91,0", "-91,0", "0,181", "0,-181", "nan,0", "0,inf", "1", "1,2,3", ",2", "1,", "a,b", "1e1,2",
                    "0x10,2", "1 ,2", "--1,2"] {
            XCTAssertNotNil(refusal("locus://drive?to=\(bad.replacingOccurrences(of: " ", with: "%20"))&key=k"), bad)
        }
        XCTAssertNotNil(refusal("locus://drive?to=1,2&from=95,0&key=k"))
        XCTAssertNotNil(refusal("locus://drive?key=k"), "to= is required")
        for edge in ["90,180", "-90,-180", "0,0", "-0.5,-0.25"] {
            XCTAssertNotNil(command("locus://drive?to=\(edge)&key=k"), edge)
        }
    }

    func testRepeatedUnknownAndEmptyParametersAreRefused() {
        XCTAssertNotNil(refusal("locus://drive?to=1,2&to=3,4&key=k"))
        XCTAssertNotNil(refusal("locus://drive?to=1,2&colour=red&key=k"))
        XCTAssertNotNil(refusal("locus://drive?to=1,2&profile=&key=k"))
        XCTAssertNotNil(refusal("locus://drive?to=1,2&key=k&key=k"))
        XCTAssertNotNil(refusal("locus://stop?key=k&to=1,2"), "stop takes only a key")
        XCTAssertNotNil(refusal("locus://route?name=Home&to=1,2&key=k"))
    }

    // MARK: route / stop

    func testRouteNameIsDecodedAndTrimmed() {
        XCTAssertEqual(command("locus://route?name=Home%20to%20Office&key=k"), .route(name: "Home to Office"))
        XCTAssertEqual(command("locus://route?name=%20Commute%20&key=k"), .route(name: "Commute"))
        XCTAssertEqual(command("locus://route?name=Caf%C3%A9%20%E2%9C%93&key=k"), .route(name: "Café ✓"))
    }

    func testNamesAreBounded() {
        XCTAssertNotNil(refusal("locus://route?name=%20%20&key=k"))
        XCTAssertNotNil(refusal("locus://route?name=\(String(repeating: "a", count: 121))&key=k"))
        XCTAssertNotNil(command("locus://route?name=\(String(repeating: "a", count: 120))&key=k"))
        XCTAssertNotNil(refusal("locus://route?name=a%00b&key=k"), "NUL")
        XCTAssertNotNil(refusal("locus://route?name=a%0Ab&key=k"), "newline")
        XCTAssertNotNil(refusal("locus://route?key=k"), "name= is required")
        XCTAssertNotNil(refusal("locus://drive?to=1,2&profile=a%1Bb&key=k"), "escape")
    }

    func testNamesStayDataNotSyntax() {
        // Shell and path metacharacters pass through as inert text; they are only
        // ever compared with stored names.
        XCTAssertEqual(command("locus://route?name=%24(reboot)%3B%20..%2F..%2Fetc&key=k"),
                       .route(name: "$(reboot); ../../etc"))
    }

    func testStop() {
        XCTAssertEqual(command("locus://stop?key=k"), .stop)
        XCTAssertEqual(RemoteCommand.stop.name, "stop")
    }

    // MARK: Which URLs are ours

    func testOnlyTheThreeCommandsAreGated() {
        let url = { (s: String) in URL(string: s)! }
        XCTAssertEqual(RemoteCommandParser.commandName(of: url("locus://drive?to=1,2")), "drive")
        XCTAssertEqual(RemoteCommandParser.commandName(of: url("LOCUS://Route?name=x")), "route")
        XCTAssertEqual(RemoteCommandParser.commandName(of: url("locus://stop")), "stop")
        // These keep their old, ungated behaviour.
        XCTAssertNil(RemoteCommandParser.commandName(of: url("locus://teleport?lat=1&lon=2")))
        XCTAssertNil(RemoteCommandParser.commandName(of: url("locus://pin?lat=1&lon=2")))
        XCTAssertNil(RemoteCommandParser.commandName(of: url("geo:1,2")))
        XCTAssertNil(RemoteCommandParser.commandName(of: url("https://example.com/drive?to=1,2")))
    }

    func testKeyExtraction() {
        XCTAssertEqual(RemoteCommandParser.key(in: URL(string: "locus://stop?key=abc123")!), "abc123")
        XCTAssertEqual(RemoteCommandParser.key(in: URL(string: "locus://stop?key=a%2Bb%3D")!), "a+b=")
        XCTAssertNil(RemoteCommandParser.key(in: URL(string: "locus://stop")!))
        XCTAssertNotNil(refusal("locus://stop"), "no key, no command")
    }

    // MARK: Key gate

    /// The refusal, or `nil` when the key is accepted.
    private func gate(_ provided: String?, _ keyFile: String?) -> RemoteAuthFailure? {
        if case .failure(let failure) = RemoteKey.authorize(provided: provided, keyFile: keyFile) { return failure }
        return nil
    }

    func testMatchingKeyIsAccepted() {
        XCTAssertNil(gate("s3cret", "s3cret
"))
        XCTAssertNil(gate("s3cret", "  s3cret 
"))
    }

    func testWrongOrMissingKeyIsRefused() {
        XCTAssertEqual(gate("s3cre", "s3cret"), .badKey)
        XCTAssertEqual(gate("s3crett", "s3cret"), .badKey)
        XCTAssertEqual(gate("S3CRET", "s3cret"), .badKey, "case matters")
        XCTAssertEqual(gate(nil, "s3cret"), .badKey)
        XCTAssertEqual(gate("", "s3cret"), .badKey)
    }

    func testMissingOrEmptyKeyFileDisablesRemoteControl() {
        XCTAssertEqual(gate("anything", nil), .disabled)
        XCTAssertEqual(gate("anything", ""), .disabled)
        XCTAssertEqual(gate("", " 
"), .disabled, "an empty key must not match an empty file")
        XCTAssertEqual(RemoteAuthFailure.disabled.message, "remote control disabled")
        XCTAssertEqual(RemoteAuthFailure.badKey.message, "bad key")
    }

    func testConstantTimeEqual() {
        XCTAssertTrue(RemoteKey.constantTimeEqual([1, 2, 3], [1, 2, 3]))
        XCTAssertTrue(RemoteKey.constantTimeEqual([], []))
        XCTAssertFalse(RemoteKey.constantTimeEqual([1, 2, 3], [1, 2, 4]))
        XCTAssertFalse(RemoteKey.constantTimeEqual([1, 2, 3], [1, 2]))
        XCTAssertFalse(RemoteKey.constantTimeEqual([1, 2], [1, 2, 0]), "padding must not make lengths equal")
        XCTAssertFalse(RemoteKey.constantTimeEqual([], [0]))
    }

    func testKeyPathIsTheDocumentedOne() {
        XCTAssertEqual(RemoteKey.keyPath, "/var/jb/var/locate-ipad/locus.key")
    }

    // MARK: JSON

    private func json(_ data: Data) -> [String: Any] {
        (try! JSONSerialization.jsonObject(with: data)) as! [String: Any]
    }

    private func idleState() -> RemoteState {
        RemoteState(
            ts: 1_760_000_000, engine: "direct", status: "idle", simulating: false, mode: "idle",
            position: nil, route: nil, speedKmh: nil, loop: nil, timeScale: nil, profile: nil,
            tunnel: "direct", lastCommand: nil, error: nil, version: "1.3.0"
        )
    }

    func testIdleStateWritesExplicitNulls() throws {
        let object = json(try idleState().jsonData())
        XCTAssertEqual(Set(object.keys), [
            "ts", "engine", "status", "simulating", "mode", "position", "route", "speedKmh", "loop",
            "timeScale", "profile", "tunnel", "lastCommand", "error", "version",
        ])
        for key in ["position", "route", "speedKmh", "loop", "timeScale", "profile", "lastCommand", "error"] {
            XCTAssertTrue(object[key] is NSNull, "\(key) should be null")
        }
        XCTAssertEqual(object["ts"] as? Int, 1_760_000_000)
        XCTAssertEqual(object["simulating"] as? Bool, false)
        XCTAssertEqual(object["tunnel"] as? String, "direct")
    }

    func testActiveRouteState() throws {
        var state = idleState()
        state.status = "active"
        state.simulating = true
        state.mode = "route"
        state.position = .init(lat: 48.8584, lon: 2.2945)
        state.route = .init(name: "Remote drive", progressPct: 42.5, paused: false)
        state.speedKmh = 50.4
        state.loop = 2
        state.timeScale = 4
        state.profile = "Commute"
        state.lastCommand = .init(name: "drive", ts: 1_760_000_001, ok: true, error: nil)

        let object = json(try state.jsonData())
        let position = object["position"] as? [String: Any]
        XCTAssertEqual(position?["lat"] as? Double, 48.8584)
        XCTAssertEqual(position?["lon"] as? Double, 2.2945)
        let route = object["route"] as? [String: Any]
        XCTAssertEqual(route?["name"] as? String, "Remote drive")
        XCTAssertEqual(route?["progressPct"] as? Double, 42.5)
        XCTAssertEqual(route?["paused"] as? Bool, false)
        XCTAssertEqual(object["loop"] as? Int, 2)
        XCTAssertEqual(object["timeScale"] as? Double, 4)
        XCTAssertEqual(object["profile"] as? String, "Commute")
        let last = object["lastCommand"] as? [String: Any]
        XCTAssertEqual(last?["name"] as? String, "drive")
        XCTAssertEqual(last?["ok"] as? Bool, true)
        XCTAssertTrue(last?["error"] is NSNull)
    }

    func testFailedCommandCarriesItsError() throws {
        var state = idleState()
        state.lastCommand = .init(name: "stop", ts: 5, ok: false, error: "bad key")
        let last = json(try state.jsonData())["lastCommand"] as? [String: Any]
        XCTAssertEqual(last?["ok"] as? Bool, false)
        XCTAssertEqual(last?["error"] as? String, "bad key")
    }

    func testHostileTextIsEscapedNotInterpreted() throws {
        var state = idleState()
        state.error = "quote \" backslash \\ newline \n </script>"
        let data = try state.jsonData()
        XCTAssertEqual(json(data)["error"] as? String, state.error)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\n"), "stays on one line")
    }

    func testSameContentIgnoresTheClockOnly() {
        var a = idleState()
        var b = a
        b.ts += 5
        XCTAssertTrue(a.sameContent(as: b))
        b.status = "active"
        XCTAssertFalse(a.sameContent(as: b))
        a = idleState()
        b = a
        b.position = .init(lat: 1, lon: 2)
        XCTAssertFalse(a.sameContent(as: b))
    }

    func testRoutesFile() throws {
        let entries = [
            RemoteRouteEntry(id: "11111111-1111-1111-1111-111111111111", name: "Commute", journey: "Home → Office",
                             distanceM: 12_345.6, timesDriven: 3, lastDriven: 1_760_000_000),
            RemoteRouteEntry(id: "22222222-2222-2222-2222-222222222222", name: "New", journey: nil,
                             distanceM: 800, timesDriven: 0, lastDriven: nil),
        ]
        let array = try JSONSerialization.jsonObject(with: RemoteRouteEntry.jsonData(entries)) as! [[String: Any]]
        XCTAssertEqual(array.count, 2)
        XCTAssertEqual(array[0]["name"] as? String, "Commute")
        XCTAssertEqual(array[0]["journey"] as? String, "Home → Office")
        XCTAssertEqual(array[0]["distanceM"] as? Double, 12_345.6)
        XCTAssertEqual(array[0]["timesDriven"] as? Int, 3)
        XCTAssertEqual(array[0]["lastDriven"] as? Int, 1_760_000_000)
        XCTAssertTrue(array[1]["journey"] is NSNull)
        XCTAssertTrue(array[1]["lastDriven"] is NSNull)
        XCTAssertEqual(Set(array[1].keys), ["id", "name", "journey", "distanceM", "timesDriven", "lastDriven"])
        XCTAssertEqual(try RemoteRouteEntry.jsonData([]), Data("[]".utf8))
    }
}
