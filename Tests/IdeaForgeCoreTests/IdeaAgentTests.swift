import XCTest
@testable import IdeaForgeCore

final class IdeaAgentTests: XCTestCase {
    func testFoundationAgentUsesRetrievedEvidenceAndPreservesCitations() async {
        let agent = SystemFoundationIdeaAgent(
            availability: { .available },
            generation: { request in
                XCTAssertTrue(request.evidence.contains("IdeaForge"))
                XCTAssertTrue(request.evidence.contains("Transcript") || request.evidence.contains("Question"))
                return "Start with the builder interview because the local workspace identifies it as the next validation step."
            }
        )

        let response = await agent.respond(
            to: "What should I validate next?",
            projects: WorkspaceState.seed().projects
        )

        XCTAssertEqual(response.generationMode, .foundationModel)
        XCTAssertFalse(response.citations.isEmpty)
        XCTAssertTrue(response.answer.contains("builder interview"))
    }

    func testFoundationAgentFallsBackTruthfullyWhenModelIsUnavailable() async {
        let agent = SystemFoundationIdeaAgent(
            availability: { .deviceNotEligible },
            generation: { _ in XCTFail("Unavailable model must not generate"); return "" }
        )

        let response = await agent.respond(
            to: "What should I validate next?",
            projects: WorkspaceState.seed().projects
        )

        XCTAssertEqual(response.generationMode, .localRetrieval)
        XCTAssertTrue(response.answer.contains("Based on local idea context"))
        XCTAssertFalse(response.citations.isEmpty)
    }

    func testRespondsWithGroundedCitationForKnownIdeaQuestion() {
        let state = WorkspaceState.seed()
        let response = LocalIdeaAgent().respond(
            to: "Who is the first user who needs this badly enough to pay?",
            projects: state.projects
        )

        XCTAssertTrue(response.answer.contains("IdeaForge"))
        XCTAssertTrue(response.answer.contains("Evidence:"))
        XCTAssertTrue(response.citations.contains { citation in
            citation.projectTitle == "IdeaForge"
                && citation.sourceTitle.localizedCaseInsensitiveContains("Question")
        })
        XCTAssertFalse(response.suggestedPrompts.isEmpty)
    }

    func testDoesNotInventWhenNoLocalContextMatches() {
        let state = WorkspaceState.seed()
        let response = LocalIdeaAgent().respond(
            to: "quantum banana warehouse forecast",
            projects: state.projects
        )

        XCTAssertTrue(response.answer.contains("could not find a strong local match"))
        XCTAssertTrue(response.citations.isEmpty)
        XCTAssertEqual(response.suggestedPrompts.count, 3)
    }

    func testEmptyWorkspaceExplainsHowToStart() {
        let response = LocalIdeaAgent().respond(
            to: "What should I build?",
            projects: []
        )

        XCTAssertTrue(response.answer.contains("no local ideas"))
        XCTAssertTrue(response.citations.isEmpty)
    }
}
