import Foundation
import StoreKit

public enum CommerceProductID {
    public static let proMonthly = "com.s1kor.ideaforge.pro.monthly"
    public static let proYearly = "com.s1kor.ideaforge.pro.yearly"
    public static let all = [proMonthly, proYearly]
}

public enum CommerceBillingPeriod: String, Codable, Equatable, Sendable {
    case monthly
    case yearly
    case unknown

    public var label: String {
        switch self {
        case .monthly: "Monthly"
        case .yearly: "Yearly"
        case .unknown: "Subscription"
        }
    }
}

public struct CommerceProduct: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var displayName: String
    public var priceLabel: String
    public var billingPeriod: CommerceBillingPeriod

    public init(
        id: String,
        displayName: String,
        priceLabel: String,
        billingPeriod: CommerceBillingPeriod
    ) {
        self.id = id
        self.displayName = displayName
        self.priceLabel = priceLabel
        self.billingPeriod = billingPeriod
    }
}

public enum CommerceProductCatalog {
    public static func orderedProducts(
        _ products: [CommerceProduct],
        preferredOrder: [String] = CommerceProductID.all
    ) -> [CommerceProduct] {
        products.sorted { lhs, rhs in
            let lhsIndex = preferredOrder.firstIndex(of: lhs.id) ?? preferredOrder.count
            let rhsIndex = preferredOrder.firstIndex(of: rhs.id) ?? preferredOrder.count
            if lhsIndex == rhsIndex {
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
            return lhsIndex < rhsIndex
        }
    }
}

public enum CommercePurchaseResult: Equatable, Sendable {
    case purchased(activeProductID: String)
    case pending
    case userCancelled
}

public struct CommerceRestoreResult: Equatable, Sendable {
    public var activeProductIDs: [String]

    public var hasActiveSubscription: Bool {
        !activeProductIDs.isEmpty
    }

    public init(activeProductIDs: [String]) {
        self.activeProductIDs = Self.normalizedProductIDs(activeProductIDs)
    }

    private static func normalizedProductIDs(_ productIDs: [String]) -> [String] {
        var seen = Set<String>()
        let unique = productIDs.filter { productID in
            guard !seen.contains(productID) else {
                return false
            }
            seen.insert(productID)
            return true
        }
        return CommerceProductID.all.filter(unique.contains)
            + unique.filter { !CommerceProductID.all.contains($0) }.sorted()
    }
}

public enum CommerceServiceError: Error, Equatable, Sendable {
    case productUnavailable(String)
    case unverifiedTransaction
}

public protocol CommerceServicing: Sendable {
    func loadProducts(productIDs: [String]) async throws -> [CommerceProduct]
    func activeProductIDs(productIDs: [String]) async throws -> [String]
    func activeTransactionEvidence(productIDs: [String]) async throws -> [AppStoreTransactionEvidence]
    func purchase(productID: String) async throws -> CommercePurchaseResult
    func restorePurchases(productIDs: [String]) async throws -> CommerceRestoreResult
}

public actor CommerceFixtureService: CommerceServicing {
    private let products: [CommerceProduct]
    private var activeProductIDsValue: [String]

    public init(products: [CommerceProduct], activeProductIDs: [String] = []) {
        self.products = CommerceProductCatalog.orderedProducts(products)
        self.activeProductIDsValue = CommerceRestoreResult(activeProductIDs: activeProductIDs).activeProductIDs
    }

    public func loadProducts(productIDs: [String]) async throws -> [CommerceProduct] {
        let productIDSet = Set(productIDs)
        return products.filter { productIDSet.contains($0.id) }
    }

    public func activeProductIDs(productIDs: [String]) async throws -> [String] {
        let productIDSet = Set(productIDs)
        return activeProductIDsValue.filter { productIDSet.contains($0) }
    }

    public func activeTransactionEvidence(productIDs: [String]) async throws -> [AppStoreTransactionEvidence] {
        try await activeProductIDs(productIDs: productIDs).map { productID in
            AppStoreTransactionEvidence(
                productID: productID,
                transactionID: "fixture-\(productID)",
                originalTransactionID: "fixture-\(productID)",
                appBundleID: "com.s1kor.ideaforge.fixture",
                purchaseDate: Date(timeIntervalSince1970: 0),
                expirationDate: nil,
                signedTransactionJWS: Self.fixtureSignedTransactionJWS(
                    productID: productID,
                    transactionID: "fixture-\(productID)",
                    originalTransactionID: "fixture-\(productID)",
                    appBundleID: "com.s1kor.ideaforge.fixture"
                )
            )
        }
    }

    public func purchase(productID: String) async throws -> CommercePurchaseResult {
        guard products.contains(where: { $0.id == productID }) else {
            throw CommerceServiceError.productUnavailable(productID)
        }
        activeProductIDsValue = CommerceRestoreResult(activeProductIDs: activeProductIDsValue + [productID]).activeProductIDs
        return .purchased(activeProductID: productID)
    }

    public func restorePurchases(productIDs: [String]) async throws -> CommerceRestoreResult {
        let activeProductIDs = try await activeProductIDs(productIDs: productIDs)
        return CommerceRestoreResult(activeProductIDs: activeProductIDs)
    }

    private static func fixtureSignedTransactionJWS(
        productID: String,
        transactionID: String,
        originalTransactionID: String,
        appBundleID: String
    ) -> String {
        let header: [String: Any] = ["alg": "ES256", "typ": "JWT"]
        let payload: [String: Any] = [
            "productId": productID,
            "transactionId": transactionID,
            "originalTransactionId": originalTransactionID,
            "bundleId": appBundleID
        ]
        return [
            base64URLEncodedJSON(header),
            base64URLEncodedJSON(payload),
            base64URLEncodedData(Data("fixture-signature".utf8))
        ].joined(separator: ".")
    }

    private static func base64URLEncodedJSON(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return base64URLEncodedData(data)
    }

    private static func base64URLEncodedData(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public actor StoreKitCommerceService: CommerceServicing {
    public init() {}

    public func loadProducts(productIDs: [String]) async throws -> [CommerceProduct] {
        let products = try await Product.products(for: productIDs)
        return CommerceProductCatalog.orderedProducts(products.map(Self.commerceProduct(from:)))
    }

    public func activeProductIDs(productIDs: [String]) async throws -> [String] {
        let productIDSet = Set(productIDs)
        var activeProductIDs: [String] = []
        for await verificationResult in Transaction.currentEntitlements {
            let transaction = try Self.verified(verificationResult)
            guard productIDSet.contains(transaction.productID) else {
                continue
            }
            activeProductIDs.append(transaction.productID)
        }
        return CommerceRestoreResult(activeProductIDs: activeProductIDs).activeProductIDs
    }

    public func activeTransactionEvidence(productIDs: [String]) async throws -> [AppStoreTransactionEvidence] {
        let productIDSet = Set(productIDs)
        var evidence: [AppStoreTransactionEvidence] = []
        for await verificationResult in Transaction.currentEntitlements {
            let signedTransactionJWS = verificationResult.jwsRepresentation
            let transaction = try Self.verified(verificationResult)
            guard productIDSet.contains(transaction.productID) else {
                continue
            }
            evidence.append(AppStoreTransactionEvidence(transaction: transaction, signedTransactionJWS: signedTransactionJWS))
        }
        return evidence
    }

    public func purchase(productID: String) async throws -> CommercePurchaseResult {
        guard let product = try await Product.products(for: [productID]).first else {
            throw CommerceServiceError.productUnavailable(productID)
        }

        let purchaseResult = try await product.purchase()
        switch purchaseResult {
        case .success(let verificationResult):
            let transaction = try Self.verified(verificationResult)
            await transaction.finish()
            return .purchased(activeProductID: transaction.productID)
        case .pending:
            return .pending
        case .userCancelled:
            return .userCancelled
        @unknown default:
            return .pending
        }
    }

    public func restorePurchases(productIDs: [String]) async throws -> CommerceRestoreResult {
        try await AppStore.sync()
        return try await CommerceRestoreResult(activeProductIDs: activeProductIDs(productIDs: productIDs))
    }

    private static func commerceProduct(from product: Product) -> CommerceProduct {
        CommerceProduct(
            id: product.id,
            displayName: product.displayName,
            priceLabel: product.displayPrice,
            billingPeriod: billingPeriod(for: product)
        )
    }

    private static func billingPeriod(for product: Product) -> CommerceBillingPeriod {
        guard let subscriptionPeriod = product.subscription?.subscriptionPeriod else {
            return CommerceProductID.proYearly == product.id ? .yearly : CommerceProductID.proMonthly == product.id ? .monthly : .unknown
        }
        switch subscriptionPeriod.unit {
        case .month:
            return .monthly
        case .year:
            return .yearly
        default:
            return .unknown
        }
    }

    private static func verified<T>(_ verificationResult: VerificationResult<T>) throws -> T {
        switch verificationResult {
        case .verified(let value):
            return value
        case .unverified:
            throw CommerceServiceError.unverifiedTransaction
        }
    }
}

@available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, visionOS 1.0, *)
extension AppStoreTransactionEvidence {
    public init(transaction: Transaction, signedTransactionJWS: String) {
        self.init(
            productID: transaction.productID,
            transactionID: String(transaction.id),
            originalTransactionID: String(transaction.originalID),
            appBundleID: transaction.appBundleID,
            purchaseDate: transaction.purchaseDate,
            expirationDate: transaction.expirationDate,
            signedTransactionJWS: signedTransactionJWS
        )
    }
}

public enum CommerceReadinessBlocker: String, Codable, Equatable, Sendable {
    case backendAccountMissing
    case storeKitProductsMissing
    case activeSubscriptionMissing
    case accountPortalMissing
    case subscriptionManagementUnavailable

    public var label: String {
        switch self {
        case .backendAccountMissing:
            "Backend account not loaded"
        case .storeKitProductsMissing:
            "StoreKit products not loaded"
        case .activeSubscriptionMissing:
            "No active subscription"
        case .accountPortalMissing:
            "Account portal unavailable"
        case .subscriptionManagementUnavailable:
            "Subscription management unavailable"
        }
    }
}

public struct CommerceReadiness: Equatable, Sendable {
    public var products: [CommerceProduct]
    public var planLabel: String
    public var accountPortalURL: URL?
    public var accountDeletionURL: URL?
    public var purchaseBlockers: [CommerceReadinessBlocker]
    public var restoreBlockers: [CommerceReadinessBlocker]
    public var manageSubscriptionBlockers: [CommerceReadinessBlocker]
    public var accountDeletionBlockers: [CommerceReadinessBlocker]

    public var canPurchase: Bool { purchaseBlockers.isEmpty }
    public var canRestore: Bool { restoreBlockers.isEmpty }
    public var canManageSubscription: Bool { manageSubscriptionBlockers.isEmpty }
    public var canRequestAccountDeletion: Bool { accountDeletionBlockers.isEmpty }

    public static func evaluate(
        accountUsageSummary: BackendAccountUsageSummary?,
        storeKitProducts: [CommerceProduct],
        activeProductIDs: [String],
        accountPortalURL: URL?,
        accountDeletionURL: URL? = nil,
        canOpenSubscriptionManagement: Bool = false
    ) -> CommerceReadiness {
        let hasBackendAccount = accountUsageSummary != nil
        let hasStoreKitProducts = !storeKitProducts.isEmpty
        let hasActiveSubscription = !activeProductIDs.isEmpty
        let hasAccountDeletionPortal = accountDeletionURL != nil

        var purchaseBlockers: [CommerceReadinessBlocker] = []
        if !hasBackendAccount {
            purchaseBlockers.append(.backendAccountMissing)
        }
        if !hasStoreKitProducts {
            purchaseBlockers.append(.storeKitProductsMissing)
        }

        var restoreBlockers: [CommerceReadinessBlocker] = []
        if !hasStoreKitProducts {
            restoreBlockers.append(.storeKitProductsMissing)
        }

        var manageSubscriptionBlockers: [CommerceReadinessBlocker] = []
        if !hasBackendAccount {
            manageSubscriptionBlockers.append(.backendAccountMissing)
        }
        if !hasActiveSubscription {
            manageSubscriptionBlockers.append(.activeSubscriptionMissing)
        }
        if !canOpenSubscriptionManagement {
            manageSubscriptionBlockers.append(.subscriptionManagementUnavailable)
        }

        var accountDeletionBlockers: [CommerceReadinessBlocker] = []
        if !hasBackendAccount {
            accountDeletionBlockers.append(.backendAccountMissing)
        }
        if !hasAccountDeletionPortal {
            accountDeletionBlockers.append(.accountPortalMissing)
        }

        return CommerceReadiness(
            products: storeKitProducts,
            planLabel: Self.planLabel(for: accountUsageSummary),
            accountPortalURL: accountPortalURL,
            accountDeletionURL: accountDeletionURL,
            purchaseBlockers: purchaseBlockers,
            restoreBlockers: restoreBlockers,
            manageSubscriptionBlockers: manageSubscriptionBlockers,
            accountDeletionBlockers: accountDeletionBlockers
        )
    }

    public func blockerSummary(for blockers: [CommerceReadinessBlocker]) -> String {
        if blockers.isEmpty {
            return "Ready"
        }
        return blockers.map(\.label).joined(separator: ", ")
    }

    private static func planLabel(for summary: BackendAccountUsageSummary?) -> String {
        guard let summary else {
            return "Not loaded"
        }
        return "\(summary.account.planName) (\(summary.account.planStatus.label))"
    }
}
