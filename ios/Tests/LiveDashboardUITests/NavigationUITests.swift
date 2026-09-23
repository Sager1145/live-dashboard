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

        // Visit global card settings first, while its link is still on screen (top section) —
        // this also avoids the data-management round trip leaving the Form scrolled down when
        // we come back looking for this link.
        let cardSettings = app.buttons["globalCardSettingsLink"]
        XCTAssertTrue(cardSettings.waitForExistence(timeout: 3))
        cardSettings.tap()

        // Card rows are collapsed DisclosureGroups; anchor on accessibility identifiers rather
        // than label text so the test passes in every app language (CI runs in English). The
        // identifier lives on the group's label only, so a single tap on the group expands it
        // without also being consumed as a second (collapsing) tap on the header.
        let groupID = "cardSettingsGroup-timeAndVenue"
        let toggleID = "cardVisibilityToggle-timeAndVenue"
        let firstGroup = app.descendants(matching: .any)[groupID].firstMatch
        XCTAssertTrue(firstGroup.waitForExistence(timeout: 5))
        firstGroup.tap()
        var visibilityToggle = app.descendants(matching: .any)[toggleID].firstMatch
        if !visibilityToggle.waitForExistence(timeout: 3) {
            // Only re-tap if the group itself is not already expanded (a second tap on an
            // expanded header would collapse it again).
            let isExpanded = (firstGroup.value as? String) == "1" || firstGroup.buttons.firstMatch.value as? String == "1"
            if !isExpanded {
                let header = firstGroup.buttons.firstMatch.exists ? firstGroup.buttons.firstMatch : app.buttons[groupID].firstMatch
                if header.exists { header.tap() }
            }
            visibilityToggle = app.descendants(matching: .any)[toggleID].firstMatch
        }
        XCTAssertTrue(visibilityToggle.waitForExistence(timeout: 5),
                      "expected the visibility toggle after expanding the first card group; hierarchy: \(app.debugDescription.prefix(4000))")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let dataManagementLink = app.buttons["dataManagementLink"]
        if !dataManagementLink.waitForExistence(timeout: 3) {
            // The row sits in the last section; scroll the Form so SwiftUI lays out the cell.
            app.swipeUp()
        }
        XCTAssertTrue(dataManagementLink.waitForExistence(timeout: 3))
        dataManagementLink.tap()
        XCTAssertTrue(app.buttons["officialRefreshButton"].waitForExistence(timeout: 3))
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }
}
