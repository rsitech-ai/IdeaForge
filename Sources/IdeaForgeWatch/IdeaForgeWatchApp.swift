import SwiftUI

@main
struct IdeaForgeWatchApp: App {
    @State private var store: IdeaForgeStore
    private let recordingTransferService: any RecordingTransferService

    init() {
        let store = IdeaForgeStore.production()
        _store = State(initialValue: store)
        let service = RecordingTransferServiceFactory.platformDefault()
        recordingTransferService = service
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
        service.activate()
    }

    var body: some Scene {
        WindowGroup {
            WatchCaptureView(store: store, transferService: recordingTransferService)
                .onAppear {
                    IdeaForgeLog.lifecycle.notice("watchOS app appeared")
                }
        }
    }
}
