import Foundation
import XCTest
@testable import IdeaForgeCore

final class BackendEnrichmentClientTests: XCTestCase {
    func testBackendSessionDecodesRecordingProcessingCapability() throws {
        let data = Data(
            #"{"userID":"local_operator","workspaceID":"workspace_rsi","account":{"id":"local_account","planName":"Local","planStatus":"active"},"capabilities":["sync_workspace","upload_recordings","process_recordings"]}"#.utf8
        )

        let session = try JSONDecoder().decode(BackendAuthenticatedSession.self, from: data)

        XCTAssertTrue(session.hasCapability(.processRecordings))
        XCTAssertEqual(BackendAccountCapability.processRecordings.label, "Process recordings")
    }

    func testConfigurationManagerResolvesEnrichmentFromPairedBackendSettings() throws {
        let manager = BackendConfigurationManager(
            settingsStore: InMemoryBackendSettingsStore(
                settings: BackendConnectionSettings(
                    baseURLString: "https://ideaforge.local:9443",
                    workspaceID: "workspace_rsi",
                    isEnabled: true,
                    connectionKind: .localBackend
                )
            ),
            credentialStore: InMemoryBackendCredentialStore(token: "secret-token")
        )

        let configuration = try XCTUnwrap(manager.resolvedEnrichmentConfiguration())

        XCTAssertEqual(configuration.baseURL, URL(string: "https://ideaforge.local:9443")!)
        XCTAssertEqual(configuration.workspaceID, "workspace_rsi")
        XCTAssertEqual(configuration.bearerToken, "secret-token")
    }

    func testClaimBuildsAuthorizedRequestAndDecodesBoundedJob() async throws {
        let responseBody = """
        {
          "job": {
            "jobID": "job_enrichment_1",
            "recordingID": "rec_watch_1",
            "ideaProjectID": "idea_watch_1",
            "objectKey": "recordings/object-1.m4a",
            "byteCount": 18,
            "sha256": "9b7fb4882c258f53cabb5c9f422fd172c062af30420f4d4e118a45104e9da2e6",
            "attemptCount": 1,
            "leaseExpiresAt": "2026-08-28T12:02:00Z"
          }
        }
        """.data(using: .utf8)!
        let transport = EnrichmentRequestTransport(
            responseData: responseBody,
            statusCode: 200
        )
        let client = BackendEnrichmentClient(
            configuration: BackendEnrichmentConfiguration(
                baseURL: URL(string: "https://ideaforge.local:9443")!,
                bearerToken: "secret-token",
                workspaceID: "workspace_rsi"
            ),
            requestTransport: transport
        )

        let job = try await client.claimNextJob(leaseDurationSeconds: 120)

        XCTAssertEqual(
            job,
            BackendEnrichmentJob(
                jobID: "job_enrichment_1",
                recordingID: "rec_watch_1",
                ideaProjectID: "idea_watch_1",
                objectKey: "recordings/object-1.m4a",
                byteCount: 18,
                sha256: "9b7fb4882c258f53cabb5c9f422fd172c062af30420f4d4e118a45104e9da2e6",
                attemptCount: 1,
                leaseExpiresAt: ISO8601DateFormatter().date(from: "2026-08-28T12:02:00Z")!
            )
        )
        let capturedRequest = await transport.lastRequest
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/v1/enrichment/jobs/claim")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: BackendRequestHeader.workspaceID),
            "workspace_rsi"
        )
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Int],
            ["leaseDurationSeconds": 120]
        )
    }

    func testStageAudioDownloadsToPrivateDirectoryAndVerifiesIntegrity() async throws {
        let audio = Data("valid-audio".utf8)
        let sha256 = "401d5d8b9ab6251eadb9c431c1ac137eeceb2996de51967918692a87c220b397"
        let downloadTransport = EnrichmentDownloadTransport(
            responseData: audio,
            statusCode: 200,
            headers: [
                "Content-Type": "application/octet-stream",
                "Content-Length": "11",
                "X-IdeaForge-Content-SHA256": sha256,
            ]
        )
        let client = BackendEnrichmentClient(
            configuration: BackendEnrichmentConfiguration(
                baseURL: URL(string: "https://ideaforge.local:9443")!,
                bearerToken: "secret-token",
                workspaceID: "workspace_rsi"
            ),
            requestTransport: EnrichmentRequestTransport(responseData: Data(), statusCode: 200),
            downloadTransport: downloadTransport
        )
        let job = BackendEnrichmentJob(
            jobID: "job_download",
            recordingID: "rec_download",
            ideaProjectID: "idea_download",
            objectKey: "recordings/object-download.m4a",
            byteCount: audio.count,
            sha256: sha256,
            attemptCount: 1,
            leaseExpiresAt: Date().addingTimeInterval(120)
        )
        let stagingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IdeaForgeEnrichmentTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }

        let stagedURL = try await client.stageAudio(for: job, in: stagingDirectory)

        XCTAssertEqual(try Data(contentsOf: stagedURL), audio)
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: stagedURL.path)[.posixPermissions] as? NSNumber)?.intValue,
            0o600
        )
        let capturedRequest = await downloadTransport.lastRequest
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url?.path, "/v1/recordings/audio")
        XCTAssertEqual(
            URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
                .queryItems?
                .reduce(into: [String: String]()) { $0[$1.name] = $1.value },
            ["recordingID": "rec_download", "objectKey": "recordings/object-download.m4a"]
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
    }

    func testStageAudioRejectsDigestMismatchWithoutLeavingFile() async throws {
        let downloadTransport = EnrichmentDownloadTransport(
            responseData: Data("tampered".utf8),
            statusCode: 200,
            headers: [
                "Content-Type": "application/octet-stream",
                "Content-Length": "8",
                "X-IdeaForge-Content-SHA256": "401d5d8b9ab6251eadb9c431c1ac137eeceb2996de51967918692a87c220b397",
            ]
        )
        let client = BackendEnrichmentClient(
            configuration: BackendEnrichmentConfiguration(
                baseURL: URL(string: "https://ideaforge.local:9443")!,
                bearerToken: "secret-token",
                workspaceID: "workspace_rsi"
            ),
            requestTransport: EnrichmentRequestTransport(responseData: Data(), statusCode: 200),
            downloadTransport: downloadTransport
        )
        let job = BackendEnrichmentJob(
            jobID: "job_tampered",
            recordingID: "rec_tampered",
            ideaProjectID: "idea_tampered",
            objectKey: "recordings/object-tampered.m4a",
            byteCount: 8,
            sha256: "401d5d8b9ab6251eadb9c431c1ac137eeceb2996de51967918692a87c220b397",
            attemptCount: 1,
            leaseExpiresAt: Date().addingTimeInterval(120)
        )
        let stagingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IdeaForgeEnrichmentTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }

        do {
            _ = try await client.stageAudio(for: job, in: stagingDirectory)
            XCTFail("Expected integrity mismatch")
        } catch {
            XCTAssertEqual(error as? BackendEnrichmentError, .integrityMismatch)
        }
        XCTAssertEqual(
            (try? FileManager.default.contentsOfDirectory(at: stagingDirectory, includingPropertiesForKeys: nil)) ?? [],
            []
        )
    }

    func testCompleteAndFailSendOnlyBoundedLeaseResults() async throws {
        let completedTransport = EnrichmentRequestTransport(
            responseData: Data(#"{"jobID":"job_complete","status":"completed"}"#.utf8),
            statusCode: 200
        )
        let configuration = BackendEnrichmentConfiguration(
            baseURL: URL(string: "https://ideaforge.local:9443")!,
            bearerToken: "secret-token",
            workspaceID: "workspace_rsi"
        )
        let completedClient = BackendEnrichmentClient(
            configuration: configuration,
            requestTransport: completedTransport
        )
        let updatedAt = ISO8601DateFormatter().date(from: "2026-08-28T12:05:00Z")!

        let completed = try await completedClient.complete(
            jobID: "job_complete",
            workspaceUpdatedAt: updatedAt
        )

        XCTAssertEqual(completed, BackendEnrichmentJobReceipt(jobID: "job_complete", status: .completed))
        let capturedCompleteRequest = await completedTransport.capturedRequest()
        let completeRequest = try XCTUnwrap(capturedCompleteRequest)
        XCTAssertEqual(completeRequest.url?.path, "/v1/enrichment/jobs/complete")
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: try XCTUnwrap(completeRequest.httpBody)) as? [String: String],
            ["jobID": "job_complete", "workspaceUpdatedAt": "2026-08-28T12:05:00Z"]
        )

        let failedTransport = EnrichmentRequestTransport(
            responseData: Data(#"{"jobID":"job_fail","status":"queued"}"#.utf8),
            statusCode: 200
        )
        let failedClient = BackendEnrichmentClient(
            configuration: configuration,
            requestTransport: failedTransport
        )
        let failed = try await failedClient.fail(
            jobID: "job_fail",
            diagnosticCode: "speech_permission_required",
            retryable: true
        )

        XCTAssertEqual(failed, BackendEnrichmentJobReceipt(jobID: "job_fail", status: .queued))
        let capturedFailRequest = await failedTransport.capturedRequest()
        let failRequest = try XCTUnwrap(capturedFailRequest)
        XCTAssertEqual(failRequest.url?.path, "/v1/enrichment/jobs/fail")
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: try XCTUnwrap(failRequest.httpBody)) as? NSDictionary,
            [
                "jobID": "job_fail",
                "diagnosticCode": "speech_permission_required",
                "retryable": true,
            ] as NSDictionary
        )
    }

    func testRenewExtendsClaimUsingBoundedDuration() async throws {
        let response = Data(
            #"{"jobID":"job_renew","status":"running","leaseExpiresAt":"2026-08-28T12:06:00Z"}"#.utf8
        )
        let transport = EnrichmentRequestTransport(responseData: response, statusCode: 200)
        let client = BackendEnrichmentClient(
            configuration: BackendEnrichmentConfiguration(
                baseURL: URL(string: "https://ideaforge.local:9443")!,
                bearerToken: "secret-token",
                workspaceID: "workspace_rsi"
            ),
            requestTransport: transport
        )

        let receipt = try await client.renew(jobID: "job_renew", leaseDurationSeconds: 120)

        XCTAssertEqual(receipt.jobID, "job_renew")
        XCTAssertEqual(
            receipt.leaseExpiresAt,
            ISO8601DateFormatter().date(from: "2026-08-28T12:06:00Z")
        )
        let captured = await transport.capturedRequest()
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.url?.path, "/v1/enrichment/jobs/renew")
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? NSDictionary,
            ["jobID": "job_renew", "leaseDurationSeconds": 120] as NSDictionary
        )
    }
}

private actor EnrichmentRequestTransport: HTTPRequestTransport {
    private let responseData: Data
    private let statusCode: Int
    private(set) var lastRequest: URLRequest?

    init(responseData: Data, statusCode: Int) {
        self.responseData = responseData
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lastRequest = request
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (responseData, response)
    }

    func capturedRequest() -> URLRequest? {
        lastRequest
    }
}

private actor EnrichmentDownloadTransport: HTTPFileDownloadTransport {
    private let responseData: Data
    private let statusCode: Int
    private let headers: [String: String]
    private(set) var lastRequest: URLRequest?

    init(responseData: Data, statusCode: Int, headers: [String: String]) {
        self.responseData = responseData
        self.statusCode = statusCode
        self.headers = headers
    }

    func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        lastRequest = request
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("IdeaForgeDownloadFixture-\(UUID().uuidString)")
        try responseData.write(to: temporaryURL, options: .atomic)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: headers
        )!
        return (temporaryURL, response)
    }
}
