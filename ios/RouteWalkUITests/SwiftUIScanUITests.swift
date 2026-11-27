import XCTest

@MainActor
final class SwiftUIScanUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testScanStatesAndCoachingInRealAppWindow() {
        let app = XCUIApplication()
        for scenario in ["start", "one", "ready", "extending", "floor", "mapping", "interrupted", "saving", "coaching"] {
            app.launchArguments = ["--interface-preview=" + scenario]
            app.launch()
            let exit = app.buttons["record.exit"]
            XCTAssertTrue(exit.waitForExistence(timeout: 6), app.debugDescription)
            XCTAssertTrue(exit.isHittable)
            XCTAssertFalse(app.staticTexts["record.count"].exists)
            XCTAssertGreaterThanOrEqual(exit.frame.minY, 50, "Close must clear the iPhone status area")
            if scenario == "coaching" {
                XCTAssertFalse(app.buttons["record.more"].exists)
                XCTAssertFalse(app.buttons["record.mark"].exists)
                XCTAssertFalse(app.staticTexts["record.instruction"].exists)
            } else {
                XCTAssertTrue(app.buttons["record.more"].exists)
                XCTAssertEqual(app.buttons["record.save"].isEnabled, scenario == "ready" || scenario == "extending")
                XCTAssertTrue(app.descendants(matching: .any)["record.mapStatus"].exists)
                XCTAssertFalse(app.buttons["record.mapStatus"].exists, "Map status is informational; details belong in More")
                let expectedMapStates = ["start": "Map unavailable", "one": "More scanning needed",
                                         "extending": "Map expanding", "ready": "Current area mapped"]
                if let expected = expectedMapStates[scenario] {
                    XCTAssertEqual(app.descendants(matching: .any)["record.mapStatus"].value as? String, expected)
                }
                let prompt = app.staticTexts["record.instruction"]
                if ["one", "ready", "extending", "mapping", "saving"].contains(scenario) {
                    XCTAssertFalse(prompt.exists, "Normal collection and saving hide redundant instructions")
                } else {
                    XCTAssertTrue(prompt.exists)
                    XCTAssertGreaterThan(prompt.frame.minY, app.frame.midY, "Action hints belong above the bottom controls")
                }
                if scenario == "start" {
                    XCTAssertEqual(prompt.label, "Place destination")
                }
                XCTAssertEqual(app.buttons["record.undo"].label, "Undo last point")
            }
            attach(app, "SwiftUI实际窗口-" + scenario)
            app.terminate()
        }
    }

    func testLargestTextActionsCanBeReachedByScrolling() {
        let app = XCUIApplication()
        app.launchArguments = ["--interface-preview=ready", "--preview-largest-text"]
        app.launch()
        XCTAssertTrue(app.buttons["record.exit"].waitForExistence(timeout: 6))
        XCTAssertFalse(app.staticTexts["record.instruction"].exists)
        let scroll = app.scrollViews["record.controls"]
        XCTAssertTrue(scroll.exists)
        attach(app, "SwiftUI实际窗口-最大字初始")
        for name in ["record.mark", "record.save"] {
            let button = app.buttons[name]
            for _ in 0..<4 where !button.isHittable { scroll.swipeUp() }
            XCTAssertTrue(button.isHittable, app.debugDescription)
            XCTAssertTrue(button.isEnabled)
            button.tap() // The DEBUG fixture has inert callbacks and never writes a map.
        }
        XCTAssertTrue(app.buttons["record.exit"].isHittable)
        attach(app, "SwiftUI实际窗口-最大字滚动后")
    }

    func testChineseAndGuideCoaching() {
        let app = XCUIApplication()
        app.launchArguments = ["--interface-preview=ready", "--preview-language=zh"]
        app.launch()
        XCTAssertTrue(app.buttons["record.exit"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.buttons["record.mark"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.buttons["record.mark"].label.contains("加路点"))
        XCTAssertFalse(app.staticTexts["record.instruction"].exists)
        attach(app, "SwiftUI实际窗口-中文扫描")
        app.terminate()
        app.launchArguments = ["--interface-preview=start", "--preview-language=zh"]
        app.launch()
        XCTAssertTrue(app.buttons["record.exit"].waitForExistence(timeout: 6))
        XCTAssertEqual(app.staticTexts["record.instruction"].label, "放置终点")
        attach(app, "SwiftUI实际窗口-中文终点")
        app.terminate()
        app.launchArguments = ["--interface-preview=guide-coaching"]
        app.launch()
        XCTAssertTrue(app.buttons["guide.exit"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.buttons["guide.exit"].isHittable)
        XCTAssertFalse(app.buttons["guide.placement"].exists)
        XCTAssertFalse(app.staticTexts["guide.instruction"].exists)
        attach(app, "SwiftUI实际窗口-系统导航引导")
    }

    func testMapStatusDetailsKeepMappingAndSaveStatesSeparate() {
        let app = XCUIApplication()
        app.launchArguments = ["--interface-preview=extending"]
        app.launch()
        XCTAssertTrue(app.buttons["record.exit"].waitForExistence(timeout: 6))
        let status = app.descendants(matching: .any)["record.mapStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 6))
        XCTAssertEqual(status.value as? String, "Map expanding")
        XCTAssertFalse(app.buttons["record.mapStatus"].exists)
        XCTAssertTrue(app.buttons["record.save"].isEnabled)
        app.buttons["record.more"].tap()
        XCTAssertFalse(app.buttons["camera.retry"].exists, "Normal mapping has no recovery action")
        let details = app.buttons["record.mapDetailsAction"]
        XCTAssertTrue(details.waitForExistence(timeout: 3))
        details.tap()
        XCTAssertTrue(app.alerts["Map details"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.alerts.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Map expanding")).firstMatch.exists)
        attach(app, "SwiftUI实际窗口-地图状态详情")
    }

    func testSavedRouteReviewStates() {
        let app = XCUIApplication()
        for scenario in ["review-saved", "review-recovering", "review-coaching"] {
            app.launchArguments = ["--interface-preview=" + scenario]
            app.launch()
            XCTAssertTrue(app.buttons["review.exit"].waitForExistence(timeout: 6))
            XCTAssertTrue(app.buttons["review.exit"].isHittable)
            XCTAssertFalse(app.buttons["record.mark"].exists)
            XCTAssertFalse(app.buttons["record.save"].exists)
            XCTAssertFalse(app.buttons["record.undo"].exists)
            if scenario == "review-coaching" {
                XCTAssertFalse(app.buttons["review.more"].exists)
                XCTAssertFalse(app.staticTexts["review.status"].exists)
            } else {
                XCTAssertTrue(app.buttons["review.more"].exists)
                XCTAssertEqual(app.staticTexts["review.status"].label,
                               scenario == "review-saved" ? "Preview" : "Look around the scanned area")
            }
            attach(app, "SwiftUI实际窗口-" + scenario)
            app.terminate()
        }
    }

    func testOpeningPreviewUsesProductionProgressWithoutCancel() {
        let app = XCUIApplication()
        app.launchArguments = ["--interface-preview=opening"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["route.preparing"].waitForExistence(timeout: 6))
        XCTAssertFalse(app.buttons["Cancel"].exists)
        XCTAssertFalse(app.buttons["取消"].exists)
        attach(app, "SwiftUI实际窗口-打开相机灰色指示")
    }

    func testFailedCameraKeepsExitAndRetryAvailableInBothLanguages() {
        let app = XCUIApplication()
        for language in ["en", "zh"] {
            app.launchArguments = ["--interface-preview=failed", "--preview-language=" + language]
            app.launch()
            XCTAssertTrue(app.buttons["record.exit"].waitForExistence(timeout: 6))
            XCTAssertTrue(app.buttons["record.exit"].isHittable)
            XCTAssertEqual(app.descendants(matching: .any)["record.mapStatus"].value as? String,
                           language == "zh" ? "追踪已停止" : "Tracking stopped")
            XCTAssertFalse(app.buttons["record.mark"].isEnabled)
            XCTAssertFalse(app.buttons["record.save"].isEnabled)
            attach(app, "SwiftUI实际窗口-追踪停止-" + language)
            app.buttons["record.more"].tap()
            let retry = app.buttons["camera.retry"].firstMatch
            XCTAssertTrue(retry.waitForExistence(timeout: 3))
            XCTAssertTrue(retry.isHittable)
            XCTAssertEqual(retry.label, language == "zh" ? "重试相机" : "Retry camera")
            attach(app, "SwiftUI实际窗口-重试相机菜单-" + language)
            retry.tap() // Camera-off fixture: exercise the button without claiming AR recovery.
            XCTAssertFalse(app.buttons["record.save"].isEnabled)
            app.terminate()
        }
        for (scenario, exitID, menuID) in [("review-failed", "review.exit", "review.more"),
                                           ("guide-failed", "guide.exit", "guide.placement")] {
            for language in ["en", "zh"] {
                app.launchArguments = ["--interface-preview=" + scenario, "--preview-language=" + language]
                app.launch()
                XCTAssertTrue(app.buttons[exitID].waitForExistence(timeout: 6))
                XCTAssertTrue(app.buttons[exitID].isHittable)
                if scenario == "guide-failed" {
                    XCTAssertEqual(app.staticTexts["guide.instruction"].label,
                                   language == "zh" ? "追踪已停止" : "Tracking stopped")
                    for title in ["Matching surroundings", "Restoring the route", "识别周围环境", "恢复路线"] {
                        XCTAssertFalse(app.staticTexts[title].exists)
                    }
                }
                attach(app, "SwiftUI实际窗口-" + scenario + "-" + language)
                app.buttons[menuID].tap()
                XCTAssertTrue(app.buttons["camera.retry"].firstMatch.waitForExistence(timeout: 3))
                attach(app, "SwiftUI实际窗口-" + scenario + "-重试菜单-" + language)
                app.terminate()
            }
        }
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
