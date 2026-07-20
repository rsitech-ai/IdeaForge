import AppKit
import SwiftUI

struct InspectorView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var store: IdeaForgeStore
    private let backendConfigurationManager: BackendConfigurationManager
    @State private var isRunning = false
    @State private var aiStatusMessage: String?
    @State private var accountUsageSummary: BackendAccountUsageSummary?
    @State private var aiAuthenticatedSession: BackendAuthenticatedSession?

    init(
        store: IdeaForgeStore,
        backendConfigurationManager: BackendConfigurationManager = .production()
    ) {
        self.store = store
        self.backendConfigurationManager = backendConfigurationManager
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                MacGlassPanel(tint: .indigo.opacity(0.12), interactive: false, isLive: isRunning) {
                    MacInspectorCommandDeck(
                        isRunning: isRunning,
                        hasSelectedProject: store.selectedProject != nil,
                        runReviewBoard: { runWorkflow("wf_app_idea_mvp") },
                        generatePRD: { runWorkflow("wf_prd") },
                        transcribeUploadedAudio: transcribeUploadedAudio,
                        prepareCodexPacket: runCodexPacket,
                        exportPacketFiles: exportCodexPacket
                    )
                }
                .animation(reduceMotion ? nil : .snappy(duration: 0.24), value: isRunning)

                if let error = store.lastErrorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if let aiStatusMessage {
                    Text(aiStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                Label("Questions", systemImage: "questionmark.bubble")
                    .font(.headline)
                ForEach(store.pendingQuestions.prefix(4)) { question in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(question.prompt)
                            .font(.callout.weight(.medium))
                        Text(question.isBlocking ? "Blocks workflow" : "Improves artifact quality")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                }

                MacGlassPanel(
                    tint: store.syncHealth.syncConflictStatus == nil ? .cyan.opacity(0.10) : .red.opacity(0.12),
                    interactive: false,
                    isLive: store.syncHealth.syncConflictStatus != nil || store.syncHealth.queuedUploads > 0
                ) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .center, spacing: 10) {
                            Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                                .font(.headline)
                            Spacer(minLength: 12)
                            MacLiveFlowRibbon(
                                tint: store.syncHealth.syncConflictStatus == nil ? .cyan : .red,
                                isActive: store.syncHealth.queuedUploads > 0 && !reduceMotion
                            )
                            .frame(width: 132, height: 16)
                        }
                        HStack(spacing: 10) {
                            MacInspectorMetricPill(
                                title: "Watch",
                                value: store.syncHealth.watchReachable ? "Reachable" : "Offline",
                                symbol: store.syncHealth.watchReachable ? "applewatch.radiowaves.left.and.right" : "applewatch.slash",
                                tint: store.syncHealth.watchReachable ? .mint : .secondary
                            )
                            MacInspectorMetricPill(
                                title: "Queued",
                                value: "\(store.syncHealth.queuedUploads)",
                                symbol: "tray",
                                tint: .cyan
                            )
                            MacInspectorMetricPill(
                                title: "Failures",
                                value: "\(store.syncHealth.failingItems)",
                                symbol: "exclamationmark.triangle",
                                tint: store.syncHealth.failingItems == 0 ? .mint : .orange
                            )
                        }
                        if let conflict = store.syncHealth.syncConflictStatus {
                            Text(conflict.recoveryAction)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                            MacSyncConflictReviewList(conflict: conflict)
                        }
                    }
                }

                MacGlassPanel(tint: .mint.opacity(0.10), interactive: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Privacy", systemImage: "lock.shield")
                            .font(.headline)
                        Picker("Mode", selection: privacyModeBinding) {
                            ForEach(PrivacyMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        Text(store.privacyMode.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func runWorkflow(_ templateID: String) {
        isRunning = true
        IdeaForgeLog.workflow.info("macOS inspector requested workflow: \(templateID, privacy: .public)")
        Task {
            defer { isRunning = false }
            do {
                let services = try await resolvedAIServices()
                await store.runWorkflow(templateID: templateID, services: services)
            } catch BackendConfigurationError.invalidBaseURL {
                aiStatusMessage = "Backend URL invalid."
                IdeaForgeLog.workflow.error("macOS backend AI workflow skipped; invalid backend URL")
            } catch InspectorAIActionError.accountUsageUnavailable {
                aiStatusMessage = "Backend AI needs account usage before running."
                IdeaForgeLog.workflow.error("macOS backend AI workflow skipped; account usage unavailable")
            } catch InspectorAIActionError.capabilityDenied(let reason) {
                aiStatusMessage = "Backend AI needs validated backend capability. \(reason)"
                IdeaForgeLog.workflow.warning("macOS backend AI workflow skipped; capability gate blocked action")
            } catch {
                aiStatusMessage = "Backend AI workflow failed."
                IdeaForgeLog.workflow.error("macOS backend AI workflow failed")
            }
        }
    }

    private func transcribeUploadedAudio() {
        isRunning = true
        Task {
            defer { isRunning = false }
            guard AIServicePolicy.allowsCloudAI(privacyMode: store.privacyMode) else {
                aiStatusMessage = "Private mode blocks backend AI."
                IdeaForgeLog.workflow.warning("macOS backend AI processing skipped; privacy mode blocks cloud AI")
                return
            }

            do {
                try await validateAIBackendCapability()
                guard let configuration = try backendConfigurationManager.resolvedAIConfiguration() else {
                    aiStatusMessage = "Backend AI needs remote settings, workspace ID, and a token."
                    IdeaForgeLog.workflow.warning("macOS backend AI processing skipped; configuration missing")
                    return
                }

                let services = BackendAIServiceFactory.services(
                    configuration: configuration,
                    privacyMode: store.privacyMode,
                    accountUsageSummary: try await refreshedAccountUsageSummary()
                )
                let summary = await store.processUploadedRecordingsForTranscription(services: services)
                if summary.attemptedCount == 0 {
                    aiStatusMessage = "No uploaded recordings are ready for AI."
                } else if summary.failedCount > 0 {
                    aiStatusMessage = "\(summary.completedCount) transcribed, \(summary.failedCount) failed."
                } else {
                    aiStatusMessage = "\(summary.completedCount) recording transcription completed."
                }
                IdeaForgeLog.workflow.info("macOS backend AI processing completed; attempted: \(summary.attemptedCount, privacy: .public), completed: \(summary.completedCount, privacy: .public), failed: \(summary.failedCount, privacy: .public)")
            } catch BackendConfigurationError.invalidBaseURL {
                aiStatusMessage = "Enter a valid https:// backend URL."
                IdeaForgeLog.workflow.error("macOS backend AI processing failed; invalid backend URL")
            } catch InspectorAIActionError.capabilityDenied(let reason) {
                aiStatusMessage = "Backend AI needs validated backend capability. \(reason)"
                IdeaForgeLog.workflow.warning("macOS backend AI processing skipped; capability gate blocked action")
            } catch {
                aiStatusMessage = "Backend AI failed."
                IdeaForgeLog.workflow.error("macOS backend AI processing failed")
            }
        }
    }

    private func runCodexPacket() {
        isRunning = true
        IdeaForgeLog.export.info("macOS inspector requested Codex packet preparation")
        Task {
            defer { isRunning = false }
            await store.prepareCodexPacket()
        }
    }

    private func exportCodexPacket() {
        isRunning = true
        IdeaForgeLog.export.info("macOS inspector requested Codex packet export")
        Task {
            defer { isRunning = false }
            await store.exportCodexPacket()
            if let url = store.lastExportedPacketURL {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    private var privacyModeBinding: Binding<PrivacyMode> {
        Binding(
            get: { store.privacyMode },
            set: { store.setPrivacyMode($0) }
        )
    }

    private func resolvedAIServices() async throws -> IdeaForgeServices {
        let configuration = try backendConfigurationManager.resolvedAIConfiguration()
        if configuration == nil {
            aiStatusMessage = "Local workflow active."
            return .local
        }
        guard AIServicePolicy.allowsCloudAI(privacyMode: store.privacyMode) else {
            aiStatusMessage = "Private mode: local workflow used."
            return .local
        }
        try await validateAIBackendCapability()
        let services = BackendAIServiceFactory.services(
            configuration: configuration,
            privacyMode: store.privacyMode,
            accountUsageSummary: try await refreshedAccountUsageSummary()
        )
        aiStatusMessage = "Backend AI workflow enabled."
        return services
    }

    private func refreshedAccountUsageSummary() async throws -> BackendAccountUsageSummary {
        guard let configuration = try backendConfigurationManager.resolvedAccountConfiguration() else {
            throw InspectorAIActionError.accountUsageUnavailable
        }
        let summary = try await BackendAccountUsageClient(configuration: configuration).fetchUsageSummary()
        accountUsageSummary = summary
        return summary
    }

    private func validateAIBackendCapability() async throws {
        guard let authConfiguration = try backendConfigurationManager.resolvedAuthConfiguration() else {
            throw InspectorAIActionError.capabilityDenied("Validate backend session before using this backend action.")
        }
        let session = try await BackendAuthSessionClient(configuration: authConfiguration).validateSession()
        let decision = BackendCapabilityGate(session: session).decision(
            requiredCapabilities: [.runAIWorkflows],
            expectedWorkspaceID: authConfiguration.workspaceID
        )
        guard decision.isAllowed else {
            throw InspectorAIActionError.capabilityDenied(decision.blockerSummary)
        }
        aiAuthenticatedSession = session
        IdeaForgeLog.workflow.info("macOS backend AI capability validated; capabilities: \(session.capabilities.count, privacy: .public)")
    }
}

private enum InspectorAIActionError: Error {
    case accountUsageUnavailable
    case capabilityDenied(String)
}

private struct MacSyncConflictReviewList: View {
    var conflict: WorkspaceSyncConflictStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Review before merge")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if conflict.reviewItems.isEmpty {
                Text("Item details are unavailable for this legacy conflict. Counts are preserved; retry sync to rebuild a full review.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(conflict.reviewItems) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: item.systemImageName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.red)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(item.kind.label): \(item.projectTitle)")
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.82)
                            Text("\(item.sourceLabel) - \(item.statusLabel) - \(item.detail)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let preview = item.fieldDiffPreview {
                                MacSyncConflictDiffPreview(preview: preview)
                            }
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.red.opacity(0.16))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mac.inspector.syncConflictReview")
    }
}

private struct MacSyncConflictSelectionList: View {
    var conflict: WorkspaceSyncConflictStatus
    @Binding var selectedReviewItemIDs: Set<String>
    @Binding var customMergeValuesByItemID: [String: String]
    @Binding var itemPrimaryValuesByItemID: [String: String]
    @Binding var itemSecondaryValuesByItemID: [String: String]
    @Binding var itemTertiaryValuesByItemID: [String: String]
    @Binding var itemFlagValuesByItemID: [String: Bool]
    @Binding var itemNumericValuesByItemID: [String: Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reviewed merge choices")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if conflict.reviewItems.isEmpty {
                Text("Legacy conflict details are unavailable. The merge action will preserve all counted local upload work.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(conflict.reviewItems) { item in
                    MacSyncConflictChoiceRow(
                        item: item,
                        isSelected: isKeeping(item),
                        keepBinding: keepBinding(for: item),
                        customMergeValue: customValueBinding(for: item),
                        itemPrimaryValue: itemTextBinding(for: item, storage: $itemPrimaryValuesByItemID),
                        itemSecondaryValue: itemTextBinding(for: item, storage: $itemSecondaryValuesByItemID),
                        itemTertiaryValue: itemTextBinding(for: item, storage: $itemTertiaryValuesByItemID),
                        itemFlagValue: itemFlagBinding(for: item),
                        itemNumericValue: itemNumericBinding(for: item)
                    )
                }
            }
        }
        .padding(10)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.red.opacity(0.16))
        }
        .onAppear(perform: resetSelectionIfNeeded)
        .onChange(of: conflict.reviewItems.map(\.id)) { _, _ in
            resetSelectionIfNeeded()
        }
        .accessibilityIdentifier("mac.settings.syncConflictChoices")
    }

    private func keepBinding(for item: WorkspaceSyncConflictReviewItem) -> Binding<Bool> {
        Binding(
            get: {
                isKeeping(item)
            },
            set: { isSelected in
                if selectedReviewItemIDs.isEmpty {
                    selectedReviewItemIDs = Set(conflict.reviewItems.map(\.id))
                }
                if isSelected {
                    selectedReviewItemIDs.insert(item.id)
                } else if selectedReviewItemIDs.count > 1 {
                    selectedReviewItemIDs.remove(item.id)
                }
            }
        )
    }

    private func customValueBinding(for item: WorkspaceSyncConflictReviewItem) -> Binding<String> {
        Binding(
            get: {
                customMergeValuesByItemID[item.id, default: ""]
            },
            set: { newValue in
                if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    customMergeValuesByItemID.removeValue(forKey: item.id)
                } else {
                    customMergeValuesByItemID[item.id] = newValue
                    selectedReviewItemIDs.insert(item.id)
                }
            }
        )
    }

    private func itemTextBinding(
        for item: WorkspaceSyncConflictReviewItem,
        storage: Binding<[String: String]>
    ) -> Binding<String> {
        Binding(
            get: {
                storage.wrappedValue[item.id, default: ""]
            },
            set: { newValue in
                if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    storage.wrappedValue.removeValue(forKey: item.id)
                } else {
                    storage.wrappedValue[item.id] = newValue
                    selectedReviewItemIDs.insert(item.id)
                }
            }
        )
    }

    private func itemFlagBinding(for item: WorkspaceSyncConflictReviewItem) -> Binding<Bool> {
        Binding(
            get: {
                itemFlagValuesByItemID[item.id, default: false]
            },
            set: { newValue in
                itemFlagValuesByItemID[item.id] = newValue
                selectedReviewItemIDs.insert(item.id)
            }
        )
    }

    private func itemNumericBinding(for item: WorkspaceSyncConflictReviewItem) -> Binding<Double> {
        Binding(
            get: {
                itemNumericValuesByItemID[item.id, default: 0.5]
            },
            set: { newValue in
                itemNumericValuesByItemID[item.id] = newValue
                selectedReviewItemIDs.insert(item.id)
            }
        )
    }

    private func isKeeping(_ item: WorkspaceSyncConflictReviewItem) -> Bool {
        selectedReviewItemIDs.isEmpty || selectedReviewItemIDs.contains(item.id)
    }

    private func resetSelectionIfNeeded() {
        let currentIDs = Set(conflict.reviewItems.map(\.id))
        guard !currentIDs.isEmpty else {
            selectedReviewItemIDs = []
            customMergeValuesByItemID = [:]
            itemPrimaryValuesByItemID = [:]
            itemSecondaryValuesByItemID = [:]
            itemTertiaryValuesByItemID = [:]
            itemFlagValuesByItemID = [:]
            itemNumericValuesByItemID = [:]
            return
        }
        if selectedReviewItemIDs.isEmpty || !selectedReviewItemIDs.isSubset(of: currentIDs) {
            selectedReviewItemIDs = currentIDs
        }
        customMergeValuesByItemID = customMergeValuesByItemID.filter { currentIDs.contains($0.key) }
        itemPrimaryValuesByItemID = itemPrimaryValuesByItemID.filter { currentIDs.contains($0.key) }
        itemSecondaryValuesByItemID = itemSecondaryValuesByItemID.filter { currentIDs.contains($0.key) }
        itemTertiaryValuesByItemID = itemTertiaryValuesByItemID.filter { currentIDs.contains($0.key) }
        itemFlagValuesByItemID = itemFlagValuesByItemID.filter { currentIDs.contains($0.key) }
        itemNumericValuesByItemID = itemNumericValuesByItemID.filter { currentIDs.contains($0.key) }
    }
}

private struct MacSyncConflictChoiceRow: View {
    var item: WorkspaceSyncConflictReviewItem
    var isSelected: Bool
    var keepBinding: Binding<Bool>
    var customMergeValue: Binding<String>
    var itemPrimaryValue: Binding<String>
    var itemSecondaryValue: Binding<String>
    var itemTertiaryValue: Binding<String>
    var itemFlagValue: Binding<Bool>
    var itemNumericValue: Binding<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: keepBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("mac.settings.syncConflictChoice.\(item.id)")

            if let preview = item.fieldDiffPreview {
                MacSyncConflictDiffPreview(preview: preview)
            }

            customMergeEditor

            Text(decisionText)
                .font(.caption2)
                .foregroundStyle(isSelected ? Color.secondary : Color.red)
        }
    }

    private var title: String {
        switch item.kind {
        case .projectContent:
            return "Keep local \(item.projectField?.label.lowercased() ?? "project field"): \(item.projectTitle)"
        case .projectArtifact:
            return "Keep artifact: \(item.projectTitle)"
        case .projectCollectionItem:
            return "Keep local \(item.projectField?.label.lowercased() ?? "project item"): \(item.projectTitle)"
        case .localRecording, .localUploadJob:
            return "Keep \(item.kind.label.lowercased()): \(item.projectTitle)"
        }
    }

    private var detail: String {
        "\(item.sourceLabel) - \(item.statusLabel) - \(item.detail)"
    }

    private var decisionText: String {
        isSelected ? "Local copy or typed draft survives merge." : "Remote snapshot wins for this item."
    }

    @ViewBuilder
    private var customMergeEditor: some View {
        if item.kind == .projectCollectionItem, item.projectField?.supportsItemCustomMerge == true {
            itemCustomMergeEditor
        } else {
            scalarCustomMergeEditor
        }
    }

    @ViewBuilder
    private var scalarCustomMergeEditor: some View {
        switch item.projectField?.customMergeKind ?? .unsupported {
        case .multilineText:
            TextField(
                "Type merged \(item.projectField?.label.lowercased() ?? "value")",
                text: customMergeValue,
                axis: .vertical
            )
            .font(.caption)
            .lineLimit(2...5)
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("mac.settings.syncConflictDraft.\(item.id)")
            customMergeHelpText("Typed draft overrides both local and remote for this field.")
        case .status:
            Picker("Merged status", selection: customMergeValue) {
                Text("No custom status").tag("")
                ForEach(IdeaStatus.allCases) { status in
                    Text(status.label).tag(status.rawValue)
                }
            }
            .controlSize(.small)
            .accessibilityIdentifier("mac.settings.syncConflictStatusDraft.\(item.id)")
            customMergeHelpText("Selected status overrides both local and remote for this field.")
        case .tags:
            VStack(alignment: .leading, spacing: 6) {
                Text("Merged tags")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 6)], spacing: 6) {
                    ForEach(IdeaTag.allCases) { tag in
                        Toggle(tag.label, isOn: tagBinding(tag))
                            .toggleStyle(.checkbox)
                            .font(.caption2)
                    }
                }
            }
            .accessibilityIdentifier("mac.settings.syncConflictTagsDraft.\(item.id)")
            customMergeHelpText("Selected tags override both local and remote for this field.")
        case .score:
            VStack(alignment: .leading, spacing: 6) {
                Text("Merged score")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                scoreSlider("Confidence", value: scoreBinding(\.confidence))
                scoreSlider("Completeness", value: scoreBinding(\.completeness))
                scoreSlider("Risk", value: scoreBinding(\.risk))
            }
            .accessibilityIdentifier("mac.settings.syncConflictScoreDraft.\(item.id)")
            customMergeHelpText("Adjusted score overrides both local and remote for this field.")
        case .unsupported:
            EmptyView()
        }
    }

    @ViewBuilder
    private var itemCustomMergeEditor: some View {
        switch item.projectField?.itemCustomMergeKind ?? .unsupported {
        case .question:
            VStack(alignment: .leading, spacing: 6) {
                TextField("Merged question prompt", text: itemPrimaryValue, axis: .vertical)
                    .font(.caption)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("mac.settings.syncConflictItemPromptDraft.\(item.id)")
                TextField("Merged answer", text: itemSecondaryValue, axis: .vertical)
                    .font(.caption)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("mac.settings.syncConflictItemAnswerDraft.\(item.id)")
                Toggle("Blocking question", isOn: itemFlagValue)
                    .toggleStyle(.checkbox)
                    .font(.caption2)
                    .accessibilityIdentifier("mac.settings.syncConflictItemBlockingDraft.\(item.id)")
            }
            customMergeHelpText("Typed question draft overrides both local and remote for this item.")
        case .assumption:
            VStack(alignment: .leading, spacing: 6) {
                TextField("Merged assumption", text: itemPrimaryValue, axis: .vertical)
                    .font(.caption)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("mac.settings.syncConflictItemAssumptionDraft.\(item.id)")
                TextField("Merged evidence", text: itemSecondaryValue, axis: .vertical)
                    .font(.caption)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("mac.settings.syncConflictItemEvidenceDraft.\(item.id)")
                scoreSlider("Confidence", value: itemNumericValue)
                    .accessibilityIdentifier("mac.settings.syncConflictItemConfidenceDraft.\(item.id)")
            }
            customMergeHelpText("Typed assumption draft overrides both local and remote for this item.")
        case .validationExperiment:
            VStack(alignment: .leading, spacing: 6) {
                TextField("Merged validation experiment", text: itemPrimaryValue, axis: .vertical)
                    .font(.caption)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("mac.settings.syncConflictItemExperimentDraft.\(item.id)")
                TextField("Merged success metric", text: itemSecondaryValue, axis: .vertical)
                    .font(.caption)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("mac.settings.syncConflictItemMetricDraft.\(item.id)")
                TextField("Merged go/no-go criteria", text: itemTertiaryValue, axis: .vertical)
                    .font(.caption)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("mac.settings.syncConflictItemCriteriaDraft.\(item.id)")
            }
            customMergeHelpText("Typed validation draft overrides both local and remote for this item.")
        case .codexTask:
            VStack(alignment: .leading, spacing: 6) {
                TextField("Merged Codex task", text: itemPrimaryValue, axis: .vertical)
                    .font(.caption)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("mac.settings.syncConflictItemCodexTaskDraft.\(item.id)")
                TextField("Acceptance criteria, one per line", text: itemSecondaryValue, axis: .vertical)
                    .font(.caption)
                    .lineLimit(2...5)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("mac.settings.syncConflictItemAcceptanceDraft.\(item.id)")
                TextField("Test plan, one per line", text: itemTertiaryValue, axis: .vertical)
                    .font(.caption)
                    .lineLimit(2...5)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("mac.settings.syncConflictItemTestPlanDraft.\(item.id)")
            }
            customMergeHelpText("Typed Codex task draft overrides both local and remote for this item.")
        case .workflowRun:
            VStack(alignment: .leading, spacing: 6) {
                TextField("Merged workflow run name", text: itemPrimaryValue, axis: .vertical)
                    .font(.caption)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("mac.settings.syncConflictItemWorkflowRunNameDraft.\(item.id)")
                Picker("Merged run status", selection: itemSecondaryValue) {
                    Text("Choose status").tag("")
                    ForEach(WorkflowRunStatus.allCases) { status in
                        Text(status.rawValue.capitalized).tag(status.rawValue)
                    }
                }
                .controlSize(.small)
                .accessibilityIdentifier("mac.settings.syncConflictItemWorkflowRunStatusDraft.\(item.id)")
                TextField("Failure note required when failed", text: itemTertiaryValue, axis: .vertical)
                    .font(.caption)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("mac.settings.syncConflictItemWorkflowRunFailureDraft.\(item.id)")
            }
            customMergeHelpText("Typed workflow-run draft updates name, status, and failure note only; provenance and artifact links are preserved.")
        case .unsupported:
            EmptyView()
        }
    }

    private func customMergeHelpText(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    private func tagBinding(_ tag: IdeaTag) -> Binding<Bool> {
        Binding(
            get: {
                WorkspaceSyncConflictMergeSelection.parseTags(customMergeValue.wrappedValue).contains(tag)
            },
            set: { isSelected in
                var tags = WorkspaceSyncConflictMergeSelection.parseTags(customMergeValue.wrappedValue)
                if isSelected, !tags.contains(tag) {
                    tags.append(tag)
                } else if !isSelected {
                    tags.removeAll { $0 == tag }
                }
                customMergeValue.wrappedValue = tags.map(\.rawValue).joined(separator: ",")
            }
        )
    }

    private func scoreBinding(_ keyPath: WritableKeyPath<IdeaScore, Double>) -> Binding<Double> {
        Binding(
            get: {
                currentScore[keyPath: keyPath]
            },
            set: { newValue in
                var score = currentScore
                score[keyPath: keyPath] = newValue
                customMergeValue.wrappedValue = WorkspaceSyncConflictMergeSelection.customScoreValue(score)
            }
        )
    }

    private var currentScore: IdeaScore {
        WorkspaceSyncConflictMergeSelection.parseScore(customMergeValue.wrappedValue)
            ?? IdeaScore(confidence: 0.5, completeness: 0.5, risk: 0.5)
    }

    private func scoreSlider(_ title: String, value: Binding<Double>) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)
            Slider(value: value, in: 0...1, step: 0.05)
            Text(value.wrappedValue, format: .percent.precision(.fractionLength(0)))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }
}

private struct MacSyncConflictDiffPreview: View {
    var preview: WorkspaceSyncConflictFieldDiffPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            syncValueRow(title: "Local", value: preview.localValue, tint: .blue)
            syncValueRow(title: "Remote", value: preview.remoteValue, tint: .purple)
            Text(preview.changeSummary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.red.opacity(0.14))
        }
    }

    private func syncValueRow(title: String, value: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 44, alignment: .leading)
            Text(value)
                .font(.caption2)
                .foregroundStyle(.primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private extension WorkspaceSyncConflictReviewItem {
    var systemImageName: String {
        switch kind {
        case .localUploadJob: "tray.and.arrow.up"
        case .localRecording: "waveform"
        case .projectContent: "text.badge.checkmark"
        case .projectArtifact: "doc.richtext"
        case .projectCollectionItem: "list.bullet.rectangle"
        }
    }
}

private struct MacInspectorCommandDeck: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var isRunning: Bool
    var hasSelectedProject: Bool
    var runReviewBoard: () -> Void
    var generatePRD: () -> Void
    var transcribeUploadedAudio: () -> Void
    var prepareCodexPacket: () -> Void
    var exportPacketFiles: () -> Void

    private var isDeckDisabled: Bool { isRunning || !hasSelectedProject }

    private var deckHelpText: String {
        if isRunning {
            return "Wait for the current AI action to finish"
        }
        if !hasSelectedProject {
            return "Select an idea project before running AI commands"
        }
        return ""
    }

    private var deckStatusText: String {
        if isRunning {
            return "Running the selected command."
        }
        if !hasSelectedProject {
            return "Select an idea project to unlock AI commands."
        }
        return "Pick a focused action for the selected idea."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Label("AI Command Deck", systemImage: "sparkles")
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 12)
                MacSignalRibbon(tint: isRunning ? .orange : .indigo, isActive: isRunning && !reduceMotion)
            }

            Text(deckStatusText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 10)], spacing: 10) {
                MacInspectorCommandButton(
                    title: "Review Board",
                    subtitle: "Score the idea",
                    systemImage: "person.3.sequence",
                    tint: .indigo,
                    isDisabled: isDeckDisabled,
                    accessibilityIdentifier: "mac.inspector.runReviewBoard",
                    helpText: !deckHelpText.isEmpty ? deckHelpText : "Run the selected idea through the review board workflow",
                    action: runReviewBoard
                )
                MacInspectorCommandButton(
                    title: "Generate PRD",
                    subtitle: "Draft product spec",
                    systemImage: "doc.text",
                    tint: .cyan,
                    isDisabled: isDeckDisabled,
                    accessibilityIdentifier: "mac.inspector.generatePRD",
                    helpText: !deckHelpText.isEmpty ? deckHelpText : "Generate a PRD artifact for the selected idea",
                    action: generatePRD
                )
                MacInspectorCommandButton(
                    title: "Transcribe",
                    subtitle: "Backend audio AI",
                    systemImage: "waveform.badge.mic",
                    tint: .mint,
                    isDisabled: isDeckDisabled,
                    accessibilityIdentifier: "mac.inspector.transcribeUploadedAudio",
                    helpText: !deckHelpText.isEmpty ? deckHelpText : "Transcribe uploaded recordings when backend AI is configured",
                    action: transcribeUploadedAudio
                )
                MacInspectorCommandButton(
                    title: "Codex Packet",
                    subtitle: "Prepare handoff",
                    systemImage: "shippingbox",
                    tint: .orange,
                    isDisabled: isDeckDisabled,
                    accessibilityIdentifier: "mac.inspector.prepareCodexPacket",
                    helpText: !deckHelpText.isEmpty ? deckHelpText : "Prepare an in-app Codex packet artifact",
                    action: prepareCodexPacket
                )
                MacInspectorCommandButton(
                    title: "Export Files",
                    subtitle: "Write packet",
                    systemImage: "folder.badge.plus",
                    tint: .teal,
                    isDisabled: isDeckDisabled,
                    accessibilityIdentifier: "mac.inspector.exportPacketFiles",
                    helpText: !deckHelpText.isEmpty ? deckHelpText : "Export the selected idea packet files to disk",
                    action: exportPacketFiles
                )
            }

            if isRunning {
                ProgressView()
                    .controlSize(.small)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
    }
}

private struct MacInspectorCommandButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var title: String
    var subtitle: String
    var systemImage: String
    var tint: Color
    var isDisabled: Bool
    var accessibilityIdentifier: String
    var helpText: String
    var action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(isDisabled ? .secondary : tint)
                Text(title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(tint.opacity(isHovering && !isDisabled ? 0.34 : 0.16))
            }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityIdentifier(accessibilityIdentifier)
        .help(helpText)
        .scaleEffect(isHovering && !isDisabled && !reduceMotion ? 1.018 : 1)
        .animation(reduceMotion ? nil : .snappy(duration: 0.16), value: isHovering)
        .onHover { isHovering = $0 }
    }
}

private struct MacInspectorMetricPill: View {
    var title: String
    var value: String
    var symbol: String
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            Text(value)
                .font(.callout.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(tint.opacity(0.16))
        }
    }
}

struct SettingsView: View {
    @Bindable var store: IdeaForgeStore
    var navigationState: MacNavigationState
    private let backendConfigurationManager: BackendConfigurationManager
    private let integrationSettingsManager: IntegrationSettingsManager
    private static let syncConflictResolverAnchor = "mac.settings.syncConflictResolver.anchor"
    @State private var backendSettings = BackendConnectionSettings()
    @State private var backendTokenEntry = ""
    @State private var backendStatusMessage = "Local upload fallback active."
    @State private var isSyncingWorkspace = false
    @State private var authenticatedSession: BackendAuthenticatedSession?
    @State private var authStatusMessage = "Backend session not validated."
    @State private var isValidatingAuthSession = false
    @State private var accountUsageSummary: BackendAccountUsageSummary?
    @State private var accountStatusMessage = "Backend account usage not loaded."
    @State private var isRefreshingAccountUsage = false
    @State private var integrationSettings = IntegrationSettings.defaults
    @State private var integrationStatusMessage = "External integrations disabled by default."
    @State private var selectedSyncConflictReviewItemIDs = Set<String>()
    @State private var syncConflictCustomMergeValuesByItemID = [String: String]()
    @State private var syncConflictItemPrimaryValuesByItemID = [String: String]()
    @State private var syncConflictItemSecondaryValuesByItemID = [String: String]()
    @State private var syncConflictItemTertiaryValuesByItemID = [String: String]()
    @State private var syncConflictItemFlagValuesByItemID = [String: Bool]()
    @State private var syncConflictItemNumericValuesByItemID = [String: Double]()

    init(
        store: IdeaForgeStore,
        navigationState: MacNavigationState,
        backendConfigurationManager: BackendConfigurationManager = .production(),
        integrationSettingsManager: IntegrationSettingsManager = .production()
    ) {
        self.store = store
        self.navigationState = navigationState
        self.backendConfigurationManager = backendConfigurationManager
        self.integrationSettingsManager = integrationSettingsManager
    }

    var body: some View {
        ScrollViewReader { proxy in
            Form {
            Section("Privacy") {
                Picker("Privacy Mode", selection: privacyModeBinding) {
                    ForEach(PrivacyMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Toggle("Allow cloud transcription", isOn: .constant(false))
                    .disabled(true)
                    .help("Planned setting. Current cloud behavior is controlled by Privacy Mode and backend configuration.")
                Toggle("Delete audio after transcription", isOn: .constant(true))
                    .disabled(true)
                    .help("Planned setting. Audio retention is currently handled by the local recording pipeline.")
                Text("Detailed privacy toggles are planned. This build uses Privacy Mode plus backend settings for runtime behavior.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Backend Upload") {
                Toggle("Remote upload", isOn: $backendSettings.isEnabled)
                TextField("Base URL", text: $backendSettings.baseURLString)
                    .textFieldStyle(.roundedBorder)
                TextField("Workspace ID", text: $backendSettings.workspaceID)
                    .textFieldStyle(.roundedBorder)
                TextField("Auth session path", text: $backendSettings.authSessionPath)
                    .textFieldStyle(.roundedBorder)
                    .help("Backend endpoint that validates the saved bearer token against this workspace")
                TextField("Upload path", text: $backendSettings.uploadPath)
                    .textFieldStyle(.roundedBorder)
                TextField("Sync path", text: $backendSettings.syncPath)
                    .textFieldStyle(.roundedBorder)
                TextField("Object metadata path", text: $backendSettings.objectMetadataPath)
                    .textFieldStyle(.roundedBorder)
                    .help("Backend endpoint that proves uploaded audio object metadata before AI transcription starts")
                TextField("Transcription path", text: $backendSettings.transcriptionPath)
                    .textFieldStyle(.roundedBorder)
                TextField("Transcription job status path", text: $backendSettings.transcriptionJobStatusPath)
                    .textFieldStyle(.roundedBorder)
                    .help("Backend endpoint prefix used to poll accepted transcription jobs by job ID")
                TextField("Workflow path", text: $backendSettings.workflowPath)
                    .textFieldStyle(.roundedBorder)
                    .help("Backend endpoint that starts workflow artifact generation")
                TextField("Workflow job status path", text: $backendSettings.workflowJobStatusPath)
                    .textFieldStyle(.roundedBorder)
                    .help("Backend endpoint prefix used to poll accepted workflow jobs by job ID")
                TextField("Usage path", text: $backendSettings.usagePath)
                    .textFieldStyle(.roundedBorder)
                TextField("Billing reconciliation path", text: $backendSettings.billingReconciliationPath)
                    .textFieldStyle(.roundedBorder)
                    .help("Backend endpoint that verifies App Store transaction evidence before updating cloud entitlements")
                TextField("Operations status path", text: $backendSettings.operationsStatusPath)
                    .textFieldStyle(.roundedBorder)
                    .help("Backend admin endpoint that reports migrations, storage, tenant, job, and audit readiness")
                TextField("Backup manifest path", text: $backendSettings.backupManifestPath)
                    .textFieldStyle(.roundedBorder)
                    .help("Backend admin endpoint that returns privacy-safe backup inventory without raw content")
                TextField("Restore drill path", text: $backendSettings.restoreDrillPath)
                    .textFieldStyle(.roundedBorder)
                    .help("Backend admin endpoint that verifies backup restore readiness without raw content")
                TextField("Operations metrics path", text: $backendSettings.operationsMetricsPath)
                    .textFieldStyle(.roundedBorder)
                    .help("Backend admin endpoint that exposes privacy-safe monitoring metrics for queues, storage, jobs, and usage")
                SecureField("Bearer token", text: $backendTokenEntry)
                    .textFieldStyle(.roundedBorder)
                Text(backendStatusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let conflict = store.syncHealth.syncConflictStatus {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Resolve Sync Conflict", systemImage: "arrow.triangle.2.circlepath.circle")
                            .font(.headline)
                        MacSyncConflictSelectionList(
                            conflict: conflict,
                            selectedReviewItemIDs: $selectedSyncConflictReviewItemIDs,
                            customMergeValuesByItemID: $syncConflictCustomMergeValuesByItemID,
                            itemPrimaryValuesByItemID: $syncConflictItemPrimaryValuesByItemID,
                            itemSecondaryValuesByItemID: $syncConflictItemSecondaryValuesByItemID,
                            itemTertiaryValuesByItemID: $syncConflictItemTertiaryValuesByItemID,
                            itemFlagValuesByItemID: $syncConflictItemFlagValuesByItemID,
                            itemNumericValuesByItemID: $syncConflictItemNumericValuesByItemID
                        )
                        Button(action: mergeSyncConflictPreservingLocalWork) {
                            Label(syncConflictMergeButtonTitle, systemImage: "arrow.triangle.2.circlepath.circle")
                        }
                        .disabled(isSyncingWorkspace)
                        .help("Re-fetch backend state and apply the reviewed local-item choices before accepting the remote snapshot")
                    }
                    .id(Self.syncConflictResolverAnchor)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("mac.settings.syncConflictResolver")
                }
                HStack {
                    Button(action: saveBackendConfiguration) {
                        Label("Save", systemImage: "externaldrive.badge.checkmark")
                    }
                    .help("Save backend paths and store the token in Keychain")
                    Button(action: syncBackendWorkspace) {
                        Label(isSyncingWorkspace ? "Syncing" : "Sync Now", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(isSyncingWorkspace)
                    .help(isSyncingWorkspace ? "Workspace sync is already running" : "Publish the local workspace snapshot to the configured backend")
                    Button(action: validateBackendSession) {
                        Label(isValidatingAuthSession ? "Validating" : "Validate Session", systemImage: "person.badge.key")
                    }
                    .disabled(isValidatingAuthSession)
                    .help(isValidatingAuthSession ? "Backend session validation is already running" : "Validate the saved bearer token and workspace against the backend")
                    Button(role: .destructive, action: clearBackendCredentials) {
                        Label("Clear Token", systemImage: "key.slash")
                    }
                    .help("Remove the saved backend bearer token from Keychain")
                }
            }

            Section("Account Usage") {
                let portalReadiness = accountPortalReadiness
                let deletionReadiness = accountDeletionReadiness
                if let authenticatedSession {
                    LabeledContent("Session workspace", value: authenticatedSession.workspaceID)
                    LabeledContent("Session account", value: "\(authenticatedSession.account.planName) (\(authenticatedSession.account.planStatus.label))")
                    Text("Capabilities: \(authenticatedSession.capabilities.map(\.label).joined(separator: ", "))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    LabeledContent("Backend session", value: "Not validated")
                }
                Text(authStatusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let accountUsageSummary {
                    LabeledContent("Current plan", value: "\(accountUsageSummary.account.planName) (\(accountUsageSummary.account.planStatus.label))")
                    ForEach(accountUsageSummary.entitlements) { entitlement in
                        LabeledContent(
                            entitlement.displayName,
                            value: "\(entitlement.usedLabel) / \(entitlement.includedLabel)"
                        )
                    }
                } else {
                    LabeledContent("Current plan", value: "Not loaded")
                }
                Text(accountStatusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                AccountPortalActionRow(
                    title: portalReadiness.actionLabel,
                    systemImage: "creditcard",
                    isEnabled: portalReadiness.canOpenPortal,
                    blockerSummary: portalReadiness.blockerText,
                    action: openAccountPortal
                )
                AccountPortalActionRow(
                    title: "Delete Account",
                    systemImage: "person.crop.circle.badge.xmark",
                    isEnabled: deletionReadiness.canOpenPortal,
                    blockerSummary: deletionReadiness.blockerText,
                    role: .destructive,
                    action: requestAccountDeletion
                )
                Button(action: refreshAccountUsage) {
                    Label(isRefreshingAccountUsage ? "Refreshing" : "Refresh Plan", systemImage: "arrow.clockwise.circle")
                }
                .disabled(isRefreshingAccountUsage)
                .help(isRefreshingAccountUsage ? "Backend account plan refresh is already running" : "Fetch the account plan and workspace usage summary from the configured backend")
            }

            Section("Integrations") {
                let report = integrationSettings.readinessReport()
                ForEach(IntegrationProvider.allCases) { provider in
                    IntegrationProviderSettingsRow(
                        settings: providerBinding(for: provider),
                        readiness: report.item(for: provider)
                    )
                }
                Text(integrationStatusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(action: saveIntegrationSettings) {
                        Label("Save Integrations", systemImage: "externaldrive.badge.checkmark")
                    }
                    .help("Save non-secret integration readiness settings")
                    Button(action: loadIntegrationSettings) {
                        Label("Reload", systemImage: "arrow.clockwise")
                    }
                    .help("Reload non-secret integration readiness settings")
                }
            }
            }
            .formStyle(.grouped)
            .padding()
            .frame(width: 560)
            .onAppear {
                loadBackendConfiguration()
                loadIntegrationSettings()
                applySettingsDestination(navigationState.settingsDestination, with: proxy)
            }
            .onChange(of: navigationState.settingsDestination) { _, destination in
                applySettingsDestination(destination, with: proxy)
            }
        }
    }

    private func applySettingsDestination(
        _ destination: MacSettingsDestination?,
        with proxy: ScrollViewProxy
    ) {
        guard destination == .syncConflictResolver else { return }
        guard store.syncHealth.syncConflictStatus != nil else {
            navigationState.settingsDestination = nil
            return
        }
        DispatchQueue.main.async {
            proxy.scrollTo(Self.syncConflictResolverAnchor, anchor: .center)
            navigationState.settingsDestination = nil
        }
    }

    private var privacyModeBinding: Binding<PrivacyMode> {
        Binding(
            get: { store.privacyMode },
            set: { store.setPrivacyMode($0) }
        )
    }

    private var accountPortalReadiness: AccountPortalReadiness {
        AccountPortalReadiness.evaluate(
            summary: accountUsageSummary,
            session: authenticatedSession,
            expectedWorkspaceID: backendSettings.normalizedWorkspaceID
        )
    }

    private var accountDeletionReadiness: AccountPortalReadiness {
        var deletionSummary = accountUsageSummary
        let accountDeletionURL = deletionSummary?.accountDeletionURL
        deletionSummary?.accountPortalURL = accountDeletionURL
        return AccountPortalReadiness.evaluate(
            summary: deletionSummary,
            session: authenticatedSession,
            expectedWorkspaceID: backendSettings.normalizedWorkspaceID
        )
    }

    private var syncConflictMergeButtonTitle: String {
        guard store.syncHealth.syncConflictStatus?.reviewItems.isEmpty == false else {
            return "Merge Local Work"
        }
        return "Merge Reviewed Choices"
    }

    private func providerBinding(for provider: IntegrationProvider) -> Binding<IntegrationProviderSettings> {
        Binding(
            get: { integrationSettings.settings(for: provider) },
            set: { integrationSettings.update($0) }
        )
    }

    private func loadBackendConfiguration() {
        do {
            backendSettings = try backendConfigurationManager.loadSettings()
            let hasToken = try backendConfigurationManager.credentialStore.loadBearerToken()?.isEmpty == false
            if !backendSettings.isEnabled {
                backendStatusMessage = "Local upload fallback active."
            } else if !backendSettings.hasValidBaseURL {
                backendStatusMessage = "Remote upload needs a valid https:// URL."
            } else if backendSettings.normalizedWorkspaceID.isEmpty {
                backendStatusMessage = "Remote upload needs a workspace ID."
            } else if hasToken {
                backendStatusMessage = "Remote upload configured."
            } else {
                backendStatusMessage = "Remote upload needs a bearer token."
            }
            IdeaForgeLog.settings.info("macOS backend settings loaded; enabled: \(backendSettings.isEnabled, privacy: .public)")
        } catch {
            backendStatusMessage = "Backend settings could not be loaded."
            IdeaForgeLog.settings.error("macOS backend settings could not be loaded")
        }
    }

    private func saveBackendConfiguration() {
        do {
            guard !backendSettings.isEnabled || backendSettings.hasValidBaseURL else {
                backendStatusMessage = "Enter a valid https:// backend URL."
                IdeaForgeLog.settings.warning("macOS backend settings save skipped; invalid URL")
                return
            }
            guard !backendSettings.isEnabled || !backendSettings.normalizedWorkspaceID.isEmpty else {
                backendStatusMessage = "Enter a backend workspace ID."
                IdeaForgeLog.settings.warning("macOS backend settings save skipped; workspace ID missing")
                return
            }
            let token = backendTokenEntry.isEmpty ? nil : backendTokenEntry
            try backendConfigurationManager.save(settings: backendSettings, bearerToken: token)
            backendTokenEntry = ""
            authenticatedSession = nil
            authStatusMessage = "Backend session not validated."
            accountUsageSummary = nil
            accountStatusMessage = "Backend account usage not loaded."
            loadBackendConfiguration()
            IdeaForgeLog.settings.info("macOS backend settings saved; enabled: \(backendSettings.isEnabled, privacy: .public), token provided: \(token != nil, privacy: .public)")
        } catch {
            backendStatusMessage = "Backend settings could not be saved."
            IdeaForgeLog.settings.error("macOS backend settings could not be saved")
        }
    }

    private func clearBackendCredentials() {
        do {
            try backendConfigurationManager.clearCredentials()
            backendTokenEntry = ""
            authenticatedSession = nil
            authStatusMessage = "Backend session not validated."
            accountUsageSummary = nil
            accountStatusMessage = "Backend account usage not loaded."
            loadBackendConfiguration()
            IdeaForgeLog.settings.info("macOS backend credentials cleared")
        } catch {
            backendStatusMessage = "Backend token could not be cleared."
            IdeaForgeLog.settings.error("macOS backend credentials could not be cleared")
        }
    }

    private func syncBackendWorkspace() {
        guard !isSyncingWorkspace else { return }
        if case .blocked(_, let message) = WorkspaceAutoSyncPolicy.localPreflightDecision(
            for: store.workspaceState()
        ) {
            backendStatusMessage = message
            IdeaForgeLog.sync.warning("macOS workspace backend sync skipped; local publication policy blocked action")
            return
        }
        let capabilityDecision = backendCapabilityDecision(requiredCapabilities: [.syncWorkspace])
        guard capabilityDecision.isAllowed else {
            backendStatusMessage = "Workspace sync needs validated backend capability. \(capabilityDecision.blockerSummary)"
            IdeaForgeLog.sync.warning("macOS workspace backend sync skipped; capability gate blocked action")
            return
        }
        isSyncingWorkspace = true
        IdeaForgeLog.sync.info("macOS workspace backend sync started")
        Task {
            defer { isSyncingWorkspace = false }
            do {
                guard let configuration = try backendConfigurationManager.resolvedSyncConfiguration() else {
                    backendStatusMessage = "Remote sync needs backend settings, workspace ID, and a token."
                    IdeaForgeLog.sync.warning("macOS workspace backend sync skipped; configuration missing")
                    return
                }
                let engine = WorkspaceSyncEngine(
                    client: BackendWorkspaceSyncClient(configuration: configuration)
                )
                let summary = try await engine.synchronize(store: store)
                if summary.appliedRemoteSnapshot {
                    backendStatusMessage = "Latest backend workspace loaded on this Mac."
                } else if summary.pushedLocalSnapshot {
                    backendStatusMessage = "Local workspace published to backend."
                } else {
                    backendStatusMessage = "Workspace already up to date."
                }
                IdeaForgeLog.sync.info("macOS workspace backend sync completed; fetched: \(summary.fetched, privacy: .public), applied remote: \(summary.appliedRemoteSnapshot, privacy: .public), pushed local: \(summary.pushedLocalSnapshot, privacy: .public)")
            } catch BackendConfigurationError.invalidBaseURL {
                backendStatusMessage = "Enter a valid https:// backend URL."
                IdeaForgeLog.sync.error("macOS workspace backend sync failed; invalid backend URL")
            } catch let conflict as WorkspaceSyncConflictError {
                backendStatusMessage = conflict.report.message
                IdeaForgeLog.sync.error("macOS workspace backend sync blocked by conflict; local upload jobs: \(conflict.report.localOnlyUploadJobIDs.count, privacy: .public), local recordings: \(conflict.report.localOnlyRecordingIDs.count, privacy: .public)")
            } catch {
                backendStatusMessage = "Workspace sync failed."
                IdeaForgeLog.sync.error("macOS workspace backend sync failed")
            }
        }
    }

    private func mergeSyncConflictPreservingLocalWork() {
        guard !isSyncingWorkspace else { return }
        guard store.syncHealth.syncConflictStatus != nil else {
            backendStatusMessage = "No sync conflict is waiting for recovery."
            return
        }
        let capabilityDecision = backendCapabilityDecision(requiredCapabilities: [.syncWorkspace])
        guard capabilityDecision.isAllowed else {
            backendStatusMessage = "Conflict recovery needs validated backend capability. \(capabilityDecision.blockerSummary)"
            IdeaForgeLog.sync.warning("macOS workspace conflict merge skipped; capability gate blocked action")
            return
        }
        isSyncingWorkspace = true
        IdeaForgeLog.sync.info("macOS workspace conflict merge started")
        Task {
            defer { isSyncingWorkspace = false }
            do {
                guard let configuration = try backendConfigurationManager.resolvedSyncConfiguration() else {
                    backendStatusMessage = "Conflict recovery needs backend settings, workspace ID, and a token."
                    IdeaForgeLog.sync.warning("macOS workspace conflict merge skipped; configuration missing")
                    return
                }
                let engine = WorkspaceSyncEngine(
                    client: BackendWorkspaceSyncClient(configuration: configuration)
                )
                if let conflict = store.syncHealth.syncConflictStatus, !conflict.reviewItems.isEmpty {
                    let selection = reviewedMergeSelection(for: conflict)
                    let summary = try await engine.pullLatestApplyingReviewedMerge(into: store, selection: selection)
                    backendStatusMessage = summary.pushedLocalSnapshot
                        ? "Workspace merged with reviewed local choices and published."
                        : "Workspace merged with reviewed local choices."
                } else {
                    let summary = try await engine.pullLatestPreservingLocalUploadWork(into: store)
                    backendStatusMessage = summary.pushedLocalSnapshot
                        ? "Workspace merged while preserving local upload work and published."
                        : "Workspace merged while preserving local upload work."
                }
                IdeaForgeLog.sync.info("macOS workspace conflict merge completed")
            } catch BackendConfigurationError.invalidBaseURL {
                backendStatusMessage = "Enter a valid https:// backend URL."
                IdeaForgeLog.sync.error("macOS workspace conflict merge failed; invalid backend URL")
            } catch {
                backendStatusMessage = "Workspace conflict merge failed."
                IdeaForgeLog.sync.error("macOS workspace conflict merge failed")
            }
        }
    }

    private func reviewedMergeSelection(for conflict: WorkspaceSyncConflictStatus) -> WorkspaceSyncConflictMergeSelection {
        var selectedIDs = selectedSyncConflictReviewItemIDs.isEmpty
            ? Set(conflict.reviewItems.map(\.id))
            : selectedSyncConflictReviewItemIDs
        let customValues = customMergeValues(for: conflict)
        let customItemValues = customCollectionItemValues(for: conflict)
        for value in customValues {
            if let itemID = conflict.reviewItems.first(where: { $0.protectedID == value.projectID && $0.projectField == value.field })?.id {
                selectedIDs.insert(itemID)
            }
        }
        for value in customItemValues {
            if let itemID = conflict.reviewItems.first(where: {
                $0.kind == .projectCollectionItem
                    && $0.projectID == value.projectID
                    && $0.projectField == value.field
                    && $0.protectedID == value.itemID
            })?.id {
                selectedIDs.insert(itemID)
            }
        }
        return WorkspaceSyncConflictMergeSelection(
            selectedReviewItemIDs: selectedIDs,
            reviewItems: conflict.reviewItems,
            customProjectFieldValues: customValues,
            customProjectCollectionItemValues: customItemValues
        )
    }

    private func customMergeValues(for conflict: WorkspaceSyncConflictStatus) -> [WorkspaceSyncProjectFieldCustomValue] {
        conflict.reviewItems.compactMap { item in
            guard item.kind == .projectContent,
                  let field = item.projectField,
                  field.supportsCustomMergeText,
                  let value = syncConflictCustomMergeValuesByItemID[item.id] else {
                return nil
            }
            return WorkspaceSyncProjectFieldCustomValue(
                projectID: item.protectedID,
                field: field,
                value: value
            )
        }
    }

    private func customCollectionItemValues(for conflict: WorkspaceSyncConflictStatus) -> [WorkspaceSyncProjectCollectionItemCustomValue] {
        conflict.reviewItems.compactMap { item in
            guard item.kind == .projectCollectionItem,
                  let projectID = item.projectID,
                  let field = item.projectField,
                  field.supportsItemCustomMerge,
                  let primaryText = syncConflictItemPrimaryValuesByItemID[item.id] else {
                return nil
            }
            return WorkspaceSyncProjectCollectionItemCustomValue(
                projectID: projectID,
                field: field,
                itemID: item.protectedID,
                primaryText: primaryText,
                secondaryText: syncConflictItemSecondaryValuesByItemID[item.id, default: ""],
                tertiaryText: syncConflictItemTertiaryValuesByItemID[item.id, default: ""],
                flagValue: syncConflictItemFlagValuesByItemID[item.id],
                numericValue: syncConflictItemNumericValuesByItemID[item.id]
            )
        }
    }

    private func validateBackendSession() {
        guard !isValidatingAuthSession else { return }
        isValidatingAuthSession = true
        IdeaForgeLog.settings.info("macOS backend session validation started")
        Task {
            defer { isValidatingAuthSession = false }
            do {
                guard let configuration = try backendConfigurationManager.resolvedAuthConfiguration() else {
                    authStatusMessage = "Session validation needs backend settings, workspace ID, and a token."
                    authenticatedSession = nil
                    IdeaForgeLog.settings.warning("macOS backend session validation skipped; configuration missing")
                    return
                }
                let session = try await BackendAuthSessionClient(configuration: configuration).validateSession()
                authenticatedSession = session
                authStatusMessage = "Backend session validated."
                IdeaForgeLog.settings.info("macOS backend session validation completed; capabilities: \(session.capabilities.count, privacy: .public)")
            } catch BackendConfigurationError.invalidBaseURL {
                authStatusMessage = "Enter a valid https:// backend URL."
                authenticatedSession = nil
                IdeaForgeLog.settings.error("macOS backend session validation failed; invalid backend URL")
            } catch {
                authStatusMessage = "Backend session validation failed."
                authenticatedSession = nil
                IdeaForgeLog.settings.error("macOS backend session validation failed")
            }
        }
    }

    private func refreshAccountUsage() {
        guard !isRefreshingAccountUsage else { return }
        let capabilityDecision = backendCapabilityDecision(requiredCapabilities: [.manageAccount])
        guard capabilityDecision.isAllowed else {
            accountStatusMessage = "Usage refresh needs validated backend capability. \(capabilityDecision.blockerSummary)"
            IdeaForgeLog.settings.warning("macOS backend account usage refresh skipped; capability gate blocked action")
            return
        }
        isRefreshingAccountUsage = true
        IdeaForgeLog.settings.info("macOS backend account usage refresh started")
        Task {
            defer { isRefreshingAccountUsage = false }
            do {
                guard let configuration = try backendConfigurationManager.resolvedAccountConfiguration() else {
                    accountStatusMessage = "Usage needs backend settings, workspace ID, and a token."
                    IdeaForgeLog.settings.warning("macOS backend account usage refresh skipped; configuration missing")
                    return
                }
                let summary = try await BackendAccountUsageClient(configuration: configuration).fetchUsageSummary()
                accountUsageSummary = summary
                accountStatusMessage = "Usage updated."
                IdeaForgeLog.settings.info("macOS backend account usage refresh completed; usage metrics: \(summary.usage.count, privacy: .public), entitlements: \(summary.entitlements.count, privacy: .public)")
            } catch BackendConfigurationError.invalidBaseURL {
                accountStatusMessage = "Enter a valid https:// backend URL."
                IdeaForgeLog.settings.error("macOS backend account usage refresh failed; invalid backend URL")
            } catch {
                accountStatusMessage = "Usage refresh failed."
                IdeaForgeLog.settings.error("macOS backend account usage refresh failed")
            }
        }
    }

    private func openAccountPortal() {
        let readiness = accountPortalReadiness
        guard readiness.canOpenPortal, let portalURL = readiness.portalURL else {
            accountStatusMessage = readiness.blockerText
            IdeaForgeLog.settings.warning("macOS account portal skipped; readiness blocked action")
            return
        }
        guard NSWorkspace.shared.open(portalURL) else {
            accountStatusMessage = "Account portal could not be opened."
            IdeaForgeLog.settings.error("macOS account portal open request failed")
            return
        }
        accountStatusMessage = "Account portal opened."
        IdeaForgeLog.settings.info("macOS account portal opened")
    }

    private func requestAccountDeletion() {
        let readiness = accountDeletionReadiness
        guard readiness.canOpenPortal, let accountDeletionURL = readiness.portalURL else {
            accountStatusMessage = readiness.blockerText
            IdeaForgeLog.settings.warning("macOS account deletion skipped; readiness blocked action")
            return
        }
        guard NSWorkspace.shared.open(accountDeletionURL) else {
            accountStatusMessage = "Account deletion portal could not be opened."
            IdeaForgeLog.settings.error("macOS account deletion portal open request failed")
            return
        }
        accountStatusMessage = "Account deletion portal opened."
        IdeaForgeLog.settings.info("macOS account deletion portal opened")
    }

    private func backendCapabilityDecision(
        requiredCapabilities: [BackendAccountCapability]
    ) -> BackendCapabilityDecision {
        BackendCapabilityGate(session: authenticatedSession).decision(
            requiredCapabilities: requiredCapabilities,
            expectedWorkspaceID: backendSettings.normalizedWorkspaceID
        )
    }

    private func loadIntegrationSettings() {
        do {
            integrationSettings = try integrationSettingsManager.loadSettings()
            let report = integrationSettings.readinessReport()
            integrationStatusMessage = "\(report.readyCount) ready, \(report.blockerCount) need attention."
            IdeaForgeLog.settings.info("macOS integration settings loaded; ready: \(report.readyCount, privacy: .public), blockers: \(report.blockerCount, privacy: .public)")
        } catch {
            integrationSettings = .defaults
            integrationStatusMessage = "Integration settings could not be loaded."
            IdeaForgeLog.settings.error("macOS integration settings could not be loaded")
        }
    }

    private func saveIntegrationSettings() {
        do {
            try integrationSettingsManager.save(settings: integrationSettings)
            let report = integrationSettings.readinessReport()
            integrationStatusMessage = "\(report.readyCount) ready, \(report.blockerCount) need attention."
            IdeaForgeLog.settings.info("macOS integration settings saved; ready: \(report.readyCount, privacy: .public), blockers: \(report.blockerCount, privacy: .public)")
        } catch {
            integrationStatusMessage = "Integration settings could not be saved."
            IdeaForgeLog.settings.error("macOS integration settings could not be saved")
        }
    }
}

private struct AccountPortalActionRow: View {
    var title: String
    var systemImage: String
    var isEnabled: Bool
    var blockerSummary: String
    var role: ButtonRole?
    var action: () -> Void

    init(
        title: String,
        systemImage: String,
        isEnabled: Bool,
        blockerSummary: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void = {}
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isEnabled = isEnabled
        self.blockerSummary = blockerSummary
        self.role = role
        self.action = action
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Button(role: role, action: action) {
                Label(title, systemImage: systemImage)
            }
            .disabled(!isEnabled)
            .help(blockerSummary)
            Text(blockerSummary)
                .font(.footnote)
                .foregroundStyle(isEnabled ? .green : .secondary)
        }
    }
}

private struct IntegrationProviderSettingsRow: View {
    @Binding var settings: IntegrationProviderSettings
    var readiness: IntegrationReadinessItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $settings.isEnabled) {
                Label(settings.provider.label, systemImage: settings.provider.symbolName)
                    .font(.headline)
            }
            .help("Include this provider in integration readiness checks")

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    Text("Status")
                        .foregroundStyle(.secondary)
                    Text(readiness?.status.label ?? "Unknown")
                }
                GridRow {
                    Text("Name")
                        .foregroundStyle(.secondary)
                    TextField("Workspace, repo, or team", text: $settings.displayName)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Credential")
                        .foregroundStyle(.secondary)
                    Picker("Credential", selection: $settings.credentialStatus) {
                        ForEach(IntegrationCredentialStatus.allCases) { status in
                            Text(status.label).tag(status)
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("Scopes")
                        .foregroundStyle(.secondary)
                    TextField("Approved scopes", text: approvedScopesTextBinding)
                        .textFieldStyle(.roundedBorder)
                        .help("Comma-separated non-secret scope names approved outside the app")
                }
                GridRow {
                    Text("Actions")
                        .foregroundStyle(.secondary)
                    Toggle("Allow reviewed external actions", isOn: $settings.allowsExternalActions)
                        .help("Still requires explicit operator review at the action surface")
                }
            }

            Text(requiredScopeSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let blocker = readiness?.blocker {
                Text(blocker)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 8)
    }

    private var approvedScopesTextBinding: Binding<String> {
        Binding(
            get: { settings.approvedScopes.joined(separator: ", ") },
            set: { value in
                settings.approvedScopes = value
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        )
    }

    private var requiredScopeSummary: String {
        if settings.requiredScopes.isEmpty {
            return "No OAuth scopes are required for this local policy."
        }
        return "Required scopes: \(settings.requiredScopes.joined(separator: ", "))."
    }
}
