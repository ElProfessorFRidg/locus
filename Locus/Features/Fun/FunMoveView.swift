import CoreLocation
import SwiftUI
import UIKit

/// Walking around, and how fast.
///
/// The first version of this screen had a pad you could drag that did nothing
/// until you had pressed a separate button, inside a `ScrollView` that could
/// take the drag for itself, above no map at all — so the honest description of
/// it was "the joystick doesn't move". Three separate reasons for one symptom,
/// and none of them visible.
///
/// So: the pad sits on the map it moves you across, dragging it starts you
/// moving without a second control, and nothing on this screen scrolls.
struct FunMoveView: View {
    @ObservedObject var settings: FunSettings
    @ObservedObject var connection: FunConnection
    var onStuck: (TunnelBlocker) -> Void

    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var pairing: PairingStore

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                FunTitle(text: "Move")
                FunConnectionPill(connection: connection, onStuck: onStuck)
            }

            map

            dial

            if session.joystickActive {
                FunSecondaryButton(title: "Stop moving", systemImage: "stop.fill") {
                    session.stopJoystick()
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                }
            } else {
                FunPrimaryButton(title: "Start moving", systemImage: "figure.walk") {
                    start()
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, FunMetrics.tabBar + 12)
        .animation(.snappy(duration: 0.25), value: session.joystickActive)
        .onAppear {
            session.startLocationUpdates()
            session.joystickSpeed = settings.speed
        }
        .onChange(of: settings.speed) { _, speed in session.joystickSpeed = speed }
    }

    // MARK: - The map, with the pad on it

    private var map: some View {
        ZStack(alignment: .bottom) {
            FunLocationMap(
                real: session.realCoordinate,
                simulated: session.simulated,
                emoji: live ? settings.pace.emoji : "🧍",
                // The camera stays on you while you walk. Without this the pad
                // moved a dot off the edge of the map and the screen sat still.
                follows: true,
                span: 500
            )

            HStack(alignment: .bottom, spacing: 12) {
                readout
                Spacer(minLength: 0)
                FunJoystick(active: session.joystickActive, onBegin: startIfNeeded) { vector in
                    session.updateJoystick(vector: vector)
                }
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: FunMetrics.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: FunMetrics.card, style: .continuous)
                .stroke(FunTheme.line, lineWidth: 1)
        )
    }

    /// What you are doing right now, as opposed to what the dial is set to.
    private var readout: some View {
        VStack(alignment: .leading, spacing: 2) {
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
            Text(status)
                .font(.fun(11, .bold))
                .foregroundStyle(session.joystickActive ? FunTheme.go : FunTheme.mist)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(FunTheme.night.opacity(0.82))
        )
    }

    private var live: Bool { session.joystickActive }

    private var liveSpeed: String {
        let speed = live ? (session.joystick?.speed ?? 0) : settings.speed
        return String(format: "%.1f", settings.units.fromMetresPerSecond(speed))
    }

    private var status: String {
        guard session.joystickActive else { return "not moving" }
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
                Text("\(dialSpeed) \(settings.units.short)")
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

    private var dialSpeed: String {
        String(format: "%.1f", settings.displaySpeed)
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
}

// MARK: - The pad

/// Fun mode's joystick, sized to sit on the map rather than under it.
///
/// `minimumDistance: 0` on the knob so the touch is claimed before a parent
/// scroll view can take it — and this screen has no scroll view either, because
/// belt and braces is the right amount of engineering for the one control the
/// tab exists for.
struct FunJoystick: View {
    let active: Bool
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

            Circle()
                .fill(FunTheme.punchGradient)
                .frame(width: 72, height: 72)
                .overlay(Text("🕹️").font(.system(size: 28)))
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
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.7)) {
                                offset = .zero
                            }
                            onChange(.zero)
                        }
                )
        }
        .frame(width: 164, height: 164)
        .accessibilityLabel("Movement pad")
        .accessibilityHint("Drag to walk. Dragging also starts you moving.")
    }

    private func clamp(_ translation: CGSize) -> CGSize {
        let length = sqrt(translation.width * translation.width + translation.height * translation.height)
        guard length > radius else { return translation }
        let scale = radius / length
        return CGSize(width: translation.width * scale, height: translation.height * scale)
    }
}
