import Foundation

public protocol BackendRecordingEnrichmentServing: Sendable {
    func claimNextJob(leaseDurationSeconds: Int) async throws -> BackendEnrichmentJob?
    func stageAudio(for job: BackendEnrichmentJob, in stagingDirectory: URL) async throws -> URL
    func renew(jobID: String, leaseDurationSeconds: Int) async throws -> BackendEnrichmentLeaseReceipt
    func complete(jobID: String, workspaceUpdatedAt: Date) async throws -> BackendEnrichmentJobReceipt
    func fail(
        jobID: String,
        diagnosticCode: String,
        retryable: Bool
    ) async throws -> BackendEnrichmentJobReceipt
}

extension BackendEnrichmentClient: BackendRecordingEnrichmentServing {}

public protocol BackendWorkspaceSynchronizing: Sendable {
    @MainActor
    func synchronize(store: IdeaForgeStore, syncedAt: Date) async throws -> WorkspaceSyncSummary

    @MainActor
    func pushLocalSnapshot(from store: IdeaForgeStore, syncedAt: Date) async throws -> WorkspaceSyncSummary
}

extension WorkspaceSyncEngine: BackendWorkspaceSynchronizing {}

public enum MacRecordingEnrichmentResult: Equatable, Sendable {
    case idle
    case completed(recordingID: String, title: String)
    case failed(recordingID: String?, diagnosticCode: String, retryable: Bool)
}

public protocol MacRecordingEnrichmentProcessing: Sendable {
    @MainActor
    func processNext(in store: IdeaForgeStore, now: Date) async -> MacRecordingEnrichmentResult
}

public struct MacRecordingEnrichmentLoopSummary: Equatable, Sendable {
    public var attemptedCount: Int
    public var completedCount: Int
    public var failedCount: Int
    public var reachedIdle: Bool

    public init(
        attemptedCount: Int = 0,
        completedCount: Int = 0,
        failedCount: Int = 0,
        reachedIdle: Bool = false
    ) {
        self.attemptedCount = attemptedCount
        self.completedCount = completedCount
        self.failedCount = failedCount
        self.reachedIdle = reachedIdle
    }
}

public struct MacRecordingEnrichmentLoop: Sendable {
    public var processor: any MacRecordingEnrichmentProcessing
    public var maxJobsPerRun: Int

    public init(
        processor: any MacRecordingEnrichmentProcessing,
        maxJobsPerRun: Int = 4
    ) {
        self.processor = processor
        self.maxJobsPerRun = max(1, maxJobsPerRun)
    }

    @MainActor
    public func run(
        in store: IdeaForgeStore,
        now: Date = Date()
    ) async -> MacRecordingEnrichmentLoopSummary {
        var summary = MacRecordingEnrichmentLoopSummary()
        for _ in 0..<maxJobsPerRun {
            summary.attemptedCount += 1
            switch await processor.processNext(in: store, now: now) {
            case .idle:
                summary.reachedIdle = true
                return summary
            case .completed:
                summary.completedCount += 1
            case .failed:
                summary.failedCount += 1
                return summary
            }
        }
        return summary
    }
}

public struct MacRecordingEnrichmentProcessor: Sendable {
    public var backend: any BackendRecordingEnrichmentServing
    public var workspaceSynchronizer: any BackendWorkspaceSynchronizing
    public var services: IdeaForgeServices
    public var stagingDirectory: URL

    public init(
        backend: any BackendRecordingEnrichmentServing,
        workspaceSynchronizer: any BackendWorkspaceSynchronizing,
        services: IdeaForgeServices = .localSpeech,
        stagingDirectory: URL
    ) {
        self.backend = backend
        self.workspaceSynchronizer = workspaceSynchronizer
        self.services = services
        self.stagingDirectory = stagingDirectory
    }

    @MainActor
    public func processNext(
        in store: IdeaForgeStore,
        now: Date = Date()
    ) async -> MacRecordingEnrichmentResult {
        do {
            guard let job = try await backend.claimNextJob(leaseDurationSeconds: 300) else {
                return .idle
            }

            do {
                _ = try await workspaceSynchronizer.synchronize(store: store, syncedAt: now)
            } catch is WorkspaceSyncPublicationBlockedError {
                guard canResumeTransientCheckpoint(for: job, in: store) else {
                    return await fail(
                        job: job,
                        recordingID: job.recordingID,
                        diagnosticCode: "workspace_sync_failed",
                        retryable: true
                    )
                }
            } catch {
                return await fail(
                    job: job,
                    recordingID: job.recordingID,
                    diagnosticCode: "workspace_sync_failed",
                    retryable: true
                )
            }

            guard let location = recordingLocation(for: job, in: store) else {
                return await fail(
                    job: job,
                    recordingID: job.recordingID,
                    diagnosticCode: "workspace_recording_missing",
                    retryable: true
                )
            }

            if store.projects[location.projectIndex].recordings[location.recordingIndex].syncStatus == .ready {
                return await publishAndComplete(job: job, store: store, now: now)
            }
            let originalRecording = store.projects[location.projectIndex].recordings[location.recordingIndex]
            if originalRecording.syncStatus == .failed,
               originalRecording.processingDiagnostic?.isRetryable == false {
                return await publishAndFail(
                    job: job, store: store, now: now,
                    diagnosticCode: "speech_processing_unavailable", retryable: false
                )
            }

            let stagedURL: URL
            do {
                stagedURL = try await backend.stageAudio(for: job, in: stagingDirectory)
            } catch {
                return await fail(
                    job: job,
                    recordingID: job.recordingID,
                    diagnosticCode: "audio_staging_failed",
                    retryable: true
                )
            }
            defer { try? FileManager.default.removeItem(at: stagedURL) }

            // Network staging suspends; revalidate identity before processing.
            guard recordingLocation(for: job, in: store) != nil else {
                return await fail(
                    job: job, recordingID: job.recordingID,
                    diagnosticCode: "workspace_recording_missing", retryable: true
                )
            }
            let heartbeat = Task {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(120))
                    guard !Task.isCancelled else { return }
                    _ = try await backend.renew(jobID: job.jobID, leaseDurationSeconds: 300)
                }
            }
            let summary = await store.processLocalRecordingForSpeechTranscription(
                recordingID: job.recordingID,
                services: services,
                stagedAudioURL: stagedURL,
                now: now
            )
            heartbeat.cancel()
            let heartbeatFailed: Bool
            do {
                try await heartbeat.value
                heartbeatFailed = false
            } catch is CancellationError {
                heartbeatFailed = false
            } catch {
                heartbeatFailed = true
            }

            guard let finalLocation = recordingLocation(for: job, in: store) else {
                return await fail(
                    job: job,
                    recordingID: job.recordingID,
                    diagnosticCode: "workspace_recording_missing",
                    retryable: true
                )
            }
            if heartbeatFailed {
                return await fail(
                    job: job,
                    recordingID: job.recordingID,
                    diagnosticCode: "job_lease_renewal_failed",
                    retryable: true
                )
            }
            guard summary.completedCount == 1 else {
                let diagnostic = store.projects[finalLocation.projectIndex]
                    .recordings[finalLocation.recordingIndex]
                    .processingDiagnostic
                return await publishAndFail(
                    job: job, store: store, now: now,
                    diagnosticCode: diagnostic?.isRetryable == false
                        ? "speech_processing_unavailable"
                        : "speech_processing_failed",
                    retryable: diagnostic?.isRetryable ?? true
                )
            }
            return await publishAndComplete(job: job, store: store, now: now)
        } catch {
            return .failed(
                recordingID: nil,
                diagnosticCode: "workspace_sync_failed",
                retryable: true
            )
        }
    }

    @MainActor
    private func publishAndFail(
        job: BackendEnrichmentJob,
        store: IdeaForgeStore,
        now: Date,
        diagnosticCode: String,
        retryable: Bool
    ) async -> MacRecordingEnrichmentResult {
        do {
            _ = try await backend.renew(jobID: job.jobID, leaseDurationSeconds: 300)
            guard store.privacyMode != .privateLocal else {
                return await fail(
                    job: job, recordingID: job.recordingID,
                    diagnosticCode: "workspace_sync_disabled", retryable: true
                )
            }
            let publication = try await workspaceSynchronizer.pushLocalSnapshot(from: store, syncedAt: now)
            guard publication.pushedLocalSnapshot, publication.acceptedLocalUpdatedAt != nil else {
                return await fail(
                    job: job, recordingID: job.recordingID,
                    diagnosticCode: "workspace_publish_unconfirmed", retryable: true
                )
            }
        } catch {
            return await fail(
                job: job, recordingID: job.recordingID,
                diagnosticCode: "workspace_publish_failed", retryable: true
            )
        }
        return await fail(
            job: job, recordingID: job.recordingID,
            diagnosticCode: diagnosticCode, retryable: retryable
        )
    }

    @MainActor
    private func publishAndComplete(
        job: BackendEnrichmentJob,
        store: IdeaForgeStore,
        now: Date
    ) async -> MacRecordingEnrichmentResult {
        // Revalidate ownership before publishing, including recovery of an
        // already-transcribed local checkpoint. Completion alone is too late.
        do {
            _ = try await backend.renew(jobID: job.jobID, leaseDurationSeconds: 300)
        } catch {
            return await fail(
                job: job,
                recordingID: job.recordingID,
                diagnosticCode: "job_lease_renewal_failed",
                retryable: true
            )
        }
        do {
            guard store.privacyMode != .privateLocal else {
                return await fail(
                    job: job, recordingID: job.recordingID,
                    diagnosticCode: "workspace_sync_disabled", retryable: true
                )
            }
            let publish = try await workspaceSynchronizer.pushLocalSnapshot(from: store, syncedAt: now)
            guard publish.pushedLocalSnapshot,
                  let acceptedLocalUpdatedAt = publish.acceptedLocalUpdatedAt else {
                return await fail(
                    job: job,
                    recordingID: job.recordingID,
                    diagnosticCode: "workspace_publish_unconfirmed",
                    retryable: true
                )
            }
            _ = try await backend.complete(
                jobID: job.jobID,
                workspaceUpdatedAt: acceptedLocalUpdatedAt
            )
            let title = store.projects.first(where: { $0.id == job.ideaProjectID })?.title ?? "Ready"
            return .completed(recordingID: job.recordingID, title: title)
        } catch {
            return await fail(
                job: job,
                recordingID: job.recordingID,
                diagnosticCode: "workspace_publish_failed",
                retryable: true
            )
        }
    }

    private func fail(
        job: BackendEnrichmentJob,
        recordingID: String?,
        diagnosticCode: String,
        retryable: Bool
    ) async -> MacRecordingEnrichmentResult {
        _ = try? await backend.fail(
            jobID: job.jobID,
            diagnosticCode: diagnosticCode,
            retryable: retryable
        )
        return .failed(
            recordingID: recordingID,
            diagnosticCode: diagnosticCode,
            retryable: retryable
        )
    }

    @MainActor
    private func recordingLocation(
        for job: BackendEnrichmentJob,
        in store: IdeaForgeStore
    ) -> (projectIndex: Int, recordingIndex: Int)? {
        guard let projectIndex = store.projects.firstIndex(where: { $0.id == job.ideaProjectID }),
              let recordingIndex = store.projects[projectIndex].recordings.firstIndex(where: {
                  $0.id == job.recordingID
                      && $0.ideaProjectID == job.ideaProjectID
                      && $0.audioObjectKey == job.objectKey
              }) else {
            return nil
        }
        return (projectIndex, recordingIndex)
    }

    @MainActor
    private func canResumeTransientCheckpoint(
        for job: BackendEnrichmentJob,
        in store: IdeaForgeStore
    ) -> Bool {
        guard store.syncHealth.lastRemoteWorkspaceUpdatedAt != nil,
              let location = recordingLocation(for: job, in: store) else {
            return false
        }
        let recording = store.projects[location.projectIndex].recordings[location.recordingIndex]
        if recording.syncStatus == .uploaded {
            return true
        }
        return recording.syncStatus == .failed && recording.processingDiagnostic != nil
    }
}

extension MacRecordingEnrichmentProcessor: MacRecordingEnrichmentProcessing {}
