import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum MacWorkspaceLayout {
    static let inspectorBreakpoint: CGFloat = 840
    static let minimumInspectorWidth: CGFloat = 300
    static let maximumInspectorWidth: CGFloat = 360

    static func showsInspector(availableWidth: CGFloat) -> Bool {
        availableWidth >= inspectorBreakpoint
    }

    static func inspectorWidth(availableWidth: CGFloat) -> CGFloat {
        min(maximumInspectorWidth, max(minimumInspectorWidth, availableWidth * 0.28))
    }
}

struct MacContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openSettings) private var openSettings
    @Bindable var store: IdeaForgeStore
    var navigationState: MacNavigationState
    var backendConfigurationManager: BackendConfigurationManager
    var backendLifecycle: MacLocalBackendLifecycleModel
    @State private var selectedSection: SidebarSection = .ideas
    @State private var query = ""
    @State private var recorder = LocalAudioRecorder()
    @State private var isRecording = false
    @State private var isInspectorPresented = false
    @State private var workspaceDetailWidth: CGFloat = 0

    private var filteredProjects: [IdeaProject] {
        guard !query.isEmpty else { return store.projects }
        return store.projects.filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
            $0.summary.localizedCaseInsensitiveContains(query)
        }
    }

    private var inboxStatus: InboxStatusSnapshot? {
        InboxStatusSnapshot(
            uploadSummary: CanonicalUploadSummary(
                projects: store.projects,
                uploadJobs: store.uploadJobs,
                syncHealth: store.syncHealth
            ),
            syncConflict: store.syncHealth.syncConflictStatus,
            watchReachable: store.syncHealth.watchReachable,
            includesWatchReachability: false
        )
    }

    private var sidebarSelection: Binding<String?> {
        Binding {
            if let selectedProjectID = store.selectedProjectID {
                return "project:\(selectedProjectID)"
            }
            return "section:\(selectedSection.rawValue)"
        } set: { newValue in
            guard let newValue else { return }
            if let projectID = newValue.removingPrefix("project:") {
                store.selectedProjectID = projectID
                selectedSection = .ideas
            } else if let sectionName = newValue.removingPrefix("section:"),
                      let section = SidebarSection(rawValue: sectionName) {
                selectedSection = section
                store.selectedProjectID = nil
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(
                selection: sidebarSelection,
                projects: filteredProjects,
                inboxStatus: inboxStatus,
                onStatusAction: routeInboxStatus
            )
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
        } detail: {
            adaptiveWorkspaceDetail
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Search ideas")
        .tint(.forgeEmber)
        .task {
            await processDueWorkflowRetries()
        }
        .toolbar {
            ToolbarItemGroup {
                if backendLifecycle.isVisible {
                    Button {
                        openSettings()
                    } label: {
                        Label(
                            backendLifecycle.statusMessage,
                            systemImage: backendLifecycle.isReady
                                ? "server.rack"
                                : (backendLifecycle.isChecking ? "arrow.triangle.2.circlepath" : "server.rack")
                        )
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("mac.toolbar.localBackendStatus")
                    .accessibilityHint("Open Local Backend settings")
                    .help(backendLifecycle.statusMessage)
                }
                Button {
                    store.selectedProjectID = nil
                    selectedSection = .inbox
                } label: {
                    Label("Inbox", systemImage: "tray")
                }
                .accessibilityIdentifier("mac.toolbar.inbox")
                .help("Show the recording inbox")
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                        isInspectorPresented.toggle()
                    }
                } label: {
                    Label(
                        isInspectorPresented ? "Close Inspector" : "Open Inspector",
                        systemImage: "sidebar.trailing"
                    )
                }
                .labelStyle(.iconOnly)
                .accessibilityIdentifier("mac.toolbar.inspector")
                .accessibilityLabel("Inspector")
                .accessibilityValue(isInspectorPresented ? "Open" : "Closed")
                .accessibilityHint(isInspectorPresented ? "Closes project details" : "Opens project details")
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(
                    workspaceDetailWidth > 0
                        && !MacWorkspaceLayout.showsInspector(availableWidth: workspaceDetailWidth)
                )
                .help(
                    workspaceDetailWidth > 0
                        && !MacWorkspaceLayout.showsInspector(availableWidth: workspaceDetailWidth)
                        ? "Widen the window to open the inspector"
                        : (isInspectorPresented ? "Close the inspector" : "Open the inspector")
                )
                Button {
                    Task {
                        await store.prepareCodexPacket()
                    }
                } label: {
                    Label("Codex Packet", systemImage: "shippingbox")
                }
                .accessibilityIdentifier("mac.toolbar.codexPacket")
                .disabled(store.selectedProject == nil)
                .help(store.selectedProject == nil ? "Select an idea before preparing a Codex packet" : "Prepare a Codex packet for the selected idea")
                Button {
                    Task {
                        await toggleRecording()
                    }
                } label: {
                    Label(isRecording ? "Stop Recording" : "Record", systemImage: isRecording ? "stop.circle.fill" : "mic.circle")
                }
                .accessibilityIdentifier("mac.toolbar.record")
                .help(isRecording ? "Stop recording and add it to the workspace" : "Start recording a new idea")
            }
        }
        .onAppear {
            configureRecordingRecovery()
            Task {
                await recoverPendingRecordingIfNeeded()
            }
        }
    }

    @ViewBuilder
    private var adaptiveWorkspaceDetail: some View {
        GeometryReader { proxy in
            let availableWidth = max(proxy.size.width, 1)
            let showsInspector = isInspectorPresented
                && MacWorkspaceLayout.showsInspector(availableWidth: availableWidth)
            let inspectorWidth = showsInspector
                ? MacWorkspaceLayout.inspectorWidth(availableWidth: availableWidth)
                : 0
            let primaryWidth = showsInspector
                ? max(availableWidth - inspectorWidth - 1, 360)
                : availableWidth

            HStack(spacing: 0) {
                primaryWorkspace
                    .frame(width: primaryWidth, height: proxy.size.height, alignment: .topLeading)
                    .clipped()

                if showsInspector {
                    Divider()
                    InspectorView(
                        store: store,
                        backendConfigurationManager: backendConfigurationManager
                    )
                    .frame(width: inspectorWidth)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(width: availableWidth, height: proxy.size.height, alignment: .topLeading)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: showsInspector)
            .onAppear {
                workspaceDetailWidth = availableWidth
            }
            .onChange(of: availableWidth) { _, newWidth in
                workspaceDetailWidth = newWidth
                guard !MacWorkspaceLayout.showsInspector(availableWidth: newWidth) else { return }
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    isInspectorPresented = false
                }
            }
        }
    }

    @ViewBuilder
    private var primaryWorkspace: some View {
        if let project = store.selectedProject {
            ProjectWorkspaceView(
                project: project,
                workflows: store.workflowTemplates,
                deletionReadiness: store.projectDeletionReadiness(projectID: project.id),
                onRetryWorkflow: { runID in
                    Task {
                        await store.retryWorkflowRun(runID: runID)
                    }
                },
                onDeleteProject: { projectID in
                    store.deleteProject(projectID)
                },
                onCreateWorkflowVariant: createWorkflowVariant,
                onUpdateWorkflowStep: { templateID, stepID, update in
                    store.updateWorkflowStep(
                        templateID: templateID,
                        stepID: stepID,
                        update: update
                    )
                },
                onAddWorkflowVariable: { templateID, variable in
                    store.addWorkflowVariable(
                        templateID: templateID,
                        variable: variable
                    )
                },
                onUpdateWorkflowVariable: { templateID, variableKey, variable in
                    store.updateWorkflowVariable(
                        templateID: templateID,
                        variableKey: variableKey,
                        variable: variable
                    )
                },
                onDeleteWorkflowVariable: { templateID, variableKey in
                    store.deleteWorkflowVariable(
                        templateID: templateID,
                        variableKey: variableKey
                    )
                },
                onAddSchemaField: { templateID, schemaName, field in
                    store.addWorkflowSchemaField(
                        templateID: templateID,
                        schemaName: schemaName,
                        field: field
                    )
                },
                onUpdateSchemaField: { templateID, schemaName, fieldName, field in
                    store.updateWorkflowSchemaField(
                        templateID: templateID,
                        schemaName: schemaName,
                        fieldName: fieldName,
                        updatedField: field
                    )
                },
                onDeleteSchemaField: { templateID, schemaName, fieldName in
                    store.deleteWorkflowSchemaField(
                        templateID: templateID,
                        schemaName: schemaName,
                        fieldName: fieldName
                    )
                },
                onMoveSchemaField: { templateID, schemaName, fieldName, direction in
                    store.moveWorkflowSchemaField(
                        templateID: templateID,
                        schemaName: schemaName,
                        fieldName: fieldName,
                        direction: direction
                    )
                },
                onUpdateTranscriptText: { projectID, text in
                    store.updateTranscriptText(text, projectID: projectID)
                },
                onAddValidationExperiment: { projectID, title, metric, criteria in
                    store.addValidationExperiment(
                        projectID: projectID,
                        title: title,
                        metric: metric,
                        goNoGoCriteria: criteria
                    )
                },
                onAddAssumption: { projectID, text, evidence, confidence in
                    store.addAssumption(
                        projectID: projectID,
                        text: text,
                        evidence: evidence,
                        confidence: confidence
                    )
                },
                onUpdateArtifactMarkdown: { artifactID, markdown in
                    store.updateArtifactMarkdown(
                        artifactID: artifactID,
                        markdown: markdown
                    )
                },
                onUpdateTranscriptSegment: { projectID, segmentID, text, isMarkedImportant in
                    store.updateTranscriptSegment(
                        projectID: projectID,
                        segmentID: segmentID,
                        text: text,
                        isMarkedImportant: isMarkedImportant
                    )
                },
                onPrepareCodexPacket: {
                    Task {
                        await store.prepareCodexPacket()
                    }
                },
                onExportCodexPacket: {
                    Task {
                        await store.exportCodexPacket()
                    }
                },
                onExportIdeaBrief: {
                    exportIdeaBrief(project)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            WorkspaceSectionView(
                section: selectedSection,
                projects: store.projects,
                workflows: store.workflowTemplates,
                queuedRecordings: store.queuedRecordings,
                questions: store.pendingQuestions,
                retryableRecordingIDs: Set(
                    store.queuedRecordings.lazy
                        .filter { store.canRetryUpload(recordingID: $0.id) }
                        .map(\.id)
                ),
                onRetryUpload: { recordingID in
                    _ = store.retryUpload(recordingID: recordingID)
                },
                onShowInbox: {
                    store.selectedProjectID = nil
                    selectedSection = .inbox
                }
            )
        }
    }

    private func exportIdeaBrief(_ project: IdeaProject) {
        let brief = IdeaBriefExporter.brief(for: project)
        let panel = NSSavePanel()
        panel.title = "Export Idea as Markdown"
        panel.nameFieldStringValue = brief.filename
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try Data(brief.markdown.utf8).write(to: destination, options: [.atomic])
            IdeaForgeLog.export.info("macOS Markdown idea brief exported")
        } catch {
            store.lastErrorMessage = "Markdown export failed. Choose another writable folder and try again."
            IdeaForgeLog.export.error("macOS Markdown idea brief export failed")
        }
    }

    private func routeInboxStatus(_ action: InboxStatusAction) {
        if action == .resolve {
            navigationState.settingsDestination = .syncConflictResolver
            openSettings()
            return
        }
        store.selectedProjectID = nil
        selectedSection = .inbox
    }

    private func createWorkflowVariant(_ workflow: WorkflowTemplate) {
        store.createCustomWorkflowTemplate(
            WorkflowTemplateCustomization(
                baseTemplateID: workflow.id,
                name: "\(workflow.name) Review Variant",
                summary: "Review-gated variant of \(workflow.name) with stricter model policy and explicit schema checkpoints.",
                stepUpdates: workflow.steps.map { step in
                    WorkflowStepUpdate(
                        stepID: step.id,
                        outputSchemaName: "\(step.outputSchemaName)Review",
                        requiresUserReview: true,
                        modelPolicy: .best
                    )
                },
                schemaContracts: workflow.steps.map { step in
                    let reviewSchemaName = "\(step.outputSchemaName)Review"
                    if let contract = workflow.schemaContract(named: step.outputSchemaName) {
                        return contract.reviewVariant(named: reviewSchemaName)
                    }
                    return WorkflowSchemaContract(
                        name: reviewSchemaName,
                        requiredInputKeys: step.inputKeys,
                        summary: "Review-gated variant of \(step.outputSchemaName).",
                        fields: [
                            WorkflowSchemaField(
                                name: "review_notes",
                                valueType: "string",
                                summary: "Human review notes required before handoff."
                            )
                        ]
                    )
                }
            )
        )
    }

    private func processDueWorkflowRetries() async {
        do {
            let summary = try await ConfiguredWorkflowRetryProcessor(
                backendConfigurationManager: backendConfigurationManager
            )
            .processDueRetries(in: store)

            guard summary.attemptedCount > 0 || summary.skippedCount > 0 else { return }
            if summary.skippedCount > 0 && summary.attemptedCount == 0 {
                IdeaForgeLog.workflow.warning("macOS workflow retry processing skipped; backend AI unavailable or privacy mode blocks cloud AI")
            } else {
                IdeaForgeLog.workflow.info("macOS workflow retry processing completed; attempted: \(summary.attemptedCount, privacy: .public), completed: \(summary.completedCount, privacy: .public), failed: \(summary.failedCount, privacy: .public), skipped: \(summary.skippedCount, privacy: .public)")
            }
        } catch BackendConfigurationError.invalidBaseURL {
            IdeaForgeLog.workflow.error("macOS workflow retry processing skipped; invalid backend URL")
        } catch {
            IdeaForgeLog.workflow.error("macOS workflow retry processing failed")
        }
    }

    private func toggleRecording() async {
        do {
            if isRecording {
                IdeaForgeLog.recording.info("macOS recording stop requested")
                let draft = try recorder.stop(
                    projectTitle: "Mac captured idea",
                    tag: .appIdea,
                    source: .mac,
                    transcriptHint: "Voice idea captured on Mac for planning."
                )
                isRecording = false
                if await store.capture(draft) != nil {
                    try recorder.acknowledgePersistence()
                }
            } else {
                IdeaForgeLog.recording.info("macOS recording start requested")
                try await recorder.start(
                    recoveryContext: RecordingCaptureContext(
                        projectTitle: "Mac captured idea",
                        tag: .appIdea,
                        source: .mac,
                        transcriptHint: "Voice idea captured on Mac for planning."
                    )
                )
                isRecording = true
            }
        } catch {
            isRecording = false
            store.lastErrorMessage = (error as? UserFacingIdeaForgeError)?.userFacingMessage ?? "Recording failed."
            IdeaForgeLog.recording.error("macOS recording control failed")
        }
    }

    private func configureRecordingRecovery() {
        recorder.setUnexpectedTerminationHandler { reason in
            isRecording = false
            Task {
                await recoverPendingRecordingIfNeeded(expectedReason: reason)
            }
        }
    }

    private func recoverPendingRecordingIfNeeded(
        expectedReason: RecordingTerminationReason? = nil
    ) async {
        guard !recorder.isRecording else {
            isRecording = true
            return
        }
        do {
            guard let recovery = try recorder.pendingRecovery() else { return }
            guard await store.capture(recovery.draft) != nil else {
                store.lastErrorMessage = "A saved recording still needs recovery. Try again before recording again."
                return
            }
            try recorder.acknowledgePersistence()
            isRecording = false
            let reason = expectedReason ?? recovery.terminationReason
            store.lastErrorMessage = reason == .userStopped
                ? "A recording saved before the app closed was recovered."
                : "An interrupted recording was recovered and kept in the Inbox."
            IdeaForgeLog.recording.info("macOS recording recovery completed")
        } catch {
            isRecording = false
            store.lastErrorMessage = (error as? UserFacingIdeaForgeError)?.userFacingMessage
                ?? "A saved recording could not be recovered."
            IdeaForgeLog.recording.error("macOS recording recovery failed")
        }
    }
}

enum SidebarSection: String, CaseIterable, Identifiable {
    case inbox
    case ideas
    case workflows
    case templates
    case exports
    case integrations

    var id: String { rawValue }

    var label: String {
        switch self {
        case .inbox: "Inbox"
        case .ideas: "Ideas"
        case .workflows: "Workflows"
        case .templates: "Templates"
        case .exports: "Exports"
        case .integrations: "Integrations"
        }
    }

    var icon: String {
        switch self {
        case .inbox: "tray"
        case .ideas: "lightbulb"
        case .workflows: "point.3.connected.trianglepath.dotted"
        case .templates: "doc.on.doc"
        case .exports: "square.and.arrow.up"
        case .integrations: "puzzlepiece.extension"
        }
    }
}

struct SidebarView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selection: String?
    var projects: [IdeaProject]
    var inboxStatus: InboxStatusSnapshot?
    var onStatusAction: (InboxStatusAction) -> Void
    @State private var isToolsExpanded = false

    private let toolSections: [SidebarSection] = [.workflows, .templates, .exports, .integrations]

    var body: some View {
        List(selection: $selection) {
            Section("Workspace") {
                SidebarSectionRow(section: .inbox, isSelected: selection == "section:inbox")
                    .tag("section:inbox")
                    .accessibilityIdentifier("mac.sidebar.section.inbox")

                if let inboxStatus {
                    if let action = inboxStatus.action {
                        Button {
                            onStatusAction(action)
                        } label: {
                            statusLabel(inboxStatus)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("mac.sidebar.status.\(action.rawValue)")
                        .accessibilityLabel(statusAccessibilityLabel(inboxStatus))
                        .accessibilityValue(inboxStatus.title)
                        .help(statusHelp(for: action))
                    } else {
                        statusLabel(inboxStatus)
                            .accessibilityIdentifier("mac.sidebar.status.informational")
                            .accessibilityLabel("Watch status")
                            .accessibilityValue(inboxStatus.title)
                            .help("Recording remains available on Watch until sync reconnects")
                    }
                }
            }

            Section("Idea Projects") {
                ForEach(projects) { project in
                    ProjectSidebarRow(
                        project: project,
                        isSelected: selection == "project:\(project.id)"
                    )
                        .tag("project:\(project.id)")
                        .accessibilityIdentifier("mac.sidebar.project.\(project.id)")
                }
            }

            DisclosureGroup(isExpanded: toolsExpansion) {
                ForEach(toolSections) { section in
                    SidebarSectionRow(
                        section: section,
                        isSelected: selection == "section:\(section.rawValue)"
                    )
                    .tag("section:\(section.rawValue)")
                    .accessibilityIdentifier("mac.sidebar.section.\(section.rawValue)")
                }
            } label: {
                Label("Tools", systemImage: "wrench.and.screwdriver")
                    .font(.body.weight(.medium))
                    .accessibilityIdentifier("mac.sidebar.tools")
                    .accessibilityLabel("Tools")
                    .accessibilityValue(isToolsExpanded ? "Expanded" : "Collapsed")
                    .accessibilityHint("Shows Workflows, Templates, Exports, and Integrations")
            }
        }
        .listStyle(.sidebar)
        .focusSection()
    }

    private var toolsExpansion: Binding<Bool> {
        Binding(
            get: { isToolsExpanded },
            set: { newValue in
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                    isToolsExpanded = newValue
                }
            }
        )
    }

    private func statusLabel(_ status: InboxStatusSnapshot) -> some View {
        Label(status.title, systemImage: status.symbolName)
            .font(.caption)
            .foregroundStyle(status.tint)
    }

    private func statusHelp(for action: InboxStatusAction) -> String {
        switch action {
        case .resolve: "Open sync conflict resolution"
        case .review: "Review failed uploads"
        case .upload: "Open the upload queue"
        }
    }

    private func statusAccessibilityLabel(_ status: InboxStatusSnapshot) -> String {
        switch status.kind {
        case .syncConflict: "Sync status"
        case .failedUpload, .queuedUpload: "Upload status"
        case .offline: "Watch status"
        }
    }
}

private extension InboxStatusSnapshot {
    var symbolName: String {
        switch kind {
        case .syncConflict: "arrow.triangle.2.circlepath"
        case .failedUpload: "exclamationmark.triangle"
        case .queuedUpload: "arrow.up.circle"
        case .offline: "applewatch.slash"
        }
    }

    var tint: Color {
        switch kind {
        case .syncConflict, .failedUpload: .orange
        case .queuedUpload: .blue
        case .offline: .secondary
        }
    }
}

private struct SidebarSectionRow: View {
    var section: SidebarSection
    var isSelected: Bool

    var body: some View {
        Label {
            Text(section.label)
                .font(.body.weight(isSelected ? .semibold : .regular))
        } icon: {
            Image(systemName: section.icon)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .symbolRenderingMode(.hierarchical)
        }
        .padding(.vertical, 3)
        .accessibilityLabel(section.label)
    }
}

struct WorkspaceSectionView: View {
    var section: SidebarSection
    var projects: [IdeaProject]
    var workflows: [WorkflowTemplate]
    var queuedRecordings: [Recording]
    var questions: [Question]
    var retryableRecordingIDs: Set<String>
    var onRetryUpload: (String) -> Void
    var onShowInbox: () -> Void

    @ViewBuilder
    var body: some View {
        if section == .ideas && projects.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("Your first recording creates an idea.")
                    .font(.title3.weight(.semibold))
                Button(action: onShowInbox) {
                    Label("Open Inbox", systemImage: "tray")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .accessibilityIdentifier("mac.emptyProjects.inbox")
                .help("Open Inbox to review recordings")
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityIdentifier("mac.emptyProjects")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(section.label, systemImage: section.icon)
                            .font(.title2.weight(.semibold))
                            .accessibilityIdentifier("mac.workspace.section.\(section.rawValue)")
                        Text(section.subtitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    switch section {
                    case .inbox:
                        MacCaptureRelayOverview(recordings: queuedRecordings)
                            .accessibilityIdentifier("mac.inbox.captureRelay")
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Label("Recording Queue", systemImage: "waveform.badge.mic")
                                    .font(.headline)
                                    .accessibilityIdentifier("mac.inbox.recordingQueue")
                                Spacer()
                                Text("\(queuedRecordings.count)")
                                    .font(.caption.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            if queuedRecordings.isEmpty {
                                Text("No recordings are waiting on this Mac.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 4)
                            } else {
                                ForEach(queuedRecordings) { recording in
                                    RecordingQueueSummaryRow(
                                        recording: recording,
                                        canRetryUpload: retryableRecordingIDs.contains(recording.id),
                                        onRetryUpload: { onRetryUpload(recording.id) }
                                    )
                                }
                            }
                        }
                    case .ideas:
                        SummaryGrid(items: projects.map { ($0.title, $0.status.label, "lightbulb") })
                    case .workflows, .templates:
                        SummaryGrid(items: workflows.map { ($0.name, "\($0.steps.count) steps", "point.3.connected.trianglepath.dotted") })
                    case .exports:
                        SummaryGrid(items: [
                            ("Markdown", "Ready", "doc.text"),
                            ("Codex packet", "Review required", "shippingbox"),
                            ("GitHub issues", "Not connected", "puzzlepiece.extension")
                        ])
                    case .integrations:
                        SummaryGrid(items: IntegrationProvider.allCases.map { provider in
                            (provider.label, "Configure in Settings", provider.symbolName)
                        })
                    }
                }
                .padding(24)
                .frame(maxWidth: 940, alignment: .leading)
            }
            .navigationTitle(section.label)
        }
    }
}

private struct MacCaptureRelayOverview: View {
    var recordings: [Recording]

    private var watchCount: Int {
        recordings.filter { $0.deviceName.localizedCaseInsensitiveContains("watch") }.count
    }

    private var phoneCount: Int {
        recordings.filter { $0.deviceName.localizedCaseInsensitiveContains("iphone") }.count
    }

    private var statusTitle: String {
        recordings.isEmpty ? "Ready for synced captures" : "\(recordings.count) local capture\(recordings.count == 1 ? "" : "s") need the next step"
    }

    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 7) {
                Text("CAPTURE RELAY")
                    .font(.caption.monospaced().weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(Color.forgeEmber)
                Text(statusTitle)
                    .font(.title3.weight(.semibold))
                Text("Counts reflect recordings present in this Mac workspace—never an inferred device receipt.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            HStack(spacing: 12) {
                VStack(alignment: .trailing, spacing: 8) {
                    sourceRow(symbol: "applewatch", value: watchCount, label: "Watch source")
                    sourceRow(symbol: "iphone", value: phoneCount, label: "iPhone source")
                }
                Image(systemName: "arrow.right")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(recordings.isEmpty ? Color.secondary.opacity(0.34) : Color.forgeEmber)
                    .accessibilityHidden(true)
                relayNode(symbol: "desktopcomputer", value: recordings.count, label: "This Mac")
            }
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [Color.forgeEmber.opacity(0.10), Color.forgeMagenta.opacity(0.045), Color.clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: UnevenRoundedRectangle(
                topLeadingRadius: 24,
                bottomLeadingRadius: 10,
                bottomTrailingRadius: 24,
                topTrailingRadius: 10,
                style: .continuous
            )
        )
        .overlay {
            UnevenRoundedRectangle(
                topLeadingRadius: 24,
                bottomLeadingRadius: 10,
                bottomTrailingRadius: 24,
                topTrailingRadius: 10,
                style: .continuous
            )
            .strokeBorder(Color.forgeEmber.opacity(0.20), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Capture relay")
        .accessibilityValue(statusTitle)
        .accessibilityIdentifier("mac.inbox.captureRelay")
    }

    private func relayNode(symbol: String, value: Int, label: String) -> some View {
        VStack(spacing: 5) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: symbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(value > 0 ? Color.black : Color.secondary)
                    .frame(width: 42, height: 42)
                    .background(value > 0 ? Color.forgeEmber : Color.secondary.opacity(0.10), in: Circle())
                if value > 0 {
                    Text("\(value)")
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(.black, in: Circle())
                        .offset(x: 4, y: -4)
                }
            }
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func sourceRow(symbol: String, value: Int, label: String) -> some View {
        HStack(spacing: 7) {
            Text(value > 0 ? "\(value)" : "—")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(value > 0 ? Color.primary : Color.secondary)
            Label(label, systemImage: symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(value > 0 ? Color.forgeEmber : Color.secondary)
        }
    }
}

private struct RecordingQueueSummaryRow: View {
    var recording: Recording
    var canRetryUpload: Bool
    var onRetryUpload: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: recording.deviceName.contains("Watch") ? "applewatch" : "waveform")
                .frame(width: 24, height: 24)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(recording.deviceName)
                        .font(.callout.weight(.semibold))
                    Text("\(recording.durationSeconds)s")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(recording.syncStatus.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(recording.syncStatus == .failed ? .orange : .secondary)
                }
                if let diagnostic = recording.processingDiagnostic {
                    Label(recordingDiagnosticText(diagnostic), systemImage: diagnostic.isRetryable ? "arrow.clockwise.circle" : "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(diagnostic.isRetryable ? .orange : .red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("mac.recordingQueue.failureDiagnostic.\(recording.id)")
                }
            }
            Spacer()
            if canRetryUpload {
                Button(action: onRetryUpload) {
                    Label("Retry Upload", systemImage: "arrow.clockwise")
                }
                .controlSize(.regular)
                .accessibilityIdentifier("mac.recordingQueue.retry.\(recording.id)")
                .accessibilityLabel("Retry upload")
                .accessibilityValue("\(recording.deviceName), \(recording.durationSeconds) seconds, Failed")
                .help("Queues the retained recording without replacing its audio")
            }
        }
        .padding(.vertical, 6)
    }

    private func recordingDiagnosticText(_ diagnostic: RecordingProcessingDiagnostic) -> String {
        diagnostic.isRetryable ? "\(diagnostic.message) Retry available." : diagnostic.message
    }
}

struct SummaryGrid: View {
    var items: [(title: String, detail: String, symbol: String)]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                MacGlassMetricCard(
                    title: item.title,
                    detail: item.detail,
                    symbol: item.symbol,
                    tint: accentColor(for: index)
                )
            }
        }
    }

    private func accentColor(for index: Int) -> Color {
        [.forgeEmber, .forgeCoral, .forgeMagenta, .forgeSpark, .mint, .purple][index % 6]
    }
}

private extension String {
    func removingPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}

struct ProjectSidebarRow: View {
    var project: IdeaProject
    var isSelected = false

    private var latestRecording: Recording? {
        project.recordings.max { $0.createdAt < $1.createdAt }
    }

    private var visibleRecordingMetadata: String? {
        guard let recording = latestRecording else { return nil }
        let recordedAt = recording.createdAt.formatted(date: .abbreviated, time: .shortened)
        return "\(recordedAt) · \(compactDuration(recording.durationSeconds)) · \(recording.syncStatus.label)"
    }

    private var accessibleRecordingMetadata: String? {
        guard let recording = latestRecording else { return nil }
        let recordedAt = recording.createdAt.formatted(date: .abbreviated, time: .shortened)
        return "\(recording.deviceName), recorded \(recordedAt), \(recording.durationSeconds) seconds, \(recording.syncStatus.label)"
    }

    var body: some View {
        Label {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.title)
                        .font(.body.weight(isSelected ? .semibold : .regular))
                        .lineLimit(1)
                    if let visibleRecordingMetadata {
                        Text(visibleRecordingMetadata)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
            }
        } icon: {
            Image(systemName: project.macSymbol)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .symbolRenderingMode(.hierarchical)
        }
        .padding(.vertical, latestRecording == nil ? 3 : 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(project.title)
        .accessibilityValue(accessibleRecordingMetadata ?? project.status.label)
    }

    private func compactDuration(_ totalSeconds: Int) -> String {
        let seconds = max(totalSeconds, 0)
        let minutes = seconds / 60
        let remainder = seconds % 60
        if minutes == 0 { return "\(remainder)s" }
        if remainder == 0 { return "\(minutes)m" }
        return "\(minutes)m \(remainder)s"
    }
}
