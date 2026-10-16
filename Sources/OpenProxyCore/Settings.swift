import Foundation

public enum SortMode: String, Codable, CaseIterable, Sendable {
    case balanced, throughput, price, exacto
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
}

public struct Settings: Codable, Equatable, Sendable {
    public var enabled = true
    public var sort = SortMode.balanced
    public var tier = TierMode.auto
    public var flex = FlexPolicy()

    public init() {}

    public init(enabled: Bool = true, sort: SortMode = .balanced, tier: TierMode = .auto, flex: FlexPolicy = FlexPolicy()) {
        self.enabled = enabled
        self.sort = sort
        self.tier = tier
        self.flex = flex
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
