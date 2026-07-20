import Foundation

public enum RecordingTerminationReason: String, Codable, Equatable, Sendable {
    case recording
    case userStopped
    case interrupted
    case encodingFailed
    case unexpectedlyFinished
}

public struct RecordingCaptureContext: Codable, Equatable, Sendable {
    public var projectTitle: String
    public var tag: IdeaTag
    public var source: IdeaSource
    public var transcriptHint: String
    public var ideaProjectID: String
    public var recordingID: String
    public var targetProjectID: String?

    public init(
        projectTitle: String,
        tag: IdeaTag,
        source: IdeaSource,
        transcriptHint: String,
        ideaProjectID: String = "idea_\(UUID().uuidString.lowercased())",
        recordingID: String = "rec_\(UUID().uuidString.lowercased())",
        targetProjectID: String? = nil
    ) {
        self.projectTitle = projectTitle
        self.tag = tag
        self.source = source
        self.transcriptHint = transcriptHint
        self.ideaProjectID = ideaProjectID
        self.recordingID = recordingID
        self.targetProjectID = targetProjectID
    }
}

public struct RecordingRecoveryCheckpoint: Codable, Equatable, Sendable {
    public var context: RecordingCaptureContext
    public var localAudioPath: String
    public var startedAt: Date
    public var endedAt: Date?
    public var markerOffsets: [Int]
    public var terminationReason: RecordingTerminationReason
}

public struct PendingRecordingRecovery: Equatable, Sendable {
    public var draft: RecordingDraft
    public var targetProjectID: String?
    public var terminationReason: RecordingTerminationReason
}

public enum RecordingRecoveryError: Error, Equatable {
    case unreadableCheckpoint
    case unwritableCheckpoint
    case missingAudio
    case unreadableAudio
}

public protocol RecordingRecoveryCheckpointStoring: Sendable {
    func load() throws -> RecordingRecoveryCheckpoint?
    func save(_ checkpoint: RecordingRecoveryCheckpoint) throws
    func remove() throws
}

public struct FileRecordingRecoveryCheckpointStore: RecordingRecoveryCheckpointStoring {
    public var fileURL: URL

    public init(fileURL: URL = Self.defaultFileURL()) {
        self.fileURL = fileURL
    }

    public func load() throws -> RecordingRecoveryCheckpoint? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            return try JSONDecoder().decode(
                RecordingRecoveryCheckpoint.self,
                from: Data(contentsOf: fileURL)
            )
        } catch {
            throw RecordingRecoveryError.unreadableCheckpoint
        }
    }

    public func save(_ checkpoint: RecordingRecoveryCheckpoint) throws {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(checkpoint).write(to: fileURL, options: .atomic)
        } catch {
            throw RecordingRecoveryError.unwritableCheckpoint
        }
    }

    public func remove() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            throw RecordingRecoveryError.unwritableCheckpoint
        }
    }

    public static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appending(
            path: "IdeaForge/Recordings/active-recording.json",
            directoryHint: .notDirectory
        )
    }
}

public struct RecordingRecoveryJournal: Sendable {
    public var store: any RecordingRecoveryCheckpointStoring

    public init(store: any RecordingRecoveryCheckpointStoring = FileRecordingRecoveryCheckpointStore()) {
        self.store = store
    }

    public func begin(
        context: RecordingCaptureContext,
        localAudioURL: URL,
        startedAt: Date
    ) throws {
        try store.save(
            RecordingRecoveryCheckpoint(
                context: context,
                localAudioPath: localAudioURL.path,
                startedAt: startedAt,
                endedAt: nil,
                markerOffsets: [],
                terminationReason: .recording
            )
        )
    }

    public func addMarker(at offset: Int) throws {
        guard var checkpoint = try store.load() else { return }
        let normalizedOffset = max(offset, 0)
        if !checkpoint.markerOffsets.contains(normalizedOffset) {
            checkpoint.markerOffsets.append(normalizedOffset)
            checkpoint.markerOffsets.sort()
        }
        try store.save(checkpoint)
    }

    public func markTerminated(reason: RecordingTerminationReason, at endedAt: Date) throws {
        guard var checkpoint = try store.load() else { return }
        checkpoint.endedAt = endedAt
        checkpoint.terminationReason = reason
        try store.save(checkpoint)
    }

    public func pendingRecovery(
        now: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> PendingRecordingRecovery? {
        guard let checkpoint = try store.load() else { return nil }
        guard fileManager.fileExists(atPath: checkpoint.localAudioPath) else {
            throw RecordingRecoveryError.missingAudio
        }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: checkpoint.localAudioPath)
        } catch {
            throw RecordingRecoveryError.unreadableAudio
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let byteCount = attributes[.size] as? NSNumber,
              byteCount.int64Value > 0
        else {
            throw RecordingRecoveryError.missingAudio
        }

        let modificationDate = attributes[.modificationDate] as? Date
        let effectiveEnd = checkpoint.endedAt ?? modificationDate ?? now
        let duration = max(Int(effectiveEnd.timeIntervalSince(checkpoint.startedAt)), 1)
        return PendingRecordingRecovery(
            draft: RecordingDraft(
                projectTitle: checkpoint.context.projectTitle,
                tag: checkpoint.context.tag,
                source: checkpoint.context.source,
                durationSeconds: duration,
                transcriptHint: checkpoint.context.transcriptHint,
                localAudioPath: checkpoint.localAudioPath,
                markerOffsets: checkpoint.markerOffsets,
                ideaProjectID: checkpoint.context.ideaProjectID,
                recordingID: checkpoint.context.recordingID
            ),
            targetProjectID: checkpoint.context.targetProjectID,
            terminationReason: checkpoint.terminationReason
        )
    }

    public func acknowledgePersistence() throws {
        try store.remove()
    }

    public func hasCheckpoint() throws -> Bool {
        try store.load() != nil
    }
}
