import XCTest
@testable import IdeaForgeCore

final class IdeaAgentTests: XCTestCase {
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

