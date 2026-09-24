import Foundation
import LiveIngestionCore

public enum LocalPerformanceClock {
    /// Builds an absolute instant only after the venue time zone is known.
    /// A missing zone stays local; it is not assumed to be Japan.
    public static func instant(localDate: String, time: String, timeZone: TimeZone?) -> Date? {
        guard let timeZone, let clock = SessionIdentityGuard.normalizedClock(time) else { return nil }
        let dateParts = localDate.split(separator: "-")
        let clockParts = clock.split(separator: ":")
        guard dateParts.count == 3, clockParts.count == 2,
              let year = Int(dateParts[0]), let month = Int(dateParts[1]), let day = Int(dateParts[2]),
              let hour = Int(clockParts[0]), let minute = Int(clockParts[1]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))
    }
}
