import SwiftUI

/// Ready-made profiles to start from.
///
/// Offered rather than installed on first launch: four profiles nobody asked
/// for is clutter, but "switching beats retuning" only becomes obvious once
/// there is something to switch to.
struct StarterProfilesView: View {
    @ObservedObject var store: DriveProfileStore
    var onAdded: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(DriveProfileStore.starters.enumerated()), id: \.offset) { _, starter in
                        Button {
                            let profile = store.add(named: starter.name, from: starter.build())
                            onAdded(profile.id)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(starter.name)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text(Self.describe(starter.build()))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text("Each one is a normal profile once added — change anything you like.")
                }
            }
            .navigationTitle("Ready-made")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    /// The three or four settings that make each starter different, rather than
    /// a paragraph nobody reads.
    private static func describe(_ profile: DriveProfile) -> String {
        var parts: [String] = []

        switch profile.speedSource {
        case .roadLimit:
            let percent = Int((profile.speedTolerance * 100).rounded())
            parts.append(percent == 0 ? "road limits" : "road limits \(percent > 0 ? "+" : "")\(percent)%")
        case .fixed:
            parts.append("\(Int(profile.fixedSpeed.rounded())) \(profile.units.short)")
        case .travelMode:
            parts.append("travel-mode pace")
        }

        parts.append("\(profile.traffic.title.lowercased()) traffic")

        if profile.stopAtJunctions {
            parts.append("stops at \(Int((profile.junctionStopChance * 100).rounded()))% of junctions")
        } else {
            parts.append("no junction stops")
        }

        if profile.vehicle != .custom {
            parts.append(profile.vehicle.title.lowercased())
        }

        return parts.joined(separator: " · ")
    }
}
