import RealityKit
import simd

/// Reassigns only the outer half of the existing front bevel; the geometry buffers stay unchanged.
@MainActor
enum RouteSignOutline {
    private enum Failure: Error { case noFrontRim }

    static func partition(_ body: MeshResource, bevelRadius: Float) throws -> MeshResource {
        var contents = body.contents
        let epsilon = Float.ulpOfOne * 64
        // Project sample: half the front quarter-circle. At a 12 mm bevel the XY band is ~3.515 mm.
        let frontJoinZ = body.bounds.max.z - bevelRadius
        let upperZ = frontJoinZ + bevelRadius * Float(0.5).squareRoot()
        var models = [MeshResource.Model]()
        var rimTriangleCount = 0
        for var model in contents.models {
            var parts = [MeshResource.Part]()
            for part in model.parts {
                guard part.materialIndex == 1, let indices = part.triangleIndices?.elements else {
                    parts.append(part)
                    continue
                }
                let positions = part.positions.elements
                var white = [UInt32](), rim = [UInt32]()
                for start in stride(from: 0, to: indices.count - 2, by: 3) {
                    let triangle = Array(indices[start..<(start + 3)])
                    let heights = triangle.map { positions[Int($0)].z }
                    let minimumZ = heights.min()!, maximumZ = heights.max()!
                    // Actual ring positions are stable around the silhouette; smoothed normals are not.
                    let isRim = minimumZ >= frontJoinZ - epsilon && maximumZ <= upperZ + epsilon
                        && maximumZ - minimumZ > epsilon
                    if isRim { rim.append(contentsOf: triangle) }
                    else { white.append(contentsOf: triangle) }
                }
                if !white.isEmpty {
                    var retained = part
                    retained.triangleIndices = MeshBuffers.TriangleIndices(white)
                    parts.append(retained)
                }
                if !rim.isEmpty {
                    var band = part
                    band.id = part.id + "-front-rim"
                    band.materialIndex = 2
                    band.triangleIndices = MeshBuffers.TriangleIndices(rim)
                    parts.append(band)
                    rimTriangleCount += rim.count / 3
                }
            }
            model.parts = MeshPartCollection(parts)
            models.append(model)
        }
        guard rimTriangleCount > 0 else { throw Failure.noFrontRim }
        contents.models = MeshModelCollection(models)
        // All positions, normals, other vertex buffers and instance transforms are retained verbatim.
        return try MeshResource.generate(from: contents)
    }
}
