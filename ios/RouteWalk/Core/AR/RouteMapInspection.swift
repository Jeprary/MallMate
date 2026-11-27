#if DEBUG
import ARKit
import CryptoKit
import Foundation

/// Explicit development-only inspection. Never opens the route library or starts an ARSession.
enum RouteMapInspection {
    nonisolated static func requestedRouteID(in arguments: [String]) -> UUID? {
        guard let flag = arguments.firstIndex(of: "--inspect-route"),
              arguments.indices.contains(flag + 1) else { return nil }
        return UUID(uuidString: arguments[flag + 1])
    }

    /// The worker owns every decoded AR object; only the small JSON report crosses back.
    nonisolated static func run(routeID: UUID) async {
        let data = await Task.detached(priority: .utility) {
            inspectAndWrite(routeID: routeID)
        }.value
        if let summary = String(data: data, encoding: .utf8) { print(summary) }
    }

    private struct Failure: Encodable {
        let domain: String
        let code: Int
        init(_ error: Error) {
            let failure = error as NSError
            domain = failure.domain
            code = failure.code
        }
    }

    private struct Report: Encodable {
        let schemaVersion = 1
        let routeID: UUID
        var status = "failed"
        var bytes: Int?
        var sha256Before: String?
        var sha256After: String?
        var sourceUnchanged: Bool?
        var features: Int?
        var waypoints: Int?
        var firstWaypointName: String?
        var lastWaypointName: String?
        var extent: [Float]?
        var extentFinite: Bool?
        var readError: Failure?
        var archiveError: Failure?
        var envelopeError: Failure?
        var decoderError: Failure?
        var nilDecoderResult: Bool?
        var rawDecoderSucceeded: Bool?
        var readAfterError: Failure?
        var reportWriteError: Failure?
    }

    private struct MapEnvelope: Decodable { let worldMap: Data }

    nonisolated private static func inspectAndWrite(routeID: UUID) -> Data {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RouteWalk", isDirectory: true)
        let source = base.appendingPathComponent("PracticeRoutes", isDirectory: true)
            .appendingPathComponent(routeID.uuidString).appendingPathExtension("routewalk")
        var report = Report(routeID: routeID)
        do {
            let data = try RouteArchive.data(at: source)
            report.bytes = data.count
            report.sha256Before = digest(data)
            inspectArchive(data, report: &report)
        } catch { report.readError = Failure(error) }
        do {
            report.sha256After = digest(try RouteArchive.data(at: source))
            if let before = report.sha256Before { report.sourceUnchanged = before == report.sha256After }
        } catch { report.readAfterError = Failure(error) }

        let directory = base.appendingPathComponent("Diagnostics", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encode(report).write(to: directory.appendingPathComponent("map-inspection.json"),
                                     options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { report.reportWriteError = Failure(error) }
        return encode(report)
    }

    nonisolated private static func inspectArchive(_ data: Data, report: inout Report) {
        do {
            let route = try RouteArchive.load(data)
            report.features = route.map.rawFeaturePoints.points.count
            report.waypoints = route.points.count
            report.firstWaypointName = route.points.first?.name
            report.lastWaypointName = route.points.last?.name
            let extent = route.map.extent
            let finite = extent.x.isFinite && extent.y.isFinite && extent.z.isFinite
            report.extentFinite = finite
            if finite { report.extent = [extent.x, extent.y, extent.z] }
            report.status = "decoded"
        } catch {
            report.archiveError = Failure(error)
            // RouteArchive deliberately presents a friendly error. Preserve only the raw
            // decoder's domain/code or nil result here, never map/photo data or userInfo.
            do {
                let envelope = try PropertyListDecoder().decode(MapEnvelope.self, from: data)
                do {
                    let map = try NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self,
                                                                   from: envelope.worldMap)
                    report.nilDecoderResult = map == nil
                    report.rawDecoderSucceeded = map != nil
                } catch {
                    report.decoderError = Failure(error)
                    report.rawDecoderSucceeded = false
                }
            } catch { report.envelopeError = Failure(error) }
        }
    }

    nonisolated private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func encode(_ report: Report) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(report)) ?? Data("{\"status\":\"failed\",\"reportEncodingFailed\":true}".utf8)
    }
}
#endif
