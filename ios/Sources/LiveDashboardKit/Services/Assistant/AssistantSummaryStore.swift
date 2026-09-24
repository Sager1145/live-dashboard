import Foundation
import LiveIngestionCore

/// On-disk store for `AssistantEventSummary` records, keyed by event ID.
/// Stored beside, never inside, the official catalog cache.
public actor AssistantSummaryStore {
    private let fileURL: URL
    private var cache: [String: AssistantEventSummary]?

    public init(directory: URL? = nil) {
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("LiveDashboard/Assistant", isDirectory: true)
        self.fileURL = root.appendingPathComponent("summaries.json")
    }

    public func all() throws -> [String: AssistantEventSummary] {
        try load()
    }

    public func summary(for eventID: String) throws -> AssistantEventSummary? {
        try load()[eventID]
    }

    public func save(_ summary: AssistantEventSummary) throws {
        var current = try load()
        current[summary.eventID] = summary
        try persist(current)
    }

    public func remove(eventID: String, ifGeneratedAt generation: Date? = nil) throws {
        var current = try load()
        if let generation, current[eventID]?.generatedAt != generation { return }
        current.removeValue(forKey: eventID)
        try persist(current)
    }

    public func removeAll() throws {
        try persist([:])
    }

    private func load() throws -> [String: AssistantEventSummary] {
        if let cache { return cache }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let empty: [String: AssistantEventSummary] = [:]
            cache = empty
            return empty
        }
        let data = try Data(contentsOf: fileURL)
        let decoded = try LiveEventBundle.decoder.decode([String: AssistantEventSummary].self, from: data)
        cache = decoded
        return decoded
    }

    private func persist(_ value: [String: AssistantEventSummary]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try LiveEventBundle.encoder.encode(value)
        try data.write(to: fileURL, options: .atomic)
        cache = value
    }
}
