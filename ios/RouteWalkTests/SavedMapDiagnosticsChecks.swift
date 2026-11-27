import XCTest
import ARKit
import CryptoKit
@testable import RouteWalk

/// An opt-in, read-only check of a device capture copied into the simulator's Documents.
final class SavedMapDiagnosticsChecks: XCTestCase {
    func testProvidedDeviceMapDecodesWithLandmarksAndOrderedWaypoints() throws {
        guard ARWorldTrackingConfiguration.isSupported else {
            throw XCTSkip("Device ARWorldMap inspection requires a supported ARKit runtime. Use the read-only device inspector on iPhone.")
        }
        let documents = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        let url = documents.appendingPathComponent("diagnostic-saved-map.routewalk")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("No device capture was provided for this optional diagnostic.")
        }
        let input = try RouteArchive.data(at: url)
        let originalHash = SHA256.hash(data: input)
        let loaded = try RouteArchive.load(input)
        let featureCount = loaded.map.rawFeaturePoints.points.count
        XCTAssertGreaterThan(featureCount, 0)
        XCTAssertGreaterThanOrEqual(loaded.points.count, 2)
        XCTAssertEqual(Set(loaded.points.map(\.identifier)).count, loaded.points.count)
        let extent = loaded.map.extent
        for component in [extent.x, extent.y, extent.z] {
            XCTAssertTrue(component.isFinite)
            XCTAssertGreaterThanOrEqual(component, 0)
        }
        let report: [String: Any] = [
            "fileBytes": input.count,
            "featureCount": featureCount,
            "waypointCount": loaded.points.count,
            "extentMeters": [extent.x, extent.y, extent.z],
            "inputSHA256": originalHash.map { String(format: "%02x", $0) }.joined(),
            "validation": "Archive integrity only; no live relocalization was performed."
        ]
        let output = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try output.write(to: documents.appendingPathComponent("diagnostic-map-report.json"), options: .atomic)
        XCTAssertEqual(originalHash, SHA256.hash(data: try Data(contentsOf: url)))
    }
}
