import Foundation

public enum BackendAccountError: Error, Equatable {
    case invalidResponse
    case requestFailed(String)
}

public enum BackendPlanStatus: String, Codable, Equatable, Sendable {
    case active
    case trialing
    case pastDue
    case canceled
    case unknown

    public var label: String {
        switch self {
        case .active: "Active"
        case .trialing: "Trial"
        case .pastDue: "Past due"
        case .canceled: "Canceled"
        case .unknown: "Unknown"
        }
    }
}

public struct BackendAccountSummary: Codable, Equatable, Sendable {
    public var id: String
    public var planName: String
    public var planStatus: BackendPlanStatus

    public init(id: String, planName: String, planStatus: BackendPlanStatus) {
        self.id = id
        self.planName = planName
        self.planStatus = planStatus
    }
}

public struct BackendUsageMetric: Codable, Equatable, Identifiable, Sendable {
    public var metric: String
    public var quantity: Double

    public var id: String { metric }

    public init(metric: String, quantity: Double) {
        self.metric = metric
        self.quantity = quantity
    }

    public var displayName: String {
        BackendUsageDisplay.name(for: metric)
    }

    public var quantityLabel: String {
        BackendUsageDisplay.quantity(quantity, metric: metric)
    }
}

public struct BackendUsageEntitlement: Codable, Equatable, Identifiable, Sendable {
    public var metric: String
    public var includedQuantity: Double
    public var usedQuantity: Double
    public var remainingQuantity: Double

    public var id: String { metric }

    public init(
        metric: String,
        includedQuantity: Double,
        usedQuantity: Double,
        remainingQuantity: Double
    ) {
        self.metric = metric
        self.includedQuantity = includedQuantity
        self.usedQuantity = usedQuantity
        self.remainingQuantity = remainingQuantity
    }

    public var displayName: String {
        BackendUsageDisplay.name(for: metric)
    }

    public var usedLabel: String {
        BackendUsageDisplay.quantity(usedQuantity, metric: metric)
    }

    public var includedLabel: String {
        BackendUsageDisplay.quantity(includedQuantity, metric: metric)
    }

    public var remainingLabel: String {
        BackendUsageDisplay.quantity(remainingQuantity, metric: metric)
    }
}

public enum BackendEntitlementMetric {
    public static let audioBytesStored = "audio_bytes_stored"
    public static let transcriptionSeconds = "transcription_seconds"
    public static let workflowRuns = "workflow_runs"
    public static let artifactsGenerated = "artifacts_generated"
}

public enum BackendEntitlementDenialReason: String, Codable, Equatable, Sendable {
    case exhausted
    case missingEntitlement
    case inactivePlan

    public var label: String {
        switch self {
        case .exhausted: "exhausted"
        case .missingEntitlement: "missing"
        case .inactivePlan: "inactive"
        }
    }
}

public struct BackendEntitlementDenial: Codable, Equatable, Sendable {
    public var metric: String
    public var reason: BackendEntitlementDenialReason

    public init(metric: String, reason: BackendEntitlementDenialReason) {
        self.metric = metric
        self.reason = reason
    }
}

public struct BackendAccountUsageSummary: Codable, Equatable, Sendable {
    public var account: BackendAccountSummary
    public var accountPortalURL: URL?
    public var accountDeletionURL: URL?
    public var workspaceID: String
    public var usage: [BackendUsageMetric]
    public var entitlements: [BackendUsageEntitlement]

    public init(
        account: BackendAccountSummary,
        accountPortalURL: URL? = nil,
        accountDeletionURL: URL? = nil,
        workspaceID: String,
        usage: [BackendUsageMetric],
        entitlements: [BackendUsageEntitlement]
    ) {
        self.account = account
        self.accountPortalURL = accountPortalURL
        self.accountDeletionURL = accountDeletionURL
        self.workspaceID = workspaceID
        self.usage = usage
        self.entitlements = entitlements
    }

    public func quantity(for metric: String) -> Double? {
        usage.first { $0.metric == metric }?.quantity
    }

    public func entitlement(for metric: String) -> BackendUsageEntitlement? {
        entitlements.first { $0.metric == metric }
    }

    public func entitlementDenial(for metric: String, requiredQuantity: Double = 1) -> BackendEntitlementDenial? {
        guard account.planStatus == .active || account.planStatus == .trialing else {
            return BackendEntitlementDenial(metric: metric, reason: .inactivePlan)
        }
        guard let entitlement = entitlement(for: metric) else {
            return BackendEntitlementDenial(metric: metric, reason: .missingEntitlement)
        }
        guard entitlement.remainingQuantity >= requiredQuantity else {
            return BackendEntitlementDenial(metric: metric, reason: .exhausted)
        }
        return nil
    }
}

public struct AccountPortalReadiness: Equatable, Sendable {
    public var planLabel: String
    public var actionLabel: String
    public var portalURL: URL?
    public var blockers: [String]

    public var canOpenPortal: Bool {
        portalURL != nil && blockers.isEmpty
    }

    public var blockerText: String {
        blockers.isEmpty ? "Ready" : blockers.joined(separator: " ")
    }

    public static func evaluate(
        summary: BackendAccountUsageSummary?,
        session: BackendAuthenticatedSession?,
        expectedWorkspaceID: String
    ) -> AccountPortalReadiness {
        guard let summary else {
            return AccountPortalReadiness(
                planLabel: "Not loaded",
                actionLabel: "View Plans",
                portalURL: nil,
                blockers: ["Backend account not loaded."]
            )
        }

        let planLabel = "\(summary.account.planName) (\(summary.account.planStatus.label))"
        let actionLabel = summary.account.planName.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("Free") == .orderedSame ? "View Plans" : "Manage Plan"
        let capabilityDecision = BackendCapabilityGate(session: session).decision(
            requiredCapabilities: [.manageAccount],
            expectedWorkspaceID: expectedWorkspaceID
        )
        guard capabilityDecision.isAllowed else {
            return AccountPortalReadiness(
                planLabel: planLabel,
                actionLabel: actionLabel,
                portalURL: nil,
                blockers: capabilityDecision.blockers
            )
        }

        guard summary.workspaceID == expectedWorkspaceID.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return AccountPortalReadiness(
                planLabel: planLabel,
                actionLabel: actionLabel,
                portalURL: nil,
                blockers: ["Backend account belongs to a different workspace."]
            )
        }

        guard let portalURL = summary.accountPortalURL else {
            return AccountPortalReadiness(
                planLabel: planLabel,
                actionLabel: actionLabel,
                portalURL: nil,
                blockers: ["Account portal unavailable."]
            )
        }
        guard isAllowedPortalURL(portalURL) else {
            return AccountPortalReadiness(
                planLabel: planLabel,
                actionLabel: actionLabel,
                portalURL: nil,
                blockers: ["Account portal must use HTTPS."]
            )
        }

        return AccountPortalReadiness(
            planLabel: planLabel,
            actionLabel: actionLabel,
            portalURL: portalURL,
            blockers: []
        )
    }

    private static func isAllowedPortalURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else {
            return false
        }
        if scheme == "https" {
            return true
        }
        return scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)
    }
}

public struct BackendAccountConfiguration: Equatable, Sendable {
    public var baseURL: URL
    public var bearerToken: String
    public var workspaceID: String
    public var usagePath: String

    public init(
        baseURL: URL,
        bearerToken: String,
        workspaceID: String = "",
        usagePath: String = "/v1/usage/summary"
    ) {
        self.baseURL = baseURL
        self.bearerToken = bearerToken
        self.workspaceID = workspaceID
        self.usagePath = usagePath
    }

    public var usageURL: URL {
        let normalizedPath = usagePath.hasPrefix("/") ? String(usagePath.dropFirst()) : usagePath
        return baseURL.appendingPathComponent(normalizedPath)
    }

    public var isConfigured: Bool {
        !bearerToken.isEmpty && !workspaceID.isEmpty
    }
}

public struct BackendAccountUsageClient: Sendable {
    public var configuration: BackendAccountConfiguration
    public var transport: any HTTPRequestTransport

    public init(
        configuration: BackendAccountConfiguration,
        transport: any HTTPRequestTransport = URLSessionHTTPRequestTransport()
    ) {
        self.configuration = configuration
        self.transport = transport
    }

    public func fetchUsageSummary() async throws -> BackendAccountUsageSummary {
        var request = URLRequest(url: configuration.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(configuration.bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue(configuration.workspaceID, forHTTPHeaderField: BackendRequestHeader.workspaceID)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw BackendAccountError.requestFailed("HTTP \(response.statusCode)")
        }

        return try JSONDecoder().decode(BackendAccountUsageSummary.self, from: data)
    }
}

private enum BackendUsageDisplay {
    static func name(for metric: String) -> String {
        switch metric {
        case BackendEntitlementMetric.audioBytesStored: "Audio stored"
        case BackendEntitlementMetric.transcriptionSeconds: "Transcription"
        case BackendEntitlementMetric.workflowRuns: "Workflow runs"
        case BackendEntitlementMetric.artifactsGenerated: "Artifacts"
        default:
            metric
                .split(separator: "_")
                .map { word in word.prefix(1).uppercased() + word.dropFirst() }
                .joined(separator: " ")
        }
    }

    static func quantity(_ value: Double, metric: String) -> String {
        if metric == BackendEntitlementMetric.audioBytesStored {
            return byteQuantity(value)
        }
        if metric == BackendEntitlementMetric.transcriptionSeconds {
            return durationQuantity(value)
        }
        if value.rounded() == value {
            return "\(Int(value))"
        }
        return String(format: "%.1f", value)
    }

    private static func byteQuantity(_ value: Double) -> String {
        let megabytes = value / 1_000_000
        if megabytes >= 1 {
            return String(format: "%.1f MB", megabytes)
        }
        return "\(Int(value.rounded())) bytes"
    }

    private static func durationQuantity(_ value: Double) -> String {
        let minutes = value / 60
        if minutes >= 1 {
            return String(format: "%.1f min", minutes)
        }
        return "\(Int(value.rounded())) sec"
    }
}
