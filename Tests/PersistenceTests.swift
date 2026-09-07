import CoreLocation
import XCTest

/// Decoding is where this app can silently destroy something someone made.
///
/// Every one of these types is written to disk by an older build and read by a
/// newer one, and synthesised `Codable` throws on a single missing key — which
/// the loaders answer by handing back an empty list. So "a field was added"
/// and "every favourite you had is gone" are one bug apart, and these tests are
/// the thing standing between them.
final class PersistenceTests: XCTestCase {
    // MARK: SavedPlace

    /// Entries written before `id` existed must survive, not be discarded.
    func testLegacySavedPlaceWithoutIDStillDecodes() throws {
        let json = #"[{"name":"Home","latitude":48.85837,"longitude":2.29448}]"#
        let places = try JSONDecoder().decode([SavedPlace].self, from: Data(json.utf8))
        XCTAssertEqual(places.count, 1)
        XCTAssertEqual(places[0].name, "Home")
        XCTAssertEqual(places[0].latitude, 48.85837, accuracy: 1e-6)
    }

    func testLegacySavedPlacesGetDistinctMintedIDs() throws {
        let json = """
        [{"name":"A","latitude":1.5,"longitude":2.5},
         {"name":"B","latitude":3.5,"longitude":4.5}]
        """
        let places = try JSONDecoder().decode([SavedPlace].self, from: Data(json.utf8))
        XCTAssertEqual(Set(places.map(\.id)).count, 2, "two entries must not collide on one id")
    }

    func testSavedPlaceRoundTrips() throws {
        let original = SavedPlace(name: "Tour Eiffel", latitude: 48.85837, longitude: 2.29448)
        let decoded = try JSONDecoder().decode(
            SavedPlace.self, from: JSONEncoder().encode(original)
        )
        XCTAssertEqual(decoded, original)
    }

    /// `isAt` is what "the same place" means everywhere now — dedupe, the star
    /// button's filled state, Siri's list.
    func testIsAtToleranceIsAboutFifteenMetres() {
        let place = SavedPlace(name: "Home", latitude: 48.85837, longitude: 2.29448)
        XCTAssertTrue(place.isAt(CLLocationCoordinate2D(latitude: 48.85838, longitude: 2.29449)))
        XCTAssertFalse(place.isAt(CLLocationCoordinate2D(latitude: 48.86000, longitude: 2.29448)))
    }

    // MARK: DriveProfile

    /// The reason `DriveProfile` decodes field by field: adding one parameter
    /// must not reset the other thirty.
    func testProfileWithOnlyOneKnownFieldKeepsDefaultsForTheRest() throws {
        let json = #"{"speedTolerance":0.25}"#
        let profile = try JSONDecoder().decode(DriveProfile.self, from: Data(json.utf8))
        let fresh = DriveProfile()
        XCTAssertEqual(profile.speedTolerance, 0.25, accuracy: 1e-9)
        XCTAssertEqual(profile.timeScale, fresh.timeScale)
        XCTAssertEqual(profile.gpsNoiseMetres, fresh.gpsNoiseMetres, accuracy: 1e-9)
        XCTAssertEqual(profile.stopAtJunctions, fresh.stopAtJunctions)
    }

    func testProfileFromAnEmptyObjectIsAllDefaults() throws {
        let profile = try JSONDecoder().decode(DriveProfile.self, from: Data("{}".utf8))
        XCTAssertEqual(profile.speedCeiling, DriveProfile().speedCeiling, accuracy: 1e-9)
    }

    func testProfileRoundTripsEveryField() throws {
        var original = DriveProfile(name: "Commute")
        original.speedTolerance = 0.17
        original.timeScale = 4
        original.traffic = .heavy
        original.keepScreenAwake = false
        original.junctionStopSeconds = ClosedRangeBox(lower: 12, upper: 44)

        let decoded = try JSONDecoder().decode(
            DriveProfile.self, from: JSONEncoder().encode(original)
        )
        XCTAssertEqual(decoded, original)
    }

    // MARK: ClosedRangeBox

    /// The two bounds are edited by independent sliders, so an inverted pair is
    /// reachable from the UI. Reading the range must not trap.
    func testInvertedRangeIsClampedNotCrashed() {
        let box = ClosedRangeBox(lower: 90, upper: 10)
        XCTAssertEqual(box.range.lowerBound, 10, accuracy: 1e-9)
        XCTAssertEqual(box.range.upperBound, 90, accuracy: 1e-9)
        for _ in 0..<50 {
            let value = box.randomValue()
            XCTAssertTrue((10...90).contains(value))
        }
    }

    func testDegenerateRangeReturnsItsOnlyValue() {
        XCTAssertEqual(ClosedRangeBox(lower: 7, upper: 7).randomValue(), 7, accuracy: 1e-9)
    }

    // MARK: SavedRoute

    /// A route saved before `recordedTimes` existed must still load.
    func testLegacySavedRouteWithoutRecordedTimesDecodes() throws {
        let json = """
        {"id":"7C6C8A2E-9C2F-4C0A-9A1E-9C1F2A3B4C5D",
         "name":"Commute",
         "coordinates":[{"latitude":48.1,"longitude":2.1},{"latitude":48.2,"longitude":2.2}],
         "distance":1200.0,
         "expectedTravelTime":300.0,
         "overrides":[],
         "createdAt":760000000.0}
        """
        let route = try JSONDecoder().decode(SavedRoute.self, from: Data(json.utf8))
        XCTAssertEqual(route.name, "Commute")
        XCTAssertNil(route.recordedTimes)
        XCTAssertEqual(route.coordinates.count, 2)
    }

    func testSavedRouteKeepsRecordedTimesAcrossASave() throws {
        let times = [Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: 60)]
        let built = BuiltRoute(
            name: "Ride",
            coordinates: [
                CLLocationCoordinate2D(latitude: 48.1, longitude: 2.1),
                CLLocationCoordinate2D(latitude: 48.2, longitude: 2.2),
            ],
            distance: 1200,
            expectedTravelTime: 60,
            recordedTimes: times
        )
        let decoded = try JSONDecoder().decode(
            SavedRoute.self,
            from: JSONEncoder().encode(SavedRoute(name: "Ride", route: built))
        )
        XCTAssertEqual(decoded.recordedTimes?.count, 2)
        XCTAssertNotNil(decoded.built.recordedSpeedSampler(), "the pace must survive the round trip")
    }

    /// A pace mapped onto the wrong places is worse than no pace at all, so a
    /// mismatched count is dropped rather than used.
    func testMismatchedRecordedTimesAreDropped() {
        var route = SavedRoute(
            name: "Odd",
            route: BuiltRoute(
                name: "Odd",
                coordinates: [
                    CLLocationCoordinate2D(latitude: 48.1, longitude: 2.1),
                    CLLocationCoordinate2D(latitude: 48.2, longitude: 2.2),
                ],
                distance: 1000,
                expectedTravelTime: 100
            )
        )
        route.recordedTimes = [Date()]
        XCTAssertNil(route.built.recordedTimes)
    }

    func testExpectedSpeedIsNilWithoutTiming() {
        let route = SavedRoute(
            name: "Drawn",
            route: BuiltRoute(name: "Drawn", coordinates: [], distance: 500, expectedTravelTime: 0)
        )
        XCTAssertNil(route.expectedSpeed)
    }

    // MARK: LimitOverride

    func testOverrideContainsIsInclusive() {
        let override = LimitOverride(startDistance: 100, endDistance: 200, limit: 13.9)
        XCTAssertTrue(override.contains(100))
        XCTAssertTrue(override.contains(150))
        XCTAssertTrue(override.contains(200))
        XCTAssertFalse(override.contains(99))
        XCTAssertFalse(override.contains(201))
    }
}
