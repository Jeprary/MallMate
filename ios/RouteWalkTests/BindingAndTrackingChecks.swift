import XCTest
import ARKit
@testable import RouteWalk

final class BindingAndTrackingChecks: XCTestCase {
    func testExplicitPauseRetainsAlignmentButRequiresFreshNormalFrameAndAnchors() {
        var gate = RouteTrackingGate(restoring: true)
        gate.receivedFrame(.normal, allExpectedAnchors: true)
        XCTAssertTrue(gate.canDisplay)
        gate.pause()
        XCTAssertFalse(gate.canPlace)
        XCTAssertFalse(gate.canDisplay)
        gate.resume()
        gate.trackingChanged(.normal)
        XCTAssertFalse(gate.canPlace)
        XCTAssertFalse(gate.canDisplay)
        gate.receivedFrame(.normal, allExpectedAnchors: false)
        XCTAssertFalse(gate.canDisplay)
        gate.receivedFrame(.normal, allExpectedAnchors: true)
        XCTAssertTrue(gate.canDisplay)
    }

    func testRestoredRouteAcceptsNormalFrameWithoutPriorMatchingSignal() {
        var gate = RouteTrackingGate(restoring: true)
        gate.trackingChanged(.normal)
        XCTAssertFalse(gate.canPlace)
        XCTAssertFalse(gate.canDisplay)
        gate.receivedFrame(.normal, allExpectedAnchors: true)
        XCTAssertFalse(gate.needsRelocalization)
        XCTAssertTrue(gate.canPlace)
        XCTAssertTrue(gate.canDisplay)
    }

    func testRestoredRouteWaitsForAllAnchorsWithoutPriorMatchingSignal() {
        var gate = RouteTrackingGate(restoring: true)
        gate.receivedFrame(.normal, allExpectedAnchors: false)
        XCTAssertTrue(gate.needsRelocalization)
        XCTAssertFalse(gate.canPlace)
        XCTAssertFalse(gate.canDisplay)
        gate.receivedFrame(.normal, allExpectedAnchors: true)
        XCTAssertFalse(gate.needsRelocalization)
        XCTAssertTrue(gate.canPlace)
        XCTAssertTrue(gate.canDisplay)
    }

    func testGuideRequiresAllAnchorsInNormalFrameAfterMatchingSignal() {
        var gate = RouteTrackingGate(restoring: true)
        gate.trackingChanged(.matchingMap)
        gate.trackingChanged(.normal)
        XCTAssertFalse(gate.canDisplay)
        gate.receivedFrame(.normal, allExpectedAnchors: false)
        XCTAssertFalse(gate.canDisplay)
        gate.receivedFrame(.normal, allExpectedAnchors: true)
        XCTAssertTrue(gate.canDisplay)
        gate.receivedFrame(.normal, allExpectedAnchors: false)
        XCTAssertFalse(gate.canDisplay)
        gate.receivedFrame(.normal, allExpectedAnchors: true)
        XCTAssertTrue(gate.canDisplay)
        gate.trackingChanged(.limited)
        XCTAssertFalse(gate.canDisplay)
        gate.trackingChanged(.normal)
        XCTAssertFalse(gate.canDisplay)
        gate.receivedFrame(.normal, allExpectedAnchors: true)
        XCTAssertTrue(gate.canDisplay)
    }

    func testInterruptionCanRecoverWhenMatchingSignalWasDiscarded() {
        var gate = RouteTrackingGate()
        gate.receivedFrame(.normal, allExpectedAnchors: true)
        XCTAssertTrue(gate.canPlace)
        XCTAssertTrue(gate.canDisplay)
        gate.interrupt()
        gate.trackingChanged(.matchingMap)
        gate.receivedFrame(.normal, allExpectedAnchors: true)
        XCTAssertFalse(gate.canDisplay)
        gate.pause()
        XCTAssertTrue(gate.interrupted)
        gate.resume()
        gate.trackingChanged(.normal)
        XCTAssertFalse(gate.canPlace)
        XCTAssertFalse(gate.canDisplay)
        gate.receivedFrame(.normal, allExpectedAnchors: false)
        XCTAssertTrue(gate.needsRelocalization)
        XCTAssertFalse(gate.canDisplay)
        gate.receivedFrame(.normal, allExpectedAnchors: true)
        XCTAssertFalse(gate.needsRelocalization)
        XCTAssertTrue(gate.canDisplay)
        gate.pointsChanged()
        XCTAssertFalse(gate.canDisplay)
        gate.receivedFrame(.normal, allExpectedAnchors: true)
        XCTAssertTrue(gate.canDisplay)
    }

    func testResumeDoesNotClearTerminalFailure() {
        var gate = RouteTrackingGate(restoring: true)
        gate.fail()
        gate.pause()
        gate.resume()
        gate.trackingChanged(.matchingMap)
        gate.receivedFrame(.normal, allExpectedAnchors: true)
        XCTAssertTrue(gate.failed)
        XCTAssertFalse(gate.canDisplay)
        XCTAssertFalse(gate.canPlace)
    }

    func testWrongStoreAndLegacyUnboundEnvelopeRejectStoreHandoff() throws {
        let requested = "B02001HUD4"
        let mismatch = RouteLanguage.text("not linked to the selected store", "未关联所选店铺")
        for saved in [nil, "different-store", requested] as [String?] {
            // A synthetic envelope exercises the metadata gate only. No scan is fabricated.
            var values: [String: Any] = ["version": 1, "worldMap": Data()]
            if let saved { values["destinationID"] = saved }
            let data = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try data.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            XCTAssertEqual(try RouteArchive.hasDestination(requested, in: url), saved == requested)
            XCTAssertThrowsError(try RouteArchive.load(data, expectedDestinationID: requested)) { error in
                XCTAssertEqual(error.localizedDescription.contains(mismatch), saved != requested)
            }
            // An in-app launch accepts caller-selected maps without requiring a destination binding.
            XCTAssertThrowsError(try RouteArchive.load(data)) { error in
                XCTAssertFalse(error.localizedDescription.contains(mismatch))
            }
        }
    }

    func testFileSizeLimitAndShortFileReads() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data().write(to: file)
        XCTAssertThrowsError(try RouteArchive.data(at: file))
        let input = Data((0..<65537).map { UInt8($0 % 251) })
        try input.write(to: file)
        XCTAssertEqual(try RouteArchive.data(at: file), input)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 128 * 1024 * 1024 + 1)
        try handle.close()
        XCTAssertThrowsError(try RouteArchive.data(at: file))
    }

    @MainActor func testPracticeSessionWritesOnlyItsOwnArchive() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let regular = directory.appendingPathComponent(RouteArchive.url.lastPathComponent)
        let practice = directory.appendingPathComponent(RouteArchive.practiceURL.lastPathComponent)
        XCTAssertNotEqual(RouteArchive.practiceURL, RouteArchive.url)
        let regularBytes = Data("store route".utf8)
        let practiceBytes = Data("practice route".utf8)
        try RouteArchive.install(RouteArchive.stage(regularBytes, for: regular), to: regular)
        let session = RouteSession(archiveURL: practice)
        XCTAssertEqual(session.savedRouteURL, practice)
        XCTAssertFalse(session.state.hasSavedRoute)
        try RouteArchive.install(RouteArchive.stage(practiceBytes, for: practice), to: practice)
        session.stop()
        XCTAssertTrue(session.state.hasSavedRoute)
        XCTAssertEqual(try Data(contentsOf: regular), regularBytes)
        XCTAssertEqual(try Data(contentsOf: practice), practiceBytes)
    }

    func testRealARAnchorsSortByStoredIndexAndRejectMissingOrDuplicatePoints() throws {
        func point(_ index: Int, x: Float) -> ARAnchor {
            var transform = matrix_identity_float4x4
            transform.columns.3.x = x
            return ARAnchor(name: RouteArchive.name(index), transform: transform)
        }
        let entrance = point(0, x: 0)
        let corner = point(1, x: 1)
        let end = point(2, x: 3)
        let sorted = try RouteArchive.orderedPoints([end, entrance, corner])
        XCTAssertEqual(sorted.map(\.identifier), [entrance.identifier, corner.identifier, end.identifier])
        XCTAssertThrowsError(try RouteArchive.orderedPoints([entrance, end]))
        XCTAssertThrowsError(try RouteArchive.orderedPoints([entrance, entrance]))
        XCTAssertThrowsError(try RouteArchive.orderedPoints([entrance, point(0, x: 1)]))
        XCTAssertThrowsError(try RouteArchive.orderedPoints([entrance, point(1, x: 0)]))
    }
}
