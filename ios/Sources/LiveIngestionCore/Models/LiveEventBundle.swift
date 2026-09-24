import Foundation

/// The top-level JSON document published by the server for one event version.
/// Decoded directly by `LiveRepository` per API_CONTRACT.md.
public struct LiveEventBundle: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let revision: Int?
    public let publishedAt: Date
    public let event: LiveEvent
    public let stops: [LiveStop]
    public let performances: [Performance]
    public let ticketTiers: [TicketTier]
    public let ticketRounds: [TicketRound]
    public let ticketOffers: [TicketOffer]
    public let goodsCampaigns: [GoodsCampaign]
    public let mediaAssets: [MediaAsset]
    public let notices: [Notice]
    public let evidence: [SourceEvidence]
    public let editions: [Edition]
    public let streamOffers: [StreamOffer]
    public let products: [Product]
    public let goodsSessions: [GoodsSession]
    /// Goods bundled with specific ticket tiers (グッズ付きチケット特典).
    public let ticketBenefits: [TicketBenefit]
    public let sourceHealth: SourceHealthState
    /// Plain-text rendering of the official detail page, including inline
    /// annotations for links and images (see `OfficialEventScraper.HTML.linkedText`).
    /// Kept verbatim so an on-device assistant can summarise the page without
    /// re-fetching or re-parsing HTML.
    public let sourceText: String?

    public init(
        schemaVersion: Int,
        revision: Int? = nil,
        publishedAt: Date,
        event: LiveEvent,
        stops: [LiveStop],
        performances: [Performance],
        ticketTiers: [TicketTier],
        ticketRounds: [TicketRound],
        ticketOffers: [TicketOffer],
        goodsCampaigns: [GoodsCampaign],
        mediaAssets: [MediaAsset],
        notices: [Notice],
        evidence: [SourceEvidence],
        editions: [Edition] = [],
        streamOffers: [StreamOffer] = [],
        products: [Product] = [],
        goodsSessions: [GoodsSession] = [],
        ticketBenefits: [TicketBenefit] = [],
        sourceHealth: SourceHealthState = .healthy,
        sourceText: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.publishedAt = publishedAt
        self.event = event
        self.stops = stops
        self.performances = performances
        self.ticketTiers = ticketTiers
        self.ticketRounds = ticketRounds
        self.ticketOffers = ticketOffers
        self.goodsCampaigns = goodsCampaigns
        self.mediaAssets = mediaAssets
        self.notices = notices
        self.evidence = evidence
        self.editions = editions
        self.streamOffers = streamOffers
        self.products = products
        self.goodsSessions = goodsSessions
        self.ticketBenefits = ticketBenefits
        self.sourceHealth = sourceHealth
        self.sourceText = sourceText
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, revision, contentRevision, publishedAt, event, stops, performances
        case ticketTiers, ticketRounds, ticketOffers, goodsCampaigns, mediaAssets, media
        case notices, evidence, editions, streamOffers, products, goodsSessions, ticketBenefits, sourceHealth
        case sourceText
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard schemaVersion <= 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: c,
                debugDescription: "schemaVersion \(schemaVersion) is not readable by this client"
            )
        }
        revision = try c.decodeIfPresent(Int.self, forKey: .revision)
            ?? c.decodeIfPresent(Int.self, forKey: .contentRevision)
        publishedAt = try c.decodeIfPresent(Date.self, forKey: .publishedAt) ?? .distantPast
        event = try c.decode(LiveEvent.self, forKey: .event)
        stops = try c.decodeIfPresent([LiveStop].self, forKey: .stops) ?? []
        performances = try c.decodeIfPresent([Performance].self, forKey: .performances) ?? []
        ticketTiers = try c.decodeIfPresent([TicketTier].self, forKey: .ticketTiers) ?? []
        ticketRounds = try c.decodeIfPresent([TicketRound].self, forKey: .ticketRounds) ?? []
        ticketOffers = try c.decodeIfPresent([TicketOffer].self, forKey: .ticketOffers) ?? []
        goodsCampaigns = try c.decodeIfPresent([GoodsCampaign].self, forKey: .goodsCampaigns) ?? []
        mediaAssets = try c.decodeIfPresent([MediaAsset].self, forKey: .mediaAssets)
            ?? c.decodeIfPresent([MediaAsset].self, forKey: .media) ?? []
        notices = try c.decodeIfPresent([Notice].self, forKey: .notices) ?? []
        evidence = try c.decodeIfPresent([SourceEvidence].self, forKey: .evidence) ?? []
        editions = try c.decodeIfPresent([Edition].self, forKey: .editions) ?? []
        streamOffers = try c.decodeIfPresent([StreamOffer].self, forKey: .streamOffers) ?? []
        products = try c.decodeIfPresent([Product].self, forKey: .products) ?? []
        goodsSessions = try c.decodeIfPresent([GoodsSession].self, forKey: .goodsSessions) ?? []
        ticketBenefits = try c.decodeIfPresent([TicketBenefit].self, forKey: .ticketBenefits) ?? []
        sourceHealth = try c.decodeIfPresent(SourceHealthState.self, forKey: .sourceHealth) ?? .healthy
        sourceText = try c.decodeIfPresent(String.self, forKey: .sourceText)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encodeIfPresent(revision, forKey: .revision)
        try c.encode(publishedAt, forKey: .publishedAt)
        try c.encode(event, forKey: .event)
        try c.encode(stops, forKey: .stops)
        try c.encode(performances, forKey: .performances)
        try c.encode(ticketTiers, forKey: .ticketTiers)
        try c.encode(ticketRounds, forKey: .ticketRounds)
        try c.encode(ticketOffers, forKey: .ticketOffers)
        try c.encode(goodsCampaigns, forKey: .goodsCampaigns)
        try c.encode(mediaAssets, forKey: .mediaAssets)
        try c.encode(notices, forKey: .notices)
        try c.encode(evidence, forKey: .evidence)
        try c.encode(editions, forKey: .editions)
        try c.encode(streamOffers, forKey: .streamOffers)
        try c.encode(products, forKey: .products)
        try c.encode(goodsSessions, forKey: .goodsSessions)
        try c.encode(ticketBenefits, forKey: .ticketBenefits)
        try c.encode(sourceHealth, forKey: .sourceHealth)
        try c.encodeIfPresent(sourceText, forKey: .sourceText)
    }
}

extension LiveEventBundle {
    public func replacingSourceHealth(_ value: SourceHealthState) -> LiveEventBundle {
        LiveEventBundle(schemaVersion: schemaVersion, revision: revision, publishedAt: publishedAt, event: event, stops: stops, performances: performances, ticketTiers: ticketTiers, ticketRounds: ticketRounds, ticketOffers: ticketOffers, goodsCampaigns: goodsCampaigns, mediaAssets: mediaAssets, notices: notices, evidence: evidence, editions: editions, streamOffers: streamOffers, products: products, goodsSessions: goodsSessions, ticketBenefits: ticketBenefits, sourceHealth: value, sourceText: sourceText)
    }

    /// Decoder configured for the API_CONTRACT.md wire format: ISO-8601 dates
    /// with a timezone offset, `null` stays `nil` (never midnight).
    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: raw) {
                return date
            }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Invalid ISO-8601 date: \(raw)"
            )
        }
        return decoder
    }

    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            try container.encode(formatter.string(from: date))
        }
        return encoder
    }
}

/// v2 fields frozen in `server/src/contracts.ts`. The v1 `LiveEventBundle` decoder rejects `schemaVersion` above 1.
public struct SharedContractV2Header: Decodable, Equatable, Sendable {
    public struct FieldAbsence: Decodable, Equatable, Sendable {
        public let recordID: String
        public let field: String
        public let absence: String
    }

    public struct PerformanceClock: Decodable, Equatable, Sendable {
        public let id: String
        public let localTime: String?
    }

    public let schemaVersion: Int
    public let sourceCheckedAt: Date
    public let revision: Int
    public let fieldAbsences: [FieldAbsence]
    public let performances: [PerformanceClock]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == 2 else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "SharedContractV2Header requires schemaVersion 2"
            )
        }
        sourceCheckedAt = try container.decode(Date.self, forKey: .sourceCheckedAt)
        revision = try container.decode(Int.self, forKey: .revision)
        fieldAbsences = try container.decode([FieldAbsence].self, forKey: .fieldAbsences)
        performances = try container.decode([PerformanceClock].self, forKey: .performances)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, sourceCheckedAt, revision, fieldAbsences, performances
    }
}
