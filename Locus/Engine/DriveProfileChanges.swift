import Foundation

/// One driving parameter that differs from the standard one.
struct DriveProfileChange: Identifiable, Equatable {
    /// Stable across builds, so a row can say which field to put back.
    let id: String
    let label: String
    /// What it is set to now.
    let value: String
    /// What it would be if it had never been touched.
    let standard: String
}

extension DriveProfile {

    /// Every parameter that differs from `reference`, in the order the sheet
    /// shows them.
    ///
    /// Thirty-odd parameters, several of them sliders, spread over nine
    /// sections and kept in named profiles that outlive any memory of what was
    /// changed in them. "Why does this one drive like that" had no answer short
    /// of reading the whole sheet twice — once for the profile and once for a
    /// fresh one to compare against.
    ///
    /// `id` and `name` are skipped: a profile differing from the default by
    /// having a name is every profile.
    func changes(from reference: DriveProfile = DriveProfile()) -> [DriveProfileChange] {
        Self.fields.compactMap { field in
            guard field.differs(self, reference) else { return nil }
            return DriveProfileChange(
                id: field.id,
                label: field.label,
                value: field.describe(self),
                standard: field.describe(reference)
            )
        }
    }

    /// Puts one parameter back to what it would be untouched.
    mutating func revert(_ changeID: String, to reference: DriveProfile = DriveProfile()) {
        guard let field = Self.fields.first(where: { $0.id == changeID }) else { return }
        field.revert(&self, reference)
    }

    /// Puts every parameter back, keeping the profile's identity and name — the
    /// same rule the sheet's Reset already follows.
    mutating func revertAll(to reference: DriveProfile = DriveProfile()) {
        for field in Self.fields {
            field.revert(&self, reference)
        }
    }

    // MARK: - The table

    /// One comparable parameter: how to tell it changed, how to say what it is,
    /// and how to put it back.
    struct Field {
        let id: String
        let label: String
        let differs: (DriveProfile, DriveProfile) -> Bool
        let describe: (DriveProfile) -> String
        let revert: (inout DriveProfile, DriveProfile) -> Void
    }

    private static func field<Value: Equatable>(
        _ id: String,
        _ label: String,
        _ keyPath: WritableKeyPath<DriveProfile, Value>,
        _ describe: @escaping (DriveProfile) -> String
    ) -> Field {
        Field(
            id: id,
            label: label,
            differs: { $0[keyPath: keyPath] != $1[keyPath: keyPath] },
            describe: describe,
            revert: { profile, reference in profile[keyPath: keyPath] = reference[keyPath: keyPath] }
        )
    }

    private static func onOff(_ value: Bool) -> String { value ? "On" : "Off" }

    /// Ordered as the sheet is, so the list reads as a summary of it rather
    /// than as an alphabetised dump.
    static let fields: [Field] = [
        field("speedSource", "Speed from", \.speedSource) { $0.speedSource.title },
        field("speedTolerance", "Tolerance", \.speedTolerance) {
            let percent = Int(($0.speedTolerance * 100).rounded())
            return percent > 0 ? "+\(percent)%" : "\(percent)%"
        },
        field("fixedSpeed", "Fixed speed", \.fixedSpeed) {
            "\(Int($0.fixedSpeed.rounded())) \($0.units.short)"
        },
        field("speedCeiling", "Never exceed", \.speedCeiling) {
            "\(Int($0.speedCeiling.rounded())) \($0.units.short)"
        },
        field("units", "Units", \.units) { $0.units.short },
        field("timeScale", "Speed of time", \.timeScale) { String(format: "%.4g×", $0.timeScale) },
        field("updateRateHz", "Fix rate", \.updateRateHz) { String(format: "%.4g Hz", $0.updateRateHz) },

        field("vehicle", "Car", \.vehicle) { $0.vehicle.title },
        field("acceleration", "Acceleration", \.acceleration) { String(format: "%.1f m/s²", $0.acceleration) },
        field("braking", "Braking", \.braking) { String(format: "%.1f m/s²", $0.braking) },
        field("cornering", "Cornering", \.cornering) { $0.cornering.title },

        field("traffic", "Traffic", \.traffic) { $0.traffic.title },
        field("stopAtJunctions", "Stop at junctions", \.stopAtJunctions) { onOff($0.stopAtJunctions) },
        field("junctionStopChance", "Caught red", \.junctionStopChance) {
            "\(Int(($0.junctionStopChance * 100).rounded()))%"
        },
        field("junctionStopSeconds", "Wait at a junction", \.junctionStopSeconds) {
            "\(Int($0.junctionStopSeconds.lower.rounded()))–\(Int($0.junctionStopSeconds.upper.rounded())) s"
        },
        field("waypointDwellSeconds", "Dwell at waypoints", \.waypointDwellSeconds) {
            "\(Int($0.waypointDwellSeconds.rounded())) s"
        },

        field("speedJitter", "Speed wobble", \.speedJitter) {
            "±\(Int(($0.speedJitter * 100).rounded()))%"
        },
        field("gpsNoiseMetres", "GPS scatter", \.gpsNoiseMetres) { String(format: "%.1f m", $0.gpsNoiseMetres) },
        field("laneOffsetMetres", "Lane offset", \.laneOffsetMetres) { String(format: "%.1f m", $0.laneOffsetMetres) },
        field("driveOnLeft", "Drive on the left", \.driveOnLeft) { onOff($0.driveOnLeft) },

        field("startDelaySeconds", "Start delay", \.startDelaySeconds) {
            "\(Int($0.startDelaySeconds.rounded())) s"
        },
        field("endBehavior", "At the end", \.endBehavior) { $0.endBehavior.title },

        field("showHUD", "Speedometer", \.showHUD) { onOff($0.showHUD) },
        field("showLiveActivity", "Live Activity", \.showLiveActivity) { onOff($0.showLiveActivity) },
        field("warnWhenOverLimit", "Warn when over", \.warnWhenOverLimit) { onOff($0.warnWhenOverLimit) },
        field("hapticOnLimitChange", "Haptic when speeding", \.hapticOnLimitChange) {
            onOff($0.hapticOnLimitChange)
        },
        field("keepScreenAwake", "Keep the screen on", \.keepScreenAwake) { onOff($0.keepScreenAwake) },
        field("showTripEconomy", "Trip fuel & CO₂", \.showTripEconomy) { onOff($0.showTripEconomy) },
        field("consumption", "Consumption", \.consumption) { String(format: "%.1f L/100km", $0.consumption) }
    ]
}
