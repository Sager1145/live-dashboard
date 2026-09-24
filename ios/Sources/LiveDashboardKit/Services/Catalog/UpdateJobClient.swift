import Foundation

/// Owner refresh jobs. Catalog GETs do not construct this request.
public struct UpdateJobClient: RefreshJobService, Sendable {
    public let baseURL: URL
    public let session: URLSession
    public let accessToken: String?

    public init(baseURL: URL, session: URLSession = .shared, accessToken: String? = nil) {
        self.baseURL = baseURL
        self.session = session
        self.accessToken = accessToken
    }

    public func requestRefresh(_ request: RefreshRequest) async throws -> RefreshJob {
        let data = try await send(method: "POST", path: "v2/update-jobs", body: try Self.body(request))
        return try Self.job(data, fallbackState: "queued")
    }

    public func status(jobID: String) async throws -> RefreshJob {
        let data = try await send(method: "GET", path: "v2/update-jobs/\(jobID)", body: nil)
        return try Self.job(data, fallbackState: "")
    }

    private func send(method: String, path: String, body: Data?) async throws -> Data {
        guard let url = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)?.url else {
            throw LiveRepositoryError.invalidBaseURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let accessToken { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw HTTPError(statusCode: status)
        }
        return data
    }

    private static func body(_ request: RefreshRequest) throws -> Data {
        var target: [String: String]
        switch request.target {
        case .catalog:
            target = ["kind": "catalog"]
        case .source(let sourceID):
            target = ["kind": "source", "sourceID": sourceID]
        case .event(let eventID):
            target = ["kind": "event", "eventID": eventID]
        case .eventSection(let eventID, let section):
            target = ["kind": "eventSection", "eventID": eventID, "section": section]
        case .card(let eventID, let cardID):
            target = ["kind": "card", "eventID": eventID, "cardID": cardID]
        case .history(let eventID):
            target = ["kind": "history", "eventID": eventID]
        }
        let object: [String: Any] = [
            "target": target,
            "fetchLatest": request.fetchLatest,
            "reextract": request.reextract,
            "reason": request.reason,
        ]
        return try JSONSerialization.data(withJSONObject: object)
    }

    private static func job(_ data: Data, fallbackState: String) throws -> RefreshJob {
        let object = try CatalogWire.object(data)
        return RefreshJob(
            jobID: try CatalogWire.string(object, "jobID"),
            state: (object["state"] as? String) ?? fallbackState,
            deduplicated: object["deduplicated"] as? Bool,
            statusPath: object["statusPath"] as? String
        )
    }
}
