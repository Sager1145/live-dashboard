import XCTest

final class NavigationUITests: XCTestCase {
    @MainActor
    func testLocalCollectionAndGlobalCardSettingsAreReachable() {
        let app = XCUIApplication()
        app.launch()

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5))
        XCTAssertEqual(tabBar.buttons.count, 3)

        tabBar.buttons.element(boundBy: 2).tap()
        XCTAssertFalse(app.textFields["apiBaseURLField"].exists)
        XCTAssertTrue(app.buttons["officialRefreshButton"].waitForExistence(timeout: 3))

        let cardSettings = app.buttons["globalCardSettingsLink"]
        XCTAssertTrue(cardSettings.waitForExistence(timeout: 3))
        cardSettings.tap()

        // The Global Card Settings screen renders a List of collapsed DisclosureGroups
        // (one per CardType); no Toggle exists until a group is expanded. Wait for the
        // screen itself first, anchoring on the first list cell by position rather than
        // by label text: the app's SwiftUI string literals are localized (the simulator
        // here runs in English, so "时间与会场" actually renders as "Time and Venue"),
        // so a hard-coded label in either language would be locale-fragile. There is no
        // accessibility identifier on the disclosure rows to key off instead, so we use
        // the first `.cell` element on screen, which is stable across locales.
        let firstCardTypeRow = app.cells.element(boundBy: 0)
        XCTAssertTrue(firstCardTypeRow.waitForExistence(timeout: 3))
        firstCardTypeRow.tap()
        XCTAssertTrue(app.switches.firstMatch.waitForExistence(timeout: 3))
    }
}
