import ARKit
import XCTest
@testable import RouteWalk

final class RouteMapSavePolicyTests: XCTestCase {
    func testExtendingMapRemainsCapturableWhileTheLocalAreaGrows() {
        XCTAssertTrue(RouteMapSavePolicy.canCapture(.extending))
    }

    func testMappedStatusSupportsCapture() {
        XCTAssertTrue(RouteMapSavePolicy.canCapture(.mapped))
    }

    func testLimitedMappingRequiresMoreScanningBeforeCapture() {
        XCTAssertFalse(RouteMapSavePolicy.canCapture(.limited))
    }

    func testUnavailableMappingCannotBeCaptured() {
        XCTAssertFalse(RouteMapSavePolicy.canCapture(.notAvailable))
    }

    @MainActor func testSaveOutsideRecordingKeepsExistingArchiveAndSession() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("existing.routewalk")
        let original = Data("Retained archive fixture".utf8)
        try original.write(to: archive, options: .withoutOverwriting)
        let route = RouteSession(archiveURL: archive)
        let session = route.session
        let state = route.state

        let result: Result<URL, Error> = await withCheckedContinuation { continuation in
            route.saveRoute { continuation.resume(returning: $0) }
        }

        XCTAssertThrowsError(try result.get())
        XCTAssertTrue(route.session === session)
        XCTAssertEqual(route.state, state)
        XCTAssertEqual(try Data(contentsOf: archive), original)
    }
}
