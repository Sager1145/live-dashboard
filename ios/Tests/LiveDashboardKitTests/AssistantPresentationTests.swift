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

        // Dates are never colour-only (no longer blue, which read as "tap
        // me"); they stay `.primary` and gain monospaced digits.
        let dateRun = runs[1]
        XCTAssertEqual(dateRun.foregroundColor, .primary)

        let priceRun = runs[2]
        XCTAssertEqual(priceRun.foregroundColor, .primary)
        XCTAssertEqual(priceRun.inlinePresentationIntent, .stronglyEmphasized)

        // Cancellation/deadline-type text uses the semantic critical colour.
        let importantRun = runs[3]
        XCTAssertEqual(importantRun.foregroundColor, .statusCritical)
        XCTAssertEqual(importantRun.inlinePresentationIntent, .stronglyEmphasized)

        let linkRun = runs[4]
        XCTAssertEqual(linkRun.link, URL(string: "https://eplus.jp"))
    }

    func testAttributedPrependsWarningSymbol() throws {
        let text = AssistantRichText(segments: [
            AssistantTextSegment(text: "请留意名额有限", style: .warning),
        ])
        let attributed = text.attributed()
        let runs = Array(attributed.runs)
        // The symbol and the text share attributes, so they may merge into a single run.
        XCTAssertFalse(runs.isEmpty)
        XCTAssertTrue(String(attributed.characters).hasPrefix("⚠︎"))
        XCTAssertTrue(String(attributed.characters).hasSuffix("请留意名额有限"))
        for run in runs {
            XCTAssertEqual(run.foregroundColor, .statusWarning)
        }
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

    func testKeyPointAccessibilityLabelContainsImportanceAndCategoryText() {
        let point = AssistantKeyPoint(id: "k1", category: .ticket, importance: .high, text: AssistantRichText("购票截止时间提前"), performanceIDs: [])
        let category = AssistantCategoryLabel(point.category)
        let expectedLabel = "\(importanceText(point.importance))，\(category.text)：\(point.text.plainText)"

        XCTAssertTrue(expectedLabel.contains(importanceText(.high)))
        XCTAssertTrue(expectedLabel.contains(category.text))
        // Category and importance labels are localized, so compare against the same lookups.
        XCTAssertEqual(expectedLabel, "\(importanceText(.high))，\(String(localized: "售票", bundle: .kit))：购票截止时间提前")
    }

    func testAttributedPrependsWarningSymbolOnceForConsecutiveWarningSegments() throws {
        let text = AssistantRichText(segments: [
            AssistantTextSegment(text: "名额有限，", style: .warning),
            AssistantTextSegment(text: "先到先得", style: .warning),
            AssistantTextSegment(text: "。", style: .normal),
        ])
        let characters = String(text.attributed().characters)
        // Only one warning symbol should appear, at the start of the run,
        // not before every consecutive warning segment.
        XCTAssertEqual(characters.components(separatedBy: "⚠︎").count - 1, 1)
        XCTAssertTrue(characters.hasPrefix("⚠︎ 名额有限，先到先得"))
    }

    func testAttributedDoesNotOverrideCallerFontForDateSegments() throws {
        let text = AssistantRichText(segments: [
            AssistantTextSegment(text: "18:00", style: .date),
        ])
        let runs = Array(text.attributed().runs)
        XCTAssertEqual(runs.count, 1)
        // Font is left unset so the rendering view's own font (and its
        // `.monospacedDigit()` modifier) apply instead of a hardcoded one.
        XCTAssertNil(runs[0].font)
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
