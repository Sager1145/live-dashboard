import Foundation
import Testing
@testable import LiveDashboardKit

struct EventFormattingTests {
    private var tokyo: TimeZone { TimeZone(identifier: "Asia/Tokyo")! }

    @Test func dateTimeContainsZoneTokenAndHour() {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 11
        components.hour = 15
        components.minute = 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tokyo
        let date = calendar.date(from: components)!

        let formatted = EventFormatting.dateTime(date, in: tokyo)
        #expect(formatted.contains("15"))
        #expect(formatted.contains("JST") || formatted.contains("GMT+9"))
    }

    @Test func parseISODateRoundTrips() {
        let string = "2026-09-11"
        let date = EventFormatting.parseISODate(string, in: tokyo)
        #expect(date != nil)
        if let date {
            let formatted = EventFormatting.date(date, in: tokyo)
            #expect(!formatted.isEmpty)
        }
    }

    @Test func priceFormatsYen() {
        let formatted = EventFormatting.price(4400, currencyCode: "JPY")
        #expect(formatted.contains("4,400") || formatted.contains("4400"))
        #expect(formatted.contains("¥"))
    }

    @Test func timeZoneFallsBackOnBogusIdentifier() {
        let fallback = TimeZone(identifier: "Asia/Tokyo")!
        let resolved = EventFormatting.timeZone(identifier: "bogus", fallback: fallback)
        #expect(resolved == fallback)
    }
}
