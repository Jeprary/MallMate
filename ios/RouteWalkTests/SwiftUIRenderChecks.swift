import SwiftUI
import UIKit
import XCTest
@testable import RouteWalk

/// Production SwiftUI controls in a real window. Backgrounds are synthetic; no AR session runs here.
final class SwiftUIRenderChecks: XCTestCase {
    @MainActor
    func testScanPresentationStatesInActualWindow() async throws {
        let examples: [(String, ScanPresentation)] = [
            ("英文标起点", .init(canPlace: true, language: .english)),
            ("英文继续标点", .init(pointCount: 1, canPlace: true, canUndo: true, language: .english)),
            ("英文可保存", .init(pointCount: 2, canPlace: true, canSave: true, canUndo: true, language: .english)),
            ("英文地图未就绪", .init(pointCount: 2, canPlace: true, canUndo: true, instruction: "Scan nearby walls", language: .english)),
            ("英文未识别地面", .init(canPlace: true, instruction: "Floor not found. Aim at clear floor.", requiresAttention: true, language: .english)),
            ("中文可保存", .init(pointCount: 2, canPlace: true, canSave: true, canUndo: true, language: .chinese)),
            ("英文保存中", .init(pointCount: 2, isSaving: true, language: .english)),
            ("系统引导仅退出", .init(coaching: true, language: .english))
        ]
        for (name, state) in examples {
            try await capture("SwiftUI扫描-" + name, content:
                ScanOverlayView(presentation: state, exit: {}, undo: {}, mark: { _ in }, save: {}) { EmptyView() })
        }
        try await capture("SwiftUI扫描-无障碍最大字", content:
            ScanOverlayView(presentation: .init(pointCount: 2, canPlace: true, canSave: true, canUndo: true,
                instruction: "The last point is the destination", language: .english),
                exit: {}, undo: {}, mark: { _ in }, save: {}) { EmptyView() }
                .environment(\.dynamicTypeSize, .accessibility5))
    }

    @MainActor
    func testGuidePresentationStatesInActualWindow() async throws {
        for language in [RouteLanguage.english, .chinese] {
            for localized in [false, true] {
                let title = "SwiftUI导览-\(language.rawValue)-\(localized ? "导航" : "匹配")"
                try await capture(title, content:
                    GuideOverlayView(presentation: .init(localized: localized,
                        destination: "UNIQLO\n" + language.select("Floor 1", "一楼"),
                        message: language.select("Slowly look around a scanned area.", "缓慢观察采集过的环境。"),
                        language: language), exit: {}, showReference: {}) { EmptyView() })
            }
        }
    }

    @MainActor
    private func capture<Content: View>(_ name: String, content: Content) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: ZStack {
            LinearGradient(colors: [Color(white: 0.64), Color(white: 0.34)],
                startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
            content
        })
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(150))
        host.view.layoutIfNeeded()
        XCTAssertGreaterThan(host.view.bounds.height, host.view.bounds.width)
        XCTAssertGreaterThan(host.view.safeAreaInsets.top, 0)
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(uniformTypeIdentifier: "public.png", name: name + ".png",
            payload: try XCTUnwrap(image.pngData()), userInfo: ["scope": "SwiftUI component in real window; synthetic background; no AR"])
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
