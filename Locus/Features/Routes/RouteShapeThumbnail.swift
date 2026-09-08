import CoreLocation
import SwiftUI

/// The route's own shape, drawn small.
///
/// A saved list of "12.4 km · 3 Sept" rows tells you nothing about which route
/// is which — but you recognise the shape of your commute instantly, the way you
/// recognise a signature. This draws the polyline itself rather than fetching a
/// map snapshot: no network, no cache to invalidate, no rate limit, and it works
/// the same in a list of forty.
///
/// The projection lives in `RouteShape` so the maths can be tested without
/// SwiftUI.
struct RouteShapeThumbnail: View {
    let coordinates: [Coordinate2D]
    var tint: Color = LocusTheme.accent
    var side: CGFloat = 44

    var body: some View {
        Canvas { context, size in
            let points = RouteShape.normalised(coordinates, into: size, inset: 5)
            guard points.count > 1 else { return }

            var path = Path()
            path.move(to: points[0])
            for point in points.dropFirst() { path.addLine(to: point) }

            context.stroke(
                path,
                with: .color(tint),
                style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
            )

            // Both ends marked, so a there-and-back route doesn't read as a
            // line with no direction.
            context.fill(
                Path(ellipseIn: CGRect(x: points[0].x - 2.5, y: points[0].y - 2.5, width: 5, height: 5)),
                with: .color(LocusTheme.statusGood)
            )
            let last = points[points.count - 1]
            context.fill(
                Path(ellipseIn: CGRect(x: last.x - 2.5, y: last.y - 2.5, width: 5, height: 5)),
                with: .color(tint)
            )
        }
        .frame(width: side, height: side)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .accessibilityHidden(true)
    }
}
