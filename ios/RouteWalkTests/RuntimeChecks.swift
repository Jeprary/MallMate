import XCTest
import ARKit
import simd
@testable import RouteWalk

final class RuntimeChecks: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("routewalk")
    }

    @MainActor func testInvalidImportKeepsCurrentRoute() async throws {
        let url = RouteArchive.url
        let previous: Data
        let insertedFixture: Bool
        if FileManager.default.fileExists(atPath: url.path) {
            previous = try Data(contentsOf: url)
            insertedFixture = false
        } else {
            previous = Data("Preserve existing bytes in this isolated test".utf8)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try previous.write(to: url, options: .withoutOverwriting)
            insertedFixture = true
        }
        defer {
            if insertedFixture, (try? Data(contentsOf: url)) == previous {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let route = RouteSession()
        let previousState = route.state
        let malformed = tempURL()
        defer { try? FileManager.default.removeItem(at: malformed) }
        try Data("invalid route".utf8).write(to: malformed)
        let completed: Result<Void, Error> = await withCheckedContinuation { continuation in
            route.importRoute(from: malformed) { continuation.resume(returning: $0) }
        }
        XCTAssertThrowsError(try completed.get())
        XCTAssertEqual(previousState, route.state)
        XCTAssertEqual(previous, try Data(contentsOf: url))
    }

    @MainActor func testUnknownFormatAndMissingFileAreRejected() throws {
        let garbage = try PropertyListSerialization.data(fromPropertyList: [
            "version": 2, "worldMap": Data()
        ], format: .binary, options: 0)
        XCTAssertThrowsError(try RouteArchive.load(garbage))
        XCTAssertThrowsError(try RouteArchive.data(at: tempURL()))
    }

    func testSignsStandBesideIncomingPathAndFaceTheWalker() throws {
        let points = [SIMD3<Float>(0,0,1), SIMD3<Float>(0,0,-2), SIMD3<Float>(3,0,-2)]
        let approaches = [SIMD3<Float>(0,0,-1), SIMD3<Float>(0,0,-1), SIMD3<Float>(1,0,0)]
        for (offset, height) in [(Float(0.5),Float(1.1)),(-0.5,1.6)] {
            let signs = RouteSignLayout.descriptors(points: points, isGuidance: true,
                placement: RouteSignPlacement(height: height, sideOffset: offset))
            XCTAssertEqual(signs.count, points.count)
            for i in points.indices {
                let sign = signs[i]
                let expected = points[i] + simd_cross(approaches[i], SIMD3(0,1,0))*offset + SIMD3(0,height,0)
                XCTAssertLessThan(simd_length(sign.position - expected), 0.0001)
                let rotation = simd_quatf(angle: sign.yaw, axis: SIMD3(0,1,0))
                XCTAssertLessThan(simd_length(rotation.act(SIMD3(0,0,1)) + approaches[i]), 0.0001)
                XCTAssertEqual(sign.groundPosition, points[i])
            }
        }
        XCTAssertTrue(RouteSignLayout.descriptors(points: [], isGuidance: true).isEmpty)
        XCTAssertTrue(RouteSignLayout.descriptors(points: [.zero], isGuidance: true).isEmpty)
    }

    func testFieldReportRecordsTransitionsAndVerdict() throws {
        var trial = FieldTrial(routeURL: tempURL())
        trial.observe(localized: true)
        trial.observe(localized: true)
        trial.observe(localized: false)
        trial.observe(localized: true)
        let file = try trial.finish(verdict: "simulator_fixture")
        defer { try? FileManager.default.removeItem(at: file) }
        let data = try Data(contentsOf: file)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.compactMap {$0["state"] as? String},
                       ["searching","localized","tracking_lost","localized","finished"])
        XCTAssertEqual(json["observerVerdict"] as? String, "simulator_fixture")
    }

    func testEditingShowsTheStartImmediatelyAndFinalizesDestinationOnlyAfterSave() throws {
        let start = SIMD3<Float>(0, 0, -1)
        let single = RouteSignLayout.descriptors(points: [start], isGuidance: false, language: .english)
        XCTAssertEqual(single.count, 1)
        XCTAssertEqual(single.first?.title, "Start")
        XCTAssertEqual(single.first?.groundPosition, start)
        let points = [start, SIMD3<Float>(0, 0, -3), SIMD3<Float>(2, 0, -3)]
        let editing = RouteSignLayout.descriptors(points: points, isGuidance: false, language: .english)
        let saved = RouteSignLayout.descriptors(points: points, isGuidance: true, language: .english)
        XCTAssertFalse(editing.contains { $0.symbol == "end" })
        XCTAssertEqual(editing.last?.title, "Waypoint")
        XCTAssertEqual(saved.last?.symbol, "end")
        XCTAssertEqual(saved.last?.title, "Destination")
        XCTAssertEqual(editing.map(\.position), saved.map(\.position))
    }

    @MainActor func testMissingSavedMapDoesNotSilentlyStartScanning() {
        let model = RouteAppModel()
        let original = model.route
        let entry = RouteLibrary.Entry(id: UUID(), name: "Missing map",
            mapURL: tempURL(), hasMap: false, hasSavedMap: true)
        model.openRoute(entry)
        XCTAssertTrue(model.route === original)
        XCTAssertEqual(model.route.state.mode, .idle)
        XCTAssertFalse(model.presentation.cameraMounted)
        XCTAssertEqual(model.notice?.title, model.text("Map unavailable", "地图不可用"))
    }

    @MainActor func testRepeatedAddKeepsTheCurrentNamingRequest() {
        let model = RouteAppModel()
        model.beginNewRoute()
        let request = model.nameRequest?.id
        XCTAssertNotNil(request)
        model.beginNewRoute()
        XCTAssertEqual(model.nameRequest?.id, request)
    }

    @MainActor func testOpeningExistingDraftNeverAutomaticallyStartsCamera() {
        let model = RouteAppModel()
        let original = model.route
        let entry = RouteLibrary.Entry(id: UUID(), name: "Existing draft",
            mapURL: tempURL(), hasMap: false, hasSavedMap: false)
        model.openRoute(entry)
        XCTAssertTrue(model.route === original)
        XCTAssertEqual(model.route.state.mode, .idle)
        XCTAssertFalse(model.presentation.cameraMounted)
        XCTAssertEqual(model.prompt, .unscannedRoute)
        model.cancelPrompt()
        model.setSceneActive(false)
        model.setSceneActive(true)
        XCTAssertNil(model.prompt)
        XCTAssertTrue(model.route === original)
        XCTAssertFalse(model.requestingCamera)
        XCTAssertFalse(model.presentation.cameraMounted)
        model.openRoute(entry)
        XCTAssertEqual(model.prompt, .unscannedRoute)
    }

    @MainActor func testDraftOpenedFromModalWaitsForDismissAndCancelDoesNotQueueScan() {
        let model = RouteAppModel()
        let entry = RouteLibrary.Entry(id: UUID(), name: "Modal draft",
            mapURL: tempURL(), hasMap: false, hasSavedMap: false)
        model.libraryDidPresent()
        model.showsLibrary = true
        model.openRoute(entry)
        XCTAssertFalse(model.showsLibrary)
        XCTAssertNil(model.prompt)
        model.libraryDidDismiss()
        XCTAssertEqual(model.prompt, .unscannedRoute)
        model.cancelPrompt()
        model.libraryDidDismiss()
        XCTAssertNil(model.prompt)
        XCTAssertEqual(model.route.state.mode, .idle)
        XCTAssertFalse(model.presentation.cameraMounted)
    }
}
