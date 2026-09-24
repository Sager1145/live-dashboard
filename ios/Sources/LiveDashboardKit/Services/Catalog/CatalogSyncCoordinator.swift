import Foundation

/// One in-flight catalog sync. Cursor advances only when the staging generation is activated.
public actor CatalogSyncCoordinator: CatalogSyncService {
    private let client: CatalogAPIClient
    private let store: CatalogGenerationStore
    private let serverInstanceID: String
    private let onEntered: @Sendable (SyncReason) -> Void
    private var flight: Task<SyncResult, Error>?

    public init(client: CatalogAPIClient, store: CatalogGenerationStore, serverInstanceID: String, onEntered: @escaping @Sendable (SyncReason) -> Void = { _ in }) {
        self.client = client
        self.store = store
        self.serverInstanceID = serverInstanceID
        self.onEntered = onEntered
    }

    public func sync(reason: SyncReason) async throws -> SyncResult {
        onEntered(reason)
        if reason.coalesces, let flight {
            let result = try await flight.value
            return SyncResult(cursor: result.cursor, committed: result.committed, coalesced: true, reason: reason)
        }
        let task = Task { try await self.perform(reason: reason) }
        if reason.coalesces { flight = task }
        do {
            let result = try await task.value
            if reason.coalesces { flight = nil }
            return result
        } catch {
            if reason.coalesces { flight = nil }
            throw error
        }
    }

    private func perform(reason: SyncReason) async throws -> SyncResult {
        let committed = await store.committedCursor()
        if let committed, !committed.isEmpty {
            do {
                return try await delta(from: committed, reason: reason)
            } catch let error as HTTPError where error.statusCode == 410 {
                // Public catalog only. UserDataStore is not part of this actor.
                return try await bootstrap(reason: reason)
            }
        }
        return try await bootstrap(reason: reason)
    }

    private func bootstrap(reason: SyncReason) async throws -> SyncResult {
        let previous = await store.committedCursor() ?? ""
        let generation = try await store.beginGeneration(copyActive: false)
        var token: String?
        var snapshotID: String?
        var cursor = previous
        var watermark: String?
        var window: [String] = []
        do {
            repeat {
                let page = try await client.bootstrapPage(pageToken: token)
                try await requireInstance(page.serverInstanceID)
                if let snapshotID, snapshotID != page.snapshotID {
                    throw CatalogSyncError.snapshotMismatch(expected: snapshotID, actual: page.snapshotID)
                }
                snapshotID = page.snapshotID
                if let watermark, DecimalCursor.compare(page.watermark, watermark) != 0 {
                    throw CatalogSyncError.invalidResponse
                }
                watermark = page.watermark
                if DecimalCursor.compare(page.cursor, page.watermark) > 0 { throw CatalogSyncError.invalidResponse }
                for event in page.events {
                    window.append(event.eventID)
                    try await store.write(generation: generation, document: event)
                }
                cursor = page.cursor
                token = page.nextPageToken
                if !page.hasMore { break }
                guard token != nil else { throw CatalogSyncError.invalidResponse }
            } while true
            guard let snapshotID else { throw CatalogSyncError.invalidResponse }
            guard await store.canCommit(generation: generation, windowEventIDs: window) else {
                await store.discard(generation: generation)
                return SyncResult(cursor: previous, committed: false, coalesced: false, reason: reason)
            }
            try await store.activate(generation: generation, cursor: cursor, snapshotID: snapshotID, sourceHealth: [:], remaps: [])
            return SyncResult(cursor: cursor, committed: true, coalesced: false, reason: reason)
        } catch let error as CatalogSyncError where error == .notSaved {
            await store.discard(generation: generation)
            return SyncResult(cursor: previous, committed: false, coalesced: false, reason: reason)
        } catch {
            await store.discard(generation: generation)
            throw error
        }
    }

    private func delta(from committed: String, reason: SyncReason) async throws -> SyncResult {
        let generation = try await store.beginGeneration(copyActive: true)
        var token: String?
        var cursor = committed
        var watermark: String?
        var window: [String] = []
        var health: [String: String] = [:]
        var remaps: [CatalogRemapRecord] = []
        do {
            repeat {
                let page = try await client.changesPage(cursor: committed, pageToken: token)
                try await requireInstance(page.serverInstanceID)
                if page.fromCursor != committed { throw CatalogSyncError.invalidResponse }
                if DecimalCursor.compare(page.cursor, committed) < 0 { throw CatalogSyncError.invalidCursor(page.cursor) }
                if let watermark, DecimalCursor.compare(page.watermark, watermark) != 0 { throw CatalogSyncError.invalidResponse }
                watermark = page.watermark
                if DecimalCursor.compare(page.cursor, page.watermark) > 0 { throw CatalogSyncError.invalidResponse }
                if page.changes.contains(where: { if case .unknown = $0.body { return true }; return false }) {
                    let kind = page.changes.compactMap { change -> String? in
                        if case .unknown(let kind) = change.body { return kind }
                        return nil
                    }.first ?? ""
                    throw CatalogSyncError.unknownChangeKind(kind)
                }
                for change in page.changes {
                    switch change.body {
                    case .upsert(let document):
                        window.append(document.eventID)
                        if let current = await store.stagedRevision(generation: generation, eventID: document.eventID), document.revision < current {
                            continue
                        }
                        try await store.write(generation: generation, document: document)
                    case .delete(let eventID, _):
                        window.append(eventID)
                        try await store.delete(generation: generation, eventID: eventID)
                        window.removeAll { $0 == eventID }
                    case .remap(let entityKind, let legacyID, let currentID):
                        remaps.append(CatalogRemapRecord(entityKind: entityKind, legacyID: legacyID, currentID: currentID))
                    case .unknown(let kind):
                        throw CatalogSyncError.unknownChangeKind(kind)
                    }
                }
                health.merge(page.sourceHealth) { _, new in new }
                guard DecimalCursor.compare(page.cursor, cursor) >= 0 else { throw CatalogSyncError.invalidCursor(page.cursor) }
                cursor = page.cursor
                token = page.nextPageToken
                if !page.hasMore { break }
                guard token != nil else { throw CatalogSyncError.invalidResponse }
            } while true
            guard await store.canCommit(generation: generation, windowEventIDs: window) else {
                await store.discard(generation: generation)
                return SyncResult(cursor: committed, committed: false, coalesced: false, reason: reason)
            }
            let snapshot = await store.activeSnapshotID() ?? "delta"
            try await store.activate(generation: generation, cursor: cursor, snapshotID: snapshot, sourceHealth: health, remaps: remaps)
            return SyncResult(cursor: cursor, committed: true, coalesced: false, reason: reason)
        } catch let error as CatalogSyncError where error == .notSaved {
            await store.discard(generation: generation)
            return SyncResult(cursor: committed, committed: false, coalesced: false, reason: reason)
        } catch {
            await store.discard(generation: generation)
            throw error
        }
    }

    private func requireInstance(_ instanceID: String) async throws {
        guard instanceID == serverInstanceID else { throw CatalogSyncError.instanceMismatch }
    }
}

private extension SyncReason {
    var coalesces: Bool { self == .foreground || self == .pull || self == .push }
}
