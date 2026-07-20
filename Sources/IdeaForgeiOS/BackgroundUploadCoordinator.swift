import BackgroundTasks
import Foundation
import UIKit

enum IdeaForgeBackgroundTasks {
    static let uploadRefreshIdentifier = "com.s1kor.ideaforge.upload-refresh"
}

enum BackgroundUploadRefreshOutcome: Equatable {
    case completed
    case failed
}

@MainActor
struct BackgroundUploadCoordinator {
    var store: IdeaForgeStore
    var backendConfigurationManager: BackendConfigurationManager
    var uploadProcessingCoordinator: UploadQueueProcessingCoordinator

    func scheduleIfNeeded(now: Date = Date()) {
        store.recoverInterruptedUploads(now: now)
        guard let nextRunDate = UploadSchedulePolicy.nextRunDate(for: store.uploadJobs, now: now) else {
            IdeaForgeLog.sync.info("Background upload scheduling skipped; no due upload jobs")
            return
        }

        let request = BGAppRefreshTaskRequest(identifier: IdeaForgeBackgroundTasks.uploadRefreshIdentifier)
        request.earliestBeginDate = nextRunDate
        do {
            try BGTaskScheduler.shared.submit(request)
            IdeaForgeLog.sync.info("Background upload refresh scheduled")
        } catch {
            IdeaForgeLog.sync.error("Background upload refresh scheduling failed")
        }
    }

    @discardableResult
    func runRefresh(now: Date = Date()) async -> BackgroundUploadRefreshOutcome {
        defer {
            scheduleIfNeeded(now: now)
        }

        do {
            _ = reconcileCompletedBackgroundUploads(now: now)
            _ = try await processUploadsAndPublishIfReady(now: now)
            IdeaForgeLog.sync.info("Background upload refresh completed")
            return .completed
        } catch {
            store.lastErrorMessage = "Background upload could not run."
            IdeaForgeLog.sync.error("Background upload refresh failed")
            return .failed
        }
    }

    @discardableResult
    func reconcileCompletedBackgroundUploads(now: Date = Date()) -> Int {
        let records = URLSessionHTTPDataTransport.shared.pendingBackgroundCompletionRecords()
        guard !records.isEmpty else { return 0 }

        var reconciledUploadJobIDs: Set<String> = []
        for record in records {
            guard store.uploadJobs.contains(where: {
                $0.id == record.uploadJobID && $0.recordingID == record.recordingID
            }) else {
                if !store.workspaceLoadFailed {
                    reconciledUploadJobIDs.insert(record.uploadJobID)
                } else {
                    IdeaForgeLog.sync.warning("Retained unmatched background upload completion because workspace loading is degraded")
                }
                continue
            }

            do {
                let receipt = try BackgroundUploadCompletionPolicy.receipt(from: record)
                if store.markUploadSucceeded(
                    recordingID: receipt.recordingID,
                    objectKey: receipt.objectKey,
                    now: record.completedAt
                ) {
                    reconciledUploadJobIDs.insert(record.uploadJobID)
                }
            } catch {
                let message = (error as? UserFacingIdeaForgeError)?.userFacingMessage
                    ?? "Background upload could not be completed."
                if store.markUploadFailed(
                    recordingID: record.recordingID,
                    message: message,
                    category: UploadFailureCategory.classify(error),
                    now: record.completedAt
                ) {
                    reconciledUploadJobIDs.insert(record.uploadJobID)
                }
            }
        }

        URLSessionHTTPDataTransport.shared.removeBackgroundCompletionRecords(
            uploadJobIDs: reconciledUploadJobIDs
        )
        if !reconciledUploadJobIDs.isEmpty {
            IdeaForgeLog.sync.info("Reconciled background upload completions after app relaunch; count: \(reconciledUploadJobIDs.count, privacy: .public)")
        }
        return reconciledUploadJobIDs.count
    }

    func runRemoteNotification(
        trigger: RemotePushNotificationTrigger,
        now: Date = Date()
    ) async -> UIBackgroundFetchResult {
        defer {
            scheduleIfNeeded(now: now)
        }

        do {
            let settings = try backendConfigurationManager.loadSettings()
            guard settings.isEnabled else {
                store.recordSyncActivity(
                    WorkspaceSyncActivityReceipt(
                        source: .remoteNotification,
                        status: .blocked,
                        title: "Push sync paused",
                        detail: "Backend sync is disabled on this iPhone.",
                        occurredAt: now
                    )
                )
                IdeaForgeLog.sync.warning("Remote notification sync skipped; backend disabled")
                return .noData
            }
            guard settings.normalizedWorkspaceID == trigger.workspaceID else {
                store.recordSyncActivity(
                    WorkspaceSyncActivityReceipt(
                        source: .remoteNotification,
                        status: .blocked,
                        title: "Push sync ignored",
                        detail: "Remote workspace did not match this iPhone workspace.",
                        occurredAt: now
                    )
                )
                IdeaForgeLog.sync.warning("Remote notification sync skipped; workspace mismatch")
                return .noData
            }

            let capabilityDecision = try await remoteNotificationCapabilityDecision(
                for: trigger,
                expectedWorkspaceID: settings.normalizedWorkspaceID
            )
            guard capabilityDecision.isAllowed else {
                store.recordSyncActivity(
                    WorkspaceSyncActivityReceipt(
                        source: .remoteNotification,
                        status: .blocked,
                        title: "Push sync paused",
                        detail: capabilityDecision.blockerSummary.isEmpty
                            ? "Validated backend sync capability is required."
                            : capabilityDecision.blockerSummary,
                        occurredAt: now
                    )
                )
                IdeaForgeLog.sync.warning("Remote notification sync skipped; capability gate blocked action")
                return .noData
            }

            var changedData = false
            if trigger.shouldProcessUploads || trigger.shouldPublishLocalSnapshot {
                changedData = try await processUploadsAndPublishIfReady(now: now) || changedData
            }
            if trigger.shouldRefreshWorkspace {
                changedData = try await refreshWorkspaceSnapshotFromRemote(now: now) || changedData
            }
            IdeaForgeLog.sync.info("Remote notification sync completed; changed data: \(changedData, privacy: .public)")
            return changedData ? .newData : .noData
        } catch BackendConfigurationError.invalidBaseURL {
            store.recordSyncActivity(
                WorkspaceSyncActivityReceipt(
                    source: .remoteNotification,
                    status: .blocked,
                    title: "Push sync paused",
                    detail: "Backend URL is invalid.",
                    occurredAt: now
                )
            )
            IdeaForgeLog.sync.error("Remote notification sync failed; invalid backend URL")
            return .failed
        } catch {
            store.recordSyncActivity(
                WorkspaceSyncActivityReceipt(
                    source: .remoteNotification,
                    status: .failed,
                    title: "Push sync failed",
                    detail: "Remote notification sync could not complete.",
                    occurredAt: now
                )
            )
            IdeaForgeLog.sync.error("Remote notification sync failed")
            return .failed
        }
    }

    private func processUploadsAndPublishIfReady(now: Date) async throws -> Bool {
        let summary = try await uploadProcessingCoordinator.requestProcessing {
            try await ConfiguredUploadQueueProcessor(
                backendConfigurationManager: backendConfigurationManager,
                maxJobsPerRun: 2
            )
            .processDueUploads(in: store, now: now)
        }
        let didPublish = await publishWorkspaceSnapshotIfReady(now: now)
        return summary.uploadedCount > 0 || summary.failedCount > 0 || didPublish
    }

    private func publishWorkspaceSnapshotIfReady(now: Date) async -> Bool {
        let result = await ConfiguredWorkspaceAutoSyncProcessor(
            backendConfigurationManager: backendConfigurationManager
        )
        .publishLocalSnapshotIfNeeded(from: store, syncedAt: now)

        switch result {
        case .published(let summary):
            IdeaForgeLog.sync.info("Background workspace auto-sync published snapshot: \(summary.pushedLocalSnapshot, privacy: .public)")
            return summary.pushedLocalSnapshot
        case .idle:
            IdeaForgeLog.sync.info("Background workspace auto-sync skipped; local workspace already has a backend receipt")
            return false
        case .skipped(let blocker, _):
            IdeaForgeLog.sync.warning("Background workspace auto-sync skipped; blocker: \(blocker.rawValue, privacy: .public)")
            return false
        }
    }

    private func refreshWorkspaceSnapshotFromRemote(now: Date) async throws -> Bool {
        guard let configuration = try backendConfigurationManager.resolvedSyncConfiguration() else {
            IdeaForgeLog.sync.warning("Remote notification workspace refresh skipped; sync configuration missing")
            return false
        }
        let engine = WorkspaceSyncEngine(
            client: BackendWorkspaceSyncClient(configuration: configuration)
        )
        let summary = try await engine.pullLatest(into: store)
        store.recordSyncActivity(
            WorkspaceSyncActivityReceipt(
                source: .remoteNotification,
                status: summary.appliedRemoteSnapshot ? .success : .skipped,
                title: summary.appliedRemoteSnapshot ? "Push refreshed workspace" : "Push refresh clean",
                detail: summary.appliedRemoteSnapshot
                    ? "This iPhone applied the latest backend workspace."
                    : "No newer backend workspace was available.",
                occurredAt: now
            ),
            clearsLastError: summary.appliedRemoteSnapshot
        )
        IdeaForgeLog.sync.info("Remote notification workspace refresh completed; applied remote snapshot: \(summary.appliedRemoteSnapshot, privacy: .public)")
        return summary.appliedRemoteSnapshot
    }

    private func remoteNotificationCapabilityDecision(
        for trigger: RemotePushNotificationTrigger,
        expectedWorkspaceID: String
    ) async throws -> BackendCapabilityDecision {
        guard let authConfiguration = try backendConfigurationManager.resolvedAuthConfiguration() else {
            return BackendCapabilityGate(session: nil).decision(
                requiredCapabilities: [.syncWorkspace],
                expectedWorkspaceID: expectedWorkspaceID
            )
        }

        var requiredCapabilities: [BackendAccountCapability] = [.syncWorkspace]
        if trigger.shouldProcessUploads {
            requiredCapabilities.append(.uploadRecordings)
        }

        let session = try await BackendAuthSessionClient(configuration: authConfiguration).validateSession()
        return BackendCapabilityGate(session: session).decision(
            requiredCapabilities: requiredCapabilities,
            expectedWorkspaceID: expectedWorkspaceID
        )
    }
}
