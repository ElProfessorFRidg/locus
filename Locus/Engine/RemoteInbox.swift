import Darwin
import Foundation
import UIKit

/// Commands as files, for when Locus is launched with nothing to open: started
/// in the background by a helper, device locked, no scene, no URL.
///
/// `/var/jb/var/locate-ipad/inbox/<id>.json` goes in, `results/<id>.json` comes
/// out. No key: the directory is only reachable by a process with the
/// file-access exception (or root), and such a process could read the key file
/// next door anyway. URLs, which any app or web page can fire, still need it.
///
/// Nothing here touches a scene, a view or the setup flow.
@MainActor
final class RemoteInbox {
    static let shared = RemoteInbox()

    static let inboxDirectory = RemoteKey.directory + "inbox/"
    static let resultsDirectory = RemoteKey.directory + "results/"
    static let darwinNotification = "com.aubin.locus.inbox"
    private static let commandCap: TimeInterval = 25
    private static let resultLifetime: TimeInterval = 600

    private var started = false
    private var scanning = false
    private var timer: Timer?
    private var notifyToken: Int32 = 0

    func start() {
        guard !started else { return }
        started = true

        // (b) A helper can poke it: `notifyutil -p com.aubin.locus.inbox`.
        notify_register_dispatch(Self.darwinNotification, &notifyToken, DispatchQueue.main) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
        // (c) While the process is awake at all.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
        // (d) Coming to the front.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
        // (a) Launch.
        scan()
    }

    private struct Candidate {
        var id: String
        var path: String
        var modified: TimeInterval
    }

    func scan() {
        guard !scanning else { return }
        let candidates = Self.candidates()
        Self.pruneResults()
        guard !candidates.isEmpty else { return }
        scanning = true
        Task { @MainActor in
            for candidate in candidates { await self.process(candidate) }
            self.scanning = false
        }
    }

    /// Regular, small files named `<hex id>.json`, oldest first. Symlinks,
    /// directories and anything big are left alone.
    private static func candidates() -> [Candidate] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: inboxDirectory) else { return [] }
        var found: [Candidate] = []
        for name in names where name.hasSuffix(".json") {
            let id = String(name.dropLast(5))
            guard RemoteCommandParser.isValidInboxID(id) else { continue }
            let path = inboxDirectory + name
            var info = stat()
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_size <= off_t(RemoteCommandParser.maxInboxBytes) else { continue }
            let modified = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9
            found.append(Candidate(id: id, path: path, modified: modified))
        }
        return found.sorted { $0.modified == $1.modified ? $0.id < $1.id : $0.modified < $1.modified }
    }

    private func process(_ candidate: Candidate) async {
        // Read, then delete — even when it turns out to be junk.
        let data = FileManager.default.contents(atPath: candidate.path)
        unlink(candidate.path)

        var command = "unknown"
        var failure: String?
        if let data {
            command = RemoteCommandParser.inboxCommandName(data)
            switch RemoteCommandParser.parseInbox(data, fileID: candidate.id) {
            case .failure(let error):
                failure = error.message
                RemoteControl.shared.recordFailure(command, error.message)
            case .success(let parsed):
                failure = await run(parsed.command)
            }
        } else {
            failure = "unreadable"
            RemoteControl.shared.recordFailure(command, "unreadable")
        }

        let result = RemoteResult(
            id: candidate.id,
            cmd: command,
            ok: failure == nil,
            error: failure,
            ts: Int(Date().timeIntervalSince1970),
            state: RemoteStateWriter.shared.currentState()
        )
        if let encoded = try? result.jsonData() {
            RemoteStateWriter.shared.persistResult(encoded, id: candidate.id)
        }
        RemoteStateWriter.shared.writeNow()
    }

    /// Runs the command and waits for it to settle, but not past the cap.
    private func run(_ command: RemoteCommand) async -> String? {
        var finished = false
        var error: String?
        Task { @MainActor in
            error = await RemoteControl.shared.perform(command)
            finished = true
        }
        let deadline = Date().addingTimeInterval(Self.commandCap)
        while !finished && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard finished else {
            let message = "timed out after \(Int(Self.commandCap)) s"
            RemoteControl.shared.recordFailure(command.name, message)
            return message
        }
        return error
    }

    private static func pruneResults() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: resultsDirectory) else { return }
        let cutoff = Date().timeIntervalSince1970 - resultLifetime
        for name in names where name.hasSuffix(".json") {
            let path = resultsDirectory + name
            var info = stat()
            if lstat(path, &info) == 0, TimeInterval(info.st_mtimespec.tv_sec) < cutoff {
                unlink(path)
            }
        }
    }
}
