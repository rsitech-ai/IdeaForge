import Foundation

public enum BackendBillingError: Error, Equatable {
    case invalidResponse
    case requestFailed(String)
    case invalidTransactionEvidence([String])
}

public enum AppStoreBillingReconciliationReason: String, Codable, Equatable, Sendable {
    case purchase
    case restore
    case refresh
}

public struct AppStoreTransactionEvidence: Codable, Equatable, Sendable {
    public var productID: String
    public var transactionID: String
    public var originalTransactionID: String
    public var appBundleID: String
    public var purchaseDate: Date
    public var expirationDate: Date?
    public var signedTransactionJWS: String?

    public init(
        productID: String,
        transactionID: String,
        originalTransactionID: String,
        appBundleID: String,
        purchaseDate: Date,
        expirationDate: Date?,
        signedTransactionJWS: String?
    ) {
        self.productID = productID
        self.transactionID = transactionID
        self.originalTransactionID = originalTransactionID
        self.appBundleID = appBundleID
        self.purchaseDate = purchaseDate
        self.expirationDate = expirationDate
        self.signedTransactionJWS = signedTransactionJWS
    }
}

public struct AppStoreBillingReconciliationRequest: Codable, Equatable, Sendable {
    public var reason: AppStoreBillingReconciliationReason
    public var transactions: [AppStoreTransactionEvidence]

    public init(
        reason: AppStoreBillingReconciliationReason,
        transactions: [AppStoreTransactionEvidence]
    ) {
        self.reason = reason
        self.transactions = transactions
    }
}

public struct BackendBillingReconciliationConfiguration: Equatable, Sendable {
    public var baseURL: URL
    public var bearerToken: String
    public var workspaceID: String
    public var reconciliationPath: String

    public init(
        baseURL: URL,
        bearerToken: String,
        workspaceID: String = "",
        reconciliationPath: String = "/v1/billing/app-store/reconcile"
    ) {
        self.baseURL = baseURL
        self.bearerToken = bearerToken
        self.workspaceID = workspaceID
        self.reconciliationPath = reconciliationPath
    }

    public var reconciliationURL: URL {
        let normalizedPath = reconciliationPath.hasPrefix("/") ? String(reconciliationPath.dropFirst()) : reconciliationPath
        return baseURL.appendingPathComponent(normalizedPath)
    }

    public var isConfigured: Bool {
        !bearerToken.isEmpty && !workspaceID.isEmpty
    }
}

public struct BackendBillingReconciliationClient: Sendable {
    public var configuration: BackendBillingReconciliationConfiguration
    public var transport: any HTTPRequestTransport

    public init(
        configuration: BackendBillingReconciliationConfiguration,
        transport: any HTTPRequestTransport = URLSessionHTTPRequestTransport()
    ) {
        self.configuration = configuration
        self.transport = transport
    }

    public func reconcileAppStoreEntitlements(
        _ reconciliationRequest: AppStoreBillingReconciliationRequest
    ) async throws -> BackendAccountUsageSummary {
        let validationIssues = AppStoreTransactionEvidenceValidator.validate(reconciliationRequest)
        guard validationIssues.isEmpty else {
            throw BackendBillingError.invalidTransactionEvidence(validationIssues)
        }

        var request = URLRequest(url: configuration.reconciliationURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue(configuration.workspaceID, forHTTPHeaderField: BackendRequestHeader.workspaceID)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(reconciliationRequest)

        let (data, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw BackendBillingError.requestFailed("HTTP \(response.statusCode)")
        }

        return try JSONDecoder().decode(BackendAccountUsageSummary.self, from: data)
    }
}

public enum AppStoreTransactionEvidenceValidator {
    public static func validate(_ request: AppStoreBillingReconciliationRequest) -> [String] {
        guard !request.transactions.isEmpty else {
            return ["transactions must include at least one App Store transaction."]
        }

        return request.transactions.enumerated().flatMap { index, transaction in
            validate(transaction, index: index)
        }
    }

    private static func validate(_ transaction: AppStoreTransactionEvidence, index: Int) -> [String] {
        let prefix = "transactions[\(index)]"
        var issues: [String] = []

        if transaction.productID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("\(prefix).productID is required.")
        }
        if transaction.transactionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("\(prefix).transactionID is required.")
        }
        if transaction.originalTransactionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("\(prefix).originalTransactionID is required.")
        }
        if transaction.appBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("\(prefix).appBundleID is required.")
        }
        issues.append(contentsOf: validateSignedTransactionJWS(transaction, prefix: prefix))

        if let expirationDate = transaction.expirationDate, expirationDate < transaction.purchaseDate {
            issues.append("\(prefix).expirationDate must not be earlier than purchaseDate.")
        }

        return issues
    }

    private static func validateSignedTransactionJWS(_ transaction: AppStoreTransactionEvidence, prefix: String) -> [String] {
        guard let compactJWS = transaction.signedTransactionJWS?.trimmingCharacters(in: .whitespacesAndNewlines),
              !compactJWS.isEmpty else {
            return ["\(prefix).signedTransactionJWS is required."]
        }

        let segments = compactJWS.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3, segments.allSatisfy({ !$0.isEmpty }) else {
            return ["\(prefix).signedTransactionJWS must be JWS Compact Serialization with header, payload, and signature segments."]
        }

        guard let header = decodedBase64URLJSONObject(String(segments[0])) else {
            return ["\(prefix).signedTransactionJWS header must be base64url-encoded JSON."]
        }
        guard let payload = decodedBase64URLJSONObject(String(segments[1])) else {
            return ["\(prefix).signedTransactionJWS payload must be base64url-encoded JSON."]
        }

        var issues: [String] = []
        if header["alg"] as? String != "ES256" {
            issues.append("\(prefix).signedTransactionJWS header alg must be ES256.")
        }
        if stringClaim("productId", in: payload) != transaction.productID {
            issues.append("\(prefix).signedTransactionJWS productId must match productID.")
        }
        if stringClaim("transactionId", in: payload) != transaction.transactionID {
            issues.append("\(prefix).signedTransactionJWS transactionId must match transactionID.")
        }
        if stringClaim("originalTransactionId", in: payload) != transaction.originalTransactionID {
            issues.append("\(prefix).signedTransactionJWS originalTransactionId must match originalTransactionID.")
        }
        if stringClaim("bundleId", in: payload) != transaction.appBundleID {
            issues.append("\(prefix).signedTransactionJWS bundleId must match appBundleID.")
        }
        return issues
    }

    private static func decodedBase64URLJSONObject(_ value: String) -> [String: Any]? {
        guard let data = decodedBase64URLData(value),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func decodedBase64URLData(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        if padding > 0 {
            base64.append(String(repeating: "=", count: padding))
        }
        return Data(base64Encoded: base64)
    }

    private static func stringClaim(_ key: String, in payload: [String: Any]) -> String? {
        if let value = payload[key] as? String {
            return value
        }
        if let value = payload[key] as? Int {
            return String(value)
        }
        if let value = payload[key] as? Int64 {
            return String(value)
        }
        return nil
    }
}
