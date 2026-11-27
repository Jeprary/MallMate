import ARKit
import CoreImage
import RealityKit
import Observation
import ImageIO
import OSLog

/// Map-capture availability follows Apple's persistence sample, not a relocalization guarantee.
/// https://developer.apple.com/documentation/arkit/saving-and-loading-world-data
/// `.extending` is capturable while the current area is still growing; `.mapped` offers
/// the highest restoration reliability. Normal tracking, fresh frames, all route anchors,
/// at least two waypoints and write exclusion remain separate RouteSession requirements.
/// https://developer.apple.com/documentation/arkit/arframe/worldmappingstatus-swift.enum/extending
/// https://developer.apple.com/documentation/arkit/arframe/worldmappingstatus-swift.enum/mapped
enum RouteMapSavePolicy {
    static func canCapture(_ status: ARFrame.WorldMappingStatus) -> Bool {
        switch status {
        case .extending, .mapped: return true
        case .notAvailable, .limited: return false
        @unknown default: return false
        }
    }
}

/// Product retry limits, not ARKit defaults. Normal frames never replenish this budget.
/// The installed SDK documents these sensor/tracking failures separately from authorization,
/// configuration and invalid-map errors; only the former are candidates for another run.
struct RouteRecoveryPolicy {
    private(set) var attempts = 0
    private static let delays: [TimeInterval] = [1, 3]

    static func canRetry(_ error: Error) -> Bool {
        switch (error as? ARError)?.code {
        case .sensorUnavailable, .sensorFailed, .worldTrackingFailed: true
        default: false
        }
    }

    func nextDelay(for error: Error) -> TimeInterval? {
        guard Self.canRetry(error), attempts < Self.delays.count else { return nil }
        return Self.delays[attempts]
    }

    mutating func recordAttempt() { attempts += 1 }
}

/// A single camera session shared by RealityView, map persistence and native coaching.
@MainActor @Observable
final class RouteSession: NSObject, @preconcurrency ARSessionDelegate {
    /// An ARKit snapshot is handed to exactly one consumer; no worker shares mutable map state.
    private struct MapSnapshot: @unchecked Sendable { let map: ARWorldMap? }
    enum Mode {
        case idle, recording, guiding, reviewing
        var detectsArrival: Bool { self == .guiding }
    }
    enum MappingState: Equatable, Sendable {
        case unavailable, limited, extending, mapped

        var description: RouteText {
            switch self {
            case .unavailable: RouteText("Map unavailable", "尚无地图")
            case .limited: RouteText("More scanning needed", "建图不足")
            case .extending: RouteText("Map expanding", "地图扩展中")
            case .mapped: RouteText("Current area mapped", "当前区域已建图")
            }
        }
    }

    struct State: Equatable {
        fileprivate(set) var mode: Mode = .idle
        fileprivate(set) var message = ""
        fileprivate(set) var recordingMessage = ""
        fileprivate(set) var recordingNeedsAttention = false
        fileprivate(set) var canPlacePoint = false
        fileprivate(set) var pointCount = 0
        fileprivate(set) var canSave = false
        fileprivate(set) var canUndo = false
        fileprivate(set) var isSaving = false
        fileprivate(set) var isLoadingFile = false
        fileprivate(set) var showsFeaturePoints = false
        fileprivate(set) var mappingStatusText = ""
        fileprivate(set) var mappingState: MappingState = .unavailable
        fileprivate(set) var computerFrameCount = 0
        fileprivate(set) var isWritingComputerFrame = false
        fileprivate(set) var canCaptureComputerFrame = false
        fileprivate(set) var computerExportNote: String?
        fileprivate(set) var hasArrived = false
        fileprivate(set) var isLocalized = false
        fileprivate(set) var isSceneReady = false
        fileprivate(set) var isSessionFailed = false
        fileprivate(set) var hasSavedRoute = false
        fileprivate(set) var hasEntrancePhoto = false
        fileprivate(set) var destinationID: String?
        fileprivate(set) var destinationName = RouteLanguage.text("Route destination", "路线终点")
    }

    var onChange: ((State) -> Void)?
    private(set) var state = State()
    private(set) var entrancePhoto: CGImage?
    private(set) var coachingActive = false
    private(set) var hasCameraFrame = false
    let session = ARSession()
    let renderer = RouteSignRenderer()
    let featurePoints = RouteFeaturePointRenderer()
    let savedRouteURL: URL

    @ObservationIgnored private lazy var photoContext = CIContext()
    private let archiveQueue = DispatchQueue(label: "routewalk.archive", qos: .userInitiated)
    private let lifecycleLogger = Logger(subsystem: "com.mallmate.routewalk", category: "ARLifecycle")
    @ObservationIgnored private var active: ARSession?
    @ObservationIgnored private var orderedIDs = [UUID]()
    @ObservationIgnored private var photoJPEG: Data?
    @ObservationIgnored private var arrivalPolicy = RouteArrivalPolicy()
    @ObservationIgnored private var tracking = RouteTrackingGate()
    @ObservationIgnored private var mapCapturable = false
    @ObservationIgnored private var observedMappingState: MappingState = .unavailable
    @ObservationIgnored private var trackingMessage = RouteText("Move slowly and look around walls and the floor.", "慢慢移动手机，同时看向墙角和地面。")
    @ObservationIgnored private var recordingTrackingHint = RouteText("Point at the floor", "对准地面")
    @ObservationIgnored private var actionMessage: RouteText?
    @ObservationIgnored private var recordingIssue: RouteText?
    @ObservationIgnored private var computerFrameFailed = false
    @ObservationIgnored private var destinationID: String?
    @ObservationIgnored private var savedExportNote: RouteText?
    @ObservationIgnored private var idleFailure: RouteText?
    @ObservationIgnored private var lastPositions = [SIMD3<Float>]()
    @ObservationIgnored private var hasLocalizedInSession = false
    @ObservationIgnored private var saveID: UUID?
    @ObservationIgnored private var pendingSave: ((Result<URL, Error>) -> Void)?
    @ObservationIgnored private var fileTaskID: UUID?
    @ObservationIgnored private var computerCapture: ComputerCapture?
    @ObservationIgnored private var language = RouteLanguage.current
    @ObservationIgnored private var spatialTracking: SpatialTrackingSession?
    @ObservationIgnored private var startupTask: Task<Void, Never>?
    @ObservationIgnored private var teardownTask: Task<Void, Never>?
    @ObservationIgnored private var runID: UUID?
    @ObservationIgnored private var activeConfiguration: ARWorldTrackingConfiguration?
    @ObservationIgnored private var spatialReady = false
    @ObservationIgnored private var suspended = false
    @ObservationIgnored private var hasRunSession = false
    @ObservationIgnored private var minimumFrameTimestamp: TimeInterval = -.infinity
    @ObservationIgnored private var hasFreshFrame = false
    @ObservationIgnored private var loggedFeaturePoints = false
    @ObservationIgnored private var loggedNormalFrame = false
    @ObservationIgnored private var loggedAlignedFrame = false
    @ObservationIgnored private var diagnosticTrackingState: String?
    @ObservationIgnored private var recoveryPolicy = RouteRecoveryPolicy()
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?
    @ObservationIgnored private var recoveryFrameTask: Task<Void, Never>?
    @ObservationIgnored private var recoveryFrameID: UUID?
    @ObservationIgnored private var restartGeneration = UUID()
    @ObservationIgnored private var recoverableFailure: NSError?
    // A canceled consumer cannot cancel ARKit's request; keep its lock until its callback returns.
    @ObservationIgnored private var mapSnapshotRequest: UUID?

    private var storeName: String? {
        destinationID == "B02001HUD4" ? RouteLanguage.text("UNIQLO", "优衣库") : nil
    }

    init(archiveURL: URL = RouteArchive.url) {
        savedRouteURL = archiveURL
        super.init()
        state.hasSavedRoute = FileManager.default.fileExists(atPath: savedRouteURL.path)
        NotificationCenter.default.addObserver(self, selector: #selector(languageDidChange),
                                               name: RouteLanguage.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(languageDidChange),
                                               name: NSLocale.currentLocaleDidChangeNotification, object: nil)
    }

    @objc private func languageDidChange() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.languageDidChange() }
            return
        }
        language = RouteLanguage.current
        renderer.destinationLabel = storeName
        if state.mode != .idle {
            renderer.update(points: lastPositions, isGuidance: state.mode != .recording)
        }
        publish {
            $0.destinationName = storeName ?? RouteLanguage.text("Route destination", "路线终点")
            $0.computerExportNote = savedExportNote?.localized
            if $0.mode == .idle {
                $0.message = $0.isLoadingFile ? RouteLanguage.text("Opening route…", "正在读取路线…") : idleFailure?.localized ?? ""
            }
        }
        refresh()
    }

    func startRecording() {
        guard !state.isLoadingFile else { return }
        guard ARWorldTrackingConfiguration.isSupported else {
            stop()
            idleFailure = RouteText("Open this on an iPhone that supports AR world tracking.", "这台设备不支持 AR 世界追踪，请在兼容的 iPhone 上打开。")
            publish { $0.message = idleFailure?.localized ?? "" }
            return
        }
        begin(mode: .recording, map: nil, points: [], photo: nil)
    }

    func startGuidance(expectedDestinationID: String? = nil, from routeFile: URL? = nil,
                       completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        startRestoredRoute(mode: .guiding, expectedDestinationID: expectedDestinationID,
                           from: routeFile, completion: completion)
    }

    /// Opens the saved map for read-only AR review, using the same real relocalization gate as guidance.
    func startReview(expectedDestinationID: String? = nil, from routeFile: URL? = nil,
                     completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        startRestoredRoute(mode: .reviewing, expectedDestinationID: expectedDestinationID,
                           from: routeFile, completion: completion)
    }

    private func startRestoredRoute(mode: Mode, expectedDestinationID: String?, from routeFile: URL?,
                                    completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        guard ARWorldTrackingConfiguration.isSupported else {
            completion(.failure(RouteProblem("This device does not support AR world tracking.", "此设备不支持 AR 世界追踪。")))
            return
        }
        let url = routeFile ?? savedRouteURL
        performFileTask(read: { try RouteArchive.load(RouteArchive.data(at: url),
                                                       expectedDestinationID: expectedDestinationID) },
                        apply: { [weak self] route in
                            self?.begin(mode: mode, map: route.map, points: route.points, photo: route.photo,
                                        destinationID: route.destinationID)
                        }, completion: completion)
    }

    private func begin(mode: Mode, map: ARWorldMap?, points: [ARAnchor], photo: CGImage?, destinationID: String? = nil) {
        stop()
        self.destinationID = destinationID
        renderer.destinationLabel = storeName
        renderer.recordingFromDestination = mode == .recording
        active = session
        session.delegateQueue = .main
        session.delegate = self
        orderedIDs = points.map(\.identifier)
        entrancePhoto = photo
        computerCapture = mode == .recording ? ComputerCapture() : nil
        tracking = RouteTrackingGate(restoring: map != nil)
        let configuration = ARWorldTrackingConfiguration()
        RouteCameraConfiguration.enableSupportedHDR(on: configuration)
        configuration.worldAlignment = .gravity
        if mode == .recording { configuration.planeDetection = [.horizontal] }
        configuration.initialWorldMap = map
        publish {
            $0.mode = mode
            $0.pointCount = points.count
            $0.hasEntrancePhoto = photo != nil
            $0.destinationID = destinationID
            $0.destinationName = storeName ?? RouteLanguage.text("Route destination", "路线终点")
            $0.showsFeaturePoints = mode == .recording
        }
        refresh()
        startSpatialTracking(configuration)
    }

    func stop() {
        arrivalPolicy.reset()
        cancelTrackingRestart()
        recoveryPolicy = RouteRecoveryPolicy()
        recoverableFailure = nil
        if let runID { RouteSessionDiagnostics.shared.record(runID, event: "stop") }
        let cancel = pendingSave
        pendingSave = nil
        saveID = nil
        fileTaskID = nil
        active?.delegate = nil
        active?.pause()
        active = nil
        renderer.root.isEnabled = false
        featurePoints.reset()
        coachingActive = false
        hasCameraFrame = false
        loggedFeaturePoints = false
        stopSpatialTracking()
        renderer.reset()
        renderer.recordingFromDestination = false
        orderedIDs.removeAll()
        lastPositions.removeAll()
        hasLocalizedInSession = false
        tracking = RouteTrackingGate()
        mapCapturable = false
        observedMappingState = .unavailable
        trackingMessage = RouteText("Move slowly and look around walls and the floor.", "慢慢移动手机，同时看向墙角和地面。")
        recordingTrackingHint = RouteText("Point at the floor", "对准地面")
        clearNotices()
        entrancePhoto = nil
        photoJPEG = nil
        destinationID = nil
        savedExportNote = nil
        idleFailure = nil
        computerCapture = nil
        let exists = FileManager.default.fileExists(atPath: savedRouteURL.path)
        publish {
            $0 = State()
            $0.hasSavedRoute = exists
        }
        cancel?(.failure(CocoaError(.userCancelled)))
    }

    func setFeaturePointsVisible(_ visible: Bool) {
        guard state.mode == .recording else { return }
        if !visible { featurePoints.reset() }
        publish { $0.showsFeaturePoints = visible }
        refresh()
        lifecycleLogger.notice("Feature display changed: enabled=\(visible, privacy: .public)")
    }

    func setSignPlacement(_ placement: RouteSignPlacement) {
        renderer.setPlacement(placement)
    }

    func setCoachingActive(_ active: Bool) {
        let enabled = active && state.mode != .idle && !tracking.failed && !suspended
        guard enabled != coachingActive else { return }
        coachingActive = enabled
        if let runID {
            RouteSessionDiagnostics.shared.record(runID, event: "coaching", fields: ["active": String(enabled)])
        }
    }

    func prepareARSurface() async -> Bool {
        lifecycleLogger.notice("RealityView surface waiting for the current spatial binding")
        await startupTask?.value
        let ready = spatialReady && state.mode != .idle && !Task.isCancelled
        lifecycleLogger.notice("RealityView surface prepared: ready=\(ready, privacy: .public)")
        return ready
    }

    private func startSpatialTracking(_ configuration: ARWorldTrackingConfiguration) {
        let token = UUID()
        runID = token
        var diagnosticFields = RouteCameraConfiguration.diagnosticFields(for: configuration)
        diagnosticFields["mode"] = String(describing: state.mode)
        diagnosticFields["savedMap"] = String(configuration.initialWorldMap != nil)
        diagnosticFields["expectedAnchors"] = String(orderedIDs.count)
        RouteSessionDiagnostics.shared.begin(token, fields: diagnosticFields)
        activeConfiguration = configuration
        let teardown = teardownTask
        let tracker = SpatialTrackingSession()
        spatialTracking = tracker
        lifecycleLogger.notice("Spatial binding queued: mode=\(String(describing: self.state.mode), privacy: .public), savedMap=\(configuration.initialWorldMap != nil, privacy: .public), features=\(self.state.showsFeaturePoints, privacy: .public)")
        startupTask = Task { [weak self] in
            await teardown?.value
            guard let self, self.runID == token, !Task.isCancelled else { return }
#if !targetEnvironment(simulator)
            // Attach RealityKit to our existing ARSession; this API leaves running ARSession to us.
            self.lifecycleLogger.notice("Spatial binding begin")
            RouteSessionDiagnostics.shared.record(token, event: "binding_begin")
            let unavailable = await tracker.run(.init(tracking: [.world]), session: self.session,
                                                arConfiguration: configuration)
            self.lifecycleLogger.notice("Spatial binding returned: unavailable=\(String(describing: unavailable), privacy: .public), delegateOwned=\(self.session.delegate === self, privacy: .public)")
            guard self.runID == token, !Task.isCancelled else { await tracker.stop(); return }
            RouteSessionDiagnostics.shared.record(token, event: "binding_returned", fields: [
                "missingCameraAuthorization": String(describing: unavailable?.missingCameraAuthorization),
                "worldUnavailable": String(unavailable?.anchor.contains(.world) == true),
                "delegateOwned": String(self.session.delegate === self)])
            if unavailable?.anchor.contains(.world) == true || unavailable?.missingCameraAuthorization == true {
                self.tracking.fail()
                self.setCoachingActive(false)
                self.trackingMessage = unavailable?.missingCameraAuthorization == true
                    ? RouteText("Allow camera access in Settings, then reopen the route.", "请在设置中允许使用相机，然后重新打开路线。")
                    : RouteText("World tracking is unavailable. Reopen the route.", "世界追踪暂不可用，请重新打开路线。")
                RouteSessionDiagnostics.shared.record(token, event: "binding_failed")
                self.refresh()
                return
            }
#endif
            self.spatialReady = true
            guard !self.suspended else { return }
            if self.tracking.failed, let error = self.recoverableFailure {
                self.scheduleAutomaticRecovery(after: error)
                self.refresh()
            } else {
                self.runConfiguredSession()
            }
        }
    }

    private func runConfiguredSession(resetTracking: Bool? = nil) {
        guard spatialReady, !suspended, !tracking.failed, active === session, let configuration = activeConfiguration else { return }
        let options: ARSession.RunOptions = (resetTracking ?? !hasRunSession) ? [.resetTracking, .removeExistingAnchors] : []
        arrivalPolicy.invalidatePending()
        minimumFrameTimestamp = session.currentFrame?.timestamp ?? -.infinity
        hasFreshFrame = false
        hasCameraFrame = false
        loggedNormalFrame = false
        loggedAlignedFrame = false
        diagnosticTrackingState = nil
        if let runID {
            RouteSessionDiagnostics.shared.record(runID, event: "run", fields: [
                "reset": String(!options.isEmpty), "savedMap": String(configuration.initialWorldMap != nil),
                "expectedAnchors": String(orderedIDs.count)])
        }
        session.run(configuration, options: options)
        hasRunSession = true
        lifecycleLogger.notice("ARSession run requested: reset=\(!options.isEmpty, privacy: .public), savedMap=\(configuration.initialWorldMap != nil, privacy: .public)")
    }

    private func stopSpatialTracking() {
        runID = nil
        activeConfiguration = nil
        spatialReady = false
        hasRunSession = false
        hasFreshFrame = false
        suspended = false
        let startup = startupTask
        startup?.cancel()
        startupTask = nil
        let tracker = spatialTracking
        spatialTracking = nil
        let previous = teardownTask
        // Serialize teardown before another binding can use the same camera session.
        teardownTask = Task {
            await previous?.value
            await startup?.value
            await tracker?.stop()
        }
    }

    func suspendForBackground() {
        guard active === session, !suspended else { return }
        cancelTrackingRestart()
        suspended = true
        hasCameraFrame = false
        // ARKit already pauses on interruption; another pause can suppress interruptionEnded.
        if !tracking.interrupted { session.pause() }
        tracking.pause()
        setCoachingActive(false)
        if let runID {
            RouteSessionDiagnostics.shared.record(runID, event: "suspend", fields: ["alreadyInterrupted": String(tracking.interrupted)])
        }
        mapCapturable = false
        refresh()
        abortSaveIfNeeded(RouteText("Scanning paused. Match the scanned area before saving again.", "采集已暂停，重新匹配已扫描区域后再保存。"))
    }

    func resumeFromBackground() {
        guard active === session, suspended else { return }
        suspended = false
        // Explicit pause/run recovery must not depend on interruptionEnded being delivered.
        tracking.resume()
        if let runID { RouteSessionDiagnostics.shared.record(runID, event: "resume") }
        if tracking.failed, let error = recoverableFailure {
            scheduleAutomaticRecovery(after: error)
        } else {
            runConfiguredSession()
            watchForRecoveryFrame()
        }
        refresh()
    }

    /// Native coaching reset preserves the saved map or the current unsaved route snapshot.
    func restartTracking() {
        guard active === session, !suspended, let configuration = activeConfiguration else { return }
        cancelTrackingRestart()
        guard saveID == nil else {
            notice(RouteText("A map snapshot is still finishing. Try again shortly.", "地图快照仍在处理，请稍后重试。"))
            return
        }
        let generation = restartGeneration
        let token = runID
        if let token { RouteSessionDiagnostics.shared.record(token, event: "coaching_reset") }
        if state.mode != .recording || orderedIDs.isEmpty {
            applyTrackingRestart(map: configuration.initialWorldMap, token: token)
        } else {
            guard mapSnapshotRequest == nil else {
                notice(RouteText("A map snapshot is still finishing. Try again shortly.", "地图快照仍在处理，请稍后重试。"))
                return
            }
            let request = UUID()
            mapSnapshotRequest = request
            let expectedIDs = orderedIDs
            session.getCurrentWorldMap { [weak self] map, error in
                let snapshot = MapSnapshot(map: map)
                DispatchQueue.main.async {
                    guard let self else { return }
                    if self.mapSnapshotRequest == request { self.mapSnapshotRequest = nil }
                    guard self.runID == token, self.restartGeneration == generation,
                          !self.suspended, self.orderedIDs == expectedIDs else { return }
                    guard let map = snapshot.map,
                          Set(expectedIDs).isSubset(of: Set(map.anchors.map(\.identifier))) else {
                        if let token {
                            RouteSessionDiagnostics.shared.record(token, event: "reset_snapshot_rejected", fields: [
                                "expectedAnchors": String(expectedIDs.count),
                                "snapshotAnchors": String(snapshot.map?.anchors.count ?? 0)], error: error as NSError?)
                        }
                        self.notice(RouteText("Cannot recover this scan yet. Saved route is unchanged.", "暂时无法恢复本次采集，已保存路线未改动。"))
                        return
                    }
                    self.applyTrackingRestart(map: map, token: token)
                }
            }
        }
    }

    private func applyTrackingRestart(map: ARWorldMap?, token: UUID?) {
        guard runID == token, active === session, !suspended, let configuration = activeConfiguration else { return }
        // Never reset a nonempty route from a missing or incomplete map.
        guard orderedIDs.isEmpty || map.map({ Set(orderedIDs).isSubset(of: Set($0.anchors.map(\.identifier))) }) == true else {
            trackingMessage = RouteText("Cannot recover this scan yet. Saved route is unchanged.", "暂时无法恢复本次采集，已保存路线未改动。")
            recordingTrackingHint = trackingMessage
            notice(trackingMessage)
            return
        }
        configuration.initialWorldMap = map
        tracking = RouteTrackingGate(restoring: map != nil)
        setCoachingActive(false)
        renderer.root.isEnabled = false
        featurePoints.reset()
        mapCapturable = false
        hasRunSession = false
        runConfiguredSession()
        watchForRecoveryFrame()
        refresh()
    }

    private func cancelTrackingRestart() {
        recoveryTask?.cancel()
        recoveryTask = nil
        cancelRecoveryFrameWatch()
        restartGeneration = UUID()
    }

    private func cancelRecoveryFrameWatch() {
        recoveryFrameTask?.cancel()
        recoveryFrameTask = nil
        recoveryFrameID = nil
    }

    /// Reuse the product's 15-second camera preparation limit. Relocalization has no deadline:
    /// any fresh camera frame ends this watch, even when tracking is still limited.
    private func watchForRecoveryFrame() {
        cancelRecoveryFrameWatch()
        guard active === session, spatialReady, hasRunSession, !suspended,
              !tracking.failed, let token = runID else { return }
        let request = UUID()
        let generation = restartGeneration
        recoveryFrameID = request
        recoveryFrameTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard let self, !Task.isCancelled, self.runID == token,
                  self.restartGeneration == generation, self.recoveryFrameID == request,
                  self.active === self.session, !self.suspended, !self.hasFreshFrame else { return }
            self.recoveryFrameTask = nil
            self.recoveryFrameID = nil
            self.tracking.fail()
            self.setCoachingActive(false)
            self.hasCameraFrame = false
            self.mapCapturable = false
            self.trackingMessage = RouteText("Camera did not restart. Try again.", "相机未恢复，请重试。")
            self.recordingTrackingHint = self.trackingMessage
            RouteSessionDiagnostics.shared.record(token, event: "recovery_frame_timeout", fields: [
                "timeoutSeconds": "15", "attempts": String(self.recoveryPolicy.attempts)])
            // A frame timeout is app state, not a synthesized ARKit error callback.
            if let error = self.recoverableFailure { self.scheduleAutomaticRecovery(after: error) }
            self.refresh()
            self.abortSaveIfNeeded(RouteText("The camera did not restart. The previous route is still saved.", "相机未恢复，未替换原路线。"))
        }
    }

    private func scheduleAutomaticRecovery(after error: Error) {
        guard active === session, spatialReady, !suspended,
              let token = runID, let delay = recoveryPolicy.nextDelay(for: error) else { return }
        trackingMessage = RouteText("Reconnecting camera…", "正在恢复相机…")
        recordingTrackingHint = trackingMessage
        guard recoveryTask == nil else { return }
        let generation = restartGeneration
        RouteSessionDiagnostics.shared.record(token, event: "recovery_scheduled", fields: [
            "attempt": String(recoveryPolicy.attempts + 1), "delaySeconds": String(delay)])
        recoveryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, !Task.isCancelled, self.runID == token,
                  self.restartGeneration == generation, self.active === self.session,
                  self.spatialReady, !self.suspended, self.tracking.failed,
                  let configuration = self.activeConfiguration else { return }
            self.recoveryTask = nil
            self.recoveryPolicy.recordAttempt()
            // A failed session may be unable to snapshot. For an unsaved draft, keeping its
            // coordinate system and anchors is safer than resetting from a missing/stale map.
            let preserveDraft = self.state.mode == .recording && !self.orderedIDs.isEmpty
            RouteSessionDiagnostics.shared.record(token, event: "recovery_attempt", fields: [
                "attempt": String(self.recoveryPolicy.attempts), "preserveDraft": String(preserveDraft)])
            if preserveDraft {
                self.tracking = RouteTrackingGate(restoring: true)
                self.setCoachingActive(false)
                self.renderer.root.isEnabled = false
                self.featurePoints.reset()
                self.mapCapturable = false
                // ARSession's documented empty-options behavior retains all existing anchors.
                self.runConfiguredSession(resetTracking: false)
                self.watchForRecoveryFrame()
                self.refresh()
            } else {
                self.applyTrackingRestart(map: configuration.initialWorldMap, token: token)
            }
        }
    }

    @ObservationIgnored private var placementFrame: ARFrame? {
        guard state.mode == .recording, saveID == nil, computerCapture?.isWriting != true,
              hasRunSession, hasFreshFrame, !suspended,
              tracking.canPlace, let frame = active?.currentFrame, case .normal = frame.camera.trackingState else { return nil }
        guard frame.timestamp > minimumFrameTimestamp else { return nil }
        return frame
    }

    func placePoint(at location: CGPoint, viewportSize: CGSize) {
        guard let session = active, let frame = placementFrame else {
            refresh()
            return
        }
        guard orderedIDs.count < RouteArchive.pointLimit else {
            notice(RouteText("This route has reached its waypoint limit.", "已达到本演示的路点上限。"))
            return
        }
        guard viewportSize.width > 0, viewportSize.height > 0,
              location.x >= 0, location.y >= 0,
              location.x <= viewportSize.width, location.y <= viewportSize.height else { return }
        let normalized = CGPoint(x: location.x / viewportSize.width, y: location.y / viewportSize.height)
        let query = frame.raycastQuery(from: normalized, allowing: .existingPlaneGeometry, alignment: .horizontal)
        guard let hit = session.raycast(query).first, let plane = hit.anchor as? ARPlaneAnchor,
              isPossibleFloor(plane) else {
            notice(RouteText("Floor not found. Aim at clear floor.", "未识别到地面，请对准空地。"))
            return
        }
        if let id = orderedIDs.last, let last = frame.anchors.first(where: { $0.identifier == id }) {
            let delta = hit.worldTransform.columns.3 - last.transform.columns.3
            guard simd_length(SIMD2<Float>(delta.x, delta.z)) >= 0.10 else {
                notice(RouteText("Too close to the last point. Move farther.", "路点太近，请再向前走。"))
                return
            }
        } else if !orderedIDs.isEmpty {
            notice(RouteText("Adding the last point. Try again shortly.", "正在登记上个路点，请稍后再试。"))
            return
        }
        var transform = matrix_identity_float4x4
        transform.columns.3 = hit.worldTransform.columns.3
        let anchor = ARAnchor(name: RouteArchive.name(orderedIDs.count), transform: transform)
        orderedIDs.append(anchor.identifier)
        tracking.pointsChanged()
        clearNotices()
        session.add(anchor: anchor)
        refresh()
    }

    private func isPossibleFloor(_ plane: ARPlaneAnchor) -> Bool {
        // The raycast already requires detected horizontal geometry. When ARKit has no
        // surface classification, the operator identifies the floor by aiming at it.
        switch plane.classification {
        case .floor, .none(_): return true
        default: return false
        }
    }

    func undoPoint() {
        guard state.mode == .recording, saveID == nil, let session = active,
              let id = orderedIDs.last else { return }
        guard let anchor = session.currentFrame?.anchors.first(where: { $0.identifier == id }) else {
            notice(RouteText("The waypoint is being added. Try undo again in a moment.", "正在登记路点，请稍后再撤销。"))
            return
        }
        session.remove(anchor: anchor)
        orderedIDs.removeLast()
        if orderedIDs.isEmpty {
            photoJPEG = nil
            entrancePhoto = nil
        }
        tracking.pointsChanged()
        clearNotices()
        refresh()
    }

    /// Only this explicit action keeps a single image. AR video frames never enter the route file.
    func captureEntrancePhoto() {
        guard state.mode == .recording, !orderedIDs.isEmpty, saveID == nil else { return }
        guard tracking.canPlace, let frame = active?.currentFrame, case .normal = frame.camera.trackingState else {
            refresh()
            return
        }
        // Both iPhone targets support portrait only. Native research frames remain unrotated.
        let orientation: CGImagePropertyOrientation = .right
        let oriented = CIImage(cvPixelBuffer: frame.capturedImage).oriented(orientation)
        let scale = min(1, 1024 / max(oriented.extent.width, oriented.extent.height))
        let preview = oriented.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let image = photoContext.createCGImage(preview, from: preview.extent) else {
            notice(RouteText("The reference photo could not be created. Try again.", "未能生成参考照，请重试。"))
            return
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let jpeg = photoContext.jpegRepresentation(of: preview, colorSpace: colorSpace,
                  options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.85]) else {
            notice(RouteText("The reference photo could not be saved. Try again.", "参考照无法保存，请重试。"))
            return
        }
        entrancePhoto = image
        photoJPEG = jpeg
        clearNotices()
        refresh()
    }

    func captureComputerFrame() {
        guard state.mode == .recording, let capture = computerCapture else { return }
        guard !capture.isWriting, saveID == nil else {
            actionMessage = RouteText("A file is being saved. Try again in a moment.", "正在写入，请稍后再拍。")
            refresh()
            return
        }
        guard tracking.canPlace, let frame = active?.currentFrame,
              case .normal = frame.camera.trackingState else {
            refresh()
            return
        }
        computerFrameFailed = false
        capture.capture(frame: frame) { [weak self, weak capture] result in
            guard let self, let capture, self.computerCapture === capture else { return }
            switch result {
            case .success:
                self.actionMessage = RouteText("Frame \(capture.count) saved. Capture another viewpoint or keep marking the route.", "已留第 \(capture.count) 帧。沿途换一个视角再拍，或继续标记地面。")
            case .failure(let error):
                self.actionMessage = RouteText("The computer frame could not be saved.", "电脑素材未写入。").appendingDetail(from: error)
                self.computerFrameFailed = true
            }
            self.refresh()
        }
        refresh()
    }

    func saveRoute(destinationID: String? = nil, completion: @escaping @MainActor (Result<URL, Error>) -> Void) {
        guard state.mode == .recording, state.canSave, mapSnapshotRequest == nil,
              let session = active, let frame = session.currentFrame,
              case .normal = frame.camera.trackingState,
              RouteMapSavePolicy.canCapture(frame.worldMappingStatus) else {
            completion(.failure(RouteProblem("Add at least two waypoints and scan until the map is ready to save.", "至少放两个路点，充分扫描周围环境，待地图就绪再保存。")))
            return
        }
        let request = UUID()
        mapSnapshotRequest = request
        saveID = request
        pendingSave = completion
        let ids = orderedIDs
        let jpeg = photoJPEG
        let destination = savedRouteURL
        clearNotices()
        refresh()
        session.getCurrentWorldMap { [weak self] map, error in
            guard let self else { return }
            DispatchQueue.main.async { [weak self] in
                if self?.mapSnapshotRequest == request { self?.mapSnapshotRequest = nil }
            }
            let snapshot = MapSnapshot(map: map)
            self.archiveQueue.async { [weak self] in
                let result = Result { () throws -> (URL, [ARAnchor]) in
                    guard let map = snapshot.map else { throw error ?? RouteProblem("ARKit could not capture the map. Scan a familiar area and try again.", "ARKit 未返回地图，请观察采集过的环境再试。") }
                    let routeIDs = Set(ids)
                    map.anchors = map.anchors.filter { routeIDs.contains($0.identifier) }
                    let points = try RouteArchive.navigationPointsForCapture(map.anchors, captureIDs: ids)
                    let staged = try RouteArchive.stage(RouteArchive.encode(map: map, photo: jpeg,
                                                                            destinationID: destinationID,
                                                                            navigationReversed: true), for: destination)
                    return (staged, points)
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.saveID == request else {
                        if case .success(let (temp, _)) = result { try? FileManager.default.removeItem(at: temp) }
                        return
                    }
                    var exportNote: RouteText?
                    let final = result.flatMap { (temp, points) -> Result<URL, Error> in
                        defer { try? FileManager.default.removeItem(at: temp) }
                        return Result {
                            try RouteArchive.install(temp, to: destination)
                            // Commit the navigation view only after the atomic file replacement succeeds.
                            // The anchors retain their original capture names for future archive loads.
                            self.orderedIDs = points.map(\.identifier)
                            self.lastPositions = points.map {
                                SIMD3<Float>($0.transform.columns.3.x, $0.transform.columns.3.y, $0.transform.columns.3.z)
                            }
                            if let capture = self.computerCapture, capture.count > 0 {
                                do {
                                    try capture.exportFinalWaypoints(points, destinationID: destinationID)
                                    exportNote = RouteText("The final waypoints are in waypoints.json with the captured frames.", "本次电脑素材已附上最终路点 waypoints.json。")
                                } catch {
                                    exportNote = RouteText("The route was saved, but the final waypoints could not be exported.", "导航地图已保存，电脑素材的最终路点未写入。").appendingDetail(from: error)
                                }
                            }
                            return destination
                        }
                    }
                    let callback = self.pendingSave
                    self.pendingSave = nil
                    self.saveID = nil
                    if case .success = final {
                        self.savedExportNote = exportNote
                        self.destinationID = destinationID
                        self.renderer.destinationLabel = self.storeName
                        self.renderer.recordingFromDestination = false
                        // Keep the same running session. This snapshot is only for a later explicit recovery.
                        self.activeConfiguration?.initialWorldMap = snapshot.map
                        self.featurePoints.reset()
                        self.clearNotices()
                        self.publish {
                            $0.mode = .reviewing
                            $0.hasSavedRoute = true
                            $0.computerExportNote = exportNote?.localized
                            $0.destinationID = destinationID
                            $0.destinationName = self.storeName ?? RouteLanguage.text("Route destination", "路线终点")
                            $0.showsFeaturePoints = false
                            $0.canPlacePoint = false
                            $0.canUndo = false
                            $0.canSave = false
                            $0.canCaptureComputerFrame = false
                            $0.isWritingComputerFrame = false
                            $0.isSaving = false
                            $0.recordingNeedsAttention = false
                        }
                        self.renderer.update(points: self.lastPositions, isGuidance: true)
                    }
                    self.refresh()
                    callback?(final)
                }
            }
        }
    }

    func checkSavedDestination(_ id: String, completion: @escaping @MainActor (Bool) -> Void) {
        let url = savedRouteURL
        archiveQueue.async {
            let matches = (try? RouteArchive.hasDestination(id, in: url)) == true
            DispatchQueue.main.async { completion(matches) }
        }
    }

    func importRoute(from url: URL, expectedDestinationID: String? = nil,
                     completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        let destination = savedRouteURL
        performFileTask(read: {
            let data = try RouteArchive.data(at: url)
            _ = try RouteArchive.load(data, expectedDestinationID: expectedDestinationID)
            return try RouteArchive.stage(data, for: destination)
        }, apply: { [weak self] staged in
            try RouteArchive.install(staged, to: destination)
            self?.publish { $0.hasSavedRoute = true }
        }, cleanup: { try? FileManager.default.removeItem(at: $0) }, completion: completion)
    }

    /// I/O and secure decoding happen off the frame-delivery queue. Only the active request
    /// can replace the stored route or start a new AR session.
    private func performFileTask<T: Sendable>(read: @escaping @Sendable () throws -> T,
                                             apply: @escaping @MainActor (T) throws -> Void,
                                             cleanup: @escaping @Sendable (T) -> Void = { _ in },
                                             completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        guard state.mode == .idle, fileTaskID == nil else {
            completion(.failure(RouteProblem("Finish the current operation first.", "请先结束当前操作。")))
            return
        }
        let request = UUID()
        fileTaskID = request
        idleFailure = nil
        publish { $0.isLoadingFile = true; $0.message = RouteText("Opening route…", "正在读取路线…").localized }
        archiveQueue.async { [weak self] in
            let result = Result { try read() }
            DispatchQueue.main.async { [weak self] in
                defer { if case .success(let value) = result { cleanup(value) } }
                guard let self, self.fileTaskID == request else {
                    completion(.failure(CocoaError(.userCancelled)))
                    return
                }
                self.fileTaskID = nil
                self.publish { $0.isLoadingFile = false; $0.message = "" }
                completion(result.flatMap { value in Result { try apply(value) } })
            }
        }
    }

    private func notice(_ message: RouteText) {
        recordingIssue = message
        actionMessage = message
        refresh()
    }

    private func clearNotices() {
        actionMessage = nil
        recordingIssue = nil
        computerFrameFailed = false
    }

    private func recordingPrompt(canPlace: Bool, canSave: Bool) -> (text: RouteText, needsAttention: Bool) {
        if tracking.interrupted { return (RouteText("Camera interrupted. Resume scanning.", "相机已中断，恢复后继续扫描。"), true) }
        if tracking.failed { return (recordingTrackingHint, true) }
        if saveID != nil { return (RouteText("Saving route…", "正在保存路线…"), true) }
        if tracking.needsRelocalization { return (RouteText("Look around a scanned area.", "扫视采集过的环境。"), true) }
        if !tracking.normal { return (recordingTrackingHint, true) }
        if computerCapture?.isWriting == true { return (RouteText("Saving camera frame…", "正在保存相机帧…"), true) }
        if let recordingIssue { return (recordingIssue, true) }
        if computerFrameFailed { return (RouteText("Frame could not be saved.", "当前帧未能保存。"), true) }
        if !orderedIDs.isEmpty && !tracking.anchorsPresent { return (RouteText("Registering route points…", "正在登记路点…"), true) }
        if canSave && !canPlace { return (RouteText("Waypoint limit reached. Save the route.", "已达路点上限，请保存路线。"), true) }
        if !canPlace && orderedIDs.count < RouteArchive.pointLimit { return (RouteText("Waiting for tracking…", "等待追踪就绪…"), true) }
        if orderedIDs.isEmpty { return (RouteText("Place destination", "放置终点"), false) }
        if orderedIDs.count == 1 { return (RouteText("Add waypoint", "添加路点"), false) }
        return canSave
            ? (RouteText("Ready to save", "可保存"), false)
            : (RouteText("Keep scanning", "继续扫视"), false)
    }

    private func publish(_ update: (inout State) -> Void) {
        let previous = state
        update(&state)
        if state != previous { onChange?(state) }
    }

    private func refresh() {
        guard state.mode != .idle else { return }
        if !state.mode.detectsArrival || !tracking.canDisplay || !hasFreshFrame || suspended {
            arrivalPolicy.invalidatePending()
        }
        let recording = state.mode == .recording
        let guide = state.mode == .guiding
        let reviewing = state.mode == .reviewing
        let viewing = guide || reviewing
        let ready = tracking.canDisplay
        let frame = recording ? placementFrame : nil
        let canPlacePoint = recording && frame != nil && orderedIDs.count < RouteArchive.pointLimit
        let canSave = recording && ready && mapCapturable && orderedIDs.count >= 2
            && mapSnapshotRequest == nil
            && frame.map { RouteMapSavePolicy.canCapture($0.worldMappingStatus) } == true
        let recordingStatus = recordingPrompt(canPlace: canPlacePoint, canSave: canSave)
        let displayedMappingState: MappingState
        if !hasCameraFrame || !hasFreshFrame || suspended || tracking.interrupted || tracking.failed {
            displayedMappingState = .unavailable
        } else {
            displayedMappingState = observedMappingState
        }
        renderer.root.isEnabled = ready
        featurePoints.root.isEnabled = state.mode == .recording && state.showsFeaturePoints && hasCameraFrame
            && !suspended && !tracking.interrupted && !tracking.failed
        let message: RouteText
        if tracking.failed {
            message = trackingMessage
        } else if tracking.interrupted {
            message = RouteText("Camera interrupted. When it resumes, look around a scanned area.", "相机已中断。恢复后，缓慢观察采集过的周围环境。")
        } else if tracking.needsRelocalization {
            message = viewing
                ? (hasLocalizedInSession ? RouteText("Look at a corner or doorframe you just passed and move slowly.", "对准刚经过的墙角或门框，缓慢移动。") : RouteText("Slowly look around an area you scanned.", "缓慢观察采集过的周围环境。"))
                : RouteText("Look around familiar surroundings and move slowly while the route realigns.", "缓慢观察采集过的周围环境，等待路线重新对齐。")
        } else if !tracking.normal {
            message = trackingMessage
        } else if saveID != nil {
            message = RouteText("Saving route…", "正在保存路线…")
        } else if computerCapture?.isWriting == true {
            message = RouteText("Saving the full-size image and camera data…", "正在写入原尺寸照片和同帧相机参数…")
        } else if let actionMessage {
            message = actionMessage
        } else if guide {
            message = ready ? RouteText("Follow the signs beside the path to the destination.", "已对齐。沿路侧悬浮箭头前进，在终点标记处结束。") : RouteText("Restoring route signs…", "正在恢复路线标记…")
        } else if reviewing {
            message = ready ? RouteText("Move around to review the saved route.", "移动查看已保存的路线。") : RouteText("Restoring route signs…", "正在恢复路线标记…")
        } else if orderedIDs.isEmpty {
            message = RouteText("Aim at the floor and tap the destination.", "对准可步行的地板，轻点终点。")
        } else if orderedIDs.count == 1 {
            message = entrancePhoto == nil
                ? RouteText("Walk toward the entrance. Mark turns, then the entrance.", "走向入口，标记拐角，最后标记入口。")
                : RouteText("Reference photo saved. Continue marking toward the entrance.", "参考照已保存，继续朝入口标记路点。")
        } else if !mapCapturable {
            message = RouteText("Keep adding waypoints. Scan nearby walls and doorframes until the local map is ready.", "可继续添加路点。缓慢扫视附近的墙面和门框，直到当前位置的地图就绪。")
        } else {
            message = RouteText("Mark the entrance last, then save.", "最后标记入口，然后保存。")
        }
        hasLocalizedInSession = hasLocalizedInSession || (guide && ready)
        publish {
            $0.hasArrived = arrivalPolicy.hasArrived
            $0.isSessionFailed = tracking.failed
            $0.pointCount = orderedIDs.count
            $0.canPlacePoint = canPlacePoint
            $0.recordingMessage = recording ? recordingStatus.text.localized(in: language) : ""
            $0.recordingNeedsAttention = recording && recordingStatus.needsAttention
            $0.isLocalized = guide && ready
            $0.isSceneReady = ready
            $0.canUndo = recording && !tracking.interrupted && !tracking.failed && !orderedIDs.isEmpty && saveID == nil
            $0.isWritingComputerFrame = recording && computerCapture?.isWriting == true
            $0.computerFrameCount = computerCapture?.count ?? 0
            $0.canCaptureComputerFrame = recording && tracking.canPlace && !$0.isWritingComputerFrame && saveID == nil
            $0.canSave = canSave
            $0.isSaving = saveID != nil
            $0.hasEntrancePhoto = entrancePhoto != nil
            $0.mappingState = displayedMappingState
            $0.mappingStatusText = displayedMappingState.description.localized(in: language)
            $0.message = message.localized(in: language)
        }
    }

    private func signal(for trackingState: ARCamera.TrackingState) -> RouteTrackingGate.Signal {
        switch trackingState {
        case .normal:
            return .normal
        case .limited(.relocalizing):
            clearNotices()
            trackingMessage = RouteText("Matching your surroundings…", "正在重新对齐环境。")
            recordingTrackingHint = RouteText("Matching the scanned area…", "正在匹配已扫描区域…")
            return .matchingMap
        case .limited(.insufficientFeatures):
            trackingMessage = RouteText("Few landmarks are visible. Aim at a doorframe, corner or textured wall.", "可识别的细节较少，请朝向固定门框、墙角或有纹理的侧墙。")
            recordingTrackingHint = RouteText("Few details. Aim at a wall or doorframe.", "可见细节太少，请对准墙面或门框。")
        case .limited(.excessiveMotion):
            trackingMessage = RouteText("Move more slowly and hold the phone steady.", "移动太快，请放慢速度并握稳手机。")
            recordingTrackingHint = RouteText("Moving too fast. Slow down.", "移动太快，请放慢速度。")
        case .limited(.initializing):
            trackingMessage = RouteText("Tracking is starting. Move the phone slowly.", "正在启动追踪，请缓慢移动手机。")
            recordingTrackingHint = RouteText("Starting tracking. Move slowly.", "正在启动追踪，请缓慢移动。")
        default:
            trackingMessage = RouteText("Tracking is unavailable. Look at a fixed landmark you just saw.", "追踪暂不可用，请对准刚才看过的固定环境。")
            recordingTrackingHint = RouteText("Tracking unavailable. Look around slowly.", "追踪暂不可用，请缓慢扫视。")
        }
        clearNotices()
        return .limited
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard session === active else { return }
        guard hasRunSession, !suspended, frame.timestamp.isFinite,
              frame.timestamp > minimumFrameTimestamp else {
            arrivalPolicy.invalidatePending()
            return
        }
        cancelRecoveryFrameWatch()
        guard !tracking.interrupted, !tracking.failed else {
            arrivalPolicy.invalidatePending()
            return
        }
        hasFreshFrame = true
        if !hasCameraFrame {
            hasCameraFrame = true
            lifecycleLogger.notice("First current-run camera frame: tracking=\(String(describing: frame.camera.trackingState), privacy: .public), observedFeatures=\(frame.rawFeaturePoints?.points.count ?? 0, privacy: .public)")
            if let runID {
                RouteSessionDiagnostics.shared.record(runID, event: "first_frame", fields: [
                    "tracking": String(describing: frame.camera.trackingState),
                    "observedFeatures": String(frame.rawFeaturePoints?.points.count ?? 0)])
            }
        }
        mapCapturable = RouteMapSavePolicy.canCapture(frame.worldMappingStatus)
        switch frame.worldMappingStatus {
        case .notAvailable: observedMappingState = .unavailable
        case .limited: observedMappingState = .limited
        case .extending: observedMappingState = .extending
        case .mapped: observedMappingState = .mapped
        @unknown default: observedMappingState = .unavailable
        }
        let positions = Dictionary(uniqueKeysWithValues: frame.anchors.compactMap { anchor -> (UUID, SIMD3<Float>)? in
            guard anchor.name?.hasPrefix(RouteArchive.prefix) == true else { return nil }
            let p = anchor.transform.columns.3
            return (anchor.identifier, SIMD3(p.x, p.y, p.z))
        })
        let current = orderedIDs.compactMap { positions[$0] }
        let observation = signal(for: frame.camera.trackingState)
        tracking.receivedFrame(observation, allExpectedAnchors: current.count == orderedIDs.count)
        let trackingState = String(describing: frame.camera.trackingState)
        if let runID, trackingState != diagnosticTrackingState {
            diagnosticTrackingState = trackingState
            RouteSessionDiagnostics.shared.record(runID, event: "tracking_changed", fields: [
                "tracking": trackingState, "matchingAnchors": String(current.count),
                "expectedAnchors": String(orderedIDs.count)])
        }
        if let runID, case .normal = frame.camera.trackingState, !loggedNormalFrame {
            loggedNormalFrame = true
            RouteSessionDiagnostics.shared.record(runID, event: "first_normal_frame", fields: [
                "matchingAnchors": String(current.count), "expectedAnchors": String(orderedIDs.count)])
        }
        if let runID, tracking.canDisplay, !loggedAlignedFrame {
            loggedAlignedFrame = true
            RouteSessionDiagnostics.shared.record(runID, event: "first_aligned_frame", fields: [
                "matchingAnchors": String(current.count), "expectedAnchors": String(orderedIDs.count)])
        }
        if state.mode == .recording && state.showsFeaturePoints {
            featurePoints.update(frame.rawFeaturePoints, cameraTransform: frame.camera.transform)
        }
        if tracking.canDisplay && current != lastPositions {
            renderer.update(points: current, isGuidance: state.mode != .recording)
            lastPositions = current
        }
        // The stored navigation order already accounts for a reversed route.
        // Resolve its final anchor from this frame, never from cached renderer positions.
        if state.mode.detectsArrival, let finalID = orderedIDs.last, let target = positions[finalID] {
            let camera = frame.camera.transform.columns.3
            arrivalPolicy.observe(camera: SIMD3(camera.x, camera.y, camera.z), target: target,
                                  timestamp: frame.timestamp, aligned: tracking.canDisplay)
        } else {
            arrivalPolicy.invalidatePending()
        }
        if !loggedFeaturePoints, state.mode == .recording, state.showsFeaturePoints,
           featurePoints.renderedPointCount > 0 {
            loggedFeaturePoints = true
            lifecycleLogger.notice("Live feature mesh populated: points=\(self.featurePoints.renderedPointCount, privacy: .public), enabled=\(self.featurePoints.root.isEnabled, privacy: .public), anchored=\(self.featurePoints.root.isAnchored, privacy: .public)")
        }
        // Publish once all frame and renderer work is complete: onChange may stop this session.
        refresh()
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        guard session === active, !suspended, !tracking.interrupted, !tracking.failed else { return }
        tracking.trackingChanged(signal(for: camera.trackingState))
        refresh()
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        guard session === active, anchors.contains(where: { orderedIDs.contains($0.identifier) }) else { return }
        tracking.pointsChanged()
        refresh()
    }

    func sessionWasInterrupted(_ session: ARSession) {
        guard session === active else { return }
        if let runID {
            RouteSessionDiagnostics.shared.record(runID, event: "interrupted", fields: ["suspended": String(suspended)])
        }
        // A background pause is recovered explicitly; its callbacks must not latch a second gate.
        guard !suspended else { return }
        tracking.interrupt()
        hasCameraFrame = false
        mapCapturable = false
        clearNotices()
        refresh()
        abortSaveIfNeeded(RouteText("Scanning was interrupted. Match a familiar area before saving again.", "采集被打断，之前的路线仍保留。重新对齐采集过的环境后再保存。"))
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        guard session === active else { return }
        if let runID {
            RouteSessionDiagnostics.shared.record(runID, event: "interruption_ended", fields: ["suspended": String(suspended)])
        }
        guard !suspended else { return }
        tracking.resume()
        recordingTrackingHint = RouteText("Look around a scanned area.", "扫视采集过的环境。")
        refresh()
    }

    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool {
        session === active
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        guard session === active else { return }
        // Coalesce duplicate recoverable callbacks while the same retry is queued.
        if recoveryTask == nil || !RouteRecoveryPolicy.canRetry(error) { cancelTrackingRestart() }
        recoverableFailure = RouteRecoveryPolicy.canRetry(error) ? error as NSError : nil
        tracking.fail()
        setCoachingActive(false)
        hasCameraFrame = false
        if let runID { RouteSessionDiagnostics.shared.record(runID, event: "session_failed", error: error as NSError) }
        lifecycleLogger.error("ARSession failed: \(error.localizedDescription, privacy: .public)")
        switch (error as? ARError)?.code {
        case .cameraUnauthorized: recordingTrackingHint = RouteText("Allow camera access in Settings.", "请在设置中允许使用相机。")
        case .sensorUnavailable, .sensorFailed: recordingTrackingHint = RouteText("Sensor unavailable.", "传感器暂不可用。")
        case .unsupportedConfiguration, .invalidConfiguration: recordingTrackingHint = RouteText("This scan configuration is unavailable.", "此设备无法使用当前采集配置。")
        case .insufficientFeatures: recordingTrackingHint = RouteText("Too few details. Restart near a textured wall.", "环境细节太少，请在有纹理的墙面旁重新开始。")
        default: recordingTrackingHint = RouteText("Tracking stopped.", "追踪已停止。")
        }
        trackingMessage = recordingTrackingHint
        scheduleAutomaticRecovery(after: error)
        refresh()
        abortSaveIfNeeded(RouteText("The AR session stopped. The previous route is still saved.", "AR 会话已停止，未替换原路线。"))
    }

    private func abortSaveIfNeeded(_ message: RouteText) {
        guard let callback = pendingSave else { return }
        pendingSave = nil
        saveID = nil
        refresh()
        callback(.failure(RouteProblem(message)))
    }
}
