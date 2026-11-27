import Foundation

/// A local, user-exportable field observation. Uses the monotonic clock for durations.
struct FieldTrial {
    struct Event: Codable {
        let seconds: Double
        let state: String
    }

    private struct Report: Codable {
        let schema: Int
        let startedAt: Date
        let finishedAt: Date
        let routeFileModifiedAt: Date?
        let events: [Event]
        let observerVerdict: String
    }

    private let startedAt = Date()
    private let started = ProcessInfo.processInfo.systemUptime
    private let routeDate: Date?
    private(set) var events = [Event(seconds: 0, state: "searching")]
    private(set) var wasLocalized = false
    private var lastState = false

    init(routeURL: URL) {
        routeDate = try? routeURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    mutating func observe(localized: Bool) {
        guard localized != lastState else { return }
        lastState = localized
        wasLocalized = wasLocalized || localized
        events.append(Event(seconds: elapsed, state: localized ? "localized" : "tracking_lost"))
    }

    private var elapsed: Double { ProcessInfo.processInfo.systemUptime - started }

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WalkingTrials", isDirectory: true)
    }

    static var latest: URL? {
        let files = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                 includingPropertiesForKeys: nil)
        return files?.filter { $0.pathExtension == "json" }
            .max { $0.lastPathComponent < $1.lastPathComponent }
    }

    func finish(verdict: String) throws -> URL {
        let report = Report(schema: 1, startedAt: startedAt, finishedAt: Date(),
                            routeFileModifiedAt: routeDate,
                            events: events + [Event(seconds: elapsed, state: "finished")],
                            observerVerdict: verdict)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let name = String(Int64(startedAt.timeIntervalSince1970 * 1000)) + "-" + UUID().uuidString + ".json"
        let file = Self.directory.appendingPathComponent(name)
        try encoder.encode(report).write(to: file, options: .atomic)
        return file
    }
}
