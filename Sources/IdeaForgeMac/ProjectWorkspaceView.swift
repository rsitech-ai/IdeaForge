import SwiftUI

struct ProjectWorkspaceView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedTab: ProjectWorkspaceTab = .overview
    @State private var showsDeleteConfirmation = false

    var project: IdeaProject
    var workflows: [WorkflowTemplate]
    var deletionReadiness: ProjectDeletionReadiness = ProjectDeletionReadiness(projectID: "", blockers: [.projectMissing])
    var onRetryWorkflow: (String) -> Void = { _ in }
    var onDeleteProject: (String) -> Void = { _ in }
    var onCreateWorkflowVariant: (WorkflowTemplate) -> Void = { _ in }
    var onUpdateWorkflowStep: (String, String, WorkflowStepUpdate) -> Void = { _, _, _ in }
    var onAddWorkflowVariable: (String, WorkflowVariable) -> Void = { _, _ in }
    var onUpdateWorkflowVariable: (String, String, WorkflowVariable) -> Void = { _, _, _ in }
    var onDeleteWorkflowVariable: (String, String) -> Void = { _, _ in }
    var onAddSchemaField: (String, String, WorkflowSchemaField) -> Void = { _, _, _ in }
    var onUpdateSchemaField: (String, String, String, WorkflowSchemaField) -> Void = { _, _, _, _ in }
    var onDeleteSchemaField: (String, String, String) -> Void = { _, _, _ in }
    var onMoveSchemaField: (String, String, String, WorkflowSchemaFieldMoveDirection) -> Void = { _, _, _, _ in }
    var onUpdateTranscriptText: (String, String) -> Void = { _, _ in }
    var onAddValidationExperiment: (String, String, String, String) -> Void = { _, _, _, _ in }
    var onAddAssumption: (String, String, String, Double) -> Void = { _, _, _, _ in }
    var onUpdateArtifactMarkdown: (String, String) -> Void = { _, _ in }
    var onUpdateTranscriptSegment: (String, String, String, Bool) -> Void = { _, _, _, _ in }
    var onPrepareCodexPacket: () -> Void = {}
    var onExportCodexPacket: () -> Void = {}

    private var tabSelection: Binding<ProjectWorkspaceTab> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                guard selectedTab != newValue else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                    selectedTab = newValue
                }
            }
        )
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch selectedTab {
        case .overview:
            OverviewPane(
                project: project,
                onAddValidationExperiment: onAddValidationExperiment,
                onAddAssumption: onAddAssumption
            )
        case .transcript:
            TranscriptPane(
                project: project,
                onUpdateTranscriptText: onUpdateTranscriptText,
                onUpdateTranscriptSegment: onUpdateTranscriptSegment
            )
        case .questions:
            QuestionsPane(project: project)
        case .plan:
            PlanPane(
                project: project,
                workflows: workflows,
                onRetryWorkflow: onRetryWorkflow,
                onCreateWorkflowVariant: onCreateWorkflowVariant,
                onUpdateWorkflowStep: onUpdateWorkflowStep,
                onAddWorkflowVariable: onAddWorkflowVariable,
                onUpdateWorkflowVariable: onUpdateWorkflowVariable,
                onDeleteWorkflowVariable: onDeleteWorkflowVariable,
                onAddSchemaField: onAddSchemaField,
                onUpdateSchemaField: onUpdateSchemaField,
                onDeleteSchemaField: onDeleteSchemaField,
                onMoveSchemaField: onMoveSchemaField
            )
        case .files:
            FilesPane(
                project: project,
                onUpdateArtifactMarkdown: onUpdateArtifactMarkdown,
                onPrepareCodexPacket: onPrepareCodexPacket,
                onExportCodexPacket: onExportCodexPacket
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ProjectWorkspaceHeader(snapshot: MacProjectOverviewSnapshot(project: project), project: project)

            HStack(alignment: .center, spacing: 12) {
                Picker("Project section", selection: tabSelection) {
                    ForEach(ProjectWorkspaceTab.allCases) { tab in
                        Text(tab.label)
                            .tag(tab)
                            .accessibilityIdentifier("mac.projectWorkspace.tab.\(tab.rawValue)")
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.regular)
                .fixedSize()
                .accessibilityIdentifier("mac.projectWorkspace.tabs")
                .accessibilityLabel("Project tabs")
                .accessibilityValue(selectedTab.label)
                .accessibilityHint("Choose Overview, Transcript, Questions, Plan, or Files")

                Spacer(minLength: 12)

                Button(role: .destructive) {
                    showsDeleteConfirmation = true
                } label: {
                    Label("Delete Project", systemImage: "trash")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!deletionReadiness.canDelete)
                .accessibilityLabel("Delete Project")
                .accessibilityIdentifier("mac.projectWorkspace.deleteProject")
                .help(deletionReadiness.canDelete ? "Delete this project" : deletionReadiness.message)
            }

            selectedContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
                .transition(.opacity)
                .layoutPriority(1)
        }
        .padding(20)
        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .focusSection()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mac.projectWorkspace.project.\(project.id)")
        .navigationTitle(project.title)
        .confirmationDialog(
            "Delete \(project.title)?",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Project", role: .destructive) {
                onDeleteProject(project.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the local project workspace after upload, recording, transcription, and workflow safety checks pass.")
        }
    }
}

private enum ProjectWorkspaceTab: String, CaseIterable, Identifiable {
    case overview
    case transcript
    case questions
    case plan
    case files

    var id: String { rawValue }

    var label: String {
        switch self {
        case .overview: "Overview"
        case .transcript: "Transcript"
        case .questions: "Questions"
        case .plan: "Plan"
        case .files: "Files"
        }
    }
}

private struct ProjectWorkspaceHeader: View {
    var snapshot: MacProjectOverviewSnapshot
    var project: IdeaProject

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(project.title)
                .font(.title2.weight(.semibold))
                .lineLimit(1)
                .accessibilityIdentifier("mac.projectWorkspace.title")
            Text(snapshot.purpose)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("mac.projectWorkspace.purpose")
            if let nextStep = snapshot.nextStep {
                Label("Next step: \(nextStep)", systemImage: "arrow.right.circle")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("mac.projectWorkspace.nextStep")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

struct OverviewPane: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var project: IdeaProject
    var onAddValidationExperiment: (String, String, String, String) -> Void = { _, _, _, _ in }
    var onAddAssumption: (String, String, String, Double) -> Void = { _, _, _, _ in }
    @State private var expandedRow: MacOverviewRow.Kind?

    private var snapshot: MacProjectOverviewSnapshot {
        MacProjectOverviewSnapshot(project: project)
    }

    var body: some View {
        GeometryReader { proxy in
            let horizontalPadding: CGFloat = 20
            let contentWidth = max(proxy.size.width - (horizontalPadding * 2), 1)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(snapshot.rows.enumerated()), id: \.element.id) { index, row in
                        OverviewRow(
                            row: displayedRow(row),
                            isExpanded: expandedRow == row.kind,
                            action: { toggle(row.kind) }
                        ) {
                            rowDetail(row.kind)
                        }
                        .accessibilityIdentifier("mac.overview.row.\(row.kind.rawValue)")

                        if index < snapshot.rows.count - 1 {
                            Divider()
                        }
                    }
                }
                .frame(width: contentWidth, alignment: .leading)
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 16)
                .padding(.bottom, 20)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            .contentMargins(.zero, for: .scrollContent)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .accessibilityIdentifier("mac.overview.scroll")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func rowDetail(_ kind: MacOverviewRow.Kind) -> some View {
        switch kind {
        case .summary:
            VStack(alignment: .leading, spacing: 14) {
                SummaryFact(
                    title: "Problem",
                    value: problemSummary,
                    identifier: "mac.overview.summary.problem"
                )
                SummaryFact(
                    title: "Audience",
                    value: audienceSummary,
                    identifier: "mac.overview.summary.audience"
                )
                SummaryFact(
                    title: "Intended outcome",
                    value: intendedOutcome,
                    identifier: "mac.overview.summary.outcome"
                )
            }
        case .validation:
            VStack(alignment: .leading, spacing: 20) {
                ValidationPlannerSection(
                    project: project,
                    onAddValidationExperiment: onAddValidationExperiment
                )
                AssumptionTrackerSection(project: project, onAddAssumption: onAddAssumption)
            }
        case .readiness:
            VStack(alignment: .leading, spacing: 14) {
                ReadinessMetricRow(
                    title: "Confidence",
                    value: project.score.confidence,
                    identifier: "mac.overview.metric.confidence"
                )
                ReadinessMetricRow(
                    title: "Completeness",
                    value: project.score.completeness,
                    identifier: "mac.overview.metric.completeness"
                )
                ReadinessMetricRow(
                    title: "Risk",
                    value: project.score.risk,
                    identifier: "mac.overview.metric.risk"
                )
            }
        }
    }

    private func toggle(_ kind: MacOverviewRow.Kind) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            expandedRow = expandedRow == kind ? nil : kind
        }
    }

    private func displayedRow(_ row: MacOverviewRow) -> MacOverviewRow {
        let detail: String
        switch row.kind {
        case .summary:
            let tagSummary = project.tags.map(\.label).joined(separator: ", ")
            detail = tagSummary.isEmpty ? "Captured on \(project.source.label)" : tagSummary
        case .validation:
            detail = row.detail
        case .readiness:
            let unresolvedCount = project.questions.filter { $0.answer == nil }.count
            detail = unresolvedCount == 0
                ? project.status.label
                : "\(unresolvedCount) decision\(unresolvedCount == 1 ? "" : "s") open"
        }
        return MacOverviewRow(kind: row.kind, title: row.title, detail: detail)
    }

    private var audienceSummary: String {
        let audienceQuestion = project.questions.first { question in
            let prompt = question.prompt.lowercased()
            return prompt.contains("user") || prompt.contains("customer") || prompt.contains("audience") || prompt.contains("who")
        }
        if let answer = audienceQuestion?.answer?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty {
            return answer
        }
        if let prompt = audienceQuestion?.prompt {
            return "Not captured yet. Open question: \(prompt)"
        }
        return "Not captured yet."
    }

    private var problemSummary: String {
        let problemQuestion = project.questions.first { question in
            question.prompt.localizedCaseInsensitiveContains("problem")
        }
        if let answer = problemQuestion?.answer?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty {
            return answer
        }
        if let prompt = problemQuestion?.prompt {
            return "Not captured yet. Open question: \(prompt)"
        }
        return "Not captured yet."
    }

    private var intendedOutcome: String {
        let transcript = project.transcript.cleanText.trimmingCharacters(in: .whitespacesAndNewlines)
        return transcript.isEmpty ? "Not captured yet." : transcript
    }
}

private struct SummaryFact: View {
    var title: String
    var value: String
    var identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }
}

private struct OverviewRow<Detail: View>: View {
    var row: MacOverviewRow
    var isExpanded: Bool
    var action: () -> Void
    @ViewBuilder var detail: () -> Detail

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: action) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(row.title)
                        .font(.headline)
                    Text(row.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 12)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
                .padding(.vertical, 14)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(row.title)
            .accessibilityValue("\(row.detail), \(isExpanded ? "Expanded" : "Collapsed")")
            .accessibilityHint(isExpanded ? "Collapses \(row.title) details" : "Expands \(row.title) details")
            .help(isExpanded ? "Collapse \(row.title)" : "Expand \(row.title)")

            if isExpanded {
                detail()
                    .padding(.bottom, 18)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

private struct ReadinessMetricRow: View {
    var title: String
    var value: Double
    var identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.callout.weight(.medium))
                Spacer()
                Text(value, format: .percent.precision(.fractionLength(0)))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: value)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }
}

private enum PlanSection: String, CaseIterable, Identifiable {
    case workflows
    case runs
    case codexTasks

    var id: String { rawValue }

    var label: String {
        switch self {
        case .workflows: "Workflows"
        case .runs: "Workflow Runs"
        case .codexTasks: "Codex Tasks"
        }
    }
}

private struct PlanPane: View {
    @State private var selectedSection: PlanSection = .workflows

    var project: IdeaProject
    var workflows: [WorkflowTemplate]
    var onRetryWorkflow: (String) -> Void
    var onCreateWorkflowVariant: (WorkflowTemplate) -> Void
    var onUpdateWorkflowStep: (String, String, WorkflowStepUpdate) -> Void
    var onAddWorkflowVariable: (String, WorkflowVariable) -> Void
    var onUpdateWorkflowVariable: (String, String, WorkflowVariable) -> Void
    var onDeleteWorkflowVariable: (String, String) -> Void
    var onAddSchemaField: (String, String, WorkflowSchemaField) -> Void
    var onUpdateSchemaField: (String, String, String, WorkflowSchemaField) -> Void
    var onDeleteSchemaField: (String, String, String) -> Void
    var onMoveSchemaField: (String, String, String, WorkflowSchemaFieldMoveDirection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Plan", systemImage: "checklist")
                    .font(.headline)
                Spacer()
                Picker("Plan section", selection: $selectedSection) {
                    ForEach(PlanSection.allCases) { section in
                        Text(section.label).tag(section)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
                .accessibilityIdentifier("mac.plan.section")
            }

            switch selectedSection {
            case .workflows:
                WorkflowTemplatesPane(
                    workflows: workflows,
                    onCreateWorkflowVariant: onCreateWorkflowVariant,
                    onUpdateWorkflowStep: onUpdateWorkflowStep,
                    onAddWorkflowVariable: onAddWorkflowVariable,
                    onUpdateWorkflowVariable: onUpdateWorkflowVariable,
                    onDeleteWorkflowVariable: onDeleteWorkflowVariable,
                    onAddSchemaField: onAddSchemaField,
                    onUpdateSchemaField: onUpdateSchemaField,
                    onDeleteSchemaField: onDeleteSchemaField,
                    onMoveSchemaField: onMoveSchemaField
                )
                .accessibilityIdentifier("mac.plan.workflows")
            case .runs:
                WorkflowRunsPane(project: project, onRetryWorkflow: onRetryWorkflow)
                    .accessibilityIdentifier("mac.plan.runs")
            case .codexTasks:
                CodexPane(project: project)
                    .accessibilityIdentifier("mac.plan.codexTasks")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct WorkflowTemplatesPane: View {
    var workflows: [WorkflowTemplate]
    var onCreateWorkflowVariant: (WorkflowTemplate) -> Void
    var onUpdateWorkflowStep: (String, String, WorkflowStepUpdate) -> Void
    var onAddWorkflowVariable: (String, WorkflowVariable) -> Void
    var onUpdateWorkflowVariable: (String, String, WorkflowVariable) -> Void
    var onDeleteWorkflowVariable: (String, String) -> Void
    var onAddSchemaField: (String, String, WorkflowSchemaField) -> Void
    var onUpdateSchemaField: (String, String, String, WorkflowSchemaField) -> Void
    var onDeleteSchemaField: (String, String, String) -> Void
    var onMoveSchemaField: (String, String, String, WorkflowSchemaFieldMoveDirection) -> Void

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 280), spacing: 12, alignment: .top)],
                spacing: 12
            ) {
                ForEach(workflows) { workflow in
                    WorkflowTemplateCard(
                        workflow: workflow,
                        onCreateWorkflowVariant: onCreateWorkflowVariant,
                        onUpdateWorkflowStep: onUpdateWorkflowStep,
                        onAddWorkflowVariable: onAddWorkflowVariable,
                        onUpdateWorkflowVariable: onUpdateWorkflowVariable,
                        onDeleteWorkflowVariable: onDeleteWorkflowVariable,
                        onAddSchemaField: onAddSchemaField,
                        onUpdateSchemaField: onUpdateSchemaField,
                        onDeleteSchemaField: onDeleteSchemaField,
                        onMoveSchemaField: onMoveSchemaField
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }
}

private struct FilesPane: View {
    var project: IdeaProject
    var onUpdateArtifactMarkdown: (String, String) -> Void
    var onPrepareCodexPacket: () -> Void
    var onExportCodexPacket: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Label("Exports", systemImage: "square.and.arrow.up")
                    .font(.headline)
                Spacer()
                Button(action: onPrepareCodexPacket) {
                    Label("Prepare Codex Packet", systemImage: "shippingbox")
                }
                .controlSize(.small)
                .accessibilityIdentifier("mac.files.prepareCodexPacket")
                .help("Prepare a reviewable Codex packet artifact")
                Button(action: onExportCodexPacket) {
                    Label("Export Files", systemImage: "folder.badge.plus")
                }
                .controlSize(.small)
                .accessibilityIdentifier("mac.files.exportCodexPacket")
                .help("Export the selected project packet files")
            }

            Divider()

            ArtifactsPane(project: project, onUpdateArtifactMarkdown: onUpdateArtifactMarkdown)
                .accessibilityIdentifier("mac.files.artifacts")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct AssumptionTrackerSection: View {
    var project: IdeaProject
    var onAddAssumption: (String, String, String, Double) -> Void

    @State private var text = ""
    @State private var evidence = ""
    @State private var confidence = 0.5

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedEvidence: String {
        evidence.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canAdd: Bool {
        !trimmedText.isEmpty && !trimmedEvidence.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Assumption Tracker")

            if project.assumptions.isEmpty {
                Label("No assumptions tracked", systemImage: "lightbulb.min")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("mac.assumptions.empty")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], spacing: 12) {
                    ForEach(project.assumptions) { assumption in
                        AssumptionCard(assumption: assumption)
                            .accessibilityIdentifier("mac.assumptions.item.\(assumption.id)")
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                TextField("Assumption", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("mac.assumptions.text")

                TextField("Evidence", text: $evidence)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("mac.assumptions.evidence")

                HStack(spacing: 10) {
                    Label("Confidence", systemImage: "chart.line.uptrend.xyaxis")
                        .font(.caption.weight(.semibold))
                    Slider(value: $confidence, in: 0...1, step: 0.05)
                        .accessibilityIdentifier("mac.assumptions.confidence")
                    Text(confidence, format: .percent.precision(.fractionLength(0)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .trailing)
                }

                Button {
                    onAddAssumption(project.id, trimmedText, trimmedEvidence, confidence)
                    text = ""
                    evidence = ""
                    confidence = 0.5
                } label: {
                    Label("Add Assumption", systemImage: "plus.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!canAdd)
                .accessibilityIdentifier("mac.assumptions.add")
                .help(canAdd ? "Add this tracked assumption" : "Enter an assumption and evidence")
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.cyan.opacity(0.14))
            }
        }
    }
}

private struct AssumptionCard: View {
    var assumption: Assumption

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(assumption.text, systemImage: "lightbulb")
                .font(.headline)
                .lineLimit(2)
            Text(assumption.evidence)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ProgressView(value: assumption.confidence) {
                Text("Confidence")
                    .font(.caption.weight(.semibold))
            }
            .accessibilityValue(Text(assumption.confidence, format: .percent.precision(.fractionLength(0))))
        }
        .padding(14)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .macLiveSurface(tint: .yellow, isActive: false)
    }
}

private struct ValidationPlannerSection: View {
    var project: IdeaProject
    var onAddValidationExperiment: (String, String, String, String) -> Void

    @State private var title = ""
    @State private var metric = ""
    @State private var goNoGoCriteria = ""

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedMetric: String {
        metric.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedCriteria: String {
        goNoGoCriteria.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canAdd: Bool {
        !trimmedTitle.isEmpty && !trimmedMetric.isEmpty && !trimmedCriteria.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Validation Planner")

            if project.validationExperiments.isEmpty {
                Label("No validation experiments planned", systemImage: "checklist.unchecked")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("mac.validation.empty")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], spacing: 12) {
                    ForEach(project.validationExperiments) { experiment in
                        ValidationExperimentCard(experiment: experiment)
                            .accessibilityIdentifier("mac.validation.experiment.\(experiment.id)")
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("Experiment title", text: $title)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("mac.validation.title")
                    TextField("Success metric", text: $metric)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("mac.validation.metric")
                }

                TextField("Go / no-go criteria", text: $goNoGoCriteria)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("mac.validation.criteria")

                Button {
                    onAddValidationExperiment(project.id, trimmedTitle, trimmedMetric, trimmedCriteria)
                    title = ""
                    metric = ""
                    goNoGoCriteria = ""
                } label: {
                    Label("Add Experiment", systemImage: "plus.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!canAdd)
                .accessibilityIdentifier("mac.validation.add")
                .help(canAdd ? "Add this validation experiment" : "Enter a title, metric, and go/no-go criteria")
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.mint.opacity(0.14))
            }
        }
    }
}

private struct ValidationExperimentCard: View {
    var experiment: ValidationExperiment

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(experiment.title, systemImage: "target")
                .font(.headline)
                .lineLimit(2)
            Label(experiment.metric, systemImage: "chart.bar")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text(experiment.goNoGoCriteria)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .macLiveSurface(tint: .orange, isActive: false)
    }
}

private struct WorkflowTemplateCard: View {
    var workflow: WorkflowTemplate
    var onCreateWorkflowVariant: (WorkflowTemplate) -> Void
    var onUpdateWorkflowStep: (String, String, WorkflowStepUpdate) -> Void
    var onAddWorkflowVariable: (String, WorkflowVariable) -> Void
    var onUpdateWorkflowVariable: (String, String, WorkflowVariable) -> Void
    var onDeleteWorkflowVariable: (String, String) -> Void
    var onAddSchemaField: (String, String, WorkflowSchemaField) -> Void
    var onUpdateSchemaField: (String, String, String, WorkflowSchemaField) -> Void
    var onDeleteSchemaField: (String, String, String) -> Void
    var onMoveSchemaField: (String, String, String, WorkflowSchemaFieldMoveDirection) -> Void

    @State private var selectedSchemaName = ""
    @State private var fieldName = ""
    @State private var fieldType = "string"
    @State private var fieldSummary = ""
    @State private var editingFieldName: String?
    @State private var editFieldName = ""
    @State private var editFieldType = ""
    @State private var editFieldSummary = ""
    @State private var variableKey = ""
    @State private var variableValue = ""
    @State private var variableSummary = ""
    @State private var editingVariableKey: String?
    @State private var editVariableKey = ""
    @State private var editVariableValue = ""
    @State private var editVariableSummary = ""
    @State private var editingStepID: String?
    @State private var editStepName = ""
    @State private var editStepInputKeys = ""
    @State private var editStepSchemaName = ""
    @State private var editStepPromptBody = ""
    @State private var editStepRequiresReview = false
    @State private var editStepModelPolicy: ModelPolicy = .balanced

    private var schemaContracts: [WorkflowSchemaContract] {
        var seen: Set<String> = []
        return workflow.steps.compactMap { step in
            guard let contract = workflow.schemaContract(named: step.outputSchemaName),
                  seen.insert(contract.name).inserted else {
                return nil
            }
            return contract
        }
    }

    private var selectedContract: WorkflowSchemaContract? {
        schemaContracts.first { $0.name == selectedSchemaName } ?? schemaContracts.first
    }

    private var trimmedFieldName: String {
        fieldName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedFieldType: String {
        fieldType.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedFieldSummary: String {
        fieldSummary.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canAddSchemaField: Bool {
        guard let selectedContract else { return false }
        return !trimmedFieldName.isEmpty
            && !trimmedFieldType.isEmpty
            && !trimmedFieldSummary.isEmpty
            && !selectedContract.fields.contains { $0.name == trimmedFieldName }
    }

    private var trimmedEditFieldName: String {
        editFieldName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedEditFieldType: String {
        editFieldType.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedEditFieldSummary: String {
        editFieldSummary.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSaveEditedField: Bool {
        guard let editingFieldName, let selectedContract else { return false }
        return !trimmedEditFieldName.isEmpty
            && !trimmedEditFieldType.isEmpty
            && !trimmedEditFieldSummary.isEmpty
            && !selectedContract.fields.contains { field in
                field.name != editingFieldName && field.name == trimmedEditFieldName
            }
    }

    private var availableSchemaNames: [String] {
        let names = workflow.steps.compactMap { step in
            workflow.schemaContract(named: step.outputSchemaName)?.name
        } + workflow.schemaContracts.map(\.name)
        var seen: Set<String> = []
        return names.filter { seen.insert($0).inserted }
    }

    private var parsedEditStepInputKeys: [String] {
        editStepInputKeys
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var canSaveEditedStep: Bool {
        guard let editingStepID,
              let contract = workflow.schemaContract(named: editStepSchemaName),
              workflow.steps.contains(where: { $0.id == editingStepID }) else {
            return false
        }
        let trimmedName = editStepName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPromptBody = editStepPromptBody.trimmingCharacters(in: .whitespacesAndNewlines)
        let missingInputKeys = contract.requiredInputKeys.filter { !parsedEditStepInputKeys.contains($0) }
        return !trimmedName.isEmpty
            && !editStepSchemaName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !trimmedPromptBody.isEmpty
            && missingInputKeys.isEmpty
    }

    private var trimmedVariableKey: String {
        variableKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedVariableValue: String {
        variableValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedVariableSummary: String {
        variableSummary.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canAddVariable: Bool {
        workflowVariableKeyIsValid(trimmedVariableKey)
            && !trimmedVariableValue.isEmpty
            && !trimmedVariableSummary.isEmpty
            && !workflow.variables.contains { $0.key == trimmedVariableKey }
    }

    private var trimmedEditVariableKey: String {
        editVariableKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedEditVariableValue: String {
        editVariableValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedEditVariableSummary: String {
        editVariableSummary.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSaveEditedVariable: Bool {
        guard let editingVariableKey else { return false }
        return workflowVariableKeyIsValid(trimmedEditVariableKey)
            && !trimmedEditVariableValue.isEmpty
            && !trimmedEditVariableSummary.isEmpty
            && !workflow.variables.contains { variable in
                variable.key != editingVariableKey && variable.key == trimmedEditVariableKey
            }
    }

    private func workflowVariableKeyIsValid(_ key: String) -> Bool {
        !key.isEmpty && key.allSatisfy { character in
            character == "_" || character.isLetter || character.isNumber
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(workflow.name, systemImage: "point.3.connected.trianglepath.dotted")
                .font(.headline)
            Text(workflow.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("\(workflow.steps.count) steps")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    onCreateWorkflowVariant(workflow)
                } label: {
                    Label("Review Variant", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("mac.workflow.createVariant.\(workflow.id)")
                .help("Create a custom review-gated variant of this workflow")
            }

            WorkflowCostEstimateRow(estimate: workflow.costEstimate)
                .accessibilityIdentifier("mac.workflow.costEstimate.\(workflow.id)")

            ForEach(workflow.steps) { step in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(step.name)
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Button {
                            startEditingStep(step)
                        } label: {
                            Image(systemName: "pencil.line")
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .accessibilityLabel("Edit \(step.name)")
                        .accessibilityIdentifier("mac.workflow.stepEditor.edit.\(workflow.id).\(step.id)")
                        .help("Edit workflow step")
                    }
                    HStack(spacing: 8) {
                        Label(step.outputSchemaName, systemImage: "curlybraces")
                        Label(step.modelPolicy.rawValue.capitalized, systemImage: "cpu")
                        Label("v\(step.version)", systemImage: "number")
                        if step.requiresUserReview {
                            Label("Review", systemImage: "person.crop.circle.badge.checkmark")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    Text(step.promptBody)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .accessibilityIdentifier("mac.workflow.stepPrompt.\(workflow.id).\(step.id)")
                    if let contract = workflow.schemaContract(named: step.outputSchemaName),
                       !contract.fields.isEmpty {
                        WorkflowSchemaFieldPreview(fields: contract.fields)
                            .accessibilityIdentifier("mac.workflow.schemaFields.\(workflow.id).\(step.id)")
                    }

                    if editingStepID == step.id {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Step name", text: $editStepName)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("mac.workflow.stepEditor.name.\(workflow.id).\(step.id)")

                            TextField("Input keys, comma separated", text: $editStepInputKeys)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("mac.workflow.stepEditor.inputKeys.\(workflow.id).\(step.id)")

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Prompt body")
                                    .font(.caption.weight(.semibold))
                                TextEditor(text: $editStepPromptBody)
                                    .font(.caption)
                                    .frame(minHeight: 96)
                                    .scrollContentBackground(.hidden)
                                    .background(.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
                                    .accessibilityIdentifier("mac.workflow.stepEditor.promptBody.\(workflow.id).\(step.id)")
                            }

                            HStack(spacing: 8) {
                                Picker("Schema", selection: $editStepSchemaName) {
                                    ForEach(availableSchemaNames, id: \.self) { schemaName in
                                        Text(schemaName).tag(schemaName)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .accessibilityIdentifier("mac.workflow.stepEditor.schema.\(workflow.id).\(step.id)")

                                Picker("Model", selection: $editStepModelPolicy) {
                                    ForEach(ModelPolicy.allCases) { policy in
                                        Text(policy.rawValue.capitalized).tag(policy)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .accessibilityIdentifier("mac.workflow.stepEditor.model.\(workflow.id).\(step.id)")

                                Toggle("Review", isOn: $editStepRequiresReview)
                                    .toggleStyle(.checkbox)
                                    .accessibilityIdentifier("mac.workflow.stepEditor.review.\(workflow.id).\(step.id)")
                            }

                            HStack(spacing: 8) {
                                Button {
                                    onUpdateWorkflowStep(
                                        workflow.id,
                                        step.id,
                                        WorkflowStepUpdate(
                                            stepID: step.id,
                                            name: editStepName.trimmingCharacters(in: .whitespacesAndNewlines),
                                            inputKeys: parsedEditStepInputKeys,
                                            outputSchemaName: editStepSchemaName,
                                            promptBody: editStepPromptBody.trimmingCharacters(in: .whitespacesAndNewlines),
                                            requiresUserReview: editStepRequiresReview,
                                            modelPolicy: editStepModelPolicy
                                        )
                                    )
                                    cancelEditingStep()
                                } label: {
                                    Label("Save Step", systemImage: "checkmark")
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(!canSaveEditedStep)
                                .accessibilityIdentifier("mac.workflow.stepEditor.save.\(workflow.id).\(step.id)")

                                Button {
                                    cancelEditingStep()
                                } label: {
                                    Label("Cancel", systemImage: "xmark")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .accessibilityIdentifier("mac.workflow.stepEditor.cancel.\(workflow.id).\(step.id)")
                            }
                        }
                        .padding(8)
                        .macInputSurface(tint: .indigo, cornerRadius: 12)
                    }
                }
            }

            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    if workflow.variables.isEmpty {
                        Text("No workflow variables yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(workflow.variables) { variable in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .top, spacing: 8) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("{\(variable.key)}")
                                            .font(.caption.weight(.semibold))
                                            .lineLimit(1)
                                        Text(variable.summary)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                        Text(variable.value)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(2)
                                    }
                                    Spacer()
                                    Button {
                                        startEditingVariable(variable)
                                    } label: {
                                        Image(systemName: "pencil")
                                    }
                                    .buttonStyle(.borderless)
                                    .controlSize(.small)
                                    .accessibilityLabel("Edit \(variable.key)")
                                    .accessibilityIdentifier("mac.workflow.variableEditor.edit.\(workflow.id).\(variable.key)")
                                    .help("Edit workflow variable")

                                    Button(role: .destructive) {
                                        onDeleteWorkflowVariable(workflow.id, variable.key)
                                        if editingVariableKey == variable.key {
                                            cancelEditingVariable()
                                        }
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                    .controlSize(.small)
                                    .accessibilityLabel("Delete \(variable.key)")
                                    .accessibilityIdentifier("mac.workflow.variableEditor.delete.\(workflow.id).\(variable.key)")
                                    .help("Delete workflow variable")
                                }

                                if editingVariableKey == variable.key {
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack(spacing: 8) {
                                            TextField("Variable key", text: $editVariableKey)
                                                .textFieldStyle(.roundedBorder)
                                                .accessibilityIdentifier("mac.workflow.variableEditor.editKey.\(workflow.id).\(variable.key)")
                                            TextField("Summary", text: $editVariableSummary)
                                                .textFieldStyle(.roundedBorder)
                                                .accessibilityIdentifier("mac.workflow.variableEditor.editSummary.\(workflow.id).\(variable.key)")
                                        }
                                        TextField("Value", text: $editVariableValue)
                                            .textFieldStyle(.roundedBorder)
                                            .accessibilityIdentifier("mac.workflow.variableEditor.editValue.\(workflow.id).\(variable.key)")
                                        HStack(spacing: 8) {
                                            Button {
                                                onUpdateWorkflowVariable(
                                                    workflow.id,
                                                    variable.key,
                                                    WorkflowVariable(
                                                        key: trimmedEditVariableKey,
                                                        value: trimmedEditVariableValue,
                                                        summary: trimmedEditVariableSummary
                                                    )
                                                )
                                                cancelEditingVariable()
                                            } label: {
                                                Label("Save", systemImage: "checkmark")
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .controlSize(.small)
                                            .disabled(!canSaveEditedVariable)
                                            .accessibilityIdentifier("mac.workflow.variableEditor.saveEdit.\(workflow.id).\(variable.key)")

                                            Button {
                                                cancelEditingVariable()
                                            } label: {
                                                Label("Cancel", systemImage: "xmark")
                                            }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                            .accessibilityIdentifier("mac.workflow.variableEditor.cancelEdit.\(workflow.id).\(variable.key)")
                                        }
                                    }
                                    .padding(.leading, 16)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    HStack(spacing: 8) {
                        TextField("Variable key", text: $variableKey)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("mac.workflow.variableEditor.key.\(workflow.id)")
                        TextField("Summary", text: $variableSummary)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("mac.workflow.variableEditor.summary.\(workflow.id)")
                    }
                    TextField("Value", text: $variableValue)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("mac.workflow.variableEditor.value.\(workflow.id)")

                    Button {
                        onAddWorkflowVariable(
                            workflow.id,
                            WorkflowVariable(
                                key: trimmedVariableKey,
                                value: trimmedVariableValue,
                                summary: trimmedVariableSummary
                            )
                        )
                        variableKey = ""
                        variableValue = ""
                        variableSummary = ""
                    } label: {
                        Label("Add Variable", systemImage: "plus.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!canAddVariable)
                    .accessibilityIdentifier("mac.workflow.variableEditor.add.\(workflow.id)")
                    .help(canAddVariable ? "Add workflow variable" : "Use a unique key with letters, numbers, and underscores plus a value and summary")
                }
                .padding(.top, 4)
            } label: {
                Label("Variables", systemImage: "curlybraces")
                    .font(.caption.weight(.semibold))
            }

            if !schemaContracts.isEmpty {
                Divider()
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Schema", selection: $selectedSchemaName) {
                            ForEach(schemaContracts) { contract in
                                Text(contract.name).tag(contract.name)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .accessibilityIdentifier("mac.workflow.schemaEditor.schema.\(workflow.id)")

                        if let selectedContract, !selectedContract.fields.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(selectedContract.fields.enumerated()), id: \.element.name) { index, field in
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack(alignment: .top, spacing: 8) {
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(field.name)
                                                    .font(.caption.weight(.semibold))
                                                    .lineLimit(1)
                                                Text("\(field.valueType) - \(field.summary)")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(2)
                                            }
                                            Spacer()
                                            Button {
                                                onMoveSchemaField(workflow.id, selectedContract.name, field.name, .up)
                                            } label: {
                                                Image(systemName: "arrow.up")
                                            }
                                            .buttonStyle(.borderless)
                                            .controlSize(.small)
                                            .disabled(index == 0)
                                            .accessibilityLabel("Move \(field.name) up")
                                            .accessibilityIdentifier("mac.workflow.schemaEditor.moveUp.\(workflow.id).\(field.name)")
                                            .help("Move field up")

                                            Button {
                                                onMoveSchemaField(workflow.id, selectedContract.name, field.name, .down)
                                            } label: {
                                                Image(systemName: "arrow.down")
                                            }
                                            .buttonStyle(.borderless)
                                            .controlSize(.small)
                                            .disabled(index == selectedContract.fields.index(before: selectedContract.fields.endIndex))
                                            .accessibilityLabel("Move \(field.name) down")
                                            .accessibilityIdentifier("mac.workflow.schemaEditor.moveDown.\(workflow.id).\(field.name)")
                                            .help("Move field down")

                                            Button {
                                                startEditing(field)
                                            } label: {
                                                Image(systemName: "pencil")
                                            }
                                            .buttonStyle(.borderless)
                                            .controlSize(.small)
                                            .accessibilityLabel("Edit \(field.name)")
                                            .accessibilityIdentifier("mac.workflow.schemaEditor.edit.\(workflow.id).\(field.name)")
                                            .help("Edit field")

                                            Button(role: .destructive) {
                                                onDeleteSchemaField(workflow.id, selectedContract.name, field.name)
                                                if editingFieldName == field.name {
                                                    cancelEditing()
                                                }
                                            } label: {
                                                Image(systemName: "trash")
                                            }
                                            .buttonStyle(.borderless)
                                            .controlSize(.small)
                                            .accessibilityLabel("Delete \(field.name)")
                                            .accessibilityIdentifier("mac.workflow.schemaEditor.delete.\(workflow.id).\(field.name)")
                                            .help("Delete field")
                                        }

                                        if editingFieldName == field.name {
                                            VStack(alignment: .leading, spacing: 6) {
                                                HStack(spacing: 8) {
                                                    TextField("Field name", text: $editFieldName)
                                                        .textFieldStyle(.roundedBorder)
                                                        .accessibilityIdentifier("mac.workflow.schemaEditor.editName.\(workflow.id).\(field.name)")
                                                    TextField("Type", text: $editFieldType)
                                                        .textFieldStyle(.roundedBorder)
                                                        .frame(width: 90)
                                                        .accessibilityIdentifier("mac.workflow.schemaEditor.editType.\(workflow.id).\(field.name)")
                                                }
                                                TextField("Summary", text: $editFieldSummary)
                                                    .textFieldStyle(.roundedBorder)
                                                    .accessibilityIdentifier("mac.workflow.schemaEditor.editSummary.\(workflow.id).\(field.name)")
                                                HStack(spacing: 8) {
                                                    Button {
                                                        onUpdateSchemaField(
                                                            workflow.id,
                                                            selectedContract.name,
                                                            field.name,
                                                            WorkflowSchemaField(
                                                                name: trimmedEditFieldName,
                                                                valueType: trimmedEditFieldType,
                                                                summary: trimmedEditFieldSummary
                                                            )
                                                        )
                                                        cancelEditing()
                                                    } label: {
                                                        Label("Save", systemImage: "checkmark")
                                                    }
                                                    .buttonStyle(.borderedProminent)
                                                    .controlSize(.small)
                                                    .disabled(!canSaveEditedField)
                                                    .accessibilityIdentifier("mac.workflow.schemaEditor.saveEdit.\(workflow.id).\(field.name)")

                                                    Button {
                                                        cancelEditing()
                                                    } label: {
                                                        Label("Cancel", systemImage: "xmark")
                                                    }
                                                    .buttonStyle(.bordered)
                                                    .controlSize(.small)
                                                    .accessibilityIdentifier("mac.workflow.schemaEditor.cancelEdit.\(workflow.id).\(field.name)")
                                                }
                                            }
                                            .padding(.leading, 16)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                        }

                        HStack(spacing: 8) {
                            TextField("Field name", text: $fieldName)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("mac.workflow.schemaEditor.fieldName.\(workflow.id)")
                            TextField("Type", text: $fieldType)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 90)
                                .accessibilityIdentifier("mac.workflow.schemaEditor.fieldType.\(workflow.id)")
                        }

                        TextField("Summary", text: $fieldSummary)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("mac.workflow.schemaEditor.fieldSummary.\(workflow.id)")

                        Button {
                            guard let selectedContract else { return }
                            onAddSchemaField(
                                workflow.id,
                                selectedContract.name,
                                WorkflowSchemaField(
                                    name: trimmedFieldName,
                                    valueType: trimmedFieldType,
                                    summary: trimmedFieldSummary
                                )
                            )
                            fieldName = ""
                            fieldSummary = ""
                        } label: {
                            Label("Add Field", systemImage: "plus.circle")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!canAddSchemaField)
                        .accessibilityIdentifier("mac.workflow.schemaEditor.addField.\(workflow.id)")
                        .help(canAddSchemaField ? "Add this field to the selected schema" : "Enter a unique field name, type, and summary")
                    }
                    .padding(.top, 4)
                } label: {
                    Label("Schema Fields", systemImage: "curlybraces.square")
                        .font(.caption.weight(.semibold))
                }
            }
        }
        .padding(14)
        .padding(.bottom, 16)
        .macLiveSurface(
            tint: .indigo,
            isActive: editingStepID != nil || editingFieldName != nil || editingVariableKey != nil
        )
        .onAppear {
            if selectedSchemaName.isEmpty {
                selectedSchemaName = schemaContracts.first?.name ?? ""
            }
        }
    }

    private func startEditing(_ field: WorkflowSchemaField) {
        editingFieldName = field.name
        editFieldName = field.name
        editFieldType = field.valueType
        editFieldSummary = field.summary
    }

    private func cancelEditing() {
        editingFieldName = nil
        editFieldName = ""
        editFieldType = ""
        editFieldSummary = ""
    }

    private func startEditingVariable(_ variable: WorkflowVariable) {
        editingVariableKey = variable.key
        editVariableKey = variable.key
        editVariableValue = variable.value
        editVariableSummary = variable.summary
    }

    private func cancelEditingVariable() {
        editingVariableKey = nil
        editVariableKey = ""
        editVariableValue = ""
        editVariableSummary = ""
    }

    private func startEditingStep(_ step: WorkflowStep) {
        editingStepID = step.id
        editStepName = step.name
        editStepInputKeys = step.inputKeys.joined(separator: ", ")
        editStepSchemaName = step.outputSchemaName
        editStepPromptBody = step.promptBody
        editStepRequiresReview = step.requiresUserReview
        editStepModelPolicy = step.modelPolicy
    }

    private func cancelEditingStep() {
        editingStepID = nil
        editStepName = ""
        editStepInputKeys = ""
        editStepSchemaName = ""
        editStepPromptBody = ""
        editStepRequiresReview = false
        editStepModelPolicy = .balanced
    }
}

private struct WorkflowCostEstimateRow: View {
    var estimate: WorkflowTemplateCostEstimate

    var body: some View {
        HStack(spacing: 10) {
            Label("\(estimate.modelPolicyUnits) units", systemImage: "gauge.medium")
            Label("\(estimate.reviewGateCount) reviews", systemImage: "checkmark.seal")
            Label("\(estimate.externalModelStepCount) model steps", systemImage: "cpu")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
    }
}

private struct WorkflowSchemaFieldPreview: View {
    var fields: [WorkflowSchemaField]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                fieldLabels
            }
            VStack(alignment: .leading, spacing: 4) {
                fieldLabels
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var fieldLabels: some View {
        ForEach(fields.prefix(3)) { field in
            Label {
                Text("\(field.name): \(field.valueType)")
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            } icon: {
                Image(systemName: field.isRequired ? "asterisk" : "circle")
            }
            .help(field.summary)
        }
    }
}

struct TranscriptPane: View {
    var project: IdeaProject
    var onUpdateTranscriptText: (String, String) -> Void = { _, _ in }
    var onUpdateTranscriptSegment: (String, String, String, Bool) -> Void = { _, _, _, _ in }
    @State private var draftText = ""

    private var trimmedDraft: String {
        draftText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedDraft.isEmpty && trimmedDraft != project.transcript.cleanText
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Clean Transcript", systemImage: "text.quote")
                            .font(.headline)
                        Spacer()
                        Button {
                            resetDraft()
                        } label: {
                            Label("Revert", systemImage: "arrow.uturn.backward")
                        }
                        .disabled(draftText == project.transcript.cleanText)
                        .controlSize(.small)
                        .accessibilityIdentifier("mac.transcript.revert")

                        Button {
                            onUpdateTranscriptText(project.id, draftText)
                        } label: {
                            Label("Save", systemImage: "checkmark.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!canSave)
                        .accessibilityIdentifier("mac.transcript.save")
                    }

                    TextEditor(text: $draftText)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 180)
                        .padding(8)
                        .macInputSurface(tint: .cyan, cornerRadius: 14)
                        .accessibilityIdentifier("mac.transcript.editor")
                }

                if !project.transcript.segments.isEmpty {
                    SectionHeader("Segments")
                    ForEach(project.transcript.segments) { segment in
                        TranscriptSegmentEditorRow(
                            projectID: project.id,
                            segment: segment,
                            onUpdateTranscriptSegment: onUpdateTranscriptSegment
                        )
                        .accessibilityIdentifier("mac.transcript.segment.\(segment.id)")
                    }
                }
            }
            .frame(maxWidth: 860, alignment: .leading)
        }
        .onAppear(perform: resetDraft)
        .onChange(of: project.id) { _, _ in
            resetDraft()
        }
        .onChange(of: project.transcript.cleanText) { _, newText in
            draftText = newText
        }
    }

    private func resetDraft() {
        draftText = project.transcript.cleanText
    }
}

private struct TranscriptSegmentEditorRow: View {
    var projectID: String
    var segment: TranscriptSegment
    var onUpdateTranscriptSegment: (String, String, String, Bool) -> Void

    @State private var draftText = ""
    @State private var isMarkedImportant = false

    private var trimmedDraft: String {
        draftText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedDraft.isEmpty && (trimmedDraft != segment.text || isMarkedImportant != segment.isMarkedImportant)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Text(timestamp(segment.startSeconds))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 54, alignment: .trailing)

                Toggle(isOn: $isMarkedImportant) {
                    Label("Important", systemImage: isMarkedImportant ? "star.fill" : "star")
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .accessibilityIdentifier("mac.transcript.segmentImportant.\(segment.id)")

                Spacer()

                Button {
                    resetDraft()
                } label: {
                    Label("Revert", systemImage: "arrow.uturn.backward")
                }
                .controlSize(.small)
                .disabled(draftText == segment.text && isMarkedImportant == segment.isMarkedImportant)
                .accessibilityIdentifier("mac.transcript.segmentRevert.\(segment.id)")

                Button {
                    onUpdateTranscriptSegment(projectID, segment.id, draftText, isMarkedImportant)
                } label: {
                    Label("Save Segment", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!canSave)
                .accessibilityIdentifier("mac.transcript.segmentSave.\(segment.id)")
            }

            TextEditor(text: $draftText)
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 74)
                .padding(8)
                .macInputSurface(tint: .cyan, cornerRadius: 12)
                .accessibilityIdentifier("mac.transcript.segmentEditor.\(segment.id)")
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isMarkedImportant ? Color.orange.opacity(0.20) : Color.cyan.opacity(0.12))
        }
        .onAppear(perform: resetDraft)
        .onChange(of: segment.id) { _, _ in
            resetDraft()
        }
        .onChange(of: segment.text) { _, newText in
            draftText = newText
        }
        .onChange(of: segment.isMarkedImportant) { _, newValue in
            isMarkedImportant = newValue
        }
    }

    private func timestamp(_ seconds: Int) -> String {
        "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }

    private func resetDraft() {
        draftText = segment.text
        isMarkedImportant = segment.isMarkedImportant
    }
}

struct QuestionsPane: View {
    var project: IdeaProject

    var body: some View {
        List(project.questions) { question in
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(question.prompt)
                        .font(.headline)
                    if question.isBlocking {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                Text(question.answer ?? "Awaiting voice or text answer")
                    .foregroundStyle(question.answer == nil ? .secondary : .primary)
            }
            .padding(.vertical, 6)
        }
    }
}

struct ArtifactsPane: View {
    var project: IdeaProject
    var onUpdateArtifactMarkdown: (String, String) -> Void = { _, _ in }

    var body: some View {
        List {
            if project.artifactHistories.isEmpty {
                ContentUnavailableView(
                    "No artifacts yet",
                    systemImage: "doc.richtext",
                    description: Text("Run a workflow or export a Codex packet to create reviewable artifacts.")
                )
            } else {
                ForEach(project.artifactHistories) { history in
                    ArtifactHistoryRow(history: history, onUpdateArtifactMarkdown: onUpdateArtifactMarkdown)
                        .accessibilityIdentifier("mac.artifactHistory.\(history.kind.rawValue)")
                }
            }
        }
    }
}

private struct ArtifactHistoryRow: View {
    var history: ArtifactHistory
    var onUpdateArtifactMarkdown: (String, String) -> Void

    @State private var draftMarkdown = ""

    private var trimmedDraft: String {
        draftMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedDraft.isEmpty && trimmedDraft != history.latest.markdown
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(history.kind.label, systemImage: "doc.richtext")
                    .font(.headline)
                Spacer()
                Text("\(history.versionCount) version\(history.versionCount == 1 ? "" : "s")")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            ArtifactVersionSummary(artifact: history.latest, prefix: "Latest")

            Text(history.latest.markdown)
                .lineLimit(5)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: $draftMarkdown)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 160)
                        .padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityIdentifier("mac.artifact.editor.\(history.latest.id)")

                    HStack {
                        Button {
                            draftMarkdown = history.latest.markdown
                        } label: {
                            Label("Revert", systemImage: "arrow.uturn.backward")
                        }
                        .controlSize(.small)
                        .disabled(draftMarkdown == history.latest.markdown)
                        .accessibilityIdentifier("mac.artifact.revert.\(history.latest.id)")

                        Spacer()

                        Button {
                            onUpdateArtifactMarkdown(history.latest.id, draftMarkdown)
                        } label: {
                            Label("Save Version", systemImage: "checkmark.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!canSave)
                        .accessibilityIdentifier("mac.artifact.save.\(history.latest.id)")
                    }
                }
                .padding(.top, 4)
            } label: {
                Label("Edit Latest", systemImage: "square.and.pencil")
                    .font(.caption.weight(.semibold))
            }

            if let diff = history.latestDiff {
                ArtifactDiffSummaryView(diff: diff)
                    .accessibilityIdentifier("mac.artifactDiff.\(history.kind.rawValue)")
            }

            if history.versions.count > 1 {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(history.versions) { artifact in
                            ArtifactVersionSummary(artifact: artifact, prefix: "v\(artifact.version)")
                                .padding(.vertical, 2)
                                .accessibilityIdentifier("mac.artifactVersion.\(artifact.id)")
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Label("Version History", systemImage: "clock.arrow.circlepath")
                        .font(.caption.weight(.semibold))
                }
            }
        }
        .padding(.vertical, 8)
        .onAppear(perform: resetDraft)
        .onChange(of: history.latest.id) { _, _ in
            resetDraft()
        }
        .onChange(of: history.latest.markdown) { _, newMarkdown in
            draftMarkdown = newMarkdown
        }
    }

    private func resetDraft() {
        draftMarkdown = history.latest.markdown
    }
}

private struct ArtifactDiffSummaryView: View {
    var diff: ArtifactDiffSummary

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(diff.lines) { line in
                    ArtifactDiffLineView(line: line)
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 8) {
                Label("Latest Changes", systemImage: "arrow.left.arrow.right")
                    .font(.caption.weight(.semibold))
                Text("v\(diff.previousVersion) -> v\(diff.currentVersion)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if diff.hasContentChanges {
                    Text("+\(diff.addedLineCount) / -\(diff.removedLineCount)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Text("No content changes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct ArtifactDiffLineView: View {
    var line: ArtifactDiffLine

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(marker)
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 14, alignment: .center)
            Text(lineNumber)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
            Text(line.text.isEmpty ? " " : line.text)
                .font(.caption.monospaced())
                .foregroundStyle(line.status == .unchanged ? .secondary : .primary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 1)
    }

    private var marker: String {
        switch line.status {
        case .unchanged: " "
        case .added: "+"
        case .removed: "-"
        }
    }

    private var color: Color {
        switch line.status {
        case .unchanged: .secondary
        case .added: .green
        case .removed: .orange
        }
    }

    private var lineNumber: String {
        switch line.status {
        case .unchanged:
            if let previousLineNumber = line.previousLineNumber,
               let newLineNumber = line.newLineNumber {
                return "\(previousLineNumber)/\(newLineNumber)"
            }
            return ""
        case .added:
            return line.newLineNumber.map { "+\($0)" } ?? "+"
        case .removed:
            return line.previousLineNumber.map { "-\($0)" } ?? "-"
        }
    }
}

private struct ArtifactVersionSummary: View {
    var artifact: Artifact
    var prefix: String

    var body: some View {
        HStack(spacing: 8) {
            Text(prefix)
                .font(.caption.monospacedDigit().weight(.semibold))
            Text(artifact.title)
                .font(.caption)
            Spacer()
            Text(artifact.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let sourceWorkflowRunID = artifact.sourceWorkflowRunID {
                Label("Workflow", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Source workflow run: \(sourceWorkflowRunID)")
            }
        }
    }
}

struct WorkflowRunsPane: View {
    var project: IdeaProject
    var onRetryWorkflow: (String) -> Void

    var body: some View {
        List {
            if project.workflowRuns.isEmpty {
                ContentUnavailableView(
                    "No workflow runs yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Run a review board, PRD, or Codex packet workflow to create auditable history.")
                )
            } else {
                ForEach(project.workflowRuns) { run in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label(run.templateName, systemImage: symbol(for: run.status))
                                .font(.headline)
                            Spacer()
                            Text(run.status.rawValue.capitalized)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(color(for: run.status))
                            if run.status == .failed {
                                Button {
                                    onRetryWorkflow(run.id)
                                } label: {
                                    Label("Retry", systemImage: "arrow.clockwise")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(!canRetry(run))
                                .accessibilityIdentifier("mac.workflowRun.retry.\(run.id)")
                                .help(retryHelp(for: run))
                            }
                        }

                        if let completedAt = run.completedAt {
                            Text("Completed \(completedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if !run.artifactIDs.isEmpty {
                            Text("\(run.artifactIDs.count) artifacts")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if let review = project.workflowRunReview(forRunID: run.id) {
                            WorkflowRunReviewCard(review: review)
                                .accessibilityIdentifier("mac.workflowRun.review.\(run.id)")
                        }

                        if run.status == .failed,
                           let errorMessage = run.errorMessage,
                           !errorMessage.isEmpty {
                            Label(errorMessage, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("mac.workflowRun.failureReason.\(run.id)")
                        }

                        if let nextRetryAt = run.nextRetryAt,
                           nextRetryAt > Date() {
                            Label("Retry scheduled \(nextRetryAt.formatted(date: .omitted, time: .shortened))", systemImage: "clock")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("mac.workflowRun.retryScheduled.\(run.id)")
                        }

                        if let evaluation = run.evaluation {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Label(evaluation.decision.label, systemImage: symbol(for: evaluation.decision))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(color(for: evaluation.decision))
                                    Spacer()
                                    Text("\(Int((evaluation.readinessScore * 100).rounded()))% ready")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                HStack(spacing: 8) {
                                    Label("Schema", systemImage: "checklist.checked")
                                        .font(.caption.weight(.semibold))
                                    Spacer()
                                    Text("\(Int((evaluation.schemaCompletenessScore * 100).rounded()))% complete")
                                        .font(.caption.monospacedDigit())
                                }
                                .foregroundStyle(schemaColor(for: evaluation))
                                HStack(spacing: 8) {
                                    Label("AI Rubric", systemImage: "sparkles")
                                        .font(.caption.weight(.semibold))
                                    Spacer()
                                    Text("\(Int((evaluation.rubricScore * 100).rounded()))% pass")
                                        .font(.caption.monospacedDigit())
                                }
                                .foregroundStyle(rubricColor(for: evaluation))
                                ForEach(evaluation.rubricItems.filter { $0.status == .failing }) { item in
                                    Text("\(item.title): \(item.summary)")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                                if !evaluation.blockers.isEmpty {
                                    ForEach(evaluation.blockers, id: \.self) { blocker in
                                        Text(blocker)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .padding(.top, 2)
                            .accessibilityIdentifier("mac.workflowRun.evaluation.\(run.id)")
                        }

                        if let comparison = project.workflowComparison(forRunID: run.id),
                           comparison.previousRunID != nil,
                           !comparison.changes.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Compared with previous run", systemImage: "arrow.left.arrow.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                ForEach(comparison.changes) { change in
                                    HStack(spacing: 8) {
                                        Image(systemName: symbol(for: change.status))
                                            .foregroundStyle(color(for: change.status))
                                        Text(change.kind.label)
                                        Spacer()
                                        Text(versionSummary(for: change))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .font(.caption)
                                }
                            }
                            .padding(.top, 2)
                            .accessibilityIdentifier("mac.workflowRun.comparison.\(run.id)")
                        }

                        ForEach(run.stepRuns) { step in
                            HStack(spacing: 8) {
                                Image(systemName: symbol(for: step.status))
                                    .foregroundStyle(color(for: step.status))
                                Text(step.stepName)
                                Spacer()
                                Text(step.status.rawValue.capitalized)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .font(.callout)
                        }
                    }
                    .padding(.vertical, 8)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func symbol(for decision: WorkflowEvaluationDecision) -> String {
        switch decision {
        case .ready: "checkmark.seal.fill"
        case .needsReview: "doc.text.magnifyingglass"
        case .blocked: "exclamationmark.octagon.fill"
        }
    }

    private func color(for decision: WorkflowEvaluationDecision) -> Color {
        switch decision {
        case .ready: .green
        case .needsReview: .blue
        case .blocked: .orange
        }
    }

    private func schemaColor(for evaluation: WorkflowRunEvaluation) -> Color {
        evaluation.schemaIssues.isEmpty ? .secondary : .orange
    }

    private func rubricColor(for evaluation: WorkflowRunEvaluation) -> Color {
        evaluation.rubricItems.contains { $0.status == .failing } ? .orange : .secondary
    }

    private func canRetry(_ run: WorkflowRun) -> Bool {
        guard run.status == .failed else { return false }
        guard let nextRetryAt = run.nextRetryAt else { return true }
        return nextRetryAt <= Date()
    }

    private func retryHelp(for run: WorkflowRun) -> String {
        guard let nextRetryAt = run.nextRetryAt, nextRetryAt > Date() else {
            return "Retry this failed workflow run"
        }
        return "Retry is scheduled for \(nextRetryAt.formatted(date: .abbreviated, time: .shortened))"
    }

    private func symbol(for status: WorkflowArtifactChangeStatus) -> String {
        switch status {
        case .added: "plus.circle.fill"
        case .updated: "arrow.triangle.2.circlepath.circle.fill"
        case .unchanged: "equal.circle.fill"
        case .removed: "minus.circle.fill"
        }
    }

    private func color(for status: WorkflowArtifactChangeStatus) -> Color {
        switch status {
        case .added: .green
        case .updated: .blue
        case .unchanged: .secondary
        case .removed: .orange
        }
    }

    private func versionSummary(for change: WorkflowArtifactChange) -> String {
        switch (change.previousVersion, change.currentVersion) {
        case let (.some(previous), .some(current)):
            return "v\(previous) -> v\(current)"
        case let (nil, .some(current)):
            return "new v\(current)"
        case let (.some(previous), nil):
            return "removed v\(previous)"
        case (nil, nil):
            return change.status.rawValue.capitalized
        }
    }

    private func symbol(for status: WorkflowRunStatus) -> String {
        switch status {
        case .running: "clock"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private func color(for status: WorkflowRunStatus) -> Color {
        switch status {
        case .running: .secondary
        case .completed: .green
        case .failed: .orange
        }
    }
}

private struct WorkflowRunReviewCard: View {
    var review: WorkflowRunReview

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label(review.decision.label, systemImage: symbol(for: review.decision))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color(for: review.decision))
                Spacer()
                Text("\(Int((review.readinessScore * 100).rounded()))% ready")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Label("\(review.artifactCount) artifacts", systemImage: "doc.richtext")
                if review.missingArtifactCount > 0 {
                    Label("\(review.missingArtifactCount) missing", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 8)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(review.provenanceSummary)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)

            if !review.blockerSummaries.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(review.blockerSummaries.prefix(3), id: \.self) { blocker in
                        Label(blocker, systemImage: "exclamationmark.octagon")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityIdentifier("mac.workflowRun.review.blockers.\(review.runID)")
            }

            if !review.warningSummaries.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(review.warningSummaries.prefix(2), id: \.self) { warning in
                        Label(warning, systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityIdentifier("mac.workflowRun.review.warnings.\(review.runID)")
            }

            if !review.artifactChangeSummaries.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Artifact changes", systemImage: "arrow.left.arrow.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(review.artifactChangeSummaries.prefix(4), id: \.self) { change in
                        Text(change)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .accessibilityIdentifier("mac.workflowRun.review.artifactChanges.\(review.runID)")
            }

            if let retrySummary = review.retrySummary {
                Label(retrySummary, systemImage: review.canRetry ? "arrow.clockwise.circle" : "clock")
                    .font(.caption)
                    .foregroundStyle(review.canRetry ? .blue : .secondary)
                    .accessibilityIdentifier("mac.workflowRun.review.retry.\(review.runID)")
            }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(color(for: review.decision).opacity(0.18))
        }
    }

    private func symbol(for decision: WorkflowEvaluationDecision) -> String {
        switch decision {
        case .ready: "checkmark.seal.fill"
        case .needsReview: "doc.text.magnifyingglass"
        case .blocked: "exclamationmark.octagon.fill"
        }
    }

    private func color(for decision: WorkflowEvaluationDecision) -> Color {
        switch decision {
        case .ready: .green
        case .needsReview: .blue
        case .blocked: .orange
        }
    }
}

struct CodexPane: View {
    var project: IdeaProject
    private let packet: EngineeringPacket
    private let review: CodexHandoffReview

    init(project: IdeaProject) {
        self.project = project
        packet = EngineeringPacketBuilder.packet(for: project)
        review = EngineeringPacketBuilder.handoffReview(for: project)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Export-only Codex Handoff", systemImage: "shippingbox")
                        .font(.title2.weight(.semibold))
                    Text("Review the packet before local export. This surface does not launch Codex, write to GitHub, or call remote integrations.")
                        .foregroundStyle(.secondary)
                }

                CodexHandoffSummaryCard(review: review)
                    .accessibilityIdentifier("mac.codex.review.summary")

                if !review.blockers.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader("Blockers")
                        ForEach(review.blockers, id: \.self) { blocker in
                            Label(blocker, systemImage: "exclamationmark.triangle")
                                .font(.callout)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityIdentifier("mac.codex.review.blockers")
                }

                SectionHeader("Review Checks")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    CodexReviewCheckTile(
                        title: "Approval Boundary",
                        isPassing: review.hasApprovalBoundary,
                        detail: "No Codex or remote write without operator approval."
                    )
                    CodexReviewCheckTile(
                        title: "Acceptance Tests",
                        isPassing: review.hasAcceptanceTests,
                        detail: "Packet includes testable acceptance coverage."
                    )
                    CodexReviewCheckTile(
                        title: "Codex Instructions",
                        isPassing: review.hasCodexInstructions,
                        detail: "Packet includes local execution instructions."
                    )
                    CodexReviewCheckTile(
                        title: "Security Notes",
                        isPassing: review.hasSecurityNotes,
                        detail: "Packet calls out privacy and credential boundaries."
                    )
                }

                SectionHeader("Packet Files")
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(packet.files) { file in
                        DisclosureGroup {
                            Text(file.contents)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 4)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: file.path.hasPrefix("tasks/") ? "checklist" : "doc.text")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)
                                Text(file.path)
                                    .font(.headline.monospaced())
                                    .lineLimit(1)
                                Spacer()
                                Text("\(file.contents.count) chars")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityIdentifier("mac.codex.packetFile.\(file.path)")
                    }
                }
            }
            .frame(maxWidth: 980, alignment: .leading)
        }
    }
}

private struct CodexHandoffSummaryCard: View {
    var review: CodexHandoffReview

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Label(
                review.isReadyForExportOnlyHandoff ? "Ready for Export Review" : "Needs Review",
                systemImage: review.isReadyForExportOnlyHandoff ? "checkmark.seal" : "exclamationmark.triangle"
            )
            .font(.headline)
            .foregroundStyle(review.isReadyForExportOnlyHandoff ? .green : .orange)

            Spacer()

            CodexHandoffMetric(title: "Files", value: "\(review.fileCount)")
            CodexHandoffMetric(title: "Tasks", value: "\(review.taskCount)")
            CodexHandoffMetric(title: "Blocking Qs", value: "\(review.blockingQuestionCount)")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct CodexHandoffMetric: View {
    var title: String
    var value: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(value)
                .font(.headline.monospacedDigit())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 72, alignment: .trailing)
    }
}

private struct CodexReviewCheckTile: View {
    var title: String
    var isPassing: Bool
    var detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: isPassing ? "checkmark.circle.fill" : "xmark.circle")
                .font(.headline)
                .foregroundStyle(isPassing ? .green : .red)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct SectionHeader: View {
    var title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.secondary)
    }
}
