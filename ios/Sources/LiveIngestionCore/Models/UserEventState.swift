import Foundation

/// User's manual record of participation in a round's application/payment
/// process. These are hand-entered facts, never inferred from public pages,
/// and never mutate the official ticketing data.
public struct UserRoundRecord: Codable, Hashable, Sendable {
    public var roundID: String
    public var applied: Bool
    public var paid: Bool
    public var hasBaseTicket: Bool

    public init(roundID: String, applied: Bool = false, paid: Bool = false, hasBaseTicket: Bool = false) {
        self.roundID = roundID
        self.applied = applied
        self.paid = paid
        self.hasBaseTicket = hasBaseTicket
    }
}

/// Per-event user data: follow state, plan-to-attend, and manual ticket
/// records. Stored separately from the public cache; never cleared by
/// "clear cache".
public struct UserEventState: Codable, Hashable, Identifiable, Sendable {
    public var eventID: String
    public var isFollowed: Bool
    /// Event-wide plan. When `participatingPerformanceIDs` is empty, this applies to every day.
    /// When that list is non-empty, only those performances are marked.
    public var planningToAttend: Bool
    /// Performances the user marked individually. Empty means "use `planningToAttend` for every day".
    public var participatingPerformanceIDs: [String]
    public var roundRecords: [UserRoundRecord]

    public var id: String { eventID }

    public init(
        eventID: String,
        isFollowed: Bool = false,
        planningToAttend: Bool = false,
        participatingPerformanceIDs: [String] = [],
        roundRecords: [UserRoundRecord] = []
    ) {
        self.eventID = eventID
        self.isFollowed = isFollowed
        self.planningToAttend = planningToAttend
        self.participatingPerformanceIDs = participatingPerformanceIDs
        self.roundRecords = roundRecords
    }

    public func isParticipating(in performanceID: String) -> Bool {
        if participatingPerformanceIDs.isEmpty { return planningToAttend }
        return participatingPerformanceIDs.contains(performanceID)
    }
}
