import Foundation
import ServiceManagement
import Testing

@testable import OpenProxyCore

@Suite("LegacyServiceCleanup")
struct LegacyServiceCleanupTests {
    @Test func notRegisteredIsConfirmedAbsentWithoutUnregistering() {
        var unregistered = false
        let failure = SMAppServiceLegacyCleanup.remove(
            name: "dev.openproxy.helper legacy daemon",
            status: { .notRegistered },
            unregister: { unregistered = true })
        #expect(failure == nil)
        #expect(!unregistered)
    }

    @Test func notFoundFailsWithoutUnregistering() {
        // A missing plist is not proof that the service is gone.
        var unregistered = false
        let failure = SMAppServiceLegacyCleanup.remove(
            name: "dev.openproxy.helper legacy daemon",
            status: { .notFound },
            unregister: { unregistered = true })
        #expect(failure?.contains("missing from the bundle") == true)
        #expect(failure?.contains("dev.openproxy.helper") == true)
        #expect(!unregistered)
    }

    @Test func enabledUnregistersAndConfirmsAbsence() {
        var status = SMAppService.Status.enabled
        var unregistered = false
        let failure = SMAppServiceLegacyCleanup.remove(
            name: "dev.openproxy.helper legacy daemon",
            status: { status },
            unregister: {
                unregistered = true
                status = .notRegistered
            })
        #expect(failure == nil)
        #expect(unregistered)
    }

    @Test func genericUnregisterErrorIsReported() {
        let failure = SMAppServiceLegacyCleanup.remove(
            name: "dev.openproxy.helper legacy daemon",
            status: { .enabled },
            unregister: { throw NSError(domain: "SMAppServiceErrorDomain", code: 1) })
        #expect(failure?.contains("could not be unregistered") == true)
        #expect(failure?.contains("dev.openproxy.helper") == true)
    }

    @Test func jobNotFoundErrorMeansAlreadyAbsent() {
        let failure = SMAppServiceLegacyCleanup.remove(
            name: "dev.openproxy.helper legacy daemon",
            status: { .enabled },
            unregister: { throw NSError(domain: "SMAppServiceErrorDomain", code: 113) })
        #expect(failure == nil)
    }

    @Test func stillRegisteredAfterUnregisterIsReported() {
        let failure = SMAppServiceLegacyCleanup.remove(
            name: "dev.openproxy.helper legacy daemon",
            status: { .enabled },
            unregister: {})
        #expect(failure?.contains("still registered after unregister") == true)
        #expect(failure?.contains("dev.openproxy.helper") == true)
    }
}
