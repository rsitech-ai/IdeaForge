import Foundation

public struct WorkspaceState: Codable, Equatable, Sendable {
    public var projects: [IdeaProject]
    public var workflowTemplates: [WorkflowTemplate]
    public var uploadJobs: [UploadJob]
    public var privacyMode: PrivacyMode
    public var syncHealth: SyncHealth
    public var selectedProjectID: String?
    public var updatedAt: Date

    public init(
        projects: [IdeaProject],
        workflowTemplates: [WorkflowTemplate],
        uploadJobs: [UploadJob] = [],
        privacyMode: PrivacyMode,
        syncHealth: SyncHealth,
        selectedProjectID: String?,
        updatedAt: Date
    ) {
        self.projects = projects
        self.workflowTemplates = workflowTemplates
        self.uploadJobs = uploadJobs
        self.privacyMode = privacyMode
        self.syncHealth = syncHealth
        self.selectedProjectID = selectedProjectID
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case projects
        case workflowTemplates
        case uploadJobs
        case privacyMode
        case syncHealth
        case selectedProjectID
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projects = try container.decode([IdeaProject].self, forKey: .projects)
        workflowTemplates = try container.decode([WorkflowTemplate].self, forKey: .workflowTemplates)
        uploadJobs = try container.decodeIfPresent([UploadJob].self, forKey: .uploadJobs) ?? []
        privacyMode = try container.decode(PrivacyMode.self, forKey: .privacyMode)
        syncHealth = try container.decode(SyncHealth.self, forKey: .syncHealth)
        selectedProjectID = try container.decodeIfPresent(String.self, forKey: .selectedProjectID)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    public static func seed() -> WorkspaceState {
        let store = SampleData.store()
        return store.workspaceState()
    }

    public static func fresh() -> WorkspaceState {
        WorkspaceState(
            projects: [],
            workflowTemplates: DefaultWorkflows.templates,
            uploadJobs: [],
            privacyMode: .privateLocal,
            syncHealth: SyncHealth(
                watchReachable: false,
                queuedUploads: 0,
                lastSuccessfulSync: .distantPast,
                failingItems: 0
            ),
            selectedProjectID: nil,
            updatedAt: .distantPast
        )
    }
}

public enum WorkspaceRepositoryError: Error, Equatable {
    case unreadableState
    case unwritableState
}

public protocol WorkspaceRepository: Sendable {
    func load() throws -> WorkspaceState?
    func save(_ state: WorkspaceState) throws
}

public struct JSONWorkspaceRepository: WorkspaceRepository {
    public var fileURL: URL
    public var encoder: JSONEncoder
    public var decoder: JSONDecoder

    public init(fileURL: URL) {
        self.fileURL = fileURL
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func load() throws -> WorkspaceState? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: fileURL)
            return try decoder.decode(WorkspaceState.self, from: data)
        } catch {
            throw WorkspaceRepositoryError.unreadableState
        }
    }

    public func save(_ state: WorkspaceState) throws {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(state)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            throw WorkspaceRepositoryError.unwritableState
        }
    }

    public static func applicationSupport(fileManager: FileManager = .default) -> JSONWorkspaceRepository {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return JSONWorkspaceRepository(fileURL: base.appending(path: "IdeaForge/workspace.json"))
    }
}

public struct InMemoryWorkspaceRepository: WorkspaceRepository {
    private final class Box: @unchecked Sendable {
        var state: WorkspaceState?

        init(state: WorkspaceState?) {
            self.state = state
        }
    }

    private let box: Box

    public init(state: WorkspaceState? = nil) {
        box = Box(state: state)
    }

    public func load() throws -> WorkspaceState? {
        box.state
    }

    public func save(_ state: WorkspaceState) throws {
        box.state = state
    }
}
