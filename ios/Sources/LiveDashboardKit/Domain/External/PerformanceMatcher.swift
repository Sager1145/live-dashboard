import Foundation
import LiveIngestionCore

public struct LocalSession: Equatable, Sendable {
    public var performanceID: String
    public var eventID: String
    public var localDate: String?
    public var startTime: String?
    public var dayLabel: String?
    public var venueName: String
    public var title: String
    public var officialURL: String

    public init(performanceID: String, eventID: String, localDate: String?, startTime: String?, dayLabel: String?, venueName: String, title: String, officialURL: String) {
        self.performanceID = performanceID
        self.eventID = eventID
        self.localDate = localDate
        self.startTime = startTime
        self.dayLabel = dayLabel
        self.venueName = venueName
        self.title = title
        self.officialURL = officialURL
    }
}

public struct ObservedSession: Equatable, Sendable {
    public var llfansPerformanceID: String?
    public var eventernoteEventID: String?
    public var localDate: String?
    public var startTime: String?
    public var dayLabel: String?
    public var venueName: String?
    public var title: String?
    public var officialLinks: [String]
    public var duplicateEventernoteTarget: Bool

    public init(llfansPerformanceID: String? = nil, eventernoteEventID: String? = nil, localDate: String? = nil, startTime: String? = nil, dayLabel: String? = nil, venueName: String? = nil, title: String? = nil, officialLinks: [String] = [], duplicateEventernoteTarget: Bool = false) {
        self.llfansPerformanceID = llfansPerformanceID
        self.eventernoteEventID = eventernoteEventID
        self.localDate = localDate
        self.startTime = startTime
        self.dayLabel = dayLabel
        self.venueName = venueName
        self.title = title
        self.officialLinks = officialLinks
        self.duplicateEventernoteTarget = duplicateEventernoteTarget
    }
}

public struct SessionMatch: Equatable, Sendable {
    public var localPerformanceID: String
    public var relation: ExternalRelationKind
    public var conflict: SessionConflictReason?
    public var external: ExternalIdentity
}

public enum PerformanceMatcher {
    /// A linked local id stays linked when the date changes. Title similarity alone
    /// never becomes an exact session. Duplicate external targets stay grouped.
    public static func match(locals: [LocalSession], observed: ObservedSession, linkedLocalID: String? = nil) -> [SessionMatch] {
        guard let external = externalIdentity(observed) else { return [] }
        return locals.compactMap { local in
            let decision = SessionIdentityGuard.compare(candidate(local), candidate(observed, localID: local.performanceID))
            if local.performanceID == linkedLocalID {
                let relation: ExternalRelationKind = observed.duplicateEventernoteTarget ? .groupedEvent : .exactSession
                return SessionMatch(localPerformanceID: local.performanceID, relation: relation, conflict: nil, external: external)
            }
            if case .hardConflict(let reason) = decision, titlesAlign(local, observed) || venuesAlign(local, observed) {
                return SessionMatch(localPerformanceID: local.performanceID, relation: .rejected, conflict: reason, external: external)
            }
            if case .sameParentActivity = decision {
                return SessionMatch(localPerformanceID: local.performanceID, relation: .groupedEvent, conflict: nil, external: external)
            }
            if sameDate(local, observed), venuesAlign(local, observed), sameClock(local, observed), !observed.duplicateEventernoteTarget {
                let relation: ExternalRelationKind = observed.llfansPerformanceID == nil ? .candidate : .exactSession
                return SessionMatch(localPerformanceID: local.performanceID, relation: relation, conflict: nil, external: external)
            }
            if observed.duplicateEventernoteTarget, sameDate(local, observed), venuesAlign(local, observed) {
                return SessionMatch(localPerformanceID: local.performanceID, relation: .groupedEvent, conflict: nil, external: external)
            }
            if titlesAlign(local, observed), local.localDate == observed.localDate {
                return SessionMatch(localPerformanceID: local.performanceID, relation: .candidate, conflict: nil, external: external)
            }
            return nil
        }
    }

    private static func externalIdentity(_ observed: ObservedSession) -> ExternalIdentity? {
        if let id = observed.eventernoteEventID {
            return ExternalIdentity(namespace: .eventernote, entity: .event, rawID: id)
        }
        if let id = observed.llfansPerformanceID {
            return ExternalIdentity(namespace: .llfans, entity: .performance, rawID: id)
        }
        return nil
    }

    private static func candidate(_ local: LocalSession) -> SessionCandidate {
        SessionCandidate(localDate: local.localDate, startTime: local.startTime, dayPartLabel: local.dayLabel, title: local.title, parentOfficialURL: local.officialURL, performanceID: local.performanceID)
    }

    private static func candidate(_ observed: ObservedSession, localID: String) -> SessionCandidate {
        SessionCandidate(localDate: observed.localDate, startTime: observed.startTime, dayPartLabel: observed.dayLabel, title: observed.title, parentOfficialURL: observed.officialLinks.first, performanceID: "observed-\(localID)")
    }

    private static func sameDate(_ local: LocalSession, _ observed: ObservedSession) -> Bool {
        local.localDate != nil && local.localDate == observed.localDate
    }

    private static func sameClock(_ local: LocalSession, _ observed: ObservedSession) -> Bool {
        guard let localClock = SessionIdentityGuard.normalizedClock(local.startTime),
              let observedClock = SessionIdentityGuard.normalizedClock(observed.startTime) else { return false }
        return localClock == observedClock
    }

    private static func venuesAlign(_ local: LocalSession, _ observed: ObservedSession) -> Bool {
        guard let venue = observed.venueName, !venue.isEmpty else { return false }
        let left = normalize(local.venueName)
        let right = normalize(venue)
        return left == right || left.contains(right) || right.contains(left)
    }

    private static func titlesAlign(_ local: LocalSession, _ observed: ObservedSession) -> Bool {
        guard let title = observed.title, !title.isEmpty else { return false }
        let left = normalize(local.title)
        let right = normalize(title)
        return left == right || left.contains(right) || right.contains(left)
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .filter { !$0.isWhitespace }
    }
}
