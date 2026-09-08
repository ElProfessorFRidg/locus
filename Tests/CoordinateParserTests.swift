import CoreLocation
import XCTest

/// The parser has about fifteen accepted shapes and, more importantly, a set of
/// things it must *refuse* — a false positive here doesn't fail loudly, it
/// quietly swallows a place search and drops a pin in the Gulf of Guinea.
final class CoordinateParserTests: XCTestCase {
    // MARK: Decimal pairs

    func testCommaSeparatedPair() {
        let match = CoordinateParser.parse("48.85837, 2.29448")
        XCTAssertEqual(match?.coordinate.latitude ?? 0, 48.85837, accuracy: 1e-6)
        XCTAssertEqual(match?.coordinate.longitude ?? 0, 2.29448, accuracy: 1e-6)
        XCTAssertNil(match?.name)
    }

    func testPairWithoutSpace() {
        XCTAssertEqual(CoordinateParser.parse("48.85837,2.29448")?.coordinate.latitude ?? 0, 48.85837, accuracy: 1e-6)
    }

    func testWhitespaceSeparatedPair() {
        XCTAssertEqual(CoordinateParser.parse("48.85837 2.29448")?.coordinate.longitude ?? 0, 2.29448, accuracy: 1e-6)
    }

    /// "48,8584 2,2945" — the decimal comma, which is how most of Europe writes
    /// this and what a French or German keyboard produces.
    func testEuropeanDecimalCommas() {
        let match = CoordinateParser.parse("48,85837 2,29448")
        XCTAssertEqual(match?.coordinate.latitude ?? 0, 48.85837, accuracy: 1e-6)
        XCTAssertEqual(match?.coordinate.longitude ?? 0, 2.29448, accuracy: 1e-6)
    }

    func testNegativeCoordinates() {
        let match = CoordinateParser.parse("-33.86882, 151.20930")
        XCTAssertEqual(match?.coordinate.latitude ?? 0, -33.86882, accuracy: 1e-6)
        XCTAssertEqual(match?.coordinate.longitude ?? 0, 151.20930, accuracy: 1e-6)
    }

    func testSurroundingWhitespaceIsIgnored() {
        XCTAssertNotNil(CoordinateParser.parse("   48.85837, 2.29448 \n"))
    }

    // MARK: Refusals

    /// The one that matters most: a place name must reach the place search.
    func testPlaceNameIsNotACoordinate() {
        XCTAssertNil(CoordinateParser.parse("Paris"))
        XCTAssertNil(CoordinateParser.parse("Eiffel Tower"))
        XCTAssertNil(CoordinateParser.parse("221B Baker Street"))
    }

    /// Free text needs a decimal separator. "12, 5" is the start of a street
    /// address far more often than it is a point in the Gulf of Guinea.
    func testIntegerPairIsRefusedInFreeText() {
        XCTAssertNil(CoordinateParser.parse("12, 5"))
        XCTAssertNil(CoordinateParser.parse("1 2"))
    }

    func testOutOfRangeIsRefused() {
        XCTAssertNil(CoordinateParser.parse("91.5, 2.0"))
        XCTAssertNil(CoordinateParser.parse("48.5, 181.2"))
    }

    func testEmptyIsRefused() {
        XCTAssertNil(CoordinateParser.parse(""))
        XCTAssertNil(CoordinateParser.parse("   "))
    }

    func testThreeNumbersAreRefused() {
        XCTAssertNil(CoordinateParser.parse("48.1, 2.2, 3.3"))
    }

    // MARK: geo:

    func testGeoURI() {
        let match = CoordinateParser.parse("geo:48.85837,2.29448")
        XCTAssertEqual(match?.coordinate.latitude ?? 0, 48.85837, accuracy: 1e-6)
    }

    func testGeoURIWithLabelledQuery() {
        let match = CoordinateParser.parse("geo:0,0?q=48.85837,2.29448(Eiffel%20Tower)")
        XCTAssertEqual(match?.coordinate.latitude ?? 0, 48.85837, accuracy: 1e-6)
        XCTAssertEqual(match?.name, "Eiffel Tower")
    }

    /// `geo:0,0?q=…` is the standard way of saying "no coordinate, use the
    /// query". Taking the 0,0 literally would drop a pin in the Atlantic.
    func testNullIslandIsNotTakenLiterally() {
        XCTAssertNil(CoordinateParser.parse("geo:0,0"))
    }

    // MARK: Map URLs

    func testAppleMapsLatLon() {
        let match = CoordinateParser.parse("https://maps.apple.com/?ll=48.85837,2.29448")
        XCTAssertEqual(match?.coordinate.latitude ?? 0, 48.85837, accuracy: 1e-6)
    }

    func testAppleMapsKeepsQueryAsNameWhenItIsNotNumbers() {
        let match = CoordinateParser.parse("https://maps.apple.com/?ll=48.85837,2.29448&q=Tour%20Eiffel")
        XCTAssertEqual(match?.name, "Tour Eiffel")
    }

    func testGoogleMapsCameraSegment() {
        let match = CoordinateParser.parse("https://www.google.com/maps/place/Eiffel+Tower/@48.85837,2.29448,17z")
        XCTAssertEqual(match?.coordinate.latitude ?? 0, 48.85837, accuracy: 1e-6)
        XCTAssertEqual(match?.name, "Eiffel Tower")
    }

    func testGoogleMapsQuery() {
        let match = CoordinateParser.parse("https://www.google.com/maps?q=48.85837,2.29448")
        XCTAssertEqual(match?.coordinate.longitude ?? 0, 2.29448, accuracy: 1e-6)
    }

    func testOpenStreetMapFragment() {
        let match = CoordinateParser.parse("https://www.openstreetmap.org/#map=17/48.85837/2.29448")
        XCTAssertEqual(match?.coordinate.latitude ?? 0, 48.85837, accuracy: 1e-6)
    }

    /// Links arrive inside sentences far more often than on their own.
    func testURLEmbeddedInProse() {
        let match = CoordinateParser.parse("look at this https://maps.apple.com/?ll=48.85837,2.29448 nice right")
        XCTAssertEqual(match?.coordinate.latitude ?? 0, 48.85837, accuracy: 1e-6)
    }

    // MARK: Locus links

    func testLocusTeleportLink() {
        let match = CoordinateParser.parse("locus://teleport?lat=48.85837&lon=2.29448&name=Home")
        XCTAssertEqual(match?.coordinate.latitude ?? 0, 48.85837, accuracy: 1e-6)
        XCTAssertEqual(match?.name, "Home")
    }

    func testDeepLinkRoundTrip() {
        let original = CLLocationCoordinate2D(latitude: 48.85837, longitude: 2.29448)
        let url = CoordinateParser.deepLink(original, name: "Tour Eiffel")
        let parsed = url.flatMap { CoordinateParser.fromURL($0) }
        XCTAssertEqual(parsed?.coordinate.latitude ?? 0, original.latitude, accuracy: 1e-9)
        XCTAssertEqual(parsed?.coordinate.longitude ?? 0, original.longitude, accuracy: 1e-9)
        XCTAssertEqual(parsed?.name, "Tour Eiffel")
    }

    // MARK: Degrees, minutes, seconds

    func testDegreesMinutesSeconds() {
        let match = CoordinateParser.parse("48°51'30.1\"N 2°17'40.1\"E")
        XCTAssertEqual(match?.coordinate.latitude ?? 0, 48.858361, accuracy: 1e-4)
        XCTAssertEqual(match?.coordinate.longitude ?? 0, 2.294472, accuracy: 1e-4)
    }

    func testSouthAndWestAreNegative() {
        let match = CoordinateParser.parse("33°51'24.0\"S 151°12'33.5\"W")
        XCTAssertLessThan(match?.coordinate.latitude ?? 0, 0)
        XCTAssertLessThan(match?.coordinate.longitude ?? 0, 0)
    }

    // MARK: Formatting

    func testTextIsFiveDecimals() {
        let text = CoordinateParser.text(CLLocationCoordinate2D(latitude: 48.858370123, longitude: 2.294480987))
        XCTAssertEqual(text, "48.85837, 2.29448")
    }

    /// What Locus writes must be what Locus reads.
    func testFormattedTextParsesBack() {
        let original = CLLocationCoordinate2D(latitude: -33.86882, longitude: 151.20930)
        let parsed = CoordinateParser.parse(CoordinateParser.text(original))
        XCTAssertEqual(parsed?.coordinate.latitude ?? 0, original.latitude, accuracy: 1e-5)
        XCTAssertEqual(parsed?.coordinate.longitude ?? 0, original.longitude, accuracy: 1e-5)
    }

    func testLooksLikeCoordinateAgreesWithParse() {
        XCTAssertTrue(CoordinateParser.looksLikeCoordinate("48.85837, 2.29448"))
        XCTAssertFalse(CoordinateParser.looksLikeCoordinate("Paris"))
    }
}
