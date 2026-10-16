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

    @MainActor
    public static func makeModel(baseDirectory: URL = AppGraph.defaultBaseDirectory) throws -> AppModel {
        // On a clean install this directory does not exist yet, and SQLite cannot
        // create stats.sqlite in a missing directory. Create it owner-only first.
        try ensureBaseDirectory(baseDirectory)

        let settingsStore = SettingsStore(url: baseDirectory.appending(path: "settings.json"))
        let stats = try StatsStore(path: baseDirectory.appending(path: "stats.sqlite").path)

        let ca = CertAuthority(directory: baseDirectory)
        try ca.loadOrCreate()

        let upstream = NIOUpstreamClient(resolver: DoHResolver())
        let catalog = TierCatalog(fetcher: UpstreamEndpointsFetcher(client: upstream))
        let installer = Installer(ca: ca, runner: OsascriptRunner())
        let server = ProxyServer(
            ca: ca,
            upstream: upstream,
            catalog: catalog,
            stats: stats,
            settings: { [settingsStore] in settingsStore.settings })

        return AppModel(settingsStore: settingsStore, stats: stats, installer: installer, server: server)
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

    func fetch(modelId: String, authorization: String) async throws -> Data {
        let response = try await client.send(UpstreamRequest(
            method: "GET",
            path: "/api/v1/models/\(modelId)/endpoints",
            headers: [("Authorization", authorization), ("Accept", "application/json")],
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
