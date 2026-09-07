import XCTest
import UIKit
import CoreImage

@MainActor
final class IdeaForgeiOSUITests: XCTestCase {
    nonisolated(unsafe) private var app: XCUIApplication!

    nonisolated override func setUpWithError() throws {
        let testName = name
        continueAfterFailure = false
        app = MainActor.assumeIsolated {
            let application = XCUIApplication()
            application.launchArguments = ["-uiTesting"]
            if testName.contains("RecordingPermissionDenied") {
                application.launchArguments.append("-uiTestingRecordingPermissionDenied")
            }
            if testName.contains("RecoveredRecording"), !testName.contains("VisualEvidence") {
                application.launchArguments.append("-uiTestingRecoveredRecording")
            }
            if testName.contains("AccountPublishWorkspaceExplainsCapabilityGate") {
                application.launchArguments.append("-uiTestingCapabilityGate")
            }
            if testName.contains("LocalEnrichment") {
                application.launchArguments.append("-uiTestingLocalEnrichment")
                application.launchArguments.append("-uiTestingFoundationUnavailable")
            }
            if testName.contains("LocalBackend") {
                application.launchArguments.append("-uiTestingLocalBackend")
            }
            if testName.contains("MixedLocalEnrichmentOutcome") {
                application.launchArguments.append("-uiTestingMixedEnrichmentOutcome")
            }
            if let fixtureArgument = Self.visualFixtureArgument(for: testName) {
                application.launchArguments.append(fixtureArgument)
            }
            if Self.expectsDarkAppearance(for: testName) {
                application.launchArguments.append("-uiTestingDarkAppearance")
            }
            application.launch()
            return application
        }
    }

    nonisolated override func tearDownWithError() throws {
        app = nil
    }

    nonisolated private static func visualFixtureArgument(for testName: String) -> String? {
        if testName.contains("VisualEvidenceCapturesForegroundFixtureClean") { return "-uiTestingClean" }
        if testName.contains("VisualEvidenceCapturesForegroundFixtureQueued") { return "-uiTestingQueuedUpload" }
        if testName.contains("VisualEvidenceCapturesForegroundFixtureFailed") { return "-uiTestingFailedUpload" }
        if testName.contains("VisualEvidenceCapturesForegroundFixtureOffline") { return "-uiTestingOfflineWatch" }
        if testName.contains("VisualEvidenceCapturesForegroundFixtureConflict") { return "-uiTestingSyncConflict" }
        if testName.contains("VisualEvidenceCapturesForegroundFixtureRecoveredReduceMotion") {
            return "-uiTestingRecoveredRecording"
        }
        return nil
    }

    nonisolated private static func expectsDarkAppearance(for testName: String) -> Bool {
        testName.contains("VisualEvidenceCapturesForegroundFixtureFailed")
            || testName.contains("VisualEvidenceCapturesForegroundFixtureConflict")
    }

    func testTaskFirstInboxHierarchy() {
        XCTAssertTrue(app.navigationBars["Recording Inbox"].waitForExistence(timeout: 5))

        XCTAssertEqual(elements(identifier: "ios.inbox.statusBanner").count, 1)
        XCTAssertEqual(elements(identifier: "ios.inbox.captureAction").count, 1)
        XCTAssertEqual(app.buttons["ios.inbox.captureAction"].value as? String, "Ready for local capture")
        XCTAssertTrue(app.descendants(matching: .any)["ios.inbox.recordingList"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["ios.inbox.recordInline"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["ios.syncOverview"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["ios.inbox.syncCard"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["ios.inbox.uploadQueueCard"].exists)

        let newestRow = app.buttons["ios.inbox.recordingRow.rec_watch_2"]
        let olderRow = app.buttons["ios.inbox.recordingRow.rec_watch_1"]
        XCTAssertTrue(scrollUntilExists(newestRow))
        XCTAssertEqual(newestRow.label, "IdeaForge recording")
        XCTAssertTrue((newestRow.value as? String)?.contains("96 seconds") == true)
        XCTAssertTrue((newestRow.value as? String)?.contains("On iPhone") == true)
        if let value = newestRow.value as? String {
            assertRecordingValueHasExactlyOneState(value)
        }
        XCTAssertTrue(scrollUntilExists(olderRow, maxSwipes: 4))
        if newestRow.exists {
            XCTAssertLessThan(newestRow.frame.minY, olderRow.frame.minY)
        }
    }

    func testTaskFirstInboxStatusPriority() {
        assertInboxStatus(arguments: ["-uiTestingSyncConflict"], title: "Sync conflict", action: "Resolve")
        assertInboxStatus(arguments: ["-uiTestingFailedUpload"], title: "1 upload failed", action: "Review")
        assertInboxStatus(arguments: ["-uiTestingQueuedUpload"], title: "1 recording waiting", action: "Upload")
        assertInboxStatus(arguments: ["-uiTestingOfflineWatch"], title: "Watch offline", action: nil)

        relaunch(with: ["-uiTestingClean"])
        XCTAssertTrue(app.navigationBars["Recording Inbox"].waitForExistence(timeout: 5))
        XCTAssertEqual(elements(identifier: "ios.inbox.statusBanner").count, 0)
        XCTAssertEqual(elements(identifier: "ios.inbox.captureAction").count, 1)
        XCTAssertTrue(app.staticTexts["No recordings yet"].exists)
        XCTAssertTrue(app.staticTexts["Record an idea to start your Inbox."].exists)
    }

    func testTaskFirstFailureAccessibilitySemantics() throws {
        relaunch(with: ["-uiTestingFailedUpload"])
        XCTAssertTrue(app.navigationBars["Recording Inbox"].waitForExistence(timeout: 5))

        let banner = app.descendants(matching: .any)["ios.inbox.statusBanner.content"]
        XCTAssertTrue(banner.exists)
        XCTAssertEqual(banner.label, "Upload status")
        XCTAssertEqual(banner.value as? String, "1 upload failed")

        let review = app.buttons["ios.inbox.statusBanner.action"]
        XCTAssertEqual(review.label, "Review")
        XCTAssertGreaterThanOrEqual(review.frame.height, 44)

        let row = app.buttons["ios.inbox.recordingRow.rec_task_first_upload"]
        XCTAssertTrue(scrollUntilFullyVisible(row))
        XCTAssertEqual(row.label, "Task-first fixture recording")
        XCTAssertGreaterThanOrEqual(row.frame.height, 44)
        let recordingValue = try XCTUnwrap(row.value as? String)
        let durationPrefix = "42 seconds, "
        let stateSuffix = ", Failed"
        XCTAssertTrue(recordingValue.hasPrefix(durationPrefix))
        XCTAssertTrue(recordingValue.hasSuffix(stateSuffix))
        let relativeDateStart = recordingValue.index(recordingValue.startIndex, offsetBy: durationPrefix.count)
        let relativeDateEnd = recordingValue.index(recordingValue.endIndex, offsetBy: -stateSuffix.count)
        let relativeDateValue = String(recordingValue[relativeDateStart..<relativeDateEnd])
        let relativeDate = app.staticTexts["ios.inbox.recordingDate.rec_task_first_upload"]
        XCTAssertTrue(relativeDate.exists)
        XCTAssertFalse(relativeDateValue.isEmpty)
        XCTAssertEqual(relativeDateValue, relativeDate.label)
        assertRecordingValueHasExactlyOneState(recordingValue)

        row.tap()
        XCTAssertTrue(app.navigationBars["Recording Details"].waitForExistence(timeout: 5))

        let uploadStatus = app.descendants(matching: .any)["ios.recordingDetail.uploadStatus"]
        let detailList = app.descendants(matching: .any)["ios.recordingDetail.list"]
        XCTAssertTrue(scroll(detailList, until: uploadStatus, maxSwipes: 2))
        XCTAssertEqual(uploadStatus.label, "Upload status")
        XCTAssertEqual(uploadStatus.value as? String, "Failed")

        let retry = app.buttons["ios.recordingDetail.retryUpload"]
        XCTAssertEqual(retry.label, "Retry upload")
        XCTAssertGreaterThanOrEqual(retry.frame.height, 44)
    }

    func testPrimaryTabsExposeProductionWorkflowSurfaces() {
        XCTAssertTrue(app.navigationBars["Recording Inbox"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["ios.inbox.captureAction"].exists)
        XCTAssertFalse(app.buttons["ios.inbox.record"].exists)
        XCTAssertFalse(app.buttons["ios.inbox.recordInline"].exists)
        XCTAssertFalse(app.buttons["ios.inbox.uploadInline"].exists)
        XCTAssertFalse(app.buttons["ios.inbox.syncInline"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["ios.syncOverview"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["ios.inbox.syncCard"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["ios.inbox.uploadQueueCard"].exists)
        XCTAssertEqual(elements(identifier: "ios.inbox.statusBanner").count, 1)
        XCTAssertTrue(scrollUntilExists(app.buttons["ios.inbox.recordingRow.rec_watch_2"]))

        app.tabBars.buttons["Ideas"].tap()
        XCTAssertTrue(app.navigationBars["Idea Projects"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["ios.project.row.idea_ideaforge"].exists)

        app.tabBars.buttons["Questions"].tap()
        XCTAssertTrue(app.navigationBars["Pending Questions"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Who is the first user who needs this badly enough to pay?"].exists)

        XCTAssertTrue(openAccountTab())

        XCTAssertTrue(scrollUntilExists(app.descendants(matching: .any)["ios.syncOverview"]))
        XCTAssertTrue(scrollUntilExists(app.descendants(matching: .any)["ios.syncHandoffSummary"]))
        XCTAssertTrue(scrollUntilExists(app.descendants(matching: .any)["ios.syncTrust"]))
        XCTAssertTrue(scrollUntilExists(app.descendants(matching: .any)["ios.syncTrust.local"]))
        XCTAssertTrue(scrollUntilExists(app.descendants(matching: .any)["ios.syncTrust.receipt"]))
        XCTAssertTrue(scrollUntilExists(app.descendants(matching: .any)["ios.syncTrust.mac"]))
        XCTAssertTrue(scrollUntilExists(app.descendants(matching: .any)["ios.syncTrust.blocker"]))
        XCTAssertTrue(scrollUntilExists(app.descendants(matching: .any)["ios.syncHandoffStatus"]))
        XCTAssertTrue(scrollUntilExists(app.descendants(matching: .any)["ios.syncReadiness"]))
        XCTAssertTrue(scrollUntilExists(app.descendants(matching: .any)["ios.syncNextStep"]))
        XCTAssertTrue(scrollUntilExists(app.descendants(matching: .any)["ios.syncAutoPlan"]))
        XCTAssertTrue(scrollUntilExists(app.descendants(matching: .any)["ios.syncLastActivity"]))
        XCTAssertTrue(scrollUntilExists(app.descendants(matching: .any)["ios.syncRoute"]))
        XCTAssertTrue(scrollUntilExists(app.descendants(matching: .any)["ios.syncRoute.watch"]))
        XCTAssertTrue(scrollUntilExists(app.descendants(matching: .any)["ios.syncRoute.iphone"]))
        XCTAssertTrue(scrollUntilExists(app.descendants(matching: .any)["ios.syncRoute.backend"]))
        XCTAssertTrue(scrollUntilExists(app.descendants(matching: .any)["ios.syncRoute.mac"]))
        XCTAssertTrue(app.staticTexts["Next: Fix failed sync items"].exists)
        XCTAssertTrue(app.staticTexts["Auto-sync off"].exists)
        XCTAssertTrue(app.staticTexts["Open Account"].exists)
        XCTAssertTrue(scrollUntilExists(app.buttons["ios.account.syncOverview.syncWorkspace"]))
        XCTAssertTrue(scrollUntilExists(app.buttons["ios.account.syncOverview.secondary"]))
        XCTAssertTrue(scrollUntilExists(app.buttons["ios.account.processLocalSpeech"]))
        XCTAssertTrue(openSubscriptionSettings(in: app.descendants(matching: .any)["ios.account.scroll"]))
        XCTAssertTrue(scrollUntilExists(purchaseControl()))
        XCTAssertTrue(scrollUntilExists(app.descendants(matching: .any)["ios.account.restorePurchases.detail"]))
        XCTAssertTrue(scrollUntilExists(app.buttons["ios.account.refreshUsage.detail"]))
    }

    func testQuietSignalDoesNotExposeSettingsOrAdminSurfaces() {
        XCTAssertTrue(app.navigationBars["Recording Inbox"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["ios.inbox.settings"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["ios.account.backendConnectionKind"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["ios.account.privacyMode"].exists)
        XCTAssertFalse(app.buttons["ios.account.processLocalSpeech"].exists)
        XCTAssertFalse(app.buttons["ios.account.subscriptionSettings"].exists)
        XCTAssertFalse(app.buttons["ios.account.advancedDiagnostics"].exists)
        XCTAssertFalse(app.textFields["ios.account.backendWorkspaceID"].exists)
        XCTAssertFalse(app.staticTexts["GitHub export"].exists)
        XCTAssertFalse(app.staticTexts["Codex packet export"].exists)
    }

    func testMacConnectionIsAFocusedPairingFlow() {
        XCTAssertTrue(app.navigationBars["Recording Inbox"].waitForExistence(timeout: 5))
        let connect = app.buttons["ios.inbox.connectMac"]
        XCTAssertTrue(connect.exists)
        connect.tap()

        XCTAssertTrue(app.navigationBars["Connect to Mac"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.secureTextFields["ios.macConnection.pairingCode"].exists)
        XCTAssertTrue(app.buttons["ios.macConnection.pair"].exists)
        XCTAssertFalse(app.textFields["ios.account.backendWorkspaceID"].exists)
        XCTAssertFalse(app.textFields["https://api.example.com"].exists)
    }

    func testInboxOwnsTheWorkFlowAndPullToRefreshRunsFullSync() {
        XCTAssertTrue(app.navigationBars["Recording Inbox"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.tabBars.count, 0)
        XCTAssertFalse(app.buttons["ios.inbox.settings"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["ios.syncOverview"].exists)
        XCTAssertFalse(app.buttons["ios.inbox.syncNow"].exists)
        XCTAssertTrue(app.buttons["ios.inbox.connectMac"].exists)
        XCTAssertFalse(app.buttons["ios.inbox.processLocalSpeech"].exists)

        let inboxScroll = app.descendants(matching: .any)["ios.inbox.scroll"]
        let initialStatus = inboxScroll.value as? String
        let pullStart = inboxScroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.18))
        let pullEnd = inboxScroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.82))
        pullStart.press(forDuration: 0.1, thenDragTo: pullEnd)

        XCTAssertTrue(
            waitForValueToChange(inboxScroll, from: initialStatus, timeout: 5),
            "Pull to refresh should run the full all-device sync and publish a visible result"
        )
    }

    func testRecordingDetailShowsTruthfulSyncTranscriptAndBasicMetadata() {
        XCTAssertTrue(app.navigationBars["Recording Inbox"].waitForExistence(timeout: 5))
        let inboxScroll = app.descendants(matching: .any)["ios.inbox.scroll"]
        let recording = app.buttons["ios.inbox.recordingRow.rec_watch_2"]
        XCTAssertTrue(scroll(inboxScroll, until: recording, maxSwipes: 3))
        recording.tap()

        XCTAssertTrue(app.navigationBars["Recording Details"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["ios.recordingDetail.title"].label, "IdeaForge")
        XCTAssertEqual(app.descendants(matching: .any)["ios.recordingDetail.syncStatus"].value as? String, "Waiting for Mac")
        XCTAssertTrue(app.staticTexts["ios.recordingDetail.transcriptPending"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["ios.recordingDetail.recordedAt"].exists)
        XCTAssertEqual(app.descendants(matching: .any)["ios.recordingDetail.duration"].value as? String, "96 seconds")
        XCTAssertEqual(app.descendants(matching: .any)["ios.recordingDetail.source"].value as? String, "Apple Watch")
        XCTAssertFalse(app.buttons["ios.recordingDetail.processLocalSpeech"].exists)
        XCTAssertFalse(app.buttons["ios.recordingDetail.openIdea"].exists)
    }

    func testCaptureEveryRecordingDetailForDesignReview() {
        XCTAssertTrue(app.navigationBars["Recording Inbox"].waitForExistence(timeout: 5))
        let recordings = [
            (id: "rec_watch_2", name: "watch-follow-up"),
            (id: "rec_phone_1", name: "private-voice"),
            (id: "rec_watch_1", name: "watch-original")
        ]

        for recording in recordings {
            let inboxScroll = app.descendants(matching: .any)["ios.inbox.scroll"]
            let row = app.buttons["ios.inbox.recordingRow.\(recording.id)"]
            XCTAssertTrue(scroll(inboxScroll, until: row, maxSwipes: 5))
            row.tap()
            XCTAssertTrue(app.navigationBars["Recording Details"].waitForExistence(timeout: 3))

            attachScreenshot(named: "recording-\(recording.name)-top")
            let detailList = app.descendants(matching: .any)["ios.recordingDetail.list"]
            detailList.swipeUp(velocity: .slow)
            attachScreenshot(named: "recording-\(recording.name)-bottom")

            app.buttons["Done"].tap()
            XCTAssertTrue(app.navigationBars["Recording Inbox"].waitForExistence(timeout: 3))
        }
    }

    func testRetainedCapabilityReachabilityMatrix() {
        XCTAssertTrue(app.navigationBars["Recording Inbox"].waitForExistence(timeout: 5))
        assertMinimumTarget(app.buttons["ios.inbox.captureAction"])

        let inboxScroll = app.descendants(matching: .any)["ios.inbox.scroll"]
        let recording = app.buttons["ios.inbox.recordingRow.rec_watch_2"]
        XCTAssertTrue(scroll(inboxScroll, until: recording, maxSwipes: 2))
        recording.tap()
        XCTAssertTrue(app.navigationBars["Recording Details"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.descendants(matching: .any)["ios.recordingDetail.state"].value as? String, "On iPhone")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Recording Inbox"].waitForExistence(timeout: 3))

        XCTAssertTrue(openTab("Ideas", navigationTitle: "Idea Projects"))
        let ideasScroll = app.descendants(matching: .any)["ios.ideas.scroll"]
        let ask = app.buttons["ios.ideaAgent.ask"]
        XCTAssertTrue(scroll(ideasScroll, until: ask, maxSwipes: 3))
        assertMinimumTarget(ask)
        ask.tap()
        XCTAssertTrue(app.descendants(matching: .any)["ios.ideaAgent.answer"].waitForExistence(timeout: 3))

        let project = app.descendants(matching: .any)["ios.project.row.idea_ideaforge"]
        XCTAssertTrue(scroll(ideasScroll, until: project, maxSwipes: 3))
        project.tap()
        XCTAssertTrue(app.navigationBars["IdeaForge"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["ios.project.ideaBriefPanel"].exists)

        XCTAssertTrue(openTab("Questions", navigationTitle: "Pending Questions"))
        let questionsScroll = app.descendants(matching: .any)["ios.questions.scroll"]
        let answer = app.textFields["ios.question.answer.q_first_user"].firstMatch
        XCTAssertTrue(scroll(questionsScroll, until: answer, maxSwipes: 3))
        answer.tap()
        app.typeText("Local reachability proof")
        let save = app.buttons["ios.question.save.q_first_user"]
        assertMinimumTarget(save)
        save.tap()
        XCTAssertFalse(save.waitForExistence(timeout: 2))
    }

    func testAccountCapabilityReachabilityMatrix() {
        XCTAssertTrue(openAccountTab())
        let accountScroll = app.descendants(matching: .any)["ios.account.scroll"]

        let publish = app.buttons["ios.account.syncOverview.syncWorkspace"]
        XCTAssertTrue(scroll(accountScroll, until: publish, maxSwipes: 2))
        assertControlAvailability(publish, expectedEnabled: true)
        let syncRoute = app.descendants(matching: .any)["ios.syncRouteSummary"]
        XCTAssertTrue(syncRoute.exists)
        XCTAssertEqual(syncRoute.value as? String, "Watch to iPhone to Mac")

        let localSpeech = app.buttons["ios.account.processLocalSpeech"]
        XCTAssertTrue(scroll(accountScroll, until: localSpeech, maxSwipes: 2))
        assertExplanatoryState(localSpeech, expectedEnabled: true)

        XCTAssertTrue(openSubscriptionSettings(in: accountScroll))
        let purchase = purchaseControl()
        XCTAssertTrue(scroll(accountScroll, until: purchase, maxSwipes: 4))
        // StoreKit product loading is asynchronous: this control may be the
        // disabled placeholder or an enabled configured product. Both valid
        // states must remain reachable and explain themselves.
        XCTAssertTrue(purchase.exists)
        XCTAssertTrue(purchase.label.contains("Purchase"))
        let restorePurchases = app.descendants(matching: .any)["ios.account.restorePurchases.detail"]
        XCTAssertTrue(restorePurchases.exists)
        XCTAssertTrue(restorePurchases.label.contains("Restore Purchases"))
        assertControlAvailability(app.buttons["ios.account.refreshUsage.detail"], expectedEnabled: true)
        XCTAssertTrue(closeSubscriptionSettings())

        let remoteUpload = app.switches["ios.account.remoteUpload"]
        XCTAssertTrue(scroll(accountScroll, until: remoteUpload, maxSwipes: 5))
        let initialRemoteUploadValue = remoteUpload.value as? String
        remoteUpload.tap()
        XCTAssertTrue(waitForValueToChange(remoteUpload, from: initialRemoteUploadValue, timeout: 2))
        remoteUpload.tap()
        XCTAssertTrue(waitForValue(remoteUpload, equalTo: initialRemoteUploadValue ?? "0", timeout: 2))

        XCTAssertTrue(expandAdvancedBackendSettings(in: accountScroll))
        let backendWorkspaceID = app.descendants(matching: .any)["ios.account.backendWorkspaceID"]
        XCTAssertTrue(scroll(accountScroll, until: backendWorkspaceID, maxSwipes: 2))

        let saveBackend = app.buttons["ios.account.saveBackend"]
        XCTAssertTrue(scroll(accountScroll, until: saveBackend, maxSwipes: 5))
        assertExplanatoryState(saveBackend, expectedEnabled: true)

        let finalBackendCommand = app.buttons["ios.account.registerPush.detail"]
        XCTAssertTrue(scroll(accountScroll, until: finalBackendCommand, maxSwipes: 4))
        assertExplanatoryState(finalBackendCommand, expectedEnabled: true)
        XCTAssertTrue(closeAdvancedBackendSettings())

        let integrations = app.staticTexts["Integrations"]
        XCTAssertTrue(scroll(accountScroll, until: integrations, maxSwipes: 6))
        XCTAssertTrue(scroll(accountScroll, until: app.staticTexts["GitHub export"], maxSwipes: 2))
        XCTAssertTrue(scroll(accountScroll, until: app.staticTexts["Codex packet export"], maxSwipes: 2))
    }

    func testLocalSpeechCapabilityProducesVisibleOutcome() {
        XCTAssertTrue(openAccountTab())
        let accountScroll = app.descendants(matching: .any)["ios.account.scroll"]
        let localSpeech = app.buttons["ios.account.processLocalSpeech"]
        XCTAssertTrue(scroll(accountScroll, until: localSpeech, maxSwipes: 4))

        let initialValue = localSpeech.value as? String
        localSpeech.tap()

        let attentionAlert = app.alerts["IdeaForge needs attention"]
        if attentionAlert.waitForExistence(timeout: 2) {
            XCTAssertFalse(attentionAlert.staticTexts.element(boundBy: 1).label.isEmpty)
            attentionAlert.buttons["OK"].tap()
        }

        XCTAssertTrue(waitForCompletedLocalSpeechValue(localSpeech, from: initialValue, timeout: 8))
        XCTAssertFalse((localSpeech.value as? String)?.isEmpty ?? true)
    }

    func testLocalEnrichmentReportsFoundationAvailabilityAndOutcomesSeparately() {
        XCTAssertTrue(openAccountTab())
        let accountScroll = app.descendants(matching: .any)["ios.account.scroll"]
        let localEnrichment = app.buttons["ios.account.processLocalSpeech"]
        XCTAssertTrue(scroll(accountScroll, until: localEnrichment, maxSwipes: 4))

        XCTAssertTrue(localEnrichment.label.hasPrefix("Enrich Locally"))
        XCTAssertTrue((localEnrichment.value as? String)?.contains("Transcript: 2 local recordings are ready.") == true)
        XCTAssertTrue((localEnrichment.value as? String)?.contains("Title: Foundation Models unavailable on this device.") == true)

        localEnrichment.tap()

        let completed = NSPredicate(
            format: "value CONTAINS %@ AND value CONTAINS %@",
            "Transcript: 2 ready, 0 need review.",
            "Title: kept 2 existing titles."
        )
        let outcome = expectation(for: completed, evaluatedWith: localEnrichment)
        wait(for: [outcome], timeout: 8)
    }

    func testMixedLocalEnrichmentOutcomeShowsExactUnavailableReason() {
        XCTAssertTrue(openAccountTab())
        let accountScroll = app.descendants(matching: .any)["ios.account.scroll"]
        let localEnrichment = app.buttons["ios.account.processLocalSpeech"]
        XCTAssertTrue(scroll(accountScroll, until: localEnrichment, maxSwipes: 4))

        let exactReason = NSPredicate(
            format: "value CONTAINS %@ AND value CONTAINS %@",
            "Title: 1 generated",
            "turn on Apple Intelligence: 1"
        )
        wait(for: [expectation(for: exactReason, evaluatedWith: localEnrichment)], timeout: 5)
    }

    func testRecoveredRecordingCheckpointReturnsToInboxAfterRelaunch() {
        let alert = app.alerts["IdeaForge needs attention"]
        XCTAssertTrue(alert.waitForExistence(timeout: 8))
        XCTAssertTrue(alert.staticTexts["An interrupted recording was recovered and kept in your Inbox."].exists)
        alert.buttons["OK"].tap()

        XCTAssertTrue(app.navigationBars["Recording Inbox"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Ideas"].tap()
        XCTAssertTrue(app.navigationBars["Idea Projects"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.descendants(matching: .any)["ios.project.row.idea_ui_recovered_recording"]
                .waitForExistence(timeout: 5)
        )
    }

    func testAccountHubExposesCommerceAndBackendControls() {
        XCTAssertTrue(app.navigationBars["Recording Inbox"].waitForExistence(timeout: 5))

        XCTAssertTrue(openAccountTab())

        XCTAssertTrue(scrollUntilExists(app.buttons["ios.account.processLocalSpeech"]))
        XCTAssertTrue(openSubscriptionSettings(in: app.descendants(matching: .any)["ios.account.scroll"]))
        XCTAssertTrue(scrollUntilExists(purchaseControl()))
        XCTAssertTrue(scrollUntilExists(app.descendants(matching: .any)["ios.account.restorePurchases.detail"]))
        XCTAssertTrue(scrollUntilExists(app.descendants(matching: .any)["ios.account.manageSubscription.row"]))
        XCTAssertTrue(scrollUntilExists(app.descendants(matching: .any)["ios.account.deleteAccount.row"]))
        XCTAssertTrue(closeSubscriptionSettings())

        let remoteUploadSwitch = app.switches["ios.account.remoteUpload"]
        XCTAssertTrue(scrollUntilExists(remoteUploadSwitch))
        let advanced = app.buttons["Advanced Backend Settings"]
        XCTAssertTrue(scrollUntilExists(advanced))
        advanced.tap()
        XCTAssertTrue(scrollUntilExists(app.descendants(matching: .any)["ios.account.backendWorkspaceID"]))
        XCTAssertTrue(scrollUntilExists(app.descendants(matching: .any)["ios.account.backendAuthSessionPath"]))
        XCTAssertTrue(scrollUntilExists(app.descendants(matching: .any)["ios.account.backendPushRegistrationPath"]))
        XCTAssertTrue(scrollUntilExists(app.descendants(matching: .any)["ios.account.backendOperationsMetricsPath"]))
        XCTAssertTrue(scrollUntilExists(app.buttons["ios.account.saveBackend"]))
        XCTAssertTrue(scrollUntilExists(app.buttons["ios.account.syncWorkspace"]))
        XCTAssertTrue(scrollUntilExists(app.buttons["ios.account.refreshWorkspace"]))
        XCTAssertTrue(scrollUntilExists(app.buttons["ios.account.validateSession.detail"]))
        XCTAssertTrue(scrollUntilExists(app.buttons["ios.account.processAI"]))
        XCTAssertTrue(scrollUntilExists(app.buttons["ios.account.registerPush.detail"]))
    }

    func testLocalBackendModeExposesPairingAndLocalOnlyCopy() {
        XCTAssertTrue(openAccountTab())
        let accountScroll = app.scrollViews["ios.account.scroll"]
        let pairingCode = app.secureTextFields["ios.account.localBackendPairingCode"]
        XCTAssertTrue(scroll(accountScroll, until: pairingCode, maxSwipes: 8))
        XCTAssertTrue(app.buttons["ios.account.pairLocalBackend"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["ios.account.backendConnectionKind"].exists)
        let localOnlyCopy = app.staticTexts["Private-LAN sync only. OpenAI is never used as a fallback."]
        XCTAssertTrue(scroll(accountScroll, until: localOnlyCopy, maxSwipes: 3))
    }

    func testLocalBackendAccountPrioritizesWorkflowAndMovesAdvancedSettingsOffMainSurface() {
        XCTAssertTrue(openAccountTab())
        let accountScroll = app.scrollViews["ios.account.scroll"]

        let enrichment = app.buttons["ios.account.processLocalSpeech"]
        XCTAssertTrue(scroll(accountScroll, until: enrichment, maxSwipes: 3))
        XCTAssertEqual(enrichment.label, "Transcribe and Title")

        let pairing = app.secureTextFields["ios.account.localBackendPairingCode"]
        XCTAssertTrue(scroll(accountScroll, until: pairing, maxSwipes: 3))

        let advanced = app.buttons["Advanced Backend Settings"]
        XCTAssertTrue(scroll(accountScroll, until: advanced, maxSwipes: 16))
        XCTAssertFalse(app.descendants(matching: .any)["ios.account.backendWorkspaceID"].exists)
        let accountAttachment = XCTAttachment(screenshot: app.screenshot())
        accountAttachment.name = "Local Backend Account"
        accountAttachment.lifetime = .keepAlways
        add(accountAttachment)

        advanced.tap()
        XCTAssertTrue(app.navigationBars["Backend Settings"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["ios.account.backendWorkspaceID"].waitForExistence(timeout: 2))
    }

    func testAccountSyncStateMatrixShowsPublishedAndLocalOnlyHandoffCopy() {
        relaunch(with: ["-uiTestingPublishedWorkspace"])

        XCTAssertTrue(app.navigationBars["Recording Inbox"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["ios.syncOverview"].exists)
        XCTAssertEqual(elements(identifier: "ios.inbox.statusBanner").count, 0)
        XCTAssertTrue(openAccountTab())
        XCTAssertTrue(scrollUntilLabelContains(app.descendants(matching: .any)["ios.syncTrust"], "Trusted handoff"))
        XCTAssertTrue(scrollUntilLabelContains(app.descendants(matching: .any)["ios.syncTrust"], "Receipted"))
        XCTAssertTrue(scrollUntilLabelContains(app.descendants(matching: .any)["ios.syncNextStep"], "Ready on Mac"))
        XCTAssertTrue(scrollUntilLabelContains(app.descendants(matching: .any)["ios.syncHandoffStatus"], "Backend receipt ready"))
        XCTAssertTrue(scrollUntilExists(app.staticTexts["Workspace published"]))

        relaunch(with: ["-uiTestingLocalOnlyWorkspace"])

        XCTAssertTrue(app.navigationBars["Recording Inbox"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["ios.syncOverview"].exists)
        XCTAssertTrue(app.staticTexts["Watch offline"].exists)
        XCTAssertTrue(openAccountTab())
        XCTAssertTrue(scrollUntilLabelContains(app.descendants(matching: .any)["ios.syncTrust"], "Local-only by design"))
        XCTAssertTrue(scrollUntilLabelContains(app.descendants(matching: .any)["ios.syncReadiness"], "Local-only workspace"))
        XCTAssertTrue(scrollUntilLabelContains(app.descendants(matching: .any)["ios.syncHandoffStatus"], "Local-only handoff"))
        XCTAssertTrue(scrollUntilLabelContains(app.descendants(matching: .any)["ios.syncTrust"], "Local-only"))
        XCTAssertTrue(scrollUntilLabelContains(app.descendants(matching: .any)["ios.syncHandoffStatus"], "Local"))
    }

    func testAppearanceAccessibilityCoreSurfacesRemainUsable() {
        XCTAssertTrue(app.navigationBars["Recording Inbox"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["ios.inbox.captureAction"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["ios.syncOverview"].exists)
        XCTAssertFalse(app.buttons["ios.inbox.syncCard"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["ios.inbox.recordingList"].exists)

        let bannerContent = app.descendants(matching: .any)["ios.inbox.statusBanner.content"]
        let bannerAction = app.buttons["ios.inbox.statusBanner.action"]
        XCTAssertTrue(bannerContent.exists)
        XCTAssertTrue(bannerAction.exists)
        XCTAssertFalse(bannerAction.label.contains("\n"))
        if UIApplication.shared.preferredContentSizeCategory.isAccessibilityCategory {
            XCTAssertGreaterThanOrEqual(bannerAction.frame.minY, bannerContent.frame.maxY - 1)
        } else {
            XCTAssertGreaterThanOrEqual(bannerAction.frame.minX, bannerContent.frame.maxX - 1)
        }

        XCTAssertTrue(openTab("Ideas", navigationTitle: "Idea Projects"))
        XCTAssertTrue(scrollUntilExists(app.descendants(matching: .any)["ios.project.row.idea_ideaforge"]))

        XCTAssertTrue(openTab("Questions", navigationTitle: "Pending Questions"))
        XCTAssertTrue(scrollUntilExists(app.staticTexts["Who is the first user who needs this badly enough to pay?"]))

        XCTAssertTrue(openAccountTab())
        XCTAssertTrue(scrollUntilExists(app.descendants(matching: .any)["ios.syncOverview"]))
        XCTAssertTrue(scrollUntilExists(app.descendants(matching: .any)["ios.syncHandoffSummary"]))
        XCTAssertTrue(scrollUntilExists(app.descendants(matching: .any)["ios.syncTrust"]))
        XCTAssertTrue(scrollUntilExists(app.descendants(matching: .any)["ios.syncHandoffStatus"]))
        XCTAssertTrue(scrollUntilExists(app.descendants(matching: .any)["ios.syncAutoPlan"]))
        XCTAssertTrue(scrollUntilExists(app.descendants(matching: .any)["ios.syncLastActivity"]))
        XCTAssertTrue(scrollUntilExists(app.buttons["ios.account.syncOverview.syncWorkspace"]))
        XCTAssertTrue(scrollUntilExists(app.buttons["ios.account.syncOverview.secondary"]))
        XCTAssertTrue(openSubscriptionSettings(in: app.descendants(matching: .any)["ios.account.scroll"]))
        XCTAssertTrue(scrollUntilExists(purchaseControl()))
        XCTAssertTrue(closeSubscriptionSettings())
        XCTAssertTrue(scrollUntilExists(app.buttons["ios.account.processLocalSpeech"]))
    }

    private func assertTaskFirstVisualEvidence(
        scenario: String,
        fixture: String,
        expectsReduceMotion: Bool = false,
        expectsLightAppearance: Bool = true
    ) {
        if fixture == "-uiTestingRecoveredRecording" {
            let alert = app.alerts["IdeaForge needs attention"]
            XCTAssertTrue(alert.waitForExistence(timeout: 8))
            XCTAssertTrue(alert.staticTexts["An interrupted recording was recovered and kept in your Inbox."].exists)
            alert.buttons["OK"].tap()
        }

        XCTAssertTrue(app.navigationBars["Recording Inbox"].waitForExistence(timeout: 5))
        switch fixture {
        case "-uiTestingClean":
            XCTAssertTrue(app.staticTexts["No recordings yet"].exists)
            XCTAssertEqual(elements(identifier: "ios.inbox.statusBanner").count, 0)
        case "-uiTestingQueuedUpload":
            XCTAssertTrue(app.staticTexts["1 recording waiting"].exists)
        case "-uiTestingFailedUpload":
            XCTAssertTrue(app.staticTexts["1 upload failed"].exists)
        case "-uiTestingOfflineWatch":
            XCTAssertTrue(app.staticTexts["Watch offline"].exists)
        case "-uiTestingSyncConflict":
            XCTAssertTrue(app.staticTexts["Sync conflict"].exists)
        case "-uiTestingRecoveredRecording":
            XCTAssertTrue(app.descendants(matching: .any)["ios.inbox.recordingList"].exists)
        default:
            XCTFail("Unsupported visual fixture: \(fixture)")
        }

        Thread.sleep(forTimeInterval: 8)
        XCTAssertTrue(app.navigationBars["Recording Inbox"].exists)
        for tabName in ["Inbox", "Ideas", "Questions", "Account"] {
            XCTAssertTrue(app.tabBars.buttons[tabName].exists, "Missing tab before visual capture: \(tabName)")
        }
        XCTAssertEqual(UIAccessibility.isReduceMotionEnabled, expectsReduceMotion)
        let stableScreenshot = waitForStableForegroundScreenshot()
        if expectsLightAppearance {
            XCTAssertGreaterThan(
                averageLuminance(of: stableScreenshot),
                0.55,
                "Light visual fixture rendered with unexpectedly low luminance."
            )
        } else {
            XCTAssertLessThan(
                averageLuminance(of: stableScreenshot),
                0.55,
                "Dark visual fixture rendered with unexpectedly high luminance."
            )
        }
        let attachment = XCTAttachment(screenshot: stableScreenshot)
        attachment.name = "IdeaForge-\(scenario)"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(app.state, .runningForeground)
    }

    private func waitForStableForegroundScreenshot() -> XCUIScreenshot {
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))

        let appFrame = app.frame
        XCTAssertFalse(appFrame.isEmpty)
        let geometryElements: [(String, XCUIElement)] = [
            ("Recording Inbox navigation bar", app.navigationBars["Recording Inbox"]),
            ("Inbox tab", app.tabBars.buttons["Inbox"]),
            ("Ideas tab", app.tabBars.buttons["Ideas"]),
            ("Questions tab", app.tabBars.buttons["Questions"]),
            ("Settings tab", app.tabBars.buttons["Settings"]),
        ]
        for (name, element) in geometryElements {
            XCTAssertTrue(element.exists, "Missing visual geometry element: \(name)")
            let elementFrame = element.frame
            XCTAssertFalse(elementFrame.isEmpty, "Empty visual geometry for: \(name)")
            XCTAssertTrue(appFrame.contains(elementFrame), "Visual geometry is outside the app window: \(name)")
        }

        var previous = XCUIScreen.main.screenshot()
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 2)
            XCTAssertEqual(app.state, .runningForeground)
            let candidate = XCUIScreen.main.screenshot()
            if candidate.pngRepresentation == previous.pngRepresentation
                || normalizedVisualDifference(between: previous, and: candidate) < 0.005 {
                return candidate
            }
            previous = candidate
        }

        XCTFail("The foreground screen did not produce two consecutive stable frames.")
        return previous
    }

    private func averageLuminance(of screenshot: XCUIScreenshot) -> CGFloat {
        guard let image = CIImage(data: screenshot.pngRepresentation) else {
            XCTFail("Unable to decode the visual evidence screenshot.")
            return 0
        }
        return averageLuminance(of: image)
    }

    private func normalizedVisualDifference(
        between first: XCUIScreenshot,
        and second: XCUIScreenshot
    ) -> CGFloat {
        guard let firstImage = CIImage(data: first.pngRepresentation),
              let secondImage = CIImage(data: second.pngRepresentation),
              firstImage.extent == secondImage.extent,
              let difference = CIFilter(name: "CIDifferenceBlendMode") else {
            XCTFail("Unable to compare foreground screenshots.")
            return 1
        }
        difference.setValue(firstImage, forKey: kCIInputImageKey)
        difference.setValue(secondImage, forKey: kCIInputBackgroundImageKey)
        guard let output = difference.outputImage else {
            XCTFail("CIDifferenceBlendMode did not produce screenshot output.")
            return 1
        }
        return averageLuminance(of: output)
    }

    private func averageLuminance(of image: CIImage) -> CGFloat {
        guard let filter = CIFilter(name: "CIAreaAverage") else {
            XCTFail("CIAreaAverage is unavailable.")
            return 0
        }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: image.extent), forKey: kCIInputExtentKey)
        guard let output = filter.outputImage else {
            XCTFail("CIAreaAverage did not produce screenshot output.")
            return 0
        }

        let context = CIContext(options: [.workingColorSpace: NSNull()])
        var rgba = [UInt8](repeating: 0, count: 4)
        rgba.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            context.render(
                output,
                toBitmap: baseAddress,
                rowBytes: 4,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                format: .RGBA8,
                colorSpace: CGColorSpaceCreateDeviceRGB()
            )
        }
        let red = CGFloat(rgba[0]) / 255
        let green = CGFloat(rgba[1]) / 255
        let blue = CGFloat(rgba[2]) / 255
        return (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
    }

    func testTaskFirstVisualEvidenceCapturesForegroundFixtureClean() {
        assertTaskFirstVisualEvidence(scenario: "clean-light", fixture: "-uiTestingClean")
    }

    func testTaskFirstVisualEvidenceCapturesForegroundFixtureQueued() {
        assertTaskFirstVisualEvidence(scenario: "queued-light", fixture: "-uiTestingQueuedUpload")
    }

    func testTaskFirstVisualEvidenceCapturesForegroundFixtureFailed() {
        assertTaskFirstVisualEvidence(
            scenario: "failed-dark",
            fixture: "-uiTestingFailedUpload",
            expectsLightAppearance: false
        )
    }

    func testTaskFirstVisualEvidenceCapturesForegroundFixtureOffline() {
        assertTaskFirstVisualEvidence(scenario: "offline-accessibility", fixture: "-uiTestingOfflineWatch")
    }

    func testTaskFirstVisualEvidenceCapturesForegroundFixtureConflict() {
        assertTaskFirstVisualEvidence(
            scenario: "conflict-contrast",
            fixture: "-uiTestingSyncConflict",
            expectsLightAppearance: false
        )
    }

    func testTaskFirstVisualEvidenceCapturesForegroundFixtureRecoveredReduceMotion() {
        assertTaskFirstVisualEvidence(
            scenario: "recovered-recording-reduce-motion",
            fixture: "-uiTestingRecoveredRecording",
            expectsReduceMotion: true
        )
    }

    func testAccountPublishWorkspaceExplainsCapabilityGate() {
        XCTAssertTrue(app.navigationBars["Recording Inbox"].waitForExistence(timeout: 5))

        XCTAssertTrue(openAccountTab())

        let publishButton = app.buttons["ios.account.syncOverview.syncWorkspace"]
        XCTAssertTrue(scrollUntilExists(publishButton))
        publishButton.tap()

        let syncOverview = app.descendants(matching: .any)["ios.syncOverview"]
        let expectedMessage = "Workspace sync needs validated backend capability. Validate backend session before using this backend action."
        XCTAssertTrue(syncOverview.waitForExistence(timeout: 2))
        XCTAssertTrue(
            (syncOverview.value as? String)?.contains(expectedMessage) == true,
            "Unexpected sync status: \(String(describing: syncOverview.value))"
        )
    }

    func testAccountRefreshWorkspaceExplainsCapabilityGate() {
        XCTAssertTrue(app.navigationBars["Recording Inbox"].waitForExistence(timeout: 5))

        XCTAssertTrue(openAccountTab())

        let refreshButton = app.buttons["ios.account.syncOverview.secondary"]
        XCTAssertTrue(scrollUntilExists(refreshButton))
        refreshButton.tap()

        XCTAssertTrue(app.staticTexts["Workspace refresh needs validated backend capability. Validate backend session before using this backend action."].waitForExistence(timeout: 3))
    }

    func testAccountHubShowsSyncConflictReviewBeforeMerge() {
        app.terminate()
        app.launchArguments = ["-uiTesting", "-uiTestingSyncConflict"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Recording Inbox"].waitForExistence(timeout: 5))

        XCTAssertTrue(openAccountTab())

        XCTAssertTrue(scrollUntilLabelContains(app.descendants(matching: .any)["ios.syncReadiness"], "Review sync before publishing"))
        XCTAssertTrue(scrollUntilLabelContains(app.descendants(matching: .any)["ios.syncAutoPlan"], "Auto-sync paused"))
        XCTAssertTrue(scrollUntilLabelContains(app.descendants(matching: .any)["ios.syncTrust"], "Review before sync"))
        XCTAssertTrue(scrollUntilLabelContains(app.descendants(matching: .any)["ios.syncTrust"], "Conflict"))
        XCTAssertTrue(scrollUntilLabelContains(app.descendants(matching: .any)["ios.syncNextStep"], "Review and merge local choices"))
        XCTAssertTrue(scrollUntilLabelContains(app.descendants(matching: .any)["ios.syncNextStep"], "Review in Account"))
        XCTAssertTrue(scrollUntilExists(app.descendants(matching: .any)["ios.account.syncConflictReview"]))
        XCTAssertTrue(scrollUntilExists(app.staticTexts["Review Before Merge"]))
        XCTAssertTrue(scrollUntilExists(app.staticTexts["Upload job: IdeaForge"]))
        XCTAssertTrue(scrollUntilExists(app.staticTexts["Recording: IdeaForge"]))
        XCTAssertTrue(scrollUntilExists(app.staticTexts["Watch - Queued - Apple Watch, 96s, attempt 0"]))
        XCTAssertTrue(scrollUntilExists(app.buttons["ios.account.resolveSyncConflict"]))
        XCTAssertFalse(app.staticTexts["recordings/rec_watch_2.m4a"].exists)
        XCTAssertFalse(app.staticTexts["audio/idea_ideaforge/rec_watch_1.m4a"].exists)
    }

    func testAccountHubSyncConflictCustomItemEditorsAreReachable() {
        app.terminate()
        app.launchArguments = ["-uiTesting", "-uiTestingCustomSyncConflict"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Recording Inbox"].waitForExistence(timeout: 5))

        XCTAssertTrue(openAccountTab())
        XCTAssertTrue(scrollUntilExists(app.descendants(matching: .any)["ios.account.syncConflictReview"]))

        let assumptionID = "project:idea_ideaforge:assumptions:item:assumption_bridge"
        XCTAssertTrue(scrollUntilExists(app.descendants(matching: .any)["ios.account.syncConflictItemAssumptionDraft.\(assumptionID)"], maxSwipes: 16))
        XCTAssertTrue(scrollUntilExists(app.descendants(matching: .any)["ios.account.syncConflictItemConfidenceDraft.\(assumptionID)"], maxSwipes: 4))

        let codexTaskID = "project:idea_ideaforge:codexTasks:item:task_bootstrap"
        let codexTaskDraft = app.descendants(matching: .any)["ios.account.syncConflictItemCodexTaskDraft.\(codexTaskID)"]
        XCTAssertTrue(scrollUntilExists(codexTaskDraft, maxSwipes: 16))
        XCTAssertTrue(scrollUntilExists(app.descendants(matching: .any)["ios.account.syncConflictItemAcceptanceDraft.\(codexTaskID)"], maxSwipes: 4))
        XCTAssertTrue(scrollUntilExists(app.descendants(matching: .any)["ios.account.syncConflictItemTestPlanDraft.\(codexTaskID)"], maxSwipes: 4))

        let questionID = "project:idea_ideaforge:questions:item:q_first_user"
        let questionPrompt = app.descendants(matching: .any)["ios.account.syncConflictItemPromptDraft.\(questionID)"]
        XCTAssertTrue(scrollUntilExists(questionPrompt, maxSwipes: 16))

        let experimentID = "project:idea_ideaforge:validationExperiments:item:exp_builder_interviews"
        let experimentDraft = app.descendants(matching: .any)["ios.account.syncConflictItemExperimentDraft.\(experimentID)"]
        XCTAssertTrue(scrollUntilExists(experimentDraft, maxSwipes: 16))
        XCTAssertTrue(scrollUntilExists(app.descendants(matching: .any)["ios.account.syncConflictItemMetricDraft.\(experimentID)"], maxSwipes: 4))
        XCTAssertTrue(scrollUntilExists(app.descendants(matching: .any)["ios.account.syncConflictItemCriteriaDraft.\(experimentID)"], maxSwipes: 4))

        let workflowRunID = "project:idea_ideaforge:workflowRuns:item:run_sample_failed_prd"
        let workflowNameDraft = app.descendants(matching: .any)["ios.account.syncConflictItemWorkflowRunNameDraft.\(workflowRunID)"]
        XCTAssertTrue(scrollUntilExists(workflowNameDraft, maxSwipes: 16))
        XCTAssertTrue(scrollUntilExists(app.descendants(matching: .any)["ios.account.syncConflictItemWorkflowRunStatusDraft.\(workflowRunID)"], maxSwipes: 4))
        let failureDraft = app.descendants(matching: .any)["ios.account.syncConflictItemWorkflowRunFailureDraft.\(workflowRunID)"]
        XCTAssertTrue(scrollUntilExists(failureDraft, maxSwipes: 4))
    }

    func testFailedUploadReviewAndRecordingDetailExposeSafeRetry() {
        relaunch(with: ["-uiTestingFailedUpload"])
        XCTAssertTrue(app.navigationBars["Recording Inbox"].waitForExistence(timeout: 5))

        app.buttons["Review"].tap()
        XCTAssertTrue(app.navigationBars["Sync & Settings"].waitForExistence(timeout: 5))
        let diagnostic = app.descendants(matching: .any)["ios.account.failedUpload.rec_task_first_upload"]
        XCTAssertTrue(scrollUntilExists(diagnostic))
        XCTAssertTrue(diagnostic.label.contains("Task-first fixture"))
        XCTAssertTrue(diagnostic.label.contains("Source Apple Watch"))
        XCTAssertTrue(diagnostic.label.contains("Status Failed"))
        XCTAssertTrue(diagnostic.label.contains("Reason Server"))
        XCTAssertTrue(diagnostic.label.contains("Retained audio available"))
        let accountRetry = app.buttons["ios.account.retryUpload.rec_task_first_upload"]
        XCTAssertEqual(accountRetry.label, "Retry upload")
        XCTAssertGreaterThanOrEqual(accountRetry.frame.height, 44)
        XCTAssertTrue(scrollUntilExists(app.descendants(matching: .any)["ios.account.uploadJob.rec_task_first_queued"]))
        XCTAssertTrue(scrollUntilExists(app.descendants(matching: .any)["ios.account.uploadJob.rec_task_first_uploading"]))
        XCTAssertTrue(scrollUntilExists(app.descendants(matching: .any)["ios.account.uploadJob.rec_task_first_retrying"]))
        XCTAssertTrue(scrollUntilExists(app.descendants(matching: .any)["ios.account.recordingDiagnostic.rec_task_first_upload"]))
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "IdeaForgeTaskFirstFixtures")).firstMatch.exists)

        XCTAssertTrue(openTab("Inbox", navigationTitle: "Recording Inbox"))
        let row = app.buttons["ios.inbox.recordingRow.rec_task_first_upload"]
        XCTAssertTrue(scrollUntilFullyVisible(row))
        row.tap()

        XCTAssertTrue(app.navigationBars["Recording Details"].waitForExistence(timeout: 5))
        let state = app.descendants(matching: .any)["ios.recordingDetail.state"]
        let uploadStatus = app.descendants(matching: .any)["ios.recordingDetail.uploadStatus"]
        let failureCategory = app.descendants(matching: .any)["ios.recordingDetail.failureCategory"]
        let playback = app.buttons["ios.recordingDetail.playback"]
        let retry = app.buttons["ios.recordingDetail.retryUpload"]
        XCTAssertTrue(state.exists)
        XCTAssertEqual(state.value as? String, "Failed")
        XCTAssertEqual(uploadStatus.value as? String, "Failed")
        XCTAssertEqual(failureCategory.value as? String, "Server")
        XCTAssertTrue(playback.exists)
        XCTAssertTrue(retry.exists)

        playback.tap()
        XCTAssertTrue(waitForValue(playback, equalTo: "Playing", timeout: 2))
        XCTAssertFalse(app.alerts["IdeaForge needs attention"].waitForExistence(timeout: 1))

        retry.tap()
        XCTAssertTrue(waitForValue(uploadStatus, equalTo: "Uploaded", timeout: 8))
        XCTAssertNotEqual(state.value as? String, "Failed")
        XCTAssertFalse(failureCategory.waitForExistence(timeout: 1))
        XCTAssertFalse(retry.waitForExistence(timeout: 1))
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "retained-audio.m4a")).firstMatch.exists)
    }

    func testNonRetryableTranscriptFailureCanKeepAudioWithoutTranscript() {
        relaunch(with: ["-uiTestingNonRetryableTranscriptFailure"])
        XCTAssertTrue(openAccountTab())
        let accountScroll = app.descendants(matching: .any)["ios.account.scroll"]
        let keepButton = app.buttons["ios.account.keepWithoutTranscript.rec_nonretryable_transcript"]
        XCTAssertTrue(scroll(accountScroll, until: keepButton, maxSwipes: 10))
        XCTAssertTrue(keepButton.isEnabled)

        keepButton.tap()
        let confirmation = app.buttons["Keep Audio"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.tap()

        XCTAssertFalse(keepButton.waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["Upload Diagnostics"].exists)
    }

    func testAccountUploadDiagnosticsExposeOneCurrentRowPerRecording() {
        relaunch(with: ["-uiTestingFailedUpload"])
        XCTAssertTrue(app.navigationBars["Recording Inbox"].waitForExistence(timeout: 5))
        app.buttons["Review"].tap()
        XCTAssertTrue(app.navigationBars["Sync & Settings"].waitForExistence(timeout: 5))

        let expectations = [
            ("ios.account.failedUpload.rec_task_first_upload", "Status Failed", "Reason Server"),
            ("ios.account.uploadJob.rec_task_first_queued", "Status Queued", ""),
            ("ios.account.uploadJob.rec_task_first_uploading", "Status Retry scheduled", ""),
            ("ios.account.uploadJob.rec_task_first_retrying", "Status Retry scheduled", "")
        ]
        for expectation in expectations {
            let row = app.descendants(matching: .any)[expectation.0]
            XCTAssertTrue(scrollUntilExists(row))
            XCTAssertEqual(elements(identifier: expectation.0).count, 1)
            XCTAssertTrue(row.label.contains(expectation.1))
            if !expectation.2.isEmpty {
                XCTAssertTrue(row.label.contains(expectation.2))
            }
        }
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "IdeaForgeTaskFirstFixtures")).firstMatch.exists)
    }

    func testInvalidUploadConfigurationFailsBackgroundCallerOutcomes() {
        relaunch(with: [
            "-uiTestingQueuedUpload",
            "-uiTestingInvalidUploadConfiguration",
            "-uiTestingRunBackgroundRefresh"
        ])
        XCTAssertTrue(app.navigationBars["Recording Inbox"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts["IdeaForge needs attention"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Background refresh result: Failed."].exists)
        app.alerts.buttons["OK"].tap()

        relaunch(with: [
            "-uiTestingQueuedUpload",
            "-uiTestingInvalidUploadConfiguration",
            "-uiTestingRunRemoteNotification"
        ])
        XCTAssertTrue(app.navigationBars["Recording Inbox"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts["IdeaForge needs attention"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Remote notification result: Failed."].exists)
        app.alerts.buttons["OK"].tap()

        relaunch(with: [
            "-uiTestingQueuedUpload",
            "-uiTestingInvalidUploadConfiguration",
            "-uiTestingRunColdRemoteNotification"
        ])
        XCTAssertTrue(app.navigationBars["Recording Inbox"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts["IdeaForge needs attention"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Cold-launch remote notification result: Failed."].exists)
    }

    func testRecordingPermissionDeniedShowsVisibleError() {
        XCTAssertTrue(app.navigationBars["Recording Inbox"].waitForExistence(timeout: 5))

        app.buttons["ios.inbox.captureAction"].tap()

        XCTAssertTrue(app.alerts["IdeaForge needs attention"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Microphone access is required. Enable microphone permission in System Settings and try again."].exists)
        app.alerts.buttons["OK"].tap()
    }

    func testProjectDetailExposesTranscriptReviewSurface() {
        XCTAssertTrue(app.navigationBars["Recording Inbox"].waitForExistence(timeout: 5))

        XCTAssertTrue(openTab("Ideas", navigationTitle: "Idea Projects"))
        let ideaForgeProjectRow = app.descendants(matching: .any)["ios.project.row.idea_ideaforge"]
        XCTAssertTrue(scrollUntilFullyVisible(ideaForgeProjectRow))
        ideaForgeProjectRow.tap()

        XCTAssertTrue(app.navigationBars["IdeaForge"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["ios.project.ideaBriefPanel"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["ios.project.shareIdeaBrief"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["ios.project.prepareIdeaBrief"].exists)
        XCTAssertTrue(app.staticTexts["Transcript Review"].exists)
        XCTAssertTrue(scrollUntilExists(app.staticTexts["Segments"]))
        XCTAssertTrue(scrollUntilExists(app.staticTexts["0:00"]))
        XCTAssertTrue(scrollUntilExists(app.switches["Important"]))
        XCTAssertTrue(scrollUntilExists(app.buttons["Save Segment"]))
        XCTAssertTrue(scrollUntilExists(app.descendants(matching: .any)["ios.project.transcript.editor"]))
        XCTAssertTrue(scrollUntilExists(app.buttons["ios.project.transcript.save"]))
        XCTAssertTrue(scrollUntilExists(app.buttons["ios.project.transcript.revert"]))
    }

    func testIdeasAgentAndQuestionAnswerFlow() {
        XCTAssertTrue(app.navigationBars["Recording Inbox"].waitForExistence(timeout: 5))

        XCTAssertTrue(openTab("Ideas", navigationTitle: "Idea Projects"))
        XCTAssertTrue(app.descendants(matching: .any)["ios.ideas.hero"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["ios.ideaAgent"].exists)
        XCTAssertTrue(scrollUntilExists(app.descendants(matching: .any)["ios.ideaAgent.query"]))

        let askButton = app.buttons["ios.ideaAgent.ask"]
        XCTAssertTrue(scrollUntilExists(askButton))
        askButton.tap()

        XCTAssertTrue(app.descendants(matching: .any)["ios.ideaAgent.answer"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Grounded in"].exists)

        XCTAssertTrue(openTab("Questions", navigationTitle: "Pending Questions"))
        XCTAssertTrue(app.descendants(matching: .any)["ios.questions.hero"].waitForExistence(timeout: 5))
        let answerField = app.textFields["ios.question.answer.q_first_user"].firstMatch
        XCTAssertTrue(scrollUntilExists(answerField))
        answerField.tap()
        app.typeText("Solo builders who already capture product ideas on the move.")

        let saveButton = app.buttons["ios.question.save.q_first_user"]
        XCTAssertTrue(saveButton.exists)
        XCTAssertTrue(saveButton.isEnabled)
        saveButton.tap()

        XCTAssertFalse(app.buttons["ios.question.save.q_first_user"].waitForExistence(timeout: 2))
    }

    private func scrollUntilFullyVisible(_ element: XCUIElement, maxSwipes: Int = 18) -> Bool {
        guard scrollUntilExists(element, maxSwipes: maxSwipes) else {
            return false
        }
        let window = app.windows.firstMatch
        for _ in 0..<maxSwipes {
            let frame = element.frame
            if window.frame.contains(frame) && element.isHittable {
                return true
            }
            app.swipeUp()
            _ = element.waitForExistence(timeout: 1)
        }
        return element.isHittable
    }

    private func scrollUntilExists(_ element: XCUIElement, maxSwipes: Int = 18) -> Bool {
        if element.waitForExistence(timeout: 1) {
            return true
        }
        for _ in 0..<maxSwipes {
            app.swipeUp()
            if element.waitForExistence(timeout: 1) {
                return true
            }
        }
        return false
    }

    private func scrollUntilLabelContains(_ element: XCUIElement, _ expectedFragment: String, maxSwipes: Int = 18) -> Bool {
        if element.waitForExistence(timeout: 1), element.label.contains(expectedFragment) {
            return true
        }
        for _ in 0..<maxSwipes {
            app.swipeUp()
            if element.waitForExistence(timeout: 1), element.label.contains(expectedFragment) {
                return true
            }
        }
        return false
    }

    private func scroll(_ container: XCUIElement, until element: XCUIElement, maxSwipes: Int) -> Bool {
        if element.waitForExistence(timeout: 0.5) {
            return true
        }
        guard container.waitForExistence(timeout: 1) else {
            return false
        }
        for _ in 0..<maxSwipes {
            container.swipeUp(velocity: .fast)
            if element.waitForExistence(timeout: 0.5) {
                return true
            }
        }
        return false
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openAccountTab() -> Bool {
        if accountSurfaceIsVisible() {
            return true
        }

        for _ in 0..<3 {
            let settingsButton = app.buttons["ios.inbox.settings"]
            if settingsButton.waitForExistence(timeout: 2) {
                settingsButton.tap()
            } else {
                continue
            }

            if accountSurfaceIsVisible() {
                return true
            }
        }

        return false
    }

    private func openTab(_ title: String, navigationTitle: String) -> Bool {
        if app.navigationBars[navigationTitle].waitForExistence(timeout: 1) {
            return true
        }

        for _ in 0..<4 {
            let tabButton = app.tabBars.buttons[title]
            if tabButton.waitForExistence(timeout: 2) {
                tabButton.tap()
            } else {
                let fallbackButton = app.buttons[title]
                guard fallbackButton.waitForExistence(timeout: 2) else {
                    continue
                }
                fallbackButton.tap()
            }

            if app.navigationBars[navigationTitle].waitForExistence(timeout: 2) {
                return true
            }
        }

        return false
    }

    private func accountSurfaceIsVisible() -> Bool {
        app.navigationBars["Settings"].waitForExistence(timeout: 1)
            || app.descendants(matching: .any)["ios.account.backendConnectionKind"].waitForExistence(timeout: 1)
            || app.descendants(matching: .any)["ios.account.syncConflictReview"].waitForExistence(timeout: 1)
    }

    private func expandAdvancedBackendSettings(in accountScroll: XCUIElement) -> Bool {
        let workspaceID = app.descendants(matching: .any)["ios.account.backendWorkspaceID"]
        if workspaceID.exists {
            return true
        }
        let advanced = app.buttons["Advanced Backend Settings"]
        guard scroll(accountScroll, until: advanced, maxSwipes: 18) else {
            return false
        }
        advanced.tap()
        return workspaceID.waitForExistence(timeout: 2)
    }

    private func openSubscriptionSettings(in accountScroll: XCUIElement) -> Bool {
        let subscription = app.buttons["ios.account.subscriptionSettings"]
        guard scroll(accountScroll, until: subscription, maxSwipes: 10) else {
            return false
        }
        subscription.tap()
        return app.navigationBars["Subscription"].waitForExistence(timeout: 3)
    }

    private func closeSubscriptionSettings() -> Bool {
        let accountBackButton = app.navigationBars["Subscription"].buttons["Sync & Settings"]
        guard accountBackButton.waitForExistence(timeout: 2) else {
            return false
        }
        accountBackButton.tap()
        return app.navigationBars["Sync & Settings"].waitForExistence(timeout: 3)
    }

    private func closeAdvancedBackendSettings() -> Bool {
        let accountBackButton = app.navigationBars["Advanced Diagnostics"].buttons["Sync & Settings"]
        guard accountBackButton.waitForExistence(timeout: 2) else {
            return false
        }
        accountBackButton.tap()
        return app.navigationBars["Sync & Settings"].waitForExistence(timeout: 3)
    }

    private func relaunch(with extraArguments: [String]) {
        app.terminate()
        app.launchArguments = ["-uiTesting"] + extraArguments
        app.launch()
    }

    private func elements(identifier: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: identifier)
    }

    private func purchaseControl() -> XCUIElement {
        app.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "identifier == %@ OR identifier BEGINSWITH %@",
                    "ios.account.purchasePro.detail",
                    "ios.account.purchase."
                )
            )
            .firstMatch
    }

    private func waitForValue(_ element: XCUIElement, equalTo expectedValue: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "value == %@", expectedValue)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForValueToChange(
        _ element: XCUIElement,
        from initialValue: String?,
        timeout: TimeInterval
    ) -> Bool {
        let predicate = NSPredicate(format: "value != %@", initialValue ?? "")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForCompletedLocalSpeechValue(
        _ element: XCUIElement,
        from initialValue: String?,
        timeout: TimeInterval
    ) -> Bool {
        let predicate = NSPredicate(
            format: "value != %@ AND NOT value CONTAINS[c] %@",
            initialValue ?? "",
            "running"
        )
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func assertControlAvailability(
        _ element: XCUIElement,
        expectedEnabled: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(element.exists, file: file, line: line)
        XCTAssertEqual(element.isEnabled, expectedEnabled, file: file, line: line)
    }

    private func assertExplanatoryState(
        _ element: XCUIElement,
        expectedEnabled: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(element.exists, file: file, line: line)
        XCTAssertEqual(element.isEnabled, expectedEnabled, file: file, line: line)
        XCTAssertFalse((element.value as? String)?.isEmpty ?? true, file: file, line: line)
    }

    private func assertRecordingValueHasExactlyOneState(
        _ value: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let states = [
            "On Watch", "On iPhone", "Ready to upload", "Uploading",
            "Retry scheduled", "Failed", "Transcribed", "Synced"
        ]
        XCTAssertEqual(states.filter(value.contains).count, 1, file: file, line: line)
    }

    private func assertMinimumTarget(
        _ element: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(scrollUntilFullyVisible(element), file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.width, 44, file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.height, 44, file: file, line: line)
    }

    private func assertInboxStatus(arguments: [String], title: String, action: String?) {
        relaunch(with: arguments)
        XCTAssertTrue(app.navigationBars["Recording Inbox"].waitForExistence(timeout: 5))
        XCTAssertEqual(elements(identifier: "ios.inbox.statusBanner").count, 1)
        let content = app.descendants(matching: .any)["ios.inbox.statusBanner.content"]
        let expectedLabel = title == "Sync conflict"
            ? "Sync status"
            : (title == "Watch offline" ? "Watch status" : "Upload status")
        XCTAssertEqual(content.label, expectedLabel)
        XCTAssertEqual(content.value as? String, title)
        if let action {
            let actionButton = app.buttons["ios.inbox.statusBanner.action"]
            XCTAssertEqual(actionButton.label, action)
            XCTAssertGreaterThanOrEqual(actionButton.frame.height, 44)
        } else {
            XCTAssertTrue(app.staticTexts["The recording remains on Watch and sync resumes after reconnection."].exists)
        }
    }

}
