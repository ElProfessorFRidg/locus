import Foundation

/// Which of Locus' two interfaces is on screen.
///
/// Not a "simple mode" drawn over the same screens. `pro` is the map with its
/// glass chrome, its route planner and its thirty-odd driving parameters;
/// `fun` is a different app over the same engine — four tabs, emoji spots, one
/// speed dial, and not one word about tunnels or m/s². They share the session,
/// the pairing and the tunnel, and nothing else: no view, no palette, no
/// vocabulary.
///
/// Pro is the default, so an existing install opens where it always did.
enum LocusInterfaceMode: String, CaseIterable, Identifiable, Codable {
    case pro
    case fun

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pro: return "Pro"
        case .fun: return "Fun"
        }
    }

    var emoji: String {
        switch self {
        case .pro: return "🛠️"
        case .fun: return "🎈"
        }
    }

    /// One line, in the words someone choosing between the two would use.
    var summary: String {
        switch self {
        case .pro: return "The full map, routes, profiles and every parameter."
        case .fun: return "Spots, moving and trips. Nothing else to learn."
        }
    }

    static let defaultsKey = "locus.interfaceMode"
}
