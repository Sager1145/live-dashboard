import Foundation
import LiveIngestionCore

public enum ExternalProvider: String, Codable, Hashable, Sendable {
    case official
    case eventernote
    case llfans
    case llernote
    case wikidata
    case osm
    case user
}

public struct SourceHop: Codable, Hashable, Sendable {
    public let provider: ExternalProvider
    public let revision: String?
    public let locator: String?

    public init(provider: ExternalProvider, revision: String?, locator: String?) {
        self.provider = provider
        self.revision = revision
        self.locator = locator
    }
}

/// One observation and the chain that produced it. LLFans converted into a
/// LLerNote snapshot is a single chain: the two ends do not corroborate each other.
public struct SourceProvenance: Codable, Hashable, Sendable {
    public let provider: ExternalProvider
    public let originProvider: ExternalProvider
    public let upstreamRevision: String
    public let fetchedAt: Date
    public let sourceUpdatedAt: Date?
    public let lastVerifiedAt: Date?
    public let rawHash: String?
    public let locator: String
    public let derivedFrom: [SourceHop]

    public init(
        provider: ExternalProvider,
        originProvider: ExternalProvider,
        upstreamRevision: String,
        fetchedAt: Date,
        sourceUpdatedAt: Date? = nil,
        lastVerifiedAt: Date? = nil,
        rawHash: String? = nil,
        locator: String,
        derivedFrom: [SourceHop] = []
    ) {
        self.provider = provider
        self.originProvider = originProvider
        self.upstreamRevision = upstreamRevision
        self.fetchedAt = fetchedAt
        self.sourceUpdatedAt = sourceUpdatedAt
        self.lastVerifiedAt = lastVerifiedAt
        self.rawHash = rawHash
        self.locator = locator
        self.derivedFrom = derivedFrom
    }

    public func independentlyCorroborates(_ other: SourceProvenance) -> Bool {
        originProvider != other.originProvider
    }
}
