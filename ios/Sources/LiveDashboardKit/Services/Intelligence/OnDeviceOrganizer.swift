import CryptoKit
import Foundation
import LiveIngestionCore

public struct OnDeviceOrganizeResult: Sendable, Equatable {
    public var blockCount: Int
    public var draftCount: Int

    public init(blockCount: Int, draftCount: Int) {
        self.blockCount = blockCount
        self.draftCount = draftCount
    }
}

public protocol OnDeviceOrganizing: Sendable {
    func organize(bundle: LiveEventBundle, force: Bool) async throws -> OnDeviceOrganizeResult
    func organize(
        bundle: LiveEventBundle,
        force: Bool,
        progress: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> OnDeviceOrganizeResult
}

extension OnDeviceOrganizing {
    public func organize(
        bundle: LiveEventBundle,
        force: Bool,
        progress: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> OnDeviceOrganizeResult {
        try await organize(bundle: bundle, force: force)
    }
}

public struct SystemOnDeviceOrganizer: OnDeviceOrganizing {
    public init() {}

    public func organize(bundle: LiveEventBundle, force: Bool) async throws -> OnDeviceOrganizeResult {
        try await organize(bundle: bundle, force: force, progress: { _ in })
    }

    public func organize(
        bundle: LiveEventBundle,
        force: Bool,
        progress: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> OnDeviceOrganizeResult {
        switch AppleIntelligenceStatus.current() {
        case .ready:
            break
        case .unsupportedOS:
            throw LocalClassificationError.unavailable("系统版本不支持")
        case .unsupportedDevice:
            throw LocalClassificationError.unavailable("设备不支持")
        case .modelNotReady:
            throw LocalClassificationError.unavailable("模型尚未就绪")
        case .systemDisabledOrUnavailable:
            throw LocalClassificationError.unavailable("Apple Intelligence 未开启")
        case .unsupportedSourceLanguage:
            throw LocalClassificationError.unavailable("不支持日文")
        }

        guard let sourceText = bundle.sourceText,
              !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalClassificationError.malformedInput
        }

        let snapshotID = Self.sha256Hex(Data(sourceText.utf8))
        let requests = SourceBlockBuilder.requests(eventID: bundle.event.id, snapshotID: snapshotID, sourceText: sourceText)
        await progress(String(localized: "读取原文 \(sourceText.count) 字，拆成 \(requests.count) 个日期区块", bundle: .kit))
        if requests.isEmpty {
            return OnDeviceOrganizeResult(blockCount: 0, draftCount: 0)
        }

        let scheduler = ExtractionRequestScheduler(classifier: AppleLocalDateClassifier())
        let store = ExtractionProposalStore()
        let timeZone = TimeZone(identifier: bundle.event.timeZone) ?? TimeZone(secondsFromGMT: 0)!
        var draftCount = 0
        var savedKeys: [String] = []
        do {
            for (offset, request) in requests.enumerated() {
                let index = offset + 1
                let heading = Self.progressHeading(request.headingPath)
                let blockHash = Self.sha256Hex(try JSONEncoder().encode(request))
                let key = ExtractionCacheKey.hex(
                    snapshotHash: snapshotID,
                    blockHash: blockHash,
                    scopeFingerprint: request.headingPath.joined(separator: "\n"),
                    providerID: OnDeviceExtraction.providerID,
                    promptVersion: OnDeviceExtraction.promptVersion,
                    schemaVersion: OnDeviceExtraction.schemaVersion,
                    language: "ja",
                    engineCompatibilityEpoch: OnDeviceExtraction.engineCompatibilityEpoch
                )
                if !force, let existing = try await store.proposal(forKey: key) {
                    let cached = ExtractedFieldValidator.validate(existing, input: request, timeZone: timeZone)
                    let tally = Self.validationTally(cached)
                    draftCount += tally.accepted
                    await progress(String(localized: "区块 \(index)/\(requests.count) · \(heading) · 日期 \(request.mentions.count) 个 · 缓存 · 采纳 \(tally.accepted) · 未采纳 \(tally.rejected) · 未知 \(tally.unknown)", bundle: .kit))
                    continue
                }
                try Task.checkCancellation()
                let proposal = try await scheduler.classify(request)
                let validations = ExtractedFieldValidator.validate(proposal, input: request, timeZone: timeZone)
                let tally = Self.validationTally(validations)
                await progress(String(localized: "区块 \(index)/\(requests.count) · \(heading) · 日期 \(request.mentions.count) 个 · 本地模型 · 采纳 \(tally.accepted) · 未采纳 \(tally.rejected) · 未知 \(tally.unknown)", bundle: .kit))
                try Task.checkCancellation()
                try await store.save(proposal, forKey: key)
                savedKeys.append(key)
                draftCount += tally.accepted
                try Task.checkCancellation()
            }
            return OnDeviceOrganizeResult(blockCount: requests.count, draftCount: draftCount)
        } catch is CancellationError {
            for key in savedKeys {
                try? await store.remove(forKey: key)
            }
            throw CancellationError()
        }
    }

    private static func progressHeading(_ headingPath: [String]) -> String {
        let joined = headingPath.joined(separator: " / ")
        if joined.isEmpty { return "无标题" }
        if joined.count > 40 { return String(joined.prefix(40)) + "…" }
        return joined
    }

    private static func validationTally(_ validations: [DateRoleValidation]) -> (accepted: Int, rejected: Int, unknown: Int) {
        var accepted = 0
        var rejected = 0
        var unknown = 0
        for validation in validations {
            if validation.rejection != nil {
                rejected += 1
            } else if validation.role == .unknown {
                unknown += 1
            } else {
                accepted += 1
            }
        }
        return (accepted, rejected, unknown)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
