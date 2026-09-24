import Foundation

/// An inclusive calendar month based on the date currently shown by the phone.
public enum LocalRefreshPolicy {
    public static func cutoff(now: Date, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day = calendar.startOfDay(for: now)
        let date = calendar.date(byAdding: .month, value: -1, to: day)!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    public static func phoneDay(now: Date, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: now)
    }

    public static func isArchived(_ bundle: LiveEventBundle, cutoff: String) -> Bool {
        hasEnded(bundle, before: cutoff)
    }

    /// True when every performance has a known local date and the last one is before `day` (yyyy-MM-dd).
    /// An unknown date or any later tour stop keeps the event current.
    public static func hasEnded(_ bundle: LiveEventBundle, before day: String) -> Bool {
        guard !bundle.performances.isEmpty,
              bundle.performances.allSatisfy({ $0.localDate != nil }),
              let last = bundle.performances.compactMap(\.localDate).max() else { return false }
        return last < day
    }
}
