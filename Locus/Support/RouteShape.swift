import CoreGraphics
import Foundation

/// Projects a route's coordinates into a drawable box.
///
/// Split out of `RouteShapeThumbnail` so it can be tested: the view needs
/// SwiftUI, and the test bundle deliberately links neither SwiftUI nor the
/// device-only FFI. This half is pure maths with an answer you can check by
/// hand, which is the half worth pinning down.
enum RouteShape {
    /// Fits the path into `size`, preserving its aspect so the shape stays the
    /// shape — a squashed route is a different route to look at.
    ///
    /// Longitude is scaled by cos(latitude): a degree of longitude is shorter
    /// than a degree of latitude everywhere but the equator, and skipping that
    /// makes every European route look stretched sideways.
    static func normalised(
        _ coordinates: [Coordinate2D],
        into size: CGSize,
        inset: CGFloat
    ) -> [CGPoint] {
        guard coordinates.count > 1 else { return [] }

        // A few hundred points is plenty for a 44-point square, and a route can
        // hold thousands.
        let step = max(1, coordinates.count / 240)

        // Three passes and two allocations, where this was six allocations and
        // eight sweeps over four separate arrays. It runs inside a `Canvas`
        // draw — once per visible row of the saved list, every time that list
        // redraws or scrolls — so the sweeps were not free.
        var sampled: [Coordinate2D] = []
        sampled.reserveCapacity(coordinates.count / step + 2)
        var latitudeTotal = 0.0

        var index = 0
        while index < coordinates.count {
            let point = coordinates[index]
            sampled.append(point)
            latitudeTotal += point.latitude
            index += step
        }
        // The real last point, whatever the stride landed on — an out-and-back
        // route that loses its far end reads as half a route.
        if let last = coordinates.last {
            sampled.append(last)
            latitudeTotal += last.latitude
        }
        guard !sampled.isEmpty else { return [] }

        let meanLatitude = latitudeTotal / Double(sampled.count)
        let squeeze = max(0.05, cos(meanLatitude * .pi / 180))

        var minX = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude
        for point in sampled {
            let x = point.longitude * squeeze
            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, point.latitude)
            maxY = max(maxY, point.latitude)
        }

        // Degenerate spans are real: an out-and-back route has zero width.
        let spanX = max(maxX - minX, 1e-9)
        let spanY = max(maxY - minY, 1e-9)
        let usableWidth = Double(size.width) - Double(inset) * 2
        let usableHeight = Double(size.height) - Double(inset) * 2
        let scale = min(usableWidth / spanX, usableHeight / spanY)

        // Centre whatever is left over, so a north-south route sits in the
        // middle rather than hugging one edge.
        let originX = Double(inset) + (usableWidth - spanX * scale) / 2
        let originY = Double(inset) + (usableHeight - spanY * scale) / 2

        var points: [CGPoint] = []
        points.reserveCapacity(sampled.count)
        for point in sampled {
            points.append(CGPoint(
                x: CGFloat(originX + (point.longitude * squeeze - minX) * scale),
                // Flipped: latitude grows north, screen y grows down.
                y: CGFloat(originY + (maxY - point.latitude) * scale)
            ))
        }
        return points
    }
}
