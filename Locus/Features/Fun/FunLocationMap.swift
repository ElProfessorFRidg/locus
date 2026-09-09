import CoreLocation
import MapKit
import SwiftUI

/// The one map in Fun mode: where you really are, where Locus says you are, and
/// the gap between the two.
///
/// The first version of Fun mode showed one dot and called it "Faking it",
/// which answers the wrong question. The whole point of the app is that there
/// are two positions and they disagree — so both are drawn, always, and the
/// distance between them is written on the map.
struct FunLocationMap: View {
    /// Where the phone actually is.
    var real: CLLocationCoordinate2D?
    /// Where Locus is telling everything else you are. Nil when not spoofing.
    var simulated: CLLocationCoordinate2D?
    var emoji: String = "📍"
    /// Which way you're going, if anything knows. Drawn as an arrow beside the
    /// marker rather than by turning it: a rotated emoji reads as a mistake.
    var course: CLLocationDirection? = nil
    /// Where you have walked since setting off.
    var trail: [CLLocationCoordinate2D] = []
    var route: [CLLocationCoordinate2D] = []
    var stops: [CLLocationCoordinate2D] = []
    /// Metres across when the camera is following. Ignored otherwise.
    var span: CLLocationDistance = 700
    /// Whether to write "1.2 km from your real spot" over the map.
    var showsGap: Bool = true
    /// Whether the camera keeps up with the simulated position. Bound rather
    /// than passed so the screen above can offer a Follow control; nil keeps
    /// the camera framing everything there is to see.
    var follows: Binding<Bool>? = nil
    /// Whether the map answers to fingers. Off for the cards, which are
    /// pictures of where you are, not places to work.
    var interactive: Bool = false

    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $position, interactionModes: interactive ? [.pan, .zoom] : []) {
            if route.count > 1 {
                MapPolyline(coordinates: route)
                    .stroke(FunTheme.go, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            }

            // Where you have been, under everything else — it is history, and
            // history does not sit on top of the present.
            if trail.count > 1 {
                MapPolyline(coordinates: trail)
                    .stroke(
                        FunTheme.punch.opacity(0.55),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round, dash: [1, 9])
                    )
            }

            ForEach(Array(stops.enumerated()), id: \.offset) { _, stop in
                Annotation("", coordinate: stop) {
                    Circle()
                        .fill(FunTheme.grape)
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(FunTheme.night, lineWidth: 3))
                }
            }

            if let real {
                Annotation("", coordinate: real) {
                    RealHere()
                }
            }

            if let simulated {
                Annotation("", coordinate: simulated) {
                    FakeHere(emoji: emoji, course: course)
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .allowsHitTesting(interactive)
        .overlay(alignment: .topLeading) {
            if showsGap, let gap {
                Text(gap)
                    .font(.fun(12, .heavy))
                    .foregroundStyle(FunTheme.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(FunTheme.night.opacity(0.80)))
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .onAppear { position = desiredCamera }
        // The camera is re-aimed when the thing it is aimed at moves — and only
        // then. Assigning it every redraw fought every pan the moment the map
        // grew fingers.
        .onChange(of: anchorKey) { _, _ in
            guard follows?.wrappedValue ?? true else { return }
            withAnimation(.easeInOut(duration: 0.3)) { position = desiredCamera }
        }
        .onChange(of: follows?.wrappedValue ?? true) { _, following in
            guard following else { return }
            withAnimation(.easeInOut(duration: 0.3)) { position = desiredCamera }
        }
        .accessibilityElement()
        .accessibilityLabel(accessibilitySummary)
    }

    /// How far the fake position is from the real one, in words.
    ///
    /// Nil when there is nothing to compare, and when the two are close enough
    /// that the number would be noise rather than information.
    private var gap: String? {
        guard let real, let simulated else { return nil }
        let metres = CLLocation(latitude: real.latitude, longitude: real.longitude)
            .distance(from: CLLocation(latitude: simulated.latitude, longitude: simulated.longitude))
        guard metres > 30 else { return nil }
        return "\(DriveFormat.distance(metres)) from your real spot"
    }

    private var accessibilitySummary: String {
        guard simulated != nil else { return "Map of where you are" }
        guard let gap else { return "Map: your fake spot, next to your real one" }
        return "Map: your fake spot, \(gap)"
    }

    /// Changes exactly when something the camera cares about has moved.
    private var anchorKey: String {
        let point = simulated ?? real
        return [
            String(format: "%.5f", point?.latitude ?? 0),
            String(format: "%.5f", point?.longitude ?? 0),
            "\(route.count)",
            "\(stops.count)"
        ].joined(separator: "|")
    }

    private var isFollowing: Bool { follows?.wrappedValue ?? false }

    private var desiredCamera: MapCameraPosition {
        if isFollowing, let simulated {
            return .region(MKCoordinateRegion(
                center: simulated,
                latitudinalMeters: span,
                longitudinalMeters: span
            ))
        }

        // Everything worth seeing, or a sensible box round the one point there
        // is. Two positions on opposite sides of the world zoom out to both,
        // which is exactly the picture someone wants after a teleport.
        var points = route + stops
        if let real { points.append(real) }
        if let simulated { points.append(simulated) }

        guard let first = points.first else {
            return .region(MKCoordinateRegion(.world))
        }
        guard points.count > 1 else {
            return .region(MKCoordinateRegion(
                center: first,
                latitudinalMeters: span,
                longitudinalMeters: span
            ))
        }
        return .rect(Self.rect(around: points))
    }

    /// A box round `coordinates`, with enough air that nothing sits on the edge.
    static func rect(around coordinates: [CLLocationCoordinate2D]) -> MKMapRect {
        guard let first = coordinates.first else { return .world }
        var rect = MKMapRect(origin: MKMapPoint(first), size: MKMapSize(width: 0, height: 0))
        for coordinate in coordinates.dropFirst() {
            rect = rect.union(MKMapRect(origin: MKMapPoint(coordinate), size: MKMapSize(width: 0, height: 0)))
        }
        return rect.insetBy(dx: -rect.size.width * 0.2 - 400, dy: -rect.size.height * 0.2 - 400)
    }
}

/// Where the phone actually is — deliberately quiet, and deliberately not the
/// same shape as the fake one. Two identical markers would be the one thing
/// this map must never do.
struct RealHere: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.22))
                .frame(width: 30, height: 30)
            Circle()
                .fill(Color(red: 0.30, green: 0.62, blue: 1.0))
                .frame(width: 14, height: 14)
                .overlay(Circle().stroke(.white, lineWidth: 2.5))
        }
    }
}

/// Where Locus says you are, and which way you're heading.
struct FakeHere: View {
    let emoji: String
    var course: CLLocationDirection? = nil

    var body: some View {
        ZStack {
            Circle()
                .fill(FunTheme.punch.opacity(0.28))
                .frame(width: 68, height: 68)

            if let course {
                Image(systemName: "location.north.fill")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(FunTheme.ink)
                    .offset(y: -34)
                    .rotationEffect(.degrees(course))
                    .animation(.easeOut(duration: 0.25), value: course)
            }

            Text(emoji)
                .font(.system(size: 26))
                .frame(width: 52, height: 52)
                .background(Circle().fill(FunTheme.punch))
        }
        .frame(width: 76, height: 76)
    }
}
