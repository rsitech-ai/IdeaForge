import SwiftUI
import AppKit
import Observation

enum MacSettingsDestination: Equatable {
    case syncConflictResolver
}

@Observable
final class MacNavigationState {
    var settingsDestination: MacSettingsDestination?
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        applyUITestingWindowPresetIfNeeded()
        IdeaForgeLog.lifecycle.notice("macOS app launched")
    }

    private func applyUITestingWindowPresetIfNeeded() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-uiTesting") else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard let window = NSApp.windows.first else { return }
            let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 900)
            let targetSize: NSSize
            if arguments.contains("-uiTestingCompactWindow") {
                targetSize = NSSize(width: 763, height: 752)
            } else if arguments.contains("-uiTestingWideWindow") {
                targetSize = NSSize(
                    width: min(1_440, visibleFrame.width),
                    height: min(860, visibleFrame.height)
                )
            } else {
                targetSize = NSSize(width: 1180, height: 760)
            }
            let targetOrigin = NSPoint(
                x: visibleFrame.minX,
                y: max(visibleFrame.minY, visibleFrame.maxY - targetSize.height)
            )
            window.setFrame(NSRect(origin: targetOrigin, size: targetSize), display: true)
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
            if arguments.contains("-uiTestingWideWindow") {
                window.setAccessibilityIdentifier("mac.uiTesting.windowPreset.wide.applied")
            }
        }
    }
}

@main
struct IdeaForgeMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: IdeaForgeStore
    @State private var navigationState = MacNavigationState()
    private let appUpdater: AppUpdater

    init() {
        let startingUpdater = !ProcessInfo.processInfo.arguments.contains("-uiTesting")
        appUpdater = AppUpdater(startingUpdater: startingUpdater)
        _store = State(initialValue: Self.makeStore())
    }

    var body: some Scene {
        WindowGroup("IdeaForge") {
            MacContentView(store: store, navigationState: navigationState)
                .frame(minWidth: 760, minHeight: 640)
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandMenu("IdeaForge") {
                Button("Check for Updates…") {
                    appUpdater.checkForUpdates()
                }

                Button("Generate Codex Packet") {
                    IdeaForgeLog.export.info("macOS command requested Codex packet preparation")
                    Task {
                        await store.prepareCodexPacket()
                    }
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])

                Button("Export Codex Packet") {
                    IdeaForgeLog.export.info("macOS command requested Codex packet export")
                    Task {
                        await store.exportCodexPacket()
                        if let url = store.lastExportedPacketURL {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                }
                .keyboardShortcut("e", modifiers: [.command, .option])
            }
        }

        Settings {
            SettingsView(store: store, navigationState: navigationState)
        }
    }

    private static func makeStore() -> IdeaForgeStore {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-uiTestingStatusSyncConflict") {
            return SampleData.taskFirstStore(state: .syncConflict)
        }
        if arguments.contains("-uiTestingStatusFailedUpload") {
            return SampleData.taskFirstStore(state: .failedUpload)
        }
        if arguments.contains("-uiTestingStatusQueuedUpload") {
            return SampleData.taskFirstStore(state: .queuedUpload)
        }
        if arguments.contains("-uiTestingStatusOffline") {
            return SampleData.taskFirstStore(state: .offlineWatch)
        }
        if arguments.contains("-uiTesting") {
            return SampleData.store()
        }
        return .production()
    }
}
