import Foundation

/// A visitor may return to a web page, never to another app scheme or an invocation loop.
enum RouteWebReturnPolicy {
    static func validated(_ raw: String?) -> URL? {
        guard let raw, let parts = URLComponents(string: raw),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil,
              !parts.path.lowercased().hasPrefix("/guide/"),
              parts.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        let scheme = parts.scheme?.lowercased()
        if scheme == "https" { return parts.url }
#if DEBUG
        // The local, static-only preview is useful before a public HTTPS site is deployed.
        if scheme == "http", [8766, 8770, 59323].contains(parts.port ?? 0),
           isLocal(host), ["/", "/ar-demo.html", "/ar-test.html"].contains(parts.path) {
            return parts.url
        }
#endif
        return nil
    }

    private static func isLocal(_ host: String) -> Bool {
        if host == "localhost" { return true }
        let fields = host.split(separator: ".")
        guard fields.count == 4 else { return false }
        let octets = fields.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        return octets[0] == 127 || octets[0] == 10 ||
            (octets[0] == 192 && octets[1] == 168) ||
            (octets[0] == 172 && (16...31).contains(octets[1]))
    }
}
