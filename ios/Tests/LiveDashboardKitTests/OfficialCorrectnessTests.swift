import XCTest
@testable import LiveDashboardKit

/// Negative cases from the 2026-09-23 audit. Each one goes through `collect`,
/// not the helper that the bug was copied from.
final class OfficialCorrectnessTests: XCTestCase {
    override func tearDown() {
        CorrectnessURLProtocol.responses = [:]
        super.tearDown()
    }

    func testUnknownHallStaysCityEmpty() async throws {
        let html = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">Unknown Hall Live</h1>
          <div class="p-live-event-detail__content">
            <h2>日程</h2><p>2027年3月1日(月)　開場17:00／開演18:00</p>
            <h2>会場</h2><p>Example Hall Nowhere</p>
          </div>
        </article>
        """
        let refreshed = try await refresh(html: html, url: "https://bang-dream.com/events/unknown-hall/", title: "Unknown Hall Live")
        XCTAssertEqual(refreshed.performances.first?.venueName, "Example Hall Nowhere")
        XCTAssertEqual(refreshed.performances.first?.venueCity, "")
    }

    func testConditionalAndNegativeCancellationClausesStayScheduled() async throws {
        for clause in [
            "開催中止の場合は払い戻しいたします。",
            "開催中止ではありません。予定通り開催します。",
        ] {
            let html = """
            <article class="p-live-event-detail">
              <h1 class="p-live-event-detail__header-title">Clause Live</h1>
              <div class="p-live-event-detail__content">
                <h2>日程</h2><p>2027年3月1日(月)　開場17:00／開演18:00</p>
                <h2>会場</h2><p>Zepp Shinjuku</p>
                <h2>チケット</h2><p>\(clause)</p>
              </div>
            </article>
            """
            let refreshed = try await refresh(html: html, url: "https://bang-dream.com/events/clause/", title: "Clause Live")
            XCTAssertEqual(refreshed.event.status, .scheduled, clause)
        }
    }

    func testExplicitCancellationNoticeCancelsAndKeepsTheQuote() async throws {
        let html = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">Notice Live</h1>
          <div class="p-live-event-detail__content">
            <h2>重要なお知らせ</h2><p>本公演は開催中止となりました。</p>
            <h2>日程</h2><p>2027年3月1日(月)　開場17:00／開演18:00</p>
            <h2>会場</h2><p>Zepp Shinjuku</p>
          </div>
        </article>
        """
        let refreshed = try await refresh(html: html, url: "https://bang-dream.com/events/notice/", title: "Notice Live")
        XCTAssertEqual(refreshed.event.status, .cancelled)
        XCTAssertEqual(
            refreshed.evidence.first { $0.field == "event.status" }?.quote.contains("本公演は開催中止となりました。"),
            true
        )
    }

    func testConditionalPostponementClauseDoesNotPostpone() async throws {
        let html = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">Postpone Clause</h1>
          <div class="p-live-event-detail__content">
            <h2>日程</h2><p>2027年3月1日(月)　開場17:00／開演18:00</p>
            <h2>会場</h2><p>Zepp Shinjuku</p>
            <h2>チケット</h2><p>開催延期の場合は改めてご案内します。</p>
          </div>
        </article>
        """
        let refreshed = try await refresh(html: html, url: "https://bang-dream.com/events/postpone-clause/", title: "Postpone Clause")
        XCTAssertEqual(refreshed.event.status, .scheduled)
    }

    func testUnmatchedDayDoesNotInheritOtherCast() async throws {
        let html = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">Three Days</h1>
          <div class="p-live-event-detail__content">
            <h2>日程・会場</h2>
            <h6>DAY1</h6><p>日程：2026年11月1日(日)<br>会場：東京ドーム</p>
            <h6>DAY2</h6><p>日程：2026年11月2日(月)<br>会場：東京ドーム</p>
            <h6>DAY3</h6><p>日程：2026年11月3日(火)<br>会場：東京ドーム</p>
            <h2>出演</h2>
            <p>DAY1<br>DAY1_ONLY<br>DAY2<br>DAY2_ONLY</p>
          </div>
        </article>
        """
        let refreshed = try await refresh(html: html, url: "https://bang-dream.com/events/three-days/", title: "Three Days")
        XCTAssertEqual(refreshed.performances.map(\.performers), [["DAY1_ONLY"], ["DAY2_ONLY"], []])
    }

    func testDay2OnlyCastMemberStaysOffDay1() async throws {
        let html = """
        <html><head><meta property="og:description" content="103期卒業公演"></head>
        <body><article>
          <div data-target="top">
            <h3>日程</h3>
            <p>Day.1　2027年1月23日(土) 16:00開場／17:00開演<br>Day.2　2027年1月24日(日) 14:30開場／15:30開演</p>
            <h3>会場</h3><p>東京・日本武道館</p>
            <h3>出演</h3>
            <p>＜Day.1＞<br>蓮ノ空女学院スクールアイドルクラブ<br>＜Day.2＞<br>蓮ノ空女学院スクールアイドルクラブ<br>花宮初奈</p>
          </div>
        </article></body></html>
        """
        let refreshed = try await refresh(
            html: html,
            url: "https://www.lovelive-anime.jp/hasunosora/live-event/live_detail.php?p=cast-day2",
            title: "103期卒業公演",
            franchise: .lovelive
        )
        let day1 = try XCTUnwrap(refreshed.performances.first { $0.localDate == "2027-01-23" })
        let day2 = try XCTUnwrap(refreshed.performances.first { $0.localDate == "2027-01-24" })
        XCTAssertFalse(day1.performers.contains("花宮初奈"))
        XCTAssertTrue(day2.performers.contains("花宮初奈"))
        XCTAssertTrue(day1.performers.contains("蓮ノ空女学院スクールアイドルクラブ"))
    }

    func testRescheduledDateDropsPreviousAbsoluteTime() async throws {
        let url = "https://bang-dream.com/events/reschedule/"
        let original = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">Reschedule Live</h1>
          <div class="p-live-event-detail__content">
            <h2>日程・会場</h2>
            <h6>DAY1</h6><p>日程：2026年5月1日(金)　開場17:00／開演18:00<br>会場：Zepp Shinjuku</p>
          </div>
        </article>
        """
        let moved = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">Reschedule Live</h1>
          <div class="p-live-event-detail__content">
            <h2>日程・会場</h2>
            <h6>DAY1</h6><p>日程：2026年6月1日(月)<br>会場：Zepp Shinjuku</p>
          </div>
        </article>
        """
        let first = try await refresh(html: original, url: url, title: "Reschedule Live")
        let firstPerformance = try XCTUnwrap(first.performances.first)
        XCTAssertEqual(firstPerformance.localDate, "2026-05-01")
        XCTAssertNotNil(firstPerformance.startAt)

        let second = try await refresh(html: moved, url: url, title: "Reschedule Live", existing: first)
        let secondPerformance = try XCTUnwrap(second.performances.first)
        XCTAssertEqual(secondPerformance.id, firstPerformance.id)
        XCTAssertEqual(secondPerformance.localDate, "2026-06-01")
        XCTAssertNil(secondPerformance.doorsAt)
        XCTAssertNil(secondPerformance.startAt)
        XCTAssertEqual(secondPerformance.precision, .date)
    }

    func testSameDateDoesNotCopyCachedTimeWhenThePageOmitsIt() async throws {
        let url = "https://bang-dream.com/events/same-date/"
        let original = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">Same Date</h1>
          <div class="p-live-event-detail__content">
            <h2>日程</h2><p>2026年5月1日(金)　開場17:00／開演18:00</p>
            <h2>会場</h2><p>Zepp Shinjuku</p>
          </div>
        </article>
        """
        let omitted = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">Same Date</h1>
          <div class="p-live-event-detail__content">
            <h2>日程</h2><p>2026年5月1日(金)</p>
            <h2>会場</h2><p>Zepp Shinjuku</p>
          </div>
        </article>
        """
        let first = try await refresh(html: original, url: url, title: "Same Date")
        let second = try await refresh(html: omitted, url: url, title: "Same Date", existing: first)
        XCTAssertEqual(second.performances.first?.localDate, "2026-05-01")
        XCTAssertNil(second.performances.first?.startAt)
        XCTAssertNil(second.performances.first?.doorsAt)
        XCTAssertEqual(second.performances.first?.id, first.performances.first?.id)
    }

    func testEmptyTicketParseDropsCachedRoundsAndStaysHealthy() async throws {
        let url = "https://bang-dream.com/events/stale-tickets/"
        let original = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">Stale Tickets</h1>
          <div class="p-live-event-detail__content">
            <h2>日程</h2><p>2027年3月1日(月)　開場17:00／開演18:00</p>
            <h2>会場</h2><p>Zepp Shinjuku</p>
            <h2>チケット</h2>
            <h3>販売情報</h3>
            <h6>一般発売</h6>
            <p>受付期間：2026年9月1日(火) 12:00 ～ 2026年9月10日(木) 23:59</p>
          </div>
        </article>
        """
        let stripped = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">Stale Tickets</h1>
          <div class="p-live-event-detail__content">
            <h2>日程</h2><p>2027年3月1日(月)　開場17:00／開演18:00</p>
            <h2>会場</h2><p>Zepp Shinjuku</p>
          </div>
        </article>
        """
        let first = try await refresh(html: original, url: url, title: "Stale Tickets")
        XCTAssertEqual(first.sourceHealth, .healthy)
        XCTAssertFalse(first.ticketRounds.isEmpty)

        let second = try await refresh(html: stripped, url: url, title: "Stale Tickets", existing: first)
        XCTAssertTrue(second.ticketRounds.isEmpty)
        XCTAssertEqual(second.sourceHealth, .healthy)
        XCTAssertEqual(second.performances.first?.venueName, "Zepp Shinjuku")
    }

    func testImageOnlyGoodsDoNotBecomeProducts() async throws {
        let html = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">Goods Pictures</h1>
          <div class="p-live-event-detail__content">
            <h2>日程</h2><p>2027年3月1日(月)　開場17:00／開演18:00</p>
            <h2>会場</h2><p>Zepp Shinjuku</p>
            <h2>グッズ情報</h2>
            <p><img src="https://bang-dream.com/images/goods-list.jpg" alt="商品一覧"></p>
          </div>
        </article>
        """
        let refreshed = try await refresh(html: html, url: "https://bang-dream.com/events/goods-pictures/", title: "Goods Pictures")
        XCTAssertTrue(refreshed.mediaAssets.contains { $0.originalURL.contains("goods-list.jpg") })
        XCTAssertTrue(refreshed.products.isEmpty)
        XCTAssertTrue(refreshed.goodsSessions.isEmpty)
    }

    func testGoodsWindowBecomesASession() async throws {
        let html = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">Goods Window</h1>
          <div class="p-live-event-detail__content">
            <h2>日程</h2><p>2027年3月1日(月)　開場17:00／開演18:00</p>
            <h2>会場</h2><p>Zepp Shinjuku</p>
            <h2>グッズ通販</h2>
            <p><a href="https://bushiroad-store.com/pages/window">通販ページ</a><br>2026年8月21日(金) 15:00より受付開始<br>お一人様1点まで</p>
          </div>
        </article>
        """
        let refreshed = try await refresh(html: html, url: "https://bang-dream.com/events/goods-window/", title: "Goods Window")
        let session = try XCTUnwrap(refreshed.goodsSessions.first)
        XCTAssertNotNil(session.startsAt)
        XCTAssertEqual(refreshed.products.first?.purchaseLimit?.contains("1点"), true)
    }

    func testUnclosedDetailContainerStillParsesTheTicketRound() async throws {
        let html = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">Unclosed</h1>
          <div class="p-live-event-detail__content">
            <h2>日程</h2><p>2027年3月1日(月)　開場17:00／開演18:00</p>
            <h2>会場</h2><p>Zepp Shinjuku</p>
            <h2>チケット</h2>
            <h3>販売情報</h3>
            <h6>一般発売</h6>
            <p>受付期間：2026年9月1日(火) 12:00 ～ 2026年9月10日(木) 23:59</p>
        """
        let refreshed = try await refresh(html: html, url: "https://bang-dream.com/events/unclosed/", title: "Unclosed")
        XCTAssertEqual(refreshed.ticketRounds.first?.officialName, "一般発売")
        let slices = OfficialPageBlocks.sourceBlocks(
            html: html,
            baseURL: URL(string: "https://bang-dream.com/events/unclosed/")!,
            snapshotID: "unclosed"
        )
        XCTAssertTrue(slices.contains { $0.headingPath.contains("一般発売") })
    }

    func testWholeEventHeadingBindsEveryPerformance() async throws {
        let html = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">All Days</h1>
          <div class="p-live-event-detail__content">
            <h2>日程・会場</h2>
            <h6>DAY1</h6><p>日程：2026年8月1日(土)<br>会場：Kアリーナ横浜</p>
            <h6>DAY2</h6><p>日程：2026年8月2日(日)<br>会場：Kアリーナ横浜</p>
            <h2>チケット</h2>
            <h3>販売情報</h3>
            <h6>全公演一般発売</h6>
            <p>受付期間：2026年6月6日(土) 12:00 ～</p>
          </div>
        </article>
        """
        let refreshed = try await refresh(html: html, url: "https://bang-dream.com/events/all-days/", title: "All Days")
        let round = try XCTUnwrap(refreshed.ticketRounds.first { $0.officialName == "全公演一般発売" })
        XCTAssertEqual(round.scope, .performances(performanceIDs: refreshed.performances.map(\.id)))
    }

    private func refresh(
        html: String,
        url: String,
        title: String,
        franchise: Franchise = .bangdream,
        existing: LiveEventBundle? = nil
    ) async throws -> LiveEventBundle {
        CorrectnessURLProtocol.responses[url] = Data(html.utf8)
        let event = existing?.event ?? LiveEvent(
            id: "correctness-event", franchise: franchise, officialTitle: title, groups: [],
            eventType: .live, status: .unknown, primarySourceURL: url, timeZone: "Asia/Tokyo"
        )
        let bundle = existing ?? LiveEventBundle(
            schemaVersion: 1, publishedAt: .distantPast, event: event, stops: [],
            performances: [], ticketTiers: [], ticketRounds: [], ticketOffers: [],
            goodsCampaigns: [], mediaAssets: [], notices: [], evidence: []
        )
        return try await OfficialEventScraper(session: session(), indexURLs: [])
            .collect(event: bundle, now: Self.date("2026-09-22T12:00:00Z"))
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CorrectnessURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}

private final class CorrectnessURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [String: Data] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let data = Self.responses[url.absoluteString] else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
