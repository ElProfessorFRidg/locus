import CoreLocation
import SwiftUI
import UIKit

/// Walking around, and how fast.
///
/// The Pro answer to "how fast do I walk" is a speed source, a fixed speed, a
/// unit picker and a travel mode, in a form with thirty other rows. Here it is
/// one dial with four shortcuts on it, and the number on the dial is the number
/// you move at — nothing multiplies it afterwards.
struct FunMoveView: View {
    @ObservedObject var settings: FunSettings
    @ObservedObject var connection: FunConnection
    var onStuck: (TunnelBlocker) -> Void

    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var pairing: PairingStore

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack(alignment: .center, spacing: 12) {
                    FunTitle(text: "Move")
                    FunConnectionPill(connection: connection, onStuck: onStuck)
                }

                dial

                paces

                FunJoystick(active: session.joystickActive) { vector in
                    session.updateJoystick(vector: vector)
                }
                .padding(.top, 4)

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

                Text(session.joystickActive
                     ? "Push the pad the way you want to go."
                     : "Drop yourself somewhere first, then walk around with the pad.")
                    .font(.fun(13, .semibold))
                    .foregroundStyle(FunTheme.mist)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, FunMetrics.tabBar + 20)
        }
        .animation(.snappy(duration: 0.25), value: session.joystickActive)
        .onAppear { session.joystickSpeed = settings.speed }
        .onChange(of: settings.speed) { _, speed in session.joystickSpeed = speed }
    }

    // MARK: - The dial

    private var dial: some View {
        VStack(spacing: 16) {
            HStack(alignment: .bottom, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(displayed)
                        .font(.fun(64, .heavy))
                        .foregroundStyle(FunTheme.ink)
                        .monospacedDigit()
                        .contentTransition(.numericText(value: settings.displaySpeed))
                    Text(settings.units.short)
                        .font(.fun(17, .heavy))
                        .foregroundStyle(FunTheme.mist)
                }
                Spacer(minLength: 0)
                Text(live ? liveEmoji : settings.pace.emoji)
                    .font(.system(size: 44))
            }

            VStack(spacing: 9) {
                Slider(
                    value: Binding(
                        get: { settings.speed },
                        set: { settings.speed = $0 }
                    ),
                    in: FunPace.dialRange
                )
                .tint(FunTheme.punch)

                HStack {
                    Text("🐢 \(bound(FunPace.dialRange.lowerBound))")
                    Spacer()
                    Text("\(bound(FunPace.dialRange.upperBound)) 🚴")
                }
                .font(.fun(12, .bold))
                .foregroundStyle(FunTheme.mist)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 20)
        .funCard()
    }

    /// The dial's own number, or the one you are actually moving at.
    private var displayed: String {
        let speed = live ? (session.joystick?.speed ?? 0) : settings.speed
        return String(format: "%.1f", settings.units.fromMetresPerSecond(speed))
    }

    private var live: Bool { session.joystickActive }

    private var liveEmoji: String {
        guard let moving = session.joystick?.isMoving, moving else { return "🧍" }
        return settings.pace.emoji
    }

    private func bound(_ speed: CLLocationSpeed) -> String {
        "\(Int(settings.units.fromMetresPerSecond(speed).rounded())) \(settings.units.short)"
    }

    // MARK: - Paces

    private var paces: some View {
        HStack(spacing: 10) {
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

    private func start() {
        session.joystickSpeed = settings.speed
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        session.startJoystick(pairing: pairing)
    }
}

// MARK: - The pad

/// Fun mode's joystick.
///
/// `JoystickPad` is the Pro one: 148 points wide, glass, teal, sized to sit in
/// a tray beside four other controls. This one has a whole screen to itself, so
/// it takes it — a 220-point pad is one you can steer without looking at.
struct FunJoystick: View {
    let active: Bool
    var onChange: (CGVector) -> Void

    @State private var offset: CGSize = .zero
    private let radius: CGFloat = 76

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [FunTheme.cardLift, FunTheme.card],
                        center: .init(x: 0.5, y: 0.38),
                        startRadius: 4,
                        endRadius: 130
                    )
                )
                .overlay(Circle().stroke(FunTheme.line, lineWidth: 1))
                .frame(width: 220, height: 220)

            Circle()
                .stroke(Color.white.opacity(0.07), lineWidth: 1.5)
                .frame(width: 176, height: 176)

            ForEach(0..<4, id: \.self) { index in
                Image(systemName: "triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.white.opacity(0.22))
                    .offset(y: -94)
                    .rotationEffect(.degrees(Double(index) * 90))
            }

            Circle()
                .fill(FunTheme.punchGradient)
                .frame(width: 88, height: 88)
                .overlay(
                    Text("🕹️")
                        .font(.system(size: 34))
                )
                .shadow(color: FunTheme.punch.opacity(active ? 0.5 : 0.25), radius: 18, y: 8)
                .offset(offset)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let limited = clamp(value.translation)
                            offset = limited
                            onChange(CGVector(dx: limited.width / radius, dy: limited.height / radius))
                        }
                        .onEnded { _ in
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.7)) {
                                offset = .zero
                            }
                            onChange(.zero)
                        }
                )
        }
        .frame(width: 220, height: 220)
        .opacity(active ? 1 : 0.45)
        .accessibilityLabel("Movement pad")
        .accessibilityHint(active ? "Drag to walk" : "Start moving first")
    }

    private func clamp(_ translation: CGSize) -> CGSize {
        let length = sqrt(translation.width * translation.width + translation.height * translation.height)
        guard length > radius else { return translation }
        let scale = radius / length
        return CGSize(width: translation.width * scale, height: translation.height * scale)
    }
}
