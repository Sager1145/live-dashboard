import AppIntents
import LiveDashboardKit

struct LiveEventEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { TypeDisplayRepresentation(name: "演出") }
    static var defaultQuery: LiveEventEntityQuery { LiveEventEntityQuery() }

    var id: String
    var title: String
    var groups: [String]

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }

    /// Case-insensitive containment. Every match is kept; nothing is ranked down to one title.
    func matches(_ needle: String) -> Bool {
        if title.localizedCaseInsensitiveContains(needle) { return true }
        return groups.contains { $0.localizedCaseInsensitiveContains(needle) }
    }
}

struct LiveEventEntityQuery: EntityStringQuery {
    func entities(for identifiers: [LiveEventEntity.ID]) async throws -> [LiveEventEntity] {
        let wanted = Set(identifiers)
        return await all().filter { wanted.contains($0.id) }
    }

    func suggestedEntities() async throws -> [LiveEventEntity] {
        await all()
    }

    func entities(matching string: String) async throws -> [LiveEventEntity] {
        Self.matching(await all(), string: string)
    }

    private func all() async -> [LiveEventEntity] {
        await LiveActionCenter.shared.savedBundles().map { bundle in
            LiveEventEntity(id: bundle.event.id, title: bundle.event.officialTitle, groups: bundle.event.groups)
        }
    }

    fileprivate static func matching<Entity>(_ entities: [Entity], string: String) -> [Entity] where Entity: CatalogMatchable {
        let needle = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return entities }
        return entities.filter { $0.matches(needle) }
    }
}

struct PerformanceEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { TypeDisplayRepresentation(name: "场次") }
    static var defaultQuery: PerformanceEntityQuery { PerformanceEntityQuery() }

    var id: String
    var eventID: String
    var officialTitle: String
    var dayLabel: String
    var localDate: String?
    var venueName: String
    var venueCity: String
    var subtitle: String?

    var displayRepresentation: DisplayRepresentation {
        let date = (localDate?.isEmpty == false ? localDate! : "日期未保存")
        let venue = venueName.isEmpty ? "场地未保存" : venueName
        return DisplayRepresentation(title: "\(officialTitle)", subtitle: "\(dayLabel) \(date) \(venue)")
    }

    func matches(_ needle: String) -> Bool {
        let fields = [officialTitle, dayLabel, localDate ?? "", venueName, venueCity, subtitle ?? ""]
        return fields.contains { $0.localizedCaseInsensitiveContains(needle) }
    }
}

struct PerformanceEntityQuery: EntityStringQuery {
    func entities(for identifiers: [PerformanceEntity.ID]) async throws -> [PerformanceEntity] {
        let wanted = Set(identifiers)
        return await all().filter { wanted.contains($0.id) }
    }

    func suggestedEntities() async throws -> [PerformanceEntity] {
        await all()
    }

    func entities(matching string: String) async throws -> [PerformanceEntity] {
        // These intents have no parent event parameter, so the query cannot scope and searches every saved bundle.
        LiveEventEntityQuery.matching(await all(), string: string)
    }

    private func all() async -> [PerformanceEntity] {
        await LiveActionCenter.shared.savedBundles().flatMap { bundle in
            bundle.performances.map { performance in
                PerformanceEntity(
                    id: performance.id,
                    eventID: bundle.event.id,
                    officialTitle: bundle.event.officialTitle,
                    dayLabel: performance.dayLabel,
                    localDate: performance.localDate,
                    venueName: performance.venueName,
                    venueCity: performance.venueCity,
                    subtitle: performance.subtitle
                )
            }
        }
    }
}

struct TicketRoundEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { TypeDisplayRepresentation(name: "售票轮次") }
    static var defaultQuery: TicketRoundEntityQuery { TicketRoundEntityQuery() }

    var id: String
    var eventID: String
    var officialName: String
    var eventTitle: String
    var groups: [String]

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(officialName)", subtitle: "\(eventTitle)")
    }

    func matches(_ needle: String) -> Bool {
        if officialName.localizedCaseInsensitiveContains(needle) || eventTitle.localizedCaseInsensitiveContains(needle) {
            return true
        }
        return groups.contains { $0.localizedCaseInsensitiveContains(needle) }
    }
}

struct TicketRoundEntityQuery: EntityStringQuery {
    func entities(for identifiers: [TicketRoundEntity.ID]) async throws -> [TicketRoundEntity] {
        let wanted = Set(identifiers)
        return await all().filter { wanted.contains($0.id) }
    }

    func suggestedEntities() async throws -> [TicketRoundEntity] {
        await all()
    }

    func entities(matching string: String) async throws -> [TicketRoundEntity] {
        LiveEventEntityQuery.matching(await all(), string: string)
    }

    private func all() async -> [TicketRoundEntity] {
        await LiveActionCenter.shared.savedBundles().flatMap { bundle in
            bundle.ticketRounds.map { round in
                TicketRoundEntity(
                    id: round.id,
                    eventID: bundle.event.id,
                    officialName: round.officialName,
                    eventTitle: bundle.event.officialTitle,
                    groups: bundle.event.groups
                )
            }
        }
    }
}

protocol CatalogMatchable {
    func matches(_ needle: String) -> Bool
}

extension LiveEventEntity: CatalogMatchable {}
extension PerformanceEntity: CatalogMatchable {}
extension TicketRoundEntity: CatalogMatchable {}
