import XCTest

@MainActor
final class RouteLiveCameraUITests: XCTestCase {
    func testExistingDraftEntersLiveCameraAndReturnsWithoutSaving() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("A physical camera is required; the interface preview is covered separately.")
        #else
        let app = XCUIApplication()
        app.launch()
        XCUIDevice.shared.system.open(try XCTUnwrap(URL(string: "mallmate-route://practice?lang=en")))
        XCTAssertTrue(app.navigationBars["Routes"].waitForExistence(timeout: 8))
        let draft = app.cells.containing(.staticText, identifier: "Not saved").firstMatch
        if draft.exists { draft.tap() }
        else {
            let saved = app.cells.firstMatch
            try XCTSkipIf(!saved.exists, "No route exists; do not create an extra user route for this check.")
            saved.press(forDuration: 1)
            let scan = app.buttons["Scan again"]
            XCTAssertTrue(scan.waitForExistence(timeout: 4))
            scan.tap() // The existing map remains intact until an explicit save, which this check never invokes.
        }
        let exit = app.buttons["record.exit"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: exit)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed, app.debugDescription)
        let camera = XCTAttachment(screenshot: app.screenshot())
        camera.name = "真机-相机进入"; camera.lifetime = .keepAlways; add(camera)
        exit.tap()
        XCTAssertTrue(app.navigationBars["Routes"].waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertFalse(app.buttons["record.exit"].exists)
        let home = XCTAttachment(screenshot: app.screenshot())
        home.name = "真机-相机退出"; home.lifetime = .keepAlways; add(home)
        #endif
    }
}
