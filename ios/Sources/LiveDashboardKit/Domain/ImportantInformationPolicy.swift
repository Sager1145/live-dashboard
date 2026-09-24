import Foundation
import LiveIngestionCore

/// Determines default card ordering per detail tab, and how user
/// `CardConfiguration` overrides apply on top of that default. Overrides are
/// always looked up by `(cardType, entityID)` — never by array index — so a
/// republished bundle cannot silently reorder or unhide a user's layout.
public enum ImportantInformationPolicy {
    // MARK: Overview

    /// Default order: AI 整理摘要, 时间与会场, 出演, 票价, 入场条件.
    public static let overviewDefaultOrder: [CardType] = [.assistantSummary, .timeAndVenue, .performers, .pricing, .admission]

    /// Resolves the overview card order/visibility for a given event, using
    /// `CardConfiguration.globalEntityID` as the key since these are
    /// singleton cards per tab (not one per record).
    public static func overviewCards(
        configurations: [CardConfiguration.Key: CardConfiguration]
    ) -> [CardType] {
        let items = overviewDefaultOrder.enumerated().map { index, type in
            (cardType: type, entityID: CardConfiguration.globalEntityID, defaultOrder: index)
        }
        return resolvedOrder(items: items, configurations: configurations).map(\.cardType)
    }

    // MARK: Tickets

    public struct TicketsTabGrouping {
        public let open: [TicketRound]
        public let upcoming: [TicketRound]
        /// Closed rounds, default-collapsed in the UI.
        public let closed: [TicketRound]
    }

    /// Open rounds first, then upcoming, then closed (collapsed). Within
    /// each group, user order/pin overrides (keyed by round ID) apply.
    public static func ticketsTabGrouping(
        rounds: [TicketRound],
        now: Date,
        configurations: [CardConfiguration.Key: CardConfiguration]
    ) -> TicketsTabGrouping {
        var buckets: [TicketRoundComputedStatus: [TicketRound]] = [:]
        for round in rounds {
            let resolution = TicketStatusResolver.resolve(round: round, now: now)
            buckets[resolution.displayStatus, default: []].append(round)
        }

        func ordered(_ rounds: [TicketRound]) -> [TicketRound] {
            let items = rounds.enumerated().map { index, round in
                (cardType: CardType.ticketRound, entityID: round.id, defaultOrder: index)
            }
            let order = resolvedOrder(items: items, configurations: configurations)
            let byID = Dictionary(rounds.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return order.compactMap { byID[$0.entityID] }
        }

        return TicketsTabGrouping(
            open: ordered(buckets[.open] ?? []),
            upcoming: ordered(buckets[.upcoming] ?? []),
            closed: ordered((buckets[.closed] ?? []) + (buckets[.unknown] ?? []))
        )
    }

    public static func orderedTicketRounds(_ rounds: [TicketRound], configurations: [CardConfiguration.Key: CardConfiguration]) -> [TicketRound] {
        let items = rounds.enumerated().map { index, round in
            (cardType: CardType.ticketRound, entityID: round.id, defaultOrder: index)
        }
        let byID = Dictionary(rounds.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return resolvedOrder(items: items, configurations: configurations).compactMap { byID[$0.entityID] }
    }

    // MARK: Seating

    public struct SeatingTabContent {
        public let eventSeatingMaps: [MediaAsset]
        public let genericVenueMaps: [MediaAsset]
        /// True when only a generic venue map exists — the UI must keep
        /// showing the "this is not the actual stage layout" caveat.
        public var showsGenericOnlyCaveat: Bool { eventSeatingMaps.isEmpty && !genericVenueMaps.isEmpty }
    }

    /// Event seating map ordered before the generic venue map.
    public static func seatingTabContent(applicableAssets: [MediaAsset]) -> SeatingTabContent {
        SeatingTabContent(
            eventSeatingMaps: applicableAssets.filter { $0.kind == .eventSeatingMap },
            genericVenueMaps: applicableAssets.filter { $0.kind == .venueGenericSeatingMap }
        )
    }

    public static func orderedSeatingAssets(_ assets: [MediaAsset], configurations: [CardConfiguration.Key: CardConfiguration]) -> [MediaAsset] {
        let items = assets.enumerated().map { index, asset in
            (cardType: asset.kind == .venueGenericSeatingMap ? CardType.venueGenericSeatingMap : .eventSeatingMap, entityID: asset.id, defaultOrder: index)
        }
        let byID = Dictionary(assets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return resolvedOrder(items: items, configurations: configurations).compactMap { byID[$0.entityID] }
    }

    // MARK: Goods

    public struct GoodsTabSections {
        public let venue: [GoodsCampaign]
        public let online: [GoodsCampaign]
        public let other: [GoodsCampaign]
    }

    public static func goodsTabSections(applicableCampaigns: [GoodsCampaign], configurations: [CardConfiguration.Key: CardConfiguration] = [:]) -> GoodsTabSections {
        let items = applicableCampaigns.enumerated().map { index, campaign in
            (cardType: CardType.goodsCampaign, entityID: campaign.id, defaultOrder: index)
        }
        let byID = Dictionary(applicableCampaigns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = resolvedOrder(items: items, configurations: configurations).compactMap { byID[$0.entityID] }
        return GoodsTabSections(
            venue: ordered.filter { $0.channel == .venue },
            online: ordered.filter { $0.channel == .online },
            other: ordered.filter { $0.channel == .unknown }
        )
    }

    public static func orderedStreamOffers(_ offers: [StreamOffer], configurations: [CardConfiguration.Key: CardConfiguration]) -> [StreamOffer] {
        let items = offers.enumerated().map { index, offer in
            (cardType: CardType.streamOffer, entityID: offer.id, defaultOrder: index)
        }
        let byID = Dictionary(offers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return resolvedOrder(items: items, configurations: configurations).compactMap { byID[$0.entityID] }
    }

    // MARK: Pricing

    /// Dashboard/overview "minimum price" only ever considers tiers priced as
    /// the full ticket (`priceKind == .full`) — never upgrade differences,
    /// streaming, or under-20 tiers.
    public static func minimumPriceJPY(tiers: [TicketTier]) -> Int? {
        tiers
            .filter { $0.priceKind == .full }
            .compactMap(\.priceJPY)
            .min()
    }

    // MARK: Shared override engine

    private static func resolvedOrder(
        items: [(cardType: CardType, entityID: String, defaultOrder: Int)],
        configurations: [CardConfiguration.Key: CardConfiguration]
    ) -> [CardConfiguration] {
        // A card-type-wide (global) preference applies to every entity, but it must be
        // rebound to the entity it is being applied to: callers map the result back with
        // `byID[$0.entityID]`, so returning the global row's `*global*` id would silently
        // drop every card. Ties fall back to the caller's default order.
        // A record that appears twice (duplicate IDs from a source page) is shown once.
        var seenKeys = Set<CardConfiguration.Key>()
        let uniqueItems = items.filter { seenKeys.insert(CardConfiguration.Key(cardType: $0.cardType, entityID: $0.entityID)).inserted }
        let resolved = uniqueItems.map { item -> (configuration: CardConfiguration, defaultOrder: Int) in
            let key = CardConfiguration.Key(cardType: item.cardType, entityID: item.entityID)
            let match = configurations[key]
                ?? configurations[.init(cardType: item.cardType, entityID: CardConfiguration.globalEntityID)]
            guard var value = match else {
                return (CardConfiguration(cardType: item.cardType, entityID: item.entityID, order: item.defaultOrder), item.defaultOrder)
            }
            value.entityID = item.entityID
            return (value, item.defaultOrder)
        }
        return resolved
            .filter { !$0.configuration.isHidden }
            .sorted { lhs, rhs in
                if lhs.configuration.isPinned != rhs.configuration.isPinned {
                    return lhs.configuration.isPinned && !rhs.configuration.isPinned
                }
                if lhs.configuration.order != rhs.configuration.order {
                    return lhs.configuration.order < rhs.configuration.order
                }
                return lhs.defaultOrder < rhs.defaultOrder
            }
            .map(\.configuration)
    }
}
