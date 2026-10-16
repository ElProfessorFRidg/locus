import Foundation

/// Places saved in the TrollStore location apps people are coming from.
///
/// Anyone installing Locus with TrollStore has very likely been using
/// Geranium's LocSim, or Mika's LocationSimulation before it — Geranium itself
/// offered to import Mika's. Their bookmarks shouldn't have to be retyped.
///
/// Both are only readable from a copy signed for it: Geranium keeps its list
/// in an App Group (`group.live.cclerc.geraniumBookmarks`), Mika's lives in a
/// preferences file outside any sandbox. The TrollStore build claims both; a
/// sideloaded copy simply finds nothing, and the import is never offered.
enum LegacyBookmarks {

    enum Source: String {
        case geranium = "Geranium"
        case mika = "LocSim"
    }

    struct Bookmark: Equatable {
        var name: String
        var latitude: Double
        var longitude: Double
        var source: Source
    }

    static let geraniumSuite = "group.live.cclerc.geraniumBookmarks"
    static let mikaPath = "/var/mobile/Library/Preferences/com.mika.LocationSimulation.plist"

    /// Everything readable from both, de-duplicated by spot. Coordinates are
    /// WGS-84 as both apps stored them.
    static func load() -> [Bookmark] {
        var found: [Bookmark] = []

        if let array = UserDefaults(suiteName: geraniumSuite)?.array(forKey: "bookmarks") {
            found += parseGeranium(array)
        }

        if let data = FileManager.default.contents(atPath: mikaPath),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
            found += parseMika(plist)
        }

        return deduplicated(found)
    }

    /// Geranium: `[["name": String, "lat": Double, "long": Double]]`.
    ///
    /// Geranium force-cast every field, so one malformed entry crashed its
    /// bookmark list. Here a malformed entry is skipped and the rest come over.
    static func parseGeranium(_ array: [Any]) -> [Bookmark] {
        array.compactMap { item in
            guard let entry = item as? [String: Any],
                  let lat = number(entry["lat"]),
                  let lon = number(entry["long"]),
                  isValid(lat, lon) else { return nil }
            return Bookmark(
                name: name(entry["name"], lat: lat, lon: lon),
                latitude: lat,
                longitude: lon,
                source: .geranium
            )
        }
    }

    /// Mika's LocationSimulation: `["datas": [["la": Double, "lo": Double, "remark": String]]]`.
    static func parseMika(_ plist: Any) -> [Bookmark] {
        guard let root = plist as? [String: Any], let datas = root["datas"] as? [Any] else { return [] }
        return datas.compactMap { item in
            guard let entry = item as? [String: Any],
                  let lat = number(entry["la"]),
                  let lon = number(entry["lo"]),
                  isValid(lat, lon) else { return nil }
            return Bookmark(
                name: name(entry["remark"], lat: lat, lon: lon),
                latitude: lat,
                longitude: lon,
                source: .mika
            )
        }
    }

    /// The same spot saved in both apps — Geranium's own Mika import did
    /// exactly that — arrives once.
    static func deduplicated(_ bookmarks: [Bookmark]) -> [Bookmark] {
        var kept: [Bookmark] = []
        for bookmark in bookmarks where !kept.contains(where: {
            abs($0.latitude - bookmark.latitude) < 0.00015 && abs($0.longitude - bookmark.longitude) < 0.00015
        }) {
            kept.append(bookmark)
        }
        return kept
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let double as Double: return double
        case let number as NSNumber: return number.doubleValue
        case let string as String: return Double(string.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    /// Geranium saved (0, 0) when nothing had been picked yet, after asking
    /// whether you were sure. Nobody meant the Gulf of Guinea.
    private static func isValid(_ lat: Double, _ lon: Double) -> Bool {
        lat.isFinite && lon.isFinite
            && (-90...90).contains(lat) && (-180...180).contains(lon)
            && !(lat == 0 && lon == 0)
    }

    private static func name(_ value: Any?, lat: Double, lon: Double) -> String {
        let trimmed = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? String(format: "%.5f, %.5f", lat, lon) : trimmed
    }
}
