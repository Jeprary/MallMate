import XCTest

@MainActor
final class RouteMotionUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testEntryExitConfirmationAndReturnNotice() {
        let app = XCUIApplication()
        app.launchArguments = ["--transition-preview"]
        app.launch()
        wait("routes", app)
        enter(app)
        app.buttons["record.exit"].tap()
        wait("routes", app)
        XCTAssertEqual(app.staticTexts["transition.stops"].label, "Stops: 1")
        enter(app)
        app.buttons["transition.confirmExit"].tap()
        XCTAssertTrue(app.buttons["End preview"].waitForExistence(timeout: 4))
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Keep preview", "Cancel", "取消"])).firstMatch
        if cancel.exists { cancel.tap() }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.70)).tap() }
        wait("camera", app)
        XCTAssertEqual(app.staticTexts["transition.stops"].label, "Stops: 1")
        app.buttons["transition.confirmExit"].tap()
        app.buttons["End preview"].tap()
        XCTAssertTrue(app.alerts["Preview returned"].waitForExistence(timeout: 5))
        app.alerts["Preview returned"].buttons["OK"].tap()
        wait("routes", app)
        XCTAssertEqual(app.staticTexts["transition.stops"].label, "Stops: 2")
        capture(app, "进退动效-确认后返回")
    }

    func testPreparingCancellationAndReduceMotionReentry() {
        let app = XCUIApplication()
        app.launchArguments = ["--transition-preview", "--preview-reduce-motion"]
        app.launch()
        wait("routes", app)
        app.buttons["transition.enter"].tap()
        wait("preparing", app)
        let cancel = app.buttons["route.cancelPreparing"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 4))
        cancel.tap()
        wait("routes", app)
        XCTAssertEqual(app.staticTexts["transition.stops"].label, "Stops: 1")
        enter(app)
        app.buttons["record.exit"].tap()
        wait("routes", app)
        XCTAssertEqual(app.staticTexts["transition.stops"].label, "Stops: 2")
        capture(app, "进退动效-减少动态效果")
    }

    private func enter(_ app: XCUIApplication) {
        app.buttons["transition.enter"].tap()
        wait("preparing", app)
        app.buttons["transition.ready"].tap()
        wait("camera", app)
        XCTAssertTrue(app.buttons["record.exit"].isHittable)
    }
    private func wait(_ phase: String, _ app: XCUIApplication) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label == %@", phase),
            object: app.staticTexts["transition.phase"])
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 6), .completed, app.debugDescription)
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
