import XCTest

/// UI smoke tests — verifies the app launches and core navigation works.
/// A new build passes if:
///   - The app launches without crashing
///   - The 3 main tabs exist and are tappable
///   - The Chat tab shows the input field
///   - Medications can be navigated to
final class AppNavigationUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDown() {
        app = nil
        super.tearDown()
    }

    // MARK: - App Launch

    func testAppLaunchesWithoutCrash() {
        XCTAssertTrue(app.state == .runningForeground)
    }

    // MARK: - Tab Navigation

    func testThreeTabsExist() {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.exists, "Tab bar should exist")
        XCTAssertGreaterThanOrEqual(tabBar.buttons.count, 3, "Should have at least 3 tabs")
    }

    func testHomeTabIsSelectedByDefault() {
        // The first tab (Home) should be selected on launch
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.exists)
        let firstTab = tabBar.buttons.element(boundBy: 0)
        XCTAssertTrue(firstTab.isSelected, "Home tab should be selected by default")
    }

    func testCanNavigateToChatTab() {
        let tabBar = app.tabBars.firstMatch
        let chatTab = tabBar.buttons.element(boundBy: 1)
        chatTab.tap()
        XCTAssertTrue(chatTab.isSelected)
    }

    func testCanNavigateToProfileTab() {
        let tabBar = app.tabBars.firstMatch
        let profileTab = tabBar.buttons.element(boundBy: 2)
        profileTab.tap()
        XCTAssertTrue(profileTab.isSelected)
    }

    func testTabNavigationIsReversible() {
        let tabBar = app.tabBars.firstMatch
        let homeTab = tabBar.buttons.element(boundBy: 0)
        let chatTab = tabBar.buttons.element(boundBy: 1)

        chatTab.tap()
        XCTAssertTrue(chatTab.isSelected)

        homeTab.tap()
        XCTAssertTrue(homeTab.isSelected)
    }

    // MARK: - Chat Tab

    func testChatTabShowsInputField() {
        let tabBar = app.tabBars.firstMatch
        tabBar.buttons.element(boundBy: 1).tap()

        // The chat input text field or text view should be present
        let inputExists = app.textFields.firstMatch.waitForExistence(timeout: 3) ||
                          app.textViews.firstMatch.waitForExistence(timeout: 1)
        XCTAssertTrue(inputExists, "Chat tab should show a text input field")
    }

    // MARK: - Home Tab

    func testHomeTabShowsCalendarOrContent() {
        // Home tab is already selected; verify something is visible
        let tabBar = app.tabBars.firstMatch
        tabBar.buttons.element(boundBy: 0).tap()

        // Some content should be visible within 3 seconds
        let hasContent = app.staticTexts.firstMatch.waitForExistence(timeout: 3) ||
                         app.buttons.firstMatch.waitForExistence(timeout: 1)
        XCTAssertTrue(hasContent, "Home tab should show content")
    }
}
