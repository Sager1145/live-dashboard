import Foundation

public struct CatalogBootstrapPage: Sendable, Equatable {
    public let schemaVersion: Int
    public let serverInstanceID: String
    public let snapshotID: String
    public let cursor: String
    public let watermark: String
    public let hasMore: Bool
    public let nextPageToken: String?
    public let events: [CatalogEventDocumentV2]
}

public struct CatalogChangeV2: Sendable, Equatable {
    public enum Body: Sendable, Equatable {
        case upsert(CatalogEventDocumentV2)
        case delete(eventID: String, revision: Int)
        case remap(entityKind: String, legacyID: String, currentID: String)
        case unknown(String)
    }

    public let sequence: String
    public let body: Body
}

public struct CatalogChangesPage: Sendable, Equatable {
    public let schemaVersion: Int
    public let serverInstanceID: String
    public let fromCursor: String
    public let cursor: String
    public let watermark: String
    public let hasMore: Bool
    public let nextPageToken: String?
    public let changes: [CatalogChangeV2]
    public let sourceHealth: [String: String]
}

public struct CatalogServerMeta: Sendable, Equatable {
    public let serverInstanceID: String
    public let schemaVersions: [Int]
    public let capabilities: [String]
}

/// GET catalog routes only. Update jobs are `UpdateJobClient`, not this type.
public struct CatalogAPIClient: Sendable {
    public let baseURL: URL
    public let session: URLSession
    public let accessToken: String?

    public init(baseURL: URL, session: URLSession = .shared, accessToken: String? = nil) {
        self.baseURL = baseURL
        self.session = session
        self.accessToken = accessToken
    }

    public func meta() async throws -> CatalogServerMeta {
        let data = try await get(path: "v2/meta", query: [])
        let object = try CatalogWire.object(data)
        let versions = object["schemaVersions"] as? [Any] ?? []
        return CatalogServerMeta(
            serverInstanceID: try CatalogWire.string(object, "serverInstanceID"),
            schemaVersions: versions.compactMap { ($0 as? NSNumber)?.intValue ?? ($0 as? Int) },
            capabilities: object["capabilities"] as? [String] ?? []
        )
    }

    public func bootstrapPage(pageToken: String?) async throws -> CatalogBootstrapPage {
        var query: [URLQueryItem] = []
        if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        let data = try await get(path: "v2/catalog/bootstrap", query: query)
        return try CatalogWire.bootstrap(data)
    }

    public func changesPage(cursor: String, pageToken: String?) async throws -> CatalogChangesPage {
        var query = [URLQueryItem(name: "cursor", value: cursor)]
        if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        let data = try await get(path: "v2/catalog/changes", query: query)
        return try CatalogWire.changes(data)
    }

    public func publishedEvent(eventID: String) async throws -> CatalogEventDocumentV2 {
        let data = try await get(path: "v2/events/\(eventID)", query: [])
        return try CatalogEventDocumentV2(payload: data)
    }

    private func get(path: String, query: [URLQueryItem]) async throws -> Data {
        guard var parts = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw LiveRepositoryError.invalidBaseURL
        }
        if !query.isEmpty { parts.queryItems = query }
        guard let url = parts.url else { throw LiveRepositoryError.invalidBaseURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.httpBody = nil
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accessToken { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CatalogSyncError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw HTTPError(statusCode: http.statusCode) }
        return data
    }
}

enum CatalogWire {
    static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CatalogSyncError.invalidResponse
        }
        return object
    }

    static func string(_ object: [String: Any], _ key: String) throws -> String {
        guard let value = object[key] as? String else { throw CatalogSyncError.invalidResponse }
        return value
    }

    static func decimal(_ object: [String: Any], _ key: String) throws -> String {
        guard let value = object[key] as? String else { throw CatalogSyncError.invalidResponse }
        try validateDecimal(value)
        return value
    }

    static func validateDecimal(_ value: String) throws {
        let digits = value.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
        let leadingZero = value.count > 1 && value.first == "0"
        guard !value.isEmpty, digits, !leadingZero else { throw CatalogSyncError.invalidCursor(value) }
    }

    static func token(_ object: [String: Any]) -> String? {
        if object["nextPageToken"] is NSNull { return nil }
        return object["nextPageToken"] as? String
    }

    static func bootstrap(_ data: Data) throws -> CatalogBootstrapPage {
        let object = try object(data)
        let schema = (object["schemaVersion"] as? NSNumber)?.intValue ?? -1
        guard schema == 2 else { throw CatalogSyncError.incompatibleSchema(schema) }
        let events = try (object["events"] as? [Any] ?? []).map { item -> CatalogEventDocumentV2 in
            let payload = try JSONSerialization.data(withJSONObject: item)
            return try CatalogEventDocumentV2(payload: payload)
        }
        return CatalogBootstrapPage(
            schemaVersion: schema,
            serverInstanceID: try string(object, "serverInstanceID"),
            snapshotID: try string(object, "snapshotID"),
            cursor: try decimal(object, "cursor"),
            watermark: try decimal(object, "watermark"),
            hasMore: object["hasMore"] as? Bool ?? false,
            nextPageToken: token(object),
            events: events
        )
    }

    static func changes(_ data: Data) throws -> CatalogChangesPage {
        let object = try object(data)
        let schema = (object["schemaVersion"] as? NSNumber)?.intValue ?? -1
        guard schema == 2 else { throw CatalogSyncError.incompatibleSchema(schema) }
        let rawChanges = object["changes"] as? [Any] ?? []
        let changes = try rawChanges.map { item -> CatalogChangeV2 in
            guard let change = item as? [String: Any] else { throw CatalogSyncError.invalidResponse }
            let sequence = try decimal(change, "sequence")
            let kind = try string(change, "kind")
            switch kind {
            case "upsert":
                guard let bundle = change["bundle"] else { throw CatalogSyncError.invalidResponse }
                let payload = try JSONSerialization.data(withJSONObject: bundle)
                let document = try CatalogEventDocumentV2(payload: payload)
                let eventID = try string(change, "eventID")
                let revision = (change["revision"] as? NSNumber)?.intValue
                guard eventID == document.eventID, revision == document.revision else {
                    throw CatalogSyncError.invalidResponse
                }
                return CatalogChangeV2(sequence: sequence, body: .upsert(document))
            case "delete":
                let revision = (change["revision"] as? NSNumber)?.intValue ?? -1
                guard revision >= 0 else { throw CatalogSyncError.invalidResponse }
                return CatalogChangeV2(sequence: sequence, body: .delete(eventID: try string(change, "eventID"), revision: revision))
            case "remap":
                return CatalogChangeV2(
                    sequence: sequence,
                    body: .remap(
                        entityKind: try string(change, "entityKind"),
                        legacyID: try string(change, "legacyID"),
                        currentID: try string(change, "currentID")
                    )
                )
            default:
                return CatalogChangeV2(sequence: sequence, body: .unknown(kind))
            }
        }
        var health: [String: String] = [:]
        if let raw = object["sourceHealth"] as? [String: Any] {
            for (key, value) in raw {
                if let text = value as? String { health[key] = text }
            }
        }
        return CatalogChangesPage(
            schemaVersion: schema,
            serverInstanceID: try string(object, "serverInstanceID"),
            fromCursor: try decimal(object, "fromCursor"),
            cursor: try decimal(object, "cursor"),
            watermark: try decimal(object, "watermark"),
            hasMore: object["hasMore"] as? Bool ?? false,
            nextPageToken: token(object),
            changes: changes,
            sourceHealth: health
        )
    }
}
