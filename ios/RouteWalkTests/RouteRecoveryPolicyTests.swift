import ARKit
import XCTest
@testable import RouteWalk

final class RouteRecoveryPolicyTests: XCTestCase {
    private func error(_ code: ARError.Code) -> NSError {
        NSError(domain: ARError.errorDomain, code: code.rawValue)
    }

    func testOnlySensorAndTrackingFailuresAreEligible() {
        for code: ARError.Code in [.sensorUnavailable, .sensorFailed, .worldTrackingFailed] {
            XCTAssertTrue(RouteRecoveryPolicy.canRetry(error(code)), String(describing: code))
        }
        for code: ARError.Code in [.cameraUnauthorized, .unsupportedConfiguration, .invalidConfiguration,
                                   .invalidWorldMap, .insufficientFeatures] {
            XCTAssertFalse(RouteRecoveryPolicy.canRetry(error(code)), String(describing: code))
        }
        XCTAssertFalse(RouteRecoveryPolicy.canRetry(NSError(domain: "unrelated", code: ARError.Code.sensorFailed.rawValue)))
        XCTAssertFalse(RouteRecoveryPolicy.canRetry(NSError(domain: ARError.errorDomain, code: 99999)))
    }

    func testTwoAttemptsShareOneBudgetAcrossErrorTypes() {
        var policy = RouteRecoveryPolicy()
        XCTAssertEqual(policy.nextDelay(for: error(.sensorUnavailable)), 1)
        XCTAssertEqual(policy.nextDelay(for: error(.sensorUnavailable)), 1)
        XCTAssertEqual(policy.attempts, 0, "Queuing and canceling must not consume an attempt")
        policy.recordAttempt()
        XCTAssertEqual(policy.nextDelay(for: error(.sensorFailed)), 3)
        policy.recordAttempt()
        XCTAssertNil(policy.nextDelay(for: error(.sensorUnavailable)))
        XCTAssertNil(policy.nextDelay(for: error(.worldTrackingFailed)))
        XCTAssertEqual(policy.attempts, 2)
    }

    func testPermissionErrorDoesNotUseOrGrantRetryBudget() {
        let policy = RouteRecoveryPolicy()
        XCTAssertNil(policy.nextDelay(for: error(.cameraUnauthorized)))
        XCTAssertEqual(policy.attempts, 0)
        XCTAssertEqual(policy.nextDelay(for: error(.sensorFailed)), 1)
    }

    func testRetryIsNotSuccessUntilFreshNormalFrameContainsAllAnchors() {
        var failed = RouteTrackingGate(restoring: true)
        failed.fail()
        failed.receivedFrame(.normal, allExpectedAnchors: true)
        XCTAssertFalse(failed.canDisplay)

        var retry = RouteTrackingGate(restoring: true)
        retry.trackingChanged(.normal)
        XCTAssertFalse(retry.canPlace)
        retry.receivedFrame(.matchingMap, allExpectedAnchors: true)
        XCTAssertFalse(retry.canDisplay)
        retry.receivedFrame(.normal, allExpectedAnchors: false)
        XCTAssertFalse(retry.canPlace)
        XCTAssertFalse(retry.canDisplay)
        retry.receivedFrame(.normal, allExpectedAnchors: true)
        XCTAssertTrue(retry.canDisplay)
    }
}
