import SwiftUI

/// Keeps a naming request alive while its native alert dismisses and the file operation completes.
@MainActor
struct RouteNamePromptPresenter: ViewModifier {
    @Bindable var model: RouteAppModel
    let active: Bool
    @State private var isPresented = false
    @State private var name = ""
    @State private var presentedRequest: RouteNameRequest?
    @State private var submittingRequestID: UUID?

    func body(content: Content) -> some View {
        content
            .alert(title, isPresented: $isPresented) {
                TextField(model.text("Route name", "路线名称"), text: $name)
                    .textInputAutocapitalization(.sentences)
                    .accessibilityIdentifier("practiceRoutes.name")
                    .submitLabel(.done).onSubmit(submit)
                Button(model.text("Cancel", "取消"), role: .cancel, action: cancel)
                    .accessibilityIdentifier("practiceRoutes.cancel")
                Button(model.text(presentedRequest?.entry == nil ? "Create" : "Save",
                                  presentedRequest?.entry == nil ? "创建" : "保存"), action: submit)
                    .disabled(!validName || model.busy)
            }
            .onChange(of: model.nameRequest?.id, initial: true) { _, id in
                if id == nil { isPresented = false }
                else { presentIfPossible() }
            }
            .onChange(of: active) { _, value in
                if value { presentIfPossible() } else { isPresented = false }
            }
            .onChange(of: model.notice?.id) { _, id in
                if id == nil { presentIfPossible() } else { isPresented = false }
            }
            .onChange(of: model.busy) { _, busy in if !busy { presentIfPossible() } }
            .onChange(of: isPresented) { previous, current in
                if previous && !current { model.nameEditorDidDismiss() }
            }
    }

    private var title: String {
        model.text(presentedRequest?.entry == nil ? "New route" : "Rename route",
                   presentedRequest?.entry == nil ? "新建路线" : "重命名路线")
    }

    private var validName: Bool {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && value.count <= RouteLibrary.nameLimit
            && value.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private func presentIfPossible() {
        guard active, !isPresented, !model.busy, model.notice == nil,
              submittingRequestID == nil, let request = model.nameRequest else { return }
        if presentedRequest?.id != request.id {
            presentedRequest = request
            name = request.entry?.name ?? ""
        }
        model.nameEditorDidPresent()
        isPresented = true
    }

    private func cancel() {
        if model.nameRequest?.id == presentedRequest?.id { model.nameRequest = nil }
        isPresented = false
    }

    private func submit() {
        guard active, validName, !model.busy, submittingRequestID == nil,
              let request = presentedRequest, model.nameRequest?.id == request.id else { return }
        let submittedName = name
        submittingRequestID = request.id
        isPresented = false
        Task {
            await model.submitName(submittedName, for: request.entry)
            guard submittingRequestID == request.id else { return }
            submittingRequestID = nil
            presentIfPossible()
        }
    }
}
