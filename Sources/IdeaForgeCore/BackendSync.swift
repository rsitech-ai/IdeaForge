import Foundation

public enum BackendSyncError: Error, Equatable {
    case invalidResponse
    case requestFailed(String)
    case preconditionFailed(String)
}

public struct BackendSyncConfiguration: Equatable, Sendable {
    public var baseURL: URL
    public var bearerToken: String
    public var workspaceID: String
    public var syncPath: String

    public init(
        baseURL: URL,
        bearerToken: String,
        workspaceID: String = "",
        syncPath: String = "/v1/workspace/snapshot"
    ) {
        self.baseURL = baseURL
        self.bearerToken = bearerToken
        self.workspaceID = workspaceID
        self.syncPath = syncPath
    }

    public func syncURL(since: Date?) -> URL {
        let normalizedPath = syncPath.hasPrefix("/") ? String(syncPath.dropFirst()) : syncPath
        let base = baseURL.appendingPathComponent(normalizedPath)
        guard let since else { return base }

        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "since", value: ISO8601DateFormatter().string(from: since))
        ]
        return components?.url ?? base
    }

    public var isConfigured: Bool {
        !bearerToken.isEmpty && !workspaceID.isEmpty
    }
}

public protocol HTTPRequestTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionHTTPRequestTransport: HTTPRequestTransport {
    public init() {}

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BackendSyncError.invalidResponse
        }
        return (data, httpResponse)
    }
}

public struct BackendWorkspaceSyncClient: Sendable {
    public var configuration: BackendSyncConfiguration
    public var transport: any HTTPRequestTransport

    public init(
        configuration: BackendSyncConfiguration,
        transport: any HTTPRequestTransport = URLSessionHTTPRequestTransport()
    ) {
        self.configuration = configuration
        self.transport = transport
    }

    public func fetchWorkspaceSnapshot(since: Date?) async throws -> WorkspaceState {
        var request = URLRequest(url: configuration.syncURL(since: since))
        request.httpMethod = "GET"
        request.setValue("Bearer \(configuration.bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue(configuration.workspaceID, forHTTPHeaderField: BackendRequestHeader.workspaceID)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await transport.data(for: request)
        if response.statusCode == 304, since != nil {
            return try await fetchWorkspaceSnapshot(since: nil)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw BackendSyncError.requestFailed("HTTP \(response.statusCode)")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(WorkspaceState.self, from: data)
        guard WorkspaceSyncPayloadPolicy.isStructurallyValid(state) else {
            throw BackendSyncError.invalidResponse
        }
        return state
    }

    public func pushWorkspaceSnapshot(
        _ state: WorkspaceState,
        baseRemoteUpdatedAt: Date?
    ) async throws -> WorkspaceSyncPushReceipt {
        var request = URLRequest(url: configuration.syncURL(since: nil))
        request.httpMethod = "PUT"
        request.setValue("Bearer \(configuration.bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue(configuration.workspaceID, forHTTPHeaderField: BackendRequestHeader.workspaceID)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let baseRemoteUpdatedAt {
            request.setValue(
                ISO8601DateFormatter().string(from: baseRemoteUpdatedAt),
                forHTTPHeaderField: "X-IdeaForge-Base-Remote-Updated-At"
            )
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(WorkspaceSyncPayloadPolicy.outboundState(from: state))

        let (data, response) = try await transport.data(for: request)
        switch response.statusCode {
        case 200..<300:
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let receipt = try decoder.decode(WorkspaceSyncPushReceipt.self, from: data)
            guard receipt.workspaceID == configuration.workspaceID else {
                throw BackendSyncError.invalidResponse
            }
            return receipt
        case 409, 412:
            throw BackendSyncError.preconditionFailed("Remote workspace changed before local snapshot publish.")
        default:
            throw BackendSyncError.requestFailed("HTTP \(response.statusCode)")
        }
    }
}

enum WorkspaceSyncPayloadPolicy {
    static func isStructurallyValid(_ state: WorkspaceState) -> Bool {
        let projectIDs = state.projects.map(\.id)
        let recordings = state.projects.flatMap(\.recordings)
        let recordingIDs = recordings.map(\.id)
        let uploadJobIDs = state.uploadJobs.map(\.id)
        let artifactIDs = state.projects.flatMap(\.artifacts).map(\.id)
        guard hasUniqueNonemptyValues(projectIDs),
              hasUniqueNonemptyValues(recordingIDs),
              hasUniqueNonemptyValues(uploadJobIDs),
              hasUniqueNonemptyValues(artifactIDs) else {
            return false
        }
        let projectIDSet = Set(projectIDs)
        guard state.selectedProjectID.map(projectIDSet.contains) ?? true else { return false }
        var recordingProjectIDs: [String: String] = [:]
        for project in state.projects {
            for recording in project.recordings {
                guard recording.ideaProjectID == project.id else { return false }
                recordingProjectIDs[recording.id] = project.id
            }
        }
        return state.uploadJobs.allSatisfy { job in
            recordingProjectIDs[job.recordingID] == job.ideaProjectID
        }
    }

    static func dictionaryByFirstID<Value>(
        _ values: [Value],
        id: (Value) -> String
    ) -> [String: Value] {
        var result: [String: Value] = [:]
        for value in values where result[id(value)] == nil {
            result[id(value)] = value
        }
        return result
    }

    static func outboundState(from state: WorkspaceState) -> WorkspaceState {
        var outbound = state
        outbound.projects = state.projects.map { project in
            var project = project
            project.recordings = project.recordings.map { recording in
                var recording = recording
                recording.localAudioPath = nil
                recording.localFileStatus = recording.audioObjectKey == nil ? .missing : .uploaded
                return recording
            }
            return project
        }
        outbound.uploadJobs = []
        outbound.syncHealth.watchReachable = false
        outbound.syncHealth.queuedUploads = 0
        outbound.syncHealth.failingItems = 0
        outbound.syncHealth.lastSuccessfulSync = .distantPast
        outbound.syncHealth.lastRemoteWorkspaceUpdatedAt = nil
        outbound.syncHealth.lastActivity = nil
        outbound.syncHealth.syncConflictStatus = nil
        outbound.syncHealth.lastPublishedLocalUpdatedAt = nil
        return outbound
    }

    static func inboundState(
        from remoteState: WorkspaceState,
        preservingDeviceLocalState localState: WorkspaceState
    ) -> WorkspaceState {
        var inbound = remoteState
        let localRecordings = dictionaryByFirstID(
            localState.projects.flatMap(\.recordings),
            id: \.id
        )
        var remoteRecordingIDs: Set<String> = []
        inbound.projects = remoteState.projects.map { project in
            var project = project
            project.recordings = project.recordings.map { recording in
                var recording = recording
                remoteRecordingIDs.insert(recording.id)
                if let localRecording = localRecordings[recording.id] {
                    recording.localAudioPath = localRecording.localAudioPath
                    recording.localFileStatus = localRecording.localFileStatus
                } else {
                    recording.localAudioPath = nil
                    recording.localFileStatus = recording.audioObjectKey == nil ? .missing : .uploaded
                }
                return recording
            }
            return project
        }
        inbound.uploadJobs = localState.uploadJobs.filter {
            remoteRecordingIDs.contains($0.recordingID)
        }
        inbound.syncHealth.watchReachable = localState.syncHealth.watchReachable
        inbound.syncHealth.queuedUploads = inbound.uploadJobs.filter {
            $0.status == .queued || $0.status == .uploading || $0.status == .waitingForRetry
        }.count
        inbound.syncHealth.failingItems = localState.syncHealth.failingItems
        inbound.syncHealth.lastActivity = localState.syncHealth.lastActivity
        inbound.syncHealth.lastPublishedLocalUpdatedAt = localState.syncHealth.lastPublishedLocalUpdatedAt
        return inbound
    }

    private static func hasUniqueNonemptyValues(_ values: [String]) -> Bool {
        values.allSatisfy { !$0.isEmpty } && Set(values).count == values.count
    }
}

public struct WorkspaceSyncPushReceipt: Codable, Equatable, Sendable {
    public var workspaceID: String
    public var acceptedUpdatedAt: Date

    public init(workspaceID: String, acceptedUpdatedAt: Date) {
        self.workspaceID = workspaceID
        self.acceptedUpdatedAt = acceptedUpdatedAt
    }
}

public struct WorkspaceSyncSummary: Equatable, Sendable {
    public var fetched: Bool
    public var appliedRemoteSnapshot: Bool
    public var pushedLocalSnapshot: Bool
    public var remoteUpdatedAt: Date?
    public var acceptedLocalUpdatedAt: Date?
    public var localUpdatedAt: Date

    public init(
        fetched: Bool,
        appliedRemoteSnapshot: Bool,
        pushedLocalSnapshot: Bool = false,
        remoteUpdatedAt: Date?,
        acceptedLocalUpdatedAt: Date? = nil,
        localUpdatedAt: Date
    ) {
        self.fetched = fetched
        self.appliedRemoteSnapshot = appliedRemoteSnapshot
        self.pushedLocalSnapshot = pushedLocalSnapshot
        self.remoteUpdatedAt = remoteUpdatedAt
        self.acceptedLocalUpdatedAt = acceptedLocalUpdatedAt
        self.localUpdatedAt = localUpdatedAt
    }
}

public enum WorkspaceSyncProjectConflictField: String, Codable, CaseIterable, Sendable {
    case title
    case status
    case summary
    case tags
    case score
    case transcript
    case questions
    case artifacts
    case assumptions
    case validationExperiments
    case codexTasks
    case workflowRuns

    public var label: String {
        switch self {
        case .title: "Title"
        case .status: "Status"
        case .summary: "Summary"
        case .tags: "Tags"
        case .score: "Score"
        case .transcript: "Transcript"
        case .questions: "Questions"
        case .artifacts: "Artifacts"
        case .assumptions: "Assumptions"
        case .validationExperiments: "Validation experiments"
        case .codexTasks: "Codex tasks"
        case .workflowRuns: "Workflow runs"
        }
    }

    public var supportsCustomMergeText: Bool {
        customMergeKind != .unsupported
    }

    public var supportsItemMerge: Bool {
        switch self {
        case .questions, .assumptions, .validationExperiments, .codexTasks, .workflowRuns:
            return true
        case .title, .status, .summary, .tags, .score, .transcript, .artifacts:
            return false
        }
    }

    public var supportsItemCustomMerge: Bool {
        itemCustomMergeKind != .unsupported
    }

    public var itemCustomMergeKind: WorkspaceSyncProjectCollectionItemCustomMergeKind {
        switch self {
        case .questions:
            return .question
        case .assumptions:
            return .assumption
        case .validationExperiments:
            return .validationExperiment
        case .codexTasks:
            return .codexTask
        case .workflowRuns:
            return .workflowRun
        case .title, .status, .summary, .tags, .score, .transcript, .artifacts:
            return .unsupported
        }
    }

    public var customMergeKind: WorkspaceSyncProjectCustomMergeKind {
        switch self {
        case .title, .summary, .transcript:
            return .multilineText
        case .status:
            return .status
        case .tags:
            return .tags
        case .score:
            return .score
        case .questions, .artifacts, .assumptions, .validationExperiments, .codexTasks, .workflowRuns:
            return .unsupported
        }
    }
}

public enum WorkspaceSyncProjectCustomMergeKind: String, Codable, Sendable {
    case multilineText
    case status
    case tags
    case score
    case unsupported
}

public enum WorkspaceSyncProjectCollectionItemCustomMergeKind: String, Codable, Sendable {
    case question
    case assumption
    case validationExperiment
    case codexTask
    case workflowRun
    case unsupported
}

public struct WorkspaceSyncProjectConflict: Equatable, Sendable {
    public var projectID: String
    public var projectTitle: String
    public var localUpdatedAt: Date
    public var remoteUpdatedAt: Date
    public var fields: [WorkspaceSyncProjectConflictField]

    public init(
        projectID: String,
        projectTitle: String,
        localUpdatedAt: Date,
        remoteUpdatedAt: Date,
        fields: [WorkspaceSyncProjectConflictField]
    ) {
        self.projectID = projectID
        self.projectTitle = projectTitle
        self.localUpdatedAt = localUpdatedAt
        self.remoteUpdatedAt = remoteUpdatedAt
        self.fields = fields
    }
}

public struct WorkspaceSyncProjectFieldSelection: Codable, Hashable, Sendable {
    public var projectID: String
    public var field: WorkspaceSyncProjectConflictField

    public init(projectID: String, field: WorkspaceSyncProjectConflictField) {
        self.projectID = projectID
        self.field = field
    }
}

public struct WorkspaceSyncProjectFieldCustomValue: Codable, Hashable, Sendable {
    public var projectID: String
    public var field: WorkspaceSyncProjectConflictField
    public var value: String

    public init(projectID: String, field: WorkspaceSyncProjectConflictField, value: String) {
        self.projectID = projectID
        self.field = field
        self.value = value
    }
}

public struct WorkspaceSyncConflictFieldDiffPreview: Codable, Hashable, Sendable {
    public var localValue: String
    public var remoteValue: String
    public var changeSummary: String

    public init(localValue: String, remoteValue: String, changeSummary: String) {
        self.localValue = localValue
        self.remoteValue = remoteValue
        self.changeSummary = changeSummary
    }
}

public struct WorkspaceSyncProjectArtifactSelection: Codable, Hashable, Sendable {
    public var projectID: String
    public var artifactID: String

    public init(projectID: String, artifactID: String) {
        self.projectID = projectID
        self.artifactID = artifactID
    }
}

public struct WorkspaceSyncProjectCollectionItemSelection: Codable, Hashable, Sendable {
    public var projectID: String
    public var field: WorkspaceSyncProjectConflictField
    public var itemID: String

    public init(projectID: String, field: WorkspaceSyncProjectConflictField, itemID: String) {
        self.projectID = projectID
        self.field = field
        self.itemID = itemID
    }
}

public struct WorkspaceSyncProjectCollectionItemCustomValue: Codable, Hashable, Sendable {
    public var projectID: String
    public var field: WorkspaceSyncProjectConflictField
    public var itemID: String
    public var primaryText: String
    public var secondaryText: String
    public var tertiaryText: String
    public var flagValue: Bool?
    public var numericValue: Double?

    public init(
        projectID: String,
        field: WorkspaceSyncProjectConflictField,
        itemID: String,
        primaryText: String,
        secondaryText: String,
        tertiaryText: String = "",
        flagValue: Bool? = nil,
        numericValue: Double? = nil
    ) {
        self.projectID = projectID
        self.field = field
        self.itemID = itemID
        self.primaryText = primaryText
        self.secondaryText = secondaryText
        self.tertiaryText = tertiaryText
        self.flagValue = flagValue
        self.numericValue = numericValue
    }

    private enum CodingKeys: String, CodingKey {
        case projectID
        case field
        case itemID
        case primaryText
        case secondaryText
        case tertiaryText
        case flagValue
        case numericValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            projectID: try container.decode(String.self, forKey: .projectID),
            field: try container.decode(WorkspaceSyncProjectConflictField.self, forKey: .field),
            itemID: try container.decode(String.self, forKey: .itemID),
            primaryText: try container.decode(String.self, forKey: .primaryText),
            secondaryText: try container.decode(String.self, forKey: .secondaryText),
            tertiaryText: try container.decodeIfPresent(String.self, forKey: .tertiaryText) ?? "",
            flagValue: try container.decodeIfPresent(Bool.self, forKey: .flagValue),
            numericValue: try container.decodeIfPresent(Double.self, forKey: .numericValue)
        )
    }
}

public struct WorkspaceSyncConflictReport: Equatable, Sendable {
    public var localOnlyUploadJobIDs: [String]
    public var localOnlyRecordingIDs: [String]
    public var projectContentConflicts: [WorkspaceSyncProjectConflict]

    public init(
        localOnlyUploadJobIDs: [String],
        localOnlyRecordingIDs: [String],
        projectContentConflicts: [WorkspaceSyncProjectConflict] = []
    ) {
        self.localOnlyUploadJobIDs = localOnlyUploadJobIDs
        self.localOnlyRecordingIDs = localOnlyRecordingIDs
        self.projectContentConflicts = projectContentConflicts
    }

    public var hasConflicts: Bool {
        !localOnlyUploadJobIDs.isEmpty || !localOnlyRecordingIDs.isEmpty || !projectContentConflicts.isEmpty
    }

    public var message: String {
        let projectConflictCount = projectContentConflicts.count
        var parts = [String]()
        if !localOnlyUploadJobIDs.isEmpty {
            parts.append(Self.countText(
                localOnlyUploadJobIDs.count,
                singular: "local upload job",
                plural: "local upload jobs"
            ))
        }
        if !localOnlyRecordingIDs.isEmpty {
            parts.append(Self.countText(
                localOnlyRecordingIDs.count,
                singular: "local recording",
                plural: "local recordings"
            ))
        }
        if projectConflictCount > 0 {
            parts.append(Self.countText(
                projectConflictCount,
                singular: "project content conflict",
                plural: "project content conflicts"
            ))
        }
        return "Remote workspace snapshot would overwrite \(Self.joinedConflictParts(parts))."
    }

    public static func report(localState: WorkspaceState, remoteState: WorkspaceState) -> WorkspaceSyncConflictReport? {
        let remoteUploadJobIDs = Set(remoteState.uploadJobs.map(\.id))
        let remoteRecordingIDs = Set(remoteState.projects.flatMap(\.recordings).map(\.id))
        let localOnlyUploadJobIDs = localState.uploadJobs
            .filter { job in
                job.status != .uploaded && !remoteUploadJobIDs.contains(job.id)
            }
            .map(\.id)
            .sorted()
        let localOnlyRecordingIDs = localState.projects
            .flatMap(\.recordings)
            .filter { recording in
                isProtectedLocalRecording(recording) && !remoteRecordingIDs.contains(recording.id)
            }
            .map(\.id)
            .sorted()
        let projectContentConflicts = projectContentConflicts(localState: localState, remoteState: remoteState)
        let report = WorkspaceSyncConflictReport(
            localOnlyUploadJobIDs: localOnlyUploadJobIDs,
            localOnlyRecordingIDs: localOnlyRecordingIDs,
            projectContentConflicts: projectContentConflicts
        )
        return report.hasConflicts ? report : nil
    }

    private static func projectContentConflicts(
        localState: WorkspaceState,
        remoteState: WorkspaceState
    ) -> [WorkspaceSyncProjectConflict] {
        let localHasUnpublishedChanges: Bool
        if let lastPublishedLocalUpdatedAt = localState.syncHealth.lastPublishedLocalUpdatedAt {
            localHasUnpublishedChanges = localState.updatedAt > lastPublishedLocalUpdatedAt
        } else {
            localHasUnpublishedChanges = !localState.projects.isEmpty
        }
        let remoteHasUnappliedChanges = localState.syncHealth.lastRemoteWorkspaceUpdatedAt.map {
            remoteState.updatedAt > $0
        } ?? true
        guard localHasUnpublishedChanges, remoteHasUnappliedChanges else { return [] }

        let remoteProjectsByID = WorkspaceSyncPayloadPolicy.dictionaryByFirstID(
            remoteState.projects,
            id: \.id
        )

        return localState.projects
            .compactMap { localProject -> WorkspaceSyncProjectConflict? in
                guard let remoteProject = remoteProjectsByID[localProject.id] else {
                    return nil
                }

                let fields = differingProjectFields(local: localProject, remote: remoteProject)
                guard !fields.isEmpty else { return nil }

                return WorkspaceSyncProjectConflict(
                    projectID: localProject.id,
                    projectTitle: localProject.title.isEmpty ? remoteProject.title : localProject.title,
                    localUpdatedAt: localProject.updatedAt,
                    remoteUpdatedAt: remoteProject.updatedAt,
                    fields: fields
                )
            }
            .sorted { $0.projectID < $1.projectID }
    }

    private static func differingProjectFields(
        local: IdeaProject,
        remote: IdeaProject
    ) -> [WorkspaceSyncProjectConflictField] {
        WorkspaceSyncProjectConflictField.allCases.filter { field in
            switch field {
            case .title:
                return local.title != remote.title
            case .status:
                return local.status != remote.status
            case .summary:
                return local.summary != remote.summary
            case .tags:
                return local.tags != remote.tags
            case .score:
                return local.score != remote.score
            case .transcript:
                return local.transcript != remote.transcript
            case .questions:
                return local.questions != remote.questions
            case .artifacts:
                return local.artifacts != remote.artifacts
            case .assumptions:
                return local.assumptions != remote.assumptions
            case .validationExperiments:
                return local.validationExperiments != remote.validationExperiments
            case .codexTasks:
                return local.codexTasks != remote.codexTasks
            case .workflowRuns:
                return local.workflowRuns != remote.workflowRuns
            }
        }
    }

    private static func isProtectedLocalRecording(_ recording: Recording) -> Bool {
        if recording.syncStatus != .ready {
            return true
        }
        return recording.localFileStatus == .available && recording.localAudioPath?.isEmpty == false
    }

    private static func countText(_ count: Int, singular: String, plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }

    private static func joinedConflictParts(_ parts: [String]) -> String {
        switch parts.count {
        case 0:
            return "local work"
        case 1:
            return parts[0]
        case 2:
            return "\(parts[0]) and \(parts[1])"
        default:
            return "\(parts.dropLast().joined(separator: ", ")), and \(parts.last!)"
        }
    }
}

public struct WorkspaceSyncConflictReviewItem: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case localUploadJob
        case localRecording
        case projectContent
        case projectArtifact
        case projectCollectionItem

        public var label: String {
            switch self {
            case .localUploadJob: "Upload job"
            case .localRecording: "Recording"
            case .projectContent: "Project field"
            case .projectArtifact: "Artifact"
            case .projectCollectionItem: "Project item"
            }
        }
    }

    public var id: String
    public var kind: Kind
    public var projectTitle: String
    public var sourceLabel: String
    public var statusLabel: String
    public var detail: String
    public var protectedID: String
    public var relatedRecordingID: String?
    public var projectID: String?
    public var projectField: WorkspaceSyncProjectConflictField?
    public var fieldDiffPreview: WorkspaceSyncConflictFieldDiffPreview?

    public init(
        id: String,
        kind: Kind,
        projectTitle: String,
        sourceLabel: String,
        statusLabel: String,
        detail: String,
        protectedID: String? = nil,
        relatedRecordingID: String? = nil,
        projectID: String? = nil,
        projectField: WorkspaceSyncProjectConflictField? = nil,
        fieldDiffPreview: WorkspaceSyncConflictFieldDiffPreview? = nil
    ) {
        self.id = id
        self.kind = kind
        self.projectTitle = projectTitle
        self.sourceLabel = sourceLabel
        self.statusLabel = statusLabel
        self.detail = detail
        self.protectedID = protectedID ?? Self.defaultProtectedID(from: id, kind: kind)
        self.relatedRecordingID = relatedRecordingID
        self.projectID = projectID
        self.projectField = projectField
        self.fieldDiffPreview = fieldDiffPreview
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case projectTitle
        case sourceLabel
        case statusLabel
        case detail
        case protectedID
        case relatedRecordingID
        case projectID
        case projectField
        case fieldDiffPreview
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(Kind.self, forKey: .kind)
        projectTitle = try container.decode(String.self, forKey: .projectTitle)
        sourceLabel = try container.decode(String.self, forKey: .sourceLabel)
        statusLabel = try container.decode(String.self, forKey: .statusLabel)
        detail = try container.decode(String.self, forKey: .detail)
        protectedID = try container.decodeIfPresent(String.self, forKey: .protectedID)
            ?? Self.defaultProtectedID(from: id, kind: kind)
        relatedRecordingID = try container.decodeIfPresent(String.self, forKey: .relatedRecordingID)
        projectID = try container.decodeIfPresent(String.self, forKey: .projectID)
        projectField = try container.decodeIfPresent(WorkspaceSyncProjectConflictField.self, forKey: .projectField)
        fieldDiffPreview = try container.decodeIfPresent(
            WorkspaceSyncConflictFieldDiffPreview.self,
            forKey: .fieldDiffPreview
        )
    }

    private static func defaultProtectedID(from id: String, kind: Kind) -> String {
        switch kind {
        case .localUploadJob:
            return id.removingPrefix("upload:")
        case .localRecording:
            return id.removingPrefix("recording:")
        case .projectContent:
            return id.removingPrefix("project:").components(separatedBy: ":").first ?? id
        case .projectArtifact:
            return id.components(separatedBy: ":").last ?? id
        case .projectCollectionItem:
            return id.components(separatedBy: ":").last ?? id
        }
    }
}

public struct WorkspaceSyncConflictMergeSelection: Codable, Hashable, Sendable {
    public var uploadJobIDsToPreserve: [String]
    public var recordingIDsToPreserve: [String]
    public var projectFieldsToPreserve: [WorkspaceSyncProjectFieldSelection]
    public var customProjectFieldValues: [WorkspaceSyncProjectFieldCustomValue]
    public var projectArtifactsToPreserve: [WorkspaceSyncProjectArtifactSelection]
    public var projectCollectionItemsToPreserve: [WorkspaceSyncProjectCollectionItemSelection]
    public var customProjectCollectionItemValues: [WorkspaceSyncProjectCollectionItemCustomValue]

    public init(
        uploadJobIDsToPreserve: [String] = [],
        recordingIDsToPreserve: [String] = [],
        projectFieldsToPreserve: [WorkspaceSyncProjectFieldSelection] = [],
        customProjectFieldValues: [WorkspaceSyncProjectFieldCustomValue] = [],
        projectArtifactsToPreserve: [WorkspaceSyncProjectArtifactSelection] = [],
        projectCollectionItemsToPreserve: [WorkspaceSyncProjectCollectionItemSelection] = [],
        customProjectCollectionItemValues: [WorkspaceSyncProjectCollectionItemCustomValue] = []
    ) {
        self.uploadJobIDsToPreserve = Self.normalized(uploadJobIDsToPreserve)
        self.recordingIDsToPreserve = Self.normalized(recordingIDsToPreserve)
        self.projectFieldsToPreserve = Self.normalized(projectFieldsToPreserve)
        self.customProjectFieldValues = Self.normalized(customProjectFieldValues)
        self.projectArtifactsToPreserve = Self.normalized(projectArtifactsToPreserve)
        self.projectCollectionItemsToPreserve = Self.normalized(projectCollectionItemsToPreserve)
        self.customProjectCollectionItemValues = Self.normalized(customProjectCollectionItemValues)
    }

    public init(
        selectedReviewItemIDs: Set<String>,
        reviewItems: [WorkspaceSyncConflictReviewItem],
        customProjectFieldValues: [WorkspaceSyncProjectFieldCustomValue] = [],
        customProjectCollectionItemValues: [WorkspaceSyncProjectCollectionItemCustomValue] = []
    ) {
        var uploadJobIDs = [String]()
        var recordingIDs = [String]()
        var projectFields = [WorkspaceSyncProjectFieldSelection]()
        var projectArtifacts = [WorkspaceSyncProjectArtifactSelection]()
        var projectCollectionItems = [WorkspaceSyncProjectCollectionItemSelection]()

        for item in reviewItems where selectedReviewItemIDs.contains(item.id) {
            switch item.kind {
            case .localUploadJob:
                uploadJobIDs.append(item.protectedID)
                if let relatedRecordingID = item.relatedRecordingID, !relatedRecordingID.isEmpty {
                    recordingIDs.append(relatedRecordingID)
                }
            case .localRecording:
                recordingIDs.append(item.protectedID)
            case .projectContent:
                guard let field = item.projectField else { continue }
                projectFields.append(
                    WorkspaceSyncProjectFieldSelection(projectID: item.protectedID, field: field)
                )
            case .projectArtifact:
                guard let projectID = item.projectID, !projectID.isEmpty, !item.protectedID.isEmpty else {
                    continue
                }
                projectArtifacts.append(
                    WorkspaceSyncProjectArtifactSelection(projectID: projectID, artifactID: item.protectedID)
                )
            case .projectCollectionItem:
                guard let projectID = item.projectID,
                      let field = item.projectField,
                      field.supportsItemMerge,
                      !projectID.isEmpty,
                      !item.protectedID.isEmpty else {
                    continue
                }
                projectCollectionItems.append(
                    WorkspaceSyncProjectCollectionItemSelection(
                        projectID: projectID,
                        field: field,
                        itemID: item.protectedID
                    )
                )
            }
        }

        self.init(
            uploadJobIDsToPreserve: uploadJobIDs,
            recordingIDsToPreserve: recordingIDs,
            projectFieldsToPreserve: projectFields,
            customProjectFieldValues: customProjectFieldValues,
            projectArtifactsToPreserve: projectArtifacts,
            projectCollectionItemsToPreserve: projectCollectionItems,
            customProjectCollectionItemValues: customProjectCollectionItemValues
        )
    }

    private enum CodingKeys: String, CodingKey {
        case uploadJobIDsToPreserve
        case recordingIDsToPreserve
        case projectFieldsToPreserve
        case customProjectFieldValues
        case projectArtifactsToPreserve
        case projectCollectionItemsToPreserve
        case customProjectCollectionItemValues
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            uploadJobIDsToPreserve: try container.decodeIfPresent([String].self, forKey: .uploadJobIDsToPreserve) ?? [],
            recordingIDsToPreserve: try container.decodeIfPresent([String].self, forKey: .recordingIDsToPreserve) ?? [],
            projectFieldsToPreserve: try container.decodeIfPresent(
                [WorkspaceSyncProjectFieldSelection].self,
                forKey: .projectFieldsToPreserve
            ) ?? [],
            customProjectFieldValues: try container.decodeIfPresent(
                [WorkspaceSyncProjectFieldCustomValue].self,
                forKey: .customProjectFieldValues
            ) ?? [],
            projectArtifactsToPreserve: try container.decodeIfPresent(
                [WorkspaceSyncProjectArtifactSelection].self,
                forKey: .projectArtifactsToPreserve
            ) ?? [],
            projectCollectionItemsToPreserve: try container.decodeIfPresent(
                [WorkspaceSyncProjectCollectionItemSelection].self,
                forKey: .projectCollectionItemsToPreserve
            ) ?? [],
            customProjectCollectionItemValues: try container.decodeIfPresent(
                [WorkspaceSyncProjectCollectionItemCustomValue].self,
                forKey: .customProjectCollectionItemValues
            ) ?? []
        )
    }

    public var hasProjectMergeWork: Bool {
        !projectFieldsToPreserve.isEmpty
            || !customProjectFieldValues.isEmpty
            || !projectArtifactsToPreserve.isEmpty
            || !projectCollectionItemsToPreserve.isEmpty
            || !customProjectCollectionItemValues.isEmpty
    }

    public static func preserveAll(report: WorkspaceSyncConflictReport) -> WorkspaceSyncConflictMergeSelection {
        WorkspaceSyncConflictMergeSelection(
            uploadJobIDsToPreserve: report.localOnlyUploadJobIDs,
            recordingIDsToPreserve: report.localOnlyRecordingIDs,
            projectFieldsToPreserve: report.projectContentConflicts.flatMap { conflict in
                conflict.fields.map {
                    WorkspaceSyncProjectFieldSelection(projectID: conflict.projectID, field: $0)
                }
            }
        )
    }

    private static func normalized(_ values: [String]) -> [String] {
        Array(Set(values.filter { !$0.isEmpty })).sorted()
    }

    private static func normalized(
        _ values: [WorkspaceSyncProjectFieldSelection]
    ) -> [WorkspaceSyncProjectFieldSelection] {
        Array(Set(values.filter { !$0.projectID.isEmpty }))
            .sorted {
                if $0.projectID != $1.projectID {
                    return $0.projectID < $1.projectID
                }
                return $0.field.rawValue < $1.field.rawValue
            }
    }

    private static func normalized(
        _ values: [WorkspaceSyncProjectFieldCustomValue]
    ) -> [WorkspaceSyncProjectFieldCustomValue] {
        var valuesByKey = [WorkspaceSyncProjectFieldSelection: WorkspaceSyncProjectFieldCustomValue]()
        for value in values {
            let projectID = value.projectID.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = value.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !projectID.isEmpty,
                  let normalizedValue = Self.normalizedCustomValue(field: value.field, text: text) else {
                continue
            }
            let key = WorkspaceSyncProjectFieldSelection(projectID: projectID, field: value.field)
            valuesByKey[key] = WorkspaceSyncProjectFieldCustomValue(
                projectID: projectID,
                field: value.field,
                value: normalizedValue
            )
        }
        return valuesByKey.values.sorted {
            if $0.projectID != $1.projectID {
                return $0.projectID < $1.projectID
            }
            return $0.field.rawValue < $1.field.rawValue
        }
    }

    private static func normalized(
        _ values: [WorkspaceSyncProjectArtifactSelection]
    ) -> [WorkspaceSyncProjectArtifactSelection] {
        Array(Set(values.filter { !$0.projectID.isEmpty && !$0.artifactID.isEmpty }))
            .sorted {
                if $0.projectID != $1.projectID {
                    return $0.projectID < $1.projectID
                }
                return $0.artifactID < $1.artifactID
            }
    }

    private static func normalized(
        _ values: [WorkspaceSyncProjectCollectionItemSelection]
    ) -> [WorkspaceSyncProjectCollectionItemSelection] {
        Array(Set(values.filter { !$0.projectID.isEmpty && $0.field.supportsItemMerge && !$0.itemID.isEmpty }))
            .sorted {
                if $0.projectID != $1.projectID {
                    return $0.projectID < $1.projectID
                }
                if $0.field.rawValue != $1.field.rawValue {
                    return $0.field.rawValue < $1.field.rawValue
                }
                return $0.itemID < $1.itemID
            }
    }

    private static func normalized(
        _ values: [WorkspaceSyncProjectCollectionItemCustomValue]
    ) -> [WorkspaceSyncProjectCollectionItemCustomValue] {
        var valuesByKey = [WorkspaceSyncProjectCollectionItemSelection: WorkspaceSyncProjectCollectionItemCustomValue]()
        for value in values {
            let projectID = value.projectID.trimmingCharacters(in: .whitespacesAndNewlines)
            let itemID = value.itemID.trimmingCharacters(in: .whitespacesAndNewlines)
            let primaryText = value.primaryText.trimmingCharacters(in: .whitespacesAndNewlines)
            let secondaryText = value.secondaryText.trimmingCharacters(in: .whitespacesAndNewlines)
            let tertiaryText = value.tertiaryText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !projectID.isEmpty,
                  !itemID.isEmpty,
                  let normalizedValue = normalizedCollectionItemCustomValue(
                    projectID: projectID,
                    field: value.field,
                    itemID: itemID,
                    primaryText: primaryText,
                    secondaryText: secondaryText,
                    tertiaryText: tertiaryText,
                    flagValue: value.flagValue,
                    numericValue: value.numericValue
                  ) else {
                continue
            }
            let key = WorkspaceSyncProjectCollectionItemSelection(
                projectID: projectID,
                field: value.field,
                itemID: itemID
            )
            valuesByKey[key] = normalizedValue
        }

        return valuesByKey.values.sorted {
            if $0.projectID != $1.projectID {
                return $0.projectID < $1.projectID
            }
            if $0.field.rawValue != $1.field.rawValue {
                return $0.field.rawValue < $1.field.rawValue
            }
            return $0.itemID < $1.itemID
        }
    }

    static func normalizedCollectionItemCustomValue(
        projectID: String,
        field: WorkspaceSyncProjectConflictField,
        itemID: String,
        primaryText: String,
        secondaryText: String,
        tertiaryText: String,
        flagValue: Bool?,
        numericValue: Double?
    ) -> WorkspaceSyncProjectCollectionItemCustomValue? {
        guard field.supportsItemCustomMerge, !primaryText.isEmpty else { return nil }

        switch field.itemCustomMergeKind {
        case .question:
            return WorkspaceSyncProjectCollectionItemCustomValue(
                projectID: projectID,
                field: field,
                itemID: itemID,
                primaryText: primaryText,
                secondaryText: secondaryText,
                tertiaryText: "",
                flagValue: flagValue ?? false
            )
        case .assumption:
            guard !secondaryText.isEmpty else { return nil }
            let confidence = min(max(numericValue ?? 0.5, 0), 1)
            return WorkspaceSyncProjectCollectionItemCustomValue(
                projectID: projectID,
                field: field,
                itemID: itemID,
                primaryText: primaryText,
                secondaryText: secondaryText,
                tertiaryText: "",
                numericValue: confidence
            )
        case .validationExperiment:
            guard !secondaryText.isEmpty, !tertiaryText.isEmpty else { return nil }
            return WorkspaceSyncProjectCollectionItemCustomValue(
                projectID: projectID,
                field: field,
                itemID: itemID,
                primaryText: primaryText,
                secondaryText: secondaryText,
                tertiaryText: tertiaryText
            )
        case .codexTask:
            let acceptanceCriteria = normalizedMultilineItems(secondaryText)
            let testPlan = normalizedMultilineItems(tertiaryText)
            guard !acceptanceCriteria.isEmpty, !testPlan.isEmpty else { return nil }
            return WorkspaceSyncProjectCollectionItemCustomValue(
                projectID: projectID,
                field: field,
                itemID: itemID,
                primaryText: primaryText,
                secondaryText: acceptanceCriteria.joined(separator: "\n"),
                tertiaryText: testPlan.joined(separator: "\n")
            )
        case .workflowRun:
            guard let status = parseWorkflowRunStatus(secondaryText) else { return nil }
            let failureNote = tertiaryText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard status != .failed || !failureNote.isEmpty else { return nil }
            return WorkspaceSyncProjectCollectionItemCustomValue(
                projectID: projectID,
                field: field,
                itemID: itemID,
                primaryText: primaryText,
                secondaryText: status.rawValue,
                tertiaryText: status == .failed ? failureNote : ""
            )
        case .unsupported:
            return nil
        }
    }

    static func parseWorkflowRunStatus(_ text: String) -> WorkflowRunStatus? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        return WorkflowRunStatus.allCases.first {
            $0.rawValue.lowercased() == normalized
        }
    }

    static func normalizedMultilineItems(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func normalizedCustomValue(field: WorkspaceSyncProjectConflictField, text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        switch field.customMergeKind {
        case .multilineText:
            return trimmed
        case .status:
            return parseStatus(trimmed)?.rawValue
        case .tags:
            let tags = parseTags(trimmed)
            guard !tags.isEmpty else { return nil }
            return tags.map(\.rawValue).joined(separator: ",")
        case .score:
            guard let score = parseScore(trimmed) else { return nil }
            return customScoreValue(score)
        case .unsupported:
            return nil
        }
    }

    static func parseStatus(_ text: String) -> IdeaStatus? {
        let normalizedText = normalizedToken(text)
        return IdeaStatus.allCases.first { status in
            normalizedToken(status.rawValue) == normalizedText || normalizedToken(status.label) == normalizedText
        }
    }

    static func parseTags(_ text: String) -> [IdeaTag] {
        var tags = [IdeaTag]()
        var seen = Set<IdeaTag>()
        for token in text.split(separator: ",") {
            let normalizedText = normalizedToken(String(token))
            guard let tag = IdeaTag.allCases.first(where: { candidate in
                normalizedToken(candidate.rawValue) == normalizedText || normalizedToken(candidate.label) == normalizedText
            }), !seen.contains(tag) else {
                continue
            }
            tags.append(tag)
            seen.insert(tag)
        }
        return tags
    }

    static func parseScore(_ text: String) -> IdeaScore? {
        let parts = text
            .split { character in
                character == "," || character == ";" || character == "\n"
            }
            .map(String.init)
        var values = [String: Double]()

        for part in parts {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { return nil }
            let key = normalizedToken(pair[0])
            guard ["confidence", "completeness", "risk"].contains(key),
                  let value = Double(pair[1].trimmingCharacters(in: .whitespacesAndNewlines)),
                  value.isFinite,
                  (0...1).contains(value) else {
                return nil
            }
            values[key] = value
        }

        guard let confidence = values["confidence"],
              let completeness = values["completeness"],
              let risk = values["risk"],
              values.count == 3 else {
            return nil
        }
        return IdeaScore(confidence: confidence, completeness: completeness, risk: risk)
    }

    static func customScoreValue(_ score: IdeaScore) -> String {
        "confidence=\(score.confidence),completeness=\(score.completeness),risk=\(score.risk)"
    }

    private static func normalizedToken(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}

public struct WorkspaceSyncConflictStatus: Codable, Hashable, Sendable {
    public var localOnlyUploadJobCount: Int
    public var localOnlyRecordingCount: Int
    public var localProjectContentConflictCount: Int
    public var detectedAt: Date
    public var reviewItems: [WorkspaceSyncConflictReviewItem]

    public init(
        localOnlyUploadJobCount: Int,
        localOnlyRecordingCount: Int,
        localProjectContentConflictCount: Int = 0,
        detectedAt: Date,
        reviewItems: [WorkspaceSyncConflictReviewItem] = []
    ) {
        self.localOnlyUploadJobCount = localOnlyUploadJobCount
        self.localOnlyRecordingCount = localOnlyRecordingCount
        self.localProjectContentConflictCount = localProjectContentConflictCount
        self.detectedAt = detectedAt
        self.reviewItems = reviewItems
    }

    public init(report: WorkspaceSyncConflictReport, detectedAt: Date) {
        self.init(
            localOnlyUploadJobCount: report.localOnlyUploadJobIDs.count,
            localOnlyRecordingCount: report.localOnlyRecordingIDs.count,
            localProjectContentConflictCount: report.projectContentConflicts.count,
            detectedAt: detectedAt
        )
    }

    public init(
        report: WorkspaceSyncConflictReport,
        localState: WorkspaceState,
        remoteState: WorkspaceState? = nil,
        detectedAt: Date
    ) {
        self.init(
            localOnlyUploadJobCount: report.localOnlyUploadJobIDs.count,
            localOnlyRecordingCount: report.localOnlyRecordingIDs.count,
            localProjectContentConflictCount: report.projectContentConflicts.count,
            detectedAt: detectedAt,
            reviewItems: Self.reviewItems(report: report, localState: localState, remoteState: remoteState)
        )
    }

    public var message: String {
        var parts = [String]()
        if localOnlyUploadJobCount > 0 {
            parts.append(countText(localOnlyUploadJobCount, singular: "local upload job", plural: "local upload jobs"))
        }
        if localOnlyRecordingCount > 0 {
            parts.append(countText(localOnlyRecordingCount, singular: "local recording", plural: "local recordings"))
        }
        if localProjectContentConflictCount > 0 {
            parts.append(countText(
                localProjectContentConflictCount,
                singular: "project content conflict",
                plural: "project content conflicts"
            ))
        }
        return "Remote workspace snapshot would overwrite \(joinedConflictParts(parts))."
    }

    public var recoveryAction: String {
        let uploadAction = "Upload \(countText(localOnlyUploadJobCount, singular: "local job", plural: "local jobs")) and \(countText(localOnlyRecordingCount, singular: "local recording", plural: "local recordings"))"
        guard localProjectContentConflictCount > 0 else {
            return "\(uploadAction), then sync again."
        }
        let projectAction = "review project fields"
        if localOnlyUploadJobCount == 0 && localOnlyRecordingCount == 0 {
            return "Review project fields, then merge or sync again."
        }
        return "\(uploadAction) and \(projectAction), then merge or sync again."
    }

    public var defaultMergeSelection: WorkspaceSyncConflictMergeSelection {
        WorkspaceSyncConflictMergeSelection(
            selectedReviewItemIDs: Set(reviewItems.map(\.id)),
            reviewItems: reviewItems
        )
    }

    private func countText(_ count: Int, singular: String, plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }

    private func joinedConflictParts(_ parts: [String]) -> String {
        switch parts.count {
        case 0:
            return "local work"
        case 1:
            return parts[0]
        case 2:
            return "\(parts[0]) and \(parts[1])"
        default:
            return "\(parts.dropLast().joined(separator: ", ")), and \(parts.last!)"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case localOnlyUploadJobCount
        case localOnlyRecordingCount
        case localProjectContentConflictCount
        case detectedAt
        case reviewItems
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        localOnlyUploadJobCount = try container.decode(Int.self, forKey: .localOnlyUploadJobCount)
        localOnlyRecordingCount = try container.decode(Int.self, forKey: .localOnlyRecordingCount)
        localProjectContentConflictCount = try container.decodeIfPresent(
            Int.self,
            forKey: .localProjectContentConflictCount
        ) ?? 0
        detectedAt = try container.decode(Date.self, forKey: .detectedAt)
        reviewItems = try container.decodeIfPresent([WorkspaceSyncConflictReviewItem].self, forKey: .reviewItems) ?? []
    }

    private static func reviewItems(
        report: WorkspaceSyncConflictReport,
        localState: WorkspaceState,
        remoteState: WorkspaceState?
    ) -> [WorkspaceSyncConflictReviewItem] {
        let localProjectsByID = WorkspaceSyncPayloadPolicy.dictionaryByFirstID(
            localState.projects,
            id: \.id
        )
        let remoteProjectsByID = WorkspaceSyncPayloadPolicy.dictionaryByFirstID(
            remoteState?.projects ?? [],
            id: \.id
        )
        let localRecordingsByID = Dictionary(
            uniqueKeysWithValues: localState.projects.flatMap(\.recordings).map { ($0.id, $0) }
        )
        let uploadItems = localState.uploadJobs
            .filter { report.localOnlyUploadJobIDs.contains($0.id) }
            .sorted { $0.id < $1.id }
            .map { job in
                let project = localProjectsByID[job.ideaProjectID]
                let recording = localRecordingsByID[job.recordingID]
                return WorkspaceSyncConflictReviewItem(
                    id: "upload:\(job.id)",
                    kind: .localUploadJob,
                    projectTitle: project?.title ?? "Unknown project",
                    sourceLabel: project?.source.label ?? "Unknown source",
                    statusLabel: job.status.label,
                    detail: uploadDetail(job: job, recording: recording),
                    protectedID: job.id,
                    relatedRecordingID: job.recordingID
                )
            }

        let recordingItems = localState.projects
            .flatMap { project in
                project.recordings
                    .filter { report.localOnlyRecordingIDs.contains($0.id) }
                    .map { recording in
                        WorkspaceSyncConflictReviewItem(
                            id: "recording:\(recording.id)",
                            kind: .localRecording,
                            projectTitle: project.title,
                            sourceLabel: project.source.label,
                            statusLabel: recording.syncStatus.label,
                            detail: recordingDetail(recording),
                            protectedID: recording.id
                        )
                    }
            }
            .sorted { $0.id < $1.id }

        let projectItems = report.projectContentConflicts.flatMap { conflict in
            let fieldItems = conflict.fields.map { field in
                let localProject = localProjectsByID[conflict.projectID]
                let remoteProject = remoteProjectsByID[conflict.projectID]
                return WorkspaceSyncConflictReviewItem(
                    id: "project:\(conflict.projectID):\(field.rawValue)",
                    kind: .projectContent,
                    projectTitle: conflict.projectTitle,
                    sourceLabel: "Field diff",
                    statusLabel: "Changed locally and remotely",
                    detail: "\(field.label) changed on both sides",
                    protectedID: conflict.projectID,
                    projectField: field,
                    fieldDiffPreview: fieldDiffPreview(field: field, local: localProject, remote: remoteProject)
                )
            }
            let artifactItems = artifactReviewItems(
                conflict: conflict,
                localProject: localProjectsByID[conflict.projectID]
            )
            let collectionItems = collectionReviewItems(
                conflict: conflict,
                localProject: localProjectsByID[conflict.projectID]
            )
            return fieldItems + artifactItems + collectionItems
        }

        return uploadItems + recordingItems + projectItems
    }

    private static func uploadDetail(job: UploadJob, recording: Recording?) -> String {
        let device = recording?.deviceName.isEmpty == false ? recording?.deviceName ?? "Unknown device" : "Unknown device"
        let duration = recording.map { durationText(seconds: $0.durationSeconds) } ?? "duration unavailable"
        return "\(device), \(duration), attempt \(job.attemptCount)"
    }

    private static func recordingDetail(_ recording: Recording) -> String {
        "\(recording.deviceName), \(durationText(seconds: recording.durationSeconds)), \(recording.localFileStatus.label.lowercased()) locally"
    }

    private static func fieldDiffPreview(
        field: WorkspaceSyncProjectConflictField,
        local: IdeaProject?,
        remote: IdeaProject?
    ) -> WorkspaceSyncConflictFieldDiffPreview? {
        guard let local, let remote else { return nil }
        let localValue = fieldValuePreview(field: field, project: local)
        let remoteValue = fieldValuePreview(field: field, project: remote)
        return WorkspaceSyncConflictFieldDiffPreview(
            localValue: localValue,
            remoteValue: remoteValue,
            changeSummary: changeSummary(field: field, localValue: localValue, remoteValue: remoteValue)
        )
    }

    private static func artifactReviewItems(
        conflict: WorkspaceSyncProjectConflict,
        localProject: IdeaProject?
    ) -> [WorkspaceSyncConflictReviewItem] {
        guard conflict.fields.contains(.artifacts), let localProject else { return [] }
        return localProject.artifacts
            .sorted { $0.id < $1.id }
            .map { artifact in
                WorkspaceSyncConflictReviewItem(
                    id: "project:\(conflict.projectID):artifacts:item:\(artifact.id)",
                    kind: .projectArtifact,
                    projectTitle: conflict.projectTitle,
                    sourceLabel: "Artifact item",
                    statusLabel: "\(artifact.kind.label) v\(artifact.version)",
                    detail: artifactItemDetail(artifact),
                    protectedID: artifact.id,
                    projectID: conflict.projectID,
                    projectField: .artifacts
                )
            }
    }

    private static func artifactItemDetail(_ artifact: Artifact) -> String {
        "\(quotedPreview(artifact.title)), by \(artifact.createdBy), content fingerprint \(fingerprint(artifact.markdown))"
    }

    private static func collectionReviewItems(
        conflict: WorkspaceSyncProjectConflict,
        localProject: IdeaProject?
    ) -> [WorkspaceSyncConflictReviewItem] {
        guard let localProject else { return [] }
        let itemFields = Set(conflict.fields.filter(\.supportsItemMerge))
        guard !itemFields.isEmpty else { return [] }

        var items = [WorkspaceSyncConflictReviewItem]()
        if itemFields.contains(.questions) {
            items += localProject.questions.map { question in
                collectionReviewItem(
                    conflict: conflict,
                    field: .questions,
                    itemID: question.id,
                    sourceLabel: "Question item",
                    statusLabel: question.isBlocking ? "Blocking" : "Non-blocking",
                    detail: questionItemDetail(question)
                )
            }
        }
        if itemFields.contains(.assumptions) {
            items += localProject.assumptions.map { assumption in
                collectionReviewItem(
                    conflict: conflict,
                    field: .assumptions,
                    itemID: assumption.id,
                    sourceLabel: "Assumption item",
                    statusLabel: "Confidence \(percent(assumption.confidence))",
                    detail: assumptionItemDetail(assumption)
                )
            }
        }
        if itemFields.contains(.validationExperiments) {
            items += localProject.validationExperiments.map { experiment in
                collectionReviewItem(
                    conflict: conflict,
                    field: .validationExperiments,
                    itemID: experiment.id,
                    sourceLabel: "Experiment item",
                    statusLabel: "Validation plan",
                    detail: validationExperimentItemDetail(experiment)
                )
            }
        }
        if itemFields.contains(.codexTasks) {
            items += localProject.codexTasks.map { task in
                collectionReviewItem(
                    conflict: conflict,
                    field: .codexTasks,
                    itemID: task.id,
                    sourceLabel: "Codex task item",
                    statusLabel: "\(task.acceptanceCriteria.count) acceptance, \(task.testPlan.count) tests",
                    detail: codexTaskItemDetail(task)
                )
            }
        }
        if itemFields.contains(.workflowRuns) {
            items += localProject.workflowRuns.map { run in
                collectionReviewItem(
                    conflict: conflict,
                    field: .workflowRuns,
                    itemID: run.id,
                    sourceLabel: "Workflow run item",
                    statusLabel: run.status.rawValue.capitalized,
                    detail: workflowRunItemDetail(run)
                )
            }
        }
        return items.sorted { $0.id < $1.id }
    }

    private static func collectionReviewItem(
        conflict: WorkspaceSyncProjectConflict,
        field: WorkspaceSyncProjectConflictField,
        itemID: String,
        sourceLabel: String,
        statusLabel: String,
        detail: String
    ) -> WorkspaceSyncConflictReviewItem {
        WorkspaceSyncConflictReviewItem(
            id: "project:\(conflict.projectID):\(field.rawValue):item:\(itemID)",
            kind: .projectCollectionItem,
            projectTitle: conflict.projectTitle,
            sourceLabel: sourceLabel,
            statusLabel: statusLabel,
            detail: detail,
            protectedID: itemID,
            projectID: conflict.projectID,
            projectField: field
        )
    }

    private static func questionItemDetail(_ question: Question) -> String {
        let answerState = question.answer?.isEmpty == false ? "answer present" : "answer missing"
        return "\(answerState), prompt fingerprint \(fingerprint(question.prompt)), answer fingerprint \(fingerprint(question.answer ?? ""))"
    }

    private static func assumptionItemDetail(_ assumption: Assumption) -> String {
        "text fingerprint \(fingerprint(assumption.text)), evidence fingerprint \(fingerprint(assumption.evidence))"
    }

    private static func validationExperimentItemDetail(_ experiment: ValidationExperiment) -> String {
        "title fingerprint \(fingerprint(experiment.title)), metric fingerprint \(fingerprint(experiment.metric)), criteria fingerprint \(fingerprint(experiment.goNoGoCriteria))"
    }

    private static func codexTaskItemDetail(_ task: CodexTask) -> String {
        "title fingerprint \(fingerprint(task.title)), criteria fingerprint \(fingerprint(task.acceptanceCriteria.joined(separator: "|"))), test fingerprint \(fingerprint(task.testPlan.joined(separator: "|")))"
    }

    private static func workflowRunItemDetail(_ run: WorkflowRun) -> String {
        var parts = [
            "template \(run.templateID)",
            "\(run.stepRuns.count) steps",
            "\(run.artifactIDs.count) artifacts"
        ]
        if let errorMessage = run.errorMessage, !errorMessage.isEmpty {
            parts.append("error fingerprint \(fingerprint(errorMessage))")
        }
        return parts.joined(separator: ", ")
    }

    private static func fieldValuePreview(field: WorkspaceSyncProjectConflictField, project: IdeaProject) -> String {
        switch field {
        case .title:
            return quotedPreview(project.title)
        case .status:
            return project.status.label
        case .summary:
            return quotedPreview(project.summary)
        case .tags:
            return project.tags.isEmpty ? "No tags" : project.tags.map(\.label).joined(separator: ", ")
        case .score:
            return "confidence \(percent(project.score.confidence)), completeness \(percent(project.score.completeness)), risk \(percent(project.score.risk))"
        case .transcript:
            return "clean text \(project.transcript.cleanText.count) chars, \(project.transcript.segments.count) segments, \(project.transcript.unclearFragments.count) unclear, fingerprint \(fingerprint(project.transcript.cleanText))"
        case .questions:
            let answeredCount = project.questions.filter { $0.answer?.isEmpty == false }.count
            let blockingCount = project.questions.filter(\.isBlocking).count
            return "\(project.questions.count) questions, \(answeredCount) answered, \(blockingCount) blocking, fingerprint \(fingerprint(project.questions.map(\.prompt).joined(separator: "|")))"
        case .artifacts:
            let artifactKinds = project.artifacts
                .prefix(3)
                .map { "\($0.kind.label) v\($0.version)" }
                .joined(separator: "; ")
            let suffix = project.artifacts.count > 3 ? " +\(project.artifacts.count - 3) more" : ""
            let label = artifactKinds.isEmpty ? "No artifacts" : artifactKinds + suffix
            return "\(project.artifacts.count) artifacts, \(label), content fingerprint \(fingerprint(project.artifacts.map(\.markdown).joined(separator: "|")))"
        case .assumptions:
            let averageConfidence = project.assumptions.isEmpty
                ? 0
                : project.assumptions.map(\.confidence).reduce(0, +) / Double(project.assumptions.count)
            return "\(project.assumptions.count) assumptions, average confidence \(percent(averageConfidence)), fingerprint \(fingerprint(project.assumptions.map(\.text).joined(separator: "|")))"
        case .validationExperiments:
            return "\(project.validationExperiments.count) experiments, title fingerprint \(fingerprint(project.validationExperiments.map(\.title).joined(separator: "|"))), criteria fingerprint \(fingerprint(project.validationExperiments.map(\.goNoGoCriteria).joined(separator: "|")))"
        case .codexTasks:
            return "\(project.codexTasks.count) Codex tasks, title fingerprint \(fingerprint(project.codexTasks.map(\.title).joined(separator: "|"))), acceptance fingerprint \(fingerprint(project.codexTasks.flatMap(\.acceptanceCriteria).joined(separator: "|")))"
        case .workflowRuns:
            let completedCount = project.workflowRuns.filter { $0.status == .completed }.count
            let failedCount = project.workflowRuns.filter { $0.status == .failed }.count
            let runningCount = project.workflowRuns.filter { $0.status == .running }.count
            return "\(project.workflowRuns.count) runs, \(completedCount) completed, \(failedCount) failed, \(runningCount) running"
        }
    }

    private static func changeSummary(
        field: WorkspaceSyncProjectConflictField,
        localValue: String,
        remoteValue: String
    ) -> String {
        if localValue == remoteValue {
            return "\(field.label) metadata differs."
        }
        return "Choose local to keep the on-device \(field.label.lowercased()); leave off for the backend version."
    }

    private static func quotedPreview(_ value: String) -> String {
        let normalized = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !normalized.isEmpty else { return "Empty" }
        let limit = 140
        if normalized.count <= limit {
            return "\"\(normalized)\""
        }
        let endIndex = normalized.index(normalized.startIndex, offsetBy: limit)
        return "\"\(normalized[..<endIndex])...\""
    }

    private static func boundedList(_ values: [String]) -> String {
        guard !values.isEmpty else { return "" }
        let preview = values.prefix(3).map { quotedPreview($0) }.joined(separator: ", ")
        let suffix = values.count > 3 ? " +\(values.count - 3) more" : ""
        return ": \(preview)\(suffix)"
    }

    private static func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }

    private static func fingerprint(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    private static func durationText(seconds: Int) -> String {
        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        if minutes == 0 {
            return "\(remainingSeconds)s"
        }
        return "\(minutes)m \(remainingSeconds)s"
    }
}

public struct WorkspaceSyncConflictError: Error, Equatable, Sendable {
    public var report: WorkspaceSyncConflictReport

    public init(report: WorkspaceSyncConflictReport) {
        self.report = report
    }
}

public struct WorkspaceSyncPublicationBlockedError: Error, Equatable, Sendable, UserFacingIdeaForgeError {
    public var message: String

    public init(message: String) {
        self.message = message
    }

    public var userFacingMessage: String { message }
}

public enum WorkspaceSyncConflictResolution: Sendable {
    case failClosed
    case preserveLocalUploadWork
    case preserveReviewedLocalWork(WorkspaceSyncConflictMergeSelection)
}

public struct WorkspaceSyncEngine: Sendable {
    public var client: BackendWorkspaceSyncClient

    public init(client: BackendWorkspaceSyncClient) {
        self.client = client
    }

    @MainActor
    public func pullLatest(
        into store: IdeaForgeStore,
        syncedAt: Date = Date()
    ) async throws -> WorkspaceSyncSummary {
        let localUpdatedAt = store.updatedAt
        let remoteState = try await client.fetchWorkspaceSnapshot(
            since: store.syncHealth.lastRemoteWorkspaceUpdatedAt
        )
        let applied = try store.applyRemoteWorkspaceSnapshot(remoteState, syncedAt: syncedAt)
        return WorkspaceSyncSummary(
            fetched: true,
            appliedRemoteSnapshot: applied,
            remoteUpdatedAt: remoteState.updatedAt,
            localUpdatedAt: localUpdatedAt
        )
    }

    @MainActor
    public func synchronize(
        store: IdeaForgeStore,
        syncedAt: Date = Date()
    ) async throws -> WorkspaceSyncSummary {
        let remoteCursor = store.syncHealth.lastRemoteWorkspaceUpdatedAt
        let remoteState = try await client.fetchWorkspaceSnapshot(
            since: remoteCursor
        )
        let localState = store.workspaceState()
        guard WorkspaceSyncPayloadPolicy.isStructurallyValid(localState) else {
            throw BackendSyncError.invalidResponse
        }
        let normalizedRemoteState = WorkspaceSyncPayloadPolicy.inboundState(
            from: remoteState,
            preservingDeviceLocalState: localState
        )
        let conflictReport = WorkspaceSyncConflictReport.report(
            localState: localState,
            remoteState: normalizedRemoteState
        )
        let applied: Bool
        if let conflictReport,
           conflictReport.projectContentConflicts.isEmpty,
           !conflictReport.localOnlyRecordingIDs.isEmpty || !conflictReport.localOnlyUploadJobIDs.isEmpty {
            let recordingIDs = Set(conflictReport.localOnlyRecordingIDs)
            let uploadJobIDs = localState.uploadJobs.compactMap { job in
                recordingIDs.contains(job.recordingID) || conflictReport.localOnlyUploadJobIDs.contains(job.id)
                    ? job.id
                    : nil
            }
            applied = try store.applyRemoteWorkspaceSnapshot(
                remoteState,
                syncedAt: syncedAt,
                conflictResolution: .preserveReviewedLocalWork(
                    WorkspaceSyncConflictMergeSelection(
                        uploadJobIDsToPreserve: uploadJobIDs,
                        recordingIDsToPreserve: conflictReport.localOnlyRecordingIDs
                    )
                )
            )
        } else {
            applied = try store.applyRemoteWorkspaceSnapshot(remoteState, syncedAt: syncedAt)
        }
        let pullSummary = WorkspaceSyncSummary(
            fetched: true,
            appliedRemoteSnapshot: applied,
            remoteUpdatedAt: remoteState.updatedAt,
            localUpdatedAt: localState.updatedAt
        )
        if applied, conflictReport != nil, store.updatedAt > remoteState.updatedAt {
            return try await pushPolicyCheckedLocalSnapshot(from: store, syncedAt: syncedAt)
        }
        guard !pullSummary.appliedRemoteSnapshot,
              let remoteUpdatedAt = pullSummary.remoteUpdatedAt,
              store.updatedAt > remoteUpdatedAt else {
            return pullSummary
        }
        return try await pushPolicyCheckedLocalSnapshot(from: store, syncedAt: syncedAt)
    }

    @MainActor
    public func pushLocalSnapshot(
        from store: IdeaForgeStore,
        syncedAt: Date = Date()
    ) async throws -> WorkspaceSyncSummary {
        let localUpdatedAt = store.updatedAt
        do {
            let receipt = try await client.pushWorkspaceSnapshot(
                store.workspaceState(),
                baseRemoteUpdatedAt: store.syncHealth.lastRemoteWorkspaceUpdatedAt
            )
            guard store.markWorkspaceSnapshotPublished(
                remoteUpdatedAt: receipt.acceptedUpdatedAt,
                publishedLocalUpdatedAt: localUpdatedAt,
                syncedAt: syncedAt
            ) else {
                throw WorkspaceRepositoryError.unwritableState
            }
            return WorkspaceSyncSummary(
                fetched: false,
                appliedRemoteSnapshot: false,
                pushedLocalSnapshot: true,
                remoteUpdatedAt: receipt.acceptedUpdatedAt,
                acceptedLocalUpdatedAt: localUpdatedAt,
                localUpdatedAt: localUpdatedAt
            )
        } catch BackendSyncError.preconditionFailed {
            let remoteState = try await client.fetchWorkspaceSnapshot(since: nil)
            _ = try store.applyRemoteWorkspaceSnapshot(remoteState, syncedAt: syncedAt)
            throw BackendSyncError.preconditionFailed("Remote workspace changed before local snapshot publish.")
        }
    }

    @MainActor
    public func pullLatestPreservingLocalUploadWork(
        into store: IdeaForgeStore,
        syncedAt: Date = Date()
    ) async throws -> WorkspaceSyncSummary {
        let localUpdatedAt = store.updatedAt
        let remoteState = try await client.fetchWorkspaceSnapshot(
            since: store.syncHealth.lastRemoteWorkspaceUpdatedAt
        )
        let applied = try store.applyRemoteWorkspaceSnapshot(
            remoteState,
            syncedAt: syncedAt,
            conflictResolution: .preserveLocalUploadWork
        )
        let summary = WorkspaceSyncSummary(
            fetched: true,
            appliedRemoteSnapshot: applied,
            remoteUpdatedAt: remoteState.updatedAt,
            localUpdatedAt: localUpdatedAt
        )
        if applied, store.updatedAt > remoteState.updatedAt {
            return try await pushPolicyCheckedLocalSnapshot(from: store, syncedAt: syncedAt)
        }
        return summary
    }

    @MainActor
    public func pullLatestApplyingReviewedMerge(
        into store: IdeaForgeStore,
        selection: WorkspaceSyncConflictMergeSelection,
        syncedAt: Date = Date()
    ) async throws -> WorkspaceSyncSummary {
        let localUpdatedAt = store.updatedAt
        let remoteState = try await client.fetchWorkspaceSnapshot(
            since: store.syncHealth.lastRemoteWorkspaceUpdatedAt
        )
        let applied = try store.applyRemoteWorkspaceSnapshot(
            remoteState,
            syncedAt: syncedAt,
            conflictResolution: .preserveReviewedLocalWork(selection)
        )
        let summary = WorkspaceSyncSummary(
            fetched: true,
            appliedRemoteSnapshot: applied,
            remoteUpdatedAt: remoteState.updatedAt,
            localUpdatedAt: localUpdatedAt
        )
        if applied, store.updatedAt > remoteState.updatedAt {
            return try await pushPolicyCheckedLocalSnapshot(from: store, syncedAt: syncedAt)
        }
        return summary
    }

    @MainActor
    private func pushPolicyCheckedLocalSnapshot(
        from store: IdeaForgeStore,
        syncedAt: Date
    ) async throws -> WorkspaceSyncSummary {
        let state = store.workspaceState()
        if let decision = WorkspaceAutoSyncPolicy.localPreflightDecision(for: state) {
            throw WorkspaceSyncPublicationBlockedError(message: decision.message)
        }
        return try await pushLocalSnapshot(from: store, syncedAt: syncedAt)
    }
}

private extension String {
    func removingPrefix(_ prefix: String) -> String {
        guard hasPrefix(prefix) else { return self }
        return String(dropFirst(prefix.count))
    }
}
