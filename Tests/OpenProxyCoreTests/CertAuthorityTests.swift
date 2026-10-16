import Foundation
import Testing
import X509
import Crypto
import SwiftASN1

@testable import OpenProxyCore

/// Prefer a full OpenSSL (handles name constraints, prints "OK"); fall back to system LibreSSL.
/// `nil` means openssl is absent and the openssl test is skipped.
let opensslPath: String? = ["/opt/homebrew/bin/openssl", "/usr/local/bin/openssl", "/usr/bin/openssl"]
    .first { FileManager.default.isExecutableFile(atPath: $0) }

@Suite("CertAuthority")
struct CertAuthorityTests {
    @Test func keyFileMode600() throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let authority = CertAuthority(directory: directory)
        try authority.loadOrCreate()

        let key = directory.appending(path: "ca.key")
        let attributes = try FileManager.default.attributesOfItem(atPath: key.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(FileManager.default.fileExists(atPath: authority.caCertificatePEMURL.path))
    }

    @Test func loadTightensLooseKeyPermissions() throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let authority = CertAuthority(directory: directory)
        try authority.loadOrCreate()

        let key = directory.appending(path: "ca.key")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: key.path)

        let reloaded = CertAuthority(directory: directory)
        try reloaded.loadOrCreate()

        let mode = (try FileManager.default.attributesOfItem(atPath: key.path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o600)
    }

    @Test func leafVerifiesAgainstCAForOpenrouter() async throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let authority = CertAuthority(directory: directory)
        try authority.loadOrCreate()
        let leaf = try authority.leaf()

        let ca = try Certificate(pemEncoded: String(contentsOf: authority.caCertificatePEMURL))
        let leafCertificate = try Certificate(pemEncoded: leaf.certificatePEM)

        var verifier = Verifier(rootCertificates: CertificateStore([ca])) {
            RFC5280Policy()
            ServerIdentityPolicy(serverHostname: "openrouter.ai", serverIP: nil)
        }
        let result = await verifier.validate(leaf: leafCertificate, intermediates: CertificateStore())
        guard case .validCertificate = result else {
            Issue.record("openrouter.ai leaf did not verify against its CA (hostname or name constraint failure)")
            return
        }
    }

    @Test func leafForOtherHostRejected() async throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let authority = CertAuthority(directory: directory)
        try authority.loadOrCreate()

        let ca = try Certificate(pemEncoded: String(contentsOf: authority.caCertificatePEMURL))
        let caKey = try Certificate.PrivateKey(pemEncoded: String(contentsOf: directory.appending(path: "ca.key")))
        let other = try Self.makeLeaf(hostname: "example.com", issuer: ca, issuerKey: caKey)

        var verifier = Verifier(rootCertificates: CertificateStore([ca])) {
            RFC5280Policy()
        }
        let result = await verifier.validate(leaf: other, intermediates: CertificateStore())
        if case .validCertificate = result {
            Issue.record("a leaf for example.com must be rejected by the CA name constraint")
        }
    }

    @Test func leafWithIPSANRejectedBySwiftVerifier() async throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let authority = CertAuthority(directory: directory)
        try authority.loadOrCreate()

        let ca = try Certificate(pemEncoded: String(contentsOf: authority.caCertificatePEMURL))
        let caKey = try Certificate.PrivateKey(pemEncoded: String(contentsOf: directory.appending(path: "ca.key")))
        // A stolen ca.key used to be able to mint an IP-SAN leaf the DNS-only constraint let through.
        let ipLeaf = try Self.makeLeaf(
            san: .ipAddress(ASN1OctetString(contentBytes: [1, 2, 3, 4])), issuer: ca, issuerKey: caKey)

        var verifier = Verifier(rootCertificates: CertificateStore([ca])) {
            RFC5280Policy()
        }
        let result = await verifier.validate(leaf: ipLeaf, intermediates: CertificateStore())
        if case .validCertificate = result {
            Issue.record("a leaf with an IP SAN must be rejected by the CA's excluded IP name constraint")
        }
    }

    @Test(.enabled(if: opensslPath != nil))
    func leafWithIPSANRejectedByOpenssl() throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let authority = CertAuthority(directory: directory)
        try authority.loadOrCreate()
        let ca = try Certificate(pemEncoded: String(contentsOf: authority.caCertificatePEMURL))
        let caKey = try Certificate.PrivateKey(pemEncoded: String(contentsOf: directory.appending(path: "ca.key")))
        let ipLeaf = try Self.makeLeaf(
            san: .ipAddress(ASN1OctetString(contentBytes: [1, 2, 3, 4])), issuer: ca, issuerKey: caKey)
        let leafURL = directory.appending(path: "ip-leaf.pem")
        try ipLeaf.serializeAsPEM().pemString.write(to: leafURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: opensslPath!)
        process.arguments = ["verify", "-CAfile", authority.caCertificatePEMURL.path, leafURL.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let log = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus != 0, "openssl accepted an IP-SAN leaf: \(log)")
    }

    @Test func regeneratesNearExpiry() throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let authority = CertAuthority(directory: directory)
        try authority.loadOrCreate()

        let day0 = Date()
        let first = try authority.leaf(now: day0)
        let cached = try authority.leaf(now: day0.addingTimeInterval(30 * 86_400))
        #expect(first.certificatePEM == cached.certificatePEM)

        let regenerated = try authority.leaf(now: day0.addingTimeInterval(61 * 86_400))
        #expect(regenerated.certificatePEM != first.certificatePEM)
    }

    @Test func reloadKeepsSameCA() throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = CertAuthority(directory: directory)
        try first.loadOrCreate()
        let firstPEM = try String(contentsOf: first.caCertificatePEMURL)

        let second = CertAuthority(directory: directory)
        try second.loadOrCreate()
        let secondPEM = try String(contentsOf: second.caCertificatePEMURL)

        #expect(firstPEM == secondPEM)
    }

    @Test func commonNameMatchesInstallerContract() throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let authority = CertAuthority(directory: directory)
        try authority.loadOrCreate()
        let ca = try Certificate(pemEncoded: String(contentsOf: authority.caCertificatePEMURL))
        // Task 8 finds/removes the trusted cert by this exact common name.
        #expect(ca.subject == (try DistinguishedName { CommonName("OpenProxy Local CA") }))
    }

    @Test(.enabled(if: opensslPath != nil))
    func opensslVerifiesLeaf() throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let authority = CertAuthority(directory: directory)
        try authority.loadOrCreate()
        let leaf = try authority.leaf()
        let leafURL = directory.appending(path: "leaf.pem")
        try leaf.certificatePEM.write(to: leafURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: opensslPath!)
        process.arguments = ["verify", "-CAfile", authority.caCertificatePEMURL.path, leafURL.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let log = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0, "openssl verify failed: \(log)")
    }

    // MARK: - Helpers

    static func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "openproxy-ca-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Builds a leaf with the given SAN, signed by the CA, so tests can probe the name constraint.
    static func makeLeaf(hostname: String, issuer: Certificate, issuerKey: Certificate.PrivateKey) throws -> Certificate {
        let key = P256.Signing.PrivateKey()
        let now = Date()
        return try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: Certificate.PublicKey(key.publicKey),
            notValidBefore: now.addingTimeInterval(-60),
            notValidAfter: now.addingTimeInterval(90 * 86_400),
            issuer: issuer.subject,
            subject: try DistinguishedName { CommonName(hostname) },
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions {
                BasicConstraints.notCertificateAuthority
                KeyUsage(digitalSignature: true)
                SubjectAlternativeNames([.dnsName(hostname)])
                try ExtendedKeyUsage([.serverAuth])
            },
            issuerPrivateKey: issuerKey
        )
    }

    /// Builds a leaf with a single SAN of the caller's choosing, signed by the CA, so tests
    /// can probe the name constraint (DNS and IP forms).
    static func makeLeaf(san: GeneralName, issuer: Certificate, issuerKey: Certificate.PrivateKey) throws -> Certificate {
        let key = P256.Signing.PrivateKey()
        let now = Date()
        return try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: Certificate.PublicKey(key.publicKey),
            notValidBefore: now.addingTimeInterval(-60),
            notValidAfter: now.addingTimeInterval(90 * 86_400),
            issuer: issuer.subject,
            subject: try DistinguishedName { CommonName("openproxy-leaf") },
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions {
                BasicConstraints.notCertificateAuthority
                KeyUsage(digitalSignature: true)
                SubjectAlternativeNames([san])
                try ExtendedKeyUsage([.serverAuth])
            },
            issuerPrivateKey: issuerKey
        )
    }
}
