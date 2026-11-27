import SwiftUI

struct CameraRouteView: View {
    @Bindable var model: RouteAppModel
    var controlsOpacity = 1.0
    var controlsEnabled = true
    var preferDarkAppearance = true
    var onSurfaceReady: (@MainActor @Sendable (Bool) -> Void)?

    var body: some View {
        ZStack {
            RouteARSurface(session: model.route, onPrepared: onSurfaceReady).ignoresSafeArea()
            Group {
            if model.route.state.mode == .recording {
                ScanOverlayView(presentation: ScanPresentation(pointCount: model.route.state.pointCount,
                    canPlace: model.route.state.canPlacePoint, canSave: model.route.state.canSave,
                    canUndo: model.route.state.canUndo, isSaving: model.route.state.isSaving,
                    coaching: model.route.coachingActive, instruction: model.route.state.recordingMessage,
                    mappingStatus: model.route.state.mappingStatusText,
                    mapIndicator: mapIndicator, requiresAttention: model.route.state.recordingNeedsAttention,
                    sessionFailed: model.route.state.isSessionFailed,
                    language: model.resolvedLanguage), exit: model.exit,
                    undo: model.undoPoint, mark: { model.markPoint(viewport: $0) }, save: model.save) {
                        scanMenu
                    }
            } else if model.route.state.mode == .reviewing {
                RouteReviewOverlayView(presentation: .init(coaching: model.route.coachingActive,
                    message: model.route.state.isSceneReady ? "" : model.route.state.message,
                    language: model.resolvedLanguage), exit: model.exit) {
                        recoveryMenuAction
                        Button(model.text("Start navigation", "开始导航"), systemImage: "location.north.fill", action: model.navigateFromReview)
                        Button(model.text("Scan again", "重新采集"), systemImage: "arrow.clockwise", action: model.scanAgainFromReview)
                        if model.currentLibraryEntry != nil {
                            Button(model.text("Delete route", "删除路线"), systemImage: "trash", role: .destructive,
                                   action: model.requestDeleteCurrentRoute)
                        }
                        Divider()
                        signPositionControls
                        RouteLanguageMenu(model: model)
                    }
            } else {
                GuideOverlayView(presentation: GuidePresentation(localized: model.route.state.isLocalized,
                    recovering: model.hasLocalizedInVisit && !model.route.state.isLocalized,
                    coaching: model.route.coachingActive,
                    sessionFailed: model.route.state.isSessionFailed,
                    destination: model.route.state.destinationName + (model.route.state.destinationID == RouteAppModel.destinationID
                        ? model.text("\nFloor 1", "\n一楼") : ""), message: model.route.state.message,
                    photo: model.route.entrancePhoto, language: model.resolvedLanguage),
                    exit: model.exit, showReference: {
                        if model.presentation.controlsEnabled { model.showsReferencePhoto = true }
                    }) { placementMenu }
                    .overlay(alignment: .topTrailing) {
                        if model.route.state.isSessionFailed, !model.route.state.isLocalized, !model.route.coachingActive {
                            GuideRecoveryMenu(language: model.resolvedLanguage) { placementMenu }
                        }
                    }
            }
            }
            .opacity(controlsOpacity)
            .allowsHitTesting(controlsEnabled)
        }
        .persistentSystemOverlays(.visible)
        .preferredColorScheme(preferDarkAppearance ? .dark : nil)
        .statusBarHidden(false)
    }

    private var mapIndicator: ScanPresentation.MapIndicator {
        switch model.route.state.mappingState {
        case .unavailable: .unavailable
        case .limited: .limited
        case .extending: .extending
        case .mapped: .mapped
        }
    }

    @ViewBuilder private var scanMenu: some View {
        recoveryMenuAction
        Button(model.text(model.route.state.hasEntrancePhoto ? "Retake reference photo (optional)" : "Reference photo (optional)",
                          model.route.state.hasEntrancePhoto ? "重拍参考照（可选）" : "拍参考照（可选）"), systemImage: "camera") {
            model.route.captureEntrancePhoto()
        }
        .disabled(model.route.state.pointCount == 0 || !model.route.state.canCaptureComputerFrame)
        Menu {
            if model.route.state.computerFrameCount > 0 {
                Text(model.text("\(model.route.state.computerFrameCount) frames exported", "已导出 \(model.route.state.computerFrameCount) 帧"))
            }
            Button(model.text(model.route.state.isWritingComputerFrame ? "Writing frame…" : "Export camera frame",
                              model.route.state.isWritingComputerFrame ? "正在写入帧…" : "导出相机帧"), systemImage: "square.and.arrow.up",
                   action: model.captureFrame)
                .disabled(!model.route.state.canCaptureComputerFrame)
            Toggle(model.text("Feature points", "特征点"), isOn: Binding(
                get: { model.route.state.showsFeaturePoints }, set: { model.route.setFeaturePointsVisible($0) }))
            Button(model.text("Export location", "导出位置"), systemImage: "folder") {
                model.notice = RouteNotice(title: model.text("Exported camera frames", "已导出的相机帧"),
                    message: model.text("Files → On My iPhone → RouteWalk → ", "文件 → 我的 iPhone → RouteWalk → ") + "电脑建图素材")
            }
        } label: { Label(model.text("Advanced", "高级"), systemImage: "slider.horizontal.3") }
        RouteLanguageMenu(model: model)
    }

    @ViewBuilder private var placementMenu: some View {
        recoveryMenuAction
        signPositionControls
        RouteLanguageMenu(model: model)
        if !model.visitorSessionActive {
            Button(model.text("Record result and end", "记录效果并结束"), systemImage: "checkmark.bubble") { model.prompt = .trialFeedback }
        }
    }

    @ViewBuilder private var recoveryMenuAction: some View {
        if model.route.state.isSessionFailed {
            RetryCameraButton(language: model.resolvedLanguage) {
                if model.route.state.isSessionFailed { model.route.restartTracking() }
            }
        }
    }

    @ViewBuilder private var signPositionControls: some View {
        Picker(model.text("Side", "位置"), selection: Binding(
            get: { model.signPlacement.sideOffset }, set: { model.updatePlacement(side: $0) })) {
            Text(model.text("Left side", "左侧")).tag(Float(-0.5))
            Text(model.text("Right side", "右侧")).tag(Float(0.5))
        }
        Picker(model.text("Height above floor", "离地高度"), selection: Binding(
            get: { model.signPlacement.height }, set: { model.updatePlacement(height: $0) })) {
            ForEach([Float(0.8), 1.1, 1.4], id: \.self) { height in
                Text(RouteLanguage.format("%.1f m", "%.1f 米", height)).tag(height)
            }
        }
    }
}

/// The recovery action is also rendered by camera-off interface fixtures.
struct RetryCameraButton: View {
    let language: RouteLanguage
    let retry: () -> Void

    var body: some View {
        Button(language.select("Retry camera", "重试相机"), systemImage: "arrow.clockwise", action: retry)
            .accessibilityIdentifier("camera.retry")
    }
}

/// A stopped guide has no localized placement menu, so recovery uses its existing top-right slot.
struct GuideRecoveryMenu<Options: View>: View {
    let language: RouteLanguage
    @ViewBuilder let options: () -> Options

    var body: some View {
        Menu(content: options) { CameraToolSymbol(name: "ellipsis") }
            .buttonStyle(.plain)
            .accessibilityLabel(language.select("More", "更多"))
            .accessibilityIdentifier("guide.placement")
            .padding(.horizontal, 16).padding(.top, 12)
    }
}
