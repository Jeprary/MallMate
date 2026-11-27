import ARKit
import XCTest
@testable import RouteWalk

final class RouteLanguageChecks: XCTestCase {
    func testSystemResolvesPreferredSupportedLanguageAndFallsBackToEnglish() {
        XCTAssertEqual(RouteLanguage.resolve(["zh-Hans-CN", "en-US"]), .chinese)
        XCTAssertEqual(RouteLanguage.resolve(["fr", "zh_Hant_TW"]), .chinese)
        XCTAssertEqual(RouteLanguage.resolve(["en-GB", "zh-Hans"]), .english)
        XCTAssertEqual(RouteLanguage.resolve(["de", "ja"]), .english)
        XCTAssertEqual(RouteLanguage.resolve([]), .english)
    }

    @MainActor func testChangeRefreshesExistingSessionAndErrorsAndPreservesRoute() throws {
        let previous = RouteLanguage.preference
        defer { RouteLanguage.preference = previous }
        let savedRoute = RouteArchive.url
        let archiveBefore = try? Data(contentsOf: savedRoute)
        RouteLanguage.preference = .english
        let route = RouteSession()
        let originalSession = route.session
        let error = RouteProblem("Could not open.", "未能打开。")
        let detail = RouteText("Route unavailable.", "路线不可用。").appendingDetail(from: error)
        XCTAssertEqual(detail.localized, "Route unavailable.\nCould not open.")
        XCTAssertEqual(route.state.destinationName, "Route destination")
        if !ARWorldTrackingConfiguration.isSupported {
            route.startRecording()
            XCTAssertTrue(route.state.message.contains("iPhone"))
        }
        RouteLanguage.preference = .chinese
        XCTAssertEqual(UserDefaults.standard.string(forKey: RouteLanguage.preferenceKey), "zh")
        XCTAssertEqual(detail.localized, "路线不可用。\n未能打开。")
        XCTAssertEqual(route.state.destinationName, "路线终点")
        if !ARWorldTrackingConfiguration.isSupported {
            XCTAssertTrue(route.state.message.contains("不支持"))
        }
        XCTAssertTrue(route.session === originalSession)
        XCTAssertEqual(route.state.mode, .idle)
        XCTAssertEqual(RouteArchive.url, savedRoute)
        XCTAssertEqual(try? Data(contentsOf: savedRoute), archiveBefore)
        XCTAssertThrowsError(try RouteArchive.load(Data())) { error in
            XCTAssertEqual(error.localizedDescription, "此文件不包含可读取的 RouteWalk 路线。")
        }
        RouteLanguage.preference = .system
        XCTAssertEqual(RouteLanguage.current, RouteLanguage.resolve(Locale.preferredLanguages))
    }

    @MainActor func testSignLanguageChangesWithoutMovingItsWaypoints() throws {
        let previous = RouteLanguage.preference
        defer { RouteLanguage.preference = previous }
        let points: [SIMD3<Float>] = [SIMD3(0, 0, 2), .zero, SIMD3(2, 0, 0)]
        RouteLanguage.preference = .english
        let signs = RouteSignLayout.descriptors(points: points, isGuidance: true)
        let positions = signs.map(\.position)
        XCTAssertEqual(signs.map(\.title), ["Start", "Turn right", "Destination"])
        RouteLanguage.preference = .chinese
        let translated = RouteSignLayout.descriptors(points: points, isGuidance: true)
        XCTAssertEqual(translated.map(\.title), ["起点", "右转", "终点"])
        XCTAssertEqual(translated.map(\.position), positions)
        let destination = RouteSignLayout.descriptors(points: points, isGuidance: true, destinationLabel: "优衣库")
        XCTAssertEqual(destination.last?.title, "优衣库")
    }
}
