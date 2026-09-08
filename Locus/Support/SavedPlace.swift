import CoreLocation
import Foundation

/// A starred place or a recent teleport.
///
/// The identity is a `UUID`, not the coordinate pair it used to be. Deriving an
/// id from `"lat,lon"` meant two entries at the same spot were the same entry,
/// so a second star with a different name silently replaced the first — and it
/// made the id change if a place was ever moved.
struct SavedPlace: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var latitude: Double
    var longitude: Double
    /// How Fun mode shows this place: one emoji, chosen when it was saved.
    ///
    /// Optional because the Pro map stars places without asking for one, and
    /// because every favourite saved before this existed has none. Fun mode
    /// falls back to a pin rather than making anyone pick.
    var emoji: String?

    init(name: String, latitude: Double, longitude: Double, emoji: String? = nil, id: UUID = UUID()) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.emoji = emoji
    }

    /// Entries saved before ids existed have no `id` key. Decoding field by
    /// field mints one instead of throwing, which would have discarded every
    /// favourite anyone had.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        latitude = try container.decode(Double.self, forKey: .latitude)
        longitude = try container.decode(Double.self, forKey: .longitude)
        emoji = try? container.decode(String.self, forKey: .emoji)
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Same spot, to within about fifteen metres — close enough that saving it
    /// twice would be a duplicate rather than a second place.
    func isAt(_ coordinate: CLLocationCoordinate2D) -> Bool {
        abs(latitude - coordinate.latitude) < 0.00015
            && abs(longitude - coordinate.longitude) < 0.00015
    }

    static func load(key: String) -> [SavedPlace] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([SavedPlace].self, from: data) else {
            return []
        }
        return decoded
    }

    static func save(_ places: [SavedPlace], key: String) {
        if let data = try? JSONEncoder().encode(places) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
