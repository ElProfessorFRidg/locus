import XCTest

/// The badge decides whether the phone is called fake or real, so the cases
/// that matter are the awkward ones: idle on paper, simulated in practice.
final class LocationVerdictTests: XCTestCase {
    private let paris = RemotePoint(lat: 48.8584, lon: 2.2945)
    private let lyon = RemotePoint(lat: 45.7640, lon: 4.8357)

    func testActiveIsSimulated() {
        for status in ["active", "reconnecting", "connecting"] {
            XCTAssertEqual(ReadoutVerdict.badge(status: status, reportedBySoftware: nil, reported: nil, lastReal: nil),
                           .simulated, status)
        }
    }

    func testDroppedIsInterrupted() {
        XCTAssertEqual(ReadoutVerdict.badge(status: "dropped", reportedBySoftware: false, reported: paris, lastReal: paris),
                       .interrupted)
    }

    func testIdleNearTheLastRealFixIsReal() {
        let nearby = RemotePoint(lat: paris.lat + 0.001, lon: paris.lon)
        XCTAssertEqual(ReadoutVerdict.badge(status: "idle", reportedBySoftware: false, reported: nearby, lastReal: paris), .real)
    }

    func testIdleWithNothingToCompareIsReal() {
        XCTAssertEqual(ReadoutVerdict.badge(status: "idle", reportedBySoftware: nil, reported: nil, lastReal: nil), .real)
        XCTAssertEqual(ReadoutVerdict.badge(status: "idle", reportedBySoftware: nil, reported: paris, lastReal: nil), .real)
    }

    func testIdleButFarFromTheLastRealFixIsUncertain() {
        let badge = ReadoutVerdict.badge(status: "idle", reportedBySoftware: false, reported: lyon, lastReal: paris)
        XCTAssertEqual(badge, .uncertain)
        XCTAssertEqual(badge.explanation, "location may still be simulated by locationd")
    }

    func testIdleButFlaggedSimulatedBySoftwareIsUncertain() {
        XCTAssertEqual(ReadoutVerdict.badge(status: "idle", reportedBySoftware: true, reported: paris, lastReal: paris),
                       .uncertain)
    }

    func testOnlyUncertainHasAnExplanation() {
        XCTAssertNil(ReadoutBadge.real.explanation)
        XCTAssertNil(ReadoutBadge.simulated.explanation)
        XCTAssertNil(ReadoutBadge.interrupted.explanation)
    }

    func testDistance() {
        XCTAssertEqual(ReadoutVerdict.distance(paris, paris), 0, accuracy: 1e-6)
        // Paris - Lyon is about 392 km.
        XCTAssertEqual(ReadoutVerdict.distance(paris, lyon), 392_000, accuracy: 3_000)
        XCTAssertEqual(ReadoutVerdict.distance(RemotePoint(lat: 0, lon: 0), RemotePoint(lat: 0, lon: 180)),
                       20_015_000, accuracy: 20_000)
    }

    func testCoordinateTextHasSixDecimals() {
        XCTAssertEqual(ReadoutVerdict.coordinateText(RemotePoint(lat: 48.85837, lon: -2.29448)), "48.858370, -2.294480")
        XCTAssertEqual(ReadoutVerdict.coordinateText(RemotePoint(lat: 0, lon: 0)), "0.000000, 0.000000")
    }

    func testBadgeTitles() {
        XCTAssertEqual(ReadoutBadge.simulated.rawValue, "SIMULATED")
        XCTAssertEqual(ReadoutBadge.real.rawValue, "REAL")
        XCTAssertEqual(ReadoutBadge.interrupted.rawValue, "INTERRUPTED")
    }
}
