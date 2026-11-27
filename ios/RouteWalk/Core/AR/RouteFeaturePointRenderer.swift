import ARKit
import CoreGraphics
import OSLog
import RealityKit
import simd

/// Diagnostic live ARKit features, separate from route anchors and the saved world map.
@MainActor
final class RouteFeaturePointRenderer {
    let root = AnchorEntity(world: .zero)
    private let points = ModelEntity()
    private var material: UnlitMaterial?
    private var previous = [SIMD3<Float>]()
    private var previousRight: SIMD3<Float>?
    private var previousUp: SIMD3<Float>?
    private let logger = Logger(subsystem: "com.mallmate.routewalk", category: "FeaturePoints")
    private(set) var renderedPointCount = 0

    init() {
        root.name = "live-feature-points"
        root.isEnabled = false
        points.name = "feature-points"
        root.addChild(points)
        guard let image = Self.circleImage() else {
            logger.error("Feature point circle image could not be created")
            return
        }
        Task { [weak self] in
            do {
                // Keep the SDK's default mipmap generation and sampling behavior.
                let texture = try await TextureResource(image: image, options: .init(semantic: .color))
                var material = UnlitMaterial(texture: texture)
                material.blending = .transparent(opacity: .init(floatLiteral: 1))
                material.faceCulling = .back
                material.readsDepth = true
                // Transparent quad corners must not hide other features or route content.
                material.writesDepth = false
                guard let self else { return }
                self.material = material
                self.rebuild()
            } catch {
                self?.logger.error("Feature point texture failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func update(_ cloud: ARPointCloud?, cameraTransform: simd_float4x4) {
        let positions = cloud?.points ?? []
        guard !positions.isEmpty else {
            previous.removeAll()
            previousRight = nil
            previousUp = nil
            points.model = nil
            renderedPointCount = 0
            return
        }
        let rightColumn = cameraTransform.columns.0
        let upColumn = cameraTransform.columns.1
        let rawRight = SIMD3<Float>(rightColumn.x, rightColumn.y, rightColumn.z)
        let rawUp = SIMD3<Float>(upColumn.x, upColumn.y, upColumn.z)
        guard rawRight.x.isFinite, rawRight.y.isFinite, rawRight.z.isFinite,
              rawUp.x.isFinite, rawUp.y.isFinite, rawUp.z.isFinite,
              simd_length_squared(rawRight) > 0, simd_length_squared(rawUp) > 0 else { return }
        let right = simd_normalize(rawRight)
        let up = simd_normalize(rawUp)
        // Fixed feature positions still need fresh quad orientation when the camera turns.
        guard positions != previous || right != previousRight || up != previousUp else { return }
        previous = positions
        previousRight = right
        previousUp = up
        rebuild()
    }

    private func rebuild() {
        guard !previous.isEmpty, let material, let right = previousRight, let up = previousUp else { return }
        var vertices = [SIMD3<Float>]()
        var coordinates = [SIMD2<Float>]()
        var triangles = [UInt32]()
        vertices.reserveCapacity(previous.count * 4)
        coordinates.reserveCapacity(previous.count * 4)
        triangles.reserveCapacity(previous.count * 6)
        // Preserve the previous approximately 6 mm footprint; only its silhouette changes.
        let halfRight = right * 0.003
        let halfUp = up * 0.003
        let corners = [-halfRight - halfUp, halfRight - halfUp, halfRight + halfUp, -halfRight + halfUp]
        let uv: [SIMD2<Float>] = [[0, 0], [1, 0], [1, 1], [0, 1]]
        for position in previous {
            let start = UInt32(vertices.count)
            vertices.append(contentsOf: corners.map { position + $0 })
            coordinates.append(contentsOf: uv)
            triangles.append(contentsOf: [0, 1, 2, 0, 2, 3].map { start + $0 })
        }
        var descriptor = MeshDescriptor(name: "live-ar-features")
        descriptor.positions = MeshBuffers.Positions(vertices)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(coordinates)
        descriptor.primitives = .triangles(triangles)
        descriptor.materials = .allFaces(0)
        guard let mesh = try? MeshResource.generate(from: [descriptor]) else { return }
        points.model = ModelComponent(mesh: mesh, materials: [material])
        renderedPointCount = previous.count
    }

    private static func circleImage() -> CGImage? {
        // 32 px is a small project sampling choice, not an Apple size requirement.
        // The CoreGraphics sample verified clear corners and antialiased boundary pixels.
        let side = 32
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side))
        context.clear(bounds)
        context.setShouldAntialias(true)
        context.setFillColor(CGColor(red: 1, green: 0.82, blue: 0.05, alpha: 1))
        context.fillEllipse(in: bounds)
        return context.makeImage()
    }

    func reset() {
        previous.removeAll()
        previousRight = nil
        previousUp = nil
        points.model = nil
        renderedPointCount = 0
        root.isEnabled = false
    }
}
