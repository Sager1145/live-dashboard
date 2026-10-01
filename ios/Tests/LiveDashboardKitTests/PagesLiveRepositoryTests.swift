import XCTest
import LiveIngestionCore
@testable import LiveDashboardKit

@MainActor
final class PagesLiveRepositoryTests: XCTestCase {
    private func fixture() throws -> LiveEventBundle {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try LiveEventBundle.decoder.decode(LiveEventBundle.self, from: Data(contentsOf: root.appendingPathComponent("fixtures/contracts/bundle-v1.json")))
    }

    private func snapshot(version: Int = 1, events: [LiveEventBundle]? = nil) throws -> Data {
        try LiveEventBundle.encoder.encode(PagesCatalogSnapshot(schemaVersion: version, generatedAt: Date(timeIntervalSince1970: 1_000),
            lastSuccessfulRefreshAt: Date(timeIntervalSince1970: 900), sourceFailures: [], events: events ?? [fixture()]))
    }

    private func setup(_ data: Data, delay: TimeInterval = 0) -> (URLSession, URL, PagesTestClock) {
        PagesTestURLProtocol.configure(data: data, delay: delay)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PagesTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (session, directory, PagesTestClock())
    }

    func testFixedEndpointAndPersistedOfflineCache() async throws {
        let (session, directory, clock) = setup(try snapshot())
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let repository = PagesLiveRepository(session: session, directory: directory, now: { clock.date })
        let bundles = try await repository.refresh()
        XCTAssertEqual(bundles.count, 1)
        XCTAssertEqual(PagesTestURLProtocol.lastURL, PagesLiveRepository.catalogURL)
        PagesTestURLProtocol.configure(data: Data(), status: 503)
        let reopened = PagesLiveRepository(session: session, directory: directory, now: { clock.date })
        let saved = try await reopened.allBundles()
        XCTAssertEqual(saved.map(\.event.id), bundles.map(\.event.id))
        XCTAssertEqual(PagesTestURLProtocol.calls, 0)
        let last = await reopened.lastRefreshDate()
        XCTAssertEqual(last, Date(timeIntervalSince1970: 900))
    }

    func testHourlyGateManualBypassAndFailureRetry() async throws {
        let good = try snapshot()
        let (session, directory, clock) = setup(good)
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let repository = PagesLiveRepository(session: session, directory: directory, now: { clock.date })
        _ = try await repository.refreshIfNeeded()
        clock.advance(3_599)
        _ = try await repository.refreshIfNeeded()
        XCTAssertEqual(PagesTestURLProtocol.calls, 1)
        _ = try await repository.refresh()
        XCTAssertEqual(PagesTestURLProtocol.calls, 2)
        clock.advance(3_600)
        PagesTestURLProtocol.configure(data: Data(), status: 503)
        do { _ = try await repository.refreshIfNeeded(); XCTFail("Expected HTTP failure") } catch {}
        PagesTestURLProtocol.configure(data: good)
        _ = try await repository.refreshIfNeeded()
        XCTAssertEqual(PagesTestURLProtocol.calls, 1, "Failure must not defer retry until the next hour")
    }

    func testBadResponsesPreserveLastGoodCacheAndHideEndpoint() async throws {
        let bundle = try fixture()
        let (session, directory, clock) = setup(try snapshot())
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let repository = PagesLiveRepository(session: session, directory: directory, now: { clock.date })
        _ = try await repository.refresh()
        for invalid in [try snapshot(version: 2), Data("{malformed".utf8), try snapshot(events: [bundle, bundle]), try snapshot(events: [])] {
            PagesTestURLProtocol.configure(data: invalid)
            do {
                _ = try await repository.refresh()
                XCTFail("Expected invalid snapshot rejection")
            } catch {
                XCTAssertFalse(error.localizedDescription.contains("github.io"))
                XCTAssertFalse(error.localizedDescription.contains("catalog.json"))
            }
            let saved = try await repository.allBundles()
            XCTAssertEqual(saved.map(\.event.id), [bundle.event.id])
            let reopened = PagesLiveRepository(session: session, directory: directory)
            let disk = try await reopened.allBundles()
            XCTAssertEqual(disk.map(\.event.id), [bundle.event.id])
        }
    }

    func testOldPublicCacheMigratesOfflineAndClearDoesNotRestoreIt() async throws {
        let (session, directory, clock) = setup(Data(), delay: 0)
        let legacyDirectory = directory.appendingPathComponent("legacy")
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        struct Legacy: Encodable { let events: [LiveEventBundle]; let lastRefresh: Date }
        try LiveEventBundle.encoder.encode(Legacy(events: [fixture()], lastRefresh: clock.date))
            .write(to: legacyDirectory.appendingPathComponent("catalog.json"))
        let repository = PagesLiveRepository(session: session, directory: directory, legacyDirectory: legacyDirectory)
        let migrated = try await repository.allBundles()
        XCTAssertEqual(migrated.count, 1)
        XCTAssertEqual(PagesTestURLProtocol.calls, 0)
        try await repository.clearPublicCache()
        let reopened = PagesLiveRepository(session: session, directory: directory, legacyDirectory: legacyDirectory)
        do { _ = try await reopened.allBundles(); XCTFail("Cleared cache should require a new download") } catch {}
        XCTAssertEqual(PagesTestURLProtocol.calls, 1)
    }

    func testConcurrentRefreshesShareOneDownloadAndCardRefreshUsesCatalog() async throws {
        let (session, directory, clock) = setup(try snapshot(), delay: 0.1)
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let repository = PagesLiveRepository(session: session, directory: directory, now: { clock.date })
        let eventID = try fixture().event.id
        async let first = repository.refresh()
        async let second = repository.refresh(eventID: eventID, cardType: .timeAndVenue, entityID: "unused")
        let (events, event) = try await (first, second)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(event?.event.id, eventID)
        XCTAssertEqual(PagesTestURLProtocol.calls, 1)
    }

    func testHistoryIncludesExhibitionPeriodOverlappingSelectedRange() async throws {
        let existing = try fixture()
        let performance = Performance(id: "exhibition", eventID: existing.event.id, stopID: nil, dayLabel: "Exhibition",
            subtitle: nil, localDate: "2026-01-01", doorsAt: nil, startAt: nil, venueName: "Venue", venueCity: "",
            performers: [], order: 0, localEndDate: "2026-01-15", activityKind: .exhibition)
        let exhibition = LiveEventBundle(schemaVersion: 1, publishedAt: existing.publishedAt, event: existing.event,
            stops: [], performances: [performance], ticketTiers: [], ticketRounds: [], ticketOffers: [],
            goodsCampaigns: [], mediaAssets: [], notices: [], evidence: [])
        let (session, directory, _) = setup(try snapshot(events: [exhibition]))
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let repository = PagesLiveRepository(session: session, directory: directory)
        let overlap = try await repository.fetchHistory(start: "2026-01-10", end: "2026-01-12")
        XCTAssertEqual(overlap.map(\.event.id), [existing.event.id])
        let boundary = try await repository.fetchHistory(start: "2026-01-15", end: "2026-01-15")
        XCTAssertEqual(boundary.count, 1)
        let outside = try await repository.fetchHistory(start: "2026-01-16", end: "2026-01-18")
        XCTAssertTrue(outside.isEmpty)
    }

    func testHistoryFiltersPublishedSnapshotWithoutOtherNetworkRequests() async throws {
        let fixture = try fixture()
        let (session, directory, _) = setup(try snapshot())
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let repository = PagesLiveRepository(session: session, directory: directory)
        let day = try XCTUnwrap(fixture.performances.compactMap(\.localDate).first)
        let included = try await repository.fetchHistory(start: day, end: day)
        XCTAssertEqual(included.map(\.event.id), [fixture.event.id])
        let excluded = try await repository.fetchHistory(start: "1900-01-01", end: "1900-01-02")
        XCTAssertTrue(excluded.isEmpty)
        XCTAssertEqual(PagesTestURLProtocol.calls, 2)
        XCTAssertEqual(PagesTestURLProtocol.lastURL, PagesLiveRepository.catalogURL)
    }
}

private final class PagesTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 10_000)
    var date: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}

private final class PagesTestURLProtocol: URLProtocol, @unchecked Sendable {
    private struct State: Sendable {
        var data = Data()
        var status = 200
        var delay: TimeInterval = 0
        var calls = 0
        var lastURL: URL?
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var state = State()
    static var calls: Int { lock.withLock { state.calls } }
    static var lastURL: URL? { lock.withLock { state.lastURL } }
    static func configure(data: Data, status: Int = 200, delay: TimeInterval = 0) {
        lock.withLock { state = State(data: data, status: status, delay: delay) }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let result = Self.lock.withLock {
            Self.state.calls += 1
            Self.state.lastURL = request.url
            return Self.state
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + result.delay) { [self] in
            let response = HTTPURLResponse(url: request.url!, statusCode: result.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
