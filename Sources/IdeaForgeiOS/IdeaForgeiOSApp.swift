import SwiftUI

@main
struct IdeaForgeiOSApp: App {
    #if canImport(UIKit)
    @UIApplicationDelegateAdaptor(IdeaForgePushNotificationAppDelegate.self) private var pushNotificationDelegate
    @StateObject private var pushNotificationTokenCenter = PushNotificationTokenCenter.shared
    #endif
    @State private var store: IdeaForgeStore
    @State private var uploadProcessingCoordinator: UploadQueueProcessingCoordinator
    @State private var didRunBackgroundCallerProbe = false
    @State private var isReconcilingMacEnrichment = false
    @Environment(\.scenePhase) private var scenePhase
    private let backendConfigurationManager: BackendConfigurationManager
    private let recordingTransferService: any RecordingTransferService

    init() {
        let store = Self.makeStore()
        let uploadProcessingCoordinator = UploadQueueProcessingCoordinator()
        let backendConfigurationManager = Self.makeBackendConfigurationManager()
        _store = State(initialValue: store)
        _uploadProcessingCoordinator = State(initialValue: uploadProcessingCoordinator)
        self.backendConfigurationManager = backendConfigurationManager

        let importer = TransferredRecordingImporter()
        let recordingTransferService: any RecordingTransferService
        if ProcessInfo.processInfo.arguments.contains("-uiTesting") {
            recordingTransferService = UnavailableRecordingTransferService()
        } else {
            recordingTransferService = RecordingTransferServiceFactory.platformDefault { fileURL, metadata in
                do {
                    try await importer.importFile(
                        sourceURL: fileURL,
                        metadata: metadata,
                        into: store
                    )
                    let backgroundCoordinator = BackgroundUploadCoordinator(
                        store: store,
                        backendConfigurationManager: backendConfigurationManager,
                        uploadProcessingCoordinator: uploadProcessingCoordinator
                    )
                    backgroundCoordinator.scheduleIfNeeded()
                    Task { @MainActor in
                        _ = await backgroundCoordinator.runRefresh()
                    }
                    IdeaForgeLog.sync.info("Watch recording transfer imported; upload and Mac enrichment handoff scheduled")
                    return .imported
                } catch {
                    store.lastErrorMessage = (error as? UserFacingIdeaForgeError)?.userFacingMessage ?? "Watch transfer import failed."
                    IdeaForgeLog.sync.error("Watch recording transfer import failed")
                    return .failed
                }
            }
        }
        self.recordingTransferService = recordingTransferService
        BackgroundUploadEventCenter.shared.install {
            let coordinator = BackgroundUploadCoordinator(
                store: store,
                backendConfigurationManager: backendConfigurationManager,
                uploadProcessingCoordinator: uploadProcessingCoordinator
            )
            _ = await coordinator.runRefresh()
        }
        PushNotificationTokenCenter.shared.installRemoteNotificationHandler { trigger in
            let coordinator = BackgroundUploadCoordinator(
                store: store,
                backendConfigurationManager: backendConfigurationManager,
                uploadProcessingCoordinator: uploadProcessingCoordinator
            )
            return await coordinator.runRemoteNotification(trigger: trigger)
        }
        if ProcessInfo.processInfo.arguments.contains("-uiTestingRunColdRemoteNotification") {
            Task { @MainActor in
                let result = await PushNotificationTokenCenter.shared.handleRemoteNotification(
                    .accepted(
                        RemotePushNotificationTrigger(
                            workspaceID: "workspace_alpha",
                            topics: [.recordingProcessing]
                        )
                    )
                )
                store.lastErrorMessage = result == .failed
                    ? "Cold-launch remote notification result: Failed."
                    : "Cold-launch remote notification handler was ready."
            }
        }
        recordingTransferService.setReachabilityHandler { isReachable in
            store.syncHealth.watchReachable = isReachable
        }
        recordingTransferService.activate()
    }

    var body: some Scene {
        WindowGroup {
            iOSContentView(
                store: store,
                backendConfigurationManager: backendConfigurationManager,
                uploadProcessingCoordinator: uploadProcessingCoordinator,
                recordingTransferService: recordingTransferService,
                pushNotificationTokenCenter: pushNotificationTokenCenter
            )
            .preferredColorScheme(Self.uiTestingPreferredColorScheme)
            .onAppear {
                IdeaForgeLog.lifecycle.notice("iOS app appeared")
                recordingTransferService.activate()
                backgroundUploadCoordinator.reconcileCompletedBackgroundUploads()
                backgroundUploadCoordinator.scheduleIfNeeded()
                runBackgroundCallerProbeIfRequested()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    IdeaForgeLog.lifecycle.info("iOS app entered background")
                    backgroundUploadCoordinator.scheduleIfNeeded()
                } else if phase == .active {
                    Task { @MainActor in
                        await reconcileMacEnrichmentIfAvailable()
                    }
                }
            }
            .task {
                await pollForMacEnrichmentWhileForegrounded()
            }
        }
        .backgroundTask(.appRefresh(IdeaForgeBackgroundTasks.uploadRefreshIdentifier)) {
            IdeaForgeLog.sync.info("iOS background upload refresh started")
            await backgroundUploadCoordinator.runRefresh()
        }
    }

    @MainActor
    private var backgroundUploadCoordinator: BackgroundUploadCoordinator {
        BackgroundUploadCoordinator(
            store: store,
            backendConfigurationManager: backendConfigurationManager,
            uploadProcessingCoordinator: uploadProcessingCoordinator
        )
    }

    /// The local backend cannot rely on APNs, so an active iPhone periodically
    /// pulls Mac-produced transcript/title updates. Watch receives only the
    /// compact title/status projection through durable application context.
    @MainActor
    private func pollForMacEnrichmentWhileForegrounded() async {
        guard !ProcessInfo.processInfo.arguments.contains("-uiTesting") else { return }

        while !Task.isCancelled {
            if scenePhase == .active {
                await reconcileMacEnrichmentIfAvailable()
            }
            do {
                try await Task.sleep(for: .seconds(15))
            } catch {
                return
            }
        }
    }

    @MainActor
    private func reconcileMacEnrichmentIfAvailable() async {
        guard !isReconcilingMacEnrichment else { return }
        isReconcilingMacEnrichment = true
        defer { isReconcilingMacEnrichment = false }

        do {
            guard let syncConfiguration = try backendConfigurationManager.resolvedSyncConfiguration() else {
                return
            }
            let summary = try await WorkspaceSyncEngine(
                client: BackendWorkspaceSyncClient(configuration: syncConfiguration)
            ).pullLatestPreservingLocalUploadWork(into: store)
            try recordingTransferService.publish(
                WatchEnrichmentProjection(projects: store.projects)
            )
            if summary.appliedRemoteSnapshot {
                IdeaForgeLog.sync.info("Mac enrichment reconciled automatically and Watch projection queued")
            }
        } catch let conflict as WorkspaceSyncConflictError {
            IdeaForgeLog.sync.notice("Automatic Mac enrichment pull paused for review; project conflicts: \(conflict.report.projectContentConflicts.count, privacy: .public)")
        } catch {
            let diagnostic = WorkspaceSyncFailureDiagnostic.classify(error)
            IdeaForgeLog.sync.info("Automatic Mac enrichment pull deferred; category: \(diagnostic.category.rawValue, privacy: .public)")
        }
    }

    @MainActor
    private func runBackgroundCallerProbeIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        let runsRefresh = arguments.contains("-uiTestingRunBackgroundRefresh")
        let runsRemoteNotification = arguments.contains("-uiTestingRunRemoteNotification")
        guard !didRunBackgroundCallerProbe, runsRefresh || runsRemoteNotification else { return }
        didRunBackgroundCallerProbe = true

        Task { @MainActor in
            if runsRefresh {
                let outcome = await backgroundUploadCoordinator.runRefresh()
                store.lastErrorMessage = outcome == .failed
                    ? "Background refresh result: Failed."
                    : "Background refresh result: Completed."
                return
            }

            let result = await backgroundUploadCoordinator.runRemoteNotification(
                trigger: RemotePushNotificationTrigger(
                    workspaceID: "workspace_alpha",
                    topics: [.recordingProcessing]
                )
            )
            store.lastErrorMessage = result == .failed
                ? "Remote notification result: Failed."
                : "Remote notification result: Not failed."
        }
    }

    private static func makeBackendConfigurationManager() -> BackendConfigurationManager {
        if ProcessInfo.processInfo.arguments.contains("-uiTestingLocalBackend") {
            return BackendConfigurationManager(
                settingsStore: InMemoryBackendSettingsStore(
                    settings: BackendConnectionSettings(
                        baseURLString: "https://ideaforge-test.local:8765",
                        workspaceID: "",
                        isEnabled: true,
                        connectionKind: .localBackend
                    )
                ),
                credentialStore: InMemoryBackendCredentialStore()
            )
        }
        guard ProcessInfo.processInfo.arguments.contains("-uiTestingInvalidUploadConfiguration") else {
            return .production()
        }
        return BackendConfigurationManager(
            settingsStore: InMemoryBackendSettingsStore(
                settings: BackendConnectionSettings(
                    baseURLString: "not a valid backend URL",
                    workspaceID: "workspace_alpha",
                    isEnabled: true
                )
            ),
            credentialStore: InMemoryBackendCredentialStore(token: "ui-test-token")
        )
    }

    private static var uiTestingPreferredColorScheme: ColorScheme? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-uiTesting") else { return nil }
        return arguments.contains("-uiTestingDarkAppearance") ? .dark : nil
    }

    private static func makeStore() -> IdeaForgeStore {
        if ProcessInfo.processInfo.arguments.contains("-uiTestingCapabilityGate") {
            let store = SampleData.taskFirstStore(state: .clean)
            store.setPrivacyMode(.standardCloud)
            return store
        }
        if ProcessInfo.processInfo.arguments.contains("-uiTestingClean") {
            return SampleData.taskFirstStore(state: .clean)
        }
        if ProcessInfo.processInfo.arguments.contains("-uiTestingQueuedUpload") {
            return SampleData.taskFirstStore(state: .queuedUpload)
        }
        if ProcessInfo.processInfo.arguments.contains("-uiTestingFailedUpload") {
            return SampleData.taskFirstStore(state: .failedUpload)
        }
        if ProcessInfo.processInfo.arguments.contains("-uiTestingNonRetryableTranscriptFailure") {
            return SampleData.nonRetryableTranscriptFailureStore()
        }
        if ProcessInfo.processInfo.arguments.contains("-uiTestingOfflineWatch") {
            return SampleData.taskFirstStore(state: .offlineWatch)
        }
        if ProcessInfo.processInfo.arguments.contains("-uiTestingPublishedWorkspace") {
            return SampleData.publishedHandoffStore()
        }
        if ProcessInfo.processInfo.arguments.contains("-uiTestingLocalOnlyWorkspace") {
            return SampleData.localOnlyCleanStore()
        }
        if ProcessInfo.processInfo.arguments.contains("-uiTestingCustomSyncConflict") {
            return SampleData.customItemSyncConflictStore()
        }
        if ProcessInfo.processInfo.arguments.contains("-uiTestingSyncConflict") {
            return SampleData.syncConflictStore()
        }
        if ProcessInfo.processInfo.arguments.contains("-uiTesting") {
            return SampleData.store()
        }
        return .production()
    }
}
