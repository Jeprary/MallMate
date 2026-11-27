#if DEBUG
import SwiftUI

/// Screenshot fixtures exercise the production overlays without starting a camera or an AR session.
struct RouteInterfacePreview: View {
    let scenario: String
    private var language: RouteLanguage {
        ProcessInfo.processInfo.arguments.contains("--preview-language=zh") ? .chinese : .english
    }

    var body: some View {
        ZStack {
            RoutePreviewRoom().ignoresSafeArea()
            if scenario == "opening" {
                RouteCameraPreparingView(title: language.select("Opening camera…", "正在打开相机…"))
            } else if scenario.hasPrefix("review") {
                RouteReviewOverlayView(presentation: RouteReviewPresentation(coaching: scenario == "review-coaching",
                    message: scenario == "review-failed" ? language.select("Tracking stopped", "追踪已停止")
                        : (scenario == "review-recovering" ? language.select("Look around the scanned area", "扫视采集过的环境") : ""),
                    language: language), exit: {}) {
                        if scenario == "review-failed" { RetryCameraButton(language: language, retry: {}) }
                    }
            } else if scenario.hasPrefix("guide") {
                GuideOverlayView(presentation: GuidePresentation(localized: scenario == "guide-following",
                    recovering: scenario == "guide-recovering", coaching: scenario == "guide-coaching",
                    sessionFailed: scenario == "guide-failed",
                    destination: language.select("Route destination", "路线终点"),
                    message: scenario == "guide-failed" ? language.select("Tracking stopped", "追踪已停止")
                        : language.select("Slowly look around a scanned area.", "缓慢观察采集过的周围环境。"),
                    language: language), exit: {}, showReference: {}) { EmptyView() }
                    .overlay(alignment: .topTrailing) {
                        if scenario == "guide-failed" {
                            GuideRecoveryMenu(language: language) { RetryCameraButton(language: language, retry: {}) }
                        }
                    }
            } else {
                ScanOverlayView(presentation: scan, exit: {}, undo: {}, mark: { _ in }, save: {}) {
                    if scan.sessionFailed { RetryCameraButton(language: language, retry: {}) }
                }
            }
            Text(language.select("Interface preview\nCamera off", "界面预览\n相机未启动"))
                    .font(.caption2.weight(.medium)).padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.black.opacity(0.42), in: Capsule()).foregroundStyle(.white)
                    .multilineTextAlignment(.center).dynamicTypeSize(.medium)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .offset(y: -65)
            .allowsHitTesting(false).accessibilityHidden(true)
        }
        .environment(\.dynamicTypeSize, ProcessInfo.processInfo.arguments.contains("--preview-largest-text") ? .accessibility5 : .large)
        .preferredColorScheme(.dark)
    }

    private var scan: ScanPresentation {
        var value = ScanPresentation(language: language)
        switch scenario {
        case "destination":
            value.canPlace = true
            value.instruction = language.select("Place destination", "放置终点")
        case "waiting":
            value.instruction = language.select("Waiting for tracking…", "等待追踪就绪…")
            value.requiresAttention = true
        case "one":
            value.pointCount = 1; value.canPlace = true; value.canUndo = true
            value.mapIndicator = .limited
        case "ready":
            value.pointCount = 2; value.canPlace = true; value.canUndo = true; value.canSave = true
            value.mapIndicator = .mapped
        case "extending":
            value.pointCount = 2; value.canPlace = true; value.canUndo = true; value.canSave = true
            value.mapIndicator = .extending
        case "floor":
            value.canPlace = true
            value.instruction = language.select("Floor not found. Aim at clear floor.", "未识别到地面，请对准空地。")
            value.requiresAttention = true
        case "mapping":
            value.pointCount = 2; value.canPlace = true; value.canUndo = true
            value.mapIndicator = .limited
        case "interrupted":
            value.pointCount = 2
            value.instruction = language.select("Camera interrupted. Resume scanning.", "相机已中断，请恢复采集。")
            value.requiresAttention = true
        case "failed":
            value.pointCount = 2
            value.sessionFailed = true
            // Keep a stale mapped observation to verify that a stopped camera never appears ready.
            value.mapIndicator = .mapped
            value.mappingStatus = language.select("Current area mapped", "当前区域已建图")
            value.instruction = language.select("Tracking stopped.", "追踪已停止。")
            value.requiresAttention = true
        case "coaching": value.coaching = true
        case "saving":
            value.pointCount = 2; value.isSaving = true
            value.mapIndicator = .mapped
        default: value.canPlace = true
        }
        return value
    }
}

struct RoutePreviewRoom: View {
    var body: some View {
        Canvas { context, size in
            let floor = size.height * 0.48
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.68)))
            context.fill(Path(CGRect(x: size.width * 0.17, y: size.height * 0.18, width: size.width * 0.22,
                                     height: floor - size.height * 0.18)), with: .color(Color(white: 0.49)))
            context.fill(Path(CGRect(x: 0, y: floor, width: size.width, height: size.height - floor)), with: .color(Color(white: 0.41)))
            var tiles = Path()
            for column in -3...3 {
                let offset = CGFloat(column) * size.width / 3
                tiles.move(to: CGPoint(x: size.width * 0.58 + offset * 0.15, y: floor))
                tiles.addLine(to: CGPoint(x: size.width * 0.58 + offset, y: size.height))
            }
            for distance in [0.05, 0.13, 0.26, 0.48] as [CGFloat] {
                let y = floor + distance * size.height
                tiles.move(to: CGPoint(x: 0, y: y)); tiles.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(tiles, with: .color(Color(white: 0.32)), lineWidth: 1)
        }
    }
}
#endif
