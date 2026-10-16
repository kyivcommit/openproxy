import Foundation
import X509
import Crypto
import SwiftASN1

/// A local CA constrained to `openrouter.ai`, plus short-lived leaf certificates for it.
///
/// The CA private key is persisted at `<directory>/ca.key` with mode 600; the CA certificate at
/// `<directory>/ca.pem`. Leaves are cached in memory and reissued when within 30 days of expiry.
public final class CertAuthority: @unchecked Sendable {
    public enum Error: Swift.Error {
        case notLoaded
    }

    private static let hostname = "openrouter.ai"
    private static let commonName = "OpenProxy Local CA"
    private static let leafValidity: TimeInterval = 90 * 86_400
    private static let renewalWindow: TimeInterval = 30 * 86_400
    /// Forbid every IP SAN. Without these the `permitted DNS:openrouter.ai` constraint is
    /// bypassed by a leaf carrying an IP SAN; a stolen `ca.key` could then sign an IP leaf
    /// that Security.framework and OpenSSL both accept. The mask is the CIDR network mask,
    /// so an all-zero mask covers the whole address space (`0.0.0.0/0` and `::/0`).
    private static let excludedIPRanges: [ASN1OctetString] = [
        ASN1OctetString(contentBytes: [0, 0, 0, 0, 0, 0, 0, 0]),  // 0.0.0.0/0
        ASN1OctetString(contentBytes: ArraySlice([UInt8](repeating: 0, count: 32))),  // ::/0
    ]

    private let directory: URL
    private let clock: @Sendable () -> Date
    private let lock = NSLock()
    private var caCertificate: Certificate?
    private var caPrivateKey: Certificate.PrivateKey?
    private var cachedLeaf: (certificate: Certificate, privateKey: Certificate.PrivateKey, notValidAfter: Date)?

    public convenience init(directory: URL) {
        self.init(directory: directory, clock: Date.init)
    }

    /// `clock` is a test seam for exercising leaf renewal; production uses `Date.init`.
    init(directory: URL, clock: @escaping @Sendable () -> Date) {
        self.directory = directory
        self.clock = clock
    }

    /// PEM of the CA certificate; also the path written by `loadOrCreate`.
    public var caCertificatePEMURL: URL {
        directory.appending(path: "ca.pem")
    }

    private var caKeyURL: URL {
        directory.appending(path: "ca.key")
    }

    /// Loads an existing CA from `directory`, or generates and persists a new one.
    public func loadOrCreate() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: caCertificatePEMURL.path),
           FileManager.default.fileExists(atPath: caKeyURL.path) {
            // An older install may have left the key group/world-readable; tighten it on load.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: caKeyURL.path)
            let certificate = try Certificate(pemEncoded: String(contentsOf: caCertificatePEMURL))
            let key = try Certificate.PrivateKey(pemEncoded: String(contentsOf: caKeyURL))
            lock.withLock {
                caCertificate = certificate
                caPrivateKey = key
                cachedLeaf = nil
            }
            return
        }

        let (certificate, key) = try Self.makeCA(now: Date())
        try Self.write(try certificate.serializeAsPEM().pemString, to: caCertificatePEMURL, permissions: 0o644)
        try Self.write(try key.serializeAsPEM().pemString, to: caKeyURL, permissions: 0o600)
        lock.withLock {
            caCertificate = certificate
            caPrivateKey = key
            cachedLeaf = nil
        }
    }

    /// Returns the current leaf certificate and key, issuing a new one if none is cached or the
    /// cached one is within 30 days of expiry.
    public func leaf(now: Date? = nil) throws -> (certificatePEM: String, privateKeyPEM: String) {
        try lock.withLock {
            guard let caCertificate, let caPrivateKey else { throw Error.notLoaded }
            let now = now ?? clock()

            if let cached = cachedLeaf, now < cached.notValidAfter.addingTimeInterval(-Self.renewalWindow) {
                return (try cached.certificate.serializeAsPEM().pemString, try cached.privateKey.serializeAsPEM().pemString)
            }

            let (certificate, privateKey) = try Self.makeLeaf(ca: caCertificate, caKey: caPrivateKey, now: now)
            cachedLeaf = (certificate, privateKey, now.addingTimeInterval(Self.leafValidity))
            return (try certificate.serializeAsPEM().pemString, try privateKey.serializeAsPEM().pemString)
        }
    }

    // MARK: - Issuing

    private static func makeCA(now: Date) throws -> (Certificate, Certificate.PrivateKey) {
        let key = P256.Signing.PrivateKey()
        let privateKey = Certificate.PrivateKey(key)
        let name = try DistinguishedName { CommonName(commonName) }
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: Certificate.PublicKey(key.publicKey),
            notValidBefore: now.addingTimeInterval(-60),
            notValidAfter: now.addingTimeInterval(10 * 365 * 86_400),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
                Critical(KeyUsage(keyCertSign: true, cRLSign: true))
                SubjectKeyIdentifier(hash: Certificate.PublicKey(key.publicKey))
                Critical(NameConstraints(
                    permittedDNSDomains: [hostname],
                    excludedIPRanges: excludedIPRanges))
            },
            issuerPrivateKey: privateKey
        )
        return (certificate, privateKey)
    }

    private static func makeLeaf(
        ca: Certificate,
        caKey: Certificate.PrivateKey,
        now: Date
    ) throws -> (Certificate, Certificate.PrivateKey) {
        let key = P256.Signing.PrivateKey()
        let privateKey = Certificate.PrivateKey(key)
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: Certificate.PublicKey(key.publicKey),
            notValidBefore: now.addingTimeInterval(-60),
            notValidAfter: now.addingTimeInterval(leafValidity),
            issuer: ca.subject,
            subject: try DistinguishedName { CommonName(hostname) },
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions {
                BasicConstraints.notCertificateAuthority
                KeyUsage(digitalSignature: true)
                SubjectKeyIdentifier(hash: Certificate.PublicKey(key.publicKey))
                AuthorityKeyIdentifier(
                    keyIdentifier: SubjectKeyIdentifier(hash: ca.publicKey).keyIdentifier)
                SubjectAlternativeNames([.dnsName(hostname)])
                try ExtendedKeyUsage([.serverAuth])
            },
            issuerPrivateKey: caKey
        )
        return (certificate, privateKey)
    }

    private static func write(_ text: String, to url: URL, permissions: Int) throws {
        // Create with the target mode directly: writing first would briefly expose a 0600 key under the process umask.
        let created = FileManager.default.createFile(
            atPath: url.path,
            contents: Data(text.utf8),
            attributes: [.posixPermissions: permissions]
        )
        guard created else { throw CocoaError(.fileWriteUnknown) }
    }
}
