import Foundation
import LiveIngestionCore

/// Namespaces are not interchangeable. The same digits from Eventernote and
/// LLFans identify different records.
public enum ExternalNamespace: String, Codable, Hashable, Sendable {
    case eventernote
    case llfans
    case official
}

public enum ExternalEntityKind: String, Codable, Hashable, Sendable {
    case event
    case performance
    case stop
    case venue
    case actor
}

public struct ExternalIdentity: Codable, Hashable, Sendable {
    public let namespace: ExternalNamespace
    public let entity: ExternalEntityKind
    public let rawID: String

    public init(namespace: ExternalNamespace, entity: ExternalEntityKind, rawID: String) {
        self.namespace = namespace
        self.entity = entity
        self.rawID = rawID
    }

    public var key: String { "\(namespace.rawValue):\(entity.rawValue):\(rawID)" }
}
