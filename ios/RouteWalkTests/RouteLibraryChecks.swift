import XCTest
import Synchronization
@testable import RouteWalk

final class RouteLibraryChecks: XCTestCase {
    private var temporary: URL!
    private var base: URL { temporary.appendingPathComponent("PracticeRoutes", isDirectory: true) }
    private var legacy: URL { temporary.appendingPathComponent("Practice.routewalk") }
    private var library: RouteLibrary { RouteLibrary(baseDirectory: base) }

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }

    func testSeparateMapsDraftsAndNamesSurviveRelaunchAndRename() throws {
        XCTAssertTrue(try library.entries().isEmpty)
        let first = try library.create(name: "  Hall / ../东门  ")
        let second = try library.create(name: "Hall / ../东门")
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.name, "Hall / ../东门")
        XCTAssertEqual(second.name, "Hall / ../东门 (2)")
        XCTAssertThrowsError(try library.rename(id: second.id, name: first.name))
        XCTAssertEqual(try library.rename(id: first.id, name: first.name), first)
        XCTAssertEqual(first.mapURL.deletingLastPathComponent(), base)
        XCTAssertEqual(first.mapURL.lastPathComponent, first.id.uuidString + ".routewalk")
        XCTAssertFalse(first.hasMap)
        XCTAssertFalse(second.hasMap)
        let firstMap = Data("first route".utf8), secondMap = Data("second route".utf8)
        try RouteArchive.install(RouteArchive.stage(firstMap, for: first.mapURL), to: first.mapURL)
        XCTAssertFalse(first.hasMap) // The original entry remains an immutable draft snapshot.
        XCTAssertTrue(try snapshot(first.id).hasMap)
        XCTAssertFalse(second.hasMap)
        try RouteArchive.install(RouteArchive.stage(secondMap, for: second.mapURL), to: second.mapURL)
        let renamed = try library.rename(id: first.id, name: "West stairs")
        XCTAssertEqual(renamed.mapURL, first.mapURL)
        XCTAssertEqual(try library.entries().map(\.name), [second.name, renamed.name])
        XCTAssertEqual(try Data(contentsOf: renamed.mapURL), firstMap)
        XCTAssertEqual(try Data(contentsOf: second.mapURL), secondMap)
    }

    func testDuplicateLongNamesFitAndPreserveTheOriginal() throws {
        let original = String(repeating: "门", count: RouteLibrary.nameLimit)
        let first = try library.create(name: original)
        let second = try library.create(name: original)
        let third = try library.create(name: original)
        XCTAssertEqual(first.name, original)
        XCTAssertEqual(second.name.count, RouteLibrary.nameLimit)
        XCTAssertTrue(second.name.hasSuffix(" (2)"))
        XCTAssertTrue(third.name.hasSuffix(" (3)"))
    }

    func testLegacyCopyIsIndependentAndRecoversAnUnindexedCopy() throws {
        let original = Data("existing practice file".utf8)
        let formal = temporary.appendingPathComponent(RouteArchive.url.lastPathComponent)
        try original.write(to: legacy)
        try Data("store map".utf8).write(to: formal)
        let entries = try library.entries()
        XCTAssertEqual(entries.count, 1)
        let migrated = try XCTUnwrap(entries.first)
        XCTAssertTrue(migrated.hasMap)
        XCTAssertNotEqual(migrated.mapURL, legacy)
        XCTAssertEqual(try Data(contentsOf: migrated.mapURL), original)
        XCTAssertEqual(try Data(contentsOf: legacy), original)
        // A later save and library reload must never re-copy the retained legacy file.
        let edited = Data("edited copy".utf8)
        try RouteArchive.install(RouteArchive.stage(edited, for: migrated.mapURL), to: migrated.mapURL)
        XCTAssertEqual(try library.entries(), [migrated])
        XCTAssertEqual(try Data(contentsOf: migrated.mapURL), edited)
        XCTAssertEqual(try Data(contentsOf: legacy), original)
        // Simulate the index not having been published after the map copy.
        try FileManager.default.removeItem(at: base.appendingPathComponent("routes.json"))
        XCTAssertEqual(try library.entries(), [migrated])
        XCTAssertEqual(try Data(contentsOf: migrated.mapURL), edited)
        XCTAssertEqual(try Data(contentsOf: formal), Data("store map".utf8))
    }

    func testInvalidNamesAndDamagedIndexCannotReplaceUserData() throws {
        for invalid in [" \n ", "a\nb", String(repeating: "x", count: RouteLibrary.nameLimit + 1)] {
            XCTAssertThrowsError(try library.create(name: invalid))
        }
        let item = try library.create(name: "Bedroom")
        let map = Data("saved map".utf8), broken = Data("invalid json".utf8)
        try map.write(to: item.mapURL)
        let json = base.appendingPathComponent("routes.json")
        try broken.write(to: json)
        XCTAssertThrowsError(try library.create(name: "Another"))
        XCTAssertThrowsError(try library.rename(id: item.id, name: "Other"))
        XCTAssertEqual(try Data(contentsOf: item.mapURL), map)
        XCTAssertEqual(try Data(contentsOf: json), broken)
    }

    func testInvalidImportLeavesListAndMapIntactAndInterruptedImportCanFinish() throws {
        let existing = try library.create(name: "Existing")
        let previous = Data("previous map".utf8)
        try previous.write(to: existing.mapURL)
        let savedExisting = try snapshot(existing.id)
        let invalid = temporary.appendingPathComponent("Bad.routewalk")
        try Data("not a route".utf8).write(to: invalid)
        XCTAssertThrowsError(try library.importRoute(from: invalid, name: "Bad"))
        XCTAssertEqual(try library.entries(), [savedExisting])
        XCTAssertEqual(try Data(contentsOf: existing.mapURL), previous)

        // Simulate a stop after a validated import wrote its map but before it wrote the index.
        let id = UUID()
        let receipt = base.appendingPathComponent("pending-import.json")
        let record = try JSONSerialization.data(withJSONObject: ["id": id.uuidString, "name": "Imported hall"])
        try record.write(to: receipt)
        XCTAssertEqual(try library.entries(), [savedExisting]) // No map was published yet.
        try record.write(to: receipt)
        let newMap = base.appendingPathComponent(id.uuidString).appendingPathExtension("routewalk")
        try Data("fully written map fixture".utf8).write(to: newMap)
        let recovered = try library.entries()
        XCTAssertEqual(recovered.map(\.name), ["Imported hall", "Existing"])
        XCTAssertEqual(recovered.first?.mapURL, newMap)
        XCTAssertEqual(try library.entries(), recovered)
        XCTAssertEqual(try Data(contentsOf: existing.mapURL), previous)
        XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.path))
    }

    func testConcurrentLibraryInstancesKeepEveryCreatedDraft() throws {
        let directory = base
        let errors = Mutex<[Error]>([])
        DispatchQueue.concurrentPerform(iterations: 8) { index in
            do { try RouteLibrary(baseDirectory: directory).create(name: "Walk \(index)") }
            catch { errors.withLock { $0.append(error) } }
        }
        XCTAssertTrue(errors.withLock { $0.isEmpty })
        let entries = try library.entries()
        XCTAssertEqual(Set(entries.map(\.id)).count, 8)
        XCTAssertTrue(entries.allSatisfy { !$0.hasMap })
    }

    func testMapSnapshotsChangeEqualityAndPersistSavedHistoryWhenFileAppears() throws {
        let draft = try library.create(name: "Hall")
        let before = try library.entries()
        XCTAssertFalse(draft.hasMap)
        XCTAssertFalse(draft.hasSavedMap)
        XCTAssertFalse(draft.isMapMissing)
        // These are file-inventory fixtures, not fabricated ARWorldMap captures.
        try Data("installed map fixture".utf8).write(to: draft.mapURL)
        let saved = try snapshot(draft.id)
        XCTAssertTrue(saved.hasMap)
        XCTAssertTrue(saved.hasSavedMap)
        XCTAssertNotEqual(before, try library.entries())
        XCTAssertFalse(draft.hasMap)

        try FileManager.default.removeItem(at: draft.mapURL)
        let missing = try snapshot(draft.id)
        XCTAssertFalse(missing.hasMap)
        XCTAssertTrue(missing.hasSavedMap)
        XCTAssertTrue(missing.isMapMissing)
        XCTAssertNotEqual([saved], [missing])
        XCTAssertEqual(try RouteLibrary(baseDirectory: base).entries(), [missing])
        try FileManager.default.createDirectory(at: draft.mapURL, withIntermediateDirectories: false)
        XCTAssertFalse(try snapshot(draft.id).hasMap)
        XCTAssertTrue(try snapshot(draft.id).isMapMissing)
    }

    func testOldIndexWithoutSavedFlagIsReconciledOnlyWhenItsMapExists() throws {
        let present = UUID(), absent = UUID()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let oldIndex: [String: Any] = ["version": 1, "routes": [
            ["id": present.uuidString, "name": "Present"], ["id": absent.uuidString, "name": "Absent"]
        ]]
        try JSONSerialization.data(withJSONObject: oldIndex).write(to: base.appendingPathComponent("routes.json"))
        let map = base.appendingPathComponent(present.uuidString).appendingPathExtension("routewalk")
        try Data("existing UUID map fixture".utf8).write(to: map)
        XCTAssertTrue(try snapshot(present).hasSavedMap)
        XCTAssertFalse(try snapshot(absent).hasSavedMap)
        try FileManager.default.removeItem(at: map)
        XCTAssertTrue(try snapshot(present).isMapMissing)
        XCTAssertFalse(try snapshot(absent).isMapMissing)
    }

    func testMarkSavedRequiresARegularMapAndNeverUsesADirectoryAsAMap() throws {
        let draft = try library.create(name: "Room")
        XCTAssertThrowsError(try library.markSaved(id: draft.id))
        XCTAssertFalse(try snapshot(draft.id).hasSavedMap)
        try FileManager.default.createDirectory(at: draft.mapURL, withIntermediateDirectories: false)
        XCTAssertThrowsError(try library.markSaved(id: draft.id))
        XCTAssertFalse(try snapshot(draft.id).hasMap)
        try FileManager.default.removeItem(at: draft.mapURL)
        try Data("map fixture".utf8).write(to: draft.mapURL)
        let saved = try library.markSaved(id: draft.id)
        XCTAssertTrue(saved.hasMap)
        XCTAssertTrue(saved.hasSavedMap)
        XCTAssertFalse(saved.isMapMissing)
    }

    func testDeleteUsesOnlyTheIndexedIDAndRetainsOtherMapsLegacyAndFrames() throws {
        let legacyData = Data("legacy original".utf8)
        try legacyData.write(to: legacy)
        let migrated = try XCTUnwrap(try library.entries().first)
        let target = try library.create(name: "Delete me")
        let other = try library.create(name: "Keep me")
        let original = Data("target map fixture".utf8), otherData = Data("other map fixture".utf8)
        try original.write(to: target.mapURL)
        try otherData.write(to: other.mapURL)
        let frames = temporary.appendingPathComponent("电脑建图素材", isDirectory: true)
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: false)
        let frame = frames.appendingPathComponent("image.jpg")
        try Data("retained frame".utf8).write(to: frame)
        let unrelated = temporary.appendingPathComponent("Unrelated.routewalk")
        try Data("outside map".utf8).write(to: unrelated)
        let forged = RouteLibrary.Entry(id: target.id, name: "Untrusted URL", mapURL: unrelated)

        try library.delete(id: forged.id)

        XCTAssertEqual(Set(try library.entries().map(\.id)), Set([other.id, migrated.id]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.mapURL.path))
        XCTAssertEqual(try Data(contentsOf: other.mapURL), otherData)
        XCTAssertEqual(try Data(contentsOf: legacy), legacyData)
        XCTAssertEqual(try Data(contentsOf: migrated.mapURL), legacyData)
        XCTAssertEqual(try Data(contentsOf: frame), Data("retained frame".utf8))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("outside map".utf8))
        let maps = try retainedTrashMaps()
        XCTAssertEqual(maps.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(maps.first)), original)
        let indexBytes = try Data(contentsOf: base.appendingPathComponent("routes.json"))
        XCTAssertThrowsError(try library.delete(id: UUID()))
        XCTAssertEqual(try Data(contentsOf: base.appendingPathComponent("routes.json")), indexBytes)
    }

    func testDeleteDraftAndLegacyDoesNotResurrectTheLegacyOriginal() throws {
        let original = Data("legacy source".utf8)
        try original.write(to: legacy)
        let migrated = try XCTUnwrap(try library.entries().first)
        let draft = try library.create(name: "Draft")
        try library.delete(id: draft.id)
        XCTAssertEqual(try library.entries().map(\.id), [migrated.id])
        try library.delete(id: migrated.id)
        XCTAssertTrue(try library.entries().isEmpty)
        XCTAssertTrue(try RouteLibrary(baseDirectory: base).entries().isEmpty)
        XCTAssertEqual(try Data(contentsOf: legacy), original)
        XCTAssertEqual(try retainedTrashMaps().count, 1)
    }

    func testFailedIndexPublicationRestoresTheMapAndKeepsTheOriginalRow() throws {
        let fail = Mutex(false)
        let store = RouteLibrary(baseDirectory: base, writeIndex: { data, url in
            if fail.withLock({ $0 }) { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        })
        let route = try store.create(name: "Retained")
        let map = Data("retained map fixture".utf8)
        try map.write(to: route.mapURL)
        let saved = try store.markSaved(id: route.id)
        let index = try Data(contentsOf: base.appendingPathComponent("routes.json"))
        fail.withLock { $0 = true }
        XCTAssertThrowsError(try store.delete(id: route.id))
        XCTAssertEqual(try Data(contentsOf: route.mapURL), map)
        XCTAssertEqual(try Data(contentsOf: base.appendingPathComponent("routes.json")), index)
        XCTAssertEqual(try library.entries(), [saved])
        XCTAssertTrue(try retainedTrashMaps().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("pending-delete.json").path))
    }

    func testCommittedDeletionIsSuccessfulEvenIfTheWriterThrowsAfterPublishing() throws {
        let throwAfterCommit = Mutex(false)
        let store = RouteLibrary(baseDirectory: base, writeIndex: { data, url in
            try data.write(to: url, options: .atomic)
            if throwAfterCommit.withLock({ $0 }) { throw CocoaError(.fileWriteUnknown) }
        })
        let draft = try store.create(name: "Committed")
        let original = Data("committed map fixture".utf8)
        try original.write(to: draft.mapURL)
        _ = try store.markSaved(id: draft.id)
        throwAfterCommit.withLock { $0 = true }

        XCTAssertNoThrow(try store.delete(id: draft.id))

        XCTAssertTrue(try library.entries().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: draft.mapURL.path))
        let retained = try XCTUnwrap(try retainedTrashMaps().first)
        XCTAssertEqual(try Data(contentsOf: retained), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("pending-delete.json").path))
    }

    func testInterruptedMoveBeforeCommitRestoresItsMapOnTheNextRead() throws {
        let draft = try library.create(name: "Interrupted")
        let map = Data("map before commit".utf8)
        try map.write(to: draft.mapURL)
        let saved = try library.markSaved(id: draft.id)
        let backup = try stagePendingDeletion(saved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: saved.mapURL.path))
        XCTAssertEqual(try library.entries(), [saved])
        XCTAssertEqual(try Data(contentsOf: saved.mapURL), map)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    func testInterruptedCommittedLegacyRemovalStaysRemovedAndKeepsItsBackup() throws {
        let original = Data("legacy after commit".utf8)
        try original.write(to: legacy)
        let saved = try XCTUnwrap(try library.entries().first)
        let backup = try stagePendingDeletion(saved)
        let committed: [String: Any] = ["version": 1, "routes": [], "deletedRouteIDs": [saved.id.uuidString]]
        try JSONSerialization.data(withJSONObject: committed).write(to: base.appendingPathComponent("routes.json"), options: .atomic)
        XCTAssertTrue(try library.entries().isEmpty)
        XCTAssertTrue(try RouteLibrary(baseDirectory: base).entries().isEmpty)
        XCTAssertEqual(try Data(contentsOf: backup), original)
        XCTAssertEqual(try Data(contentsOf: legacy), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("pending-delete.json").path))
    }

    func testNonregularMapPathCannotBeMovedOrDeletedAsARouteFile() throws {
        let draft = try library.create(name: "Unexpected directory")
        try FileManager.default.createDirectory(at: draft.mapURL, withIntermediateDirectories: false)
        let child = draft.mapURL.appendingPathComponent("keep.txt")
        let content = Data("keep this directory".utf8)
        try content.write(to: child)
        XCTAssertThrowsError(try library.delete(id: draft.id))
        XCTAssertEqual(try Data(contentsOf: child), content)
        XCTAssertEqual(try library.entries().map(\.id), [draft.id])
    }

    private func snapshot(_ id: UUID) throws -> RouteLibrary.Entry {
        try XCTUnwrap(try library.entries().first(where: { $0.id == id }))
    }

    private func retainedTrashMaps() throws -> [URL] {
        let trash = base.appendingPathComponent("Trash", isDirectory: true)
        guard FileManager.default.fileExists(atPath: trash.path) else { return [] }
        return try FileManager.default.subpathsOfDirectory(atPath: trash.path)
            .filter { $0.hasSuffix(".routewalk") }.map { trash.appendingPathComponent($0) }
    }

    /// Models the durable journal and map move before the process can publish its new index.
    private func stagePendingDeletion(_ entry: RouteLibrary.Entry) throws -> URL {
        let transactionID = UUID()
        let transaction = base.appendingPathComponent("Trash", isDirectory: true)
            .appendingPathComponent(transactionID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: transaction, withIntermediateDirectories: true)
        let receipt: [String: Any] = ["version": 1, "id": entry.id.uuidString, "name": entry.name,
                                    "transactionID": transactionID.uuidString, "hadMap": entry.hasMap]
        let bytes = try JSONSerialization.data(withJSONObject: receipt)
        try bytes.write(to: transaction.appendingPathComponent("entry.json"))
        try bytes.write(to: base.appendingPathComponent("pending-delete.json"), options: .atomic)
        let backup = transaction.appendingPathComponent(entry.id.uuidString).appendingPathExtension("routewalk")
        try FileManager.default.moveItem(at: entry.mapURL, to: backup)
        return backup
    }
}
