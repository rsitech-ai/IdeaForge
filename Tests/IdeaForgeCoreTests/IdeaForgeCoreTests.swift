import AVFoundation
import XCTest
@testable import IdeaForgeCore

private struct FixedStorageCapacityChecker: StorageCapacityChecking {
    var availableBytes: Int64

    func availableCapacityBytes(for url: URL) throws -> Int64 {
        availableBytes
    }
}

private struct FixedAudioRecordingPermissionClient: AudioRecordingPermissionChecking {
    var isGranted: Bool

    func requestRecordPermission() async -> Bool {
        isGranted
    }
}

private final class TrackingStorageCapacityChecker: StorageCapacityChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func availableCapacityBytes(for url: URL) throws -> Int64 {
        lock.lock()
        count += 1
        lock.unlock()
        return 1_000_000_000
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

final class IdeaForgeCoreTests: XCTestCase {
    private static func fixtureAppStoreTransactionJWS(
        productID: String,
        transactionID: String,
        originalTransactionID: String,
        appBundleID: String
    ) -> String {
        let header: [String: Any] = ["alg": "ES256", "typ": "JWT"]
        let payload: [String: Any] = [
            "productId": productID,
            "transactionId": transactionID,
            "originalTransactionId": originalTransactionID,
            "bundleId": appBundleID
        ]
        return [
            base64URLEncodedJSON(header),
            base64URLEncodedJSON(payload),
            base64URLEncodedData(Data("fixture-signature".utf8))
        ].joined(separator: ".")
    }

    private static func base64URLEncodedJSON(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return base64URLEncodedData(data)
    }

    private static func base64URLEncodedData(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    func testStoragePreflightFailsClosedWhenAvailableCapacityIsBelowRequirement() throws {
        let preflight = StoragePreflight(
            minimumFreeBytes: 1_000,
            capacityChecker: FixedStorageCapacityChecker(availableBytes: 999)
        )

        do {
            try preflight.validateWritableVolume(
                for: FileManager.default.temporaryDirectory,
                estimatedWriteBytes: 128
            )
            XCTFail("Expected low storage to fail closed before writing.")
        } catch let error as StoragePreflightError {
            XCTAssertEqual(error, .insufficientStorage(requiredBytes: 1_128, availableBytes: 999))
            XCTAssertFalse(error.userFacingMessage.localizedCaseInsensitiveContains(FileManager.default.temporaryDirectory.path))
        }
    }

    func testIdeaBriefFileWriterFailsBeforeWritingWhenStoragePreflightFails() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "IdeaForgeLowStorageBriefTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let brief = IdeaBriefExporter.brief(for: SampleData.ideaForgeProject, exportedAt: SampleData.now)
        let writer = IdeaBriefFileWriter(
            rootDirectory: root,
            storagePreflight: StoragePreflight(
                minimumFreeBytes: 1_000_000,
                capacityChecker: FixedStorageCapacityChecker(availableBytes: 1)
            )
        )

        do {
            _ = try writer.write(brief)
            XCTFail("Expected low storage to fail before creating the share file.")
        } catch let error as IdeaBriefExportError {
            guard case .storage(let storageError) = error else {
                return XCTFail("Expected storage error, got \(error).")
            }
            XCTAssertEqual(storageError.availableBytes, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        }
    }

    @MainActor
    func testLocalAudioRecorderFailsBeforeStartingWhenStoragePreflightFails() async throws {
        let recorder = LocalAudioRecorder(
            storagePreflight: StoragePreflight(
                minimumFreeBytes: 1_000_000,
                capacityChecker: FixedStorageCapacityChecker(availableBytes: 1)
            ),
            permissionClient: FixedAudioRecordingPermissionClient(isGranted: true)
        )

        do {
            try await recorder.start()
            XCTFail("Expected recording to fail before starting under low storage.")
        } catch let error as AudioRecordingError {
            guard case .storage(let storageError) = error else {
                return XCTFail("Expected storage error, got \(error).")
            }
            XCTAssertEqual(storageError.availableBytes, 1)
            XCTAssertFalse(recorder.isRecording)
        }
    }

    @MainActor
    func testLocalAudioRecorderFailsClosedBeforeStorageWhenMicrophonePermissionIsDenied() async throws {
        let capacityChecker = TrackingStorageCapacityChecker()
        let recorder = LocalAudioRecorder(
            storagePreflight: StoragePreflight(
                minimumFreeBytes: 1,
                capacityChecker: capacityChecker
            ),
            permissionClient: FixedAudioRecordingPermissionClient(isGranted: false)
        )

        do {
            try await recorder.start()
            XCTFail("Expected microphone permission denial to stop recording startup.")
        } catch let error as AudioRecordingError {
            XCTAssertEqual(error, .permissionDenied)
            XCTAssertFalse(recorder.isRecording)
            XCTAssertEqual(capacityChecker.callCount, 0)
            XCTAssertFalse(error.userFacingMessage.localizedCaseInsensitiveContains(FileManager.default.temporaryDirectory.path))
        }
    }

    func testLocalAudioRecorderNormalizesMeterPowerForWatchPulse() {
        XCTAssertEqual(LocalAudioRecorder.normalizedPowerLevel(decibels: -.infinity), 0)
        XCTAssertEqual(LocalAudioRecorder.normalizedPowerLevel(decibels: -90), 0)
        XCTAssertLessThan(LocalAudioRecorder.normalizedPowerLevel(decibels: -45), LocalAudioRecorder.normalizedPowerLevel(decibels: -18))
        XCTAssertEqual(LocalAudioRecorder.normalizedPowerLevel(decibels: 0), 1, accuracy: 0.0001)
        XCTAssertEqual(LocalAudioRecorder.normalizedPowerLevel(decibels: 12), 1, accuracy: 0.0001)
    }

    func testLocalAudioRecorderUsesHighQualityMonoSpeechProfile() {
        XCTAssertEqual(AudioRecordingProfile.highQualitySpeech.sampleRate, 44_100)
        XCTAssertEqual(AudioRecordingProfile.highQualitySpeech.channelCount, 1)
        XCTAssertEqual(AudioRecordingProfile.highQualitySpeech.bitRate, 96_000)
        XCTAssertEqual(AudioRecordingProfile.highQualitySpeech.encoderQuality, .high)
    }

    func testRecordingRecoveryJournalSurvivesRelaunchUntilWorkspacePersistenceIsAcknowledged() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "IdeaForgeRecordingRecoveryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audioURL = root.appending(path: "recovered.m4a")
        try Data("recoverable audio".utf8).write(to: audioURL)
        let checkpointURL = root.appending(path: "active-recording.json")
        let context = RecordingCaptureContext(
            projectTitle: "Recovered Watch idea",
            tag: .appIdea,
            source: .watch,
            transcriptHint: "Recovered after interruption.",
            ideaProjectID: "idea_recovery_stable",
            recordingID: "rec_recovery_stable",
            targetProjectID: "idea_existing_target"
        )
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let endedAt = startedAt.addingTimeInterval(27)
        let store = FileRecordingRecoveryCheckpointStore(fileURL: checkpointURL)
        let journal = RecordingRecoveryJournal(store: store)

        try journal.begin(context: context, localAudioURL: audioURL, startedAt: startedAt)
        try journal.addMarker(at: 8)
        try journal.markTerminated(reason: .interrupted, at: endedAt)

        let relaunchedJournal = RecordingRecoveryJournal(store: store)
        let pending = try XCTUnwrap(relaunchedJournal.pendingRecovery(now: endedAt))
        XCTAssertEqual(pending.draft.ideaProjectID, "idea_recovery_stable")
        XCTAssertEqual(pending.draft.recordingID, "rec_recovery_stable")
        XCTAssertEqual(pending.draft.localAudioPath, audioURL.path)
        XCTAssertEqual(pending.draft.durationSeconds, 27)
        XCTAssertEqual(pending.draft.markerOffsets, [8])
        XCTAssertEqual(pending.targetProjectID, "idea_existing_target")
        XCTAssertEqual(pending.terminationReason, .interrupted)

        try relaunchedJournal.acknowledgePersistence()
        XCTAssertNil(try relaunchedJournal.pendingRecovery(now: endedAt))
    }

    @MainActor
    func testLocalAudioRecorderClearsInvalidRecoveryCheckpointAfterReportingMissingAudio() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "IdeaForgeInvalidRecoveryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let checkpointURL = root.appending(path: "active-recording.json")
        let journal = RecordingRecoveryJournal(
            store: FileRecordingRecoveryCheckpointStore(fileURL: checkpointURL)
        )
        try journal.begin(
            context: RecordingCaptureContext(
                projectTitle: "Missing audio",
                tag: .random,
                source: .iphone,
                transcriptHint: "Missing audio should fail closed."
            ),
            localAudioURL: root.appending(path: "missing.m4a"),
            startedAt: SampleData.now
        )
        let recorder = LocalAudioRecorder(
            permissionClient: FixedAudioRecordingPermissionClient(isGranted: true),
            recoveryJournal: journal
        )

        XCTAssertThrowsError(try recorder.pendingRecovery(now: SampleData.now)) { error in
            XCTAssertEqual(error as? AudioRecordingError, .recoveryAudioMissing)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkpointURL.path))
    }

    @MainActor
    func testRecoveredCaptureReplayUsesStableIDsAndDoesNotDuplicateWorkspaceWork() async throws {
        let repository = InMemoryWorkspaceRepository()
        let store = IdeaForgeStore(
            projects: [],
            workflowTemplates: DefaultWorkflows.templates,
            selectedProjectID: nil,
            privacyMode: .privateLocal,
            syncHealth: SyncHealth(
                watchReachable: false,
                queuedUploads: 0,
                lastSuccessfulSync: SampleData.now,
                failingItems: 0
            ),
            repository: repository
        )
        let draft = RecordingDraft(
            projectTitle: "Recovered iPhone idea",
            tag: .appIdea,
            source: .iphone,
            durationSeconds: 18,
            transcriptHint: "Recovered once.",
            localAudioPath: "recordings/recovered-stable.m4a",
            ideaProjectID: "idea_recovered_once",
            recordingID: "rec_recovered_once"
        )

        let first = await store.capture(draft)
        let replay = await store.capture(draft)

        XCTAssertEqual(first?.id, "idea_recovered_once")
        XCTAssertEqual(replay?.id, first?.id)
        XCTAssertEqual(store.projects.count, 1)
        XCTAssertEqual(store.projects.first?.recordings.map(\.id), ["rec_recovered_once"])
        XCTAssertEqual(store.uploadJobs.map(\.recordingID), ["rec_recovered_once"])
    }

    @MainActor
    func testRecoveredWatchAppendReplayUsesStableRecordingID() async throws {
        let state = WorkspaceState.seed()
        let store = IdeaForgeStore(state: state, repository: InMemoryWorkspaceRepository())
        let targetProject = try XCTUnwrap(store.projects.first)
        let draft = RecordingDraft(
            projectTitle: targetProject.title,
            tag: .appIdea,
            source: .watch,
            durationSeconds: 12,
            transcriptHint: "Recovered Watch append.",
            localAudioPath: "recordings/recovered-watch-append.m4a",
            ideaProjectID: "idea_recovered_append_capture",
            recordingID: "rec_recovered_append_once"
        )

        let first = await store.appendWatchRecording(draft, to: targetProject.id)
        let replay = await store.appendWatchRecording(draft, to: targetProject.id)

        XCTAssertEqual(first?.id, "rec_recovered_append_once")
        XCTAssertEqual(replay?.id, first?.id)
        XCTAssertEqual(
            store.projects.first(where: { $0.id == targetProject.id })?.recordings
                .filter { $0.id == "rec_recovered_append_once" }.count,
            1
        )
        XCTAssertEqual(store.uploadJobs.filter { $0.recordingID == "rec_recovered_append_once" }.count, 1)
    }

    func testPacketFileSystemWriterFailsBeforeWritingWhenStoragePreflightFails() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "IdeaForgeLowStoragePacketTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let writer = PacketFileSystemWriter(
            rootDirectory: root,
            storagePreflight: StoragePreflight(
                minimumFreeBytes: 1_000_000,
                capacityChecker: FixedStorageCapacityChecker(availableBytes: 1)
            )
        )

        do {
            _ = try writer.write(
                packet: EngineeringPacketBuilder.packet(for: SampleData.ideaForgeProject),
                for: SampleData.ideaForgeProject,
                exportedAt: SampleData.now
            )
            XCTFail("Expected packet export to fail before creating files.")
        } catch let error as PacketExportError {
            guard case .storage(let storageError) = error else {
                return XCTFail("Expected storage error, got \(error).")
            }
            XCTAssertEqual(storageError.availableBytes, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        }
    }

    @MainActor
    func testTransferredRecordingImporterFailsBeforeCopyingWhenStoragePreflightFails() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "IdeaForgeLowStorageImportTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appending(path: "watch-source.m4a")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("watch audio".utf8).write(to: sourceURL)

        let importer = TransferredRecordingImporter(
            inboxDirectory: root.appending(path: "inbox", directoryHint: .isDirectory),
            storagePreflight: StoragePreflight(
                minimumFreeBytes: 1_000_000,
                capacityChecker: FixedStorageCapacityChecker(availableBytes: 1)
            )
        )
        let store = SampleData.store()
        let metadata = RecordingTransferMetadata(
            recordingID: "rec_low_storage",
            ideaProjectID: "idea_low_storage",
            sourceDeviceName: "Apple Watch",
            durationSeconds: 12,
            languageHint: "en-US",
            markerOffsets: [],
            createdAt: SampleData.now
        )

        do {
            _ = try await importer.importFile(sourceURL: sourceURL, metadata: metadata, into: store)
            XCTFail("Expected import to fail before copying.")
        } catch let error as TransferredRecordingImportError {
            guard case .storage(let storageError) = error else {
                return XCTFail("Expected storage error, got \(error).")
            }
            XCTAssertEqual(storageError.availableBytes, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "inbox").path))
        }
    }

    func testEncryptedLocalAudioObjectStoreFailsBeforeWritingWhenStoragePreflightFails() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "IdeaForgeLowStorageObjectTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appending(path: "source.m4a")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: sourceURL)

        let objectRoot = root.appending(path: "objects", directoryHint: .isDirectory)
        let objectStore = EncryptedLocalAudioObjectStore(
            objectRoot: objectRoot,
            keyProvider: StaticObjectEncryptionKeyProvider.testKey(),
            storagePreflight: StoragePreflight(
                minimumFreeBytes: 1_000_000,
                capacityChecker: FixedStorageCapacityChecker(availableBytes: 1)
            )
        )

        do {
            try objectStore.storeAudio(
                from: sourceURL,
                objectKey: "audio/idea/rec.m4a",
                recordingID: "rec_low_storage",
                ideaProjectID: "idea_low_storage"
            )
            XCTFail("Expected object store to fail before writing.")
        } catch let error as LocalAudioObjectStoreError {
            guard case .storage(let storageError) = error else {
                return XCTFail("Expected storage error, got \(error).")
            }
            XCTAssertEqual(storageError.availableBytes, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: objectRoot.path))
        }
    }

    func testSampleStoreExposesProductionObjects() {
        let store = SampleData.store()

        XCTAssertEqual(store.projects.count, 2)
        XCTAssertEqual(store.workflowTemplates.count, 4)
        XCTAssertEqual(store.pendingQuestions.count, 2)
        XCTAssertEqual(store.queuedRecordings.count, 2)
        XCTAssertEqual(store.selectedProject?.title, "IdeaForge")
    }

    func testDefaultCodexWorkflowRequiresReviewBeforeToolAction() {
        let workflow = DefaultWorkflows.templates.first { $0.id == "wf_codex_packet" }

        XCTAssertNotNil(workflow)
        XCTAssertEqual(workflow?.outputKinds, [.codexTaskBundle, .architecture])
        XCTAssertTrue(workflow?.steps.allSatisfy(\.requiresUserReview) == true)
        XCTAssertEqual(workflow?.steps.last?.kind, .toolAction)
    }

    func testDefaultMVPWorkflowContractsCoverEveryPromisedPlanningArtifact() throws {
        let workflow = try XCTUnwrap(DefaultWorkflows.templates.first { $0.id == "wf_app_idea_mvp" })
        let outputKindsByStep = Set(workflow.steps.compactMap { step in
            workflow.schemaContract(named: step.outputSchemaName)?.outputKind
        })

        XCTAssertEqual(workflow.outputKinds, [.ideaBrief, .roadmap, .validationPlan])
        XCTAssertEqual(outputKindsByStep, Set(workflow.outputKinds))
        XCTAssertTrue(workflow.steps.contains { $0.outputSchemaName == "IdeaBriefArtifact" })
        XCTAssertTrue(workflow.steps.contains { $0.outputSchemaName == "MVPPlanArtifact" })
        XCTAssertTrue(workflow.steps.contains { $0.outputSchemaName == "ValidationPlanArtifact" })
    }

    func testDefaultFullBuildPacketWorkflowCoversOriginalPlanArtifacts() throws {
        let workflow = try XCTUnwrap(DefaultWorkflows.templates.first { $0.id == "wf_full_build_packet" })
        let expectedOutputKinds: [ArtifactKind] = [
            .ideaBrief,
            .prd,
            .architecture,
            .uxFlow,
            .dataModel,
            .apiDesign,
            .roadmap,
            .issueBundle,
            .codexTaskBundle,
            .launchChecklist
        ]
        let outputKindsByStep = Set(workflow.steps.compactMap { step in
            workflow.schemaContract(named: step.outputSchemaName)?.outputKind
        })

        XCTAssertEqual(workflow.outputKinds, expectedOutputKinds)
        XCTAssertEqual(outputKindsByStep, Set(expectedOutputKinds))
        XCTAssertTrue(workflow.steps.allSatisfy(\.requiresUserReview))
        XCTAssertTrue(workflow.steps.contains { $0.kind == .toolAction && $0.outputSchemaName == "CodexPacketSchema" })

        for schemaName in [
            "UXFlowArtifact",
            "DataModelArtifact",
            "APIDesignArtifact",
            "IssueBundleArtifact",
            "LaunchChecklistArtifact"
        ] {
            let contract = try XCTUnwrap(DefaultWorkflows.schemaContracts.first { $0.name == schemaName })
            XCTAssertFalse(contract.fields.isEmpty, "\(schemaName) should expose required fields.")
            XCTAssertTrue(contract.fields.allSatisfy(\.isRequired), "\(schemaName) fields should be required.")
        }
    }

    func testEngineeringPacketContainsSafeHandoffFiles() {
        let project = SampleData.ideaForgeProject
        let packet = EngineeringPacketBuilder.packet(for: project)
        let paths = packet.files.map(\.path)

        XCTAssertTrue(paths.contains("project-context.md"))
        XCTAssertTrue(paths.contains("tasks/001-bootstrap-native-apple-project.md"))
        XCTAssertTrue(paths.contains(".codex/instructions.md"))
        XCTAssertTrue(packet.files.contains { file in
            file.contents.contains("without operator approval") ||
            file.contents.contains("without explicit approval")
        })
    }

    func testEngineeringPacketExportsEveryCodexTaskAsItsOwnFile() {
        var project = SampleData.ideaForgeProject
        project.codexTasks.append(
            CodexTask(
                id: "task_second",
                title: "Wire backend sync",
                acceptanceCriteria: ["Snapshot publish succeeds"],
                testPlan: ["Run sync engine tests"]
            )
        )

        let packet = EngineeringPacketBuilder.packet(for: project)
        let taskPaths = packet.files.map(\.path).filter { $0.hasPrefix("tasks/") }

        XCTAssertEqual(taskPaths, [
            "tasks/001-bootstrap-native-apple-project.md",
            "tasks/002-wire-backend-sync.md"
        ])
        XCTAssertTrue(packet.files.contains { $0.path == "tasks/002-wire-backend-sync.md" && $0.contents.contains("Snapshot publish succeeds") })

        var emptyProject = project
        emptyProject.codexTasks = []
        let fallbackPaths = EngineeringPacketBuilder.packet(for: emptyProject).files.map(\.path).filter { $0.hasPrefix("tasks/") }
        XCTAssertEqual(fallbackPaths, ["tasks/001-bootstrap-project.md"])
    }

    func testIdeaBriefExporterBuildsShareableMarkdownWithoutPrivateStorageDetails() {
        var project = SampleData.ideaForgeProject
        project.questions[0].answer = "Founders who already use Codex for weekend prototypes."

        let brief = IdeaBriefExporter.brief(for: project, exportedAt: SampleData.now)

        XCTAssertEqual(brief.filename, "IdeaForge-idea-brief.md")
        XCTAssertTrue(brief.markdown.contains("# Idea Brief: IdeaForge"))
        XCTAssertTrue(brief.markdown.contains("Status: Ready for Build"))
        XCTAssertTrue(brief.markdown.contains("Source: Watch"))
        XCTAssertTrue(brief.markdown.contains("Speak an idea into Watch"))
        XCTAssertTrue(brief.markdown.contains("## Questions"))
        XCTAssertTrue(brief.markdown.contains("Who is the first user who needs this badly enough to pay?"))
        XCTAssertTrue(brief.markdown.contains("Founders who already use Codex for weekend prototypes."))
        XCTAssertTrue(brief.markdown.contains("## Assumptions"))
        XCTAssertTrue(brief.markdown.contains("iPhone bridge materially improves Watch recording reliability."))
        XCTAssertTrue(brief.markdown.contains("## Validation"))
        XCTAssertTrue(brief.markdown.contains("Builder workflow interviews"))
        XCTAssertTrue(brief.markdown.contains("## Artifacts"))
        XCTAssertTrue(brief.markdown.contains("Product Requirements Document"))
        XCTAssertTrue(brief.markdown.contains("## Codex Tasks"))
        XCTAssertTrue(brief.markdown.contains("Bootstrap native Apple project"))
        XCTAssertTrue(brief.markdown.contains("Recordings: 2 total, 1 uploaded, 1 retained locally."))
        XCTAssertFalse(brief.markdown.contains("recordings/rec_watch_2.m4a"))
        XCTAssertFalse(brief.markdown.contains("audio/idea_ideaforge/rec_watch_1.m4a"))
        XCTAssertFalse(brief.markdown.localizedCaseInsensitiveContains("bearer"))
        XCTAssertFalse(brief.markdown.localizedCaseInsensitiveContains("token"))
    }

    func testIdeaBriefFileWriterWritesMarkdownFileForNativeShare() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "IdeaForgeBriefTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let brief = IdeaBriefExporter.brief(for: SampleData.ideaForgeProject, exportedAt: SampleData.now)

        let url = try IdeaBriefFileWriter(rootDirectory: root).write(brief)

        XCTAssertEqual(url.lastPathComponent, "IdeaForge-idea-brief.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try String(contentsOf: url), brief.markdown)
    }

    func testCodexHandoffReviewTracksExportOnlyReadiness() {
        let blockedProject = SampleData.ideaForgeProject
        let blockedReview = EngineeringPacketBuilder.handoffReview(for: blockedProject)

        XCTAssertFalse(blockedReview.isReadyForExportOnlyHandoff)
        XCTAssertEqual(blockedReview.blockingQuestionCount, 1)
        XCTAssertTrue(blockedReview.blockers.contains("Answer 1 blocking question before handoff."))
        XCTAssertTrue(blockedReview.hasApprovalBoundary)
        XCTAssertTrue(blockedReview.hasAcceptanceTests)
        XCTAssertTrue(blockedReview.hasCodexInstructions)

        var readyProject = blockedProject
        readyProject.questions = readyProject.questions.map { question in
            var answered = question
            if answered.isBlocking {
                answered.answer = "Founders who already use Codex for weekend prototypes."
            }
            return answered
        }

        let readyReview = EngineeringPacketBuilder.handoffReview(for: readyProject)
        XCTAssertTrue(readyReview.isReadyForExportOnlyHandoff)
        XCTAssertEqual(readyReview.blockers, [])
        XCTAssertEqual(readyReview.fileCount, EngineeringPacketBuilder.packet(for: readyProject).files.count)
        XCTAssertEqual(readyReview.taskCount, readyProject.codexTasks.count)
    }

    func testCanonicalUploadSummaryRetainsUnassociatedAggregateFailureWithoutDoubleCounting() throws {
        let store = SampleData.store()
        let recording = try XCTUnwrap(store.projects.flatMap(\.recordings).first { $0.localAudioPath != nil })
        let now = Date(timeIntervalSince1970: 1_000)
        let failedJob = UploadJob(
            id: "upload_\(recording.id)", recordingID: recording.id,
            ideaProjectID: recording.ideaProjectID,
            localAudioPath: try XCTUnwrap(recording.localAudioPath),
            status: .permanentlyFailed, attemptCount: UploadQueuePolicy.maximumAttempts,
            nextAttemptAt: now, lastErrorMessage: "Server unavailable",
            createdAt: now, updatedAt: now
        )
        var projects = store.projects
        let projectIndex = try XCTUnwrap(projects.firstIndex { $0.id == recording.ideaProjectID })
        let recordingIndex = try XCTUnwrap(projects[projectIndex].recordings.firstIndex { $0.id == recording.id })
        projects[projectIndex].recordings[recordingIndex].syncStatus = .failed
        let health = SyncHealth(
            watchReachable: true, queuedUploads: 0, lastSuccessfulSync: now,
            failingItems: 2
        )

        let summary = CanonicalUploadSummary(projects: projects, uploadJobs: [failedJob], syncHealth: health)

        XCTAssertEqual(summary.permanentlyFailedCount, 2)
        XCTAssertEqual(summary.failedRecordingIDs, Set([recording.id]))
    }

    func testInboxStatusPriorityIsConflictThenFailureThenQueueThenOffline() {
        let conflict = InboxStatusSnapshot(
            uploadSummary: .init(permanentlyFailedCount: 2, queuedCount: 3),
            syncConflict: WorkspaceSyncConflictStatus(
                localOnlyUploadJobCount: 1,
                localOnlyRecordingCount: 1,
                detectedAt: Date(timeIntervalSince1970: 1_000)
            ),
            watchReachable: false
        )
        XCTAssertEqual(conflict?.kind, .syncConflict)

        let failure = InboxStatusSnapshot(
            uploadSummary: .init(permanentlyFailedCount: 2, queuedCount: 3),
            syncConflict: nil,
            watchReachable: false
        )
        XCTAssertEqual(failure, .init(kind: .failedUpload, title: "2 uploads failed", action: .review))

        let queue = InboxStatusSnapshot(
            uploadSummary: .init(permanentlyFailedCount: 0, queuedCount: 3),
            syncConflict: nil,
            watchReachable: false
        )
        XCTAssertEqual(queue, .init(kind: .queuedUpload, title: "3 recordings waiting", action: .upload))

        let offline = InboxStatusSnapshot(
            uploadSummary: .init(permanentlyFailedCount: 0, queuedCount: 0),
            syncConflict: nil,
            watchReachable: false
        )
        XCTAssertEqual(offline, .init(kind: .offline, title: "Watch offline", action: nil))
    }

    func testInboxStatusSnapshotIsNilForCleanReachableState() {
        let summary = CanonicalUploadSummary(permanentlyFailedCount: 0, queuedCount: 0)

        let snapshot = InboxStatusSnapshot(
            uploadSummary: summary,
            syncConflict: nil,
            watchReachable: true
        )

        XCTAssertNil(snapshot)
    }

    func testTaskFirstFixtureStatesProduceExpectedInboxStatus() {
        let expectedStatuses: [(state: TaskFirstFixtureState, expected: InboxStatusKind?)] = [
            (.clean, nil),
            (.queuedUpload, .queuedUpload),
            (.failedUpload, .failedUpload),
            (.offlineWatch, .offline),
            (.syncConflict, .syncConflict)
        ]

        for fixture in expectedStatuses {
            let store = SampleData.taskFirstStore(state: fixture.state)
            let snapshot = InboxStatusSnapshot(
                uploadSummary: CanonicalUploadSummary(
                    projects: store.projects,
                    uploadJobs: store.uploadJobs,
                    syncHealth: store.syncHealth
                ),
                syncConflict: store.syncHealth.syncConflictStatus,
                watchReachable: store.syncHealth.watchReachable
            )

            XCTAssertEqual(snapshot?.kind, fixture.expected, "Unexpected Inbox status for \(fixture.state).")
        }
    }

    func testTaskFirstUploadFixturesRetainValidRegularAudioAndCanonicalHealth() throws {
        for state in [TaskFirstFixtureState.queuedUpload, .failedUpload] {
            let store = SampleData.taskFirstStore(state: state)
            XCTAssertEqual(store.projects.flatMap(\.recordings).count, state == .failedUpload ? 4 : 1)
            XCTAssertEqual(store.uploadJobs.count, state == .failedUpload ? 4 : 1)
            let recording = try XCTUnwrap(
                store.projects.flatMap(\.recordings)
                    .first { $0.id == "rec_task_first_upload" }
            )
            let job = try XCTUnwrap(
                store.uploadJobs.first { $0.recordingID == recording.id }
            )
            let audioPath = try XCTUnwrap(recording.localAudioPath)

            XCTAssertEqual(job.recordingID, recording.id)
            XCTAssertEqual(job.localAudioPath, audioPath)
            XCTAssertTrue(FileManager.default.fileExists(atPath: audioPath))
            XCTAssertEqual(
                try FileManager.default.attributesOfItem(atPath: audioPath)[.type] as? FileAttributeType,
                .typeRegular
            )
            let audioFile = try AVAudioFile(forReading: URL(filePath: audioPath))
            XCTAssertGreaterThan(audioFile.length, 0)
            XCTAssertGreaterThan(audioFile.fileFormat.sampleRate, 0)
            let uploadSummary = CanonicalUploadSummary(
                projects: store.projects,
                uploadJobs: store.uploadJobs,
                syncHealth: store.syncHealth
            )
            XCTAssertEqual(
                uploadSummary.permanentlyFailedCount,
                state == .failedUpload ? 1 : 0
            )
            XCTAssertEqual(uploadSummary.queuedCount, state == .failedUpload ? 3 : 1)
            XCTAssertEqual(store.syncHealth.failingItems, 0)
            XCTAssertEqual(store.syncHealth.queuedUploads, state == .queuedUpload ? 1 : 0)
        }
    }

    func testFailedTaskFirstFixtureKeepsCanonicalJobCountsWhenAggregateHealthLags() throws {
        let store = SampleData.taskFirstStore(state: .failedUpload)
        let dashboard = MobileDashboardSnapshot(
            projects: store.projects,
            syncHealth: store.syncHealth,
            privacyMode: store.privacyMode,
            uploadJobs: store.uploadJobs
        )
        let readiness = MobileSyncReadinessSnapshot(
            projects: store.projects,
            syncHealth: store.syncHealth,
            privacyMode: store.privacyMode,
            uploadJobs: store.uploadJobs
        )
        let inbox = InboxStatusSnapshot(
            uploadSummary: CanonicalUploadSummary(
                projects: store.projects,
                uploadJobs: store.uploadJobs,
                syncHealth: store.syncHealth
            ),
            syncConflict: store.syncHealth.syncConflictStatus,
            watchReachable: store.syncHealth.watchReachable
        )

        XCTAssertEqual(store.syncHealth.failingItems, 0)
        XCTAssertEqual(store.syncHealth.queuedUploads, 0)
        XCTAssertEqual(
            store.uploadJobs.map(\.status.rawValue).sorted(),
            [
                UploadJobStatus.permanentlyFailed.rawValue,
                UploadJobStatus.queued.rawValue,
                UploadJobStatus.uploading.rawValue,
                UploadJobStatus.waitingForRetry.rawValue
            ].sorted()
        )
        XCTAssertNotNil(
            store.projects.flatMap(\.recordings)
                .first { $0.id == "rec_task_first_upload" }?
                .processingDiagnostic
        )
        XCTAssertEqual(dashboard.failedUploadCount, 1)
        XCTAssertEqual(dashboard.queuedUploadCount, 3)
        XCTAssertEqual(readiness.failedItemCount, 1)
        XCTAssertEqual(readiness.queuedCaptureCount, 3)
        XCTAssertEqual(inbox?.title, "1 upload failed")
    }

    func testTaskFirstOfflineFixtureDiffersFromCleanOnlyByWatchReachability() {
        let clean = SampleData.taskFirstStore(state: .clean).workspaceState(now: SampleData.now)
        let offline = SampleData.taskFirstStore(state: .offlineWatch).workspaceState(now: SampleData.now)

        XCTAssertEqual(offline.projects, clean.projects)
        XCTAssertEqual(offline.uploadJobs, clean.uploadJobs)
        XCTAssertEqual(offline.workflowTemplates, clean.workflowTemplates)
        XCTAssertEqual(offline.privacyMode, clean.privacyMode)
        XCTAssertEqual(offline.syncHealth.queuedUploads, clean.syncHealth.queuedUploads)
        XCTAssertEqual(offline.syncHealth.failingItems, clean.syncHealth.failingItems)
        XCTAssertEqual(offline.syncHealth.syncConflictStatus, clean.syncHealth.syncConflictStatus)
        XCTAssertFalse(offline.syncHealth.watchReachable)
        XCTAssertTrue(clean.syncHealth.watchReachable)
        XCTAssertFalse(clean.uploadJobs.contains { $0.status == .queued || $0.status == .uploading || $0.status == .waitingForRetry })
        XCTAssertFalse(clean.uploadJobs.contains { $0.status == .permanentlyFailed })
        XCTAssertFalse(clean.projects.flatMap(\.recordings).contains { $0.syncStatus == .failed })
        XCTAssertEqual(clean.syncHealth.failingItems, 0)
        XCTAssertEqual(clean.syncHealth.queuedUploads, 0)
    }

    func testRecordingRowSnapshotPrioritizesScheduledRetryOverRemoteReceipt() throws {
        let project = SampleData.ideaForgeProject
        let recording = try XCTUnwrap(project.recordings.first)
        let now = Date(timeIntervalSince1970: 1_000)
        let job = UploadJob(
            id: "upload_\(recording.id)",
            recordingID: recording.id,
            ideaProjectID: recording.ideaProjectID,
            localAudioPath: "recordings/\(recording.id).m4a",
            status: .waitingForRetry,
            attemptCount: 1,
            nextAttemptAt: now,
            createdAt: now,
            updatedAt: now
        )

        let snapshot = RecordingRowSnapshot(
            recording: recording,
            projectTitle: project.title,
            uploadJob: job,
            hasRemoteReceipt: true
        )

        XCTAssertEqual(snapshot.id, recording.id)
        XCTAssertEqual(snapshot.title, project.title)
        XCTAssertEqual(snapshot.durationSeconds, recording.durationSeconds)
        XCTAssertEqual(snapshot.createdAt, recording.createdAt)
        XCTAssertEqual(snapshot.state, .retryScheduled)
    }

    func testRecordingHistoryBuildsLargeNewestFirstSnapshotFromIndexedJobs() {
        let baseDate = Date(timeIntervalSince1970: 10_000)
        let recordings = (0..<1_000).map { index in
            Recording(
                id: "rec_history_\(index)",
                ideaProjectID: "idea_history",
                deviceName: "iPhone",
                durationSeconds: index + 1,
                localFileStatus: .available,
                syncStatus: .pending,
                localAudioPath: "recordings/rec_history_\(index).m4a",
                languageHint: "en",
                createdAt: baseDate.addingTimeInterval(TimeInterval(index)),
                markerOffsets: []
            )
        }
        var project = SampleData.ideaForgeProject
        project.id = "idea_history"
        project.title = "History"
        project.recordings = recordings
        let jobs = recordings.reversed().map { recording in
            UploadQueuePolicy.job(
                for: recording,
                localAudioPath: recording.localAudioPath!,
                now: baseDate
            )
        }

        let rows = RecordingRowSnapshot.history(projects: [project], uploadJobs: jobs)

        XCTAssertEqual(rows.count, 1_000)
        XCTAssertEqual(rows.first?.id, "rec_history_999")
        XCTAssertEqual(rows.last?.id, "rec_history_0")
        XCTAssertEqual(rows.first?.state, .readyToUpload)
        XCTAssertEqual(Set(rows.map(\.id)).count, 1_000)
    }

    func testUploadDiagnosticsBuildsLargeStableIndexedContextAndHistory() {
        let baseDate = Date(timeIntervalSince1970: 20_000)
        var recordings: [Recording] = []
        var currentJobs: [UploadJob] = []
        var staleJobs: [UploadJob] = []

        for index in 0..<1_000 {
            var recording = Recording(
                id: "rec_diagnostic_\(index)",
                ideaProjectID: "idea_diagnostics",
                deviceName: index.isMultiple(of: 2) ? "Apple Watch" : "iPhone",
                durationSeconds: index + 1,
                localFileStatus: .available,
                syncStatus: .pending,
                localAudioPath: "recordings/rec_diagnostic_\(index).m4a",
                languageHint: "en",
                createdAt: baseDate.addingTimeInterval(TimeInterval(index)),
                markerOffsets: []
            )
            if index.isMultiple(of: 100) {
                recording.processingDiagnostic = RecordingProcessingDiagnostic(
                    code: .transcriptionFailed,
                    message: "Retry transcription.",
                    isRetryable: true,
                    failedAt: baseDate.addingTimeInterval(TimeInterval(index))
                )
            }
            recordings.append(recording)

            let status: UploadJobStatus = switch index % 4 {
            case 0: .queued
            case 1: .uploading
            case 2: .waitingForRetry
            default: .permanentlyFailed
            }
            let updatedAt = baseDate.addingTimeInterval(TimeInterval(index))
            currentJobs.append(
                UploadJob(
                    id: "upload_current_\(index)",
                    recordingID: recording.id,
                    ideaProjectID: recording.ideaProjectID,
                    localAudioPath: recording.localAudioPath!,
                    status: status,
                    attemptCount: status == .permanentlyFailed ? UploadQueuePolicy.maximumAttempts : (status == .queued ? 0 : 1),
                    nextAttemptAt: updatedAt,
                    lastErrorMessage: status == .permanentlyFailed ? "HTTP 503" : nil,
                    failureCategory: status == .permanentlyFailed ? .server : nil,
                    createdAt: baseDate,
                    updatedAt: updatedAt
                )
            )
            staleJobs.append(
                UploadJob(
                    id: "upload_stale_\(index)",
                    recordingID: recording.id,
                    ideaProjectID: recording.ideaProjectID,
                    localAudioPath: recording.localAudioPath!,
                    status: .queued,
                    attemptCount: 0,
                    nextAttemptAt: baseDate,
                    createdAt: baseDate.addingTimeInterval(-1),
                    updatedAt: baseDate.addingTimeInterval(-1)
                )
            )
        }

        var project = SampleData.ideaForgeProject
        project.id = "idea_diagnostics"
        project.title = "Diagnostics"
        project.recordings = recordings
        let jobs = staleJobs + currentJobs.reversed()

        let diagnostics = AccountUploadDiagnosticsSnapshot(
            projects: [project],
            uploadJobs: jobs
        )
        let history = RecordingRowSnapshot.history(projects: [project], uploadJobs: jobs)

        XCTAssertEqual(diagnostics.uploadContexts.count, 1_000)
        XCTAssertEqual(Set(diagnostics.uploadContexts.map(\.recording.id)).count, 1_000)
        XCTAssertTrue(diagnostics.uploadContexts.allSatisfy { $0.job.id.hasPrefix("upload_current_") })
        XCTAssertEqual(diagnostics.uploadContexts.first?.recording.id, "rec_diagnostic_999")
        XCTAssertEqual(diagnostics.uploadContexts.first?.job.status, .permanentlyFailed)
        XCTAssertEqual(diagnostics.uploadContexts[249].recording.id, "rec_diagnostic_3")
        XCTAssertEqual(diagnostics.uploadContexts[250].recording.id, "rec_diagnostic_998")
        XCTAssertEqual(diagnostics.uploadContexts[250].job.status, .waitingForRetry)
        XCTAssertEqual(diagnostics.uploadContexts.last?.recording.id, "rec_diagnostic_0")
        XCTAssertEqual(diagnostics.recordingContexts.count, 10)
        XCTAssertEqual(diagnostics.recordingContexts.first?.recording.id, "rec_diagnostic_900")
        XCTAssertEqual(Set(diagnostics.recordingContexts.map(\.recording.id)).count, 10)

        XCTAssertEqual(history.count, 1_000)
        XCTAssertEqual(Set(history.map(\.id)).count, 1_000)
        XCTAssertEqual(Array(history.prefix(4).map(\.id)), [
            "rec_diagnostic_999",
            "rec_diagnostic_998",
            "rec_diagnostic_997",
            "rec_diagnostic_996"
        ])
        XCTAssertEqual(Array(history.prefix(4).map(\.state)), [
            .failed,
            .retryScheduled,
            .uploading,
            .readyToUpload
        ])
    }

    func testMacProjectOverviewSnapshotPrioritizesBlockingQuestion() {
        let project = SampleData.ideaForgeProject

        let snapshot = MacProjectOverviewSnapshot(project: project)

        XCTAssertEqual(snapshot.purpose, project.summary)
        XCTAssertEqual(snapshot.nextStep, "Answer: Who is the first user who needs this badly enough to pay?")
        XCTAssertEqual(snapshot.rows.map(\.kind), [.summary, .validation, .readiness])
        XCTAssertEqual(snapshot.rows[1].detail, "2 assumptions, 1 experiments")
        XCTAssertEqual(snapshot.rows[2].detail, snapshot.nextStep)
    }

    func testMobileDashboardSnapshotDerivesQueueAndQuestionCounts() {
        let store = SampleData.store()
        let snapshot = MobileDashboardSnapshot(
            projects: store.projects,
            syncHealth: store.syncHealth,
            privacyMode: store.privacyMode
        )

        XCTAssertTrue(snapshot.watchReachable)
        XCTAssertEqual(snapshot.queuedUploadCount, 2)
        XCTAssertEqual(snapshot.pendingQuestionCount, 2)
        XCTAssertEqual(snapshot.blockingQuestionCount, 2)
        XCTAssertEqual(snapshot.featuredProjectTitle, "IdeaForge")
        XCTAssertEqual(snapshot.liveHealthDetail, "1 failed item needs review before sync is clean.")
    }

    func testMobileSnapshotsUseLiveUploadJobsForJobOnlyPermanentFailure() throws {
        let store = SampleData.store()
        var projects = store.projects
        for projectIndex in projects.indices {
            for recordingIndex in projects[projectIndex].recordings.indices {
                projects[projectIndex].recordings[recordingIndex].syncStatus = .ready
            }
        }
        let recording = try XCTUnwrap(projects.flatMap(\.recordings).first)
        let now = Date(timeIntervalSince1970: 1_000)
        let failedJob = UploadJob(
            id: "upload_\(recording.id)",
            recordingID: recording.id,
            ideaProjectID: recording.ideaProjectID,
            localAudioPath: "recordings/\(recording.id).m4a",
            status: .permanentlyFailed,
            attemptCount: UploadQueuePolicy.maximumAttempts,
            nextAttemptAt: now,
            lastErrorMessage: "Server unavailable",
            createdAt: now,
            updatedAt: now
        )
        let health = SyncHealth(
            watchReachable: true,
            queuedUploads: 0,
            lastSuccessfulSync: now,
            failingItems: 0
        )

        let dashboard = MobileDashboardSnapshot(
            projects: projects,
            syncHealth: health,
            privacyMode: .power,
            uploadJobs: [failedJob]
        )
        let readiness = MobileSyncReadinessSnapshot(
            projects: projects,
            syncHealth: health,
            privacyMode: .power,
            uploadJobs: [failedJob]
        )

        XCTAssertEqual(dashboard.failedUploadCount, 1)
        XCTAssertEqual(dashboard.liveHealthTitle, "Review needed")
        XCTAssertEqual(readiness.failedItemCount, 1)
        XCTAssertEqual(readiness.title, "Resolve failed sync items")
    }

    func testMobileSnapshotsUseLiveUploadJobsForQueuedAndRetryingWork() throws {
        let store = SampleData.store()
        var projects = store.projects
        for projectIndex in projects.indices {
            for recordingIndex in projects[projectIndex].recordings.indices {
                projects[projectIndex].recordings[recordingIndex].syncStatus = .ready
            }
        }
        let recordings = Array(projects.flatMap(\.recordings).prefix(2))
        XCTAssertEqual(recordings.count, 2)
        let now = Date(timeIntervalSince1970: 1_000)
        let queuedJob = UploadJob(
            id: "upload_\(recordings[0].id)",
            recordingID: recordings[0].id,
            ideaProjectID: recordings[0].ideaProjectID,
            localAudioPath: "recordings/\(recordings[0].id).m4a",
            status: .queued,
            attemptCount: 0,
            nextAttemptAt: now,
            createdAt: now,
            updatedAt: now
        )
        let retryJob = UploadJob(
            id: "upload_\(recordings[1].id)",
            recordingID: recordings[1].id,
            ideaProjectID: recordings[1].ideaProjectID,
            localAudioPath: "recordings/\(recordings[1].id).m4a",
            status: .waitingForRetry,
            attemptCount: 1,
            nextAttemptAt: now,
            createdAt: now,
            updatedAt: now
        )
        let health = SyncHealth(
            watchReachable: true,
            queuedUploads: 0,
            lastSuccessfulSync: now,
            failingItems: 0
        )

        let dashboard = MobileDashboardSnapshot(
            projects: projects,
            syncHealth: health,
            privacyMode: .power,
            uploadJobs: [queuedJob, retryJob]
        )
        let readiness = MobileSyncReadinessSnapshot(
            projects: projects,
            syncHealth: health,
            privacyMode: .power,
            uploadJobs: [queuedJob, retryJob]
        )

        XCTAssertEqual(dashboard.queuedUploadCount, 2)
        XCTAssertEqual(dashboard.liveHealthTitle, "Upload queue active")
        XCTAssertEqual(readiness.queuedCaptureCount, 2)
        XCTAssertEqual(readiness.title, "Captures waiting to sync")
    }

    func testMobileDashboardSnapshotPrioritizesLiveHealthFailures() {
        let store = SampleData.store()
        let snapshot = MobileDashboardSnapshot(
            projects: store.projects,
            syncHealth: SyncHealth(
                watchReachable: true,
                queuedUploads: 0,
                lastSuccessfulSync: SampleData.now,
                failingItems: 3
            ),
            privacyMode: .privateLocal
        )

        XCTAssertEqual(snapshot.liveHealthTone, .needsReview)
        XCTAssertEqual(snapshot.liveHealthTitle, "Review needed")
        XCTAssertEqual(snapshot.liveHealthDetail, "3 failed items need review before sync is clean.")
        XCTAssertTrue(snapshot.isLiveActivityActive)
    }

    func testMobileDashboardSnapshotPrioritizesSyncConflictRecovery() {
        let store = SampleData.store()
        let snapshot = MobileDashboardSnapshot(
            projects: store.projects,
            syncHealth: SyncHealth(
                watchReachable: true,
                queuedUploads: 2,
                lastSuccessfulSync: SampleData.now,
                failingItems: 4,
                syncConflictStatus: WorkspaceSyncConflictStatus(
                    localOnlyUploadJobCount: 2,
                    localOnlyRecordingCount: 1,
                    detectedAt: SampleData.now
                )
            ),
            privacyMode: .privateLocal
        )

        XCTAssertEqual(snapshot.liveHealthTone, .syncConflict)
        XCTAssertEqual(snapshot.liveHealthTitle, "Sync conflict blocked")
        XCTAssertEqual(snapshot.liveHealthDetail, "Upload 2 local jobs and 1 local recording, then sync again.")
        XCTAssertTrue(snapshot.isLiveActivityActive)
    }

    func testSyncHealthDecodesLegacyPayloadWithoutSyncConflictStatus() throws {
        let data = Data("""
        {
          "watchReachable": true,
          "queuedUploads": 2,
          "lastSuccessfulSync": 2000,
          "failingItems": 0
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(SyncHealth.self, from: data)

        XCTAssertTrue(decoded.watchReachable)
        XCTAssertEqual(decoded.queuedUploads, 2)
        XCTAssertEqual(decoded.lastSuccessfulSync, Date(timeIntervalSinceReferenceDate: 2_000))
        XCTAssertEqual(decoded.failingItems, 0)
        XCTAssertNil(decoded.syncConflictStatus)
        XCTAssertNil(decoded.lastPublishedLocalUpdatedAt)
    }

    func testSyncConflictStatusDecodesLegacyPayloadWithoutReviewItems() throws {
        let data = Data("""
        {
          "localOnlyUploadJobCount": 1,
          "localOnlyRecordingCount": 2,
          "detectedAt": 2000
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(WorkspaceSyncConflictStatus.self, from: data)

        XCTAssertEqual(decoded.localOnlyUploadJobCount, 1)
        XCTAssertEqual(decoded.localOnlyRecordingCount, 2)
        XCTAssertEqual(decoded.detectedAt, Date(timeIntervalSinceReferenceDate: 2_000))
        XCTAssertEqual(decoded.reviewItems, [])
        XCTAssertEqual(decoded.recoveryAction, "Upload 1 local job and 2 local recordings, then sync again.")
    }

    func testMobileDashboardSnapshotReportsQuietLocalModeWhenWorkspaceIsClean() {
        let cleanProject = IdeaProject(
            id: "clean",
            title: "Clean workspace",
            status: .validated,
            source: .mac,
            createdAt: SampleData.now,
            updatedAt: SampleData.now,
            summary: "No pending uploads or questions.",
            tags: [.appIdea],
            score: IdeaScore(confidence: 0.8, completeness: 0.9, risk: 0.1),
            transcript: Transcript(cleanText: "Ready.", segments: [], unclearFragments: []),
            recordings: [],
            questions: [],
            artifacts: [],
            assumptions: [],
            validationExperiments: [],
            codexTasks: []
        )
        let snapshot = MobileDashboardSnapshot(
            projects: [cleanProject],
            syncHealth: SyncHealth(
                watchReachable: true,
                queuedUploads: 0,
                lastSuccessfulSync: SampleData.now,
                failingItems: 0
            ),
            privacyMode: .privateLocal
        )

        XCTAssertEqual(snapshot.liveHealthTone, .localFirst)
        XCTAssertEqual(snapshot.liveHealthTitle, "Local-first")
        XCTAssertEqual(snapshot.liveHealthDetail, "Private mode is keeping capture and review on device.")
        XCTAssertFalse(snapshot.isLiveActivityActive)
    }

    func testMobileSyncReadinessReportsLocalOnlyCleanWorkspace() {
        let cleanProject = IdeaProject(
            id: "clean",
            title: "Clean workspace",
            status: .validated,
            source: .iphone,
            createdAt: SampleData.now,
            updatedAt: SampleData.now,
            summary: "No pending uploads.",
            tags: [.appIdea],
            score: IdeaScore(confidence: 0.8, completeness: 0.9, risk: 0.1),
            transcript: Transcript(cleanText: "Ready.", segments: [], unclearFragments: []),
            recordings: [],
            questions: [],
            artifacts: [],
            assumptions: [],
            validationExperiments: [],
            codexTasks: []
        )

        let readiness = MobileSyncReadinessSnapshot(
            projects: [cleanProject],
            syncHealth: SyncHealth(
                watchReachable: false,
                queuedUploads: 0,
                lastSuccessfulSync: SampleData.now,
                failingItems: 0
            ),
            privacyMode: .privateLocal
        )

        XCTAssertEqual(readiness.title, "Local-only workspace")
        XCTAssertEqual(readiness.watchStatus, "Offline")
        XCTAssertEqual(readiness.iPhoneStatus, "Clean")
        XCTAssertEqual(readiness.backendStatus, "Local-only")
        XCTAssertEqual(readiness.macStatus, "Local")
        XCTAssertEqual(readiness.nextStepTitle, "Enable backend when ready")
        XCTAssertEqual(readiness.nextStepActionTitle, "Configure sync")
        XCTAssertEqual(readiness.timelineSteps.map(\.statusLabel), ["offline", "clean", "local", "local"])
        XCTAssertEqual(readiness.timelineSteps.first(where: { $0.id == "backend" })?.detail, "Private mode keeps backend publish off.")
        XCTAssertEqual(readiness.tone, .localFirst)
        XCTAssertFalse(readiness.isLive)
    }

    func testMobileSyncReadinessReportsQueuedCaptureNextStep() {
        let store = SampleData.store()
        store.syncHealth.failingItems = 0

        let readiness = MobileSyncReadinessSnapshot(
            projects: store.projects,
            syncHealth: store.syncHealth,
            privacyMode: .power
        )

        XCTAssertEqual(readiness.title, "Captures waiting to sync")
        XCTAssertEqual(readiness.nextStepTitle, "Upload, then publish")
        XCTAssertEqual(readiness.nextStepDetail, "2 local captures need upload first.")
        XCTAssertEqual(readiness.nextStepActionTitle, "Open sync controls")
        XCTAssertEqual(readiness.backendStatus, "Pending")
        XCTAssertEqual(readiness.macStatus, "Waiting")
        XCTAssertEqual(readiness.timelineSteps.map(\.id), ["watch", "iphone", "backend", "mac"])
        XCTAssertEqual(readiness.timelineSteps.first(where: { $0.id == "iphone" })?.statusLabel, "2 queued")
        XCTAssertEqual(readiness.timelineSteps.first(where: { $0.id == "backend" })?.statusLabel, "pending")
        XCTAssertEqual(readiness.timelineSteps.first(where: { $0.id == "mac" })?.statusLabel, "waiting")
        XCTAssertEqual(readiness.timelineSteps.first(where: { $0.id == "mac" })?.detail, "Mac waits until iPhone publishes the workspace.")
        XCTAssertEqual(readiness.tone, .active)
        XCTAssertTrue(readiness.isLive)
    }

    func testMobileSyncReadinessUsesSingularFailedItemCopy() {
        let store = SampleData.store()
        let readiness = MobileSyncReadinessSnapshot(
            projects: store.projects,
            syncHealth: store.syncHealth,
            privacyMode: .power
        )

        XCTAssertEqual(readiness.title, "Resolve failed sync items")
        XCTAssertEqual(readiness.detail, "1 failed item needs review before Mac handoff resumes.")
    }

    func testMobileSyncReadinessPrioritizesConflictAndDoesNotExposeRecordingPaths() {
        let store = SampleData.store()
        let readiness = MobileSyncReadinessSnapshot(
            projects: store.projects,
            syncHealth: SyncHealth(
                watchReachable: true,
                queuedUploads: 2,
                lastSuccessfulSync: SampleData.now,
                failingItems: 1,
                syncConflictStatus: WorkspaceSyncConflictStatus(
                    localOnlyUploadJobCount: 1,
                    localOnlyRecordingCount: 1,
                    detectedAt: SampleData.now
                )
            ),
            privacyMode: .power
        )

        XCTAssertEqual(readiness.title, "Review sync before publishing")
        XCTAssertEqual(readiness.backendStatus, "Review")
        XCTAssertEqual(readiness.macStatus, "Blocked")
        XCTAssertEqual(readiness.nextStepTitle, "Review and merge local choices")
        XCTAssertEqual(readiness.nextStepActionTitle, "Review in Account")
        XCTAssertEqual(readiness.tone, .syncConflict)
        XCTAssertTrue(readiness.isLive)
        let renderedReadiness = [
            readiness.title,
            readiness.detail,
            readiness.nextStepTitle,
            readiness.nextStepDetail,
            readiness.nextStepActionTitle,
            readiness.watchStatus,
            readiness.iPhoneStatus,
            readiness.backendStatus,
            readiness.macStatus
        ].joined(separator: "\n")
        let renderedTimeline = readiness.timelineSteps.map {
            "\($0.title) \($0.statusLabel) \($0.detail)"
        }.joined(separator: "\n")
        XCTAssertFalse(renderedReadiness.contains("recordings/"))
        XCTAssertFalse(renderedReadiness.contains("audio/"))
        XCTAssertFalse(renderedTimeline.contains("recordings/"))
        XCTAssertFalse(renderedTimeline.contains("audio/"))
        XCTAssertEqual(readiness.timelineSteps.first(where: { $0.id == "backend" })?.statusLabel, "review")
        XCTAssertEqual(readiness.timelineSteps.first(where: { $0.id == "mac" })?.statusLabel, "blocked")
    }

    func testMobileSyncReadinessReportsPublishedWorkspace() {
        let cleanProject = IdeaProject(
            id: "published",
            title: "Published workspace",
            status: .readyForBuild,
            source: .mac,
            createdAt: SampleData.now,
            updatedAt: SampleData.now,
            summary: "Synced.",
            tags: [.appIdea],
            score: IdeaScore(confidence: 0.9, completeness: 0.9, risk: 0.2),
            transcript: Transcript(cleanText: "Ready.", segments: [], unclearFragments: []),
            recordings: [],
            questions: [],
            artifacts: [],
            assumptions: [],
            validationExperiments: [],
            codexTasks: []
        )

        let readiness = MobileSyncReadinessSnapshot(
            projects: [cleanProject],
            syncHealth: SyncHealth(
                watchReachable: true,
                queuedUploads: 0,
                lastSuccessfulSync: SampleData.now,
                lastRemoteWorkspaceUpdatedAt: SampleData.now,
                failingItems: 0
            ),
            privacyMode: .power
        )

        XCTAssertEqual(readiness.title, "Workspace published")
        XCTAssertEqual(readiness.backendStatus, "Published")
        XCTAssertEqual(readiness.macStatus, "Ready")
        XCTAssertEqual(readiness.nextStepTitle, "Ready on Mac")
        XCTAssertEqual(readiness.nextStepActionTitle, "Refresh if needed")
        XCTAssertEqual(readiness.timelineSteps.map(\.statusLabel), ["linked", "clean", "published", "ready"])
        XCTAssertEqual(readiness.timelineSteps.first(where: { $0.id == "backend" })?.detail, "Latest workspace has a backend receipt.")
        XCTAssertEqual(readiness.timelineSteps.first(where: { $0.id == "mac" })?.detail, "Workspace is ready for Mac review and build packets.")
        XCTAssertEqual(readiness.tone, .ready)
        XCTAssertFalse(readiness.isLive)
    }

    func testMobileSyncTrustPrioritizesConflictWithoutPrivatePaths() {
        let store = SampleData.syncConflictStore()
        let state = store.workspaceState(now: SampleData.now)
        let readiness = MobileSyncReadinessSnapshot(
            projects: state.projects,
            syncHealth: state.syncHealth,
            privacyMode: state.privacyMode
        )
        let plan = MobileWorkspaceSyncPlanSnapshot(
            state: state,
            capabilityDecision: BackendCapabilityDecision(isAllowed: true, blockers: [])
        )

        let trust = MobileSyncTrustSnapshot(state: state, readiness: readiness, plan: plan)

        XCTAssertEqual(trust.title, "Review before sync")
        XCTAssertEqual(trust.localStatus, "Review")
        XCTAssertEqual(trust.receiptStatus, "Paused")
        XCTAssertEqual(trust.macHandoffStatus, "Review")
        XCTAssertEqual(trust.blockerStatus, "Conflict")
        XCTAssertEqual(trust.actionTitle, "Review")
        XCTAssertEqual(trust.tone, .syncConflict)
        XCTAssertTrue(trust.isLive)
        let renderedTrust = [
            trust.title,
            trust.detail,
            trust.localStatus,
            trust.receiptStatus,
            trust.macHandoffStatus,
            trust.blockerStatus,
            trust.actionTitle
        ].joined(separator: "\n")
        XCTAssertFalse(renderedTrust.contains("recordings/"))
        XCTAssertFalse(renderedTrust.contains("audio/"))
    }

    func testMobileSyncTrustReportsPrivateLocalBeforeBackendCapability() {
        let project = IdeaProject(
            id: "private_clean",
            title: "Private clean workspace",
            status: .validated,
            source: .iphone,
            createdAt: SampleData.now,
            updatedAt: SampleData.now,
            summary: "Clean local workspace.",
            tags: [.appIdea],
            score: IdeaScore(confidence: 0.8, completeness: 0.9, risk: 0.1),
            transcript: Transcript(cleanText: "Ready.", segments: [], unclearFragments: []),
            recordings: [],
            questions: [],
            artifacts: [],
            assumptions: [],
            validationExperiments: [],
            codexTasks: []
        )
        let state = WorkspaceState(
            projects: [project],
            workflowTemplates: [],
            privacyMode: .privateLocal,
            syncHealth: SyncHealth(
                watchReachable: false,
                queuedUploads: 0,
                lastSuccessfulSync: SampleData.now,
                failingItems: 0
            ),
            selectedProjectID: nil,
            updatedAt: SampleData.now
        )
        let readiness = MobileSyncReadinessSnapshot(
            projects: state.projects,
            syncHealth: state.syncHealth,
            privacyMode: state.privacyMode
        )
        let plan = MobileWorkspaceSyncPlanSnapshot(
            state: state,
            capabilityDecision: BackendCapabilityDecision(
                isAllowed: false,
                blockers: ["Validate backend session before using this backend action."]
            )
        )

        let trust = MobileSyncTrustSnapshot(state: state, readiness: readiness, plan: plan)

        XCTAssertEqual(trust.title, "Local-only by design")
        XCTAssertEqual(trust.localStatus, "Clean")
        XCTAssertEqual(trust.receiptStatus, "Local-only")
        XCTAssertEqual(trust.macHandoffStatus, "Local")
        XCTAssertEqual(trust.blockerStatus, "Private")
        XCTAssertEqual(trust.actionTitle, "Enable")
        XCTAssertEqual(trust.tone, .localFirst)
        XCTAssertFalse(trust.detail.contains("Validate backend session"))
    }

    func testMobileSyncTrustReportsCurrentBackendReceiptForMacHandoff() {
        let project = IdeaProject(
            id: "receipt_clean",
            title: "Receipted workspace",
            status: .readyForBuild,
            source: .iphone,
            createdAt: SampleData.now,
            updatedAt: SampleData.now,
            summary: "Synced.",
            tags: [.appIdea],
            score: IdeaScore(confidence: 0.9, completeness: 0.9, risk: 0.1),
            transcript: Transcript(cleanText: "Ready.", segments: [], unclearFragments: []),
            recordings: [],
            questions: [],
            artifacts: [],
            assumptions: [],
            validationExperiments: [],
            codexTasks: []
        )
        let state = WorkspaceState(
            projects: [project],
            workflowTemplates: [],
            privacyMode: .standardCloud,
            syncHealth: SyncHealth(
                watchReachable: true,
                queuedUploads: 0,
                lastSuccessfulSync: SampleData.now,
                lastRemoteWorkspaceUpdatedAt: SampleData.now,
                failingItems: 0
            ),
            selectedProjectID: nil,
            updatedAt: SampleData.now
        )
        let readiness = MobileSyncReadinessSnapshot(
            projects: state.projects,
            syncHealth: state.syncHealth,
            privacyMode: state.privacyMode
        )
        let plan = MobileWorkspaceSyncPlanSnapshot(
            state: state,
            capabilityDecision: BackendCapabilityDecision(isAllowed: true, blockers: [])
        )

        let trust = MobileSyncTrustSnapshot(state: state, readiness: readiness, plan: plan)

        XCTAssertEqual(trust.title, "Trusted handoff")
        XCTAssertEqual(trust.localStatus, "Clean")
        XCTAssertEqual(trust.receiptStatus, "Receipted")
        XCTAssertEqual(trust.macHandoffStatus, "Ready")
        XCTAssertEqual(trust.blockerStatus, "Clear")
        XCTAssertEqual(trust.actionTitle, "Refresh")
        XCTAssertEqual(trust.tone, .ready)
        XCTAssertFalse(trust.isLive)
    }

    func testMobileWorkspaceSyncPlanPrioritizesPrivateModeBeforeBackendValidation() {
        let store = SampleData.store()
        let blockedCapabilityDecision = BackendCapabilityDecision(
            isAllowed: false,
            blockers: ["Validate backend session before using this backend action."]
        )

        let plan = MobileWorkspaceSyncPlanSnapshot(
            state: store.workspaceState(now: SampleData.now),
            capabilityDecision: blockedCapabilityDecision
        )

        XCTAssertEqual(plan.title, "Auto-sync off")
        XCTAssertEqual(plan.statusLabel, "Private")
        XCTAssertEqual(plan.actionTitle, "Enable sync")
        XCTAssertEqual(plan.handoffTitle, "Local-only handoff")
        XCTAssertEqual(plan.handoffStatusLabel, "Local")
        XCTAssertEqual(plan.handoffDetail, "Private mode keeps this iPhone workspace off backend and Mac sync.")
        XCTAssertEqual(plan.tone, .localFirst)
        XCTAssertEqual(plan.blocker, .privateLocalMode)
        XCTAssertFalse(plan.detail.contains("Validate backend session"))
    }

    func testMobileWorkspaceSyncPlanPrioritizesExistingConflictBeforePrivateMode() {
        let store = SampleData.syncConflictStore()
        let blockedCapabilityDecision = BackendCapabilityDecision(
            isAllowed: false,
            blockers: ["Validate backend session before using this backend action."]
        )

        let plan = MobileWorkspaceSyncPlanSnapshot(
            state: store.workspaceState(now: SampleData.now),
            capabilityDecision: blockedCapabilityDecision
        )

        XCTAssertEqual(plan.title, "Auto-sync paused")
        XCTAssertEqual(plan.statusLabel, "Review")
        XCTAssertEqual(plan.actionTitle, "Review conflict")
        XCTAssertEqual(plan.handoffTitle, "Review required")
        XCTAssertEqual(plan.handoffStatusLabel, "Review")
        XCTAssertEqual(plan.handoffDetail, "Mac handoff stays paused until Account review confirms the local work to keep.")
        XCTAssertEqual(plan.tone, .syncConflict)
        XCTAssertEqual(plan.blocker, .syncConflict)
        XCTAssertFalse(plan.detail.contains("Validate backend session"))
    }

    func testMobileWorkspaceSyncPlanReportsCapabilityGateForCloudWorkspace() {
        let cleanProject = IdeaProject(
            id: "cloud",
            title: "Cloud workspace",
            status: .validated,
            source: .iphone,
            createdAt: SampleData.now,
            updatedAt: SampleData.now,
            summary: "Ready to publish.",
            tags: [.appIdea],
            score: IdeaScore(confidence: 0.8, completeness: 0.9, risk: 0.1),
            transcript: Transcript(cleanText: "Ready.", segments: [], unclearFragments: []),
            recordings: [],
            questions: [],
            artifacts: [],
            assumptions: [],
            validationExperiments: [],
            codexTasks: []
        )
        let state = WorkspaceState(
            projects: [cleanProject],
            workflowTemplates: [],
            privacyMode: .standardCloud,
            syncHealth: SyncHealth(
                watchReachable: true,
                queuedUploads: 0,
                lastSuccessfulSync: SampleData.now,
                failingItems: 0
            ),
            selectedProjectID: nil,
            updatedAt: SampleData.now
        )
        let blockedCapabilityDecision = BackendCapabilityDecision(
            isAllowed: false,
            blockers: ["Validate backend session before using this backend action."]
        )

        let plan = MobileWorkspaceSyncPlanSnapshot(
            state: state,
            capabilityDecision: blockedCapabilityDecision
        )

        XCTAssertEqual(plan.title, "Validate backend")
        XCTAssertEqual(plan.statusLabel, "Needs session")
        XCTAssertEqual(plan.actionTitle, "Validate")
        XCTAssertEqual(plan.handoffTitle, "Session not validated")
        XCTAssertEqual(plan.handoffStatusLabel, "Validate")
        XCTAssertEqual(plan.handoffDetail, "Validate backend sync capability before publishing or refreshing Mac handoff state.")
        XCTAssertEqual(plan.tone, .offline)
        XCTAssertEqual(plan.blocker, .capabilityGate)
        XCTAssertTrue(plan.detail.contains("Validate backend session"))
    }

    func testMobileWorkspaceSyncPlanReportsPendingAndReceiptedMacHandoff() {
        let project = IdeaProject(
            id: "cloud",
            title: "Cloud workspace",
            status: .validated,
            source: .iphone,
            createdAt: SampleData.now,
            updatedAt: SampleData.now,
            summary: "Ready to publish.",
            tags: [.appIdea],
            score: IdeaScore(confidence: 0.8, completeness: 0.9, risk: 0.1),
            transcript: Transcript(cleanText: "Ready.", segments: [], unclearFragments: []),
            recordings: [],
            questions: [],
            artifacts: [],
            assumptions: [],
            validationExperiments: [],
            codexTasks: []
        )
        let capabilityDecision = BackendCapabilityDecision(isAllowed: true, blockers: [])
        let lastRemote = SampleData.now.addingTimeInterval(-300)
        let pendingState = WorkspaceState(
            projects: [project],
            workflowTemplates: [],
            privacyMode: .standardCloud,
            syncHealth: SyncHealth(
                watchReachable: true,
                queuedUploads: 0,
                lastSuccessfulSync: SampleData.now,
                lastRemoteWorkspaceUpdatedAt: lastRemote,
                failingItems: 0
            ),
            selectedProjectID: nil,
            updatedAt: SampleData.now
        )

        let pendingPlan = MobileWorkspaceSyncPlanSnapshot(
            state: pendingState,
            capabilityDecision: capabilityDecision
        )

        XCTAssertEqual(pendingPlan.title, "Auto-sync ready")
        XCTAssertEqual(pendingPlan.handoffTitle, "Local changes pending")
        XCTAssertEqual(pendingPlan.handoffStatusLabel, "Pending")
        XCTAssertEqual(pendingPlan.handoffDetail, "This iPhone changed after the last backend receipt; publish before Mac refresh.")

        var receiptedState = pendingState
        receiptedState.updatedAt = lastRemote
        let receiptedPlan = MobileWorkspaceSyncPlanSnapshot(
            state: receiptedState,
            capabilityDecision: capabilityDecision
        )

        XCTAssertEqual(receiptedPlan.title, "Auto-sync clean")
        XCTAssertEqual(receiptedPlan.handoffTitle, "Backend receipt ready")
        XCTAssertEqual(receiptedPlan.handoffStatusLabel, "Ready")
        XCTAssertEqual(receiptedPlan.handoffDetail, "Mac can refresh this workspace without waiting for another iPhone publish.")
    }

    func testWorkspaceRepositoryRoundTripsState() throws {
        let repository = InMemoryWorkspaceRepository()
        let state = WorkspaceState.seed()

        try repository.save(state)

        XCTAssertEqual(try repository.load(), state)
    }

    func testProductionStoreStartsWithEmptyWorkspaceWhenNoStateExists() {
        let store = IdeaForgeStore.production(repository: InMemoryWorkspaceRepository())

        XCTAssertTrue(store.projects.isEmpty)
        XCTAssertNil(store.selectedProjectID)
        XCTAssertEqual(store.workflowTemplates, DefaultWorkflows.templates)
        XCTAssertEqual(store.updatedAt, .distantPast)
        XCTAssertNil(store.lastErrorMessage)
        XCTAssertFalse(store.workspaceLoadFailed)
    }

    func testProductionStoreSurfacesUnreadableWorkspaceWithoutSeedingSampleData() {
        let repository = UnreadableWorkspaceRepository()
        let store = IdeaForgeStore.production(repository: repository)

        XCTAssertTrue(store.projects.isEmpty)
        XCTAssertNil(store.selectedProjectID)
        XCTAssertEqual(store.updatedAt, .distantPast)
        XCTAssertEqual(store.lastErrorMessage, "Workspace data could not be loaded. The original file was left unchanged.")
        XCTAssertTrue(store.workspaceLoadFailed)

        XCTAssertFalse(store.save(now: Date(timeIntervalSince1970: 2_000)))
        XCTAssertEqual(store.updatedAt, .distantPast)
        XCTAssertEqual(repository.saveCallCount, 0)
        XCTAssertEqual(store.lastErrorMessage, "Workspace data could not be loaded. The original file was left unchanged.")
    }

    func testPrivacyModeChangePersistsToRepository() throws {
        let repository = InMemoryWorkspaceRepository(state: WorkspaceState.seed())
        let store = IdeaForgeStore.production(repository: repository)

        store.setPrivacyMode(.power)

        let saved = try XCTUnwrap(try repository.load())
        XCTAssertEqual(saved.privacyMode, .power)
    }

    func testCaptureCreatesPersistedProjectAndQueuedRecording() async throws {
        let repository = InMemoryWorkspaceRepository()
        let store = IdeaForgeStore(
            projects: [],
            workflowTemplates: DefaultWorkflows.templates,
            selectedProjectID: nil,
            privacyMode: .privateLocal,
            syncHealth: SyncHealth(
                watchReachable: true,
                queuedUploads: 0,
                lastSuccessfulSync: SampleData.now,
                failingItems: 0
            ),
            repository: repository
        )

        await store.capture(
            RecordingDraft(
                projectTitle: "Recorded MVP",
                tag: .appIdea,
                source: .watch,
                durationSeconds: 90,
                transcriptHint: "A recorded MVP idea.",
                localAudioPath: "recordings/watch-draft.m4a",
                markerOffsets: [12, 44],
                languageHint: "en-US"
            )
        )

        let saved = try XCTUnwrap(try repository.load())
        XCTAssertEqual(saved.projects.count, 1)
        XCTAssertEqual(saved.projects.first?.title, "Recorded MVP")
        XCTAssertEqual(saved.projects.first?.recordings.first?.syncStatus, .transferredToIPhone)
        XCTAssertEqual(saved.projects.first?.recordings.first?.localFileStatus, .available)
        XCTAssertEqual(saved.projects.first?.recordings.first?.localAudioPath, "recordings/watch-draft.m4a")
        XCTAssertEqual(saved.projects.first?.recordings.first?.markerOffsets, [12, 44])
        XCTAssertEqual(saved.uploadJobs.count, 1)
        XCTAssertEqual(saved.uploadJobs.first?.localAudioPath, "recordings/watch-draft.m4a")
        XCTAssertEqual(saved.projects.first?.questions.count, 1)
    }

    func testRecordingQueuePolicyPreventsDeletingBeforeUpload() throws {
        let recording = Recording(
            id: "rec_pending",
            ideaProjectID: "idea_pending",
            deviceName: "Apple Watch",
            durationSeconds: 30,
            localFileStatus: .available,
            syncStatus: .pending,
            localAudioPath: "recordings/rec_pending.m4a",
            languageHint: "en",
            createdAt: SampleData.now,
            markerOffsets: []
        )

        XCTAssertThrowsError(try RecordingQueuePolicy.applying(.deleteLocalAudio, to: recording)) { error in
            XCTAssertEqual(error as? RecordingQueueError, .cannotDeleteBeforeUpload)
        }
    }

    func testRecordingQueuePolicyAllowsDeletingAfterUpload() throws {
        let recording = Recording(
            id: "rec_uploaded",
            ideaProjectID: "idea_uploaded",
            deviceName: "iPhone",
            durationSeconds: 30,
            localFileStatus: .uploaded,
            syncStatus: .uploaded,
            localAudioPath: "recordings/rec_uploaded.m4a",
            languageHint: "en",
            createdAt: SampleData.now,
            markerOffsets: []
        )

        let deleted = try RecordingQueuePolicy.applying(.deleteLocalAudio, to: recording)

        XCTAssertEqual(deleted.localFileStatus, .deleted)
        XCTAssertNil(deleted.localAudioPath)
    }

    func testRecordingQueuePolicyStoresObjectKeyOnUpload() throws {
        let recording = Recording(
            id: "rec_uploading",
            ideaProjectID: "idea_uploading",
            deviceName: "iPhone",
            durationSeconds: 30,
            localFileStatus: .available,
            syncStatus: .pending,
            localAudioPath: "recordings/rec_uploading.m4a",
            languageHint: "en",
            createdAt: SampleData.now,
            markerOffsets: []
        )

        let uploaded = try RecordingQueuePolicy.applying(.uploaded(objectKey: "audio/rec_uploading.m4a"), to: recording)

        XCTAssertEqual(uploaded.syncStatus, .uploaded)
        XCTAssertEqual(uploaded.localFileStatus, .uploaded)
        XCTAssertEqual(uploaded.audioObjectKey, "audio/rec_uploading.m4a")
        XCTAssertEqual(uploaded.localAudioPath, "recordings/rec_uploading.m4a")
    }

    @MainActor
    func testProjectDeletionReadinessFailsClosedForMidProcessWorkWithoutPrivateDetails() throws {
        let project = deletionSafetyProject(
            recordings: [
                deletionRecording(
                    id: "rec_pending",
                    localFileStatus: .available,
                    syncStatus: .pending,
                    localAudioPath: "/Users/private/recordings/pending.m4a"
                ),
                deletionRecording(
                    id: "rec_transcribing",
                    localFileStatus: .uploaded,
                    syncStatus: .transcribing,
                    localAudioPath: nil,
                    audioObjectKey: "audio/private-object-key.m4a"
                )
            ],
            workflowRuns: [
                deletionWorkflowRun(id: "run_active", status: .running),
                deletionWorkflowRun(
                    id: "run_retry",
                    status: .failed,
                    nextRetryAt: SampleData.now.addingTimeInterval(60)
                )
            ]
        )
        let failedJob = UploadJob(
            id: "upload_failed",
            recordingID: "rec_failed",
            ideaProjectID: project.id,
            localAudioPath: "/Users/private/recordings/failed.m4a",
            status: .permanentlyFailed,
            attemptCount: 5,
            nextAttemptAt: SampleData.now,
            lastErrorMessage: "backend said token abc123 failed for /Users/private/recordings/failed.m4a",
            createdAt: SampleData.now,
            updatedAt: SampleData.now
        )
        let activeJob = UploadJob(
            id: "upload_active",
            recordingID: "rec_pending",
            ideaProjectID: project.id,
            localAudioPath: "/Users/private/recordings/pending.m4a",
            status: .waitingForRetry,
            attemptCount: 1,
            nextAttemptAt: SampleData.now.addingTimeInterval(60),
            createdAt: SampleData.now,
            updatedAt: SampleData.now
        )

        let readiness = ProjectDeletionPolicy.readiness(
            for: project,
            uploadJobs: [failedJob, activeJob]
        )

        XCTAssertFalse(readiness.canDelete)
        XCTAssertEqual(
            Set(readiness.blockers),
            Set([
                .activeUploadJobs(count: 1),
                .unresolvedUploadFailures(count: 1),
                .unsafeLocalRecordings(count: 1),
                .activeTranscriptions(count: 1),
                .activeWorkflowRuns(count: 1),
                .scheduledWorkflowRetries(count: 1)
            ])
        )
        XCTAssertFalse(readiness.message.contains("/Users/private"))
        XCTAssertFalse(readiness.message.contains("private-object-key"))
        XCTAssertFalse(readiness.message.localizedCaseInsensitiveContains("token"))
    }

    @MainActor
    func testProjectDeletionRollsBackWhenWorkspacePersistenceFails() throws {
        let project = deletionSafetyProject(recordings: [])
        let state = WorkspaceState(
            projects: [project],
            workflowTemplates: DefaultWorkflows.templates,
            uploadJobs: [],
            privacyMode: .privateLocal,
            syncHealth: SyncHealth(
                watchReachable: false,
                queuedUploads: 0,
                lastSuccessfulSync: SampleData.now,
                failingItems: 0
            ),
            selectedProjectID: project.id,
            updatedAt: SampleData.now
        )
        let repository = ThrowingWorkspaceRepository(state: state)
        let store = IdeaForgeStore(state: state, repository: repository)

        XCTAssertFalse(store.deleteProject(project.id, now: SampleData.now.addingTimeInterval(1)))
        XCTAssertEqual(store.workspaceState(), state)
        XCTAssertEqual(try repository.load(), state)
        XCTAssertEqual(store.lastErrorMessage, "Could not delete the project because the workspace was not saved.")
    }

    @MainActor
    func testDeleteProjectFailsClosedAndPreservesStateWhenReadinessBlocksDeletion() throws {
        let repository = InMemoryWorkspaceRepository()
        let project = deletionSafetyProject(
            recordings: [
                deletionRecording(
                    id: "rec_pending",
                    localFileStatus: .available,
                    syncStatus: .pending,
                    localAudioPath: "recordings/pending.m4a"
                )
            ]
        )
        let job = UploadQueuePolicy.job(
            for: project.recordings[0],
            localAudioPath: "recordings/pending.m4a",
            now: SampleData.now
        )
        let store = IdeaForgeStore(
            projects: [project],
            workflowTemplates: DefaultWorkflows.templates,
            uploadJobs: [job],
            selectedProjectID: project.id,
            privacyMode: .privateLocal,
            syncHealth: SyncHealth(watchReachable: true, queuedUploads: 1, lastSuccessfulSync: SampleData.now, failingItems: 0),
            updatedAt: SampleData.now,
            repository: repository
        )

        XCTAssertFalse(store.deleteProject(project.id, now: SampleData.now.addingTimeInterval(10)))

        XCTAssertEqual(store.projects.map(\.id), [project.id])
        XCTAssertEqual(store.uploadJobs.map(\.id), [job.id])
        XCTAssertEqual(store.selectedProjectID, project.id)
        XCTAssertEqual(store.syncHealth.queuedUploads, 1)
        XCTAssertTrue(store.lastErrorMessage?.contains("Project cannot be deleted") ?? false)
        XCTAssertFalse(store.lastErrorMessage?.contains("recordings/pending.m4a") ?? true)
        XCTAssertNil(try repository.load())
    }

    @MainActor
    func testDeleteProjectRemovesSafeProjectTerminalJobsAndPersistsSelection() throws {
        let repository = InMemoryWorkspaceRepository()
        let deletedRecording = deletionRecording(
            id: "rec_done",
            localFileStatus: .uploaded,
            syncStatus: .ready,
            localAudioPath: nil,
            audioObjectKey: "audio/rec_done.m4a"
        )
        let deletedProject = deletionSafetyProject(recordings: [deletedRecording])
        let survivingProject = deletionSafetyProject(id: "idea_keep", title: "Keep")
        let terminalJob = UploadJob(
            id: "upload_done",
            recordingID: deletedRecording.id,
            ideaProjectID: deletedProject.id,
            localAudioPath: "recordings/done.m4a",
            status: .uploaded,
            attemptCount: 1,
            nextAttemptAt: SampleData.now,
            objectKey: "audio/rec_done.m4a",
            createdAt: SampleData.now,
            updatedAt: SampleData.now
        )
        let unrelatedJob = UploadJob(
            id: "upload_keep",
            recordingID: "rec_keep",
            ideaProjectID: survivingProject.id,
            localAudioPath: "recordings/keep.m4a",
            status: .queued,
            attemptCount: 0,
            nextAttemptAt: SampleData.now,
            createdAt: SampleData.now,
            updatedAt: SampleData.now
        )
        let store = IdeaForgeStore(
            projects: [deletedProject, survivingProject],
            workflowTemplates: DefaultWorkflows.templates,
            uploadJobs: [terminalJob, unrelatedJob],
            selectedProjectID: deletedProject.id,
            privacyMode: .privateLocal,
            syncHealth: SyncHealth(watchReachable: true, queuedUploads: 2, lastSuccessfulSync: SampleData.now, failingItems: 0),
            updatedAt: SampleData.now,
            repository: repository
        )

        XCTAssertTrue(store.deleteProject(deletedProject.id, now: SampleData.now.addingTimeInterval(10)))

        XCTAssertEqual(store.projects.map(\.id), [survivingProject.id])
        XCTAssertEqual(store.uploadJobs.map(\.id), [unrelatedJob.id])
        XCTAssertEqual(store.selectedProjectID, survivingProject.id)
        XCTAssertEqual(store.syncHealth.queuedUploads, 1)
        XCTAssertNil(store.lastErrorMessage)

        let saved = try XCTUnwrap(try repository.load())
        XCTAssertEqual(saved.projects.map(\.id), [survivingProject.id])
        XCTAssertEqual(saved.uploadJobs.map(\.id), [unrelatedJob.id])
        XCTAssertEqual(saved.selectedProjectID, survivingProject.id)
        XCTAssertEqual(saved.syncHealth.queuedUploads, 1)
    }

    @MainActor
    func testDeleteProjectRemovesOnlyManagedRecordingFilesAfterPersistence() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "IdeaForgeProjectDeletion-\(UUID().uuidString)", directoryHint: .isDirectory)
        let managedRoot = root.appending(path: "managed", directoryHint: .isDirectory)
        let outsideRoot = root.appending(path: "outside", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: managedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        let managedAudio = managedRoot.appending(path: "managed.m4a")
        let outsideAudio = outsideRoot.appending(path: "outside.m4a")
        try Data("managed".utf8).write(to: managedAudio)
        try Data("outside".utf8).write(to: outsideAudio)

        let managedRecording = deletionRecording(
            id: "rec_managed_cleanup",
            localFileStatus: .uploaded,
            syncStatus: .ready,
            localAudioPath: managedAudio.path,
            audioObjectKey: "audio/managed.m4a"
        )
        let outsideRecording = deletionRecording(
            id: "rec_outside_cleanup",
            localFileStatus: .uploaded,
            syncStatus: .ready,
            localAudioPath: outsideAudio.path,
            audioObjectKey: "audio/outside.m4a"
        )
        let project = deletionSafetyProject(recordings: [managedRecording, outsideRecording])
        let state = WorkspaceState(
            projects: [project],
            workflowTemplates: DefaultWorkflows.templates,
            uploadJobs: [],
            privacyMode: .privateLocal,
            syncHealth: SyncHealth(
                watchReachable: false,
                queuedUploads: 0,
                lastSuccessfulSync: SampleData.now,
                failingItems: 0
            ),
            selectedProjectID: project.id,
            updatedAt: SampleData.now
        )
        let repository = InMemoryWorkspaceRepository(state: state)
        let store = IdeaForgeStore(state: state, repository: repository)

        XCTAssertTrue(
            store.deleteProject(
                project.id,
                now: SampleData.now.addingTimeInterval(1),
                managedRecordingDirectory: managedRoot
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: managedAudio.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideAudio.path))
    }

    @MainActor
    func testDeleteProjectKeepsManagedFileReferencedBySurvivingProject() throws {
        let managedRoot = FileManager.default.temporaryDirectory
            .appending(path: "IdeaForgeSharedRecording-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: managedRoot) }
        try FileManager.default.createDirectory(at: managedRoot, withIntermediateDirectories: true)
        let sharedAudio = managedRoot.appending(path: "shared.m4a")
        try Data("shared".utf8).write(to: sharedAudio)

        let deletedProject = deletionSafetyProject(recordings: [
            deletionRecording(
                id: "rec_shared_deleted",
                localFileStatus: .uploaded,
                syncStatus: .ready,
                localAudioPath: sharedAudio.path,
                audioObjectKey: "audio/shared-deleted.m4a"
            )
        ])
        let survivingProject = deletionSafetyProject(
            id: "idea_shared_survivor",
            title: "Survivor",
            recordings: [
                deletionRecording(
                    id: "rec_shared_survivor",
                    localFileStatus: .uploaded,
                    syncStatus: .ready,
                    localAudioPath: sharedAudio.path,
                    audioObjectKey: "audio/shared-survivor.m4a"
                )
            ]
        )
        let state = WorkspaceState(
            projects: [deletedProject, survivingProject],
            workflowTemplates: DefaultWorkflows.templates,
            uploadJobs: [],
            privacyMode: .privateLocal,
            syncHealth: SyncHealth(
                watchReachable: false,
                queuedUploads: 0,
                lastSuccessfulSync: SampleData.now,
                failingItems: 0
            ),
            selectedProjectID: deletedProject.id,
            updatedAt: SampleData.now
        )
        let store = IdeaForgeStore(state: state, repository: InMemoryWorkspaceRepository(state: state))

        XCTAssertTrue(
            store.deleteProject(
                deletedProject.id,
                now: SampleData.now.addingTimeInterval(1),
                managedRecordingDirectory: managedRoot
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: sharedAudio.path))
    }

    func testRecordingTransferMetadataRoundTripsWatchConnectivityPayload() throws {
        let recording = Recording(
            id: "rec_transfer",
            ideaProjectID: "idea_transfer",
            deviceName: "Apple Watch",
            durationSeconds: 42,
            localFileStatus: .available,
            syncStatus: .transferredToIPhone,
            localAudioPath: "recordings/rec_transfer.m4a",
            languageHint: "en-US",
            createdAt: SampleData.now,
            markerOffsets: [4, 18]
        )

        let metadata = RecordingTransferMetadata(recording: recording)
        let decoded = try XCTUnwrap(
            RecordingTransferMetadata(watchConnectivityMetadata: metadata.watchConnectivityMetadata)
        )

        XCTAssertEqual(decoded, metadata)
    }

    func testRecordingTransferMetadataRejectsUnsafeBoundaryValues() {
        let valid = RecordingTransferMetadata(
            recordingID: "rec_transfer",
            ideaProjectID: "idea_transfer",
            sourceDeviceName: "Apple Watch",
            durationSeconds: 42,
            languageHint: "en-US",
            markerOffsets: [4, 18],
            createdAt: SampleData.now
        ).watchConnectivityMetadata

        for invalidID in ["", ".", "..", "../escape", "nested/escape", "nested\\escape"] {
            var payload = valid
            payload["recordingID"] = invalidID
            XCTAssertNil(RecordingTransferMetadata(watchConnectivityMetadata: payload))
        }

        var invalidDuration = valid
        invalidDuration["durationSeconds"] = -1
        XCTAssertNil(RecordingTransferMetadata(watchConnectivityMetadata: invalidDuration))

        var invalidMarkers = valid
        invalidMarkers["markerOffsets"] = [-1, 100]
        XCTAssertNil(RecordingTransferMetadata(watchConnectivityMetadata: invalidMarkers))

        var invalidTimestamp = valid
        invalidTimestamp["createdAt"] = Double.nan
        XCTAssertNil(RecordingTransferMetadata(watchConnectivityMetadata: invalidTimestamp))

        var implausiblyOldTimestamp = valid
        implausiblyOldTimestamp["createdAt"] = Date(timeIntervalSince1970: 1).timeIntervalSince1970
        XCTAssertNil(RecordingTransferMetadata(watchConnectivityMetadata: implausiblyOldTimestamp))

        var implausiblyFutureTimestamp = valid
        implausiblyFutureTimestamp["createdAt"] = Date().addingTimeInterval(2 * 60 * 60).timeIntervalSince1970
        XCTAssertNil(RecordingTransferMetadata(watchConnectivityMetadata: implausiblyFutureTimestamp))
    }

    func testRecordingTransferImportAcknowledgementRoundTripsQueuedMessage() throws {
        let acknowledgement = RecordingTransferImportAcknowledgement(
            recordingID: "rec_watch_import_ack",
            result: .imported
        )

        let decoded = try XCTUnwrap(
            RecordingTransferImportAcknowledgement(
                watchConnectivityUserInfo: acknowledgement.watchConnectivityUserInfo
            )
        )

        XCTAssertEqual(decoded, acknowledgement)
        XCTAssertNil(
            RecordingTransferImportAcknowledgement(
                watchConnectivityUserInfo: [
                    "messageType": "recordingImportAcknowledgement",
                    "recordingID": "rec_watch_import_ack"
                ]
            )
        )
    }

    func testRecordingTransferCompletionWaitsForIPhoneImportAcknowledgement() {
        XCTAssertNil(RecordingTransferCompletionPolicy.transportCompletion(delivered: true))
        XCTAssertEqual(RecordingTransferCompletionPolicy.transportCompletion(delivered: false), false)
        XCTAssertEqual(RecordingTransferCompletionPolicy.importCompletion(for: .imported), true)
        XCTAssertEqual(RecordingTransferCompletionPolicy.importCompletion(for: .failed), false)
    }

    func testRecordingTransferQueueRequiresActivatedSessionAndNoOutstandingDuplicate() {
        XCTAssertFalse(
            RecordingTransferQueuePolicy.shouldQueue(
                recordingID: "rec_watch",
                sessionIsActivated: false,
                outstandingRecordingIDs: []
            )
        )
        XCTAssertFalse(
            RecordingTransferQueuePolicy.shouldQueue(
                recordingID: "rec_watch",
                sessionIsActivated: true,
                outstandingRecordingIDs: ["rec_watch"]
            )
        )
        XCTAssertTrue(
            RecordingTransferQueuePolicy.shouldQueue(
                recordingID: "rec_watch",
                sessionIsActivated: true,
                outstandingRecordingIDs: []
            )
        )
    }

    func testRecordingTransferReachabilityRequiresActivationCompanionAndLiveReachability() {
        XCTAssertTrue(
            RecordingTransferReachabilityPolicy.isReachable(
                sessionIsActivated: true,
                companionIsAvailable: true,
                sessionIsReachable: true
            )
        )
        XCTAssertFalse(
            RecordingTransferReachabilityPolicy.isReachable(
                sessionIsActivated: false,
                companionIsAvailable: true,
                sessionIsReachable: true
            )
        )
        XCTAssertFalse(
            RecordingTransferReachabilityPolicy.isReachable(
                sessionIsActivated: true,
                companionIsAvailable: false,
                sessionIsReachable: true
            )
        )
        XCTAssertFalse(
            RecordingTransferReachabilityPolicy.isReachable(
                sessionIsActivated: true,
                companionIsAvailable: true,
                sessionIsReachable: false
            )
        )
    }

    func testStagedWatchConnectivityFileIsDiscardedAfterImportAttempt() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "IdeaForgeTransferCleanupTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stagedURL = root.appending(path: "staged-watch-recording.m4a")
        try Data("staged watch audio".utf8).write(to: stagedURL)

        XCTAssertTrue(
            RecordingTransferFileStager.discardStagedFileAfterImport(
                stagedURL,
                fileManager: .default
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.path))
        XCTAssertTrue(
            RecordingTransferFileStager.discardStagedFileAfterImport(
                stagedURL,
                fileManager: .default
            )
        )
    }

    @MainActor
    func testWatchCaptureCanRemainPendingUntilTransferReceipt() async throws {
        let repository = InMemoryWorkspaceRepository()
        let store = IdeaForgeStore(
            projects: [],
            workflowTemplates: DefaultWorkflows.templates,
            selectedProjectID: nil,
            privacyMode: .privateLocal,
            syncHealth: SyncHealth(watchReachable: true, queuedUploads: 0, lastSuccessfulSync: SampleData.now, failingItems: 0),
            repository: repository
        )
        let services = IdeaForgeServices(
            transcription: LocalTranscriptionService(),
            workflow: LocalWorkflowExecutionService(),
            syncQueue: PendingSyncQueueService(),
            export: LocalExportService()
        )
        let draft = RecordingDraft(
            projectTitle: "Watch retry idea",
            tag: .appIdea,
            source: .watch,
            durationSeconds: 18,
            transcriptHint: "Watch idea should stay pending until handoff succeeds.",
            localAudioPath: "recordings/watch-retry.m4a"
        )

        let capturedProject = await store.capture(draft, services: services)
        let project = try XCTUnwrap(capturedProject)
        let recording = try XCTUnwrap(project.recordings.first)

        XCTAssertEqual(recording.syncStatus, .pending)
        XCTAssertEqual(recording.localFileStatus, .available)
        XCTAssertEqual(store.retryableWatchTransferRecording?.id, recording.id)

        store.markRecordingTransferredToIPhone(recordingID: recording.id, now: SampleData.now)

        let transferredRecording = try XCTUnwrap(store.projects.first?.recordings.first)
        XCTAssertEqual(transferredRecording.syncStatus, .transferredToIPhone)
        XCTAssertNil(store.retryableWatchTransferRecording)

        let saved = try XCTUnwrap(try repository.load())
        XCTAssertEqual(saved.projects.first?.recordings.first?.syncStatus, .transferredToIPhone)
    }

    @MainActor
    func testMarkRecordingWatchTransferFailedKeepsRecordingRetryable() async throws {
        let repository = InMemoryWorkspaceRepository()
        let store = IdeaForgeStore(
            projects: [],
            workflowTemplates: DefaultWorkflows.templates,
            selectedProjectID: nil,
            privacyMode: .privateLocal,
            syncHealth: SyncHealth(watchReachable: false, queuedUploads: 0, lastSuccessfulSync: SampleData.now, failingItems: 0),
            repository: repository
        )
        let services = IdeaForgeServices(
            transcription: LocalTranscriptionService(),
            workflow: LocalWorkflowExecutionService(),
            syncQueue: PendingSyncQueueService(),
            export: LocalExportService()
        )
        let draft = RecordingDraft(
            projectTitle: "Watch delivery failure idea",
            tag: .appIdea,
            source: .watch,
            durationSeconds: 12,
            transcriptHint: "Delivery failure must surface the retry affordance.",
            localAudioPath: "recordings/watch-delivery-failure.m4a"
        )

        let capturedProject = await store.capture(draft, services: services)
        let project = try XCTUnwrap(capturedProject)
        let recording = try XCTUnwrap(project.recordings.first)

        store.markRecordingWatchTransferFailed(recordingID: recording.id, now: SampleData.now)

        let failedRecording = try XCTUnwrap(store.projects.first?.recordings.first)
        XCTAssertEqual(failedRecording.syncStatus, .failed)
        XCTAssertEqual(failedRecording.localFileStatus, .available)
        XCTAssertEqual(store.retryableWatchTransferRecording?.id, recording.id)

        let saved = try XCTUnwrap(try repository.load())
        XCTAssertEqual(saved.projects.first?.recordings.first?.syncStatus, .failed)
    }

    @MainActor
    func testWatchTransferReceiptRollsBackWhenWorkspacePersistenceFails() throws {
        var originalState = WorkspaceState.seed()
        let recordingID = try XCTUnwrap(originalState.projects.first?.recordings.first?.id)
        originalState.projects[0].recordings[0].syncStatus = .pending
        let repository = ThrowingWorkspaceRepository(state: originalState)
        let store = IdeaForgeStore(state: originalState, repository: repository)

        XCTAssertFalse(
            store.markRecordingTransferredToIPhone(
                recordingID: recordingID,
                now: SampleData.now
            )
        )
        XCTAssertEqual(store.workspaceState(), originalState)
        XCTAssertEqual(store.lastErrorMessage, "Watch transfer receipt could not be saved.")

        XCTAssertFalse(
            store.markRecordingWatchTransferFailed(
                recordingID: recordingID,
                now: SampleData.now
            )
        )
        XCTAssertEqual(store.workspaceState(), originalState)
        XCTAssertEqual(store.lastErrorMessage, "Watch transfer failure could not be saved.")
    }

    @MainActor
    func testWatchAppendAddsRecordingWithoutOverwritingExistingCapture() async throws {
        let repository = InMemoryWorkspaceRepository()
        let services = IdeaForgeServices(
            transcription: LocalTranscriptionService(),
            workflow: LocalWorkflowExecutionService(),
            syncQueue: PendingSyncQueueService(),
            export: LocalExportService()
        )
        let firstDraft = RecordingDraft(
            projectTitle: "Offline Watch idea",
            tag: .appIdea,
            source: .watch,
            durationSeconds: 21,
            transcriptHint: "Original Watch capture.",
            localAudioPath: "recordings/watch-original.m4a",
            markerOffsets: [4]
        )
        let store = IdeaForgeStore(
            projects: [],
            workflowTemplates: DefaultWorkflows.templates,
            selectedProjectID: nil,
            privacyMode: .privateLocal,
            syncHealth: SyncHealth(watchReachable: false, queuedUploads: 0, lastSuccessfulSync: SampleData.now, failingItems: 0),
            repository: repository
        )
        let capturedProject = await store.capture(firstDraft, services: services)
        let project = try XCTUnwrap(capturedProject)
        let originalRecordingID = try XCTUnwrap(project.recordings.first?.id)

        let appendDraft = RecordingDraft(
            projectTitle: project.title,
            tag: .feature,
            source: .watch,
            durationSeconds: 13,
            transcriptHint: "Additional Watch note queued for transcription.",
            localAudioPath: "recordings/watch-append.m4a",
            markerOffsets: [2, 9]
        )
        let appended = await store.appendWatchRecording(appendDraft, to: project.id, services: services)
        let appendedRecording = try XCTUnwrap(appended)

        let updatedProject = try XCTUnwrap(store.projects.first { $0.id == project.id })
        XCTAssertEqual(updatedProject.recordings.count, 2)
        XCTAssertEqual(updatedProject.recordings.map(\.id), [appendedRecording.id, originalRecordingID])
        XCTAssertEqual(updatedProject.recordings.first?.localAudioPath, "recordings/watch-append.m4a")
        XCTAssertEqual(updatedProject.recordings.last?.localAudioPath, "recordings/watch-original.m4a")
        XCTAssertEqual(updatedProject.recordings.first?.syncStatus, .pending)
        XCTAssertEqual(updatedProject.recordings.first?.localFileStatus, .available)
        XCTAssertTrue(updatedProject.transcript.cleanText.contains("Original Watch capture."))
        XCTAssertTrue(updatedProject.transcript.cleanText.contains("Additional Watch note queued for transcription."))
        XCTAssertEqual(updatedProject.transcript.segments.last?.id, "segment_\(appendedRecording.id)")
        XCTAssertEqual(store.retryableWatchTransferRecording?.id, appendedRecording.id)
        XCTAssertEqual(store.watchCaptureProjects.first?.id, project.id)

        let saved = try XCTUnwrap(try repository.load())
        XCTAssertEqual(saved.projects.first?.recordings.count, 2)
        XCTAssertEqual(saved.projects.first?.recordings.first?.localAudioPath, "recordings/watch-append.m4a")
    }

    func testRetryableWatchTransferRecordingRequiresLocalAvailableAudio() throws {
        var project = SampleData.ideaForgeProject
        let failedLocalWatchRecording = Recording(
            id: "rec_failed_watch_retry",
            ideaProjectID: project.id,
            deviceName: "Apple Watch",
            durationSeconds: 42,
            localFileStatus: .available,
            syncStatus: .failed,
            localAudioPath: "recordings/rec_failed_watch_retry.m4a",
            languageHint: "en-US",
            createdAt: SampleData.now.addingTimeInterval(30),
            markerOffsets: []
        )
        let uploadedWatchRecording = Recording(
            id: "rec_uploaded_watch",
            ideaProjectID: project.id,
            deviceName: "Apple Watch",
            durationSeconds: 31,
            localFileStatus: .uploaded,
            syncStatus: .uploaded,
            localAudioPath: "recordings/rec_uploaded_watch.m4a",
            languageHint: "en-US",
            createdAt: SampleData.now.addingTimeInterval(60),
            markerOffsets: []
        )
        let missingPathWatchRecording = Recording(
            id: "rec_missing_path_watch",
            ideaProjectID: project.id,
            deviceName: "Apple Watch",
            durationSeconds: 28,
            localFileStatus: .available,
            syncStatus: .pending,
            localAudioPath: nil,
            languageHint: "en-US",
            createdAt: SampleData.now.addingTimeInterval(90),
            markerOffsets: []
        )
        project.recordings = [
            uploadedWatchRecording,
            missingPathWatchRecording,
            failedLocalWatchRecording
        ]
        let store = IdeaForgeStore(
            projects: [project],
            workflowTemplates: DefaultWorkflows.templates,
            privacyMode: .privateLocal,
            syncHealth: SyncHealth(watchReachable: true, queuedUploads: 0, lastSuccessfulSync: SampleData.now, failingItems: 0)
        )

        XCTAssertEqual(store.retryableWatchTransferRecording?.id, "rec_failed_watch_retry")
    }

    @MainActor
    func testTransferredWatchFileImportsIntoWorkspaceAndUploadQueue() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "IdeaForgeTransferTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appending(path: "watch-source.m4a")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("watch audio".utf8).write(to: sourceURL)
        let repository = InMemoryWorkspaceRepository()
        let store = IdeaForgeStore(
            projects: [],
            workflowTemplates: DefaultWorkflows.templates,
            selectedProjectID: nil,
            privacyMode: .privateLocal,
            syncHealth: SyncHealth(
                watchReachable: true,
                queuedUploads: 0,
                lastSuccessfulSync: SampleData.now,
                failingItems: 0
            ),
            repository: repository
        )
        let metadata = RecordingTransferMetadata(
            recordingID: "rec_watch_import",
            ideaProjectID: "idea_watch_import",
            sourceDeviceName: "Apple Watch",
            durationSeconds: 33,
            languageHint: "en-US",
            markerOffsets: [5, 20],
            createdAt: SampleData.now
        )
        let importer = TransferredRecordingImporter(inboxDirectory: root.appending(path: "inbox", directoryHint: .isDirectory))

        let project = try await importer.importFile(
            sourceURL: sourceURL,
            metadata: metadata,
            into: store
        )

        let saved = try XCTUnwrap(try repository.load())
        let recording = try XCTUnwrap(project.recordings.first)
        XCTAssertEqual(project.id, "idea_watch_import")
        XCTAssertEqual(project.title, "Watch Idea")
        XCTAssertEqual(recording.id, "rec_watch_import")
        XCTAssertEqual(recording.syncStatus, .transferredToIPhone)
        XCTAssertEqual(recording.localFileStatus, .available)
        XCTAssertEqual(recording.languageHint, "en-US")
        XCTAssertEqual(recording.markerOffsets, [5, 20])
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(recording.localAudioPath)))
        XCTAssertEqual(saved.uploadJobs.first?.recordingID, "rec_watch_import")
        XCTAssertEqual(saved.syncHealth.queuedUploads, 1)
    }

    @MainActor
    func testTransferredWatchFileImportFailsClosedWhenWorkspaceCannotBePersisted() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "IdeaForgeTransferPersistenceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceURL = root.appending(path: "watch-source.m4a")
        try Data("watch audio".utf8).write(to: sourceURL)

        let originalState = WorkspaceState(
            projects: [],
            workflowTemplates: DefaultWorkflows.templates,
            uploadJobs: [],
            privacyMode: .privateLocal,
            syncHealth: SyncHealth(
                watchReachable: true,
                queuedUploads: 0,
                lastSuccessfulSync: SampleData.now,
                failingItems: 0
            ),
            selectedProjectID: nil,
            updatedAt: SampleData.now
        )
        let repository = ThrowingWorkspaceRepository(state: originalState)
        let store = IdeaForgeStore(state: originalState, repository: repository)
        let metadata = RecordingTransferMetadata(
            recordingID: "rec_watch_import_persistence_failure",
            ideaProjectID: "idea_watch_import_persistence_failure",
            sourceDeviceName: "Apple Watch",
            durationSeconds: 33,
            languageHint: "en-US",
            markerOffsets: [5],
            createdAt: SampleData.now
        )
        let inbox = root.appending(path: "inbox", directoryHint: .isDirectory)
        let importer = TransferredRecordingImporter(inboxDirectory: inbox)

        do {
            _ = try await importer.importFile(sourceURL: sourceURL, metadata: metadata, into: store)
            XCTFail("Expected the import to fail when workspace persistence fails.")
        } catch {
            XCTAssertEqual(error as? TransferredRecordingImportError, .copyFailed)
        }

        XCTAssertEqual(store.workspaceState(), originalState)
        XCTAssertEqual(try repository.load(), originalState)
        XCTAssertFalse(FileManager.default.fileExists(atPath: inbox.appending(path: "rec_watch_import_persistence_failure.m4a").path))
    }

    @MainActor
    func testWatchCaptureFailsClosedWhenWorkspaceCannotBePersisted() async throws {
        let originalState = WorkspaceState(
            projects: [],
            workflowTemplates: DefaultWorkflows.templates,
            uploadJobs: [],
            privacyMode: .privateLocal,
            syncHealth: SyncHealth(
                watchReachable: false,
                queuedUploads: 0,
                lastSuccessfulSync: SampleData.now,
                failingItems: 0
            ),
            selectedProjectID: nil,
            updatedAt: SampleData.now
        )
        let repository = ThrowingWorkspaceRepository(state: originalState)
        let store = IdeaForgeStore(state: originalState, repository: repository)
        let draft = RecordingDraft(
            projectTitle: "Durable Watch capture",
            tag: .appIdea,
            source: .watch,
            durationSeconds: 12,
            transcriptHint: "Keep the recovery checkpoint if this cannot be saved.",
            localAudioPath: "recordings/watch-durable.m4a"
        )

        let captured = await store.capture(draft, services: .local)

        XCTAssertNil(captured)
        XCTAssertEqual(store.workspaceState(), originalState)
        XCTAssertEqual(try repository.load(), originalState)
        XCTAssertEqual(store.lastErrorMessage, "Capture could not be saved.")
    }

    @MainActor
    func testWatchAppendFailsClosedWhenWorkspaceCannotBePersisted() async throws {
        var originalState = WorkspaceState.seed()
        originalState.uploadJobs = []
        let projectID = try XCTUnwrap(originalState.projects.first?.id)
        let repository = ThrowingWorkspaceRepository(state: originalState)
        let store = IdeaForgeStore(state: originalState, repository: repository)
        let draft = RecordingDraft(
            projectTitle: "Durable Watch append",
            tag: .appIdea,
            source: .watch,
            durationSeconds: 14,
            transcriptHint: "This append must not exist only in memory.",
            localAudioPath: "recordings/watch-append-durable.m4a"
        )

        let appended = await store.appendWatchRecording(draft, to: projectID, services: .local)

        XCTAssertNil(appended)
        XCTAssertEqual(store.workspaceState(), originalState)
        XCTAssertEqual(try repository.load(), originalState)
        XCTAssertEqual(store.lastErrorMessage, "Watch append could not be saved.")
    }

    @MainActor
    func testWatchAppendRevalidatesTargetAfterAsyncQueueing() async throws {
        let initialState = WorkspaceState.seed()
        let repository = InMemoryWorkspaceRepository(state: initialState)
        let store = IdeaForgeStore(state: initialState, repository: repository)
        let targetID = try XCTUnwrap(store.projects.first?.id)
        let survivorID = try XCTUnwrap(store.projects.last?.id)
        let services = IdeaForgeServices(
            transcription: LocalTranscriptionService(),
            workflow: LocalWorkflowExecutionService(),
            syncQueue: MutatingSyncQueueService {
                store.projects.removeAll { $0.id == targetID }
                store.selectedProjectID = survivorID
                _ = store.save()
            },
            export: LocalExportService()
        )
        let draft = RecordingDraft(
            projectTitle: "Removed target",
            tag: .appIdea,
            source: .watch,
            durationSeconds: 10,
            transcriptHint: "Must not move to the survivor.",
            localAudioPath: "recordings/reentrant.m4a",
            recordingID: "rec_reentrant_watch_append"
        )

        let appended = await store.appendWatchRecording(draft, to: targetID, services: services)

        XCTAssertNil(appended)
        XCTAssertEqual(store.projects.map(\.id), [survivorID])
        XCTAssertFalse(store.projects.flatMap(\.recordings).contains { $0.id == "rec_reentrant_watch_append" })
        XCTAssertEqual(try repository.load()?.projects.map(\.id), [survivorID])
    }

    @MainActor
    func testTransferredWatchFileReplayIsIdempotentAndDoesNotOverwriteInboxFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "IdeaForgeTransferReplayTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceURL = root.appending(path: "watch-source.m4a")
        let replayURL = root.appending(path: "watch-replay.m4a")
        try Data("original watch audio".utf8).write(to: sourceURL)
        try Data("replayed partial audio".utf8).write(to: replayURL)
        let repository = InMemoryWorkspaceRepository()
        let store = IdeaForgeStore(
            projects: [],
            workflowTemplates: DefaultWorkflows.templates,
            selectedProjectID: nil,
            privacyMode: .privateLocal,
            syncHealth: SyncHealth(
                watchReachable: true,
                queuedUploads: 0,
                lastSuccessfulSync: SampleData.now,
                failingItems: 0
            ),
            repository: repository
        )
        let metadata = RecordingTransferMetadata(
            recordingID: "rec_watch_replay",
            ideaProjectID: "idea_watch_replay",
            sourceDeviceName: "Apple Watch",
            durationSeconds: 33,
            languageHint: "en-US",
            markerOffsets: [5, 20],
            createdAt: SampleData.now
        )
        let importer = TransferredRecordingImporter(inboxDirectory: root.appending(path: "inbox", directoryHint: .isDirectory))

        let firstProject = try await importer.importFile(
            sourceURL: sourceURL,
            metadata: metadata,
            into: store
        )
        let importedPath = try XCTUnwrap(firstProject.recordings.first?.localAudioPath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: importedPath)), Data("original watch audio".utf8))

        let replayedProject = try await importer.importFile(
            sourceURL: replayURL,
            metadata: metadata,
            into: store
        )

        XCTAssertEqual(replayedProject.id, firstProject.id)
        XCTAssertEqual(store.projects.count, 1)
        let project = try XCTUnwrap(store.projects.first)
        XCTAssertEqual(project.recordings.map(\.id), ["rec_watch_replay"])
        XCTAssertEqual(project.recordings.first?.localAudioPath, importedPath)
        XCTAssertEqual(store.uploadJobs.map(\.recordingID), ["rec_watch_replay"])
        XCTAssertEqual(store.syncHealth.queuedUploads, 1)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: importedPath)), Data("original watch audio".utf8))

        let saved = try XCTUnwrap(try repository.load())
        XCTAssertEqual(saved.projects.first?.recordings.map(\.id), ["rec_watch_replay"])
        XCTAssertEqual(saved.uploadJobs.map(\.recordingID), ["rec_watch_replay"])
        XCTAssertEqual(saved.syncHealth.queuedUploads, 1)
    }

    @MainActor
    func testTransferredWatchReplayRepairsMissingDurableAudio() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "IdeaForgeTransferRepairTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let firstURL = root.appending(path: "first.m4a")
        let replayURL = root.appending(path: "replay.m4a")
        try Data("first audio".utf8).write(to: firstURL)
        try Data("repaired audio".utf8).write(to: replayURL)
        let repository = InMemoryWorkspaceRepository()
        let store = IdeaForgeStore(
            projects: [],
            workflowTemplates: DefaultWorkflows.templates,
            privacyMode: .privateLocal,
            syncHealth: SyncHealth(watchReachable: true, queuedUploads: 0, lastSuccessfulSync: SampleData.now, failingItems: 0),
            repository: repository
        )
        let metadata = RecordingTransferMetadata(
            recordingID: "rec_watch_repair",
            ideaProjectID: "idea_watch_repair",
            sourceDeviceName: "Apple Watch",
            durationSeconds: 12,
            languageHint: "en-US",
            markerOffsets: [],
            createdAt: SampleData.now
        )
        let importer = TransferredRecordingImporter(inboxDirectory: root.appending(path: "inbox", directoryHint: .isDirectory))
        let firstProject = try await importer.importFile(sourceURL: firstURL, metadata: metadata, into: store)
        let importedPath = try XCTUnwrap(firstProject.recordings.first?.localAudioPath)
        try FileManager.default.removeItem(atPath: importedPath)

        let repairedProject = try await importer.importFile(sourceURL: replayURL, metadata: metadata, into: store)

        let repairedRecording = try XCTUnwrap(repairedProject.recordings.first)
        XCTAssertEqual(repairedRecording.localFileStatus, .available)
        XCTAssertEqual(repairedRecording.syncStatus, .transferredToIPhone)
        let repairedPath = try XCTUnwrap(repairedRecording.localAudioPath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: repairedPath)), Data("repaired audio".utf8))
        XCTAssertEqual(store.uploadJobs.first?.status, .queued)
        XCTAssertEqual(store.uploadJobs.first?.attemptCount, 0)
    }

    @MainActor
    func testReceivedWatchConnectivityFileIsStagedBeforeAsyncImport() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "IdeaForgeTransferStageTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceURL = root.appending(path: "watch-temp-source.m4a")
        try Data("temporary watch audio".utf8).write(to: sourceURL)
        let metadata = RecordingTransferMetadata(
            recordingID: "rec_watch_staged",
            ideaProjectID: "idea_watch_staged",
            sourceDeviceName: "Apple Watch",
            durationSeconds: 96,
            languageHint: "en-US",
            markerOffsets: [],
            createdAt: SampleData.now
        )

        let stagedURL = try RecordingTransferFileStager.stageReceivedFileForImport(
            sourceURL: sourceURL,
            metadata: metadata,
            rootDirectory: root.appending(path: "staged", directoryHint: .isDirectory)
        )
        try FileManager.default.removeItem(at: sourceURL)
        let repository = InMemoryWorkspaceRepository()
        let store = IdeaForgeStore(
            projects: [],
            workflowTemplates: DefaultWorkflows.templates,
            selectedProjectID: nil,
            privacyMode: .privateLocal,
            syncHealth: SyncHealth(
                watchReachable: true,
                queuedUploads: 0,
                lastSuccessfulSync: SampleData.now,
                failingItems: 0
            ),
            repository: repository
        )
        let importer = TransferredRecordingImporter(inboxDirectory: root.appending(path: "inbox", directoryHint: .isDirectory))

        let project = try await importer.importFile(
            sourceURL: stagedURL,
            metadata: metadata,
            into: store
        )

        let recording = try XCTUnwrap(project.recordings.first)
        let importedPath = try XCTUnwrap(recording.localAudioPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: importedPath)), Data("temporary watch audio".utf8))
        XCTAssertEqual(recording.durationSeconds, 96)
        XCTAssertEqual(recording.syncStatus, .transferredToIPhone)
    }

    @MainActor
    func testAttachRecordingIsIdempotentForDuplicateRecordingIDs() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "IdeaForgeAttachReplayTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceURL = root.appending(path: "watch-source.m4a")
        try Data("original watch audio".utf8).write(to: sourceURL)
        let repository = InMemoryWorkspaceRepository()
        let store = IdeaForgeStore(
            projects: [],
            workflowTemplates: DefaultWorkflows.templates,
            selectedProjectID: nil,
            privacyMode: .privateLocal,
            syncHealth: SyncHealth(
                watchReachable: true,
                queuedUploads: 0,
                lastSuccessfulSync: SampleData.now,
                failingItems: 0
            ),
            repository: repository
        )
        let metadata = RecordingTransferMetadata(
            recordingID: "rec_attach_replay",
            ideaProjectID: "idea_attach_replay",
            sourceDeviceName: "Apple Watch",
            durationSeconds: 33,
            languageHint: "en-US",
            markerOffsets: [5, 20],
            createdAt: SampleData.now
        )
        let importer = TransferredRecordingImporter(inboxDirectory: root.appending(path: "inbox", directoryHint: .isDirectory))
        _ = try await importer.importFile(sourceURL: sourceURL, metadata: metadata, into: store)
        let originalTranscript = try XCTUnwrap(store.projects.first?.transcript)

        let duplicateRecording = Recording(
            id: "rec_attach_replay",
            ideaProjectID: "idea_attach_replay",
            deviceName: "Apple Watch",
            durationSeconds: 12,
            localFileStatus: .available,
            syncStatus: .transferredToIPhone,
            localAudioPath: root.appending(path: "other.m4a").path,
            languageHint: "en-US",
            createdAt: SampleData.now.addingTimeInterval(60),
            markerOffsets: []
        )
        let duplicateTranscript = Transcript(
            cleanText: "Duplicate should not overwrite transcript.",
            segments: [],
            unclearFragments: []
        )

        store.attach(recording: duplicateRecording, to: "idea_attach_replay", transcript: duplicateTranscript)

        let project = try XCTUnwrap(store.projects.first)
        XCTAssertEqual(project.recordings.map(\.id), ["rec_attach_replay"])
        XCTAssertEqual(project.transcript, originalTranscript)
        XCTAssertEqual(store.uploadJobs.map(\.recordingID), ["rec_attach_replay"])
        XCTAssertEqual(store.syncHealth.queuedUploads, 1)
    }

    @MainActor
    func testAttachNewTransferredRecordingPreservesExistingProjectTranscript() throws {
        let state = WorkspaceState.seed()
        let projectID = try XCTUnwrap(state.projects.first?.id)
        let originalTranscript = try XCTUnwrap(state.projects.first?.transcript)
        let store = IdeaForgeStore(state: state, repository: InMemoryWorkspaceRepository(state: state))
        let recording = Recording(
            id: "rec_late_watch_transfer",
            ideaProjectID: projectID,
            deviceName: "Apple Watch",
            durationSeconds: 20,
            localFileStatus: .available,
            syncStatus: .transferredToIPhone,
            localAudioPath: "recordings/rec_late_watch_transfer.m4a",
            languageHint: "en-US",
            createdAt: SampleData.now,
            markerOffsets: []
        )
        let placeholder = Transcript(cleanText: "Voice idea transferred from Apple Watch.", segments: [], unclearFragments: [])

        XCTAssertTrue(store.attach(recording: recording, to: projectID, transcript: placeholder))
        XCTAssertEqual(store.projects.first?.transcript, originalTranscript)
    }

    func testUploadQueuePolicySchedulesBoundedRetry() {
        let now = Date(timeIntervalSince1970: 100)
        let job = UploadJob(
            id: "upload_rec_retry",
            recordingID: "rec_retry",
            ideaProjectID: "idea_retry",
            localAudioPath: "recordings/retry.m4a",
            status: .uploading,
            attemptCount: 3,
            nextAttemptAt: now,
            createdAt: now,
            updatedAt: now
        )

        let failed = UploadQueuePolicy.markFailed(job, message: "network offline", now: now)

        XCTAssertEqual(failed.status, .waitingForRetry)
        XCTAssertEqual(failed.lastErrorMessage, "network offline")
        XCTAssertEqual(failed.nextAttemptAt, now.addingTimeInterval(240))
    }

    func testUploadFailureCategoryClassifiesTypedTransportAndHTTPFailures() {
        XCTAssertEqual(
            UploadFailureCategory.classify(URLError(.notConnectedToInternet)),
            .connectivity
        )
        XCTAssertEqual(
            UploadFailureCategory.classify(URLError(.timedOut)),
            .connectivity
        )
        XCTAssertEqual(
            UploadFailureCategory.classify(UploadClientError.httpStatus(401)),
            .authentication
        )
        XCTAssertEqual(
            UploadFailureCategory.classify(UploadClientError.httpStatus(403)),
            .entitlement
        )
        XCTAssertEqual(
            UploadFailureCategory.classify(UploadClientError.httpStatus(503)),
            .server
        )
        XCTAssertEqual(
            UploadFailureCategory.classify(BackendConfigurationError.invalidBaseURL("not a URL")),
            .configuration
        )
        XCTAssertEqual(
            UploadFailureCategory.classify(NSError(domain: "IdeaForgeTests", code: 1)),
            .uploadError
        )
    }

    func testUploadJobDecodesLegacyStateWithoutFailureCategory() throws {
        let data = Data(
            #"{"id":"upload_legacy","recordingID":"rec_legacy","ideaProjectID":"idea_legacy","localAudioPath":"recordings/legacy.m4a","status":"permanentlyFailed","attemptCount":5,"nextAttemptAt":0,"lastErrorMessage":"offline","createdAt":0,"updatedAt":0}"#.utf8
        )

        let job = try JSONDecoder().decode(UploadJob.self, from: data)

        XCTAssertEqual(job.id, "upload_legacy")
        XCTAssertNil(job.failureCategory)
    }

    func testUploadQueuePolicyMarksPermanentFailureAtMaximumAttempts() {
        let now = Date(timeIntervalSince1970: 100)
        let job = UploadJob(
            id: "upload_rec_dead",
            recordingID: "rec_dead",
            ideaProjectID: "idea_dead",
            localAudioPath: "recordings/dead.m4a",
            status: .uploading,
            attemptCount: UploadQueuePolicy.maximumAttempts,
            nextAttemptAt: now,
            createdAt: now,
            updatedAt: now
        )

        let failed = UploadQueuePolicy.markFailed(job, message: "bad request", now: now)

        XCTAssertEqual(failed.status, .permanentlyFailed)
        XCTAssertEqual(failed.nextAttemptAt, now)
    }

    func testManualRetryResetsOnlyPermanentFailureWithoutChangingPath() {
        let now = Date(timeIntervalSince1970: 2_000)
        let failed = UploadJob(
            id: "upload_rec",
            recordingID: "rec",
            ideaProjectID: "idea",
            localAudioPath: "/tmp/recording.m4a",
            status: .permanentlyFailed,
            attemptCount: 5,
            nextAttemptAt: now.addingTimeInterval(900),
            objectKey: "stale-object-key",
            lastErrorMessage: "failed",
            createdAt: now,
            updatedAt: now
        )

        let retried = UploadQueuePolicy.manualRetry(failed, now: now)

        XCTAssertEqual(retried?.status, .queued)
        XCTAssertEqual(retried?.attemptCount, 0)
        XCTAssertEqual(retried?.nextAttemptAt, now)
        XCTAssertNil(retried?.objectKey)
        XCTAssertNil(retried?.lastErrorMessage)
        XCTAssertEqual(retried?.localAudioPath, failed.localAudioPath)
        XCTAssertNil(UploadQueuePolicy.manualRetry(UploadQueuePolicy.markUploading(failed, now: now), now: now))
    }

    func testUploadQueuePolicyPersistsAndClearsFailureCategory() throws {
        let now = Date(timeIntervalSince1970: 2_100)
        let uploading = UploadJob(
            id: "upload_categorized",
            recordingID: "rec_categorized",
            ideaProjectID: "idea_categorized",
            localAudioPath: "recordings/categorized.m4a",
            status: .uploading,
            attemptCount: UploadQueuePolicy.maximumAttempts,
            nextAttemptAt: now,
            createdAt: now,
            updatedAt: now
        )

        let failed = UploadQueuePolicy.markFailed(
            uploading,
            message: "The Internet connection appears to be offline.",
            category: .connectivity,
            now: now
        )
        let retried = try XCTUnwrap(UploadQueuePolicy.manualRetry(failed, now: now.addingTimeInterval(1)))
        let uploaded = UploadQueuePolicy.markUploaded(
            failed,
            objectKey: "audio/idea_categorized/rec_categorized.m4a",
            now: now.addingTimeInterval(1)
        )

        XCTAssertEqual(failed.failureCategory, .connectivity)
        XCTAssertNil(retried.failureCategory)
        XCTAssertNil(retried.lastErrorMessage)
        XCTAssertNil(uploaded.failureCategory)
        XCTAssertNil(uploaded.lastErrorMessage)
    }

    @MainActor
    func testStoreRetryPersistsWatchRecordingBeforeItBecomesDue() throws {
        let fixture = try FailedUploadFixture.make(source: .watch)
        defer { try? fixture.fileManager.removeItem(at: fixture.directory) }
        let store = IdeaForgeStore(state: fixture.state, repository: fixture.repository)

        XCTAssertTrue(store.retryUpload(recordingID: fixture.recordingID, now: fixture.now, fileManager: fixture.fileManager))

        let persisted = try XCTUnwrap(try fixture.repository.load())
        let job = try XCTUnwrap(persisted.uploadJobs.first { $0.recordingID == fixture.recordingID })
        let recording = try XCTUnwrap(persisted.projects.flatMap(\.recordings).first { $0.id == fixture.recordingID })
        XCTAssertEqual(job.status, .queued)
        XCTAssertEqual(job.nextAttemptAt, fixture.now)
        XCTAssertEqual(job.localAudioPath, fixture.localAudioPath)
        XCTAssertEqual(recording.syncStatus, .transferredToIPhone)
        XCTAssertEqual(recording.localFileStatus, .available)
        XCTAssertEqual(recording.localAudioPath, fixture.localAudioPath)
        XCTAssertEqual(try Data(contentsOf: fixture.audioURL), fixture.audioData)
        XCTAssertEqual(UploadSchedulePolicy.nextRunDate(for: persisted.uploadJobs, now: fixture.now), fixture.now)
        XCTAssertEqual(persisted.syncHealth.failingItems, 0)
        XCTAssertEqual(persisted.syncHealth.queuedUploads, 1)
    }

    @MainActor
    func testStoreRetryPublishesOnlyAfterRepositorySavesCandidateState() throws {
        let fixture = try FailedUploadFixture.make(source: .iphone)
        defer { try? fixture.fileManager.removeItem(at: fixture.directory) }
        let repository = ObservingWorkspaceRepository(state: fixture.state)
        let store = IdeaForgeStore(state: fixture.state, repository: repository)
        let oldState = store.workspaceState()
        var observedSave = false
        repository.willSave = { candidateState in
            observedSave = true
            XCTAssertEqual(candidateState.uploadJobs.first?.status, .queued)
            XCTAssertEqual(store.workspaceState(), oldState)
            XCTAssertEqual(store.uploadJobs.first?.status, .permanentlyFailed)
            XCTAssertEqual(store.projects.flatMap(\.recordings).first?.syncStatus, .failed)
            XCTAssertEqual(store.syncHealth, oldState.syncHealth)
            XCTAssertEqual(store.updatedAt, oldState.updatedAt)
        }

        XCTAssertTrue(store.retryUpload(recordingID: fixture.recordingID, now: fixture.now, fileManager: fixture.fileManager))

        XCTAssertTrue(observedSave)
        XCTAssertEqual(try repository.load()?.uploadJobs.first?.status, .queued)
        XCTAssertEqual(try Data(contentsOf: fixture.audioURL), fixture.audioData)
        XCTAssertEqual(store.projects.flatMap(\.recordings).first?.localAudioPath, fixture.localAudioPath)
    }

    @MainActor
    func testStoreRetryRejectsMissingAudioWithoutChangingState() throws {
        let fixture = try FailedUploadFixture.make(source: .iphone)
        defer { try? fixture.fileManager.removeItem(at: fixture.directory) }
        try fixture.fileManager.removeItem(at: fixture.audioURL)
        let store = IdeaForgeStore(state: fixture.state, repository: fixture.repository)
        let oldState = store.workspaceState()

        XCTAssertFalse(store.canRetryUpload(recordingID: fixture.recordingID, fileManager: fixture.fileManager))
        XCTAssertFalse(store.retryUpload(recordingID: fixture.recordingID, now: fixture.now, fileManager: fixture.fileManager))

        XCTAssertEqual(store.workspaceState(), oldState)
        XCTAssertEqual(store.uploadJobs.first?.localAudioPath, fixture.localAudioPath)
        XCTAssertEqual(store.projects.flatMap(\.recordings).first?.localAudioPath, fixture.localAudioPath)
        XCTAssertFalse((store.lastErrorMessage ?? "").contains(fixture.localAudioPath))
    }

    @MainActor
    func testStoreRetryRejectsDirectorySourceWithoutChangingState() throws {
        let fixture = try FailedUploadFixture.make(source: .iphone)
        defer { try? fixture.fileManager.removeItem(at: fixture.directory) }
        let directorySource = fixture.directory.appending(path: "retained-audio", directoryHint: .isDirectory)
        try fixture.fileManager.createDirectory(at: directorySource, withIntermediateDirectories: true)
        var state = fixture.state
        state.projects[0].recordings[0].localAudioPath = directorySource.path
        state.uploadJobs[0].localAudioPath = directorySource.path
        let repository = InMemoryWorkspaceRepository(state: state)
        let store = IdeaForgeStore(state: state, repository: repository)
        let oldState = store.workspaceState()

        XCTAssertTrue(fixture.fileManager.fileExists(atPath: directorySource.path))
        XCTAssertFalse(store.canRetryUpload(recordingID: fixture.recordingID, fileManager: fixture.fileManager))
        XCTAssertFalse(store.retryUpload(recordingID: fixture.recordingID, now: fixture.now, fileManager: fixture.fileManager))

        XCTAssertEqual(store.workspaceState(), oldState)
        XCTAssertEqual(try repository.load(), oldState)
        XCTAssertEqual(store.uploadJobs.first?.localAudioPath, directorySource.path)
        XCTAssertEqual(store.projects.flatMap(\.recordings).first?.localAudioPath, directorySource.path)
        XCTAssertFalse((store.lastErrorMessage ?? "").contains(directorySource.path))
    }

    @MainActor
    func testRetainedAudioValidationDistinguishesAvailableMismatchedInvalidAndUnavailable() throws {
        let fixture = try FailedUploadFixture.make(source: .iphone)
        defer { try? fixture.fileManager.removeItem(at: fixture.directory) }

        let availableStore = IdeaForgeStore(state: fixture.state, repository: fixture.repository)
        let availableJob = try XCTUnwrap(fixture.state.uploadJobs.first)
        let availableRecording = try XCTUnwrap(fixture.state.projects.first?.recordings.first)
        XCTAssertEqual(
            availableStore.retainedAudioValidation(
                recordingID: fixture.recordingID,
                fileManager: fixture.fileManager
            ),
            .available
        )
        XCTAssertEqual(
            IdeaForgeStore.retainedAudioValidation(
                job: availableJob,
                recording: availableRecording,
                fileManager: fixture.fileManager
            ),
            .available
        )

        var mismatchedState = fixture.state
        mismatchedState.uploadJobs[0].localAudioPath = fixture.directory.appending(path: "different.m4a").path
        let mismatchedStore = IdeaForgeStore(state: mismatchedState)
        XCTAssertEqual(
            mismatchedStore.retainedAudioValidation(
                recordingID: fixture.recordingID,
                fileManager: fixture.fileManager
            ),
            .mismatched
        )

        try fixture.fileManager.removeItem(at: fixture.audioURL)
        try fixture.fileManager.createDirectory(at: fixture.audioURL, withIntermediateDirectories: true)
        let invalidStore = IdeaForgeStore(state: fixture.state)
        XCTAssertEqual(
            invalidStore.retainedAudioValidation(
                recordingID: fixture.recordingID,
                fileManager: fixture.fileManager
            ),
            .invalid
        )

        try fixture.fileManager.removeItem(at: fixture.audioURL)
        let unavailableStore = IdeaForgeStore(state: fixture.state)
        XCTAssertEqual(
            unavailableStore.retainedAudioValidation(
                recordingID: fixture.recordingID,
                fileManager: fixture.fileManager
            ),
            .unavailable
        )
    }

    @MainActor
    func testStoreRetryRejectsNonPermanentJobWithoutChangingState() throws {
        let fixture = try FailedUploadFixture.make(source: .iphone)
        defer { try? fixture.fileManager.removeItem(at: fixture.directory) }
        var state = fixture.state
        state.uploadJobs[0].status = .waitingForRetry
        let store = IdeaForgeStore(state: state, repository: fixture.repository)
        let oldState = store.workspaceState()

        XCTAssertFalse(store.canRetryUpload(recordingID: fixture.recordingID, fileManager: fixture.fileManager))
        XCTAssertFalse(store.retryUpload(recordingID: fixture.recordingID, now: fixture.now, fileManager: fixture.fileManager))

        XCTAssertEqual(store.workspaceState(), oldState)
        XCTAssertEqual(try Data(contentsOf: fixture.audioURL), fixture.audioData)
        XCTAssertEqual(store.uploadJobs.first?.localAudioPath, fixture.localAudioPath)
        XCTAssertEqual(store.projects.flatMap(\.recordings).first?.localAudioPath, fixture.localAudioPath)
        XCTAssertFalse((store.lastErrorMessage ?? "").contains(fixture.localAudioPath))
    }

    @MainActor
    func testStoreRetryRetainsLiveAndPersistedStateWhenRepositorySaveFails() throws {
        let fixture = try FailedUploadFixture.make(source: .iphone)
        defer { try? fixture.fileManager.removeItem(at: fixture.directory) }
        let repository = ThrowingWorkspaceRepository(state: fixture.state)
        let store = IdeaForgeStore(state: fixture.state, repository: repository)
        let oldState = store.workspaceState()

        XCTAssertTrue(store.canRetryUpload(recordingID: fixture.recordingID, fileManager: fixture.fileManager))
        XCTAssertFalse(store.retryUpload(recordingID: fixture.recordingID, now: fixture.now, fileManager: fixture.fileManager))

        XCTAssertEqual(store.workspaceState(), oldState)
        XCTAssertEqual(try repository.load(), oldState)
        XCTAssertEqual(store.lastErrorMessage, "Could not save the upload retry.")
        XCTAssertFalse((store.lastErrorMessage ?? "").contains(fixture.localAudioPath))
        XCTAssertEqual(try Data(contentsOf: fixture.audioURL), fixture.audioData)
        XCTAssertEqual(store.uploadJobs.first?.localAudioPath, fixture.localAudioPath)
        XCTAssertEqual(store.projects.flatMap(\.recordings).first?.localAudioPath, fixture.localAudioPath)
    }

    @MainActor
    func testUploadSuccessRollsBackWhenWorkspacePersistenceFails() throws {
        let fixture = try FailedUploadFixture.make(source: .iphone)
        defer { try? fixture.fileManager.removeItem(at: fixture.directory) }
        let repository = ThrowingWorkspaceRepository(state: fixture.state)
        let store = IdeaForgeStore(state: fixture.state, repository: repository)

        XCTAssertFalse(
            store.markUploadSucceeded(
                recordingID: fixture.recordingID,
                objectKey: "audio/test/object.m4a",
                now: fixture.now
            )
        )
        XCTAssertEqual(store.workspaceState(), fixture.state)
        XCTAssertEqual(try repository.load(), fixture.state)
        XCTAssertEqual(store.lastErrorMessage, "Upload completion could not be saved.")
    }

    @MainActor
    func testUploadStartRollsBackWhenWorkspacePersistenceFails() throws {
        let fixture = try FailedUploadFixture.make(source: .iphone)
        defer { try? fixture.fileManager.removeItem(at: fixture.directory) }
        let repository = ThrowingWorkspaceRepository(state: fixture.state)
        let store = IdeaForgeStore(state: fixture.state, repository: repository)

        store.markUploadStarted(recordingID: fixture.recordingID, now: fixture.now)

        XCTAssertEqual(store.workspaceState(), fixture.state)
        XCTAssertEqual(try repository.load(), fixture.state)
        XCTAssertEqual(store.lastErrorMessage, "Upload start could not be saved.")
    }

    @MainActor
    func testInterruptedUploadRecoveryRollsBackWhenWorkspacePersistenceFails() throws {
        let fixture = try FailedUploadFixture.make(source: .iphone)
        defer { try? fixture.fileManager.removeItem(at: fixture.directory) }
        var state = fixture.state
        let startedAt = fixture.now.addingTimeInterval(-UploadQueuePolicy.interruptedUploadTimeout - 1)
        state.uploadJobs[0] = UploadQueuePolicy.markUploading(state.uploadJobs[0], now: startedAt)
        let repository = ThrowingWorkspaceRepository(state: state)
        let store = IdeaForgeStore(state: state, repository: repository)

        XCTAssertEqual(store.recoverInterruptedUploads(now: fixture.now), 0)

        XCTAssertEqual(store.workspaceState(), state)
        XCTAssertEqual(try repository.load(), state)
        XCTAssertEqual(store.lastErrorMessage, "Interrupted upload recovery could not be saved.")
    }

    @MainActor
    func testUploadFailureRollsBackWhenWorkspacePersistenceFails() throws {
        let fixture = try FailedUploadFixture.make(source: .iphone)
        defer { try? fixture.fileManager.removeItem(at: fixture.directory) }
        let repository = ThrowingWorkspaceRepository(state: fixture.state)
        let store = IdeaForgeStore(state: fixture.state, repository: repository)

        XCTAssertFalse(
            store.markUploadFailed(
                recordingID: fixture.recordingID,
                message: "offline",
                category: .connectivity,
                now: fixture.now
            )
        )
        XCTAssertEqual(store.workspaceState(), fixture.state)
        XCTAssertEqual(try repository.load(), fixture.state)
        XCTAssertEqual(store.lastErrorMessage, "Upload failure could not be saved.")
    }

    @MainActor
    func testHistoricalUploadCompletionDoesNotMoveWorkspaceClockBackward() throws {
        let fixture = try FailedUploadFixture.make(source: .iphone)
        defer { try? fixture.fileManager.removeItem(at: fixture.directory) }
        var state = fixture.state
        let newerEditAt = Date(timeIntervalSince1970: 9_000)
        state.updatedAt = newerEditAt
        let repository = InMemoryWorkspaceRepository(state: state)
        let store = IdeaForgeStore(state: state, repository: repository)

        XCTAssertTrue(
            store.markUploadSucceeded(
                recordingID: fixture.recordingID,
                objectKey: "audio/test/object.m4a",
                now: Date(timeIntervalSince1970: 8_000)
            )
        )

        XCTAssertEqual(store.updatedAt, newerEditAt)
        XCTAssertEqual(try repository.load()?.updatedAt, newerEditAt)
    }

    @MainActor
    func testWatchTransferReceiptRejectsUnknownRecordingID() {
        let state = WorkspaceState.seed()
        let store = IdeaForgeStore(state: state, repository: InMemoryWorkspaceRepository(state: state))

        XCTAssertFalse(store.markRecordingTransferredToIPhone(recordingID: "rec_unknown", now: SampleData.now))
        XCTAssertFalse(store.markRecordingWatchTransferFailed(recordingID: "rec_unknown", now: SampleData.now))
        XCTAssertEqual(store.workspaceState(), state)
    }

    func testUploadQueuePolicyRecoversInterruptedInFlightUpload() {
        let startedAt = Date(timeIntervalSince1970: 100)
        let recoveredAt = startedAt.addingTimeInterval(UploadQueuePolicy.interruptedUploadTimeout + 1)
        let job = UploadJob(
            id: "upload_rec_interrupted",
            recordingID: "rec_interrupted",
            ideaProjectID: "idea_interrupted",
            localAudioPath: "recordings/interrupted.m4a",
            status: .uploading,
            attemptCount: 1,
            nextAttemptAt: startedAt,
            createdAt: startedAt,
            updatedAt: startedAt
        )

        let recovered = UploadQueuePolicy.markInterruptedForRetry(job, now: recoveredAt)

        XCTAssertEqual(recovered.status, .waitingForRetry)
        XCTAssertEqual(recovered.attemptCount, 1)
        XCTAssertEqual(recovered.nextAttemptAt, recoveredAt)
        XCTAssertEqual(recovered.lastErrorMessage, "Upload was interrupted and will retry.")
    }

    func testUploadQueuePolicyInterruptedRecoveryHonorsMaximumAttempts() {
        let startedAt = Date(timeIntervalSince1970: 100)
        let recoveredAt = startedAt.addingTimeInterval(UploadQueuePolicy.interruptedUploadTimeout + 1)
        let job = UploadJob(
            id: "upload_rec_interrupted_exhausted",
            recordingID: "rec_interrupted_exhausted",
            ideaProjectID: "idea_interrupted",
            localAudioPath: "recordings/interrupted.m4a",
            status: .uploading,
            attemptCount: UploadQueuePolicy.maximumAttempts,
            nextAttemptAt: startedAt,
            createdAt: startedAt,
            updatedAt: startedAt
        )

        let recovered = UploadQueuePolicy.markInterruptedForRetry(job, now: recoveredAt)

        XCTAssertEqual(recovered.status, .permanentlyFailed)
        XCTAssertEqual(recovered.lastErrorMessage, UploadQueuePolicy.interruptedUploadExhaustedMessage)
    }

    func testLocalAudioObjectUploadClientStoresAudioAndReturnsObjectKey() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "IdeaForgeUploadTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appending(path: "source.m4a")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: sourceURL)

        let job = UploadJob(
            id: "upload_rec_local",
            recordingID: "rec_local",
            ideaProjectID: "idea_local",
            localAudioPath: sourceURL.path,
            status: .uploading,
            attemptCount: 1,
            nextAttemptAt: SampleData.now,
            createdAt: SampleData.now,
            updatedAt: SampleData.now
        )
        let objectStore = EncryptedLocalAudioObjectStore(
            objectRoot: root.appending(path: "objects", directoryHint: .isDirectory),
            keyProvider: StaticObjectEncryptionKeyProvider.testKey()
        )
        let client = LocalAudioObjectUploadClient(objectStore: objectStore)

        let receipt = try await client.upload(job: job)

        XCTAssertEqual(receipt.recordingID, "rec_local")
        XCTAssertEqual(receipt.objectKey, "audio/idea_local/rec_local.m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "objects/audio/idea_local/rec_local.m4a").path))
    }

    func testLocalAudioObjectUploadClientEncryptsStoredAudioAndReadsBackPlaintext() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "IdeaForgeEncryptedUploadTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appending(path: "source.m4a")
        let plaintext = Data("private voice memo contents".utf8)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try plaintext.write(to: sourceURL)

        let job = UploadJob(
            id: "upload_rec_encrypted",
            recordingID: "rec_encrypted",
            ideaProjectID: "idea_encrypted",
            localAudioPath: sourceURL.path,
            status: .uploading,
            attemptCount: 1,
            nextAttemptAt: SampleData.now,
            createdAt: SampleData.now,
            updatedAt: SampleData.now
        )
        let objectStore = EncryptedLocalAudioObjectStore(
            objectRoot: root.appending(path: "objects", directoryHint: .isDirectory),
            keyProvider: StaticObjectEncryptionKeyProvider.testKey()
        )
        let client = LocalAudioObjectUploadClient(objectStore: objectStore)

        let receipt = try await client.upload(job: job)
        let storedURL = try objectStore.storedObjectURL(for: receipt.objectKey)
        let storedData = try Data(contentsOf: storedURL)
        let restored = try objectStore.readObjectData(objectKey: receipt.objectKey)

        XCTAssertEqual(receipt.objectKey, "audio/idea_encrypted/rec_encrypted.m4a")
        XCTAssertFalse(storedData.contains(plaintext))
        XCTAssertEqual(restored, plaintext)
    }

    func testEncryptedLocalAudioObjectStoreRejectsUnsafeObjectKeys() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "IdeaForgeUnsafeObjectTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appending(path: "source.m4a")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: sourceURL)

        let objectStore = EncryptedLocalAudioObjectStore(
            objectRoot: root.appending(path: "objects", directoryHint: .isDirectory),
            keyProvider: StaticObjectEncryptionKeyProvider.testKey()
        )

        do {
            try objectStore.storeAudio(
                from: sourceURL,
                objectKey: "../escape.m4a",
                recordingID: "rec_unsafe",
                ideaProjectID: "idea_unsafe"
            )
            XCTFail("Expected unsafe object key to fail closed.")
        } catch let error as LocalAudioObjectStoreError {
            XCTAssertEqual(error, .unsafeObjectKey("../escape.m4a"))
        }
    }

    func testBackendAudioUploadClientPostsAudioAndReadsObjectKey() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "IdeaForgeBackendUploadTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appending(path: "source.m4a")
        let audioData = Data("remote audio".utf8)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try audioData.write(to: sourceURL)
        let job = UploadJob(
            id: "upload_rec_backend",
            recordingID: "rec_backend",
            ideaProjectID: "idea_backend",
            localAudioPath: sourceURL.path,
            status: .uploading,
            attemptCount: 2,
            nextAttemptAt: SampleData.now,
            createdAt: SampleData.now,
            updatedAt: SampleData.now
        )
        let transport = CapturingHTTPUploadTransport(
            responseData: Data(#"{"objectKey":"audio/idea_backend/rec_backend.m4a"}"#.utf8),
            statusCode: 201
        )
        let client = BackendAudioUploadClient(
            configuration: BackendUploadConfiguration(
                baseURL: URL(string: "https://api.example.test")!,
                bearerToken: "test-token",
                workspaceID: "workspace_alpha"
            ),
            transport: transport
        )

        let receipt = try await client.upload(job: job)
        let captured = await transport.capturedRequest()

        XCTAssertEqual(receipt, UploadReceipt(recordingID: "rec_backend", objectKey: "audio/idea_backend/rec_backend.m4a"))
        XCTAssertEqual(captured.request?.url?.absoluteString, "https://api.example.test/v1/recordings/upload")
        XCTAssertEqual(captured.request?.httpMethod, "POST")
        XCTAssertEqual(captured.request?.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(captured.request?.value(forHTTPHeaderField: "X-IdeaForge-Workspace-ID"), "workspace_alpha")
        XCTAssertEqual(captured.request?.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
        XCTAssertEqual(captured.request?.value(forHTTPHeaderField: "X-IdeaForge-Recording-ID"), "rec_backend")
        XCTAssertEqual(captured.request?.value(forHTTPHeaderField: "X-IdeaForge-Idea-ID"), "idea_backend")
        XCTAssertEqual(captured.request?.value(forHTTPHeaderField: "X-IdeaForge-Upload-Job-ID"), "upload_rec_backend")
        XCTAssertEqual(
            captured.request?.value(forHTTPHeaderField: "X-IdeaForge-Content-SHA256"),
            "bcac4b575736492c3e64a8a60af1ed6839642228f30217c12176b5ed08a06407"
        )
        XCTAssertEqual(captured.request?.value(forHTTPHeaderField: "Content-Length"), "\(audioData.count)")
        XCTAssertEqual(captured.request?.value(forHTTPHeaderField: "X-IdeaForge-Attempt"), "2")
        XCTAssertEqual(captured.sourceURL, sourceURL)
        XCTAssertEqual(captured.body, audioData)
    }

    func testBackgroundUploadCompletionRecordRestoresSuccessfulReceiptAfterRelaunch() throws {
        let record = BackgroundUploadCompletionRecord(
            uploadJobID: "upload_rec_background",
            recordingID: "rec_background",
            responseData: try JSONSerialization.data(withJSONObject: ["objectKey": "audio/idea/rec_background.m4a"]),
            statusCode: 200,
            errorDescription: nil,
            completedAt: SampleData.now
        )

        XCTAssertEqual(
            try BackgroundUploadCompletionPolicy.receipt(from: record),
            UploadReceipt(
                recordingID: "rec_background",
                objectKey: "audio/idea/rec_background.m4a"
            )
        )
    }

    func testBackgroundUploadCompletionRecordFailsClosedForUnsuccessfulResponse() {
        let record = BackgroundUploadCompletionRecord(
            uploadJobID: "upload_rec_background",
            recordingID: "rec_background",
            responseData: Data(),
            statusCode: 503,
            errorDescription: nil,
            completedAt: SampleData.now
        )

        XCTAssertThrowsError(try BackgroundUploadCompletionPolicy.receipt(from: record))
    }

    func testAudioUploadClientFactoryFallsBackToLocalClientWithoutBackendToken() {
        let client = AudioUploadClientFactory.client(
            configuration: BackendUploadConfiguration(
                baseURL: URL(string: "https://api.example.test")!,
                bearerToken: ""
            )
        )

        XCTAssertTrue(client is LocalAudioObjectUploadClient)
    }

    func testBackendConfigurationManagerResolvesConfiguredUploadClientSettings() throws {
        let settingsStore = InMemoryBackendSettingsStore()
        let credentialStore = InMemoryBackendCredentialStore()
        let manager = BackendConfigurationManager(
            settingsStore: settingsStore,
            credentialStore: credentialStore
        )

        try manager.save(
            settings: BackendConnectionSettings(
                baseURLString: "https://api.example.test",
                uploadPath: "custom/upload",
                workspaceID: "  workspace_alpha  ",
                isEnabled: true
            ),
            bearerToken: "  test-token  "
        )

        let configuration = try XCTUnwrap(try manager.resolvedUploadConfiguration())

        XCTAssertEqual(configuration.baseURL.absoluteString, "https://api.example.test")
        XCTAssertEqual(configuration.uploadPath, "/custom/upload")
        XCTAssertEqual(configuration.uploadURL.absoluteString, "https://api.example.test/custom/upload")
        XCTAssertEqual(configuration.bearerToken, "test-token")
        XCTAssertEqual(configuration.workspaceID, "workspace_alpha")
        XCTAssertEqual(try settingsStore.loadSettings().baseURLString, "https://api.example.test")
        XCTAssertEqual(try credentialStore.loadBearerToken(), "test-token")
    }

    func testBackendConnectionSettingsDecodeDefaultsSyncPathForOlderSettings() throws {
        let data = Data(#"{"baseURLString":"https://api.example.test","uploadPath":"/upload","isEnabled":true}"#.utf8)

        let settings = try JSONDecoder().decode(BackendConnectionSettings.self, from: data)

        XCTAssertEqual(settings.normalizedSyncPath, "/v1/workspace/snapshot")
        XCTAssertEqual(settings.normalizedObjectMetadataPath, "/v1/objects/metadata")
        XCTAssertEqual(settings.normalizedTranscriptionPath, "/v1/ai/transcriptions")
        XCTAssertEqual(settings.normalizedTranscriptionJobStatusPath, "/v1/ai/transcription-jobs")
        XCTAssertEqual(settings.normalizedWorkflowPath, "/v1/ai/workflows/run")
        XCTAssertEqual(settings.normalizedUsagePath, "/v1/usage/summary")
        XCTAssertEqual(settings.normalizedOperationsStatusPath, "/v1/admin/status")
        XCTAssertEqual(settings.normalizedBackupManifestPath, "/v1/admin/backup-manifest")
        XCTAssertEqual(settings.normalizedRestoreDrillPath, "/v1/admin/restore-drill")
        XCTAssertEqual(settings.normalizedPushRegistrationPath, "/v1/devices/apns")
        XCTAssertEqual(settings.normalizedWorkspaceID, "")
    }

    func testBackendConfigurationManagerResolvesSyncSettings() throws {
        let manager = BackendConfigurationManager(
            settingsStore: InMemoryBackendSettingsStore(
                settings: BackendConnectionSettings(
                    baseURLString: "https://api.example.test",
                    uploadPath: "/upload",
                    syncPath: "workspace/pull",
                    workspaceID: "workspace_alpha",
                    isEnabled: true
                )
            ),
            credentialStore: InMemoryBackendCredentialStore(token: "sync-token")
        )

        let configuration = try XCTUnwrap(try manager.resolvedSyncConfiguration())

        XCTAssertEqual(configuration.baseURL.absoluteString, "https://api.example.test")
        XCTAssertEqual(configuration.syncPath, "/workspace/pull")
        XCTAssertEqual(configuration.syncURL(since: nil).absoluteString, "https://api.example.test/workspace/pull")
        XCTAssertEqual(configuration.bearerToken, "sync-token")
        XCTAssertEqual(configuration.workspaceID, "workspace_alpha")
    }

    func testBackendConfigurationManagerResolvesAISettings() throws {
        let manager = BackendConfigurationManager(
            settingsStore: InMemoryBackendSettingsStore(
                settings: BackendConnectionSettings(
                    baseURLString: "https://api.example.test",
                    objectMetadataPath: "objects/metadata",
                    transcriptionPath: "ai/transcribe",
                    transcriptionJobStatusPath: "ai/transcription-jobs",
                    workflowPath: "/ai/workflow",
                    workflowJobStatusPath: "ai/workflow-jobs",
                    workspaceID: "workspace_alpha",
                    isEnabled: true
                )
            ),
            credentialStore: InMemoryBackendCredentialStore(token: "ai-token")
        )

        let configuration = try XCTUnwrap(try manager.resolvedAIConfiguration())

        XCTAssertEqual(
            configuration.objectMetadataURL(objectKey: "audio/idea/rec.m4a").absoluteString,
            "https://api.example.test/objects/metadata?objectKey=audio/idea/rec.m4a"
        )
        XCTAssertEqual(configuration.transcriptionURL.absoluteString, "https://api.example.test/ai/transcribe")
        XCTAssertEqual(configuration.transcriptionJobStatusURL(jobID: "job_123").absoluteString, "https://api.example.test/ai/transcription-jobs/job_123")
        XCTAssertEqual(configuration.workflowURL.absoluteString, "https://api.example.test/ai/workflow")
        XCTAssertEqual(configuration.workflowJobStatusURL(jobID: "job_456").absoluteString, "https://api.example.test/ai/workflow-jobs/job_456")
        XCTAssertEqual(configuration.bearerToken, "ai-token")
        XCTAssertEqual(configuration.workspaceID, "workspace_alpha")
    }

    func testBackendConfigurationManagerResolvesAccountUsageSettings() throws {
        let manager = BackendConfigurationManager(
            settingsStore: InMemoryBackendSettingsStore(
                settings: BackendConnectionSettings(
                    baseURLString: "https://api.example.test",
                    authSessionPath: "auth/session",
                    usagePath: "account/usage",
                    billingReconciliationPath: "billing/reconcile",
                    operationsStatusPath: "admin/status",
                    backupManifestPath: "admin/backup",
                    restoreDrillPath: "admin/restore-drill",
                    operationsMetricsPath: "admin/metrics",
                    pushRegistrationPath: "devices/push",
                    workspaceID: "workspace_alpha",
                    isEnabled: true
                )
            ),
            credentialStore: InMemoryBackendCredentialStore(token: "account-token")
        )

        let authConfiguration = try XCTUnwrap(try manager.resolvedAuthConfiguration())
        XCTAssertEqual(authConfiguration.sessionPath, "/auth/session")
        XCTAssertEqual(authConfiguration.sessionURL.absoluteString, "https://api.example.test/auth/session")
        XCTAssertEqual(authConfiguration.bearerToken, "account-token")
        XCTAssertEqual(authConfiguration.workspaceID, "workspace_alpha")

        let configuration = try XCTUnwrap(try manager.resolvedAccountConfiguration())

        XCTAssertEqual(configuration.usagePath, "/account/usage")
        XCTAssertEqual(configuration.usageURL.absoluteString, "https://api.example.test/account/usage")
        XCTAssertEqual(configuration.bearerToken, "account-token")
        XCTAssertEqual(configuration.workspaceID, "workspace_alpha")

        let billingConfiguration = try XCTUnwrap(try manager.resolvedBillingReconciliationConfiguration())
        XCTAssertEqual(billingConfiguration.reconciliationPath, "/billing/reconcile")
        XCTAssertEqual(billingConfiguration.reconciliationURL.absoluteString, "https://api.example.test/billing/reconcile")
        XCTAssertEqual(billingConfiguration.bearerToken, "account-token")
        XCTAssertEqual(billingConfiguration.workspaceID, "workspace_alpha")

        let operationsConfiguration = try XCTUnwrap(try manager.resolvedOperationsConfiguration())
        XCTAssertEqual(operationsConfiguration.statusPath, "/admin/status")
        XCTAssertEqual(operationsConfiguration.statusURL.absoluteString, "https://api.example.test/admin/status")
        XCTAssertEqual(operationsConfiguration.backupManifestPath, "/admin/backup")
        XCTAssertEqual(operationsConfiguration.backupManifestURL.absoluteString, "https://api.example.test/admin/backup")
        XCTAssertEqual(operationsConfiguration.restoreDrillPath, "/admin/restore-drill")
        XCTAssertEqual(operationsConfiguration.restoreDrillURL.absoluteString, "https://api.example.test/admin/restore-drill")
        XCTAssertEqual(operationsConfiguration.metricsPath, "/admin/metrics")
        XCTAssertEqual(operationsConfiguration.metricsURL.absoluteString, "https://api.example.test/admin/metrics")
        XCTAssertEqual(operationsConfiguration.bearerToken, "account-token")
        XCTAssertEqual(operationsConfiguration.workspaceID, "workspace_alpha")

        let pushConfiguration = try XCTUnwrap(try manager.resolvedPushRegistrationConfiguration())
        XCTAssertEqual(pushConfiguration.registrationPath, "/devices/push")
        XCTAssertEqual(pushConfiguration.registrationURL.absoluteString, "https://api.example.test/devices/push")
        XCTAssertEqual(pushConfiguration.bearerToken, "account-token")
        XCTAssertEqual(pushConfiguration.workspaceID, "workspace_alpha")
    }

    func testBackendConfigurationManagerRequiresWorkspaceIDWhenEnabled() throws {
        let manager = BackendConfigurationManager(
            settingsStore: InMemoryBackendSettingsStore(
                settings: BackendConnectionSettings(
                    baseURLString: "https://api.example.test",
                    workspaceID: "   ",
                    isEnabled: true
                )
            ),
            credentialStore: InMemoryBackendCredentialStore(token: "test-token")
        )

        XCTAssertNil(try manager.resolvedUploadConfiguration())
        XCTAssertNil(try manager.resolvedSyncConfiguration())
        XCTAssertNil(try manager.resolvedAIConfiguration())
        XCTAssertNil(try manager.resolvedAuthConfiguration())
        XCTAssertNil(try manager.resolvedAccountConfiguration())
        XCTAssertNil(try manager.resolvedBillingReconciliationConfiguration())
        XCTAssertNil(try manager.resolvedOperationsConfiguration())
        XCTAssertNil(try manager.resolvedPushRegistrationConfiguration())
    }

    func testBackendAIServiceFactoryHonorsConfigurationAndPrivacyMode() {
        let configuration = BackendAIConfiguration(
            baseURL: URL(string: "https://api.example.test")!,
            bearerToken: "ai-token",
            workspaceID: "workspace_alpha"
        )

        let cloudServices = BackendAIServiceFactory.services(
            configuration: configuration,
            privacyMode: .standardCloud
        )
        let privateServices = BackendAIServiceFactory.services(
            configuration: configuration,
            privacyMode: .privateLocal
        )
        let missingConfigurationServices = BackendAIServiceFactory.services(
            configuration: nil,
            privacyMode: .standardCloud
        )

        XCTAssertTrue(cloudServices.transcription is BackendTranscriptionService)
        XCTAssertTrue(cloudServices.workflow is BackendWorkflowExecutionService)
        XCTAssertTrue(privateServices.transcription is LocalTranscriptionService)
        XCTAssertTrue(privateServices.workflow is LocalWorkflowExecutionService)
        XCTAssertTrue(missingConfigurationServices.transcription is LocalTranscriptionService)
        XCTAssertTrue(missingConfigurationServices.workflow is LocalWorkflowExecutionService)
    }

    func testLocalSpeechTranscriptionServiceFailsClosedWithoutLocalAudio() async throws {
        let service = LocalSpeechTranscriptionService(
            authorizer: StubSpeechAuthorizationClient(status: .authorized),
            transcriber: StubSpeechAudioTranscriber(text: "Recognized idea")
        )
        let recording = speechTestRecording(localAudioPath: nil)

        do {
            _ = try await service.transcript(for: recording, hint: "Do not use this hint")
            XCTFail("Expected missing local audio to fail closed.")
        } catch let error as LocalSpeechTranscriptionError {
            XCTAssertEqual(error, .missingLocalAudio)
            XCTAssertEqual(
                error.userFacingMessage,
                "Local speech transcription needs the original audio file on this device."
            )
        }
    }

    func testLocalSpeechTranscriptionServiceRequiresSpeechAuthorization() async throws {
        let audioURL = try makeTemporarySpeechAudioFile()
        let service = LocalSpeechTranscriptionService(
            authorizer: StubSpeechAuthorizationClient(status: .denied),
            transcriber: StubSpeechAudioTranscriber(text: "Recognized idea")
        )
        let recording = speechTestRecording(localAudioPath: audioURL.path)

        do {
            _ = try await service.transcript(for: recording, hint: "")
            XCTFail("Expected denied speech authorization to fail closed.")
        } catch let error as LocalSpeechTranscriptionError {
            XCTAssertEqual(error, .authorizationDenied(.denied))
            XCTAssertEqual(
                error.userFacingMessage,
                "Speech recognition is not available. Enable speech recognition access and retry."
            )
        }
    }

    func testLocalSpeechTranscriptionServiceBuildsTranscriptFromRecognizedAudio() async throws {
        let audioURL = try makeTemporarySpeechAudioFile()
        let service = LocalSpeechTranscriptionService(
            authorizer: StubSpeechAuthorizationClient(status: .authorized),
            transcriber: StubSpeechAudioTranscriber(text: "  Build an offline-first watch capture inbox.  ")
        )
        let recording = speechTestRecording(
            localAudioPath: audioURL.path,
            durationSeconds: 42,
            markerOffsets: [12],
            languageHint: "en-US"
        )

        let transcript = try await service.transcript(for: recording, hint: "Placeholder hint must not leak")

        XCTAssertEqual(transcript.cleanText, "Build an offline-first watch capture inbox.")
        XCTAssertEqual(transcript.segments.count, 1)
        XCTAssertEqual(transcript.segments[0].id, "segment_rec_speech_test")
        XCTAssertEqual(transcript.segments[0].endSeconds, 42)
        XCTAssertTrue(transcript.segments[0].isMarkedImportant)
        XCTAssertEqual(transcript.unclearFragments, [])
    }

    func testLocalSpeechTranscriptionServiceRejectsEmptyRecognition() async throws {
        let audioURL = try makeTemporarySpeechAudioFile()
        let service = LocalSpeechTranscriptionService(
            authorizer: StubSpeechAuthorizationClient(status: .authorized),
            transcriber: StubSpeechAudioTranscriber(text: " \n ")
        )
        let recording = speechTestRecording(localAudioPath: audioURL.path)

        do {
            _ = try await service.transcript(for: recording, hint: "Do not use this hint")
            XCTFail("Expected empty speech recognition result to fail closed.")
        } catch let error as LocalSpeechTranscriptionError {
            XCTAssertEqual(error, .emptyRecognition)
        }
    }

    func testLocalSpeechTranscriptionServiceTimesOutUnfinishedRecognition() async throws {
        let audioURL = try makeTemporarySpeechAudioFile()
        let service = LocalSpeechTranscriptionService(
            authorizer: StubSpeechAuthorizationClient(status: .authorized),
            transcriber: NeverReturningSpeechAudioTranscriber(),
            recognitionTimeoutSeconds: 0
        )
        let recording = speechTestRecording(localAudioPath: audioURL.path)

        do {
            _ = try await service.transcript(for: recording, hint: "")
            XCTFail("Expected unfinished speech recognition to time out.")
        } catch let error as LocalSpeechTranscriptionError {
            XCTAssertEqual(error, .recognitionTimedOut)
            XCTAssertEqual(
                error.userFacingMessage,
                "Speech recognition took too long. Try again with a shorter recording or use cloud transcription."
            )
        }
    }

    func testBackendAIServiceFactoryDeniesExhaustedAccountEntitlements() async throws {
        let configuration = BackendAIConfiguration(
            baseURL: URL(string: "https://api.example.test")!,
            bearerToken: "ai-token",
            workspaceID: "workspace_alpha"
        )
        let accountUsage = BackendAccountUsageSummary(
            account: BackendAccountSummary(id: "acct_test", planName: "Pro", planStatus: .active),
            workspaceID: "workspace_alpha",
            usage: [],
            entitlements: [
                BackendUsageEntitlement(
                    metric: BackendEntitlementMetric.transcriptionSeconds,
                    includedQuantity: 60,
                    usedQuantity: 60,
                    remainingQuantity: 0
                ),
                BackendUsageEntitlement(
                    metric: BackendEntitlementMetric.workflowRuns,
                    includedQuantity: 1,
                    usedQuantity: 1,
                    remainingQuantity: 0
                )
            ]
        )
        let services = BackendAIServiceFactory.services(
            configuration: configuration,
            privacyMode: .standardCloud,
            accountUsageSummary: accountUsage
        )
        let recording = Recording(
            id: "rec_exhausted",
            ideaProjectID: "idea_exhausted",
            deviceName: "iPhone",
            durationSeconds: 30,
            localFileStatus: .uploaded,
            syncStatus: .uploaded,
            audioObjectKey: "audio/idea_exhausted/rec_exhausted.m4a",
            languageHint: "en",
            createdAt: SampleData.now,
            markerOffsets: []
        )

        do {
            _ = try await services.transcription.transcript(for: recording, hint: "")
            XCTFail("Expected exhausted transcription entitlement to deny backend transcription.")
        } catch BackendAIError.entitlementUnavailable(let denial) {
            XCTAssertEqual(denial.metric, BackendEntitlementMetric.transcriptionSeconds)
            XCTAssertEqual(denial.reason, .exhausted)
        }

        do {
            _ = try await services.workflow.run(
                template: DefaultWorkflows.templates[0],
                project: SampleData.ideaForgeProject
            )
            XCTFail("Expected exhausted workflow entitlement to deny backend workflow execution.")
        } catch BackendAIError.entitlementUnavailable(let denial) {
            XCTAssertEqual(denial.metric, BackendEntitlementMetric.workflowRuns)
            XCTAssertEqual(denial.reason, .exhausted)
        }
    }

    func testAccountPortalReadinessRequiresBackendAccount() {
        let readiness = AccountPortalReadiness.evaluate(
            summary: nil,
            session: nil,
            expectedWorkspaceID: "workspace_alpha"
        )

        XCTAssertFalse(readiness.canOpenPortal)
        XCTAssertEqual(readiness.actionLabel, "View Plans")
        XCTAssertEqual(readiness.planLabel, "Not loaded")
        XCTAssertEqual(readiness.blockers, ["Backend account not loaded."])
        XCTAssertEqual(readiness.blockerText, "Backend account not loaded.")
    }

    func testAccountPortalReadinessRequiresValidatedSessionForSummaryWorkspace() {
        let summary = accountPortalSummary()

        let readiness = AccountPortalReadiness.evaluate(
            summary: summary,
            session: nil,
            expectedWorkspaceID: "workspace_alpha"
        )

        XCTAssertFalse(readiness.canOpenPortal)
        XCTAssertEqual(readiness.planLabel, "Pro (Active)")
        XCTAssertEqual(readiness.blockers, ["Validate backend session before using this backend action."])
    }

    func testAccountPortalReadinessRejectsMismatchedSessionWorkspace() {
        let summary = accountPortalSummary()
        let session = accountPortalSession(workspaceID: "workspace_beta")

        let readiness = AccountPortalReadiness.evaluate(
            summary: summary,
            session: session,
            expectedWorkspaceID: "workspace_alpha"
        )

        XCTAssertFalse(readiness.canOpenPortal)
        XCTAssertEqual(readiness.blockers, ["Validated session belongs to a different workspace."])
    }

    func testAccountPortalReadinessRejectsSummaryFromDifferentConfiguredWorkspace() {
        var summary = accountPortalSummary()
        summary.workspaceID = "workspace_beta"

        let readiness = AccountPortalReadiness.evaluate(
            summary: summary,
            session: accountPortalSession(),
            expectedWorkspaceID: "workspace_alpha"
        )

        XCTAssertFalse(readiness.canOpenPortal)
        XCTAssertEqual(readiness.blockers, ["Backend account belongs to a different workspace."])
    }

    func testAccountPortalReadinessRequiresManageAccountCapability() {
        let summary = accountPortalSummary()
        let session = accountPortalSession(capabilities: [.syncWorkspace])

        let readiness = AccountPortalReadiness.evaluate(
            summary: summary,
            session: session,
            expectedWorkspaceID: "workspace_alpha"
        )

        XCTAssertFalse(readiness.canOpenPortal)
        XCTAssertEqual(readiness.blockers, ["Backend session is missing capability: Manage account."])
    }

    func testAccountPortalReadinessRejectsNonHTTPSRemotePortal() {
        let summary = accountPortalSummary(
            portalURL: URL(string: "http://accounts.example.test/ideaforge")!
        )

        let readiness = AccountPortalReadiness.evaluate(
            summary: summary,
            session: accountPortalSession(),
            expectedWorkspaceID: "workspace_alpha"
        )

        XCTAssertFalse(readiness.canOpenPortal)
        XCTAssertEqual(readiness.blockers, ["Account portal must use HTTPS."])
    }

    func testAccountPortalReadinessAllowsLoopbackHTTPForLocalDevelopment() {
        for host in ["localhost", "127.0.0.1", "[::1]"] {
            let portalURL = try! XCTUnwrap(URL(string: "http://\(host):8080/account"))
            let readiness = AccountPortalReadiness.evaluate(
                summary: accountPortalSummary(portalURL: portalURL),
                session: accountPortalSession(),
                expectedWorkspaceID: "workspace_alpha"
            )

            XCTAssertTrue(readiness.canOpenPortal, "Expected exact loopback host \(host) to be allowed.")
            XCTAssertEqual(readiness.portalURL, portalURL)
            XCTAssertEqual(readiness.blockerText, "Ready")
        }
    }

    func testAccountPortalReadinessAllowsFreeAndActivePlansWithoutSubscriptionGate() {
        let freeSummary = accountPortalSummary(
            account: BackendAccountSummary(id: "acct_free", planName: "Free", planStatus: .canceled)
        )
        let activeSummary = accountPortalSummary(
            account: BackendAccountSummary(id: "acct_pro", planName: "Pro", planStatus: .active)
        )

        let freeReadiness = AccountPortalReadiness.evaluate(
            summary: freeSummary,
            session: accountPortalSession(account: freeSummary.account),
            expectedWorkspaceID: "workspace_alpha"
        )
        let activeReadiness = AccountPortalReadiness.evaluate(
            summary: activeSummary,
            session: accountPortalSession(account: activeSummary.account),
            expectedWorkspaceID: "workspace_alpha"
        )

        XCTAssertTrue(freeReadiness.canOpenPortal)
        XCTAssertEqual(freeReadiness.actionLabel, "View Plans")
        XCTAssertEqual(freeReadiness.planLabel, "Free (Canceled)")
        XCTAssertTrue(activeReadiness.canOpenPortal)
        XCTAssertEqual(activeReadiness.actionLabel, "Manage Plan")
        XCTAssertEqual(activeReadiness.planLabel, "Pro (Active)")
    }

    private func accountPortalSummary(
        account: BackendAccountSummary = BackendAccountSummary(
            id: "acct_pro",
            planName: "Pro",
            planStatus: .active
        ),
        portalURL: URL = URL(string: "https://accounts.example.test/ideaforge")!
    ) -> BackendAccountUsageSummary {
        BackendAccountUsageSummary(
            account: account,
            accountPortalURL: portalURL,
            workspaceID: "workspace_alpha",
            usage: [],
            entitlements: []
        )
    }

    private func accountPortalSession(
        workspaceID: String = "workspace_alpha",
        account: BackendAccountSummary = BackendAccountSummary(
            id: "acct_pro",
            planName: "Pro",
            planStatus: .active
        ),
        capabilities: [BackendAccountCapability] = [.manageAccount]
    ) -> BackendAuthenticatedSession {
        BackendAuthenticatedSession(
            userID: "user_portal",
            workspaceID: workspaceID,
            account: account,
            capabilities: capabilities
        )
    }

    func testCommerceReadinessFailsClosedWithoutBackendAccountOrStoreKitProducts() {
        let readiness = CommerceReadiness.evaluate(
            accountUsageSummary: nil,
            storeKitProducts: [],
            activeProductIDs: [],
            accountPortalURL: nil
        )

        XCTAssertFalse(readiness.canPurchase)
        XCTAssertEqual(readiness.purchaseBlockers, [.backendAccountMissing, .storeKitProductsMissing])
        XCTAssertFalse(readiness.canRestore)
        XCTAssertEqual(readiness.restoreBlockers, [.storeKitProductsMissing])
        XCTAssertFalse(readiness.canManageSubscription)
        XCTAssertEqual(readiness.manageSubscriptionBlockers, [.backendAccountMissing, .activeSubscriptionMissing, .subscriptionManagementUnavailable])
        XCTAssertFalse(readiness.canRequestAccountDeletion)
        XCTAssertEqual(readiness.accountDeletionBlockers, [.backendAccountMissing, .accountPortalMissing])
        XCTAssertEqual(readiness.planLabel, "Not loaded")
    }

    func testCommerceReadinessAllowsPurchaseRestoreManageAndDeletionWhenAccountIsReady() {
        let product = CommerceProduct(
            id: CommerceProductID.proMonthly,
            displayName: "IdeaForge Pro",
            priceLabel: "$9.99",
            billingPeriod: .monthly
        )
        let accountUsage = BackendAccountUsageSummary(
            account: BackendAccountSummary(id: "acct_test", planName: "Pro", planStatus: .active),
            workspaceID: "workspace_alpha",
            usage: [],
            entitlements: []
        )
        let accountPortalURL = URL(string: "https://accounts.example.test/ideaforge")!
        let accountDeletionURL = URL(string: "https://accounts.example.test/ideaforge/delete")!

        let readiness = CommerceReadiness.evaluate(
            accountUsageSummary: accountUsage,
            storeKitProducts: [product],
            activeProductIDs: [product.id],
            accountPortalURL: accountPortalURL,
            accountDeletionURL: accountDeletionURL,
            canOpenSubscriptionManagement: true
        )

        XCTAssertTrue(readiness.canPurchase)
        XCTAssertTrue(readiness.canRestore)
        XCTAssertTrue(readiness.canManageSubscription)
        XCTAssertTrue(readiness.canRequestAccountDeletion)
        XCTAssertEqual(readiness.products, [product])
        XCTAssertEqual(readiness.planLabel, "Pro (Active)")
        XCTAssertEqual(readiness.accountPortalURL, accountPortalURL)
        XCTAssertEqual(readiness.accountDeletionURL, accountDeletionURL)
    }

    func testCommerceReadinessRequiresExplicitAccountDeletionURL() {
        let product = CommerceProduct(
            id: CommerceProductID.proMonthly,
            displayName: "IdeaForge Pro",
            priceLabel: "$9.99",
            billingPeriod: .monthly
        )
        let accountUsage = BackendAccountUsageSummary(
            account: BackendAccountSummary(id: "acct_test", planName: "Pro", planStatus: .active),
            workspaceID: "workspace_alpha",
            usage: [],
            entitlements: []
        )

        let readiness = CommerceReadiness.evaluate(
            accountUsageSummary: accountUsage,
            storeKitProducts: [product],
            activeProductIDs: [product.id],
            accountPortalURL: URL(string: "https://accounts.example.test/ideaforge")!,
            accountDeletionURL: nil,
            canOpenSubscriptionManagement: true
        )

        XCTAssertFalse(readiness.canRequestAccountDeletion)
        XCTAssertEqual(readiness.accountDeletionBlockers, [.accountPortalMissing])
    }

    func testCommerceProductCatalogOrdersStoreKitProductsByConfiguredProductIDs() {
        let yearly = CommerceProduct(
            id: CommerceProductID.proYearly,
            displayName: "IdeaForge Pro Annual",
            priceLabel: "$79.99",
            billingPeriod: .yearly
        )
        let monthly = CommerceProduct(
            id: CommerceProductID.proMonthly,
            displayName: "IdeaForge Pro Monthly",
            priceLabel: "$9.99",
            billingPeriod: .monthly
        )
        let unknown = CommerceProduct(
            id: "com.s1kor.ideaforge.unknown",
            displayName: "Unknown",
            priceLabel: "$1.99",
            billingPeriod: .unknown
        )

        let ordered = CommerceProductCatalog.orderedProducts([unknown, yearly, monthly])

        XCTAssertEqual(ordered.map(\.id), [
            CommerceProductID.proMonthly,
            CommerceProductID.proYearly,
            "com.s1kor.ideaforge.unknown"
        ])
    }

    func testCommerceRestoreResultDeduplicatesActiveProductIDsInConfiguredOrder() {
        let result = CommerceRestoreResult(
            activeProductIDs: [
                CommerceProductID.proYearly,
                CommerceProductID.proMonthly,
                CommerceProductID.proYearly
            ]
        )

        XCTAssertEqual(result.activeProductIDs, [
            CommerceProductID.proMonthly,
            CommerceProductID.proYearly
        ])
        XCTAssertTrue(result.hasActiveSubscription)
    }

    func testCommerceFixtureServiceFiltersProductsAndTracksPurchasedEntitlement() async throws {
        let product = CommerceProduct(
            id: CommerceProductID.proMonthly,
            displayName: "IdeaForge Pro Monthly",
            priceLabel: "$9.99",
            billingPeriod: .monthly
        )
        let service = CommerceFixtureService(products: [product])

        let products = try await service.loadProducts(productIDs: [CommerceProductID.proMonthly])
        XCTAssertEqual(products, [product])

        let purchaseResult = try await service.purchase(productID: CommerceProductID.proMonthly)
        XCTAssertEqual(purchaseResult, .purchased(activeProductID: CommerceProductID.proMonthly))

        let restoreResult = try await service.restorePurchases(productIDs: CommerceProductID.all)
        XCTAssertEqual(restoreResult.activeProductIDs, [CommerceProductID.proMonthly])
    }

    func testBackendConfigurationManagerReturnsNilWhenRemoteUploadDisabled() throws {
        let manager = BackendConfigurationManager(
            settingsStore: InMemoryBackendSettingsStore(
                settings: BackendConnectionSettings(
                    baseURLString: "https://api.example.test",
                    isEnabled: false
                )
            ),
            credentialStore: InMemoryBackendCredentialStore(token: "test-token")
        )

        XCTAssertNil(try manager.resolvedUploadConfiguration())
    }

    func testBackendConfigurationManagerRejectsEnabledInvalidBaseURL() throws {
        let manager = BackendConfigurationManager(
            settingsStore: InMemoryBackendSettingsStore(
                settings: BackendConnectionSettings(
                    baseURLString: "api.example.test",
                    isEnabled: true
                )
            ),
            credentialStore: InMemoryBackendCredentialStore(token: "test-token")
        )

        XCTAssertThrowsError(try manager.resolvedUploadConfiguration()) { error in
            XCTAssertEqual(error as? BackendConfigurationError, .invalidBaseURL("api.example.test"))
        }
    }

    func testBackendConfigurationRejectsPlaintextRemoteHostButAllowsLoopbackDevelopment() throws {
        let remoteSettings = BackendConnectionSettings(
            baseURLString: "http://api.example.test",
            workspaceID: "workspace_prod",
            isEnabled: true
        )
        let loopbackSettings = BackendConnectionSettings(
            baseURLString: "http://127.0.0.1:8765",
            workspaceID: "workspace_local",
            isEnabled: true
        )

        XCTAssertFalse(remoteSettings.hasValidBaseURL)
        XCTAssertTrue(loopbackSettings.hasValidBaseURL)

        let remoteManager = BackendConfigurationManager(
            settingsStore: InMemoryBackendSettingsStore(settings: remoteSettings),
            credentialStore: InMemoryBackendCredentialStore(token: "test-token")
        )
        XCTAssertThrowsError(try remoteManager.resolvedUploadConfiguration()) { error in
            XCTAssertEqual(
                error as? BackendConfigurationError,
                .invalidBaseURL("http://api.example.test")
            )
        }
    }

    func testIntegrationSettingsReportMissingScopesAndActionApproval() {
        var settings = IntegrationSettings.defaults
        settings.update(
            IntegrationProviderSettings(
                provider: .github,
                isEnabled: true,
                displayName: "IdeaForge Repo",
                approvedScopes: ["repo:read"],
                credentialStatus: .configured
            )
        )

        let missingScopeReport = settings.readinessReport()
        let githubMissingScope = missingScopeReport.item(for: .github)

        XCTAssertEqual(githubMissingScope?.status, .missingScopes)
        XCTAssertEqual(githubMissingScope?.settings.missingScopes, ["issues:write"])
        XCTAssertEqual(missingScopeReport.blockerCount, 1)

        settings.update(
            IntegrationProviderSettings(
                provider: .github,
                isEnabled: true,
                displayName: "IdeaForge Repo",
                approvedScopes: ["repo:read", "issues:write"],
                credentialStatus: .configured,
                allowsExternalActions: false
            )
        )

        let approvalReport = settings.readinessReport()
        let gate = settings.actionGate(provider: .github, action: .remoteWrite)

        XCTAssertEqual(approvalReport.item(for: .github)?.status, .approvalRequired)
        XCTAssertFalse(gate.isAllowed)
        XCTAssertEqual(gate.reason, "External actions require explicit operator approval.")
    }

    func testIntegrationSettingsCanFailClosedOrAllowReviewedCodexLauncherActions() {
        var settings = IntegrationSettings.defaults
        settings.update(
            IntegrationProviderSettings(
                provider: .codexLauncher,
                isEnabled: true,
                credentialStatus: .configured,
                allowsExternalActions: false
            )
        )

        let blockedGate = settings.actionGate(provider: .codexLauncher, action: .codexLaunch)

        XCTAssertFalse(blockedGate.isAllowed)
        XCTAssertEqual(settings.readinessReport().item(for: .codexLauncher)?.status, .approvalRequired)

        settings.update(
            IntegrationProviderSettings(
                provider: .codexLauncher,
                isEnabled: true,
                credentialStatus: .configured,
                allowsExternalActions: true
            )
        )

        let allowedGate = settings.actionGate(provider: .codexLauncher, action: .codexLaunch)

        XCTAssertTrue(allowedGate.isAllowed)
        XCTAssertEqual(settings.readinessReport().item(for: .codexLauncher)?.status, .readyForReviewedAction)
    }

    func testIntegrationSettingsDecodeBackfillsDefaultProviders() throws {
        let data = Data(
            #"""
            {
              "providerSettings": [
                {
                  "provider": "github",
                  "isEnabled": true,
                  "displayName": "IdeaForge Repo",
                  "requiredScopes": ["repo:read", "issues:write"],
                  "approvedScopes": ["repo:read", "issues:write"],
                  "credentialStatus": "configured",
                  "allowsExternalActions": false
                }
              ]
            }
            """#.utf8
        )

        let decoded = try JSONDecoder().decode(IntegrationSettings.self, from: data)

        XCTAssertEqual(decoded.providerSettings.count, IntegrationProvider.allCases.count)
        XCTAssertTrue(decoded.settings(for: .github).isEnabled)
        XCTAssertEqual(decoded.settings(for: .codexLauncher).credentialStatus, .configured)
        XCTAssertFalse(decoded.settings(for: .notion).isEnabled)
    }

    func testUploadSchedulePolicyReturnsDueOrFutureRunDate() {
        let now = Date(timeIntervalSince1970: 1_000)
        let due = UploadJob(
            id: "upload_due",
            recordingID: "rec_due",
            ideaProjectID: "idea_due",
            localAudioPath: "recordings/due.m4a",
            status: .queued,
            attemptCount: 0,
            nextAttemptAt: now.addingTimeInterval(-30),
            createdAt: now,
            updatedAt: now
        )
        let future = UploadJob(
            id: "upload_future",
            recordingID: "rec_future",
            ideaProjectID: "idea_future",
            localAudioPath: "recordings/future.m4a",
            status: .waitingForRetry,
            attemptCount: 1,
            nextAttemptAt: now.addingTimeInterval(120),
            createdAt: now,
            updatedAt: now
        )

        XCTAssertEqual(UploadSchedulePolicy.nextRunDate(for: [future], now: now), now.addingTimeInterval(120))
        XCTAssertEqual(UploadSchedulePolicy.nextRunDate(for: [future, due], now: now), now)
        XCTAssertNil(UploadSchedulePolicy.nextRunDate(for: []))
    }

    func testBackendWorkspaceSyncClientRequestsSnapshotAndDecodesState() async throws {
        var remoteState = WorkspaceState.seed()
        remoteState.updatedAt = Date(timeIntervalSince1970: 1_000)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let transport = CapturingHTTPRequestTransport(
            responseData: try encoder.encode(remoteState),
            statusCode: 200
        )
        let client = BackendWorkspaceSyncClient(
            configuration: BackendSyncConfiguration(
                baseURL: URL(string: "https://api.example.test")!,
                bearerToken: "sync-token",
                workspaceID: "workspace_alpha",
                syncPath: "/workspace/snapshot"
            ),
            transport: transport
        )
        let since = Date(timeIntervalSince1970: 100)

        let snapshot = try await client.fetchWorkspaceSnapshot(since: since)
        let capturedRequest = await transport.capturedRequest()

        XCTAssertEqual(snapshot.projects.map(\.id), remoteState.projects.map(\.id))
        XCTAssertEqual(snapshot.selectedProjectID, remoteState.selectedProjectID)
        XCTAssertEqual(snapshot.updatedAt, remoteState.updatedAt)
        XCTAssertEqual(capturedRequest?.httpMethod, "GET")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer sync-token")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "X-IdeaForge-Workspace-ID"), "workspace_alpha")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(capturedRequest?.url?.host, "api.example.test")
        XCTAssertEqual(capturedRequest?.url?.path, "/workspace/snapshot")
        XCTAssertNotNil(URLComponents(url: try XCTUnwrap(capturedRequest?.url), resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "since" })
    }

    func testBackendWorkspaceSyncClientPublishesScopedSnapshotWithRevisionBase() async throws {
        var localState = WorkspaceState.seed()
        localState.updatedAt = Date(timeIntervalSince1970: 2_000)
        let baseRemoteUpdatedAt = Date(timeIntervalSince1970: 1_500)
        localState.syncHealth.lastRemoteWorkspaceUpdatedAt = baseRemoteUpdatedAt
        localState.syncHealth.lastPublishedLocalUpdatedAt = Date(timeIntervalSince1970: 1_400)
        let receipt = WorkspaceSyncPushReceipt(
            workspaceID: "workspace_alpha",
            acceptedUpdatedAt: localState.updatedAt
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let transport = CapturingHTTPRequestTransport(
            responseData: try encoder.encode(receipt),
            statusCode: 200
        )
        let client = BackendWorkspaceSyncClient(
            configuration: BackendSyncConfiguration(
                baseURL: URL(string: "https://api.example.test")!,
                bearerToken: "sync-token",
                workspaceID: "workspace_alpha",
                syncPath: "/workspace/snapshot"
            ),
            transport: transport
        )

        let published = try await client.pushWorkspaceSnapshot(
            localState,
            baseRemoteUpdatedAt: baseRemoteUpdatedAt
        )
        let capturedRequest = await transport.capturedRequest()
        let maybeCapturedBody = await transport.capturedBody()
        let capturedBody = try XCTUnwrap(maybeCapturedBody)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decodedBody = try decoder.decode(WorkspaceState.self, from: capturedBody)

        XCTAssertEqual(published, receipt)
        XCTAssertEqual(capturedRequest?.httpMethod, "PUT")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer sync-token")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "X-IdeaForge-Workspace-ID"), "workspace_alpha")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "X-IdeaForge-Base-Remote-Updated-At"), "1970-01-01T00:25:00Z")
        XCTAssertEqual(capturedRequest?.url?.path, "/workspace/snapshot")
        XCTAssertEqual(decodedBody.updatedAt, localState.updatedAt)
        XCTAssertEqual(decodedBody.projects.map(\.id), localState.projects.map(\.id))
        XCTAssertNil(decodedBody.syncHealth.lastRemoteWorkspaceUpdatedAt)
        XCTAssertNil(decodedBody.syncHealth.lastPublishedLocalUpdatedAt)
        XCTAssertEqual(decodedBody.syncHealth.lastSuccessfulSync, .distantPast)
    }

    func testBackendAccountUsageClientRequestsScopedSummaryAndDecodesEntitlements() async throws {
        let response = Data(
            """
            {
              "account": {
                "id": "acct_local_dev",
                "planName": "Pro",
                "planStatus": "active"
              },
              "accountPortalURL": "https://accounts.example.test/portal",
              "accountDeletionURL": "https://accounts.example.test/delete",
              "workspaceID": "workspace_alpha",
              "usage": [
                {"metric": "transcription_seconds", "quantity": 120.0},
                {"metric": "workflow_runs", "quantity": 3.0}
              ],
              "entitlements": [
                {
                  "metric": "transcription_seconds",
                  "includedQuantity": 1800.0,
                  "usedQuantity": 120.0,
                  "remainingQuantity": 1680.0
                }
              ]
            }
            """.utf8
        )
        let transport = CapturingHTTPRequestTransport(
            responseData: response,
            statusCode: 200
        )
        let client = BackendAccountUsageClient(
            configuration: BackendAccountConfiguration(
                baseURL: URL(string: "https://api.example.test")!,
                bearerToken: "account-token",
                workspaceID: "workspace_alpha",
                usagePath: "/account/usage"
            ),
            transport: transport
        )

        let summary = try await client.fetchUsageSummary()
        let capturedRequest = await transport.capturedRequest()

        XCTAssertEqual(summary.account.id, "acct_local_dev")
        XCTAssertEqual(summary.account.planName, "Pro")
        XCTAssertEqual(summary.account.planStatus, .active)
        XCTAssertEqual(summary.accountPortalURL?.absoluteString, "https://accounts.example.test/portal")
        XCTAssertEqual(summary.accountDeletionURL?.absoluteString, "https://accounts.example.test/delete")
        XCTAssertEqual(summary.workspaceID, "workspace_alpha")
        XCTAssertEqual(summary.quantity(for: "workflow_runs"), 3.0)
        XCTAssertEqual(summary.entitlement(for: "transcription_seconds")?.remainingQuantity, 1680.0)
        XCTAssertEqual(capturedRequest?.httpMethod, "GET")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer account-token")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "X-IdeaForge-Workspace-ID"), "workspace_alpha")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(capturedRequest?.url?.absoluteString, "https://api.example.test/account/usage")
    }

    func testBackendAuthSessionClientValidatesScopedSessionAndDecodesCapabilities() async throws {
        let response = Data(
            """
            {
              "userID": "user_local_dev",
              "email": "builder@example.test",
              "workspaceID": "workspace_alpha",
              "account": {
                "id": "acct_local_dev",
                "planName": "Pro",
                "planStatus": "active"
              },
              "capabilities": [
                "upload_recordings",
                "sync_workspace",
                "run_ai_workflows",
                "reconcile_billing",
                "manage_account",
                "register_push_notifications"
              ],
              "accountPortalURL": "https://accounts.example.test/portal",
              "accountDeletionURL": "https://accounts.example.test/delete"
            }
            """.utf8
        )
        let transport = CapturingHTTPRequestTransport(
            responseData: response,
            statusCode: 200
        )
        let client = BackendAuthSessionClient(
            configuration: BackendAuthConfiguration(
                baseURL: URL(string: "https://api.example.test")!,
                bearerToken: "session-token",
                workspaceID: "workspace_alpha",
                sessionPath: "/auth/session"
            ),
            transport: transport
        )

        let session = try await client.validateSession()
        let capturedRequest = await transport.capturedRequest()

        XCTAssertEqual(session.userID, "user_local_dev")
        XCTAssertEqual(session.email, "builder@example.test")
        XCTAssertEqual(session.workspaceID, "workspace_alpha")
        XCTAssertEqual(session.account.id, "acct_local_dev")
        XCTAssertTrue(session.hasCapability(.uploadRecordings))
        XCTAssertTrue(session.hasCapability(.syncWorkspace))
        XCTAssertTrue(session.hasCapability(.runAIWorkflows))
        XCTAssertTrue(session.hasCapability(.reconcileBilling))
        XCTAssertTrue(session.hasCapability(.manageAccount))
        XCTAssertTrue(session.hasCapability(.registerPushNotifications))
        XCTAssertEqual(session.accountPortalURL?.absoluteString, "https://accounts.example.test/portal")
        XCTAssertEqual(session.accountDeletionURL?.absoluteString, "https://accounts.example.test/delete")
        XCTAssertEqual(capturedRequest?.httpMethod, "GET")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer session-token")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "X-IdeaForge-Workspace-ID"), "workspace_alpha")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(capturedRequest?.url?.absoluteString, "https://api.example.test/auth/session")
    }

    func testBackendPushRegistrationClientPostsScopedAPNSToken() async throws {
        let receipt = BackendPushDeviceRegistrationReceipt(
            workspaceID: "workspace_alpha",
            deviceID: "apns_abc123",
            tokenFingerprint: "abc123",
            environment: .sandbox,
            platform: .iOS,
            enabledTopics: [.workspaceSync, .recordingProcessing],
            registeredAt: "2026-07-02T00:00:00Z"
        )
        let transport = CapturingHTTPRequestTransport(
            responseData: try JSONEncoder().encode(receipt),
            statusCode: 200
        )
        let client = BackendPushRegistrationClient(
            configuration: BackendPushRegistrationConfiguration(
                baseURL: URL(string: "https://api.example.test")!,
                bearerToken: "push-token",
                workspaceID: "workspace_alpha",
                registrationPath: "/devices/apns"
            ),
            transport: transport
        )

        let result = try await client.registerDevice(
            BackendPushDeviceRegistrationRequest(
                apnsDeviceToken: try BackendAPNSDeviceToken(
                    hexString: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
                ),
                environment: .sandbox,
                platform: .iOS,
                bundleID: "com.s1kor.ideaforge.ios",
                appVersion: "1.0",
                topics: [.workspaceSync, .recordingProcessing]
            )
        )
        let maybeCapturedRequest = await transport.capturedRequest()
        let capturedRequest = try XCTUnwrap(maybeCapturedRequest)
        let maybeCapturedBody = await transport.capturedBody()
        let capturedBody = try XCTUnwrap(maybeCapturedBody)
        let payload = try JSONSerialization.jsonObject(with: capturedBody) as? [String: Any]

        XCTAssertEqual(result.deviceID, "apns_abc123")
        XCTAssertEqual(capturedRequest.httpMethod, "POST")
        XCTAssertEqual(capturedRequest.value(forHTTPHeaderField: "Authorization"), "Bearer push-token")
        XCTAssertEqual(capturedRequest.value(forHTTPHeaderField: "X-IdeaForge-Workspace-ID"), "workspace_alpha")
        XCTAssertEqual(capturedRequest.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(capturedRequest.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(capturedRequest.url?.absoluteString, "https://api.example.test/devices/apns")
        XCTAssertEqual(payload?["apnsDeviceToken"] as? String, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
        XCTAssertEqual(payload?["environment"] as? String, "sandbox")
        XCTAssertEqual(payload?["platform"] as? String, "ios")
        XCTAssertEqual(payload?["bundleID"] as? String, "com.s1kor.ideaforge.ios")
        XCTAssertEqual(payload?["appVersion"] as? String, "1.0")
        XCTAssertEqual(payload?["topics"] as? [String], ["workspace_sync", "recording_processing"])
    }

    func testConfiguredPushRegistrationProcessorValidatesCapabilityBeforeRegistering() async throws {
        let encoder = JSONEncoder()
        let session = BackendAuthenticatedSession(
            userID: "user_push",
            workspaceID: "workspace_alpha",
            account: BackendAccountSummary(id: "acct_push", planName: "Pro", planStatus: .active),
            capabilities: [.syncWorkspace, .registerPushNotifications]
        )
        let receipt = BackendPushDeviceRegistrationReceipt(
            workspaceID: "workspace_alpha",
            deviceID: "apns_push",
            tokenFingerprint: "pushfingerprint",
            environment: .sandbox,
            platform: .iOS,
            enabledTopics: [.workspaceSync],
            registeredAt: "2026-07-02T00:00:00Z"
        )
        let transport = SequencedHTTPRequestTransport(responses: [
            HTTPTestResponse(data: try encoder.encode(session), statusCode: 200),
            HTTPTestResponse(data: try encoder.encode(receipt), statusCode: 200)
        ])
        let manager = BackendConfigurationManager(
            settingsStore: InMemoryBackendSettingsStore(
                settings: BackendConnectionSettings(
                    baseURLString: "https://api.example.test",
                    authSessionPath: "/auth/session",
                    pushRegistrationPath: "/devices/apns",
                    workspaceID: "workspace_alpha",
                    isEnabled: true
                )
            ),
            credentialStore: InMemoryBackendCredentialStore(token: "push-token")
        )
        let processor = ConfiguredPushNotificationRegistrationProcessor(
            backendConfigurationManager: manager,
            authTransport: transport,
            registrationTransport: transport
        )

        let result = await processor.registerDevice(
            BackendPushDeviceRegistrationRequest(
                apnsDeviceToken: try BackendAPNSDeviceToken(
                    hexString: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
                ),
                environment: .sandbox,
                platform: .iOS,
                bundleID: "com.s1kor.ideaforge.ios",
                appVersion: "1.0",
                topics: [.workspaceSync]
            )
        )
        let requests = await transport.capturedRequests()

        XCTAssertEqual(result, .registered(receipt))
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST"])
        XCTAssertEqual(requests[0].url?.absoluteString, "https://api.example.test/auth/session")
        XCTAssertEqual(requests[1].url?.absoluteString, "https://api.example.test/devices/apns")
    }

    func testConfiguredPushRegistrationProcessorBlocksMissingCapabilityBeforeTokenUpload() async throws {
        let encoder = JSONEncoder()
        let session = BackendAuthenticatedSession(
            userID: "user_push",
            workspaceID: "workspace_alpha",
            account: BackendAccountSummary(id: "acct_push", planName: "Pro", planStatus: .active),
            capabilities: [.syncWorkspace]
        )
        let transport = SequencedHTTPRequestTransport(responses: [
            HTTPTestResponse(data: try encoder.encode(session), statusCode: 200)
        ])
        let manager = BackendConfigurationManager(
            settingsStore: InMemoryBackendSettingsStore(
                settings: BackendConnectionSettings(
                    baseURLString: "https://api.example.test",
                    workspaceID: "workspace_alpha",
                    isEnabled: true
                )
            ),
            credentialStore: InMemoryBackendCredentialStore(token: "push-token")
        )
        let processor = ConfiguredPushNotificationRegistrationProcessor(
            backendConfigurationManager: manager,
            authTransport: transport,
            registrationTransport: transport
        )

        let result = await processor.registerDevice(
            BackendPushDeviceRegistrationRequest(
                apnsDeviceToken: try BackendAPNSDeviceToken(
                    hexString: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
                ),
                environment: .sandbox,
                platform: .iOS,
                bundleID: "com.s1kor.ideaforge.ios",
                appVersion: "1.0",
                topics: [.workspaceSync]
            )
        )
        let requests = await transport.capturedRequests()

        XCTAssertEqual(
            result,
            .skipped(.capabilityGate, "Backend session is missing capability: Register push notifications.")
        )
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpMethod, "GET")
    }

    func testRemotePushNotificationParserAcceptsSilentWorkspaceSyncPayload() throws {
        let decision = RemotePushNotificationPayloadParser.parse(userInfo: [
            "aps": ["content-available": 1],
            "ideaforge": [
                "workspaceID": "workspace_alpha",
                "topics": ["workspace_sync", "recording_processing"],
                "remoteUpdatedAt": "2026-07-02T06:30:00Z"
            ]
        ])

        guard case .accepted(let trigger) = decision else {
            return XCTFail("Expected accepted remote push trigger")
        }
        XCTAssertEqual(trigger.workspaceID, "workspace_alpha")
        XCTAssertEqual(trigger.topics, [.workspaceSync, .recordingProcessing])
        XCTAssertEqual(trigger.remoteUpdatedAt, "2026-07-02T06:30:00Z")
        XCTAssertTrue(trigger.shouldProcessUploads)
        XCTAssertTrue(trigger.shouldPublishLocalSnapshot)
        XCTAssertTrue(trigger.shouldRefreshWorkspace)
    }

    func testRemoteNotificationRegistrationStillRegistersForSilentPushWhenAlertsAreDenied() {
        let deniedPlan = RemoteNotificationRegistrationPolicy.plan(for: .denied)
        XCTAssertFalse(deniedPlan.shouldRequestAlertAuthorization)
        XCTAssertTrue(deniedPlan.shouldRegisterForRemoteNotifications)

        let undeterminedPlan = RemoteNotificationRegistrationPolicy.plan(for: .notDetermined)
        XCTAssertTrue(undeterminedPlan.shouldRequestAlertAuthorization)
        XCTAssertTrue(undeterminedPlan.shouldRegisterForRemoteNotifications)
    }

    func testRemotePushNotificationParserRejectsVisibleNotificationPayload() throws {
        let decision = RemotePushNotificationPayloadParser.parse(userInfo: [
            "aps": ["alert": "Workspace updated"],
            "ideaforge": [
                "workspaceID": "workspace_alpha",
                "topics": ["workspace_sync"]
            ]
        ])

        XCTAssertEqual(decision, .ignored(.notSilentPush))
    }

    func testRemotePushNotificationParserRejectsMissingWorkspace() throws {
        let decision = RemotePushNotificationPayloadParser.parse(userInfo: [
            "aps": ["content-available": 1],
            "ideaforge": [
                "topics": ["workspace_sync"]
            ]
        ])

        XCTAssertEqual(decision, .ignored(.missingWorkspaceID))
    }

    func testRemotePushNotificationParserRejectsUnknownTopic() throws {
        let decision = RemotePushNotificationPayloadParser.parse(userInfo: [
            "aps": ["content-available": 1],
            "ideaforge": [
                "workspaceID": "workspace_alpha",
                "topics": ["workspace_sync", "raw_transcript"]
            ]
        ])

        XCTAssertEqual(decision, .ignored(.unknownTopic))
    }

    func testRemotePushNotificationParserNormalizesDuplicateEventTopic() throws {
        let decision = RemotePushNotificationPayloadParser.parse(userInfo: [
            "aps": ["content-available": NSNumber(value: 1)],
            "ideaforge": [
                "workspaceID": " workspace_alpha ",
                "event": "recording_processing"
            ]
        ])

        guard case .accepted(let trigger) = decision else {
            return XCTFail("Expected accepted remote push trigger")
        }
        XCTAssertEqual(trigger.workspaceID, "workspace_alpha")
        XCTAssertEqual(trigger.topics, [.recordingProcessing])
        XCTAssertTrue(trigger.shouldProcessUploads)
        XCTAssertTrue(trigger.shouldPublishLocalSnapshot)
        XCTAssertFalse(trigger.shouldRefreshWorkspace)
    }

    func testBackendAccountProvisioningClientCreatesWorkspaceBoundSession() async throws {
        let response = Data(
            """
            {
              "workspaceID": "workspace_alpha",
              "account": {
                "id": "acct_workspace_alpha",
                "planName": "Free",
                "planStatus": "trialing"
              },
              "session": {
                "userID": "user_workspace_alpha",
                "email": "builder@example.test",
                "workspaceID": "workspace_alpha",
                "account": {
                  "id": "acct_workspace_alpha",
                  "planName": "Free",
                  "planStatus": "trialing"
                },
                "capabilities": [
                  "upload_recordings",
                  "sync_workspace",
                  "run_ai_workflows",
                  "reconcile_billing",
                  "manage_account"
                ],
                "accountPortalURL": "https://accounts.example.test/workspaces/workspace_alpha",
                "accountDeletionURL": "https://accounts.example.test/workspaces/workspace_alpha/delete"
              },
              "bearerToken": "provisioned-token-workspace_alpha",
              "created": true
            }
            """.utf8
        )
        let transport = CapturingHTTPRequestTransport(
            responseData: response,
            statusCode: 201
        )
        let client = BackendAccountProvisioningClient(
            configuration: BackendAccountProvisioningConfiguration(
                baseURL: URL(string: "https://api.example.test")!,
                bootstrapToken: "bootstrap-token",
                provisionPath: "/account/provision"
            ),
            transport: transport
        )

        let provisioned = try await client.provisionAccount(
            BackendAccountProvisioningRequest(
                email: "builder@example.test",
                workspaceID: "workspace_alpha",
                displayName: "Builder",
                idempotencyKey: "idem-123"
            )
        )
        let capturedRequest = await transport.capturedRequest()
        let capturedBodyData = await transport.capturedBody()
        let capturedBody = try XCTUnwrap(capturedBodyData)
        let body = try JSONSerialization.jsonObject(with: capturedBody) as? [String: String]

        XCTAssertEqual(provisioned.workspaceID, "workspace_alpha")
        XCTAssertEqual(provisioned.account.id, "acct_workspace_alpha")
        XCTAssertEqual(provisioned.account.planName, "Free")
        XCTAssertEqual(provisioned.account.planStatus, BackendPlanStatus.trialing)
        XCTAssertEqual(provisioned.session.workspaceID, "workspace_alpha")
        XCTAssertEqual(provisioned.session.userID, "user_workspace_alpha")
        XCTAssertEqual(provisioned.session.accountPortalURL?.absoluteString, "https://accounts.example.test/workspaces/workspace_alpha")
        XCTAssertEqual(provisioned.bearerToken, "provisioned-token-workspace_alpha")
        XCTAssertTrue(provisioned.created)
        XCTAssertEqual(capturedRequest?.httpMethod, "POST")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer bootstrap-token")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Idempotency-Key"), "idem-123")
        XCTAssertEqual(capturedRequest?.url?.absoluteString, "https://api.example.test/account/provision")
        XCTAssertEqual(body?["email"], "builder@example.test")
        XCTAssertEqual(body?["workspaceID"], "workspace_alpha")
        XCTAssertEqual(body?["displayName"], "Builder")
    }

    func testBackendOperationsClientFetchesScopedStatusAndBackupManifest() async throws {
        let statusResponse = Data(
            """
            {
              "status": "ready",
              "generatedAt": "2026-07-01T00:00:00Z",
              "schema": {
                "currentVersion": "2026_07_01_002_async_workflow_jobs",
                "appliedMigrations": [
                  {
                    "version": "2026_07_01_002_async_workflow_jobs",
                    "appliedAt": "2026-07-01T00:00:00Z"
                  }
                ]
              },
              "checks": [
                {"name": "database", "status": "ok"},
                {"name": "schema_migrations", "status": "ok"},
                {"name": "object_storage", "status": "ok"}
              ],
              "counts": {
                "accounts": 1,
                "auditEvents": 2,
                "jobs": 3,
                "objects": 2,
                "transcriptionResults": 1,
                "workflowResults": 1,
                "usageEvents": 4
              },
              "tenants": [
                {
                  "workspaceID": "workspace_alpha",
                  "accountID": "acct_workspace_alpha",
                  "planName": "Free",
                  "planStatus": "trialing",
                  "capabilitiesCount": 5,
                  "createdAt": "2026-07-01T00:00:00Z"
                }
              ]
            }
            """.utf8
        )
        let backupResponse = Data(
            """
            {
              "generatedAt": "2026-07-01T00:01:00Z",
              "schemaVersion": "2026_07_01_002_async_workflow_jobs",
              "workspace": {
                "projectCount": 1,
                "workflowTemplateCount": 1,
                "uploadJobCount": 0,
                "updatedAt": "2026-07-01T00:00:00Z"
              },
              "storage": {
                "objectCount": 2,
                "totalObjectBytes": 128
              },
              "operations": {
                "accountCount": 1,
                "auditEventCount": 2,
                "jobCount": 3,
                "usageEventCount": 4
              },
              "tenants": [
                {
                  "workspaceID": "workspace_alpha",
                  "accountID": "acct_workspace_alpha",
                  "planName": "Free",
                  "planStatus": "trialing",
                  "capabilitiesCount": 5,
                  "createdAt": "2026-07-01T00:00:00Z"
                }
              ],
              "privacy": {
                "includesRawTranscript": false,
                "includesRawAudio": false,
                "includesBearerTokens": false,
                "includesEmailAddresses": false,
                "includesGeneratedArtifacts": false
              }
            }
            """.utf8
        )
        let transport = SequencedHTTPRequestTransport(
            responses: [
                HTTPTestResponse(data: statusResponse, statusCode: 200),
                HTTPTestResponse(data: backupResponse, statusCode: 200),
            ]
        )
        let client = BackendOperationsClient(
            configuration: BackendOperationsConfiguration(
                baseURL: URL(string: "https://api.example.test")!,
                bearerToken: "operations-token",
                workspaceID: "workspace_alpha",
                statusPath: "/admin/status",
                backupManifestPath: "/admin/backup"
            ),
            transport: transport
        )

        let status = try await client.fetchStatus()
        let backup = try await client.fetchBackupManifest()
        let requests = await transport.capturedRequests()

        XCTAssertTrue(status.isReady)
        XCTAssertEqual(status.schema.currentVersion, "2026_07_01_002_async_workflow_jobs")
        XCTAssertEqual(status.check(named: "database")?.status, "ok")
        XCTAssertEqual(status.counts.accounts, 1)
        XCTAssertEqual(status.counts.workflowResults, 1)
        XCTAssertEqual(status.tenants.first?.workspaceID, "workspace_alpha")
        XCTAssertEqual(status.tenants.first?.planStatus, .trialing)
        XCTAssertEqual(backup.workspace.projectCount, 1)
        XCTAssertEqual(backup.storage.totalObjectBytes, 128)
        XCTAssertEqual(backup.operations.auditEventCount, 2)
        XCTAssertTrue(backup.privacy.isContentFree)
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET"])
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "Authorization") }, ["Bearer operations-token", "Bearer operations-token"])
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "X-IdeaForge-Workspace-ID") }, ["workspace_alpha", "workspace_alpha"])
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "Accept") }, ["application/json", "application/json"])
        XCTAssertEqual(requests.map { $0.url?.absoluteString }, [
            "https://api.example.test/admin/status",
            "https://api.example.test/admin/backup",
        ])
    }

    func testBackendOperationsClientRunsScopedRestoreDrillWithoutContent() async throws {
        let restoreResponse = Data(
            """
            {
              "status": "passed",
              "generatedAt": "2026-07-01T00:02:00Z",
              "sourceBackupGeneratedAt": "2026-07-01T00:01:00Z",
              "schemaVersion": "2026_07_01_002_async_workflow_jobs",
              "checks": [
                {"name": "schema_version", "status": "ok"},
                {"name": "workspace_snapshot", "status": "ok"},
                {"name": "object_inventory", "status": "ok"},
                {"name": "privacy_redaction", "status": "ok"}
              ],
              "restored": {
                "workspace": {
                  "projectCount": 1,
                  "workflowTemplateCount": 1,
                  "uploadJobCount": 0,
                  "updatedAt": "2026-07-01T00:00:00Z"
                },
                "storage": {
                  "objectCount": 2,
                  "totalObjectBytes": 128
                },
                "operations": {
                  "accountCount": 1,
                  "auditEventCount": 2,
                  "jobCount": 3,
                  "usageEventCount": 4
                }
              },
              "privacy": {
                "includesRawTranscript": false,
                "includesRawAudio": false,
                "includesBearerTokens": false,
                "includesEmailAddresses": false,
                "includesGeneratedArtifacts": false,
                "includesLocalPaths": false
              }
            }
            """.utf8
        )
        let transport = SequencedHTTPRequestTransport(
            responses: [
                HTTPTestResponse(data: restoreResponse, statusCode: 200),
            ]
        )
        let client = BackendOperationsClient(
            configuration: BackendOperationsConfiguration(
                baseURL: URL(string: "https://api.example.test")!,
                bearerToken: "operations-token",
                workspaceID: "workspace_alpha",
                statusPath: "/admin/status",
                backupManifestPath: "/admin/backup",
                restoreDrillPath: "/admin/restore-drill"
            ),
            transport: transport
        )

        let report = try await client.runRestoreDrill(
            BackendRestoreDrillRequest(
                backupGeneratedAt: "2026-07-01T00:01:00Z",
                schemaVersion: "2026_07_01_002_async_workflow_jobs"
            )
        )
        let requests = await transport.capturedRequests()
        let body = try XCTUnwrap(requests.first?.httpBody)
        let requestPayload = try JSONSerialization.jsonObject(with: body) as? [String: String]

        XCTAssertTrue(report.isPassing)
        XCTAssertEqual(report.sourceBackupGeneratedAt, "2026-07-01T00:01:00Z")
        XCTAssertEqual(report.restored.workspace.projectCount, 1)
        XCTAssertEqual(report.restored.storage.totalObjectBytes, 128)
        XCTAssertEqual(report.check(named: "privacy_redaction")?.status, "ok")
        XCTAssertTrue(report.privacy.isContentFree)
        XCTAssertEqual(requests.map(\.httpMethod), ["POST"])
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer operations-token")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "X-IdeaForge-Workspace-ID"), "workspace_alpha")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(requests.first?.url?.absoluteString, "https://api.example.test/admin/restore-drill")
        XCTAssertEqual(requestPayload?["backupGeneratedAt"], "2026-07-01T00:01:00Z")
        XCTAssertEqual(requestPayload?["schemaVersion"], "2026_07_01_002_async_workflow_jobs")
    }

    func testBackendOperationsClientFetchesPrivacySafeMetrics() async throws {
        let metricsResponse = Data(
            """
            {
              "status": "ready",
              "generatedAt": "2026-07-02T08:10:00Z",
              "schemaVersion": "2026_07_01_002_async_workflow_jobs",
              "jobCountsByStatus": {
                "completed": 4,
                "running": 1,
                "failed": 1
              },
              "jobCountsByKind": {
                "recording_upload": 1,
                "transcription": 3,
                "workflow": 2
              },
              "storage": {
                "objectCount": 2,
                "totalObjectBytes": 128
              },
              "usage": [
                {
                  "metric": "transcription_seconds",
                  "quantity": 90.5
                },
                {
                  "metric": "workflow_runs",
                  "quantity": 2
                }
              ],
              "privacy": {
                "includesRawTranscript": false,
                "includesRawAudio": false,
                "includesBearerTokens": false,
                "includesEmailAddresses": false,
                "includesGeneratedArtifacts": false,
                "includesLocalPaths": false
              }
            }
            """.utf8
        )
        let transport = SequencedHTTPRequestTransport(
            responses: [
                HTTPTestResponse(data: metricsResponse, statusCode: 200),
            ]
        )
        let client = BackendOperationsClient(
            configuration: BackendOperationsConfiguration(
                baseURL: URL(string: "https://api.example.test")!,
                bearerToken: "operations-token",
                workspaceID: "workspace_alpha",
                metricsPath: "/admin/metrics"
            ),
            transport: transport
        )

        let metrics = try await client.fetchMetrics()
        let requests = await transport.capturedRequests()

        XCTAssertTrue(metrics.isMonitoringSafe)
        XCTAssertEqual(metrics.schemaVersion, "2026_07_01_002_async_workflow_jobs")
        XCTAssertEqual(metrics.jobCountsByStatus["completed"], 4)
        XCTAssertEqual(metrics.jobCountsByKind["workflow"], 2)
        XCTAssertEqual(metrics.storage.totalObjectBytes, 128)
        XCTAssertEqual(metrics.usage.first?.metric, "transcription_seconds")
        XCTAssertEqual(metrics.usage.first?.quantity ?? 0, 90.5, accuracy: 0.001)
        XCTAssertEqual(requests.map(\.httpMethod), ["GET"])
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer operations-token")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "X-IdeaForge-Workspace-ID"), "workspace_alpha")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(requests.first?.url?.absoluteString, "https://api.example.test/admin/metrics")
    }

    func testBackendCapabilityGateRequiresValidatedSessionWorkspaceAndCapabilities() {
        let account = BackendAccountSummary(id: "acct_local_dev", planName: "Pro", planStatus: .active)
        let missingSessionDecision = BackendCapabilityGate(session: nil).decision(
            requiredCapabilities: [.syncWorkspace],
            expectedWorkspaceID: "workspace_alpha"
        )

        XCTAssertFalse(missingSessionDecision.isAllowed)
        XCTAssertEqual(missingSessionDecision.blockers, ["Validate backend session before using this backend action."])

        let mismatchedWorkspaceSession = BackendAuthenticatedSession(
            userID: "user_local_dev",
            workspaceID: "workspace_beta",
            account: account,
            capabilities: [.syncWorkspace]
        )
        let workspaceDecision = BackendCapabilityGate(session: mismatchedWorkspaceSession).decision(
            requiredCapabilities: [.syncWorkspace],
            expectedWorkspaceID: "workspace_alpha"
        )

        XCTAssertFalse(workspaceDecision.isAllowed)
        XCTAssertEqual(workspaceDecision.blockers, ["Validated session belongs to a different workspace."])

        let missingCapabilitySession = BackendAuthenticatedSession(
            userID: "user_local_dev",
            workspaceID: "workspace_alpha",
            account: account,
            capabilities: [.syncWorkspace]
        )
        let missingCapabilityDecision = BackendCapabilityGate(session: missingCapabilitySession).decision(
            requiredCapabilities: [.syncWorkspace, .runAIWorkflows],
            expectedWorkspaceID: "workspace_alpha"
        )

        XCTAssertFalse(missingCapabilityDecision.isAllowed)
        XCTAssertEqual(missingCapabilityDecision.missingCapabilities, [.runAIWorkflows])
        XCTAssertEqual(missingCapabilityDecision.blockers, ["Backend session is missing capability: Run AI workflows."])

        let allowedDecision = BackendCapabilityGate(session: missingCapabilitySession).decision(
            requiredCapabilities: [.syncWorkspace],
            expectedWorkspaceID: "workspace_alpha"
        )

        XCTAssertTrue(allowedDecision.isAllowed)
        XCTAssertTrue(allowedDecision.blockers.isEmpty)
    }

    func testWorkspaceAutoSyncPolicyPublishesOnlySafeLocalChanges() {
        let allowedDecision = BackendCapabilityDecision(isAllowed: true)
        let localUpdatedAt = Date(timeIntervalSince1970: 2_000)
        let remoteUpdatedAt = Date(timeIntervalSince1970: 1_000)
        var state = WorkspaceState(
            projects: [],
            workflowTemplates: [],
            privacyMode: .standardCloud,
            syncHealth: SyncHealth(
                watchReachable: true,
                queuedUploads: 0,
                lastSuccessfulSync: Date(timeIntervalSince1970: 900),
                lastRemoteWorkspaceUpdatedAt: remoteUpdatedAt,
                failingItems: 0
            ),
            selectedProjectID: nil,
            updatedAt: localUpdatedAt
        )

        XCTAssertTrue(
            WorkspaceAutoSyncPolicy.decision(
                for: state,
                capabilityDecision: allowedDecision
            )
            .isPublishable
        )

        state.syncHealth.lastPublishedLocalUpdatedAt = remoteUpdatedAt
        state.syncHealth.lastRemoteWorkspaceUpdatedAt = Date(timeIntervalSince1970: 3_000)
        XCTAssertTrue(
            WorkspaceAutoSyncPolicy.decision(
                for: state,
                capabilityDecision: allowedDecision
            )
            .isPublishable,
            "A server-assigned revision must not hide a local edit made after the published snapshot was captured."
        )

        state.updatedAt = remoteUpdatedAt
        XCTAssertEqual(
            WorkspaceAutoSyncPolicy.decision(
                for: state,
                capabilityDecision: allowedDecision
            ),
            .idle("Local workspace already has a backend receipt.")
        )

        state.updatedAt = localUpdatedAt
        state.privacyMode = .privateLocal
        XCTAssertEqual(
            WorkspaceAutoSyncPolicy.decision(
                for: state,
                capabilityDecision: allowedDecision
            ),
            .blocked(
                .privateLocalMode,
                "Private mode keeps automatic workspace sync off."
            )
        )

        state.privacyMode = .standardCloud
        state.uploadJobs = [
            UploadJob(
                id: "upload_auto_1",
                recordingID: "rec_auto_1",
                ideaProjectID: "project_auto",
                localAudioPath: "/tmp/rec_auto_1.m4a",
                status: .waitingForRetry,
                attemptCount: 1,
                nextAttemptAt: localUpdatedAt,
                createdAt: localUpdatedAt,
                updatedAt: localUpdatedAt
            )
        ]
        XCTAssertEqual(
            WorkspaceAutoSyncPolicy.decision(
                for: state,
                capabilityDecision: allowedDecision
            ),
            .blocked(
                .activeUploadWork,
                "Automatic workspace sync is waiting for local upload work to finish. 1 item(s) remain queued or retrying."
            )
        )

        state.uploadJobs[0].status = .permanentlyFailed
        XCTAssertEqual(
            WorkspaceAutoSyncPolicy.decision(
                for: state,
                capabilityDecision: allowedDecision
            ),
            .blocked(
                .failedUploadWork,
                "Automatic workspace sync is paused until failed upload work is reviewed. 1 item(s) need attention."
            )
        )

        let blockedCapabilityDecision = BackendCapabilityDecision(
            isAllowed: false,
            blockers: ["Validate backend session before using this backend action."]
        )
        state.uploadJobs = []
        XCTAssertEqual(
            WorkspaceAutoSyncPolicy.decision(
                for: state,
                capabilityDecision: blockedCapabilityDecision
            ),
            .blocked(
                .capabilityGate,
                "Validate backend session before using this backend action."
            )
        )
    }

    @MainActor
    func testConfiguredWorkspaceAutoSyncProcessorSkipsPrivateModeBeforeNetwork() async throws {
        let state = WorkspaceState(
            projects: [],
            workflowTemplates: [],
            privacyMode: .privateLocal,
            syncHealth: SyncHealth(
                watchReachable: true,
                queuedUploads: 0,
                lastSuccessfulSync: SampleData.now,
                failingItems: 0
            ),
            selectedProjectID: nil,
            updatedAt: SampleData.now
        )
        let store = IdeaForgeStore(state: state)
        let transport = SequencedHTTPRequestTransport(responses: [])
        let manager = BackendConfigurationManager(
            settingsStore: InMemoryBackendSettingsStore(
                settings: BackendConnectionSettings(
                    baseURLString: "https://api.example.test",
                    workspaceID: "workspace_alpha",
                    isEnabled: true
                )
            ),
            credentialStore: InMemoryBackendCredentialStore(token: "sync-token")
        )
        let processor = ConfiguredWorkspaceAutoSyncProcessor(
            backendConfigurationManager: manager,
            authTransport: transport,
            syncTransport: transport
        )

        let result = await processor.publishLocalSnapshotIfNeeded(from: store, syncedAt: SampleData.now)
        let requests = await transport.capturedRequests()

        XCTAssertEqual(
            result,
            .skipped(
                .privateLocalMode,
                "Private mode keeps automatic workspace sync off."
            )
        )
        XCTAssertEqual(store.syncHealth.lastActivity?.source, .backgroundAutoSync)
        XCTAssertEqual(store.syncHealth.lastActivity?.status, .blocked)
        XCTAssertEqual(store.syncHealth.lastActivity?.title, "Auto-sync paused")
        XCTAssertEqual(store.syncHealth.lastActivity?.detail, "Private mode keeps automatic workspace sync off.")
        XCTAssertEqual(store.syncHealth.lastActivity?.occurredAt, SampleData.now)
        XCTAssertTrue(requests.isEmpty)
    }

    @MainActor
    func testConfiguredWorkspaceAutoSyncProcessorValidatesSessionAndPublishesSafeSnapshot() async throws {
        let localUpdatedAt = Date(timeIntervalSince1970: 2_000)
        let remoteUpdatedAt = Date(timeIntervalSince1970: 1_000)
        let syncedAt = Date(timeIntervalSince1970: 2_100)
        let state = WorkspaceState(
            projects: [],
            workflowTemplates: [],
            privacyMode: .standardCloud,
            syncHealth: SyncHealth(
                watchReachable: true,
                queuedUploads: 0,
                lastSuccessfulSync: Date(timeIntervalSince1970: 900),
                lastRemoteWorkspaceUpdatedAt: remoteUpdatedAt,
                failingItems: 0
            ),
            selectedProjectID: nil,
            updatedAt: localUpdatedAt
        )
        let repository = InMemoryWorkspaceRepository()
        let store = IdeaForgeStore(state: state, repository: repository)
        let session = BackendAuthenticatedSession(
            userID: "user_auto",
            workspaceID: "workspace_alpha",
            account: BackendAccountSummary(id: "acct_auto", planName: "Pro", planStatus: .active),
            capabilities: [.syncWorkspace]
        )
        let receipt = WorkspaceSyncPushReceipt(
            workspaceID: "workspace_alpha",
            acceptedUpdatedAt: localUpdatedAt
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var remoteState = state
        remoteState.updatedAt = remoteUpdatedAt
        let transport = SequencedHTTPRequestTransport(responses: [
            HTTPTestResponse(data: try encoder.encode(session), statusCode: 200),
            HTTPTestResponse(data: try encoder.encode(remoteState), statusCode: 200),
            HTTPTestResponse(data: try encoder.encode(receipt), statusCode: 200)
        ])
        let manager = BackendConfigurationManager(
            settingsStore: InMemoryBackendSettingsStore(
                settings: BackendConnectionSettings(
                    baseURLString: "https://api.example.test",
                    workspaceID: "workspace_alpha",
                    isEnabled: true
                )
            ),
            credentialStore: InMemoryBackendCredentialStore(token: "sync-token")
        )
        let processor = ConfiguredWorkspaceAutoSyncProcessor(
            backendConfigurationManager: manager,
            authTransport: transport,
            syncTransport: transport
        )

        let result = await processor.publishLocalSnapshotIfNeeded(from: store, syncedAt: syncedAt)
        let requests = await transport.capturedRequests()
        let saved = try XCTUnwrap(try repository.load())

        guard case .published(let summary) = result else {
            return XCTFail("Expected auto-sync to publish the local workspace snapshot.")
        }
        XCTAssertTrue(summary.pushedLocalSnapshot)
        XCTAssertEqual(summary.acceptedLocalUpdatedAt, localUpdatedAt)
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "PUT"])
        XCTAssertEqual(requests.first?.url?.absoluteString, "https://api.example.test/v1/auth/session")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer sync-token")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "X-IdeaForge-Workspace-ID"), "workspace_alpha")
        XCTAssertEqual(requests[1].url?.absoluteString, "https://api.example.test/v1/workspace/snapshot?since=1970-01-01T00:16:40Z")
        XCTAssertEqual(requests.last?.url?.absoluteString, "https://api.example.test/v1/workspace/snapshot")
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer sync-token")
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "X-IdeaForge-Workspace-ID"), "workspace_alpha")
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "X-IdeaForge-Base-Remote-Updated-At"), "1970-01-01T00:16:40Z")
        XCTAssertEqual(store.syncHealth.lastSuccessfulSync, syncedAt)
        XCTAssertEqual(store.syncHealth.lastRemoteWorkspaceUpdatedAt, localUpdatedAt)
        XCTAssertEqual(store.syncHealth.lastActivity?.source, .backgroundAutoSync)
        XCTAssertEqual(store.syncHealth.lastActivity?.status, .success)
        XCTAssertEqual(store.syncHealth.lastActivity?.title, "Auto-sync published")
        XCTAssertEqual(store.syncHealth.lastActivity?.detail, "Workspace snapshot has a backend receipt for Mac handoff.")
        XCTAssertEqual(store.syncHealth.lastActivity?.occurredAt, syncedAt)
        XCTAssertEqual(saved.syncHealth.lastSuccessfulSync, syncedAt)
        XCTAssertEqual(saved.syncHealth.lastRemoteWorkspaceUpdatedAt, localUpdatedAt)
        XCTAssertEqual(saved.syncHealth.lastActivity, store.syncHealth.lastActivity)
    }

    func testBackendBillingReconciliationClientPostsAppStoreTransactionEvidenceAndDecodesUsageSummary() async throws {
        let response = Data(
            """
            {
              "account": {
                "id": "acct_local_dev",
                "planName": "Pro",
                "planStatus": "active"
              },
              "accountPortalURL": "https://accounts.example.test/portal",
              "accountDeletionURL": "https://accounts.example.test/delete",
              "workspaceID": "workspace_alpha",
              "usage": [],
              "entitlements": [
                {
                  "metric": "workflow_runs",
                  "includedQuantity": 100.0,
                  "usedQuantity": 0.0,
                  "remainingQuantity": 100.0
                }
              ]
            }
            """.utf8
        )
        let transport = CapturingHTTPRequestTransport(
            responseData: response,
            statusCode: 200
        )
        let client = BackendBillingReconciliationClient(
            configuration: BackendBillingReconciliationConfiguration(
                baseURL: URL(string: "https://api.example.test")!,
                bearerToken: "billing-token",
                workspaceID: "workspace_alpha",
                reconciliationPath: "/billing/app-store/reconcile"
            ),
            transport: transport
        )
        let purchaseDate = Date(timeIntervalSince1970: 1_000)
        let expirationDate = Date(timeIntervalSince1970: 2_000)
        let evidence = AppStoreTransactionEvidence(
            productID: CommerceProductID.proMonthly,
            transactionID: "123",
            originalTransactionID: "100",
            appBundleID: "com.s1kor.ideaforge.ios",
            purchaseDate: purchaseDate,
            expirationDate: expirationDate,
            signedTransactionJWS: Self.fixtureAppStoreTransactionJWS(
                productID: CommerceProductID.proMonthly,
                transactionID: "123",
                originalTransactionID: "100",
                appBundleID: "com.s1kor.ideaforge.ios"
            )
        )

        let summary = try await client.reconcileAppStoreEntitlements(
            AppStoreBillingReconciliationRequest(
                reason: .purchase,
                transactions: [evidence]
            )
        )
        let capturedRequest = await transport.capturedRequest()
        let maybeCapturedBody = await transport.capturedBody()
        let capturedBody = try XCTUnwrap(maybeCapturedBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: capturedBody) as? [String: Any])
        let transactions = try XCTUnwrap(body["transactions"] as? [[String: Any]])

        XCTAssertEqual(summary.account.planName, "Pro")
        XCTAssertEqual(summary.entitlement(for: BackendEntitlementMetric.workflowRuns)?.remainingQuantity, 100.0)
        XCTAssertEqual(capturedRequest?.httpMethod, "POST")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer billing-token")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "X-IdeaForge-Workspace-ID"), "workspace_alpha")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(capturedRequest?.url?.absoluteString, "https://api.example.test/billing/app-store/reconcile")
        XCTAssertEqual(body["reason"] as? String, "purchase")
        XCTAssertEqual(transactions.first?["productID"] as? String, CommerceProductID.proMonthly)
        XCTAssertEqual(transactions.first?["transactionID"] as? String, "123")
        XCTAssertEqual(transactions.first?["originalTransactionID"] as? String, "100")
        XCTAssertEqual(transactions.first?["appBundleID"] as? String, "com.s1kor.ideaforge.ios")
        XCTAssertEqual(
            transactions.first?["signedTransactionJWS"] as? String,
            Self.fixtureAppStoreTransactionJWS(
                productID: CommerceProductID.proMonthly,
                transactionID: "123",
                originalTransactionID: "100",
                appBundleID: "com.s1kor.ideaforge.ios"
            )
        )
    }

    func testBackendBillingReconciliationClientRejectsMalformedTransactionEvidenceBeforeNetwork() async throws {
        let transport = CapturingHTTPRequestTransport(
            responseData: Data("{}".utf8),
            statusCode: 200
        )
        let client = BackendBillingReconciliationClient(
            configuration: BackendBillingReconciliationConfiguration(
                baseURL: URL(string: "https://api.example.test")!,
                bearerToken: "billing-token",
                workspaceID: "workspace_alpha"
            ),
            transport: transport
        )
        let malformedEvidence = AppStoreTransactionEvidence(
            productID: CommerceProductID.proMonthly,
            transactionID: "123",
            originalTransactionID: "100",
            appBundleID: "com.s1kor.ideaforge.ios",
            purchaseDate: Date(timeIntervalSince1970: 1_000),
            expirationDate: nil,
            signedTransactionJWS: "not-jws"
        )

        do {
            _ = try await client.reconcileAppStoreEntitlements(
                AppStoreBillingReconciliationRequest(
                    reason: .purchase,
                    transactions: [malformedEvidence]
                )
            )
            XCTFail("Malformed transaction evidence should fail closed before network submission.")
        } catch BackendBillingError.invalidTransactionEvidence(let issues) {
            XCTAssertEqual(issues, ["transactions[0].signedTransactionJWS must be JWS Compact Serialization with header, payload, and signature segments."])
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let capturedRequest = await transport.capturedRequest()
        XCTAssertNil(capturedRequest)
    }

    func testBackendBillingReconciliationClientRejectsMismatchedJWSTransactionClaimsBeforeNetwork() async throws {
        let transport = CapturingHTTPRequestTransport(
            responseData: Data("{}".utf8),
            statusCode: 200
        )
        let client = BackendBillingReconciliationClient(
            configuration: BackendBillingReconciliationConfiguration(
                baseURL: URL(string: "https://api.example.test")!,
                bearerToken: "billing-token",
                workspaceID: "workspace_alpha"
            ),
            transport: transport
        )
        let mismatchedEvidence = AppStoreTransactionEvidence(
            productID: CommerceProductID.proMonthly,
            transactionID: "123",
            originalTransactionID: "100",
            appBundleID: "com.s1kor.ideaforge.ios",
            purchaseDate: Date(timeIntervalSince1970: 1_000),
            expirationDate: nil,
            signedTransactionJWS: Self.fixtureAppStoreTransactionJWS(
                productID: CommerceProductID.proYearly,
                transactionID: "123",
                originalTransactionID: "100",
                appBundleID: "com.s1kor.ideaforge.ios"
            )
        )

        do {
            _ = try await client.reconcileAppStoreEntitlements(
                AppStoreBillingReconciliationRequest(
                    reason: .purchase,
                    transactions: [mismatchedEvidence]
                )
            )
            XCTFail("Mismatched transaction claims should fail closed before network submission.")
        } catch BackendBillingError.invalidTransactionEvidence(let issues) {
            XCTAssertEqual(issues, ["transactions[0].signedTransactionJWS productId must match productID."])
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let capturedRequest = await transport.capturedRequest()
        XCTAssertNil(capturedRequest)
    }

    @MainActor
    func testWorkspaceSyncEngineAppliesOnlyNewerRemoteSnapshots() async throws {
        let localUpdatedAt = Date(timeIntervalSince1970: 1_000)
        let remoteUpdatedAt = Date(timeIntervalSince1970: 2_000)
        let repository = InMemoryWorkspaceRepository()
        let store = IdeaForgeStore(
            state: WorkspaceState(
                projects: [],
                workflowTemplates: DefaultWorkflows.templates,
                uploadJobs: [],
                privacyMode: .privateLocal,
                syncHealth: SyncHealth(
                    watchReachable: false,
                    queuedUploads: 0,
                    lastSuccessfulSync: localUpdatedAt,
                    failingItems: 0
                ),
                selectedProjectID: nil,
                updatedAt: localUpdatedAt
            ),
            repository: repository
        )
        store.syncHealth.syncConflictStatus = WorkspaceSyncConflictStatus(
            localOnlyUploadJobCount: 1,
            localOnlyRecordingCount: 1,
            detectedAt: Date(timeIntervalSince1970: 1_500)
        )
        let remoteState = WorkspaceState(
            projects: [
                IdeaProject(
                    id: "idea_remote",
                    title: "Remote Idea",
                    status: .draft,
                    source: .mac,
                    createdAt: remoteUpdatedAt,
                    updatedAt: remoteUpdatedAt,
                    summary: "Remote backend summary.",
                    tags: [.business],
                    score: IdeaScore(confidence: 0.8, completeness: 0.7, risk: 0.2),
                    transcript: Transcript(cleanText: "Remote backend summary.", segments: [], unclearFragments: []),
                    recordings: [],
                    questions: [],
                    artifacts: [],
                    assumptions: [],
                    validationExperiments: [],
                    codexTasks: []
                )
            ],
            workflowTemplates: DefaultWorkflows.templates,
            uploadJobs: [],
            privacyMode: .standardCloud,
            syncHealth: SyncHealth(
                watchReachable: false,
                queuedUploads: 0,
                lastSuccessfulSync: localUpdatedAt,
                failingItems: 0
            ),
            selectedProjectID: "idea_remote",
            updatedAt: remoteUpdatedAt
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let engine = WorkspaceSyncEngine(
            client: BackendWorkspaceSyncClient(
                configuration: BackendSyncConfiguration(
                    baseURL: URL(string: "https://api.example.test")!,
                    bearerToken: "sync-token",
                    workspaceID: "workspace_alpha"
                ),
                transport: CapturingHTTPRequestTransport(
                    responseData: try encoder.encode(remoteState),
                    statusCode: 200
                )
            )
        )

        let summary = try await engine.pullLatest(into: store, syncedAt: Date(timeIntervalSince1970: 3_000))

        XCTAssertTrue(summary.appliedRemoteSnapshot)
        XCTAssertEqual(store.selectedProject?.title, "Remote Idea")
        XCTAssertEqual(store.updatedAt, remoteUpdatedAt)
        XCTAssertEqual(store.syncHealth.lastRemoteWorkspaceUpdatedAt, remoteUpdatedAt)
        XCTAssertEqual(store.syncHealth.lastSuccessfulSync, Date(timeIntervalSince1970: 3_000))
        XCTAssertNil(store.syncHealth.syncConflictStatus)

        let olderState = WorkspaceState(
            projects: [],
            workflowTemplates: DefaultWorkflows.templates,
            uploadJobs: [],
            privacyMode: .privateLocal,
            syncHealth: SyncHealth(
                watchReachable: false,
                queuedUploads: 0,
                lastSuccessfulSync: localUpdatedAt,
                failingItems: 0
            ),
            selectedProjectID: nil,
            updatedAt: Date(timeIntervalSince1970: 1_500)
        )
        let ignored = try store.applyRemoteWorkspaceSnapshot(olderState, syncedAt: Date(timeIntervalSince1970: 4_000))

        XCTAssertFalse(ignored)
        XCTAssertEqual(store.selectedProject?.title, "Remote Idea")
        XCTAssertEqual(store.updatedAt, remoteUpdatedAt)
        XCTAssertEqual(store.syncHealth.lastSuccessfulSync, Date(timeIntervalSince1970: 4_000))
        XCTAssertEqual(store.syncHealth.lastRemoteWorkspaceUpdatedAt, remoteUpdatedAt)
    }

    @MainActor
    func testWorkspaceSyncEngineInitialPullHydratesEmptyWorkspaceEvenWhenLocalClockIsNewer() async throws {
        let localUpdatedAt = Date(timeIntervalSince1970: 4_000)
        let remoteUpdatedAt = Date(timeIntervalSince1970: 2_000)
        let repository = InMemoryWorkspaceRepository()
        let localState = WorkspaceState(
            projects: [],
            workflowTemplates: DefaultWorkflows.templates,
            uploadJobs: [],
            privacyMode: .privateLocal,
            syncHealth: SyncHealth(
                watchReachable: false,
                queuedUploads: 0,
                lastSuccessfulSync: .distantPast,
                failingItems: 0
            ),
            selectedProjectID: nil,
            updatedAt: localUpdatedAt
        )
        let store = IdeaForgeStore(state: localState, repository: repository)
        var remoteState = WorkspaceState.seed()
        remoteState.updatedAt = remoteUpdatedAt
        remoteState.syncHealth.lastRemoteWorkspaceUpdatedAt = remoteUpdatedAt
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let engine = WorkspaceSyncEngine(
            client: BackendWorkspaceSyncClient(
                configuration: BackendSyncConfiguration(
                    baseURL: URL(string: "https://api.example.test")!,
                    bearerToken: "sync-token",
                    workspaceID: "workspace_alpha"
                ),
                transport: CapturingHTTPRequestTransport(
                    responseData: try encoder.encode(remoteState),
                    statusCode: 200
                )
            )
        )

        let summary = try await engine.pullLatest(into: store, syncedAt: Date(timeIntervalSince1970: 5_000))
        let expectedRemoteState = WorkspaceSyncPayloadPolicy.inboundState(
            from: remoteState,
            preservingDeviceLocalState: localState
        )

        XCTAssertTrue(summary.appliedRemoteSnapshot)
        XCTAssertEqual(store.projects, expectedRemoteState.projects)
        XCTAssertEqual(store.updatedAt, remoteUpdatedAt)
        XCTAssertEqual(store.syncHealth.lastRemoteWorkspaceUpdatedAt, remoteUpdatedAt)
    }

    @MainActor
    func testRemoteWorkspaceApplyRollsBackWhenPersistenceFails() throws {
        var localState = WorkspaceState.fresh()
        localState.updatedAt = Date(timeIntervalSince1970: 1_000)
        let repository = ThrowingWorkspaceRepository(state: localState)
        let store = IdeaForgeStore(state: localState, repository: repository)
        var remoteState = WorkspaceState.seed()
        remoteState.updatedAt = Date(timeIntervalSince1970: 2_000)

        XCTAssertThrowsError(
            try store.applyRemoteWorkspaceSnapshot(
                remoteState,
                syncedAt: Date(timeIntervalSince1970: 3_000)
            )
        )
        XCTAssertEqual(store.workspaceState(), localState)
        XCTAssertEqual(try repository.load(), localState)
        XCTAssertEqual(store.lastErrorMessage, "Remote workspace could not be saved.")
    }

    @MainActor
    func testRemoteWorkspaceApplyPreservesDeviceLocalAudioAndUploadQueue() throws {
        var localState = WorkspaceState.seed()
        localState.updatedAt = Date(timeIntervalSince1970: 1_000)
        localState.syncHealth.lastRemoteWorkspaceUpdatedAt = localState.updatedAt
        localState.syncHealth.lastPublishedLocalUpdatedAt = localState.updatedAt
        for index in localState.projects.indices {
            localState.projects[index].updatedAt = localState.updatedAt
        }
        let expectedLocalPaths = Dictionary(
            uniqueKeysWithValues: localState.projects
                .flatMap(\.recordings)
                .map { ($0.id, $0.localAudioPath) }
        )
        let expectedUploadJobs = localState.uploadJobs
        var remoteState = WorkspaceSyncPayloadPolicy.outboundState(from: localState)
        remoteState.updatedAt = Date(timeIntervalSince1970: 2_000)
        remoteState.projects[0].title = "Remote title edit"
        remoteState.projects[0].updatedAt = remoteState.updatedAt
        let store = IdeaForgeStore(
            state: localState,
            repository: InMemoryWorkspaceRepository(state: localState)
        )

        XCTAssertTrue(
            try store.applyRemoteWorkspaceSnapshot(
                remoteState,
                syncedAt: Date(timeIntervalSince1970: 3_000)
            )
        )

        XCTAssertEqual(store.projects[0].title, "Remote title edit")
        XCTAssertEqual(store.uploadJobs, expectedUploadJobs)
        for recording in store.projects.flatMap(\.recordings) {
            XCTAssertEqual(recording.localAudioPath, expectedLocalPaths[recording.id] ?? nil)
        }
    }

    @MainActor
    func testWorkspaceSyncEnginePublishesLocalSnapshotAndStoresRemoteRevision() async throws {
        let localUpdatedAt = Date(timeIntervalSince1970: 2_000)
        let lastRemoteUpdatedAt = Date(timeIntervalSince1970: 1_000)
        let syncedAt = Date(timeIntervalSince1970: 2_100)
        let serverAcceptedAt = Date(timeIntervalSince1970: 2_500)
        let repository = InMemoryWorkspaceRepository()
        let store = IdeaForgeStore(state: WorkspaceState.seed(), repository: repository)
        store.syncHealth.lastRemoteWorkspaceUpdatedAt = lastRemoteUpdatedAt
        store.save(now: localUpdatedAt)
        let receipt = WorkspaceSyncPushReceipt(
            workspaceID: "workspace_alpha",
            acceptedUpdatedAt: serverAcceptedAt
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let transport = CapturingHTTPRequestTransport(
            responseData: try encoder.encode(receipt),
            statusCode: 200
        )
        let engine = WorkspaceSyncEngine(
            client: BackendWorkspaceSyncClient(
                configuration: BackendSyncConfiguration(
                    baseURL: URL(string: "https://api.example.test")!,
                    bearerToken: "sync-token",
                    workspaceID: "workspace_alpha"
                ),
                transport: transport
            )
        )

        let summary = try await engine.pushLocalSnapshot(from: store, syncedAt: syncedAt)
        let saved = try XCTUnwrap(try repository.load())
        let capturedRequest = await transport.capturedRequest()
        let publishedBody = try XCTUnwrap(capturedRequest?.httpBody)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let publishedState = try decoder.decode(WorkspaceState.self, from: publishedBody)

        XCTAssertTrue(summary.pushedLocalSnapshot)
        XCTAssertFalse(summary.fetched)
        XCTAssertEqual(summary.acceptedLocalUpdatedAt, localUpdatedAt)
        XCTAssertEqual(store.updatedAt, localUpdatedAt)
        XCTAssertEqual(store.syncHealth.lastSuccessfulSync, syncedAt)
        XCTAssertEqual(store.syncHealth.lastRemoteWorkspaceUpdatedAt, serverAcceptedAt)
        XCTAssertEqual(store.syncHealth.lastPublishedLocalUpdatedAt, localUpdatedAt)
        XCTAssertEqual(saved.syncHealth.lastSuccessfulSync, syncedAt)
        XCTAssertEqual(saved.syncHealth.lastRemoteWorkspaceUpdatedAt, serverAcceptedAt)
        XCTAssertEqual(saved.syncHealth.lastPublishedLocalUpdatedAt, localUpdatedAt)
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "X-IdeaForge-Base-Remote-Updated-At"), "1970-01-01T00:16:40Z")
        XCTAssertTrue(publishedState.uploadJobs.isEmpty)
        XCTAssertTrue(
            publishedState.projects
                .flatMap(\.recordings)
                .allSatisfy { $0.localAudioPath == nil }
        )
    }

    @MainActor
    func testWorkspaceSyncEngineDoesNotReportPublishedWhenReceiptCannotBePersisted() async throws {
        var localState = WorkspaceState.seed()
        localState.updatedAt = Date(timeIntervalSince1970: 2_000)
        localState.syncHealth.lastRemoteWorkspaceUpdatedAt = Date(timeIntervalSince1970: 1_000)
        let repository = ThrowingWorkspaceRepository(state: localState)
        let store = IdeaForgeStore(state: localState, repository: repository)
        let receipt = WorkspaceSyncPushReceipt(
            workspaceID: "workspace_alpha",
            acceptedUpdatedAt: localState.updatedAt
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let engine = WorkspaceSyncEngine(
            client: BackendWorkspaceSyncClient(
                configuration: BackendSyncConfiguration(
                    baseURL: URL(string: "https://api.example.test")!,
                    bearerToken: "sync-token",
                    workspaceID: "workspace_alpha"
                ),
                transport: CapturingHTTPRequestTransport(
                    responseData: try encoder.encode(receipt),
                    statusCode: 200
                )
            )
        )

        do {
            _ = try await engine.pushLocalSnapshot(
                from: store,
                syncedAt: Date(timeIntervalSince1970: 3_000)
            )
            XCTFail("Expected a failed receipt persistence to fail the sync operation.")
        } catch {
            XCTAssertEqual(error as? WorkspaceRepositoryError, .unwritableState)
        }
        XCTAssertEqual(store.workspaceState(), localState)
        XCTAssertEqual(try repository.load(), localState)
        XCTAssertEqual(store.lastErrorMessage, "Workspace publish receipt could not be saved.")
    }

    @MainActor
    func testWorkspaceSynchronizePullsBeforePublishingLocalChanges() async throws {
        let localUpdatedAt = Date(timeIntervalSince1970: 3_000)
        let remoteUpdatedAt = Date(timeIntervalSince1970: 2_000)
        var localState = WorkspaceState.seed()
        localState.privacyMode = .standardCloud
        localState.syncHealth.failingItems = 0
        localState.syncHealth.queuedUploads = 0
        localState.updatedAt = localUpdatedAt
        localState.syncHealth.lastRemoteWorkspaceUpdatedAt = Date(timeIntervalSince1970: 1_000)
        var remoteState = localState
        remoteState.updatedAt = remoteUpdatedAt
        remoteState.syncHealth.lastRemoteWorkspaceUpdatedAt = remoteUpdatedAt
        let receipt = WorkspaceSyncPushReceipt(
            workspaceID: "workspace_alpha",
            acceptedUpdatedAt: localUpdatedAt
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let transport = SequencedHTTPRequestTransport(responses: [
            HTTPTestResponse(data: try encoder.encode(remoteState), statusCode: 200),
            HTTPTestResponse(data: try encoder.encode(receipt), statusCode: 200)
        ])
        let store = IdeaForgeStore(
            state: localState,
            repository: InMemoryWorkspaceRepository(state: localState)
        )
        let engine = WorkspaceSyncEngine(
            client: BackendWorkspaceSyncClient(
                configuration: BackendSyncConfiguration(
                    baseURL: URL(string: "https://api.example.test")!,
                    bearerToken: "sync-token",
                    workspaceID: "workspace_alpha"
                ),
                transport: transport
            )
        )

        let summary = try await engine.synchronize(store: store, syncedAt: Date(timeIntervalSince1970: 4_000))
        let requests = await transport.capturedRequests()

        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "PUT"])
        XCTAssertEqual(
            requests.last?.value(forHTTPHeaderField: "X-IdeaForge-Base-Remote-Updated-At"),
            "1970-01-01T00:33:20Z"
        )
        XCTAssertTrue(summary.pushedLocalSnapshot)
        XCTAssertEqual(store.syncHealth.lastRemoteWorkspaceUpdatedAt, localUpdatedAt)
    }

    @MainActor
    func testWorkspaceSynchronizeMergesNonOverlappingWatchCaptureAndPublishesForMac() async throws {
        let remoteUpdatedAt = Date(timeIntervalSince1970: 2_000)
        let localUpdatedAt = Date(timeIntervalSince1970: 3_000)
        var localState = WorkspaceState.seed()
        localState.privacyMode = .standardCloud
        var watchProject = localState.projects[0]
        watchProject.id = "idea_watch_handoff"
        watchProject.title = "Watch handoff"
        watchProject.updatedAt = localUpdatedAt
        var watchRecording = watchProject.recordings[0]
        watchRecording.id = "rec_watch_handoff"
        watchRecording.ideaProjectID = watchProject.id
        watchRecording.localFileStatus = .uploaded
        watchRecording.syncStatus = .transferredToIPhone
        watchRecording.localAudioPath = "recordings/rec_watch_handoff.m4a"
        watchRecording.audioObjectKey = "audio/idea_watch_handoff/rec_watch_handoff.m4a"
        watchProject.recordings = [watchRecording]
        localState.projects = [watchProject]
        localState.selectedProjectID = watchProject.id
        localState.uploadJobs = [
            UploadJob(
                id: "upload_rec_watch_handoff",
                recordingID: watchRecording.id,
                ideaProjectID: watchProject.id,
                localAudioPath: try XCTUnwrap(watchRecording.localAudioPath),
                status: .uploaded,
                attemptCount: 1,
                nextAttemptAt: localUpdatedAt,
                objectKey: watchRecording.audioObjectKey,
                createdAt: localUpdatedAt,
                updatedAt: localUpdatedAt
            )
        ]
        localState.syncHealth = SyncHealth(
            watchReachable: true,
            queuedUploads: 0,
            lastSuccessfulSync: .distantPast,
            failingItems: 0
        )
        localState.updatedAt = localUpdatedAt

        var remoteState = WorkspaceState.seed()
        remoteState.privacyMode = .standardCloud
        remoteState.projects = [remoteState.projects[1]]
        remoteState.selectedProjectID = remoteState.projects[0].id
        remoteState.uploadJobs = []
        remoteState.updatedAt = remoteUpdatedAt
        let receipt = WorkspaceSyncPushReceipt(
            workspaceID: "workspace_alpha",
            acceptedUpdatedAt: Date(timeIntervalSince1970: 4_000)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let transport = SequencedHTTPRequestTransport(responses: [
            HTTPTestResponse(data: try encoder.encode(remoteState), statusCode: 200),
            HTTPTestResponse(data: try encoder.encode(receipt), statusCode: 200)
        ])
        let repository = InMemoryWorkspaceRepository(state: localState)
        let store = IdeaForgeStore(state: localState, repository: repository)
        let engine = WorkspaceSyncEngine(
            client: BackendWorkspaceSyncClient(
                configuration: BackendSyncConfiguration(
                    baseURL: URL(string: "https://api.example.test")!,
                    bearerToken: "sync-token",
                    workspaceID: "workspace_alpha"
                ),
                transport: transport
            )
        )

        let summary = try await engine.synchronize(store: store, syncedAt: Date(timeIntervalSince1970: 5_000))
        let requests = await transport.capturedRequests()
        let pushedData = try XCTUnwrap(requests.last?.httpBody)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let pushedState = try decoder.decode(WorkspaceState.self, from: pushedData)

        XCTAssertTrue(summary.pushedLocalSnapshot)
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "PUT"])
        XCTAssertEqual(Set(store.projects.map(\.id)), ["idea_watch_handoff", remoteState.projects[0].id])
        XCTAssertEqual(Set(pushedState.projects.map(\.id)), ["idea_watch_handoff", remoteState.projects[0].id])
        XCTAssertNil(store.syncHealth.syncConflictStatus)
    }

    func testBackendWorkspaceSyncClientRejectsDuplicateRemoteProjectIDs() async throws {
        var remoteState = WorkspaceState.seed()
        remoteState.projects.append(remoteState.projects[0])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let client = BackendWorkspaceSyncClient(
            configuration: BackendSyncConfiguration(
                baseURL: URL(string: "https://api.example.test")!,
                bearerToken: "sync-token",
                workspaceID: "workspace_alpha"
            ),
            transport: CapturingHTTPRequestTransport(
                responseData: try encoder.encode(remoteState),
                statusCode: 200
            )
        )

        do {
            _ = try await client.fetchWorkspaceSnapshot(since: nil)
            XCTFail("Expected duplicate remote identifiers to fail closed.")
        } catch {
            XCTAssertEqual(error as? BackendSyncError, .invalidResponse)
        }
    }

    func testBackendWorkspaceSyncClientRejectsBrokenWorkspaceRelationships() async throws {
        var wrongNestedProject = WorkspaceState.seed()
        wrongNestedProject.projects[0].recordings[0].ideaProjectID = wrongNestedProject.projects[1].id

        var wrongJobProject = WorkspaceState.seed()
        let jobRecording = wrongJobProject.projects[0].recordings[0]
        wrongJobProject.uploadJobs = [
            UploadJob(
                id: "upload_wrong_relationship",
                recordingID: jobRecording.id,
                ideaProjectID: wrongJobProject.projects[1].id,
                localAudioPath: jobRecording.localAudioPath ?? "recordings/wrong-relationship.m4a",
                status: .uploaded,
                attemptCount: 1,
                nextAttemptAt: SampleData.now,
                objectKey: "audio/wrong-relationship.m4a",
                createdAt: SampleData.now,
                updatedAt: SampleData.now
            )
        ]

        var missingSelection = WorkspaceState.seed()
        missingSelection.selectedProjectID = "idea_missing"

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        for invalidState in [wrongNestedProject, wrongJobProject, missingSelection] {
            let client = BackendWorkspaceSyncClient(
                configuration: BackendSyncConfiguration(
                    baseURL: URL(string: "https://api.example.test")!,
                    bearerToken: "sync-token",
                    workspaceID: "workspace_alpha"
                ),
                transport: CapturingHTTPRequestTransport(
                    responseData: try encoder.encode(invalidState),
                    statusCode: 200
                )
            )
            do {
                _ = try await client.fetchWorkspaceSnapshot(since: nil)
                XCTFail("Expected inconsistent workspace relationships to fail closed.")
            } catch {
                XCTAssertEqual(error as? BackendSyncError, .invalidResponse)
            }
        }
    }

    func testBackendWorkspaceSyncClientRetriesUnconditionallyAfterNotModifiedResponse() async throws {
        var remoteState = WorkspaceState.seed()
        remoteState.updatedAt = SampleData.now
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let transport = SequencedHTTPRequestTransport(responses: [
            HTTPTestResponse(data: Data(), statusCode: 304),
            HTTPTestResponse(data: try encoder.encode(remoteState), statusCode: 200)
        ])
        let client = BackendWorkspaceSyncClient(
            configuration: BackendSyncConfiguration(
                baseURL: URL(string: "https://api.example.test")!,
                bearerToken: "sync-token",
                workspaceID: "workspace_alpha"
            ),
            transport: transport
        )

        let fetched = try await client.fetchWorkspaceSnapshot(since: SampleData.now)
        let requests = await transport.capturedRequests()

        XCTAssertEqual(fetched, remoteState)
        XCTAssertNotNil(requests.first?.url?.query)
        XCTAssertNil(requests.last?.url?.query)
    }

    @MainActor
    func testWorkspaceSynchronizeRechecksPublicationPolicyAfterRemoteFetch() async throws {
        let baseAt = Date().addingTimeInterval(-60)
        var remoteState = WorkspaceState.fresh()
        remoteState.privacyMode = .standardCloud
        remoteState.updatedAt = Date().addingTimeInterval(60)
        var localState = remoteState
        localState.updatedAt = baseAt
        localState.syncHealth.lastRemoteWorkspaceUpdatedAt = baseAt
        localState.syncHealth.lastPublishedLocalUpdatedAt = baseAt
        let store = IdeaForgeStore(state: localState, repository: InMemoryWorkspaceRepository(state: localState))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let transport = MutatingSequencedHTTPRequestTransport(
            responses: [HTTPTestResponse(data: try encoder.encode(remoteState), statusCode: 200)],
            mutation: {
                let recording = Recording(
                    id: "rec_arrived_during_fetch",
                    ideaProjectID: "idea_arrived_during_fetch",
                    deviceName: "Apple Watch",
                    durationSeconds: 15,
                    localFileStatus: .available,
                    syncStatus: .transferredToIPhone,
                    localAudioPath: "recordings/arrived-during-fetch.m4a",
                    languageHint: "en-US",
                    createdAt: Date(),
                    markerOffsets: []
                )
                _ = store.createProject(
                    from: RecordingDraft(
                        projectTitle: "Arrived during fetch",
                        tag: .appIdea,
                        source: .watch,
                        durationSeconds: recording.durationSeconds,
                        transcriptHint: "Wait for upload.",
                        localAudioPath: recording.localAudioPath,
                        languageHint: recording.languageHint,
                        ideaProjectID: recording.ideaProjectID,
                        recordingID: recording.id
                    ),
                    transcript: Transcript(cleanText: "Wait for upload.", segments: [], unclearFragments: []),
                    recording: recording
                )
            }
        )
        let engine = WorkspaceSyncEngine(
            client: BackendWorkspaceSyncClient(
                configuration: BackendSyncConfiguration(
                    baseURL: URL(string: "https://api.example.test")!,
                    bearerToken: "sync-token",
                    workspaceID: "workspace_alpha"
                ),
                transport: transport
            )
        )

        do {
            _ = try await engine.synchronize(store: store, syncedAt: Date().addingTimeInterval(120))
            XCTFail("Expected the upload arriving during fetch to block publication.")
        } catch let error as WorkspaceSyncPublicationBlockedError {
            XCTAssertTrue(error.message.contains("upload work"))
        }
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.map(\.httpMethod), ["GET"])
        XCTAssertEqual(store.activeUploadJobs.map(\.recordingID), ["rec_arrived_during_fetch"])
    }

    func testBackendWorkspaceSyncClientRejectsReceiptForDifferentWorkspace() async throws {
        let receipt = WorkspaceSyncPushReceipt(
            workspaceID: "workspace_other",
            acceptedUpdatedAt: SampleData.now
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let client = BackendWorkspaceSyncClient(
            configuration: BackendSyncConfiguration(
                baseURL: URL(string: "https://api.example.test")!,
                bearerToken: "sync-token",
                workspaceID: "workspace_alpha"
            ),
            transport: CapturingHTTPRequestTransport(
                responseData: try encoder.encode(receipt),
                statusCode: 200
            )
        )

        do {
            _ = try await client.pushWorkspaceSnapshot(.fresh(), baseRemoteUpdatedAt: nil)
            XCTFail("Expected a mismatched workspace receipt to fail closed.")
        } catch {
            XCTAssertEqual(error as? BackendSyncError, .invalidResponse)
        }
    }

    @MainActor
    func testWorkspaceSyncEngineFetchesRemoteAndFailsClosedWhenPublishRevisionIsStale() async throws {
        let localUpdatedAt = Date(timeIntervalSince1970: 2_000)
        let remoteUpdatedAt = Date(timeIntervalSince1970: 3_000)
        let syncedAt = Date(timeIntervalSince1970: 3_100)
        let repository = InMemoryWorkspaceRepository()
        let store = IdeaForgeStore(state: WorkspaceState.seed(), repository: repository)
        store.syncHealth.lastRemoteWorkspaceUpdatedAt = Date(timeIntervalSince1970: 1_000)
        store.save(now: localUpdatedAt)

        var remoteState = WorkspaceState.seed()
        remoteState.updatedAt = remoteUpdatedAt
        remoteState.projects = []
        remoteState.selectedProjectID = nil
        remoteState.uploadJobs = []
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let transport = SequencedHTTPRequestTransport(responses: [
            HTTPTestResponse(data: Data(#"{"error":"workspace_revision_conflict"}"#.utf8), statusCode: 409),
            HTTPTestResponse(data: try encoder.encode(remoteState), statusCode: 200)
        ])
        let engine = WorkspaceSyncEngine(
            client: BackendWorkspaceSyncClient(
                configuration: BackendSyncConfiguration(
                    baseURL: URL(string: "https://api.example.test")!,
                    bearerToken: "sync-token",
                    workspaceID: "workspace_alpha"
                ),
                transport: transport
            )
        )

        do {
            _ = try await engine.pushLocalSnapshot(from: store, syncedAt: syncedAt)
            XCTFail("Expected stale publish to fail closed.")
        } catch let conflict as WorkspaceSyncConflictError {
            let requests = await transport.capturedRequests()
            XCTAssertEqual(requests.map(\.httpMethod), ["PUT", "GET"])
            XCTAssertEqual(conflict.report.localOnlyRecordingIDs.sorted(), ["rec_phone_1", "rec_watch_2"])
            XCTAssertEqual(store.syncHealth.syncConflictStatus?.message, "Remote workspace snapshot would overwrite 2 local recordings.")
            XCTAssertEqual(store.lastErrorMessage, "Remote workspace snapshot would overwrite 2 local recordings.")
            XCTAssertEqual(store.syncHealth.lastSuccessfulSync, syncedAt)
            XCTAssertEqual(store.syncHealth.lastRemoteWorkspaceUpdatedAt, remoteUpdatedAt)
        }
    }

    @MainActor
    func testWorkspaceSyncEngineFailsClosedWhenNewerRemoteWouldDropLocalUploadWork() async throws {
        let localUpdatedAt = Date(timeIntervalSince1970: 1_000)
        let remoteUpdatedAt = Date(timeIntervalSince1970: 2_000)
        let syncedAt = Date(timeIntervalSince1970: 3_000)
        let repository = InMemoryWorkspaceRepository()
        let store = IdeaForgeStore(state: WorkspaceState.seed(), repository: repository)
        let localRecording = Recording(
            id: "rec_local_pending",
            ideaProjectID: "idea_local_pending",
            deviceName: "Apple Watch",
            durationSeconds: 42,
            localFileStatus: .available,
            syncStatus: .transferredToIPhone,
            localAudioPath: "recordings/local-pending.m4a",
            languageHint: "en-US",
            createdAt: localUpdatedAt,
            markerOffsets: [12]
        )
        let localProject = IdeaProject(
            id: "idea_local_pending",
            title: "Local pending idea",
            status: .inbox,
            source: .watch,
            createdAt: localUpdatedAt,
            updatedAt: localUpdatedAt,
            summary: "Local pending summary.",
            tags: [.appIdea],
            score: IdeaScore(confidence: 0.4, completeness: 0.2, risk: 0.6),
            transcript: Transcript(cleanText: "Local pending summary.", segments: [], unclearFragments: []),
            recordings: [localRecording],
            questions: [],
            artifacts: [],
            assumptions: [],
            validationExperiments: [],
            codexTasks: []
        )
        store.projects = [localProject]
        store.uploadJobs = [
            UploadQueuePolicy.job(
                for: localRecording,
                localAudioPath: "recordings/local-pending.m4a",
                now: localUpdatedAt
            )
        ]
        store.selectedProjectID = localProject.id
        store.updatedAt = localUpdatedAt
        store.syncHealth.queuedUploads = store.activeUploadJobs.count

        let remoteState = WorkspaceState(
            projects: [
                IdeaProject(
                    id: "idea_remote",
                    title: "Remote Idea",
                    status: .draft,
                    source: .mac,
                    createdAt: remoteUpdatedAt,
                    updatedAt: remoteUpdatedAt,
                    summary: "Remote backend summary.",
                    tags: [.business],
                    score: IdeaScore(confidence: 0.8, completeness: 0.7, risk: 0.2),
                    transcript: Transcript(cleanText: "Remote backend summary.", segments: [], unclearFragments: []),
                    recordings: [],
                    questions: [],
                    artifacts: [],
                    assumptions: [],
                    validationExperiments: [],
                    codexTasks: []
                )
            ],
            workflowTemplates: DefaultWorkflows.templates,
            uploadJobs: [],
            privacyMode: .standardCloud,
            syncHealth: SyncHealth(
                watchReachable: false,
                queuedUploads: 0,
                lastSuccessfulSync: localUpdatedAt,
                failingItems: 0
            ),
            selectedProjectID: "idea_remote",
            updatedAt: remoteUpdatedAt
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let engine = WorkspaceSyncEngine(
            client: BackendWorkspaceSyncClient(
                configuration: BackendSyncConfiguration(
                    baseURL: URL(string: "https://api.example.test")!,
                    bearerToken: "sync-token",
                    workspaceID: "workspace_alpha"
                ),
                transport: CapturingHTTPRequestTransport(
                    responseData: try encoder.encode(remoteState),
                    statusCode: 200
                )
            )
        )

        do {
            _ = try await engine.pullLatest(into: store, syncedAt: syncedAt)
            XCTFail("Expected sync conflict to fail closed before overwriting local upload work.")
        } catch let error as WorkspaceSyncConflictError {
            XCTAssertEqual(error.report.localOnlyUploadJobIDs, ["upload_rec_local_pending"])
            XCTAssertEqual(error.report.localOnlyRecordingIDs, ["rec_local_pending"])
            XCTAssertEqual(error.report.message, "Remote workspace snapshot would overwrite 1 local upload job and 1 local recording.")
        }

        XCTAssertEqual(store.projects.first?.id, "idea_local_pending")
        XCTAssertEqual(store.uploadJobs.first?.recordingID, "rec_local_pending")
        XCTAssertEqual(store.syncHealth.queuedUploads, 1)
        XCTAssertEqual(store.syncHealth.lastSuccessfulSync, syncedAt)
        XCTAssertEqual(store.syncHealth.syncConflictStatus?.localOnlyUploadJobCount, 1)
        XCTAssertEqual(store.syncHealth.syncConflictStatus?.localOnlyRecordingCount, 1)
        XCTAssertEqual(store.syncHealth.syncConflictStatus?.detectedAt, syncedAt)
        XCTAssertEqual(store.syncHealth.syncConflictStatus?.message, "Remote workspace snapshot would overwrite 1 local upload job and 1 local recording.")
        XCTAssertEqual(store.syncHealth.syncConflictStatus?.recoveryAction, "Upload 1 local job and 1 local recording, then sync again.")
        let reviewItems = try XCTUnwrap(store.syncHealth.syncConflictStatus?.reviewItems)
        XCTAssertEqual(reviewItems.count, 2)
        XCTAssertEqual(reviewItems.map(\.kind), [.localUploadJob, .localRecording])
        XCTAssertEqual(reviewItems.map(\.projectTitle), ["Local pending idea", "Local pending idea"])
        XCTAssertEqual(reviewItems[0].statusLabel, "Queued")
        XCTAssertEqual(reviewItems[0].detail, "Apple Watch, 42s, attempt 0")
        XCTAssertEqual(reviewItems[1].statusLabel, "On iPhone")
        XCTAssertEqual(reviewItems[1].detail, "Apple Watch, 42s, available locally")
        let encodedConflictStatus = String(
            data: try JSONEncoder().encode(store.syncHealth.syncConflictStatus),
            encoding: .utf8
        )
        XCTAssertFalse(encodedConflictStatus?.contains("recordings/local-pending.m4a") == true)
        XCTAssertFalse(encodedConflictStatus?.localizedCaseInsensitiveContains("objectKey") == true)
        XCTAssertFalse(encodedConflictStatus?.localizedCaseInsensitiveContains("token") == true)
        XCTAssertEqual(store.lastErrorMessage, "Remote workspace snapshot would overwrite 1 local upload job and 1 local recording.")
        let saved = try XCTUnwrap(try repository.load())
        XCTAssertEqual(saved.syncHealth.syncConflictStatus?.recoveryAction, "Upload 1 local job and 1 local recording, then sync again.")
        XCTAssertEqual(saved.syncHealth.syncConflictStatus?.reviewItems.count, 2)
    }

    @MainActor
    func testWorkspaceSyncConflictRecoveryAppliesRemoteAndPreservesLocalUploadWork() async throws {
        let localUpdatedAt = Date(timeIntervalSince1970: 1_000)
        let remoteUpdatedAt = Date(timeIntervalSince1970: 2_000)
        let syncedAt = Date(timeIntervalSince1970: 3_000)
        let repository = InMemoryWorkspaceRepository()
        let store = IdeaForgeStore(state: WorkspaceState.seed(), repository: repository)
        let localRecording = Recording(
            id: "rec_local_pending",
            ideaProjectID: "idea_local_pending",
            deviceName: "Apple Watch",
            durationSeconds: 42,
            localFileStatus: .available,
            syncStatus: .transferredToIPhone,
            localAudioPath: "recordings/local-pending.m4a",
            languageHint: "en-US",
            createdAt: localUpdatedAt,
            markerOffsets: [12]
        )
        let localProject = IdeaProject(
            id: "idea_local_pending",
            title: "Local pending idea",
            status: .inbox,
            source: .watch,
            createdAt: localUpdatedAt,
            updatedAt: localUpdatedAt,
            summary: "Local pending summary.",
            tags: [.appIdea],
            score: IdeaScore(confidence: 0.4, completeness: 0.2, risk: 0.6),
            transcript: Transcript(cleanText: "Local pending summary.", segments: [], unclearFragments: []),
            recordings: [localRecording],
            questions: [],
            artifacts: [],
            assumptions: [],
            validationExperiments: [],
            codexTasks: []
        )
        store.projects = [localProject]
        store.uploadJobs = [
            UploadQueuePolicy.job(
                for: localRecording,
                localAudioPath: "recordings/local-pending.m4a",
                now: localUpdatedAt
            )
        ]
        store.selectedProjectID = localProject.id
        store.updatedAt = localUpdatedAt
        store.syncHealth.queuedUploads = store.activeUploadJobs.count
        store.syncHealth.syncConflictStatus = WorkspaceSyncConflictStatus(
            localOnlyUploadJobCount: 1,
            localOnlyRecordingCount: 1,
            detectedAt: localUpdatedAt
        )

        let remoteProject = IdeaProject(
            id: "idea_remote",
            title: "Remote Idea",
            status: .draft,
            source: .mac,
            createdAt: remoteUpdatedAt,
            updatedAt: remoteUpdatedAt,
            summary: "Remote backend summary.",
            tags: [.business],
            score: IdeaScore(confidence: 0.8, completeness: 0.7, risk: 0.2),
            transcript: Transcript(cleanText: "Remote backend summary.", segments: [], unclearFragments: []),
            recordings: [],
            questions: [],
            artifacts: [],
            assumptions: [],
            validationExperiments: [],
            codexTasks: []
        )
        let remoteState = WorkspaceState(
            projects: [remoteProject],
            workflowTemplates: DefaultWorkflows.templates,
            uploadJobs: [],
            privacyMode: .standardCloud,
            syncHealth: SyncHealth(
                watchReachable: false,
                queuedUploads: 0,
                lastSuccessfulSync: localUpdatedAt,
                failingItems: 0
            ),
            selectedProjectID: "idea_remote",
            updatedAt: remoteUpdatedAt
        )

        let applied = try store.applyRemoteWorkspaceSnapshot(
            remoteState,
            syncedAt: syncedAt,
            conflictResolution: .preserveLocalUploadWork
        )

        XCTAssertTrue(applied)
        XCTAssertEqual(store.projects.map(\.id).sorted(), ["idea_local_pending", "idea_remote"])
        XCTAssertEqual(store.projects.first { $0.id == "idea_remote" }?.summary, "Remote backend summary.")
        let preservedProject = try XCTUnwrap(store.projects.first { $0.id == "idea_local_pending" })
        XCTAssertEqual(preservedProject.recordings.first?.localAudioPath, "recordings/local-pending.m4a")
        XCTAssertEqual(preservedProject.recordings.first?.syncStatus, .transferredToIPhone)
        XCTAssertEqual(store.uploadJobs.first?.recordingID, "rec_local_pending")
        XCTAssertEqual(store.uploadJobs.first?.status, .queued)
        XCTAssertEqual(store.syncHealth.queuedUploads, 1)
        XCTAssertNil(store.syncHealth.syncConflictStatus)
        XCTAssertEqual(store.syncHealth.lastSuccessfulSync, syncedAt)
        XCTAssertEqual(store.selectedProjectID, "idea_remote")
        XCTAssertEqual(store.privacyMode, .standardCloud)
        XCTAssertEqual(store.updatedAt, syncedAt)
        XCTAssertEqual(store.syncHealth.lastRemoteWorkspaceUpdatedAt, remoteUpdatedAt)

        let saved = try XCTUnwrap(try repository.load())
        XCTAssertEqual(saved.projects.map(\.id).sorted(), ["idea_local_pending", "idea_remote"])
        XCTAssertEqual(saved.uploadJobs.first?.recordingID, "rec_local_pending")
        XCTAssertNil(saved.syncHealth.syncConflictStatus)
    }

    @MainActor
    func testReviewedWorkspaceSyncConflictMergePreservesOnlySelectedLocalItems() throws {
        let localUpdatedAt = Date(timeIntervalSince1970: 1_000)
        let remoteUpdatedAt = Date(timeIntervalSince1970: 2_000)
        let syncedAt = Date(timeIntervalSince1970: 3_000)
        let repository = InMemoryWorkspaceRepository()
        let store = IdeaForgeStore(state: WorkspaceState.seed(), repository: repository)
        let keptRecording = Recording(
            id: "rec_keep",
            ideaProjectID: "idea_local_pending",
            deviceName: "Apple Watch",
            durationSeconds: 90,
            localFileStatus: .available,
            syncStatus: .transferredToIPhone,
            localAudioPath: "recordings/keep.m4a",
            languageHint: "en-US",
            createdAt: localUpdatedAt,
            markerOffsets: []
        )
        let discardedRecording = Recording(
            id: "rec_discard",
            ideaProjectID: "idea_local_pending",
            deviceName: "Apple Watch",
            durationSeconds: 45,
            localFileStatus: .available,
            syncStatus: .transferredToIPhone,
            localAudioPath: "recordings/discard.m4a",
            languageHint: "en-US",
            createdAt: localUpdatedAt,
            markerOffsets: []
        )
        let localProject = IdeaProject(
            id: "idea_local_pending",
            title: "Local pending idea",
            status: .inbox,
            source: .watch,
            createdAt: localUpdatedAt,
            updatedAt: localUpdatedAt,
            summary: "Local pending summary.",
            tags: [.appIdea],
            score: IdeaScore(confidence: 0.4, completeness: 0.2, risk: 0.6),
            transcript: Transcript(cleanText: "Local pending summary.", segments: [], unclearFragments: []),
            recordings: [keptRecording, discardedRecording],
            questions: [],
            artifacts: [],
            assumptions: [],
            validationExperiments: [],
            codexTasks: []
        )
        store.projects = [localProject]
        store.uploadJobs = [
            UploadQueuePolicy.job(for: keptRecording, localAudioPath: "recordings/keep.m4a", now: localUpdatedAt),
            UploadQueuePolicy.job(for: discardedRecording, localAudioPath: "recordings/discard.m4a", now: localUpdatedAt)
        ]
        store.selectedProjectID = localProject.id
        store.updatedAt = localUpdatedAt
        store.syncHealth.queuedUploads = store.activeUploadJobs.count

        let remoteProject = IdeaProject(
            id: "idea_remote",
            title: "Remote Idea",
            status: .draft,
            source: .mac,
            createdAt: remoteUpdatedAt,
            updatedAt: remoteUpdatedAt,
            summary: "Remote backend summary.",
            tags: [.business],
            score: IdeaScore(confidence: 0.8, completeness: 0.7, risk: 0.2),
            transcript: Transcript(cleanText: "Remote backend summary.", segments: [], unclearFragments: []),
            recordings: [],
            questions: [],
            artifacts: [],
            assumptions: [],
            validationExperiments: [],
            codexTasks: []
        )
        let remoteState = WorkspaceState(
            projects: [remoteProject],
            workflowTemplates: DefaultWorkflows.templates,
            uploadJobs: [],
            privacyMode: .standardCloud,
            syncHealth: SyncHealth(
                watchReachable: false,
                queuedUploads: 0,
                lastSuccessfulSync: localUpdatedAt,
                failingItems: 0
            ),
            selectedProjectID: "idea_remote",
            updatedAt: remoteUpdatedAt
        )

        XCTAssertThrowsError(try store.applyRemoteWorkspaceSnapshot(remoteState, syncedAt: syncedAt)) { error in
            XCTAssertTrue(error is WorkspaceSyncConflictError)
        }
        let conflictStatus = try XCTUnwrap(store.syncHealth.syncConflictStatus)
        let selection = WorkspaceSyncConflictMergeSelection(
            selectedReviewItemIDs: ["upload:upload_rec_keep"],
            reviewItems: conflictStatus.reviewItems
        )

        XCTAssertEqual(selection.uploadJobIDsToPreserve, ["upload_rec_keep"])
        XCTAssertEqual(selection.recordingIDsToPreserve, ["rec_keep"])

        let applied = try store.applyRemoteWorkspaceSnapshot(
            remoteState,
            syncedAt: syncedAt.addingTimeInterval(60),
            conflictResolution: .preserveReviewedLocalWork(selection)
        )

        XCTAssertTrue(applied)
        XCTAssertEqual(store.projects.map(\.id).sorted(), ["idea_local_pending", "idea_remote"])
        let preservedProject = try XCTUnwrap(store.projects.first { $0.id == "idea_local_pending" })
        XCTAssertEqual(preservedProject.recordings.map(\.id), ["rec_keep"])
        XCTAssertFalse(preservedProject.recordings.map(\.id).contains("rec_discard"))
        XCTAssertEqual(store.uploadJobs.map(\.id), ["upload_rec_keep"])
        XCTAssertFalse(store.uploadJobs.map(\.id).contains("upload_rec_discard"))
        XCTAssertNil(store.syncHealth.syncConflictStatus)

        let saved = try XCTUnwrap(try repository.load())
        XCTAssertEqual(saved.projects.first { $0.id == "idea_local_pending" }?.recordings.map(\.id), ["rec_keep"])
        XCTAssertEqual(saved.uploadJobs.map(\.id), ["upload_rec_keep"])
    }

    @MainActor
    func testWorkspaceSyncFailsClosedWhenProjectContentChangedOnBothSides() throws {
        let lastSyncedAt = Date(timeIntervalSince1970: 900)
        let localUpdatedAt = Date(timeIntervalSince1970: 1_000)
        let remoteUpdatedAt = Date(timeIntervalSince1970: 2_000)
        let syncedAt = Date(timeIntervalSince1970: 3_000)
        let repository = InMemoryWorkspaceRepository()
        let store = IdeaForgeStore(state: WorkspaceState.seed(), repository: repository)
        let localProject = IdeaProject(
            id: "idea_shared",
            title: "Shared Idea",
            status: .draft,
            source: .mac,
            createdAt: lastSyncedAt,
            updatedAt: localUpdatedAt,
            summary: "Local edited private summary.",
            tags: [.appIdea, .research],
            score: IdeaScore(confidence: 0.7, completeness: 0.5, risk: 0.4),
            transcript: Transcript(cleanText: "Local transcript private text.", segments: [], unclearFragments: []),
            recordings: [],
            questions: [],
            artifacts: [
                Artifact(
                    id: "artifact_local",
                    kind: .prd,
                    title: "Local PRD",
                    markdown: "# Local private PRD",
                    version: 2,
                    createdBy: "Manual edit",
                    createdAt: localUpdatedAt
                )
            ],
            assumptions: [],
            validationExperiments: [],
            codexTasks: []
        )
        store.projects = [localProject]
        store.selectedProjectID = localProject.id
        store.updatedAt = localUpdatedAt
        store.syncHealth.lastSuccessfulSync = lastSyncedAt

        let remoteProject = IdeaProject(
            id: "idea_shared",
            title: "Shared Idea",
            status: .readyForBuild,
            source: .mac,
            createdAt: lastSyncedAt,
            updatedAt: remoteUpdatedAt,
            summary: "Remote edited summary.",
            tags: [.business],
            score: IdeaScore(confidence: 0.9, completeness: 0.9, risk: 0.2),
            transcript: Transcript(cleanText: "Remote transcript text.", segments: [], unclearFragments: []),
            recordings: [],
            questions: [],
            artifacts: [
                Artifact(
                    id: "artifact_remote",
                    kind: .prd,
                    title: "Remote PRD",
                    markdown: "# Remote PRD",
                    version: 3,
                    createdBy: "Backend",
                    createdAt: remoteUpdatedAt
                )
            ],
            assumptions: [],
            validationExperiments: [],
            codexTasks: []
        )
        let remoteState = WorkspaceState(
            projects: [remoteProject],
            workflowTemplates: DefaultWorkflows.templates,
            uploadJobs: [],
            privacyMode: .standardCloud,
            syncHealth: SyncHealth(
                watchReachable: false,
                queuedUploads: 0,
                lastSuccessfulSync: lastSyncedAt,
                failingItems: 0
            ),
            selectedProjectID: "idea_shared",
            updatedAt: remoteUpdatedAt
        )

        XCTAssertThrowsError(try store.applyRemoteWorkspaceSnapshot(remoteState, syncedAt: syncedAt)) { error in
            guard let conflictError = error as? WorkspaceSyncConflictError else {
                return XCTFail("Expected workspace sync conflict error.")
            }
            XCTAssertEqual(conflictError.report.localOnlyUploadJobIDs, [])
            XCTAssertEqual(conflictError.report.localOnlyRecordingIDs, [])
            XCTAssertEqual(conflictError.report.projectContentConflicts.map(\.projectID), ["idea_shared"])
            XCTAssertEqual(
                conflictError.report.projectContentConflicts.first?.fields,
                [.status, .summary, .tags, .score, .transcript, .artifacts]
            )
        }

        let conflictStatus = try XCTUnwrap(store.syncHealth.syncConflictStatus)
        XCTAssertEqual(conflictStatus.localProjectContentConflictCount, 1)
        XCTAssertEqual(conflictStatus.reviewItems.filter { $0.kind == .projectContent }.count, 6)
        let statusReview = try XCTUnwrap(
            conflictStatus.reviewItems.first { $0.id == "project:idea_shared:status" }
        )
        XCTAssertEqual(statusReview.fieldDiffPreview?.localValue, "Draft")
        XCTAssertEqual(statusReview.fieldDiffPreview?.remoteValue, "Ready for Build")
        XCTAssertTrue(statusReview.fieldDiffPreview?.changeSummary.contains("on-device status") == true)
        let summaryReview = try XCTUnwrap(
            conflictStatus.reviewItems.first { $0.id == "project:idea_shared:summary" }
        )
        XCTAssertEqual(summaryReview.fieldDiffPreview?.localValue, "\"Local edited private summary.\"")
        XCTAssertEqual(summaryReview.fieldDiffPreview?.remoteValue, "\"Remote edited summary.\"")
        let transcriptReview = try XCTUnwrap(
            conflictStatus.reviewItems.first { $0.id == "project:idea_shared:transcript" }
        )
        XCTAssertTrue(transcriptReview.fieldDiffPreview?.localValue.contains("fingerprint") == true)
        XCTAssertFalse(transcriptReview.fieldDiffPreview?.localValue.contains("Local transcript private text.") == true)
        let artifactReview = try XCTUnwrap(
            conflictStatus.reviewItems.first { $0.id == "project:idea_shared:artifacts" }
        )
        XCTAssertTrue(artifactReview.fieldDiffPreview?.localValue.contains("content fingerprint") == true)
        XCTAssertFalse(artifactReview.fieldDiffPreview?.localValue.contains("# Local private PRD") == true)
        XCTAssertTrue(conflictStatus.message.contains("1 project content conflict"))
        XCTAssertTrue(conflictStatus.recoveryAction.localizedCaseInsensitiveContains("review project fields"))
        let encodedConflictStatus = String(
            data: try JSONEncoder().encode(conflictStatus),
            encoding: .utf8
        )
        XCTAssertFalse(encodedConflictStatus?.contains("Local transcript private text.") == true)
        XCTAssertFalse(encodedConflictStatus?.contains("# Local private PRD") == true)
        XCTAssertFalse(encodedConflictStatus?.localizedCaseInsensitiveContains("token") == true)
        XCTAssertEqual(store.selectedProject?.summary, "Local edited private summary.")
        XCTAssertEqual(store.lastErrorMessage, "Remote workspace snapshot would overwrite 1 project content conflict.")
    }

    @MainActor
    func testReviewedProjectContentMergePreservesOnlySelectedLocalFields() throws {
        let lastSyncedAt = Date(timeIntervalSince1970: 900)
        let localUpdatedAt = Date(timeIntervalSince1970: 1_000)
        let remoteUpdatedAt = Date(timeIntervalSince1970: 2_000)
        let syncedAt = Date(timeIntervalSince1970: 3_000)
        let repository = InMemoryWorkspaceRepository()
        let store = IdeaForgeStore(state: WorkspaceState.seed(), repository: repository)
        let localArtifact = Artifact(
            id: "artifact_local",
            kind: .prd,
            title: "Local PRD",
            markdown: "# Local PRD",
            version: 2,
            createdBy: "Manual edit",
            createdAt: localUpdatedAt
        )
        let localProject = IdeaProject(
            id: "idea_shared",
            title: "Local Title",
            status: .draft,
            source: .mac,
            createdAt: lastSyncedAt,
            updatedAt: localUpdatedAt,
            summary: "Local summary.",
            tags: [.research],
            score: IdeaScore(confidence: 0.6, completeness: 0.4, risk: 0.5),
            transcript: Transcript(cleanText: "Local transcript.", segments: [], unclearFragments: []),
            recordings: [],
            questions: [],
            artifacts: [localArtifact],
            assumptions: [],
            validationExperiments: [],
            codexTasks: []
        )
        store.projects = [localProject]
        store.selectedProjectID = localProject.id
        store.updatedAt = localUpdatedAt
        store.syncHealth.lastSuccessfulSync = lastSyncedAt

        let remoteArtifact = Artifact(
            id: "artifact_remote",
            kind: .prd,
            title: "Remote PRD",
            markdown: "# Remote PRD",
            version: 3,
            createdBy: "Backend",
            createdAt: remoteUpdatedAt
        )
        let remoteProject = IdeaProject(
            id: "idea_shared",
            title: "Remote Title",
            status: .readyForBuild,
            source: .mac,
            createdAt: lastSyncedAt,
            updatedAt: remoteUpdatedAt,
            summary: "Remote summary.",
            tags: [.business],
            score: IdeaScore(confidence: 0.9, completeness: 0.9, risk: 0.2),
            transcript: Transcript(cleanText: "Remote transcript.", segments: [], unclearFragments: []),
            recordings: [],
            questions: [],
            artifacts: [remoteArtifact],
            assumptions: [],
            validationExperiments: [],
            codexTasks: []
        )
        let remoteState = WorkspaceState(
            projects: [remoteProject],
            workflowTemplates: DefaultWorkflows.templates,
            uploadJobs: [],
            privacyMode: .standardCloud,
            syncHealth: SyncHealth(
                watchReachable: false,
                queuedUploads: 0,
                lastSuccessfulSync: lastSyncedAt,
                failingItems: 0
            ),
            selectedProjectID: "idea_shared",
            updatedAt: remoteUpdatedAt
        )

        XCTAssertThrowsError(try store.applyRemoteWorkspaceSnapshot(remoteState, syncedAt: syncedAt))
        let conflictStatus = try XCTUnwrap(store.syncHealth.syncConflictStatus)
        let selection = WorkspaceSyncConflictMergeSelection(
            selectedReviewItemIDs: [
                "project:idea_shared:summary",
                "project:idea_shared:artifacts"
            ],
            reviewItems: conflictStatus.reviewItems
        )

        XCTAssertEqual(
            selection.projectFieldsToPreserve,
            [
                WorkspaceSyncProjectFieldSelection(projectID: "idea_shared", field: .artifacts),
                WorkspaceSyncProjectFieldSelection(projectID: "idea_shared", field: .summary)
            ]
        )

        let applied = try store.applyRemoteWorkspaceSnapshot(
            remoteState,
            syncedAt: syncedAt.addingTimeInterval(60),
            conflictResolution: .preserveReviewedLocalWork(selection)
        )

        XCTAssertTrue(applied)
        let mergedProject = try XCTUnwrap(store.projects.first { $0.id == "idea_shared" })
        XCTAssertEqual(mergedProject.title, "Remote Title")
        XCTAssertEqual(mergedProject.status, .readyForBuild)
        XCTAssertEqual(mergedProject.summary, "Local summary.")
        XCTAssertEqual(mergedProject.tags, [.business])
        XCTAssertEqual(mergedProject.transcript.cleanText, "Remote transcript.")
        XCTAssertEqual(mergedProject.artifacts.map(\.id), ["artifact_local"])
        XCTAssertEqual(mergedProject.updatedAt, remoteUpdatedAt)
        XCTAssertNil(store.syncHealth.syncConflictStatus)
    }

    @MainActor
    func testReviewedProjectContentMergePreservesSelectedLocalArtifactItems() throws {
        let lastSyncedAt = Date(timeIntervalSince1970: 900)
        let localUpdatedAt = Date(timeIntervalSince1970: 2_000)
        let remoteUpdatedAt = Date(timeIntervalSince1970: 2_500)
        let syncedAt = Date(timeIntervalSince1970: 3_000)
        let repository = InMemoryWorkspaceRepository()
        let store = IdeaForgeStore(state: WorkspaceState.seed(), repository: repository)
        let localSharedArtifact = Artifact(
            id: "artifact_shared",
            kind: .prd,
            title: "Shared PRD",
            markdown: "# Local reviewed PRD",
            version: 4,
            createdBy: "Manual edit",
            createdAt: localUpdatedAt
        )
        let localOnlyArtifact = Artifact(
            id: "artifact_local_only",
            kind: .architecture,
            title: "Local Architecture",
            markdown: "# Local architecture notes",
            version: 1,
            createdBy: "Manual edit",
            createdAt: localUpdatedAt.addingTimeInterval(-20)
        )
        let localProject = IdeaProject(
            id: "idea_shared",
            title: "Shared Idea",
            status: .validated,
            source: .mac,
            createdAt: lastSyncedAt,
            updatedAt: localUpdatedAt,
            summary: "Shared summary.",
            tags: [.appIdea],
            score: IdeaScore(confidence: 0.7, completeness: 0.8, risk: 0.2),
            transcript: Transcript(cleanText: "Shared transcript.", segments: [], unclearFragments: []),
            recordings: [],
            questions: [],
            artifacts: [localSharedArtifact, localOnlyArtifact],
            assumptions: [],
            validationExperiments: [],
            codexTasks: []
        )
        store.projects = [localProject]
        store.selectedProjectID = localProject.id
        store.updatedAt = localUpdatedAt
        store.syncHealth.lastSuccessfulSync = lastSyncedAt

        let remoteSharedArtifact = Artifact(
            id: "artifact_shared",
            kind: .prd,
            title: "Shared PRD",
            markdown: "# Remote generated PRD",
            version: 5,
            createdBy: "Backend",
            createdAt: remoteUpdatedAt
        )
        let remoteOnlyArtifact = Artifact(
            id: "artifact_remote_only",
            kind: .codexTaskBundle,
            title: "Remote Codex Tasks",
            markdown: "# Remote task bundle",
            version: 1,
            createdBy: "Backend",
            createdAt: remoteUpdatedAt.addingTimeInterval(-10)
        )
        let remoteProject = IdeaProject(
            id: "idea_shared",
            title: "Shared Idea",
            status: .validated,
            source: .mac,
            createdAt: lastSyncedAt,
            updatedAt: remoteUpdatedAt,
            summary: "Shared summary.",
            tags: [.appIdea],
            score: IdeaScore(confidence: 0.7, completeness: 0.8, risk: 0.2),
            transcript: Transcript(cleanText: "Shared transcript.", segments: [], unclearFragments: []),
            recordings: [],
            questions: [],
            artifacts: [remoteSharedArtifact, remoteOnlyArtifact],
            assumptions: [],
            validationExperiments: [],
            codexTasks: []
        )
        let remoteState = WorkspaceState(
            projects: [remoteProject],
            workflowTemplates: DefaultWorkflows.templates,
            uploadJobs: [],
            privacyMode: .standardCloud,
            syncHealth: SyncHealth(
                watchReachable: false,
                queuedUploads: 0,
                lastSuccessfulSync: lastSyncedAt,
                failingItems: 0
            ),
            selectedProjectID: "idea_shared",
            updatedAt: remoteUpdatedAt
        )

        XCTAssertThrowsError(try store.applyRemoteWorkspaceSnapshot(remoteState, syncedAt: syncedAt))
        let conflictStatus = try XCTUnwrap(store.syncHealth.syncConflictStatus)
        let artifactReviewItems = conflictStatus.reviewItems.filter { $0.kind == .projectArtifact }
        XCTAssertEqual(
            artifactReviewItems.map(\.id),
            [
                "project:idea_shared:artifacts:item:artifact_local_only",
                "project:idea_shared:artifacts:item:artifact_shared"
            ]
        )
        let encodedConflictStatus = String(data: try JSONEncoder().encode(conflictStatus), encoding: .utf8)
        XCTAssertFalse(encodedConflictStatus?.contains("# Local reviewed PRD") == true)
        XCTAssertFalse(encodedConflictStatus?.contains("# Local architecture notes") == true)

        let selection = WorkspaceSyncConflictMergeSelection(
            selectedReviewItemIDs: [
                "project:idea_shared:artifacts:item:artifact_shared",
                "project:idea_shared:artifacts:item:artifact_local_only"
            ],
            reviewItems: conflictStatus.reviewItems
        )

        XCTAssertEqual(
            selection.projectArtifactsToPreserve,
            [
                WorkspaceSyncProjectArtifactSelection(projectID: "idea_shared", artifactID: "artifact_local_only"),
                WorkspaceSyncProjectArtifactSelection(projectID: "idea_shared", artifactID: "artifact_shared")
            ]
        )
        XCTAssertEqual(selection.projectFieldsToPreserve, [])

        let applied = try store.applyRemoteWorkspaceSnapshot(
            remoteState,
            syncedAt: syncedAt.addingTimeInterval(60),
            conflictResolution: .preserveReviewedLocalWork(selection)
        )

        XCTAssertTrue(applied)
        let mergedProject = try XCTUnwrap(store.projects.first { $0.id == "idea_shared" })
        XCTAssertEqual(
            mergedProject.artifacts.map(\.id),
            ["artifact_shared", "artifact_local_only", "artifact_remote_only"]
        )
        XCTAssertEqual(mergedProject.artifacts.first { $0.id == "artifact_shared" }?.markdown, "# Local reviewed PRD")
        XCTAssertEqual(mergedProject.artifacts.first { $0.id == "artifact_local_only" }?.markdown, "# Local architecture notes")
        XCTAssertEqual(mergedProject.artifacts.first { $0.id == "artifact_remote_only" }?.markdown, "# Remote task bundle")
        XCTAssertEqual(mergedProject.updatedAt, remoteUpdatedAt)
        XCTAssertNil(store.syncHealth.syncConflictStatus)
    }

    @MainActor
    func testReviewedProjectContentMergePreservesSelectedLocalCollectionItems() throws {
        let lastSyncedAt = Date(timeIntervalSince1970: 900)
        let localUpdatedAt = Date(timeIntervalSince1970: 2_000)
        let remoteUpdatedAt = Date(timeIntervalSince1970: 2_500)
        let syncedAt = Date(timeIntervalSince1970: 3_000)
        let repository = InMemoryWorkspaceRepository()
        let store = IdeaForgeStore(state: WorkspaceState.seed(), repository: repository)
        let localRunArtifact = Artifact(
            id: "artifact_shared_run",
            kind: .architecture,
            title: "Local Run Architecture",
            markdown: "# Local run architecture",
            version: 2,
            createdBy: "Manual workflow",
            createdAt: localUpdatedAt,
            sourceWorkflowRunID: "run_shared"
        )
        let localProject = IdeaProject(
            id: "idea_shared",
            title: "Shared Idea",
            status: .validated,
            source: .mac,
            createdAt: lastSyncedAt,
            updatedAt: localUpdatedAt,
            summary: "Shared summary.",
            tags: [.appIdea],
            score: IdeaScore(confidence: 0.7, completeness: 0.8, risk: 0.2),
            transcript: Transcript(cleanText: "Shared transcript.", segments: [], unclearFragments: []),
            recordings: [],
            questions: [
                Question(id: "question_shared", prompt: "Local private question prompt", answer: "Local answer", isBlocking: false),
                Question(id: "question_local_only", prompt: "Local only private question", answer: nil, isBlocking: true)
            ],
            artifacts: [localRunArtifact],
            assumptions: [
                Assumption(id: "assumption_shared", text: "Local private assumption", confidence: 0.8, evidence: "Local private evidence"),
                Assumption(id: "assumption_local_only", text: "Local only assumption", confidence: 0.6, evidence: "Local only evidence")
            ],
            validationExperiments: [
                ValidationExperiment(id: "experiment_shared", title: "Local experiment", metric: "Local metric", goNoGoCriteria: "Local criteria"),
                ValidationExperiment(id: "experiment_local_only", title: "Local only experiment", metric: "Local only metric", goNoGoCriteria: "Local only criteria")
            ],
            codexTasks: [
                CodexTask(id: "task_shared", title: "Local Codex task", acceptanceCriteria: ["Local AC"], testPlan: ["Local test"]),
                CodexTask(id: "task_local_only", title: "Local only Codex task", acceptanceCriteria: ["Local only AC"], testPlan: ["Local only test"])
            ],
            workflowRuns: [
                WorkflowRun(
                    id: "run_shared",
                    templateID: "template_architecture",
                    templateName: "Local Architecture Run",
                    status: .completed,
                    stepRuns: [],
                    artifactIDs: ["artifact_shared_run"],
                    startedAt: localUpdatedAt.addingTimeInterval(-100),
                    completedAt: localUpdatedAt
                ),
                WorkflowRun(
                    id: "run_local_only",
                    templateID: "template_validation",
                    templateName: "Local Validation Run",
                    status: .failed,
                    stepRuns: [],
                    artifactIDs: [],
                    startedAt: localUpdatedAt.addingTimeInterval(-50),
                    completedAt: localUpdatedAt,
                    errorMessage: "Local failure"
                )
            ]
        )
        store.projects = [localProject]
        store.selectedProjectID = localProject.id
        store.updatedAt = localUpdatedAt
        store.syncHealth.lastSuccessfulSync = lastSyncedAt

        let remoteRunArtifact = Artifact(
            id: "artifact_shared_run",
            kind: .architecture,
            title: "Remote Run Architecture",
            markdown: "# Remote run architecture",
            version: 3,
            createdBy: "Backend workflow",
            createdAt: remoteUpdatedAt,
            sourceWorkflowRunID: "run_shared"
        )
        let remoteOnlyArtifact = Artifact(
            id: "artifact_remote_only",
            kind: .roadmap,
            title: "Remote Roadmap",
            markdown: "# Remote roadmap",
            version: 1,
            createdBy: "Backend workflow",
            createdAt: remoteUpdatedAt,
            sourceWorkflowRunID: "run_remote_only"
        )
        let remoteProject = IdeaProject(
            id: "idea_shared",
            title: "Shared Idea",
            status: .validated,
            source: .mac,
            createdAt: lastSyncedAt,
            updatedAt: remoteUpdatedAt,
            summary: "Shared summary.",
            tags: [.appIdea],
            score: IdeaScore(confidence: 0.7, completeness: 0.8, risk: 0.2),
            transcript: Transcript(cleanText: "Shared transcript.", segments: [], unclearFragments: []),
            recordings: [],
            questions: [
                Question(id: "question_shared", prompt: "Remote question prompt", answer: "Remote answer", isBlocking: false),
                Question(id: "question_remote_only", prompt: "Remote only question", answer: "Remote only answer", isBlocking: false)
            ],
            artifacts: [remoteRunArtifact, remoteOnlyArtifact],
            assumptions: [
                Assumption(id: "assumption_shared", text: "Remote assumption", confidence: 0.4, evidence: "Remote evidence"),
                Assumption(id: "assumption_remote_only", text: "Remote only assumption", confidence: 0.9, evidence: "Remote only evidence")
            ],
            validationExperiments: [
                ValidationExperiment(id: "experiment_shared", title: "Remote experiment", metric: "Remote metric", goNoGoCriteria: "Remote criteria"),
                ValidationExperiment(id: "experiment_remote_only", title: "Remote only experiment", metric: "Remote only metric", goNoGoCriteria: "Remote only criteria")
            ],
            codexTasks: [
                CodexTask(id: "task_shared", title: "Remote Codex task", acceptanceCriteria: ["Remote AC"], testPlan: ["Remote test"]),
                CodexTask(id: "task_remote_only", title: "Remote only Codex task", acceptanceCriteria: ["Remote only AC"], testPlan: ["Remote only test"])
            ],
            workflowRuns: [
                WorkflowRun(
                    id: "run_shared",
                    templateID: "template_architecture",
                    templateName: "Remote Architecture Run",
                    status: .completed,
                    stepRuns: [],
                    artifactIDs: ["artifact_shared_run"],
                    startedAt: remoteUpdatedAt.addingTimeInterval(-100),
                    completedAt: remoteUpdatedAt
                ),
                WorkflowRun(
                    id: "run_remote_only",
                    templateID: "template_roadmap",
                    templateName: "Remote Roadmap Run",
                    status: .completed,
                    stepRuns: [],
                    artifactIDs: ["artifact_remote_only"],
                    startedAt: remoteUpdatedAt.addingTimeInterval(-80),
                    completedAt: remoteUpdatedAt
                )
            ]
        )
        let remoteState = WorkspaceState(
            projects: [remoteProject],
            workflowTemplates: DefaultWorkflows.templates,
            uploadJobs: [],
            privacyMode: .standardCloud,
            syncHealth: SyncHealth(
                watchReachable: false,
                queuedUploads: 0,
                lastSuccessfulSync: lastSyncedAt,
                failingItems: 0
            ),
            selectedProjectID: "idea_shared",
            updatedAt: remoteUpdatedAt
        )

        XCTAssertThrowsError(try store.applyRemoteWorkspaceSnapshot(remoteState, syncedAt: syncedAt))
        let conflictStatus = try XCTUnwrap(store.syncHealth.syncConflictStatus)
        let collectionReviewItems = conflictStatus.reviewItems.filter { $0.kind == .projectCollectionItem }
        XCTAssertEqual(
            collectionReviewItems.map(\.id),
            [
                "project:idea_shared:assumptions:item:assumption_local_only",
                "project:idea_shared:assumptions:item:assumption_shared",
                "project:idea_shared:codexTasks:item:task_local_only",
                "project:idea_shared:codexTasks:item:task_shared",
                "project:idea_shared:questions:item:question_local_only",
                "project:idea_shared:questions:item:question_shared",
                "project:idea_shared:validationExperiments:item:experiment_local_only",
                "project:idea_shared:validationExperiments:item:experiment_shared",
                "project:idea_shared:workflowRuns:item:run_local_only",
                "project:idea_shared:workflowRuns:item:run_shared"
            ]
        )
        let encodedConflictStatus = String(data: try JSONEncoder().encode(conflictStatus), encoding: .utf8)
        XCTAssertFalse(encodedConflictStatus?.contains("Local private question prompt") == true)
        XCTAssertFalse(encodedConflictStatus?.contains("Local private assumption") == true)
        XCTAssertFalse(encodedConflictStatus?.contains("Local experiment") == true)
        XCTAssertFalse(encodedConflictStatus?.contains("Local Codex task") == true)
        XCTAssertFalse(encodedConflictStatus?.contains("Local Architecture Run") == true)

        let selection = WorkspaceSyncConflictMergeSelection(
            selectedReviewItemIDs: [
                "project:idea_shared:questions:item:question_shared",
                "project:idea_shared:questions:item:question_local_only",
                "project:idea_shared:assumptions:item:assumption_shared",
                "project:idea_shared:assumptions:item:assumption_local_only",
                "project:idea_shared:validationExperiments:item:experiment_shared",
                "project:idea_shared:validationExperiments:item:experiment_local_only",
                "project:idea_shared:codexTasks:item:task_shared",
                "project:idea_shared:codexTasks:item:task_local_only",
                "project:idea_shared:workflowRuns:item:run_shared",
                "project:idea_shared:workflowRuns:item:run_local_only"
            ],
            reviewItems: conflictStatus.reviewItems
        )

        XCTAssertEqual(
            selection.projectCollectionItemsToPreserve,
            [
                WorkspaceSyncProjectCollectionItemSelection(projectID: "idea_shared", field: .assumptions, itemID: "assumption_local_only"),
                WorkspaceSyncProjectCollectionItemSelection(projectID: "idea_shared", field: .assumptions, itemID: "assumption_shared"),
                WorkspaceSyncProjectCollectionItemSelection(projectID: "idea_shared", field: .codexTasks, itemID: "task_local_only"),
                WorkspaceSyncProjectCollectionItemSelection(projectID: "idea_shared", field: .codexTasks, itemID: "task_shared"),
                WorkspaceSyncProjectCollectionItemSelection(projectID: "idea_shared", field: .questions, itemID: "question_local_only"),
                WorkspaceSyncProjectCollectionItemSelection(projectID: "idea_shared", field: .questions, itemID: "question_shared"),
                WorkspaceSyncProjectCollectionItemSelection(projectID: "idea_shared", field: .validationExperiments, itemID: "experiment_local_only"),
                WorkspaceSyncProjectCollectionItemSelection(projectID: "idea_shared", field: .validationExperiments, itemID: "experiment_shared"),
                WorkspaceSyncProjectCollectionItemSelection(projectID: "idea_shared", field: .workflowRuns, itemID: "run_local_only"),
                WorkspaceSyncProjectCollectionItemSelection(projectID: "idea_shared", field: .workflowRuns, itemID: "run_shared")
            ]
        )

        let applied = try store.applyRemoteWorkspaceSnapshot(
            remoteState,
            syncedAt: syncedAt.addingTimeInterval(60),
            conflictResolution: .preserveReviewedLocalWork(selection)
        )

        XCTAssertTrue(applied)
        let mergedProject = try XCTUnwrap(store.projects.first { $0.id == "idea_shared" })
        XCTAssertEqual(mergedProject.questions.map(\.id), ["question_shared", "question_local_only", "question_remote_only"])
        XCTAssertEqual(mergedProject.questions.first { $0.id == "question_shared" }?.prompt, "Local private question prompt")
        XCTAssertEqual(mergedProject.assumptions.map(\.id), ["assumption_shared", "assumption_local_only", "assumption_remote_only"])
        XCTAssertEqual(mergedProject.validationExperiments.map(\.id), ["experiment_shared", "experiment_local_only", "experiment_remote_only"])
        XCTAssertEqual(mergedProject.codexTasks.map(\.id), ["task_shared", "task_local_only", "task_remote_only"])
        XCTAssertEqual(mergedProject.workflowRuns.map(\.id), ["run_shared", "run_local_only", "run_remote_only"])
        XCTAssertEqual(mergedProject.workflowRuns.first { $0.id == "run_shared" }?.templateName, "Local Architecture Run")
        XCTAssertEqual(mergedProject.artifacts.map(\.id), ["artifact_shared_run", "artifact_remote_only"])
        XCTAssertEqual(mergedProject.artifacts.first { $0.id == "artifact_shared_run" }?.markdown, "# Local run architecture")
        XCTAssertEqual(mergedProject.workflowComparison(forRunID: "run_shared")?.changes.first?.currentArtifactID, "artifact_shared_run")
        XCTAssertNil(store.syncHealth.syncConflictStatus)
    }

    @MainActor
    func testReviewedProjectContentMergeAppliesCustomQuestionAndAssumptionItemValues() throws {
        let lastSyncedAt = Date(timeIntervalSince1970: 900)
        let localUpdatedAt = Date(timeIntervalSince1970: 2_000)
        let remoteUpdatedAt = Date(timeIntervalSince1970: 2_500)
        let mergeSyncedAt = Date(timeIntervalSince1970: 3_000)
        let repository = InMemoryWorkspaceRepository()
        let store = IdeaForgeStore(state: WorkspaceState.seed(), repository: repository)
        let localProject = IdeaProject(
            id: "idea_shared",
            title: "Shared Idea",
            status: .validated,
            source: .mac,
            createdAt: lastSyncedAt,
            updatedAt: localUpdatedAt,
            summary: "Shared summary.",
            tags: [.appIdea],
            score: IdeaScore(confidence: 0.7, completeness: 0.8, risk: 0.2),
            transcript: Transcript(cleanText: "Shared transcript.", segments: [], unclearFragments: []),
            recordings: [],
            questions: [
                Question(id: "question_shared", prompt: "Local private question prompt", answer: "Local answer", isBlocking: false),
                Question(id: "question_local_only", prompt: "Local only private question", answer: nil, isBlocking: true)
            ],
            artifacts: [],
            assumptions: [
                Assumption(id: "assumption_shared", text: "Local private assumption", confidence: 0.8, evidence: "Local private evidence"),
                Assumption(id: "assumption_local_only", text: "Local only assumption", confidence: 0.6, evidence: "Local only evidence")
            ],
            validationExperiments: [],
            codexTasks: []
        )
        store.projects = [localProject]
        store.selectedProjectID = localProject.id
        store.updatedAt = localUpdatedAt
        store.syncHealth.lastSuccessfulSync = lastSyncedAt

        let remoteProject = IdeaProject(
            id: "idea_shared",
            title: "Shared Idea",
            status: .validated,
            source: .mac,
            createdAt: lastSyncedAt,
            updatedAt: remoteUpdatedAt,
            summary: "Shared summary.",
            tags: [.appIdea],
            score: IdeaScore(confidence: 0.7, completeness: 0.8, risk: 0.2),
            transcript: Transcript(cleanText: "Shared transcript.", segments: [], unclearFragments: []),
            recordings: [],
            questions: [
                Question(id: "question_shared", prompt: "Remote question prompt", answer: "Remote answer", isBlocking: false),
                Question(id: "question_remote_only", prompt: "Remote only question", answer: "Remote only answer", isBlocking: false)
            ],
            artifacts: [],
            assumptions: [
                Assumption(id: "assumption_shared", text: "Remote assumption", confidence: 0.4, evidence: "Remote evidence"),
                Assumption(id: "assumption_remote_only", text: "Remote only assumption", confidence: 0.9, evidence: "Remote only evidence")
            ],
            validationExperiments: [],
            codexTasks: []
        )
        let remoteState = WorkspaceState(
            projects: [remoteProject],
            workflowTemplates: DefaultWorkflows.templates,
            uploadJobs: [],
            privacyMode: .standardCloud,
            syncHealth: SyncHealth(
                watchReachable: false,
                queuedUploads: 0,
                lastSuccessfulSync: lastSyncedAt,
                failingItems: 0
            ),
            selectedProjectID: "idea_shared",
            updatedAt: remoteUpdatedAt
        )

        XCTAssertThrowsError(try store.applyRemoteWorkspaceSnapshot(remoteState, syncedAt: mergeSyncedAt.addingTimeInterval(-60)))
        let conflictStatus = try XCTUnwrap(store.syncHealth.syncConflictStatus)
        let encodedConflictStatus = String(data: try JSONEncoder().encode(conflictStatus), encoding: .utf8)
        XCTAssertFalse(encodedConflictStatus?.contains("Merged question prompt") == true)
        XCTAssertFalse(encodedConflictStatus?.contains("Merged assumption") == true)
        XCTAssertFalse(encodedConflictStatus?.contains("Local private question prompt") == true)
        XCTAssertFalse(encodedConflictStatus?.contains("Local private assumption") == true)

        let selection = WorkspaceSyncConflictMergeSelection(
            selectedReviewItemIDs: [
                "project:idea_shared:questions:item:question_local_only",
                "project:idea_shared:assumptions:item:assumption_local_only"
            ],
            reviewItems: conflictStatus.reviewItems,
            customProjectCollectionItemValues: [
                WorkspaceSyncProjectCollectionItemCustomValue(
                    projectID: "idea_shared",
                    field: .questions,
                    itemID: "question_shared",
                    primaryText: " Merged question prompt ",
                    secondaryText: " Merged answer ",
                    flagValue: true
                ),
                WorkspaceSyncProjectCollectionItemCustomValue(
                    projectID: "idea_shared",
                    field: .questions,
                    itemID: "question_local_only",
                    primaryText: " Merged local-only question ",
                    secondaryText: "",
                    flagValue: false
                ),
                WorkspaceSyncProjectCollectionItemCustomValue(
                    projectID: "idea_shared",
                    field: .assumptions,
                    itemID: "assumption_shared",
                    primaryText: " Merged assumption ",
                    secondaryText: " Merged evidence ",
                    numericValue: 0.77
                ),
                WorkspaceSyncProjectCollectionItemCustomValue(
                    projectID: "idea_shared",
                    field: .assumptions,
                    itemID: "assumption_local_only",
                    primaryText: " Merged local-only assumption ",
                    secondaryText: " Merged local-only evidence ",
                    numericValue: 1.4
                ),
                WorkspaceSyncProjectCollectionItemCustomValue(
                    projectID: "idea_shared",
                    field: .workflowRuns,
                    itemID: "run_unsupported",
                    primaryText: "Unsupported",
                    secondaryText: "Ignored"
                ),
                WorkspaceSyncProjectCollectionItemCustomValue(
                    projectID: "idea_shared",
                    field: .questions,
                    itemID: "question_blank",
                    primaryText: " ",
                    secondaryText: "Ignored"
                )
            ]
        )

        XCTAssertEqual(
            selection.customProjectCollectionItemValues,
            [
                WorkspaceSyncProjectCollectionItemCustomValue(
                    projectID: "idea_shared",
                    field: .assumptions,
                    itemID: "assumption_local_only",
                    primaryText: "Merged local-only assumption",
                    secondaryText: "Merged local-only evidence",
                    numericValue: 1.0
                ),
                WorkspaceSyncProjectCollectionItemCustomValue(
                    projectID: "idea_shared",
                    field: .assumptions,
                    itemID: "assumption_shared",
                    primaryText: "Merged assumption",
                    secondaryText: "Merged evidence",
                    numericValue: 0.77
                ),
                WorkspaceSyncProjectCollectionItemCustomValue(
                    projectID: "idea_shared",
                    field: .questions,
                    itemID: "question_local_only",
                    primaryText: "Merged local-only question",
                    secondaryText: "",
                    flagValue: false
                ),
                WorkspaceSyncProjectCollectionItemCustomValue(
                    projectID: "idea_shared",
                    field: .questions,
                    itemID: "question_shared",
                    primaryText: "Merged question prompt",
                    secondaryText: "Merged answer",
                    flagValue: true
                )
            ]
        )

        let applied = try store.applyRemoteWorkspaceSnapshot(
            remoteState,
            syncedAt: mergeSyncedAt,
            conflictResolution: .preserveReviewedLocalWork(selection)
        )

        XCTAssertTrue(applied)
        let mergedProject = try XCTUnwrap(store.projects.first { $0.id == "idea_shared" })
        XCTAssertEqual(mergedProject.questions.map(\.id), ["question_local_only", "question_shared", "question_remote_only"])
        XCTAssertEqual(mergedProject.questions.first { $0.id == "question_shared" }?.prompt, "Merged question prompt")
        XCTAssertEqual(mergedProject.questions.first { $0.id == "question_shared" }?.answer, "Merged answer")
        XCTAssertEqual(mergedProject.questions.first { $0.id == "question_shared" }?.isBlocking, true)
        XCTAssertEqual(mergedProject.questions.first { $0.id == "question_local_only" }?.prompt, "Merged local-only question")
        XCTAssertEqual(mergedProject.questions.first { $0.id == "question_local_only" }?.answer, nil)
        XCTAssertEqual(mergedProject.questions.first { $0.id == "question_local_only" }?.isBlocking, false)
        XCTAssertEqual(mergedProject.assumptions.map(\.id), ["assumption_local_only", "assumption_shared", "assumption_remote_only"])
        XCTAssertEqual(mergedProject.assumptions.first { $0.id == "assumption_shared" }?.text, "Merged assumption")
        XCTAssertEqual(mergedProject.assumptions.first { $0.id == "assumption_shared" }?.evidence, "Merged evidence")
        XCTAssertEqual(mergedProject.assumptions.first { $0.id == "assumption_shared" }?.confidence ?? 0, 0.77, accuracy: 0.001)
        XCTAssertEqual(mergedProject.assumptions.first { $0.id == "assumption_local_only" }?.confidence ?? 0, 1.0, accuracy: 0.001)
        XCTAssertEqual(mergedProject.updatedAt, mergeSyncedAt)
        XCTAssertNil(store.syncHealth.syncConflictStatus)
    }

    @MainActor
    func testReviewedProjectContentMergeAppliesCustomValidationAndCodexItemValues() throws {
        let lastSyncedAt = Date(timeIntervalSince1970: 900)
        let localUpdatedAt = Date(timeIntervalSince1970: 2_000)
        let remoteUpdatedAt = Date(timeIntervalSince1970: 2_500)
        let mergeSyncedAt = Date(timeIntervalSince1970: 3_000)
        let repository = InMemoryWorkspaceRepository()
        let store = IdeaForgeStore(state: WorkspaceState.seed(), repository: repository)
        let localProject = IdeaProject(
            id: "idea_shared",
            title: "Shared Idea",
            status: .validated,
            source: .mac,
            createdAt: lastSyncedAt,
            updatedAt: localUpdatedAt,
            summary: "Shared summary.",
            tags: [.appIdea],
            score: IdeaScore(confidence: 0.7, completeness: 0.8, risk: 0.2),
            transcript: Transcript(cleanText: "Shared transcript.", segments: [], unclearFragments: []),
            recordings: [],
            questions: [],
            artifacts: [],
            assumptions: [],
            validationExperiments: [
                ValidationExperiment(id: "experiment_shared", title: "Local private experiment", metric: "Local private metric", goNoGoCriteria: "Local private criteria"),
                ValidationExperiment(id: "experiment_local_only", title: "Local only experiment", metric: "Local only metric", goNoGoCriteria: "Local only criteria")
            ],
            codexTasks: [
                CodexTask(id: "task_shared", title: "Local private Codex task", acceptanceCriteria: ["Local AC"], testPlan: ["Local test"]),
                CodexTask(id: "task_local_only", title: "Local only Codex task", acceptanceCriteria: ["Local only AC"], testPlan: ["Local only test"])
            ]
        )
        store.projects = [localProject]
        store.selectedProjectID = localProject.id
        store.updatedAt = localUpdatedAt
        store.syncHealth.lastSuccessfulSync = lastSyncedAt

        let remoteProject = IdeaProject(
            id: "idea_shared",
            title: "Shared Idea",
            status: .validated,
            source: .mac,
            createdAt: lastSyncedAt,
            updatedAt: remoteUpdatedAt,
            summary: "Shared summary.",
            tags: [.appIdea],
            score: IdeaScore(confidence: 0.7, completeness: 0.8, risk: 0.2),
            transcript: Transcript(cleanText: "Shared transcript.", segments: [], unclearFragments: []),
            recordings: [],
            questions: [],
            artifacts: [],
            assumptions: [],
            validationExperiments: [
                ValidationExperiment(id: "experiment_shared", title: "Remote experiment", metric: "Remote metric", goNoGoCriteria: "Remote criteria"),
                ValidationExperiment(id: "experiment_remote_only", title: "Remote only experiment", metric: "Remote only metric", goNoGoCriteria: "Remote only criteria")
            ],
            codexTasks: [
                CodexTask(id: "task_shared", title: "Remote Codex task", acceptanceCriteria: ["Remote AC"], testPlan: ["Remote test"]),
                CodexTask(id: "task_remote_only", title: "Remote only Codex task", acceptanceCriteria: ["Remote only AC"], testPlan: ["Remote only test"])
            ]
        )
        let remoteState = WorkspaceState(
            projects: [remoteProject],
            workflowTemplates: DefaultWorkflows.templates,
            uploadJobs: [],
            privacyMode: .standardCloud,
            syncHealth: SyncHealth(
                watchReachable: false,
                queuedUploads: 0,
                lastSuccessfulSync: lastSyncedAt,
                failingItems: 0
            ),
            selectedProjectID: "idea_shared",
            updatedAt: remoteUpdatedAt
        )

        XCTAssertThrowsError(try store.applyRemoteWorkspaceSnapshot(remoteState, syncedAt: mergeSyncedAt.addingTimeInterval(-60)))
        let conflictStatus = try XCTUnwrap(store.syncHealth.syncConflictStatus)
        let encodedConflictStatus = String(data: try JSONEncoder().encode(conflictStatus), encoding: .utf8)
        XCTAssertFalse(encodedConflictStatus?.contains("Merged validation experiment") == true)
        XCTAssertFalse(encodedConflictStatus?.contains("Merged Codex task") == true)
        XCTAssertFalse(encodedConflictStatus?.contains("Local private experiment") == true)
        XCTAssertFalse(encodedConflictStatus?.contains("Local private Codex task") == true)

        let selection = WorkspaceSyncConflictMergeSelection(
            selectedReviewItemIDs: [
                "project:idea_shared:validationExperiments:item:experiment_local_only",
                "project:idea_shared:codexTasks:item:task_local_only"
            ],
            reviewItems: conflictStatus.reviewItems,
            customProjectCollectionItemValues: [
                WorkspaceSyncProjectCollectionItemCustomValue(
                    projectID: "idea_shared",
                    field: .validationExperiments,
                    itemID: "experiment_shared",
                    primaryText: " Merged validation experiment ",
                    secondaryText: " Merged success metric ",
                    tertiaryText: " Merged go/no-go criteria "
                ),
                WorkspaceSyncProjectCollectionItemCustomValue(
                    projectID: "idea_shared",
                    field: .validationExperiments,
                    itemID: "experiment_local_only",
                    primaryText: " Merged local-only experiment ",
                    secondaryText: " Local-only metric ",
                    tertiaryText: " Local-only criteria "
                ),
                WorkspaceSyncProjectCollectionItemCustomValue(
                    projectID: "idea_shared",
                    field: .codexTasks,
                    itemID: "task_shared",
                    primaryText: " Merged Codex task ",
                    secondaryText: " First acceptance criterion \n\n Second acceptance criterion ",
                    tertiaryText: " First test step \n Second test step "
                ),
                WorkspaceSyncProjectCollectionItemCustomValue(
                    projectID: "idea_shared",
                    field: .codexTasks,
                    itemID: "task_local_only",
                    primaryText: " Merged local-only Codex task ",
                    secondaryText: " Local acceptance ",
                    tertiaryText: " Local test "
                ),
                WorkspaceSyncProjectCollectionItemCustomValue(
                    projectID: "idea_shared",
                    field: .workflowRuns,
                    itemID: "run_unsupported",
                    primaryText: "Unsupported",
                    secondaryText: "Ignored",
                    tertiaryText: "Ignored"
                ),
                WorkspaceSyncProjectCollectionItemCustomValue(
                    projectID: "idea_shared",
                    field: .codexTasks,
                    itemID: "task_blank",
                    primaryText: " ",
                    secondaryText: "Ignored",
                    tertiaryText: "Ignored"
                )
            ]
        )

        XCTAssertEqual(
            selection.customProjectCollectionItemValues,
            [
                WorkspaceSyncProjectCollectionItemCustomValue(
                    projectID: "idea_shared",
                    field: .codexTasks,
                    itemID: "task_local_only",
                    primaryText: "Merged local-only Codex task",
                    secondaryText: "Local acceptance",
                    tertiaryText: "Local test"
                ),
                WorkspaceSyncProjectCollectionItemCustomValue(
                    projectID: "idea_shared",
                    field: .codexTasks,
                    itemID: "task_shared",
                    primaryText: "Merged Codex task",
                    secondaryText: "First acceptance criterion\nSecond acceptance criterion",
                    tertiaryText: "First test step\nSecond test step"
                ),
                WorkspaceSyncProjectCollectionItemCustomValue(
                    projectID: "idea_shared",
                    field: .validationExperiments,
                    itemID: "experiment_local_only",
                    primaryText: "Merged local-only experiment",
                    secondaryText: "Local-only metric",
                    tertiaryText: "Local-only criteria"
                ),
                WorkspaceSyncProjectCollectionItemCustomValue(
                    projectID: "idea_shared",
                    field: .validationExperiments,
                    itemID: "experiment_shared",
                    primaryText: "Merged validation experiment",
                    secondaryText: "Merged success metric",
                    tertiaryText: "Merged go/no-go criteria"
                )
            ]
        )

        let applied = try store.applyRemoteWorkspaceSnapshot(
            remoteState,
            syncedAt: mergeSyncedAt,
            conflictResolution: .preserveReviewedLocalWork(selection)
        )

        XCTAssertTrue(applied)
        let mergedProject = try XCTUnwrap(store.projects.first { $0.id == "idea_shared" })
        XCTAssertEqual(mergedProject.validationExperiments.map(\.id), ["experiment_local_only", "experiment_shared", "experiment_remote_only"])
        XCTAssertEqual(mergedProject.validationExperiments.first { $0.id == "experiment_shared" }?.title, "Merged validation experiment")
        XCTAssertEqual(mergedProject.validationExperiments.first { $0.id == "experiment_shared" }?.metric, "Merged success metric")
        XCTAssertEqual(mergedProject.validationExperiments.first { $0.id == "experiment_shared" }?.goNoGoCriteria, "Merged go/no-go criteria")
        XCTAssertEqual(mergedProject.validationExperiments.first { $0.id == "experiment_local_only" }?.title, "Merged local-only experiment")
        XCTAssertEqual(mergedProject.codexTasks.map(\.id), ["task_local_only", "task_shared", "task_remote_only"])
        XCTAssertEqual(mergedProject.codexTasks.first { $0.id == "task_shared" }?.title, "Merged Codex task")
        XCTAssertEqual(mergedProject.codexTasks.first { $0.id == "task_shared" }?.acceptanceCriteria, ["First acceptance criterion", "Second acceptance criterion"])
        XCTAssertEqual(mergedProject.codexTasks.first { $0.id == "task_shared" }?.testPlan, ["First test step", "Second test step"])
        XCTAssertEqual(mergedProject.codexTasks.first { $0.id == "task_local_only" }?.acceptanceCriteria, ["Local acceptance"])
        XCTAssertEqual(mergedProject.updatedAt, mergeSyncedAt)
        XCTAssertNil(store.syncHealth.syncConflictStatus)
    }

    @MainActor
    func testReviewedProjectContentMergeAppliesCustomWorkflowRunItemValuesWithoutChangingProvenance() throws {
        let lastSyncedAt = Date(timeIntervalSince1970: 900)
        let localUpdatedAt = Date(timeIntervalSince1970: 2_000)
        let remoteUpdatedAt = Date(timeIntervalSince1970: 2_500)
        let mergeSyncedAt = Date(timeIntervalSince1970: 3_000)
        let repository = InMemoryWorkspaceRepository()
        let store = IdeaForgeStore(state: WorkspaceState.seed(), repository: repository)
        let localRunArtifact = Artifact(
            id: "artifact_local_run",
            kind: .architecture,
            title: "Local Run Architecture",
            markdown: "# Local run architecture",
            version: 1,
            createdBy: "Local workflow",
            createdAt: localUpdatedAt,
            sourceWorkflowRunID: "run_local_only"
        )
        let localStepRun = StepRun(
            id: "step_local",
            stepID: "step_architecture",
            stepName: "Local private architecture step",
            status: .failed,
            outputArtifactIDs: ["artifact_local_run"],
            startedAt: localUpdatedAt.addingTimeInterval(-90),
            completedAt: localUpdatedAt,
            errorMessage: "Local provider failure"
        )
        let remoteStepRun = StepRun(
            id: "step_remote",
            stepID: "step_architecture",
            stepName: "Remote architecture step",
            status: .completed,
            outputArtifactIDs: ["artifact_remote_run"],
            startedAt: remoteUpdatedAt.addingTimeInterval(-120),
            completedAt: remoteUpdatedAt
        )
        let remoteEvaluation = WorkflowRunEvaluation(
            readinessScore: 0.81,
            decision: .needsReview,
            generatedArtifactCount: 1,
            blockingIssueCount: 1,
            blockers: ["Review generated architecture before handoff."],
            schemaCompletenessScore: 0.9,
            schemaIssues: ["Architecture missing launch checklist."],
            rubricScore: 0.75,
            rubricItems: [
                WorkflowRubricItem(
                    id: "handoff_safety",
                    title: "Handoff Safety",
                    score: 0,
                    status: .failing,
                    summary: "Generated artifacts need explicit approval boundaries before handoff."
                )
            ]
        )
        let localProject = IdeaProject(
            id: "idea_shared",
            title: "Shared Idea",
            status: .validated,
            source: .mac,
            createdAt: lastSyncedAt,
            updatedAt: localUpdatedAt,
            summary: "Shared summary.",
            tags: [.appIdea],
            score: IdeaScore(confidence: 0.7, completeness: 0.8, risk: 0.2),
            transcript: Transcript(cleanText: "Shared transcript.", segments: [], unclearFragments: []),
            recordings: [],
            questions: [],
            artifacts: [localRunArtifact],
            assumptions: [],
            validationExperiments: [],
            codexTasks: [],
            workflowRuns: [
                WorkflowRun(
                    id: "run_shared",
                    templateID: "template_architecture",
                    templateName: "Local private workflow run",
                    status: .running,
                    stepRuns: [localStepRun],
                    artifactIDs: [],
                    startedAt: localUpdatedAt.addingTimeInterval(-200)
                ),
                WorkflowRun(
                    id: "run_local_only",
                    templateID: "template_local_validation",
                    templateName: "Local-only workflow run",
                    status: .failed,
                    stepRuns: [localStepRun],
                    artifactIDs: ["artifact_local_run"],
                    startedAt: localUpdatedAt.addingTimeInterval(-120),
                    completedAt: localUpdatedAt,
                    errorMessage: "Local provider failure",
                    retryOfRunID: "run_previous",
                    retryAttempt: 2,
                    nextRetryAt: localUpdatedAt.addingTimeInterval(300)
                )
            ]
        )
        store.projects = [localProject]
        store.selectedProjectID = localProject.id
        store.updatedAt = localUpdatedAt
        store.syncHealth.lastSuccessfulSync = lastSyncedAt

        let remoteRunArtifact = Artifact(
            id: "artifact_remote_run",
            kind: .architecture,
            title: "Remote Run Architecture",
            markdown: "# Remote run architecture",
            version: 2,
            createdBy: "Backend workflow",
            createdAt: remoteUpdatedAt,
            sourceWorkflowRunID: "run_shared"
        )
        let remoteOnlyArtifact = Artifact(
            id: "artifact_remote_only",
            kind: .roadmap,
            title: "Remote Roadmap",
            markdown: "# Remote roadmap",
            version: 1,
            createdBy: "Backend workflow",
            createdAt: remoteUpdatedAt,
            sourceWorkflowRunID: "run_remote_only"
        )
        let remoteProject = IdeaProject(
            id: "idea_shared",
            title: "Shared Idea",
            status: .validated,
            source: .mac,
            createdAt: lastSyncedAt,
            updatedAt: remoteUpdatedAt,
            summary: "Shared summary.",
            tags: [.appIdea],
            score: IdeaScore(confidence: 0.7, completeness: 0.8, risk: 0.2),
            transcript: Transcript(cleanText: "Shared transcript.", segments: [], unclearFragments: []),
            recordings: [],
            questions: [],
            artifacts: [remoteRunArtifact, remoteOnlyArtifact],
            assumptions: [],
            validationExperiments: [],
            codexTasks: [],
            workflowRuns: [
                WorkflowRun(
                    id: "run_shared",
                    templateID: "template_architecture",
                    templateName: "Remote Architecture Run",
                    status: .completed,
                    stepRuns: [remoteStepRun],
                    artifactIDs: ["artifact_remote_run"],
                    startedAt: remoteUpdatedAt.addingTimeInterval(-120),
                    completedAt: remoteUpdatedAt,
                    evaluation: remoteEvaluation
                ),
                WorkflowRun(
                    id: "run_remote_only",
                    templateID: "template_roadmap",
                    templateName: "Remote Roadmap Run",
                    status: .completed,
                    stepRuns: [],
                    artifactIDs: ["artifact_remote_only"],
                    startedAt: remoteUpdatedAt.addingTimeInterval(-80),
                    completedAt: remoteUpdatedAt
                )
            ]
        )
        let remoteState = WorkspaceState(
            projects: [remoteProject],
            workflowTemplates: DefaultWorkflows.templates,
            uploadJobs: [],
            privacyMode: .standardCloud,
            syncHealth: SyncHealth(
                watchReachable: false,
                queuedUploads: 0,
                lastSuccessfulSync: lastSyncedAt,
                failingItems: 0
            ),
            selectedProjectID: "idea_shared",
            updatedAt: remoteUpdatedAt
        )

        XCTAssertThrowsError(try store.applyRemoteWorkspaceSnapshot(remoteState, syncedAt: mergeSyncedAt.addingTimeInterval(-60)))
        let conflictStatus = try XCTUnwrap(store.syncHealth.syncConflictStatus)
        let encodedConflictStatus = String(data: try JSONEncoder().encode(conflictStatus), encoding: .utf8)
        XCTAssertFalse(encodedConflictStatus?.contains("Merged Workflow Run") == true)
        XCTAssertFalse(encodedConflictStatus?.contains("Local private workflow run") == true)
        XCTAssertFalse(encodedConflictStatus?.contains("Local provider failure") == true)
        XCTAssertFalse(encodedConflictStatus?.contains("Local private architecture step") == true)

        let selection = WorkspaceSyncConflictMergeSelection(
            selectedReviewItemIDs: [
                "project:idea_shared:workflowRuns:item:run_local_only"
            ],
            reviewItems: conflictStatus.reviewItems,
            customProjectCollectionItemValues: [
                WorkspaceSyncProjectCollectionItemCustomValue(
                    projectID: "idea_shared",
                    field: .workflowRuns,
                    itemID: "run_shared",
                    primaryText: " Merged Workflow Run ",
                    secondaryText: " failed ",
                    tertiaryText: " Needs operator review before retry. "
                ),
                WorkspaceSyncProjectCollectionItemCustomValue(
                    projectID: "idea_shared",
                    field: .workflowRuns,
                    itemID: "run_local_only",
                    primaryText: " Merged Local Run ",
                    secondaryText: " completed ",
                    tertiaryText: " Should be ignored for completed runs. "
                ),
                WorkspaceSyncProjectCollectionItemCustomValue(
                    projectID: "idea_shared",
                    field: .workflowRuns,
                    itemID: "run_invalid_status",
                    primaryText: "Invalid status run",
                    secondaryText: "paused",
                    tertiaryText: "Ignored"
                ),
                WorkspaceSyncProjectCollectionItemCustomValue(
                    projectID: "idea_shared",
                    field: .workflowRuns,
                    itemID: "run_missing_failure_note",
                    primaryText: "Missing failure note",
                    secondaryText: "failed",
                    tertiaryText: " "
                )
            ]
        )

        XCTAssertEqual(
            selection.customProjectCollectionItemValues,
            [
                WorkspaceSyncProjectCollectionItemCustomValue(
                    projectID: "idea_shared",
                    field: .workflowRuns,
                    itemID: "run_local_only",
                    primaryText: "Merged Local Run",
                    secondaryText: "completed",
                    tertiaryText: ""
                ),
                WorkspaceSyncProjectCollectionItemCustomValue(
                    projectID: "idea_shared",
                    field: .workflowRuns,
                    itemID: "run_shared",
                    primaryText: "Merged Workflow Run",
                    secondaryText: "failed",
                    tertiaryText: "Needs operator review before retry."
                )
            ]
        )

        let applied = try store.applyRemoteWorkspaceSnapshot(
            remoteState,
            syncedAt: mergeSyncedAt,
            conflictResolution: .preserveReviewedLocalWork(selection)
        )

        XCTAssertTrue(applied)
        let mergedProject = try XCTUnwrap(store.projects.first { $0.id == "idea_shared" })
        XCTAssertEqual(mergedProject.workflowRuns.map(\.id), ["run_local_only", "run_shared", "run_remote_only"])
        let mergedSharedRun = try XCTUnwrap(mergedProject.workflowRuns.first { $0.id == "run_shared" })
        XCTAssertEqual(mergedSharedRun.templateID, "template_architecture")
        XCTAssertEqual(mergedSharedRun.templateName, "Merged Workflow Run")
        XCTAssertEqual(mergedSharedRun.status, .failed)
        XCTAssertEqual(mergedSharedRun.errorMessage, "Needs operator review before retry.")
        XCTAssertEqual(mergedSharedRun.stepRuns, [remoteStepRun])
        XCTAssertEqual(mergedSharedRun.artifactIDs, ["artifact_remote_run"])
        XCTAssertEqual(mergedSharedRun.startedAt, remoteUpdatedAt.addingTimeInterval(-120))
        XCTAssertEqual(mergedSharedRun.completedAt, remoteUpdatedAt)
        XCTAssertEqual(mergedSharedRun.evaluation, remoteEvaluation)

        let mergedLocalRun = try XCTUnwrap(mergedProject.workflowRuns.first { $0.id == "run_local_only" })
        XCTAssertEqual(mergedLocalRun.templateID, "template_local_validation")
        XCTAssertEqual(mergedLocalRun.templateName, "Merged Local Run")
        XCTAssertEqual(mergedLocalRun.status, .completed)
        XCTAssertNil(mergedLocalRun.errorMessage)
        XCTAssertEqual(mergedLocalRun.stepRuns, [localStepRun])
        XCTAssertEqual(mergedLocalRun.artifactIDs, ["artifact_local_run"])
        XCTAssertEqual(mergedLocalRun.retryOfRunID, "run_previous")
        XCTAssertEqual(mergedLocalRun.retryAttempt, 2)
        XCTAssertEqual(mergedLocalRun.nextRetryAt, localUpdatedAt.addingTimeInterval(300))
        XCTAssertEqual(mergedProject.artifacts.map(\.id), ["artifact_local_run", "artifact_remote_run", "artifact_remote_only"])
        XCTAssertEqual(mergedProject.workflowComparison(forRunID: "run_local_only")?.currentRunID, "run_local_only")
        XCTAssertEqual(mergedProject.updatedAt, mergeSyncedAt)
        XCTAssertNil(store.syncHealth.syncConflictStatus)
    }

    @MainActor
    func testReviewedProjectContentMergeAppliesCustomTextFieldValues() throws {
        let lastSyncedAt = Date(timeIntervalSince1970: 900)
        let localUpdatedAt = Date(timeIntervalSince1970: 1_000)
        let remoteUpdatedAt = Date(timeIntervalSince1970: 2_000)
        let mergeSyncedAt = Date(timeIntervalSince1970: 3_060)
        let repository = InMemoryWorkspaceRepository()
        let store = IdeaForgeStore(state: WorkspaceState.seed(), repository: repository)
        let localSegment = TranscriptSegment(
            id: "seg_local",
            startSeconds: 0,
            endSeconds: 12,
            text: "Local segment text.",
            isMarkedImportant: true
        )
        let remoteSegment = TranscriptSegment(
            id: "seg_remote",
            startSeconds: 0,
            endSeconds: 10,
            text: "Remote segment text.",
            isMarkedImportant: false
        )
        let localProject = IdeaProject(
            id: "idea_shared",
            title: "Local Title",
            status: .draft,
            source: .mac,
            createdAt: lastSyncedAt,
            updatedAt: localUpdatedAt,
            summary: "Local summary.",
            tags: [.research],
            score: IdeaScore(confidence: 0.6, completeness: 0.4, risk: 0.5),
            transcript: Transcript(cleanText: "Local transcript.", segments: [localSegment], unclearFragments: ["local unclear"]),
            recordings: [],
            questions: [],
            artifacts: [],
            assumptions: [],
            validationExperiments: [],
            codexTasks: []
        )
        store.projects = [localProject]
        store.selectedProjectID = localProject.id
        store.updatedAt = localUpdatedAt
        store.syncHealth.lastSuccessfulSync = lastSyncedAt

        let remoteProject = IdeaProject(
            id: "idea_shared",
            title: "Remote Title",
            status: .readyForBuild,
            source: .mac,
            createdAt: lastSyncedAt,
            updatedAt: remoteUpdatedAt,
            summary: "Remote summary.",
            tags: [.business],
            score: IdeaScore(confidence: 0.9, completeness: 0.9, risk: 0.2),
            transcript: Transcript(cleanText: "Remote transcript.", segments: [remoteSegment], unclearFragments: ["remote unclear"]),
            recordings: [],
            questions: [],
            artifacts: [],
            assumptions: [],
            validationExperiments: [],
            codexTasks: []
        )
        let remoteState = WorkspaceState(
            projects: [remoteProject],
            workflowTemplates: DefaultWorkflows.templates,
            uploadJobs: [],
            privacyMode: .standardCloud,
            syncHealth: SyncHealth(
                watchReachable: false,
                queuedUploads: 0,
                lastSuccessfulSync: lastSyncedAt,
                failingItems: 0
            ),
            selectedProjectID: "idea_shared",
            updatedAt: remoteUpdatedAt
        )

        XCTAssertThrowsError(try store.applyRemoteWorkspaceSnapshot(remoteState, syncedAt: mergeSyncedAt.addingTimeInterval(-60)))
        let conflictStatus = try XCTUnwrap(store.syncHealth.syncConflictStatus)
        let encodedConflictStatus = String(
            data: try JSONEncoder().encode(conflictStatus),
            encoding: .utf8
        )
        XCTAssertFalse(encodedConflictStatus?.contains("Merged Title") == true)
        XCTAssertFalse(encodedConflictStatus?.contains("Merged transcript clean text.") == true)

        let selection = WorkspaceSyncConflictMergeSelection(
            selectedReviewItemIDs: [
                "project:idea_shared:summary"
            ],
            reviewItems: conflictStatus.reviewItems,
            customProjectFieldValues: [
                WorkspaceSyncProjectFieldCustomValue(
                    projectID: "idea_shared",
                    field: .transcript,
                    value: " Merged transcript clean text. "
                ),
                WorkspaceSyncProjectFieldCustomValue(
                    projectID: "idea_shared",
                    field: .title,
                    value: " Merged Title "
                ),
                WorkspaceSyncProjectFieldCustomValue(
                    projectID: "idea_shared",
                    field: .summary,
                    value: " Merged summary from local and remote. "
                ),
                WorkspaceSyncProjectFieldCustomValue(
                    projectID: "idea_shared",
                    field: .tags,
                    value: "ignored custom tags"
                )
            ]
        )

        XCTAssertEqual(
            selection.projectFieldsToPreserve,
            [WorkspaceSyncProjectFieldSelection(projectID: "idea_shared", field: .summary)]
        )
        XCTAssertEqual(
            selection.customProjectFieldValues,
            [
                WorkspaceSyncProjectFieldCustomValue(
                    projectID: "idea_shared",
                    field: .summary,
                    value: "Merged summary from local and remote."
                ),
                WorkspaceSyncProjectFieldCustomValue(
                    projectID: "idea_shared",
                    field: .title,
                    value: "Merged Title"
                ),
                WorkspaceSyncProjectFieldCustomValue(
                    projectID: "idea_shared",
                    field: .transcript,
                    value: "Merged transcript clean text."
                )
            ]
        )

        let applied = try store.applyRemoteWorkspaceSnapshot(
            remoteState,
            syncedAt: mergeSyncedAt,
            conflictResolution: .preserveReviewedLocalWork(selection)
        )

        XCTAssertTrue(applied)
        let mergedProject = try XCTUnwrap(store.projects.first { $0.id == "idea_shared" })
        XCTAssertEqual(mergedProject.title, "Merged Title")
        XCTAssertEqual(mergedProject.status, .readyForBuild)
        XCTAssertEqual(mergedProject.summary, "Merged summary from local and remote.")
        XCTAssertEqual(mergedProject.tags, [.business])
        XCTAssertEqual(mergedProject.transcript.cleanText, "Merged transcript clean text.")
        XCTAssertEqual(mergedProject.transcript.segments, remoteProject.transcript.segments)
        XCTAssertEqual(mergedProject.transcript.unclearFragments, remoteProject.transcript.unclearFragments)
        XCTAssertEqual(mergedProject.updatedAt, mergeSyncedAt)
        XCTAssertNil(store.syncHealth.syncConflictStatus)
    }

    @MainActor
    func testReviewedProjectContentMergeAppliesValidatedCustomScalarFieldValues() throws {
        let lastSyncedAt = Date(timeIntervalSince1970: 900)
        let localUpdatedAt = Date(timeIntervalSince1970: 1_000)
        let remoteUpdatedAt = Date(timeIntervalSince1970: 2_000)
        let mergeSyncedAt = Date(timeIntervalSince1970: 3_060)
        let repository = InMemoryWorkspaceRepository()
        let store = IdeaForgeStore(state: WorkspaceState.seed(), repository: repository)
        let localProject = IdeaProject(
            id: "idea_shared",
            title: "Shared Idea",
            status: .draft,
            source: .mac,
            createdAt: lastSyncedAt,
            updatedAt: localUpdatedAt,
            summary: "Shared summary.",
            tags: [.research],
            score: IdeaScore(confidence: 0.3, completeness: 0.4, risk: 0.8),
            transcript: Transcript(cleanText: "Shared transcript.", segments: [], unclearFragments: []),
            recordings: [],
            questions: [],
            artifacts: [],
            assumptions: [],
            validationExperiments: [],
            codexTasks: []
        )
        store.projects = [localProject]
        store.selectedProjectID = localProject.id
        store.updatedAt = localUpdatedAt
        store.syncHealth.lastSuccessfulSync = lastSyncedAt

        let remoteProject = IdeaProject(
            id: "idea_shared",
            title: "Shared Idea",
            status: .readyForBuild,
            source: .mac,
            createdAt: lastSyncedAt,
            updatedAt: remoteUpdatedAt,
            summary: "Shared summary.",
            tags: [.business],
            score: IdeaScore(confidence: 0.9, completeness: 0.9, risk: 0.1),
            transcript: Transcript(cleanText: "Shared transcript.", segments: [], unclearFragments: []),
            recordings: [],
            questions: [],
            artifacts: [],
            assumptions: [],
            validationExperiments: [],
            codexTasks: []
        )
        let remoteState = WorkspaceState(
            projects: [remoteProject],
            workflowTemplates: DefaultWorkflows.templates,
            uploadJobs: [],
            privacyMode: .standardCloud,
            syncHealth: SyncHealth(
                watchReachable: false,
                queuedUploads: 0,
                lastSuccessfulSync: lastSyncedAt,
                failingItems: 0
            ),
            selectedProjectID: "idea_shared",
            updatedAt: remoteUpdatedAt
        )

        XCTAssertThrowsError(try store.applyRemoteWorkspaceSnapshot(remoteState, syncedAt: mergeSyncedAt.addingTimeInterval(-60)))
        let conflictStatus = try XCTUnwrap(store.syncHealth.syncConflictStatus)
        let selection = WorkspaceSyncConflictMergeSelection(
            selectedReviewItemIDs: [],
            reviewItems: conflictStatus.reviewItems,
            customProjectFieldValues: [
                WorkspaceSyncProjectFieldCustomValue(
                    projectID: "idea_shared",
                    field: .status,
                    value: "validated"
                ),
                WorkspaceSyncProjectFieldCustomValue(
                    projectID: "idea_shared",
                    field: .tags,
                    value: "appIdea, research"
                ),
                WorkspaceSyncProjectFieldCustomValue(
                    projectID: "idea_shared",
                    field: .score,
                    value: "confidence=0.72,completeness=0.83,risk=0.21"
                ),
                WorkspaceSyncProjectFieldCustomValue(
                    projectID: "idea_shared",
                    field: .score,
                    value: "confidence=not-a-number"
                ),
                WorkspaceSyncProjectFieldCustomValue(
                    projectID: "idea_shared",
                    field: .workflowRuns,
                    value: "unsupported structured field"
                )
            ]
        )

        XCTAssertEqual(
            selection.customProjectFieldValues,
            [
                WorkspaceSyncProjectFieldCustomValue(
                    projectID: "idea_shared",
                    field: .score,
                    value: "confidence=0.72,completeness=0.83,risk=0.21"
                ),
                WorkspaceSyncProjectFieldCustomValue(
                    projectID: "idea_shared",
                    field: .status,
                    value: "validated"
                ),
                WorkspaceSyncProjectFieldCustomValue(
                    projectID: "idea_shared",
                    field: .tags,
                    value: "appIdea,research"
                )
            ]
        )

        let applied = try store.applyRemoteWorkspaceSnapshot(
            remoteState,
            syncedAt: mergeSyncedAt,
            conflictResolution: .preserveReviewedLocalWork(selection)
        )

        XCTAssertTrue(applied)
        let mergedProject = try XCTUnwrap(store.projects.first { $0.id == "idea_shared" })
        XCTAssertEqual(mergedProject.status, .validated)
        XCTAssertEqual(mergedProject.tags, [.appIdea, .research])
        XCTAssertEqual(mergedProject.score.confidence, 0.72, accuracy: 0.001)
        XCTAssertEqual(mergedProject.score.completeness, 0.83, accuracy: 0.001)
        XCTAssertEqual(mergedProject.score.risk, 0.21, accuracy: 0.001)
        XCTAssertEqual(mergedProject.updatedAt, mergeSyncedAt)
        XCTAssertNil(store.syncHealth.syncConflictStatus)
    }

    func testBackendTranscriptionServicePostsUploadedAudioObjectAndDecodesTranscript() async throws {
        let transcript = Transcript(
            cleanText: "Backend transcript.",
            segments: [
                TranscriptSegment(
                    id: "seg_backend",
                    startSeconds: 0,
                    endSeconds: 12,
                    text: "Backend transcript.",
                    isMarkedImportant: true
                )
            ],
            unclearFragments: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let objectKey = "audio/idea_backend_ai/rec_backend_ai.m4a"
        let transport = SequencedHTTPRequestTransport(
            responses: [
                try backendAudioObjectMetadataResponse(
                    objectKey: objectKey,
                    recordingID: "rec_backend_ai",
                    ideaProjectID: "idea_backend_ai"
                ),
                HTTPTestResponse(
                    data: try encoder.encode(transcript),
                    statusCode: 200
                )
            ]
        )
        let service = BackendTranscriptionService(
            configuration: BackendAIConfiguration(
                baseURL: URL(string: "https://api.example.test")!,
                bearerToken: "ai-token",
                workspaceID: "workspace_alpha",
                transcriptionPath: "/ai/transcribe"
            ),
            transport: transport
        )
        let recording = Recording(
            id: "rec_backend_ai",
            ideaProjectID: "idea_backend_ai",
            deviceName: "iPhone",
            durationSeconds: 12,
            localFileStatus: .uploaded,
            syncStatus: .uploaded,
            localAudioPath: "recordings/backend.m4a",
            audioObjectKey: objectKey,
            languageHint: "en-US",
            createdAt: SampleData.now,
            markerOffsets: [4]
        )

        let decoded = try await service.transcript(for: recording, hint: "Prefer product language.")
        let requests = await transport.capturedRequests()
        let capturedRequest = try XCTUnwrap(requests.last)
        let body = try XCTUnwrap(capturedRequest.httpBody)
        let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any]

        XCTAssertEqual(decoded, transcript)
        XCTAssertEqual(requests.map { $0.httpMethod }, ["GET", "POST"])
        XCTAssertEqual(capturedRequest.url?.absoluteString, "https://api.example.test/ai/transcribe")
        XCTAssertEqual(capturedRequest.httpMethod, "POST")
        XCTAssertEqual(capturedRequest.value(forHTTPHeaderField: "Authorization"), "Bearer ai-token")
        XCTAssertEqual(capturedRequest.value(forHTTPHeaderField: "X-IdeaForge-Workspace-ID"), "workspace_alpha")
        XCTAssertEqual(payload?["recordingID"] as? String, "rec_backend_ai")
        XCTAssertEqual(payload?["audioObjectKey"] as? String, "audio/idea_backend_ai/rec_backend_ai.m4a")
        XCTAssertEqual(payload?["languageHint"] as? String, "en-US")
    }

    func testBackendTranscriptionServiceChecksAudioObjectMetadataBeforePosting() async throws {
        let transcript = Transcript(
            cleanText: "Backend transcript.",
            segments: [
                TranscriptSegment(
                    id: "seg_backend_metadata",
                    startSeconds: 0,
                    endSeconds: 12,
                    text: "Backend transcript.",
                    isMarkedImportant: false
                )
            ],
            unclearFragments: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let objectKey = "audio/idea_backend_ai/rec_backend_metadata.m4a"
        let transport = SequencedHTTPRequestTransport(
            responses: [
                HTTPTestResponse(
                    data: try encoder.encode(BackendAudioObjectMetadataTestResponse(
                        objectKey: objectKey,
                        recordingID: "rec_backend_metadata",
                        ideaProjectID: "idea_backend_ai",
                        byteCount: 2048,
                        contentType: "audio/mp4",
                        isAvailable: true
                    )),
                    statusCode: 200
                ),
                HTTPTestResponse(
                    data: try encoder.encode(transcript),
                    statusCode: 200
                )
            ]
        )
        let service = BackendTranscriptionService(
            configuration: BackendAIConfiguration(
                baseURL: URL(string: "https://api.example.test")!,
                bearerToken: "ai-token",
                workspaceID: "workspace_alpha",
                transcriptionPath: "/ai/transcribe"
            ),
            transport: transport
        )
        let recording = Recording(
            id: "rec_backend_metadata",
            ideaProjectID: "idea_backend_ai",
            deviceName: "iPhone",
            durationSeconds: 12,
            localFileStatus: .uploaded,
            syncStatus: .uploaded,
            localAudioPath: "recordings/backend.m4a",
            audioObjectKey: objectKey,
            languageHint: "en-US",
            createdAt: SampleData.now,
            markerOffsets: []
        )

        let decoded = try await service.transcript(for: recording, hint: "")
        let requests = await transport.capturedRequests()

        XCTAssertEqual(decoded, transcript)
        XCTAssertEqual(requests.map { $0.httpMethod }, ["GET", "POST"])
        XCTAssertEqual(requests[0].url?.path, "/v1/objects/metadata")
        XCTAssertEqual(
            URLComponents(url: try XCTUnwrap(requests[0].url), resolvingAgainstBaseURL: false)?
                .queryItems?
                .first { $0.name == "objectKey" }?
                .value,
            objectKey
        )
        XCTAssertEqual(requests[1].url?.absoluteString, "https://api.example.test/ai/transcribe")
        XCTAssertTrue(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer ai-token"
                && $0.value(forHTTPHeaderField: "X-IdeaForge-Workspace-ID") == "workspace_alpha"
                && $0.value(forHTTPHeaderField: "Accept") == "application/json"
        })
    }

    func testBackendTranscriptionServiceRejectsMismatchedAudioObjectMetadata() async throws {
        let objectKey = "audio/idea_backend_ai/rec_backend_metadata_stale.m4a"
        let transport = SequencedHTTPRequestTransport(
            responses: [
                try backendAudioObjectMetadataResponse(
                    objectKey: objectKey,
                    recordingID: "rec_other",
                    ideaProjectID: "idea_backend_ai"
                )
            ]
        )
        let service = BackendTranscriptionService(
            configuration: BackendAIConfiguration(
                baseURL: URL(string: "https://api.example.test")!,
                bearerToken: "ai-token",
                workspaceID: "workspace_alpha",
                transcriptionPath: "/ai/transcribe"
            ),
            transport: transport
        )
        let recording = Recording(
            id: "rec_backend_metadata_stale",
            ideaProjectID: "idea_backend_ai",
            deviceName: "iPhone",
            durationSeconds: 12,
            localFileStatus: .uploaded,
            syncStatus: .uploaded,
            audioObjectKey: objectKey,
            languageHint: "en-US",
            createdAt: SampleData.now,
            markerOffsets: []
        )

        do {
            _ = try await service.transcript(for: recording, hint: "")
            XCTFail("Expected stale object metadata to fail before transcription.")
        } catch BackendAIError.providerFailure(let failure) {
            XCTAssertEqual(failure.statusCode, 409)
            XCTAssertEqual(failure.code, "audio_object_recording_mismatch")
            XCTAssertFalse(failure.isRetryable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.map { $0.httpMethod }, ["GET"])
    }

    func testAudioTranscriptionChunkPlannerBoundsShortAndLongRecordings() {
        let shortPlan = AudioTranscriptionChunkPlanner.chunks(
            recordingID: "rec_short",
            audioObjectKey: "audio/idea/rec_short.m4a",
            durationSeconds: 42
        )
        let longPlan = AudioTranscriptionChunkPlanner.chunks(
            recordingID: "rec_long",
            audioObjectKey: "audio/idea/rec_long.m4a",
            durationSeconds: 1500
        )

        XCTAssertEqual(
            shortPlan,
            [
                AudioTranscriptionChunk(
                    id: "rec_short_chunk_1",
                    audioObjectKey: "audio/idea/rec_short.m4a",
                    startSeconds: 0,
                    endSeconds: 42
                )
            ]
        )
        XCTAssertEqual(longPlan.map(\.startSeconds), [0, 595, 1190])
        XCTAssertEqual(longPlan.map(\.endSeconds), [600, 1195, 1500])
        XCTAssertTrue(longPlan.allSatisfy { $0.audioObjectKey == "audio/idea/rec_long.m4a" })
    }

    func testTranscriptContractValidatorRequiresUsableSegments() {
        let recording = Recording(
            id: "rec_empty_segments",
            ideaProjectID: "idea_backend_ai",
            deviceName: "iPhone",
            durationSeconds: 30,
            localFileStatus: .uploaded,
            syncStatus: .uploaded,
            localAudioPath: "recordings/empty.m4a",
            audioObjectKey: "audio/idea_backend_ai/rec_empty_segments.m4a",
            languageHint: "en-US",
            createdAt: SampleData.now,
            markerOffsets: []
        )
        let validation = TranscriptContractValidator.validate(
            transcript: Transcript(
                cleanText: "Backend transcript.",
                segments: [],
                unclearFragments: []
            ),
            recording: recording
        )

        XCTAssertFalse(validation.isValid)
        XCTAssertEqual(validation.issues, ["Transcript has no segments."])
    }

    func testBackendTranscriptionServiceSendsBoundedAudioChunkPlanForLongRecordings() async throws {
        let transcript = Transcript(
            cleanText: "Long backend transcript.",
            segments: [
                TranscriptSegment(
                    id: "seg_long_backend",
                    startSeconds: 0,
                    endSeconds: 1500,
                    text: "Long backend transcript.",
                    isMarkedImportant: false
                )
            ],
            unclearFragments: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let objectKey = "audio/idea_backend_ai/rec_long_backend.m4a"
        let transport = SequencedHTTPRequestTransport(
            responses: [
                try backendAudioObjectMetadataResponse(
                    objectKey: objectKey,
                    recordingID: "rec_long_backend",
                    ideaProjectID: "idea_backend_ai",
                    byteCount: 5_000_000
                ),
                HTTPTestResponse(
                    data: try encoder.encode(transcript),
                    statusCode: 200
                )
            ]
        )
        let service = BackendTranscriptionService(
            configuration: BackendAIConfiguration(
                baseURL: URL(string: "https://api.example.test")!,
                bearerToken: "ai-token",
                workspaceID: "workspace_alpha"
            ),
            transport: transport
        )
        let recording = Recording(
            id: "rec_long_backend",
            ideaProjectID: "idea_backend_ai",
            deviceName: "iPhone",
            durationSeconds: 1500,
            localFileStatus: .uploaded,
            syncStatus: .uploaded,
            localAudioPath: "recordings/long.m4a",
            audioObjectKey: objectKey,
            languageHint: "en-US",
            createdAt: SampleData.now,
            markerOffsets: [600, 1200]
        )

        _ = try await service.transcript(for: recording, hint: "")
        let requests = await transport.capturedRequests()
        let capturedRequest = try XCTUnwrap(requests.last)
        let body = try XCTUnwrap(capturedRequest.httpBody)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let chunks = try XCTUnwrap(payload["audioChunks"] as? [[String: Any]])

        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks[0]["id"] as? String, "rec_long_backend_chunk_1")
        XCTAssertEqual(chunks[0]["audioObjectKey"] as? String, "audio/idea_backend_ai/rec_long_backend.m4a")
        XCTAssertEqual(chunks[0]["startSeconds"] as? Int, 0)
        XCTAssertEqual(chunks[0]["endSeconds"] as? Int, 600)
        XCTAssertEqual(chunks[1]["startSeconds"] as? Int, 595)
        XCTAssertEqual(chunks[1]["endSeconds"] as? Int, 1195)
        XCTAssertEqual(chunks[2]["startSeconds"] as? Int, 1190)
        XCTAssertEqual(chunks[2]["endSeconds"] as? Int, 1500)
    }

    func testBackendTranscriptionServicePollsAcceptedJobUntilCompleted() async throws {
        let transcript = Transcript(
            cleanText: "Async backend transcript.",
            segments: [
                TranscriptSegment(
                    id: "seg_async_backend",
                    startSeconds: 0,
                    endSeconds: 30,
                    text: "Async backend transcript.",
                    isMarkedImportant: false
                )
            ],
            unclearFragments: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let objectKey = "audio/idea_backend_ai/rec_async_backend.m4a"
        let transport = SequencedHTTPRequestTransport(
            responses: [
                try backendAudioObjectMetadataResponse(
                    objectKey: objectKey,
                    recordingID: "rec_async_backend",
                    ideaProjectID: "idea_backend_ai"
                ),
                HTTPTestResponse(
                    data: Data(#"{"jobID":"job_transcribe_1","status":"queued"}"#.utf8),
                    statusCode: 202
                ),
                HTTPTestResponse(
                    data: Data(#"{"jobID":"job_transcribe_1","status":"running"}"#.utf8),
                    statusCode: 200
                ),
                HTTPTestResponse(
                    data: try encoder.encode(BackendTranscriptionJobTestResponse(
                        jobID: "job_transcribe_1",
                        status: "completed",
                        transcript: transcript
                    )),
                    statusCode: 200
                )
            ]
        )
        let service = BackendTranscriptionService(
            configuration: BackendAIConfiguration(
                baseURL: URL(string: "https://api.example.test")!,
                bearerToken: "ai-token",
                workspaceID: "workspace_alpha",
                transcriptionPath: "/ai/transcribe",
                transcriptionJobStatusPath: "/ai/transcription-jobs"
            ),
            transport: transport,
            maxJobPollAttempts: 3,
            jobPollDelayNanoseconds: 0
        )
        let recording = Recording(
            id: "rec_async_backend",
            ideaProjectID: "idea_backend_ai",
            deviceName: "iPhone",
            durationSeconds: 30,
            localFileStatus: .uploaded,
            syncStatus: .uploaded,
            localAudioPath: "recordings/async.m4a",
            audioObjectKey: objectKey,
            languageHint: "en-US",
            createdAt: SampleData.now,
            markerOffsets: []
        )

        let decoded = try await service.transcript(for: recording, hint: "Async job.")
        let requests = await transport.capturedRequests()

        XCTAssertEqual(decoded, transcript)
        XCTAssertEqual(requests.map { $0.httpMethod }, ["GET", "POST", "GET", "GET"])
        XCTAssertEqual(requests[0].url?.path, "/v1/objects/metadata")
        XCTAssertEqual(requests[1].url?.absoluteString, "https://api.example.test/ai/transcribe")
        XCTAssertEqual(requests[2].url?.absoluteString, "https://api.example.test/ai/transcription-jobs/job_transcribe_1")
        XCTAssertEqual(requests[3].url?.absoluteString, "https://api.example.test/ai/transcription-jobs/job_transcribe_1")
        XCTAssertTrue(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer ai-token"
                && $0.value(forHTTPHeaderField: "X-IdeaForge-Workspace-ID") == "workspace_alpha"
                && $0.value(forHTTPHeaderField: "Accept") == "application/json"
        })
    }

    func testBackendTranscriptionServiceFailsClosedWhenAcceptedJobDoesNotComplete() async throws {
        let objectKey = "audio/idea_backend_ai/rec_async_timeout.m4a"
        let transport = SequencedHTTPRequestTransport(
            responses: [
                try backendAudioObjectMetadataResponse(
                    objectKey: objectKey,
                    recordingID: "rec_async_timeout",
                    ideaProjectID: "idea_backend_ai"
                ),
                HTTPTestResponse(
                    data: Data(#"{"jobID":"job_transcribe_timeout","status":"queued"}"#.utf8),
                    statusCode: 202
                ),
                HTTPTestResponse(
                    data: Data(#"{"jobID":"job_transcribe_timeout","status":"running"}"#.utf8),
                    statusCode: 200
                ),
                HTTPTestResponse(
                    data: Data(#"{"jobID":"job_transcribe_timeout","status":"running"}"#.utf8),
                    statusCode: 200
                )
            ]
        )
        let service = BackendTranscriptionService(
            configuration: BackendAIConfiguration(
                baseURL: URL(string: "https://api.example.test")!,
                bearerToken: "ai-token",
                workspaceID: "workspace_alpha",
                transcriptionPath: "/ai/transcribe",
                transcriptionJobStatusPath: "/ai/transcription-jobs"
            ),
            transport: transport,
            maxJobPollAttempts: 2,
            jobPollDelayNanoseconds: 0
        )
        let recording = Recording(
            id: "rec_async_timeout",
            ideaProjectID: "idea_backend_ai",
            deviceName: "iPhone",
            durationSeconds: 30,
            localFileStatus: .uploaded,
            syncStatus: .uploaded,
            audioObjectKey: objectKey,
            languageHint: "en-US",
            createdAt: SampleData.now,
            markerOffsets: []
        )

        do {
            _ = try await service.transcript(for: recording, hint: "")
            XCTFail("Expected bounded async transcription polling to fail closed.")
        } catch BackendAIError.providerFailure(let failure) {
            XCTAssertEqual(failure.code, "transcription_job_timeout")
            XCTAssertEqual(failure.statusCode, 202)
            XCTAssertTrue(failure.isRetryable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testBackendTranscriptionServiceNormalizesFailedAcceptedJobDiagnostics() async throws {
        let encoder = JSONEncoder()
        let objectKey = "audio/idea_backend_ai/rec_async_failed.m4a"
        let transport = SequencedHTTPRequestTransport(
            responses: [
                try backendAudioObjectMetadataResponse(
                    objectKey: objectKey,
                    recordingID: "rec_async_failed",
                    ideaProjectID: "idea_backend_ai"
                ),
                HTTPTestResponse(
                    data: Data(#"{"jobID":"job_transcribe_failed","status":"queued"}"#.utf8),
                    statusCode: 202
                ),
                HTTPTestResponse(
                    data: try encoder.encode(BackendTranscriptionJobTestResponse(
                        jobID: "job_transcribe_failed",
                        status: "failed",
                        transcript: nil,
                        code: "Provider Timeout!",
                        retryable: true
                    )),
                    statusCode: 200
                )
            ]
        )
        let service = BackendTranscriptionService(
            configuration: BackendAIConfiguration(
                baseURL: URL(string: "https://api.example.test")!,
                bearerToken: "ai-token",
                workspaceID: "workspace_alpha",
                transcriptionPath: "/ai/transcribe",
                transcriptionJobStatusPath: "/ai/transcription-jobs"
            ),
            transport: transport,
            maxJobPollAttempts: 2,
            jobPollDelayNanoseconds: 0
        )
        let recording = Recording(
            id: "rec_async_failed",
            ideaProjectID: "idea_backend_ai",
            deviceName: "iPhone",
            durationSeconds: 30,
            localFileStatus: .uploaded,
            syncStatus: .uploaded,
            audioObjectKey: objectKey,
            languageHint: "en-US",
            createdAt: SampleData.now,
            markerOffsets: []
        )

        do {
            _ = try await service.transcript(for: recording, hint: "")
            XCTFail("Expected failed async transcription job diagnostics.")
        } catch BackendAIError.providerFailure(let failure) {
            XCTAssertEqual(failure.code, "provider_timeout")
            XCTAssertEqual(failure.statusCode, 200)
            XCTAssertTrue(failure.isRetryable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testBackendTranscriptionServiceRejectsMalformedTranscriptContract() async throws {
        let malformedTranscript = Transcript(
            cleanText: "   ",
            segments: [
                TranscriptSegment(
                    id: "seg_blank",
                    startSeconds: 0,
                    endSeconds: 20,
                    text: "   ",
                    isMarkedImportant: false
                ),
                TranscriptSegment(
                    id: "seg_overlap",
                    startSeconds: 10,
                    endSeconds: 11,
                    text: "Overlap.",
                    isMarkedImportant: false
                )
            ],
            unclearFragments: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let objectKey = "audio/idea_backend_ai/rec_malformed_backend.m4a"
        let transport = SequencedHTTPRequestTransport(
            responses: [
                try backendAudioObjectMetadataResponse(
                    objectKey: objectKey,
                    recordingID: "rec_malformed_backend",
                    ideaProjectID: "idea_backend_ai"
                ),
                HTTPTestResponse(
                    data: try encoder.encode(malformedTranscript),
                    statusCode: 200
                )
            ]
        )
        let service = BackendTranscriptionService(
            configuration: BackendAIConfiguration(
                baseURL: URL(string: "https://api.example.test")!,
                bearerToken: "ai-token",
                workspaceID: "workspace_alpha"
            ),
            transport: transport
        )
        let recording = Recording(
            id: "rec_malformed_backend",
            ideaProjectID: "idea_backend_ai",
            deviceName: "iPhone",
            durationSeconds: 12,
            localFileStatus: .uploaded,
            syncStatus: .uploaded,
            localAudioPath: "recordings/malformed.m4a",
            audioObjectKey: objectKey,
            languageHint: "en-US",
            createdAt: SampleData.now,
            markerOffsets: []
        )

        do {
            _ = try await service.transcript(for: recording, hint: "")
            XCTFail("Malformed backend transcript should fail contract validation.")
        } catch BackendAIError.contractViolation(let issues) {
            XCTAssertEqual(
                issues,
                [
                    "Transcript clean text is empty.",
                    "Transcript segment 1 text is empty.",
                    "Transcript segment 1 ends after recording duration.",
                    "Transcript segment 2 overlaps or is out of order."
                ]
            )
        }
    }

    func testBackendTranscriptionServiceMapsProviderFailure() async throws {
        let body = """
        {
          "error": "Rate Limit Exceeded",
          "retryable": true
        }
        """.data(using: .utf8)!
        let objectKey = "audio/idea_backend_ai/rec_backend_ai_failed.m4a"
        let transport = SequencedHTTPRequestTransport(
            responses: [
                try backendAudioObjectMetadataResponse(
                    objectKey: objectKey,
                    recordingID: "rec_backend_ai_failed",
                    ideaProjectID: "idea_backend_ai"
                ),
                HTTPTestResponse(data: body, statusCode: 429)
            ]
        )
        let service = BackendTranscriptionService(
            configuration: BackendAIConfiguration(
                baseURL: URL(string: "https://api.example.test")!,
                bearerToken: "ai-token",
                workspaceID: "workspace_alpha",
                transcriptionPath: "/ai/transcribe"
            ),
            transport: transport
        )
        let recording = Recording(
            id: "rec_backend_ai_failed",
            ideaProjectID: "idea_backend_ai",
            deviceName: "iPhone",
            durationSeconds: 12,
            localFileStatus: .uploaded,
            syncStatus: .uploaded,
            localAudioPath: "recordings/backend.m4a",
            audioObjectKey: objectKey,
            languageHint: "en-US",
            createdAt: SampleData.now,
            markerOffsets: []
        )

        do {
            _ = try await service.transcript(for: recording, hint: "Prefer product language.")
            XCTFail("Expected backend provider failure.")
        } catch BackendAIError.providerFailure(let failure) {
            XCTAssertEqual(failure.statusCode, 429)
            XCTAssertEqual(failure.code, "rate_limit_exceeded")
            XCTAssertTrue(failure.isRetryable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testBackendTranscriptionServiceMapsEntitlementExhaustionAsNonRetryableProviderFailure() async throws {
        let body = """
        {
          "error": "entitlement_exhausted",
          "code": "entitlement_exhausted",
          "metric": "transcription_seconds",
          "retryable": false,
          "remainingQuantity": 0.0
        }
        """.data(using: .utf8)!
        let objectKey = "audio/idea_backend_ai/rec_backend_ai_entitlement.m4a"
        let transport = SequencedHTTPRequestTransport(
            responses: [
                try backendAudioObjectMetadataResponse(
                    objectKey: objectKey,
                    recordingID: "rec_backend_ai_entitlement",
                    ideaProjectID: "idea_backend_ai"
                ),
                HTTPTestResponse(data: body, statusCode: 402)
            ]
        )
        let service = BackendTranscriptionService(
            configuration: BackendAIConfiguration(
                baseURL: URL(string: "https://api.example.test")!,
                bearerToken: "ai-token",
                workspaceID: "workspace_alpha",
                transcriptionPath: "/ai/transcribe"
            ),
            transport: transport
        )
        let recording = Recording(
            id: "rec_backend_ai_entitlement",
            ideaProjectID: "idea_backend_ai",
            deviceName: "iPhone",
            durationSeconds: 12,
            localFileStatus: .uploaded,
            syncStatus: .uploaded,
            audioObjectKey: objectKey,
            languageHint: "en-US",
            createdAt: SampleData.now,
            markerOffsets: []
        )

        do {
            _ = try await service.transcript(for: recording, hint: "Prefer product language.")
            XCTFail("Expected backend entitlement failure.")
        } catch BackendAIError.providerFailure(let failure) {
            XCTAssertEqual(failure.statusCode, 402)
            XCTAssertEqual(failure.code, "entitlement_exhausted")
            XCTAssertFalse(failure.isRetryable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testBackendWorkflowExecutionServicePostsProjectAndDecodesArtifacts() async throws {
        let artifact = Artifact(
            id: "artifact_backend_prd",
            kind: .prd,
            title: "Backend PRD",
            markdown: """
            # Backend PRD

            ## Goals
            - Shape the product plan.

            ## Requirements
            - Preserve reviewable workflow output.

            ## Acceptance Criteria
            - Required schema fields are present.

            ## Validation
            - Evidence is attached before implementation.

            ## Risks
            - Provider output can drift.
            """,
            version: 1,
            createdBy: "backend-ai",
            createdAt: SampleData.now
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let transport = CapturingHTTPRequestTransport(
            responseData: try encoder.encode(BackendWorkflowTestResponse(artifacts: [artifact])),
            statusCode: 200
        )
        let service = BackendWorkflowExecutionService(
            configuration: BackendAIConfiguration(
                baseURL: URL(string: "https://api.example.test")!,
                bearerToken: "ai-token",
                workspaceID: "workspace_alpha",
                workflowPath: "/ai/workflow"
            ),
            transport: transport
        )
        let template = try XCTUnwrap(DefaultWorkflows.templates.first { $0.id == "wf_prd" })

        let artifacts = try await service.run(template: template, project: SampleData.ideaForgeProject)
        let maybeCapturedRequest = await transport.capturedRequest()
        let capturedRequest = try XCTUnwrap(maybeCapturedRequest)
        let body = try XCTUnwrap(capturedRequest.httpBody)
        let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let encodedTemplate = payload?["template"] as? [String: Any]
        let encodedProject = payload?["project"] as? [String: Any]
        let outputContract = payload?["outputContract"] as? [String: Any]
        let artifactOutputs = outputContract?["artifactOutputs"] as? [[String: Any]]
        let firstOutput = artifactOutputs?.first
        let requiredFields = firstOutput?["requiredFields"] as? [[String: Any]]
        let rubricRequirements = outputContract?["rubricRequirements"] as? [String]

        XCTAssertEqual(artifacts, [artifact])
        XCTAssertEqual(capturedRequest.url?.absoluteString, "https://api.example.test/ai/workflow")
        XCTAssertEqual(capturedRequest.httpMethod, "POST")
        XCTAssertEqual(capturedRequest.value(forHTTPHeaderField: "Authorization"), "Bearer ai-token")
        XCTAssertEqual(capturedRequest.value(forHTTPHeaderField: "X-IdeaForge-Workspace-ID"), "workspace_alpha")
        XCTAssertEqual(encodedTemplate?["id"] as? String, "wf_prd")
        XCTAssertEqual(encodedProject?["id"] as? String, SampleData.ideaForgeProject.id)
        XCTAssertEqual(outputContract?["version"] as? Int, 1)
        XCTAssertEqual(artifactOutputs?.count, 1)
        XCTAssertEqual(firstOutput?["kind"] as? String, "prd")
        XCTAssertEqual(firstOutput?["label"] as? String, "PRD")
        XCTAssertEqual(firstOutput?["schemaName"] as? String, "PRDArtifact")
        XCTAssertEqual(requiredFields?.map { $0["name"] as? String }, ["goals", "requirements", "acceptance_criteria"])
        XCTAssertEqual(requiredFields?.map { $0["valueType"] as? String }, ["list", "list", "list"])
        XCTAssertTrue(rubricRequirements?.contains("actionability") == true)
        XCTAssertTrue(rubricRequirements?.contains("risk_coverage") == true)
    }

    func testBackendWorkflowExecutionServicePollsAcceptedJobUntilCompleted() async throws {
        let artifact = Artifact(
            id: "artifact_async_prd",
            kind: .prd,
            title: "Async PRD",
            markdown: """
            # Async PRD

            ## Goals
            - Shape the reviewed product plan.

            ## Requirements
            - Preserve schema-backed workflow output.

            ## Acceptance Criteria
            - Required fields are present before acceptance.

            ## Validation
            - Use verifier evidence before handoff.

            ## Risks
            - Provider output may drift.
            """,
            version: 1,
            createdBy: "backend-ai",
            createdAt: SampleData.now
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let transport = SequencedHTTPRequestTransport(
            responses: [
                HTTPTestResponse(
                    data: Data(#"{"jobID":"job_workflow_1","status":"queued"}"#.utf8),
                    statusCode: 202
                ),
                HTTPTestResponse(
                    data: Data(#"{"jobID":"job_workflow_1","status":"running"}"#.utf8),
                    statusCode: 200
                ),
                HTTPTestResponse(
                    data: try encoder.encode(BackendWorkflowJobTestResponse(
                        jobID: "job_workflow_1",
                        status: "completed",
                        artifacts: [artifact]
                    )),
                    statusCode: 200
                )
            ]
        )
        let service = BackendWorkflowExecutionService(
            configuration: BackendAIConfiguration(
                baseURL: URL(string: "https://api.example.test")!,
                bearerToken: "ai-token",
                workspaceID: "workspace_alpha",
                workflowPath: "/ai/workflow",
                workflowJobStatusPath: "/ai/workflow-jobs"
            ),
            transport: transport,
            maxJobPollAttempts: 3,
            jobPollDelayNanoseconds: 0
        )
        let template = try XCTUnwrap(DefaultWorkflows.templates.first { $0.id == "wf_prd" })

        let artifacts = try await service.run(template: template, project: SampleData.ideaForgeProject)
        let requests = await transport.capturedRequests()

        XCTAssertEqual(artifacts, [artifact])
        XCTAssertEqual(requests.map { $0.httpMethod }, ["POST", "GET", "GET"])
        XCTAssertEqual(requests[0].url?.absoluteString, "https://api.example.test/ai/workflow")
        XCTAssertEqual(requests[1].url?.absoluteString, "https://api.example.test/ai/workflow-jobs/job_workflow_1")
        XCTAssertEqual(requests[2].url?.absoluteString, "https://api.example.test/ai/workflow-jobs/job_workflow_1")
        XCTAssertTrue(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer ai-token"
                && $0.value(forHTTPHeaderField: "X-IdeaForge-Workspace-ID") == "workspace_alpha"
                && $0.value(forHTTPHeaderField: "Accept") == "application/json"
        })
    }

    func testBackendWorkflowExecutionServiceFailsClosedWhenAcceptedJobDoesNotComplete() async throws {
        let transport = SequencedHTTPRequestTransport(
            responses: [
                HTTPTestResponse(
                    data: Data(#"{"jobID":"job_workflow_timeout","status":"queued"}"#.utf8),
                    statusCode: 202
                ),
                HTTPTestResponse(
                    data: Data(#"{"jobID":"job_workflow_timeout","status":"running"}"#.utf8),
                    statusCode: 200
                ),
                HTTPTestResponse(
                    data: Data(#"{"jobID":"job_workflow_timeout","status":"running"}"#.utf8),
                    statusCode: 200
                )
            ]
        )
        let service = BackendWorkflowExecutionService(
            configuration: BackendAIConfiguration(
                baseURL: URL(string: "https://api.example.test")!,
                bearerToken: "ai-token",
                workspaceID: "workspace_alpha",
                workflowPath: "/ai/workflow",
                workflowJobStatusPath: "/ai/workflow-jobs"
            ),
            transport: transport,
            maxJobPollAttempts: 2,
            jobPollDelayNanoseconds: 0
        )
        let template = try XCTUnwrap(DefaultWorkflows.templates.first { $0.id == "wf_prd" })

        do {
            _ = try await service.run(template: template, project: SampleData.ideaForgeProject)
            XCTFail("Expected bounded async workflow polling to fail closed.")
        } catch BackendAIError.providerFailure(let failure) {
            XCTAssertEqual(failure.code, "workflow_job_timeout")
            XCTAssertEqual(failure.statusCode, 202)
            XCTAssertTrue(failure.isRetryable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testBackendWorkflowExecutionServiceNormalizesFailedAcceptedJobDiagnostics() async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let transport = SequencedHTTPRequestTransport(
            responses: [
                HTTPTestResponse(
                    data: Data(#"{"jobID":"job_workflow_failed","status":"queued"}"#.utf8),
                    statusCode: 202
                ),
                HTTPTestResponse(
                    data: try encoder.encode(BackendWorkflowJobTestResponse(
                        jobID: "job_workflow_failed",
                        status: "failed",
                        artifacts: nil,
                        code: "Provider Timeout!",
                        retryable: true
                    )),
                    statusCode: 200
                )
            ]
        )
        let service = BackendWorkflowExecutionService(
            configuration: BackendAIConfiguration(
                baseURL: URL(string: "https://api.example.test")!,
                bearerToken: "ai-token",
                workspaceID: "workspace_alpha",
                workflowPath: "/ai/workflow",
                workflowJobStatusPath: "/ai/workflow-jobs"
            ),
            transport: transport,
            maxJobPollAttempts: 2,
            jobPollDelayNanoseconds: 0
        )
        let template = try XCTUnwrap(DefaultWorkflows.templates.first { $0.id == "wf_prd" })

        do {
            _ = try await service.run(template: template, project: SampleData.ideaForgeProject)
            XCTFail("Expected failed async workflow job to throw provider diagnostics.")
        } catch BackendAIError.providerFailure(let failure) {
            XCTAssertEqual(failure.statusCode, 200)
            XCTAssertEqual(failure.code, "provider_timeout")
            XCTAssertTrue(failure.isRetryable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testBackendWorkflowExecutionServiceRejectsContractViolatingCompletedJob() async throws {
        let artifact = Artifact(
            id: "artifact_async_thin",
            kind: .codexTaskBundle,
            title: "Thin Async Codex Packet",
            markdown: "# Build\n\nRun unreviewed tools.",
            version: 1,
            createdBy: "backend-ai",
            createdAt: SampleData.now
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let transport = SequencedHTTPRequestTransport(
            responses: [
                HTTPTestResponse(
                    data: Data(#"{"jobID":"job_workflow_contract","status":"queued"}"#.utf8),
                    statusCode: 202
                ),
                HTTPTestResponse(
                    data: try encoder.encode(BackendWorkflowJobTestResponse(
                        jobID: "job_workflow_contract",
                        status: "completed",
                        artifacts: [artifact]
                    )),
                    statusCode: 200
                )
            ]
        )
        let service = BackendWorkflowExecutionService(
            configuration: BackendAIConfiguration(
                baseURL: URL(string: "https://api.example.test")!,
                bearerToken: "ai-token",
                workspaceID: "workspace_alpha",
                workflowPath: "/ai/workflow",
                workflowJobStatusPath: "/ai/workflow-jobs"
            ),
            transport: transport,
            maxJobPollAttempts: 2,
            jobPollDelayNanoseconds: 0
        )
        let template = try XCTUnwrap(DefaultWorkflows.templates.first { $0.id == "wf_codex_packet" })

        do {
            _ = try await service.run(template: template, project: SampleData.ideaForgeProject)
            XCTFail("Expected contract-violating async workflow output to be rejected.")
        } catch BackendAIError.contractViolation(let issues) {
            XCTAssertTrue(issues.contains("Missing expected artifacts: Architecture."))
            XCTAssertTrue(issues.contains("CodexPacketSchema missing required fields: repo_context, tasks, checks."))
            XCTAssertTrue(issues.contains("AI rubric failed: Handoff Safety."))
            XCTAssertFalse(issues.joined(separator: " ").contains(artifact.markdown))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testBackendWorkflowExecutionServiceMapsNonJSONProviderFailure() async throws {
        let transport = CapturingHTTPRequestTransport(
            responseData: Data("service temporarily unavailable".utf8),
            statusCode: 503
        )
        let service = BackendWorkflowExecutionService(
            configuration: BackendAIConfiguration(
                baseURL: URL(string: "https://api.example.test")!,
                bearerToken: "ai-token",
                workspaceID: "workspace_alpha",
                workflowPath: "/ai/workflow"
            ),
            transport: transport
        )
        let template = try XCTUnwrap(DefaultWorkflows.templates.first { $0.id == "wf_prd" })

        do {
            _ = try await service.run(template: template, project: SampleData.ideaForgeProject)
            XCTFail("Expected backend provider failure.")
        } catch BackendAIError.providerFailure(let failure) {
            XCTAssertEqual(failure.statusCode, 503)
            XCTAssertEqual(failure.code, "backend_ai_request_failed")
            XCTAssertTrue(failure.isRetryable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testBackendWorkflowExecutionServiceSendsCodexHandoffOutputContract() async throws {
        let artifacts = [
            Artifact(
                id: "artifact_backend_codex",
                kind: .codexTaskBundle,
                title: "Backend Codex Packet",
                markdown: """
                # Codex Packet

                ## Repo Context
                Build inside the IdeaForge repository.

                ## Tasks
                - Implement the reviewed slice.

                ## Checks
                - Run swift test.

                ## Risks
                - Review before external handoff.

                ## Approval Boundary
                Do not execute tools without operator approval.

                ## Evidence
                - Based on reviewed project state.
                """,
                version: 1,
                createdBy: "backend-ai",
                createdAt: SampleData.now
            ),
            Artifact(
                id: "artifact_backend_architecture",
                kind: .architecture,
                title: "Backend Architecture",
                markdown: """
                # Architecture

                ## Decision
                Keep app logic in shared core.

                ## Components
                - macOS app.
                - Shared IdeaForgeCore services.

                ## Risks
                - Validate provider output before accepting artifacts.

                ## Evidence
                - Based on reviewed project state.

                ## Next Steps
                - Run release checks.
                """,
                version: 1,
                createdBy: "backend-ai",
                createdAt: SampleData.now
            )
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let transport = CapturingHTTPRequestTransport(
            responseData: try encoder.encode(BackendWorkflowTestResponse(artifacts: artifacts)),
            statusCode: 200
        )
        let service = BackendWorkflowExecutionService(
            configuration: BackendAIConfiguration(
                baseURL: URL(string: "https://api.example.test")!,
                bearerToken: "ai-token",
                workspaceID: "workspace_alpha",
                workflowPath: "/ai/workflow"
            ),
            transport: transport
        )
        let template = try XCTUnwrap(DefaultWorkflows.templates.first { $0.id == "wf_codex_packet" })

        _ = try await service.run(template: template, project: SampleData.ideaForgeProject)
        let maybeCapturedRequest = await transport.capturedRequest()
        let capturedRequest = try XCTUnwrap(maybeCapturedRequest)
        let body = try XCTUnwrap(capturedRequest.httpBody)
        let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let outputContract = payload?["outputContract"] as? [String: Any]
        let artifactOutputs = outputContract?["artifactOutputs"] as? [[String: Any]]
        let rubricRequirements = outputContract?["rubricRequirements"] as? [String]
        let structuredOutput = outputContract?["structuredOutput"] as? [String: Any]
        let schema = structuredOutput?["schema"] as? [String: Any]
        let properties = schema?["properties"] as? [String: Any]
        let artifactsSchema = properties?["artifacts"] as? [String: Any]
        let itemSchema = artifactsSchema?["items"] as? [String: Any]
        let itemProperties = itemSchema?["properties"] as? [String: Any]
        let kindSchema = itemProperties?["kind"] as? [String: Any]

        XCTAssertEqual(artifactOutputs?.map { $0["kind"] as? String }, ["codexTaskBundle", "architecture"])
        XCTAssertEqual(artifactOutputs?.map { $0["schemaName"] as? String }, ["CodexPacketSchema", "ArchitectureArtifact"])
        XCTAssertEqual((artifactOutputs?.first?["requiredFields"] as? [[String: Any]])?.map { $0["name"] as? String }, ["repo_context", "tasks", "checks"])
        XCTAssertTrue(rubricRequirements?.contains("handoff_safety") == true)
        XCTAssertEqual(structuredOutput?["name"] as? String, "ideaforge_workflow_output_v1")
        XCTAssertEqual(structuredOutput?["strict"] as? Bool, true)
        XCTAssertEqual(schema?["type"] as? String, "object")
        XCTAssertEqual(schema?["additionalProperties"] as? Bool, false)
        XCTAssertEqual(schema?["required"] as? [String], ["artifacts"])
        XCTAssertEqual(artifactsSchema?["type"] as? String, "array")
        XCTAssertEqual(artifactsSchema?["minItems"] as? Int, 2)
        XCTAssertEqual(itemSchema?["additionalProperties"] as? Bool, false)
        XCTAssertEqual(kindSchema?["enum"] as? [String], ["codexTaskBundle", "architecture"])
    }

    func testBackendWorkflowExecutionServiceRejectsContractViolatingArtifacts() async throws {
        let artifact = Artifact(
            id: "artifact_backend_thin",
            kind: .codexTaskBundle,
            title: "Thin Codex Packet",
            markdown: "# Build\n\nImplement the app.",
            version: 1,
            createdBy: "backend-ai",
            createdAt: SampleData.now
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let transport = CapturingHTTPRequestTransport(
            responseData: try encoder.encode(BackendWorkflowTestResponse(artifacts: [artifact])),
            statusCode: 200
        )
        let service = BackendWorkflowExecutionService(
            configuration: BackendAIConfiguration(
                baseURL: URL(string: "https://api.example.test")!,
                bearerToken: "ai-token",
                workspaceID: "workspace_alpha",
                workflowPath: "/ai/workflow"
            ),
            transport: transport
        )
        let template = try XCTUnwrap(DefaultWorkflows.templates.first { $0.id == "wf_codex_packet" })

        do {
            _ = try await service.run(template: template, project: SampleData.ideaForgeProject)
            XCTFail("Expected contract-violating backend output to be rejected.")
        } catch BackendAIError.contractViolation(let issues) {
            XCTAssertTrue(issues.contains("Missing expected artifacts: Architecture."))
            XCTAssertTrue(issues.contains("CodexPacketSchema missing required fields: repo_context, tasks, checks."))
            XCTAssertTrue(issues.contains("AI rubric failed: Handoff Safety."))
            XCTAssertFalse(issues.joined(separator: " ").contains(artifact.markdown))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testWorkflowPromptRegressionFixturesSatisfyOutputContracts() throws {
        let fixtures = try Self.loadWorkflowPromptRegressionFixtures()
        XCTAssertFalse(fixtures.isEmpty)

        for fixture in fixtures {
            let template = try XCTUnwrap(
                DefaultWorkflows.templates.first { $0.id == fixture.templateID },
                "Missing template for prompt regression fixture \(fixture.id)."
            )
            let project = try XCTUnwrap(
                SampleData.store().projects.first { $0.id == fixture.projectID },
                "Missing project for prompt regression fixture \(fixture.id)."
            )

            let validation = WorkflowOutputContractValidator.validate(
                template: template,
                project: project,
                artifacts: fixture.artifacts
            )

            XCTAssertTrue(
                validation.isValid,
                "\(fixture.id) failed prompt regression validation: \(validation.issues.joined(separator: " | "))"
            )
            XCTAssertEqual(validation.expectedKinds, Set(template.outputKinds))
            XCTAssertEqual(validation.generatedKinds, Set(fixture.artifacts.map(\.kind)))
            XCTAssertGreaterThanOrEqual(validation.schemaCompletenessScore, 1)
            XCTAssertGreaterThanOrEqual(validation.rubricScore, 1)
        }
    }

    @MainActor
    func testStoreProcessesUploadedRecordingThroughTranscriptionWorker() async throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let recording = Recording(
            id: "rec_uploaded_transcribe",
            ideaProjectID: "idea_uploaded_transcribe",
            deviceName: "iPhone",
            durationSeconds: 30,
            localFileStatus: .uploaded,
            syncStatus: .uploaded,
            localAudioPath: "recordings/uploaded.m4a",
            audioObjectKey: "audio/idea_uploaded_transcribe/rec_uploaded_transcribe.m4a",
            languageHint: "en",
            createdAt: now,
            markerOffsets: []
        )
        let project = IdeaProject(
            id: "idea_uploaded_transcribe",
            title: "Uploaded transcribe",
            status: .inbox,
            source: .iphone,
            createdAt: now,
            updatedAt: now,
            summary: "Pending transcript.",
            tags: [.appIdea],
            score: IdeaScore(confidence: 0.2, completeness: 0.1, risk: 0.7),
            transcript: Transcript(cleanText: "Pending transcript.", segments: [], unclearFragments: []),
            recordings: [recording],
            questions: [],
            artifacts: [],
            assumptions: [],
            validationExperiments: [],
            codexTasks: []
        )
        let repository = InMemoryWorkspaceRepository()
        let store = IdeaForgeStore(
            projects: [project],
            workflowTemplates: DefaultWorkflows.templates,
            selectedProjectID: project.id,
            privacyMode: .standardCloud,
            syncHealth: SyncHealth(
                watchReachable: false,
                queuedUploads: 0,
                lastSuccessfulSync: now,
                failingItems: 0
            ),
            repository: repository
        )
        let transcript = Transcript(
            cleanText: "A completed backend transcript.",
            segments: [],
            unclearFragments: []
        )
        let services = IdeaForgeServices(
            transcription: SucceedingTranscriptionService(transcript: transcript),
            workflow: LocalWorkflowExecutionService(),
            syncQueue: LocalSyncQueueService(),
            export: LocalExportService()
        )

        let summary = await store.processUploadedRecordingsForTranscription(
            services: services,
            now: now.addingTimeInterval(60)
        )

        let saved = try XCTUnwrap(try repository.load())
        XCTAssertEqual(summary, AIProcessingSummary(attemptedCount: 1, completedCount: 1, failedCount: 0))
        XCTAssertEqual(saved.projects.first?.summary, "A completed backend transcript.")
        XCTAssertEqual(saved.projects.first?.recordings.first?.syncStatus, .ready)
        XCTAssertEqual(saved.projects.first?.recordings.first?.localFileStatus, .uploaded)
    }

    @MainActor
    func testStoreProcessesTransferredWatchRecordingThroughLocalSpeechWorker() async throws {
        let now = Date(timeIntervalSince1970: 12_000)
        let recording = Recording(
            id: "rec_watch_local_speech",
            ideaProjectID: "idea_watch_local_speech",
            deviceName: "Apple Watch Ultra",
            durationSeconds: 52,
            localFileStatus: .available,
            syncStatus: .transferredToIPhone,
            localAudioPath: "recordings/watch-local.m4a",
            languageHint: "en-US",
            createdAt: now,
            markerOffsets: [20]
        )
        let project = IdeaProject(
            id: "idea_watch_local_speech",
            title: "Watch local speech",
            status: .inbox,
            source: .watch,
            createdAt: now,
            updatedAt: now,
            summary: "Queued Watch note.",
            tags: [.appIdea],
            score: IdeaScore(confidence: 0.2, completeness: 0.1, risk: 0.7),
            transcript: Transcript(cleanText: "Queued Watch note.", segments: [], unclearFragments: []),
            recordings: [recording],
            questions: [],
            artifacts: [],
            assumptions: [],
            validationExperiments: [],
            codexTasks: []
        )
        let repository = InMemoryWorkspaceRepository()
        let store = IdeaForgeStore(
            projects: [project],
            workflowTemplates: DefaultWorkflows.templates,
            selectedProjectID: project.id,
            privacyMode: .privateLocal,
            syncHealth: SyncHealth(
                watchReachable: true,
                queuedUploads: 0,
                lastSuccessfulSync: now,
                failingItems: 0
            ),
            repository: repository
        )
        let transcript = Transcript(
            cleanText: "A local Watch transcript ready for review.",
            segments: [
                TranscriptSegment(
                    id: "segment_watch_local",
                    startSeconds: 0,
                    endSeconds: 52,
                    text: "A local Watch transcript ready for review.",
                    isMarkedImportant: true
                )
            ],
            unclearFragments: []
        )
        let services = IdeaForgeServices(
            transcription: SucceedingTranscriptionService(transcript: transcript),
            workflow: LocalWorkflowExecutionService(),
            syncQueue: LocalSyncQueueService(),
            export: LocalExportService()
        )

        let summary = await store.processLocalRecordingsForSpeechTranscription(
            services: services,
            now: now.addingTimeInterval(60)
        )

        let saved = try XCTUnwrap(try repository.load())
        XCTAssertEqual(summary, AIProcessingSummary(attemptedCount: 1, completedCount: 1, failedCount: 0))
        XCTAssertEqual(saved.projects.first?.summary, "A local Watch transcript ready for review.")
        XCTAssertEqual(saved.projects.first?.recordings.first?.syncStatus, .ready)
        XCTAssertEqual(saved.projects.first?.recordings.first?.localFileStatus, .available)
        XCTAssertNil(saved.projects.first?.recordings.first?.processingDiagnostic)
    }

    @MainActor
    func testStorePersistsLocalSpeechFailureDiagnosticWithoutDeletingAudio() async throws {
        let now = Date(timeIntervalSince1970: 13_000)
        let failureTime = now.addingTimeInterval(60)
        let recording = Recording(
            id: "rec_local_speech_failure",
            ideaProjectID: "idea_local_speech_failure",
            deviceName: "iPhone",
            durationSeconds: 33,
            localFileStatus: .available,
            syncStatus: .pending,
            localAudioPath: "recordings/local-speech-failure.m4a",
            languageHint: "en",
            createdAt: now,
            markerOffsets: []
        )
        let project = IdeaProject(
            id: "idea_local_speech_failure",
            title: "Local speech failure",
            status: .inbox,
            source: .iphone,
            createdAt: now,
            updatedAt: now,
            summary: "Local speech should fail closed.",
            tags: [.appIdea],
            score: IdeaScore(confidence: 0.2, completeness: 0.1, risk: 0.7),
            transcript: Transcript(cleanText: "Local speech should fail closed.", segments: [], unclearFragments: []),
            recordings: [recording],
            questions: [],
            artifacts: [],
            assumptions: [],
            validationExperiments: [],
            codexTasks: []
        )
        let repository = InMemoryWorkspaceRepository()
        let store = IdeaForgeStore(
            projects: [project],
            workflowTemplates: DefaultWorkflows.templates,
            selectedProjectID: project.id,
            privacyMode: .privateLocal,
            syncHealth: SyncHealth(
                watchReachable: false,
                queuedUploads: 0,
                lastSuccessfulSync: now,
                failingItems: 0
            ),
            repository: repository
        )
        let services = IdeaForgeServices(
            transcription: FailingTranscriptionService(error: LocalSpeechTranscriptionError.recognizerUnavailable),
            workflow: LocalWorkflowExecutionService(),
            syncQueue: LocalSyncQueueService(),
            export: LocalExportService()
        )

        let summary = await store.processLocalRecordingsForSpeechTranscription(
            services: services,
            now: failureTime
        )

        let saved = try XCTUnwrap(try repository.load())
        let failedRecording = try XCTUnwrap(saved.projects.first?.recordings.first)
        let diagnostic = try XCTUnwrap(failedRecording.processingDiagnostic)
        XCTAssertEqual(summary, AIProcessingSummary(attemptedCount: 1, completedCount: 0, failedCount: 1))
        XCTAssertEqual(failedRecording.syncStatus, .failed)
        XCTAssertEqual(failedRecording.localFileStatus, .available)
        XCTAssertEqual(diagnostic.code, .localSpeechUnavailable)
        XCTAssertEqual(diagnostic.message, "Speech recognition is unavailable for this language or device right now.")
        XCTAssertEqual(diagnostic.failedAt, failureTime)
        XCTAssertTrue(diagnostic.isRetryable)
        XCTAssertEqual(saved.syncHealth.failingItems, 1)
        XCTAssertEqual(store.lastErrorMessage, diagnostic.message)
    }

    @MainActor
    func testStorePersistsSanitizedTranscriptionFailureDiagnostic() async throws {
        let now = Date(timeIntervalSince1970: 20_000)
        let failureTime = now.addingTimeInterval(60)
        let recording = Recording(
            id: "rec_uploaded_bad_transcript",
            ideaProjectID: "idea_uploaded_bad_transcript",
            deviceName: "iPhone",
            durationSeconds: 45,
            localFileStatus: .uploaded,
            syncStatus: .uploaded,
            localAudioPath: "recordings/secret-project-raven.m4a",
            audioObjectKey: "audio/idea_uploaded_bad_transcript/rec_uploaded_bad_transcript.m4a",
            languageHint: "en",
            createdAt: now,
            markerOffsets: []
        )
        let project = IdeaProject(
            id: "idea_uploaded_bad_transcript",
            title: "Project Raven",
            status: .inbox,
            source: .iphone,
            createdAt: now,
            updatedAt: now,
            summary: "Secret Project Raven launch plan.",
            tags: [.business],
            score: IdeaScore(confidence: 0.2, completeness: 0.1, risk: 0.7),
            transcript: Transcript(cleanText: "Pending transcript.", segments: [], unclearFragments: []),
            recordings: [recording],
            questions: [],
            artifacts: [],
            assumptions: [],
            validationExperiments: [],
            codexTasks: []
        )
        let repository = InMemoryWorkspaceRepository()
        let store = IdeaForgeStore(
            projects: [project],
            workflowTemplates: DefaultWorkflows.templates,
            selectedProjectID: project.id,
            privacyMode: .standardCloud,
            syncHealth: SyncHealth(
                watchReachable: false,
                queuedUploads: 0,
                lastSuccessfulSync: now,
                failingItems: 0
            ),
            repository: repository
        )
        let services = IdeaForgeServices(
            transcription: ContractViolatingTranscriptionService(
                issues: [
                    "Transcript clean text is empty.",
                    "raw transcript leaked Project Raven"
                ]
            ),
            workflow: LocalWorkflowExecutionService(),
            syncQueue: LocalSyncQueueService(),
            export: LocalExportService()
        )

        let summary = await store.processUploadedRecordingsForTranscription(
            services: services,
            now: failureTime
        )

        let saved = try XCTUnwrap(try repository.load())
        let failedRecording = try XCTUnwrap(saved.projects.first?.recordings.first)
        let diagnostic = try XCTUnwrap(failedRecording.processingDiagnostic)
        XCTAssertEqual(summary, AIProcessingSummary(attemptedCount: 1, completedCount: 0, failedCount: 1))
        XCTAssertEqual(saved.syncHealth.failingItems, 1)
        XCTAssertEqual(failedRecording.syncStatus, .failed)
        XCTAssertEqual(failedRecording.localFileStatus, .uploaded)
        XCTAssertEqual(diagnostic.code, .transcriptContractViolation)
        XCTAssertEqual(diagnostic.message, "Backend transcript failed contract validation: 2 issues.")
        XCTAssertEqual(diagnostic.failedAt, failureTime)
        XCTAssertFalse(diagnostic.isRetryable)
        XCTAssertEqual(store.lastErrorMessage, diagnostic.message)
        XCTAssertFalse(diagnostic.message.contains("Project Raven"))
        XCTAssertFalse(diagnostic.message.contains("secret-project-raven"))
        XCTAssertFalse(diagnostic.message.contains("raw transcript"))
    }

    @MainActor
    func testTranscriptionWorkerRetriesRetryableFailedRecording() async throws {
        let now = Date(timeIntervalSince1970: 30_000)
        let recording = Recording(
            id: "rec_retryable_transcript",
            ideaProjectID: "idea_retryable_transcript",
            deviceName: "iPhone",
            durationSeconds: 45,
            localFileStatus: .failed,
            syncStatus: .failed,
            localAudioPath: "recordings/retryable.m4a",
            audioObjectKey: "audio/idea_retryable_transcript/rec_retryable_transcript.m4a",
            languageHint: "en",
            createdAt: now,
            markerOffsets: [],
            processingDiagnostic: RecordingProcessingDiagnostic(
                code: .backendProviderFailure,
                message: "AI provider failed: rate_limit_exceeded (HTTP 429, retryable).",
                isRetryable: true,
                failedAt: now
            )
        )
        let project = IdeaProject(
            id: "idea_retryable_transcript",
            title: "Retryable transcript",
            status: .inbox,
            source: .iphone,
            createdAt: now,
            updatedAt: now,
            summary: "Pending transcript.",
            tags: [.business],
            score: IdeaScore(confidence: 0.2, completeness: 0.1, risk: 0.7),
            transcript: Transcript(cleanText: "Pending transcript.", segments: [], unclearFragments: []),
            recordings: [recording],
            questions: [],
            artifacts: [],
            assumptions: [],
            validationExperiments: [],
            codexTasks: []
        )
        let repository = InMemoryWorkspaceRepository()
        let store = IdeaForgeStore(
            projects: [project],
            workflowTemplates: DefaultWorkflows.templates,
            selectedProjectID: project.id,
            privacyMode: .standardCloud,
            syncHealth: SyncHealth(
                watchReachable: false,
                queuedUploads: 0,
                lastSuccessfulSync: now,
                failingItems: 1
            ),
            repository: repository
        )
        let transcript = Transcript(
            cleanText: "Recovered backend transcript.",
            segments: [TranscriptSegment(id: "seg_recovered", startSeconds: 0, endSeconds: 45, text: "Recovered backend transcript.", isMarkedImportant: false)],
            unclearFragments: []
        )
        let services = IdeaForgeServices(
            transcription: SucceedingTranscriptionService(transcript: transcript),
            workflow: LocalWorkflowExecutionService(),
            syncQueue: LocalSyncQueueService(),
            export: LocalExportService()
        )

        let summary = await store.processUploadedRecordingsForTranscription(
            services: services,
            now: now.addingTimeInterval(60)
        )

        let saved = try XCTUnwrap(try repository.load())
        let recoveredRecording = try XCTUnwrap(saved.projects.first?.recordings.first)
        XCTAssertEqual(summary, AIProcessingSummary(attemptedCount: 1, completedCount: 1, failedCount: 0))
        XCTAssertEqual(saved.syncHealth.failingItems, 0)
        XCTAssertEqual(saved.projects.first?.summary, "Recovered backend transcript.")
        XCTAssertEqual(recoveredRecording.syncStatus, .ready)
        XCTAssertEqual(recoveredRecording.localFileStatus, .uploaded)
        XCTAssertNil(recoveredRecording.processingDiagnostic)
    }

    func testUpdateTranscriptTextPersistsProjectSummaryAndTranscript() throws {
        let repository = InMemoryWorkspaceRepository()
        let state = WorkspaceState.seed()
        let store = IdeaForgeStore(state: state, repository: repository)
        let projectID = try XCTUnwrap(store.selectedProjectID)
        let updatedAt = Date(timeIntervalSince1970: 2_000)

        XCTAssertTrue(store.updateTranscriptText("Edited transcript for build review.", projectID: projectID, now: updatedAt))

        let saved = try XCTUnwrap(try repository.load())
        let project = try XCTUnwrap(saved.projects.first { $0.id == projectID })
        XCTAssertEqual(project.transcript.cleanText, "Edited transcript for build review.")
        XCTAssertEqual(project.summary, "Edited transcript for build review.")
        XCTAssertEqual(project.updatedAt, updatedAt)
        XCTAssertEqual(saved.updatedAt, updatedAt)
    }

    func testUpdateTranscriptSegmentPersistsSegmentReviewEdit() throws {
        let repository = InMemoryWorkspaceRepository()
        let state = WorkspaceState.seed()
        let store = IdeaForgeStore(state: state, repository: repository)
        let projectID = try XCTUnwrap(store.selectedProjectID)
        let originalSummary = try XCTUnwrap(store.selectedProject?.summary)
        let originalCleanText = try XCTUnwrap(store.selectedProject?.transcript.cleanText)
        let updatedAt = Date(timeIntervalSince1970: 2_200)

        XCTAssertTrue(
            store.updateTranscriptSegment(
                projectID: projectID,
                segmentID: "seg_3",
                text: "Ask targeted follow-up questions until the idea is strong enough for a build packet.",
                isMarkedImportant: true,
                now: updatedAt
            )
        )

        let saved = try XCTUnwrap(try repository.load())
        let project = try XCTUnwrap(saved.projects.first { $0.id == projectID })
        let segment = try XCTUnwrap(project.transcript.segments.first { $0.id == "seg_3" })
        XCTAssertEqual(segment.text, "Ask targeted follow-up questions until the idea is strong enough for a build packet.")
        XCTAssertTrue(segment.isMarkedImportant)
        XCTAssertEqual(project.transcript.cleanText, originalCleanText)
        XCTAssertEqual(project.summary, originalSummary)
        XCTAssertEqual(project.updatedAt, updatedAt)
        XCTAssertEqual(saved.updatedAt, updatedAt)
    }

    func testAddValidationExperimentPersistsPlannerItem() throws {
        let repository = InMemoryWorkspaceRepository()
        let state = WorkspaceState.seed()
        let store = IdeaForgeStore(state: state, repository: repository)
        let projectID = try XCTUnwrap(store.selectedProjectID)
        let updatedAt = Date(timeIntervalSince1970: 2_500)

        XCTAssertTrue(
            store.addValidationExperiment(
                projectID: projectID,
                title: "Concierge onboarding smoke",
                metric: "3 of 5 invited founders complete setup",
                goNoGoCriteria: "Continue only if at least 60% finish without a live call.",
                now: updatedAt
            )
        )

        let saved = try XCTUnwrap(try repository.load())
        let project = try XCTUnwrap(saved.projects.first { $0.id == projectID })
        let experiment = try XCTUnwrap(project.validationExperiments.last)
        XCTAssertEqual(experiment.title, "Concierge onboarding smoke")
        XCTAssertEqual(experiment.metric, "3 of 5 invited founders complete setup")
        XCTAssertEqual(experiment.goNoGoCriteria, "Continue only if at least 60% finish without a live call.")
        XCTAssertEqual(project.updatedAt, updatedAt)
        XCTAssertEqual(saved.updatedAt, updatedAt)
    }

    func testAddAssumptionPersistsTrackerItem() throws {
        let repository = InMemoryWorkspaceRepository()
        let state = WorkspaceState.seed()
        let store = IdeaForgeStore(state: state, repository: repository)
        let projectID = try XCTUnwrap(store.selectedProjectID)
        let updatedAt = Date(timeIntervalSince1970: 3_000)

        XCTAssertTrue(
            store.addAssumption(
                projectID: projectID,
                text: " Founders will review packets before asking Codex to build. ",
                evidence: "Validation calls showed users want a review checkpoint.",
                confidence: 0.67,
                now: updatedAt
            )
        )

        let saved = try XCTUnwrap(try repository.load())
        let project = try XCTUnwrap(saved.projects.first { $0.id == projectID })
        let assumption = try XCTUnwrap(project.assumptions.last)
        XCTAssertEqual(assumption.text, "Founders will review packets before asking Codex to build.")
        XCTAssertEqual(assumption.evidence, "Validation calls showed users want a review checkpoint.")
        XCTAssertEqual(assumption.confidence, 0.67, accuracy: 0.001)
        XCTAssertEqual(project.updatedAt, updatedAt)
        XCTAssertEqual(saved.updatedAt, updatedAt)
    }

    func testUpdateArtifactMarkdownCreatesNewVersion() throws {
        let repository = InMemoryWorkspaceRepository()
        let state = WorkspaceState.seed()
        let store = IdeaForgeStore(state: state, repository: repository)
        let projectID = try XCTUnwrap(store.selectedProjectID)
        let updatedAt = Date(timeIntervalSince1970: 3_500)

        XCTAssertTrue(
            store.updateArtifactMarkdown(
                artifactID: "artifact_prd",
                markdown: "## Goals\nCapture, review, and edit generated plans before handoff.",
                now: updatedAt
            )
        )

        let saved = try XCTUnwrap(try repository.load())
        let project = try XCTUnwrap(saved.projects.first { $0.id == projectID })
        let prdHistory = try XCTUnwrap(project.artifactHistories.first { $0.kind == .prd })

        XCTAssertEqual(prdHistory.versions.map(\.version), [2, 1])
        XCTAssertEqual(prdHistory.latest.markdown, "## Goals\nCapture, review, and edit generated plans before handoff.")
        XCTAssertEqual(prdHistory.latest.title, "Product Requirements Document")
        XCTAssertEqual(prdHistory.latest.createdBy, "manual-edit")
        XCTAssertEqual(prdHistory.latest.createdAt, updatedAt)
        XCTAssertNotEqual(prdHistory.latest.id, "artifact_prd")
        XCTAssertEqual(prdHistory.latestDiff?.currentVersion, 2)
        XCTAssertEqual(prdHistory.latestDiff?.previousVersion, 1)
        XCTAssertEqual(project.updatedAt, updatedAt)
        XCTAssertEqual(saved.updatedAt, updatedAt)
    }

    @MainActor
    func testCaptureReturnsCreatedProjectForTransferHandoff() async throws {
        let store = IdeaForgeStore(
            projects: [],
            workflowTemplates: DefaultWorkflows.templates,
            selectedProjectID: nil,
            privacyMode: .privateLocal,
            syncHealth: SyncHealth(
                watchReachable: true,
                queuedUploads: 0,
                lastSuccessfulSync: SampleData.now,
                failingItems: 0
            ),
            repository: InMemoryWorkspaceRepository()
        )

        let project = await store.capture(
            RecordingDraft(
                projectTitle: "Transfer handoff",
                tag: .feature,
                source: .watch,
                durationSeconds: 12,
                transcriptHint: "Needs transfer.",
                localAudioPath: "recordings/transfer.m4a"
            )
        )

        XCTAssertEqual(project?.title, "Transfer handoff")
        XCTAssertEqual(project?.recordings.first?.localAudioPath, "recordings/transfer.m4a")
        XCTAssertEqual(store.uploadJobs.first?.recordingID, project?.recordings.first?.id)
    }

    @MainActor
    func testMarkUploadSucceededUpdatesJobAndRecording() async throws {
        let repository = InMemoryWorkspaceRepository()
        let store = IdeaForgeStore(
            projects: [],
            workflowTemplates: DefaultWorkflows.templates,
            selectedProjectID: nil,
            privacyMode: .privateLocal,
            syncHealth: SyncHealth(
                watchReachable: true,
                queuedUploads: 0,
                lastSuccessfulSync: SampleData.now,
                failingItems: 0
            ),
            repository: repository
        )

        let capturedProject = await store.capture(
            RecordingDraft(
                projectTitle: "Uploaded idea",
                tag: .business,
                source: .iphone,
                durationSeconds: 22,
                transcriptHint: "Upload this.",
                localAudioPath: "recordings/uploaded.m4a"
            )
        )
        let project = try XCTUnwrap(capturedProject)
        let recordingID = try XCTUnwrap(project.recordings.first?.id)

        store.markUploadSucceeded(recordingID: recordingID, objectKey: "audio/\(recordingID).m4a", now: SampleData.now)

        let saved = try XCTUnwrap(try repository.load())
        XCTAssertEqual(saved.uploadJobs.first?.status, .uploaded)
        XCTAssertEqual(saved.uploadJobs.first?.objectKey, "audio/\(recordingID).m4a")
        XCTAssertEqual(saved.projects.first?.recordings.first?.syncStatus, .uploaded)
        XCTAssertEqual(saved.projects.first?.recordings.first?.audioObjectKey, "audio/\(recordingID).m4a")
        XCTAssertEqual(saved.syncHealth.queuedUploads, 0)
    }

    @MainActor
    func testUploadProcessorUploadsDueJobAndUpdatesRecording() async throws {
        let repository = InMemoryWorkspaceRepository()
        let store = IdeaForgeStore(
            projects: [],
            workflowTemplates: DefaultWorkflows.templates,
            selectedProjectID: nil,
            privacyMode: .privateLocal,
            syncHealth: SyncHealth(
                watchReachable: true,
                queuedUploads: 0,
                lastSuccessfulSync: SampleData.now,
                failingItems: 0
            ),
            repository: repository
        )
        let capturedProject = await store.capture(
            RecordingDraft(
                projectTitle: "Processor upload",
                tag: .appIdea,
                source: .iphone,
                durationSeconds: 15,
                transcriptHint: "Processor should upload this.",
                localAudioPath: "recordings/processor.m4a"
            )
        )
        let project = try XCTUnwrap(capturedProject)
        let recordingID = try XCTUnwrap(project.recordings.first?.id)
        let processor = UploadQueueProcessor(client: SucceedingUploadClient(objectKey: "audio/\(recordingID).m4a"))

        let summary = await processor.processDueUploads(in: store, now: Date().addingTimeInterval(1))

        let saved = try XCTUnwrap(try repository.load())
        XCTAssertEqual(summary.uploadedCount, 1)
        XCTAssertEqual(summary.failedCount, 0)
        XCTAssertEqual(saved.uploadJobs.first?.status, .uploaded)
        XCTAssertEqual(saved.projects.first?.recordings.first?.syncStatus, .uploaded)
        XCTAssertEqual(saved.projects.first?.recordings.first?.audioObjectKey, "audio/\(recordingID).m4a")
    }

    @MainActor
    func testUploadProcessorSchedulesRetryWhenClientFails() async throws {
        let repository = InMemoryWorkspaceRepository()
        let store = IdeaForgeStore(
            projects: [],
            workflowTemplates: DefaultWorkflows.templates,
            selectedProjectID: nil,
            privacyMode: .privateLocal,
            syncHealth: SyncHealth(
                watchReachable: true,
                queuedUploads: 0,
                lastSuccessfulSync: SampleData.now,
                failingItems: 0
            ),
            repository: repository
        )
        let capturedProject = await store.capture(
            RecordingDraft(
                projectTitle: "Retry upload",
                tag: .appIdea,
                source: .iphone,
                durationSeconds: 15,
                transcriptHint: "Processor should retry this.",
                localAudioPath: "recordings/retry-upload.m4a"
            )
        )
        let project = try XCTUnwrap(capturedProject)
        let recordingID = try XCTUnwrap(project.recordings.first?.id)
        let processor = UploadQueueProcessor(client: FailingUploadClient())

        let summary = await processor.processDueUploads(in: store, now: Date().addingTimeInterval(1))

        let saved = try XCTUnwrap(try repository.load())
        XCTAssertEqual(summary.uploadedCount, 0)
        XCTAssertEqual(summary.failedCount, 1)
        XCTAssertEqual(saved.uploadJobs.first?.status, .waitingForRetry)
        XCTAssertEqual(saved.uploadJobs.first?.attemptCount, 1)
        XCTAssertEqual(saved.projects.first?.recordings.first?.id, recordingID)
        XCTAssertEqual(saved.projects.first?.recordings.first?.syncStatus, .pending)
        XCTAssertEqual(saved.syncHealth.queuedUploads, 1)
    }

    @MainActor
    func testUploadProcessorPersistsTypedConnectivityFailureCategory() async throws {
        let state = SampleData.taskFirstStore(state: .queuedUpload).workspaceState(now: SampleData.now)
        let repository = InMemoryWorkspaceRepository(state: state)
        let store = IdeaForgeStore(state: state, repository: repository)
        let processor = UploadQueueProcessor(client: URLErrorUploadClient(code: .timedOut))

        let summary = await processor.processDueUploads(
            in: store,
            now: SampleData.now.addingTimeInterval(1)
        )

        let saved = try XCTUnwrap(try repository.load())
        XCTAssertEqual(summary.failedCount, 1)
        XCTAssertEqual(saved.uploadJobs.first?.status, .waitingForRetry)
        XCTAssertEqual(saved.uploadJobs.first?.failureCategory, .connectivity)
    }

    @MainActor
    func testConfiguredUploadProcessorPersistsConfigurationFailureCategory() async throws {
        let state = SampleData.taskFirstStore(state: .queuedUpload).workspaceState(now: SampleData.now)
        let repository = InMemoryWorkspaceRepository(state: state)
        let store = IdeaForgeStore(state: state, repository: repository)
        let manager = BackendConfigurationManager(
            settingsStore: InMemoryBackendSettingsStore(
                settings: BackendConnectionSettings(
                    baseURLString: "not a valid backend URL",
                    workspaceID: "workspace_alpha",
                    isEnabled: true
                )
            ),
            credentialStore: InMemoryBackendCredentialStore(token: "test-token")
        )

        do {
            _ = try await ConfiguredUploadQueueProcessor(
                backendConfigurationManager: manager
            ).processDueUploads(in: store, now: SampleData.now.addingTimeInterval(1))
            XCTFail("Expected invalid backend configuration to remain visible to the caller.")
        } catch let error as BackendConfigurationError {
            XCTAssertEqual(error, .invalidBaseURL("not a valid backend URL"))
        } catch {
            XCTFail("Unexpected configured upload error: \(error)")
        }

        let saved = try XCTUnwrap(try repository.load())
        XCTAssertEqual(saved.uploadJobs.first?.status, .waitingForRetry)
        XCTAssertEqual(saved.uploadJobs.first?.failureCategory, .configuration)
    }

    @MainActor
    func testConfiguredUploadProcessorDoesNotFallBackToLocalWhenEnabledCredentialsAreMissing() async throws {
        let state = SampleData.taskFirstStore(state: .queuedUpload).workspaceState(now: SampleData.now)
        let repository = InMemoryWorkspaceRepository(state: state)
        let store = IdeaForgeStore(state: state, repository: repository)
        let manager = BackendConfigurationManager(
            settingsStore: InMemoryBackendSettingsStore(
                settings: BackendConnectionSettings(
                    baseURLString: "https://api.example.test",
                    workspaceID: "workspace_alpha",
                    isEnabled: true
                )
            ),
            credentialStore: InMemoryBackendCredentialStore(token: nil)
        )

        do {
            _ = try await ConfiguredUploadQueueProcessor(
                backendConfigurationManager: manager
            ).processDueUploads(in: store, now: SampleData.now.addingTimeInterval(1))
            XCTFail("Expected missing enabled backend credentials to remain visible to the caller.")
        } catch let error as BackendConfigurationError {
            XCTAssertEqual(error, .missingRequiredConfiguration)
        } catch {
            XCTFail("Unexpected configured upload error: \(error)")
        }

        let saved = try XCTUnwrap(try repository.load())
        XCTAssertEqual(saved.uploadJobs.first?.status, .waitingForRetry)
        XCTAssertEqual(saved.uploadJobs.first?.failureCategory, .configuration)
        XCTAssertNil(saved.uploadJobs.first?.objectKey)
    }

    @MainActor
    func testAppScopedUploadCoordinatorSerializesBackgroundAndForegroundRequests() async throws {
        let fixture = try FailedUploadFixture.make(source: .iphone)
        defer { try? fixture.fileManager.removeItem(at: fixture.directory) }
        let firstAudioURL = fixture.directory.appending(path: "first.m4a")
        try fixture.audioData.write(to: firstAudioURL)

        var state = fixture.state
        var firstRecording = try XCTUnwrap(state.projects.first?.recordings.first)
        firstRecording.id = "rec_first_active_pass"
        firstRecording.localAudioPath = firstAudioURL.path
        firstRecording.localFileStatus = .available
        firstRecording.syncStatus = .pending
        state.projects[0].recordings.append(firstRecording)
        let firstJob = UploadQueuePolicy.job(
            for: firstRecording,
            localAudioPath: firstAudioURL.path,
            now: fixture.now
        )
        state.uploadJobs.insert(firstJob, at: 0)
        state.syncHealth.queuedUploads = 1

        let repository = InMemoryWorkspaceRepository(state: state)
        let store = IdeaForgeStore(state: state, repository: repository)
        let client = SuspendedFirstUploadClient()
        let processor = UploadQueueProcessor(client: client)
        let coordinator = UploadQueueProcessingCoordinator()
        let passRecorder = UploadPassRecorder()
        let processingDate = fixture.now.addingTimeInterval(1)

        let backgroundRequest = Task { @MainActor in
            try await coordinator.requestProcessing {
                await passRecorder.record("background")
                return await processor.processDueUploads(in: store, now: processingDate)
            }
        }
        await client.waitUntilFirstUploadStarts()

        XCTAssertTrue(
            store.retryUpload(
                recordingID: fixture.recordingID,
                now: processingDate,
                fileManager: fixture.fileManager
            )
        )
        let foregroundRequest = Task { @MainActor in
            try await coordinator.requestProcessing {
                await passRecorder.record("foreground")
                return await processor.processDueUploads(in: store, now: processingDate)
            }
        }

        var observedPendingForegroundRequest = false
        for _ in 0..<1_000 {
            if await coordinator.hasPendingRequest {
                observedPendingForegroundRequest = true
                break
            }
            await Task.yield()
        }
        XCTAssertTrue(observedPendingForegroundRequest)

        await client.resumeFirstUpload()
        let backgroundSummary = try await backgroundRequest.value
        let foregroundSummary = try await foregroundRequest.value

        let saved = try XCTUnwrap(try repository.load())
        let attemptedRecordingIDs = await client.attemptedRecordingIDs()
        let backgroundPassCount = await passRecorder.count(for: "background")
        let foregroundPassCount = await passRecorder.count(for: "foreground")
        XCTAssertEqual(attemptedRecordingIDs, [firstRecording.id, fixture.recordingID])
        XCTAssertEqual(Set(attemptedRecordingIDs).count, 2)
        XCTAssertEqual(backgroundSummary.attemptedCount, 2)
        XCTAssertEqual(foregroundSummary.attemptedCount, 2)
        XCTAssertEqual(backgroundPassCount, 1)
        XCTAssertEqual(foregroundPassCount, 1)
        XCTAssertEqual(
            saved.uploadJobs.first { $0.recordingID == firstRecording.id }?.attemptCount,
            1
        )
        XCTAssertEqual(
            saved.uploadJobs.first { $0.recordingID == fixture.recordingID }?.attemptCount,
            1
        )
        XCTAssertEqual(
            saved.uploadJobs.first { $0.recordingID == firstRecording.id }?.status,
            .uploaded
        )
        XCTAssertEqual(
            saved.uploadJobs.first { $0.recordingID == fixture.recordingID }?.status,
            .uploaded
        )
    }

    @MainActor
    func testUploadProcessorRecoversInterruptedUploadingJobBeforeScheduling() async throws {
        let repository = InMemoryWorkspaceRepository()
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let recoveredAt = startedAt.addingTimeInterval(UploadQueuePolicy.interruptedUploadTimeout + 1)
        let recording = Recording(
            id: "rec_interrupted_processor",
            ideaProjectID: "idea_interrupted_processor",
            deviceName: "iPhone",
            durationSeconds: 18,
            localFileStatus: .available,
            syncStatus: .pending,
            localAudioPath: "recordings/interrupted-processor.m4a",
            languageHint: "en-US",
            createdAt: startedAt,
            markerOffsets: []
        )
        let project = IdeaProject(
            id: "idea_interrupted_processor",
            title: "Interrupted upload",
            status: .draft,
            source: .iphone,
            createdAt: startedAt,
            updatedAt: startedAt,
            summary: "Upload should recover after interruption.",
            tags: [.appIdea],
            score: IdeaScore(confidence: 0.3, completeness: 0.2, risk: 0.8),
            transcript: Transcript(cleanText: "", segments: [], unclearFragments: []),
            recordings: [recording],
            questions: [],
            artifacts: [],
            assumptions: [],
            validationExperiments: [],
            codexTasks: []
        )
        let stuckJob = UploadJob(
            id: "upload_rec_interrupted_processor",
            recordingID: recording.id,
            ideaProjectID: project.id,
            localAudioPath: "recordings/interrupted-processor.m4a",
            status: .uploading,
            attemptCount: 1,
            nextAttemptAt: startedAt,
            createdAt: startedAt,
            updatedAt: startedAt
        )
        let store = IdeaForgeStore(
            projects: [project],
            workflowTemplates: DefaultWorkflows.templates,
            uploadJobs: [stuckJob],
            selectedProjectID: project.id,
            privacyMode: .privateLocal,
            syncHealth: SyncHealth(
                watchReachable: true,
                queuedUploads: 1,
                lastSuccessfulSync: startedAt,
                failingItems: 0
            ),
            repository: repository
        )
        let processor = UploadQueueProcessor(client: SucceedingUploadClient(objectKey: "audio/idea_interrupted_processor/rec_interrupted_processor.m4a"))

        let summary = await processor.processDueUploads(in: store, now: recoveredAt)

        let saved = try XCTUnwrap(try repository.load())
        XCTAssertEqual(summary.attemptedCount, 1)
        XCTAssertEqual(summary.uploadedCount, 1)
        XCTAssertEqual(summary.failedCount, 0)
        XCTAssertEqual(saved.uploadJobs.first?.status, .uploaded)
        XCTAssertEqual(saved.uploadJobs.first?.attemptCount, 2)
        XCTAssertEqual(saved.projects.first?.recordings.first?.syncStatus, .uploaded)
        XCTAssertEqual(saved.syncHealth.queuedUploads, 0)
    }

    func testWorkflowRunAddsArtifactsToSelectedProject() async throws {
        let repository = InMemoryWorkspaceRepository()
        let state = WorkspaceState.seed()
        let store = IdeaForgeStore(state: state, repository: repository)

        await store.runWorkflow(templateID: "wf_codex_packet")

        let saved = try XCTUnwrap(try repository.load())
        let selected = try XCTUnwrap(saved.projects.first { $0.id == saved.selectedProjectID })
        XCTAssertTrue(selected.artifacts.contains { $0.kind == .codexTaskBundle })
        XCTAssertTrue(selected.artifacts.contains { $0.kind == .architecture })
    }

    @MainActor
    func testWorkflowRunPersistsStepHistoryAndArtifactProvenance() async throws {
        let repository = InMemoryWorkspaceRepository()
        let state = WorkspaceState.seed()
        let store = IdeaForgeStore(state: state, repository: repository)

        await store.runWorkflow(templateID: "wf_codex_packet")

        let saved = try XCTUnwrap(try repository.load())
        let selected = try XCTUnwrap(saved.projects.first { $0.id == saved.selectedProjectID })
        let run = try XCTUnwrap(selected.workflowRuns.first)
        XCTAssertEqual(run.templateID, "wf_codex_packet")
        XCTAssertEqual(run.templateName, "Codex Build Packet")
        XCTAssertEqual(run.status, .completed)
        XCTAssertEqual(run.stepRuns.map(\.stepID), ["step_architecture", "step_codex_tasks"])
        XCTAssertTrue(run.stepRuns.allSatisfy { $0.status == .completed })
        XCTAssertEqual(Set(run.artifactIDs), Set(selected.artifacts.filter { $0.sourceWorkflowRunID == run.id }.map(\.id)))
        XCTAssertFalse(run.artifactIDs.isEmpty)
    }

    @MainActor
    func testFailedWorkflowRunPersistsFailureHistoryWithoutArtifacts() async throws {
        let repository = InMemoryWorkspaceRepository()
        let state = WorkspaceState.seed()
        let store = IdeaForgeStore(state: state, repository: repository)
        let services = IdeaForgeServices(
            transcription: LocalTranscriptionService(),
            workflow: FailingWorkflowExecutionService(),
            syncQueue: LocalSyncQueueService(),
            export: LocalExportService()
        )

        await store.runWorkflow(templateID: "wf_codex_packet", services: services)

        let saved = try XCTUnwrap(try repository.load())
        let selected = try XCTUnwrap(saved.projects.first { $0.id == saved.selectedProjectID })
        let run = try XCTUnwrap(selected.workflowRuns.first)
        XCTAssertEqual(run.status, .failed)
        XCTAssertEqual(run.templateID, "wf_codex_packet")
        XCTAssertEqual(run.artifactIDs, [])
        XCTAssertEqual(run.errorMessage, "Workflow failed.")
        XCTAssertTrue(run.stepRuns.allSatisfy { $0.status == .failed })
        XCTAssertEqual(store.lastErrorMessage, "Workflow failed.")
    }

    @MainActor
    func testBackendProviderFailurePersistsRetryableWorkflowDiagnosticsWithoutContent() async throws {
        let repository = InMemoryWorkspaceRepository()
        let state = WorkspaceState.seed()
        let store = IdeaForgeStore(state: state, repository: repository)
        let services = IdeaForgeServices(
            transcription: LocalTranscriptionService(),
            workflow: ProviderFailingWorkflowExecutionService(),
            syncQueue: LocalSyncQueueService(),
            export: LocalExportService()
        )

        await store.runWorkflow(templateID: "wf_codex_packet", services: services)

        let saved = try XCTUnwrap(try repository.load())
        let selected = try XCTUnwrap(saved.projects.first { $0.id == saved.selectedProjectID })
        let run = try XCTUnwrap(selected.workflowRuns.first)
        XCTAssertEqual(run.status, .failed)
        XCTAssertEqual(run.artifactIDs, [])
        XCTAssertEqual(run.errorMessage, "AI provider failed: rate_limit_exceeded (HTTP 429, retryable).")
        XCTAssertTrue(run.stepRuns.allSatisfy {
            $0.status == .failed
                && $0.errorMessage == "AI provider failed: rate_limit_exceeded (HTTP 429, retryable)."
        })
        XCTAssertEqual(store.lastErrorMessage, "AI provider failed: rate_limit_exceeded (HTTP 429, retryable).")
        XCTAssertFalse(run.errorMessage?.contains(selected.title) ?? true)
        XCTAssertFalse(run.errorMessage?.contains(selected.summary) ?? true)
    }

    @MainActor
    func testBackendEntitlementDenialPersistsWorkflowDiagnosticWithoutContent() async throws {
        let repository = InMemoryWorkspaceRepository()
        let state = WorkspaceState.seed()
        let store = IdeaForgeStore(state: state, repository: repository)
        let services = IdeaForgeServices(
            transcription: LocalTranscriptionService(),
            workflow: EntitlementDeniedWorkflowExecutionService(
                denial: BackendEntitlementDenial(
                    metric: BackendEntitlementMetric.workflowRuns,
                    reason: .exhausted
                )
            ),
            syncQueue: LocalSyncQueueService(),
            export: LocalExportService()
        )

        await store.runWorkflow(templateID: "wf_codex_packet", services: services)

        let saved = try XCTUnwrap(try repository.load())
        let selected = try XCTUnwrap(saved.projects.first { $0.id == saved.selectedProjectID })
        let run = try XCTUnwrap(selected.workflowRuns.first)
        XCTAssertEqual(run.status, .failed)
        XCTAssertEqual(run.artifactIDs, [])
        XCTAssertEqual(run.errorMessage, "Backend entitlement unavailable: workflow_runs exhausted.")
        XCTAssertNil(run.nextRetryAt)
        XCTAssertTrue(run.stepRuns.allSatisfy {
            $0.status == .failed
                && $0.errorMessage == "Backend entitlement unavailable: workflow_runs exhausted."
        })
        XCTAssertEqual(store.lastErrorMessage, "Backend entitlement unavailable: workflow_runs exhausted.")
        XCTAssertFalse(run.errorMessage?.contains(selected.title) ?? true)
        XCTAssertFalse(run.errorMessage?.contains(selected.summary) ?? true)
    }

    @MainActor
    func testRetryableBackendProviderFailureSchedulesRetryBeforeRunningAgain() async throws {
        let repository = InMemoryWorkspaceRepository()
        let state = WorkspaceState.seed()
        let store = IdeaForgeStore(state: state, repository: repository)
        let failingServices = IdeaForgeServices(
            transcription: LocalTranscriptionService(),
            workflow: ProviderFailingWorkflowExecutionService(),
            syncQueue: LocalSyncQueueService(),
            export: LocalExportService()
        )

        await store.runWorkflow(templateID: "wf_codex_packet", services: failingServices)
        let failedRun = try XCTUnwrap(store.selectedProject?.workflowRuns.first)
        let completedAt = try XCTUnwrap(failedRun.completedAt)
        let nextRetryAt = try XCTUnwrap(failedRun.nextRetryAt)
        XCTAssertEqual(failedRun.retryAttempt, 0)
        XCTAssertGreaterThanOrEqual(nextRetryAt.timeIntervalSince(completedAt), 59)
        XCTAssertLessThanOrEqual(nextRetryAt.timeIntervalSince(completedAt), 61)
        let runCountAfterFailure = store.selectedProject?.workflowRuns.count

        await store.retryWorkflowRun(runID: failedRun.id, now: nextRetryAt.addingTimeInterval(-1))
        XCTAssertEqual(store.selectedProject?.workflowRuns.count, runCountAfterFailure)
        XCTAssertEqual(store.lastErrorMessage, "Workflow retry is scheduled.")

        await store.retryWorkflowRun(runID: failedRun.id, now: nextRetryAt)

        let retriedRun = try XCTUnwrap(store.selectedProject?.workflowRuns.first)
        XCTAssertEqual(retriedRun.status, .completed)
        XCTAssertEqual(retriedRun.retryOfRunID, failedRun.id)
        XCTAssertEqual(retriedRun.retryAttempt, 1)
    }

    @MainActor
    func testWorkflowRetryProcessorRunsOnlyDueScheduledProviderFailures() async throws {
        let repository = InMemoryWorkspaceRepository()
        let state = WorkspaceState.seed()
        let store = IdeaForgeStore(state: state, repository: repository)
        let failingServices = IdeaForgeServices(
            transcription: LocalTranscriptionService(),
            workflow: ProviderFailingWorkflowExecutionService(),
            syncQueue: LocalSyncQueueService(),
            export: LocalExportService()
        )

        await store.runWorkflow(templateID: "wf_codex_packet", services: failingServices)
        let failedRun = try XCTUnwrap(store.selectedProject?.workflowRuns.first)
        let nextRetryAt = try XCTUnwrap(failedRun.nextRetryAt)
        let runCountAfterFailure = store.selectedProject?.workflowRuns.count
        let processor = WorkflowRetryProcessor(services: .local)

        let earlySummary = await processor.processDueRetries(
            in: store,
            now: nextRetryAt.addingTimeInterval(-1)
        )
        XCTAssertEqual(earlySummary, WorkflowRetryProcessingSummary())
        XCTAssertEqual(store.selectedProject?.workflowRuns.count, runCountAfterFailure)

        let dueSummary = await processor.processDueRetries(in: store, now: nextRetryAt)
        let retriedRun = try XCTUnwrap(store.selectedProject?.workflowRuns.first)

        XCTAssertEqual(dueSummary.attemptedCount, 1)
        XCTAssertEqual(dueSummary.completedCount, 1)
        XCTAssertEqual(dueSummary.failedCount, 0)
        XCTAssertEqual(dueSummary.skippedCount, 0)
        XCTAssertEqual(retriedRun.status, .completed)
        XCTAssertEqual(retriedRun.retryOfRunID, failedRun.id)
        XCTAssertEqual(retriedRun.retryAttempt, 1)

        let repeatedSummary = await processor.processDueRetries(
            in: store,
            now: nextRetryAt.addingTimeInterval(600)
        )
        XCTAssertEqual(repeatedSummary, WorkflowRetryProcessingSummary())
    }

    @MainActor
    func testWorkflowRetryProcessorLeavesManualFailuresAlone() async throws {
        let repository = InMemoryWorkspaceRepository()
        let state = WorkspaceState.seed()
        let store = IdeaForgeStore(state: state, repository: repository)
        let failingServices = IdeaForgeServices(
            transcription: LocalTranscriptionService(),
            workflow: FailingWorkflowExecutionService(),
            syncQueue: LocalSyncQueueService(),
            export: LocalExportService()
        )

        await store.runWorkflow(templateID: "wf_codex_packet", services: failingServices)
        let failedRun = try XCTUnwrap(store.selectedProject?.workflowRuns.first)
        XCTAssertNil(failedRun.nextRetryAt)

        let processor = WorkflowRetryProcessor(services: .local)
        let summary = await processor.processDueRetries(
            in: store,
            now: Date().addingTimeInterval(10_000)
        )

        XCTAssertEqual(summary, WorkflowRetryProcessingSummary())
        XCTAssertEqual(store.selectedProject?.workflowRuns.first?.id, failedRun.id)
    }

    @MainActor
    func testRetryFailedWorkflowRunPersistsLinkedCompletedRun() async throws {
        let repository = InMemoryWorkspaceRepository()
        let state = WorkspaceState.seed()
        let store = IdeaForgeStore(state: state, repository: repository)
        let failingServices = IdeaForgeServices(
            transcription: LocalTranscriptionService(),
            workflow: FailingWorkflowExecutionService(),
            syncQueue: LocalSyncQueueService(),
            export: LocalExportService()
        )

        await store.runWorkflow(templateID: "wf_codex_packet", services: failingServices)
        let failedRunID = try XCTUnwrap(store.selectedProject?.workflowRuns.first?.id)

        await store.retryWorkflowRun(runID: failedRunID)

        let saved = try XCTUnwrap(try repository.load())
        let selected = try XCTUnwrap(saved.projects.first { $0.id == saved.selectedProjectID })
        let retriedRun = try XCTUnwrap(selected.workflowRuns.first)
        XCTAssertEqual(retriedRun.status, .completed)
        XCTAssertEqual(retriedRun.retryOfRunID, failedRunID)
        XCTAssertEqual(retriedRun.retryAttempt, 1)
        XCTAssertFalse(retriedRun.artifactIDs.isEmpty)
        XCTAssertTrue(selected.workflowRuns.contains { $0.id == failedRunID && $0.status == .failed })
    }

    @MainActor
    func testConcurrentWorkflowRetryStartsOnlyOneChildRun() async throws {
        let repository = InMemoryWorkspaceRepository()
        let store = IdeaForgeStore(state: WorkspaceState.seed(), repository: repository)
        let failingServices = IdeaForgeServices(
            transcription: LocalTranscriptionService(),
            workflow: FailingWorkflowExecutionService(),
            syncQueue: LocalSyncQueueService(),
            export: LocalExportService()
        )

        await store.runWorkflow(templateID: "wf_codex_packet", services: failingServices)
        let failedRunID = try XCTUnwrap(store.selectedProject?.workflowRuns.first?.id)
        let blockingWorkflow = BlockingWorkflowExecutionService()
        let retryServices = IdeaForgeServices(
            transcription: LocalTranscriptionService(),
            workflow: blockingWorkflow,
            syncQueue: LocalSyncQueueService(),
            export: LocalExportService()
        )

        let firstRetry = Task { @MainActor in
            await store.retryWorkflowRun(runID: failedRunID, services: retryServices)
        }
        await blockingWorkflow.waitUntilStarted()

        await store.retryWorkflowRun(runID: failedRunID, services: retryServices)
        XCTAssertEqual(store.lastErrorMessage, "Workflow retry is already in progress.")
        XCTAssertEqual(store.selectedProject?.workflowRuns.filter { $0.retryOfRunID == failedRunID }.count, 0)

        await blockingWorkflow.release()
        await firstRetry.value

        let executionCount = await blockingWorkflow.executionCount()
        XCTAssertEqual(executionCount, 1)
        XCTAssertEqual(store.selectedProject?.workflowRuns.filter { $0.retryOfRunID == failedRunID }.count, 1)
        XCTAssertNil(store.lastErrorMessage)
    }

    @MainActor
    func testCompletedWorkflowRunRetryIsIgnored() async throws {
        let repository = InMemoryWorkspaceRepository()
        let state = WorkspaceState.seed()
        let store = IdeaForgeStore(state: state, repository: repository)

        await store.runWorkflow(templateID: "wf_codex_packet")
        let completedRunID = try XCTUnwrap(store.selectedProject?.workflowRuns.first?.id)
        let runCount = store.selectedProject?.workflowRuns.count

        await store.retryWorkflowRun(runID: completedRunID)

        XCTAssertEqual(store.selectedProject?.workflowRuns.count, runCount)
    }

    @MainActor
    func testMVPWorkflowRunProducesSchemaCompletePlanningPacket() async throws {
        let repository = InMemoryWorkspaceRepository()
        let state = WorkspaceState.seed()
        let store = IdeaForgeStore(state: state, repository: repository)

        await store.runWorkflow(templateID: "wf_app_idea_mvp")

        let saved = try XCTUnwrap(try repository.load())
        let selected = try XCTUnwrap(saved.projects.first { $0.id == saved.selectedProjectID })
        let latestRun = try XCTUnwrap(selected.workflowRuns.first)
        let runArtifacts = selected.artifacts.filter { $0.sourceWorkflowRunID == latestRun.id }
        let evaluation = try XCTUnwrap(latestRun.evaluation)

        XCTAssertEqual(Set(runArtifacts.map(\.kind)), Set([.ideaBrief, .roadmap, .validationPlan]))
        XCTAssertEqual(evaluation.schemaCompletenessScore, 1)
        XCTAssertEqual(evaluation.decision, .blocked)
        XCTAssertTrue(evaluation.blockers.contains("1 blocking question needs an answer."))
        XCTAssertFalse(evaluation.schemaIssues.contains { $0.contains("IdeaBriefArtifact") })
        XCTAssertFalse(evaluation.schemaIssues.contains { $0.contains("MVPPlanArtifact") })
        XCTAssertFalse(evaluation.schemaIssues.contains { $0.contains("ValidationPlanArtifact") })
    }

    @MainActor
    func testFullBuildPacketWorkflowRunProducesSchemaCompleteOriginalPlanPacket() async throws {
        let repository = InMemoryWorkspaceRepository()
        let state = WorkspaceState.seed()
        let store = IdeaForgeStore(state: state, repository: repository)

        await store.runWorkflow(templateID: "wf_full_build_packet")

        let saved = try XCTUnwrap(try repository.load())
        let selected = try XCTUnwrap(saved.projects.first { $0.id == saved.selectedProjectID })
        let latestRun = try XCTUnwrap(selected.workflowRuns.first)
        let runArtifacts = selected.artifacts.filter { $0.sourceWorkflowRunID == latestRun.id }
        let evaluation = try XCTUnwrap(latestRun.evaluation)
        let expectedKinds: Set<ArtifactKind> = [
            .ideaBrief,
            .prd,
            .architecture,
            .uxFlow,
            .dataModel,
            .apiDesign,
            .roadmap,
            .issueBundle,
            .codexTaskBundle,
            .launchChecklist
        ]

        XCTAssertEqual(Set(runArtifacts.map(\.kind)), expectedKinds)
        XCTAssertEqual(evaluation.schemaCompletenessScore, 1)
        XCTAssertEqual(evaluation.generatedArtifactCount, expectedKinds.count)
        XCTAssertEqual(evaluation.decision, .blocked)
        XCTAssertTrue(evaluation.blockers.contains("1 blocking question needs an answer."))

        for schemaName in [
            "IdeaBriefArtifact",
            "PRDArtifact",
            "ArchitectureArtifact",
            "UXFlowArtifact",
            "DataModelArtifact",
            "APIDesignArtifact",
            "MVPPlanArtifact",
            "IssueBundleArtifact",
            "CodexPacketSchema",
            "LaunchChecklistArtifact"
        ] {
            XCTAssertFalse(
                evaluation.schemaIssues.contains { $0.contains(schemaName) },
                "\(schemaName) should be schema-complete."
            )
        }
    }

    @MainActor
    func testRepeatedWorkflowRunCreatesVersionedArtifactsAndComparison() async throws {
        let repository = InMemoryWorkspaceRepository()
        let state = WorkspaceState.seed()
        let store = IdeaForgeStore(state: state, repository: repository)

        await store.runWorkflow(templateID: "wf_codex_packet")
        await store.runWorkflow(templateID: "wf_codex_packet")

        let saved = try XCTUnwrap(try repository.load())
        let selected = try XCTUnwrap(saved.projects.first { $0.id == saved.selectedProjectID })
        let latestRun = try XCTUnwrap(selected.workflowRuns.first)
        let previousRun = try XCTUnwrap(selected.workflowRuns.dropFirst().first)
        let architectureVersions = selected.artifacts
            .filter { $0.kind == .architecture && $0.createdBy == "local-workflow" }
            .map(\.version)
            .sorted()

        XCTAssertEqual(architectureVersions, [1, 2])

        let comparison = try XCTUnwrap(selected.workflowComparison(forRunID: latestRun.id))
        XCTAssertEqual(comparison.previousRunID, previousRun.id)
        XCTAssertEqual(comparison.changes.first { $0.kind == .architecture }?.status, .updated)
        XCTAssertEqual(comparison.changes.first { $0.kind == .architecture }?.previousVersion, 1)
        XCTAssertEqual(comparison.changes.first { $0.kind == .architecture }?.currentVersion, 2)
    }

    @MainActor
    func testArtifactHistoriesGroupVersionsNewestFirst() async throws {
        let repository = InMemoryWorkspaceRepository()
        let state = WorkspaceState.seed()
        let store = IdeaForgeStore(state: state, repository: repository)

        await store.runWorkflow(templateID: "wf_codex_packet")
        await store.runWorkflow(templateID: "wf_codex_packet")

        let saved = try XCTUnwrap(try repository.load())
        let selected = try XCTUnwrap(saved.projects.first { $0.id == saved.selectedProjectID })
        let histories = selected.artifactHistories
        let architectureHistory = try XCTUnwrap(histories.first { $0.kind == .architecture })
        let codexHistory = try XCTUnwrap(histories.first { $0.kind == .codexTaskBundle })

        XCTAssertEqual(architectureHistory.latest.version, 2)
        XCTAssertEqual(architectureHistory.versions.map(\.version), [2, 1])
        XCTAssertEqual(architectureHistory.versionCount, 2)
        XCTAssertEqual(codexHistory.latest.version, 2)
        XCTAssertEqual(histories.first?.kind, .architecture)
    }

    func testArtifactHistoryBuildsLatestLineDiff() throws {
        let previous = Artifact(
            id: "prd_v1",
            kind: .prd,
            title: "PRD",
            markdown: "# Plan\n\n- Capture\n- Export",
            version: 1,
            createdBy: "test",
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let current = Artifact(
            id: "prd_v2",
            kind: .prd,
            title: "PRD",
            markdown: "# Plan\n\n- Capture\n- Validate\n- Export",
            version: 2,
            createdBy: "test",
            createdAt: Date(timeIntervalSince1970: 20)
        )

        let diff = try XCTUnwrap(ArtifactHistory(kind: .prd, versions: [current, previous]).latestDiff)

        XCTAssertEqual(diff.previousArtifactID, "prd_v1")
        XCTAssertEqual(diff.currentArtifactID, "prd_v2")
        XCTAssertEqual(diff.previousVersion, 1)
        XCTAssertEqual(diff.currentVersion, 2)
        XCTAssertEqual(diff.addedLineCount, 1)
        XCTAssertEqual(diff.removedLineCount, 0)
        XCTAssertEqual(diff.unchangedLineCount, 4)
        XCTAssertTrue(diff.hasContentChanges)
        XCTAssertEqual(diff.lines.first { $0.status == .added }?.text, "- Validate")
        XCTAssertEqual(diff.lines.first { $0.status == .added }?.newLineNumber, 4)
    }

    func testWorkflowRunReviewBlocksMissingArtifactsWithoutLeakingArtifactIDs() throws {
        let readyEvaluation = WorkflowRunEvaluation(
            readinessScore: 0.92,
            decision: .ready,
            generatedArtifactCount: 2,
            blockingIssueCount: 0,
            blockers: []
        )
        let artifact = Artifact(
            id: "artifact_architecture_present",
            kind: .architecture,
            title: "Architecture",
            markdown: "# Architecture\n\nPrivate recorder path: /Users/person/recordings/secret.m4a",
            version: 1,
            createdBy: "local-workflow",
            createdAt: SampleData.now,
            sourceWorkflowRunID: "run_review"
        )
        let missingArtifactID = "missing_private_path_/Users/person/recordings/secret.m4a"
        let run = WorkflowRun(
            id: "run_review",
            templateID: "wf_codex_packet",
            templateName: "Codex Build Packet",
            status: .completed,
            stepRuns: [],
            artifactIDs: [artifact.id, missingArtifactID],
            startedAt: SampleData.now,
            completedAt: SampleData.now,
            evaluation: readyEvaluation
        )
        var project = SampleData.ideaForgeProject
        project.artifacts = [artifact]
        project.workflowRuns = [run]

        let review = try XCTUnwrap(project.workflowRunReview(forRunID: run.id, now: SampleData.now))

        XCTAssertEqual(review.decision, .blocked)
        XCTAssertFalse(review.isReadyForHandoff)
        XCTAssertEqual(review.artifactCount, 1)
        XCTAssertEqual(review.missingArtifactCount, 1)
        XCTAssertTrue(review.blockerSummaries.contains("1 referenced artifact is missing from project history."))
        let renderedReviewText = (review.blockerSummaries + review.warningSummaries + review.artifactChangeSummaries + [review.provenanceSummary])
            .joined(separator: "\n")
        XCTAssertFalse(renderedReviewText.contains(missingArtifactID))
        XCTAssertFalse(renderedReviewText.contains("/Users/person/recordings/secret.m4a"))
    }

    func testWorkflowRunReviewSummarizesArtifactChangesAndReadyHandoff() throws {
        let readyEvaluation = WorkflowRunEvaluation(
            readinessScore: 0.95,
            decision: .ready,
            generatedArtifactCount: 1,
            blockingIssueCount: 0,
            blockers: []
        )
        let previousArtifact = Artifact(
            id: "artifact_architecture_v1",
            kind: .architecture,
            title: "Architecture",
            markdown: "# Architecture\n\n## Decision\nLocal-first clients.",
            version: 1,
            createdBy: "local-workflow",
            createdAt: SampleData.now.addingTimeInterval(-120),
            sourceWorkflowRunID: "run_previous"
        )
        let currentArtifact = Artifact(
            id: "artifact_architecture_v2",
            kind: .architecture,
            title: "Architecture",
            markdown: "# Architecture\n\n## Decision\nLocal-first clients with reviewed sync.",
            version: 2,
            createdBy: "local-workflow",
            createdAt: SampleData.now,
            sourceWorkflowRunID: "run_current"
        )
        let previousRun = WorkflowRun(
            id: "run_previous",
            templateID: "wf_codex_packet",
            templateName: "Codex Build Packet",
            status: .completed,
            stepRuns: [],
            artifactIDs: [previousArtifact.id],
            startedAt: SampleData.now.addingTimeInterval(-120),
            completedAt: SampleData.now.addingTimeInterval(-90),
            evaluation: readyEvaluation
        )
        let currentRun = WorkflowRun(
            id: "run_current",
            templateID: "wf_codex_packet",
            templateName: "Codex Build Packet",
            status: .completed,
            stepRuns: [],
            artifactIDs: [currentArtifact.id],
            startedAt: SampleData.now,
            completedAt: SampleData.now,
            evaluation: readyEvaluation
        )
        var project = SampleData.ideaForgeProject
        project.artifacts = [currentArtifact, previousArtifact]
        project.workflowRuns = [currentRun, previousRun]

        let review = try XCTUnwrap(project.workflowRunReview(forRunID: currentRun.id, now: SampleData.now))

        XCTAssertEqual(review.decision, .ready)
        XCTAssertTrue(review.isReadyForHandoff)
        XCTAssertEqual(review.artifactChangeSummaries, ["Architecture: v1 -> v2"])
        XCTAssertTrue(review.provenanceSummary.contains("wf_codex_packet"))
        XCTAssertTrue(review.provenanceSummary.contains("1 resolved artifacts"))
    }

    @MainActor
    func testCompletedWorkflowRunPersistsEvaluationSummary() async throws {
        let repository = InMemoryWorkspaceRepository()
        let state = WorkspaceState.seed()
        let store = IdeaForgeStore(state: state, repository: repository)

        await store.runWorkflow(templateID: "wf_codex_packet")

        let saved = try XCTUnwrap(try repository.load())
        let selected = try XCTUnwrap(saved.projects.first { $0.id == saved.selectedProjectID })
        let run = try XCTUnwrap(selected.workflowRuns.first)
        let evaluation = try XCTUnwrap(run.evaluation)
        XCTAssertEqual(evaluation.decision, .blocked)
        XCTAssertEqual(evaluation.generatedArtifactCount, 2)
        XCTAssertEqual(evaluation.blockingIssueCount, 1)
        XCTAssertTrue(evaluation.readinessScore > 0)
        XCTAssertTrue(evaluation.readinessScore < 1)
        XCTAssertTrue(evaluation.blockers.contains("1 blocking question needs an answer."))
        XCTAssertFalse(evaluation.blockers.contains("Who is the first user"))
        XCTAssertEqual(evaluation.rubricItems.count, 4)
        XCTAssertEqual(evaluation.rubricItems.first { $0.id == "handoff_safety" }?.status, .passing)
        XCTAssertGreaterThan(evaluation.rubricScore, 0.9)
    }

    func testWorkflowEvaluationReportsMissingRequiredSchemaFields() throws {
        let template = try XCTUnwrap(DefaultWorkflows.templates.first { $0.id == "wf_codex_packet" })
        var project = SampleData.ideaForgeProject
        project.questions = project.questions.map { question in
            Question(id: question.id, prompt: question.prompt, answer: question.answer ?? "Answered.", isBlocking: question.isBlocking)
        }
        let artifacts = [
            Artifact(
                id: "artifact_architecture_incomplete",
                kind: .architecture,
                title: "Architecture",
                markdown: """
                # Architecture

                ## Decision
                Build local-first Apple clients with backend sync seams.
                """,
                version: 1,
                createdBy: "local-workflow",
                createdAt: SampleData.now
            ),
            Artifact(
                id: "artifact_codex_complete",
                kind: .codexTaskBundle,
                title: "Codex Packet",
                markdown: """
                # Codex Packet

                ## Repo Context
                IdeaForge native Apple app.

                ## Tasks
                - Keep the workflow auditable.

                ## Checks
                - Run swift test.
                """,
                version: 1,
                createdBy: "local-workflow",
                createdAt: SampleData.now
            )
        ]
        let stepRuns = template.steps.map { step in
            StepRun(
                id: "step_run_\(step.id)",
                stepID: step.id,
                stepName: step.name,
                status: .completed,
                outputArtifactIDs: artifacts.filter { $0.kind == template.schemaContract(named: step.outputSchemaName)?.outputKind }.map(\.id),
                startedAt: SampleData.now,
                completedAt: SampleData.now
            )
        }

        let evaluation = WorkflowRunEvaluator.evaluate(
            template: template,
            project: project,
            stepRuns: stepRuns,
            artifacts: artifacts
        )

        XCTAssertLessThan(evaluation.schemaCompletenessScore, 1)
        XCTAssertEqual(evaluation.schemaIssues, ["ArchitectureArtifact missing required fields: components, risks."])
        XCTAssertTrue(evaluation.blockers.contains("ArchitectureArtifact missing required fields: components, risks."))
        XCTAssertEqual(evaluation.decision, .blocked)
    }

    func testWorkflowEvaluationRubricBlocksUnsafeThinHandoffArtifacts() throws {
        let template = try XCTUnwrap(DefaultWorkflows.templates.first { $0.id == "wf_codex_packet" })
        var project = SampleData.ideaForgeProject
        project.questions = project.questions.map { question in
            Question(id: question.id, prompt: question.prompt, answer: "Answered.", isBlocking: question.isBlocking)
        }
        let artifacts = [
            Artifact(
                id: "artifact_codex_thin",
                kind: .codexTaskBundle,
                title: "Codex Packet",
                markdown: "# Build\n\nImplement the app.",
                version: 1,
                createdBy: "backend-ai",
                createdAt: SampleData.now
            )
        ]
        let stepRuns = template.steps.map { step in
            StepRun(
                id: "step_run_\(step.id)",
                stepID: step.id,
                stepName: step.name,
                status: .completed,
                outputArtifactIDs: artifacts.map(\.id),
                startedAt: SampleData.now,
                completedAt: SampleData.now
            )
        }

        let evaluation = WorkflowRunEvaluator.evaluate(
            template: template,
            project: project,
            stepRuns: stepRuns,
            artifacts: artifacts
        )

        XCTAssertLessThan(evaluation.rubricScore, 1)
        XCTAssertEqual(evaluation.rubricItems.first { $0.id == "handoff_safety" }?.status, .failing)
        XCTAssertTrue(evaluation.blockers.contains("AI rubric failed: Handoff Safety."))
        XCTAssertEqual(evaluation.decision, .blocked)
    }

    func testWorkflowRunEvaluationDecodeDefaultsRubricForOlderRuns() throws {
        let data = Data(
            #"""
            {
              "readinessScore": 0.5,
              "decision": "needsReview",
              "generatedArtifactCount": 1,
              "blockingIssueCount": 0,
              "blockers": [],
              "schemaCompletenessScore": 1,
              "schemaIssues": []
            }
            """#.utf8
        )

        let evaluation = try JSONDecoder().decode(WorkflowRunEvaluation.self, from: data)

        XCTAssertEqual(evaluation.rubricScore, 1)
        XCTAssertEqual(evaluation.rubricItems, [])
    }

    func testCustomWorkflowTemplatePersistsStepSchemaAndReviewPolicy() throws {
        let repository = InMemoryWorkspaceRepository()
        let state = WorkspaceState.seed()
        let store = IdeaForgeStore(state: state, repository: repository)

        let custom = try XCTUnwrap(store.createCustomWorkflowTemplate(
            WorkflowTemplateCustomization(
                baseTemplateID: "wf_codex_packet",
                name: "Founder Review Packet",
                summary: "Codex packet with stricter founder review and a custom architecture schema.",
                stepUpdates: [
                    WorkflowStepUpdate(
                        stepID: "step_architecture",
                        name: "Founder architecture review",
                        inputKeys: ["prd", "constraints", "pricing", "risk_register"],
                        outputSchemaName: "FounderArchitectureReviewSchema",
                        requiresUserReview: true,
                        modelPolicy: .best
                    )
                ],
                schemaContracts: [
                    WorkflowSchemaContract(
                        name: "FounderArchitectureReviewSchema",
                        requiredInputKeys: ["prd", "constraints", "pricing", "risk_register"],
                        outputKind: .architecture,
                        summary: "Founder-facing architecture review schema.",
                        fields: [
                            WorkflowSchemaField(name: "decision", valueType: "string", summary: "Founder-facing architecture decision."),
                            WorkflowSchemaField(name: "tradeoffs", valueType: "list", summary: "Important product and technical tradeoffs.")
                        ]
                    )
                ]
            )
        ))

        let saved = try XCTUnwrap(try repository.load())
        let savedTemplate = try XCTUnwrap(saved.workflowTemplates.first { $0.id == custom.id })
        let editedStep = try XCTUnwrap(savedTemplate.steps.first { $0.id == "step_architecture" })
        XCTAssertEqual(savedTemplate.name, "Founder Review Packet")
        XCTAssertEqual(editedStep.name, "Founder architecture review")
        XCTAssertEqual(editedStep.inputKeys, ["prd", "constraints", "pricing", "risk_register"])
        XCTAssertEqual(editedStep.outputSchemaName, "FounderArchitectureReviewSchema")
        XCTAssertEqual(editedStep.modelPolicy, .best)
        XCTAssertTrue(editedStep.requiresUserReview)
        XCTAssertEqual(editedStep.version, 2)
        XCTAssertEqual(savedTemplate.schemaContracts.first?.name, "FounderArchitectureReviewSchema")
        XCTAssertEqual(savedTemplate.schemaContracts.first?.fields.map(\.name), ["decision", "tradeoffs"])
        XCTAssertEqual(saved.workflowTemplates.first { $0.id == "wf_codex_packet" }?.steps.first?.version, 1)
    }

    @MainActor
    func testLocalWorkflowRunHonorsCustomSchemaFieldsInGeneratedArtifacts() async throws {
        let repository = InMemoryWorkspaceRepository()
        let state = WorkspaceState.seed()
        let store = IdeaForgeStore(state: state, repository: repository)
        let custom = try XCTUnwrap(store.createCustomWorkflowTemplate(
            WorkflowTemplateCustomization(
                baseTemplateID: "wf_codex_packet",
                name: "Architecture Tradeoff Packet",
                summary: "Codex packet that requires founder-facing tradeoff analysis.",
                stepUpdates: [
                    WorkflowStepUpdate(
                        stepID: "step_architecture",
                        outputSchemaName: "TradeoffArchitectureArtifact",
                        modelPolicy: .best
                    )
                ],
                schemaContracts: [
                    WorkflowSchemaContract(
                        name: "TradeoffArchitectureArtifact",
                        requiredInputKeys: ["prd", "constraints", "platforms"],
                        outputKind: .architecture,
                        summary: "Architecture schema with explicit tradeoff analysis.",
                        fields: [
                            WorkflowSchemaField(name: "decision", valueType: "string", summary: "Recommended technical direction."),
                            WorkflowSchemaField(name: "tradeoffs", valueType: "list", summary: "Important product and technical tradeoffs."),
                            WorkflowSchemaField(name: "risks", valueType: "list", summary: "Technical risks and boundaries.")
                        ]
                    )
                ]
            )
        ))

        await store.runWorkflow(templateID: custom.id)

        let saved = try XCTUnwrap(try repository.load())
        let selected = try XCTUnwrap(saved.projects.first { $0.id == saved.selectedProjectID })
        let latestRun = try XCTUnwrap(selected.workflowRuns.first)
        let architecture = try XCTUnwrap(selected.artifacts.first { $0.kind == .architecture && $0.sourceWorkflowRunID == latestRun.id })
        let evaluation = try XCTUnwrap(latestRun.evaluation)

        XCTAssertTrue(architecture.markdown.localizedCaseInsensitiveContains("## Tradeoffs"))
        XCTAssertEqual(evaluation.schemaCompletenessScore, 1)
        XCTAssertFalse(evaluation.schemaIssues.contains { $0.contains("TradeoffArchitectureArtifact") })
    }

    @MainActor
    func testWorkflowSchemaFieldEditPersistsAndDrivesGeneratedArtifact() async throws {
        let repository = InMemoryWorkspaceRepository()
        let state = WorkspaceState.seed()
        let store = IdeaForgeStore(state: state, repository: repository)

        let wasEdited = store.addWorkflowSchemaField(
            templateID: "wf_codex_packet",
            schemaName: "ArchitectureArtifact",
            field: WorkflowSchemaField(
                name: "dependencies",
                valueType: "list",
                summary: "External systems or services this architecture depends on."
            )
        )

        XCTAssertTrue(wasEdited)
        let saved = try XCTUnwrap(try repository.load())
        let savedTemplate = try XCTUnwrap(saved.workflowTemplates.first { $0.id == "wf_codex_packet" })
        let architectureContract = try XCTUnwrap(savedTemplate.schemaContracts.first { $0.name == "ArchitectureArtifact" })
        XCTAssertEqual(architectureContract.fields.map(\.name), ["decision", "components", "risks", "dependencies"])

        await store.runWorkflow(templateID: "wf_codex_packet")

        let updatedState = try XCTUnwrap(try repository.load())
        let selected = try XCTUnwrap(updatedState.projects.first { $0.id == updatedState.selectedProjectID })
        let latestRun = try XCTUnwrap(selected.workflowRuns.first)
        let architecture = try XCTUnwrap(selected.artifacts.first { $0.kind == .architecture && $0.sourceWorkflowRunID == latestRun.id })
        let evaluation = try XCTUnwrap(latestRun.evaluation)

        XCTAssertTrue(architecture.markdown.localizedCaseInsensitiveContains("## Dependencies"))
        XCTAssertEqual(evaluation.schemaCompletenessScore, 1)
        XCTAssertFalse(evaluation.schemaIssues.contains { $0.contains("ArchitectureArtifact") })
    }

    @MainActor
    func testWorkflowSchemaFieldEditorUpdatesDeletesAndReordersFields() async throws {
        let repository = InMemoryWorkspaceRepository()
        let state = WorkspaceState.seed()
        let store = IdeaForgeStore(state: state, repository: repository)

        XCTAssertTrue(store.addWorkflowSchemaField(
            templateID: "wf_codex_packet",
            schemaName: "ArchitectureArtifact",
            field: WorkflowSchemaField(
                name: "service_boundaries",
                valueType: "list",
                summary: "External service boundaries that affect architecture."
            )
        ))
        XCTAssertTrue(store.addWorkflowSchemaField(
            templateID: "wf_codex_packet",
            schemaName: "ArchitectureArtifact",
            field: WorkflowSchemaField(
                name: "data_contracts",
                valueType: "list",
                summary: "Data contracts and ownership boundaries."
            )
        ))

        XCTAssertTrue(store.updateWorkflowSchemaField(
            templateID: "wf_codex_packet",
            schemaName: "ArchitectureArtifact",
            fieldName: "service_boundaries",
            updatedField: WorkflowSchemaField(
                name: "integration_boundaries",
                valueType: "list",
                summary: "External integrations and service boundaries."
            )
        ))
        XCTAssertFalse(store.updateWorkflowSchemaField(
            templateID: "wf_codex_packet",
            schemaName: "ArchitectureArtifact",
            fieldName: "integration_boundaries",
            updatedField: WorkflowSchemaField(
                name: "data_contracts",
                valueType: "list",
                summary: "Duplicate field names must be rejected."
            )
        ))
        XCTAssertTrue(store.moveWorkflowSchemaField(
            templateID: "wf_codex_packet",
            schemaName: "ArchitectureArtifact",
            fieldName: "data_contracts",
            direction: .up
        ))
        XCTAssertTrue(store.deleteWorkflowSchemaField(
            templateID: "wf_codex_packet",
            schemaName: "ArchitectureArtifact",
            fieldName: "data_contracts"
        ))

        let saved = try XCTUnwrap(try repository.load())
        let savedTemplate = try XCTUnwrap(saved.workflowTemplates.first { $0.id == "wf_codex_packet" })
        let architectureContract = try XCTUnwrap(savedTemplate.schemaContracts.first { $0.name == "ArchitectureArtifact" })
        XCTAssertEqual(
            architectureContract.fields.map(\.name),
            ["decision", "components", "risks", "integration_boundaries"]
        )
        XCTAssertEqual(architectureContract.fields.last?.summary, "External integrations and service boundaries.")

        await store.runWorkflow(templateID: "wf_codex_packet")

        let updatedState = try XCTUnwrap(try repository.load())
        let selected = try XCTUnwrap(updatedState.projects.first { $0.id == updatedState.selectedProjectID })
        let latestRun = try XCTUnwrap(selected.workflowRuns.first)
        let architecture = try XCTUnwrap(selected.artifacts.first { $0.kind == .architecture && $0.sourceWorkflowRunID == latestRun.id })
        let evaluation = try XCTUnwrap(latestRun.evaluation)

        XCTAssertTrue(architecture.markdown.localizedCaseInsensitiveContains("## Integration Boundaries"))
        XCTAssertFalse(architecture.markdown.localizedCaseInsensitiveContains("## Data Contracts"))
        XCTAssertEqual(evaluation.schemaCompletenessScore, 1)
        XCTAssertFalse(evaluation.schemaIssues.contains { $0.contains("ArchitectureArtifact") })
    }

    func testCustomWorkflowTemplateHandlesDuplicateStepUpdatesDeterministically() throws {
        let repository = InMemoryWorkspaceRepository()
        let state = WorkspaceState.seed()
        let store = IdeaForgeStore(state: state, repository: repository)

        let custom = try XCTUnwrap(store.createCustomWorkflowTemplate(
            WorkflowTemplateCustomization(
                baseTemplateID: "wf_codex_packet",
                name: "Duplicate Update Variant",
                summary: "",
                stepUpdates: [
                    WorkflowStepUpdate(
                        stepID: "step_architecture",
                        outputSchemaName: "ArchitectureArtifact",
                        requiresUserReview: false
                    ),
                    WorkflowStepUpdate(
                        stepID: "step_architecture",
                        outputSchemaName: "ArchitectureArtifact",
                        requiresUserReview: true
                    )
                ]
            )
        ))

        let editedStep = try XCTUnwrap(custom.steps.first { $0.id == "step_architecture" })
        XCTAssertEqual(editedStep.outputSchemaName, "ArchitectureArtifact")
        XCTAssertTrue(editedStep.requiresUserReview)
        XCTAssertEqual(editedStep.version, 2)
    }

    func testWorkflowStepEditorPersistsValidatedStepChanges() throws {
        let repository = InMemoryWorkspaceRepository()
        let state = WorkspaceState.seed()
        let store = IdeaForgeStore(state: state, repository: repository)

        XCTAssertFalse(store.updateWorkflowStep(
            templateID: "wf_codex_packet",
            stepID: "step_architecture",
            update: WorkflowStepUpdate(
                stepID: "step_architecture",
                name: "Architecture decision",
                inputKeys: ["prd"],
                outputSchemaName: "ArchitectureArtifact",
                requiresUserReview: true,
                modelPolicy: .best
            )
        ))

        XCTAssertTrue(store.updateWorkflowStep(
            templateID: "wf_codex_packet",
            stepID: "step_architecture",
            update: WorkflowStepUpdate(
                stepID: "step_architecture",
                name: "Architecture decision",
                inputKeys: ["prd", "constraints", "platforms", "security_notes"],
                outputSchemaName: "ArchitectureArtifact",
                requiresUserReview: false,
                modelPolicy: .balanced
            )
        ))

        let saved = try XCTUnwrap(try repository.load())
        let savedTemplate = try XCTUnwrap(saved.workflowTemplates.first { $0.id == "wf_codex_packet" })
        let editedStep = try XCTUnwrap(savedTemplate.steps.first { $0.id == "step_architecture" })

        XCTAssertEqual(editedStep.name, "Architecture decision")
        XCTAssertEqual(editedStep.inputKeys, ["prd", "constraints", "platforms", "security_notes"])
        XCTAssertEqual(editedStep.outputSchemaName, "ArchitectureArtifact")
        XCTAssertFalse(editedStep.requiresUserReview)
        XCTAssertEqual(editedStep.modelPolicy, .balanced)
        XCTAssertEqual(editedStep.version, 2)
        XCTAssertEqual(savedTemplate.costEstimate.reviewGateCount, 1)
        XCTAssertEqual(savedTemplate.costEstimate.modelPolicyUnits, 4)
    }

    func testWorkflowStepEditorPersistsPromptBodyChanges() throws {
        let repository = InMemoryWorkspaceRepository()
        let state = WorkspaceState.seed()
        let store = IdeaForgeStore(state: state, repository: repository)

        XCTAssertFalse(store.updateWorkflowStep(
            templateID: "wf_prd",
            stepID: "step_prd",
            update: WorkflowStepUpdate(
                stepID: "step_prd",
                promptBody: "   "
            )
        ))
        XCTAssertEqual(store.lastErrorMessage, "Workflow step prompt body is required.")

        let promptBody = """
        Create a production PRD from {personas}, {requirements}, and {edge_cases}.

        Include success metrics, release blockers, and review notes for Codex handoff.
        """

        XCTAssertTrue(store.updateWorkflowStep(
            templateID: "wf_prd",
            stepID: "step_prd",
            update: WorkflowStepUpdate(
                stepID: "step_prd",
                promptBody: promptBody
            )
        ))

        let saved = try XCTUnwrap(try repository.load())
        let savedTemplate = try XCTUnwrap(saved.workflowTemplates.first { $0.id == "wf_prd" })
        let editedStep = try XCTUnwrap(savedTemplate.steps.first { $0.id == "step_prd" })

        XCTAssertEqual(editedStep.promptBody, promptBody)
        XCTAssertEqual(editedStep.version, 2)
        XCTAssertTrue(editedStep.promptBody.contains("{requirements}"))
    }

    func testWorkflowVariableEditorPersistsValidatedVariables() throws {
        let repository = InMemoryWorkspaceRepository()
        let state = WorkspaceState.seed()
        let store = IdeaForgeStore(state: state, repository: repository)

        XCTAssertFalse(store.addWorkflowVariable(
            templateID: "wf_prd",
            variable: WorkflowVariable(
                key: "release gate",
                value: "No App Store release before signing proof.",
                summary: "Release policy"
            )
        ))
        XCTAssertEqual(store.lastErrorMessage, "Workflow variable keys must use letters, numbers, and underscores.")

        XCTAssertTrue(store.addWorkflowVariable(
            templateID: "wf_prd",
            variable: WorkflowVariable(
                key: "release_gate",
                value: "No App Store release before signing proof.",
                summary: "Release policy"
            )
        ))
        XCTAssertFalse(store.addWorkflowVariable(
            templateID: "wf_prd",
            variable: WorkflowVariable(
                key: "release_gate",
                value: "Duplicate",
                summary: "Duplicate"
            )
        ))
        XCTAssertEqual(store.lastErrorMessage, "Workflow variable already exists.")

        XCTAssertTrue(store.updateWorkflowVariable(
            templateID: "wf_prd",
            variableKey: "release_gate",
            variable: WorkflowVariable(
                key: "launch_gate",
                value: "Ship only after device smoke and signing proof.",
                summary: "Launch readiness policy"
            )
        ))

        var saved = try XCTUnwrap(try repository.load())
        var savedTemplate = try XCTUnwrap(saved.workflowTemplates.first { $0.id == "wf_prd" })
        let savedVariable = try XCTUnwrap(savedTemplate.variables.first)

        XCTAssertEqual(savedTemplate.variables.count, 1)
        XCTAssertEqual(savedVariable.key, "launch_gate")
        XCTAssertEqual(savedVariable.value, "Ship only after device smoke and signing proof.")
        XCTAssertEqual(savedVariable.summary, "Launch readiness policy")

        XCTAssertTrue(store.deleteWorkflowVariable(
            templateID: "wf_prd",
            variableKey: "launch_gate"
        ))

        saved = try XCTUnwrap(try repository.load())
        savedTemplate = try XCTUnwrap(saved.workflowTemplates.first { $0.id == "wf_prd" })

        XCTAssertEqual(savedTemplate.variables, [])
    }

    func testCustomWorkflowTemplateValidationRejectsUnknownStepsAndBlankSchemas() throws {
        let repository = InMemoryWorkspaceRepository()
        let state = WorkspaceState.seed()
        let store = IdeaForgeStore(state: state, repository: repository)
        let customization = WorkflowTemplateCustomization(
            baseTemplateID: "wf_codex_packet",
            name: "Invalid Variant",
            summary: "Should not be saved.",
            stepUpdates: [
                WorkflowStepUpdate(
                    stepID: "step_missing",
                    outputSchemaName: "MissingStepSchema"
                ),
                WorkflowStepUpdate(
                    stepID: "step_architecture",
                    outputSchemaName: "   "
                )
            ]
        )

        let validation = store.validateWorkflowTemplateCustomization(customization)

        XCTAssertFalse(validation.canCreate)
        XCTAssertEqual(validation.errors.count, 2)
        XCTAssertTrue(validation.errors.contains("Unknown workflow step: step_missing."))
        XCTAssertTrue(validation.errors.contains("Step step_architecture must keep a non-empty output schema."))
        XCTAssertNil(store.createCustomWorkflowTemplate(customization))
        XCTAssertEqual(store.workflowTemplates.count, state.workflowTemplates.count)
    }

    func testCustomWorkflowTemplateValidationRejectsUnregisteredSchemaContracts() throws {
        let repository = InMemoryWorkspaceRepository()
        let state = WorkspaceState.seed()
        let store = IdeaForgeStore(state: state, repository: repository)
        let customization = WorkflowTemplateCustomization(
            baseTemplateID: "wf_codex_packet",
            name: "Unregistered Schema Variant",
            summary: "Should not be saved.",
            stepUpdates: [
                WorkflowStepUpdate(
                    stepID: "step_architecture",
                    outputSchemaName: "UnregisteredArchitectureSchema"
                )
            ]
        )

        let validation = store.validateWorkflowTemplateCustomization(customization)

        XCTAssertFalse(validation.canCreate)
        XCTAssertTrue(validation.errors.contains("Workflow schema contract missing: UnregisteredArchitectureSchema."))
        XCTAssertNil(store.createCustomWorkflowTemplate(customization))
        XCTAssertEqual(store.workflowTemplates.count, state.workflowTemplates.count)
    }

    func testCustomWorkflowTemplateValidationRejectsMissingSchemaInputs() throws {
        let repository = InMemoryWorkspaceRepository()
        let state = WorkspaceState.seed()
        let store = IdeaForgeStore(state: state, repository: repository)
        let customization = WorkflowTemplateCustomization(
            baseTemplateID: "wf_codex_packet",
            name: "Incomplete Schema Inputs",
            summary: "Should not be saved.",
            stepUpdates: [
                WorkflowStepUpdate(
                    stepID: "step_architecture",
                    inputKeys: ["prd"],
                    outputSchemaName: "ArchitectureArtifact"
                )
            ]
        )

        let validation = store.validateWorkflowTemplateCustomization(customization)

        XCTAssertFalse(validation.canCreate)
        XCTAssertTrue(validation.errors.contains("Step step_architecture missing schema inputs: constraints, platforms."))
        XCTAssertNil(store.createCustomWorkflowTemplate(customization))
        XCTAssertEqual(store.workflowTemplates.count, state.workflowTemplates.count)
    }

    func testCustomWorkflowTemplateValidationRejectsDuplicateSchemaFields() throws {
        let repository = InMemoryWorkspaceRepository()
        let state = WorkspaceState.seed()
        let store = IdeaForgeStore(state: state, repository: repository)
        let customization = WorkflowTemplateCustomization(
            baseTemplateID: "wf_codex_packet",
            name: "Duplicate Field Variant",
            summary: "Should not be saved.",
            stepUpdates: [
                WorkflowStepUpdate(
                    stepID: "step_architecture",
                    outputSchemaName: "FounderArchitectureReviewSchema"
                )
            ],
            schemaContracts: [
                WorkflowSchemaContract(
                    name: "FounderArchitectureReviewSchema",
                    requiredInputKeys: ["prd", "constraints", "platforms"],
                    outputKind: .architecture,
                    summary: "Founder-facing architecture review schema.",
                    fields: [
                        WorkflowSchemaField(name: "decision", valueType: "string", summary: "Recommendation."),
                        WorkflowSchemaField(name: "decision", valueType: "string", summary: "Duplicate recommendation.")
                    ]
                )
            ]
        )

        let validation = store.validateWorkflowTemplateCustomization(customization)

        XCTAssertFalse(validation.canCreate)
        XCTAssertTrue(validation.errors.contains("Workflow schema FounderArchitectureReviewSchema has duplicate fields: decision."))
        XCTAssertNil(store.createCustomWorkflowTemplate(customization))
        XCTAssertEqual(store.workflowTemplates.count, state.workflowTemplates.count)
    }

    func testWorkflowTemplateValidationIncludesCostEstimateForReviewVariant() throws {
        let repository = InMemoryWorkspaceRepository()
        let state = WorkspaceState.seed()
        let store = IdeaForgeStore(state: state, repository: repository)

        let validation = store.validateWorkflowTemplateCustomization(
            WorkflowTemplateCustomization(
                baseTemplateID: "wf_codex_packet",
                name: "High Review Packet",
                summary: "Review-gated high quality variant.",
                stepUpdates: [
                    WorkflowStepUpdate(
                        stepID: "step_architecture",
                        requiresUserReview: true,
                        modelPolicy: .best
                    ),
                    WorkflowStepUpdate(
                        stepID: "step_codex_tasks",
                        requiresUserReview: true,
                        modelPolicy: .best
                    )
                ]
            )
        )

        XCTAssertTrue(validation.canCreate)
        XCTAssertEqual(validation.costEstimate.stepCount, 2)
        XCTAssertEqual(validation.costEstimate.reviewGateCount, 2)
        XCTAssertEqual(validation.costEstimate.externalModelStepCount, 2)
        XCTAssertEqual(validation.costEstimate.modelPolicyUnits, 8)
    }

    func testDefaultWorkflowTemplateCostEstimateSummarizesModelAndReviewLoad() throws {
        let template = try XCTUnwrap(DefaultWorkflows.templates.first { $0.id == "wf_codex_packet" })

        XCTAssertEqual(template.costEstimate.stepCount, 2)
        XCTAssertEqual(template.costEstimate.reviewGateCount, 2)
        XCTAssertEqual(template.costEstimate.externalModelStepCount, 2)
        XCTAssertEqual(template.costEstimate.modelPolicyUnits, 6)
    }

    func testDefaultWorkflowSchemaContractsExposeRequiredFieldsForPreview() throws {
        let architecture = try XCTUnwrap(DefaultWorkflows.schemaContracts.first { $0.name == "ArchitectureArtifact" })

        XCTAssertEqual(
            architecture.fields.filter(\.isRequired).map(\.name),
            ["decision", "components", "risks"]
        )
        XCTAssertEqual(architecture.fields.map(\.valueType), ["string", "list", "list"])
        XCTAssertTrue(architecture.fields.allSatisfy { !$0.summary.isEmpty })
    }

    func testPacketFileSystemWriterWritesPacketAndManifest() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "IdeaForgeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = SampleData.ideaForgeProject
        let packet = EngineeringPacketBuilder.packet(for: project)
        let result = try PacketFileSystemWriter(rootDirectory: root).write(
            packet: packet,
            for: project,
            exportedAt: SampleData.now
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.directoryURL.appending(path: "project-context.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.directoryURL.appending(path: "tasks/001-bootstrap-native-apple-project.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.directoryURL.appending(path: "manifest.json").path))
        XCTAssertEqual(result.manifest.projectID, project.id)
        XCTAssertEqual(result.manifest.files, packet.files.map(\.path))
    }

    func testPacketFileSystemWriterRejectsUnsafePaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "IdeaForgeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let packet = EngineeringPacket(files: [
            PacketFile(path: "../escape.md", contents: "nope")
        ])

        XCTAssertThrowsError(
            try PacketFileSystemWriter(rootDirectory: root).write(
                packet: packet,
                for: SampleData.ideaForgeProject,
                exportedAt: SampleData.now
            )
        ) { error in
            XCTAssertEqual(error as? PacketExportError, .unsafePath("../escape.md"))
        }
    }

    @MainActor
    func testExportCodexPacketWritesFilesAndRecordsArtifact() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "IdeaForgeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = InMemoryWorkspaceRepository()
        let store = IdeaForgeStore(state: WorkspaceState.seed(), repository: repository)
        let services = IdeaForgeServices(
            transcription: LocalTranscriptionService(),
            workflow: LocalWorkflowExecutionService(),
            syncQueue: LocalSyncQueueService(),
            export: LocalExportService(exportRoot: root)
        )

        await store.exportCodexPacket(services: services)

        let exportURL = try XCTUnwrap(store.lastExportedPacketURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportURL.appending(path: "manifest.json").path))
        let saved = try XCTUnwrap(try repository.load())
        let selected = try XCTUnwrap(saved.projects.first { $0.id == saved.selectedProjectID })
        XCTAssertTrue(selected.artifacts.contains { artifact in
            artifact.title == "Exported Codex Packet" && artifact.markdown.contains(exportURL.path)
        })
    }
}

private struct WorkflowPromptRegressionFixture: Decodable {
    var id: String
    var templateID: String
    var projectID: String
    var artifacts: [Artifact]
}

private extension IdeaForgeCoreTests {
    static func loadWorkflowPromptRegressionFixtures() throws -> [WorkflowPromptRegressionFixture] {
        let url = Bundle.module.url(
            forResource: "workflow_prompt_regressions",
            withExtension: "json",
            subdirectory: "Fixtures"
        ) ?? Bundle.module.url(
            forResource: "workflow_prompt_regressions",
            withExtension: "json"
        )
        let fixtureURL = try XCTUnwrap(url)
        let data = try Data(contentsOf: fixtureURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([WorkflowPromptRegressionFixture].self, from: data)
    }
}

private struct SucceedingUploadClient: AudioUploadClient {
    var objectKey: String

    func upload(job: UploadJob) async throws -> UploadReceipt {
        UploadReceipt(recordingID: job.recordingID, objectKey: objectKey)
    }
}

private struct FailingUploadClient: AudioUploadClient {
    func upload(job: UploadJob) async throws -> UploadReceipt {
        throw UploadClientError.uploadFailed("offline")
    }
}

private struct URLErrorUploadClient: AudioUploadClient {
    var code: URLError.Code

    func upload(job: UploadJob) async throws -> UploadReceipt {
        throw URLError(code)
    }
}

private actor SuspendedFirstUploadClient: AudioUploadClient {
    private var attemptedIDs: [String] = []
    private var firstUploadStarted = false
    private var firstUploadReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func upload(job: UploadJob) async throws -> UploadReceipt {
        attemptedIDs.append(job.recordingID)
        if attemptedIDs.count == 1 {
            firstUploadStarted = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
            if !firstUploadReleased {
                await withCheckedContinuation { continuation in
                    releaseWaiter = continuation
                }
            }
        }
        return UploadReceipt(
            recordingID: job.recordingID,
            objectKey: "audio/\(job.ideaProjectID)/\(job.recordingID).m4a"
        )
    }

    func waitUntilFirstUploadStarts() async {
        guard !firstUploadStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func resumeFirstUpload() {
        firstUploadReleased = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func attemptedRecordingIDs() -> [String] {
        attemptedIDs
    }
}

private actor UploadPassRecorder {
    private var counts: [String: Int] = [:]

    func record(_ entryPoint: String) {
        counts[entryPoint, default: 0] += 1
    }

    func count(for entryPoint: String) -> Int {
        counts[entryPoint, default: 0]
    }
}

private final class ObservingWorkspaceRepository: WorkspaceRepository, @unchecked Sendable {
    private var state: WorkspaceState?
    var willSave: ((WorkspaceState) -> Void)?

    init(state: WorkspaceState?) {
        self.state = state
    }

    func load() throws -> WorkspaceState? {
        state
    }

    func save(_ state: WorkspaceState) throws {
        willSave?(state)
        self.state = state
    }
}

private final class ThrowingWorkspaceRepository: WorkspaceRepository, @unchecked Sendable {
    private let state: WorkspaceState?

    init(state: WorkspaceState?) {
        self.state = state
    }

    func load() throws -> WorkspaceState? {
        state
    }

    func save(_ state: WorkspaceState) throws {
        throw WorkspaceRepositoryError.unwritableState
    }
}

private final class UnreadableWorkspaceRepository: WorkspaceRepository, @unchecked Sendable {
    private(set) var saveCallCount = 0

    func load() throws -> WorkspaceState? {
        throw WorkspaceRepositoryError.unreadableState
    }

    func save(_ state: WorkspaceState) throws {
        saveCallCount += 1
    }
}

private struct FailedUploadFixture {
    var state: WorkspaceState
    var repository: InMemoryWorkspaceRepository
    var recordingID: String
    var localAudioPath: String
    var now: Date
    var fileManager: FileManager
    var directory: URL
    var audioURL: URL
    var audioData: Data

    static func make(source: IdeaSource) throws -> FailedUploadFixture {
        let now = Date(timeIntervalSince1970: 3_000)
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let audioURL = directory.appending(path: "retained.m4a")
        let audioData = Data("retained audio".utf8)
        try audioData.write(to: audioURL)

        var state = SampleData.store().workspaceState(now: now)
        state.projects[0].source = source
        state.projects[0].recordings[0].deviceName = source == .watch ? "Apple Watch" : "iPhone"
        state.projects[0].recordings[0].localAudioPath = audioURL.path
        state.projects[0].recordings[0].localFileStatus = .failed
        state.projects[0].recordings[0].syncStatus = .failed
        let recording = state.projects[0].recordings[0]
        state.uploadJobs = [
            UploadJob(
                id: "upload_\(recording.id)",
                recordingID: recording.id,
                ideaProjectID: recording.ideaProjectID,
                localAudioPath: audioURL.path,
                status: .permanentlyFailed,
                attemptCount: UploadQueuePolicy.maximumAttempts,
                nextAttemptAt: now,
                lastErrorMessage: "Server unavailable",
                createdAt: now,
                updatedAt: now
            )
        ]
        state.syncHealth.failingItems = 1
        state.syncHealth.queuedUploads = 0
        let repository = InMemoryWorkspaceRepository(state: state)
        return FailedUploadFixture(
            state: state,
            repository: repository,
            recordingID: recording.id,
            localAudioPath: audioURL.path,
            now: now,
            fileManager: fileManager,
            directory: directory,
            audioURL: audioURL,
            audioData: audioData
        )
    }
}

private func deletionRecording(
    id: String,
    localFileStatus: RecordingFileStatus,
    syncStatus: SyncStatus,
    localAudioPath: String?,
    audioObjectKey: String? = nil
) -> Recording {
    Recording(
        id: id,
        ideaProjectID: "idea_delete",
        deviceName: "iPhone",
        durationSeconds: 30,
        localFileStatus: localFileStatus,
        syncStatus: syncStatus,
        localAudioPath: localAudioPath,
        audioObjectKey: audioObjectKey,
        languageHint: "en-US",
        createdAt: SampleData.now,
        markerOffsets: []
    )
}

private func deletionWorkflowRun(
    id: String,
    status: WorkflowRunStatus,
    nextRetryAt: Date? = nil
) -> WorkflowRun {
    WorkflowRun(
        id: id,
        templateID: "wf_delete",
        templateName: "Deletion Safety",
        status: status,
        stepRuns: [
            StepRun(
                id: "step_\(id)",
                stepID: "step_delete",
                stepName: "Deletion step",
                status: status,
                outputArtifactIDs: [],
                startedAt: SampleData.now,
                completedAt: status == .running ? nil : SampleData.now
            )
        ],
        artifactIDs: [],
        startedAt: SampleData.now,
        completedAt: status == .running ? nil : SampleData.now,
        errorMessage: status == .failed ? "Provider failed." : nil,
        nextRetryAt: nextRetryAt
    )
}

private func deletionSafetyProject(
    id: String = "idea_delete",
    title: String = "Deletion Safety",
    recordings: [Recording] = [],
    workflowRuns: [WorkflowRun] = []
) -> IdeaProject {
    IdeaProject(
        id: id,
        title: title,
        status: .readyForBuild,
        source: .mac,
        createdAt: SampleData.now,
        updatedAt: SampleData.now,
        summary: "Safe deletion fixture.",
        tags: [.appIdea],
        score: IdeaScore(confidence: 0.7, completeness: 0.8, risk: 0.2),
        transcript: Transcript(cleanText: "Safe deletion fixture.", segments: [], unclearFragments: []),
        recordings: recordings.map { recording in
            var updated = recording
            updated.ideaProjectID = id
            return updated
        },
        questions: [],
        artifacts: [],
        assumptions: [],
        validationExperiments: [],
        codexTasks: [],
        workflowRuns: workflowRuns
    )
}

private struct FailingWorkflowExecutionService: WorkflowExecutionService {
    func run(template: WorkflowTemplate, project: IdeaProject) async throws -> [Artifact] {
        throw NSError(domain: "IdeaForgeTests", code: 1)
    }
}

private struct ProviderFailingWorkflowExecutionService: WorkflowExecutionService {
    func run(template: WorkflowTemplate, project: IdeaProject) async throws -> [Artifact] {
        throw BackendAIError.providerFailure(
            BackendAIProviderFailure(
                statusCode: 429,
                code: "rate_limit_exceeded",
                isRetryable: true
            )
        )
    }
}

private actor BlockingWorkflowExecutionService: WorkflowExecutionService {
    private var hasStarted = false
    private var isReleased = false
    private var count = 0
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func run(template: WorkflowTemplate, project: IdeaProject) async throws -> [Artifact] {
        count += 1
        hasStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }

        if !isReleased {
            await withCheckedContinuation { continuation in
                releaseWaiter = continuation
            }
        }
        return try await LocalWorkflowExecutionService().run(template: template, project: project)
    }

    func waitUntilStarted() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func executionCount() -> Int {
        count
    }
}

private struct SucceedingTranscriptionService: TranscriptionService {
    var transcript: Transcript

    func transcript(for recording: Recording, hint: String) async throws -> Transcript {
        transcript
    }
}

private struct FailingTranscriptionService: TranscriptionService {
    var error: Error

    func transcript(for recording: Recording, hint: String) async throws -> Transcript {
        throw error
    }
}

private struct ContractViolatingTranscriptionService: TranscriptionService {
    var issues: [String]

    func transcript(for recording: Recording, hint: String) async throws -> Transcript {
        throw BackendAIError.contractViolation(issues)
    }
}

private struct StubSpeechAuthorizationClient: LocalSpeechAuthorizationChecking {
    var status: LocalSpeechAuthorizationStatus

    func requestSpeechRecognitionAuthorization() async -> LocalSpeechAuthorizationStatus {
        status
    }
}

private struct StubSpeechAudioTranscriber: LocalSpeechAudioTranscribing {
    var text: String

    func transcribeAudio(at url: URL, localeIdentifier: String) async throws -> String {
        text
    }
}

private struct NeverReturningSpeechAudioTranscriber: LocalSpeechAudioTranscribing {
    func transcribeAudio(at url: URL, localeIdentifier: String) async throws -> String {
        try await Task.sleep(nanoseconds: UInt64.max)
        return "unreachable"
    }
}

private func speechTestRecording(
    localAudioPath: String?,
    durationSeconds: Int = 8,
    markerOffsets: [Int] = [],
    languageHint: String = "en"
) -> Recording {
    Recording(
        id: "rec_speech_test",
        ideaProjectID: "idea_speech_test",
        deviceName: "iPhone",
        durationSeconds: durationSeconds,
        localFileStatus: .available,
        syncStatus: .uploaded,
        localAudioPath: localAudioPath,
        audioObjectKey: "objects/idea_speech_test/rec_speech_test.m4a",
        languageHint: languageHint,
        createdAt: Date(timeIntervalSince1970: 1_800_000_000),
        markerOffsets: markerOffsets
    )
}

private func makeTemporarySpeechAudioFile() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "IdeaForgeSpeechTests", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "\(UUID().uuidString).m4a")
    try Data([0x00, 0x01, 0x02]).write(to: url)
    return url
}

private struct BackendWorkflowTestResponse: Encodable {
    var artifacts: [Artifact]
}

private struct BackendWorkflowJobTestResponse: Encodable {
    var jobID: String
    var status: String
    var artifacts: [Artifact]?
    var code: String?
    var retryable: Bool?
}

private struct BackendTranscriptionJobTestResponse: Encodable {
    var jobID: String
    var status: String
    var transcript: Transcript?
    var code: String?
    var retryable: Bool?
}

private struct BackendAudioObjectMetadataTestResponse: Encodable {
    var objectKey: String
    var recordingID: String
    var ideaProjectID: String
    var byteCount: Int
    var contentType: String
    var isAvailable: Bool
}

private func backendAudioObjectMetadataResponse(
    objectKey: String,
    recordingID: String,
    ideaProjectID: String,
    byteCount: Int = 2048,
    contentType: String = "audio/mp4",
    isAvailable: Bool = true
) throws -> HTTPTestResponse {
    HTTPTestResponse(
        data: try JSONEncoder().encode(
            BackendAudioObjectMetadataTestResponse(
                objectKey: objectKey,
                recordingID: recordingID,
                ideaProjectID: ideaProjectID,
                byteCount: byteCount,
                contentType: contentType,
                isAvailable: isAvailable
            )
        ),
        statusCode: 200
    )
}

private struct HTTPTestResponse: Sendable {
    var data: Data
    var statusCode: Int
}

private actor CapturingHTTPUploadTransport: HTTPDataTransport {
    private var request: URLRequest?
    private var sourceURL: URL?
    private var body: Data?
    private let responseData: Data
    private let statusCode: Int

    init(responseData: Data, statusCode: Int) {
        self.responseData = responseData
        self.statusCode = statusCode
    }

    func uploadFile(for request: URLRequest, from sourceURL: URL) async throws -> (Data, HTTPURLResponse) {
        self.request = request
        self.sourceURL = sourceURL
        body = try Data(contentsOf: sourceURL)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (responseData, response)
    }

    func capturedRequest() -> (request: URLRequest?, sourceURL: URL?, body: Data?) {
        (request, sourceURL, body)
    }
}

private actor CapturingHTTPRequestTransport: HTTPRequestTransport {
    private var request: URLRequest?
    private var body: Data?
    private let responseData: Data
    private let statusCode: Int

    init(responseData: Data, statusCode: Int) {
        self.responseData = responseData
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        self.request = request
        self.body = request.httpBody
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (responseData, response)
    }

    func capturedRequest() -> URLRequest? {
        request
    }

    func capturedBody() -> Data? {
        body
    }
}

private actor SequencedHTTPRequestTransport: HTTPRequestTransport {
    private var requests: [URLRequest] = []
    private var responses: [HTTPTestResponse]

    init(responses: [HTTPTestResponse]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty else {
            throw NSError(domain: "IdeaForgeTests", code: 2)
        }
        let next = responses.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: next.statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (next.data, response)
    }

    func capturedRequests() -> [URLRequest] {
        requests
    }
}

private actor MutatingSequencedHTTPRequestTransport: HTTPRequestTransport {
    private var requests: [URLRequest] = []
    private var responses: [HTTPTestResponse]
    private var didMutate = false
    private let mutation: @MainActor @Sendable () -> Void

    init(
        responses: [HTTPTestResponse],
        mutation: @escaping @MainActor @Sendable () -> Void
    ) {
        self.responses = responses
        self.mutation = mutation
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if !didMutate {
            didMutate = true
            await mutation()
        }
        guard !responses.isEmpty else {
            throw NSError(domain: "IdeaForgeTests", code: 3)
        }
        let next = responses.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: next.statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (next.data, response)
    }

    func capturedRequests() -> [URLRequest] {
        requests
    }
}

private struct MutatingSyncQueueService: SyncQueueService {
    var mutation: @MainActor @Sendable () -> Void

    init(mutation: @escaping @MainActor @Sendable () -> Void) {
        self.mutation = mutation
    }

    func enqueue(recording _: Recording) async throws -> SyncStatus {
        await mutation()
        return .pending
    }
}
