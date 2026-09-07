import SwiftUI
import WatchKit

extension Color {
    static let forgeAubergine = Color(red: 0.17, green: 0.025, blue: 0.23)
    static let forgeEmber = Color(red: 1.00, green: 0.48, blue: 0.08)
    static let forgeCoral = Color(red: 1.00, green: 0.18, blue: 0.25)
    static let forgeMagenta = Color(red: 0.86, green: 0.06, blue: 0.34)
    static let forgeSpark = Color(red: 1.00, green: 0.95, blue: 0.72)
}

struct WatchCaptureView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Bindable var store: IdeaForgeStore
    @State private var isRecording = false
    @State private var selectedTag: IdeaTag = .appIdea
    @State private var captureTargetID = Self.newIdeaTargetID
    @State private var recorder = LocalAudioRecorder()
    let transferService: any RecordingTransferService
    @State private var transferStatus = RecordingTransferStatus.unavailable
    @State private var transferFailureMessage: String?
    @State private var voiceLevel = 0.0

    private static let newIdeaTargetID = "watch.capture.target.new"

    private let watchCaptureServices = IdeaForgeServices(
        transcription: LocalTranscriptionService(),
        workflow: LocalWorkflowExecutionService(),
        syncQueue: PendingSyncQueueService(),
        export: LocalExportService()
    )

    private var liveTint: Color {
        if isRecording { return .red }
        if transferStatus == .queuedForTransfer || transferStatus == .received { return .green }
        if transferStatus == .failed { return .orange }
        return .forgeEmber
    }

    private var captureTitle: String {
        if isRecording { return "Recording" }
        return recordingCount == 0 ? "Record idea" : "Record again"
    }

    private var captureDetail: String {
        if isRecording { return "Tap to stop · stays on Watch" }
        if transferStatus == .queuedForTransfer { return "Sending when iPhone is ready" }
        if transferStatus == .received { return "iPhone acknowledged import" }
        if transferStatus == .failed { return "Audio is safe · retry later" }
        return "Works offline · relays to iPhone"
    }

    private var watchProjects: [IdeaProject] {
        store.watchCaptureProjects
    }

    private var selectedAppendProject: IdeaProject? {
        guard captureTargetID != Self.newIdeaTargetID else { return nil }
        return watchProjects.first { $0.id == captureTargetID }
    }

    private var recordButtonTitle: String {
        if isRecording { return "Stop" }
        return selectedAppendProject == nil ? "Record" : "Append"
    }

    private var recordingCount: Int {
        watchProjects.reduce(0) { total, project in
            total + project.recordings.filter { $0.deviceName.localizedCaseInsensitiveContains("watch") }.count
        }
    }

    private var pendingWatchRecordings: [Recording] {
        watchProjects
            .flatMap(\.recordings)
            .filter { recording in
                recording.deviceName.localizedCaseInsensitiveContains("watch")
                    && (recording.syncStatus == .pending || recording.syncStatus == .failed)
            }
            .sorted { lhs, rhs in lhs.createdAt > rhs.createdAt }
    }

    private var recentWatchRecordingItems: [WatchRecordingListItem] {
        watchProjects
            .flatMap { project in
                project.recordings
                    .filter { $0.deviceName.localizedCaseInsensitiveContains("watch") }
                    .map { WatchRecordingListItem(project: project, recording: $0) }
            }
            .sorted { lhs, rhs in lhs.recording.createdAt > rhs.recording.createdAt }
    }

    private var relayState: WatchCaptureRelayState {
        WatchCaptureRelayPolicy.state(
            isRecording: isRecording,
            transientTransferStatus: transferStatus,
            recordings: watchProjects.flatMap(\.recordings)
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ForgeRelayBackdrop(tint: liveTint)

                ScrollView {
                    VStack(spacing: 5) {
                        if !dynamicTypeSize.isAccessibilitySize {
                            ForgeRelayHeader(
                                pendingCount: pendingWatchRecordings.count,
                                isRecording: isRecording
                            )
                        }

                        ForgeCaptureSurface(
                            title: captureTitle,
                            detail: captureDetail,
                            tint: liveTint,
                            isRecording: isRecording,
                            audioLevel: voiceLevel,
                            actionLabel: isRecording ? "Stop recording" : "\(recordButtonTitle) on Apple Watch"
                        ) {
                            Task { await toggleRecording() }
                        }

                        ForgeRelayTrack(
                            state: relayState,
                            pendingCount: pendingWatchRecordings.count
                        )

                        if isRecording {
                            WatchMarkerButton(isRecording: true) {
                                addMarker()
                            }
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        }

                        NavigationLink {
                            WatchCaptureDetails(
                                recordingCount: recordingCount,
                                pendingCount: pendingWatchRecordings.count,
                                recordings: Array(recentWatchRecordingItems.prefix(5)),
                                selectedProjectID: $captureTargetID,
                                selectedTag: $selectedTag,
                                projects: Array(watchProjects.prefix(5)),
                                newIdeaTargetID: Self.newIdeaTargetID,
                                isRecording: isRecording,
                                transferState: relayState,
                                transferFailureMessage: transferFailureMessage,
                                canRetryTransfer: store.retryableWatchTransferRecording != nil,
                                questions: Array(store.pendingQuestions.prefix(2)),
                                onRetryTransfer: { Task { await retryWatchTransfer() } }
                            )
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "tray.full")
                                    .foregroundStyle(Color.forgeEmber)
                                Text("Saved & setup")
                                    .font(.caption.weight(.semibold))
                                Spacer(minLength: 0)
                                Text("\(recordingCount)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 10)
                            .frame(minHeight: 42)
                            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("watch.capture.savedSetup")
                        .disabled(isRecording)
                        .opacity(isRecording ? 0.45 : 1)
                    }
                    .padding(.horizontal, 2)
                    .padding(.bottom, 10)
                    .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: isRecording)
                }
            }
            .navigationTitle("")
            .onAppear {
                transferService.setReachabilityHandler { isReachable in
                    store.syncHealth.watchReachable = isReachable
                }
                transferService.setTransferCompletionHandler { recordingID, imported in
                    if imported {
                        if store.markRecordingTransferredToIPhone(recordingID: recordingID) {
                            transferStatus = .received
                            transferFailureMessage = nil
                            WKInterfaceDevice.current().play(.success)
                        } else {
                            transferStatus = .failed
                            transferFailureMessage = "iPhone imported this clip, but Watch could not save the receipt. Retry to confirm it."
                            WKInterfaceDevice.current().play(.failure)
                        }
                    } else {
                        transferStatus = .failed
                        transferFailureMessage = "iPhone did not import this clip. Retry when both devices are ready."
                        _ = store.markRecordingWatchTransferFailed(recordingID: recordingID)
                        WKInterfaceDevice.current().play(.failure)
                    }
                }
                transferService.activate()
                configureRecordingRecovery()
                Task {
                    await recoverPendingRecordingIfNeeded()
                }
                IdeaForgeLog.sync.info("watchOS recording transfer service activated")
            }
            .onChange(of: watchProjects.map(\.id)) { _, projectIDs in
                guard captureTargetID != Self.newIdeaTargetID,
                      !projectIDs.contains(captureTargetID) else {
                    return
                }
                captureTargetID = Self.newIdeaTargetID
            }
            .task(id: isRecording) {
                guard isRecording else {
                    voiceLevel = 0
                    return
                }

                while !Task.isCancelled && isRecording {
                    voiceLevel = recorder.normalizedPowerLevel
                    try? await Task.sleep(nanoseconds: 80_000_000)
                }
            }
        }
    }

    private func toggleRecording() async {
        do {
            if isRecording {
                IdeaForgeLog.recording.info("watchOS recording stop requested")
                let appendProject = selectedAppendProject
                let draft = try recorder.stop(
                    projectTitle: appendProject?.title ?? selectedTag.label,
                    tag: selectedTag,
                    source: .watch,
                    transcriptHint: appendProject == nil
                        ? "Voice idea captured on Apple Watch for later review on iPhone and Mac."
                        : "Additional Apple Watch note queued for transcription and review."
                )
                isRecording = false
                voiceLevel = 0
                if let recording = await persistWatchRecording(
                    draft,
                    targetProjectID: appendProject?.id
                ) {
                    try recorder.acknowledgePersistence()
                    WKInterfaceDevice.current().play(.success)
                    attemptTransfer(recording: recording)
                }
            } else {
                IdeaForgeLog.recording.info("watchOS recording start requested")
                let appendProject = selectedAppendProject
                try await recorder.start(
                    recoveryContext: RecordingCaptureContext(
                        projectTitle: appendProject?.title ?? selectedTag.label,
                        tag: selectedTag,
                        source: .watch,
                        transcriptHint: appendProject == nil
                            ? "Voice idea captured on Apple Watch for later review on iPhone and Mac."
                            : "Additional Apple Watch note queued for transcription and review.",
                        targetProjectID: appendProject?.id
                    )
                )
                voiceLevel = recorder.normalizedPowerLevel
                isRecording = true
                WKInterfaceDevice.current().play(.start)
            }
        } catch {
            isRecording = false
            voiceLevel = 0
            store.lastErrorMessage = (error as? UserFacingIdeaForgeError)?.userFacingMessage ?? "Recording failed."
            WKInterfaceDevice.current().play(.failure)
            IdeaForgeLog.recording.error("watchOS recording control failed")
        }
    }

    private func addMarker() {
        do {
            try recorder.addMarker()
            WKInterfaceDevice.current().play(.click)
        } catch {
            store.lastErrorMessage = (error as? UserFacingIdeaForgeError)?.userFacingMessage
                ?? "Marker recovery state could not be saved."
            WKInterfaceDevice.current().play(.failure)
        }
    }

    private func configureRecordingRecovery() {
        recorder.setUnexpectedTerminationHandler { reason in
            isRecording = false
            voiceLevel = 0
            Task {
                await recoverPendingRecordingIfNeeded(expectedReason: reason)
            }
        }
    }

    private func recoverPendingRecordingIfNeeded(
        expectedReason: RecordingTerminationReason? = nil
    ) async {
        guard !recorder.isRecording else {
            isRecording = true
            return
        }
        do {
            guard let recovery = try recorder.pendingRecovery() else { return }
            guard let recording = await persistWatchRecording(
                recovery.draft,
                targetProjectID: recovery.targetProjectID
            ) else {
                store.lastErrorMessage = "A saved Watch recording still needs recovery."
                return
            }
            try recorder.acknowledgePersistence()
            WKInterfaceDevice.current().play(.success)
            isRecording = false
            voiceLevel = 0
            let reason = expectedReason ?? recovery.terminationReason
            store.lastErrorMessage = reason == .userStopped
                ? "A recording saved before the app closed was recovered."
                : "An interrupted recording was recovered and kept on Watch."
            attemptTransfer(recording: recording)
            IdeaForgeLog.recording.info("watchOS recording recovery completed")
        } catch {
            isRecording = false
            voiceLevel = 0
            store.lastErrorMessage = (error as? UserFacingIdeaForgeError)?.userFacingMessage
                ?? "A saved Watch recording could not be recovered."
            IdeaForgeLog.recording.error("watchOS recording recovery failed")
        }
    }

    private func persistWatchRecording(
        _ draft: RecordingDraft,
        targetProjectID: String?
    ) async -> Recording? {
        if let targetProjectID,
           let recording = await store.appendWatchRecording(
               draft,
               to: targetProjectID,
               services: watchCaptureServices
           ) {
            return recording
        }
        guard let project = await store.capture(draft, services: watchCaptureServices),
              let recordingID = draft.recordingID,
              let recording = project.recordings.first(where: { $0.id == recordingID }) else {
            return nil
        }
        captureTargetID = project.id
        return recording
    }

    private func retryWatchTransfer() async {
        guard let recording = store.retryableWatchTransferRecording else { return }
        attemptTransfer(recording: recording)
    }

    private func attemptTransfer(recording: Recording) {
        do {
            let receipt = try transferService.transfer(recording: recording)
            transferStatus = receipt.status
            transferFailureMessage = nil
            // Keep the recording pending until the iPhone acknowledges a durable import.
            IdeaForgeLog.sync.info("watchOS recording transfer queued; status: \(receipt.status.rawValue, privacy: .public)")
        } catch {
            transferStatus = .failed
            transferFailureMessage = "iPhone handoff failed. Retry when devices are nearby."
            store.lastErrorMessage = transferFailureMessage
            WKInterfaceDevice.current().play(.failure)
            IdeaForgeLog.sync.error("watchOS recording transfer failed")
        }
    }
}

private extension WatchCaptureRelayState {
    var title: String {
        switch self {
        case .ready: "Ready on Watch"
        case .recording: "Recording locally"
        case .saved: "Saved on Watch"
        case .queued: "Waiting for iPhone"
        case .received: "Received on iPhone"
        case .failed: "Kept on Watch"
        }
    }

    var detail: String {
        switch self {
        case .ready: "Works without iPhone"
        case .recording: "Audio remains local"
        case .saved: "Durable local copy"
        case .queued: "Safe to retry later"
        case .received: "Import acknowledged"
        case .failed: "Send needs attention"
        }
    }

    var tint: Color {
        switch self {
        case .ready: .forgeEmber
        case .recording: .red
        case .saved: .mint
        case .queued: .yellow
        case .received: .green
        case .failed: .orange
        }
    }

    var symbol: String {
        switch self {
        case .ready: "mic"
        case .recording: "waveform"
        case .saved: "checkmark"
        case .queued: "arrow.right"
        case .received: "iphone"
        case .failed: "exclamationmark"
        }
    }
}

private struct ForgeRelayBackdrop: View {
    var tint: Color

    var body: some View {
        ZStack {
            Color.forgeAubergine
            LinearGradient(
                colors: [tint.opacity(0.18), Color.forgeMagenta.opacity(0.07), .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

private struct ForgeRelayHeader: View {
    var pendingCount: Int
    var isRecording: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkle")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.forgeSpark)
            Text("IDEAFORGE")
                .font(.caption2.monospaced().weight(.bold))
                .tracking(0.8)
            Spacer(minLength: 4)
            if isRecording {
                Text("LIVE")
                    .foregroundStyle(.red)
            } else if pendingCount > 0 {
                Text("\(pendingCount) WAITING")
                    .foregroundStyle(.yellow)
            } else {
                Text("LOCAL READY")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 9, weight: .semibold, design: .monospaced))
        .lineLimit(1)
        .minimumScaleFactor(0.72)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isRecording ? "IdeaForge, recording live" : pendingCount > 0 ? "IdeaForge, \(pendingCount) waiting for iPhone" : "IdeaForge, ready for local capture")
    }
}

private struct ForgeCaptureSurface: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var title: String
    var detail: String
    var tint: Color
    var isRecording: Bool
    var audioLevel: Double
    var actionLabel: String
    var onToggleRecording: () -> Void

    var body: some View {
        Button(action: onToggleRecording) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    if !dynamicTypeSize.isAccessibilitySize {
                        Text(isRecording ? "CAPTURING" : "VOICE CAPTURE")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .tracking(0.7)
                            .foregroundStyle(tint)
                    }
                    Text(title)
                        .font((dynamicTypeSize.isAccessibilitySize ? Font.body : .subheadline).weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                        .minimumScaleFactor(0.75)
                    Text(detail)
                        .font(.system(size: 9, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if !dynamicTypeSize.isAccessibilitySize {
                        ForgeSignalBars(
                            tint: tint,
                            isRecording: isRecording,
                            audioLevel: audioLevel
                        )
                        .frame(height: 11)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ZStack {
                    Circle()
                        .strokeBorder(tint.opacity(0.28), lineWidth: 1)
                        .frame(
                            width: dynamicTypeSize.isAccessibilitySize ? 44 : 52,
                            height: dynamicTypeSize.isAccessibilitySize ? 44 : 52
                        )
                    Circle()
                        .fill(tint.gradient)
                        .frame(
                            width: dynamicTypeSize.isAccessibilitySize ? 38 : 44,
                            height: dynamicTypeSize.isAccessibilitySize ? 38 : 44
                        )
                        .shadow(color: tint.opacity(isRecording ? 0.32 : 0.16), radius: isRecording ? 9 : 4)
                    Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                        .font(.body.weight(.bold))
                        .foregroundStyle(.black.opacity(0.84))
                }
                .scaleEffect(isRecording && !reduceMotion ? 1.03 : 1)
                .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: isRecording)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(minHeight: 72)
            .background(
                LinearGradient(
                    colors: [.white.opacity(0.09), tint.opacity(0.09), .white.opacity(0.035)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: UnevenRoundedRectangle(
                    topLeadingRadius: 20,
                    bottomLeadingRadius: 9,
                    bottomTrailingRadius: 20,
                    topTrailingRadius: 9,
                    style: .continuous
                )
            )
            .overlay {
                UnevenRoundedRectangle(
                    topLeadingRadius: 20,
                    bottomLeadingRadius: 9,
                    bottomTrailingRadius: 20,
                    topTrailingRadius: 9,
                    style: .continuous
                )
                .strokeBorder(tint.opacity(0.24), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("watch.capture.record")
        .accessibilityLabel(actionLabel)
        .accessibilityValue(isRecording ? "Recording locally" : "Ready")
        .accessibilityHint(isRecording ? "Stops and saves the recording on Apple Watch" : "Starts an offline recording on Apple Watch")
    }
}

private struct ForgeSignalBars: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var tint: Color
    var isRecording: Bool
    var audioLevel: Double

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<9, id: \.self) { index in
                Capsule()
                    .fill(tint.opacity(isRecording ? 0.9 : 0.34))
                    .frame(width: 3, height: barHeight(index))
            }
            Spacer(minLength: 0)
        }
        .animation(reduceMotion ? nil : .linear(duration: 0.08), value: audioLevel)
        .accessibilityHidden(true)
    }

    private func barHeight(_ index: Int) -> CGFloat {
        guard isRecording else { return index == 4 ? 5 : 2 }
        let level = CGFloat(min(max(audioLevel, 0), 1))
        let weights: [CGFloat] = [0.32, 0.48, 0.68, 0.86, 1, 0.82, 0.62, 0.44, 0.28]
        return 3 + level * 17 * weights[index]
    }
}

private struct ForgeRelayTrack: View {
    var state: WatchCaptureRelayState
    var pendingCount: Int

    private var reachesQueue: Bool {
        state == .queued || state == .received || state == .failed
    }

    private var reachesPhone: Bool {
        state == .received
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                relayNode(symbol: "applewatch", label: "WATCH", resolved: state != .ready)
                relayLine(active: reachesQueue)
                relayNode(symbol: state == .failed ? "exclamationmark" : "arrow.up", label: "RELAY", resolved: reachesQueue)
                relayLine(active: reachesPhone)
                relayNode(symbol: "iphone", label: "IPHONE", resolved: reachesPhone)
            }

            HStack(spacing: 4) {
                Image(systemName: state.symbol)
                Text(state.title)
                if pendingCount > 1 && state == .queued {
                    Text("· \(pendingCount) clips")
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 8, weight: .semibold, design: .rounded))
            .foregroundStyle(state.tint)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("watch.capture.relay")
        .accessibilityLabel("Capture relay")
        .accessibilityValue("\(state.title). \(state.detail)")
    }

    private func relayNode(symbol: String, label: String, resolved: Bool) -> some View {
        Image(systemName: symbol)
            .font(.caption2.weight(.bold))
            .frame(width: 18, height: 18)
            .background((resolved ? state.tint : Color.white.opacity(0.08)), in: Circle())
            .foregroundStyle(resolved ? .black : .secondary)
            .accessibilityLabel(label)
    }

    private func relayLine(active: Bool) -> some View {
        Capsule()
            .fill(active ? state.tint : Color.white.opacity(0.12))
            .frame(maxWidth: .infinity, minHeight: 2, maxHeight: 2)
    }
}

private struct WatchCaptureDetails: View {
    var recordingCount: Int
    var pendingCount: Int
    var recordings: [WatchRecordingListItem]
    @Binding var selectedProjectID: String
    @Binding var selectedTag: IdeaTag
    var projects: [IdeaProject]
    var newIdeaTargetID: String
    var isRecording: Bool
    var transferState: WatchCaptureRelayState
    var transferFailureMessage: String?
    var canRetryTransfer: Bool
    var questions: [Question]
    var onRetryTransfer: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(transferState.title, systemImage: transferState.symbol)
                        .font(.headline)
                        .foregroundStyle(transferState.tint)
                    Text(transferFailureMessage ?? transferState.detail)
                        .font(.caption2)
                        .foregroundStyle(transferFailureMessage == nil ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(transferFailureMessage == nil ? "watch.capture.transferStatus" : "watch.capture.transferFailure")
                    if canRetryTransfer {
                        Button(action: onRetryTransfer) {
                            Label("Retry Send", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .accessibilityIdentifier("watch.capture.retryTransfer")
                    }
                }

                Divider()

                Text("NEXT CAPTURE")
                    .font(.caption2.monospaced().weight(.bold))
                    .foregroundStyle(.secondary)
                WatchCaptureTargetPicker(
                    selection: $selectedProjectID,
                    projects: projects,
                    newIdeaTargetID: newIdeaTargetID,
                    isDisabled: isRecording
                )
                WatchIdeaTagPicker(selectedTag: $selectedTag)

                WatchRecordingsPanel(
                    recordingCount: recordingCount,
                    pendingCount: pendingCount,
                    recordings: recordings,
                    selectedProjectID: $selectedProjectID,
                    newIdeaTargetID: newIdeaTargetID,
                    isRecording: isRecording
                )

                if !questions.isEmpty {
                    Text("QUESTIONS")
                        .font(.caption2.monospaced().weight(.bold))
                        .foregroundStyle(.secondary)
                    ForEach(questions) { question in
                        WatchQuestionRow(question: question)
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 12)
        }
        .navigationTitle("Saved & Setup")
    }
}

private struct WatchCaptureTargetPicker: View {
    @Binding var selection: String
    var projects: [IdeaProject]
    var newIdeaTargetID: String
    var isDisabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Target")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            Button {
                selection = newIdeaTargetID
            } label: {
                WatchSelectionChip(
                    title: "New idea",
                    detail: "fresh capture",
                    symbol: "sparkles",
                    isSelected: selection == newIdeaTargetID,
                    tint: .green
                )
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .accessibilityIdentifier("watch.capture.target.new")

            ForEach(projects.prefix(3)) { project in
                Button {
                    selection = project.id
                } label: {
                    WatchSelectionChip(
                        title: project.title,
                        detail: "append",
                        symbol: "plus.bubble",
                        isSelected: selection == project.id,
                        tint: .forgeEmber
                    )
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
                .accessibilityIdentifier("watch.capture.target.\(project.id)")
            }
        }
        .opacity(isDisabled ? 0.55 : 1)
        .disabled(isDisabled)
        .accessibilityIdentifier("watch.capture.target")
    }
}

private struct WatchIdeaTagPicker: View {
    @Binding var selectedTag: IdeaTag

    var body: some View {
        Button {
            selectedTag = nextTag(after: selectedTag)
        } label: {
            WatchSelectionChip(
                title: selectedTag.label,
                detail: "tap to change",
                symbol: symbol(for: selectedTag),
                isSelected: true,
                tint: tint(for: selectedTag)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("watch.capture.tag")
        .accessibilityHint("Tap to cycle the idea tag")
    }

    private func nextTag(after tag: IdeaTag) -> IdeaTag {
        let tags = IdeaTag.allCases
        guard let index = tags.firstIndex(of: tag) else { return tags[0] }
        return tags[(index + 1) % tags.count]
    }

    private func symbol(for tag: IdeaTag) -> String {
        switch tag {
        case .appIdea: "lightbulb"
        case .feature: "wand.and.stars"
        case .bug: "ladybug"
        case .business: "chart.line.uptrend.xyaxis"
        case .research: "doc.text.magnifyingglass"
        case .random: "sparkles"
        }
    }

    private func tint(for tag: IdeaTag) -> Color {
        switch tag {
        case .appIdea: .yellow
        case .feature: .forgeEmber
        case .bug: .red
        case .business: .green
        case .research: .forgeMagenta
        case .random: .forgeCoral
        }
    }
}

private struct WatchSelectionChip: View {
    var title: String
    var detail: String
    var symbol: String
    var isSelected: Bool
    var tint: Color

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(isSelected ? 0.18 : 0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tint.opacity(isSelected ? 0.36 : 0.14), lineWidth: 1)
        }
    }
}

private struct WatchMarkerButton: View {
    var isRecording: Bool
    var onAddMarker: () -> Void

    var body: some View {
        Button {
            onAddMarker()
        } label: {
            Label("Marker", systemImage: isRecording ? "star.circle.fill" : "star.circle")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(.yellow)
        .disabled(!isRecording)
        .accessibilityIdentifier("watch.capture.marker")
        .accessibilityHint(isRecording ? "Add a marker to the current recording" : "Start recording before adding a marker")
    }
}

private struct WatchRecordingListItem: Identifiable {
    var project: IdeaProject
    var recording: Recording

    var id: String { recording.id }
}

private struct WatchRecordingsPanel: View {
    var recordingCount: Int
    var pendingCount: Int
    var recordings: [WatchRecordingListItem]
    @Binding var selectedProjectID: String
    var newIdeaTargetID: String
    var isRecording: Bool

    private var hasPending: Bool {
        pendingCount > 0
    }

    private var syncSummary: String {
        if recordingCount == 0 { return "No clips yet." }
        return hasPending ? "\(pendingCount) waiting for iPhone." : "All visible clips sent."
    }

    private var syncSymbol: String {
        if recordingCount == 0 { return "waveform" }
        return hasPending ? "arrow.triangle.2.circlepath" : "checkmark.circle"
    }

    var body: some View {
        WatchGlassPanel(tint: .forgeEmber, isLive: hasPending) {
            VStack(alignment: .leading, spacing: 9) {
                WatchPanelHeader(
                    title: "Saved on Watch",
                    detail: "\(recordingCount) clip\(recordingCount == 1 ? "" : "s")",
                    symbol: "waveform.badge.plus",
                    tint: .forgeEmber,
                    isLive: hasPending
                )

                Label(syncSummary, systemImage: syncSymbol)
                    .font(.caption2)
                    .foregroundStyle(hasPending ? .yellow : .secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if recordings.isEmpty {
                    Text("Tap the ring once to start. Tap again to save the clip offline.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(recordings) { item in
                        WatchSavedRecordingRow(
                            item: item,
                            isSelectedForAppend: selectedProjectID == item.project.id,
                            isRecording: isRecording,
                            onAppend: {
                                selectedProjectID = item.project.id
                            }
                        )
                    }

                    if selectedProjectID != newIdeaTargetID {
                        Button {
                            selectedProjectID = newIdeaTargetID
                        } label: {
                            Label("Next: New Idea", systemImage: "sparkles")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.green)
                        .disabled(isRecording)
                        .accessibilityIdentifier("watch.recordings.newIdea")
                    }
                }
            }
            .accessibilityIdentifier("watch.recordings.list")
        }
    }
}

private struct WatchGlassPanel<Content: View>: View {
    var tint: Color
    var isLive: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.linearGradient(
                        colors: [
                            .white.opacity(0.18),
                            tint.opacity(0.10),
                            .clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(tint.opacity(isLive ? 0.28 : 0.16), lineWidth: 1)
            }
            .shadow(color: tint.opacity(isLive ? 0.12 : 0.06), radius: 8, y: 4)
    }
}

private struct WatchPanelHeader: View {
    var title: String
    var detail: String
    var symbol: String
    var tint: Color
    var isLive: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: symbol)
                .font(.headline)
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct WatchSavedRecordingRow: View {
    var item: WatchRecordingListItem
    var isSelectedForAppend: Bool
    var isRecording: Bool
    var onAppend: () -> Void

    private var recording: Recording {
        item.recording
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: recording.syncStatus.watchSymbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(recording.syncStatus.watchTint)
                    .frame(width: 24, height: 24)
                    .background(recording.syncStatus.watchTint.opacity(0.14), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.project.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.78)
                    Text("\(recording.durationSeconds)s · \(recording.createdAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Text(recording.syncStatus.watchStatusLabel)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.70)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(recording.syncStatus.watchTint.opacity(0.16), in: Capsule())
                    .foregroundStyle(recording.syncStatus.watchTint)
            }

            Button {
                onAppend()
            } label: {
                Label(isSelectedForAppend ? "Append Selected" : "Append Here", systemImage: isSelectedForAppend ? "checkmark.circle.fill" : "plus.bubble")
                    .frame(maxWidth: .infinity)
            }
            .font(.caption2.weight(.semibold))
            .buttonStyle(.bordered)
            .tint(isSelectedForAppend ? .green : .forgeEmber)
            .disabled(isRecording)
            .accessibilityIdentifier("watch.recordings.append.\(item.project.id)")
            .accessibilityHint("Append the next Watch recording to \(item.project.title)")
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(isSelectedForAppend ? 0.20 : 0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder((isSelectedForAppend ? Color.green : recording.syncStatus.watchTint).opacity(isSelectedForAppend ? 0.34 : 0.18))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.project.title), \(recording.durationSeconds) seconds, \(recording.syncStatus.watchStatusLabel)")
        .accessibilityIdentifier("watch.recordings.row.\(recording.id)")
    }
}

private struct WatchQuestionRow: View {
    var question: Question

    var body: some View {
        Text(question.prompt)
            .font(.caption)
            .foregroundStyle(.primary)
            .lineLimit(3)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityLabel(question.prompt)
    }
}

private extension SyncStatus {
    var watchStatusLabel: String {
        switch self {
        case .pending: "On Watch"
        case .transferredToIPhone: "Sent"
        case .uploaded: "Uploaded"
        case .failed: "Retry"
        case .transcribing: "Transcribing"
        case .ready: "Ready"
        }
    }

    var watchTint: Color {
        switch self {
        case .pending: .yellow
        case .transferredToIPhone, .uploaded, .ready: .green
        case .failed: .red
        case .transcribing: .forgeMagenta
        }
    }

    var watchSymbol: String {
        switch self {
        case .pending: "clock"
        case .transferredToIPhone: "iphone.gen3"
        case .uploaded: "icloud"
        case .failed: "exclamationmark.triangle.fill"
        case .transcribing: "waveform"
        case .ready: "checkmark.circle.fill"
        }
    }
}
