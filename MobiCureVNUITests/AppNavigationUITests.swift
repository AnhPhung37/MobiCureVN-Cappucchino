import XCTest

/// UI smoke tests for the navigation reworked in #54.
///
/// These previously asserted a three-tab tab bar. The app has never had one, so all six tab
/// tests failed on every run and the two that passed did so vacuously. They now describe the
/// real structure:
///
///     Chat (root — the main screen)
///       ├── header ▸ house  → Home (sheet: care notes, warning signs, remembered facts,
///       │                     wound photos, data source)
///       │                     └── toolbar ▸ profile → ProfileView
///       └── header ▸ avatar → ProfileView (sheet)
///
/// Onboarding is skipped with a launch argument rather than an app-side test hook:
/// `UserDefaults` consults `NSArgumentDomain` first, so `-hasCompletedOnboarding YES`
/// overrides the `@AppStorage` default for the launched process only, leaving no test-only
/// branch in shipping code. The language is pinned the same way so assertions do not depend on
/// whichever language a previous run happened to leave stored.
final class AppNavigationUITests: XCTestCase {

    private var app: XCUIApplication!

    /// The chat composer, matched by placeholder rather than `textFields.firstMatch`, which can
    /// also resolve the sidebar's conversation-search field on a wide layout.
    private var chatComposer: XCUIElement {
        app.textFields["Describe your symptoms or ask a question..."]
    }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-hasCompletedOnboarding", "YES",
            "-appLanguage", "en"
        ]
        app.launch()
    }

    override func tearDown() {
        app = nil
        super.tearDown()
    }

    /// Swipes up until `label` is on screen, or gives up after a bounded number of tries.
    private func scrollToStaticText(_ label: String, maxSwipes: Int = 6) -> Bool {
        let element = app.staticTexts[label]
        for _ in 0..<maxSwipes {
            if element.exists && element.isHittable { return true }
            app.swipeUp()
        }
        return element.exists
    }

    /// Opens Home from the chat header and waits for it to be on screen.
    @discardableResult
    private func openHome() -> Bool {
        // "Home" because setUp pins the language to English; the button's accessibility
        // label is resolved through `.localized(for:)` in ChatWorkspaceView, so it follows
        // that setting rather than staying Vietnamese.
        let homeButton = app.buttons["Home"]
        guard homeButton.waitForExistence(timeout: 30) else { return false }
        guard homeButton.waitForHittable(timeout: 10) else { return false }
        homeButton.tap()
        return app.staticTexts["Home"].waitForExistence(timeout: 10)
    }

    // MARK: - Launch

    func testAppLaunchesWithoutCrash() {
        XCTAssertTrue(app.state == .runningForeground)
    }

    /// Chat is the main screen: a patient opening the app is usually here to ask something.
    /// The timeout is generous because `ChatViewModel` spins up the on-device backend on
    /// launch, and CI runs several simulator clones on one machine.
    func testChatIsTheRootScreen() {
        XCTAssertTrue(
            chatComposer.waitForExistence(timeout: 30),
            "Chat should be the first screen after onboarding, with its composer ready"
        )
    }

    // MARK: - Home

    func testHomeOpensFromTheChatHeader() {
        XCTAssertTrue(openHome(), "The chat header should offer a way into Home")
    }

    /// Home's whole purpose in #54 is surfacing these five fields. If one silently stops
    /// rendering, the screen still "shows content" — so each is asserted by name.
    func testHomeShowsEveryRealDataCard() {
        XCTAssertTrue(openHome())

        for title in ["Care notes", "Warning signs", "What the assistant remembers about you"] {
            XCTAssertTrue(
                app.staticTexts[title].waitForExistence(timeout: 5),
                "Home should show the “\(title)” card"
            )
        }

        // The last two sit below the fold on a phone. Scroll until each appears rather than
        // swiping once: a single swipe travels a different distance depending on how much the
        // cards above it wrapped, and under parallel-simulator load it can land short.
        for title in ["Wound photos", "Data source"] {
            XCTAssertTrue(
                scrollToStaticText(title),
                "Home should show the “\(title)” card"
            )
        }
    }

    /// The mockup this screen replaced hardcoded a patient name, a 256-day streak and a
    /// "Dr. Schmitz" appointment. Nothing invented may come back.
    func testHomeShowsNoFabricatedContent() {
        XCTAssertTrue(openHome())

        for fake in ["Chào Nam,", "256 days STRONG", "Dr. Schmitz", "Remind Calendar", "Your Journey"] {
            XCTAssertFalse(app.staticTexts[fake].exists, "“\(fake)” is mockup data and must not appear")
        }
    }

    func testClosingHomeReturnsToChat() {
        XCTAssertTrue(openHome())

        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(close.waitForHittable(timeout: 10), "Home should offer a close button")
        close.tap()

        XCTAssertTrue(
            chatComposer.waitForExistence(timeout: 15),
            "Closing Home should return to the conversation"
        )
    }

    // MARK: - Profile

    func testProfileOpensFromHome() {
        XCTAssertTrue(openHome())

        // Scoped to Home's navigation bar: chat's header avatar carries the same "Profile"
        // label, and an unscoped query can resolve that one instead — it is still in the tree
        // behind the Home sheet, and tapping it does nothing.
        let profileButton = app.navigationBars["Home"].buttons["Profile"]
        XCTAssertTrue(profileButton.waitForHittable(timeout: 10), "Home's toolbar should offer Profile")
        profileButton.tap()

        XCTAssertTrue(
            app.navigationBars["Profile"].waitForExistence(timeout: 10),
            "Tapping the toolbar button should present Profile"
        )
    }
}

private extension XCUIElement {
    /// `waitForExistence` only proves an element is in the tree — it can still be behind a
    /// sheet, a scrim, or an open sidebar. Tapping one of those does nothing useful, so waits
    /// that precede a tap should use this instead.
    func waitForHittable(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if exists && isHittable { return true }
            _ = waitForExistence(timeout: 0.3)
        }
        return exists && isHittable
    }
}
