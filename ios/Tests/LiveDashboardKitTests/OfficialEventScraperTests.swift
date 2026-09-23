import XCTest
@testable import LiveDashboardKit

final class OfficialEventScraperTests: XCTestCase {
    override func tearDown() {
        ScraperURLProtocol.handler = nil
        super.tearDown()
    }

    func testDailyCollectionFiltersOldSummaryBeforeFetchingDetailAndParsesBangDream() async throws {
        let index = """
        <html><section class="p-live-event-list">
          <article class="p-live-event-list__item"><a class="p-live-event-list__item-link" href="/events/new-live/">
            <div class="p-live-event-list__item-title">New LIVE</div>
            <div class="p-live-event-list__item-category">ライブ</div>
            <div><h2 class="p-live-event-list__item-date">開催日</h2><p>2027年1月9日(土)</p>
            <h2 class="p-live-event-list__item-place">場所</h2><p>東京・Test Hall</p></div>
            <span class="p-live-event-list__item-artist-item">Roselia</span>
          </a></article>
          <article class="p-live-event-list__item"><a class="p-live-event-list__item-link" href="/events/old-live/">
            <div class="p-live-event-list__item-title">Old LIVE</div>
            <div class="p-live-event-list__item-category">ライブ</div>
            <div><h2 class="p-live-event-list__item-date">開催日</h2><p>2024年1月1日(月)</p></div>
          </a></article>
        </section></html>
        """
        let detail = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">New LIVE</h1>
          <div class="p-live-event-detail__content">
            <h2>日程</h2><p>2027年1月9日(土) 開場16:00／開演17:00</p>
            <h2>会場</h2><p>東京・Test Hall</p>
            <h2>出演</h2><p>Roselia</p>
            <h2>チケット</h2><h3>料金</h3><p>一般指定席：9,900円(税込)</p>
            <h6>一般発売</h6><p>受付期間：2026年12月1日(火) 12:00～2026年12月20日(日) 23:59 先着</p>
          </div>
        </article>
        """
        var requestedPaths: [String] = []
        ScraperURLProtocol.handler = { request in
            requestedPaths.append(request.url!.path)
            if request.url?.path == "/events/" || request.url?.path == "/events" { return Self.response(request, body: index) }
            if request.url?.path == "/events/new-live/" || request.url?.path == "/events/new-live" { return Self.response(request, body: detail) }
            throw URLError(.badURL)
        }
        let scraper = OfficialEventScraper(session: session(), indexURLs: [URL(string: "https://bang-dream.com/events/")!])

        let bundles = try await scraper.collect(existing: [], cutoff: "2026-01-01", now: Self.date("2026-09-22T12:00:00Z"))

        XCTAssertEqual(bundles.map(\.event.officialTitle), ["New LIVE"])
        XCTAssertEqual(bundles.first?.performances.first?.localDate, "2027-01-09")
        XCTAssertEqual(bundles.first?.performances.first?.venueName, "東京・Test Hall")
        XCTAssertEqual(bundles.first?.performances.first?.performers, ["Roselia"])
        XCTAssertEqual(bundles.first?.ticketTiers.first?.priceJPY, 9_900)
        // A single-performance page can only mean that performance.
        let performanceID = try XCTUnwrap(bundles.first?.performances.first?.id)
        XCTAssertEqual(bundles.first?.ticketRounds.first?.scope, .performances(performanceIDs: [performanceID]))
        XCTAssertFalse(requestedPaths.contains("/events/old-live/"))
    }

    func testRangedCollectionFetchesArchivedEventsAndSkipsEventsOutsideTheWindow() async throws {
        let index = """
        <html><section class="p-live-event-list">
          <article class="p-live-event-list__item"><a class="p-live-event-list__item-link" href="/events/new-live/">
            <div class="p-live-event-list__item-title">New LIVE</div>
            <div class="p-live-event-list__item-category">ライブ</div>
            <div><h2 class="p-live-event-list__item-date">開催日</h2><p>2027年1月9日(土)</p>
            <h2 class="p-live-event-list__item-place">場所</h2><p>東京・Test Hall</p></div>
            <span class="p-live-event-list__item-artist-item">Roselia</span>
          </a></article>
          <article class="p-live-event-list__item"><a class="p-live-event-list__item-link" href="/events/old-live/">
            <div class="p-live-event-list__item-title">Old LIVE</div>
            <div class="p-live-event-list__item-category">ライブ</div>
            <div><h2 class="p-live-event-list__item-date">開催日</h2><p>2024年1月1日(月)</p></div>
          </a></article>
        </section></html>
        """
        let newDetail = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">New LIVE</h1>
          <div class="p-live-event-detail__content">
            <h2>日程</h2><p>2027年1月9日(土) 開場16:00／開演17:00</p>
            <h2>会場</h2><p>東京・Test Hall</p>
            <h2>出演</h2><p>Roselia</p>
            <h2>チケット</h2><h3>料金</h3><p>一般指定席：9,900円(税込)</p>
            <h6>一般発売</h6><p>受付期間：2026年12月1日(火) 12:00～2026年12月20日(日) 23:59 先着</p>
          </div>
        </article>
        """
        let oldDetail = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">Old LIVE</h1>
          <div class="p-live-event-detail__content">
            <h2>日程</h2><p>2024年1月1日(月) 開場16:00／開演17:00</p>
            <h2>会場</h2><p>東京・Test Hall</p>
            <h2>出演</h2><p>Roselia</p>
            <h2>チケット</h2><h3>料金</h3><p>一般指定席：9,900円(税込)</p>
            <h6>一般発売</h6><p>受付期間：2023年12月1日(金) 12:00～2023年12月20日(水) 23:59 先着</p>
          </div>
        </article>
        """
        var requestedPaths: [String] = []
        ScraperURLProtocol.handler = { request in
            requestedPaths.append(request.url!.path)
            if request.url?.path == "/events/" || request.url?.path == "/events" { return Self.response(request, body: index) }
            if request.url?.path == "/events/old-live/" || request.url?.path == "/events/old-live" { return Self.response(request, body: oldDetail) }
            if request.url?.path == "/events/new-live/" || request.url?.path == "/events/new-live" { return Self.response(request, body: newDetail) }
            throw URLError(.badURL)
        }
        let scraper = OfficialEventScraper(session: session(), indexURLs: [URL(string: "https://bang-dream.com/events/")!])

        let bundles = try await scraper.collect(existing: [], window: OfficialDateWindow(start: "2023-12-01", end: "2024-01-31"), now: Self.date("2026-09-22T12:00:00Z"))

        XCTAssertEqual(bundles.map(\.event.officialTitle), ["Old LIVE"])
        XCTAssertTrue(requestedPaths.contains("/events/old-live/") || requestedPaths.contains("/events/old-live"))
        XCTAssertFalse(requestedPaths.contains("/events/new-live/") || requestedPaths.contains("/events/new-live"))
    }

    func testRangedCollectionSkipsCachedEventsOutsideTheWindowAndKeepsTourSpansThatStraddleIt() async throws {
        let index = """
        <html><section class="p-live-event-list">
          <article class="p-live-event-list__item"><a class="p-live-event-list__item-link" href="/events/new-live/">
            <div class="p-live-event-list__item-title">New LIVE</div>
            <div class="p-live-event-list__item-category">ライブ</div>
            <div><h2 class="p-live-event-list__item-date">開催日</h2><p>2027年1月9日(土)</p></div>
          </a></article>
          <article class="p-live-event-list__item"><a class="p-live-event-list__item-link" href="/events/tour/">
            <div class="p-live-event-list__item-title">Old TOUR</div>
            <div class="p-live-event-list__item-category">ライブ</div>
            <div><h2 class="p-live-event-list__item-date">開催日</h2><p>2024年1月10日(水)～3月20日(水)</p></div>
          </a></article>
        </section></html>
        """
        let tourDetail = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">Old TOUR</h1>
          <div class="p-live-event-detail__content">
            <h2>日程</h2><p>2024年1月10日(水) 開演17:00</p><p>2024年2月14日(水) 開演17:00</p><p>2024年3月20日(水) 開演17:00</p>
            <h2>会場</h2><p>東京・Test Hall</p>
            <h2>出演</h2><p>Roselia</p>
          </div>
        </article>
        """
        var requestedPaths: [String] = []
        ScraperURLProtocol.handler = { request in
            requestedPaths.append(request.url!.path)
            if request.url?.path == "/events/" || request.url?.path == "/events" { return Self.response(request, body: index) }
            if request.url?.path == "/events/tour/" || request.url?.path == "/events/tour" { return Self.response(request, body: tourDetail) }
            throw URLError(.badURL)
        }
        let cachedNew = LiveEventBundle(
            schemaVersion: 1, publishedAt: .distantPast,
            event: LiveEvent(id: "new-live", franchise: .bangdream, officialTitle: "New LIVE", groups: [], eventType: .live, status: .scheduled, primarySourceURL: "https://bang-dream.com/events/new-live/", timeZone: "Asia/Tokyo"),
            stops: [], performances: [Performance(id: "new-live-0", eventID: "new-live", stopID: nil, dayLabel: "Day 1", subtitle: nil, localDate: "2027-01-09", doorsAt: nil, startAt: nil, venueName: "", venueCity: "", performers: [], order: 0)],
            ticketTiers: [], ticketRounds: [], ticketOffers: [], goodsCampaigns: [], mediaAssets: [], notices: [], evidence: []
        )
        let scraper = OfficialEventScraper(session: session(), indexURLs: [URL(string: "https://bang-dream.com/events/")!])

        let bundles = try await scraper.collect(existing: [cachedNew], window: OfficialDateWindow(start: "2024-02-01", end: "2024-02-29"), now: Self.date("2026-09-22T12:00:00Z"))

        XCTAssertEqual(bundles.map(\.event.officialTitle), ["Old TOUR"])
        XCTAssertEqual(bundles.first?.performances.compactMap(\.localDate), ["2024-01-10", "2024-02-14", "2024-03-20"])
        XCTAssertFalse(requestedPaths.contains("/events/new-live/") || requestedPaths.contains("/events/new-live"))
    }

    func testRangedCollectionRejectsInvertedWindow() async throws {
        let scraper = OfficialEventScraper(session: session(), indexURLs: [URL(string: "https://bang-dream.com/events/")!])
        do {
            _ = try await scraper.collect(existing: [], window: OfficialDateWindow(start: "2024-02-01", end: "2024-01-01"), now: Self.date("2026-09-22T12:00:00Z"))
            XCTFail("Expected invalidCutoff")
        } catch OfficialEventScraperError.invalidCutoff { } catch { XCTFail("Unexpected error \(error)") }
    }

    func testDailyCollectionUsesBangDreamListThumbnailAsEventCover() async throws {
        let index = """
        <article class="p-live-event-list__item"><a href="/events/card-cover/">
          <div class="p-live-event-list__item-thumb"><img src="/images/list-cover-768x401.png" alt="Card Cover LIVE"></div>
          <div class="p-live-event-list__item-title">Card Cover LIVE</div>
          <div class="p-live-event-list__item-category">ライブ</div>
          <h2 class="p-live-event-list__item-date">開催日</h2><p>2027年1月9日(土)</p>
        </a></article>
        """
        let detail = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">Card Cover LIVE</h1>
          <div class="p-live-event-detail__eyecatch"><img src="/images/detail-poster.png"></div>
          <div class="p-live-event-detail__content"><h2>日程</h2><p>2027年1月9日(土)</p></div>
        </article>
        """
        ScraperURLProtocol.handler = { request in
            switch request.url?.path {
            case "/events/", "/events": return Self.response(request, body: index)
            case "/events/card-cover/", "/events/card-cover": return Self.response(request, body: detail)
            default: throw URLError(.badURL)
            }
        }

        let bundles = try await OfficialEventScraper(
            session: session(), indexURLs: [URL(string: "https://bang-dream.com/events/")!]
        ).collect(existing: [], cutoff: "2026-01-01", now: Self.date("2026-09-22T12:00:00Z"))

        let assets = try XCTUnwrap(bundles.first?.mediaAssets)
        let eventCover = try XCTUnwrap(assets.first { $0.kind == .eventCover })
        XCTAssertEqual(eventCover.originalURL, "https://bang-dream.com/images/list-cover-768x401.png")
        XCTAssertEqual(eventCover.sourceURL, "https://bang-dream.com/events/")
        XCTAssertEqual(
            assets.first { $0.kind == .keyVisual }?.originalURL,
            "https://bang-dream.com/images/detail-poster.png"
        )
        XCTAssertFalse(assets.contains { $0.kind == .eventCover && $0.originalURL.contains("detail-poster") })
    }

    func testManualRefreshPreservesCachedEventCoverWithoutAnIndexCard() async throws {
        let eventCover = MediaAsset(
            id: "goods-event-event-cover", eventID: "goods-event", kind: .eventCover,
            originalURL: "https://bang-dream.com/images/list-cover.png", thumbnailURL: nil,
            scope: .unconfirmed, sourceURL: "https://bang-dream.com/events/", version: 3,
            caption: "公演一覧サムネイル", displayPolicy: .remoteDisplay, contentKind: .image
        )
        let detail = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">Goods Event</h1>
          <div class="p-live-event-detail__content"><h2>日程</h2><p>2027年1月9日(土)</p></div>
        </article>
        """
        ScraperURLProtocol.handler = { request in Self.response(request, body: detail) }

        let refreshed = try await OfficialEventScraper(session: session(), indexURLs: []).collect(
            event: Self.cachedBangDreamBundle(mediaAssets: [eventCover]), now: Self.date("2026-09-22T12:00:00Z")
        )

        XCTAssertEqual(refreshed.mediaAssets.filter { $0.kind == .eventCover }, [eventCover])
    }

    func testManualLoveLiveRefreshBypassesCutoffAndPreservesStableCachedRecords() async throws {
        let detail = """
        <html><head><meta property="og:description" content="Updated LoveLive! Event｜ラブライブ！"></head>
        <main><article>
          <div data-target="top"><h3>日程・会場</h3><p>■日程<br>2024年2月3日(土) 16:00開場／17:00開演<br>■会場<br>東京・日本武道館</p></div>
          <div data-target="ticket"><h3>お知らせ</h3><p>詳細は後日発表します。</p></div>
        </article></main></html>
        """
        ScraperURLProtocol.handler = { request in Self.response(request, body: detail) }
        let existing = Self.cachedLoveLiveBundle()
        let scraper = OfficialEventScraper(session: session(), indexURLs: [])

        let refreshed = try await scraper.collect(event: existing, now: Self.date("2026-09-22T12:00:00Z"))

        XCTAssertEqual(refreshed.event.id, "existing-event")
        XCTAssertEqual(refreshed.event.officialTitle, "Updated LoveLive! Event")
        XCTAssertEqual(refreshed.performances.first?.id, "existing-performance")
        XCTAssertEqual(refreshed.performances.first?.localDate, "2024-02-03")
        XCTAssertEqual(refreshed.performances.first?.venueName, "東京・日本武道館")
        XCTAssertEqual(refreshed.ticketTiers.map(\.id), ["existing-tier"])
    }

    func testLoveLiveRefreshSendsCompatibleUserAgentAndPreservesEventQuery() async throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("server/tests/fixtures/snapshots/lovelive_detail_15th_lovelivefest.html")
        let html = try String(contentsOf: fixture, encoding: .utf8)
        ScraperURLProtocol.handler = { request in
            let agent = request.value(forHTTPHeaderField: "User-Agent") ?? ""
            XCTAssertTrue(agent.contains("Mobile/"))
            XCTAssertTrue(agent.contains("Safari/"))
            XCTAssertTrue(agent.contains("LiveDashboard/"))
            XCTAssertEqual(request.url?.query, "p=15th_lovelivefest")
            // Reproduce the official site's response to the old app-only agent.
            guard agent.contains("Safari/") else {
                return (HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!, Data("NOT FOUND".utf8))
            }
            return Self.response(request, body: html)
        }
        let bundle = try await OfficialEventScraper(session: session(), indexURLs: [])
            .collect(event: Self.cachedLoveLiveFixtureBundle(), now: Self.date("2026-09-22T12:00:00Z"))
        XCTAssertFalse(bundle.performances.isEmpty)
        XCTAssertFalse(bundle.mediaAssets.isEmpty)
    }

    func testLoveLiveRealForbiddenResponseStillFails() async throws {
        ScraperURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!, Data("NOT FOUND".utf8))
        }
        do {
            _ = try await OfficialEventScraper(session: session(), indexURLs: [])
                .collect(event: Self.cachedLoveLiveFixtureBundle(), now: Date())
            XCTFail("A real HTTP failure must not be treated as event data")
        } catch let failure as OfficialScrapeFailure {
            XCTAssertEqual(failure.kind, .invalidResponse)
            XCTAssertEqual(failure.message, "HTTP 403")
        }
    }

    func testGoodsImagesResolveLazyRelativeAndDirectSourcesWhileWebLinksRemainLinks() async throws {
        let detail = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">Goods Event</h1>
          <div class="p-live-event-detail__content">
            <h2>グッズ通販</h2>
            <p><a href="https://store.example.test/event-goods"><img src="/images/placeholder.gif" data-src="/images/goods-list.jpg" alt="商品一覧"></a></p>
            <h2>グッズ販売</h2>
            <p><a href="/images/venue-original.png"><img srcset="/images/venue-small.webp 320w, /images/venue-large.webp 1200w" alt="会場物販"></a></p>
            <h2>グッズ通販案内</h2>
            <p><a href="https://store.example.test/information">公式ストアのお知らせ</a></p>
            <h2>事前通販</h2>
            <p><a href="/images/order-sheet.jpg">商品画像を開く</a></p>
          </div>
        </article>
        """
        ScraperURLProtocol.handler = { request in Self.response(request, body: detail) }
        let existing = Self.cachedBangDreamBundle()
        let scraper = OfficialEventScraper(session: session(), indexURLs: [])

        let refreshed = try await scraper.collect(event: existing, now: Self.date("2026-09-22T12:00:00Z"))

        let online = try XCTUnwrap(refreshed.goodsCampaigns.first { $0.officialName == "グッズ通販" })
        XCTAssertEqual(online.url, "https://store.example.test/event-goods")
        XCTAssertEqual(online.mediaAssetIDs.count, 1)
        let onlineImage = try XCTUnwrap(refreshed.mediaAssets.first { $0.id == online.mediaAssetIDs.first })
        XCTAssertEqual(onlineImage.originalURL, "https://bang-dream.com/images/goods-list.jpg")
        XCTAssertEqual(onlineImage.contentKind, .image)
        XCTAssertEqual(onlineImage.displayPolicy, .remoteDisplay)

        let venue = try XCTUnwrap(refreshed.goodsCampaigns.first { $0.officialName == "グッズ販売" })
        XCTAssertNil(venue.url, "A direct image href is media, not a store webpage")
        let venueImage = try XCTUnwrap(refreshed.mediaAssets.first { $0.id == venue.mediaAssetIDs.first })
        XCTAssertEqual(venueImage.originalURL, "https://bang-dream.com/images/venue-original.png")
        XCTAssertEqual(venueImage.thumbnailURL, "https://bang-dream.com/images/venue-large.webp")

        let linkOnly = try XCTUnwrap(refreshed.goodsCampaigns.first { $0.officialName == "グッズ通販案内" })
        XCTAssertEqual(linkOnly.url, "https://store.example.test/information")
        XCTAssertTrue(linkOnly.mediaAssetIDs.isEmpty)
        XCTAssertFalse(refreshed.mediaAssets.contains { $0.originalURL == linkOnly.url })

        let directImage = try XCTUnwrap(refreshed.goodsCampaigns.first { $0.officialName == "事前通販" })
        XCTAssertNil(directImage.url)
        XCTAssertEqual(directImage.mediaAssetIDs.count, 1)
        XCTAssertEqual(
            refreshed.mediaAssets.first { $0.id == directImage.mediaAssetIDs.first }?.originalURL,
            "https://bang-dream.com/images/order-sheet.jpg"
        )
    }

    func testOfficialLoveLiveFixtureAttachesGoodsGalleryToCampaign() async throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("server/tests/fixtures/snapshots/lovelive_detail_15th_lovelivefest.html")
        let html = try String(contentsOf: fixture, encoding: .utf8)
        ScraperURLProtocol.handler = { request in Self.response(request, body: html) }
        let existing = Self.cachedLoveLiveFixtureBundle()

        let refreshed = try await OfficialEventScraper(session: session(), indexURLs: [])
            .collect(event: existing, now: Self.date("2026-09-22T12:00:00Z"))

        let campaign = try XCTUnwrap(refreshed.goodsCampaigns.first { $0.officialName == "グッズ" })
        XCTAssertEqual(campaign.url, "https://lovelive.fannect.jp/pages/lovelive-series-15th-anniversary")
        XCTAssertGreaterThan(campaign.mediaAssetIDs.count, 10)
        let associated = refreshed.mediaAssets.filter { campaign.mediaAssetIDs.contains($0.id) }
        XCTAssertEqual(associated.count, campaign.mediaAssetIDs.count)
        XCTAssertTrue(associated.allSatisfy { $0.contentKind == .image && $0.displayPolicy == .remoteDisplay })
        XCTAssertTrue(associated.contains { $0.originalURL.contains("image.php?img_path=") })
    }

    func testOfficialBangDreamFixtureExcludesFooterStoreLogos() async throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("server/tests/fixtures/snapshots/bangdream_13th_live_day1.html")
        let html = try String(contentsOf: fixture, encoding: .utf8)
        ScraperURLProtocol.handler = { request in Self.response(request, body: html) }

        let refreshed = try await OfficialEventScraper(session: session(), indexURLs: [])
            .collect(event: Self.cachedBangDreamBundle(), now: Self.date("2026-09-22T12:00:00Z"))

        XCTAssertEqual(refreshed.goodsCampaigns.map(\.officialName), ["グッズ通販"])
        let campaign = try XCTUnwrap(refreshed.goodsCampaigns.first)
        XCTAssertEqual(campaign.mediaAssetIDs.count, 1)
        let image = try XCTUnwrap(refreshed.mediaAssets.first { $0.id == campaign.mediaAssetIDs.first })
        XCTAssertTrue(image.originalURL.contains("67144cdd-c1157a53-0c15dd0a-de6af61e.jpg"))
        XCTAssertFalse(refreshed.mediaAssets.contains { $0.originalURL.contains("logo_bushiroad") || $0.originalURL.contains("bnr_x") })
    }

    func testTicketRoundGoodsCampaignAndSourceTextCaptureOfficialLinks() async throws {
        let detail = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">Link Event</h1>
          <div class="p-live-event-detail__content">
            <h2>日程</h2><p>2027年1月9日(土) 開場16:00／開演17:00</p>
            <h2>会場</h2><p>東京・Test Hall</p>
            <h2>出演</h2><p>Roselia</p>
            <h2>チケット</h2><h3>料金</h3><p>一般指定席：9,900円(税込)</p>
            <h6>一般発売</h6><p>受付期間：2026年12月1日(火) 12:00～2026年12月20日(日) 23:59 先着<br>
            <a href="https://eplus.jp/xxx">イープラス</a>　<a href="https://l-tike.com/yyy">ローソンチケット</a>　<a href="https://example.com/album">アルバム封入</a></p>
            <h2>グッズ通販</h2>
            <p><a href="/store/goods">通販サイトはこちら</a></p>
            <p><img src="/g.jpg"></p>
          </div>
        </article>
        """
        ScraperURLProtocol.handler = { request in Self.response(request, body: detail) }
        let existing = Self.cachedBangDreamBundle()
        let scraper = OfficialEventScraper(session: session(), indexURLs: [])

        let refreshed = try await scraper.collect(event: existing, now: Self.date("2026-09-22T12:00:00Z"))

        let round = try XCTUnwrap(refreshed.ticketRounds.first { $0.officialName == "一般発売" })
        XCTAssertEqual(round.links.count, 3)
        XCTAssertEqual(round.links.map(\.label), ["イープラス", "ローソンチケット", "アルバム封入"])
        XCTAssertEqual(round.links.map(\.url), [
            "https://eplus.jp/xxx", "https://l-tike.com/yyy", "https://example.com/album",
        ])
        XCTAssertEqual(round.applyURL, "https://eplus.jp/xxx")
        XCTAssertEqual(round.links.last?.role, .other)

        let campaign = try XCTUnwrap(refreshed.goodsCampaigns.first { $0.officialName == "グッズ通販" })
        XCTAssertEqual(campaign.links, [OfficialLink(label: "通販サイトはこちら", url: "https://bang-dream.com/store/goods")])
        XCTAssertEqual(campaign.url, "https://bang-dream.com/store/goods")

        let sourceText = try XCTUnwrap(refreshed.sourceText)
        XCTAssertTrue(sourceText.hasPrefix("# Link Event"))
        XCTAssertTrue(sourceText.contains("通販サイトはこちら（https://bang-dream.com/store/goods）"))
    }

    func testLinksDeduplicateAndSkipJavascriptAndFragmentHrefs() async throws {
        let detail = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">Link Skip Event</h1>
          <div class="p-live-event-detail__content">
            <h2>チケット</h2>
            <h6>一般発売</h6><p>受付期間：2026年12月1日(火) 12:00～2026年12月20日(日) 23:59 先着<br>
            <a href="https://eplus.jp/dup">イープラス</a>　<a href="https://eplus.jp/dup">重复</a>
            <a href="javascript:void(0)">無効</a> <a href="#top">トップへ</a></p>
          </div>
        </article>
        """
        ScraperURLProtocol.handler = { request in Self.response(request, body: detail) }
        let existing = Self.cachedBangDreamBundle()
        let scraper = OfficialEventScraper(session: session(), indexURLs: [])

        let refreshed = try await scraper.collect(event: existing, now: Self.date("2026-09-22T12:00:00Z"))

        let round = try XCTUnwrap(refreshed.ticketRounds.first { $0.officialName == "一般発売" })
        XCTAssertEqual(round.links, [OfficialLink(label: "イープラス", url: "https://eplus.jp/dup", role: .application)])
    }

    func testTicketRoundAndBundleCodableCompatibilityWithLinksAndSourceText() throws {
        let round = TicketRound(
            id: "r1", eventID: "e1", officialName: "一般発売", kind: .firstComeFirstServed, scope: .unconfirmed,
            applyStartAt: nil, applyEndAt: nil, resultAt: nil, paymentDeadlineAt: nil, eligibility: nil,
            announcementURL: nil, applyURL: nil, overseasURL: nil, officialStatus: nil, status: .confirmed,
            links: [OfficialLink(label: "イープラス", url: "https://eplus.jp/xxx")]
        )
        let encodedRound = try LiveEventBundle.encoder.encode(round)
        let decodedRound = try LiveEventBundle.decoder.decode(TicketRound.self, from: encodedRound)
        XCTAssertEqual(decodedRound, round)

        let legacyRoundJSON = """
        {"id":"r2","eventID":"e1","officialName":"抽選","kind":"lottery","scope":{"kind":"unconfirmed"},"status":"confirmed"}
        """
        let legacyRound = try LiveEventBundle.decoder.decode(TicketRound.self, from: Data(legacyRoundJSON.utf8))
        XCTAssertEqual(legacyRound.links, [])

        let event = LiveEvent(
            id: "e1", franchise: .bangdream, officialTitle: "Title", groups: [], eventType: .live,
            status: .scheduled, primarySourceURL: "https://bang-dream.com/events/x/", timeZone: "Asia/Tokyo"
        )
        let bundle = LiveEventBundle(
            schemaVersion: 1, publishedAt: Self.date("2026-09-22T12:00:00Z"), event: event, stops: [], performances: [],
            ticketTiers: [], ticketRounds: [round], ticketOffers: [], goodsCampaigns: [], mediaAssets: [],
            notices: [], evidence: [], sourceText: "# Title\n本文"
        )
        let encodedBundle = try LiveEventBundle.encoder.encode(bundle)
        let decodedBundle = try LiveEventBundle.decoder.decode(LiveEventBundle.self, from: encodedBundle)
        XCTAssertEqual(decodedBundle, bundle)

        var legacyBundleObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encodedBundle) as? [String: Any])
        legacyBundleObject.removeValue(forKey: "sourceText")
        let legacyBundleData = try JSONSerialization.data(withJSONObject: legacyBundleObject)
        let legacyBundle = try LiveEventBundle.decoder.decode(LiveEventBundle.self, from: legacyBundleData)
        XCTAssertNil(legacyBundle.sourceText)
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScraperURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func response(_ request: URLRequest, body: String) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html; charset=utf-8"])!, Data(body.utf8))
    }

    private static func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private static func cachedLoveLiveBundle() -> LiveEventBundle {
        let event = LiveEvent(
            id: "existing-event", franchise: .lovelive, officialTitle: "Old title",
            groups: ["Aqours"], eventType: .live, status: .finished,
            primarySourceURL: "https://www.lovelive-anime.jp/special/live/live_detail.php?p=old",
            timeZone: "Asia/Tokyo"
        )
        let performance = Performance(
            id: "existing-performance", eventID: event.id, stopID: nil, dayLabel: "公演",
            subtitle: nil, localDate: "2024-02-03", doorsAt: nil, startAt: nil,
            venueName: "Old venue", venueCity: "", performers: [], order: 0
        )
        let tier = TicketTier(
            id: "existing-tier", eventID: event.id, name: "一般", priceJPY: 9_900,
            priceKind: .full, includes: nil, feeNote: nil, taxNote: "税込"
        )
        return LiveEventBundle(
            schemaVersion: 1, publishedAt: .distantPast, event: event, stops: [],
            performances: [performance], ticketTiers: [tier], ticketRounds: [],
            ticketOffers: [], goodsCampaigns: [], mediaAssets: [], notices: [], evidence: []
        )
    }

    private static func cachedBangDreamBundle(mediaAssets: [MediaAsset] = []) -> LiveEventBundle {
        let event = LiveEvent(
            id: "goods-event", franchise: .bangdream, officialTitle: "Goods Event",
            groups: [], eventType: .live, status: .scheduled,
            primarySourceURL: "https://bang-dream.com/events/goods-event/", timeZone: "Asia/Tokyo"
        )
        return LiveEventBundle(
            schemaVersion: 1, publishedAt: .distantPast, event: event, stops: [],
            performances: [], ticketTiers: [], ticketRounds: [], ticketOffers: [],
            goodsCampaigns: [], mediaAssets: mediaAssets, notices: [], evidence: []
        )
    }

    private static func cachedLoveLiveFixtureBundle() -> LiveEventBundle {
        let event = LiveEvent(
            id: "love-live-fixture", franchise: .lovelive, officialTitle: "Fixture",
            groups: [], eventType: .live, status: .scheduled,
            primarySourceURL: "https://www.lovelive-anime.jp/special/live/live_detail.php?p=15th_lovelivefest",
            timeZone: "Asia/Tokyo"
        )
        return LiveEventBundle(
            schemaVersion: 1, publishedAt: .distantPast, event: event, stops: [],
            performances: [], ticketTiers: [], ticketRounds: [], ticketOffers: [],
            goodsCampaigns: [], mediaAssets: [], notices: [], evidence: []
        )
    }
}

private final class ScraperURLProtocol: URLProtocol, @unchecked Sendable {
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
