import RealityKit
import ARKit
import XCTest
@testable import RouteWalk

@MainActor
final class RouteDirectionChecks: XCTestCase {
    private func points(turn degrees: Float) -> [SIMD3<Float>] {
        let angle = degrees * .pi / 180
        return [[0, 0, 3], .zero, [3 * sin(angle), 0, -3 * cos(angle)]]
    }

    func testReversedArchiveOrderChangesEveryInstructionAndMovesDestinationToOriginalStart() throws {
        let route = points(turn: 90)
        let anchors = route.enumerated().map { index, point -> ARAnchor in
            var transform = matrix_identity_float4x4
            transform.columns.3 = [point.x, point.y, point.z, 1]
            return ARAnchor(name: RouteArchive.name(index), transform: transform)
        }
        let normal = try RouteArchive.orderedPoints([anchors[2], anchors[0], anchors[1]])
        let reversed = try RouteArchive.orderedPoints([anchors[2], anchors[0], anchors[1]], navigationReversed: true)
        XCTAssertEqual(reversed.map(\.identifier), normal.reversed().map(\.identifier))
        let reversedPositions = reversed.map { SIMD3<Float>($0.transform.columns.3.x, $0.transform.columns.3.y, $0.transform.columns.3.z) }
        let signs = RouteSignLayout.descriptors(points: reversedPositions, isGuidance: true, language: .english)
        XCTAssertEqual(signs.first?.groundPosition, route.last)
        XCTAssertEqual(signs[1].symbol, "left")
        XCTAssertEqual(signs.last?.symbol, "end")
        XCTAssertEqual(signs.last?.groundPosition, route.first)
        XCTAssertEqual(reversed.first?.name, RouteArchive.name(2))
        XCTAssertEqual(reversed.last?.name, RouteArchive.name(0))
        XCTAssertThrowsError(try RouteArchive.orderedPoints([anchors[0], anchors[0]], navigationReversed: true))
    }

    func testTurnBandsAreSymmetricAtRequestedBoundaries() throws {
        for (angle, positive, negative) in [(Float(39.19), "up", "up"), (44.99, "up", "up"),
                                          (45, "forward-right", "forward-left"), (60, "forward-right", "forward-left"),
                                          (69.99, "forward-right", "forward-left"), (70, "right", "left"),
                                          (90, "right", "left"), (149.99, "right", "left"), (150, "back", "back")] {
            for (sign, expected) in [(Float(1), positive), (-1, negative)] {
                let result = try XCTUnwrap(RouteSignLayout.descriptors(points: points(turn: angle * sign), isGuidance: true).dropFirst().first)
                XCTAssertEqual(result.symbol, expected, "\(angle * sign) degrees")
            }
        }
    }

    func testDiagonalTextUsesNextSegmentAndChangesLanguageWithoutMovingRoute() {
        let route = points(turn: 50) + [[-20, 0, -20]]
        let english = RouteSignLayout.descriptors(points: route, isGuidance: true, language: .english)
        let chinese = RouteSignLayout.descriptors(points: route, isGuidance: true, language: .chinese)
        XCTAssertEqual(english[1].title, "Bear right")
        XCTAssertEqual(chinese[1].title, "右前方")
        XCTAssertEqual(english[1].symbol, "forward-right")
        XCTAssertEqual(english.map(\.position), chinese.map(\.position))
        let movedDestination = points(turn: 50) + [[20, 0, 20]]
        XCTAssertEqual(english[1], RouteSignLayout.descriptors(points: movedDestination, isGuidance: true, language: .english)[1])
    }

    func testTurnAndUprightBoardAreIndependentOfWorldHeadingAndSideOffset() {
        for turn in [Float(-94), -50, -39.19, 0, 39.19, 50, 94] {
            for yaw in [Float(0), 37 * .pi / 180, -.pi / 2] {
                let rotation = simd_quatf(angle: yaw, axis: [0, 1, 0])
                let route = points(turn: turn).map { rotation.act($0) + [6, 0, 4] }
                for offset in [Float(-0.5), 0.5] {
                    let sign = RouteSignLayout.descriptors(points: route, isGuidance: true,
                        placement: .init(height: 1.1, sideOffset: offset))[1]
                    let original = RouteSignLayout.descriptors(points: points(turn: turn), isGuidance: true)[1]
                    XCTAssertEqual(sign.symbol, original.symbol)
                    let orientation = simd_quatf(angle: sign.yaw, axis: [0, 1, 0])
                    let incoming = simd_normalize(route[1] - route[0])
                    XCTAssertGreaterThan(simd_dot(orientation.act([0, 0, 1]), -incoming), 0.99999)
                    XCTAssertLessThan(simd_length(orientation.act([0, 1, 0]) - [0, 1, 0]), 0.0001)
                }
            }
        }
    }

    func testSavedCurveChangesInstructionWithoutChangingRoutePositions() {
        let route: [SIMD3<Float>] = [[-13.116, -1.410, -12.722], [-26.235, -1.450, -11.173],
                                    [-33.504, -1.477, -15.795], [-29.927, -1.568, -20.636]]
        let signs = RouteSignLayout.descriptors(points: route, isGuidance: true, language: .english)
        XCTAssertEqual(signs[1].symbol, "up")
        XCTAssertEqual(signs[2].symbol, "right")
        XCTAssertEqual(signs.map(\.groundPosition), route)
        XCTAssertEqual(signs.last?.symbol, "end")
    }

    func testDiagonalMeshesUpdateAndReuseWithoutTiltingOrMovingBoard() async throws {
        let renderer = RouteSignRenderer()
        renderer.update(points: points(turn: 50), isGuidance: true)
        let ready = await renderer.waitForResources()
        XCTAssertTrue(ready)
        let sign = try XCTUnwrap(renderer.root.findEntity(named: "sign-1"))
        let symbol = try XCTUnwrap(sign.findEntity(named: "symbol") as? ModelEntity)
        let firstMesh = try XCTUnwrap(symbol.model?.mesh)
        let position = sign.position
        let rotation = sign.orientation.vector
        renderer.update(points: points(turn: -50), isGuidance: true)
        let changed = await renderer.waitForResources()
        XCTAssertTrue(changed)
        XCTAssertFalse(symbol.model?.mesh === firstMesh)
        XCTAssertTrue(renderer.root.findEntity(named: "sign-1") === sign)
        XCTAssertEqual(sign.position, position)
        XCTAssertEqual(sign.orientation.vector, rotation)
        renderer.update(points: points(turn: 50), isGuidance: true)
        let restored = await renderer.waitForResources()
        XCTAssertTrue(restored)
        XCTAssertTrue(symbol.model?.mesh === firstMesh)
        XCTAssertEqual(symbol.orientation.vector, SIMD4<Float>(0, 0, 0, 1))
    }
}
