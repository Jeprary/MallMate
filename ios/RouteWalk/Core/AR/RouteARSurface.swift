import ARKit
import RealityKit
import SwiftUI

/// RealityView renders the same ARSession that supplies the map and route-anchor observations.
struct RouteARSurface: View {
    let session: RouteSession
    let onPrepared: (@MainActor @Sendable (Bool) -> Void)?

    init(session: RouteSession, onPrepared: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        self.session = session
        self.onPrepared = onPrepared
    }

    var body: some View {
        RealityView { content in
            content.camera = .virtual
            content.add(session.renderer.root)
            content.add(session.featurePoints.root)
#if !targetEnvironment(simulator)
            // Do not let RealityView start its default camera session before our custom binding is ready.
            let ready = await session.prepareARSurface()
            guard !Task.isCancelled else { return }
            if ready { content.camera = .spatialTracking }
            onPrepared?(ready)
#else
            guard !Task.isCancelled else { return }
            onPrepared?(true)
#endif
        }
        .overlay { RouteCoachingSurface(route: session, sessionFailed: session.state.isSessionFailed) }
        .accessibilityIdentifier("route.ar-surface")
    }
}

/// ARKit provides its native coaching UI as a UIView; the app's own controls are SwiftUI.
private struct RouteCoachingSurface: UIViewRepresentable {
    let route: RouteSession
    let sessionFailed: Bool

    func makeCoordinator() -> Coordinator { Coordinator(route: route) }

    func makeUIView(context: Context) -> ARCoachingOverlayView {
        let overlay = ARCoachingOverlayView()
        overlay.session = route.session
        overlay.delegate = context.coordinator
        overlay.activatesAutomatically = !sessionFailed
        overlay.goal = route.state.mode == .recording ? .horizontalPlane : .tracking
        return overlay
    }

    func updateUIView(_ overlay: ARCoachingOverlayView, context: Context) {
        let goal: ARCoachingOverlayView.Goal = route.state.mode == .recording ? .horizontalPlane : .tracking
        if overlay.goal != goal { overlay.goal = goal }
        overlay.activatesAutomatically = !sessionFailed
        if sessionFailed || route.state.mode == .idle { overlay.setActive(false, animated: false) }
    }

    @MainActor final class Coordinator: NSObject, @preconcurrency ARCoachingOverlayViewDelegate {
        weak var route: RouteSession?
        init(route: RouteSession) { self.route = route }

        func coachingOverlayViewWillActivate(_ coachingOverlayView: ARCoachingOverlayView) {
            route?.setCoachingActive(true)
        }

        func coachingOverlayViewDidDeactivate(_ coachingOverlayView: ARCoachingOverlayView) {
            route?.setCoachingActive(false)
        }

        func coachingOverlayViewDidRequestSessionReset(_ coachingOverlayView: ARCoachingOverlayView) {
            route?.restartTracking()
        }
    }
}
