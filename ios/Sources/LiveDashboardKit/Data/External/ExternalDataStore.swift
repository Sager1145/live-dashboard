import Foundation
import LiveIngestionCore

public struct ExternalSnapshotFile: Codable, Hashable, Sendable {
    public let path: String
    public let sha256: String
    public let upstreamRevision: String

    public init(path: String, sha256: String, upstreamRevision: String) {
        self.path = path
        self.sha256 = sha256
        self.upstreamRevision = upstreamRevision
    }
}

public enum ExternalSnapshotState: String, Codable, Hashable, Sendable {
    case active
    case stale
}

public struct ExternalSnapshotRevision: Codable, Hashable, Identifiable, Sendable {
    public let provider: ExternalProvider
    public let upstreamRevision: String
    public let files: [ExternalSnapshotFile]
    public let recordCount: Int
    public var state: ExternalSnapshotState
    public var activatedAt: Date?
    public var lastRejectedAt: Date?

    public init(
        provider: ExternalProvider,
        upstreamRevision: String,
        files: [ExternalSnapshotFile],
        recordCount: Int,
        state: ExternalSnapshotState = .active,
        activatedAt: Date? = nil,
        lastRejectedAt: Date? = nil
    ) {
        self.provider = provider
        self.upstreamRevision = upstreamRevision
        self.files = files
        self.recordCount = recordCount
        self.state = state
        self.activatedAt = activatedAt
        self.lastRejectedAt = lastRejectedAt
    }

    public var id: String { "\(provider.rawValue):\(upstreamRevision)" }
}

public enum ExternalSnapshotAdmission: Equatable, Sendable {
    case activate
    case keepPrevious(SnapshotRejectReason)
}

public enum SnapshotRejectReason: String, Equatable, Sendable {
    case mixedFileRevisions
    case emptyRevision
    case abnormalShrink
}

public enum ExternalSnapshotCheck {
    /// Files in one admission must share a revision. A sharp drop keeps the
    /// previous snapshot instead of replacing it.
    public static func admit(
        _ proposed: ExternalSnapshotRevision,
        replacing active: ExternalSnapshotRevision?
    ) -> ExternalSnapshotAdmission {
        let revision = proposed.upstreamRevision.trimmingCharacters(in: .whitespacesAndNewlines)
        if revision.isEmpty || proposed.files.isEmpty || proposed.recordCount == 0 {
            return .keepPrevious(.emptyRevision)
        }
        if proposed.files.contains(where: { $0.upstreamRevision != proposed.upstreamRevision }) {
            return .keepPrevious(.mixedFileRevisions)
        }
        if let active, active.recordCount > 0, proposed.recordCount * 2 < active.recordCount {
            return .keepPrevious(.abnormalShrink)
        }
        return .activate
    }
}

public enum ExternalStoreError: Error, Equatable {
    case unsupportedSchema(Int)
    case officialCatalogDirectory
}

public actor ExternalDataStore {
    public nonisolated let fileURL: URL
    private var document: Document?

    public init(directory: URL? = nil) {
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("LiveDashboard/ExternalCatalog", isDirectory: true)
        self.fileURL = root.appendingPathComponent("catalog.json")
    }

    public func references() throws -> [ExternalReference] {
        try load().references
    }

    public func revision(for provider: ExternalProvider) throws -> ExternalSnapshotRevision? {
        try load().revisions.first { $0.provider == provider }
    }

    public func localIDs(for identity: ExternalIdentity, includeRejected: Bool = false) throws -> Set<String> {
        ExternalReferenceIndex(references: try load().references)
            .localIDs(for: identity, includeRejected: includeRejected)
    }

    /// Inserts or replaces the link for this local/external pair. The local id
    /// is stored as given.
    public func upsert(_ reference: ExternalReference) throws {
        var current = try load()
        if let index = current.references.firstIndex(where: { $0.id == reference.id }) {
            current.references[index] = reference
        } else {
            current.references.append(reference)
        }
        current.references.sort { $0.id < $1.id }
        try persist(current)
    }

    @discardableResult
    public func proposeSnapshot(_ proposed: ExternalSnapshotRevision, at date: Date = Date()) throws -> ExternalSnapshotAdmission {
        var current = try load()
        let active = current.revisions.first { $0.provider == proposed.provider }
        let admission = ExternalSnapshotCheck.admit(proposed, replacing: active)
        switch admission {
        case .activate:
            var stored = proposed
            stored.state = .active
            stored.activatedAt = date
            stored.lastRejectedAt = nil
            current.revisions.removeAll { $0.provider == proposed.provider }
            current.revisions.append(stored)
            current.revisions.sort { $0.id < $1.id }
            try persist(current)
        case .keepPrevious:
            guard let index = current.revisions.firstIndex(where: { $0.provider == proposed.provider }) else {
                return admission
            }
            current.revisions[index].state = .stale
            current.revisions[index].lastRejectedAt = date
            try persist(current)
        }
        return admission
    }

    /// The upstream row disappeared. The local link and any saved attendance
    /// stay; callers must not delete the official event from this signal.
    public func markSourceMissing(_ identity: ExternalIdentity) throws {
        var current = try load()
        var changed = false
        for index in current.references.indices where current.references[index].external == identity {
            if current.references[index].availability != .sourceMissing {
                current.references[index].availability = .sourceMissing
                changed = true
            }
        }
        if changed { try persist(current) }
    }

    public func communityCatalog() throws -> LLerNoteCatalog? { try load().catalog }

    /// Writes a catalog only when its snapshot is admitted. A rejected snapshot
    /// leaves the previous catalog and references in place and marks them stale.
    @discardableResult
    public func applyCommunityCatalog(_ catalog: LLerNoteCatalog, revision: ExternalSnapshotRevision, at date: Date = Date()) throws -> ExternalSnapshotAdmission {
        var current = try load()
        let active = current.revisions.first { $0.provider == revision.provider }
        let admission = ExternalSnapshotCheck.admit(revision, replacing: active)
        switch admission {
        case .activate:
            var stored = revision
            stored.state = .active
            stored.activatedAt = date
            stored.lastRejectedAt = nil
            current.revisions.removeAll { $0.provider == revision.provider }
            current.revisions.append(stored)
            current.revisions.sort { $0.id < $1.id }
            current.catalog = catalog
            try persist(current)
        case .keepPrevious:
            guard let index = current.revisions.firstIndex(where: { $0.provider == revision.provider }) else { return admission }
            current.revisions[index].state = .stale
            current.revisions[index].lastRejectedAt = date
            try persist(current)
        }
        return admission
    }

    private struct Document: Codable {
        static let currentSchema = 1
        var schemaVersion: Int = currentSchema
        var references: [ExternalReference] = []
        var revisions: [ExternalSnapshotRevision] = []
        var catalog: LLerNoteCatalog?

        private enum CodingKeys: String, CodingKey { case schemaVersion, references, revisions, catalog }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchema
            references = try container.decodeIfPresent([ExternalReference].self, forKey: .references) ?? []
            revisions = try container.decodeIfPresent([ExternalSnapshotRevision].self, forKey: .revisions) ?? []
            catalog = try container.decodeIfPresent(LLerNoteCatalog.self, forKey: .catalog)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(schemaVersion, forKey: .schemaVersion)
            try container.encode(references, forKey: .references)
            try container.encode(revisions, forKey: .revisions)
            try container.encodeIfPresent(catalog, forKey: .catalog)
        }
    }

    private func load() throws -> Document {
        if let document { return document }
        if fileURL.deletingLastPathComponent().lastPathComponent == "OfficialCatalog" {
            throw ExternalStoreError.officialCatalogDirectory
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let empty = Document()
            document = empty
            return empty
        }
        let decoded = try LiveEventBundle.decoder.decode(Document.self, from: Data(contentsOf: fileURL))
        guard decoded.schemaVersion <= Document.currentSchema else {
            throw ExternalStoreError.unsupportedSchema(decoded.schemaVersion)
        }
        document = decoded
        return decoded
    }

    private func persist(_ value: Document) throws {
        if fileURL.deletingLastPathComponent().lastPathComponent == "OfficialCatalog" {
            throw ExternalStoreError.officialCatalogDirectory
        }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try LiveEventBundle.encoder.encode(value).write(to: fileURL, options: .atomic)
        document = value
    }
}
