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
}
