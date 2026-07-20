import Foundation

public struct IdeaAgentCitation: Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var projectID: String
    public var projectTitle: String
    public var sourceTitle: String
    public var excerpt: String

    public init(
        id: String,
        projectID: String,
        projectTitle: String,
        sourceTitle: String,
        excerpt: String
    ) {
        self.id = id
        self.projectID = projectID
        self.projectTitle = projectTitle
        self.sourceTitle = sourceTitle
        self.excerpt = excerpt
    }
}

public struct IdeaAgentResponse: Equatable, Sendable {
    public var answer: String
    public var citations: [IdeaAgentCitation]
    public var suggestedPrompts: [String]

    public init(
        answer: String,
        citations: [IdeaAgentCitation],
        suggestedPrompts: [String]
    ) {
        self.answer = answer
        self.citations = citations
        self.suggestedPrompts = suggestedPrompts
    }
}

public struct LocalIdeaAgent: Sendable {
    public init() {}

    public func respond(to query: String, projects: [IdeaProject]) -> IdeaAgentResponse {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !projects.isEmpty else {
            return IdeaAgentResponse(
                answer: "There are no local ideas to inspect yet. Record or import an idea first, then ask again.",
                citations: [],
                suggestedPrompts: Self.defaultSuggestedPrompts
            )
        }

        guard !trimmedQuery.isEmpty else {
            return IdeaAgentResponse(
                answer: "Ask about a user, risk, next step, validation plan, transcript detail, or build readiness across your local ideas.",
                citations: [],
                suggestedPrompts: Self.defaultSuggestedPrompts
            )
        }

        let queryTokens = Self.tokens(in: trimmedQuery)
        let chunks = projects.flatMap(Self.chunks(for:))
        let ranked = chunks
            .map { chunk in
                RankedIdeaAgentChunk(chunk: chunk, score: Self.score(chunk, queryTokens: queryTokens))
            }
            .filter { $0.score > 0 }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.chunk.projectUpdatedAt > rhs.chunk.projectUpdatedAt
                }
                return lhs.score > rhs.score
            }

        guard !ranked.isEmpty else {
            return IdeaAgentResponse(
                answer: "I could not find a strong local match for that question. Try asking about first users, open questions, risks, validation, transcript evidence, or build readiness.",
                citations: [],
                suggestedPrompts: Self.defaultSuggestedPrompts
            )
        }

        let selected = Array(ranked.prefix(3).map(\.chunk))
        let citations = selected.enumerated().map { index, chunk in
            IdeaAgentCitation(
                id: "\(chunk.projectID)-\(chunk.sourceTitle)-\(index)",
                projectID: chunk.projectID,
                projectTitle: chunk.projectTitle,
                sourceTitle: chunk.sourceTitle,
                excerpt: chunk.text.truncatedForIdeaAgent(maxLength: 180)
            )
        }

        return IdeaAgentResponse(
            answer: Self.answer(for: trimmedQuery, chunks: selected),
            citations: citations,
            suggestedPrompts: Self.suggestedPrompts(from: projects, citations: citations)
        )
    }

    private static func answer(for query: String, chunks: [IdeaAgentChunk]) -> String {
        let primary = chunks[0]
        let joinedEvidence = chunks
            .map { "- \($0.projectTitle), \($0.sourceTitle): \($0.text.truncatedForIdeaAgent(maxLength: 140))" }
            .joined(separator: "\n")

        return """
        Based on local idea context, the strongest match is \(primary.projectTitle).

        \(primary.text.truncatedForIdeaAgent(maxLength: 220))

        Evidence:
        \(joinedEvidence)

        Next useful move: answer the highest-risk open question or run the validation step tied to this evidence before treating the idea as build-ready.
        """
    }

    private static func score(_ chunk: IdeaAgentChunk, queryTokens: Set<String>) -> Int {
        guard !queryTokens.isEmpty else { return 0 }
        let chunkTokens = tokens(in: "\(chunk.projectTitle) \(chunk.sourceTitle) \(chunk.text)")
        let overlap = queryTokens.intersection(chunkTokens)
        let titleBoost = queryTokens.intersection(tokens(in: chunk.projectTitle)).count * 3
        let sourceBoost = queryTokens.intersection(tokens(in: chunk.sourceTitle)).count
        return overlap.count + titleBoost + sourceBoost
    }

    private static func chunks(for project: IdeaProject) -> [IdeaAgentChunk] {
        var chunks: [IdeaAgentChunk] = [
            IdeaAgentChunk(project: project, sourceTitle: "Summary", text: project.summary),
            IdeaAgentChunk(project: project, sourceTitle: "Transcript", text: project.transcript.cleanText)
        ]

        chunks += project.questions.map { question in
            let status = question.answer?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Unanswered"
            return IdeaAgentChunk(
                project: project,
                sourceTitle: question.isBlocking ? "Blocking Question" : "Question",
                text: "\(question.prompt) Answer: \(status)"
            )
        }

        chunks += project.assumptions.map { assumption in
            IdeaAgentChunk(
                project: project,
                sourceTitle: "Assumption",
                text: "\(assumption.text) Evidence: \(assumption.evidence)"
            )
        }

        chunks += project.validationExperiments.map { experiment in
            IdeaAgentChunk(
                project: project,
                sourceTitle: "Validation",
                text: "\(experiment.title). Metric: \(experiment.metric). Go/no-go: \(experiment.goNoGoCriteria)"
            )
        }

        chunks += project.artifacts.map { artifact in
            IdeaAgentChunk(
                project: project,
                sourceTitle: artifact.title,
                text: artifact.markdown
            )
        }

        return chunks.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private static func suggestedPrompts(from projects: [IdeaProject], citations: [IdeaAgentCitation]) -> [String] {
        if let firstCitation = citations.first {
            return [
                "What is blocking \(firstCitation.projectTitle)?",
                "What should I validate next?",
                "What is the strongest build-ready evidence?"
            ]
        }
        if let firstProject = projects.first {
            return [
                "What is blocking \(firstProject.title)?",
                "What should I validate next?",
                "Which idea is closest to build-ready?"
            ]
        }
        return defaultSuggestedPrompts
    }

    private static let defaultSuggestedPrompts = [
        "Which idea is closest to build-ready?",
        "What should I validate next?",
        "What open question is blocking handoff?"
    ]

    private static func tokens(in text: String) -> Set<String> {
        Set(
            text
                .lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { $0.count >= 3 }
        )
    }
}

private struct RankedIdeaAgentChunk: Sendable {
    var chunk: IdeaAgentChunk
    var score: Int
}

private struct IdeaAgentChunk: Sendable {
    var projectID: String
    var projectTitle: String
    var projectUpdatedAt: Date
    var sourceTitle: String
    var text: String

    init(project: IdeaProject, sourceTitle: String, text: String) {
        projectID = project.id
        projectTitle = project.title
        projectUpdatedAt = project.updatedAt
        self.sourceTitle = sourceTitle
        self.text = text
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }

    func truncatedForIdeaAgent(maxLength: Int) -> String {
        let collapsed = split(whereSeparator: \.isNewline).joined(separator: " ")
        guard collapsed.count > maxLength else { return collapsed }
        let endIndex = collapsed.index(collapsed.startIndex, offsetBy: maxLength)
        return "\(collapsed[..<endIndex])..."
    }
}

