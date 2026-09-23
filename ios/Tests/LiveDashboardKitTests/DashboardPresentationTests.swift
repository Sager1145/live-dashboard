import XCTest
@testable import LiveDashboardKit

@MainActor
final class DashboardPresentationTests: XCTestCase {
    /// Fixtures use 2027+ dates, so the clock is pinned to keep them upcoming as real time passes.
    private func store(now: Date = DashboardPresentationTests.today) -> DashboardStore {
        DashboardStore(repository: LocalLiveRepository(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            userDataStore: UserDataStore(container: UserDataStore.makeContainer(inMemory: true)),
            timeZone: TimeZone(identifier: "Asia/Tokyo")!, now: { now })
    }

    /// 2026-09-23 10:00 in Tokyo.
    private static let today = ISO8601DateFormatter().date(from: "2026-09-23T01:00:00Z")!
    private var today: Date { Self.today }

    func testPastScopeHoldsOnlyEventsWhoseEveryPerformanceEndedBeforeToday() {
        let store = store(now: today)
        [
            bundle("ended", dates: ["2026-09-01"]),
            bundle("ended-yesterday", dates: ["2026-09-21", "2026-09-22"]),
            bundle("today", dates: ["2026-09-23"]),
            bundle("ongoing-tour", dates: ["2026-09-20", "2026-09-25"]),
            bundle("partly-unknown", dates: ["2026-01-01", nil]),
            bundle("unknown", dates: [nil]),
            bundle("no-dates", dates: []),
            bundle("future", dates: ["2027-03-01"])
        ].forEach(store.acceptRefreshedBundle)

        XCTAssertEqual(store.visibleSummaries(in: .past).map(\.id), ["ended-yesterday", "ended"])
        XCTAssertEqual(Set(store.visibleSummaries.map(\.id)), ["today", "ongoing-tour", "partly-unknown", "unknown", "no-dates", "future"])
        XCTAssertEqual(store.visibleSummaries.map(\.id), store.visibleSummaries(in: .upcoming).map(\.id))
    }

    func testPastScopeSortsMostRecentFirstThenByStartTime() {
        let store = store(now: today)
        let morning = ISO8601DateFormatter().date(from: "2026-08-10T02:00:00Z")!
        let evening = ISO8601DateFormatter().date(from: "2026-08-10T09:00:00Z")!
        [
            bundle("older", dates: ["2026-07-01"]),
            bundle("morning", dates: ["2026-08-10"], starts: [morning]),
            bundle("evening", dates: ["2026-08-10"], starts: [evening]),
            bundle("tour-ending-latest", dates: ["2026-06-01", "2026-09-05"])
        ].forEach(store.acceptRefreshedBundle)
        XCTAssertEqual(store.visibleSummaries(in: .past).map(\.id), ["tour-ending-latest", "evening", "morning", "older"])
    }

    func testScopesKeepIndependentFiltersAndCalendarOptions() {
        let store = store(now: today)
        [
            bundle("past-2025", dates: ["2025-05-01"]),
            bundle("past-2026", dates: ["2026-08-01"]),
            bundle("future-2027", dates: ["2027-03-01"])
        ].forEach(store.acceptRefreshedBundle)

        XCTAssertEqual(store.availableYears(in: .past), [2025, 2026])
        XCTAssertEqual(store.availableYears(in: .upcoming), [2027])
        XCTAssertEqual(store.availableMonths(in: .past), [5, 8])

        store.pastFilters.year = 2025
        XCTAssertEqual(store.visibleSummaries(in: .past).map(\.id), ["past-2025"])
        XCTAssertEqual(store.visibleSummaries(in: .upcoming).map(\.id), ["future-2027"], "the upcoming list ignores the past tab's year")
        XCTAssertNil(store.filters.year)

        store.filters.searchText = "nothing-matches"
        XCTAssertTrue(store.visibleSummaries(in: .upcoming).isEmpty)
        XCTAssertEqual(store.visibleSummaries(in: .past).map(\.id), ["past-2025"], "the past list ignores the upcoming tab's search")
    }

    func testEventMovesToPastOnThePhoneDayAfterItsLastPerformance() {
        let store = store(now: ISO8601DateFormatter().date(from: "2026-09-22T14:59:00Z")!) // 23:59 Tokyo, Sep 22
        store.acceptRefreshedBundle(bundle("live", dates: ["2026-09-22"]))
        XCTAssertEqual(store.visibleSummaries(in: .upcoming).map(\.id), ["live"])
        XCTAssertTrue(store.visibleSummaries(in: .past).isEmpty)

        let later = self.store(now: ISO8601DateFormatter().date(from: "2026-09-22T15:00:00Z")!) // 00:00 Tokyo, Sep 23
        later.acceptRefreshedBundle(bundle("live", dates: ["2026-09-22"]))
        XCTAssertEqual(later.visibleSummaries(in: .past).map(\.id), ["live"])
        XCTAssertTrue(later.visibleSummaries(in: .upcoming).isEmpty)
    }

    private func bundle(_ id: String, dates: [String?], starts: [Date?] = [], media: [MediaAsset] = [], rounds: [TicketRound] = []) -> LiveEventBundle {
        let event = LiveEvent(id: id, franchise: .lovelive, officialTitle: id, groups: [], eventType: .live,
            status: .scheduled, primarySourceURL: "https://www.lovelive-anime.jp/", timeZone: "Asia/Tokyo")
        let performances = dates.enumerated().map { index, date in
            Performance(id: "\(id)-\(index)", eventID: id, stopID: nil, dayLabel: "Day \(index + 1)", subtitle: nil,
                localDate: date, doorsAt: nil, startAt: starts.indices.contains(index) ? starts[index] : nil,
                venueName: "Tokyo", venueCity: "Tokyo", performers: [], order: index)
        }
        return LiveEventBundle(schemaVersion: 1, publishedAt: .distantPast, event: event, stops: [], performances: performances,
            ticketTiers: [], ticketRounds: rounds, ticketOffers: [], goodsCampaigns: [], mediaAssets: media, notices: [], evidence: [])
    }

    func testSortsByActualDatesAndStartTimesWithUnknownDatesLast() {
        let store = store()
        let morning = ISO8601DateFormatter().date(from: "2027-03-01T02:00:00Z")!
        let evening = ISO8601DateFormatter().date(from: "2027-03-01T09:00:00Z")!
        let values = [
            bundle("unknown", dates: [nil]),
            bundle("evening", dates: ["2027-03-01"], starts: [evening]),
            bundle("earlier", dates: ["2027-02-01"]),
            bundle("morning", dates: ["2027-03-01"], starts: [morning]),
            bundle("time-tbd", dates: ["2027-03-01"]),
        ]
        values.forEach(store.acceptRefreshedBundle)
        XCTAssertEqual(store.visibleSummaries.map(\.id), ["earlier", "morning", "evening", "time-tbd", "unknown"])
        store.acceptRefreshedBundle(bundle("earlier", dates: ["2027-04-01"]))
        XCTAssertEqual(store.visibleSummaries.map(\.id), ["morning", "evening", "time-tbd", "earlier", "unknown"])
    }

    func testTourRangeUsesChronologicalDatesRatherThanSourceOrder() throws {
        let store = store()
        store.acceptRefreshedBundle(bundle("tour", dates: ["2027-04-01", nil, "2027-02-01"]))
        let summary = try XCTUnwrap(store.visibleSummaries.first)
        XCTAssertEqual(summary.firstLocalDate, "2027-02-01")
        XCTAssertEqual(summary.lastLocalDate, "2027-04-01")
    }

    func testThumbnailOnlyUsesOfficialKeyVisualAndUpdatesWithRefreshedBundle() throws {
        func asset(_ id: String, kind: MediaAssetKind, version: Int = 1) -> MediaAsset {
            MediaAsset(id: id, eventID: "live", kind: kind, originalURL: "https://www.lovelive-anime.jp/\(id).jpg",
                thumbnailURL: "https://www.lovelive-anime.jp/\(id)-small.jpg", scope: .unconfirmed,
                sourceURL: "https://www.lovelive-anime.jp/live/", version: version, caption: nil, contentKind: .image)
        }
        let store = store()
        store.acceptRefreshedBundle(bundle("live", dates: [], media: [asset("goods", kind: .goodsList)]))
        XCTAssertNil(store.visibleSummaries.first?.officialThumbnail)
        store.acceptRefreshedBundle(bundle("live", dates: [], media: [asset("poster", kind: .keyVisual), asset("new-poster", kind: .keyVisual, version: 2)]))
        XCTAssertEqual(store.visibleSummaries.first?.officialThumbnail?.id, "new-poster")
    }

    func testYearAndMonthFiltersMatchTheSamePerformanceAndExcludeUnknownDatesWhenActive() {
        let store = store()
        [
            bundle("march-2027", dates: ["2027-03-12"]),
            bundle("march-2028", dates: ["2028-03-12"]),
            bundle("april-2027", dates: ["2027-04-12"]),
            bundle("unknown", dates: [nil])
        ].forEach(store.acceptRefreshedBundle)

        XCTAssertEqual(Set(store.visibleSummaries.map(\.id)), ["march-2027", "march-2028", "april-2027", "unknown"])
        store.filters.year = 2027
        XCTAssertEqual(store.visibleSummaries.map(\.id), ["march-2027", "april-2027"])
        store.filters.month = 3
        XCTAssertEqual(store.visibleSummaries.map(\.id), ["march-2027"])
    }

    func testCrossYearTourMatchesYearAndMonthFromAnyActualPerformance() {
        let store = store()
        store.acceptRefreshedBundle(bundle("cross-year-tour", dates: ["2027-12-31", "2028-01-01"]))

        store.filters.year = 2028
        XCTAssertEqual(store.visibleSummaries.map(\.id), ["cross-year-tour"])
        store.filters.month = 1
        XCTAssertEqual(store.visibleSummaries.map(\.id), ["cross-year-tour"])
        store.filters.month = 12
        XCTAssertTrue(store.visibleSummaries.isEmpty)
    }

    func testMonthFilterWorksAcrossAllYears() {
        let store = store()
        [
            bundle("march-2027", dates: ["2027-03-12"]),
            bundle("march-2028", dates: ["2028-03-12"]),
            bundle("april-2028", dates: ["2028-04-12"])
        ].forEach(store.acceptRefreshedBundle)

        store.filters.month = 3
        XCTAssertEqual(store.visibleSummaries.map(\.id), ["march-2027", "march-2028"])
    }

    func testAvailableYearsAreDeduplicatedAndSortedAscendingFromPerformanceDates() {
        let store = store()
        [
            bundle("later", dates: ["2028-01-01", "2027-12-31"]),
            bundle("earlier", dates: ["2026-05-01", "2028-06-01"]),
            bundle("unknown", dates: [nil])
        ].forEach(store.acceptRefreshedBundle)

        XCTAssertEqual(store.availableYears, [2026, 2027, 2028])
    }
    func testSummaryCarriesEventLevelTicketBadgesRegardlessOfScope() throws {
        let store = store(now: today)
        let round = TicketRound(
            id: "r1", eventID: "live", officialName: "【1次抽選】", kind: .lottery, scope: .unconfirmed,
            applyStartAt: today.addingTimeInterval(-3600), applyEndAt: today.addingTimeInterval(86_400),
            resultAt: nil, paymentDeadlineAt: nil, eligibility: nil, announcementURL: nil, applyURL: nil,
            overseasURL: nil, officialStatus: nil, status: .confirmed)
        store.acceptRefreshedBundle(bundle("live", dates: ["2026-09-23"], rounds: [round]))
        let summary = try XCTUnwrap(store.visibleSummaries.first)
        let expected = String(localized: "第", bundle: .kit) + "1" + String(localized: "次", bundle: .kit) + String(localized: "抽选", bundle: .kit) + String(localized: "中", bundle: .kit)
        XCTAssertEqual(summary.ticketBadges.map(\.text), [expected])
        XCTAssertNil(summary.currentRoundLabel)
    }

    func testListingCoverTakesPriorityOverNewerDetailPoster() throws {
        func asset(_ id: String, kind: MediaAssetKind, version: Int) -> MediaAsset {
            MediaAsset(id: id, eventID: "live", kind: kind,
                originalURL: "https://bang-dream.com/\(id).png", thumbnailURL: nil,
                scope: .unconfirmed, sourceURL: "https://bang-dream.com/events/",
                version: version, caption: nil, contentKind: .image)
        }
        let store = store()
        store.acceptRefreshedBundle(bundle("live", dates: [], media: [
            asset("poster", kind: .keyVisual, version: 10),
            asset("cover", kind: .eventCover, version: 1),
            asset("updated-cover", kind: .eventCover, version: 2),
        ]))
        XCTAssertEqual(store.visibleSummaries.first?.officialThumbnail?.id, "updated-cover")
    }

}
