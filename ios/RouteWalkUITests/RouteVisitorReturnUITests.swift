import XCTest

/// Exercises real OS URL dispatch and browser return with an unavailable UUID.
/// This does not fabricate a world map or claim camera/relocalization coverage.
@MainActor
final class RouteVisitorReturnUITests: XCTestCase {
    func testUnavailableVisitorReturnsToActualSafariPageWithoutOpeningLibrary() throws {
        let app = XCUIApplication()
        app.launchArguments = []
        app.launch()
        var invocation = try XCTUnwrap(URLComponents(string: "mallmate-route://route/" + UUID().uuidString))
        invocation.queryItems = [URLQueryItem(name: "lang", value: "en"),
            URLQueryItem(name: "return", value: "http://127.0.0.1:8770/ar-demo.html?lang=en")]
        app.open(try XCTUnwrap(invocation.url))
        XCTAssertTrue(app.staticTexts["visitor.completion"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["visitor.completion"].label, "Route unavailable")
        XCTAssertFalse(app.buttons["handoff.start"].exists)
        XCTAssertFalse(app.buttons["route.new"].exists)
        let unavailable = XCTAttachment(screenshot: app.screenshot())
        unavailable.name = "OS-handoff-unavailable"; unavailable.lifetime = .keepAlways; add(unavailable)
        app.buttons["visitor.return"].tap()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(safari.staticTexts["Demo route"].waitForExistence(timeout: 15))
        let browser = XCTAttachment(screenshot: safari.screenshot())
        browser.name = "OS-return-Safari-EF-page"; browser.lifetime = .keepAlways; add(browser)
        app.activate()
        XCTAssertTrue(app.staticTexts["visitor.completion"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["handoff.start"].exists)
        XCTAssertFalse(app.buttons["route.new"].exists)
        app.terminate()
    }
}
