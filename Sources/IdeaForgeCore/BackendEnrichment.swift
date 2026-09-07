import Foundation
import CryptoKit

public enum BackendEnrichmentError: Error, Equatable, Sendable {
    case invalidConfiguration
    case invalidRequest
    case invalidResponse
    case httpStatus(Int)
    case integrityMismatch
}

public struct BackendEnrichmentConfiguration: Equatable, Sendable {
    public var baseURL: URL
    public var bearerToken: String
    public var workspaceID: String

    public init(baseURL: URL, bearerToken: String, workspaceID: String) {
        self.baseURL = baseURL
        self.bearerToken = bearerToken
        self.workspaceID = workspaceID
    }

    public var isConfigured: Bool {
        !bearerToken.isEmpty && !workspaceID.isEmpty
    }

    func url(path: String) -> URL {
        baseURL.appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path)
    }
}

public struct BackendEnrichmentJob: Codable, Equatable, Sendable {
    public var jobID: String
    public var recordingID: String
    public var ideaProjectID: String
    public var objectKey: String
    public var byteCount: Int
    public var sha256: String
    public var attemptCount: Int
    public var leaseExpiresAt: Date

    public init(
        jobID: String,
        recordingID: String,
        ideaProjectID: String,
        objectKey: String,
        byteCount: Int,
        sha256: String,
        attemptCount: Int,
        leaseExpiresAt: Date
    ) {
        self.jobID = jobID
        self.recordingID = recordingID
        self.ideaProjectID = ideaProjectID
        self.objectKey = objectKey
        self.byteCount = byteCount
        self.sha256 = sha256
        self.attemptCount = attemptCount
        self.leaseExpiresAt = leaseExpiresAt
    }

    var isStructurallyValid: Bool {
        !jobID.isEmpty
            && !recordingID.isEmpty
            && !ideaProjectID.isEmpty
            && objectKey.hasPrefix("recordings/")
            && !objectKey.contains("..")
            && byteCount > 0
            && attemptCount > 0
            && sha256.count == 64
            && sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}

private struct BackendEnrichmentClaimRequest: Encodable {
    var leaseDurationSeconds: Int
}

private struct BackendEnrichmentClaimResponse: Decodable {
    var job: BackendEnrichmentJob?
}

public enum BackendEnrichmentJobStatus: String, Codable, Equatable, Sendable {
    case queued
    case completed
    case failed
}

public struct BackendEnrichmentJobReceipt: Codable, Equatable, Sendable {
    public var jobID: String
    public var status: BackendEnrichmentJobStatus

    public init(jobID: String, status: BackendEnrichmentJobStatus) {
        self.jobID = jobID
        self.status = status
    }
}

private struct BackendEnrichmentCompletionRequest: Encodable {
    var jobID: String
    var workspaceUpdatedAt: String
}

private struct BackendEnrichmentFailureRequest: Encodable {
    var jobID: String
    var diagnosticCode: String
    var retryable: Bool
}

private struct BackendEnrichmentRenewalRequest: Encodable {
    var jobID: String
    var leaseDurationSeconds: Int
}

public struct BackendEnrichmentLeaseReceipt: Codable, Equatable, Sendable {
    public var jobID: String
    public var status: String
    public var leaseExpiresAt: Date

    public init(jobID: String, status: String, leaseExpiresAt: Date) {
        self.jobID = jobID
        self.status = status
        self.leaseExpiresAt = leaseExpiresAt
    }
}

public protocol HTTPFileDownloadTransport: Sendable {
    func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse)
}

public struct URLSessionHTTPFileDownloadTransport: HTTPFileDownloadTransport {
    public init() {}

    public func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        let (temporaryURL, response) = try await URLSession.shared.download(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BackendEnrichmentError.invalidResponse
        }
        return (temporaryURL, httpResponse)
    }
}

public struct BackendEnrichmentClient: Sendable {
    public var configuration: BackendEnrichmentConfiguration
    public var requestTransport: any HTTPRequestTransport
    public var downloadTransport: any HTTPFileDownloadTransport

    public init(
        configuration: BackendEnrichmentConfiguration,
        requestTransport: any HTTPRequestTransport = URLSessionHTTPRequestTransport(),
        downloadTransport: any HTTPFileDownloadTransport = URLSessionHTTPFileDownloadTransport()
    ) {
        self.configuration = configuration
        self.requestTransport = requestTransport
        self.downloadTransport = downloadTransport
    }

    public func claimNextJob(leaseDurationSeconds: Int = 120) async throws -> BackendEnrichmentJob? {
        guard configuration.isConfigured else {
            throw BackendEnrichmentError.invalidConfiguration
        }
        guard (30...300).contains(leaseDurationSeconds) else {
            throw BackendEnrichmentError.invalidRequest
        }
        var request = authorizedRequest(path: "/v1/enrichment/jobs/claim")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            BackendEnrichmentClaimRequest(leaseDurationSeconds: leaseDurationSeconds)
        )
        let (data, response) = try await requestTransport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw BackendEnrichmentError.httpStatus(response.statusCode)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(BackendEnrichmentClaimResponse.self, from: data) else {
            throw BackendEnrichmentError.invalidResponse
        }
        guard decoded.job?.isStructurallyValid ?? true else {
            throw BackendEnrichmentError.invalidResponse
        }
        return decoded.job
    }

    public func stageAudio(
        for job: BackendEnrichmentJob,
        in stagingDirectory: URL
    ) async throws -> URL {
        guard configuration.isConfigured else {
            throw BackendEnrichmentError.invalidConfiguration
        }
        guard job.isStructurallyValid, stagingDirectory.isFileURL else {
            throw BackendEnrichmentError.invalidRequest
        }
        var components = URLComponents(
            url: configuration.url(path: "/v1/recordings/audio"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "recordingID", value: job.recordingID),
            URLQueryItem(name: "objectKey", value: job.objectKey),
        ]
        guard let url = components?.url else {
            throw BackendEnrichmentError.invalidRequest
        }
        var request = authorizedRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")

        let (temporaryURL, response) = try await downloadTransport.download(for: request)
        var shouldRemoveTemporary = true
        defer {
            if shouldRemoveTemporary {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }
        guard (200..<300).contains(response.statusCode) else {
            throw BackendEnrichmentError.httpStatus(response.statusCode)
        }
        guard response.value(forHTTPHeaderField: "X-IdeaForge-Content-SHA256") == job.sha256,
              response.expectedContentLength == Int64(job.byteCount) else {
            throw BackendEnrichmentError.integrityMismatch
        }
        let metadata = try Self.fileMetadata(for: temporaryURL, maximumByteCount: job.byteCount)
        guard metadata.byteCount == job.byteCount, metadata.sha256 == job.sha256 else {
            throw BackendEnrichmentError.integrityMismatch
        }

        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: stagingDirectory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue,
                  (try stagingDirectory.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
                throw BackendEnrichmentError.invalidRequest
            }
        } else {
            try fileManager.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let destination = stagingDirectory
            .appendingPathComponent("enrichment-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        try fileManager.moveItem(at: temporaryURL, to: destination)
        shouldRemoveTemporary = false
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return destination
    }

    public func complete(
        jobID: String,
        workspaceUpdatedAt: Date
    ) async throws -> BackendEnrichmentJobReceipt {
        let trimmedJobID = jobID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedJobID.isEmpty else {
            throw BackendEnrichmentError.invalidRequest
        }
        let payload = BackendEnrichmentCompletionRequest(
            jobID: trimmedJobID,
            workspaceUpdatedAt: ISO8601DateFormatter().string(from: workspaceUpdatedAt)
        )
        let receipt = try await post(
            payload,
            path: "/v1/enrichment/jobs/complete",
            as: BackendEnrichmentJobReceipt.self
        )
        guard receipt.jobID == trimmedJobID, receipt.status == .completed else {
            throw BackendEnrichmentError.invalidResponse
        }
        return receipt
    }

    public func fail(
        jobID: String,
        diagnosticCode: String,
        retryable: Bool
    ) async throws -> BackendEnrichmentJobReceipt {
        let trimmedJobID = jobID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCode = diagnosticCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedJobID.isEmpty,
              !trimmedCode.isEmpty,
              trimmedCode.count <= 64,
              trimmedCode.allSatisfy({ $0.isLowercase || $0.isNumber || $0 == "_" }) else {
            throw BackendEnrichmentError.invalidRequest
        }
        let receipt = try await post(
            BackendEnrichmentFailureRequest(
                jobID: trimmedJobID,
                diagnosticCode: trimmedCode,
                retryable: retryable
            ),
            path: "/v1/enrichment/jobs/fail",
            as: BackendEnrichmentJobReceipt.self
        )
        guard receipt.jobID == trimmedJobID else {
            throw BackendEnrichmentError.invalidResponse
        }
        return receipt
    }

    public func renew(
        jobID: String,
        leaseDurationSeconds: Int = 120
    ) async throws -> BackendEnrichmentLeaseReceipt {
        let trimmedJobID = jobID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedJobID.isEmpty, (30...300).contains(leaseDurationSeconds) else {
            throw BackendEnrichmentError.invalidRequest
        }
        guard configuration.isConfigured else {
            throw BackendEnrichmentError.invalidConfiguration
        }
        var request = authorizedRequest(path: "/v1/enrichment/jobs/renew")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            BackendEnrichmentRenewalRequest(
                jobID: trimmedJobID,
                leaseDurationSeconds: leaseDurationSeconds
            )
        )
        let (data, response) = try await requestTransport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw BackendEnrichmentError.httpStatus(response.statusCode)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let receipt = try? decoder.decode(BackendEnrichmentLeaseReceipt.self, from: data),
              receipt.jobID == trimmedJobID,
              receipt.status == "running" else {
            throw BackendEnrichmentError.invalidResponse
        }
        return receipt
    }

    private func post<Body: Encodable, Response: Decodable>(
        _ body: Body,
        path: String,
        as responseType: Response.Type
    ) async throws -> Response {
        guard configuration.isConfigured else {
            throw BackendEnrichmentError.invalidConfiguration
        }
        var request = authorizedRequest(path: path)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await requestTransport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw BackendEnrichmentError.httpStatus(response.statusCode)
        }
        guard let decoded = try? JSONDecoder().decode(responseType, from: data) else {
            throw BackendEnrichmentError.invalidResponse
        }
        return decoded
    }

    private static func fileMetadata(
        for url: URL,
        maximumByteCount: Int
    ) throws -> (byteCount: Int, sha256: String) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var byteCount = 0
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            byteCount += chunk.count
            guard byteCount <= maximumByteCount else {
                throw BackendEnrichmentError.integrityMismatch
            }
            hasher.update(data: chunk)
        }
        let sha256 = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (byteCount, sha256)
    }

    private func authorizedRequest(path: String) -> URLRequest {
        authorizedRequest(url: configuration.url(path: path))
    }

    private func authorizedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(configuration.bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue(configuration.workspaceID, forHTTPHeaderField: BackendRequestHeader.workspaceID)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}
