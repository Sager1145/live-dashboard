import Foundation

/// One source-language segment queued for on-device translation, keyed by a
/// caller-chosen stable `id` (e.g. `"\(eventID)|\(cardType)|\(entityID)|title"`)
/// so results can be matched back to the field they came from.
public struct TranslationRequestItem: Sendable, Hashable {
    public let id: String
    public let text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

/// The translated counterpart of a `TranslationRequestItem`, matched by `id`.
public struct TranslationResultItem: Sendable, Hashable {
    public let id: String
    public let text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

/// Whether a given source/target language pair can be translated on this
/// device right now, per `LanguageAvailability`.
public enum TranslationAvailability: Sendable {
    case installed
    case needsDownload
    case unsupported
}

/// Abstraction over Apple's `Translation` framework so the rest of the app
/// (and tests, which cannot exercise `Translation` in the simulator) never
/// call the framework directly.
public protocol TranslationProviding: Sendable {
    func availability(from source: Locale.Language, to target: Locale.Language) async -> TranslationAvailability
}
