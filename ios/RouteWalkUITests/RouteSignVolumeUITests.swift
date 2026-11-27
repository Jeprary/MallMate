import XCTest

@MainActor
final class RouteSignVolumeUITests: XCTestCase {
    func testTurnDirectionSignsStayUprightInBothLanguages() {
        let app = XCUIApplication()
        for language in ["en", "zh"] {
            for degrees in ["39.19", "50", "94", "-50"] {
                app.launchArguments = ["--sign-volume-preview=front", "--preview-turn-degrees=" + degrees,
                                       "--preview-context-background", "--preview-guide-interface",
                                       "-routewalk.language", language]
                app.launch()
                XCTAssertTrue(app.staticTexts["sign.volume.ready"].waitForExistence(timeout: 15), app.debugDescription)
                let shot = XCTAttachment(screenshot: app.screenshot())
                shot.name = "Turn-direction-" + degrees + "-" + language
                shot.lifetime = .keepAlways
                add(shot)
                app.terminate()
            }
        }
    }

    func testOutlineComparisonAtFixedCameraDistance() {
        let app = XCUIApplication()
        for background in ["context", "pattern"] {
            for hidden in [true, false] {
                app.launchArguments = ["--sign-volume-preview=front", "--preview-" + background + "-background",
                                       "--preview-guide-interface", "-routewalk.language", "en"]
                if hidden { app.launchArguments.append("--preview-hide-outline") }
                app.launch()
                XCTAssertTrue(app.staticTexts["sign.volume.ready"].waitForExistence(timeout: 15), app.debugDescription)
                let shot = XCTAttachment(screenshot: app.screenshot())
                shot.name = "Outline-" + background + (hidden ? "-before" : "-after")
                shot.lifetime = .keepAlways
                add(shot)
                app.terminate()
            }
        }
    }

    func testProductionVolumeFromFourCameraAngles() {
        let app = XCUIApplication()
        for viewpoint in ["front", "angle", "side", "back"] {
            app.launchArguments = ["--sign-volume-preview=" + viewpoint]
            app.launch()
            XCTAssertTrue(app.staticTexts["sign.volume.ready"].waitForExistence(timeout: 15), app.debugDescription)
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "RealityKit-3D路标-" + viewpoint
            shot.lifetime = .keepAlways
            add(shot)
            app.terminate()
        }
    }

    func testOtherProductionSymbolsAndChineseTitle() {
        let app = XCUIApplication()
        for (symbol, viewpoint, language) in [("up", "front", "en"), ("left", "front", "en"), ("back", "front", "en"),
                                                ("end", "front", "en"), ("point", "front", "en"),
                                                ("right", "angle", "zh")] {
            app.launchArguments = ["--sign-volume-preview=" + viewpoint, "--preview-symbol=" + symbol,
                                   "-routewalk.language", language]
            app.launch()
            XCTAssertTrue(app.staticTexts["sign.volume.ready"].waitForExistence(timeout: 15), app.debugDescription)
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "RealityKit-3D路标-" + symbol + "-" + viewpoint + "-" + language
            shot.lifetime = .keepAlways
            add(shot)
            app.terminate()
        }
    }

    func testFrontAndAngleAgainstLightBackground() {
        let app = XCUIApplication()
        for viewpoint in ["front", "angle"] {
            app.launchArguments = ["--sign-volume-preview=" + viewpoint, "--preview-light-background",
                                   "-routewalk.language", "zh"]
            app.launch()
            XCTAssertTrue(app.staticTexts["sign.volume.ready"].waitForExistence(timeout: 15), app.debugDescription)
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "RealityKit-3D路标-浅色背景-" + viewpoint + "-中文"
            shot.lifetime = .keepAlways
            add(shot)
            app.terminate()
        }
    }

    func testMaterialAgainstContextBackground() {
        let app = XCUIApplication()
        for (viewpoint, language) in [("front", "en"), ("angle", "zh")] {
            app.launchArguments = ["--sign-volume-preview=" + viewpoint, "--preview-context-background", "--preview-guide-interface",
                                   "-routewalk.language", language]
            app.launch()
            XCTAssertTrue(app.staticTexts["sign.volume.ready"].waitForExistence(timeout: 15), app.debugDescription)
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "RealityKit-路标材质-明暗交界-" + viewpoint + "-" + language
            shot.lifetime = .keepAlways
            add(shot)
            app.terminate()
        }
    }
}
