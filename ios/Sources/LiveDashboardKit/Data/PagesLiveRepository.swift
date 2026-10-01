import Foundation
import LiveIngestionCore

/// Reads the published catalog. This repository never contacts official event websites.
public actor PagesLiveRepository: LiveRepository, CatalogReadRepository {
    public static let catalogURL = URL(string: "https://sager1145.github.io/live-dashboard/api/v1/catalog.json")!
    private struct Cache: Codable, Sendable {
        let snapshot: PagesCatalogSnapshot
        let downloadedAt: Date
    }
    private let session: URLSession
    private let directory: URL
    private let legacyCacheURL: URL?
    private let now: @Sendable () -> Date
    private var cache: Cache?
    private var inFlight: Task<[LiveEventBundle], Error>?

    public init(session: URLSession = .shared, directory: URL? = nil, legacyDirectory: URL? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.session = session
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("LiveDashboard/PagesCatalog", isDirectory: true)
        let legacyRoot = legacyDirectory ?? (directory == nil ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("LiveDashboard/OfficialCatalog", isDirectory: true) : nil)
        self.legacyCacheURL = legacyRoot?.appendingPathComponent("catalog.json")
        self.now = now
    }

    public func allBundles() async throws -> [LiveEventBundle] {
        if let saved = loadCache() { return saved.snapshot.events }
        return try await refresh()
    }

    public func bundle(eventID: String) async throws -> LiveEventBundle? {
        try await allBundles().first { $0.event.id == eventID }
    }

    public func refresh() async throws -> [LiveEventBundle] {
        if let inFlight { return try await inFlight.value }
        let task = Task { try await self.downloadAndSave() }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    public func refreshIfNeeded() async throws -> [LiveEventBundle] {
        if let inFlight { return try await inFlight.value }
        if let saved = loadCache(), now().timeIntervalSince(saved.downloadedAt) < 3_600 {
            return saved.snapshot.events
        }
        return try await refresh()
    }

    public func refresh(eventID: String) async throws -> LiveEventBundle? {
        try await refresh().first { $0.event.id == eventID }
    }

    public func refresh(eventID: String, cardType: CardType, entityID: String) async throws -> LiveEventBundle? {
        try await refresh(eventID: eventID)
    }

    public func lastRefreshDate() async -> Date? { loadCache()?.snapshot.lastSuccessfulRefreshAt }
    public func changes(eventID: String) async throws -> [EventChangeHistory] { [] }

    public func fetchHistory(start: String, end: String) async throws -> [LiveEventBundle] {
        try await refresh().filter { bundle in
            bundle.performances.contains { performance in
                guard let day = performance.localDate else { return false }
                return day <= end && (performance.localEndDate ?? day) >= start
            }
        }
    }

    public func clearPublicCache() async throws {
        // Finish any existing write before deleting so it cannot recreate the cleared cache.
        if let inFlight { _ = try? await inFlight.value }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: migrationMarker, options: .atomic)
        cache = nil
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            try FileManager.default.removeItem(at: cacheURL)
        }
    }

    private func downloadAndSave() async throws -> [LiveEventBundle] {
        do {
            var request = URLRequest(url: Self.catalogURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 30
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                throw LiveRepositoryError.invalidResponse
            }
            let snapshot = try LiveEventBundle.decoder.decode(PagesCatalogSnapshot.self, from: data)
            try Self.validate(snapshot)
            let updated = Cache(snapshot: snapshot, downloadedAt: now())
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try LiveEventBundle.encoder.encode(updated).write(to: cacheURL, options: .atomic)
            cache = updated
            return snapshot.events
        } catch let error as LiveRepositoryError {
            throw error
        } catch {
            // Decoder and networking diagnostics can include internal endpoint URLs.
            throw LiveRepositoryError.invalidResponse
        }
    }

    private func loadCache() -> Cache? {
        if let cache { return cache }
        if let data = try? Data(contentsOf: cacheURL),
           let saved = try? LiveEventBundle.decoder.decode(Cache.self, from: data),
           (try? Self.validate(saved.snapshot)) != nil {
            cache = saved
            return saved
        }
        // One-time import of the old public cache; personal SwiftData is independent.
        struct LegacyCatalog: Decodable { let events: [LiveEventBundle]; let lastRefresh: Date? }
        guard !FileManager.default.fileExists(atPath: migrationMarker.path),
              let legacyCacheURL, let data = try? Data(contentsOf: legacyCacheURL),
              let legacy = try? LiveEventBundle.decoder.decode(LegacyCatalog.self, from: data), !legacy.events.isEmpty else { return nil }
        let snapshot = PagesCatalogSnapshot(generatedAt: legacy.lastRefresh ?? .distantPast,
            lastSuccessfulRefreshAt: legacy.lastRefresh, sourceFailures: [], events: legacy.events)
        guard (try? Self.validate(snapshot)) != nil else { return nil }
        let migrated = Cache(snapshot: snapshot, downloadedAt: .distantPast)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try LiveEventBundle.encoder.encode(migrated).write(to: cacheURL, options: .atomic)
            try Data().write(to: migrationMarker, options: .atomic)
        } catch { return nil }
        cache = migrated
        return migrated
    }

    private static func validate(_ snapshot: PagesCatalogSnapshot) throws {
        guard snapshot.schemaVersion == 1 else { throw LiveRepositoryError.incompatibleSchema(snapshot.schemaVersion) }
        guard snapshot.refreshIntervalSeconds == 3_600, !snapshot.events.isEmpty,
              Set(snapshot.events.map { $0.event.id }).count == snapshot.events.count,
              snapshot.events.allSatisfy({ $0.schemaVersion == 1 && !$0.event.id.isEmpty }) else {
            throw LiveRepositoryError.invalidResponse
        }
    }

    private var migrationMarker: URL { directory.appendingPathComponent("migration-complete") }
    private var cacheURL: URL { directory.appendingPathComponent("catalog.json") }
}
