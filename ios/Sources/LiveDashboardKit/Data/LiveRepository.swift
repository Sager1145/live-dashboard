import Foundation
import LiveIngestionCore

public enum LiveRepositoryError: Error, LocalizedError, Sendable {
    case invalidBaseURL, invalidResponse
    case incompatibleSchema(Int)
    case unknownChangeKind(String)

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL: String(localized: "API 地址无效", bundle: .kit)
        case .invalidResponse: String(localized: "服务器响应无效", bundle: .kit)
        case .incompatibleSchema(let version): String(localized: "需要更新 App 才能读取资料版本 \(version)", bundle: .kit)
        case .unknownChangeKind(let kind): String(localized: "无法识别的目录变更类型：\(kind)", bundle: .kit)
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
    /// Fetches official events whose performances fall inside the inclusive yyyy-MM-dd
    /// range and stores them, including archived ones. Returns the bundles that were
    /// fetched for the range (not the whole catalog).
    func fetchHistory(start: String, end: String) async throws -> [LiveEventBundle]
}

public extension LiveRepository {
    func consumeRemaps() async -> [CatalogRemap] { [] }
    func refresh(eventID: String) async throws -> LiveEventBundle? { try await refresh().first { $0.event.id == eventID } }
    func refreshIfNeeded() async throws -> [LiveEventBundle] { try await refresh() }
    func lastRefreshDate() async -> Date? { nil }
    func refresh(eventID: String, cardType: CardType, entityID: String) async throws -> LiveEventBundle? { throw CardRefreshError.unavailable }
    func fetchHistory(start: String, end: String) async throws -> [LiveEventBundle] { throw HistoryFetchError.unavailable }
}

public enum HistoryFetchError: Error, LocalizedError, Sendable {
    case unavailable
    public var errorDescription: String? { String(localized: "此数据源不支持抓取过往公演", bundle: .kit) }
}

public struct CatalogRemap: Hashable, Codable, Sendable {
    public let eventID: String
    public let replacementID: String
    public init(eventID: String, replacementID: String) { self.eventID = eventID; self.replacementID = replacementID }
}

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

private final class SameHostRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        if let fromHost = task.originalRequest?.url?.host, let toHost = request.url?.host, fromHost.caseInsensitiveCompare(toHost) != .orderedSame {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

public actor APILiveRepository: LiveRepository {
    private struct CachedCatalog: Codable {
        var schemaVersion: Int
        var cursor: String
        var events: [LiveEventBundle]
        var pendingRemaps: [CatalogRemap]
        var etags: [String: String]

        init(schemaVersion: Int, cursor: String, events: [LiveEventBundle], pendingRemaps: [CatalogRemap] = [], etags: [String: String] = [:]) {
            self.schemaVersion = schemaVersion
            self.cursor = cursor
            self.events = events
            self.pendingRemaps = pendingRemaps
            self.etags = etags
        }

        private enum CodingKeys: String, CodingKey { case schemaVersion, cursor, events, pendingRemaps, etags }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
            cursor = try c.decode(String.self, forKey: .cursor)
            events = try c.decode([LiveEventBundle].self, forKey: .events)
            pendingRemaps = try c.decodeIfPresent([CatalogRemap].self, forKey: .pendingRemaps) ?? []
            etags = try c.decodeIfPresent([String: String].self, forKey: .etags) ?? [:]
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(schemaVersion, forKey: .schemaVersion)
            try c.encode(cursor, forKey: .cursor)
            try c.encode(events, forKey: .events)
            try c.encode(pendingRemaps, forKey: .pendingRemaps)
            try c.encode(etags, forKey: .etags)
        }
    }

    private let session: URLSession
    private let baseURL: URL
    private let bearerToken: String?
    private let cacheDirectory: URL
    private let fileManager: FileManager
    private let decoder = LiveEventBundle.decoder
    private let encoder = LiveEventBundle.encoder
    private var memory: CachedCatalog?

    public init(baseURL: URL, session: URLSession = .shared, fileManager: FileManager = .default, cacheDirectory: URL? = nil, serverInstanceID: String? = nil, bearerToken: String? = nil) {
        self.baseURL = baseURL
        self.bearerToken = bearerToken
        self.fileManager = fileManager
        if session === URLSession.shared {
            self.session = URLSession(configuration: .default, delegate: SameHostRedirectDelegate(), delegateQueue: nil)
        } else {
            self.session = session
        }
        let root = cacheDirectory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.cacheDirectory = root.appendingPathComponent("LiveDashboard/PublicCatalog/\(Self.cacheNamespace(for: baseURL, serverInstanceID: serverInstanceID))", isDirectory: true)
    }

    public func allBundles() async throws -> [LiveEventBundle] {
        if let memory { return memory.events }
        if let cached = try? readCache() { memory = cached; return cached.events }
        return try await bootstrap().events
    }

    public func bundle(eventID: String) async throws -> LiveEventBundle? {
        if let local = try? await allBundles().first(where: { $0.event.id == eventID }) { return local }
        let remote: LiveEventBundle = try await get("v1/events/\(eventID)")
        return try upsertAndPersist(remote)
    }

    public func refresh() async throws -> [LiveEventBundle] {
        guard let catalog = memory ?? (try? readCache()), !catalog.cursor.isEmpty else { return try await bootstrap().events }
        var stagedRemaps = catalog.pendingRemaps
        do {
            var byID = Dictionary(uniqueKeysWithValues: catalog.events.map { ($0.event.id, $0) })
            var cursor = catalog.cursor
            var etags = catalog.etags
            var hasMore: Bool
            repeat {
                let delta: CatalogChangesResponse = try await get("v1/catalog/changes", query: ["cursor": cursor])
                for change in delta.changes {
                    switch change.kind {
                    case "upsert":
                        if let bundle = change.bundle { byID[change.eventID] = Self.preferredBundle(stored: byID[change.eventID], incoming: bundle) }
                    case "delete":
                        byID.removeValue(forKey: change.eventID)
                        etags.removeValue(forKey: change.eventID)
                    case "remap":
                        byID.removeValue(forKey: change.eventID)
                        etags.removeValue(forKey: change.eventID)
                        if let replacementID = change.replacementID { stagedRemaps.append(CatalogRemap(eventID: change.eventID, replacementID: replacementID)) }
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
            let updated = CachedCatalog(schemaVersion: catalog.schemaVersion, cursor: cursor, events: byID.values.sorted { $0.event.officialTitle < $1.event.officialTitle }, pendingRemaps: stagedRemaps, etags: etags)
            try persist(updated); memory = updated
            return updated.events
        } catch let error as HTTPError where error.statusCode == 410 {
            var current = memory ?? (try? readCache()) ?? catalog
            current.pendingRemaps = stagedRemaps
            memory = current
            if (try? persist(current)) != nil { memory = current }
            return try await bootstrap().events
        }
    }

    public func refresh(eventID: String) async throws -> LiveEventBundle? {
        let catalog = memory ?? (try? readCache())
        var headers: [String: String] = [:]
        if let etag = catalog?.etags[eventID] { headers["If-None-Match"] = etag }
        let (data, http) = try await perform("v1/events/\(eventID)", headers: headers)
        if http.statusCode == 304 { return catalog?.events.first { $0.event.id == eventID } }
        guard (200..<300).contains(http.statusCode) else { throw HTTPError(statusCode: http.statusCode) }
        let bundle = try decoder.decode(LiveEventBundle.self, from: data)
        return try upsertAndPersist(bundle, etag: http.value(forHTTPHeaderField: "ETag"))
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
        guard var catalog = memory ?? (try? readCache()) else { return [] }
        let remaps = catalog.pendingRemaps
        guard !remaps.isEmpty else { return [] }
        catalog.pendingRemaps = []
        do { try persist(catalog); memory = catalog } catch { return remaps }
        return remaps
    }

    private func bootstrap() async throws -> CachedCatalog {
        let response: BootstrapResponse = try await get("v1/catalog/bootstrap")
        guard response.schemaVersion == 1 else { throw LiveRepositoryError.incompatibleSchema(response.schemaVersion) }
        let carried = (memory ?? (try? readCache()))?.pendingRemaps ?? []
        let catalog = CachedCatalog(schemaVersion: response.schemaVersion, cursor: response.cursor, events: response.events, pendingRemaps: carried)
        try persist(catalog); memory = catalog
        return catalog
    }

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:], headers: [String: String] = [:]) async throws -> T {
        let (data, http) = try await perform(path, query: query, headers: headers)
        guard (200..<300).contains(http.statusCode) else { throw HTTPError(statusCode: http.statusCode) }
        return try decoder.decode(T.self, from: data)
    }

    private func perform(_ path: String, query: [String: String] = [:], headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        guard baseURL.scheme?.lowercased() == "https" else { throw LiveRepositoryError.invalidBaseURL }
        guard var parts = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false) else { throw LiveRepositoryError.invalidBaseURL }
        if !query.isEmpty { parts.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = parts.url else { throw LiveRepositoryError.invalidBaseURL }
        var request = URLRequest(url: url); request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearerToken, !bearerToken.isEmpty { request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization") }
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LiveRepositoryError.invalidResponse }
        return (data, http)
    }

    private func readCache() throws -> CachedCatalog { try decoder.decode(CachedCatalog.self, from: Data(contentsOf: cacheURL)) }
    private func persist(_ catalog: CachedCatalog) throws {
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let temporary = cacheDirectory.appendingPathComponent("catalog-\(UUID().uuidString).tmp")
        try encoder.encode(catalog).write(to: temporary, options: .atomic)
        if fileManager.fileExists(atPath: cacheURL.path) { _ = try fileManager.replaceItemAt(cacheURL, withItemAt: temporary) }
        else { try fileManager.moveItem(at: temporary, to: cacheURL) }
    }
    @discardableResult
    private func upsertAndPersist(_ bundle: LiveEventBundle, etag: String? = nil) throws -> LiveEventBundle {
        var catalog = memory ?? (try? readCache()) ?? CachedCatalog(schemaVersion: 1, cursor: "", events: [])
        if let stored = catalog.events.first(where: { $0.event.id == bundle.event.id }), let incomingRevision = bundle.revision, let storedRevision = stored.revision, incomingRevision < storedRevision { return stored }
        catalog.events.removeAll { $0.event.id == bundle.event.id }
        catalog.events.append(bundle)
        if let etag { catalog.etags[bundle.event.id] = etag }
        try persist(catalog); memory = catalog
        return bundle
    }
    private var cacheURL: URL { cacheDirectory.appendingPathComponent("catalog.json") }

    private static func preferredBundle(stored: LiveEventBundle?, incoming: LiveEventBundle) -> LiveEventBundle {
        guard let stored, let incomingRevision = incoming.revision, let storedRevision = stored.revision, incomingRevision < storedRevision else { return incoming }
        return stored
    }

    private static func cacheNamespace(for url: URL, serverInstanceID: String?) -> String {
        if let serverInstanceID, !serverInstanceID.isEmpty {
            let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
            let sanitized = String(serverInstanceID.map { allowed.contains($0) ? $0 : "_" })
            return "instance-\(sanitized)-v1"
        }
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in url.absoluteString.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return "\(String(hash, radix: 16))-v1"
    }
}

public struct HTTPError: Error, Sendable { public let statusCode: Int }
