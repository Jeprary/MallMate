#if DEBUG
import SwiftUI

/// Uses the production coordinator and overlays, with no ARSession or camera permission request.
struct RouteTransitionPreview: View {
    @State private var presentation = RoutePresentationCoordinator()
    @State private var stops = 0
    @State private var showsNotice = false
    @State private var confirmsExit = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            if presentation.cameraMounted {
                ZStack {
                    RoutePreviewRoom().ignoresSafeArea()
                    ScanOverlayView(presentation: .init(instruction: "Camera-off interface preview", language: .english),
                        exit: { returnToRoutes() }, undo: {}, mark: { _ in }, save: {}) { EmptyView() }
                        .opacity(presentation.controlsOpacity)
                        .allowsHitTesting(presentation.phase == .entering || presentation.phase == .camera)
                }
                .id(presentation.cameraID)
                .onAppear { presentation.surfaceDidMount(id: presentation.cameraID) }
            }
            NavigationStack {
                List {
                    Button("Enter scan") { presentation.presentCamera() }
                        .accessibilityIdentifier("transition.enter")
                }
                .listStyle(.plain).navigationTitle("Routes").navigationBarTitleDisplayMode(.inline)
            }
            .opacity(presentation.homeOpacity)
            .allowsHitTesting(presentation.phase == .routes)
            .accessibilityHidden(presentation.phase != .routes)
            if presentation.phase == .preparing {
                VStack(spacing: 16) {
                    RouteCameraPreparingView(title: "Preparing preview")
                    // Harness-only cancellation exercises the coordinator without product UI.
                    Button("Cancel preview") { returnToRoutes() }
                        .accessibilityIdentifier("route.cancelPreparing")
                    Button("Show preview frame") {
                        presentation.surfaceBindingFinished(id: presentation.cameraID, ready: true)
                        presentation.cameraFrameChanged(true)
                    }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("transition.ready")
                }
            }
            VStack(spacing: 6) {
                Text("Motion preview\nCamera off").multilineTextAlignment(.center)
                Text(presentation.phase.rawValue).accessibilityIdentifier("transition.phase")
                Text("Stops: \(stops)").accessibilityIdentifier("transition.stops")
                if presentation.phase == .camera {
                    HStack(spacing: 14) {
                        Button("Confirm exit") { confirmsExit = true }.accessibilityIdentifier("transition.confirmExit")
                        Button("Return with notice") { returnToRoutes(notice: true) }.accessibilityIdentifier("transition.returnNotice")
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
            }
            .font(.caption).padding(.top, 68)
        }
        .onChange(of: reduceMotion, initial: true) { _, value in
            presentation.setReduceMotion(value || ProcessInfo.processInfo.arguments.contains("--preview-reduce-motion"))
        }
        .onChange(of: scenePhase, initial: true) { _, phase in presentation.sceneActivityChanged(phase == .active) }
        .confirmationDialog("End preview?", isPresented: $confirmsExit, titleVisibility: .visible) {
            Button("End preview", role: .destructive) { returnToRoutes(notice: true) }
            Button("Keep preview", role: .cancel) {}
        }
        .alert("Preview returned", isPresented: $showsNotice) {
            Button("OK", role: .cancel) {}
        } message: { Text("The home page covered the preview before its stop callback. No AR session ran.") }
    }

    private func returnToRoutes(notice: Bool = false) {
        presentation.returnToRoutes(stopWhenCovered: { stops += 1 }) {
            if notice { showsNotice = true }
        }
    }
}
#endif
