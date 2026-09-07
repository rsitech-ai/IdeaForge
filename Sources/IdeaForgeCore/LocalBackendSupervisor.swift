import Foundation

public enum LocalBackendDiscoveredEndpointPolicy {
    public static func endpoint(hostName: String, port: Int) -> URL? {
        let normalizedHost = hostName.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !normalizedHost.isEmpty, (1...65_535).contains(port) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = normalizedHost
        components.port = port
        guard let endpoint = components.url,
              BackendEndpointPolicy.allowsLocalBackend(endpoint) else {
            return nil
        }
        return endpoint
    }
}

public enum LocalBackendReadinessFailure: String, Equatable, Sendable {
    case connectivity
    case timeout
    case certificateUntrusted
    case invalidResponse

    public var userFacingMessage: String {
        switch self {
        case .connectivity:
            return "Local Backend is not reachable on this network."
        case .timeout:
            return "Local Backend did not respond in time."
        case .certificateUntrusted:
            return "Local Backend certificate is not trusted on this Mac."
        case .invalidResponse:
            return "Local Backend returned an invalid readiness response."
        }
    }
}

public enum LocalBackendReadiness: Equatable, Sendable {
    case ready
    case unavailable(LocalBackendReadinessFailure)
}

public enum LocalBackendRecoveryResult: Equatable, Sendable {
    case started
    case notInstalled
    case failed
}

public enum LocalBackendSupervisorOutcome: Equatable, Sendable {
    case ready(recovered: Bool)
    case needsSetup
    case unavailable(LocalBackendReadinessFailure)

    public var userFacingMessage: String {
        switch self {
        case .ready(false):
            return "Local Backend is ready."
        case .ready(true):
            return "Local Backend recovered and is ready."
        case .needsSetup:
            return "Local Backend is not installed for this Mac. Open Settings to finish setup."
        case .unavailable(let failure):
            return failure.userFacingMessage
        }
    }
}

public protocol LocalBackendRuntimeControlling: Sendable {
    func checkReadiness(baseURL: URL) async -> LocalBackendReadiness
    func recoverInstalledService() async -> LocalBackendRecoveryResult
}

public struct LocalBackendSupervisor<Runtime: LocalBackendRuntimeControlling>: Sendable {
    public var runtime: Runtime

    public init(runtime: Runtime) {
        self.runtime = runtime
    }

    public func start(baseURL: URL) async -> LocalBackendSupervisorOutcome {
        let firstReadiness = await runtime.checkReadiness(baseURL: baseURL)
        switch firstReadiness {
        case .ready:
            return .ready(recovered: false)
        case .unavailable(.certificateUntrusted), .unavailable(.invalidResponse):
            if case .unavailable(let failure) = firstReadiness {
                return .unavailable(failure)
            }
        case .unavailable(let originalFailure):
            switch await runtime.recoverInstalledService() {
            case .notInstalled:
                return .needsSetup
            case .failed:
                return .unavailable(originalFailure)
            case .started:
                switch await runtime.checkReadiness(baseURL: baseURL) {
                case .ready:
                    return .ready(recovered: true)
                case .unavailable(let failure):
                    return .unavailable(failure)
                }
            }
        }

        return .unavailable(.invalidResponse)
    }
}
