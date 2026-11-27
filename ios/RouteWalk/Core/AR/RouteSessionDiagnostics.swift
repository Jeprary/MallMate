import Foundation
import OSLog

/// Small, local diagnostic history; contains no images, map data, route names or error descriptions.
/// Project policy: current and previous run, at most 256 events / 256 KiB each. Repeated
/// tracking/coaching events are capped so a noisy session cannot enqueue per-frame file work.
@MainActor
final class RouteSessionDiagnostics {
    static let shared = RouteSessionDiagnostics()
    private var currentRun: UUID?
    private var count = 0
    private var eventCounts = [String: Int]()
    private let writer = Writer()

    func begin(_ runID: UUID, fields: [String: String]) {
        currentRun = runID
        count = 0
        eventCounts.removeAll()
        writer.begin(runID)
        record(runID, event: "begin", fields: fields)
    }

    func record(_ runID: UUID, event: String, fields: [String: String] = [:], error: NSError? = nil) {
        // Reserve the final slots for a terminal failure after noisy coaching/tracking changes.
        let critical = error != nil || event == "binding_failed"
        guard runID == currentRun, count < (critical ? 256 : 240) else { return }
        let limit = event == "tracking_changed" ? 64 : 16
        guard eventCounts[event, default: 0] < limit else { return }
        count += 1
        eventCounts[event, default: 0] += 1
        var values = fields
        var underlying = error
        // Preserve diagnostic codes, never arbitrary error descriptions/userInfo or user text.
        for depth in 0..<3 {
            guard let failure = underlying else { break }
            values["errorDomain\(depth)"] = failure.domain
            values["errorCode\(depth)"] = String(failure.code)
            underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        let bounded = Dictionary(uniqueKeysWithValues: values.sorted { $0.key < $1.key }.prefix(16).map {
            (String($0.key.prefix(64)), String($0.value.prefix(256)))
        })
        writer.append(Entry(runID: runID, uptime: ProcessInfo.processInfo.systemUptime,
                            event: String(event.prefix(64)), fields: bounded))
    }

    private struct Entry: Codable, Sendable {
        let runID: UUID
        let uptime: TimeInterval
        let event: String
        let fields: [String: String]
    }

    /// Mutable report state and all filesystem operations are confined to queue.
    private final class Writer: @unchecked Sendable {
        private let queue = DispatchQueue(label: "routewalk.session-diagnostics", qos: .utility)
        private let logger = Logger(subsystem: "com.mallmate.routewalk", category: "SessionDiagnostics")
        private var runID: UUID?
        private var entries = [Entry]()
        private let byteLimit = 256 * 1024

        private var directory: URL {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("RouteWalk", isDirectory: true)
                .appendingPathComponent("Diagnostics", isDirectory: true)
        }

        func begin(_ runID: UUID) {
            queue.async { [self] in
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let current = directory.appendingPathComponent("session-current.json")
                    if let size = try? current.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                       size <= byteLimit, let data = try? Data(contentsOf: current) {
                        try data.write(to: directory.appendingPathComponent("session-previous.json"), options: .atomic)
                    }
                    self.runID = runID
                    entries.removeAll(keepingCapacity: true)
                    try persist()
                } catch { logFailure(error) }
            }
        }

        func append(_ entry: Entry) {
            queue.async { [self] in
                guard entry.runID == runID else { return }
                entries.append(entry)
                if entries.count > 256 { entries.removeFirst(entries.count - 256) }
                do { try persist() } catch { logFailure(error) }
            }
        }

        private func persist() throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            var data = try encoder.encode(entries)
            while data.count > byteLimit, !entries.isEmpty {
                entries.removeFirst()
                data = try encoder.encode(entries)
            }
            try data.write(to: directory.appendingPathComponent("session-current.json"), options: .atomic)
        }

        private func logFailure(_ error: Error) {
            let failure = error as NSError
            logger.error("Diagnostic write failed: domain=\(failure.domain, privacy: .public), code=\(failure.code, privacy: .public)")
        }
    }
}

