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

    private func bundle(_ id: String, dates: [String?], starts: [Date?] = [], media: [MediaAsset] = [], rounds: [TicketRound] = [], venues: [String] = []) -> LiveEventBundle {
        let event = LiveEvent(id: id, franchise: .lovelive, officialTitle: id, groups: [], eventType: .live,
            status: .scheduled, primarySourceURL: "https://www.lovelive-anime.jp/", timeZone: "Asia/Tokyo")
        let performances = dates.enumerated().map { index, date in
            Performance(id: "\(id)-\(index)", eventID: id, stopID: nil, dayLabel: "Day \(index + 1)", subtitle: nil,
                localDate: date, doorsAt: nil, startAt: starts.indices.contains(index) ? starts[index] : nil,
                venueName: venues.indices.contains(index) ? venues[index] : "Tokyo",
                venueCity: venues.indices.contains(index) ? venues[index] : "Tokyo", performers: [], order: index)
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

    func testMultiVenueCardAndPerformancePickerNameEachLocation() throws {
        let store = store()
        let tour = bundle("tour", dates: ["2027-03-01", "2027-04-01", "2027-05-01"],
            venues: ["東京", "大阪", "東京"])
        store.acceptRefreshedBundle(tour)
        XCTAssertEqual(store.visibleSummaries.first?.venueSummary, "東京 · 大阪")
        XCTAssertTrue(PerformanceSelector.shortLabel(for: tour.performances[1], in: tour).contains("大阪"))
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
        let phase = String(localized: "第\(1)次", bundle: .kit) + String(localized: "抽选", bundle: .kit)
        let expected = String(localized: "\(phase)中", bundle: .kit)
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

    func testConcurrentManualRefreshesShareOneRepositoryPass() async {
        let fixedNow = ISO8601DateFormatter().date(from: "2026-09-23T01:00:00Z")!
        let repository = CountingRepository(bundles: [bundle("live", dates: ["2027-01-01"])])
        let store = DashboardStore(repository: repository,
            userDataStore: UserDataStore(container: UserDataStore.makeContainer(inMemory: true)),
            timeZone: TimeZone(identifier: "Asia/Tokyo")!, now: { fixedNow })

        async let first: () = store.refresh()
        async let second: () = store.refresh()
        _ = await (first, second)

        let count = await repository.refreshCallCount
        XCTAssertEqual(count, 1, "two concurrent manual refreshes should share a single repository pass")
    }

    /// A manual refresh requested while the automatic one is still running must not start its
    /// own pass immediately (racing the automatic one for `bundles`); it should wait and then
    /// run exactly one shared extra pass, joined by every manual caller that arrived meanwhile.
    func testManualRefreshDuringAutomaticRunsExactlyOneExtraPass() async {
        let fixedNow = ISO8601DateFormatter().date(from: "2026-09-23T01:00:00Z")!
        let repository = CountingRepository(bundles: [bundle("live", dates: ["2027-01-01"])])
        let store = DashboardStore(repository: repository,
            userDataStore: UserDataStore(container: UserDataStore.makeContainer(inMemory: true)),
            timeZone: TimeZone(identifier: "Asia/Tokyo")!, now: { fixedNow })

        let automatic = Task { await store.refreshIfNeeded() }
        // Wait until the automatic pass has actually started before issuing manual calls,
        // instead of relying on `async let` scheduling order (which isn't guaranteed).
        while !store.isRefreshing { await Task.yield() }

        async let manualFirst: () = store.refresh()
        async let manualSecond: () = store.refresh()
        _ = await (automatic.value, manualFirst, manualSecond)

        let count = await repository.refreshCallCount
        XCTAssertEqual(count, 2, "one automatic pass plus exactly one shared manual pass, not one per manual caller")
        XCTAssertFalse(store.isRefreshing)
    }

    func testCardListsEachDayAndParticipationStaysOnThatDay() throws {
        let userData = UserDataStore(container: UserDataStore.makeContainer(inMemory: true))
        let store = DashboardStore(
            repository: LocalLiveRepository(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            userDataStore: userData,
            timeZone: TimeZone(identifier: "Asia/Tokyo")!,
            now: { today }
        )
        let zone = TimeZone(identifier: "Asia/Tokyo")!
        let morning = ISO8601DateFormatter().date(from: "2027-03-01T02:00:00Z")!
        let evening = ISO8601DateFormatter().date(from: "2027-03-02T09:00:00Z")!
        let event = LiveEvent(id: "live", franchise: .lovelive, officialTitle: "Link Live", groups: [], eventType: .live,
            status: .scheduled, primarySourceURL: "https://www.lovelive-anime.jp/", timeZone: "Asia/Tokyo")
        let first = Performance(id: "live-0", eventID: "live", stopID: nil, dayLabel: "Day 1", subtitle: "昼",
            localDate: "2027-03-01", doorsAt: nil, startAt: morning, venueName: "Tokyo Dome", venueCity: "Tokyo",
            performers: [], order: 0, precision: .minute, timeZone: "Asia/Tokyo")
        let second = Performance(id: "live-1", eventID: "live", stopID: nil, dayLabel: "Day 2", subtitle: nil,
            localDate: "2027-03-02", doorsAt: nil, startAt: evening, venueName: "K-Arena", venueCity: "Yokohama",
            performers: [], order: 1, precision: .minute, timeZone: "Asia/Tokyo")
        store.acceptRefreshedBundle(LiveEventBundle(schemaVersion: 1, publishedAt: .distantPast, event: event, stops: [],
            performances: [first, second], ticketTiers: [], ticketRounds: [], ticketOffers: [], goodsCampaigns: [],
            mediaAssets: [], notices: [], evidence: []))

        let summary = try XCTUnwrap(store.visibleSummaries.first)
        XCTAssertEqual(summary.days.map(\.id), ["live-0", "live-1"])
        XCTAssertTrue(summary.days[0].primaryText.contains("Day 1"))
        XCTAssertTrue(summary.days[0].primaryText.contains(EventFormatting.clockTime(morning, in: zone)))
        XCTAssertEqual(summary.days[0].secondaryText, "昼 · Tokyo Dome · Tokyo")
        XCTAssertTrue(summary.days[1].secondaryText.contains("K-Arena"))
        XCTAssertTrue(summary.days[1].secondaryText.contains("Yokohama"))
        XCTAssertFalse(summary.days[0].isParticipating)
        XCTAssertTrue(LiveEventCard(summary: summary).accessibilitySummary.contains(summary.days[0].primaryText))

        store.toggleDayParticipation(eventID: "live", performanceID: "live-0")
        let marked = try XCTUnwrap(store.visibleSummaries.first)
        XCTAssertEqual(marked.days.map(\.isParticipating), [true, false])

        userData.setPlanningToAttend(true, eventID: "live")
        let everyone = try XCTUnwrap(store.visibleSummaries.first)
        XCTAssertEqual(everyone.days.map(\.isParticipating), [true, true])

        store.toggleDayParticipation(eventID: "live", performanceID: "live-1")
        let partial = try XCTUnwrap(store.visibleSummaries.first)
        XCTAssertEqual(partial.days.map(\.isParticipating), [true, false])
    }

    func testAccessibilitySummaryContainsTitleAndZoneLabel() {
        let deadline = ISO8601DateFormatter().date(from: "2026-10-01T05:00:00Z")!
        let summary = DashboardEventSummary(
            id: "ev1", officialTitle: "Poppin'Party 10th LIVE", primarySourceURL: "https://example.com",
            groups: ["Poppin'Party"], franchise: .bangdream, status: .scheduled, eventType: .live,
            isFollowed: false, dayLabels: ["Day 1"], stopCount: 1, venueSummary: "Tokyo Dome",
            firstLocalDate: "2026-10-01", lastLocalDate: "2026-10-01", firstStartAt: deadline,
            officialThumbnail: nil, minimumPriceJPY: 8800, currentRoundLabel: "一般",
            ticketBadges: [
                TicketPhaseBadge(text: String(localized: "一般贩售中", bundle: .kit), tone: .open),
                TicketPhaseBadge(text: String(localized: "已售罄", bundle: .kit), tone: .soldOut),
            ],
            nextDeadline: deadline, hasPendingAction: true, hasImportantUpdate: false,
            timeZoneIdentifier: "Asia/Tokyo", days: []
        )
        let card = LiveEventCard(summary: summary)
        let text = card.accessibilitySummary

        XCTAssertTrue(text.contains("Poppin'Party 10th LIVE"))
        XCTAssertTrue(text.contains(String(localized: "一般贩售中", bundle: .kit)), "summary should include the on-sale badge; got: \(text)")
        XCTAssertTrue(text.contains(String(localized: "已售罄", bundle: .kit)), "summary should include the sold-out badge; got: \(text)")
        // The zone name depends on the test locale ("JST" vs "GMT+9"), so compare against the
        // same helper the card uses instead of a literal.
        let zoneLabel = EventFormatting.zoneLabel(TimeZone(identifier: "Asia/Tokyo")!)
        XCTAssertFalse(zoneLabel.isEmpty)
        XCTAssertTrue(text.contains(zoneLabel), "should include the zone label EventFormatting.dateTime appends (\(zoneLabel)); got: \(text)")
    }
}

/// A minimal `LiveRepository` that counts `refresh()` calls and holds each pass open briefly,
/// so concurrent callers actually overlap instead of trivially serializing.
private actor CountingRepository: LiveRepository {
    private(set) var refreshCallCount = 0
    private let bundles: [LiveEventBundle]

    init(bundles: [LiveEventBundle]) { self.bundles = bundles }

    func allBundles() async throws -> [LiveEventBundle] { bundles }
    func bundle(eventID: String) async throws -> LiveEventBundle? { bundles.first { $0.event.id == eventID } }
    func refresh() async throws -> [LiveEventBundle] {
        refreshCallCount += 1
        try? await Task.sleep(nanoseconds: 50_000_000)
        return bundles
    }
    func changes(eventID: String) async throws -> [EventChangeHistory] { [] }
    func clearPublicCache() async throws {}
}
