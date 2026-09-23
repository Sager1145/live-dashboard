import SwiftUI
import XCTest
@testable import LiveDashboardKit

final class AssistantPresentationTests: XCTestCase {
    func testAttributedMapsEachStyleToItsPresentation() throws {
        let text = AssistantRichText(segments: [
            AssistantTextSegment(text: "开演", style: .normal),
            AssistantTextSegment(text: "18:00", style: .date),
            AssistantTextSegment(text: "¥9,900", style: .price),
            AssistantTextSegment(text: "中止", style: .important),
            AssistantTextSegment(text: "e+", style: .link, url: "https://eplus.jp"),
        ])

        let attributed = text.attributed()
        let runs = Array(attributed.runs)
        XCTAssertEqual(runs.count, 5)

        let dateRun = runs[1]
        XCTAssertEqual(dateRun.foregroundColor, .blue)

        let priceRun = runs[2]
        XCTAssertEqual(priceRun.foregroundColor, .green)
        XCTAssertEqual(priceRun.inlinePresentationIntent, .stronglyEmphasized)

        let importantRun = runs[3]
        XCTAssertEqual(importantRun.foregroundColor, .red)
        XCTAssertEqual(importantRun.inlinePresentationIntent, .stronglyEmphasized)

        let linkRun = runs[4]
        XCTAssertEqual(linkRun.link, URL(string: "https://eplus.jp"))
    }

    func testAttributedTreatsUnparsableLinkURLAsBold() throws {
        let text = AssistantRichText(segments: [
            AssistantTextSegment(text: "详情", style: .link, url: nil),
        ])
        let runs = Array(text.attributed().runs)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].inlinePresentationIntent, .stronglyEmphasized)
        XCTAssertNil(runs[0].link)
    }

    func testKeyPointsOrdersHighBeforeLowAndFiltersByPerformance() {
        let high = AssistantKeyPoint(id: "b-high", category: .ticket, importance: .high, text: AssistantRichText("高"), performanceIDs: ["p1"])
        let low = AssistantKeyPoint(id: "a-low", category: .goods, importance: .low, text: AssistantRichText("低"), performanceIDs: ["p1"])
        let other = AssistantKeyPoint(id: "c-other", category: .notice, importance: .medium, text: AssistantRichText("其他场次"), performanceIDs: ["p2"])
        let whole = AssistantKeyPoint(id: "d-whole", category: .schedule, importance: .medium, text: AssistantRichText("全场"), performanceIDs: [])

        let summary = AssistantEventSummary(
            eventID: "e1",
            generatedAt: .distantPast,
            model: "gpt-5-mini",
            sourceFingerprint: "fp",
            overview: AssistantRichText("overview"),
            keyPoints: [low, high, other, whole],
            performances: [],
            ticketLinks: [],
            goodsLinks: [],
            warnings: []
        )

        let filtered = summary.keyPoints(for: "p1")
        XCTAssertEqual(filtered.map(\.id), ["b-high", "d-whole", "a-low"])
        XCTAssertFalse(filtered.contains { $0.id == "c-other" })
    }

    func testAssistantLinkAppliesToSemantics() {
        let scoped = AssistantLink(label: "e+", url: "https://eplus.jp", kind: .ticketSales, performanceIDs: ["p1"])
        let global = AssistantLink(label: "官网", url: "https://example.com", kind: .other, performanceIDs: [])

        XCTAssertTrue(scoped.applies(to: "p1"))
        XCTAssertFalse(scoped.applies(to: "p2"))
        XCTAssertTrue(global.applies(to: "p1"))
        XCTAssertTrue(global.applies(to: "anything"))
    }
}
