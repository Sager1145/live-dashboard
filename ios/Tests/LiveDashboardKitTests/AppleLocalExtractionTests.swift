import Foundation
import os
import XCTest
@testable import LiveDashboardKit

final class AppleLocalExtractionTests: XCTestCase {
    func testValidateRejectsTooManyMentionsDuplicateIDsAndUncitedRawText() {
        XCTAssertThrowsError(try request(mentionCount: 9).validate()) { error in
            XCTAssertEqual(error as? LocalClassificationError, .malformedInput)
        }
        XCTAssertNoThrow(try request(mentionCount: 8).validate())

        var duplicatedMention = request(mentionCount: 2)
        duplicatedMention.mentions[1].id = duplicatedMention.mentions[0].id
        XCTAssertThrowsError(try duplicatedMention.validate()) { error in
            XCTAssertEqual(error as? LocalClassificationError, .malformedInput)
        }

        var duplicatedLine = request(mentionCount: 1)
        duplicatedLine.lines.append(EvidenceLine(id: "L1", text: "2026年1月2日10:00"))
        XCTAssertThrowsError(try duplicatedLine.validate()) { error in
            XCTAssertEqual(error as? LocalClassificationError, .malformedInput)
        }

        var uncited = request(mentionCount: 1)
        uncited.mentions[0].rawText = "2026年2月2日10:00"
        XCTAssertThrowsError(try uncited.validate()) { error in
            XCTAssertEqual(error as? LocalClassificationError, .unsupportedEvidence)
        }
    }

    func testGroundingRejectsBadIDsAndEvidenceAndListsUnclassified() throws {
        let input = request(mentionCount: 2)
        XCTAssertThrowsError(try DateAssignmentGrounding.check(
            assignments: [(mentionID: "missing", roleRaw: "salesStart", evidenceLineIDs: ["L1"])],
            input: input
        )) { error in
            XCTAssertEqual(error as? LocalClassificationError, .invalidCandidateID)
        }

        XCTAssertThrowsError(try DateAssignmentGrounding.check(
            assignments: [
                (mentionID: "d1", roleRaw: "salesStart", evidenceLineIDs: ["L1"]),
                (mentionID: "d1", roleRaw: "salesEnd", evidenceLineIDs: ["L1"]),
            ],
            input: input
        )) { error in
            XCTAssertEqual(error as? LocalClassificationError, .duplicateCandidateID)
        }

        XCTAssertThrowsError(try DateAssignmentGrounding.check(
            assignments: [(mentionID: "d1", roleRaw: "salesStart", evidenceLineIDs: ["L2"])],
            input: input
        )) { error in
            XCTAssertEqual(error as? LocalClassificationError, .unsupportedEvidence)
        }

        let grounded = try DateAssignmentGrounding.check(
            assignments: [(mentionID: "d1", roleRaw: "paymentEnd", evidenceLineIDs: ["L1"])],
            input: input
        )
        XCTAssertEqual(grounded.proposals, [
            DateRoleProposal(mentionID: "d1", role: .paymentEnd, evidenceLineIDs: ["L1"]),
        ])
        XCTAssertEqual(grounded.unclassified, ["d2"])
    }

    func testValidatorDoesNotInventAYearAndParsesExplicitTokyoInstants() throws {
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let undated = DateClassificationRequest(
            snapshotID: "s",
            eventID: "e",
            blockID: "b",
            headingPath: [],
            lines: [EvidenceLine(id: "L1", text: "10月18日23:59 まで")],
            mentions: [DateMention(id: "d1", rawText: "10月18日23:59", lineIDs: ["L1"])]
        )
        let undatedProposal = proposal(input: undated, role: .paymentEnd)
        let undatedRows = ExtractedFieldValidator.validate(undatedProposal, input: undated, timeZone: tokyo)
        XCTAssertEqual(undatedRows.count, 1)
        XCTAssertNil(undatedRows[0].absoluteDate)
        XCTAssertNil(undatedRows[0].rejection)
        XCTAssertTrue(undatedRows[0].needsReview)

        let dated = DateClassificationRequest(
            snapshotID: "s",
            eventID: "e",
            blockID: "b",
            headingPath: [],
            lines: [EvidenceLine(id: "L1", text: "2026年9月22日21:00 開始")],
            mentions: [DateMention(id: "d1", rawText: "2026年9月22日21:00", lineIDs: ["L1"])]
        )
        let datedRows = ExtractedFieldValidator.validate(proposal(input: dated, role: .salesStart), input: dated, timeZone: tokyo)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let expected = try XCTUnwrap(formatter.date(from: "2026-09-22T21:00:00+09:00"))
        XCTAssertEqual(datedRows[0].absoluteDate, expected)
        XCTAssertTrue(datedRows[0].needsReview)
        XCTAssertNil(datedRows[0].rejection)

        let unknownRows = ExtractedFieldValidator.validate(proposal(input: dated, role: .unknown), input: dated, timeZone: tokyo)
        XCTAssertNil(unknownRows[0].absoluteDate)
        XCTAssertNil(unknownRows[0].rejection)
        XCTAssertEqual(unknownRows[0].role, .unknown)
    }

    func testSourceBlockBuilderKeepsHeadingSplitsMentionsAndDoesNotInventYears() throws {
        let headed = SourceBlockBuilder.requests(
            eventID: "event",
            snapshotID: "snap",
            sourceText: "プレイガイド先行\n\n2026年9月22日21:00 開始\n"
        )
        XCTAssertEqual(headed.count, 1)
        XCTAssertEqual(headed[0].headingPath, ["プレイガイド先行"])
        XCTAssertEqual(headed[0].blockID, "snap-1")
        XCTAssertEqual(headed[0].mentions.map(\.rawText), ["2026年9月22日21:00"])
        try headed[0].validate()

        var lines = ["販売期間", ""]
        let dates = (1...9).map { "2026年1月\($0)日10:00" }
        lines.append(contentsOf: dates)
        let split = SourceBlockBuilder.requests(
            eventID: "event",
            snapshotID: "snap",
            sourceText: lines.joined(separator: "\n")
        )
        XCTAssertEqual(split.count, 2)
        XCTAssertEqual(split.map(\.headingPath), [["販売期間"], ["販売期間"]])
        XCTAssertEqual(split.map { $0.mentions.count }, [8, 1])
        XCTAssertEqual(split.map(\.blockID), ["snap-1", "snap-2"])
        let raws = split.flatMap { $0.mentions.map(\.rawText) }
        XCTAssertEqual(raws, dates)
        for request in split {
            try request.validate()
            for mention in request.mentions {
                XCTAssertTrue(lines.joined(separator: "\n").contains(mention.rawText))
                XCTAssertFalse(mention.rawText.contains("2025"))
            }
        }

        let undated = SourceBlockBuilder.requests(
            eventID: "event",
            snapshotID: "snap",
            sourceText: "当落\n\n10月18日23:59"
        )
        XCTAssertEqual(undated.count, 1)
        XCTAssertEqual(undated[0].headingPath, ["当落"])
        XCTAssertEqual(undated[0].mentions.map(\.rawText), ["10月18日23:59"])
        XCTAssertFalse(undated[0].mentions[0].rawText.contains("年"))
    }

    func testExtractionCacheKeyIsStableUntilProviderChanges() {
        let first = ExtractionCacheKey.hex(
            snapshotHash: "snap",
            blockHash: "block",
            scopeFingerprint: "scope",
            providerID: OnDeviceExtraction.providerID,
            promptVersion: OnDeviceExtraction.promptVersion,
            schemaVersion: OnDeviceExtraction.schemaVersion,
            language: "ja",
            engineCompatibilityEpoch: OnDeviceExtraction.engineCompatibilityEpoch
        )
        let second = ExtractionCacheKey.hex(
            snapshotHash: "snap",
            blockHash: "block",
            scopeFingerprint: "scope",
            providerID: OnDeviceExtraction.providerID,
            promptVersion: OnDeviceExtraction.promptVersion,
            schemaVersion: OnDeviceExtraction.schemaVersion,
            language: "ja",
            engineCompatibilityEpoch: OnDeviceExtraction.engineCompatibilityEpoch
        )
        let otherProvider = ExtractionCacheKey.hex(
            snapshotHash: "snap",
            blockHash: "block",
            scopeFingerprint: "scope",
            providerID: "other",
            promptVersion: OnDeviceExtraction.promptVersion,
            schemaVersion: OnDeviceExtraction.schemaVersion,
            language: "ja",
            engineCompatibilityEpoch: OnDeviceExtraction.engineCompatibilityEpoch
        )
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, "d8c347c8c8f501784037eac9e816431fe7b3ccb93e9654ed57a699213444072b")
        XCTAssertNotEqual(first, otherProvider)
    }

    func testSchedulerRunsRequestsSerially() async throws {
        let recorder = RecordingDateClassifier()
        let scheduler = ExtractionRequestScheduler(classifier: recorder)
        let first = request(mentionCount: 1, blockID: "b1")
        let second = request(mentionCount: 1, blockID: "b2")
        async let left = scheduler.classify(first)
        async let right = scheduler.classify(second)
        let results = try await [left, right]
        XCTAssertEqual(Set(results.map(\.blockID)), ["b1", "b2"])
        XCTAssertEqual(recorder.maxActive, 1)
    }

    private func request(mentionCount: Int, blockID: String = "b") -> DateClassificationRequest {
        let raws = (1...mentionCount).map { "2026年1月\($0)日10:00" }
        let lines = raws.enumerated().map { EvidenceLine(id: "L\($0.offset + 1)", text: $0.element) }
        let mentions = raws.enumerated().map {
            DateMention(id: "d\($0.offset + 1)", rawText: $0.element, lineIDs: ["L\($0.offset + 1)"])
        }
        return DateClassificationRequest(
            snapshotID: "s",
            eventID: "e",
            blockID: blockID,
            headingPath: [],
            lines: lines,
            mentions: mentions
        )
    }

    private func proposal(input: DateClassificationRequest, role: TicketDateRole) -> DateClassificationProposal {
        DateClassificationProposal(
            snapshotID: input.snapshotID,
            eventID: input.eventID,
            blockID: input.blockID,
            generatedAt: Date(timeIntervalSince1970: 0),
            providerID: OnDeviceExtraction.providerID,
            assignments: [
                DateRoleProposal(
                    mentionID: input.mentions[0].id,
                    role: role,
                    evidenceLineIDs: input.mentions[0].lineIDs
                ),
            ],
            unclassifiedMentionIDs: [],
            requiresSemanticReview: true
        )
    }
}

private final class RecordingDateClassifier: DateClassifying, Sendable {
    private struct State {
        var active = 0
        var maxActive = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var maxActive: Int {
        state.withLock { $0.maxActive }
    }

    func classify(_ input: DateClassificationRequest) async throws -> DateClassificationProposal {
        state.withLock { value in
            value.active += 1
            value.maxActive = max(value.maxActive, value.active)
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        state.withLock { value in
            value.active -= 1
        }
        return DateClassificationProposal(
            snapshotID: input.snapshotID,
            eventID: input.eventID,
            blockID: input.blockID,
            generatedAt: Date(timeIntervalSince1970: 0),
            providerID: OnDeviceExtraction.providerID,
            assignments: [],
            unclassifiedMentionIDs: input.mentions.map(\.id),
            requiresSemanticReview: true
        )
    }
}
