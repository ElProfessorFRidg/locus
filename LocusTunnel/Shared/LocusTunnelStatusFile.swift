//
//  LocusTunnelStatusFile.swift
//  Shared between the Locus app and the LocusTunnel extension.
//
//  The packet tunnel runs in its own process, so its `os_log` output never
//  reaches the app — every diagnostic it emits (active interface, the cellular
//  rebind, packet errors) would otherwise be invisible exactly where the user is
//  looking. This is a small App Group file the extension appends to and the app
//  polls, so "the tunnel came up but nothing goes through it" comes with a
//  reason attached.
//
//  If the App Group entitlement is stripped during re-signing, `containerURL`
//  returns nil and everything here becomes a no-op — `isAvailable` exists so the
//  UI can say that out loud instead of showing an empty log forever.
//

import Foundation

enum LocusTunnelStatusFile {
    static let appGroup = "group.com.chrismack.locus"

    private static let fileName = "tunnel-status.txt"
    private static let maxBytes = 64 * 1024
    private static let queue = DispatchQueue(label: "com.chrismack.locus.tunnelstatus")

    static var isAvailable: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) != nil
    }

    private static var url: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent(fileName)
    }

    /// Call from the extension. Safe from any thread.
    static func write(_ message: String) {
        queue.async {
            guard let url else { return }
            let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
            trim(url)
        }
    }

    /// Call from the app to read everything the extension logged since the last
    /// `clear()` (which happens on each `startTunnel`).
    static func readAll() -> [String] {
        guard let url,
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    static func clear() {
        queue.async {
            guard let url else { return }
            try? Data().write(to: url)
        }
    }

    private static func trim(_ url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int, size > maxBytes,
              let data = try? Data(contentsOf: url) else { return }
        try? Data(data.suffix(maxBytes / 2)).write(to: url)
    }
}
