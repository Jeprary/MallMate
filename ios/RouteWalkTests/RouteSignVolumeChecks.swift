import RealityKit
import CoreGraphics
import XCTest
@testable import RouteWalk

@MainActor
final class RouteSignVolumeChecks: XCTestCase {
    func testArrowSilhouetteHasRoundCapsAndAnOpenChevron() {
        let outline = RouteSignGeometry.outline(symbol: "up")
        // These silhouette samples catch square/flattened caps even when the drawing API says .round.
        XCTAssertTrue(outline.contains(CGPoint(x: 0, y: -0.185)), "The tail must extend into a round cap")
        XCTAssertFalse(outline.contains(CGPoint(x: 0.030, y: -0.180)), "A round tail must exclude its bounding-box corners")
        XCTAssertTrue(outline.contains(CGPoint(x: 0, y: 0.190)), "The head join must retain its rounded tip")
        XCTAssertFalse(outline.contains(CGPoint(x: -0.060, y: 0.040)), "The chevron must preserve the open space beside the shaft")
    }

    func testTrimStaysOnFrontBevelAndLeavesWhiteSidesAndBack() throws {
        for symbol in RouteSignGeometry.symbols {
            let mesh = try RouteSignGeometry.mesh(symbol: symbol)
            let parts = mesh.contents.models.flatMap { Array($0.parts) }
            let bevel: Float = symbol == "point" ? 0.004 : 0.012
            let joinZ = mesh.bounds.max.z - bevel
            let trimZ = joinZ + bevel * Float(0.5).squareRoot()
            let trim = parts.filter { $0.materialIndex == 2 }
            XCTAssertFalse(trim.isEmpty, symbol)
            for part in trim {
                let positions = part.positions.elements
                let indices = try XCTUnwrap(part.triangleIndices, symbol).elements
                for index in stride(from: 0, to: indices.count - 2, by: 3) {
                    let ids = (0..<3).map { Int(indices[index + $0]) }
                    let levels = ids.map { positions[$0].z }
                    XCTAssertGreaterThanOrEqual(levels.min() ?? 0, joinZ - 0.00001, symbol)
                    XCTAssertLessThanOrEqual(levels.max() ?? 1, trimZ + 0.00001, symbol)
                    XCTAssertGreaterThan((levels.max() ?? 0) - (levels.min() ?? 0), 0.000001, symbol)
                }
            }
            let whiteNormals = parts.filter { $0.materialIndex == 1 }.flatMap { part -> [SIMD3<Float>] in
                guard let normals = part.normals?.elements, let indices = part.triangleIndices?.elements else { return [] }
                return indices.map { normals[Int($0)] }
            }
            XCTAssertTrue(whiteNormals.contains { $0.z < -0.001 }, "The back bevel must remain white: " + symbol)
            XCTAssertTrue(whiteNormals.contains { abs($0.z) < 0.0001 }, "The sidewall must remain white: " + symbol)
        }
    }

    func testAllSymbolsHaveRealEightCentimetreThicknessAndTrimMaterials() throws {
        var meshInventory = [[String: Any]]()
        for symbol in RouteSignGeometry.symbols {
            let mesh = try RouteSignGeometry.mesh(symbol: symbol)
            let parts = mesh.contents.models.flatMap { Array($0.parts) }
            meshInventory.append(["symbol": symbol,
                                  "partVertexCount": parts.reduce(0) { $0 + $1.positions.count },
                                  "triangles": parts.reduce(0) { $0 + ($1.triangleIndices?.count ?? 0) / 3 },
                                  "frontCap": capEvidence(mesh: mesh)])
            XCTAssertEqual(mesh.bounds.extents.z, 0.08, accuracy: 0.0001, symbol)
            XCTAssertGreaterThan(mesh.bounds.extents.x, 0.05, symbol)
            XCTAssertGreaterThan(mesh.bounds.extents.y, 0.05, symbol)
            XCTAssertEqual(mesh.expectedMaterialCount, 3, symbol)
            let assignments = Set(mesh.contents.models.flatMap { $0.parts.map(\.materialIndex) })
            XCTAssertEqual(assignments, [0, 1, 2], symbol)
        }
        let inventory = try JSONSerialization.data(withJSONObject: meshInventory, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: inventory, uniformTypeIdentifier: "public.json")
        attachment.name = "Route-sign-mesh-inventory"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func capEvidence(mesh: MeshResource) -> [String: Any] {
        var points = [SIMD3<Float>]()
        var triangleCount = 0
        var coversCenter = false
        func cross(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { a.x * b.y - a.y * b.x }
        for part in mesh.contents.models.flatMap({ Array($0.parts) }) where part.materialIndex == 0 {
            let positions = part.positions.elements
            let indices = part.triangleIndices?.elements ?? []
            for index in stride(from: 0, to: indices.count - 2, by: 3) {
                let a = positions[Int(indices[index])], b = positions[Int(indices[index + 1])], c = positions[Int(indices[index + 2])]
                guard a.z > mesh.bounds.center.z,
                      abs(a.z - b.z) < 0.00001, abs(a.z - c.z) < 0.00001 else { continue }
                triangleCount += 1
                points += [a, b, c]
                let pa = SIMD2<Float>(a.x, a.y), pb = SIMD2<Float>(b.x, b.y), pc = SIMD2<Float>(c.x, c.y)
                let s1 = cross(pb - pa, -pa), s2 = cross(pc - pb, -pb), s3 = cross(pa - pc, -pc)
                if (s1 >= -0.00000001 && s2 >= -0.00000001 && s3 >= -0.00000001)
                    || (s1 <= 0.00000001 && s2 <= 0.00000001 && s3 <= 0.00000001) { coversCenter = true }
            }
        }
        let minimum: [Float] = [points.map(\.x).min() ?? 0, points.map(\.y).min() ?? 0, points.map(\.z).min() ?? 0]
        let maximum: [Float] = [points.map(\.x).max() ?? 0, points.map(\.y).max() ?? 0, points.map(\.z).max() ?? 0]
        return ["triangles": triangleCount, "centerCovered": coversCenter,
                "rawMeshCenterZ": mesh.bounds.center.z,
                "minimum": minimum, "maximum": maximum]
    }

    func testRendererReusesMeshAndPreservesWorldPlacementWhileChangingTitle() async throws {
        let renderer = RouteSignRenderer()
        renderer.destinationLabel = "First destination"
        let points: [SIMD3<Float>] = [[0, 0, 1], .zero, [1, 0, 0]]
        renderer.update(points: points, isGuidance: true)
        let ready = await renderer.waitForResources()
        XCTAssertTrue(ready)
        let sign = try XCTUnwrap(renderer.root.findEntity(named: "sign-2"))
        let symbol = try XCTUnwrap(sign.findEntity(named: "symbol") as? ModelEntity)
        let mesh = try XCTUnwrap(symbol.model?.mesh)
        let label = try XCTUnwrap(sign.findEntity(named: "label") as? ModelEntity)
        let labelMesh = try XCTUnwrap(label.model?.mesh)
        let originalMaterial = try XCTUnwrap(label.model?.materials.first as? UnlitMaterial)
        let originalTexture = try XCTUnwrap(originalMaterial.color.texture?.resource)
        let orientation = sign.orientation.vector
        let expected = try XCTUnwrap(RouteSignLayout.descriptors(points: points, isGuidance: true,
                                                                 destinationLabel: "First destination").first { $0.index == 2 })
        XCTAssertEqual(sign.position, expected.position)
        XCTAssertEqual(symbol.visualBounds(relativeTo: sign).center.z, 0, accuracy: 0.0001)
        renderer.destinationLabel = "New destination"
        renderer.update(points: points, isGuidance: true)
        XCTAssertTrue(renderer.root.findEntity(named: "sign-2") === sign)
        XCTAssertTrue(symbol.model?.mesh === mesh)
        let updatedReady = await renderer.waitForResources()
        XCTAssertTrue(updatedReady)
        let material = try XCTUnwrap(label.model?.materials.first as? UnlitMaterial)
        let newTexture = try XCTUnwrap(material.color.texture?.resource)
        XCTAssertFalse(newTexture === originalTexture, "The changed destination must install its new title texture")
        XCTAssertTrue(label.model?.mesh === labelMesh)
        XCTAssertEqual(sign.position, expected.position)
        XCTAssertEqual(sign.orientation.vector, orientation)
        XCTAssertEqual(material.faceCulling, .back)
        XCTAssertFalse(material.writesDepth)
        XCTAssertGreaterThan(label.position.z, RouteSignGeometry.depth / 2)
        renderer.destinationLabel = "First destination"
        renderer.update(points: points, isGuidance: true)
        let restoredReady = await renderer.waitForResources()
        XCTAssertTrue(restoredReady)
        let restoredMaterial = try XCTUnwrap(label.model?.materials.first as? UnlitMaterial)
        XCTAssertTrue(restoredMaterial.color.texture?.resource === originalTexture,
                      "Returning to a previous title must reuse the cached texture")
        XCTAssertTrue(symbol.model?.mesh === mesh)
    }
}
