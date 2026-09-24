import Foundation
import LiveIngestionCore

struct StoredExtractionProposal: Codable, Sendable, Equatable {
    var proposal: DateClassificationProposal
    var osVersion: String
    var reportedContextSize: Int?

    init(proposal: DateClassificationProposal, osVersion: String, reportedContextSize: Int?) {
        self.proposal = proposal
        self.osVersion = osVersion
        self.reportedContextSize = reportedContextSize
    }
}

/// On-disk date-classification proposals, keyed by `ExtractionCacheKey`.
/// Stored beside, never inside, `summaries.json`.
actor ExtractionProposalStore {
    private let fileURL: URL
    private var cache: [String: StoredExtractionProposal]?

    init(directory: URL? = nil) {
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("LiveDashboard/Assistant", isDirectory: true)
        self.fileURL = root.appendingPathComponent("extraction-proposals.json")
    }

    func load() throws -> [String: StoredExtractionProposal] {
        if let cache { return cache }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let empty: [String: StoredExtractionProposal] = [:]
            cache = empty
            return empty
        }
        let data = try Data(contentsOf: fileURL)
        let decoded = try LiveEventBundle.decoder.decode([String: StoredExtractionProposal].self, from: data)
        cache = decoded
        return decoded
    }

    func proposal(forKey key: String) throws -> DateClassificationProposal? {
        try load()[key]?.proposal
    }

    func save(
        _ proposal: DateClassificationProposal,
        forKey key: String,
        reportedContextSize: Int? = nil
    ) throws {
        var current = try load()
        current[key] = StoredExtractionProposal(
            proposal: proposal,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            reportedContextSize: reportedContextSize
        )
        try persist(current)
    }

    func remove(forKey key: String) throws {
        var current = try load()
        current.removeValue(forKey: key)
        try persist(current)
    }

    func removeAll() throws {
        try persist([:])
    }

    private func persist(_ value: [String: StoredExtractionProposal]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try LiveEventBundle.encoder.encode(value)
        try data.write(to: fileURL, options: .atomic)
        cache = value
    }
}
