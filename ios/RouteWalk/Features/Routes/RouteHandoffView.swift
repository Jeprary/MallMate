import SwiftUI

/// A web handoff selects a local route. Camera permission and navigation begin only on a tap.
struct RouteHandoffView: View {
    @Bindable var model: RouteAppModel

    var body: some View {
        RouteHandoffContent(name: model.handoffRoute?.name ?? model.homeTitle,
            language: model.resolvedLanguage, busy: model.isBusy,
            canStart: model.canGuide, close: model.dismissRouteHandoff, start: model.startHandoffNavigation) {
                RouteLanguageMenu(model: model)
            }
    }
}

private struct RouteHandoffContent<Options: View>: View {
    let name: String
    let language: RouteLanguage
    var busy = false
    var canStart = true
    let close: () -> Void
    let start: () -> Void
    @ViewBuilder let options: () -> Options

    var body: some View {
        NavigationStack {
          GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 28) {
                    Image(systemName: "location.north.circle.fill")
                        .font(.system(size: 56)).symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.tint).accessibilityHidden(true)
                    Text(name).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("handoff.title")
                    if !canStart {
                        Text(language.select("Route unavailable", "路线不可用")).foregroundStyle(.secondary)
                    }
                    Button(action: canStart ? start : close) {
                        Text(canStart ? language.select("Start navigation", "开始导航") : language.select("Return to website", "返回网页"))
                            .lineLimit(nil).multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.glassProminent).controlSize(.large).disabled(busy)
                    .accessibilityIdentifier(canStart ? "handoff.start" : "visitor.return")
                }
                .frame(maxWidth: 360).padding(28)
                .frame(maxWidth: .infinity).frame(minHeight: geometry.size.height)
            }
          }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(language.select("Close", "关闭"), systemImage: "xmark", action: close)
                        .labelStyle(.iconOnly).disabled(busy).accessibilityIdentifier("handoff.close")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu(content: options) {
                        Label(language.select("More", "更多"), systemImage: "ellipsis")
                    }.labelStyle(.iconOnly).disabled(busy)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct RouteVisitorCompletionView: View {
    @Bindable var model: RouteAppModel
    var body: some View {
        VisitorCompletionContent(name: model.handoffRoute?.name ?? "",
            language: model.resolvedLanguage, completion: model.visitorCompletion ?? .ended,
            returning: model.returningToWeb, failed: model.webReturnFailed,
            canReturn: model.visitorReturnURL != nil,
            returnToWeb: model.returnVisitorToWeb)
    }
}

private struct VisitorCompletionContent: View {
    let name: String
    let language: RouteLanguage
    let completion: RouteAppModel.VisitorCompletion
    var returning = false
    var failed = false
    var canReturn = true
    let returnToWeb: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: completion == .arrived ? "checkmark.circle.fill" : "arrow.up.right.circle.fill")
                        .font(.system(size: 56)).symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.tint).accessibilityHidden(true)
                    Text(title).font(.title.weight(.semibold)).multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader).accessibilityIdentifier("visitor.completion")
                    if !name.isEmpty { Text(name).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                    if !canReturn {
                        Text(language.select("Open the original page in your browser.", "请在浏览器中重新打开原网页。"))
                            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    if failed {
                        Text(language.select("Could not open the page. Try again.", "网页未能打开，请重试。"))
                            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            .accessibilityIdentifier("visitor.returnError")
                    }
                    Button(action: returnToWeb) {
                        Text(language.select("Return to website", "返回网页"))
                            .lineLimit(nil).multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.glassProminent).controlSize(.large).disabled(returning || !canReturn)
                    .accessibilityIdentifier("visitor.return")
                }
                .frame(maxWidth: 360).padding(28)
                .frame(maxWidth: .infinity).frame(minHeight: geometry.size.height)
            }
        }
    }

    private var title: String {
        switch completion {
        case .arrived: language.select("Arrived", "已到达")
        case .ended: language.select("Navigation ended", "导航已结束")
        case .unavailable: language.select("Route unavailable", "路线不可用")
        }
    }
}

#if DEBUG
struct RouteHandoffPreview: View {
    private var language: RouteLanguage {
        ProcessInfo.processInfo.arguments.contains("--preview-language=zh") ? .chinese : .english
    }

    var body: some View {
      Group {
        if let state = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--visitor-completion=") }) {
            VisitorCompletionContent(name: "EF F2 2026.11.12", language: language,
                completion: state.hasSuffix("arrived") ? .arrived : .ended,
                failed: state.hasSuffix("failed"), returnToWeb: {})
        } else {
        RouteHandoffContent(name: "EF F2 2026.11.12", language: language, close: {}, start: {}) {
            Text(language.select("Language", "语言"))
        }
        }
      }
        .tint(Color(red: 0.07, green: 0.37, blue: 0.30))
        .environment(\.dynamicTypeSize, ProcessInfo.processInfo.arguments.contains("--preview-largest-text") ? .accessibility5 : .large)
        .safeAreaInset(edge: .bottom) {
          if !ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--visitor-completion=") }) {
            Text(language.select("Camera off", "相机未启动")).font(.caption)
                .foregroundStyle(.secondary).padding(.bottom, 12).allowsHitTesting(false)
          }
        }
    }
}
#endif
