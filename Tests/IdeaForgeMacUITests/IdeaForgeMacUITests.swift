import XCTest
import Darwin
import AppKit

@MainActor
final class IdeaForgeMacUITests: XCTestCase {
    func testMarkdownExportOpensSavePanelAndCanCancel() {
        let project = app.descendants(matching: .any)["mac.sidebar.project.idea_ideaforge"]
        XCTAssertTrue(project.waitForExistence(timeout: 5))
        project.click()
        let tabs = app.descendants(matching: .any)["mac.projectWorkspace.tabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 3))
        tabs.radioButtons["Files"].click()
        app.buttons["mac.files.exportIdeaBrief"].click()
        let panel = app.dialogs["save-panel"]
        let save = panel.buttons["Save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        let cancel = panel.buttons["CancelButton"]
        XCTAssertTrue(cancel.exists)
        cancel.click()
        XCTAssertTrue(app.buttons["mac.files.exportIdeaBrief"].exists)
    }

    nonisolated(unsafe) private var app: XCUIApplication!

    nonisolated override func setUpWithError() throws {
        let testName = name
        let liveURL = testName.contains("LiveLocalBackend") ? try Self.liveLocalBackendURL() : nil
        app = MainActor.assumeIsolated {
            let application = XCUIApplication(bundleIdentifier: "com.s1kor.ideaforge.mac")
            application.launchArguments = ["-uiTesting"]
            if testName.contains("CompactWindow") {
                application.launchArguments.append("-uiTestingCompactWindow")
            } else if testName.contains("WideWindow") || testName.contains("InspectorShortcut") {
                application.launchArguments.append("-uiTestingWideWindow")
            }
            if testName.contains("SyncConflictStatus") {
                application.launchArguments.append("-uiTestingStatusSyncConflict")
            } else if testName.contains("FailedUploadStatus") {
                application.launchArguments.append("-uiTestingStatusFailedUpload")
            } else if testName.contains("QueuedUploadStatus") {
                application.launchArguments.append("-uiTestingStatusQueuedUpload")
            } else if testName.contains("OfflineStatus") {
                application.launchArguments.append("-uiTestingStatusOffline")
            }
            if testName.contains("LocalEnrichment") {
                application.launchArguments.append("-uiTestingLocalEnrichment")
                application.launchArguments.append("-uiTestingFoundationUnavailable")
            }
            if testName.contains("MixedLocalEnrichmentOutcome") {
                application.launchArguments.append("-uiTestingMixedEnrichmentOutcome")
            }
            if testName.contains("LocalBackend") {
                application.launchArguments.append("-uiTestingLocalBackend")
            }
            if let liveURL {
                application.launchArguments.append("-uiTestingLiveLocalBackend")
                application.launchEnvironment["IDEAFORGE_UI_TEST_LIVE_BACKEND_URL"] = liveURL
            }
            if testName.contains("LiveBonjourDiscovery") {
                application.launchArguments.append("-uiTestingLiveBonjourDiscovery")
            }
            application.launch()
            application.activate()
            return application
        }
    }

    nonisolated override func tearDownWithError() throws {
        app = nil
    }

    nonisolated private static func liveLocalBackendURL() throws -> String {
        guard let passwordEntry = getpwuid(getuid()),
              let homePointer = passwordEntry.pointee.pw_dir else {
            throw XCTSkip("The operator home directory is unavailable for the live recovery smoke.")
        }
        let operatorHome = URL(fileURLWithPath: String(cString: homePointer), isDirectory: true)
        let configurationURL = operatorHome
            .appendingPathComponent("Library/Application Support/IdeaForge/LocalBackend/runtime-config.json")
        guard FileManager.default.fileExists(atPath: configurationURL.path) else {
            throw XCTSkip("Install the Local Backend to run the live recovery smoke.")
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
        process.arguments = ["--get", "LocalHostName"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let localHostName = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, !localHostName.isEmpty else {
            throw XCTSkip("The Mac LocalHostName is unavailable for the live recovery smoke.")
        }
        return "https://\(localHostName).local:8765"
    }

    func testMainWindowExposesPlanningWorkflowControls() {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["mac.toolbar.inbox"].exists)
        XCTAssertTrue(app.buttons["mac.toolbar.codexPacket"].exists)
        XCTAssertTrue(app.buttons["mac.toolbar.record"].exists)
        let inspectorToggle = app.buttons["mac.toolbar.inspector"]
        XCTAssertTrue(inspectorToggle.waitForExistence(timeout: 2))
        inspectorToggle.click()
        XCTAssertTrue(app.buttons["mac.inspector.runReviewBoard"].exists)
        XCTAssertTrue(app.buttons["mac.inspector.generatePRD"].exists)
        XCTAssertTrue(app.buttons["mac.inspector.prepareCodexPacket"].exists)
    }

    func testInspectorLocalEnrichmentReportsFoundationAvailabilityAndSeparateOutcomes() {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5))
        app.buttons["mac.toolbar.inspector"].click()

        let localEnrichment = app.buttons["mac.inspector.processLocalEnrichment"]
        XCTAssertTrue(localEnrichment.waitForExistence(timeout: 2))
        XCTAssertTrue(localEnrichment.label.hasPrefix("Enrich Locally"))

        let availability = app.descendants(matching: .any)["mac.inspector.localEnrichmentStatus"]
        XCTAssertTrue(availability.waitForExistence(timeout: 2))
        XCTAssertTrue((availability.value as? String)?.contains("Transcript: 2 local recordings are ready.") == true)
        XCTAssertTrue((availability.value as? String)?.contains("Title: Foundation Models unavailable on this device.") == true)

        localEnrichment.click()

        let completed = NSPredicate(
            format: "value CONTAINS %@ AND value CONTAINS %@",
            "Transcript: 2 ready, 0 need review.",
            "Title: kept 2 existing titles."
        )
        let outcome = expectation(for: completed, evaluatedWith: availability)
        wait(for: [outcome], timeout: 8)
    }

    func testMixedLocalEnrichmentOutcomeShowsExactUnavailableReason() {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5))
        app.buttons["mac.toolbar.inspector"].click()
        let status = app.descendants(matching: .any)["mac.inspector.localEnrichmentStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 2))

        let exactReason = NSPredicate(
            format: "value CONTAINS %@ AND value CONTAINS %@",
            "Title: 1 generated",
            "turn on Apple Intelligence: 1"
        )
        wait(for: [expectation(for: exactReason, evaluatedWith: status)], timeout: 5)
    }

    func testSettingsUsesBackendAccountPortalInsteadOfAppStoreCommerce() {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5))

        app.typeKey(",", modifierFlags: .command)

        XCTAssertTrue(app.buttons["View Plans"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Refresh Plan"].exists)
        XCTAssertTrue(app.buttons["Delete Account"].exists)
        XCTAssertFalse(app.buttons["Purchase Pro"].exists)
        XCTAssertFalse(app.buttons["Restore Purchases"].exists)
        XCTAssertFalse(app.buttons["Manage Subscription"].exists)
        XCTAssertFalse(app.buttons["Reload StoreKit"].exists)
    }

    func testLocalBackendSettingsExposePairingAndLocalOnlyCopy() {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5))
        app.typeKey(",", modifierFlags: .command)

        XCTAssertTrue(app.secureTextFields["mac.settings.localBackendPairingCode"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["mac.settings.pairLocalBackend"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["mac.settings.backendConnectionKind"].exists)
        XCTAssertTrue(app.staticTexts["Sync stays on your private LAN. OpenAI is optional, disabled by default, and never a fallback."].exists)
    }

    func testLocalBackendToolbarReportsReadyAndOpensSettings() {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5))

        let backendStatus = app.buttons["mac.toolbar.localBackendStatus"]
        XCTAssertTrue(backendStatus.waitForExistence(timeout: 3))
        XCTAssertEqual(backendStatus.label, "Local Backend is ready.")

        backendStatus.click()
        XCTAssertTrue(app.secureTextFields["mac.settings.localBackendPairingCode"].waitForExistence(timeout: 3))
    }

    func testLiveLocalBackendReadinessRunsInsideSandboxedMacApp() {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5))

        let backendStatus = app.buttons["mac.toolbar.localBackendStatus"]
        XCTAssertTrue(backendStatus.waitForExistence(timeout: 8))
        wait(for: [expectation(
            for: NSPredicate(format: "label BEGINSWITH %@", "Local Backend is ready."),
            evaluatedWith: backendStatus
        )], timeout: 8)
        XCTAssertTrue(
            backendStatus.label.hasPrefix("Local Backend is ready.") == true,
            "Expected the sandboxed app to complete the real HTTPS readiness check."
        )
    }

    func testLiveBonjourDiscoveryFindsBackendAndPrefillsSettings() {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5))

        let backendStatus = app.buttons["mac.toolbar.localBackendStatus"]
        XCTAssertTrue(backendStatus.waitForExistence(timeout: 10))
        wait(for: [expectation(
            for: NSPredicate(format: "label == %@", "Local Backend found and ready. Pair in Settings."),
            evaluatedWith: backendStatus
        )], timeout: 10)
        XCTAssertEqual(
            backendStatus.label,
            "Local Backend found and ready. Pair in Settings."
        )

        backendStatus.click()
        XCTAssertTrue(app.secureTextFields["mac.settings.localBackendPairingCode"].waitForExistence(timeout: 3))
        let baseURL = app.textFields["mac.settings.backendBaseURL"]
        XCTAssertTrue(baseURL.waitForExistence(timeout: 5))
        let discoveredURL = baseURL.value as? String
        XCTAssertTrue(discoveredURL?.hasPrefix("https://") == true)
        XCTAssertTrue(discoveredURL?.contains(".local:8765") == true)
    }

    func testTaskFirstWorkspaceHierarchy() {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5))

        XCTAssertTrue(app.descendants(matching: .any)["mac.sidebar.section.inbox"].exists)
        let projectRow = app.descendants(matching: .any)["mac.sidebar.project.idea_ideaforge"]
        XCTAssertTrue(projectRow.exists)
        let projectMetadata = projectRow.value as? String
        XCTAssertTrue(projectMetadata?.contains("96 seconds") == true)
        XCTAssertTrue(projectMetadata?.contains("On iPhone") == true)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "mac.sidebar.tools").count, 1)
        XCTAssertFalse(app.descendants(matching: .any)["mac.sidebar.health"].exists)
        XCTAssertFalse(app.staticTexts["Health"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["mac.sidebar.section.workflows"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["mac.sidebar.section.templates"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["mac.sidebar.section.exports"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["mac.sidebar.section.integrations"].exists)

        let tabs = app.descendants(matching: .any)["mac.projectWorkspace.tabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 4))
        let tabButtons = tabs.descendants(matching: .radioButton)
        XCTAssertEqual(tabButtons.count, 6)
        for tab in ["Summary", "Transcript", "Questions", "Ask", "Plan", "Files"] {
            XCTAssertEqual(
                tabButtons.matching(NSPredicate(format: "label == %@", tab)).count,
                1,
                "Expected exactly one \(tab) tab."
            )
        }

        for row in ["summary", "validation", "readiness"] {
            XCTAssertEqual(
                app.descendants(matching: .any).matching(identifier: "mac.overview.row.\(row)").count,
                1,
                "Expected exactly one first-level \(row) row."
            )
        }
        XCTAssertFalse(app.descendants(matching: .any)["mac.overview.metric.confidence"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["mac.overview.metric.completeness"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["mac.overview.metric.risk"].exists)
        XCTAssertFalse(app.buttons["mac.inspector.runReviewBoard"].exists)
    }

    func testTaskFirstAccessibilitySemanticsAndInspectorShortcut() {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5))

        let tools = app.descendants(matching: .any)["mac.sidebar.tools"]
        XCTAssertEqual(tools.label, "Tools")
        XCTAssertEqual(tools.value as? String, "Collapsed")

        let tabs = app.descendants(matching: .any)["mac.projectWorkspace.tabs"]
        XCTAssertEqual(tabs.label, "Project tabs")
        XCTAssertEqual(tabs.value as? String, "Summary")

        for title in ["Summary", "Validation", "Readiness"] {
            let row = app.buttons[title]
            XCTAssertTrue(row.exists)
            XCTAssertEqual(row.label, title)
            XCTAssertTrue((row.value as? String)?.hasSuffix(", Collapsed") == true)
        }

        let selectedProject = app.descendants(matching: .any)["mac.projectWorkspace.project.idea_ideaforge"]
        let inspector = app.buttons["mac.toolbar.inspector"]
        XCTAssertEqual(inspector.label, "Open Inspector")
        XCTAssertEqual(inspector.value as? String, "Closed")

        app.typeKey("i", modifierFlags: [.command, .option])
        XCTAssertTrue(app.buttons["mac.inspector.runReviewBoard"].waitForExistence(timeout: 2))
        XCTAssertEqual(inspector.label, "Close Inspector")
        XCTAssertEqual(inspector.value as? String, "Open")
        XCTAssertTrue(selectedProject.exists)
    }

    func testTabAndShiftTabTraversalReturnsFocusWithoutLosingProjectSelection() throws {
        guard NSApplication.shared.isFullKeyboardAccessEnabled else {
            throw XCTSkip("macOS Keyboard Navigation is disabled; Tab traversal requires that operator setting.")
        }
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5))

        let selectedProject = app.descendants(matching: .any)["mac.projectWorkspace.project.idea_ideaforge"]
        XCTAssertTrue(selectedProject.waitForExistence(timeout: 4))
        let overview = app.descendants(matching: .any)["mac.projectWorkspace.tabs"].radioButtons["Summary"]
        XCTAssertTrue(overview.waitForExistence(timeout: 3))

        overview.click()
        XCTAssertTrue(waitForKeyboardFocus(overview, expected: true))
        app.typeKey(.tab, modifierFlags: [])
        XCTAssertTrue(waitForKeyboardFocus(overview, expected: false))
        app.typeKey(.tab, modifierFlags: [.shift])
        XCTAssertTrue(waitForKeyboardFocus(overview, expected: true))
        XCTAssertTrue(selectedProject.exists)
    }

    func testInspectorStartsClosedAndPreservesSelection() {
        let window = mainWindow
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        let selectedProject = app.descendants(matching: .any)["mac.projectWorkspace.project.idea_ideaforge"]
        XCTAssertTrue(selectedProject.waitForExistence(timeout: 4))
        let initialFrame = selectedProject.frame
        XCTAssertFalse(app.buttons["mac.inspector.runReviewBoard"].exists)

        let inspectorToggle = app.buttons["mac.toolbar.inspector"]
        XCTAssertTrue(inspectorToggle.exists)
        inspectorToggle.click()
        XCTAssertTrue(app.buttons["mac.inspector.runReviewBoard"].waitForExistence(timeout: 2))
        XCTAssertTrue(selectedProject.exists)

        inspectorToggle.click()
        let inspectorClosed = expectation(
            for: NSPredicate(format: "exists == false"),
            evaluatedWith: app.buttons["mac.inspector.runReviewBoard"]
        )
        wait(for: [inspectorClosed], timeout: 2)
        XCTAssertTrue(selectedProject.exists)
        XCTAssertEqual(selectedProject.frame.minX, initialFrame.minX, accuracy: 2)
        XCTAssertEqual(selectedProject.frame.width, initialFrame.width, accuracy: 2)
    }

    func testSyncConflictStatusRoutesDirectlyToResolver() {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5))

        let status = app.buttons["mac.sidebar.status.resolve"]
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        status.click()

        let resolver = app.descendants(matching: .any)["mac.settings.syncConflictResolver"]
        XCTAssertTrue(resolver.waitForExistence(timeout: 3))
        let mergeButton = resolver.descendants(matching: .button)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Merge"))
            .firstMatch
        XCTAssertTrue(mergeButton.waitForExistence(timeout: 2))
        XCTAssertTrue(mergeButton.isHittable)
    }

    func testFailedUploadStatusRoutesToReviewAndRetry() {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))

        let status = app.buttons["mac.sidebar.status.review"]
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        XCTAssertEqual(status.label, "Upload status")
        XCTAssertEqual(status.value as? String, "1 upload failed")
        status.click()

        let retry = app.buttons["mac.recordingQueue.retry.rec_task_first_upload"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["mac.inbox.recordingQueue"].exists)
        XCTAssertEqual(retry.label, "Retry upload")
        XCTAssertTrue((retry.value as? String)?.hasSuffix(", Failed") == true)
    }

    func testQueuedUploadStatusRoutesToUploadQueue() {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))

        let status = app.buttons["mac.sidebar.status.upload"]
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        status.click()

        XCTAssertTrue(app.descendants(matching: .any)["mac.inbox.captureRelay"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Recording Queue"].exists)
    }

    func testMacOfflineStatusFixtureDoesNotClaimWatchIsOfflineFromLocalOnlyReachability() {
        // A selected project supplies the document window title on macOS.
        XCTAssertTrue(app.buttons["mac.toolbar.inbox"].waitForExistence(timeout: 5))

        let status = app.descendants(matching: .any)["mac.sidebar.status.informational"]
        XCTAssertFalse(status.waitForExistence(timeout: 1))
        XCTAssertEqual(app.buttons.matching(identifier: "mac.sidebar.status.informational").count, 0)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "Watch offline")).count, 0)
    }

    func testSidebarCanNavigateBackToInboxFromSelectedProject() {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5))
        app.buttons["mac.toolbar.inbox"].firstMatch.click()

        XCTAssertTrue(app.staticTexts["Inbox"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.descendants(matching: .any)["mac.inbox.recordingQueue"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["mac.projectWorkspace.project.idea_ideaforge"].exists)
    }

    func testQuietSignalMacInboxUsesCompactQueueAndSummaryMode() {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5))

        app.buttons["mac.toolbar.inbox"].click()
        XCTAssertTrue(app.descendants(matching: .any)["mac.inbox.captureRelay"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["mac.inbox.recordingQueue"].exists)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "mac.inbox.metric").count, 0)

        app.descendants(matching: .any)["mac.sidebar.project.idea_ideaforge"].click()
        let tabs = app.descendants(matching: .any)["mac.projectWorkspace.tabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 3))
        XCTAssertTrue(tabs.radioButtons["Summary"].exists)
        XCTAssertFalse(tabs.radioButtons["Overview"].exists)
    }

    func testQuietSignalInspectorUsesNativeSectionsAndRetainsCommands() {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5))

        app.buttons["mac.toolbar.inspector"].click()
        XCTAssertTrue(app.descendants(matching: .any)["mac.inspector.summary"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["mac.inspector.commandDeck"].exists)
        XCTAssertTrue(app.buttons["mac.inspector.processLocalEnrichment"].exists)
        XCTAssertTrue(app.buttons["mac.inspector.runReviewBoard"].exists)
        XCTAssertTrue(app.buttons["mac.inspector.generatePRD"].exists)
        XCTAssertTrue(app.buttons["mac.inspector.prepareCodexPacket"].exists)
    }

    func testProjectOverviewDoesNotCollapseIntoSlidingMiddleColumnInCompactWindow() throws {
        let window = mainWindow
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        let overviewTabs = app.descendants(matching: .any)["mac.projectWorkspace.tabs"]
        XCTAssertTrue(overviewTabs.waitForExistence(timeout: 4))
        let overview = app.descendants(matching: .any)["mac.overview.scroll"]
        XCTAssertTrue(overview.waitForExistence(timeout: 4))
        let summary = app.descendants(matching: .any)["mac.overview.row.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 4))
        let validation = app.descendants(matching: .any)["mac.overview.row.validation"]
        XCTAssertTrue(validation.waitForExistence(timeout: 4))

        XCTAssertGreaterThanOrEqual(
            summary.frame.minX,
            overview.frame.minX + 12,
            "The overview summary should remain anchored inside the visible project viewport, not slide under the split-view divider."
        )
        XCTAssertGreaterThan(
            summary.frame.width,
            overview.frame.width * 0.70,
            "The overview summary should fill the project viewport instead of collapsing into an intrinsic-width strip."
        )
        XCTAssertGreaterThanOrEqual(
            validation.frame.minX,
            overview.frame.minX + 12,
            "The first actionable section should stay inside the same anchored overview viewport."
        )

        XCTAssertFalse(
            app.buttons["mac.inspector.runReviewBoard"].exists,
            "The inspector should collapse out of compact project windows instead of squeezing the overview into a narrow middle column."
        )
    }

    func testMovedCapabilitiesRemainReachable() {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5))

        // SwiftUI exposes the identifier on the disclosure row, while XCTest
        // exposes its native triangle as a sibling accessibility element.
        XCTAssertEqual(app.disclosureTriangles.count, 1)
        let tools = app.disclosureTriangles.firstMatch
        XCTAssertTrue(tools.waitForExistence(timeout: 3))
        tools.click()
        for section in ["workflows", "templates", "exports", "integrations"] {
            let destination = app.descendants(matching: .any)["mac.sidebar.section.\(section)"]
            XCTAssertTrue(destination.waitForExistence(timeout: 2), "Expected \(section) under expanded Tools.")
            destination.click()
            XCTAssertTrue(
                app.descendants(matching: .any)["mac.workspace.section.\(section)"].waitForExistence(timeout: 2),
                "Expected the retained \(section) capability surface to open."
            )
        }

        let project = app.descendants(matching: .any)["mac.sidebar.project.idea_ideaforge"]
        XCTAssertTrue(project.waitForExistence(timeout: 2))
        project.click()

        let tabs = app.descendants(matching: .any)["mac.projectWorkspace.tabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 3))
        app.descendants(matching: .any)["mac.overview.row.summary"].click()
        for identifier in ["problem", "audience", "outcome"] {
            XCTAssertTrue(
                app.descendants(matching: .any)["mac.overview.summary.\(identifier)"].waitForExistence(timeout: 2)
            )
        }

        let plan = tabs.radioButtons["Plan"]
        XCTAssertTrue(plan.exists)
        plan.click()
        XCTAssertTrue(app.descendants(matching: .any)["mac.plan.workflows"].waitForExistence(timeout: 3))

        let planSection = app.popUpButtons["mac.plan.section"]
        XCTAssertTrue(planSection.exists)
        planSection.click()
        app.menuItems["Workflow Runs"].click()
        XCTAssertTrue(app.descendants(matching: .any)["mac.plan.runs"].waitForExistence(timeout: 3))
        planSection.click()
        app.menuItems["Codex Tasks"].click()
        XCTAssertTrue(app.descendants(matching: .any)["mac.plan.codexTasks"].waitForExistence(timeout: 3))

        tabs.radioButtons["Files"].click()
        XCTAssertTrue(app.descendants(matching: .any)["mac.files.artifacts"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["mac.files.prepareCodexPacket"].exists)
        XCTAssertTrue(app.buttons["mac.files.exportCodexPacket"].exists)

        tabs.radioButtons["Summary"].click()
        app.descendants(matching: .any)["mac.overview.row.readiness"].click()
        XCTAssertTrue(app.descendants(matching: .any)["mac.overview.metric.confidence"].waitForExistence(timeout: 3))
    }

    func testTaskFirstWorkspaceUsesWideWindowFixture() {
        let window = app.windows["mac.uiTesting.windowPreset.wide.applied"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        let overview = app.descendants(matching: .any)["mac.overview.scroll"]
        let summary = app.descendants(matching: .any)["mac.overview.row.summary"]
        XCTAssertTrue(overview.waitForExistence(timeout: 4))
        XCTAssertTrue(summary.waitForExistence(timeout: 4))
        XCTAssertGreaterThan(overview.frame.width, window.frame.width * 0.50)
        XCTAssertGreaterThan(summary.frame.width, overview.frame.width * 0.70)
        XCTAssertGreaterThanOrEqual(summary.frame.minX, overview.frame.minX + 12)
        XCTAssertLessThanOrEqual(overview.frame.maxX, window.frame.maxX)
    }

    private var mainWindow: XCUIElement {
        app.windows.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "mac.uiTesting.windowPreset."
        )).firstMatch
    }

    private func waitForKeyboardFocus(
        _ element: XCUIElement,
        expected: Bool,
        timeout: TimeInterval = 2
    ) -> Bool {
        let predicate = NSPredicate(format: "hasKeyboardFocus == %@", NSNumber(value: expected))
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
