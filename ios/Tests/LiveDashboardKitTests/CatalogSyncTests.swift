import XCTest
import UserNotifications
@testable import LiveDashboardKit

final class CatalogSyncTests: XCTestCase {
    private let instance = "server-demo-1"

    override func setUp() {
        super.setUp()
        CatalogFixtureProtocol.reset()
    }

    override func tearDown() {
        CatalogFixtureProtocol.reset()
        super.tearDown()
    }

    func testDecimalCursorComparesLengthThenTextNotDouble() {
        XCTAssertEqual(DecimalCursor.compare("9", "10"), -1)
        XCTAssertEqual(DecimalCursor.compare("99", "100"), -1)
        XCTAssertEqual(DecimalCursor.compare("100", "99"), 1)
        XCTAssertEqual(DecimalCursor.compare("10", "10"), 0)
        let low = "9007199254740992"
        let high = "9007199254740993"
        XCTAssertEqual(DecimalCursor.compare(low, high), -1)
        XCTAssertEqual(Double(low), Double(high))
    }

    func testV2FixtureStaysSchemaVersionTwo() throws {
        let payload = try fixtureData()
        XCTAssertThrowsError(try LiveEventBundle.decoder.decode(LiveEventBundle.self, from: payload))
        let header = try LiveEventBundle.decoder.decode(SharedContractV2Header.self, from: payload)
        let document = try CatalogEventDocumentV2(payload: payload)
        XCTAssertEqual(header.schemaVersion, 2)
        XCTAssertEqual(document.schemaVersion, 2)
        XCTAssertEqual(document.revision, header.revision)
        XCTAssertEqual(document.eventID, "b3c342aa-714c-47bb-b8fc-854b139427d4")
        XCTAssertEqual(header.performances.map(\.localTime), ["14:00", "19:00"])
    }

    func testV1RepositoryStillRejectsSchemaVersionAboveOne() async throws {
        let body = Data(#"{"schemaVersion":2,"cursor":"1","events":[]}"#.utf8)
        CatalogFixtureProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            return (200, body)
        }
        let directory = try makeDirectory()
        let repository = APILiveRepository(baseURL: baseURL, session: makeSession(), cacheDirectory: directory)
        do {
            _ = try await repository.allBundles()
            XCTFail("schemaVersion 2 must not bootstrap as v1")
        } catch LiveRepositoryError.incompatibleSchema(let version) {
            XCTAssertEqual(version, 2)
        }
        let names = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?.allObjects as? [URL]
        XCTAssertFalse(names?.contains { $0.lastPathComponent == "catalog.json" } == true)
    }

    func testBootstrapPagesShareSnapshotAndInterruptKeepsActiveCatalog() async throws {
        let first = try bundleObject(revision: 1, title: "Kept")
        let second = try bundleObject(revision: 1, title: "Second", eventID: "event-two")
        let pageOne = try bootstrapData(snapshot: "snap-a", cursor: "4", watermark: "8", hasMore: true, token: "p2", events: [first])
        let pageTwo = try bootstrapData(snapshot: "snap-a", cursor: "8", watermark: "8", hasMore: false, token: nil, events: [second])
        CatalogFixtureProtocol.handler = { request in
            let token = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "pageToken" }?.value
            if token == "p2" { return (200, pageTwo) }
            return (200, pageOne)
        }
        let stack = try makeStack()
        let synced = try await stack.coordinator.sync(reason: .foreground)
        XCTAssertTrue(synced.committed)
        XCTAssertEqual(synced.cursor, "8")
        let firstActiveSnapshot = await stack.store.activeSnapshotID()
        XCTAssertEqual(firstActiveSnapshot, "snap-a")
        let titles = await stack.reader.documents().map(\.officialTitle).sorted()
        XCTAssertEqual(titles, ["Kept", "Second"])
        for document in await stack.reader.documents() {
            let header = try LiveEventBundle.decoder.decode(SharedContractV2Header.self, from: document.payload)
            XCTAssertEqual(header.schemaVersion, 2)
            XCTAssertFalse(header.performances.compactMap(\.localTime).isEmpty)
        }

        CatalogFixtureProtocol.handler = { request in
            let token = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "pageToken" }?.value
            if request.url?.path.contains("changes") == true { return (410, Data()) }
            if token == "p2" { throw URLError(.networkConnectionLost) }
            return (200, try self.bootstrapData(snapshot: "snap-new", cursor: "20", watermark: "21", hasMore: true, token: "p2", events: [try self.bundleObject(revision: 3, title: "Should not replace")]))
        }
        do {
            _ = try await stack.coordinator.sync(reason: .pull)
            XCTFail("interrupted rebuild should fail")
        } catch is URLError {
        }
        let committedCursor = await stack.store.committedCursor()
        let activeSnapshot = await stack.store.activeSnapshotID()
        let titlesAfterInterruption = await stack.reader.documents().map(\.officialTitle).sorted()
        let storedAfterInterruption = await stack.store.documents()
        XCTAssertEqual(committedCursor, "8")
        XCTAssertEqual(activeSnapshot, "snap-a")
        XCTAssertEqual(titlesAfterInterruption, ["Kept", "Second"])
        XCTAssertFalse(storedAfterInterruption.contains { $0.officialTitle == "Should not replace" })
    }

    func testMismatchedSnapshotDoesNotActivate() async throws {
        let pageOne = try bootstrapData(snapshot: "snap-a", cursor: "1", watermark: "2", hasMore: true, token: "p2", events: [try bundleObject(revision: 1, title: "One")])
        let pageTwo = try bootstrapData(snapshot: "snap-b", cursor: "2", watermark: "2", hasMore: false, token: nil, events: [try bundleObject(revision: 1, title: "Two", eventID: "event-two")])
        CatalogFixtureProtocol.handler = { request in
            let token = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "pageToken" }?.value
            return (200, token == "p2" ? pageTwo : pageOne)
        }
        let stack = try makeStack()
        do {
            _ = try await stack.coordinator.sync(reason: .foreground)
            XCTFail("snapshot mismatch must not commit")
        } catch let error as CatalogSyncError {
            guard case .snapshotMismatch = error else {
                XCTFail("unexpected \(error)")
                return
            }
        }
        let committedCursor = await stack.store.committedCursor()
        let documents = await stack.reader.documents()
        XCTAssertNil(committedCursor)
        XCTAssertTrue(documents.isEmpty)
    }

    func testDeltaReplacesWholeBundleAndRefusesOlderRevision() async throws {
        let stack = try makeStack()
        CatalogFixtureProtocol.handler = { _ in
            (200, try self.bootstrapData(snapshot: "snap", cursor: "5", watermark: "5", hasMore: false, token: nil, events: [try self.bundleObject(revision: 2, title: "Current")]))
        }
        _ = try await stack.coordinator.sync(reason: .foreground)
        let older = try changesData(from: "5", cursor: "6", watermark: "6", changes: [
            try change(kind: "upsert", sequence: "6", bundle: try bundleObject(revision: 1, title: "Regressed")),
        ])
        CatalogFixtureProtocol.handler = { _ in (200, older) }
        let regressed = try await stack.coordinator.sync(reason: .pull)
        XCTAssertTrue(regressed.committed)
        XCTAssertEqual(regressed.cursor, "6")
        let keptDocument = await stack.reader.document(eventID: "b3c342aa-714c-47bb-b8fc-854b139427d4")
        let kept = try XCTUnwrap(keptDocument)
        XCTAssertEqual(kept.revision, 2)
        XCTAssertEqual(kept.officialTitle, "Current")
        XCTAssertEqual(try LiveEventBundle.decoder.decode(SharedContractV2Header.self, from: kept.payload).schemaVersion, 2)

        let newer = try changesData(from: "6", cursor: "100", watermark: "100", changes: [
            try change(kind: "upsert", sequence: "100", bundle: try bundleObject(revision: 4, title: "Replaced")),
        ])
        CatalogFixtureProtocol.handler = { _ in (200, newer) }
        let advanced = try await stack.coordinator.sync(reason: .foreground)
        XCTAssertEqual(advanced.cursor, "100")
        let replacedDocument = await stack.reader.document(eventID: kept.eventID)
        let replaced = try XCTUnwrap(replacedDocument)
        XCTAssertEqual(replaced.revision, 4)
        XCTAssertEqual(replaced.officialTitle, "Replaced")
        XCTAssertEqual(DecimalCursor.compare("99", advanced.cursor), -1)
    }

    func testUnknownKindLeavesCatalogAndCursor() async throws {
        let stack = try await seeded(cursor: "5", title: "Stable")
        let page = try changesData(from: "5", cursor: "9", watermark: "9", changes: [
            try change(kind: "upsert", sequence: "8", bundle: try bundleObject(revision: 3, title: "Should stay staged only")),
            try change(kind: "patch", sequence: "9", bundle: nil),
        ])
        CatalogFixtureProtocol.handler = { _ in (200, page) }
        do {
            _ = try await stack.coordinator.sync(reason: .push)
            XCTFail("unknown kind must not commit")
        } catch CatalogSyncError.unknownChangeKind(let kind) {
            XCTAssertEqual(kind, "patch")
        }
        let committedCursor = await stack.store.committedCursor()
        let titles = await stack.reader.documents().map(\.officialTitle)
        XCTAssertEqual(committedCursor, "5")
        XCTAssertEqual(titles, ["Stable"])
    }

    func testSaveFailureDoesNotCommitCursor() async throws {
        let stack = try makeStack()
        await stack.store.setFailNextWrite(true)
        CatalogFixtureProtocol.handler = { _ in
            (200, try self.bootstrapData(snapshot: "snap", cursor: "12", watermark: "12", hasMore: false, token: nil, events: [try self.bundleObject(revision: 1, title: "Unsaved")]))
        }
        let result = try await stack.coordinator.sync(reason: .foreground)
        XCTAssertFalse(result.committed)
        XCTAssertEqual(result.cursor, "")
        XCTAssertNotEqual(result.cursor, "12")
        let documents = await stack.reader.documents()
        let canCommitMissing = await stack.store.canCommit(generation: UUID(), windowEventIDs: ["b3c342aa-714c-47bb-b8fc-854b139427d4"])
        XCTAssertTrue(documents.isEmpty)
        XCTAssertFalse(canCommitMissing)
    }

    func testReceivedBundleThatIsNotInStagingCannotCommit() async throws {
        let saved: Set<String> = []
        XCTAssertFalse(CatalogCursorCommit.canCommit(savedEventIDs: saved, windowEventIDs: ["event-1"]))
        XCTAssertTrue(CatalogCursorCommit.canCommit(savedEventIDs: ["event-1"], windowEventIDs: ["event-1"]))
    }

    func testDetailRevisionSurvivesOlderDeltaWithoutMovingCursorFirst() async throws {
        let stack = try await seeded(cursor: "5", title: "Base")
        CatalogFixtureProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.httpBody)
            XCTAssertFalse(request.url?.path.contains("update-jobs") == true)
            return (200, try self.bundleData(revision: 5, title: "Detail"))
        }
        let detail = try await stack.reader.publishedEvent(eventID: "b3c342aa-714c-47bb-b8fc-854b139427d4")
        XCTAssertEqual(detail.revision, 5)
        let cursorBeforeDelta = await stack.store.committedCursor()
        XCTAssertEqual(cursorBeforeDelta, "5")
        let older = try changesData(from: "5", cursor: "7", watermark: "7", changes: [
            try change(kind: "upsert", sequence: "7", bundle: try bundleObject(revision: 3, title: "Older than detail")),
        ])
        CatalogFixtureProtocol.handler = { _ in (200, older) }
        _ = try await stack.coordinator.sync(reason: .foreground)
        let keptDocument = await stack.reader.document(eventID: detail.eventID)
        let kept = try XCTUnwrap(keptDocument)
        XCTAssertEqual(kept.revision, 5)
        XCTAssertEqual(kept.officialTitle, "Detail")
        let cursorAfterDelta = await stack.store.committedCursor()
        XCTAssertEqual(cursorAfterDelta, "7")
    }

    @MainActor
    func testGoneRebuildsPublicCatalogWithoutDeletingUserData() async throws {
        let users = UserDataStore(container: UserDataStore.makeContainer(inMemory: true))
        users.setFollowed(true, eventID: "keep-me")
        let stack = try makeStack()
        let original = try bootstrapData(snapshot: "snap", cursor: "5", watermark: "5", hasMore: false, token: nil, events: [try bundleObject(revision: 1, title: "Old public")])
        CatalogFixtureProtocol.handler = { _ in (200, original) }
        let seeded = try await stack.coordinator.sync(reason: .foreground)
        XCTAssertEqual(seeded.cursor, "5")
        let rebuilt = try bootstrapData(snapshot: "snap-rebuild", cursor: "40", watermark: "40", hasMore: false, token: nil, events: [try bundleObject(revision: 2, title: "Rebuilt")])
        CatalogFixtureProtocol.handler = { request in
            if request.url?.path.contains("changes") == true { return (410, Data()) }
            return (200, rebuilt)
        }
        let result = try await stack.coordinator.sync(reason: .foreground)
        XCTAssertTrue(result.committed)
        XCTAssertEqual(result.cursor, "40")
        let titles = await stack.reader.documents().map(\.officialTitle)
        XCTAssertEqual(titles, ["Rebuilt"])
        XCTAssertTrue(users.state(for: "keep-me").isFollowed)
        XCTAssertEqual(users.eventStates.count, 1)
    }

    func testForegroundPullAndPushCoalesceToOneSync() async throws {
        let page = try bootstrapData(snapshot: "snap", cursor: "4", watermark: "4", hasMore: false, token: nil, events: [try bundleObject(revision: 1, title: "One")])
        let release = BlockingGate()
        let entries = EntryGate()
        CatalogFixtureProtocol.handler = { _ in
            release.wait()
            return (200, page)
        }
        let stack = try makeStack(onEntered: { _ in entries.enter() })
        async let ready = entries.waitUntil(3)
        async let foreground = stack.coordinator.sync(reason: .foreground)
        async let pull = stack.coordinator.sync(reason: .pull)
        async let push = stack.coordinator.sync(reason: .push)
        await ready
        let deadline = Date().addingTimeInterval(2)
        while CatalogFixtureProtocol.requestCount < 1, Date() < deadline {
            await Task.yield()
        }
        XCTAssertEqual(CatalogFixtureProtocol.requestCount, 1)
        release.open()
        let results = try await [foreground, pull, push]
        XCTAssertEqual(CatalogFixtureProtocol.requestCount, 1)
        XCTAssertEqual(results.map(\.cursor), ["4", "4", "4"])
        XCTAssertEqual(results.filter(\.coalesced).count, 2)
        XCTAssertTrue(results.contains { !$0.coalesced && $0.reason == .foreground })
    }

    @MainActor
    func testGetClientDoesNotBuildUpdateJobAndPullDoesNotRequestRefresh() async throws {
        let meta = Data(#"{"serverInstanceID":"server-demo-1","schemaVersions":[2],"capabilities":["catalog"]}"#.utf8)
        let event = try fixtureData()
        let bootstrap = try bootstrapData(snapshot: "snap", cursor: "1", watermark: "1", hasMore: false, token: nil, events: [try bundleObject(revision: 1, title: "Listed")])
        let changes = try changesData(from: "1", cursor: "1", watermark: "1", changes: [])
        CatalogFixtureProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/v2/meta") { return (200, meta) }
            if path.contains("/v2/events/") { return (200, event) }
            if path.contains("changes") { return (200, changes) }
            if path.contains("bootstrap") { return (200, bootstrap) }
            if path.contains("update-jobs") {
                return (200, Data(#"{"jobID":"job-1","state":"queued","deduplicated":false,"statusPath":"/v2/update-jobs/job-1"}"#.utf8))
            }
            return (404, Data())
        }
        let client = CatalogAPIClient(baseURL: baseURL, session: makeSession())
        _ = try await client.meta()
        _ = try await client.bootstrapPage(pageToken: nil)
        _ = try await client.changesPage(cursor: "1", pageToken: nil)
        _ = try await client.publishedEvent(eventID: "b3c342aa-714c-47bb-b8fc-854b139427d4")
        let gets = CatalogFixtureProtocol.recordedRequests
        XCTAssertEqual(gets.count, 4)
        for request in gets {
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.httpBody)
            XCTAssertNil(request.httpBodyStream)
            XCTAssertFalse(request.url?.path.contains("update-jobs") == true)
        }

        let jobs = UpdateJobClient(baseURL: baseURL, session: makeSession())
        let accepted = try await jobs.requestRefresh(RefreshRequest(target: .event(eventID: "event-1"), fetchLatest: false, reextract: true, reason: "owner_requested"))
        XCTAssertEqual(accepted.jobID, "job-1")
        let posted = CatalogFixtureProtocol.recordedRequests.last
        XCTAssertEqual(posted?.httpMethod, "POST")
        XCTAssertTrue(posted?.url?.path.contains("update-jobs") == true)
        let body = try XCTUnwrap(CatalogFixtureProtocol.recordedBodies.last ?? nil)
        let json = try XCTUnwrap(String(data: body, encoding: .utf8))
        XCTAssertTrue(json.contains("fetchLatest"))
        XCTAssertTrue(json.contains("owner_requested"))
        XCTAssertFalse(json.contains("\"schemaVersion\""))

        let syncSpy = SyncSpy()
        let jobSpy = JobSpy()
        let local = LocalLiveRepository(directory: try makeDirectory())
        let center = LiveActionCenter(
            reader: EmptyCatalogReader(),
            sync: syncSpy,
            jobs: jobSpy,
            userDataStore: UserDataStore(container: UserDataStore.makeContainer(inMemory: true)),
            reminderService: ReminderStub(),
            repository: local
        )
        _ = await center.refreshSpeech(eventID: "missing", title: "Missing")
        XCTAssertEqual(syncSpy.reasons, [.pull])
        XCTAssertEqual(jobSpy.requests, 0)
        _ = try await center.requestServerRefresh(RefreshRequest(target: .catalog, fetchLatest: true, reextract: false, reason: "owner_requested"))
        XCTAssertEqual(jobSpy.requests, 1)
        XCTAssertEqual(syncSpy.reasons, [.pull])
    }

    func testRepositoryCacheUsesInstanceNotHost() async throws {
        let directory = try makeDirectory()
        CatalogFixtureProtocol.handler = { _ in
            (200, Data(#"{"schemaVersion":1,"cursor":"1","events":[]}"#.utf8))
        }
        let first = APILiveRepository(baseURL: baseURL, session: makeSession(), cacheDirectory: directory, serverInstanceID: instance)
        let firstBundles = try await first.allBundles()
        XCTAssertTrue(firstBundles.isEmpty)
        let second = APILiveRepository(baseURL: URL(string: "https://tunnel.example/")!, session: makeSession(), cacheDirectory: directory, serverInstanceID: instance)
        let secondBundles = try await second.allBundles()
        XCTAssertTrue(secondBundles.isEmpty)
        XCTAssertEqual(CatalogFixtureProtocol.requestCount, 1)
    }

    private var baseURL: URL { URL(string: "https://catalog.test/")! }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogFixtureProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func makeStack(onEntered: @escaping @Sendable (SyncReason) -> Void = { _ in }) throws -> (coordinator: CatalogSyncCoordinator, store: CatalogGenerationStore, reader: APICatalogV2Reader) {
        let directory = try makeDirectory()
        let client = CatalogAPIClient(baseURL: baseURL, session: makeSession())
        let store = CatalogGenerationStore(directory: directory.appendingPathComponent("catalog"), serverInstanceID: instance)
        let coordinator = CatalogSyncCoordinator(client: client, store: store, serverInstanceID: instance, onEntered: onEntered)
        let reader = APICatalogV2Reader(client: client, store: store, sync: coordinator)
        return (coordinator, store, reader)
    }

    private func seeded(cursor: String, title: String) async throws -> (coordinator: CatalogSyncCoordinator, store: CatalogGenerationStore, reader: APICatalogV2Reader) {
        let stack = try makeStack()
        let page = try bootstrapData(snapshot: "snap", cursor: cursor, watermark: cursor, hasMore: false, token: nil, events: [try bundleObject(revision: 1, title: title)])
        CatalogFixtureProtocol.handler = { _ in (200, page) }
        let seeded = try await stack.coordinator.sync(reason: .foreground)
        XCTAssertEqual(seeded.cursor, cursor)
        return stack
    }

    private func fixtureData() throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/contracts/bundle-v2.json")
        return try Data(contentsOf: url)
    }

    private func bundleObject(revision: Int, title: String, eventID: String? = nil) throws -> [String: Any] {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: try fixtureData()) as? [String: Any])
        object["schemaVersion"] = 2
        object["revision"] = revision
        var event = try XCTUnwrap(object["event"] as? [String: Any])
        event["officialTitle"] = title
        if let eventID { event["id"] = eventID }
        object["event"] = event
        return object
    }

    private func bundleData(revision: Int, title: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: try bundleObject(revision: revision, title: title))
    }

    private func bootstrapData(snapshot: String, cursor: String, watermark: String, hasMore: Bool, token: String?, events: [[String: Any]]) throws -> Data {
        let object: [String: Any] = [
            "schemaVersion": 2,
            "serverInstanceID": instance,
            "snapshotID": snapshot,
            "cursor": cursor,
            "watermark": watermark,
            "hasMore": hasMore,
            "nextPageToken": token ?? NSNull(),
            "events": events,
        ]
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func change(kind: String, sequence: String, bundle: [String: Any]?) throws -> [String: Any] {
        var object: [String: Any] = ["sequence": sequence, "kind": kind]
        if kind == "upsert" {
            let event = try XCTUnwrap(bundle?["event"] as? [String: Any])
            object["eventID"] = event["id"] as Any
            object["revision"] = bundle?["revision"] as Any
            object["bundle"] = bundle as Any
        } else if kind == "patch" {
            object["eventID"] = "b3c342aa-714c-47bb-b8fc-854b139427d4"
        }
        return object
    }

    private func changesData(from: String, cursor: String, watermark: String, changes: [[String: Any]]) throws -> Data {
        let object: [String: Any] = [
            "schemaVersion": 2,
            "serverInstanceID": instance,
            "fromCursor": from,
            "cursor": cursor,
            "watermark": watermark,
            "hasMore": false,
            "nextPageToken": NSNull(),
            "changes": changes,
            "sourceHealth": [String: String](),
        ]
        return try JSONSerialization.data(withJSONObject: object)
    }

}

private actor EmptyCatalogReader: CatalogReadRepository {
    func allBundles() async throws -> [LiveEventBundle] { [] }
    func bundle(eventID: String) async throws -> LiveEventBundle? { nil }
}

private final class SyncSpy: CatalogSyncService, @unchecked Sendable {
    var reasons: [SyncReason] = []
    func sync(reason: SyncReason) async throws -> SyncResult {
        reasons.append(reason)
        return SyncResult(cursor: "1", committed: true, coalesced: false, reason: reason)
    }
}

private final class JobSpy: RefreshJobService, @unchecked Sendable {
    var requests = 0
    func requestRefresh(_ request: RefreshRequest) async throws -> RefreshJob {
        requests += 1
        return RefreshJob(jobID: "job", state: "queued", deduplicated: false)
    }
    func status(jobID: String) async throws -> RefreshJob {
        RefreshJob(jobID: jobID, state: "queued")
    }
}

private struct ReminderStub: ReminderScheduling {
    func requestAuthorizationIfNeeded() async -> Bool { false }
    func authorizationStatus() async -> UNAuthorizationStatus { .denied }
    func scheduleDeadlineReminder(identifier: ReminderIdentifier, title: String, body: String, fireAt: Date) async throws {}
    func cancelReminder(identifier: ReminderIdentifier) async {}
}

private final class EntryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var expected = 0
    private var waiter: CheckedContinuation<Void, Never>?

    func enter() {
        lock.lock()
        count += 1
        let resume = count >= expected && expected > 0 ? waiter : nil
        if resume != nil { waiter = nil }
        lock.unlock()
        resume?.resume()
    }

    func waitUntil(_ count: Int) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            expected = count
            if self.count >= count {
                lock.unlock()
                continuation.resume()
                return
            }
            waiter = continuation
            lock.unlock()
        }
    }
}

private final class BlockingGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var opened = false

    func wait() {
        lock.lock()
        let already = opened
        lock.unlock()
        if !already { semaphore.wait() }
    }

    func open() {
        lock.lock()
        opened = true
        lock.unlock()
        semaphore.signal()
    }
}

private final class CatalogFixtureProtocol: URLProtocol, @unchecked Sendable {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var handler: ((URLRequest) throws -> (Int, Data))?
        var requests: [URLRequest] = []
        var bodies: [Data?] = []
    }

    private static let state = State()

    static var handler: ((URLRequest) throws -> (Int, Data))? {
        get {
            state.lock.lock()
            defer { state.lock.unlock() }
            return state.handler
        }
        set {
            state.lock.lock()
            state.handler = newValue
            state.lock.unlock()
        }
    }

    static var recordedRequests: [URLRequest] {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.requests
    }

    static var requestCount: Int { recordedRequests.count }

    static var recordedBodies: [Data?] {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.bodies
    }

    static func reset() {
        state.lock.lock()
        state.handler = nil
        state.requests = []
        state.bodies = []
        state.lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "catalog.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? Self.readBody(request.httpBodyStream)
        Self.state.lock.lock()
        let handler = Self.state.handler
        Self.state.requests.append(request)
        Self.state.bodies.append(body)
        Self.state.lock.unlock()
        do {
            guard let handler else { throw URLError(.unsupportedURL) }
            let (status, data) = try handler(request)
            guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else {
                throw URLError(.badServerResponse)
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func readBody(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}

private extension CatalogGenerationStore {
    func setFailNextWrite(_ value: Bool) { failNextWrite = value }
}
