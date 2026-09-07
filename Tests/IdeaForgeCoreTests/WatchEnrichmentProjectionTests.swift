import Foundation
import XCTest
@testable import IdeaForgeCore

@MainActor
final class WatchEnrichmentProjectionTests: XCTestCase {
    func testProjectionContainsOnlyWatchTitleAndProcessingState() throws {
        let now = Date(timeIntervalSince1970: 20_000)
        let recording = Recording(
            id: "rec_watch_ready",
            ideaProjectID: "idea_watch_ready",
            deviceName: "Apple Watch",
            durationSeconds: 12,
            localFileStatus: .uploaded,
            syncStatus: .ready,
            audioObjectKey: "recordings/rec_watch_ready.m4a",
            languageHint: "en",
            createdAt: now,
            markerOffsets: []
        )
        let project = IdeaProject(
            id: "idea_watch_ready",
            title: "Private Focus Timer",
            status: .inbox,
            source: .watch,
            createdAt: now,
            updatedAt: now,
            summary: "This must never be copied to Watch.",
            tags: [.appIdea],
            score: IdeaScore(confidence: 0.8, completeness: 0.7, risk: 0.2),
            transcript: Transcript(
                cleanText: "A complete transcript that must remain on iPhone and Mac.",
                segments: [],
                unclearFragments: []
            ),
            recordings: [recording],
            questions: [],
            artifacts: [],
            assumptions: [],
            validationExperiments: [],
            codexTasks: []
        )

        let projection = WatchEnrichmentProjection(projects: [project], updatedAt: now)

        XCTAssertEqual(
            projection.items,
            [
                WatchEnrichmentProjectionItem(
                    recordingID: recording.id,
                    ideaProjectID: project.id,
                    title: project.title,
                    state: .ready,
                    updatedAt: now
                )
            ]
        )
        let serialized = String(data: try JSONEncoder().encode(projection), encoding: .utf8) ?? ""
        XCTAssertFalse(serialized.contains(project.transcript.cleanText))
        XCTAssertFalse(serialized.contains(project.summary))
    }

    func testProjectionRoundTripsApplicationContextAndRejectsOversizedTitle() {
        let item = WatchEnrichmentProjectionItem(
            recordingID: "rec_1",
            ideaProjectID: "idea_1",
            title: "Offline Maps for Hikers",
            state: .processing,
            updatedAt: Date(timeIntervalSince1970: 30_000)
        )
        let projection = WatchEnrichmentProjection(
            items: [item],
            updatedAt: Date(timeIntervalSince1970: 30_000)
        )

        XCTAssertEqual(
            WatchEnrichmentProjection(applicationContext: projection.applicationContext),
            projection
        )

        var invalidContext = projection.applicationContext
        invalidContext["payload"] = Data(repeating: 65, count: 70_000)
        XCTAssertNil(WatchEnrichmentProjection(applicationContext: invalidContext))
    }

    func testStoreAppliesNewerProjectedTitleWithoutTranscript() {
        let store = SampleData.watchRelayStore(state: .received)
        guard let project = store.projects.first,
              let recording = project.recordings.first else {
            XCTFail("Watch fixture needs one project and recording")
            return
        }
        let originalTranscript = project.transcript
        let now = project.updatedAt.addingTimeInterval(60)
        let projection = WatchEnrichmentProjection(
            items: [
                WatchEnrichmentProjectionItem(
                    recordingID: recording.id,
                    ideaProjectID: project.id,
                    title: "A Better Watch Capture",
                    state: .ready,
                    updatedAt: now
                )
            ],
            updatedAt: now
        )

        XCTAssertEqual(store.apply(projection), 1)
        XCTAssertEqual(store.projects.first?.title, "A Better Watch Capture")
        XCTAssertEqual(store.projects.first?.transcript, originalTranscript)
        XCTAssertEqual(store.projects.first?.recordings.first?.syncStatus, .ready)

        let stale = WatchEnrichmentProjection(
            items: [WatchEnrichmentProjectionItem(
                recordingID: recording.id,
                ideaProjectID: project.id,
                title: "Stale title",
                state: .needsAttention,
                updatedAt: now.addingTimeInterval(-1)
            )],
            updatedAt: now.addingTimeInterval(120)
        )
        XCTAssertEqual(store.apply(stale), 0)
        XCTAssertEqual(store.projects.first?.title, "A Better Watch Capture")
        XCTAssertEqual(store.projects.first?.recordings.first?.syncStatus, .ready)
    }
}
