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
