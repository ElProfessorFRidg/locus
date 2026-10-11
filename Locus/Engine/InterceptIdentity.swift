import CryptoKit
import Foundation
import Security

/// The certificates network mode needs: an authority the person installs and
/// trusts, and a leaf for the location hosts that the authority has signed.
///
/// Two choices keep this from being a loaded gun:
///
/// - **The authority's private key is thrown away** the moment it has signed the
///   leaf. Nothing can ever be issued from it again — there is no key left to
///   issue with — so trusting it means trusting exactly one certificate.
/// - **The authority is name-constrained** to the location hosts. Even a copy of
///   the key would not let anyone impersonate anything else.
///
/// The leaf's key is the only secret kept, in the app's own sandbox.
@MainActor
final class InterceptIdentity: ObservableObject {
    static let shared = InterceptIdentity()

    enum Trust: Equatable {
        case notCreated
        /// Created, but iOS doesn't (yet) trust it: not installed, or installed
        /// and not switched on under Certificate Trust Settings.
        case notTrusted
        case trusted
    }

    @Published private(set) var trust: Trust = .notCreated
    /// Why iOS's own evaluation of the leaf failed, verbatim, when it did — the
    /// difference between "not switched on yet" and "the certificate is wrong".
    @Published private(set) var trustFailure: String?

    struct Material: Codable, Equatable {
        var authority: Data
        var leaf: Data
        var leafKey: Data
        var hosts: [String]
        var created: Date
        /// How long the leaf was issued for, in days. Absent on material made
        /// before the lifetime was capped; that material is regenerated.
        var leafDays: Int?
    }

    /// iOS rejects a TLS server certificate valid for more than 825 days, user-
    /// installed roots included (Apple HT210176). Stay well inside it.
    static let leafDays = 800
    /// Renew this long before the leaf expires. The authority's key is gone, so
    /// renewing means a new authority and the person installing it again.
    static let renewalWindowDays = 30

    private(set) var material: Material?

    /// What the person installs.
    var authorityCertificate: Data? { material?.authority }

    private var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Intercept", isDirectory: true)
            .appendingPathComponent("identity.json")
    }

    private init() {
        material = Self.read(fileURL)
        refreshTrust()
    }

    // MARK: - Lifecycle

    /// Creates the certificates if there are none, or if the ones there are for a
    /// different host list or about to expire.
    func ensureCreated() throws {
        if let material,
           material.hosts == InterceptConfig.hosts,
           material.leafDays == Self.leafDays,
           material.created.addingTimeInterval(TimeInterval(Self.leafDays - Self.renewalWindowDays) * 86_400) > Date() {
            return
        }
        try regenerate()
    }

    /// New certificates. Anything installed from the previous set stops
    /// matching, so the person has to install the new authority.
    func regenerate() throws {
        let authorityKey = try Self.makeKey()
        let leafKey = try Self.makeKey()
        let authorityPoint = try Self.publicPoint(authorityKey)
        let leafPoint = try Self.publicPoint(leafKey)

        let hosts = InterceptConfig.hosts
        let now = Date()
        let notBefore = now.addingTimeInterval(-86_400)
        let authorityID = Self.keyID(authorityPoint)
        let tag = authorityID.prefix(2).map { String(format: "%02X", $0) }.joined()
        let authorityName = "\(InterceptConfig.authorityName) \(tag)"

        let sign: ([UInt8]) throws -> [UInt8] = { tbs in
            var error: Unmanaged<CFError>?
            guard let signature = SecKeyCreateSignature(
                authorityKey, .ecdsaSignatureMessageX962SHA256, Data(tbs) as CFData, &error
            ) else { throw error!.takeRetainedValue() }
            return [UInt8](signature as Data)
        }

        let authority = try X509Builder.certificate(
            role: .authority(permittedDNS: hosts),
            serial: Self.randomSerial(),
            subjectCN: authorityName,
            issuerCN: authorityName,
            notBefore: notBefore,
            notAfter: now.addingTimeInterval(TimeInterval(Self.leafDays + 60) * 86_400),
            subjectPublicKey: authorityPoint,
            subjectKeyID: authorityID,
            authorityKeyID: nil,
            sign: sign
        )
        let leaf = try X509Builder.certificate(
            role: .server(dnsNames: hosts),
            serial: Self.randomSerial(),
            subjectCN: "Locus Location Host",
            issuerCN: authorityName,
            notBefore: notBefore,
            notAfter: now.addingTimeInterval(TimeInterval(Self.leafDays) * 86_400),
            subjectPublicKey: leafPoint,
            subjectKeyID: Self.keyID(leafPoint),
            authorityKeyID: authorityID,
            sign: sign
        )

        var error: Unmanaged<CFError>?
        guard let leafPrivate = SecKeyCopyExternalRepresentation(leafKey, &error) else {
            throw error!.takeRetainedValue()
        }

        let created = Material(authority: authority, leaf: leaf, leafKey: leafPrivate as Data, hosts: hosts, created: now, leafDays: Self.leafDays)
        try Self.write(created, to: fileURL)
        material = created
        refreshTrust()
        // `authorityKey` leaves scope here, and nothing kept a reference to it.
    }

    func reset() {
        try? FileManager.default.removeItem(at: fileURL)
        material = nil
        refreshTrust()
    }

    /// Whether iOS would accept the leaf — which it does only once the authority
    /// is both installed and enabled under Certificate Trust Settings.
    func refreshTrust() {
        guard let material,
              let authority = SecCertificateCreateWithData(nil, material.authority as CFData),
              let leaf = SecCertificateCreateWithData(nil, material.leaf as CFData) else {
            trust = .notCreated
            trustFailure = nil
            return
        }
        var evaluation: SecTrust?
        SecTrustCreateWithCertificates(
            [leaf, authority] as CFArray,
            SecPolicyCreateSSL(true, InterceptConfig.hosts[0] as CFString),
            &evaluation
        )
        var failure: CFError?
        if let evaluation, SecTrustEvaluateWithError(evaluation, &failure) {
            trust = .trusted
            trustFailure = nil
        } else {
            trust = .notTrusted
            trustFailure = failure.map { "\(CFErrorCopyDescription($0) as String) (\(CFErrorGetCode($0)))" }
        }
    }

    // MARK: - Keys

    private nonisolated static func makeKey() throws -> SecKey {
        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
        ]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw error!.takeRetainedValue()
        }
        return key
    }

    private nonisolated static func publicPoint(_ key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let publicKey = SecKeyCopyPublicKey(key),
              let data = SecKeyCopyExternalRepresentation(publicKey, &error) else {
            let cause: Error = error?.takeRetainedValue() ?? X509Builder.Failure(description: "no public key")
            throw cause
        }
        return data as Data
    }

    private nonisolated static func keyID(_ point: Data) -> [UInt8] {
        Array(Insecure.SHA1.hash(data: point))
    }

    private nonisolated static func randomSerial() -> [UInt8] {
        var bytes = (0..<16).map { _ in UInt8.random(in: 0...255) }
        bytes[0] = max(bytes[0] & 0x7F, 1)
        return bytes
    }

    // MARK: - Storage

    private nonisolated static func read(_ url: URL) -> Material? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Material.self, from: data)
    }

    private nonisolated static func write(_ material: Material, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(material).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
