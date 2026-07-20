import AVFoundation
import Foundation

public protocol AudioRecordingPermissionChecking: Sendable {
    func requestRecordPermission() async -> Bool
}

public struct AudioRecordingProfile: Equatable, Sendable {
    public var sampleRate: Double
    public var channelCount: Int
    public var bitRate: Int
    public var encoderQuality: AVAudioQuality

    public init(
        sampleRate: Double,
        channelCount: Int,
        bitRate: Int,
        encoderQuality: AVAudioQuality
    ) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitRate = bitRate
        self.encoderQuality = encoderQuality
    }

    public static let highQualitySpeech = AudioRecordingProfile(
        sampleRate: 44_100,
        channelCount: 1,
        bitRate: 96_000,
        encoderQuality: .high
    )

    var avFoundationSettings: [String: Any] {
        [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVEncoderBitRateKey: bitRate,
            AVEncoderAudioQualityKey: encoderQuality.rawValue
        ]
    }
}

public struct SystemAudioRecordingPermissionClient: AudioRecordingPermissionChecking {
    public init() {}

    public func requestRecordPermission() async -> Bool {
        #if os(macOS)
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
        #elseif os(iOS) || os(watchOS)
        return await withCheckedContinuation { continuation in
            if #available(iOS 17.0, watchOS 10.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
        #else
        return false
        #endif
    }
}

public enum AudioRecordingError: Error, Equatable, UserFacingIdeaForgeError {
    case permissionDenied
    case alreadyRecording
    case notRecording
    case couldNotCreateDirectory
    case storage(StoragePreflightError)
    case couldNotStart
    case pendingRecovery
    case recoveryPersistenceFailed
    case recoveryAudioMissing

    public var userFacingMessage: String {
        switch self {
        case .permissionDenied:
            return "Microphone access is required. Enable microphone permission in System Settings and try again."
        case .alreadyRecording:
            return "Recording is already running."
        case .notRecording:
            return "No active recording to stop."
        case .couldNotCreateDirectory:
            return "Recording storage could not be prepared."
        case .storage(let error):
            return error.userFacingMessage
        case .couldNotStart:
            return "Recording could not start."
        case .pendingRecovery:
            return "A previous recording must be recovered before starting another capture."
        case .recoveryPersistenceFailed:
            return "Recording recovery state could not be saved. The audio file was kept for review."
        case .recoveryAudioMissing:
            return "A previous recording checkpoint exists, but its audio file is unavailable."
        }
    }
}

@MainActor
public final class LocalAudioRecorder: NSObject {
    private var recorder: AVAudioRecorder?
    private var startedAt: Date?
    private var fileURL: URL?
    private var markerOffsets: [Int] = []
    private var captureContext: RecordingCaptureContext?
    private let storagePreflight: StoragePreflight
    private let permissionClient: any AudioRecordingPermissionChecking
    private let recoveryJournal: RecordingRecoveryJournal
    private var unexpectedTerminationHandler: (@MainActor @Sendable (RecordingTerminationReason) -> Void)?
    private nonisolated(unsafe) var interruptionObserver: NSObjectProtocol?
    private var isStoppingIntentionally = false

    public private(set) var isRecording = false

    public var normalizedPowerLevel: Double {
        guard isRecording, let recorder else { return 0 }
        recorder.updateMeters()
        return Self.normalizedPowerLevel(decibels: recorder.averagePower(forChannel: 0))
    }

    public init(
        storagePreflight: StoragePreflight = .recording(),
        permissionClient: any AudioRecordingPermissionChecking = SystemAudioRecordingPermissionClient(),
        recoveryJournal: RecordingRecoveryJournal = RecordingRecoveryJournal()
    ) {
        self.storagePreflight = storagePreflight
        self.permissionClient = permissionClient
        self.recoveryJournal = recoveryJournal
        super.init()
        installInterruptionObserver()
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    public func start(
        recoveryContext: RecordingCaptureContext = RecordingCaptureContext(
            projectTitle: "Recovered voice idea",
            tag: .appIdea,
            source: .iphone,
            transcriptHint: "Voice idea recovered after recording interruption."
        )
    ) async throws {
        guard !isRecording else {
            throw AudioRecordingError.alreadyRecording
        }
        do {
            guard try !recoveryJournal.hasCheckpoint() else {
                throw AudioRecordingError.pendingRecovery
            }
        } catch let error as AudioRecordingError {
            throw error
        } catch {
            throw AudioRecordingError.recoveryPersistenceFailed
        }

        guard await requestPermission() else {
            throw AudioRecordingError.permissionDenied
        }

        var didStartRecording = false
        defer {
            if !didStartRecording {
                deactivateAudioSession()
            }
        }

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)
        #elseif os(watchOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default)
        try session.setActive(true)
        #endif

        let directory = Self.recordingsDirectory()
        do {
            try storagePreflight.validateWritableVolume(for: directory)
        } catch let error as StoragePreflightError {
            throw AudioRecordingError.storage(error)
        }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw AudioRecordingError.couldNotCreateDirectory
        }

        let outputURL = directory.appending(path: "recording-\(UUID().uuidString).m4a")
        let audioRecorder: AVAudioRecorder
        do {
            audioRecorder = try AVAudioRecorder(
                url: outputURL,
                settings: AudioRecordingProfile.highQualitySpeech.avFoundationSettings
            )
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
        audioRecorder.delegate = self
        audioRecorder.isMeteringEnabled = true
        audioRecorder.prepareToRecord()

        let startedAt = Date()
        do {
            try recoveryJournal.begin(
                context: recoveryContext,
                localAudioURL: outputURL,
                startedAt: startedAt
            )
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw AudioRecordingError.recoveryPersistenceFailed
        }

        guard audioRecorder.record() else {
            try? recoveryJournal.acknowledgePersistence()
            try? FileManager.default.removeItem(at: outputURL)
            throw AudioRecordingError.couldNotStart
        }

        recorder = audioRecorder
        fileURL = outputURL
        self.startedAt = startedAt
        captureContext = recoveryContext
        markerOffsets = []
        isRecording = true
        didStartRecording = true
    }

    public func addMarker() throws {
        guard let startedAt else { return }
        let offset = max(Int(Date().timeIntervalSince(startedAt)), 0)
        try recoveryJournal.addMarker(at: offset)
        if !markerOffsets.contains(offset) {
            markerOffsets.append(offset)
            markerOffsets.sort()
        }
    }

    public func stop(
        projectTitle: String,
        tag: IdeaTag,
        source: IdeaSource,
        transcriptHint: String
    ) throws -> RecordingDraft {
        guard isRecording, let recorder, let startedAt, let fileURL else {
            throw AudioRecordingError.notRecording
        }

        isStoppingIntentionally = true
        recorder.stop()
        isStoppingIntentionally = false
        deactivateAudioSession()
        do {
            try recoveryJournal.markTerminated(reason: .userStopped, at: Date())
        } catch {
            resetActiveRecordingState()
            throw AudioRecordingError.recoveryPersistenceFailed
        }
        let duration = max(Int(Date().timeIntervalSince(startedAt)), 1)
        let stableContext = captureContext
        let stableMarkerOffsets = markerOffsets
        resetActiveRecordingState()

        return RecordingDraft(
            projectTitle: projectTitle,
            tag: tag,
            source: source,
            durationSeconds: duration,
            transcriptHint: transcriptHint,
            localAudioPath: fileURL.path,
            markerOffsets: stableMarkerOffsets,
            ideaProjectID: stableContext?.ideaProjectID,
            recordingID: stableContext?.recordingID
        )
    }

    public func pendingRecovery(now: Date = Date()) throws -> PendingRecordingRecovery? {
        guard !isRecording else { return nil }
        do {
            return try recoveryJournal.pendingRecovery(now: now)
        } catch RecordingRecoveryError.missingAudio {
            try? recoveryJournal.acknowledgePersistence()
            throw AudioRecordingError.recoveryAudioMissing
        } catch RecordingRecoveryError.unreadableCheckpoint {
            try? recoveryJournal.acknowledgePersistence()
            throw AudioRecordingError.recoveryPersistenceFailed
        } catch {
            throw AudioRecordingError.recoveryPersistenceFailed
        }
    }

    public func acknowledgePersistence() throws {
        do {
            try recoveryJournal.acknowledgePersistence()
        } catch {
            throw AudioRecordingError.recoveryPersistenceFailed
        }
    }

    public func setUnexpectedTerminationHandler(
        _ handler: (@MainActor @Sendable (RecordingTerminationReason) -> Void)?
    ) {
        unexpectedTerminationHandler = handler
    }

    public static func recordingsDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appending(path: "IdeaForge/Recordings", directoryHint: .isDirectory)
    }

    public nonisolated static func normalizedPowerLevel(decibels: Float) -> Double {
        guard decibels.isFinite else { return 0 }
        let clamped = min(max(Double(decibels), -60), 0)
        let linear = (clamped + 60) / 60
        return min(max(pow(linear, 1.7), 0), 1)
    }

    private func requestPermission() async -> Bool {
        await permissionClient.requestRecordPermission()
    }

    private func installInterruptionObserver() {
        #if os(iOS) || os(watchOS)
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: rawType) == .began else {
                return
            }
            Task { @MainActor [weak self] in
                self?.handleUnexpectedTermination(reason: .interrupted)
            }
        }
        #endif
    }

    private func handleUnexpectedTermination(reason: RecordingTerminationReason) {
        guard isRecording, !isStoppingIntentionally else { return }
        isRecording = false
        isStoppingIntentionally = true
        recorder?.stop()
        isStoppingIntentionally = false
        do {
            try recoveryJournal.markTerminated(reason: reason, at: Date())
        } catch {
            IdeaForgeLog.recording.error("Recording recovery checkpoint terminal update failed")
        }
        deactivateAudioSession()
        recorder = nil
        startedAt = nil
        fileURL = nil
        captureContext = nil
        markerOffsets = []
        unexpectedTerminationHandler?(reason)
    }

    private func resetActiveRecordingState() {
        recorder = nil
        startedAt = nil
        fileURL = nil
        captureContext = nil
        markerOffsets = []
        isRecording = false
    }

    private func deactivateAudioSession() {
        #if os(iOS) || os(watchOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        #endif
    }
}

extension LocalAudioRecorder: AVAudioRecorderDelegate {
    public nonisolated func audioRecorderDidFinishRecording(
        _: AVAudioRecorder,
        successfully flag: Bool
    ) {
        guard !flag else { return }
        Task { @MainActor [weak self] in
            self?.handleUnexpectedTermination(reason: .unexpectedlyFinished)
        }
    }

    public nonisolated func audioRecorderEncodeErrorDidOccur(
        _: AVAudioRecorder,
        error _: Error?
    ) {
        Task { @MainActor [weak self] in
            self?.handleUnexpectedTermination(reason: .encodingFailed)
        }
    }
}
