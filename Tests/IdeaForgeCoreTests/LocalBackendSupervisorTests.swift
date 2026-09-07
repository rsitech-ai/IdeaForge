import Foundation
import XCTest
@testable import IdeaForgeCore

final class LocalBackendSupervisorTests: XCTestCase {
    func testDiscoveredEndpointNormalizesBonjourHostAndRequiresPrivateHTTPS() {
        XCTAssertEqual(
            LocalBackendDiscoveredEndpointPolicy.endpoint(
                hostName: "ideaforge-mac.local.",
                port: 8_765
            )?.absoluteString,
            "https://ideaforge-mac.local:8765"
        )
        XCTAssertNil(
            LocalBackendDiscoveredEndpointPolicy.endpoint(
                hostName: "api.example.com",
                port: 8_765
            )
        )
        XCTAssertNil(
            LocalBackendDiscoveredEndpointPolicy.endpoint(
                hostName: "ideaforge-mac.local.",
                port: 0
            )
        )
    }

    func testReadyRuntimeDoesNotAttemptRecovery() async {
        let runtime = ScriptedLocalBackendRuntime(
            readiness: [.ready],
            recovery: .failed
        )
        let supervisor = LocalBackendSupervisor(runtime: runtime)

        let outcome = await supervisor.start(baseURL: backendURL)
        let recoveryCount = await runtime.recoveryCount
        let checkedURLs = await runtime.checkedURLs

        XCTAssertEqual(outcome, .ready(recovered: false))
        XCTAssertEqual(recoveryCount, 0)
        XCTAssertEqual(checkedURLs, [backendURL])
    }

    func testConnectivityFailureRecoversKnownServiceAndChecksAgain() async {
        let runtime = ScriptedLocalBackendRuntime(
            readiness: [.unavailable(.connectivity), .ready],
            recovery: .started
        )
        let supervisor = LocalBackendSupervisor(runtime: runtime)

        let outcome = await supervisor.start(baseURL: backendURL)
        let recoveryCount = await runtime.recoveryCount
        let checkedURLs = await runtime.checkedURLs

        XCTAssertEqual(outcome, .ready(recovered: true))
        XCTAssertEqual(recoveryCount, 1)
        XCTAssertEqual(checkedURLs, [backendURL, backendURL])
    }

    func testMissingInstalledServiceReturnsSetupState() async {
        let runtime = ScriptedLocalBackendRuntime(
            readiness: [.unavailable(.connectivity)],
            recovery: .notInstalled
        )
        let supervisor = LocalBackendSupervisor(runtime: runtime)

        let outcome = await supervisor.start(baseURL: backendURL)
        let recoveryCount = await runtime.recoveryCount

        XCTAssertEqual(outcome, .needsSetup)
        XCTAssertEqual(recoveryCount, 1)
    }

    func testCertificateFailureDoesNotRestartHealthyProcessBlindly() async {
        let runtime = ScriptedLocalBackendRuntime(
            readiness: [.unavailable(.certificateUntrusted)],
            recovery: .started
        )
        let supervisor = LocalBackendSupervisor(runtime: runtime)

        let outcome = await supervisor.start(baseURL: backendURL)
        let recoveryCount = await runtime.recoveryCount

        XCTAssertEqual(outcome, .unavailable(.certificateUntrusted))
        XCTAssertEqual(recoveryCount, 0)
    }

    func testFailedRecoveryIsBoundedToOneAttempt() async {
        let runtime = ScriptedLocalBackendRuntime(
            readiness: [.unavailable(.timeout)],
            recovery: .failed
        )
        let supervisor = LocalBackendSupervisor(runtime: runtime)

        let outcome = await supervisor.start(baseURL: backendURL)
        let recoveryCount = await runtime.recoveryCount
        let checkedURLCount = await runtime.checkedURLs.count

        XCTAssertEqual(outcome, .unavailable(.timeout))
        XCTAssertEqual(recoveryCount, 1)
        XCTAssertEqual(checkedURLCount, 1)
    }

    private var backendURL: URL {
        URL(string: "https://ideaforge.local:8765")!
    }
}

private actor ScriptedLocalBackendRuntime: LocalBackendRuntimeControlling {
    private var readiness: [LocalBackendReadiness]
    private let recovery: LocalBackendRecoveryResult
    private(set) var checkedURLs = [URL]()
    private(set) var recoveryCount = 0

    init(
        readiness: [LocalBackendReadiness],
        recovery: LocalBackendRecoveryResult
    ) {
        self.readiness = readiness
        self.recovery = recovery
    }

    func checkReadiness(baseURL: URL) async -> LocalBackendReadiness {
        checkedURLs.append(baseURL)
        return readiness.isEmpty ? .unavailable(.connectivity) : readiness.removeFirst()
    }

    func recoverInstalledService() async -> LocalBackendRecoveryResult {
        recoveryCount += 1
        return recovery
    }
}
