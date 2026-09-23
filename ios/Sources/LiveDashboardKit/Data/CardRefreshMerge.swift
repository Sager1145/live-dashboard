import Foundation

public enum CardRefreshError: Error, LocalizedError, Sendable {
    case unavailable
    public var errorDescription: String? {
        "官网尚未提供可重新整理的这张卡片资料，已保留原内容。可打开官方公演页面核对。"
    }
}

/// Apply only the selected card's freshly parsed fields, preserving all other cards.
enum CardRefreshMerge {
    static func apply(_ fresh: LiveEventBundle, to saved: LiveEventBundle, cardType: CardType, entityID: String) throws -> LiveEventBundle {
        let evidence = fresh.evidence.filter { $0.verifiedAt >= fresh.publishedAt }
        var selectedEvidence: [SourceEvidence] = []
        var performances = saved.performances
        var tiers = saved.ticketTiers
        var rounds = saved.ticketRounds
        var streams = saved.streamOffers
        var goods = saved.goodsCampaigns
        var media = saved.mediaAssets
        switch cardType {
        case .timeAndVenue, .performers:
            let fields = cardType == .timeAndVenue ? ["performance.schedule", "performance.venueName"] : ["performance.performers"]
            selectedEvidence = evidence.filter { fields.contains($0.field) && ($0.recordID == saved.event.id || $0.recordID == entityID) }
            guard let index = performances.firstIndex(where: { $0.id == entityID }),
                  let updated = fresh.performances.first(where: { $0.id == entityID }), !selectedEvidence.isEmpty else { throw CardRefreshError.unavailable }
            let old = performances[index]
            let updateSchedule = selectedEvidence.contains { $0.field == "performance.schedule" }
            let updateVenue = selectedEvidence.contains { $0.field == "performance.venueName" }
            performances[index] = Performance(id: old.id, eventID: old.eventID, stopID: old.stopID,
                dayLabel: updateSchedule ? updated.dayLabel : old.dayLabel, subtitle: old.subtitle,
                localDate: updateSchedule ? updated.localDate : old.localDate,
                doorsAt: updateSchedule ? updated.doorsAt : old.doorsAt, startAt: updateSchedule ? updated.startAt : old.startAt,
                venueName: updateVenue ? updated.venueName : old.venueName, venueCity: updateVenue ? updated.venueCity : old.venueCity,
                performers: cardType == .performers ? updated.performers : old.performers, order: old.order,
                editionID: old.editionID, rawDate: updateSchedule ? updated.rawDate : old.rawDate,
                precision: (updateSchedule ? updated.precision : old.precision) ?? .unknown,
                timeZone: updateSchedule ? updated.timeZone : old.timeZone)
        case .pricing:
            selectedEvidence = evidence.filter { $0.field == "ticket.price" }
            let ids = Set(selectedEvidence.map(\.recordID))
            guard !ids.isEmpty else { throw CardRefreshError.unavailable }
            for tier in fresh.ticketTiers where ids.contains(tier.id) {
                tiers.removeAll { $0.id == tier.id }; tiers.append(tier)
            }
        case .ticketRound:
            selectedEvidence = evidence.filter { $0.recordID == entityID && $0.field.hasPrefix("ticket.") }
            guard let value = fresh.ticketRounds.first(where: { $0.id == entityID }), !selectedEvidence.isEmpty else { throw CardRefreshError.unavailable }
            rounds.removeAll { $0.id == entityID }; rounds.append(value)
        case .streamOffer:
            selectedEvidence = evidence.filter { $0.recordID == entityID && $0.field.hasPrefix("stream.") }
            guard let value = fresh.streamOffers.first(where: { $0.id == entityID }), !selectedEvidence.isEmpty else { throw CardRefreshError.unavailable }
            streams.removeAll { $0.id == entityID }; streams.append(value)
        case .goodsCampaign:
            selectedEvidence = evidence.filter { $0.recordID == entityID && $0.field.hasPrefix("goods.") }
            guard let value = fresh.goodsCampaigns.first(where: { $0.id == entityID }), !selectedEvidence.isEmpty else { throw CardRefreshError.unavailable }
            goods.removeAll { $0.id == entityID }; goods.append(value)
            let assetIDs = Set(value.mediaAssetIDs)
            let refreshedMedia = fresh.mediaAssets.filter { assetIDs.contains($0.id) }
            for asset in refreshedMedia {
                media.removeAll { $0.id == asset.id }; media.append(asset)
            }
            selectedEvidence += evidence.filter { assetIDs.contains($0.recordID) && $0.field.hasPrefix("media.") }
        case .eventSeatingMap, .venueGenericSeatingMap:
            selectedEvidence = evidence.filter { $0.recordID == entityID && $0.field.hasPrefix("media.") }
            guard let value = fresh.mediaAssets.first(where: { $0.id == entityID }), !selectedEvidence.isEmpty else { throw CardRefreshError.unavailable }
            media.removeAll { $0.id == entityID }; media.append(value)
        case .admission:
            selectedEvidence = evidence.filter { $0.field == "event.admission" }
            guard !selectedEvidence.isEmpty else { throw CardRefreshError.unavailable }
        case .assistantSummary:
            throw CardRefreshError.unavailable
        }
        let replaced = Set(selectedEvidence.map { "\($0.recordID)|\($0.field)" })
        let mergedEvidence = saved.evidence.filter { !replaced.contains("\($0.recordID)|\($0.field)") } + selectedEvidence
        return LiveEventBundle(schemaVersion: saved.schemaVersion, revision: saved.revision, publishedAt: fresh.publishedAt,
            event: saved.event, stops: saved.stops, performances: performances, ticketTiers: tiers,
            ticketRounds: rounds, ticketOffers: saved.ticketOffers, goodsCampaigns: goods, mediaAssets: media,
            notices: saved.notices, evidence: mergedEvidence, editions: saved.editions, streamOffers: streams,
            products: saved.products, goodsSessions: saved.goodsSessions, sourceHealth: saved.sourceHealth,
            sourceText: fresh.sourceText ?? saved.sourceText)
    }
}
