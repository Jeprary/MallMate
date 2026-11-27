import SwiftUI
import UIKit

/// This confirmation needs UIKit's dismissal completion before starting a camera request.
/// SwiftUI owns the surrounding interface and all ordinary notices.
@MainActor
struct RouteDraftAlertPresenter: UIViewControllerRepresentable {
    let model: RouteAppModel
    let active: Bool
    let requested: Bool

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIViewController(context: Context) -> HostController {
        let host = HostController()
        let coordinator = context.coordinator
        coordinator.host = host
        host.onReady = { [weak coordinator] in coordinator?.reconcile() }
        return host
    }

    func updateUIViewController(_ host: HostController, context: Context) {
        context.coordinator.update(active: active, requested: requested)
    }

    static func dismantleUIViewController(_ host: HostController, coordinator: Coordinator) {
        host.onReady = nil
        coordinator.invalidate()
    }

    final class HostController: UIViewController {
        var onReady: (@MainActor () -> Void)?

        override func loadView() {
            view = UIView(frame: .zero)
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            onReady?()
        }
    }

    @MainActor
    final class Coordinator {
        private enum Action: Sendable { case start, cancel }
        private let model: RouteAppModel
        weak var host: HostController?
        private var active = false
        private var requested = false
        private var alert: UIAlertController?
        private var presentationID: UUID?
        private var presenting = false
        private var transitioning = false
        private var invalidated = false

        init(model: RouteAppModel) { self.model = model }

        func update(active: Bool, requested: Bool) {
            self.active = active
            self.requested = requested
            reconcile()
        }

        func reconcile() {
            guard !invalidated, !presenting, !transitioning else { return }
            guard active, requested, model.prompt == .unscannedRoute else {
                if alert != nil { dismiss(action: nil) }
                return
            }
            guard alert == nil, let host, host.viewIfLoaded?.window != nil else { return }
            var ancestor: UIViewController? = host
            while let controller = ancestor {
                guard controller.presentedViewController == nil else { return }
                ancestor = controller.parent
            }
            let id = UUID()
            let controller = UIAlertController(title: model.promptTitle, message: model.promptMessage, preferredStyle: .alert)
            controller.addAction(UIAlertAction(title: model.text("Start scanning", "开始采集"), style: .default) { [weak self] _ in
                self?.dismiss(action: .start, expectedID: id)
            })
            controller.addAction(UIAlertAction(title: model.text("Cancel", "取消"), style: .cancel) { [weak self] _ in
                self?.dismiss(action: .cancel, expectedID: id)
            })
            alert = controller
            presentationID = id
            presenting = true
            host.present(controller, animated: true) { [weak self] in
                guard let self, self.presentationID == id, !self.invalidated else { return }
                self.presenting = false
                self.reconcile()
            }
        }

        private func dismiss(action: Action?, expectedID: UUID? = nil) {
            guard !invalidated, !transitioning, let alert, let id = presentationID,
                  expectedID == nil || expectedID == id else { return }
            transitioning = true
            let completed: @MainActor @Sendable () -> Void = { [weak self] in
                guard let self, !self.invalidated, self.presentationID == id else { return }
                self.alert = nil
                self.presentationID = nil
                self.presenting = false
                self.transitioning = false
                // Backgrounding or a changed source cancels the action without consuming the draft.
                if self.active, self.requested, self.model.prompt == .unscannedRoute {
                    switch action {
                    case .start: self.model.confirmScanDraft()
                    case .cancel: self.model.cancelPrompt()
                    case nil: break
                    }
                }
                self.reconcile()
            }
            if alert.isBeingDismissed, let transition = alert.transitionCoordinator,
               transition.animate(alongsideTransition: nil, completion: { _ in completed() }) {
                return
            }
            alert.dismiss(animated: true, completion: completed)
        }

        func invalidate() {
            invalidated = true
            active = false
            presentationID = nil
            alert?.dismiss(animated: false)
            alert = nil
        }
    }
}
