import SwiftUI

struct RoutesHomeView: View {
    @Bindable var model: RouteAppModel

    var body: some View {
        if model.visitorCompletion != nil { RouteVisitorCompletionView(model: model) }
        else if model.handoffRoute != nil || model.visitorSessionActive { RouteHandoffView(model: model) }
        else if model.practiceMode { RouteLibraryView(model: model, isModal: false) }
        else { MallRouteView(model: model) }
    }
}

/// A store handoff remains separate from UUID-named test routes.
private struct MallRouteView: View {
    @Bindable var model: RouteAppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        if model.requestedDestination != nil {
                            Text(model.text("Taicang Wanda\nFloor 1", "太仓万达\n一楼")).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 10) {
                            if model.isBusy || model.checkingDestination { ProgressView().controlSize(.small) }
                            Text(model.homeStatus).font(.subheadline).foregroundStyle(.secondary)
                                .accessibilityIdentifier("home.status")
                        }
                    }
                    VStack(spacing: 12) {
                        if model.canGuide {
                            Button(action: model.startGuidance) {
                                Label(model.text("Start navigation", "开始导航"), systemImage: "location.north.fill")
                                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                            }
                            .buttonStyle(.glassProminent).controlSize(.large).accessibilityIdentifier("home.guide")
                        }
                        Button { model.showsImporter = true } label: {
                            Label(model.text("Import route", "导入路线"), systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity).padding(.vertical, 8)
                        }
                        .buttonStyle(.glass).controlSize(.large).accessibilityIdentifier("home.import")
                    }
                    .disabled(model.isBusy || model.checkingDestination)
                    if model.route.state.hasSavedRoute || model.latestReport != nil {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(model.text("Share", "分享")).font(.headline)
                            if model.route.state.hasSavedRoute {
                                ShareLink(item: model.route.savedRouteURL) {
                                    Label(model.text("Share route", "分享路线"), systemImage: "square.and.arrow.up")
                                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
                                }
                                .accessibilityIdentifier("home.shareRoute")
                            }
                            if let report = model.latestReport {
                                ShareLink(item: report) {
                                    Label(model.text("Share field report", "分享实测记录"), systemImage: "list.clipboard")
                                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
                                }
                                .accessibilityIdentifier("home.shareReport")
                            }
                        }
                        .padding(.top, 12)
                    }
                }
                .padding(24).frame(maxWidth: 560, alignment: .leading).frame(maxWidth: .infinity)
            }
            .background(.background)
            .navigationTitle(model.homeTitle).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(model.text("Routes", "路线"), systemImage: "chevron.left") { model.openLibrary() }
                        .accessibilityIdentifier("home.myRoutes").disabled(model.isBusy)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(model.text("Scan mall route", "采集商场路线"), systemImage: "plus", action: model.startRecording)
                        Button(model.text("Import route", "导入路线"), systemImage: "square.and.arrow.down") { model.showsImporter = true }
                        RouteLanguageMenu(model: model)
                    } label: { Label(model.text("More", "更多"), systemImage: "ellipsis") }
                    .accessibilityIdentifier("home.language").disabled(model.isBusy)
                }
            }
        }
    }
}
