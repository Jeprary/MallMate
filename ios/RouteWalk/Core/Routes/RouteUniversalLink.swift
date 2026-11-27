import Foundation

enum RouteUniversalLink {
    static func invocation(for url: URL) -> URL? {
        guard let link = URLComponents(url: url, resolvingAgainstBaseURL: false),
              link.user == nil, link.password == nil, link.fragment == nil,
              link.path.hasPrefix("/go/"),
              let route = UUID(uuidString: String(link.path.dropFirst("/go/".count))) else { return nil }

        let callbackHost: String
        let callbackScheme: String
        let callbackPort: Int?
        switch (link.scheme, link.host, link.port) {
        case ("https", "mallmate-ar-preview.pages.dev", nil):
            (callbackScheme, callbackHost, callbackPort) = ("https", "mallmate.pages.dev", nil)
#if DEBUG
        case ("http", "localhost", 8766):
            (callbackScheme, callbackHost, callbackPort) = ("http", "127.0.0.1", 8770)
#endif
        default:
            return nil
        }

        let query = link.queryItems ?? []
        let returnItems = query.filter { $0.name == "return" }
        guard returnItems.count == 1, let value = returnItems[0].value,
              let callback = URLComponents(string: value), callback.scheme == callbackScheme,
              callback.host == callbackHost, callback.port == callbackPort,
              callback.user == nil, callback.password == nil, callback.path == "/" else { return nil }
        let callbackItems = callback.queryItems ?? []
        let screens = callbackItems.filter { $0.name == "screen" }
        let stores = callbackItems.filter { $0.name == "store" }
        guard screens.count == 1, screens[0].value == "map", stores.count == 1,
              let store = stores[0].value, store.range(of: "^[A-Za-z0-9_-]{1,200}$", options: .regularExpression) != nil else { return nil }
        if let fragment = callback.fragment {
            guard fragment.hasPrefix("return-"),
                  UUID(uuidString: String(fragment.dropFirst("return-".count))) != nil else { return nil }
        }

        var invocation = URLComponents()
        invocation.scheme = "mallmate-route"
        invocation.host = "route"
        invocation.path = "/" + route.uuidString
        invocation.queryItems = query
        return invocation.url
    }
}
