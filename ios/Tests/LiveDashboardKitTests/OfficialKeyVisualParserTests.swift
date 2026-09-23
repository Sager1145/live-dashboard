import XCTest
@testable import LiveDashboardKit

final class OfficialKeyVisualParserTests: XCTestCase {
    override func tearDown() {
        KeyVisualURLProtocol.handler = nil
        super.tearDown()
    }

    func testBangDreamUsesEventEyecatchAndReplacesCachedKeyVisual() async throws {
        let html = try fixture("server/tests/fixtures/snapshots/bangdream_13th_live_day1.html")
        KeyVisualURLProtocol.handler = { request in Self.response(request, body: html) }
        let cached = bundle(
            franchise: .bangdream,
            sourceURL: "https://bang-dream.com/events/13th-live-day1/",
            cachedKeyVisual: MediaAsset(
                id: "stable-key-visual", eventID: "visual-event", kind: .keyVisual,
                originalURL: "https://bang-dream.com/old-event-art.jpg",
                thumbnailURL: "https://bang-dream.com/old-event-art-thumb.jpg",
                scope: .unconfirmed, sourceURL: "https://bang-dream.com/events/13th-live-day1/",
                version: 7, caption: "旧キービジュアル", displayPolicy: .remoteDisplay,
                contentKind: .image
            )
        )

        let refreshed = try await scraper().collect(event: cached, now: Self.date("2026-09-22T12:00:00Z"))

        let visuals = refreshed.mediaAssets.filter { $0.kind == .keyVisual }
        let visual = try XCTUnwrap(visuals.first)
        XCTAssertEqual(visuals.count, 1)
        XCTAssertEqual(visual.id, "stable-key-visual")
        XCTAssertEqual(visual.version, 8)
        XCTAssertEqual(
            visual.originalURL,
            "https://bang-dream.com/wordpress/wp-content/uploads/2026/10/24113355/7856fc99-6a2117bd-1891e8c5-9b2e33a8.png"
        )
        XCTAssertFalse(refreshed.mediaAssets.contains { $0.originalURL.contains("old-event-art") })
        XCTAssertFalse(visual.originalURL.contains("67144cdd-c1157a53-0c15dd0a-de6af61e"), "Goods artwork must not become the event visual")
    }

    func testLoveLiveUsesOfficialEventOGImageAsAbsoluteKeyVisual() async throws {
        let html = try fixture("server/tests/fixtures/snapshots/lovelive_detail_15th_lovelivefest.html")
        KeyVisualURLProtocol.handler = { request in Self.response(request, body: html) }

        let refreshed = try await scraper().collect(
            event: bundle(
                franchise: .lovelive,
                sourceURL: "https://www.lovelive-anime.jp/special/live/live_detail.php?p=15th_lovelivefest"
            ),
            now: Self.date("2026-09-22T12:00:00Z")
        )

        let visual = try XCTUnwrap(refreshed.mediaAssets.first { $0.kind == .keyVisual })
        XCTAssertEqual(
            visual.originalURL,
            "https://www.lovelive-anime.jp/special/live/image.php?img_path=/lovelive/jp/live/2026/02/13/1002/MTLGhpBqwB7hnEwW/eHMg6nlsLyB31Vqd.jpeg"
        )
        XCTAssertEqual(visual.contentKind, .image)
        XCTAssertEqual(visual.displayPolicy, .remoteDisplay)
        XCTAssertFalse(visual.originalURL.contains("HuNlLc1Huxjy9Bfl"), "Goods artwork must not become the event visual")
    }

    func testLoveLiveGenericOGPFallsBackToFirstEventArtwork() async throws {
        let html = try fixture("docs/audits/2026-09-22/lovelive/fixtures/LL10.html")
        KeyVisualURLProtocol.handler = { request in Self.response(request, body: html) }

        let refreshed = try await scraper().collect(
            event: bundle(
                franchise: .lovelive,
                sourceURL: "https://www.lovelive-anime.jp/lovehigh/live/live_detail.php?_id=2ndLIVE"
            ),
            now: Self.date("2026-09-22T12:00:00Z")
        )

        let visual = try XCTUnwrap(refreshed.mediaAssets.first { $0.kind == .keyVisual })
        XCTAssertEqual(
            visual.originalURL,
            "https://www.lovelive-anime.jp/lovelive/jp/live/2026/06/24/1003/bmrOCSJozVJTd4CB/milMTU3OSCGrRwoO.jpeg"
        )
        XCTAssertNotEqual(visual.originalURL, "https://www.lovelive-anime.jp/lovehigh/img/ogp.png")
        XCTAssertFalse(visual.originalURL.contains("logo"))
        XCTAssertEqual(refreshed.event.officialTitle, "いきづらい部！ 2nd LIVE Dou-Da? DOING! ～Reply to L～")
    }

    func testLiellaUsesRenderedArticleEndpointForMatchingOGImagePath() async throws {
        let cases = [
            (
                fixture: "LL06.html",
                sourceURL: "https://www.lovelive-anime.jp/yuigaoka/live/live_detail.php?p=8thlivetour",
                expectedURL: "https://www.lovelive-anime.jp/yuigaoka/common/api/image.php?img_path=/lovelive/jp/live/2026/09/03/1002/NxLuZEh2hhMek7is/p1h3XcoSoKvN2x1g.jpeg"
            ),
            (
                fixture: "LL13.html",
                sourceURL: "https://www.lovelive-anime.jp/yuigaoka/live/live_detail.php?p=taiikusai",
                expectedURL: "https://www.lovelive-anime.jp/yuigaoka/common/api/image.php?img_path=/lovelive/jp/live/2026/05/29/1002/XqqnD1fBbCzndRAi/BlafDuwJ8C7Iz9tg.jpeg"
            ),
            (
                fixture: "LL18.html",
                sourceURL: "https://www.lovelive-anime.jp/yuigaoka/live/live_detail.php?p=7thlive",
                expectedURL: "https://www.lovelive-anime.jp/yuigaoka/common/api/image.php?img_path=/lovelive/jp/live/2025/10/23/1002/Metu7cXE7duUer9N/Y7vyTHoDojEjEZ4A.jpeg"
            ),
        ]

        for item in cases {
            let html = try fixture("docs/audits/2026-09-22/lovelive/fixtures/\(item.fixture)")
            KeyVisualURLProtocol.handler = { request in Self.response(request, body: html) }
            let refreshed = try await scraper().collect(
                event: bundle(franchise: .lovelive, sourceURL: item.sourceURL),
                now: Self.date("2026-09-22T12:00:00Z")
            )

            let visual = try XCTUnwrap(refreshed.mediaAssets.first { $0.kind == .keyVisual })
            XCTAssertEqual(visual.originalURL, item.expectedURL, item.fixture)
            XCTAssertTrue(visual.originalURL.contains("/common/api/image.php"), item.fixture)
        }
    }

    private func scraper() -> OfficialEventScraper {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KeyVisualURLProtocol.self]
        return OfficialEventScraper(session: URLSession(configuration: configuration), indexURLs: [])
    }

    private func fixture(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func bundle(
        franchise: Franchise,
        sourceURL: String,
        cachedKeyVisual: MediaAsset? = nil
    ) -> LiveEventBundle {
        let event = LiveEvent(
            id: "visual-event", franchise: franchise, officialTitle: "Visual fixture",
            groups: [], eventType: .live, status: .scheduled,
            primarySourceURL: sourceURL, timeZone: "Asia/Tokyo"
        )
        return LiveEventBundle(
            schemaVersion: 1, publishedAt: .distantPast, event: event, stops: [],
            performances: [], ticketTiers: [], ticketRounds: [], ticketOffers: [],
            goodsCampaigns: [], mediaAssets: cachedKeyVisual.map { [$0] } ?? [], notices: [], evidence: []
        )
    }

    private static func response(_ request: URLRequest, body: String) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!,
            Data(body.utf8)
        )
    }

    private static func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}

private final class KeyVisualURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.unknown) }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
