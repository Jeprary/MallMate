import ARKit
import AVFoundation
import Foundation
import Observation

enum RoutePrompt: String, Identifiable {
    case exitScan, restartScan, replacePractice, saveDestination, replaceImport, exportFrame, trialFeedback, failedTrial, deleteRoute, unscannedRoute
    var id: String { rawValue }
}

struct RouteNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    var offersSettings = false
}

struct RouteNameRequest: Identifiable {
    let id = UUID()
    let entry: RouteLibrary.Entry?
}

/// Serializes library file work away from the UI actor without changing stable route URLs.
private actor RouteLibraryStore {
    private let library = RouteLibrary()
    func entries() throws -> [RouteLibrary.Entry] { try library.entries() }
    func create(_ name: String) throws -> RouteLibrary.Entry { try library.create(name: name) }
    func rename(_ entry: RouteLibrary.Entry, to name: String) throws -> RouteLibrary.Entry {
        try library.rename(id: entry.id, name: name)
    }
    func importRoute(_ url: URL, name: String) throws -> RouteLibrary.Entry {
        try library.importRoute(from: url, name: name)
    }
    func markSaved(_ id: UUID) throws { _ = try library.markSaved(id: id) }
    func delete(_ id: UUID) throws { try library.delete(id: id) }
}

@MainActor @Observable
final class RouteAppModel {
    static let destinationID = "B02001HUD4"
    let presentation = RoutePresentationCoordinator()
    private(set) var route: RouteSession
    private(set) var practiceMode = true
    private(set) var selectedPractice: RouteLibrary.Entry?
    private(set) var handoffRoute: RouteLibrary.Entry?
    enum VisitorCompletion: Sendable { case arrived, ended, unavailable }
    private(set) var visitorSessionActive = false
    private(set) var visitorCompletion: VisitorCompletion?
    private(set) var visitorReturnURL: URL?
    private(set) var returningToWeb = false
    private(set) var webReturnFailed = false
    private(set) var webReturnRequest: UUID?
    private(set) var requestedDestination: String?
    private(set) var savedDestinationMatches = false
    private(set) var checkingDestination = false
    private(set) var libraryEntries = [RouteLibrary.Entry]()
    private(set) var libraryLoaded = false
    private(set) var busy = false
    private(set) var requestingCamera = false
    var showsLibrary = false
    private(set) var libraryIsPresented = false
    private(set) var nameEditorIsPresented = false
    var showsImporter = false
    var showsReferencePhoto = false
    var nameRequest: RouteNameRequest?
    var prompt: RoutePrompt?
    private(set) var pendingDeleteEntry: RouteLibrary.Entry?
    private var pendingDraftEntry: RouteLibrary.Entry?
    var notice: RouteNotice?
    var signPlacement = RouteSignPlacement()
    var language = RouteLanguage.preference {
        didSet { RouteLanguage.preference = language }
    }
    private(set) var systemLanguageRevision = 0
    private(set) var hasLocalizedInVisit = false
    private(set) var latestReport: URL? = FieldTrial.latest
    @ObservationIgnored private let library = RouteLibraryStore()
    @ObservationIgnored private var trial: FieldTrial?
    @ObservationIgnored private var pendingTrialVerdict: String?
    @ObservationIgnored private var selectionRequest: UUID?
    @ObservationIgnored private var bindingRequest: UUID?
    @ObservationIgnored private var pendingImport: (url: URL, scoped: Bool)?
    @ObservationIgnored private var explainedFrames = false
    @ObservationIgnored private var receivedHandoff = false
    @ObservationIgnored private var sceneActive = true
    @ObservationIgnored private var pendingCameraStart: (@MainActor () -> Void)?
    @ObservationIgnored private var trialFailure = ""
    @ObservationIgnored private var pendingCreatedEntry: RouteLibrary.Entry?
    private enum RouteEntryAction { case scan, review, navigate }
    private struct PendingRouteAction {
        let archive: URL
        let action: RouteEntryAction
    }
    @ObservationIgnored private var pendingRouteAction: PendingRouteAction?

    init() { route = RouteSession(archiveURL: RouteArchive.practiceURL) }

    func text(_ english: String, _ chinese: String) -> String {
        resolvedLanguage.select(english, chinese)
    }

    var resolvedLanguage: RouteLanguage {
        _ = systemLanguageRevision
        return language == .system ? RouteLanguage.current : language
    }

    var locale: Locale { language == .system ? .current : Locale(identifier: language == .chinese ? "zh-Hans" : "en") }

    var isIdle: Bool { route.state.mode == .idle }
    var isBusy: Bool { busy || returningToWeb || requestingCamera || route.state.isLoadingFile || presentation.isTransitioning }
    var bundledRoute: URL? { Bundle.main.url(forResource: "Uniqlo", withExtension: "routewalk") }
    var canGuide: Bool {
        if requestedDestination != nil { return savedDestinationMatches || bundledRoute != nil }
        return practiceMode ? selectedPractice?.hasMap == true : route.state.hasSavedRoute
    }
    var homeTitle: String {
        if practiceMode { return selectedPractice?.name ?? text("Test routes", "测试路线") }
        return requestedDestination == nil ? text("Mall route", "商场路线") : "UNIQLO"
    }
    var homeStatus: String {
        if requestingCamera { return text("Waiting for camera access…", "等待相机权限…") }
        if route.state.isLoadingFile || busy { return text("Loading route…", "正在读取路线…") }
        if checkingDestination { return text("Checking saved route…", "正在核对本机路线…") }
        if requestedDestination != nil {
            return canGuide ? text("Route ready", "路线已就绪")
                : text("Import the route shared by the person who scanned this location.", "请导入采集者分享的路线文件。")
        }
        if practiceMode { return selectedPractice == nil ? "" : (canGuide ? text("Route ready", "路线已就绪") : text("Not scanned", "未采集")) }
        return route.state.hasSavedRoute ? text("A route is saved on this iPhone", "本机已保存一条路线")
            : text("No route saved yet", "还没有实地路线")
    }

    func systemLanguageChanged() { systemLanguageRevision += 1 }

    func setSceneActive(_ active: Bool) {
        guard sceneActive != active else { return }
        sceneActive = active
        presentation.sceneActivityChanged(active)
        if active {
            route.resumeFromBackground()
            performPendingRouteAction()
            if let action = pendingCameraStart, isIdle, !isBusy {
                pendingCameraStart = nil
                action()
            }
        } else { route.suspendForBackground() }
    }

    func restoreSelection() async {
        let token = UUID()
        selectionRequest = token
        do {
            let entries = try await library.entries()
            if !libraryLoaded { libraryEntries = entries; libraryLoaded = true }
            guard !receivedHandoff, selectionRequest == token, isIdle, !isBusy else { return }
            selectionRequest = nil
            if let raw = UserDefaults.standard.string(forKey: "routewalk.testRouteID"),
               let id = UUID(uuidString: raw), let entry = entries.first(where: { $0.id == id }) {
                select(entry, scanIfNew: false)
            }
        } catch {
            libraryLoaded = true
            guard selectionRequest == token else { return }
            selectionRequest = nil
            showError(text("Routes", "路线"), error)
        }
    }

    func openLibrary(create: Bool = false) {
        guard isIdle, !isBusy else { return }
        handoffRoute = nil
        selectionRequest = nil
        requestedDestination = nil
        resetDestinationBinding()
        selectArchive(practice: true)
        showsLibrary = false
        Task {
            await reloadLibrary()
            if create, practiceMode, isIdle { beginNewRoute() }
        }
    }

    func beginNewRoute() {
        guard isIdle, !isBusy, nameRequest == nil, !nameEditorIsPresented else { return }
        if !practiceMode { openLibrary(create: true); return }
        nameRequest = RouteNameRequest(entry: nil)
    }

    func reloadLibrary() async {
        guard !busy else { return }
        busy = true
        defer { busy = false; libraryLoaded = true; performPendingRouteAction() }
        do {
            libraryEntries = try await library.entries()
            if let id = selectedPractice?.id {
                selectedPractice = libraryEntries.first(where: { $0.id == id })
            }
        }
        catch { showError(text("Routes", "路线"), error) }
    }

    func submitName(_ value: String, for entry: RouteLibrary.Entry?) async {
        guard !busy else { return }
        busy = true
        let updated: RouteLibrary.Entry
        do {
            if let entry { updated = try await library.rename(entry, to: value) }
            else { updated = try await library.create(value) }
        } catch {
            busy = false
            showError(text("Routes", "路线"), error)
            return
        }
        // The name operation committed. A refresh failure must not offer Create a second time.
        if let index = libraryEntries.firstIndex(where: { $0.id == updated.id }) { libraryEntries[index] = updated }
        else { libraryEntries.insert(updated, at: 0) }
        libraryLoaded = true
        var refreshFailure: Error?
        do { libraryEntries = try await library.entries() }
        catch { refreshFailure = error }
        if selectedPractice?.id == updated.id { selectedPractice = updated }
        busy = false
        if entry == nil, refreshFailure == nil { pendingCreatedEntry = updated }
        nameRequest = nil
        if let refreshFailure {
            showError(text("Route updated; list could not refresh", "路线已更新，列表未能刷新"), refreshFailure)
        }
        if !nameEditorIsPresented { nameEditorDidDismiss() }
    }

    func select(_ entry: RouteLibrary.Entry, scanIfNew: Bool = true) {
        guard isIdle, !isBusy else { return }
        selectionRequest = nil
        resetDestinationBinding()
        requestedDestination = nil
        selectedPractice = entry
        selectArchive(practice: true, entry: entry)
        UserDefaults.standard.set(entry.id.uuidString, forKey: "routewalk.testRouteID")
        if scanIfNew, !entry.hasSavedMap { pendingRouteAction = PendingRouteAction(archive: route.savedRouteURL, action: .scan) }
        showsLibrary = false
        performPendingRouteAction()
    }

    func openRoute(_ entry: RouteLibrary.Entry) {
        guard isIdle, !isBusy, prompt == nil, pendingDraftEntry == nil,
              nameRequest == nil, !nameEditorIsPresented else { return }
        guard !entry.isMapMissing else {
            notice = RouteNotice(title: text("Map unavailable", "地图不可用"),
                message: text("Import the saved map or choose Scan again.", "请导入已保存的地图，或明确选择重新采集。"))
            return
        }
        guard entry.hasMap else {
            pendingDraftEntry = entry
            if libraryIsPresented { showsLibrary = false }
            else { prompt = .unscannedRoute }
            return
        }
        activate(entry, action: .review)
    }

    func confirmScanDraft() {
        guard prompt == .unscannedRoute, let entry = pendingDraftEntry else { return }
        pendingDraftEntry = nil
        prompt = nil
        guard let current = libraryEntries.first(where: { $0.id == entry.id }) else { return }
        if current.hasSavedMap { openRoute(current) }
        else { scanRoute(current) }
    }

    func scanRoute(_ entry: RouteLibrary.Entry) { activate(entry, action: .scan) }
    func navigateRoute(_ entry: RouteLibrary.Entry) { activate(entry, action: .navigate) }

    var currentLibraryEntry: RouteLibrary.Entry? {
        guard practiceMode else { return nil }
        return libraryEntries.first { $0.mapURL == route.savedRouteURL }
    }

    func requestDeleteCurrentRoute() {
        if let entry = currentLibraryEntry { requestDelete(entry) }
    }

    func requestDelete(_ entry: RouteLibrary.Entry) {
        guard !isBusy, !route.state.isSaving, nameRequest == nil, !nameEditorIsPresented,
              isIdle || (route.state.mode == .reviewing && route.savedRouteURL == entry.mapURL) else { return }
        pendingDeleteEntry = entry
        if libraryIsPresented { showsLibrary = false }
        else { prompt = .deleteRoute }
    }

    func confirmDelete() {
        guard prompt == .deleteRoute, let entry = pendingDeleteEntry else { return }
        prompt = nil
        if route.state.mode == .reviewing {
            finishCameraSession { [weak self] in
                Task { await self?.removeRoute(entry) }
            }
        } else { Task { await removeRoute(entry) } }
    }

    private func removeRoute(_ entry: RouteLibrary.Entry) async {
        guard isIdle, !busy else { pendingDeleteEntry = nil; return }
        busy = true
        defer { busy = false; pendingDeleteEntry = nil; performPendingRouteAction() }
        do {
            try await library.delete(entry.id)
        } catch { showError(text("Could not delete route", "未能删除路线"), error); return }
        // The deletion has committed. A later refresh error must not resurrect its old row.
        libraryEntries.removeAll { $0.id == entry.id }
        libraryLoaded = true
        selectionRequest = nil
        if pendingRouteAction?.archive == entry.mapURL { pendingRouteAction = nil }
        if pendingCreatedEntry?.id == entry.id { pendingCreatedEntry = nil }
        if selectedPractice?.id == entry.id {
            selectedPractice = nil
            let next = libraryEntries.first
            selectArchive(practice: true, entry: next)
            if let next { UserDefaults.standard.set(next.id.uuidString, forKey: "routewalk.testRouteID") }
            else { UserDefaults.standard.removeObject(forKey: "routewalk.testRouteID") }
        }
        do {
            libraryEntries = try await library.entries()
            if let selected = selectedPractice { selectedPractice = libraryEntries.first { $0.id == selected.id } }
        } catch { showError(text("Route removed; list could not refresh", "路线已移除，列表未能刷新"), error) }
    }

    func navigateFromReview() { leaveReview(for: .navigate) }
    func scanAgainFromReview() { leaveReview(for: .scan) }

    private func leaveReview(for action: RouteEntryAction) {
        guard route.state.mode == .reviewing, presentation.controlsEnabled else { return }
        let archive = route.savedRouteURL
        finishCameraSession { [weak self] in
            guard let self, self.route.savedRouteURL == archive else { return }
            self.pendingRouteAction = PendingRouteAction(archive: archive, action: action)
            self.performPendingRouteAction()
        }
    }

    private func activate(_ entry: RouteLibrary.Entry, action: RouteEntryAction) {
        guard isIdle, !isBusy else { return }
        select(entry, scanIfNew: false)
        pendingRouteAction = PendingRouteAction(archive: entry.mapURL, action: action)
        performPendingRouteAction()
    }

    func libraryDidPresent() { libraryIsPresented = true }

    func libraryDidDismiss() {
        libraryIsPresented = false
        if pendingDeleteEntry != nil { prompt = .deleteRoute; return }
        if pendingDraftEntry != nil { prompt = .unscannedRoute; return }
        performPendingRouteAction()
    }

    func nameEditorDidPresent() { nameEditorIsPresented = true }

    func nameEditorDidDismiss() {
        nameEditorIsPresented = false
        guard let entry = pendingCreatedEntry else { return }
        pendingCreatedEntry = nil
        select(entry, scanIfNew: true)
    }

    private func performPendingRouteAction() {
        guard let pending = pendingRouteAction, sceneActive,
              !libraryIsPresented, !showsLibrary, !nameEditorIsPresented,
              isIdle, !isBusy else { return }
        pendingRouteAction = nil
        guard route.savedRouteURL == pending.archive else { return }
        if practiceMode { guard selectedPractice?.mapURL == pending.archive else { return } }
        switch pending.action {
        case .scan: startRecording()
        case .review: startReview()
        case .navigate: startGuidance(from: pending.archive)
        }
    }

    func showMallRoute() {
        guard isIdle, !isBusy else { return }
        selectionRequest = nil
        resetDestinationBinding()
        requestedDestination = nil
        selectArchive(practice: false)
    }

    private func selectArchive(practice: Bool, entry: RouteLibrary.Entry? = nil) {
        pendingCameraStart = nil
        pendingRouteAction = nil
        pendingCreatedEntry = nil
        let selected = entry ?? (practice ? selectedPractice : nil)
        let archive = practice ? selected?.mapURL ?? RouteArchive.practiceURL : RouteArchive.url
        UserDefaults.standard.set(practice ? "test" : "mall", forKey: "routewalk.lastLibrary")
        if practice != practiceMode || route.savedRouteURL != archive {
            route.stop()
            route = RouteSession(archiveURL: archive)
            route.setSignPlacement(signPlacement)
        }
        practiceMode = practice
        if practice { selectedPractice = selected }
    }

    /// URL handoffs select a destination or test library; camera access remains a separate action.
    func receive(_ url: URL) {
        receivedHandoff = true
        selectionRequest = nil
        let incoming = RouteUniversalLink.invocation(for: url) ?? url
        guard let parts = URLComponents(url: incoming, resolvingAgainstBaseURL: false) else {
            invalidDestination(); return
        }
        guard parts.scheme?.lowercased() == "mallmate-route", parts.user == nil,
              parts.password == nil, parts.port == nil, parts.fragment == nil else {
            if parts.scheme?.lowercased() == "mallmate-route",
               ["route", "guide"].contains(parts.host?.lowercased() ?? "") {
                rejectVisitorHandoff(parts)
            } else { invalidDestination() }
            return
        }
        if parts.host?.lowercased() == "practice" {
            let query = parts.queryItems ?? []
            guard (parts.path.isEmpty || parts.path == "/"), query.count <= 1,
                  query.allSatisfy({ $0.name == "lang" }),
                  let preference = RouteLanguage(rawValue: query.first?.value ?? "system") else {
                notice = RouteNotice(title: text("Cannot open this test", "无法打开这个测试"),
                    message: text("Open the room test page again.", "请重新打开宿舍测试页。"))
                return
            }
            guard canAcceptHandoff() else { return }
            clearVisitorContext()
            language = preference
            openLibrary()
            return
        }
        if parts.host?.lowercased() == "route" {
            let path = String(parts.path.dropFirst())
            let query = parts.queryItems ?? []
            guard parts.path.hasPrefix("/"), let id = UUID(uuidString: path),
                  path.lowercased() == id.uuidString.lowercased(),
                  let context = visitorContext(query) else {
                rejectVisitorHandoff(parts); return
            }
            guard canAcceptHandoff() else { return }
            configureVisitorContext(context.url)
            language = context.language
            busy = true
            Task {
                defer { busy = false }
                do {
                    let entries = try await library.entries()
                    guard let entry = entries.first(where: { $0.id == id }), entry.hasMap else {
                        visitorCompletion = .unavailable; return
                    }
                    libraryEntries = entries
                    libraryLoaded = true
                    language = context.language
                    notice = nil
                    busy = false
                    select(entry, scanIfNew: false)
                    handoffRoute = entry
                } catch { visitorCompletion = .unavailable }
            }
            return
        }
        guard parts.host?.lowercased() == "guide" else { invalidDestination(); return }
        guard parts.path == "/" + Self.destinationID,
              let context = visitorContext(parts.queryItems ?? []) else { rejectVisitorHandoff(parts); return }
        guard canAcceptHandoff() else { return }
        configureVisitorContext(context.url)
        language = context.language
        handoffRoute = nil
        showsLibrary = false
        showsImporter = false
        nameRequest = nil
        selectArchive(practice: false)
        requestedDestination = Self.destinationID
        resetDestinationBinding()
        if bundledRoute == nil, route.state.hasSavedRoute {
            let token = UUID()
            bindingRequest = token
            checkingDestination = true
            route.checkSavedDestination(Self.destinationID) { [weak self] matches in
                guard let self, self.bindingRequest == token else { return }
                self.bindingRequest = nil
                self.checkingDestination = false
                self.savedDestinationMatches = matches
            }
        }
    }

    private func invalidDestination() {
        notice = RouteNotice(title: text("Cannot open this destination", "无法打开这个目的地"),
            message: text("This link supports UNIQLO at Taicang Wanda, Floor 1.", "此入口仅支持太仓万达一楼优衣库。"))
    }

    private func unavailableHandoffRoute() {
        notice = RouteNotice(title: text("Route unavailable", "路线不可用"),
            message: text("Import this route on this iPhone first.", "请先在这部 iPhone 上导入这条路线。"))
    }

    private func rejectVisitorHandoff(_ parts: URLComponents) {
        guard canAcceptHandoff() else { return }
        let returns = (parts.queryItems ?? []).filter { $0.name == "return" }
        let url = returns.count == 1 ? RouteWebReturnPolicy.validated(returns[0].value) : nil
        clearVisitorContext()
        if let url { configureVisitorContext(url) }
        else { visitorSessionActive = true; showsLibrary = false }
        if let contextLanguage = (parts.queryItems ?? []).first(where: { $0.name == "lang" })?.value,
           let preference = RouteLanguage(rawValue: contextLanguage) { language = preference }
        notice = nil
        visitorCompletion = .unavailable
    }

    func dismissRouteHandoff() {
        guard isIdle, !isBusy else { return }
        if visitorSessionActive { finishVisitor(.ended, returnImmediately: true) }
        else { handoffRoute = nil }
    }

    func startHandoffNavigation() {
        guard isIdle, !isBusy, visitorCompletion == nil else { return }
        guard let entry = handoffRoute else { startGuidance(); return }
        guard let current = libraryEntries.first(where: { $0.id == entry.id }), current.hasMap else {
            if visitorSessionActive { visitorCompletion = .unavailable }
            else { unavailableHandoffRoute() }
            return
        }
        navigateRoute(current)
    }

    private func visitorContext(_ query: [URLQueryItem]) -> (language: RouteLanguage, url: URL)? {
        guard query.count <= 2, Set(query.map(\.name)).count == query.count,
              query.allSatisfy({ ["lang", "return"].contains($0.name) && $0.value != nil }),
              let language = RouteLanguage(rawValue: query.first(where: { $0.name == "lang" })?.value ?? "system"),
              let url = RouteWebReturnPolicy.validated(query.first(where: { $0.name == "return" })?.value) else { return nil }
        return (language, url)
    }

    private func configureVisitorContext(_ url: URL) {
        clearVisitorContext()
        showsLibrary = false
        showsImporter = false
        notice = nil
        handoffRoute = nil
        visitorSessionActive = true
        visitorReturnURL = url
        visitorCompletion = nil
        webReturnFailed = false
    }

    private func clearVisitorContext() {
        handoffRoute = nil
        visitorSessionActive = false
        visitorReturnURL = nil
        visitorCompletion = nil
        returningToWeb = false
        webReturnFailed = false
        webReturnRequest = nil
    }

    func visitorArrived() {
        guard visitorSessionActive, route.state.mode == .guiding, route.state.hasArrived else { return }
        finishVisitor(.arrived, returnImmediately: false)
    }

    private func finishVisitor(_ completion: VisitorCompletion, returnImmediately: Bool) {
        guard visitorSessionActive, visitorCompletion == nil else { return }
        visitorCompletion = completion
        trial = nil
        let complete: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            if returnImmediately { self.returnVisitorToWeb() }
        }
        if route.state.mode == .idle && !presentation.cameraMounted { complete() }
        else { finishCameraSession(afterReturn: complete) }
    }

    func returnVisitorToWeb() {
        guard visitorSessionActive, visitorCompletion != nil, !returningToWeb else { return }
        guard visitorReturnURL != nil else { webReturnFailed = true; return }
        returningToWeb = true
        webReturnFailed = false
        webReturnRequest = UUID()
    }

    func webReturnFinished(_ accepted: Bool, request: UUID? = nil) {
        guard returningToWeb, request == nil || request == webReturnRequest else { return }
        returningToWeb = false
        webReturnFailed = !accepted
        // A later app switch stays in the completed visitor view, never the route library.
    }

    private func canAcceptHandoff() -> Bool {
        guard isIdle, !isBusy, prompt == nil, nameRequest == nil, pendingDraftEntry == nil,
              pendingImport == nil, !showsImporter, !nameEditorIsPresented else {
            notice = RouteNotice(title: text("Finish the current session first", "请先结束当前操作"),
                message: text("Open the link again when finished.", "结束后重新打开链接。"))
            return false
        }
        return true
    }

    private func resetDestinationBinding() {
        bindingRequest = nil
        checkingDestination = false
        savedDestinationMatches = false
    }

    func startRecording() {
        if practiceMode, selectedPractice == nil { openLibrary(create: true); return }
        withCamera { [weak self] in
            guard let self else { return }
            self.explainedFrames = false
            self.hasLocalizedInVisit = false
            self.route.startRecording()
        }
    }

    func startGuidance() {
        startGuidance(from: nil)
    }

    private func startGuidance(from explicitFile: URL?) {
        withCamera { [weak self] in
            guard let self else { return }
            let map = explicitFile ?? (self.requestedDestination == nil ? nil : self.bundledRoute)
            self.hasLocalizedInVisit = false
            self.trial = self.visitorSessionActive ? nil : FieldTrial(routeURL: map ?? self.route.savedRouteURL)
            self.route.startGuidance(expectedDestinationID: self.requestedDestination, from: map) { [weak self] result in
                guard let self, case .failure(let error) = result else { return }
                self.trial = nil
                if !self.isCancelled(error) { self.showError(self.text("Cannot open route", "无法打开路线"), error) }
            }
        }
    }

    func startReview() {
        withCamera { [weak self] in
            guard let self else { return }
            self.hasLocalizedInVisit = false
            self.trial = nil
            self.route.startReview { [weak self] result in
                guard let self, case .failure(let error) = result else { return }
                if !self.isCancelled(error) { self.showError(self.text("Cannot open route", "无法打开路线"), error) }
            }
        }
    }

    private func withCamera(_ action: @escaping @MainActor () -> Void) {
        guard sceneActive, isIdle, !isBusy else { return }
        guard ARWorldTrackingConfiguration.isSupported else {
            notice = RouteNotice(title: text("AR-compatible iPhone required", "需要支持 AR 的 iPhone"),
                message: text("Use a compatible iPhone to scan a route and test the signs.", "请在兼容的 iPhone 上采集路线和测试路标。"))
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: action()
        case .notDetermined:
            requestingCamera = true
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    self.requestingCamera = false
                    guard self.isIdle else { return }
                    if granted {
                        if self.sceneActive { action() } else { self.pendingCameraStart = action }
                    } else { self.cameraUnavailable() }
                }
            }
        default: cameraUnavailable()
        }
    }

    private func cameraUnavailable() {
        notice = RouteNotice(title: text("Allow camera access", "请允许使用相机"),
            message: text("Enable camera access in Settings to scan and navigate.", "在系统设置中开启相机权限，以采集和导航。"), offersSettings: true)
    }

    func markPoint(viewport: CGSize) {
        guard presentation.controlsEnabled, route.state.mode == .recording, route.state.canPlacePoint, !route.coachingActive else { return }
        route.placePoint(at: CGPoint(x: viewport.width / 2, y: viewport.height / 2), viewportSize: viewport)
    }

    func undoPoint() {
        guard presentation.controlsEnabled else { return }
        route.undoPoint()
    }

    func cameraSurfacePrepared(session: RouteSession, id: UUID, ready: Bool) {
        guard route === session, presentation.cameraID == id, presentation.phase == .preparing else { return }
        if ready {
            presentation.surfaceBindingFinished(id: id, ready: true)
            presentation.cameraFrameChanged(session.hasCameraFrame)
        } else {
            finishCameraSession(notice: RouteNotice(title: text("Cannot open camera", "无法打开相机"), message: session.state.message))
        }
    }

    func cameraPreparationTimedOut(id: UUID) {
        guard sceneActive, presentation.cameraID == id, presentation.phase == .preparing else { return }
        finishCameraSession(notice: RouteNotice(title: text("Cannot open camera", "无法打开相机"),
            message: text("Try opening the route again.", "请重新打开路线。")))
    }

    private func finishCameraSession(notice: RouteNotice? = nil, afterReturn: @escaping @MainActor () -> Void = {}) {
        let session = route
        presentation.returnToRoutes(stopWhenCovered: { session.stop() }) { [weak self] in
            guard let self, self.route === session else { return }
            if let notice { self.notice = notice }
            afterReturn()
        }
    }

    func save() {
        guard presentation.controlsEnabled, route.state.canSave, !route.state.isSaving else { return }
        if practiceMode {
            if route.state.hasSavedRoute { prompt = .replacePractice }
            else { finishSaving(destinationID: nil) }
        } else { prompt = .saveDestination }
    }

    func finishSaving(destinationID: String?) {
        prompt = nil
        route.saveRoute(destinationID: destinationID) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.resetDestinationBinding()
                self.savedDestinationMatches = destinationID != nil && self.requestedDestination == destinationID
                // The session enters review only after the archive is installed successfully.
                // Keep its camera and world origin mounted while the saved route is inspected.
                let savedEntry = self.currentLibraryEntry
                if let savedEntry {
                    // Install already succeeded. Publish the durable-file state before any async index work.
                    let saved = RouteLibrary.Entry(id: savedEntry.id, name: savedEntry.name,
                        mapURL: savedEntry.mapURL, hasMap: true, hasSavedMap: true)
                    self.libraryEntries = self.libraryEntries.map { $0.id == saved.id ? saved : $0 }
                    if self.selectedPractice?.id == saved.id { self.selectedPractice = saved }
                }
                let savedID = savedEntry?.id
                Task {
                    if let savedID {
                        do { try await self.library.markSaved(savedID) }
                        catch {
                            self.notice = RouteNotice(title: self.text("Map saved", "地图已保存"),
                                message: self.text("The route list could not be updated. Open Routes to retry.", "路线列表未能更新，请返回列表后重试。"))
                        }
                    }
                    await self.reloadLibrary()
                }
            case .failure(let error):
                if !self.isCancelled(error) { self.showError(self.text("Could not save", "未能保存"), error) }
            }
        }
    }

    var hasRecordingData: Bool {
        route.state.pointCount > 0 || route.state.hasEntrancePhoto ||
            route.state.computerFrameCount > 0 || route.state.isWritingComputerFrame
    }

    func exit() {
        guard presentation.phase != .leaving else { return }
        if visitorSessionActive { finishVisitor(.ended, returnImmediately: true); return }
        if route.state.mode == .reviewing { finishCameraSession() }
        else if route.state.mode == .guiding { finishTrial(trial?.wasLocalized == true ? "not_assessed" : "ended_without_localization") }
        else if hasRecordingData { prompt = .exitScan }
        else { finishCameraSession() }
    }

    func discardScan(restart: Bool = false) {
        prompt = nil
        if restart { route.startRecording() } else { finishCameraSession() }
    }

    func captureFrame() {
        guard presentation.controlsEnabled, route.state.canCaptureComputerFrame else { return }
        if explainedFrames { route.captureComputerFrame() } else { prompt = .exportFrame }
    }

    func confirmFrameExport() {
        prompt = nil
        explainedFrames = true
        route.captureComputerFrame()
    }

    func receiveImport(_ result: Result<URL, Error>) {
        guard isIdle, !isBusy else { return }
        switch result {
        case .failure(let error): if !isCancelled(error) { showError(text("Cannot import route", "无法导入路线"), error) }
        case .success(let url):
            selectionRequest = nil
            pendingImport = (url, url.startAccessingSecurityScopedResource())
            if !practiceMode, route.state.hasSavedRoute { prompt = .replaceImport }
            else { performPendingImport() }
        }
    }

    func performPendingImport() {
        guard let pending = pendingImport else { return }
        pendingImport = nil
        prompt = nil
        if practiceMode {
            busy = true
            Task {
                defer { if pending.scoped { pending.url.stopAccessingSecurityScopedResource() } }
                do {
                    let raw = String(pending.url.deletingPathExtension().lastPathComponent.prefix(RouteLibrary.nameLimit))
                    let entry = try await library.importRoute(pending.url,
                        name: raw.isEmpty ? text("Imported route", "导入路线") : raw)
                    libraryEntries = try await library.entries()
                    busy = false
                    select(entry, scanIfNew: false)
                } catch {
                    busy = false
                    showError(text("Cannot import route", "无法导入路线"), error)
                }
            }
        } else {
            let destination = requestedDestination
            route.importRoute(from: pending.url, expectedDestinationID: destination) { [weak self] result in
                if pending.scoped { pending.url.stopAccessingSecurityScopedResource() }
                guard let self else { return }
                switch result {
                case .success:
                    self.resetDestinationBinding()
                    self.savedDestinationMatches = destination != nil && self.requestedDestination == destination
                    self.notice = RouteNotice(title: self.text("Route imported", "路线已导入"),
                        message: self.text("Start navigation in a scanned area.", "在采集过的区域开始导航。"))
                case .failure(let error):
                    if !self.isCancelled(error) { self.showError(self.text("Cannot import route", "无法导入路线"), error) }
                }
            }
        }
    }

    func cancelPrompt() {
        if prompt == .deleteRoute { pendingDeleteEntry = nil }
        if prompt == .unscannedRoute { pendingDraftEntry = nil }
        if prompt == .replaceImport, let pending = pendingImport {
            if pending.scoped { pending.url.stopAccessingSecurityScopedResource() }
            pendingImport = nil
        }
        prompt = nil
    }

    func updatePlacement(height: Float? = nil, side: Float? = nil) {
        if let height { signPlacement.height = height }
        if let side { signPlacement.sideOffset = side }
        route.setSignPlacement(signPlacement)
    }

    func observeLocalization() {
        guard route.state.mode == .guiding else { return }
        trial?.observe(localized: route.state.isLocalized)
        hasLocalizedInVisit = hasLocalizedInVisit || route.state.isLocalized
    }

    func finishTrial(_ verdict: String) {
        prompt = nil
        guard let trial else { finishCameraSession(); return }
        do {
            latestReport = try trial.finish(verdict: verdict)
            self.trial = nil
            pendingTrialVerdict = nil
            finishCameraSession()
        } catch {
            pendingTrialVerdict = verdict
            trialFailure = error.localizedDescription
            prompt = .failedTrial
        }
    }

    func retryTrial() { finishTrial(pendingTrialVerdict ?? "not_assessed") }
    func abandonTrial() { trial = nil; pendingTrialVerdict = nil; prompt = nil; finishCameraSession() }

    var promptTitle: String {
        switch prompt {
        case .unscannedRoute: return text("No saved map", "尚未保存地图")
        case .exitScan: return text("End this scan?", "结束本次采集？")
        case .restartScan: return text("Restart this scan?", "重新采集？")
        case .replacePractice: return text("Replace this route?", "替换这条路线？")
        case .saveDestination: return text("Where does this route lead?", "路线通向哪里？")
        case .replaceImport: return text("Replace the saved route?", "替换本机路线？")
        case .exportFrame: return text("Export camera frame?", "导出相机帧？")
        case .trialFeedback: return text("How did the route align?", "路线对齐效果如何？")
        case .failedTrial: return text("Field report not saved", "实测记录未保存")
        case .deleteRoute:
            return text("Delete “\(pendingDeleteEntry?.name ?? "")”?", "删除“\(pendingDeleteEntry?.name ?? "")”？")
        case nil: return ""
        }
    }

    var promptMessage: String {
        switch prompt {
        case .deleteRoute: return text("This route will be removed from the library.", "这条路线将从路线库中移除。")
        case .exitScan, .restartScan:
            var message = route.state.pointCount > 0 || route.state.hasEntrancePhoto
                ? text("Unsaved route data will be lost.", "尚未保存的路线数据会丢失。") : ""
            if route.state.computerFrameCount > 0 || route.state.isWritingComputerFrame {
                if !message.isEmpty { message += "\n" }
                message += text("Exported camera frames stay in Files.", "已导出的相机帧仍保留在「文件」中。")
            }
            return message
        case .replacePractice: return text("Your mall route is kept separately.", "商场路线单独保留。")
        case .saveDestination:
            return route.state.hasSavedRoute ? text("This replaces the saved route.", "本次保存会替换原路线。") : ""
        case .replaceImport: return text("Navigation will use the selected route after a successful import.", "导入成功后，导航会使用所选路线。")
        case .exportFrame: return text("Saves an image, camera parameters and pose to Files for computer mapping.", "将图像、相机参数和位置保存到「文件」，供电脑建图。")
        case .failedTrial: return trialFailure + "\n" + text("Try saving the report again, or exit without it.", "重试保存报告，或退出并放弃报告。")
        default: return ""
        }
    }

    private func isCancelled(_ error: Error) -> Bool {
        (error as NSError).domain == NSCocoaErrorDomain && (error as NSError).code == NSUserCancelledError
    }

    private func showError(_ title: String, _ error: Error) {
        notice = RouteNotice(title: title, message: error.localizedDescription)
    }
}
