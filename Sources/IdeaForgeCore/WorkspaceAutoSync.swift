import Foundation

public enum WorkspaceAutoSyncBlocker: String, Equatable, Sendable {
    case missingConfiguration
    case invalidConfiguration
    case capabilityGate
    case privateLocalMode
    case syncConflict
    case activeUploadWork
    case failedUploadWork
    case requestFailed

    public var userFacingMessage: String {
        switch self {
        case .missingConfiguration:
            return "Automatic workspace sync needs backend settings, workspace ID, and a token."
        case .invalidConfiguration:
            return "Automatic workspace sync needs a valid backend URL."
        case .capabilityGate:
            return "Automatic workspace sync needs a validated backend session with workspace sync capability."
        case .privateLocalMode:
            return "Private mode keeps automatic workspace sync off."
        case .syncConflict:
            return "Automatic workspace sync is paused until the sync conflict is reviewed."
        case .activeUploadWork:
            return "Automatic workspace sync is waiting for local upload work to finish."
        case .failedUploadWork:
            return "Automatic workspace sync is paused until failed upload work is reviewed."
        case .requestFailed:
            return "Automatic workspace sync failed."
        }
    }
}

public enum WorkspaceAutoSyncDecision: Equatable, Sendable {
    case publishLocalSnapshot(String)
    case idle(String)
    case blocked(WorkspaceAutoSyncBlocker, String)

    public var isPublishable: Bool {
        if case .publishLocalSnapshot = self {
            return true
        }
        return false
    }

    public var message: String {
        switch self {
        case .publishLocalSnapshot(let message), .idle(let message), .blocked(_, let message):
            return message
        }
    }
}

public enum WorkspaceAutoSyncPolicy {
    public static func localPreflightDecision(for state: WorkspaceState) -> WorkspaceAutoSyncDecision? {
        guard state.syncHealth.syncConflictStatus == nil else {
            return .blocked(
                .syncConflict,
                WorkspaceAutoSyncBlocker.syncConflict.userFacingMessage
            )
        }

        guard state.privacyMode != .privateLocal else {
            return .blocked(
                .privateLocalMode,
                WorkspaceAutoSyncBlocker.privateLocalMode.userFacingMessage
            )
        }

        let activeUploadCount = state.uploadJobs.filter(Self.isActiveUploadWork).count
        guard activeUploadCount == 0 else {
            return .blocked(
                .activeUploadWork,
                "\(WorkspaceAutoSyncBlocker.activeUploadWork.userFacingMessage) \(activeUploadCount) item(s) remain queued or retrying."
            )
        }

        let failedItemCount = failedUploadItemCount(in: state)
        guard failedItemCount == 0 else {
            return .blocked(
                .failedUploadWork,
                "\(WorkspaceAutoSyncBlocker.failedUploadWork.userFacingMessage) \(failedItemCount) item(s) need attention."
            )
        }

        guard let lastPublishedLocal = state.syncHealth.lastPublishedLocalUpdatedAt
            ?? state.syncHealth.lastRemoteWorkspaceUpdatedAt else {
            return nil
        }

        guard state.updatedAt > lastPublishedLocal else {
            return .idle("Local workspace already has a backend receipt.")
        }

        return nil
    }

    public static func decision(
        for state: WorkspaceState,
        capabilityDecision: BackendCapabilityDecision
    ) -> WorkspaceAutoSyncDecision {
        if let localPreflightDecision = localPreflightDecision(for: state) {
            return localPreflightDecision
        }

        guard capabilityDecision.isAllowed else {
            let message = capabilityDecision.blockerSummary.isEmpty
                ? WorkspaceAutoSyncBlocker.capabilityGate.userFacingMessage
                : capabilityDecision.blockerSummary
            return .blocked(.capabilityGate, message)
        }

        guard state.syncHealth.lastRemoteWorkspaceUpdatedAt != nil else {
            return .publishLocalSnapshot("No remote workspace receipt exists; publish the local iPhone workspace snapshot.")
        }

        return .publishLocalSnapshot("Local workspace changed after the last backend receipt; publish it for Mac handoff.")
    }

    private static func isActiveUploadWork(_ job: UploadJob) -> Bool {
        switch job.status {
        case .queued, .uploading, .waitingForRetry:
            return true
        case .uploaded, .permanentlyFailed:
            return false
        }
    }

    private static func failedUploadItemCount(in state: WorkspaceState) -> Int {
        let failedUploadCount = state.uploadJobs.filter { $0.status == .permanentlyFailed }.count
        let failedRecordingCount = state.projects
            .flatMap(\.recordings)
            .filter { $0.syncStatus == .failed }
            .count
        return failedUploadCount + failedRecordingCount + state.syncHealth.failingItems
    }
}

public enum WorkspaceAutoSyncResult: Equatable, Sendable {
    case skipped(WorkspaceAutoSyncBlocker, String)
    case idle(String)
    case published(WorkspaceSyncSummary)
}

public struct ConfiguredWorkspaceAutoSyncProcessor: Sendable {
    public var backendConfigurationManager: BackendConfigurationManager
    public var authTransport: any HTTPRequestTransport
    public var syncTransport: any HTTPRequestTransport

    public init(
        backendConfigurationManager: BackendConfigurationManager,
        authTransport: any HTTPRequestTransport = URLSessionHTTPRequestTransport(),
        syncTransport: any HTTPRequestTransport = URLSessionHTTPRequestTransport()
    ) {
        self.backendConfigurationManager = backendConfigurationManager
        self.authTransport = authTransport
        self.syncTransport = syncTransport
    }

    @MainActor
    public func publishLocalSnapshotIfNeeded(
        from store: IdeaForgeStore,
        syncedAt: Date = Date()
    ) async -> WorkspaceAutoSyncResult {
        do {
            let localState = store.workspaceState()
            if let preflightDecision = WorkspaceAutoSyncPolicy.localPreflightDecision(for: localState) {
                switch preflightDecision {
                case .blocked(let blocker, let message):
                    store.recordSyncActivity(
                        WorkspaceSyncActivityReceipt(
                            source: .backgroundAutoSync,
                            status: .blocked,
                            title: "Auto-sync paused",
                            detail: message,
                            occurredAt: syncedAt
                        )
                    )
                    return .skipped(blocker, message)
                case .idle(let message):
                    store.recordSyncActivity(
                        WorkspaceSyncActivityReceipt(
                            source: .backgroundAutoSync,
                            status: .skipped,
                            title: "Auto-sync clean",
                            detail: message,
                            occurredAt: syncedAt
                        )
                    )
                    return .idle(message)
                case .publishLocalSnapshot:
                    break
                }
            }

            guard let authConfiguration = try backendConfigurationManager.resolvedAuthConfiguration() else {
                store.recordSyncActivity(
                    WorkspaceSyncActivityReceipt(
                        source: .backgroundAutoSync,
                        status: .blocked,
                        title: "Auto-sync paused",
                        detail: WorkspaceAutoSyncBlocker.missingConfiguration.userFacingMessage,
                        occurredAt: syncedAt
                    )
                )
                return .skipped(
                    .missingConfiguration,
                    WorkspaceAutoSyncBlocker.missingConfiguration.userFacingMessage
                )
            }

            let session = try await BackendAuthSessionClient(
                configuration: authConfiguration,
                transport: authTransport
            )
            .validateSession()
            let capabilityDecision = BackendCapabilityGate(session: session).decision(
                requiredCapabilities: [.syncWorkspace],
                expectedWorkspaceID: authConfiguration.workspaceID
            )

            let currentState = store.workspaceState()
            let decision = WorkspaceAutoSyncPolicy.decision(
                for: currentState,
                capabilityDecision: capabilityDecision
            )
            switch decision {
            case .blocked(let blocker, let message):
                store.recordSyncActivity(
                    WorkspaceSyncActivityReceipt(
                        source: .backgroundAutoSync,
                        status: .blocked,
                        title: "Auto-sync paused",
                        detail: message,
                        occurredAt: syncedAt
                    )
                )
                return .skipped(blocker, message)
            case .idle(let message):
                store.recordSyncActivity(
                    WorkspaceSyncActivityReceipt(
                        source: .backgroundAutoSync,
                        status: .skipped,
                        title: "Auto-sync clean",
                        detail: message,
                        occurredAt: syncedAt
                    )
                )
                return .idle(message)
            case .publishLocalSnapshot:
                break
            }

            guard let syncConfiguration = try backendConfigurationManager.resolvedSyncConfiguration() else {
                store.recordSyncActivity(
                    WorkspaceSyncActivityReceipt(
                        source: .backgroundAutoSync,
                        status: .blocked,
                        title: "Auto-sync paused",
                        detail: WorkspaceAutoSyncBlocker.missingConfiguration.userFacingMessage,
                        occurredAt: syncedAt
                    )
                )
                return .skipped(
                    .missingConfiguration,
                    WorkspaceAutoSyncBlocker.missingConfiguration.userFacingMessage
                )
            }

            let engine = WorkspaceSyncEngine(
                client: BackendWorkspaceSyncClient(
                    configuration: syncConfiguration,
                    transport: syncTransport
                )
            )
            let summary = try await engine.synchronize(store: store, syncedAt: syncedAt)
            store.recordSyncActivity(
                WorkspaceSyncActivityReceipt(
                    source: .backgroundAutoSync,
                    status: summary.pushedLocalSnapshot ? .success : .skipped,
                    title: summary.pushedLocalSnapshot ? "Auto-sync published" : "Auto-sync clean",
                    detail: summary.pushedLocalSnapshot
                        ? "Workspace snapshot has a backend receipt for Mac handoff."
                        : "No workspace changes needed a new backend receipt.",
                    occurredAt: syncedAt
                )
            )
            return .published(summary)
        } catch BackendConfigurationError.invalidBaseURL {
            store.recordSyncActivity(
                WorkspaceSyncActivityReceipt(
                    source: .backgroundAutoSync,
                    status: .blocked,
                    title: "Auto-sync paused",
                    detail: WorkspaceAutoSyncBlocker.invalidConfiguration.userFacingMessage,
                    occurredAt: syncedAt
                )
            )
            return .skipped(
                .invalidConfiguration,
                WorkspaceAutoSyncBlocker.invalidConfiguration.userFacingMessage
            )
        } catch let conflict as WorkspaceSyncConflictError {
            store.recordSyncActivity(
                WorkspaceSyncActivityReceipt(
                    source: .backgroundAutoSync,
                    status: .blocked,
                    title: "Auto-sync paused",
                    detail: conflict.report.message,
                    occurredAt: syncedAt
                )
            )
            return .skipped(.syncConflict, conflict.report.message)
        } catch {
            store.recordSyncActivity(
                WorkspaceSyncActivityReceipt(
                    source: .backgroundAutoSync,
                    status: .failed,
                    title: "Auto-sync failed",
                    detail: WorkspaceAutoSyncBlocker.requestFailed.userFacingMessage,
                    occurredAt: syncedAt
                )
            )
            return .skipped(
                .requestFailed,
                WorkspaceAutoSyncBlocker.requestFailed.userFacingMessage
            )
        }
    }
}
