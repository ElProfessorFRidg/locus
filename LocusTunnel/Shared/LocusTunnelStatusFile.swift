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
//  Everything here runs inside a packet-tunnel extension, which iOS holds to a
//  memory ceiling small enough that a per-line allocation is worth caring about.
//  So the container lookup, the date formatter and the file descriptor are all
//  resolved once and reused, and the size cap is tracked in memory rather than
//  rediscovered with a `stat` on every line.
//

import Foundation

enum LocusTunnelStatusFile {
    static let appGroup = "group.com.chrismack.locus"

    private static let fileName = "tunnel-status.txt"
    private static let maxBytes = 64 * 1024
    private static let queue = DispatchQueue(label: "com.chrismack.locus.tunnelstatus")

    /// Resolved once. `containerURL(forSecurityApplicationGroupIdentifier:)` is a
    /// cross-process lookup into the container manager, and the extension used to
    /// pay for one on every line it logged. The answer cannot change while the
    /// process is alive.
    private static let url: URL? = FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
        .appendingPathComponent(fileName)

    /// Built once too: `ISO8601DateFormatter` is among the most expensive objects
    /// in Foundation to create, and one was being made and thrown away per line.
    /// Only ever touched on `queue`.
    private static let stamp = ISO8601DateFormatter()

    /// Open append handle, and what the file's length is known to be. Both are
    /// `queue`-confined.
    private static var handle: FileHandle?
    private static var bytesOnDisk = 0

    static var isAvailable: Bool { url != nil }

    /// Call from the extension. Safe from any thread.
    static func write(_ message: String) {
        queue.async {
            guard let handle = openedHandle() else { return }
            let line = "[\(stamp.string(from: Date()))] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            handle.write(data)
            bytesOnDisk += data.count
            // Only when the cap is actually crossed. The old version stat'ed the
            // file on every single line and, once it was big, read all 64 KB back
            // into memory to rewrite half of them.
            if bytesOnDisk > maxBytes { trim() }
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
            closeHandle()
            guard let url else { return }
            try? Data().write(to: url)
            bytesOnDisk = 0
        }
    }

    /// The append handle, opened on first use and kept. Opening and closing a
    /// file descriptor per log line is two syscalls the tunnel doesn't need to
    /// make while it is moving packets.
    private static func openedHandle() -> FileHandle? {
        if let handle { return handle }
        guard let url else { return nil }

        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil)
        }
        guard let opened = try? FileHandle(forWritingTo: url) else { return nil }

        bytesOnDisk = Int(opened.seekToEndOfFile())
        handle = opened
        return opened
    }

    private static func closeHandle() {
        try? handle?.close()
        handle = nil
    }

    /// Keeps the newest half and drops the rest. The handle is closed first
    /// because the atomic write replaces the file underneath it.
    private static func trim() {
        guard let url, let data = try? Data(contentsOf: url) else { return }
        let kept = Data(data.suffix(maxBytes / 2))
        closeHandle()
        try? kept.write(to: url, options: .atomic)
        bytesOnDisk = kept.count
    }
}
