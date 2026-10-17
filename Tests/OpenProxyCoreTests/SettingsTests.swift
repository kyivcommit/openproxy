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
        #expect(settings.pollMinutes == 10)
    }

    @Test func smartPriceIsASortMode() {
        #expect(SortMode.allCases.contains(.smartPrice))
        #expect(SortMode.smartPrice.rawValue == "smartPrice")
        #expect(SortMode.smartPrice.displayName == "Smart price")
    }

    @Test func pollMinutesClamped() {
        var settings = Settings()
        settings.pollMinutes = 0
        #expect(settings.pollMinutes == 1)
        settings.pollMinutes = 90
        #expect(settings.pollMinutes == 60)
        settings.pollMinutes = 15
        #expect(settings.pollMinutes == 15)
    }

    @Test func decodedPollMinutesAreClamped() throws {
        let low = try JSONDecoder().decode(Settings.self, from: Data(#"{"pollMinutes":0}"#.utf8))
        #expect(low.pollMinutes == 1)
        let high = try JSONDecoder().decode(Settings.self, from: Data(#"{"pollMinutes":900}"#.utf8))
        #expect(high.pollMinutes == 60)
    }

    @Test func decodedSettingsTolerateMissingKeys() throws {
        // An older settings.json has no pollMinutes (and may predate flex).
        let settings = try JSONDecoder().decode(Settings.self, from: Data(#"{"sort":"price"}"#.utf8))
        #expect(settings.pollMinutes == 10)
        #expect(settings.sort == .price)
        #expect(settings == Settings(enabled: true, sort: .price, tier: .auto, flex: FlexPolicy(), pollMinutes: 10))
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

    @Test func decodedAttemptsAreClamped() throws {
        let low = try JSONDecoder().decode(FlexPolicy.self, from: Data(#"{"attempts":0}"#.utf8))
        #expect(low.attempts == 1)
        let high = try JSONDecoder().decode(FlexPolicy.self, from: Data(#"{"attempts":9}"#.utf8))
        #expect(high.attempts == 5)
    }

    @Test func decodedPolicyToleratesMissingKeys() throws {
        let policy = try JSONDecoder().decode(FlexPolicy.self, from: Data("{}".utf8))
        #expect(policy == FlexPolicy())
    }

    @Test func roundTripThroughFile() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = SettingsStore(url: url)
        var settings = Settings()
        settings.sort = .throughput
        settings.tier = .flex
        settings.flex.attempts = 4
        settings.pollMinutes = 30
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

    @Test func setupCompleteDefaultsOffAndRoundTrips() throws {
        // A fresh install has not been set up yet; only a successful automatic setup sets it.
        #expect(Settings().setupComplete == false)

        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SettingsStore(url: url)
        var settings = Settings()
        settings.setupComplete = true
        store.settings = settings
        try store.save()
        #expect(SettingsStore(url: url).settings.setupComplete)
    }

    @Test func decodedSettingsTolerateMissingSetupCompleteAndOldRouteOnLaunch() throws {
        // An older settings.json predates setupComplete and may still carry routeOnLaunch;
        // both must decode without failing, defaulting setupComplete off.
        let settings = try JSONDecoder().decode(
            Settings.self, from: Data(#"{"sort":"price","routeOnLaunch":true}"#.utf8))
        #expect(settings.setupComplete == false)
        #expect(settings.sort == .price)
    }

    @Test func tierAvailabilityFields() {
        let availability = TierAvailability(hasFlex: true, hasPriority: false)
        #expect(availability.hasFlex)
        #expect(!availability.hasPriority)
    }
}
