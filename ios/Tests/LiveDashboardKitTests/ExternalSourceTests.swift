import XCTest
@testable import LiveDashboardKit

final class ExternalSourceTests: XCTestCase {
    func testEventernoteParserKeepsDescriptionEmptyAndCapacityText() throws {
        let list = try EventernoteHTMLParser.eventList(in: """
        <ul class="gb_event_list">
        <li class="clearfix"><div class="date"><p>2026-05-01 (金)</p></div>
        <div class="event"><h4><a href="/events/107761">昼公演</a></h4>
        <div class="place"><a href="/places/9">東京ドーム</a> 開場 13:00 開演 14:00</div></div></li>
        </ul>
        """)
        XCTAssertEqual(list.map(\.id), ["107761"])
        XCTAssertEqual(list.first?.startTime, "14:00")
        let detail = try EventernoteHTMLParser.eventDetail(in: """
        <div class="gb_events_detail_title"><h2>昼公演</h2></div>
        <table><tr><td>開催日時</td><td>2026-05-01 (金)</td></tr>
        <tr><td>時間</td><td>開場 13:00 開演 14:00 終演 16:00</td></tr>
        <tr><td>開催場所</td><td><a href="/places/9">東京ドーム</a></td></tr>
        <tr><td>関連リンク</td><td><a href="https://www.lovelive-anime.jp/live/">official</a></td></tr>
        <tr><td>説明</td><td>票价 9000 円</td></tr></table>
        """, pageURL: URL(string: "https://www.eventernote.com/events/107761")!)
        XCTAssertNil(detail.description)
        XCTAssertEqual(detail.links, ["https://www.lovelive-anime.jp/live/"])
        XCTAssertEqual(detail.event.endTime, "16:00")
        let place = try EventernoteHTMLParser.placeDetail(in: """
        <div class="gb_place_detail_title"><h2>東京ドーム</h2></div>
        <table><tr><td>所在地</td><td>〒112-0004 文京区</td></tr>
        <tr><td>収容人数</td><td>約55,000人</td></tr>
        <tr><td>座席情報</td><td><a href="/places/9/seat">seat</a></td></tr></table>
        <script>var lat = '35.7'; var lon = '139.7';</script>
        """, pageURL: URL(string: "https://www.eventernote.com/places/9")!)
        XCTAssertEqual(place.capacity, "約55,000人")
        XCTAssertFalse(FieldMergePolicy.seatMapIsPerformanceConfiguration(officialPageLinksThisPerformance: false))
        XCTAssertThrowsError(try EventernoteHTMLParser.eventList(in: "<title>ページが見つかりません</title>"))
    }

    func testFilteredEmptyPageDoesNotLookFinishedAndRegionNeedsVenueData() async throws {
        let transport = FixtureTransport(bodies: [
            "/actors/3/events": "<li class=\"clearfix\"><h4><a href=\"/events/1\">Other</a></h4><p>2026-05-01</p></li>",
            "/": "<meta id=\"crumb\" content=\"c\">"
        ])
        let client = EventernoteClient(transport: transport, budget: EventernoteBudget(maxRequests: 2))
        let page = try await client.listEvents(EventernoteEventQuery(keyword: "Morfonica", actorID: "3"))
        XCTAssertEqual(page.rawCount, 1)
        XCTAssertTrue(page.matched.isEmpty)
        XCTAssertFalse(page.reachedBudget)
        do {
            _ = try await client.listEvents(EventernoteEventQuery(region: "1", actorID: "3"))
            XCTFail("region filter is not applied on actor pages")
        } catch EventernoteClientError.unsupportedFilter {}
    }

    func testSnapshotKeepsMissingExtraAndDuplicateTargets() throws {
        let files = [
            "performance-info.json": Data("""
            [{"id":"12","eventId":10,"concertId":10,"tourName":"Tour","date":"2026-05-01","venue":"Hall","seriesIds":["1"],"status":"upcoming","hasSetlist":true},
             {"id":"13","eventId":10,"concertId":10,"tourName":"Tour","date":"2026-05-02","venue":"Hall","seriesIds":[2],"status":"completed","hasSetlist":false,"category":"mystery"}]
            """.utf8),
            "event-extra.json": Data("""
            {"12":{"startTime":"14:00","canceled":false,"venueId":"v1"}}
            """.utf8),
            "eventernote-map.json": Data("""
            {"38":"147583","39":"147583"}
            """.utf8),
            "venue-info.json": Data("""
            [{"id":"v1","name":"Hall","source":"osm","confidence":0.4,"reviewRequired":true,"lat":1,"lng":2}]
            """.utf8),
            "performance-setlists.json": Data("""
            {"12":{"id":"s","performanceId":"12","isActual":false,"items":[{"id":"a","type":"encore","position":0,"title":"未分类"}],"sections":[]}}
            """.utf8)
        ]
        let catalog = try LLerNoteSnapshotDecoder.decode(files: files, revision: UpstreamSourceRegistry.llernoteRevision)
        let first = try XCTUnwrap(catalog.performances.first { $0.id == "12" })
        let second = try XCTUnwrap(catalog.performances.first { $0.id == "13" })
        XCTAssertEqual(first.canceled, false)
        XCTAssertNil(second.canceled)
        XCTAssertEqual(second.category, "mystery")
        XCTAssertEqual(second.seriesIDs, ["2"])
        XCTAssertEqual(catalog.eventernoteTargets["147583"], ["38", "39"])
        XCTAssertEqual(catalog.setlist(performanceID: "12")?.items.first?.type, "encore")
        XCTAssertEqual(catalog.setlist(performanceID: "12")?.isActual, false)
        XCTAssertEqual(catalog.venue(id: "v1")?.reviewRequired, true)
    }

    func testMatcherDoesNotMergeDayNightOrRewriteIDs() {
        let day = LocalSession(performanceID: "p-day", eventID: "e", localDate: "2026-05-01", startTime: "14:00", dayLabel: "昼", venueName: "東京ドーム", title: "Tour", officialURL: "https://example.com/tour")
        let night = LocalSession(performanceID: "p-night", eventID: "e", localDate: "2026-05-01", startTime: "18:00", dayLabel: "夜", venueName: "東京ドーム", title: "Tour", officialURL: "https://example.com/tour")
        let observed = ObservedSession(llfansPerformanceID: "13", eventernoteEventID: "107762", localDate: "2026-05-01", startTime: "18:00", dayLabel: "夜", venueName: "東京ドーム", title: "Tour")
        let matches = PerformanceMatcher.match(locals: [day, night], observed: observed)
        XCTAssertEqual(matches.first { $0.localPerformanceID == "p-day" }?.relation, .rejected)
        XCTAssertEqual(matches.first { $0.localPerformanceID == "p-night" }?.relation, .exactSession)
        XCTAssertEqual(Set(matches.map(\.localPerformanceID)), ["p-day", "p-night"])

        let duplicate = ObservedSession(llfansPerformanceID: "38", eventernoteEventID: "147583", localDate: "2026-05-01", startTime: "18:00", venueName: "東京ドーム", title: "Tour", duplicateEventernoteTarget: true)
        XCTAssertEqual(PerformanceMatcher.match(locals: [night], observed: duplicate).first?.relation, .groupedEvent)

        let later = ObservedSession(llfansPerformanceID: "14", eventernoteEventID: "9", localDate: "2026-06-01", startTime: "18:00", venueName: "Hall", title: "Tour", officialLinks: ["https://example.com/tour"])
        XCTAssertEqual(PerformanceMatcher.match(locals: [day], observed: later).first?.relation, .groupedEvent)

        let postponed = PerformanceMatcher.match(locals: [night], observed: ObservedSession(llfansPerformanceID: "13", eventernoteEventID: "107762", localDate: "2026-07-01"), linkedLocalID: "p-night")
        XCTAssertEqual(postponed.first?.localPerformanceID, "p-night")
        XCTAssertEqual(postponed.first?.relation, .exactSession)
    }

    func testCommunityDiffAndSetlistDoNotOverwriteOfficialFacts() {
        let event = LiveEvent(id: "e", franchise: .lovelive, officialTitle: "Tour", groups: [], eventType: .live, status: .scheduled, primarySourceURL: "https://example.com/tour", timeZone: "Asia/Tokyo")
        let performance = Performance(id: "p", eventID: "e", stopID: nil, dayLabel: "夜", subtitle: nil, localDate: "2026-05-01", doorsAt: nil, startAt: ISO8601DateFormatter().date(from: "2026-05-01T09:00:00Z"), venueName: "Hall", venueCity: "", performers: [], order: 0)
        let community = LLerPerformance(id: "13", eventID: "10", concertID: "10", tourName: "Tour", date: "2026-05-01", venueName: "Other", venueID: "v", seriesIDs: [], status: "completed", hasSetlist: true, performanceName: nil, concertName: nil, openTime: "17:00", startTime: "19:00", tourType: nil, canceled: true, note: nil, category: nil)
        let setlist = LLerSetlist(id: "s", performanceID: "13", items: [LLerSetlistItem(id: "a", type: "mystery", position: 1, songID: nil, customSongName: nil, isCustomSong: nil, title: "MC", remarks: nil)], sections: [], isActual: false)
        let enrichment = CommunityEnrichmentBuilder.make(performance: performance, event: event, community: community, references: [], setlist: setlist, songs: [], venue: LLerVenue(id: "v", name: "Other", source: "osm", sourceID: nil, confidence: 0.2, reviewRequired: true, address: "addr", latitude: nil, longitude: nil, country: nil, region: nil, locality: nil, website: nil))
        XCTAssertEqual(enrichment.diffs.first { $0.field == "开演" }?.officialText, "18:00")
        XCTAssertEqual(enrichment.diffs.first { $0.field == "开演" }?.communityText, "19:00")
        XCTAssertEqual(enrichment.diffs.first { $0.field == "取消" }?.outcome, "保留官网状态")
        XCTAssertEqual(enrichment.setlist?.isActual, false)
        XCTAssertEqual(enrichment.setlist?.rows.first?.type, "mystery")
        XCTAssertEqual(enrichment.venue?.reviewRequired, true)
        XCTAssertEqual(performance.id, "p")
        XCTAssertEqual(event.status, .scheduled)
    }

    func testBackupPreviewIsIdempotentAndDoesNotDropUnmatchedOrConflicts() throws {
        let backup = Data("""
        {"version":2,"exportedAt":"2026-09-23T00:00:00Z","attendance":{
          "12":{"performanceId":"12","status":"attended","createdAt":"2026-09-01T00:00:00Z","updatedAt":"2026-09-02T00:00:00Z"},
          "13":{"performanceId":"13","status":"interested","deleted":true,"createdAt":"2026-09-01T00:00:00Z","updatedAt":"2026-09-02T00:00:00Z"},
          "99":{"performanceId":"99","status":"attended","createdAt":"2026-09-01T00:00:00Z","updatedAt":"2026-09-02T00:00:00Z"}
        }}
        """.utf8)
        let preview = try LLerNoteBackupImporter.preview(data: backup) { id in
            if id == "12" { return BackupPerformanceLocator(eventID: "e", performanceID: "p12", explicitParticipation: nil) }
            if id == "13" { return BackupPerformanceLocator(eventID: "e", performanceID: "p13", explicitParticipation: true) }
            return nil
        }
        let again = try LLerNoteBackupImporter.preview(data: backup) { id in
            if id == "12" { return BackupPerformanceLocator(eventID: "e", performanceID: "p12", explicitParticipation: nil) }
            if id == "13" { return BackupPerformanceLocator(eventID: "e", performanceID: "p13", explicitParticipation: true) }
            return nil
        }
        XCTAssertEqual(preview, again)
        XCTAssertEqual(preview.unmatchedSourceIDs, ["99"])
        XCTAssertEqual(preview.conflicts.map(\.performanceID), ["p13"])
        XCTAssertTrue(preview.conflicts.first?.tombstone == true)
        XCTAssertEqual(LLerNoteBackupImporter.changes(from: preview).map(\.performanceID), ["p12"])
        XCTAssertThrowsError(try LLerNoteBackupImporter.preview(data: Data("{\"version\":3,\"attendance\":{}}".utf8)) { _ in nil })
    }

    func testRejectedSnapshotDoesNotReplaceCommunityCatalogOrOfficialFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let official = root.appendingPathComponent("LiveDashboard/OfficialCatalog/catalog.json")
        try FileManager.default.createDirectory(at: official.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("official".utf8).write(to: official)
        let store = ExternalDataStore(directory: root.appendingPathComponent("LiveDashboard/ExternalCatalog"))
        let files = ["performance-info.json": Data("[{\"id\":\"12\",\"tourName\":\"Tour\",\"date\":\"2026-05-01\",\"venue\":\"Hall\",\"seriesIds\":[],\"status\":\"upcoming\",\"hasSetlist\":false}]".utf8)]
        let first = try await CommunityIngestor.ingest(files: files, revision: "rev-a", locals: [], into: store)
        XCTAssertEqual(first.admission, .activate)
        let shrunk = try await CommunityIngestor.ingest(files: ["performance-info.json": Data("[]".utf8)], revision: "rev-b", locals: [], into: store)
        guard case .keepPrevious = shrunk.admission else { return XCTFail("shrink should keep the previous snapshot") }
        let catalog = try await store.communityCatalog()
        XCTAssertEqual(catalog?.performances.map(\.id), ["12"])
        XCTAssertEqual(try await store.revision(for: .llernote)?.upstreamRevision, "rev-a")
        XCTAssertEqual(try Data(contentsOf: official), Data("official".utf8))
    }
}

private struct FixtureTransport: EventernoteTransport {
    var bodies: [String: String]
    func response(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url?.path ?? ""
        let body = bodies[path] ?? ""
        let status = body.isEmpty ? 404 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!
        return (Data(body.utf8), response)
    }
}
