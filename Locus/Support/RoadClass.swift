import CoreLocation
import Foundation

/// What kind of road a route is on, read from the number MapKit gives it.
///
/// The limit estimator knew only the road's *shape* — corner radius and how
/// often it turns — scaled off one average for the whole route. Two problems
/// follow from that, and both were reported from the field:
///
/// - A motorway and a straight départementale have the same shape, so they got
///   the same answer.
/// - The average is taken over the whole journey, so a trip that is mostly town
///   with some autoroute in it drags the autoroute down. The A1 came out at 110
///   instead of 130, and the rest of the route sat on 30 or 50.
///
/// The road number fixes both, and it is already in the step instructions.
/// Continental Europe numbers roads by class — A for autoroute/Autobahn, N for
/// nationale, D for départementale — so the prefix *is* the classification.
enum RoadClass: String, CaseIterable, Codable, Sendable {
    /// A1, A86. 130 in France, 120–130 across most of the continent.
    case motorway
    /// N roads. Mostly 80 on single carriageway, 110 where it is dual — the
    /// number can't tell those apart, so the band spans both and the road's
    /// shape picks within it.
    case national
    /// D roads: 80 since 2018, some reverted to 90.
    case departmental
    /// A named street with no number. Town speeds.
    case street

    /// The band this class can be estimated within, km/h.
    ///
    /// A band rather than a number: a D road through open country and the same
    /// D road through a village are both "D", and the shape heuristic is good
    /// at telling those apart. What shape could never do is tell a D road from
    /// an autoroute, which is what this adds.
    var bandKph: ClosedRange<Double> {
        switch self {
        case .motorway: return 110...130
        case .national: return 80...110
        case .departmental: return 50...90
        case .street: return 30...50
        }
    }

    /// Lower is faster, so `min` picks the more major road when a step names
    /// two — which is what a junction instruction does.
    var rank: Int {
        switch self {
        case .motorway: return 0
        case .national: return 1
        case .departmental: return 2
        case .street: return 3
        }
    }

    /// Reads the road number out of a step instruction.
    ///
    /// Instructions are localised prose — "Prendre l'autoroute A1", "Continuer
    /// sur D 1017" — so this looks for the number rather than parsing the
    /// sentence. `E` numbers are deliberately ignored: a European number always
    /// overlays a national one ("A1/E15"), and the local number is the one that
    /// carries the limit.
    static func parse(_ instruction: String) -> RoadClass? {
        let upper = instruction.uppercased()
        let range = NSRange(upper.startIndex..<upper.endIndex, in: upper)
        var best: RoadClass?

        for match in numberPattern.matches(in: upper, range: range) {
            guard let prefixRange = Range(match.range(at: 1), in: upper) else { continue }
            let found: RoadClass
            switch String(upper[prefixRange]) {
            case "A": found = .motorway
            case "N", "RN": found = .national
            case "D", "RD": found = .departmental
            default: continue
            }
            if found.rank < (best?.rank ?? Int.max) { best = found }
        }
        return best
    }

    /// `A1`, `RN 20`, `D 1017`, `A6a`, `D 6A` — a class letter, an optional
    /// space, up to four digits, and an optional suffix letter.
    ///
    /// The suffix is not decoration. France splits busy roads by letter — A6a
    /// and A6b are the two halves of the A6 into Paris, and suffixed D roads
    /// (D 6A, D 920A) are everywhere. Without it the digits ran into the letter,
    /// there was no word boundary to close the match, and every one of those
    /// roads parsed as nothing at all.
    ///
    /// `M` is excluded twice over. As a prefix it is a motorway in the UK and a
    /// métropolitaine in France, and no prefix is worth reading two ways. As a
    /// suffix it is the metre abbreviation, and no French road uses it — so
    /// allowing it would let "N 500m" become road N500M.
    ///
    /// The trailing lookahead is what keeps a spaced distance from reading as a
    /// road: "N 500 M" would otherwise be road N500. French instructions write
    /// the preposition as "à", which uppercases to "À" and so never matches the
    /// ASCII `A` here, but the unit check costs nothing and covers the rest.
    private static let numberPattern: NSRegularExpression = {
        // Safe to force: a literal pattern, and `parse` is covered by tests.
        try! NSRegularExpression(pattern: #"\b(RN|RD|[AND])\s?\d{1,4}[A-LN-Z]?\b(?!\s*(?:KM|MIN|M\b))"#)
    }()
}

/// A stretch of a route that MapKit attributed to one road.
struct RoadSegment: Codable, Sendable, Equatable {
    let startDistance: CLLocationDistance
    let endDistance: CLLocationDistance
    let roadClass: RoadClass

    func contains(_ distance: CLLocationDistance) -> Bool {
        distance >= startDistance && distance < endDistance
    }
}

extension Array where Element == RoadSegment {
    /// The class covering `distance`, if any step named a road there.
    func roadClass(at distance: CLLocationDistance) -> RoadClass? {
        first { $0.contains(distance) }?.roadClass
    }

    /// Joins the runs and bridges the holes. Input must be in route order.
    ///
    /// Two things leave one road in pieces. Consecutive steps on the same road
    /// are still separate steps — "Merge onto A1", then "Keep left to stay on
    /// A1" — and some steps name no road at all ("Continue straight", "Keep
    /// right") in the middle of one.
    ///
    /// The second kind is the reported bug seen from the other side: an unnamed
    /// step punches a hole through the middle of an autoroute, and the shape
    /// heuristic fills the hole with a town speed. The car drops to 50 for two
    /// kilometres of the A1 and picks 130 back up afterwards.
    ///
    /// A hole is attributed to the road either side only when both name the
    /// same class and the hole is shorter than each of them. A kilometre of
    /// silence inside forty kilometres of A1 is the A1; forty kilometres of
    /// silence between two brief mentions of a D road is not, and is left to
    /// the shape heuristic as before. That is a scale-relative test, so it
    /// needs no threshold to be wrong about.
    func joinedRuns() -> [RoadSegment] {
        var merged: [RoadSegment] = []
        merged.reserveCapacity(count)

        for segment in self {
            guard let last = merged.last, last.roadClass == segment.roadClass else {
                merged.append(segment)
                continue
            }
            let gap = segment.startDistance - last.endDistance
            // Sub-metre gaps are the steps simply touching, not a hole.
            let touching = gap < 1
            let shortEnough = gap < last.endDistance - last.startDistance
                && gap < segment.endDistance - segment.startDistance
            guard touching || shortEnough else {
                merged.append(segment)
                continue
            }
            merged[merged.count - 1] = RoadSegment(
                startDistance: last.startDistance,
                endDistance: Swift.max(last.endDistance, segment.endDistance),
                roadClass: segment.roadClass
            )
        }
        return merged
    }
}
