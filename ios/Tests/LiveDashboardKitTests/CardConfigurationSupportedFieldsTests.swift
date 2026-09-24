import XCTest
@testable import LiveDashboardKit

/// The settings matrix lives only on `CardType.supportedFields`.
/// `CardSettingsView.offeredFields(for:)` must return that same value —
/// a second handwritten list here would drift from the toggles the UI shows.
final class CardConfigurationSupportedFieldsTests: XCTestCase {
    func testSettingsOffersTheSupportedFieldMapping() {
        for type in CardType.allCases {
            XCTAssertEqual(
                CardSettingsView.offeredFields(for: type),
                type.supportedFields,
                "card settings must list CardType.supportedFields for \(type)"
            )
            XCTAssertEqual(Set(type.supportedFields).count, type.supportedFields.count, "\(type) repeats a field")
            XCTAssertTrue(type.supportedFields.allSatisfy { CardField.allCases.contains($0) })
        }
    }

    func testSupportedFieldsAreOrderedLikeCardFieldAllCases() {
        for type in CardType.allCases {
            let indices = type.supportedFields.map { CardField.allCases.firstIndex(of: $0)! }
            XCTAssertEqual(indices, indices.sorted(), "\(type) supportedFields must follow CardField.allCases order")
        }
    }

    func testLegacyEmptySetStillShowsEveryField() {
        let config = CardConfiguration(cardType: .timeAndVenue, entityID: CardConfiguration.globalEntityID)
        for field in CardField.allCases {
            XCTAssertTrue(config.shows(field))
        }
    }

    func testFirstToggleKeepsUnknownKeysAndOtherSupportedFields() {
        var config = CardConfiguration(
            cardType: .timeAndVenue,
            entityID: CardConfiguration.globalEntityID,
            visibleFields: ["historical-unknown", CardField.price.rawValue]
        )
        config.setShows(.place, enabled: false)

        XCTAssertTrue(config.visibleFields.contains("historical-unknown"))
        XCTAssertTrue(config.visibleFields.contains(CardField.price.rawValue))
        XCTAssertTrue(config.visibleFields.contains(CardField.configuredMarker))
        XCTAssertTrue(config.visibleFields.contains(CardField.time.rawValue))
        XCTAssertFalse(config.shows(.place))
        XCTAssertTrue(config.shows(.time))
        XCTAssertEqual(config.cardType, .timeAndVenue)
        XCTAssertEqual(config.entityID, CardConfiguration.globalEntityID)
        XCTAssertNil(config.eventID)
    }

    func testConfiguredToggleDoesNotDropUnknownOrUnsupportedKeys() {
        var config = CardConfiguration(
            cardType: .timeAndVenue,
            entityID: CardConfiguration.globalEntityID,
            isHidden: true,
            visibleFields: [
                CardField.configuredMarker,
                CardField.time.rawValue,
                CardField.place.rawValue,
                CardField.price.rawValue,
                "historical-unknown"
            ]
        )
        config.setShows(.time, enabled: false)
        config.isHidden = false

        XCTAssertTrue(config.visibleFields.contains("historical-unknown"))
        XCTAssertTrue(config.visibleFields.contains(CardField.price.rawValue))
        XCTAssertTrue(config.visibleFields.contains(CardField.place.rawValue))
        XCTAssertTrue(config.visibleFields.contains(CardField.configuredMarker))
        XCTAssertFalse(config.shows(.time))
        XCTAssertTrue(config.shows(.place))
        XCTAssertFalse(config.isHidden)
    }
}
