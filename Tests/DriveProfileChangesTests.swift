import XCTest

/// The changes list is the only answer the app gives to "why does this profile
/// drive like that", and it is only worth anything if it is complete.
///
/// A parameter added to `DriveProfile` and forgotten here doesn't break
/// anything visibly — it just quietly never appears in the list, so the one
/// slider somebody nudged is the one the summary doesn't mention.
final class DriveProfileChangesTests: XCTestCase {

    // MARK: - Completeness

    func testEveryStoredParameterHasARowInTheTable() {
        let stored = Set(Mirror(reflecting: DriveProfile()).children.compactMap(\.label))
        let listed = Set(DriveProfile.fields.map(\.id))
        // Identity isn't a driving parameter: every profile differs from the
        // default by having its own id, and most by having a name.
        let identity: Set<String> = ["id", "name"]

        XCTAssertEqual(
            stored.subtracting(identity),
            listed,
            "a driving parameter exists with no row in the changes table, or a row names a field that is gone"
        )
    }

    func testFieldIDsAreUnique() {
        let ids = DriveProfile.fields.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "two rows sharing an id makes Revert land on the wrong one")
    }

    // MARK: - What it reports

    func testAnUntouchedProfileHasChangedNothing() {
        XCTAssertTrue(DriveProfile().changes().isEmpty)
    }

    func testANameIsNotAChange() {
        var profile = DriveProfile()
        profile.name = "Commute"
        XCTAssertTrue(profile.changes().isEmpty, "every profile has a name; that is not something anyone tuned")
    }

    func testOneNudgedSliderIsOneRow() {
        var profile = DriveProfile()
        profile.speedTolerance = 0.22

        let changes = profile.changes()
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.id, "speedTolerance")
        XCTAssertEqual(changes.first?.label, "Tolerance")
        XCTAssertEqual(changes.first?.value, "+22%")
        XCTAssertEqual(changes.first?.standard, "+10%")
    }

    func testSpeedsAreReportedInTheProfilesOwnUnits() {
        // Deliberately not asserting how many rows this produces: on a metric
        // phone the conversion itself moves units, the fixed speed and the
        // ceiling, and on an imperial one it moves nothing. The unit the number
        // is written in is the thing under test.
        var profile = DriveProfile()
        profile.convert(to: .mph)
        profile.fixedSpeed = 45

        guard let fixed = profile.changes().first(where: { $0.id == "fixedSpeed" }) else {
            return XCTFail("changing the fixed speed must show up")
        }
        XCTAssertEqual(fixed.value, "45 mph")

        profile.convert(to: .kph)
        guard let metric = profile.changes().first(where: { $0.id == "fixedSpeed" }) else {
            return XCTFail("it is still a change after a conversion")
        }
        XCTAssertTrue(metric.value.hasSuffix("km/h"), "got \(metric.value)")
    }

    func testRowsComeOutInTheOrderTheSheetShowsThem() {
        var profile = DriveProfile()
        profile.consumption = 9.9        // last section
        profile.speedTolerance = 0.2     // first section
        profile.traffic = other(TrafficDensity.allCases, than: profile.traffic)

        let ids = profile.changes().map(\.id)
        let expected = DriveProfile.fields.map(\.id).filter { ids.contains($0) }
        XCTAssertEqual(ids, expected)
    }

    // MARK: - Putting it back

    func testRevertingOneRowLeavesTheRest() {
        var profile = DriveProfile()
        profile.gpsNoiseMetres = 9
        profile.laneOffsetMetres = 0

        profile.revert("gpsNoiseMetres")

        XCTAssertEqual(profile.gpsNoiseMetres, DriveProfile().gpsNoiseMetres, accuracy: 1e-9)
        XCTAssertEqual(profile.changes().map(\.id), ["laneOffsetMetres"])
    }

    func testRevertingAnUnknownRowChangesNothing() {
        var profile = DriveProfile()
        profile.gpsNoiseMetres = 9
        let before = profile

        profile.revert("somethingThatWasRemovedTwoBuildsAgo")

        XCTAssertEqual(profile, before)
    }

    func testRevertingEverythingKeepsTheProfileItself() {
        var profile = DriveProfile()
        let id = profile.id
        profile.name = "Commute"
        profile.traffic = other(TrafficDensity.allCases, than: profile.traffic)
        profile.gpsNoiseMetres = 9
        profile.showHUD.toggle()

        profile.revertAll()

        XCTAssertTrue(profile.changes().isEmpty)
        XCTAssertEqual(profile.id, id, "a reset must not orphan the profile it was run on")
        XCTAssertEqual(profile.name, "Commute", "or rename it")
    }

    // MARK: -

    /// Any case but the one given, so a test can change an enum without
    /// hard-coding a case that may be renamed.
    private func other<T: Equatable>(_ all: [T], than current: T) -> T {
        all.first { $0 != current } ?? current
    }
}
