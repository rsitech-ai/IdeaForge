import Foundation

public enum BackendAIError: Error, Equatable {
    case invalidResponse
    case requestFailed(String)
    case missingUploadedAudioObject(String)
    case contractViolation([String])
    case entitlementUnavailable(BackendEntitlementDenial)
    case providerFailure(BackendAIProviderFailure)
}

public struct BackendAIProviderFailure: Equatable, Sendable {
    public var statusCode: Int
    public var code: String
    public var isRetryable: Bool

    public init(statusCode: Int, code: String, isRetryable: Bool) {
        self.statusCode = statusCode
        self.code = code
        self.isRetryable = isRetryable
    }
}

public struct BackendAIConfiguration: Equatable, Sendable {
    public var baseURL: URL
    public var bearerToken: String
    public var workspaceID: String
    public var objectMetadataPath: String
    public var transcriptionPath: String
    public var transcriptionJobStatusPath: String
    public var workflowPath: String
    public var workflowJobStatusPath: String

    public init(
        baseURL: URL,
        bearerToken: String,
        workspaceID: String = "",
        objectMetadataPath: String = "/v1/objects/metadata",
        transcriptionPath: String = "/v1/ai/transcriptions",
        transcriptionJobStatusPath: String = "/v1/ai/transcription-jobs",
        workflowPath: String = "/v1/ai/workflows/run",
        workflowJobStatusPath: String = "/v1/ai/workflow-jobs"
    ) {
        self.baseURL = baseURL
        self.bearerToken = bearerToken
        self.workspaceID = workspaceID
        self.objectMetadataPath = objectMetadataPath
        self.transcriptionPath = transcriptionPath
        self.transcriptionJobStatusPath = transcriptionJobStatusPath
        self.workflowPath = workflowPath
        self.workflowJobStatusPath = workflowJobStatusPath
    }

    public func objectMetadataURL(objectKey: String) -> URL {
        let metadataURL = url(path: objectMetadataPath)
        guard var components = URLComponents(url: metadataURL, resolvingAgainstBaseURL: false) else {
            return metadataURL
        }
        components.queryItems = [URLQueryItem(name: "objectKey", value: objectKey)]
        return components.url ?? metadataURL
    }

    public var transcriptionURL: URL {
        url(path: transcriptionPath)
    }

    public var workflowURL: URL {
        url(path: workflowPath)
    }

    public func transcriptionJobStatusURL(jobID: String) -> URL {
        url(path: transcriptionJobStatusPath).appendingPathComponent(jobID)
    }

    public func workflowJobStatusURL(jobID: String) -> URL {
        url(path: workflowJobStatusPath).appendingPathComponent(jobID)
    }

    public var isConfigured: Bool {
        !bearerToken.isEmpty && !workspaceID.isEmpty
    }

    private func url(path: String) -> URL {
        let normalizedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return baseURL.appendingPathComponent(normalizedPath)
    }
}

public struct BackendTranscriptionService: TranscriptionService {
    public var configuration: BackendAIConfiguration
    public var transport: any HTTPRequestTransport
    public var maxJobPollAttempts: Int
    public var jobPollDelayNanoseconds: UInt64

    public init(
        configuration: BackendAIConfiguration,
        transport: any HTTPRequestTransport = URLSessionHTTPRequestTransport(),
        maxJobPollAttempts: Int = 20,
        jobPollDelayNanoseconds: UInt64 = 500_000_000
    ) {
        self.configuration = configuration
        self.transport = transport
        self.maxJobPollAttempts = max(maxJobPollAttempts, 1)
        self.jobPollDelayNanoseconds = jobPollDelayNanoseconds
    }

    public func transcript(for recording: Recording, hint: String) async throws -> Transcript {
        guard let objectKey = recording.audioObjectKey, !objectKey.isEmpty else {
            throw BackendAIError.missingUploadedAudioObject(recording.id)
        }
        try await validateAudioObjectMetadata(objectKey: objectKey, recording: recording)

        let payload = BackendTranscriptionRequest(
            recordingID: recording.id,
            ideaProjectID: recording.ideaProjectID,
            audioObjectKey: objectKey,
            audioChunks: AudioTranscriptionChunkPlanner.chunks(
                recordingID: recording.id,
                audioObjectKey: objectKey,
                durationSeconds: recording.durationSeconds
            ),
            languageHint: recording.languageHint,
            durationSeconds: recording.durationSeconds,
            markerOffsets: recording.markerOffsets,
            hint: hint
        )
        var request = authenticatedRequest(url: configuration.transcriptionURL, method: "POST")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(payload)
        let (data, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw BackendAIError.providerFailure(
                BackendAIProviderFailureMapper.failure(from: data, response: response)
            )
        }
        if response.statusCode == 202 {
            let job = try decodeTranscriptionJob(from: data)
            return try await pollTranscriptionJob(job, recording: recording)
        }

        return try decodeAndValidateTranscript(from: data, recording: recording)
    }

    private func authenticatedRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(configuration.bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue(configuration.workspaceID, forHTTPHeaderField: BackendRequestHeader.workspaceID)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func validateAudioObjectMetadata(objectKey: String, recording: Recording) async throws {
        let request = authenticatedRequest(
            url: configuration.objectMetadataURL(objectKey: objectKey),
            method: "GET"
        )
        let (data, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw BackendAIError.providerFailure(
                BackendAIProviderFailureMapper.failure(from: data, response: response)
            )
        }

        let metadata = try decodeAudioObjectMetadata(from: data)
        if let failure = metadataFailure(metadata: metadata, objectKey: objectKey, recording: recording) {
            throw BackendAIError.providerFailure(failure)
        }
    }

    private func decodeAudioObjectMetadata(from data: Data) throws -> BackendAudioObjectMetadata {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BackendAudioObjectMetadata.self, from: data)
    }

    private func metadataFailure(
        metadata: BackendAudioObjectMetadata,
        objectKey: String,
        recording: Recording
    ) -> BackendAIProviderFailure? {
        if metadata.objectKey != objectKey {
            return BackendAIProviderFailure(
                statusCode: 409,
                code: "audio_object_metadata_mismatch",
                isRetryable: false
            )
        }
        if let recordingID = metadata.normalizedRecordingID, recordingID != recording.id {
            return BackendAIProviderFailure(
                statusCode: 409,
                code: "audio_object_recording_mismatch",
                isRetryable: false
            )
        }
        if let ideaProjectID = metadata.normalizedIdeaProjectID, ideaProjectID != recording.ideaProjectID {
            return BackendAIProviderFailure(
                statusCode: 409,
                code: "audio_object_project_mismatch",
                isRetryable: false
            )
        }
        if !metadata.isAvailable {
            return BackendAIProviderFailure(
                statusCode: 409,
                code: "audio_object_unavailable",
                isRetryable: true
            )
        }
        if metadata.byteCount <= 0 {
            return BackendAIProviderFailure(
                statusCode: 422,
                code: "audio_object_empty",
                isRetryable: false
            )
        }
        let contentType = metadata.contentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !contentType.isEmpty && !contentType.hasPrefix("audio/") && contentType != "application/octet-stream" {
            return BackendAIProviderFailure(
                statusCode: 422,
                code: "audio_object_invalid_content_type",
                isRetryable: false
            )
        }
        return nil
    }

    private func pollTranscriptionJob(
        _ acceptedJob: BackendTranscriptionJobResponse,
        recording: Recording
    ) async throws -> Transcript {
        let jobID = acceptedJob.jobID
        for attempt in 0..<maxJobPollAttempts {
            let request = authenticatedRequest(
                url: configuration.transcriptionJobStatusURL(jobID: jobID),
                method: "GET"
            )
            let (data, response) = try await transport.data(for: request)
            guard (200..<300).contains(response.statusCode) else {
                throw BackendAIError.providerFailure(
                    BackendAIProviderFailureMapper.failure(from: data, response: response)
                )
            }
            let job = try decodeTranscriptionJob(from: data)
            switch job.status {
            case .queued, .running:
                if attempt + 1 < maxJobPollAttempts, jobPollDelayNanoseconds > 0 {
                    try await Task.sleep(nanoseconds: jobPollDelayNanoseconds)
                }
            case .completed:
                guard let transcript = job.transcript else {
                    throw BackendAIError.contractViolation(["Transcription job completed without transcript."])
                }
                return try validate(transcript: transcript, recording: recording)
            case .failed:
                throw BackendAIError.providerFailure(
                    BackendAIProviderFailure(
                        statusCode: response.statusCode,
                        code: BackendAIProviderFailureMapper.normalizedCode(
                            job.errorCode ?? "transcription_job_failed"
                        ),
                        isRetryable: job.retryable ?? false
                    )
                )
            }
        }

        throw BackendAIError.providerFailure(
            BackendAIProviderFailure(
                statusCode: 202,
                code: "transcription_job_timeout",
                isRetryable: true
            )
        )
    }

    private func decodeAndValidateTranscript(from data: Data, recording: Recording) throws -> Transcript {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let transcript = try decoder.decode(Transcript.self, from: data)
        return try validate(transcript: transcript, recording: recording)
    }

    private func decodeTranscriptionJob(from data: Data) throws -> BackendTranscriptionJobResponse {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BackendTranscriptionJobResponse.self, from: data)
    }

    private func validate(transcript: Transcript, recording: Recording) throws -> Transcript {
        let validation = TranscriptContractValidator.validate(
            transcript: transcript,
            recording: recording
        )
        guard validation.isValid else {
            throw BackendAIError.contractViolation(validation.issues)
        }
        return transcript
    }
}

private struct BackendAudioObjectMetadata: Decodable {
    var objectKey: String
    var recordingID: String?
    var ideaProjectID: String?
    var byteCount: Int
    var contentType: String
    var isAvailable: Bool

    var normalizedRecordingID: String? {
        normalized(recordingID)
    }

    var normalizedIdeaProjectID: String? {
        normalized(ideaProjectID)
    }

    private func normalized(_ value: String?) -> String? {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private enum BackendTranscriptionJobStatus: String, Decodable {
    case queued
    case running
    case completed
    case failed
}

private struct BackendTranscriptionJobResponse: Decodable {
    var jobID: String
    var status: BackendTranscriptionJobStatus
    var transcript: Transcript?
    var error: String?
    var code: String?
    var retryable: Bool?

    var errorCode: String? {
        let raw = (code ?? error ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }
}

public struct TranscriptContractValidation: Equatable, Sendable {
    public var issues: [String]

    public init(issues: [String]) {
        self.issues = issues
    }

    public var isValid: Bool {
        issues.isEmpty
    }
}

public enum TranscriptContractValidator {
    public static func validate(
        transcript: Transcript,
        recording: Recording
    ) -> TranscriptContractValidation {
        var issues: [String] = []
        let duration = max(recording.durationSeconds, 1)

        if transcript.cleanText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("Transcript clean text is empty.")
        }
        if transcript.segments.isEmpty {
            issues.append("Transcript has no segments.")
        }

        var previousEnd = 0
        for (index, segment) in transcript.segments.enumerated() {
            let segmentNumber = index + 1
            if segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append("Transcript segment \(segmentNumber) text is empty.")
            }
            if segment.startSeconds < 0 {
                issues.append("Transcript segment \(segmentNumber) starts before zero.")
            }
            if segment.endSeconds <= segment.startSeconds {
                issues.append("Transcript segment \(segmentNumber) has invalid timing.")
            }
            if segment.endSeconds > duration {
                issues.append("Transcript segment \(segmentNumber) ends after recording duration.")
            }
            if index > 0 && segment.startSeconds < previousEnd {
                issues.append("Transcript segment \(segmentNumber) overlaps or is out of order.")
            }
            previousEnd = max(previousEnd, segment.endSeconds)
        }

        return TranscriptContractValidation(issues: issues)
    }
}

public struct AudioTranscriptionChunk: Codable, Equatable, Sendable {
    public var id: String
    public var audioObjectKey: String
    public var startSeconds: Int
    public var endSeconds: Int

    public init(
        id: String,
        audioObjectKey: String,
        startSeconds: Int,
        endSeconds: Int
    ) {
        self.id = id
        self.audioObjectKey = audioObjectKey
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }
}

public enum AudioTranscriptionChunkPlanner {
    public static let defaultMaxChunkDurationSeconds = 600
    public static let defaultOverlapSeconds = 5

    public static func chunks(
        recordingID: String,
        audioObjectKey: String,
        durationSeconds: Int,
        maxChunkDurationSeconds: Int = defaultMaxChunkDurationSeconds,
        overlapSeconds: Int = defaultOverlapSeconds
    ) -> [AudioTranscriptionChunk] {
        let duration = max(durationSeconds, 1)
        let chunkDuration = max(maxChunkDurationSeconds, 1)
        let overlap = max(0, min(overlapSeconds, chunkDuration - 1))
        var chunks: [AudioTranscriptionChunk] = []
        var startSeconds = 0

        while startSeconds < duration {
            let endSeconds = min(startSeconds + chunkDuration, duration)
            chunks.append(
                AudioTranscriptionChunk(
                    id: "\(recordingID)_chunk_\(chunks.count + 1)",
                    audioObjectKey: audioObjectKey,
                    startSeconds: startSeconds,
                    endSeconds: endSeconds
                )
            )

            guard endSeconds < duration else { break }
            startSeconds = endSeconds - overlap
        }

        return chunks
    }
}

public struct BackendWorkflowExecutionService: WorkflowExecutionService {
    public var configuration: BackendAIConfiguration
    public var transport: any HTTPRequestTransport
    public var maxJobPollAttempts: Int
    public var jobPollDelayNanoseconds: UInt64

    public init(
        configuration: BackendAIConfiguration,
        transport: any HTTPRequestTransport = URLSessionHTTPRequestTransport(),
        maxJobPollAttempts: Int = 20,
        jobPollDelayNanoseconds: UInt64 = 500_000_000
    ) {
        self.configuration = configuration
        self.transport = transport
        self.maxJobPollAttempts = max(maxJobPollAttempts, 1)
        self.jobPollDelayNanoseconds = jobPollDelayNanoseconds
    }

    public func run(template: WorkflowTemplate, project: IdeaProject) async throws -> [Artifact] {
        let payload = BackendWorkflowRequest(template: template, project: project)
        var request = authenticatedRequest(url: configuration.workflowURL, method: "POST")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(payload)
        let (data, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw BackendAIError.providerFailure(
                BackendAIProviderFailureMapper.failure(from: data, response: response)
            )
        }
        if response.statusCode == 202 {
            let job = try decodeWorkflowJob(from: data)
            return try await pollWorkflowJob(job, template: template, project: project)
        }

        let decoded = try decodeWorkflowResponse(from: data)
        return try validate(artifacts: decoded.artifacts, template: template, project: project)
    }

    private func authenticatedRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(configuration.bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue(configuration.workspaceID, forHTTPHeaderField: BackendRequestHeader.workspaceID)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func pollWorkflowJob(
        _ acceptedJob: BackendWorkflowJobResponse,
        template: WorkflowTemplate,
        project: IdeaProject
    ) async throws -> [Artifact] {
        let jobID = acceptedJob.jobID
        for attempt in 0..<maxJobPollAttempts {
            let request = authenticatedRequest(
                url: configuration.workflowJobStatusURL(jobID: jobID),
                method: "GET"
            )
            let (data, response) = try await transport.data(for: request)
            guard (200..<300).contains(response.statusCode) else {
                throw BackendAIError.providerFailure(
                    BackendAIProviderFailureMapper.failure(from: data, response: response)
                )
            }
            let job = try decodeWorkflowJob(from: data)
            switch job.status {
            case .queued, .running:
                if attempt + 1 < maxJobPollAttempts, jobPollDelayNanoseconds > 0 {
                    try await Task.sleep(nanoseconds: jobPollDelayNanoseconds)
                }
            case .completed:
                guard let artifacts = job.artifacts else {
                    throw BackendAIError.contractViolation(["Workflow job completed without artifacts."])
                }
                return try validate(artifacts: artifacts, template: template, project: project)
            case .failed:
                throw BackendAIError.providerFailure(
                    BackendAIProviderFailure(
                        statusCode: response.statusCode,
                        code: BackendAIProviderFailureMapper.normalizedCode(
                            job.errorCode ?? "workflow_job_failed"
                        ),
                        isRetryable: job.retryable ?? false
                    )
                )
            }
        }

        throw BackendAIError.providerFailure(
            BackendAIProviderFailure(
                statusCode: 202,
                code: "workflow_job_timeout",
                isRetryable: true
            )
        )
    }

    private func decodeWorkflowResponse(from data: Data) throws -> BackendWorkflowResponse {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BackendWorkflowResponse.self, from: data)
    }

    private func decodeWorkflowJob(from data: Data) throws -> BackendWorkflowJobResponse {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BackendWorkflowJobResponse.self, from: data)
    }

    private func validate(
        artifacts: [Artifact],
        template: WorkflowTemplate,
        project: IdeaProject
    ) throws -> [Artifact] {
        let validation = WorkflowOutputContractValidator.validate(
            template: template,
            project: project,
            artifacts: artifacts
        )
        guard validation.isValid else {
            throw BackendAIError.contractViolation(validation.issues)
        }
        return artifacts
    }
}

public enum BackendAIServiceFactory {
    public static func services(configuration: BackendAIConfiguration?) -> IdeaForgeServices {
        services(configuration: configuration, privacyMode: .standardCloud)
    }

    public static func services(configuration: BackendAIConfiguration?, privacyMode: PrivacyMode) -> IdeaForgeServices {
        services(
            configuration: configuration,
            privacyMode: privacyMode,
            accountUsageSummary: nil
        )
    }

    public static func services(
        configuration: BackendAIConfiguration?,
        privacyMode: PrivacyMode,
        accountUsageSummary: BackendAccountUsageSummary?
    ) -> IdeaForgeServices {
        guard AIServicePolicy.allowsCloudAI(privacyMode: privacyMode) else {
            return .local
        }
        guard let configuration, configuration.isConfigured else {
            return .local
        }

        let transcriptionService: any TranscriptionService
        if let denial = accountUsageSummary?.entitlementDenial(
            for: BackendEntitlementMetric.transcriptionSeconds
        ) {
            transcriptionService = EntitlementDeniedTranscriptionService(denial: denial)
        } else {
            transcriptionService = BackendTranscriptionService(configuration: configuration)
        }

        let workflowService: any WorkflowExecutionService
        if let denial = accountUsageSummary?.entitlementDenial(
            for: BackendEntitlementMetric.workflowRuns
        ) {
            workflowService = EntitlementDeniedWorkflowExecutionService(denial: denial)
        } else {
            workflowService = BackendWorkflowExecutionService(configuration: configuration)
        }

        return IdeaForgeServices(
            transcription: transcriptionService,
            workflow: workflowService,
            syncQueue: LocalSyncQueueService(),
            export: LocalExportService()
        )
    }
}

public struct EntitlementDeniedTranscriptionService: TranscriptionService {
    public var denial: BackendEntitlementDenial

    public init(denial: BackendEntitlementDenial) {
        self.denial = denial
    }

    public func transcript(for recording: Recording, hint: String) async throws -> Transcript {
        throw BackendAIError.entitlementUnavailable(denial)
    }
}

public struct EntitlementDeniedWorkflowExecutionService: WorkflowExecutionService {
    public var denial: BackendEntitlementDenial

    public init(denial: BackendEntitlementDenial) {
        self.denial = denial
    }

    public func run(template: WorkflowTemplate, project: IdeaProject) async throws -> [Artifact] {
        throw BackendAIError.entitlementUnavailable(denial)
    }
}

private struct BackendTranscriptionRequest: Encodable {
    var recordingID: String
    var ideaProjectID: String
    var audioObjectKey: String
    var audioChunks: [AudioTranscriptionChunk]
    var languageHint: String
    var durationSeconds: Int
    var markerOffsets: [Int]
    var hint: String
}

private struct BackendWorkflowRequest: Encodable {
    var template: WorkflowTemplate
    var project: IdeaProject
    var outputContract: BackendWorkflowOutputContract

    init(template: WorkflowTemplate, project: IdeaProject) {
        self.template = template
        self.project = project
        self.outputContract = BackendWorkflowOutputContract(template: template)
    }
}

private struct BackendWorkflowResponse: Decodable {
    var artifacts: [Artifact]
}

private enum BackendWorkflowJobStatus: String, Decodable {
    case queued
    case running
    case completed
    case failed
}

private struct BackendWorkflowJobResponse: Decodable {
    var jobID: String
    var status: BackendWorkflowJobStatus
    var artifacts: [Artifact]?
    var error: String?
    var code: String?
    var retryable: Bool?

    var errorCode: String? {
        let raw = (code ?? error ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }
}

private struct BackendWorkflowOutputContract: Encodable {
    var version: Int
    var artifactOutputs: [BackendWorkflowArtifactOutputContract]
    var rubricRequirements: [String]
    var structuredOutput: BackendWorkflowStructuredOutput

    init(template: WorkflowTemplate) {
        version = 1
        artifactOutputs = template.outputKinds.map { kind in
            let contract = Self.schemaContract(for: kind, template: template)
            return BackendWorkflowArtifactOutputContract(kind: kind, schemaContract: contract)
        }
        rubricRequirements = Self.rubricRequirements(for: template)
        structuredOutput = BackendWorkflowStructuredOutput(template: template)
    }

    private static func schemaContract(
        for kind: ArtifactKind,
        template: WorkflowTemplate
    ) -> WorkflowSchemaContract? {
        template.schemaContracts.first { $0.outputKind == kind }
            ?? DefaultWorkflows.schemaContracts.first { $0.outputKind == kind }
    }

    private static func rubricRequirements(for template: WorkflowTemplate) -> [String] {
        var requirements = [
            "actionability",
            "evidence",
            "risk_coverage"
        ]
        let needsHandoffSafety = template.steps.contains { $0.kind == .toolAction }
            || template.outputKinds.contains(.codexTaskBundle)
        if needsHandoffSafety {
            requirements.append("handoff_safety")
        }
        return requirements
    }
}

private struct BackendWorkflowArtifactOutputContract: Encodable {
    var kind: ArtifactKind
    var label: String
    var schemaName: String?
    var requiredFields: [BackendWorkflowSchemaFieldContract]

    init(kind: ArtifactKind, schemaContract: WorkflowSchemaContract?) {
        self.kind = kind
        self.label = kind.label
        self.schemaName = schemaContract?.name
        self.requiredFields = schemaContract?
            .fields
            .filter(\.isRequired)
            .map(BackendWorkflowSchemaFieldContract.init(field:)) ?? []
    }
}

private struct BackendWorkflowSchemaFieldContract: Encodable {
    var name: String
    var valueType: String
    var summary: String

    init(field: WorkflowSchemaField) {
        self.name = field.name
        self.valueType = field.valueType
        self.summary = field.summary
    }
}

private struct BackendWorkflowStructuredOutput: Encodable {
    var name: String
    var strict: Bool
    var schema: BackendJSONSchema

    init(template: WorkflowTemplate) {
        name = "ideaforge_workflow_output_v1"
        strict = true
        schema = BackendJSONSchema.object(
            required: ["artifacts"],
            properties: [
                "artifacts": .array(
                    minItems: template.outputKinds.count,
                    items: .artifactItem(allowedKinds: template.outputKinds.map(\.rawValue))
                )
            ]
        )
    }
}

private indirect enum BackendJSONSchema: Encodable {
    case string(description: String? = nil, enumValues: [String]? = nil)
    case integer
    case array(minItems: Int? = nil, items: BackendJSONSchema)
    case object(required: [String], properties: [String: BackendJSONSchema])

    static func artifactItem(allowedKinds: [String]) -> BackendJSONSchema {
        .object(
            required: ["id", "kind", "title", "markdown", "version", "createdBy", "createdAt"],
            properties: [
                "id": .string(description: "Stable artifact identifier."),
                "kind": .string(description: "One of the requested IdeaForge artifact kinds.", enumValues: allowedKinds),
                "title": .string(description: "Human-readable artifact title."),
                "markdown": .string(description: "Markdown artifact body that includes required schema headings."),
                "version": .integer,
                "createdBy": .string(description: "Backend or provider label."),
                "createdAt": .string(description: "ISO-8601 creation timestamp.")
            ]
        )
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case description
        case enumValues = "enum"
        case minItems
        case items
        case required
        case properties
        case additionalProperties
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .string(description, enumValues):
            try container.encode("string", forKey: .type)
            try container.encodeIfPresent(description, forKey: .description)
            try container.encodeIfPresent(enumValues, forKey: .enumValues)
        case .integer:
            try container.encode("integer", forKey: .type)
        case let .array(minItems, items):
            try container.encode("array", forKey: .type)
            try container.encodeIfPresent(minItems, forKey: .minItems)
            try container.encode(items, forKey: .items)
        case let .object(required, properties):
            try container.encode("object", forKey: .type)
            try container.encode(required, forKey: .required)
            try container.encode(properties, forKey: .properties)
            try container.encode(false, forKey: .additionalProperties)
        }
    }
}

private struct BackendAIProviderFailureBody: Decodable {
    var error: String?
    var code: String?
    var retryable: Bool?
}

private enum BackendAIProviderFailureMapper {
    static func failure(from data: Data, response: HTTPURLResponse) -> BackendAIProviderFailure {
        let body = try? JSONDecoder().decode(BackendAIProviderFailureBody.self, from: data)
        let code = normalizedCode(
            body?.code ?? body?.error ?? "backend_ai_request_failed"
        )
        return BackendAIProviderFailure(
            statusCode: response.statusCode,
            code: code,
            isRetryable: body?.retryable ?? retryable(statusCode: response.statusCode, code: code)
        )
    }

    private static func retryable(statusCode: Int, code: String) -> Bool {
        if [408, 409, 425, 429, 500, 502, 503, 504].contains(statusCode) {
            return true
        }
        return code.contains("rate_limit")
            || code.contains("timeout")
            || code.contains("temporarily_unavailable")
            || code.contains("unavailable")
    }

    static func normalizedCode(_ rawCode: String) -> String {
        let lowered = rawCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let scalars = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-" || scalar == "." {
                return Character(scalar)
            }
            return "_"
        }
        let normalized = String(scalars)
            .split(separator: "_")
            .joined(separator: "_")
            .prefix(80)
        return normalized.isEmpty ? "backend_ai_request_failed" : String(normalized)
    }
}
