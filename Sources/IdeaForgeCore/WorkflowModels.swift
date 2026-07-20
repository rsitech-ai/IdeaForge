import Foundation

public enum WorkflowStepKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case prompt
    case structuredPrompt
    case research
    case question
    case artifact
    case toolAction
    case reviewGate

    public var id: String { rawValue }
}

public enum ModelPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case fast
    case balanced
    case best
    case local

    public var id: String { rawValue }

    public var estimateUnits: Int {
        switch self {
        case .local: 0
        case .fast: 1
        case .balanced: 2
        case .best: 4
        }
    }
}

public struct WorkflowVariable: Identifiable, Codable, Hashable, Sendable {
    public var id: String { key }
    public var key: String
    public var value: String
    public var summary: String

    public init(key: String, value: String, summary: String) {
        self.key = key
        self.value = value
        self.summary = summary
    }
}

public struct WorkflowTemplate: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var summary: String
    public var outputKinds: [ArtifactKind]
    public var steps: [WorkflowStep]
    public var schemaContracts: [WorkflowSchemaContract]
    public var variables: [WorkflowVariable]

    public var costEstimate: WorkflowTemplateCostEstimate {
        WorkflowTemplateCostEstimate(steps: steps)
    }

    public init(
        id: String,
        name: String,
        summary: String,
        outputKinds: [ArtifactKind],
        steps: [WorkflowStep],
        schemaContracts: [WorkflowSchemaContract] = [],
        variables: [WorkflowVariable] = []
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.outputKinds = outputKinds
        self.steps = steps
        self.schemaContracts = schemaContracts
        self.variables = variables
    }

    public func schemaContract(named name: String) -> WorkflowSchemaContract? {
        schemaContracts.first { $0.name == name }
            ?? DefaultWorkflows.schemaContracts.first { $0.name == name }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case summary
        case outputKinds
        case steps
        case schemaContracts
        case variables
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        summary = try container.decode(String.self, forKey: .summary)
        outputKinds = try container.decode([ArtifactKind].self, forKey: .outputKinds)
        steps = try container.decode([WorkflowStep].self, forKey: .steps)
        schemaContracts = try container.decodeIfPresent([WorkflowSchemaContract].self, forKey: .schemaContracts) ?? []
        variables = try container.decodeIfPresent([WorkflowVariable].self, forKey: .variables) ?? []
    }
}

public struct WorkflowStep: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var kind: WorkflowStepKind
    public var inputKeys: [String]
    public var outputSchemaName: String
    public var promptBody: String
    public var requiresUserReview: Bool
    public var modelPolicy: ModelPolicy
    public var version: Int

    public init(
        id: String,
        name: String,
        kind: WorkflowStepKind,
        inputKeys: [String],
        outputSchemaName: String,
        promptBody: String? = nil,
        requiresUserReview: Bool,
        modelPolicy: ModelPolicy,
        version: Int
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.inputKeys = inputKeys
        self.outputSchemaName = outputSchemaName
        self.promptBody = promptBody ?? Self.defaultPromptBody(
            name: name,
            kind: kind,
            inputKeys: inputKeys,
            outputSchemaName: outputSchemaName
        )
        self.requiresUserReview = requiresUserReview
        self.modelPolicy = modelPolicy
        self.version = version
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case kind
        case inputKeys
        case outputSchemaName
        case promptBody
        case requiresUserReview
        case modelPolicy
        case version
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(WorkflowStepKind.self, forKey: .kind)
        inputKeys = try container.decode([String].self, forKey: .inputKeys)
        outputSchemaName = try container.decode(String.self, forKey: .outputSchemaName)
        promptBody = try container.decodeIfPresent(String.self, forKey: .promptBody)
            ?? Self.defaultPromptBody(
                name: name,
                kind: kind,
                inputKeys: inputKeys,
                outputSchemaName: outputSchemaName
            )
        requiresUserReview = try container.decode(Bool.self, forKey: .requiresUserReview)
        modelPolicy = try container.decode(ModelPolicy.self, forKey: .modelPolicy)
        version = try container.decode(Int.self, forKey: .version)
    }

    public static func defaultPromptBody(
        name: String,
        kind: WorkflowStepKind,
        inputKeys: [String],
        outputSchemaName: String
    ) -> String {
        let inputs = inputKeys.isEmpty ? "the current idea project" : inputKeys.joined(separator: ", ")
        return """
        Execute the \(name) workflow step as a \(kind.rawValue) step.

        Use these inputs: \(inputs).
        Return output that satisfies the \(outputSchemaName) schema.
        Keep the result specific, reviewable, and safe for a local-first IdeaForge workspace.
        """
    }
}

public struct WorkflowStepUpdate: Codable, Hashable, Sendable {
    public var stepID: String
    public var name: String?
    public var inputKeys: [String]?
    public var outputSchemaName: String?
    public var promptBody: String?
    public var requiresUserReview: Bool?
    public var modelPolicy: ModelPolicy?

    public init(
        stepID: String,
        name: String? = nil,
        inputKeys: [String]? = nil,
        outputSchemaName: String? = nil,
        promptBody: String? = nil,
        requiresUserReview: Bool? = nil,
        modelPolicy: ModelPolicy? = nil
    ) {
        self.stepID = stepID
        self.name = name
        self.inputKeys = inputKeys
        self.outputSchemaName = outputSchemaName
        self.promptBody = promptBody
        self.requiresUserReview = requiresUserReview
        self.modelPolicy = modelPolicy
    }
}

public struct WorkflowTemplateCustomization: Codable, Hashable, Sendable {
    public var baseTemplateID: String
    public var name: String
    public var summary: String
    public var stepUpdates: [WorkflowStepUpdate]
    public var schemaContracts: [WorkflowSchemaContract]

    public init(
        baseTemplateID: String,
        name: String,
        summary: String,
        stepUpdates: [WorkflowStepUpdate],
        schemaContracts: [WorkflowSchemaContract] = []
    ) {
        self.baseTemplateID = baseTemplateID
        self.name = name
        self.summary = summary
        self.stepUpdates = stepUpdates
        self.schemaContracts = schemaContracts
    }

}

public struct WorkflowSchemaContract: Identifiable, Codable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var requiredInputKeys: [String]
    public var outputKind: ArtifactKind?
    public var summary: String
    public var fields: [WorkflowSchemaField]

    public init(
        name: String,
        requiredInputKeys: [String],
        outputKind: ArtifactKind? = nil,
        summary: String,
        fields: [WorkflowSchemaField] = []
    ) {
        self.name = name
        self.requiredInputKeys = requiredInputKeys
        self.outputKind = outputKind
        self.summary = summary
        self.fields = fields
    }

    public func reviewVariant(named variantName: String) -> WorkflowSchemaContract {
        let reviewField = WorkflowSchemaField(
            name: "review_notes",
            valueType: "string",
            summary: "Human review notes required before handoff."
        )
        let variantFields = fields.contains { $0.name == reviewField.name }
            ? fields
            : fields + [reviewField]
        return WorkflowSchemaContract(
            name: variantName,
            requiredInputKeys: requiredInputKeys,
            outputKind: outputKind,
            summary: "Review-gated variant of \(name).",
            fields: variantFields
        )
    }
}

public struct WorkflowSchemaField: Identifiable, Codable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var valueType: String
    public var isRequired: Bool
    public var summary: String

    public init(name: String, valueType: String, isRequired: Bool = true, summary: String) {
        self.name = name
        self.valueType = valueType
        self.isRequired = isRequired
        self.summary = summary
    }
}

public enum WorkflowSchemaFieldMoveDirection: String, Codable, CaseIterable, Identifiable, Sendable {
    case up
    case down

    public var id: String { rawValue }
}

public struct WorkflowTemplateCostEstimate: Codable, Hashable, Sendable {
    public var stepCount: Int
    public var reviewGateCount: Int
    public var externalModelStepCount: Int
    public var modelPolicyUnits: Int

    public static let zero = WorkflowTemplateCostEstimate(
        stepCount: 0,
        reviewGateCount: 0,
        externalModelStepCount: 0,
        modelPolicyUnits: 0
    )

    public init(
        stepCount: Int,
        reviewGateCount: Int,
        externalModelStepCount: Int,
        modelPolicyUnits: Int
    ) {
        self.stepCount = stepCount
        self.reviewGateCount = reviewGateCount
        self.externalModelStepCount = externalModelStepCount
        self.modelPolicyUnits = modelPolicyUnits
    }

    public init(steps: [WorkflowStep]) {
        self.init(
            stepCount: steps.count,
            reviewGateCount: steps.filter(\.requiresUserReview).count,
            externalModelStepCount: steps.filter { $0.modelPolicy != .local }.count,
            modelPolicyUnits: steps.reduce(0) { $0 + $1.modelPolicy.estimateUnits }
        )
    }
}

public struct WorkflowTemplateValidation: Codable, Hashable, Sendable {
    public var errors: [String]
    public var warnings: [String]
    public var costEstimate: WorkflowTemplateCostEstimate

    public var canCreate: Bool {
        errors.isEmpty
    }

    public init(
        errors: [String] = [],
        warnings: [String] = [],
        costEstimate: WorkflowTemplateCostEstimate = .zero
    ) {
        self.errors = errors
        self.warnings = warnings
        self.costEstimate = costEstimate
    }
}

public enum WorkflowRunStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case running
    case completed
    case failed

    public var id: String { rawValue }
}

public enum WorkflowEvaluationDecision: String, Codable, CaseIterable, Identifiable, Sendable {
    case ready
    case needsReview
    case blocked

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .ready: "Ready"
        case .needsReview: "Needs Review"
        case .blocked: "Blocked"
        }
    }
}

public enum WorkflowRubricStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case passing
    case warning
    case failing

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .passing: "Passing"
        case .warning: "Warning"
        case .failing: "Failing"
        }
    }
}

public struct WorkflowRubricItem: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var score: Double
    public var status: WorkflowRubricStatus
    public var summary: String

    public init(
        id: String,
        title: String,
        score: Double,
        status: WorkflowRubricStatus,
        summary: String
    ) {
        self.id = id
        self.title = title
        self.score = score
        self.status = status
        self.summary = summary
    }
}

public struct WorkflowRunEvaluation: Codable, Hashable, Sendable {
    public var readinessScore: Double
    public var decision: WorkflowEvaluationDecision
    public var generatedArtifactCount: Int
    public var blockingIssueCount: Int
    public var blockers: [String]
    public var schemaCompletenessScore: Double
    public var schemaIssues: [String]
    public var rubricScore: Double
    public var rubricItems: [WorkflowRubricItem]

    public init(
        readinessScore: Double,
        decision: WorkflowEvaluationDecision,
        generatedArtifactCount: Int,
        blockingIssueCount: Int,
        blockers: [String],
        schemaCompletenessScore: Double = 1,
        schemaIssues: [String] = [],
        rubricScore: Double = 1,
        rubricItems: [WorkflowRubricItem] = []
    ) {
        self.readinessScore = readinessScore
        self.decision = decision
        self.generatedArtifactCount = generatedArtifactCount
        self.blockingIssueCount = blockingIssueCount
        self.blockers = blockers
        self.schemaCompletenessScore = schemaCompletenessScore
        self.schemaIssues = schemaIssues
        self.rubricScore = rubricScore
        self.rubricItems = rubricItems
    }

    private enum CodingKeys: String, CodingKey {
        case readinessScore
        case decision
        case generatedArtifactCount
        case blockingIssueCount
        case blockers
        case schemaCompletenessScore
        case schemaIssues
        case rubricScore
        case rubricItems
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        readinessScore = try container.decode(Double.self, forKey: .readinessScore)
        decision = try container.decode(WorkflowEvaluationDecision.self, forKey: .decision)
        generatedArtifactCount = try container.decode(Int.self, forKey: .generatedArtifactCount)
        blockingIssueCount = try container.decode(Int.self, forKey: .blockingIssueCount)
        blockers = try container.decode([String].self, forKey: .blockers)
        schemaCompletenessScore = try container.decodeIfPresent(Double.self, forKey: .schemaCompletenessScore) ?? 1
        schemaIssues = try container.decodeIfPresent([String].self, forKey: .schemaIssues) ?? []
        rubricScore = try container.decodeIfPresent(Double.self, forKey: .rubricScore) ?? 1
        rubricItems = try container.decodeIfPresent([WorkflowRubricItem].self, forKey: .rubricItems) ?? []
    }
}

public struct WorkflowOutputContractValidation: Equatable, Sendable {
    public var isValid: Bool
    public var issues: [String]
    public var expectedKinds: Set<ArtifactKind>
    public var generatedKinds: Set<ArtifactKind>
    public var schemaCompletenessScore: Double
    public var schemaIssues: [String]
    public var rubricScore: Double
    public var rubricItems: [WorkflowRubricItem]

    public init(
        isValid: Bool,
        issues: [String],
        expectedKinds: Set<ArtifactKind>,
        generatedKinds: Set<ArtifactKind>,
        schemaCompletenessScore: Double,
        schemaIssues: [String],
        rubricScore: Double,
        rubricItems: [WorkflowRubricItem]
    ) {
        self.isValid = isValid
        self.issues = issues
        self.expectedKinds = expectedKinds
        self.generatedKinds = generatedKinds
        self.schemaCompletenessScore = schemaCompletenessScore
        self.schemaIssues = schemaIssues
        self.rubricScore = rubricScore
        self.rubricItems = rubricItems
    }
}

public enum WorkflowOutputContractValidator {
    public static func validate(
        template: WorkflowTemplate,
        project: IdeaProject,
        artifacts: [Artifact]
    ) -> WorkflowOutputContractValidation {
        let generatedKinds = Set(artifacts.map(\.kind))
        let expectedKinds = Set(template.outputKinds)
        let missingKindIssues = missingExpectedArtifactIssues(
            expectedKinds: expectedKinds,
            generatedKinds: generatedKinds
        )
        let schemaCompleteness = schemaCompleteness(template: template, artifacts: artifacts)
        let rubric = rubricEvaluation(template: template, project: project, artifacts: artifacts)
        let issues = missingKindIssues + schemaCompleteness.issues + rubric.issues

        return WorkflowOutputContractValidation(
            isValid: issues.isEmpty,
            issues: issues,
            expectedKinds: expectedKinds,
            generatedKinds: generatedKinds,
            schemaCompletenessScore: schemaCompleteness.score,
            schemaIssues: schemaCompleteness.issues,
            rubricScore: rubric.score,
            rubricItems: rubric.items
        )
    }

    private static func missingExpectedArtifactIssues(
        expectedKinds: Set<ArtifactKind>,
        generatedKinds: Set<ArtifactKind>
    ) -> [String] {
        let missingKinds = expectedKinds.subtracting(generatedKinds)
        guard !missingKinds.isEmpty else { return [] }

        let labels = missingKinds
            .sorted { $0.rawValue < $1.rawValue }
            .map(\.label)
            .joined(separator: ", ")
        return ["Missing expected artifacts: \(labels)."]
    }

    private static func rubricEvaluation(
        template: WorkflowTemplate,
        project: IdeaProject,
        artifacts: [Artifact]
    ) -> (score: Double, items: [WorkflowRubricItem], issues: [String]) {
        let combinedMarkdown = artifacts.map(\.markdown).joined(separator: "\n\n")
        let hasActionPlan = containsAny(
            combinedMarkdown,
            normalizedNeedles: ["tasks", "checks", "acceptance criteria", "next steps", "roadmap"]
        )
        let hasEvidence = !project.assumptions.isEmpty
            || !project.validationExperiments.isEmpty
            || containsAny(combinedMarkdown, normalizedNeedles: ["validation", "evidence", "assumptions"])
        let hasRiskCoverage = containsAny(combinedMarkdown, normalizedNeedles: ["risk", "risks", "boundary", "boundaries", "tradeoffs"])
        let needsHandoffSafety = template.steps.contains { $0.kind == .toolAction }
            || template.outputKinds.contains(.codexTaskBundle)
        let hasHandoffSafety = !needsHandoffSafety
            || containsAny(
                combinedMarkdown,
                normalizedNeedles: ["operator approval", "explicit approval", "review before", "without operator approval"]
            )

        let items = [
            rubricItem(
                id: "actionability",
                title: "Actionability",
                passes: hasActionPlan,
                summary: hasActionPlan
                    ? "Generated artifacts include a concrete action or verification path."
                    : "Generated artifacts need tasks, checks, acceptance criteria, or next steps."
            ),
            rubricItem(
                id: "evidence",
                title: "Evidence",
                passes: hasEvidence,
                summary: hasEvidence
                    ? "Generated artifacts are tied to assumptions, validation, or evidence."
                    : "Generated artifacts need evidence, assumptions, or validation context."
            ),
            rubricItem(
                id: "risk_coverage",
                title: "Risk Coverage",
                passes: hasRiskCoverage,
                summary: hasRiskCoverage
                    ? "Generated artifacts include risk, boundary, or tradeoff coverage."
                    : "Generated artifacts need explicit risk, boundary, or tradeoff coverage."
            ),
            rubricItem(
                id: "handoff_safety",
                title: "Handoff Safety",
                passes: hasHandoffSafety,
                summary: hasHandoffSafety
                    ? "Generated artifacts preserve review or approval boundaries for tool handoff."
                    : "Generated artifacts need explicit approval boundaries before tool handoff."
            )
        ]
        let score = items.isEmpty ? 1 : items.map(\.score).reduce(0, +) / Double(items.count)
        let issues = items
            .filter { $0.status == .failing }
            .map { "AI rubric failed: \($0.title)." }
        return (score, items, issues)
    }

    private static func rubricItem(
        id: String,
        title: String,
        passes: Bool,
        summary: String
    ) -> WorkflowRubricItem {
        WorkflowRubricItem(
            id: id,
            title: title,
            score: passes ? 1 : 0,
            status: passes ? .passing : .failing,
            summary: summary
        )
    }

    private static func containsAny(_ markdown: String, normalizedNeedles: [String]) -> Bool {
        let haystack = markdown.lowercased()
        return normalizedNeedles.contains { haystack.contains($0) }
    }

    private static func schemaCompleteness(
        template: WorkflowTemplate,
        artifacts: [Artifact]
    ) -> (score: Double, issues: [String]) {
        var requiredFieldCount = 0
        var presentFieldCount = 0
        var issues: [String] = []

        for step in template.steps {
            guard let contract = template.schemaContract(named: step.outputSchemaName),
                  let outputKind = contract.outputKind else {
                continue
            }
            let requiredFields = contract.fields.filter(\.isRequired)
            guard !requiredFields.isEmpty,
                  let artifact = artifacts.first(where: { $0.kind == outputKind }) else {
                continue
            }

            requiredFieldCount += requiredFields.count
            let missingFields = requiredFields.filter { field in
                !markdown(artifact.markdown, containsSchemaField: field.name)
            }
            presentFieldCount += requiredFields.count - missingFields.count
            if !missingFields.isEmpty {
                issues.append("\(contract.name) missing required fields: \(missingFields.map(\.name).joined(separator: ", ")).")
            }
        }

        guard requiredFieldCount > 0 else {
            return (1, issues)
        }
        return (Double(presentFieldCount) / Double(requiredFieldCount), issues)
    }

    private static func markdown(_ markdown: String, containsSchemaField fieldName: String) -> Bool {
        let expected = normalizedSchemaFieldLabel(fieldName)
        return markdown
            .split(whereSeparator: \.isNewline)
            .map { normalizedSchemaLine(String($0)) }
            .contains { line in
                line == expected || line.hasPrefix("\(expected) ")
            }
    }

    private static func normalizedSchemaLine(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = text.first,
              "#*-•0123456789. ".contains(first) {
            text.removeFirst()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let colonIndex = text.firstIndex(of: ":") {
            text = String(text[..<colonIndex])
        }
        return normalizedSchemaFieldLabel(text)
    }

    private static func normalizedSchemaFieldLabel(_ text: String) -> String {
        text
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }
}

public struct StepRun: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var stepID: String
    public var stepName: String
    public var status: WorkflowRunStatus
    public var outputArtifactIDs: [String]
    public var startedAt: Date
    public var completedAt: Date?
    public var errorMessage: String?

    public init(
        id: String,
        stepID: String,
        stepName: String,
        status: WorkflowRunStatus,
        outputArtifactIDs: [String],
        startedAt: Date,
        completedAt: Date? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.stepID = stepID
        self.stepName = stepName
        self.status = status
        self.outputArtifactIDs = outputArtifactIDs
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.errorMessage = errorMessage
    }
}

public struct WorkflowRun: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var templateID: String
    public var templateName: String
    public var status: WorkflowRunStatus
    public var stepRuns: [StepRun]
    public var artifactIDs: [String]
    public var startedAt: Date
    public var completedAt: Date?
    public var errorMessage: String?
    public var retryOfRunID: String?
    public var retryAttempt: Int
    public var nextRetryAt: Date?
    public var evaluation: WorkflowRunEvaluation?

    public init(
        id: String,
        templateID: String,
        templateName: String,
        status: WorkflowRunStatus,
        stepRuns: [StepRun],
        artifactIDs: [String],
        startedAt: Date,
        completedAt: Date? = nil,
        errorMessage: String? = nil,
        retryOfRunID: String? = nil,
        retryAttempt: Int = 0,
        nextRetryAt: Date? = nil,
        evaluation: WorkflowRunEvaluation? = nil
    ) {
        self.id = id
        self.templateID = templateID
        self.templateName = templateName
        self.status = status
        self.stepRuns = stepRuns
        self.artifactIDs = artifactIDs
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.errorMessage = errorMessage
        self.retryOfRunID = retryOfRunID
        self.retryAttempt = retryAttempt
        self.nextRetryAt = nextRetryAt
        self.evaluation = evaluation
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case templateID
        case templateName
        case status
        case stepRuns
        case artifactIDs
        case startedAt
        case completedAt
        case errorMessage
        case retryOfRunID
        case retryAttempt
        case nextRetryAt
        case evaluation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        templateID = try container.decode(String.self, forKey: .templateID)
        templateName = try container.decode(String.self, forKey: .templateName)
        status = try container.decode(WorkflowRunStatus.self, forKey: .status)
        stepRuns = try container.decode([StepRun].self, forKey: .stepRuns)
        artifactIDs = try container.decode([String].self, forKey: .artifactIDs)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        retryOfRunID = try container.decodeIfPresent(String.self, forKey: .retryOfRunID)
        retryAttempt = try container.decodeIfPresent(Int.self, forKey: .retryAttempt) ?? 0
        nextRetryAt = try container.decodeIfPresent(Date.self, forKey: .nextRetryAt)
        evaluation = try container.decodeIfPresent(WorkflowRunEvaluation.self, forKey: .evaluation)
    }
}

public enum WorkflowRetryPolicy {
    public static let maximumAttempts = 5

    public static func nextRetryDate(afterAttempt attempt: Int, from date: Date) -> Date {
        date.addingTimeInterval(retryDelaySeconds(afterAttempt: attempt))
    }

    public static func retryDelaySeconds(afterAttempt attempt: Int) -> TimeInterval {
        let boundedAttempt = min(max(attempt, 1), maximumAttempts)
        return TimeInterval(60 * (1 << (boundedAttempt - 1)))
    }
}

public enum DefaultWorkflows {
    public static let schemaContracts: [WorkflowSchemaContract] = [
        WorkflowSchemaContract(
            name: "CleanTranscriptSchema",
            requiredInputKeys: ["transcript", "markers"],
            summary: "Cleaned transcript with marked moments preserved.",
            fields: [
                WorkflowSchemaField(name: "clean_text", valueType: "string", summary: "Edited transcript text."),
                WorkflowSchemaField(name: "marked_moments", valueType: "list", summary: "Important transcript moments.")
            ]
        ),
        WorkflowSchemaContract(
            name: "ProblemStatementSchema",
            requiredInputKeys: ["clean_transcript"],
            summary: "Target user, problem, current alternatives, and urgency.",
            fields: [
                WorkflowSchemaField(name: "target_user", valueType: "string", summary: "Primary user or buyer."),
                WorkflowSchemaField(name: "problem", valueType: "string", summary: "Problem being solved."),
                WorkflowSchemaField(name: "urgency", valueType: "string", summary: "Why the problem matters now.")
            ]
        ),
        WorkflowSchemaContract(
            name: "MVPPlanArtifact",
            requiredInputKeys: ["problem", "target_users", "risks"],
            outputKind: .roadmap,
            summary: "MVP scope and build sequence artifact.",
            fields: [
                WorkflowSchemaField(name: "scope", valueType: "list", summary: "Must-have MVP capabilities."),
                WorkflowSchemaField(name: "sequence", valueType: "list", summary: "Recommended build order."),
                WorkflowSchemaField(name: "risks", valueType: "list", summary: "Delivery and product risks.")
            ]
        ),
        WorkflowSchemaContract(
            name: "IdeaBriefArtifact",
            requiredInputKeys: ["problem", "target_users", "questions"],
            outputKind: .ideaBrief,
            summary: "Founder-facing idea brief with the core problem and open questions.",
            fields: [
                WorkflowSchemaField(name: "summary", valueType: "string", summary: "Concise product summary."),
                WorkflowSchemaField(name: "target_user", valueType: "string", summary: "Primary user or buyer."),
                WorkflowSchemaField(name: "problem", valueType: "string", summary: "Problem being solved."),
                WorkflowSchemaField(name: "next_questions", valueType: "list", summary: "Questions to answer before build handoff.")
            ]
        ),
        WorkflowSchemaContract(
            name: "ValidationPlanArtifact",
            requiredInputKeys: ["assumptions", "risks", "metrics"],
            outputKind: .validationPlan,
            summary: "Validation plan for proving demand and de-risking the MVP.",
            fields: [
                WorkflowSchemaField(name: "assumptions", valueType: "list", summary: "Riskiest assumptions to test."),
                WorkflowSchemaField(name: "experiments", valueType: "list", summary: "Validation experiments to run."),
                WorkflowSchemaField(name: "success_metrics", valueType: "list", summary: "Metrics that define success."),
                WorkflowSchemaField(name: "risks", valueType: "list", summary: "Risks and boundaries for validation.")
            ]
        ),
        WorkflowSchemaContract(
            name: "PersonaSchema",
            requiredInputKeys: ["idea_summary", "answers"],
            summary: "Persona and buyer/user context.",
            fields: [
                WorkflowSchemaField(name: "persona", valueType: "string", summary: "Named user or buyer profile."),
                WorkflowSchemaField(name: "jobs", valueType: "list", summary: "Jobs the persona needs done."),
                WorkflowSchemaField(name: "constraints", valueType: "list", summary: "Adoption or context constraints.")
            ]
        ),
        WorkflowSchemaContract(
            name: "PRDArtifact",
            requiredInputKeys: ["personas", "requirements", "edge_cases"],
            outputKind: .prd,
            summary: "Product requirements and acceptance criteria.",
            fields: [
                WorkflowSchemaField(name: "goals", valueType: "list", summary: "Product goals."),
                WorkflowSchemaField(name: "requirements", valueType: "list", summary: "Functional requirements."),
                WorkflowSchemaField(name: "acceptance_criteria", valueType: "list", summary: "Testable acceptance checks.")
            ]
        ),
        WorkflowSchemaContract(
            name: "ArchitectureArtifact",
            requiredInputKeys: ["prd", "constraints", "platforms"],
            outputKind: .architecture,
            summary: "Technical architecture and implementation boundaries.",
            fields: [
                WorkflowSchemaField(name: "decision", valueType: "string", summary: "Recommended technical direction."),
                WorkflowSchemaField(name: "components", valueType: "list", summary: "Major app and service components."),
                WorkflowSchemaField(name: "risks", valueType: "list", summary: "Technical risks and boundaries.")
            ]
        ),
        WorkflowSchemaContract(
            name: "UXFlowArtifact",
            requiredInputKeys: ["personas", "requirements", "edge_cases"],
            outputKind: .uxFlow,
            summary: "User journey, screens, states, and edge cases.",
            fields: [
                WorkflowSchemaField(name: "user_journey", valueType: "list", summary: "Primary user journey steps."),
                WorkflowSchemaField(name: "screens", valueType: "list", summary: "Required screens and navigation surfaces."),
                WorkflowSchemaField(name: "states", valueType: "list", summary: "Empty, loading, error, offline, and permission states."),
                WorkflowSchemaField(name: "edge_cases", valueType: "list", summary: "Interaction edge cases and recovery paths.")
            ]
        ),
        WorkflowSchemaContract(
            name: "DataModelArtifact",
            requiredInputKeys: ["prd", "architecture", "privacy_requirements"],
            outputKind: .dataModel,
            summary: "Domain entities, relationships, storage, and retention rules.",
            fields: [
                WorkflowSchemaField(name: "entities", valueType: "list", summary: "Core domain entities and fields."),
                WorkflowSchemaField(name: "relationships", valueType: "list", summary: "Entity relationships and ownership boundaries."),
                WorkflowSchemaField(name: "storage", valueType: "list", summary: "Local and backend persistence responsibilities."),
                WorkflowSchemaField(name: "retention_rules", valueType: "list", summary: "Privacy and deletion rules for user data.")
            ]
        ),
        WorkflowSchemaContract(
            name: "APIDesignArtifact",
            requiredInputKeys: ["architecture", "data_model", "privacy_requirements"],
            outputKind: .apiDesign,
            summary: "Backend routes, payload contracts, auth scope, and failure behavior.",
            fields: [
                WorkflowSchemaField(name: "endpoints", valueType: "list", summary: "Backend or integration endpoints."),
                WorkflowSchemaField(name: "payloads", valueType: "list", summary: "Request and response payload contracts."),
                WorkflowSchemaField(name: "auth_scope", valueType: "list", summary: "Authentication, authorization, and workspace scope requirements."),
                WorkflowSchemaField(name: "failure_modes", valueType: "list", summary: "Fail-closed error and retry behavior.")
            ]
        ),
        WorkflowSchemaContract(
            name: "IssueBundleArtifact",
            requiredInputKeys: ["prd", "architecture", "acceptance_criteria"],
            outputKind: .issueBundle,
            summary: "Reviewable implementation issues with acceptance checks.",
            fields: [
                WorkflowSchemaField(name: "issues", valueType: "list", summary: "Ordered implementation issues."),
                WorkflowSchemaField(name: "labels", valueType: "list", summary: "Suggested labels or ownership areas."),
                WorkflowSchemaField(name: "dependencies", valueType: "list", summary: "Issue dependencies and sequencing constraints."),
                WorkflowSchemaField(name: "acceptance_checks", valueType: "list", summary: "Verification commands and behavioral checks.")
            ]
        ),
        WorkflowSchemaContract(
            name: "CodexPacketSchema",
            requiredInputKeys: ["architecture", "acceptance_criteria"],
            outputKind: .codexTaskBundle,
            summary: "Export-only Codex task packet schema.",
            fields: [
                WorkflowSchemaField(name: "repo_context", valueType: "string", summary: "Implementation context for Codex."),
                WorkflowSchemaField(name: "tasks", valueType: "list", summary: "Ordered build tasks."),
                WorkflowSchemaField(name: "checks", valueType: "list", summary: "Verification commands and acceptance checks.")
            ]
        ),
        WorkflowSchemaContract(
            name: "LaunchChecklistArtifact",
            requiredInputKeys: ["prd", "release_gates", "privacy_requirements"],
            outputKind: .launchChecklist,
            summary: "Launch readiness checklist with release, privacy, monitoring, and support gates.",
            fields: [
                WorkflowSchemaField(name: "release_gates", valueType: "list", summary: "Build, signing, review, and submission gates."),
                WorkflowSchemaField(name: "app_store_assets", valueType: "list", summary: "Screenshots, metadata, icon, support, and review notes."),
                WorkflowSchemaField(name: "privacy_checks", valueType: "list", summary: "Privacy labels, logging checks, and data retention proof."),
                WorkflowSchemaField(name: "monitoring_checks", valueType: "list", summary: "Operational monitoring, backup, and rollback checks.")
            ]
        )
    ]

    public static let templates: [WorkflowTemplate] = [
        WorkflowTemplate(
            id: "wf_app_idea_mvp",
            name: "App Idea -> MVP Plan",
            summary: "Extracts target user, problem, MVP scope, risks, validation plan, and roadmap.",
            outputKinds: [.ideaBrief, .roadmap, .validationPlan],
            steps: [
                WorkflowStep(
                    id: "step_clean_transcript",
                    name: "Clean transcript",
                    kind: .structuredPrompt,
                    inputKeys: ["transcript", "markers"],
                    outputSchemaName: "CleanTranscriptSchema",
                    requiresUserReview: false,
                    modelPolicy: .fast,
                    version: 1
                ),
                WorkflowStep(
                    id: "step_extract_problem",
                    name: "Extract problem statement",
                    kind: .structuredPrompt,
                    inputKeys: ["clean_transcript"],
                    outputSchemaName: "ProblemStatementSchema",
                    requiresUserReview: true,
                    modelPolicy: .balanced,
                    version: 1
                ),
                WorkflowStep(
                    id: "step_generate_idea_brief",
                    name: "Generate idea brief",
                    kind: .artifact,
                    inputKeys: ["problem", "target_users", "questions"],
                    outputSchemaName: "IdeaBriefArtifact",
                    requiresUserReview: true,
                    modelPolicy: .balanced,
                    version: 1
                ),
                WorkflowStep(
                    id: "step_generate_mvp",
                    name: "Generate MVP plan",
                    kind: .artifact,
                    inputKeys: ["problem", "target_users", "risks"],
                    outputSchemaName: "MVPPlanArtifact",
                    requiresUserReview: true,
                    modelPolicy: .best,
                    version: 1
                ),
                WorkflowStep(
                    id: "step_generate_validation_plan",
                    name: "Generate validation plan",
                    kind: .artifact,
                    inputKeys: ["assumptions", "risks", "metrics"],
                    outputSchemaName: "ValidationPlanArtifact",
                    requiresUserReview: true,
                    modelPolicy: .balanced,
                    version: 1
                )
            ]
        ),
        WorkflowTemplate(
            id: "wf_prd",
            name: "App Idea -> PRD",
            summary: "Turns a strengthened idea into goals, personas, requirements, flows, edge cases, and acceptance criteria.",
            outputKinds: [.prd],
            steps: [
                WorkflowStep(
                    id: "step_personas",
                    name: "Define personas",
                    kind: .structuredPrompt,
                    inputKeys: ["idea_summary", "answers"],
                    outputSchemaName: "PersonaSchema",
                    requiresUserReview: true,
                    modelPolicy: .balanced,
                    version: 1
                ),
                WorkflowStep(
                    id: "step_prd",
                    name: "Generate PRD",
                    kind: .artifact,
                    inputKeys: ["personas", "requirements", "edge_cases"],
                    outputSchemaName: "PRDArtifact",
                    requiresUserReview: true,
                    modelPolicy: .best,
                    version: 1
                )
            ]
        ),
        WorkflowTemplate(
            id: "wf_codex_packet",
            name: "Codex Build Packet",
            summary: "Creates repo context, architecture, tasks, acceptance checks, and a safe export-only handoff.",
            outputKinds: [.codexTaskBundle, .architecture],
            steps: [
                WorkflowStep(
                    id: "step_architecture",
                    name: "Draft technical architecture",
                    kind: .artifact,
                    inputKeys: ["prd", "constraints", "platforms"],
                    outputSchemaName: "ArchitectureArtifact",
                    requiresUserReview: true,
                    modelPolicy: .best,
                    version: 1
                ),
                WorkflowStep(
                    id: "step_codex_tasks",
                    name: "Generate Codex task bundle",
                    kind: .toolAction,
                    inputKeys: ["architecture", "acceptance_criteria"],
                    outputSchemaName: "CodexPacketSchema",
                    requiresUserReview: true,
                    modelPolicy: .balanced,
                    version: 1
                )
            ]
        ),
        WorkflowTemplate(
            id: "wf_full_build_packet",
            name: "Idea -> Full Build Packet",
            summary: "Creates the full reviewed build packet: brief, PRD, architecture, UX flow, data model, API design, roadmap, issues, Codex tasks, and launch checklist.",
            outputKinds: [
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
            ],
            steps: [
                WorkflowStep(
                    id: "step_full_idea_brief",
                    name: "Create idea brief",
                    kind: .artifact,
                    inputKeys: ["problem", "target_users", "questions"],
                    outputSchemaName: "IdeaBriefArtifact",
                    requiresUserReview: true,
                    modelPolicy: .balanced,
                    version: 1
                ),
                WorkflowStep(
                    id: "step_full_prd",
                    name: "Create PRD",
                    kind: .artifact,
                    inputKeys: ["personas", "requirements", "edge_cases"],
                    outputSchemaName: "PRDArtifact",
                    requiresUserReview: true,
                    modelPolicy: .best,
                    version: 1
                ),
                WorkflowStep(
                    id: "step_full_architecture",
                    name: "Create architecture",
                    kind: .artifact,
                    inputKeys: ["prd", "constraints", "platforms"],
                    outputSchemaName: "ArchitectureArtifact",
                    requiresUserReview: true,
                    modelPolicy: .best,
                    version: 1
                ),
                WorkflowStep(
                    id: "step_full_ux_flow",
                    name: "Create UX flow",
                    kind: .artifact,
                    inputKeys: ["personas", "requirements", "edge_cases"],
                    outputSchemaName: "UXFlowArtifact",
                    requiresUserReview: true,
                    modelPolicy: .balanced,
                    version: 1
                ),
                WorkflowStep(
                    id: "step_full_data_model",
                    name: "Create data model",
                    kind: .artifact,
                    inputKeys: ["prd", "architecture", "privacy_requirements"],
                    outputSchemaName: "DataModelArtifact",
                    requiresUserReview: true,
                    modelPolicy: .balanced,
                    version: 1
                ),
                WorkflowStep(
                    id: "step_full_api_design",
                    name: "Create API design",
                    kind: .artifact,
                    inputKeys: ["architecture", "data_model", "privacy_requirements"],
                    outputSchemaName: "APIDesignArtifact",
                    requiresUserReview: true,
                    modelPolicy: .best,
                    version: 1
                ),
                WorkflowStep(
                    id: "step_full_roadmap",
                    name: "Create roadmap",
                    kind: .artifact,
                    inputKeys: ["problem", "target_users", "risks"],
                    outputSchemaName: "MVPPlanArtifact",
                    requiresUserReview: true,
                    modelPolicy: .balanced,
                    version: 1
                ),
                WorkflowStep(
                    id: "step_full_issue_bundle",
                    name: "Create implementation issues",
                    kind: .artifact,
                    inputKeys: ["prd", "architecture", "acceptance_criteria"],
                    outputSchemaName: "IssueBundleArtifact",
                    requiresUserReview: true,
                    modelPolicy: .balanced,
                    version: 1
                ),
                WorkflowStep(
                    id: "step_full_codex_tasks",
                    name: "Create Codex tasks",
                    kind: .toolAction,
                    inputKeys: ["architecture", "acceptance_criteria"],
                    outputSchemaName: "CodexPacketSchema",
                    requiresUserReview: true,
                    modelPolicy: .balanced,
                    version: 1
                ),
                WorkflowStep(
                    id: "step_full_launch_checklist",
                    name: "Create launch checklist",
                    kind: .artifact,
                    inputKeys: ["prd", "release_gates", "privacy_requirements"],
                    outputSchemaName: "LaunchChecklistArtifact",
                    requiresUserReview: true,
                    modelPolicy: .balanced,
                    version: 1
                )
            ]
        )
    ]
}
