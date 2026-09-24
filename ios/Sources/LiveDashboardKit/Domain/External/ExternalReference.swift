import Foundation
import LiveIngestionCore

public enum LocalEntityKind: String, Codable, Hashable, Sendable {
    case event
    case stop
    case performance
    case venue
}

public struct LocalEntityRef: Codable, Hashable, Sendable {
    public let kind: LocalEntityKind
    public let id: String

    public init(kind: LocalEntityKind, id: String) {
        self.kind = kind
        self.id = id
    }
}

public enum ExternalRelationKind: String, Codable, Hashable, Sendable {
    case exactSession
    case groupedEvent
    case alias
    case candidate
    case rejected
}

public enum ExternalRecordAvailability: String, Codable, Hashable, Sendable {
    case present
    case sourceMissing
}

/// Binds a stable local id to an external id. Saving a reference never mints
/// or rewrites the local Live / Performance id.
public struct ExternalReference: Codable, Hashable, Identifiable, Sendable {
    public let local: LocalEntityRef
    public let external: ExternalIdentity
    public var relation: ExternalRelationKind
    public var availability: ExternalRecordAvailability
    public var provenance: SourceProvenance

    public init(
        local: LocalEntityRef,
        external: ExternalIdentity,
        relation: ExternalRelationKind,
        availability: ExternalRecordAvailability = .present,
        provenance: SourceProvenance
    ) {
        self.local = local
        self.external = external
        self.relation = relation
        self.availability = availability
        self.provenance = provenance
    }

    public var id: String { "\(local.kind.rawValue):\(local.id)|\(external.key)" }
}

public struct ExternalReferenceIndex: Equatable, Sendable {
    public let references: [ExternalReference]

    public init(references: [ExternalReference]) {
        self.references = references
    }

    /// One external id may point at several local performances. Rejected links
    /// stay stored, but they drop out of the open set.
    public func localIDs(for identity: ExternalIdentity, includeRejected: Bool = false) -> Set<String> {
        Set(references.compactMap { reference in
            guard reference.external == identity else { return nil }
            if reference.relation == .rejected && !includeRejected { return nil }
            return reference.local.id
        })
    }
}
