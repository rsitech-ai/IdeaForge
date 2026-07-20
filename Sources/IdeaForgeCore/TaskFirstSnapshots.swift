import Foundation

public struct CanonicalUploadSummary: Equatable, Sendable {
    public var permanentlyFailedCount: Int
    public var queuedCount: Int
    public var failedRecordingIDs: Set<String>

    public init(permanentlyFailedCount: Int, queuedCount: Int, failedRecordingIDs: Set<String> = []) {
        self.permanentlyFailedCount = max(0, permanentlyFailedCount)
        self.queuedCount = max(0, queuedCount)
        self.failedRecordingIDs = failedRecordingIDs
    }

    public init(projects: [IdeaProject], uploadJobs: [UploadJob], syncHealth: SyncHealth) {
        let recordings = projects.flatMap(\.recordings)
        let failedRecordingIDs = Set(recordings.filter { $0.syncStatus == .failed }.map(\.id))
        let failedJobRecordingIDs = Set(uploadJobs.filter { $0.status == .permanentlyFailed }.map(\.recordingID))
        let associatedFailures = failedRecordingIDs.union(failedJobRecordingIDs)
        let queuedJobRecordingIDs = Set(uploadJobs.filter {
            $0.status == .queued || $0.status == .uploading || $0.status == .waitingForRetry
        }.map(\.recordingID))

        self.failedRecordingIDs = associatedFailures
        permanentlyFailedCount = max(associatedFailures.count, max(0, syncHealth.failingItems))
        queuedCount = max(queuedJobRecordingIDs.count, max(0, syncHealth.queuedUploads))
    }
}

public enum InboxStatusKind: String, Equatable, Sendable {
    case syncConflict, failedUpload, queuedUpload, offline
}

public enum InboxStatusAction: String, Equatable, Sendable {
    case resolve, review, upload
}

public struct InboxStatusSnapshot: Equatable, Sendable {
    public var kind: InboxStatusKind
    public var title: String
    public var action: InboxStatusAction?

    public init(kind: InboxStatusKind, title: String, action: InboxStatusAction?) {
        self.kind = kind
        self.title = title
        self.action = action
    }

    public init?(uploadSummary: CanonicalUploadSummary, syncConflict: WorkspaceSyncConflictStatus?, watchReachable: Bool) {
        if syncConflict != nil {
            self.init(kind: .syncConflict, title: "Sync conflict", action: .resolve)
        } else if uploadSummary.permanentlyFailedCount > 0 {
            let count = uploadSummary.permanentlyFailedCount
            self.init(kind: .failedUpload, title: "\(count) upload\(count == 1 ? "" : "s") failed", action: .review)
        } else if uploadSummary.queuedCount > 0 {
            let count = uploadSummary.queuedCount
            self.init(kind: .queuedUpload, title: "\(count) recording\(count == 1 ? "" : "s") waiting", action: .upload)
        } else if !watchReachable {
            self.init(kind: .offline, title: "Watch offline", action: nil)
        } else {
            return nil
        }
    }
}

public enum RecordingRowState: String, Equatable, Sendable {
    case onWatch = "On Watch"
    case onIPhone = "On iPhone"
    case readyToUpload = "Ready to upload"
    case uploading = "Uploading"
    case retryScheduled = "Retry scheduled"
    case failed = "Failed"
    case transcribed = "Transcribed"
    case synced = "Synced"
}

public struct RecordingRowSnapshot: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var durationSeconds: Int
    public var createdAt: Date
    public var state: RecordingRowState

    public init(recording: Recording, projectTitle: String, uploadJob: UploadJob?, hasRemoteReceipt: Bool) {
        id = recording.id
        title = projectTitle.isEmpty ? recording.deviceName : projectTitle
        durationSeconds = recording.durationSeconds
        createdAt = recording.createdAt
        if uploadJob?.status == .permanentlyFailed || recording.syncStatus == .failed {
            state = .failed
        } else if uploadJob?.status == .waitingForRetry {
            state = .retryScheduled
        } else if uploadJob?.status == .uploading {
            state = .uploading
        } else if uploadJob?.status == .queued {
            state = .readyToUpload
        } else if recording.syncStatus == .ready && hasRemoteReceipt {
            state = .synced
        } else if recording.syncStatus == .ready || recording.syncStatus == .transcribing {
            state = .transcribed
        } else if recording.syncStatus == .uploaded {
            state = .readyToUpload
        } else if recording.syncStatus == .transferredToIPhone {
            state = .onIPhone
        } else if recording.deviceName.localizedCaseInsensitiveContains("watch") {
            state = .onWatch
        } else {
            state = .onIPhone
        }
    }
}

public struct MacOverviewRow: Identifiable, Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case summary, validation, readiness
    }

    public var id: Kind { kind }
    public var kind: Kind
    public var title: String
    public var detail: String
}

public struct MacProjectOverviewSnapshot: Equatable, Sendable {
    public var purpose: String
    public var nextStep: String?
    public var rows: [MacOverviewRow]

    public init(project: IdeaProject) {
        purpose = project.summary.isEmpty ? "Shape this recording into a clear product idea." : project.summary
        if let question = project.questions.first(where: { $0.isBlocking && $0.answer == nil }) {
            nextStep = "Answer: \(question.prompt)"
        } else if project.validationExperiments.isEmpty {
            nextStep = "Add the first validation experiment."
        } else if project.status != .readyForBuild {
            nextStep = "Review readiness and unresolved decisions."
        } else {
            nextStep = nil
        }
        rows = [
            MacOverviewRow(kind: .summary, title: "Summary", detail: purpose),
            MacOverviewRow(
                kind: .validation,
                title: "Validation",
                detail: "\(project.assumptions.count) assumptions, \(project.validationExperiments.count) experiments"
            ),
            MacOverviewRow(
                kind: .readiness,
                title: "Readiness",
                detail: nextStep ?? "Ready to move forward"
            )
        ]
    }
}
