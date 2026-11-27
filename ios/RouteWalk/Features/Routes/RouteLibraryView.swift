import SwiftUI
import UIKit

struct RouteLibraryView: View {
    @Bindable var model: RouteAppModel
    var isModal = false
    @State private var showsImporter = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if isModal {
            page
                .modifier(RouteNamePromptPresenter(model: model, active: true))
                .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.routeWalkMap]) { model.receiveImport($0) }
                .modifier(RouteNoticePresenter(model: model, active: !model.nameEditorIsPresented))
        } else { page }
    }

    private var page: some View {
        NavigationStack {
            List {
                if !model.libraryLoaded, model.libraryEntries.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).listRowSeparator(.hidden)
                } else if model.libraryEntries.isEmpty {
                    Text(model.text("No routes yet", "暂无路线"))
                        .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 12)
                        .listRowSeparator(.hidden).accessibilityIdentifier("practiceRoutes.empty")
                } else {
                    ForEach(model.libraryEntries) { entry in routeRow(entry) }
                }
            }
            .listStyle(.plain).accessibilityIdentifier("practiceRoutes.list")
            .animation(RouteMotion.list(reduceMotion: reduceMotion), value: model.libraryEntries)
            .refreshable { await model.reloadLibrary() }
            .overlay {
                if model.requestingCamera || model.route.state.isLoadingFile { ProgressView() }
            }
            .navigationTitle(model.text("Routes", "路线"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isModal {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(model.text("Close", "关闭"), systemImage: "xmark") { model.showsLibrary = false }
                            .labelStyle(.iconOnly)
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Button(model.text("Import route", "导入路线"), systemImage: "square.and.arrow.down") {
                            if isModal { showsImporter = true } else { model.showsImporter = true }
                        }
                        RouteLanguageMenu(model: model)
                        if let report = model.latestReport {
                            ShareLink(item: report) { Label(model.text("Share field report", "分享实测记录"), systemImage: "list.clipboard") }
                        }
                    } label: { Label(model.text("More", "更多"), systemImage: "ellipsis") }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("home.language")
                    Button(model.text("New route", "新建路线"), systemImage: "plus", action: model.beginNewRoute)
                        .labelStyle(.iconOnly)
                        .accessibilityIdentifier("practiceRoutes.add")
                }
            }
            .disabled(model.isBusy && !model.presentation.isTransitioning)
        }
    }

    private func routeRow(_ entry: RouteLibrary.Entry) -> some View {
        Button { model.openRoute(entry) } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.name).font(.body.weight(.medium)).foregroundStyle(.primary).contentTransition(.opacity)
                    Text(model.text(entry.isMapMissing ? "Map unavailable" : (entry.hasMap ? "Saved" : "Not saved"),
                                    entry.isMapMissing ? "地图不可用" : (entry.hasMap ? "已保存" : "未保存")))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.medium)).foregroundStyle(.secondary).accessibilityHidden(true)
            }
            .padding(.vertical, 8).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("practiceRoutes." + entry.id.uuidString)
        .accessibilityHint(model.text(entry.isMapMissing ? "View map issue" : (entry.hasMap ? "Preview this route" : "View this route"),
                                    entry.isMapMissing ? "查看地图问题" : (entry.hasMap ? "预览已保存路线" : "查看路线")))
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // Requesting confirmation must not make List optimistically remove the row.
            Button { model.requestDelete(entry) } label: {
                Label(model.text("Delete", "删除"), systemImage: "trash")
            }
            .tint(.red)
            .accessibilityIdentifier("practiceRoutes.delete." + entry.id.uuidString)
            Button(model.text("Rename", "重命名"), systemImage: "pencil") { model.nameRequest = RouteNameRequest(entry: entry) }
            if entry.hasSavedMap {
                Button(model.text("Scan again", "重新采集"), systemImage: "arrow.clockwise") { model.scanRoute(entry) }
            }
        }
        .contextMenu {
            if entry.hasMap {
                Button(model.text("Start navigation", "开始导航"), systemImage: "location.north.fill") { model.navigateRoute(entry) }
                Button(model.text("Copy route ID", "复制路线 ID"), systemImage: "document.on.document") {
                    UIPasteboard.general.string = entry.id.uuidString.lowercased()
                }
            }
            Button(model.text("Rename", "重命名"), systemImage: "pencil") { model.nameRequest = RouteNameRequest(entry: entry) }
            if entry.hasSavedMap {
                Button(model.text("Scan again", "重新采集"), systemImage: "arrow.clockwise") { model.scanRoute(entry) }
                if entry.hasMap {
                    ShareLink(item: entry.mapURL) { Label(model.text("Share route", "分享路线"), systemImage: "square.and.arrow.up") }
                }
            }
            Button(role: .destructive) { model.requestDelete(entry) } label: {
                Label(model.text("Delete", "删除"), systemImage: "trash")
            }
            .accessibilityIdentifier("practiceRoutes.delete." + entry.id.uuidString)
        }
        .accessibilityAction(named: model.text("Rename", "重命名")) { model.nameRequest = RouteNameRequest(entry: entry) }
        .accessibilityAction(named: model.text("Delete", "删除")) { model.requestDelete(entry) }
    }
}

