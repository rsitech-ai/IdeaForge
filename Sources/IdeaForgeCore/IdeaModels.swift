import Foundation
import Observation

public enum IdeaStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case inbox
    case processing
    case draft
    case validated
    case readyForBuild
    case archived

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .inbox: "Inbox"
        case .processing: "Processing"
        case .draft: "Draft"
        case .validated: "Validated"
        case .readyForBuild: "Ready for Build"
        case .archived: "Archived"
        }
    }
}

public enum IdeaSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case watch
    case iphone
    case mac
    case importFile

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .watch: "Watch"
        case .iphone: "iPhone"
        case .mac: "Mac"
        case .importFile: "Import"
        }
    }
}

public enum IdeaTag: String, Codable, CaseIterable, Identifiable, Sendable {
    case appIdea
    case feature
    case bug
    case business
    case research
    case random

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .appIdea: "App Idea"
        case .feature: "Feature"
        case .bug: "Bug"
        case .business: "Business"
        case .research: "Research"
        case .random: "Random"
        }
    }
}

public enum SyncStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case pending
    case transferredToIPhone
    case uploaded
    case failed
    case transcribing
    case ready

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .pending: "Pending"
        case .transferredToIPhone: "On iPhone"
        case .uploaded: "Uploaded"
        case .failed: "Failed"
        case .transcribing: "Transcribing"
        case .ready: "Ready"
        }
    }
}

public enum WorkspaceSyncActivitySource: String, Codable, Hashable, Sendable {
    case manualPublish
    case manualRefresh
    case backgroundAutoSync
    case remoteNotification

    public var label: String {
        switch self {
        case .manualPublish: "Manual publish"
        case .manualRefresh: "Manual refresh"
        case .backgroundAutoSync: "Background sync"
        case .remoteNotification: "Remote push"
        }
    }
}

public enum WorkspaceSyncActivityStatus: String, Codable, Hashable, Sendable {
    case success
    case skipped
    case blocked
    case failed

    public var label: String {
        switch self {
        case .success: "Done"
        case .skipped: "No changes"
        case .blocked: "Blocked"
        case .failed: "Failed"
        }
    }

    public var systemImage: String {
        switch self {
        case .success: "checkmark.icloud.fill"
        case .skipped: "checkmark.circle"
        case .blocked: "pause.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}

public struct WorkspaceSyncActivityReceipt: Codable, Hashable, Sendable {
    public var source: WorkspaceSyncActivitySource
    public var status: WorkspaceSyncActivityStatus
    public var title: String
    public var detail: String
    public var occurredAt: Date

    public init(
        source: WorkspaceSyncActivitySource,
        status: WorkspaceSyncActivityStatus,
        title: String,
        detail: String,
        occurredAt: Date
    ) {
        self.source = source
        self.status = status
        self.title = title
        self.detail = detail
        self.occurredAt = occurredAt
    }
}

public enum RecordingFileStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case available
    case uploaded
    case deleted
    case missing
    case failed

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .available: "Available"
        case .uploaded: "Uploaded"
        case .deleted: "Deleted"
        case .missing: "Missing"
        case .failed: "Failed"
        }
    }
}

public enum RetainedAudioValidation: String, CaseIterable, Identifiable, Equatable, Sendable {
    case available
    case unavailable
    case invalid
    case mismatched

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .available: "Available"
        case .unavailable: "Unavailable"
        case .invalid: "Invalid"
        case .mismatched: "Mismatched"
        }
    }

    public var isRetryEligible: Bool {
        self == .available
    }
}

public enum RecordingProcessingFailureCode: String, Codable, CaseIterable, Identifiable, Sendable {
    case backendProviderFailure = "backend_provider_failure"
    case backendEntitlementUnavailable = "backend_entitlement_unavailable"
    case localSpeechUnavailable = "local_speech_unavailable"
    case transcriptContractViolation = "transcript_contract_violation"
    case transcriptionFailed = "transcription_failed"

    public var id: String { rawValue }
}

public struct RecordingProcessingDiagnostic: Codable, Hashable, Sendable {
    public var code: RecordingProcessingFailureCode
    public var message: String
    public var isRetryable: Bool
    public var failedAt: Date

    public init(
        code: RecordingProcessingFailureCode,
        message: String,
        isRetryable: Bool,
        failedAt: Date
    ) {
        self.code = code
        self.message = message
        self.isRetryable = isRetryable
        self.failedAt = failedAt
    }
}

public enum RecordingQueueEvent: Equatable, Sendable {
    case transferredToIPhone
    case watchTransferFailed
    case uploaded(objectKey: String?)
    case transcribing
    case ready
    case transcriptionFailed
    case failed
    case deleteLocalAudio
}

public enum RecordingQueueError: Error, Equatable {
    case cannotDeleteBeforeUpload
}

public enum RecordingQueuePolicy {
    public static func applying(_ event: RecordingQueueEvent, to recording: Recording) throws -> Recording {
        var updated = recording
        switch event {
        case .transferredToIPhone:
            updated.syncStatus = .transferredToIPhone
        case .watchTransferFailed:
            // Keep the local file available so the Watch retry affordance stays eligible.
            updated.syncStatus = .failed
        case let .uploaded(objectKey):
            updated.syncStatus = .uploaded
            updated.localFileStatus = .uploaded
            updated.audioObjectKey = objectKey
            updated.processingDiagnostic = nil
        case .transcribing:
            updated.syncStatus = .transcribing
            if updated.audioObjectKey?.isEmpty == false {
                updated.localFileStatus = .uploaded
            }
            updated.processingDiagnostic = nil
        case .ready:
            updated.syncStatus = .ready
            if updated.audioObjectKey?.isEmpty == false {
                updated.localFileStatus = .uploaded
            }
            updated.processingDiagnostic = nil
        case .transcriptionFailed:
            updated.syncStatus = .failed
        case .failed:
            updated.syncStatus = .failed
            updated.localFileStatus = .failed
        case .deleteLocalAudio:
            guard recording.syncStatus == .uploaded || recording.syncStatus == .ready else {
                throw RecordingQueueError.cannotDeleteBeforeUpload
            }
            updated.localFileStatus = .deleted
            updated.localAudioPath = nil
        }
        return updated
    }
}

public enum ArtifactKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case ideaBrief
    case prd
    case roadmap
    case architecture
    case uxFlow
    case dataModel
    case apiDesign
    case issueBundle
    case codexTaskBundle
    case validationPlan
    case launchChecklist

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .ideaBrief: "Idea Brief"
        case .prd: "PRD"
        case .roadmap: "Roadmap"
        case .architecture: "Architecture"
        case .uxFlow: "UX Flow"
        case .dataModel: "Data Model"
        case .apiDesign: "API Design"
        case .issueBundle: "Issue Bundle"
        case .codexTaskBundle: "Codex Task Bundle"
        case .validationPlan: "Validation Plan"
        case .launchChecklist: "Launch Checklist"
        }
    }
}

public struct IdeaScore: Codable, Hashable, Sendable {
    public var confidence: Double
    public var completeness: Double
    public var risk: Double

    public init(confidence: Double, completeness: Double, risk: Double) {
        self.confidence = confidence
        self.completeness = completeness
        self.risk = risk
    }
}

public struct IdeaProject: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var status: IdeaStatus
    public var source: IdeaSource
    public var createdAt: Date
    public var updatedAt: Date
    public var summary: String
    public var tags: [IdeaTag]
    public var score: IdeaScore
    public var transcript: Transcript
    public var recordings: [Recording]
    public var questions: [Question]
    public var artifacts: [Artifact]
    public var assumptions: [Assumption]
    public var validationExperiments: [ValidationExperiment]
    public var codexTasks: [CodexTask]
    public var workflowRuns: [WorkflowRun]

    public init(
        id: String,
        title: String,
        status: IdeaStatus,
        source: IdeaSource,
        createdAt: Date,
        updatedAt: Date,
        summary: String,
        tags: [IdeaTag],
        score: IdeaScore,
        transcript: Transcript,
        recordings: [Recording],
        questions: [Question],
        artifacts: [Artifact],
        assumptions: [Assumption],
        validationExperiments: [ValidationExperiment],
        codexTasks: [CodexTask],
        workflowRuns: [WorkflowRun] = []
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.summary = summary
        self.tags = tags
        self.score = score
        self.transcript = transcript
        self.recordings = recordings
        self.questions = questions
        self.artifacts = artifacts
        self.assumptions = assumptions
        self.validationExperiments = validationExperiments
        self.codexTasks = codexTasks
        self.workflowRuns = workflowRuns
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case status
        case source
        case createdAt
        case updatedAt
        case summary
        case tags
        case score
        case transcript
        case recordings
        case questions
        case artifacts
        case assumptions
        case validationExperiments
        case codexTasks
        case workflowRuns
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        status = try container.decode(IdeaStatus.self, forKey: .status)
        source = try container.decode(IdeaSource.self, forKey: .source)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        summary = try container.decode(String.self, forKey: .summary)
        tags = try container.decode([IdeaTag].self, forKey: .tags)
        score = try container.decode(IdeaScore.self, forKey: .score)
        transcript = try container.decode(Transcript.self, forKey: .transcript)
        recordings = try container.decode([Recording].self, forKey: .recordings)
        questions = try container.decode([Question].self, forKey: .questions)
        artifacts = try container.decode([Artifact].self, forKey: .artifacts)
        assumptions = try container.decode([Assumption].self, forKey: .assumptions)
        validationExperiments = try container.decode([ValidationExperiment].self, forKey: .validationExperiments)
        codexTasks = try container.decode([CodexTask].self, forKey: .codexTasks)
        workflowRuns = try container.decodeIfPresent([WorkflowRun].self, forKey: .workflowRuns) ?? []
    }
}

public struct Recording: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var ideaProjectID: String
    public var deviceName: String
    public var durationSeconds: Int
    public var localFileStatus: RecordingFileStatus
    public var syncStatus: SyncStatus
    public var localAudioPath: String?
    public var audioObjectKey: String?
    public var languageHint: String
    public var createdAt: Date
    public var markerOffsets: [Int]
    public var processingDiagnostic: RecordingProcessingDiagnostic?

    public init(
        id: String,
        ideaProjectID: String,
        deviceName: String,
        durationSeconds: Int,
        localFileStatus: RecordingFileStatus,
        syncStatus: SyncStatus,
        localAudioPath: String? = nil,
        audioObjectKey: String? = nil,
        languageHint: String,
        createdAt: Date,
        markerOffsets: [Int],
        processingDiagnostic: RecordingProcessingDiagnostic? = nil
    ) {
        self.id = id
        self.ideaProjectID = ideaProjectID
        self.deviceName = deviceName
        self.durationSeconds = durationSeconds
        self.localFileStatus = localFileStatus
        self.syncStatus = syncStatus
        self.localAudioPath = localAudioPath
        self.audioObjectKey = audioObjectKey
        self.languageHint = languageHint
        self.createdAt = createdAt
        self.markerOffsets = markerOffsets
        self.processingDiagnostic = processingDiagnostic
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case ideaProjectID
        case deviceName
        case durationSeconds
        case localFileStatus
        case syncStatus
        case localAudioPath
        case audioObjectKey
        case languageHint
        case createdAt
        case markerOffsets
        case processingDiagnostic
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        ideaProjectID = try container.decode(String.self, forKey: .ideaProjectID)
        deviceName = try container.decode(String.self, forKey: .deviceName)
        durationSeconds = try container.decode(Int.self, forKey: .durationSeconds)
        localFileStatus = try container.decode(RecordingFileStatus.self, forKey: .localFileStatus)
        syncStatus = try container.decode(SyncStatus.self, forKey: .syncStatus)
        localAudioPath = try container.decodeIfPresent(String.self, forKey: .localAudioPath)
        audioObjectKey = try container.decodeIfPresent(String.self, forKey: .audioObjectKey)
        languageHint = try container.decode(String.self, forKey: .languageHint)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        markerOffsets = try container.decode([Int].self, forKey: .markerOffsets)
        processingDiagnostic = try container.decodeIfPresent(
            RecordingProcessingDiagnostic.self,
            forKey: .processingDiagnostic
        )
    }
}

public struct Transcript: Codable, Hashable, Sendable {
    public var cleanText: String
    public var segments: [TranscriptSegment]
    public var unclearFragments: [String]

    public init(cleanText: String, segments: [TranscriptSegment], unclearFragments: [String]) {
        self.cleanText = cleanText
        self.segments = segments
        self.unclearFragments = unclearFragments
    }
}

public struct TranscriptSegment: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var startSeconds: Int
    public var endSeconds: Int
    public var text: String
    public var isMarkedImportant: Bool

    public init(id: String, startSeconds: Int, endSeconds: Int, text: String, isMarkedImportant: Bool) {
        self.id = id
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = text
        self.isMarkedImportant = isMarkedImportant
    }
}

public struct Question: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var prompt: String
    public var answer: String?
    public var isBlocking: Bool

    public init(id: String, prompt: String, answer: String?, isBlocking: Bool) {
        self.id = id
        self.prompt = prompt
        self.answer = answer
        self.isBlocking = isBlocking
    }
}

public struct Artifact: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var kind: ArtifactKind
    public var title: String
    public var markdown: String
    public var version: Int
    public var createdBy: String
    public var createdAt: Date
    public var sourceWorkflowRunID: String?

    public init(
        id: String,
        kind: ArtifactKind,
        title: String,
        markdown: String,
        version: Int,
        createdBy: String,
        createdAt: Date,
        sourceWorkflowRunID: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.markdown = markdown
        self.version = version
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.sourceWorkflowRunID = sourceWorkflowRunID
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case title
        case markdown
        case version
        case createdBy
        case createdAt
        case sourceWorkflowRunID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(ArtifactKind.self, forKey: .kind)
        title = try container.decode(String.self, forKey: .title)
        markdown = try container.decode(String.self, forKey: .markdown)
        version = try container.decode(Int.self, forKey: .version)
        createdBy = try container.decode(String.self, forKey: .createdBy)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        sourceWorkflowRunID = try container.decodeIfPresent(String.self, forKey: .sourceWorkflowRunID)
    }
}

public enum WorkflowArtifactChangeStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case added
    case updated
    case unchanged
    case removed

    public var id: String { rawValue }
}

public enum ArtifactDiffLineStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case unchanged
    case added
    case removed

    public var id: String { rawValue }
}

public struct ArtifactDiffLine: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var status: ArtifactDiffLineStatus
    public var text: String
    public var previousLineNumber: Int?
    public var newLineNumber: Int?

    public init(
        id: String,
        status: ArtifactDiffLineStatus,
        text: String,
        previousLineNumber: Int?,
        newLineNumber: Int?
    ) {
        self.id = id
        self.status = status
        self.text = text
        self.previousLineNumber = previousLineNumber
        self.newLineNumber = newLineNumber
    }
}

public struct ArtifactDiffSummary: Identifiable, Codable, Hashable, Sendable {
    public var id: String { "\(previousArtifactID)->\(currentArtifactID)" }
    public var kind: ArtifactKind
    public var previousArtifactID: String
    public var currentArtifactID: String
    public var previousVersion: Int
    public var currentVersion: Int
    public var lines: [ArtifactDiffLine]

    public var addedLineCount: Int {
        lines.filter { $0.status == .added }.count
    }

    public var removedLineCount: Int {
        lines.filter { $0.status == .removed }.count
    }

    public var unchangedLineCount: Int {
        lines.filter { $0.status == .unchanged }.count
    }

    public var hasContentChanges: Bool {
        addedLineCount > 0 || removedLineCount > 0
    }

    public init(previous: Artifact, current: Artifact) {
        kind = current.kind
        previousArtifactID = previous.id
        currentArtifactID = current.id
        previousVersion = previous.version
        currentVersion = current.version
        lines = Self.lineDiff(previous: previous.markdown, current: current.markdown)
    }

    private static func lineDiff(previous: String, current: String) -> [ArtifactDiffLine] {
        let oldLines = previous.components(separatedBy: .newlines)
        let newLines = current.components(separatedBy: .newlines)
        let oldCount = oldLines.count
        let newCount = newLines.count
        var table = Array(
            repeating: Array(repeating: 0, count: newCount + 1),
            count: oldCount + 1
        )

        if oldCount > 0 && newCount > 0 {
            for oldIndex in stride(from: oldCount - 1, through: 0, by: -1) {
                for newIndex in stride(from: newCount - 1, through: 0, by: -1) {
                    if oldLines[oldIndex] == newLines[newIndex] {
                        table[oldIndex][newIndex] = table[oldIndex + 1][newIndex + 1] + 1
                    } else {
                        table[oldIndex][newIndex] = max(
                            table[oldIndex + 1][newIndex],
                            table[oldIndex][newIndex + 1]
                        )
                    }
                }
            }
        }

        var diff: [ArtifactDiffLine] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < oldCount || newIndex < newCount {
            if oldIndex < oldCount,
               newIndex < newCount,
               oldLines[oldIndex] == newLines[newIndex] {
                diff.append(
                    ArtifactDiffLine(
                        id: "same_\(diff.count)",
                        status: .unchanged,
                        text: oldLines[oldIndex],
                        previousLineNumber: oldIndex + 1,
                        newLineNumber: newIndex + 1
                    )
                )
                oldIndex += 1
                newIndex += 1
            } else if newIndex < newCount,
                      (oldIndex == oldCount || table[oldIndex][newIndex + 1] >= table[oldIndex + 1][newIndex]) {
                diff.append(
                    ArtifactDiffLine(
                        id: "add_\(diff.count)",
                        status: .added,
                        text: newLines[newIndex],
                        previousLineNumber: nil,
                        newLineNumber: newIndex + 1
                    )
                )
                newIndex += 1
            } else if oldIndex < oldCount {
                diff.append(
                    ArtifactDiffLine(
                        id: "remove_\(diff.count)",
                        status: .removed,
                        text: oldLines[oldIndex],
                        previousLineNumber: oldIndex + 1,
                        newLineNumber: nil
                    )
                )
                oldIndex += 1
            }
        }

        return diff
    }
}

public struct ArtifactHistory: Identifiable, Codable, Hashable, Sendable {
    public var id: String { kind.rawValue }
    public var kind: ArtifactKind
    public var versions: [Artifact]

    public var latest: Artifact {
        versions[0]
    }

    public var versionCount: Int {
        versions.count
    }

    public var latestDiff: ArtifactDiffSummary? {
        guard versions.count >= 2 else { return nil }
        return ArtifactDiffSummary(previous: versions[1], current: versions[0])
    }

    public init(kind: ArtifactKind, versions: [Artifact]) {
        self.kind = kind
        self.versions = versions
    }
}

public struct WorkflowArtifactChange: Identifiable, Codable, Hashable, Sendable {
    public var id: String { kind.rawValue }
    public var kind: ArtifactKind
    public var status: WorkflowArtifactChangeStatus
    public var previousArtifactID: String?
    public var currentArtifactID: String?
    public var previousVersion: Int?
    public var currentVersion: Int?

    public init(
        kind: ArtifactKind,
        status: WorkflowArtifactChangeStatus,
        previousArtifactID: String?,
        currentArtifactID: String?,
        previousVersion: Int?,
        currentVersion: Int?
    ) {
        self.kind = kind
        self.status = status
        self.previousArtifactID = previousArtifactID
        self.currentArtifactID = currentArtifactID
        self.previousVersion = previousVersion
        self.currentVersion = currentVersion
    }
}

public struct WorkflowRunComparison: Identifiable, Codable, Hashable, Sendable {
    public var id: String { currentRunID }
    public var currentRunID: String
    public var previousRunID: String?
    public var templateID: String
    public var changes: [WorkflowArtifactChange]

    public init(currentRunID: String, previousRunID: String?, templateID: String, changes: [WorkflowArtifactChange]) {
        self.currentRunID = currentRunID
        self.previousRunID = previousRunID
        self.templateID = templateID
        self.changes = changes
    }
}

public struct WorkflowRunReview: Identifiable, Codable, Hashable, Sendable {
    public var id: String { runID }
    public var runID: String
    public var templateName: String
    public var status: WorkflowRunStatus
    public var decision: WorkflowEvaluationDecision
    public var readinessScore: Double
    public var artifactCount: Int
    public var missingArtifactCount: Int
    public var blockerSummaries: [String]
    public var warningSummaries: [String]
    public var artifactChangeSummaries: [String]
    public var canRetry: Bool
    public var retrySummary: String?
    public var provenanceSummary: String

    public var isReadyForHandoff: Bool {
        decision == .ready && blockerSummaries.isEmpty
    }

    public init(
        runID: String,
        templateName: String,
        status: WorkflowRunStatus,
        decision: WorkflowEvaluationDecision,
        readinessScore: Double,
        artifactCount: Int,
        missingArtifactCount: Int,
        blockerSummaries: [String],
        warningSummaries: [String],
        artifactChangeSummaries: [String],
        canRetry: Bool,
        retrySummary: String?,
        provenanceSummary: String
    ) {
        self.runID = runID
        self.templateName = templateName
        self.status = status
        self.decision = decision
        self.readinessScore = readinessScore
        self.artifactCount = artifactCount
        self.missingArtifactCount = missingArtifactCount
        self.blockerSummaries = blockerSummaries
        self.warningSummaries = warningSummaries
        self.artifactChangeSummaries = artifactChangeSummaries
        self.canRetry = canRetry
        self.retrySummary = retrySummary
        self.provenanceSummary = provenanceSummary
    }
}

public extension IdeaProject {
    var artifactHistories: [ArtifactHistory] {
        Dictionary(grouping: artifacts, by: \.kind)
            .map { kind, versions in
                ArtifactHistory(
                    kind: kind,
                    versions: versions.sorted { left, right in
                        if left.version != right.version {
                            return left.version > right.version
                        }
                        return left.createdAt > right.createdAt
                    }
                )
            }
            .sorted { $0.kind.rawValue < $1.kind.rawValue }
    }

    func workflowRunReview(forRunID runID: String, now: Date = Date()) -> WorkflowRunReview? {
        guard let run = workflowRuns.first(where: { $0.id == runID }) else { return nil }

        let artifactByID = Dictionary(uniqueKeysWithValues: artifacts.map { ($0.id, $0) })
        let resolvedArtifacts = run.artifactIDs.compactMap { artifactByID[$0] }
        let missingArtifactCount = run.artifactIDs.count - resolvedArtifacts.count
        var blockers: [String] = []
        var warnings: [String] = []

        switch run.status {
        case .running:
            blockers.append("Workflow is still running.")
        case .failed:
            blockers.append("Workflow failed: \(run.errorMessage?.nonEmpty ?? "No failure detail recorded.").")
        case .completed:
            break
        }

        if run.status == .completed && run.artifactIDs.isEmpty {
            blockers.append("No artifacts were attached to this run.")
        }

        if missingArtifactCount > 0 {
            let noun = missingArtifactCount == 1 ? "artifact is" : "artifacts are"
            blockers.append("\(missingArtifactCount) referenced \(noun) missing from project history.")
        }

        if let evaluation = run.evaluation {
            blockers.append(contentsOf: evaluation.blockers)
            blockers.append(contentsOf: evaluation.schemaIssues)
            blockers.append(
                contentsOf: evaluation.rubricItems
                    .filter { $0.status == .failing }
                    .map { "AI rubric failed: \($0.title)." }
            )
            warnings.append(
                contentsOf: evaluation.rubricItems
                    .filter { $0.status == .warning }
                    .map { "AI rubric warning: \($0.title)." }
            )
        } else {
            blockers.append("No workflow evaluation is recorded.")
        }

        if run.retryAttempt > 0 {
            warnings.append("Retry attempt \(run.retryAttempt) of \(WorkflowRetryPolicy.maximumAttempts).")
        }

        let canRetry = run.status == .failed
            && run.retryAttempt < WorkflowRetryPolicy.maximumAttempts
            && (run.nextRetryAt == nil || run.nextRetryAt! <= now)
        let retrySummary: String?
        if run.status == .failed {
            if canRetry {
                retrySummary = "Retry is available."
            } else if let nextRetryAt = run.nextRetryAt, nextRetryAt > now {
                retrySummary = "Retry scheduled for \(nextRetryAt.formatted(date: .abbreviated, time: .shortened))."
            } else {
                retrySummary = "Retry is not available."
            }
        } else {
            retrySummary = nil
        }

        let comparison = workflowComparison(forRunID: run.id)
        let artifactChangeSummaries = comparison?.changes
            .filter { $0.status != .unchanged }
            .map { change in
                "\(change.kind.label): \(workflowRunReviewChangeSummary(for: change))"
            } ?? []

        if comparison?.previousRunID == nil && run.status == .completed {
            warnings.append("No previous completed run exists for comparison.")
        }

        let uniqueBlockers = uniqueStringsPreservingOrder(blockers)
        let uniqueWarnings = uniqueStringsPreservingOrder(warnings)
        let decision: WorkflowEvaluationDecision
        if !uniqueBlockers.isEmpty {
            decision = .blocked
        } else if run.evaluation?.decision == .ready {
            decision = .ready
        } else {
            decision = run.evaluation?.decision ?? .needsReview
        }

        return WorkflowRunReview(
            runID: run.id,
            templateName: run.templateName,
            status: run.status,
            decision: decision,
            readinessScore: run.evaluation?.readinessScore ?? 0,
            artifactCount: resolvedArtifacts.count,
            missingArtifactCount: missingArtifactCount,
            blockerSummaries: uniqueBlockers,
            warningSummaries: uniqueWarnings,
            artifactChangeSummaries: artifactChangeSummaries,
            canRetry: canRetry,
            retrySummary: retrySummary,
            provenanceSummary: workflowRunReviewProvenanceSummary(for: run, resolvedArtifactCount: resolvedArtifacts.count)
        )
    }

    func workflowComparison(forRunID runID: String) -> WorkflowRunComparison? {
        guard let currentIndex = workflowRuns.firstIndex(where: { $0.id == runID }) else { return nil }
        let currentRun = workflowRuns[currentIndex]
        let previousRun = workflowRuns
            .dropFirst(currentIndex + 1)
            .first { $0.templateID == currentRun.templateID && $0.status == .completed }
        let currentArtifacts = artifactsByKind(for: currentRun)
        let previousArtifacts = previousRun.map { artifactsByKind(for: $0) } ?? [:]
        let kinds = Set(currentArtifacts.keys).union(previousArtifacts.keys)

        let changes = kinds
            .sorted { $0.rawValue < $1.rawValue }
            .map { kind in
                let previous = previousArtifacts[kind]
                let current = currentArtifacts[kind]
                return WorkflowArtifactChange(
                    kind: kind,
                    status: changeStatus(previous: previous, current: current),
                    previousArtifactID: previous?.id,
                    currentArtifactID: current?.id,
                    previousVersion: previous?.version,
                    currentVersion: current?.version
                )
            }

        return WorkflowRunComparison(
            currentRunID: currentRun.id,
            previousRunID: previousRun?.id,
            templateID: currentRun.templateID,
            changes: changes
        )
    }

    private func artifactsByKind(for run: WorkflowRun) -> [ArtifactKind: Artifact] {
        let artifactByID = Dictionary(uniqueKeysWithValues: artifacts.map { ($0.id, $0) })
        return run.artifactIDs.reduce(into: [ArtifactKind: Artifact]()) { result, artifactID in
            guard let artifact = artifactByID[artifactID] else { return }
            result[artifact.kind] = artifact
        }
    }

    private func changeStatus(previous: Artifact?, current: Artifact?) -> WorkflowArtifactChangeStatus {
        switch (previous, current) {
        case (nil, nil):
            return .unchanged
        case (nil, .some):
            return .added
        case (.some, nil):
            return .removed
        case let (.some(previous), .some(current)):
            if previous.version == current.version && previous.markdown == current.markdown {
                return .unchanged
            }
            return .updated
        }
    }

    private func workflowRunReviewChangeSummary(for change: WorkflowArtifactChange) -> String {
        switch (change.status, change.previousVersion, change.currentVersion) {
        case let (.added, _, .some(current)):
            return "new v\(current)"
        case let (.updated, .some(previous), .some(current)):
            return "v\(previous) -> v\(current)"
        case let (.removed, .some(previous), _):
            return "removed v\(previous)"
        default:
            return change.status.rawValue
        }
    }

    private func workflowRunReviewProvenanceSummary(for run: WorkflowRun, resolvedArtifactCount: Int) -> String {
        let retryText = run.retryOfRunID == nil ? "original run" : "retry of \(run.retryOfRunID ?? "unknown")"
        return "\(run.templateID), \(retryText), \(run.stepRuns.count) steps, \(resolvedArtifactCount) resolved artifacts"
    }

    private func uniqueStringsPreservingOrder(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}

public struct Assumption: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var text: String
    public var confidence: Double
    public var evidence: String

    public init(id: String, text: String, confidence: Double, evidence: String) {
        self.id = id
        self.text = text
        self.confidence = confidence
        self.evidence = evidence
    }
}

public struct ValidationExperiment: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var metric: String
    public var goNoGoCriteria: String

    public init(id: String, title: String, metric: String, goNoGoCriteria: String) {
        self.id = id
        self.title = title
        self.metric = metric
        self.goNoGoCriteria = goNoGoCriteria
    }
}

public struct CodexTask: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var acceptanceCriteria: [String]
    public var testPlan: [String]

    public init(id: String, title: String, acceptanceCriteria: [String], testPlan: [String]) {
        self.id = id
        self.title = title
        self.acceptanceCriteria = acceptanceCriteria
        self.testPlan = testPlan
    }
}

public extension RecordingRowSnapshot {
    static func history(
        projects: [IdeaProject],
        uploadJobs: [UploadJob]
    ) -> [RecordingRowSnapshot] {
        let jobsByRecordingID = uploadJobs.reduce(into: [String: UploadJob]()) { indexed, job in
            guard let existing = indexed[job.recordingID] else {
                indexed[job.recordingID] = job
                return
            }
            if job.updatedAt > existing.updatedAt
                || (job.updatedAt == existing.updatedAt && job.id > existing.id) {
                indexed[job.recordingID] = job
            }
        }

        return projects
            .flatMap { project in
                project.recordings.map { recording in
                    RecordingRowSnapshot(
                        recording: recording,
                        projectTitle: project.title,
                        uploadJob: jobsByRecordingID[recording.id],
                        hasRemoteReceipt: recording.audioObjectKey?.isEmpty == false
                    )
                }
            }
            .sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.id > rhs.id
                }
                return lhs.createdAt > rhs.createdAt
            }
    }
}

public struct AccountUploadDiagnosticContext: Identifiable, Equatable, Sendable {
    public var job: UploadJob
    public var recording: Recording
    public var projectTitle: String

    public var id: String { recording.id }

    public init(job: UploadJob, recording: Recording, projectTitle: String) {
        self.job = job
        self.recording = recording
        self.projectTitle = projectTitle
    }
}

public struct AccountRecordingDiagnosticContext: Identifiable, Equatable, Sendable {
    public var recording: Recording
    public var projectTitle: String

    public var id: String { recording.id }

    public init(recording: Recording, projectTitle: String) {
        self.recording = recording
        self.projectTitle = projectTitle
    }
}

public struct AccountUploadDiagnosticsSnapshot: Equatable, Sendable {
    public var uploadContexts: [AccountUploadDiagnosticContext]
    public var recordingContexts: [AccountRecordingDiagnosticContext]

    public init(projects: [IdeaProject], uploadJobs: [UploadJob]) {
        let recordingsByID = projects.reduce(into: [String: AccountRecordingDiagnosticContext]()) { indexed, project in
            for recording in project.recordings where indexed[recording.id] == nil {
                indexed[recording.id] = AccountRecordingDiagnosticContext(
                    recording: recording,
                    projectTitle: project.title
                )
            }
        }
        let currentJobsByRecordingID = uploadJobs.reduce(into: [String: UploadJob]()) { indexed, job in
            guard let existing = indexed[job.recordingID] else {
                indexed[job.recordingID] = job
                return
            }
            if job.updatedAt > existing.updatedAt
                || (job.updatedAt == existing.updatedAt && job.id > existing.id) {
                indexed[job.recordingID] = job
            }
        }

        uploadContexts = currentJobsByRecordingID.values
            .compactMap { job in
                guard
                    job.status != .uploaded,
                    let recordingContext = recordingsByID[job.recordingID]
                else {
                    return nil
                }
                return AccountUploadDiagnosticContext(
                    job: job,
                    recording: recordingContext.recording,
                    projectTitle: recordingContext.projectTitle
                )
            }
            .sorted { lhs, rhs in
                let lhsFailed = lhs.job.status == .permanentlyFailed
                let rhsFailed = rhs.job.status == .permanentlyFailed
                if lhsFailed != rhsFailed {
                    return lhsFailed
                }
                if lhs.job.updatedAt == rhs.job.updatedAt {
                    return lhs.job.id > rhs.job.id
                }
                return lhs.job.updatedAt > rhs.job.updatedAt
            }

        recordingContexts = recordingsByID.values
            .filter { $0.recording.processingDiagnostic != nil }
            .sorted { lhs, rhs in
                if lhs.recording.createdAt == rhs.recording.createdAt {
                    return lhs.id > rhs.id
                }
                return lhs.recording.createdAt > rhs.recording.createdAt
            }
    }
}

@Observable
public final class IdeaForgeStore {
    public var projects: [IdeaProject]
    public var workflowTemplates: [WorkflowTemplate]
    public var uploadJobs: [UploadJob]
    public var selectedProjectID: String?
    public var privacyMode: PrivacyMode
    public var syncHealth: SyncHealth
    public var lastErrorMessage: String?
    public var lastExportedPacketURL: URL?
    public var updatedAt: Date
    public private(set) var workspaceLoadFailed = false

    private let repository: any WorkspaceRepository
    @ObservationIgnored private var inFlightWorkflowRetryRunIDs: Set<String> = []

    public init(
        projects: [IdeaProject],
        workflowTemplates: [WorkflowTemplate],
        uploadJobs: [UploadJob] = [],
        selectedProjectID: String? = nil,
        privacyMode: PrivacyMode,
        syncHealth: SyncHealth,
        updatedAt: Date = Date(),
        repository: any WorkspaceRepository = InMemoryWorkspaceRepository()
    ) {
        self.projects = projects
        self.workflowTemplates = workflowTemplates
        self.uploadJobs = uploadJobs
        self.selectedProjectID = selectedProjectID ?? projects.first?.id
        self.privacyMode = privacyMode
        self.syncHealth = syncHealth
        self.updatedAt = updatedAt
        self.repository = repository
    }

    public var selectedProject: IdeaProject? {
        get { projects.first { $0.id == selectedProjectID } }
        set {
            guard let newValue, let index = projects.firstIndex(where: { $0.id == newValue.id }) else { return }
            projects[index] = newValue
        }
    }

    public var pendingQuestions: [Question] {
        projects.flatMap(\.questions).filter { $0.answer == nil }
    }

    public var queuedRecordings: [Recording] {
        projects.flatMap(\.recordings).filter { $0.syncStatus != .ready }
    }

    public var watchCaptureProjects: [IdeaProject] {
        projects
            .filter { project in
                project.recordings.contains { recording in
                    recording.deviceName.localizedCaseInsensitiveContains("watch")
                }
            }
            .sorted { lhs, rhs in
                lhs.updatedAt > rhs.updatedAt
            }
    }

    public var activeUploadJobs: [UploadJob] {
        uploadJobs.filter { job in
            job.status == .queued || job.status == .uploading || job.status == .waitingForRetry
        }
    }

    public var retryableWatchTransferRecording: Recording? {
        projects
            .flatMap(\.recordings)
            .filter(Self.isRetryableWatchTransferRecording)
            .sorted { lhs, rhs in
                lhs.createdAt > rhs.createdAt
            }
            .first
    }

    public static func production(
        repository: any WorkspaceRepository = JSONWorkspaceRepository.applicationSupport()
    ) -> IdeaForgeStore {
        let state: WorkspaceState
        let loadErrorMessage: String?
        do {
            state = try repository.load() ?? .fresh()
            loadErrorMessage = nil
        } catch {
            state = .fresh()
            loadErrorMessage = "Workspace data could not be loaded. The original file was left unchanged."
            IdeaForgeLog.lifecycle.error("Workspace load failed; existing storage was left unchanged")
        }
        IdeaForgeLog.lifecycle.info("Loaded workspace with \(state.projects.count, privacy: .public) projects and \(state.uploadJobs.count, privacy: .public) upload jobs")
        let store = IdeaForgeStore(state: state, repository: repository)
        store.lastErrorMessage = loadErrorMessage
        store.workspaceLoadFailed = loadErrorMessage != nil
        store.recoverInterruptedUploads()
        return store
    }

    public convenience init(state: WorkspaceState, repository: any WorkspaceRepository = InMemoryWorkspaceRepository()) {
        self.init(
            projects: state.projects,
            workflowTemplates: state.workflowTemplates,
            uploadJobs: state.uploadJobs,
            selectedProjectID: state.selectedProjectID,
            privacyMode: state.privacyMode,
            syncHealth: state.syncHealth,
            updatedAt: state.updatedAt,
            repository: repository
        )
    }

    public func workspaceState(now: Date? = nil) -> WorkspaceState {
        WorkspaceState(
            projects: projects,
            workflowTemplates: workflowTemplates,
            uploadJobs: uploadJobs,
            privacyMode: privacyMode,
            syncHealth: syncHealth,
            selectedProjectID: selectedProjectID,
            updatedAt: now ?? updatedAt
        )
    }

    private func restoreLiveState(_ state: WorkspaceState) {
        projects = state.projects
        workflowTemplates = state.workflowTemplates
        uploadJobs = state.uploadJobs
        selectedProjectID = state.selectedProjectID
        privacyMode = state.privacyMode
        syncHealth = state.syncHealth
        updatedAt = state.updatedAt
    }

    @discardableResult
    public func recordSyncActivity(
        _ receipt: WorkspaceSyncActivityReceipt,
        clearsLastError: Bool = false
    ) -> Bool {
        let originalState = workspaceState()
        let previousError = lastErrorMessage
        syncHealth.lastActivity = receipt
        let persisted = persistCurrentState()
        guard persisted else {
            restoreLiveState(originalState)
            lastErrorMessage = "Sync activity could not be saved."
            return false
        }
        if !clearsLastError {
            lastErrorMessage = previousError
        }
        return true
    }

    @discardableResult
    public func save(now: Date = Date()) -> Bool {
        let originalUpdatedAt = updatedAt
        updatedAt = now
        guard persistCurrentState() else {
            updatedAt = originalUpdatedAt
            return false
        }
        return true
    }

    @discardableResult
    private func persistCurrentState() -> Bool {
        guard !workspaceLoadFailed else {
            lastErrorMessage = "Workspace data could not be loaded. The original file was left unchanged."
            IdeaForgeLog.workspace.error("Workspace persistence blocked because the stored workspace is unreadable")
            return false
        }
        do {
            try repository.save(workspaceState())
            lastErrorMessage = nil
            return true
        } catch {
            lastErrorMessage = "Could not save workspace."
            IdeaForgeLog.workspace.error("Workspace persistence failed")
            return false
        }
    }

    public func projectDeletionReadiness(projectID: String) -> ProjectDeletionReadiness {
        ProjectDeletionPolicy.readiness(
            for: projects.first { $0.id == projectID },
            projectID: projectID,
            uploadJobs: uploadJobs
        )
    }

    @discardableResult
    public func deleteProject(
        _ projectID: String,
        now: Date = Date(),
        fileManager: FileManager = .default,
        managedRecordingDirectory: URL? = nil
    ) -> Bool {
        let readiness = projectDeletionReadiness(projectID: projectID)
        guard readiness.canDelete else {
            lastErrorMessage = readiness.message
            IdeaForgeLog.workspace.warning("Project deletion blocked; blockers: \(readiness.blockers.count, privacy: .public)")
            return false
        }

        let originalState = workspaceState()
        let deletedProject = projects.first { $0.id == projectID }
        let recordingPaths = Set(
            (deletedProject?.recordings.compactMap(\.localAudioPath) ?? [])
                + uploadJobs.filter { $0.ideaProjectID == projectID }.map(\.localAudioPath)
        )
        projects.removeAll { $0.id == projectID }
        uploadJobs.removeAll { $0.ideaProjectID == projectID }
        if selectedProjectID == projectID || selectedProjectID.map({ selectedID in
            !projects.contains { $0.id == selectedID }
        }) == true {
            selectedProjectID = projects.first?.id
        }
        syncHealth.queuedUploads = activeUploadJobs.count
        updatedAt = now
        guard persistCurrentState() else {
            restoreLiveState(originalState)
            lastErrorMessage = "Could not delete the project because the workspace was not saved."
            return false
        }
        IdeaForgeLog.workspace.info("Deleted project after safety checks; remaining projects: \(self.projects.count, privacy: .public)")
        let survivingRecordingPaths = Set(
            projects.flatMap(\.recordings).compactMap(\.localAudioPath)
                + uploadJobs.map(\.localAudioPath)
        )
        let cleanupFailureCount = ManagedRecordingFileCleanup.removeFiles(
            at: recordingPaths.subtracting(survivingRecordingPaths),
            within: managedRecordingDirectory ?? ManagedRecordingFileCleanup.defaultDirectory(fileManager: fileManager),
            fileManager: fileManager
        )
        if cleanupFailureCount > 0 {
            lastErrorMessage = "Project deleted, but some local recording files could not be removed."
            IdeaForgeLog.workspace.warning("Project recording cleanup was incomplete; failure count: \(cleanupFailureCount, privacy: .public)")
        }
        return true
    }

    public func setPrivacyMode(_ mode: PrivacyMode) {
        privacyMode = mode
        IdeaForgeLog.settings.info("Privacy mode changed to \(mode.rawValue, privacy: .public)")
        save()
    }

    public func validateWorkflowTemplateCustomization(_ customization: WorkflowTemplateCustomization) -> WorkflowTemplateValidation {
        guard let base = workflowTemplates.first(where: { $0.id == customization.baseTemplateID }) else {
            return WorkflowTemplateValidation(
                errors: ["Base workflow template missing: \(customization.baseTemplateID)."]
            )
        }

        var errors: [String] = []
        var warnings: [String] = []

        if customization.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Workflow variant name is required.")
        }

        let knownStepIDs = Set(base.steps.map(\.id))
        var seenStepIDs: Set<String> = []
        for update in customization.stepUpdates {
            if !knownStepIDs.contains(update.stepID) {
                errors.append("Unknown workflow step: \(update.stepID).")
                continue
            }

            if seenStepIDs.contains(update.stepID) {
                warnings.append("Step \(update.stepID) has multiple updates; the last update wins.")
            }
            seenStepIDs.insert(update.stepID)

            if let name = update.name, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append("Step \(update.stepID) must keep a non-empty name.")
            }
            if let outputSchemaName = update.outputSchemaName,
               outputSchemaName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append("Step \(update.stepID) must keep a non-empty output schema.")
            }
            if let promptBody = update.promptBody,
               promptBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append("Step \(update.stepID) must keep a non-empty prompt body.")
            }
            if let inputKeys = update.inputKeys,
               inputKeys.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                errors.append("Step \(update.stepID) input keys cannot be empty.")
            }
        }

        for contract in customization.schemaContracts {
            if contract.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append("Workflow schema contract name is required.")
            }
            let fieldNames = contract.fields.map(\.name)
            let duplicateFieldNames = fieldNames.duplicates()
            if !duplicateFieldNames.isEmpty {
                errors.append("Workflow schema \(contract.name) has duplicate fields: \(duplicateFieldNames.joined(separator: ", ")).")
            }
            if contract.fields.contains(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                errors.append("Workflow schema \(contract.name) field names cannot be empty.")
            }
        }

        let updatesByStepID = workflowStepUpdatesByID(customization.stepUpdates)
        let estimatedSteps = base.steps.map { step in
            customizedWorkflowStep(step, update: updatesByStepID[step.id])
        }
        let schemaContracts = workflowSchemaContractsByName(base.schemaContracts + customization.schemaContracts)
        for step in estimatedSteps {
            guard let contract = schemaContracts[step.outputSchemaName] else {
                errors.append("Workflow schema contract missing: \(step.outputSchemaName).")
                continue
            }
            let missingInputKeys = contract.requiredInputKeys.filter { !step.inputKeys.contains($0) }
            if !missingInputKeys.isEmpty {
                errors.append("Step \(step.id) missing schema inputs: \(missingInputKeys.joined(separator: ", ")).")
            }
        }

        return WorkflowTemplateValidation(
            errors: errors,
            warnings: warnings,
            costEstimate: WorkflowTemplateCostEstimate(steps: estimatedSteps)
        )
    }

    @discardableResult
    public func createCustomWorkflowTemplate(_ customization: WorkflowTemplateCustomization) -> WorkflowTemplate? {
        let validation = validateWorkflowTemplateCustomization(customization)
        guard validation.canCreate,
              let base = workflowTemplates.first(where: { $0.id == customization.baseTemplateID }) else {
            IdeaForgeLog.workflow.warning("Custom workflow creation skipped; validation errors: \(validation.errors.count, privacy: .public)")
            return nil
        }

        let updatesByStepID = workflowStepUpdatesByID(customization.stepUpdates)
        let customID = uniqueWorkflowTemplateID(baseID: base.id, name: customization.name)
        let custom = WorkflowTemplate(
            id: customID,
            name: customization.name.trimmingCharacters(in: .whitespacesAndNewlines),
            summary: customization.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? base.summary
                : customization.summary.trimmingCharacters(in: .whitespacesAndNewlines),
            outputKinds: base.outputKinds,
            steps: base.steps.map { step in
                customizedWorkflowStep(step, update: updatesByStepID[step.id])
            },
            schemaContracts: customization.schemaContracts,
            variables: base.variables
        )
        workflowTemplates.append(custom)
        IdeaForgeLog.workflow.info("Custom workflow template created: \(custom.id, privacy: .public)")
        save()
        return custom
    }

    @discardableResult
    public func updateWorkflowStep(
        templateID: String,
        stepID: String,
        update: WorkflowStepUpdate
    ) -> Bool {
        guard update.stepID == stepID else {
            lastErrorMessage = "Workflow step update mismatch."
            IdeaForgeLog.workflow.warning("Workflow step edit skipped; step update mismatch")
            return false
        }
        guard let templateIndex = workflowTemplates.firstIndex(where: { $0.id == templateID }) else {
            lastErrorMessage = "Workflow template missing."
            IdeaForgeLog.workflow.warning("Workflow step edit skipped; template missing")
            return false
        }

        var template = workflowTemplates[templateIndex]
        guard let stepIndex = template.steps.firstIndex(where: { $0.id == stepID }) else {
            lastErrorMessage = "Workflow step missing."
            IdeaForgeLog.workflow.warning("Workflow step edit skipped; step missing")
            return false
        }

        let currentStep = template.steps[stepIndex]
        let editedStep = customizedWorkflowStep(currentStep, update: update)
        guard workflowStepIsValid(editedStep, in: template) else {
            return false
        }

        guard editedStep != currentStep else {
            return true
        }

        template.steps[stepIndex] = editedStep
        workflowTemplates[templateIndex] = template
        IdeaForgeLog.workflow.info("Workflow step updated for template \(templateID, privacy: .public)")
        save()
        return true
    }

    private func workflowStepIsValid(_ step: WorkflowStep, in template: WorkflowTemplate) -> Bool {
        guard !step.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastErrorMessage = "Workflow step name is required."
            IdeaForgeLog.workflow.warning("Workflow step edit skipped; blank name")
            return false
        }
        guard !step.outputSchemaName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastErrorMessage = "Workflow step output schema is required."
            IdeaForgeLog.workflow.warning("Workflow step edit skipped; blank output schema")
            return false
        }
        guard !step.promptBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastErrorMessage = "Workflow step prompt body is required."
            IdeaForgeLog.workflow.warning("Workflow step edit skipped; blank prompt body")
            return false
        }
        guard !step.inputKeys.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            lastErrorMessage = "Workflow step input keys cannot be empty."
            IdeaForgeLog.workflow.warning("Workflow step edit skipped; blank input key")
            return false
        }
        guard let contract = template.schemaContract(named: step.outputSchemaName) else {
            lastErrorMessage = "Workflow schema contract missing."
            IdeaForgeLog.workflow.warning("Workflow step edit skipped; schema contract missing")
            return false
        }
        let missingInputKeys = contract.requiredInputKeys.filter { !step.inputKeys.contains($0) }
        guard missingInputKeys.isEmpty else {
            lastErrorMessage = "Workflow step is missing required schema inputs."
            IdeaForgeLog.workflow.warning("Workflow step edit skipped; missing schema inputs")
            return false
        }
        return true
    }

    @discardableResult
    public func addWorkflowVariable(
        templateID: String,
        variable: WorkflowVariable
    ) -> Bool {
        guard let normalizedVariable = normalizedWorkflowVariable(variable) else {
            return false
        }
        guard let templateIndex = workflowTemplates.firstIndex(where: { $0.id == templateID }) else {
            lastErrorMessage = "Workflow template missing."
            IdeaForgeLog.workflow.warning("Workflow variable add skipped; template missing")
            return false
        }
        guard !workflowTemplates[templateIndex].variables.contains(where: { $0.key == normalizedVariable.key }) else {
            lastErrorMessage = "Workflow variable already exists."
            IdeaForgeLog.workflow.warning("Workflow variable add skipped; duplicate key")
            return false
        }

        workflowTemplates[templateIndex].variables.append(normalizedVariable)
        IdeaForgeLog.workflow.info("Workflow variable added for template \(templateID, privacy: .public)")
        save()
        return true
    }

    @discardableResult
    public func updateWorkflowVariable(
        templateID: String,
        variableKey: String,
        variable: WorkflowVariable
    ) -> Bool {
        let currentKey = variableKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currentKey.isEmpty else {
            lastErrorMessage = "Workflow variable missing."
            IdeaForgeLog.workflow.warning("Workflow variable update skipped; blank key")
            return false
        }
        guard let normalizedVariable = normalizedWorkflowVariable(variable) else {
            return false
        }
        guard let templateIndex = workflowTemplates.firstIndex(where: { $0.id == templateID }) else {
            lastErrorMessage = "Workflow template missing."
            IdeaForgeLog.workflow.warning("Workflow variable update skipped; template missing")
            return false
        }
        guard let variableIndex = workflowTemplates[templateIndex].variables.firstIndex(where: { $0.key == currentKey }) else {
            lastErrorMessage = "Workflow variable missing."
            IdeaForgeLog.workflow.warning("Workflow variable update skipped; variable missing")
            return false
        }
        guard !workflowTemplates[templateIndex].variables.contains(where: { $0.key != currentKey && $0.key == normalizedVariable.key }) else {
            lastErrorMessage = "Workflow variable already exists."
            IdeaForgeLog.workflow.warning("Workflow variable update skipped; duplicate key")
            return false
        }

        workflowTemplates[templateIndex].variables[variableIndex] = normalizedVariable
        IdeaForgeLog.workflow.info("Workflow variable updated for template \(templateID, privacy: .public)")
        save()
        return true
    }

    @discardableResult
    public func deleteWorkflowVariable(
        templateID: String,
        variableKey: String
    ) -> Bool {
        let key = variableKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            lastErrorMessage = "Workflow variable missing."
            IdeaForgeLog.workflow.warning("Workflow variable delete skipped; blank key")
            return false
        }
        guard let templateIndex = workflowTemplates.firstIndex(where: { $0.id == templateID }) else {
            lastErrorMessage = "Workflow template missing."
            IdeaForgeLog.workflow.warning("Workflow variable delete skipped; template missing")
            return false
        }
        guard let variableIndex = workflowTemplates[templateIndex].variables.firstIndex(where: { $0.key == key }) else {
            lastErrorMessage = "Workflow variable missing."
            IdeaForgeLog.workflow.warning("Workflow variable delete skipped; variable missing")
            return false
        }

        workflowTemplates[templateIndex].variables.remove(at: variableIndex)
        IdeaForgeLog.workflow.info("Workflow variable deleted for template \(templateID, privacy: .public)")
        save()
        return true
    }

    private func normalizedWorkflowVariable(_ variable: WorkflowVariable) -> WorkflowVariable? {
        let key = variable.key.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = variable.value.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = variable.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            lastErrorMessage = "Workflow variable key is required."
            IdeaForgeLog.workflow.warning("Workflow variable edit skipped; blank key")
            return nil
        }
        guard workflowVariableKeyIsValid(key) else {
            lastErrorMessage = "Workflow variable keys must use letters, numbers, and underscores."
            IdeaForgeLog.workflow.warning("Workflow variable edit skipped; invalid key")
            return nil
        }
        guard !value.isEmpty else {
            lastErrorMessage = "Workflow variable value is required."
            IdeaForgeLog.workflow.warning("Workflow variable edit skipped; blank value")
            return nil
        }
        guard !summary.isEmpty else {
            lastErrorMessage = "Workflow variable summary is required."
            IdeaForgeLog.workflow.warning("Workflow variable edit skipped; blank summary")
            return nil
        }
        return WorkflowVariable(key: key, value: value, summary: summary)
    }

    private func workflowVariableKeyIsValid(_ key: String) -> Bool {
        key.allSatisfy { character in
            character == "_" || character.isLetter || character.isNumber
        }
    }

    @discardableResult
    public func addWorkflowSchemaField(
        templateID: String,
        schemaName: String,
        field: WorkflowSchemaField
    ) -> Bool {
        guard let normalizedField = normalizedWorkflowSchemaField(field) else {
            return false
        }
        guard updateWorkflowSchemaContract(templateID: templateID, schemaName: schemaName, action: "add", edit: { contract in
            guard !contract.fields.contains(where: { $0.name == normalizedField.name }) else {
                lastErrorMessage = "Workflow schema field already exists."
                IdeaForgeLog.workflow.warning("Workflow schema field edit skipped; duplicate field")
                return false
            }
            contract.fields.append(normalizedField)
            return true
        }) else {
            return false
        }
        IdeaForgeLog.workflow.info("Workflow schema field added for template \(templateID, privacy: .public)")
        save()
        return true
    }

    @discardableResult
    public func updateWorkflowSchemaField(
        templateID: String,
        schemaName: String,
        fieldName: String,
        updatedField: WorkflowSchemaField
    ) -> Bool {
        let existingName = fieldName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !existingName.isEmpty else {
            lastErrorMessage = "Workflow schema field missing."
            IdeaForgeLog.workflow.warning("Workflow schema field update skipped; blank field name")
            return false
        }
        guard let normalizedField = normalizedWorkflowSchemaField(updatedField) else {
            return false
        }
        guard updateWorkflowSchemaContract(templateID: templateID, schemaName: schemaName, action: "update", edit: { contract in
            guard let fieldIndex = contract.fields.firstIndex(where: { $0.name == existingName }) else {
                lastErrorMessage = "Workflow schema field missing."
                IdeaForgeLog.workflow.warning("Workflow schema field update skipped; field missing")
                return false
            }
            let isDuplicate = contract.fields.enumerated().contains { index, field in
                index != fieldIndex && field.name == normalizedField.name
            }
            guard !isDuplicate else {
                lastErrorMessage = "Workflow schema field already exists."
                IdeaForgeLog.workflow.warning("Workflow schema field update skipped; duplicate field")
                return false
            }
            contract.fields[fieldIndex] = normalizedField
            return true
        }) else {
            return false
        }
        IdeaForgeLog.workflow.info("Workflow schema field updated for template \(templateID, privacy: .public)")
        save()
        return true
    }

    @discardableResult
    public func deleteWorkflowSchemaField(
        templateID: String,
        schemaName: String,
        fieldName: String
    ) -> Bool {
        let existingName = fieldName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !existingName.isEmpty else {
            lastErrorMessage = "Workflow schema field missing."
            IdeaForgeLog.workflow.warning("Workflow schema field delete skipped; blank field name")
            return false
        }
        guard updateWorkflowSchemaContract(templateID: templateID, schemaName: schemaName, action: "delete", edit: { contract in
            guard let fieldIndex = contract.fields.firstIndex(where: { $0.name == existingName }) else {
                lastErrorMessage = "Workflow schema field missing."
                IdeaForgeLog.workflow.warning("Workflow schema field delete skipped; field missing")
                return false
            }
            contract.fields.remove(at: fieldIndex)
            return true
        }) else {
            return false
        }
        IdeaForgeLog.workflow.info("Workflow schema field deleted for template \(templateID, privacy: .public)")
        save()
        return true
    }

    @discardableResult
    public func moveWorkflowSchemaField(
        templateID: String,
        schemaName: String,
        fieldName: String,
        direction: WorkflowSchemaFieldMoveDirection
    ) -> Bool {
        let existingName = fieldName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !existingName.isEmpty else {
            lastErrorMessage = "Workflow schema field missing."
            IdeaForgeLog.workflow.warning("Workflow schema field move skipped; blank field name")
            return false
        }
        guard updateWorkflowSchemaContract(templateID: templateID, schemaName: schemaName, action: "move", edit: { contract in
            guard let fieldIndex = contract.fields.firstIndex(where: { $0.name == existingName }) else {
                lastErrorMessage = "Workflow schema field missing."
                IdeaForgeLog.workflow.warning("Workflow schema field move skipped; field missing")
                return false
            }
            let targetIndex: Int
            switch direction {
            case .up:
                targetIndex = fieldIndex - 1
            case .down:
                targetIndex = fieldIndex + 1
            }
            guard contract.fields.indices.contains(targetIndex) else {
                lastErrorMessage = "Workflow schema field cannot move farther."
                IdeaForgeLog.workflow.warning("Workflow schema field move skipped; boundary reached")
                return false
            }
            contract.fields.swapAt(fieldIndex, targetIndex)
            return true
        }) else {
            return false
        }
        IdeaForgeLog.workflow.info("Workflow schema field moved for template \(templateID, privacy: .public)")
        save()
        return true
    }

    private func normalizedWorkflowSchemaField(_ field: WorkflowSchemaField) -> WorkflowSchemaField? {
        let fieldName = field.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let valueType = field.valueType.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = field.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fieldName.isEmpty, !valueType.isEmpty, !summary.isEmpty else {
            lastErrorMessage = "Workflow schema fields need a name, type, and summary."
            IdeaForgeLog.workflow.warning("Workflow schema field edit skipped; blank field metadata")
            return nil
        }
        return WorkflowSchemaField(
            name: fieldName,
            valueType: valueType,
            isRequired: field.isRequired,
            summary: summary
        )
    }

    @discardableResult
    private func updateWorkflowSchemaContract(
        templateID: String,
        schemaName: String,
        action: String,
        edit: (inout WorkflowSchemaContract) -> Bool
    ) -> Bool {
        guard let templateIndex = workflowTemplates.firstIndex(where: { $0.id == templateID }) else {
            lastErrorMessage = "Workflow template missing."
            IdeaForgeLog.workflow.warning("Workflow schema field \(action, privacy: .public) skipped; template missing")
            return false
        }

        var template = workflowTemplates[templateIndex]
        var contracts = template.schemaContracts
        let contractIndex: Int
        if let existingIndex = contracts.firstIndex(where: { $0.name == schemaName }) {
            contractIndex = existingIndex
        } else if let inheritedContract = template.schemaContract(named: schemaName) {
            contracts.append(inheritedContract)
            contractIndex = contracts.index(before: contracts.endIndex)
        } else {
            lastErrorMessage = "Workflow schema contract missing."
            IdeaForgeLog.workflow.warning("Workflow schema field \(action, privacy: .public) skipped; schema contract missing")
            return false
        }

        var contract = contracts[contractIndex]
        guard edit(&contract) else {
            return false
        }
        contracts[contractIndex] = contract
        template.schemaContracts = contracts
        workflowTemplates[templateIndex] = template
        return true
    }

    @discardableResult
    public func createProject(from draft: RecordingDraft, transcript: Transcript, recording: Recording) -> IdeaProject? {
        let originalState = workspaceState()
        let now = Date()
        let projectID = recording.ideaProjectID
        let project = IdeaProject(
            id: projectID,
            title: draft.projectTitle.isEmpty ? "Untitled Idea" : draft.projectTitle,
            status: .inbox,
            source: draft.source,
            createdAt: now,
            updatedAt: now,
            summary: transcript.cleanText,
            tags: [draft.tag],
            score: IdeaScore(confidence: 0.35, completeness: 0.2, risk: 0.65),
            transcript: transcript,
            recordings: [recording],
            questions: [
                Question(
                    id: "q_first_user_\(projectID)",
                    prompt: "Who is the first user and what do they use today?",
                    answer: nil,
                    isBlocking: true
                )
            ],
            artifacts: [],
            assumptions: [],
            validationExperiments: [],
            codexTasks: []
        )
        projects.insert(project, at: 0)
        selectedProjectID = project.id
        enqueueUploadJobIfNeeded(for: recording, now: now)
        syncHealth.queuedUploads = activeUploadJobs.count
        IdeaForgeLog.recording.info("Created idea project from \(draft.source.rawValue, privacy: .public) capture; queued uploads: \(self.activeUploadJobs.count, privacy: .public)")
        guard save() else {
            restoreLiveState(originalState)
            lastErrorMessage = "Could not save workspace."
            return nil
        }
        return project
    }

    @discardableResult
    public func attach(recording: Recording, to projectID: String, transcript _: Transcript) -> Bool {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return false }
        guard !projects[index].recordings.contains(where: { $0.id == recording.id }) else {
            IdeaForgeLog.recording.info("Skipped duplicate recording attach; project recording count: \(self.projects[index].recordings.count, privacy: .public)")
            return true
        }
        let originalState = workspaceState()
        projects[index].recordings.insert(recording, at: 0)
        projects[index].updatedAt = Date()
        enqueueUploadJobIfNeeded(for: recording)
        syncHealth.queuedUploads = activeUploadJobs.count
        IdeaForgeLog.recording.info("Attached recording to existing project; queued uploads: \(self.activeUploadJobs.count, privacy: .public)")
        guard save() else {
            restoreLiveState(originalState)
            lastErrorMessage = "Could not save workspace."
            return false
        }
        return true
    }

    @discardableResult
    public func repairTransferredRecordingAudio(
        recordingID: String,
        localAudioPath: String,
        now: Date = Date()
    ) -> IdeaProject? {
        guard let projectIndex = projects.firstIndex(where: { project in
            project.recordings.contains { $0.id == recordingID }
        }), let recordingIndex = projects[projectIndex].recordings.firstIndex(where: { $0.id == recordingID }) else {
            return nil
        }
        let originalState = workspaceState()
        let wasFailed = projects[projectIndex].recordings[recordingIndex].syncStatus == .failed
        projects[projectIndex].recordings[recordingIndex].localAudioPath = localAudioPath
        projects[projectIndex].recordings[recordingIndex].localFileStatus = .available
        projects[projectIndex].recordings[recordingIndex].syncStatus = .transferredToIPhone
        projects[projectIndex].recordings[recordingIndex].processingDiagnostic = nil
        projects[projectIndex].updatedAt = max(projects[projectIndex].updatedAt, now)
        if let jobIndex = uploadJobs.firstIndex(where: { $0.recordingID == recordingID }) {
            uploadJobs[jobIndex].localAudioPath = localAudioPath
            uploadJobs[jobIndex].status = .queued
            uploadJobs[jobIndex].attemptCount = 0
            uploadJobs[jobIndex].nextAttemptAt = now
            uploadJobs[jobIndex].objectKey = nil
            uploadJobs[jobIndex].lastErrorMessage = nil
            uploadJobs[jobIndex].failureCategory = nil
            uploadJobs[jobIndex].updatedAt = now
        } else {
            enqueueUploadJobIfNeeded(for: projects[projectIndex].recordings[recordingIndex], now: now)
        }
        if wasFailed {
            syncHealth.failingItems = max(0, syncHealth.failingItems - 1)
        }
        syncHealth.queuedUploads = activeUploadJobs.count
        guard save(now: max(originalState.updatedAt, now)) else {
            restoreLiveState(originalState)
            lastErrorMessage = "Transferred recording repair could not be saved."
            return nil
        }
        return projects[projectIndex]
    }

    @MainActor
    @discardableResult
    public func appendWatchRecording(
        _ draft: RecordingDraft,
        to projectID: String,
        services: IdeaForgeServices = .local
    ) async -> Recording? {
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }) else {
            lastErrorMessage = "Idea missing."
            IdeaForgeLog.recording.warning("Watch append skipped; project missing")
            return nil
        }

        if let requestedRecordingID = draft.recordingID,
           let existing = projects[projectIndex].recordings.first(where: { $0.id == requestedRecordingID }) {
            return existing
        }

        let now = Date()
        let recordingID = draft.recordingID ?? "rec_\(UUID().uuidString.lowercased())"
        let initialRecording = Recording(
            id: recordingID,
            ideaProjectID: projectID,
            deviceName: draft.source.label,
            durationSeconds: draft.durationSeconds,
            localFileStatus: .available,
            syncStatus: .pending,
            localAudioPath: draft.localAudioPath,
            languageHint: draft.languageHint,
            createdAt: now,
            markerOffsets: draft.markerOffsets
        )
        do {
            let syncStatus = try await services.syncQueue.enqueue(recording: initialRecording)
            guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }) else {
                lastErrorMessage = "Idea missing."
                IdeaForgeLog.recording.warning("Watch append stopped because the target project changed while queueing")
                return nil
            }
            if let existing = projects[projectIndex].recordings.first(where: { $0.id == recordingID }) {
                return existing
            }
            let originalState = workspaceState()
            let recording = Recording(
                id: initialRecording.id,
                ideaProjectID: initialRecording.ideaProjectID,
                deviceName: initialRecording.deviceName,
                durationSeconds: initialRecording.durationSeconds,
                localFileStatus: initialRecording.localFileStatus,
                syncStatus: syncStatus,
                localAudioPath: initialRecording.localAudioPath,
                audioObjectKey: initialRecording.audioObjectKey,
                languageHint: initialRecording.languageHint,
                createdAt: initialRecording.createdAt,
                markerOffsets: initialRecording.markerOffsets
            )
            projects[projectIndex].recordings.insert(recording, at: 0)
            projects[projectIndex].updatedAt = now
            projects[projectIndex].summary = appendedWatchSummary(
                currentSummary: projects[projectIndex].summary,
                durationSeconds: draft.durationSeconds
            )
            projects[projectIndex].transcript = transcriptWithQueuedWatchAppend(
                projects[projectIndex].transcript,
                recording: recording,
                hint: draft.transcriptHint
            )
            selectedProjectID = projectID
            enqueueUploadJobIfNeeded(for: recording, now: now)
            syncHealth.queuedUploads = activeUploadJobs.count
            IdeaForgeLog.recording.info("Appended watch recording to existing project; queued uploads: \(self.activeUploadJobs.count, privacy: .public)")
            guard save(now: now) else {
                restoreLiveState(originalState)
                lastErrorMessage = "Watch append could not be saved."
                IdeaForgeLog.recording.error("Watch append failed because workspace persistence failed")
                return nil
            }
            return recording
        } catch {
            lastErrorMessage = "Append failed."
            IdeaForgeLog.recording.error("Watch append failed")
            return nil
        }
    }

    private func workflowSchemaContractsByName(_ customContracts: [WorkflowSchemaContract]) -> [String: WorkflowSchemaContract] {
        var contractsByName = Dictionary(uniqueKeysWithValues: DefaultWorkflows.schemaContracts.map { ($0.name, $0) })
        for contract in customContracts {
            contractsByName[contract.name] = contract
        }
        return contractsByName
    }

    private func workflowStepUpdatesByID(_ updates: [WorkflowStepUpdate]) -> [String: WorkflowStepUpdate] {
        var updatesByStepID: [String: WorkflowStepUpdate] = [:]
        for update in updates {
            updatesByStepID[update.stepID] = update
        }
        return updatesByStepID
    }

    private func customizedWorkflowStep(_ step: WorkflowStep, update: WorkflowStepUpdate?) -> WorkflowStep {
        guard let update else { return step }
        return WorkflowStep(
            id: step.id,
            name: update.name?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? step.name,
            kind: step.kind,
            inputKeys: update.inputKeys ?? step.inputKeys,
            outputSchemaName: update.outputSchemaName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? step.outputSchemaName,
            promptBody: update.promptBody?.trimmingCharacters(in: .whitespacesAndNewlines) ?? step.promptBody,
            requiresUserReview: update.requiresUserReview ?? step.requiresUserReview,
            modelPolicy: update.modelPolicy ?? step.modelPolicy,
            version: step.version + 1
        )
    }

    private func uniqueWorkflowTemplateID(baseID: String, name: String) -> String {
        let slug = name
            .lowercased()
            .map { character -> Character in
                character.isLetter || character.isNumber ? character : "_"
            }
        let compactSlug = String(slug)
            .split(separator: "_")
            .joined(separator: "_")
        let baseSlug = compactSlug.isEmpty ? "custom" : compactSlug
        var candidate = "\(baseID)_custom_\(baseSlug)"
        var suffix = 2
        let existingIDs = Set(workflowTemplates.map(\.id))
        while existingIDs.contains(candidate) {
            candidate = "\(baseID)_custom_\(baseSlug)_\(suffix)"
            suffix += 1
        }
        return candidate
    }

    public func answerQuestion(_ questionID: String, answer: String) {
        for projectIndex in projects.indices {
            guard let questionIndex = projects[projectIndex].questions.firstIndex(where: { $0.id == questionID }) else {
                continue
            }
            projects[projectIndex].questions[questionIndex].answer = answer
            projects[projectIndex].updatedAt = Date()
            selectedProjectID = projects[projectIndex].id
            save()
            return
        }
    }

    @discardableResult
    public func updateTranscriptText(_ text: String, projectID: String, now: Date = Date()) -> Bool {
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }) else {
            lastErrorMessage = "Project missing."
            IdeaForgeLog.workspace.warning("Transcript edit skipped; project missing")
            return false
        }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            lastErrorMessage = "Transcript cannot be empty."
            IdeaForgeLog.workspace.warning("Transcript edit skipped; empty transcript")
            return false
        }

        projects[projectIndex].transcript.cleanText = trimmedText
        projects[projectIndex].summary = trimmedText
        projects[projectIndex].updatedAt = now
        selectedProjectID = projectID
        IdeaForgeLog.workspace.info("Transcript edited for project \(projectID, privacy: .private)")
        return save(now: now)
    }

    @discardableResult
    public func updateTranscriptSegment(
        projectID: String,
        segmentID: String,
        text: String,
        isMarkedImportant: Bool,
        now: Date = Date()
    ) -> Bool {
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }) else {
            lastErrorMessage = "Project missing."
            IdeaForgeLog.workspace.warning("Transcript segment edit skipped; project missing")
            return false
        }

        guard let segmentIndex = projects[projectIndex].transcript.segments.firstIndex(where: { $0.id == segmentID }) else {
            lastErrorMessage = "Transcript segment missing."
            IdeaForgeLog.workspace.warning("Transcript segment edit skipped; segment missing")
            return false
        }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            lastErrorMessage = "Transcript segment cannot be empty."
            IdeaForgeLog.workspace.warning("Transcript segment edit skipped; empty segment")
            return false
        }

        projects[projectIndex].transcript.segments[segmentIndex].text = trimmedText
        projects[projectIndex].transcript.segments[segmentIndex].isMarkedImportant = isMarkedImportant
        projects[projectIndex].updatedAt = now
        selectedProjectID = projectID
        IdeaForgeLog.workspace.info("Transcript segment edited for project \(projectID, privacy: .private); segment: \(segmentID, privacy: .private)")
        return save(now: now)
    }

    @discardableResult
    public func addValidationExperiment(
        projectID: String,
        title: String,
        metric: String,
        goNoGoCriteria: String,
        now: Date = Date()
    ) -> Bool {
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }) else {
            lastErrorMessage = "Project missing."
            IdeaForgeLog.workspace.warning("Validation experiment skipped; project missing")
            return false
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMetric = metric.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCriteria = goNoGoCriteria.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, !trimmedMetric.isEmpty, !trimmedCriteria.isEmpty else {
            lastErrorMessage = "Validation experiment needs a title, metric, and go/no-go criteria."
            IdeaForgeLog.workspace.warning("Validation experiment skipped; incomplete planner item")
            return false
        }

        let nextIndex = projects[projectIndex].validationExperiments.count + 1
        let experiment = ValidationExperiment(
            id: "validation_\(projectID)_\(nextIndex)",
            title: trimmedTitle,
            metric: trimmedMetric,
            goNoGoCriteria: trimmedCriteria
        )
        projects[projectIndex].validationExperiments.append(experiment)
        projects[projectIndex].updatedAt = now
        selectedProjectID = projectID
        IdeaForgeLog.workspace.info("Validation experiment added for project \(projectID, privacy: .private); count: \(self.projects[projectIndex].validationExperiments.count, privacy: .public)")
        return save(now: now)
    }

    @discardableResult
    public func addAssumption(
        projectID: String,
        text: String,
        evidence: String,
        confidence: Double,
        now: Date = Date()
    ) -> Bool {
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }) else {
            lastErrorMessage = "Project missing."
            IdeaForgeLog.workspace.warning("Assumption skipped; project missing")
            return false
        }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEvidence = evidence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty, !trimmedEvidence.isEmpty else {
            lastErrorMessage = "Assumption needs text and evidence."
            IdeaForgeLog.workspace.warning("Assumption skipped; incomplete tracker item")
            return false
        }

        let nextIndex = projects[projectIndex].assumptions.count + 1
        let assumption = Assumption(
            id: "assumption_\(projectID)_\(nextIndex)",
            text: trimmedText,
            confidence: min(max(confidence, 0), 1),
            evidence: trimmedEvidence
        )
        projects[projectIndex].assumptions.append(assumption)
        projects[projectIndex].updatedAt = now
        selectedProjectID = projectID
        IdeaForgeLog.workspace.info("Assumption added for project \(projectID, privacy: .private); count: \(self.projects[projectIndex].assumptions.count, privacy: .public)")
        return save(now: now)
    }

    @discardableResult
    public func updateArtifactMarkdown(
        artifactID: String,
        markdown: String,
        now: Date = Date()
    ) -> Bool {
        for projectIndex in projects.indices {
            guard let artifactIndex = projects[projectIndex].artifacts.firstIndex(where: { $0.id == artifactID }) else {
                continue
            }

            let trimmedMarkdown = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedMarkdown.isEmpty else {
                lastErrorMessage = "Artifact markdown cannot be empty."
                IdeaForgeLog.workspace.warning("Artifact edit skipped; empty markdown")
                return false
            }

            let artifact = projects[projectIndex].artifacts[artifactIndex]
            let nextVersion = (projects[projectIndex].artifacts
                .filter { $0.kind == artifact.kind }
                .map(\.version)
                .max() ?? artifact.version) + 1
            let editedArtifact = Artifact(
                id: uniqueArtifactEditID(baseID: artifact.id, version: nextVersion, existingArtifacts: projects[projectIndex].artifacts),
                kind: artifact.kind,
                title: artifact.title,
                markdown: trimmedMarkdown,
                version: nextVersion,
                createdBy: "manual-edit",
                createdAt: now,
                sourceWorkflowRunID: artifact.sourceWorkflowRunID
            )
            projects[projectIndex].artifacts.insert(editedArtifact, at: 0)
            projects[projectIndex].updatedAt = now
            selectedProjectID = projects[projectIndex].id
            IdeaForgeLog.workspace.info("Artifact edited for project \(self.projects[projectIndex].id, privacy: .private); kind: \(artifact.kind.rawValue, privacy: .public); version: \(nextVersion, privacy: .public)")
            return save(now: now)
        }

        lastErrorMessage = "Artifact missing."
        IdeaForgeLog.workspace.warning("Artifact edit skipped; artifact missing")
        return false
    }

    private func uniqueArtifactEditID(baseID: String, version: Int, existingArtifacts: [Artifact]) -> String {
        let existingIDs = Set(existingArtifacts.map(\.id))
        var candidate = "\(baseID)_edit_v\(version)"
        while existingIDs.contains(candidate) {
            candidate = "\(baseID)_edit_v\(version)_\(UUID().uuidString.lowercased())"
        }
        return candidate
    }

    public func addArtifacts(_ artifacts: [Artifact], to projectID: String) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        let existingIDs = Set(projects[index].artifacts.map(\.id))
        let newArtifacts = artifacts.filter { !existingIDs.contains($0.id) }
        projects[index].artifacts.insert(contentsOf: newArtifacts, at: 0)
        projects[index].status = projects[index].questions.contains { $0.answer == nil } ? .draft : .validated
        projects[index].updatedAt = Date()
        save()
    }

    @discardableResult
    public func markUploadSucceeded(recordingID: String, objectKey: String, now: Date = Date()) -> Bool {
        guard let jobIndex = uploadJobs.firstIndex(where: { $0.recordingID == recordingID }) else { return false }
        guard recording(withID: recordingID) != nil else { return false }
        let originalState = workspaceState()
        uploadJobs[jobIndex] = UploadQueuePolicy.markUploaded(uploadJobs[jobIndex], objectKey: objectKey, now: now)
        updateRecording(recordingID: recordingID, event: .uploaded(objectKey: objectKey), now: now)
        syncHealth.queuedUploads = activeUploadJobs.count
        IdeaForgeLog.sync.info("Upload succeeded for recording \(recordingID, privacy: .private); queued uploads: \(self.activeUploadJobs.count, privacy: .public)")
        guard save(now: max(originalState.updatedAt, now)) else {
            restoreLiveState(originalState)
            lastErrorMessage = "Upload completion could not be saved."
            return false
        }
        return true
    }

    @discardableResult
    public func markRecordingTransferredToIPhone(recordingID: String, now: Date = Date()) -> Bool {
        guard recording(withID: recordingID) != nil else { return false }
        let originalState = workspaceState()
        updateRecording(recordingID: recordingID, event: .transferredToIPhone, now: now)
        syncHealth.queuedUploads = activeUploadJobs.count
        IdeaForgeLog.sync.info("Watch recording import acknowledged by iPhone; recording: \(recordingID, privacy: .private)")
        guard save(now: max(originalState.updatedAt, now)) else {
            restoreLiveState(originalState)
            lastErrorMessage = "Watch transfer receipt could not be saved."
            return false
        }
        return true
    }

    @discardableResult
    public func markRecordingWatchTransferFailed(recordingID: String, now: Date = Date()) -> Bool {
        guard recording(withID: recordingID) != nil else { return false }
        let originalState = workspaceState()
        updateRecording(recordingID: recordingID, event: .watchTransferFailed, now: now)
        IdeaForgeLog.sync.error("Watch recording transfer delivery failed; recording: \(recordingID, privacy: .private)")
        guard save(now: max(originalState.updatedAt, now)) else {
            restoreLiveState(originalState)
            lastErrorMessage = "Watch transfer failure could not be saved."
            return false
        }
        return true
    }

    @MainActor
    public func processUploadedRecordingsForTranscription(
        services: IdeaForgeServices,
        maxRecordingsPerRun: Int = 2,
        now: Date = Date()
    ) async -> AIProcessingSummary {
        let candidates = projects
            .flatMap(\.recordings)
            .filter { recording in
                let isUploaded = recording.syncStatus == .uploaded
                let isRetryableFailure = recording.syncStatus == .failed
                    && recording.processingDiagnostic?.isRetryable == true
                return (isUploaded || isRetryableFailure) && recording.audioObjectKey?.isEmpty == false
            }
            .prefix(maxRecordingsPerRun)

        var summary = AIProcessingSummary()
        IdeaForgeLog.workflow.info("Processing uploaded recordings for transcription; candidate count: \(candidates.count, privacy: .public)")
        for recording in candidates {
            summary.attemptedCount += 1
            let wasFailedCandidate = recording.syncStatus == .failed
            updateRecording(recordingID: recording.id, event: .transcribing)
            save(now: now)

            do {
                let hint = projects.first { $0.id == recording.ideaProjectID }?.summary ?? ""
                let transcript = try await services.transcription.transcript(
                    for: recording,
                    hint: hint
                )
                if wasFailedCandidate {
                    syncHealth.failingItems = max(0, syncHealth.failingItems - 1)
                }
                apply(transcript: transcript, to: recording.ideaProjectID, recordingID: recording.id, now: now)
                summary.completedCount += 1
            } catch {
                let diagnostic = transcriptionFailureDiagnostic(for: error, failedAt: now)
                updateRecording(recordingID: recording.id, event: .transcriptionFailed)
                setProcessingDiagnostic(diagnostic, recordingID: recording.id, now: now)
                if !wasFailedCandidate {
                    syncHealth.failingItems += 1
                }
                save(now: now)
                summary.failedCount += 1
                lastErrorMessage = diagnostic.message
                IdeaForgeLog.workflow.error("Transcription failed for recording \(recording.id, privacy: .private); reason: \(diagnostic.message, privacy: .public)")
            }
        }

        IdeaForgeLog.workflow.info("Transcription run completed; attempted: \(summary.attemptedCount, privacy: .public), completed: \(summary.completedCount, privacy: .public), failed: \(summary.failedCount, privacy: .public)")
        return summary
    }

    @MainActor
    public func processLocalRecordingsForSpeechTranscription(
        services: IdeaForgeServices = .localSpeech,
        maxRecordingsPerRun: Int = 2,
        now: Date = Date()
    ) async -> AIProcessingSummary {
        let candidates = projects
            .flatMap(\.recordings)
            .filter { recording in
                guard recording.localFileStatus == .available,
                      recording.localAudioPath?.isEmpty == false,
                      recording.syncStatus != .ready,
                      recording.syncStatus != .transcribing else {
                    return false
                }
                if recording.syncStatus == .failed {
                    return recording.processingDiagnostic?.isRetryable == true
                }
                return true
            }
            .prefix(maxRecordingsPerRun)

        var summary = AIProcessingSummary()
        IdeaForgeLog.workflow.info("Processing local recordings for speech transcription; candidate count: \(candidates.count, privacy: .public)")
        for recording in candidates {
            summary.attemptedCount += 1
            let wasFailedCandidate = recording.syncStatus == .failed
            updateRecording(recordingID: recording.id, event: .transcribing)
            save(now: now)

            do {
                let hint = projects.first { $0.id == recording.ideaProjectID }?.summary ?? ""
                let transcript = try await services.transcription.transcript(
                    for: recording,
                    hint: hint
                )
                if wasFailedCandidate {
                    syncHealth.failingItems = max(0, syncHealth.failingItems - 1)
                }
                apply(transcript: transcript, to: recording.ideaProjectID, recordingID: recording.id, now: now)
                summary.completedCount += 1
            } catch {
                let diagnostic = transcriptionFailureDiagnostic(for: error, failedAt: now)
                updateRecording(recordingID: recording.id, event: .transcriptionFailed)
                setProcessingDiagnostic(diagnostic, recordingID: recording.id, now: now)
                if !wasFailedCandidate {
                    syncHealth.failingItems += 1
                }
                save(now: now)
                summary.failedCount += 1
                lastErrorMessage = diagnostic.message
                IdeaForgeLog.workflow.error("Local speech transcription failed for recording \(recording.id, privacy: .private); reason: \(diagnostic.message, privacy: .public)")
            }
        }

        IdeaForgeLog.workflow.info("Local speech transcription run completed; attempted: \(summary.attemptedCount, privacy: .public), completed: \(summary.completedCount, privacy: .public), failed: \(summary.failedCount, privacy: .public)")
        return summary
    }

    @discardableResult
    public func applyRemoteWorkspaceSnapshot(
        _ incomingRemoteState: WorkspaceState,
        syncedAt: Date = Date(),
        conflictResolution: WorkspaceSyncConflictResolution = .failClosed
    ) throws -> Bool {
        let originalState = workspaceState()
        guard WorkspaceSyncPayloadPolicy.isStructurallyValid(originalState),
              WorkspaceSyncPayloadPolicy.isStructurallyValid(incomingRemoteState) else {
            throw BackendSyncError.invalidResponse
        }
        let remoteState = WorkspaceSyncPayloadPolicy.inboundState(
            from: incomingRemoteState,
            preservingDeviceLocalState: originalState
        )
        let isInitialHydration = syncHealth.lastRemoteWorkspaceUpdatedAt == nil
        let isResolvingKnownConflict: Bool
        switch conflictResolution {
        case .failClosed:
            isResolvingKnownConflict = false
        case .preserveLocalUploadWork, .preserveReviewedLocalWork:
            isResolvingKnownConflict = syncHealth.syncConflictStatus != nil
                && syncHealth.lastRemoteWorkspaceUpdatedAt == remoteState.updatedAt
        }
        guard isInitialHydration || isResolvingKnownConflict || remoteState.updatedAt > updatedAt else {
            syncHealth.lastSuccessfulSync = syncedAt
            syncHealth.lastRemoteWorkspaceUpdatedAt = max(
                syncHealth.lastRemoteWorkspaceUpdatedAt ?? remoteState.updatedAt,
                remoteState.updatedAt
            )
            guard persistCurrentState() else {
                restoreLiveState(originalState)
                lastErrorMessage = "Remote workspace could not be saved."
                throw WorkspaceRepositoryError.unwritableState
            }
            IdeaForgeLog.sync.info("Remote workspace snapshot ignored because local state is current")
            return false
        }

        let localState = workspaceState()
        if let conflictReport = WorkspaceSyncConflictReport.report(
            localState: localState,
            remoteState: remoteState
        ) {
            switch conflictResolution {
            case .preserveLocalUploadWork:
                try applyMergedRemoteSnapshot(
                    remoteState,
                    preserving: .preserveAll(report: conflictReport),
                    from: localState,
                    syncedAt: syncedAt
                )
                return true
            case .preserveReviewedLocalWork(let selection):
                try applyMergedRemoteSnapshot(
                    remoteState,
                    preserving: selection,
                    from: localState,
                    syncedAt: syncedAt
                )
                return true
            case .failClosed:
                break
            }

            syncHealth.lastSuccessfulSync = syncedAt
            syncHealth.lastRemoteWorkspaceUpdatedAt = remoteState.updatedAt
            syncHealth.queuedUploads = activeUploadJobs.count
            syncHealth.syncConflictStatus = WorkspaceSyncConflictStatus(
                report: conflictReport,
                localState: localState,
                remoteState: remoteState,
                detectedAt: syncedAt
            )
            guard persistCurrentState() else {
                restoreLiveState(originalState)
                lastErrorMessage = "Remote workspace could not be saved."
                throw WorkspaceRepositoryError.unwritableState
            }
            lastErrorMessage = conflictReport.message
            IdeaForgeLog.sync.error("Remote workspace snapshot blocked by sync conflict; local upload jobs: \(conflictReport.localOnlyUploadJobIDs.count, privacy: .public), local recordings: \(conflictReport.localOnlyRecordingIDs.count, privacy: .public)")
            throw WorkspaceSyncConflictError(report: conflictReport)
        }

        if case .preserveReviewedLocalWork(let selection) = conflictResolution,
           selection.hasProjectMergeWork {
            try applyMergedRemoteSnapshot(
                remoteState,
                preserving: selection,
                from: localState,
                syncedAt: syncedAt
            )
            return true
        }

        projects = remoteState.projects
        workflowTemplates = remoteState.workflowTemplates
        uploadJobs = remoteState.uploadJobs
        selectedProjectID = remoteState.selectedProjectID ?? remoteState.projects.first?.id
        privacyMode = remoteState.privacyMode
        syncHealth = remoteState.syncHealth
        syncHealth.lastSuccessfulSync = syncedAt
        syncHealth.lastRemoteWorkspaceUpdatedAt = remoteState.updatedAt
        syncHealth.queuedUploads = activeUploadJobs.count
        syncHealth.syncConflictStatus = nil
        updatedAt = remoteState.updatedAt
        guard persistCurrentState() else {
            restoreLiveState(originalState)
            lastErrorMessage = "Remote workspace could not be saved."
            throw WorkspaceRepositoryError.unwritableState
        }
        IdeaForgeLog.sync.info("Remote workspace snapshot applied with \(self.projects.count, privacy: .public) projects")
        return true
    }

    @discardableResult
    public func markWorkspaceSnapshotPublished(
        remoteUpdatedAt: Date,
        publishedLocalUpdatedAt: Date,
        syncedAt: Date = Date()
    ) -> Bool {
        let originalState = workspaceState()
        syncHealth.lastSuccessfulSync = syncedAt
        syncHealth.lastRemoteWorkspaceUpdatedAt = remoteUpdatedAt
        syncHealth.lastPublishedLocalUpdatedAt = publishedLocalUpdatedAt
        syncHealth.syncConflictStatus = nil
        guard persistCurrentState() else {
            restoreLiveState(originalState)
            lastErrorMessage = "Workspace publish receipt could not be saved."
            return false
        }
        IdeaForgeLog.sync.info("Local workspace snapshot published to backend")
        return true
    }

    private func applyMergedRemoteSnapshot(
        _ remoteState: WorkspaceState,
        preserving selection: WorkspaceSyncConflictMergeSelection,
        from localState: WorkspaceState,
        syncedAt: Date
    ) throws {
        let protectedRecordingIDs = Set(selection.recordingIDsToPreserve)
        let protectedUploadJobIDs = Set(selection.uploadJobIDsToPreserve)
        let localProjectsByID = WorkspaceSyncPayloadPolicy.dictionaryByFirstID(
            localState.projects,
            id: \.id
        )
        let remoteProjectIDs = Set(remoteState.projects.map(\.id))
        var mergedProjects = remoteState.projects

        for localProject in localState.projects {
            let protectedRecordings = localProject.recordings.filter { protectedRecordingIDs.contains($0.id) }
            if !protectedRecordings.isEmpty {
                if let remoteIndex = mergedProjects.firstIndex(where: { $0.id == localProject.id }) {
                    let remoteRecordingIDs = Set(mergedProjects[remoteIndex].recordings.map(\.id))
                    let missingRecordings = protectedRecordings.filter { !remoteRecordingIDs.contains($0.id) }
                    if !missingRecordings.isEmpty {
                        mergedProjects[remoteIndex].recordings.append(contentsOf: missingRecordings)
                        mergedProjects[remoteIndex].updatedAt = max(mergedProjects[remoteIndex].updatedAt, localProject.updatedAt)
                    }
                } else if !remoteProjectIDs.contains(localProject.id) {
                    var preservedProject = localProject
                    preservedProject.recordings = protectedRecordings
                    mergedProjects.append(preservedProject)
                }
            }
        }

        applyProjectFieldSelections(
            selection.projectFieldsToPreserve,
            to: &mergedProjects,
            from: localProjectsByID
        )
        applyProjectArtifactSelections(
            selection.projectArtifactsToPreserve,
            to: &mergedProjects,
            from: localProjectsByID
        )
        applyProjectCollectionItemSelections(
            selection.projectCollectionItemsToPreserve,
            to: &mergedProjects,
            from: localProjectsByID
        )
        applyProjectCollectionItemCustomValues(
            selection.customProjectCollectionItemValues,
            to: &mergedProjects,
            syncedAt: syncedAt
        )
        applyProjectFieldCustomValues(
            selection.customProjectFieldValues,
            to: &mergedProjects,
            syncedAt: syncedAt
        )

        let remoteUploadJobIDs = Set(remoteState.uploadJobs.map(\.id))
        let preservedUploadJobs = localState.uploadJobs.filter { job in
            protectedUploadJobIDs.contains(job.id) && !remoteUploadJobIDs.contains(job.id)
        }

        projects = mergedProjects
        workflowTemplates = remoteState.workflowTemplates
        uploadJobs = remoteState.uploadJobs + preservedUploadJobs
        selectedProjectID = remoteState.selectedProjectID
            ?? (localState.selectedProjectID.flatMap { localProjectsByID[$0] }?.id)
            ?? mergedProjects.first?.id
        privacyMode = remoteState.privacyMode
        syncHealth = remoteState.syncHealth
        syncHealth.lastSuccessfulSync = syncedAt
        syncHealth.lastRemoteWorkspaceUpdatedAt = remoteState.updatedAt
        syncHealth.queuedUploads = activeUploadJobs.count
        syncHealth.syncConflictStatus = nil
        updatedAt = max(syncedAt, remoteState.updatedAt.addingTimeInterval(0.001))
        lastErrorMessage = nil
        guard persistCurrentState() else {
            restoreLiveState(localState)
            lastErrorMessage = "Remote workspace merge could not be saved."
            throw WorkspaceRepositoryError.unwritableState
        }
        IdeaForgeLog.sync.info("Remote workspace snapshot merged with protected local upload work; preserved upload jobs: \(preservedUploadJobs.count, privacy: .public), preserved recordings: \(protectedRecordingIDs.count, privacy: .public)")
    }

    private func applyProjectFieldSelections(
        _ selections: [WorkspaceSyncProjectFieldSelection],
        to mergedProjects: inout [IdeaProject],
        from localProjectsByID: [String: IdeaProject]
    ) {
        guard !selections.isEmpty else { return }

        for selection in selections {
            guard let localProject = localProjectsByID[selection.projectID],
                  let projectIndex = mergedProjects.firstIndex(where: { $0.id == selection.projectID }) else {
                continue
            }

            switch selection.field {
            case .title:
                mergedProjects[projectIndex].title = localProject.title
            case .status:
                mergedProjects[projectIndex].status = localProject.status
            case .summary:
                mergedProjects[projectIndex].summary = localProject.summary
            case .tags:
                mergedProjects[projectIndex].tags = localProject.tags
            case .score:
                mergedProjects[projectIndex].score = localProject.score
            case .transcript:
                mergedProjects[projectIndex].transcript = localProject.transcript
            case .questions:
                mergedProjects[projectIndex].questions = localProject.questions
            case .artifacts:
                mergedProjects[projectIndex].artifacts = localProject.artifacts
            case .assumptions:
                mergedProjects[projectIndex].assumptions = localProject.assumptions
            case .validationExperiments:
                mergedProjects[projectIndex].validationExperiments = localProject.validationExperiments
            case .codexTasks:
                mergedProjects[projectIndex].codexTasks = localProject.codexTasks
            case .workflowRuns:
                mergedProjects[projectIndex].workflowRuns = localProject.workflowRuns
            }

            mergedProjects[projectIndex].updatedAt = max(
                mergedProjects[projectIndex].updatedAt,
                localProject.updatedAt
            )
        }
    }

    private func applyProjectArtifactSelections(
        _ selections: [WorkspaceSyncProjectArtifactSelection],
        to mergedProjects: inout [IdeaProject],
        from localProjectsByID: [String: IdeaProject]
    ) {
        guard !selections.isEmpty else { return }
        let selectionsByProject = Dictionary(grouping: selections, by: \.projectID)

        for (projectID, projectSelections) in selectionsByProject {
            guard let localProject = localProjectsByID[projectID],
                  let projectIndex = mergedProjects.firstIndex(where: { $0.id == projectID }) else {
                continue
            }

            let artifactIDsToPreserve = Set(projectSelections.map(\.artifactID))
            let localArtifactsToPreserve = localProject.artifacts.filter {
                artifactIDsToPreserve.contains($0.id)
            }
            guard !localArtifactsToPreserve.isEmpty else { continue }

            let preservedArtifactIDs = Set(localArtifactsToPreserve.map(\.id))
            let remainingRemoteArtifacts = mergedProjects[projectIndex].artifacts.filter {
                !preservedArtifactIDs.contains($0.id)
            }
            mergedProjects[projectIndex].artifacts = localArtifactsToPreserve + remainingRemoteArtifacts
            mergedProjects[projectIndex].updatedAt = max(
                mergedProjects[projectIndex].updatedAt,
                localProject.updatedAt
            )
        }
    }

    private func applyProjectCollectionItemSelections(
        _ selections: [WorkspaceSyncProjectCollectionItemSelection],
        to mergedProjects: inout [IdeaProject],
        from localProjectsByID: [String: IdeaProject]
    ) {
        guard !selections.isEmpty else { return }
        let selectionsByProject = Dictionary(grouping: selections, by: \.projectID)

        for (projectID, projectSelections) in selectionsByProject {
            guard let localProject = localProjectsByID[projectID],
                  let projectIndex = mergedProjects.firstIndex(where: { $0.id == projectID }) else {
                continue
            }

            let selectionsByField = Dictionary(grouping: projectSelections, by: \.field)
            for (field, fieldSelections) in selectionsByField where field.supportsItemMerge {
                let itemIDsToPreserve = Set(fieldSelections.map(\.itemID))
                guard !itemIDsToPreserve.isEmpty else { continue }

                switch field {
                case .questions:
                    mergedProjects[projectIndex].questions = mergedCollectionItems(
                        localItems: localProject.questions,
                        remoteItems: mergedProjects[projectIndex].questions,
                        preserving: itemIDsToPreserve
                    )
                case .assumptions:
                    mergedProjects[projectIndex].assumptions = mergedCollectionItems(
                        localItems: localProject.assumptions,
                        remoteItems: mergedProjects[projectIndex].assumptions,
                        preserving: itemIDsToPreserve
                    )
                case .validationExperiments:
                    mergedProjects[projectIndex].validationExperiments = mergedCollectionItems(
                        localItems: localProject.validationExperiments,
                        remoteItems: mergedProjects[projectIndex].validationExperiments,
                        preserving: itemIDsToPreserve
                    )
                case .codexTasks:
                    mergedProjects[projectIndex].codexTasks = mergedCollectionItems(
                        localItems: localProject.codexTasks,
                        remoteItems: mergedProjects[projectIndex].codexTasks,
                        preserving: itemIDsToPreserve
                    )
                case .workflowRuns:
                    let localRunsToPreserve = localProject.workflowRuns.filter {
                        itemIDsToPreserve.contains($0.id)
                    }
                    mergedProjects[projectIndex].workflowRuns = mergedCollectionItems(
                        localItems: localProject.workflowRuns,
                        remoteItems: mergedProjects[projectIndex].workflowRuns,
                        preserving: itemIDsToPreserve
                    )
                    preserveArtifactsReferencedByWorkflowRuns(
                        localRunsToPreserve,
                        in: &mergedProjects[projectIndex],
                        from: localProject
                    )
                case .title, .status, .summary, .tags, .score, .transcript, .artifacts:
                    continue
                }

                mergedProjects[projectIndex].updatedAt = max(
                    mergedProjects[projectIndex].updatedAt,
                    localProject.updatedAt
                )
            }
        }
    }

    private func mergedCollectionItems<Item: Identifiable>(
        localItems: [Item],
        remoteItems: [Item],
        preserving itemIDsToPreserve: Set<String>
    ) -> [Item] where Item.ID == String {
        let localItemsToPreserve = localItems.filter {
            itemIDsToPreserve.contains($0.id)
        }
        guard !localItemsToPreserve.isEmpty else { return remoteItems }

        let preservedItemIDs = Set(localItemsToPreserve.map(\.id))
        let remainingRemoteItems = remoteItems.filter {
            !preservedItemIDs.contains($0.id)
        }
        return localItemsToPreserve + remainingRemoteItems
    }

    private func preserveArtifactsReferencedByWorkflowRuns(
        _ runs: [WorkflowRun],
        in mergedProject: inout IdeaProject,
        from localProject: IdeaProject
    ) {
        let artifactIDsToPreserve = Set(runs.flatMap(\.artifactIDs))
        guard !artifactIDsToPreserve.isEmpty else { return }

        let localArtifactsToPreserve = localProject.artifacts.filter {
            artifactIDsToPreserve.contains($0.id)
        }
        guard !localArtifactsToPreserve.isEmpty else { return }

        let preservedArtifactIDs = Set(localArtifactsToPreserve.map(\.id))
        let remainingRemoteArtifacts = mergedProject.artifacts.filter {
            !preservedArtifactIDs.contains($0.id)
        }
        mergedProject.artifacts = localArtifactsToPreserve + remainingRemoteArtifacts
    }

    private func applyProjectCollectionItemCustomValues(
        _ values: [WorkspaceSyncProjectCollectionItemCustomValue],
        to mergedProjects: inout [IdeaProject],
        syncedAt: Date
    ) {
        guard !values.isEmpty else { return }

        for value in values {
            guard let projectIndex = mergedProjects.firstIndex(where: { $0.id == value.projectID }) else {
                continue
            }

            var didApply = false
            switch value.field {
            case .questions:
                if let itemIndex = mergedProjects[projectIndex].questions.firstIndex(where: { $0.id == value.itemID }) {
                    mergedProjects[projectIndex].questions[itemIndex] = Question(
                        id: value.itemID,
                        prompt: value.primaryText,
                        answer: value.secondaryText.isEmpty ? nil : value.secondaryText,
                        isBlocking: value.flagValue ?? false
                    )
                    didApply = true
                }
            case .assumptions:
                if let itemIndex = mergedProjects[projectIndex].assumptions.firstIndex(where: { $0.id == value.itemID }) {
                    mergedProjects[projectIndex].assumptions[itemIndex] = Assumption(
                        id: value.itemID,
                        text: value.primaryText,
                        confidence: min(max(value.numericValue ?? 0.5, 0), 1),
                        evidence: value.secondaryText
                    )
                    didApply = true
                }
            case .validationExperiments:
                if let itemIndex = mergedProjects[projectIndex].validationExperiments.firstIndex(where: { $0.id == value.itemID }) {
                    mergedProjects[projectIndex].validationExperiments[itemIndex] = ValidationExperiment(
                        id: value.itemID,
                        title: value.primaryText,
                        metric: value.secondaryText,
                        goNoGoCriteria: value.tertiaryText
                    )
                    didApply = true
                }
            case .codexTasks:
                if let itemIndex = mergedProjects[projectIndex].codexTasks.firstIndex(where: { $0.id == value.itemID }) {
                    mergedProjects[projectIndex].codexTasks[itemIndex] = CodexTask(
                        id: value.itemID,
                        title: value.primaryText,
                        acceptanceCriteria: WorkspaceSyncConflictMergeSelection.normalizedMultilineItems(value.secondaryText),
                        testPlan: WorkspaceSyncConflictMergeSelection.normalizedMultilineItems(value.tertiaryText)
                    )
                    didApply = true
                }
            case .workflowRuns:
                if let itemIndex = mergedProjects[projectIndex].workflowRuns.firstIndex(where: { $0.id == value.itemID }),
                   let status = WorkspaceSyncConflictMergeSelection.parseWorkflowRunStatus(value.secondaryText) {
                    var run = mergedProjects[projectIndex].workflowRuns[itemIndex]
                    run.templateName = value.primaryText
                    run.status = status
                    run.errorMessage = status == .failed ? value.tertiaryText : nil
                    mergedProjects[projectIndex].workflowRuns[itemIndex] = run
                    didApply = true
                }
            case .title, .status, .summary, .tags, .score, .transcript, .artifacts:
                continue
            }

            if didApply {
                mergedProjects[projectIndex].updatedAt = max(
                    mergedProjects[projectIndex].updatedAt,
                    syncedAt
                )
            }
        }
    }

    private func applyProjectFieldCustomValues(
        _ values: [WorkspaceSyncProjectFieldCustomValue],
        to mergedProjects: inout [IdeaProject],
        syncedAt: Date
    ) {
        guard !values.isEmpty else { return }

        for value in values {
            guard let projectIndex = mergedProjects.firstIndex(where: { $0.id == value.projectID }) else {
                continue
            }

            switch value.field {
            case .title:
                mergedProjects[projectIndex].title = value.value
            case .status:
                guard let status = WorkspaceSyncConflictMergeSelection.parseStatus(value.value) else {
                    continue
                }
                mergedProjects[projectIndex].status = status
            case .summary:
                mergedProjects[projectIndex].summary = value.value
            case .tags:
                let tags = WorkspaceSyncConflictMergeSelection.parseTags(value.value)
                guard !tags.isEmpty else { continue }
                mergedProjects[projectIndex].tags = tags
            case .score:
                guard let score = WorkspaceSyncConflictMergeSelection.parseScore(value.value) else {
                    continue
                }
                mergedProjects[projectIndex].score = score
            case .transcript:
                mergedProjects[projectIndex].transcript.cleanText = value.value
            case .questions, .artifacts, .assumptions, .validationExperiments, .codexTasks, .workflowRuns:
                continue
            }

            mergedProjects[projectIndex].updatedAt = max(
                mergedProjects[projectIndex].updatedAt,
                syncedAt
            )
        }
    }

    @discardableResult
    public func markUploadStarted(recordingID: String, now: Date = Date()) -> Bool {
        guard let jobIndex = uploadJobs.firstIndex(where: { $0.recordingID == recordingID }) else { return false }
        let originalState = workspaceState()
        uploadJobs[jobIndex] = UploadQueuePolicy.markUploading(uploadJobs[jobIndex], now: now)
        syncHealth.queuedUploads = activeUploadJobs.count
        IdeaForgeLog.sync.info("Upload started for recording \(recordingID, privacy: .private)")
        guard save(now: max(originalState.updatedAt, now)) else {
            restoreLiveState(originalState)
            lastErrorMessage = "Upload start could not be saved."
            return false
        }
        return true
    }

    @discardableResult
    public func recoverInterruptedUploads(now: Date = Date()) -> Int {
        let originalState = workspaceState()
        var recoveredCount = 0
        for index in uploadJobs.indices where UploadQueuePolicy.isInterruptedUpload(uploadJobs[index], now: now) {
            uploadJobs[index] = UploadQueuePolicy.markInterruptedForRetry(uploadJobs[index], now: now)
            recoveredCount += 1
        }
        guard recoveredCount > 0 else { return 0 }
        syncHealth.queuedUploads = activeUploadJobs.count
        guard save(now: max(originalState.updatedAt, now)) else {
            restoreLiveState(originalState)
            lastErrorMessage = "Interrupted upload recovery could not be saved."
            return 0
        }
        IdeaForgeLog.sync.warning("Recovered interrupted upload jobs; count: \(recoveredCount, privacy: .public)")
        return recoveredCount
    }

    @discardableResult
    public func markUploadFailed(
        recordingID: String,
        message: String,
        category: UploadFailureCategory = .uploadError,
        now: Date = Date()
    ) -> Bool {
        guard let jobIndex = uploadJobs.firstIndex(where: { $0.recordingID == recordingID }) else { return false }
        let originalState = workspaceState()
        uploadJobs[jobIndex] = UploadQueuePolicy.markFailed(
            uploadJobs[jobIndex],
            message: message,
            category: category,
            now: now
        )
        if uploadJobs[jobIndex].status == .permanentlyFailed {
            updateRecording(recordingID: recordingID, event: .failed, now: now)
            syncHealth.failingItems += 1
        }
        syncHealth.queuedUploads = activeUploadJobs.count
        IdeaForgeLog.sync.error("Upload failed for recording \(recordingID, privacy: .private); status: \(self.uploadJobs[jobIndex].status.rawValue, privacy: .public)")
        guard save(now: max(originalState.updatedAt, now)) else {
            restoreLiveState(originalState)
            lastErrorMessage = "Upload failure could not be saved."
            return false
        }
        return true
    }

    public func canRetryUpload(recordingID: String, fileManager: FileManager = .default) -> Bool {
        guard
            let job = uploadJobs.first(where: { $0.recordingID == recordingID }),
            job.status == .permanentlyFailed,
            let recording = recording(withID: recordingID)
        else {
            return false
        }
        return Self.retainedAudioValidation(
            job: job,
            recording: recording,
            fileManager: fileManager
        ).isRetryEligible
    }

    public func retainedAudioValidation(
        recordingID: String,
        fileManager: FileManager = .default
    ) -> RetainedAudioValidation {
        guard
            let job = uploadJobs.first(where: { $0.recordingID == recordingID }),
            let recording = recording(withID: recordingID)
        else {
            return .unavailable
        }
        return Self.retainedAudioValidation(
            job: job,
            recording: recording,
            fileManager: fileManager
        )
    }

    @discardableResult
    public func retryUpload(
        recordingID: String,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> Bool {
        guard !workspaceLoadFailed else {
            lastErrorMessage = "Workspace data could not be loaded. The original file was left unchanged."
            IdeaForgeLog.workspace.error("Upload retry blocked because the stored workspace is unreadable")
            return false
        }
        guard
            let jobIndex = uploadJobs.firstIndex(where: { $0.recordingID == recordingID }),
            let retriedJob = UploadQueuePolicy.manualRetry(uploadJobs[jobIndex], now: now),
            let projectIndex = projects.firstIndex(where: { project in
                project.recordings.contains { $0.id == recordingID }
            }),
            let recordingIndex = projects[projectIndex].recordings.firstIndex(where: { $0.id == recordingID }),
            Self.retainedAudioValidation(
                job: uploadJobs[jobIndex],
                recording: projects[projectIndex].recordings[recordingIndex],
                fileManager: fileManager
            ).isRetryEligible
        else {
            lastErrorMessage = "The retained recording is not available for upload retry."
            return false
        }

        var candidateJobs = uploadJobs
        var candidateProjects = projects
        var candidateHealth = syncHealth
        candidateJobs[jobIndex] = retriedJob
        candidateProjects[projectIndex].recordings[recordingIndex].localFileStatus = .available
        let isWatch = candidateProjects[projectIndex].recordings[recordingIndex].deviceName.localizedCaseInsensitiveContains("watch")
        candidateProjects[projectIndex].recordings[recordingIndex].syncStatus = isWatch ? .transferredToIPhone : .pending
        candidateHealth.failingItems = max(0, candidateHealth.failingItems - 1)
        candidateHealth.queuedUploads = candidateJobs.filter { job in
            job.status == .queued || job.status == .uploading || job.status == .waitingForRetry
        }.count
        let candidateState = WorkspaceState(
            projects: candidateProjects,
            workflowTemplates: workflowTemplates,
            uploadJobs: candidateJobs,
            privacyMode: privacyMode,
            syncHealth: candidateHealth,
            selectedProjectID: selectedProjectID,
            updatedAt: now
        )

        do {
            try repository.save(candidateState)
            uploadJobs = candidateJobs
            projects = candidateProjects
            syncHealth = candidateHealth
            updatedAt = now
            lastErrorMessage = nil
            return true
        } catch {
            lastErrorMessage = "Could not save the upload retry."
            IdeaForgeLog.workspace.error("Upload retry persistence failed")
            return false
        }
    }

    public static func retainedAudioValidation(
        job: UploadJob,
        recording: Recording,
        fileManager: FileManager = .default
    ) -> RetainedAudioValidation {
        guard
            let localAudioPath = recording.localAudioPath,
            !localAudioPath.isEmpty
        else {
            return .unavailable
        }
        guard localAudioPath == job.localAudioPath else {
            return .mismatched
        }
        guard recording.localFileStatus != .deleted, recording.localFileStatus != .missing else {
            return .invalid
        }

        guard fileManager.fileExists(atPath: localAudioPath) else {
            return .unavailable
        }
        guard
            let attributes = try? fileManager.attributesOfItem(atPath: localAudioPath),
            attributes[.type] as? FileAttributeType == .typeRegular
        else {
            return .invalid
        }
        return .available
    }

    private func recording(withID recordingID: String) -> Recording? {
        for project in projects {
            if let recording = project.recordings.first(where: { $0.id == recordingID }) {
                return recording
            }
        }
        return nil
    }

    private func enqueueUploadJobIfNeeded(for recording: Recording, now: Date = Date()) {
        guard let localAudioPath = recording.localAudioPath else { return }
        guard !uploadJobs.contains(where: { $0.recordingID == recording.id }) else { return }
        uploadJobs.append(UploadQueuePolicy.job(for: recording, localAudioPath: localAudioPath, now: now))
    }

    private static func isRetryableWatchTransferRecording(_ recording: Recording) -> Bool {
        guard recording.deviceName.localizedCaseInsensitiveContains("watch") else { return false }
        guard recording.localFileStatus == .available else { return false }
        guard recording.localAudioPath?.isEmpty == false else { return false }
        return recording.syncStatus == .pending || recording.syncStatus == .failed
    }

    private func updateRecording(recordingID: String, event: RecordingQueueEvent, now: Date = Date()) {
        for projectIndex in projects.indices {
            guard let recordingIndex = projects[projectIndex].recordings.firstIndex(where: { $0.id == recordingID }) else {
                continue
            }
            if let updated = try? RecordingQueuePolicy.applying(event, to: projects[projectIndex].recordings[recordingIndex]) {
                projects[projectIndex].recordings[recordingIndex] = updated
                projects[projectIndex].updatedAt = max(projects[projectIndex].updatedAt, now)
            }
            return
        }
    }

    private func appendedWatchSummary(currentSummary: String, durationSeconds: Int) -> String {
        let trimmedSummary = currentSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        let appendNote = "Additional Watch note queued for transcription (\(durationSeconds)s)."
        guard !trimmedSummary.isEmpty else { return appendNote }
        guard !trimmedSummary.contains(appendNote) else { return trimmedSummary }
        return "\(trimmedSummary)\n\n\(appendNote)"
    }

    private func transcriptWithQueuedWatchAppend(
        _ transcript: Transcript,
        recording: Recording,
        hint: String
    ) -> Transcript {
        let trimmedHint = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = trimmedHint.isEmpty
            ? "Additional Watch recording queued for transcription."
            : trimmedHint
        let segment = TranscriptSegment(
            id: "segment_\(recording.id)",
            startSeconds: 0,
            endSeconds: max(recording.durationSeconds, 1),
            text: text,
            isMarkedImportant: !recording.markerOffsets.isEmpty
        )
        let cleanText = transcript.cleanText.trimmingCharacters(in: .whitespacesAndNewlines)
        let updatedCleanText = cleanText.isEmpty ? text : "\(cleanText)\n\n\(text)"
        return Transcript(
            cleanText: updatedCleanText,
            segments: transcript.segments + [segment],
            unclearFragments: transcript.unclearFragments
        )
    }

    private func setProcessingDiagnostic(_ diagnostic: RecordingProcessingDiagnostic, recordingID: String, now: Date) {
        for projectIndex in projects.indices {
            guard let recordingIndex = projects[projectIndex].recordings.firstIndex(where: { $0.id == recordingID }) else {
                continue
            }
            projects[projectIndex].recordings[recordingIndex].processingDiagnostic = diagnostic
            projects[projectIndex].updatedAt = now
            return
        }
    }

    private func apply(transcript: Transcript, to projectID: String, recordingID: String, now: Date) {
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[projectIndex].transcript = transcript
        projects[projectIndex].summary = transcript.cleanText
        projects[projectIndex].updatedAt = now
        updateRecording(recordingID: recordingID, event: .ready)
        save(now: now)
    }

    @MainActor
    @discardableResult
    public func capture(_ draft: RecordingDraft, services: IdeaForgeServices = .local) async -> IdeaProject? {
        if let requestedRecordingID = draft.recordingID,
           let existingProject = projects.first(where: { project in
               project.recordings.contains(where: { $0.id == requestedRecordingID })
           }) {
            return existingProject
        }

        let projectID = draft.ideaProjectID ?? "idea_\(UUID().uuidString.lowercased())"
        guard !projects.contains(where: { $0.id == projectID }) else {
            lastErrorMessage = "Recovered recording conflicts with an existing idea."
            IdeaForgeLog.recording.error("Capture recovery failed closed on project identifier conflict")
            return nil
        }
        let recordingID = draft.recordingID ?? "rec_\(UUID().uuidString.lowercased())"
        let initialRecording = Recording(
            id: recordingID,
            ideaProjectID: projectID,
            deviceName: draft.source.label,
            durationSeconds: draft.durationSeconds,
            localFileStatus: .available,
            syncStatus: .pending,
            localAudioPath: draft.localAudioPath,
            languageHint: draft.languageHint,
            createdAt: Date(),
            markerOffsets: draft.markerOffsets
        )

        IdeaForgeLog.recording.info("Capture started from \(draft.source.rawValue, privacy: .public); duration seconds: \(draft.durationSeconds, privacy: .public)")
        do {
            let transcript = try await services.transcription.transcript(
                for: initialRecording,
                hint: draft.transcriptHint
            )
            let syncStatus = try await services.syncQueue.enqueue(recording: initialRecording)
            let recording = Recording(
                id: initialRecording.id,
                ideaProjectID: initialRecording.ideaProjectID,
                deviceName: initialRecording.deviceName,
                durationSeconds: initialRecording.durationSeconds,
                localFileStatus: initialRecording.localFileStatus,
                syncStatus: syncStatus,
                localAudioPath: initialRecording.localAudioPath,
                audioObjectKey: initialRecording.audioObjectKey,
                languageHint: initialRecording.languageHint,
                createdAt: initialRecording.createdAt,
                markerOffsets: initialRecording.markerOffsets
            )
            let project = createProject(from: draft, transcript: transcript, recording: recording)
            guard let project else {
                lastErrorMessage = "Capture could not be saved."
                IdeaForgeLog.recording.error("Capture failed because workspace persistence failed")
                return nil
            }
            IdeaForgeLog.recording.info("Capture completed from \(draft.source.rawValue, privacy: .public); queued uploads: \(self.activeUploadJobs.count, privacy: .public)")
            return project
        } catch {
            lastErrorMessage = "Capture failed."
            IdeaForgeLog.recording.error("Capture failed from \(draft.source.rawValue, privacy: .public)")
            return nil
        }
    }

    @MainActor
    public func runWorkflow(templateID: String, services: IdeaForgeServices = .local) async {
        guard let project = selectedProject,
              let template = workflowTemplates.first(where: { $0.id == templateID }) else {
            IdeaForgeLog.workflow.warning("Workflow run skipped; selected project or template missing")
            return
        }

        await runWorkflow(template: template, project: project, services: services)
    }

    @MainActor
    public func retryWorkflowRun(runID: String, services: IdeaForgeServices = .local, now: Date = Date()) async {
        guard let project = projects.first(where: { project in
            project.workflowRuns.contains { $0.id == runID }
        }),
              let priorRun = project.workflowRuns.first(where: { $0.id == runID }),
              priorRun.status == .failed,
              let template = workflowTemplates.first(where: { $0.id == priorRun.templateID }) else {
            IdeaForgeLog.workflow.warning("Workflow retry skipped; failed run or template missing")
            return
        }

        if project.workflowRuns.contains(where: { $0.retryOfRunID == priorRun.id }) {
            lastErrorMessage = "Workflow run was already retried."
            IdeaForgeLog.workflow.warning("Workflow retry skipped; run already has retry child for \(priorRun.templateID, privacy: .public)")
            return
        }

        guard inFlightWorkflowRetryRunIDs.insert(priorRun.id).inserted else {
            lastErrorMessage = "Workflow retry is already in progress."
            IdeaForgeLog.workflow.warning("Workflow retry skipped; retry already in progress for \(priorRun.templateID, privacy: .public)")
            return
        }
        defer { inFlightWorkflowRetryRunIDs.remove(priorRun.id) }

        if let nextRetryAt = priorRun.nextRetryAt, nextRetryAt > now {
            lastErrorMessage = "Workflow retry is scheduled."
            IdeaForgeLog.workflow.warning("Workflow retry skipped; retry window not due for \(priorRun.templateID, privacy: .public)")
            return
        }

        selectedProjectID = project.id
        await runWorkflow(
            template: template,
            project: project,
            services: services,
            retryOfRunID: priorRun.id,
            retryAttempt: priorRun.retryAttempt + 1,
            now: now
        )
        if lastErrorMessage == "Workflow retry is already in progress.",
           projects.contains(where: { project in
               project.workflowRuns.contains { $0.retryOfRunID == priorRun.id && $0.status == .completed }
           }) {
            lastErrorMessage = nil
        }
    }

    @MainActor
    private func runWorkflow(
        template: WorkflowTemplate,
        project: IdeaProject,
        services: IdeaForgeServices,
        retryOfRunID: String? = nil,
        retryAttempt: Int = 0,
        now: Date = Date()
    ) async {
        let templateID = template.id
        IdeaForgeLog.workflow.info("Workflow started: \(templateID, privacy: .public)")
        let runID = "run_\(templateID)_\(UUID().uuidString.lowercased())"
        let startedAt = now
        do {
            let artifacts = try await services.workflow.run(template: template, project: project)
            let versionedArtifacts = versionedWorkflowArtifacts(artifacts, for: project, runID: runID)
            let completedAt = workflowCompletionDate(startedAt: startedAt)
            let stepRuns = stepRuns(for: template, status: .completed, startedAt: startedAt, completedAt: completedAt)
            let evaluation = WorkflowRunEvaluator.evaluate(
                template: template,
                project: project,
                stepRuns: stepRuns,
                artifacts: versionedArtifacts
            )
            addArtifacts(versionedArtifacts, to: project.id)
            recordWorkflowRun(
                WorkflowRun(
                    id: runID,
                    templateID: template.id,
                    templateName: template.name,
                    status: .completed,
                    stepRuns: stepRuns,
                    artifactIDs: versionedArtifacts.map(\.id),
                    startedAt: startedAt,
                    completedAt: completedAt,
                    retryOfRunID: retryOfRunID,
                    retryAttempt: retryAttempt,
                    evaluation: evaluation
                ),
                projectID: project.id
            )
            IdeaForgeLog.workflow.info("Workflow completed: \(templateID, privacy: .public); artifacts: \(artifacts.count, privacy: .public)")
        } catch {
            let completedAt = workflowCompletionDate(startedAt: startedAt)
            let failureResolution = workflowFailureResolution(
                for: error,
                retryAttempt: retryAttempt,
                completedAt: completedAt
            )
            recordWorkflowRun(
                WorkflowRun(
                    id: runID,
                    templateID: template.id,
                    templateName: template.name,
                    status: .failed,
                    stepRuns: stepRuns(for: template, status: .failed, startedAt: startedAt, completedAt: completedAt, errorMessage: failureResolution.message),
                    artifactIDs: [],
                    startedAt: startedAt,
                    completedAt: completedAt,
                    errorMessage: failureResolution.message,
                    retryOfRunID: retryOfRunID,
                    retryAttempt: retryAttempt,
                    nextRetryAt: failureResolution.nextRetryAt
                ),
                projectID: project.id
            )
            lastErrorMessage = failureResolution.message
            IdeaForgeLog.workflow.error("Workflow failed: \(templateID, privacy: .public); reason: \(failureResolution.message, privacy: .public)")
        }
    }

    private struct WorkflowFailureResolution {
        var message: String
        var nextRetryAt: Date?
    }

    private func transcriptionFailureDiagnostic(for error: Error, failedAt: Date) -> RecordingProcessingDiagnostic {
        if case BackendAIError.entitlementUnavailable(let denial) = error {
            return RecordingProcessingDiagnostic(
                code: .backendEntitlementUnavailable,
                message: "Backend entitlement unavailable: \(denial.metric) \(denial.reason.label).",
                isRetryable: false,
                failedAt: failedAt
            )
        }

        if case BackendAIError.contractViolation(let issues) = error {
            let issueText = issues.count == 1 ? "1 issue" : "\(issues.count) issues"
            return RecordingProcessingDiagnostic(
                code: .transcriptContractViolation,
                message: "Backend transcript failed contract validation: \(issueText).",
                isRetryable: false,
                failedAt: failedAt
            )
        }

        if case BackendAIError.providerFailure(let failure) = error {
            let retryText = failure.isRetryable ? "retryable" : "not retryable"
            return RecordingProcessingDiagnostic(
                code: .backendProviderFailure,
                message: "AI provider failed: \(failure.code) (HTTP \(failure.statusCode), \(retryText)).",
                isRetryable: failure.isRetryable,
                failedAt: failedAt
            )
        }

        if let localSpeechError = error as? LocalSpeechTranscriptionError {
            return RecordingProcessingDiagnostic(
                code: .localSpeechUnavailable,
                message: localSpeechError.userFacingMessage,
                isRetryable: localSpeechError == .recognizerUnavailable
                    || localSpeechError == .recognitionTimedOut,
                failedAt: failedAt
            )
        }

        return RecordingProcessingDiagnostic(
            code: .transcriptionFailed,
            message: "Transcription failed.",
            isRetryable: false,
            failedAt: failedAt
        )
    }

    private func workflowFailureResolution(
        for error: Error,
        retryAttempt: Int,
        completedAt: Date
    ) -> WorkflowFailureResolution {
        if case BackendAIError.entitlementUnavailable(let denial) = error {
            return WorkflowFailureResolution(
                message: "Backend entitlement unavailable: \(denial.metric) \(denial.reason.label).",
                nextRetryAt: nil
            )
        }

        guard case BackendAIError.providerFailure(let failure) = error else {
            return WorkflowFailureResolution(message: "Workflow failed.", nextRetryAt: nil)
        }

        let nextRetryAt = failure.isRetryable && retryAttempt < WorkflowRetryPolicy.maximumAttempts
            ? WorkflowRetryPolicy.nextRetryDate(afterAttempt: retryAttempt + 1, from: completedAt)
            : nil
        let retryText = failure.isRetryable ? "retryable" : "not retryable"
        return WorkflowFailureResolution(
            message: "AI provider failed: \(failure.code) (HTTP \(failure.statusCode), \(retryText)).",
            nextRetryAt: nextRetryAt
        )
    }

    private func workflowCompletionDate(startedAt: Date) -> Date {
        let current = Date()
        return current < startedAt ? startedAt : current
    }

    private func versionedWorkflowArtifacts(_ artifacts: [Artifact], for project: IdeaProject, runID: String) -> [Artifact] {
        var usedIDs = Set(project.artifacts.map(\.id))
        var maxVersionByKind = Dictionary(
            grouping: project.artifacts,
            by: \.kind
        ).mapValues { artifacts in
            artifacts.map(\.version).max() ?? 0
        }

        return artifacts.map { artifact in
            let existingMaxVersion = maxVersionByKind[artifact.kind] ?? 0
            let nextVersion = max(artifact.version, existingMaxVersion + 1)
            maxVersionByKind[artifact.kind] = nextVersion

            var artifactID = artifact.id
            if usedIDs.contains(artifactID) || nextVersion != artifact.version {
                artifactID = "\(artifact.id)_v\(nextVersion)"
            }
            while usedIDs.contains(artifactID) {
                artifactID = "\(artifact.id)_v\(nextVersion)_\(UUID().uuidString.lowercased())"
            }
            usedIDs.insert(artifactID)

            return Artifact(
                id: artifactID,
                kind: artifact.kind,
                title: artifact.title,
                markdown: artifact.markdown,
                version: nextVersion,
                createdBy: artifact.createdBy,
                createdAt: artifact.createdAt,
                sourceWorkflowRunID: runID
            )
        }
    }

    private func stepRuns(
        for template: WorkflowTemplate,
        status: WorkflowRunStatus,
        startedAt: Date,
        completedAt: Date?,
        errorMessage: String? = nil
    ) -> [StepRun] {
        template.steps.map { step in
            StepRun(
                id: "step_run_\(step.id)_\(UUID().uuidString.lowercased())",
                stepID: step.id,
                stepName: step.name,
                status: status,
                outputArtifactIDs: [],
                startedAt: startedAt,
                completedAt: completedAt,
                errorMessage: errorMessage
            )
        }
    }

    private func recordWorkflowRun(_ run: WorkflowRun, projectID: String) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[index].workflowRuns.insert(run, at: 0)
        projects[index].updatedAt = Date()
        save()
    }

    @MainActor
    public func prepareCodexPacket(services: IdeaForgeServices = .local) async {
        guard let project = selectedProject else {
            IdeaForgeLog.export.warning("Codex packet preparation skipped; no project selected")
            return
        }

        IdeaForgeLog.export.info("Codex packet preparation started")
        do {
            let packet = try await services.export.codexPacket(for: project)
            let markdown = packet.files
                .map { "## \($0.path)\n\n\($0.contents)" }
                .joined(separator: "\n\n")
            let artifact = Artifact(
                id: "artifact_codex_packet_\(project.id)",
                kind: .codexTaskBundle,
                title: "Codex Build Packet",
                markdown: markdown,
                version: 1,
                createdBy: "local-export",
                createdAt: Date()
            )
            addArtifacts([artifact], to: project.id)
            IdeaForgeLog.export.info("Codex packet prepared; files: \(packet.files.count, privacy: .public)")
        } catch {
            lastErrorMessage = (error as? UserFacingIdeaForgeError)?.userFacingMessage ?? "Codex packet export failed."
            IdeaForgeLog.export.error("Codex packet preparation failed")
        }
    }

    @MainActor
    public func exportCodexPacket(services: IdeaForgeServices = .local) async {
        guard let project = selectedProject else {
            IdeaForgeLog.export.warning("Codex packet export skipped; no project selected")
            return
        }

        IdeaForgeLog.export.info("Codex packet export started")
        do {
            let result = try await services.export.exportCodexPacket(for: project)
            lastExportedPacketURL = result.directoryURL
            let markdown = """
            # Codex Packet Export

            Directory: \(result.directoryURL.path)

            ## Files
            \(result.files.map { "- \($0.path)" }.joined(separator: "\n"))
            """
            let artifact = Artifact(
                id: "artifact_codex_export_\(project.id)_\(Int(result.manifest.exportedAt.timeIntervalSince1970))",
                kind: .codexTaskBundle,
                title: "Exported Codex Packet",
                markdown: markdown,
                version: 1,
                createdBy: "local-export",
                createdAt: result.manifest.exportedAt
            )
            addArtifacts([artifact], to: project.id)
            IdeaForgeLog.export.info("Codex packet export completed; files: \(result.files.count, privacy: .public)")
        } catch {
            lastErrorMessage = (error as? UserFacingIdeaForgeError)?.userFacingMessage ?? "Codex packet export failed."
            IdeaForgeLog.export.error("Codex packet export failed")
        }
    }
}

public enum WorkflowRunEvaluator {
    public static func evaluate(
        template: WorkflowTemplate,
        project: IdeaProject,
        stepRuns: [StepRun],
        artifacts: [Artifact]
    ) -> WorkflowRunEvaluation {
        let contractValidation = WorkflowOutputContractValidator.validate(
            template: template,
            project: project,
            artifacts: artifacts
        )
        let generatedKinds = contractValidation.generatedKinds
        let expectedKinds = contractValidation.expectedKinds
        let artifactCoverage = expectedKinds.isEmpty
            ? 1
            : Double(generatedKinds.intersection(expectedKinds).count) / Double(expectedKinds.count)
        let stepCompletion = stepRuns.isEmpty
            ? 0
            : Double(stepRuns.filter { $0.status == .completed }.count) / Double(stepRuns.count)
        let unansweredBlockingQuestions = project.questions.filter { $0.isBlocking && $0.answer == nil }.count
        let assumptionConfidence = project.assumptions.isEmpty
            ? 0.5
            : project.assumptions.map(\.confidence).reduce(0, +) / Double(project.assumptions.count)
        let validationSignal = project.validationExperiments.isEmpty ? 0.2 : 1.0
        let blockingPenalty = min(0.35, Double(unansweredBlockingQuestions) * 0.2)
        let rawScore = artifactCoverage * 0.35
            + stepCompletion * 0.2
            + contractValidation.schemaCompletenessScore * 0.15
            + contractValidation.rubricScore * 0.15
            + assumptionConfidence * 0.075
            + validationSignal * 0.075
            - blockingPenalty
        let readinessScore = min(1, max(0, rawScore))
        let blockers = blockers(
            unansweredBlockingQuestions: unansweredBlockingQuestions,
            validationExperimentCount: project.validationExperiments.count,
            contractIssues: contractValidation.issues
        )
        let decision: WorkflowEvaluationDecision
        if !blockers.isEmpty || readinessScore < 0.45 {
            decision = .blocked
        } else if readinessScore < 0.75 {
            decision = .needsReview
        } else {
            decision = .ready
        }

        return WorkflowRunEvaluation(
            readinessScore: readinessScore,
            decision: decision,
            generatedArtifactCount: artifacts.count,
            blockingIssueCount: blockers.count,
            blockers: blockers,
            schemaCompletenessScore: contractValidation.schemaCompletenessScore,
            schemaIssues: contractValidation.schemaIssues,
            rubricScore: contractValidation.rubricScore,
            rubricItems: contractValidation.rubricItems
        )
    }

    private static func blockers(
        unansweredBlockingQuestions: Int,
        validationExperimentCount: Int,
        contractIssues: [String]
    ) -> [String] {
        var blockers: [String] = []
        if unansweredBlockingQuestions > 0 {
            let noun = unansweredBlockingQuestions == 1 ? "question needs" : "questions need"
            blockers.append("\(unansweredBlockingQuestions) blocking \(noun) an answer.")
        }

        if validationExperimentCount == 0 {
            blockers.append("No validation experiment is attached.")
        }

        blockers.append(contentsOf: contractIssues)

        return blockers
    }
}

public enum PrivacyMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case privateLocal
    case standardCloud
    case power

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .privateLocal: "Private"
        case .standardCloud: "Standard"
        case .power: "Power"
        }
    }

    public var description: String {
        switch self {
        case .privateLocal: "Ask before cloud AI, delete audio after transcription."
        case .standardCloud: "Cloud transcription and planning with user-controlled retention."
        case .power: "Cloud AI, research tools, Codex packets, and integrations."
        }
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension Array where Element: Hashable {
    func duplicates() -> [Element] {
        var seen: Set<Element> = []
        var duplicates: [Element] = []
        for element in self where !seen.insert(element).inserted && !duplicates.contains(element) {
            duplicates.append(element)
        }
        return duplicates
    }
}

public struct SyncHealth: Codable, Hashable, Sendable {
    public var watchReachable: Bool
    public var queuedUploads: Int
    public var lastSuccessfulSync: Date
    public var lastRemoteWorkspaceUpdatedAt: Date?
    public var lastPublishedLocalUpdatedAt: Date?
    public var lastActivity: WorkspaceSyncActivityReceipt?
    public var failingItems: Int
    public var syncConflictStatus: WorkspaceSyncConflictStatus?

    public init(
        watchReachable: Bool,
        queuedUploads: Int,
        lastSuccessfulSync: Date,
        lastRemoteWorkspaceUpdatedAt: Date? = nil,
        lastPublishedLocalUpdatedAt: Date? = nil,
        lastActivity: WorkspaceSyncActivityReceipt? = nil,
        failingItems: Int,
        syncConflictStatus: WorkspaceSyncConflictStatus? = nil
    ) {
        self.watchReachable = watchReachable
        self.queuedUploads = queuedUploads
        self.lastSuccessfulSync = lastSuccessfulSync
        self.lastRemoteWorkspaceUpdatedAt = lastRemoteWorkspaceUpdatedAt
        self.lastPublishedLocalUpdatedAt = lastPublishedLocalUpdatedAt
        self.lastActivity = lastActivity
        self.failingItems = failingItems
        self.syncConflictStatus = syncConflictStatus
    }
}
