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
            let preset = arguments.contains("-uiTestingWideWindow") ? "wide"
                : (arguments.contains("-uiTestingCompactWindow") ? "compact" : "default")
            window.setAccessibilityIdentifier("mac.uiTesting.windowPreset.\(preset).applied")
        }
    }
}

actor MacLocalBackendRuntimeController: LocalBackendRuntimeControlling {
    func checkReadiness(baseURL: URL) async -> LocalBackendReadiness {
        let readinessURL = baseURL.appendingPathComponent("health/ready")
        var request = URLRequest(url: readinessURL)
        request.timeoutInterval = 3
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let payload = try? JSONDecoder().decode(ReadinessPayload.self, from: data),
                  payload.status == "ready" else {
                return .unavailable(.invalidResponse)
            }
            return .ready
        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                return .unavailable(.timeout)
            case .serverCertificateUntrusted,
                 .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid,
                 .secureConnectionFailed:
                return .unavailable(.certificateUntrusted)
            default:
                return .unavailable(.connectivity)
            }
        } catch {
            return .unavailable(.connectivity)
        }
    }

    func recoverInstalledService() async -> LocalBackendRecoveryResult {
        // App Sandbox cannot invoke launchctl. The installed LaunchAgent owns
        // RunAtLoad/KeepAlive recovery; give it one bounded restart window.
        try? await Task.sleep(for: .milliseconds(700))
        return .started
    }

    private struct ReadinessPayload: Decodable {
        var status: String
    }
}

@MainActor
protocol MacLocalBackendEndpointDiscovering {
    func discoverEndpoint() async -> URL?
}

@MainActor
final class MacLocalBackendBonjourDiscovery: NSObject,
    @preconcurrency NetServiceBrowserDelegate,
    @preconcurrency NetServiceDelegate,
    MacLocalBackendEndpointDiscovering {
    private var browser: NetServiceBrowser?
    private var resolvingServices = [NetService]()
    private var continuation: CheckedContinuation<URL?, Never>?
    private var timeoutTask: Task<Void, Never>?

    func discoverEndpoint() async -> URL? {
        guard continuation == nil else { return nil }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            let browser = NetServiceBrowser()
            browser.delegate = self
            self.browser = browser
            browser.searchForServices(ofType: "_ideaforge._tcp.", inDomain: "local.")
            timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.finish(with: nil)
            }
        }
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        resolvingServices.append(service)
        service.delegate = self
        service.resolve(withTimeout: 2)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let hostName = sender.hostName,
              sender.port > 0,
              let endpoint = LocalBackendDiscoveredEndpointPolicy.endpoint(
                hostName: hostName,
                port: sender.port
              ) else {
            return
        }
        finish(with: endpoint)
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didNotSearch errorDict: [String: NSNumber]
    ) {
        finish(with: nil)
    }

    private func finish(with endpoint: URL?) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        browser?.stop()
        browser = nil
        resolvingServices.forEach { $0.stop() }
        resolvingServices.removeAll()
        continuation.resume(returning: endpoint)
    }
}

@MainActor
@Observable
final class MacLocalBackendLifecycleModel {
    private(set) var isVisible = false
    private(set) var isReady = false
    private(set) var isChecking = false
    private(set) var statusMessage = "Local Backend is not configured."
    private var isProcessingEnrichment = false

    func start(
        store: IdeaForgeStore,
        configurationManager: BackendConfigurationManager,
        discovery: any MacLocalBackendEndpointDiscovering = MacLocalBackendBonjourDiscovery()
    ) async {
        guard !isReady, !isChecking else { return }

        do {
            var settings = try configurationManager.loadSettings()
            let isConfiguredLocalBackend = settings.isEnabled
                && settings.connectionKind == .localBackend
                && settings.normalizedBaseURL.map(BackendEndpointPolicy.allowsLocalBackend) == true

            if !isConfiguredLocalBackend {
                let arguments = ProcessInfo.processInfo.arguments
                guard Self.shouldAutoDiscover(settings: settings, arguments: arguments) else { return }
                isVisible = true
                isChecking = true
                statusMessage = "Looking for Local Backend…"
                guard let discoveredEndpoint = await discovery.discoverEndpoint() else {
                    isVisible = false
                    isChecking = false
                    return
                }

                settings.baseURLString = discoveredEndpoint.absoluteString
                settings.connectionKind = .localBackend
                try configurationManager.settingsStore.saveSettings(settings)
                let outcome = await LocalBackendSupervisor(
                    runtime: MacLocalBackendRuntimeController()
                ).start(baseURL: discoveredEndpoint)
                isChecking = false
                statusMessage = outcome.userFacingMessage
                guard case .ready = outcome else { return }
                isReady = true
                statusMessage = "Local Backend found and ready. Pair in Settings."
                IdeaForgeLog.sync.notice("macOS discovered a ready Local Backend")
                return
            }

            isVisible = true

            guard let baseURL = settings.normalizedBaseURL,
                  BackendEndpointPolicy.allowsLocalBackend(baseURL) else {
                statusMessage = "Local Backend needs a valid private-LAN HTTPS address."
                return
            }

            if ProcessInfo.processInfo.arguments.contains("-uiTesting")
                && !ProcessInfo.processInfo.arguments.contains("-uiTestingLiveLocalBackend") {
                isReady = true
                statusMessage = "Local Backend is ready."
                return
            }

            isChecking = true
            statusMessage = "Checking Local Backend…"
            let outcome = await LocalBackendSupervisor(
                runtime: MacLocalBackendRuntimeController()
            ).start(baseURL: baseURL)
            isChecking = false
            statusMessage = outcome.userFacingMessage

            guard case .ready = outcome else {
                IdeaForgeLog.sync.warning("macOS Local Backend supervision completed without readiness")
                return
            }
            isReady = true
            IdeaForgeLog.sync.notice("macOS Local Backend supervision reports ready")

            let syncResult = await ConfiguredWorkspaceAutoSyncProcessor(
                backendConfigurationManager: configurationManager
            ).publishLocalSnapshotIfNeeded(from: store)
            switch syncResult {
            case .published:
                statusMessage = "Local Backend is ready. Workspace synchronized."
            case .idle:
                statusMessage = "Local Backend is ready. Workspace is current."
            case .skipped(_, let message):
                statusMessage = "Local Backend is ready. \(message)"
            }
        } catch {
            isChecking = false
            isVisible = true
            statusMessage = "Local Backend settings could not be read."
            IdeaForgeLog.sync.error("macOS Local Backend supervision could not load settings")
        }
    }

    private static func shouldAutoDiscover(
        settings: BackendConnectionSettings,
        arguments: [String]
    ) -> Bool {
        let isPristine = !settings.isEnabled
            && settings.baseURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && settings.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard isPristine else { return false }
        return !arguments.contains("-uiTesting")
            || arguments.contains("-uiTestingLiveBonjourDiscovery")
    }

    func processPendingRecordings(
        store: IdeaForgeStore,
        configurationManager: BackendConfigurationManager
    ) async {
        guard isReady, !isProcessingEnrichment, store.privacyMode != .privateLocal else { return }
        isProcessingEnrichment = true
        defer { isProcessingEnrichment = false }

        do {
            guard let authConfiguration = try configurationManager.resolvedAuthConfiguration(),
                  let syncConfiguration = try configurationManager.resolvedSyncConfiguration(),
                  let enrichmentConfiguration = try configurationManager.resolvedEnrichmentConfiguration() else {
                return
            }
            let session = try await BackendAuthSessionClient(configuration: authConfiguration)
                .validateSession()
            let capability = BackendCapabilityGate(session: session).decision(
                requiredCapabilities: [.syncWorkspace, .processRecordings],
                expectedWorkspaceID: authConfiguration.workspaceID
            )
            guard capability.isAllowed else {
                statusMessage = "Local Backend is ready. Update it to enable Mac transcription."
                return
            }

            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            let stagingDirectory = applicationSupport
                .appendingPathComponent("IdeaForge", isDirectory: true)
                .appendingPathComponent("EnrichmentStaging", isDirectory: true)
            let processor = MacRecordingEnrichmentProcessor(
                backend: BackendEnrichmentClient(configuration: enrichmentConfiguration),
                workspaceSynchronizer: WorkspaceSyncEngine(
                    client: BackendWorkspaceSyncClient(configuration: syncConfiguration)
                ),
                services: .localSpeech,
                stagingDirectory: stagingDirectory
            )
            let summary = await MacRecordingEnrichmentLoop(
                processor: processor,
                maxJobsPerRun: 4
            ).run(in: store)
            if summary.completedCount > 0 {
                statusMessage = summary.completedCount == 1
                    ? "Local Backend is ready. One recording transcribed and synchronized."
                    : "Local Backend is ready. \(summary.completedCount) recordings transcribed and synchronized."
                IdeaForgeLog.workflow.notice("macOS automatic enrichment completed; count: \(summary.completedCount, privacy: .public)")
            } else if summary.failedCount > 0 {
                statusMessage = "Local Backend is ready. One recording needs transcription attention."
                IdeaForgeLog.workflow.warning("macOS automatic enrichment stopped on a retryable or reviewable item")
            }
        } catch {
            isReady = false
            statusMessage = "Local Backend connection needs attention. Automatic transcription will retry."
            IdeaForgeLog.workflow.warning("macOS automatic enrichment could not start")
        }
    }
}

@main
struct IdeaForgeMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: IdeaForgeStore
    @State private var navigationState = MacNavigationState()
    @State private var backendLifecycle = MacLocalBackendLifecycleModel()
    private let appUpdater: AppUpdater
    private let backendConfigurationManager: BackendConfigurationManager

    init() {
        let startingUpdater = !ProcessInfo.processInfo.arguments.contains("-uiTesting")
        appUpdater = AppUpdater(startingUpdater: startingUpdater)
        backendConfigurationManager = Self.makeBackendConfigurationManager()
        _store = State(initialValue: Self.makeStore())
    }

    var body: some Scene {
        WindowGroup("IdeaForge") {
            MacContentView(
                store: store,
                navigationState: navigationState,
                backendConfigurationManager: backendConfigurationManager,
                backendLifecycle: backendLifecycle
            )
                .frame(minWidth: 760, minHeight: 640)
                .task {
                    while !Task.isCancelled {
                        await backendLifecycle.start(
                            store: store,
                            configurationManager: backendConfigurationManager
                        )
                        await backendLifecycle.processPendingRecordings(
                            store: store,
                            configurationManager: backendConfigurationManager
                        )
                        try? await Task.sleep(for: .seconds(30))
                    }
                }
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
            SettingsView(
                store: store,
                navigationState: navigationState,
                backendConfigurationManager: backendConfigurationManager
            )
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

    private static func makeBackendConfigurationManager() -> BackendConfigurationManager {
        if ProcessInfo.processInfo.arguments.contains("-uiTestingLiveBonjourDiscovery") {
            return BackendConfigurationManager(
                settingsStore: InMemoryBackendSettingsStore(),
                credentialStore: InMemoryBackendCredentialStore()
            )
        }
        if ProcessInfo.processInfo.arguments.contains("-uiTestingLiveLocalBackend"),
           let liveURL = ProcessInfo.processInfo.environment["IDEAFORGE_UI_TEST_LIVE_BACKEND_URL"],
           !liveURL.isEmpty {
            return BackendConfigurationManager(
                settingsStore: InMemoryBackendSettingsStore(
                    settings: BackendConnectionSettings(
                        baseURLString: liveURL,
                        workspaceID: "workspace_rsi",
                        isEnabled: true,
                        connectionKind: .localBackend
                    )
                ),
                credentialStore: InMemoryBackendCredentialStore()
            )
        }
        guard ProcessInfo.processInfo.arguments.contains("-uiTestingLocalBackend") else {
            return .production()
        }
        return BackendConfigurationManager(
            settingsStore: InMemoryBackendSettingsStore(
                settings: BackendConnectionSettings(
                    baseURLString: "https://ideaforge-test.local:8765",
                    workspaceID: "",
                    isEnabled: true,
                    connectionKind: .localBackend
                )
            ),
            credentialStore: InMemoryBackendCredentialStore()
        )
    }
}
