import XCTest

/// Covers the sidebar's emergency banner, which hands `tel:115` to the OS.
///
/// The Simulator has no phone, so `openURL` reports failure and the app shows its
/// "Unable to place call" fallback alert. That is the only branch reachable here; the
/// native "Call 115 / Cancel" sheet on a real iPhone is the OS's own UI and cannot be
/// asserted from XCUITest. The test therefore proves the banner is a live button wired
/// to the call action, not that a call goes out.
///
/// Onboarding and language are pinned via `NSArgumentDomain`, as in
/// `AppNavigationUITests`.
final class EmergencyCallUITests: XCTestCase {

    private var app: XCUIApplication!

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

    func testEmergencyBannerTriggersCallFlow() {
        let callButton = app.buttons["Call 115"]

        // On a phone the sidebar starts hidden behind the hamburger; on a wide layout it is
        // already on screen and there is no toggle.
        if !waitForHittable(callButton, timeout: 30) {
            let toggle = app.buttons["Chat history"]
            XCTAssertTrue(waitForHittable(toggle, timeout: 10), "Compact layout should offer a sidebar toggle")
            toggle.tap()
        }

        XCTAssertTrue(waitForHittable(callButton, timeout: 10), "The sidebar should show the emergency call banner")
        callButton.tap()

        // Kept as a test attachment so a failing run shows what the tester saw.
        let alertShot = XCTAttachment(screenshot: app.screenshot())
        alertShot.name = "emergency-alert"
        alertShot.lifetime = .keepAlways
        add(alertShot)

        // Simulator cannot dial, so the fallback alert is the expected outcome here.
        let alert = app.alerts["Unable to place call"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "Tapping the banner should attempt a call; the Simulator refuses tel: and the app must say so")
        XCTAssertTrue(alert.staticTexts["This device cannot place phone calls. Please use another phone to call 115."].exists)

        alert.buttons["Got it"].tap()
        XCTAssertFalse(alert.waitForExistence(timeout: 2), "Dismissing the alert should close it")
    }

    /// Like `waitForExistence`, but also requires the element to be hittable, and dismisses
    /// the Simulator-only Translation popover ("Translation is not supported on simulated
    /// devices") whenever it appears — it is presented a few seconds after launch, once the
    /// backend has initialised, and its dismiss region covers the whole chat header.
    /// Real devices never show it, so the branch is a no-op there.
    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let translationDone = app.buttons["Done"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if translationDone.exists && translationDone.isHittable {
                translationDone.tap()
            }
            if element.exists && element.isHittable { return true }
            _ = element.waitForExistence(timeout: 0.3)
        }
        return element.exists && element.isHittable
    }
}
