import NetworkExtension
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var pairing: PairingStore
    @StateObject private var tunnel = TunnelController.shared

    @State private var showSettings = false
    @State private var showPlaces = false

    /// Owned here rather than by the map, because the bottom chrome acts on it
    /// too — the trip summary offers to drive the route again, or back.
    @StateObject private var workspace = RouteWorkspace()

    @Namespace private var bottomGlass

    var body: some View {
        // Bottom chrome is a sibling overlay aligned to the bottom — no full-screen
        // Spacer layer that can steal / pass map taps through the tray.
        ZStack(alignment: .bottom) {
            MapHomeView(workspace: workspace)

            LocusGlassGroup(spacing: 16) {
                VStack(spacing: 10) {
                    tripSummary

                    if let telemetry = session.telemetry, session.drive.showHUD {
                        DriveHUDView(
                            telemetry: telemetry,
                            profile: session.drive,
                            isPaused: session.isRoutePaused,
                            onTogglePause: { session.toggleRoutePause() },
                            onStop: { session.cancelRoute() },
                            // Writes through to the active profile, which the
                            // drive loop now reads every tick — so this takes
                            // effect on the next fix, not the next route.
                            onChangeTimeScale: { session.drive.timeScale = $0 }
                        )
                        .locusGlassID("hud", in: bottomGlass)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    if let countdown = session.routeCountdown {
                        CountdownPill(seconds: countdown)
                            .locusGlassID("countdown", in: bottomGlass)
                            .transition(.scale(scale: 0.85).combined(with: .opacity))
                    }

                    if let toast = session.toast {
                        ToastPill(message: toast)
                            .locusGlassID("toast", in: bottomGlass)
                            .transition(.scale(scale: 0.85).combined(with: .opacity))
                            .onTapGesture { session.dismissToast() }
                    }

                    BottomControlsView(
                        showSettings: $showSettings,
                        showPlaces: $showPlaces
                    )
                    .locusGlassID("tray", in: bottomGlass)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: session.telemetry == nil)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: session.routeCountdown)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: session.toast)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: session.lastTrip)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showPlaces) {
            PlacesView()
        }
        .task {
            // One quiet attempt on launch: if the loopback subnet is already up
            // this does nothing at all, so it costs a check, not a VPN prompt.
            if tunnel.autoConnect {
                await tunnel.ensureConnected()
            }
        }
        .alert("Locus", isPresented: Binding(
            get: { session.lastError != nil },
            set: { if !$0 { session.lastError = nil } }
        )) {
            Button("OK", role: .cancel) { session.lastError = nil }
        } message: {
            Text(session.lastError ?? "")
        }
    }

    /// Extracted from `body` deliberately: seven arguments, three of them
    /// multi-line closures, inline in a `ViewBuilder` is exactly the shape that
    /// sends the type-checker away for a minute.
    @ViewBuilder
    private var tripSummary: some View {
        if let trip = session.lastTrip {
            TripSummaryView(
                trip: trip,
                profile: session.drive,
                economy: economy(for: trip),
                canSave: workspace.selectedRoute != nil && workspace.savedRouteID == nil,
                onDriveAgain: driveAgain,
                onReverse: driveBack,
                onSave: saveDrivenRoute,
                onDismiss: { session.lastTrip = nil }
            )
            .locusGlassID("trip", in: bottomGlass)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func economy(for trip: TripSummary) -> (litres: Double, gramsCO2: Double)? {
        // A walk burns no diesel, whatever the toggle says.
        guard trip.mode.isMotorVehicle, session.drive.showTripEconomy else { return nil }
        return session.tripEconomy(distance: trip.distance)
    }

    private func driveAgain() {
        session.lastTrip = nil
        session.driveRoute(workspace, pairing: pairing)
    }

    private func driveBack() {
        session.lastTrip = nil
        workspace.reverseSelectedRoute()
        session.driveRoute(workspace, pairing: pairing)
    }

    private func saveDrivenRoute() {
        guard let route = workspace.selectedRoute else { return }
        session.routeStore.save(
            route,
            named: route.name,
            overrides: workspace.overrides,
            startName: workspace.stops.first?.name,
            endName: workspace.stops.count >= 2 ? workspace.stops[workspace.stops.count - 1].name : nil
        )
        session.flash("Saved “\(route.name)”")
    }
}

/// The quiet counterpart to the error alert: something worked, here is what.
/// Tapping it dismisses it early, because a confirmation you have already read
/// is just something in the way.
struct ToastPill: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(LocusTheme.statusGood)
            Text(message)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .locusGlass(.clear, in: Capsule())
        .contentShape(Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// Shown during `startDelaySeconds`, so a delayed start doesn't look like a
/// button that did nothing.
struct CountdownPill: View {
    let seconds: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "timer")
                .foregroundStyle(LocusTheme.accentSecondary)
            Text("Setting off in \(seconds)…")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText(countsDown: true))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .locusGlass(.clear, in: Capsule())
        .contentShape(Capsule())
    }
}

// MARK: - Status bar

/// One line that always answers "why isn't this working". Spoof status wins when
/// something is being spoofed; otherwise it reports the tunnel, because a
/// missing tunnel is the reason a teleport fails nine times out of ten.
struct StatusBarView: View {
    @EnvironmentObject private var session: SpoofSession
    @StateObject private var tunnel = TunnelController.shared
    @Environment(\.scenePhase) private var scenePhase

    @State private var loopbackUp = TunnelController.loopbackReachable
    @State private var isConnecting = false
    @State private var troubleBlocker: TunnelBlocker?

    private enum Display {
        case spoof(String)
        case ready
        case tunnelAction(String)
        case tunnelBusy(String)
        /// The built-in tunnel can never work on this build — sideloaded without
        /// the entitlement, or in LiveContainer. Says so, and offers the way out.
        case tunnelBlocked(TunnelBlocker)
        case tunnelProblem(String)
    }

    private var display: Display {
        switch session.status {
        case .connecting: return .spoof("Connecting…")
        case .active: return .spoof("Spoofing")
        case .reconnecting: return .spoof("Reconnecting…")
        case .dropped(let reason):
            return .spoof(reason.isEmpty ? "Disconnected" : "Disconnected — \(reason)")
        case .idle:
            break
        }

        if loopbackUp { return .ready }

        switch tunnel.state {
        case .connecting:
            return .tunnelBusy("Starting tunnel…")
        case .failed(let reason):
            return .tunnelProblem(reason)
        case .unavailable(let blocker):
            return .tunnelBlocked(blocker)
        case .idle, .connected:
            return isConnecting
                ? .tunnelBusy("Starting tunnel…")
                : .tunnelAction("Tap to start the tunnel")
        }
    }

    private var title: String {
        switch display {
        case .spoof(let text): return text
        case .ready: return "Not Spoofing"
        case .tunnelAction(let text): return text
        case .tunnelBusy(let text): return text
        case .tunnelBlocked(let blocker): return blocker.shortTitle
        case .tunnelProblem: return "Tunnel didn’t connect"
        }
    }

    private var color: Color {
        switch display {
        case .ready: return Color.primary.opacity(0.55)
        case .tunnelAction, .tunnelBusy, .tunnelBlocked: return LocusTheme.statusWarn
        case .tunnelProblem: return LocusTheme.statusBad
        case .spoof:
            switch session.status {
            case .active: return LocusTheme.statusGood
            case .connecting, .reconnecting: return LocusTheme.statusWarn
            case .dropped: return LocusTheme.statusBad
            case .idle: return Color.primary.opacity(0.55)
            }
        }
    }

    private var isTappable: Bool {
        switch display {
        case .tunnelAction, .tunnelProblem, .tunnelBlocked: return true
        default: return false
        }
    }

    var body: some View {
        Group {
            if isTappable {
                Button(action: handleTap) { statusContent }
                    .buttonStyle(.plain)
            } else {
                statusContent
            }
        }
        .onAppear { refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refresh() }
        }
        .onChange(of: session.status) { _, _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .NEVPNStatusDidChange)) { _ in
            // Covers a tunnel raised by LocalDevVPN as well as our own.
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .locusShowTunnelTrouble)) { note in
            // A teleport or route hit the missing tunnel — explain it here rather
            // than leaving an alert that only says what failed.
            guard let blocker = note.object as? TunnelBlocker else { return }
            troubleBlocker = blocker
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                refresh()
            }
        }
        .sheet(item: $troubleBlocker) { blocker in
            TunnelTroubleView(blocker: blocker) {
                startBuiltInTunnel()
            }
        }
    }

    private var statusContent: some View {
        HStack(spacing: 10) {
            if case .tunnelBusy = display {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 8, height: 8)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                    .shadow(color: color.opacity(0.7), radius: 4)
            }

            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 8)

            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .locusGlass(.clear, in: RoundedRectangle(cornerRadius: LocusMetrics.barRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: LocusMetrics.barRadius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityHint(statusHint)
        // The status bar is where the current coordinates already are, so it's
        // where you reach for them. Long press to copy, link or share.
        .contextMenu {
            if let coordinate = session.simulated ?? session.pin {
                LocationActionsMenu(coordinate: coordinate, name: session.simulatedAddress)
            }
        }
    }

    private var statusHint: String {
        switch display {
        case .tunnelBlocked:
            return "Explains why the built-in tunnel can’t run here, and what to use instead."
        case .tunnelAction:
            return "Starts the loopback tunnel Locus needs."
        case .tunnelProblem:
            return "Shows what went wrong and tries again."
        default:
            return ""
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch display {
        case .tunnelAction:
            Image(systemName: TunnelController.isEmbedded ? "bolt.horizontal.circle.fill" : "arrow.up.forward.app.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(LocusTheme.accent)
        case .tunnelBlocked:
            Image(systemName: "arrow.up.forward.app.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(LocusTheme.accent)
        case .tunnelProblem:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(LocusTheme.statusBad)
        case .spoof:
            if case .active = session.status, let sim = session.simulated {
                // An address if one has been resolved for where the fix actually
                // is; coordinates otherwise, which is what a moving route gets.
                if let address = session.simulatedAddress {
                    Text(address)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                } else {
                    Text(String(format: "%.4f, %.4f", sim.latitude, sim.longitude))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        case .ready, .tunnelBusy:
            EmptyView()
        }
    }

    private func handleTap() {
        // A build that can never raise its own tunnel gets the explanation and
        // the LocalDevVPN route, not a retry that will fail the same way.
        if let blocker = tunnel.blocker ?? TunnelController.staticBlocker {
            troubleBlocker = blocker
            return
        }
        // A previous failure has a reason attached; surface it rather than
        // silently retrying the same thing.
        if case .failed(let reason) = tunnel.state {
            session.lastError = reason
        }
        startBuiltInTunnel()
    }

    private func startBuiltInTunnel() {
        isConnecting = true
        Task {
            await tunnel.connect()
            isConnecting = false
            refresh()
            // Connecting can *discover* a blocker: a stripped entitlement only
            // shows itself when iOS is asked to save the configuration.
            if let blocker = tunnel.blocker {
                troubleBlocker = blocker
            }
        }
    }

    /// Only writes when the answer moved.
    ///
    /// This is polled every two seconds for as long as Locus is on screen, and
    /// assigning `@State` invalidates the view whether or not the value changed
    /// — so the status bar and the tray under it were being rebuilt every two
    /// seconds, forever, to draw exactly what was already there.
    private func refresh() {
        let up = TunnelController.loopbackReachable
        if up != loopbackUp { loopbackUp = up }
    }
}

// MARK: - Bottom tray

struct BottomControlsView: View {
    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var pairing: PairingStore
    @Binding var showSettings: Bool
    @Binding var showPlaces: Bool

    @Namespace private var modeSelection

    private let trayShape = RoundedRectangle(cornerRadius: LocusMetrics.trayRadius, style: .continuous)

    var body: some View {
        VStack(spacing: 12) {
            if session.joystickActive {
                HStack(alignment: .bottom, spacing: 12) {
                    if let joystick = session.joystick {
                        JoystickReadout(telemetry: joystick, units: session.drive.units)
                            .transition(.opacity.combined(with: .move(edge: .leading)))
                    }
                    Spacer(minLength: 0)
                    JoystickPad { vector in
                        session.updateJoystick(vector: vector)
                    }
                    .frame(width: 148, height: 148)
                }
                .transition(.scale(scale: 0.85, anchor: .bottomTrailing).combined(with: .opacity))
            }

            travelModePicker

            HStack(spacing: 10) {
                trayIcon("gearshape.fill", label: "Settings") { showSettings = true }
                trayIcon("star.fill", label: "Saved places") { showPlaces = true }
                joystickButton
                primaryAction
            }
        }
        .padding(14)
        .locusGlass(.regular, in: trayShape)
        // Whole tray absorbs taps so near-misses don't fall through to the map.
        .contentShape(trayShape)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: session.joystickActive)
        .animation(.snappy, value: session.travelMode)
    }

    /// Segmented by hand rather than a `Picker`, so the selection can slide
    /// between chips with a matched-geometry pill instead of snapping.
    private var travelModePicker: some View {
        HStack(spacing: 4) {
            ForEach(TravelMode.allCases) { mode in
                let selected = session.travelMode == mode
                Button {
                    session.travelMode = mode
                } label: {
                    Image(systemName: mode.icon)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(selected ? .black : .primary)
                        .frame(width: 46, height: 38)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(LocusTheme.accent)
                                    .matchedGeometryEffect(id: "modePill", in: modeSelection)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(mode.title)
            }
            Spacer(minLength: 0)
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }

    private var joystickButton: some View {
        Button {
            if session.joystickActive {
                session.stopJoystick()
            } else {
                session.startJoystick(pairing: pairing)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "dot.circle.and.hand.point.up.left.fill")
                // "Joy" was an abbreviation nothing explained — it reads as a
                // word, not as the first half of one. There is room for the
                // whole thing, and it shrinks a little before it would clip.
                Text(session.joystickActive ? "Joystick on" : "Joystick")
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(session.joystickActive ? .black : .primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                Capsule().fill(
                    session.joystickActive ? LocusTheme.accentSecondary : Color.primary.opacity(0.08)
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(session.joystickActive ? "Turn joystick off" : "Turn joystick on")
    }

    @ViewBuilder
    private var primaryAction: some View {
        if session.isSpoofing {
            Button {
                session.stop(pairing: pairing)
            } label: {
                Text("Stop")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 72)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 8)
                    .background(Capsule().fill(LocusTheme.danger))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        } else {
            Button {
                guard let pin = session.pin else {
                    session.lastError = "Tap the map to drop a pin first."
                    return
                }
                session.teleport(to: pin, pairing: pairing)
            } label: {
                Text("Teleport")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.black)
                    .frame(minWidth: 96)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 10)
                    .background(Capsule().fill(LocusTheme.accent))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(session.isBusy)
        }
    }

    private func trayIcon(_ systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: LocusMetrics.controlSide, height: LocusMetrics.controlSide)
                .background(Circle().fill(Color.primary.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
