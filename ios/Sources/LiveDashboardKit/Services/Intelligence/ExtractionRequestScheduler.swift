import Foundation

protocol DateClassifying: Sendable {
    func classify(_ input: DateClassificationRequest) async throws -> DateClassificationProposal
}

actor ExtractionRequestScheduler {
    private let classifier: any DateClassifying
    private var inFlight: [String: Task<DateClassificationProposal, Error>] = [:]
    private var last: Task<Void, Never>?

    init(classifier: any DateClassifying) {
        self.classifier = classifier
    }

    func classify(_ input: DateClassificationRequest) async throws -> DateClassificationProposal {
        try Task.checkCancellation()
        let key = [input.snapshotID, input.blockID, OnDeviceExtraction.promptVersion].joined(separator: "\n")
        if let existing = inFlight[key] {
            return try await waitForClassification(existing)
        }

        let previous = last
        let classifier = self.classifier
        // Unstructured so later requests can await this one after the caller returns.
        // Still tied to the caller: cancellation must reach the classifier before a proposal is returned.
        let task = Task<DateClassificationProposal, Error> {
            await previous?.value
            try Task.checkCancellation()
            return try await classifier.classify(input)
        }
        inFlight[key] = task
        last = Task<Void, Never> {
            _ = try? await task.value
        }
        defer { inFlight[key] = nil }
        return try await waitForClassification(task)
    }

    private func waitForClassification(
        _ task: Task<DateClassificationProposal, Error>
    ) async throws -> DateClassificationProposal {
        let value = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        return value
    }
}
