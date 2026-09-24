import Foundation

/// Stable card kinds across the four detail tabs, per DESIGN.md 四.4 / 五.
public enum CardType: String, Codable, Hashable, Sendable {
    // Overview – assistant-generated summary, singleton per event
    case assistantSummary
    // Overview
    case timeAndVenue
    case performers
    case pricing
    case admission
    // Tickets (one card per round, keyed by round entity ID)
    case ticketRound
    case streamOffer
    // Tickets (one card per goods-bundled ticket benefit, keyed by benefit entity ID)
    case ticketBenefit
    // Seating
    case eventSeatingMap
    case venueGenericSeatingMap
    // Goods (one card per campaign, keyed by campaign entity ID)
    case goodsCampaign

    /// Fields the card's view actually reads via `CardConfiguration.shows(_:)`,
    /// ordered as `CardField.allCases`. This must mirror the `shows(_:)` calls
    /// in the corresponding card view exactly — update it whenever a view adds
    /// or drops a field check, or the settings UI will offer dead toggles.
    public var supportedFields: [CardField] {
        switch self {
        case .assistantSummary, .performers, .eventSeatingMap, .venueGenericSeatingMap:
            return []
        case .timeAndVenue:
            return [.time, .place]
        case .pricing:
            return [.price]
        case .admission:
            return [.eligibility]
        case .ticketRound:
            return [.time, .price, .eligibility, .source]
        case .streamOffer:
            return [.time, .place, .price, .eligibility, .source]
        case .ticketBenefit:
            return [.time, .place, .price, .source]
        case .goodsCampaign:
            return [.time, .place, .price, .eligibility, .source]
        }
    }
}

public enum CardDensity: String, Codable, Hashable, Sendable {
    case compact
    case detailed
}

/// Stable field identifiers stored with card preferences. The marker lets an
/// explicitly empty selection remain distinct from the legacy/default empty
/// set, which means "show every field".
public enum CardField: String, CaseIterable, Sendable {
    case time = "时间"
    case place = "地点"
    case price = "费用"
    case eligibility = "资格"
    case source = "来源"

    public static let configuredMarker = "__configured_fields__"
}

/// User override for a card, keyed by `(cardType, entityID)` — never by array
/// index, so a re-published bundle cannot silently reorder or reset a user's
/// layout. `entityID` is the stable record ID the card represents, or
/// `CardConfiguration.globalEntityID` for tab-level singleton cards
/// (e.g. `timeAndVenue`) applied as a cross-event default.
public struct CardConfiguration: Codable, Hashable, Sendable {
    public static let globalEntityID = "*global*"

    public var cardType: CardType
    public var entityID: String
    public var eventID: String?
    public var isHidden: Bool
    public var isPinned: Bool
    public var order: Int
    public var density: CardDensity
    public var changeReminderEnabled: Bool
    public var visibleFields: Set<String>

    public init(
        cardType: CardType,
        entityID: String,
        eventID: String? = nil,
        isHidden: Bool = false,
        isPinned: Bool = false,
        order: Int = 0,
        density: CardDensity = .detailed,
        changeReminderEnabled: Bool = false,
        visibleFields: Set<String> = []
    ) {
        self.cardType = cardType
        self.entityID = entityID
        self.eventID = eventID
        self.isHidden = isHidden
        self.isPinned = isPinned
        self.order = order
        self.density = density
        self.changeReminderEnabled = changeReminderEnabled
        self.visibleFields = visibleFields
    }

    public struct Key: Hashable, Sendable {
        public let cardType: CardType
        public let entityID: String
        public let eventID: String?
        public init(cardType: CardType, entityID: String, eventID: String? = nil) {
            self.cardType = cardType
            self.entityID = entityID
            self.eventID = eventID
        }
    }

    public var key: Key { Key(cardType: cardType, entityID: entityID, eventID: eventID) }

    public func shows(_ field: CardField) -> Bool {
        if !visibleFields.contains(CardField.configuredMarker) { return true }
        return visibleFields.contains(field.rawValue)
    }

    /// Applies one settings toggle. A marker-less set still means every field
    /// is visible, so the first write materializes this card's supported
    /// fields as on. Existing strings — including unsupported or unknown
    /// historical keys — are kept; this never replaces the set.
    public mutating func setShows(_ field: CardField, enabled: Bool) {
        if !visibleFields.contains(CardField.configuredMarker) {
            visibleFields.formUnion(cardType.supportedFields.map(\.rawValue))
            visibleFields.insert(CardField.configuredMarker)
        }
        if enabled {
            visibleFields.insert(field.rawValue)
        } else {
            visibleFields.remove(field.rawValue)
        }
    }
}
