import Foundation

public enum IntegrationProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case github
    case linear
    case jira
    case notion
    case codexLauncher

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .github: "GitHub"
        case .linear: "Linear"
        case .jira: "Jira"
        case .notion: "Notion"
        case .codexLauncher: "Codex Launcher"
        }
    }

    public var symbolName: String {
        switch self {
        case .github: "chevron.left.forwardslash.chevron.right"
        case .linear: "line.3.horizontal.decrease.circle"
        case .jira: "checklist"
        case .notion: "square.grid.3x3"
        case .codexLauncher: "terminal"
        }
    }

    public var defaultRequiredScopes: [String] {
        switch self {
        case .github:
            ["repo:read", "issues:write"]
        case .linear:
            ["issues:read", "issues:write"]
        case .jira:
            ["read:jira-work", "write:jira-work"]
        case .notion:
            ["pages:read", "pages:write"]
        case .codexLauncher:
            []
        }
    }
}

public enum IntegrationCredentialStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case notConfigured
    case configured
    case expired

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .notConfigured: "Not configured"
        case .configured: "Configured"
        case .expired: "Expired"
        }
    }
}

public enum IntegrationReadinessStatus: String, Codable, Equatable, Sendable {
    case disabled
    case needsCredential
    case expiredCredential
    case missingScopes
    case approvalRequired
    case readyForReviewedAction

    public var label: String {
        switch self {
        case .disabled: "Disabled"
        case .needsCredential: "Needs credential"
        case .expiredCredential: "Credential expired"
        case .missingScopes: "Needs scopes"
        case .approvalRequired: "Approval required"
        case .readyForReviewedAction: "Ready with review"
        }
    }
}

public enum IntegrationActionKind: String, Codable, Sendable {
    case remoteWrite
    case codexLaunch

    public var label: String {
        switch self {
        case .remoteWrite: "Remote write"
        case .codexLaunch: "Codex launch"
        }
    }
}

public struct IntegrationProviderSettings: Codable, Equatable, Identifiable, Sendable {
    public var id: String { provider.id }
    public var provider: IntegrationProvider
    public var isEnabled: Bool
    public var displayName: String
    public var requiredScopes: [String]
    public var approvedScopes: [String]
    public var credentialStatus: IntegrationCredentialStatus
    public var allowsExternalActions: Bool

    public init(
        provider: IntegrationProvider,
        isEnabled: Bool = false,
        displayName: String = "",
        requiredScopes: [String]? = nil,
        approvedScopes: [String] = [],
        credentialStatus: IntegrationCredentialStatus = .notConfigured,
        allowsExternalActions: Bool = false
    ) {
        self.provider = provider
        self.isEnabled = isEnabled
        self.displayName = displayName
        self.requiredScopes = requiredScopes ?? provider.defaultRequiredScopes
        self.approvedScopes = approvedScopes
        self.credentialStatus = credentialStatus
        self.allowsExternalActions = allowsExternalActions
    }

    public var normalizedApprovedScopes: Set<String> {
        Set(approvedScopes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
    }

    public var missingScopes: [String] {
        let approved = normalizedApprovedScopes
        return requiredScopes.filter { !approved.contains($0) }
    }
}

public struct IntegrationReadinessItem: Equatable, Identifiable, Sendable {
    public var id: String { settings.id }
    public var settings: IntegrationProviderSettings
    public var status: IntegrationReadinessStatus
    public var blocker: String?

    public init(
        settings: IntegrationProviderSettings,
        status: IntegrationReadinessStatus,
        blocker: String?
    ) {
        self.settings = settings
        self.status = status
        self.blocker = blocker
    }
}

public struct IntegrationReadinessReport: Equatable, Sendable {
    public var items: [IntegrationReadinessItem]

    public init(items: [IntegrationReadinessItem]) {
        self.items = items
    }

    public var readyCount: Int {
        items.filter { $0.status == .readyForReviewedAction }.count
    }

    public var blockerCount: Int {
        items.filter { $0.status != .disabled && $0.status != .readyForReviewedAction }.count
    }

    public func item(for provider: IntegrationProvider) -> IntegrationReadinessItem? {
        items.first { $0.settings.provider == provider }
    }
}

public struct IntegrationActionGate: Equatable, Sendable {
    public var provider: IntegrationProvider
    public var action: IntegrationActionKind
    public var isAllowed: Bool
    public var reason: String

    public init(
        provider: IntegrationProvider,
        action: IntegrationActionKind,
        isAllowed: Bool,
        reason: String
    ) {
        self.provider = provider
        self.action = action
        self.isAllowed = isAllowed
        self.reason = reason
    }
}

public struct IntegrationSettings: Codable, Equatable, Sendable {
    public var providerSettings: [IntegrationProviderSettings]

    private enum CodingKeys: String, CodingKey {
        case providerSettings
    }

    public init(providerSettings: [IntegrationProviderSettings] = IntegrationSettings.defaultProviderSettings) {
        var merged = providerSettings
        let defaultsByProvider = Dictionary(uniqueKeysWithValues: IntegrationSettings.defaultProviderSettings.map { ($0.provider, $0) })
        for provider in IntegrationProvider.allCases where !merged.contains(where: { $0.provider == provider }) {
            merged.append(defaultsByProvider[provider] ?? IntegrationProviderSettings(provider: provider))
        }
        self.providerSettings = merged.sorted { $0.provider.rawValue < $1.provider.rawValue }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedProviderSettings = try container.decode([IntegrationProviderSettings].self, forKey: .providerSettings)
        self.init(providerSettings: decodedProviderSettings)
    }

    public static var defaultProviderSettings: [IntegrationProviderSettings] {
        IntegrationProvider.allCases.map { provider in
            IntegrationProviderSettings(
                provider: provider,
                credentialStatus: provider == .codexLauncher ? .configured : .notConfigured
            )
        }
    }

    public static var defaults: IntegrationSettings {
        IntegrationSettings()
    }

    public func settings(for provider: IntegrationProvider) -> IntegrationProviderSettings {
        providerSettings.first { $0.provider == provider } ?? IntegrationProviderSettings(provider: provider)
    }

    public mutating func update(_ settings: IntegrationProviderSettings) {
        if let index = providerSettings.firstIndex(where: { $0.provider == settings.provider }) {
            providerSettings[index] = settings
        } else {
            providerSettings.append(settings)
        }
        providerSettings.sort { $0.provider.rawValue < $1.provider.rawValue }
    }

    public func readinessReport() -> IntegrationReadinessReport {
        IntegrationReadinessReport(
            items: providerSettings.map { settings in
                if !settings.isEnabled {
                    return IntegrationReadinessItem(settings: settings, status: .disabled, blocker: nil)
                }

                switch settings.credentialStatus {
                case .notConfigured:
                    return IntegrationReadinessItem(
                        settings: settings,
                        status: .needsCredential,
                        blocker: "\(settings.provider.label) needs a credential before actions can run."
                    )
                case .expired:
                    return IntegrationReadinessItem(
                        settings: settings,
                        status: .expiredCredential,
                        blocker: "\(settings.provider.label) credential is expired."
                    )
                case .configured:
                    break
                }

                let missingScopes = settings.missingScopes
                if !missingScopes.isEmpty {
                    return IntegrationReadinessItem(
                        settings: settings,
                        status: .missingScopes,
                        blocker: "Approve scopes: \(missingScopes.joined(separator: ", "))."
                    )
                }

                if !settings.allowsExternalActions {
                    return IntegrationReadinessItem(
                        settings: settings,
                        status: .approvalRequired,
                        blocker: "External actions require explicit operator approval."
                    )
                }

                return IntegrationReadinessItem(
                    settings: settings,
                    status: .readyForReviewedAction,
                    blocker: nil
                )
            }
        )
    }

    public func actionGate(provider: IntegrationProvider, action: IntegrationActionKind) -> IntegrationActionGate {
        let settings = settings(for: provider)
        guard settings.isEnabled else {
            return IntegrationActionGate(
                provider: provider,
                action: action,
                isAllowed: false,
                reason: "\(provider.label) is disabled."
            )
        }
        guard settings.credentialStatus == .configured else {
            return IntegrationActionGate(
                provider: provider,
                action: action,
                isAllowed: false,
                reason: "\(provider.label) credential is not ready."
            )
        }
        guard settings.missingScopes.isEmpty else {
            return IntegrationActionGate(
                provider: provider,
                action: action,
                isAllowed: false,
                reason: "\(provider.label) is missing required scopes."
            )
        }
        guard settings.allowsExternalActions else {
            return IntegrationActionGate(
                provider: provider,
                action: action,
                isAllowed: false,
                reason: "External actions require explicit operator approval."
            )
        }
        return IntegrationActionGate(
            provider: provider,
            action: action,
            isAllowed: true,
            reason: "\(action.label) is allowed after review."
        )
    }
}

public enum IntegrationSettingsError: Error, Equatable {
    case unreadableSettings
    case unwritableSettings
}

public protocol IntegrationSettingsStore: Sendable {
    func loadIntegrationSettings() throws -> IntegrationSettings
    func saveIntegrationSettings(_ settings: IntegrationSettings) throws
}

public struct UserDefaultsIntegrationSettingsStore: IntegrationSettingsStore {
    private final class DefaultsBox: @unchecked Sendable {
        let defaults: UserDefaults

        init(defaults: UserDefaults) {
            self.defaults = defaults
        }
    }

    private let defaultsBox: DefaultsBox
    private let key: String

    public init(
        defaults: UserDefaults = .standard,
        key: String = "ideaforge.integration.settings"
    ) {
        defaultsBox = DefaultsBox(defaults: defaults)
        self.key = key
    }

    public func loadIntegrationSettings() throws -> IntegrationSettings {
        let defaults = defaultsBox.defaults
        guard let data = defaults.data(forKey: key) else {
            return .defaults
        }

        do {
            return try JSONDecoder().decode(IntegrationSettings.self, from: data)
        } catch {
            throw IntegrationSettingsError.unreadableSettings
        }
    }

    public func saveIntegrationSettings(_ settings: IntegrationSettings) throws {
        do {
            let data = try JSONEncoder().encode(settings)
            defaultsBox.defaults.set(data, forKey: key)
        } catch {
            throw IntegrationSettingsError.unwritableSettings
        }
    }
}

public struct InMemoryIntegrationSettingsStore: IntegrationSettingsStore {
    private final class Box: @unchecked Sendable {
        var settings: IntegrationSettings

        init(settings: IntegrationSettings) {
            self.settings = settings
        }
    }

    private let box: Box

    public init(settings: IntegrationSettings = .defaults) {
        box = Box(settings: settings)
    }

    public func loadIntegrationSettings() throws -> IntegrationSettings {
        box.settings
    }

    public func saveIntegrationSettings(_ settings: IntegrationSettings) throws {
        box.settings = settings
    }
}

public struct IntegrationSettingsManager: Sendable {
    public var settingsStore: any IntegrationSettingsStore

    public init(settingsStore: any IntegrationSettingsStore) {
        self.settingsStore = settingsStore
    }

    public func loadSettings() throws -> IntegrationSettings {
        try settingsStore.loadIntegrationSettings()
    }

    public func save(settings: IntegrationSettings) throws {
        try settingsStore.saveIntegrationSettings(settings)
    }

    public static func production() -> IntegrationSettingsManager {
        IntegrationSettingsManager(settingsStore: UserDefaultsIntegrationSettingsStore())
    }
}
