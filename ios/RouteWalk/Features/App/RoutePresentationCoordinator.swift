import Observation
import SwiftUI

/// These brief fades are project UI choices, not durations prescribed by Apple.
/// https://developer.apple.com/design/human-interface-guidelines/motion
enum RouteMotion {
    static func screen(reduceMotion: Bool) -> Animation {
        .easeInOut(duration: reduceMotion ? 0.10 : 0.22)
    }

    static func list(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .snappy(duration: 0.22, extraBounce: 0)
    }
}

/// Keeps the live camera mounted until the returning page completely covers it.
@MainActor @Observable
final class RoutePresentationCoordinator {
    enum Phase: String { case routes, preparing, entering, camera, leaving }

    private(set) var phase = Phase.routes
    private(set) var cameraID = UUID()
    private(set) var cameraMounted = false
    private(set) var homeOpacity = 1.0
    private(set) var controlsOpacity = 0.0
    private(set) var reduceMotion = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var surfaceMounted = false
    @ObservationIgnored private var bindingReady = false
    @ObservationIgnored private var hasFrame = false
    @ObservationIgnored private var sceneActive = true
    @ObservationIgnored private var stopWhenCovered: (() -> Void)?
    @ObservationIgnored private var afterReturn: (() -> Void)?

    var isTransitioning: Bool { phase == .preparing || phase == .entering || phase == .leaving }
    var controlsEnabled: Bool { phase == .entering || phase == .camera }

    func setReduceMotion(_ value: Bool) { reduceMotion = value }

    func presentCamera() {
        guard phase == .routes else { return }
        generation = UUID()
        cameraID = UUID()
        surfaceMounted = false
        bindingReady = false
        hasFrame = false
        homeOpacity = 1
        controlsOpacity = 0
        cameraMounted = true
        phase = .preparing
    }

    func surfaceDidMount(id: UUID) {
        guard id == cameraID, phase == .preparing else { return }
        surfaceMounted = true
        revealIfReady()
    }

    func surfaceBindingFinished(id: UUID, ready: Bool) {
        guard id == cameraID, phase == .preparing else { return }
        bindingReady = ready
        revealIfReady()
    }

    func cameraFrameChanged(_ available: Bool) {
        // Tracking interruptions after entry use the existing AR coaching and status UI.
        guard phase == .preparing else { return }
        hasFrame = available
        revealIfReady()
    }

    private func revealIfReady() {
        guard phase == .preparing, sceneActive, surfaceMounted, bindingReady, hasFrame else { return }
        let token = generation
        phase = .entering
        withAnimation(RouteMotion.screen(reduceMotion: reduceMotion), completionCriteria: .removed) {
            homeOpacity = 0
            controlsOpacity = 1
        } completion: { [weak self] in
            guard let self, self.generation == token, self.phase == .entering else { return }
            self.phase = .camera
        }
    }

    func returnToRoutes(stopWhenCovered: @escaping () -> Void, afterReturn: @escaping () -> Void = {}) {
        if phase == .leaving {
            let previous = self.afterReturn
            self.afterReturn = { previous?(); afterReturn() }
            return
        }
        guard cameraMounted else { stopWhenCovered(); afterReturn(); return }
        generation = UUID()
        let token = generation
        self.stopWhenCovered = stopWhenCovered
        self.afterReturn = afterReturn
        phase = .leaving
        if !sceneActive {
            finishReturn(token: token)
            return
        }
        withAnimation(RouteMotion.screen(reduceMotion: reduceMotion), completionCriteria: .removed) {
            homeOpacity = 1
            controlsOpacity = 0
        } completion: { [weak self] in self?.finishReturn(token: token) }
    }

    private func finishReturn(token: UUID) {
        guard generation == token, phase == .leaving else { return }
        let stop = stopWhenCovered
        let returned = afterReturn
        stopWhenCovered = nil
        afterReturn = nil
        // Stop may clear the renderer; the home page is already fully opaque here.
        withoutAnimation {
            homeOpacity = 1
            controlsOpacity = 0
        }
        stop?()
        cameraMounted = false
        phase = .routes
        generation = UUID()
        returned?()
    }

    func engineBecameIdle() {
        guard cameraMounted, phase != .leaving else { return }
        returnToRoutes(stopWhenCovered: {})
    }

    func sceneActivityChanged(_ active: Bool) {
        sceneActive = active
        if !active, phase == .leaving {
            finishReturn(token: generation)
        } else if !active, phase == .entering {
            // Preserve an open scan when the app backgrounds during its brief reveal.
            generation = UUID()
            withoutAnimation { homeOpacity = 0; controlsOpacity = 1 }
            phase = .camera
        } else if active { revealIfReady() }
    }

    func completePendingReturn() {
        if phase == .leaving { finishReturn(token: generation) }
    }

    private func withoutAnimation(_ changes: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, changes)
    }
}

struct RouteCameraPreparingView: View {
    let title: String

    var body: some View {
        ProgressView(title).font(.subheadline).controlSize(.regular)
            .tint(.secondary).foregroundStyle(.secondary)
            .padding(.horizontal, 24).padding(.vertical, 22)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .accessibilityIdentifier("route.preparing")
            .allowsHitTesting(false)
    }
}
