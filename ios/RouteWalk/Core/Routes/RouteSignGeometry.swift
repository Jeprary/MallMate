import RealityKit
import SwiftUI
import simd

/// Prototype dimensions in metres. The 8 cm depth is a project visibility trial, not an Apple default.
/// XY dimensions keep the previous artwork's approximate 500 px/metre footprint.
enum RouteSignGeometry {
    static let depth: Float = 0.08
    // Project appearance trials, not system Liquid Glass: white reading faces and clear-coated edges.
    static let arrowStrokeWidth: CGFloat = 0.07 // Equal-width round shaft and chevron, in metres.
    static let chamferRadius: Float = 0.012
    static let pointChamferRadius: Float = 0.004 // The ring wall is only 16 mm wide.
    static let surfaceRoughness: Float = 0.25
    static let clearcoat: Float = 0.7
    static let coatRoughness: Float = 0.18
    static let symbolCenterY: Float = 0.112
    static let labelSize = SIMD2<Float>(0.88, 0.18)
    static let labelCenterY: Float = -0.145
    static let labelFrontZ: Float = depth / 2 + 0.002
    static let symbols = ["up", "forward-left", "forward-right", "left", "right", "back", "end", "point"]

    @MainActor static func mesh(symbol: String) throws -> MeshResource {
        var options = MeshResource.ShapeExtrusionOptions()
        let bevel = symbol == "point" ? pointChamferRadius : chamferRadius
        // Native round chamfers extend beyond both caps. Preserve the total 8 cm envelope.
        options.extrusionMethod = .linear(depth: depth - 2 * bevel)
        options.chamferRadius = bevel
        options.chamferMode = .both
        // Project curve-quality trial: 24 segments per boundary span; chamfer resolution stays at its SDK default.
        options.boundaryResolution = .uniformSegmentsPerSpan(segmentCount: 24)
        // Retain the SDK's default chamfer profile and chamfer resolution.
        options.materialAssignment = .init(front: 0, back: 0, extrusion: 1, frontChamfer: 1, backChamfer: 1)
        let body = try MeshResource(extruding: outline(symbol: symbol), extrusionOptions: options)
        return try RouteSignOutline.partition(body, bevelRadius: bevel)
    }

    @MainActor static func materials() -> [any RealityKit.Material] {
        // Preserve display-white instead of compressing it toward a light background.
        var front = UnlitMaterial(applyPostProcessToneMap: false)
        front.color.tint = .white
        front.faceCulling = .back
        var edges = PhysicallyBasedMaterial()
        edges.baseColor = .init(tint: .white)
        edges.metallic = .init(floatLiteral: 0)
        edges.roughness = .init(floatLiteral: surfaceRoughness)
        edges.clearcoat = .init(floatLiteral: clearcoat)
        edges.clearcoatRoughness = .init(floatLiteral: coatRoughness)
        edges.blending = .opaque
        edges.faceCulling = .back
        return [front, edges, outlineMaterial()]
    }

    @MainActor static func outlineMaterial() -> UnlitMaterial {
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        material.color.tint = .init(white: 0.22, alpha: 1)
        material.faceCulling = .back
        return material
    }

    /// Every subpath is closed; holes are contained and never touch the outer contour.
    /// RealityKit applies even-odd filling when extruding these paths.
    static func outline(symbol: String) -> Path {
        if symbol == "point" {
            var ring = Path(ellipseIn: CGRect(x: -0.054, y: -0.054, width: 0.108, height: 0.108))
            ring.addEllipse(in: CGRect(x: -0.038, y: -0.038, width: 0.076, height: 0.076))
            return ring
        }
        if symbol == "end" {
            var pin = Path()
            pin.move(to: CGPoint(x: 0, y: -0.16))
            pin.addCurve(to: CGPoint(x: -0.12, y: 0.038),
                         control1: CGPoint(x: -0.014, y: -0.16), control2: CGPoint(x: -0.12, y: -0.038))
            pin.addCurve(to: CGPoint(x: 0, y: 0.158),
                         control1: CGPoint(x: -0.12, y: 0.106), control2: CGPoint(x: -0.068, y: 0.158))
            pin.addCurve(to: CGPoint(x: 0.12, y: 0.038),
                         control1: CGPoint(x: 0.068, y: 0.158), control2: CGPoint(x: 0.12, y: 0.106))
            pin.addCurve(to: CGPoint(x: 0, y: -0.16),
                         control1: CGPoint(x: 0.12, y: -0.038), control2: CGPoint(x: 0.014, y: -0.16))
            pin.closeSubpath()
            pin.addEllipse(in: CGRect(x: -0.046, y: 0.0, width: 0.092, height: 0.092))
            return pin
        }
        if symbol == "back" {
            let turn = CGMutablePath()
            turn.move(to: CGPoint(x: -0.125, y: -0.145))
            turn.addLine(to: CGPoint(x: -0.125, y: 0.06))
            turn.addCurve(to: CGPoint(x: 0.085, y: 0.06),
                          control1: CGPoint(x: -0.125, y: 0.20), control2: CGPoint(x: 0.085, y: 0.20))
            turn.addLine(to: CGPoint(x: 0.085, y: -0.165))
            let chevron = CGMutablePath()
            chevron.move(to: CGPoint(x: 0.005, y: -0.065))
            chevron.addLine(to: CGPoint(x: 0.085, y: -0.165))
            chevron.addLine(to: CGPoint(x: 0.165, y: -0.065))
            return roundStrokeUnion([turn, chevron])
        }
        let shaft = CGMutablePath()
        shaft.move(to: CGPoint(x: 0, y: -0.155))
        shaft.addLine(to: CGPoint(x: 0, y: 0.165))
        let chevron = CGMutablePath()
        chevron.move(to: CGPoint(x: -0.115, y: 0.04))
        chevron.addLine(to: CGPoint(x: 0, y: 0.165))
        chevron.addLine(to: CGPoint(x: 0.115, y: 0.04))
        // Boolean union removes overlapping subpaths before RealityKit's even-odd extrusion.
        let arrow = roundStrokeUnion([shaft, chevron])
        let angle: CGFloat = switch symbol {
        case "left": .pi / 2
        case "right": -.pi / 2
        case "forward-left": .pi / 4
        case "forward-right": -.pi / 4
        default: 0
        }
        return arrow.applying(CGAffineTransform(rotationAngle: angle))
    }

    private static func roundStrokeUnion(_ paths: [CGPath]) -> Path {
        // On the verified SDK, metre-scale stroke/union flattened cap curves; millimetre units preserved them.
        // Convert before both operations, then return the unchanged physical size in metres.
        let millimetresPerMetre: CGFloat = 1000
        let toMillimetres = CGAffineTransform(scaleX: millimetresPerMetre, y: millimetresPerMetre)
        let outlines = paths.map { path in
            let scaled = CGMutablePath()
            scaled.addPath(path, transform: toMillimetres)
            return Path(scaled.copy(strokingWithWidth: arrowStrokeWidth * millimetresPerMetre,
                                    lineCap: .round, lineJoin: .round, miterLimit: 1))
        }
        guard let first = outlines.first else { return Path() }
        let merged = outlines.dropFirst().reduce(first) { $0.union($1) }
        return merged.applying(CGAffineTransform(scaleX: 1 / millimetresPerMetre, y: 1 / millimetresPerMetre))
    }
}
