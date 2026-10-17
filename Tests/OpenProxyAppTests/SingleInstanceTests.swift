import Foundation
import Testing

@testable import OpenProxyAppModel

private struct FakeInstances: RunningInstanceProviding {
    let pids: [Int32]
    func runningPIDs(bundleIdentifier: String) -> [Int32] { pids }
}

@Suite("SingleInstanceGuard")
struct SingleInstanceGuardTests {
    @Test func noOtherInstanceMeansRun() {
        #expect(!SingleInstanceGuard.shouldYield(otherPIDs: [], ownPID: 100))
    }

    @Test func anotherPIDMeansYield() {
        #expect(SingleInstanceGuard.shouldYield(otherPIDs: [200], ownPID: 100))
        #expect(SingleInstanceGuard.shouldYield(otherPIDs: [100, 200], ownPID: 100))
    }

    @Test func onlyOwnPIDMeansRun() {
        #expect(!SingleInstanceGuard.shouldYield(otherPIDs: [100], ownPID: 100))
        #expect(!SingleInstanceGuard.shouldYield(otherPIDs: [100, 100], ownPID: 100))
    }

    @Test func injectedProviderDrivesTheDecision() {
        let bundleID = "dev.openproxy.app"
        #expect(!SingleInstanceGuard.shouldYield(
            using: FakeInstances(pids: [100]), bundleIdentifier: bundleID, ownPID: 100))
        #expect(SingleInstanceGuard.shouldYield(
            using: FakeInstances(pids: [100, 200]), bundleIdentifier: bundleID, ownPID: 100))
    }
}
