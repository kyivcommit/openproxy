import Foundation

/// RFC 7230 hop-by-hop header handling: these headers are meaningful only for a
/// single transport hop and must not be forwarded, nor may any header the
/// `Connection` header nominates.
enum HeaderFilter {
    static func stripHopByHop(_ headers: [(String, String)]) -> [(String, String)] {
        var nominated = Set<String>()
        for (name, value) in headers where name.lowercased() == "connection" {
            for token in value.split(separator: ",") {
                nominated.insert(token.trimmingCharacters(in: .whitespaces).lowercased())
            }
        }
        return headers.filter { header in
            let name = header.0.lowercased()
            return !isHopByHop(name) && !nominated.contains(name)
        }
    }

    static func isHopByHop(_ lowercasedName: String) -> Bool {
        switch lowercasedName {
        case "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
             "te", "trailer", "transfer-encoding", "upgrade":
            return true
        default:
            return lowercasedName.hasPrefix("proxy-")
        }
    }
}
