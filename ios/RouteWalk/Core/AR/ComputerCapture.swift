import ARKit
import CoreImage
import Foundation

/// One operator-initiated still per tap. Pixel data and pose are taken from the same ARFrame.
@MainActor
final class ComputerCapture {
    struct CameraRecord: Encodable, Sendable {
        let schemaVersion = 1
        let sessionID: String
        let index: Int
        let timestamp: Double
        let image = "image.jpg"
        let width: Int
        let height: Int
        let intrinsics: [[Double]]
        let cameraToWorld: [[Double]]

    }

    struct Waypoint: Encodable, Sendable {
        let index: Int
        let role: String
        let position: [Double]
    }

    struct RoutePoints: Encodable, Sendable {
        let schemaVersion = 1
        let sessionID: String
        let destinationID: String?
        let coordinateSystem = "ARKit gravity-aligned world; x right, y up, z backward at origin; metres. Final map snapshot; camera poses at capture can drift. Register and verify against measured landmarks."
        let points: [Waypoint]
    }

    let id = UUID().uuidString
    private(set) var count = 0
    private(set) var isWriting = false
    private let documents: URL
    private let writer = Writer()

    /// ARKit supplies an immutable captured image. This task retains only its pixel buffer,
    /// never mutates it, and releases it after this one requested export completes.
    private struct PixelSnapshot: @unchecked Sendable { let buffer: CVPixelBuffer }

    private actor Writer {
        private let imageContext = CIContext()
        func write(_ snapshot: PixelSnapshot, record: CameraRecord, documents: URL, directory: URL) throws {
            let image = CIImage(cvPixelBuffer: snapshot.buffer, options: [.applyOrientationProperty: false])
                .settingProperties([:])
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let jpeg = imageContext.jpegRepresentation(of: image, colorSpace: colorSpace, options: [:]) else {
                throw RouteProblem("The full-size JPEG could not be encoded. This frame was not saved.", "原尺寸 JPEG 编码失败，本帧未保存。")
            }
            try ComputerCapture.publish(jpeg: jpeg, record: record, documents: documents, directory: directory)
        }
    }

    init(documents: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]) {
        self.documents = documents
    }

    var directory: URL {
        documents.appendingPathComponent("电脑建图素材", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }

    func capture(frame: ARFrame, completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        let camera = frame.camera
        capture(pixelBuffer: frame.capturedImage, imageResolution: camera.imageResolution,
                intrinsics: camera.intrinsics, cameraToWorld: camera.transform, timestamp: frame.timestamp,
                completion: completion)
    }

    func capture(pixelBuffer: CVPixelBuffer, imageResolution: CGSize, intrinsics: simd_float3x3,
                 cameraToWorld: simd_float4x4, timestamp: Double,
                 completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        guard !isWriting else {
            completion(.failure(RouteProblem("The previous frame is being saved. Try again in a moment.", "上一帧正在写入，请稍后再拍。")))
            return
        }
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        guard width == Int(imageResolution.width), height == Int(imageResolution.height) else {
            completion(.failure(RouteProblem("The image size does not match the camera calibration. This frame was not saved.", "图像与相机标定尺寸不一致，本帧未保存。")))
            return
        }
        let record = CameraRecord(sessionID: id, index: count + 1, timestamp: timestamp, width: width, height: height,
                                  intrinsics: (0..<3).map { row in (0..<3).map { Double(intrinsics[$0][row]) } },
                                  cameraToWorld: (0..<4).map { row in (0..<4).map { Double(cameraToWorld[$0][row]) } })
        isWriting = true
        let snapshot = PixelSnapshot(buffer: pixelBuffer)
        let documents = documents, directory = directory
        Task { [self] in
            let result: Result<Void, Error>
            do {
                try await writer.write(snapshot, record: record, documents: documents, directory: directory)
                result = .success(())
            } catch { result = .failure(error) }
            isWriting = false
            if case .success = result { count = record.index }
            completion(result)
        }
    }

    nonisolated private static func publish(jpeg: Data, record: CameraRecord, documents: URL, directory: URL) throws {
        let fm = FileManager.default
        let target = directory.appendingPathComponent(String(format: "frame-%06d", record.index), isDirectory: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let metadata = try encoder.encode(record)
        // Stage outside the public session directory. Move the completed pair into place together.
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: documents,
                                 create: true)
        defer { try? fm.removeItem(at: staging) }
        let pair = staging.appendingPathComponent("frame", isDirectory: true)
        try fm.createDirectory(at: pair, withIntermediateDirectories: false)
        try jpeg.write(to: pair.appendingPathComponent("image.jpg"))
        try metadata.write(to: pair.appendingPathComponent("camera.json"))
        if record.index == 1 {
            // Publish the first frame and its session directory together.
            let initial = staging.appendingPathComponent("session", isDirectory: true)
            try fm.createDirectory(at: initial, withIntermediateDirectories: false)
            try fm.moveItem(at: pair, to: initial.appendingPathComponent(target.lastPathComponent))
            try fm.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: initial, to: directory)
        } else {
            try fm.moveItem(at: pair, to: target)
        }
    }

    func exportFinalWaypoints(_ points: [ARAnchor], destinationID: String?) throws {
        guard count > 0 else { return }
        let converted = points.enumerated().map { index, anchor in
            let p = anchor.transform.columns.3
            let role = index == 0 ? "entrance" : (index == points.count - 1 ? "destination" : "via")
            return Waypoint(index: index, role: role, position: [Double(p.x), Double(p.y), Double(p.z)])
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(RoutePoints(sessionID: id, destinationID: destinationID, points: converted))
        try data.write(to: directory.appendingPathComponent("waypoints.json"), options: .atomic)
    }
}
