#if DEBUG
import Observation
import RealityKit
import SwiftUI

/// A real virtual-camera scene using the production renderer; no AR session or map is started.
@MainActor
struct RouteSignVolumePreview: View {
    let viewpoint: String
    @State private var scene = RouteSignVolumeScene()

    var body: some View {
        RealityView { [scene = scene] content in
            content.camera = .virtual
            let camera = PerspectiveCamera()
            // A fixed 3 m distance and the SDK's default 60° field of view for every comparison.
            let angle: Float = switch viewpoint {
            case "angle": .pi / 4
            case "side": 80 * .pi / 180
            case "back": .pi
            default: 0
            }
            camera.look(at: .zero, from: [3 * sin(angle), 0, 3 * cos(angle)], relativeTo: nil)
            content.add(camera)
            // One SDK-default directional light (2145.7078 lux). Virtual-camera preview only;
            // production AR continues to use its real environment lighting.
            let light = DirectionalLight()
            light.look(at: .zero, from: [-2, 3, 4], relativeTo: nil)
            content.add(light)
            let lightBackground = ProcessInfo.processInfo.arguments.contains("--preview-light-background")
            var backdrop = UnlitMaterial(color: .init(white: lightBackground ? 0.94 : 0.32, alpha: 1))
            backdrop.faceCulling = .front
            content.add(ModelEntity(mesh: .generateBox(size: 20), materials: [backdrop]))
            if ProcessInfo.processInfo.arguments.contains("--preview-pattern-background") {
                guard let image = Self.contrastPattern(),
                      let texture = try? await TextureResource(image: image, options: .init(semantic: .color)) else {
                    scene.failed = true
                    return
                }
                var material = UnlitMaterial(applyPostProcessToneMap: false)
                material.color = .init(tint: .white, texture: .init(texture))
                let wall = ModelEntity(mesh: .generatePlane(width: 6, height: 6), materials: [material])
                let support = Entity()
                support.orientation = simd_quatf(angle: angle, axis: [0, 1, 0])
                wall.position = [0, 0, -1]
                support.addChild(wall)
                content.add(support)
            } else if ProcessInfo.processInfo.arguments.contains("--preview-context-background") {
                // Synthetic contrast panels, not a camera frame or a localization result.
                let wall = Entity()
                wall.orientation = simd_quatf(angle: angle, axis: [0, 1, 0])
                let panels: [(SIMD3<Float>, SIMD3<Float>, Float)] = [
                    ([-1.3, 0, -1], [2.6, 6, 0.02], 0.92),
                    ([1.3, 0, -1], [2.6, 6, 0.02], 0.18),
                    ([0, 0, -0.96], [0.08, 6, 0.02], 0.48),
                    ([-0.6, 0.6, -0.94], [1.2, 0.10, 0.02], 0.36),
                    ([0.65, -0.8, -0.94], [1.2, 0.12, 0.02], 0.76)
                ]
                for (position, size, gray) in panels {
                    var material = UnlitMaterial(applyPostProcessToneMap: false)
                    material.color.tint = .init(white: CGFloat(gray), alpha: 1)
                    let panel = ModelEntity(mesh: .generateBox(size: size), materials: [material])
                    panel.position = position
                    wall.addChild(panel)
                }
                content.add(wall)
            }
            scene.renderer.setPlacement(RouteSignPlacement(height: 0, sideOffset: 0))
            let symbol = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--preview-symbol=") })?
                .split(separator: "=", maxSplits: 1).last.map(String.init) ?? "right"
            let turnDegrees = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--preview-turn-degrees=") })?
                .split(separator: "=", maxSplits: 1).last.flatMap { Float($0) }
            let outgoing: SIMD3<Float> = switch symbol {
            case "left": [-1, 0, 0]
            case "forward-right": [1, 0, -1]
            case "forward-left": [-1, 0, -1]
            case "back": [0, 0, 1]
            default: [1, 0, 0]
            }
            let points: [SIMD3<Float>]
            let selected: Int
            if let degrees = turnDegrees, degrees.isFinite {
                let radians = degrees * .pi / 180
                points = [[0, 0, 1], .zero, [sin(radians), 0, -cos(radians)]]; selected = 1
            }
            else if symbol == "point" { points = [.zero]; selected = 0 }
            else if symbol == "end" { points = [[0, 0, 1], .zero]; selected = 1 }
            else if symbol == "up" { points = [[0, 0, 1], .zero, [0, 0, -1]]; selected = 1 }
            else { points = [[0, 0, 1], .zero, outgoing]; selected = 1 }
            scene.renderer.update(points: points, isGuidance: symbol != "point")
            for entity in scene.renderer.root.children where entity.name != "sign-\(selected)" { entity.isEnabled = false }
            scene.renderer.root.isEnabled = true
            content.add(scene.renderer.root)
            scene.subscription = content.subscribe(to: SceneEvents.Update.self) { [weak scene] _ in
                Task { @MainActor [weak scene] in scene?.renderedFrame() }
            }
            scene.resourcesReady = await scene.renderer.waitForResources()
            if ProcessInfo.processInfo.arguments.contains("--preview-hide-outline") {
                for sign in scene.renderer.root.children {
                    guard let symbol = sign.findEntity(named: "symbol") as? ModelEntity,
                          var model = symbol.model, model.materials.count == 3 else { continue }
                    model.materials[2] = model.materials[1]
                    symbol.model = model
                }
            }
            if !scene.resourcesReady {
                scene.failed = true
                scene.subscription?.cancel()
                scene.subscription = nil
            }
        }
        .ignoresSafeArea()
        .overlay {
            if ProcessInfo.processInfo.arguments.contains("--preview-guide-interface") {
                // Reuse the production SwiftUI shell so native glass is reviewed in context.
                GuideOverlayView(presentation: GuidePresentation(localized: true, destination: "UNIQLO"),
                                 exit: {}, showReference: {}) {
                    Text("Preview")
                }
            }
        }
        .overlay(alignment: .top) {
            Text("Camera off").font(.caption).padding(.horizontal, 12).padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule()).padding(.top, 12)
        }
        .overlay(alignment: .bottom) {
            Text(scene.ready ? "Ready" : (scene.failed ? "Resource failed" : "Loading"))
                .font(.caption).padding(8)
                .accessibilityIdentifier(scene.ready ? "sign.volume.ready" : "sign.volume.loading")
        }
    }

    /// Deterministic multi-edge background for comparison, not a captured real environment.
    private static func contrastPattern() -> CGImage? {
        let size = 512
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                      bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let levels: [CGFloat] = [0.98, 0.72, 0.23, 0.90, 0.43, 0.98, 0.82, 0.30]
        for column in 0..<8 {
            context.setFillColor(CGColor(gray: levels[column], alpha: 1))
            context.fill(CGRect(x: CGFloat(column * 64), y: 0, width: 64, height: CGFloat(size)))
        }
        for row in 0..<8 {
            context.setFillColor(CGColor(gray: row.isMultiple(of: 2) ? 0.18 : 0.95, alpha: 1))
            context.fill(CGRect(x: 0, y: CGFloat(row * 64 + 12), width: CGFloat(size), height: row.isMultiple(of: 2) ? 6 : 18))
        }
        return context.makeImage()
    }
}

@MainActor @Observable
private final class RouteSignVolumeScene {
    let renderer = RouteSignRenderer()
    var resourcesReady = false
    var ready = false
    var failed = false
    var subscription: EventSubscription?
    private var framesAfterResources = 0

    func renderedFrame() {
        guard resourcesReady, !ready else { return }
        framesAfterResources += 1
        if framesAfterResources >= 2 {
            ready = true
            subscription?.cancel()
            subscription = nil
        }
    }
}
#endif
