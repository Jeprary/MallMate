import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let routeWalkMap = UTType(exportedAs: "com.mallmate.routewalk.map")
}

struct RouteRootView: View {
    @Bindable var model: RouteAppModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    @State private var showsPreparationProgress = false

    var body: some View {
        ZStack {
            if model.presentation.cameraMounted { cameraLayer.zIndex(0) }
            ZStack {
                Rectangle().fill(.background).ignoresSafeArea()
                RoutesHomeView(model: model)
            }
            .opacity(model.presentation.homeOpacity)
            .allowsHitTesting(model.presentation.phase == .routes)
            .accessibilityHidden(model.presentation.phase != .routes)
            .zIndex(1)
            if model.presentation.phase == .preparing && showsPreparationProgress {
                RouteCameraPreparingView(title: model.text("Opening camera…", "正在打开相机…"))
                    .zIndex(2)
            }
        }
        .task(id: preparationTaskID) {
            showsPreparationProgress = false
            guard model.presentation.phase == .preparing, scenePhase == .active else { return }
            let id = model.presentation.cameraID
            do {
                // Project UX thresholds: avoid a loading flash; recover a stalled startup.
                try await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, model.presentation.cameraID == id,
                      model.presentation.phase == .preparing, scenePhase == .active else { return }
                showsPreparationProgress = true
                try await Task.sleep(for: .seconds(14))
                guard !Task.isCancelled else { return }
                model.cameraPreparationTimedOut(id: id)
            } catch { /* Phase, scene, or camera changes cancel the old wait. */ }
        }
        .sheet(isPresented: $model.showsLibrary, onDismiss: model.libraryDidDismiss) {
            RouteLibraryView(model: model, isModal: true).onAppear(perform: model.libraryDidPresent)
        }
        .modifier(RouteNamePromptPresenter(model: model, active: !model.libraryIsPresented))
        .sheet(isPresented: $model.showsReferencePhoto) {
            NavigationStack {
                Group {
                    if let image = model.route.entrancePhoto {
                        Image(decorative: image, scale: 1).resizable().scaledToFit().padding()
                    }
                }
                .navigationTitle(model.text("Reference view", "参考视角"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(model.text("Done", "完成"), systemImage: "xmark") { model.showsReferencePhoto = false }
                            .labelStyle(.iconOnly)
                    }
                }
            }
        }
        .fileImporter(isPresented: $model.showsImporter, allowedContentTypes: [.routeWalkMap]) { model.receiveImport($0) }
        .confirmationDialog(model.promptTitle, isPresented: Binding(
            get: { model.prompt != nil && model.prompt != .unscannedRoute },
            set: { if !$0 && model.prompt != .unscannedRoute { model.cancelPrompt() } }), titleVisibility: .visible) {
                promptActions
            } message: { if !model.promptMessage.isEmpty { Text(model.promptMessage) } }
        .modifier(RouteNoticePresenter(model: model, active: !model.libraryIsPresented && !model.nameEditorIsPresented
            && !model.presentation.isTransitioning && scenePhase == .active && model.prompt != .unscannedRoute))
        .background {
            RouteDraftAlertPresenter(model: model,
                active: !model.libraryIsPresented && !model.nameEditorIsPresented
                    && !model.presentation.isTransitioning && scenePhase == .active,
                requested: model.prompt == .unscannedRoute)
                .frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
        }
        .onChange(of: model.route.state.isLocalized) { _, _ in model.observeLocalization() }
        .onChange(of: model.route.state.hasArrived) { _, arrived in if arrived { model.visitorArrived() } }
        .onChange(of: model.webReturnRequest) { _, request in
            guard let request, let url = model.visitorReturnURL else { return }
            openURL(url) { accepted in
                Task { @MainActor in model.webReturnFinished(accepted, request: request) }
            }
        }
        .onChange(of: model.route.state.mode, initial: true) { _, mode in
            if mode == .idle { model.presentation.engineBecameIdle() }
            else { model.presentation.presentCamera() }
        }
        .onChange(of: model.route.hasCameraFrame, initial: true) { _, available in
            model.presentation.cameraFrameChanged(available)
        }
        .onChange(of: reduceMotion, initial: true) { _, value in model.presentation.setReduceMotion(value) }
        .onChange(of: scenePhase, initial: true) { _, phase in model.setSceneActive(phase == .active) }
        .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in model.systemLanguageChanged() }
        .onDisappear { model.presentation.completePendingReturn() }
    }

    private var preparationTaskID: String {
        "\(model.presentation.cameraID)-\(model.presentation.phase.rawValue)-\(scenePhase)"
    }

    private var cameraLayer: some View {
        let id = model.presentation.cameraID
        let session = model.route
        return CameraRouteView(model: model, controlsOpacity: model.presentation.controlsOpacity,
            controlsEnabled: model.presentation.phase == .entering || model.presentation.phase == .camera,
            preferDarkAppearance: model.presentation.phase == .camera,
            onSurfaceReady: { ready in model.cameraSurfacePrepared(session: session, id: id, ready: ready) })
            .id(id)
            .onAppear {
                model.presentation.surfaceDidMount(id: id)
                model.presentation.cameraFrameChanged(session.hasCameraFrame)
            }
            .accessibilityHidden(model.presentation.phase == .preparing || model.presentation.phase == .leaving)
    }

    @ViewBuilder private var promptActions: some View {
        switch model.prompt {
        case .unscannedRoute: EmptyView()
        case .deleteRoute:
            Button(model.text("Delete", "删除"), role: .destructive, action: model.confirmDelete)
                .accessibilityIdentifier("route.confirmDelete")
            Button(model.text("Cancel", "取消"), role: .cancel) { model.cancelPrompt() }
        case .exitScan:
            Button(model.text("End scan", "结束采集"), role: .destructive) { model.discardScan() }
            Button(model.text("Keep scanning", "继续采集"), role: .cancel) { model.cancelPrompt() }
        case .restartScan:
            Button(model.text("Restart scan", "重新采集"), role: .destructive) { model.discardScan(restart: true) }
            Button(model.text("Keep scanning", "继续采集"), role: .cancel) { model.cancelPrompt() }
        case .replacePractice:
            Button(model.text("Save route", "保存路线"), role: .destructive) { model.finishSaving(destinationID: nil) }
            Button(model.text("Keep scanning", "继续采集"), role: .cancel) { model.cancelPrompt() }
        case .saveDestination:
            Button(model.text("UNIQLO, Taicang Wanda, Floor 1", "太仓万达一楼优衣库")) { model.finishSaving(destinationID: RouteAppModel.destinationID) }
            Button(model.text("Another destination", "其他目的地")) { model.finishSaving(destinationID: nil) }
            Button(model.text("Keep scanning", "继续采集"), role: .cancel) { model.cancelPrompt() }
        case .replaceImport:
            Button(model.text("Import and replace", "导入并替换"), role: .destructive) { model.performPendingImport() }
            Button(model.text("Cancel", "取消"), role: .cancel) { model.cancelPrompt() }
        case .exportFrame:
            Button(model.text("Export", "导出")) { model.confirmFrameExport() }
            Button(model.text("Cancel", "取消"), role: .cancel) { model.cancelPrompt() }
        case .trialFeedback:
            if model.hasLocalizedInVisit {
                Button(model.text("Signs aligned", "路标与实地对齐")) { model.finishTrial("aligned_by_observer") }
                Button(model.text("Position or direction was off", "位置或方向有偏差")) { model.finishTrial("offset_by_observer") }
            } else {
                Button(model.text("Route did not relocalize", "未能找回路线")) { model.finishTrial("not_localized") }
            }
            Button(model.text("Keep navigating", "继续导航"), role: .cancel) { model.cancelPrompt() }
        case .failedTrial:
            Button(model.text("Try again", "重试")) { model.retryTrial() }
            Button(model.text("Exit without report", "退出并放弃报告"), role: .destructive) { model.abandonTrial() }
            Button(model.text("Keep navigating", "继续导航"), role: .cancel) { model.cancelPrompt() }
        case nil: EmptyView()
        }
    }
}

/// Ordinary notices remain SwiftUI alerts, owned by the current presentation.
struct RouteNoticePresenter: ViewModifier {
    @Bindable var model: RouteAppModel
    let active: Bool
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        let notice = model.notice
        return content.alert(notice?.title ?? "", isPresented: Binding(
            get: { active && model.notice != nil },
            set: { value in
                if active, !value, let id = notice?.id { dismissNotice(id) }
            })) {
                if notice?.offersSettings == true {
                    Button(model.text("Open Settings", "打开设置")) {
                        if let id = notice?.id { dismissNotice(id) }
                        if let url = URL(string: "app-settings:") { openURL(url) }
                    }
                    Button(model.text("Cancel", "取消"), role: .cancel) {
                        if let id = notice?.id { dismissNotice(id) }
                    }
                } else {
                    Button(model.text("OK", "好"), role: .cancel) {
                        if let id = notice?.id { dismissNotice(id) }
                    }
                }
            } message: { Text(notice?.message ?? "") }
    }

    private func dismissNotice(_ id: UUID) {
        if model.notice?.id == id { model.notice = nil }
    }
}

struct RouteLanguageMenu: View {
    @Bindable var model: RouteAppModel
    var body: some View {
        Menu(model.text("Language", "语言")) {
            Picker(model.text("Language", "语言"), selection: $model.language) {
                Text(model.text("System default", "跟随系统")).tag(RouteLanguage.system)
                Text("English").tag(RouteLanguage.english)
                Text("中文").tag(RouteLanguage.chinese)
            }
            .pickerStyle(.inline)
        }
    }
}
