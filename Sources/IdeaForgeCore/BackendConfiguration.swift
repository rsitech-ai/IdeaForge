import Foundation
#if canImport(Security)
import Security
#endif

public struct BackendConnectionSettings: Codable, Equatable, Sendable {
    public var baseURLString: String
    public var authSessionPath: String
    public var uploadPath: String
    public var syncPath: String
    public var objectMetadataPath: String
    public var transcriptionPath: String
    public var transcriptionJobStatusPath: String
    public var workflowPath: String
    public var workflowJobStatusPath: String
    public var usagePath: String
    public var billingReconciliationPath: String
    public var operationsStatusPath: String
    public var backupManifestPath: String
    public var restoreDrillPath: String
    public var operationsMetricsPath: String
    public var pushRegistrationPath: String
    public var workspaceID: String
    public var isEnabled: Bool

    public init(
        baseURLString: String = "",
        authSessionPath: String = "/v1/auth/session",
        uploadPath: String = "/v1/recordings/upload",
        syncPath: String = "/v1/workspace/snapshot",
        objectMetadataPath: String = "/v1/objects/metadata",
        transcriptionPath: String = "/v1/ai/transcriptions",
        transcriptionJobStatusPath: String = "/v1/ai/transcription-jobs",
        workflowPath: String = "/v1/ai/workflows/run",
        workflowJobStatusPath: String = "/v1/ai/workflow-jobs",
        usagePath: String = "/v1/usage/summary",
        billingReconciliationPath: String = "/v1/billing/app-store/reconcile",
        operationsStatusPath: String = "/v1/admin/status",
        backupManifestPath: String = "/v1/admin/backup-manifest",
        restoreDrillPath: String = "/v1/admin/restore-drill",
        operationsMetricsPath: String = "/v1/admin/metrics",
        pushRegistrationPath: String = "/v1/devices/apns",
        workspaceID: String = "",
        isEnabled: Bool = false
    ) {
        self.baseURLString = baseURLString
        self.authSessionPath = authSessionPath
        self.uploadPath = uploadPath
        self.syncPath = syncPath
        self.objectMetadataPath = objectMetadataPath
        self.transcriptionPath = transcriptionPath
        self.transcriptionJobStatusPath = transcriptionJobStatusPath
        self.workflowPath = workflowPath
        self.workflowJobStatusPath = workflowJobStatusPath
        self.usagePath = usagePath
        self.billingReconciliationPath = billingReconciliationPath
        self.operationsStatusPath = operationsStatusPath
        self.backupManifestPath = backupManifestPath
        self.restoreDrillPath = restoreDrillPath
        self.operationsMetricsPath = operationsMetricsPath
        self.pushRegistrationPath = pushRegistrationPath
        self.workspaceID = workspaceID
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case baseURLString
        case authSessionPath
        case uploadPath
        case syncPath
        case objectMetadataPath
        case transcriptionPath
        case transcriptionJobStatusPath
        case workflowPath
        case workflowJobStatusPath
        case usagePath
        case billingReconciliationPath
        case operationsStatusPath
        case backupManifestPath
        case restoreDrillPath
        case operationsMetricsPath
        case pushRegistrationPath
        case workspaceID
        case isEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseURLString = try container.decodeIfPresent(String.self, forKey: .baseURLString) ?? ""
        authSessionPath = try container.decodeIfPresent(String.self, forKey: .authSessionPath) ?? "/v1/auth/session"
        uploadPath = try container.decodeIfPresent(String.self, forKey: .uploadPath) ?? "/v1/recordings/upload"
        syncPath = try container.decodeIfPresent(String.self, forKey: .syncPath) ?? "/v1/workspace/snapshot"
        objectMetadataPath = try container.decodeIfPresent(String.self, forKey: .objectMetadataPath) ?? "/v1/objects/metadata"
        transcriptionPath = try container.decodeIfPresent(String.self, forKey: .transcriptionPath) ?? "/v1/ai/transcriptions"
        transcriptionJobStatusPath = try container.decodeIfPresent(String.self, forKey: .transcriptionJobStatusPath) ?? "/v1/ai/transcription-jobs"
        workflowPath = try container.decodeIfPresent(String.self, forKey: .workflowPath) ?? "/v1/ai/workflows/run"
        workflowJobStatusPath = try container.decodeIfPresent(String.self, forKey: .workflowJobStatusPath) ?? "/v1/ai/workflow-jobs"
        usagePath = try container.decodeIfPresent(String.self, forKey: .usagePath) ?? "/v1/usage/summary"
        billingReconciliationPath = try container.decodeIfPresent(String.self, forKey: .billingReconciliationPath) ?? "/v1/billing/app-store/reconcile"
        operationsStatusPath = try container.decodeIfPresent(String.self, forKey: .operationsStatusPath) ?? "/v1/admin/status"
        backupManifestPath = try container.decodeIfPresent(String.self, forKey: .backupManifestPath) ?? "/v1/admin/backup-manifest"
        restoreDrillPath = try container.decodeIfPresent(String.self, forKey: .restoreDrillPath) ?? "/v1/admin/restore-drill"
        operationsMetricsPath = try container.decodeIfPresent(String.self, forKey: .operationsMetricsPath) ?? "/v1/admin/metrics"
        pushRegistrationPath = try container.decodeIfPresent(String.self, forKey: .pushRegistrationPath) ?? "/v1/devices/apns"
        workspaceID = try container.decodeIfPresent(String.self, forKey: .workspaceID) ?? ""
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
    }

    public var normalizedBaseURL: URL? {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
    }

    public var hasValidBaseURL: Bool {
        normalizedBaseURL.map(BackendEndpointPolicy.allows) ?? false
    }

    public var normalizedAuthSessionPath: String {
        let trimmed = authSessionPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/v1/auth/session" }
        return trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
    }

    public var normalizedUploadPath: String {
        let trimmed = uploadPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/v1/recordings/upload" }
        return trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
    }

    public var normalizedSyncPath: String {
        let trimmed = syncPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/v1/workspace/snapshot" }
        return trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
    }

    public var normalizedObjectMetadataPath: String {
        let trimmed = objectMetadataPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/v1/objects/metadata" }
        return trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
    }

    public var normalizedTranscriptionPath: String {
        let trimmed = transcriptionPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/v1/ai/transcriptions" }
        return trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
    }

    public var normalizedTranscriptionJobStatusPath: String {
        let trimmed = transcriptionJobStatusPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/v1/ai/transcription-jobs" }
        return trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
    }

    public var normalizedWorkflowPath: String {
        let trimmed = workflowPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/v1/ai/workflows/run" }
        return trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
    }

    public var normalizedWorkflowJobStatusPath: String {
        let trimmed = workflowJobStatusPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/v1/ai/workflow-jobs" }
        return trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
    }

    public var normalizedUsagePath: String {
        let trimmed = usagePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/v1/usage/summary" }
        return trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
    }

    public var normalizedBillingReconciliationPath: String {
        let trimmed = billingReconciliationPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/v1/billing/app-store/reconcile" }
        return trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
    }

    public var normalizedOperationsStatusPath: String {
        let trimmed = operationsStatusPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/v1/admin/status" }
        return trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
    }

    public var normalizedBackupManifestPath: String {
        let trimmed = backupManifestPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/v1/admin/backup-manifest" }
        return trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
    }

    public var normalizedRestoreDrillPath: String {
        let trimmed = restoreDrillPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/v1/admin/restore-drill" }
        return trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
    }

    public var normalizedOperationsMetricsPath: String {
        let trimmed = operationsMetricsPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/v1/admin/metrics" }
        return trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
    }

    public var normalizedPushRegistrationPath: String {
        let trimmed = pushRegistrationPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/v1/devices/apns" }
        return trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
    }

    public var normalizedWorkspaceID: String {
        workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum BackendEndpointPolicy {
    public static func allows(_ baseURL: URL) -> Bool {
        guard let scheme = baseURL.scheme?.lowercased(),
              let rawHost = baseURL.host?.lowercased(),
              baseURL.user == nil,
              baseURL.password == nil,
              baseURL.query == nil,
              baseURL.fragment == nil else {
            return false
        }
        if scheme == "https" {
            return true
        }
        guard scheme == "http" else {
            return false
        }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}

public enum BackendRequestHeader {
    public static let workspaceID = "X-IdeaForge-Workspace-ID"
}

public enum BackendConfigurationError: Error, Equatable {
    case invalidBaseURL(String)
    case missingRequiredConfiguration
    case unreadableSettings
    case unwritableSettings
    case keychainUnavailable
    case keychainReadFailed(Int32)
    case keychainWriteFailed(Int32)
    case keychainDeleteFailed(Int32)
    case invalidCredentialData
}

public protocol BackendSettingsStore: Sendable {
    func loadSettings() throws -> BackendConnectionSettings
    func saveSettings(_ settings: BackendConnectionSettings) throws
}

public struct UserDefaultsBackendSettingsStore: BackendSettingsStore {
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
        key: String = "ideaforge.backend.connectionSettings"
    ) {
        defaultsBox = DefaultsBox(defaults: defaults)
        self.key = key
    }

    public func loadSettings() throws -> BackendConnectionSettings {
        let defaults = defaultsBox.defaults
        guard let data = defaults.data(forKey: key) else {
            return BackendConnectionSettings()
        }

        do {
            return try JSONDecoder().decode(BackendConnectionSettings.self, from: data)
        } catch {
            throw BackendConfigurationError.unreadableSettings
        }
    }

    public func saveSettings(_ settings: BackendConnectionSettings) throws {
        do {
            let data = try JSONEncoder().encode(settings)
            defaultsBox.defaults.set(data, forKey: key)
        } catch {
            throw BackendConfigurationError.unwritableSettings
        }
    }
}

public struct InMemoryBackendSettingsStore: BackendSettingsStore {
    private final class Box: @unchecked Sendable {
        var settings: BackendConnectionSettings

        init(settings: BackendConnectionSettings) {
            self.settings = settings
        }
    }

    private let box: Box

    public init(settings: BackendConnectionSettings = BackendConnectionSettings()) {
        box = Box(settings: settings)
    }

    public func loadSettings() throws -> BackendConnectionSettings {
        box.settings
    }

    public func saveSettings(_ settings: BackendConnectionSettings) throws {
        box.settings = settings
    }
}

public protocol BackendCredentialStore: Sendable {
    func loadBearerToken() throws -> String?
    func saveBearerToken(_ token: String) throws
    func clearBearerToken() throws
}

public struct InMemoryBackendCredentialStore: BackendCredentialStore {
    private final class Box: @unchecked Sendable {
        var token: String?

        init(token: String?) {
            self.token = token
        }
    }

    private let box: Box

    public init(token: String? = nil) {
        box = Box(token: token)
    }

    public func loadBearerToken() throws -> String? {
        box.token
    }

    public func saveBearerToken(_ token: String) throws {
        box.token = token
    }

    public func clearBearerToken() throws {
        box.token = nil
    }
}

public struct KeychainBackendCredentialStore: BackendCredentialStore {
    public var service: String
    public var account: String

    public init(
        service: String = "com.s1kor.ideaforge.backend",
        account: String = "bearerToken"
    ) {
        self.service = service
        self.account = account
    }

    public func loadBearerToken() throws -> String? {
        #if canImport(Security)
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw BackendConfigurationError.keychainReadFailed(status)
        }
        guard
            let data = result as? Data,
            let token = String(data: data, encoding: .utf8)
        else {
            throw BackendConfigurationError.invalidCredentialData
        }
        return token
        #else
        throw BackendConfigurationError.keychainUnavailable
        #endif
    }

    public func saveBearerToken(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try clearBearerToken()
            return
        }

        #if canImport(Security)
        var query = baseQuery
        let data = Data(trimmed.utf8)
        var attributes: [String: Any] = [kSecValueData as String: data]
        #if os(iOS) || os(watchOS)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw BackendConfigurationError.keychainWriteFailed(updateStatus)
        }

        query[kSecValueData as String] = data
        #if os(iOS) || os(watchOS)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw BackendConfigurationError.keychainWriteFailed(addStatus)
        }
        #else
        throw BackendConfigurationError.keychainUnavailable
        #endif
    }

    public func clearBearerToken() throws {
        #if canImport(Security)
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw BackendConfigurationError.keychainDeleteFailed(status)
        }
        #else
        throw BackendConfigurationError.keychainUnavailable
        #endif
    }

    #if canImport(Security)
    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
    #endif
}

public struct BackendConfigurationManager: Sendable {
    public var settingsStore: any BackendSettingsStore
    public var credentialStore: any BackendCredentialStore

    public init(
        settingsStore: any BackendSettingsStore,
        credentialStore: any BackendCredentialStore
    ) {
        self.settingsStore = settingsStore
        self.credentialStore = credentialStore
    }

    public func loadSettings() throws -> BackendConnectionSettings {
        try settingsStore.loadSettings()
    }

    public func save(settings: BackendConnectionSettings, bearerToken: String?) throws {
        try settingsStore.saveSettings(settings)
        if let bearerToken {
            try credentialStore.saveBearerToken(bearerToken.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    public func clearCredentials() throws {
        try credentialStore.clearBearerToken()
    }

    public func resolvedAuthConfiguration() throws -> BackendAuthConfiguration? {
        let settings = try settingsStore.loadSettings()
        guard settings.isEnabled else {
            return nil
        }

        guard let baseURL = settings.normalizedBaseURL,
              BackendEndpointPolicy.allows(baseURL) else {
            throw BackendConfigurationError.invalidBaseURL(settings.baseURLString)
        }

        guard
            let token = try credentialStore.loadBearerToken()?.trimmingCharacters(in: .whitespacesAndNewlines),
            !token.isEmpty
        else {
            return nil
        }
        let workspaceID = settings.normalizedWorkspaceID
        guard !workspaceID.isEmpty else {
            return nil
        }

        return BackendAuthConfiguration(
            baseURL: baseURL,
            bearerToken: token,
            workspaceID: workspaceID,
            sessionPath: settings.normalizedAuthSessionPath
        )
    }

    public func resolvedUploadConfiguration() throws -> BackendUploadConfiguration? {
        let settings = try settingsStore.loadSettings()
        guard settings.isEnabled else {
            return nil
        }

        guard let baseURL = settings.normalizedBaseURL,
              BackendEndpointPolicy.allows(baseURL) else {
            throw BackendConfigurationError.invalidBaseURL(settings.baseURLString)
        }

        guard
            let token = try credentialStore.loadBearerToken()?.trimmingCharacters(in: .whitespacesAndNewlines),
            !token.isEmpty
        else {
            return nil
        }
        let workspaceID = settings.normalizedWorkspaceID
        guard !workspaceID.isEmpty else {
            return nil
        }

        return BackendUploadConfiguration(
            baseURL: baseURL,
            bearerToken: token,
            workspaceID: workspaceID,
            uploadPath: settings.normalizedUploadPath
        )
    }

    public func resolvedSyncConfiguration() throws -> BackendSyncConfiguration? {
        let settings = try settingsStore.loadSettings()
        guard settings.isEnabled else {
            return nil
        }

        guard let baseURL = settings.normalizedBaseURL,
              BackendEndpointPolicy.allows(baseURL) else {
            throw BackendConfigurationError.invalidBaseURL(settings.baseURLString)
        }

        guard
            let token = try credentialStore.loadBearerToken()?.trimmingCharacters(in: .whitespacesAndNewlines),
            !token.isEmpty
        else {
            return nil
        }
        let workspaceID = settings.normalizedWorkspaceID
        guard !workspaceID.isEmpty else {
            return nil
        }

        return BackendSyncConfiguration(
            baseURL: baseURL,
            bearerToken: token,
            workspaceID: workspaceID,
            syncPath: settings.normalizedSyncPath
        )
    }

    public func resolvedAIConfiguration() throws -> BackendAIConfiguration? {
        let settings = try settingsStore.loadSettings()
        guard settings.isEnabled else {
            return nil
        }

        guard let baseURL = settings.normalizedBaseURL,
              BackendEndpointPolicy.allows(baseURL) else {
            throw BackendConfigurationError.invalidBaseURL(settings.baseURLString)
        }

        guard
            let token = try credentialStore.loadBearerToken()?.trimmingCharacters(in: .whitespacesAndNewlines),
            !token.isEmpty
        else {
            return nil
        }
        let workspaceID = settings.normalizedWorkspaceID
        guard !workspaceID.isEmpty else {
            return nil
        }

        return BackendAIConfiguration(
            baseURL: baseURL,
            bearerToken: token,
            workspaceID: workspaceID,
            objectMetadataPath: settings.normalizedObjectMetadataPath,
            transcriptionPath: settings.normalizedTranscriptionPath,
            transcriptionJobStatusPath: settings.normalizedTranscriptionJobStatusPath,
            workflowPath: settings.normalizedWorkflowPath,
            workflowJobStatusPath: settings.normalizedWorkflowJobStatusPath
        )
    }

    public func resolvedAccountConfiguration() throws -> BackendAccountConfiguration? {
        let settings = try settingsStore.loadSettings()
        guard settings.isEnabled else {
            return nil
        }

        guard let baseURL = settings.normalizedBaseURL,
              BackendEndpointPolicy.allows(baseURL) else {
            throw BackendConfigurationError.invalidBaseURL(settings.baseURLString)
        }

        guard
            let token = try credentialStore.loadBearerToken()?.trimmingCharacters(in: .whitespacesAndNewlines),
            !token.isEmpty
        else {
            return nil
        }
        let workspaceID = settings.normalizedWorkspaceID
        guard !workspaceID.isEmpty else {
            return nil
        }

        return BackendAccountConfiguration(
            baseURL: baseURL,
            bearerToken: token,
            workspaceID: workspaceID,
            usagePath: settings.normalizedUsagePath
        )
    }

    public func resolvedBillingReconciliationConfiguration() throws -> BackendBillingReconciliationConfiguration? {
        let settings = try settingsStore.loadSettings()
        guard settings.isEnabled else {
            return nil
        }

        guard let baseURL = settings.normalizedBaseURL,
              BackendEndpointPolicy.allows(baseURL) else {
            throw BackendConfigurationError.invalidBaseURL(settings.baseURLString)
        }

        guard
            let token = try credentialStore.loadBearerToken()?.trimmingCharacters(in: .whitespacesAndNewlines),
            !token.isEmpty
        else {
            return nil
        }
        let workspaceID = settings.normalizedWorkspaceID
        guard !workspaceID.isEmpty else {
            return nil
        }

        return BackendBillingReconciliationConfiguration(
            baseURL: baseURL,
            bearerToken: token,
            workspaceID: workspaceID,
            reconciliationPath: settings.normalizedBillingReconciliationPath
        )
    }

    public func resolvedOperationsConfiguration() throws -> BackendOperationsConfiguration? {
        let settings = try settingsStore.loadSettings()
        guard settings.isEnabled else {
            return nil
        }

        guard let baseURL = settings.normalizedBaseURL,
              BackendEndpointPolicy.allows(baseURL) else {
            throw BackendConfigurationError.invalidBaseURL(settings.baseURLString)
        }

        guard
            let token = try credentialStore.loadBearerToken()?.trimmingCharacters(in: .whitespacesAndNewlines),
            !token.isEmpty
        else {
            return nil
        }
        let workspaceID = settings.normalizedWorkspaceID
        guard !workspaceID.isEmpty else {
            return nil
        }

        return BackendOperationsConfiguration(
            baseURL: baseURL,
            bearerToken: token,
            workspaceID: workspaceID,
            statusPath: settings.normalizedOperationsStatusPath,
            backupManifestPath: settings.normalizedBackupManifestPath,
            restoreDrillPath: settings.normalizedRestoreDrillPath,
            metricsPath: settings.normalizedOperationsMetricsPath
        )
    }

    public func resolvedPushRegistrationConfiguration() throws -> BackendPushRegistrationConfiguration? {
        let settings = try settingsStore.loadSettings()
        guard settings.isEnabled else {
            return nil
        }

        guard let baseURL = settings.normalizedBaseURL,
              BackendEndpointPolicy.allows(baseURL) else {
            throw BackendConfigurationError.invalidBaseURL(settings.baseURLString)
        }

        guard
            let token = try credentialStore.loadBearerToken()?.trimmingCharacters(in: .whitespacesAndNewlines),
            !token.isEmpty
        else {
            return nil
        }
        let workspaceID = settings.normalizedWorkspaceID
        guard !workspaceID.isEmpty else {
            return nil
        }

        return BackendPushRegistrationConfiguration(
            baseURL: baseURL,
            bearerToken: token,
            workspaceID: workspaceID,
            registrationPath: settings.normalizedPushRegistrationPath
        )
    }

    public static func production() -> BackendConfigurationManager {
        BackendConfigurationManager(
            settingsStore: UserDefaultsBackendSettingsStore(),
            credentialStore: KeychainBackendCredentialStore()
        )
    }
}
