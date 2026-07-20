import Foundation

public enum ServiceMode: String, Codable, Sendable {
    case localMock
    case cloud
    case disabled
}

public struct RecordingDraft: Equatable, Sendable {
    public var projectTitle: String
    public var tag: IdeaTag
    public var source: IdeaSource
    public var durationSeconds: Int
    public var transcriptHint: String
    public var localAudioPath: String?
    public var markerOffsets: [Int]
    public var languageHint: String
    public var ideaProjectID: String?
    public var recordingID: String?

    public init(
        projectTitle: String,
        tag: IdeaTag,
        source: IdeaSource,
        durationSeconds: Int,
        transcriptHint: String,
        localAudioPath: String? = nil,
        markerOffsets: [Int] = [],
        languageHint: String = "en",
        ideaProjectID: String? = nil,
        recordingID: String? = nil
    ) {
        self.projectTitle = projectTitle
        self.tag = tag
        self.source = source
        self.durationSeconds = durationSeconds
        self.transcriptHint = transcriptHint
        self.localAudioPath = localAudioPath
        self.markerOffsets = markerOffsets
        self.languageHint = languageHint
        self.ideaProjectID = ideaProjectID
        self.recordingID = recordingID
    }
}

public protocol TranscriptionService: Sendable {
    func transcript(for recording: Recording, hint: String) async throws -> Transcript
}

public protocol WorkflowExecutionService: Sendable {
    func run(template: WorkflowTemplate, project: IdeaProject) async throws -> [Artifact]
}

public protocol SyncQueueService: Sendable {
    func enqueue(recording: Recording) async throws -> SyncStatus
}

public protocol ExportService: Sendable {
    func codexPacket(for project: IdeaProject) async throws -> EngineeringPacket
    func exportCodexPacket(for project: IdeaProject) async throws -> PacketExportResult
}

public struct AIProcessingSummary: Equatable, Sendable {
    public var attemptedCount: Int
    public var completedCount: Int
    public var failedCount: Int

    public init(attemptedCount: Int = 0, completedCount: Int = 0, failedCount: Int = 0) {
        self.attemptedCount = attemptedCount
        self.completedCount = completedCount
        self.failedCount = failedCount
    }
}

public struct WorkflowRetryProcessingSummary: Equatable, Sendable {
    public var attemptedCount: Int
    public var completedCount: Int
    public var failedCount: Int
    public var skippedCount: Int

    public init(
        attemptedCount: Int = 0,
        completedCount: Int = 0,
        failedCount: Int = 0,
        skippedCount: Int = 0
    ) {
        self.attemptedCount = attemptedCount
        self.completedCount = completedCount
        self.failedCount = failedCount
        self.skippedCount = skippedCount
    }
}

public struct WorkflowRetryCandidate: Equatable, Sendable {
    public var projectID: String
    public var runID: String
    public var nextRetryAt: Date

    public init(projectID: String, runID: String, nextRetryAt: Date) {
        self.projectID = projectID
        self.runID = runID
        self.nextRetryAt = nextRetryAt
    }
}

public enum WorkflowRetrySchedulePolicy {
    public static func dueCandidates(
        in projects: [IdeaProject],
        now: Date = Date(),
        limit: Int = Int.max
    ) -> [WorkflowRetryCandidate] {
        Array(
            scheduledCandidates(in: projects)
                .filter { $0.nextRetryAt <= now }
                .prefix(limit)
        )
    }

    public static func nextRunDate(in projects: [IdeaProject], now: Date = Date()) -> Date? {
        guard let earliest = scheduledCandidates(in: projects).map(\.nextRetryAt).min() else {
            return nil
        }
        return earliest <= now ? now : earliest
    }

    private static func scheduledCandidates(in projects: [IdeaProject]) -> [WorkflowRetryCandidate] {
        projects.flatMap { project in
            project.workflowRuns.compactMap { run -> WorkflowRetryCandidate? in
                guard run.status == .failed,
                      run.retryAttempt < WorkflowRetryPolicy.maximumAttempts,
                      let nextRetryAt = run.nextRetryAt,
                      !project.workflowRuns.contains(where: { $0.retryOfRunID == run.id }) else {
                    return nil
                }
                return WorkflowRetryCandidate(
                    projectID: project.id,
                    runID: run.id,
                    nextRetryAt: nextRetryAt
                )
            }
        }
        .sorted {
            if $0.nextRetryAt != $1.nextRetryAt {
                return $0.nextRetryAt < $1.nextRetryAt
            }
            return $0.runID < $1.runID
        }
    }
}

public struct WorkflowRetryProcessor: Sendable {
    public var services: IdeaForgeServices
    public var maxRunsPerPass: Int

    public init(services: IdeaForgeServices, maxRunsPerPass: Int = 2) {
        self.services = services
        self.maxRunsPerPass = maxRunsPerPass
    }

    @MainActor
    public func processDueRetries(
        in store: IdeaForgeStore,
        now: Date = Date()
    ) async -> WorkflowRetryProcessingSummary {
        let candidates = WorkflowRetrySchedulePolicy.dueCandidates(
            in: store.projects,
            now: now,
            limit: maxRunsPerPass
        )

        var summary = WorkflowRetryProcessingSummary()
        for candidate in candidates {
            summary.attemptedCount += 1
            await store.retryWorkflowRun(
                runID: candidate.runID,
                services: services,
                now: now
            )

            guard let project = store.projects.first(where: { $0.id == candidate.projectID }),
                  let retryRun = project.workflowRuns.first(where: { $0.retryOfRunID == candidate.runID }) else {
                summary.skippedCount += 1
                continue
            }

            switch retryRun.status {
            case .completed:
                summary.completedCount += 1
            case .failed:
                summary.failedCount += 1
            case .running:
                summary.skippedCount += 1
            }
        }

        return summary
    }
}

public struct ConfiguredWorkflowRetryProcessor: Sendable {
    public var backendConfigurationManager: BackendConfigurationManager
    public var maxRunsPerPass: Int

    public init(
        backendConfigurationManager: BackendConfigurationManager,
        maxRunsPerPass: Int = 2
    ) {
        self.backendConfigurationManager = backendConfigurationManager
        self.maxRunsPerPass = maxRunsPerPass
    }

    @MainActor
    public func processDueRetries(
        in store: IdeaForgeStore,
        accountUsageSummary: BackendAccountUsageSummary? = nil,
        now: Date = Date()
    ) async throws -> WorkflowRetryProcessingSummary {
        let dueCount = WorkflowRetrySchedulePolicy.dueCandidates(
            in: store.projects,
            now: now,
            limit: maxRunsPerPass
        ).count
        guard dueCount > 0 else { return WorkflowRetryProcessingSummary() }

        guard AIServicePolicy.allowsCloudAI(privacyMode: store.privacyMode),
              let configuration = try backendConfigurationManager.resolvedAIConfiguration() else {
            return WorkflowRetryProcessingSummary(skippedCount: dueCount)
        }

        let services = BackendAIServiceFactory.services(
            configuration: configuration,
            privacyMode: store.privacyMode,
            accountUsageSummary: accountUsageSummary
        )
        return await WorkflowRetryProcessor(
            services: services,
            maxRunsPerPass: maxRunsPerPass
        )
        .processDueRetries(in: store, now: now)
    }
}

public enum AIServicePolicy {
    public static func allowsCloudAI(privacyMode: PrivacyMode) -> Bool {
        switch privacyMode {
        case .privateLocal:
            return false
        case .standardCloud, .power:
            return true
        }
    }
}

public struct LocalTranscriptionService: TranscriptionService {
    public init() {}

    public func transcript(for recording: Recording, hint: String) async throws -> Transcript {
        let cleanText = hint.isEmpty ? "Untitled idea captured from \(recording.deviceName)." : hint
        return Transcript(
            cleanText: cleanText,
            segments: [
                TranscriptSegment(
                    id: "segment_\(recording.id)",
                    startSeconds: 0,
                    endSeconds: max(recording.durationSeconds, 1),
                    text: cleanText,
                    isMarkedImportant: !recording.markerOffsets.isEmpty
                )
            ],
            unclearFragments: []
        )
    }
}

public struct LocalWorkflowExecutionService: WorkflowExecutionService {
    public init() {}

    public func run(template: WorkflowTemplate, project: IdeaProject) async throws -> [Artifact] {
        let now = Date()
        return template.outputKinds.map { kind in
            Artifact(
                id: "artifact_\(kind.rawValue)_\(project.id)",
                kind: kind,
                title: "\(kind.label): \(project.title)",
                markdown: markdown(kind: kind, project: project, template: template),
                version: 1,
                createdBy: "local-workflow",
                createdAt: now
            )
        }
    }

    private func markdown(kind: ArtifactKind, project: IdeaProject, template: WorkflowTemplate) -> String {
        let baseMarkdown: String
        switch kind {
        case .ideaBrief:
            baseMarkdown = """
            # \(project.title)

            \(project.summary)

            ## Next Questions
            \(project.questions.map { "- \($0.prompt)" }.joined(separator: "\n"))
            """
        case .prd:
            baseMarkdown = """
            # PRD: \(project.title)

            ## Goals
            Turn captured voice notes into reviewed product artifacts.

            ## Acceptance Criteria
            - Transcript is editable.
            - Questions are reviewable.
            - Artifacts are versioned.
            """
        case .roadmap:
            baseMarkdown = """
            # Roadmap

            1. Capture and sync.
            2. Transcribe and ask questions.
            3. Generate artifacts.
            4. Export Codex-ready tasks.
            """
        case .architecture:
            baseMarkdown = EngineeringPacketBuilder.packet(for: project)
                .files
                .first { $0.path == "architecture.md" }?
                .contents ?? "# Architecture\n\nPending."
        case .uxFlow:
            baseMarkdown = """
            # UX Flow: \(project.title)

            ## User Journey
            - Capture a raw idea from Watch, iPhone, or Mac.
            - Review transcript, clarifying questions, and generated artifacts.
            - Export only after human review marks the packet ready.

            ## Screens
            - Inbox, project overview, transcript, questions, workflow runs, artifacts, Codex handoff, account, and export review.

            ## States
            - Empty, queued, recording, uploading, failed, offline, permission denied, review needed, and ready-for-build states.

            ## Edge Cases
            - Interrupted upload, duplicate transfer, sync conflict, low storage, revoked permissions, and partial workflow failure.
            """
        case .dataModel:
            baseMarkdown = """
            # Data Model: \(project.title)

            ## Entities
            - IdeaProject, Recording, Transcript, Artifact, WorkflowRun, UploadJob, Question, Assumption, ValidationExperiment, and CodexTask.

            ## Relationships
            - Projects own recordings, transcript segments, questions, artifacts, assumptions, validation experiments, workflow runs, and Codex tasks.

            ## Storage
            - Local JSON workspace state, encrypted local audio objects, Keychain-held secrets, and scoped backend objects.

            ## Retention Rules
            - Do not delete local audio before confirmed safe state; avoid raw transcript, audio path, token, and credential logging.
            """
        case .apiDesign:
            baseMarkdown = """
            # API Design: \(project.title)

            ## Endpoints
            - Account provisioning, signed recording upload, workspace sync, restore drill, and provider-backed workflow execution.

            ## Payloads
            - Requests include stable project IDs, upload-job idempotency keys, content length, SHA-256 digests, schema names, and review status.

            ## Auth Scope
            - Use explicit account/session scope, Keychain-backed credentials, and no remote write without operator-approved configuration.

            ## Failure Modes
            - Fail closed on digest mismatch, idempotency conflict, missing configuration, revoked credentials, schema mismatch, and unsafe deletion state.
            """
        case .issueBundle:
            baseMarkdown = """
            # Issue Bundle: \(project.title)

            ## Issues
            - Build capture, transcription, review, workflow execution, sync, export, and release-readiness slices.

            ## Labels
            - macOS, iOS, watchOS, privacy, backend, workflow, verification, and release.

            ## Dependencies
            - Capture and storage precede upload; transcript review precedes artifact export; schema validation precedes Codex handoff.

            ## Acceptance Checks
            - Run swift test, backend self-test, production verifier, macOS launch smoke, iOS UI smoke, and privacy-safe log review.
            """
        case .codexTaskBundle:
            let packet = EngineeringPacketBuilder.packet(for: project)
                .files
                .map { "## \($0.path)\n\n\($0.contents)" }
                .joined(separator: "\n\n")
            baseMarkdown = """
            # Codex Packet

            ## Repo Context
            \(project.title) implementation packet generated from local project state.

            ## Tasks
            \(project.codexTasks.map { "- \($0.title)" }.joined(separator: "\n"))

            ## Checks
            - Run swift test.
            - Run the production verifier before handoff.

            ## Packet Files
            \(packet)
            """
        case .validationPlan:
            baseMarkdown = """
            # Validation Plan

            ## Riskiest Assumptions
            \(project.assumptions.map { "- \($0.text)" }.joined(separator: "\n"))

            ## Workflow
            \(template.name)
            """
        case .launchChecklist:
            baseMarkdown = """
            # Launch Checklist: \(project.title)

            ## Release Gates
            - Clean tests, clean production verifier, signing review, package validation, upload readiness, and fail-closed release blockers.

            ## App Store Assets
            - App icon, screenshots, privacy nutrition labels, support URL, review notes, subscription metadata, and export examples.

            ## Privacy Checks
            - Verify local-first storage, Keychain secrets, redacted logs, explicit backend opt-in, and data deletion/retention behavior.

            ## Monitoring Checks
            - Confirm telemetry categories, restore drill, upload retry visibility, sync health, crash review, and rollback instructions.
            """
        }
        return markdown(baseMarkdown, applyingSchemaFor: kind, project: project, template: template)
    }

    private func markdown(
        _ markdown: String,
        applyingSchemaFor kind: ArtifactKind,
        project: IdeaProject,
        template: WorkflowTemplate
    ) -> String {
        guard let contract = template.schemaContracts.first(where: { $0.outputKind == kind })
            ?? DefaultWorkflows.schemaContracts.first(where: { $0.outputKind == kind }) else {
            return markdown
        }

        let missingFields = contract.fields.filter { field in
            !markdownContainsField(markdown, fieldName: field.name)
        }
        guard !missingFields.isEmpty else { return markdown }

        let additions = missingFields.map { field in
            """
            ## \(title(forSchemaField: field.name))
            Local draft checkpoint for \(project.title): \(field.summary)
            """
        }
        .joined(separator: "\n\n")

        return "\(markdown)\n\n\(additions)"
    }

    private func markdownContainsField(_ markdown: String, fieldName: String) -> Bool {
        let expected = normalizedSchemaFieldLabel(fieldName)
        return markdown
            .split(whereSeparator: \.isNewline)
            .map { normalizedSchemaLine(String($0)) }
            .contains { line in
                line == expected || line.hasPrefix("\(expected) ")
            }
    }

    private func normalizedSchemaLine(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = text.first,
              "#*-•0123456789. ".contains(first) {
            text.removeFirst()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let colonIndex = text.firstIndex(of: ":") {
            text = String(text[..<colonIndex])
        }
        return normalizedSchemaFieldLabel(text)
    }

    private func normalizedSchemaFieldLabel(_ text: String) -> String {
        text
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }

    private func title(forSchemaField fieldName: String) -> String {
        fieldName
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .map { word in
                word.prefix(1).uppercased() + word.dropFirst().lowercased()
            }
            .joined(separator: " ")
    }
}

public struct LocalSyncQueueService: SyncQueueService {
    public init() {}

    public func enqueue(recording: Recording) async throws -> SyncStatus {
        if recording.deviceName.localizedCaseInsensitiveContains("watch") {
            return SyncStatus.transferredToIPhone
        }
        return recording.syncStatus
    }
}

public struct PendingSyncQueueService: SyncQueueService {
    public init() {}

    public func enqueue(recording: Recording) async throws -> SyncStatus {
        .pending
    }
}

public struct LocalExportService: ExportService {
    public var exportRoot: URL
    public var storagePreflight: StoragePreflight

    public init(
        exportRoot: URL = LocalExportService.applicationSupportExportRoot(),
        storagePreflight: StoragePreflight = .codexPacketExport()
    ) {
        self.exportRoot = exportRoot
        self.storagePreflight = storagePreflight
    }

    public func codexPacket(for project: IdeaProject) async throws -> EngineeringPacket {
        EngineeringPacketBuilder.packet(for: project)
    }

    public func exportCodexPacket(for project: IdeaProject) async throws -> PacketExportResult {
        let packet = EngineeringPacketBuilder.packet(for: project)
        return try PacketFileSystemWriter(rootDirectory: exportRoot, storagePreflight: storagePreflight).write(packet: packet, for: project)
    }

    public static func applicationSupportExportRoot(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appending(path: "IdeaForge/Exports", directoryHint: .isDirectory)
    }
}

public struct IdeaForgeServices: Sendable {
    public var transcription: any TranscriptionService
    public var workflow: any WorkflowExecutionService
    public var syncQueue: any SyncQueueService
    public var export: any ExportService

    public init(
        transcription: any TranscriptionService,
        workflow: any WorkflowExecutionService,
        syncQueue: any SyncQueueService,
        export: any ExportService
    ) {
        self.transcription = transcription
        self.workflow = workflow
        self.syncQueue = syncQueue
        self.export = export
    }

    public static let local = IdeaForgeServices(
        transcription: LocalTranscriptionService(),
        workflow: LocalWorkflowExecutionService(),
        syncQueue: LocalSyncQueueService(),
        export: LocalExportService()
    )

    public static let localSpeech = IdeaForgeServices(
        transcription: LocalSpeechTranscriptionService(),
        workflow: LocalWorkflowExecutionService(),
        syncQueue: LocalSyncQueueService(),
        export: LocalExportService()
    )
}
