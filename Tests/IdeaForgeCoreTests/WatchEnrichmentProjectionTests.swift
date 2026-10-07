import Foundation
import XCTest
@testable import IdeaForgeCore

@MainActor
final class WatchEnrichmentProjectionTests: XCTestCase {
    func testLateImportAcknowledgementDoesNotDowngradeEnrichedRecording() throws {
        for state in [WatchEnrichmentState.processing, .ready, .needsAttention] {
            let store = SampleData.watchRelayStore(state: .received)
            let project = try XCTUnwrap(store.projects.first)
            let recording = try XCTUnwrap(project.recordings.first)
            let revision = project.updatedAt.addingTimeInterval(60)
            let projection = WatchEnrichmentProjection(
                items: [.init(recordingID: recording.id, ideaProjectID: project.id,
                              title: "Enriched capture", state: state, updatedAt: revision)],
                updatedAt: revision
            )
            XCTAssertEqual(store.apply(projection), 1)
            let enrichedStatus = store.projects[0].recordings[0].syncStatus
            XCTAssertTrue(store.markRecordingTransferredToIPhone(
                recordingID: recording.id, now: revision.addingTimeInterval(1)
            ))
            XCTAssertEqual(store.projects[0].recordings[0].syncStatus, enrichedStatus)
            XCTAssertEqual(store.projects[0].title, "Enriched capture")
            XCTAssertEqual(store.projects[0].updatedAt, revision)
        }
    }

    func testImportReceiptWithAheadClockDoesNotRejectFirstRemoteProjection() throws {
        let store = SampleData.watchRelayStore(state: .received)
        let recording = try XCTUnwrap(store.projects.first?.recordings.first)
        let revision = store.projects[0].updatedAt.addingTimeInterval(60)
        XCTAssertTrue(store.markRecordingTransferredToIPhone(recordingID: recording.id,
                                                            now: revision.addingTimeInterval(600)))
        let projection = WatchEnrichmentProjection(
            items: [.init(recordingID: recording.id, ideaProjectID: recording.ideaProjectID,
                          title: "Remote title", state: .ready, updatedAt: revision)],
            updatedAt: revision
        )
        XCTAssertEqual(store.apply(projection), 1)
        XCTAssertEqual(store.projects[0].recordings[0].syncStatus, .ready)
        let persisted = try JSONDecoder().decode(WorkspaceState.self,
                                                from: JSONEncoder().encode(store.workspaceState()))
        XCTAssertEqual(persisted.projects[0].recordings[0].watchEnrichmentUpdatedAt, revision)
        let outbound = WorkspaceSyncPayloadPolicy.outboundState(from: persisted)
        XCTAssertNil(outbound.projects[0].recordings[0].watchEnrichmentUpdatedAt)
        let restored = IdeaForgeStore(state: persisted)
        var stale = projection
        stale.items[0].updatedAt = revision.addingTimeInterval(-1)
        stale.items[0].state = .waiting
        XCTAssertEqual(restored.apply(stale), 0)
        XCTAssertEqual(restored.projects[0].recordings[0].syncStatus, .ready)
    }

    func testEqualRevisionReplayCannotDowngradeStatusOrReplaceTitle() throws {
        let store = SampleData.watchRelayStore(state: .received)
        let recording = try XCTUnwrap(store.projects.first?.recordings.first)
        let revision = store.projects[0].updatedAt.addingTimeInterval(60)
        var projection = WatchEnrichmentProjection(
            items: [.init(recordingID: recording.id, ideaProjectID: recording.ideaProjectID,
                          title: "Final title", state: .ready, updatedAt: revision)],
            updatedAt: revision
        )
        XCTAssertEqual(store.apply(projection), 1)
        projection.items[0].state = .processing
        projection.items[0].title = "Stale title"
        XCTAssertEqual(store.apply(projection), 0)
        XCTAssertEqual(store.projects[0].recordings[0].syncStatus, .ready)
        XCTAssertEqual(store.projects[0].title, "Final title")
    }

    func testOlderOtherRecordingUpdatesItsStatusWithoutReplacingSharedTitle() throws {
        let store = SampleData.watchRelayStore(state: .received)
        let recording = try XCTUnwrap(store.projects.first?.recordings.first)
        var second = recording
        second.id = "rec_second_projection"
        store.projects[0].recordings.append(second)
        let revision = store.projects[0].updatedAt.addingTimeInterval(60)
        let projection = WatchEnrichmentProjection(
            items: [
                .init(recordingID: recording.id, ideaProjectID: recording.ideaProjectID,
                      title: "Newest shared title", state: .ready, updatedAt: revision),
                .init(recordingID: second.id, ideaProjectID: second.ideaProjectID,
                      title: "Older shared title", state: .processing,
                      updatedAt: revision.addingTimeInterval(-1))
            ], updatedAt: revision
        )
        XCTAssertEqual(store.apply(projection), 2)
        XCTAssertEqual(store.projects[0].title, "Newest shared title")
        XCTAssertEqual(store.projects[0].recordings[0].syncStatus, .ready)
        XCTAssertEqual(store.projects[0].recordings.last?.syncStatus, .transcribing)
    }

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
