import Foundation
#if canImport(Translation)
import Translation
import LiveIngestionCore
#endif

/// Real `Translation` framework-backed availability check. Never call
/// `Translation` APIs outside this file (and `TranslationStore`'s
/// `.translationTask` handler) — the framework does not work in the iOS
/// Simulator, so all other code must go through `TranslationProviding`.
public struct AppleTranslationProvider: TranslationProviding {
    public init() {}

    public func availability(from source: Locale.Language, to target: Locale.Language) async -> TranslationAvailability {
        #if canImport(Translation)
        let status = await LanguageAvailability().status(from: source, to: target)
        switch status {
        case .installed: return .installed
        case .supported: return .needsDownload
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
        #else
        return .unsupported
        #endif
    }
}

/// Preview/test double: always reports the pair as installed so UI can be
/// exercised without the real framework (which does not run in the
/// Simulator).
public struct StubTranslationProvider: TranslationProviding {
    public var result: TranslationAvailability

    public init(result: TranslationAvailability = .installed) {
        self.result = result
    }

    public func availability(from source: Locale.Language, to target: Locale.Language) async -> TranslationAvailability {
        result
    }
}
