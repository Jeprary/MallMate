import ARKit
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import Darwin

struct RouteProblem: LocalizedError {
    let message: RouteText
    var errorDescription: String? { message.localized }
    init(_ english: String, _ chinese: String) { message = RouteText(english, chinese) }
    init(_ message: RouteText) { self.message = message }
}

extension RouteText {
    func appendingDetail(from error: Error) -> RouteText {
        let detail = (error as? RouteProblem)?.message ?? RouteText(error.localizedDescription, error.localizedDescription)
        return RouteText(english + "\n" + detail.english, chinese + "\n" + detail.chinese)
    }
}

/// A route is a single replaceable file so an interrupted save cannot mix two scans.
enum RouteArchive {
    static let prefix = "routewalk.point."
    static let pointLimit = 512
    private static let fileLimit = 128 * 1024 * 1024

    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RouteWalk", isDirectory: true)
            .appendingPathComponent("步行路线.routewalk")
    }

    static var practiceURL: URL { url.deletingLastPathComponent().appendingPathComponent("Practice.routewalk") }

    private struct Envelope: Codable {
        let version: Int
        let worldMap: Data
        let entranceJPEG: Data?
        let destinationID: String?
        /// Optional for older archives. Reverses navigation order without rewriting the AR map.
        let navigationReversed: Bool?
    }

    /// Decoding finishes before this frozen map/anchor graph is handed to the main actor.
    /// No archive worker keeps or mutates the graph after the handoff.
    struct Loaded: @unchecked Sendable {
        let map: ARWorldMap
        let points: [ARAnchor]
        let photo: CGImage?
        let destinationID: String?
    }

    static func hasDestination(_ expected: String, in url: URL) throws -> Bool {
        struct Header: Decodable {
            let version: Int
            let destinationID: String?
        }
        let header = try PropertyListDecoder().decode(Header.self, from: data(at: url))
        return header.version == 1 && header.destinationID == expected
    }

    static func name(_ index: Int) -> String { prefix + String(index) }

    /// Refuse sparse, duplicate or non-finite points before using their transforms for rendering.
    static func orderedPoints(_ anchors: [ARAnchor], navigationReversed: Bool? = nil) throws -> [ARAnchor] {
        guard (2...pointLimit).contains(anchors.count) else {
            throw RouteProblem("A route must contain 2 to \(pointLimit) waypoints.", "路线文件需要包含 2 至 \(pointLimit) 个路点。")
        }
        var ordered = Array<ARAnchor?>(repeating: nil, count: anchors.count)
        var identifiers = Set<UUID>()
        for anchor in anchors {
            guard !(anchor is ARTrackable),
                  let label = anchor.name, label.hasPrefix(prefix),
                  let index = Int(label.dropFirst(prefix.count)),
                  ordered.indices.contains(index), label == name(index),
                  identifiers.insert(anchor.identifier).inserted, ordered[index] == nil,
                  finiteTransform(anchor.transform) else {
                throw RouteProblem("A waypoint has an invalid name, order or position.", "路线点的名称、顺序或位置无效。")
            }
            ordered[index] = anchor
        }
        let points = ordered.compactMap { $0 }
        for (a, b) in zip(points, points.dropFirst()) {
            let delta = b.transform.columns.3 - a.transform.columns.3
            let length = simd_length(SIMD2<Float>(delta.x, delta.z))
            guard length.isFinite && length > 0.001 else {
                throw RouteProblem("Adjacent waypoints overlap. The arrow direction is undefined.", "相邻路点重叠，无法确定箭头方向。")
            }
        }
        return navigationReversed == true ? Array(points.reversed()) : points
    }

    /// Anchor names and draft IDs stay in destination-to-entrance capture order.
    /// Validate that order before deriving the entrance-to-destination navigation view.
    static func navigationPointsForCapture(_ anchors: [ARAnchor], captureIDs: [UUID]) throws -> [ARAnchor] {
        let capturePoints = try orderedPoints(anchors)
        guard capturePoints.map(\.identifier) == captureIDs else {
            throw RouteProblem("The map is still registering waypoints. Try again in a moment.", "地图仍在登记路点，请稍后重试。")
        }
        return Array(capturePoints.reversed())
    }

    private static func finiteTransform(_ t: simd_float4x4) -> Bool {
        for c in [t.columns.0, t.columns.1, t.columns.2, t.columns.3] {
            guard c.x.isFinite && c.y.isFinite && c.z.isFinite && c.w.isFinite else { return false }
        }
        return true
    }

    static func data(at url: URL) throws -> Data {
        // Read from a single descriptor. Document providers may return an unknown on-disk size.
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size > 0 && size <= UInt64(fileLimit) else {
            throw RouteProblem("The route file is empty or exceeds the 128 MiB import limit.", "路线文件为空或超过本演示的 128 MiB 导入上限。")
        }
        try handle.seek(toOffset: 0)
        var data = Data()
        data.reserveCapacity(Int(size))
        while data.count < Int(size) {
            let remaining = Int(size) - data.count
            guard let part = try handle.read(upToCount: min(remaining, 1024 * 1024)), !part.isEmpty else {
                throw RouteProblem("The entire route file could not be read. Import it again.", "未能完整读取路线文件，请重新导入。")
            }
            data.append(part)
        }
        guard (try handle.read(upToCount: 1))?.isEmpty != false else {
            throw RouteProblem("The entire route file could not be read. Import it again.", "未能完整读取路线文件，请重新导入。")
        }
        return data
    }

    static func load(_ data: Data, expectedDestinationID: String? = nil) throws -> Loaded {
        guard let envelope = try? PropertyListDecoder().decode(Envelope.self, from: data) else {
            throw RouteProblem("This file does not contain a readable RouteWalk route.", "此文件不包含可读取的 RouteWalk 路线。")
        }
        guard envelope.version == 1 else { throw RouteProblem("This route file version is not supported.", "此版本的路线文件暂不支持。") }
        if let expectedDestinationID, envelope.destinationID != expectedDestinationID {
            throw RouteProblem("This route is not linked to the selected store. Import its route or scan one on site and link it.", "本机路线未关联所选店铺。请先导入该店路线，或在现场采集并关联。")
        }
        guard let map = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self,
                                                                from: envelope.worldMap) else {
            throw RouteProblem("The AR map could not be decoded.", "无法解码 AR 地图。")
        }
        return try Loaded(map: map, points: orderedPoints(map.anchors, navigationReversed: envelope.navigationReversed),
                          photo: envelope.entranceJPEG.map { try decodeThumbnail($0) },
                          destinationID: envelope.destinationID)
    }

    private static func decodeThumbnail(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source),
              UTType(type as String)?.conforms(to: .jpeg) == true else {
            throw RouteProblem("The entrance photo in this route file is invalid.", "路线文件中的入口参考图无效。")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1024
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw RouteProblem("The entrance photo is damaged.", "入口参考图损坏。")
        }
        return image
    }

    static func encode(map: ARWorldMap, photo: Data?, destinationID: String? = nil,
                       navigationReversed: Bool = false) throws -> Data {
        let mapData = try NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true)
        return try encode(worldMapData: mapData, photo: photo, destinationID: destinationID,
                          navigationReversed: navigationReversed)
    }

    /// Keeps envelope policy testable without decoding a device-specific ARWorldMap.
    static func encode(worldMapData: Data, photo: Data?, destinationID: String? = nil,
                       navigationReversed: Bool = false) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(Envelope(version: 1, worldMap: worldMapData, entranceJPEG: photo,
                                               destinationID: destinationID, navigationReversed: navigationReversed))
        guard data.count <= fileLimit else {
            throw RouteProblem("The map exceeds 128 MiB. Try scanning a shorter route.", "地图超过 128 MiB。请保留原路线，将新扫描缩短后重试。")
        }
        return data
    }

    static func stage(_ data: Data, for destination: URL = url) throws -> URL {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("tmp")
        do {
            try data.write(to: temporary, options: .completeFileProtectionUntilFirstUserAuthentication)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        return temporary
    }

    /// The stage and destination are on the same filesystem. POSIX rename is atomic across readers.
    static func install(_ staged: URL, to destination: URL = url) throws {
        guard Darwin.rename(staged.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
