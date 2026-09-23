import XCTest
@testable import LiveDashboardKit

@MainActor
final class LocalRepositoryTests: XCTestCase {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return value
    }
    private func bundle(_ id: String, dates: [String?], title: String = "Live") -> LiveEventBundle {
        let event = LiveEvent(id: id, franchise: .bangdream, officialTitle: title, groups: [], eventType: .live, status: .scheduled, primarySourceURL: "https://bang-dream.com/events/\(id)", timeZone: "Asia/Tokyo")
        return LiveEventBundle(schemaVersion: 1, publishedAt: .distantPast, event: event, stops: [], performances: dates.enumerated().map { index, day in
            Performance(id: "\(id)-\(index)", eventID: id, stopID: nil, dayLabel: "Day \(index + 1)", subtitle: nil, localDate: day, doorsAt: nil, startAt: nil, venueName: "", venueCity: "", performers: [], order: index)
        }, ticketTiers: [], ticketRounds: [], ticketOffers: [], goodsCampaigns: [], mediaAssets: [], notices: [], evidence: [])
    }
    func testCalendarMonthBoundaryAndTours() {
        XCTAssertEqual(LocalRefreshPolicy.cutoff(now: date("2026-03-31T12:00:00Z"), timeZone: calendar.timeZone), "2026-02-28")
        XCTAssertEqual(LocalRefreshPolicy.cutoff(now: date("2026-09-21T16:00:00Z"), timeZone: calendar.timeZone), "2026-08-22")
        XCTAssertEqual(LocalRefreshPolicy.cutoff(now: date("2026-09-21T16:00:00Z"), timeZone: TimeZone(identifier: "America/Toronto")!), "2026-08-21")
        XCTAssertTrue(LocalRefreshPolicy.isArchived(bundle("old", dates: ["2026-08-21"]), cutoff: "2026-08-22"))
        XCTAssertFalse(LocalRefreshPolicy.isArchived(bundle("edge", dates: ["2026-08-22"]), cutoff: "2026-08-22"))
        XCTAssertFalse(LocalRefreshPolicy.isArchived(bundle("tour", dates: ["2026-01-01", "2027-01-01"]), cutoff: "2026-08-22"))
        XCTAssertFalse(LocalRefreshPolicy.isArchived(bundle("unknown", dates: [nil]), cutoff: "2026-08-22"))
    }
    func testScopedCardRefreshChangesOnlySelectedPerformanceFields() throws {
        let saved = bundle("live", dates: ["2026-09-22", "2026-09-23"], title: "Original")
        let changed = bundle("live", dates: ["2026-10-22", "2026-10-23"], title: "Other title")
        let now = date("2026-09-22T00:00:00Z")
        let fresh = LiveEventBundle(schemaVersion: 1, publishedAt: now, event: changed.event,
            stops: [], performances: changed.performances, ticketTiers: [], ticketRounds: [], ticketOffers: [],
            goodsCampaigns: [], mediaAssets: [], notices: [], evidence: [
                SourceEvidence(id: "fresh-date", recordID: "live", field: "performance.schedule", sourceURL: changed.event.primarySourceURL,
                    quote: "2026年10月22日・23日", sourcePublishedAt: nil, verifiedAt: now, verification: .confirmed)
            ])
        let result = try CardRefreshMerge.apply(fresh, to: saved, cardType: .timeAndVenue, entityID: "live-0")
        XCTAssertEqual(result.performances[0].localDate, "2026-10-22")
        XCTAssertEqual(result.performances[1], saved.performances[1])
        XCTAssertEqual(result.event, saved.event)
        XCTAssertEqual(result.ticketRounds, saved.ticketRounds)
        XCTAssertThrowsError(try CardRefreshMerge.apply(fresh, to: saved, cardType: .goodsCampaign, entityID: "missing"))
    }

    func testDailyGatePersistsAndManualBypassesIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scraper = RecordingScraper(events: [bundle("live", dates: ["2026-09-22"])])
        let today = date("2026-09-22T00:00:00Z")
        let repository = LocalLiveRepository(scraper: scraper, directory: directory, calendar: calendar, now: { today })
        _ = try await repository.refreshIfNeeded()
        _ = try await repository.refreshIfNeeded()
        let reopened = LocalLiveRepository(scraper: scraper, directory: directory, calendar: calendar, now: { today })
        _ = try await reopened.refreshIfNeeded()
        var calls = await scraper.calls
        XCTAssertEqual(calls, 1)
        _ = try await reopened.refresh()
        calls = await scraper.calls
        XCTAssertEqual(calls, 2)
        let tomorrow = date("2026-09-23T00:00:00Z")
        let nextDay = LocalLiveRepository(scraper: scraper, directory: directory, calendar: calendar, now: { tomorrow })
        _ = try await nextDay.refreshIfNeeded()
        calls = await scraper.calls
        XCTAssertEqual(calls, 3)
    }
    func testDailyRolloverUsesPhoneDateInsteadOfJapanDate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var phoneCalendar = Calendar(identifier: .gregorian)
        phoneCalendar.timeZone = TimeZone(identifier: "America/Toronto")!
        let scraper = RecordingScraper(events: [bundle("future", dates: ["2027-01-01"])])
        let beforeMidnight = date("2026-09-22T03:59:00Z")
        let first = LocalLiveRepository(scraper: scraper, directory: directory, calendar: phoneCalendar, now: { beforeMidnight })
        _ = try await first.refreshIfNeeded()
        let afterMidnight = date("2026-09-22T04:01:00Z")
        let reopened = LocalLiveRepository(scraper: scraper, directory: directory, calendar: phoneCalendar, now: { afterMidnight })
        _ = try await reopened.refreshIfNeeded()
        let calls = await scraper.calls
        XCTAssertEqual(calls, 2)
    }

    func testChangingTimeZoneDoesNotReinterpretTheStoredPhoneDate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scraper = RecordingScraper(events: [bundle("future", dates: ["2027-01-01"])])
        let firstTime = date("2026-09-22T00:00:00Z")
        let first = LocalLiveRepository(scraper: scraper, directory: directory, calendar: calendar, now: { firstTime })
        _ = try await first.refreshIfNeeded() // phone reads September 22
        var changed = Calendar(identifier: .gregorian)
        changed.timeZone = TimeZone(identifier: "America/Toronto")!
        let secondTime = date("2026-09-22T12:00:00Z")
        let reopened = LocalLiveRepository(scraper: scraper, directory: directory, calendar: changed, now: { secondTime })
        _ = try await reopened.refreshIfNeeded() // phone still reads September 22
        let calls = await scraper.calls
        XCTAssertEqual(calls, 1)
    }

    func testArchiveIsRetainedAndNotOverwritten() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = bundle("old", dates: ["2026-08-21"], title: "Original")
        let scraper = RecordingScraper(events: [original])
        let earlier = date("2026-08-22T00:00:00Z")
        let seed = LocalLiveRepository(scraper: scraper, directory: directory, calendar: calendar, now: { earlier })
        _ = try await seed.refresh()
        await scraper.setEvents([bundle("old", dates: ["2026-08-21"], title: "Changed"), bundle("future", dates: ["2027-01-01"])])
        let later = date("2026-09-22T00:00:00Z")
        let current = LocalLiveRepository(scraper: scraper, directory: directory, calendar: calendar, now: { later })
        let events = try await current.refresh()
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.first { $0.event.id == "old" }?.event.officialTitle, "Original")
        let inputs = await scraper.lastExisting
        XCTAssertEqual(inputs.map(\.event.id), ["old"])
    }
    func testExplicitArchivedCardRefreshDoesNotCountAsDailyCatalogRefresh() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scraper = RecordingScraper(events: [bundle("old", dates: ["2026-08-21"], title: "Original"), bundle("other", dates: ["2027-01-01"])])
        let earlier = date("2026-08-22T00:00:00Z")
        let seed = LocalLiveRepository(scraper: scraper, directory: directory, calendar: calendar, now: { earlier })
        _ = try await seed.refresh()
        await scraper.setEvents([bundle("old", dates: ["2026-08-21"], title: "Rechecked")])
        let later = date("2026-09-22T00:00:00Z")
        let current = LocalLiveRepository(scraper: scraper, directory: directory, calendar: calendar, now: { later })
        let result = try await current.refresh(eventID: "old")
        XCTAssertEqual(result?.event.officialTitle, "Rechecked")
        let all = try await current.allBundles()
        XCTAssertEqual(all.count, 2)
        let last = await current.lastRefreshDate()
        XCTAssertEqual(last, earlier)
    }

    func testPartialOfficialFailureSavesSuccessfulPagesWithoutCompletingTheDay() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scraper = RecordingScraper(events: [bundle("success", dates: ["2027-01-01"])])
        await scraper.setPartialFailure()
        let now = date("2026-09-22T12:00:00Z")
        let repository = LocalLiveRepository(scraper: scraper, directory: directory, calendar: calendar, now: { now })
        do { _ = try await repository.refreshIfNeeded(); XCTFail("Expected partial failure") } catch {}
        let saved = try await repository.allBundles()
        XCTAssertEqual(saved.map(\.event.id), ["success"])
        let last = await repository.lastRefreshDate()
        XCTAssertNil(last)
    }

    func testFailureKeepsSavedDataAndAllowsRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scraper = RecordingScraper(events: [bundle("live", dates: ["2027-01-01"])])
        let today = date("2026-09-22T00:00:00Z")
        let repository = LocalLiveRepository(scraper: scraper, directory: directory, calendar: calendar, now: { today })
        _ = try await repository.refresh()
        await scraper.setFailure(true)
        let tomorrow = date("2026-09-23T00:00:00Z")
        let next = LocalLiveRepository(scraper: scraper, directory: directory, calendar: calendar, now: { tomorrow })
        do { _ = try await next.refreshIfNeeded(); XCTFail("Expected source failure") } catch {}
        let saved = try await next.allBundles()
        XCTAssertEqual(saved.count, 1)
        let last = await next.lastRefreshDate()
        XCTAssertEqual(last, today)
        _ = try await next.refreshIfNeeded()
        let automaticCalls = await scraper.calls
        XCTAssertEqual(automaticCalls, 2) // only the first automatic attempt each phone date
        await scraper.setFailure(false)
        _ = try await next.refresh()
        let calls = await scraper.calls
        XCTAssertEqual(calls, 3)
    }

    func testHistoryFetchStoresArchivedEventsWithoutCompletingTheDay() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scraper = RecordingScraper(events: [bundle("old", dates: ["2024-01-01"]), bundle("future", dates: ["2027-01-01"])])
        let now = date("2026-09-22T00:00:00Z")
        let repository = LocalLiveRepository(scraper: scraper, directory: directory, calendar: calendar, now: { now })

        let refreshed = try await repository.refresh()
        XCTAssertEqual(refreshed.map(\.event.id), ["future"])
        let firstRefreshDate = await repository.lastRefreshDate()
        XCTAssertEqual(firstRefreshDate, now)

        let history = try await repository.fetchHistory(start: "2023-12-01", end: "2024-01-31")
        XCTAssertEqual(history.map(\.event.id), ["old"])
        let all = try await repository.allBundles()
        XCTAssertEqual(all.count, 2)
        let lastRefreshDate = await repository.lastRefreshDate()
        XCTAssertEqual(lastRefreshDate, firstRefreshDate)
        let lastWindow = await scraper.lastWindow
        XCTAssertEqual(lastWindow, OfficialDateWindow(start: "2023-12-01", end: "2024-01-31"))

        let refreshedAgain = try await repository.refresh()
        XCTAssertTrue(refreshedAgain.contains { $0.event.id == "old" })
    }
}

private actor RecordingScraper: OfficialEventScraping {
    var events: [LiveEventBundle]
    var calls = 0
    var lastExisting: [LiveEventBundle] = []
    var lastWindow: OfficialDateWindow?
    var failure = false
    var partialFailure = false
    init(events: [LiveEventBundle]) { self.events = events }
    func setEvents(_ value: [LiveEventBundle]) { events = value }
    func setFailure(_ value: Bool) { failure = value }
    func setPartialFailure() { partialFailure = true }
    func collect(event: LiveEventBundle, now: Date) async throws -> LiveEventBundle {
        calls += 1
        if failure { throw URLError(.notConnectedToInternet) }
        return events.first { $0.event.id == event.event.id } ?? event
    }
    func collect(existing: [LiveEventBundle], cutoff: String, now: Date) async throws -> [LiveEventBundle] {
        try await collect(existing: existing, window: .cutoff(cutoff), now: now)
    }
    func collect(existing: [LiveEventBundle], window: OfficialDateWindow, now: Date) async throws -> [LiveEventBundle] {
        calls += 1
        lastExisting = existing
        lastWindow = window
        // Daily (open-ended) refresh returns everything so `save()` archive rules stay under test.
        let filtered = window.end == nil ? events : events.filter { window.overlaps($0) }
        if partialFailure {
            throw OfficialEventScraperError.partialFailure(partialBundles: filtered, failures: [OfficialScrapeFailure(url: URL(string: "https://www.lovelive-anime.jp/")!, kind: .fetch, message: "HTTP 403")])
        }
        if failure { throw URLError(.notConnectedToInternet) }
        return filtered
    }
}
