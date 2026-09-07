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
        var sampled = stride(from: 0, to: coordinates.count, by: step).map { coordinates[$0] }
        if let last = coordinates.last { sampled.append(last) }

        let meanLatitude = sampled.reduce(0.0) { $0 + $1.latitude } / Double(sampled.count)
        let squeeze = max(0.05, cos(meanLatitude * .pi / 180))

        let xs: [Double] = sampled.map { $0.longitude * squeeze }
        let ys: [Double] = sampled.map { $0.latitude }
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return [] }

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

        return zip(xs, ys).map { x, y in
            CGPoint(
                x: CGFloat(originX + (x - minX) * scale),
                // Flipped: latitude grows north, screen y grows down.
                y: CGFloat(originY + (maxY - y) * scale)
            )
        }
    }
}
