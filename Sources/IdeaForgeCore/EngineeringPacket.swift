import Foundation

public struct EngineeringPacket: Equatable, Sendable {
    public var files: [PacketFile]

    public init(files: [PacketFile]) {
        self.files = files
    }
}

public struct PacketFile: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public var path: String
    public var contents: String

    public init(path: String, contents: String) {
        self.path = path
        self.contents = contents
    }
}

public struct CodexHandoffReview: Equatable, Sendable {
    public var fileCount: Int
    public var taskCount: Int
    public var blockingQuestionCount: Int
    public var hasApprovalBoundary: Bool
    public var hasAcceptanceTests: Bool
    public var hasCodexInstructions: Bool
    public var hasSecurityNotes: Bool
    public var blockers: [String]

    public var isReadyForExportOnlyHandoff: Bool {
        blockers.isEmpty
    }

    public init(
        fileCount: Int,
        taskCount: Int,
        blockingQuestionCount: Int,
        hasApprovalBoundary: Bool,
        hasAcceptanceTests: Bool,
        hasCodexInstructions: Bool,
        hasSecurityNotes: Bool,
        blockers: [String]
    ) {
        self.fileCount = fileCount
        self.taskCount = taskCount
        self.blockingQuestionCount = blockingQuestionCount
        self.hasApprovalBoundary = hasApprovalBoundary
        self.hasAcceptanceTests = hasAcceptanceTests
        self.hasCodexInstructions = hasCodexInstructions
        self.hasSecurityNotes = hasSecurityNotes
        self.blockers = blockers
    }
}

public struct PacketExportManifest: Codable, Equatable, Sendable {
    public var projectID: String
    public var projectTitle: String
    public var exportedAt: Date
    public var files: [String]

    public init(projectID: String, projectTitle: String, exportedAt: Date, files: [String]) {
        self.projectID = projectID
        self.projectTitle = projectTitle
        self.exportedAt = exportedAt
        self.files = files
    }
}

public struct PacketExportResult: Equatable, Sendable {
    public var directoryURL: URL
    public var manifest: PacketExportManifest
    public var files: [PacketFile]

    public init(directoryURL: URL, manifest: PacketExportManifest, files: [PacketFile]) {
        self.directoryURL = directoryURL
        self.manifest = manifest
        self.files = files
    }
}

public enum PacketExportError: Error, Equatable, UserFacingIdeaForgeError {
    case unsafePath(String)
    case storage(StoragePreflightError)
    case writeFailed

    public var userFacingMessage: String {
        switch self {
        case .unsafePath:
            return "Codex packet contains an unsafe file path."
        case .storage(let error):
            return error.userFacingMessage
        case .writeFailed:
            return "Codex packet could not be exported."
        }
    }
}

public struct PacketFileSystemWriter: Sendable {
    public var rootDirectory: URL
    public var storagePreflight: StoragePreflight

    public init(
        rootDirectory: URL,
        storagePreflight: StoragePreflight = .codexPacketExport()
    ) {
        self.rootDirectory = rootDirectory
        self.storagePreflight = storagePreflight
    }

    public func write(
        packet: EngineeringPacket,
        for project: IdeaProject,
        exportedAt: Date = Date()
    ) throws -> PacketExportResult {
        let exportDirectory = rootDirectory
            .appending(path: safeSegment(project.id), directoryHint: .isDirectory)
            .appending(path: String(Int(exportedAt.timeIntervalSince1970)), directoryHint: .isDirectory)
        let manifest = PacketExportManifest(
            projectID: project.id,
            projectTitle: project.title,
            exportedAt: exportedAt,
            files: packet.files.map(\.path)
        )

        do {
            try storagePreflight.validateWritableVolume(
                for: exportDirectory,
                estimatedWriteBytes: estimatedWriteBytes(packet: packet, manifest: manifest)
            )
            try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)

            for file in packet.files {
                let destination = try exportDirectory.appendingSafeRelativePath(file.path)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data(file.contents.utf8).write(to: destination, options: [.atomic])
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let manifestData = try encoder.encode(manifest)
            try manifestData.write(to: exportDirectory.appending(path: "manifest.json"), options: [.atomic])
            return PacketExportResult(directoryURL: exportDirectory, manifest: manifest, files: packet.files)
        } catch let error as PacketExportError {
            throw error
        } catch let error as StoragePreflightError {
            throw PacketExportError.storage(error)
        } catch {
            throw PacketExportError.writeFailed
        }
    }

    private func estimatedWriteBytes(packet: EngineeringPacket, manifest: PacketExportManifest) -> Int64 {
        let packetBytes = packet.files.reduce(Int64(0)) { total, file in
            total + Int64(Data(file.contents.utf8).count)
        }
        let manifestBytes = (try? JSONEncoder().encode(manifest)).map { Int64($0.count) } ?? 8_192
        let filesystemOverhead = Int64((packet.files.count + 1) * 4_096)
        return packetBytes + manifestBytes + filesystemOverhead
    }

    private func safeSegment(_ value: String) -> String {
        let allowed = value.map { character in
            character.isLetter || character.isNumber || character == "_" || character == "-" ? character : "_"
        }
        let segment = String(allowed).trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
        return segment.isEmpty ? "project" : segment
    }
}

public enum EngineeringPacketBuilder {
    public static func packet(for project: IdeaProject) -> EngineeringPacket {
        let taskFiles = project.codexTasks.enumerated().map { index, task in
            PacketFile(
                path: String(format: "tasks/%03d-%@.md", index + 1, taskFileSlug(task.title)),
                contents: """
                # \(task.title)

                ## Acceptance Criteria
                \(task.acceptanceCriteria.map { "- \($0)" }.joined(separator: "\n"))

                ## Test Plan
                \(task.testPlan.map { "- \($0)" }.joined(separator: "\n"))
                """
            )
        }
        let resolvedTaskFiles = taskFiles.isEmpty
            ? [PacketFile(path: "tasks/001-bootstrap-project.md", contents: "# Bootstrap Project\n\nNo task generated yet.")]
            : taskFiles

        return EngineeringPacket(files: [
            PacketFile(path: "project-context.md", contents: projectContext(for: project)),
            PacketFile(path: "product-brief.md", contents: productBrief(for: project)),
            PacketFile(path: "architecture.md", contents: architecture(for: project)),
            PacketFile(path: "security-notes.md", contents: securityNotes)
        ] + resolvedTaskFiles + [
            PacketFile(path: "tests/acceptance-tests.md", contents: acceptanceTests(for: project)),
            PacketFile(path: ".codex/instructions.md", contents: codexInstructions(for: project))
        ])
    }

    private static func taskFileSlug(_ title: String) -> String {
        let slug = title
            .lowercased()
            .map { character in
                character.isLetter || character.isNumber ? character : "-"
            }
        let collapsed = String(slug)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "task" : String(collapsed.prefix(48))
    }

    public static func handoffReview(for project: IdeaProject) -> CodexHandoffReview {
        let packet = packet(for: project)
        let paths = Set(packet.files.map(\.path))
        let combinedContents = packet.files.map(\.contents).joined(separator: "\n")
        let blockingQuestionCount = project.questions.filter { $0.isBlocking && ($0.answer?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }.count
        let hasTaskPlans = !project.codexTasks.isEmpty && project.codexTasks.allSatisfy { task in
            !task.acceptanceCriteria.isEmpty && !task.testPlan.isEmpty
        }
        let hasApprovalBoundary = combinedContents.localizedCaseInsensitiveContains("without operator approval") ||
            combinedContents.localizedCaseInsensitiveContains("without explicit approval")
        let hasAcceptanceTests = paths.contains("tests/acceptance-tests.md")
        let hasCodexInstructions = paths.contains(".codex/instructions.md")
        let hasSecurityNotes = paths.contains("security-notes.md")
        var blockers: [String] = []

        if blockingQuestionCount > 0 {
            let noun = blockingQuestionCount == 1 ? "question" : "questions"
            blockers.append("Answer \(blockingQuestionCount) blocking \(noun) before handoff.")
        }
        if !hasTaskPlans {
            blockers.append("Add Codex tasks with acceptance criteria and test plans.")
        }
        if !hasApprovalBoundary {
            blockers.append("Add explicit approval boundaries before Codex or remote writes.")
        }
        if !hasAcceptanceTests {
            blockers.append("Add acceptance tests to the packet.")
        }
        if !hasCodexInstructions {
            blockers.append("Add Codex instructions to the packet.")
        }
        if !hasSecurityNotes {
            blockers.append("Add security notes to the packet.")
        }

        return CodexHandoffReview(
            fileCount: packet.files.count,
            taskCount: project.codexTasks.count,
            blockingQuestionCount: blockingQuestionCount,
            hasApprovalBoundary: hasApprovalBoundary,
            hasAcceptanceTests: hasAcceptanceTests,
            hasCodexInstructions: hasCodexInstructions,
            hasSecurityNotes: hasSecurityNotes,
            blockers: blockers
        )
    }

    private static func projectContext(for project: IdeaProject) -> String {
        """
        # Project Context

        Title: \(project.title)

        Status: \(project.status.label)

        Source: \(project.source.label)

        Summary:
        \(project.summary)

        Tags: \(project.tags.map(\.label).joined(separator: ", "))
        """
    }

    private static func productBrief(for project: IdeaProject) -> String {
        """
        # Product Brief

        ## Problem
        \(project.assumptions.first?.text ?? "Problem statement needs user review.")

        ## Transcript Summary
        \(project.transcript.cleanText)

        ## Open Questions
        \(project.questions.map { "- \($0.prompt)" }.joined(separator: "\n"))
        """
    }

    private static func architecture(for project: IdeaProject) -> String {
        """
        # Architecture

        ## Decision
        Build local-first Apple clients with explicit backend sync and AI seams.

        ## Components

        - watchOS captures audio and transfers files to the paired iPhone.
        - iPhone owns upload queue, account state, privacy settings, and lightweight review.
        - Backend owns transcription, workflow execution, artifact versions, and integrations.
        - macOS app syncs project state and provides the planning studio.

        ## Risks
        - Physical Watch/iPhone transfer still needs device proof.
        - Cloud AI and backend paths need production credentials, quotas, and privacy gates.
        - App Store signing and release assets remain external blockers.

        Current project score: confidence \(project.score.confidence), completeness \(project.score.completeness), risk \(project.score.risk).
        """
    }

    private static let securityNotes = """
    # Security Notes

    - No API keys belong in client apps.
    - Do not include audio or transcripts in analytics or crash logs.
    - Use Keychain for local credentials.
    - Require explicit user approval before cloud AI, GitHub export, or Codex launcher actions.
    - Prefer signed upload/download URLs and per-user object access control for backend audio storage.
    """

    private static func acceptanceTests(for project: IdeaProject) -> String {
        """
        # Acceptance Tests

        - A user can capture a recording from Watch and see sync status on iPhone.
        - A user can open \(project.title) on Mac and review transcript, questions, workflows, artifacts, and Codex tasks.
        - Export-only Codex packet generation never executes code or writes to a remote service without explicit approval.
        """
    }

    private static func codexInstructions(for project: IdeaProject) -> String {
        """
        # Codex Instructions

        Build the smallest verified slice for \(project.title). Keep source boundaries clear, write focused tests, and do not perform remote writes or run external integrations without operator approval.
        """
    }
}

private extension URL {
    func appendingSafeRelativePath(_ path: String) throws -> URL {
        guard !path.hasPrefix("/") else {
            throw PacketExportError.unsafePath(path)
        }

        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty else {
            throw PacketExportError.unsafePath(path)
        }

        var destination = self
        for component in components {
            guard component != ".", component != "..", !component.isEmpty, !component.contains("\\") else {
                throw PacketExportError.unsafePath(path)
            }
            destination.append(path: component)
        }
        return destination
    }
}
