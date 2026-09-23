import XCTest
import UIKit
@testable import LiveDashboardKit

/// Opt-in: LIVE_DASHBOARD_NETWORK_TESTS=1 in the test runner environment.
/// Kept out of ordinary deterministic runs because these are real official sites.
final class OfficialNetworkIntegrationTests: XCTestCase {
    func testLoveLiveOfficialDetailsOnDevice() async throws {
        guard ProcessInfo.processInfo.environment["LIVE_DASHBOARD_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("Enable LIVE_DASHBOARD_NETWORK_TESTS to check the live official website")
        }
        struct Entry: Decodable { let id: String; let url: String; let title: String }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf:
            root.appendingPathComponent("docs/audits/2026-09-22/lovelive/replay-manifest.json")))
        XCTAssertEqual(entries.count, 20)
        let scraper = OfficialEventScraper(session: URLSession(configuration: .ephemeral), indexURLs: [])
        let mediaLoader = URLSessionOfficialMediaLoader(session: URLSession(configuration: .ephemeral))
        var testedImageBranches = Set<String>()
        for entry in entries {
            let event = LiveEvent(id: entry.id, franchise: .lovelive, officialTitle: entry.title,
                groups: [], eventType: .live, status: .unknown, primarySourceURL: entry.url, timeZone: "Asia/Tokyo")
            let cached = LiveEventBundle(schemaVersion: 1, publishedAt: .distantPast, event: event,
                stops: [], performances: [], ticketTiers: [], ticketRounds: [], ticketOffers: [],
                goodsCampaigns: [], mediaAssets: [], notices: [], evidence: [])
            do {
                let refreshed = try await scraper.collect(event: cached, now: Date())
                XCTAssertFalse(refreshed.performances.isEmpty, entry.url)
                print("Official live fetch \(entry.id): \(refreshed.performances.count) performances")
                if let asset = refreshed.mediaAssets.first(where: { $0.isImage }),
                   let url = URL(string: asset.originalURL),
                   let branch = url.path.split(separator: "/").first,
                   testedImageBranches.insert(String(branch)).inserted {
                    let image = try await mediaLoader.load(url)
                    XCTAssertNotNil(UIImage(data: image.data), asset.originalURL)
                }
            } catch {
                XCTFail("\(entry.id) \(entry.url): \(error)")
            }
        }
        XCTAssertFalse(testedImageBranches.isEmpty)
        print("Official live images: \(testedImageBranches.sorted().joined(separator: ", "))")
    }
}
