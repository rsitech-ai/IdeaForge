import Foundation

public enum WatchCaptureRelayState: String, CaseIterable, Equatable, Sendable {
    case ready
    case recording
    case saved
    case queued
    case received
    case failed
}

public enum WatchCaptureRelayPolicy {
    public static func state(
        isRecording: Bool,
        transientTransferStatus: RecordingTransferStatus,
        recordings: [Recording]
    ) -> WatchCaptureRelayState {
        if isRecording { return .recording }

        if transientTransferStatus == .failed { return .failed }

        let watchRecordings = recordings.filter {
            $0.deviceName.localizedCaseInsensitiveContains("watch")
        }
        if watchRecordings.contains(where: { $0.syncStatus == .failed }) { return .failed }
        if watchRecordings.contains(where: { $0.syncStatus == .pending }) { return .queued }
        if transientTransferStatus == .queuedForTransfer { return .queued }
        if transientTransferStatus == .received { return .received }

        guard let newestWatchRecording = watchRecordings.max(by: { $0.createdAt < $1.createdAt }) else {
            return .ready
        }

        switch newestWatchRecording.syncStatus {
        case .pending:
            return .queued
        case .failed:
            return .failed
        case .transferredToIPhone, .uploaded, .transcribing, .ready:
            return .received
        }
    }
}
