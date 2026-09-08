import CoreLocation
import MapKit
import SwiftUI

/// A trip in flight, taking the whole screen.
///
/// The Pro drive HUD is a card among cards: the tray, the mode picker and the
/// search bar are all still there, because someone driving a route in Pro mode
/// is often about to do something else to it. Nobody watching their first trip
/// is. So this is the only thing on the screen, and it has three controls.
struct FunTripRunningView: View {
    @ObservedObject var settings: FunSettings

    @EnvironmentObject private var session: SpoofSession

    var body: some View {
        ZStack {
            FunTheme.night.ignoresSafeArea()

            if let coordinate = session.simulated {
                Map(
                    position: .constant(.region(MKCoordinateRegion(
                        center: coordinate,
                        latitudinalMeters: 900,
                        longitudinalMeters: 900
                    ))),
                    interactionModes: []
                ) {
                    Annotation("", coordinate: coordinate) {
                        Text(emoji)
                            .font(.system(size: 26))
                            .frame(width: 54, height: 54)
                            .background(Circle().fill(.white))
                            .overlay(Circle().stroke(.white.opacity(0.28), lineWidth: 10))
                    }
                }
                .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }

            VStack(spacing: 0) {
                header
                Spacer(minLength: 0)
                card
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
        .preferredColorScheme(.dark)
    }

    private var emoji: String {
        switch session.travelMode {
        case .walk: return session.telemetry?.isStopped == true ? "🧍" : "🚶"
        case .run: return "🏃"
        case .cycle: return "🚴"
        case .drive: return "🚗"
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("🏁").font(.system(size: 22))
            VStack(alignment: .leading, spacing: 1) {
                Text("ON THE WAY")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .tracking(1)
                    .foregroundStyle(FunTheme.go)
                Text(session.telemetry?.isStopped == true ? "Waiting…" : "Moving")
                    .font(.fun(16, .heavy))
                    .foregroundStyle(FunTheme.ink)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Capsule().fill(FunTheme.night.opacity(0.86)))
        .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
    }

    private var card: some View {
        VStack(spacing: 18) {
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(remaining)
                        .font(.fun(30, .semibold))
                        .foregroundStyle(FunTheme.ink)
                        .contentTransition(.numericText())
                    Text("\(DriveFormat.distance(session.telemetry?.distanceRemaining ?? 0)) to go")
                        .font(.fun(14, .bold))
                        .foregroundStyle(FunTheme.mist)
                }
                Spacer(minLength: 0)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("\(Int(settings.units.fromMetresPerSecond(session.telemetry?.speed ?? 0).rounded()))")
                        .font(.fun(38, .heavy))
                        .foregroundStyle(FunTheme.go)
                        .monospacedDigit()
                        .contentTransition(.numericText(value: session.telemetry?.speed ?? 0))
                    Text(settings.units.short)
                        .font(.fun(14, .heavy))
                        .foregroundStyle(FunTheme.mist)
                }
            }

            ProgressView(value: min(max(session.telemetry?.progress ?? 0, 0), 1))
                .progressViewStyle(.linear)
                .tint(FunTheme.go)

            HStack(spacing: 10) {
                ForEach(FunTripSpeed.allCases) { speed in
                    Button {
                        settings.tripSpeed = speed
                        // Read every tick by the drive loop, so this lands on
                        // the next fix rather than the next trip.
                        session.profileOverride?.timeScale = speed.timeScale
                        UISelectionFeedbackGenerator().selectionChanged()
                    } label: {
                        HStack(spacing: 6) {
                            Text(speed.emoji).font(.system(size: 17))
                            Text(speed.title)
                                .font(.fun(14, settings.tripSpeed == speed ? .heavy : .bold))
                        }
                        .foregroundStyle(settings.tripSpeed == speed ? FunTheme.ink : FunTheme.mist)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(
                            Capsule().fill(settings.tripSpeed == speed
                                           ? FunTheme.punch.opacity(0.18)
                                           : Color.white.opacity(0.07))
                        )
                        .overlay(
                            Capsule().stroke(FunTheme.punch, lineWidth: settings.tripSpeed == speed ? 1.5 : 0)
                        )
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(settings.tripSpeed == speed ? [.isSelected] : [])
                }
            }

            HStack(spacing: 12) {
                Button {
                    session.toggleRoutePause()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: session.isRoutePaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 15, weight: .bold))
                        Text(session.isRoutePaused ? "Go on" : "Pause")
                            .font(.fun(16, .heavy))
                    }
                    .foregroundStyle(FunTheme.ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: 58)
                    .background(Capsule().fill(Color.white.opacity(0.10)))
                    .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    session.cancelRoute()
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 15, weight: .bold))
                        Text("Stop")
                            .font(.fun(16, .heavy))
                    }
                    .foregroundStyle(FunTheme.ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: 58)
                    .background(Capsule().fill(FunTheme.punch))
                    .shadow(color: FunTheme.punch.opacity(0.35), radius: 14, y: 6)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 22)
        .background(
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(FunTheme.night.opacity(0.94))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 30, y: -8)
    }

    /// Wall-clock time left, so a trip at 6× says how long *you* are waiting.
    private var remaining: String {
        guard let telemetry = session.telemetry else { return "Setting off…" }
        if session.isRoutePaused { return "Paused" }
        guard let eta = DriveFormat.eta(telemetry: telemetry, timeScale: settings.tripSpeed.timeScale) else {
            return "Almost there"
        }
        return "\(eta) left"
    }
}

/// The payoff. A trip that ends by the card simply vanishing is a trip that
/// didn't finish, it stopped.
struct FunArrivedSheet: View {
    let trip: TripSummary

    @EnvironmentObject private var session: SpoofSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            FunTheme.night.ignoresSafeArea()

            VStack(spacing: 20) {
                Text("🎉")
                    .font(.system(size: 60))
                    .padding(.top, 30)

                Text("You made it")
                    .font(.fun(28, .heavy))
                    .foregroundStyle(FunTheme.ink)

                Text(trip.routeName)
                    .font(.fun(16, .semibold))
                    .foregroundStyle(FunTheme.mist)
                    .lineLimit(1)

                HStack(spacing: 12) {
                    stat(DriveFormat.distance(trip.distance), "travelled")
                    stat(DriveFormat.clock(trip.simulatedSeconds), "the journey")
                    stat(DriveFormat.clock(trip.wallClockSeconds), "you waited")
                }

                Spacer(minLength: 0)

                FunPrimaryButton(title: "Nice", systemImage: "hand.thumbsup.fill") {
                    session.lastTrip = nil
                    dismiss()
                }
                .padding(.bottom, 24)
            }
            .padding(.horizontal, 20)
        }
        .preferredColorScheme(.dark)
    }

    private func stat(_ value: String, _ caption: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.fun(18, .heavy))
                .foregroundStyle(FunTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(caption)
                .font(.fun(11, .bold))
                .foregroundStyle(FunTheme.mist)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .funCard(20)
    }
}
