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
}

public struct SystemOnDeviceOrganizer: OnDeviceOrganizing {
    public init() {}

    public func organize(bundle: LiveEventBundle, force: Bool) async throws -> OnDeviceOrganizeResult {
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
        if requests.isEmpty {
            return OnDeviceOrganizeResult(blockCount: 0, draftCount: 0)
        }

        let scheduler = ExtractionRequestScheduler(classifier: AppleLocalDateClassifier())
        let store = ExtractionProposalStore()
        let timeZone = TimeZone(identifier: bundle.event.timeZone) ?? TimeZone(secondsFromGMT: 0)!
        var draftCount = 0
        var savedKeys: [String] = []
        do {
            for request in requests {
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
                    draftCount += cached.filter { $0.role != .unknown && $0.rejection == nil }.count
                    continue
                }
                try Task.checkCancellation()
                let proposal = try await scheduler.classify(request)
                let validations = ExtractedFieldValidator.validate(proposal, input: request, timeZone: timeZone)
                let accepted = validations.filter { $0.role != .unknown && $0.rejection == nil }.count
                try Task.checkCancellation()
                try await store.save(proposal, forKey: key)
                savedKeys.append(key)
                draftCount += accepted
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

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
