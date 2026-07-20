import Foundation

public enum BackendOperationsError: Error, Equatable {
    case invalidResponse
    case requestFailed(String)
}

public struct BackendOperationsConfiguration: Equatable, Sendable {
    public var baseURL: URL
    public var bearerToken: String
    public var workspaceID: String
    public var statusPath: String
    public var backupManifestPath: String
    public var restoreDrillPath: String
    public var metricsPath: String

    public init(
        baseURL: URL,
        bearerToken: String,
        workspaceID: String = "",
        statusPath: String = "/v1/admin/status",
        backupManifestPath: String = "/v1/admin/backup-manifest",
        restoreDrillPath: String = "/v1/admin/restore-drill",
        metricsPath: String = "/v1/admin/metrics"
    ) {
        self.baseURL = baseURL
        self.bearerToken = bearerToken
        self.workspaceID = workspaceID
        self.statusPath = statusPath
        self.backupManifestPath = backupManifestPath
        self.restoreDrillPath = restoreDrillPath
        self.metricsPath = metricsPath
    }

    public var statusURL: URL {
        url(path: statusPath)
    }

    public var backupManifestURL: URL {
        url(path: backupManifestPath)
    }

    public var restoreDrillURL: URL {
        url(path: restoreDrillPath)
    }

    public var metricsURL: URL {
        url(path: metricsPath)
    }

    public var isConfigured: Bool {
        !bearerToken.isEmpty && !workspaceID.isEmpty
    }

    private func url(path: String) -> URL {
        let normalizedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return baseURL.appendingPathComponent(normalizedPath)
    }
}

public struct BackendSchemaMigration: Codable, Equatable, Sendable {
    public var version: String
    public var appliedAt: String

    public init(version: String, appliedAt: String) {
        self.version = version
        self.appliedAt = appliedAt
    }
}

public struct BackendOperationsSchemaStatus: Codable, Equatable, Sendable {
    public var currentVersion: String
    public var appliedMigrations: [BackendSchemaMigration]

    public init(currentVersion: String, appliedMigrations: [BackendSchemaMigration]) {
        self.currentVersion = currentVersion
        self.appliedMigrations = appliedMigrations
    }
}

public struct BackendOperationsCheck: Codable, Equatable, Identifiable, Sendable {
    public var name: String
    public var status: String

    public var id: String { name }

    public init(name: String, status: String) {
        self.name = name
        self.status = status
    }
}

public struct BackendOperationsCounts: Codable, Equatable, Sendable {
    public var accounts: Int
    public var auditEvents: Int
    public var jobs: Int
    public var objects: Int
    public var transcriptionResults: Int
    public var workflowResults: Int
    public var usageEvents: Int

    public init(
        accounts: Int,
        auditEvents: Int,
        jobs: Int,
        objects: Int,
        transcriptionResults: Int,
        workflowResults: Int = 0,
        usageEvents: Int
    ) {
        self.accounts = accounts
        self.auditEvents = auditEvents
        self.jobs = jobs
        self.objects = objects
        self.transcriptionResults = transcriptionResults
        self.workflowResults = workflowResults
        self.usageEvents = usageEvents
    }

    private enum CodingKeys: String, CodingKey {
        case accounts
        case auditEvents
        case jobs
        case objects
        case transcriptionResults
        case workflowResults
        case usageEvents
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try container.decode(Int.self, forKey: .accounts)
        auditEvents = try container.decode(Int.self, forKey: .auditEvents)
        jobs = try container.decode(Int.self, forKey: .jobs)
        objects = try container.decode(Int.self, forKey: .objects)
        transcriptionResults = try container.decode(Int.self, forKey: .transcriptionResults)
        workflowResults = try container.decodeIfPresent(Int.self, forKey: .workflowResults) ?? 0
        usageEvents = try container.decode(Int.self, forKey: .usageEvents)
    }
}

public struct BackendTenantOperationsSummary: Codable, Equatable, Identifiable, Sendable {
    public var workspaceID: String
    public var accountID: String
    public var planName: String
    public var planStatus: BackendPlanStatus
    public var capabilitiesCount: Int
    public var createdAt: String

    public var id: String { workspaceID }

    public init(
        workspaceID: String,
        accountID: String,
        planName: String,
        planStatus: BackendPlanStatus,
        capabilitiesCount: Int,
        createdAt: String
    ) {
        self.workspaceID = workspaceID
        self.accountID = accountID
        self.planName = planName
        self.planStatus = planStatus
        self.capabilitiesCount = capabilitiesCount
        self.createdAt = createdAt
    }
}

public struct BackendOperationsStatus: Codable, Equatable, Sendable {
    public var status: String
    public var generatedAt: String
    public var schema: BackendOperationsSchemaStatus
    public var checks: [BackendOperationsCheck]
    public var counts: BackendOperationsCounts
    public var tenants: [BackendTenantOperationsSummary]

    public init(
        status: String,
        generatedAt: String,
        schema: BackendOperationsSchemaStatus,
        checks: [BackendOperationsCheck],
        counts: BackendOperationsCounts,
        tenants: [BackendTenantOperationsSummary]
    ) {
        self.status = status
        self.generatedAt = generatedAt
        self.schema = schema
        self.checks = checks
        self.counts = counts
        self.tenants = tenants
    }

    public var isReady: Bool {
        status == "ready" && checks.allSatisfy { $0.status == "ok" }
    }

    public func check(named name: String) -> BackendOperationsCheck? {
        checks.first { $0.name == name }
    }
}

public struct BackendBackupWorkspaceManifest: Codable, Equatable, Sendable {
    public var projectCount: Int
    public var workflowTemplateCount: Int
    public var uploadJobCount: Int
    public var updatedAt: String?

    public init(projectCount: Int, workflowTemplateCount: Int, uploadJobCount: Int, updatedAt: String?) {
        self.projectCount = projectCount
        self.workflowTemplateCount = workflowTemplateCount
        self.uploadJobCount = uploadJobCount
        self.updatedAt = updatedAt
    }
}

public struct BackendBackupStorageManifest: Codable, Equatable, Sendable {
    public var objectCount: Int
    public var totalObjectBytes: Int

    public init(objectCount: Int, totalObjectBytes: Int) {
        self.objectCount = objectCount
        self.totalObjectBytes = totalObjectBytes
    }
}

public struct BackendBackupOperationsManifest: Codable, Equatable, Sendable {
    public var accountCount: Int
    public var auditEventCount: Int
    public var jobCount: Int
    public var usageEventCount: Int

    public init(accountCount: Int, auditEventCount: Int, jobCount: Int, usageEventCount: Int) {
        self.accountCount = accountCount
        self.auditEventCount = auditEventCount
        self.jobCount = jobCount
        self.usageEventCount = usageEventCount
    }
}

public struct BackendBackupPrivacyManifest: Codable, Equatable, Sendable {
    public var includesRawTranscript: Bool
    public var includesRawAudio: Bool
    public var includesBearerTokens: Bool
    public var includesEmailAddresses: Bool
    public var includesGeneratedArtifacts: Bool

    public init(
        includesRawTranscript: Bool,
        includesRawAudio: Bool,
        includesBearerTokens: Bool,
        includesEmailAddresses: Bool,
        includesGeneratedArtifacts: Bool
    ) {
        self.includesRawTranscript = includesRawTranscript
        self.includesRawAudio = includesRawAudio
        self.includesBearerTokens = includesBearerTokens
        self.includesEmailAddresses = includesEmailAddresses
        self.includesGeneratedArtifacts = includesGeneratedArtifacts
    }

    public var isContentFree: Bool {
        !includesRawTranscript
            && !includesRawAudio
            && !includesBearerTokens
            && !includesEmailAddresses
            && !includesGeneratedArtifacts
    }
}

public struct BackendBackupManifest: Codable, Equatable, Sendable {
    public var generatedAt: String
    public var schemaVersion: String
    public var workspace: BackendBackupWorkspaceManifest
    public var storage: BackendBackupStorageManifest
    public var operations: BackendBackupOperationsManifest
    public var tenants: [BackendTenantOperationsSummary]
    public var privacy: BackendBackupPrivacyManifest

    public init(
        generatedAt: String,
        schemaVersion: String,
        workspace: BackendBackupWorkspaceManifest,
        storage: BackendBackupStorageManifest,
        operations: BackendBackupOperationsManifest,
        tenants: [BackendTenantOperationsSummary],
        privacy: BackendBackupPrivacyManifest
    ) {
        self.generatedAt = generatedAt
        self.schemaVersion = schemaVersion
        self.workspace = workspace
        self.storage = storage
        self.operations = operations
        self.tenants = tenants
        self.privacy = privacy
    }
}

public struct BackendRestoreDrillRequest: Codable, Equatable, Sendable {
    public var backupGeneratedAt: String
    public var schemaVersion: String

    public init(backupGeneratedAt: String, schemaVersion: String) {
        self.backupGeneratedAt = backupGeneratedAt
        self.schemaVersion = schemaVersion
    }
}

public struct BackendRestoreDrillRestoredCounts: Codable, Equatable, Sendable {
    public var workspace: BackendBackupWorkspaceManifest
    public var storage: BackendBackupStorageManifest
    public var operations: BackendBackupOperationsManifest

    public init(
        workspace: BackendBackupWorkspaceManifest,
        storage: BackendBackupStorageManifest,
        operations: BackendBackupOperationsManifest
    ) {
        self.workspace = workspace
        self.storage = storage
        self.operations = operations
    }
}

public struct BackendRestoreDrillPrivacyReport: Codable, Equatable, Sendable {
    public var includesRawTranscript: Bool
    public var includesRawAudio: Bool
    public var includesBearerTokens: Bool
    public var includesEmailAddresses: Bool
    public var includesGeneratedArtifacts: Bool
    public var includesLocalPaths: Bool

    public init(
        includesRawTranscript: Bool,
        includesRawAudio: Bool,
        includesBearerTokens: Bool,
        includesEmailAddresses: Bool,
        includesGeneratedArtifacts: Bool,
        includesLocalPaths: Bool
    ) {
        self.includesRawTranscript = includesRawTranscript
        self.includesRawAudio = includesRawAudio
        self.includesBearerTokens = includesBearerTokens
        self.includesEmailAddresses = includesEmailAddresses
        self.includesGeneratedArtifacts = includesGeneratedArtifacts
        self.includesLocalPaths = includesLocalPaths
    }

    public var isContentFree: Bool {
        !includesRawTranscript
            && !includesRawAudio
            && !includesBearerTokens
            && !includesEmailAddresses
            && !includesGeneratedArtifacts
            && !includesLocalPaths
    }
}

public struct BackendRestoreDrillReport: Codable, Equatable, Sendable {
    public var status: String
    public var generatedAt: String
    public var sourceBackupGeneratedAt: String
    public var schemaVersion: String
    public var checks: [BackendOperationsCheck]
    public var restored: BackendRestoreDrillRestoredCounts
    public var privacy: BackendRestoreDrillPrivacyReport

    public init(
        status: String,
        generatedAt: String,
        sourceBackupGeneratedAt: String,
        schemaVersion: String,
        checks: [BackendOperationsCheck],
        restored: BackendRestoreDrillRestoredCounts,
        privacy: BackendRestoreDrillPrivacyReport
    ) {
        self.status = status
        self.generatedAt = generatedAt
        self.sourceBackupGeneratedAt = sourceBackupGeneratedAt
        self.schemaVersion = schemaVersion
        self.checks = checks
        self.restored = restored
        self.privacy = privacy
    }

    public var isPassing: Bool {
        status == "passed" && checks.allSatisfy { $0.status == "ok" } && privacy.isContentFree
    }

    public func check(named name: String) -> BackendOperationsCheck? {
        checks.first { $0.name == name }
    }
}

public struct BackendOperationsStorageMetrics: Codable, Equatable, Sendable {
    public var objectCount: Int
    public var totalObjectBytes: Int

    public init(objectCount: Int, totalObjectBytes: Int) {
        self.objectCount = objectCount
        self.totalObjectBytes = totalObjectBytes
    }
}

public struct BackendOperationsUsageMetric: Codable, Equatable, Identifiable, Sendable {
    public var metric: String
    public var quantity: Double

    public var id: String { metric }

    public init(metric: String, quantity: Double) {
        self.metric = metric
        self.quantity = quantity
    }
}

public struct BackendOperationsMetricsPrivacy: Codable, Equatable, Sendable {
    public var includesRawTranscript: Bool
    public var includesRawAudio: Bool
    public var includesBearerTokens: Bool
    public var includesEmailAddresses: Bool
    public var includesGeneratedArtifacts: Bool
    public var includesLocalPaths: Bool

    public init(
        includesRawTranscript: Bool,
        includesRawAudio: Bool,
        includesBearerTokens: Bool,
        includesEmailAddresses: Bool,
        includesGeneratedArtifacts: Bool,
        includesLocalPaths: Bool
    ) {
        self.includesRawTranscript = includesRawTranscript
        self.includesRawAudio = includesRawAudio
        self.includesBearerTokens = includesBearerTokens
        self.includesEmailAddresses = includesEmailAddresses
        self.includesGeneratedArtifacts = includesGeneratedArtifacts
        self.includesLocalPaths = includesLocalPaths
    }

    public var isContentFree: Bool {
        !includesRawTranscript
            && !includesRawAudio
            && !includesBearerTokens
            && !includesEmailAddresses
            && !includesGeneratedArtifacts
            && !includesLocalPaths
    }
}

public struct BackendOperationsMetrics: Codable, Equatable, Sendable {
    public var status: String
    public var generatedAt: String
    public var schemaVersion: String
    public var jobCountsByStatus: [String: Int]
    public var jobCountsByKind: [String: Int]
    public var storage: BackendOperationsStorageMetrics
    public var usage: [BackendOperationsUsageMetric]
    public var privacy: BackendOperationsMetricsPrivacy

    public init(
        status: String,
        generatedAt: String,
        schemaVersion: String,
        jobCountsByStatus: [String: Int],
        jobCountsByKind: [String: Int],
        storage: BackendOperationsStorageMetrics,
        usage: [BackendOperationsUsageMetric],
        privacy: BackendOperationsMetricsPrivacy
    ) {
        self.status = status
        self.generatedAt = generatedAt
        self.schemaVersion = schemaVersion
        self.jobCountsByStatus = jobCountsByStatus
        self.jobCountsByKind = jobCountsByKind
        self.storage = storage
        self.usage = usage
        self.privacy = privacy
    }

    public var isMonitoringSafe: Bool {
        status == "ready" && privacy.isContentFree
    }
}

public struct BackendOperationsClient: Sendable {
    public var configuration: BackendOperationsConfiguration
    public var transport: any HTTPRequestTransport

    public init(
        configuration: BackendOperationsConfiguration,
        transport: any HTTPRequestTransport = URLSessionHTTPRequestTransport()
    ) {
        self.configuration = configuration
        self.transport = transport
    }

    public func fetchStatus() async throws -> BackendOperationsStatus {
        try await get(configuration.statusURL)
    }

    public func fetchBackupManifest() async throws -> BackendBackupManifest {
        try await get(configuration.backupManifestURL)
    }

    public func runRestoreDrill(_ request: BackendRestoreDrillRequest) async throws -> BackendRestoreDrillReport {
        try await post(request, to: configuration.restoreDrillURL)
    }

    public func fetchMetrics() async throws -> BackendOperationsMetrics {
        try await get(configuration.metricsURL)
    }

    private func get<Response: Decodable>(_ url: URL) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(configuration.bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue(configuration.workspaceID, forHTTPHeaderField: BackendRequestHeader.workspaceID)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw BackendOperationsError.requestFailed("HTTP \(response.statusCode)")
        }

        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func post<Body: Encodable, Response: Decodable>(_ body: Body, to url: URL) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue(configuration.workspaceID, forHTTPHeaderField: BackendRequestHeader.workspaceID)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw BackendOperationsError.requestFailed("HTTP \(response.statusCode)")
        }

        return try JSONDecoder().decode(Response.self, from: data)
    }
}
