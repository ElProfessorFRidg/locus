import CoreLocation
import SwiftUI
import UIKit

/// What there is to do with a coordinate once you have one.
///
/// Locus could show you where it had put you and nothing else: the numbers were
/// on screen, and the only way to get them anywhere was to read them off and
/// type them in again. Built to drop into a `.contextMenu` or a `Menu`, so the
/// same actions are in every place a location appears.
struct LocationActionsMenu: View {
    let coordinate: CLLocationCoordinate2D
    var name: String?

    var body: some View {
        Button {
            UIPasteboard.general.string = CoordinateParser.text(coordinate)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } label: {
            Label("Copy coordinates", systemImage: "doc.on.doc")
        }

        // Pasteable back into Locus — on another device, into a Shortcut, or
        // into the search field, which now reads these.
        Button {
            guard let url = CoordinateParser.deepLink(coordinate, name: name) else { return }
            UIPasteboard.general.string = url.absoluteString
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } label: {
            Label("Copy Locus link", systemImage: "link")
        }

        if let mapsURL = CoordinateParser.appleMapsURL(coordinate) {
            Button {
                UIApplication.shared.open(mapsURL)
            } label: {
                Label("Open in Maps", systemImage: "map")
            }

            ShareLink(
                item: mapsURL,
                subject: Text(name ?? "Location"),
                message: Text(CoordinateParser.text(coordinate))
            ) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
    }
}
