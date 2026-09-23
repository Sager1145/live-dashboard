import XCTest
@testable import LiveDashboardKit

/// Structured ticket-round fields (applyWindowText / resultText / paymentWindowText /
/// quantityLimit / lotteryProducts / applicationTarget / notes) and link role
/// classification, exercised against trimmed real markup from
/// docs/audits/2026-09-22 (BanG Dream 13954-mygo_9th.html, Love Live LL12.html).
final class TicketRoundFieldParsingTests: XCTestCase {
    override func tearDown() {
        TicketFieldsURLProtocol.responses = [:]
        super.tearDown()
    }

    // MARK: - 1. Love Live block

    func testLoveLiveTicketRoundsCaptureStructuredFieldsAndNotes() async throws {
        let html = """
        <article>
          <div data-target="top">
            <h3>日程</h3><p>2026年3月7日(土) 開場17:00／開演18:00</p>
            <h3>会場</h3><p>東京・Test Hall</p>
          </div>
          <div class="ticket" data-target="ticket">
          <strong><u>＜最速先行抽選＞</u></strong><br>
          <s>★申込対象：＜Bloom Stage／福岡公演＞<br>
          2026年1月28日（水）発売<br>
          蓮ノ空女学院スクールアイドルクラブ 9thシングル<br>
          「Echoes Beyond」<br>
          封入申込券にて受付<br>
          ----------<br>
          ■受付期間：2026年1月28日（水）12:00～3月1日（日）23:59<br>
          ■当落発表：2026年3月7日（土）13:00～<br>
          ■入金期間：2026年3月7日（土）13:00～3月10日（火）21:00<br>
          ※枚数制限：『シリアルNo.』1つにつき、＜Bloom Stage／福岡公演＞に2枚までお申込み可能。（複数公演申込可能）</s><br>
          ----------<br>
          <s>★申込対象：＜Bloom Garden Party Stage／埼玉Day.1公演＞<br>
          2026年4月8日（水）発売<br>
          スリーズブーケ 7thシングル「不思議と君とライブラリー」<br>
          DOLLCHESTRA 7thシングル「アイシイ」<br>
          みらくらぱーく6thシングル「トモダチになれる場所」<br>
          Edel Note 3rdシングル「EdelinieN」<br>
          封入申込券にて受付<br>
          ----------<br>
          ■受付期間：2026年4月8日（水）12:00～4月26日（日）23:59</s><br>
          <strong><u>＜二次先行抽選＞</u></strong><br>
          ★申込対象：＜Bloom Garden Party Stage／埼玉公演＞<br>
          下記いずれかのシリアルをお持ちの方は二次先行にお申込みいただけます。<br>
          ①『映画 ラブライブ！蓮ノ空女学院スクールアイドルクラブ Bloom Garden Party』入場者プレゼント第１弾・二次先行抽選申込券<br>
          ②ラブライブ！オフィシャルカードゲーム プレミアムブースター・二次先行抽選申込券<br>
          ③LoveLive!Days6月号・二次先行抽選申込券<br>
          ----------<br>
          ■受付期間：2026年3月15日（日）12:00～3月22日（日）23:59<br>
          <strong><u>＜一般発売（一次抽選）＞</u></strong><br>
          ★申込対象：＜Bloom Stage／福岡公演＞<br>
          ----------<br>
          ■受付URL：<a href="https://eplus.jp/hasunosora6th/">https://eplus.jp/hasunosora6th/</a><br>
          ■受付期間：2026年3月7日（土）12:00～3月22日（日）23:59<br>
          ■当落発表：2026年3月28日（土）13:00～<br>
          ■入金期間：2026年3月28日（土）13:00～3月31日（火）21:00<br>
          ※枚数制限：＜Bloom Stage／福岡公演＞各公演それぞれに2枚までお申込み可能。（複数公演申込可能）<br>
          ※本受付では全席指定、U-20割引チケットの2券種を販売いたします。<br>
          ※クレジットカード決済のみ受付となります。<br>
          <strong><u>＜一般発売（先着）＞</u></strong><br>
          ★申込対象：＜Party Stage／神奈川公演＞<br>
          ----------<br>
          ■受付URL：<a href="https://eplus.jp/hasunosora6th/">https://eplus.jp/hasunosora6th/</a><br>
          ■発売日：<br>
          Day.1　2026年7月11日（土）0:00～<br>
          Day.2　2026年7月12日（日）0:00～<br>
          【電子チケットのお申込みについて】<br>
          チケットのお受取はイープラス電子チケット「スマチケ」となります。<br>
          ▼スマチケご利用ガイドはこちら<br>
          <a href="https://eplus.jp/sf/guide/spticket">https://eplus.jp/sf/guide/spticket</a><br>
          【同行者登録に関して】<br>
          2枚お申込みの場合は、お申込み前に同行者登録の手続きが必要となります。<br>
          ■同行者登録とは？<br>
          <a href="https://eplus.jp/sf/guide/fellow-ep/">同行者登録とは</a><br>
          ■【同行者登録】手続きはこちら<br>
          <a href="https://member.eplus.jp/update-dokosha">同行者登録手続き</a><br>
          ●注意事項●<br>
          ※お申込み時にイープラスの会員登録（無料）が必要です。<br>
          ※顔認証入場システムを利用したチケット販売のため、顔写真登録が必要となります。必ず来場者ご本人様がお申込みください。<br>
          ※顔認証入場システムでご本人と判断できない場合、顔写真付きの公的身分証でご本人確認をさせていただきますので、必ずご持参ください。<br>
          <a href="https://eplus.jp/faceticket_about/">顔認証入場システムについて</a>
          </div>
        </article>
        """

        let refreshed = try await refresh(html: html, url: "https://www.lovelive-anime.jp/hasunosora/live-event/6th/", title: "Hasunosora 6th Single Release Live", franchise: .lovelive)
        let rounds = refreshed.ticketRounds

        XCTAssertEqual(rounds.map(\.officialName), [
            "最速先行抽選（Bloom Stage／福岡公演）",
            "最速先行抽選（Bloom Garden Party Stage／埼玉Day.1公演）",
            "二次先行抽選（Bloom Garden Party Stage／埼玉公演）",
            "一般発売（一次抽選）（Bloom Stage／福岡公演）",
            "一般発売（先着）（Party Stage／神奈川公演）",
        ])

        let firstBlock = try XCTUnwrap(rounds.first { $0.officialName == "最速先行抽選（Bloom Stage／福岡公演）" })
        XCTAssertEqual(firstBlock.lotteryProducts, ["蓮ノ空女学院スクールアイドルクラブ 9thシングル 「Echoes Beyond」"])
        XCTAssertEqual(firstBlock.applyWindowText, "2026年1月28日（水）12:00～3月1日（日）23:59")
        XCTAssertEqual(firstBlock.resultText, "2026年3月7日（土）13:00～")
        XCTAssertEqual(firstBlock.paymentWindowText, "2026年3月7日（土）13:00～3月10日（火）21:00")
        XCTAssertEqual(firstBlock.quantityLimit, "『シリアルNo.』1つにつき、＜Bloom Stage／福岡公演＞に2枚までお申込み可能。（複数公演申込可能）")
        XCTAssertEqual(firstBlock.paymentStartAt, Self.date("2026-03-07T04:00:00Z"))
        XCTAssertEqual(firstBlock.paymentDeadlineAt, Self.date("2026-03-10T12:00:00Z"))
        XCTAssertEqual(firstBlock.officialStatus, "受付終了")
        XCTAssertNil(firstBlock.applyURL)

        let secondBlock = try XCTUnwrap(rounds.first { $0.officialName == "最速先行抽選（Bloom Garden Party Stage／埼玉Day.1公演）" })
        XCTAssertEqual(secondBlock.lotteryProducts, [
            "スリーズブーケ 7thシングル「不思議と君とライブラリー」",
            "DOLLCHESTRA 7thシングル「アイシイ」",
            "みらくらぱーく6thシングル「トモダチになれる場所」",
            "Edel Note 3rdシングル「EdelinieN」",
        ])
        XCTAssertEqual(secondBlock.officialStatus, "受付終了")

        let secondaryLottery = try XCTUnwrap(rounds.first { $0.officialName == "二次先行抽選（Bloom Garden Party Stage／埼玉公演）" })
        XCTAssertEqual(secondaryLottery.lotteryProducts, [
            "『映画 ラブライブ！蓮ノ空女学院スクールアイドルクラブ Bloom Garden Party』入場者プレゼント第１弾・二次先行抽選申込券",
            "ラブライブ！オフィシャルカードゲーム プレミアムブースター・二次先行抽選申込券",
            "LoveLive!Days6月号・二次先行抽選申込券",
        ])
        XCTAssertNotEqual(secondaryLottery.officialStatus, "受付終了")

        let generalLottery = try XCTUnwrap(rounds.first { $0.officialName == "一般発売（一次抽選）（Bloom Stage／福岡公演）" })
        XCTAssertEqual(generalLottery.applyURL, "https://eplus.jp/hasunosora6th/")
        XCTAssertNotEqual(generalLottery.officialStatus, "受付終了")
        XCTAssertTrue(generalLottery.notes.contains { $0.kind == .creditCardOnly })

        let firstComeBlock = try XCTUnwrap(rounds.first { $0.officialName == "一般発売（先着）（Party Stage／神奈川公演）" })
        XCTAssertEqual(firstComeBlock.kind, .firstComeFirstServed)
        XCTAssertEqual(firstComeBlock.applyURL, "https://eplus.jp/hasunosora6th/")
        XCTAssertEqual(firstComeBlock.applyWindowText, "Day.1\u{3000}2026年7月11日（土）0:00～\nDay.2\u{3000}2026年7月12日（日）0:00～")
        XCTAssertEqual(firstComeBlock.applyStartAt, Self.date("2026-07-10T15:00:00Z"))
        XCTAssertNil(firstComeBlock.applyEndAt, "independent per-day sale starts are not a window")

        for round in rounds {
            let faceNote = try XCTUnwrap(round.notes.first { $0.kind == .faceRecognition }, "round \(round.officialName) missing faceRecognition note")
            XCTAssertTrue(faceNote.links.contains { $0.url.contains("faceticket_about") })

            let companionNote = try XCTUnwrap(round.notes.first { $0.kind == .companionRegistration }, "round \(round.officialName) missing companionRegistration note")
            XCTAssertTrue(companionNote.links.contains { $0.url.contains("fellow-ep") })
            XCTAssertTrue(companionNote.links.contains { $0.url.contains("update-dokosha") })

            XCTAssertTrue(round.notes.contains { $0.kind == .membershipRequired }, "round \(round.officialName) missing membershipRequired note")

            let identityNote = try XCTUnwrap(round.notes.first { $0.kind == .identityCheck }, "round \(round.officialName) missing identityCheck note")
            XCTAssertTrue(identityNote.text.contains("本人確認"))

            if round.officialName != "一般発売（一次抽選）（Bloom Stage／福岡公演）" {
                XCTAssertFalse(round.notes.contains { $0.kind == .creditCardOnly }, "round \(round.officialName) unexpectedly has creditCardOnly note")
            }
        }
    }

    func testLoveLiveTargetWordingVariantsSplitBlocksAndSectionNotesStayScoped() async throws {
        let html = """
        <article>
          <div data-target="top">
            <h3>日程</h3><p>2027年1月23日(土) 開場17:00／開演18:00</p>
            <h3>会場</h3><p>東京・Test Hall</p>
          </div>
          <div class="ticket" data-target="ticket">
          <strong>＜最速先行抽選＞</strong><br>
          ★申込対象公演：＜東京Day.1公演＞<br>
          2026年7月26日（日）発売<br>
          テストシングル「A」<br>
          封入申込券にて受付<br>
          ----------<br>
          ■受付期間：2026年7月26日（日）12:00～8月17日（月）23:59<br>
          ■当落発表：2026年8月22日（土）13:00～<br>
          ※枚数制限：『シリアルNo.』1つにつき2枚まで<br>
          ----------<br>
          ★お申込み対象：Day.2　2027年1月24日（日）公演<br>
          テストシングル「B」<br>
          封入申込券にて受付<br>
          ----------<br>
          ■受付期間：2026年9月1日（火）12:00～9月20日（日）23:59<br>
          ■当落発表：2026年9月26日（土）13:00～<br>
          ----------<br>
          受付対象公演：大阪公演DAY.1<br>
          テストシングル「C」<br>
          封入申込券にて受付<br>
          ----------<br>
          ■受付期間：2026年10月1日（木）12:00～10月26日（月）23:59<br>
          ■当落発表：2026年10月31日（土）13:00～<br>
          【ご注意】<br>
          ※お申込みには身分証明書番号の入力が必要です。<br>
          <strong>＜一般発売（先着）＞</strong><br>
          ★申込対象：＜東京Day.1公演＞<br>
          ----------<br>
          ■受付URL：<a href="https://eplus.jp/serial/test_sg/">https://eplus.jp/serial/test_sg/</a><br>
          ■発売日：2026年11月7日（土）12:00～<br>
          ※本受付では全席指定のみを販売いたします。<br>
          【電子チケットのお申込みについて】<br>
          ＜一般発売（先着）＞受付でご購入された場合、チケットのお受取はイープラス電子チケット「スマチケ」となります。顔写真登録の必要はございません。<br>
          ▼顔認証入場システムのご利用について<br>
          <a href="https://eplus.jp/faceticket_about/">https://eplus.jp/faceticket_about/</a><br>
          ●注意事項●<br>
          ※顔認証入場システムを利用したチケット販売のため、顔写真登録が必要となります。<br>
          <a href="https://eplus.jp/faceticket_about/">https://eplus.jp/faceticket_about/</a>
          </div>
        </article>
        """

        let refreshed = try await refresh(html: html, url: "https://www.lovelive-anime.jp/test/live-event/variants/", title: "Variants", franchise: .lovelive)
        let rounds = refreshed.ticketRounds

        XCTAssertEqual(rounds.map(\.officialName), [
            "最速先行抽選（東京Day.1公演）",
            "最速先行抽選（Day.2\u{3000}2027年1月24日（日）公演）",
            "最速先行抽選（大阪公演DAY.1）",
            "一般発売（先着）（東京Day.1公演）",
        ])
        XCTAssertEqual(rounds.map(\.applyWindowText), [
            "2026年7月26日（日）12:00～8月17日（月）23:59",
            "2026年9月1日（火）12:00～9月20日（日）23:59",
            "2026年10月1日（木）12:00～10月26日（月）23:59",
            "2026年11月7日（土）12:00～",
        ])
        XCTAssertEqual(rounds[0].applyEndAt, Self.date("2026-08-17T14:59:00Z"))
        XCTAssertEqual(rounds.prefix(3).map(\.lotteryProducts), [["テストシングル「A」"], ["テストシングル「B」"], ["テストシングル「C」"]])
        XCTAssertEqual(rounds[0].quantityLimit, "『シリアルNo.』1つにつき2枚まで")

        // A 【…】 block between rounds must not swallow the rounds after it.
        let firstCome = rounds[3]
        XCTAssertEqual(firstCome.kind, .firstComeFirstServed)
        XCTAssertEqual(firstCome.applyURL, "https://eplus.jp/serial/test_sg/", "an e+ serial page is an application link, not a product")

        // 身分証明書番号 in an input instruction is not an identity check.
        XCTAssertFalse(rounds.flatMap(\.notes).contains { $0.kind == .identityCheck })

        // The スマチケ sentence names ＜一般発売（先着）＞ and applies only there; the
        // negated 顔写真登録 clause never becomes a face-recognition requirement.
        XCTAssertTrue(firstCome.notes.contains { $0.kind == .smartTicketOnly })
        for round in rounds.prefix(3) {
            XCTAssertFalse(round.notes.contains { $0.kind == .smartTicketOnly }, "\(round.officialName) should not carry the 先着-only スマチケ note")
        }
        for round in rounds {
            let face = try XCTUnwrap(round.notes.first { $0.kind == .faceRecognition })
            XCTAssertFalse(face.text.contains("必要はございません"))
            XCTAssertFalse(face.text.contains("ご利用について"))
            XCTAssertEqual(face.links.map(\.url), ["https://eplus.jp/faceticket_about/"], "note links are deduplicated")
            XCTAssertFalse(round.notes.contains { $0.text.hasPrefix("【") })
        }
    }

    // MARK: - 2. BanG Dream block

    func testBangDreamTicketRoundsShareApplicationLinkAndCaptureLotteryProductAndQuantityLimit() async throws {
        let html = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">MyGO!!!!! 9th Single Release Live</h1>
          <div class="p-live-event-detail__content">
            <h2>日程</h2><p>2026年7月17日(金) 開場19:00／開演20:00</p>
            <h2>会場</h2><p>東京・Test Hall</p>
            <h2>出演</h2><p>MyGO!!!!!</p>
            <h2>チケット</h2>
            <h3>料金</h3>
            <p>S席(特製グッズ付き)：24,200円(税込)</p>
            <h3>販売情報</h3>
            <p><a href="https://eplus.jp/mygo-9th/">受付はこちら</a></p>
            <h6>プレイガイド二次先行（受付終了）</h6>
            <p>受付期間：2026年4月29日(水･祝) 12:00 ～ 2026年5月18日(月) 23:59</p>
            <p>※DAY1のS席(特製グッズ付き)の受付はございません。<br />
            ※お一人様につき、それぞれ下記枚数までお申し込みいただけます。<br />
            　S席(特製グッズ付き)：1枚まで<br />
            　A席(特製グッズ付き)：2枚まで<br />
            　一般指定席(特製グッズ付き)・一般指定席：4枚まで<br />
            ※本先行では、一部着席指定席を含みます。</p>
            <h6 class="blogparts_element blogparts_root">最速先行抽選</h6>
            <p class="blogparts_element">受付期間：2025年12月6日(土) 21:00 ～ 2026年2月2日(月) 23:59</p>
            <p class="blogparts_element">※<a href="https://bang-dream.com/discographies/4132">MyGO!!!!! 8th Single「静降想」</a>初回生産分に封入の申込券でご応募いただけます。<br />
            ※封入のシリアル1枚で、DAY1・DAY2いずれかにご応募いただけます。<br />
            　1回につき4枚までお申込みいただけます。</p>
            <h6>見切れ席・2F後方立ち見エリア発売（DAY2のみ）</h6>
            <p>受付期間：2026年7月17日(金) 20:00 ～</p>
            <p>※先着順・上限数に達し次第終了<br />
            ※スマチケのみの受付となります。<br />
            ※お一人様1公演につき4枚までお申込みいただけます。</p>
          </div>
        </article>
        """

        let refreshed = try await refresh(html: html, url: "https://bang-dream.com/events/mygo-9th/", title: "MyGO!!!!! 9th Single Release Live")
        let rounds = refreshed.ticketRounds

        let secondary = try XCTUnwrap(rounds.first { $0.officialName == "プレイガイド二次先行（受付終了）" })
        XCTAssertEqual(secondary.applyURL, "https://eplus.jp/mygo-9th/")
        XCTAssertTrue(secondary.links.contains { $0.role == .application })
        XCTAssertEqual(secondary.applyWindowText, "2026年4月29日(水･祝) 12:00 ～ 2026年5月18日(月) 23:59")
        XCTAssertEqual(secondary.quantityLimit, "お一人様につき、それぞれ下記枚数までお申し込みいただけます。\nS席(特製グッズ付き)：1枚まで\nA席(特製グッズ付き)：2枚まで\n一般指定席(特製グッズ付き)・一般指定席：4枚まで")

        let earliest = try XCTUnwrap(rounds.first { $0.officialName == "最速先行抽選" })
        XCTAssertEqual(earliest.applyURL, "https://eplus.jp/mygo-9th/")
        XCTAssertEqual(earliest.lotteryProducts, ["MyGO!!!!! 8th Single「静降想」"])
        XCTAssertTrue(earliest.links.contains { $0.url == "https://bang-dream.com/discographies/4132" && $0.role == .product })

        let smartTicketRound = try XCTUnwrap(rounds.first { $0.officialName == "見切れ席・2F後方立ち見エリア発売（DAY2のみ）" })
        XCTAssertTrue(smartTicketRound.notes.contains { $0.kind == .smartTicketOnly })
    }

    // MARK: - 3. Link classification table

    func testOfficialLinkClassifyMatchesTheDocumentedRoleTable() {
        let cases: [(label: String, url: String, role: OfficialLinkRole)] = [
            ("受付はこちら", "https://eplus.jp/mygo-9th/", .application),
            ("お問い合わせ", "https://eplus.jp/qa/", .support),
            ("お問い合わせ", "https://support.eplus.jp/", .support),
            ("同行者登録とは", "https://eplus.jp/sf/guide/fellow-ep/", .support),
            ("同行者登録手続き", "https://member.eplus.jp/update-dokosha", .support),
            ("顔認証入場システムについて", "https://eplus.jp/faceticket_about/", .support),
            ("海外先行", "https://ib.eplus.jp/mygo-9th_st", .overseasApplication),
            ("KKTIX", "https://zewgr.kktix.cc/events/x", .overseasApplication),
            ("お申込みはこちら", "https://w.pia.jp/t/hasunosora6th/", .application),
            ("ヘルプ", "https://t.pia.jp/help/", .support),
            ("MyGO!!!!! 8th Single「静降想」", "https://bang-dream.com/discographies/4132", .product),
            ("公式ストア", "https://bushiroad-store.com/pages/x", .product),
            ("アルバム封入", "https://example.com/album", .other),
            ("上海站", "https://sdp.ctrip.com/?x", .other),
            ("https://eplus.jp/serial/ppp_22ndsg/", "https://eplus.jp/serial/ppp_22ndsg/", .application),
            ("チケット購入", "https://ticket.bushiroad-music.com/order/x", .application),
            ("受付はこちら", "https://eplus.jp/garden-challenge/", .application),
            ("English", "https://w.pia.jp/a/hasunosora6th26engpls/", .overseasApplication),
            ("FamiPort", "https://kktix.link/familyMartfamiport", .other),
            ("決済申込書", "https://assets.kktix.io/x/form.pdf", .other),
        ]
        for testCase in cases {
            XCTAssertEqual(
                OfficialLink.classify(label: testCase.label, url: testCase.url), testCase.role,
                "\(testCase.label) / \(testCase.url) should classify as \(testCase.role)"
            )
        }
    }

    // MARK: - 4. Codable back-compat

    func testTicketRoundAndOfficialLinkDecodeLegacyPayloadsAndRoundTripNewFields() throws {
        let legacyLinkJSON = #"{"label":"受付はこちら","url":"https://eplus.jp/x"}"#
        let legacyLink = try LiveEventBundle.decoder.decode(OfficialLink.self, from: Data(legacyLinkJSON.utf8))
        XCTAssertNil(legacyLink.role)

        let legacyRoundJSON = """
        {"id":"r1","eventID":"e1","officialName":"抽選","kind":"lottery","scope":{"kind":"unconfirmed"},"status":"confirmed"}
        """
        let legacyRound = try LiveEventBundle.decoder.decode(TicketRound.self, from: Data(legacyRoundJSON.utf8))
        XCTAssertNil(legacyRound.applyWindowText)
        XCTAssertNil(legacyRound.resultText)
        XCTAssertNil(legacyRound.paymentStartAt)
        XCTAssertNil(legacyRound.paymentWindowText)
        XCTAssertNil(legacyRound.quantityLimit)
        XCTAssertEqual(legacyRound.lotteryProducts, [])
        XCTAssertNil(legacyRound.applicationTarget)
        XCTAssertEqual(legacyRound.notes, [])

        let fullRound = TicketRound(
            id: "r2", eventID: "e1", officialName: "一般発売", kind: .firstComeFirstServed, scope: .unconfirmed,
            applyStartAt: Self.date("2026-01-01T00:00:00Z"), applyEndAt: nil, resultAt: nil, paymentDeadlineAt: nil, eligibility: nil,
            announcementURL: nil, applyURL: "https://eplus.jp/x", overseasURL: nil, officialStatus: nil, status: .confirmed,
            links: [OfficialLink(label: "受付はこちら", url: "https://eplus.jp/x", role: .application)],
            applyWindowText: "2026年1月1日（木）12:00～", resultText: "2026年1月10日（土）13:00～",
            paymentStartAt: Self.date("2026-01-11T00:00:00Z"), paymentWindowText: "2026年1月11日（日）～2026年1月15日（木）",
            quantityLimit: "1枚まで", lotteryProducts: ["Sample Single"], applicationTarget: "東京公演",
            notes: [TicketNote(kind: .smartTicketOnly, text: "スマチケのみの受付となります。", links: [])]
        )
        let encoded = try LiveEventBundle.encoder.encode(fullRound)
        let decoded = try LiveEventBundle.decoder.decode(TicketRound.self, from: encoded)
        XCTAssertEqual(decoded, fullRound)
    }

    func testMultipleProductsKeepTheirOwnAndSharedApplicationLinks() async throws {
        let html = """
        <article>
        <div data-target="top"><h3>日程</h3><p>2026年10月1日(木) 開場17:00／開演18:00</p><h3>会場</h3><p>東京・Test Hall</p></div>
        <div class="ticket" data-target="ticket">
        ＜最速先行抽選＞<br>
        テストシングル「A」<br>
        <a href="https://eplus.jp/serial/a/">受付はこちら</a><br>
        <a href="https://eplus.jp/serial/a/">受付はこちら</a><br>
        テストシングル「B」<br>
        <a href="https://eplus.jp/serial/b/"><img src="button.png" alt="受付はこちら"></a><br>
        テストシングル「C」<br>
        テストシングル「D」<br>
        封入申込券にて受付<br>
        <a href="https://eplus.jp/serial/shared/">受付はこちら</a><br>
        ■受付期間：2026年8月1日(土)12:00～8月31日(月)23:59<br>
        <a href="https://eplus.jp/extra/">追加受付</a><br>
        <a href="https://ib.eplus.jp/example">Overseas tickets</a>
        </div></article>
        """
        let bundle = try await refresh(html: html, url: "https://www.lovelive-anime.jp/test/live/", title: "Test", franchise: .lovelive)
        let round = try XCTUnwrap(bundle.ticketRounds.first)
        XCTAssertEqual(round.allLotteryProducts, ["テストシングル「A」", "テストシングル「B」", "テストシングル「C」", "テストシングル「D」"])
        XCTAssertEqual(round.allApplicationLinks.count, 5)
        XCTAssertEqual(round.applicationLinks(forProduct: "テストシングル「A」").map(\.url), ["https://eplus.jp/serial/a/"])
        XCTAssertEqual(round.applicationLinks(forProduct: "テストシングル「B」").map(\.url), ["https://eplus.jp/serial/b/"])
        for name in ["テストシングル「C」", "テストシングル「D」"] {
            XCTAssertEqual(round.applicationLinks(forProduct: name).map(\.url), ["https://eplus.jp/serial/shared/"])
        }
        XCTAssertEqual(round.unassignedApplicationLinks.map(\.url), ["https://eplus.jp/extra/", "https://ib.eplus.jp/example"])
        XCTAssertEqual(try LiveEventBundle.decoder.decode(TicketRound.self, from: LiveEventBundle.encoder.encode(round)), round)
    }

    func testRepeatedRoundNamesAndMultipleBareURLsAreNotDropped() async throws {
        let html = """
        <article><div data-target="top"><h3>日程</h3><p>2026年10月1日(木) 開場17:00／開演18:00</p><h3>会場</h3><p>東京・Test Hall</p></div>
        <div class="ticket" data-target="ticket">
        ＜最速先行抽選＞<br>テストシングル「A」<br>封入申込券にて受付<br>
        ■受付期間：2026年8月1日(土)12:00～8月31日(月)23:59<br>
        ■受付URL：https://eplus.jp/a/ https://eplus.jp/a2/<br>
        ＜最速先行抽選＞<br>テストシングル「B」<br>封入申込券にて受付<br>
        ■受付期間：2026年8月1日(土)12:00～8月31日(月)23:59<br>
        ■受付URL：https://eplus.jp/b/<br>
        ＜最速先行抽選＞<br>テストシングル「A」<br>封入申込券にて受付<br>
        ■受付期間：2026年8月1日(土)12:00～8月31日(月)23:59<br>
        ■受付URL：https://eplus.jp/another-a/
        </div></article>
        """
        let bundle = try await refresh(html: html, url: "https://www.lovelive-anime.jp/test/live/", title: "Test", franchise: .lovelive)
        XCTAssertEqual(bundle.ticketRounds.count, 3)
        XCTAssertEqual(Set(bundle.ticketRounds.map(\.id)).count, 3)
        XCTAssertEqual(Set(bundle.ticketRounds.flatMap(\.allApplicationLinks).map(\.url)), Set(["https://eplus.jp/a/", "https://eplus.jp/a2/", "https://eplus.jp/b/", "https://eplus.jp/another-a/"]))
    }

    func testBangDreamReceiptBeforeProductKeepsAllThreePairs() async throws {
        let html = """
        <article class="p-live-event-detail">
        <h1 class="p-live-event-detail__header-title">BanG Dream! Test</h1>
        <div class="p-live-event-detail__content c-post-content">
        <h2>日程・会場</h2><p>日程：2026年10月1日(木) 開場16:00／開演17:00<br>会場：東京・Test Hall</p>
        <h2>会場チケット</h2><h3>各公演チケット</h3>
        <p>○DAY1 : Band A<br>受付期間：2026年5月3日(日)21:00～7月13日(月)23:59<br>
        受付URL：<a href="https://eplus.jp/serial/a/">受付はこちら</a><br>
        ※<a href="https://bang-dream.com/discographies/a/">Band A Single「A」</a>初回生産分に封入の申込券でご応募いただけます。</p>
        <p>○DAY2 : Band B<br>受付期間：2026年5月3日(日)21:00～7月13日(月)23:59<br>
        受付URL：<a href="https://eplus.jp/serial/b/">受付はこちら</a><br>
        ※<a href="https://bang-dream.com/discographies/b/">Band B Single「B」</a>初回生産分に封入の申込券でご応募いただけます。</p>
        <p>○DAY3 : Band C<br>受付期間：2026年5月3日(日)21:00～7月13日(月)23:59<br>
        受付URL：<a href="https://eplus.jp/serial/c/">受付はこちら</a><br>
        ※<a href="https://bang-dream.com/discographies/c/">Band C Single「C」</a>初回生産分に封入の申込券でご応募いただけます。</p>
        </div></article>
        """
        let bundle = try await refresh(html: html, url: "https://bang-dream.com/events/test/", title: "Test")
        let round = try XCTUnwrap(bundle.ticketRounds.first)
        XCTAssertEqual(round.allLotteryProducts.count, 3)
        XCTAssertEqual(round.allApplicationLinks.count, 3)
        for letter in ["A", "B", "C"] {
            XCTAssertEqual(round.applicationLinks(forProduct: "Band \(letter) Single「\(letter)」").map(\.url), ["https://eplus.jp/serial/\(letter.lowercased())/"])
        }
    }

    func testLegacySingularURLsRemainVisibleAlongsideAllAdditionalLinks() throws {
        let json = """
        {"id":"r","eventID":"e","officialName":"抽選","kind":"lottery","scope":{"kind":"unconfirmed"},"status":"confirmed","officialStatus":"受付終了",
        "applyURL":"https://eplus.jp/a/","overseasURL":"https://ib.eplus.jp/a/",
        "lotteryProducts":["A","B","A"],"links":[{"label":"Shared application","url":"https://eplus.jp/b/","productNames":["B"]},{"label":"Shared application","url":"https://eplus.jp/b/","productNames":["C"]}]}
        """
        let round = try LiveEventBundle.decoder.decode(TicketRound.self, from: Data(json.utf8))
        XCTAssertEqual(round.allLotteryProducts, ["A", "B", "C"])
        XCTAssertEqual(round.allApplicationLinks.count, 3)
        XCTAssertEqual(round.applicationLinks(forProduct: "B").count, 1)
        XCTAssertEqual(round.applicationLinks(forProduct: "C").count, 1)
        XCTAssertEqual(round.unassignedApplicationLinks.count, 2)
    }

    // MARK: - Helpers

    private func refresh(html: String, url: String, title: String, franchise: Franchise = .bangdream) async throws -> LiveEventBundle {
        TicketFieldsURLProtocol.responses = [url: Data(html.utf8)]
        let event = LiveEvent(
            id: "ticket-fields-event", franchise: franchise, officialTitle: title, groups: [],
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
        configuration.protocolClasses = [TicketFieldsURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}

private final class TicketFieldsURLProtocol: URLProtocol, @unchecked Sendable {
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
