import Foundation
import LiveIngestionCore

// Runs the production parser against independently captured official responses.
// Built with SwiftPM (`swift build --product OfficialAuditCLI`); no server dependency.
private final class AuditURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [String: Data] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let body = Self.responses[url.absoluteString] else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html; charset=utf-8"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct OfficialScraperAudit {
    struct Input: Decodable {
        let id: String
        let url: String
        let path: String
        let title: String
        let franchise: String
        let groups: [String]?
    }
    struct Output: Encodable {
        let id: String
        let url: String
        let bundle: LiveEventBundle?
        let error: String?
    }
    static func main() async throws {
        guard (3 ... 4).contains(CommandLine.arguments.count) else {
            fatalError("Usage: official-scraper-audit manifest.json output.json [--live]")
        }
        let inputs = try JSONDecoder().decode([Input].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let live = CommandLine.arguments.contains("--live")
        if !live {
            for input in inputs { AuditURLProtocol.responses[input.url] = try Data(contentsOf: URL(fileURLWithPath: input.path)) }
        }
        let config = URLSessionConfiguration.ephemeral
        if !live { config.protocolClasses = [AuditURLProtocol.self] }
        let scraper = OfficialEventScraper(session: URLSession(configuration: config), indexURLs: [])
        let now = ISO8601DateFormatter().date(from: "2026-09-22T12:00:00Z")!
        var results: [Output] = []
        for input in inputs {
            let event = LiveEvent(id: input.id, franchise: input.franchise == "bangdream" ? .bangdream : .lovelive, officialTitle: input.title, groups: input.groups ?? [], eventType: .live, status: .unknown, primarySourceURL: input.url, timeZone: "Asia/Tokyo")
            let empty = LiveEventBundle(schemaVersion: 1, publishedAt: now, event: event, stops: [], performances: [], ticketTiers: [], ticketRounds: [], ticketOffers: [], goodsCampaigns: [], mediaAssets: [], notices: [], evidence: [])
            do {
                let bundle = try await scraper.collect(event: empty, now: now)
                results.append(.init(id: input.id, url: input.url, bundle: bundle, error: nil))
            } catch { results.append(.init(id: input.id, url: input.url, bundle: nil, error: String(describing: error))) }
            print("\(results.count)/\(inputs.count) \(input.id): \(results.last?.error ?? "parsed")")
        }
        try LiveEventBundle.encoder.encode(results).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        print("Audited \(results.count) \(live ? "live responses" : "captured pages"); \(results.filter { $0.error != nil }.count) parser failures")
    }
}
