import XCTest
@testable import RouteWalk

@MainActor
final class RouteHandoffChecks: XCTestCase {
    private let returnPage = URL(string: "https://mallmate.example/stores/uniqlo?lang=zh#details")!

    private struct Preferences {
        private let values = [RouteLanguage.preferenceKey, "routewalk.testRouteID", "routewalk.lastLibrary"]
            .map { ($0, UserDefaults.standard.object(forKey: $0)) }
        func restore() {
            for (key, value) in values {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
    }

    private func fixture() throws -> RouteLibrary.Entry {
        let library = RouteLibrary()
        let entry = try library.create(name: "Handoff test " + UUID().uuidString)
        // File presence exercises selection only. These bytes are not an ARWorldMap;
        // no test below starts navigation or claims map decoding/relocalization coverage.
        try Data("Camera-off handoff fixture".utf8).write(to: entry.mapURL)
        return try library.markSaved(id: entry.id)
    }

    private func invocation(_ path: String, language: String = "zh", returning: String? = nil) throws -> URL {
        var parts = try XCTUnwrap(URLComponents(string: "mallmate-route://route/" + path))
        parts.queryItems = [URLQueryItem(name: "lang", value: language),
                            URLQueryItem(name: "return", value: returning ?? returnPage.absoluteString)]
        return try XCTUnwrap(parts.url)
    }

    private func waitUntilSettled(_ model: RouteAppModel) async throws {
        for _ in 0..<100 {
            if !model.busy { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Local route selection did not finish")
    }

    private func assertUnavailableVisitor(_ model: RouteAppModel, _ context: String = "",
                                          file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(model.visitorSessionActive, context, file: file, line: line)
        XCTAssertEqual(model.visitorCompletion, .unavailable, context, file: file, line: line)
        XCTAssertNil(model.handoffRoute, context, file: file, line: line)
        XCTAssertNil(model.prompt, context, file: file, line: line)
        XCTAssertNil(model.nameRequest, context, file: file, line: line)
        XCTAssertFalse(model.showsLibrary, context, file: file, line: line)
        XCTAssertFalse(model.presentation.cameraMounted, context, file: file, line: line)
        XCTAssertFalse(model.requestingCamera, context, file: file, line: line)
        XCTAssertTrue(model.isIdle, context, file: file, line: line)
    }

    func testWebLinkSelectsExactLocalUUIDWithoutStartingCamera() async throws {
        let preferences = Preferences()
        defer { preferences.restore() }
        let first = try fixture(), second = try fixture()
        let library = RouteLibrary()
        defer { try? library.delete(id: first.id); try? library.delete(id: second.id) }
        UserDefaults.standard.set(first.id.uuidString, forKey: "routewalk.testRouteID")
        let model = RouteAppModel()
        // Lowercase UUID remains the same exact identifier, irrespective of index order or saved selection.
        model.receive(try invocation(second.id.uuidString.lowercased()))
        try await waitUntilSettled(model)
        await model.restoreSelection()
        XCTAssertEqual(model.handoffRoute?.id, second.id)
        XCTAssertEqual(model.selectedPractice?.id, second.id)
        XCTAssertEqual(model.route.savedRouteURL, second.mapURL)
        XCTAssertEqual(model.visitorReturnURL, returnPage)
        XCTAssertTrue(model.visitorSessionActive)
        XCTAssertNil(model.visitorCompletion)
        XCTAssertEqual(model.resolvedLanguage, .chinese)
        XCTAssertTrue(model.isIdle)
        XCTAssertFalse(model.presentation.cameraMounted)
        XCTAssertFalse(model.requestingCamera)
        XCTAssertNil(model.prompt)
        XCTAssertEqual(try Data(contentsOf: second.mapURL), Data("Camera-off handoff fixture".utf8))
    }

    func testUnknownUUIDRemainsUnavailableVisitorInsteadOfRestoringSelectedRoute() async throws {
        let preferences = Preferences()
        defer { preferences.restore() }
        let fallback = try fixture()
        let library = RouteLibrary()
        defer { try? library.delete(id: fallback.id) }
        UserDefaults.standard.set(fallback.id.uuidString, forKey: "routewalk.testRouteID")
        let model = RouteAppModel()
        model.receive(try invocation(UUID().uuidString))
        try await waitUntilSettled(model)
        await model.restoreSelection()
        assertUnavailableVisitor(model)
        XCTAssertNil(model.selectedPractice)
        XCTAssertEqual(model.visitorReturnURL, returnPage)
        XCTAssertEqual(model.resolvedLanguage, .chinese)
    }

    func testMalformedRouteInvocationsStayInUnavailableVisitorView() async throws {
        let preferences = Preferences()
        defer { preferences.restore() }
        let id = UUID().uuidString
        let paths = [try invocation("not-a-uuid"), try invocation(id + "/extra"),
                     try invocation(id, language: "fr"),
                     try XCTUnwrap(URL(string: "mallmate-route://route/\(id)?lang=en")),
                     try XCTUnwrap(URL(string: "mallmate-route://route/\(id)?lang"))]
        for url in paths {
            let model = RouteAppModel()
            model.receive(url)
            try await waitUntilSettled(model)
            await model.restoreSelection()
            assertUnavailableVisitor(model, url.absoluteString)
            XCTAssertNil(model.selectedPractice, url.absoluteString)
        }
        for extra in [URLQueryItem(name: "lang", value: "en"),
                      URLQueryItem(name: "return", value: returnPage.absoluteString),
                      URLQueryItem(name: "download", value: "https://example.com/map")] {
            var parts = try XCTUnwrap(URLComponents(url: invocation(id), resolvingAgainstBaseURL: false))
            parts.queryItems?.append(extra)
            let model = RouteAppModel()
            model.receive(try XCTUnwrap(parts.url))
            try await waitUntilSettled(model)
            assertUnavailableVisitor(model, extra.name)
        }
        for host in ["route", "guide"] {
            let path = host == "route" ? id : RouteAppModel.destinationID
            for invalidPart in ["fragment", "port", "userinfo"] {
                var parts = try XCTUnwrap(URLComponents(url: invocation(id), resolvingAgainstBaseURL: false))
                parts.host = host; parts.path = "/" + path
                if invalidPart == "fragment" { parts.fragment = "unexpected" }
                if invalidPart == "port" { parts.port = 1234 }
                if invalidPart == "userinfo" { parts.user = "unexpected" }
                let model = RouteAppModel()
                model.receive(try XCTUnwrap(parts.url))
                try await waitUntilSettled(model)
                assertUnavailableVisitor(model, host + invalidPart)
            }
        }
    }

    func testUnsafeReturnNeverBecomesAnOpenURLRequestOrManagementFallback() async throws {
        let preferences = Preferences()
        defer { preferences.restore() }
        for target in ["mallmate-route://route/" + UUID().uuidString, "javascript:alert(1)",
                       "file:///tmp/route", "https://user:pass@example.com/store",
                       "https://mallmate.example/guide/B02001HUD4"] {
            let model = RouteAppModel()
            model.receive(try invocation(UUID().uuidString, returning: target))
            try await waitUntilSettled(model)
            assertUnavailableVisitor(model, target)
            XCTAssertNil(model.visitorReturnURL, target)
            model.returnVisitorToWeb()
            XCTAssertNil(model.webReturnRequest, target)
            XCTAssertFalse(model.returningToWeb, target)
            XCTAssertTrue(model.visitorSessionActive, target)
        }
    }

    func testDraftAndMissingSavedMapRemainUnavailableWithoutCapturePrompt() async throws {
        let preferences = Preferences()
        defer { preferences.restore() }
        let library = RouteLibrary()
        let draft = try library.create(name: "Handoff draft " + UUID().uuidString)
        let missing = try fixture()
        defer { try? library.delete(id: draft.id); try? library.delete(id: missing.id) }
        try FileManager.default.removeItem(at: missing.mapURL)
        for entry in [draft, missing] {
            let model = RouteAppModel()
            model.receive(try invocation(entry.id.uuidString))
            try await waitUntilSettled(model)
            assertUnavailableVisitor(model, entry.name)
            XCTAssertEqual(model.visitorReturnURL, returnPage)
            XCTAssertEqual(model.resolvedLanguage, .chinese)
        }
        let entries = try library.entries()
        XCTAssertFalse(try XCTUnwrap(entries.first { $0.id == draft.id }).hasSavedMap)
        XCTAssertTrue(try XCTUnwrap(entries.first { $0.id == missing.id }).isMapMissing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: draft.mapURL.path))
    }

    func testCloseRequestsWebReturnAndKeepsTerminalVisitorAfterAcceptedOpen() async throws {
        let preferences = Preferences()
        defer { preferences.restore() }
        let entry = try fixture()
        let library = RouteLibrary()
        defer { try? library.delete(id: entry.id) }
        let model = RouteAppModel()
        model.receive(try invocation(entry.id.uuidString))
        try await waitUntilSettled(model)
        model.dismissRouteHandoff()
        XCTAssertEqual(model.visitorCompletion, .ended)
        XCTAssertTrue(model.visitorSessionActive)
        XCTAssertTrue(model.returningToWeb)
        let request = try XCTUnwrap(model.webReturnRequest)
        XCTAssertEqual(model.visitorReturnURL, returnPage)
        model.returnVisitorToWeb()
        XCTAssertEqual(model.webReturnRequest, request, "An in-flight request is not duplicated")
        model.webReturnFinished(true, request: request)
        model.setSceneActive(false)
        model.setSceneActive(true)
        await model.restoreSelection()
        XCTAssertFalse(model.returningToWeb)
        XCTAssertFalse(model.webReturnFailed)
        XCTAssertEqual(model.visitorCompletion, .ended)
        XCTAssertTrue(model.visitorSessionActive)
        XCTAssertFalse(model.showsLibrary)
        XCTAssertFalse(model.presentation.cameraMounted)
    }

    func testRejectedOpenURLStaysTerminalAndRetryCreatesNewRequest() async throws {
        let preferences = Preferences()
        defer { preferences.restore() }
        let model = RouteAppModel()
        model.receive(try invocation(UUID().uuidString))
        try await waitUntilSettled(model)
        model.returnVisitorToWeb()
        let first = try XCTUnwrap(model.webReturnRequest)
        model.webReturnFinished(false, request: first)
        assertUnavailableVisitor(model)
        XCTAssertTrue(model.webReturnFailed)
        XCTAssertFalse(model.returningToWeb)
        model.returnVisitorToWeb()
        let retry = try XCTUnwrap(model.webReturnRequest)
        XCTAssertNotEqual(retry, first)
        XCTAssertTrue(model.returningToWeb)
        XCTAssertFalse(model.webReturnFailed)
        XCTAssertEqual(model.visitorReturnURL, returnPage)
        model.webReturnFinished(true, request: retry)
        assertUnavailableVisitor(model)
    }

    func testOldWebReturnCallbackCannotChangeNewVisitorOrItsReturnRequest() async throws {
        let preferences = Preferences()
        defer { preferences.restore() }
        let entry = try fixture()
        let library = RouteLibrary()
        defer { try? library.delete(id: entry.id) }
        let model = RouteAppModel()
        model.receive(try invocation(UUID().uuidString))
        try await waitUntilSettled(model)
        model.returnVisitorToWeb()
        let oldRequest = try XCTUnwrap(model.webReturnRequest)
        model.webReturnFinished(true, request: oldRequest)

        let nextReturn = "https://mallmate.example/stores/second?lang=en"
        model.receive(try invocation(entry.id.uuidString, language: "en", returning: nextReturn))
        try await waitUntilSettled(model)
        XCTAssertEqual(model.handoffRoute?.id, entry.id)
        XCTAssertNil(model.visitorCompletion)
        XCTAssertNil(model.webReturnRequest)
        // An old completion arriving after the next invocation cannot introduce a return error.
        model.webReturnFinished(false, request: oldRequest)
        XCTAssertFalse(model.webReturnFailed)
        XCTAssertNil(model.visitorCompletion)
        XCTAssertEqual(model.visitorReturnURL?.absoluteString, nextReturn)

        model.dismissRouteHandoff()
        let currentRequest = try XCTUnwrap(model.webReturnRequest)
        XCTAssertNotEqual(currentRequest, oldRequest)
        XCTAssertTrue(model.returningToWeb)
        // The stale callback also cannot finish a newer request that is now in flight.
        model.webReturnFinished(false, request: oldRequest)
        XCTAssertTrue(model.returningToWeb)
        XCTAssertFalse(model.webReturnFailed)
        XCTAssertEqual(model.webReturnRequest, currentRequest)
        XCTAssertEqual(model.visitorCompletion, .ended)
        XCTAssertEqual(model.visitorReturnURL?.absoluteString, nextReturn)
        model.webReturnFinished(true, request: currentRequest)
        XCTAssertFalse(model.returningToWeb)
        XCTAssertFalse(model.webReturnFailed)
        XCTAssertTrue(model.visitorSessionActive)
    }

    func testMalformedInvocationWithoutReturnClearsPreviousVisitorHandoff() async throws {
        let preferences = Preferences()
        defer { preferences.restore() }
        let entry = try fixture()
        let library = RouteLibrary()
        defer { try? library.delete(id: entry.id) }
        let model = RouteAppModel()
        model.receive(try invocation(entry.id.uuidString))
        try await waitUntilSettled(model)
        XCTAssertEqual(model.handoffRoute?.id, entry.id)
        XCTAssertEqual(model.visitorReturnURL, returnPage)

        model.receive(try XCTUnwrap(URL(string: "mallmate-route://route/not-a-uuid?lang=en")))
        try await waitUntilSettled(model)
        await model.restoreSelection()
        assertUnavailableVisitor(model)
        XCTAssertNil(model.visitorReturnURL)
        XCTAssertNil(model.webReturnRequest)
        XCTAssertFalse(model.returningToWeb)
        XCTAssertFalse(model.webReturnFailed)
        XCTAssertEqual(model.resolvedLanguage, .english)
        model.startHandoffNavigation()
        assertUnavailableVisitor(model)
        XCTAssertEqual(try Data(contentsOf: entry.mapURL), Data("Camera-off handoff fixture".utf8))
    }

    func testPendingDraftConfirmationCannotBeReplacedByValidOrMalformedHandoff() async throws {
        let preferences = Preferences()
        defer { preferences.restore() }
        let library = RouteLibrary()
        let draft = try library.create(name: "Pending handoff draft " + UUID().uuidString)
        let incoming = try fixture()
        defer { try? library.delete(id: draft.id); try? library.delete(id: incoming.id) }
        let model = RouteAppModel()
        model.openRoute(draft)
        let originalArchive = model.route.savedRouteURL
        let language = model.language
        for url in [try invocation(incoming.id.uuidString), try invocation("not-a-uuid")] {
            model.receive(url)
            try await waitUntilSettled(model)
            XCTAssertEqual(model.prompt, .unscannedRoute)
            XCTAssertEqual(model.route.savedRouteURL, originalArchive)
            XCTAssertEqual(model.language, language)
            XCTAssertNil(model.handoffRoute)
            XCTAssertFalse(model.visitorSessionActive)
            XCTAssertFalse(model.busy)
            XCTAssertTrue(model.isIdle)
            XCTAssertFalse(model.presentation.cameraMounted)
        }
        XCTAssertTrue(try library.entries().contains { $0.id == draft.id && !$0.hasMap })
        XCTAssertEqual(try Data(contentsOf: incoming.mapURL), Data("Camera-off handoff fixture".utf8))
    }
}
