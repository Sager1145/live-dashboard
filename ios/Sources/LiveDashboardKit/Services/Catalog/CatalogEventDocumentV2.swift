import Foundation
import LiveIngestionCore

/// Published v2 event document. This is not `LiveEventBundle`; schemaVersion 2 stays 2.
public struct CatalogEventDocumentV2: Sendable, Equatable {
    public let schemaVersion: Int
    public let revision: Int
    public let eventID: String
    public let officialTitle: String
    public let payload: Data

    public init(payload: Data) throws {
        let header = try LiveEventBundle.decoder.decode(SharedContractV2Header.self, from: payload)
        let identity = try JSONDecoder().decode(Identity.self, from: payload)
        guard header.schemaVersion == 2 else {
            throw CatalogSyncError.incompatibleSchema(header.schemaVersion)
        }
        schemaVersion = header.schemaVersion
        revision = header.revision
        eventID = identity.event.id
        officialTitle = identity.event.officialTitle
        self.payload = payload
    }

    private struct Identity: Decodable {
        struct Event: Decodable {
            let id: String
            let officialTitle: String
        }
        let event: Event
    }
}
