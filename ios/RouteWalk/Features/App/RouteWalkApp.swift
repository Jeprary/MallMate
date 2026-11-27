import SwiftUI

@main
struct RouteWalkApp: App {
    var body: some Scene {
        WindowGroup { RouteLaunchView() }
    }
}

private struct RouteLaunchView: View {
    var body: some View {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--transition-preview") {
            RouteTransitionPreview()
        } else if ProcessInfo.processInfo.arguments.contains("--handoff-preview") {
            RouteHandoffPreview()
        } else if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--sign-volume-preview=") }) {
            RouteSignVolumePreview(viewpoint: String(argument.dropFirst("--sign-volume-preview=".count)))
        } else if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--interface-preview=") }),
           let scenario = argument.split(separator: "=", maxSplits: 1).last {
            RouteInterfacePreview(scenario: String(scenario))
        } else { RouteAppContainer() }
#else
        RouteAppContainer()
#endif
    }
}

private struct RouteAppContainer: View {
    @State private var model = RouteAppModel()

    var body: some View {
        RouteRootView(model: model)
            .environment(\.locale, model.locale)
            .tint(Color(red: 0.07, green: 0.37, blue: 0.30))
            .onOpenURL { model.receive($0) }
            .task {
#if DEBUG
                if let routeID = RouteMapInspection.requestedRouteID(in: ProcessInfo.processInfo.arguments) {
                    await RouteMapInspection.run(routeID: routeID)
                    return
                }
                // Device-side URL delivery can be exercised without opening the camera.
                // The normal invocation parser validates this development-only input.
                if let value = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--visitor-url=") }),
                   let url = URL(string: String(value.dropFirst("--visitor-url=".count))) {
                    model.receive(url)
                    return
                }
#endif
                await model.restoreSelection()
            }
    }
}
