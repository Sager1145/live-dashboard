import XCTest
@testable import LiveDashboardKit

final class LLPlainDetailTests: XCTestCase {
    override func tearDown() {
        LLPlainDetailURLProtocol.body = nil
        super.tearDown()
    }

    func testJimoaiPlainBodyParsesSixPerformancesVenueAndPrices() async throws {
        LLPlainDetailURLProtocol.body = try Data(contentsOf: Self.fixtureURL)

        let bundle = try await OfficialEventScraper(session: session(), indexURLs: [])
            .collect(event: Self.cachedBundle, now: Self.date("2026-09-22T12:00:00Z"))

        XCTAssertEqual(bundle.performances.map(\.localDate), [
            "2027-03-20", "2027-03-20", "2027-03-21",
            "2027-03-21", "2027-03-22", "2027-03-22",
        ])
        XCTAssertEqual(bundle.performances.map(\.dayLabel), [
            "DAY1", "DAY1", "DAY2", "DAY2", "DAY3", "DAY3",
        ])
        XCTAssertEqual(bundle.performances.map(\.subtitle), [
            "昼公演", "夜公演", "昼公演", "夜公演", "昼公演", "夜公演",
        ])
        XCTAssertEqual(bundle.performances.map(\.doorsAt), [
            Self.date("2027-03-20T04:00:00Z"), Self.date("2027-03-20T08:30:00Z"),
            Self.date("2027-03-21T04:00:00Z"), Self.date("2027-03-21T08:30:00Z"),
            Self.date("2027-03-22T04:00:00Z"), Self.date("2027-03-22T08:30:00Z"),
        ])
        XCTAssertEqual(bundle.performances.map(\.startAt), [
            Self.date("2027-03-20T05:00:00Z"), Self.date("2027-03-20T09:30:00Z"),
            Self.date("2027-03-21T05:00:00Z"), Self.date("2027-03-21T09:30:00Z"),
            Self.date("2027-03-22T05:00:00Z"), Self.date("2027-03-22T09:30:00Z"),
        ])
        XCTAssertTrue(bundle.performances.allSatisfy {
            $0.venueName == "キラメッセぬまづ（静岡県沼津市大手1丁目1−4）"
        })
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: bundle.ticketTiers.map { ($0.name, $0.priceJPY) }),
            ["全席指定(グッズ付き)": 11_500, "全席指定": 8_500]
        )
    }

    func testNotFoundBodyIsRejectedAsUnsupportedTemplate() async throws {
        LLPlainDetailURLProtocol.body = Data("NOT FOUND".utf8)

        do {
            _ = try await OfficialEventScraper(session: session(), indexURLs: [])
                .collect(event: Self.cachedBundle, now: Self.date("2026-09-22T12:00:00Z"))
            XCTFail("An HTTP 200 error body must not be accepted as official event detail")
        } catch let failure as OfficialScrapeFailure {
            XCTAssertEqual(failure.kind, .unsupportedTemplate)
            XCTAssertEqual(failure.message, "Missing Love Live structured detail body")
        }
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LLPlainDetailURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/audits/2026-09-22/lovelive/fixtures/jimoai5th.html")

    private static let cachedBundle: LiveEventBundle = {
        let event = LiveEvent(
            id: "ll-jimoai5th", franchise: .lovelive,
            officialTitle: "ラブライブ！サンシャイン!! 第５回沼津地元愛まつり",
            groups: ["Aqours"], eventType: .live, status: .unknown,
            primarySourceURL: "https://www.lovelive-anime.jp/uranohoshi/live/live_detail.php?p=jimoai5th",
            timeZone: "Asia/Tokyo"
        )
        return LiveEventBundle(
            schemaVersion: 1, publishedAt: .distantPast, event: event,
            stops: [], performances: [], ticketTiers: [], ticketRounds: [], ticketOffers: [],
            goodsCampaigns: [], mediaAssets: [], notices: [], evidence: []
        )
    }()

    private static func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}

private final class LLPlainDetailURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let body = Self.body else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
