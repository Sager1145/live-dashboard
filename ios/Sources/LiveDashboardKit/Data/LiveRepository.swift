import Foundation

public enum LiveRepositoryError: Error, LocalizedError, Sendable {
    case invalidBaseURL, invalidResponse
    case incompatibleSchema(Int)
    case unknownChangeKind(String)

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL: String(localized: "API 地址无效")
        case .invalidResponse: String(localized: "服务器响应无效")
        case .incompatibleSchema(let version): String(localized: "需要更新 App 才能读取资料版本 \(version)")
        case .unknownChangeKind(let kind): String(localized: "无法识别的目录变更类型：\(kind)")
        }
    }
}

public protocol LiveRepository: Sendable {
    func allBundles() async throws -> [LiveEventBundle]
    func bundle(eventID: String) async throws -> LiveEventBundle?
    func refresh() async throws -> [LiveEventBundle]
    func refresh(eventID: String) async throws -> LiveEventBundle?
    func refresh(eventID: String, cardType: CardType, entityID: String) async throws -> LiveEventBundle?
    func refreshIfNeeded() async throws -> [LiveEventBundle]
    func lastRefreshDate() async -> Date?
    func changes(eventID: String) async throws -> [EventChangeHistory]
    func clearPublicCache() async throws
    func consumeRemaps() async -> [CatalogRemap]
}

public extension LiveRepository {
    func consumeRemaps() async -> [CatalogRemap] { [] }
    func refresh(eventID: String) async throws -> LiveEventBundle? { try await refresh().first { $0.event.id == eventID } }
    func refreshIfNeeded() async throws -> [LiveEventBundle] { try await refresh() }
    func lastRefreshDate() async -> Date? { nil }
    func refresh(eventID: String, cardType: CardType, entityID: String) async throws -> LiveEventBundle? { throw CardRefreshError.unavailable }
}

public struct CatalogRemap: Hashable, Sendable { public let eventID: String; public let replacementID: String }

public struct BootstrapResponse: Codable, Sendable {
    public let schemaVersion: Int
    public let cursor: String
    public let events: [LiveEventBundle]
}

public struct CatalogChangesResponse: Codable, Sendable {
    public let cursor: String
    public let changes: [CatalogChange]
    public let hasMore: Bool
    public let sourceHealth: [String: SourceHealthState]

    public init(cursor: String, changes: [CatalogChange], hasMore: Bool = false, sourceHealth: [String: SourceHealthState] = [:]) { self.cursor = cursor; self.changes = changes; self.hasMore = hasMore; self.sourceHealth = sourceHealth }
    private enum CodingKeys: String, CodingKey { case cursor, changes, hasMore, sourceHealth }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cursor = try c.decode(String.self, forKey: .cursor)
        changes = try c.decode([CatalogChange].self, forKey: .changes)
        hasMore = try c.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
        sourceHealth = try c.decodeIfPresent([String: SourceHealthState].self, forKey: .sourceHealth) ?? [:]
    }
}

public struct CatalogChange: Codable, Sendable {
    public let sequence: String
    public let eventID: String
    public let revision: Int?
    public let kind: String
    public let bundle: LiveEventBundle?
    public let replacementID: String?

    public init(sequence: String, eventID: String, revision: Int?, kind: String, bundle: LiveEventBundle?, replacementID: String?) {
        self.sequence = sequence; self.eventID = eventID; self.revision = revision; self.kind = kind; self.bundle = bundle; self.replacementID = replacementID
    }
    private enum CodingKeys: String, CodingKey { case sequence, eventID, revision, kind, bundle, replacementID }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let string = try? c.decode(String.self, forKey: .sequence) { sequence = string }
        else { sequence = String(try c.decode(Int64.self, forKey: .sequence)) }
        guard !sequence.isEmpty, sequence.allSatisfy(\.isNumber) else { throw DecodingError.dataCorruptedError(forKey: .sequence, in: c, debugDescription: "sequence must be decimal digits") }
        eventID = try c.decode(String.self, forKey: .eventID)
        revision = try c.decodeIfPresent(Int.self, forKey: .revision)
        kind = try c.decode(String.self, forKey: .kind)
        bundle = try c.decodeIfPresent(LiveEventBundle.self, forKey: .bundle)
        replacementID = try c.decodeIfPresent(String.self, forKey: .replacementID)
    }
}

public actor APILiveRepository: LiveRepository {
    private struct CachedCatalog: Codable {
        var schemaVersion: Int
        var cursor: String
        var events: [LiveEventBundle]
    }

    private let session: URLSession
    private let baseURL: URL
    private let cacheDirectory: URL
    private let fileManager: FileManager
    private let decoder = LiveEventBundle.decoder
    private let encoder = LiveEventBundle.encoder
    private var memory: CachedCatalog?
    private var pendingRemaps: [CatalogRemap] = []

    public init(baseURL: URL, session: URLSession = .shared, fileManager: FileManager = .default, cacheDirectory: URL? = nil) {
        self.baseURL = baseURL
        self.session = session
        self.fileManager = fileManager
        let root = cacheDirectory ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.cacheDirectory = root.appendingPathComponent("LiveDashboard/PublicCatalog/\(Self.cacheNamespace(for: baseURL))", isDirectory: true)
    }

    public func allBundles() async throws -> [LiveEventBundle] {
        if let memory { return memory.events }
        if let cached = try? readCache() { memory = cached; return cached.events }
        return try await bootstrap().events
    }

    public func bundle(eventID: String) async throws -> LiveEventBundle? {
        if let local = try? await allBundles().first(where: { $0.event.id == eventID }) { return local }
        let remote: LiveEventBundle = try await get("v1/events/\(eventID)")
        try upsertAndPersist(remote)
        return remote
    }

    public func refresh() async throws -> [LiveEventBundle] {
        guard let catalog = memory ?? (try? readCache()), !catalog.cursor.isEmpty else { return try await bootstrap().events }
        do {
            var byID = Dictionary(uniqueKeysWithValues: catalog.events.map { ($0.event.id, $0) })
            var cursor = catalog.cursor
            var remaps: [CatalogRemap] = []
            var hasMore: Bool
            repeat {
                let delta: CatalogChangesResponse = try await get("v1/catalog/changes", query: ["cursor": cursor])
                for change in delta.changes {
                    switch change.kind {
                    case "upsert": if let bundle = change.bundle { byID[change.eventID] = bundle }
                    case "delete": byID.removeValue(forKey: change.eventID)
                    case "remap":
                        byID.removeValue(forKey: change.eventID)
                        if let replacementID = change.replacementID { remaps.append(.init(eventID: change.eventID, replacementID: replacementID)) }
                    default: throw LiveRepositoryError.unknownChangeKind(change.kind)
                    }
                }
                for (eventID, health) in delta.sourceHealth {
                    if let bundle = byID[eventID] { byID[eventID] = bundle.replacingSourceHealth(health) }
                }
                guard !delta.hasMore || delta.cursor != cursor else { throw LiveRepositoryError.invalidResponse }
                cursor = delta.cursor
                hasMore = delta.hasMore
            } while hasMore
            let updated = CachedCatalog(schemaVersion: catalog.schemaVersion, cursor: cursor, events: byID.values.sorted { $0.event.officialTitle < $1.event.officialTitle })
            try persist(updated); memory = updated; pendingRemaps.append(contentsOf: remaps)
            return updated.events
        } catch let error as HTTPError where error.statusCode == 410 {
            return try await bootstrap().events
        } catch LiveRepositoryError.unknownChangeKind {
            return try await bootstrap().events
        }
    }

    public func changes(eventID: String) async throws -> [EventChangeHistory] {
        struct Envelope: Codable { let changes: [EventChangeHistory] }
        if let envelope: Envelope = try? await get("v1/events/\(eventID)/changes") { return envelope.changes }
        return try await get("v1/events/\(eventID)/changes")
    }

    public func clearPublicCache() async throws {
        memory = nil
        if fileManager.fileExists(atPath: cacheDirectory.path) { try fileManager.removeItem(at: cacheDirectory) }
    }

    public func consumeRemaps() async -> [CatalogRemap] {
        defer { pendingRemaps.removeAll() }
        return pendingRemaps
    }

    private func bootstrap() async throws -> CachedCatalog {
        let response: BootstrapResponse = try await get("v1/catalog/bootstrap")
        guard response.schemaVersion <= 1 else { throw LiveRepositoryError.incompatibleSchema(response.schemaVersion) }
        let catalog = CachedCatalog(schemaVersion: response.schemaVersion, cursor: response.cursor, events: response.events)
        try persist(catalog); memory = catalog
        return catalog
    }

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        guard var parts = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false) else { throw LiveRepositoryError.invalidBaseURL }
        if !query.isEmpty { parts.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = parts.url else { throw LiveRepositoryError.invalidBaseURL }
        var request = URLRequest(url: url); request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LiveRepositoryError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw HTTPError(statusCode: http.statusCode) }
        return try decoder.decode(T.self, from: data)
    }

    private func readCache() throws -> CachedCatalog { try decoder.decode(CachedCatalog.self, from: Data(contentsOf: cacheURL)) }
    private func persist(_ catalog: CachedCatalog) throws {
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let temporary = cacheDirectory.appendingPathComponent("catalog-\(UUID().uuidString).tmp")
        try encoder.encode(catalog).write(to: temporary, options: .atomic)
        if fileManager.fileExists(atPath: cacheURL.path) { _ = try fileManager.replaceItemAt(cacheURL, withItemAt: temporary) }
        else { try fileManager.moveItem(at: temporary, to: cacheURL) }
    }
    private func upsertAndPersist(_ bundle: LiveEventBundle) throws {
        var catalog = memory ?? (try? readCache()) ?? CachedCatalog(schemaVersion: 1, cursor: "", events: [])
        catalog.events.removeAll { $0.event.id == bundle.event.id }; catalog.events.append(bundle)
        try persist(catalog); memory = catalog
    }
    private var cacheURL: URL { cacheDirectory.appendingPathComponent("catalog.json") }

    private static func cacheNamespace(for url: URL) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in url.absoluteString.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return String(hash, radix: 16)
    }
}

public struct HTTPError: Error, Sendable { public let statusCode: Int }
