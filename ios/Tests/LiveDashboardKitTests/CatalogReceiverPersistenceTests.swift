import XCTest
@testable import LiveDashboardKit

final class CatalogReceiverPersistenceTests: XCTestCase {
    private let encoder = LiveEventBundle.encoder

    override func tearDown() {
        CatalogURLProtocolStub.handler = nil
        super.tearDown()
    }

    func testSchemaTwoDoesNotReplaceGoodCatalog() async throws {
        let cache = temporaryCache()
        let good = bundle(id: "e1", title: "Good", revision: 5)
        let bad = bundle(id: "bad", title: "Bad", revision: 1)
        let gate = Gate()
        CatalogURLProtocolStub.handler = { request in
            let url = try Self.url(request)
            if url.path.hasSuffix("/bootstrap") {
                let turn = gate.next()
                let response = turn == 1
                    ? BootstrapResponse(schemaVersion: 1, cursor: "10", events: [good])
                    : BootstrapResponse(schemaVersion: 2, cursor: "99", events: [bad])
                return try Self.http(url: url, status: 200, body: self.encoder.encode(response))
            }
            return Self.http(url: url, status: 410, body: Data())
        }
        let repository = makeRepository(cache: cache)
        let initial = try await repository.allBundles()
        XCTAssertEqual(initial.map(\.event.id), ["e1"])
        do {
            _ = try await repository.refresh()
            XCTFail("expected incompatible schema")
        } catch let error as LiveRepositoryError {
            guard case .incompatibleSchema(2) = error else { return XCTFail("\(error)") }
        }
        let stored = try await makeRepository(cache: cache).allBundles()
        XCTAssertEqual(stored.map(\.event.id), ["e1"])
        XCTAssertEqual(stored.map(\.event.officialTitle), ["Good"])
    }

    func testUnknownKindDoesNotAdvanceCursor() async throws {
        let cache = temporaryCache()
        let seen = Gate()
        CatalogURLProtocolStub.handler = { request in
            let url = try Self.url(request)
            if url.path.hasSuffix("/bootstrap") {
                return try Self.http(url: url, status: 200, body: self.encoder.encode(BootstrapResponse(schemaVersion: 1, cursor: "41", events: [self.bundle()])))
            }
            let cursor = Self.cursor(url)
            let turn = seen.next()
            if turn == 1 {
                let change = CatalogChange(sequence: "1", eventID: "e1", revision: 6, kind: "rename", bundle: nil, replacementID: nil)
                return try Self.http(url: url, status: 200, body: self.encoder.encode(CatalogChangesResponse(cursor: "99", changes: [change])))
            }
            seen.append(cursor ?? "")
            return try Self.http(url: url, status: 200, body: self.encoder.encode(CatalogChangesResponse(cursor: "41", changes: [])))
        }
        let repository = makeRepository(cache: cache)
        _ = try await repository.allBundles()
        do {
            _ = try await repository.refresh()
            XCTFail("expected unknown change kind")
        } catch let error as LiveRepositoryError {
            guard case .unknownChangeKind("rename") = error else { return XCTFail("\(error)") }
        }
        _ = try await makeRepository(cache: cache).refresh()
        XCTAssertEqual(seen.values, ["41"])
    }

    func testOlderRevisionIsIgnored() async throws {
        let cache = temporaryCache()
        let current = bundle(title: "Current", revision: 5)
        let stale = bundle(title: "Stale", revision: 2)
        CatalogURLProtocolStub.handler = { request in
            let url = try Self.url(request)
            if url.path.hasSuffix("/bootstrap") {
                return try Self.http(url: url, status: 200, body: self.encoder.encode(BootstrapResponse(schemaVersion: 1, cursor: "7", events: [current])))
            }
            if url.path.contains("/events/") {
                return try Self.http(url: url, status: 200, body: self.encoder.encode(stale))
            }
            let change = CatalogChange(sequence: "2", eventID: "e1", revision: stale.revision, kind: "upsert", bundle: stale, replacementID: nil)
            return try Self.http(url: url, status: 200, body: self.encoder.encode(CatalogChangesResponse(cursor: "8", changes: [change])))
        }
        let repository = makeRepository(cache: cache)
        _ = try await repository.allBundles()
        let refreshed = try await repository.refresh()
        XCTAssertEqual(refreshed.map(\.event.officialTitle), ["Current"])
        XCTAssertEqual(refreshed.map(\.revision), [5])
        let single = try await repository.refresh(eventID: "e1")
        XCTAssertEqual(single?.event.officialTitle, "Current")
        XCTAssertEqual(single?.revision, 5)
        let stored = try await makeRepository(cache: cache).allBundles()
        XCTAssertEqual(stored.map(\.event.officialTitle), ["Current"])
        XCTAssertEqual(stored.map(\.revision), [5])
    }

    func testRemapSurvivesUntilConsumedOnTheSameDirectory() async throws {
        let cache = temporaryCache()
        let original = bundle()
        CatalogURLProtocolStub.handler = { request in
            let url = try Self.url(request)
            if url.path.hasSuffix("/bootstrap") {
                return try Self.http(url: url, status: 200, body: self.encoder.encode(BootstrapResponse(schemaVersion: 1, cursor: "3", events: [original])))
            }
            let change = CatalogChange(sequence: "3", eventID: "e1", revision: nil, kind: "remap", bundle: nil, replacementID: "e2")
            return try Self.http(url: url, status: 200, body: self.encoder.encode(CatalogChangesResponse(cursor: "4", changes: [change])))
        }
        _ = try await makeRepository(cache: cache).allBundles()
        _ = try await makeRepository(cache: cache).refresh()
        let remaps = await makeRepository(cache: cache).consumeRemaps()
        XCTAssertEqual(remaps, [CatalogRemap(eventID: "e1", replacementID: "e2")])
        let again = await makeRepository(cache: cache).consumeRemaps()
        XCTAssertTrue(again.isEmpty)
    }

    func testBearerTokenIsPresentOnRequest() async throws {
        let seen = Gate()
        CatalogURLProtocolStub.handler = { request in
            seen.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
            seen.append(request.url?.absoluteString ?? "")
            let url = try Self.url(request)
            return try Self.http(url: url, status: 200, body: self.encoder.encode(BootstrapResponse(schemaVersion: 1, cursor: "1", events: [self.bundle()])))
        }
        _ = try await makeRepository(cache: temporaryCache(), bearerToken: "secret-token").allBundles()
        XCTAssertEqual(seen.values.first, "Bearer secret-token")
        XCTAssertFalse(seen.values.dropFirst().contains { $0.contains("secret-token") })
    }

    func testNotModifiedKeepsCachedEventAndCursor() async throws {
        let cache = temporaryCache()
        let kept = bundle(title: "Kept", revision: 4)
        let gate = Gate()
        CatalogURLProtocolStub.handler = { request in
            let url = try Self.url(request)
            if url.path.hasSuffix("/bootstrap") {
                return try Self.http(url: url, status: 200, body: self.encoder.encode(BootstrapResponse(schemaVersion: 1, cursor: "15", events: [kept])))
            }
            if url.path.contains("/events/") {
                let turn = gate.next()
                if turn == 1 {
                    return try Self.http(url: url, status: 200, body: self.encoder.encode(kept), headers: ["Content-Type": "application/json", "ETag": "W/\"kept\""])
                }
                gate.append(request.value(forHTTPHeaderField: "If-None-Match") ?? "")
                return Self.http(url: url, status: 304, body: Data(), headers: ["ETag": "W/\"kept\""])
            }
            gate.append("cursor:" + (Self.cursor(url) ?? ""))
            return try Self.http(url: url, status: 200, body: self.encoder.encode(CatalogChangesResponse(cursor: "15", changes: [])))
        }
        let repository = makeRepository(cache: cache)
        _ = try await repository.allBundles()
        let updated = try await repository.refresh(eventID: "e1")
        XCTAssertEqual(updated?.event.officialTitle, "Kept")
        let cached = try await repository.refresh(eventID: "e1")
        XCTAssertEqual(cached?.event.officialTitle, "Kept")
        XCTAssertEqual(cached?.revision, 4)
        _ = try await repository.refresh()
        XCTAssertEqual(gate.values, ["W/\"kept\"", "cursor:15"])
        let stored = try await makeRepository(cache: cache).allBundles()
        XCTAssertEqual(stored.map(\.event.officialTitle), ["Kept"])
    }

    func testSameServerInstanceSharesCatalogAcrossBaseURLs() async throws {
        let cache = temporaryCache()
        let gate = Gate()
        let event = bundle(id: "shared", title: "Shared", revision: 1)
        CatalogURLProtocolStub.handler = { request in
            let url = try Self.url(request)
            gate.append(url.host ?? "")
            return try Self.http(url: url, status: 200, body: self.encoder.encode(BootstrapResponse(schemaVersion: 1, cursor: "1", events: [event])))
        }
        let session = makeSession()
        let first = try await makeRepository(session: session, cache: cache, baseURL: "https://a.example.test/", serverInstanceID: "prod/1").allBundles()
        let second = try await makeRepository(session: session, cache: cache, baseURL: "https://b.example.test/", serverInstanceID: "prod/1").allBundles()
        XCTAssertEqual(first.map(\.event.id), ["shared"])
        XCTAssertEqual(second.map(\.event.id), ["shared"])
        XCTAssertEqual(gate.values, ["a.example.test"])
    }

    func testRemapReceivedBefore410IsCarriedIntoBootstrap() async throws {
        let cache = temporaryCache()
        let original = bundle(id: "e1", title: "Original", revision: 1)
        let replacement = bundle(id: "e2", title: "Replacement", revision: 1)
        let bootstraps = Gate()
        CatalogURLProtocolStub.handler = { request in
            let url = try Self.url(request)
            if url.path.hasSuffix("/bootstrap") {
                let turn = bootstraps.next()
                let response = turn == 1
                    ? BootstrapResponse(schemaVersion: 1, cursor: "1", events: [original])
                    : BootstrapResponse(schemaVersion: 1, cursor: "9", events: [replacement])
                return try Self.http(url: url, status: 200, body: self.encoder.encode(response))
            }
            let turn = bootstraps.next()
            if turn == 2 {
                let change = CatalogChange(sequence: "2", eventID: "e1", revision: 1, kind: "remap", bundle: nil, replacementID: "e2")
                return try Self.http(url: url, status: 200, body: self.encoder.encode(CatalogChangesResponse(cursor: "2", changes: [change], hasMore: true)))
            }
            return Self.http(url: url, status: 410, body: Data())
        }
        let repository = makeRepository(cache: cache)
        _ = try await repository.allBundles()
        let refreshed = try await repository.refresh()
        XCTAssertEqual(refreshed.map(\.event.id), ["e2"])
        let remaps = await repository.consumeRemaps()
        XCTAssertEqual(remaps, [CatalogRemap(eventID: "e1", replacementID: "e2")])
        let again = await makeRepository(cache: cache).consumeRemaps()
        XCTAssertTrue(again.isEmpty)
    }

    func testFailedSecondDeltaPageDoesNotPersistFirstPageCursor() async throws {
        let cache = temporaryCache()
        let original = bundle(id: "e1", title: "Original", revision: 1)
        let extra = bundle(id: "e2", title: "Page One", revision: 1)
        let seen = Gate()
        CatalogURLProtocolStub.handler = { request in
            let url = try Self.url(request)
            if url.path.hasSuffix("/bootstrap") {
                return try Self.http(url: url, status: 200, body: self.encoder.encode(BootstrapResponse(schemaVersion: 1, cursor: "3", events: [original])))
            }
            let cursor = Self.cursor(url) ?? ""
            let turn = seen.next()
            if turn == 1 {
                let change = CatalogChange(sequence: "4", eventID: "e2", revision: 1, kind: "upsert", bundle: extra, replacementID: nil)
                return try Self.http(url: url, status: 200, body: self.encoder.encode(CatalogChangesResponse(cursor: "4", changes: [change], hasMore: true)))
            }
            if turn == 2 { return Self.http(url: url, status: 500, body: Data()) }
            seen.append(cursor)
            return try Self.http(url: url, status: 200, body: self.encoder.encode(CatalogChangesResponse(cursor: "3", changes: [])))
        }
        let repository = makeRepository(cache: cache)
        _ = try await repository.allBundles()
        do {
            _ = try await repository.refresh()
            XCTFail("expected second page failure")
        } catch let error as HTTPError {
            XCTAssertEqual(error.statusCode, 500)
        }
        let stored = try await makeRepository(cache: cache).allBundles()
        XCTAssertEqual(stored.map(\.event.id), ["e1"])
        _ = try await makeRepository(cache: cache).refresh()
        XCTAssertEqual(seen.values, ["3"])
    }

    private func bundle(id: String = "e1", title: String = "Kept", revision: Int? = 5) -> LiveEventBundle {
        let event = LiveEvent(id: id, franchise: .bangdream, officialTitle: title, groups: [], eventType: .live, status: .scheduled, primarySourceURL: "https://example.com/e", timeZone: "Asia/Tokyo")
        return LiveEventBundle(schemaVersion: 1, revision: revision, publishedAt: Date(timeIntervalSince1970: 1_700_000_000), event: event, stops: [], performances: [], ticketTiers: [], ticketRounds: [], ticketOffers: [], goodsCampaigns: [], mediaAssets: [], notices: [], evidence: [])
    }

    private func temporaryCache() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogURLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    private func makeRepository(session: URLSession? = nil, cache: URL, baseURL: String = "https://api.example.test/", serverInstanceID: String? = nil, bearerToken: String? = nil) -> APILiveRepository {
        APILiveRepository(baseURL: URL(string: baseURL)!, session: session ?? makeSession(), cacheDirectory: cache, serverInstanceID: serverInstanceID, bearerToken: bearerToken)
    }

    private static func url(_ request: URLRequest) throws -> URL {
        guard let url = request.url else { throw URLError(.badURL) }
        return url
    }

    private static func cursor(_ url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "cursor" }?.value
    }

    private static func http(url: URL, status: Int, body: Data, headers: [String: String] = ["Content-Type": "application/json"]) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!, body)
    }
}

private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var storage: [String] = []
    func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
    func append(_ value: String) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}

private final class CatalogURLProtocolStub: URLProtocol, @unchecked Sendable {
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
