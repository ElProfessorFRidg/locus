import CoreLocation
import XCTest

/// The China map offset. Wrong in one direction it moves every teleport in
/// China several hundred metres; wrong in the other it moves every teleport in
/// Seoul, Tokyo or Hong Kong by the same amount — and neither fails loudly.
final class MapDatumTests: XCTestCase {
    private func c(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private func metres(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    // MARK: The transform

    /// The reference pair every GCJ-02 implementation publishes
    /// (wandergis/coordtransform's README): Tiananmen.
    func testForwardMatchesTheReferenceImplementation() {
        let gcj = MapDatum.wgs84ToGCJ02(c(39.915, 116.404))
        XCTAssertEqual(gcj.latitude, 39.91640428150164, accuracy: 1e-9)
        XCTAssertEqual(gcj.longitude, 116.41024449916938, accuracy: 1e-9)
    }

    /// Geranium's inverse subtracted the offset once and was a metre or two
    /// out. Iterated, a round trip comes back to within a millimetre.
    func testInverseRoundTripsToWithinAMillimetre() {
        for point in [c(39.915, 116.404), c(31.2304, 121.4737), c(22.5431, 114.0579), c(30.5728, 104.0668)] {
            let back = MapDatum.gcj02ToWGS84(MapDatum.wgs84ToGCJ02(point))
            XCTAssertLessThan(metres(back, point), 0.001, "\(point)")
        }
    }

    func testTheOffsetIsHundredsOfMetres() {
        let beijing = c(39.915, 116.404)
        let shift = metres(beijing, MapDatum.wgs84ToGCJ02(beijing))
        XCTAssertGreaterThan(shift, 100)
        XCTAssertLessThan(shift, 1000)
    }

    // MARK: Where it applies

    func testMainlandCitiesAreShifted() {
        for (name, point) in [
            ("Beijing", c(39.915, 116.404)),
            ("Shanghai", c(31.2304, 121.4737)),
            ("Shenzhen", c(22.5431, 114.0579)),
            ("Guangzhou", c(23.1291, 113.2644)),
            ("Chengdu", c(30.5728, 104.0668)),
            ("Urumqi", c(43.8256, 87.6168)),
            ("Lhasa", c(29.6520, 91.1721)),
            ("Harbin", c(45.8038, 126.5349)),
            ("Haikou", c(20.0440, 110.1999)),
        ] {
            XCTAssertTrue(MapDatum.isInMainlandChina(point), name)
        }
    }

    /// Every one of these sits inside the single rectangle Geranium used.
    func testNeighboursInsideTheOldBoxAreNot() {
        for (name, point) in [
            ("Hong Kong", c(22.3193, 114.1694)),
            ("Macau", c(22.1987, 113.5439)),
            ("Taipei", c(25.0330, 121.5654)),
            ("Seoul", c(37.5665, 126.9780)),
            ("Pyongyang", c(39.0392, 125.7625)),
            ("Tokyo", c(35.6762, 139.6503)),
            ("Osaka", c(34.6937, 135.5023)),
            ("Hanoi", c(21.0278, 105.8342)),
            ("Ulaanbaatar", c(47.8864, 106.9057)),
            ("Vladivostok", c(43.1155, 131.8855)),
            ("Bangkok", c(13.7563, 100.5018)),
            ("New Delhi", c(28.6139, 77.2090)),
        ] {
            XCTAssertFalse(MapDatum.isInMainlandChina(point), name)
        }
    }

    // MARK: Modes

    func testAutomaticOnlyMovesMainlandPoints() {
        let paris = c(48.85837, 2.29448)
        let seoul = c(37.5665, 126.9780)
        let shanghai = c(31.2304, 121.4737)
        XCTAssertEqual(MapDatumMode.automatic.toWGS84(paris).latitude, paris.latitude)
        XCTAssertEqual(MapDatumMode.automatic.toWGS84(seoul).longitude, seoul.longitude)
        XCTAssertGreaterThan(metres(MapDatumMode.automatic.toWGS84(shanghai), shanghai), 100)
    }

    func testNeverLeavesEverythingAlone() {
        let shanghai = c(31.2304, 121.4737)
        XCTAssertEqual(MapDatumMode.never.toWGS84(shanghai).latitude, shanghai.latitude)
        XCTAssertEqual(MapDatumMode.never.fromWGS84(shanghai).longitude, shanghai.longitude)
    }

    /// `.always` still stops at the edge of the area the formula is defined for.
    func testAlwaysShiftsSeoulButNotParis() {
        let seoul = c(37.5665, 126.9780)
        let paris = c(48.85837, 2.29448)
        XCTAssertGreaterThan(metres(MapDatumMode.always.toWGS84(seoul), seoul), 50)
        XCTAssertEqual(MapDatumMode.always.toWGS84(paris).latitude, paris.latitude)
    }

    func testToAndFromAreInverses() {
        let tap = c(31.2304, 121.4737)
        let back = MapDatumMode.automatic.fromWGS84(MapDatumMode.automatic.toWGS84(tap))
        XCTAssertLessThan(metres(back, tap), 0.001)
    }
}
