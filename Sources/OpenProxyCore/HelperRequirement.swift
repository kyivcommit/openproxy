import Foundation
import Security

/// Resolves the parent app's code-signing identifier from the helper's own executable path.
/// The helper ships as `<App>.app/Contents/MacOS/OpenProxyHelper`, so the app bundle is three
/// directories up. Anything else (a bare SwiftPM binary, a moved executable) resolves to nil and
/// the caller falls back to `HelperConstants.connectionRequirement`.
public enum HelperRequirement {
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

    /// Reads both the signing identifier and the Team Identifier from one
    /// `SecCodeCopySigningInformation` call. A nil Team Identifier means the build is ad-hoc.
    public static func appSigningInfo(
        forExecutableURL executable: URL
    ) -> (identifier: String?, teamIdentifier: String?) {
        guard let bundle = appBundleURL(forExecutableURL: executable) else { return (nil, nil) }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode
        else { return (nil, nil) }
        var signingInfo: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &signingInfo) == errSecSuccess,
              let signingInfo = signingInfo as? [String: Any]
        else { return (nil, nil) }
        let identifier = (signingInfo[kSecCodeInfoIdentifier as String] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
        let teamIdentifier = (signingInfo[kSecCodeInfoTeamIdentifier as String] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
        return (identifier, teamIdentifier)
    }
}
