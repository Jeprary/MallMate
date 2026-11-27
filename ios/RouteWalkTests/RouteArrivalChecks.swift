import XCTest
#if os(iOS)
import ARKit
#endif
@testable import RouteWalk

/// Synthetic coordinates verify the policy; these do not measure real-world AR accuracy.
final class RouteArrivalChecks: XCTestCase {
    private let camera: SIMD3<Float> = [0, 1.5, 0]

    private func complete(_ policy: inout RouteArrivalPolicy, camera: SIMD3<Float> = [0, 1.5, 0],
                          target: SIMD3<Float> = .zero, start: TimeInterval = 0) -> Bool {
        for step in 0...4 {
            policy.observe(camera: camera, target: target, timestamp: start + Double(step) * 0.5, aligned: true)
        }
        return policy.hasArrived
    }

    func testRequiresTwoSecondsOfContinuousAlignedFrames() {
        var policy = RouteArrivalPolicy()
        for time in [0.0, 0.5, 1, 1.5, 1.999] {
            XCTAssertFalse(policy.observe(camera: camera, target: .zero, timestamp: time, aligned: true))
        }
        XCTAssertTrue(policy.observe(camera: camera, target: .zero, timestamp: 2, aligned: true))
    }

    func testHorizontalRadiusAndHeightBoundariesIncludeEndpoints() {
        for height in [Float(0.4), 2.4] {
            var policy = RouteArrivalPolicy()
            XCTAssertTrue(complete(&policy, camera: [1.5, height, 0]))
        }
        for position: SIMD3<Float> in [[1.5001, 1.5, 0], [0, 0.3999, 0], [0, 2.4001, 0],
                                        [0, -1.5, 0], [0, 4.5, 0], [1.1, 1.5, 1.1]] {
            var policy = RouteArrivalPolicy()
            XCTAssertFalse(complete(&policy, camera: position))
        }
        var policy = RouteArrivalPolicy()
        XCTAssertTrue(complete(&policy, camera: [11.5, 6.5, -3], target: [10, 5, -3]))
    }

    func testLeavingRadiusOrHeightRestartsWholeDwell() {
        for position: SIMD3<Float> in [[2, 1.5, 0], [0, 3, 0]] {
            var policy = RouteArrivalPolicy()
            for time in [0.0, 0.5, 1, 1.5] {
                policy.observe(camera: camera, target: .zero, timestamp: time, aligned: true)
            }
            XCTAssertFalse(policy.observe(camera: position, target: .zero, timestamp: 1.75, aligned: true))
            XCTAssertFalse(policy.observe(camera: camera, target: .zero, timestamp: 2, aligned: true))
            XCTAssertFalse(policy.observe(camera: camera, target: .zero, timestamp: 2.5, aligned: true))
            XCTAssertTrue(complete(&policy, start: 3))
        }
    }

    func testMaximumGapBoundaryAndLongGapRestart() {
        var policy = RouteArrivalPolicy()
        for time in [0.0, 0.75, 1.5] {
            XCTAssertFalse(policy.observe(camera: camera, target: .zero, timestamp: time, aligned: true))
        }
        XCTAssertTrue(policy.observe(camera: camera, target: .zero, timestamp: 2, aligned: true))
        policy.reset()
        for time in [0.0, 0.5, 1, 1.5, 2.251, 2.75, 3.25, 3.75, 4.25] {
            XCTAssertFalse(policy.observe(camera: camera, target: .zero, timestamp: time, aligned: true))
        }
        XCTAssertTrue(policy.observe(camera: camera, target: .zero, timestamp: 4.251, aligned: true))
    }

    func testTrackingLossAndExplicitLifecycleInvalidationClearPendingImmediately() {
        // The session invokes invalidatePending on interruption, failure, background and new AR runs.
        for explicitInvalidation in [true, false] {
            var policy = RouteArrivalPolicy()
            for time in [0.0, 0.5, 1, 1.5] {
                policy.observe(camera: camera, target: .zero, timestamp: time, aligned: true)
            }
            if explicitInvalidation { policy.invalidatePending() }
            else { XCTAssertFalse(policy.observe(camera: camera, target: .zero, timestamp: 1.6, aligned: false)) }
            for time in [1.75, 2.25, 2.75, 3.25] {
                XCTAssertFalse(policy.observe(camera: camera, target: .zero, timestamp: time, aligned: true))
            }
            XCTAssertTrue(policy.observe(camera: camera, target: .zero, timestamp: 3.75, aligned: true))
        }
    }

    func testInvalidCoordinatesAndTimestampsClearPending() {
        for invalid in [Double.nan, .infinity, -.infinity, 1, 1.5] {
            var policy = RouteArrivalPolicy()
            for time in [0.0, 0.5, 1, 1.5] {
                policy.observe(camera: camera, target: .zero, timestamp: time, aligned: true)
            }
            XCTAssertFalse(policy.observe(camera: camera, target: .zero, timestamp: invalid, aligned: true))
            XCTAssertFalse(policy.observe(camera: camera, target: .zero, timestamp: 2, aligned: true))
        }
        for value in [Float.nan, .infinity, -.infinity] {
            for axis in 0..<3 {
                for invalidCamera in [true, false] {
                    var policy = RouteArrivalPolicy()
                    policy.observe(camera: camera, target: .zero, timestamp: 0, aligned: true)
                    var position = invalidCamera ? camera : .zero
                    position[axis] = value
                    XCTAssertFalse(policy.observe(camera: invalidCamera ? position : camera,
                        target: invalidCamera ? .zero : position, timestamp: 0.5, aligned: true))
                    XCTAssertFalse(policy.observe(camera: camera, target: .zero, timestamp: 1, aligned: true))
                }
            }
        }
    }

    func testArrivalRemainsTerminalUntilReset() {
        var policy = RouteArrivalPolicy()
        XCTAssertTrue(complete(&policy))
        policy.invalidatePending()
        XCTAssertTrue(policy.hasArrived)
        XCTAssertTrue(policy.observe(camera: [99, 99, 99], target: .zero, timestamp: .nan, aligned: false))
        policy.reset()
        XCTAssertFalse(policy.hasArrived)
        XCTAssertFalse(policy.observe(camera: camera, target: .zero, timestamp: 10, aligned: true))
    }

#if os(iOS)
    @MainActor func testOnlyGuidanceEnablesArrivalAndIdleStateStartsClear() {
        XCTAssertTrue(RouteSession.Mode.guiding.detectsArrival)
        for mode in [RouteSession.Mode.idle, .recording, .reviewing] { XCTAssertFalse(mode.detectsArrival) }
        let session = RouteSession()
        XCTAssertFalse(session.state.hasArrived)
        session.stop()
        XCTAssertFalse(session.state.hasArrived)
    }

    func testFinalNavigationPointFollowsReversedArchiveOrder() throws {
        let anchors = (0..<3).map { index -> ARAnchor in
            var transform = matrix_identity_float4x4
            transform.columns.3.x = Float(index) * 10
            return ARAnchor(name: RouteArchive.name(index), transform: transform)
        }
        for reversed in [false, true] {
            let ordered = try RouteArchive.orderedPoints(anchors, navigationReversed: reversed)
            let target = try XCTUnwrap(ordered.last).transform.columns.3
            XCTAssertEqual(target.x, reversed ? 0 : 20)
            var policy = RouteArrivalPolicy()
            XCTAssertTrue(complete(&policy, camera: [target.x, 1.5, 0], target: [target.x, 0, 0]))
        }
    }
#endif
}
