import XCTest
@testable import LiveDashboardKit

final class ExternalCatalogTests: XCTestCase {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    private func provenance(
        provider: ExternalProvider,
        origin: ExternalProvider,
        revision: String = "rev",
        hops: [SourceHop] = []
    ) -> SourceProvenance {
        SourceProvenance(
            provider: provider, originProvider: origin, upstreamRevision: revision,
            fetchedAt: date("2026-09-23T00:00:00Z"), locator: "data/performance-info.json", derivedFrom: hops
        )
    }

    private func reference(
        localID: String,
        rawID: String,
        namespace: ExternalNamespace = .eventernote,
        entity: ExternalEntityKind = .event,
        relation: ExternalRelationKind = .candidate
    ) -> ExternalReference {
        ExternalReference(
            local: LocalEntityRef(kind: .performance, id: localID),
            external: ExternalIdentity(namespace: namespace, entity: entity, rawID: rawID),
            relation: relation,
            provenance: provenance(provider: .llernote, origin: .llfans, revision: UpstreamSourceRegistry.llernoteRevision)
        )
    }

    private func snapshot(
        revision: String,
        recordCount: Int,
        fileRevision: String? = nil
    ) -> ExternalSnapshotRevision {
        ExternalSnapshotRevision(
            provider: .llernote,
            upstreamRevision: revision,
            files: [
                ExternalSnapshotFile(path: "performance-info.json", sha256: "abc", upstreamRevision: fileRevision ?? revision),
                ExternalSnapshotFile(path: "event-extra.json", sha256: "def", upstreamRevision: fileRevision ?? revision)
            ],
            recordCount: recordCount
        )
    }

    func testNumericIDsStayInsideTheirNamespace() {
        let eventernote = ExternalIdentity(namespace: .eventernote, entity: .event, rawID: "12")
        let llfans = ExternalIdentity(namespace: .llfans, entity: .performance, rawID: "12")
        XCTAssertNotEqual(eventernote, llfans)
        XCTAssertEqual(eventernote.key, "eventernote:event:12")
        XCTAssertEqual(llfans.key, "llfans:performance:12")
    }

    func testDuplicateEventernoteTargetsAccumulateInsteadOfOverwriting() {
        let index = ExternalReferenceIndex(references: [
            reference(localID: "38", rawID: "147583", relation: .groupedEvent),
            reference(localID: "39", rawID: "147583", relation: .groupedEvent),
            reference(localID: "79", rawID: "163561", relation: .candidate),
            reference(localID: "80", rawID: "163561", relation: .rejected)
        ])
        let shared = ExternalIdentity(namespace: .eventernote, entity: .event, rawID: "147583")
        XCTAssertEqual(index.localIDs(for: shared), ["38", "39"])
        let overwritten = ExternalIdentity(namespace: .eventernote, entity: .event, rawID: "163561")
        XCTAssertEqual(index.localIDs(for: overwritten), ["79"])
        XCTAssertEqual(index.localIDs(for: overwritten, includeRejected: true), ["79", "80"])
    }

    func testLLerNoteDoesNotCorroborateItsLLFansOrigin() {
        let llfans = provenance(provider: .llfans, origin: .llfans, revision: "fans")
        let llernote = provenance(
            provider: .llernote, origin: .llfans, revision: UpstreamSourceRegistry.llernoteRevision,
            hops: [SourceHop(provider: .llfans, revision: "fans", locator: nil)]
        )
        let eventernote = provenance(provider: .eventernote, origin: .eventernote, revision: UpstreamSourceRegistry.eventernoteRevision)
        XCTAssertFalse(llfans.independentlyCorroborates(llernote))
        XCTAssertTrue(eventernote.independentlyCorroborates(llernote))
    }

    func testRegisteredSourcesRefuseTicketFactsAndAccountSync() {
        XCTAssertEqual(UpstreamSourceRegistry.eventernote.pinnedRevision, "ca823bca6596255864ecd511c981088a87d0a1b9")
        XCTAssertEqual(UpstreamSourceRegistry.llernote.pinnedRevision, "85791aced3e8dc7467622ad9a72072699dc98230")
        XCTAssertEqual(UpstreamSourceRegistry.eventernote.license, .mitClientCodeOnly)
        XCTAssertEqual(UpstreamSourceRegistry.llernote.license, .unspecified)
        XCTAssertEqual(UpstreamSourceRegistry.llernote.originProvider, .llfans)
        for source in [UpstreamSourceRegistry.eventernote, UpstreamSourceRegistry.llernote] {
            XCTAssertFalse(source.allows(.ticketFacts))
            XCTAssertFalse(source.allows(.goodsFacts))
            XCTAssertFalse(source.allows(.accountSync))
            XCTAssertFalse(source.allows(.eventDescription))
        }
        XCTAssertTrue(UpstreamSourceRegistry.eventernote.allows(.eventDiscovery))
        XCTAssertTrue(UpstreamSourceRegistry.llernote.allows(.historicalCatalog))
        XCTAssertNil(UpstreamSourceRegistry.registration(for: .llfans))
    }

    func testCommunityValuesDoNotReplaceOfficialFields() {
        let cancelled = FieldMergePolicy.merge(official: .value(EventStatus.scheduled), community: EventStatus.cancelled)
        XCTAssertEqual(cancelled, .retainOfficial(.scheduled, community: .cancelled))
        XCTAssertEqual(
            FieldMergePolicy.merge(official: .unpublished, community: Optional("fan time")),
            .unpublished(community: "fan time")
        )
        XCTAssertEqual(
            FieldMergePolicy.merge(official: .unparsed(stale: Optional("2026-01-01")), community: "2026-02-01"),
            .staleOfficial(retained: "2026-01-01", community: "2026-02-01", reason: .unparsed)
        )
        XCTAssertEqual(
            FieldMergePolicy.merge(official: .requestFailed(stale: Optional("old")), community: "new"),
            .staleOfficial(retained: "old", community: "new", reason: .requestFailed)
        )
        XCTAssertEqual(FieldMergePolicy.merge(official: .absent, community: Optional("guess")), .absent(community: "guess"))
        XCTAssertFalse(FieldMergePolicy.mayAttachCommunitySupplement(.ticketPrice))
        XCTAssertFalse(FieldMergePolicy.mayAttachCommunitySupplement(.paymentDeadline))
        XCTAssertFalse(FieldMergePolicy.mayAttachCommunitySupplement(.performanceSeatMap))
        XCTAssertTrue(FieldMergePolicy.mayAttachCommunitySupplement(.venueGenericSeatMap))
        XCTAssertFalse(FieldMergePolicy.seatMapIsPerformanceConfiguration(officialPageLinksThisPerformance: false))
        XCTAssertTrue(FieldMergePolicy.seatMapIsPerformanceConfiguration(officialPageLinksThisPerformance: true))
    }

    func testSameDaySessionsAndTourURLsStayDistinct() {
        let day = SessionCandidate(localDate: "2026-05-01", startTime: "14:00", dayPartLabel: "昼公演", title: "Live", parentOfficialURL: "https://example.com/tour/", performanceID: "day")
        let night = SessionCandidate(localDate: "2026-05-01", startTime: "18:00", dayPartLabel: "夜公演", title: "Live", parentOfficialURL: "https://example.com/tour", performanceID: "night")
        XCTAssertEqual(SessionIdentityGuard.compare(day, night), .hardConflict(.sameDayDifferentStart))
        XCTAssertEqual(SessionIdentityGuard.compare(night, day), .hardConflict(.sameDayDifferentStart))

        let matinee = SessionCandidate(localDate: "2026-05-01", startTime: nil, dayPartLabel: "マチネ", title: "Live", parentOfficialURL: nil, performanceID: "m")
        let soiree = SessionCandidate(localDate: "2026-05-01", startTime: nil, dayPartLabel: "ソワレ", title: "Live", parentOfficialURL: nil, performanceID: "s")
        XCTAssertEqual(SessionIdentityGuard.compare(matinee, soiree), .hardConflict(.sameDayDifferentDayPart))

        let daytime = SessionCandidate(localDate: "2026-05-01", startTime: "18:00", dayPartLabel: "昼", title: "Live", parentOfficialURL: nil, performanceID: "d")
        let nighttime = SessionCandidate(localDate: "2026-05-01", startTime: "18:00", dayPartLabel: "夜", title: "Live", parentOfficialURL: nil, performanceID: "n")
        XCTAssertEqual(SessionIdentityGuard.compare(daytime, nighttime), .hardConflict(.sameDayDifferentDayPart))

        let first = SessionCandidate(localDate: "2026-05-01", startTime: nil, dayPartLabel: "DAY1", title: "Live", parentOfficialURL: nil, performanceID: "1")
        let second = SessionCandidate(localDate: "2026-05-01", startTime: nil, dayPartLabel: "DAY 2", title: "Live", parentOfficialURL: nil, performanceID: "2")
        XCTAssertEqual(SessionIdentityGuard.compare(first, second), .hardConflict(.sameDayDifferentSessionLabel))

        let tokyo = SessionCandidate(localDate: "2026-05-01", startTime: nil, dayPartLabel: "DAY1", title: "Tour", parentOfficialURL: "https://example.com/tour", performanceID: "tokyo")
        let osaka = SessionCandidate(localDate: "2026-05-02", startTime: nil, dayPartLabel: "DAY2", title: "Tour", parentOfficialURL: "http://example.com/tour/", performanceID: "osaka")
        XCTAssertEqual(SessionIdentityGuard.compare(tokyo, osaka), .sameParentActivity)

        let postponed = SessionCandidate(localDate: "2026-06-01", startTime: "18:00", dayPartLabel: "DAY1", title: "Tour", parentOfficialURL: "https://example.com/tour", performanceID: "stable")
        var moved = postponed
        moved.localDate = "2026-07-01"
        XCTAssertEqual(SessionIdentityGuard.compare(postponed, moved), .stableIdentity("stable"))

        let titled = SessionCandidate(localDate: "2026-05-01", startTime: nil, dayPartLabel: nil, title: "Live", parentOfficialURL: nil, performanceID: "a")
        var other = titled
        other.performanceID = "b"
        XCTAssertEqual(SessionIdentityGuard.compare(titled, other), .unresolvedCandidate)
    }

    func testUnknownTimeZoneDoesNotBecomeJapan() {
        XCTAssertNil(LocalPerformanceClock.instant(localDate: "2026-04-01", time: "18:00", timeZone: nil))
        let tokyo = LocalPerformanceClock.instant(localDate: "2026-04-01", time: "18:00", timeZone: TimeZone(identifier: "Asia/Tokyo"))
        let london = LocalPerformanceClock.instant(localDate: "2026-04-01", time: "18:00", timeZone: TimeZone(identifier: "Europe/London"))
        XCTAssertEqual(tokyo, date("2026-04-01T09:00:00Z"))
        XCTAssertEqual(london, date("2026-04-01T17:00:00Z"))
        XCTAssertNotEqual(tokyo, london)
    }

    func testStoreKeepsLocalIDsAndSurvivesABadSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let official = root.appendingPathComponent("LiveDashboard/OfficialCatalog/catalog.json")
        try FileManager.default.createDirectory(at: official.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("official".utf8).write(to: official)

        let store = ExternalDataStore(directory: root.appendingPathComponent("LiveDashboard/ExternalCatalog"))
        XCTAssertTrue(store.fileURL.path.contains("ExternalCatalog"))
        XCTAssertFalse(store.fileURL.path.contains("OfficialCatalog"))

        let first = reference(localID: "p-38", rawID: "147583", relation: .groupedEvent)
        let second = reference(localID: "p-39", rawID: "147583", relation: .groupedEvent)
        try await store.upsert(first)
        try await store.upsert(second)
        let saved = try await store.references()
        XCTAssertEqual(saved.map(\.local.id).sorted(), ["p-38", "p-39"])
        let linked = try await store.localIDs(for: first.external)
        XCTAssertEqual(linked, ["p-38", "p-39"])

        let activated = snapshot(revision: UpstreamSourceRegistry.llernoteRevision, recordCount: 100)
        let admitted = try await store.proposeSnapshot(activated, at: date("2026-09-23T01:00:00Z"))
        let mixed = try await store.proposeSnapshot(snapshot(revision: "other", recordCount: 100, fileRevision: "mixed"))
        let shrunk = try await store.proposeSnapshot(snapshot(revision: "smaller", recordCount: 40))
        XCTAssertEqual(admitted, .activate)
        XCTAssertEqual(mixed, .keepPrevious(.mixedFileRevisions))
        XCTAssertEqual(shrunk, .keepPrevious(.abnormalShrink))

        let kept = try await store.revision(for: .llernote)
        let storedReferences = try await store.references()
        XCTAssertEqual(kept?.upstreamRevision, UpstreamSourceRegistry.llernoteRevision)
        XCTAssertEqual(kept?.recordCount, 100)
        XCTAssertEqual(kept?.state, .stale)
        XCTAssertEqual(storedReferences.count, 2)

        try await store.markSourceMissing(first.external)
        let missing = try await store.references()
        XCTAssertEqual(missing.count, 2)
        XCTAssertTrue(missing.allSatisfy { $0.availability == .sourceMissing })
        XCTAssertEqual(try Data(contentsOf: official), Data("official".utf8))

        let roundTrip = try LiveEventBundle.decoder.decode([ExternalReference].self, from: LiveEventBundle.encoder.encode(missing))
        XCTAssertEqual(roundTrip, missing)
    }

    func testCorruptExternalCatalogIsNotReplaced() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("catalog.json")
        try Data("{".utf8).write(to: file)
        let store = ExternalDataStore(directory: directory)
        do {
            _ = try await store.proposeSnapshot(snapshot(revision: "rev", recordCount: 10))
            XCTFail("corrupt catalog should not be replaced")
        } catch {
            XCTAssertEqual(try Data(contentsOf: file), Data("{".utf8))
        }
    }

    func testOfficialCatalogDirectoryIsRefused() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("OfficialCatalog")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let store = ExternalDataStore(directory: directory)
        do {
            try await store.upsert(reference(localID: "p", rawID: "1"))
            XCTFail("official directory should be refused")
        } catch ExternalStoreError.officialCatalogDirectory {
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
