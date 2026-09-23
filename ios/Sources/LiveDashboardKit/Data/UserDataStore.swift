import Foundation
import Observation
import SwiftData

@Model
public final class UserEventRecord {
    @Attribute(.unique) public var eventID: String
    public var isFollowed: Bool
    public var planningToAttend: Bool
    public var selectedPerformanceID: String?

    public init(eventID: String, isFollowed: Bool = false, planningToAttend: Bool = false, selectedPerformanceID: String? = nil) {
        self.eventID = eventID
        self.isFollowed = isFollowed
        self.planningToAttend = planningToAttend
        self.selectedPerformanceID = selectedPerformanceID
    }
}

@Model
public final class UserRoundRecordModel {
    @Attribute(.unique) public var stableID: String
    public var eventID: String
    public var roundID: String
    public var applied: Bool
    public var paid: Bool
    public var hasBaseTicket: Bool

    public init(eventID: String, value: UserRoundRecord) {
        stableID = "\(eventID)::\(value.roundID)"
        self.eventID = eventID
        roundID = value.roundID
        applied = value.applied
        paid = value.paid
        hasBaseTicket = value.hasBaseTicket
    }
}

@Model
public final class CardPreferenceRecord {
    @Attribute(.unique) public var stableID: String
    public var scope: String
    public var eventID: String?
    public var cardType: String
    public var entityID: String
    public var isHidden: Bool
    public var isPinned: Bool
    public var order: Int
    public var density: String
    public var changeReminderEnabled: Bool
    public var visibleFields: String = ""

    public init(scope: String = "global", eventID: String? = nil, configuration: CardConfiguration) {
        stableID = "\(scope)::\(eventID ?? "*")::\(configuration.cardType.rawValue)::\(configuration.entityID)"
        self.scope = scope
        self.eventID = eventID
        cardType = configuration.cardType.rawValue
        entityID = configuration.entityID
        isHidden = configuration.isHidden
        isPinned = configuration.isPinned
        order = configuration.order
        density = configuration.density.rawValue
        changeReminderEnabled = configuration.changeReminderEnabled
        visibleFields = configuration.visibleFields.sorted().joined(separator: ",")
    }

    var value: CardConfiguration? {
        guard let type = CardType(rawValue: cardType), let density = CardDensity(rawValue: density) else { return nil }
        return CardConfiguration(cardType: type, entityID: entityID, eventID: eventID, isHidden: isHidden, isPinned: isPinned, order: order, density: density, changeReminderEnabled: changeReminderEnabled, visibleFields: Set(visibleFields.split(separator: ",").map(String.init)))
    }
}

@Model
public final class PersonalReminderRecord {
    @Attribute(.unique) public var stableID: String
    public var eventID: String
    public var performanceID: String
    public var entityID: String
    public var fireAt: Date
    public var isEnabled: Bool

    public init(stableID: String, eventID: String, performanceID: String, entityID: String, fireAt: Date, isEnabled: Bool = true) {
        self.stableID = stableID
        self.eventID = eventID
        self.performanceID = performanceID
        self.entityID = entityID
        self.fireAt = fireAt
        self.isEnabled = isEnabled
    }
}

@Model
public final class OfficialReminderPreference {
    @Attribute(.unique) public var stableID: String
    public var eventID: String
    public var performanceID: String
    public var recordID: String
    public var field: String
    public var leadSeconds: Int
    public var enabled: Bool

    public init(eventID: String, performanceID: String, recordID: String, field: String, leadSeconds: Int, enabled: Bool) {
        stableID = "\(eventID)::\(performanceID)::\(recordID)::\(field)"
        self.eventID = eventID; self.performanceID = performanceID; self.recordID = recordID
        self.field = field; self.leadSeconds = leadSeconds; self.enabled = enabled
    }

    var rule: ServerReminderRule { ServerReminderRule(eventID: eventID, performanceID: performanceID, recordID: recordID, field: field, leadSeconds: leadSeconds, enabled: enabled) }
}

@Observable
@MainActor
public final class UserDataStore {
    public private(set) var eventStates: [String: UserEventState] = [:]
    public private(set) var cardConfigurations: [CardConfiguration.Key: CardConfiguration] = [:]
    public var showsDeviceLocalTime: Bool {
        didSet { UserDefaults.standard.set(showsDeviceLocalTime, forKey: "showsDeviceLocalTime") }
    }

    private let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    public init(container: ModelContainer? = nil) {
        self.container = container ?? Self.makeContainer()
        showsDeviceLocalTime = UserDefaults.standard.bool(forKey: "showsDeviceLocalTime")
        reload()
    }

    public static func makeContainer(inMemory: Bool = false) -> ModelContainer {
        let schema = Schema([UserEventRecord.self, UserRoundRecordModel.self, CardPreferenceRecord.self, PersonalReminderRecord.self, OfficialReminderPreference.self])
        let configuration = ModelConfiguration("PrivateUserState", schema: schema, isStoredInMemoryOnly: inMemory)
        do { return try ModelContainer(for: schema, configurations: [configuration]) }
        catch { fatalError("Unable to create private user store: \(error)") }
    }

    public func state(for eventID: String) -> UserEventState { eventStates[eventID] ?? UserEventState(eventID: eventID) }

    public func setFollowed(_ value: Bool, eventID: String) { updateEvent(eventID) { $0.isFollowed = value } }
    public func setPlanningToAttend(_ value: Bool, eventID: String) { updateEvent(eventID) { $0.planningToAttend = value } }
    public func setSelectedPerformance(_ performanceID: String?, eventID: String) { updateEvent(eventID) { $0.selectedPerformanceID = performanceID } }
    public func selectedPerformanceID(eventID: String) -> String? {
        fetchEvent(eventID)?.selectedPerformanceID
    }

    public func setRoundRecord(_ value: UserRoundRecord, eventID: String) {
        let stableID = "\(eventID)::\(value.roundID)"
        let descriptor = FetchDescriptor<UserRoundRecordModel>(predicate: #Predicate { $0.stableID == stableID })
        let record = (try? context.fetch(descriptor).first) ?? UserRoundRecordModel(eventID: eventID, value: value)
        if record.modelContext == nil { context.insert(record) }
        record.applied = value.applied; record.paid = value.paid; record.hasBaseTicket = value.hasBaseTicket
        commit()
    }

    public func configuration(cardType: CardType, entityID: String, eventID: String? = nil) -> CardConfiguration? {
        cardConfigurations[.init(cardType: cardType, entityID: entityID, eventID: eventID)]
            ?? cardConfigurations[.init(cardType: cardType, entityID: entityID)]
    }

    /// Resolves a card from broadest to narrowest preference: global card
    /// type, global entity, event card type, then event entity.
    public func effectiveConfiguration(cardType: CardType, entityID: String, eventID: String) -> CardConfiguration {
        var result = CardConfiguration(cardType: cardType, entityID: entityID)
        let candidates = [
            cardConfigurations[.init(cardType: cardType, entityID: CardConfiguration.globalEntityID)],
            cardConfigurations[.init(cardType: cardType, entityID: entityID)],
            cardConfigurations[.init(cardType: cardType, entityID: CardConfiguration.globalEntityID, eventID: eventID)],
            cardConfigurations[.init(cardType: cardType, entityID: entityID, eventID: eventID)]
        ]
        for value in candidates.compactMap({ $0 }) {
            result = value
            result.entityID = entityID
            result.eventID = eventID
        }
        return result
    }

    public func setConfiguration(_ value: CardConfiguration) {
        let stableID = "\(value.eventID == nil ? "global" : "event")::\(value.eventID ?? "*")::\(value.cardType.rawValue)::\(value.entityID)"
        let descriptor = FetchDescriptor<CardPreferenceRecord>(predicate: #Predicate { $0.stableID == stableID })
        let record = (try? context.fetch(descriptor).first) ?? CardPreferenceRecord(scope: value.eventID == nil ? "global" : "event", eventID: value.eventID, configuration: value)
        if record.modelContext == nil { context.insert(record) }
        record.isHidden = value.isHidden; record.isPinned = value.isPinned; record.order = value.order
        record.density = value.density.rawValue; record.changeReminderEnabled = value.changeReminderEnabled
        record.visibleFields = value.visibleFields.sorted().joined(separator: ",")
        commit()
    }

    public func effectiveConfigurations(eventID: String) -> [CardConfiguration.Key: CardConfiguration] {
        var result: [CardConfiguration.Key: CardConfiguration] = [:]
        for value in cardConfigurations.values where value.eventID == nil {
            result[.init(cardType: value.cardType, entityID: value.entityID)] = value
        }
        for value in cardConfigurations.values where value.eventID == eventID {
            var normalized = value; normalized.eventID = nil
            result[.init(cardType: value.cardType, entityID: value.entityID)] = normalized
        }
        return result
    }

    public func removeConfiguration(cardType: CardType, entityID: String) {
        let stableID = "global::*::\(cardType.rawValue)::\(entityID)"
        let descriptor = FetchDescriptor<CardPreferenceRecord>(predicate: #Predicate { $0.stableID == stableID })
        if let record = try? context.fetch(descriptor).first { context.delete(record); commit() }
    }

    public func removeConfigurations(cardType: CardType) {
        let rawValue = cardType.rawValue
        let descriptor = FetchDescriptor<CardPreferenceRecord>(predicate: #Predicate { $0.cardType == rawValue })
        let records = (try? context.fetch(descriptor)) ?? []
        for record in records { context.delete(record) }
        commit()
    }

    /// Count of cards of the given types hidden either globally or for this event.
    public func hiddenCardCount(cardTypes: [CardType], eventID: String) -> Int {
        let configs = effectiveConfigurations(eventID: eventID)
        return configs.values.filter { cardTypes.contains($0.cardType) && $0.isHidden }.count
    }

    public func unhideCards(cardTypes: [CardType], eventID: String) {
        let rawValues = Set(cardTypes.map(\.rawValue))
        let records = (try? context.fetch(FetchDescriptor<CardPreferenceRecord>())) ?? []
        for record in records where rawValues.contains(record.cardType) {
            guard record.eventID == nil || record.eventID == eventID else { continue }
            record.isHidden = false
        }
        commit()
    }

    public func saveReminder(_ reminder: PersonalReminderRecord) {
        let stableID = reminder.stableID
        let descriptor = FetchDescriptor<PersonalReminderRecord>(predicate: #Predicate { $0.stableID == stableID })
        if let existing = try? context.fetch(descriptor).first {
            existing.fireAt = reminder.fireAt; existing.isEnabled = reminder.isEnabled
        } else { context.insert(reminder) }
        commit()
    }
    public func setOfficialReminder(eventID: String, performanceID: String, recordID: String, field: String, leadSeconds: Int, enabled: Bool) -> [ServerReminderRule] {
        let stableID = "\(eventID)::\(performanceID)::\(recordID)::\(field)"
        let descriptor = FetchDescriptor<OfficialReminderPreference>(predicate: #Predicate { $0.stableID == stableID })
        let record = (try? context.fetch(descriptor).first) ?? OfficialReminderPreference(eventID: eventID, performanceID: performanceID, recordID: recordID, field: field, leadSeconds: leadSeconds, enabled: enabled)
        if record.modelContext == nil { context.insert(record) }
        record.leadSeconds = leadSeconds; record.enabled = enabled
        commit()
        return ((try? context.fetch(FetchDescriptor<OfficialReminderPreference>())) ?? []).map(\.rule)
    }
    public func setDeviceLocalTimeEnabled(_ enabled: Bool) { showsDeviceLocalTime = enabled }

    public func reconcile(remaps: [CatalogRemap], availableBundles: [LiveEventBundle]) {
        // stableID is unique; track what this batch has already claimed, because earlier
        // iterations' rewrites are not visible to a fetch until the final save.
        var claimedStableIDs = Set<String>()
        for remap in remaps {
            guard let replacement = availableBundles.first(where: { $0.event.id == remap.replacementID }) else { continue }
            if let old = fetchEvent(remap.eventID) {
                let target = fetchEvent(remap.replacementID) ?? UserEventRecord(eventID: remap.replacementID)
                if target.modelContext == nil { context.insert(target) }
                target.isFollowed = target.isFollowed || old.isFollowed
                target.planningToAttend = target.planningToAttend || old.planningToAttend
                if let selected = old.selectedPerformanceID, replacement.performances.contains(where: { $0.id == selected }) { target.selectedPerformanceID = selected }
                // Preserve the original private record as history.
            }

            // Round records are migrated even when the source event has no UserEventRecord:
            // a user can mark 已申请 on an event they never followed.
            let sourceEventID = remap.eventID
            let orphanedRounds = (try? context.fetch(FetchDescriptor<UserRoundRecordModel>(predicate: #Predicate { $0.eventID == sourceEventID }))) ?? []
            for round in orphanedRounds {
                let replacementStableID = "\(remap.replacementID)::\(round.roundID)"
                if claimedStableIDs.contains(replacementStableID) { continue }
                let existingDescriptor = FetchDescriptor<UserRoundRecordModel>(predicate: #Predicate { $0.stableID == replacementStableID })
                if (try? context.fetch(existingDescriptor).first) != nil { continue }
                round.eventID = remap.replacementID
                round.stableID = replacementStableID
                claimedStableIDs.insert(replacementStableID)
            }
        }
        commit()
    }

    private func updateEvent(_ eventID: String, mutate: (UserEventRecord) -> Void) {
        let record = fetchEvent(eventID) ?? UserEventRecord(eventID: eventID)
        if record.modelContext == nil { context.insert(record) }
        mutate(record); commit()
    }

    private func fetchEvent(_ eventID: String) -> UserEventRecord? {
        let descriptor = FetchDescriptor<UserEventRecord>(predicate: #Predicate { $0.eventID == eventID })
        return try? context.fetch(descriptor).first
    }

    private func commit() { try? context.save(); reload() }

    private func reload() {
        let events = (try? context.fetch(FetchDescriptor<UserEventRecord>())) ?? []
        let rounds = (try? context.fetch(FetchDescriptor<UserRoundRecordModel>())) ?? []
        let roundsByEvent = Dictionary(grouping: rounds, by: \.eventID)
        var states: [String: UserEventState] = [:]
        for event in events {
            let values = (roundsByEvent[event.eventID] ?? []).map { UserRoundRecord(roundID: $0.roundID, applied: $0.applied, paid: $0.paid, hasBaseTicket: $0.hasBaseTicket) }
            states[event.eventID] = UserEventState(eventID: event.eventID, isFollowed: event.isFollowed, planningToAttend: event.planningToAttend, roundRecords: values)
        }
        for (eventID, roundModels) in roundsByEvent where states[eventID] == nil {
            let values = roundModels.map { UserRoundRecord(roundID: $0.roundID, applied: $0.applied, paid: $0.paid, hasBaseTicket: $0.hasBaseTicket) }
            states[eventID] = UserEventState(eventID: eventID, isFollowed: false, planningToAttend: false, roundRecords: values)
        }
        eventStates = states
        let cards = (try? context.fetch(FetchDescriptor<CardPreferenceRecord>())) ?? []
        cardConfigurations = Dictionary(uniqueKeysWithValues: cards.compactMap { $0.value }.map { ($0.key, $0) })
    }
}
