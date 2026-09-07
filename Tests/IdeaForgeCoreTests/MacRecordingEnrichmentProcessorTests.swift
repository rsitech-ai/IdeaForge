import Foundation
import XCTest
@testable import IdeaForgeCore

@MainActor
final class MacRecordingEnrichmentProcessorTests: XCTestCase {
    func testProcessorDoesNotPublishWhenItsLeaseCannotBeRenewed() async throws {
        let store = SampleData.watchRelayStore(state: .received)
        store.projects[0].recordings[0].syncStatus = .ready
        store.projects[0].recordings[0].audioObjectKey = "recordings/lease.m4a"
        let recording = try XCTUnwrap(store.projects.first?.recordings.first)
        let backend = TestRecordingEnrichmentBackend(
            job: BackendEnrichmentJob(
                jobID: "job_lost_lease", recordingID: recording.id,
                ideaProjectID: recording.ideaProjectID, objectKey: "recordings/lease.m4a",
                byteCount: 1, sha256: String(repeating: "a", count: 64),
                attemptCount: 1, leaseExpiresAt: Date().addingTimeInterval(300)
            ),
            audio: Data([1]), rejectsRenewal: true
        )
        let synchronizer = TestWorkspaceSynchronizer(remoteUpdatedAt: store.updatedAt)
        let processor = MacRecordingEnrichmentProcessor(
            backend: backend, workspaceSynchronizer: synchronizer,
            stagingDirectory: FileManager.default.temporaryDirectory
        )
        let result = await processor.processNext(in: store)
        XCTAssertEqual(result, .failed(recordingID: recording.id,
                                      diagnosticCode: "job_lease_renewal_failed", retryable: true))
        XCTAssertNil(synchronizer.publishedState)
        let completed = await backend.completedJobID()
        XCTAssertNil(completed)
    }

    func testLoopProcessesAvailableJobsUntilIdleWithinBound() async {
        let processor = SequencedMacEnrichmentProcessor(
            results: [
                .completed(recordingID: "rec_1", title: "First"),
                .completed(recordingID: "rec_2", title: "Second"),
                .idle,
                .completed(recordingID: "rec_unreachable", title: "Unreachable"),
            ]
        )
        let loop = MacRecordingEnrichmentLoop(processor: processor, maxJobsPerRun: 4)

        let summary = await loop.run(in: SampleData.publishedHandoffStore(), now: SampleData.now)

        XCTAssertEqual(summary.attemptedCount, 3)
        XCTAssertEqual(summary.completedCount, 2)
        XCTAssertEqual(summary.failedCount, 0)
        XCTAssertTrue(summary.reachedIdle)
        let callCount = await processor.callCount()
        XCTAssertEqual(callCount, 3)
    }

    func testProcessorStagesEnrichesPublishesCompletesAndRemovesTemporaryAudio() async throws {
        let now = Date(timeIntervalSince1970: 20_000)
        let objectKey = "recordings/object-watch.m4a"
        let recording = Recording(
            id: "rec_watch_mac",
            ideaProjectID: "idea_watch_mac",
            deviceName: "Apple Watch",
            durationSeconds: 14,
            localFileStatus: .uploaded,
            syncStatus: .uploaded,
            audioObjectKey: objectKey,
            languageHint: "en",
            createdAt: now,
            markerOffsets: []
        )
        let project = IdeaProject(
            id: "idea_watch_mac",
            title: "Watch Idea",
            status: .inbox,
            source: .watch,
            createdAt: now,
            updatedAt: now,
            summary: "Voice idea transferred from Watch.",
            tags: [.appIdea],
            score: IdeaScore(confidence: 0.2, completeness: 0.1, risk: 0.7),
            transcript: Transcript(
                cleanText: "Voice idea transferred from Watch.",
                segments: [],
                unclearFragments: []
            ),
            recordings: [recording],
            questions: [],
            artifacts: [],
            assumptions: [],
            validationExperiments: [],
            codexTasks: []
        )
        let store = IdeaForgeStore(
            projects: [project],
            workflowTemplates: DefaultWorkflows.templates,
            privacyMode: .standardCloud,
            syncHealth: SyncHealth(
                watchReachable: false,
                queuedUploads: 0,
                lastSuccessfulSync: now,
                lastRemoteWorkspaceUpdatedAt: now,
                failingItems: 0
            ),
            updatedAt: now
        )
        let audio = Data("mac-stage-audio".utf8)
        let backend = TestRecordingEnrichmentBackend(
            job: BackendEnrichmentJob(
                jobID: "job_watch_mac",
                recordingID: recording.id,
                ideaProjectID: project.id,
                objectKey: objectKey,
                byteCount: audio.count,
                sha256: String(repeating: "a", count: 64),
                attemptCount: 1,
                leaseExpiresAt: now.addingTimeInterval(300)
            ),
            audio: audio
        )
        let synchronizer = TestWorkspaceSynchronizer(remoteUpdatedAt: now)
        let services = IdeaForgeServices(
            transcription: TestMacTranscriptionService(
                transcript: Transcript(
                    cleanText: "Build a private focus app for recurring deep-work sessions.",
                    segments: [],
                    unclearFragments: []
                )
            ),
            titleGeneration: SystemFoundationTitleGenerator(
                availability: { _ in .available },
                generation: { _ in "Private Focus Sessions" }
            ),
            workflow: LocalWorkflowExecutionService(),
            syncQueue: LocalSyncQueueService(),
            export: LocalExportService()
        )
        let stagingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IdeaForgeMacProcessorTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }
        let processor = MacRecordingEnrichmentProcessor(
            backend: backend,
            workspaceSynchronizer: synchronizer,
            services: services,
            stagingDirectory: stagingDirectory
        )

        let result = await processor.processNext(in: store, now: now.addingTimeInterval(60))

        XCTAssertEqual(
            result,
            .completed(recordingID: recording.id, title: "Private Focus Sessions")
        )
        XCTAssertEqual(store.projects.first?.title, "Private Focus Sessions")
        XCTAssertEqual(
            store.projects.first?.transcript.cleanText,
            "Build a private focus app for recurring deep-work sessions."
        )
        XCTAssertEqual(store.projects.first?.recordings.first?.syncStatus, .ready)
        XCTAssertEqual(store.projects.first?.recordings.first?.localFileStatus, .uploaded)
        XCTAssertNil(store.projects.first?.recordings.first?.localAudioPath)
        let completedJobID = await backend.completedJobID()
        let failedJob = await backend.failedJob()
        XCTAssertEqual(completedJobID, "job_watch_mac")
        XCTAssertNil(failedJob)
        let published = synchronizer.publishedState
        XCTAssertEqual(published?.projects.first?.title, "Private Focus Sessions")
        let projectData = try JSONEncoder().encode(XCTUnwrap(published?.projects.first))
        let projectJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: projectData) as? [String: Any])
        let provenance = try XCTUnwrap(projectJSON["titleProvenance"] as? [String: Any])
        XCTAssertEqual(provenance["providerIdentifier"] as? String, "apple.foundation-models")
        XCTAssertEqual(provenance["recordingID"] as? String, "rec_watch_mac")
        XCTAssertEqual(provenance["generatedTitle"] as? String, "Private Focus Sessions")
        XCTAssertEqual(provenance["transcriptSHA256"] as? String,
                       "8cd54bf27bce0d2fd54743ba2538775f7848f36f0309fd84dd39717b95560a3a")
        XCTAssertNotNil(provenance["generatedAt"])
        let decoded = try JSONDecoder().decode(IdeaProject.self, from: projectData)
        XCTAssertEqual(decoded, published?.projects.first)
        XCTAssertNil(published?.projects.first?.recordings.first?.localAudioPath)
        XCTAssertEqual(
            (try? FileManager.default.contentsOfDirectory(at: stagingDirectory, includingPropertiesForKeys: nil)) ?? [],
            []
        )
    }

    func testProcessorReturnsIdleWithoutStagingWhenQueueIsEmpty() async {
        let store = SampleData.publishedHandoffStore()
        let backend = TestRecordingEnrichmentBackend(job: nil, audio: Data())
        let synchronizer = TestWorkspaceSynchronizer(remoteUpdatedAt: SampleData.now)
        let processor = MacRecordingEnrichmentProcessor(
            backend: backend,
            workspaceSynchronizer: synchronizer,
            services: IdeaForgeServices.local,
            stagingDirectory: FileManager.default.temporaryDirectory
        )

        let result = await processor.processNext(in: store, now: SampleData.now)

        XCTAssertEqual(result, .idle)
        let stageCount = await backend.stageCount()
        XCTAssertEqual(stageCount, 0)
    }

    func testProcessorResumesClaimedRetryableCheckpointWhenTransientPublishIsBlocked() async throws {
        let now = Date(timeIntervalSince1970: 30_000)
        let objectKey = "recordings/interrupted-watch.m4a"
        let diagnostic = RecordingProcessingDiagnostic(
            code: .transcriptionFailed,
            message: "Transcription was interrupted and will retry.",
            isRetryable: true,
            failedAt: now
        )
        let recording = Recording(
            id: "rec_interrupted_watch",
            ideaProjectID: "idea_interrupted_watch",
            deviceName: "Apple Watch",
            durationSeconds: 18,
            localFileStatus: .uploaded,
            syncStatus: .failed,
            audioObjectKey: objectKey,
            languageHint: "en",
            createdAt: now,
            markerOffsets: [],
            processingDiagnostic: diagnostic
        )
        let project = IdeaProject(
            id: recording.ideaProjectID,
            title: "Watch Idea",
            status: .inbox,
            source: .watch,
            createdAt: now,
            updatedAt: now,
            summary: "Voice idea transferred from Watch.",
            tags: [.appIdea],
            score: IdeaScore(confidence: 0.2, completeness: 0.1, risk: 0.7),
            transcript: Transcript(
                cleanText: "Voice idea transferred from Watch.",
                segments: [],
                unclearFragments: []
            ),
            recordings: [recording],
            questions: [],
            artifacts: [],
            assumptions: [],
            validationExperiments: [],
            codexTasks: []
        )
        let store = IdeaForgeStore(
            projects: [project],
            workflowTemplates: DefaultWorkflows.templates,
            privacyMode: .standardCloud,
            syncHealth: SyncHealth(
                watchReachable: false,
                queuedUploads: 0,
                lastSuccessfulSync: now,
                lastRemoteWorkspaceUpdatedAt: now,
                failingItems: 0
            ),
            updatedAt: now.addingTimeInterval(60)
        )
        let audio = Data("interrupted-mac-stage-audio".utf8)
        let backend = TestRecordingEnrichmentBackend(
            job: BackendEnrichmentJob(
                jobID: "job_interrupted_watch",
                recordingID: recording.id,
                ideaProjectID: project.id,
                objectKey: objectKey,
                byteCount: audio.count,
                sha256: String(repeating: "b", count: 64),
                attemptCount: 2,
                leaseExpiresAt: now.addingTimeInterval(300)
            ),
            audio: audio
        )
        let synchronizer = TestWorkspaceSynchronizer(
            remoteUpdatedAt: now,
            synchronizeError: WorkspaceSyncPublicationBlockedError(
                message: "Transient processing state is not publishable."
            )
        )
        let services = IdeaForgeServices(
            transcription: TestMacTranscriptionService(
                transcript: Transcript(
                    cleanText: "Recovered speech after a Mac app restart.",
                    segments: [],
                    unclearFragments: []
                )
            ),
            titleGeneration: TestMacTitleGenerator(title: "Recovered Mac Recording"),
            workflow: LocalWorkflowExecutionService(),
            syncQueue: LocalSyncQueueService(),
            export: LocalExportService()
        )
        let stagingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IdeaForgeMacProcessorRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }
        let processor = MacRecordingEnrichmentProcessor(
            backend: backend,
            workspaceSynchronizer: synchronizer,
            services: services,
            stagingDirectory: stagingDirectory
        )

        let result = await processor.processNext(in: store, now: now.addingTimeInterval(120))

        XCTAssertEqual(
            result,
            .completed(recordingID: recording.id, title: "Recovered Mac Recording")
        )
        XCTAssertEqual(store.projects.first?.recordings.first?.syncStatus, .ready)
        XCTAssertEqual(store.projects.first?.transcript.cleanText, "Recovered speech after a Mac app restart.")
        let completedJobID = await backend.completedJobID()
        let failedJobID = await backend.failedJob()
        XCTAssertEqual(completedJobID, "job_interrupted_watch")
        XCTAssertNil(failedJobID)
    }
}

private actor SequencedMacEnrichmentProcessor: MacRecordingEnrichmentProcessing {
    private var results: [MacRecordingEnrichmentResult]
    private var calls = 0

    init(results: [MacRecordingEnrichmentResult]) {
        self.results = results
    }

    @MainActor
    func processNext(in store: IdeaForgeStore, now: Date) async -> MacRecordingEnrichmentResult {
        await nextResult()
    }

    private func nextResult() -> MacRecordingEnrichmentResult {
        calls += 1
        return results.isEmpty ? .idle : results.removeFirst()
    }

    func callCount() -> Int { calls }
}

private actor TestRecordingEnrichmentBackend: BackendRecordingEnrichmentServing {
    private var job: BackendEnrichmentJob?
    private let audio: Data
    private var stagedCount = 0
    private var completedID: String?
    private var failure: (String, String, Bool)?
    private let rejectsRenewal: Bool

    init(job: BackendEnrichmentJob?, audio: Data, rejectsRenewal: Bool = false) {
        self.job = job
        self.audio = audio
        self.rejectsRenewal = rejectsRenewal
    }

    func claimNextJob(leaseDurationSeconds: Int) async throws -> BackendEnrichmentJob? {
        defer { job = nil }
        return job
    }

    func stageAudio(for job: BackendEnrichmentJob, in stagingDirectory: URL) async throws -> URL {
        stagedCount += 1
        try FileManager.default.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let url = stagingDirectory.appendingPathComponent("fixture.m4a")
        try audio.write(to: url)
        return url
    }

    func renew(jobID: String, leaseDurationSeconds: Int) async throws -> BackendEnrichmentLeaseReceipt {
        if rejectsRenewal { throw URLError(.networkConnectionLost) }
        return BackendEnrichmentLeaseReceipt(
            jobID: jobID,
            status: "running",
            leaseExpiresAt: Date().addingTimeInterval(TimeInterval(leaseDurationSeconds))
        )
    }

    func complete(jobID: String, workspaceUpdatedAt: Date) async throws -> BackendEnrichmentJobReceipt {
        completedID = jobID
        return BackendEnrichmentJobReceipt(jobID: jobID, status: .completed)
    }

    func fail(
        jobID: String,
        diagnosticCode: String,
        retryable: Bool
    ) async throws -> BackendEnrichmentJobReceipt {
        failure = (jobID, diagnosticCode, retryable)
        return BackendEnrichmentJobReceipt(jobID: jobID, status: retryable ? .queued : .failed)
    }

    func completedJobID() -> String? { completedID }
    func failedJob() -> String? { failure?.0 }
    func stageCount() -> Int { stagedCount }
}

@MainActor
private final class TestWorkspaceSynchronizer: BackendWorkspaceSynchronizing {
    private let remoteUpdatedAt: Date
    private let synchronizeError: Error?
    private(set) var publishedState: WorkspaceState?

    init(remoteUpdatedAt: Date, synchronizeError: Error? = nil) {
        self.remoteUpdatedAt = remoteUpdatedAt
        self.synchronizeError = synchronizeError
    }

    func synchronize(store: IdeaForgeStore, syncedAt: Date) async throws -> WorkspaceSyncSummary {
        if let synchronizeError {
            throw synchronizeError
        }
        return WorkspaceSyncSummary(
            fetched: true,
            appliedRemoteSnapshot: false,
            remoteUpdatedAt: remoteUpdatedAt,
            localUpdatedAt: store.updatedAt
        )
    }

    func pushLocalSnapshot(from store: IdeaForgeStore, syncedAt: Date) async throws -> WorkspaceSyncSummary {
        publishedState = store.workspaceState()
        return WorkspaceSyncSummary(
            fetched: false,
            appliedRemoteSnapshot: false,
            pushedLocalSnapshot: true,
            remoteUpdatedAt: store.updatedAt,
            acceptedLocalUpdatedAt: store.updatedAt,
            localUpdatedAt: store.updatedAt
        )
    }
}

private struct TestMacTranscriptionService: TranscriptionService {
    var transcript: Transcript

    func transcript(for recording: Recording, hint: String) async throws -> Transcript {
        transcript
    }
}

private struct TestMacTitleGenerator: IdeaTitleGenerating {
    var title: String

    func availability(for localeIdentifier: String) async -> IdeaTitleGenerationAvailability {
        .available
    }

    func generateTitle(for request: IdeaTitleGenerationRequest) async throws -> IdeaTitleGenerationResult {
        IdeaTitleGenerationResult(title: title)
    }
}
