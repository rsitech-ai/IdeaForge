import SwiftUI

struct WatchCaptureView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
        return .cyan
    }

    private var captureTitle: String {
        if isRecording { return "Recording" }
        return recordingCount == 0 ? "Tap to record" : "Ready"
    }

    private var captureDetail: String {
        if isRecording { return "Tap the ring again to stop. Voice pulse follows your speech." }
        if transferStatus == .queuedForTransfer { return "Last clip is sending to iPhone." }
        if transferStatus == .received { return "Last clip was imported on iPhone." }
        if transferStatus == .failed { return "Clip stayed on Watch. Retry when iPhone is nearby." }
        return "Capture offline, then sync when your iPhone is available."
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

    var body: some View {
        NavigationStack {
            ZStack {
                WatchAmbientBackdrop(tint: liveTint, isActive: isRecording || transferStatus != .unavailable)

                ScrollView {
                    VStack(spacing: 12) {
                        Text("IdeaForge")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 2)

                        WatchCaptureHero(
                            title: captureTitle,
                            detail: captureDetail,
                            tint: liveTint,
                            isRecording: isRecording,
                            audioLevel: voiceLevel,
                            queuedCount: pendingWatchRecordings.count,
                            questionCount: store.pendingQuestions.count,
                            actionLabel: isRecording ? "Stop recording" : "\(recordButtonTitle) on Apple Watch"
                        ) {
                            Task {
                                await toggleRecording()
                            }
                        }

                        WatchRecordingsPanel(
                            recordingCount: recordingCount,
                            pendingCount: pendingWatchRecordings.count,
                            recordings: Array(recentWatchRecordingItems.prefix(5)),
                            selectedProjectID: $captureTargetID,
                            newIdeaTargetID: Self.newIdeaTargetID,
                            isRecording: isRecording
                        )

                        WatchGlassPanel(tint: transferStatus.watchTint, isLive: transferStatus != .unavailable) {
                            VStack(alignment: .leading, spacing: 9) {
                                WatchPanelHeader(
                                    title: "Sync",
                                    detail: transferStatus.watchActionLabel,
                                    symbol: transferStatus.watchSymbol,
                                    tint: transferStatus.watchTint,
                                    isLive: transferStatus != .unavailable
                                )

                                if let transferFailureMessage {
                                    Label(transferFailureMessage, systemImage: "exclamationmark.triangle.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .accessibilityIdentifier("watch.capture.transferFailure")
                                } else if pendingWatchRecordings.isEmpty {
                                    Label("No Watch clips waiting.", systemImage: "checkmark.circle")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Label("\(pendingWatchRecordings.count) Watch clip\(pendingWatchRecordings.count == 1 ? "" : "s") waiting.", systemImage: "clock")
                                        .font(.caption2)
                                        .foregroundStyle(.yellow)
                                }

                                if store.retryableWatchTransferRecording != nil {
                                    Button {
                                        Task {
                                            await retryWatchTransfer()
                                        }
                                    } label: {
                                        Label("Retry Send", systemImage: "arrow.clockwise")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(.orange)
                                    .disabled(isRecording)
                                    .accessibilityIdentifier("watch.capture.retryTransfer")
                                    .accessibilityHint("Retry sending the latest local Watch recording to iPhone")
                                }
                            }
                        }

                        WatchGlassPanel(tint: liveTint, isLive: isRecording || selectedAppendProject != nil) {
                            VStack(spacing: 10) {
                                WatchPanelHeader(
                                    title: "Options",
                                    detail: selectedAppendProject == nil ? "New idea" : "Appending next clip",
                                    symbol: "slider.horizontal.3",
                                    tint: liveTint,
                                    isLive: isRecording || selectedAppendProject != nil
                                )

                                WatchCaptureTargetPicker(
                                    selection: $captureTargetID,
                                    projects: Array(watchProjects.prefix(5)),
                                    newIdeaTargetID: Self.newIdeaTargetID,
                                    isDisabled: isRecording
                                )

                                if let selectedAppendProject {
                                    Label("Appending to \(selectedAppendProject.title)", systemImage: "plus.bubble")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.cyan)
                                        .lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .accessibilityIdentifier("watch.capture.appendTarget")
                                }

                                WatchIdeaTagPicker(selectedTag: $selectedTag)

                                WatchMarkerButton(isRecording: isRecording) {
                                    do {
                                        try recorder.addMarker()
                                    } catch {
                                        store.lastErrorMessage = (error as? UserFacingIdeaForgeError)?.userFacingMessage
                                            ?? "Marker recovery state could not be saved."
                                    }
                                }

                                if !isRecording {
                                    Text("Markers are available while recording.")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }

                        if !store.pendingQuestions.isEmpty {
                            WatchGlassPanel(tint: .indigo, isLive: true) {
                                VStack(alignment: .leading, spacing: 9) {
                                    WatchPanelHeader(
                                        title: "Questions",
                                        detail: "\(store.pendingQuestions.count) pending",
                                        symbol: "questionmark.bubble.fill",
                                        tint: .indigo,
                                        isLive: true
                                    )

                                    ForEach(store.pendingQuestions.prefix(2)) { question in
                                        WatchQuestionRow(question: question)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 12)
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
                        } else {
                            transferStatus = .failed
                            transferFailureMessage = "iPhone imported this clip, but Watch could not save the receipt. Retry to confirm it."
                        }
                    } else {
                        transferStatus = .failed
                        transferFailureMessage = "iPhone did not import this clip. Retry when both devices are ready."
                        _ = store.markRecordingWatchTransferFailed(recordingID: recordingID)
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
            }
        } catch {
            isRecording = false
            voiceLevel = 0
            store.lastErrorMessage = (error as? UserFacingIdeaForgeError)?.userFacingMessage ?? "Recording failed."
            IdeaForgeLog.recording.error("watchOS recording control failed")
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
            IdeaForgeLog.sync.error("watchOS recording transfer failed")
        }
    }
}

private struct WatchCaptureHero: View {
    var title: String
    var detail: String
    var tint: Color
    var isRecording: Bool
    var audioLevel: Double
    var queuedCount: Int
    var questionCount: Int
    var actionLabel: String
    var onToggleRecording: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Button {
                onToggleRecording()
            } label: {
                WatchLiveRing(tint: tint, isActive: isRecording, audioLevel: audioLevel)
                    .frame(width: 108, height: 108)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("watch.capture.record")
            .accessibilityLabel(actionLabel)
            .accessibilityHint(isRecording ? "Stops recording and queues it for iPhone handoff" : "Starts offline recording on Apple Watch")

            VStack(spacing: 3) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                WatchMetricCapsule(title: "Queue", value: queuedCount, tint: .cyan)
                WatchMetricCapsule(title: "Ask", value: questionCount, tint: .indigo)
            }
        }
        .padding(.top, 4)
    }
}

private struct WatchLiveRing: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var tint: Color
    var isActive: Bool
    var audioLevel: Double
    @State private var phase = false

    var body: some View {
        let active = isActive && !reduceMotion
        let level = CGFloat(min(max(audioLevel, 0), 1))
        let reactiveScale = active ? 1 + level * 0.12 : 1
        let reactiveGlow = active ? 0.16 + level * 0.30 : 0.12

        ZStack {
            Circle()
                .fill(.radialGradient(
                    colors: [
                        tint.opacity(active ? reactiveGlow : 0.18),
                        tint.opacity(0.08),
                        .clear
                    ],
                    center: .center,
                    startRadius: 8,
                    endRadius: 58
                ))

            Circle()
                .stroke(
                    AngularGradient(
                        colors: [
                            tint.opacity(0.24),
                            .white.opacity(active ? 0.82 : 0.30),
                            tint.opacity(active ? 0.95 : 0.42),
                            tint.opacity(0.24)
                        ],
                        center: .center
                    ),
                    lineWidth: active ? 4 + level * 4 : 3
                )
                .rotationEffect(.degrees(phase && active ? 360 : 0))

            Circle()
                .strokeBorder(tint.opacity(active ? 0.22 + level * 0.36 : 0.16), lineWidth: active ? 1.5 + level * 2 : 1)
                .padding(12 - level * 3)

            Image(systemName: isActive ? "waveform.circle.fill" : "mic.circle.fill")
                .font(.system(size: 42 + level * 4, weight: .semibold))
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
                .symbolEffect(.pulse, options: .repeating, isActive: active)

            WatchSignalBars(tint: tint, isActive: active, audioLevel: audioLevel)
                .frame(width: 54, height: 24)
                .offset(y: 44)
        }
        .scaleEffect((active && phase ? 1.025 : 1) * reactiveScale)
        .animation(reduceMotion ? nil : .easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: phase)
        .animation(reduceMotion ? nil : .interactiveSpring(response: 0.18, dampingFraction: 0.72), value: audioLevel)
        .onAppear {
            updateAnimation(active: active)
        }
        .onChange(of: isActive) { _, newValue in
            updateAnimation(active: newValue && !reduceMotion)
        }
        .onChange(of: reduceMotion) { _, newValue in
            updateAnimation(active: isActive && !newValue)
        }
    }

    private func updateAnimation(active: Bool) {
        guard active else {
            phase = false
            return
        }
        withAnimation(.linear(duration: 3.4).repeatForever(autoreverses: false)) {
            phase = true
        }
    }
}

private struct WatchSignalBars: View {
    var tint: Color
    var isActive: Bool
    var audioLevel: Double

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(0..<5, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(tint.gradient)
                    .frame(width: 5, height: height(for: index))
                    .opacity(isActive ? 0.92 : 0.45)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.thinMaterial, in: Capsule())
        .overlay {
            Capsule().strokeBorder(tint.opacity(isActive ? 0.32 : 0.18))
        }
    }

    private func height(for index: Int) -> CGFloat {
        let level = CGFloat(min(max(audioLevel, 0), 1))
        let gainPattern: [CGFloat] = [8, 15, 20, 12, 17]
        let activePattern: [CGFloat] = [9, 16, 22, 14, 19]
        let idlePattern: [CGFloat] = [8, 11, 14, 10, 12]
        guard isActive else { return idlePattern[index] }
        return activePattern[index] + gainPattern[index] * level
    }
}

private struct WatchMetricCapsule: View {
    var title: String
    var value: Int
    var tint: Color

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.caption2.weight(.medium))
            Text("\(value)")
                .font(.caption2.monospacedDigit().weight(.semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(tint.opacity(value > 0 ? 0.20 : 0.10), in: Capsule())
        .overlay {
            Capsule().strokeBorder(tint.opacity(value > 0 ? 0.30 : 0.16))
        }
        .foregroundStyle(value > 0 ? tint : .secondary)
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
                        tint: .cyan
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
        case .feature: .cyan
        case .bug: .red
        case .business: .green
        case .research: .indigo
        case .random: .orange
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
        WatchGlassPanel(tint: .cyan, isLive: hasPending) {
            VStack(alignment: .leading, spacing: 9) {
                WatchPanelHeader(
                    title: "Saved on Watch",
                    detail: "\(recordingCount) clip\(recordingCount == 1 ? "" : "s")",
                    symbol: "waveform.badge.plus",
                    tint: .cyan,
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var tint: Color
    var isLive: Bool
    @ViewBuilder var content: () -> Content
    @State private var glow = false

    var body: some View {
        let active = isLive && !reduceMotion && glow

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
            .overlay {
                WatchConstellationTrace(tint: tint, isActive: isLive)
            }
            .shadow(color: tint.opacity(active ? 0.24 : 0.08), radius: active ? 14 : 8, y: 5)
            .scaleEffect(active ? 1.01 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 1.8), value: glow)
            .onAppear {
                updateGlow(active: isLive && !reduceMotion)
            }
            .onChange(of: isLive) { _, newValue in
                updateGlow(active: newValue && !reduceMotion)
            }
            .onChange(of: reduceMotion) { _, newValue in
                updateGlow(active: isLive && !newValue)
            }
    }

    private func updateGlow(active: Bool) {
        guard active else {
            glow = false
            return
        }
        withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
            glow = true
        }
    }
}

private struct WatchConstellationTrace: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var tint: Color
    var isActive: Bool
    @State private var phase = false

    var body: some View {
        let active = isActive && !reduceMotion

        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let height = max(proxy.size.height, 1)

            ZStack(alignment: .topLeading) {
                ForEach(0..<2, id: \.self) { index in
                    Capsule()
                        .fill(tint.opacity(active ? 0.28 : 0.10))
                        .frame(width: width * (0.24 + CGFloat(index) * 0.08), height: 1.5)
                        .rotationEffect(.degrees(index == 0 ? -9 : 10))
                        .offset(
                            x: width * (0.56 + CGFloat(index) * 0.18),
                            y: height * (0.24 + CGFloat(index) * 0.34) + (phase && active ? 4 : -2)
                        )
                        .opacity(active ? 0.70 : 0.22)
                }

                ForEach(0..<4, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(tint.opacity(active ? 0.50 : 0.16))
                        .frame(width: 4, height: 4)
                        .offset(
                            x: width * xPosition(for: index),
                            y: height * yPosition(for: index) + (phase && active ? CGFloat(index % 2) * -2 : 0)
                        )
                        .opacity(active ? 0.82 : 0.30)
                }
            }
            .frame(width: width, height: height)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .blendMode(.screen)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            updateAnimation(active: active)
        }
        .onChange(of: isActive) { _, newValue in
            updateAnimation(active: newValue && !reduceMotion)
        }
        .onChange(of: reduceMotion) { _, newValue in
            updateAnimation(active: isActive && !newValue)
        }
    }

    private func xPosition(for index: Int) -> CGFloat {
        [0.58, 0.76, 0.86, 0.68][index]
    }

    private func yPosition(for index: Int) -> CGFloat {
        [0.24, 0.34, 0.58, 0.70][index]
    }

    private func updateAnimation(active: Bool) {
        guard active else {
            phase = false
            return
        }
        withAnimation(.easeInOut(duration: 3.6).repeatForever(autoreverses: true)) {
            phase = true
        }
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
                .symbolEffect(.pulse, options: .repeating, isActive: isLive)
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
            .tint(isSelectedForAppend ? .green : .cyan)
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

private struct WatchAmbientBackdrop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var tint: Color
    var isActive: Bool
    @State private var phase = false

    var body: some View {
        LinearGradient(
            colors: [
                tint.opacity(phase && isActive && !reduceMotion ? 0.24 : 0.12),
                Color.indigo.opacity(phase && isActive && !reduceMotion ? 0.16 : 0.08),
                Color.orange.opacity(0.08),
                .clear
            ],
            startPoint: phase && isActive && !reduceMotion ? .topLeading : .bottomLeading,
            endPoint: phase && isActive && !reduceMotion ? .bottomTrailing : .topTrailing
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            updateAnimation(active: isActive && !reduceMotion)
        }
        .onChange(of: isActive) { _, newValue in
            updateAnimation(active: newValue && !reduceMotion)
        }
        .onChange(of: reduceMotion) { _, newValue in
            updateAnimation(active: isActive && !newValue)
        }
    }

    private func updateAnimation(active: Bool) {
        guard active else {
            phase = false
            return
        }
        withAnimation(.easeInOut(duration: 7).repeatForever(autoreverses: true)) {
            phase = true
        }
    }
}

private extension RecordingTransferStatus {
    var watchActionLabel: String {
        switch self {
        case .unavailable: "Ready offline"
        case .queuedForTransfer: "Sending to iPhone"
        case .received: "Imported on iPhone"
        case .failed: "Retry needed"
        }
    }

    var watchTint: Color {
        switch self {
        case .unavailable: .orange
        case .queuedForTransfer: .green
        case .received: .cyan
        case .failed: .red
        }
    }

    var watchSymbol: String {
        switch self {
        case .unavailable: "icloud.slash"
        case .queuedForTransfer: "checkmark.icloud"
        case .received: "iphone.gen3"
        case .failed: "exclamationmark.icloud"
        }
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
        case .transcribing: .cyan
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
