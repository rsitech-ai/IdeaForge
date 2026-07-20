import AVFoundation
import StoreKit
import SwiftUI
import UIKit

enum AccountDestination: Hashable {
    case syncConflict
    case failedUploads
}

enum AppTab: String, CaseIterable, Identifiable {
    case inbox
    case ideas
    case questions
    case account

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inbox: "Inbox"
        case .ideas: "Ideas"
        case .questions: "Questions"
        case .account: "Account"
        }
    }

    var symbol: String {
        switch self {
        case .inbox: "tray"
        case .ideas: "lightbulb"
        case .questions: "questionmark.bubble"
        case .account: "person.crop.circle"
        }
    }

    var selectedSymbol: String {
        switch self {
        case .inbox: "tray.fill"
        case .ideas: "lightbulb.fill"
        case .questions: "questionmark.bubble.fill"
        case .account: "person.crop.circle.fill"
        }
    }

    var accessibilityHint: String {
        switch self {
        case .inbox: "Shows recordings and capture controls"
        case .ideas: "Shows idea projects"
        case .questions: "Shows questions waiting for answers"
        case .account: "Shows account, sync, upload, and integration controls"
        }
    }

    var accentColor: Color {
        switch self {
        case .inbox: .cyan
        case .ideas: .orange
        case .questions: .indigo
        case .account: .teal
        }
    }
}

struct iOSContentView: View {
    @Environment(\.openURL) private var openURL
    @Bindable var store: IdeaForgeStore
    private let backendConfigurationManager: BackendConfigurationManager
    private let uploadProcessingCoordinator: UploadQueueProcessingCoordinator
    private let commerceService: any CommerceServicing
    @ObservedObject private var pushNotificationTokenCenter: PushNotificationTokenCenter
    @State private var selectedTab: AppTab = .inbox
    @State private var requestedAccountDestination: AccountDestination?
    @State private var recorder: LocalAudioRecorder
    @State private var isRecording = false
    @State private var isProcessingUploads = false
    @State private var isSyncingWorkspace = false
    @State private var isProcessingAI = false
    @State private var isProcessingLocalSpeech = false
    @State private var backendSettings = BackendConnectionSettings()
    @State private var backendTokenEntry = ""
    @State private var backendStatusMessage = "Local upload fallback active."
    @State private var localSpeechStatusMessage = "Local speech ready for recordings kept on this iPhone."
    @State private var authenticatedSession: BackendAuthenticatedSession?
    @State private var authStatusMessage = "Backend session not validated."
    @State private var isValidatingAuthSession = false
    @State private var accountUsageSummary: BackendAccountUsageSummary?
    @State private var accountStatusMessage = "Backend account usage not loaded."
    @State private var isRefreshingAccountUsage = false
    @State private var storeKitProducts: [CommerceProduct] = []
    @State private var activeCommerceProductIDs: [String] = []
    @State private var commerceStatusMessage = "StoreKit products not loaded."
    @State private var isLoadingCommerce = false
    @State private var isPurchasingCommerce = false
    @State private var isRestoringCommerce = false
    @State private var pushNotificationStatusMessage = "Push sync is not registered."
    @State private var isRegisteringPushNotifications = false
    @State private var isAwaitingPushDeviceToken = false

    @MainActor
    init(
        store: IdeaForgeStore,
        backendConfigurationManager: BackendConfigurationManager = .production(),
        uploadProcessingCoordinator: UploadQueueProcessingCoordinator,
        commerceService: (any CommerceServicing)? = nil,
        pushNotificationTokenCenter: PushNotificationTokenCenter
    ) {
        self.store = store
        self.backendConfigurationManager = backendConfigurationManager
        self.uploadProcessingCoordinator = uploadProcessingCoordinator
        self.commerceService = commerceService ?? Self.defaultCommerceService()
        _pushNotificationTokenCenter = ObservedObject(wrappedValue: pushNotificationTokenCenter)
        _recorder = State(initialValue: Self.defaultRecorder())
    }

    private var dashboard: MobileDashboardSnapshot {
        MobileDashboardSnapshot(
            projects: store.projects,
            syncHealth: store.syncHealth,
            privacyMode: store.privacyMode,
            uploadJobs: store.uploadJobs
        )
    }

    private var syncReadiness: MobileSyncReadinessSnapshot {
        MobileSyncReadinessSnapshot(
            projects: store.projects,
            syncHealth: store.syncHealth,
            privacyMode: store.privacyMode,
            uploadJobs: store.uploadJobs
        )
    }

    private var workspaceSyncPlan: MobileWorkspaceSyncPlanSnapshot {
        MobileWorkspaceSyncPlanSnapshot(
            state: store.workspaceState(),
            capabilityDecision: backendCapabilityDecision(requiredCapabilities: [.syncWorkspace])
        )
    }

    private var syncTrust: MobileSyncTrustSnapshot {
        MobileSyncTrustSnapshot(
            state: store.workspaceState(),
            readiness: syncReadiness,
            plan: workspaceSyncPlan
        )
    }

    private var canonicalUploadSummary: CanonicalUploadSummary {
        CanonicalUploadSummary(
            projects: store.projects,
            uploadJobs: store.uploadJobs,
            syncHealth: store.syncHealth
        )
    }

    private var inboxStatus: InboxStatusSnapshot? {
        InboxStatusSnapshot(
            uploadSummary: canonicalUploadSummary,
            syncConflict: store.syncHealth.syncConflictStatus,
            watchReachable: store.syncHealth.watchReachable
        )
    }

    private var recordingRows: [RecordingRowSnapshot] {
        RecordingRowSnapshot.history(
            projects: store.projects,
            uploadJobs: store.uploadJobs
        )
    }

    private static func defaultCommerceService() -> any CommerceServicing {
        if ProcessInfo.processInfo.arguments.contains("-uiTesting") {
            return CommerceFixtureService(products: [
                CommerceProduct(
                    id: CommerceProductID.proMonthly,
                    displayName: "IdeaForge Pro Monthly",
                    priceLabel: "$9.99",
                    billingPeriod: .monthly
                ),
                CommerceProduct(
                    id: CommerceProductID.proYearly,
                    displayName: "IdeaForge Pro Yearly",
                    priceLabel: "$89.99",
                    billingPeriod: .yearly
                )
            ])
        }
        return StoreKitCommerceService()
    }

    private static func defaultRecorder() -> LocalAudioRecorder {
        if ProcessInfo.processInfo.arguments.contains("-uiTestingRecordingPermissionDenied") {
            return LocalAudioRecorder(permissionClient: DeniedRecordingPermissionClient())
        }
        if ProcessInfo.processInfo.arguments.contains("-uiTestingRecoveredRecording") {
            let root = FileManager.default.temporaryDirectory
                .appending(path: "IdeaForge-RecoveredRecording-UIFixture", directoryHint: .isDirectory)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let audioURL = root.appending(path: "recovered-ui-fixture.m4a")
            try? Data("IdeaForge recovered recording UI fixture".utf8).write(to: audioURL)
            let journal = RecordingRecoveryJournal(
                store: FileRecordingRecoveryCheckpointStore(
                    fileURL: root.appending(path: "active-recording.json")
                )
            )
            let startedAt = Date().addingTimeInterval(-24)
            try? journal.begin(
                context: RecordingCaptureContext(
                    projectTitle: "Recovered simulator recording",
                    tag: .appIdea,
                    source: .iphone,
                    transcriptHint: "Recovered from an interrupted simulator recording.",
                    ideaProjectID: "idea_ui_recovered_recording",
                    recordingID: "rec_ui_recovered_recording"
                ),
                localAudioURL: audioURL,
                startedAt: startedAt
            )
            try? journal.markTerminated(reason: .interrupted, at: startedAt.addingTimeInterval(18))
            return LocalAudioRecorder(recoveryJournal: journal)
        }
        return LocalAudioRecorder()
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                RecordingInboxView(
                    store: store,
                    status: inboxStatus,
                    rows: recordingRows,
                    isRecording: isRecording,
                    isProcessingUploads: isProcessingUploads
                ) {
                    Task {
                        await toggleRecording()
                    }
                } onStatusAction: { action in
                    handleInboxStatusAction(action)
                } onRetryUpload: { recordingID in
                    retryPersistedUpload(recordingID: recordingID)
                }
            }
            .tabItem { tabLabel(for: .inbox) }
            .tag(AppTab.inbox)

            NavigationStack {
                ProjectListView(store: store, snapshot: dashboard)
            }
            .tabItem { tabLabel(for: .ideas) }
            .tag(AppTab.ideas)

            NavigationStack {
                QuestionsReviewView(store: store)
            }
            .tabItem { tabLabel(for: .questions) }
            .tag(AppTab.questions)

            NavigationStack {
                AccountHubView(
                    store: store,
                    requestedDestination: $requestedAccountDestination,
                    snapshot: dashboard,
                    syncReadiness: syncReadiness,
                    syncPlan: workspaceSyncPlan,
                    syncTrust: syncTrust,
                    backendSettings: $backendSettings,
                    backendTokenEntry: $backendTokenEntry,
                    backendStatusMessage: backendStatusMessage,
                    localSpeechStatusMessage: localSpeechStatusMessage,
                    authenticatedSession: authenticatedSession,
                    authStatusMessage: authStatusMessage,
                    accountUsageSummary: accountUsageSummary,
                    accountStatusMessage: accountStatusMessage,
                    storeKitProducts: storeKitProducts,
                    activeCommerceProductIDs: activeCommerceProductIDs,
                    commerceStatusMessage: commerceStatusMessage,
                    pushNotificationStatusMessage: pushNotificationStatusMessage,
                    isProcessingUploads: isProcessingUploads,
                    isSyncingWorkspace: isSyncingWorkspace,
                    isProcessingAI: isProcessingAI,
                    isProcessingLocalSpeech: isProcessingLocalSpeech,
                    isValidatingAuthSession: isValidatingAuthSession,
                    isRefreshingAccountUsage: isRefreshingAccountUsage,
                    isLoadingCommerce: isLoadingCommerce,
                    isPurchasingCommerce: isPurchasingCommerce,
                    isRestoringCommerce: isRestoringCommerce,
                    isRegisteringPushNotifications: isRegisteringPushNotifications,
                    onSaveBackend: saveBackendConfiguration,
                    onClearBackendCredentials: clearBackendCredentials,
                    onSyncWorkspace: {
                        Task {
                            await syncBackendWorkspace()
                        }
                    },
                    onRefreshWorkspace: {
                        Task {
                            await refreshBackendWorkspace()
                        }
                    },
                    onResolveSyncConflict: { selection in
                        Task {
                            await mergeSyncConflictPreservingLocalWork(selection: selection)
                        }
                    },
                    onValidateSession: {
                        Task {
                            await validateBackendSession()
                        }
                    },
                    onProcessAI: {
                        Task {
                            await processUploadedAudioForAI()
                        }
                    },
                    onProcessLocalSpeech: {
                        Task {
                            await processLocalSpeechTranscription()
                        }
                    },
                    onRefreshAccountUsage: {
                        Task {
                            await refreshAccountUsage()
                        }
                    },
                    onRefreshCommerce: {
                        Task {
                            await refreshCommerceState()
                        }
                    },
                    onPurchaseProduct: { productID in
                        Task {
                            await purchaseCommerceProduct(productID)
                        }
                    },
                    onRestorePurchases: {
                        Task {
                            await restoreCommercePurchases()
                        }
                    },
                    onManageSubscription: {
                        Task {
                            await manageSubscription()
                        }
                    },
                    onRequestAccountDeletion: {
                        requestAccountDeletion()
                    },
                    onRegisterPushNotifications: {
                        Task {
                            await preparePushNotificationSync()
                        }
                    },
                    onProcessUploads: {
                        Task {
                            await processUploadQueue()
                        }
                    },
                    onRetryUpload: { recordingID in
                        retryPersistedUpload(recordingID: recordingID)
                    }
                )
            }
            .tabItem { tabLabel(for: .account) }
            .tag(AppTab.account)
        }
        .tint(selectedTab.accentColor)
        .background {
            MobileAmbientBackdrop(
                tint: selectedTab.accentColor,
                isActive: dashboard.isLiveActivityActive || isRecording || isProcessingUploads || isSyncingWorkspace || isProcessingAI || isProcessingLocalSpeech
            )
        }
        .safeAreaInset(edge: .top) {
            if liveStatusStripIsVisible {
                MobileLiveStatusStrip(
                    snapshot: dashboard,
                    selectedTab: selectedTab,
                    isRecording: isRecording,
                    isProcessingUploads: isProcessingUploads,
                    isSyncingWorkspace: isSyncingWorkspace,
                    isProcessingAI: isProcessingAI,
                    isProcessingLocalSpeech: isProcessingLocalSpeech,
                    isAccountBusy: isValidatingAuthSession
                        || isRefreshingAccountUsage
                        || isLoadingCommerce
                        || isPurchasingCommerce
                        || isRestoringCommerce
                        || isRegisteringPushNotifications
                )
                .padding(.horizontal)
                .padding(.top, 6)
                .padding(.bottom, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .alert(
            "IdeaForge needs attention",
            isPresented: Binding(
                get: { store.lastErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        store.lastErrorMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                store.lastErrorMessage = nil
            }
        } message: {
            Text(store.lastErrorMessage ?? "")
        }
        .onAppear {
            configureRecordingRecovery()
            loadBackendConfiguration()
            Task {
                await recoverPendingRecordingIfNeeded()
                await refreshCommerceState()
            }
        }
        .onChange(of: pushNotificationTokenCenter.deviceToken) { _, token in
            guard let token, isAwaitingPushDeviceToken else { return }
            Task {
                await registerPushDeviceToken(token)
            }
        }
        .onChange(of: pushNotificationTokenCenter.registrationFailureMessage) { _, message in
            guard let message else { return }
            isAwaitingPushDeviceToken = false
            pushNotificationStatusMessage = message
        }
    }

    @ViewBuilder
    private func tabLabel(for tab: AppTab) -> some View {
        Label {
            Text(tab.title)
        } icon: {
            Image(systemName: selectedTab == tab ? tab.selectedSymbol : tab.symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(selectedTab == tab ? tab.accentColor : .secondary)
        }
        .accessibilityLabel(tab.title)
        .accessibilityHint(tab.accessibilityHint)
    }

    private var liveStatusStripIsVisible: Bool {
        let hasGlobalOperation = isSyncingWorkspace
            || isProcessingAI
            || isProcessingLocalSpeech
            || isValidatingAuthSession
            || isRefreshingAccountUsage
            || isLoadingCommerce
            || isPurchasingCommerce
            || isRestoringCommerce
        if selectedTab == .inbox && !hasGlobalOperation {
            return false
        }
        return isRecording
            || isProcessingUploads
            || hasGlobalOperation
    }

    private func toggleRecording() async {
        do {
            if isRecording {
                IdeaForgeLog.recording.info("iOS recording stop requested")
                let draft = try recorder.stop(
                    projectTitle: "Quick captured idea",
                    tag: .appIdea,
                    source: .iphone,
                    transcriptHint: "A quick captured idea that needs follow-up questions and a product plan."
                )
                isRecording = false
                if await store.capture(draft) != nil {
                    try recorder.acknowledgePersistence()
                }
            } else {
                IdeaForgeLog.recording.info("iOS recording start requested")
                try await recorder.start(
                    recoveryContext: RecordingCaptureContext(
                        projectTitle: "Quick captured idea",
                        tag: .appIdea,
                        source: .iphone,
                        transcriptHint: "A quick captured idea that needs follow-up questions and a product plan."
                    )
                )
                isRecording = true
            }
        } catch {
            isRecording = false
            store.lastErrorMessage = (error as? UserFacingIdeaForgeError)?.userFacingMessage ?? "Recording failed."
            IdeaForgeLog.recording.error("iOS recording control failed")
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
                store.lastErrorMessage = "A saved recording still needs recovery. Try again before starting another recording."
                return
            }
            try recorder.acknowledgePersistence()
            isRecording = false
            let reason = expectedReason ?? recovery.terminationReason
            store.lastErrorMessage = reason == .userStopped
                ? "A recording saved before the app closed was recovered."
                : "An interrupted recording was recovered and kept in your Inbox."
            IdeaForgeLog.recording.info("iOS recording recovery completed")
        } catch {
            isRecording = false
            store.lastErrorMessage = (error as? UserFacingIdeaForgeError)?.userFacingMessage
                ?? "A saved recording could not be recovered."
            IdeaForgeLog.recording.error("iOS recording recovery failed")
        }
    }

    private func handleInboxStatusAction(_ action: InboxStatusAction) {
        switch action {
        case .resolve:
            requestedAccountDestination = .syncConflict
            selectedTab = .account
        case .review:
            requestedAccountDestination = .failedUploads
            selectedTab = .account
        case .upload:
            Task {
                await processUploadQueue()
            }
        }
    }

    private func retryPersistedUpload(recordingID: String) {
        guard store.retryUpload(recordingID: recordingID) else { return }
        Task {
            await processUploadQueue()
        }
    }

    private func processUploadQueue() async {
        isProcessingUploads = true
        defer {
            isProcessingUploads = false
        }

        let summary: UploadQueueProcessingSummary
        do {
            summary = try await uploadProcessingCoordinator.requestProcessing {
                try await processUploadQueuePass()
            }
        } catch BackendConfigurationError.invalidBaseURL {
            store.lastErrorMessage = "Backend URL is invalid. Fix Account settings before uploading."
            IdeaForgeLog.sync.error("Foreground upload queue processing failed; invalid backend URL")
            return
        } catch {
            store.lastErrorMessage = "Backend configuration could not be loaded."
            IdeaForgeLog.sync.error("Foreground upload queue processing failed; backend configuration unavailable")
            return
        }

        IdeaForgeLog.sync.info("Foreground upload queue processing completed; uploaded: \(summary.uploadedCount, privacy: .public), failed: \(summary.failedCount, privacy: .public)")
        if summary.failedCount > 0 {
            store.lastErrorMessage = "\(summary.failedCount) upload failed and will retry."
        }

        // Keep foreground uploads at parity with background refresh: publish the
        // local workspace snapshot so other devices see the uploaded recordings.
        let publishResult = await ConfiguredWorkspaceAutoSyncProcessor(
            backendConfigurationManager: backendConfigurationManager
        )
        .publishLocalSnapshotIfNeeded(from: store)
        switch publishResult {
        case .published(let publishSummary):
            IdeaForgeLog.sync.info("Foreground workspace auto-sync published snapshot: \(publishSummary.pushedLocalSnapshot, privacy: .public)")
        case .idle:
            IdeaForgeLog.sync.info("Foreground workspace auto-sync skipped; local workspace already has a backend receipt")
        case .skipped(let blocker, _):
            IdeaForgeLog.sync.warning("Foreground workspace auto-sync skipped; blocker: \(blocker.rawValue, privacy: .public)")
        }
    }

    private func processUploadQueuePass() async throws -> UploadQueueProcessingSummary {
        IdeaForgeLog.sync.info("Foreground upload queue processing started")
        if ProcessInfo.processInfo.arguments.contains("-uiTestingFailedUpload") {
            let objectRoot = FileManager.default.temporaryDirectory
                .appending(path: "IdeaForgeTaskFirstUploadObjects", directoryHint: .isDirectory)
            let objectStore = EncryptedLocalAudioObjectStore(
                objectRoot: objectRoot,
                keyProvider: StaticObjectEncryptionKeyProvider.testKey()
            )
            return await UploadQueueProcessor(
                client: LocalAudioObjectUploadClient(objectStore: objectStore),
                maxJobsPerRun: 10
            )
            .processDueUploads(in: store)
        }
        return try await ConfiguredUploadQueueProcessor(
            backendConfigurationManager: backendConfigurationManager
        )
        .processDueUploads(in: store)
    }

    private func loadBackendConfiguration() {
        do {
            backendSettings = try backendConfigurationManager.loadSettings()
            let hasToken: Bool
            if backendSettings.isEnabled {
                hasToken = try backendConfigurationManager.credentialStore.loadBearerToken()?.isEmpty == false
            } else {
                hasToken = false
            }
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
            IdeaForgeLog.settings.info("Backend settings loaded; enabled: \(backendSettings.isEnabled, privacy: .public)")
        } catch {
            backendStatusMessage = "Backend settings could not be loaded."
            IdeaForgeLog.settings.error("Backend settings could not be loaded")
        }
    }

    private func saveBackendConfiguration() {
        do {
            guard !backendSettings.isEnabled || backendSettings.hasValidBaseURL else {
                backendStatusMessage = "Enter a valid https:// backend URL."
                IdeaForgeLog.settings.warning("Backend settings save skipped; invalid URL")
                return
            }
            guard !backendSettings.isEnabled || !backendSettings.normalizedWorkspaceID.isEmpty else {
                backendStatusMessage = "Enter a backend workspace ID."
                IdeaForgeLog.settings.warning("Backend settings save skipped; workspace ID missing")
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
            IdeaForgeLog.settings.info("Backend settings saved; enabled: \(backendSettings.isEnabled, privacy: .public), token provided: \(token != nil, privacy: .public)")
        } catch {
            backendStatusMessage = "Backend settings could not be saved."
            IdeaForgeLog.settings.error("Backend settings could not be saved")
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
            IdeaForgeLog.settings.info("Backend credentials cleared")
        } catch {
            backendStatusMessage = "Backend token could not be cleared."
            IdeaForgeLog.settings.error("Backend credentials could not be cleared")
        }
    }

    private func syncBackendWorkspace() async {
        guard !isSyncingWorkspace else { return }
        if case .blocked(_, let message) = WorkspaceAutoSyncPolicy.localPreflightDecision(
            for: store.workspaceState()
        ) {
            backendStatusMessage = message
            store.recordSyncActivity(
                WorkspaceSyncActivityReceipt(
                    source: .manualPublish,
                    status: .blocked,
                    title: "Publish paused",
                    detail: message,
                    occurredAt: Date()
                )
            )
            IdeaForgeLog.sync.warning("Workspace backend sync skipped; local publication policy blocked action")
            return
        }
        let capabilityDecision = backendCapabilityDecision(requiredCapabilities: [.syncWorkspace])
        guard capabilityDecision.isAllowed else {
            backendStatusMessage = "Workspace sync needs validated backend capability. \(capabilityDecision.blockerSummary)"
            store.recordSyncActivity(
                WorkspaceSyncActivityReceipt(
                    source: .manualPublish,
                    status: .blocked,
                    title: "Publish paused",
                    detail: backendStatusMessage,
                    occurredAt: Date()
                )
            )
            IdeaForgeLog.sync.warning("Workspace backend sync skipped; capability gate blocked action")
            return
        }
        isSyncingWorkspace = true
        IdeaForgeLog.sync.info("Workspace backend sync started")
        defer { isSyncingWorkspace = false }

        do {
            guard let configuration = try backendConfigurationManager.resolvedSyncConfiguration() else {
                backendStatusMessage = "Remote sync needs backend settings, workspace ID, and a token."
                store.recordSyncActivity(
                    WorkspaceSyncActivityReceipt(
                        source: .manualPublish,
                        status: .blocked,
                        title: "Publish paused",
                        detail: backendStatusMessage,
                        occurredAt: Date()
                    )
                )
                IdeaForgeLog.sync.warning("Workspace backend sync skipped; configuration missing")
                return
            }
            let engine = WorkspaceSyncEngine(
                client: BackendWorkspaceSyncClient(configuration: configuration)
            )
            let summary = try await engine.synchronize(store: store)
            backendStatusMessage = summary.pushedLocalSnapshot
                ? "Local workspace published for iPhone, Watch, and Mac sync."
                : "Workspace already up to date across devices."
            store.recordSyncActivity(
                WorkspaceSyncActivityReceipt(
                    source: .manualPublish,
                    status: summary.pushedLocalSnapshot ? .success : .skipped,
                    title: summary.pushedLocalSnapshot ? "Workspace published" : "Publish not needed",
                    detail: summary.pushedLocalSnapshot
                        ? "Backend receipt is ready for Mac handoff."
                        : "This iPhone already has the latest backend receipt.",
                    occurredAt: Date()
                ),
                clearsLastError: true
            )
            IdeaForgeLog.sync.info("Workspace backend sync completed; pushed local snapshot: \(summary.pushedLocalSnapshot, privacy: .public)")
        } catch BackendConfigurationError.invalidBaseURL {
            backendStatusMessage = "Enter a valid https:// backend URL."
            store.recordSyncActivity(
                WorkspaceSyncActivityReceipt(
                    source: .manualPublish,
                    status: .blocked,
                    title: "Publish paused",
                    detail: backendStatusMessage,
                    occurredAt: Date()
                )
            )
            IdeaForgeLog.sync.error("Workspace backend sync failed; invalid backend URL")
        } catch let conflict as WorkspaceSyncConflictError {
            backendStatusMessage = conflict.report.message
            store.recordSyncActivity(
                WorkspaceSyncActivityReceipt(
                    source: .manualPublish,
                    status: .blocked,
                    title: "Publish needs review",
                    detail: conflict.report.message,
                    occurredAt: Date()
                )
            )
            IdeaForgeLog.sync.error("Workspace backend sync blocked by conflict; local upload jobs: \(conflict.report.localOnlyUploadJobIDs.count, privacy: .public), local recordings: \(conflict.report.localOnlyRecordingIDs.count, privacy: .public)")
        } catch {
            backendStatusMessage = "Workspace sync failed."
            store.recordSyncActivity(
                WorkspaceSyncActivityReceipt(
                    source: .manualPublish,
                    status: .failed,
                    title: "Publish failed",
                    detail: backendStatusMessage,
                    occurredAt: Date()
                )
            )
            IdeaForgeLog.sync.error("Workspace backend sync failed")
        }
    }

    private func refreshBackendWorkspace() async {
        guard !isSyncingWorkspace else { return }
        let capabilityDecision = backendCapabilityDecision(requiredCapabilities: [.syncWorkspace])
        guard capabilityDecision.isAllowed else {
            backendStatusMessage = "Workspace refresh needs validated backend capability. \(capabilityDecision.blockerSummary)"
            store.recordSyncActivity(
                WorkspaceSyncActivityReceipt(
                    source: .manualRefresh,
                    status: .blocked,
                    title: "Refresh paused",
                    detail: backendStatusMessage,
                    occurredAt: Date()
                )
            )
            IdeaForgeLog.sync.warning("Workspace backend refresh skipped; capability gate blocked action")
            return
        }
        isSyncingWorkspace = true
        IdeaForgeLog.sync.info("Workspace backend refresh started")
        defer { isSyncingWorkspace = false }

        do {
            guard let configuration = try backendConfigurationManager.resolvedSyncConfiguration() else {
                backendStatusMessage = "Remote refresh needs backend settings, workspace ID, and a token."
                store.recordSyncActivity(
                    WorkspaceSyncActivityReceipt(
                        source: .manualRefresh,
                        status: .blocked,
                        title: "Refresh paused",
                        detail: backendStatusMessage,
                        occurredAt: Date()
                    )
                )
                IdeaForgeLog.sync.warning("Workspace backend refresh skipped; configuration missing")
                return
            }
            let engine = WorkspaceSyncEngine(
                client: BackendWorkspaceSyncClient(configuration: configuration)
            )
            let summary = try await engine.pullLatest(into: store)
            if summary.appliedRemoteSnapshot {
                backendStatusMessage = "Latest backend workspace applied on this iPhone."
            } else {
                backendStatusMessage = "This iPhone already has the latest workspace."
            }
            store.recordSyncActivity(
                WorkspaceSyncActivityReceipt(
                    source: .manualRefresh,
                    status: summary.appliedRemoteSnapshot ? .success : .skipped,
                    title: summary.appliedRemoteSnapshot ? "Workspace refreshed" : "Refresh not needed",
                    detail: summary.appliedRemoteSnapshot
                        ? "This iPhone applied the latest backend workspace."
                        : "No newer backend workspace was available.",
                    occurredAt: Date()
                ),
                clearsLastError: true
            )
            IdeaForgeLog.sync.info("Workspace backend refresh completed; applied remote snapshot: \(summary.appliedRemoteSnapshot, privacy: .public)")
        } catch BackendConfigurationError.invalidBaseURL {
            backendStatusMessage = "Enter a valid https:// backend URL."
            store.recordSyncActivity(
                WorkspaceSyncActivityReceipt(
                    source: .manualRefresh,
                    status: .blocked,
                    title: "Refresh paused",
                    detail: backendStatusMessage,
                    occurredAt: Date()
                )
            )
            IdeaForgeLog.sync.error("Workspace backend refresh failed; invalid backend URL")
        } catch let conflict as WorkspaceSyncConflictError {
            backendStatusMessage = conflict.report.message
            store.recordSyncActivity(
                WorkspaceSyncActivityReceipt(
                    source: .manualRefresh,
                    status: .blocked,
                    title: "Refresh needs review",
                    detail: conflict.report.message,
                    occurredAt: Date()
                )
            )
            IdeaForgeLog.sync.error("Workspace backend refresh blocked by conflict; local upload jobs: \(conflict.report.localOnlyUploadJobIDs.count, privacy: .public), local recordings: \(conflict.report.localOnlyRecordingIDs.count, privacy: .public)")
        } catch {
            backendStatusMessage = "Workspace refresh failed."
            store.recordSyncActivity(
                WorkspaceSyncActivityReceipt(
                    source: .manualRefresh,
                    status: .failed,
                    title: "Refresh failed",
                    detail: backendStatusMessage,
                    occurredAt: Date()
                )
            )
            IdeaForgeLog.sync.error("Workspace backend refresh failed")
        }
    }

    private func mergeSyncConflictPreservingLocalWork(selection: WorkspaceSyncConflictMergeSelection? = nil) async {
        guard !isSyncingWorkspace else { return }
        guard store.syncHealth.syncConflictStatus != nil else {
            backendStatusMessage = "No sync conflict is waiting for recovery."
            return
        }
        let capabilityDecision = backendCapabilityDecision(requiredCapabilities: [.syncWorkspace])
        guard capabilityDecision.isAllowed else {
            backendStatusMessage = "Conflict recovery needs validated backend capability. \(capabilityDecision.blockerSummary)"
            IdeaForgeLog.sync.warning("Workspace conflict merge skipped; capability gate blocked action")
            return
        }
        isSyncingWorkspace = true
        IdeaForgeLog.sync.info("Workspace conflict merge started")
        defer { isSyncingWorkspace = false }

        do {
            guard let configuration = try backendConfigurationManager.resolvedSyncConfiguration() else {
                backendStatusMessage = "Conflict recovery needs backend settings, workspace ID, and a token."
                IdeaForgeLog.sync.warning("Workspace conflict merge skipped; configuration missing")
                return
            }
            let engine = WorkspaceSyncEngine(
                client: BackendWorkspaceSyncClient(configuration: configuration)
            )
            if let conflict = store.syncHealth.syncConflictStatus,
               !conflict.reviewItems.isEmpty,
               let selection {
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
            IdeaForgeLog.sync.info("Workspace conflict merge completed")
        } catch BackendConfigurationError.invalidBaseURL {
            backendStatusMessage = "Enter a valid https:// backend URL."
            IdeaForgeLog.sync.error("Workspace conflict merge failed; invalid backend URL")
        } catch {
            backendStatusMessage = "Workspace conflict merge failed."
            IdeaForgeLog.sync.error("Workspace conflict merge failed")
        }
    }

    private func validateBackendSession() async {
        guard !isValidatingAuthSession else { return }
        isValidatingAuthSession = true
        IdeaForgeLog.settings.info("iOS backend session validation started")
        defer { isValidatingAuthSession = false }

        do {
            guard let configuration = try backendConfigurationManager.resolvedAuthConfiguration() else {
                authStatusMessage = "Session validation needs backend settings, workspace ID, and a token."
                authenticatedSession = nil
                IdeaForgeLog.settings.warning("iOS backend session validation skipped; configuration missing")
                return
            }
            let session = try await BackendAuthSessionClient(configuration: configuration).validateSession()
            authenticatedSession = session
            authStatusMessage = "Backend session validated."
            IdeaForgeLog.settings.info("iOS backend session validation completed; capabilities: \(session.capabilities.count, privacy: .public)")
        } catch BackendConfigurationError.invalidBaseURL {
            authStatusMessage = "Enter a valid https:// backend URL."
            authenticatedSession = nil
            IdeaForgeLog.settings.error("iOS backend session validation failed; invalid backend URL")
        } catch {
            authStatusMessage = "Backend session validation failed."
            authenticatedSession = nil
            IdeaForgeLog.settings.error("iOS backend session validation failed")
        }
    }

    private func processUploadedAudioForAI() async {
        guard !isProcessingAI else { return }
        guard AIServicePolicy.allowsCloudAI(privacyMode: store.privacyMode) else {
            backendStatusMessage = "Private mode blocks backend AI."
            IdeaForgeLog.workflow.warning("Backend AI processing skipped; privacy mode blocks cloud AI")
            return
        }
        let capabilityDecision = backendCapabilityDecision(requiredCapabilities: [.runAIWorkflows])
        guard capabilityDecision.isAllowed else {
            backendStatusMessage = "Backend AI needs validated backend capability. \(capabilityDecision.blockerSummary)"
            IdeaForgeLog.workflow.warning("Backend AI processing skipped; capability gate blocked action")
            return
        }

        isProcessingAI = true
        IdeaForgeLog.workflow.info("Backend AI processing started")
        defer { isProcessingAI = false }

        do {
            guard let configuration = try backendConfigurationManager.resolvedAIConfiguration() else {
                backendStatusMessage = "Backend AI needs remote settings, workspace ID, and a token."
                IdeaForgeLog.workflow.warning("Backend AI processing skipped; configuration missing")
                return
            }

            let services = BackendAIServiceFactory.services(
                configuration: configuration,
                privacyMode: store.privacyMode,
                accountUsageSummary: try await refreshedAccountUsageSummaryForBackendAI()
            )
            let summary = await store.processUploadedRecordingsForTranscription(services: services)
            if summary.attemptedCount == 0 {
                backendStatusMessage = "No uploaded recordings are ready for AI."
            } else if summary.failedCount > 0 {
                backendStatusMessage = "\(summary.completedCount) transcribed, \(summary.failedCount) failed."
            } else {
                backendStatusMessage = "\(summary.completedCount) recording transcription completed."
            }
            IdeaForgeLog.workflow.info("Backend AI processing completed; attempted: \(summary.attemptedCount, privacy: .public), completed: \(summary.completedCount, privacy: .public), failed: \(summary.failedCount, privacy: .public)")
        } catch BackendConfigurationError.invalidBaseURL {
            backendStatusMessage = "Enter a valid https:// backend URL."
            IdeaForgeLog.workflow.error("Backend AI processing failed; invalid backend URL")
        } catch iOSAIActionError.accountUsageUnavailable {
            backendStatusMessage = "Backend AI needs account usage before processing."
            IdeaForgeLog.workflow.error("Backend AI processing skipped; account usage unavailable")
        } catch {
            backendStatusMessage = "Backend AI failed."
            IdeaForgeLog.workflow.error("Backend AI processing failed")
        }
    }

    private func processLocalSpeechTranscription() async {
        guard !isProcessingLocalSpeech else { return }
        isProcessingLocalSpeech = true
        localSpeechStatusMessage = "Local speech transcription is running."
        IdeaForgeLog.workflow.info("iOS local speech transcription started")
        defer { isProcessingLocalSpeech = false }

        let summary = await store.processLocalRecordingsForSpeechTranscription(services: .localSpeech)
        if summary.attemptedCount == 0 {
            localSpeechStatusMessage = "No local iPhone or Watch recordings are ready for speech."
        } else if summary.failedCount > 0 {
            localSpeechStatusMessage = "\(summary.completedCount) local transcript ready, \(summary.failedCount) needs review."
        } else {
            localSpeechStatusMessage = "\(summary.completedCount) local transcript ready."
        }
        IdeaForgeLog.workflow.info("iOS local speech transcription completed; attempted: \(summary.attemptedCount, privacy: .public), completed: \(summary.completedCount, privacy: .public), failed: \(summary.failedCount, privacy: .public)")
    }

    private func refreshedAccountUsageSummaryForBackendAI() async throws -> BackendAccountUsageSummary {
        guard let configuration = try backendConfigurationManager.resolvedAccountConfiguration() else {
            throw iOSAIActionError.accountUsageUnavailable
        }
        let summary = try await BackendAccountUsageClient(configuration: configuration).fetchUsageSummary()
        accountUsageSummary = summary
        accountStatusMessage = "Usage updated."
        return summary
    }

    private func refreshAccountUsage() async {
        guard !isRefreshingAccountUsage else { return }
        let capabilityDecision = backendCapabilityDecision(requiredCapabilities: [.manageAccount])
        guard capabilityDecision.isAllowed else {
            accountStatusMessage = "Usage refresh needs validated backend capability. \(capabilityDecision.blockerSummary)"
            IdeaForgeLog.settings.warning("Backend account usage refresh skipped; capability gate blocked action")
            return
        }
        isRefreshingAccountUsage = true
        IdeaForgeLog.settings.info("Backend account usage refresh started")
        defer { isRefreshingAccountUsage = false }

        do {
            guard let configuration = try backendConfigurationManager.resolvedAccountConfiguration() else {
                accountStatusMessage = "Usage needs backend settings, workspace ID, and a token."
                IdeaForgeLog.settings.warning("Backend account usage refresh skipped; configuration missing")
                return
            }
            let summary = try await BackendAccountUsageClient(configuration: configuration).fetchUsageSummary()
            accountUsageSummary = summary
            accountStatusMessage = "Usage updated."
            IdeaForgeLog.settings.info("Backend account usage refresh completed; usage metrics: \(summary.usage.count, privacy: .public), entitlements: \(summary.entitlements.count, privacy: .public)")
        } catch BackendConfigurationError.invalidBaseURL {
            accountStatusMessage = "Enter a valid https:// backend URL."
            IdeaForgeLog.settings.error("Backend account usage refresh failed; invalid backend URL")
        } catch {
            accountStatusMessage = "Usage refresh failed."
            IdeaForgeLog.settings.error("Backend account usage refresh failed")
        }
    }

    private func refreshCommerceState() async {
        guard !isLoadingCommerce else { return }
        isLoadingCommerce = true
        IdeaForgeLog.settings.info("iOS StoreKit commerce refresh started")
        defer { isLoadingCommerce = false }

        do {
            let products = try await commerceService.loadProducts(productIDs: CommerceProductID.all)
            let activeProductIDs = try await commerceService.activeProductIDs(productIDs: CommerceProductID.all)
            storeKitProducts = products
            activeCommerceProductIDs = activeProductIDs
            if products.isEmpty {
                commerceStatusMessage = "No App Store products returned. Configure IdeaForge Pro products in App Store Connect."
            } else if activeProductIDs.isEmpty {
                commerceStatusMessage = "StoreKit products loaded. No active subscription restored."
            } else {
                commerceStatusMessage = "Active App Store subscription restored."
                await reconcileBackendBilling(reason: .refresh)
            }
            IdeaForgeLog.settings.info("iOS StoreKit commerce refresh completed; products: \(products.count, privacy: .public), active: \(activeProductIDs.count, privacy: .public)")
        } catch {
            storeKitProducts = []
            activeCommerceProductIDs = []
            commerceStatusMessage = "StoreKit refresh failed. Check App Store Connect product setup."
            IdeaForgeLog.settings.error("iOS StoreKit commerce refresh failed")
        }
    }

    private func purchaseCommerceProduct(_ productID: String) async {
        guard !isPurchasingCommerce else { return }
        isPurchasingCommerce = true
        IdeaForgeLog.settings.info("iOS StoreKit purchase started")
        defer { isPurchasingCommerce = false }

        do {
            let result = try await commerceService.purchase(productID: productID)
            switch result {
            case .purchased:
                activeCommerceProductIDs = try await commerceService.activeProductIDs(productIDs: CommerceProductID.all)
                if await reconcileBackendBilling(reason: .purchase) {
                    commerceStatusMessage = "Purchase completed and backend entitlement reconciled."
                }
            case .pending:
                commerceStatusMessage = "Purchase is pending App Store approval."
            case .userCancelled:
                commerceStatusMessage = "Purchase cancelled."
            }
            IdeaForgeLog.settings.info("iOS StoreKit purchase finished")
        } catch CommerceServiceError.productUnavailable {
            commerceStatusMessage = "Selected App Store product is unavailable."
            IdeaForgeLog.settings.error("iOS StoreKit purchase failed; product unavailable")
        } catch {
            commerceStatusMessage = "Purchase failed."
            IdeaForgeLog.settings.error("iOS StoreKit purchase failed")
        }
    }

    private func restoreCommercePurchases() async {
        guard !isRestoringCommerce else { return }
        isRestoringCommerce = true
        IdeaForgeLog.settings.info("iOS StoreKit restore started")
        defer { isRestoringCommerce = false }

        do {
            let result = try await commerceService.restorePurchases(productIDs: CommerceProductID.all)
            activeCommerceProductIDs = result.activeProductIDs
            commerceStatusMessage = result.hasActiveSubscription ? "Purchases restored." : "No active App Store subscription found."
            if result.hasActiveSubscription {
                if await reconcileBackendBilling(reason: .restore) {
                    commerceStatusMessage = "Purchases restored and backend entitlement reconciled."
                }
            }
            IdeaForgeLog.settings.info("iOS StoreKit restore completed; active: \(result.activeProductIDs.count, privacy: .public)")
        } catch {
            commerceStatusMessage = "Restore failed."
            IdeaForgeLog.settings.error("iOS StoreKit restore failed")
        }
    }

    private func manageSubscription() async {
        guard !activeCommerceProductIDs.isEmpty else {
            commerceStatusMessage = "No active App Store subscription found."
            IdeaForgeLog.settings.warning("iOS StoreKit subscription management skipped; active subscription missing")
            return
        }
        guard let scene = Self.foregroundWindowScene() else {
            commerceStatusMessage = "Subscription management needs an active app window."
            IdeaForgeLog.settings.error("iOS StoreKit subscription management failed; active window scene missing")
            return
        }

        do {
            try await AppStore.showManageSubscriptions(in: scene)
            commerceStatusMessage = "Subscription management opened."
            IdeaForgeLog.settings.info("iOS StoreKit subscription management opened")
        } catch {
            commerceStatusMessage = "Subscription management failed."
            IdeaForgeLog.settings.error("iOS StoreKit subscription management failed")
        }
    }

    @discardableResult
    private func reconcileBackendBilling(reason: AppStoreBillingReconciliationReason) async -> Bool {
        guard !activeCommerceProductIDs.isEmpty else {
            return false
        }
        let capabilityDecision = backendCapabilityDecision(requiredCapabilities: [.reconcileBilling])
        guard capabilityDecision.isAllowed else {
            commerceStatusMessage = "Billing reconciliation needs validated backend capability. \(capabilityDecision.blockerSummary)"
            IdeaForgeLog.settings.warning("iOS billing reconciliation skipped; capability gate blocked action")
            return false
        }

        do {
            guard let configuration = try backendConfigurationManager.resolvedBillingReconciliationConfiguration() else {
                commerceStatusMessage = "App Store entitlement active. Configure backend billing reconciliation before cloud limits update."
                IdeaForgeLog.settings.warning("iOS billing reconciliation skipped; backend billing configuration missing")
                return false
            }

            let transactions = try await commerceService.activeTransactionEvidence(productIDs: activeCommerceProductIDs)
            guard !transactions.isEmpty else {
                commerceStatusMessage = "App Store entitlement active, but transaction evidence is unavailable."
                IdeaForgeLog.settings.error("iOS billing reconciliation failed; transaction evidence missing")
                return false
            }

            let summary = try await BackendBillingReconciliationClient(configuration: configuration)
                .reconcileAppStoreEntitlements(
                    AppStoreBillingReconciliationRequest(
                        reason: reason,
                        transactions: transactions
                    )
                )
            accountUsageSummary = summary
            accountStatusMessage = "Backend billing entitlement reconciled."
            IdeaForgeLog.settings.info("iOS billing reconciliation completed; transactions: \(transactions.count, privacy: .public)")
            return true
        } catch {
            commerceStatusMessage = "Backend billing reconciliation failed."
            IdeaForgeLog.settings.error("iOS billing reconciliation failed")
            return false
        }
    }

    private func requestAccountDeletion() {
        let capabilityDecision = backendCapabilityDecision(requiredCapabilities: [.manageAccount])
        guard capabilityDecision.isAllowed else {
            accountStatusMessage = "Account deletion needs validated backend capability. \(capabilityDecision.blockerSummary)"
            IdeaForgeLog.settings.warning("iOS account deletion skipped; capability gate blocked action")
            return
        }
        guard let accountDeletionURL = accountUsageSummary?.accountDeletionURL else {
            accountStatusMessage = "Account deletion needs a backend deletion portal."
            IdeaForgeLog.settings.warning("iOS account deletion skipped; deletion portal missing")
            return
        }
        openURL(accountDeletionURL)
        accountStatusMessage = "Account deletion portal opened."
        IdeaForgeLog.settings.info("iOS account deletion portal opened")
    }

    private func preparePushNotificationSync() async {
        guard !isRegisteringPushNotifications else { return }
        let capabilityDecision = backendCapabilityDecision(requiredCapabilities: [.syncWorkspace, .registerPushNotifications])
        guard capabilityDecision.isAllowed else {
            pushNotificationStatusMessage = "Push sync needs validated backend capability. \(capabilityDecision.blockerSummary)"
            IdeaForgeLog.sync.warning("iOS push sync registration skipped; capability gate blocked action")
            return
        }

        isRegisteringPushNotifications = true
        defer { isRegisteringPushNotifications = false }

        do {
            let alertAuthorization = try await PushNotificationAuthorizationRequester.authorizeAndRequestDeviceToken()

            if let token = pushNotificationTokenCenter.deviceToken {
                await registerPushDeviceToken(token)
            } else {
                isAwaitingPushDeviceToken = true
                pushNotificationStatusMessage = alertAuthorization == .denied
                    ? "Silent push registration requested. Alerts remain off; waiting for the APNs device token."
                    : "Notification registration requested. Waiting for the APNs device token."
                IdeaForgeLog.sync.info("iOS push sync registration waiting for APNs device token")
            }
        } catch {
            isAwaitingPushDeviceToken = false
            pushNotificationStatusMessage = PushNotificationRegistrationBlocker.requestFailed.userFacingMessage
            IdeaForgeLog.sync.error("iOS push sync authorization failed")
        }
    }

    private func registerPushDeviceToken(_ token: Data) async {
        let managesBusyState = !isRegisteringPushNotifications
        if managesBusyState {
            isRegisteringPushNotifications = true
        }
        isAwaitingPushDeviceToken = false
        defer {
            if managesBusyState {
                isRegisteringPushNotifications = false
            }
        }

        do {
            let registration = try BackendPushDeviceRegistrationRequest(
                apnsDeviceToken: BackendAPNSDeviceToken(data: token),
                environment: .current,
                platform: .iOS,
                bundleID: Bundle.main.bundleIdentifier ?? "com.s1kor.ideaforge.ios",
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
                topics: [.workspaceSync, .recordingProcessing, .account]
            )
            let result = await ConfiguredPushNotificationRegistrationProcessor(
                backendConfigurationManager: backendConfigurationManager
            )
            .registerDevice(registration)

            switch result {
            case .registered(let receipt):
                let topicLabel = receipt.enabledTopics.map(\.label).joined(separator: ", ")
                pushNotificationStatusMessage = topicLabel.isEmpty
                    ? "Push sync registered."
                    : "Push sync registered for \(topicLabel)."
                IdeaForgeLog.sync.info("iOS push sync registered; topics: \(receipt.enabledTopics.count, privacy: .public)")
            case .skipped(_, let message):
                pushNotificationStatusMessage = message
                IdeaForgeLog.sync.warning("iOS push sync registration skipped")
            }
        } catch {
            pushNotificationStatusMessage = PushNotificationRegistrationBlocker.requestFailed.userFacingMessage
            IdeaForgeLog.sync.error("iOS push sync registration failed before backend request")
        }
    }

    private func backendCapabilityDecision(
        requiredCapabilities: [BackendAccountCapability]
    ) -> BackendCapabilityDecision {
        BackendCapabilityGate(session: authenticatedSession).decision(
            requiredCapabilities: requiredCapabilities,
            expectedWorkspaceID: backendSettings.normalizedWorkspaceID
        )
    }

    private static func foregroundWindowScene() -> UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }
}

private struct DeniedRecordingPermissionClient: AudioRecordingPermissionChecking {
    func requestRecordPermission() async -> Bool {
        false
    }
}

private enum iOSAIActionError: Error {
    case accountUsageUnavailable
}

private struct MobileLiveStatusStrip: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var snapshot: MobileDashboardSnapshot
    var selectedTab: AppTab
    var isRecording: Bool
    var isProcessingUploads: Bool
    var isSyncingWorkspace: Bool
    var isProcessingAI: Bool
    var isProcessingLocalSpeech: Bool
    var isAccountBusy: Bool

    private var tint: Color {
        if isRecording { return .orange }
        if isProcessingUploads { return .cyan }
        if isSyncingWorkspace { return .indigo }
        if isProcessingAI { return .purple }
        if isProcessingLocalSpeech { return .mint }
        if isAccountBusy { return .teal }
        return snapshot.liveHealthTone.mobileTint
    }

    private var title: String {
        if isRecording { return "Recording active" }
        if isProcessingUploads { return "Uploading captures" }
        if isSyncingWorkspace { return "Syncing workspace" }
        if isProcessingAI { return "Backend AI running" }
        if isProcessingLocalSpeech { return "Local speech running" }
        if isAccountBusy { return "Account check running" }
        return snapshot.liveHealthTitle
    }

    private var detail: String {
        if isRecording { return "Capture stays local until you choose a backend path." }
        if isProcessingUploads { return "Queued audio is moving through the upload pipeline." }
        if isSyncingWorkspace { return "Remote state is being checked before local work changes." }
        if isProcessingAI { return "Uploaded recordings are being processed through the configured backend." }
        if isProcessingLocalSpeech { return "Local iPhone and Watch recordings are being transcribed on this device." }
        if isAccountBusy { return "Store, account, or entitlement state is refreshing." }
        return snapshot.liveHealthDetail
    }

    private var symbolName: String {
        if isRecording { return "mic.circle.fill" }
        if isProcessingUploads { return "icloud.and.arrow.up" }
        if isSyncingWorkspace { return "arrow.triangle.2.circlepath" }
        if isProcessingAI { return "sparkles" }
        if isProcessingLocalSpeech { return "waveform" }
        if isAccountBusy { return "person.badge.key" }
        return snapshot.liveHealthTone.symbolName
    }

    private var isActive: Bool {
        isRecording || isProcessingUploads || isSyncingWorkspace || isProcessingAI || isProcessingLocalSpeech || isAccountBusy || snapshot.isLiveActivityActive
    }

    var body: some View {
        LiquidGlassPanel(tint: tint.opacity(0.16), interactive: false, isLive: isActive) {
            HStack(alignment: .center, spacing: 12) {
                MobileLiveIconBadge(
                    systemImage: symbolName,
                    tint: tint,
                    isActive: isActive && !reduceMotion,
                    size: 38,
                    cornerRadius: 13
                )

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(selectedTab.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(tint)
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                    }
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                MobileSignalGlyph(tint: tint, isActive: isActive && !reduceMotion)
            }

            MobileLiveFlowRibbon(tint: tint, isActive: isActive && !reduceMotion)
                .frame(height: 14)
                .padding(.top, 8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(selectedTab.title). \(title). \(detail)")
        .accessibilityIdentifier("ios.liveStatusStrip")
    }
}

struct RecordingInboxView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var store: IdeaForgeStore
    var status: InboxStatusSnapshot?
    var rows: [RecordingRowSnapshot]
    var isRecording: Bool
    var isProcessingUploads: Bool
    var onRecord: () -> Void
    var onStatusAction: (InboxStatusAction) -> Void
    var onRetryUpload: (String) -> Void
    @State private var selectedRecordingID: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if let status {
                    InboxStatusBanner(
                        snapshot: status,
                        isProcessingAction: status.action == .upload && isProcessingUploads,
                        onAction: onStatusAction
                    )
                    .accessibilityIdentifier("ios.inbox.statusBanner")
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                InboxCaptureButton(
                    isRecording: isRecording,
                    onRecord: onRecord
                )
                .accessibilityIdentifier("ios.inbox.captureAction")

                if rows.isEmpty {
                    ContentUnavailableView(
                        "No recordings yet",
                        systemImage: "waveform",
                        description: Text("Record an idea to start your Inbox.")
                    )
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("ios.inbox.emptyState")
                } else {
                    Section {
                        ForEach(rows) { row in
                            Button {
                                selectedRecordingID = row.id
                            } label: {
                                RecordingInboxRow(snapshot: row)
                            }
                            .buttonStyle(.plain)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("ios.inbox.recordingRow.\(row.id)")
                            .accessibilityLabel(recordingAccessibilityLabel(for: row))
                            .accessibilityValue(recordingAccessibilityValue(for: row))
                            .accessibilityHint("Open recording details")
                        }
                    } header: {
                        Text("Recordings")
                            .font(.headline)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("ios.inbox.recordingList")
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .accessibilityIdentifier("ios.inbox.scroll")
        .navigationTitle("Recording Inbox")
        .navigationBarTitleDisplayMode(.inline)
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: status)
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: isRecording)
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: selectedRecordingID)
        .sheet(isPresented: isShowingRecordingDetail) {
            if let selectedRecordingID {
                RecordingDetailView(
                    store: store,
                    recordingID: selectedRecordingID,
                    onRetryUpload: onRetryUpload
                )
            } else {
                ContentUnavailableView("Recording unavailable", systemImage: "waveform.slash")
            }
        }
    }

    private var isShowingRecordingDetail: Binding<Bool> {
        Binding(
            get: { selectedRecordingID != nil },
            set: { isPresented in
                if !isPresented {
                    selectedRecordingID = nil
                }
            }
        )
    }

    private func recordingAccessibilityLabel(for row: RecordingRowSnapshot) -> String {
        "\(row.title) recording"
    }

    private func recordingAccessibilityValue(for row: RecordingRowSnapshot) -> Text {
        Text("\(row.durationSeconds) seconds, ")
            + Text(row.createdAt, style: .relative)
            + Text(", \(row.state.rawValue)")
    }
}

private struct InboxStatusBanner: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var snapshot: InboxStatusSnapshot
    var isProcessingAction: Bool
    var onAction: (InboxStatusAction) -> Void

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    bannerContent
                    if let action = snapshot.action {
                        actionButton(action)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    bannerContent
                    Spacer(minLength: 8)
                    if let action = snapshot.action {
                        actionButton(action)
                    }
                }
            }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(tint.opacity(0.24))
        }
        .accessibilityElement(children: .contain)
    }

    private var bannerContent: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.headline)
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot.title)
                    .font(.headline)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(statusAccessibilityLabel)
            .accessibilityValue(snapshot.title)
            .accessibilityHint(detail)
            .accessibilityIdentifier("ios.inbox.statusBanner.content")
        }
    }

    private func actionButton(_ action: InboxStatusAction) -> some View {
        Button {
            onAction(action)
        } label: {
            if isProcessingAction {
                ProgressView()
                    .controlSize(.small)
                    .frame(minWidth: 44, minHeight: 44)
            } else {
                Text(actionTitle(for: action))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minHeight: 44)
            }
        }
        .buttonStyle(.bordered)
        .disabled(isProcessingAction)
        .accessibilityIdentifier("ios.inbox.statusBanner.action")
        .accessibilityLabel(isProcessingAction ? "Uploading" : actionTitle(for: action))
        .accessibilityHint(actionHint(for: action))
    }

    private var symbol: String {
        switch snapshot.kind {
        case .syncConflict: "arrow.triangle.2.circlepath.circle"
        case .failedUpload: "exclamationmark.triangle"
        case .queuedUpload: "icloud.and.arrow.up"
        case .offline: "applewatch.slash"
        }
    }

    private var tint: Color {
        switch snapshot.kind {
        case .syncConflict, .failedUpload: .orange
        case .queuedUpload: .cyan
        case .offline: .secondary
        }
    }

    private var detail: String {
        switch snapshot.kind {
        case .syncConflict:
            "Review the conflicting workspace choices in Account before sync continues."
        case .failedUpload:
            "Review the failed upload and retained-audio diagnostics in Account."
        case .queuedUpload:
            "The recording is stored safely and ready for its next upload."
        case .offline:
            "The recording remains on Watch and sync resumes after reconnection."
        }
    }

    private var statusAccessibilityLabel: String {
        switch snapshot.kind {
        case .syncConflict: "Sync status"
        case .failedUpload, .queuedUpload: "Upload status"
        case .offline: "Watch status"
        }
    }

    private func actionTitle(for action: InboxStatusAction) -> String {
        switch action {
        case .resolve: "Resolve"
        case .review: "Review"
        case .upload: "Upload"
        }
    }

    private func actionHint(for action: InboxStatusAction) -> String {
        switch action {
        case .resolve: "Open Account conflict resolution"
        case .review: "Open Account failed-upload diagnostics"
        case .upload: "Process the existing upload queue"
        }
    }
}

private struct InboxCaptureButton: View {
    var isRecording: Bool
    var onRecord: () -> Void

    var body: some View {
        Button(action: onRecord) {
            Label(isRecording ? "Stop" : "Record", systemImage: isRecording ? "stop.fill" : "mic.fill")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .tint(isRecording ? .red : .cyan)
        .accessibilityLabel(isRecording ? "Stop Recording" : "Record")
        .accessibilityHint(isRecording ? "Stop recording and add the idea to the Inbox" : "Start recording a new idea")
    }
}

private struct RecordingInboxRow: View {
    var snapshot: RecordingRowSnapshot

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: snapshot.state.symbol)
                .font(.headline)
                .foregroundStyle(snapshot.state.tint)
                .frame(width: 36, height: 36)
                .background(snapshot.state.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(snapshot.createdAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("ios.inbox.recordingDate.\(snapshot.id)")
                Text("\(snapshot.durationSeconds)s - \(snapshot.state.rawValue)")
                    .font(.subheadline)
                    .foregroundStyle(snapshot.state.tint)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(snapshot.state.tint.opacity(0.18))
        }
    }
}

private struct RecordingDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: IdeaForgeStore
    var recordingID: String
    var onRetryUpload: (String) -> Void

    var body: some View {
        NavigationStack {
            List {
                if let context {
                    let retainedAudio = store.retainedAudioValidation(recordingID: recordingID)

                    Section("Recording") {
                        LabeledContent("Project", value: context.row.title)
                        LabeledContent("Source", value: context.recording.deviceName)
                        LabeledContent("Recorded", value: context.row.createdAt.formatted(date: .abbreviated, time: .shortened))
                        LabeledContent("Duration", value: "\(context.row.durationSeconds) seconds")
                        LabeledContent("State", value: context.row.state.rawValue)
                            .accessibilityElement(children: .ignore)
                            .accessibilityIdentifier("ios.recordingDetail.state")
                            .accessibilityLabel("State")
                            .accessibilityValue(context.row.state.rawValue)
                    }

                    Section("Playback") {
                        if retainedAudio == .available,
                           let localAudioPath = context.recording.localAudioPath {
                            RecordingPlaybackButton(localAudioPath: localAudioPath) {
                                store.lastErrorMessage = "Audio playback is unavailable for this recording."
                            }
                        } else {
                            Text("Audio playback is not available on this iPhone.")
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let uploadJob = context.uploadJob {
                        Section("Upload") {
                            LabeledContent("Status", value: uploadJob.status.label)
                                .accessibilityElement(children: .ignore)
                                .accessibilityIdentifier("ios.recordingDetail.uploadStatus")
                                .accessibilityLabel("Upload status")
                                .accessibilityValue(uploadJob.status.label)
                            LabeledContent("Retained audio", value: retainedAudio.label)
                                .accessibilityIdentifier("ios.recordingDetail.retainedAudio")
                            if uploadJob.status == .permanentlyFailed {
                                let category = uploadJob.failureCategory ?? .uploadError
                                LabeledContent("Reason", value: category.label)
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityIdentifier("ios.recordingDetail.failureCategory")
                                    .accessibilityLabel("Failure category")
                                    .accessibilityValue(category.label)
                            }
                            if uploadJob.status == .permanentlyFailed && retainedAudio.isRetryEligible {
                                Button {
                                    onRetryUpload(recordingID)
                                } label: {
                                    Label("Retry upload", systemImage: "arrow.clockwise")
                                        .frame(minHeight: 44)
                                }
                                .accessibilityIdentifier("ios.recordingDetail.retryUpload")
                                .accessibilityHint("Queues the retained recording without replacing its audio")
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("Recording unavailable", systemImage: "waveform.slash")
                }
            }
            .accessibilityIdentifier("ios.recordingDetail.list")
            .navigationTitle("Recording Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: dismiss.callAsFunction)
                }
            }
        }
    }

    private var context: RecordingDetailContext? {
        for project in store.projects {
            guard let recording = project.recordings.first(where: { $0.id == recordingID }) else {
                continue
            }
            let uploadJob = store.uploadJobs.first { $0.recordingID == recordingID }
            return RecordingDetailContext(
                row: RecordingRowSnapshot(
                    recording: recording,
                    projectTitle: project.title,
                    uploadJob: uploadJob,
                    hasRemoteReceipt: recording.audioObjectKey?.isEmpty == false
                ),
                recording: recording,
                uploadJob: uploadJob
            )
        }
        return nil
    }

    private struct RecordingDetailContext {
        var row: RecordingRowSnapshot
        var recording: Recording
        var uploadJob: UploadJob?
    }
}

private struct RecordingPlaybackButton: View {
    var localAudioPath: String
    var onFailure: () -> Void
    @State private var player: AVAudioPlayer?
    @State private var playbackResetTask: Task<Void, Never>?
    @State private var isPlaying = false

    var body: some View {
        Button(action: togglePlayback) {
            Label(
                isPlaying ? "Stop playback" : "Play recording",
                systemImage: isPlaying ? "stop.fill" : "play.fill"
            )
        }
        .frame(minHeight: 44)
        .accessibilityIdentifier("ios.recordingDetail.playback")
        .accessibilityLabel("Playback")
        .accessibilityValue(isPlaying ? "Playing" : "Stopped")
        .accessibilityHint(isPlaying ? "Stop retained audio playback" : "Play retained audio on this iPhone")
        .onDisappear(perform: stopPlayback)
    }

    private func togglePlayback() {
        if isPlaying {
            stopPlayback()
            return
        }

        do {
            let nextPlayer = try AVAudioPlayer(contentsOf: URL(filePath: localAudioPath))
            nextPlayer.prepareToPlay()
            guard nextPlayer.play() else {
                onFailure()
                return
            }
            player = nextPlayer
            isPlaying = true
            playbackResetTask?.cancel()
            playbackResetTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(nextPlayer.duration))
                guard !Task.isCancelled, player === nextPlayer else { return }
                player = nil
                isPlaying = false
            }
        } catch {
            player = nil
            isPlaying = false
            onFailure()
        }
    }

    private func stopPlayback() {
        playbackResetTask?.cancel()
        playbackResetTask = nil
        player?.stop()
        player = nil
        isPlaying = false
    }
}

private extension RecordingRowState {
    var symbol: String {
        switch self {
        case .onWatch: "applewatch"
        case .onIPhone: "iphone"
        case .readyToUpload: "icloud.and.arrow.up"
        case .uploading: "arrow.up.circle"
        case .retryScheduled: "clock.arrow.circlepath"
        case .failed: "exclamationmark.triangle"
        case .transcribed: "text.document"
        case .synced: "checkmark.icloud"
        }
    }

    var tint: Color {
        switch self {
        case .failed: .red
        case .retryScheduled: .orange
        case .uploading, .readyToUpload: .cyan
        case .synced, .transcribed: .mint
        case .onWatch, .onIPhone: .secondary
        }
    }
}

struct ProjectListView: View {
    @Bindable var store: IdeaForgeStore
    var snapshot: MobileDashboardSnapshot

    var body: some View {
        ZStack {
            MobileAmbientBackdrop(
                tint: snapshot.liveHealthTone.mobileTint,
                isActive: snapshot.isLiveActivityActive
            )
            ScrollView {
                LazyVStack(spacing: 12) {
                    MobileProjectListHero(snapshot: snapshot)
                        .dynamicTypeSize(.medium ... .xLarge)

                    MobileIdeaAgentPanel(projects: store.projects)
                        .dynamicTypeSize(.medium ... .xLarge)

                    ForEach(store.projects) { project in
                        NavigationLink {
                            ProjectDetailView(store: store, projectID: project.id)
                        } label: {
                            LiquidGlassPanel(
                                tint: project.mobileTint.opacity(0.14),
                                interactive: true,
                                isLive: project.isMobileLive
                            ) {
                                ProjectSummaryRow(project: project)
                            }
                        }
                        .buttonStyle(.plain)
                        .buttonStyle(MobileCardButtonStyle(tint: project.mobileTint, isLive: project.isMobileLive))
                        .accessibilityIdentifier("ios.project.row.\(project.id)")
                        .dynamicTypeSize(.medium ... .xLarge)
                    }
                }
                .padding()
                .padding(.bottom, 112)
            }
            .accessibilityIdentifier("ios.ideas.scroll")
        }
        .navigationTitle("Idea Projects")
    }
}

struct MobileProjectListHero: View {
    var snapshot: MobileDashboardSnapshot

    var body: some View {
        LiquidGlassPanel(
            tint: snapshot.liveHealthTone.mobileTint.opacity(0.15),
            interactive: snapshot.isLiveActivityActive,
            isLive: snapshot.isLiveActivityActive
        ) {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .center, spacing: 12) {
                    MobileLiveIconBadge(
                        systemImage: "lightbulb.2",
                        tint: .orange,
                        isActive: snapshot.isLiveActivityActive,
                        size: 38,
                        cornerRadius: 14
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Idea Workspace")
                            .font(.headline.weight(.semibold))
                            .lineLimit(1)
                        Text("Review projects, ask the local agent, and move the strongest idea toward build handoff.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                }

                MobileLiveFlowRibbon(tint: .orange, isActive: snapshot.isLiveActivityActive)
                    .frame(height: 14)

                HStack(spacing: 10) {
                    StatusPill(
                        title: "Queued",
                        value: "\(snapshot.queuedUploadCount)",
                        symbol: "tray",
                        tint: .cyan,
                        isActive: snapshot.queuedUploadCount > 0
                    )
                    StatusPill(
                        title: "Questions",
                        value: "\(snapshot.pendingQuestionCount)",
                        symbol: "questionmark.bubble",
                        tint: .indigo,
                        isActive: snapshot.pendingQuestionCount > 0
                    )
                }
            }
        }
        .accessibilityIdentifier("ios.ideas.hero")
    }
}

private struct MobileIdeaAgentPanel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var projects: [IdeaProject]
    @State private var query = "What should I validate next?"
    @State private var response: IdeaAgentResponse?

    private let agent = LocalIdeaAgent()

    private var active: Bool {
        response != nil
    }

    var body: some View {
        LiquidGlassPanel(tint: .indigo.opacity(0.14), interactive: true, isLive: active && !reduceMotion) {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .center, spacing: 12) {
                    MobileLiveIconBadge(
                        systemImage: "sparkles",
                        tint: .indigo,
                        isActive: active && !reduceMotion,
                        size: 38,
                        cornerRadius: 14
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Idea Agent")
                            .font(.headline.weight(.semibold))
                        Text("Ask across local summaries, transcripts, questions, validation plans, and artifacts.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    MobileSignalGlyph(tint: .indigo, isActive: active && !reduceMotion)
                }

                HStack(spacing: 9) {
                    TextField("Ask your ideas", text: $query, axis: .vertical)
                        .lineLimit(1...3)
                        .textInputAutocapitalization(.sentences)
                        .autocorrectionDisabled(false)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                        .mobileInputSurface(tint: .indigo, cornerRadius: 15)
                        .accessibilityIdentifier("ios.ideaAgent.query")

                    Button {
                        ask()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2.weight(.semibold))
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .foregroundStyle(.indigo)
                    .accessibilityLabel("Ask Idea Agent")
                    .accessibilityIdentifier("ios.ideaAgent.ask")
                    .accessibilityHint("Ask a local question about your idea workspace")
                }

                if let response {
                    Text(response.answer)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("ios.ideaAgent.answer")

                    if !response.citations.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Grounded in")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(response.citations) { citation in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(citation.projectTitle) - \(citation.sourceTitle)")
                                        .font(.caption2.weight(.semibold))
                                    Text(citation.excerpt)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(3)
                                }
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .accessibilityIdentifier("ios.ideaAgent.citation.\(citation.id)")
                            }
                        }
                    }
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            ForEach(agent.respond(to: "", projects: projects).suggestedPrompts, id: \.self) { prompt in
                                suggestedPromptButton(prompt)
                            }
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(agent.respond(to: "", projects: projects).suggestedPrompts, id: \.self) { prompt in
                                suggestedPromptButton(prompt)
                            }
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ios.ideaAgent")
    }

    private func suggestedPromptButton(_ prompt: String) -> some View {
        Button {
            query = prompt
            ask()
        } label: {
            Text(prompt)
                .font(.caption2.weight(.semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.70)
                .frame(maxWidth: .infinity, minHeight: 34)
        }
        .buttonStyle(.bordered)
        .tint(.indigo)
        .accessibilityIdentifier("ios.ideaAgent.suggestion")
    }

    private func ask() {
        response = agent.respond(to: query, projects: projects)
    }
}

struct MobileProjectHero: View {
    var project: IdeaProject

    private var tint: Color { project.mobileTint }
    private var symbol: String { project.mobileSymbol }

    var body: some View {
        LiquidGlassPanel(tint: tint.opacity(0.15), interactive: false, isLive: project.isMobileLive) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    MobileLiveIconBadge(
                        systemImage: symbol,
                        tint: tint,
                        isActive: project.isMobileLive,
                        size: 42,
                        cornerRadius: 14
                    )

                    VStack(alignment: .leading, spacing: 5) {
                        Text(project.title)
                            .font(.title3.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(project.summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    Text(project.status.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(tint.opacity(0.11), in: Capsule())
                        .overlay {
                            Capsule().strokeBorder(tint.opacity(0.18))
                        }
                }

                MobileStatusRail(tint: tint, isActive: project.isMobileLive)
                    .frame(height: 8)

                MobileLiveFlowRibbon(tint: tint, isActive: project.isMobileLive)
                    .frame(height: 18)

                MobileSignalField(tint: tint, isActive: project.isMobileLive)
                    .frame(height: 42)

                MobileReadinessPulseMeter(score: project.score, tint: tint, isActive: project.isMobileLive)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct MobileReadinessPulseMeter: View {
    var score: IdeaScore
    var tint: Color
    var isActive: Bool

    var body: some View {
        let active = isActive

        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Label("Readiness pulse", systemImage: "waveform.path.ecg")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(overall, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .contentTransition(.numericText(value: overall))
            }

            VStack(spacing: 8) {
                MobilePulseTrack(title: "Confidence", value: score.confidence, tint: .cyan, phase: false, isActive: active)
                MobilePulseTrack(title: "Build", value: score.completeness, tint: .mint, phase: false, isActive: active)
                MobilePulseTrack(title: "Risk", value: score.risk, tint: .orange, phase: false, isActive: active)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .strokeBorder(tint.opacity(active ? 0.24 : 0.14))
        }
        .shadow(color: tint.opacity(active ? 0.12 : 0.04), radius: active ? 12 : 5, y: active ? 6 : 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Readiness pulse. Confidence \(percent(score.confidence)), build \(percent(score.completeness)), risk \(percent(score.risk)).")
    }

    private var overall: Double {
        (score.confidence + score.completeness + (1 - score.risk)) / 3
    }

    private func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }
}

private struct MobileWorkspacePulseMeter: View {
    var snapshot: MobileDashboardSnapshot
    var isActive: Bool

    var body: some View {
        let active = isActive

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Workspace pulse", systemImage: snapshot.liveHealthTone.symbolName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(snapshot.liveHealthTone.mobileTint)
                    .labelStyle(.titleAndIcon)
                Spacer(minLength: 8)
                Text("\(snapshot.queuedUploadCount + snapshot.failedUploadCount + snapshot.pendingQuestionCount)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText(value: Double(snapshot.queuedUploadCount + snapshot.failedUploadCount + snapshot.pendingQuestionCount)))
            }

            HStack(spacing: 8) {
                MobileCountPulseChip(
                    title: "Queue",
                    count: snapshot.queuedUploadCount,
                    tint: .cyan,
                    phase: false,
                    isActive: active && snapshot.queuedUploadCount > 0
                )
                MobileCountPulseChip(
                    title: "Fail",
                    count: snapshot.failedUploadCount,
                    tint: .orange,
                    phase: false,
                    isActive: active && snapshot.failedUploadCount > 0
                )
                MobileCountPulseChip(
                    title: "Ask",
                    count: snapshot.pendingQuestionCount,
                    tint: .indigo,
                    phase: false,
                    isActive: active && snapshot.pendingQuestionCount > 0
                )
            }
        }
        .padding(11)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .strokeBorder(snapshot.liveHealthTone.mobileTint.opacity(active ? 0.24 : 0.14))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Workspace pulse. \(snapshot.queuedUploadCount) queued, \(snapshot.failedUploadCount) failed, \(snapshot.pendingQuestionCount) questions.")
    }
}

private struct MobileDeviceSyncPanel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var snapshot: MobileDashboardSnapshot
    var readiness: MobileSyncReadinessSnapshot
    var syncPlan: MobileWorkspaceSyncPlanSnapshot
    var syncTrust: MobileSyncTrustSnapshot
    var syncHealth: SyncHealth
    var backendStatusMessage: String?
    var isSyncingWorkspace: Bool
    var isProcessingUploads: Bool
    var isProcessingAI: Bool
    var primaryActionTitle: String
    var primaryActionSystemImage: String
    var primaryAccessibilityIdentifier: String
    var primaryAccessibilityHint: String
    var onPrimaryAction: () -> Void
    var wholePanelPrimaryAction: Bool
    var compactLayout: Bool
    var showsRoute: Bool
    var showsMetrics: Bool
    var secondaryActionTitle: String?
    var secondaryActionSystemImage: String
    var secondaryAccessibilityIdentifier: String
    var secondaryAccessibilityHint: String
    var onSecondaryAction: (() -> Void)?
    var hidesNextStepInCompactLayout = false
    var usesAccessibilitySummaryLayout = false

    private var tint: Color {
        if syncHealth.syncConflictStatus != nil { return .red }
        if snapshot.failedUploadCount > 0 { return .orange }
        if isSyncingWorkspace || isProcessingUploads || isProcessingAI || snapshot.queuedUploadCount > 0 { return .cyan }
        if syncHealth.watchReachable { return .teal }
        return .secondary
    }

    private var isLive: Bool {
        syncHealth.syncConflictStatus != nil
            || snapshot.failedUploadCount > 0
            || snapshot.queuedUploadCount > 0
            || isSyncingWorkspace
            || isProcessingUploads
            || isProcessingAI
    }

    private var title: String {
        if syncHealth.syncConflictStatus != nil { return "Sync needs review" }
        if isSyncingWorkspace { return "Syncing devices" }
        if isProcessingUploads { return "Uploading captures" }
        if isProcessingAI { return "Preparing transcripts" }
        if snapshot.failedUploadCount == 1 { return "1 upload needs review" }
        if snapshot.failedUploadCount > 1 { return "\(snapshot.failedUploadCount) uploads need review" }
        if snapshot.queuedUploadCount == 1 { return "1 recording waiting" }
        if snapshot.queuedUploadCount > 1 { return "\(snapshot.queuedUploadCount) recordings waiting" }
        return "Device sync ready"
    }

    private var detail: String {
        if let conflict = syncHealth.syncConflictStatus {
            return conflict.recoveryAction
        }
        if let backendStatusMessage, !backendStatusMessage.isEmpty {
            return backendStatusMessage
        }
        if snapshot.failedUploadCount == 1 {
            return "Open Account to review the failed upload before sync continues."
        }
        if snapshot.failedUploadCount > 1 {
            return "Open Account to review failed uploads before sync continues."
        }
        if snapshot.queuedUploadCount > 0 {
            return "Recordings are stored safely and waiting for their next upload window."
        }
        if snapshot.privacyMode == .privateLocal {
            return "Capture stays local until backend sync is enabled."
        }
        return "Watch capture, iPhone review, and Mac handoff are aligned."
    }

    private var compactPrimaryActionTitle: String {
        switch primaryActionTitle {
        case "Sync Settings", "Sync Now", "Syncing":
            return "Sync"
        case "Publish Workspace", "Publishing":
            return "Publish"
        case "Uploading", "Upload Queue":
            return "Upload"
        default:
            return primaryActionTitle
        }
    }

    private var showsCompactConflictReview: Bool {
        compactLayout && readiness.hasSyncConflict
    }

    private var isCompactInboxPanel: Bool {
        compactLayout && !showsRoute && !showsMetrics
    }

    private var usesAccessibilityInboxLayout: Bool {
        isCompactInboxPanel && (dynamicTypeSize.isAccessibilitySize || usesAccessibilitySummaryLayout)
    }

    private var showsReadinessStrip: Bool {
        !isCompactInboxPanel && (!compactLayout || showsRoute || showsMetrics || readiness.hasSyncConflict)
    }

    var body: some View {
        let active = isLive && !reduceMotion

        LiquidGlassPanel(tint: tint.opacity(0.14), interactive: true, isLive: active) {
            VStack(alignment: .leading, spacing: compactLayout ? 9 : 11) {
                HStack(alignment: .center, spacing: 12) {
                    MobileLiveIconBadge(
                        systemImage: syncHealth.watchReachable ? "applewatch.radiowaves.left.and.right" : "applewatch.slash",
                        tint: tint,
                        isActive: active,
                        size: usesAccessibilityInboxLayout ? 34 : 40,
                        cornerRadius: 14
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.headline)
                            .lineLimit(2)
                            .minimumScaleFactor(0.82)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(accessibilityDetailLineLimit)
                            .minimumScaleFactor(usesAccessibilityInboxLayout ? 0.76 : 1)
                            .fixedSize(horizontal: false, vertical: true)
                        if isCompactInboxPanel, let lastActivity = syncHealth.lastActivity {
                            Label(
                                compactActivitySummary(for: lastActivity),
                                systemImage: lastActivity.status.systemImage
                            )
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(compactActivityTint(for: lastActivity))
                            .lineLimit(usesAccessibilityInboxLayout ? 2 : 1)
                            .minimumScaleFactor(usesAccessibilityInboxLayout ? 0.74 : 0.68)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Last sync activity. \(lastActivity.title). \(lastActivity.detail).")
                            .accessibilityIdentifier("ios.inbox.syncLastActivity")
                        }
                    }

                    Spacer(minLength: 8)
                }

                if showsRoute && !showsCompactConflictReview {
                    MobileSyncHandoffSummaryStrip(
                        steps: readiness.timelineSteps,
                        isActive: active
                    )
                }

                if showsRoute {
                    MobileSyncTrustStrip(
                        trust: syncTrust,
                        isActive: active || syncTrust.isLive
                    )
                }

                HStack(spacing: 10) {
                    Button(action: onPrimaryAction) {
                        Label(compactPrimaryActionTitle, systemImage: primaryActionSystemImage)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.70)
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background(tint.gradient, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(primaryActionTitle)
                    .accessibilityIdentifier(primaryAccessibilityIdentifier)
                    .accessibilityHint(primaryAccessibilityHint)

                    if let secondaryActionTitle, onSecondaryAction != nil {
                        Button(action: onSecondaryAction ?? {}) {
                            Image(systemName: secondaryActionSystemImage)
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(tint)
                                .frame(width: 38, height: 38)
                                .background(.thinMaterial, in: Circle())
                                .overlay {
                                    Circle().strokeBorder(tint.opacity(0.20))
                            }
                        }
                        .buttonStyle(.plain)
                        .frame(width: 42, height: 42)
                        .accessibilityLabel(secondaryActionTitle)
                        .accessibilityIdentifier(secondaryAccessibilityIdentifier)
                        .accessibilityHint(secondaryAccessibilityHint)
                    }

                    Spacer(minLength: 0)
                }

                if showsRoute && !showsCompactConflictReview {
                    MobileDeviceRouteTimeline(
                        readiness: readiness,
                        syncHealth: syncHealth,
                        isSyncingWorkspace: isSyncingWorkspace,
                        isProcessingUploads: isProcessingUploads,
                        isProcessingAI: isProcessingAI,
                        tint: tint,
                        compact: compactLayout || !showsMetrics
                    )
                }

                if !usesAccessibilityInboxLayout && !hidesNextStepInCompactLayout {
                    MobileSyncNextStepStrip(
                        readiness: readiness,
                        tint: tint,
                        isActive: active
                    )
                }

                if !isCompactInboxPanel {
                    MobileWorkspaceAutoSyncStrip(
                        plan: syncPlan,
                        tint: syncPlan.tone.mobileTint,
                        isActive: active || syncPlan.isLive,
                        compact: compactLayout
                    )

                    if let lastActivity = syncHealth.lastActivity {
                        MobileSyncActivityReceiptStrip(
                            receipt: lastActivity,
                            isActive: active || isSyncingWorkspace || syncPlan.isLive,
                            compact: compactLayout,
                            accessibilityIdentifier: "ios.syncLastActivity"
                        )
                    }
                }

                if showsReadinessStrip {
                    MobileSyncReadinessStrip(
                        readiness: readiness,
                        showsHeader: !compactLayout || readiness.hasSyncConflict
                    )
                }

                if showsMetrics {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 8)], spacing: 8) {
                        MobileSyncMetricTile(
                            title: "Watch",
                            value: syncHealth.watchReachable ? "Online" : "Offline",
                            systemImage: syncHealth.watchReachable ? "applewatch.radiowaves.left.and.right" : "applewatch.slash",
                            tint: syncHealth.watchReachable ? .mint : .secondary,
                            isActive: active && !syncHealth.watchReachable
                        )
                        MobileSyncMetricTile(
                            title: "Queue",
                            value: "\(snapshot.queuedUploadCount)",
                            systemImage: "tray.and.arrow.up",
                            tint: .cyan,
                            isActive: active && snapshot.queuedUploadCount > 0
                        )
                        MobileSyncMetricTile(
                            title: "Failed",
                            value: "\(snapshot.failedUploadCount)",
                            systemImage: "exclamationmark.triangle",
                            tint: snapshot.failedUploadCount == 0 ? .mint : .orange,
                            isActive: active && snapshot.failedUploadCount > 0
                        )
                        MobileSyncMetricTile(
                            title: "Last sync",
                            value: syncHealth.lastSuccessfulSync.formatted(date: .abbreviated, time: .shortened),
                            systemImage: "clock.arrow.circlepath",
                            tint: .indigo,
                            isActive: active && isSyncingWorkspace
                        )
                        MobileSyncMetricTile(
                            title: "Remote",
                            value: remoteWorkspaceValue,
                            systemImage: "icloud",
                            tint: .teal,
                            isActive: active && isSyncingWorkspace
                        )
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ios.syncOverview")
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .onTapGesture {
            if wholePanelPrimaryAction {
                onPrimaryAction()
            }
        }
    }

    private var accessibilityDetailLineLimit: Int {
        if usesAccessibilityInboxLayout { return 4 }
        if showsCompactConflictReview { return 1 }
        return compactLayout ? 2 : 3
    }

    private var remoteWorkspaceValue: String {
        guard let remoteUpdatedAt = syncHealth.lastRemoteWorkspaceUpdatedAt else {
            return snapshot.privacyMode == .privateLocal ? "Local" : "Pending"
        }
        return remoteUpdatedAt.formatted(date: .abbreviated, time: .shortened)
    }

    private func compactActivitySummary(for receipt: WorkspaceSyncActivityReceipt) -> String {
        "\(receipt.title) / \(compactActivitySource(for: receipt)) / \(receipt.occurredAt.formatted(date: .omitted, time: .shortened))"
    }

    private func compactActivitySource(for receipt: WorkspaceSyncActivityReceipt) -> String {
        switch receipt.source {
        case .manualPublish: "Publish"
        case .manualRefresh: "Refresh"
        case .backgroundAutoSync: "Background"
        case .remoteNotification: "Push"
        }
    }

    private func compactActivityTint(for receipt: WorkspaceSyncActivityReceipt) -> Color {
        switch receipt.status {
        case .success: .mint
        case .skipped: .teal
        case .blocked: .orange
        case .failed: .red
        }
    }
}

private struct MobileSyncHandoffSummaryStrip: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var steps: [MobileSyncTimelineStep]
    var isActive: Bool

    var body: some View {
        let renderedSteps = Array(steps.prefix(4))
        let active = isActive && !reduceMotion

        HStack(alignment: .center, spacing: 4) {
            ForEach(Array(renderedSteps.enumerated()), id: \.element.id) { index, step in
                MobileSyncHandoffNode(step: step, isActive: active)
                if index < renderedSteps.count - 1 {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary.opacity(0.72))
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(Color.primary.opacity(active ? 0.12 : 0.08))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Device handoff route. \(renderedSteps.map { "\($0.title) \($0.statusLabel)" }.joined(separator: ", ")).")
        .accessibilityIdentifier("ios.syncHandoffSummary")
    }
}

private struct MobileSyncHandoffNode: View {
    var step: MobileSyncTimelineStep
    var isActive: Bool

    var body: some View {
        let tint = step.tone.mobileTint
        let emphasized = step.isCurrent || step.isBlocked

        VStack(spacing: 3) {
            Image(systemName: step.systemImage)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(tint.opacity(emphasized || isActive ? 0.14 : 0.07), in: Circle())
                .overlay {
                    Circle().strokeBorder(tint.opacity(emphasized || isActive ? 0.24 : 0.10))
                }
            Text(step.title)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.68)
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}

private struct MobileSyncTrustStrip: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var trust: MobileSyncTrustSnapshot
    var isActive: Bool

    private var tint: Color {
        trust.tone.mobileTint
    }

    var body: some View {
        let active = (isActive || trust.isLive) && !reduceMotion

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: trust.systemImage)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(active ? 0.15 : 0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(tint.opacity(active ? 0.24 : 0.12))
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text(trust.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.70)
                    Text(trust.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.64)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 6)

                Text(trust.actionTitle)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.66)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(tint.opacity(active ? 0.13 : 0.07), in: Capsule())
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 6)], spacing: 6) {
                MobileSyncTrustChip(
                    title: "Local",
                    value: trust.localStatus,
                    systemImage: "iphone",
                    tint: localTint,
                    accessibilityIdentifier: "ios.syncTrust.local"
                )
                MobileSyncTrustChip(
                    title: "Receipt",
                    value: trust.receiptStatus,
                    systemImage: "checkmark.icloud",
                    tint: receiptTint,
                    accessibilityIdentifier: "ios.syncTrust.receipt"
                )
                MobileSyncTrustChip(
                    title: "Mac",
                    value: trust.macHandoffStatus,
                    systemImage: "macbook",
                    tint: macTint,
                    accessibilityIdentifier: "ios.syncTrust.mac"
                )
                MobileSyncTrustChip(
                    title: "Blocker",
                    value: trust.blockerStatus,
                    systemImage: "shield.lefthalf.filled",
                    tint: blockerTint,
                    accessibilityIdentifier: "ios.syncTrust.blocker"
                )
            }
        }
        .padding(9)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .strokeBorder(tint.opacity(active ? 0.24 : 0.12))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sync trust. \(trust.title). \(trust.detail). Local \(trust.localStatus). Receipt \(trust.receiptStatus). Mac \(trust.macHandoffStatus). Blocker \(trust.blockerStatus).")
        .accessibilityIdentifier("ios.syncTrust")
    }

    private var localTint: Color {
        switch trust.localStatus {
        case "Clean": .mint
        case "Review": .red
        default: trust.localStatus.hasPrefix("Fix") ? .orange : .cyan
        }
    }

    private var receiptTint: Color {
        switch trust.receiptStatus {
        case "Receipted": .mint
        case "Paused", "Blocked": .red
        case "Local-only": .secondary
        case "Validate", "Setup", "Retry", "Outdated": .orange
        default: .teal
        }
    }

    private var macTint: Color {
        switch trust.macHandoffStatus {
        case "Ready": .mint
        case "Blocked", "Review": .red
        case "Local", "Setup", "Validate": .secondary
        default: .indigo
        }
    }

    private var blockerTint: Color {
        switch trust.blockerStatus {
        case "Clear": .mint
        case "Conflict": .red
        case "Private": .secondary
        default: .orange
        }
    }
}

private struct MobileSyncTrustChip: View {
    var title: String
    var value: String
    var systemImage: String
    var tint: Color
    var accessibilityIdentifier: String

    var body: some View {
        HStack(alignment: .center, spacing: 5) {
            Image(systemName: systemImage)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.66)
                Text(value)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.58)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .frame(minHeight: 42)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tint.opacity(0.12))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(value)")
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct MobileSyncNextStepStrip: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var readiness: MobileSyncReadinessSnapshot
    var tint: Color
    var isActive: Bool

    var body: some View {
        let active = isActive && !reduceMotion

        HStack(alignment: .center, spacing: 10) {
            Image(systemName: readiness.nextStepSystemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(active ? 0.15 : 0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(tint.opacity(active ? 0.24 : 0.12))
                }

            VStack(alignment: .leading, spacing: 3) {
                Text("Next: \(readiness.nextStepTitle)")
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.76)
                    .fixedSize(horizontal: false, vertical: true)
                Text(readiness.nextStepDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.68)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 6)

            Text(readiness.nextStepActionTitle)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .minimumScaleFactor(0.62)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(tint.opacity(active ? 0.14 : 0.08), in: Capsule())
                .overlay {
                    Capsule().strokeBorder(tint.opacity(active ? 0.22 : 0.11))
                }
        }
        .padding(9)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .strokeBorder(tint.opacity(active ? 0.24 : 0.12))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Next sync step. \(readiness.nextStepTitle). \(readiness.nextStepDetail). \(readiness.nextStepActionTitle).")
        .accessibilityIdentifier("ios.syncNextStep")
    }
}

private struct MobileWorkspaceAutoSyncStrip: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var plan: MobileWorkspaceSyncPlanSnapshot
    var tint: Color
    var isActive: Bool
    var compact = false

    var body: some View {
        let active = (isActive || plan.isLive) && !reduceMotion

        HStack(alignment: .center, spacing: 10) {
            Image(systemName: plan.systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: compact ? 26 : 30, height: compact ? 26 : 30)
                .background(tint.opacity(active ? 0.15 : 0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(tint.opacity(active ? 0.24 : 0.12))
                }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(plan.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.66)
                    Text(plan.statusLabel)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.68)
                        .padding(.horizontal, compact ? 6 : 7)
                        .padding(.vertical, compact ? 2 : 3)
                        .background(tint.opacity(active ? 0.13 : 0.07), in: Capsule())
                }
                if !compact {
                    Text(plan.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.66)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 6)

            if !compact {
                Text(plan.actionTitle)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(tint)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .minimumScaleFactor(0.62)
            }
        }
        .padding(compact ? 7 : 9)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .strokeBorder(tint.opacity(active ? 0.24 : 0.12))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Automatic sync. \(plan.title). \(plan.detail). \(plan.actionTitle).")
        .accessibilityIdentifier("ios.syncAutoPlan")
    }
}

private struct MobileSyncActivityReceiptStrip: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var receipt: WorkspaceSyncActivityReceipt
    var isActive: Bool
    var compact = false
    var accessibilityIdentifier = "ios.syncLastActivity"

    private var tint: Color {
        switch receipt.status {
        case .success: .mint
        case .skipped: .teal
        case .blocked: .orange
        case .failed: .red
        }
    }

    var body: some View {
        let active = isActive && receipt.status != .skipped && !reduceMotion

        HStack(alignment: .center, spacing: 10) {
            Image(systemName: receipt.status.systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: compact ? 26 : 30, height: compact ? 26 : 30)
                .background(tint.opacity(active ? 0.15 : 0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(tint.opacity(active ? 0.24 : 0.12))
                }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(receipt.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.66)
                    Text(receipt.source.label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.68)
                        .padding(.horizontal, compact ? 6 : 7)
                        .padding(.vertical, compact ? 2 : 3)
                        .background(tint.opacity(active ? 0.13 : 0.07), in: Capsule())
                }
                if !compact {
                    Text(receipt.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.66)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 2) {
                Text(receipt.status.label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(tint)
                Text(receipt.occurredAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.66)
        }
        .padding(compact ? 7 : 9)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .strokeBorder(tint.opacity(active ? 0.24 : 0.12))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Last sync activity. \(receipt.title). \(receipt.detail). \(receipt.source.label). \(receipt.status.label).")
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct MobileSyncHandoffStatusStrip: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var plan: MobileWorkspaceSyncPlanSnapshot
    var tint: Color
    var isActive: Bool

    var body: some View {
        let active = (isActive || plan.isLive) && !reduceMotion

        HStack(alignment: .center, spacing: 10) {
            Image(systemName: plan.systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(active ? 0.15 : 0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(tint.opacity(active ? 0.24 : 0.12))
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(plan.handoffTitle)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                Text(plan.handoffDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.66)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 6)

            Text(plan.handoffStatusLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.66)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(tint.opacity(active ? 0.13 : 0.07), in: Capsule())
                .overlay {
                    Capsule().strokeBorder(tint.opacity(active ? 0.22 : 0.11))
                }
        }
        .padding(9)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .strokeBorder(tint.opacity(active ? 0.24 : 0.12))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mac handoff. \(plan.handoffTitle). \(plan.handoffDetail). \(plan.handoffStatusLabel).")
        .accessibilityIdentifier("ios.syncHandoffStatus")
    }
}

private struct MobileSyncReadinessStrip: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var readiness: MobileSyncReadinessSnapshot
    var showsHeader = true

    private var tint: Color {
        readiness.tone.mobileTint
    }

    var body: some View {
        let active = readiness.isLive && !reduceMotion
        let compact = !showsHeader

        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            if showsHeader {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: readiness.tone.symbolName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                        .frame(width: 24, height: 24)
                        .background(tint.opacity(active ? 0.16 : 0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(readiness.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                        Text(readiness.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.62)
                    }

                    Spacer(minLength: 0)
                }
            }

            HStack(spacing: 7) {
                MobileSyncReadinessChip(
                    title: "Watch",
                    value: readiness.watchStatus,
                    systemImage: readiness.watchStatus == "Offline" ? "applewatch.slash" : "applewatch",
                    tint: readiness.watchStatus == "Offline" ? .secondary : .mint,
                    isActive: active && readiness.watchStatus == "Offline",
                    compact: compact,
                    accessibilityIdentifier: "ios.syncReadiness.watch"
                )
                MobileSyncReadinessChip(
                    title: "iPhone",
                    value: readiness.iPhoneStatus,
                    systemImage: "iphone",
                    tint: readiness.queuedCaptureCount > 0 ? .cyan : .mint,
                    isActive: active && readiness.queuedCaptureCount > 0,
                    compact: compact,
                    accessibilityIdentifier: "ios.syncReadiness.iphone"
                )
                MobileSyncReadinessChip(
                    title: "Backend",
                    value: readiness.backendStatus,
                    systemImage: "icloud",
                    tint: readiness.hasSyncConflict ? .red : (readiness.backendStatus == "Published" ? .mint : .teal),
                    isActive: active && (readiness.hasSyncConflict || readiness.backendStatus == "Pending"),
                    compact: compact,
                    accessibilityIdentifier: "ios.syncReadiness.backend"
                )
                MobileSyncReadinessChip(
                    title: "Mac",
                    value: readiness.macStatus,
                    systemImage: "macbook",
                    tint: readiness.macStatus == "Blocked" ? .red : .indigo,
                    isActive: active && readiness.macStatus != "Ready",
                    compact: compact,
                    accessibilityIdentifier: "ios.syncReadiness.mac"
                )
            }
        }
        .padding(compact ? 7 : 9)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .strokeBorder(tint.opacity(active ? 0.24 : 0.13))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(readiness.title). \(readiness.detail)")
        .accessibilityIdentifier("ios.syncReadiness")
    }
}

private struct MobileSyncReadinessChip: View {
    var title: String
    var value: String
    var systemImage: String
    var tint: Color
    var isActive: Bool
    var compact = false
    var accessibilityIdentifier: String

    var body: some View {
        VStack(spacing: compact ? 2 : 4) {
            Image(systemName: systemImage)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
            if !compact {
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
            Text(value)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.55)
        }
        .padding(.horizontal, compact ? 4 : 5)
        .padding(.vertical, compact ? 3 : 7)
        .frame(maxWidth: .infinity, minHeight: compact ? 30 : 54, alignment: .center)
        .background(tint.opacity(isActive ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tint.opacity(isActive ? 0.20 : 0.10))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(value)")
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct MobileDeviceRouteTimeline: View {
    var readiness: MobileSyncReadinessSnapshot
    var syncHealth: SyncHealth
    var isSyncingWorkspace: Bool
    var isProcessingUploads: Bool
    var isProcessingAI: Bool
    var tint: Color
    var compact = false

    private var steps: [MobileSyncTimelineStep] {
        readiness.timelineSteps.map { step in
            var renderedStep = step
            if step.id == "iphone", isProcessingUploads {
                renderedStep.statusLabel = "uploading"
                renderedStep.detail = "Upload queue is moving before workspace publish."
                renderedStep.tone = .active
                renderedStep.isCurrent = true
                renderedStep.isBlocked = false
            } else if step.id == "backend", isSyncingWorkspace {
                renderedStep.statusLabel = "publishing"
                renderedStep.detail = "Workspace snapshot is being checked and published."
                renderedStep.tone = .active
                renderedStep.isCurrent = true
                renderedStep.isBlocked = false
            } else if step.id == "backend", isProcessingAI {
                renderedStep.statusLabel = "transcribing"
                renderedStep.detail = "Uploaded recordings are being processed through the backend."
                renderedStep.tone = .active
                renderedStep.isCurrent = true
                renderedStep.isBlocked = false
            } else if step.id == "mac", isSyncingWorkspace {
                renderedStep.statusLabel = "updating"
                renderedStep.detail = "Mac handoff updates after the publish receipt."
                renderedStep.tone = .active
                renderedStep.isCurrent = true
                renderedStep.isBlocked = false
            }
            return renderedStep
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                MobileDeviceRouteStepView(step: step, compact: compact)
                if index < steps.count - 1 {
                    Capsule()
                        .fill(tint.opacity(0.22))
                        .frame(width: 10, height: 3)
                        .padding(.top, compact ? 12 : 14)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Cross-device route. \(steps.map { "\($0.title) \($0.statusLabel). \($0.detail)" }.joined(separator: ", ")).")
        .accessibilityIdentifier("ios.syncRoute")
    }
}

private struct MobileDeviceRouteStepView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var step: MobileSyncTimelineStep
    var compact = false

    var body: some View {
        let tint = step.tone.mobileTint
        let active = step.isCurrent || step.isBlocked

        VStack(spacing: compact ? 0 : 3) {
            Image(systemName: step.systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: compact ? 25 : 28, height: compact ? 25 : 28)
                .background(tint.opacity(active ? 0.15 : 0.08), in: Circle())
                .overlay {
                    Circle().strokeBorder(tint.opacity(active ? 0.28 : 0.12))
                }
                .shadow(color: tint.opacity(active && !reduceMotion ? 0.14 : 0), radius: 8, y: 4)
            if !compact {
                Text(step.title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Text(step.statusLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(step.title), \(step.statusLabel). \(step.detail)")
        .accessibilityIdentifier("ios.syncRoute.\(step.id)")
    }
}

private struct MobileSyncMetricTile: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var title: String
    var value: String
    var systemImage: String
    var tint: Color
    var isActive: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(tint.opacity(isActive ? 0.14 : 0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(value)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
            }

            Spacer(minLength: 0)
        }
        .padding(9)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(tint.opacity(isActive ? 0.22 : 0.10))
        }
        .shadow(color: tint.opacity(isActive && !reduceMotion ? 0.12 : 0.04), radius: isActive && !reduceMotion ? 9 : 4, y: isActive && !reduceMotion ? 5 : 2)
    }
}

private struct MobileCountPulseChip: View {
    var title: String
    var count: Int
    var tint: Color
    var phase: Bool
    var isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Spacer(minLength: 8)
                Text("\(count)")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.numericText(value: Double(count)))
            }

            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                let fillWidth = max(8, width * min(Double(max(count, 0)) / 4.0, 1))

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.055))
                    Capsule()
                        .fill(.linearGradient(
                            colors: [
                                tint.opacity(count > 0 ? 0.32 : 0.14),
                                tint.opacity(count > 0 ? 0.76 : 0.20),
                                .white.opacity(isActive ? 0.34 : 0.08)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                        .frame(width: fillWidth)
                        .overlay(alignment: .leading) {
                            if isActive {
                                Capsule()
                                    .fill(.linearGradient(
                                        colors: [
                                            .clear,
                                            .white.opacity(0.40),
                                            .clear
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    ))
                                    .frame(width: min(44, fillWidth))
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .opacity(phase ? 0.95 : 0.46)
                            }
                        }
                }
                .clipShape(Capsule())
            }
            .frame(height: 8)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(count > 0 ? 0.08 : 0.04), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(tint.opacity(count > 0 ? 0.16 : 0.08))
        }
    }
}

private struct MobilePulseTrack: View {
    var title: String
    var value: Double
    var tint: Color
    var phase: Bool
    var isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(value, format: .percent.precision(.fractionLength(0)))
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: value))
            }

            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                let fillWidth = max(8, width * min(max(value, 0), 1))

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.055))
                    Capsule()
                        .fill(.linearGradient(
                            colors: [
                                tint.opacity(0.34),
                                tint.opacity(0.78),
                                .white.opacity(isActive ? 0.36 : 0.10)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                        .frame(width: fillWidth)
                        .overlay(alignment: .leading) {
                            if isActive {
                                Capsule()
                                    .fill(.linearGradient(
                                        colors: [
                                            .clear,
                                            .white.opacity(0.42),
                                            .clear
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    ))
                                    .frame(width: min(44, fillWidth))
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .opacity(phase ? 0.95 : 0.46)
                            }
                        }
                }
                .clipShape(Capsule())
            }
            .frame(height: 8)
        }
    }
}

struct ProjectSummaryRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var project: IdeaProject

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                MobileLiveIconBadge(
                    systemImage: project.mobileSymbol,
                    tint: project.mobileTint,
                    isActive: project.isMobileLive && !reduceMotion,
                    size: 38,
                    cornerRadius: 13
                )
                VStack(alignment: .leading, spacing: 5) {
                    Text(project.title)
                        .font(.headline)
                        .lineLimit(2)
                    Text(project.summary)
                        .lineLimit(2)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text(project.status.label)
                        Text(project.source.label)
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }

            MobileProjectFlowMeter(project: project)

            MobileStatusRail(tint: project.mobileTint, isActive: project.isMobileLive && !reduceMotion)
                .frame(height: 7)
        }
    }
}

private struct MobileProjectFlowMeter: View {
    var project: IdeaProject

    private var active: Bool {
        project.isMobileLive
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                MobileProjectFlowChip(
                    title: "Confidence",
                    value: project.score.confidence,
                    tint: .cyan,
                    phase: false,
                    isActive: active
                )
                MobileProjectFlowChip(
                    title: "Build",
                    value: project.score.completeness,
                    tint: .mint,
                    phase: false,
                    isActive: active
                )
                MobileProjectFlowChip(
                    title: "Risk",
                    value: project.score.risk,
                    tint: .orange,
                    phase: false,
                    isActive: active
                )
            }

            MobileLiveFlowRibbon(tint: project.mobileTint, isActive: active)
                .frame(height: 12)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Project momentum. Confidence \(percent(project.score.confidence)), build \(percent(project.score.completeness)), risk \(percent(project.score.risk))."
        )
    }

    private func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }
}

private struct MobileProjectFlowChip: View {
    var title: String
    var value: Double
    var tint: Color
    var phase: Bool
    var isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.70)
                Spacer(minLength: 2)
                Text(value, format: .percent.precision(.fractionLength(0)))
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: value))
            }

            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                let fillWidth = max(8, width * min(max(value, 0), 1))

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.055))
                    Capsule()
                        .fill(.linearGradient(
                            colors: [
                                tint.opacity(0.30),
                                tint.opacity(0.74),
                                .white.opacity(isActive ? 0.34 : 0.08)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                        .frame(width: fillWidth)
                        .overlay(alignment: .leading) {
                            if isActive {
                                Capsule()
                                    .fill(.linearGradient(
                                        colors: [
                                            .clear,
                                            .white.opacity(0.42),
                                            .clear
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    ))
                                    .frame(width: min(32, fillWidth))
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .opacity(phase ? 0.95 : 0.46)
                            }
                        }
                }
                .clipShape(Capsule())
            }
            .frame(height: 7)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(isActive ? 0.09 : 0.045), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(tint.opacity(isActive ? 0.18 : 0.08))
        }
    }
}

struct ProjectDetailView: View {
    @Bindable var store: IdeaForgeStore
    var projectID: String
    @State private var ideaBriefShareURL: URL?
    @State private var ideaBriefShareError: String?

    private var project: IdeaProject? {
        store.projects.first { $0.id == projectID }
    }

    private var ambientTint: Color {
        guard let project else { return .indigo }
        switch project.source {
        case .watch: return Color.cyan
        case .iphone: return Color.orange
        case .mac: return Color.indigo
        case .importFile: return Color.mint
        }
    }

    private var isAmbientActive: Bool {
        guard let project else { return false }
        return project.status == .readyForBuild || !project.questions.isEmpty
    }

    var body: some View {
        Group {
            if let project {
                ZStack {
                    MobileAmbientBackdrop(tint: ambientTint, isActive: isAmbientActive)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            MobileProjectHero(project: project)

                            MobileIdeaBriefSharePanel(
                                project: project,
                                shareURL: ideaBriefShareURL,
                                errorMessage: ideaBriefShareError,
                                onPrepare: {
                                    prepareIdeaBrief(for: project)
                                }
                            )

                            MobileTranscriptReviewPanel(
                                project: project,
                                onSaveTranscript: { text in
                                    store.updateTranscriptText(text, projectID: project.id)
                                },
                                onSaveSegment: { segmentID, text, isMarkedImportant in
                                    store.updateTranscriptSegment(
                                        projectID: project.id,
                                        segmentID: segmentID,
                                        text: text,
                                        isMarkedImportant: isMarkedImportant
                                    )
                                }
                            )

                            LiquidGlassPanel(tint: .mint.opacity(0.10), interactive: false) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Label("Artifacts", systemImage: "doc.richtext")
                                        .font(.headline)
                                    if project.artifacts.isEmpty {
                                        Text("No generated artifacts yet.")
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        ForEach(project.artifacts) { artifact in
                                            Label(artifact.title, systemImage: "doc.richtext")
                                        }
                                    }
                                }
                            }

                            LiquidGlassPanel(tint: .indigo.opacity(0.10), interactive: false) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Label("Codex", systemImage: "shippingbox")
                                        .font(.headline)
                                    ForEach(EngineeringPacketBuilder.packet(for: project).files) { file in
                                        Text(file.path)
                                            .font(.body.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .padding()
                        .padding(.bottom, 112)
                    }
                }
                .navigationTitle(project.title)
                .onAppear {
                    prepareIdeaBrief(for: project)
                }
                .onChange(of: project.id) { _, _ in
                    prepareIdeaBrief(for: project)
                }
                .onChange(of: project.updatedAt) { _, _ in
                    prepareIdeaBrief(for: project)
                }
            } else {
                ContentUnavailableView(
                    "Project not found",
                    systemImage: "exclamationmark.magnifyingglass",
                    description: Text("The project may have been deleted or replaced during sync.")
                )
            }
        }
    }

    private func prepareIdeaBrief(for project: IdeaProject) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "IdeaForgeIdeaBriefs", directoryHint: .isDirectory)
        let brief = IdeaBriefExporter.brief(for: project)
        do {
            ideaBriefShareURL = try IdeaBriefFileWriter(rootDirectory: root).write(brief)
            ideaBriefShareError = nil
            IdeaForgeLog.export.info("Prepared iOS idea brief for project \(project.id, privacy: .private)")
        } catch {
            ideaBriefShareURL = nil
            ideaBriefShareError = (error as? UserFacingIdeaForgeError)?.userFacingMessage ?? "Idea brief could not be prepared. Try again before sharing."
            IdeaForgeLog.export.error("iOS idea brief preparation failed for project \(project.id, privacy: .private)")
        }
    }
}

private struct MobileIdeaBriefSharePanel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var project: IdeaProject
    var shareURL: URL?
    var errorMessage: String?
    var onPrepare: () -> Void

    var body: some View {
        let isPrepared = shareURL != nil

        LiquidGlassPanel(tint: .teal.opacity(0.15), interactive: isPrepared, isLive: isPrepared) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    MobileLiveIconBadge(
                        systemImage: "square.and.arrow.up",
                        tint: .teal,
                        isActive: isPrepared && !reduceMotion,
                        size: 38,
                        cornerRadius: 13
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Share Idea Brief")
                            .font(.headline)
                        Text("Export a Markdown brief with summary, questions, assumptions, validation, artifacts, and Codex task names.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)
                }

                MobileStatusRail(tint: .teal, isActive: isPrepared && !reduceMotion)
                    .frame(height: 7)

                HStack(spacing: 10) {
                    if let shareURL {
                        ShareLink(
                            item: shareURL,
                            subject: Text("Idea Brief: \(project.title)"),
                            message: Text("Review this IdeaForge brief before sharing it outside the device.")
                        ) {
                            Label("Share Brief", systemImage: "square.and.arrow.up")
                                .accessibilityIdentifier("ios.project.shareIdeaBrief")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.teal)
                    }

                    Button {
                        onPrepare()
                    } label: {
                        Label(shareURL == nil ? "Prepare Brief" : "Refresh Brief", systemImage: "arrow.clockwise")
                            .accessibilityIdentifier("ios.project.prepareIdeaBrief")
                    }
                    .buttonStyle(.bordered)
                    .tint(.teal)
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("ios.project.ideaBriefError")
                }
            }
        }
        .accessibilityIdentifier("ios.project.ideaBriefPanel")
    }
}

struct MobileTranscriptReviewPanel: View {
    var project: IdeaProject
    var onSaveTranscript: (String) -> Void
    var onSaveSegment: (String, String, Bool) -> Void
    @State private var draftText = ""

    private var trimmedDraft: String {
        draftText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedDraft.isEmpty && trimmedDraft != project.transcript.cleanText
    }

    var body: some View {
        LiquidGlassPanel(tint: .cyan.opacity(0.12), interactive: false) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Transcript Review", systemImage: "text.quote")
                        .font(.headline)
                    Spacer()
                    Button {
                        resetDraft()
                    } label: {
                        Label("Revert", systemImage: "arrow.uturn.backward")
                    }
                    .font(.caption.weight(.semibold))
                    .disabled(draftText == project.transcript.cleanText)
                    .accessibilityIdentifier("ios.project.transcript.revert")

                    Button {
                        onSaveTranscript(draftText)
                    } label: {
                        Label("Save", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .font(.caption.weight(.semibold))
                    .disabled(!canSave)
                    .accessibilityIdentifier("ios.project.transcript.save")
                }

                if !project.transcript.segments.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Segments")
                            .font(.subheadline.weight(.semibold))
                        ForEach(project.transcript.segments) { segment in
                            MobileTranscriptSegmentReviewRow(
                                projectID: project.id,
                                segment: segment,
                                onSaveSegment: onSaveSegment
                            )
                            .accessibilityIdentifier("ios.project.transcript.segment.\(segment.id)")
                        }
                    }
                }

                Text("Clean Transcript")
                    .font(.subheadline.weight(.semibold))

                TextEditor(text: $draftText)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 130)
                    .padding(8)
                    .mobileInputSurface(tint: .cyan, cornerRadius: 16)
                    .accessibilityIdentifier("ios.project.transcript.editor")
            }
        }
        .onAppear(perform: resetDraft)
        .onChange(of: project.id) { _, _ in
            resetDraft()
        }
        .onChange(of: project.transcript.cleanText) { _, newText in
            draftText = newText
        }
    }

    private func resetDraft() {
        draftText = project.transcript.cleanText
    }
}

private struct MobileTranscriptSegmentReviewRow: View {
    var projectID: String
    var segment: TranscriptSegment
    var onSaveSegment: (String, String, Bool) -> Void

    @State private var draftText = ""
    @State private var isMarkedImportant = false

    private var trimmedDraft: String {
        draftText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedDraft.isEmpty && (trimmedDraft != segment.text || isMarkedImportant != segment.isMarkedImportant)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Text(timestamp(segment.startSeconds))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .leading)

                Toggle(isOn: $isMarkedImportant) {
                    Label("Important", systemImage: isMarkedImportant ? "star.fill" : "star")
                }
                .font(.caption.weight(.semibold))
                .accessibilityIdentifier("ios.project.transcript.segmentImportant.\(segment.id)")

                Spacer()
            }

            TextEditor(text: $draftText)
                .font(.callout)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 86)
                .padding(8)
                .mobileInputSurface(tint: isMarkedImportant ? .orange : .cyan, cornerRadius: 14)
                .accessibilityIdentifier("ios.project.transcript.segmentEditor.\(segment.id)")

            HStack {
                Button {
                    resetDraft()
                } label: {
                    Label("Revert", systemImage: "arrow.uturn.backward")
                }
                .font(.caption.weight(.semibold))
                .disabled(draftText == segment.text && isMarkedImportant == segment.isMarkedImportant)
                .accessibilityIdentifier("ios.project.transcript.segmentRevert.\(segment.id)")

                Spacer()

                Button {
                    onSaveSegment(segment.id, draftText, isMarkedImportant)
                } label: {
                    Label("Save Segment", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .font(.caption.weight(.semibold))
                .disabled(!canSave)
                .accessibilityIdentifier("ios.project.transcript.segmentSave.\(segment.id)")
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ios.project.transcript.segment.\(segment.id)")
        .onAppear(perform: resetDraft)
        .onChange(of: segment.id) { _, _ in
            resetDraft()
        }
        .onChange(of: segment.text) { _, newText in
            draftText = newText
        }
        .onChange(of: segment.isMarkedImportant) { _, newValue in
            isMarkedImportant = newValue
        }
    }

    private func timestamp(_ seconds: Int) -> String {
        "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }

    private func resetDraft() {
        draftText = segment.text
        isMarkedImportant = segment.isMarkedImportant
    }
}

struct QuestionsReviewView: View {
    @Bindable var store: IdeaForgeStore

    private var questions: [Question] {
        store.pendingQuestions
    }

    private var hasBlockingQuestions: Bool {
        questions.contains { $0.isBlocking }
    }

    var body: some View {
        ZStack {
            MobileAmbientBackdrop(
                tint: hasBlockingQuestions ? .orange : .teal,
                isActive: hasBlockingQuestions
            )
            ScrollView {
                LazyVStack(spacing: 12) {
                    MobileQuestionsHeader(questions: questions)
                        .dynamicTypeSize(.medium ... .xLarge)

                    ForEach(questions) { question in
                        MobileQuestionAnswerCard(question: question) { answer in
                            store.answerQuestion(question.id, answer: answer)
                        }
                        .dynamicTypeSize(.medium ... .xLarge)
                    }

                    if questions.isEmpty {
                        LiquidGlassPanel(tint: .teal.opacity(0.12), interactive: false) {
                            ContentUnavailableView(
                                "No pending questions",
                                systemImage: "checkmark.seal",
                                description: Text("All idea questions have an answer for now.")
                            )
                        }
                    }
                }
                .padding()
                .padding(.bottom, 112)
            }
            .accessibilityIdentifier("ios.questions.scroll")
        }
        .navigationTitle("Pending Questions")
    }
}

private struct MobileQuestionsHeader: View {
    var questions: [Question]

    private var blockingCount: Int {
        questions.filter(\.isBlocking).count
    }

    private var tint: Color {
        blockingCount > 0 ? .orange : .teal
    }

    var body: some View {
        LiquidGlassPanel(tint: tint.opacity(0.14), interactive: false, isLive: blockingCount > 0) {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .center, spacing: 12) {
                    MobileLiveIconBadge(
                        systemImage: blockingCount > 0 ? "exclamationmark.bubble" : "checkmark.bubble",
                        tint: tint,
                        isActive: blockingCount > 0,
                        size: 38,
                        cornerRadius: 14
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        Text(blockingCount > 0 ? "Questions need answers" : "Questions clear")
                            .font(.headline.weight(.semibold))
                        Text(blockingCount > 0 ? "Answer blockers before build handoff." : "No open blockers are waiting for review.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    MobileSignalGlyph(tint: tint, isActive: blockingCount > 0)
                }

                HStack(spacing: 10) {
                    StatusPill(
                        title: "Pending",
                        value: "\(questions.count)",
                        symbol: "questionmark.bubble",
                        tint: .indigo,
                        isActive: !questions.isEmpty
                    )
                    StatusPill(
                        title: "Required",
                        value: "\(blockingCount)",
                        symbol: "exclamationmark.triangle",
                        tint: .orange,
                        isActive: blockingCount > 0
                    )
                }
            }
        }
        .accessibilityIdentifier("ios.questions.hero")
    }
}

private struct MobileQuestionAnswerCard: View {
    var question: Question
    var onSave: (String) -> Void
    @State private var draftAnswer = ""

    private var tint: Color {
        question.isBlocking ? .orange : .teal
    }

    private var trimmedAnswer: String {
        draftAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        LiquidGlassPanel(
            tint: tint.opacity(question.isBlocking ? 0.12 : 0.10),
            interactive: true,
            isLive: question.isBlocking
        ) {
            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .top, spacing: 11) {
                    Image(systemName: question.isBlocking ? "exclamationmark.circle" : "text.bubble")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(tint)
                        .frame(width: 34, height: 34)
                        .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(alignment: .leading, spacing: 5) {
                        Text(question.prompt)
                            .font(.subheadline.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Label(question.isBlocking ? "Required" : "Optional", systemImage: question.isBlocking ? "exclamationmark.circle" : "text.bubble")
                            .font(.caption)
                            .foregroundStyle(question.isBlocking ? .orange : .secondary)
                    }
                }

                TextField("Answer this question", text: $draftAnswer, axis: .vertical)
                    .lineLimit(2...4)
                    .textInputAutocapitalization(.sentences)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .mobileInputSurface(tint: tint, cornerRadius: 15)
                    .accessibilityIdentifier("ios.question.answer.\(question.id)")

                HStack {
                    Text(trimmedAnswer.isEmpty ? "Add an answer to clear this blocker." : "Ready to save.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button {
                        onSave(trimmedAnswer)
                        draftAnswer = ""
                    } label: {
                        Label("Save", systemImage: "checkmark.circle")
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(tint)
                    .font(.caption.weight(.semibold))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .disabled(trimmedAnswer.isEmpty)
                    .accessibilityIdentifier("ios.question.save.\(question.id)")
                    .accessibilityHint("Save this answer and remove the question from the pending list")
                }
            }
        }
    }
}

struct RecordingQueueRow: View {
    var recording: Recording
    var projectTitle: String

    var body: some View {
        let tint = recording.syncStatus == .failed ? Color.orange : Color.cyan

        LiquidGlassPanel(
            tint: tint.opacity(recording.syncStatus == .failed ? 0.12 : 0.10),
            interactive: false,
            isLive: recording.syncStatus == .failed || recording.syncStatus == .transcribing || recording.syncStatus == .uploaded
        ) {
            HStack(spacing: 12) {
                Image(systemName: recording.deviceName.contains("Watch") ? "applewatch" : "iphone")
                    .font(.headline.weight(.semibold))
                    .frame(width: 34, height: 34)
                    .foregroundStyle(tint)
                    .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(projectTitle)
                        .font(.headline)
                    Text("\(recording.deviceName) - \(recording.durationSeconds)s - \(recording.syncStatus.label) - \(recording.localFileStatus.label)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let diagnostic = recording.processingDiagnostic {
                        Label(recordingDiagnosticText(diagnostic), systemImage: diagnostic.isRetryable ? "arrow.clockwise.circle" : "exclamationmark.triangle")
                            .font(.caption2)
                            .foregroundStyle(diagnostic.isRetryable ? .orange : .red)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("ios.recordingQueue.failureDiagnostic.\(recording.id)")
                    }
                }
                Spacer()
            }
            MobileStatusRail(tint: tint, isActive: recording.syncStatus == .failed || recording.syncStatus == .transcribing || recording.syncStatus == .uploaded)
                .frame(height: 7)
                .padding(.top, 6)
        }
        .accessibilityElement(children: .contain)
    }

    private func recordingDiagnosticText(_ diagnostic: RecordingProcessingDiagnostic) -> String {
        diagnostic.isRetryable ? "\(diagnostic.message) Retry available." : diagnostic.message
    }
}

struct StatusPill: View {
    var title: String
    var value: String
    var symbol: String
    var tint: Color = .cyan
    var isActive = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
            Text(value)
                .font(.title3.monospacedDigit().weight(.semibold))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .topLeading) {
            MobileGlassSheen(tint: tint, cornerRadius: 16)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(tint.opacity(0.16))
        }
        .overlay(alignment: .bottomLeading) {
            MobileStatusRail(tint: tint, isActive: isActive)
                .frame(height: 5)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
        }
        .shadow(color: tint.opacity(isActive ? 0.12 : 0.06), radius: isActive ? 10 : 6, y: isActive ? 5 : 3)
    }
}

struct LiveHealthFormRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var snapshot: MobileDashboardSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            MobileLiveIconBadge(
                systemImage: snapshot.liveHealthTone.symbolName,
                tint: snapshot.liveHealthTone.mobileTint,
                isActive: snapshot.isLiveActivityActive && !reduceMotion,
                size: 34,
                cornerRadius: 12
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot.liveHealthTitle)
                    .font(.headline)
                Text(snapshot.liveHealthDetail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                MobileLiveFlowRibbon(
                    tint: snapshot.liveHealthTone.mobileTint,
                    isActive: snapshot.isLiveActivityActive && !reduceMotion
                )
                .frame(height: 14)
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(snapshot.liveHealthTitle). \(snapshot.liveHealthDetail)")
    }
}

extension WorkspaceLiveHealthTone {
    var symbolName: String {
        switch self {
        case .ready: "checkmark.seal"
        case .active: "dot.radiowaves.left.and.right"
        case .needsReview: "exclamationmark.triangle"
        case .syncConflict: "arrow.triangle.2.circlepath.circle"
        case .offline: "applewatch.slash"
        case .localFirst: "lock.shield"
        }
    }

    var mobileTint: Color {
        switch self {
        case .ready: .mint
        case .active: .cyan
        case .needsReview: .orange
        case .syncConflict: .red
        case .offline: .secondary
        case .localFirst: .indigo
        }
    }
}

struct MobileAmbientBackdrop: View {
    var tint: Color
    var isActive: Bool

    var body: some View {
        GeometryReader { proxy in
            LinearGradient(
                colors: [
                    Color(uiColor: .systemBackground),
                    tint.opacity(isActive ? 0.12 : 0.07),
                    Color.indigo.opacity(isActive ? 0.08 : 0.04),
                    Color(uiColor: .secondarySystemBackground)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .overlay(alignment: .topLeading) {
                Rectangle()
                    .fill(.linearGradient(
                        colors: [
                            .white.opacity(0.18),
                            .clear,
                            tint.opacity(0.12)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(maxWidth: .infinity)
                    .rotationEffect(.degrees(-11))
                    .blur(radius: 18)
                    .opacity(isActive ? 0.28 : 0.20)
            }
            .ignoresSafeArea()
        }
        .accessibilityHidden(true)
    }
}

struct MobileLiveFlowRibbon: View {
    var tint: Color
    var isActive: Bool

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.linearGradient(
                        colors: [
                            tint.opacity(0.11),
                            Color.primary.opacity(0.035),
                            tint.opacity(0.17)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .overlay {
                        Capsule().strokeBorder(tint.opacity(0.18))
                    }

                Capsule()
                    .fill(.linearGradient(
                        colors: [
                            .white.opacity(0),
                            tint.opacity(isActive ? 0.50 : 0.22),
                            .white.opacity(0)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .frame(width: min(96, width * 0.50))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .blur(radius: isActive ? 3 : 2)
                    .opacity(isActive ? 0.78 : 0.50)
            }
            .clipShape(Capsule())
        }
        .accessibilityHidden(true)
    }
}

struct MobileStatusRail: View {
    var tint: Color
    var isActive: Bool

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let active = isActive

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.linearGradient(
                        colors: [
                            tint.opacity(0.12),
                            Color.primary.opacity(0.035),
                            tint.opacity(0.18)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .overlay {
                        Capsule().strokeBorder(tint.opacity(active ? 0.24 : 0.14))
                    }

                Capsule()
                    .fill(.linearGradient(
                        colors: [
                            .clear,
                            tint.opacity(active ? 0.64 : 0.22),
                            .white.opacity(active ? 0.42 : 0.12),
                            .clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .frame(width: min(76, width * 0.56))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .opacity(active ? 0.78 : 0.50)
            }
            .clipShape(Capsule())
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct MobileSignalField: View {
    var tint: Color
    var isActive: Bool

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let active = isActive

            ZStack(alignment: .leading) {
                ForEach(0..<4, id: \.self) { index in
                    Capsule()
                        .fill(.linearGradient(
                            colors: [
                                .clear,
                                tint.opacity(active ? 0.48 : 0.20),
                                .white.opacity(active ? 0.24 : 0.10),
                                .clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                        .frame(width: width * (0.34 + CGFloat(index) * 0.06), height: 2)
                        .offset(
                            x: width * (0.12 + CGFloat(index) * 0.17),
                            y: CGFloat(index) * 9 + 5
                        )
                        .opacity((active ? 0.78 : 0.60) - Double(index) * 0.10)
                }

                ForEach(0..<5, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(tint.opacity(active ? 0.34 : 0.16))
                        .frame(width: 5, height: 10 + CGFloat((index % 3) * 5))
                        .offset(
                            x: width * CGFloat(index + 1) / 6,
                            y: CGFloat((index % 2) * 6 + 6)
                        )
                        .opacity(active ? 0.72 : 0.56)
                }
            }
            .frame(width: width, height: proxy.size.height, alignment: .leading)
            .background(tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(tint.opacity(active ? 0.20 : 0.12))
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct LiquidGlassPanel<Content: View>: View {
    var tint: Color = .clear
    var interactive: Bool = false
    var isLive: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                GlassEffectContainer(spacing: 18) {
                    content()
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassEffect(.regular.tint(tint).interactive(interactive), in: .rect(cornerRadius: 20))
                        .overlay {
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .strokeBorder(tint.opacity(isLive ? 0.24 : 0.12))
                        }
                        .shadow(color: tint.opacity(interactive ? 0.12 : 0.06), radius: interactive ? 10 : 6, y: 4)
                }
            } else {
                content()
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(tint.opacity(isLive ? 0.24 : 0.12))
                    }
                    .shadow(color: tint.opacity(interactive ? 0.12 : 0.06), radius: interactive ? 10 : 6, y: 4)
            }
        }
    }
}

private struct MobileGlassSheen: View {
    var tint: Color
    var cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.linearGradient(
                colors: [
                    .white.opacity(0.20),
                    tint.opacity(0.08),
                    .clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct MobileInputSurface: ViewModifier {
    var tint: Color
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(alignment: .topLeading) {
                MobileGlassSheen(tint: tint, cornerRadius: cornerRadius)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(tint.opacity(0.16))
            }
    }
}

private extension View {
    func mobileInputSurface(tint: Color, cornerRadius: CGFloat) -> some View {
        modifier(MobileInputSurface(tint: tint, cornerRadius: cornerRadius))
    }

    func mobileConflictDraftHitTarget(multiline: Bool = false) -> some View {
        frame(maxWidth: .infinity, minHeight: multiline ? 48 : 36, alignment: .leading)
    }
}

struct MobileCardButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var tint: Color = .accentColor
    var isLive = false

    func makeBody(configuration: Configuration) -> some View {
        let active = (configuration.isPressed || isLive) && !reduceMotion

        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.978 : (isLive && !reduceMotion ? 1.004 : 1))
            .brightness(configuration.isPressed ? -0.025 : 0)
            .shadow(color: tint.opacity(active ? 0.14 : 0.03), radius: active ? 12 : 3, y: active ? 6 : 2)
    }
}

struct MobileSignalGlyph: View {
    var tint: Color
    var isActive: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(tint.gradient)
                    .frame(width: 4, height: height(for: index))
                    .opacity(isActive ? 0.95 : 0.45)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(tint.opacity(0.12), in: Capsule())
        .overlay {
            Capsule().strokeBorder(tint.opacity(0.20))
        }
        .accessibilityHidden(true)
    }

    private func height(for index: Int) -> CGFloat {
        let heights = isActive ? [16, 9, 19, 11] : [8, 14, 10, 17]
        return CGFloat(heights[index])
    }
}

struct MobileLiveIconBadge: View {
    var systemImage: String
    var tint: Color
    var isActive: Bool
    var size: CGFloat
    var cornerRadius: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.linearGradient(
                    colors: [
                        tint.opacity(isActive ? 0.20 : 0.11),
                        Color.primary.opacity(0.035),
                        tint.opacity(isActive ? 0.11 : 0.06)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(tint.opacity(isActive ? 0.36 : 0.16), lineWidth: 1)

            Image(systemName: systemImage)
                .font(.system(size: size * 0.50, weight: .semibold))
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
        }
        .frame(width: size, height: size)
        .shadow(color: tint.opacity(isActive ? 0.14 : 0.06), radius: isActive ? 8 : 4, y: isActive ? 4 : 2)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension IdeaProject {
    var mobileTint: Color {
        switch source {
        case .watch: .cyan
        case .iphone: .orange
        case .mac: .indigo
        case .importFile: .mint
        }
    }

    var mobileSymbol: String {
        switch source {
        case .watch: "applewatch.radiowaves.left.and.right"
        case .iphone: "iphone.radiowaves.left.and.right"
        case .mac: "desktopcomputer"
        case .importFile: "doc.badge.plus"
        }
    }

    var isMobileLive: Bool {
        status == .readyForBuild || !questions.isEmpty || recordings.contains { recording in
            recording.syncStatus == .failed || recording.syncStatus == .transcribing || recording.syncStatus == .uploaded
        }
    }
}

struct LiquidGlassToolbarButton: View {
    var title: String
    var systemImage: String
    var accessibilityIdentifier: String?
    var accessibilityHint: String?
    var action: () -> Void

    var body: some View {
        if #available(iOS 26.0, *) {
            Button(action: action) {
                Label(title, systemImage: systemImage)
            }
            .buttonStyle(.glassProminent)
            .accessibilityLabel(title)
            .accessibilityIdentifier(accessibilityIdentifier ?? title)
            .accessibilityHint(accessibilityHint ?? "")
        } else {
            Button(action: action) {
                Label(title, systemImage: systemImage)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel(title)
            .accessibilityIdentifier(accessibilityIdentifier ?? title)
            .accessibilityHint(accessibilityHint ?? "")
        }
    }
}

private struct UploadDiagnosticRow: View {
    var context: AccountUploadDiagnosticContext
    var onRetry: () -> Void

    var body: some View {
        let retainedAudio = IdeaForgeStore.retainedAudioValidation(
            job: context.job,
            recording: context.recording
        )

        VStack(alignment: .leading, spacing: 8) {
            Text(context.projectTitle)
                .font(.headline)
            LabeledContent("Source", value: context.recording.deviceName)
            LabeledContent("Status", value: context.job.status.label)
            if context.job.status == .permanentlyFailed {
                LabeledContent("Reason", value: failureCategory.label)
            }
            LabeledContent("Retained audio", value: retainedAudio.label)

            if context.job.status == .permanentlyFailed {
                if retainedAudio.isRetryEligible {
                    Button(action: onRetry) {
                        Label("Retry upload", systemImage: "arrow.clockwise")
                            .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("ios.account.retryUpload.\(context.recording.id)")
                    .accessibilityHint("Queues the retained recording without replacing its audio")
                } else {
                    Text(retryUnavailableMessage(for: retainedAudio))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary(retainedAudio: retainedAudio))
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var failureCategory: UploadFailureCategory {
        context.job.failureCategory ?? .uploadError
    }

    private var accessibilityIdentifier: String {
        let kind = context.job.status == .permanentlyFailed ? "failedUpload" : "uploadJob"
        return "ios.account.\(kind).\(context.recording.id)"
    }

    private func accessibilitySummary(retainedAudio: RetainedAudioValidation) -> String {
        var fields = [
            context.projectTitle,
            "Source \(context.recording.deviceName)",
            "Status \(context.job.status.label)"
        ]
        if context.job.status == .permanentlyFailed {
            fields.append("Reason \(failureCategory.label)")
        }
        fields.append("Retained audio \(retainedAudio.label.lowercased())")
        return fields.joined(separator: ". ") + "."
    }

    private func retryUnavailableMessage(for retainedAudio: RetainedAudioValidation) -> String {
        switch retainedAudio {
        case .available:
            "Retry is unavailable for this upload state."
        case .unavailable:
            "Retry is unavailable because retained audio is missing."
        case .invalid:
            "Retry is unavailable because retained audio is not a valid regular file."
        case .mismatched:
            "Retry is unavailable because retained audio does not match this upload."
        }
    }
}

struct AccountHubView: View {
    @Bindable var store: IdeaForgeStore
    @Binding var requestedDestination: AccountDestination?
    var snapshot: MobileDashboardSnapshot
    var syncReadiness: MobileSyncReadinessSnapshot
    var syncPlan: MobileWorkspaceSyncPlanSnapshot
    var syncTrust: MobileSyncTrustSnapshot
    @Binding var backendSettings: BackendConnectionSettings
    @Binding var backendTokenEntry: String
    var backendStatusMessage: String
    var localSpeechStatusMessage: String
    var authenticatedSession: BackendAuthenticatedSession?
    var authStatusMessage: String
    var accountUsageSummary: BackendAccountUsageSummary?
    var accountStatusMessage: String
    var storeKitProducts: [CommerceProduct]
    var activeCommerceProductIDs: [String]
    var commerceStatusMessage: String
    var pushNotificationStatusMessage: String
    var isProcessingUploads: Bool
    var isSyncingWorkspace: Bool
    var isProcessingAI: Bool
    var isProcessingLocalSpeech: Bool
    var isValidatingAuthSession: Bool
    var isRefreshingAccountUsage: Bool
    var isLoadingCommerce: Bool
    var isPurchasingCommerce: Bool
    var isRestoringCommerce: Bool
    var isRegisteringPushNotifications: Bool
    var onSaveBackend: () -> Void
    var onClearBackendCredentials: () -> Void
    var onSyncWorkspace: () -> Void
    var onRefreshWorkspace: () -> Void
    var onResolveSyncConflict: (WorkspaceSyncConflictMergeSelection) -> Void
    var onValidateSession: () -> Void
    var onProcessAI: () -> Void
    var onProcessLocalSpeech: () -> Void
    var onRefreshAccountUsage: () -> Void
    var onRefreshCommerce: () -> Void
    var onPurchaseProduct: (String) -> Void
    var onRestorePurchases: () -> Void
    var onManageSubscription: () -> Void
    var onRequestAccountDeletion: () -> Void
    var onRegisterPushNotifications: () -> Void
    var onProcessUploads: () -> Void
    var onRetryUpload: (String) -> Void
    @State private var selectedSyncConflictReviewItemIDs = Set<String>()
    @State private var syncConflictCustomMergeValuesByItemID = [String: String]()
    @State private var syncConflictItemPrimaryValuesByItemID = [String: String]()
    @State private var syncConflictItemSecondaryValuesByItemID = [String: String]()
    @State private var syncConflictItemTertiaryValuesByItemID = [String: String]()
    @State private var syncConflictItemFlagValuesByItemID = [String: Bool]()
    @State private var syncConflictItemNumericValuesByItemID = [String: Double]()

    var body: some View {
        let uploadDiagnostics = AccountUploadDiagnosticsSnapshot(
            projects: store.projects,
            uploadJobs: store.uploadJobs
        )

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
            MobileAccountStatusHero(
                snapshot: snapshot,
                status: accountCommandStatus,
                isActive: accountSurfaceIsActive,
                isRemoteEnabled: backendSettings.isEnabled,
                privacyMode: store.privacyMode
            )
            .dynamicTypeSize(.medium ... .xLarge)

            MobileAccountSection("Live Workspace") {
                MobileDeviceSyncPanel(
                    snapshot: snapshot,
                    readiness: syncReadiness,
                    syncPlan: syncPlan,
                    syncTrust: syncTrust,
                    syncHealth: store.syncHealth,
                    backendStatusMessage: backendStatusMessage,
                    isSyncingWorkspace: isSyncingWorkspace,
                    isProcessingUploads: false,
                    isProcessingAI: isProcessingAI || isProcessingLocalSpeech,
                    primaryActionTitle: isSyncingWorkspace ? "Publishing" : "Publish Workspace",
                    primaryActionSystemImage: "arrow.triangle.2.circlepath",
                    primaryAccessibilityIdentifier: "ios.account.syncOverview.syncWorkspace",
                    primaryAccessibilityHint: isSyncingWorkspace ? "Workspace sync is already running" : "Publish the local workspace snapshot to the configured backend",
                    onPrimaryAction: onSyncWorkspace,
                    wholePanelPrimaryAction: false,
                    compactLayout: true,
                    showsRoute: true,
                    showsMetrics: false,
                    secondaryActionTitle: isSyncingWorkspace ? "Refreshing" : "Refresh from Backend",
                    secondaryActionSystemImage: "arrow.down.circle",
                    secondaryAccessibilityIdentifier: "ios.account.syncOverview.secondary",
                    secondaryAccessibilityHint: isSyncingWorkspace ? "Workspace sync is already running" : "Pull the latest backend workspace snapshot onto this iPhone",
                    onSecondaryAction: onRefreshWorkspace
                )
                MobileSyncHandoffStatusStrip(
                    plan: syncPlan,
                    tint: syncPlan.tone.mobileTint,
                    isActive: isSyncingWorkspace
                )
                LiveHealthFormRow(snapshot: snapshot)
            }
            MobileAccountSection("Actions") {
                let billingReadiness = commerceReadiness
                let purchaseProductID = preferredPurchaseProductID
                AccountCommandDeck(
                    isActive: isSyncingWorkspace || isProcessingAI || isProcessingLocalSpeech || isValidatingAuthSession || isRefreshingAccountUsage || isPurchasingCommerce || isRestoringCommerce || isRegisteringPushNotifications,
                    primaryStatus: accountCommandStatus,
                    commands: [
                        AccountCommand(
                            title: purchaseActionTitle,
                            detail: preferredPurchaseProductID == nil ? "Store unavailable" : billingReadiness.planLabel,
                            systemImage: purchaseActionSystemImage,
                            tint: .mint,
                            isDisabled: purchaseProductID == nil || !billingReadiness.canPurchase || isPurchasingCommerce,
                            accessibilityIdentifier: "ios.account.purchasePro",
                            accessibilityHint: purchaseActionHint(readiness: billingReadiness),
                            action: {
                                if let purchaseProductID {
                                    onPurchaseProduct(purchaseProductID)
                                }
                            }
                        ),
                        AccountCommand(
                            title: isRestoringCommerce ? "Restoring" : "Restore Purchases",
                            detail: billingReadiness.blockerSummary(for: billingReadiness.restoreBlockers),
                            systemImage: "arrow.clockwise.circle",
                            tint: .cyan,
                            isDisabled: !billingReadiness.canRestore || isRestoringCommerce,
                            accessibilityIdentifier: "ios.account.restorePurchases",
                            accessibilityHint: billingReadiness.blockerSummary(for: billingReadiness.restoreBlockers),
                            action: onRestorePurchases
                        ),
                        AccountCommand(
                            title: isRefreshingAccountUsage ? "Refreshing Usage" : "Refresh Usage",
                            detail: accountStatusMessage,
                            systemImage: "chart.bar.doc.horizontal",
                            tint: .teal,
                            isDisabled: isRefreshingAccountUsage,
                            accessibilityIdentifier: "ios.account.refreshUsage",
                            accessibilityHint: isRefreshingAccountUsage ? "Backend account usage refresh is already running" : "Fetch the account plan and workspace usage summary from the configured backend",
                            action: onRefreshAccountUsage
                        ),
                        AccountCommand(
                            title: isValidatingAuthSession ? "Validating Session" : "Validate Session",
                            detail: authStatusMessage,
                            systemImage: "person.badge.key",
                            tint: .orange,
                            isDisabled: isValidatingAuthSession,
                            accessibilityIdentifier: "ios.account.validateSession",
                            accessibilityHint: isValidatingAuthSession ? "Backend session validation is already running" : "Validate the saved bearer token and workspace against the backend",
                            action: onValidateSession
                        ),
                        AccountCommand(
                            title: isProcessingLocalSpeech ? "Transcribing Local" : "Local Speech",
                            detail: localSpeechStatusMessage,
                            systemImage: "waveform",
                            tint: .mint,
                            isDisabled: isProcessingLocalSpeech,
                            accessibilityIdentifier: "ios.account.processLocalSpeech",
                            accessibilityHint: isProcessingLocalSpeech ? "Local speech transcription is already running" : "Transcribe locally available iPhone and Watch recordings on this device",
                            action: onProcessLocalSpeech
                        ),
                        AccountCommand(
                            title: isRegisteringPushNotifications ? "Registering Push" : "Register Push",
                            detail: pushNotificationStatusMessage,
                            systemImage: "bell.badge",
                            tint: .purple,
                            isDisabled: isRegisteringPushNotifications,
                            accessibilityIdentifier: "ios.account.registerPush",
                            accessibilityHint: isRegisteringPushNotifications ? "Push sync registration is already running" : "Register this iPhone for backend push sync notifications",
                            action: onRegisterPushNotifications
                        )
                    ]
                )
                AccountReadinessSummaryRow(
                    title: "Manage Subscription",
                    detail: billingReadiness.blockerSummary(for: billingReadiness.manageSubscriptionBlockers),
                    systemImage: "creditcard",
                    tint: .blue,
                    accessibilityIdentifier: "ios.account.manageSubscription.detail"
                )
                AccountReadinessSummaryRow(
                    title: "Delete Account",
                    detail: billingReadiness.blockerSummary(for: billingReadiness.accountDeletionBlockers),
                    systemImage: "person.crop.circle.badge.xmark",
                    tint: .red,
                    accessibilityIdentifier: "ios.account.deleteAccount.detail"
                )
            }
            MobileAccountSection("Privacy") {
                Picker("Mode", selection: privacyModeBinding) {
                    ForEach(PrivacyMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Text(store.privacyMode.description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            MobileAccountSection("Subscription") {
                let billingReadiness = commerceReadiness
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
                LabeledContent("Billing status", value: billingReadiness.planLabel)
                Text(commerceStatusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if storeKitProducts.isEmpty {
                    CommerceActionReadinessRow(
                        title: isLoadingCommerce ? "Loading Products" : "Purchase Pro",
                        systemImage: "cart.badge.plus",
                        isEnabled: false,
                        blockerSummary: billingReadiness.blockerSummary(for: billingReadiness.purchaseBlockers),
                        accessibilityIdentifier: "ios.account.purchasePro.detail"
                    )
                } else {
                    ForEach(storeKitProducts) { product in
                        CommerceProductPurchaseRow(
                            product: product,
                            isActive: activeCommerceProductIDs.contains(product.id),
                            isEnabled: billingReadiness.canPurchase && !isPurchasingCommerce,
                            blockerSummary: billingReadiness.blockerSummary(for: billingReadiness.purchaseBlockers),
                            accessibilityIdentifier: "ios.account.purchase.\(product.id).detail",
                            action: {
                                onPurchaseProduct(product.id)
                            }
                        )
                    }
                }
                CommerceActionReadinessRow(
                    title: "Restore Purchases",
                    systemImage: "arrow.clockwise.circle",
                    isEnabled: billingReadiness.canRestore && !isRestoringCommerce,
                    blockerSummary: billingReadiness.blockerSummary(for: billingReadiness.restoreBlockers),
                    accessibilityIdentifier: "ios.account.restorePurchases.detail",
                    action: onRestorePurchases
                )
                CommerceActionReadinessRow(
                    title: "Manage Subscription",
                    systemImage: "creditcard",
                    isEnabled: billingReadiness.canManageSubscription,
                    blockerSummary: billingReadiness.blockerSummary(for: billingReadiness.manageSubscriptionBlockers),
                    accessibilityIdentifier: "ios.account.manageSubscription.row",
                    action: onManageSubscription
                )
                CommerceActionReadinessRow(
                    title: "Delete Account",
                    systemImage: "person.crop.circle.badge.xmark",
                    isEnabled: billingReadiness.canRequestAccountDeletion,
                    blockerSummary: billingReadiness.blockerSummary(for: billingReadiness.accountDeletionBlockers),
                    accessibilityIdentifier: "ios.account.deleteAccount.row",
                    role: .destructive,
                    action: onRequestAccountDeletion
                )
                Button(action: onRefreshCommerce) {
                    Label(isLoadingCommerce ? "Loading StoreKit" : "Reload StoreKit", systemImage: "bag.badge.plus")
                }
                .accessibilityIdentifier("ios.account.reloadStoreKit")
                .disabled(isLoadingCommerce)
                Button(action: onRefreshAccountUsage) {
                    Label(isRefreshingAccountUsage ? "Refreshing" : "Refresh Usage", systemImage: "chart.bar.doc.horizontal")
                }
                .accessibilityIdentifier("ios.account.refreshUsage.detail")
                .disabled(isRefreshingAccountUsage)
            }
            MobileAccountSection("Upload Diagnostics") {
                if uploadDiagnostics.uploadContexts.isEmpty && uploadDiagnostics.recordingContexts.isEmpty {
                    Text("No upload or recording diagnostics need review.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("ios.account.failedUploads.empty")
                } else {
                    ForEach(uploadDiagnostics.uploadContexts) { context in
                        UploadDiagnosticRow(
                            context: context,
                            onRetry: {
                                onRetryUpload(context.recording.id)
                            }
                        )
                    }

                    ForEach(uploadDiagnostics.recordingContexts) { context in
                        RecordingQueueRow(
                            recording: context.recording,
                            projectTitle: context.projectTitle
                        )
                        .accessibilityIdentifier("ios.account.recordingDiagnostic.\(context.id)")
                    }
                }

                if !store.activeUploadJobs.isEmpty {
                    Button(action: onProcessUploads) {
                        Label(isProcessingUploads ? "Uploading" : "Process upload queue", systemImage: "icloud.and.arrow.up")
                            .frame(minHeight: 44)
                    }
                    .disabled(isProcessingUploads)
                    .accessibilityIdentifier("ios.account.processUploads")
                    .accessibilityHint(isProcessingUploads ? "Upload processing is already running" : "Process recordings currently due for upload")
                }
            }
            .id(AccountDestination.failedUploads)

            MobileAccountSection("Backend Upload") {
                if let conflict = store.syncHealth.syncConflictStatus {
                    MobileSyncConflictReviewPanel(
                        conflict: conflict,
                        selectedReviewItemIDs: $selectedSyncConflictReviewItemIDs,
                        customMergeValuesByItemID: $syncConflictCustomMergeValuesByItemID,
                        itemPrimaryValuesByItemID: $syncConflictItemPrimaryValuesByItemID,
                        itemSecondaryValuesByItemID: $syncConflictItemSecondaryValuesByItemID,
                        itemTertiaryValuesByItemID: $syncConflictItemTertiaryValuesByItemID,
                        itemFlagValuesByItemID: $syncConflictItemFlagValuesByItemID,
                        itemNumericValuesByItemID: $syncConflictItemNumericValuesByItemID
                    )
                }
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Remote upload")
                            .font(.body)
                        Text("Enable backend upload, sync, and AI routes for this workspace.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Toggle("Remote upload", isOn: $backendSettings.isEnabled)
                        .labelsHidden()
                        .accessibilityIdentifier("ios.account.remoteUpload")
                        .accessibilityLabel("Remote upload")
                        .accessibilityHint("Enable backend upload, sync, and AI routes for this workspace")
                }
                TextField("https://api.example.com", text: $backendSettings.baseURLString)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Workspace ID", text: $backendSettings.workspaceID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("ios.account.backendWorkspaceID")
                TextField("/v1/auth/session", text: $backendSettings.authSessionPath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("ios.account.backendAuthSessionPath")
                TextField("/v1/workspace/snapshot", text: $backendSettings.syncPath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("/v1/devices/apns", text: $backendSettings.pushRegistrationPath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("ios.account.backendPushRegistrationPath")
                TextField("/v1/admin/metrics", text: $backendSettings.operationsMetricsPath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("ios.account.backendOperationsMetricsPath")
                SecureField("Bearer token", text: $backendTokenEntry)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Text(backendStatusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                BackendCommandDeck(
                    isActive: isSyncingWorkspace || isProcessingAI || isValidatingAuthSession || store.syncHealth.syncConflictStatus != nil,
                    commands: backendCommands
                )
                if isSyncingWorkspace || isProcessingAI {
                    Text("Wait for the current backend operation to finish before starting another.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text("Advanced route paths")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("/v1/recordings/upload", text: $backendSettings.uploadPath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("/v1/objects/metadata", text: $backendSettings.objectMetadataPath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("/v1/ai/transcriptions", text: $backendSettings.transcriptionPath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("/v1/ai/transcription-jobs", text: $backendSettings.transcriptionJobStatusPath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("/v1/ai/workflows/run", text: $backendSettings.workflowPath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("/v1/ai/workflow-jobs", text: $backendSettings.workflowJobStatusPath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("ios.account.backendWorkflowJobStatusPath")
                TextField("/v1/usage/summary", text: $backendSettings.usagePath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("/v1/billing/app-store/reconcile", text: $backendSettings.billingReconciliationPath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("ios.account.backendBillingPath")
                TextField("/v1/admin/status", text: $backendSettings.operationsStatusPath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("ios.account.backendOperationsStatusPath")
                TextField("/v1/admin/backup-manifest", text: $backendSettings.backupManifestPath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("ios.account.backendBackupManifestPath")
                TextField("/v1/admin/restore-drill", text: $backendSettings.restoreDrillPath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("ios.account.backendRestoreDrillPath")
            }
            .id(AccountDestination.syncConflict)
            MobileAccountSection("Integrations") {
                Label("GitHub export", systemImage: "checkmark.seal")
                Label("Codex packet export", systemImage: "shippingbox")
            }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
            .accessibilityIdentifier("ios.account.scroll")
            .onAppear {
                scrollToRequestedDestination(using: proxy)
            }
            .onChange(of: requestedDestination) { _, _ in
                scrollToRequestedDestination(using: proxy)
            }
        }
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background {
            MobileAmbientBackdrop(tint: .teal, isActive: accountSurfaceIsActive)
        }
        .safeAreaInset(edge: .bottom) {
            Color.clear
                .frame(height: 112)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func scrollToRequestedDestination(using proxy: ScrollViewProxy) {
        guard let requestedDestination else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(requestedDestination, anchor: .top)
            self.requestedDestination = nil
        }
    }

    private var privacyModeBinding: Binding<PrivacyMode> {
        Binding(
            get: { store.privacyMode },
            set: { store.setPrivacyMode($0) }
        )
    }

    private var commerceReadiness: CommerceReadiness {
        CommerceReadiness.evaluate(
            accountUsageSummary: accountUsageSummary,
            storeKitProducts: storeKitProducts,
            activeProductIDs: activeCommerceProductIDs,
            accountPortalURL: accountUsageSummary?.accountPortalURL,
            accountDeletionURL: accountUsageSummary?.accountDeletionURL,
            canOpenSubscriptionManagement: true
        )
    }

    private var preferredPurchaseProductID: String? {
        if storeKitProducts.contains(where: { $0.id == CommerceProductID.proMonthly }) {
            return CommerceProductID.proMonthly
        }
        return storeKitProducts.first?.id
    }

    private var purchaseActionTitle: String {
        if isLoadingCommerce {
            return "Loading Products"
        }
        if let preferredPurchaseProductID, activeCommerceProductIDs.contains(preferredPurchaseProductID) {
            return "Pro Active"
        }
        return "Purchase Pro"
    }

    private var purchaseActionSystemImage: String {
        if let preferredPurchaseProductID, activeCommerceProductIDs.contains(preferredPurchaseProductID) {
            return "checkmark.seal"
        }
        return "cart.badge.plus"
    }

    private func purchaseActionHint(readiness: CommerceReadiness) -> String {
        if preferredPurchaseProductID == nil {
            return "App Store products are not loaded"
        }
        return readiness.blockerSummary(for: readiness.purchaseBlockers)
    }

    private var accountCommandStatus: String {
        if store.syncHealth.syncConflictStatus != nil { return "Sync conflict needs review." }
        if isPurchasingCommerce { return "Purchasing subscription." }
        if isRestoringCommerce { return "Restoring purchases." }
        if isRefreshingAccountUsage { return "Refreshing usage." }
        if isRegisteringPushNotifications { return "Registering push sync." }
        if isValidatingAuthSession { return "Validating backend session." }
        if isSyncingWorkspace { return "Syncing workspace." }
        if isProcessingAI { return "Processing backend AI." }
        if isProcessingLocalSpeech { return "Processing local speech." }
        return "Account and backend controls are ready."
    }

    private var accountSurfaceIsActive: Bool {
        isSyncingWorkspace
            || isProcessingAI
            || isProcessingLocalSpeech
            || isValidatingAuthSession
            || isRefreshingAccountUsage
            || isLoadingCommerce
            || isPurchasingCommerce
            || isRestoringCommerce
            || isRegisteringPushNotifications
            || store.syncHealth.syncConflictStatus != nil
    }

    private var backendCommands: [AccountCommand] {
        var commands = [
            AccountCommand(
                title: "Save",
                detail: "Store backend paths",
                systemImage: "externaldrive.badge.checkmark",
                tint: .cyan,
                isDisabled: false,
                accessibilityIdentifier: "ios.account.saveBackend",
                accessibilityHint: "Save backend paths and store the token in Keychain",
                action: onSaveBackend
            ),
            AccountCommand(
                title: isSyncingWorkspace ? "Publishing" : "Publish Workspace",
                detail: backendStatusMessage,
                systemImage: "arrow.triangle.2.circlepath",
                tint: .indigo,
                isDisabled: isSyncingWorkspace,
                accessibilityIdentifier: "ios.account.syncWorkspace",
                accessibilityHint: isSyncingWorkspace ? "Workspace sync is already running" : "Publish the local workspace snapshot to the configured backend",
                action: onSyncWorkspace
            ),
            AccountCommand(
                title: isSyncingWorkspace ? "Refreshing" : "Refresh Workspace",
                detail: "Pull newer backend or Mac changes",
                systemImage: "arrow.down.circle",
                tint: .teal,
                isDisabled: isSyncingWorkspace,
                accessibilityIdentifier: "ios.account.refreshWorkspace",
                accessibilityHint: isSyncingWorkspace ? "Workspace sync is already running" : "Pull the latest backend workspace snapshot onto this iPhone without overwriting local recordings silently",
                action: onRefreshWorkspace
            )
        ]

        if let conflict = store.syncHealth.syncConflictStatus {
            commands.append(
                AccountCommand(
                    title: conflict.reviewItems.isEmpty ? "Merge Local Work" : "Merge Choices",
                    detail: conflict.recoveryAction,
                    systemImage: "arrow.triangle.2.circlepath.circle",
                    tint: .red,
                    isDisabled: isSyncingWorkspace,
                    accessibilityIdentifier: "ios.account.resolveSyncConflict",
                    accessibilityHint: "Re-fetch backend state and apply the reviewed local-item choices before accepting the remote snapshot",
                    action: {
                        onResolveSyncConflict(reviewedMergeSelection(for: conflict))
                    }
                )
            )
        }

        commands.append(contentsOf: [
            AccountCommand(
                title: isValidatingAuthSession ? "Validating" : "Validate Session",
                detail: authStatusMessage,
                systemImage: "person.badge.key",
                tint: .orange,
                isDisabled: isValidatingAuthSession,
                accessibilityIdentifier: "ios.account.validateSession.detail",
                accessibilityHint: isValidatingAuthSession ? "Backend session validation is already running" : "Validate the saved bearer token and workspace against the backend",
                action: onValidateSession
            ),
            AccountCommand(
                title: isProcessingAI ? "Processing" : "Process AI",
                detail: "Transcribe and run workflows",
                systemImage: "sparkles",
                tint: .indigo,
                isDisabled: isProcessingAI,
                accessibilityIdentifier: "ios.account.processAI",
                accessibilityHint: isProcessingAI ? "Backend AI processing is already running" : "Process uploaded recordings with backend AI when configured",
                action: onProcessAI
            ),
            AccountCommand(
                title: isRegisteringPushNotifications ? "Registering Push" : "Register Push",
                detail: pushNotificationStatusMessage,
                systemImage: "bell.badge",
                tint: .purple,
                isDisabled: isRegisteringPushNotifications,
                accessibilityIdentifier: "ios.account.registerPush.detail",
                accessibilityHint: isRegisteringPushNotifications ? "Push sync registration is already running" : "Request notification permission and register this iPhone APNs token with the configured backend",
                action: onRegisterPushNotifications
            ),
            AccountCommand(
                title: "Clear Token",
                detail: "Remove Keychain secret",
                systemImage: "key.slash",
                tint: .red,
                isDisabled: false,
                accessibilityIdentifier: "ios.account.clearToken",
                accessibilityHint: "Remove the saved backend bearer token from Keychain",
                role: .destructive,
                action: onClearBackendCredentials
            )
        ])
        return commands
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
}

private struct MobileAccountStatusHero: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var snapshot: MobileDashboardSnapshot
    var status: String
    var isActive: Bool
    var isRemoteEnabled: Bool
    var privacyMode: PrivacyMode

    private var tint: Color {
        if isActive { return .teal }
        return privacyMode == .privateLocal ? .indigo : .teal
    }

    var body: some View {
        LiquidGlassPanel(tint: tint.opacity(0.14), interactive: false, isLive: isActive) {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .center, spacing: 12) {
                    MobileLiveIconBadge(
                        systemImage: privacyMode == .privateLocal ? "lock.shield" : "person.crop.circle.badge.checkmark",
                        tint: tint,
                        isActive: isActive && !reduceMotion,
                        size: 38,
                        cornerRadius: 14
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Account Console")
                            .font(.headline.weight(.semibold))
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    MobileSignalGlyph(tint: tint, isActive: isActive && !reduceMotion)
                }

                MobileLiveFlowRibbon(tint: tint, isActive: isActive && !reduceMotion)
                    .frame(height: 14)

                HStack(spacing: 10) {
                    StatusPill(
                        title: "Mode",
                        value: privacyMode.label,
                        symbol: privacyMode == .privateLocal ? "lock" : "icloud",
                        tint: privacyMode == .privateLocal ? .indigo : .teal,
                        isActive: false
                    )
                    StatusPill(
                        title: "Remote",
                        value: isRemoteEnabled ? "On" : "Off",
                        symbol: isRemoteEnabled ? "checkmark.icloud" : "icloud.slash",
                        tint: isRemoteEnabled ? .teal : .secondary,
                        isActive: isRemoteEnabled
                    )
                    StatusPill(
                        title: "Review",
                        value: "\(snapshot.failedUploadCount)",
                        symbol: "exclamationmark.triangle",
                        tint: snapshot.failedUploadCount == 0 ? .mint : .orange,
                        isActive: snapshot.failedUploadCount > 0
                    )
                }
            }
        }
        .accessibilityIdentifier("ios.account.hero")
    }
}

private struct MobileAccountSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .accessibilityAddTraits(.isHeader)

            LazyVStack(alignment: .leading, spacing: 12) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AccountCommand: Identifiable {
    var id: String { accessibilityIdentifier }
    var title: String
    var detail: String
    var systemImage: String
    var tint: Color
    var isDisabled: Bool
    var accessibilityIdentifier: String
    var accessibilityHint: String
    var role: ButtonRole? = nil
    var action: () -> Void
}

private struct AccountCommandDeck: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var isActive: Bool
    var primaryStatus: String
    var commands: [AccountCommand]

    var body: some View {
        LiquidGlassPanel(tint: .teal.opacity(0.14), interactive: isActive, isLive: isActive) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 10) {
                    Label("Command Deck", systemImage: "sparkles")
                        .font(.headline)
                    Spacer()
                    MobileSignalGlyph(tint: isActive ? .orange : .teal, isActive: isActive && !reduceMotion)
                }
                Text(primaryStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                MobileLiveFlowRibbon(tint: isActive ? .orange : .teal, isActive: isActive && !reduceMotion)
                    .frame(height: 16)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 10)], spacing: 10) {
                    ForEach(commands) { command in
                        AccountCommandButton(command: command)
                    }
                }
            }
        }
    }
}

private struct BackendCommandDeck: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var isActive: Bool
    var commands: [AccountCommand]

    var body: some View {
        LiquidGlassPanel(tint: .indigo.opacity(0.12), interactive: isActive, isLive: isActive) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 10) {
                    Label("Backend Controls", systemImage: "network")
                        .font(.headline)
                    Spacer()
                    MobileLiveFlowRibbon(tint: isActive ? .orange : .indigo, isActive: isActive && !reduceMotion)
                        .frame(width: 118, height: 15)
                }
                LazyVStack(spacing: 8) {
                    ForEach(commands) { command in
                        AccountCommandButton(command: command, compact: true)
                    }
                }
            }
        }
    }
}

private struct AccountReadinessSummaryRow: View {
    var title: String
    var detail: String
    var systemImage: String
    var tint: Color
    var accessibilityIdentifier: String

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: systemImage)
                .font(.headline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(tint.opacity(0.16))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(detail)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct MobileSyncConflictReviewPanel: View {
    var conflict: WorkspaceSyncConflictStatus
    @Binding var selectedReviewItemIDs: Set<String>
    @Binding var customMergeValuesByItemID: [String: String]
    @Binding var itemPrimaryValuesByItemID: [String: String]
    @Binding var itemSecondaryValuesByItemID: [String: String]
    @Binding var itemTertiaryValuesByItemID: [String: String]
    @Binding var itemFlagValuesByItemID: [String: Bool]
    @Binding var itemNumericValuesByItemID: [String: Double]

    var body: some View {
        LiquidGlassPanel(tint: .red.opacity(0.12), interactive: false, isLive: !conflict.reviewItems.isEmpty) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Review Before Merge", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text(conflict.message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if conflict.reviewItems.isEmpty {
                    Text("Item details are unavailable for this legacy conflict. Counts are preserved; sync again to rebuild a full review.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(conflict.reviewItems) { item in
                            MobileSyncConflictChoiceRow(
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
            }
        }
        .onAppear(perform: resetSelectionIfNeeded)
        .onChange(of: conflict.reviewItems.map(\.id)) { _, _ in
            resetSelectionIfNeeded()
        }
        .accessibilityIdentifier("ios.account.syncConflictReview")
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

private struct MobileSyncConflictChoiceRow: View {
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
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
                .frame(width: 24, height: 24)
                .background(.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 7) {
                Toggle(isOn: keepBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.80)
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .accessibilityIdentifier("ios.account.syncConflictChoice.\(item.id)")

                if let preview = item.fieldDiffPreview {
                    MobileSyncConflictDiffPreview(preview: preview)
                }

                customMergeEditor

                Text(decisionText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.secondary : Color.red)
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var systemImage: String {
        item.systemImageName
    }

    private var title: String {
        switch item.kind {
        case .projectContent:
            return "Project field: \(item.projectField?.label ?? "Content")"
        case .projectArtifact:
            return "Artifact: \(item.projectTitle)"
        case .projectCollectionItem:
            return "\(item.projectField?.label ?? "Project item"): \(item.projectTitle)"
        case .localRecording, .localUploadJob:
            return "\(item.kind.label): \(item.projectTitle)"
        }
    }

    private var detail: String {
        "\(item.sourceLabel) - \(item.statusLabel) - \(item.detail)"
    }

    private var decisionText: String {
        isSelected ? "Keep local choice or typed draft" : "Remote snapshot wins"
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
            TextField("Type merged \(item.projectField?.label.lowercased() ?? "value")", text: customMergeValue, axis: .vertical)
                .font(.caption)
                .lineLimit(2...5)
                .mobileConflictDraftHitTarget(multiline: true)
                .textInputAutocapitalization(.sentences)
                .autocorrectionDisabled(false)
                .padding(8)
                .mobileInputSurface(tint: .red, cornerRadius: 10)
                .accessibilityIdentifier("ios.account.syncConflictDraft.\(item.id)")
            customMergeHelpText("Typed draft overrides both local and remote for this field.")
        case .status:
            Picker("Merged status", selection: customMergeValue) {
                Text("No custom status").tag("")
                ForEach(IdeaStatus.allCases) { status in
                    Text(status.label).tag(status.rawValue)
                }
            }
            .pickerStyle(.menu)
            .font(.caption)
            .accessibilityIdentifier("ios.account.syncConflictStatusDraft.\(item.id)")
            customMergeHelpText("Selected status overrides both local and remote for this field.")
        case .tags:
            VStack(alignment: .leading, spacing: 6) {
                Text("Merged tags")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 6)], spacing: 6) {
                    ForEach(IdeaTag.allCases) { tag in
                        Toggle(tag.label, isOn: tagBinding(tag))
                            .font(.caption2)
                    }
                }
            }
            .accessibilityIdentifier("ios.account.syncConflictTagsDraft.\(item.id)")
            customMergeHelpText("Selected tags override both local and remote for this field.")
        case .score:
            VStack(alignment: .leading, spacing: 8) {
                Text("Merged score")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                scoreSlider("Confidence", value: scoreBinding(\.confidence))
                scoreSlider("Completeness", value: scoreBinding(\.completeness))
                scoreSlider("Risk", value: scoreBinding(\.risk))
            }
            .accessibilityIdentifier("ios.account.syncConflictScoreDraft.\(item.id)")
            customMergeHelpText("Adjusted score overrides both local and remote for this field.")
        case .unsupported:
            EmptyView()
        }
    }

    @ViewBuilder
    private var itemCustomMergeEditor: some View {
        switch item.projectField?.itemCustomMergeKind ?? .unsupported {
        case .question:
            VStack(alignment: .leading, spacing: 7) {
                TextField("Merged question prompt", text: itemPrimaryValue, axis: .vertical)
                    .font(.caption)
                    .lineLimit(1...3)
                    .mobileConflictDraftHitTarget()
                    .textInputAutocapitalization(.sentences)
                    .autocorrectionDisabled(false)
                    .padding(8)
                    .mobileInputSurface(tint: .red, cornerRadius: 10)
                    .accessibilityIdentifier("ios.account.syncConflictItemPromptDraft.\(item.id)")
                TextField("Merged answer", text: itemSecondaryValue, axis: .vertical)
                    .font(.caption)
                    .lineLimit(1...3)
                    .mobileConflictDraftHitTarget()
                    .textInputAutocapitalization(.sentences)
                    .autocorrectionDisabled(false)
                    .padding(8)
                    .mobileInputSurface(tint: .red, cornerRadius: 10)
                    .accessibilityIdentifier("ios.account.syncConflictItemAnswerDraft.\(item.id)")
                Toggle("Blocking question", isOn: itemFlagValue)
                    .font(.caption2)
                    .accessibilityIdentifier("ios.account.syncConflictItemBlockingDraft.\(item.id)")
            }
            customMergeHelpText("Typed question draft overrides both local and remote for this item.")
        case .assumption:
            VStack(alignment: .leading, spacing: 7) {
                TextField("Merged assumption", text: itemPrimaryValue, axis: .vertical)
                    .font(.caption)
                    .lineLimit(1...3)
                    .mobileConflictDraftHitTarget()
                    .textInputAutocapitalization(.sentences)
                    .autocorrectionDisabled(false)
                    .padding(8)
                    .mobileInputSurface(tint: .red, cornerRadius: 10)
                    .accessibilityIdentifier("ios.account.syncConflictItemAssumptionDraft.\(item.id)")
                TextField("Merged evidence", text: itemSecondaryValue, axis: .vertical)
                    .font(.caption)
                    .lineLimit(1...3)
                    .mobileConflictDraftHitTarget()
                    .textInputAutocapitalization(.sentences)
                    .autocorrectionDisabled(false)
                    .padding(8)
                    .mobileInputSurface(tint: .red, cornerRadius: 10)
                    .accessibilityIdentifier("ios.account.syncConflictItemEvidenceDraft.\(item.id)")
                scoreSlider("Confidence", value: itemNumericValue)
                    .accessibilityIdentifier("ios.account.syncConflictItemConfidenceDraft.\(item.id)")
            }
            customMergeHelpText("Typed assumption draft overrides both local and remote for this item.")
        case .validationExperiment:
            VStack(alignment: .leading, spacing: 7) {
                TextField("Merged validation experiment", text: itemPrimaryValue, axis: .vertical)
                    .font(.caption)
                    .lineLimit(1...3)
                    .mobileConflictDraftHitTarget()
                    .textInputAutocapitalization(.sentences)
                    .autocorrectionDisabled(false)
                    .padding(8)
                    .mobileInputSurface(tint: .red, cornerRadius: 10)
                    .accessibilityIdentifier("ios.account.syncConflictItemExperimentDraft.\(item.id)")
                TextField("Merged success metric", text: itemSecondaryValue, axis: .vertical)
                    .font(.caption)
                    .lineLimit(1...3)
                    .mobileConflictDraftHitTarget()
                    .textInputAutocapitalization(.sentences)
                    .autocorrectionDisabled(false)
                    .padding(8)
                    .mobileInputSurface(tint: .red, cornerRadius: 10)
                    .accessibilityIdentifier("ios.account.syncConflictItemMetricDraft.\(item.id)")
                TextField("Merged go/no-go criteria", text: itemTertiaryValue, axis: .vertical)
                    .font(.caption)
                    .lineLimit(1...3)
                    .mobileConflictDraftHitTarget()
                    .textInputAutocapitalization(.sentences)
                    .autocorrectionDisabled(false)
                    .padding(8)
                    .mobileInputSurface(tint: .red, cornerRadius: 10)
                    .accessibilityIdentifier("ios.account.syncConflictItemCriteriaDraft.\(item.id)")
            }
            customMergeHelpText("Typed validation draft overrides both local and remote for this item.")
        case .codexTask:
            VStack(alignment: .leading, spacing: 7) {
                TextField("Merged Codex task", text: itemPrimaryValue, axis: .vertical)
                    .font(.caption)
                    .lineLimit(1...3)
                    .mobileConflictDraftHitTarget()
                    .textInputAutocapitalization(.sentences)
                    .autocorrectionDisabled(false)
                    .padding(8)
                    .mobileInputSurface(tint: .red, cornerRadius: 10)
                    .accessibilityIdentifier("ios.account.syncConflictItemCodexTaskDraft.\(item.id)")
                TextField("Acceptance criteria, one per line", text: itemSecondaryValue, axis: .vertical)
                    .font(.caption)
                    .lineLimit(2...5)
                    .mobileConflictDraftHitTarget(multiline: true)
                    .textInputAutocapitalization(.sentences)
                    .autocorrectionDisabled(false)
                    .padding(8)
                    .mobileInputSurface(tint: .red, cornerRadius: 10)
                    .accessibilityIdentifier("ios.account.syncConflictItemAcceptanceDraft.\(item.id)")
                TextField("Test plan, one per line", text: itemTertiaryValue, axis: .vertical)
                    .font(.caption)
                    .lineLimit(2...5)
                    .mobileConflictDraftHitTarget(multiline: true)
                    .textInputAutocapitalization(.sentences)
                    .autocorrectionDisabled(false)
                    .padding(8)
                    .mobileInputSurface(tint: .red, cornerRadius: 10)
                    .accessibilityIdentifier("ios.account.syncConflictItemTestPlanDraft.\(item.id)")
            }
            customMergeHelpText("Typed Codex task draft overrides both local and remote for this item.")
        case .workflowRun:
            VStack(alignment: .leading, spacing: 7) {
                TextField("Merged workflow run name", text: itemPrimaryValue, axis: .vertical)
                    .font(.caption)
                    .lineLimit(1...3)
                    .mobileConflictDraftHitTarget()
                    .textInputAutocapitalization(.sentences)
                    .autocorrectionDisabled(false)
                    .padding(8)
                    .mobileInputSurface(tint: .red, cornerRadius: 10)
                    .accessibilityIdentifier("ios.account.syncConflictItemWorkflowRunNameDraft.\(item.id)")
                Picker("Merged run status", selection: itemSecondaryValue) {
                    Text("Choose status").tag("")
                    ForEach(WorkflowRunStatus.allCases) { status in
                        Text(status.rawValue.capitalized).tag(status.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .font(.caption)
                .accessibilityIdentifier("ios.account.syncConflictItemWorkflowRunStatusDraft.\(item.id)")
                TextField("Failure note required when failed", text: itemTertiaryValue, axis: .vertical)
                    .font(.caption)
                    .lineLimit(1...3)
                    .mobileConflictDraftHitTarget()
                    .textInputAutocapitalization(.sentences)
                    .autocorrectionDisabled(false)
                    .padding(8)
                    .mobileInputSurface(tint: .red, cornerRadius: 10)
                    .accessibilityIdentifier("ios.account.syncConflictItemWorkflowRunFailureDraft.\(item.id)")
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
                .frame(width: 82, alignment: .leading)
            Slider(value: value, in: 0...1, step: 0.05)
            Text(value.wrappedValue, format: .percent.precision(.fractionLength(0)))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }
}

private struct MobileSyncConflictDiffPreview: View {
    var preview: WorkspaceSyncConflictFieldDiffPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            syncValueRow(title: "Local", value: preview.localValue, tint: .cyan)
            syncValueRow(title: "Remote", value: preview.remoteValue, tint: .indigo)
            Text(preview.changeSummary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(.background.opacity(0.46), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.red.opacity(0.12))
        }
    }

    private func syncValueRow(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
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

private struct AccountCommandButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var command: AccountCommand
    var compact = false

    var body: some View {
        Button(role: command.role, action: command.action) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: command.systemImage)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(command.isDisabled ? .secondary : command.tint)
                    .frame(width: 28, height: 28)
                    .background(command.tint.opacity(command.isDisabled ? 0.06 : 0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(command.title)
                        .font(compact ? .callout.weight(.semibold) : .subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                    Text(command.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(compact ? 1 : 2)
                        .minimumScaleFactor(0.78)
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, compact ? 9 : 11)
            .frame(maxWidth: .infinity, minHeight: compact ? 54 : 68, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: compact ? 14 : 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: compact ? 14 : 16, style: .continuous)
                    .strokeBorder(command.tint.opacity(command.isDisabled ? 0.08 : 0.18))
            }
            .overlay(alignment: .bottomLeading) {
                MobileStatusRail(tint: command.tint, isActive: !command.isDisabled && !reduceMotion)
                    .frame(height: 5)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
                    .opacity(command.isDisabled ? 0.28 : 1)
            }
        }
        .buttonStyle(MobileCardButtonStyle(tint: command.tint, isLive: !command.isDisabled))
        .disabled(command.isDisabled)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(command.title)
        .accessibilityValue(command.detail)
        .accessibilityIdentifier(command.accessibilityIdentifier)
        .accessibilityHint(command.accessibilityHint)
        .opacity(command.isDisabled ? 0.74 : 1)
    }
}

private struct CommerceActionReadinessRow: View {
    var title: String
    var systemImage: String
    var isEnabled: Bool
    var blockerSummary: String
    var accessibilityIdentifier: String
    var role: ButtonRole? = nil
    var action: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(role: role, action: action) {
                Label(title, systemImage: systemImage)
            }
            .disabled(!isEnabled)
            .accessibilityIdentifier(accessibilityIdentifier)
            .accessibilityHint(blockerSummary)
            Text(blockerSummary)
                .font(.caption)
                .foregroundStyle(isEnabled ? .green : .secondary)
        }
    }
}

private struct CommerceProductPurchaseRow: View {
    var product: CommerceProduct
    var isActive: Bool
    var isEnabled: Bool
    var blockerSummary: String
    var accessibilityIdentifier: String
    var action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(product.displayName)
                    Text("\(product.billingPeriod.label) - \(product.priceLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: action) {
                    Label(isActive ? "Active" : "Purchase", systemImage: isActive ? "checkmark.seal" : "cart.badge.plus")
                }
                .disabled(!isEnabled || isActive)
                .accessibilityIdentifier(accessibilityIdentifier)
                .accessibilityHint(isActive ? "This subscription is active" : blockerSummary)
            }
            if !isEnabled && !isActive {
                Text(blockerSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
