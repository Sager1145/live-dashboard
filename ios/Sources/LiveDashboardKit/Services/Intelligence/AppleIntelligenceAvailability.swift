import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

public enum AppleIntelligenceAvailability: Equatable, Sendable {
    case unsupportedOS
    case unsupportedDevice
    case modelNotReady
    case systemDisabledOrUnavailable
    case unsupportedSourceLanguage
    case ready
}

public enum AppleIntelligenceStatus {
    public static func current() -> AppleIntelligenceAvailability {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            return currentAvailable()
        }
        #endif
        return .unsupportedOS
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    private static func currentAvailable() -> AppleIntelligenceAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            let japanese = Locale(identifier: "ja_JP")
            return SystemLanguageModel.default.supportsLocale(japanese) ? .ready : .unsupportedSourceLanguage
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .unsupportedDevice
            case .modelNotReady:
                return .modelNotReady
            case .appleIntelligenceNotEnabled:
                return .systemDisabledOrUnavailable
            @unknown default:
                return .systemDisabledOrUnavailable
            }
        }
    }
    #endif
}
