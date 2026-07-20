import Foundation

public enum RecordingTransferStatus: String, Codable, Equatable, Sendable {
    case unavailable
    case queuedForTransfer
    case received
    case failed

    public var label: String {
        switch self {
        case .unavailable: "Unavailable"
        case .queuedForTransfer: "Queued for transfer"
        case .received: "Imported on iPhone"
        case .failed: "Retry needed"
        }
    }
}

public struct RecordingTransferMetadata: Codable, Equatable, Sendable {
    private static let maximumIdentifierLength = 128
    private static let maximumDeviceNameLength = 128
    private static let maximumLanguageHintLength = 32
    private static let maximumDurationSeconds = 24 * 60 * 60
    private static let maximumMarkerCount = 1_024
    private static let earliestPlausibleCreationDate = Date(timeIntervalSince1970: 978_307_200)
    private static let maximumFutureSkew: TimeInterval = 60 * 60
    public var recordingID: String
    public var ideaProjectID: String
    public var sourceDeviceName: String
    public var durationSeconds: Int
    public var languageHint: String
    public var markerOffsets: [Int]
    public var createdAt: Date

    public init(
        recordingID: String,
        ideaProjectID: String,
        sourceDeviceName: String,
        durationSeconds: Int,
        languageHint: String,
        markerOffsets: [Int],
        createdAt: Date
    ) {
        self.recordingID = recordingID
        self.ideaProjectID = ideaProjectID
        self.sourceDeviceName = sourceDeviceName
        self.durationSeconds = durationSeconds
        self.languageHint = languageHint
        self.markerOffsets = markerOffsets
        self.createdAt = createdAt
    }

    public init(recording: Recording) {
        self.init(
            recordingID: recording.id,
            ideaProjectID: recording.ideaProjectID,
            sourceDeviceName: recording.deviceName,
            durationSeconds: recording.durationSeconds,
            languageHint: recording.languageHint,
            markerOffsets: recording.markerOffsets,
            createdAt: recording.createdAt
        )
    }

    public var isValid: Bool {
        Self.isSafeIdentifier(recordingID)
            && Self.isSafeIdentifier(ideaProjectID)
            && !sourceDeviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && sourceDeviceName.count <= Self.maximumDeviceNameLength
            && !languageHint.isEmpty
            && languageHint.count <= Self.maximumLanguageHintLength
            && languageHint.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
            }
            && (0...Self.maximumDurationSeconds).contains(durationSeconds)
            && markerOffsets.count <= Self.maximumMarkerCount
            && markerOffsets.allSatisfy { (0...durationSeconds).contains($0) }
            && createdAt.timeIntervalSince1970.isFinite
            && createdAt >= Self.earliestPlausibleCreationDate
            && createdAt <= Date().addingTimeInterval(Self.maximumFutureSkew)
    }

    public var watchConnectivityMetadata: [String: Any] {
        [
            "recordingID": recordingID,
            "ideaProjectID": ideaProjectID,
            "sourceDeviceName": sourceDeviceName,
            "durationSeconds": durationSeconds,
            "languageHint": languageHint,
            "markerOffsets": markerOffsets,
            "createdAt": createdAt.timeIntervalSince1970
        ]
    }

    public init?(watchConnectivityMetadata metadata: [String: Any]) {
        guard let recordingID = metadata["recordingID"] as? String,
              let ideaProjectID = metadata["ideaProjectID"] as? String,
              let sourceDeviceName = metadata["sourceDeviceName"] as? String,
              let durationSeconds = metadata["durationSeconds"] as? Int,
              let languageHint = metadata["languageHint"] as? String,
              let markerOffsets = metadata["markerOffsets"] as? [Int],
              let createdAtSeconds = metadata["createdAt"] as? TimeInterval else {
            return nil
        }

        let decoded = Self(
            recordingID: recordingID,
            ideaProjectID: ideaProjectID,
            sourceDeviceName: sourceDeviceName,
            durationSeconds: durationSeconds,
            languageHint: languageHint,
            markerOffsets: markerOffsets,
            createdAt: Date(timeIntervalSince1970: createdAtSeconds)
        )
        guard decoded.isValid else { return nil }
        self = decoded
    }

    static func isSafeIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.count <= maximumIdentifierLength,
              value != ".",
              value != ".." else {
            return false
        }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" || $0 == "."
        }
    }
}

public struct RecordingTransferReceipt: Equatable, Sendable {
    public var recordingID: String
    public var status: RecordingTransferStatus

    public init(recordingID: String, status: RecordingTransferStatus) {
        self.recordingID = recordingID
        self.status = status
    }
}

public enum RecordingTransferImportResult: String, Codable, Equatable, Sendable {
    case imported
    case failed
}

public struct RecordingTransferImportAcknowledgement: Equatable, Sendable {
    private static let messageType = "recordingImportAcknowledgement"

    public var recordingID: String
    public var result: RecordingTransferImportResult

    public init(recordingID: String, result: RecordingTransferImportResult) {
        self.recordingID = recordingID
        self.result = result
    }

    public var watchConnectivityUserInfo: [String: Any] {
        [
            "messageType": Self.messageType,
            "recordingID": recordingID,
            "result": result.rawValue
        ]
    }

    public init?(watchConnectivityUserInfo userInfo: [String: Any]) {
        guard userInfo["messageType"] as? String == Self.messageType,
              let recordingID = userInfo["recordingID"] as? String,
              RecordingTransferMetadata.isSafeIdentifier(recordingID),
              let rawResult = userInfo["result"] as? String,
              let result = RecordingTransferImportResult(rawValue: rawResult) else {
            return nil
        }
        self.init(recordingID: recordingID, result: result)
    }
}

enum RecordingTransferCompletionPolicy {
    static func transportCompletion(delivered: Bool) -> Bool? {
        delivered ? nil : false
    }

    static func importCompletion(for result: RecordingTransferImportResult) -> Bool {
        result == .imported
    }
}

enum RecordingTransferQueuePolicy {
    static func shouldQueue(
        recordingID: String,
        sessionIsActivated: Bool,
        outstandingRecordingIDs: Set<String>
    ) -> Bool {
        sessionIsActivated && !outstandingRecordingIDs.contains(recordingID)
    }
}

enum RecordingTransferReachabilityPolicy {
    static func isReachable(
        sessionIsActivated: Bool,
        companionIsAvailable: Bool,
        sessionIsReachable: Bool
    ) -> Bool {
        sessionIsActivated && companionIsAvailable && sessionIsReachable
    }
}

public enum RecordingTransferError: Error, Equatable {
    case unsupportedPlatform
    case missingLocalAudioFile
    case inactiveSession
    case receivedFileStageFailed
    case invalidMetadata
}

public protocol RecordingTransferService {
    @MainActor func activate()
    @MainActor func transfer(recording: Recording) throws -> RecordingTransferReceipt
    @MainActor func setTransferCompletionHandler(_ handler: RecordingTransferCompletionHandler?)
    @MainActor func setReachabilityHandler(_ handler: RecordingTransferReachabilityHandler?)
}

extension RecordingTransferService {
    @MainActor
    public func setTransferCompletionHandler(_ handler: RecordingTransferCompletionHandler?) {}

    @MainActor
    public func setReachabilityHandler(_ handler: RecordingTransferReachabilityHandler?) {}
}

public typealias RecordingTransferReceiveHandler = @MainActor @Sendable (URL, RecordingTransferMetadata) async -> RecordingTransferImportResult

/// Called after transport fails or the receiving app acknowledges its import.
/// `imported` is true only after the recording is durable in the receiving workspace.
public typealias RecordingTransferCompletionHandler = @MainActor @Sendable (_ recordingID: String, _ imported: Bool) -> Void
public typealias RecordingTransferReachabilityHandler = @MainActor @Sendable (_ isReachable: Bool) -> Void

public struct UnavailableRecordingTransferService: RecordingTransferService {
    public init() {}

    @MainActor
    public func activate() {}

    @MainActor
    public func transfer(recording: Recording) throws -> RecordingTransferReceipt {
        throw RecordingTransferError.unsupportedPlatform
    }
}

enum RecordingTransferFileStager {
    static func stageReceivedFileForImport(
        sourceURL: URL,
        metadata: RecordingTransferMetadata,
        fileManager: FileManager = .default,
        rootDirectory: URL? = nil
    ) throws -> URL {
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw RecordingTransferError.missingLocalAudioFile
        }
        let attributes = try fileManager.attributesOfItem(atPath: sourceURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw RecordingTransferError.missingLocalAudioFile
        }

        let root = rootDirectory
            ?? fileManager.temporaryDirectory.appending(path: "IdeaForge/WatchConnectivity/Received", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        guard metadata.isValid else { throw RecordingTransferError.invalidMetadata }
        let candidateExtension = sourceURL.pathExtension.lowercased()
        let fileExtension = candidateExtension.isEmpty || candidateExtension.count > 10
            || !candidateExtension.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains)
            ? "m4a"
            : candidateExtension
        let destinationURL = root.appending(
            path: "\(metadata.recordingID)-\(UUID().uuidString).\(fileExtension)"
        )
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    @discardableResult
    static func discardStagedFileAfterImport(
        _ stagedURL: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard fileManager.fileExists(atPath: stagedURL.path) else {
            return true
        }
        do {
            try fileManager.removeItem(at: stagedURL)
            return true
        } catch {
            return false
        }
    }
}

public enum RecordingTransferServiceFactory {
    @MainActor
    public static func platformDefault(
        receiveHandler: RecordingTransferReceiveHandler? = nil
    ) -> any RecordingTransferService {
        #if canImport(WatchConnectivity) && (os(iOS) || os(watchOS))
        return WatchConnectivityRecordingTransferService(receiveHandler: receiveHandler)
        #else
        return UnavailableRecordingTransferService()
        #endif
    }
}

#if canImport(WatchConnectivity) && (os(iOS) || os(watchOS))
@preconcurrency import WatchConnectivity

public final class WatchConnectivityRecordingTransferService: NSObject, RecordingTransferService, @unchecked Sendable {
    private let session: WCSession?
    private let receiveHandler: RecordingTransferReceiveHandler?
    @MainActor private var transferCompletionHandler: RecordingTransferCompletionHandler?
    @MainActor private var reachabilityHandler: RecordingTransferReachabilityHandler?
    @MainActor private var pendingAcknowledgements: [String: RecordingTransferImportResult] = [:]
    @MainActor public private(set) var receivedTransfers: [RecordingTransferMetadata] = []

    public init(
        session: WCSession? = WCSession.isSupported() ? .default : nil,
        receiveHandler: RecordingTransferReceiveHandler? = nil
    ) {
        self.session = session
        self.receiveHandler = receiveHandler
        super.init()
    }

    @MainActor
    public func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    @MainActor
    public func setTransferCompletionHandler(_ handler: RecordingTransferCompletionHandler?) {
        transferCompletionHandler = handler
    }

    @MainActor
    public func setReachabilityHandler(_ handler: RecordingTransferReachabilityHandler?) {
        reachabilityHandler = handler
        if let session {
            publishReachability(for: session)
        }
    }

    @MainActor
    public func transfer(recording: Recording) throws -> RecordingTransferReceipt {
        guard let session else {
            throw RecordingTransferError.unsupportedPlatform
        }
        guard session.activationState == .activated else {
            throw RecordingTransferError.inactiveSession
        }
        guard RecordingTransferMetadata(recording: recording).isValid else {
            throw RecordingTransferError.invalidMetadata
        }
        guard let localAudioPath = recording.localAudioPath else {
            throw RecordingTransferError.missingLocalAudioFile
        }

        let fileURL = URL(fileURLWithPath: localAudioPath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw RecordingTransferError.missingLocalAudioFile
        }

        let outstandingRecordingIDs = Set(
            session.outstandingFileTransfers.compactMap { transfer in
                RecordingTransferMetadata(
                    watchConnectivityMetadata: transfer.file.metadata ?? [:]
                )?.recordingID
            }
        )
        guard RecordingTransferQueuePolicy.shouldQueue(
            recordingID: recording.id,
            sessionIsActivated: true,
            outstandingRecordingIDs: outstandingRecordingIDs
        ) else {
            IdeaForgeLog.sync.info("Watch recording transfer already queued; duplicate request ignored")
            return RecordingTransferReceipt(recordingID: recording.id, status: .queuedForTransfer)
        }

        _ = session.transferFile(
            fileURL,
            metadata: RecordingTransferMetadata(recording: recording).watchConnectivityMetadata
        )
        return RecordingTransferReceipt(recordingID: recording.id, status: .queuedForTransfer)
    }

    @MainActor
    private func queueAcknowledgement(
        recordingID: String,
        result: RecordingTransferImportResult,
        on session: WCSession
    ) {
        guard session.activationState == .activated else {
            pendingAcknowledgements[recordingID] = result
            session.activate()
            IdeaForgeLog.sync.info("Watch import acknowledgement held until connectivity session activates")
            return
        }
        _ = session.transferUserInfo(
            RecordingTransferImportAcknowledgement(
                recordingID: recordingID,
                result: result
            )
            .watchConnectivityUserInfo
        )
        pendingAcknowledgements.removeValue(forKey: recordingID)
    }

    @MainActor
    private func flushPendingAcknowledgements(on session: WCSession) {
        guard session.activationState == .activated else { return }
        let acknowledgements = pendingAcknowledgements
        pendingAcknowledgements.removeAll()
        for (recordingID, result) in acknowledgements {
            _ = session.transferUserInfo(
                RecordingTransferImportAcknowledgement(
                    recordingID: recordingID,
                    result: result
                )
                .watchConnectivityUserInfo
            )
        }
    }

    @MainActor
    private func publishReachability(for session: WCSession) {
        #if os(iOS)
        let companionIsAvailable = session.isPaired && session.isWatchAppInstalled
        #else
        let companionIsAvailable = true
        #endif
        reachabilityHandler?(
            RecordingTransferReachabilityPolicy.isReachable(
                sessionIsActivated: session.activationState == .activated,
                companionIsAvailable: companionIsAvailable,
                sessionIsReachable: session.isReachable
            )
        )
    }
}

extension WatchConnectivityRecordingTransferService: WCSessionDelegate {
    public nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        guard error == nil, activationState == .activated else {
            if error != nil {
                IdeaForgeLog.sync.error("Watch connectivity session activation failed")
            }
            return
        }
        Task { @MainActor [weak self] in
            self?.flushPendingAcknowledgements(on: session)
            self?.publishReachability(for: session)
        }
    }

    public nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.publishReachability(for: session)
        }
    }

    public nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        guard let metadata = RecordingTransferMetadata(watchConnectivityMetadata: fileTransfer.file.metadata ?? [:]) else {
            return
        }
        let delivered = error == nil
        guard let completion = RecordingTransferCompletionPolicy.transportCompletion(delivered: delivered) else {
            IdeaForgeLog.sync.info("Watch recording transport completed; awaiting iPhone import acknowledgement")
            return
        }
        if !completion {
            IdeaForgeLog.sync.error("Watch recording transfer finished with delivery failure")
        }
        Task { @MainActor [weak self] in
            self?.transferCompletionHandler?(metadata.recordingID, completion)
        }
    }

    public nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let metadata = RecordingTransferMetadata(watchConnectivityMetadata: file.metadata ?? [:]) else {
            return
        }
        let stagedFileURL: URL
        do {
            stagedFileURL = try RecordingTransferFileStager.stageReceivedFileForImport(
                sourceURL: file.fileURL,
                metadata: metadata
            )
        } catch {
            IdeaForgeLog.sync.error("Watch recording transfer staging failed")
            Task { @MainActor [weak self] in
                self?.queueAcknowledgement(
                    recordingID: metadata.recordingID,
                    result: .failed,
                    on: session
                )
            }
            return
        }

        Task { @MainActor [weak self] in
            guard let self else {
                _ = RecordingTransferFileStager.discardStagedFileAfterImport(stagedFileURL)
                return
            }
            let result = await self.receiveHandler?(stagedFileURL, metadata) ?? .failed
            if result == .imported {
                self.receivedTransfers.append(metadata)
            } else {
                IdeaForgeLog.sync.error("Watch recording reached iPhone but workspace import failed")
            }
            if !RecordingTransferFileStager.discardStagedFileAfterImport(stagedFileURL) {
                IdeaForgeLog.sync.error("Watch recording transfer staging cleanup failed")
            }
            self.queueAcknowledgement(
                recordingID: metadata.recordingID,
                result: result,
                on: session
            )
        }
    }

    public nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let acknowledgement = RecordingTransferImportAcknowledgement(
            watchConnectivityUserInfo: userInfo
        ) else {
            return
        }
        let imported = RecordingTransferCompletionPolicy.importCompletion(for: acknowledgement.result)
        Task { @MainActor [weak self] in
            self?.transferCompletionHandler?(acknowledgement.recordingID, imported)
        }
    }

    #if os(iOS)
    public nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.publishReachability(for: session)
        }
    }

    public nonisolated func sessionDidDeactivate(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.publishReachability(for: session)
        }
        session.activate()
    }
    #endif
}
#endif
