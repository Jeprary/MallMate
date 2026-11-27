import SwiftUI

/// Presentation values also support deterministic previews without creating an AR session.
struct ScanPresentation {
    enum MapIndicator { case unavailable, limited, extending, mapped }
    var pointCount = 0
    var canPlace = false
    var canSave = false
    var canUndo = false
    var isSaving = false
    var coaching = false
    var instruction = ""
    var mappingStatus = ""
    var mapIndicator: MapIndicator = .unavailable
    var requiresAttention = false
    var sessionFailed = false
    var language = RouteLanguage.current
}

struct ScanOverlayView<MoreContent: View>: View {
    let presentation: ScanPresentation
    let exit: () -> Void
    let undo: () -> Void
    let mark: (CGSize) -> Void
    let save: () -> Void
    @ViewBuilder let moreContent: () -> MoreContent
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var footerHeight: CGFloat = 200
    @State private var showsMapDetails = false

    var body: some View {
        GeometryReader { geometry in
            let viewport = CGSize(width: geometry.size.width + geometry.safeAreaInsets.leading + geometry.safeAreaInsets.trailing,
                                  height: geometry.size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom)
            ZStack {
                if !presentation.coaching {
                    VStack {
                        LinearGradient(colors: [.black.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: geometry.safeAreaInsets.top + 80)
                        Spacer(minLength: 0)
                        LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .top, endPoint: .bottom)
                            .frame(height: min(footerHeight + 72, max(148, viewport.height / 2 - geometry.safeAreaInsets.bottom - 16)))
                    }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    ScanReticle().stroke(.white.opacity(presentation.canPlace && !presentation.isSaving ? 1 : 0.45),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .frame(width: 32, height: 32)
                        .shadow(color: .black.opacity(0.55), radius: 3)
                        .position(x: viewport.width / 2 - geometry.safeAreaInsets.leading,
                                  y: viewport.height / 2 - geometry.safeAreaInsets.top)
                        .allowsHitTesting(false).accessibilityHidden(true)
                        .accessibilityIdentifier("record.target")
                }
                VStack(spacing: 0) {
                    HStack {
                        Button(action: exit) { CameraToolSymbol(name: "xmark") }
                            .buttonStyle(CameraPressStyle())
                            .accessibilityLabel(text("Exit scan", "退出采集")).accessibilityIdentifier("record.exit")
                        Spacer()
                        if !presentation.coaching {
                            mapStatus
                            Spacer()
                        }
                        if !presentation.coaching {
                            Menu {
                                Button(text("Map details", "地图详情"), systemImage: "info.circle") { showsMapDetails = true }
                                    .accessibilityIdentifier("record.mapDetailsAction")
                                Divider()
                                moreContent()
                            } label: {
                                CameraToolSymbol(name: "ellipsis")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(text("More", "更多")).accessibilityIdentifier("record.more")
                            .disabled(presentation.isSaving)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    Spacer(minLength: 0)
                    if !presentation.coaching {
                        ScrollView(.vertical) {
                            VStack(spacing: 16) {
                                if let prompt {
                                    Text(prompt).font(.subheadline.weight(.medium))
                                        .multilineTextAlignment(.center)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .padding(.horizontal, 14).padding(.vertical, 9)
                                        .background(.ultraThinMaterial, in: Capsule())
                                        .accessibilityIdentifier("record.instruction")
                                }
                                actionButtons(viewport: viewport)
                            }
                            .padding(.bottom, 2)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
                        }
                        .frame(height: min(footerHeight, max(100, viewport.height / 2 - geometry.safeAreaInsets.bottom - 64)))
                        .scrollIndicators(.visible)
                        .accessibilityIdentifier("record.controls")
                        .padding(.horizontal, 24)
                        .padding(.bottom, 18)
                    }
                }
            }
            .foregroundStyle(.white)
            .colorScheme(.dark)
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: presentation.pointCount) { previous, current in current > previous }
        .onChange(of: presentation.coaching) { _, active in if active { showsMapDetails = false } }
        .alert(text("Map details", "地图详情"), isPresented: $showsMapDetails) {
            Button(text("Done", "完成"), role: .cancel) {}
        } message: {
            Text(detailMessages.joined(separator: "\n\n")).accessibilityIdentifier("record.mapDetails")
        }
    }

    private func text(_ en: String, _ zh: String) -> String { presentation.language.select(en, zh) }
    private var instruction: String {
        if !presentation.instruction.isEmpty { return presentation.instruction }
        if presentation.isSaving { return text("Saving route…", "正在保存路线…") }
        if !presentation.canPlace { return text("Waiting for tracking…", "等待追踪就绪…") }
        if presentation.pointCount == 0 { return text("Place destination", "放置终点") }
        if presentation.pointCount == 1 { return text("Add waypoint", "添加路点") }
        if !presentation.canSave { return text("Keep scanning", "继续扫视") }
        return text("Ready to save", "可保存")
    }

    private var prompt: String? {
        if presentation.isSaving { return nil }
        if presentation.requiresAttention { return instruction }
        return presentation.pointCount == 0 ? instruction : nil
    }

    private var mapStatus: some View {
        HStack(spacing: 7) {
            Circle().fill(mapColor).frame(width: 8, height: 8)
            Text(mapLabel).font(.footnote.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: 44).shadow(color: .black.opacity(0.55), radius: 3)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text("Map status", "地图状态"))
        .accessibilityValue(presentation.sessionFailed ? mapDescription
                            : (presentation.mappingStatus.isEmpty ? mapDescription : presentation.mappingStatus))
        .accessibilityIdentifier("record.mapStatus")
    }

    private var detailMessages: [String] {
        var result: [String] = []
        for message in [presentation.sessionFailed || presentation.mappingStatus.isEmpty ? mapDescription : presentation.mappingStatus, instruction,
                        presentation.pointCount < 2 && !presentation.isSaving
                        ? text("At least 2 waypoints to save", "至少放置 2 个路点后保存") : ""] {
            let value = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty, !result.contains(value) { result.append(value) }
        }
        return result
    }

    private var mapColor: Color {
        if presentation.sessionFailed { return .gray }
        return switch presentation.mapIndicator {
        case .unavailable: .gray
        case .limited: .yellow
        case .extending: .blue
        case .mapped: .green
        }
    }

    private var mapDescription: String {
        if presentation.sessionFailed { return text("Tracking stopped", "追踪已停止") }
        return switch presentation.mapIndicator {
        case .unavailable: text("Map unavailable", "尚无地图")
        case .limited: text("More scanning needed", "建图不足")
        case .extending: text("Map expanding", "地图扩展中")
        case .mapped: text("Current area mapped", "当前区域已建图")
        }
    }

    private var mapLabel: String {
        if presentation.sessionFailed { return text("Tracking stopped", "追踪已停止") }
        return switch presentation.mapIndicator {
        case .unavailable: text("No map", "尚无地图")
        case .limited: text("Scan more", "采集不足")
        case .extending: text("Mapping", "扩展中")
        case .mapped: text("Mapped", "已充分建图")
        }
    }

    @ViewBuilder private func actionButtons(viewport: CGSize) -> some View {
        if typeSize.isAccessibilitySize {
            VStack(spacing: 18) {
                markButton(viewport: viewport)
                HStack { undoButton; Spacer(minLength: 20); saveButton }
            }
        } else {
            HStack(alignment: .top, spacing: 8) {
                undoButton.padding(.top, 12).frame(maxWidth: .infinity)
                markButton(viewport: viewport).frame(maxWidth: .infinity)
                saveButton.padding(.top, 12).frame(maxWidth: .infinity)
            }
        }
    }

    private func markButton(viewport: CGSize) -> some View {
        let enabled = presentation.canPlace && !presentation.isSaving
        let title = text(presentation.pointCount == 0 ? "Place destination" : "Add point", presentation.pointCount == 0 ? "放置终点" : "加路点")
        return Button { mark(viewport) } label: {
            Image(systemName: "plus").font(.system(size: 26, weight: .medium))
                .foregroundStyle(.white.opacity(enabled ? 1 : 0.4))
                .frame(width: 68, height: 68)
                .background(.black.opacity(enabled ? 0.38 : 0.24), in: Circle())
                .glassEffect(.clear.interactive(), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(CameraPressStyle()).disabled(!enabled)
        .accessibilityLabel(title).accessibilityIdentifier("record.mark")
    }

    private var undoButton: some View {
        let enabled = presentation.canUndo && !presentation.isSaving
        return Button(action: undo) {
            Text(text("Undo", "撤销"))
                .font(.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16).padding(.vertical, 10).frame(minHeight: 44)
                .foregroundStyle(.white.opacity(enabled ? 1 : 0.5))
                .glassEffect(.regular.interactive(), in: Capsule())
        }
            .buttonStyle(CameraPressStyle()).disabled(!presentation.canUndo || presentation.isSaving)
            .accessibilityLabel(text("Undo last point", "撤销上个点")).accessibilityIdentifier("record.undo")
    }

    private var saveButton: some View {
        let enabled = presentation.canSave && !presentation.isSaving
        return Button(action: save) {
            ZStack {
                Text(text("Save", "保存"))
                    .font(.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    .opacity(presentation.isSaving ? 0 : 1)
                    .accessibilityHidden(presentation.isSaving)
                if presentation.isSaving { ProgressView().tint(.white) }
            }
            .padding(.horizontal, 16).padding(.vertical, 10).frame(minHeight: 44)
            .foregroundStyle(.white.opacity(enabled ? 1 : 0.5))
            .glassEffect(.regular.interactive(), in: Capsule())
        }
        .buttonStyle(CameraPressStyle()).disabled(!enabled)
        .accessibilityLabel(text(presentation.isSaving ? "Saving route" : "Save", presentation.isSaving ? "正在保存路线" : "保存"))
        .accessibilityIdentifier("record.save")
    }
}

private struct ScanReticle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addEllipse(in: rect.insetBy(dx: 2, dy: 2))
        path.move(to: CGPoint(x: rect.midX - 1, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX + 1, y: rect.midY))
        return path
    }
}
