import XCTest
@testable import LiveDashboardKit

final class DeadlineReadModelTests: XCTestCase {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    private func bundle(health: SourceHealthState, applyEnd: Date?, payment: Date?, performanceTimeZone: String? = nil) -> LiveEventBundle {
        let event = LiveEvent(
            id: "event-1", franchise: .bangdream, officialTitle: "Contract Live", groups: ["Roselia"],
            eventType: .live, status: .scheduled, primarySourceURL: "https://example.com/event-1", timeZone: "Asia/Tokyo"
        )
        let performance = Performance(
            id: "show-1", eventID: "event-1", stopID: nil, dayLabel: "Day 1", subtitle: nil,
            localDate: "2026-10-01", doorsAt: nil, startAt: applyEnd, venueName: "Tokyo Dome", venueCity: "Tokyo",
            performers: [], order: 0, timeZone: performanceTimeZone
        )
        let round = TicketRound(
            id: "round-1", eventID: "event-1", officialName: "一次先行", kind: .lottery, scope: .wholeEvent,
            applyStartAt: nil, applyEndAt: applyEnd, resultAt: nil, paymentDeadlineAt: payment,
            eligibility: nil, announcementURL: nil, applyURL: nil, overseasURL: nil,
            officialStatus: nil, status: .confirmed
        )
        return LiveEventBundle(
            schemaVersion: 1, publishedAt: .distantPast, event: event, stops: [], performances: [performance],
            ticketTiers: [], ticketRounds: [round], ticketOffers: [], goodsCampaigns: [],
            mediaAssets: [], notices: [], evidence: [], sourceHealth: health
        )
    }

    func testAnswerReturnsApplyEndAndMarksStale() {
        let end = date("2026-10-01T14:59:00Z")
        let bundle = bundle(health: .stale, applyEnd: end, payment: nil)
        let answer = DeadlineReadModel.answer(bundle: bundle, roundID: "round-1", kind: .applicationEnd)
        XCTAssertEqual(answer?.deadline, end)
        XCTAssertEqual(answer?.sourceIsStale, true)
        XCTAssertEqual(answer?.unknown, false)
        XCTAssertEqual(answer?.roundName, "一次先行")
        XCTAssertNil(DeadlineReadModel.answer(bundle: bundle, roundID: "other-round", kind: .applicationEnd))
    }

    func testMissingPaymentDeadlineIsUnknownAndDoesNotFallBack() {
        let end = date("2026-10-01T14:59:00Z")
        let saved = bundle(health: .healthy, applyEnd: end, payment: nil)
        let answer = DeadlineReadModel.answer(bundle: saved, roundID: "round-1", kind: .paymentEnd)
        XCTAssertEqual(answer?.unknown, true)
        XCTAssertNil(answer?.deadline)
        XCTAssertNotEqual(answer?.deadline, end)
        XCTAssertEqual(answer?.sourceIsStale, false)
        let text = DeadlineReadModel.format(answer!, now: date("2026-09-23T00:00:00Z"))
        XCTAssertTrue(text.contains("没有已保存的支付截止时间"))
        XCTAssertFalse(text.contains("23:59"))
        XCTAssertFalse(text.contains(DeadlineReadModel.staleCaveat))
    }

    func testFormatIncludesStaleCaveatAndSavedInstant() {
        let end = date("2026-10-01T14:59:00Z")
        let answer = DeadlineReadModel.answer(bundle: bundle(health: .stale, applyEnd: end, payment: nil), roundID: "round-1", kind: .applicationEnd)!
        let text = DeadlineReadModel.format(answer, now: date("2026-09-23T00:00:00Z"))
        XCTAssertTrue(text.contains("一次先行"))
        XCTAssertTrue(text.contains("2026年10月1日 23:59"))
        XCTAssertTrue(text.contains("Asia/Tokyo"))
        XCTAssertTrue(text.contains(DeadlineReadModel.staleCaveat))
    }

    func testPerformanceTimeZoneFallsBackToEvent() {
        let start = date("2026-10-01T09:00:00Z")
        let saved = bundle(health: .healthy, applyEnd: nil, payment: nil)
        let performance = Performance(
            id: "show-1", eventID: "event-1", stopID: nil, dayLabel: "Day 1", subtitle: "夜",
            localDate: "2026-10-01", doorsAt: nil, startAt: start, venueName: "Tokyo Dome", venueCity: "Tokyo",
            performers: [], order: 0, timeZone: nil
        )
        let event = saved.event
        let rebuilt = LiveEventBundle(
            schemaVersion: 1, publishedAt: saved.publishedAt, event: event, stops: [], performances: [performance],
            ticketTiers: [], ticketRounds: saved.ticketRounds, ticketOffers: [], goodsCampaigns: [],
            mediaAssets: [], notices: [], evidence: []
        )
        let answer = DeadlineReadModel.performanceAnswer(bundle: rebuilt, performanceID: "show-1")
        XCTAssertEqual(answer?.timeZoneIdentifier, "Asia/Tokyo")
        XCTAssertEqual(answer?.localDate, "2026-10-01")
        XCTAssertEqual(answer?.startAt, start)
        XCTAssertEqual(answer?.venueName, "Tokyo Dome")
        XCTAssertEqual(answer?.dayLabel, "Day 1")
        XCTAssertNil(DeadlineReadModel.performanceAnswer(bundle: rebuilt, performanceID: "missing"))

        let zoned = Performance(
            id: "show-2", eventID: "event-1", stopID: nil, dayLabel: "Day 2", subtitle: nil,
            localDate: "2026-10-02", doorsAt: nil, startAt: start, venueName: "Osaka", venueCity: "Osaka",
            performers: [], order: 1, timeZone: "Asia/Seoul"
        )
        let both = LiveEventBundle(
            schemaVersion: 1, publishedAt: saved.publishedAt, event: event, stops: [], performances: [performance, zoned],
            ticketTiers: [], ticketRounds: [], ticketOffers: [], goodsCampaigns: [],
            mediaAssets: [], notices: [], evidence: []
        )
        XCTAssertEqual(DeadlineReadModel.performanceAnswer(bundle: both, performanceID: "show-2")?.timeZoneIdentifier, "Asia/Seoul")
    }

    func testReminderRequestKeyIdentifierIsStable() {
        let key = ReminderRequestKey(roundID: "round-1", kind: .applicationEnd, leadMinutes: 1440)
        let first = ReminderRequestKey.identifier(eventID: "event-1", key: key)
        let again = ReminderRequestKey.identifier(
            eventID: "event-1",
            key: ReminderRequestKey(roundID: "round-1", kind: .applicationEnd, leadMinutes: 1440)
        )
        let otherLead = ReminderRequestKey.identifier(
            eventID: "event-1",
            key: ReminderRequestKey(roundID: "round-1", kind: .applicationEnd, leadMinutes: 60)
        )
        XCTAssertEqual(first.stableID, again.stableID)
        XCTAssertEqual(first.stableID, "live-dashboard.reminder.event-1..tickets.ticketRound.round-1.applicationEnd.1440")
        XCTAssertEqual(first.eventID, "event-1")
        XCTAssertEqual(first.performanceID, "")
        XCTAssertEqual(first.tab, "tickets")
        XCTAssertEqual(first.cardType, .ticketRound)
        XCTAssertEqual(first.entityID, "round-1.applicationEnd.1440")
        XCTAssertNotEqual(first.stableID, otherLead.stableID)
        XCTAssertTrue(otherLead.stableID.contains("round-1"))
        XCTAssertTrue(otherLead.stableID.contains("applicationEnd"))
        XCTAssertTrue(otherLead.stableID.contains("60"))
        XCTAssertFalse(otherLead.stableID.contains("1440"))
    }

    func testTicketReminderPlannerLeadAndFireDate() {
        let now = date("2026-09-23T00:00:00Z")
        let future = now.addingTimeInterval(2 * 60 * 60)
        XCTAssertEqual(TicketReminderPlanner.fireDate(deadline: future, leadMinutes: 0, now: now), .failure(.invalidLead))
        XCTAssertEqual(TicketReminderPlanner.fireDate(deadline: future, leadMinutes: -1, now: now), .failure(.invalidLead))
        XCTAssertEqual(TicketReminderPlanner.fireDate(deadline: nil, leadMinutes: 60, now: now), .failure(.missingDeadline))
        XCTAssertEqual(
            TicketReminderPlanner.fireDate(deadline: now.addingTimeInterval(30 * 60), leadMinutes: 60, now: now),
            .failure(.alreadyPast)
        )
        XCTAssertEqual(
            TicketReminderPlanner.fireDate(deadline: now.addingTimeInterval(60 * 60), leadMinutes: 60, now: now),
            .failure(.alreadyPast)
        )
        XCTAssertEqual(
            TicketReminderPlanner.fireDate(deadline: future, leadMinutes: 60, now: now),
            .success(future.addingTimeInterval(-60 * 60))
        )
    }
}
