import Foundation
import LiveIngestionCore

/// Helpers for `CardSettingsView`, built entirely on `UserDataStore`'s
/// existing public API (this file does not touch `UserDataStore.swift`,
/// which is owned elsewhere).
public extension UserDataStore {
    /// The global (cross-event) configuration for a singleton card type,
    /// falling back to a default built from `defaultOrder` when no override
    /// has been saved yet.
    func globalConfiguration(cardType: CardType, defaultOrder: Int) -> CardConfiguration {
        configuration(cardType: cardType, entityID: CardConfiguration.globalEntityID)
            ?? CardConfiguration(cardType: cardType, entityID: CardConfiguration.globalEntityID, order: defaultOrder)
    }

    /// Persists a sequential `order` (0, 1, 2, …) for each card type in
    /// `orderedTypes`, keeping every other field of the existing global
    /// configuration untouched.
    func reorderGlobalConfigurations(_ orderedTypes: [CardType]) {
        for (index, type) in orderedTypes.enumerated() {
            var value = globalConfiguration(cardType: type, defaultOrder: index)
            guard value.order != index else { continue }
            value.order = index
            setConfiguration(value)
        }
    }

    /// Resets every global + per-event override for the given card type back
    /// to defaults.
    func restoreCardTypeDefaults(_ cardType: CardType) {
        removeConfigurations(cardType: cardType)
    }
}
