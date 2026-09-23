import XCTest
@testable import LiveDashboardKit

/// Pins `CardType.supportedFields` to the fields each card view actually
/// reads via `CardConfiguration.shows(_:)` (grepped from OverviewView,
/// TicketsView, GoodsView). If a card view starts or stops checking a field,
/// this test forces `supportedFields` to be updated alongside it — otherwise
/// `CardSettingsView` would offer dead or missing toggles.
final class CardConfigurationSupportedFieldsTests: XCTestCase {
    func testSupportedFieldsMirrorsCardViewShowsCalls() {
        let expected: [CardType: [CardField]] = [
            .assistantSummary: [],
            .timeAndVenue: [.time, .place],
            .performers: [],
            .pricing: [.price],
            .admission: [.eligibility],
            .ticketRound: [.time, .price, .eligibility, .source],
            .streamOffer: [.time, .place, .price, .eligibility, .source],
            .ticketBenefit: [.time, .place, .price, .source],
            .eventSeatingMap: [],
            .venueGenericSeatingMap: [],
            .goodsCampaign: [.time, .place, .price, .eligibility, .source]
        ]

        for type in CardType.allCases {
            XCTAssertEqual(type.supportedFields, expected[type] ?? [], "supportedFields mismatch for \(type)")
        }
    }

    func testSupportedFieldsAreOrderedLikeCardFieldAllCases() {
        for type in CardType.allCases {
            let indices = type.supportedFields.map { CardField.allCases.firstIndex(of: $0)! }
            XCTAssertEqual(indices, indices.sorted(), "\(type) supportedFields must follow CardField.allCases order")
        }
    }
}
