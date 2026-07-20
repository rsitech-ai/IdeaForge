import Foundation

public enum RemoteNotificationAlertAuthorizationState: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
}

public struct RemoteNotificationRegistrationPlan: Equatable, Sendable {
    public var shouldRequestAlertAuthorization: Bool
    public var shouldRegisterForRemoteNotifications: Bool

    public init(
        shouldRequestAlertAuthorization: Bool,
        shouldRegisterForRemoteNotifications: Bool
    ) {
        self.shouldRequestAlertAuthorization = shouldRequestAlertAuthorization
        self.shouldRegisterForRemoteNotifications = shouldRegisterForRemoteNotifications
    }
}

public enum RemoteNotificationRegistrationPolicy {
    public static func plan(
        for state: RemoteNotificationAlertAuthorizationState
    ) -> RemoteNotificationRegistrationPlan {
        RemoteNotificationRegistrationPlan(
            shouldRequestAlertAuthorization: state == .notDetermined,
            shouldRegisterForRemoteNotifications: true
        )
    }
}

public enum BackendPushRegistrationError: Error, Equatable {
    case emptyDeviceToken
    case invalidDeviceToken
    case invalidResponse
    case requestFailed(String)
}

public enum PushNotificationRegistrationBlocker: String, Equatable, Sendable {
    case notificationPermissionDenied = "notification_permission_denied"
    case deviceTokenMissing = "device_token_missing"
    case missingConfiguration = "missing_configuration"
    case capabilityGate = "capability_gate"
    case invalidConfiguration = "invalid_configuration"
    case requestFailed = "request_failed"

    public var userFacingMessage: String {
        switch self {
        case .notificationPermissionDenied:
            "Enable notifications in Settings before push sync can be registered."
        case .deviceTokenMissing:
            "APNs has not returned a device token for this iPhone yet."
        case .missingConfiguration:
            "Push sync needs backend settings, workspace ID, and a token."
        case .capabilityGate:
            "Push sync needs a validated backend session with notification registration capability."
        case .invalidConfiguration:
            "Backend URL is invalid. Fix Account settings before registering push sync."
        case .requestFailed:
            "Push sync registration failed. Check backend status and try again."
        }
    }
}

public enum PushNotificationRegistrationResult: Equatable, Sendable {
    case registered(BackendPushDeviceRegistrationReceipt)
    case skipped(PushNotificationRegistrationBlocker, String)
}

public struct BackendAPNSDeviceToken: Codable, Equatable, Sendable {
    public var hexValue: String

    public init(data: Data) throws {
        guard !data.isEmpty else {
            throw BackendPushRegistrationError.emptyDeviceToken
        }
        self.hexValue = data.map { String(format: "%02x", $0) }.joined()
    }

    public init(hexString: String) throws {
        let normalized = hexString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else {
            throw BackendPushRegistrationError.emptyDeviceToken
        }
        guard normalized.count.isMultiple(of: 2),
              normalized.allSatisfy({ $0.isHexDigit })
        else {
            throw BackendPushRegistrationError.invalidDeviceToken
        }
        self.hexValue = normalized
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(hexString: container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hexValue)
    }
}

public enum BackendPushPlatform: String, Codable, Equatable, Sendable {
    case iOS = "ios"
    case watchOS = "watchos"
    case macOS = "macos"
}

public enum BackendPushEnvironment: String, Codable, Equatable, Sendable {
    case sandbox
    case production

    /// APNs environment matching the running binary: debug builds receive
    /// sandbox device tokens, release (TestFlight/App Store) builds receive
    /// production tokens.
    public static var current: BackendPushEnvironment {
        #if DEBUG
        return .sandbox
        #else
        return .production
        #endif
    }
}

public enum BackendPushTopic: String, Codable, CaseIterable, Equatable, Identifiable, Sendable {
    case workspaceSync = "workspace_sync"
    case recordingProcessing = "recording_processing"
    case account = "account"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .workspaceSync: "Workspace sync"
        case .recordingProcessing: "Recording processing"
        case .account: "Account"
        }
    }
}

public struct BackendPushDeviceRegistrationRequest: Codable, Equatable, Sendable {
    public var apnsDeviceToken: BackendAPNSDeviceToken
    public var environment: BackendPushEnvironment
    public var platform: BackendPushPlatform
    public var bundleID: String
    public var appVersion: String
    public var topics: [BackendPushTopic]

    public init(
        apnsDeviceToken: BackendAPNSDeviceToken,
        environment: BackendPushEnvironment,
        platform: BackendPushPlatform,
        bundleID: String,
        appVersion: String,
        topics: [BackendPushTopic]
    ) {
        self.apnsDeviceToken = apnsDeviceToken
        self.environment = environment
        self.platform = platform
        self.bundleID = bundleID
        self.appVersion = appVersion
        self.topics = topics
    }
}

public struct BackendPushDeviceRegistrationReceipt: Codable, Equatable, Sendable {
    public var workspaceID: String
    public var deviceID: String
    public var tokenFingerprint: String
    public var environment: BackendPushEnvironment
    public var platform: BackendPushPlatform
    public var enabledTopics: [BackendPushTopic]
    public var registeredAt: String

    public init(
        workspaceID: String,
        deviceID: String,
        tokenFingerprint: String,
        environment: BackendPushEnvironment,
        platform: BackendPushPlatform,
        enabledTopics: [BackendPushTopic],
        registeredAt: String
    ) {
        self.workspaceID = workspaceID
        self.deviceID = deviceID
        self.tokenFingerprint = tokenFingerprint
        self.environment = environment
        self.platform = platform
        self.enabledTopics = enabledTopics
        self.registeredAt = registeredAt
    }
}

public struct BackendPushRegistrationConfiguration: Equatable, Sendable {
    public var baseURL: URL
    public var bearerToken: String
    public var workspaceID: String
    public var registrationPath: String

    public init(
        baseURL: URL,
        bearerToken: String,
        workspaceID: String = "",
        registrationPath: String = "/v1/devices/apns"
    ) {
        self.baseURL = baseURL
        self.bearerToken = bearerToken
        self.workspaceID = workspaceID
        self.registrationPath = registrationPath
    }

    public var registrationURL: URL {
        let normalizedPath = registrationPath.hasPrefix("/") ? String(registrationPath.dropFirst()) : registrationPath
        return baseURL.appendingPathComponent(normalizedPath)
    }

    public var isConfigured: Bool {
        !bearerToken.isEmpty && !workspaceID.isEmpty
    }
}

public struct BackendPushRegistrationClient: Sendable {
    public var configuration: BackendPushRegistrationConfiguration
    public var transport: any HTTPRequestTransport

    public init(
        configuration: BackendPushRegistrationConfiguration,
        transport: any HTTPRequestTransport = URLSessionHTTPRequestTransport()
    ) {
        self.configuration = configuration
        self.transport = transport
    }

    public func registerDevice(_ registration: BackendPushDeviceRegistrationRequest) async throws -> BackendPushDeviceRegistrationReceipt {
        var request = URLRequest(url: configuration.registrationURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue(configuration.workspaceID, forHTTPHeaderField: BackendRequestHeader.workspaceID)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(registration)

        let (data, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw BackendPushRegistrationError.requestFailed("HTTP \(response.statusCode)")
        }

        do {
            return try JSONDecoder().decode(BackendPushDeviceRegistrationReceipt.self, from: data)
        } catch {
            throw BackendPushRegistrationError.invalidResponse
        }
    }
}

public struct ConfiguredPushNotificationRegistrationProcessor: Sendable {
    public var backendConfigurationManager: BackendConfigurationManager
    public var authTransport: any HTTPRequestTransport
    public var registrationTransport: any HTTPRequestTransport

    public init(
        backendConfigurationManager: BackendConfigurationManager,
        authTransport: any HTTPRequestTransport = URLSessionHTTPRequestTransport(),
        registrationTransport: any HTTPRequestTransport = URLSessionHTTPRequestTransport()
    ) {
        self.backendConfigurationManager = backendConfigurationManager
        self.authTransport = authTransport
        self.registrationTransport = registrationTransport
    }

    public func registerDevice(_ registration: BackendPushDeviceRegistrationRequest) async -> PushNotificationRegistrationResult {
        do {
            guard let authConfiguration = try backendConfigurationManager.resolvedAuthConfiguration() else {
                return .skipped(
                    .missingConfiguration,
                    PushNotificationRegistrationBlocker.missingConfiguration.userFacingMessage
                )
            }

            let session = try await BackendAuthSessionClient(
                configuration: authConfiguration,
                transport: authTransport
            )
            .validateSession()
            let capabilityDecision = BackendCapabilityGate(session: session).decision(
                requiredCapabilities: [.syncWorkspace, .registerPushNotifications],
                expectedWorkspaceID: authConfiguration.workspaceID
            )
            guard capabilityDecision.isAllowed else {
                return .skipped(
                    .capabilityGate,
                    capabilityDecision.blockerSummary.isEmpty
                        ? PushNotificationRegistrationBlocker.capabilityGate.userFacingMessage
                        : capabilityDecision.blockerSummary
                )
            }

            guard let registrationConfiguration = try backendConfigurationManager.resolvedPushRegistrationConfiguration() else {
                return .skipped(
                    .missingConfiguration,
                    PushNotificationRegistrationBlocker.missingConfiguration.userFacingMessage
                )
            }

            let receipt = try await BackendPushRegistrationClient(
                configuration: registrationConfiguration,
                transport: registrationTransport
            )
            .registerDevice(registration)
            return .registered(receipt)
        } catch BackendConfigurationError.invalidBaseURL {
            return .skipped(
                .invalidConfiguration,
                PushNotificationRegistrationBlocker.invalidConfiguration.userFacingMessage
            )
        } catch {
            return .skipped(
                .requestFailed,
                PushNotificationRegistrationBlocker.requestFailed.userFacingMessage
            )
        }
    }
}

public enum RemotePushNotificationBlocker: String, Equatable, Sendable {
    case notSilentPush = "not_silent_push"
    case missingEnvelope = "missing_envelope"
    case missingWorkspaceID = "missing_workspace_id"
    case missingTopic = "missing_topic"
    case unknownTopic = "unknown_topic"
}

public struct RemotePushNotificationTrigger: Equatable, Sendable {
    public var workspaceID: String
    public var topics: [BackendPushTopic]
    public var remoteUpdatedAt: String?

    public init(
        workspaceID: String,
        topics: [BackendPushTopic],
        remoteUpdatedAt: String? = nil
    ) {
        self.workspaceID = workspaceID
        self.topics = topics
        self.remoteUpdatedAt = remoteUpdatedAt
    }

    public var shouldProcessUploads: Bool {
        topics.contains(.recordingProcessing) || topics.contains(.workspaceSync)
    }

    public var shouldPublishLocalSnapshot: Bool {
        topics.contains(.recordingProcessing) || topics.contains(.workspaceSync)
    }

    public var shouldRefreshWorkspace: Bool {
        topics.contains(.workspaceSync)
    }
}

public enum RemotePushNotificationPayloadDecision: Equatable, Sendable {
    case accepted(RemotePushNotificationTrigger)
    case ignored(RemotePushNotificationBlocker)
}

public enum RemotePushNotificationPayloadParser {
    private enum TopicParseResult {
        case success([BackendPushTopic])
        case failure(RemotePushNotificationBlocker)
    }

    public static func parse(userInfo: [AnyHashable: Any]) -> RemotePushNotificationPayloadDecision {
        guard
            let aps = dictionaryValue(userInfo["aps"]),
            silentPushValue(aps["content-available"])
        else {
            return .ignored(.notSilentPush)
        }

        guard let envelope = dictionaryValue(userInfo["ideaforge"]) else {
            return .ignored(.missingEnvelope)
        }

        guard
            let workspaceID = stringValue(envelope["workspaceID"]),
            !workspaceID.isEmpty
        else {
            return .ignored(.missingWorkspaceID)
        }

        switch topics(from: envelope) {
        case .success(let topics):
            guard !topics.isEmpty else {
                return .ignored(.missingTopic)
            }
            let remoteUpdatedAt = stringValue(envelope["remoteUpdatedAt"])
            return .accepted(
                RemotePushNotificationTrigger(
                    workspaceID: workspaceID,
                    topics: topics,
                    remoteUpdatedAt: remoteUpdatedAt
                )
            )
        case .failure(let blocker):
            return .ignored(blocker)
        }
    }

    private static func dictionaryValue(_ value: Any?) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            return dictionary
        }
        if let dictionary = value as? [AnyHashable: Any] {
            var normalized: [String: Any] = [:]
            for (key, value) in dictionary {
                guard let key = key as? String else { continue }
                normalized[key] = value
            }
            return normalized
        }
        return nil
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func silentPushValue(_ value: Any?) -> Bool {
        if let number = value as? NSNumber {
            return number.intValue == 1
        }
        if let intValue = value as? Int {
            return intValue == 1
        }
        return false
    }

    private static func topics(from envelope: [String: Any]) -> TopicParseResult {
        let rawTopics: [String]
        if let topics = envelope["topics"] as? [String] {
            rawTopics = topics
        } else if let topic = stringValue(envelope["topic"]) {
            rawTopics = [topic]
        } else if let event = stringValue(envelope["event"]) {
            rawTopics = [event]
        } else {
            return .failure(.missingTopic)
        }

        var parsedTopics: [BackendPushTopic] = []
        for rawTopic in rawTopics {
            let normalized = rawTopic.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }
            guard let topic = BackendPushTopic(rawValue: normalized) else {
                return .failure(.unknownTopic)
            }
            if !parsedTopics.contains(topic) {
                parsedTopics.append(topic)
            }
        }
        return .success(parsedTopics)
    }
}
