import XCTest
@testable import LiveDashboardKit

/// Regressions reduced from official HTML captured on 2026-09-22. Each excerpt
/// keeps the heading hierarchy that determines the production parser's scope.
final class OfficialAuditRegressionTests: XCTestCase {
    override func tearDown() {
        OfficialAuditURLProtocol.responses = [:]
        super.tearDown()
    }

    func testRoseliaTourAssociatesEachDateWithItsOwnVenue() async throws {
        // Source: https://bang-dream.com/events/roselia-10th-anniversary-live-tour/
        let html = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">Roselia 10th Anniversary LIVE TOUR</h1>
          <div class="p-live-event-detail__content c-post-content">
            <h2>公演名</h2><p>Roselia 10th Anniversary LIVE TOUR</p>
            <h2>日程・会場</h2>
            <h6>東京公演</h6><p>日程：2027年1月30日(土)<br>会場：TOYOTA ARENA TOKYO</p>
            <h6>愛知公演</h6><p>日程：2027年2月28日(日)<br>会場：愛知県芸術劇場 大ホール</p>
            <h6>宮城公演</h6><p>日程：2027年3月14日(日)<br>会場：仙台サンプラザホール</p>
            <h6>福岡公演</h6><p>日程：2027年4月25日(日)<br>会場：福岡サンパレス</p>
            <h2>出演</h2><p>Roselia</p>
          </div>
        </article>
        """

        let refreshed = try await refresh(
            html: html,
            url: "https://bang-dream.com/events/roselia-10th-anniversary-live-tour/",
            title: "Roselia 10th Anniversary LIVE TOUR"
        )

        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: refreshed.performances.map { ($0.localDate, $0.venueName) }),
            [
                "2027-01-30": "TOYOTA ARENA TOKYO",
                "2027-02-28": "愛知県芸術劇場 大ホール",
                "2027-03-14": "仙台サンプラザホール",
                "2027-04-25": "福岡サンパレス",
            ]
        )
        XCTAssertTrue(refreshed.performances.allSatisfy { $0.performers == ["Roselia"] })
    }

    func testBootIgnitionCombinedOverviewAndVenueTicketRetainFacts() async throws {
        // Source: https://bang-dream.com/ras_2026_tokyo/
        let html = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">RAISE A SUILEN LIVE 2026「Boot IGNITION」東京公演</h1>
          <div class="p-live-event-detail__content c-post-content">
            <h2>公演名</h2><p>RAISE A SUILEN LIVE 2026「Boot IGNITION」東京公演</p>
            <h2>日程・会場</h2>
            <p>日程：2026年6月18日(木)　開場17:30／開演19:00（予定）<br>会場：SGC HALL ARIAKE</p>
            <h2>出演</h2><p>RAISE A SUILEN</p>
            <h2>会場チケット</h2>
            <h3>料金</h3>
            <p>アリーナスタンディング Sエリア(特製グッズ付き)：19,800円(税込)<br>
            アリーナスタンディング Aエリア(特製グッズ付き)：14,300円(税込)<br>
            スタンド指定席(特製グッズ付き)：14,300円(税込)<br>
            スタンド指定席：9,900円(税込)<br>
            スタンド指定席(当日券)：11,000円(税込)</p>
            <h3>販売情報</h3>
            <h6>東京公演 一般発売</h6>
            <p>受付期間：2026年5月9日(土) 12:00～<br>
            受付URL：<a href="https://eplus.jp/ras-2026/">https://eplus.jp/ras-2026/</a><br>※先着順</p>
            <h6>プレイガイド二次先行（受付終了）</h6>
            <p>受付期間：2026年4月15日(水) 18:00～2026年4月26日(日) 23:59</p>
            <h2>グッズ通販</h2>
            <p><img src="https://bang-dream.com/wordpress/wp-content/uploads/2026/05/18154202/3472d09f-b3294fc8-f937f7a3-7f19be53.jpg"></p>
            <h6>先行通販開始</h6>
            <p>2026年5月22日(金) 15:00～ 在庫なくなり次第終了</p>
            <p>詳細はこちら：<a href="https://bushiroad-store.com/pages/ras_2026">公式ストア</a></p>
          </div>
        </article>
        """

        let refreshed = try await refresh(
            html: html,
            url: "https://bang-dream.com/ras_2026_tokyo/",
            title: "RAISE A SUILEN LIVE 2026「Boot IGNITION」"
        )

        let performance = try XCTUnwrap(refreshed.performances.first)
        XCTAssertEqual(performance.localDate, "2026-06-18")
        XCTAssertEqual(performance.venueName, "SGC HALL ARIAKE")
        XCTAssertEqual(performance.doorsAt, Self.date("2026-06-18T08:30:00Z"))
        XCTAssertEqual(performance.startAt, Self.date("2026-06-18T10:00:00Z"))

        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: refreshed.ticketTiers.map { ($0.name, $0.priceJPY) }),
            [
                "アリーナスタンディング Sエリア(特製グッズ付き)": 19_800,
                "アリーナスタンディング Aエリア(特製グッズ付き)": 14_300,
                "スタンド指定席(特製グッズ付き)": 14_300,
                "スタンド指定席": 9_900,
                "スタンド指定席(当日券)": 11_000,
            ]
        )
        let general = try XCTUnwrap(refreshed.ticketRounds.first { $0.officialName == "東京公演 一般発売" })
        XCTAssertEqual(general.applyStartAt, Self.date("2026-05-09T03:00:00Z"))
        XCTAssertNil(general.applyEndAt)
        XCTAssertEqual(general.applyURL, "https://eplus.jp/ras-2026/")
        let second = try XCTUnwrap(refreshed.ticketRounds.first { $0.officialName.contains("プレイガイド二次先行") })
        XCTAssertEqual(second.applyStartAt, Self.date("2026-04-15T09:00:00Z"))
        XCTAssertEqual(second.applyEndAt, Self.date("2026-04-26T14:59:00Z"))
        XCTAssertEqual(second.officialStatus, "受付終了")

        let goods = try XCTUnwrap(refreshed.goodsCampaigns.first { $0.officialName == "グッズ通販" })
        XCTAssertEqual(goods.url, "https://bushiroad-store.com/pages/ras_2026")
        XCTAssertEqual(goods.phase, .pre)
        XCTAssertEqual(goods.salesStartAt, Self.date("2026-05-22T06:00:00Z"))
        XCTAssertNil(goods.salesEndAt, "在庫終了 is open-ended, not an invented timestamp")
    }

    func testTicketWindowCarriesYearIntoOmittedYearDeadline() async throws {
        // Source: https://bang-dream.com/events/eleganza/
        let html = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">Morfonica LIVE「eleganza」</h1>
          <div class="p-live-event-detail__content c-post-content">
            <h2>日程</h2><p>2027年1月9日(土)　開場17:00／開演18:00（予定）</p>
            <h2>会場</h2><p>Kanadevia Hall</p>
            <h2>チケット</h2>
            <h3>販売情報</h3>
            <h6>プレイガイド先行</h6>
            <p><a href="https://eplus.jp/morfonica-eleganza/">受付はこちら</a></p>
            <p>受付期間：2026年9月22日(火・祝) 21:00～ 10月18日(日) 23:59</p>
          </div>
        </article>
        """

        let refreshed = try await refresh(
            html: html,
            url: "https://bang-dream.com/events/eleganza/",
            title: "Morfonica LIVE「eleganza」"
        )

        let round = try XCTUnwrap(refreshed.ticketRounds.first)
        XCTAssertEqual(round.applyStartAt, Self.date("2026-09-22T12:00:00Z"))
        XCTAssertEqual(round.applyEndAt, Self.date("2026-10-18T14:59:00Z"))
    }

    func testEleganzaVendorButtonAndOfficiallyTBABenefitAreImported() async throws {
        // Source: https://bang-dream.com/events/eleganza/ (captured 2026-09-22)
        let html = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">Morfonica LIVE「eleganza」</h1>
          <div class="p-live-event-detail__content c-post-content">
            <h2>日程</h2><p>2027年1月9日(土)　開場17:00／開演18:00（予定）</p>
            <h2>会場</h2><p>Kanadevia Hall</p>
            <h2 id="Ticket" class="blogparts_element blogparts_root">チケット</h2>
            <h3 class="blogparts_element blogparts_root">料金</h3>
            <p>アリーナスタンディング Sエリア(特製グッズ付き)：22,000円(税込)<br />
            アリーナスタンディング Aエリア(特製グッズ付き)：16,500円(税込)<br />
            スタンド指定席(特製グッズ付き)：14,300円(税込))<br />
            スタンド指定席：9,900円(税込))</p>
            <h6 class="blogparts_element blogparts_root">グッズ付きチケット特典</h6>
            <p class="blogparts_element">後日公開いたします。</p>
            <h6 class="blogparts_element blogparts_root">会場座席イメージ</h6>
            <p class="blogparts_element"><img src="https://bang-dream.com/wordpress/wp-content/uploads/2026/09/18121237/seat.jpg" alt="" /></p>
            <h3>販売情報</h3>
            <h6 class="blogparts_element blogparts_root">プレイガイド先行</h6>
            <p><a class="c-button--blog-large c-button--red-grad" href="https://eplus.jp/morfonica-eleganza/" target="_blank" rel="noopener">受付はこちら</a></p>
            <p>受付期間：2026年9月22日(火・祝) 21:00～ 10月18日(日) 23:59</p>
            <p class="blogparts_element">※1回につき4枚までお申し込みいただけます。</p>
          </div>
        </article>
        """

        let refreshed = try await refresh(html: html, url: "https://bang-dream.com/events/eleganza/", title: "Morfonica LIVE「eleganza」")

        let performance = try XCTUnwrap(refreshed.performances.first)
        let round = try XCTUnwrap(refreshed.ticketRounds.first { $0.officialName == "プレイガイド先行" })
        XCTAssertEqual(round.applyURL, "https://eplus.jp/morfonica-eleganza/")
        XCTAssertEqual(round.links.first { $0.url == "https://eplus.jp/morfonica-eleganza/" }?.label, "受付はこちら")
        XCTAssertEqual(round.scope, .performances(performanceIDs: [performance.id]), "single-performance rounds apply to that performance")
        XCTAssertEqual(round.applyStartAt, Self.date("2026-09-22T12:00:00Z"))

        let benefit = try XCTUnwrap(refreshed.ticketBenefits.first)
        XCTAssertEqual(benefit.officialName, "グッズ付きチケット特典")
        XCTAssertEqual(benefit.status, .officiallyTBA)
        XCTAssertNil(benefit.detail)
        XCTAssertEqual(benefit.notes, "後日公開いたします。")
        XCTAssertEqual(benefit.scope, .performances(performanceIDs: [performance.id]))
        XCTAssertEqual(Set(benefit.tierIDs), Set(refreshed.ticketTiers.filter { $0.name.contains("グッズ付き") }.map(\.id)))
        XCTAssertEqual(benefit.tierIDs.count, 3)
        XCTAssertTrue(refreshed.ticketTiers.allSatisfy { $0.includes == nil }, "no announced contents to copy into tiers")
        XCTAssertTrue(benefit.mediaAssetIDs.isEmpty, "the seating image belongs to the next heading")
    }

    func testMovementBenefitContentsRedemptionAndTradeButtonAreImported() async throws {
        // Source: https://bang-dream.com/events/morfonica_live_2026/ (captured 2026-09-22)
        let html = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">Morfonica LIVE「Movement」</h1>
          <div class="p-live-event-detail__content c-post-content">
            <h2>日程</h2><p>2026年9月22日(火・祝)　開場17:00／開演18:00</p>
            <h2>会場</h2><p>TACHIKAWA STAGE GARDEN</p>
            <h2 id="Ticket">チケット ※SOLD OUT！</h2>
            <h3>料金</h3>
            <p><span style="text-decoration: line-through;">スタンド指定席(特製グッズ付き)：14,300円(税込))</span>　受付終了<br />
            <span style="text-decoration: line-through;">スタンド指定席：9,900円(税込))</span>　受付終了</p>
            <h6>グッズ付きチケット特典</h6>
            <p>イロドリコースター＋二重奏グラス</p>
            <p>※二重奏グラスについて、特典の性質上、ロゴ部分に印刷のカスレが入る場合がございます。あらかじめご了承ください。</p>
            <p><img src="https://bang-dream.com/wordpress/wp-content/uploads/2026/09/05161644/benefit-1024x778.jpg" alt="" /></p>
            <blockquote class="c-post-content__quote">
            <h6><span style="color: #ff0000;">チケット特典のお渡しについて (2026年9月18日更新)</span></h6>
            <p>特典の引き換えは、<strong>チケットのグッズ引換券</strong>にて実施いたします。<br />
            お受け取り忘れのないようご注意ください。</p>
            <p><strong>▼引換場所</strong><br />
            TACHIKAWA STAGE GARDEN 入場口付近 特典引換所</p>
            <p><strong>▼引換日時<br />
            </strong>9/22(火・祝) 13:00～16:30、17:00～終演後 列が途切れ次第終了</p>
            <p>※開場時間中は場内に限り引き換えいただけます。</p>
            </blockquote>
            <h4>会場座席イメージ</h4>
            <p><img src="https://bang-dream.com/wordpress/wp-content/uploads/2026/09/17195416/seat.jpg" alt="" /></p>
            <h3>販売情報</h3>
            <h6>一般発売（受付終了）</h6>
            <p>受付期間：2026年8月29日(土) 10:00 ～</p>
            <h2 id="Ticket_trade">チケットトレード</h2>
            <p>本公演では公式チケットトレードを受付いたします。</p>
            <h6>トレード申し込み・詳細はこちら</h6>
            <p><a href="https://trade.tixplus.jp/artists/tour/15286" target="_blank" rel="noopener">https://trade.tixplus.jp/artists/tour/15286</a><br />
            ※受付開始後に遷移可能となります。</p>
            <h6>トレード受付期間</h6>
            <p>2026年9月14日(月) 12:00 ～ 9月18日(金) 11:59</p>
          </div>
        </article>
        """

        let refreshed = try await refresh(html: html, url: "https://bang-dream.com/events/morfonica_live_2026/", title: "Morfonica LIVE「Movement」")

        let benefit = try XCTUnwrap(refreshed.ticketBenefits.first)
        XCTAssertEqual(benefit.status, .confirmed)
        XCTAssertEqual(benefit.detail, "イロドリコースター＋二重奏グラス")
        XCTAssertEqual(benefit.notes, "※二重奏グラスについて、特典の性質上、ロゴ部分に印刷のカスレが入る場合がございます。あらかじめご了承ください。")
        XCTAssertEqual(benefit.redemptionLocation, "TACHIKAWA STAGE GARDEN 入場口付近 特典引換所")
        XCTAssertEqual(benefit.redemptionWindow, "9/22(火・祝) 13:00～16:30、17:00～終演後 列が途切れ次第終了")
        XCTAssertEqual(benefit.redemptionNote?.contains("グッズ引換券"), true)
        XCTAssertEqual(benefit.redemptionNote?.contains("※開場時間中"), true)
        XCTAssertEqual(benefit.mediaAssetIDs.count, 1)
        let image = try XCTUnwrap(refreshed.mediaAssets.first { benefit.mediaAssetIDs.contains($0.id) })
        XCTAssertEqual(image.originalURL, "https://bang-dream.com/wordpress/wp-content/uploads/2026/09/05161644/benefit-1024x778.jpg")
        XCTAssertEqual(image.caption, "グッズ付きチケット特典")
        XCTAssertEqual(refreshed.evidence.first { $0.recordID == benefit.id }?.field, "ticket.benefit")

        let bundled = try XCTUnwrap(refreshed.ticketTiers.first { $0.name == "スタンド指定席(特製グッズ付き)" })
        XCTAssertEqual(bundled.includes, "イロドリコースター＋二重奏グラス")
        XCTAssertNil(refreshed.ticketTiers.first { $0.name == "スタンド指定席" }?.includes)

        let trade = try XCTUnwrap(refreshed.ticketRounds.first { $0.kind == .resale })
        XCTAssertEqual(trade.officialName, "トレード受付期間")
        XCTAssertEqual(trade.applyURL, "https://trade.tixplus.jp/artists/tour/15286", "the button-only sibling heading lends its link")
        XCTAssertEqual(trade.applyStartAt, Self.date("2026-09-14T03:00:00Z"))
        XCTAssertFalse(refreshed.ticketRounds.contains { $0.officialName.contains("こちら") }, "a pointer heading is never a round of its own")
    }

    func testSharedVendorButtonUnderSalesContainerHeadingIsNotARound() async throws {
        // Source: https://bang-dream.com/events/mygo_9th/ (captured 2026-09-22)
        let html = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">MyGO!!!!! 9th LIVE</h1>
          <div class="p-live-event-detail__content c-post-content">
            <h2>日程・会場</h2>
            <h6>DAY1</h6><p>日程：2026年8月1日(土)<br>会場：Kアリーナ横浜</p>
            <h6>DAY2</h6><p>日程：2026年8月2日(日)<br>会場：Kアリーナ横浜</p>
            <h2>チケット</h2>
            <h3>販売情報</h3>
            <p><a class="c-button--blog-large c-button--red-grad" href="https://eplus.jp/mygo-9th/" target="_blank" rel="noopener">受付はこちら</a></p>
            <h6>見切れ席・2F後方立ち見エリア発売（DAY2のみ）</h6>
            <p>受付期間：2026年7月17日(金) 20:00 ～</p>
            <h6>一般発売（受付終了）</h6>
            <p>受付期間：2026年6月6日(土) 12:00 ～</p>
          </div>
        </article>
        """

        let refreshed = try await refresh(html: html, url: "https://bang-dream.com/events/mygo_9th/", title: "MyGO!!!!! 9th LIVE")

        XCTAssertEqual(refreshed.ticketRounds.map(\.officialName), ["見切れ席・2F後方立ち見エリア発売（DAY2のみ）", "一般発売（受付終了）"], "the 販売情報 container is not a round")
        XCTAssertTrue(refreshed.ticketRounds.allSatisfy { $0.applyURL == "https://eplus.jp/mygo-9th/" }, "the shared button reaches every round")
        XCTAssertTrue(refreshed.ticketRounds.allSatisfy { $0.scope == .unconfirmed }, "two dates: never guess which day")
    }

    func testBenefitContentsInChildHeadingAreNotOfficiallyTBA() async throws {
        // Source: https://bang-dream.com/events/arale_acousticlive2025/ (captured 2026-09-22)
        let html = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">仲町あられ Acoustic LIVE</h1>
          <div class="p-live-event-detail__content c-post-content">
            <h2>日程</h2><p>2025年10月18日(土)　開場17:00／開演18:00</p>
            <h2>会場</h2><p>Zepp Shinjuku</p>
            <h2>チケット</h2>
            <h3>料金</h3><p>指定席(特製グッズ付き)：8,800円(税込)</p>
            <h3>グッズ付きチケット特典</h3>
            <h6>仲町あられ 直筆サイン&amp;ニックネーム入りポストカード</h6>
            <p><strong>その場でポストカードに直筆サイン＆ご希望のニックネーム（もしくはお名前）を入れてお渡しいたします！</strong></p>
            <p>●お名前、ニックネームは、整列時に配布する用紙に事前にご記入いただきます。</p>
            <h3>販売情報</h3>
            <h6>一般発売</h6>
            <p>受付期間：2025年9月6日(土) 12:00 ～<br>受付URL：<a href="https://eplus.jp/nakamachiarale/">https://eplus.jp/nakamachiarale/</a></p>
          </div>
        </article>
        """

        let refreshed = try await refresh(html: html, url: "https://bang-dream.com/events/arale_acousticlive2025/", title: "仲町あられ Acoustic LIVE")

        let benefit = try XCTUnwrap(refreshed.ticketBenefits.first)
        XCTAssertEqual(benefit.status, .confirmed)
        XCTAssertEqual(benefit.detail?.hasPrefix("仲町あられ 直筆サイン&ニックネーム入りポストカード\nその場でポストカードに"), true, "\(benefit.detail ?? "nil")")
        XCTAssertEqual(refreshed.ticketTiers.first?.includes, benefit.detail)
        XCTAssertEqual(refreshed.ticketRounds.map(\.officialName), ["一般発売"], "the benefit's child heading is not a round")
    }

    func testVendorButtonWithoutPeriodTextStillBecomesARound() async throws {
        let html = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">Button Only LIVE</h1>
          <div class="p-live-event-detail__content c-post-content">
            <h2>日程</h2><p>2027年3月6日(土)　開場17:00／開演18:00</p>
            <h2>会場</h2><p>Zepp Haneda</p>
            <h2>チケット</h2>
            <h3>販売情報</h3>
            <h6>プレイガイド先行</h6>
            <p><a class="c-button--blog-large c-button--red-grad" href="https://eplus.jp/button-only/" target="_blank" rel="noopener">受付はこちら</a></p>
          </div>
        </article>
        """

        let refreshed = try await refresh(html: html, url: "https://bang-dream.com/events/button-only/", title: "Button Only LIVE")

        let round = try XCTUnwrap(refreshed.ticketRounds.first)
        XCTAssertEqual(round.officialName, "プレイガイド先行")
        XCTAssertEqual(round.applyURL, "https://eplus.jp/button-only/")
        XCTAssertNil(round.applyStartAt)
        XCTAssertEqual(round.status, .confirmed)
        XCTAssertTrue(refreshed.ticketBenefits.isEmpty)
    }

    func testApplicationResultAndPaymentIntervalsDoNotBleedIntoEachOther() async throws {
        // Source: https://www.lovelive-anime.jp/special/live/live_detail.php?p=15th_lovelivefest
        let html = """
        <html><head><meta property="og:description" content="LoveLive! Series 15th Anniversary ラブライブ！フェス｜ラブライブ！"></head>
        <article>
          <div data-target="top"><h3>日程</h3><p>Day.1：2026年11月14日（土）14:30開場／16:30開演</p>
          <h3>会場</h3><p>愛知・バンテリンドーム ナゴヤ</p></div>
          <div data-target="ticket2">
            <h3>アップグレード受付</h3>
            <h6>【1次抽選】</h6>
            <p>受付期間：2026年8月15日（土）12:00～9月13日（日）23:59<br>
            当落発表：2026年9月19日（土）13:00～<br>
            入金期間：2026年9月19日（土）13:00～9月22日（火・祝）21:00</p>
          </div>
        </article></html>
        """

        let refreshed = try await refresh(
            html: html,
            url: "https://www.lovelive-anime.jp/special/live/live_detail.php?p=15th_lovelivefest",
            title: "LoveLive! Series 15th Anniversary ラブライブ！フェス",
            franchise: .lovelive
        )

        let round = try XCTUnwrap(refreshed.ticketRounds.first { $0.officialName.contains("1次抽選") })
        XCTAssertEqual(round.applyStartAt, Self.date("2026-08-15T03:00:00Z"))
        XCTAssertEqual(round.applyEndAt, Self.date("2026-09-13T14:59:00Z"))
        XCTAssertEqual(round.resultAt, Self.date("2026-09-19T04:00:00Z"))
        XCTAssertEqual(round.paymentDeadlineAt, Self.date("2026-09-22T12:00:00Z"))
    }

    func testHasunosoraIndexPreservesFourSessionsAcrossTwoDates() async throws {
        let indexURL = "https://www.lovelive-anime.jp/hasunosora/live-event/"
        let detailURL = "https://www.lovelive-anime.jp/hasunosora/live-event/live_detail.php?p=RTB"
        // Source: https://www.lovelive-anime.jp/hasunosora/live-event/
        let index = """
        <ul><li><a href="live_detail.php?p=RTB">
          <div class="live_title"><p>103-105th Fes×ReC：LIVE ～Road to Bloom～</p></div>
          <div class="schedule"><p class="live_date"><span>【日程】
          ●2026年1月21日(水)
          ＜第1回公演＞18:00開場／19:00開演
          ●2026年1月22日(木)
          ＜第2回公演＞10:30開場／11:30開演
          ＜第3回公演＞13:30開場／14:30開演
          ＜第4回公演＞18:15開場／19:00開演</span></p></div>
          <div class="place"><p class="live_place"><span>【会場】<br>Zepp Haneda（TOKYO）</span></p></div>
        </a></li></ul>
        """
        // The captured index supplies the schedule; the detail's top section is intentionally sparse.
        let detail = """
        <html><head><meta property="og:description" content="103-105th Fes×ReC：LIVE ～Road to Bloom～｜ラブライブ！蓮ノ空"></head>
        <article><div data-target="top"><h3>公演概要</h3><p>詳細情報</p></div></article></html>
        """
        OfficialAuditURLProtocol.responses = [indexURL: Data(index.utf8), detailURL: Data(detail.utf8)]
        let scraper = OfficialEventScraper(session: session(), indexURLs: [URL(string: indexURL)!])

        let bundles = try await scraper.collect(
            existing: [], cutoff: "2025-01-01", now: Self.date("2026-09-22T12:00:00Z")
        )

        let performances = try XCTUnwrap(bundles.first?.performances)
        XCTAssertEqual(performances.map(\.localDate), ["2026-01-21", "2026-01-22", "2026-01-22", "2026-01-22"])
        XCTAssertEqual(
            performances.map(\.doorsAt),
            [
                Self.date("2026-01-21T09:00:00Z"),
                Self.date("2026-01-22T01:30:00Z"),
                Self.date("2026-01-22T04:30:00Z"),
                Self.date("2026-01-22T09:15:00Z"),
            ]
        )
        XCTAssertEqual(
            performances.map(\.startAt),
            [
                Self.date("2026-01-21T10:00:00Z"),
                Self.date("2026-01-22T02:30:00Z"),
                Self.date("2026-01-22T05:30:00Z"),
                Self.date("2026-01-22T10:00:00Z"),
            ]
        )
        XCTAssertTrue(performances.allSatisfy { $0.venueName == "Zepp Haneda（TOKYO）" })
    }

    func testHongKongPerformanceKeepsLocalTimeZoneAndCurrency() async throws {
        // Source: https://bang-dream.com/ras_2026_hongkong/
        let html = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">RAISE A SUILEN LIVE 2026「Boot IGNITION」香港公演</h1>
          <div class="p-live-event-detail__content c-post-content">
            <p>※本ページに記載の時間は、原則として現地時間となります。</p>
            <h2>公演名</h2><p>RAISE A SUILEN LIVE 2026「Boot IGNITION」香港公演</p>
            <h2>日程・会場</h2>
            <p>DAY1<br>2026年8月14日(金)　開場18:00／開演20:00 (現地時間・予定)</p>
            <p>DAY2<br>2026年8月15日(土)　開場17:00／開演19:00 (現地時間・予定)</p>
            <p>会場：AsiaWorld-Expo, Hall 10</p>
            <h2>出演</h2><p>RAISE A SUILEN</p>
            <h2>チケット</h2>
            <h3>料金</h3><h6>香港公演</h6>
            <p>A：HK$1688 (特製グッズ付き)<br>B：HK$1488 (特製グッズ付き)<br>C：HK$988<br>D：HK$788</p>
          </div>
        </article>
        """

        let refreshed = try await refresh(
            html: html,
            url: "https://bang-dream.com/ras_2026_hongkong/",
            title: "RAISE A SUILEN LIVE 2026「Boot IGNITION」香港公演"
        )

        XCTAssertEqual(refreshed.event.timeZone, "Asia/Hong_Kong")
        XCTAssertEqual(refreshed.performances.map(\.timeZone), ["Asia/Hong_Kong", "Asia/Hong_Kong"])
        XCTAssertEqual(refreshed.performances.map(\.doorsAt), [
            Self.date("2026-08-14T10:00:00Z"), Self.date("2026-08-15T09:00:00Z"),
        ])
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: refreshed.ticketTiers.map { ($0.name, $0.amount) }),
            [
                "A": MoneyAmount(minorUnits: 168_800, currency: "HKD"),
                "B": MoneyAmount(minorUnits: 148_800, currency: "HKD"),
                "C": MoneyAmount(minorUnits: 98_800, currency: "HKD"),
                "D": MoneyAmount(minorUnits: 78_800, currency: "HKD"),
            ]
        )
        XCTAssertTrue(refreshed.ticketTiers.allSatisfy { $0.priceJPY == nil })
    }

    func testResonextPreservesSameDateMatineeAndEveningSessions() async throws {
        // Source: https://bang-dream.com/events/nakamachiarale_live2026/
        let html = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">NAKAMACHI ARALE LIVE 2026「RESONEXT」</h1>
          <div class="p-live-event-detail__content c-post-content">
            <h2>公演名</h2><p>NAKAMACHI ARALE LIVE 2026「RESONEXT」</p>
            <h2>日程</h2><p>2026年12月24日(木)<br>
            昼の部　開場：13:15／開演：14:00（予定）<br>
            夜の部　開場：18:30／開演：19:15（予定）</p>
            <h2>会場</h2><p>大手町三井ホール</p>
            <h2>出演</h2><p>仲町あられ（夢限大みゅーたいぷ）</p>
          </div>
        </article>
        """

        let refreshed = try await refresh(
            html: html,
            url: "https://bang-dream.com/events/nakamachiarale_live2026/",
            title: "NAKAMACHI ARALE LIVE 2026「RESONEXT」"
        )

        XCTAssertEqual(refreshed.performances.map(\.localDate), ["2026-12-24", "2026-12-24"])
        XCTAssertEqual(refreshed.performances.map(\.dayLabel), ["昼の部", "夜の部"])
        XCTAssertEqual(refreshed.performances.map(\.doorsAt), [
            Self.date("2026-12-24T04:15:00Z"), Self.date("2026-12-24T09:30:00Z"),
        ])
        XCTAssertEqual(refreshed.performances.map(\.startAt), [
            Self.date("2026-12-24T05:00:00Z"), Self.date("2026-12-24T10:15:00Z"),
        ])
        XCTAssertTrue(refreshed.performances.allSatisfy { $0.venueName == "大手町三井ホール" })
    }

    func testFestivalSchedulesMapPairedParagraphsAndSharedTimes() async throws {
        // Source: https://bang-dream.com/events/bm-echoes-festival-2026/
        let echoesHTML = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">BM-ECHOES FESTIVAL 2026</h1>
          <div class="p-live-event-detail__content c-post-content">
            <h2>公演名</h2><p>BM-ECHOES FESTIVAL 2026</p>
            <h2>日程・会場</h2>
            <p>日程：2026年9月5日(土)<br>開場：17:00／開演：18:00（予定）<br>
            会場：Zepp Osaka Bayside<br>出演：青木陽菜、夢限大みゅーたいぷ、RealRomantic（オープニングアクト）</p>
            <p>日程：2026年9月6日(日)<br>開場：16:30／開演：17:30（予定）<br>
            会場：Zepp Nagoya<br>出演：青木陽菜、夢限大みゅーたいぷ、and more</p>
          </div>
        </article>
        """
        let echoes = try await refresh(
            html: echoesHTML,
            url: "https://bang-dream.com/events/bm-echoes-festival-2026/",
            title: "BM-ECHOES FESTIVAL 2026"
        )

        XCTAssertEqual(echoes.performances.map(\.localDate), ["2026-09-05", "2026-09-06"])
        XCTAssertEqual(echoes.performances.map(\.venueName), ["Zepp Osaka Bayside", "Zepp Nagoya"])
        XCTAssertEqual(echoes.performances.map(\.doorsAt), [
            Self.date("2026-09-05T08:00:00Z"), Self.date("2026-09-06T07:30:00Z"),
        ])
        XCTAssertEqual(echoes.performances.map(\.startAt), [
            Self.date("2026-09-05T09:00:00Z"), Self.date("2026-09-06T08:30:00Z"),
        ])

        // Source: https://bang-dream.com/events/flowthefestival2026/
        let flowHTML = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">FLOW THE FESTIVAL 2026</h1>
          <div class="p-live-event-detail__content c-post-content">
            <h2>公演名</h2><p>FLOW THE FESTIVAL 2026</p>
            <h2>日程</h2><p>2026年6月6日(土)・6月7日(日)　開場10:00／開演12:00 (予定)</p>
            <h2>会場</h2><p>ぴあアリーナMM</p>
          </div>
        </article>
        """
        let flow = try await refresh(
            html: flowHTML,
            url: "https://bang-dream.com/events/flowthefestival2026/",
            title: "FLOW THE FESTIVAL 2026"
        )

        XCTAssertEqual(flow.performances.map(\.localDate), ["2026-06-06", "2026-06-07"])
        XCTAssertEqual(flow.performances.map(\.doorsAt), [
            Self.date("2026-06-06T01:00:00Z"), Self.date("2026-06-07T01:00:00Z"),
        ])
        XCTAssertEqual(flow.performances.map(\.startAt), [
            Self.date("2026-06-06T03:00:00Z"), Self.date("2026-06-07T03:00:00Z"),
        ])
    }

    func testTaipeiPerformersRemainScopedToTheirDays() async throws {
        // Source: https://bang-dream.com/bsl-taipei2026/
        let html = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">BanG Dream! Special LIVE in TAIPEI</h1>
          <div class="p-live-event-detail__content c-post-content">
            <h2>公演名</h2><p>BanG Dream! Special LIVE in TAIPEI</p>
            <h2>日程</h2>
            <p>DAY1 : MyGO!!!!!×Ave Mujica「“moment / memory”」<br>
            2026年4月11日(土)　開場16:30／開演18:30（現地時間・予定）</p>
            <p>DAY2 : Poppin'Party×Roselia「DREAMS GO ON」<br>
            2026年4月12日(日)　開場16:00／開演18:00（現地時間・予定）</p>
            <h2>会場</h2><p>台北・大佳河濱公園</p>
            <h2>出演</h2><p>DAY1 : MyGO!!!!!×Ave Mujica<br>DAY2 : Poppin'Party×Roselia</p>
          </div>
        </article>
        """

        let refreshed = try await refresh(
            html: html,
            url: "https://bang-dream.com/bsl-taipei2026/",
            title: "BanG Dream! Special LIVE in TAIPEI"
        )

        XCTAssertEqual(refreshed.event.timeZone, "Asia/Taipei")
        XCTAssertEqual(refreshed.performances.map(\.dayLabel), ["DAY1", "DAY2"])
        XCTAssertEqual(refreshed.performances.map(\.performers), [
            ["MyGO!!!!!", "Ave Mujica"], ["Poppin'Party", "Roselia"],
        ])
        XCTAssertEqual(refreshed.performances.map(\.startAt), [
            Self.date("2026-04-11T10:30:00Z"), Self.date("2026-04-12T10:00:00Z"),
        ])
    }

    func testLehreDerRoseCreatesThreeStreamOffersWithIndependentDeadlines() async throws {
        // Source: https://bang-dream.com/events/lehre-der-rose/
        let html = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">Roselia「Lehre der Rose」</h1>
          <div class="p-live-event-detail__content c-post-content">
            <h2>公演名</h2><p>Roselia「Lehre der Rose」</p>
            <h2>日程</h2><p>2026年8月29日(土)　開場17:00／開演18:00（予定）</p>
            <h2>会場</h2><p>有明アリーナ</p>
            <h2>配信チケット</h2>
            <h3>料金</h3><p>2DAYS通し視聴チケット：9,900円(税込)<br>
            各公演視聴チケット　　：5,500円(税込)</p>
            <h3>販売情報</h3>
            <h6>2DAYS通し視聴チケット</h6>
            <p>販売期間：2026年8月29日(土) 12:00 ～ 9月5日(土) 21:00まで<br>
            配信期間：各公演視聴チケットの配信期間と同日・同時刻となります。</p>
            <h6>各公演視聴チケット</h6>
            <p>・DAY1<br>販売期間：2026年8月29日(土) 12:00 ～ 9月5日(土) 21:00まで<br>
            配信期間：～ 9月5日(土) 23:59まで</p>
            <p>・DAY2<br>販売期間：2026年8月29日(土) 12:00 ～ 9月6日(日) 21:00まで<br>
            配信期間：～ 9月6日(日) 23:59まで</p>
            <h3>チケット購入</h3><p><a href="https://eplus.jp/roselia-lehre-der-rose/st/">ご購入はこちら</a></p>
          </div>
        </article>
        """

        let refreshed = try await refresh(
            html: html,
            url: "https://bang-dream.com/events/lehre-der-rose/",
            title: "Roselia「Lehre der Rose」"
        )

        XCTAssertEqual(refreshed.streamOffers.count, 3)
        let twoDays = try XCTUnwrap(refreshed.streamOffers.first { $0.officialName == "2DAYS通し視聴チケット" })
        let day1 = try XCTUnwrap(refreshed.streamOffers.first { $0.officialName.contains("DAY1") })
        let day2 = try XCTUnwrap(refreshed.streamOffers.first { $0.officialName.contains("DAY2") })
        XCTAssertEqual(twoDays.amount, MoneyAmount(minorUnits: 9_900, currency: "JPY"))
        XCTAssertEqual(day1.amount, MoneyAmount(minorUnits: 5_500, currency: "JPY"))
        XCTAssertEqual(day2.amount, MoneyAmount(minorUnits: 5_500, currency: "JPY"))
        XCTAssertTrue(refreshed.streamOffers.allSatisfy {
            $0.platform == "Streaming+"
                && $0.url == "https://eplus.jp/roselia-lehre-der-rose/st/"
                && $0.salesStartAt == Self.date("2026-08-29T03:00:00Z")
        })
        XCTAssertEqual(twoDays.salesEndAt, Self.date("2026-09-05T12:00:00Z"))
        XCTAssertEqual(day1.salesEndAt, Self.date("2026-09-05T12:00:00Z"))
        XCTAssertEqual(day2.salesEndAt, Self.date("2026-09-06T12:00:00Z"))
        XCTAssertEqual(day1.archiveAvailableUntil, Self.date("2026-09-05T14:59:00Z"))
        XCTAssertEqual(day2.archiveAvailableUntil, Self.date("2026-09-06T14:59:00Z"))
    }

    func testTicketWindowRollsOmittedYearForwardAcrossNewYear() async throws {
        // Source: https://bang-dream.com/events/mygo-avemujica2026/
        let html = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">MyGO!!!!!×Ave Mujica ツーマンライブ「“moment / memory”」</h1>
          <div class="p-live-event-detail__content c-post-content">
            <h2>日程</h2><p>2026年3月1日(日)　開場15:30／開演17:00（予定）</p>
            <h2>会場</h2><p>Kアリーナ横浜</p>
            <h2>チケット</h2><h3>販売情報</h3>
            <h6>プレイガイド先行（受付終了）</h6>
            <p>受付期間：12月18日(木) 12:00～1月15日(木) 23:59</p>
          </div>
        </article>
        """

        let refreshed = try await refresh(
            html: html,
            url: "https://bang-dream.com/events/mygo-avemujica2026/",
            title: "MyGO!!!!!×Ave Mujica ツーマンライブ「“moment / memory”」"
        )

        let round = try XCTUnwrap(refreshed.ticketRounds.first)
        XCTAssertEqual(round.applyStartAt, Self.date("2025-12-18T03:00:00Z"))
        XCTAssertEqual(round.applyEndAt, Self.date("2026-01-15T14:59:00Z"))
    }

    func testTicketRoundStatusTransitionKeepsIdentityAndTradeIsSeparateRound() async throws {
        let url = "https://bang-dream.com/events/identity-and-trade-audit/"
        let initialHTML = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">Identity audit live</h1>
          <div class="p-live-event-detail__content c-post-content">
            <h2>日程</h2><p>2026年10月1日(木)　開場17:00／開演18:00（予定）</p>
            <h2>会場</h2><p>Audit Hall</p>
            <h2>チケット</h2><h3>販売情報</h3>
            <h6>プレイガイド先行</h6><p>受付期間：2026年8月1日(土) 12:00～8月9日(日) 23:59</p>
          </div>
        </article>
        """
        let initial = try await refresh(html: initialHTML, url: url, title: "Identity audit live")
        let initialRound = try XCTUnwrap(initial.ticketRounds.first)

        let updatedHTML = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">Identity audit live</h1>
          <div class="p-live-event-detail__content c-post-content">
            <h2>日程</h2><p>2026年10月1日(木)　開場17:00／開演18:00（予定）</p>
            <h2>会場</h2><p>Audit Hall</p>
            <h2>チケット</h2><h3>販売情報</h3>
            <h6>プレイガイド先行（終了）</h6><p>受付期間：2026年8月1日(土) 12:00～8月9日(日) 23:59</p>
            <h2>チケットトレード</h2>
            <h6>トレード受付期間</h6><p>2026年9月24日(木) 12:00～9月29日(火) 11:59</p>
          </div>
        </article>
        """
        OfficialAuditURLProtocol.responses = [url: Data(updatedHTML.utf8)]
        let updated = try await OfficialEventScraper(session: session(), indexURLs: [])
            .collect(event: initial, now: Self.date("2026-09-22T12:00:00Z"))

        let closedRound = try XCTUnwrap(updated.ticketRounds.first { $0.officialName.contains("プレイガイド先行") })
        XCTAssertEqual(closedRound.id, initialRound.id)
        XCTAssertEqual(closedRound.officialStatus, "受付終了")
        let trade = try XCTUnwrap(updated.ticketRounds.first { $0.officialName == "トレード受付期間" })
        XCTAssertEqual(trade.kind, .resale)
        XCTAssertEqual(trade.applyStartAt, Self.date("2026-09-24T03:00:00Z"))
        XCTAssertEqual(trade.applyEndAt, Self.date("2026-09-29T02:59:00Z"))
    }

    func testIkizuliveTourKeepsHyogoVenueForHyogoDates() async throws {
        // Source: https://www.lovelive-anime.jp/lovehigh/live/live_detail.php?_id=3rdLIVE
        let html = """
        <html><head><meta property="og:title" content="いきづらい部！3rd LIVE～いつかみんなで叶いそう～ | LIVE＆EVENT | イキヅライブ！ LOVELIVE! BLUEBIRD"></head>
        <div id="event-detail" class="p-article">
          <div data-type="component-livetext"><div class="text-area"><a id="top" name="top" value="top"><h3 data-priset="1" class="ke-live_text ke-live_text_01">開催概要</h3></a></div></div>
          <div data-textblock="" data-type="component-text"><div class="text-area"><div data-textbody="">【日程・会場】<br> ＜東京公演＞<br> Day.1　2027年3月27日（土）16:00開場／17:00開演<br> Day.2　2027年3月28日（日）15:00開場／16:00開演<br> 会場：東京・有明アリーナ<br><br> ＜兵庫公演＞<br> Day.1　2027年4月10日（土）16:00開場／17:00開演<br> Day.2　2027年4月11日（日）14:30開場／15:30開演<br> 会場：兵庫・GLION ARENA KOBE<br><br> 【出演】<br> 「イキヅライブ！ LOVELIVE! BLUEBIRD」いきづらい部！<br><br> 【公演に関するお問い合わせ先】<br> ＜東京公演＞クリエイティブマンプロダクション　03-3499-6669 (月・水・金 12:00〜16:00)<br> ＜兵庫公演＞SOGO大阪 06-6344-3326（平日14:00～16:00）</div></div></div>
          <div class="ticket" data-target="ticket"><div data-type="component-livetext"><a id="ticket" name="ticket" value="ticket"><h3 data-priset="1" class="ke-live_text ke-live_text_01">チケット情報</h3></a></div></div>
        </div></html>
        """

        let refreshed = try await refresh(
            html: html,
            url: "https://www.lovelive-anime.jp/lovehigh/live/live_detail.php?_id=3rdLIVE",
            title: "いきづらい部！3rd LIVE ～いつかみんなで叶いそう～",
            franchise: .lovelive
        )

        XCTAssertEqual(refreshed.performances.map(\.localDate), ["2027-03-27", "2027-03-28", "2027-04-10", "2027-04-11"])
        XCTAssertEqual(refreshed.performances.map(\.venueName), [
            "東京・有明アリーナ", "東京・有明アリーナ", "兵庫・GLION ARENA KOBE", "兵庫・GLION ARENA KOBE",
        ])
        XCTAssertEqual(refreshed.performances.map(\.venueCity), ["東京", "東京", "兵庫", "兵庫"])
    }

    func testNijigasaki8thLiveAssignsTokyoVenueToTokyoDates() async throws {
        // Source: https://www.lovelive-anime.jp/nijigasaki/live/live_detail.php?p=8thlive
        let html = """
        <html><head><meta property="og:description" content="ラブライブ！虹ヶ咲学園スクールアイドル同好会 8thライブ"></head>
        <article>
          <div data-type="component-livetext"><div class="text-area"><a id="top" name="top" value="top"><h3 data-priset="1" class="ke-live_text ke-live_text_01">ライブTOP</h3></a></div></div>
          <div data-textblock="" data-type="component-text"><div class="text-area"><div data-textbody=""><span style="font-size:133.30%;"><strong>＜大阪公演＞</strong></span><br> 【日程】Day.1　2026年6月6日（土）16:00開場／17:00開演<br> 　　　Day.2　2026年6月7日（日）14:00開場／15:00開演<br> 【会場】大阪城ホール<br> 【出演】虹ヶ咲学園スクールアイドル同好会<br><br><span style="font-size:133.30%;"><strong>＜東京公演＞</strong></span><br> 【日程】Day.1　2026年6月13日（土）16:00開場／17:00開演<br> 　　　Day.2　2026年6月14日（日）14:00開場／15:00開演<br> 【会場】京王アリーナ TOKYO<br> 【出演】虹ヶ咲学園スクールアイドル同好会</div></div></div>
          <div data-type="component-livetext"><div class="text-area"><div data-priset="1" class="ke-live_text ke-live_text_01">チケット料金</div></div></div>
          <div data-textblock="" data-type="component-text"><div class="text-area"><div data-textbody="">全席指定　　　　　　：13,500円（税込）</div></div></div>
          <div class="ticket" data-target="ticket"><div data-type="component-livetext"><a id="ticket" name="ticket" value="ticket"><h3 data-priset="1" class="ke-live_text ke-live_text_01">チケット情報</h3></a></div></div>
        </article></html>
        """

        let refreshed = try await refresh(
            html: html,
            url: "https://www.lovelive-anime.jp/nijigasaki/live/live_detail.php?p=8thlive",
            title: "ラブライブ！虹ヶ咲学園スクールアイドル同好会 8th Live! TOKIMEKI Express",
            franchise: .lovelive
        )

        XCTAssertEqual(refreshed.performances.map(\.localDate), ["2026-06-06", "2026-06-07", "2026-06-13", "2026-06-14"])
        XCTAssertEqual(refreshed.performances.map(\.venueName), [
            "大阪城ホール", "大阪城ホール", "京王アリーナ TOKYO", "京王アリーナ TOKYO",
        ])
        // These venue lines carry no "都道府県・" prefix; the city comes from the venue name itself.
        XCTAssertEqual(refreshed.performances.map(\.venueCity), ["大阪", "大阪", "東京", "東京"])
    }

    func testHasunosora6thLiveDreamMapsEachStageToItsVenue() async throws {
        // Source: https://www.lovelive-anime.jp/hasunosora/live-event/live_detail.php?p=6thBGP
        let html = """
        <html><head><meta property="og:description" content="ラブライブ！蓮ノ空女学院スクールアイドルクラブ 6th Live Dream ～Bloom Garden Party～"></head>
        <article>
          <div data-type="component-livetext"><div class="text-area"><a id="top" name="top" value="top"><h3 data-priset="1" class="ke-live_text ke-live_text_01">ライブTOP</h3></a></div></div>
          <div data-textblock="" data-type="component-text"><div class="text-area"><div data-textbody="">ラブライブ！蓮ノ空女学院スクールアイドルクラブ 6th Live Dream ～Bloom Garden Party～<br><br> ＜Bloom Stage／福岡公演＞<br> Day.1　2026年5月2日（土）16:00開場／17:00開演<br> Day.2　2026年5月3日（日）14:00開場／15:00開演<br> 【会場】福岡・マリンメッセ福岡B館<br><br> ＜Garden Stage／兵庫公演＞<br> Day.1　2026年5月23日（土）16:00開場／17:00開演<br> Day.2　2026年5月24日（日）14:00開場／15:00開演<br> 【会場】兵庫・神戸ワールド記念ホール<br><br> ＜Party Stage／神奈川公演＞<br> Day.1　2026年5月30日（土）16:00開場／17:00開演<br> Day.2　2026年5月31日（日）14:00開場／15:00開演<br> 【会場】神奈川・ぴあアリーナMM<br><strong><span style="color:#e74c3c;">※大沢瑠璃乃役の菅 叶和につきまして、体調不良のため＜Party Stage／神奈川公演＞への出演を見合わせることとなりました。</span></strong><br><br> ＜Bloom Garden Party Stage／埼玉公演＞<br> Day.1　2026年7月11日（土）14:00開場／16:00開演<br> Day.2　2026年7月12日（日）13:00開場／15:00開演<br> 【会場】埼玉・ベルーナドーム<br><br> 【出演】<br><span style="color:#e74c3c;">★対象公演：＜Bloom Stage／福岡公演＞、＜Garden Stage／兵庫公演＞、＜Party Stage／神奈川公演＞</span><br> 蓮ノ空女学院スクールアイドルクラブ<br><br> ※ぴあアリーナMMは、会場規定により一部着席指定のお席がございますため、着席指定のお席になる場合がございます。</div></div></div>
          <div class="ticket" data-target="ticket"><div data-type="component-livetext"><a id="ticket" name="ticket" value="ticket"><h3 data-priset="1" class="ke-live_text ke-live_text_01">チケット情報</h3></a></div></div>
        </article></html>
        """

        let refreshed = try await refresh(
            html: html,
            url: "https://www.lovelive-anime.jp/hasunosora/live-event/live_detail.php?p=6thBGP",
            title: "ラブライブ！蓮ノ空女学院スクールアイドルクラブ 6th Live Dream ～Bloom Garden Party～",
            franchise: .lovelive
        )

        XCTAssertEqual(refreshed.performances.map(\.localDate), [
            "2026-05-02", "2026-05-03", "2026-05-23", "2026-05-24",
            "2026-05-30", "2026-05-31", "2026-07-11", "2026-07-12",
        ])
        XCTAssertEqual(refreshed.performances.map(\.venueName), [
            "福岡・マリンメッセ福岡B館", "福岡・マリンメッセ福岡B館",
            "兵庫・神戸ワールド記念ホール", "兵庫・神戸ワールド記念ホール",
            "神奈川・ぴあアリーナMM", "神奈川・ぴあアリーナMM",
            "埼玉・ベルーナドーム", "埼玉・ベルーナドーム",
        ])
        XCTAssertEqual(refreshed.performances.map(\.venueCity), ["福岡", "福岡", "兵庫", "兵庫", "神奈川", "神奈川", "埼玉", "埼玉"])
    }

    func testHasunosora5thLiveTourMapsEachStageToItsVenue() async throws {
        // Source: https://www.lovelive-anime.jp/hasunosora/live-event/live_detail.php?p=4PPS
        let html = """
        <html><head><meta property="og:description" content="ラブライブ！蓮ノ空女学院スクールアイドルクラブ 5th Live Tour ～4Pair Power Spread!!!!～"></head>
        <article>
          <div data-type="component-livetext"><div class="text-area"><a id="top" name="top" value="top"><h3 data-priset="1" class="ke-live_text ke-live_text_01">ライブTOP</h3></a></div></div>
          <div data-textblock="" data-type="component-text"><div class="text-area"><div data-textbody=""><strong>＜みらくらぱーく！ presents Heart Stage cross Bloom Days Extra ～Fes×ReC：LIVE～＞</strong><br> Day.1　2025年10月4日（土） 15:30開場／17:00開演<br> Day.2　2025年10月5日（日） 14:00開場／15:30開演<br> 【会場】東京・国立代々木競技場　第一体育館<br> ※本公演のみ、演出としてメンバーによるバーチャルライブを一部想定しております。<br><br><strong>＜DOLLCHESTRA presents Diamond Stage＞</strong><br> Day.1　2025年11月8日（土） 16:00開場／17:00開演<br> Day.2　2025年11月9日（日） 14:30開場／15:30開演<br> 【会場】愛知・Aichi Sky Expo（愛知県国際展示場）ホールA<br><br><strong>＜Edel Note presents Spade Stage＞</strong><br> Day.1　2025年11月19日（水） 16:30開場／17:30開演<br> Day.2　2025年11月20日（木） 16:30開場／17:30 開演<br> 【会場】大阪・大阪城ホール<br><br><strong>＜スリーズブーケ presents Clover Stage＞</strong><br> Day.1　2025年12月6日（土） 15:30開場／17:00開演<br> Day.2　2025年12月7日（日） 14:00開場／15:30開演<br> 【会場】神奈川・Ｋアリーナ横浜<br><br> 【出演】<br> 蓮ノ空女学院スクールアイドルクラブ<br><br> 【公演に関するお問い合わせ先】<br> 東京公演：H.I.P.　03-3475-9999（平日10:00～18:00）</div></div></div>
          <div class="ticket" data-target="ticket"><div data-type="component-livetext"><a id="ticket" name="ticket" value="ticket"><h3 data-priset="1" class="ke-live_text ke-live_text_01">チケット情報</h3></a></div></div>
        </article></html>
        """

        let refreshed = try await refresh(
            html: html,
            url: "https://www.lovelive-anime.jp/hasunosora/live-event/live_detail.php?p=4PPS",
            title: "ラブライブ！蓮ノ空女学院スクールアイドルクラブ 5th Live Tour ～4Pair Power Spread!!!!～",
            franchise: .lovelive
        )

        XCTAssertEqual(refreshed.performances.map(\.localDate), [
            "2025-10-04", "2025-10-05", "2025-11-08", "2025-11-09",
            "2025-11-19", "2025-11-20", "2025-12-06", "2025-12-07",
        ])
        XCTAssertEqual(refreshed.performances.map(\.venueName), [
            "東京・国立代々木競技場\u{3000}第一体育館", "東京・国立代々木競技場\u{3000}第一体育館",
            "愛知・Aichi Sky Expo（愛知県国際展示場）ホールA", "愛知・Aichi Sky Expo（愛知県国際展示場）ホールA",
            "大阪・大阪城ホール", "大阪・大阪城ホール",
            "神奈川・Ｋアリーナ横浜", "神奈川・Ｋアリーナ横浜",
        ])
        XCTAssertEqual(refreshed.performances.map(\.venueCity), ["東京", "東京", "愛知", "愛知", "大阪", "大阪", "神奈川", "神奈川"])
    }

    func testLL13SameDayLoveLiveSessionsGetDistinctPerformances() async throws {
        // Source: https://www.lovelive-anime.jp/uranohoshi/live/live_detail.php?p=taiikusai
        let url = "https://www.lovelive-anime.jp/uranohoshi/live/live_detail.php?p=taiikusai"
        let html = """
        <html><head><meta property="og:description" content="ラブライブ！サンシャイン!! 体育祭"></head>
        <article><div data-target="top"><h3>日程・場所</h3><p>1日目 昼の部:2026年9月5日(土)13:00開場/14:00開演<br>1日目 夜の部:2026年9月5日(土)17:30開場/18:30開演<br>2日目 昼の部:2026年9月6日(日)13:00開場/14:00開演<br>2日目 夜の部:2026年9月6日(日)17:30開場/18:30開演<br>■会場<br>東京・東京体育館 メインアリーナ</p></div></article>
        </html>
        """

        let first = try await refresh(html: html, url: url, title: "体育祭", franchise: .lovelive)

        XCTAssertEqual(first.performances.count, 4)
        XCTAssertEqual(first.performances.map(\.localDate), ["2026-09-05", "2026-09-05", "2026-09-06", "2026-09-06"])
        XCTAssertEqual(first.performances.map(\.dayLabel), ["DAY1", "DAY1", "DAY2", "DAY2"])
        XCTAssertEqual(first.performances.map(\.subtitle), ["昼の部", "夜の部", "昼の部", "夜の部"])
        XCTAssertEqual(first.performances.map(\.doorsAt), [
            Self.date("2026-09-05T04:00:00Z"), Self.date("2026-09-05T08:30:00Z"),
            Self.date("2026-09-06T04:00:00Z"), Self.date("2026-09-06T08:30:00Z"),
        ])
        XCTAssertEqual(first.performances.map(\.startAt), [
            Self.date("2026-09-05T05:00:00Z"), Self.date("2026-09-05T09:30:00Z"),
            Self.date("2026-09-06T05:00:00Z"), Self.date("2026-09-06T09:30:00Z"),
        ])

        // Refreshing again from the same source must resolve every performance
        // back to its own prior ID, never colliding with another performance.
        OfficialAuditURLProtocol.responses = [url: Data(html.utf8)]
        let second = try await OfficialEventScraper(session: session(), indexURLs: [])
            .collect(event: first, now: Self.date("2026-09-22T12:00:00Z"))

        XCTAssertEqual(Set(first.performances.map(\.id)).count, 4)
        XCTAssertEqual(second.performances.map(\.id), first.performances.map(\.id))
    }

    func testLL18TourStopSessionsIgnoreContactPhoneHoursAsScheduleTimes() async throws {
        // Source: https://www.lovelive-anime.jp/uranohoshi/live/live_detail.php?p=7thlive
        let html = """
        <html><head><meta property="og:description" content="ラブライブ！サンシャイン!! 7th Live"></head>
        <article><div data-target="top"><h3>開催日程</h3><p>Day.1：2026年2月7日（土）16:00開場／17:00開演<br>Day.2:2026年2月8日(日)15:00開場/16:00開演<br>■会場<br>神奈川・横浜アリーナ<br>■お問い合わせ<br>H.I.P. 03-3475-9999(月曜~金曜日 11:00〜13:00 / 15:00〜18:00 (土・日・祝祭日休み))<br>＜愛知公演＞<br>Day.1：2026年2月28日（土）16:00開場／17:00開演<br>Day.2：2026年3月 1日（日）15:00開場／16:00開演</p></div></article>
        </html>
        """

        let refreshed = try await refresh(
            html: html,
            url: "https://www.lovelive-anime.jp/uranohoshi/live/live_detail.php?p=7thlive",
            title: "7th Live",
            franchise: .lovelive
        )

        XCTAssertEqual(refreshed.performances.count, 4)
        XCTAssertEqual(refreshed.performances.map(\.localDate), ["2026-02-07", "2026-02-08", "2026-02-28", "2026-03-01"])
        XCTAssertEqual(refreshed.performances.map(\.dayLabel), ["DAY1", "DAY2", "DAY1", "DAY2"])
        XCTAssertEqual(refreshed.performances.map(\.doorsAt), [
            Self.date("2026-02-07T07:00:00Z"), Self.date("2026-02-08T06:00:00Z"),
            Self.date("2026-02-28T07:00:00Z"), Self.date("2026-03-01T06:00:00Z"),
        ])
        XCTAssertFalse(refreshed.performances.contains { ($0.rawDate ?? "").contains("13:00 / 15:00") })
    }

    func testLL17RTBFourSameWeekPerformancesGetOwnLabelsAndNilSubtitle() async throws {
        // Source: https://www.lovelive-anime.jp/uranohoshi/live/live_detail.php?p=RTB
        let html = """
        <html><head><meta property="og:description" content="ラブライブ！サンシャイン!! RTB"></head>
        <article><div data-target="top"><h3>開催概要</h3><p>【日程】<br>●2026年1月21日(水)<br>&lt;第1回公演&gt;18:15開場/19:00開演<br>●2026年1月22日(木)<br>&lt;第2回公演&gt;10:30開場/11:30開演<br>&lt;第3回公演&gt;13:30開場/14:30開演<br>&lt;第4回公演&gt;18:15開場/19:00開演</p></div></article>
        </html>
        """

        let refreshed = try await refresh(
            html: html,
            url: "https://www.lovelive-anime.jp/uranohoshi/live/live_detail.php?p=RTB",
            title: "RTB",
            franchise: .lovelive
        )

        XCTAssertEqual(refreshed.performances.map(\.dayLabel), ["第1回公演", "第2回公演", "第3回公演", "第4回公演"])
        XCTAssertTrue(refreshed.performances.allSatisfy { $0.subtitle == nil })
        XCTAssertEqual(refreshed.performances.map(\.startAt), [
            Self.date("2026-01-21T10:00:00Z"), Self.date("2026-01-22T02:30:00Z"),
            Self.date("2026-01-22T05:30:00Z"), Self.date("2026-01-22T10:00:00Z"),
        ])
    }

    func testLinkLiveDreamStackedVenueLabelFillsEveryDay() async throws {
        // Source: https://www.lovelive-anime.jp/hasunosora/live-event/live_detail.php?p=LLDream103
        let html = """
        <html><head><meta property="og:description" content="ラブライブ！蓮ノ空女学院スクールアイドルクラブ Link Live Dream ～103期卒業公演～｜ラブライブ！蓮ノ空女学院スクールアイドルクラブ"></head>
        <body><article id="live-event-page" class="container"><article>
          <div data-ke_tab="tab" data-type="component-livetext"><div class="text-area"><a id="top" name="top"><h3 class="ke-live_text ke-live_text_01">ライブTOP</h3></a></div></div>
          <div data-textblock="" data-type="component-text"><div class="text-area"><div data-textbody="">【公演名】<br> ラブライブ！蓮ノ空女学院スクールアイドルクラブ Link Live Dream ～103期卒業公演～<br><br> 【日程】<br> Day.1　2027年1月23日(土) 16:00開場／17:00開演<br> Day.2　2027年1月24日(日) 14:30開場／15:30開演<br><br> 【会場】<br> 東京・日本武道館<br><br> 【出演】<br> 蓮ノ空女学院スクールアイドルクラブ<br><br> ※グッズは公演当日に会場でのお渡しを予定しております。</div></div></div>
          <div class="ticket" data-target="ticket"><div data-type="component-livetext"><a id="ticket" name="ticket" value="ticket"><h3 class="ke-live_text ke-live_text_01">チケット情報</h3></a></div></div>
        </article></article></body></html>
        """

        let refreshed = try await refresh(
            html: html,
            url: "https://www.lovelive-anime.jp/hasunosora/live-event/live_detail.php?p=LLDream103",
            title: "ラブライブ！蓮ノ空女学院スクールアイドルクラブ Link Live Dream ～103期卒業公演～",
            franchise: .lovelive
        )

        XCTAssertEqual(refreshed.performances.map(\.localDate), ["2027-01-23", "2027-01-24"])
        XCTAssertEqual(refreshed.performances.map(\.venueName), ["東京・日本武道館", "東京・日本武道館"])
        XCTAssertEqual(refreshed.performances.map(\.venueCity), ["東京", "東京"])
        XCTAssertEqual(refreshed.performances.map(\.doorsAt), [
            Self.date("2027-01-23T07:00:00Z"), Self.date("2027-01-24T05:30:00Z"),
        ])
    }

    func testRoadToBloomStackedVenueLabelFillsAllFourSessions() async throws {
        // Source: https://www.lovelive-anime.jp/hasunosora/live-event/live_detail.php?p=RTB
        let html = """
        <html><head><meta property="og:description" content="ラブライブ！蓮ノ空女学院スクールアイドルクラブ 103-105th Fes×ReC：LIVE ～Road to Bloom～｜ラブライブ！蓮ノ空女学院スクールアイドルクラブ"></head>
        <body><article>
          <div data-type="component-livetext"><div><a id="top" name="top"><h3>ライブTOP</h3></a></div></div>
          <div data-textblock="" data-type="component-text"><div><div data-textbody="">【日程】<br> ●2026年1月21日（水）<br> ＜第1回公演＞18:00開場／19:00開演<br> ●2026年1月22日（木）<br> ＜第2回公演＞10:30開場／11:30開演<br> ＜第3回公演＞13:30開場／14:30開演<br> ＜第4回公演＞18:15開場／19:00開演<br><br> 【会場】<br> Zepp Haneda（TOKYO）<br><br> 【出演】<br> 蓮ノ空女学院スクールアイドルクラブ</div></div></div>
        </article></body></html>
        """

        let refreshed = try await refresh(
            html: html,
            url: "https://www.lovelive-anime.jp/hasunosora/live-event/live_detail.php?p=RTB",
            title: "103-105th Fes×ReC：LIVE ～Road to Bloom～",
            franchise: .lovelive
        )

        XCTAssertEqual(refreshed.performances.map(\.localDate), ["2026-01-21", "2026-01-22", "2026-01-22", "2026-01-22"])
        XCTAssertTrue(refreshed.performances.allSatisfy { $0.venueName == "Zepp Haneda（TOKYO）" })
    }

    func testIkizuliveSpanWrappedStackedVenueLabelInEventDetailContainer() async throws {
        // Source: https://www.lovelive-anime.jp/lovehigh/live/live_detail.php?_id=WhatismyL
        let html = """
        <html><head><meta property="og:title" content="いきづらい部！ 1st LIVE ～ What is my L ? ～ | イキヅライブ！ LOVELIVE! BLUEBIRD"></head>
        <body><div id="event-detail" class="p-article">
          <div data-type="container-content"><div data-type="component-livetext"><div><a id="top" name="top"><h3>開催概要</h3></a></div></div></div>
          <div data-type="container-content"><div data-textblock="" data-type="component-text"><div><div data-textbody=""><span>【日程】</span><br> Day.1　2026年2月14日（土）16:30開場／17:30開演<br> Day.2　2026年2月15日（日）16:30開場／17:30開演<br><br><span>【会場】</span><br> 千葉・幕張イベントホール<br><br><span>【出演】</span><br> 「イキヅライブ！ LOVELIVE! BLUEBIRD」いきづらい部！</div></div></div></div>
        </div></body></html>
        """

        let refreshed = try await refresh(
            html: html,
            url: "https://www.lovelive-anime.jp/lovehigh/live/live_detail.php?_id=WhatismyL",
            title: "いきづらい部！ 1st LIVE ～ What is my L ? ～",
            franchise: .lovelive
        )

        XCTAssertEqual(refreshed.performances.map(\.localDate), ["2026-02-14", "2026-02-15"])
        XCTAssertEqual(refreshed.performances.map(\.venueName), ["千葉・幕張イベントホール", "千葉・幕張イベントホール"])
        XCTAssertEqual(refreshed.performances.map(\.venueCity), ["千葉", "千葉"])
    }

    func testLiellaTourStackedVenuePerStopAndSiblingCastSection() async throws {
        // Source: https://www.lovelive-anime.jp/yuigaoka/live/live_detail.php?p=8thlivetour
        let html = """
        <html><head><meta property="og:description" content="ラブライブ！スーパースター!! Liella! 8th LoveLive! Tour ～Our Song, Our Dreams～｜ラブライブ！スーパースター!!"></head>
        <body><article>
          <div data-type="component-livetext"><div><h3>開催概要</h3></div></div>
          <div data-textblock="" data-type="component-text"><div><div data-textbody="">
            <div>＜東京公演＞</div><div>【日程】<br> Day.1　2027年3月6日（土）<br> Day.2　2027年3月7日（日）<br> 【会場】<br> 東京・有明アリーナ<br> 【公演に関するお問い合わせ先】<br> インフォメーションデスク</div>
            <div>＜福岡公演＞</div><div>【日程】<br> Day.1　2027年4月24日（土）<br> Day.2　2027年4月25日（日）<br> 【会場】<br> 福岡・マリンメッセ福岡B館<br> 【公演に関するお問い合わせ先】<br> BEA 092−712−4221（平日12:00〜16:00）</div>
            <div>＜愛知公演＞</div><div>【日程】<br> Day.1　2027年5月8日（土）<br> Day.2　2027年5月9日（日）<br> 【会場】<br> 愛知・ポートメッセなごや 第1展示館<br> 【公演に関するお問い合わせ先】<br> キョードー東海 052-972-7466</div>
          </div></div></div>
          <div data-type="component-livetext"><div><h3>出演者</h3></div></div>
          <div><div>Liella!<br> 伊達さゆり（澁谷かのん役）、Liyuu（唐 可可役）、岬 なこ（嵐 千砂都役）</div></div>
          <div><div><br><br> ※開場・開演時間、チケット代など、そのほかの詳細は後日ご案内いたします。<br> ※天候・災害等の諸事情により、開演時間・公演内容の変更、延期、または中止させていただく場合がございます。</div></div>
          <div data-type="component-livetext"><a id="ticket" name="ticket" value="ticket"><h3>チケット情報</h3></a></div>
        </article></body></html>
        """

        let refreshed = try await refresh(
            html: html,
            url: "https://www.lovelive-anime.jp/yuigaoka/live/live_detail.php?p=8thlivetour",
            title: "ラブライブ！スーパースター!! Liella! 8th LoveLive! Tour ～Our Song, Our Dreams～",
            franchise: .lovelive
        )

        XCTAssertEqual(refreshed.performances.map(\.localDate), [
            "2027-03-06", "2027-03-07", "2027-04-24", "2027-04-25", "2027-05-08", "2027-05-09",
        ])
        XCTAssertFalse(refreshed.performances.contains { $0.venueName.isEmpty })
        XCTAssertTrue(refreshed.performances.allSatisfy {
            $0.performers == ["Liella!", "伊達さゆり（澁谷かのん役）", "Liyuu（唐 可可役）", "岬 なこ（嵐 千砂都役）"]
        })
        XCTAssertEqual(refreshed.performances.map(\.venueName), [
            "東京・有明アリーナ", "東京・有明アリーナ",
            "福岡・マリンメッセ福岡B館", "福岡・マリンメッセ福岡B館",
            "愛知・ポートメッセなごや 第1展示館", "愛知・ポートメッセなごや 第1展示館",
        ])
        XCTAssertEqual(refreshed.performances.map(\.venueCity), ["東京", "東京", "福岡", "福岡", "愛知", "愛知"])
    }

    func testInlineCastLabelStackedValueUsedAsPerformersFallback() async throws {
        // Source: https://www.lovelive-anime.jp/uranohoshi/live/live_detail.php?p=LL03 style inline 【出演】 cast.
        let html = """
        <html><head><meta property="og:description" content="ラブライブ！サンシャイン!! LL03"></head>
        <body><article>
          <div data-type="component-livetext"><div><a id="top" name="top"><h3>開催概要</h3></a></div></div>
          <div data-textblock="" data-type="component-text"><div><div data-textbody="">【日程】<br> Day.1　2026年5月1日（金）<br> Day.2　2026年5月2日（土）<br><br> 【会場】<br> 東京・日本武道館<br><br> 【出演】<br> 伊達さゆり、Liyuu、岬 なこ<br><br> 【チケット】<br> 詳細は後日案内いたします。</div></div></div>
        </article></body></html>
        """

        let refreshed = try await refresh(
            html: html,
            url: "https://www.lovelive-anime.jp/uranohoshi/live/live_detail.php?p=LL03",
            title: "LL03",
            franchise: .lovelive
        )

        XCTAssertEqual(refreshed.performances.map(\.localDate), ["2026-05-01", "2026-05-02"])
        XCTAssertTrue(refreshed.performances.allSatisfy {
            $0.performers == ["伊達さゆり", "Liyuu", "岬 なこ"]
        })
    }

    func testLoveLiveRepeatedTicketBlocksProduceUniqueRoundAndTierIDs() async throws {
        let block = """
        <h3>チケット</h3><p>S席：9,900円（税込）<br>A席：7,700円（税込）</p>
        <h3>（終了）オフィシャル先行抽選</h3><p>受付期間：2026年7月1日（水）12:00～2026年7月10日（金）23:59<br><a href="https://eplus.jp/ll-test/">受付はこちら</a></p>
        <h3>（終了）一般抽選</h3><p>受付期間：2026年8月1日（土）12:00～2026年8月10日（月）23:59</p>
        """
        let html = """
        <html><head><meta property="og:description" content="ラブライブ！テスト公演｜ラブライブ！"></head><body>
        <article><div data-target="top"><h3>日程・場所</h3><p>Day.1：2026年9月5日（土）17:30開場／18:30開演<br>■会場<br>東京・東京体育館</p>\(block)</div>
        <div data-target="ticket">\(block)</div><div data-target="ticket2">\(block)</div></article></body></html>
        """
        let bundle = try await refresh(html: html, url: "https://www.lovelive-anime.jp/yuigaoka/live/live_detail.php?p=dup", title: "テスト", franchise: .lovelive)
        XCTAssertEqual(bundle.ticketRounds.map(\.officialName).sorted(), ["（終了）オフィシャル先行抽選", "（終了）一般抽選"])
        XCTAssertEqual(Set(bundle.ticketRounds.map(\.id)).count, bundle.ticketRounds.count)
        XCTAssertEqual(Set(bundle.ticketTiers.map(\.id)).count, bundle.ticketTiers.count)
        XCTAssertEqual(bundle.ticketTiers.map(\.name).sorted(), ["A席", "S席"])
        let grouping = ImportantInformationPolicy.ticketsTabGrouping(rounds: bundle.ticketRounds + bundle.ticketRounds, now: Date(), configurations: [:])
        XCTAssertEqual(grouping.open.count + grouping.upcoming.count + grouping.closed.count, bundle.ticketRounds.count)
    }

    func testJimoaiDayBlocksScopeInlineCastToEachDaysSessions() async throws {
        // Source: https://www.lovelive-anime.jp/uranohoshi/live/live_detail.php?p=jimoai5th (LL09)
        let html = """
        <html><head><meta property="og:description" content="ラブライブ！サンシャイン!! 第５回沼津地元愛まつり｜ラブライブ！サンシャイン!!"></head>
        <body><article>
          <div data-type="component-livetext"><div class="text-area"><h4 class="ke-live_text ke-live_text_03">開催概要・出演者</h4></div></div>
          <div data-textblock="" data-type="component-text"><div class="text-area"><div data-textbody="">＜Day.1＞<br> 2027年3月20日（土）<br> ＜昼公演＞13:00開場／14:00開演<br> ＜夜公演＞17:30開場／18:30開演<br> 【出演】伊波杏樹（高海千歌役）、小宮有紗（黒澤ダイヤ役）、降幡 愛（黒澤ルビィ役）<br><br> ＜Day.2＞<br> 2027年3月21日（日）<br> ＜昼公演＞13:00開場／14:00開演<br> ＜夜公演＞17:30開場／18:30開演<br> 【出演】逢田梨香子（桜内梨子役）、高槻かなこ（国木田花丸役）、鈴木愛奈（小原鞠莉役）<br> &nbsp;</div></div></div>
          <div data-type="component-livetext"><div class="text-area"><h4 class="ke-live_text ke-live_text_03">会場</h4></div></div>
          <div data-textblock="" data-type="component-text"><div class="text-area"><div data-textbody="">キラメッセぬまづ（静岡県沼津市大手1丁目1−4）</div></div></div>
          <div data-type="component-livetext"><div class="text-area"><h4 class="ke-live_text ke-live_text_03">チケット</h4></div></div>
          <div data-textblock="" data-type="component-text"><div class="text-area"><div data-textbody="">全席指定：8,500円（税込）<br>※開場・開演時間、出演者は諸事情により変更になる場合がございます。</div></div></div>
        </article></body></html>
        """
        let refreshed = try await refresh(html: html, url: "https://www.lovelive-anime.jp/uranohoshi/live/live_detail.php?p=jimoai5th",
                                          title: "ラブライブ！サンシャイン!! 第５回沼津地元愛まつり", franchise: .lovelive)
        let day1 = ["伊波杏樹（高海千歌役）", "小宮有紗（黒澤ダイヤ役）", "降幡 愛（黒澤ルビィ役）"]
        let day2 = ["逢田梨香子（桜内梨子役）", "高槻かなこ（国木田花丸役）", "鈴木愛奈（小原鞠莉役）"]
        XCTAssertEqual(refreshed.performances.map(\.localDate), ["2027-03-20", "2027-03-20", "2027-03-21", "2027-03-21"])
        XCTAssertEqual(refreshed.performances.map(\.performers), [day1, day1, day2, day2])
    }

    func testJimoai2025PublicDayCastHeadingInsideOverview() async throws {
        // Source: https://www.lovelive-anime.jp/uranohoshi/live/live_detail.php?p=jimoai2025 (LL20)
        let html = """
        <html><head><meta property="og:description" content="ラブライブ！サンシャイン!! 沼津地元愛まつり 2025｜ラブライブ！サンシャイン!!"></head>
        <body><article>
          <div data-type="component-livetext"><div class="text-area"><a id="top" name="top"><h3 class="ke-live_text ke-live_text_01">開催概要</h3></a></div></div>
          <div data-type="component-livetext"><div class="text-area"><h4 class="ke-live_text ke-live_text_03">公演日・出演</h4></div></div>
          <div data-textblock="" data-type="component-text"><div class="text-area"><div data-textbody=""><strong>＜Day.1＞</strong><br> 2025年11月1日（土）<br> ＜昼公演＞13:00開場／14:00開演<br> 【出演】諏訪ななか（松浦果南役）、小林愛香（津島善子役）、降幡 愛（黒澤ルビィ役）<br><br><strong>＜Day.2＞</strong><br> 2025年11月2日（日）<br> ＜昼公演＞13:00開場／14:00開演<br> 【出演】伊波杏樹（高海千歌役）、逢田梨香子（桜内梨子役）、鈴木愛奈（小原鞠莉役）</div></div></div>
          <div data-type="component-livetext"><div class="text-area"><h4 class="ke-live_text ke-live_text_03">会場</h4></div></div>
          <div data-textblock="" data-type="component-text"><div class="text-area"><div data-textbody="">キラメッセぬまづ</div></div></div>
          <div data-type="component-livetext"><div class="text-area"><h3 class="ke-live_text ke-live_text_01">チケット情報</h3></div></div>
        </article></body></html>
        """
        let refreshed = try await refresh(html: html, url: "https://www.lovelive-anime.jp/uranohoshi/live/live_detail.php?p=jimoai2025",
                                          title: "ラブライブ！サンシャイン!! 沼津地元愛まつり 2025", franchise: .lovelive)
        XCTAssertEqual(refreshed.performances.map(\.performers), [
            ["諏訪ななか（松浦果南役）", "小林愛香（津島善子役）", "降幡 愛（黒澤ルビィ役）"],
            ["伊波杏樹（高海千歌役）", "逢田梨香子（桜内梨子役）", "鈴木愛奈（小原鞠莉役）"],
        ])
    }

    func testNijigasaki8thDivTitledCastWithIndentedContinuationAndSupport() async throws {
        // Source: https://www.lovelive-anime.jp/nijigasaki/live/live_detail.php?p=8thlive (LL11)
        let html = """
        <html><head><meta property="og:description" content="ラブライブ！虹ヶ咲学園スクールアイドル同好会 8thライブ"></head>
        <article>
          <div data-type="component-livetext"><div class="text-area"><a id="top" name="top" value="top"><h3 data-priset="1" class="ke-live_text ke-live_text_01">ライブTOP</h3></a></div></div>
          <div data-textblock="" data-type="component-text"><div class="text-area"><div data-textbody=""><strong>＜大阪公演＞</strong><br> 【日程】Day.1　2026年6月6日（土）16:00開場／17:00開演<br> 【会場】大阪城ホール<br> 【出演】虹ヶ咲学園スクールアイドル同好会<br><br><strong>＜東京公演＞</strong><br> 【日程】Day.1　2026年6月13日（土）16:00開場／17:00開演<br> 【会場】京王アリーナ TOKYO<br> 【出演】虹ヶ咲学園スクールアイドル同好会</div></div></div>
          <div data-type="component-livetext"><div class="text-area"><div data-priset="1" class="ke-live_text ke-live_text_01">出演</div></div></div>
          <div data-textblock="" data-type="component-text"><div class="text-area"><div data-textbody="">【出演】虹ヶ咲学園スクールアイドル同好会<br> 　　　大西亜玖璃（上原歩夢役）、相良茉優（中須かすみ役）、<br> 　　　法元明菜（鐘 嵐珠役）<br> 【応援出演】矢野妃菜喜（高咲 侑役）</div></div></div>
          <div data-type="component-livetext"><div class="text-area"><div data-priset="1" class="ke-live_text ke-live_text_01">チケット料金</div></div></div>
          <div data-textblock="" data-type="component-text"><div class="text-area"><div data-textbody="">全席指定：13,500円（税込）<br>※完全見切れ席はステージ裏側にあるため、出演者・ステージを直接ご覧いただけないお席となります。</div></div></div>
          <div class="ticket" data-target="ticket"><div data-type="component-livetext"><a id="ticket" name="ticket"><h3 class="ke-live_text ke-live_text_01">チケット情報</h3></a></div></div>
        </article></html>
        """
        let refreshed = try await refresh(html: html, url: "https://www.lovelive-anime.jp/nijigasaki/live/live_detail.php?p=8thlive",
                                          title: "ラブライブ！虹ヶ咲学園スクールアイドル同好会 8th Live! TOKIMEKI Express", franchise: .lovelive)
        XCTAssertEqual(refreshed.performances.map(\.localDate), ["2026-06-06", "2026-06-13"])
        XCTAssertTrue(refreshed.performances.allSatisfy {
            $0.performers == ["虹ヶ咲学園スクールアイドル同好会", "大西亜玖璃（上原歩夢役）", "相良茉優（中須かすみ役）", "法元明菜（鐘 嵐珠役）", "矢野妃菜喜（高咲 侑役）"]
        })
    }

    func testFlowerLiveSiblingCastHeadingSplitsUnitsByDayAndKeepsSupportOnBoth() async throws {
        // Source: https://www.lovelive-anime.jp/nijigasaki/live/live_detail.php?p=flower_live (LL16)
        let html = """
        <html><head><meta property="og:description" content="ラブライブ！虹ヶ咲学園スクールアイドル同好会 FLOWER MUSIC LIVE"></head>
        <article>
          <div data-type="component-livetext"><div class="text-area"><a id="top" name="top" value="top"><h4 class="ke-live_text ke-live_text_03">ライブTOP</h4></a></div></div>
          <div data-textblock="" data-type="component-text"><div class="text-area"><div data-textbody="">【日程】DAY.1：2026年1月17日（土）16:00開場／17:00開演<br> 　　　DAY.2：2026年1月18日（日）15:00開場／16:00開演<br><br> 【会場】京王アリーナ TOKYO</div></div></div>
          <div data-type="component-livetext"><div class="text-area"><h4 class="ke-live_text ke-live_text_03">出演</h4></div></div>
          <div data-textblock="" data-type="component-text"><div class="text-area"><div data-textbody="">【出演】<br> 〈DAY.1〉<br> タンポポ：相良茉優（中須かすみ役）、指出毬亜（エマ・ヴェルデ役）<br> ヒナギク：田中ちえ美（天王寺璃奈役）<br><br> 〈DAY.2〉<br> アサガオ：前田佳織里（桜坂しずく役）、鬼頭明里（近江彼方役）<br><br> 【応援出演】DAY.1&amp;DAY.2 矢野妃菜喜（高咲 侑役）</div></div></div>
          <div data-type="component-livetext"><div class="text-area"><h4 class="ke-live_text ke-live_text_03">チケット料金</h4></div></div>
          <div data-textblock="" data-type="component-text"><div class="text-area"><div data-textbody="">全席指定：12,000円（税込）</div></div></div>
        </article></html>
        """
        let refreshed = try await refresh(html: html, url: "https://www.lovelive-anime.jp/nijigasaki/live/live_detail.php?p=flower_live",
                                          title: "FLOWER MUSIC LIVE『Boooooom Boooooom Bee!!』", franchise: .lovelive)
        XCTAssertEqual(refreshed.performances.map(\.dayLabel), ["DAY1", "DAY2"])
        XCTAssertEqual(refreshed.performances.map(\.performers), [
            ["相良茉優（中須かすみ役）", "指出毬亜（エマ・ヴェルデ役）", "田中ちえ美（天王寺璃奈役）", "矢野妃菜喜（高咲 侑役）"],
            ["前田佳織里（桜坂しずく役）", "鬼頭明里（近江彼方役）", "矢野妃菜喜（高咲 侑役）"],
        ])
    }

    func testFestCastDropsLinkLabelsGuestHeadingAndSupportPrefix() async throws {
        // Source: https://www.lovelive-anime.jp/special/live/live_detail.php?p=15th_lovelivefest (LL01)
        let html = """
        <html><head><meta property="og:description" content="LoveLive! Series 15th Anniversary ラブライブ！フェス｜ラブライブ！"></head>
        <body><article><div data-target="top">
          <div data-type="component-midashi"><div class="text-area"><h3>日程・会場</h3></div></div>
          <div data-type="component-text"><div class="text-area"><div data-textbody="">■日程<br>Day.1：2026年11月14日（土）14:30開場／16:30開演<br>Day.2：2026年11月15日（日）13:30開場／15:30開演<br><br>■会場<br>愛知・ <a href="https://www.nagoya-dome.co.jp/sp/access.php">バンテリンドーム ナゴヤ</a></div></div></div>
          <div data-type="component-midashi"><div class="text-area"><h3>出演者</h3></div></div>
          <div data-type="component-text"><div class="text-area"><div data-textbody=""><strong>『ラブライブ！虹ヶ咲学園スクールアイドル同好会』</strong><br>大西亜玖璃（上原歩夢役）、法元明菜（鐘 嵐珠役）<br>応援出演：矢野妃菜喜（高咲 侑役）<br><a class="link" href="https://www.lovelive-anime.jp/nijigasaki/about_nijigasaki.php">作品サイト</a></div></div></div>
          <div data-type="component-text"><div class="text-area"><div data-textbody=""><span>ゲスト出演</span><br><strong>『スクールアイドルミュージカル2026』</strong><br> 堀内まり菜（椿 ルリカ役）<br><a class="link" href="https://www.lovelive-anime.jp/musical/member.php">作品サイト</a></div></div></div>
          <div data-type="component-midashi"><div class="text-area"><h3>チケット料金</h3></div></div>
        </div></article></body></html>
        """
        let refreshed = try await refresh(html: html, url: "https://www.lovelive-anime.jp/special/live/live_detail.php?p=15th_lovelivefest",
                                          title: "LoveLive! Series 15th Anniversary ラブライブ！フェス", franchise: .lovelive)
        XCTAssertEqual(refreshed.performances.count, 2)
        XCTAssertTrue(refreshed.performances.allSatisfy {
            $0.performers == ["『ラブライブ！虹ヶ咲学園スクールアイドル同好会』", "大西亜玖璃（上原歩夢役）", "法元明菜（鐘 嵐珠役）",
                              "矢野妃菜喜（高咲 侑役）", "『スクールアイドルミュージカル2026』", "堀内まり菜（椿 ルリカ役）"]
        })
    }

    func testFilmLiveDateSubsectionsScopeCastAndSkipTalkPartBlock() async throws {
        // Source: https://www.lovelive-anime.jp/special/live/live_detail.php?p=15thzenyasai (LL02)
        let html = """
        <html><head><meta property="og:description" content="前夜祭 FILM LIVE｜ラブライブ！"></head>
        <body><article>
          <div data-type="component-livetext"><div class="text-area"><h3 class="ke-live_text ke-live_text_01">イベント概要</h3></div></div>
          <div data-textblock="" data-type="component-text"><div class="text-area"><div data-textbody=""></div></div></div>
          <div data-type="component-midashi"><div class="text-area"><h4>日程</h4></div></div>
          <div data-type="component-text"><div class="text-area"><div data-textbody="">2026年10月10日（土）<br> ＜昼公演＞13:30開場／14:30開演<br><br> 2026年10月11日（日）<br> ＜昼公演＞13:00開場／14:00開演</div></div></div>
          <div data-type="component-midashi"><div class="text-area"><h4>出演</h4></div></div>
          <div data-type="component-midashi"><div class="text-area"><h5>10日（土）公演</h5></div></div>
          <div data-type="component-text"><div class="text-area"><div data-textbody=""><strong>『スクールアイドルミュージカル』&nbsp;</strong><br> 堀内まり菜（椿&nbsp;ルリカ役）、浅井七海（皇 ユズハ役）&nbsp;<br><br> 【10日（土）トークパート出演者】<br> ●昼公演<br> 虹ヶ咲学園スクールアイドル同好会、蓮ノ空女学院スクールアイドルクラブ<br> MC：堀内まり菜（椿 ルリカ役）（「スクールアイドルミュージカル」より）</div></div></div>
          <div data-type="component-midashi"><div class="text-area"><h5>11日（日）公演</h5></div></div>
          <div data-type="component-text"><div class="text-area"><div data-textbody=""><strong>『ラブライブ！スーパースター!!』 Liella!&nbsp;</strong><br> 伊達さゆり（澁谷かのん役）、結那（ウィーン・マルガレーテ役）&nbsp;<br><br> 【11日（日）トークパート出演者】<br> ●昼公演<br> Liella!、いきづらい部！</div></div></div>
          <div data-type="component-midashi"><div class="text-area"><h4>チケット料金</h4></div></div>
          <div data-type="component-text"><div class="text-area"><div data-textbody="">全席指定：8,900円（税込）</div></div></div>
        </article></body></html>
        """
        let refreshed = try await refresh(html: html, url: "https://www.lovelive-anime.jp/special/live/live_detail.php?p=15thzenyasai",
                                          title: "前夜祭 FILM LIVE", franchise: .lovelive)
        XCTAssertEqual(refreshed.performances.map(\.localDate), ["2026-10-10", "2026-10-11"])
        XCTAssertEqual(refreshed.performances.map(\.performers), [
            ["『スクールアイドルミュージカル』", "堀内まり菜（椿 ルリカ役）", "浅井七海（皇 ユズハ役）"],
            ["『ラブライブ！スーパースター!!』 Liella!", "伊達さゆり（澁谷かのん役）", "結那（ウィーン・マルガレーテ役）"],
        ])
    }

    private func refresh(
        html: String,
        url: String,
        title: String,
        franchise: Franchise = .bangdream
    ) async throws -> LiveEventBundle {
        OfficialAuditURLProtocol.responses = [url: Data(html.utf8)]
        let event = LiveEvent(
            id: "audit-event", franchise: franchise, officialTitle: title, groups: [],
            eventType: .live, status: .unknown, primarySourceURL: url, timeZone: "Asia/Tokyo"
        )
        let empty = LiveEventBundle(
            schemaVersion: 1, publishedAt: .distantPast, event: event, stops: [],
            performances: [], ticketTiers: [], ticketRounds: [], ticketOffers: [],
            goodsCampaigns: [], mediaAssets: [], notices: [], evidence: []
        )
        return try await OfficialEventScraper(session: session(), indexURLs: [])
            .collect(event: empty, now: Self.date("2026-09-22T12:00:00Z"))
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfficialAuditURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}

private final class OfficialAuditURLProtocol: URLProtocol, @unchecked Sendable {
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
