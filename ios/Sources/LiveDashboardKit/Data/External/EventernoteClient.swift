import Foundation
import LiveIngestionCore

public protocol EventernoteTransport: Sendable {
    func response(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: EventernoteTransport {
    public func response(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request)
    }
}

public struct EventernoteBudget: Equatable, Sendable {
    public var maxRequests: Int
    public init(maxRequests: Int = 8) { self.maxRequests = maxRequests }
}

public struct EventernoteEventQuery: Equatable, Sendable {
    public var keyword: String?
    public var date: String?
    public var region: String?
    public var prefecture: String?
    public var actorID: String?
    public var placeID: String?
    public var page: Int

    public init(keyword: String? = nil, date: String? = nil, region: String? = nil, prefecture: String? = nil, actorID: String? = nil, placeID: String? = nil, page: Int = 1) {
        self.keyword = keyword
        self.date = date
        self.region = region
        self.prefecture = prefecture
        self.actorID = actorID
        self.placeID = placeID
        self.page = page
    }
}

public actor EventernoteClient {
    private let transport: any EventernoteTransport
    private let budget: EventernoteBudget
    private let origin: URL
    private var crumbValue: String?
    private var requestCount = 0

    public init(transport: any EventernoteTransport, budget: EventernoteBudget = EventernoteBudget(), origin: URL = EventernoteHTMLParser.origin) {
        self.transport = transport
        self.budget = budget
        self.origin = origin
    }

    public func listEvents(_ query: EventernoteEventQuery) async throws -> EventernoteListResult {
        if query.actorID != nil || query.placeID != nil {
            guard query.region == nil, query.prefecture == nil else { throw EventernoteClientError.unsupportedFilter }
        }
        let path: String
        if let actorID = query.actorID { path = "/actors/\(actorID)/events" }
        else if let placeID = query.placeID { path = "/places/\(placeID)/events" }
        else { path = "/events/search" }
        var components = URLComponents(url: origin.appendingPathComponent(String(path.dropFirst())), resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [URLQueryItem(name: "page", value: String(query.page))]
        if let keyword = query.keyword { items.append(URLQueryItem(name: "keyword", value: keyword)) }
        if let date = query.date {
            let parts = date.split(separator: "-")
            if parts.count == 3 {
                items.append(URLQueryItem(name: "year", value: String(parts[0])))
                items.append(URLQueryItem(name: "month", value: String(parts[1])))
                items.append(URLQueryItem(name: "day", value: String(parts[2])))
            }
        }
        if let region = query.region { items.append(URLQueryItem(name: "area_id", value: region)) }
        if let prefecture = query.prefecture { items.append(URLQueryItem(name: "prefecture_id", value: prefecture)) }
        components.queryItems = items
        let html = try await text(URLRequest(url: components.url!))
        let raw = try EventernoteHTMLParser.eventList(in: html)
        let matched = query.keyword.map { keyword in raw.filter { $0.name.localizedCaseInsensitiveContains(keyword) } } ?? raw
        return EventernoteListResult(matched: matched, rawCount: raw.count, page: query.page, reachedBudget: requestCount >= budget.maxRequests)
    }

    public func event(id: String) async throws -> EventernoteEventDetail {
        let url = origin.appendingPathComponent("events/\(id)")
        return try EventernoteHTMLParser.eventDetail(in: try await text(URLRequest(url: url)), pageURL: url)
    }

    public func place(id: String) async throws -> EventernotePlaceSummary {
        let url = origin.appendingPathComponent("places/\(id)")
        return try EventernoteHTMLParser.placeDetail(in: try await text(URLRequest(url: url)), pageURL: url)
    }

    public func searchActors(keyword: String) async throws -> [EventernoteActorSummary] {
        try await search(path: "/api/actors/search", keyword: keyword, decode: EventernoteHTMLParser.actors(fromJSON:))
    }

    public func searchPlaces(keyword: String) async throws -> [EventernotePlaceSummary] {
        try await search(path: "/api/places/search", keyword: keyword, decode: EventernoteHTMLParser.places(fromJSON:))
    }

    private func search<T>(path: String, keyword: String, decode: (Data) throws -> [T]) async throws -> [T] {
        let crumb = try await crumbToken(forceRefresh: false)
        do {
            return try decode(try await data(searchRequest(path: path, keyword: keyword, crumb: crumb)))
        } catch EventernoteClientError.http {
            crumbValue = nil
            let refreshed = try await crumbToken(forceRefresh: true)
            return try decode(try await data(searchRequest(path: path, keyword: keyword, crumb: refreshed)))
        }
    }

    private func searchRequest(path: String, keyword: String, crumb: String) -> URLRequest {
        var components = URLComponents(url: origin.appendingPathComponent(String(path.dropFirst())), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "keyword", value: keyword), URLQueryItem(name: "crumb", value: crumb)]
        return URLRequest(url: components.url!)
    }

    private func crumbToken(forceRefresh: Bool) async throws -> String {
        if !forceRefresh, let crumbValue { return crumbValue }
        let html = try await text(URLRequest(url: origin))
        let crumb = try EventernoteHTMLParser.crumb(in: html)
        crumbValue = crumb
        return crumb
    }

    private func text(_ request: URLRequest) async throws -> String {
        let body = try await data(request)
        guard let text = String(data: body, encoding: .utf8) else { throw EventernoteClientError.parse }
        return text
    }

    private func data(_ request: URLRequest) async throws -> Data {
        guard requestCount < budget.maxRequests else { throw EventernoteClientError.budgetExhausted }
        requestCount += 1
        let (body, response) = try await transport.response(for: request)
        guard let http = response as? HTTPURLResponse else { throw EventernoteClientError.parse }
        guard (200..<300).contains(http.statusCode) else { throw EventernoteClientError.http(http.statusCode) }
        let mime = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        if !mime.isEmpty, !mime.contains("html"), !mime.contains("json"), !mime.contains("text") {
            throw EventernoteClientError.parse
        }
        return body
    }
}
