import XCTest

@MainActor
final class RouteHandoffUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testHandoffAndDestinationPromptInBothLanguagesAndLargeText() {
        let app = XCUIApplication()
        for language in ["en", "zh"] {
            for large in [false, true] {
                app.launchArguments = ["--handoff-preview", "--preview-language=" + language]
                if large { app.launchArguments.append("--preview-largest-text") }
                app.launch()
                XCTAssertTrue(app.staticTexts["handoff.title"].waitForExistence(timeout: 10))
                XCTAssertTrue(app.buttons["handoff.start"].isHittable)
                XCTAssertTrue(app.buttons["handoff.close"].isHittable)
                let shot = XCTAttachment(screenshot: app.screenshot())
                shot.name = "Handoff-" + language + (large ? "-large" : "-normal")
                shot.lifetime = .keepAlways; add(shot)
                app.terminate()
            }
            app.launchArguments = ["--interface-preview=destination", "--preview-language=" + language]
            app.launch()
            XCTAssertTrue(app.staticTexts[language == "zh" ? "放置终点" : "Place destination"].waitForExistence(timeout: 10))
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "Capture-destination-" + language
            shot.lifetime = .keepAlways; add(shot)
            app.terminate()
        }
    }

    func testVisitorCompletionStatesInBothLanguages() {
        assertVisitorCompletionStates(largestText: false)
    }

    func testVisitorCompletionStatesAtLargestTextInBothLanguages() {
        assertVisitorCompletionStates(largestText: true)
    }

    private func assertVisitorCompletionStates(largestText: Bool,
                                               file: StaticString = #filePath, line: UInt = #line) {
        let app = XCUIApplication()
        for language in ["en", "zh"] {
            for state in ["arrived", "failed", "ended"] {
                app.launchArguments = ["--handoff-preview", "--visitor-completion=" + state,
                                       "--preview-language=" + language]
                if largestText { app.launchArguments.append("--preview-largest-text") }
                app.launch()

                let title = app.staticTexts["visitor.completion"]
                XCTAssertTrue(title.waitForExistence(timeout: 10), app.debugDescription, file: file, line: line)
                let expectedTitle = state == "arrived"
                    ? (language == "zh" ? "已到达" : "Arrived")
                    : (language == "zh" ? "导航已结束" : "Navigation ended")
                XCTAssertEqual(title.label, expectedTitle, file: file, line: line)
                XCTAssertTrue(app.staticTexts["EF F2 2026.11.12"].exists, file: file, line: line)

                let returnButton = app.buttons["visitor.return"]
                XCTAssertTrue(returnButton.exists, file: file, line: line)
                XCTAssertEqual(returnButton.label, language == "zh" ? "返回网页" : "Return to website",
                               file: file, line: line)
                XCTAssertTrue(returnButton.isEnabled, "Returning and retrying must remain available", file: file, line: line)

                let returnError = app.staticTexts["visitor.returnError"]
                XCTAssertEqual(returnError.exists, state == "failed", file: file, line: line)
                if state == "failed" {
                    XCTAssertEqual(returnError.label,
                                   language == "zh" ? "网页未能打开，请重试。" : "Could not open the page. Try again.",
                                   file: file, line: line)
                }
                XCTAssertFalse(app.buttons["handoff.start"].exists, file: file, line: line)
                for libraryTitle in ["Routes", "路线"] {
                    XCTAssertFalse(app.navigationBars[libraryTitle].exists, file: file, line: line)
                    XCTAssertFalse(app.staticTexts[libraryTitle].exists, file: file, line: line)
                }

                let name = "Visitor-completion-" + state + "-" + language + (largestText ? "-largest" : "-normal")
                attach(app, name + "-initial")
                assertFitsHorizontally(title, in: app, file: file, line: line)
                if state == "failed" { assertFitsHorizontally(returnError, in: app, file: file, line: line) }

                let scroll = app.scrollViews.firstMatch
                XCTAssertTrue(scroll.exists, file: file, line: line)
                let neededScroll = !returnButton.isHittable || !app.frame.contains(returnButton.frame)
                for _ in 0..<6 where !returnButton.isHittable || !app.frame.contains(returnButton.frame) {
                    scroll.swipeUp()
                }
                XCTAssertTrue(returnButton.isHittable, app.debugDescription, file: file, line: line)
                XCTAssertTrue(app.frame.contains(returnButton.frame), "The full return action must be reachable", file: file, line: line)
                XCTAssertGreaterThanOrEqual(returnButton.frame.height, 44, file: file, line: line)
                assertFitsHorizontally(returnButton, in: app, file: file, line: line)
                if neededScroll { attach(app, name + "-return-visible") }

                returnButton.tap() // The production component fixture has an inert callback; no browser is opened.
                XCTAssertTrue(title.exists, file: file, line: line)
                XCTAssertTrue(returnButton.isEnabled, file: file, line: line)
                app.terminate()
            }
        }
    }

    private func assertFitsHorizontally(_ element: XCUIElement, in app: XCUIApplication,
                                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(element.frame.width, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.minX, app.frame.minX, file: file, line: line)
        XCTAssertLessThanOrEqual(element.frame.maxX, app.frame.maxX, file: file, line: line)
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
