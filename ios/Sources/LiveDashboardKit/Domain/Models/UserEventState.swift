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
    public var planningToAttend: Bool
    public var roundRecords: [UserRoundRecord]

    public var id: String { eventID }

    public init(
        eventID: String,
        isFollowed: Bool = false,
        planningToAttend: Bool = false,
        roundRecords: [UserRoundRecord] = []
    ) {
        self.eventID = eventID
        self.isFollowed = isFollowed
        self.planningToAttend = planningToAttend
        self.roundRecords = roundRecords
    }
}
