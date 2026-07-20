import XCTest

@MainActor
final class IdeaForgeMacUITests: XCTestCase {
    nonisolated(unsafe) private var app: XCUIApplication!

    nonisolated override func setUpWithError() throws {
        let testName = name
        app = MainActor.assumeIsolated {
            let application = XCUIApplication()
            application.launchArguments = ["-uiTesting"]
            if testName.contains("CompactWindow") {
                application.launchArguments.append("-uiTestingCompactWindow")
            } else if testName.contains("WideWindow") {
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
            application.launch()
            return application
        }
    }

    nonisolated override func tearDownWithError() throws {
        app = nil
    }

    func testMainWindowExposesPlanningWorkflowControls() {
        XCTAssertTrue(app.windows["IdeaForge"].waitForExistence(timeout: 5))
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

    func testSettingsUsesBackendAccountPortalInsteadOfAppStoreCommerce() {
        XCTAssertTrue(app.windows["IdeaForge"].waitForExistence(timeout: 5))

        app.typeKey(",", modifierFlags: .command)

        XCTAssertTrue(app.buttons["View Plans"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Refresh Plan"].exists)
        XCTAssertTrue(app.buttons["Delete Account"].exists)
        XCTAssertFalse(app.buttons["Purchase Pro"].exists)
        XCTAssertFalse(app.buttons["Restore Purchases"].exists)
        XCTAssertFalse(app.buttons["Manage Subscription"].exists)
        XCTAssertFalse(app.buttons["Reload StoreKit"].exists)
    }

    func testTaskFirstWorkspaceHierarchy() {
        XCTAssertTrue(app.windows["IdeaForge"].waitForExistence(timeout: 5))

        XCTAssertTrue(app.descendants(matching: .any)["mac.sidebar.section.inbox"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["mac.sidebar.project.idea_ideaforge"].exists)
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
        XCTAssertEqual(tabButtons.count, 5)
        for tab in ["Overview", "Transcript", "Questions", "Plan", "Files"] {
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
        XCTAssertTrue(app.windows["IdeaForge"].waitForExistence(timeout: 5))

        let tools = app.disclosureTriangles["mac.sidebar.tools"]
        XCTAssertEqual(tools.label, "Tools")
        XCTAssertEqual(tools.value as? String, "Collapsed")

        let tabs = app.descendants(matching: .any)["mac.projectWorkspace.tabs"]
        XCTAssertEqual(tabs.label, "Project tabs")
        XCTAssertEqual(tabs.value as? String, "Overview")

        for title in ["Summary", "Validation", "Readiness"] {
            let row = app.buttons[title]
            XCTAssertTrue(row.exists)
            XCTAssertEqual(row.label, title)
            XCTAssertTrue((row.value as? String)?.hasSuffix(", Collapsed") == true)
        }

        let selectedProject = app.descendants(matching: .any)["mac.projectWorkspace.project.idea_ideaforge"]
        let inspector = app.buttons["mac.toolbar.inspector"]
        XCTAssertEqual(inspector.label, "Inspector")
        XCTAssertEqual(inspector.value as? String, "Closed")

        app.typeKey("i", modifierFlags: [.command, .option])
        XCTAssertTrue(app.buttons["mac.inspector.runReviewBoard"].waitForExistence(timeout: 2))
        XCTAssertEqual(inspector.value as? String, "Open")
        XCTAssertTrue(selectedProject.exists)
    }

    func testTabAndShiftTabTraversalReturnsFocusWithoutLosingProjectSelection() {
        XCTAssertTrue(app.windows["IdeaForge"].waitForExistence(timeout: 5))

        let selectedProject = app.descendants(matching: .any)["mac.projectWorkspace.project.idea_ideaforge"]
        XCTAssertTrue(selectedProject.waitForExistence(timeout: 4))
        let overview = app.descendants(matching: .any)["mac.projectWorkspace.tabs"].radioButtons["Overview"]
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
        let window = app.windows["IdeaForge"]
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
        XCTAssertTrue(app.windows["IdeaForge"].waitForExistence(timeout: 5))

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
        XCTAssertTrue(app.windows["IdeaForge"].waitForExistence(timeout: 5))

        let status = app.buttons["mac.sidebar.status.review"]
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        XCTAssertEqual(status.label, "Upload status")
        XCTAssertEqual(status.value as? String, "1 upload failed")
        status.click()

        XCTAssertTrue(app.descendants(matching: .any)["mac.inbox.recovery.review"].waitForExistence(timeout: 3))
        let retry = app.buttons["mac.recordingQueue.retry.rec_task_first_upload"]
        XCTAssertEqual(retry.label, "Retry upload")
        XCTAssertTrue((retry.value as? String)?.hasSuffix(", Failed") == true)
    }

    func testQueuedUploadStatusRoutesToUploadQueue() {
        XCTAssertTrue(app.windows["IdeaForge"].waitForExistence(timeout: 5))

        let status = app.buttons["mac.sidebar.status.upload"]
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        status.click()

        XCTAssertTrue(app.descendants(matching: .any)["mac.inbox.recovery.upload"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Recording Queue"].exists)
    }

    func testOfflineStatusIsInformational() {
        XCTAssertTrue(app.windows["IdeaForge"].waitForExistence(timeout: 5))

        let status = app.descendants(matching: .any)["mac.sidebar.status.informational"]
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons.matching(identifier: "mac.sidebar.status.informational").count, 0)
    }

    func testSidebarCanNavigateBackToInboxFromSelectedProject() {
        XCTAssertTrue(app.windows["IdeaForge"].waitForExistence(timeout: 5))
        app.buttons["mac.toolbar.inbox"].firstMatch.click()

        XCTAssertTrue(app.staticTexts["Inbox"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Queued recordings"].exists)
        XCTAssertTrue(app.staticTexts["Pending questions"].exists)
    }

    func testProjectOverviewDoesNotCollapseIntoSlidingMiddleColumnInCompactWindow() throws {
        let window = app.windows["IdeaForge"]
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
        XCTAssertTrue(app.windows["IdeaForge"].waitForExistence(timeout: 5))

        let tools = app.disclosureTriangles["mac.sidebar.tools"]
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

        tabs.radioButtons["Overview"].click()
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
