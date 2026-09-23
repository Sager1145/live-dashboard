import Foundation

public enum Franchise: String, Hashable, Sendable, LossyStringEnum {
    case bangdream
    case lovelive
    case unknown
    public static let fallback: Franchise = .unknown
}

public enum EventType: String, Hashable, Sendable, LossyStringEnum {
    case live
    case fanMeeting
    case screening
    case other
    public static let fallback: EventType = .other
}

public enum EventStatus: String, Hashable, Sendable, LossyStringEnum {
    case scheduled
    case postponed
    case cancelled
    case finished
    case unknown
    public static let fallback: EventStatus = .unknown
}

public struct LiveEvent: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let franchise: Franchise
    public let officialTitle: String
    public let groups: [String]
    public let eventType: EventType
    public let status: EventStatus
    public let primarySourceURL: String
    public let timeZone: String

    public init(
        id: String,
        franchise: Franchise,
        officialTitle: String,
        groups: [String],
        eventType: EventType,
        status: EventStatus,
        primarySourceURL: String,
        timeZone: String
    ) {
        self.id = id
        self.franchise = franchise
        self.officialTitle = officialTitle
        self.groups = groups
        self.eventType = eventType
        self.status = status
        self.primarySourceURL = primarySourceURL
        self.timeZone = timeZone
    }

    /// The event's home time zone, per DESIGN.md 四.4: dates must always be
    /// formatted in the organizer's time zone first.
    public var resolvedTimeZone: TimeZone {
        TimeZone(identifier: timeZone) ?? TimeZone(identifier: "UTC")!
    }
}
