import Foundation
import XCTest
@testable import RouteWalk

final class RouteUniversalLinkChecks: XCTestCase {
    private let route = "150B0E3D-B07F-4AAC-A571-23581BE36619"

    private func link(host: String = "mallmate-ar-preview.pages.dev", callback: String) throws -> URL {
        var url = URLComponents()
        url.scheme = "https"
        url.host = host
        url.path = "/go/" + route
        url.queryItems = [URLQueryItem(name: "lang", value: "zh"), URLQueryItem(name: "return", value: callback)]
        return try XCTUnwrap(url.url)
    }

    func testReusesExistingRouteInvocationAndPreservesReturnToken() throws {
        let callback = "https://mallmate.pages.dev/?screen=map&store=amap-example&lang=zh#return-020BB542-AAF7-405A-B880-E48DB220672C"
        let url = try XCTUnwrap(RouteUniversalLink.invocation(for: link(callback: callback)))
        let parsed = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parsed.scheme, "mallmate-route")
        XCTAssertEqual(parsed.host, "route")
        XCTAssertEqual(parsed.path, "/" + route)
        XCTAssertEqual(parsed.queryItems?.first { $0.name == "return" }?.value, callback)
    }

    func testRequiresTheDedicatedEntryAndMallMateStoreMap() throws {
        let callback = "https://mallmate.pages.dev/?screen=map&store=amap-example"
        XCTAssertNil(RouteUniversalLink.invocation(for: try link(host: "mallmate.pages.dev", callback: callback)))
        XCTAssertNil(RouteUniversalLink.invocation(for: try link(callback: "https://example.com/?screen=map&store=amap-example")))
        XCTAssertNil(RouteUniversalLink.invocation(for: try link(callback: "https://mallmate.pages.dev/admin?screen=map&store=amap-example")))
        XCTAssertNil(RouteUniversalLink.invocation(for: try link(callback: callback + "&store=other")))
    }
}
