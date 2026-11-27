import XCTest
@testable import RouteWalk

final class RouteCameraConfigurationTests: XCTestCase {
    private func format(_ width: Int, _ height: Int, _ fps: Int, hdr: Bool = true) -> RouteVideoFormatCapabilities {
        RouteVideoFormatCapabilities(width: width, height: height, framesPerSecond: fps, supportsHDR: hdr)
    }

    func testKeepsHDRDefaultEvenWhenOtherHDRFormatsExist() {
        XCTAssertNil(RouteVideoFormatSelection.hdrReplacementIndex(
            defaultFormat: format(1920, 1440, 60), supportedFormats: [format(3840, 2160, 30)]))
    }

    func testPreservesFrameRateAndAvoidsUnneededResolutionIncrease() {
        let candidates = [format(3840, 2160, 30), format(3840, 2160, 60), format(1280, 720, 60),
                          format(1920, 1080, 60), format(1920, 1440, 60, hdr: false)]
        XCTAssertEqual(RouteVideoFormatSelection.hdrReplacementIndex(
            defaultFormat: format(1920, 1440, 60, hdr: false), supportedFormats: candidates), 3)
    }

    func testFallsBackToSDRWhenHDRIsUnavailable() {
        let original = format(1920, 1440, 60, hdr: false)
        XCTAssertNil(RouteVideoFormatSelection.hdrReplacementIndex(defaultFormat: original, supportedFormats: [original]))
        XCTAssertNil(RouteVideoFormatSelection.hdrReplacementIndex(defaultFormat: original, supportedFormats: []))
    }

    func testChoosesClosestFrameRateAndPrefersLowerRateOnTie() {
        XCTAssertEqual(RouteVideoFormatSelection.hdrReplacementIndex(
            defaultFormat: format(1920, 1440, 60, hdr: false),
            supportedFormats: [format(1920, 1440, 90), format(1920, 1440, 30), format(1920, 1440, 24)]), 1)
    }

    func testUsesSupportedLargerFormatOnlyWhenNeededAndKeepsStableOrder() {
        XCTAssertEqual(RouteVideoFormatSelection.hdrReplacementIndex(
            defaultFormat: format(1280, 720, 60, hdr: false),
            supportedFormats: [format(3840, 2160, 60), format(1920, 1080, 60), format(1920, 1080, 60)]), 1)
    }
}
