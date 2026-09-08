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

    /// France splits busy roads by letter. A6a and A6b are the two halves of
    /// the A6 into Paris, and suffixed D roads are everywhere — and every one
    /// of them used to parse as nothing, because the digits ran into the letter
    /// and there was no word boundary to close the match on.
    func testSuffixedRoadNumbersParse() {
        XCTAssertEqual(RoadClass.parse("Continuer sur A6a"), .motorway)
        XCTAssertEqual(RoadClass.parse("Prendre A6b vers Paris"), .motorway)
        XCTAssertEqual(RoadClass.parse("Continuer sur D 6A"), .departmental)
        XCTAssertEqual(RoadClass.parse("Rejoindre la D920A"), .departmental)
        XCTAssertEqual(RoadClass.parse("Prendre la N 2A"), .national)
    }

    /// The suffix must not swallow the metre abbreviation. "N 500m" is five
    /// hundred metres however it is spaced.
    func testASuffixIsNeverTheUnit() {
        XCTAssertNil(RoadClass.parse("Continuer N 500m"))
        XCTAssertNil(RoadClass.parse("Continuer N 500 m"))
        XCTAssertNil(RoadClass.parse("Dans 300m"))
    }

    // MARK: Joining runs

    /// Consecutive steps on one road are still separate steps.
    func testTouchingRunsOfOneClassBecomeOneSegment() {
        let joined = [
            RoadSegment(startDistance: 0, endDistance: 400, roadClass: .motorway),
            RoadSegment(startDistance: 400, endDistance: 40_000, roadClass: .motorway),
        ].joinedRuns()
        XCTAssertEqual(joined, [
            RoadSegment(startDistance: 0, endDistance: 40_000, roadClass: .motorway)
        ])
    }

    /// The reported bug from the other side: an unnamed step ("Keep left")
    /// punches a hole through the middle of the A1, and the shape heuristic
    /// fills the hole with a town speed. A kilometre of silence inside forty
    /// kilometres of motorway is the motorway.
    func testAShortHoleInsideOneRoadIsClaimed() {
        let joined = [
            RoadSegment(startDistance: 0, endDistance: 20_000, roadClass: .motorway),
            RoadSegment(startDistance: 21_000, endDistance: 40_000, roadClass: .motorway),
        ].joinedRuns()
        XCTAssertEqual(joined.count, 1)
        XCTAssertEqual(joined.first?.roadClass, .motorway)
        XCTAssertEqual(joined.roadClass(at: 20_500), .motorway)
    }

    /// And the other way, which is why the test is scale-relative rather than a
    /// threshold: forty kilometres of silence between two brief mentions of a D
    /// road is not that D road, and is left to the shape heuristic.
    func testALongHoleBetweenBriefMentionsIsNotClaimed() {
        let joined = [
            RoadSegment(startDistance: 0, endDistance: 500, roadClass: .departmental),
            RoadSegment(startDistance: 40_000, endDistance: 40_500, roadClass: .departmental),
        ].joinedRuns()
        XCTAssertEqual(joined.count, 2)
        XCTAssertNil(joined.roadClass(at: 20_000))
    }

    /// A hole between two different classes is a real change of road, so it
    /// stays a hole whatever its length.
    func testAHoleBetweenDifferentClassesIsNeverClaimed() {
        let joined = [
            RoadSegment(startDistance: 0, endDistance: 40_000, roadClass: .motorway),
            RoadSegment(startDistance: 40_100, endDistance: 80_000, roadClass: .departmental),
        ].joinedRuns()
        XCTAssertEqual(joined.count, 2)
        XCTAssertNil(joined.roadClass(at: 40_050))
    }

    /// Joining must not invent coverage outside the segments it was given, and
    /// must leave the list in order for the estimator's cursor walk.
    func testJoiningStaysInOrderAndInsideItsBounds() {
        let input = [
            RoadSegment(startDistance: 0, endDistance: 1_000, roadClass: .street),
            RoadSegment(startDistance: 1_000, endDistance: 1_400, roadClass: .motorway),
            RoadSegment(startDistance: 1_600, endDistance: 30_000, roadClass: .motorway),
            RoadSegment(startDistance: 30_000, endDistance: 31_000, roadClass: .street),
        ]
        let joined = input.joinedRuns()
        XCTAssertEqual(joined.first?.startDistance, input.first?.startDistance)
        XCTAssertEqual(joined.last?.endDistance, input.last?.endDistance)
        for (a, b) in zip(joined, joined.dropFirst()) {
            XCTAssertLessThanOrEqual(a.endDistance, b.startDistance)
            XCTAssertLessThan(a.startDistance, a.endDistance)
        }
        XCTAssertNil(joined.roadClass(at: 31_500))
    }

    func testJoiningEmptyAndSingleAreLeftAlone() {
        XCTAssertEqual([RoadSegment]().joinedRuns(), [])
        let one = [RoadSegment(startDistance: 0, endDistance: 10, roadClass: .national)]
        XCTAssertEqual(one.joinedRuns(), one)
    }
}
