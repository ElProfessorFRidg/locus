import SwiftUI

/// How to get a position that holds with the Both method, in the order it has
/// to happen. Most of it is iOS settings Locus can't change for the person, so
/// the honest help is saying which, where, and why.
struct BothGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Developer replaces the whole position, GPS included — that is what holds it. Network mode underneath rewrites Apple’s Wi-Fi and cell-tower answers, so they don’t contradict it.")
                        .font(.callout)
                }

                Section {
                    step(1, "Developer Mode", "Settings › Privacy & Security › Developer Mode, on. The iPhone restarts.")
                    step(2, "Pairing file", "Locus › Settings › Pairing: import a recent RPPairing file.")
                    step(3, "Certificate", "Locus › Settings › Network mode › install it. Then Settings › General › VPN & Device Management to install the profile, and Settings › General › About › Certificate Trust Settings to switch it on. Locus should say “Installed and trusted”.")
                    step(4, "Method", "Locus › Settings › Spoofing method › Both.")
                    step(5, "Check", "Locus › Settings › Network mode › run the checks: Certificate, Tunnel, DNS and Proxy all green.")
                } header: {
                    Text("Once")
                }

                Section {
                    step(1, "One VPN only", "Turn off Shadowrocket, LocalDevVPN or any other VPN. iOS keeps one active at a time, and another one takes Locus’ tunnel down.")
                    step(2, "Clear iOS’ location cache", "Airplane Mode on, Location Services off (Settings › Privacy & Security), then restart the iPhone. On iOS 26 and later only a restart clears it.")
                    step(3, "Come back without Wi-Fi", "Unlock, open Locus, Airplane Mode off. Leave Wi-Fi off if you can: iOS leans less on access points it already knows.")
                    step(4, "Tunnel up", "The bar at the top mustn’t say “Tap to start the tunnel” — tap it if it does.")
                    step(5, "Location Services on", "Switch them back on.")
                    step(6, "Teleport", "Pick the place and tap Teleport. The bar reads “Spoofing”, with the place under it.")
                    step(7, "Make iOS look again", "Location Services off and on, wait five seconds, then open Maps.")
                } header: {
                    Text("Each time")
                }

                Section {
                    tip("checkmark.seal", "“What apps see” in Settings shows the position other apps get — it should be the new one.")
                    tip("number", "Network mode › Activity: “Replies rewritten” above 0 means the network part is working too. At 0, Developer still holds the position on its own.")
                } header: {
                    Text("Is it working?")
                }

                Section {
                    tip("app.badge", "Don’t force-quit Locus. In the background it resends the position every 8 seconds and reconnects if the tunnel drops.")
                    tip("battery.25", "Avoid Low Power Mode: it can pause Locus in the background.")
                    tip("wifi.slash", "If the position slips, stay on mobile data with Wi-Fi off.")
                    tip("arrow.clockwise", "After a restart of the iPhone, teleport again.")
                } header: {
                    Text("Keeping it")
                }

                Section {
                    tip("stop.circle", "Tap Stop. Then Location Services off and on; if the old place sticks, restart the iPhone — iOS keeps the rewritten answers for a while.")
                } header: {
                    Text("Stopping")
                }

                Section {
                    Text("Apps can tell the Developer part is simulated: iOS marks it, and “What apps see” shows that mark. The network part carries no mark but holds far less well on its own.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Limits")
                }
            }
            .navigationTitle("Using Both")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(LocusTheme.accent)
                .frame(width: 18, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).font(.footnote)
        } icon: {
            Image(systemName: symbol).foregroundStyle(LocusTheme.accent)
        }
    }
}
