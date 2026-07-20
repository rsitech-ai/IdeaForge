import Foundation

public enum ProjectDeletionBlocker: Hashable, Sendable {
    case projectMissing
    case activeUploadJobs(count: Int)
    case unresolvedUploadFailures(count: Int)
    case unsafeLocalRecordings(count: Int)
    case activeTranscriptions(count: Int)
    case failedTranscriptions(count: Int)
    case activeWorkflowRuns(count: Int)
    case scheduledWorkflowRetries(count: Int)

    public var summary: String {
        switch self {
        case .projectMissing:
            return "Project was not found."
        case .activeUploadJobs(let count):
            return "\(count) upload \(count == 1 ? "job is" : "jobs are") still active."
        case .unresolvedUploadFailures(let count):
            return "\(count) upload \(count == 1 ? "failure needs" : "failures need") review."
        case .unsafeLocalRecordings(let count):
            return "\(count) local \(count == 1 ? "recording is" : "recordings are") not uploaded or safely deleted."
        case .activeTranscriptions(let count):
            return "\(count) transcription \(count == 1 ? "job is" : "jobs are") still active."
        case .failedTranscriptions(let count):
            return "\(count) transcription \(count == 1 ? "failure needs" : "failures need") review."
        case .activeWorkflowRuns(let count):
            return "\(count) workflow \(count == 1 ? "run is" : "runs are") still active."
        case .scheduledWorkflowRetries(let count):
            return "\(count) workflow \(count == 1 ? "retry is" : "retries are") still scheduled."
        }
    }
}

public struct ProjectDeletionReadiness: Equatable, Sendable {
    public var projectID: String
    public var blockers: [ProjectDeletionBlocker]

    public init(projectID: String, blockers: [ProjectDeletionBlocker]) {
        self.projectID = projectID
        self.blockers = blockers
    }

    public var canDelete: Bool {
        blockers.isEmpty
    }

    public var message: String {
        guard !canDelete else {
            return "Project can be deleted."
        }
        return "Project cannot be deleted yet. " + blockers.map(\.summary).joined(separator: " ")
    }
}

public enum ProjectDeletionPolicy {
    public static func readiness(
        for project: IdeaProject?,
        projectID: String,
        uploadJobs: [UploadJob]
    ) -> ProjectDeletionReadiness {
        guard let project else {
            return ProjectDeletionReadiness(projectID: projectID, blockers: [.projectMissing])
        }
        return readiness(for: project, uploadJobs: uploadJobs)
    }

    public static func readiness(
        for project: IdeaProject,
        uploadJobs: [UploadJob]
    ) -> ProjectDeletionReadiness {
        let projectUploadJobs = uploadJobs.filter { $0.ideaProjectID == project.id }
        var blockers: [ProjectDeletionBlocker] = []

        let activeUploadCount = projectUploadJobs.filter { job in
            switch job.status {
            case .queued, .uploading, .waitingForRetry:
                return true
            case .uploaded, .permanentlyFailed:
                return false
            }
        }.count
        if activeUploadCount > 0 {
            blockers.append(.activeUploadJobs(count: activeUploadCount))
        }

        let failedUploadCount = projectUploadJobs.filter { $0.status == .permanentlyFailed }.count
        if failedUploadCount > 0 {
            blockers.append(.unresolvedUploadFailures(count: failedUploadCount))
        }

        let unsafeRecordingCount = project.recordings.filter { recording in
            switch recording.localFileStatus {
            case .uploaded, .deleted:
                return false
            case .available, .missing, .failed:
                return true
            }
        }.count
        if unsafeRecordingCount > 0 {
            blockers.append(.unsafeLocalRecordings(count: unsafeRecordingCount))
        }

        let activeTranscriptionCount = project.recordings.filter { $0.syncStatus == .transcribing }.count
        if activeTranscriptionCount > 0 {
            blockers.append(.activeTranscriptions(count: activeTranscriptionCount))
        }

        let failedTranscriptionCount = project.recordings.filter { $0.syncStatus == .failed }.count
        if failedTranscriptionCount > 0 {
            blockers.append(.failedTranscriptions(count: failedTranscriptionCount))
        }

        let activeWorkflowCount = project.workflowRuns.filter { $0.status == .running }.count
        if activeWorkflowCount > 0 {
            blockers.append(.activeWorkflowRuns(count: activeWorkflowCount))
        }

        let scheduledRetryCount = project.workflowRuns.filter { run in
            run.status == .failed && run.nextRetryAt != nil
        }.count
        if scheduledRetryCount > 0 {
            blockers.append(.scheduledWorkflowRetries(count: scheduledRetryCount))
        }

        return ProjectDeletionReadiness(projectID: project.id, blockers: blockers)
    }
}

enum ManagedRecordingFileCleanup {
    static func defaultDirectory(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appending(path: "IdeaForge/Recordings", directoryHint: .isDirectory)
    }

    static func removeFiles(
        at paths: Set<String>,
        within managedDirectory: URL,
        fileManager: FileManager
    ) -> Int {
        let resolvedRoot = managedDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"
        var failureCount = 0

        for path in paths where !path.isEmpty {
            let candidate = URL(fileURLWithPath: path).standardizedFileURL
            guard fileManager.fileExists(atPath: candidate.path) else { continue }

            let resolvedCandidate = candidate.resolvingSymlinksInPath()
            guard resolvedCandidate.path.hasPrefix(rootPath) else { continue }

            do {
                let values = try candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                try fileManager.removeItem(at: candidate)
            } catch {
                failureCount += 1
            }
        }
        return failureCount
    }
}
