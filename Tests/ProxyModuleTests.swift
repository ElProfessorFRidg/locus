import CoreLocation
import XCTest

/// A module is text another app parses, and nothing in Locus ever reads it
/// back — so a coordinate written with a decimal comma, or a place name that
/// breaks a header line, would fail inside Shadowrocket with no word to Locus.
final class ProxyModuleTests: XCTestCase {
    private let eiffel = CLLocationCoordinate2D(latitude: 48.858370, longitude: 2.294481)

    private func module(_ app: ProxyApp, place: String? = nil, accuracy: Int = 39) -> ProxyModule {
        ProxyModule(app: app, coordinate: eiffel, place: place, horizontalAccuracy: accuracy)
    }

    func testArgumentCarriesTheCoordinate() {
        XCTAssertEqual(
            module(.shadowrocket, accuracy: 10).argument,
            "mode=response&latitude=48.858370&longitude=2.294481&horizontalAccuracy=10"
        )
    }

    func testNegativeCoordinatesKeepTheirSign() {
        let sydney = ProxyModule(app: .stash, coordinate: CLLocationCoordinate2D(latitude: -33.86882, longitude: 151.2093))
        XCTAssertTrue(sydney.argument.contains("latitude=-33.868820&longitude=151.209300"))
    }

    /// The phone's locale must not reach the numbers: a French one writes
    /// "48,858370", which the script would read as 48.
    func testDegreesAlwaysUseADot() {
        XCTAssertEqual(ProxyModule.degrees(48.85837), "48.858370")
        XCTAssertFalse(module(.surge).text.contains("48,858370"))
    }

    func testEveryFormatInterceptsEveryHostAndLoadsTheScript() {
        for app in ProxyApp.allCases {
            let text = module(app).text
            for host in ProxyModule.hostnames {
                XCTAssertTrue(text.contains(host), "\(app.title) is missing \(host)")
            }
            XCTAssertTrue(text.contains(ProxyModule.scriptURL), "\(app.title) doesn't load the script")
            XCTAssertTrue(text.contains(ProxyModule.pattern), "\(app.title) doesn't match the lookup")
        }
    }

    func testEveryFormatCarriesTheCoordinate() {
        for app in ProxyApp.allCases {
            let text = module(app).text
            XCTAssertTrue(text.contains("48.858370"), "\(app.title) lost the latitude")
            XCTAssertTrue(text.contains("2.294481"), "\(app.title) lost the longitude")
        }
    }

    /// Surge substitutes `{{{name}}}` from `#!arguments`, so the script line
    /// must use the placeholders and the header must declare them.
    func testSurgeUsesEditableArguments() {
        let text = module(.surge).text
        XCTAssertTrue(text.contains("#!arguments=latitude:48.858370,longitude:2.294481,horizontalAccuracy:39"))
        XCTAssertTrue(text.contains("latitude={{{latitude}}}&longitude={{{longitude}}}"))
    }

    /// Loon substitutes only `[{name}]` arguments declared under `[Argument]`.
    func testLoonDeclaresWhatItPasses() {
        let text = module(.loon).text
        XCTAssertTrue(text.contains("[Argument]"))
        XCTAssertTrue(text.contains(#"latitude = input,"48.858370""#))
        XCTAssertTrue(text.contains("argument=[{enabled},{latitude},{longitude},{horizontalAccuracy}]"))
        XCTAssertTrue(text.contains("http-request "), "Loon needs the uncompressed-answer request script")
    }

    func testStashIndentsTheHostsUnderMitm() {
        let text = module(.stash).text
        XCTAssertTrue(text.contains("  mitm:\n    - gs-loc.apple.com\n    - gs-loc-cn.apple.com"))
        XCTAssertTrue(text.contains(#"argument: "mode=response&latitude=48.858370"#))
    }

    /// A place name is a geocoder's output or something typed: a newline in
    /// it would end the `#!desc` line and start a header of its own.
    func testPlaceNameCannotBreakAHeader() {
        let text = module(.shadowrocket, place: "Tour Eiffel\n#!name=Evil").text
        XCTAssertFalse(text.components(separatedBy: "\n").contains { $0.hasPrefix("#!name=Evil") })
        XCTAssertTrue(text.contains("#!desc=Puts Apple's Wi-Fi location at Tour Eiffel #!name=Evil (48.858370, 2.294481)"))
    }

    func testPlaceNameIsQuotedInYAML() {
        let text = module(.stash, place: #"The "Iron" Lady \ Paris"#).text
        XCTAssertTrue(text.contains(#"desc: "Puts Apple's Wi-Fi location at The \"Iron\" Lady \\ Paris (48.858370, 2.294481). Made by Locus.""#))
    }

    func testEmptyPlaceIsLeftOut() {
        XCTAssertEqual(module(.surge, place: "  \n ").summary, "Puts Apple's Wi-Fi location at 48.858370, 2.294481. Made by Locus.")
    }

    /// The same file name every time, so a new place replaces the old module
    /// instead of installing a second one beside it.
    func testFileNameIsStable() {
        XCTAssertEqual(module(.shadowrocket).fileName, "Locus.sgmodule")
        XCTAssertEqual(module(.surge).fileName, "Locus.sgmodule")
        XCTAssertEqual(module(.loon).fileName, "Locus.lnplugin")
        XCTAssertEqual(module(.stash).fileName, "Locus.stoverride")
    }
}
