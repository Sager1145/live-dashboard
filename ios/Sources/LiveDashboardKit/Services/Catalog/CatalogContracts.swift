import Foundation
import LiveIngestionCore

public enum SyncReason: String, Sendable, Equatable {
    case foreground
    case pull
    case push
    case background
}

public struct SyncResult: Sendable, Equatable {
    public let cursor: String
    public let committed: Bool
    public let coalesced: Bool
    public let reason: SyncReason

    public init(cursor: String, committed: Bool, coalesced: Bool, reason: SyncReason) {
        self.cursor = cursor
        self.committed = committed
        self.coalesced = coalesced
        self.reason = reason
    }
}

public protocol CatalogReadRepository: Sendable {
    func allBundles() async throws -> [LiveEventBundle]
    func bundle(eventID: String) async throws -> LiveEventBundle?
}

public protocol CatalogSyncService: Sendable {
    func sync(reason: SyncReason) async throws -> SyncResult
}

public protocol RefreshJobService: Sendable {
    func requestRefresh(_ request: RefreshRequest) async throws -> RefreshJob
    func status(jobID: String) async throws -> RefreshJob
}

extension LocalLiveRepository: CatalogReadRepository {}

/// Decimal catalog cursor. Compare digit length, then lexicographic order. Never `Double`.
public enum DecimalCursor {
    public static func compare(_ lhs: String, _ rhs: String) -> Int {
        if lhs.count != rhs.count { return lhs.count < rhs.count ? -1 : 1 }
        if lhs == rhs { return 0 }
        return lhs < rhs ? -1 : 1
    }
}

public enum CatalogCursorCommit {
    public static func canCommit(savedEventIDs: Set<String>, windowEventIDs: [String]) -> Bool {
        windowEventIDs.allSatisfy { savedEventIDs.contains($0) }
    }
}

public struct RefreshRequest: Sendable, Equatable {
    public enum Target: Sendable, Equatable {
        case catalog
        case source(sourceID: String)
        case event(eventID: String)
        case eventSection(eventID: String, section: String)
        case card(eventID: String, cardID: String)
        case history(eventID: String)
    }

    public var target: Target
    public var fetchLatest: Bool
    public var reextract: Bool
    public var reason: String

    public init(target: Target, fetchLatest: Bool, reextract: Bool, reason: String) {
        self.target = target
        self.fetchLatest = fetchLatest
        self.reextract = reextract
        self.reason = reason
    }
}

public struct RefreshJob: Sendable, Equatable {
    public let jobID: String
    public let state: String
    public let deduplicated: Bool?
    public let statusPath: String?

    public init(jobID: String, state: String, deduplicated: Bool? = nil, statusPath: String? = nil) {
        self.jobID = jobID
        self.state = state
        self.deduplicated = deduplicated
        self.statusPath = statusPath
    }
}

public enum CatalogSyncError: Error, Equatable, Sendable {
    case incompatibleSchema(Int)
    case invalidResponse
    case invalidCursor(String)
    case snapshotMismatch(expected: String, actual: String)
    case unknownChangeKind(String)
    case instanceMismatch
    case notSaved
    case refreshUnavailable
}

struct LocalRepositorySyncService: CatalogSyncService {
    let repository: LocalLiveRepository

    func sync(reason: SyncReason) async throws -> SyncResult {
        _ = try await repository.refresh()
        return SyncResult(cursor: "", committed: true, coalesced: false, reason: reason)
    }
}

struct UnavailableRefreshJobService: RefreshJobService {
    func requestRefresh(_ request: RefreshRequest) async throws -> RefreshJob {
        throw CatalogSyncError.refreshUnavailable
    }

    func status(jobID: String) async throws -> RefreshJob {
        throw CatalogSyncError.refreshUnavailable
    }
}
