import XCTest
@testable import LiveDashboardKit

/// Regression coverage for the overview-tab hide/pin defect: `overviewCards`
/// must key its lookups by `CardConfiguration.globalEntityID`, matching what
/// `TimeAndVenueCard`/`PerformersCard` now pass to `DetailCard`.
final class OverviewCardsTests: XCTestCase {
    func testHiddenGlobalConfigExcludesTheCardType() {
        var hidden = CardConfiguration(cardType: .timeAndVenue, entityID: CardConfiguration.globalEntityID)
        hidden.isHidden = true
        let configurations = [hidden.key: hidden]

        let order = ImportantInformationPolicy.overviewCards(configurations: configurations)

        XCTAssertFalse(order.contains(.timeAndVenue))
        XCTAssertEqual(order, ImportantInformationPolicy.overviewDefaultOrder.filter { $0 != .timeAndVenue })
    }

    func testPinnedGlobalConfigMovesTheCardTypeFirst() {
        var pinned = CardConfiguration(cardType: .performers, entityID: CardConfiguration.globalEntityID)
        pinned.isPinned = true
        let configurations = [pinned.key: pinned]

        let order = ImportantInformationPolicy.overviewCards(configurations: configurations)

        XCTAssertEqual(order.first, .performers)
        XCTAssertEqual(Set(order), Set(ImportantInformationPolicy.overviewDefaultOrder))
    }
}

/// `TicketRoundCard`'s headline date: the single most relevant date for the
/// round's current status, so the card doesn't force the user to scan every
/// phase's date to find the one that matters right now.
final class TicketRoundKeyDateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeRound(
        applyStartAt: Date? = nil,
        applyEndAt: Date? = nil,
        resultAt: Date? = nil,
        paymentDeadlineAt: Date? = nil
    ) -> TicketRound {
        TicketRound(
            id: "round-1",
            eventID: "event-1",
            officialName: "第一抽選",
            kind: .lottery,
            scope: .wholeEvent,
            applyStartAt: applyStartAt,
            applyEndAt: applyEndAt,
            resultAt: resultAt,
            paymentDeadlineAt: paymentDeadlineAt,
            eligibility: nil,
            announcementURL: nil,
            applyURL: nil,
            overseasURL: nil,
            officialStatus: nil,
            status: .confirmed
        )
    }

    func testUpcomingResolvesToApplyStart() {
        let start = now.addingTimeInterval(3600)
        let round = makeRound(applyStartAt: start, applyEndAt: now.addingTimeInterval(7200))

        XCTAssertEqual(TicketRoundKeyDate.resolve(round: round, displayStatus: .upcoming, now: now), .applyStart(start))
    }

    func testOpenResolvesToApplyEnd() {
        let end = now.addingTimeInterval(3600)
        let round = makeRound(applyStartAt: now.addingTimeInterval(-3600), applyEndAt: end)

        XCTAssertEqual(TicketRoundKeyDate.resolve(round: round, displayStatus: .open, now: now), .applyEnd(end))
    }

    func testClosedWithFutureResultAndPaymentPicksEarlier() {
        let result = now.addingTimeInterval(3600)
        let payment = now.addingTimeInterval(7200)
        let round = makeRound(resultAt: result, paymentDeadlineAt: payment)

        XCTAssertEqual(TicketRoundKeyDate.resolve(round: round, displayStatus: .closed, now: now), .result(result))
    }

    func testClosedWithBothPastResolvesToNil() {
        let round = makeRound(resultAt: now.addingTimeInterval(-3600), paymentDeadlineAt: now.addingTimeInterval(-1800))

        XCTAssertNil(TicketRoundKeyDate.resolve(round: round, displayStatus: .closed, now: now))
    }

    func testOpenWithoutApplyEndResolvesToNil() {
        let round = makeRound(applyStartAt: now.addingTimeInterval(-3600))

        XCTAssertNil(TicketRoundKeyDate.resolve(round: round, displayStatus: .open, now: now))
    }
}
