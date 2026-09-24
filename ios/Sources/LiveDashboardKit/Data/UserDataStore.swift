import Foundation
import Observation
import SwiftData
import LiveIngestionCore

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

/// One performance the user marked as planning to attend. Absence means that day is not
/// individually marked; an event-level `planningToAttend` with no rows still means every day.
@Model
public final class UserPerformanceParticipationRecord {
    @Attribute(.unique) public var stableID: String
    public var eventID: String
    public var performanceID: String

    public init(eventID: String, performanceID: String) {
        stableID = "\(eventID)::\(performanceID)"
        self.eventID = eventID
        self.performanceID = performanceID
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

public struct LegacyIdentityMapping: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Equatable, Codable, Hashable {
        case event, performance, ticket, goods
    }

    public var entityKind: Kind
    public var legacyID: String
    public var currentID: String

    public init(entityKind: Kind, legacyID: String, currentID: String) {
        self.entityKind = entityKind
        self.legacyID = legacyID
        self.currentID = currentID
    }
}

public struct LegacyIdentityUnmatched: Sendable, Equatable, Codable, Hashable {
    public var entityKind: LegacyIdentityMapping.Kind
    public var id: String
    public var record: String

    public init(entityKind: LegacyIdentityMapping.Kind, id: String, record: String) {
        self.entityKind = entityKind
        self.id = id
        self.record = record
    }
}

public struct LegacyIdentityRemapReport: Sendable, Equatable {
    public var unmatched: [LegacyIdentityUnmatched]
    /// False when this call replayed a journaled mapping list and did not write again.
    public var applied: Bool

    public init(unmatched: [LegacyIdentityUnmatched], applied: Bool) {
        self.unmatched = unmatched
        self.applied = applied
    }
}

public struct UserDataRemap: Sendable, Equatable {
    public var fromEventID: String
    public var toEventID: String
    public var performanceIDs: [String: String]

    public init(fromEventID: String, toEventID: String, performanceIDs: [String: String] = [:]) {
        self.fromEventID = fromEventID
        self.toEventID = toEventID
        self.performanceIDs = performanceIDs
    }
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
    private let remapDefaults: UserDefaults
    private var context: ModelContext { container.mainContext }

    public init(container: ModelContainer? = nil, remapDefaults: UserDefaults = .standard) {
        self.container = container ?? Self.makeContainer()
        self.remapDefaults = remapDefaults
        showsDeviceLocalTime = UserDefaults.standard.bool(forKey: "showsDeviceLocalTime")
        reload()
    }

    public static func makeContainer(inMemory: Bool = false) -> ModelContainer {
        let schema = Schema([UserEventRecord.self, UserPerformanceParticipationRecord.self, UserRoundRecordModel.self, CardPreferenceRecord.self, PersonalReminderRecord.self, OfficialReminderPreference.self])
        let configuration = ModelConfiguration("PrivateUserState", schema: schema, isStoredInMemoryOnly: inMemory)
        do { return try ModelContainer(for: schema, configurations: [configuration]) }
        catch { fatalError("Unable to create private user store: \(error)") }
    }

    public func state(for eventID: String) -> UserEventState { eventStates[eventID] ?? UserEventState(eventID: eventID) }

    public func setFollowed(_ value: Bool, eventID: String) { updateEvent(eventID) { $0.isFollowed = value } }

    /// Event-wide plan. Clears per-day marks so the flag applies to every performance again.
    public func setPlanningToAttend(_ value: Bool, eventID: String) {
        replaceParticipations(eventID: eventID, performanceIDs: [])
        updateEvent(eventID) { $0.planningToAttend = value }
    }

    /// Marks or unmarks a single performance. An event-wide plan is expanded to the known
    /// performances first, so turning one day off leaves the others marked.
    public func toggleParticipation(eventID: String, performanceID: String, knownPerformanceIDs: [String]) {
        let state = state(for: eventID)
        var ids = Set(state.participatingPerformanceIDs)
        if state.planningToAttend && ids.isEmpty {
            ids = Set(knownPerformanceIDs)
        }
        if ids.contains(performanceID) { ids.remove(performanceID) } else { ids.insert(performanceID) }
        replaceParticipations(eventID: eventID, performanceIDs: ids)
        updateEvent(eventID) { $0.planningToAttend = !ids.isEmpty }
    }

    /// Sets one performance's personal participation. A second call with the same
    /// value does not change stored rows. It never deletes the official event.
    public func setParticipation(eventID: String, performanceID: String, participate: Bool, knownPerformanceIDs: [String]) {
        let state = state(for: eventID)
        var ids = Set(state.participatingPerformanceIDs)
        if state.planningToAttend && ids.isEmpty { ids = Set(knownPerformanceIDs) }
        let covered = ids.contains(performanceID)
        if participate == covered { return }
        if participate { ids.insert(performanceID) } else { ids.remove(performanceID) }
        replaceParticipations(eventID: eventID, performanceIDs: ids)
        updateEvent(eventID) { $0.planningToAttend = !ids.isEmpty }
    }

    /// Removes participation marks that pointed at performances the latest
    /// scrape no longer publishes. Event follow and personal plans stay.
    public func pruneMissingPerformances(eventID: String, validPerformanceIDs: Set<String>) {
        let state = state(for: eventID)
        let kept = state.participatingPerformanceIDs.filter { validPerformanceIDs.contains($0) }
        guard kept.count != state.participatingPerformanceIDs.count else { return }
        replaceParticipations(eventID: eventID, performanceIDs: Set(kept))
        updateEvent(eventID) { record in
            record.planningToAttend = !kept.isEmpty
            record.isFollowed = state.isFollowed
        }
    }

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

    /// Rewrites private user rows from one event id to another. A catalog event
    /// disappearing is not a reason to drop rows; empty endpoints are skipped.
    @MainActor public func applyRemaps(_ remaps: [UserDataRemap]) {
        let remaps = remaps.filter { !$0.fromEventID.isEmpty && !$0.toEventID.isEmpty }
        if !remaps.isEmpty {
            var deleted = Set<ObjectIdentifier>()
            var events = (try? context.fetch(FetchDescriptor<UserEventRecord>())) ?? []
            var participations = (try? context.fetch(FetchDescriptor<UserPerformanceParticipationRecord>())) ?? []
            var rounds = (try? context.fetch(FetchDescriptor<UserRoundRecordModel>())) ?? []
            var cards = (try? context.fetch(FetchDescriptor<CardPreferenceRecord>())) ?? []
            var reminders = (try? context.fetch(FetchDescriptor<PersonalReminderRecord>())) ?? []
            var official = (try? context.fetch(FetchDescriptor<OfficialReminderPreference>())) ?? []
            for remap in remaps {
                remapEvent(remap, rows: &events, deleted: &deleted)
                remapParticipations(remap, rows: &participations, deleted: &deleted)
                remapRounds(remap, rows: &rounds, deleted: &deleted)
                remapCards(remap, rows: &cards, deleted: &deleted)
                remapPersonalReminders(remap, rows: &reminders, deleted: &deleted)
                remapOfficialReminders(remap, rows: &official, deleted: &deleted)
            }
        }
        commit()
    }

    /// Rewrites favorites, the selected performance, round applications, and card
    /// settings from legacy ids to current ids. Ids with no mapping are kept and
    /// reported. The same list applied again reads the journal and does not
    /// insert or delete rows.
    @MainActor public func applyIdentityMappings(_ mappings: [LegacyIdentityMapping]) -> LegacyIdentityRemapReport {
        let usable = mappings.filter { !$0.legacyID.isEmpty && !$0.currentID.isEmpty }
        let fingerprint = Self.identityRemapFingerprint(usable)
        if let stored = readRemapJournal(fingerprint) {
            return LegacyIdentityRemapReport(unmatched: stored, applied: false)
        }
        let tables = IdentityRemapTables(mappings: usable)
        var unmatched: [LegacyIdentityUnmatched] = []
        unmatched += rewriteEvents(tables)
        unmatched += rewriteParticipations(tables)
        unmatched += rewriteRounds(tables)
        unmatched += rewriteCards(tables)
        let unique = Self.normalizedUnmatched(unmatched)
        commit()
        writeRemapJournal(fingerprint, unmatched: unique)
        return LegacyIdentityRemapReport(unmatched: unique, applied: true)
    }

    /// A public-catalog 410 (or instance remap that did not match) must not delete
    /// private rows. Unmatched ids are reported and left in place.
    @MainActor public func applyPublicCatalogUnavailable(statusCode: Int) -> LegacyIdentityRemapReport {
        guard statusCode == 410 else {
            return LegacyIdentityRemapReport(unmatched: [], applied: false)
        }
        var unmatched: [LegacyIdentityUnmatched] = []
        let events = (try? context.fetch(FetchDescriptor<UserEventRecord>())) ?? []
        for row in events {
            unmatched.append(LegacyIdentityUnmatched(entityKind: .event, id: row.eventID, record: "favorite"))
            if let selected = row.selectedPerformanceID {
                unmatched.append(LegacyIdentityUnmatched(entityKind: .performance, id: selected, record: "selectedPerformance"))
            }
        }
        let participations = (try? context.fetch(FetchDescriptor<UserPerformanceParticipationRecord>())) ?? []
        for row in participations {
            unmatched.append(LegacyIdentityUnmatched(entityKind: .performance, id: row.performanceID, record: "participation"))
        }
        let rounds = (try? context.fetch(FetchDescriptor<UserRoundRecordModel>())) ?? []
        for row in rounds {
            unmatched.append(LegacyIdentityUnmatched(entityKind: .ticket, id: row.roundID, record: "round"))
        }
        let cards = (try? context.fetch(FetchDescriptor<CardPreferenceRecord>())) ?? []
        for row in cards where row.entityID != CardConfiguration.globalEntityID {
            let kind: LegacyIdentityMapping.Kind = row.cardType == CardType.goodsCampaign.rawValue ? .goods : .ticket
            unmatched.append(LegacyIdentityUnmatched(entityKind: kind, id: row.entityID, record: "card"))
        }
        return LegacyIdentityRemapReport(unmatched: Self.normalizedUnmatched(unmatched), applied: false)
    }

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

            let orphanedDays = (try? context.fetch(FetchDescriptor<UserPerformanceParticipationRecord>(predicate: #Predicate { $0.eventID == sourceEventID }))) ?? []
            for day in orphanedDays {
                guard replacement.performances.contains(where: { $0.id == day.performanceID }) else { continue }
                let replacementStableID = "\(remap.replacementID)::\(day.performanceID)"
                if claimedStableIDs.contains(replacementStableID) { continue }
                let existingDescriptor = FetchDescriptor<UserPerformanceParticipationRecord>(predicate: #Predicate { $0.stableID == replacementStableID })
                if (try? context.fetch(existingDescriptor).first) != nil { continue }
                day.eventID = remap.replacementID
                day.stableID = replacementStableID
                claimedStableIDs.insert(replacementStableID)
            }
        }
        commit()
    }

    private func remapEvent(_ remap: UserDataRemap, rows: inout [UserEventRecord], deleted: inout Set<ObjectIdentifier>) {
        guard let source = rows.first(where: { $0.eventID == remap.fromEventID && !deleted.contains(ObjectIdentifier($0)) }) else { return }
        let mappedSelection = source.selectedPerformanceID.map { remap.performanceIDs[$0] ?? $0 }
        if remap.fromEventID == remap.toEventID {
            source.selectedPerformanceID = mappedSelection
            return
        }
        if let destination = rows.first(where: { $0 !== source && $0.eventID == remap.toEventID && !deleted.contains(ObjectIdentifier($0)) }) {
            destination.isFollowed = destination.isFollowed || source.isFollowed
            destination.planningToAttend = destination.planningToAttend || source.planningToAttend
            context.delete(source)
            deleted.insert(ObjectIdentifier(source))
            return
        }
        source.eventID = remap.toEventID
        source.selectedPerformanceID = mappedSelection
    }

    private func remapParticipations(_ remap: UserDataRemap, rows: inout [UserPerformanceParticipationRecord], deleted: inout Set<ObjectIdentifier>) {
        let pending: [(row: UserPerformanceParticipationRecord, stableID: String, performanceID: String)] = rows.compactMap { row in
            guard row.eventID == remap.fromEventID, !deleted.contains(ObjectIdentifier(row)) else { return nil }
            let performanceID = remap.performanceIDs[row.performanceID] ?? row.performanceID
            let stableID = "\(remap.toEventID)::\(performanceID)"
            guard row.stableID != stableID || row.performanceID != performanceID else { return nil }
            return (row, stableID, performanceID)
        }
        retarget(rows: rows, pending: pending.map { ($0.row, $0.stableID) }, deleted: &deleted, stableID: { $0.stableID }, setStableID: { $0.stableID = $1 }, apply: { row in
            guard let move = pending.first(where: { $0.row === row }) else { return }
            row.eventID = remap.toEventID
            row.performanceID = move.performanceID
            row.stableID = move.stableID
        }, merge: { _, _ in })
    }

    private func remapRounds(_ remap: UserDataRemap, rows: inout [UserRoundRecordModel], deleted: inout Set<ObjectIdentifier>) {
        let pending: [(row: UserRoundRecordModel, stableID: String)] = rows.compactMap { row in
            guard row.eventID == remap.fromEventID, !deleted.contains(ObjectIdentifier(row)) else { return nil }
            let stableID = "\(remap.toEventID)::\(row.roundID)"
            guard row.stableID != stableID else { return nil }
            return (row, stableID)
        }
        retarget(rows: rows, pending: pending, deleted: &deleted, stableID: { $0.stableID }, setStableID: { $0.stableID = $1 }, apply: { row in
            guard let move = pending.first(where: { $0.row === row }) else { return }
            row.eventID = remap.toEventID
            row.stableID = move.stableID
        }, merge: { _, _ in })
    }

    private func remapCards(_ remap: UserDataRemap, rows: inout [CardPreferenceRecord], deleted: inout Set<ObjectIdentifier>) {
        let pending: [(row: CardPreferenceRecord, stableID: String)] = rows.compactMap { row in
            guard row.eventID == remap.fromEventID, !deleted.contains(ObjectIdentifier(row)) else { return nil }
            let stableID = "\(row.scope)::\(remap.toEventID)::\(row.cardType)::\(row.entityID)"
            guard row.stableID != stableID else { return nil }
            return (row, stableID)
        }
        retarget(rows: rows, pending: pending, deleted: &deleted, stableID: { $0.stableID }, setStableID: { $0.stableID = $1 }, apply: { row in
            guard let move = pending.first(where: { $0.row === row }) else { return }
            row.eventID = remap.toEventID
            row.stableID = move.stableID
        }, merge: { destination, source in
            destination.changeReminderEnabled = destination.changeReminderEnabled || source.changeReminderEnabled
        })
    }

    private func remapPersonalReminders(_ remap: UserDataRemap, rows: inout [PersonalReminderRecord], deleted: inout Set<ObjectIdentifier>) {
        let pending: [(row: PersonalReminderRecord, stableID: String, performanceID: String)] = rows.compactMap { row in
            guard row.eventID == remap.fromEventID, !deleted.contains(ObjectIdentifier(row)) else { return nil }
            let performanceID = remap.performanceIDs[row.performanceID] ?? row.performanceID
            let stableID = reminderStableID(existing: row.stableID, fromEventID: row.eventID, fromPerformanceID: row.performanceID, toEventID: remap.toEventID, toPerformanceID: performanceID)
            guard row.stableID != stableID || row.eventID != remap.toEventID || row.performanceID != performanceID else { return nil }
            return (row, stableID, performanceID)
        }
        retarget(rows: rows, pending: pending.map { ($0.row, $0.stableID) }, deleted: &deleted, stableID: { $0.stableID }, setStableID: { $0.stableID = $1 }, apply: { row in
            guard let move = pending.first(where: { $0.row === row }) else { return }
            row.eventID = remap.toEventID
            row.performanceID = move.performanceID
            row.stableID = move.stableID
        }, merge: { destination, source in
            destination.isEnabled = destination.isEnabled || source.isEnabled
        })
    }

    private func remapOfficialReminders(_ remap: UserDataRemap, rows: inout [OfficialReminderPreference], deleted: inout Set<ObjectIdentifier>) {
        let pending: [(row: OfficialReminderPreference, stableID: String, performanceID: String)] = rows.compactMap { row in
            guard row.eventID == remap.fromEventID, !deleted.contains(ObjectIdentifier(row)) else { return nil }
            let performanceID = remap.performanceIDs[row.performanceID] ?? row.performanceID
            let stableID = "\(remap.toEventID)::\(performanceID)::\(row.recordID)::\(row.field)"
            guard row.stableID != stableID || row.performanceID != performanceID else { return nil }
            return (row, stableID, performanceID)
        }
        retarget(rows: rows, pending: pending.map { ($0.row, $0.stableID) }, deleted: &deleted, stableID: { $0.stableID }, setStableID: { $0.stableID = $1 }, apply: { row in
            guard let move = pending.first(where: { $0.row === row }) else { return }
            row.eventID = remap.toEventID
            row.performanceID = move.performanceID
            row.stableID = move.stableID
        }, merge: { _, _ in })
    }

    /// `live-dashboard.reminder.{eventID}.{performanceID}.{tab}.{cardType}.{entityID}`
    private func reminderStableID(existing: String, fromEventID: String, fromPerformanceID: String, toEventID: String, toPerformanceID: String) -> String {
        let prefix = "live-dashboard.reminder.\(fromEventID).\(fromPerformanceID)."
        guard existing.hasPrefix(prefix) else { return existing }
        return "live-dashboard.reminder.\(toEventID).\(toPerformanceID)." + existing.dropFirst(prefix.count)
    }

    /// Moves rows onto `stableID`. A row already stored there keeps its non-boolean
    /// fields. Callers OR the booleans the remap spec names. Parked ids exist only
    /// so two performances can exchange keys before the single save.
    private func retarget<Row: AnyObject & PersistentModel>(
        rows: [Row],
        pending: [(row: Row, stableID: String)],
        deleted: inout Set<ObjectIdentifier>,
        stableID: (Row) -> String,
        setStableID: (Row, String) -> Void,
        apply: (Row) -> Void,
        merge: (Row, Row) -> Void
    ) {
        var pending = pending
        var parksRemaining = pending.count
        var parkSerial = 0
        while !pending.isEmpty {
            var blocked: [(row: Row, stableID: String)] = []
            var progressed = false
            for item in pending {
                let holder = rows.first {
                    $0 !== item.row && !deleted.contains(ObjectIdentifier($0)) && stableID($0) == item.stableID
                }
                if let holder, pending.contains(where: { $0.row === holder }) {
                    blocked.append(item)
                    continue
                }
                if let holder {
                    merge(holder, item.row)
                    context.delete(item.row)
                    deleted.insert(ObjectIdentifier(item.row))
                } else {
                    apply(item.row)
                }
                progressed = true
            }
            if blocked.count == pending.count {
                if parksRemaining == 0 {
                    for item in pending { apply(item.row) }
                    return
                }
                setStableID(blocked[0].row, "remap-park::\(parkSerial)")
                parkSerial += 1
                parksRemaining -= 1
                continue
            }
            pending = blocked
            if !progressed { return }
        }
    }

    private struct IdentityRemapTables {
        var maps: [LegacyIdentityMapping.Kind: [String: String]] = [:]
        var currents: [LegacyIdentityMapping.Kind: Set<String>] = [:]

        init(mappings: [LegacyIdentityMapping]) {
            for mapping in mappings {
                var inner = maps[mapping.entityKind] ?? [:]
                if inner[mapping.legacyID] == nil {
                    inner[mapping.legacyID] = mapping.currentID
                }
                maps[mapping.entityKind] = inner
                var current = currents[mapping.entityKind] ?? []
                current.insert(mapping.currentID)
                currents[mapping.entityKind] = current
            }
        }

        func resolve(_ id: String, kind: LegacyIdentityMapping.Kind) -> (id: String, matched: Bool) {
            if let next = maps[kind]?[id] { return (next, true) }
            if currents[kind]?.contains(id) == true { return (id, true) }
            return (id, false)
        }
    }

    private static let remapJournalKey = "liveDashboard.identityRemapJournal.v1"

    private struct RemapJournalEnvelope: Codable {
        var entries: [String: [LegacyIdentityUnmatched]]
    }

    private static func normalizedUnmatched(_ rows: [LegacyIdentityUnmatched]) -> [LegacyIdentityUnmatched] {
        Array(Set(rows)).sorted {
            ($0.record, $0.entityKind.rawValue, $0.id) < ($1.record, $1.entityKind.rawValue, $1.id)
        }
    }

    private func readRemapJournal(_ fingerprint: String) -> [LegacyIdentityUnmatched]? {
        guard let data = remapDefaults.data(forKey: Self.remapJournalKey),
              let envelope = try? JSONDecoder().decode(RemapJournalEnvelope.self, from: data) else { return nil }
        return envelope.entries[fingerprint]
    }

    private func writeRemapJournal(_ fingerprint: String, unmatched: [LegacyIdentityUnmatched]) {
        var envelope = (remapDefaults.data(forKey: Self.remapJournalKey).flatMap {
            try? JSONDecoder().decode(RemapJournalEnvelope.self, from: $0)
        }) ?? RemapJournalEnvelope(entries: [:])
        envelope.entries[fingerprint] = unmatched
        if let data = try? JSONEncoder().encode(envelope) {
            remapDefaults.set(data, forKey: Self.remapJournalKey)
        }
    }

    private func rewriteEvents(_ tables: IdentityRemapTables) -> [LegacyIdentityUnmatched] {
        let rows = (try? context.fetch(FetchDescriptor<UserEventRecord>())) ?? []
        struct Plan {
            var row: UserEventRecord
            var eventID: String
            var selected: String?
        }
        var unmatched: [LegacyIdentityUnmatched] = []
        var plans: [Plan] = []
        for row in rows {
            let event = tables.resolve(row.eventID, kind: .event)
            if !event.matched {
                unmatched.append(LegacyIdentityUnmatched(entityKind: .event, id: row.eventID, record: "favorite"))
            }
            var selected = row.selectedPerformanceID
            if let current = selected {
                let performance = tables.resolve(current, kind: .performance)
                if !performance.matched {
                    unmatched.append(LegacyIdentityUnmatched(entityKind: .performance, id: current, record: "selectedPerformance"))
                }
                selected = performance.id
            }
            plans.append(Plan(row: row, eventID: event.id, selected: selected))
        }
        var survivors: [Plan] = []
        for (eventID, group) in Dictionary(grouping: plans, by: \.eventID) {
            let keeper = group[0].row
            for extra in group.dropFirst() {
                keeper.isFollowed = keeper.isFollowed || extra.row.isFollowed
                keeper.planningToAttend = keeper.planningToAttend || extra.row.planningToAttend
                context.delete(extra.row)
            }
            survivors.append(Plan(row: keeper, eventID: eventID, selected: group.compactMap(\.selected).first))
        }
        for plan in survivors where plan.row.eventID != plan.eventID {
            plan.row.eventID = "remap-park::\(UUID().uuidString)"
        }
        for plan in survivors {
            plan.row.eventID = plan.eventID
            plan.row.selectedPerformanceID = plan.selected
        }
        return unmatched
    }

    private func rewriteParticipations(_ tables: IdentityRemapTables) -> [LegacyIdentityUnmatched] {
        let rows = (try? context.fetch(FetchDescriptor<UserPerformanceParticipationRecord>())) ?? []
        struct Plan {
            var row: UserPerformanceParticipationRecord
            var eventID: String
            var performanceID: String
            var stableID: String
        }
        var unmatched: [LegacyIdentityUnmatched] = []
        var plans: [Plan] = []
        for row in rows {
            let event = tables.resolve(row.eventID, kind: .event)
            let performance = tables.resolve(row.performanceID, kind: .performance)
            if !performance.matched {
                unmatched.append(LegacyIdentityUnmatched(entityKind: .performance, id: row.performanceID, record: "participation"))
            }
            let stableID = "\(event.id)::\(performance.id)"
            plans.append(Plan(row: row, eventID: event.id, performanceID: performance.id, stableID: stableID))
        }
        var survivors: [Plan] = []
        for (_, group) in Dictionary(grouping: plans, by: \.stableID) {
            let keeper = group[0]
            for extra in group.dropFirst() { context.delete(extra.row) }
            survivors.append(keeper)
        }
        for plan in survivors where plan.row.stableID != plan.stableID {
            plan.row.stableID = "remap-park::\(UUID().uuidString)"
        }
        for plan in survivors {
            plan.row.eventID = plan.eventID
            plan.row.performanceID = plan.performanceID
            plan.row.stableID = plan.stableID
        }
        return unmatched
    }

    private func rewriteRounds(_ tables: IdentityRemapTables) -> [LegacyIdentityUnmatched] {
        let rows = (try? context.fetch(FetchDescriptor<UserRoundRecordModel>())) ?? []
        struct Plan {
            var row: UserRoundRecordModel
            var eventID: String
            var roundID: String
            var stableID: String
        }
        var unmatched: [LegacyIdentityUnmatched] = []
        var plans: [Plan] = []
        for row in rows {
            let event = tables.resolve(row.eventID, kind: .event)
            let ticket = tables.resolve(row.roundID, kind: .ticket)
            if !ticket.matched {
                unmatched.append(LegacyIdentityUnmatched(entityKind: .ticket, id: row.roundID, record: "round"))
            }
            let stableID = "\(event.id)::\(ticket.id)"
            plans.append(Plan(row: row, eventID: event.id, roundID: ticket.id, stableID: stableID))
        }
        var survivors: [Plan] = []
        for (_, group) in Dictionary(grouping: plans, by: \.stableID) {
            let keeper = group[0].row
            for extra in group.dropFirst() {
                keeper.applied = keeper.applied || extra.row.applied
                keeper.paid = keeper.paid || extra.row.paid
                keeper.hasBaseTicket = keeper.hasBaseTicket || extra.row.hasBaseTicket
                context.delete(extra.row)
            }
            survivors.append(Plan(row: keeper, eventID: group[0].eventID, roundID: group[0].roundID, stableID: group[0].stableID))
        }
        for plan in survivors where plan.row.stableID != plan.stableID {
            plan.row.stableID = "remap-park::\(UUID().uuidString)"
        }
        for plan in survivors {
            plan.row.eventID = plan.eventID
            plan.row.roundID = plan.roundID
            plan.row.stableID = plan.stableID
        }
        return unmatched
    }

    private func rewriteCards(_ tables: IdentityRemapTables) -> [LegacyIdentityUnmatched] {
        let rows = (try? context.fetch(FetchDescriptor<CardPreferenceRecord>())) ?? []
        struct Plan {
            var row: CardPreferenceRecord
            var eventID: String?
            var entityID: String
            var stableID: String
        }
        var unmatched: [LegacyIdentityUnmatched] = []
        var plans: [Plan] = []
        for row in rows {
            let entity = Self.remappedCardEntityID(
                cardType: row.cardType,
                entityID: row.entityID,
                tickets: tables.maps[.ticket] ?? [:],
                ticketCurrents: tables.currents[.ticket] ?? [],
                goods: tables.maps[.goods] ?? [:],
                goodsCurrents: tables.currents[.goods] ?? []
            )
            if !entity.matched {
                let kind: LegacyIdentityMapping.Kind = row.cardType == CardType.goodsCampaign.rawValue ? .goods : .ticket
                unmatched.append(LegacyIdentityUnmatched(entityKind: kind, id: row.entityID, record: "card"))
            }
            let eventID: String?
            if let current = row.eventID {
                eventID = tables.resolve(current, kind: .event).id
            } else {
                eventID = nil
            }
            let stableID = "\(row.scope)::\(eventID ?? "*")::\(row.cardType)::\(entity.entityID)"
            plans.append(Plan(row: row, eventID: eventID, entityID: entity.entityID, stableID: stableID))
        }
        var survivors: [Plan] = []
        for (_, group) in Dictionary(grouping: plans, by: \.stableID) {
            let keeper = group[0].row
            for extra in group.dropFirst() {
                keeper.isHidden = keeper.isHidden || extra.row.isHidden
                keeper.isPinned = keeper.isPinned || extra.row.isPinned
                keeper.changeReminderEnabled = keeper.changeReminderEnabled || extra.row.changeReminderEnabled
                context.delete(extra.row)
            }
            survivors.append(Plan(row: keeper, eventID: group[0].eventID, entityID: group[0].entityID, stableID: group[0].stableID))
        }
        for plan in survivors where plan.row.stableID != plan.stableID {
            plan.row.stableID = "remap-park::\(UUID().uuidString)"
        }
        for plan in survivors {
            plan.row.eventID = plan.eventID
            plan.row.entityID = plan.entityID
            plan.row.stableID = plan.stableID
        }
        return unmatched
    }

    private func replaceParticipations(eventID: String, performanceIDs: Set<String>) {
        let targetEventID = eventID
        let existing = (try? context.fetch(FetchDescriptor<UserPerformanceParticipationRecord>(predicate: #Predicate { $0.eventID == targetEventID }))) ?? []
        for record in existing where !performanceIDs.contains(record.performanceID) {
            context.delete(record)
        }
        let already = Set(existing.map(\.performanceID))
        for performanceID in performanceIDs where !already.contains(performanceID) {
            context.insert(UserPerformanceParticipationRecord(eventID: eventID, performanceID: performanceID))
        }
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
        let participations = (try? context.fetch(FetchDescriptor<UserPerformanceParticipationRecord>())) ?? []
        let roundsByEvent = Dictionary(grouping: rounds, by: \.eventID)
        let daysByEvent = Dictionary(grouping: participations, by: \.eventID).mapValues { $0.map(\.performanceID).sorted() }
        var states: [String: UserEventState] = [:]
        for event in events {
            let values = (roundsByEvent[event.eventID] ?? []).map { UserRoundRecord(roundID: $0.roundID, applied: $0.applied, paid: $0.paid, hasBaseTicket: $0.hasBaseTicket) }
            states[event.eventID] = UserEventState(eventID: event.eventID, isFollowed: event.isFollowed, planningToAttend: event.planningToAttend, participatingPerformanceIDs: daysByEvent[event.eventID] ?? [], roundRecords: values)
        }
        for (eventID, roundModels) in roundsByEvent where states[eventID] == nil {
            let values = roundModels.map { UserRoundRecord(roundID: $0.roundID, applied: $0.applied, paid: $0.paid, hasBaseTicket: $0.hasBaseTicket) }
            states[eventID] = UserEventState(eventID: eventID, isFollowed: false, planningToAttend: false, participatingPerformanceIDs: daysByEvent[eventID] ?? [], roundRecords: values)
        }
        for (eventID, dayIDs) in daysByEvent where states[eventID] == nil {
            states[eventID] = UserEventState(eventID: eventID, participatingPerformanceIDs: dayIDs)
        }
        eventStates = states
        let cards = (try? context.fetch(FetchDescriptor<CardPreferenceRecord>())) ?? []
        cardConfigurations = Dictionary(uniqueKeysWithValues: cards.compactMap { $0.value }.map { ($0.key, $0) })
    }
}
