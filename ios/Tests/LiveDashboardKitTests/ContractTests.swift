import XCTest
@testable import LiveDashboardKit

final class ContractTests: XCTestCase {
    private func serverFixture() throws -> LiveEventBundle {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/contracts/bundle-v1.json")
        return try LiveEventBundle.decoder.decode(LiveEventBundle.self, from: Data(contentsOf: fixture))
    }

    func testDecodesServerOwnedContractFixture() throws {
        let bundle = try serverFixture()
        XCTAssertEqual(bundle.schemaVersion, 1)
        XCTAssertFalse(bundle.performances.isEmpty)
        XCTAssertTrue(bundle.ticketRounds.allSatisfy { round in
            if case .performances(let ids) = round.scope { return !ids.isEmpty }
            return true
        })
    }

    func testAdditiveV1BundleDecodesMoneyMediaAndExplicitScope() throws {
        let json = """
        {"schemaVersion":1,"revision":4,"publishedAt":"2026-09-22T12:00:00Z","event":{"id":"e1","franchise":"bangdream","officialTitle":"Contract Fixture","groups":[],"eventType":"live","status":"scheduled","primarySourceURL":"https://example.com/e","timeZone":"Asia/Tokyo"},"editions":[],"stops":[],"performances":[{"id":"p1","eventID":"e1","stopID":null,"dayLabel":"Day 1","subtitle":null,"localDate":"2027-01-01","doorsAt":null,"startAt":"2027-01-01T18:00:00+09:00","venueName":"V","venueCity":"Tokyo","performers":[],"order":0}],"ticketTiers":[{"id":"t1","eventID":"e1","name":"一般","priceJPY":15000,"amount":{"minorUnits":15000,"currency":"JPY"},"priceKind":"full","includes":null,"feeNote":null,"taxNote":null}],"ticketRounds":[{"id":"r1","eventID":"e1","scope":{"kind":"performances","performanceIDs":["p1"]},"officialName":"先行","kind":"lottery","applyStartAt":null,"applyEndAt":null,"resultAt":null,"paymentDeadlineAt":null,"eligibility":null,"announcementURL":null,"applyURL":null,"overseasURL":null,"officialStatus":null,"status":"confirmed"}],"ticketOffers":[],"streamOffers":[],"goodsCampaigns":[],"products":[],"goodsSessions":[],"mediaAssets":[{"id":"m1","eventID":"e1","scope":{"kind":"performances","performanceIDs":["p1"]},"kind":"eventSeatingMap","originalURL":"https://example.com/a.jpg","thumbnailURL":null,"sourceURL":"https://example.com/source","version":1,"caption":null,"displayPolicy":"link_only"}],"notices":[],"evidence":[],"sourceHealth":"healthy"}
        """
        let bundle = try LiveEventBundle.decoder.decode(LiveEventBundle.self, from: Data(json.utf8))
        XCTAssertEqual(bundle.revision, 4)
        XCTAssertEqual(bundle.ticketTiers.first?.amount?.minorUnits, 15000)
        XCTAssertEqual(bundle.mediaAssets.first?.displayPolicy, .linkOnly)
        let resolved = PerformanceScopeResolver.resolve(records: bundle.ticketRounds, selectedPerformanceID: "p1", stopID: { _ in nil })
        XCTAssertEqual(resolved.applicable.map(\.id), ["r1"])
    }

    @MainActor func testSwiftDataUserStateIsIndependent() {
        let store = UserDataStore(container: UserDataStore.makeContainer(inMemory: true))
        store.setFollowed(true, eventID: "e1")
        store.setSelectedPerformance("p1", eventID: "e1")
        store.setRoundRecord(UserRoundRecord(roundID: "r1", applied: true, paid: false), eventID: "e1")
        XCTAssertTrue(store.state(for: "e1").isFollowed)
        XCTAssertEqual(store.selectedPerformanceID(eventID: "e1"), "p1")
        XCTAssertTrue(store.state(for: "e1").roundRecords.first?.applied == true)
    }

    @MainActor func testSetRoundRecordIsReadableWithoutPriorFollow() {
        let store = UserDataStore(container: UserDataStore.makeContainer(inMemory: true))
        store.setRoundRecord(UserRoundRecord(roundID: "r1", applied: true, paid: false), eventID: "e-no-follow")
        XCTAssertTrue(store.state(for: "e-no-follow").roundRecords.first?.applied == true)
        XCTAssertFalse(store.state(for: "e-no-follow").isFollowed)
    }

    @MainActor func testHiddenCardIsRestoredByRemoveConfigurationsAndUnhideCards() {
        let store = UserDataStore(container: UserDataStore.makeContainer(inMemory: true))
        var config = CardConfiguration(cardType: .goodsCampaign, entityID: "entity-1", isPinned: true, order: 3)
        config.isHidden = true
        store.setConfiguration(config)
        XCTAssertTrue(store.configuration(cardType: .goodsCampaign, entityID: "entity-1")?.isHidden == true)

        store.removeConfigurations(cardType: .goodsCampaign)
        XCTAssertNil(store.configuration(cardType: .goodsCampaign, entityID: "entity-1"))

        var eventConfig = CardConfiguration(cardType: .goodsCampaign, entityID: "entity-2", eventID: "event-1", isPinned: true, order: 5)
        eventConfig.isHidden = true
        store.setConfiguration(eventConfig)
        store.unhideCards(cardTypes: [.goodsCampaign], eventID: "event-1")
        let restored = store.configuration(cardType: .goodsCampaign, entityID: "entity-2", eventID: "event-1")
        XCTAssertEqual(restored?.isHidden, false)
        XCTAssertEqual(restored?.isPinned, true)
    }

    @MainActor func testGlobalCardPreferencesApplyToEntityAndAllowNoVisibleFields() {
        let store = UserDataStore(container: UserDataStore.makeContainer(inMemory: true))
        var global = CardConfiguration(
            cardType: .goodsCampaign,
            entityID: CardConfiguration.globalEntityID,
            isPinned: true,
            order: 9,
            density: .compact,
            visibleFields: [CardField.configuredMarker]
        )
        store.setConfiguration(global)

        let effective = store.effectiveConfiguration(cardType: .goodsCampaign, entityID: "campaign-1", eventID: "event-1")
        XCTAssertTrue(effective.isPinned)
        XCTAssertEqual(effective.order, 9)
        XCTAssertEqual(effective.density, .compact)
        XCTAssertFalse(effective.shows(.time))
        XCTAssertFalse(effective.shows(.source))

        global.visibleFields = []
        XCTAssertTrue(global.shows(.time), "Legacy/default empty sets continue to mean all fields")
    }

    @MainActor func testGlobalCardPreferenceDoesNotDropEveryCard() {
        // Regression: a card-type-wide preference used to be returned verbatim for every
        // entity, so callers mapping back by entityID resolved "*global*" and lost all cards.
        func campaign(_ id: String, _ channel: GoodsChannel) -> GoodsCampaign {
            GoodsCampaign(
                id: id, eventID: "event-1", officialName: id, channel: channel,
                fulfillment: .shipping, phase: .pre,
                scope: .performances(performanceIDs: ["p1"]),
                salesStartAt: nil, salesEndAt: nil, pickupWindow: nil, shippingNote: nil,
                location: nil, requiresTicket: nil, purchaseLimit: nil, paymentMethods: nil,
                url: nil, mediaAssetIDs: [], status: .confirmed
            )
        }
        let campaigns = [campaign("online-1", .online), campaign("online-2", .online), campaign("venue-1", .venue)]

        let store = UserDataStore(container: UserDataStore.makeContainer(inMemory: true))
        store.setConfiguration(CardConfiguration(
            cardType: .goodsCampaign,
            entityID: CardConfiguration.globalEntityID,
            order: 9
        ))
        let configurations = store.effectiveConfigurations(eventID: "event-1")

        let sections = ImportantInformationPolicy.goodsTabSections(applicableCampaigns: campaigns, configurations: configurations)
        XCTAssertEqual(sections.online.map(\.id), ["online-1", "online-2"], "A global preference must not drop cards, and must keep default order")
        XCTAssertEqual(sections.venue.map(\.id), ["venue-1"])

        // Hiding via the same global row still hides everything.
        store.setConfiguration(CardConfiguration(
            cardType: .goodsCampaign,
            entityID: CardConfiguration.globalEntityID,
            isHidden: true,
            order: 9
        ))
        let hidden = ImportantInformationPolicy.goodsTabSections(
            applicableCampaigns: campaigns,
            configurations: store.effectiveConfigurations(eventID: "event-1")
        )
        XCTAssertTrue(hidden.online.isEmpty && hidden.venue.isEmpty)
    }

    func testUnconfirmedScopeNeverLeaksIntoApplicable() {
        let round = TicketRound(id: "r", eventID: "e", officialName: "x", kind: .other, scope: .unconfirmed, applyStartAt: nil, applyEndAt: nil, resultAt: nil, paymentDeadlineAt: nil, eligibility: nil, announcementURL: nil, applyURL: nil, overseasURL: nil, officialStatus: nil, status: .needsReview)
        let result = PerformanceScopeResolver.resolve(records: [round], selectedPerformanceID: "p", stopID: { _ in nil })
        XCTAssertTrue(result.applicable.isEmpty)
        XCTAssertEqual(result.unconfirmed.map(\.id), ["r"])
    }

    func testBroadWireScopesWithoutMaterializedPerformanceIDsBecomeUnconfirmed() throws {
        let decoder = JSONDecoder()
        for raw in [#"{"kind":"wholeEvent"}"#, #"{"kind":"all_event"}"#, #"{"kind":"stop","stopID":"s1"}"#, #"{"kind":"performances","performanceIDs":[]}"#] {
            let scope = try decoder.decode(Scope.self, from: Data(raw.utf8))
            XCTAssertEqual(scope, .unconfirmed)
        }
        let materialized = try decoder.decode(Scope.self, from: Data(#"{"kind":"wholeEvent","performanceIDs":["p1"]}"#.utf8))
        XCTAssertEqual(materialized, .performances(performanceIDs: ["p1"]))
    }

    func testMoneyUsesCurrencyMinorUnits() {
        XCTAssertTrue(MoneyAmount(minorUnits: 15000, currency: "JPY").formatted.contains("15,000"))
        XCTAssertTrue(MoneyAmount(minorUnits: 12345, currency: "CAD").formatted.contains("123.45"))
        XCTAssertTrue(MoneyAmount(minorUnits: 12345, currency: "KWD").formatted.contains("12.345"))
    }

    @MainActor func testDashboardExcludesUnconfirmedScopeAndUnrelatedTierPrice() async throws {
        let base = try serverFixture()
        let round = TicketRound(id: "unconfirmed", eventID: base.event.id, officialName: "upgrade", kind: .upgrade, scope: .unconfirmed, applyStartAt: Date().addingTimeInterval(-60), applyEndAt: Date().addingTimeInterval(3600), resultAt: nil, paymentDeadlineAt: nil, eligibility: nil, announcementURL: nil, applyURL: nil, overseasURL: nil, officialStatus: nil, status: .confirmed)
        let tier = TicketTier(id: "unrelated", eventID: base.event.id, name: "Unrelated", priceJPY: 100, priceKind: .full, includes: nil, feeNote: nil, taxNote: nil)
        let bundle = LiveEventBundle(schemaVersion: 1, publishedAt: base.publishedAt, event: base.event, stops: base.stops, performances: base.performances, ticketTiers: [tier], ticketRounds: [round], ticketOffers: [], goodsCampaigns: [], mediaAssets: [], notices: [], evidence: [])
        let store = DashboardStore(repository: StaticRepository(bundle: bundle), userDataStore: UserDataStore(container: UserDataStore.makeContainer(inMemory: true)))
        await store.load()
        let summary = try XCTUnwrap(store.visibleSummaries.first)
        XCTAssertNil(summary.currentRoundLabel)
        XCTAssertNil(summary.nextDeadline)
        XCTAssertNil(summary.minimumPriceJPY)
    }

    func testBootstrapThenDeltaDeletionIsAtomicAndPrivateStateSurvivesCacheClear() async throws {
        let bundle = try serverFixture()
        let encoder = LiveEventBundle.encoder
        URLProtocolStub.handler = { request in
            let body: Data
            if request.url?.path.hasSuffix("/bootstrap") == true {
                body = try encoder.encode(BootstrapResponse(schemaVersion: 1, cursor: "c1", events: [bundle]))
            } else if URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "cursor" })?.value == "c1" {
                body = try encoder.encode(CatalogChangesResponse(cursor: "c2", changes: [], hasMore: true))
            } else {
                body = try encoder.encode(CatalogChangesResponse(cursor: "c3", changes: [CatalogChange(sequence: "9223372036854775808", eventID: bundle.event.id, revision: bundle.revision, kind: "delete", bundle: nil, replacementID: nil)]))
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, body)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = APILiveRepository(baseURL: URL(string: "https://api.example.test/")!, session: session, cacheDirectory: cache)
        let store = await MainActor.run { UserDataStore(container: UserDataStore.makeContainer(inMemory: true)) }
        await MainActor.run { store.setFollowed(true, eventID: bundle.event.id) }

        let initial = try await repository.allBundles()
        XCTAssertEqual(initial.count, 1)
        let refreshed = try await repository.refresh()
        XCTAssertTrue(refreshed.isEmpty)
        try await repository.clearPublicCache()
        let stillFollowed = await MainActor.run { store.state(for: bundle.event.id).isFollowed }
        XCTAssertTrue(stillFollowed)
    }
}

private actor StaticRepository: LiveRepository {
    let bundleValue: LiveEventBundle
    init(bundle: LiveEventBundle) { bundleValue = bundle }
    func allBundles() async throws -> [LiveEventBundle] { [bundleValue] }
    func bundle(eventID: String) async throws -> LiveEventBundle? { bundleValue.event.id == eventID ? bundleValue : nil }
    func refresh() async throws -> [LiveEventBundle] { [bundleValue] }
    func changes(eventID: String) async throws -> [EventChangeHistory] { [] }
    func clearPublicCache() async throws {}
}

private final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (response, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
