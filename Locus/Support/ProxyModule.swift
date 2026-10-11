import CoreLocation
import Foundation

/// A proxy app that can rewrite Apple's location answers on their way back to
/// the phone, given a module that tells it how.
///
/// Quantumult X is missing on purpose: its rewrite takes no argument, so the
/// coordinates live inside the script itself and there is nothing for Locus to
/// write into a module.
enum ProxyApp: String, CaseIterable, Identifiable {
    case shadowrocket
    case surge
    case loon
    case stash

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shadowrocket: return "Shadowrocket"
        case .surge: return "Surge"
        case .loon: return "Loon"
        case .stash: return "Stash"
        }
    }

    /// What each app calls the thing being made, so the instructions use the
    /// word the user will find in that app's own menus.
    var moduleNoun: String {
        switch self {
        case .shadowrocket, .surge: return "module"
        case .loon: return "plugin"
        case .stash: return "override"
        }
    }

    var fileExtension: String {
        switch self {
        case .shadowrocket, .surge: return "sgmodule"
        case .loon: return "lnplugin"
        case .stash: return "stoverride"
        }
    }
}

/// A module that moves the phone by rewriting Apple's Wi-Fi location answers,
/// for when the developer service can't be reached at all — no pairing file,
/// no tunnel, a re-sign that stripped both.
///
/// It is the weaker of the two ways. iOS asks Apple where the Wi-Fi networks
/// and cell towers around it are, and works out its own position from the
/// answer; a MITM proxy can change that answer, so the phone concludes it is
/// somewhere else. But that only covers the network part of the fix: outdoors,
/// with a clear sky, real GPS wins and the phone walks back home. The
/// developer service has no such hole, which is why it stays the default.
///
/// The rewriting is done by ios-location-spoofer (github.com/mekos2772), whose
/// script the proxy app downloads itself from `scriptURL`. That project is
/// AGPL-3.0 and Locus is MIT, so none of its code is copied here: what Locus
/// writes is only the module — which hosts to intercept, where the script
/// lives, and the coordinates to hand it.
struct ProxyModule {
    static let homepage = URL(string: "https://github.com/mekos2772/ios-location-spoofer")!
    static let scriptURL = "https://raw.githubusercontent.com/mekos2772/ios-location-spoofer/main/location-spoofer.js"

    /// Every host Apple's location lookup has been seen on, the Chinese
    /// mainland ones included. Kept to exactly these: a wildcard over
    /// `*.apple.com` would decrypt far more than this needs to read.
    static let hostnames = [
        "gs-loc.apple.com",
        "gs-loc-cn.apple.com",
        "gsp-ssl.ls.apple.com",
        "bluedot.is.autonavi.com",
        "bluedot.is.autonavi.com.gds.alibabadns.com",
    ]

    static let pattern = #"^https?:\/\/(?:gs-loc(?:-cn)?\.apple\.com|gsp-ssl\.ls\.apple\.com|bluedot\.is\.autonavi\.com(?:\.gds\.alibabadns\.com)?)\/clls\/wloc"#

    /// Radii, in metres, the module can claim. Smaller reads more like GPS;
    /// 39 is what the script defaults to.
    static let accuracyChoices = [10, 39, 65, 100]
    static let defaultAccuracy = 39

    /// Always the same name, so importing a new place replaces the last one
    /// instead of leaving two modules fighting over the same response.
    static let name = "Locus"

    let app: ProxyApp
    let coordinate: CLLocationCoordinate2D
    var place: String?
    var horizontalAccuracy: Int = ProxyModule.defaultAccuracy

    var fileName: String { "\(Self.name).\(app.fileExtension)" }

    var latitudeText: String { Self.degrees(coordinate.latitude) }
    var longitudeText: String { Self.degrees(coordinate.longitude) }

    /// The script's argument string, as Shadowrocket and Stash pass it.
    var argument: String {
        "mode=response&latitude=\(latitudeText)&longitude=\(longitudeText)&horizontalAccuracy=\(horizontalAccuracy)"
    }

    /// One line saying where this module puts the phone. A place name is
    /// whatever a geocoder or a user typed, so anything that could end the
    /// line — and with it the header it sits in — is flattened first.
    var summary: String {
        let spot = "\(latitudeText), \(longitudeText)"
        guard let place = place.map(Self.singleLine), !place.isEmpty else {
            return "Puts Apple's Wi-Fi location at \(spot). Made by Locus."
        }
        return "Puts Apple's Wi-Fi location at \(place) (\(spot)). Made by Locus."
    }

    var text: String {
        switch app {
        case .shadowrocket: return shadowrocketText
        case .surge: return surgeText
        case .loon: return loonText
        case .stash: return stashText
        }
    }

    // MARK: - Formats

    private var header: String {
        """
        #!name=\(Self.name)
        #!desc=\(summary)
        #!homepage=\(Self.homepage.absoluteString)
        """
    }

    private var shadowrocketText: String {
        """
        \(header)

        [Script]
        Locus location = type=http-response,pattern=\(Self.pattern),requires-body=1,binary-body-mode=1,max-size=0,timeout=30,script-path=\(Self.scriptURL),argument=\(argument)

        [MITM]
        hostname = %APPEND% \(Self.hostnames.joined(separator: ", "))

        """
    }

    /// Surge shows `#!arguments` as editable fields, so the place can be
    /// nudged in Surge later without coming back here.
    private var surgeText: String {
        """
        \(header)
        #!arguments=latitude:\(latitudeText),longitude:\(longitudeText),horizontalAccuracy:\(horizontalAccuracy)

        [Script]
        Locus location = type=http-response,pattern=\(Self.pattern),requires-body=1,binary-body-mode=1,max-size=0,timeout=30,script-path=\(Self.scriptURL),argument=mode=response&latitude={{{latitude}}}&longitude={{{longitude}}}&horizontalAccuracy={{{horizontalAccuracy}}}

        [MITM]
        hostname = %APPEND% \(Self.hostnames.joined(separator: ", "))

        """
    }

    /// Loon wants its arguments declared and passed by name; a `{latitude}`
    /// inside a plain string is not substituted. The request script only asks
    /// Apple for an uncompressed answer — without it Loon's script can time
    /// out decompressing the body before it gets to rewrite it.
    private var loonText: String {
        """
        \(header)

        [Argument]
        enabled = switch,true,tag=Spoof location
        latitude = input,"\(latitudeText)",tag=Latitude
        longitude = input,"\(longitudeText)",tag=Longitude
        horizontalAccuracy = input,"\(horizontalAccuracy)",tag=Accuracy (m)

        [Script]
        http-request \(Self.pattern) script-path=\(Self.scriptURL), requires-body=false, timeout=3, tag=Locus location prepare
        http-response \(Self.pattern) script-path=\(Self.scriptURL), requires-body=true, binary-body-mode=true, timeout=30, tag=Locus location, argument=[{enabled},{latitude},{longitude},{horizontalAccuracy}]

        [mitm]
        hostname = \(Self.hostnames.joined(separator: ", "))

        """
    }

    private var stashText: String {
        let hosts = Self.hostnames.map { "    - \($0)" }.joined(separator: "\n")
        return """
        name: \(Self.name)
        desc: \(Self.yamlQuoted(summary))
        homepage: \(Self.homepage.absoluteString)

        http:
          script:
            - match: \(Self.pattern)
              name: locus-location
              type: response
              require-body: true
              binary-mode: true
              max-size: 0
              timeout: 30
              argument: \(Self.yamlQuoted(argument))
          mitm:
        \(hosts)

        script-providers:
          locus-location:
            url: \(Self.scriptURL)
            interval: 86400

        """
    }

    // MARK: - Helpers

    /// Six places is about 11 cm, and always a dot: `String(format:)` without
    /// a locale doesn't write "48,858370" on a French phone.
    static func degrees(_ value: Double) -> String {
        String(format: "%.6f", value)
    }

    static func singleLine(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func yamlQuoted(_ text: String) -> String {
        let escaped = singleLine(text)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
