import XCTest
@testable import LiveDashboardKit

@MainActor
final class TranslationStoreTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        tempDirectory = nil
        super.tearDown()
    }

    private func makeStore(provider: TranslationProviding = StubTranslationProvider()) -> TranslationStore {
        TranslationStore(provider: provider, directory: tempDirectory)
    }

    // MARK: - Cache round-trip

    func testCacheRoundTripPersistsAcrossInstances() async {
        let store = makeStore()
        XCTAssertNil(store.cached("こんにちは", target: .zhHans))

        store.request(items: [TranslationRequestItem(id: "a", text: "こんにちは")], target: .zhHans)
        store.store(results: [TranslationResultItem(id: "a", text: "你好")], target: .zhHans)

        XCTAssertEqual(store.cached("こんにちは", target: .zhHans), "你好")

        // The cache write is debounced and happens off the main actor; wait
        // for it before reading it back from a fresh instance.
        await store.flushPendingSave()

        // A fresh store instance pointed at the same directory should load the persisted cache.
        let reloaded = makeStore()
        XCTAssertEqual(reloaded.cached("こんにちは", target: .zhHans), "你好")
    }

    func testCacheIsScopedByTargetLanguage() {
        let store = makeStore()
        store.request(items: [TranslationRequestItem(id: "a", text: "こんにちは")], target: .zhHans)
        store.store(results: [TranslationResultItem(id: "a", text: "你好")], target: .zhHans)

        XCTAssertNil(store.cached("こんにちは", target: .en))
    }

    // MARK: - sourceSegments filtering

    func testSourceSegmentsSkipsURLsASCIIOnlyAndNumericAndDedupes() {
        let store = makeStore()
        let bundle = Self.makeBundle(
            officialTitle: "ライブ2026",
            performers: ["ライブ2026", "https://example.com", "12345", "Band ABC", "ライブ2026"]
        )

        let segments = store.sourceSegments(for: bundle, performanceID: nil)
        let texts = segments.map(\.text)

        XCTAssertTrue(texts.contains("ライブ2026"))
        XCTAssertFalse(texts.contains("https://example.com"))
        XCTAssertFalse(texts.contains("12345"))
        XCTAssertFalse(texts.contains("Band ABC"))
        // Deduped: "ライブ2026" appears as both the event title and a performer name.
        XCTAssertEqual(texts.filter { $0 == "ライブ2026" }.count, 1)
    }

    func testSourceSegmentsFiltersByPerformanceID() {
        let store = makeStore()
        let bundle = Self.makeBundle(officialTitle: "公演", performers: ["出演者A"], secondPerformancePerformers: ["出演者B"])

        let firstOnly = store.sourceSegments(for: bundle, performanceID: "perf-1")
        XCTAssertTrue(firstOnly.map(\.text).contains("出演者A"))
        XCTAssertFalse(firstOnly.map(\.text).contains("出演者B"))
    }

    // MARK: - request() cache filtering

    func testRequestFiltersAlreadyCachedItemsLeavingOnlyUncachedPending() {
        let store = makeStore()
        store.request(items: [TranslationRequestItem(id: "a", text: "こんにちは")], target: .zhHans)
        store.store(results: [TranslationResultItem(id: "a", text: "你好")], target: .zhHans)

        store.request(
            items: [
                TranslationRequestItem(id: "a", text: "こんにちは"),
                TranslationRequestItem(id: "b", text: "さようなら"),
            ],
            target: .zhHans
        )

        XCTAssertEqual(store.pendingRequests.map(\.id), ["b"])
    }

    // MARK: - Same-pair requests merge into one batch (fix 2 + fix 3)

    func testSameTargetSecondRequestMergesIntoPendingBatchInsteadOfReplacingIt() {
        let store = makeStore()
        store.request(items: [TranslationRequestItem(id: "a", text: "こんにちは")], target: .zhHans)
        XCTAssertEqual(store.pendingRequests.map(\.id), ["a"])

        // A second request for the same language pair, made before the first
        // batch finished, must merge into the running batch rather than
        // replacing it (and rely on invalidating the *same* Configuration,
        // never assigning a fresh equal one, to re-trigger `.translationTask`).
        store.request(items: [TranslationRequestItem(id: "b", text: "さようなら")], target: .zhHans)
        XCTAssertEqual(Set(store.pendingRequests.map(\.id)), ["a", "b"])
        XCTAssertEqual(store.phase, .translating(count: 2))
    }

    #if canImport(Translation)
    func testSameTargetSecondRequestReusesConfigurationIdentity() {
        let store = makeStore()
        store.request(items: [TranslationRequestItem(id: "a", text: "こんにちは")], target: .zhHans)
        let firstVersion = store.configuration?.version

        store.request(items: [TranslationRequestItem(id: "b", text: "さようなら")], target: .zhHans)
        let secondVersion = store.configuration?.version

        // Same source/target pair: the configuration is invalidated in place
        // (its internal version advances) rather than replaced with a new
        // instance.
        XCTAssertNotNil(firstVersion)
        XCTAssertNotNil(secondVersion)
        XCTAssertNotEqual(firstVersion, secondVersion)
    }
    #endif

    // MARK: - Generation guards a stale batch from clobbering a newer one (fix 3)

    func testOlderGenerationStoreDoesNotClearNewerPendingBatch() {
        let store = makeStore()
        store.request(items: [TranslationRequestItem(id: "a", text: "こんにちは")], target: .zhHans)
        let firstGeneration = store.currentGeneration

        // A newer request merges in "b" and bumps the generation past the
        // still-in-flight first batch.
        store.request(items: [TranslationRequestItem(id: "b", text: "さようなら")], target: .zhHans)
        XCTAssertGreaterThan(store.currentGeneration, firstGeneration)
        XCTAssertEqual(Set(store.pendingRequests.map(\.id)), ["a", "b"])

        // The stale first batch completes and stores its result tagged with
        // the generation it started with.
        store.store(results: [TranslationResultItem(id: "a", text: "你好")], target: .zhHans, generation: firstGeneration)

        // "a" is translated and removed from the queue, but "b" — queued by
        // the newer, still-current request — must not be wiped.
        XCTAssertEqual(store.pendingRequests.map(\.id), ["b"])
        XCTAssertEqual(store.cached("こんにちは", target: .zhHans), "你好")
    }

    func testOlderGenerationFailDoesNotClobberNewerPhase() {
        let store = makeStore()
        store.request(items: [TranslationRequestItem(id: "a", text: "こんにちは")], target: .zhHans)
        let firstGeneration = store.currentGeneration

        store.request(items: [TranslationRequestItem(id: "b", text: "さようなら")], target: .zhHans)
        XCTAssertEqual(store.phase, .translating(count: 2))

        // The stale first batch fails; it must not overwrite the newer
        // request's `.translating` phase or clear its pending items.
        store.fail("network error", generation: firstGeneration)

        XCTAssertEqual(store.phase, .translating(count: 2))
        XCTAssertEqual(Set(store.pendingRequests.map(\.id)), ["a", "b"])
    }

    func testRequestWithAllItemsCachedLeavesPhaseIdle() {
        let store = makeStore()
        store.request(items: [TranslationRequestItem(id: "a", text: "こんにちは")], target: .zhHans)
        store.store(results: [TranslationResultItem(id: "a", text: "你好")], target: .zhHans)

        store.request(items: [TranslationRequestItem(id: "a", text: "こんにちは")], target: .zhHans)

        XCTAssertTrue(store.pendingRequests.isEmpty)
        XCTAssertEqual(store.phase, .idle)
    }

    // MARK: - isShowingTranslation OR logic

    func testIsShowingTranslationIsPageOrCardToggle() {
        let store = makeStore()
        XCTAssertFalse(store.isShowingTranslation(eventID: "event-1", cardKey: "event-1|ticketRound|round-1"))

        store.toggleCard(cardKey: "event-1|ticketRound|round-1")
        XCTAssertTrue(store.isShowingTranslation(eventID: "event-1", cardKey: "event-1|ticketRound|round-1"))
        XCTAssertFalse(store.isShowingTranslation(eventID: "event-1", cardKey: "event-1|ticketRound|round-2"))

        store.toggleCard(cardKey: "event-1|ticketRound|round-1")
        XCTAssertFalse(store.isShowingTranslation(eventID: "event-1", cardKey: "event-1|ticketRound|round-1"))

        store.togglePage(eventID: "event-1")
        XCTAssertTrue(store.isShowingTranslation(eventID: "event-1", cardKey: "event-1|ticketRound|round-1"))
        XCTAssertTrue(store.isShowingTranslation(eventID: "event-1", cardKey: nil))
    }

    // MARK: - Scoped translation failures (card vs. page, per-event)

    func testCardFailureIsRecordedOnlyUnderItsOwnScope() {
        let store = makeStore()
        let cardScope = TranslationScope.card(eventID: "event-1", cardKey: "event-1|ticketRound|round-1")
        store.request(items: [TranslationRequestItem(id: "a", text: "こんにちは")], target: .zhHans, scope: cardScope)
        store.fail("network error")

        XCTAssertEqual(store.failure(for: cardScope)?.message, "network error")
        XCTAssertNil(store.failure(for: .page(eventID: "event-1")))
        XCTAssertNil(store.failure(for: .page(eventID: "event-2")))
        XCTAssertNil(store.failure(for: .card(eventID: "event-2", cardKey: "event-2|ticketRound|round-1")))
    }

    func testRetryReQueuesOriginalItemsAndDoesNotToggleTranslation() {
        let store = makeStore()
        let cardScope = TranslationScope.card(eventID: "event-1", cardKey: "event-1|ticketRound|round-1")
        let items = [TranslationRequestItem(id: "a", text: "こんにちは"), TranslationRequestItem(id: "b", text: "さようなら")]
        store.request(items: items, target: .zhHans, scope: cardScope)
        store.fail("network error")

        store.retry(cardScope)

        XCTAssertEqual(Set(store.pendingRequests.map(\.id)), ["a", "b"])
        XCTAssertNil(store.failure(for: cardScope))
        XCTAssertFalse(store.translatedEventIDs.contains("event-1"))
    }

    func testMergedBatchFailureRecordsBothScopesWithTheirOwnItems() {
        let store = makeStore()
        let pageScope = TranslationScope.page(eventID: "event-1")
        let cardScope = TranslationScope.card(eventID: "event-1", cardKey: "event-1|ticketRound|round-1")
        store.request(items: [TranslationRequestItem(id: "a", text: "こんにちは")], target: .zhHans, scope: pageScope)
        store.request(items: [TranslationRequestItem(id: "b", text: "さようなら")], target: .zhHans, scope: cardScope)
        store.fail("network error")

        XCTAssertEqual(store.failure(for: pageScope)?.items.map(\.id), ["a"])
        XCTAssertEqual(store.failure(for: cardScope)?.items.map(\.id), ["b"])
    }

    func testRequestWithScopeClearsThatScopesPriorFailure() {
        let store = makeStore()
        let cardScope = TranslationScope.card(eventID: "event-1", cardKey: "event-1|ticketRound|round-1")
        store.request(items: [TranslationRequestItem(id: "a", text: "こんにちは")], target: .zhHans, scope: cardScope)
        store.fail("network error")
        XCTAssertNotNil(store.failure(for: cardScope))

        store.request(items: [TranslationRequestItem(id: "a", text: "こんにちは")], target: .zhHans, scope: cardScope)
        XCTAssertNil(store.failure(for: cardScope))
    }

    func testStoreCompletingTheBatchEmptiesInFlightScopes() {
        let store = makeStore()
        let cardScope = TranslationScope.card(eventID: "event-1", cardKey: "event-1|ticketRound|round-1")
        store.request(items: [TranslationRequestItem(id: "a", text: "こんにちは")], target: .zhHans, scope: cardScope)
        XCTAssertTrue(store.isTranslating(cardScope))

        store.store(results: [TranslationResultItem(id: "a", text: "你好")], target: .zhHans)

        XCTAssertFalse(store.isTranslating(cardScope))
        XCTAssertFalse(store.isTranslating(eventID: "event-1"))
    }

    // A cached-only request for a different scope must not stale-out an
    // in-flight batch's generation (fix 1): its eventual failure must still
    // be attributed to its own scope, and that scope must no longer be
    // reported as in flight.
    func testCachedOnlyRequestDoesNotStaleAnInFlightBatch() {
        let store = makeStore()
        // Pre-cache "さようなら" so a later request for it is fully cached.
        store.request(items: [TranslationRequestItem(id: "seed", text: "さようなら")], target: .zhHans)
        store.store(results: [TranslationResultItem(id: "seed", text: "再见")], target: .zhHans)

        let pageScope = TranslationScope.page(eventID: "event-1")
        store.request(items: [TranslationRequestItem(id: "a", text: "こんにちは")], target: .zhHans, scope: pageScope)
        let pageGeneration = store.currentGeneration

        let cardScope = TranslationScope.card(eventID: "event-1", cardKey: "event-1|ticketRound|round-1")
        store.request(items: [TranslationRequestItem(id: "b", text: "さようなら")], target: .zhHans, scope: cardScope)

        store.fail("network error", generation: pageGeneration)

        XCTAssertEqual(store.failure(for: pageScope)?.message, "network error")
        XCTAssertFalse(store.isTranslating(pageScope))
    }

    func testCancelEmptiesInFlightScopesWithNoFailure() {
        let store = makeStore()
        let cardScope = TranslationScope.card(eventID: "event-1", cardKey: "event-1|ticketRound|round-1")
        store.request(items: [TranslationRequestItem(id: "a", text: "こんにちは")], target: .zhHans, scope: cardScope)

        store.cancel()

        XCTAssertFalse(store.isTranslating(cardScope))
        XCTAssertNil(store.failure(for: cardScope))
    }

    // MARK: - TranslationTargetLanguage.followApp

    func testFollowAppResolvesToOneOfTheFourConcreteLanguages() {
        let allowed: Set<Locale.Language> = [
            Locale.Language(identifier: "zh-Hans"),
            Locale.Language(identifier: "zh-Hant"),
            Locale.Language(identifier: "en"),
            Locale.Language(identifier: "ja"),
        ]
        let resolved = TranslationTargetLanguage.followApp.localeLanguage
        XCTAssertNotNil(resolved)
        XCTAssertTrue(allowed.contains { $0.languageCode?.identifier == resolved?.languageCode?.identifier })
    }

    func testResolveFollowAppMapsPreferredLanguages() {
        XCTAssertEqual(TranslationTargetLanguage.resolveFollowApp(preferredLanguages: ["ja-JP"], kitPreferredLocalizations: ["ja"]), .ja)
        XCTAssertEqual(TranslationTargetLanguage.resolveFollowApp(preferredLanguages: ["en-US"], kitPreferredLocalizations: ["en"]), .en)
        XCTAssertEqual(TranslationTargetLanguage.resolveFollowApp(preferredLanguages: ["zh-Hant-TW"], kitPreferredLocalizations: ["zh-Hant"]), .zhHant)
        XCTAssertEqual(TranslationTargetLanguage.resolveFollowApp(preferredLanguages: ["zh-Hans"], kitPreferredLocalizations: ["zh-Hans"]), .zhHans)
        XCTAssertEqual(TranslationTargetLanguage.resolveFollowApp(preferredLanguages: ["fr-FR"], kitPreferredLocalizations: ["fr"]), .zhHans)
    }

    // MARK: - Fixture

    private static func makeBundle(officialTitle: String, performers: [String], secondPerformancePerformers: [String] = []) -> LiveEventBundle {
        let event = LiveEvent(
            id: "event-1",
            franchise: .lovelive,
            officialTitle: officialTitle,
            groups: [],
            eventType: .live,
            status: .scheduled,
            primarySourceURL: "https://example.com/event",
            timeZone: "Asia/Tokyo"
        )
        var performances = [
            Performance(
                id: "perf-1",
                eventID: "event-1",
                stopID: nil,
                dayLabel: "Day 1",
                subtitle: nil,
                localDate: "2026-10-01",
                doorsAt: nil,
                startAt: nil,
                venueName: "会場",
                venueCity: "東京",
                performers: performers,
                order: 0
            ),
        ]
        if !secondPerformancePerformers.isEmpty {
            performances.append(
                Performance(
                    id: "perf-2",
                    eventID: "event-1",
                    stopID: nil,
                    dayLabel: "Day 2",
                    subtitle: nil,
                    localDate: "2026-10-02",
                    doorsAt: nil,
                    startAt: nil,
                    venueName: "会場",
                    venueCity: "東京",
                    performers: secondPerformancePerformers,
                    order: 1
                )
            )
        }
        return LiveEventBundle(
            schemaVersion: 1,
            publishedAt: Date(timeIntervalSince1970: 0),
            event: event,
            stops: [],
            performances: performances,
            ticketTiers: [],
            ticketRounds: [],
            ticketOffers: [],
            goodsCampaigns: [],
            mediaAssets: [],
            notices: [],
            evidence: []
        )
    }
}

@MainActor
final class LiveDetailSelectionTests: XCTestCase {
    private func makeUserDataStore() -> UserDataStore {
        UserDataStore(container: UserDataStore.makeContainer(inMemory: true))
    }

    private func makeEvent() -> LiveEvent {
        LiveEvent(
            id: "event-1",
            franchise: .lovelive,
            officialTitle: "Test LIVE",
            groups: [],
            eventType: .live,
            status: .scheduled,
            primarySourceURL: "https://example.com/event",
            timeZone: "Asia/Tokyo"
        )
    }

    private func makePerformance(id: String, order: Int) -> Performance {
        Performance(
            id: id,
            eventID: "event-1",
            stopID: nil,
            dayLabel: "Day \(order + 1)",
            subtitle: nil,
            localDate: "2026-10-0\(order + 1)",
            doorsAt: nil,
            startAt: nil,
            venueName: "会場",
            venueCity: "東京",
            performers: [],
            order: order
        )
    }

    private func makeOfficialBundle() -> LiveEventBundle {
        LiveEventBundle(
            schemaVersion: 1,
            publishedAt: .distantPast,
            event: makeEvent(),
            stops: [],
            performances: [makePerformance(id: "perf-1", order: 0), makePerformance(id: "perf-2", order: 1)],
            ticketTiers: [], ticketRounds: [], ticketOffers: [], goodsCampaigns: [], mediaAssets: [],
            notices: [], evidence: []
        )
    }

    private func fixtureSummary(eventID: String, organizedBundle: LiveEventBundle?, source: LiveEventBundle) -> AssistantEventSummary {
        AssistantEventSummary(
            eventID: eventID,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            model: "gpt-5-mini",
            sourceFingerprint: AssistantSummarizer.fingerprint(of: source),
            overview: AssistantRichText("总览"),
            keyPoints: [],
            performances: [],
            ticketLinks: [],
            goodsLinks: [],
            warnings: [],
            organizedBundle: organizedBundle
        )
    }

    // (a) A performance id present in both sources survives official→AI→official.
    func testPerformanceIDPresentInBothSourcesSurvivesRoundTrip() {
        let officialBundle = makeOfficialBundle()
        let store = LiveDetailStore(bundle: officialBundle, initialPerformanceID: "perf-2", userDataStore: makeUserDataStore())
        XCTAssertEqual(store.selectedPerformanceID, "perf-2")

        var aiBundle = officialBundle
        aiBundle = LiveEventBundle(
            schemaVersion: 1, publishedAt: .distantPast, event: officialBundle.event, stops: [],
            performances: [makePerformance(id: "perf-1", order: 0), makePerformance(id: "perf-2", order: 1)],
            ticketTiers: [], ticketRounds: [], ticketOffers: [], goodsCampaigns: [], mediaAssets: [], notices: [], evidence: []
        )
        store.assistantSummary = fixtureSummary(eventID: "event-1", organizedBundle: aiBundle, source: officialBundle)
        store.usesAssistantData = true
        XCTAssertEqual(store.selectedPerformanceID, "perf-2")
        XCTAssertNil(store.replacedPerformanceID)

        store.usesAssistantData = false
        XCTAssertEqual(store.selectedPerformanceID, "perf-2")
        XCTAssertNil(store.replacedPerformanceID)
    }

    // (b) AI bundle lacking the id → fallback chosen and replacedPerformanceID set;
    // switching back to official restores the original and clears it.
    func testAIBundleLackingPerformanceFallsBackAndRestoresOnSwitchBack() {
        let officialBundle = makeOfficialBundle()
        let store = LiveDetailStore(bundle: officialBundle, initialPerformanceID: "perf-2", userDataStore: makeUserDataStore())

        let aiBundle = LiveEventBundle(
            schemaVersion: 1, publishedAt: .distantPast, event: officialBundle.event, stops: [],
            performances: [makePerformance(id: "perf-1", order: 0)],
            ticketTiers: [], ticketRounds: [], ticketOffers: [], goodsCampaigns: [], mediaAssets: [], notices: [], evidence: []
        )
        store.assistantSummary = fixtureSummary(eventID: "event-1", organizedBundle: aiBundle, source: officialBundle)
        store.usesAssistantData = true

        XCTAssertEqual(store.selectedPerformanceID, "perf-1")
        XCTAssertEqual(store.replacedPerformanceID, "perf-2")

        store.usesAssistantData = false
        XCTAssertEqual(store.selectedPerformanceID, "perf-2")
        XCTAssertNil(store.replacedPerformanceID)
    }

    // Fix 5: a temporary fallback selection (the AI bundle lacks the
    // previously selected performance) must not overwrite the persisted
    // selection — only a real user pick, or a source that actually has the
    // original performance, should persist.
    func testFallbackSelectionIsNotPersisted() {
        let officialBundle = makeOfficialBundle()
        let userDataStore = makeUserDataStore()
        let store = LiveDetailStore(bundle: officialBundle, initialPerformanceID: "perf-2", userDataStore: userDataStore)
        // A real user pick persists immediately.
        store.selectedPerformanceID = "perf-2"
        XCTAssertEqual(userDataStore.selectedPerformanceID(eventID: "event-1"), "perf-2")

        let aiBundle = LiveEventBundle(
            schemaVersion: 1, publishedAt: .distantPast, event: officialBundle.event, stops: [],
            performances: [makePerformance(id: "perf-1", order: 0)],
            ticketTiers: [], ticketRounds: [], ticketOffers: [], goodsCampaigns: [], mediaAssets: [], notices: [], evidence: []
        )
        store.assistantSummary = fixtureSummary(eventID: "event-1", organizedBundle: aiBundle, source: officialBundle)
        store.usesAssistantData = true

        XCTAssertEqual(store.selectedPerformanceID, "perf-1")
        XCTAssertEqual(store.replacedPerformanceID, "perf-2")
        // The fallback to perf-1 must never overwrite the persisted perf-2.
        XCTAssertEqual(userDataStore.selectedPerformanceID(eventID: "event-1"), "perf-2")

        store.usesAssistantData = false
        XCTAssertEqual(store.selectedPerformanceID, "perf-2")
        XCTAssertNil(store.replacedPerformanceID)
        XCTAssertEqual(userDataStore.selectedPerformanceID(eventID: "event-1"), "perf-2")
    }

    // (c) A user selection clears the replaced marker.
    func testUserSelectionClearsReplacedPerformanceID() {
        let officialBundle = makeOfficialBundle()
        let store = LiveDetailStore(bundle: officialBundle, initialPerformanceID: "perf-2", userDataStore: makeUserDataStore())

        let aiBundle = LiveEventBundle(
            schemaVersion: 1, publishedAt: .distantPast, event: officialBundle.event, stops: [],
            performances: [makePerformance(id: "perf-1", order: 0)],
            ticketTiers: [], ticketRounds: [], ticketOffers: [], goodsCampaigns: [], mediaAssets: [], notices: [], evidence: []
        )
        store.assistantSummary = fixtureSummary(eventID: "event-1", organizedBundle: aiBundle, source: officialBundle)
        store.usesAssistantData = true
        XCTAssertNotNil(store.replacedPerformanceID)

        store.selectedPerformanceID = "perf-1"
        XCTAssertNil(store.replacedPerformanceID)
    }

    // P1-4: an official critical notice is never hidden by switching to an
    // AI bundle that doesn't carry it.
    func testCriticalNoticesAlwaysIncludesOfficialCriticalNoticeUnderAIMode() {
        let notice = Notice(
            id: "notice-1", eventID: "event-1", kind: .cancellation,
            title: "公演中止のお知らせ", body: "本公演は中止となりました。",
            publishedAt: nil, sourceURL: "https://example.com/notice", scope: .wholeEvent
        )
        var officialBundle = makeOfficialBundle()
        officialBundle = LiveEventBundle(
            schemaVersion: 1, publishedAt: .distantPast, event: officialBundle.event, stops: [],
            performances: officialBundle.performances,
            ticketTiers: [], ticketRounds: [], ticketOffers: [], goodsCampaigns: [], mediaAssets: [],
            notices: [notice], evidence: []
        )
        let store = LiveDetailStore(bundle: officialBundle, initialPerformanceID: "perf-1", userDataStore: makeUserDataStore())

        let aiBundle = LiveEventBundle(
            schemaVersion: 1, publishedAt: .distantPast, event: officialBundle.event, stops: [],
            performances: officialBundle.performances,
            ticketTiers: [], ticketRounds: [], ticketOffers: [], goodsCampaigns: [], mediaAssets: [],
            notices: [], evidence: []
        )
        store.assistantSummary = fixtureSummary(eventID: "event-1", organizedBundle: aiBundle, source: officialBundle)
        store.usesAssistantData = true

        XCTAssertTrue(store.hasAssistantData)
        XCTAssertTrue(store.bundle.notices.isEmpty)
        XCTAssertEqual(store.criticalNotices().map(\.notice.id), ["notice-1"])
    }
}
