import Foundation

public struct IdeaBriefDocument: Equatable, Sendable {
    public var filename: String
    public var markdown: String

    public init(filename: String, markdown: String) {
        self.filename = filename
        self.markdown = markdown
    }
}

public enum IdeaBriefExportError: Error, Equatable, UserFacingIdeaForgeError {
    case storage(StoragePreflightError)
    case writeFailed

    public var userFacingMessage: String {
        switch self {
        case .storage(let error):
            return error.userFacingMessage
        case .writeFailed:
            return "Idea brief could not be exported."
        }
    }
}

public enum IdeaBriefExporter {
    public static func brief(for project: IdeaProject, exportedAt: Date = Date()) -> IdeaBriefDocument {
        let filename = "\(safeSegment(project.title))-idea-brief.md"
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        return IdeaBriefDocument(
            filename: filename,
            markdown: [
                "# Idea Brief: \(project.title)",
                "",
                "Generated: \(formatter.string(from: exportedAt))",
                "",
                "Status: \(project.status.label)",
                "Source: \(project.source.label)",
                "Tags: \(project.tags.map(\.label).joined(separator: ", "))",
                scoreLine(for: project),
                recordingLine(for: project),
                "",
                "## Summary",
                project.summary,
                "",
                questionsSection(for: project),
                assumptionsSection(for: project),
                validationSection(for: project),
                artifactsSection(for: project),
                codexTasksSection(for: project),
                "",
                "## Privacy Boundary",
                "- This brief excludes local audio file locations, backend object keys, credentials, and raw storage metadata.",
                "- Review this Markdown before sharing it outside the device."
            ].joined(separator: "\n")
        )
    }

    private static func scoreLine(for project: IdeaProject) -> String {
        let confidence = Int((project.score.confidence * 100).rounded())
        let completeness = Int((project.score.completeness * 100).rounded())
        let risk = Int((project.score.risk * 100).rounded())
        return "Score: \(confidence)% confidence, \(completeness)% complete, \(risk)% risk."
    }

    private static func recordingLine(for project: IdeaProject) -> String {
        let uploaded = project.recordings.filter { $0.localFileStatus == .uploaded || $0.syncStatus == .uploaded }.count
        let retained = project.recordings.filter { $0.localFileStatus == .available }.count
        return "Recordings: \(project.recordings.count) total, \(uploaded) uploaded, \(retained) retained locally."
    }

    private static func questionsSection(for project: IdeaProject) -> String {
        let rows = project.questions.map { question in
            let answer = question.answer?.trimmingCharacters(in: .whitespacesAndNewlines)
            let status = question.isBlocking ? "Blocking" : "Optional"
            if let answer, !answer.isEmpty {
                return "- [\(status)] \(question.prompt)\n  Answer: \(answer)"
            }
            return "- [\(status)] \(question.prompt)\n  Answer: Not answered yet."
        }
        return section(title: "Questions", rows: rows, empty: "No follow-up questions are open.")
    }

    private static func assumptionsSection(for project: IdeaProject) -> String {
        let rows = project.assumptions.map { assumption in
            let confidence = Int((assumption.confidence * 100).rounded())
            return "- \(assumption.text) (\(confidence)% confidence)\n  Evidence: \(assumption.evidence)"
        }
        return section(title: "Assumptions", rows: rows, empty: "No assumptions have been captured yet.")
    }

    private static func validationSection(for project: IdeaProject) -> String {
        let rows = project.validationExperiments.map { experiment in
            "- \(experiment.title)\n  Metric: \(experiment.metric)\n  Go/no-go: \(experiment.goNoGoCriteria)"
        }
        return section(title: "Validation", rows: rows, empty: "No validation experiments have been planned yet.")
    }

    private static func artifactsSection(for project: IdeaProject) -> String {
        let rows = project.artifacts.map { artifact in
            "- \(artifact.title) (\(artifact.kind.label), v\(artifact.version))"
        }
        return section(title: "Artifacts", rows: rows, empty: "No generated artifacts are attached yet.")
    }

    private static func codexTasksSection(for project: IdeaProject) -> String {
        let rows = project.codexTasks.map { task in
            "- \(task.title)\n  Acceptance checks: \(task.acceptanceCriteria.count)\n  Test steps: \(task.testPlan.count)"
        }
        return section(title: "Codex Tasks", rows: rows, empty: "No Codex-ready implementation tasks have been prepared yet.")
    }

    private static func section(title: String, rows: [String], empty: String) -> String {
        """
        ## \(title)
        \(rows.isEmpty ? empty : rows.joined(separator: "\n"))

        """
        .trimmingCharacters(in: .newlines)
    }

    private static func safeSegment(_ value: String) -> String {
        let allowed = value.map { character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "-"
        }
        let collapsed = String(allowed)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return collapsed.isEmpty ? "idea" : collapsed
    }
}

public struct IdeaBriefFileWriter: Sendable {
    public var rootDirectory: URL
    public var storagePreflight: StoragePreflight

    public init(
        rootDirectory: URL = FileManager.default.temporaryDirectory,
        storagePreflight: StoragePreflight = .ideaBriefExport()
    ) {
        self.rootDirectory = rootDirectory
        self.storagePreflight = storagePreflight
    }

    public func write(_ brief: IdeaBriefDocument) throws -> URL {
        do {
            try storagePreflight.validateWritableVolume(
                for: rootDirectory,
                estimatedWriteBytes: Int64(Data(brief.markdown.utf8).count)
            )
            try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
            let destination = rootDirectory.appending(path: brief.filename)
            try Data(brief.markdown.utf8).write(to: destination, options: [.atomic])
            return destination
        } catch let error as StoragePreflightError {
            throw IdeaBriefExportError.storage(error)
        } catch {
            throw IdeaBriefExportError.writeFailed
        }
    }
}
