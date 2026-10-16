import Foundation
import Testing

@testable import OpenProxyCore

@Suite("Settings")
struct SettingsTests {
    @Test func defaultsMatchSpec() {
        let settings = Settings()
        #expect(settings.enabled)
        #expect(settings.sort == .balanced)
        #expect(settings.tier == .auto)
        #expect(settings.flex.fallback)
        #expect(settings.flex.attempts == 2)
        #expect(settings.flex.firstByteTimeout == 30)
        #expect(settings.flex.nonStreamingTimeout == 120)
    }

    @Test func attemptsClamped() {
        var policy = FlexPolicy()
        policy.attempts = 0
        #expect(policy.attempts == 1)
        policy.attempts = 9
        #expect(policy.attempts == 5)
        policy.attempts = 3
        #expect(policy.attempts == 3)
    }

    @Test func roundTripThroughFile() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = SettingsStore(url: url)
        var settings = Settings()
        settings.sort = .throughput
        settings.tier = .flex
        settings.flex.attempts = 4
        store.settings = settings
        try store.save()

        #expect(SettingsStore(url: url).settings == settings)
    }

    @Test func corruptFileYieldsDefaults() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)

        #expect(SettingsStore(url: url).settings == Settings())
    }

    @Test func tierAvailabilityFields() {
        let availability = TierAvailability(hasFlex: true, hasPriority: false)
        #expect(availability.hasFlex)
        #expect(!availability.hasPriority)
    }
}
