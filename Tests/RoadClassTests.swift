import CoreLocation
import XCTest

/// Reading the road number out of what MapKit says.
///
/// Reported from the field: "même en ville sur l'A1 il considère 110 alors que
/// 130". The estimator knew only the road's shape, scaled off one average for
/// the whole journey — so an autoroute inside a mostly-urban route was dragged
/// down to 110, and everything else pinned at 30 or 50. Continental road
/// numbering carries the classification, and it was being thrown away.
final class RoadClassTests: XCTestCase {
    func testAutorouteIsReadAsMotorway() {
        XCTAssertEqual(RoadClass.parse("Prendre l'autoroute A1"), .motorway)
        XCTAssertEqual(RoadClass.parse("Continuer sur A86"), .motorway)
        XCTAssertEqual(RoadClass.parse("Take A7"), .motorway)
    }

    func testNationalAndDepartmental() {
        XCTAssertEqual(RoadClass.parse("Continuer sur N 104"), .national)
        XCTAssertEqual(RoadClass.parse("Rejoindre la RN20"), .national)
        XCTAssertEqual(RoadClass.parse("Continuer sur D 1017"), .departmental)
        XCTAssertEqual(RoadClass.parse("Prendre la RD 920"), .departmental)
    }

    /// A junction instruction names the road you are leaving and the one you
    /// are joining. The faster of the two is the road being joined, which is
    /// the one whose limit applies next.
    func testAJunctionTakesTheMoreMajorRoad() {
        XCTAssertEqual(RoadClass.parse("Depuis D 1017, rejoindre A1"), .motorway)
        XCTAssertEqual(RoadClass.parse("Sortir de A1 vers D 1017"), .motorway)
        XCTAssertEqual(RoadClass.parse("De D 920 vers N 104"), .national)
    }

    func testAStreetNameIsNotARoadNumber() {
        XCTAssertNil(RoadClass.parse("Tourner à gauche sur Rue Marie de France"))
        XCTAssertNil(RoadClass.parse("Continuer tout droit"))
        XCTAssertNil(RoadClass.parse("Prendre la 3e sortie au rond-point"))
    }

    /// The one that would quietly poison everything: a distance reading as a
    /// road number. "N 500 M" is five hundred metres, not the N500.
    func testADistanceIsNotARoad() {
        XCTAssertNil(RoadClass.parse("Dans 500 m"))
        XCTAssertNil(RoadClass.parse("Continuer pendant 12 km"))
        XCTAssertNil(RoadClass.parse("Dans 2 min"))
        // The case the trailing unit check exists for: this is five hundred
        // metres, not the N500.
        XCTAssertNil(RoadClass.parse("Continuer N 500 m"))
    }

    /// European numbers always overlay a national road, so the local number is
    /// the one that carries the limit — and E on its own says nothing.
    func testEuropeanNumbersAreIgnored() {
        XCTAssertNil(RoadClass.parse("Continuer sur E15"))
        XCTAssertEqual(RoadClass.parse("Continuer sur A1/E15"), .motorway)
    }

    func testTheBandsAreOrderedAndDoNotInvert() {
        for roadClass in RoadClass.allCases {
            let band = roadClass.bandKph
            XCTAssertLessThan(band.lowerBound, band.upperBound, "\(roadClass)")
            XCTAssertGreaterThan(band.lowerBound, 0, "\(roadClass)")
        }
        // The whole point: an autoroute can never estimate below a street's top.
        XCTAssertGreaterThan(RoadClass.motorway.bandKph.lowerBound, RoadClass.street.bandKph.upperBound)
        XCTAssertGreaterThanOrEqual(RoadClass.motorway.bandKph.upperBound, 130)
    }

    // MARK: Segments

    func testSegmentLookupByDistance() {
        let roads = [
            RoadSegment(startDistance: 0, endDistance: 1000, roadClass: .street),
            RoadSegment(startDistance: 1000, endDistance: 50_000, roadClass: .motorway),
        ]
        XCTAssertEqual(roads.roadClass(at: 500), .street)
        XCTAssertEqual(roads.roadClass(at: 1000), .motorway, "the boundary belongs to the road being joined")
        XCTAssertEqual(roads.roadClass(at: 49_999), .motorway)
        XCTAssertNil(roads.roadClass(at: 60_000), "past the end nothing is claimed")
        XCTAssertNil([RoadSegment]().roadClass(at: 10))
    }
}
