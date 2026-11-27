import XCTest
@testable import RouteWalk

@MainActor
final class RoutePresentationTests: XCTestCase {
    func testCameraRequiresMountBindingAndFreshFrame() async throws {
        let flow = RoutePresentationCoordinator()
        flow.presentCamera()
        let id = flow.cameraID
        flow.surfaceDidMount(id: UUID())
        flow.surfaceBindingFinished(id: id, ready: true)
        flow.cameraFrameChanged(true)
        XCTAssertEqual(flow.phase, .preparing)
        XCTAssertEqual(flow.homeOpacity, 1)
        flow.surfaceDidMount(id: id)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(flow.phase, .camera)
        flow.cameraFrameChanged(false)
        XCTAssertEqual(flow.phase, .camera, "Tracking recovery must not replay the page entrance.")
    }

    func testReturnStopsOnceAfterCoverAndRejectsOldCompletions() async throws {
        let flow = RoutePresentationCoordinator()
        flow.presentCamera()
        let oldID = flow.cameraID
        flow.surfaceDidMount(id: oldID)
        flow.surfaceBindingFinished(id: oldID, ready: true)
        flow.cameraFrameChanged(true)
        try await Task.sleep(for: .milliseconds(300))
        var stops = 0
        flow.returnToRoutes(stopWhenCovered: {
            XCTAssertEqual(flow.homeOpacity, 1)
            stops += 1
        })
        flow.sceneActivityChanged(false)
        flow.completePendingReturn()
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(flow.phase, .routes)
        flow.sceneActivityChanged(true)
        flow.presentCamera()
        let currentID = flow.cameraID
        XCTAssertNotEqual(oldID, currentID)
        flow.surfaceDidMount(id: oldID)
        flow.surfaceBindingFinished(id: oldID, ready: true)
        flow.cameraFrameChanged(true)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(flow.phase, .preparing)
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(flow.cameraID, currentID)
    }
}
