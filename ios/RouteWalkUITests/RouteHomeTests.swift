import XCTest

@MainActor
final class RouteHomeTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testColdStoreLinkAndImporterKeepDestination() throws {
        let app = XCUIApplication(); app.launch()
        try open("practice?lang=en"); app.terminate()
        try open("guide/B02001HUD4")
        XCTAssertTrue(app.staticTexts["UNIQLO"].waitForExistence(timeout: 7), app.debugDescription)
        if app.buttons["home.guide"].exists { throw XCTSkip("Preserving an existing mall map; empty-store import scenario is inapplicable.") }
        let status = app.staticTexts["home.status"]
        XCTAssertTrue(status.label.contains("Import the route"), app.debugDescription)
        XCTAssertTrue(app.buttons["home.import"].isHittable)
        app.buttons["home.import"].tap()
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消", "Close", "关闭"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 7)); cancel.tap()
        XCTAssertTrue(app.staticTexts["UNIQLO"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["home.import"].isHittable)
        capture(app, "门店链接-导入取消后")
        try open("guide/invalid")
        let invalid = app.alerts["Cannot open this destination"]
        XCTAssertTrue(invalid.waitForExistence(timeout: 5)); invalid.buttons["OK"].tap()
        XCTAssertTrue(app.staticTexts["UNIQLO"].exists)
    }

    func testPracticeLinkAndLanguageChangeStayOnFlatList() throws {
        let app = XCUIApplication(); app.launch()
        try open("practice?lang=en")
        XCTAssertTrue(app.navigationBars["Routes"].waitForExistence(timeout: 7))
        XCTAssertFalse(app.buttons["home.myRoutes"].exists)
        XCTAssertTrue(app.buttons["practiceRoutes.add"].isHittable)
        try open("practice?lang=zh")
        XCTAssertTrue(app.navigationBars["路线"].waitForExistence(timeout: 6))
        app.buttons["home.language"].tap()
        let language = app.buttons["语言"].firstMatch
        XCTAssertTrue(language.waitForExistence(timeout: 4)); language.tap()
        let english = app.buttons["English"].firstMatch
        XCTAssertTrue(english.waitForExistence(timeout: 4)); english.tap()
        XCTAssertTrue(app.navigationBars["Routes"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["practiceRoutes.add"].isHittable)
        capture(app, "平铺路线-语言切换后")
    }

    private func open(_ path: String) throws {
        XCUIDevice.shared.system.open(try XCTUnwrap(URL(string: "mallmate-route://" + path)))
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name
        shot.lifetime = .keepAlways; add(shot)
    }
}
