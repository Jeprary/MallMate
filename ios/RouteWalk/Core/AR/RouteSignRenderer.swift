import CoreGraphics
import OSLog
import RealityKit
import simd

/// World-space RealityKit entities in the saved ARKit map's coordinate system.
@MainActor
final class RouteSignRenderer {
    let root = AnchorEntity(world: .zero)
    var destinationLabel: String?
    var recordingFromDestination = false
    private var placement = RouteSignPlacement()
    private var previousPoints = [SIMD3<Float>]()
    private var previousMode = false
    private var previousRecordingFromDestination = false
    private var signs = [Int: Entity]()
    private var symbolKeys = [Int: String]()
    private var labelKeys = [Int: String]()
    private var meshes = [String: MeshResource]()
    private var materials = [String: UnlitMaterial]()
    private var loading = [String: Task<Void, Never>]()
    private let labelMesh = MeshResource.generatePlane(width: RouteSignGeometry.labelSize.x, height: RouteSignGeometry.labelSize.y)
    private let solidMaterials = RouteSignGeometry.materials()
    private let logger = Logger(subsystem: "com.mallmate.routewalk", category: "RouteSigns")

    init() { root.name = "route-signs"; root.isEnabled = false }

    func setPlacement(_ value: RouteSignPlacement) {
        guard value != placement, value.height.isFinite, value.sideOffset.isFinite else { return }
        placement = value
        update(points: previousPoints, isGuidance: previousMode)
    }

    func update(points: [SIMD3<Float>], isGuidance: Bool) {
        if previousPoints.count != points.count || previousMode != isGuidance
            || previousRecordingFromDestination != recordingFromDestination {
            reset()
            for index in points.indices {
                let sign = Entity()
                sign.name = "sign-\(index)"
                let symbol = ModelEntity()
                symbol.name = "symbol"
                symbol.isEnabled = false
                let label = ModelEntity(mesh: labelMesh)
                label.name = "label"
                label.position = [0, RouteSignGeometry.labelCenterY, RouteSignGeometry.labelFrontZ]
                label.isEnabled = false
                sign.addChild(symbol)
                sign.addChild(label)
                signs[index] = sign
                root.addChild(sign)
                if !isGuidance {
                    let handle = ModelEntity(mesh: .generatePlane(width: 0.224, height: 0.224))
                    handle.name = "ground-\(index)"
                    handle.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
                    handle.position = points[index] + [0, 0.014, 0]
                    handle.isEnabled = false
                    root.addChild(handle)
                    installArtwork(key: "ground", entity: handle, image: RouteSignArtwork.groundRing())
                }
            }
        }
        previousPoints = points
        previousMode = isGuidance
        previousRecordingFromDestination = recordingFromDestination
        for descriptor in RouteSignLayout.descriptors(points: points, isGuidance: isGuidance,
                                                      placement: placement, destinationLabel: destinationLabel,
                                                      recordingFromDestination: recordingFromDestination) {
            guard let sign = signs[descriptor.index],
                  let symbol = sign.findEntity(named: "symbol") as? ModelEntity,
                  let label = sign.findEntity(named: "label") as? ModelEntity else { continue }
            sign.position = descriptor.position
            sign.orientation = simd_quatf(angle: descriptor.yaw, axis: [0, 1, 0])
            root.findEntity(named: "ground-\(descriptor.index)")?.position = descriptor.groundPosition + [0, 0.014, 0]
            if symbolKeys[descriptor.index] != descriptor.symbol {
                do {
                    let mesh: MeshResource
                    if let cached = meshes[descriptor.symbol] { mesh = cached }
                    else {
                        mesh = try RouteSignGeometry.mesh(symbol: descriptor.symbol)
                        meshes[descriptor.symbol] = mesh
                    }
                    symbol.model = ModelComponent(mesh: mesh, materials: solidMaterials)
                    // Native extrusion origin is normalized so thickness straddles the original plane.
                    symbol.position = -mesh.bounds.center + [0, RouteSignGeometry.symbolCenterY, 0]
                    symbol.isEnabled = true
                    symbolKeys[descriptor.index] = descriptor.symbol
                } catch {
                    symbol.isEnabled = false
                    logger.error("Route sign geometry failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            let key = "label:" + descriptor.title
            if labelKeys[descriptor.index] != key || !label.isEnabled {
                labelKeys[descriptor.index] = key
                label.isEnabled = false
                installArtwork(key: key, entity: label,
                               image: materials[key] == nil && loading[key] == nil ? RouteSignArtwork.label(title: descriptor.title) : nil)
            }
        }
    }

    func reset() {
        root.children.removeAll()
        signs.removeAll()
        symbolKeys.removeAll()
        labelKeys.removeAll()
        previousPoints.removeAll()
    }

    /// Used by deterministic GPU previews and resource tests; no camera or tracking is implied.
    func waitForResources() async -> Bool {
        for task in Array(loading.values) { await task.value }
        return !signs.isEmpty && signs.values.allSatisfy {
            $0.findEntity(named: "symbol")?.isEnabled == true && $0.findEntity(named: "label")?.isEnabled == true
        }
    }

    private func installArtwork(key: String, entity: ModelEntity, image: CGImage?) {
        if let material = materials[key] {
            entity.model?.materials = [material]
            entity.isEnabled = true
            return
        }
        guard loading[key] == nil, let image else { return }
        loading[key] = Task { [weak self] in
            do {
                let texture = try await TextureResource(image: image, options: .init(semantic: .color))
                var material: UnlitMaterial
                if key == "ground" {
                    material = UnlitMaterial(texture: texture)
                } else {
                    material = UnlitMaterial(applyPostProcessToneMap: false)
                    material.color = .init(tint: .white, texture: .init(texture))
                }
                material.blending = .transparent(opacity: .init(floatLiteral: 1))
                material.faceCulling = .back
                material.writesDepth = false
                guard let self else { return }
                self.materials[key] = material
                self.loading[key] = nil
                if key == "ground" {
                    for handle in self.root.children.compactMap({ $0 as? ModelEntity })
                    where handle.name.hasPrefix("ground-") {
                        handle.model?.materials = [material]
                        handle.isEnabled = true
                    }
                } else {
                    // Apply only to the current title: old async work cannot paint a renamed route.
                    for (index, sign) in self.signs where self.labelKeys[index] == key {
                        guard let label = sign.findEntity(named: "label") as? ModelEntity else { continue }
                        label.model?.materials = [material]
                        label.isEnabled = true
                    }
                }
            } catch {
                self?.loading[key] = nil
                self?.logger.error("Route sign texture failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
