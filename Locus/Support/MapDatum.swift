import CoreLocation
import Foundation

/// How the coordinates on the map relate to the ones the location system wants.
///
/// Everywhere but mainland China they are the same thing: WGS-84, what GPS
/// reports and what `locationd` expects to be handed. In mainland China the
/// map is drawn in GCJ-02 — a legally mandated, deliberately non-linear offset
/// of a few hundred metres — and MapKit hands back GCJ-02 for every tap,
/// search result and route it produces there. Injected as-is, a teleport lands
/// three to six hundred metres from the pin, which on a dense street grid is
/// the wrong block entirely.
///
/// So map-space coordinates stay what MapKit gave, and the conversion happens
/// at exactly two edges: on the way out to the location system, and on the way
/// in from anything that speaks WGS-84 (CoreLocation's own fixes, a GPX file).
///
/// Ported from Geranium's LocSim, which carried the transform after users in
/// China reported exactly that offset. Geranium applied it to any point inside
/// one rectangle around China — a box that also holds Korea, half of Japan,
/// Vietnam and Mongolia, none of which Apple draws shifted. This one asks a
/// tighter question first.
enum MapDatumMode: String, CaseIterable, Identifiable, Codable {
    /// Correct only inside mainland China, where Apple's map is actually shifted.
    case automatic
    /// Always treat the map as GCJ-02. For a map that is shifted somewhere the
    /// region test doesn't cover.
    case always
    /// Never correct. The map and the location system are taken to agree.
    case never

    var id: String { rawValue }

    static let defaultsKey = "locus.mapDatum"

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .always: return "Always"
        case .never: return "Off"
        }
    }

    var detail: String {
        switch self {
        case .automatic:
            return "Inside mainland China, Apple's map is drawn a few hundred metres off true GPS (GCJ-02). Locus undoes that offset there, and nowhere else."
        case .always:
            return "Every location is treated as GCJ-02. Only useful if a shifted map isn't being recognised."
        case .never:
            return "Locations are sent exactly as the map shows them. In mainland China that lands a few hundred metres off the pin."
        }
    }

    /// The stored choice, falling back to automatic for anything unreadable.
    static var current: MapDatumMode {
        get {
            UserDefaults.standard.string(forKey: defaultsKey).flatMap(MapDatumMode.init(rawValue:)) ?? .automatic
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    /// Whether a map-space coordinate here is GCJ-02 under this mode.
    func isShifted(_ coordinate: CLLocationCoordinate2D) -> Bool {
        switch self {
        case .never: return false
        case .always: return MapDatum.isNearChina(coordinate)
        case .automatic: return MapDatum.isInMainlandChina(coordinate)
        }
    }

    /// Map space → what the location system should be told.
    func toWGS84(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        isShifted(coordinate) ? MapDatum.gcj02ToWGS84(coordinate) : coordinate
    }

    /// A real GPS fix (or a GPX point) → where the map draws it.
    func fromWGS84(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        isShifted(coordinate) ? MapDatum.wgs84ToGCJ02(coordinate) : coordinate
    }
}

enum MapDatum {

    // MARK: - Where the map is shifted

    /// Rectangles that together cover mainland China, north-west corner first,
    /// minus the ones carved back out below. Coarse at the borders by a few
    /// kilometres, which is the right way round to be wrong: a point just over
    /// the line is a few hundred metres off, where the single big box puts all
    /// of Seoul there.
    private static let mainland: [Box] = [
        Box(north: 49.220400, west: 79.446200, south: 42.889900, east: 96.330000),
        Box(north: 54.141500, west: 109.687200, south: 39.374200, east: 135.000200),
        Box(north: 42.889900, west: 73.124600, south: 29.529700, east: 124.143255),
        Box(north: 29.529700, west: 82.968400, south: 26.718600, east: 97.035200),
        Box(north: 29.529700, west: 97.025300, south: 20.414096, east: 124.367395),
        Box(north: 20.414096, west: 107.975793, south: 17.871542, east: 111.744104),
    ]

    private static let carvedOut: [Box] = [
        // Taiwan.
        Box(north: 25.398623, west: 119.921265, south: 21.785006, east: 122.497559),
        // Northern Laos and Vietnam.
        Box(north: 22.284000, west: 101.865200, south: 20.098800, east: 106.665000),
        Box(north: 21.542200, west: 106.452500, south: 20.487800, east: 108.051000),
        // Russia and Mongolia beyond the north-east border.
        Box(north: 55.817500, west: 109.032300, south: 50.325700, east: 119.127000),
        Box(north: 55.817500, west: 127.456800, south: 49.557400, east: 137.022700),
        Box(north: 44.892200, west: 131.266200, south: 42.569200, east: 137.022700),
        // Hong Kong and Macau, which Apple draws on WGS-84. Stops short of the
        // Shenzhen side of the border rather than reaching into it.
        Box(north: 22.500000, west: 113.830000, south: 22.150000, east: 114.420000),
        Box(north: 22.220000, west: 113.520000, south: 22.100000, east: 113.610000),
    ]

    /// The rectangle every GCJ-02 implementation starts from, Geranium's
    /// included. Used as the outer limit for `.always` — outside it the offset
    /// formula is meaningless.
    static func isNearChina(_ coordinate: CLLocationCoordinate2D) -> Bool {
        coordinate.longitude >= 72.004 && coordinate.longitude <= 137.8347
            && coordinate.latitude >= 0.8293 && coordinate.latitude <= 55.8271
    }

    static func isInMainlandChina(_ coordinate: CLLocationCoordinate2D) -> Bool {
        guard isNearChina(coordinate) else { return false }
        guard mainland.contains(where: { $0.contains(coordinate) }) else { return false }
        return !carvedOut.contains(where: { $0.contains(coordinate) })
    }

    private struct Box {
        let north, west, south, east: Double

        func contains(_ c: CLLocationCoordinate2D) -> Bool {
            c.latitude <= north && c.latitude >= south && c.longitude >= west && c.longitude <= east
        }
    }

    // MARK: - The transform

    /// Krasovsky 1940 semi-major axis, which GCJ-02 is defined against.
    private static let a = 6378245.0
    /// Its first eccentricity, squared.
    private static let ee = 0.00669342162296594323

    /// WGS-84 → GCJ-02. Unconditional: the region decision belongs to the caller.
    static func wgs84ToGCJ02(_ wgs: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let (dLat, dLon) = offset(wgs)
        return CLLocationCoordinate2D(latitude: wgs.latitude + dLat, longitude: wgs.longitude + dLon)
    }

    /// GCJ-02 → WGS-84.
    ///
    /// The forward transform has no closed-form inverse. Geranium subtracted
    /// the offset computed *at the shifted point* once, which leaves a metre or
    /// two of error; a few rounds of fixed-point iteration take that below a
    /// millimetre for the cost of four more evaluations of a polynomial.
    static func gcj02ToWGS84(_ gcj: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        var wgs = gcj
        for _ in 0..<6 {
            let shifted = wgs84ToGCJ02(wgs)
            let errLat = shifted.latitude - gcj.latitude
            let errLon = shifted.longitude - gcj.longitude
            wgs.latitude -= errLat
            wgs.longitude -= errLon
            if abs(errLat) < 1e-9, abs(errLon) < 1e-9 { break }
        }
        return wgs
    }

    private static func offset(_ c: CLLocationCoordinate2D) -> (Double, Double) {
        let x = c.longitude - 105.0
        let y = c.latitude - 35.0
        var dLat = transformLatitude(x: x, y: y)
        var dLon = transformLongitude(x: x, y: y)

        let radLat = c.latitude / 180.0 * .pi
        var magic = sin(radLat)
        magic = 1 - ee * magic * magic
        let sqrtMagic = sqrt(magic)

        dLat = (dLat * 180.0) / ((a * (1 - ee)) / (magic * sqrtMagic) * .pi)
        dLon = (dLon * 180.0) / (a / sqrtMagic * cos(radLat) * .pi)
        return (dLat, dLon)
    }

    private static func transformLatitude(x: Double, y: Double) -> Double {
        var lat = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        lat += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        lat += (20.0 * sin(y * .pi) + 40.0 * sin(y / 3.0 * .pi)) * 2.0 / 3.0
        lat += (160.0 * sin(y / 12.0 * .pi) + 320.0 * sin(y * .pi / 30.0)) * 2.0 / 3.0
        return lat
    }

    private static func transformLongitude(x: Double, y: Double) -> Double {
        var lon = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        lon += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        lon += (20.0 * sin(x * .pi) + 40.0 * sin(x / 3.0 * .pi)) * 2.0 / 3.0
        lon += (150.0 * sin(x / 12.0 * .pi) + 300.0 * sin(x / 30.0 * .pi)) * 2.0 / 3.0
        return lon
    }
}
