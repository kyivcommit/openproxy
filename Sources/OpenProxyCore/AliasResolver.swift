import Foundation

/// Remembers which concrete model an alias id (`~vendor/name-latest`) actually serves.
/// The response body is the only place OpenRouter says so, so the first request after
/// launch goes unranked and every later one is ranked from the learned id.
actor AliasResolver {
    /// Aliases are few; the cap only stops a client from growing this without bound.
    static let maxEntries = 64

    private var concrete: [String: String] = [:]
    /// Insertion order, so the oldest alias is the one dropped at capacity.
    private var order: [String] = []

    func resolve(_ model: String) -> String? {
        guard Self.isAlias(model) else { return nil }
        return concrete[model]
    }

    func learn(alias: String, concrete: String) {
        guard Self.isAlias(alias), !concrete.isEmpty, concrete != alias else { return }
        if self.concrete[alias] == nil {
            order.append(alias)
            if order.count > Self.maxEntries {
                self.concrete.removeValue(forKey: order.removeFirst())
            }
        }
        self.concrete[alias] = concrete
    }

    private static func isAlias(_ model: String) -> Bool { model.hasPrefix("~") }
}
