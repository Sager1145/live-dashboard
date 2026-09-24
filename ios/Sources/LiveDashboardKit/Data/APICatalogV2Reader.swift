import Foundation

/// Reads the activated v2 catalog and the published-event route. It does not decode schemaVersion 2 as `LiveEventBundle`.
public actor APICatalogV2Reader {
    private let client: CatalogAPIClient
    private let store: CatalogGenerationStore
    private let syncService: any CatalogSyncService

    public init(client: CatalogAPIClient, store: CatalogGenerationStore, sync: any CatalogSyncService) {
        self.client = client
        self.store = store
        self.syncService = sync
    }

    public func documents() async -> [CatalogEventDocumentV2] {
        await store.documents()
    }

    public func document(eventID: String) async -> CatalogEventDocumentV2? {
        await store.document(eventID: eventID)
    }

    public func sync(reason: SyncReason) async throws -> SyncResult {
        try await syncService.sync(reason: reason)
    }

    /// Detail GET. A newer revision is kept without committing a catalog cursor.
    public func publishedEvent(eventID: String) async throws -> CatalogEventDocumentV2 {
        let remote = try await client.publishedEvent(eventID: eventID)
        await store.keepNewerDetail(remote)
        return await store.document(eventID: eventID) ?? remote
    }
}
