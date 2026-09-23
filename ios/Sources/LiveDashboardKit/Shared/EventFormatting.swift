import Foundation

public enum EventFormatting {
    /// "9月11日 15:00 JST" style: abbreviated date, short time, short generic zone name. Uses current locale.
    public static func dateTime(_ date: Date, in timeZone: TimeZone) -> String {
        var style = Date.FormatStyle.dateTime.month().day().hour().minute().timeZone(.specificName(.short))
        style.timeZone = timeZone
        return date.formatted(style)
    }

    /// Date only, abbreviated, in the given zone (no zone suffix): "9月11日", or "2025年9月11日"
    /// with `includesYear: true` — for a date whose year isn't otherwise obvious from context.
    public static func date(_ date: Date, in timeZone: TimeZone, includesYear: Bool = false) -> String {
        var style = Date.FormatStyle.dateTime.month().day()
        if includesYear { style = style.year() }
        style.timeZone = timeZone
        return date.formatted(style)
    }

    /// Inclusive range "9月5日–6日" using Date.IntervalFormatStyle in the zone.
    public static func dateRange(_ start: Date, _ end: Date, in timeZone: TimeZone) -> String {
        var style = Date.IntervalFormatStyle(date: .abbreviated, time: .omitted)
        style.timeZone = timeZone
        return style.format(start ..< end)
    }

    /// Short generic zone label, e.g. "JST" or "GMT+9" fallback to identifier.
    public static func zoneLabel(_ timeZone: TimeZone) -> String {
        var style = Date.FormatStyle.dateTime.timeZone(.specificName(.short))
        style.timeZone = timeZone
        let formatted = Date().formatted(style)
        return formatted
    }

    /// Parses "yyyy-MM-dd" (en_US_POSIX, in the given zone) → Date; nil on failure.
    public static func parseISODate(_ string: String, in timeZone: TimeZone) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = timeZone
        return formatter.date(from: string)
    }

    /// Currency: JPY minor units are whole yen. Produces "JP¥4,400" via Decimal.FormatStyle.Currency with the current locale.
    public static func price(_ amount: Int, currencyCode: String) -> String {
        Decimal(amount).formatted(.currency(code: currencyCode))
    }

    /// Resolves a time zone identifier, falling back to `fallback` when nil/invalid.
    public static func timeZone(identifier: String?, fallback: TimeZone) -> TimeZone {
        guard let identifier, let resolved = TimeZone(identifier: identifier) else { return fallback }
        return resolved
    }
}
