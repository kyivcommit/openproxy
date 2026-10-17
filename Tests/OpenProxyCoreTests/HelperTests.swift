import Foundation
import Testing

@testable import OpenProxyCore

@Suite("HelperRegistration")
struct HelperRegistrationTests {
    @Test func statusLabelsReadAsAMenuLine() {
        #expect(HelperStatus.enabled.label == "enabled")
        #expect(HelperStatus.notRegistered.label == "not installed")
        #expect(HelperStatus.requiresApproval.label == "needs approval in System Settings")
        #expect(HelperStatus.notFound.label.contains("missing"))
        #expect(!HelperStatus.unknown.label.isEmpty)
    }

    @Test func machServiceNameMatchesThePlistContract() {
        // The app connects to this name; Resources/dev.openproxy.helper.plist must advertise it.
        #expect(HelperConstants.machServiceName == "dev.openproxy.helper")
    }

    @Test func requirementPinsTheIdentifier() throws {
        #expect(try HelperConstants.requirement(forAppIdentifier: "dev.openproxy.app") == "identifier \"dev.openproxy.app\"")
    }

    @Test func requirementPinsTheTeamIdentifierForSignedBuilds() throws {
        #expect(try HelperConstants.requirement(
            forAppIdentifier: "dev.openproxy.app", teamIdentifier: "ABCDE12345")
            == "identifier \"dev.openproxy.app\" and anchor apple generic and certificate leaf[subject.OU] = \"ABCDE12345\"")
    }

    @Test func requirementRejectsAnInvalidTeamIdentifier() {
        for bad in ["", "short", "ABCDE1234", "ABCDE123456", "ABCDE-2345", "ABCDE1234;", "ABCDE 2345"] {
            #expect(throws: HelperConstants.RequirementError.invalidTeamIdentifier) {
                try HelperConstants.requirement(forAppIdentifier: "dev.openproxy.app", teamIdentifier: bad)
            }
        }
    }

    @Test func requirementWithoutATeamIdentifierStaysIdentifierOnly() throws {
        #expect(try HelperConstants.requirement(
            forAppIdentifier: "dev.openproxy.app", teamIdentifier: nil)
            == "identifier \"dev.openproxy.app\"")
    }

    @Test func requirementEscapesQuotesAndBackslashes() throws {
        #expect(try HelperConstants.requirement(forAppIdentifier: "a\"b\\c") == "identifier \"a\\\"b\\\\c\"")
    }

    @Test func requirementRejectsAnEmptyIdentifier() {
        #expect(throws: HelperConstants.RequirementError.emptyIdentifier) {
            try HelperConstants.requirement(forAppIdentifier: "")
        }
    }

    @Test func defaultConnectionRequirementMatchesTheDefaultIdentifier() throws {
        #expect(HelperConstants.connectionRequirement == (try HelperConstants.requirement(forAppIdentifier: "dev.openproxy.app")))
    }
}
