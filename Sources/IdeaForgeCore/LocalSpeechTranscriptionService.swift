import Foundation
#if canImport(Speech) && !os(watchOS)
@preconcurrency import Speech
#endif

public enum LocalSpeechAuthorizationStatus: String, Equatable, Sendable {
    case authorized
    case denied
    case restricted
    case notDetermined
}

public protocol LocalSpeechAuthorizationChecking: Sendable {
    func requestSpeechRecognitionAuthorization() async -> LocalSpeechAuthorizationStatus
}

public protocol LocalSpeechAudioTranscribing: Sendable {
    func transcribeAudio(at url: URL, localeIdentifier: String) async throws -> String
}

public protocol LocalSpeechAudioFileChecking: Sendable {
    func fileExists(atPath path: String) -> Bool
}

public struct SystemSpeechAudioFileChecker: LocalSpeechAudioFileChecking {
    public init() {}

    public func fileExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}

public enum LocalSpeechTranscriptionError: Error, Equatable, UserFacingIdeaForgeError {
    case missingLocalAudio
    case audioFileUnavailable
    case authorizationDenied(LocalSpeechAuthorizationStatus)
    case recognizerUnavailable
    case recognitionTimedOut
    case emptyRecognition

    public var userFacingMessage: String {
        switch self {
        case .missingLocalAudio:
            return "Local speech transcription needs the original audio file on this device."
        case .audioFileUnavailable:
            return "The local audio file is no longer available. Sync the recording again and retry."
        case .authorizationDenied(.denied), .authorizationDenied(.restricted):
            return "Speech recognition is not available. Enable speech recognition access and retry."
        case .authorizationDenied(.notDetermined):
            return "Speech recognition access has not been granted yet."
        case .authorizationDenied(.authorized):
            return "Speech recognition could not start."
        case .recognizerUnavailable:
            return "Speech recognition is unavailable for this language or device right now."
        case .recognitionTimedOut:
            return "Speech recognition took too long. Try again with a shorter recording or use cloud transcription."
        case .emptyRecognition:
            return "Speech recognition did not return usable text. Try recording again or use cloud transcription."
        }
    }
}

public struct LocalSpeechTranscriptionService: TranscriptionService {
    public var authorizer: any LocalSpeechAuthorizationChecking
    public var transcriber: any LocalSpeechAudioTranscribing
    public var audioFileChecker: any LocalSpeechAudioFileChecking
    public var recognitionTimeoutSeconds: UInt64

    public init(
        authorizer: any LocalSpeechAuthorizationChecking = SystemSpeechAuthorizationClient(),
        transcriber: any LocalSpeechAudioTranscribing = SystemSpeechAudioTranscriber(),
        audioFileChecker: any LocalSpeechAudioFileChecking = SystemSpeechAudioFileChecker(),
        recognitionTimeoutSeconds: UInt64 = 120
    ) {
        self.authorizer = authorizer
        self.transcriber = transcriber
        self.audioFileChecker = audioFileChecker
        self.recognitionTimeoutSeconds = recognitionTimeoutSeconds
    }

    public func transcript(for recording: Recording, hint: String) async throws -> Transcript {
        guard let audioPath = recording.localAudioPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !audioPath.isEmpty else {
            throw LocalSpeechTranscriptionError.missingLocalAudio
        }

        let audioURL = URL(fileURLWithPath: audioPath)
        guard audioFileChecker.fileExists(atPath: audioURL.path) else {
            throw LocalSpeechTranscriptionError.audioFileUnavailable
        }

        let authorization = await authorizer.requestSpeechRecognitionAuthorization()
        guard authorization == .authorized else {
            throw LocalSpeechTranscriptionError.authorizationDenied(authorization)
        }

        let localeIdentifier = recording.languageHint.trimmingCharacters(in: .whitespacesAndNewlines)
        let transcriber = transcriber
        let recognizedText = try await Self.withRecognitionTimeout(seconds: recognitionTimeoutSeconds) {
            try await transcriber.transcribeAudio(
                at: audioURL,
                localeIdentifier: localeIdentifier.isEmpty ? "en" : localeIdentifier
            )
        }
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !recognizedText.isEmpty else {
            throw LocalSpeechTranscriptionError.emptyRecognition
        }

        return Transcript(
            cleanText: recognizedText,
            segments: [
                TranscriptSegment(
                    id: "segment_\(recording.id)",
                    startSeconds: 0,
                    endSeconds: max(recording.durationSeconds, 1),
                    text: recognizedText,
                    isMarkedImportant: !recording.markerOffsets.isEmpty
                )
            ],
            unclearFragments: []
        )
    }

    private static func withRecognitionTimeout(
        seconds: UInt64,
        operation: @escaping @Sendable () async throws -> String
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                throw LocalSpeechTranscriptionError.recognitionTimedOut
            }

            guard let result = try await group.next() else {
                throw LocalSpeechTranscriptionError.recognitionTimedOut
            }
            group.cancelAll()
            return result
        }
    }
}

#if canImport(Speech) && !os(watchOS)
public struct SystemSpeechAuthorizationClient: LocalSpeechAuthorizationChecking {
    public init() {}

    public func requestSpeechRecognitionAuthorization() async -> LocalSpeechAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                switch status {
                case .authorized:
                    continuation.resume(returning: .authorized)
                case .denied:
                    continuation.resume(returning: .denied)
                case .restricted:
                    continuation.resume(returning: .restricted)
                case .notDetermined:
                    continuation.resume(returning: .notDetermined)
                @unknown default:
                    continuation.resume(returning: .restricted)
                }
            }
        }
    }
}

public struct SystemSpeechAudioTranscriber: LocalSpeechAudioTranscribing {
    public init() {}

    public func transcribeAudio(at url: URL, localeIdentifier: String) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
              recognizer.isAvailable else {
            throw LocalSpeechTranscriptionError.recognizerUnavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = false

        let holder = SpeechRecognitionContinuationHolder()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let box = SpeechRecognitionContinuationBox(continuation: continuation)
                holder.install(box)
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let error {
                        box.finish(.failure(error))
                        return
                    }

                    guard let result, result.isFinal else { return }
                    box.finish(.success(result.bestTranscription.formattedString))
                }
                box.install(task: task)
            }
        } onCancel: {
            holder.cancel()
        }
    }
}

private final class SpeechRecognitionContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    private var task: SFSpeechRecognitionTask?

    init(continuation: CheckedContinuation<String, Error>) {
        self.continuation = continuation
    }

    func install(task: SFSpeechRecognitionTask) {
        lock.lock()
        guard continuation != nil else {
            lock.unlock()
            task.cancel()
            return
        }
        self.task = task
        lock.unlock()
    }

    func finish(_ result: Result<String, Error>) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        let task = task
        self.task = nil
        lock.unlock()

        guard let continuation else { return }
        task?.cancel()
        continuation.resume(with: result)
    }
}

private final class SpeechRecognitionContinuationHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var box: SpeechRecognitionContinuationBox?
    private var isCancelled = false

    func install(_ box: SpeechRecognitionContinuationBox) {
        lock.lock()
        if isCancelled {
            lock.unlock()
            box.finish(.failure(CancellationError()))
            return
        }
        self.box = box
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let box = box
        self.box = nil
        lock.unlock()
        box?.finish(.failure(CancellationError()))
    }
}
#else
public struct SystemSpeechAuthorizationClient: LocalSpeechAuthorizationChecking {
    public init() {}

    public func requestSpeechRecognitionAuthorization() async -> LocalSpeechAuthorizationStatus {
        .restricted
    }
}

public struct SystemSpeechAudioTranscriber: LocalSpeechAudioTranscribing {
    public init() {}

    public func transcribeAudio(at url: URL, localeIdentifier: String) async throws -> String {
        throw LocalSpeechTranscriptionError.recognizerUnavailable
    }
}
#endif
