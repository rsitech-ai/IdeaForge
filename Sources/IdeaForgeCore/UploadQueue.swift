import Foundation
import CryptoKit

public enum UploadJobStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case queued
    case uploading
    case uploaded
    case waitingForRetry
    case permanentlyFailed

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .queued: "Queued"
        case .uploading: "Uploading"
        case .uploaded: "Uploaded"
        case .waitingForRetry: "Retry scheduled"
        case .permanentlyFailed: "Failed"
        }
    }
}

public enum UploadFailureCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case configuration
    case authentication
    case connectivity
    case entitlement
    case server
    case uploadError = "upload_error"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .configuration: "Configuration"
        case .authentication: "Authentication"
        case .connectivity: "Connectivity"
        case .entitlement: "Entitlement"
        case .server: "Server"
        case .uploadError: "Upload error"
        }
    }

    public static func classify(_ error: Error) -> UploadFailureCategory {
        if error is BackendConfigurationError || error is LocalAudioObjectStoreError {
            return .configuration
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .userAuthenticationRequired,
                 .userCancelledAuthentication,
                 .clientCertificateRejected,
                 .clientCertificateRequired:
                return .authentication
            case .timedOut,
                 .cannotFindHost,
                 .cannotConnectToHost,
                 .networkConnectionLost,
                 .dnsLookupFailed,
                 .notConnectedToInternet,
                 .internationalRoamingOff,
                 .callIsActive,
                 .dataNotAllowed,
                 .secureConnectionFailed,
                 .backgroundSessionWasDisconnected:
                return .connectivity
            default:
                return .uploadError
            }
        }

        guard let clientError = error as? UploadClientError else {
            return .uploadError
        }
        switch clientError {
        case .missingLocalFile, .configurationUnavailable:
            return .configuration
        case .invalidResponse:
            return .server
        case .httpStatus(let statusCode):
            return category(forHTTPStatus: statusCode)
        case .uploadFailed:
            return .uploadError
        }
    }

    private static func category(forHTTPStatus statusCode: Int) -> UploadFailureCategory {
        switch statusCode {
        case 400, 404, 405, 415, 422:
            return .configuration
        case 401:
            return .authentication
        case 402, 403, 429:
            return .entitlement
        case 408:
            return .connectivity
        case 500...599:
            return .server
        default:
            return .uploadError
        }
    }
}

public struct UploadJob: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var recordingID: String
    public var ideaProjectID: String
    public var localAudioPath: String
    public var status: UploadJobStatus
    public var attemptCount: Int
    public var nextAttemptAt: Date
    public var objectKey: String?
    public var lastErrorMessage: String?
    public var failureCategory: UploadFailureCategory?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        recordingID: String,
        ideaProjectID: String,
        localAudioPath: String,
        status: UploadJobStatus,
        attemptCount: Int,
        nextAttemptAt: Date,
        objectKey: String? = nil,
        lastErrorMessage: String? = nil,
        failureCategory: UploadFailureCategory? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.recordingID = recordingID
        self.ideaProjectID = ideaProjectID
        self.localAudioPath = localAudioPath
        self.status = status
        self.attemptCount = attemptCount
        self.nextAttemptAt = nextAttemptAt
        self.objectKey = objectKey
        self.lastErrorMessage = lastErrorMessage
        self.failureCategory = failureCategory
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum UploadQueuePolicy {
    public static let maximumAttempts = 5
    public static let interruptedUploadTimeout: TimeInterval = 15 * 60
    public static let interruptedUploadMessage = "Upload was interrupted and will retry."
    public static let interruptedUploadExhaustedMessage = "Upload was interrupted and has no retry attempts left."

    public static func job(for recording: Recording, localAudioPath: String, now: Date = Date()) -> UploadJob {
        UploadJob(
            id: "upload_\(recording.id)",
            recordingID: recording.id,
            ideaProjectID: recording.ideaProjectID,
            localAudioPath: localAudioPath,
            status: .queued,
            attemptCount: 0,
            nextAttemptAt: now,
            createdAt: now,
            updatedAt: now
        )
    }

    public static func markUploading(_ job: UploadJob, now: Date = Date()) -> UploadJob {
        var updated = job
        updated.status = .uploading
        updated.attemptCount += 1
        updated.updatedAt = now
        return updated
    }

    public static func markUploaded(_ job: UploadJob, objectKey: String, now: Date = Date()) -> UploadJob {
        var updated = job
        updated.status = .uploaded
        updated.objectKey = objectKey
        updated.lastErrorMessage = nil
        updated.failureCategory = nil
        updated.updatedAt = now
        return updated
    }

    public static func markFailed(
        _ job: UploadJob,
        message: String,
        category: UploadFailureCategory = .uploadError,
        now: Date = Date()
    ) -> UploadJob {
        var updated = job
        updated.lastErrorMessage = message
        updated.failureCategory = category
        updated.updatedAt = now

        if updated.attemptCount >= maximumAttempts {
            updated.status = .permanentlyFailed
            return updated
        }

        updated.status = .waitingForRetry
        let delay = retryDelaySeconds(afterAttempt: max(updated.attemptCount, 1))
        updated.nextAttemptAt = now.addingTimeInterval(delay)
        return updated
    }

    public static func manualRetry(_ job: UploadJob, now: Date = Date()) -> UploadJob? {
        guard job.status == .permanentlyFailed else { return nil }
        var updated = job
        updated.status = .queued
        updated.attemptCount = 0
        updated.nextAttemptAt = now
        updated.objectKey = nil
        updated.lastErrorMessage = nil
        updated.failureCategory = nil
        updated.updatedAt = now
        return updated
    }

    public static func isInterruptedUpload(_ job: UploadJob, now: Date = Date()) -> Bool {
        job.status == .uploading && now.timeIntervalSince(job.updatedAt) >= interruptedUploadTimeout
    }

    public static func markInterruptedForRetry(_ job: UploadJob, now: Date = Date()) -> UploadJob {
        var updated = job
        updated.updatedAt = now

        // markUploading already charged an attempt when this upload started, so
        // interrupted recovery must honor the same bound or a crash loop retries forever.
        if updated.attemptCount >= maximumAttempts {
            updated.status = .permanentlyFailed
            updated.lastErrorMessage = interruptedUploadExhaustedMessage
            updated.failureCategory = .connectivity
            return updated
        }

        updated.status = .waitingForRetry
        updated.nextAttemptAt = now
        updated.lastErrorMessage = interruptedUploadMessage
        updated.failureCategory = .connectivity
        return updated
    }

    public static func retryDelaySeconds(afterAttempt attempt: Int) -> TimeInterval {
        let boundedAttempt = min(max(attempt, 1), maximumAttempts)
        return TimeInterval(60 * (1 << (boundedAttempt - 1)))
    }
}

public enum UploadSchedulePolicy {
    public static func nextRunDate(for jobs: [UploadJob], now: Date = Date()) -> Date? {
        let eligibleDates = jobs.compactMap { job -> Date? in
            switch job.status {
            case .queued, .waitingForRetry:
                return job.nextAttemptAt
            case .uploading:
                return UploadQueuePolicy.isInterruptedUpload(job, now: now) ? now : nil
            case .uploaded, .permanentlyFailed:
                return nil
            }
        }

        guard let earliest = eligibleDates.min() else {
            return nil
        }
        return earliest <= now ? now : earliest
    }

    public static func hasDueUpload(in jobs: [UploadJob], now: Date = Date()) -> Bool {
        nextRunDate(for: jobs, now: now) == now
    }
}

public struct UploadReceipt: Equatable, Sendable {
    public var recordingID: String
    public var objectKey: String

    public init(recordingID: String, objectKey: String) {
        self.recordingID = recordingID
        self.objectKey = objectKey
    }
}

public enum UploadClientError: Error, Equatable, Sendable {
    case missingLocalFile(String)
    case configurationUnavailable
    case uploadFailed(String)
    case httpStatus(Int)
    case invalidResponse
}

public protocol AudioUploadClient: Sendable {
    func upload(job: UploadJob) async throws -> UploadReceipt
}

public enum LocalAudioObjectStoreError: Error, Equatable, UserFacingIdeaForgeError {
    case missingLocalFile(String)
    case unsafeObjectKey(String)
    case storage(StoragePreflightError)
    case invalidStoredObject
    case invalidStoredKey
    case encryptionUnavailable

    public var userFacingMessage: String {
        switch self {
        case .missingLocalFile:
            return "Local recording file is missing."
        case .unsafeObjectKey:
            return "Audio object path is unsafe."
        case .storage(let error):
            return error.userFacingMessage
        case .invalidStoredObject:
            return "Stored audio object could not be read."
        case .invalidStoredKey:
            return "Local audio encryption key is invalid."
        case .encryptionUnavailable:
            return "Local audio encryption is unavailable."
        }
    }
}

public protocol ObjectEncryptionKeyProvider: Sendable {
    func loadOrCreateKey() throws -> SymmetricKey
}

public struct StaticObjectEncryptionKeyProvider: ObjectEncryptionKeyProvider {
    private var keyData: Data

    public init(keyData: Data) {
        self.keyData = keyData
    }

    public func loadOrCreateKey() throws -> SymmetricKey {
        guard keyData.count == 32 else {
            throw LocalAudioObjectStoreError.invalidStoredKey
        }
        return SymmetricKey(data: keyData)
    }

    public static func testKey() -> StaticObjectEncryptionKeyProvider {
        StaticObjectEncryptionKeyProvider(keyData: Data(repeating: 7, count: 32))
    }
}

public struct KeychainObjectEncryptionKeyProvider: ObjectEncryptionKeyProvider {
    public var credentialStore: any BackendCredentialStore

    public init(
        credentialStore: any BackendCredentialStore = KeychainBackendCredentialStore(
            service: "com.s1kor.ideaforge.local-object-store",
            account: "objectStoreMasterKey"
        )
    ) {
        self.credentialStore = credentialStore
    }

    public func loadOrCreateKey() throws -> SymmetricKey {
        if let encodedKey = try credentialStore.loadBearerToken() {
            guard
                let keyData = Data(base64Encoded: encodedKey),
                keyData.count == 32
            else {
                throw LocalAudioObjectStoreError.invalidStoredKey
            }
            return SymmetricKey(data: keyData)
        }

        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        try credentialStore.saveBearerToken(keyData.base64EncodedString())
        return key
    }
}

public protocol LocalAudioObjectStoring: Sendable {
    func storeAudio(
        from sourceURL: URL,
        objectKey: String,
        recordingID: String,
        ideaProjectID: String
    ) throws
    func readObjectData(objectKey: String) throws -> Data
    func storedObjectURL(for objectKey: String) throws -> URL
}

public struct EncryptedLocalAudioObjectStore: LocalAudioObjectStoring {
    public var objectRoot: URL
    public var keyProvider: any ObjectEncryptionKeyProvider
    public var storagePreflight: StoragePreflight

    public init(
        objectRoot: URL = LocalAudioObjectUploadClient.applicationSupportObjectRoot(),
        keyProvider: any ObjectEncryptionKeyProvider = KeychainObjectEncryptionKeyProvider(),
        storagePreflight: StoragePreflight = .encryptedObjectStore()
    ) {
        self.objectRoot = objectRoot
        self.keyProvider = keyProvider
        self.storagePreflight = storagePreflight
    }

    public func storeAudio(
        from sourceURL: URL,
        objectKey: String,
        recordingID: String,
        ideaProjectID: String
    ) throws {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw LocalAudioObjectStoreError.missingLocalFile(sourceURL.path)
        }

        let plaintextByteCount = try sourceFileByteCount(sourceURL)
        let destinationURL = try storedObjectURL(for: objectKey)
        do {
            try storagePreflight.validateWritableVolume(
                for: destinationURL.deletingLastPathComponent(),
                estimatedWriteBytes: estimatedEnvelopeBytes(plaintextByteCount: plaintextByteCount)
            )
        } catch let error as StoragePreflightError {
            throw LocalAudioObjectStoreError.storage(error)
        }

        let plaintext = try Data(contentsOf: sourceURL)
        let key = try keyProvider.loadOrCreateKey()
        let associatedData = authenticationData(
            objectKey: objectKey,
            recordingID: recordingID,
            ideaProjectID: ideaProjectID,
            plaintextByteCount: plaintext.count
        )
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: associatedData)
        guard let combined = sealed.combined else {
            throw LocalAudioObjectStoreError.encryptionUnavailable
        }

        let envelope = EncryptedAudioObjectEnvelope(
            objectKey: objectKey,
            recordingID: recordingID,
            ideaProjectID: ideaProjectID,
            plaintextByteCount: plaintext.count,
            contentType: contentType(for: sourceURL),
            sealedPayloadBase64: combined.base64EncodedString(),
            createdAt: Date()
        )
        let encoded = try envelopeEncoder.encode(envelope)
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoded.write(to: destinationURL, options: [.atomic])
    }

    public func readObjectData(objectKey: String) throws -> Data {
        let storedURL = try storedObjectURL(for: objectKey)
        let data = try Data(contentsOf: storedURL)
        let envelope = try envelopeDecoder.decode(EncryptedAudioObjectEnvelope.self, from: data)
        guard
            envelope.version == EncryptedAudioObjectEnvelope.currentVersion,
            envelope.algorithm == EncryptedAudioObjectEnvelope.algorithm,
            envelope.objectKey == objectKey,
            let sealedPayload = Data(base64Encoded: envelope.sealedPayloadBase64)
        else {
            throw LocalAudioObjectStoreError.invalidStoredObject
        }

        let key = try keyProvider.loadOrCreateKey()
        let sealedBox = try AES.GCM.SealedBox(combined: sealedPayload)
        let associatedData = authenticationData(
            objectKey: envelope.objectKey,
            recordingID: envelope.recordingID,
            ideaProjectID: envelope.ideaProjectID,
            plaintextByteCount: envelope.plaintextByteCount
        )
        return try AES.GCM.open(sealedBox, using: key, authenticating: associatedData)
    }

    public func storedObjectURL(for objectKey: String) throws -> URL {
        let parts = objectKey.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.allSatisfy(isSafeObjectPathComponent) else {
            throw LocalAudioObjectStoreError.unsafeObjectKey(objectKey)
        }

        let root = objectRoot.standardizedFileURL
        var url = root
        for part in parts {
            url.append(path: part)
        }

        let destination = url.standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : "\(root.path)/"
        guard destination.path.hasPrefix(rootPath) else {
            throw LocalAudioObjectStoreError.unsafeObjectKey(objectKey)
        }
        return destination
    }

    private func authenticationData(
        objectKey: String,
        recordingID: String,
        ideaProjectID: String,
        plaintextByteCount: Int
    ) -> Data {
        Data("\(objectKey)|\(recordingID)|\(ideaProjectID)|\(plaintextByteCount)".utf8)
    }

    private func contentType(for sourceURL: URL) -> String {
        switch sourceURL.pathExtension.lowercased() {
        case "m4a":
            return "audio/mp4"
        case "wav":
            return "audio/wav"
        case "mp3":
            return "audio/mpeg"
        default:
            return "application/octet-stream"
        }
    }

    private func sourceFileByteCount(_ sourceURL: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        guard let byteCount = attributes[.size] as? NSNumber else {
            throw LocalAudioObjectStoreError.missingLocalFile(sourceURL.path)
        }
        return byteCount.int64Value
    }

    private func estimatedEnvelopeBytes(plaintextByteCount: Int64) -> Int64 {
        max(plaintextByteCount * 2, plaintextByteCount + 8_192)
    }

    private func isSafeObjectPathComponent(_ part: String) -> Bool {
        guard !part.isEmpty, part != ".", part != ".." else {
            return false
        }
        return part.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" || scalar == "."
        }
    }

    private var envelopeEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private var envelopeDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private struct EncryptedAudioObjectEnvelope: Codable, Equatable {
    static let currentVersion = 1
    static let algorithm = "AES.GCM.256"

    var version: Int = currentVersion
    var algorithm: String = Self.algorithm
    var objectKey: String
    var recordingID: String
    var ideaProjectID: String
    var plaintextByteCount: Int
    var contentType: String
    var sealedPayloadBase64: String
    var createdAt: Date
}

public struct BackendUploadConfiguration: Equatable, Sendable {
    public var baseURL: URL
    public var bearerToken: String
    public var workspaceID: String
    public var uploadPath: String

    public init(
        baseURL: URL,
        bearerToken: String,
        workspaceID: String = "",
        uploadPath: String = "/v1/recordings/upload"
    ) {
        self.baseURL = baseURL
        self.bearerToken = bearerToken
        self.workspaceID = workspaceID
        self.uploadPath = uploadPath
    }

    public var uploadURL: URL {
        let normalizedPath = uploadPath.hasPrefix("/") ? String(uploadPath.dropFirst()) : uploadPath
        return baseURL.appendingPathComponent(normalizedPath)
    }

    public var isConfigured: Bool {
        !bearerToken.isEmpty && !workspaceID.isEmpty
    }
}

public protocol HTTPDataTransport: Sendable {
    func uploadFile(for request: URLRequest, from sourceURL: URL) async throws -> (Data, HTTPURLResponse)
}

public struct BackgroundUploadCompletionRecord: Codable, Equatable, Sendable {
    public var uploadJobID: String
    public var recordingID: String
    public var responseData: Data
    public var statusCode: Int?
    public var errorDescription: String?
    public var completedAt: Date

    public init(
        uploadJobID: String,
        recordingID: String,
        responseData: Data,
        statusCode: Int?,
        errorDescription: String?,
        completedAt: Date
    ) {
        self.uploadJobID = uploadJobID
        self.recordingID = recordingID
        self.responseData = responseData
        self.statusCode = statusCode
        self.errorDescription = errorDescription
        self.completedAt = completedAt
    }
}

public enum BackgroundUploadCompletionPolicy {
    public static func receipt(from record: BackgroundUploadCompletionRecord) throws -> UploadReceipt {
        if let errorDescription = record.errorDescription {
            throw UploadClientError.uploadFailed(errorDescription)
        }
        guard let statusCode = record.statusCode else {
            throw UploadClientError.invalidResponse
        }
        guard (200..<300).contains(statusCode) else {
            throw UploadClientError.httpStatus(statusCode)
        }
        let decoded = try JSONDecoder().decode(BackendUploadResponse.self, from: record.responseData)
        guard !decoded.objectKey.isEmpty else {
            throw UploadClientError.invalidResponse
        }
        return UploadReceipt(recordingID: record.recordingID, objectKey: decoded.objectKey)
    }
}

public final class URLSessionHTTPDataTransport: NSObject, HTTPDataTransport, @unchecked Sendable {
    public static let backgroundSessionIdentifier = "com.s1kor.ideaforge.audio-upload"
    public static let shared = URLSessionHTTPDataTransport()

    private struct TransferState {
        var responseData = Data()
        var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>
    }

    private let lock = NSLock()
    private var transferStates: [Int: TransferState] = [:]
    private var orphanResponseData: [Int: Data] = [:]
    private var backgroundEventsCompletionHandler: (@Sendable () -> Void)?
    private let completionRecordsKey = "ideaforge.backgroundUpload.completionRecords.v1"
    private lazy var session: URLSession = {
        let configuration: URLSessionConfiguration
        #if os(iOS)
        configuration = .background(withIdentifier: Self.backgroundSessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        #else
        configuration = .default
        #endif
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    override private init() {
        super.init()
    }

    public func uploadFile(
        for request: URLRequest,
        from sourceURL: URL
    ) async throws -> (Data, HTTPURLResponse) {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw UploadClientError.missingLocalFile(sourceURL.path)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let task = session.uploadTask(with: request, fromFile: sourceURL)
            task.taskDescription = request.value(forHTTPHeaderField: "X-IdeaForge-Upload-Job-ID")
            lock.lock()
            transferStates[task.taskIdentifier] = TransferState(continuation: continuation)
            lock.unlock()
            task.resume()
        }
    }

    public func installBackgroundEventsCompletionHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        backgroundEventsCompletionHandler = handler
        lock.unlock()
        _ = session
    }

    public func pendingBackgroundCompletionRecords() -> [BackgroundUploadCompletionRecord] {
        lock.lock()
        defer { lock.unlock() }
        return loadCompletionRecordsLocked()
    }

    public func removeBackgroundCompletionRecords(uploadJobIDs: Set<String>) {
        guard !uploadJobIDs.isEmpty else { return }
        lock.lock()
        let remaining = loadCompletionRecordsLocked().filter {
            !uploadJobIDs.contains($0.uploadJobID)
        }
        saveCompletionRecordsLocked(remaining)
        lock.unlock()
    }

    private func append(_ data: Data, to taskIdentifier: Int) {
        lock.lock()
        if transferStates[taskIdentifier] != nil {
            transferStates[taskIdentifier]?.responseData.append(data)
        } else {
            orphanResponseData[taskIdentifier, default: Data()].append(data)
        }
        lock.unlock()
    }

    private func finish(task: URLSessionTask, error: Error?) {
        lock.lock()
        let state = transferStates.removeValue(forKey: task.taskIdentifier)
        let orphanData = orphanResponseData.removeValue(forKey: task.taskIdentifier) ?? Data()
        lock.unlock()

        guard let state else {
            persistBackgroundCompletion(task: task, responseData: orphanData, error: error)
            return
        }
        if let error {
            state.continuation.resume(throwing: error)
            return
        }
        guard let response = task.response as? HTTPURLResponse else {
            state.continuation.resume(throwing: UploadClientError.invalidResponse)
            return
        }
        state.continuation.resume(returning: (state.responseData, response))
    }

    private func persistBackgroundCompletion(
        task: URLSessionTask,
        responseData: Data,
        error: Error?
    ) {
        let request = task.originalRequest ?? task.currentRequest
        let uploadJobID = request?.value(forHTTPHeaderField: "X-IdeaForge-Upload-Job-ID")
            ?? task.taskDescription
            ?? ""
        let recordingID = request?.value(forHTTPHeaderField: "X-IdeaForge-Recording-ID") ?? ""
        guard !uploadJobID.isEmpty, !recordingID.isEmpty else {
            IdeaForgeLog.sync.error("Background upload completion could not be reconciled; task metadata missing")
            return
        }

        let record = BackgroundUploadCompletionRecord(
            uploadJobID: uploadJobID,
            recordingID: recordingID,
            responseData: responseData,
            statusCode: (task.response as? HTTPURLResponse)?.statusCode,
            errorDescription: error.map { String(describing: $0) },
            completedAt: Date()
        )
        lock.lock()
        var records = loadCompletionRecordsLocked()
        records.removeAll { $0.uploadJobID == uploadJobID }
        records.append(record)
        saveCompletionRecordsLocked(records)
        lock.unlock()
        IdeaForgeLog.sync.info("Background upload completion persisted for relaunch reconciliation")
    }

    private func loadCompletionRecordsLocked() -> [BackgroundUploadCompletionRecord] {
        guard let data = UserDefaults.standard.data(forKey: completionRecordsKey) else {
            return []
        }
        return (try? JSONDecoder().decode([BackgroundUploadCompletionRecord].self, from: data)) ?? []
    }

    private func saveCompletionRecordsLocked(_ records: [BackgroundUploadCompletionRecord]) {
        if records.isEmpty {
            UserDefaults.standard.removeObject(forKey: completionRecordsKey)
            return
        }
        guard let data = try? JSONEncoder().encode(records) else {
            IdeaForgeLog.sync.error("Background upload completion persistence encoding failed")
            return
        }
        UserDefaults.standard.set(data, forKey: completionRecordsKey)
    }

    private func finishBackgroundEvents() {
        lock.lock()
        let handler = backgroundEventsCompletionHandler
        backgroundEventsCompletionHandler = nil
        lock.unlock()
        handler?()
    }
}

extension URLSessionHTTPDataTransport: URLSessionDataDelegate {
    public func urlSession(
        _: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        append(data, to: dataTask.taskIdentifier)
    }

    public func urlSession(
        _: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        finish(task: task, error: error)
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession _: URLSession) {
        finishBackgroundEvents()
    }
}

public struct BackendAudioUploadClient: AudioUploadClient {
    public var configuration: BackendUploadConfiguration
    public var transport: any HTTPDataTransport

    public init(
        configuration: BackendUploadConfiguration,
        transport: any HTTPDataTransport = URLSessionHTTPDataTransport.shared
    ) {
        self.configuration = configuration
        self.transport = transport
    }

    public func upload(job: UploadJob) async throws -> UploadReceipt {
        let sourceURL = URL(fileURLWithPath: job.localAudioPath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw UploadClientError.missingLocalFile(job.localAudioPath)
        }

        let fileMetadata = try Self.fileMetadata(for: sourceURL)
        var request = URLRequest(url: configuration.uploadURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue(configuration.workspaceID, forHTTPHeaderField: BackendRequestHeader.workspaceID)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("\(fileMetadata.byteCount)", forHTTPHeaderField: "Content-Length")
        request.setValue(job.recordingID, forHTTPHeaderField: "X-IdeaForge-Recording-ID")
        request.setValue(job.ideaProjectID, forHTTPHeaderField: "X-IdeaForge-Idea-ID")
        request.setValue(job.id, forHTTPHeaderField: "X-IdeaForge-Upload-Job-ID")
        request.setValue(fileMetadata.sha256HexDigest, forHTTPHeaderField: "X-IdeaForge-Content-SHA256")
        request.setValue("\(job.attemptCount)", forHTTPHeaderField: "X-IdeaForge-Attempt")

        let (data, response) = try await transport.uploadFile(for: request, from: sourceURL)
        guard (200..<300).contains(response.statusCode) else {
            throw UploadClientError.httpStatus(response.statusCode)
        }

        let decoded = try JSONDecoder().decode(BackendUploadResponse.self, from: data)
        guard !decoded.objectKey.isEmpty else {
            throw UploadClientError.invalidResponse
        }
        return UploadReceipt(recordingID: job.recordingID, objectKey: decoded.objectKey)
    }

    private static func fileMetadata(for sourceURL: URL) throws -> (byteCount: Int64, sha256HexDigest: String) {
        let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw UploadClientError.missingLocalFile(sourceURL.path)
        }

        let handle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
        return (size.int64Value, digest)
    }
}

struct BackendUploadResponse: Decodable {
    var objectKey: String
}

public enum AudioUploadClientFactory {
    public static func client(configuration: BackendUploadConfiguration?) -> any AudioUploadClient {
        guard let configuration, configuration.isConfigured else {
            return LocalAudioObjectUploadClient()
        }
        return BackendAudioUploadClient(configuration: configuration)
    }
}

public struct UploadQueueProcessingSummary: Equatable, Sendable {
    public var attemptedCount: Int
    public var uploadedCount: Int
    public var failedCount: Int

    public init(attemptedCount: Int = 0, uploadedCount: Int = 0, failedCount: Int = 0) {
        self.attemptedCount = attemptedCount
        self.uploadedCount = uploadedCount
        self.failedCount = failedCount
    }
}

public actor UploadQueueProcessingCoordinator {
    private typealias ProcessingPass = @MainActor @Sendable () async throws -> UploadQueueProcessingSummary

    private var ownsProcessing = false
    private var pendingPass: ProcessingPass?
    private var waitingRequests: [CheckedContinuation<UploadQueueProcessingSummary, any Error>] = []

    public init() {}

    public var isProcessing: Bool {
        ownsProcessing
    }

    public var hasPendingRequest: Bool {
        pendingPass != nil
    }

    @discardableResult
    public func requestProcessing(
        _ processPass: @escaping @MainActor @Sendable () async throws -> UploadQueueProcessingSummary
    ) async throws -> UploadQueueProcessingSummary {
        guard !ownsProcessing else {
            pendingPass = processPass
            return try await withCheckedThrowingContinuation { continuation in
                waitingRequests.append(continuation)
            }
        }

        ownsProcessing = true
        var nextPass: ProcessingPass? = processPass
        var aggregate = UploadQueueProcessingSummary()

        do {
            while let pass = nextPass {
                let summary = try await pass()
                aggregate.attemptedCount += summary.attemptedCount
                aggregate.uploadedCount += summary.uploadedCount
                aggregate.failedCount += summary.failedCount
                nextPass = pendingPass
                pendingPass = nil
            }
            finishWaitingRequests(with: .success(aggregate))
            return aggregate
        } catch {
            pendingPass = nil
            finishWaitingRequests(with: .failure(error))
            throw error
        }
    }

    private func finishWaitingRequests(
        with result: Result<UploadQueueProcessingSummary, any Error>
    ) {
        ownsProcessing = false
        let continuations = waitingRequests
        waitingRequests.removeAll()
        for continuation in continuations {
            switch result {
            case .success(let summary):
                continuation.resume(returning: summary)
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
    }
}

public struct UploadQueueProcessor: Sendable {
    public var client: any AudioUploadClient
    public var maxJobsPerRun: Int

    public init(client: any AudioUploadClient, maxJobsPerRun: Int = 3) {
        self.client = client
        self.maxJobsPerRun = maxJobsPerRun
    }

    @MainActor
    public func processDueUploads(
        in store: IdeaForgeStore,
        now: Date = Date()
    ) async -> UploadQueueProcessingSummary {
        store.recoverInterruptedUploads(now: now)
        let dueJobs = store.uploadJobs
            .filter { job in
                (job.status == .queued || job.status == .waitingForRetry) && job.nextAttemptAt <= now
            }
            .prefix(maxJobsPerRun)

        var summary = UploadQueueProcessingSummary()
        for job in dueJobs {
            summary.attemptedCount += 1
            guard store.markUploadStarted(recordingID: job.recordingID, now: now) else {
                summary.failedCount += 1
                continue
            }

            let uploadJob = store.uploadJobs.first { $0.recordingID == job.recordingID } ?? job
            do {
                let receipt = try await client.upload(job: uploadJob)
                if store.markUploadSucceeded(
                    recordingID: receipt.recordingID,
                    objectKey: receipt.objectKey,
                    now: now
                ) {
                    summary.uploadedCount += 1
                } else {
                    summary.failedCount += 1
                }
            } catch {
                let message = (error as? UserFacingIdeaForgeError)?.userFacingMessage ?? String(describing: error)
                store.markUploadFailed(
                    recordingID: job.recordingID,
                    message: message,
                    category: UploadFailureCategory.classify(error),
                    now: now
                )
                summary.failedCount += 1
            }
        }
        return summary
    }
}

public struct ConfiguredUploadQueueProcessor: Sendable {
    public var backendConfigurationManager: BackendConfigurationManager
    public var maxJobsPerRun: Int

    public init(
        backendConfigurationManager: BackendConfigurationManager,
        maxJobsPerRun: Int = 3
    ) {
        self.backendConfigurationManager = backendConfigurationManager
        self.maxJobsPerRun = maxJobsPerRun
    }

    @MainActor
    public func processDueUploads(
        in store: IdeaForgeStore,
        now: Date = Date()
    ) async throws -> UploadQueueProcessingSummary {
        let configuration: BackendUploadConfiguration?
        do {
            configuration = try backendConfigurationManager.resolvedUploadConfiguration()
            let settings = try backendConfigurationManager.loadSettings()
            if settings.isEnabled, configuration == nil {
                throw BackendConfigurationError.missingRequiredConfiguration
            }
        } catch {
            _ = await UploadQueueProcessor(
                client: ImmediateUploadFailureClient(error: .configurationUnavailable),
                maxJobsPerRun: maxJobsPerRun
            )
            .processDueUploads(in: store, now: now)
            throw error
        }
        let processor = UploadQueueProcessor(
            client: AudioUploadClientFactory.client(configuration: configuration),
            maxJobsPerRun: maxJobsPerRun
        )
        return await processor.processDueUploads(in: store, now: now)
    }
}

private struct ImmediateUploadFailureClient: AudioUploadClient {
    var error: UploadClientError

    func upload(job: UploadJob) async throws -> UploadReceipt {
        throw error
    }
}

public struct LocalAudioObjectUploadClient: AudioUploadClient {
    public var objectStore: any LocalAudioObjectStoring

    public init(
        objectRoot: URL = LocalAudioObjectUploadClient.applicationSupportObjectRoot()
    ) {
        self.objectStore = EncryptedLocalAudioObjectStore(objectRoot: objectRoot)
    }

    public init(objectStore: any LocalAudioObjectStoring) {
        self.objectStore = objectStore
    }

    public func upload(job: UploadJob) async throws -> UploadReceipt {
        let fileManager = FileManager.default
        let sourceURL = URL(fileURLWithPath: job.localAudioPath)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw UploadClientError.missingLocalFile(job.localAudioPath)
        }

        let fileExtension = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension
        let objectKey = "audio/\(Self.safeObjectComponent(job.ideaProjectID))/\(Self.safeObjectComponent(job.recordingID)).\(Self.safeObjectComponent(fileExtension))"
        try objectStore.storeAudio(
            from: sourceURL,
            objectKey: objectKey,
            recordingID: job.recordingID,
            ideaProjectID: job.ideaProjectID
        )
        return UploadReceipt(recordingID: job.recordingID, objectKey: objectKey)
    }

    private static func safeObjectComponent(_ value: String) -> String {
        let filtered = value.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" || scalar == "." {
                return Character(scalar)
            }
            return "_"
        }
        let sanitized = String(filtered).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return sanitized.isEmpty ? "unknown" : sanitized
    }

    public static func applicationSupportObjectRoot(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appending(path: "IdeaForge/BackendObjects", directoryHint: .isDirectory)
    }
}
