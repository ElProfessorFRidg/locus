import CoreLocation
import SwiftUI
import UIKit

/// Walking around, and how fast.
///
/// The pad sits on the map it moves you across, dragging it starts you moving,
/// and nothing on this screen scrolls — three separate reasons an earlier
/// version of it did nothing at all.
struct FunMoveView: View {
    @ObservedObject var settings: FunSettings
    @ObservedObject var connection: FunConnection
    var onStuck: (TunnelBlocker) -> Void

    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var pairing: PairingStore

    /// Whether the camera keeps up with you. On by default — you almost always
    /// want to see where you're walking — but a map you can never move is a map
    /// you can't look around with.
    @State private var follows = true
    /// Where you've been since setting off.
    @State private var trail: [CLLocationCoordinate2D] = []
    /// Keeps you walking in the last direction after your thumb lets go.
    @State private var autoWalk = false

    /// Beyond this the trail is old news, and every point is another polyline
    /// segment to draw on every fix.
    private static let trailLimit = 400

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                FunTitle(text: "Move")
                FunConnectionPill(connection: connection, onStuck: onStuck)
            }

            map

            dial

            controls
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, FunMetrics.tabBar + 12)
        .animation(.snappy(duration: 0.25), value: session.joystickActive)
        .animation(.snappy(duration: 0.2), value: autoWalk)
        .onAppear {
            session.startLocationUpdates()
            session.joystickSpeed = settings.speed
        }
        .onChange(of: settings.speed) { _, speed in session.joystickSpeed = speed }
        .onChange(of: session.joystickActive) { _, active in
            follows = true
            if active {
                trail = session.simulated.map { [$0] } ?? []
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            } else {
                autoWalk = false
                UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            }
        }
        // Driven by the distance counter rather than the coordinate: it is the
        // one value that only changes when you have actually moved.
        .onChange(of: session.joystick?.distance) { _, _ in recordTrail() }
    }

    // MARK: - The map, with the pad on it

    private var map: some View {
        ZStack(alignment: .bottom) {
            FunLocationMap(
                real: session.realCoordinate,
                simulated: session.simulated,
                emoji: session.joystickActive ? settings.pace.emoji : "🧍",
                course: session.joystick?.isMoving == true ? session.joystick?.course : nil,
                trail: trail,
                span: 500,
                showsGap: false,
                follows: $follows,
                interactive: true
            )

            VStack(spacing: 0) {
                HStack {
                    Spacer(minLength: 0)
                    followChip
                }
                Spacer(minLength: 0)
                HStack(alignment: .bottom, spacing: 12) {
                    readout
                    Spacer(minLength: 0)
                    FunJoystick(
                        active: session.joystickActive,
                        locked: autoWalk,
                        onBegin: startIfNeeded
                    ) { vector in
                        session.updateJoystick(vector: vector)
                    }
                }
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: FunMetrics.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: FunMetrics.card, style: .continuous)
                .stroke(FunTheme.line, lineWidth: 1)
        )
    }

    private var followChip: some View {
        Button {
            withAnimation(.snappy) { follows.toggle() }
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: follows ? "location.fill" : "location")
                    .font(.system(size: 12, weight: .heavy))
                Text(follows ? "Following" : "Free")
                    .font(.fun(12, .heavy))
            }
            .foregroundStyle(follows ? FunTheme.night : FunTheme.ink)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(Capsule().fill(follows ? FunTheme.go : FunTheme.night.opacity(0.80)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(follows ? "Camera is following you" : "Camera is free — tap to follow again")
    }

    /// What you are doing right now, as opposed to what the dial is set to.
    private var readout: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(liveSpeed)
                    .font(.fun(26, .heavy))
                    .foregroundStyle(FunTheme.ink)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: session.joystick?.speed ?? 0))
                Text(settings.units.short)
                    .font(.fun(12, .heavy))
                    .foregroundStyle(FunTheme.mist)
            }

            HStack(spacing: 8) {
                Text(status)
                    .font(.fun(11, .bold))
                    .foregroundStyle(session.joystickActive ? FunTheme.go : FunTheme.mist)
                if let walked = session.joystick?.distance, walked > 20 {
                    Text("· \(DriveFormat.distance(walked))")
                        .font(.fun(11, .bold))
                        .foregroundStyle(FunTheme.mist)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(FunTheme.night.opacity(0.82))
        )
    }

    private var liveSpeed: String {
        let speed = session.joystickActive ? (session.joystick?.speed ?? 0) : settings.speed
        return String(format: "%.1f", settings.units.fromMetresPerSecond(speed))
    }

    private var status: String {
        guard session.joystickActive else { return "not moving" }
        if autoWalk { return "auto-walking" }
        return (session.joystick?.isMoving ?? false) ? "walking" : "standing still"
    }

    // MARK: - The dial

    private var dial: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Text("How fast")
                    .font(.fun(15, .heavy))
                    .foregroundStyle(FunTheme.ink)
                Spacer(minLength: 0)
                Text("\(String(format: "%.1f", settings.displaySpeed)) \(settings.units.short)")
                    .font(.fun(15, .heavy))
                    .foregroundStyle(FunTheme.punch)
                    .monospacedDigit()
                Text(settings.pace.emoji)
                    .font(.system(size: 22))
            }

            Slider(
                value: Binding(
                    get: { settings.speed },
                    set: { settings.speed = $0 }
                ),
                in: FunPace.dialRange
            )
            .tint(FunTheme.punch)

            HStack(spacing: 8) {
                ForEach(FunPace.allCases) { pace in
                    FunChip(
                        emoji: pace.emoji,
                        title: pace.title,
                        selected: settings.pace == pace
                    ) {
                        withAnimation(.snappy) { settings.select(pace) }
                        UISelectionFeedbackGenerator().selectionChanged()
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 18)
        .funCard()
    }

    // MARK: - Controls

    @ViewBuilder
    private var controls: some View {
        if session.joystickActive {
            HStack(spacing: 12) {
                Button {
                    autoWalk.toggle()
                    // Letting go of auto-walk has to actually stop you, or the
                    // button turns off and the legs keep going.
                    if !autoWalk { session.updateJoystick(vector: .zero) }
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: autoWalk ? "figure.walk.motion" : "hand.raised.fill")
                            .font(.system(size: 15, weight: .bold))
                        Text(autoWalk ? "Auto-walk on" : "Auto-walk")
                            .font(.fun(16, .heavy))
                    }
                    .foregroundStyle(autoWalk ? FunTheme.night : FunTheme.ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(Capsule().fill(autoWalk ? FunTheme.go : Color.white.opacity(0.10)))
                    .overlay(Capsule().stroke(Color.white.opacity(autoWalk ? 0 : 0.14), lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Keeps you walking in the last direction after you let go")

                Button {
                    session.stopJoystick()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 15, weight: .bold))
                        Text("Stop")
                            .font(.fun(16, .heavy))
                    }
                    .foregroundStyle(FunTheme.ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(Capsule().fill(FunTheme.punch))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        } else {
            FunPrimaryButton(title: "Start moving", systemImage: "figure.walk") {
                start()
            }
        }
    }

    // MARK: - Going

    private func start() {
        session.joystickSpeed = settings.speed
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        session.startJoystick(pairing: pairing)
    }

    /// Called the moment the pad is touched. A pad that has to be armed by
    /// another control first is a pad that doesn't work, as far as anyone
    /// holding it is concerned.
    private func startIfNeeded() {
        guard !session.joystickActive else { return }
        start()
    }

    /// Adds where you are to the trail, if you have gone far enough to be
    /// somewhere else. Every point is a segment MapKit redraws on every fix, so
    /// a metre-by-metre trail costs the whole map its frame rate.
    private func recordTrail() {
        guard session.joystickActive, let here = session.simulated else { return }
        if let last = trail.last {
            let moved = CLLocation(latitude: last.latitude, longitude: last.longitude)
                .distance(from: CLLocation(latitude: here.latitude, longitude: here.longitude))
            guard moved > 4 else { return }
        }
        trail.append(here)
        if trail.count > Self.trailLimit {
            trail.removeFirst(trail.count - Self.trailLimit)
        }
    }
}

// MARK: - The pad

/// Fun mode's joystick, sized to sit on the map rather than under it.
///
/// `minimumDistance: 0` on the knob so the touch is claimed the instant it
/// lands — before the map underneath can read it as a pan, and before a parent
/// scroll view could read it as a scroll.
struct FunJoystick: View {
    let active: Bool
    /// Keeps the stick where it was left instead of springing back.
    var locked: Bool = false
    /// Fired on touch-down, so the first drag can also be the thing that starts
    /// you moving.
    var onBegin: () -> Void = {}
    var onChange: (CGVector) -> Void

    @State private var offset: CGSize = .zero
    @State private var pressing = false
    private let radius: CGFloat = 58

    var body: some View {
        ZStack {
            Circle()
                .fill(FunTheme.night.opacity(0.72))
                .overlay(Circle().stroke(Color.white.opacity(0.16), lineWidth: 1))
                .frame(width: 164, height: 164)

            Circle()
                .stroke(Color.white.opacity(0.10), lineWidth: 1.5)
                .frame(width: 128, height: 128)

            ForEach(0..<4, id: \.self) { index in
                Image(systemName: "triangle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(Color.white.opacity(0.28))
                    .offset(y: -70)
                    .rotationEffect(.degrees(Double(index) * 90))
            }

            // How far from the middle the stick is *is* how fast you're going,
            // and nothing said so. Now the throw is drawn.
            if throwLength > 8 {
                Capsule()
                    .fill(FunTheme.punch.opacity(0.45))
                    .frame(width: throwLength, height: 8)
                    .rotationEffect(.radians(throwAngle))
                    .offset(x: offset.width / 2, y: offset.height / 2)
            }

            Circle()
                .fill(FunTheme.punchGradient)
                .frame(width: 72, height: 72)
                .overlay(Text(locked ? "🔒" : "🕹️").font(.system(size: 26)))
                .shadow(color: FunTheme.punch.opacity(active ? 0.55 : 0.30), radius: 16, y: 6)
                .scaleEffect(pressing ? 1.06 : 1)
                .offset(offset)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !pressing {
                                pressing = true
                                onBegin()
                            }
                            let limited = clamp(value.translation)
                            offset = limited
                            onChange(CGVector(dx: limited.width / radius, dy: limited.height / radius))
                        }
                        .onEnded { _ in
                            pressing = false
                            // Auto-walk means the stick stays where it was put.
                            guard !locked else { return }
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.7)) {
                                offset = .zero
                            }
                            onChange(.zero)
                        }
                )
        }
        .frame(width: 164, height: 164)
        .onChange(of: locked) { _, isLocked in
            guard !isLocked else { return }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.7)) { offset = .zero }
        }
        .onChange(of: active) { _, isActive in
            guard !isActive else { return }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.7)) { offset = .zero }
        }
        .accessibilityLabel("Movement pad")
        .accessibilityHint("Drag to walk. Dragging also starts you moving.")
    }

    private var throwLength: CGFloat {
        sqrt(offset.width * offset.width + offset.height * offset.height)
    }

    private var throwAngle: Double {
        atan2(Double(offset.height), Double(offset.width))
    }

    private func clamp(_ translation: CGSize) -> CGSize {
        let length = sqrt(translation.width * translation.width + translation.height * translation.height)
        guard length > radius else { return translation }
        let scale = radius / length
        return CGSize(width: translation.width * scale, height: translation.height * scale)
    }
}
