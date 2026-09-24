import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

public struct AppleContextBudget {
    public static func assertFits(
        instructions: String,
        prompt: String,
        schema: Any? = nil,
        responseAllowance: Int = 512,
        safetyMargin: Int = 256
    ) async throws {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            try await fit(
                instructions: instructions,
                prompt: prompt,
                schema: schema,
                responseAllowance: responseAllowance,
                safetyMargin: safetyMargin
            )
            return
        }
        #endif
        throw LocalClassificationError.unavailable("unsupportedOS")
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    private static func fit(
        instructions: String,
        prompt: String,
        schema: Any?,
        responseAllowance: Int,
        safetyMargin: Int
    ) async throws {
        let model = SystemLanguageModel.default
        let limit = model.contextSize
        let total: Int
        if #available(iOS 26.4, macOS 26.4, *) {
            let instructionTokens = try await model.tokenCount(for: Instructions(instructions))
            let promptTokens = try await model.tokenCount(for: prompt)
            let schemaTokens = try await measuredSchemaTokens(schema, model: model)
            total = instructionTokens + promptTokens + schemaTokens + responseAllowance + safetyMargin
        } else {
            // Scalar upper bound, not a measured token count. Japanese is about one token per character; do not divide by 4.
            let upperBound = instructions.unicodeScalars.count
                + prompt.unicodeScalars.count
                + 800
                + responseAllowance
                + safetyMargin
            total = upperBound
        }
        guard total <= limit else {
            throw LocalClassificationError.overBudget
        }
    }

    @available(iOS 26.4, macOS 26.4, *)
    private static func measuredSchemaTokens(_ schema: Any?, model: SystemLanguageModel) async throws -> Int {
        guard let schema = schema as? GenerationSchema else { return 0 }
        return try await model.tokenCount(for: schema)
    }
    #endif
}
