import XCTest

/// UI smoke tests — verifies the app launches and core navigation works.
/// A new build passes if:
///   - The app launches without crashing
///   - The 3 main tabs exist and are tappable
///   - The Chat tab shows the input field
///   - Home tab shows content on launch
///
/// iOS 18+ note: Apple replaced the classic tab bar with a floating tab bar
/// (_UIFloatingTabBarItemCell). XCTest no longer finds it via app.tabBars, so
/// tests now use app.buttons["Label"] which resolves tab items by accessibility label.
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

    // MARK: - Tab Existence

    func testThreeTabsExist() {
        XCTAssertTrue(homeTab.waitForExistence(timeout: 3), "Home tab should exist")
        XCTAssertTrue(chatTab.waitForExistence(timeout: 3), "Chat tab should exist")
        XCTAssertTrue(profileTab.waitForExistence(timeout: 3), "Profile tab should exist")
    }

    func testHomeTabIsSelectedByDefault() {
        XCTAssertTrue(homeTab.waitForExistence(timeout: 3))
        XCTAssertTrue(homeTab.isSelected, "Home tab should be selected on launch")
    }

    // MARK: - Tab Navigation

    func testCanNavigateToChatTab() {
        XCTAssertTrue(chatTab.waitForExistence(timeout: 3))
        chatTab.tap()
        XCTAssertTrue(chatTab.isSelected)
    }

    func testCanNavigateToProfileTab() {
        XCTAssertTrue(profileTab.waitForExistence(timeout: 3))
        profileTab.tap()
        XCTAssertTrue(profileTab.isSelected)
    }

    func testTabNavigationIsReversible() {
        XCTAssertTrue(chatTab.waitForExistence(timeout: 3))

        chatTab.tap()
        XCTAssertTrue(chatTab.isSelected)

        homeTab.tap()
        XCTAssertTrue(homeTab.isSelected)
    }

    // MARK: - Chat Tab

    func testChatTabShowsInputField() {
        XCTAssertTrue(chatTab.waitForExistence(timeout: 3))
        chatTab.tap()

        let inputExists = app.textFields.firstMatch.waitForExistence(timeout: 5) ||
                          app.textViews.firstMatch.waitForExistence(timeout: 1)
        XCTAssertTrue(inputExists, "Chat tab should show a text input field")
    }

    // MARK: - Home Tab

    func testHomeTabShowsCalendarOrContent() {
        // Home tab is already selected on launch
        let hasContent = app.staticTexts.firstMatch.waitForExistence(timeout: 3) ||
                         app.buttons.firstMatch.waitForExistence(timeout: 1)
        XCTAssertTrue(hasContent, "Home tab should show content")
    }
}

// MARK: - Helpers

private extension AppNavigationUITests {

    /// Resolves the Home tab item regardless of classic vs floating tab bar style.
    /// Classic (< iOS 18): app.tabBars.buttons["Home"]
    /// Floating (iOS 18+): app.buttons["Home"] at the window level
    var homeTab: XCUIElement {
        tabItem(label: "Home")
    }

    var chatTab: XCUIElement {
        tabItem(label: "Chat")
    }

    var profileTab: XCUIElement {
        tabItem(label: "Profile")
    }

    func tabItem(label: String) -> XCUIElement {
        // Prefer the classic tab bar button when available (pre-iOS 18)
        let classicBar = app.tabBars.firstMatch
        if classicBar.exists {
            let btn = classicBar.buttons[label]
            if btn.exists { return btn }
        }
        // Fall back to direct button lookup used by iOS 18 floating tab bar
        return app.buttons[label]
    }
}
