import XCTest

@MainActor
final class IdeaForgeWatchUITests: XCTestCase {
    nonisolated(unsafe) private var app: XCUIApplication!

    nonisolated override func setUpWithError() throws {
        continueAfterFailure = false
        let testName = name
        app = MainActor.assumeIsolated {
            let application = XCUIApplication()
            application.launchArguments = ["-uiTesting"]
            if testName.contains("Queued") {
                application.launchArguments.append("-uiTestingWatchQueued")
            } else if testName.contains("Received") {
                application.launchArguments.append("-uiTestingWatchReceived")
            } else if testName.contains("Failed") {
                application.launchArguments.append("-uiTestingWatchFailed")
            } else {
                application.launchArguments.append("-uiTestingWatchReady")
            }
            if testName.contains("AccessibilityXXXL") {
                application.launchArguments.append("-uiTestingAccessibilityXXXL")
            }
            application.launch()
            return application
        }
    }

    nonisolated override func tearDownWithError() throws {
        app = nil
    }

    func testReadyRelayKeepsPrimaryCaptureActionVisible() {
        assertRelay(value: "Ready on Watch. Works without iPhone")
        XCTAssertTrue(app.buttons["watch.capture.record"].isHittable)
        captureEvidence(named: "watch-ready")
    }

    func testQueuedRelayUsesPersistentPendingTruth() {
        assertRelay(value: "Waiting for iPhone. Safe to retry later")
        XCTAssertTrue(app.buttons["watch.capture.record"].isHittable)
        captureEvidence(named: "watch-queued")
    }

    func testReceivedRelaySurvivesRelaunchFromPersistentReceipt() {
        assertRelay(value: "Received on iPhone. Import acknowledged")
        captureEvidence(named: "watch-received")
    }

    func testFailedRelayKeepsAudioSafetyTruthVisible() {
        assertRelay(value: "Kept on Watch. Send needs attention")
        let savedSetup = app.buttons["watch.capture.savedSetup"]
        if !savedSetup.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(savedSetup.waitForExistence(timeout: 3))
        XCTAssertTrue(savedSetup.isHittable)
        captureEvidence(named: "watch-failed")
    }

    func testAccessibilityXXXLReadyRelayKeepsPrimaryActionReachable() {
        assertRelay(value: "Ready on Watch. Works without iPhone")
        XCTAssertTrue(app.buttons["watch.capture.record"].isHittable)
        captureEvidence(named: "watch-accessibility-xxxl")
    }

    private func assertRelay(value expectedValue: String) {
        let relay = app.descendants(matching: .any)["watch.capture.relay"]
        XCTAssertTrue(relay.waitForExistence(timeout: 8))
        XCTAssertEqual(relay.label, "Capture relay")
        XCTAssertEqual(relay.value as? String, expectedValue)
    }

    private func captureEvidence(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
