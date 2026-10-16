import Foundation
import X509
import Crypto

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

    private let directory: URL
    private let lock = NSLock()
    private var caCertificate: Certificate?
    private var caPrivateKey: Certificate.PrivateKey?
    private var cachedLeaf: (certificate: Certificate, privateKey: Certificate.PrivateKey, notValidAfter: Date)?

    public init(directory: URL) {
        self.directory = directory
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
    public func leaf(now: Date = Date()) throws -> (certificatePEM: String, privateKeyPEM: String) {
        try lock.withLock {
            guard let caCertificate, let caPrivateKey else { throw Error.notLoaded }

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
                Critical(NameConstraints(permittedDNSDomains: [hostname]))
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
                SubjectAlternativeNames([.dnsName(hostname)])
                try ExtendedKeyUsage([.serverAuth])
            },
            issuerPrivateKey: caKey
        )
        return (certificate, privateKey)
    }

    private static func write(_ text: String, to url: URL, permissions: Int) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }
}
