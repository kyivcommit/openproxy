import Foundation
import Security

/// Resolves the parent app's code-signing identity from the helper's own executable path.
/// The helper ships as `<App>.app/Contents/MacOS/OpenProxyHelper`, so the app bundle is three
/// directories up. Anything else (a bare SwiftPM binary, a moved executable) resolves to a
/// failed read, and `decision` refuses to run rather than fall back to a requirement that
/// omits the Team ID.
public enum HelperRequirement {
    /// What could be read about the parent app's signature.
    public struct AppSigningInfo: Equatable, Sendable {
        public var identifier: String?
        public var teamIdentifier: String?
        /// True when the signature carries `SecCodeSignatureFlags.adhoc`: a dev/ad-hoc build,
        /// where macOS gives the helper no Team ID to pin.
        public var isAdhoc: Bool
        /// True when the app bundle or its signing information could not be read at all.
        public var readFailed: Bool

        public static let unreadable = AppSigningInfo(
            identifier: nil, teamIdentifier: nil, isAdhoc: false, readFailed: true)
    }

    /// The requirement to set on the XPC listener, or the reason the helper must not listen.
    public enum RequirementDecision: Equatable, Sendable {
        case requirement(String)
        case refusal(String)
    }

    /// Fail closed: the helper only listens with a requirement it could build from a real
    /// signature read. An ad-hoc build pins the bundle identifier alone (that is all macOS
    /// gives it); anything else must pin the Team ID, and a missing or unreadable one refuses.
    public static func decision(
        identifier: String?,
        teamIdentifier: String?,
        isAdhoc: Bool,
        readFailed: Bool
    ) -> RequirementDecision {
        let identifier = identifier.flatMap { $0.isEmpty ? nil : $0 }
        guard !readFailed, let identifier else {
            return .refusal("the parent app's signing information could not be read")
        }
        if isAdhoc {
            return (try? HelperConstants.requirement(forAppIdentifier: identifier))
                .map(RequirementDecision.requirement)
                ?? .refusal("the parent app's signing identifier is not usable")
        }
        guard let teamIdentifier else {
            return .refusal("the signature is not ad-hoc but has no Team ID")
        }
        do {
            return .requirement(try HelperConstants.requirement(
                forAppIdentifier: identifier, teamIdentifier: teamIdentifier))
        } catch {
            return .refusal("the signature's Team ID is not a valid Team ID")
        }
    }

    /// Walks `.../Foo.app/Contents/MacOS/Foo` up to `.../Foo.app`; nil when the layout is not an app.
    public static func appBundleURL(forExecutableURL executable: URL) -> URL? {
        let bundle = executable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard bundle.pathExtension == "app" else { return nil }
        return bundle
    }

    /// The app bundle's signing identifier, or nil when the bundle is unsigned or unreadable.
    public static func appIdentifier(forExecutableURL executable: URL) -> String? {
        appSigningInfo(forExecutableURL: executable).identifier
    }

    /// The app bundle's Team Identifier, or nil for an ad-hoc/unsigned build.
    public static func appTeamIdentifier(forExecutableURL executable: URL) -> String? {
        appSigningInfo(forExecutableURL: executable).teamIdentifier
    }

    /// Reads the signing identifier, the Team Identifier and `kSecCodeInfoFlags` (for the
    /// ad-hoc bit) from one `SecCodeCopySigningInformation` call.
    public static func appSigningInfo(forExecutableURL executable: URL) -> AppSigningInfo {
        guard let bundle = appBundleURL(forExecutableURL: executable) else { return .unreadable }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode
        else { return .unreadable }
        var signingInfo: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &signingInfo) == errSecSuccess,
              let signingInfo = signingInfo as? [String: Any]
        else { return .unreadable }
        let identifier = (signingInfo[kSecCodeInfoIdentifier as String] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
        let teamIdentifier = (signingInfo[kSecCodeInfoTeamIdentifier as String] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
        let codeFlags = (signingInfo[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        return AppSigningInfo(
            identifier: identifier,
            teamIdentifier: teamIdentifier,
            isAdhoc: SecCodeSignatureFlags(rawValue: codeFlags).contains(.adhoc),
            readFailed: false)
    }
}
