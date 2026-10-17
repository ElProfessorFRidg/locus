import XCTest

/// The inbox's JSON, held to the same rules as the URL grammar — it is built
/// by the same code, so these pin that it stayed that way.
final class RemoteInboxTests: XCTestCase {
    private let id = "a1b2c3d4"

    private func parse(_ json: String, file: String? = nil) -> Result<RemoteInboxCommand, RemoteCommandError> {
        RemoteCommandParser.parseInbox(Data(json.utf8), fileID: file ?? id)
    }

    private func command(_ args: String, cmd: String) -> String {
        "{\"id\":\"\(id)\",\"cmd\":\"\(cmd)\",\"args\":\(args)}"
    }

    private func accepted(_ json: String, line: UInt = #line) -> RemoteCommand? {
        if case .success(let parsed) = parse(json) { return parsed.command }
        XCTFail("expected to parse: \(json)", line: line)
        return nil
    }

    private func refused(_ json: String, file: String? = nil) -> Bool {
        if case .failure = parse(json, file: file) { return true }
        return false
    }

    // MARK: valid

    func testGo() {
        XCTAssertEqual(accepted(command("{\"lat\":48.8584,\"lon\":2.2945}", cmd: "go")),
                       .go(RemoteCoordinate(latitude: 48.8584, longitude: 2.2945)))
        XCTAssertEqual(accepted(command("{\"lat\":-90,\"lon\":180}", cmd: "go")),
                       .go(RemoteCoordinate(latitude: -90, longitude: 180)))
        XCTAssertEqual(accepted(command("{\"lat\":\"1.5\",\"lon\":\"2\"}", cmd: "go")),
                       .go(RemoteCoordinate(latitude: 1.5, longitude: 2)))
    }

    func testStopWithAndWithoutArgs() {
        XCTAssertEqual(accepted(command("{}", cmd: "stop")), .stop)
        XCTAssertEqual(accepted("{\"id\":\"\(id)\",\"cmd\":\"stop\"}"), .stop)
    }

    func testRoute() {
        XCTAssertEqual(accepted(command("{\"name\":\"Home to Office\"}", cmd: "route")), .route(name: "Home to Office"))
    }

    func testDriveMinimalAndFull() {
        guard case .drive(let minimal)? = accepted(command("{\"to\":{\"lat\":1,\"lon\":2}}", cmd: "drive")) else { return }
        XCTAssertEqual(minimal.destination, RemoteCoordinate(latitude: 1, longitude: 2))
        XCTAssertEqual(minimal.mode, .drive)
        XCTAssertNil(minimal.origin)

        let full = command("{\"to\":{\"lat\":-33.8,\"lon\":151.2},\"from\":{\"lat\":-33.9,\"lon\":151.1},"
            + "\"mode\":\"cycle\",\"profile\":\"On foot\",\"speed\":2.5,\"loop\":2}", cmd: "drive")
        guard case .drive(let request)? = accepted(full) else { return }
        XCTAssertEqual(request.destination, RemoteCoordinate(latitude: -33.8, longitude: 151.2))
        XCTAssertEqual(request.origin, RemoteCoordinate(latitude: -33.9, longitude: 151.1))
        XCTAssertEqual(request.mode, .cycle)
        XCTAssertEqual(request.profileName, "On foot")
        XCTAssertEqual(request.timeScale, 2.5)
        XCTAssertEqual(request.endBehavior, .pingPong)
    }

    // MARK: rejections

    func testRejectsOutOfRangeAndMalformedCoordinates() {
        for args in ["{\"lat\":91,\"lon\":0}", "{\"lat\":0,\"lon\":-181}", "{\"lat\":\"nan\",\"lon\":0}",
                     "{\"lat\":1}", "{\"lon\":1}", "{\"lat\":null,\"lon\":1}", "{\"lat\":true,\"lon\":1}",
                     "{\"lat\":[1],\"lon\":1}", "{\"lat\":1,\"lon\":2,\"name\":\"x\"}", "{\"lat\":\"1e1\",\"lon\":0}"] {
            XCTAssertTrue(refused(command(args, cmd: "go")), args)
        }
    }

    func testRejectsBadDriveArguments() {
        let to = "\"to\":{\"lat\":1,\"lon\":2}"
        for extra in ["\"mode\":\"fly\"", "\"mode\":3", "\"speed\":0.4", "\"speed\":8.5", "\"speed\":\"fast\"",
                      "\"loop\":3", "\"loop\":1.5", "\"loop\":true", "\"profile\":\"\"", "\"profile\":\"a\\u0007b\"",
                      "\"from\":{\"lat\":95,\"lon\":0}", "\"from\":\"1,2\"", "\"from\":{\"lat\":1,\"lon\":2,\"x\":3}",
                      "\"colour\":\"red\"", "\"key\":\"k\""] {
            XCTAssertTrue(refused(command("{\(to),\(extra)}", cmd: "drive")), extra)
        }
        XCTAssertTrue(refused(command("{}", cmd: "drive")), "to is required")
        XCTAssertTrue(refused(command("{\"to\":\"1,2\"}", cmd: "drive")), "to must be an object")
    }

    func testRejectsBadRouteNames() {
        let long = String(repeating: "a", count: 121)
        for args in ["{}", "{\"name\":\"\"}", "{\"name\":\"   \"}", "{\"name\":5}",
                     "{\"name\":\"\(long)\"}", "{\"name\":\"a\\nb\"}"] {
            XCTAssertTrue(refused(command(args, cmd: "route")), args)
        }
    }

    func testScreenshot() {
        XCTAssertEqual(accepted(command("{}", cmd: "screenshot")), .screenshot(scale: 1))
        XCTAssertEqual(accepted("{\"id\":\"\(id)\",\"cmd\":\"screenshot\"}"), .screenshot(scale: 1))
        XCTAssertEqual(accepted(command("{\"scale\":2}", cmd: "screenshot")), .screenshot(scale: 2))
        XCTAssertEqual(accepted(command("{\"scale\":1}", cmd: "screenshot")), .screenshot(scale: 1))
        for args in ["{\"scale\":3}", "{\"scale\":0}", "{\"scale\":1.5}", "{\"scale\":true}",
                     "{\"scale\":\"big\"}", "{\"width\":100}", "{\"key\":\"k\"}"] {
            XCTAssertTrue(refused(command(args, cmd: "screenshot")), args)
        }
    }

    func testScreenshotResultFieldsSitAtTheTopLevel() throws {
        let info = ScreenshotInfo(file: "/var/jb/var/locate-ipad/screens/a1b2c3d4.png", width: 1640, height: 2360,
                                  mapMayBeBlank: false)
        let result = RemoteResult(id: id, cmd: "screenshot", ok: true, error: nil, ts: 5, state: nil, screenshot: info)
        let object = try JSONSerialization.jsonObject(with: result.jsonData()) as! [String: Any]
        XCTAssertEqual(object["file"] as? String, info.file)
        XCTAssertEqual(object["width"] as? Int, 1640)
        XCTAssertEqual(object["height"] as? Int, 2360)
        XCTAssertEqual(object["mapMayBeBlank"] as? Bool, false)
        XCTAssertEqual(object["ok"] as? Bool, true)
    }

    func testInterface() {
        XCTAssertEqual(accepted(command("{\"mode\":\"fun\"}", cmd: "interface")), .interface(.fun))
        XCTAssertEqual(accepted(command("{\"mode\":\"pro\"}", cmd: "interface")), .interface(.pro))
        for args in ["{}", "{\"mode\":\"x\"}", "{\"mode\":1}", "{\"mode\":\"pro\",\"a\":1}"] {
            XCTAssertTrue(refused(command(args, cmd: "interface")), args)
        }
        let result = RemoteResult(id: id, cmd: "interface", ok: true, error: nil, ts: 1, state: nil, interface: "fun")
        let object = try! JSONSerialization.jsonObject(with: result.jsonData()) as! [String: Any]
        XCTAssertEqual(object["interface"] as? String, "fun")
    }

    func testRejectsStopWithArguments() {
        XCTAssertTrue(refused(command("{\"lat\":1}", cmd: "stop")))
    }

    func testRejectsStructuralProblems() {
        XCTAssertTrue(refused("not json"))
        XCTAssertTrue(refused("[]"))
        XCTAssertTrue(refused("{\"id\":\"\(id)\",\"cmd\":\"teleport\",\"args\":{}}"), "unknown cmd")
        XCTAssertTrue(refused("{\"id\":\"\(id)\",\"args\":{}}"), "no cmd")
        XCTAssertTrue(refused("{\"id\":\"ffffff\",\"cmd\":\"stop\"}"), "id differs from the file name")
        XCTAssertTrue(refused("{\"cmd\":\"stop\"}"), "no id")
        XCTAssertTrue(refused("{\"id\":\"\(id)\",\"cmd\":\"stop\",\"args\":[]}"), "args not an object")
        XCTAssertTrue(refused("{\"id\":\"\(id)\",\"cmd\":\"stop\",\"key\":\"k\"}"), "unknown field")
        let huge = String(repeating: "a", count: 5000)
        XCTAssertTrue(refused("{\"id\":\"\(id)\",\"cmd\":\"route\",\"args\":{\"name\":\"\(huge)\"}}"), "over 4 KB")
    }

    func testFileIDs() {
        XCTAssertTrue(RemoteCommandParser.isValidInboxID("abcdef"))
        XCTAssertTrue(RemoteCommandParser.isValidInboxID(String(repeating: "0", count: 32)))
        for bad in ["abcde", String(repeating: "0", count: 33), "ABCDEF", "abcdeg", "../abcd", "abc def", ""] {
            XCTAssertFalse(RemoteCommandParser.isValidInboxID(bad), bad)
            XCTAssertTrue(refused(command("{}", cmd: "stop"), file: bad), bad)
        }
    }

    func testCommandNameOfJunk() {
        XCTAssertEqual(RemoteCommandParser.inboxCommandName(Data("{\"cmd\":\"go\"}".utf8)), "go")
        XCTAssertEqual(RemoteCommandParser.inboxCommandName(Data("{\"cmd\":\"rm\"}".utf8)), "unknown")
        XCTAssertEqual(RemoteCommandParser.inboxCommandName(Data("junk".utf8)), "unknown")
    }

    // MARK: result file

    func testResultJSON() throws {
        var state = RemoteState(
            ts: 10, engine: "direct", status: "active", simulating: true, mode: "teleport",
            position: .init(lat: 1, lon: 2), route: nil, speedKmh: nil, loop: nil, timeScale: nil,
            profile: nil, tunnel: "direct", lastCommand: nil, error: nil, version: "1"
        )
        state.lastCommand = .init(name: "go", ts: 10, ok: true, error: nil)
        let ok = RemoteResult(id: id, cmd: "go", ok: true, error: nil, ts: 11, state: state)
        let object = try JSONSerialization.jsonObject(with: ok.jsonData()) as! [String: Any]
        XCTAssertEqual(Set(object.keys), ["id", "cmd", "ok", "error", "ts", "state"])
        XCTAssertEqual(object["id"] as? String, id)
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertTrue(object["error"] is NSNull)
        XCTAssertEqual((object["state"] as? [String: Any])?["mode"] as? String, "teleport")

        let bad = RemoteResult(id: id, cmd: "unknown", ok: false, error: "unknown cmd", ts: 12, state: nil)
        let failed = try JSONSerialization.jsonObject(with: bad.jsonData()) as! [String: Any]
        XCTAssertEqual(failed["error"] as? String, "unknown cmd")
        XCTAssertTrue(failed["state"] is NSNull)
    }
}
