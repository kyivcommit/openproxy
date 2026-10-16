import Foundation

public enum SortMode: String, Codable, CaseIterable, Sendable {
    case balanced, throughput, price, exacto, smartPrice

    /// Picker label; "Smart price" does not fall out of `rawValue.capitalized`.
    public var displayName: String {
        self == .smartPrice ? "Smart price" : rawValue.capitalized
    }
}

public enum TierMode: String, Codable, CaseIterable, Sendable {
    case auto, `default`, priority, flex
}

public struct FlexPolicy: Codable, Equatable, Sendable {
    public var fallback = true
    public var attempts = 2 {
        didSet { attempts = min(max(attempts, 1), 5) }
    }
    public var firstByteTimeout: TimeInterval = 30
    public var nonStreamingTimeout: TimeInterval = 120

    public init() {}

    public init(fallback: Bool = true, attempts: Int = 2, firstByteTimeout: TimeInterval = 30, nonStreamingTimeout: TimeInterval = 120) {
        self.fallback = fallback
        self.attempts = min(max(attempts, 1), 5)
        self.firstByteTimeout = firstByteTimeout
        self.nonStreamingTimeout = nonStreamingTimeout
    }

    private enum CodingKeys: String, CodingKey {
        case fallback, attempts, firstByteTimeout, nonStreamingTimeout
    }

    /// Custom decoding: `didSet` does not run during `init(from:)`, so clamp
    /// `attempts` here, and default any missing key (older settings files).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.fallback = try container.decodeIfPresent(Bool.self, forKey: .fallback) ?? true
        self.attempts = min(max(try container.decodeIfPresent(Int.self, forKey: .attempts) ?? 2, 1), 5)
        self.firstByteTimeout = try container.decodeIfPresent(TimeInterval.self, forKey: .firstByteTimeout) ?? 30
        self.nonStreamingTimeout = try container.decodeIfPresent(TimeInterval.self, forKey: .nonStreamingTimeout) ?? 120
    }
}

public struct Settings: Codable, Equatable, Sendable {
    public var enabled = true
    public var sort = SortMode.balanced
    public var tier = TierMode.auto
    public var flex = FlexPolicy()
    /// Endpoint-catalog TTL in minutes: how often a cached model's endpoint list is refreshed.
    public var pollMinutes = 10 {
        didSet { pollMinutes = min(max(pollMinutes, 1), 60) }
    }

    public init() {}

    public init(
        enabled: Bool = true, sort: SortMode = .balanced, tier: TierMode = .auto,
        flex: FlexPolicy = FlexPolicy(), pollMinutes: Int = 10
    ) {
        self.enabled = enabled
        self.sort = sort
        self.tier = tier
        self.flex = flex
        self.pollMinutes = min(max(pollMinutes, 1), 60)
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, sort, tier, flex, pollMinutes
    }

    /// Custom decoding: `didSet` does not run during `init(from:)`, so clamp
    /// `pollMinutes` here, and default any missing key (older settings files).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.sort = try container.decodeIfPresent(SortMode.self, forKey: .sort) ?? .balanced
        self.tier = try container.decodeIfPresent(TierMode.self, forKey: .tier) ?? .auto
        self.flex = try container.decodeIfPresent(FlexPolicy.self, forKey: .flex) ?? FlexPolicy()
        self.pollMinutes = min(max(try container.decodeIfPresent(Int.self, forKey: .pollMinutes) ?? 10, 1), 60)
    }
}

public struct TierAvailability: Equatable, Sendable {
    public var hasFlex: Bool
    public var hasPriority: Bool

    public init(hasFlex: Bool, hasPriority: Bool) {
        self.hasFlex = hasFlex
        self.hasPriority = hasPriority
    }
}

public final class SettingsStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var stored: Settings

    public init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(Settings.self, from: data) {
            self.stored = decoded
        } else {
            self.stored = Settings()
        }
    }

    public var settings: Settings {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    public func save() throws {
        let data = try JSONEncoder().encode(settings)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
