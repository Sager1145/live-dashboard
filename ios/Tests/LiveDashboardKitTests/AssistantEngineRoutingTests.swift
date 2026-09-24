import XCTest
@testable import LiveDashboardKit

@MainActor
final class AssistantEngineRoutingTests: XCTestCase {
    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames {
            UserDefaults().removePersistentDomain(forName: name)
        }
        suiteNames.removeAll()
        super.tearDown()
    }

    func testAppleEngineGenerateStaleRunsWithoutSignInAndDoesNotSaveSummary() async {
        let organizer = FakeOnDeviceOrganizer()
        let coordinator = makeCoordinator(organizer: organizer)
        coordinator.engine = .appleOnDevice
        coordinator.autoSummarizeAfterRefresh = true
        let bundle = Self.fixtureBundle(sourceText: "2026年3月1日 10:00 开场")

        await coordinator.generateStale(in: [bundle])

        XCTAssertEqual(organizer.eventIDs, [bundle.event.id])
        XCTAssertTrue(coordinator.summaries.isEmpty)
        XCTAssertFalse(coordinator.account.isSignedIn)
        XCTAssertEqual(
            coordinator.localDraftNote(for: bundle.event.id),
            "已保存 1 条本地日期角色草稿，需要核对，尚未写入票务截止。"
        )
    }

    func testOpenAIGenerateStaleDoesNotCallOnDeviceOrganizerWhenSignedOut() async {
        let organizer = FakeOnDeviceOrganizer()
        let coordinator = makeCoordinator(organizer: organizer)
        XCTAssertEqual(coordinator.engine, .openAI)
        coordinator.autoSummarizeAfterRefresh = true

        await coordinator.generateStale(in: [Self.fixtureBundle(sourceText: "2026年3月1日 10:00 开场")])

        XCTAssertTrue(organizer.eventIDs.isEmpty)
        XCTAssertTrue(coordinator.summaries.isEmpty)
    }

    func testOrganizeOnDeviceUsesLocalPathEvenWhenEngineIsOpenAI() async throws {
        let organizer = FakeOnDeviceOrganizer()
        let coordinator = makeCoordinator(organizer: organizer)
        XCTAssertEqual(coordinator.engine, .openAI)
        let bundle = Self.fixtureBundle(sourceText: "2026年3月1日 10:00 开场")
        let repository = LiveActionCenter.shared.repository
        let previous = try await repository.allBundles()
        await repository.installEventsForTesting([bundle])
        await coordinator.organizeOnDevice(eventID: bundle.event.id)
        await repository.installEventsForTesting(previous)

        XCTAssertEqual(organizer.eventIDs, [bundle.event.id])
        XCTAssertNil(coordinator.summary(for: bundle.event.id))
        XCTAssertTrue(coordinator.summaries.isEmpty)
    }

    private func makeCoordinator(organizer: FakeOnDeviceOrganizer) -> AssistantCoordinator {
        let (defaults, suiteName) = isolatedDefaults()
        suiteNames.append(suiteName)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        return AssistantCoordinator(
            officialPageSession: nil,
            accountStore: AssistantAccountStore(secrets: InMemorySecretStore()),
            summaryStore: AssistantSummaryStore(directory: directory),
            defaults: defaults,
            onDeviceOrganizer: organizer
        )
    }

    private func isolatedDefaults() -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "AssistantEngineRoutingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private static func fixtureBundle(sourceText: String?) -> LiveEventBundle {
        let event = LiveEvent(
            id: "event-1",
            franchise: .bangdream,
            officialTitle: "Test LIVE",
            groups: ["Roselia"],
            eventType: .live,
            status: .scheduled,
            primarySourceURL: "https://bang-dream.com/events/test-live/",
            timeZone: "Asia/Tokyo"
        )
        let start = ISO8601DateFormatter().date(from: "2027-03-01T11:00:00Z")!
        let performance = Performance(
            id: "perf-1", eventID: "event-1", stopID: nil, dayLabel: "Day1", subtitle: nil,
            localDate: "2027-03-01", doorsAt: nil, startAt: start, venueName: "Test Hall", venueCity: "Tokyo",
            performers: ["Roselia"], order: 0
        )
        let round = TicketRound(
            id: "round-1", eventID: "event-1", officialName: "一般先行", kind: .lottery, scope: .wholeEvent,
            applyStartAt: nil, applyEndAt: nil, resultAt: nil, paymentDeadlineAt: nil, eligibility: nil,
            announcementURL: nil, applyURL: "https://eplus.jp/round1", overseasURL: nil, officialStatus: nil,
            status: .confirmed, links: [OfficialLink(label: "eplus", url: "https://eplus.jp/round1")]
        )
        return LiveEventBundle(
            schemaVersion: 1, publishedAt: .distantPast, event: event, stops: [], performances: [performance],
            ticketTiers: [], ticketRounds: [round], ticketOffers: [], goodsCampaigns: [], mediaAssets: [],
            notices: [], evidence: [], sourceText: sourceText
        )
    }
}

private final class FakeOnDeviceOrganizer: OnDeviceOrganizing, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var eventIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func organize(bundle: LiveEventBundle, force: Bool) async throws -> OnDeviceOrganizeResult {
        lock.lock()
        recorded.append(bundle.event.id)
        lock.unlock()
        return OnDeviceOrganizeResult(blockCount: 1, draftCount: 1)
    }
}
