import Foundation

/// A specific date/session of a `LiveEvent`. IDs are stable and never derived
/// from the date — a postponement updates `localDate`/`startAt` in place while
/// keeping the same `id`, follow state, and reminders.
public enum PerformanceActivity: String, Codable, Hashable, Sendable {
    /// A timed live performance. Missing clocks use the existing 开演 copy.
    case performance
    /// A multi-day or single-day exhibition. Open hours are not a start time.
    case exhibition
    /// A timed handover / お渡し会. Its clocks must not be copied onto the exhibition.
    case handover
}

public struct Performance: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let eventID: String
    public let stopID: String?
    public let dayLabel: String
    public let subtitle: String?
    public let localDate: String?
    /// Inclusive end of a 会期. Nil means the record is a single day.
    public let localEndDate: String?
    public let activityKind: PerformanceActivity?
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
        timeZone: String? = nil,
        localEndDate: String? = nil,
        activityKind: PerformanceActivity? = nil
    ) {
        self.id = id
        self.eventID = eventID
        self.stopID = stopID
        self.dayLabel = dayLabel
        self.subtitle = subtitle
        self.localDate = localDate
        self.localEndDate = localEndDate
        self.activityKind = activityKind
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

    /// Inclusive. ISO dates compare in calendar order. A nil `localDate` covers nothing.
    public func covers(localDate day: String) -> Bool {
        guard let start = localDate else { return false }
        let end = localEndDate ?? start
        return day >= start && day <= end
    }

    public var periodEndLocalDate: String? { localEndDate ?? localDate }

    public var editionIDValue: String? { editionID }
}

public enum TimePrecision: String, Codable, Hashable, Sendable {
    case minute, date, month, range, unknown
}

/// One stored performer string is one line. A newline inside that string is
/// an unsplit roster, not a single name. Commas, slashes and middle dots stay
/// inside the name: group names and role notes use them.
public enum PerformerLines {
    public static func expandingNewlines(_ performers: [String]) -> [String] {
        performers.flatMap { name -> [String] in
            guard name.contains(where: \.isNewline) else { return [name] }
            return name.split(whereSeparator: \.isNewline).map { line in
                line.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
        }
    }
}
