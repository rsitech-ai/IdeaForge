import Foundation

public enum WatchEnrichmentState: String, Codable, Equatable, Sendable {
    case waiting
    case processing
    case ready
    case needsAttention
}

public struct WatchEnrichmentProjectionItem: Codable, Equatable, Sendable {
    public var recordingID: String
    public var ideaProjectID: String
    public var title: String
    public var state: WatchEnrichmentState
    public var updatedAt: Date

    public init(
        recordingID: String,
        ideaProjectID: String,
        title: String,
        state: WatchEnrichmentState,
        updatedAt: Date
    ) {
        self.recordingID = recordingID
        self.ideaProjectID = ideaProjectID
        self.title = title
        self.state = state
        self.updatedAt = updatedAt
    }

    fileprivate var isValid: Bool {
        RecordingTransferMetadata.isSafeIdentifier(recordingID)
            && RecordingTransferMetadata.isSafeIdentifier(ideaProjectID)
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && title.count <= 120
            && updatedAt.timeIntervalSince1970.isFinite
    }
}

/// The intentionally small state mirrored from iPhone to Watch after backend sync.
/// Audio, transcript text, summaries, questions, and artifacts are never encoded here.
public struct WatchEnrichmentProjection: Codable, Equatable, Sendable {
    private static let messageType = "watchEnrichmentProjection.v1"
    private static let maximumItemCount = 24
    private static let maximumPayloadBytes = 64 * 1_024

    public var items: [WatchEnrichmentProjectionItem]
    public var updatedAt: Date

    public init(items: [WatchEnrichmentProjectionItem], updatedAt: Date) {
        self.items = Array(items.prefix(Self.maximumItemCount))
        self.updatedAt = updatedAt
    }

    public init(projects: [IdeaProject], updatedAt: Date = Date()) {
        let candidates = projects.flatMap { project in
            project.recordings.compactMap { recording -> WatchEnrichmentProjectionItem? in
                guard recording.deviceName.localizedCaseInsensitiveContains("watch") else { return nil }
                let state: WatchEnrichmentState = switch recording.syncStatus {
                case .ready: .ready
                case .transcribing: .processing
                case .failed: .needsAttention
                case .pending, .transferredToIPhone, .uploaded: .waiting
                }
                return WatchEnrichmentProjectionItem(
                    recordingID: recording.id,
                    ideaProjectID: project.id,
                    title: project.title,
                    state: state,
                    updatedAt: project.updatedAt
                )
            }
        }
        self.init(
            items: candidates
                .filter(\.isValid)
                .sorted { $0.updatedAt > $1.updatedAt },
            updatedAt: updatedAt
        )
    }

    public var applicationContext: [String: Any] {
        let payload = (try? JSONEncoder().encode(self)) ?? Data()
        return [
            "messageType": Self.messageType,
            "payload": payload,
        ]
    }

    public init?(applicationContext: [String: Any]) {
        guard applicationContext["messageType"] as? String == Self.messageType,
              let payload = applicationContext["payload"] as? Data,
              !payload.isEmpty,
              payload.count <= Self.maximumPayloadBytes,
              let decoded = try? JSONDecoder().decode(Self.self, from: payload),
              decoded.items.count <= Self.maximumItemCount,
              decoded.items.allSatisfy(\.isValid),
              decoded.updatedAt.timeIntervalSince1970.isFinite else {
            return nil
        }
        self = decoded
    }
}

extension IdeaForgeStore {
    /// Applies only the title and compact processing state delivered to Watch.
    /// The Watch's local transcript and all other project fields remain untouched.
    @MainActor
    @discardableResult
    public func apply(_ projection: WatchEnrichmentProjection) -> Int {
        let originalState = workspaceState()
        var appliedCount = 0

        for item in projection.items {
            guard let projectIndex = projects.firstIndex(where: { $0.id == item.ideaProjectID }),
                  item.updatedAt >= projects[projectIndex].updatedAt,
                  let recordingIndex = projects[projectIndex].recordings.firstIndex(where: {
                      $0.id == item.recordingID
                          && $0.deviceName.localizedCaseInsensitiveContains("watch")
                  }) else {
                continue
            }

            projects[projectIndex].title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let event: RecordingQueueEvent? = switch item.state {
            case .ready: .ready
            case .processing: .transcribing
            case .needsAttention: .transcriptionFailed
            case .waiting: nil
            }
            if let event,
               let recording = try? RecordingQueuePolicy.applying(
                   event,
                   to: projects[projectIndex].recordings[recordingIndex]
               ) {
                projects[projectIndex].recordings[recordingIndex] = recording
            }
            projects[projectIndex].updatedAt = max(projects[projectIndex].updatedAt, item.updatedAt)
            appliedCount += 1
        }

        guard appliedCount > 0 else { return 0 }
        guard save(now: max(updatedAt, projection.updatedAt)) else {
            restoreLiveState(originalState)
            return 0
        }
        return appliedCount
    }
}
