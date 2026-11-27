import XCTest

@MainActor
final class RouteLibraryUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw XCTSkip("Synthetic route-library fixtures run only in the simulator.")
        #endif
    }

    func testFlatListHasOneTitleAndNewRouteInToolbar() throws {
        let app = try openRoutes()
        XCTAssertFalse(app.navigationBars["MallMate"].exists)
        XCTAssertFalse(app.buttons["home.myRoutes"].exists)
        let add = app.buttons["practiceRoutes.add"]
        XCTAssertTrue(add.isHittable)
        XCTAssertLessThan(add.frame.minY, 140)
        XCTAssertEqual(app.buttons.matching(identifier: "practiceRoutes.add").count, 1)
        attach(app, "平铺路线-首页-英文")
    }

    func testCreateRenameAndReopenVisibleRoutesInBothLanguages() throws {
        let app = try openRoutes()
        let first = try create("Desk to door " + String(UUID().uuidString.prefix(4)), in: app)
        let second = try create("Window to bed " + String(UUID().uuidString.prefix(4)), in: app)
        XCTAssertTrue(row(first, app).exists && row(second, app).exists)
        row(second, app).swipeLeft()
        app.buttons["Rename"].firstMatch.tap()
        let renameAlert = app.alerts["Rename route"]
        XCTAssertTrue(renameAlert.waitForExistence(timeout: 4))
        let field = renameAlert.textFields.firstMatch
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: second.count))
        let renamed = "Door to desk " + String(UUID().uuidString.prefix(4))
        field.typeText(renamed)
        XCTAssertEqual(field.value as? String, renamed)
        renameAlert.buttons["Save"].firstMatch.tap()
        XCTAssertTrue(row(renamed, app).waitForExistence(timeout: 5))
        attach(app, "平铺路线-两条路线-英文")
        app.terminate(); app.launch()
        XCTAssertTrue(app.navigationBars["Routes"].waitForExistence(timeout: 6))
        XCTAssertTrue(row(first, app).exists && row(renamed, app).exists)
        XCUIDevice.shared.system.open(try XCTUnwrap(URL(string: "mallmate-route://practice?lang=zh")))
        XCTAssertTrue(app.navigationBars["路线"].waitForExistence(timeout: 6))
        XCTAssertTrue(row(first, app).exists && row(renamed, app).exists)
        XCTAssertTrue(app.staticTexts["未保存"].firstMatch.exists)
        attach(app, "平铺路线-两条路线-中文")
    }

    func testMoreContainsImportLanguageWithoutMallRoute() throws {
        let app = try openRoutes()
        app.buttons["home.language"].tap()
        for title in ["Import route", "Language"] {
            XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", title)).firstMatch.waitForExistence(timeout: 4))
        }
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Mall route")).firstMatch.exists)
        attach(app, "平铺路线-更多菜单")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.navigationBars["Routes"].waitForExistence(timeout: 6))
        XCUIDevice.shared.system.open(try XCTUnwrap(URL(string: "mallmate-route://practice?lang=zh")))
        XCTAssertTrue(app.navigationBars["路线"].waitForExistence(timeout: 6))
        app.buttons["home.language"].tap()
        for title in ["导入路线", "语言"] {
            XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", title)).firstMatch.waitForExistence(timeout: 4))
        }
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "商场路线")).firstMatch.exists)
        attach(app, "平铺路线-更多菜单-中文")
    }

    func testDraftRouteRequiresExplicitScanConfirmationAndCancelPreservesList() throws {
        let app = try openRoutes()
        let name = try create("Draft consent " + String(UUID().uuidString.prefix(8)), in: app)
        row(name, app).tap()
        let confirmation = app.alerts["No saved map"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 4), app.debugDescription)
        XCTAssertTrue(confirmation.buttons["Start scanning"].firstMatch.isHittable)
        XCTAssertTrue(confirmation.buttons["Cancel"].firstMatch.isHittable)
        XCTAssertFalse(app.alerts["AR-compatible iPhone required"].exists)
        XCTAssertFalse(app.buttons["record.exit"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["route.preparing"].exists)
        attach(app, "未采集路线-先确认开始采集")
        confirmation.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(confirmation.waitForNonExistence(timeout: 3))
        XCTAssertTrue(row(name, app).exists)
        XCTAssertTrue(app.buttons["practiceRoutes.add"].isHittable)
        XCTAssertFalse(app.buttons["record.exit"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["route.preparing"].exists)
        attach(app, "未采集路线-取消后留在列表")
        XCUIDevice.shared.system.open(try XCTUnwrap(URL(string: "mallmate-route://practice?lang=zh")))
        XCTAssertTrue(app.navigationBars["路线"].waitForExistence(timeout: 6))
        row(name, app).tap()
        let chineseConfirmation = app.alerts["尚未保存地图"]
        XCTAssertTrue(chineseConfirmation.waitForExistence(timeout: 4), app.debugDescription)
        XCTAssertTrue(chineseConfirmation.buttons["开始采集"].firstMatch.isHittable)
        XCTAssertTrue(chineseConfirmation.buttons["取消"].firstMatch.isHittable)
        XCTAssertFalse(app.buttons["record.exit"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["route.preparing"].exists)
        attach(app, "未采集路线-先确认开始采集-中文")
        chineseConfirmation.buttons["取消"].firstMatch.tap()
        XCTAssertTrue(chineseConfirmation.waitForNonExistence(timeout: 3))
        XCTAssertTrue(row(name, app).exists)
        XCTAssertTrue(app.buttons["practiceRoutes.add"].isHittable)
        XCTAssertFalse(app.buttons["record.exit"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["route.preparing"].exists)
        attach(app, "未采集路线-取消后留在列表-中文")
        row(name, app).tap()
        XCTAssertTrue(chineseConfirmation.waitForExistence(timeout: 4), app.debugDescription)
        chineseConfirmation.buttons["开始采集"].firstMatch.tap()
        let unsupported = app.alerts["需要支持 AR 的 iPhone"]
        XCTAssertTrue(unsupported.waitForExistence(timeout: 6), app.debugDescription)
        attach(app, "未采集路线-明确开始后的真实设备限制")
        unsupported.buttons["好"].firstMatch.tap()
    }

    func testNewRouteUsesNativeNamingAlert() throws {
        let app = try openRoutes()
        app.buttons["practiceRoutes.add"].tap()
        let alert = app.alerts["New route"]
        XCTAssertTrue(alert.waitForExistence(timeout: 4))
        let field = alert.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 4))
        XCTAssertTrue(field.isHittable)
        XCTAssertTrue(alert.buttons["Cancel"].firstMatch.isHittable)
        XCTAssertTrue(alert.buttons["Create"].firstMatch.exists)
        XCTAssertFalse(alert.buttons["Create"].firstMatch.isEnabled)
        attach(app, "路线命名-系统原生弹窗")
        alert.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(app.buttons["practiceRoutes.add"].waitForExistence(timeout: 4))
    }

    func testDuplicateNameErrorPreservesInputForRetry() throws {
        let app = try openRoutes()
        let suffix = String(UUID().uuidString.prefix(8))
        let name = try create("Name retry A " + suffix, in: app)
        let other = try create("Name retry B " + suffix, in: app)
        row(other, app).swipeLeft()
        app.buttons["Rename"].firstMatch.tap()
        let naming = app.alerts["Rename route"]
        XCTAssertTrue(naming.waitForExistence(timeout: 4))
        let field = naming.textFields.firstMatch
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: other.count))
        field.typeText(name)
        naming.buttons["Save"].firstMatch.tap()
        let error = app.alerts["Routes"]
        XCTAssertTrue(error.waitForExistence(timeout: 5), app.debugDescription)
        error.buttons["OK"].firstMatch.tap()
        XCTAssertTrue(naming.waitForExistence(timeout: 4), app.debugDescription)
        XCTAssertEqual(naming.textFields.firstMatch.value as? String, name)
        attach(app, "路线命名-错误后保留输入")
        naming.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(row(name, app).exists)
        XCTAssertTrue(row(other, app).exists)
    }

    func testDeleteTemporaryRouteRequiresConfirmationAndPreservesOtherRoute() throws {
        #if targetEnvironment(simulator)
        let app = try openRoutes()
        let suffix = String(UUID().uuidString.prefix(8))
        let first = try create("Delete test A " + suffix, in: app)
        let second = try create("Delete test B " + suffix, in: app)
        let delete = try deleteButton(for: first, in: app)
        exposeDelete(delete, for: first, in: app)
        delete.tap()
        let confirm = app.buttons["route.confirmDelete"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 4))
        attach(app, "路线删除-确认前")
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.exists && cancel.isHittable { cancel.tap() }
        else { app.navigationBars["Routes"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 3))
        XCTAssertTrue(row(first, app).exists)
        XCTAssertTrue(row(second, app).exists)
        attach(app, "路线删除-取消后保留两条路线")
        exposeDelete(delete, for: first, in: app)
        attach(app, "路线删除-再次显示目标行删除入口")
        delete.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 4), app.debugDescription)
        confirm.tap()
        XCTAssertTrue(row(first, app).waitForNonExistence(timeout: 5))
        XCTAssertTrue(row(second, app).exists)
        attach(app, "路线删除-仅移除确认的临时路线")
        #else
        throw XCTSkip("Route deletion fixtures run only in the simulator.")
        #endif
    }

    private func openRoutes() throws -> XCUIApplication {
        let app = XCUIApplication(); app.launch()
        XCUIDevice.shared.system.open(try XCTUnwrap(URL(string: "mallmate-route://practice?lang=en")))
        XCTAssertTrue(app.navigationBars["Routes"].waitForExistence(timeout: 7), app.debugDescription)
        XCTAssertTrue(app.buttons["practiceRoutes.add"].waitForExistence(timeout: 4))
        return app
    }
    private func row(_ name: String, _ app: XCUIApplication) -> XCUIElement {
        app.cells.containing(.staticText, identifier: name).firstMatch
    }
    private func create(_ name: String, in app: XCUIApplication) throws -> String {
        app.buttons["practiceRoutes.add"].tap()
        let alert = app.alerts["New route"]
        XCTAssertTrue(alert.waitForExistence(timeout: 4), app.debugDescription)
        // Native alert fields do not forward SwiftUI identifiers on every supported OS.
        let field = alert.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 4), app.debugDescription)
        field.tap(); field.typeText(name)
        alert.buttons["Create"].firstMatch.tap()
        let unsupported = app.alerts["AR-compatible iPhone required"]
        XCTAssertTrue(unsupported.waitForExistence(timeout: 6), app.debugDescription)
        unsupported.buttons["OK"].firstMatch.tap()
        XCTAssertTrue(row(name, app).waitForExistence(timeout: 4), app.debugDescription)
        return name
    }

    private func deleteButton(for name: String, in app: XCUIApplication) throws -> XCUIElement {
        let cell = row(name, app)
        let prefix = "practiceRoutes."
        let identifiers = [cell.identifier] + cell.buttons.allElementsBoundByIndex.map(\.identifier)
        let identifier = try XCTUnwrap(identifiers.first {
            $0.hasPrefix(prefix) && UUID(uuidString: String($0.dropFirst(prefix.count))) != nil
        }, "Route row must expose its UUID identifier: " + app.debugDescription)
        return app.buttons["practiceRoutes.delete." + String(identifier.dropFirst(prefix.count))].firstMatch
    }

    private func exposeDelete(_ button: XCUIElement, for name: String, in app: XCUIApplication) {
        if !button.isHittable { row(name, app).swipeLeft() }
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: button)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 4), .completed,
                       "The target route's delete action must be hittable: " + app.debugDescription)
    }
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name
        shot.lifetime = .keepAlways; add(shot)
    }
}
