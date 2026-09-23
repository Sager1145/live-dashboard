import XCTest
@testable import LiveDashboardKit

@MainActor
final class DashboardPresentationTests: XCTestCase {
    private func store() -> DashboardStore {
        DashboardStore(repository: LocalLiveRepository(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            userDataStore: UserDataStore(container: UserDataStore.makeContainer(inMemory: true)))
    }

    private func bundle(_ id: String, dates: [String?], starts: [Date?] = [], media: [MediaAsset] = []) -> LiveEventBundle {
        let event = LiveEvent(id: id, franchise: .lovelive, officialTitle: id, groups: [], eventType: .live,
            status: .scheduled, primarySourceURL: "https://www.lovelive-anime.jp/", timeZone: "Asia/Tokyo")
        let performances = dates.enumerated().map { index, date in
            Performance(id: "\(id)-\(index)", eventID: id, stopID: nil, dayLabel: "Day \(index + 1)", subtitle: nil,
                localDate: date, doorsAt: nil, startAt: starts.indices.contains(index) ? starts[index] : nil,
                venueName: "Tokyo", venueCity: "Tokyo", performers: [], order: index)
        }
        return LiveEventBundle(schemaVersion: 1, publishedAt: .distantPast, event: event, stops: [], performances: performances,
            ticketTiers: [], ticketRounds: [], ticketOffers: [], goodsCampaigns: [], mediaAssets: media, notices: [], evidence: [])
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
