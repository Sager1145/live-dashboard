import XCTest

final class NavigationUITests: XCTestCase {
    @MainActor
    func testLocalCollectionAndGlobalCardSettingsAreReachable() {
        let app = XCUIApplication()
        app.launch()

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5))
        XCTAssertEqual(tabBar.buttons.count, 4)

        tabBar.buttons.element(boundBy: 3).tap()
        XCTAssertFalse(app.textFields["apiBaseURLField"].exists)
        XCTAssertTrue(app.buttons["officialRefreshButton"].waitForExistence(timeout: 3))

        let cardSettings = app.buttons["globalCardSettingsLink"]
        XCTAssertTrue(cardSettings.waitForExistence(timeout: 3))
        cardSettings.tap()

        // Card rows are collapsed DisclosureGroups; anchor on accessibility identifiers rather
        // than label text so the test passes in every app language (CI runs in English).
        let groupID = "cardSettingsGroup-timeAndVenue"
        let toggleID = "cardVisibilityToggle-timeAndVenue"
        let firstGroup = app.descendants(matching: .any)[groupID].firstMatch
        XCTAssertTrue(firstGroup.waitForExistence(timeout: 5))
        firstGroup.tap()
        var visibilityToggle = app.descendants(matching: .any)[toggleID].firstMatch
        if !visibilityToggle.waitForExistence(timeout: 3) {
            // The identifier may land on the group's container; tap its header button instead.
            let header = firstGroup.buttons.firstMatch.exists ? firstGroup.buttons.firstMatch : app.buttons[groupID].firstMatch
            if header.exists { header.tap() }
            visibilityToggle = app.descendants(matching: .any)[toggleID].firstMatch
        }
        XCTAssertTrue(visibilityToggle.waitForExistence(timeout: 5),
                      "expected the visibility toggle after expanding the first card group; hierarchy: \(app.debugDescription.prefix(4000))")
    }
}
