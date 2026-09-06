import SwiftUI

/// Every knob that shapes how Locus drives a route.
///
/// Ordered by how often you'd touch it: speed at the top (the tolerance dial is
/// the headline), then the car, then the things that make a trace look driven,
/// then playback, then the frankly ornamental.
struct DriveSettingsView: View {
    @Binding var profile: DriveProfile
    let mode: TravelMode
    /// Present when the caller has a profile list to switch between; the sheet
    /// still works on a lone binding without one.
    var store: DriveProfileStore?
    var onSelect: ((UUID) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var showResetConfirm = false
    @State private var showDeleteConfirm = false
    @State private var renaming = false
    @State private var draftName = ""
    @State private var showStarters = false

    /// Sample limits used for the live "what this actually means" preview.
    private var previewLimits: [Double] {
        profile.units == .kph ? [30, 50, 90, 130] : [25, 35, 55, 70]
    }

    var body: some View {
        NavigationStack {
            Form {
                if let store { profileSection(store) }
                speedSection
                if profile.speedSource == .roadLimit { toleranceSection }
                vehicleSection
                trafficSection
                realismSection
                playbackSection
                gadgetSection
                resetSection
            }
            .navigationTitle("Driving")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Reset every driving parameter?",
                isPresented: $showResetConfirm,
                titleVisibility: .visible
            ) {
                // Keeps the identity so the reset lands on this profile rather
                // than orphaning it and creating a nameless new one.
                Button("Reset", role: .destructive) {
                    var fresh = DriveProfile()
                    fresh.id = profile.id
                    fresh.name = profile.name
                    profile = fresh
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(
                "Delete “\(profile.name)”?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    guard let store else { return }
                    let id = profile.id
                    store.delete(id)
                    onSelect?(store.activeID)
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Rename profile", isPresented: $renaming) {
                TextField("Name", text: $draftName)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    store?.rename(profile.id, to: draftName)
                    if let renamed = store?.profile(profile.id) { profile.name = renamed.name }
                }
            }
            .sheet(isPresented: $showStarters) {
                if let store {
                    StarterProfilesView(store: store) { id in
                        showStarters = false
                        onSelect?(id)
                    }
                }
            }
        }
    }

    // MARK: - Profiles

    private func profileSection(_ store: DriveProfileStore) -> some View {
        Section {
            Picker("Profile", selection: Binding(
                get: { profile.id },
                set: { onSelect?($0) }
            )) {
                ForEach(store.profiles) { candidate in
                    Text(candidate.name).tag(candidate.id)
                }
            }

            Menu {
                Button("Rename…", systemImage: "pencil") {
                    draftName = profile.name
                    renaming = true
                }
                Button("Duplicate", systemImage: "plus.square.on.square") {
                    let copy = store.duplicate(profile)
                    onSelect?(copy.id)
                }
                Button("New blank profile", systemImage: "plus") {
                    let fresh = store.add(named: "New profile")
                    onSelect?(fresh.id)
                }
                Button("Add a ready-made one…", systemImage: "sparkles") {
                    showStarters = true
                }
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive) {
                    showDeleteConfirm = true
                }
            } label: {
                Label("Manage profiles", systemImage: "square.stack.3d.up")
            }
        } header: {
            Text("Profile")
        } footer: {
            Text("A commute and a walk in the park want opposite settings. Keep one of each and switch, instead of retuning thirty sliders.")
        }
    }

    // MARK: - Speed

    private var speedSection: some View {
        Section {
            Picker("Speed from", selection: $profile.speedSource) {
                ForEach(SpeedSource.allCases) { source in
                    Text(source.title).tag(source)
                }
            }
            .pickerStyle(.segmented)

            Text(profile.speedSource.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if profile.speedSource == .fixed {
                stepperRow(
                    "Speed",
                    value: $profile.fixedSpeed,
                    range: 1...400,
                    step: profile.units == .kph ? 5 : 5,
                    suffix: profile.units.short
                )
            }

            stepperRow(
                "Never exceed",
                value: $profile.speedCeiling,
                range: 10...400,
                step: 5,
                suffix: profile.units.short
            )

            Picker("Units", selection: unitsBinding) {
                ForEach(SpeedUnit.allCases) { unit in
                    Text(unit.short).tag(unit)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Speed")
        } footer: {
            if profile.speedSource == .roadLimit {
                if mode.usesRoadLimits {
                    Text("Locus estimates each road's limit from how fast Apple expects the route to take and how the road bends — MapKit publishes no posted limits, so this is a reading of the road, not a lookup.")
                } else {
                    Text("Road limits are estimated from driving-speed data. On \(mode.title.lowercased()) they'll read high — Fixed speed or Travel mode fits better.")
                }
            }
        }
    }

    private var unitsBinding: Binding<SpeedUnit> {
        Binding(
            get: { profile.units },
            set: { profile.convert(to: $0) }
        )
    }

    // MARK: - Tolerance (the +10%)

    private var toleranceSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Tolerance")
                    Spacer()
                    Text(toleranceLabel)
                        .font(.body.weight(.semibold).monospacedDigit())
                        .foregroundStyle(toleranceColor)
                }

                Slider(value: $profile.speedTolerance, in: -0.30...0.50, step: 0.01)
                    .tint(toleranceColor)

                HStack(spacing: 8) {
                    ForEach([-0.10, 0.0, 0.05, 0.10, 0.20], id: \.self) { preset in
                        Button {
                            withAnimation(.snappy) { profile.speedTolerance = preset }
                        } label: {
                            Text(presetLabel(preset))
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                        }
                        .buttonStyle(.plain)
                        .background(
                            Capsule().fill(
                                abs(profile.speedTolerance - preset) < 0.005
                                    ? LocusTheme.accent.opacity(0.35)
                                    : Color.primary.opacity(0.08)
                            )
                        )
                        .contentShape(Capsule())
                    }
                }
            }
            .padding(.vertical, 4)

            // The whole point of a percentage is what it turns into. Show it.
            VStack(alignment: .leading, spacing: 6) {
                ForEach(previewLimits, id: \.self) { limit in
                    HStack(spacing: 10) {
                        SpeedLimitSign(value: Int(limit))
                            .scaleEffect(0.55)
                            .frame(width: 30, height: 30)
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text("\(Int((limit * (1 + profile.speedTolerance)).rounded())) \(profile.units.short)")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                        Spacer()
                        if limit * (1 + profile.speedTolerance) > profile.speedCeiling {
                            Label("capped", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(LocusTheme.statusWarn)
                                .labelStyle(.titleAndIcon)
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        } header: {
            Text("Respect the limit, plus…")
        } footer: {
            Text("Applied on top of every estimated limit, then clipped by “never exceed”. Corners and traffic can still hold the car below this.")
        }
    }

    private var toleranceLabel: String {
        let percent = Int((profile.speedTolerance * 100).rounded())
        return percent > 0 ? "+\(percent)%" : "\(percent)%"
    }

    private var toleranceColor: Color {
        if profile.speedTolerance > 0.15 { return LocusTheme.overLimit }
        if profile.speedTolerance > 0 { return LocusTheme.accentSecondary }
        return LocusTheme.accent
    }

    private func presetLabel(_ value: Double) -> String {
        let percent = Int((value * 100).rounded())
        return percent > 0 ? "+\(percent)" : "\(percent)"
    }

    // MARK: - Vehicle

    private var vehicleSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(VehiclePreset.allCases) { preset in
                        Button {
                            withAnimation(.snappy) { profile.apply(preset) }
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: preset.icon)
                                    .font(.title3)
                                Text(preset.title)
                                    .font(.caption2.weight(.medium))
                                    .lineLimit(1)
                            }
                            .frame(width: 74, height: 62)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(profile.vehicle == preset ? Color.black : .primary)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(profile.vehicle == preset ? LocusTheme.accent : Color.primary.opacity(0.08))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
                .padding(.vertical, 2)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

            sliderRow(
                "Acceleration",
                value: customising($profile.acceleration),
                range: 0.5...6.0,
                format: "%.1f m/s²"
            )
            sliderRow(
                "Braking",
                value: customising($profile.braking),
                range: 1.0...8.0,
                format: "%.1f m/s²"
            )

            Picker("Cornering", selection: $profile.cornering) {
                ForEach(CorneringStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
        } header: {
            Text("Car")
        } footer: {
            Text("Cornering is a lateral-grip budget: a bend of radius r is taken at √(budget × r), so tight turns slow the car down on their own. \(profile.cornering.title) is \(String(format: "%.1f", profile.cornering.lateralAcceleration)) m/s².")
        }
    }

    /// Editing a physics value by hand means you're no longer on a preset.
    private func customising(_ binding: Binding<Double>) -> Binding<Double> {
        Binding(
            get: { binding.wrappedValue },
            set: {
                binding.wrappedValue = $0
                profile.vehicle = .custom
            }
        )
    }

    // MARK: - Traffic

    private var trafficSection: some View {
        Section {
            Picker("Traffic", selection: $profile.traffic) {
                ForEach(TrafficDensity.allCases) { density in
                    Text(density.title).tag(density)
                }
            }

            Toggle("Stop at junctions", isOn: $profile.stopAtJunctions)

            if profile.stopAtJunctions {
                sliderRow(
                    "Caught red",
                    value: $profile.junctionStopChance,
                    range: 0...1,
                    format: "%.0f%%",
                    scale: 100
                )
                HStack {
                    Text("Wait")
                    Spacer()
                    Text("\(Int(profile.junctionStopSeconds.lower))–\(Int(profile.junctionStopSeconds.upper)) s")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $profile.junctionStopSeconds.lower, in: 0...60, step: 1)
                    .tint(LocusTheme.accent)
                Slider(value: $profile.junctionStopSeconds.upper, in: 0...120, step: 1)
                    .tint(LocusTheme.accentSecondary)
            }

            sliderRow(
                "Dwell at waypoints",
                value: $profile.waypointDwellSeconds,
                range: 0...120,
                format: "%.0f s"
            )
        } header: {
            Text("Traffic & stops")
        } footer: {
            Text("Traffic is a slow random walk around \(Int(profile.traffic.meanFactor * 100))% of the target speed, so it thickens and clears over tens of seconds instead of flickering.")
        }
    }

    // MARK: - Realism

    private var realismSection: some View {
        Section {
            sliderRow(
                "Speed wobble",
                value: $profile.speedJitter,
                range: 0...0.30,
                format: "±%.0f%%",
                scale: 100
            )
            sliderRow(
                "GPS scatter",
                value: $profile.gpsNoiseMetres,
                range: 0...15,
                format: "%.1f m"
            )
            sliderRow(
                "Lane offset",
                value: $profile.laneOffsetMetres,
                range: 0...6,
                format: "%.1f m"
            )
            Toggle("Drive on the left", isOn: $profile.driveOnLeft)
        } header: {
            Text("Realism")
        } footer: {
            Text("Scatter is added to the reported fix only — the car itself stays on the road, so noise never drifts you into a field.")
        }
    }

    // MARK: - Playback

    private var playbackSection: some View {
        Section {
            HStack {
                Text("Speed of time")
                Spacer()
                Text(String(format: "%.4g×", profile.timeScale))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            HStack(spacing: 8) {
                ForEach([0.5, 1.0, 2.0, 4.0, 8.0], id: \.self) { scale in
                    Button {
                        withAnimation(.snappy) { profile.timeScale = scale }
                    } label: {
                        Text(String(format: "%.4g×", scale))
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                    }
                    .buttonStyle(.plain)
                    .background(
                        Capsule().fill(
                            abs(profile.timeScale - scale) < 0.01
                                ? LocusTheme.accent.opacity(0.35)
                                : Color.primary.opacity(0.08)
                        )
                    )
                    .contentShape(Capsule())
                }
            }

            Picker("Fix rate", selection: $profile.updateRateHz) {
                Text("0.5 Hz").tag(0.5)
                Text("1 Hz").tag(1.0)
                Text("2 Hz").tag(2.0)
                Text("4 Hz").tag(4.0)
            }

            sliderRow(
                "Start delay",
                value: $profile.startDelaySeconds,
                range: 0...30,
                format: "%.0f s"
            )

            Picker("At the end", selection: $profile.endBehavior) {
                ForEach(RouteEndBehavior.allCases) { behavior in
                    Label(behavior.title, systemImage: behavior.icon).tag(behavior)
                }
            }
        } header: {
            Text("Playback")
        } footer: {
            Text("Real GPS reports about once a second. Higher rates look smoother on the map and ask more of the tunnel; the start delay gives you time to switch apps first.")
        }
    }

    // MARK: - Gadgets

    private var gadgetSection: some View {
        Section {
            Toggle("Speedometer over the map", isOn: $profile.showHUD)
            Toggle("Lock Screen Live Activity", isOn: $profile.showLiveActivity)
            Toggle("Warn when over the limit", isOn: $profile.warnWhenOverLimit)
            Toggle("Haptic when speeding", isOn: $profile.hapticOnLimitChange)
            Toggle("Trip fuel & CO₂", isOn: $profile.showTripEconomy)
            if profile.showTripEconomy {
                sliderRow(
                    "Consumption",
                    value: $profile.consumption,
                    range: 0...30,
                    format: "%.1f L/100km"
                )
            }
        } header: {
            Text("Extras")
        } footer: {
            Text("The Live Activity keeps speed and progress on the Lock Screen while a route plays, so it doesn't need the app open. The fuel figure is your consumption times the distance — a garnish on the trip summary, not something the simulation measured.")
        }
    }

    private var resetSection: some View {
        Section {
            Button("Reset driving parameters", role: .destructive) {
                showResetConfirm = true
            }
        }
    }

    // MARK: - Row builders

    private func sliderRow(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: String,
        scale: Double = 1
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value.wrappedValue * scale))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range)
                .tint(LocusTheme.accent)
        }
        .padding(.vertical, 2)
    }

    private func stepperRow(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        suffix: String
    ) -> some View {
        Stepper(value: value, in: range, step: step) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue.rounded())) \(suffix)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}
