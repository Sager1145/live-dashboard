import Foundation

/// A specific date/session of a `LiveEvent`. IDs are stable and never derived
/// from the date — a postponement updates `localDate`/`startAt` in place while
/// keeping the same `id`, follow state, and reminders.
public struct Performance: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let eventID: String
    public let stopID: String?
    public let dayLabel: String
    public let subtitle: String?
    public let localDate: String?
    public let rawDate: String?
    public let precision: TimePrecision?
    public let timeZone: String?
    public let doorsAt: Date?
    public let startAt: Date?
    public let venueName: String
    public let venueCity: String
    public let performers: [String]
    public let order: Int
    public let editionID: String?

    public init(
        id: String,
        eventID: String,
        stopID: String?,
        dayLabel: String,
        subtitle: String?,
        localDate: String?,
        doorsAt: Date?,
        startAt: Date?,
        venueName: String,
        venueCity: String,
        performers: [String],
        order: Int,
        editionID: String? = nil,
        rawDate: String? = nil,
        precision: TimePrecision = .date,
        timeZone: String? = nil
    ) {
        self.id = id
        self.eventID = eventID
        self.stopID = stopID
        self.dayLabel = dayLabel
        self.subtitle = subtitle
        self.localDate = localDate
        self.rawDate = rawDate
        self.precision = precision
        self.timeZone = timeZone
        self.doorsAt = doorsAt
        self.startAt = startAt
        self.venueName = venueName
        self.venueCity = venueCity
        self.performers = performers
        self.order = order
        self.editionID = editionID
    }

    public var editionIDValue: String? { editionID }
}

public enum TimePrecision: String, Codable, Hashable, Sendable {
    case minute, date, month, range, unknown
}
