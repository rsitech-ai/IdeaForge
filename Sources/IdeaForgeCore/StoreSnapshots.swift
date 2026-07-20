import Foundation

public enum WorkspaceLiveHealthTone: String, Equatable, Sendable {
    case ready
    case active
    case needsReview
    case syncConflict
    case offline
    case localFirst
}

private func mobileCountLabel(_ count: Int, singular: String, plural: String) -> String {
    "\(count) \(count == 1 ? singular : plural)"
}

public struct MobileDashboardSnapshot: Equatable, Sendable {
    public var watchReachable: Bool
    public var queuedUploadCount: Int
    public var failedUploadCount: Int
    public var pendingQuestionCount: Int
    public var blockingQuestionCount: Int
    public var privacyMode: PrivacyMode
    public var featuredProjectTitle: String?
    public var liveHealthTone: WorkspaceLiveHealthTone
    public var liveHealthTitle: String
    public var liveHealthDetail: String
    public var isLiveActivityActive: Bool

    public init(
        projects: [IdeaProject],
        syncHealth: SyncHealth,
        privacyMode: PrivacyMode,
        uploadJobs: [UploadJob] = []
    ) {
        let uploadSummary = CanonicalUploadSummary(
            projects: projects,
            uploadJobs: uploadJobs,
            syncHealth: syncHealth
        )
        let questions = projects.flatMap(\.questions).filter { $0.answer == nil }

        watchReachable = syncHealth.watchReachable
        queuedUploadCount = uploadSummary.queuedCount
        failedUploadCount = uploadSummary.permanentlyFailedCount
        pendingQuestionCount = questions.count
        blockingQuestionCount = questions.filter(\.isBlocking).count
        self.privacyMode = privacyMode
        featuredProjectTitle = projects.first { $0.status == .readyForBuild }?.title ?? projects.first?.title

        if let syncConflictStatus = syncHealth.syncConflictStatus {
            liveHealthTone = .syncConflict
            liveHealthTitle = "Sync conflict blocked"
            liveHealthDetail = syncConflictStatus.recoveryAction
            isLiveActivityActive = true
        } else if failedUploadCount > 0 {
            liveHealthTone = .needsReview
            liveHealthTitle = "Review needed"
            liveHealthDetail = "\(mobileCountLabel(failedUploadCount, singular: "failed item", plural: "failed items")) \(failedUploadCount == 1 ? "needs" : "need") review before sync is clean."
            isLiveActivityActive = true
        } else if queuedUploadCount > 0 {
            liveHealthTone = .active
            liveHealthTitle = "Upload queue active"
            liveHealthDetail = "\(mobileCountLabel(queuedUploadCount, singular: "capture", plural: "captures")) \(queuedUploadCount == 1 ? "is" : "are") moving through the workspace."
            isLiveActivityActive = true
        } else if blockingQuestionCount > 0 {
            liveHealthTone = .active
            liveHealthTitle = "Decisions waiting"
            liveHealthDetail = "\(mobileCountLabel(blockingQuestionCount, singular: "blocking question", plural: "blocking questions")) \(blockingQuestionCount == 1 ? "needs an answer" : "need answers") before handoff."
            isLiveActivityActive = true
        } else if !watchReachable {
            liveHealthTone = .offline
            liveHealthTitle = "Watch offline"
            liveHealthDetail = "Capture still works locally; reconnect Watch sync when available."
            isLiveActivityActive = false
        } else if privacyMode == .privateLocal {
            liveHealthTone = .localFirst
            liveHealthTitle = "Local-first"
            liveHealthDetail = "Private mode is keeping capture and review on device."
            isLiveActivityActive = false
        } else {
            liveHealthTone = .ready
            liveHealthTitle = "Workspace ready"
            liveHealthDetail = "Sync, review, and export surfaces are clean."
            isLiveActivityActive = false
        }
    }
}

public struct MobileSyncReadinessSnapshot: Equatable, Sendable {
    public var title: String
    public var detail: String
    public var nextStepTitle: String
    public var nextStepDetail: String
    public var nextStepActionTitle: String
    public var nextStepSystemImage: String
    public var watchStatus: String
    public var iPhoneStatus: String
    public var backendStatus: String
    public var macStatus: String
    public var queuedCaptureCount: Int
    public var failedItemCount: Int
    public var hasSyncConflict: Bool
    public var tone: WorkspaceLiveHealthTone
    public var isLive: Bool
    public var timelineSteps: [MobileSyncTimelineStep]

    public init(
        projects: [IdeaProject],
        syncHealth: SyncHealth,
        privacyMode: PrivacyMode,
        uploadJobs: [UploadJob] = []
    ) {
        let uploadSummary = CanonicalUploadSummary(
            projects: projects,
            uploadJobs: uploadJobs,
            syncHealth: syncHealth
        )
        let queuedCaptures = uploadSummary.queuedCount
        let failedItems = uploadSummary.permanentlyFailedCount
        let failedItemLabel = mobileCountLabel(failedItems, singular: "failed item", plural: "failed items")
        let queuedCaptureLabel = mobileCountLabel(queuedCaptures, singular: "local capture", plural: "local captures")
        let hasRemoteReceipt = syncHealth.lastRemoteWorkspaceUpdatedAt != nil

        watchStatus = syncHealth.watchReachable ? "Linked" : "Offline"
        iPhoneStatus = queuedCaptures == 0 ? "Clean" : "\(queuedCaptures) local"
        queuedCaptureCount = queuedCaptures
        failedItemCount = failedItems
        hasSyncConflict = syncHealth.syncConflictStatus != nil

        if let conflict = syncHealth.syncConflictStatus {
            title = "Review sync before publishing"
            detail = "\(conflict.recoveryAction) Automatic background publish is paused."
            nextStepTitle = "Review and merge local choices"
            nextStepDetail = "Automatic publish stays paused until Account review confirms what local work to keep."
            nextStepActionTitle = "Review in Account"
            nextStepSystemImage = "exclamationmark.triangle.fill"
            backendStatus = "Review"
            macStatus = "Blocked"
            tone = .syncConflict
            isLive = true
        } else if failedItems > 0 {
            title = "Resolve failed sync items"
            detail = "\(failedItemLabel) \(failedItems == 1 ? "needs" : "need") review before Mac handoff resumes."
            nextStepTitle = "Fix failed sync items"
            nextStepDetail = "Review uploads before Mac handoff."
            nextStepActionTitle = "Open Account"
            nextStepSystemImage = "wrench.and.screwdriver.fill"
            backendStatus = hasRemoteReceipt ? "Published" : "Pending"
            macStatus = "Blocked"
            tone = .needsReview
            isLive = true
        } else if queuedCaptures > 0 {
            title = "Captures waiting to sync"
            detail = "\(queuedCaptureLabel) will publish after upload work is safe."
            nextStepTitle = "Upload, then publish"
            nextStepDetail = "\(queuedCaptureLabel) \(queuedCaptures == 1 ? "needs" : "need") upload first."
            nextStepActionTitle = "Open sync controls"
            nextStepSystemImage = "icloud.and.arrow.up.fill"
            backendStatus = hasRemoteReceipt ? "Published" : "Pending"
            macStatus = "Waiting"
            tone = .active
            isLive = true
        } else if hasRemoteReceipt {
            title = "Workspace published"
            detail = "Latest local snapshot has a backend receipt for iPhone, Watch, and Mac handoff."
            nextStepTitle = "Ready on Mac"
            nextStepDetail = "The latest iPhone workspace receipt is available for Mac handoff."
            nextStepActionTitle = "Refresh if needed"
            nextStepSystemImage = "checkmark.icloud.fill"
            backendStatus = "Published"
            macStatus = "Ready"
            tone = .ready
            isLive = false
        } else if privacyMode == .privateLocal {
            title = "Local-only workspace"
            detail = "Recordings stay on-device until you enable backend sync."
            nextStepTitle = "Enable backend when ready"
            nextStepDetail = "iPhone can keep recording offline; Mac sync starts after backend setup."
            nextStepActionTitle = "Configure sync"
            nextStepSystemImage = "lock.icloud.fill"
            backendStatus = "Local-only"
            macStatus = "Local"
            tone = .localFirst
            isLive = false
        } else {
            title = "Ready to publish"
            detail = "No local blockers; publish manually or during the next background refresh."
            nextStepTitle = "Publish when ready"
            nextStepDetail = "No blockers on this iPhone; publish now or let background refresh handle it."
            nextStepActionTitle = "Publish workspace"
            nextStepSystemImage = "arrow.triangle.2.circlepath.circle.fill"
            backendStatus = "Pending"
            macStatus = "Waiting"
            tone = .ready
            isLive = false
        }

        timelineSteps = Self.timelineSteps(
            watchReachable: syncHealth.watchReachable,
            queuedCaptures: queuedCaptures,
            failedItems: failedItems,
            hasSyncConflict: syncHealth.syncConflictStatus != nil,
            hasRemoteReceipt: hasRemoteReceipt,
            privacyMode: privacyMode
        )
    }

    private static func timelineSteps(
        watchReachable: Bool,
        queuedCaptures: Int,
        failedItems: Int,
        hasSyncConflict: Bool,
        hasRemoteReceipt: Bool,
        privacyMode: PrivacyMode
    ) -> [MobileSyncTimelineStep] {
        [
            MobileSyncTimelineStep(
                id: "watch",
                title: "Watch",
                statusLabel: watchReachable ? "linked" : "offline",
                detail: watchReachable ? "Ready to hand recordings to iPhone." : "Offline capture still works locally.",
                systemImage: watchReachable ? "applewatch.radiowaves.left.and.right" : "applewatch.slash",
                tone: watchReachable ? .ready : .offline,
                isCurrent: !watchReachable,
                isBlocked: false
            ),
            MobileSyncTimelineStep(
                id: "iphone",
                title: "iPhone",
                statusLabel: iPhoneTimelineStatus(queuedCaptures: queuedCaptures, failedItems: failedItems),
                detail: iPhoneTimelineDetail(queuedCaptures: queuedCaptures, failedItems: failedItems),
                systemImage: "iphone",
                tone: failedItems > 0 || hasSyncConflict ? .needsReview : (queuedCaptures > 0 ? .active : .ready),
                isCurrent: queuedCaptures > 0 || failedItems > 0 || hasSyncConflict,
                isBlocked: false
            ),
            MobileSyncTimelineStep(
                id: "backend",
                title: "Backend",
                statusLabel: backendTimelineStatus(
                    hasSyncConflict: hasSyncConflict,
                    failedItems: failedItems,
                    hasRemoteReceipt: hasRemoteReceipt,
                    privacyMode: privacyMode
                ),
                detail: backendTimelineDetail(
                    hasSyncConflict: hasSyncConflict,
                    failedItems: failedItems,
                    queuedCaptures: queuedCaptures,
                    hasRemoteReceipt: hasRemoteReceipt,
                    privacyMode: privacyMode
                ),
                systemImage: backendTimelineSystemImage(hasRemoteReceipt: hasRemoteReceipt, privacyMode: privacyMode),
                tone: backendTimelineTone(
                    hasSyncConflict: hasSyncConflict,
                    failedItems: failedItems,
                    hasRemoteReceipt: hasRemoteReceipt,
                    privacyMode: privacyMode
                ),
                isCurrent: !hasRemoteReceipt && privacyMode != .privateLocal && !hasSyncConflict,
                isBlocked: hasSyncConflict || failedItems > 0 || privacyMode == .privateLocal
            ),
            MobileSyncTimelineStep(
                id: "mac",
                title: "Mac",
                statusLabel: macTimelineStatus(
                    hasSyncConflict: hasSyncConflict,
                    failedItems: failedItems,
                    queuedCaptures: queuedCaptures,
                    hasRemoteReceipt: hasRemoteReceipt,
                    privacyMode: privacyMode
                ),
                detail: macTimelineDetail(
                    hasSyncConflict: hasSyncConflict,
                    failedItems: failedItems,
                    queuedCaptures: queuedCaptures,
                    hasRemoteReceipt: hasRemoteReceipt,
                    privacyMode: privacyMode
                ),
                systemImage: "macbook",
                tone: macTimelineTone(
                    hasSyncConflict: hasSyncConflict,
                    failedItems: failedItems,
                    queuedCaptures: queuedCaptures,
                    hasRemoteReceipt: hasRemoteReceipt,
                    privacyMode: privacyMode
                ),
                isCurrent: hasRemoteReceipt && failedItems == 0 && !hasSyncConflict,
                isBlocked: hasSyncConflict || failedItems > 0 || privacyMode == .privateLocal
            )
        ]
    }

    private static func iPhoneTimelineStatus(queuedCaptures: Int, failedItems: Int) -> String {
        if failedItems > 0 {
            return "review"
        }
        return queuedCaptures > 0 ? "\(queuedCaptures) queued" : "clean"
    }

    private static func iPhoneTimelineDetail(queuedCaptures: Int, failedItems: Int) -> String {
        if failedItems > 0 {
            return "\(mobileCountLabel(failedItems, singular: "failed item", plural: "failed items")) need review before sync continues."
        }
        if queuedCaptures > 0 {
            return "\(mobileCountLabel(queuedCaptures, singular: "capture", plural: "captures")) waiting for safe upload."
        }
        return "No local upload blockers on this iPhone."
    }

    private static func backendTimelineStatus(
        hasSyncConflict: Bool,
        failedItems: Int,
        hasRemoteReceipt: Bool,
        privacyMode: PrivacyMode
    ) -> String {
        if hasSyncConflict { return "review" }
        if failedItems > 0 { return "blocked" }
        if privacyMode == .privateLocal { return "local" }
        return hasRemoteReceipt ? "published" : "pending"
    }

    private static func backendTimelineDetail(
        hasSyncConflict: Bool,
        failedItems: Int,
        queuedCaptures: Int,
        hasRemoteReceipt: Bool,
        privacyMode: PrivacyMode
    ) -> String {
        if hasSyncConflict {
            return "Conflict review must choose what local work to keep."
        }
        if failedItems > 0 {
            return "Backend publish stays blocked until failures are reviewed."
        }
        if privacyMode == .privateLocal {
            return "Private mode keeps backend publish off."
        }
        if hasRemoteReceipt {
            return "Latest workspace has a backend receipt."
        }
        if queuedCaptures > 0 {
            return "Publishes after queued capture upload is safe."
        }
        return "Ready for manual or background publish."
    }

    private static func backendTimelineSystemImage(
        hasRemoteReceipt: Bool,
        privacyMode: PrivacyMode
    ) -> String {
        if privacyMode == .privateLocal {
            return "lock.icloud"
        }
        return hasRemoteReceipt ? "checkmark.icloud" : "icloud"
    }

    private static func backendTimelineTone(
        hasSyncConflict: Bool,
        failedItems: Int,
        hasRemoteReceipt: Bool,
        privacyMode: PrivacyMode
    ) -> WorkspaceLiveHealthTone {
        if hasSyncConflict { return .syncConflict }
        if failedItems > 0 { return .needsReview }
        if privacyMode == .privateLocal { return .localFirst }
        return hasRemoteReceipt ? .ready : .active
    }

    private static func macTimelineStatus(
        hasSyncConflict: Bool,
        failedItems: Int,
        queuedCaptures: Int,
        hasRemoteReceipt: Bool,
        privacyMode: PrivacyMode
    ) -> String {
        if hasSyncConflict || failedItems > 0 { return "blocked" }
        if privacyMode == .privateLocal { return "local" }
        if queuedCaptures > 0 { return "waiting" }
        return hasRemoteReceipt ? "ready" : "waiting"
    }

    private static func macTimelineDetail(
        hasSyncConflict: Bool,
        failedItems: Int,
        queuedCaptures: Int,
        hasRemoteReceipt: Bool,
        privacyMode: PrivacyMode
    ) -> String {
        if hasSyncConflict {
            return "Mac handoff resumes after conflict review."
        }
        if failedItems > 0 {
            return "Mac handoff waits for failed sync review."
        }
        if privacyMode == .privateLocal {
            return "Mac handoff stays local until backend sync is enabled."
        }
        if queuedCaptures > 0 {
            return "Mac waits until iPhone publishes the workspace."
        }
        if hasRemoteReceipt {
            return "Workspace is ready for Mac review and build packets."
        }
        return "Publish this iPhone workspace before Mac handoff."
    }

    private static func macTimelineTone(
        hasSyncConflict: Bool,
        failedItems: Int,
        queuedCaptures: Int,
        hasRemoteReceipt: Bool,
        privacyMode: PrivacyMode
    ) -> WorkspaceLiveHealthTone {
        if hasSyncConflict { return .syncConflict }
        if failedItems > 0 { return .needsReview }
        if privacyMode == .privateLocal { return .localFirst }
        if queuedCaptures > 0 { return .active }
        return hasRemoteReceipt ? .ready : .active
    }
}

public struct MobileSyncTimelineStep: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var statusLabel: String
    public var detail: String
    public var systemImage: String
    public var tone: WorkspaceLiveHealthTone
    public var isCurrent: Bool
    public var isBlocked: Bool

    public init(
        id: String,
        title: String,
        statusLabel: String,
        detail: String,
        systemImage: String,
        tone: WorkspaceLiveHealthTone,
        isCurrent: Bool,
        isBlocked: Bool
    ) {
        self.id = id
        self.title = title
        self.statusLabel = statusLabel
        self.detail = detail
        self.systemImage = systemImage
        self.tone = tone
        self.isCurrent = isCurrent
        self.isBlocked = isBlocked
    }
}

public struct MobileSyncTrustSnapshot: Equatable, Sendable {
    public var title: String
    public var detail: String
    public var localStatus: String
    public var receiptStatus: String
    public var macHandoffStatus: String
    public var blockerStatus: String
    public var actionTitle: String
    public var systemImage: String
    public var tone: WorkspaceLiveHealthTone
    public var isLive: Bool

    public init(
        state: WorkspaceState,
        readiness: MobileSyncReadinessSnapshot,
        plan: MobileWorkspaceSyncPlanSnapshot
    ) {
        localStatus = Self.localStatus(readiness: readiness)
        receiptStatus = Self.receiptStatus(state: state, readiness: readiness, plan: plan)
        macHandoffStatus = plan.handoffStatusLabel
        blockerStatus = Self.blockerStatus(state: state, readiness: readiness, plan: plan)
        isLive = readiness.isLive || plan.isLive

        if readiness.hasSyncConflict {
            title = "Review before sync"
            detail = "Choose what local iPhone work to keep before publishing to backend or Mac."
            actionTitle = "Review"
            systemImage = "exclamationmark.triangle.fill"
            tone = .syncConflict
        } else if readiness.failedItemCount > 0 {
            title = "Fix failed sync"
            detail = readiness.detail
            actionTitle = "Fix"
            systemImage = "wrench.and.screwdriver.fill"
            tone = .needsReview
        } else if state.privacyMode == .privateLocal {
            title = "Local-only by design"
            detail = "iPhone can keep capturing offline; Mac handoff starts after backend sync is enabled."
            actionTitle = "Enable"
            systemImage = "lock.icloud.fill"
            tone = .localFirst
        } else if let blocker = plan.blocker {
            title = Self.blockerTitle(for: blocker)
            detail = plan.handoffDetail
            actionTitle = plan.actionTitle
            systemImage = plan.systemImage
            tone = plan.tone
        } else if readiness.queuedCaptureCount > 0 {
            title = "Upload before handoff"
            detail = "Queued iPhone or Watch captures must upload before the workspace receipt is trusted on Mac."
            actionTitle = "Upload"
            systemImage = "tray.and.arrow.up.fill"
            tone = .active
        } else if let remoteUpdatedAt = state.syncHealth.lastRemoteWorkspaceUpdatedAt {
            if state.updatedAt <= remoteUpdatedAt {
                title = "Trusted handoff"
                detail = "Backend receipt is current; Mac can refresh this workspace."
                actionTitle = "Refresh"
                systemImage = "checkmark.icloud.fill"
                tone = .ready
            } else {
                title = "Publish iPhone changes"
                detail = plan.handoffDetail
                actionTitle = "Publish"
                systemImage = "arrow.triangle.2.circlepath.circle.fill"
                tone = .active
                isLive = true
            }
        } else {
            title = "First publish needed"
            detail = plan.handoffDetail
            actionTitle = "Publish"
            systemImage = "icloud.and.arrow.up.fill"
            tone = .active
            isLive = true
        }
    }

    private static func localStatus(readiness: MobileSyncReadinessSnapshot) -> String {
        if readiness.hasSyncConflict { return "Review" }
        if readiness.failedItemCount > 0 {
            return "Fix \(readiness.failedItemCount)"
        }
        if readiness.queuedCaptureCount > 0 {
            return "Upload \(readiness.queuedCaptureCount)"
        }
        return "Clean"
    }

    private static func receiptStatus(
        state: WorkspaceState,
        readiness: MobileSyncReadinessSnapshot,
        plan: MobileWorkspaceSyncPlanSnapshot
    ) -> String {
        if readiness.hasSyncConflict { return "Paused" }
        if state.privacyMode == .privateLocal { return "Local-only" }

        switch plan.blocker {
        case .missingConfiguration, .invalidConfiguration:
            return "Setup"
        case .capabilityGate:
            return "Validate"
        case .requestFailed:
            return "Retry"
        case .activeUploadWork:
            return "Waiting"
        case .failedUploadWork:
            return "Blocked"
        case .privateLocalMode:
            return "Local-only"
        case .syncConflict:
            return "Paused"
        case .none:
            break
        }

        guard let remoteUpdatedAt = state.syncHealth.lastRemoteWorkspaceUpdatedAt else {
            return "No receipt"
        }
        return state.updatedAt <= remoteUpdatedAt ? "Receipted" : "Outdated"
    }

    private static func blockerStatus(
        state: WorkspaceState,
        readiness: MobileSyncReadinessSnapshot,
        plan: MobileWorkspaceSyncPlanSnapshot
    ) -> String {
        if readiness.hasSyncConflict { return "Conflict" }
        if readiness.failedItemCount > 0 { return "Failed items" }
        if readiness.queuedCaptureCount > 0 { return "Upload first" }
        if state.privacyMode == .privateLocal { return "Private" }
        if let blocker = plan.blocker {
            switch blocker {
            case .missingConfiguration, .invalidConfiguration:
                return "Setup"
            case .capabilityGate:
                return "Session"
            case .requestFailed:
                return "Retry"
            case .activeUploadWork:
                return "Uploads"
            case .failedUploadWork:
                return "Failures"
            case .privateLocalMode:
                return "Private"
            case .syncConflict:
                return "Conflict"
            }
        }
        return "Clear"
    }

    private static func blockerTitle(for blocker: WorkspaceAutoSyncBlocker) -> String {
        switch blocker {
        case .missingConfiguration, .invalidConfiguration:
            return "Backend setup needed"
        case .capabilityGate:
            return "Validate backend trust"
        case .requestFailed:
            return "Sync retry needed"
        case .activeUploadWork:
            return "Uploads in progress"
        case .failedUploadWork:
            return "Failed uploads block sync"
        case .privateLocalMode:
            return "Local-only by design"
        case .syncConflict:
            return "Review before sync"
        }
    }
}

public struct MobileWorkspaceSyncPlanSnapshot: Equatable, Sendable {
    public var title: String
    public var detail: String
    public var statusLabel: String
    public var actionTitle: String
    public var handoffTitle: String
    public var handoffDetail: String
    public var handoffStatusLabel: String
    public var systemImage: String
    public var tone: WorkspaceLiveHealthTone
    public var isLive: Bool
    public var blocker: WorkspaceAutoSyncBlocker?

    public init(
        state: WorkspaceState,
        capabilityDecision: BackendCapabilityDecision
    ) {
        let decision = WorkspaceAutoSyncPolicy.decision(
            for: state,
            capabilityDecision: capabilityDecision
        )
        switch decision {
        case .publishLocalSnapshot(let message):
            title = "Auto-sync ready"
            detail = message
            statusLabel = "Will publish"
            actionTitle = "Publish now"
            systemImage = "arrow.triangle.2.circlepath.circle.fill"
            tone = .ready
            isLive = false
            blocker = nil
        case .idle(let message):
            title = "Auto-sync clean"
            detail = message
            statusLabel = "Receipted"
            actionTitle = "Refresh if needed"
            systemImage = "checkmark.icloud.fill"
            tone = .ready
            isLive = false
            blocker = nil
        case .blocked(let blocker, let message):
            self.blocker = blocker
            detail = message
            switch blocker {
            case .missingConfiguration, .invalidConfiguration:
                title = "Configure backend"
                statusLabel = "Setup needed"
                actionTitle = "Open settings"
                systemImage = "gearshape.fill"
                tone = .offline
                isLive = false
            case .capabilityGate:
                title = "Validate backend"
                statusLabel = "Needs session"
                actionTitle = "Validate"
                systemImage = "person.badge.key.fill"
                tone = .offline
                isLive = false
            case .privateLocalMode:
                title = "Auto-sync off"
                statusLabel = "Private"
                actionTitle = "Enable sync"
                systemImage = "lock.icloud.fill"
                tone = .localFirst
                isLive = false
            case .syncConflict:
                title = "Auto-sync paused"
                statusLabel = "Review"
                actionTitle = "Review conflict"
                systemImage = "exclamationmark.triangle.fill"
                tone = .syncConflict
                isLive = true
            case .activeUploadWork:
                title = "Waiting for uploads"
                statusLabel = "Queue"
                actionTitle = "Upload first"
                systemImage = "tray.and.arrow.up.fill"
                tone = .active
                isLive = true
            case .failedUploadWork:
                title = "Auto-sync paused"
                statusLabel = "Review failed"
                actionTitle = "Review failed"
                systemImage = "wrench.and.screwdriver.fill"
                tone = .needsReview
                isLive = true
            case .requestFailed:
                title = "Auto-sync failed"
                statusLabel = "Retry"
                actionTitle = "Try again"
                systemImage = "arrow.clockwise.circle.fill"
                tone = .needsReview
                isLive = true
            }
        }

        let hasReceipt = state.syncHealth.lastRemoteWorkspaceUpdatedAt != nil
        switch decision {
        case .idle:
            handoffTitle = "Backend receipt ready"
            handoffDetail = "Mac can refresh this workspace without waiting for another iPhone publish."
            handoffStatusLabel = "Ready"
        case .publishLocalSnapshot:
            handoffTitle = hasReceipt ? "Local changes pending" : "First publish pending"
            handoffDetail = hasReceipt
                ? "This iPhone changed after the last backend receipt; publish before Mac refresh."
                : "No backend receipt exists yet; publish once to make this workspace available to Mac."
            handoffStatusLabel = "Pending"
        case .blocked(let blocker, _):
            switch blocker {
            case .syncConflict:
                handoffTitle = "Review required"
                handoffDetail = "Mac handoff stays paused until Account review confirms the local work to keep."
                handoffStatusLabel = "Review"
            case .activeUploadWork:
                handoffTitle = "Upload first"
                handoffDetail = "Queued recordings must finish upload before the workspace snapshot can publish."
                handoffStatusLabel = "Waiting"
            case .failedUploadWork:
                handoffTitle = "Failed items block handoff"
                handoffDetail = "Review failed uploads before publishing the workspace to backend and Mac."
                handoffStatusLabel = "Blocked"
            case .privateLocalMode:
                handoffTitle = "Local-only handoff"
                handoffDetail = "Private mode keeps this iPhone workspace off backend and Mac sync."
                handoffStatusLabel = "Local"
            case .missingConfiguration, .invalidConfiguration:
                handoffTitle = "Backend not configured"
                handoffDetail = "Add backend settings before this iPhone can publish a Mac handoff receipt."
                handoffStatusLabel = "Setup"
            case .capabilityGate:
                handoffTitle = "Session not validated"
                handoffDetail = "Validate backend sync capability before publishing or refreshing Mac handoff state."
                handoffStatusLabel = "Validate"
            case .requestFailed:
                handoffTitle = "Sync retry needed"
                handoffDetail = "The last automatic sync request failed; retry after checking backend connectivity."
                handoffStatusLabel = "Retry"
            }
        }
    }
}
