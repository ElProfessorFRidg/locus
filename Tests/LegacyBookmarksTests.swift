import XCTest

/// Bookmarks brought over from Geranium and Mika's LocSim. Both formats are
/// loosely typed plists, and Geranium force-cast every field — one malformed
/// entry crashed its list. Here one malformed entry must cost that entry only.
final class LegacyBookmarksTests: XCTestCase {

    func testGeraniumBookmarks() {
        let parsed = LegacyBookmarks.parseGeranium([
            ["name": "Eiffel Tower", "lat": 48.85837, "long": 2.29448],
            ["name": "Home", "lat": NSNumber(value: 51.5), "long": NSNumber(value: -0.12)],
        ])
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].name, "Eiffel Tower")
        XCTAssertEqual(parsed[0].latitude, 48.85837, accuracy: 1e-9)
        XCTAssertEqual(parsed[1].longitude, -0.12, accuracy: 1e-9)
        XCTAssertEqual(parsed[0].source, .geranium)
    }

    func testMalformedGeraniumEntriesAreSkippedNotFatal() {
        let parsed = LegacyBookmarks.parseGeranium([
            ["name": "No longitude", "lat": 10.0],
            "not even a dictionary",
            ["name": "Out of range", "lat": 120.0, "long": 10.0],
            ["name": "Kept", "lat": "35.6762", "long": "139.6503"],
        ])
        XCTAssertEqual(parsed.map(\.name), ["Kept"])
        XCTAssertEqual(parsed.first?.latitude ?? 0, 35.6762, accuracy: 1e-9)
    }

    /// Geranium let you save (0, 0) after an "are you sure?" — nobody was sure.
    func testNullIslandIsDropped() {
        XCTAssertTrue(LegacyBookmarks.parseGeranium([["name": "Oops", "lat": 0.0, "long": 0.0]]).isEmpty)
    }

    func testUnnamedBookmarksGetTheirCoordinates() {
        let parsed = LegacyBookmarks.parseGeranium([["name": "  ", "lat": 1.5, "long": 2.5]])
        XCTAssertEqual(parsed.first?.name, "1.50000, 2.50000")
    }

    func testMikaBookmarks() {
        let parsed = LegacyBookmarks.parseMika([
            "datas": [
                ["la": 40.7128, "lo": -74.0060, "remark": "New York"],
                ["la": 1.0],
            ],
        ])
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].name, "New York")
        XCTAssertEqual(parsed[0].source, .mika)
    }

    func testMikaWithoutDatasIsEmpty() {
        XCTAssertTrue(LegacyBookmarks.parseMika(["something": "else"]).isEmpty)
        XCTAssertTrue(LegacyBookmarks.parseMika([1, 2, 3]).isEmpty)
    }

    /// Geranium imported Mika's list into its own, so the same spot is often
    /// in both. It comes over once, under the name it was found with first.
    func testTheSameSpotInBothAppsArrivesOnce() {
        let both = LegacyBookmarks.parseGeranium([["name": "Office", "lat": 48.8566, "long": 2.3522]])
            + LegacyBookmarks.parseMika(["datas": [["la": 48.85661, "lo": 2.35221, "remark": "Bureau"]]])
        let kept = LegacyBookmarks.deduplicated(both)
        XCTAssertEqual(kept.map(\.name), ["Office"])
    }
}
