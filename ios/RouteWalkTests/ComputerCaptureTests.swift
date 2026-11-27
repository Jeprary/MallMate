import ARKit
import ImageIO
import XCTest
@testable import RouteWalk

final class ComputerCaptureTests: XCTestCase {
    @MainActor func testManualStillPublishesNativeRasterAndMatchedCalibrationWithRoutePoints() async throws {
        let fm = FileManager.default
        let docs = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: docs, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: docs) }
        let capture = ComputerCapture(documents: docs)
        XCTAssertFalse(fm.fileExists(atPath: capture.directory.path))

        let w = 96, h = 64
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA,
                                           [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                                           &buffer), kCVReturnSuccess)
        let image = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(image, [])
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(image)).assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            for x in 0..<w {
                let i = y * CVPixelBufferGetBytesPerRow(image) + x * 4
                bytes[i] = y >= h / 2 ? 255 : 0
                bytes[i+1] = x >= w / 2 ? 255 : 0
                bytes[i+2] = x < w / 2 && y < h / 2 ? 255 : 0
                bytes[i+3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(image, [])
        let k = simd_float3x3(columns: (SIMD3(101,0,0), SIMD3(0,102,0), SIMD3(47,31,1)))
        var pose = matrix_identity_float4x4
        pose.columns.3 = SIMD4(1.25, 2.5, -3, 1)
        let result: Result<Void,Error> = await withCheckedContinuation { continuation in
            capture.capture(pixelBuffer: image, imageResolution: CGSize(width: w, height: h), intrinsics: k,
                            cameraToWorld: pose, timestamp: 42.75) { continuation.resume(returning: $0) }
            XCTAssertTrue(capture.isWriting)
            capture.capture(pixelBuffer: image, imageResolution: CGSize(width: w, height: h), intrinsics: k,
                            cameraToWorld: pose, timestamp: 42.75) { busy in
                if case .success = busy { XCTFail("Overlapping captures must be rejected") }
            }
        }
        try result.get()
        XCTAssertEqual(capture.count, 1)
        let frame = capture.directory.appendingPathComponent("frame-000001")
        XCTAssertEqual(Set(try fm.contentsOfDirectory(atPath: frame.path)), ["image.jpg","camera.json"])
        let jpeg = try XCTUnwrap(CGImageSourceCreateWithURL(frame.appendingPathComponent("image.jpg") as CFURL, nil))
        let raster = try XCTUnwrap(CGImageSourceCreateImageAtIndex(jpeg,0,nil))
        XCTAssertEqual(raster.width,w)
        XCTAssertEqual(raster.height,h)
        // Native top-left is red, bottom-left blue, and top-right green. Sample well inside
        // each patch so JPEG chroma subsampling cannot move the expected dominant channel.
        for (x, y, channel) in [(16,16,0), (16,48,2), (80,16,1)] {
            let patch = try XCTUnwrap(raster.cropping(to: CGRect(x:x, y:y, width:1, height:1)))
            var pixel = [UInt8](repeating:0, count:4)
            try pixel.withUnsafeMutableBytes { ptr in
                let info = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
                let ctx = try XCTUnwrap(CGContext(data:ptr.baseAddress, width:1, height:1,
                                                  bitsPerComponent:8, bytesPerRow:4,
                                                  space:CGColorSpaceCreateDeviceRGB(), bitmapInfo:info))
                ctx.draw(patch, in:CGRect(x:0,y:0,width:1,height:1))
            }
            XCTAssertGreaterThan(Int(pixel[channel]), 200)
            XCTAssertLessThan(Int(pixel[(channel + 1) % 3]), 55)
        }
        let metaData = try Data(contentsOf: frame.appendingPathComponent("camera.json"))
        let meta = try XCTUnwrap(JSONSerialization.jsonObject(with: metaData) as? [String: Any])
        XCTAssertEqual(meta["timestamp"] as? Double, 42.75)
        XCTAssertEqual(meta["intrinsics"] as? [[Double]], [[101,0,47],[0,102,31],[0,0,1]])
        XCTAssertEqual(meta["cameraToWorld"] as? [[Double]], [[1,0,0,1.25],[0,1,0,2.5],[0,0,1,-3],[0,0,0,1]])
        let a = ARAnchor(name: RouteArchive.name(0), transform: matrix_identity_float4x4)
        let b = ARAnchor(name: RouteArchive.name(1), transform: pose)
        try capture.exportFinalWaypoints([a,b], destinationID: nil)
        let route = try Data(contentsOf: capture.directory.appendingPathComponent("waypoints.json"))
        let doc = try XCTUnwrap(JSONSerialization.jsonObject(with: route) as? [String: Any])
        let entries = try XCTUnwrap(doc["points"] as? [[String: Any]])
        XCTAssertEqual(entries.map {$0["role"] as? String}, ["entrance","destination"])
        XCTAssertEqual(entries.last?["position"] as? [Double], [1.25,2.5,-3])
        XCTAssertEqual(meta["sessionID"] as? String, doc["sessionID"] as? String)
    }
}
