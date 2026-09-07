import Foundation
import XCTest
@testable import IdeaForgeCore

final class WorkspaceSyncFailureDiagnosticTests: XCTestCase {
    func testConnectivityFailuresRemainDistinctAndActionable() {
        assertDiagnostic(
            URLError(.cannotFindHost),
            category: .hostLookup,
            contains: "could not be found"
        )
        assertDiagnostic(
            URLError(.networkConnectionLost),
            category: .connectionLost,
            contains: "interrupted"
        )
        assertDiagnostic(
            URLError(.timedOut),
            category: .timeout,
            contains: "did not respond in time"
        )
        assertDiagnostic(
            URLError(.serverCertificateUntrusted),
            category: .certificateTrust,
            contains: "certificate"
        )
    }

    func testHTTPFailuresSeparateAuthenticationPermissionAndAvailability() {
        assertDiagnostic(
            BackendSyncError.httpStatus(401),
            category: .authentication,
            contains: "pair or sign in again"
        )
        assertDiagnostic(
            BackendSyncError.httpStatus(403),
            category: .permission,
            contains: "workspace access"
        )
        assertDiagnostic(
            BackendSyncError.httpStatus(503),
            category: .backendUnavailable,
            contains: "temporarily unavailable"
        )
        assertDiagnostic(
            BackendAuthError.unauthorized,
            category: .authentication,
            contains: "pair or sign in again"
        )
        assertDiagnostic(
            BackendAuthError.invalidResponse,
            category: .invalidResponse,
            contains: "unreadable response"
        )
    }

    func testRevisionAndPayloadFailuresDoNotCollapseToUnknown() {
        assertDiagnostic(
            BackendSyncError.revisionConflict,
            category: .revisionConflict,
            contains: "changed on another device"
        )
        assertDiagnostic(
            BackendSyncError.invalidResponse,
            category: .invalidResponse,
            contains: "unreadable response"
        )
    }

    func testMalformedFetchPayloadBecomesTypedInvalidResponse() async throws {
        let client = BackendWorkspaceSyncClient(
            configuration: testConfiguration,
            transport: MalformedSyncResponseTransport(data: Data("not-json".utf8))
        )

        do {
            _ = try await client.fetchWorkspaceSnapshot(since: nil)
            XCTFail("Expected malformed workspace payload to be rejected")
        } catch {
            XCTAssertEqual(error as? BackendSyncError, .invalidResponse)
        }
    }

    func testMalformedPublishReceiptBecomesTypedInvalidResponse() async throws {
        let client = BackendWorkspaceSyncClient(
            configuration: testConfiguration,
            transport: MalformedSyncResponseTransport(data: Data("{}".utf8))
        )

        do {
            _ = try await client.pushWorkspaceSnapshot(WorkspaceState.seed(), baseRemoteUpdatedAt: nil)
            XCTFail("Expected malformed publish receipt to be rejected")
        } catch {
            XCTAssertEqual(error as? BackendSyncError, .invalidResponse)
        }
    }

    private var testConfiguration: BackendSyncConfiguration {
        BackendSyncConfiguration(
            baseURL: URL(string: "https://api.example.test")!,
            bearerToken: "sync-token",
            workspaceID: "workspace_alpha"
        )
    }

    private func assertDiagnostic(
        _ error: Error,
        category: WorkspaceSyncFailureCategory,
        contains expectedText: String
    ) {
        let diagnostic = WorkspaceSyncFailureDiagnostic.classify(error)
        XCTAssertEqual(diagnostic.category, category)
        XCTAssertTrue(diagnostic.userFacingMessage.localizedCaseInsensitiveContains(expectedText))
        XCTAssertFalse(diagnostic.receiptTitle.isEmpty)
    }
}

private actor MalformedSyncResponseTransport: HTTPRequestTransport {
    let data: Data

    init(data: Data) {
        self.data = data
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }
}
