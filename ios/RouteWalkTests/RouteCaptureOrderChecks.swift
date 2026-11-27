import ARKit
import RealityKit
import XCTest
@testable import RouteWalk

final class RouteCaptureOrderChecks: XCTestCase {
    private struct Header: Decodable {
        let worldMap: Data
        let navigationReversed: Bool?
    }

    private func captureAnchors() -> [ARAnchor] {
        let points: [SIMD3<Float>] = [[0, 0, 3], .zero, [3, 0, 0]]
        return points.enumerated().map { index, point in
            var transform = matrix_identity_float4x4
            transform.columns.3 = [point.x, point.y, point.z, 1]
            return ARAnchor(name: RouteArchive.name(index), transform: transform)
        }
    }

    private func positions(_ points: [ARAnchor]) -> [SIMD3<Float>] {
        points.map { SIMD3<Float>($0.transform.columns.3.x, $0.transform.columns.3.y, $0.transform.columns.3.z) }
    }

    func testNewCaptureEnvelopeExplicitlyStoresReverseNavigationAndRetainsMapBytes() throws {
        // Opaque bytes exercise the production envelope encoder only, not ARWorldMap decoding.
        let mapBytes = Data("opaque archived map".utf8)
        let data = try RouteArchive.encode(worldMapData: mapBytes, photo: nil, navigationReversed: true)
        let header = try PropertyListDecoder().decode(Header.self, from: data)
        XCTAssertEqual(header.navigationReversed, true)
        XCTAssertEqual(header.worldMap, mapBytes)
        let normal = try RouteArchive.encode(worldMapData: mapBytes, photo: nil)
        XCTAssertEqual(try PropertyListDecoder().decode(Header.self, from: normal).navigationReversed, false)
    }

    func testCaptureValidationPrecedesNavigationReversalAndPreservesNames() throws {
        let anchors = captureAnchors()
        let ids = anchors.map(\.identifier)
        let points = try RouteArchive.navigationPointsForCapture([anchors[2], anchors[0], anchors[1]], captureIDs: ids)
        XCTAssertEqual(points.map(\.identifier), Array(ids.reversed()))
        XCTAssertEqual(points.map(\.name), [RouteArchive.name(2), RouteArchive.name(1), RouteArchive.name(0)])
        XCTAssertEqual(anchors.map(\.identifier), ids)
        XCTAssertThrowsError(try RouteArchive.navigationPointsForCapture(anchors, captureIDs: Array(ids.reversed())))
        XCTAssertThrowsError(try RouteArchive.navigationPointsForCapture([anchors[0], anchors[2]], captureIDs: [ids[0], ids[2]]))
        XCTAssertThrowsError(try RouteArchive.navigationPointsForCapture([anchors[0], anchors[0]], captureIDs: [ids[0], ids[0]]))
    }

    func testImmediateNavigationAndRepeatedArchiveLoadsUseTheSameSingleReversal() throws {
        let anchors = captureAnchors()
        let immediate = try RouteArchive.navigationPointsForCapture(anchors, captureIDs: anchors.map(\.identifier))
        let data = try RouteArchive.encode(worldMapData: Data(), photo: nil, navigationReversed: true)
        let header = try PropertyListDecoder().decode(Header.self, from: data)
        let reopened = try RouteArchive.orderedPoints(anchors, navigationReversed: header.navigationReversed)
        // Loading sorts canonical capture names before applying the saved flag. Even an input
        // array already in navigation order cannot cause a second reversal.
        let reopenedAgain = try RouteArchive.orderedPoints(immediate, navigationReversed: header.navigationReversed)
        XCTAssertEqual(immediate.map(\.identifier), reopened.map(\.identifier))
        XCTAssertEqual(immediate.map(\.identifier), reopenedAgain.map(\.identifier))
        let signs = RouteSignLayout.descriptors(points: positions(immediate), isGuidance: true, language: .english)
        XCTAssertEqual(signs.first?.groundPosition, positions(anchors).last)
        XCTAssertEqual(signs.last?.groundPosition, positions(anchors).first)
        XCTAssertEqual(signs[1].symbol, "left")
        XCTAssertEqual(signs.last?.symbol, "end")
    }

    func testLegacyMissingOrFalseFlagRetainsForwardNavigation() throws {
        let anchors = captureAnchors()
        for flag in [nil, false, true] as [Bool?] {
            // Metadata fixtures establish the same optional-flag policy used by load().
            var envelope: [String: Any] = ["worldMap": Data()]
            if let flag { envelope["navigationReversed"] = flag }
            let data = try PropertyListSerialization.data(fromPropertyList: envelope, format: .binary, options: 0)
            let header = try PropertyListDecoder().decode(Header.self, from: data)
            let points = try RouteArchive.orderedPoints([anchors[1], anchors[2], anchors[0]],
                                                       navigationReversed: header.navigationReversed)
            let expected = flag == true ? Array(anchors.reversed()) : anchors
            XCTAssertEqual(points.map(\.identifier), expected.map(\.identifier))
        }
    }

    func testRecordingSignsPointInFutureNavigationDirectionWithoutChangingCaptureInput() {
        let capture: [SIMD3<Float>] = [[0, 0, 3], .zero, [3, 0, 0]]
        let editing = RouteSignLayout.descriptors(points: capture, isGuidance: false,
                                                  recordingFromDestination: true, language: .english)
        let saved = RouteSignLayout.descriptors(points: Array(capture.reversed()), isGuidance: true, language: .english)
        XCTAssertEqual(editing.map(\.groundPosition), Array(capture.reversed()))
        XCTAssertEqual(editing.map(\.position), saved.map(\.position))
        XCTAssertEqual(editing.map(\.yaw), saved.map(\.yaw))
        XCTAssertEqual(editing[1].symbol, "left")
        XCTAssertEqual(editing.last?.symbol, "point")
        XCTAssertEqual(editing.last?.title, "Destination")
        XCTAssertEqual(saved.last?.symbol, "end")
        XCTAssertEqual(capture.first, [0, 0, 3])
    }

    func testSingleCapturePointUsesDestinationDotAndDefaultLayoutRetainsStart() throws {
        for (language, title) in [(RouteLanguage.english, "Destination"), (.chinese, "终点")] {
            let point = try XCTUnwrap(RouteSignLayout.descriptors(points: [.zero], isGuidance: false,
                recordingFromDestination: true, language: language).first)
            XCTAssertEqual(point.symbol, "point")
            XCTAssertEqual(point.title, title)
        }
        let old = try XCTUnwrap(RouteSignLayout.descriptors(points: [.zero], isGuidance: false, language: .english).first)
        XCTAssertEqual(old.title, "Start")
        XCTAssertEqual(old.symbol, "point")
    }

    @MainActor func testRendererSwitchesFromCaptureDirectionToCommittedNavigationOrder() throws {
        let renderer = RouteSignRenderer()
        let capture = positions(captureAnchors())
        renderer.recordingFromDestination = true
        renderer.update(points: capture, isGuidance: false)
        let editing = RouteSignLayout.descriptors(points: capture, isGuidance: false,
                                                  recordingFromDestination: true)
        for descriptor in editing {
            XCTAssertEqual(renderer.root.findEntity(named: "sign-\(descriptor.index)")?.position, descriptor.position)
        }
        renderer.recordingFromDestination = false
        let navigation = Array(capture.reversed())
        renderer.update(points: navigation, isGuidance: true)
        let saved = RouteSignLayout.descriptors(points: navigation, isGuidance: true)
        for descriptor in saved {
            XCTAssertEqual(renderer.root.findEntity(named: "sign-\(descriptor.index)")?.position, descriptor.position)
        }
        renderer.update(points: navigation, isGuidance: true)
        XCTAssertEqual(renderer.root.findEntity(named: "sign-0")?.position, saved.first?.position)
    }
}
