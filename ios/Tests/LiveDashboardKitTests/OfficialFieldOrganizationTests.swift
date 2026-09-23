import XCTest
@testable import LiveDashboardKit

/// Official-page facts must land in their own columns instead of being copied
/// as one block of text: round eligibility, bundled products, ticket-benefit
/// bodies, venue/online goods fields, Love Live paid-stream tabs and venue cities.
/// Markup is trimmed from docs/audits/2026-09-22 captures.
final class OfficialFieldOrganizationTests: XCTestCase {
    override func tearDown() {
        FieldOrganizationURLProtocol.responses = [:]
        super.tearDown()
    }

    // MARK: - Ticket rounds

    func testBangDreamEligibilityKeepsOnlyTheConditionSentences() async throws {
        let html = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">MyGO!!!!! 9th LIVE</h1>
          <div class="p-live-event-detail__content c-post-content">
            <h2>日程・会場</h2><p>日程：2026年7月18日(土) 開場16:00／開演17:00<br>会場：神奈川・ぴあアリーナMM</p>
            <h2>会場チケット</h2>
            <h3>販売情報</h3>
            <h6>最速先行抽選</h6>
            <p>受付期間：2026年4月17日(金) 12:00 ～ 2026年5月10日(日) 23:59<br>
            ※MyGO!!!!! 8th Single「静降想」初回生産分に封入の申込券でご応募いただけます。<br>
            ※封入のシリアル1枚で、DAY1・DAY2いずれかにご応募いただけます。<br>
            ※本公演は顔認証入場システムを利用したチケット販売です。<br>
            <a href="https://eplus.jp/mygo-9th/">受付はこちら</a></p>
          </div>
        </article>
        """
        let refreshed = try await refresh(html: html, url: "https://bang-dream.com/events/mygo_9th/", title: "MyGO!!!!! 9th LIVE")
        let round = try XCTUnwrap(refreshed.ticketRounds.first { $0.officialName == "最速先行抽選" })

        XCTAssertEqual(
            round.eligibility,
            "MyGO!!!!! 8th Single「静降想」初回生産分に封入の申込券でご応募いただけます。\n封入のシリアル1枚で、DAY1・DAY2いずれかにご応募いただけます。"
        )
        XCTAssertEqual(round.lotteryProducts, ["MyGO!!!!! 8th Single「静降想」"])
        XCTAssertFalse(round.eligibility?.contains("受付期間") ?? true)
        XCTAssertFalse(round.eligibility?.contains("顔認証") ?? true)
    }

    func testBangDreamAlternativeProductsAndListedTitlesBecomeSeparateProducts() async throws {
        let html = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">BanG Dream! 13th☆LIVE</h1>
          <div class="p-live-event-detail__content c-post-content">
            <h2>日程・会場</h2><p>日程：2026年9月19日(土) 開場16:00／開演17:00<br>会場：東京・有明アリーナ</p>
            <h2>会場チケット</h2>
            <h3>販売情報</h3>
            <h6>3DAYS通しチケット</h6>
            <p>受付期間：2026年5月1日(金) 12:00 ～ 2026年5月17日(日) 23:59<br>
            ※Poppin'Party 22nd Single「どきどきデエト」・夢限大みゅーたいぷ 4th Single「超惑星Xへの旅」いずれかの初回生産分に封入の申込券でご応募いただけます。</p>
            <h6>Roselia先行</h6>
            <p>受付期間：2026年5月1日(金) 12:00 ～ 2026年5月17日(日) 23:59<br>
            ※下記2タイトルの初回生産分に封入の申込券でご応募いただけます。<br>
            ・11/19(水)リリース　Roselia 18th Single「Steadfast Spirits」<br>
            ・12/24(水)リリース　Roselia 19th Single「Fear Nothing」<br>
            ※いずれかのCDに封入の申し込み券1枚につき1回・2枚までお申込みいただけます。</p>
          </div>
        </article>
        """
        let refreshed = try await refresh(html: html, url: "https://bang-dream.com/events/13th-live/", title: "BanG Dream! 13th☆LIVE")

        let through = try XCTUnwrap(refreshed.ticketRounds.first { $0.officialName == "3DAYS通しチケット" })
        XCTAssertEqual(through.lotteryProducts, ["Poppin'Party 22nd Single「どきどきデエト」", "夢限大みゅーたいぷ 4th Single「超惑星Xへの旅」"])

        let listed = try XCTUnwrap(refreshed.ticketRounds.first { $0.officialName == "Roselia先行" })
        XCTAssertEqual(listed.lotteryProducts, ["Roselia 18th Single「Steadfast Spirits」", "Roselia 19th Single「Fear Nothing」"])
        XCTAssertEqual(
            listed.eligibility,
            "下記2タイトルの初回生産分に封入の申込券でご応募いただけます。\nいずれかのCDに封入の申し込み券1枚につき1回・2枚までお申込みいただけます。"
        )
    }

    func testLoveLiveEligibilityIsTheBundledTicketLineAndProductIsReadFromThePrecedingLine() async throws {
        let html = """
        <article>
          <div data-target="top">
            <h3>日程</h3><p>DAY1 2026年1月24日(土) 開場16:00／開演17:00<br>DAY2 2026年1月25日(日) 開場15:00／開演16:00</p>
            <h3>会場</h3><p>京王アリーナ TOKYO</p>
          </div>
          <div class="ticket" data-target="ticket">
          <strong>＜最速先行抽選＞</strong><br>
          2025年8月6日（水）発売<br>
          <a href="https://www.lovelive-anime.jp/nijigasaki/discography/">NIJIGAKU Monthly Songs♪8月度シングル 天王寺璃奈「SUMMER WARNING」</a><br>
          初回生産分限定封入特典・チケット最速先行抽選申込券にて受付<br>
          ■受付期間：2025年8月6日（水）12:00～9月7日（日）23:59<br>
          ■当落発表：2025年9月13日（土）13:00～<br>
          ■入金期間：2025年9月13日（土）13:00～9月16日（火）21:00<br>
          ※枚数制限：『シリアルNo.』1つにつき、各公演それぞれに4枚までお申込み可能（複数公演申込可能）<br>
          </div>
        </article>
        """
        let refreshed = try await refresh(
            html: html, url: "https://www.lovelive-anime.jp/nijigasaki/live/live_detail.php?p=flowerlive",
            title: "FLOWER MUSIC LIVE", franchise: .lovelive
        )
        let round = try XCTUnwrap(refreshed.ticketRounds.first { $0.officialName.hasPrefix("最速先行抽選") })

        XCTAssertEqual(round.eligibility, "初回生産分限定封入特典・チケット最速先行抽選申込券にて受付")
        XCTAssertEqual(round.lotteryProducts, ["NIJIGAKU Monthly Songs♪8月度シングル 天王寺璃奈「SUMMER WARNING」"])
        XCTAssertEqual(round.quantityLimit, "『シリアルNo.』1つにつき、各公演それぞれに4枚までお申込み可能（複数公演申込可能）")
        XCTAssertEqual(refreshed.performances.map(\.venueCity), ["東京", "東京"])
    }

    // MARK: - Ticket benefits

    func testTicketBenefitBodyStopsBeforeContactAndGuideLines() async throws {
        let html = """
        <article>
          <div data-target="top">
            <h3>日程</h3><p>2026年9月19日（土） 開場16:00／開演17:00</p>
            <h3>会場</h3><p>東京・Zepp Haneda</p>
            <h3>チケット料金</h3><p>全席指定（グッズ付き）：13,500円（税込）</p>
            <h3>Day.1 アップグレードチケット購入特典グッズデザイン</h3>
            <p>Day.1 ライブTシャツ（表）<br>Day.1 ライブTシャツ（裏）<br>Day.1 リストバンド<br>
            ※別途送料がかかります。<br>
            --------------------<br>
            【公演に関するお問い合わせ先】<br>
            インフォメーションデスク https://information-desk.info/<br>
            ▼スマチケご利用ガイドはこちら<br>
            https://eplus.jp/smaticke/</p>
          </div>
        </article>
        """
        let refreshed = try await refresh(
            html: html, url: "https://www.lovelive-anime.jp/lovehigh/live/live_detail.php?p=2nd",
            title: "いきづらい部！ 2nd LIVE", franchise: .lovelive
        )
        let benefit = try XCTUnwrap(refreshed.ticketBenefits.first)

        XCTAssertEqual(benefit.detail, "Day.1 ライブTシャツ（表）\nDay.1 ライブTシャツ（裏）\nDay.1 リストバンド")
        XCTAssertEqual(benefit.notes, "※別途送料がかかります。")
        XCTAssertFalse(benefit.detail?.contains("お問い合わせ") ?? true)
        XCTAssertFalse(benefit.detail?.contains("スマチケ") ?? true)
    }

    // MARK: - Goods

    func testVenueGoodsFieldsAreOrganizedAndShareLinksAreDropped() async throws {
        let html = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">Morfonica LIVE「Movement」</h1>
          <div class="p-live-event-detail__content c-post-content">
            <h2>日程・会場</h2><p>日程：2026年9月22日(火･祝) 開場17:00／開演18:00<br>会場：TACHIKAWA STAGE GARDEN</p>
            <h2>グッズ情報</h2>
            <h3>会場グッズ販売について</h3>
            <h4>販売場所</h4><p>TACHIKAWA STAGE GARDEN 1階 ロビー</p>
            <h4>販売日時</h4>
            <p>2026年9月22日(火･祝)<br>・先行物販　：12:00～16:30<br>・開場後物販：17:00～18:00<br>
            ※先行物販はチケットをお持ちでないお客様もご利用いただけます。<br>
            ※終演後の販売はございません。<br>
            ※販売の開始、終了時間等は当日の状況によって変更する場合がございます。</p>
            <h4>購入制限について</h4>
            <p>お一人様1会計あたり各種【3個】までのご購入とさせていただきます。<br>
            ※トレーディング商品につきましては3BOX(相当分PACK数)までとさせていただきます。<br>
            ※当日の状況によっては、急遽購入数制限を変更する場合がございます。<br>
            多くのお客様のお手元に届くように、ご理解とご協力をよろしくお願いいたします。</p>
            <h4>お支払い方法</h4>
            <p>※お会計は現金のほか、以下が利用可能です。<br>
            ・クレジットカード決済【VISA/Mastercard/JCB】<br>
            ・QRコード決済【PayPay/au PAY】<br>
            ※クレジットカードのお支払い方法は「一括払い」のみとさせていただきます。</p>
            <p><a href="https://x.com/Bushi_goods">＠Bushi_goods</a>
            <a href="https://twitter.com/intent/tweet?url=https://bang-dream.com/events/morfonica_live_2026/&text=Morfonica">ツイート</a>
            <a href="https://social-plugins.line.me/lineit/share?url=https://bang-dream.com/events/morfonica_live_2026/">LINE</a></p>
            <h3>グッズ通販</h3>
            <p>2026年8月21日(金) 15:00より受付開始<br><a href="https://bushiroad-store.com/pages/morfonica_live_2026">https://bushiroad-store.com/pages/morfonica_live_2026</a></p>
          </div>
        </article>
        """
        let refreshed = try await refresh(html: html, url: "https://bang-dream.com/events/morfonica_live_2026/", title: "Morfonica LIVE「Movement」")
        let venue = try XCTUnwrap(refreshed.goodsCampaigns.first { $0.officialName == "会場グッズ販売について" })

        XCTAssertEqual(venue.channel, .venue)
        XCTAssertEqual(venue.location, "TACHIKAWA STAGE GARDEN 1階 ロビー")
        XCTAssertEqual(venue.pickupWindow, "2026年9月22日(火･祝)\n・先行物販　：12:00～16:30\n・開場後物販：17:00～18:00")
        XCTAssertEqual(venue.requiresTicket, false)
        XCTAssertEqual(venue.purchaseLimit, "お一人様1会計あたり各種【3個】までのご購入とさせていただきます。\nトレーディング商品につきましては3BOX(相当分PACK数)までとさせていただきます。")
        XCTAssertEqual(venue.paymentMethods, "現金、クレジットカード（VISA/Mastercard/JCB）、QRコード決済（PayPay/au PAY）　※クレジットカードは一括払いのみ")
        XCTAssertEqual(venue.links.map(\.label), ["＠Bushi_goods"])
        XCTAssertFalse(venue.links.contains { $0.url.contains("intent/tweet") || $0.url.contains("line.me") })

        let online = try XCTUnwrap(refreshed.goodsCampaigns.first { $0.officialName == "グッズ通販" })
        XCTAssertEqual(online.channel, .online)
        XCTAssertEqual(online.url, "https://bushiroad-store.com/pages/morfonica_live_2026")
        XCTAssertNil(online.pickupWindow)
    }

    func testLoveLiveGoodsRoundsSplitPerReceptionAndNoticesExtendTheVenueCampaign() async throws {
        let html = """
        <article>
          <div data-target="top">
            <h3>日程</h3><p>2026年9月5日（土） 開場16:00／開演17:00</p>
            <h3>会場</h3><p>神奈川・ぴあアリーナMM</p>
            <h3>グッズ情報</h3>
            <p><a href="https://lovelive.fannect.jp/collections/ll-46-02">lovelive.fannect.jp</a><br>
            ■事前通販受付<br>
            2026年6月8日(月)18:00~6月21日(日)23:59<br>
            ※8月下旬以降順次発送、9月5日(土)公演前のお届け予定<br>
            ※各商品お1人様あたりの注文点数制限を設定しております。<br>
            ■事後通販受付<br>
            2026年9月8日(火)18:00～9月14日(月)23:59<br>
            ※9月下旬以降順次発送予定<br>
            ※ご注文は受付期間内お1人様1回のみとさせていただきます。</p>
            <h3>会場でのグッズ販売について</h3>
            <p>公演当日、会場にてグッズ販売を実施いたします。<br>販売場所：ぴあアリーナMM 2F ロビー</p>
            <h3>グッズ販売時の個数制限について</h3>
            <p>お1人様1会計あたり各種2点までとさせていただきます。<br>※当日の状況によっては変更する場合がございます。</p>
            <h3>本会場グッズ販売クイックオーダーシステムのご案内</h3>
            <p><a href="https://qo-kun.com/lovelive-yuigaoka/">https://qo-kun.com/lovelive-yuigaoka/</a></p>
            <h3>グッズ販売に関するご注意</h3>
            <p>※転売目的でのご購入はお断りいたします。</p>
          </div>
        </article>
        """
        let refreshed = try await refresh(
            html: html, url: "https://www.lovelive-anime.jp/yuigaoka/live/live_detail.php?p=taiikusai",
            title: "Liella! 結女体育祭", franchise: .lovelive
        )
        let names = refreshed.goodsCampaigns.map(\.officialName)

        // グッズ情報 stays as the catalog record (store link + gallery); the two
        // receptions become dated rounds; the notices never become campaigns.
        XCTAssertEqual(Set(names), ["グッズ情報", "事前通販受付", "事後通販受付", "会場でのグッズ販売について"])
        let catalog = try XCTUnwrap(refreshed.goodsCampaigns.first { $0.officialName == "グッズ情報" })
        XCTAssertEqual(catalog.url, "https://lovelive.fannect.jp/collections/ll-46-02")
        XCTAssertNil(catalog.salesStartAt)
        let pre = try XCTUnwrap(refreshed.goodsCampaigns.first { $0.officialName == "事前通販受付" })
        XCTAssertEqual(pre.phase, .pre)
        XCTAssertEqual(pre.channel, .online)
        XCTAssertEqual(pre.salesStartAt, Self.date("2026-06-08T09:00:00Z"))
        XCTAssertEqual(pre.salesEndAt, Self.date("2026-06-21T14:59:00Z"))
        XCTAssertEqual(pre.shippingNote, "8月下旬以降順次発送、9月5日(土)公演前のお届け予定")
        XCTAssertEqual(pre.url, "https://lovelive.fannect.jp/collections/ll-46-02")

        let post = try XCTUnwrap(refreshed.goodsCampaigns.first { $0.officialName == "事後通販受付" })
        XCTAssertEqual(post.phase, .post)
        XCTAssertEqual(post.salesStartAt, Self.date("2026-09-08T09:00:00Z"))
        XCTAssertEqual(post.purchaseLimit, "ご注文は受付期間内お1人様1回のみとさせていただきます。")

        let venue = try XCTUnwrap(refreshed.goodsCampaigns.first { $0.officialName == "会場でのグッズ販売について" })
        XCTAssertEqual(venue.channel, .venue)
        XCTAssertEqual(venue.location, "ぴあアリーナMM 2F ロビー")
        XCTAssertEqual(venue.purchaseLimit, "お1人様1会計あたり各種2点までとさせていただきます。")
        XCTAssertTrue(venue.links.contains { $0.url == "https://qo-kun.com/lovelive-yuigaoka/" })
    }

    // MARK: - Streams

    func testLoveLiveStreamingTabYieldsOnePerDayOfferScopedToItsPerformance() async throws {
        let html = """
        <article>
          <div data-target="top">
            <h3>日程</h3><p>Day.1 2026年9月19日（土） 開場16:00／開演17:00<br>Day.2 2026年9月20日（日） 開場15:00／開演16:00</p>
            <h3>会場</h3><p>東京・Zepp Haneda</p>
          </div>
          <div data-target="streaming">
            ＜有料生配信＞<br>
            【生配信日程】<br>
            Day.1　2026年9月19日（土）17:00開演<br>
            Day.2　2026年9月20日（日）16:00開演<br>
            【アーカイブ期間】<br>
            Day.1　2026年9月19日（土）22:30～9月26日（土）23:59<br>
            Day.2　2026年9月20日（日）22:30～9月27日（日）23:59<br>
            【有料生配信　チケット料金】<br>
            ・1公演視聴券：6,000円（税込）<br>
            【販売期間】<br>
            Day.1　2026年9月10日（木）18:00～9月26日（土）21:00<br>
            Day.2　2026年9月10日（木）18:00～9月27日（日）21:00<br>
            ＜イープラス＞<br>
            URL： <a href="https://eplus.jp/ikizulive_2nd_ol/">https://eplus.jp/ikizulive_2nd_ol/</a><br>
            ＜チケットぴあ＞<br>
            URL： <a href="https://w.pia.jp/t/ikizulive-2nd/">https://w.pia.jp/t/ikizulive-2nd/</a><br>
            【配信視聴チケットについてのお問合せ先】<br>
            ■Streaming＋視聴に関するお問合せ <a href="https://eplus.jp/sf/guide/streamingplus-userguide/qa">https://eplus.jp/sf/guide/streamingplus-userguide/qa</a><br>
          </div>
        </article>
        """
        let refreshed = try await refresh(
            html: html, url: "https://www.lovelive-anime.jp/lovehigh/live/live_detail.php?p=2nd",
            title: "いきづらい部！ 2nd LIVE", franchise: .lovelive
        )
        let offers = refreshed.streamOffers.sorted { $0.officialName < $1.officialName }

        XCTAssertEqual(offers.map(\.officialName), ["1公演視聴券 Day.1", "1公演視聴券 Day.2"])
        XCTAssertTrue(offers.allSatisfy { $0.amount == MoneyAmount(minorUnits: 6000, currency: "JPY") })
        XCTAssertTrue(offers.allSatisfy { $0.platform == "Streaming+" && $0.url == "https://eplus.jp/ikizulive_2nd_ol/" })
        XCTAssertEqual(offers[0].salesStartAt, Self.date("2026-09-10T09:00:00Z"))
        XCTAssertEqual(offers[0].salesEndAt, Self.date("2026-09-26T12:00:00Z"))
        XCTAssertEqual(offers[1].salesEndAt, Self.date("2026-09-27T12:00:00Z"))
        XCTAssertEqual(offers[0].archiveAvailableUntil, Self.date("2026-09-26T14:59:00Z"))
        XCTAssertEqual(offers[1].archiveAvailableUntil, Self.date("2026-09-27T14:59:00Z"))

        let day1 = try XCTUnwrap(refreshed.performances.first { $0.dayLabel == "DAY1" })
        let day2 = try XCTUnwrap(refreshed.performances.first { $0.dayLabel == "DAY2" })
        XCTAssertEqual(offers[0].scope, .performances(performanceIDs: [day1.id]))
        XCTAssertEqual(offers[1].scope, .performances(performanceIDs: [day2.id]))
    }

    // MARK: - Review cases

    func testGoodsCampaignIDsStayStableAcrossRefreshesWhenSectionsShareOneLink() async throws {
        let html = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">Shared Link Live</h1>
          <div class="p-live-event-detail__content c-post-content">
            <h2>日程・会場</h2><p>日程：2026年9月22日(火) 開場17:00／開演18:00<br>会場：東京・Zepp Shinjuku</p>
            <h2>グッズ情報</h2>
            <h3>会場グッズ販売について</h3>
            <p><a href="https://x.com/Bushi_goods">＠Bushi_goods</a><br>販売場所：Zepp Shinjuku 1F<br>2026年9月22日(火) 12:00～16:30</p>
            <h3>グッズ通販</h3>
            <p><a href="https://x.com/Bushi_goods">＠Bushi_goods</a><br>2026年8月21日(金) 15:00より受付開始<br><a href="https://bushiroad-store.com/pages/shared">通販ページ</a></p>
          </div>
        </article>
        """
        let url = "https://bang-dream.com/events/shared-link/"
        let first = try await refresh(html: html, url: url, title: "Shared Link Live")
        let second = try await refresh(html: html, url: url, title: "Shared Link Live", existing: first)
        let third = try await refresh(html: html, url: url, title: "Shared Link Live", existing: second)

        XCTAssertEqual(first.goodsCampaigns.count, 2)
        XCTAssertEqual(second.goodsCampaigns.count, 2)
        XCTAssertEqual(third.goodsCampaigns.count, 2)
        XCTAssertEqual(Set(first.goodsCampaigns.map(\.id)), Set(second.goodsCampaigns.map(\.id)))
        XCTAssertEqual(Set(second.goodsCampaigns.map(\.id)), Set(third.goodsCampaigns.map(\.id)))
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: third.goodsCampaigns.map { ($0.officialName, $0.id) }),
            Dictionary(uniqueKeysWithValues: first.goodsCampaigns.map { ($0.officialName, $0.id) })
        )
    }

    func testStreamSalesWindowAppliesToEveryTierAndThroughPassIsNotSplitPerDay() async throws {
        let html = """
        <article>
          <div data-target="top">
            <h3>日程</h3><p>Day.1 2026年9月19日（土） 開場16:00／開演17:00<br>Day.2 2026年9月20日（日） 開場15:00／開演16:00</p>
            <h3>会場</h3><p>東京・Zepp Haneda</p>
          </div>
          <div data-target="streaming">
            【アーカイブ期間】<br>
            Day.1　2026年9月19日（土）22:30～9月26日（土）23:59<br>
            Day.2　2026年9月20日（日）22:30～9月27日（日）23:59<br>
            【チケット料金】<br>
            ・1公演視聴券：6,000円（税込）<br>
            ・2公演通し視聴券：10,000円（税込）<br>
            【販売期間】<br>
            2026年9月10日（木）18:00～9月27日（日）21:00<br>
            ＜イープラス＞<br>
            URL： <a href="https://eplus.jp/test_ol/">https://eplus.jp/test_ol/</a><br>
          </div>
        </article>
        """
        let refreshed = try await refresh(
            html: html, url: "https://www.lovelive-anime.jp/lovehigh/live/live_detail.php?p=multi",
            title: "Multi tier", franchise: .lovelive
        )
        let offers = refreshed.streamOffers.sorted { $0.officialName < $1.officialName }

        XCTAssertEqual(offers.map(\.officialName), ["1公演視聴券 Day.1", "1公演視聴券 Day.2", "2公演通し視聴券"])
        XCTAssertTrue(offers.allSatisfy { $0.salesStartAt == Self.date("2026-09-10T09:00:00Z") && $0.salesEndAt == Self.date("2026-09-27T12:00:00Z") })
        let through = try XCTUnwrap(offers.last)
        XCTAssertEqual(through.amount, MoneyAmount(minorUnits: 10_000, currency: "JPY"))
        XCTAssertEqual(through.archiveAvailableUntil, Self.date("2026-09-27T14:59:00Z"))
        XCTAssertEqual(through.scope, .performances(performanceIDs: refreshed.performances.map(\.id)))
    }

    func testBenefitBodyKeepsItemsWhenItOpensWithAHeadingLine() async throws {
        let html = """
        <article>
          <div data-target="top">
            <h3>日程</h3><p>2026年9月19日（土） 開場16:00／開演17:00</p>
            <h3>会場</h3><p>東京・Zepp Haneda</p>
            <h3>グッズ付きチケット特典</h3>
            <p>【特典内容】<br>特製Tシャツ<br>特製タオル<br>※デザインは後日公開いたします。</p>
          </div>
        </article>
        """
        let refreshed = try await refresh(
            html: html, url: "https://www.lovelive-anime.jp/lovehigh/live/live_detail.php?p=benefit",
            title: "Benefit", franchise: .lovelive
        )
        let benefit = try XCTUnwrap(refreshed.ticketBenefits.first)

        XCTAssertEqual(benefit.detail, "特製Tシャツ\n特製タオル")
        XCTAssertEqual(benefit.notes, "※デザインは後日公開いたします。")
        XCTAssertEqual(benefit.status, .confirmed)
    }

    func testNegatedSerialSentenceIsNotAnEligibility() async throws {
        let html = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">General Sale Live</h1>
          <div class="p-live-event-detail__content c-post-content">
            <h2>日程・会場</h2><p>日程：2026年9月22日(火) 開場17:00／開演18:00<br>会場：東京・Zepp Shinjuku</p>
            <h2>会場チケット</h2>
            <h3>販売情報</h3>
            <h6>一般発売</h6>
            <p>受付期間：2026年8月1日(土) 10:00 ～ 2026年9月20日(日) 23:59<br>
            ※シリアルナンバーの入力は不要です。<br>
            <a href="https://eplus.jp/general/">受付はこちら</a></p>
          </div>
        </article>
        """
        let refreshed = try await refresh(html: html, url: "https://bang-dream.com/events/general-sale/", title: "General Sale Live")
        let round = try XCTUnwrap(refreshed.ticketRounds.first { $0.officialName == "一般発売" })

        XCTAssertNil(round.eligibility)
        XCTAssertEqual(round.lotteryProducts, [])
    }

    // MARK: - Helpers

    private func refresh(html: String, url: String, title: String, franchise: Franchise = .bangdream, existing: LiveEventBundle? = nil) async throws -> LiveEventBundle {
        FieldOrganizationURLProtocol.responses[url] = Data(html.utf8)
        let event = LiveEvent(
            id: "field-organization", franchise: franchise, officialTitle: title, groups: [],
            eventType: .live, status: .unknown, primarySourceURL: url, timeZone: "Asia/Tokyo"
        )
        let empty = LiveEventBundle(
            schemaVersion: 1, publishedAt: .distantPast, event: event, stops: [],
            performances: [], ticketTiers: [], ticketRounds: [], ticketOffers: [],
            goodsCampaigns: [], mediaAssets: [], notices: [], evidence: []
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FieldOrganizationURLProtocol.self]
        return try await OfficialEventScraper(session: URLSession(configuration: configuration), indexURLs: [])
            .collect(event: existing ?? empty, now: Self.date("2026-09-22T12:00:00Z"))
    }

    private static func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}

private final class FieldOrganizationURLProtocol: URLProtocol, @unchecked Sendable {
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
