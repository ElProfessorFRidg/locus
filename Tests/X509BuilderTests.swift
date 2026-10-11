import XCTest
#if canImport(Security)
import Security
#endif

final class X509BuilderTests: XCTestCase {
    func testDERLengths() {
        XCTAssertEqual(DER.length(5), [5])
        XCTAssertEqual(DER.length(127), [127])
        XCTAssertEqual(DER.length(128), [0x81, 128])
        XCTAssertEqual(DER.length(300), [0x82, 0x01, 0x2C])
    }

    func testDEROIDs() {
        XCTAssertEqual(DER.oid("2.5.4.3"), [0x06, 0x03, 0x55, 0x04, 0x03])
        XCTAssertEqual(DER.oid("1.2.840.10045.4.3.2"), [0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02])
    }

    func testDERIntegersStayPositive() {
        XCTAssertEqual(DER.integer([0x80]), [0x02, 0x02, 0x00, 0x80])
        XCTAssertEqual(DER.integer([0x00, 0x00, 0x7F]), [0x02, 0x01, 0x7F])
        XCTAssertEqual(DER.integer([]), [0x02, 0x01, 0x00])
    }

    func testDERTimes() {
        XCTAssertEqual(String(decoding: DER.time(Date(timeIntervalSince1970: 1_700_000_000)).dropFirst(2), as: UTF8.self), "231114221320Z")
        XCTAssertEqual(DER.time(Date(timeIntervalSince1970: 1_700_000_000))[0], 0x17)
        XCTAssertEqual(DER.time(Date(timeIntervalSince1970: 4_000_000_000))[0], 0x18)
    }

    #if canImport(Security)
    /// The real test: iOS has to accept the chain. A certificate that parses but
    /// fails name-constraint or key-usage checks would only show itself on a
    /// phone, as "the spoof doesn't work", so build both and let Security judge.
    func testLeafChainsToAuthorityAndIsConstrainedToTheLocationHosts() throws {
        let authority = try makeKey()
        let leaf = try makeKey()
        let hosts = InterceptConfig.hosts
        let now = Date()

        func signer(_ key: SecKey) -> ([UInt8]) throws -> [UInt8] {
            { tbs in
                var error: Unmanaged<CFError>?
                guard let sig = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, Data(tbs) as CFData, &error) else {
                    throw error!.takeRetainedValue()
                }
                return [UInt8](sig as Data)
            }
        }

        let caDER = try X509Builder.certificate(
            role: .authority(permittedDNS: hosts), serial: [1, 2, 3, 4], subjectCN: "Test Authority", issuerCN: "Test Authority",
            notBefore: now.addingTimeInterval(-60), notAfter: now.addingTimeInterval(86_400),
            subjectPublicKey: try publicPoint(authority), subjectKeyID: [1, 1, 1, 1], authorityKeyID: nil,
            sign: signer(authority))
        let leafDER = try X509Builder.certificate(
            role: .server(dnsNames: hosts), serial: [9, 9, 9, 9], subjectCN: "Test Leaf", issuerCN: "Test Authority",
            notBefore: now.addingTimeInterval(-60), notAfter: now.addingTimeInterval(86_400),
            subjectPublicKey: try publicPoint(leaf), subjectKeyID: [2, 2, 2, 2], authorityKeyID: [1, 1, 1, 1],
            sign: signer(authority))

        let ca = try XCTUnwrap(SecCertificateCreateWithData(nil, caDER as CFData), "authority is not valid DER")
        let cert = try XCTUnwrap(SecCertificateCreateWithData(nil, leafDER as CFData), "leaf is not valid DER")

        func evaluate(_ host: String) -> Bool {
            var trust: SecTrust?
            SecTrustCreateWithCertificates([cert, ca] as CFArray, SecPolicyCreateSSL(true, host as CFString), &trust)
            guard let trust else { return false }
            SecTrustSetAnchorCertificates(trust, [ca] as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
            return SecTrustEvaluateWithError(trust, nil)
        }

        for host in hosts { XCTAssertTrue(evaluate(host), "\(host) should validate") }
        XCTAssertFalse(evaluate("example.com"), "leaf must not be valid for other names")
    }

    func testAuthorityCannotVouchForAnythingOutsideItsConstraint() throws {
        let authority = try makeKey()
        let leaf = try makeKey()
        let now = Date()
        func sign(_ tbs: [UInt8]) throws -> [UInt8] {
            var error: Unmanaged<CFError>?
            guard let sig = SecKeyCreateSignature(authority, .ecdsaSignatureMessageX962SHA256, Data(tbs) as CFData, &error) else {
                throw error!.takeRetainedValue()
            }
            return [UInt8](sig as Data)
        }
        let caDER = try X509Builder.certificate(
            role: .authority(permittedDNS: ["gs-loc.apple.com"]), serial: [1], subjectCN: "A", issuerCN: "A",
            notBefore: now.addingTimeInterval(-60), notAfter: now.addingTimeInterval(86_400),
            subjectPublicKey: try publicPoint(authority), subjectKeyID: [1], authorityKeyID: nil, sign: sign)
        let rogue = try X509Builder.certificate(
            role: .server(dnsNames: ["www.example.com"]), serial: [2], subjectCN: "Rogue", issuerCN: "A",
            notBefore: now.addingTimeInterval(-60), notAfter: now.addingTimeInterval(86_400),
            subjectPublicKey: try publicPoint(leaf), subjectKeyID: [2], authorityKeyID: [1], sign: sign)

        let ca = try XCTUnwrap(SecCertificateCreateWithData(nil, caDER as CFData))
        let cert = try XCTUnwrap(SecCertificateCreateWithData(nil, rogue as CFData))
        var trust: SecTrust?
        SecTrustCreateWithCertificates([cert, ca] as CFArray, SecPolicyCreateSSL(true, "www.example.com" as CFString), &trust)
        SecTrustSetAnchorCertificates(try XCTUnwrap(trust), [ca] as CFArray)
        SecTrustSetAnchorCertificatesOnly(try XCTUnwrap(trust), true)
        XCTAssertFalse(SecTrustEvaluateWithError(try XCTUnwrap(trust), nil), "name constraints must be enforced")
    }

    private func makeKey() throws -> SecKey {
        var error: Unmanaged<CFError>?
        let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits: 256]
        guard let key = SecKeyCreateRandomKey(attrs as CFDictionary, &error) else { throw error!.takeRetainedValue() }
        return key
    }

    private func publicPoint(_ key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let pub = SecKeyCopyPublicKey(key), let data = SecKeyCopyExternalRepresentation(pub, &error) else {
            throw error!.takeRetainedValue()
        }
        return data as Data
    }
    #endif
}
