import Foundation
import Testing

@testable import OpenProxyCore

@Suite("HelperRequirement")
struct HelperRequirementTests {
    @Test func resolvesTheAppBundleFromTheHelperExecutablePath() {
        let executable = URL(fileURLWithPath: "/Applications/OpenProxy.app/Contents/MacOS/OpenProxyHelper")
        #expect(HelperRequirement.appBundleURL(forExecutableURL: executable)?.path == "/Applications/OpenProxy.app")
    }

    @Test func resolvesNestedAppBundles() {
        let executable = URL(fileURLWithPath: "/Users/me/build/Test.app/Contents/MacOS/OpenProxyHelper")
        #expect(HelperRequirement.appBundleURL(forExecutableURL: executable)?.path == "/Users/me/build/Test.app")
    }

    @Test func rejectsAFlatExecutablePath() {
        let executable = URL(fileURLWithPath: "/tmp/OpenProxyHelper")
        #expect(HelperRequirement.appBundleURL(forExecutableURL: executable) == nil)
    }

    @Test func rejectsContentsThatAreNotAnAppBundle() {
        let executable = URL(fileURLWithPath: "/tmp/Contents/MacOS/OpenProxyHelper")
        #expect(HelperRequirement.appBundleURL(forExecutableURL: executable) == nil)
    }

    @Test func signingInfoReadFailsWithoutAnAppBundle() {
        let info = HelperRequirement.appSigningInfo(forExecutableURL: URL(fileURLWithPath: "/tmp/OpenProxyHelper"))
        #expect(info.readFailed)
        #expect(info.identifier == nil)
        #expect(info.teamIdentifier == nil)
        #expect(info.isAdhoc == false)
    }

    // MARK: - Fail-closed decision

    @Test func adHocSignatureGetsAnIdentifierOnlyRequirement() {
        let decision = HelperRequirement.decision(
            identifier: "dev.openproxy.app", teamIdentifier: nil, isAdhoc: true, readFailed: false)
        #expect(decision == .requirement("identifier \"dev.openproxy.app\""))
    }

    @Test func signedSignaturePinsTheTeamIdentifier() {
        let decision = HelperRequirement.decision(
            identifier: "dev.openproxy.app", teamIdentifier: "ABCDE12345", isAdhoc: false, readFailed: false)
        #expect(decision == .requirement(
            "identifier \"dev.openproxy.app\" and anchor apple generic "
                + "and certificate leaf[subject.OU] = \"ABCDE12345\""))
    }

    @Test func signedSignatureWithoutATeamIdentifierIsRefused() {
        // Not ad-hoc means a real signature; being unable to pin its Team ID must fail closed
        // instead of falling back to an identifier a local process could re-sign itself with.
        let decision = HelperRequirement.decision(
            identifier: "dev.openproxy.app", teamIdentifier: nil, isAdhoc: false, readFailed: false)
        #expect(decision == .refusal("the signature is not ad-hoc but has no Team ID"))
    }

    @Test func signedSignatureWithAnInvalidTeamIdentifierIsRefused() {
        for bad in ["", "short", "ABCDE-2345"] {
            let decision = HelperRequirement.decision(
                identifier: "dev.openproxy.app", teamIdentifier: bad, isAdhoc: false, readFailed: false)
            #expect(decision == .refusal("the signature's Team ID is not a valid Team ID"))
        }
    }

    @Test func unreadableSigningInfoIsRefused() {
        // Even a fully populated input tuple must not yield a requirement when the read failed.
        for adhoc in [true, false] {
            let decision = HelperRequirement.decision(
                identifier: "dev.openproxy.app", teamIdentifier: "ABCDE12345", isAdhoc: adhoc, readFailed: true)
            #expect(decision == .refusal("the parent app's signing information could not be read"))
        }
    }

    @Test func adHocSignatureWithoutAnIdentifierIsRefused() {
        for identifier in [nil, ""] {
            let decision = HelperRequirement.decision(
                identifier: identifier, teamIdentifier: nil, isAdhoc: true, readFailed: false)
            #expect(decision == .refusal("the parent app's signing information could not be read"))
        }
    }

    @Test func decisionEscapesACraftedIdentifier() {
        let decision = HelperRequirement.decision(
            identifier: "a\"b\\c", teamIdentifier: nil, isAdhoc: true, readFailed: false)
        #expect(decision == .requirement("identifier \"a\\\"b\\\\c\""))
    }
}
