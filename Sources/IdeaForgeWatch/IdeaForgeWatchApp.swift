import SwiftUI

@main
struct IdeaForgeWatchApp: App {
    @State private var store: IdeaForgeStore
    private let recordingTransferService: any RecordingTransferService
    private let usesAccessibilityFixture: Bool

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let fixtureState: WatchRelayFixtureState? = {
            if arguments.contains("-uiTestingWatchQueued") { return .queued }
            if arguments.contains("-uiTestingWatchReceived") { return .received }
            if arguments.contains("-uiTestingWatchFailed") { return .failed }
            if arguments.contains("-uiTestingWatchReady") { return .ready }
            return nil
        }()
        let store = fixtureState.map(SampleData.watchRelayStore) ?? IdeaForgeStore.production()
        _store = State(initialValue: store)
        let service: any RecordingTransferService = fixtureState == nil
            ? RecordingTransferServiceFactory.platformDefault()
            : UnavailableRecordingTransferService()
        recordingTransferService = service
        usesAccessibilityFixture = arguments.contains("-uiTestingAccessibilityXXXL")
        service.setReachabilityHandler { isReachable in
            store.syncHealth.watchReachable = isReachable
        }
        service.setTransferCompletionHandler { recordingID, imported in
            if imported {
                _ = store.markRecordingTransferredToIPhone(recordingID: recordingID)
            } else {
                _ = store.markRecordingWatchTransferFailed(recordingID: recordingID)
            }
        }
        service.setEnrichmentProjectionHandler { projection in
            let appliedCount = store.apply(projection)
            IdeaForgeLog.sync.info("Watch enrichment projection applied; count: \(appliedCount, privacy: .public)")
        }
        service.activate()
    }

    var body: some Scene {
        WindowGroup {
            WatchCaptureView(store: store, transferService: recordingTransferService)
                .environment(\.dynamicTypeSize, usesAccessibilityFixture ? .accessibility5 : .medium)
                .onAppear {
                    IdeaForgeLog.lifecycle.notice("watchOS app appeared")
                }
        }
    }
}
