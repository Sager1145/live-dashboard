import CryptoKit
import Foundation
import LiveIngestionCore

/// Card settings helpers, plus the card-entity half of the identity-remap journal.
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

    /// Stable journal key for one legacy→current list. Order does not matter.
    static func identityRemapFingerprint(_ mappings: [LegacyIdentityMapping]) -> String {
        let lines = mappings.map { "\($0.entityKind.rawValue)\t\($0.legacyID)\t\($0.currentID)" }.sorted().joined(separator: "\n")
        return SHA256.hash(data: Data(lines.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Goods and ticket card entity ids follow those mappings. A global singleton
    /// is not an entity id. Unmatched ids are returned unchanged.
    static func remappedCardEntityID(
        cardType: String,
        entityID: String,
        tickets: [String: String],
        ticketCurrents: Set<String>,
        goods: [String: String],
        goodsCurrents: Set<String>
    ) -> (entityID: String, matched: Bool) {
        if entityID == CardConfiguration.globalEntityID || entityID.isEmpty {
            return (entityID, true)
        }
        switch cardType {
        case CardType.goodsCampaign.rawValue:
            return resolveMappedID(entityID, map: goods, currents: goodsCurrents)
        case CardType.ticketRound.rawValue, CardType.ticketBenefit.rawValue:
            return resolveMappedID(entityID, map: tickets, currents: ticketCurrents)
        default:
            return (entityID, true)
        }
    }

    private static func resolveMappedID(_ id: String, map: [String: String], currents: Set<String>) -> (entityID: String, matched: Bool) {
        if let next = map[id] { return (next, true) }
        if currents.contains(id) { return (id, true) }
        return (id, false)
    }
}
