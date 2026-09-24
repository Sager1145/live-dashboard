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

    func testFujimiyakoExhibitionSeparatesVenuesPeriodsAndGoods() async throws {
        let fixture = "/Users/sager/Documents/GitHub/live-dashboard/docs/audits/2026-09-22/bangdream/html/27529-fujimiyako_exhibition.html"
        let detail = try String(contentsOfFile: fixture, encoding: .utf8)
        let index = """
        <html><section class="p-live-event-list">
          <article class="p-live-event-list__item"><a class="p-live-event-list__item-link" href="/events/fujimiyako_exhibition/">
            <div class="p-live-event-list__item-title">藤都子展～16歳～</div>
            <div class="p-live-event-list__item-category">イベント</div>
            <div><h2 class="p-live-event-list__item-date">開催日</h2><p>2026年9月19日(土)～10月4日(日)</p>
            <h2 class="p-live-event-list__item-place">場所</h2><p>AKIHABARA</p></div>
          </a></article>
        </section></html>
        """
        ScraperURLProtocol.handler = { request in
            if request.url?.path == "/events/" || request.url?.path == "/events" { return Self.response(request, body: index) }
            if request.url?.path.contains("fujimiyako") == true { return Self.response(request, body: detail) }
            throw URLError(.badURL)
        }
        let scraper = OfficialEventScraper(session: session(), indexURLs: [URL(string: "https://bang-dream.com/events/")!])
        let collected = try await scraper.collect(existing: [], cutoff: "2026-01-01", now: Self.date("2026-09-22T12:00:00Z"))
        let bundle = try XCTUnwrap(collected.first)

        func covering(_ day: String) -> [Performance] { bundle.performances.filter { $0.covers(localDate: day) } }

        let september20 = covering("2026-09-20")
        XCTAssertEqual(september20.count, 2)
        XCTAssertTrue(september20.allSatisfy { $0.activityKind == .exhibition && $0.startAt == nil })
        XCTAssertTrue(september20.contains { $0.venueName.contains("4階") })
        XCTAssertTrue(september20.contains { $0.venueName.contains("池袋") })
        XCTAssertFalse(september20.contains { $0.venueName.contains("6階") })

        let september19 = covering("2026-09-19")
        XCTAssertEqual(september19.filter { $0.activityKind == .exhibition }.count, 1)
        let handover19 = try XCTUnwrap(september19.first { $0.activityKind == .handover })
        XCTAssertNotNil(handover19.startAt)
        XCTAssertNil(september19.first { $0.activityKind == .exhibition }?.startAt)
        XCTAssertTrue(handover19.venueName.contains("6階"))

        let september27 = covering("2026-09-27")
        let ikebukuro = september27.filter { $0.venueName.contains("池袋") }
        XCTAssertEqual(ikebukuro.compactMap(\.activityKind).sorted { $0.rawValue < $1.rawValue }, [.exhibition, .handover])
        XCTAssertNil(ikebukuro.first { $0.activityKind == .exhibition }?.startAt)
        XCTAssertNotNil(ikebukuro.first { $0.activityKind == .handover }?.startAt)
        XCTAssertTrue(september27.contains { $0.activityKind == .exhibition && $0.venueName.contains("4階") })

        for day in ["2026-10-03", "2026-10-04"] {
            let shows = covering(day)
            XCTAssertEqual(shows.map(\.venueName), covering(day).map(\.venueName))
            XCTAssertEqual(shows.count, 1)
            XCTAssertTrue(shows[0].venueName.contains("4階"))
            XCTAssertFalse(shows[0].venueName.contains("池袋"))
        }
        XCTAssertTrue(covering("2026-10-05").isEmpty)
        XCTAssertFalse(bundle.performances.contains { $0.dayLabel.hasPrefix("Day") })
        XCTAssertFalse(bundle.performances.contains { $0.venueName.contains("、") })

        XCTAssertEqual(bundle.products.count, 8)
        let badge = try XCTUnwrap(bundle.products.first { $0.name.contains("缶バッジ") })
        XCTAssertEqual(badge.variants.first { $0.name == "PACK" }?.amount?.minorUnits, 550)
        XCTAssertEqual(badge.variants.first { $0.name == "BOX" }?.amount?.minorUnits, 5_500)
        XCTAssertFalse(bundle.ticketTiers.contains { ($0.priceJPY ?? 0) == 5_500 || $0.amount?.minorUnits == 5_500 })
        XCTAssertTrue(bundle.notices.contains { $0.title == "参加资格" && ($0.body.contains("5500") || $0.body.contains("5,500")) })
        XCTAssertTrue(bundle.notices.contains { $0.title == "先着購入特典" })
        let catalog = try XCTUnwrap(bundle.goodsCampaigns.first { $0.officialName.contains("グッズ") })
        XCTAssertNotEqual(catalog.channel, .online)
        XCTAssertNil(catalog.shippingNote)
        XCTAssertEqual(bundle.goodsSessions.count, 2)
        let handoverIDs = Set(bundle.performances.filter { $0.activityKind == .handover }.map(\.id))
        for session in bundle.goodsSessions {
            guard case .performances(let ids) = session.scope else {
                XCTFail("distribution window was not tied to one handover")
                continue
            }
            XCTAssertEqual(ids.count, 1)
            XCTAssertTrue(handoverIDs.contains(ids[0]))
        }

        let users = await MainActor.run { UserDataStore(container: UserDataStore.makeContainer(inMemory: true)) }
        await MainActor.run {
            users.setFollowed(true, eventID: bundle.event.id)
            users.setParticipation(eventID: bundle.event.id, performanceID: "stale-day-2", participate: true, knownPerformanceIDs: ["stale-day-2"])
            let store = LiveDetailStore(bundle: bundle, userDataStore: users)
            XCTAssertTrue(users.state(for: bundle.event.id).isFollowed)
            XCTAssertFalse(users.state(for: bundle.event.id).participatingPerformanceIDs.contains("stale-day-2"))
            store.selectLocalDate("2026-09-20")
            XCTAssertEqual(store.performancesOnSelectedDate.count, 2)
            XCTAssertEqual(store.selectedPerformanceID, "")
            store.selectLocalDate("2026-10-05")
            XCTAssertEqual(store.selectedPerformanceID, "")
            XCTAssertTrue(store.performancesOnSelectedDate.isEmpty)
        }
    }

    func testDateVenuePairingIgnoresCachedHallsAndKeepsASingleSharedHall() async throws {
        let split = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">Split Halls</h1>
          <div class="p-live-event-detail__content">
            <h2>日程・会場</h2>
            <p>2027年1月30日(土) 開演18:00<br>■会場：第一ホール<br>
            2027年2月28日(日) 開演18:00<br>■会場：第二ホール</p>
          </div>
        </article>
        """
        let cachedSplit = Self.bundle(url: "https://bang-dream.com/events/split-halls/", title: "Split Halls", venue: "缓存会场", rounds: 1, goods: 1)
        let splitResult = try await refresh(html: split, bundle: cachedSplit)
        XCTAssertEqual(splitResult.performances.map(\.localDate), ["2027-01-30", "2027-02-28"])
        XCTAssertEqual(splitResult.performances.map(\.venueName), ["第一ホール", "第二ホール"])
        XCTAssertFalse(splitResult.performances.contains { $0.venueName.contains("缓存") })

        let leading = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">Leading Halls</h1>
          <div class="p-live-event-detail__content">
            <h2>日程・会場</h2>
            <p>■会場：第一ホール<br>2027年1月30日(土) 開演18:00<br>
            ■会場：第二ホール<br>2027年2月28日(日) 開演18:00</p>
          </div>
        </article>
        """
        let leadingResult = try await refresh(html: leading, bundle: Self.bundle(url: "https://bang-dream.com/events/leading-halls/", title: "Leading Halls", venue: "上一个馆"))
        XCTAssertEqual(leadingResult.performances.map(\.venueName), ["第一ホール", "第二ホール"])

        let shared = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">Shared Hall</h1>
          <div class="p-live-event-detail__content">
            <h2>日程・会場</h2>
            <p>2027年1月30日(土) 開演18:00<br>2027年2月28日(日) 開演18:00<br>■会場：共用ホール</p>
          </div>
        </article>
        """
        let sharedResult = try await refresh(html: shared, bundle: Self.bundle(url: "https://bang-dream.com/events/shared-hall/", title: "Shared Hall", venue: "另一馆"))
        XCTAssertEqual(sharedResult.performances.map(\.venueName), ["共用ホール", "共用ホール"])
    }

    func testScopedVenueMissDoesNotBlockTheSharedHall() async throws {
        let html = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">City Miss</h1>
          <div class="p-live-event-detail__table"><table>
            <tr><th>概要</th><td>12月1日(火)・2日(水)名古屋公演</td></tr>
          </table></div>
          <div class="p-live-event-detail__content">
            <h2>日程</h2><p>2026年12月1日(火)・2日(水)</p>
            <h2>会場</h2><p>SGC HALL ARIAKE（東京公演）<br>Zepp Osaka Bayside（大阪公演）</p>
          </div>
        </article>
        """
        let refreshed = try await refresh(html: html, bundle: Self.bundle(url: "https://bang-dream.com/events/city-miss/", title: "City Miss", venue: ""))
        XCTAssertEqual(refreshed.performances.count, 2)
        XCTAssertTrue(refreshed.performances.allSatisfy { !$0.venueName.isEmpty })
        XCTAssertEqual(refreshed.performances.map(\.venueName), [refreshed.performances[0].venueName, refreshed.performances[0].venueName])
    }

    func testSuccessfulParseDropsCachedRoundsAndGoods() async throws {
        let html = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">Bare Page</h1>
          <div class="p-live-event-detail__content">
            <h2>日程</h2><p>2027年3月1日(月) 開演18:00</p>
            <h2>会場</h2><p>Zepp Shinjuku</p>
          </div>
        </article>
        """
        let refreshed = try await refresh(html: html, bundle: Self.bundle(url: "https://bang-dream.com/events/bare/", title: "Bare Page", venue: "旧馆", rounds: 1, goods: 1))
        XCTAssertTrue(refreshed.ticketRounds.isEmpty)
        XCTAssertTrue(refreshed.goodsCampaigns.isEmpty)
        XCTAssertEqual(refreshed.sourceHealth, .healthy)
        XCTAssertEqual(refreshed.performances.first?.venueName, "Zepp Shinjuku")
    }

    func testFailedDetailFetchKeepsThePreviousBundle() async throws {
        let cached = Self.bundle(url: "https://bang-dream.com/events/offline/", title: "Offline", venue: "上次会场", rounds: 1, goods: 1)
        ScraperURLProtocol.handler = { _ in throw URLError(.networkConnectionLost) }
        let scraper = OfficialEventScraper(session: session(), indexURLs: [])
        do {
            _ = try await scraper.collect(existing: [cached], cutoff: "2020-01-01", now: Self.date("2026-09-22T12:00:00Z"))
            XCTFail("expected partial failure")
        } catch let OfficialEventScraperError.partialFailure(bundles, _) {
            XCTAssertEqual(bundles.first?.performances.first?.venueName, "上次会场")
            XCTAssertEqual(bundles.first?.ticketRounds.map(\.id), cached.ticketRounds.map(\.id))
            XCTAssertEqual(bundles.first?.goodsCampaigns.map(\.id), cached.goodsCampaigns.map(\.id))
        }
        ScraperURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, Data())
        }
        do {
            _ = try await scraper.collect(existing: [cached], cutoff: "2020-01-01", now: Self.date("2026-09-22T12:00:00Z"))
            XCTFail("expected partial failure")
        } catch let OfficialEventScraperError.partialFailure(bundles, _) {
            XCTAssertEqual(bundles.first?.performances.first?.venueName, "上次会场")
            XCTAssertEqual(bundles.first?.ticketRounds.map(\.officialName), ["缓存票轮"])
        }
    }

    func testGoodsAndTicketScopeFollowTheRecordText() async throws {
        let allShows = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">All Goods</h1>
          <div class="p-live-event-detail__content">
            <h2>日程・会場</h2>
            <h6>DAY1</h6><p>日程：2026年8月1日(土)<br>会場：Kアリーナ横浜</p>
            <h6>DAY2</h6><p>日程：2026年8月2日(日)<br>会場：Kアリーナ横浜</p>
            <h2>グッズ通販</h2><p>全公演で販売します。<br><a href="https://example.com/all-goods">通販</a></p>
          </div>
        </article>
        """
        let all = try await refresh(html: allShows, bundle: Self.bundle(url: "https://bang-dream.com/events/all-goods/", title: "All Goods"))
        let allCampaign = try XCTUnwrap(all.goodsCampaigns.first)
        XCTAssertEqual(allCampaign.scope, .performances(performanceIDs: all.performances.map(\.id)))

        let oneShow = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">One Goods</h1>
          <div class="p-live-event-detail__content">
            <h2>日程</h2><p>2026年8月1日(土) 開演18:00</p>
            <h2>会場</h2><p>Zepp Shinjuku</p>
            <h2>グッズ通販</h2><p><a href="https://example.com/one-goods">通販</a></p>
          </div>
        </article>
        """
        let one = try await refresh(html: oneShow, bundle: Self.bundle(url: "https://bang-dream.com/events/one-goods/", title: "One Goods"))
        let oneID = try XCTUnwrap(one.performances.first?.id)
        XCTAssertEqual(one.goodsCampaigns.first?.scope, .performances(performanceIDs: [oneID]))

        let unscoped = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">Unscoped Goods</h1>
          <div class="p-live-event-detail__content">
            <h2>日程・会場</h2>
            <h6>DAY1</h6><p>日程：2026年8月1日(土)<br>会場：Kアリーナ横浜</p>
            <h6>DAY2</h6><p>日程：2026年8月2日(日)<br>会場：Kアリーナ横浜</p>
            <h2>グッズ通販</h2><p>オンラインで受付します。<br><a href="https://example.com/unscope">通販</a></p>
            <h2>チケット</h2>
            <h6>一般発売</h6><p>受付期間：2026年6月6日(土) 12:00～</p>
            <h6>初日券</h6><p>対象：8月1日<br>受付期間：2026年6月1日(月) 12:00～</p>
          </div>
        </article>
        """
        let multi = try await refresh(html: unscoped, bundle: Self.bundle(url: "https://bang-dream.com/events/unscoped-goods/", title: "Unscoped Goods"))
        XCTAssertEqual(multi.goodsCampaigns.first?.scope, .unconfirmed)
        XCTAssertEqual(multi.ticketRounds.first { $0.officialName == "一般発売" }?.scope, .unconfirmed)
        let day1 = try XCTUnwrap(multi.performances.first { $0.localDate == "2026-08-01" })
        XCTAssertEqual(multi.ticketRounds.first { $0.officialName == "初日券" }?.scope, .performances(performanceIDs: [day1.id]))
    }

    func testPricedGoodsLineAndDistinctImageEndpoints() async throws {
        let html = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">Priced Goods</h1>
          <div class="p-live-event-detail__content">
            <h2>日程</h2><p>2027年3月1日(月) 開演18:00</p>
            <h2>会場</h2><p>Zepp Shinjuku</p>
            <h2>グッズ通販</h2>
            <p>T シャツ：3,500円<br>
            <img src="https://bang-dream.com/images/shirt.jpg">
            <img src="https://www.lovelive-anime.jp/common/api/image.php?img_path=a">
            <img src="https://www.lovelive-anime.jp/common/api/image.php?img_path=b">
            </p>
          </div>
        </article>
        """
        let refreshed = try await refresh(html: html, bundle: Self.bundle(url: "https://bang-dream.com/events/priced-goods/", title: "Priced Goods"))
        let product = try XCTUnwrap(refreshed.products.first { $0.name == "T シャツ" })
        XCTAssertEqual(product.amount, MoneyAmount(minorUnits: 3500, currency: "JPY"))
        let campaign = try XCTUnwrap(refreshed.goodsCampaigns.first)
        XCTAssertEqual(campaign.mediaAssetIDs.count, 3)
        let paths = refreshed.mediaAssets.map(\.originalURL)
        XCTAssertEqual(paths.filter { $0.contains("img_path=a") }.count, 1)
        XCTAssertEqual(paths.filter { $0.contains("img_path=b") }.count, 1)
    }

    func testNotedPerformersKeepThePrintedGroupName() async throws {
        let html = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">Guest</h1>
          <a class="p-news-detail__related-artist-link" href="/artists/yume">夢限大みゅーたいぷ</a>
          <div class="p-live-event-detail__content">
            <h2>日程</h2><p>2027年1月9日(土) 開演18:00<br>千石ユノ（夢限大みゅーたいぷ）ゲスト出演</p>
            <h2>会場</h2><p>Zepp Shinjuku</p>
          </div>
        </article>
        """
        let refreshed = try await refresh(html: html, bundle: Self.bundle(url: "https://bang-dream.com/events/guest/", title: "Guest"))
        XCTAssertEqual(refreshed.performances.first?.performers, ["夢限大みゅーたいぷ"])
        XCTAssertFalse(refreshed.performances.first?.performers.contains("千石ユノ（夢限大みゅーたいぷ）") ?? false)
    }

    func testSaleDateOnAShowDayDoesNotBindTheRound() async throws {
        let html = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">Sale Date</h1>
          <div class="p-live-event-detail__content">
            <h2>日程・会場</h2>
            <h6>DAY1</h6><p>日程：2026年8月1日(土)<br>会場：Kアリーナ横浜</p>
            <h6>DAY2</h6><p>日程：2026年8月2日(日)<br>会場：Kアリーナ横浜</p>
            <h2>チケット</h2>
            <h6>最速先行</h6><p>受付期間：2026年8月1日(土) 12:00～2026年8月2日(日) 23:59</p>
          </div>
        </article>
        """
        let refreshed = try await refresh(html: html, bundle: Self.bundle(url: "https://bang-dream.com/events/sale-date/", title: "Sale Date"))
        XCTAssertEqual(refreshed.ticketRounds.first { $0.officialName == "最速先行" }?.scope, .unconfirmed)
    }

    func testSameDayTwoHallsStayUnconfirmedUntilTheHallIsNamed() async throws {
        let html = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">Two Halls</h1>
          <div class="p-live-event-detail__content">
            <h2>日程・会場</h2>
            <h6>横浜</h6><p>日程：2026年8月1日(土)<br>会場：横浜アリーナ</p>
            <h6>神戸</h6><p>日程：2026年8月1日(土)<br>会場：神戸ワールド記念ホール</p>
            <h2>チケット</h2>
            <h6>日付のみ先行</h6><p>対象公演：2026年8月1日</p>
            <h6>横浜先行</h6><p>対象：2026年8月1日 横浜アリーナ</p>
            <h2>会場グッズ販売</h2><p>販売場所：横浜アリーナ<br><a href="https://example.com/goods-yokohama">販売</a></p>
            <h2>会場グッズ販売</h2><p>販売場所：神戸ワールド記念ホール<br><a href="https://example.com/goods-kobe">販売</a></p>
          </div>
        </article>
        """
        let refreshed = try await refresh(html: html, bundle: Self.bundle(url: "https://bang-dream.com/events/two-halls/", title: "Two Halls"))
        XCTAssertEqual(refreshed.performances.count, 2)
        XCTAssertEqual(refreshed.ticketRounds.first { $0.officialName == "日付のみ先行" }?.scope, .unconfirmed)
        let yokohama = try XCTUnwrap(refreshed.performances.first { $0.venueName.contains("横浜アリーナ") })
        XCTAssertEqual(
            refreshed.ticketRounds.first { $0.officialName == "横浜先行" }?.scope,
            .performances(performanceIDs: [yokohama.id])
        )
        let goods = refreshed.goodsCampaigns.filter { $0.officialName == "会場グッズ販売" }
        XCTAssertEqual(goods.count, 2)
        XCTAssertEqual(Set(goods.compactMap(\.location)), ["横浜アリーナ", "神戸ワールド記念ホール"])
    }

    func testPerformerLinesKeepCommasAndSplitNewlines() {
        XCTAssertEqual(PerformerLines.expandingNewlines(["A\nB\nC"]), ["A", "B", "C"])
        XCTAssertEqual(PerformerLines.expandingNewlines(["A、B", "C/D（role、guest）"]), ["A、B", "C/D（role、guest）"])
    }

    private func refresh(html: String, bundle: LiveEventBundle) async throws -> LiveEventBundle {
        ScraperURLProtocol.handler = { request in Self.response(request, body: html) }
        return try await OfficialEventScraper(session: session(), indexURLs: [])
            .collect(event: bundle, now: Self.date("2026-09-22T12:00:00Z"))
    }

    private static func bundle(url: String, title: String, venue: String = "", rounds: Int = 0, goods: Int = 0) -> LiveEventBundle {
        let event = LiveEvent(
            id: "fixture-event", franchise: .bangdream, officialTitle: title, groups: [],
            eventType: .live, status: .scheduled, primarySourceURL: url, timeZone: "Asia/Tokyo"
        )
        let performance = Performance(
            id: "fixture-performance", eventID: event.id, stopID: nil, dayLabel: "公演",
            subtitle: nil, localDate: "2027-03-01", doorsAt: nil, startAt: nil,
            venueName: venue, venueCity: "", performers: ["缓存出演"], order: 0
        )
        let round = TicketRound(
            id: "cached-round", eventID: event.id, officialName: "缓存票轮", kind: .firstComeFirstServed,
            scope: .unconfirmed, applyStartAt: nil, applyEndAt: nil, resultAt: nil, paymentDeadlineAt: nil,
            eligibility: nil, announcementURL: nil, applyURL: nil, overseasURL: nil, officialStatus: nil,
            status: .confirmed, links: []
        )
        let campaign = GoodsCampaign(
            id: "cached-goods", eventID: event.id, officialName: "缓存周边", channel: .online,
            fulfillment: .shipping, phase: .pre, scope: .unconfirmed, salesStartAt: nil, salesEndAt: nil,
            pickupWindow: nil, shippingNote: nil, location: nil, requiresTicket: nil, purchaseLimit: nil,
            paymentMethods: nil, url: "https://example.com/cached-goods", mediaAssetIDs: [], status: .confirmed
        )
        return LiveEventBundle(
            schemaVersion: 1, publishedAt: .distantPast, event: event, stops: [],
            performances: [performance], ticketTiers: [],
            ticketRounds: rounds > 0 ? [round] : [], ticketOffers: [],
            goodsCampaigns: goods > 0 ? [campaign] : [], mediaAssets: [], notices: [], evidence: []
        )
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
