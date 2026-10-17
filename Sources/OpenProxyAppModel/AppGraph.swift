import Foundation
import OpenProxyCore

/// Builds the concrete production dependency graph (stores, CA, installer,
/// upstream, proxy server) behind a single injection point, so the executable
/// stays free of wiring and the `AppModel` stays testable with fakes.
public enum AppGraph {
    public static var defaultBaseDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "openproxy")
    }

    /// True when the app bundle at `bundleURL` ships the helper's launch daemon plist, i.e. this
    /// is a built OpenProxy.app. A plain `swift run` has no such bundle, so there the legacy
    /// osascript fallback stays available; in a built app the helper must work.
    static func helperIsBundled(inBundleAt bundleURL: URL = Bundle.main.bundleURL) -> Bool {
        FileManager.default.fileExists(atPath: bundleURL
            .appending(path: "Contents/Library/LaunchDaemons/dev.openproxy.helper.plist").path)
    }

    @MainActor
    public static func makeModel(
        baseDirectory: URL = AppGraph.defaultBaseDirectory,
        quitDecision: QuitDecision,
        setupDecision: SetupDecision = NoSetupDecision(),
        uninstallDecision: UninstallDecision = NoUninstallDecision()
    ) throws -> AppModel {
        // On a clean install this directory does not exist yet, and SQLite cannot
        // create stats.sqlite in a missing directory. Create it owner-only first.
        try ensureBaseDirectory(baseDirectory)

        let settingsStore = SettingsStore(url: baseDirectory.appending(path: "settings.json"))
        let stats = try StatsStore(path: baseDirectory.appending(path: "stats.sqlite").path)

        let ca = CertAuthority(directory: baseDirectory)
        try ca.loadOrCreate()

        let upstream = NIOUpstreamClient(resolver: DoHResolver())
        // TTL follows the UI setting (pollMinutes), read per lookup, so changing it needs no restart.
        let catalog = EndpointCatalog(
            fetcher: UpstreamEndpointsFetcher(client: upstream),
            ttl: { [settingsStore] in TimeInterval(settingsStore.settings.pollMinutes * 60) })
        let installer = Installer(
            caPEMURL: ca.caCertificatePEMURL,
            runner: OsascriptRunner(),
            commandRunner: ShellCommandRunner(),
            hostsEditor: XPCHostsEditor(),
            helper: SMAppServiceDaemon(),
            allowPasswordFallback: !helperIsBundled())
        let server = ProxyServer(
            ca: ca,
            upstream: upstream,
            catalog: catalog,
            stats: stats,
            settings: { [settingsStore] in settingsStore.settings })

        return AppModel(
            settingsStore: settingsStore, stats: stats, installer: installer,
            server: server, loginItem: SMAppServiceLoginItem(), quitDecision: quitDecision,
            helper: SMAppServiceDaemon(),
            setupDecision: setupDecision,
            uninstallDecision: uninstallDecision,
            dataRemover: AppSupportDataRemover(directory: baseDirectory),
            waiting: RealSetupWaiting(),
            caWasRegenerated: ca.didRotateLegacyCA)
    }

    /// The CA key and stats live here, so the directory stays owner-only even if
    /// it already existed with looser permissions.
    static func ensureBaseDirectory(_ url: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}

/// Fetches `GET /api/v1/models/<id>/endpoints` through the same hosts-bypassing
/// upstream client, so the catalog lookup never loops back through this proxy.
struct UpstreamEndpointsFetcher: EndpointsFetcher {
    let client: UpstreamClient

    func fetch(modelId: String, authorization: String?) async throws -> Data {
        // No key is needed for /endpoints, so only forward the header when the client sent one.
        var headers: [(String, String)] = [("Accept", "application/json")]
        if let authorization { headers.append(("Authorization", authorization)) }
        let response = try await client.send(UpstreamRequest(
            method: "GET",
            path: "/api/v1/models/\(modelId)/endpoints",
            headers: headers,
            body: Data()))
        guard response.status == 200 else { throw EndpointsFetchError.badStatus(response.status) }
        var data = Data()
        for try await chunk in response.body { data.append(chunk) }
        return data
    }
}

enum EndpointsFetchError: Error {
    case badStatus(Int)
}
