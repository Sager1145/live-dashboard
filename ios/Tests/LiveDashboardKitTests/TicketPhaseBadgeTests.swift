import XCTest
@testable import LiveDashboardKit

final class TicketPhaseBadgeTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-09-23T01:00:00Z")!

    private func round(
        _ name: String, kind: TicketRoundKind, start: Date? = nil, end: Date? = nil,
        status: DataStatus = .confirmed, officialStatus: String? = nil, scope: Scope = .unconfirmed
    ) -> TicketRound {
        TicketRound(
            id: name, eventID: "e", officialName: name, kind: kind, scope: scope,
            applyStartAt: start, applyEndAt: end, resultAt: nil, paymentDeadlineAt: nil,
            eligibility: nil, announcementURL: nil, applyURL: nil, overseasURL: nil,
            officialStatus: officialStatus, status: status)
    }


    // Expectations are composed from the same localized fragments the builder
    // uses, so they hold under the English test-host locale as well as zh-Hans.
    private func l(_ key: String) -> String { String(localized: String.LocalizationValue(key), bundle: .kit) }
    private func ordinal(_ n: Int, presale: Bool = false) -> String { l("第") + "\(n)" + l("次") + (presale ? l("先行") : "") }

    // MARK: phaseName

    func testPhaseNameOrdinalLottery() {
        XCTAssertEqual(TicketPhaseBadgeBuilder.phaseName(for: round("【1次抽選】", kind: .lottery)), ordinal(1) + l("抽选"))
    }

    func testPhaseNameOrdinalWithSecondaryPreSale() {
        XCTAssertEqual(TicketPhaseBadgeBuilder.phaseName(for: round("プレイガイド二次先行（受付終了）", kind: .lottery)), ordinal(2, presale: true) + l("抽选"))
    }

    func testPhaseNameFastest() {
        XCTAssertEqual(TicketPhaseBadgeBuilder.phaseName(for: round("最速先行", kind: .lottery)), l("最速先行") + l("抽选"))
    }

    func testPhaseNameOfficial() {
        XCTAssertEqual(TicketPhaseBadgeBuilder.phaseName(for: round("オフィシャル先行抽選", kind: .lottery)), l("官方先行") + l("抽选"))
    }

    func testPhaseNameGeneralPreSale() {
        XCTAssertEqual(TicketPhaseBadgeBuilder.phaseName(for: round("一般先行", kind: .lottery)), l("一般先行") + l("抽选"))
    }

    func testPhaseNameGeneralSaleFirstComeFirstServed() {
        XCTAssertEqual(TicketPhaseBadgeBuilder.phaseName(for: round("一般発売", kind: .firstComeFirstServed)), l("一般贩售"))
    }

    func testPhaseNameGeneralSaleWithVenuePrefix() {
        XCTAssertEqual(TicketPhaseBadgeBuilder.phaseName(for: round("東京公演 一般発売", kind: .firstComeFirstServed)), l("一般贩售"))
    }

    func testPhaseNameResale() {
        XCTAssertEqual(TicketPhaseBadgeBuilder.phaseName(for: round("トレード受付期間", kind: .resale)), l("官方转售"))
    }

    func testPhaseNameFullWidthDigit() {
        XCTAssertEqual(TicketPhaseBadgeBuilder.phaseName(for: round("１次抽選", kind: .lottery)), ordinal(1) + l("抽选"))
    }

    // MARK: badges

    func testOpenAndUpcomingBadges() {
        let openRound = round("2次先行", kind: .lottery, start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(86_400))
        let upcomingRound = round("一般発売", kind: .firstComeFirstServed, start: now.addingTimeInterval(2 * 86_400))
        let badges = TicketPhaseBadgeBuilder.badges(rounds: [openRound, upcomingRound], now: now)
        XCTAssertEqual(badges.map(\.text), [ordinal(2, presale: true) + l("抽选") + l("中"), l("即将：") + l("一般贩售")])
        XCTAssertEqual(badges.map(\.tone), [.open, .upcoming])
    }

    func testAllClosedProducesClosedBadge() {
        let yesterday = now.addingTimeInterval(-86_400)
        let r1 = round("1次抽選", kind: .lottery, start: yesterday.addingTimeInterval(-3600), end: yesterday)
        let r2 = round("2次抽選", kind: .lottery, start: yesterday.addingTimeInterval(-7200), end: yesterday.addingTimeInterval(-3600))
        let badges = TicketPhaseBadgeBuilder.badges(rounds: [r1, r2], now: now)
        XCTAssertEqual(badges.map(\.text), [l("受付全部结束")])
        XCTAssertEqual(badges.map(\.tone), [.closed])
    }

    func testAllClosedWithSoldOutProducesSoldOutBadge() {
        let yesterday = now.addingTimeInterval(-86_400)
        let r1 = round("1次抽選", kind: .lottery, start: yesterday.addingTimeInterval(-3600), end: yesterday, officialStatus: "完売")
        let r2 = round("2次抽選", kind: .lottery, start: yesterday.addingTimeInterval(-7200), end: yesterday.addingTimeInterval(-3600))
        let badges = TicketPhaseBadgeBuilder.badges(rounds: [r1, r2], now: now)
        XCTAssertEqual(badges.map(\.text), [l("已售罄")])
        XCTAssertEqual(badges.map(\.tone), [.soldOut])
    }

    func testOfficialStatusOverridesDateBasedOpenToClosed() {
        let openByDates = round("1次抽選", kind: .lottery, start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(86_400), officialStatus: "受付終了")
        let badges = TicketPhaseBadgeBuilder.badges(rounds: [openByDates], now: now)
        XCTAssertEqual(badges.map(\.text), [l("受付全部结束")])
    }

    func testUpgradeRoundIgnored() {
        let upgrade = round("アップグレード", kind: .upgrade, start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(86_400))
        XCTAssertEqual(TicketPhaseBadgeBuilder.badges(rounds: [upgrade], now: now), [])
    }

    func testNeedsReviewStatusRoundIgnored() {
        let review = round("1次抽選", kind: .lottery, start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(86_400), status: .needsReview)
        XCTAssertEqual(TicketPhaseBadgeBuilder.badges(rounds: [review], now: now), [])
    }

    func testEmptyInputReturnsEmpty() {
        XCTAssertEqual(TicketPhaseBadgeBuilder.badges(rounds: [], now: now), [])
    }

    func testUnconfirmedScopeOpenRoundStillProducesBadge() {
        let openRound = round("1次抽選", kind: .lottery, start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(86_400), scope: .unconfirmed)
        let badges = TicketPhaseBadgeBuilder.badges(rounds: [openRound], now: now)
        XCTAssertEqual(badges.map(\.text), [ordinal(1) + l("抽选") + l("中")])
    }

    func testCapsAtThreeBadges() {
        let rounds = (1...4).map { index in
            round("\(index)次先行", kind: .lottery, start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(Double(index) * 86_400))
        }
        let badges = TicketPhaseBadgeBuilder.badges(rounds: rounds, now: now)
        XCTAssertEqual(badges.count, 3)
    }
}
