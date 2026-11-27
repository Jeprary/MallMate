import XCTest

/// Real OS dispatch to existing route selection, then real Safari on the production website.
/// Camera stays off: a simulator selection is not physical AR localization or arrival evidence.
@MainActor
final class RouteProductionReturnUITests: XCTestCase {
    private let returnPage = "https://mallmate.pages.dev/?screen=detail&store=amap-B02001HUD4&lang=en"

    private func open(_ app: XCUIApplication, host: String, path: String) throws {
        app.launchArguments = []
        app.launch()
        var parts = try XCTUnwrap(URLComponents(string: "mallmate-route://" + host + "/" + path))
        parts.queryItems = [URLQueryItem(name: "lang", value: "en"), URLQueryItem(name: "return", value: returnPage)]
        app.open(try XCTUnwrap(parts.url))
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    private func assertProductionDetail(_ name: String) {
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(safari.webViews.firstMatch.waitForExistence(timeout: 20))
        let storeName = safari.staticTexts.matching(NSPredicate(format: "label == %@ OR label == %@", "UNIQLO", "优衣库")).firstMatch
        XCTAssertTrue(storeName.waitForExistence(timeout: 20), "The production return must restore the requested store, not the chat home.")
        capture(safari, name + "-production-detail")
    }

    private func assertTerminalOnSwitchBack(_ app: XCUIApplication) {
        app.activate()
        XCTAssertTrue(app.staticTexts["visitor.completion"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["handoff.start"].exists)
        XCTAssertFalse(app.buttons["route.new"].exists)
        app.terminate()
    }

    func testMissingUniqloMapReturnsToProductionStoreDetail() throws {
        let app = XCUIApplication()
        try open(app, host: "guide", path: "B02001HUD4")
        XCTAssertTrue(app.staticTexts["Route unavailable"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["handoff.start"].exists)
        XCTAssertTrue(app.buttons["visitor.return"].isHittable)
        capture(app, "guide-missing-map")
        app.buttons["visitor.return"].tap()
        assertProductionDetail("guide")
        assertTerminalOnSwitchBack(app)
    }

    func testExistingEFCampusRouteReadyAndExitReturnsToProductionStoreDetail() throws {
        let app = XCUIApplication()
        try open(app, host: "route", path: "85D2F1AA-89D7-4A3D-B101-2624E4B2D41C")
        XCTAssertTrue(app.staticTexts["handoff.title"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["handoff.title"].label, "EF F2 2026.11.12")
        XCTAssertTrue(app.buttons["handoff.start"].isEnabled)
        capture(app, "EF-existing-backup-ready-camera-off")
        // This is a transport check to an independently selected return page.
        // It does not bind the campus map to UNIQLO or start an unsupported simulator camera.
        app.buttons["handoff.close"].tap()
        assertProductionDetail("EF-exit")
        assertTerminalOnSwitchBack(app)
    }
}
