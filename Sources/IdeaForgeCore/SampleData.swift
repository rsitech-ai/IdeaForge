import AVFoundation
import Foundation

public enum TaskFirstFixtureState: CaseIterable, Equatable, Sendable {
    case clean
    case queuedUpload
    case failedUpload
    case offlineWatch
    case syncConflict
}

public enum SampleData {
    public static let now = Date(timeIntervalSince1970: 1_782_746_400)

    public static func taskFirstStore(state: TaskFirstFixtureState) -> IdeaForgeStore {
        switch state {
        case .clean:
            return taskFirstCleanStore()
        case .queuedUpload, .failedUpload:
            return taskFirstUploadStore(state: state)
        case .offlineWatch:
            let store = taskFirstCleanStore()
            store.syncHealth.watchReachable = false
            return store
        case .syncConflict:
            return syncConflictStore()
        }
    }

    public static func store() -> IdeaForgeStore {
        IdeaForgeStore(
            projects: [ideaForgeProject, localOnlyProject],
            workflowTemplates: DefaultWorkflows.templates,
            privacyMode: .privateLocal,
            syncHealth: SyncHealth(
                watchReachable: true,
                queuedUploads: 2,
                lastSuccessfulSync: now.addingTimeInterval(-900),
                lastActivity: WorkspaceSyncActivityReceipt(
                    source: .backgroundAutoSync,
                    status: .blocked,
                    title: "Auto-sync paused",
                    detail: "One failed item needs review before backend and Mac handoff continue.",
                    occurredAt: now.addingTimeInterval(-300)
                ),
                failingItems: 1
            )
        )
    }

    public static func publishedHandoffStore() -> IdeaForgeStore {
        IdeaForgeStore(
            projects: [publishedHandoffProject],
            workflowTemplates: DefaultWorkflows.templates,
            privacyMode: .standardCloud,
            syncHealth: SyncHealth(
                watchReachable: true,
                queuedUploads: 0,
                lastSuccessfulSync: now,
                lastRemoteWorkspaceUpdatedAt: now,
                lastActivity: WorkspaceSyncActivityReceipt(
                    source: .manualPublish,
                    status: .success,
                    title: "Workspace published",
                    detail: "Backend receipt is current for Mac handoff.",
                    occurredAt: now
                ),
                failingItems: 0
            ),
            updatedAt: now
        )
    }

    public static func localOnlyCleanStore() -> IdeaForgeStore {
        IdeaForgeStore(
            projects: [localOnlyCleanProject],
            workflowTemplates: DefaultWorkflows.templates,
            privacyMode: .privateLocal,
            syncHealth: SyncHealth(
                watchReachable: false,
                queuedUploads: 0,
                lastSuccessfulSync: now,
                failingItems: 0
            ),
            updatedAt: now
        )
    }

    public static func syncConflictStore() -> IdeaForgeStore {
        let store = self.store()
        store.syncHealth.syncConflictStatus = WorkspaceSyncConflictStatus(
            localOnlyUploadJobCount: 1,
            localOnlyRecordingCount: 1,
            detectedAt: now,
            reviewItems: [
                WorkspaceSyncConflictReviewItem(
                    id: "upload:upload_rec_watch_2",
                    kind: .localUploadJob,
                    projectTitle: "IdeaForge",
                    sourceLabel: "Watch",
                    statusLabel: "Queued",
                    detail: "Apple Watch, 96s, attempt 0"
                ),
                WorkspaceSyncConflictReviewItem(
                    id: "recording:rec_watch_2",
                    kind: .localRecording,
                    projectTitle: "IdeaForge",
                    sourceLabel: "Watch",
                    statusLabel: "On iPhone",
                    detail: "Apple Watch, 96s, available locally"
                )
            ]
        )
        return store
    }

    public static func customItemSyncConflictStore() -> IdeaForgeStore {
        let store = self.store()
        let collectionConflictReport = WorkspaceSyncConflictReport(
            localOnlyUploadJobIDs: [],
            localOnlyRecordingIDs: [],
            projectContentConflicts: [
                WorkspaceSyncProjectConflict(
                    projectID: "idea_ideaforge",
                    projectTitle: "IdeaForge",
                    localUpdatedAt: now,
                    remoteUpdatedAt: now.addingTimeInterval(60),
                    fields: [
                        .questions,
                        .assumptions,
                        .validationExperiments,
                        .codexTasks,
                        .workflowRuns
                    ]
                )
            ]
        )
        let generatedStatus = WorkspaceSyncConflictStatus(
            report: collectionConflictReport,
            localState: store.workspaceState(now: now),
            detectedAt: now
        )
        let focusedItemIDs: Set<String> = [
            "project:idea_ideaforge:assumptions:item:assumption_bridge",
            "project:idea_ideaforge:codexTasks:item:task_bootstrap",
            "project:idea_ideaforge:questions:item:q_first_user",
            "project:idea_ideaforge:validationExperiments:item:exp_builder_interviews",
            "project:idea_ideaforge:workflowRuns:item:run_sample_failed_prd"
        ]
        store.syncHealth.syncConflictStatus = WorkspaceSyncConflictStatus(
            localOnlyUploadJobCount: 0,
            localOnlyRecordingCount: 0,
            localProjectContentConflictCount: 1,
            detectedAt: now,
            reviewItems: generatedStatus.reviewItems.filter { item in
                item.kind == .projectCollectionItem && focusedItemIDs.contains(item.id)
            }
        )
        return store
    }

    private static func taskFirstCleanStore() -> IdeaForgeStore {
        IdeaForgeStore(
            projects: [taskFirstFixtureProject(recordings: [])],
            workflowTemplates: DefaultWorkflows.templates,
            selectedProjectID: "idea_task_first_fixture",
            privacyMode: .privateLocal,
            syncHealth: SyncHealth(
                watchReachable: true,
                queuedUploads: 0,
                lastSuccessfulSync: now,
                failingItems: 0
            ),
            updatedAt: now
        )
    }

    private static func taskFirstUploadStore(state: TaskFirstFixtureState) -> IdeaForgeStore {
        let isFailed = state == .failedUpload
        let audioPath = taskFirstFixtureAudioPath()
        var recording = Recording(
            id: "rec_task_first_upload",
            ideaProjectID: "idea_task_first_fixture",
            deviceName: "Apple Watch",
            durationSeconds: 42,
            localFileStatus: isFailed ? .failed : .available,
            syncStatus: isFailed ? .failed : .transferredToIPhone,
            localAudioPath: audioPath,
            languageHint: "en",
            createdAt: now,
            markerOffsets: []
        )
        if isFailed {
            recording.processingDiagnostic = RecordingProcessingDiagnostic(
                code: .backendProviderFailure,
                message: "Backend transcription did not complete.",
                isRetryable: true,
                failedAt: now
            )
        }
        let job = UploadJob(
            id: "upload_rec_task_first_upload",
            recordingID: recording.id,
            ideaProjectID: recording.ideaProjectID,
            localAudioPath: audioPath,
            status: isFailed ? .permanentlyFailed : .queued,
            attemptCount: isFailed ? UploadQueuePolicy.maximumAttempts : 0,
            nextAttemptAt: now,
            lastErrorMessage: isFailed ? "HTTP 503" : nil,
            failureCategory: isFailed ? .server : nil,
            createdAt: now,
            updatedAt: now
        )

        var recordings = [recording]
        var uploadJobs = [job]
        if isFailed {
            let activeStates: [(String, UploadJobStatus, Int, UploadFailureCategory?)] = [
                ("queued", .queued, 0, nil),
                ("uploading", .uploading, 1, nil),
                ("retrying", .waitingForRetry, 1, .connectivity)
            ]
            for (index, fixture) in activeStates.enumerated() {
                let recordingID = "rec_task_first_\(fixture.0)"
                let activeRecording = Recording(
                    id: recordingID,
                    ideaProjectID: "idea_task_first_fixture",
                    deviceName: index == 1 ? "iPhone" : "Apple Watch",
                    durationSeconds: 18 + index,
                    localFileStatus: .available,
                    syncStatus: index == 1 ? .pending : .transferredToIPhone,
                    localAudioPath: audioPath,
                    languageHint: "en",
                    createdAt: now.addingTimeInterval(Double(-(index + 1) * 60)),
                    markerOffsets: []
                )
                recordings.append(activeRecording)
                uploadJobs.append(
                    UploadJob(
                        id: "upload_\(recordingID)",
                        recordingID: recordingID,
                        ideaProjectID: activeRecording.ideaProjectID,
                        localAudioPath: audioPath,
                        status: fixture.1,
                        attemptCount: fixture.2,
                        nextAttemptAt: now,
                        lastErrorMessage: fixture.1 == .waitingForRetry ? "The request timed out." : nil,
                        failureCategory: fixture.3,
                        createdAt: activeRecording.createdAt,
                        updatedAt: activeRecording.createdAt
                    )
                )
            }
        }

        return IdeaForgeStore(
            projects: [taskFirstFixtureProject(recordings: recordings)],
            workflowTemplates: DefaultWorkflows.templates,
            uploadJobs: uploadJobs,
            selectedProjectID: "idea_task_first_fixture",
            privacyMode: .privateLocal,
            syncHealth: SyncHealth(
                watchReachable: true,
                queuedUploads: isFailed ? 0 : 1,
                lastSuccessfulSync: now,
                failingItems: 0
            ),
            updatedAt: now
        )
    }

    private static func taskFirstFixtureProject(recordings: [Recording]) -> IdeaProject {
        IdeaProject(
            id: "idea_task_first_fixture",
            title: "Task-first fixture",
            status: .draft,
            source: .watch,
            createdAt: now,
            updatedAt: now,
            summary: "Deterministic task-first fixture.",
            tags: [.appIdea],
            score: IdeaScore(confidence: 0.5, completeness: 0.5, risk: 0.5),
            transcript: Transcript(cleanText: "Deterministic fixture.", segments: [], unclearFragments: []),
            recordings: recordings,
            questions: [],
            artifacts: [],
            assumptions: [],
            validationExperiments: [],
            codexTasks: []
        )
    }

    private static func taskFirstFixtureAudioPath() -> String {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appending(path: "IdeaForgeTaskFirstFixtures", directoryHint: .isDirectory)
        let audioURL = directory.appending(path: "retained-audio.m4a")

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: audioURL.path) {
                let attributes = try fileManager.attributesOfItem(atPath: audioURL.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular else {
                    preconditionFailure("Unable to stage deterministic fixture audio.")
                }
            }
            return try writeTaskFirstFixtureAudio(to: audioURL)
        } catch {
            preconditionFailure("Unable to stage deterministic fixture audio.")
        }
    }

    private static func writeTaskFirstFixtureAudio(to url: URL) throws -> String {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }

        let sampleRate = 44_100.0
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000
        ]
        do {
            let audioFile = try AVAudioFile(forWriting: url, settings: settings)
            let frameCount = AVAudioFrameCount(sampleRate * 3)
            guard
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: audioFile.processingFormat,
                    frameCapacity: frameCount
                ),
                let samples = buffer.floatChannelData?[0]
            else {
                throw CocoaError(.fileWriteUnknown)
            }
            buffer.frameLength = frameCount
            for frame in 0..<Int(frameCount) {
                let phase = 2 * Double.pi * 440 * Double(frame) / sampleRate
                samples[frame] = Float(sin(phase) * 0.08)
            }
            try audioFile.write(from: buffer)
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw CocoaError(.fileWriteUnknown)
        }
        let audioFile = try AVAudioFile(forReading: url)
        guard audioFile.length > 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url.path
    }

    public static let publishedHandoffProject = IdeaProject(
        id: "idea_published_handoff",
        title: "Published Mac handoff",
        status: .readyForBuild,
        source: .iphone,
        createdAt: now.addingTimeInterval(-3600),
        updatedAt: now,
        summary: "A clean iPhone workspace with a current backend receipt ready for Mac review.",
        tags: [.appIdea, .business],
        score: IdeaScore(confidence: 0.88, completeness: 0.86, risk: 0.18),
        transcript: Transcript(
            cleanText: "The iPhone workspace has already published its latest snapshot for Mac handoff.",
            segments: [],
            unclearFragments: []
        ),
        recordings: [],
        questions: [],
        artifacts: [],
        assumptions: [],
        validationExperiments: [],
        codexTasks: []
    )

    public static let localOnlyCleanProject = IdeaProject(
        id: "idea_local_only_clean",
        title: "Local-only capture",
        status: .validated,
        source: .iphone,
        createdAt: now.addingTimeInterval(-2400),
        updatedAt: now,
        summary: "A private iPhone workspace with no queued uploads or backend handoff receipt.",
        tags: [.feature],
        score: IdeaScore(confidence: 0.80, completeness: 0.78, risk: 0.24),
        transcript: Transcript(
            cleanText: "Private mode keeps this workspace on device until backend sync is enabled.",
            segments: [],
            unclearFragments: []
        ),
        recordings: [],
        questions: [],
        artifacts: [],
        assumptions: [],
        validationExperiments: [],
        codexTasks: []
    )

    public static let ideaForgeProject = IdeaProject(
        id: "idea_ideaforge",
        title: "IdeaForge",
        status: .readyForBuild,
        source: .watch,
        createdAt: now.addingTimeInterval(-7200),
        updatedAt: now,
        summary: "Speak an idea into Watch, open Mac, and get a validated product plan plus Codex-ready implementation tasks.",
        tags: [.appIdea, .business, .research],
        score: IdeaScore(confidence: 0.78, completeness: 0.64, risk: 0.42),
        transcript: Transcript(
            cleanText: "Build a product incubator that starts from messy voice notes and turns them into PRDs, roadmaps, validation plans, and Codex packets.",
            segments: [
                TranscriptSegment(id: "seg_1", startSeconds: 0, endSeconds: 42, text: "The core object is an idea project, not a recording.", isMarkedImportant: true),
                TranscriptSegment(id: "seg_2", startSeconds: 43, endSeconds: 138, text: "Watch records, iPhone bridges, backend orchestrates, Mac becomes the planning studio.", isMarkedImportant: true),
                TranscriptSegment(id: "seg_3", startSeconds: 139, endSeconds: 206, text: "The app should ask follow-up questions until the idea is strong enough to build.", isMarkedImportant: false)
            ],
            unclearFragments: ["exact pricing tiers", "first backend provider"]
        ),
        recordings: [
            Recording(
                id: "rec_watch_1",
                ideaProjectID: "idea_ideaforge",
                deviceName: "Apple Watch",
                durationSeconds: 312,
                localFileStatus: .uploaded,
                syncStatus: .ready,
                localAudioPath: nil,
                audioObjectKey: "audio/idea_ideaforge/rec_watch_1.m4a",
                languageHint: "en",
                createdAt: now.addingTimeInterval(-7200),
                markerOffsets: [42, 138]
            ),
            Recording(
                id: "rec_watch_2",
                ideaProjectID: "idea_ideaforge",
                deviceName: "Apple Watch",
                durationSeconds: 96,
                localFileStatus: .available,
                syncStatus: .transferredToIPhone,
                localAudioPath: "recordings/rec_watch_2.m4a",
                languageHint: "en",
                createdAt: now.addingTimeInterval(-1800),
                markerOffsets: [64]
            )
        ],
        questions: [
            Question(id: "q_first_user", prompt: "Who is the first user who needs this badly enough to pay?", answer: nil, isBlocking: true),
            Question(id: "q_local_mode", prompt: "Should private/local mode launch before cloud AI billing?", answer: "Private mode should be visible in onboarding, but cloud workflow can power the first Pro tier.", isBlocking: false)
        ],
        artifacts: [
            Artifact(
                id: "artifact_prd",
                kind: .prd,
                title: "Product Requirements Document",
                markdown: "## Goals\nCapture messy voice ideas and generate structured planning artifacts.\n\n## Non-goals\nDo not auto-run Codex without user review.",
                version: 1,
                createdBy: "ai",
                createdAt: now,
                sourceWorkflowRunID: "run_sample_codex"
            ),
            Artifact(
                id: "artifact_validation",
                kind: .validationPlan,
                title: "Startup Validation Plan",
                markdown: "Interview 10 builders who capture ideas on the move and measure whether Codex packet export saves implementation prep time.",
                version: 1,
                createdBy: "ai",
                createdAt: now,
                sourceWorkflowRunID: "run_sample_codex"
            )
        ],
        assumptions: [
            Assumption(id: "assumption_bridge", text: "iPhone bridge materially improves Watch recording reliability.", confidence: 0.82, evidence: "WatchConnectivity supports paired transfer and iPhone can own upload queue."),
            Assumption(id: "assumption_codex", text: "Codex packets are more valuable than raw transcript export.", confidence: 0.74, evidence: "Raw transcripts are ambiguous; engineering packets include architecture, tasks, and acceptance criteria.")
        ],
        validationExperiments: [
            ValidationExperiment(
                id: "exp_builder_interviews",
                title: "Builder workflow interviews",
                metric: "At least 7/10 builders say the packet saves 30+ minutes.",
                goNoGoCriteria: "Proceed if packet review is faster than manual PRD/task drafting."
            )
        ],
        codexTasks: [
            CodexTask(
                id: "task_bootstrap",
                title: "Bootstrap native Apple project",
                acceptanceCriteria: [
                    "Shared domain models compile on Apple platforms",
                    "macOS studio opens with sample Idea Projects",
                    "iPhone and Watch shells expose sync/capture states"
                ],
                testPlan: [
                    "Run Swift core tests",
                    "Build macOS app through XcodeGen project",
                    "Verify app process launches"
                ]
            )
        ],
        workflowRuns: [
            WorkflowRun(
                id: "run_sample_codex",
                templateID: "wf_codex_packet",
                templateName: "Codex Build Packet",
                status: .completed,
                stepRuns: [
                    StepRun(
                        id: "step_run_sample_architecture",
                        stepID: "step_architecture",
                        stepName: "Draft technical architecture",
                        status: .completed,
                        outputArtifactIDs: ["artifact_prd"],
                        startedAt: now.addingTimeInterval(-600),
                        completedAt: now.addingTimeInterval(-540)
                    ),
                    StepRun(
                        id: "step_run_sample_codex_tasks",
                        stepID: "step_codex_tasks",
                        stepName: "Generate Codex task bundle",
                        status: .completed,
                        outputArtifactIDs: ["artifact_validation"],
                        startedAt: now.addingTimeInterval(-540),
                        completedAt: now.addingTimeInterval(-480)
                    )
                ],
                artifactIDs: ["artifact_prd", "artifact_validation"],
                startedAt: now.addingTimeInterval(-600),
                completedAt: now.addingTimeInterval(-480),
                evaluation: WorkflowRunEvaluation(
                    readinessScore: 0.72,
                    decision: .blocked,
                    generatedArtifactCount: 2,
                    blockingIssueCount: 1,
                    blockers: ["1 blocking question needs an answer."]
                )
            ),
            WorkflowRun(
                id: "run_sample_failed_prd",
                templateID: "wf_prd",
                templateName: "App Idea -> PRD",
                status: .failed,
                stepRuns: [
                    StepRun(
                        id: "step_run_sample_failed_personas",
                        stepID: "step_personas",
                        stepName: "Define personas",
                        status: .failed,
                        outputArtifactIDs: [],
                        startedAt: now.addingTimeInterval(-1_200),
                        completedAt: now.addingTimeInterval(-1_140),
                        errorMessage: "Workflow failed."
                    ),
                    StepRun(
                        id: "step_run_sample_failed_prd",
                        stepID: "step_prd",
                        stepName: "Generate PRD",
                        status: .failed,
                        outputArtifactIDs: [],
                        startedAt: now.addingTimeInterval(-1_200),
                        completedAt: now.addingTimeInterval(-1_140),
                        errorMessage: "Workflow failed."
                    )
                ],
                artifactIDs: [],
                startedAt: now.addingTimeInterval(-1_200),
                completedAt: now.addingTimeInterval(-1_140),
                errorMessage: "Workflow failed."
            )
        ]
    )

    public static let localOnlyProject = IdeaProject(
        id: "idea_private_voice",
        title: "Private voice idea vault",
        status: .draft,
        source: .iphone,
        createdAt: now.addingTimeInterval(-3600),
        updatedAt: now.addingTimeInterval(-1200),
        summary: "A local-first mode for sensitive product ideas that asks before cloud AI.",
        tags: [.feature, .business],
        score: IdeaScore(confidence: 0.62, completeness: 0.48, risk: 0.57),
        transcript: Transcript(cleanText: "Users need a private capture mode for early ideas.", segments: [], unclearFragments: []),
        recordings: [
            Recording(
                id: "rec_phone_1",
                ideaProjectID: "idea_private_voice",
                deviceName: "iPhone",
                durationSeconds: 74,
                localFileStatus: .available,
                syncStatus: .pending,
                localAudioPath: "recordings/rec_phone_1.m4a",
                languageHint: "en",
                createdAt: now.addingTimeInterval(-3600),
                markerOffsets: []
            )
        ],
        questions: [
            Question(id: "q_retention", prompt: "What should the default audio retention policy be?", answer: nil, isBlocking: true)
        ],
        artifacts: [],
        assumptions: [],
        validationExperiments: [],
        codexTasks: []
    )
}
