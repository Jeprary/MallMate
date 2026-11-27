import Foundation

/// The index stores display names and UUIDs. Each AR map has its own stable file URL.
final class RouteLibrary {
    struct Entry: Identifiable, Equatable, Sendable {
        let id: UUID
        let name: String
        let mapURL: URL
        let hasMap: Bool
        let hasSavedMap: Bool
        var isMapMissing: Bool { hasSavedMap && !hasMap }

        init(id: UUID, name: String, mapURL: URL, hasMap: Bool? = nil, hasSavedMap: Bool? = nil) {
            self.id = id
            self.name = name
            self.mapURL = mapURL
            let exists = hasMap ?? RouteLibrary.isRegularMapFile(at: mapURL)
            self.hasMap = exists
            self.hasSavedMap = hasSavedMap == true || exists
        }
    }

    static let nameLimit = 60
    private static let lock = NSLock()
    // A fixed migration ID lets the next launch recover a copy made before index publication.
    private static let legacyID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))
    private struct Record: Codable {
        let id: UUID
        var name: String
        var saved: Bool? = nil
    }
    private struct Index: Codable {
        let version: Int
        var routes: [Record]
        // Optional for existing version-1 indexes. A deleted migration/import must not reappear.
        var deletedRouteIDs: [UUID]? = nil
    }
    private struct DeletionReceipt: Codable {
        let version: Int
        let id: UUID
        let name: String
        let transactionID: UUID
        let hadMap: Bool
        let saved: Bool?
    }

    private let directory: URL
    private let legacyURL: URL
    private let writeIndex: @Sendable (Data, URL) throws -> Void
    private var indexURL: URL { directory.appendingPathComponent("routes.json") }
    private var pendingImportURL: URL { directory.appendingPathComponent("pending-import.json") }
    private var pendingDeleteURL: URL { directory.appendingPathComponent("pending-delete.json") }
    private var trashURL: URL { directory.appendingPathComponent("Trash", isDirectory: true) }

    init(baseDirectory: URL = RouteArchive.url.deletingLastPathComponent()
        .appendingPathComponent("PracticeRoutes", isDirectory: true), legacyURL: URL? = nil,
         writeIndex: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) {
        directory = baseDirectory
        self.legacyURL = legacyURL ?? baseDirectory.deletingLastPathComponent().appendingPathComponent("Practice.routewalk")
        self.writeIndex = writeIndex
    }

    func entries() throws -> [Entry] {
        try Self.lock.withLock { try load().routes.map(entry) }
    }

    @discardableResult func create(name: String) throws -> Entry {
        let name = try checkedName(name)
        return try Self.lock.withLock {
            var index = try load()
            let record = Record(id: UUID(), name: uniqueName(name, in: index), saved: false)
            index.routes.insert(record, at: 0)
            try save(index)
            return entry(record)
        }
    }

    @discardableResult func rename(id: UUID, name: String) throws -> Entry {
        let name = try checkedName(name)
        return try Self.lock.withLock {
            var index = try load()
            guard let position = index.routes.firstIndex(where: { $0.id == id }) else {
                throw RouteProblem("This route could not be found.", "找不到这条路线。")
            }
            if name != index.routes[position].name,
               index.routes.contains(where: { $0.id != id && $0.name.lowercased() == name.lowercased() }) {
                throw RouteProblem("Name already used.", "名称已使用。")
            }
            index.routes[position].name = name
            try save(index)
            return entry(index.routes[position])
        }
    }

    /// Call after the route archive was installed successfully. Missing files never become drafts again.
    @discardableResult func markSaved(id: UUID) throws -> Entry {
        try Self.lock.withLock {
            var index = try load()
            guard let position = index.routes.firstIndex(where: { $0.id == id }) else {
                throw RouteProblem("This route could not be found.", "找不到这条路线。")
            }
            guard Self.isRegularMapFile(at: mapURL(for: id)) else {
                throw RouteProblem("The saved map file is unavailable. The route was kept.", "已保存的地图文件不可用，路线记录已保留。")
            }
            if index.routes[position].saved != true {
                index.routes[position].saved = true
                try save(index)
            }
            return entry(index.routes[position])
        }
    }

    /// Removes one indexed UUID. The original map stays in this library's recoverable Trash.
    /// Call off the main thread; the atomic index write is the deletion's commit point.
    func delete(id: UUID) throws {
        try Self.lock.withLock {
            var index = try load()
            guard let record = index.routes.first(where: { $0.id == id }) else {
                throw RouteProblem("This route could not be found.", "找不到这条路线。")
            }
            let files = FileManager.default
            let source = mapURL(for: id)
            let hadMap = files.fileExists(atPath: source.path)
            guard !hadMap || Self.isRegularMapFile(at: source) else {
                throw RouteProblem("The route path is not a regular map file. Its contents were kept.", "路线位置不是普通地图文件，已有内容已保留。")
            }
            let receipt = DeletionReceipt(version: 1, id: id, name: record.name,
                                           transactionID: UUID(), hadMap: hadMap, saved: record.saved)
            let transaction = try prepareTrash(receipt)
            let bytes = try JSONEncoder().encode(receipt)
            try bytes.write(to: transaction.appendingPathComponent("entry.json"), options: .atomic)
            try bytes.write(to: pendingDeleteURL, options: .atomic)
            do {
                if hadMap { try files.moveItem(at: source, to: trashedMap(for: receipt)) }
                index.routes.removeAll { $0.id == id }
                index.deletedRouteIDs = Array(Set((index.deletedRouteIDs ?? []) + [id]))
                    .sorted { $0.uuidString < $1.uuidString }
                try save(index)
            } catch {
                let failure = error
                // Read the durable index, rather than assuming a failed write never committed.
                var persisted = try readIndex()
                let committed = !persisted.routes.contains(where: { $0.id == id })
                    && (persisted.deletedRouteIDs ?? []).contains(id)
                try recoverPendingDeletion(in: &persisted)
                if committed { return }
                throw failure
            }
            // A leftover journal is safe: the next read recognizes the committed index.
            try? files.removeItem(at: pendingDeleteURL)
        }
    }

    /// Call off the main thread. Validate first, then publish the map before adding its row.
    @discardableResult func importRoute(from source: URL, name: String) throws -> Entry {
        let name = try checkedName(name)
        let bytes = try RouteArchive.data(at: source)
        _ = try RouteArchive.load(bytes)
        return try Self.lock.withLock {
            var index = try load()
            let record = Record(id: UUID(), name: uniqueName(name, in: index), saved: true)
            let result = entry(record)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // If the app stops between the map and index writes, the next read can finish this import.
            try JSONEncoder().encode(record).write(to: pendingImportURL, options: .atomic)
            try bytes.write(to: result.mapURL, options: .atomic)
            index.routes.insert(record, at: 0)
            try save(index)
            try? FileManager.default.removeItem(at: pendingImportURL)
            return entry(record)
        }
    }

    private func checkedName(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= Self.nameLimit,
              trimmed.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw RouteProblem("Enter a name of 1 to \(Self.nameLimit) characters on one line.",
                               "请填写 1 至 \(Self.nameLimit) 个字符的单行名称。")
        }
        return trimmed
    }

    private func uniqueName(_ name: String, in index: Index) -> String {
        let names = Set(index.routes.map { $0.name.lowercased() })
        var candidate = name
        var ordinal = 2
        while names.contains(candidate.lowercased()) {
            let suffix = " (\(ordinal))"
            let prefix = name.prefix(Self.nameLimit - suffix.count).trimmingCharacters(in: .whitespaces)
            candidate = prefix + suffix
            ordinal += 1
        }
        return candidate
    }

    private func entry(_ record: Record) -> Entry {
        let url = mapURL(for: record.id)
        let exists = Self.isRegularMapFile(at: url)
        return Entry(id: record.id, name: record.name, mapURL: url,
                     hasMap: exists, hasSavedMap: record.saved == true || exists)
    }

    private func mapURL(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("routewalk")
    }

    /// FileManager attributes are a fresh filesystem query; URL resource-value caches are not consulted.
    private static func isRegularMapFile(at url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
        return attributes[.type] as? FileAttributeType == FileAttributeType.typeRegular
    }

    private func readIndex() throws -> Index {
        let files = FileManager.default
        var index = Index(version: 1, routes: [])
        if files.fileExists(atPath: indexURL.path) {
            let data = try Data(contentsOf: indexURL)
            guard let stored = try? JSONDecoder().decode(Index.self, from: data), stored.version == 1,
                  Set(stored.routes.map(\.id)).count == stored.routes.count,
                  Set(stored.routes.map(\.id)).isDisjoint(with: stored.deletedRouteIDs ?? []) else {
                throw RouteProblem("The route list could not be read. Existing files were not changed.",
                                   "无法读取路线列表。已有文件未改动。")
            }
            index = stored
        }
        return index
    }

    private func load() throws -> Index {
        let files = FileManager.default
        var index = try readIndex()
        try recoverPendingDeletion(in: &index)

        if files.fileExists(atPath: pendingImportURL.path) {
            var pending = try JSONDecoder().decode(Record.self, from: Data(contentsOf: pendingImportURL))
            if entry(pending).hasMap, !index.routes.contains(where: { $0.id == pending.id }),
               !(index.deletedRouteIDs ?? []).contains(pending.id) {
                pending.saved = true
                index.routes.insert(pending, at: 0)
                try save(index)
            }
            try? files.removeItem(at: pendingImportURL)
        }
        var foundSavedMap = false
        for position in index.routes.indices where index.routes[position].saved != true {
            if Self.isRegularMapFile(at: mapURL(for: index.routes[position].id)) {
                index.routes[position].saved = true
                foundSavedMap = true
            }
        }
        if foundSavedMap { try save(index) }
        guard !(index.deletedRouteIDs ?? []).contains(Self.legacyID) else { return index }
        guard !index.routes.contains(where: { $0.id == Self.legacyID }) else { return index }
        let record = Record(id: Self.legacyID,
                            name: uniqueName(RouteLanguage.text("Test route", "测试路线"), in: index), saved: true)
        let destination = entry(record)
        guard destination.hasMap || files.fileExists(atPath: legacyURL.path) else { return index }
        if !destination.hasMap {
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            let temporary = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("tmp")
            defer { try? files.removeItem(at: temporary) }
            guard Self.isRegularMapFile(at: legacyURL) else {
                throw RouteProblem("The previous test map could not be read.", "无法读取原测试地图。")
            }
            try files.copyItem(at: legacyURL, to: temporary)
            try files.moveItem(at: temporary, to: destination.mapURL)
        }
        index.routes.append(record)
        try save(index)
        return index
    }

    private func save(_ index: Index) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeIndex(JSONEncoder().encode(index), indexURL)
    }

    private func prepareTrash(_ receipt: DeletionReceipt) throws -> URL {
        let files = FileManager.default
        if files.fileExists(atPath: trashURL.path) {
            let attributes = try files.attributesOfItem(atPath: trashURL.path)
            guard attributes[.type] as? FileAttributeType == FileAttributeType.typeDirectory else {
                throw RouteProblem("The local route recovery folder is unavailable.", "本机路线恢复目录暂不可用。")
            }
        } else {
            try files.createDirectory(at: trashURL, withIntermediateDirectories: true)
        }
        let transaction = trashURL.appendingPathComponent(receipt.transactionID.uuidString, isDirectory: true)
        if files.fileExists(atPath: transaction.path) {
            let attributes = try files.attributesOfItem(atPath: transaction.path)
            guard attributes[.type] as? FileAttributeType == FileAttributeType.typeDirectory else {
                throw RouteProblem("The route recovery record is invalid. Existing files were kept.", "路线恢复记录无效，已有文件已保留。")
            }
        } else {
            try files.createDirectory(at: transaction, withIntermediateDirectories: false)
        }
        return transaction
    }

    private func trashedMap(for receipt: DeletionReceipt) -> URL {
        trashURL.appendingPathComponent(receipt.transactionID.uuidString, isDirectory: true)
            .appendingPathComponent(receipt.id.uuidString).appendingPathExtension("routewalk")
    }

    private func recoverPendingDeletion(in index: inout Index) throws {
        let files = FileManager.default
        guard files.fileExists(atPath: pendingDeleteURL.path) else { return }
        guard let receipt = try? JSONDecoder().decode(DeletionReceipt.self, from: Data(contentsOf: pendingDeleteURL)),
              receipt.version == 1 else {
            throw RouteProblem("The route recovery record could not be read. Existing files were kept.", "无法读取路线恢复记录，已有文件已保留。")
        }
        _ = try prepareTrash(receipt)
        let source = mapURL(for: receipt.id)
        let backup = trashedMap(for: receipt)
        if index.routes.contains(where: { $0.id == receipt.id }) {
            // The index still owns the route: roll back a move interrupted before commit.
            if files.fileExists(atPath: backup.path) {
                guard Self.isRegularMapFile(at: backup), !files.fileExists(atPath: source.path) else {
                    throw RouteProblem("The route could not be restored automatically. Both locations were kept.", "路线无法自动恢复，两处已有内容均已保留。")
                }
                try files.moveItem(at: backup, to: source)
            } else if receipt.hadMap && !Self.isRegularMapFile(at: source) {
                throw RouteProblem("The route needs file recovery. Its index was kept.", "路线需要文件恢复，原索引已保留。")
            }
        } else if !(index.deletedRouteIDs ?? []).contains(receipt.id) {
            // A committed removal must also suppress legacy or pending-import resurrection.
            index.deletedRouteIDs = (index.deletedRouteIDs ?? []) + [receipt.id]
            try save(index)
        }
        try? files.removeItem(at: pendingDeleteURL)
    }
}
