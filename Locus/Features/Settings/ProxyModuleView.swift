import CoreLocation
import SwiftUI
import UIKit

/// Writes a proxy-app module that puts Apple's Wi-Fi location where Locus' pin
/// is — the way to move the phone when there is no pairing or tunnel to move
/// it with. See `ProxyModule` for what that does and doesn't cover.
struct ProxyModuleView: View {
    /// Where the module should put the phone: the place being simulated, or
    /// failing that the pin. Nil when there is neither.
    let coordinate: CLLocationCoordinate2D?
    var place: String?

    @AppStorage("proxyModule.app") private var app = ProxyApp.shadowrocket
    @AppStorage("proxyModule.accuracy") private var accuracy = ProxyModule.defaultAccuracy
    @State private var fileURL: URL?
    @State private var showText = false

    private var module: ProxyModule? {
        guard let coordinate else { return nil }
        return ProxyModule(app: app, coordinate: coordinate, place: place, horizontalAccuracy: accuracy)
    }

    var body: some View {
        List {
            if let module {
                moduleSection(module)
                stepsSection
            } else {
                Section {
                    Text("Drop a pin on the map first — the module is written for wherever the pin is.")
                        .foregroundStyle(.secondary)
                }
            }
            limitsSection
        }
        .navigationTitle("Proxy app module")
        .navigationBarTitleDisplayMode(.inline)
        // Rewritten whenever the text changes, so the share sheet always hands
        // over the place and app on screen, never the previous one.
        .task(id: module?.text) {
            fileURL = module.flatMap { write($0) }
        }
    }

    private func moduleSection(_ module: ProxyModule) -> some View {
        Section {
            Picker("App", selection: $app) {
                ForEach(ProxyApp.allCases) { Text($0.title).tag($0) }
            }

            LabeledContent("Location") {
                VStack(alignment: .trailing, spacing: 2) {
                    if let place, !place.isEmpty {
                        Text(place).lineLimit(1)
                    }
                    Text("\(module.latitudeText), \(module.longitudeText)")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Picker("Accuracy", selection: $accuracy) {
                ForEach(ProxyModule.accuracyChoices, id: \.self) { Text("\($0) m").tag($0) }
            }

            if let fileURL {
                ShareLink(item: fileURL) {
                    Label("Share \(module.fileName)", systemImage: "square.and.arrow.up")
                }
            }

            Button {
                UIPasteboard.general.string = module.text
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } label: {
                Label("Copy \(app.moduleNoun) text", systemImage: "doc.on.doc")
            }

            DisclosureGroup("Show \(app.moduleNoun)", isExpanded: $showText) {
                Text(module.text)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
            }
        } header: {
            Text("\(app.title) \(app.moduleNoun)")
        } footer: {
            Text("Always named \u{201C}\(ProxyModule.name)\u{201D}, so importing a new place replaces the last one. Smaller accuracy reads more like GPS.")
        }
    }

    private var stepsSection: some View {
        Section {
            step(1, "In \(app.title), turn on HTTPS decryption (MITM) and install its certificate.")
            step(2, "Settings › General › About › Certificate Trust Settings — turn on full trust for that certificate.")
            step(3, "Share the \(app.moduleNoun) to \(app.title), or save it to Files and import it there, then enable it.")
            step(4, "Reconnect \(app.title), then turn Location Services off and on again.")
        } header: {
            Text("Using it")
        } footer: {
            Text("Leave the \(app.moduleNoun) off when you don't need it: while it runs, \(app.title) decrypts Apple's location lookups.")
        }
    }

    private var limitsSection: some View {
        Section {
            Text("This is the fallback, not Locus' usual method. It rewrites the answer Apple sends back for nearby Wi-Fi and cell towers, so outdoors, where real GPS gets a fix, the phone can drift home. Teleporting through the tunnel has no such gap — use that whenever it works. Routes and the joystick need the tunnel too.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Link(destination: ProxyModule.homepage) {
                Label("ios-location-spoofer", systemImage: "arrow.up.right.square")
            }
        } footer: {
            Text("The rewriting script is ios-location-spoofer's (AGPL-3.0). \(app.title) downloads it from GitHub itself; Locus only writes the \(app.moduleNoun) that points at it.")
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        Label {
            Text(text).font(.subheadline)
        } icon: {
            Image(systemName: "\(number).circle.fill")
                .foregroundStyle(Color.accentColor)
        }
    }

    private func write(_ module: ProxyModule) -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ProxyModule", isDirectory: true)
        let url = folder.appendingPathComponent(module.fileName)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try module.text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}
