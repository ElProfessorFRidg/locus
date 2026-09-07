import CoreLocation
import Foundation

/// Everything that is really a place, written down.
///
/// A coordinate arrives as text far more often than as a search result: copied
/// out of a chat, shared from Maps, pulled off a forum post, printed by another
/// tool. Typing any of that into the search field used to ask MapKit to find a
/// business called "48.8584, 2.2945", which of course found nothing — the one
/// input that says exactly where to go was the one input that didn't work.
enum CoordinateParser {
    struct Match: Equatable {
        var coordinate: CLLocationCoordinate2D
        /// A name carried alongside the coordinate, when the source had one —
        /// `geo:` queries and Google Maps place URLs both do.
        var name: String?

        static func == (lhs: Match, rhs: Match) -> Bool {
            lhs.name == rhs.name
                && lhs.coordinate.latitude == rhs.coordinate.latitude
                && lhs.coordinate.longitude == rhs.coordinate.longitude
        }
    }

    /// Reads a coordinate out of anything a person might reasonably paste.
    ///
    /// Returns nil rather than guessing: a string that isn't a location should
    /// fall through to the normal place search, not teleport someone to 0,0.
    static func parse(_ raw: String) -> Match? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let url = URL(string: text), url.scheme != nil, let match = fromURL(url) {
            return match
        }
        // Some share sheets paste "Look at this: https://maps.apple.com/…".
        if let embedded = firstURL(in: text), let match = fromURL(embedded) {
            return match
        }
        if hasDecimals(text), let plain = fromPlainPair(text) {
            return Match(coordinate: plain, name: nil)
        }
        if let dms = fromDegreesMinutesSeconds(text) {
            return Match(coordinate: dms, name: nil)
        }
        return nil
    }

    /// Free text needs a decimal separator before it counts as a coordinate.
    /// "12, 5" is far likelier to be the start of a street address than a point
    /// in the Gulf of Guinea, and swallowing it would break the place search
    /// for the sake of a case nobody has. A URL that says `?ll=12,5` has
    /// already told us what it is, so this doesn't apply there.
    private static func hasDecimals(_ text: String) -> Bool {
        if text.contains(".") { return true }
        // "48,8584 2,2945" — decimal commas, separated by a space.
        let halves = text.split(whereSeparator: { $0.isWhitespace })
        return halves.count == 2 && halves.allSatisfy { $0.contains(",") }
    }

    /// True when this text is a location and shouldn't be sent to place search.
    static func looksLikeCoordinate(_ raw: String) -> Bool { parse(raw) != nil }

    // MARK: - URLs

    static func fromURL(_ url: URL) -> Match? {
        let scheme = url.scheme?.lowercased()
        let host = url.host?.lowercased() ?? ""
        let path = url.path(percentEncoded: false)
        let items = queryItems(url)

        // locus://teleport?lat=…&lon=…&name=…  — our own, and the one a
        // Shortcut or another app can build by hand.
        if scheme == "locus" {
            if let match = fromLatLonItems(items) { return match }
        }

        // geo:48.8584,2.2945  /  geo:0,0?q=48.8584,2.2945(Eiffel Tower)
        if scheme == "geo" {
            let body = url.absoluteString.dropFirst("geo:".count)
            let head = String(body.prefix(while: { $0 != "?" }))
            if let q = items["q"] {
                // "lat,lon(Label)" — the label is optional and parenthesised.
                var query = q
                var name: String?
                if let open = query.firstIndex(of: "("), query.hasSuffix(")") {
                    name = String(query[query.index(after: open)..<query.index(before: query.endIndex)])
                    query = String(query[query.startIndex..<open])
                }
                if let coordinate = fromPlainPair(query) {
                    return Match(coordinate: coordinate, name: name?.trimmed.nilIfEmpty)
                }
            }
            if let coordinate = fromPlainPair(head), !isNullIsland(coordinate) {
                return Match(coordinate: coordinate, name: nil)
            }
        }

        // maps.apple.com/?ll=48.8584,2.2945  (also ?sll=, ?q=lat,lon, ?daddr=)
        if host.hasSuffix("maps.apple.com") || scheme == "maps" {
            // `q` carries the place name as often as it carries numbers; keep
            // it as the label in the cases where it isn't the coordinate.
            let label = items["q"].flatMap { fromPlainPair($0) == nil ? $0 : nil }?.trimmed.nilIfEmpty
            for key in ["ll", "sll", "coordinate", "daddr", "q", "address"] {
                if let value = items[key], let coordinate = fromPlainPair(value) {
                    return Match(coordinate: coordinate, name: label)
                }
            }
        }

        // google.com/maps/place/Eiffel+Tower/@48.8584,2.2945,17z
        // google.com/maps?q=48.8584,2.2945   |   ?ll= / ?daddr= / ?center=
        if (host.contains("google.") && path.contains("maps")) || host.hasPrefix("maps.google") {
            for key in ["q", "ll", "daddr", "center", "query"] {
                if let value = items[key], let coordinate = fromPlainPair(value) {
                    return Match(coordinate: coordinate, name: placeName(inPath: path))
                }
            }
            // The @lat,lon,zoom segment is the camera, which is the only thing
            // a copied map URL usually carries.
            if let at = path.split(separator: "/").first(where: { $0.hasPrefix("@") }) {
                let parts = at.dropFirst().split(separator: ",")
                if parts.count >= 2, let coordinate = fromPlainPair("\(parts[0]),\(parts[1])") {
                    return Match(coordinate: coordinate, name: placeName(inPath: path))
                }
            }
        }

        // openstreetmap.org/#map=17/48.8584/2.2945
        if host.hasSuffix("openstreetmap.org") {
            if let fragment = url.fragment(percentEncoded: false),
               let range = fragment.range(of: "map=") {
                let parts = fragment[range.upperBound...].split(separator: "/")
                if parts.count >= 3, let coordinate = fromPlainPair("\(parts[1]),\(parts[2])") {
                    return Match(coordinate: coordinate, name: nil)
                }
            }
            if let match = fromLatLonItems(items) { return match }
        }

        // Anything else that spells the parameters out.
        return fromLatLonItems(items)
    }

    private static func fromLatLonItems(_ items: [String: String]) -> Match? {
        let latKeys = ["lat", "latitude"]
        let lonKeys = ["lon", "lng", "long", "longitude"]
        guard let latText = latKeys.compactMap({ items[$0] }).first,
              let lonText = lonKeys.compactMap({ items[$0] }).first,
              let lat = Double(latText), let lon = Double(lonText),
              let coordinate = validated(lat, lon) else { return nil }
        return Match(coordinate: coordinate, name: items["name"]?.trimmed.nilIfEmpty)
    }

    /// Lowercased keys, so `?LL=` works as well as `?ll=`.
    private static func queryItems(_ url: URL) -> [String: String] {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else { return [:] }
        var result: [String: String] = [:]
        for item in items where item.value?.isEmpty == false {
            result[item.name.lowercased()] = item.value
        }
        return result
    }

    /// "…/maps/place/Eiffel+Tower/@48.8584,…" — the segment after `place`.
    private static func placeName(inPath path: String) -> String? {
        let parts = path.split(separator: "/")
        guard let index = parts.firstIndex(of: "place"), index + 1 < parts.count else { return nil }
        let raw = String(parts[index + 1]).replacingOccurrences(of: "+", with: " ")
        return (raw.removingPercentEncoding ?? raw).trimmed.nilIfEmpty
    }

    /// Built once. The search field re-parses on every keystroke, and both of
    /// these cost real work to construct.
    private nonisolated(unsafe) static let linkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )

    private nonisolated(unsafe) static let dmsRegex = try? NSRegularExpression(
        pattern: #"([0-9]{1,3})[°º:\s]+([0-9]{1,2})['′:\s]+([0-9]{1,2}(?:[.,][0-9]+)?)?["″]?\s*([NSEWnsew])"#
    )

    private static func firstURL(in text: String) -> URL? {
        guard let detector = linkDetector else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return detector.firstMatch(in: text, range: range)?.url
    }

    // MARK: - Bare numbers

    /// "48.8584, 2.2945", "48.8584,2.2945", "48.8584 2.2945", "48,8584 2,2945".
    static func fromPlainPair(_ raw: String) -> CLLocationCoordinate2D? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
        guard !text.isEmpty else { return nil }

        // Split on comma when there are exactly two commas' worth of numbers;
        // otherwise on whitespace, which covers the "48.8584 2.2945" form and
        // the European "48,8584 2,2945" one in the same pass.
        var pieces = text.split(separator: ",").map { $0.trimmed }
        if pieces.count != 2 {
            pieces = text.split(whereSeparator: { $0.isWhitespace }).map { String($0).trimmed }
            // Decimal commas: "48,8584 2,2945" splits into two on whitespace,
            // and each half is a number once the comma becomes a point.
            pieces = pieces.map { $0.replacingOccurrences(of: ",", with: ".") }
        }
        guard pieces.count == 2,
              let lat = Double(pieces[0]), let lon = Double(pieces[1]) else { return nil }
        return validated(lat, lon)
    }

    /// 48°51'32.2"N 2°17'40.2"E — degrees, minutes, seconds with the hemisphere
    /// after the numbers, which is how Google Maps and Wikipedia both write it.
    static func fromDegreesMinutesSeconds(_ raw: String) -> CLLocationCoordinate2D? {
        guard let regex = dmsRegex else { return nil }
        let range = NSRange(raw.startIndex..., in: raw)
        let matches = regex.matches(in: raw, range: range)
        guard matches.count == 2 else { return nil }

        var latitude: Double?
        var longitude: Double?
        for match in matches {
            func group(_ index: Int) -> String? {
                guard let r = Range(match.range(at: index), in: raw) else { return nil }
                return String(raw[r])
            }
            guard let degreesText = group(1), let degrees = Double(degreesText),
                  let minutesText = group(2), let minutes = Double(minutesText),
                  let hemisphere = group(4)?.uppercased() else { return nil }
            let seconds = group(3).flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) } ?? 0
            var value = degrees + minutes / 60 + seconds / 3600
            if hemisphere == "S" || hemisphere == "W" { value = -value }
            if hemisphere == "N" || hemisphere == "S" { latitude = value } else { longitude = value }
        }
        guard let latitude, let longitude else { return nil }
        return validated(latitude, longitude)
    }

    // MARK: - Formatting

    /// The form Locus writes back out — five decimals is about a metre, which
    /// is finer than anything here can actually place you.
    static func text(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
    }

    static func appleMapsURL(_ coordinate: CLLocationCoordinate2D) -> URL? {
        URL(string: "https://maps.apple.com/?ll=\(coordinate.latitude),\(coordinate.longitude)&q=Locus")
    }

    static func googleMapsURL(_ coordinate: CLLocationCoordinate2D) -> URL? {
        URL(string: "https://www.google.com/maps/search/?api=1&query=\(coordinate.latitude),\(coordinate.longitude)")
    }

    /// A `locus://` link that reopens the app straight onto this spot.
    static func deepLink(_ coordinate: CLLocationCoordinate2D, name: String? = nil) -> URL? {
        var components = URLComponents()
        components.scheme = "locus"
        components.host = "teleport"
        var items = [
            URLQueryItem(name: "lat", value: String(coordinate.latitude)),
            URLQueryItem(name: "lon", value: String(coordinate.longitude)),
        ]
        if let name, !name.isEmpty { items.append(URLQueryItem(name: "name", value: name)) }
        components.queryItems = items
        return components.url
    }

    // MARK: - Sanity

    private static func validated(_ latitude: Double, _ longitude: Double) -> CLLocationCoordinate2D? {
        guard latitude.isFinite, longitude.isFinite,
              abs(latitude) <= 90, abs(longitude) <= 180 else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// `geo:0,0?q=…` is the standard way of saying "no coordinate, use the
    /// query" — taking it literally would drop a pin in the Atlantic.
    private static func isNullIsland(_ coordinate: CLLocationCoordinate2D) -> Bool {
        coordinate.latitude == 0 && coordinate.longitude == 0
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension Substring {
    var trimmed: String { String(self).trimmingCharacters(in: .whitespacesAndNewlines) }
}
