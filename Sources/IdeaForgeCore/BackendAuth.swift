import Foundation

public enum BackendAuthError: Error, Equatable {
    case invalidResponse
    case requestFailed(String)
}

public enum BackendAccountProvisioningError: Error, Equatable {
    case invalidResponse
    case requestFailed(String)
}

public enum BackendAccountCapability: String, Codable, CaseIterable, Identifiable, Equatable, Sendable {
    case uploadRecordings = "upload_recordings"
    case syncWorkspace = "sync_workspace"
    case runAIWorkflows = "run_ai_workflows"
    case reconcileBilling = "reconcile_billing"
    case manageAccount = "manage_account"
    case registerPushNotifications = "register_push_notifications"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .uploadRecordings: "Upload recordings"
        case .syncWorkspace: "Sync workspace"
        case .runAIWorkflows: "Run AI workflows"
        case .reconcileBilling: "Reconcile billing"
        case .manageAccount: "Manage account"
        case .registerPushNotifications: "Register push notifications"
        }
    }
}

public struct BackendAuthenticatedSession: Codable, Equatable, Sendable {
    public var userID: String
    public var email: String?
    public var workspaceID: String
    public var account: BackendAccountSummary
    public var capabilities: [BackendAccountCapability]
    public var accountPortalURL: URL?
    public var accountDeletionURL: URL?

    public init(
        userID: String,
        email: String? = nil,
        workspaceID: String,
        account: BackendAccountSummary,
        capabilities: [BackendAccountCapability],
        accountPortalURL: URL? = nil,
        accountDeletionURL: URL? = nil
    ) {
        self.userID = userID
        self.email = email
        self.workspaceID = workspaceID
        self.account = account
        self.capabilities = capabilities
        self.accountPortalURL = accountPortalURL
        self.accountDeletionURL = accountDeletionURL
    }

    public func hasCapability(_ capability: BackendAccountCapability) -> Bool {
        capabilities.contains(capability)
    }
}

public struct BackendAccountProvisioningRequest: Codable, Equatable, Sendable {
    public var email: String
    public var workspaceID: String
    public var displayName: String?
    public var idempotencyKey: String?

    public init(
        email: String,
        workspaceID: String,
        displayName: String? = nil,
        idempotencyKey: String? = nil
    ) {
        self.email = email
        self.workspaceID = workspaceID
        self.displayName = displayName
        self.idempotencyKey = idempotencyKey
    }

    private enum CodingKeys: String, CodingKey {
        case email
        case workspaceID
        case displayName
    }
}

public struct BackendProvisionedAccount: Codable, Equatable, Sendable {
    public var workspaceID: String
    public var account: BackendAccountSummary
    public var session: BackendAuthenticatedSession
    public var bearerToken: String
    public var created: Bool

    public init(
        workspaceID: String,
        account: BackendAccountSummary,
        session: BackendAuthenticatedSession,
        bearerToken: String,
        created: Bool
    ) {
        self.workspaceID = workspaceID
        self.account = account
        self.session = session
        self.bearerToken = bearerToken
        self.created = created
    }
}

public struct BackendCapabilityDecision: Equatable, Sendable {
    public var isAllowed: Bool
    public var missingCapabilities: [BackendAccountCapability]
    public var blockers: [String]

    public init(
        isAllowed: Bool,
        missingCapabilities: [BackendAccountCapability] = [],
        blockers: [String] = []
    ) {
        self.isAllowed = isAllowed
        self.missingCapabilities = missingCapabilities
        self.blockers = blockers
    }

    public var blockerSummary: String {
        blockers.joined(separator: " ")
    }
}

public struct BackendCapabilityGate: Equatable, Sendable {
    public var session: BackendAuthenticatedSession?

    public init(session: BackendAuthenticatedSession?) {
        self.session = session
    }

    public func decision(
        requiredCapabilities: [BackendAccountCapability],
        expectedWorkspaceID: String
    ) -> BackendCapabilityDecision {
        guard let session else {
            return BackendCapabilityDecision(
                isAllowed: false,
                blockers: ["Validate backend session before using this backend action."]
            )
        }

        let normalizedExpectedWorkspaceID = expectedWorkspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedExpectedWorkspaceID.isEmpty, session.workspaceID == normalizedExpectedWorkspaceID else {
            return BackendCapabilityDecision(
                isAllowed: false,
                blockers: ["Validated session belongs to a different workspace."]
            )
        }

        let missingCapabilities = requiredCapabilities.filter { !session.hasCapability($0) }
        guard missingCapabilities.isEmpty else {
            let labels = missingCapabilities.map(\.label).joined(separator: ", ")
            let noun = missingCapabilities.count == 1 ? "capability" : "capabilities"
            return BackendCapabilityDecision(
                isAllowed: false,
                missingCapabilities: missingCapabilities,
                blockers: ["Backend session is missing \(noun): \(labels)."]
            )
        }

        return BackendCapabilityDecision(isAllowed: true)
    }
}

public struct BackendAuthConfiguration: Equatable, Sendable {
    public var baseURL: URL
    public var bearerToken: String
    public var workspaceID: String
    public var sessionPath: String

    public init(
        baseURL: URL,
        bearerToken: String,
        workspaceID: String = "",
        sessionPath: String = "/v1/auth/session"
    ) {
        self.baseURL = baseURL
        self.bearerToken = bearerToken
        self.workspaceID = workspaceID
        self.sessionPath = sessionPath
    }

    public var sessionURL: URL {
        let normalizedPath = sessionPath.hasPrefix("/") ? String(sessionPath.dropFirst()) : sessionPath
        return baseURL.appendingPathComponent(normalizedPath)
    }

    public var isConfigured: Bool {
        !bearerToken.isEmpty && !workspaceID.isEmpty
    }
}

public struct BackendAccountProvisioningConfiguration: Equatable, Sendable {
    public var baseURL: URL
    public var bootstrapToken: String
    public var provisionPath: String

    public init(
        baseURL: URL,
        bootstrapToken: String,
        provisionPath: String = "/v1/accounts/provision"
    ) {
        self.baseURL = baseURL
        self.bootstrapToken = bootstrapToken
        self.provisionPath = provisionPath
    }

    public var provisionURL: URL {
        let normalizedPath = provisionPath.hasPrefix("/") ? String(provisionPath.dropFirst()) : provisionPath
        return baseURL.appendingPathComponent(normalizedPath)
    }

    public var isConfigured: Bool {
        !bootstrapToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public struct BackendAccountProvisioningClient: Sendable {
    public var configuration: BackendAccountProvisioningConfiguration
    public var transport: any HTTPRequestTransport

    public init(
        configuration: BackendAccountProvisioningConfiguration,
        transport: any HTTPRequestTransport = URLSessionHTTPRequestTransport()
    ) {
        self.configuration = configuration
        self.transport = transport
    }

    public func provisionAccount(_ provisioningRequest: BackendAccountProvisioningRequest) async throws -> BackendProvisionedAccount {
        var request = URLRequest(url: configuration.provisionURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.bootstrapToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let idempotencyKey = provisioningRequest.idempotencyKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !idempotencyKey.isEmpty {
            request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        }
        request.httpBody = try JSONEncoder().encode(provisioningRequest)

        let (data, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw BackendAccountProvisioningError.requestFailed("HTTP \(response.statusCode)")
        }

        return try JSONDecoder().decode(BackendProvisionedAccount.self, from: data)
    }
}

public struct BackendAuthSessionClient: Sendable {
    public var configuration: BackendAuthConfiguration
    public var transport: any HTTPRequestTransport

    public init(
        configuration: BackendAuthConfiguration,
        transport: any HTTPRequestTransport = URLSessionHTTPRequestTransport()
    ) {
        self.configuration = configuration
        self.transport = transport
    }

    public func validateSession() async throws -> BackendAuthenticatedSession {
        var request = URLRequest(url: configuration.sessionURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(configuration.bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue(configuration.workspaceID, forHTTPHeaderField: BackendRequestHeader.workspaceID)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw BackendAuthError.requestFailed("HTTP \(response.statusCode)")
        }

        return try JSONDecoder().decode(BackendAuthenticatedSession.self, from: data)
    }
}
