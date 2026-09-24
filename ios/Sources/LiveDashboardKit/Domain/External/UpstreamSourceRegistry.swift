import Foundation
import LiveIngestionCore

public enum SourceLicense: String, Codable, Hashable, Sendable {
    /// The client implementation is MIT. Site text and images are not.
    case mitClientCodeOnly
    case unspecified
}

public enum SourceCapability: String, Codable, Hashable, Sendable {
    case eventDiscovery
    case venueFacts
    case performerIdentity
    case officialLinkDiscovery
    case historicalCatalog
    case tourStructure
    case setlist
    case attendanceBackupImport
    case ticketFacts
    case goodsFacts
    case accountSync
    case eventDescription
}

public struct UpstreamSourceRegistration: Equatable, Sendable {
    public let provider: ExternalProvider
    public let originProvider: ExternalProvider
    public let pinnedRevision: String
    public let license: SourceLicense
    public let allowed: Set<SourceCapability>

    public func allows(_ capability: SourceCapability) -> Bool {
        allowed.contains(capability)
    }
}

public enum UpstreamSourceRegistry {
    public static let eventernoteRevision = "ca823bca6596255864ecd511c981088a87d0a1b9"
    public static let llernoteRevision = "85791aced3e8dc7467622ad9a72072699dc98230"

    public static let eventernote = UpstreamSourceRegistration(
        provider: .eventernote,
        originProvider: .eventernote,
        pinnedRevision: eventernoteRevision,
        license: .mitClientCodeOnly,
        allowed: [.eventDiscovery, .venueFacts, .performerIdentity, .officialLinkDiscovery]
    )

    /// LLerNote redistributes a snapshot. Performance ids stay in the LLFans namespace.
    public static let llernote = UpstreamSourceRegistration(
        provider: .llernote,
        originProvider: .llfans,
        pinnedRevision: llernoteRevision,
        license: .unspecified,
        allowed: [.historicalCatalog, .tourStructure, .setlist, .attendanceBackupImport]
    )

    public static func registration(for provider: ExternalProvider) -> UpstreamSourceRegistration? {
        switch provider {
        case .eventernote: return eventernote
        case .llernote: return llernote
        case .official, .llfans, .wikidata, .osm, .user: return nil
        }
    }
}
