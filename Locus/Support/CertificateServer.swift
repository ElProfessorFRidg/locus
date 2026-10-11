import Foundation
import Network
import UIKit

/// Hands the authority certificate to Safari, which is what makes iOS offer to
/// install it. A `.cer` served with the right content type becomes "this website
/// is trying to download a configuration profile" — there is no API to install
/// a certificate directly.
///
/// Listens on loopback only, serves the one file, and stops after the first
/// download or two minutes, whichever comes first.
@MainActor
final class CertificateServer {
    static let shared = CertificateServer()

    private var listener: NWListener?
    private var shutdown: DispatchWorkItem?
    private var background: UIBackgroundTaskIdentifier = .invalid

    nonisolated static let fileName = "LocusAuthority.cer"

    /// Starts serving `certificate` and returns the URL to open, or `nil` if the
    /// listener couldn't start.
    func publish(_ certificate: Data) async -> URL? {
        stop()

        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        guard let listener = try? NWListener(using: parameters) else { return nil }

        let response = Self.response(for: certificate)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, _ in
                connection.send(content: response, completion: .contentProcessed { _ in
                    connection.cancel()
                    Task { @MainActor in CertificateServer.shared.scheduleStop(after: 5) }
                })
            }
        }

        let port: NWEndpoint.Port? = await withCheckedContinuation { continuation in
            let gate = Gate()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if gate.claim() { continuation.resume(returning: listener.port) }
                case .failed, .cancelled:
                    if gate.claim() { continuation.resume(returning: nil) }
                default:
                    break
                }
            }
            listener.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if gate.claim() { continuation.resume(returning: nil) }
            }
        }

        guard let port else {
            listener.cancel()
            return nil
        }

        self.listener = listener
        background = UIApplication.shared.beginBackgroundTask(withName: "LocusCertificateServer") { [weak self] in
            Task { @MainActor in self?.stop() }
        }
        scheduleStop(after: 120)
        return URL(string: "http://127.0.0.1:\(port.rawValue)/\(Self.fileName)")
    }

    func stop() {
        shutdown?.cancel()
        shutdown = nil
        listener?.cancel()
        listener = nil
        if background != .invalid {
            UIApplication.shared.endBackgroundTask(background)
            background = .invalid
        }
    }

    private func scheduleStop(after seconds: TimeInterval) {
        shutdown?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.stop() }
        }
        shutdown = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private nonisolated static func response(for certificate: Data) -> Data {
        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: application/x-x509-ca-cert\r\n"
        head += "Content-Disposition: attachment; filename=\"\(fileName)\"\r\n"
        head += "Content-Length: \(certificate.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + certificate
    }
}

private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
