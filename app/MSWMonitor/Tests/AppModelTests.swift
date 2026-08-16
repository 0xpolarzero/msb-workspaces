import Foundation
import CryptoKit
import XCTest
import UserNotifications
@testable import MSWMonitor

@MainActor
private final class RecordingHostService: MSWHostServiceControlling {
    let status: MSWHostServiceStatus = .notRegistered
    private(set) var registerInvocationCount = 0

    func registerIfNeeded() throws -> MSWHostServiceStatus {
        registerInvocationCount += 1
        return .notRegistered
    }

    func openApprovalSettings() {}
}
@MainActor
private final class EnabledHostService: MSWHostServiceControlling {
    let status: MSWHostServiceStatus = .enabled
    private(set) var registerInvocationCount = 0

    func registerIfNeeded() throws -> MSWHostServiceStatus {
        registerInvocationCount += 1
        return .enabled
    }

    func openApprovalSettings() {}
}

private actor RecordingHostAgent: MSWHostAgentControlling {
    private(set) var ensureAliasInvocationCount = 0
    private(set) var installRecordsInvocationCount = 0

    func inspect() async throws -> MSWHostRecordSnapshot {
        snapshot()
    }

    func ensureFixedLoopbackAliases() async throws -> MSWHostRecordSnapshot {
        ensureAliasInvocationCount += 1
        return snapshot()
    }

    func installFixedHostRecords() async throws -> MSWHostRecordSnapshot {
        installRecordsInvocationCount += 1
        return snapshot()
    }

    func uninstall() async throws -> MSWHostRecordSnapshot {
        snapshot()
    }

    private func snapshot() -> MSWHostRecordSnapshot {
        MSWHostRecordSnapshot(
            fixedAliases: MSWWorkspaceNetwork.addresses,
            hostsBlockInstalled: true,
            launchDaemonRegistered: true
        )
    }
}

private struct AvailableSourceSetup: MSWSourceSetupControlling {
    let isAvailable = true

    func configureUserIntegrationIfAvailable() async throws {}
    func installRuntime() async throws {}
}

private actor CommandRecorder {
    private(set) var command: MSWCommand?

    func record(_ command: MSWCommand) {
        self.command = command
    }
}

private let protocolCompatibleHandshake = #"{"schemaVersion":1,"requestId":"test-handshake","ok":true,"command":"handshake","observedAt":"2026-08-08T00:00:00Z","result":{"protocolVersion":1,"mswVersion":"test","platform":{"os":"macOS","architecture":"arm64"},"configurationAvailable":true,"runtimeAvailable":true,"capabilities":{"jsonState":true,"jsonMetrics":true,"jsonLogs":true,"plans":true,"bootstrapEvents":true,"jq":true,"workspaceCount":3},"exitCodes":{}},"warnings":[],"error":null}"#

private final class FailingNotificationCenter: MSWNotificationCenterControlling {
    private(set) var addInvocationCount = 0

    func authorizationStatus() async -> UNAuthorizationStatus { .authorized }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        true
    }

    func add(_ request: UNNotificationRequest) async throws {
        addInvocationCount += 1
        throw NSError(domain: "NotificationTest", code: 1)
    }
}

@MainActor
private func makeNotificationEvent() -> MSWNotificationEvent {
    MSWNotificationEvent(
        id: UUID(),
        kind: .operationFailure,
        createdAt: Date(),
        workspace: "dev",
        title: "Operation failed",
        message: "The operation failed.",
        recovery: "Review Activity.",
        deepLink: "msw-monitor://workspace/dev?section=activity",
        generation: 1
    )
}

@MainActor
final class AppModelTests: XCTestCase {
    func testInitialWorkspacesAreFixedAndStopped() {
        let model = AppModel()

        XCTAssertEqual(model.workspaces.map(\.id), [.dev, .playgrounds, .personal])
        XCTAssertEqual(model.workspaces.map(\.state), [.stopped, .stopped, .stopped])
        XCTAssertEqual(model.observationCount, 0)
        XCTAssertEqual(model.observationText, "Not yet refreshed")
    }

    func testRefreshAdvancesVisibleObservationCounter() {
        let model = AppModel()

        model.refresh()
        XCTAssertEqual(model.observationCount, 1)
        XCTAssertEqual(model.observationText, "Observation #1")

        model.refresh()
        XCTAssertEqual(model.observationText, "Observation #2")
    }
    func testStartupRecoveryBlockedModelFailsClosedAndRetriesRecovery() {
        var retryCount = 0
        let model = AppModel(
            startupRecoveryBlockedReason: "Recovery journal could not be reconciled.",
            startupRecoveryRetry: { retryCount += 1 }
        )

        XCTAssertEqual(model.health.title, "Authorization recovery blocked")
        XCTAssertEqual(model.workspaces.map(\.state), [.quarantined, .quarantined, .quarantined])
        XCTAssertEqual(model.workspaces.map(\.credential), [.quarantined, .quarantined, .quarantined])
        model.refresh()
        XCTAssertEqual(retryCount, 1)
        XCTAssertEqual(model.observationCount, 0)
        XCTAssertEqual(model.observationText, "Not yet refreshed")
    }

    func testNotificationDeliveryCapsPersistentFailures() async {
        let defaults = UserDefaults(suiteName: "notification-retry-\(UUID().uuidString)")!
        defaults.set(true, forKey: "notifications.category.operations.enabled")
        let center = FailingNotificationCenter()
        let coordinator = NotificationCoordinator(
            defaults: defaults,
            notificationCenter: center,
            retryDelays: [.milliseconds(1), .milliseconds(1)]
        )

        await coordinator.deliver(makeNotificationEvent())
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(center.addInvocationCount, 3)
        XCTAssertEqual(coordinator.permanentFailures.count, 1)
        XCTAssertEqual(coordinator.permanentFailures.first?.attempts, 3)
        XCTAssertNotNil(coordinator.notificationFailureMessage)

        await coordinator.retryFailedNotifications()
        XCTAssertTrue(coordinator.permanentFailures.isEmpty)
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(center.addInvocationCount, 6)
        XCTAssertEqual(coordinator.permanentFailures.count, 1)
        XCTAssertEqual(coordinator.permanentFailures.first?.attempts, 3)
        coordinator.clearPermanentFailures()
        XCTAssertNil(coordinator.notificationFailureMessage)
    }

    func testClientBackedColdLaunchAndFailedObservationsRemainTruthful() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-cold-launch-truth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let failure = #"{"schemaVersion":1,"requestId":"state-failed","ok":false,"command":"state","observedAt":"2026-08-08T00:00:00Z","result":null,"warnings":[],"error":{"code":"MSW_RUNTIME_UNAVAILABLE","message":"runtime unavailable","recovery":"Repair MSW and retry.","workspace":null,"retryable":true}}"#
        let executable = temporary.appendingPathComponent("msw")
        let script = """
        #!/bin/sh
        if [ "$1" = "app" ] && [ "$2" = "handshake" ]; then
            printf '%s\n' '\(protocolCompatibleHandshake)'
        elif [ "$1" = "app" ] && [ "$2" = "state" ]; then
            printf '%s\n' '\(failure)'
            exit 1
        else
            exit 64
        fi
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let client = MSWClient(runner: MSWCommandRunner(configuration: .init(
            homeDirectory: temporary,
            configuredExecutable: executable
        )))
        let model = AppModel(client: client)

        XCTAssertEqual(model.aggregateText, "Not observed")
        XCTAssertEqual(model.observationCount, 0)
        XCTAssertTrue(model.workspaces.allSatisfy { $0.state == .unknown && $0.freshness == .unavailable })

        await model.refreshRemote()
        XCTAssertEqual(model.aggregateText, "Unavailable")
        XCTAssertEqual(model.observationCount, 0)
        XCTAssertEqual(model.lastRecovery?.code, "MSW_RUNTIME_UNAVAILABLE")
        XCTAssertEqual(model.lastRecovery?.recovery, "Repair MSW and retry.")
        XCTAssertTrue(model.notificationEvents.isEmpty)

        await model.refreshRemote()
        XCTAssertEqual(model.observationCount, 0)
        let events = model.drainNotificationEvents()
        XCTAssertEqual(events.map(\.kind), [.sustainedUnavailability])
        XCTAssertEqual(events.first?.deepLink, "msw-monitor://diagnostics")
    }

    func testFirstAuthoritativeObservationDoesNotNotifyForExistingQuarantine() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-notification-baseline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let stateURL = temporary.appendingPathComponent("state.json")
        try encoder.encode(makeTestStateEnvelope(devLifecycle: .running, devQuarantine: .quarantined)).write(to: stateURL)
        let executable = temporary.appendingPathComponent("msw")
        let script = """
        #!/bin/sh
        if [ "$1" = "app" ] && [ "$2" = "handshake" ]; then
            printf '%s\n' '\(protocolCompatibleHandshake)'
        elif [ "$1" = "app" ] && [ "$2" = "state" ]; then
            /bin/cat "\(stateURL.path)"
        else
            exit 64
        fi
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let client = MSWClient(runner: MSWCommandRunner(configuration: .init(
            homeDirectory: temporary,
            configuredExecutable: executable
        )))
        let model = AppModel(client: client)

        await model.refreshRemote()
        XCTAssertTrue(model.drainNotificationEvents().isEmpty)

        try encoder.encode(makeTestStateEnvelope(devLifecycle: .stopped, devQuarantine: .clear)).write(to: stateURL)
        await model.refreshRemote()
        XCTAssertTrue(model.drainNotificationEvents().isEmpty)

        try encoder.encode(makeTestStateEnvelope(devLifecycle: .running, devQuarantine: .quarantined)).write(to: stateURL)
        await model.refreshRemote()
        XCTAssertEqual(model.drainNotificationEvents().map(\.kind), [.quarantine])
    }

    func testFailedRefreshPreservesLastKnownSnapshotAndServerCapabilities() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-last-known-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let stateURL = temporary.appendingPathComponent("state.json")
        try encoder.encode(makeTestStateEnvelope(devLifecycle: .running, devQuarantine: .clear)).write(to: stateURL)
        let failureMarker = temporary.appendingPathComponent("fail")
        let executable = temporary.appendingPathComponent("msw")
        let failure = #"{"schemaVersion":1,"requestId":"state-failed","ok":false,"command":"state","observedAt":"2026-08-08T00:00:00Z","result":null,"warnings":[],"error":{"code":"MSW_STATE_UNAVAILABLE","message":"state unavailable","recovery":"Run diagnostics.","workspace":"dev","retryable":true}}"#
        let script = """
        #!/bin/sh
        if [ "$1" = "app" ] && [ "$2" = "handshake" ]; then
            printf '%s\n' '\(protocolCompatibleHandshake)'
        elif [ "$1" = "app" ] && [ "$2" = "state" ]; then
            if [ -e "\(failureMarker.path)" ]; then
                printf '%s\n' '\(failure)'
                exit 1
            fi
            /bin/cat "\(stateURL.path)"
        else
            exit 64
        fi
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let client = MSWClient(runner: MSWCommandRunner(configuration: .init(
            homeDirectory: temporary,
            configuredExecutable: executable
        )))
        let model = AppModel(client: client)
        await model.refreshRemote()

        let fresh = try XCTUnwrap(model.workspaces.first(where: { $0.id == .dev }))
        XCTAssertEqual(model.observationCount, 1)
        XCTAssertEqual(model.aggregateText, "Ready")
        XCTAssertEqual(fresh.state, .running)
        XCTAssertTrue(fresh.canOpenTerminal)
        XCTAssertTrue(fresh.canPush)
        XCTAssertTrue(fresh.serverCapabilities.canOpenTerminal)
        XCTAssertTrue(fresh.serverCapabilities.canPush)

        try Data().write(to: failureMarker)
        await model.refreshRemote()

        let stale = try XCTUnwrap(model.workspaces.first(where: { $0.id == .dev }))
        XCTAssertEqual(model.observationCount, 1)
        XCTAssertEqual(model.aggregateText, "Showing last known state")
        XCTAssertEqual(stale.state, .running)
        XCTAssertEqual(stale.freshness, .stale)
        XCTAssertFalse(stale.canOpenTerminal)
        XCTAssertFalse(stale.canPush)
        XCTAssertTrue(stale.serverCapabilities.canOpenTerminal)
        XCTAssertTrue(stale.serverCapabilities.canPush)
        XCTAssertEqual(stale.statusReason, "The latest observation failed; this is the last known snapshot.")
        XCTAssertEqual(stale.recoveryAction, "Run diagnostics.")
    }

    func testLifecycleOperationStaysVerifyingUntilFreshMatchingObservation() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-operation-verification-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let stoppedURL = temporary.appendingPathComponent("stopped.json")
        let runningURL = temporary.appendingPathComponent("running.json")
        let planURL = temporary.appendingPathComponent("plan.json")
        let applyURL = temporary.appendingPathComponent("apply.json")
        let observedOnce = temporary.appendingPathComponent("observed-once")
        try encoder.encode(makeTestStateEnvelope(devLifecycle: .stopped, devQuarantine: .clear)).write(to: stoppedURL)
        try encoder.encode(makeTestStateEnvelope(devLifecycle: .running, devQuarantine: .clear)).write(to: runningURL)
        try encoder.encode(MSWEnvelope(
            schemaVersion: 1, requestId: "plan-start", ok: true, command: "plan", observedAt: Date(),
            result: MSWLifecyclePlan(
                planId: "plan-start", action: "start", workspace: "dev",
                expiresAt: Date().addingTimeInterval(300), confirmationPhrase: "START dev", effects: "Starting dev."
            )
        )).write(to: planURL)
        try encoder.encode(MSWEnvelope(
            schemaVersion: 1, requestId: "apply-start", ok: true, command: "apply", observedAt: Date(),
            result: MSWApplyResult(workspace: "dev", action: "start", reconciled: true, outcome: "Start applied.")
        )).write(to: applyURL)

        let executable = temporary.appendingPathComponent("msw")
        let script = """
        #!/bin/sh
        if [ "$1" = "app" ] && [ "$2" = "handshake" ]; then
            printf '%s\n' '\(protocolCompatibleHandshake)'
        elif [ "$1" = "app" ] && [ "$2" = "state" ]; then
            if [ -e "\(observedOnce.path)" ]; then
                /bin/sleep 1
                /bin/cat "\(runningURL.path)"
            else
                : > "\(observedOnce.path)"
                /bin/cat "\(stoppedURL.path)"
            fi
        elif [ "$1" = "app" ] && [ "$2" = "plan" ]; then
            /bin/cat "\(planURL.path)"
        elif [ "$1" = "app" ] && [ "$2" = "apply" ]; then
            /bin/cat "\(applyURL.path)"
        else
            exit 64
        fi
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let client = MSWClient(runner: MSWCommandRunner(configuration: .init(
            homeDirectory: temporary,
            configuredExecutable: executable
        )))
        let model = AppModel(
            client: client,
            operationCoordinator: MSWOperationCoordinator(client: client)
        )
        await model.refreshRemote()
        model.start(.dev)

        for _ in 0..<40 {
            if model.operationStates["lifecycle:dev"]?.phase == .verifying { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let verifying = try XCTUnwrap(model.operationStates["lifecycle:dev"])
        XCTAssertEqual(verifying.phase, .verifying)
        XCTAssertEqual(verifying.outcome, .pending)
        XCTAssertEqual(model.workspaces.first(where: { $0.id == .dev })?.state, .starting)
        XCTAssertFalse(model.activities.contains { $0.title == "Start completed" })

        for _ in 0..<80 {
            if model.operationStates["lifecycle:dev"]?.phase == .finished,
               model.activities.contains(where: { $0.title == "Start verified" }) { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let finished = try XCTUnwrap(model.operationStates["lifecycle:dev"])
        XCTAssertEqual(finished.phase, .finished)
        XCTAssertEqual(finished.outcome, .succeeded)
        XCTAssertEqual(model.workspaces.first(where: { $0.id == .dev })?.state, .running)
        XCTAssertTrue(model.activities.contains { $0.title == "Start verified" })
    }

    func testRepairInvalidatesResolutionAndPrefersManagedRuntime() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-managed-runtime-resolution-\(UUID().uuidString)", isDirectory: true)
        let legacy = temporary.appendingPathComponent(".local/bin/msw")
        let managed = temporary.appendingPathComponent(
            "Library/Application Support/MSW Monitor/Toolchains/current/bin/msw"
        )
        try FileManager.default.createDirectory(
            at: legacy.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let legacyHandshake = protocolCompatibleHandshake.replacingOccurrences(
            of: "\"configurationAvailable\":true",
            with: "\"configurationAvailable\":false"
        )
        let writeExecutable: (URL, String) throws -> Void = { url, output in
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let script = "#!/bin/sh\nprintf '%s\\n' '\(output)'\n"
            try Data(script.utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: url.path
            )
        }
        try writeExecutable(legacy, legacyHandshake)

        let runner = MSWCommandRunner(configuration: .init(homeDirectory: temporary))
        let beforeRepair = await runner.mswResolution(forceRefresh: true)
        XCTAssertEqual(beforeRepair.selected?.standardizedFileURL, legacy.standardizedFileURL)

        try writeExecutable(managed, protocolCompatibleHandshake)
        await runner.invalidateMSWResolution()

        let afterRepair = await runner.mswResolution()
        XCTAssertEqual(afterRepair.selected?.standardizedFileURL, managed.standardizedFileURL)
    }
    func testUnknownQuarantineSnapshotAllowsStopButDisablesOtherLifecycleActions() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-unknown-quarantine-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let snapshots = Workspace.ID.allCases.map { id in
            let isUnknownQuarantine = id == .dev
            return MSWWorkspaceSnapshot(
                id: id.rawValue,
                purpose: "Test workspace",
                lifecycle: isUnknownQuarantine ? .running : .stopped,
                freshness: .fresh,
                quarantine: MSWQuarantineSnapshot(
                    state: isUnknownQuarantine ? .unknown : .clear,
                    reason: nil
                ),
                credential: MSWCredentialSnapshot(
                    state: .ready,
                    accessMode: "guest-read",
                    verificationRepository: nil,
                    accountLogin: nil,
                    installationId: nil,
                    accessExpiresAt: nil,
                    refreshExpiresAt: nil,
                    needsRestart: false
                ),
                resources: MSWResourceSnapshot(
                    cpus: "2",
                    maxCpus: "8",
                    memory: "4GiB",
                    maxMemory: "16GiB",
                    rootDisk: "20GiB"
                ),
                network: MSWNetworkSnapshot(
                    host: "\(id.rawValue).msw.test",
                    ip: "127.0.0.10"
                ),
                actionCapabilities: MSWActionCapabilities(
                    canStart: true,
                    canStop: true,
                    canRestart: true,
                    canOpenTerminal: true,
                    canPush: true
                )
            )
        }
        let state = MSWStateResponse(schemaVersion: 1, mswVersion: "test", workspaces: snapshots)
        let envelope = MSWEnvelope(
            schemaVersion: 1,
            requestId: "state-test",
            ok: true,
            command: "state",
            observedAt: Date(),
            result: state
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let responseURL = temporary.appendingPathComponent("state.json")
        try encoder.encode(envelope).write(to: responseURL)

        let planURL = temporary.appendingPathComponent("plan.json")
        try encoder.encode(
            MSWEnvelope(
                schemaVersion: 1,
                requestId: "plan-stop",
                ok: true,
                command: "plan",
                observedAt: Date(),
                result: MSWLifecyclePlan(
                    planId: "plan-stop",
                    action: "stop",
                    workspace: "dev",
                    expiresAt: Date().addingTimeInterval(300),
                    confirmationPhrase: "STOP dev",
                    effects: "Stopping dev."
                )
            )
        ).write(to: planURL)

        let executable = temporary.appendingPathComponent("msw")
        let script = """
        #!/bin/sh
        if [ "$1" = "app" ] && [ "$2" = "handshake" ]; then
            printf '%s\n' '\(protocolCompatibleHandshake)'
        elif [ "$1" = "app" ] && [ "$2" = "state" ]; then
            /bin/cat '\(responseURL.path)'
        elif [ "$1" = "app" ] && [ "$2" = "plan" ]; then
            /bin/cat '\(planURL.path)'
        else
            exit 64
        fi
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let runner = MSWCommandRunner(configuration: .init(
            homeDirectory: temporary,
            configuredExecutable: executable
        ))
        let client = MSWClient(runner: runner)
        let model = AppModel(
            client: client,
            operationCoordinator: MSWOperationCoordinator(client: client)
        )
        await model.refreshRemote()
        XCTAssertNil(model.lastError, "Refresh error: \(model.lastError ?? "nil")")

        let dev = try XCTUnwrap(model.workspaces.first(where: { $0.id == .dev }))
        XCTAssertEqual(dev.state, .quarantined)
        XCTAssertEqual(dev.credential, .quarantined)
        XCTAssertEqual(dev.nextAction, "Stop or Repair")
        XCTAssertFalse(dev.canStart)
        XCTAssertTrue(dev.canStop)
        XCTAssertFalse(dev.canRestart)

        model.stop(.dev)
        for _ in 0..<40 {
            if model.pendingLifecyclePlan != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertNotNil(model.pendingLifecyclePlan)
        XCTAssertNil(model.lastError, "Stop plan error: \(model.lastError ?? "nil")")

        model.start(.dev)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(model.lastError?.contains("quarantined") == true)
        XCTAssertNotNil(model.pendingLifecyclePlan)
        model.cancelPendingLifecycle()
    }

    func testStopApplyDoesNotLoadQuarantinedGuestCredential() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-stop-credential-isolation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let metadataURL = temporary.appendingPathComponent("credentials.json")
        let metadata: [String: Any] = [
            "schemaVersion": 2,
            "entries": [
                "dev.guest": [
                    "workspace": "dev",
                    "schemaVersion": 2,
                    "role": "guest",
                    "provider": "github-app-user",
                    "accessMode": "read-only",
                    "verificationRepository": "acme/demo",
                    "needsRestart": false,
                    "generation": 1,
                    "quarantined": true,
                    "updatedAt": "2026-08-08T00:00:00Z"
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: metadata, options: []).write(to: metadataURL)
        let broker = try CredentialBroker(metadataURL: metadataURL)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let responseURL = temporary.appendingPathComponent("apply.json")
        try encoder.encode(
            MSWEnvelope(
                schemaVersion: 1,
                requestId: "apply-stop",
                ok: true,
                command: "apply",
                observedAt: Date(),
                result: MSWApplyResult(
                    workspace: "dev",
                    action: "stop",
                    reconciled: true,
                    outcome: "Stopped dev."
                )
            )
        ).write(to: responseURL)

        let executable = temporary.appendingPathComponent("msw")
        let script = """
        #!/bin/sh
        if [ "$1" = "app" ] && [ "$2" = "handshake" ]; then
            printf '%s\n' '\(protocolCompatibleHandshake)'
        elif [ "$1" = "app" ] && [ "$2" = "apply" ]; then
            /bin/cat '\(responseURL.path)'
        else
            exit 64
        fi
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let runner = MSWCommandRunner(configuration: .init(
            homeDirectory: temporary,
            configuredExecutable: executable
        ))
        let client = MSWClient(runner: runner, credentialBroker: broker)
        let plan = MSWLifecyclePlan(
            planId: "plan-stop",
            action: "stop",
            workspace: "dev",
            expiresAt: Date().addingTimeInterval(300),
            confirmationPhrase: "STOP dev",
            effects: "Stopping dev."
        )

        let response = try await client.applyLifecyclePlan(plan, confirmation: "STOP dev")
        XCTAssertEqual(response.result?.outcome, "Stopped dev.")
    }

    func testUnsafeRefreshCancelsPendingLifecycleConfirmation() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-stale-lifecycle-plan-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let safeStateURL = temporary.appendingPathComponent("state-safe.json")
        let unsafeStateURL = temporary.appendingPathComponent("state-unsafe.json")
        let planURL = temporary.appendingPathComponent("plan.json")
        let applyURL = temporary.appendingPathComponent("apply.json")
        let unsafeMarker = temporary.appendingPathComponent("unsafe")
        let applyMarker = temporary.appendingPathComponent("apply-called")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(
            makeTestStateEnvelope(devLifecycle: .running, devQuarantine: .clear)
        ).write(to: safeStateURL)
        try encoder.encode(
            makeTestStateEnvelope(devLifecycle: .running, devQuarantine: .quarantined)
        ).write(to: unsafeStateURL)
        try encoder.encode(
            MSWEnvelope(
                schemaVersion: 1,
                requestId: "plan-stop",
                ok: true,
                command: "plan",
                observedAt: Date(),
                result: MSWLifecyclePlan(
                    planId: "plan-stop",
                    action: "stop",
                    workspace: "dev",
                    expiresAt: Date().addingTimeInterval(300),
                    confirmationPhrase: "STOP dev",
                    effects: "Stopping dev."
                )
            )
        ).write(to: planURL)
        try encoder.encode(
            MSWEnvelope(
                schemaVersion: 1,
                requestId: "apply-stop",
                ok: true,
                command: "apply",
                observedAt: Date(),
                result: MSWApplyResult(
                    workspace: "dev",
                    action: "stop",
                    reconciled: true,
                    outcome: "Stopped dev."
                )
            )
        ).write(to: applyURL)

        let executable = temporary.appendingPathComponent("msw")
        let script = """
        #!/bin/sh
        if [ "$1" = "app" ] && [ "$2" = "handshake" ]; then
            printf '%s\n' '\(protocolCompatibleHandshake)'
        elif [ "$1" = "app" ] && [ "$2" = "state" ]; then
            if [ -e "\(unsafeMarker.path)" ]; then
                /bin/cat "\(unsafeStateURL.path)"
            else
                /bin/cat "\(safeStateURL.path)"
            fi
        elif [ "$1" = "app" ] && [ "$2" = "plan" ]; then
            /bin/cat "\(planURL.path)"
        elif [ "$1" = "app" ] && [ "$2" = "apply" ]; then
            : > "\(applyMarker.path)"
            /bin/cat "\(applyURL.path)"
        else
            exit 64
        fi
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let runner = MSWCommandRunner(configuration: .init(
            homeDirectory: temporary,
            configuredExecutable: executable
        ))
        let client = MSWClient(runner: runner)
        let model = AppModel(
            client: client,
            operationCoordinator: MSWOperationCoordinator(client: client)
        )

        await model.refreshRemote()
        XCTAssertEqual(model.workspaces.first(where: { $0.id == .dev })?.state, .running)

        model.stop(.dev)
        for _ in 0..<40 {
            if model.pendingLifecyclePlan != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertNotNil(model.pendingLifecyclePlan)

        try Data("unsafe\n".utf8).write(to: unsafeMarker)
        await model.refreshRemote()

        XCTAssertNotNil(model.pendingLifecyclePlan)
        XCTAssertEqual(model.workspaces.first(where: { $0.id == .dev })?.state, .quarantined)
        XCTAssertNil(model.lastError)

        model.confirmPendingLifecycle()
        for _ in 0..<40 {
            if FileManager.default.fileExists(atPath: applyMarker.path) { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: applyMarker.path))
    }

    func testUnsafeRefreshCancelsPendingPushConfirmation() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-stale-push-plan-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let safeStateURL = temporary.appendingPathComponent("state-safe.json")
        let unsafeStateURL = temporary.appendingPathComponent("state-unsafe.json")
        let planURL = temporary.appendingPathComponent("push-plan.json")
        let applyURL = temporary.appendingPathComponent("push-apply.json")
        let unsafeMarker = temporary.appendingPathComponent("unsafe")
        let applyMarker = temporary.appendingPathComponent("apply-called")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(
            makeTestStateEnvelope(devLifecycle: .running, devQuarantine: .clear)
        ).write(to: safeStateURL)
        try encoder.encode(
            makeTestStateEnvelope(devLifecycle: .running, devQuarantine: .quarantined)
        ).write(to: unsafeStateURL)
        try encoder.encode(
            MSWEnvelope(
                schemaVersion: 1,
                requestId: "push-plan",
                ok: true,
                command: "push-plan",
                observedAt: Date(),
                result: MSWPushPlan(
                    planId: "push-plan",
                    workspace: "dev",
                    repositoryPath: "repo",
                    branch: "main",
                    localCommit: "local",
                    remoteCommit: "remote",
                    aheadCount: 1,
                    behindCount: 0,
                    forceWithLease: false,
                    expiresAt: Date().addingTimeInterval(300),
                    confirmationPhrase: "PUSH dev/repo",
                    effects: "Push repo."
                )
            )
        ).write(to: planURL)
        try encoder.encode(
            MSWEnvelope(
                schemaVersion: 1,
                requestId: "push-apply",
                ok: true,
                command: "apply",
                observedAt: Date(),
                result: MSWPushApplyResult(
                    workspace: "dev",
                    repositoryPath: "repo",
                    branch: "main",
                    pushed: true,
                    reconciled: true,
                    outcome: "Pushed repo."
                )
            )
        ).write(to: applyURL)

        let executable = temporary.appendingPathComponent("msw")
        let script = """
        #!/bin/sh
        if [ "$1" = "app" ] && [ "$2" = "handshake" ]; then
            printf '%s\n' '\(protocolCompatibleHandshake)'
        elif [ "$1" = "app" ] && [ "$2" = "state" ]; then
            if [ -e "\(unsafeMarker.path)" ]; then
                /bin/cat "\(unsafeStateURL.path)"
            else
                /bin/cat "\(safeStateURL.path)"
            fi
        elif [ "$1" = "app" ] && [ "$2" = "push-plan" ]; then
            /bin/cat "\(planURL.path)"
        elif [ "$1" = "app" ] && [ "$2" = "apply" ]; then
            : > "\(applyMarker.path)"
            /bin/cat "\(applyURL.path)"
        else
            exit 64
        fi
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let runner = MSWCommandRunner(configuration: .init(
            homeDirectory: temporary,
            configuredExecutable: executable
        ))
        let client = MSWClient(runner: runner)
        let coordinator = MSWOperationCoordinator(client: client)
        let model = AppModel(
            client: client,
            operationCoordinator: coordinator,
            operationService: MSWOperationService(client: client, coordinator: coordinator)
        )
        let repository = MSWRepositorySnapshot(
            path: "repo",
            canonicalRemote: "https://github.com/example/repo.git",
            branch: "main",
            upstreamRef: "origin/main",
            worktreeState: .clean,
            destinationState: .ahead,
            stagedCount: 0,
            modifiedCount: 0,
            deletedCount: 0,
            untrackedCount: 0,
            aheadCount: 1,
            behindCount: 0,
            localCommit: "local",
            remoteCommit: "remote",
            pushability: .pushable,
            needsStart: false,
            freshness: .fresh,
            checkedAt: Date()
        )

        await model.refreshRemote()
        model.reviewPush(for: repository, workspace: .dev)
        for _ in 0..<40 {
            if model.pendingPushPlan != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertNotNil(model.pendingPushPlan)

        try Data("unsafe\n".utf8).write(to: unsafeMarker)
        await model.refreshRemote()

        XCTAssertNil(model.pendingPushPlan)
        XCTAssertEqual(model.workspaces.first(where: { $0.id == .dev })?.state, .quarantined)
        XCTAssertTrue(model.detailError?.contains("cancelled") == true)

        model.confirmPendingPush(confirmation: "PUSH dev/repo")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(FileManager.default.fileExists(atPath: applyMarker.path))
    }
    func testFailedNonHostPreflightDoesNotRegisterHostService() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-bootstrap-preflight-test-\(UUID().uuidString)", isDirectory: true)
        let bin = temporary.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let passingHandshake = #"""
        {"schemaVersion":1,"requestId":"handshake-pass","ok":true,"command":"handshake","observedAt":"2026-08-08T00:00:00Z","result":{"protocolVersion":1,"mswVersion":"test","platform":{"os":"macOS","architecture":"arm64"},"configurationAvailable":true,"runtimeAvailable":true,"capabilities":{"jsonState":true,"jsonMetrics":true,"jsonLogs":true,"plans":true,"bootstrapEvents":true,"jq":true,"workspaceCount":3},"exitCodes":{}},"warnings":[],"error":null}
        """#
        let failingHandshake = #"""
        {"schemaVersion":1,"requestId":"handshake-fail","ok":false,"command":"handshake","observedAt":"2026-08-08T00:00:00Z","result":null,"warnings":[],"error":{"code":"MSW_RUNTIME_UNAVAILABLE","message":"runtime unavailable","recovery":"Repair MSW","workspace":null,"retryable":true}}
        """#
        let passingURL = temporary.appendingPathComponent("handshake-pass.json")
        let failingURL = temporary.appendingPathComponent("handshake-fail.json")
        try Data(passingHandshake.utf8).write(to: passingURL)
        try Data(failingHandshake.utf8).write(to: failingURL)

        for name in ["git", "tar", "zstd", "git-lfs", "msb"] {
            let tool = bin.appendingPathComponent(name)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: tool)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        }

        let marker = temporary.appendingPathComponent("handshake-seen")
        let executable = bin.appendingPathComponent("msw")
        let script = """
        #!/bin/sh
        count=0
        if [ -e "\(marker.path)" ]; then count=$(/bin/cat "\(marker.path)"); fi
        count=$((count + 1))
        printf '%s\n' "$count" > "\(marker.path)"
        if [ "$count" -ge 3 ]; then
            /bin/cat "\(failingURL.path)"
        else
            /bin/cat "\(passingURL.path)"
        fi
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let runner = MSWCommandRunner(configuration: .init(
            homeDirectory: temporary,
            configuredExecutable: executable,
            additionalSearchPaths: [executable]
        ))
        let hostService = RecordingHostService()
        let coordinator = BootstrapCoordinator(
            client: MSWClient(runner: runner),
            runner: runner,
            stateStore: BootstrapStateStore(url: temporary.appendingPathComponent("bootstrap-state.json")),
            hostService: hostService
        )

        do {
            _ = try await coordinator.run()
            XCTFail("Expected the failing non-host preflight to block setup.")
        } catch let error as BootstrapCoordinatorError {
            XCTAssertEqual(error, .preflightBlocked)
        } catch {
            XCTFail("Unexpected bootstrap error: \(error)")
        }

        XCTAssertEqual(hostService.registerInvocationCount, 0)
        let finalState = await coordinator.state()
        XCTAssertEqual(finalState.phase, .preflight)
        XCTAssertEqual(finalState.lastError, BootstrapCoordinatorError.preflightBlocked.localizedDescription)
    }


    func testBootstrapRunCompletesWithInjectedSetupAndHostFakes() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-bootstrap-success-test-\(UUID().uuidString)", isDirectory: true)
        let mswBin = temporary.appendingPathComponent("bin", isDirectory: true)
        let toolBin = temporary.appendingPathComponent(".local/bin", isDirectory: true)
        let configDirectory = temporary.appendingPathComponent(".config/msw", isDirectory: true)
        try FileManager.default.createDirectory(at: mswBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: toolBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        try Data("# test configuration\n".utf8)
            .write(to: configDirectory.appendingPathComponent("config.sh"))
        for name in ["git", "tar", "zstd", "git-lfs", "msb"] {
            let tool = toolBin.appendingPathComponent(name)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: tool)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: tool.path
            )
        }

        let bootstrapURL = temporary.appendingPathComponent("bootstrap.json")
        let bootstrapResponse = #"""
        {"schemaVersion":1,"requestId":"bootstrap-success","ok":true,"command":"bootstrap","observedAt":"2026-08-08T00:00:00Z","result":{"resumed":false,"phase":"complete","requiresApproval":false,"vmsStarted":false,"message":"Setup complete."},"warnings":[],"error":null}
        """#
        try Data(bootstrapResponse.utf8).write(to: bootstrapURL)

        let executable = mswBin.appendingPathComponent("msw")
        let script = """
        #!/bin/sh
        if [ "$1" = "app" ] && [ "$2" = "handshake" ]; then
            printf '%s\\n' '\(protocolCompatibleHandshake)'
        elif [ "$1" = "app" ] && [ "$2" = "bootstrap" ]; then
            /bin/cat "\(bootstrapURL.path)"
        else
            exit 64
        fi
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let runner = MSWCommandRunner(configuration: .init(
            homeDirectory: temporary,
            configuredExecutable: executable
        ))
        let hostService = EnabledHostService()
        let hostAgent = RecordingHostAgent()
        let coordinator = BootstrapCoordinator(
            client: MSWClient(runner: runner),
            runner: runner,
            stateStore: BootstrapStateStore(
                url: temporary.appendingPathComponent("bootstrap-state.json")
            ),
            hostAgent: hostAgent,
            hostService: hostService,
            sourceSetup: AvailableSourceSetup()
        )

        let result = try await coordinator.run()

        XCTAssertEqual(result.phase, MSWBootstrapState.Phase.complete.rawValue)
        let ensureAliasCount = await hostAgent.ensureAliasInvocationCount
        let installRecordsCount = await hostAgent.installRecordsInvocationCount
        XCTAssertEqual(ensureAliasCount, 1)
        XCTAssertEqual(installRecordsCount, 1)
        let finalState = await coordinator.state()
        XCTAssertEqual(finalState.phase, .complete)
        XCTAssertTrue(finalState.completedPhases.contains(.hostIntegration))
        XCTAssertTrue(finalState.completedPhases.contains(.workspaces))
    }

    func testJSONLFramerSplitsChunksAndFinishesPendingData() throws {
        var framer = MSWJSONLFramer(maxLineBytes: 8, maxBufferedBytes: 16)

        XCTAssertEqual(try framer.append(Data("one\n".utf8)), [Data("one".utf8)])
        XCTAssertEqual(try framer.append(Data("tail".utf8)), [])
        XCTAssertEqual(try framer.finish(), Data("tail".utf8))
    }

    func testJSONLFramerRejectsAnOversizedUnterminatedLine() {
        var framer = MSWJSONLFramer(maxLineBytes: 4, maxBufferedBytes: 16)

        XCTAssertThrowsError(try framer.append(Data("12345".utf8))) { error in
            XCTAssertEqual(
                error as? MSWClientError,
                .unavailable("MSW JSONL line exceeded the capture limit.")
            )
        }
    }

    func testProtocolDecoderRejectsUnsupportedSchemaAndProtocolErrors() {
        let unsupported = Data(
            #"{"schemaVersion":2,"requestId":"req","ok":true,"command":"handshake","observedAt":null,"result":"ok","warnings":[],"error":null}"#.utf8
        )
        XCTAssertThrowsError(
            try MSWProtocolDecoder.decodeEnvelope(unsupported, as: String.self, expectedCommand: "handshake")
        ) { error in
            XCTAssertEqual(error as? MSWClientError, .unsupportedSchema(2))
        }

        let failed = Data(
            #"{"schemaVersion":1,"requestId":"req","ok":false,"command":"state","observedAt":null,"result":null,"warnings":[],"error":{"code":"MSW_CONFIG_MISSING","message":"setup required","recovery":"Run Setup","workspace":null,"retryable":false}}"#.utf8
        )
        XCTAssertThrowsError(
            try MSWProtocolDecoder.decodeEnvelope(failed, as: String.self, expectedCommand: "state")
        ) { error in
            XCTAssertEqual(
                error as? MSWClientError,
                .protocolFailure(
                    MSWProtocolError(
                        code: "MSW_CONFIG_MISSING",
                        message: "setup required",
                        recovery: "Run Setup",
                        workspace: nil,
                        retryable: false
                    )
                )
            )
        }

        let missingObservation = Data(
            #"{"schemaVersion":1,"requestId":"req","ok":true,"command":"handshake","observedAt":null,"result":"ok","warnings":[],"error":null}"#.utf8
        )
        XCTAssertThrowsError(
            try MSWProtocolDecoder.decodeEnvelope(missingObservation, as: String.self, expectedCommand: "handshake")
        ) { error in
            XCTAssertEqual(error as? MSWClientError, .malformedJSON(command: "handshake"))
        }

        let missingResult = Data(
            #"{"schemaVersion":1,"requestId":"req","ok":true,"command":"handshake","observedAt":"2026-08-08T00:00:00Z","result":null,"warnings":[],"error":null}"#.utf8
        )
        XCTAssertThrowsError(
            try MSWProtocolDecoder.decodeEnvelope(missingResult, as: String.self, expectedCommand: "handshake")
        ) { error in
            XCTAssertEqual(error as? MSWClientError, .malformedJSON(command: "handshake"))
        }
    }

    func testProtocolRedactorRemovesBearerTokenAndCredentialURL() {
        let redactor = MSWProtocolRedactor()
        let input = "Authorization: Bearer ghp_secret https://user:password@example.test/repo.git"

        XCTAssertEqual(
            redactor.redact(input),
            "Authorization: [REDACTED] [REDACTED]example.test/repo.git"
        )
    }

    func testProtocolRedactorPreservesStructuredJSONBoundaries() throws {
        let input = #"{"detail":"GH_TOKEN=ghp_secret","next":"ok"}"#
        let redacted = MSWProtocolRedactor().redact(input)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(redacted.utf8)) as? [String: String])

        XCTAssertEqual(object["detail"], "[REDACTED]")
        XCTAssertEqual(object["next"], "ok")
        XCTAssertFalse(redacted.contains("ghp_secret"))
    }
    func testProtocolRedactorRemovesOpaqueJSONCredentialValues() throws {
        let input = #"{"accessToken":"opaque-access","refresh_token":"opaque-refresh","next":"ok"}"#
        let redacted = MSWProtocolRedactor().redact(input)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(redacted.utf8)) as? [String: String])

        XCTAssertEqual(object["accessToken"], "[REDACTED]")
        XCTAssertEqual(object["refresh_token"], "[REDACTED]")
        XCTAssertEqual(object["next"], "ok")
        XCTAssertFalse(redacted.contains("opaque-access"))
        XCTAssertFalse(redacted.contains("opaque-refresh"))
    }
    func testProtocolRedactorRemovesScopedWorkspaceTokenAssignments() {
        let input = "MSW_GITHUB_READ_TOKEN_DEV=opaque_read MSW_GITHUB_WRITE_TOKEN_PLAYGROUNDS=opaque_write"
        let redacted = MSWProtocolRedactor().redact(input)

        XCTAssertEqual(redacted, "[REDACTED] [REDACTED]")
        XCTAssertFalse(redacted.contains("opaque_read"))
        XCTAssertFalse(redacted.contains("opaque_write"))
    }



    func testCommandRunnerCapturesOutputAndFiltersCredentialConfiguration() async throws {
        let runner = MSWCommandRunner()
        let command = MSWCommand(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '%s\\n' \"$MSW_TEST_VISIBLE\"; printf '%s' \"${MSW_TEST_TOKEN-unset}\""],
            environment: [
                "MSW_TEST_VISIBLE": "visible",
                "MSW_TEST_TOKEN": "blocked"
            ],
            timeout: .seconds(5)
        )

        let result = try await runner.run(command)

        XCTAssertEqual(result.stdoutString, "visible\nunset")
        XCTAssertFalse(result.stdoutString.contains("blocked"))
    }
    func testCommandRunnerAllowsHostRepairControlWithoutCredentialEnvironment() async throws {
        let runner = MSWCommandRunner()
        let result = try await runner.run(
            MSWCommand(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf '%s' \"${MSW_SKIP_HOST_REPAIR-unset}\""],
                environment: ["MSW_SKIP_HOST_REPAIR": "1"],
                timeout: .seconds(5)
            )
        )

        XCTAssertEqual(result.stdoutString, "1")
    }


    func testCommandRunnerSkipsInstalledCLIWithoutAppProtocol() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-protocol-resolution-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let stale = temporary.appendingPathComponent("stale-msw")
        try Data("#!/bin/sh\necho \"msw: unknown command 'app'\" >&2\nexit 1\n".utf8).write(to: stale)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stale.path)

        let compatible = temporary.appendingPathComponent("compatible-msw")
        let handshake = #"{"schemaVersion":1,"requestId":"compatible","ok":true,"command":"handshake","observedAt":"2026-08-08T00:00:00Z","result":{"protocolVersion":1,"mswVersion":"3.1.0","platform":{"os":"macOS","architecture":"arm64"},"configurationAvailable":true,"runtimeAvailable":true,"capabilities":{"jsonState":true,"jsonMetrics":true,"jsonLogs":true,"plans":true,"bootstrapEvents":true,"jq":true,"workspaceCount":3},"exitCodes":{}},"warnings":[],"error":null}"#
        try Data("#!/bin/sh\nprintf '%s\\n' '\(handshake)'\n".utf8).write(to: compatible)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: compatible.path)

        let runner = MSWCommandRunner(configuration: .init(
            homeDirectory: temporary,
            configuredExecutable: stale,
            additionalSearchPaths: [compatible]
        ))
        let resolution = await runner.mswResolution()

        XCTAssertEqual(resolution.selected, compatible)
        XCTAssertEqual(resolution.incompatibleCandidates, [stale])
        let result = try await MSWClient(runner: runner).handshake().result
        XCTAssertEqual(result?.protocolVersion, 1)
        XCTAssertEqual(result?.mswVersion, "3.1.0")
    }

    func testCommandRunnerReportsOnlyProtocolIncompatibleCLIAsUnusable() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-protocol-repair-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let stale = temporary.appendingPathComponent("msw")
        try Data("#!/bin/sh\necho \"unknown command app\" >&2\nexit 1\n".utf8).write(to: stale)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stale.path)
        let runner = MSWCommandRunner(configuration: .init(
            homeDirectory: temporary,
            configuredExecutable: stale
        ))

        let resolution = await runner.mswResolution()
        XCTAssertTrue(resolution.hasInstalledExecutable)
        XCTAssertNil(resolution.selected)
        XCTAssertEqual(resolution.incompatibleCandidates, [stale])
    }

    func testUnsignedDevelopmentBundleExplainsHostServiceRegistrationFailure() {
        XCTAssertEqual(
            MSWHostServiceController.inspectPackaging(bundleURL: Bundle.main.bundleURL),
            .signingUnavailable
        )
    }
    func testHostRepairAuthorizationBuildsFixedAdministratorPayload() async throws {
        let recorder = CommandRecorder()
        let authorization = MSWHostRepairAuthorization { command in
            await recorder.record(command)
            return MSWCommandResult(
                status: 0,
                stdout: Data(),
                stderr: Data(),
                duration: .milliseconds(1)
            )
        }

        try await authorization.repair()

        let recordedCommand = await recorder.command
        let command = try XCTUnwrap(recordedCommand)
        XCTAssertEqual(command.executable.path, "/usr/bin/osascript")
        XCTAssertEqual(command.arguments.first, "-e")
        let script = try XCTUnwrap(command.arguments.dropFirst().first)
        XCTAssertTrue(script.contains("with administrator privileges"))
        XCTAssertTrue(script.contains("127.0.0.10 dev.msw.test"))
        XCTAssertTrue(script.contains("127.0.0.11 playgrounds.msw.test"))
        XCTAssertTrue(script.contains("127.0.0.12 personal.msw.test"))
        XCTAssertFalse(script.contains("sudo"))
    }
    func testHostRepairAuthorizationAppleScriptCompilesWithoutRunning() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-host-repair-script-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let output = temporary.appendingPathComponent("repair.scpt")
        let result = try await MSWCommandRunner().run(
            MSWCommand(
                executable: URL(fileURLWithPath: "/usr/bin/osacompile"),
                arguments: ["-o", output.path, "-e", MSWHostRepairAuthorization.appleScriptForTesting],
                timeout: .seconds(5)
            )
        )

        XCTAssertEqual(result.status, 0, result.stderrString)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }
    func testSourceSetupUsesDevelopmentRootWithoutPrivilegedHostRepair() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-source-setup-test-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let runtimeMarker = root.appendingPathComponent("runtime-marker")
        let hostRepairMarker = root.appendingPathComponent("host-repair-marker")
        let setup = """
        #!/bin/sh
        set -eu
        printf '%s\\n' "${MSW_SKIP_HOST_REPAIR:-unset}" > "\(runtimeMarker.path)"
        """
        let launcher = """
        #!/bin/sh
        set -eu
        printf '%s %s %s\\n' "$1" "$2" "${MSW_SKIP_HOST_REPAIR:-unset}" > "\(hostRepairMarker.path)"
        """
        try Data(setup.utf8).write(to: root.appendingPathComponent("setup.sh"))
        try Data("#!/bin/sh\n".utf8).write(to: root.appendingPathComponent("config.sh"))
        try Data(launcher.utf8).write(to: bin.appendingPathComponent("msw"))
        for url in [root.appendingPathComponent("setup.sh"), root.appendingPathComponent("config.sh"), bin.appendingPathComponent("msw")] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        let service = MSWSourceSetupService(
            runner: MSWCommandRunner(configuration: .init(homeDirectory: root)),
            bundleURL: root.appending(path: "build/MSWMonitor.app"),
            workingDirectory: root
        )

        XCTAssertTrue(service.isAvailable)
        try await service.installRuntime()
        try await service.configureUserIntegrationIfAvailable()
        XCTAssertEqual(try String(contentsOf: runtimeMarker, encoding: .utf8), "1\n")
        XCTAssertEqual(try String(contentsOf: hostRepairMarker, encoding: .utf8), "host repair 1\n")
    }


    func testCommandRunnerTerminatesTimedOutProcessGroup() async {
        let runner = MSWCommandRunner()
        let command = MSWCommand(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 30"],
            timeout: .milliseconds(100)
        )

        do {
            _ = try await runner.run(command)
            XCTFail("Expected the command to time out.")
        } catch let error as MSWClientError {
            XCTAssertEqual(error, .timedOut(command: "-c"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCommandRunnerExplicitCancellationReportsCancelled() async {
        let runner = MSWCommandRunner()
        let operationID = UUID()
        let command = MSWCommand(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            timeout: .seconds(60)
        )
        let task = Task { try await runner.run(command, operationID: operationID) }
        try? await Task.sleep(for: .milliseconds(100))

        await runner.cancel(operationID: operationID)

        do {
            _ = try await task.value
            XCTFail("Expected explicit cancellation.")
        } catch let error as MSWClientError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testWorkspaceURLValidationRejectsMismatchedOrCredentialedURLs() {
        XCTAssertNotNil(AppModel.validatedWorkspaceURL(
            "http://dev.msw.test:3000",
            expectedWorkspace: "dev",
            responseWorkspace: "dev",
            expectedHost: "dev.msw.test",
            expectedPort: "3000",
            expectedScheme: "http"
        ))
        XCTAssertNil(AppModel.validatedWorkspaceURL(
            "http://user:password@dev.msw.test:3000",
            expectedWorkspace: "dev",
            responseWorkspace: "dev",
            expectedHost: "dev.msw.test",
            expectedPort: "3000",
            expectedScheme: "http"
        ))
        XCTAssertNil(AppModel.validatedWorkspaceURL(
            "https://dev.msw.test:3000/path?token=value",
            expectedWorkspace: "dev",
            responseWorkspace: "personal",
            expectedHost: "dev.msw.test",
            expectedPort: "3000",
            expectedScheme: "http"
        ))
        XCTAssertNil(AppModel.validatedWorkspaceURL(
            "http://attacker.example:3000",
            expectedWorkspace: "dev",
            responseWorkspace: "dev",
            expectedHost: "dev.msw.test",
            expectedPort: "3000",
            expectedScheme: "http"
        ))
    }

    func testToolchainInstallerRejectsSignedTraversalDestination() async throws {
        struct UnsignedManifest: Encodable {
            let schemaVersion: Int
            let version: String
            let architecture: String
            let artifacts: [ToolchainManifest.Artifact]
        }

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-toolchain-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("artifact")
        try Data("safe".utf8).write(to: source)
        let digest = SHA256.hash(data: Data("safe".utf8)).map { String(format: "%02x", $0) }.joined()
        let artifact = ToolchainManifest.Artifact(
            id: "msw",
            source: source,
            destination: "../escape",
            sha256: digest,
            executable: true
        )
        let unsigned = UnsignedManifest(
            schemaVersion: 1,
            version: "1.0.0",
            architecture: "arm64",
            artifacts: [artifact]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let privateKey = Curve25519.Signing.PrivateKey()
        let signature = try privateKey.signature(for: encoder.encode(unsigned)).base64EncodedString()
        let manifest = ToolchainManifest(
            schemaVersion: 1,
            version: "1.0.0",
            architecture: "arm64",
            artifacts: [artifact],
            signature: signature
        )
        let installer = try ToolchainInstaller(
            installationRoot: temporary.appendingPathComponent("install", isDirectory: true),
            trustedManifestPublicKey: privateKey.publicKey.rawRepresentation
        )

        do {
            _ = try await installer.install(manifestData: JSONEncoder().encode(manifest))
            XCTFail("Expected the traversal destination to be rejected.")
        } catch let error as ToolchainInstallerError {
            XCTAssertEqual(error, .unsafeDestination("../escape"))
        }
    }
    func testToolchainInstallerInstallsSignedRelativeArtifact() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-toolchain-install-\(UUID().uuidString)", isDirectory: true)
        let sourceRoot = temporary.appendingPathComponent("sources", isDirectory: true)
        let installationRoot = temporary.appendingPathComponent("install", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let payload = Data("signed payload".utf8)
        try payload.write(to: sourceRoot.appendingPathComponent("msw"))
        let artifact = ToolchainManifest.Artifact(
            id: "msw",
            source: URL(string: "msw")!,
            destination: "bin/msw",
            sha256: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined(),
            executable: false
        )
        let privateKey = Curve25519.Signing.PrivateKey()
        let manifestData = try makeSignedToolchainManifest(artifacts: [artifact], privateKey: privateKey)
        let installer = try ToolchainInstaller(
            installationRoot: installationRoot,
            sourceRoot: sourceRoot,
            trustedManifestPublicKey: privateKey.publicKey.rawRepresentation,
            allowExternalFileSources: false
        )

        let result = try await installer.install(manifestData: manifestData)

        XCTAssertEqual(result.version, "1.0.0")
        XCTAssertEqual(try Data(contentsOf: result.root.appendingPathComponent("bin/msw")), payload)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: installationRoot.appendingPathComponent("current").path),
            "1.0.0"
        )
    }

    func testToolchainInstallerRejectsExternalAndNonHTTPSSources() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-toolchain-source-policy-\(UUID().uuidString)", isDirectory: true)
        let sourceRoot = temporary.appendingPathComponent("sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }
        let privateKey = Curve25519.Signing.PrivateKey()

        let externalArtifact = ToolchainManifest.Artifact(
            id: "external",
            source: temporary.appendingPathComponent("outside"),
            destination: "bin/external",
            sha256: String(repeating: "0", count: 64),
            executable: false
        )
        let externalInstaller = try ToolchainInstaller(
            installationRoot: temporary.appendingPathComponent("install-external"),
            sourceRoot: sourceRoot,
            trustedManifestPublicKey: privateKey.publicKey.rawRepresentation,
            allowExternalFileSources: false
        )
        do {
            _ = try await externalInstaller.install(
                manifestData: makeSignedToolchainManifest(artifacts: [externalArtifact], privateKey: privateKey)
            )
            XCTFail("Expected an external artifact source to be rejected.")
        } catch let error as ToolchainInstallerError {
            XCTAssertEqual(error, .invalidArtifactSource("external"))
        }

        let insecureArtifact = ToolchainManifest.Artifact(
            id: "insecure",
            source: URL(string: "http://example.test/msw")!,
            destination: "bin/insecure",
            sha256: String(repeating: "0", count: 64),
            executable: false
        )
        let insecureInstaller = try ToolchainInstaller(
            installationRoot: temporary.appendingPathComponent("install-insecure"),
            sourceRoot: sourceRoot,
            trustedManifestPublicKey: privateKey.publicKey.rawRepresentation,
            allowNetworkSources: true,
            allowExternalFileSources: false
        )
        do {
            _ = try await insecureInstaller.install(
                manifestData: makeSignedToolchainManifest(artifacts: [insecureArtifact], privateKey: privateKey)
            )
            XCTFail("Expected a non-HTTPS artifact source to be rejected.")
        } catch let error as ToolchainInstallerError {
            XCTAssertEqual(error, .invalidArtifactSource("insecure"))
        }
    }

    private func makeSignedToolchainManifest(
        artifacts: [ToolchainManifest.Artifact],
        privateKey: Curve25519.Signing.PrivateKey
    ) throws -> Data {
        struct UnsignedManifest: Encodable {
            let schemaVersion: Int
            let version: String
            let architecture: String
            let artifacts: [ToolchainManifest.Artifact]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let unsigned = UnsignedManifest(
            schemaVersion: 1,
            version: "1.0.0",
            architecture: "arm64",
            artifacts: artifacts
        )
        let signature = try privateKey.signature(for: encoder.encode(unsigned)).base64EncodedString()
        return try encoder.encode(ToolchainManifest(
            schemaVersion: 1,
            version: "1.0.0",
            architecture: "arm64",
            artifacts: artifacts,
            signature: signature
        ))
    }

    private func makeTestStateEnvelope(
        devLifecycle: MSWLifecycle,
        devQuarantine: MSWQuarantineSnapshot.State
    ) -> MSWEnvelope<MSWStateResponse> {
        let snapshots = Workspace.ID.allCases.map { id in
            let quarantine = id == .dev ? devQuarantine : .clear
            return MSWWorkspaceSnapshot(
                id: id.rawValue,
                purpose: "Test workspace",
                lifecycle: id == .dev ? devLifecycle : .stopped,
                freshness: .fresh,
                quarantine: MSWQuarantineSnapshot(
                    state: quarantine,
                    reason: quarantine == .clear ? nil : "Test quarantine"
                ),
                credential: MSWCredentialSnapshot(
                    state: .ready,
                    accessMode: "guest-read",
                    verificationRepository: nil,
                    accountLogin: nil,
                    installationId: nil,
                    accessExpiresAt: nil,
                    refreshExpiresAt: nil,
                    needsRestart: false
                ),
                resources: MSWResourceSnapshot(
                    cpus: "2",
                    maxCpus: "8",
                    memory: "4GiB",
                    maxMemory: "16GiB",
                    rootDisk: "20GiB"
                ),
                network: MSWNetworkSnapshot(
                    host: "\(id.rawValue).msw.test",
                    ip: "127.0.0.10"
                ),
                actionCapabilities: MSWActionCapabilities(
                    canStart: true,
                    canStop: true,
                    canRestart: true,
                    canOpenTerminal: true,
                    canPush: true
                )
            )
        }
        return MSWEnvelope(
            schemaVersion: 1,
            requestId: "state-test",
            ok: true,
            command: "state",
            observedAt: Date(),
            result: MSWStateResponse(
                schemaVersion: 1,
                mswVersion: "test",
                workspaces: snapshots
            )
        )
    }

    func testMSWConnectRejectsUnknownExpiredAndReplayedCallbacks() async throws {
        let keychain = InMemoryConnectKeychain()
        let transport = QueueConnectTransport()
        let clock = TestConnectClock(Date(timeIntervalSince1970: 1_900_000_000))
        let configuration = testConnectConfiguration()
        let client = MSWConnectClient(
            configuration: configuration,
            transport: transport,
            keychain: keychain,
            now: clock.now,
            sessionService: "test-connect-\(UUID().uuidString)"
        )

        let start = try await client.startAuthorization()
        let startQuery = try XCTUnwrap(URLComponents(url: start.url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(startQuery.first(where: { $0.name == "state" })?.value, start.state)
        XCTAssertEqual(
            startQuery.first(where: { $0.name == "code_challenge" })?.value,
            MSWConnectClient.pkceChallenge(for: start.codeVerifier)
        )

        do {
            _ = try await client.completeAuthorization(
                callbackURL: testCallbackURL(configuration: configuration, state: "unknown-state", code: "code")
            )
            XCTFail("An unknown callback state must be rejected.")
        } catch let error as MSWConnectError {
            XCTAssertEqual(error, .callbackStateMismatch)
        }

        await transport.enqueue(try testJSON(TestCallbackPayload(
            sessionID: UUID(),
            sessionToken: "opaque-service-session",
            account: GitHubAccount(login: "octocat", id: 1, name: "Octo Cat", email: nil),
            expiresAt: clock.value.addingTimeInterval(3600)
        )))
        let connected = try await client.completeAuthorization(
            callbackURL: testCallbackURL(configuration: configuration, state: start.state, code: "one-time-code")
        )
        XCTAssertEqual(connected.account.login, "octocat")

        do {
            _ = try await client.completeAuthorization(
                callbackURL: testCallbackURL(configuration: configuration, state: start.state, code: "replayed")
            )
            XCTFail("A callback state must be single-use.")
        } catch let error as MSWConnectError {
            XCTAssertEqual(error, .callbackReplayed)
        }

        let expiredStart = try await client.startAuthorization()
        clock.value = clock.value.addingTimeInterval(601)
        do {
            _ = try await client.completeAuthorization(
                callbackURL: testCallbackURL(configuration: configuration, state: expiredStart.state, code: "expired")
            )
            XCTFail("An expired callback must be rejected.")
        } catch let error as MSWConnectError {
            XCTAssertEqual(error, .callbackExpired)
        }
    }

    func testMSWConnectAuthorizationOpensBrowserWithoutEndpointPreflight() async throws {
        let transport = QueueConnectTransport()
        let client = MSWConnectClient(
            configuration: testConnectConfiguration(),
            transport: transport,
            keychain: InMemoryConnectKeychain(),
            sessionService: "test-connect-authorize-\(UUID().uuidString)"
        )
        let browser = RecordingConnectBrowser()

        do {
            _ = try await client.authorize(browser: browser)
            XCTFail("A cancelled browser authorization must fail.")
        } catch let error as MSWConnectError {
            XCTAssertEqual(error, .cancelled)
        }

        XCTAssertNotNil(browser.openedURL)
        let requests = await transport.requests()
        XCTAssertTrue(
            requests.isEmpty,
            "Authorization must let the browser reach the endpoint instead of issuing a fragile HEAD preflight."
        )
    }

    func testDefaultBrowserIgnoresStaleCallbackAfterCancelRetry() async throws {
        let browser = MSWConnectBrowser(opener: { _ in true })
        let first = Task {
            try await browser.authenticate(
                url: Self.authorizeURL(state: "stale-state"),
                callbackScheme: "msw"
            )
        }
        try await Self.waitUntil { browser.expectedState == "stale-state" }

        // Cancel the first attempt, then immediately retry: the cancellation
        // handler may fire before OR after the retry installs its wait, and
        // neither interleaving may disturb the retry.
        first.cancel()
        let retry = Task {
            try await browser.authenticate(
                url: Self.authorizeURL(state: "fresh-state"),
                callbackScheme: "msw"
            )
        }
        try await Self.waitUntil { browser.expectedState == "fresh-state" }

        let firstResult = await first.result
        guard case .failure(let firstError) = firstResult else {
            return XCTFail("The cancelled first attempt must fail.")
        }
        XCTAssertEqual(firstError as? MSWConnectError, .cancelled)

        let stale = URL(string: "msw://connect.microsandbox.dev/oauth/callback?code=one&state=stale-state")!
        XCTAssertFalse(browser.handleCallback(stale), "A callback from a cancelled attempt must be ignored.")
        XCTAssertTrue(browser.isWaiting, "An ignored stale callback must not consume the wait.")

        let fresh = URL(string: "msw://connect.microsandbox.dev/oauth/callback?code=two&state=fresh-state")!
        XCTAssertTrue(browser.handleCallback(fresh))
        let value = try await retry.value
        XCTAssertEqual(value.absoluteString, fresh.absoluteString)
        XCTAssertFalse(browser.isWaiting)
    }

    func testDefaultBrowserIgnoresCallbacksFromOtherSchemesHostsPathsOrStates() async throws {
        let browser = MSWConnectBrowser(opener: { _ in true })
        let task = Task {
            try await browser.authenticate(
                url: Self.authorizeURL(state: "expected-state"),
                callbackScheme: "msw"
            )
        }
        try await Self.waitUntil { browser.expectedState == "expected-state" }

        XCTAssertFalse(browser.handleCallback(
            URL(string: "https://connect.microsandbox.dev/oauth/callback?code=x&state=expected-state")!
        ))
        XCTAssertFalse(browser.handleCallback(
            URL(string: "msw://other.example.com/oauth/callback?code=x&state=expected-state")!
        ))
        XCTAssertFalse(browser.handleCallback(
            URL(string: "msw://connect.microsandbox.dev/other/callback?code=x&state=expected-state")!
        ))
        XCTAssertFalse(browser.handleCallback(
            URL(string: "msw://connect.microsandbox.dev/oauth/callback?code=x&state=wrong-state")!
        ))
        XCTAssertFalse(browser.handleCallback(
            URL(string: "msw://connect.microsandbox.dev/oauth/callback?code=x")!
        ))
        XCTAssertTrue(browser.isWaiting, "Mismatched callbacks must leave the wait intact.")

        let fresh = URL(string: "msw://connect.microsandbox.dev/oauth/callback?code=ok&state=expected-state")!
        XCTAssertTrue(browser.handleCallback(fresh))
        let value = try await task.value
        XCTAssertEqual(value.absoluteString, fresh.absoluteString)
        XCTAssertFalse(browser.handleCallback(fresh), "After completion the slot is free for a new attempt.")
    }

    private static func authorizeURL(state: String) -> URL {
        var components = URLComponents(string: "https://connect.test/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: "test-client"),
            URLQueryItem(name: "redirect_uri", value: "msw://connect.microsandbox.dev/oauth/callback"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: "challenge"),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        return components.url!
    }

    private static func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for the browser wait to install.")
    }

    /// Deterministic poll for async conditions (actor state): waits up to the
    /// timeout, failing the test with `description` if the condition never
    /// holds. Unlike `waitUntil`, the condition can `await` actor state.
    @MainActor
    private static func waitForCondition(
        _ description: String,
        timeout: TimeInterval = 5,
        condition: () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for \(description).")
    }

    /// Minimal SetupView for the device-flow barrier tests: optional
    /// coordinator/authorization/device flow/refresher. The reference-typed
    /// `setupLifecycle`, `deviceSessionRefresher`, and the injected
    /// verification-page opener are shared across struct copies, so the test's
    /// copy drives the same gate, store-backed revalidation, and flow the
    /// production surface uses.
    @MainActor
    private func makeDeviceSetupView(
        coordinator: (any MSWBootstrapCoordinating)? = nil,
        authorizationCoordinator: GitHubAuthorizationCoordinator? = nil,
        deviceFlow: GitHubDeviceFlow? = nil,
        deviceSessionRefresher: GitHubDeviceSessionRefresher = .shared,
        openDeviceVerificationPage: @escaping (URL) -> Bool = { _ in true }
    ) -> SetupView {
        SetupView(
            coordinator: coordinator,
            authorizationCoordinator: authorizationCoordinator,
            deviceFlow: deviceFlow,
            deviceInstallationURL: nil,
            openSettings: { _ in },
            closeSetup: {},
            uiTestMode: false,
            uiTestStartsInReview: false,
            uiTestGitHubScenario: nil,
            uiTestBootstrapReconnect: false,
            startupRecoveryBlockedReason: nil,
            retryStartupRecovery: {},
            deviceSessionRefresher: deviceSessionRefresher,
            openDeviceVerificationPage: openDeviceVerificationPage
        )
    }
    func testGitHubDeviceFlowRequestsCodeAndPollsToken() async throws {
        let transport = QueueConnectTransport()
        await transport.enqueue(Data(#"{"device_code":"device-123","user_code":"WDJB-MJHT","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#.utf8))
        let client = GitHubDeviceFlow(
            configuration: GitHubDeviceFlowConfiguration(clientID: "Iv1.testclient"),
            transport: transport
        )

        let authorization = try await client.requestDeviceCode()
        XCTAssertEqual(authorization.deviceCode, "device-123")
        XCTAssertEqual(authorization.userCode, "WDJB-MJHT")
        XCTAssertEqual(authorization.expiresIn, 900)
        XCTAssertEqual(authorization.interval, 5)
        let verification = GitHubDeviceFlow.verificationURL(for: authorization)
        XCTAssertTrue(verification.absoluteString.contains("user_code=WDJB-MJHT"))

        await transport.enqueue(Data(#"{"access_token":"ghu_device_access","refresh_token":"ghr_device_refresh","expires_in":28800,"refresh_token_expires_in":15897600,"scope":""}"#.utf8))
        let token = try await client.pollToken(clientID: "Iv1.testclient", deviceCode: "device-123")
        XCTAssertEqual(token.accessToken, "ghu_device_access")
        XCTAssertEqual(token.refreshToken, "ghr_device_refresh")
        XCTAssertEqual(token.expiresIn, 28800)
    }

    func testGitHubDeviceFlowMapsTerminalErrors() async throws {
        let cases: [(String, String, GitHubDeviceFlowError)] = [
            ("authorization_pending", #"{"error":"authorization_pending"}"#, .authorizationPending),
            ("slow_down", #"{"error":"slow_down","interval":"10"}"#, .slowDown(10)),
            ("expired", #"{"error":"expired_token"}"#, .expired),
            ("denied", #"{"error":"access_denied"}"#, .denied),
            ("disabled", #"{"error":"device_flow_disabled"}"#, .deviceFlowDisabled),
            ("rate_limited", #"{"error":"rate_limited"}"#, .rateLimited)
        ]
        for (name, payload, expected) in cases {
            let transport = QueueConnectTransport()
            await transport.enqueue(Data(payload.utf8))
            let client = GitHubDeviceFlow(
                configuration: GitHubDeviceFlowConfiguration(clientID: "Iv1.testclient"),
                transport: transport
            )
            do {
                _ = try await client.pollToken(clientID: "Iv1.testclient", deviceCode: "device")
                XCTFail("\(name) must fail")
            } catch let error as GitHubDeviceFlowError {
                XCTAssertEqual(error, expected, "case \(name)")
            }
        }
    }

    func testGitHubDeviceFlowRejectsUnknownClientAndTransportFailure() async throws {
        let unknown = QueueConnectTransport()
        await unknown.enqueue(Data(#"{"error":"Not Found"}"#.utf8), status: 404)
        let unknownClient = GitHubDeviceFlow(
            configuration: GitHubDeviceFlowConfiguration(clientID: "Iv1.testclient"),
            transport: unknown
        )
        do {
            _ = try await unknownClient.requestDeviceCode()
            XCTFail("An unknown client must fail.")
        } catch let error as GitHubDeviceFlowError {
            XCTAssertEqual(error, .deviceFlowDisabled)
        }

        let offline = QueueConnectTransport() // empty queue: send throws
        let offlineClient = GitHubDeviceFlow(
            configuration: GitHubDeviceFlowConfiguration(clientID: "Iv1.testclient"),
            transport: offline
        )
        do {
            _ = try await offlineClient.requestDeviceCode()
            XCTFail("A transport failure must fail.")
        } catch let error as GitHubDeviceFlowError {
            XCTAssertEqual(error, .transportUnavailable)
        }
    }

    func testGitHubDeviceFlowFetchesAccountInstallationsAndRepositories() async throws {
        let transport = QueueConnectTransport()
        let client = GitHubDeviceFlow(
            configuration: GitHubDeviceFlowConfiguration(clientID: "Iv1.testclient"),
            transport: transport
        )

        await transport.enqueue(Data(#"{"login":"octocat","id":1,"name":"Octo Cat","email":"octo@example.com"}"#.utf8))
        let account = try await client.account(accessToken: "ghu_token")
        XCTAssertEqual(account.login, "octocat")
        XCTAssertEqual(account.id, 1)

        await transport.enqueue(Data(#"{"total_count":1,"installations":[{"id":42,"account":{"login":"acme","id":7,"type":"Organization"},"repository_selection":"selected"}]}"#.utf8))
        let installations = try await client.installations(accessToken: "ghu_token")
        XCTAssertEqual(installations.count, 1)
        XCTAssertEqual(installations.first?.id, 42)

        await transport.enqueue(Data(#"{"repositories":[{"id":1001,"full_name":"acme/one","name":"one","owner":{"login":"acme","id":7,"type":"Organization"},"private":true,"default_branch":"main"}]}"#.utf8))
        let repositories = try await client.repositories(accessToken: "ghu_token", installationID: 42)
        XCTAssertEqual(repositories.map(\.fullName), ["acme/one"])
    }

    func testGitHubDeviceSessionStoreRoundTripAndClear() throws {
        let keychain = InMemoryConnectKeychain()
        let store = GitHubDeviceSessionStore(keychain: keychain)
        XCTAssertNil(try store.load())

        let session = GitHubDeviceSession(
            schemaVersion: 1,
            clientID: "Iv1.testclient",
            account: GitHubAccount(login: "octocat", id: 1, name: "Octo Cat", email: "octo@example.com"),
            accessToken: "ghu_access",
            refreshToken: "ghr_refresh",
            accessExpiresAt: Date().addingTimeInterval(3600),
            refreshExpiresAt: Date().addingTimeInterval(15_897_600),
            obtainedAt: Date()
        )
        try store.save(session)
        XCTAssertEqual(try store.load(), session)

        try store.clear()
        XCTAssertNil(try store.load())
    }

    func testDeviceAccessDecisionRequiresAccessibleRepository() {
        XCTAssertFalse(SetupView.deviceAccessDecided(signedIn: true, repositoryCount: 0),
                       "A sign-in with zero accessible repositories grants nothing.")
        XCTAssertTrue(SetupView.deviceAccessDecided(signedIn: true, repositoryCount: 1))
        XCTAssertFalse(SetupView.deviceAccessDecided(signedIn: false, repositoryCount: 1))
    }

    func testAttentionReapplyRequiredNamesGrantReapplyAfterAccessibleRepositories() {
        // No accessible repositories yet: the user has not completed the
        // reconnect, so the banner keeps its plain attention message.
        XCTAssertFalse(SetupView.attentionReapplyRequired(
            attentionWorkspace: "dev",
            accessibleRepositoryCount: 0
        ), "A re-check with zero accessible repositories must not name a re-apply action yet.")
        // Confirming accessible repositories does not restore the host-side
        // scoped credential the reconnect error demands; the banner must name
        // the remaining grant re-apply action instead of clearing.
        XCTAssertTrue(SetupView.attentionReapplyRequired(
            attentionWorkspace: "dev",
            accessibleRepositoryCount: 1
        ), "A successful re-check with accessible repositories must transition the banner to the re-apply action.")
        XCTAssertTrue(SetupView.attentionReapplyRequired(
            attentionWorkspace: "dev",
            accessibleRepositoryCount: 3
        ), "The transition applies to any positive accessible repository count.")
        // Without an active attention banner there is nothing to transition.
        XCTAssertFalse(SetupView.attentionReapplyRequired(
            attentionWorkspace: nil,
            accessibleRepositoryCount: 1
        ), "No attention banner means no re-apply transition.")
    }

    func testAttentionResolvedRequiresTheAttentionWorkspaceToCommit() {
        // No active banner: nothing to keep.
        XCTAssertTrue(SetupView.attentionResolved(attentionWorkspace: nil, committedWorkspaces: []))
        XCTAssertTrue(SetupView.attentionResolved(attentionWorkspace: nil, committedWorkspaces: ["dev"]))
        // An authorization discovery or a commit of other workspaces does not
        // resolve the attention workspace; it stays host-unreadable.
        XCTAssertFalse(SetupView.attentionResolved(attentionWorkspace: "dev", committedWorkspaces: []),
                       "Discovery creates no host credential and must not clear the banner.")
        XCTAssertFalse(SetupView.attentionResolved(attentionWorkspace: "dev", committedWorkspaces: ["playgrounds"]),
                       "Committing only other workspaces must not clear the banner for dev.")
        // Only a successful commit that includes the attention workspace
        // restores the host credential and clears the banner.
        XCTAssertTrue(SetupView.attentionResolved(attentionWorkspace: "dev", committedWorkspaces: ["dev"]))
        XCTAssertTrue(SetupView.attentionResolved(attentionWorkspace: "dev", committedWorkspaces: ["playgrounds", "dev"]))
    }

    func testSkipIssueResolvedOnlyByCommittingTheAffectedWorkspace() {
        // A dependency-missing failure (no issue workspace) is never resolved
        // by any commit; only a successful skip retry clears it.
        XCTAssertFalse(SetupView.skipIssueResolved(issueWorkspace: nil, committedWorkspaces: []))
        XCTAssertFalse(SetupView.skipIssueResolved(issueWorkspace: nil, committedWorkspaces: ["dev"]),
                       "Dependency-missing failures must not be cleared by a commit.")
        // A workspace-scoped failure for dev is not resolved by committing
        // unrelated workspaces: the gates must stay closed while dev's
        // reconnect-required grant remains unresolved.
        XCTAssertFalse(SetupView.skipIssueResolved(issueWorkspace: "dev", committedWorkspaces: []))
        XCTAssertFalse(SetupView.skipIssueResolved(issueWorkspace: "dev", committedWorkspaces: ["playgrounds"]),
                       "Committing only other workspaces must not clear a failed skip for dev.")
        // Only a successful commit that includes the affected workspace
        // reconnects it and resolves the failure.
        XCTAssertTrue(SetupView.skipIssueResolved(issueWorkspace: "dev", committedWorkspaces: ["dev"]))
        XCTAssertTrue(SetupView.skipIssueResolved(issueWorkspace: "dev", committedWorkspaces: ["playgrounds", "dev"]))
    }

    func testVerificationTaskIsCurrentOnlyClearsItsOwnHandle() {
        // A successor replaced the verifier (the generation advanced); the
        // cancelled predecessor must not publish state or clear the live
        // successor's handle.
        XCTAssertFalse(SetupView.verificationTaskIsCurrent(storedGeneration: 2, taskGeneration: 1),
                       "A cancelled predecessor must not act on a successor's generation.")
        // The stored verifier is still the current one: publishing and
        // clearing the handle are safe.
        XCTAssertTrue(SetupView.verificationTaskIsCurrent(storedGeneration: 2, taskGeneration: 2),
                      "The current verifier may publish and clear its own handle.")
    }

    func testDeviceRepositoryPollingActiveOnlyWhileUndecidedAndOnGitHubStep() {
        XCTAssertTrue(SetupView.deviceRepositoryPollingActive(
            signedIn: true, repositoryCount: 0, stepActive: true, skipped: false, alreadyDecided: false
        ), "A signed-in session with zero accessible repositories on the GitHub step must poll.")
        XCTAssertFalse(SetupView.deviceRepositoryPollingActive(
            signedIn: true, repositoryCount: 1, stepActive: true, skipped: false, alreadyDecided: false
        ), "Polling must stop once repositories are detected.")
        XCTAssertFalse(SetupView.deviceRepositoryPollingActive(
            signedIn: true, repositoryCount: 0, stepActive: false, skipped: false, alreadyDecided: false
        ), "Polling must not run while the GitHub step is not active.")
        XCTAssertFalse(SetupView.deviceRepositoryPollingActive(
            signedIn: true, repositoryCount: 0, stepActive: true, skipped: true, alreadyDecided: false
        ), "Polling must not run once GitHub is skipped.")
        XCTAssertFalse(SetupView.deviceRepositoryPollingActive(
            signedIn: false, repositoryCount: 0, stepActive: true, skipped: false, alreadyDecided: false
        ), "Polling must not run without a device sign-in.")
        XCTAssertFalse(SetupView.deviceRepositoryPollingActive(
            signedIn: true, repositoryCount: 0, stepActive: true, skipped: false, alreadyDecided: true
        ), "Polling must not run when existing metadata or retained verifications already decide the step.")
    }

    func testPollingTaskIsCurrentOnlyClearsItsOwnHandle() {
        // A successor replaced the poller (the generation advanced); the
        // stale predecessor must not erase the live successor's handle.
        XCTAssertFalse(SetupView.pollingTaskIsCurrent(storedGeneration: 2, taskGeneration: 1),
                       "A cancelled predecessor must not clear a successor's handle.")
        // The stored poller is still the current one: clearing is safe.
        XCTAssertTrue(SetupView.pollingTaskIsCurrent(storedGeneration: 2, taskGeneration: 2),
                      "The current poller may clear its own handle.")
    }

    func testShouldRecheckNowThrottlesFocusRestarts() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(SetupView.shouldRecheckNow(lastCheckAt: nil, now: now, minimumInterval: 5),
                      "No prior check means an immediate re-check is allowed.")
        XCTAssertTrue(SetupView.shouldRecheckNow(
            lastCheckAt: now.addingTimeInterval(-6), now: now, minimumInterval: 5
        ), "A check older than the minimum gap allows an immediate re-check.")
        XCTAssertFalse(SetupView.shouldRecheckNow(
            lastCheckAt: now.addingTimeInterval(-1), now: now, minimumInterval: 5
        ), "A recent check must throttle a focus-triggered re-check.")
    }

    func testNextRepositoryCheckDateTracksLastCompletedCheckFromAnySource() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // No check yet: the deadline is in the distant past, so the poller
        // runs its first check immediately.
        XCTAssertLessThanOrEqual(
            SetupView.nextRepositoryCheckDate(lastCheckAt: nil, now: now, interval: 8).timeIntervalSince(now),
            0,
            "With no prior check the poller must not wait."
        )
        // The deadline is a full interval after the last completed re-check,
        // whether that check came from the poller or the manual button, so a
        // manual check that finishes during the poller's wait satisfies it.
        XCTAssertEqual(
            SetupView.nextRepositoryCheckDate(lastCheckAt: now, now: now, interval: 8).timeIntervalSince(now),
            8,
            "The next check must be a full interval after the last completed check."
        )
        // A check that completed mid-wait (3 s ago) pushes the next check to
        // a full interval after it (5 s from now).
        XCTAssertEqual(
            SetupView.nextRepositoryCheckDate(lastCheckAt: now.addingTimeInterval(-3), now: now, interval: 8).timeIntervalSince(now),
            5,
            "A check that completed mid-wait pushes the next check a full interval after it."
        )
        // A stamp in the future (corrupted clock) is capped to the normal
        // cadence from now: the poller waits one interval instead of parking.
        XCTAssertEqual(
            SetupView.nextRepositoryCheckDate(lastCheckAt: now.addingTimeInterval(100), now: now, interval: 8).timeIntervalSince(now),
            8,
            "A future stamp must yield the normal cadence from now, never an unbounded wait."
        )
    }

    func testRepositoryCheckIsDueReevaluatedAfterMidWaitCompletion() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // The poller checked at t0: mid-wait (t0+5) the next check is not due.
        XCTAssertFalse(SetupView.repositoryCheckIsDue(
            lastCheckAt: now, now: now.addingTimeInterval(5), interval: 8
        ), "Mid-wait the check is not due yet.")
        // A manual (or restore) check completed at t0+5 moves the deadline to
        // t0+13; at the ORIGINAL wake time t0+8 the poller must keep waiting
        // (wake-recompute ordering: no refresh until the moved deadline).
        XCTAssertFalse(SetupView.repositoryCheckIsDue(
            lastCheckAt: now.addingTimeInterval(5), now: now.addingTimeInterval(8), interval: 8
        ), "A check completed during the wait pushes the deadline; at the old wake time it is not due.")
        XCTAssertTrue(SetupView.repositoryCheckIsDue(
            lastCheckAt: now.addingTimeInterval(5), now: now.addingTimeInterval(13), interval: 8
        ), "The moved deadline makes the check due a full interval after the mid-wait completion.")
        // A startup restore that stamped the timestamp must not be duplicated
        // by an immediate first poll.
        XCTAssertFalse(SetupView.repositoryCheckIsDue(
            lastCheckAt: now, now: now.addingTimeInterval(1), interval: 8
        ), "A just-stamped restore check must not be followed by an immediate poll.")
        XCTAssertTrue(SetupView.repositoryCheckIsDue(
            lastCheckAt: nil, now: now, interval: 8
        ), "With no completed check the first poll is due immediately.")
        // Clock rollback: `now` regressed below the stamp — due, so the
        // poller re-checks and re-stamps instead of parking indefinitely.
        XCTAssertTrue(SetupView.repositoryCheckIsDue(
            lastCheckAt: now, now: now.addingTimeInterval(-3_600), interval: 8
        ), "A clock rollback must be treated as due so the poller cannot park.")
        // A stamp in the future (corrupted clock) must not park the poller
        // either: it is due, and the re-check re-stamps a sane timestamp.
        XCTAssertTrue(SetupView.repositoryCheckIsDue(
            lastCheckAt: now.addingTimeInterval(100), now: now, interval: 8
        ), "A future stamp must not park the poller; it is due and re-stamps.")
    }

    func testFalseRecheckOutcomeIsTerminalNoOp() {
        XCTAssertTrue(SetupView.shouldContinueSetupAfterRecheck(completed: true),
                      "A completed re-check may publish status, stamp the schedule, and continue.")
        XCTAssertFalse(SetupView.shouldContinueSetupAfterRecheck(completed: false),
                       "A cancelled/superseded re-check must be a terminal no-op: no status publication, no polling restart, no timestamp stamp.")
    }

    func testDeviceSetupLifecycleIsCurrentOnlyWhileUntouched() {
        let gate = DeviceSetupLifecycleGate()
        let captured = gate.generation
        XCTAssertTrue(gate.isCurrent(captured),
                      "An untouched lifecycle accepts the generation captured before the first await.")
        gate.invalidate()
        XCTAssertFalse(gate.isCurrent(captured),
                       "Teardown (willClose, onDisappear, cancelDeviceFlow) must invalidate every previously captured lifecycle.")
        XCTAssertTrue(gate.isCurrent(gate.generation),
                      "A fresh capture after teardown is current again; the barrier is per-capture, not a permanent lock.")
    }

    /// Deterministic ordering test for guard point 1 of the restore barrier:
    /// the window closes while revalidation is pending (the gated rotation
    /// request is in flight and the restore continuation has not resumed).
    /// The captured lifecycle is stale by the time revalidation returns, so
    /// the restore must NOT create a new repository refresh — and the shared
    /// actor's Keychain work still completes, preserving credential
    /// integrity. The control phase proves the same setup DOES create the
    /// refresh when no close lands.
    func testCloseDuringRevalidationPreventsRefreshCreationAndPublication() async throws {
        let transport = GatedConnectTransport()
        let flow = GitHubDeviceFlow(
            configuration: GitHubDeviceFlowConfiguration(clientID: "Iv1.testclient"),
            transport: transport
        )
        let store = GitHubDeviceSessionStore(keychain: InMemoryConnectKeychain())
        try store.save(GitHubDeviceSession(
            schemaVersion: 1,
            clientID: "Iv1.testclient",
            account: GitHubAccount(login: "octocat", id: 1, name: "Octo Cat", email: "octo@example.com"),
            accessToken: "ghu_expired",
            refreshToken: "ghr_refresh",
            accessExpiresAt: Date(timeIntervalSinceNow: -60),
            refreshExpiresAt: Date().addingTimeInterval(15_897_600),
            obtainedAt: Date(timeIntervalSinceNow: -3600)
        ))
        // Rotation response, then a zero-repository installations response
        // (for the control phase's refresh child).
        await transport.enqueue(Data(#"{"access_token":"ghu_fresh","refresh_token":"ghr_fresh2","expires_in":3600,"refresh_token_expires_in":15897600,"scope":""}"#.utf8))
        await transport.enqueue(Data(#"{"total_count":0,"installations":[]}"#.utf8))
        let refresher = GitHubDeviceSessionRefresher(store: store)
        let view = makeDeviceSetupView(deviceFlow: flow, deviceSessionRefresher: refresher)

        // Close while revalidation is pending: the rotation request is in
        // flight (the send is gated), the restore is suspended at its first
        // await. The lifecycle bump is the authoritative barrier — the same
        // primitive every teardown path (willClose, onDisappear,
        // cancelDeviceFlow) invokes. The restore carries the token the
        // OUTERMOST startup entry captured, so it can never recapture a
        // post-close generation as current.
        let startupToken = view.setupLifecycle.generation
        let restoreTask = Task { await view.restoreDeviceSession(startupLifecycle: startupToken) }
        await transport.waitUntilSendStarted()
        view.setupLifecycle.invalidate()
        await transport.resumeSend()
        await restoreTask.value

        // Credential integrity preserved: the shared actor finished its
        // Keychain work even though the window closed mid-flight.
        XCTAssertEqual(try store.load()?.accessToken, "ghu_fresh",
                       "The close may let the actor finish the rotation; the durable session must be the fresh one.")
        // No new repository refresh creation: the only request consumed is
        // the rotation itself — an installations request would mean the
        // restore created a refresh task after teardown.
        let requestsAfterClose = await transport.requests()
        XCTAssertEqual(requestsAfterClose.count, 1,
                       "A close during revalidation must prevent the restore from creating a NEW refresh task.")

        // Control: the same setup without a close does create the repository
        // refresh (installations request), proving the barrier — not the
        // setup — blocked it. The store now holds a current session, so the
        // control restore skips rotation and goes straight to the refresh.
        let controlToken = view.setupLifecycle.generation
        let controlTask = Task { await view.restoreDeviceSession(startupLifecycle: controlToken) }
        try await Self.waitForCondition("the control restore to create its repository refresh") {
            await transport.requests().count == 2
        }
        await transport.resumeSend()
        await controlTask.value
        let requestsAfterControl = await transport.requests()
        XCTAssertEqual(requestsAfterControl.count, 2,
                       "Without a close the restore creates its repository refresh.")
    }

    /// Deterministic ordering test for guard point 2 of the restore barrier:
    /// the child re-check completed TRUE (its cancel raced a finished
    /// publish), and the close lands before the restore continuation runs.
    /// The captured lifecycle is stale, so the continuation must not stamp
    /// the schedule, publish status, or restart polling — the generation is
    /// the barrier, not cancelling an already-finished child task. The
    /// control cases pin the exact production decision.
    func testCloseAfterRefreshCompletedBlocksRestorePublication() {
        let view = makeDeviceSetupView()
        let gate = view.setupLifecycle
        let captured = gate.generation
        // The child completed true; the close lands in the continuation gap.
        gate.invalidate()
        XCTAssertFalse(
            view.publishDeviceRepositoryRestoreResult(lifecycleGeneration: captured, completed: true),
            "A close after the child completed must block status/stamp/poll publication.")
        // Control: a current lifecycle publishes (stamp, poll restart, status).
        XCTAssertTrue(
            view.publishDeviceRepositoryRestoreResult(lifecycleGeneration: gate.generation, completed: true),
            "A current lifecycle publishes the restore result.")
        // A false outcome is terminal regardless of the lifecycle.
        XCTAssertFalse(
            view.publishDeviceRepositoryRestoreResult(lifecycleGeneration: gate.generation, completed: false),
            "A cancelled/superseded re-check is terminal even with a current lifecycle.")
    }

    /// Deterministic ordering test for the device-flow barrier: the window
    /// closes while the device-code POLL is awaiting the token (every send is
    /// step-gated). The flow token was captured at `startDeviceFlow` (after
    /// the reset) and carried through the poll; the token delivered after the
    /// close can only be stale, so the late verification emits NO account/
    /// installation fetches, NO Keychain write, and NO UI. The control phase
    /// proves the same flow DOES verify and persist when no close lands.
    func testCloseDuringDeviceCodePollPreventsLateFlowPublication() async throws {
        let transport = StepGatedConnectTransport()
        let flow = GitHubDeviceFlow(
            configuration: GitHubDeviceFlowConfiguration(clientID: "Iv1.testclient"),
            transport: transport
        )
        let store = GitHubDeviceSessionStore(keychain: InMemoryConnectKeychain())
        let refresher = GitHubDeviceSessionRefresher(store: store)
        let view = makeDeviceSetupView(
            deviceFlow: flow,
            deviceSessionRefresher: refresher,
            openDeviceVerificationPage: { _ in true }
        )

        // Close phase: device code, then a token GitHub delivers AFTER the
        // window closes (the poll-token request is held in flight).
        await transport.enqueue(Data(#"{"device_code":"device-123","user_code":"WDJB-MJHT","verification_uri":"https://github.com/login/device","expires_in":900,"interval":1}"#.utf8))
        await transport.enqueue(Data(#"{"access_token":"ghu_late","refresh_token":"ghr_late","expires_in":3600,"refresh_token_expires_in":15897600,"scope":""}"#.utf8))

        guard let pollTask = view.startDeviceFlow() else {
            XCTFail("The flow must return its poll task handle.")
            return
        }
        await transport.waitUntilSendStarted(nth: 1)   // device-code request
        await transport.resumeSend(nth: 1)
        await transport.waitUntilSendStarted(nth: 2)   // poll-token request in flight
        view.setupLifecycle.invalidate()               // willClose/onDisappear/cancel bump
        await transport.resumeSend(nth: 2)             // the token arrives after close
        // Terminal completion barrier: the poll task finishes only AFTER its
        // carried finishDeviceFlow invocation has fully run (and rejected the
        // stale token at entry). With the fix no verification task, fetch, or
        // write can exist afterwards — the assertions below are final, not a
        // timed absence.
        await pollTask.value
        XCTAssertNil(try store.load(),
                     "A token arriving after close must not be verified or written.")
        let lateRequests = await transport.requests()
        XCTAssertEqual(lateRequests.count, 2,
                       "A late token must not start verification network work (account/installations).")

        // Control: a fresh flow WITHOUT the close verifies and persists.
        await transport.enqueue(Data(#"{"device_code":"device-456","user_code":"AAAA-BBBB","verification_uri":"https://github.com/login/device","expires_in":900,"interval":1}"#.utf8))
        await transport.enqueue(Data(#"{"access_token":"ghu_ok","refresh_token":"ghr_ok","expires_in":3600,"refresh_token_expires_in":15897600,"scope":""}"#.utf8))
        await transport.enqueue(Data(#"{"login":"octocat","id":1,"name":"Octo Cat","email":"octo@example.com"}"#.utf8))
        await transport.enqueue(Data(#"{"total_count":0,"installations":[]}"#.utf8))
        view.startDeviceFlow()
        for nth in [3, 4, 5, 6] {
            await transport.waitUntilSendStarted(nth: nth)
            await transport.resumeSend(nth: nth)
        }
        try await Self.waitForCondition("the control verification to persist the session") {
            (try? store.load()) != nil
        }
        let controlSession = try store.load()
        XCTAssertEqual(controlSession?.accessToken, "ghu_ok",
                       "Without a close the flow verifies and persists.")
        let controlRequests = await transport.requests()
        XCTAssertEqual(controlRequests.count, 6,
                       "The control flow completes its verification fetches.")
    }

    /// Deterministic ordering test for the startup chain: the window closes
    /// during an EARLIER startup await (`restoreCachedAuthorization`, which is
    /// held in flight on `connect.installations()`), before the device-session
    /// restore is ever invoked. The token captured at the outermost `.task`
    /// entry is stale, so the chain returns silently: NO restore rotation, NO
    /// repository refresh, NO githubContextLoaded publication, NO polling.
    func testCloseDuringEarlierStartupAwaitPreventsRestoreAndContextPublication() async throws {
        // Connect client with a step-gated transport; seed a session so
        // restoreCachedAuthorization reaches its network installations call.
        let connectTransport = StepGatedConnectTransport()
        let connectKeychain = InMemoryConnectKeychain()
        let sessionService = "test-startup-connect-\(UUID().uuidString)"
        let clock = TestConnectClock(Date(timeIntervalSince1970: 1_900_000_000))
        let connect = MSWConnectClient(
            configuration: testConnectConfiguration(),
            transport: connectTransport,
            keychain: connectKeychain,
            now: clock.now,
            sessionService: sessionService
        )
        let start = try await connect.startAuthorization()
        await connectTransport.enqueue(try testJSON(TestCallbackPayload(
            sessionID: UUID(),
            sessionToken: "opaque-service-session",
            account: GitHubAccount(login: "octocat", id: 1, name: nil, email: nil),
            expiresAt: clock.value.addingTimeInterval(3600)
        )))
        let seedTask = Task {
            try await connect.completeAuthorization(
                callbackURL: testCallbackURL(
                    configuration: testConnectConfiguration(),
                    state: start.state,
                    code: "one-time-code"
                )
            )
        }
        await connectTransport.waitUntilSendStarted(nth: 1)
        await connectTransport.resumeSend(nth: 1)
        _ = try await seedTask.value

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-startup-chain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }
        let broker = try CredentialBroker(
            keychain: InMemoryConnectKeychain(),
            metadataURL: temporary.appendingPathComponent("credentials.json"),
            keychainService: "test-startup-connect-broker-\(UUID().uuidString)"
        )
        let coordinator = GitHubAuthorizationCoordinator(
            broker: broker,
            connect: connect,
            now: clock.now,
            journalURL: temporary.appendingPathComponent("authorization-journal.json")
        )

        // Device flow with its own transport; the close phase must leave it
        // completely untouched (the restore is never invoked).
        let deviceTransport = GatedConnectTransport()
        let deviceFlow = GitHubDeviceFlow(
            configuration: GitHubDeviceFlowConfiguration(clientID: "Iv1.testclient"),
            transport: deviceTransport
        )
        let deviceStore = GitHubDeviceSessionStore(keychain: InMemoryConnectKeychain())
        try deviceStore.save(GitHubDeviceSession(
            schemaVersion: 1,
            clientID: "Iv1.testclient",
            account: GitHubAccount(login: "octocat", id: 1, name: "Octo Cat", email: "octo@example.com"),
            accessToken: "ghu_expired",
            refreshToken: "ghr_refresh",
            accessExpiresAt: Date(timeIntervalSinceNow: -60),
            refreshExpiresAt: Date().addingTimeInterval(15_897_600),
            obtainedAt: Date(timeIntervalSinceNow: -3600)
        ))
        let refresher = GitHubDeviceSessionRefresher(store: deviceStore)
        let view = makeDeviceSetupView(
            authorizationCoordinator: coordinator,
            deviceFlow: deviceFlow,
            deviceSessionRefresher: refresher
        )

        // The startup chain captures the token at its OUTERMOST entry and is
        // held inside restoreCachedAuthorization (connect.installations()).
        let startupToken = view.setupLifecycle.generation
        await connectTransport.enqueue(Data(#"{"installations":[]}"#.utf8))
        let chainTask = Task { await view.loadGitHubStartupContext() }
        await connectTransport.waitUntilSendStarted(nth: 2)   // installations in flight
        view.setupLifecycle.invalidate()                      // willClose/onDisappear/cancel bump
        await connectTransport.resumeSend(nth: 2)
        let completed = await chainTask.value

        XCTAssertFalse(completed,
                       "A closed startup chain must not publish githubContextLoaded.")
        let deviceRequests = await deviceTransport.requests()
        XCTAssertEqual(deviceRequests.count, 0,
                       "A close during an earlier startup await must prevent the restore from being invoked at all — no rotation, no refresh, no polling.")

        // Helper-level: the same stale token must suppress every helper
        // publication, not merely the restore — a close during the helper's
        // own awaits must not publish metadata/account/installations/status.
        let staleMetadata = await view.loadExistingMetadata(startupLifecycle: startupToken)
        XCTAssertNil(staleMetadata,
                     "A closed startup must not publish existing metadata.")
        // restoreCachedAuthorization's resume finishes (credential integrity
        // work completes), but its publications are suppressed.
        await connectTransport.enqueue(Data(#"{"installations":[]}"#.utf8))
        let staleRestoreTask = Task {
            await view.restoreCachedAuthorization(startupLifecycle: startupToken)
        }
        await connectTransport.waitUntilSendStarted(nth: 3)
        await connectTransport.resumeSend(nth: 3)
        let staleDiscovery = await staleRestoreTask.value
        XCTAssertNil(staleDiscovery,
                     "A closed startup must not publish account/installations/status from the cached authorization.")

        // Control: a fresh live token publishes (the metadata read returns
        // non-nil), proving the suppression above is the barrier, not the
        // setup.
        let liveToken = view.setupLifecycle.generation
        let liveMetadata = await view.loadExistingMetadata(startupLifecycle: liveToken)
        XCTAssertNotNil(liveMetadata,
                        "A current startup publishes existing metadata.")
    }

    /// Deterministic ordering test for flow supersession: flow A's token
    /// arrives AFTER flow B has started and its verification is in flight.
    /// `finishDeviceFlow(A)` must reject the stale carried token AT ENTRY —
    /// before cancelling `deviceVerificationTask` or bumping
    /// `deviceVerificationGeneration` — so A neither cancels B's live
    /// verification nor replaces its generation, and B still verifies and
    /// persists.
    func testLateTokenFromSupersededFlowDoesNotCancelNewerVerification() async throws {
        let transport = StepGatedConnectTransport()
        let flow = GitHubDeviceFlow(
            configuration: GitHubDeviceFlowConfiguration(clientID: "Iv1.testclient"),
            transport: transport
        )
        let store = GitHubDeviceSessionStore(keychain: InMemoryConnectKeychain())
        let refresher = GitHubDeviceSessionRefresher(store: store)
        let view = makeDeviceSetupView(
            deviceFlow: flow,
            deviceSessionRefresher: refresher,
            openDeviceVerificationPage: { _ in true }
        )

        await transport.enqueue(Data(#"{"device_code":"device-A","user_code":"AAAA-AAAA","verification_uri":"https://github.com/login/device","expires_in":900,"interval":1}"#.utf8))
        await transport.enqueue(Data(#"{"access_token":"ghu_late_a","refresh_token":"ghr_late_a","expires_in":3600,"refresh_token_expires_in":15897600,"scope":""}"#.utf8))
        await transport.enqueue(Data(#"{"device_code":"device-B","user_code":"BBBB-BBBB","verification_uri":"https://github.com/login/device","expires_in":900,"interval":1}"#.utf8))
        await transport.enqueue(Data(#"{"access_token":"ghu_b","refresh_token":"ghr_b","expires_in":3600,"refresh_token_expires_in":15897600,"scope":""}"#.utf8))
        await transport.enqueue(Data(#"{"login":"octocat","id":1,"name":"Octo Cat","email":"octo@example.com"}"#.utf8))
        await transport.enqueue(Data(#"{"total_count":0,"installations":[]}"#.utf8))

        // Flow A: device code requested; its poll-token request is held in
        // flight (the token has not arrived yet). Capture A's carried flow
        // token (the generation its startDeviceFlow captured after the reset).
        guard let pollA = view.startDeviceFlow() else {
            XCTFail("The flow must return its poll task handle.")
            return
        }
        let flowAToken = view.setupLifecycle.generation
        await transport.waitUntilSendStarted(nth: 1)
        await transport.resumeSend(nth: 1)
        await transport.waitUntilSendStarted(nth: 2)

        // Flow B starts (reset/reconnect): cancels A's poll, captures a new
        // flow token. B's device code is delivered, B's poll token arrives,
        // and B's verification is now in flight (fetching the account).
        _ = view.startDeviceFlow()
        await transport.waitUntilSendStarted(nth: 3)
        await transport.resumeSend(nth: 3)
        await transport.waitUntilSendStarted(nth: 4)
        await transport.resumeSend(nth: 4)
        await transport.waitUntilSendStarted(nth: 5)

        // A's late token arrives NOW, released EXACTLY as send #2 while B's
        // verification remains gated on its own sends. Awaiting A's poll
        // task is the terminal barrier: it completes only after A's carried
        // finishDeviceFlow has fully run — the stale-token entry guard
        // deterministically executes BEFORE B's responses are released, so
        // the bug (A cancelling B's task / bumping B's generation at entry)
        // cannot hide behind scheduler ordering.
        await transport.resumeSend(nth: 2)   // deliver A's late token
        await pollA.value

        // The entry-guard rejection is additionally observable directly:
        // invoking the finish entry synchronously with A's stale carried
        // token must be refused BEFORE any shared verification state is
        // touched (B's task and generation stay intact).
        let lateToken = GitHubDeviceToken(
            accessToken: "ghu_late_a",
            refreshToken: "ghr_late_a",
            expiresIn: 3600,
            refreshExpiresIn: 15_897_600,
            scope: ""
        )
        let accepted = view.finishDeviceFlow(token: lateToken, lifecycleGeneration: flowAToken)
        XCTAssertFalse(accepted,
                       "A stale flow token must be rejected at finish entry — before any verification state is touched.")

        await transport.resumeSend(nth: 5)   // B's account response
        await transport.waitUntilSendStarted(nth: 6)   // B's installations request
        await transport.resumeSend(nth: 6)   // B's installations response
        try await Self.waitForCondition("flow B's verification to persist") {
            (try? store.load()) != nil
        }
        let persisted = try store.load()
        XCTAssertEqual(persisted?.accessToken, "ghu_b",
                       "A late token from a superseded flow must not cancel or replace the newer flow's verification.")
        // Observed request ordinals: A's device code + poll token, then B's
        // device code + poll token, then B's verification fetches — and NOTHING
        // from A's late token (no extra account/installations requests).
        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 6,
                       "Flow A's late token must not start its own verification network work.")
        XCTAssertEqual(requests.map(\.url?.path), [
            "/login/device/code",
            "/login/oauth/access_token",
            "/login/device/code",
            "/login/oauth/access_token",
            "/user",
            "/user/installations",
        ], "The flows must proceed in exact ordinal order.")
    }

    func testDeviceVerificationMayPublishRequiresCurrentLifecycle() {
        XCTAssertTrue(SetupView.deviceVerificationMayPublish(
            taskCancelled: false,
            storedGeneration: 2,
            taskGeneration: 2,
            storedLifecycle: 3,
            capturedLifecycle: 3
        ), "The current verification with a current lifecycle may publish.")
        // A window close / disappear / flow cancellation during verification
        // bumps the stored lifecycle: publication is blocked even though the
        // verification identity is still current.
        XCTAssertFalse(SetupView.deviceVerificationMayPublish(
            taskCancelled: false,
            storedGeneration: 2,
            taskGeneration: 2,
            storedLifecycle: 4,
            capturedLifecycle: 3
        ), "A stale lifecycle must block verification publication even when the verification identity is current.")
        // Task cancellation and a superseded verification remain terminal.
        XCTAssertFalse(SetupView.deviceVerificationMayPublish(
            taskCancelled: true,
            storedGeneration: 2,
            taskGeneration: 2,
            storedLifecycle: 3,
            capturedLifecycle: 3
        ), "A cancelled verification must not publish.")
        XCTAssertFalse(SetupView.deviceVerificationMayPublish(
            taskCancelled: false,
            storedGeneration: 3,
            taskGeneration: 2,
            storedLifecycle: 3,
            capturedLifecycle: 3
        ), "A superseded verification must not publish.")
    }

    func testFalseRefreshOutcomeEndsPollerWithoutStampOrRetry() {
        let view = makeDeviceSetupView()
        XCTAssertFalse(view.continueDeviceRepositoryPolling(completed: false),
                       "A cancelled/superseded re-check must end THIS poller: no schedule stamp, no retry on the next wake.")
        XCTAssertTrue(view.continueDeviceRepositoryPolling(completed: true),
                      "A completed re-check stamps the schedule and lets the poller continue.")
    }

    func testDeviceRefreshIssueMessageSurfacesFailureDistinctFromEmptySelection() {
        let message = SetupView.deviceRefreshIssueMessage(
            for: GitHubDeviceFlowError.transportUnavailable,
            action: "listing installations"
        )
        XCTAssertTrue(message.hasPrefix("GitHub reported an error listing installations:"))
        XCTAssertTrue(message.contains("GitHub could not be reached"),
                      "The message must carry the actionable detail, not a bare zero.")
        XCTAssertFalse(message.contains("no repositories are selected"),
                       "A failure must not read like a genuine empty selection.")
    }

    func testRefreshIssueTakesPrecedenceOverZeroSelectionWording() {
        let account = GitHubAccount(login: "octocat", id: 1, name: "Octo Cat", email: nil)
        let issue = SetupView.deviceRefreshIssueMessage(
            for: GitHubDeviceFlowError.transportUnavailable,
            action: "listing installations"
        )
        // An active refresh failure must never produce zero-selection wording.
        let label = SetupView.deviceAccountLabel(login: account.login, repositoryCount: 0, refreshIssue: issue)
        XCTAssertFalse(label.contains("no repositories are selected"))
        XCTAssertTrue(label.contains("could not be refreshed"))
        let status = SetupView.deviceRepositorySignedInLine(login: account.login, repositoryCount: 0, refreshIssue: issue)
        XCTAssertFalse(status.contains("no repositories are selected"))
        XCTAssertTrue(status.contains("could not be refreshed"))
        // A genuine zero with no error keeps the existing wording exactly.
        XCTAssertTrue(SetupView.deviceAccountLabel(login: account.login, repositoryCount: 0, refreshIssue: nil).contains("no repositories are selected"))
        XCTAssertTrue(SetupView.deviceRepositorySignedInLine(login: account.login, repositoryCount: 0, refreshIssue: nil).contains("no repositories are selected"))
        // A connected account is unaffected by a refresh error.
        XCTAssertEqual(SetupView.deviceAccountLabel(login: account.login, repositoryCount: 2, refreshIssue: issue), "Connected as @octocat")
        // The header presentation suppresses the awaiting-repositories state.
        XCTAssertEqual(
            SetupView.connectionPresentation(account: nil, deviceAccount: account, deviceRepositoryCount: 0, deviceRefreshIssue: issue),
            .refreshFailed(account: account)
        )
        XCTAssertEqual(
            SetupView.connectionPresentation(account: nil, deviceAccount: account, deviceRepositoryCount: 0, deviceRefreshIssue: nil),
            .signedInAwaitingRepositories(account: account)
        )
        XCTAssertEqual(
            SetupView.connectionPresentation(account: nil, deviceAccount: account, deviceRepositoryCount: 2, deviceRefreshIssue: issue),
            .connected(account: account)
        )
    }

    func testDeviceSessionRefresherSubmitsSingleUseRefreshTokenOnce() async throws {
        let transport = QueueConnectTransport()
        let flow = GitHubDeviceFlow(
            configuration: GitHubDeviceFlowConfiguration(clientID: "Iv1.testclient"),
            transport: transport
        )
        let keychain = InMemoryConnectKeychain()
        let store = GitHubDeviceSessionStore(keychain: keychain)
        try store.save(GitHubDeviceSession(
            schemaVersion: 1,
            clientID: "Iv1.testclient",
            account: GitHubAccount(login: "octocat", id: 1, name: "Octo Cat", email: "octo@example.com"),
            accessToken: "ghu_expired",
            refreshToken: "ghr_refresh",
            accessExpiresAt: Date(timeIntervalSinceNow: -60),
            refreshExpiresAt: Date().addingTimeInterval(15_897_600),
            obtainedAt: Date(timeIntervalSinceNow: -3600)
        ))
        // Exactly one refresh-token submission is enqueued: a concurrent
        // revalidation must coalesce onto the first and re-load the persisted
        // rotated session instead of submitting the single-use token again.
        await transport.enqueue(Data(#"{"access_token":"ghu_fresh","refresh_token":"ghr_fresh2","expires_in":3600,"refresh_token_expires_in":15897600,"scope":""}"#.utf8))
        let refresher = GitHubDeviceSessionRefresher(store: store)
        async let first: GitHubDeviceSessionRefreshOutcome = refresher.revalidatedSession(using: flow)
        async let second: GitHubDeviceSessionRefreshOutcome = refresher.revalidatedSession(using: flow)
        let (a, b) = try await (first, second)
        XCTAssertEqual(currentSession(of: a)?.accessToken, "ghu_fresh")
        XCTAssertEqual(currentSession(of: b)?.accessToken, "ghu_fresh")
        XCTAssertEqual(try store.load()?.accessToken, "ghu_fresh")
    }

    func testDeviceSessionRefresherPoisonsConsumedGenerationWhenSaveFails() async throws {
        let transport = QueueConnectTransport()
        let flow = GitHubDeviceFlow(
            configuration: GitHubDeviceFlowConfiguration(clientID: "Iv1.testclient"),
            transport: transport
        )
        // Save #1 (fixture) succeeds; save #2 (rotated session) fails; save #3
        // (poison marker) succeeds — the consumed generation is poisoned
        // fail-closed instead of being left retryable.
        let store = GitHubDeviceSessionStore(keychain: WindowedFailingSaveKeychain(failingSaves: [2]))
        try store.save(GitHubDeviceSession(
            schemaVersion: 1,
            clientID: "Iv1.testclient",
            account: GitHubAccount(login: "octocat", id: 1, name: "Octo Cat", email: "octo@example.com"),
            accessToken: "ghu_expired",
            refreshToken: "ghr_refresh",
            accessExpiresAt: Date(timeIntervalSinceNow: -60),
            refreshExpiresAt: Date().addingTimeInterval(15_897_600),
            obtainedAt: Date(timeIntervalSinceNow: -3600)
        ))
        await transport.enqueue(Data(#"{"access_token":"ghu_fresh","refresh_token":"ghr_fresh2","expires_in":3600,"refresh_token_expires_in":15897600,"scope":""}"#.utf8))
        let refresher = GitHubDeviceSessionRefresher(store: store)
        let session = currentSession(of: try await refresher.revalidatedSession(using: flow))
        XCTAssertTrue(session?.isAccessExpired ?? false, "A poisoned generation must read as expired.")
        XCTAssertNil(session?.refreshToken, "The poison must strip the consumed refresh token.")
        XCTAssertEqual(try store.load()?.refreshToken, nil, "The durable record must be poisoned too.")
        // A subsequent call must not resubmit the single-use token (the queue
        // is empty — any refresh attempt would throw).
        let again = currentSession(of: try await refresher.revalidatedSession(using: flow))
        XCTAssertNil(again?.refreshToken)
        XCTAssertTrue(again?.isAccessExpired ?? false)
    }

    func testDeviceSessionRefresherQuarantinesWhenPoisonAlsoFails() async throws {
        let transport = QueueConnectTransport()
        let flow = GitHubDeviceFlow(
            configuration: GitHubDeviceFlowConfiguration(clientID: "Iv1.testclient"),
            transport: transport
        )
        // Save #1 (fixture) succeeds; saves #2 (rotated) and #3 (poison) and
        // the quarantine helper's best-effort poison (#4) all fail — the
        // consumed OLD record stays durable, so only the in-memory tombstone
        // can keep the state reauthorization-only.
        let store = GitHubDeviceSessionStore(keychain: WindowedFailingSaveKeychain(failingSaves: [2, 3, 4]))
        try store.save(GitHubDeviceSession(
            schemaVersion: 1,
            clientID: "Iv1.testclient",
            account: GitHubAccount(login: "octocat", id: 1, name: "Octo Cat", email: "octo@example.com"),
            accessToken: "ghu_expired",
            refreshToken: "ghr_refresh",
            accessExpiresAt: Date(timeIntervalSinceNow: -60),
            refreshExpiresAt: Date().addingTimeInterval(15_897_600),
            obtainedAt: Date(timeIntervalSinceNow: -3600)
        ))
        await transport.enqueue(Data(#"{"access_token":"ghu_fresh","refresh_token":"ghr_fresh2","expires_in":3600,"refresh_token_expires_in":15897600,"scope":""}"#.utf8))
        let refresher = GitHubDeviceSessionRefresher(store: store)
        let outcome = try await refresher.revalidatedSession(using: flow)
        guard case .reauthorizationRequired(let generation) = outcome else {
            XCTFail("A consumed generation that cannot be poisoned must fail closed into reauthorization.")
            return
        }
        // The terminal outcome carries the post-operation epoch: a guard
        // comparing against it must not self-suppress the operation's own
        // quarantine result.
        let currentGeneration = await refresher.currentSessionGeneration()
        XCTAssertEqual(generation, currentGeneration)
        // The in-memory tombstone must keep every later call reauthorization-
        // only (no resubmission — the queue is empty, so any refresh attempt
        // would throw), even though the consumed pair is still durable.
        let again = currentSession(of: try await refresher.revalidatedSession(using: flow))
        XCTAssertTrue(again?.isAccessExpired ?? false, "The quarantined generation must stay reauthorization-only.")
        XCTAssertEqual(again?.refreshToken, "ghr_refresh", "The durable record still holds the consumed pair; only the tombstone blocks resubmission.")
        let message = SetupView.deviceRefreshIssueMessage(for: GitHubDeviceSessionRefreshError.keychainSaveFailed, action: "refreshing your GitHub session")
        XCTAssertTrue(message.contains("Reconnect to GitHub to continue"), "The recovery guidance must name reauthorization.")
    }

    func testDeviceSessionRefresherTreatsInvalidGrantAsReauthorizationRequired() async throws {
        let transport = QueueConnectTransport()
        let flow = GitHubDeviceFlow(
            configuration: GitHubDeviceFlowConfiguration(clientID: "Iv1.testclient"),
            transport: transport
        )
        let store = GitHubDeviceSessionStore(keychain: InMemoryConnectKeychain())
        try store.save(GitHubDeviceSession(
            schemaVersion: 1,
            clientID: "Iv1.testclient",
            account: GitHubAccount(login: "octocat", id: 1, name: "Octo Cat", email: "octo@example.com"),
            accessToken: "ghu_expired",
            refreshToken: "ghr_refresh",
            accessExpiresAt: Date(timeIntervalSinceNow: -60),
            refreshExpiresAt: Date().addingTimeInterval(15_897_600),
            obtainedAt: Date(timeIntervalSinceNow: -3600)
        ))
        // Relaunch detection: GitHub rejects the (consumed) grant; the actor
        // tombstones it and surfaces the session as reauthorization-required
        // instead of resubmitting it.
        await transport.enqueue(Data(#"{"error":"invalid_grant","error_description":"The refresh token is no longer valid."}"#.utf8))
        let refresher = GitHubDeviceSessionRefresher(store: store)
        let session = currentSession(of: try await refresher.revalidatedSession(using: flow))
        XCTAssertTrue(session?.isAccessExpired ?? false)
        // Tombstoned: a subsequent call must not resubmit (empty queue).
        let again = currentSession(of: try await refresher.revalidatedSession(using: flow))
        XCTAssertTrue(again?.isAccessExpired ?? false)
    }

    func testDeviceSessionRefresherQuarantinesOnLoadFailureAfterConsumption() async throws {
        let transport = QueueConnectTransport()
        let flow = GitHubDeviceFlow(
            configuration: GitHubDeviceFlowConfiguration(clientID: "Iv1.testclient"),
            transport: transport
        )
        // Load #1 (initial session) succeeds; load #2 (generation guard after
        // GitHub accepted the refresh) fails — the consumed pair must still be
        // quarantined (tombstoned, reauthorization-only), never resubmittable.
        let store = GitHubDeviceSessionStore(keychain: WindowedFailingLoadKeychain(failingLoads: [2]))
        try store.save(GitHubDeviceSession(
            schemaVersion: 1,
            clientID: "Iv1.testclient",
            account: GitHubAccount(login: "octocat", id: 1, name: "Octo Cat", email: "octo@example.com"),
            accessToken: "ghu_expired",
            refreshToken: "ghr_refresh",
            accessExpiresAt: Date(timeIntervalSinceNow: -60),
            refreshExpiresAt: Date().addingTimeInterval(15_897_600),
            obtainedAt: Date(timeIntervalSinceNow: -3600)
        ))
        await transport.enqueue(Data(#"{"access_token":"ghu_fresh","refresh_token":"ghr_fresh2","expires_in":3600,"refresh_token_expires_in":15897600,"scope":""}"#.utf8))
        let refresher = GitHubDeviceSessionRefresher(store: store)
        let outcome = try await refresher.revalidatedSession(using: flow)
        guard case .reauthorizationRequired = outcome else {
            XCTFail("A post-consumption Keychain read failure must fail closed into reauthorization.")
            return
        }
        // Tombstoned (and best-effort poisoned): the next call must not
        // resubmit the single-use token (the queue is empty — any refresh
        // attempt would throw).
        let again = currentSession(of: try await refresher.revalidatedSession(using: flow))
        XCTAssertTrue(again?.isAccessExpired ?? false, "The quarantined generation must stay reauthorization-only.")
    }

    func testDeviceSessionRefresherTombstonesConsumedTokenAfterAcceptedRefresh() async throws {
        let transport = QueueConnectTransport()
        let flow = GitHubDeviceFlow(
            configuration: GitHubDeviceFlowConfiguration(clientID: "Iv1.testclient"),
            transport: transport
        )
        let store = GitHubDeviceSessionStore(keychain: InMemoryConnectKeychain())
        let session = GitHubDeviceSession(
            schemaVersion: 1,
            clientID: "Iv1.testclient",
            account: GitHubAccount(login: "octocat", id: 1, name: "Octo Cat", email: "octo@example.com"),
            accessToken: "ghu_expired",
            refreshToken: "ghr_refresh",
            accessExpiresAt: Date(timeIntervalSinceNow: -60),
            refreshExpiresAt: Date().addingTimeInterval(15_897_600),
            obtainedAt: Date(timeIntervalSinceNow: -3600)
        )
        try store.save(session)
        await transport.enqueue(Data(#"{"access_token":"ghu_fresh","refresh_token":"ghr_fresh2","expires_in":3600,"refresh_token_expires_in":15897600,"scope":""}"#.utf8))
        let refresher = GitHubDeviceSessionRefresher(store: store)
        let rotated = currentSession(of: try await refresher.revalidatedSession(using: flow))
        XCTAssertEqual(rotated?.accessToken, "ghu_fresh")
        // Simulate the rotated write being lost (e.g. a concurrent revert):
        // the consumed pair is back in the store. The tombstone recorded at
        // refresh-acceptance time must keep the next call from resubmitting
        // the single-use token (the queue is empty — any refresh attempt
        // would throw).
        try store.save(session)
        let again = currentSession(of: try await refresher.revalidatedSession(using: flow))
        XCTAssertTrue(again?.isAccessExpired ?? false, "A tombstoned consumed pair must stay reauthorization-only.")
        XCTAssertEqual(again?.refreshToken, "ghr_refresh")
    }

    func testDeviceSessionRefresherReturnsPostOperationGenerationForGuard() async throws {
        let transport = QueueConnectTransport()
        let flow = GitHubDeviceFlow(
            configuration: GitHubDeviceFlowConfiguration(clientID: "Iv1.testclient"),
            transport: transport
        )
        let store = GitHubDeviceSessionStore(keychain: InMemoryConnectKeychain())
        try store.save(GitHubDeviceSession(
            schemaVersion: 1,
            clientID: "Iv1.testclient",
            account: GitHubAccount(login: "octocat", id: 1, name: "Octo Cat", email: "octo@example.com"),
            accessToken: "ghu_expired",
            refreshToken: "ghr_refresh",
            accessExpiresAt: Date(timeIntervalSinceNow: -60),
            refreshExpiresAt: Date().addingTimeInterval(15_897_600),
            obtainedAt: Date(timeIntervalSinceNow: -3600)
        ))
        await transport.enqueue(Data(#"{"access_token":"ghu_fresh","refresh_token":"ghr_fresh2","expires_in":3600,"refresh_token_expires_in":15897600,"scope":""}"#.utf8))
        let refresher = GitHubDeviceSessionRefresher(store: store)
        let outcome = try await refresher.revalidatedSession(using: flow)
        guard case .current(let session, let generation) = outcome, let session else {
            XCTFail("A rotation must produce a current outcome with the rotated session.")
            return
        }
        XCTAssertEqual(session.accessToken, "ghu_fresh")
        // The returned generation is the POST-operation epoch: a publication
        // guard comparing against it (the Settings pattern) must NOT
        // self-suppress the operation's own rotated result.
        let currentGeneration = await refresher.currentSessionGeneration()
        XCTAssertEqual(generation, currentGeneration)
    }

    func testDeviceSessionRefresherReplacementWinsOverQuarantineAfterLoadFailure() async throws {
        let transport = GatedConnectTransport()
        let flow = GitHubDeviceFlow(
            configuration: GitHubDeviceFlowConfiguration(clientID: "Iv1.testclient"),
            transport: transport
        )
        // Load #1 (initial expired session) succeeds; the post-refresh
        // generation load (#2) fails. A fresh sign-in lands during the
        // refresh await, so quarantine reconciliation must yield to the
        // replacement instead of surfacing reauthorization over it.
        let keychain = WindowedFailingLoadKeychain(failingLoads: [2])
        let store = GitHubDeviceSessionStore(keychain: keychain)
        let expired = GitHubDeviceSession(
            schemaVersion: 1,
            clientID: "Iv1.testclient",
            account: GitHubAccount(login: "octocat", id: 1, name: "Octo Cat", email: "octo@example.com"),
            accessToken: "ghu_expired",
            refreshToken: "ghr_refresh",
            accessExpiresAt: Date(timeIntervalSinceNow: -60),
            refreshExpiresAt: Date().addingTimeInterval(15_897_600),
            obtainedAt: Date(timeIntervalSinceNow: -3600)
        )
        try store.save(expired)
        await transport.enqueue(Data(#"{"access_token":"ghu_fresh","refresh_token":"ghr_fresh2","expires_in":3600,"refresh_token_expires_in":15897600,"scope":""}"#.utf8))
        let refresher = GitHubDeviceSessionRefresher(store: store)
        let replacement = GitHubDeviceSession(
            schemaVersion: 1,
            clientID: "Iv1.testclient",
            account: GitHubAccount(login: "monalisa", id: 2, name: "Mona Lisa", email: nil),
            accessToken: "ghu_replacement",
            refreshToken: "ghr_replacement",
            accessExpiresAt: Date().addingTimeInterval(3600),
            refreshExpiresAt: Date().addingTimeInterval(15_897_600),
            obtainedAt: Date()
        )
        async let outcome = refresher.revalidatedSession(using: flow)
        // Deterministic interleaving: the barrier returns only after the
        // refresh request has entered the transport (so the starting epoch
        // and the initial load have both happened). Replace the session
        // only then, and release the refresh response last.
        await transport.waitUntilSendStarted()
        try await refresher.replaceCurrentSession(with: replacement)
        await transport.resumeSend()
        let result = try await outcome
        guard case .superseded = result else {
            XCTFail("A replacement that won the epoch must supersede quarantine, not surface reauthorization.")
            return
        }
        // The fresh replacement is preserved and wins; exactly two loads ran
        // (the starting read plus the post-refresh generation guard that
        // failed), so .superseded really came from the quarantine
        // reconciliation rather than from skipping the guard read.
        XCTAssertEqual(keychain.storedSession()?.accessToken, "ghu_replacement")
        XCTAssertEqual(keychain.observedLoadCount, 2)
    }

    func testDeviceSessionRefresherInvalidGrantDoesNotPublishOverReplacement() async throws {
        let transport = GatedConnectTransport()
        let flow = GitHubDeviceFlow(
            configuration: GitHubDeviceFlowConfiguration(clientID: "Iv1.testclient"),
            transport: transport
        )
        // Load #1 (initial expired session) succeeds; the injected load
        // failure at #2 must remain UNCONSUMED. A fresh sign-in lands during
        // the network await: correct starting-epoch handling returns
        // .superseded BEFORE the invalid-grant fallback reload, so the
        // stale expired session is never paired with the fresh epoch and the
        // reload never runs over the replacement.
        let keychain = WindowedFailingLoadKeychain(failingLoads: [2])
        let store = GitHubDeviceSessionStore(keychain: keychain)
        let expired = GitHubDeviceSession(
            schemaVersion: 1,
            clientID: "Iv1.testclient",
            account: GitHubAccount(login: "octocat", id: 1, name: "Octo Cat", email: "octo@example.com"),
            accessToken: "ghu_expired",
            refreshToken: "ghr_refresh",
            accessExpiresAt: Date(timeIntervalSinceNow: -60),
            refreshExpiresAt: Date().addingTimeInterval(15_897_600),
            obtainedAt: Date(timeIntervalSinceNow: -3600)
        )
        try store.save(expired)
        await transport.enqueue(Data(#"{"error":"invalid_grant","error_description":"The refresh token is no longer valid."}"#.utf8))
        let refresher = GitHubDeviceSessionRefresher(store: store)
        let replacement = GitHubDeviceSession(
            schemaVersion: 1,
            clientID: "Iv1.testclient",
            account: GitHubAccount(login: "monalisa", id: 2, name: "Mona Lisa", email: nil),
            accessToken: "ghu_replacement",
            refreshToken: "ghr_replacement",
            accessExpiresAt: Date().addingTimeInterval(3600),
            refreshExpiresAt: Date().addingTimeInterval(15_897_600),
            obtainedAt: Date()
        )
        async let outcome = refresher.revalidatedSession(using: flow)
        // Deterministic interleaving: the barrier returns only after the
        // refresh request has entered the transport (so the starting epoch
        // and the initial load have both happened). Replace the session
        // only then, and release the invalid-grant response last.
        await transport.waitUntilSendStarted()
        try await refresher.replaceCurrentSession(with: replacement)
        await transport.resumeSend()
        let result = try await outcome
        guard case .superseded = result else {
            XCTFail("invalidGrant must never pair a stale session with a fresh epoch.")
            return
        }
        // The replacement is preserved untouched, and production performed
        // exactly one load (the starting read): the invalid-grant branch
        // returned .superseded BEFORE the fallback reload, so it neither
        // paired the stale expired session with the fresh epoch nor
        // reloaded/published over the replacement.
        XCTAssertEqual(keychain.storedSession()?.accessToken, "ghu_replacement")
        XCTAssertEqual(keychain.observedLoadCount, 1)
    }

    func testDeviceSessionRefresherReplaceCurrentSessionIsCancellationSafe() async throws {
        let store = GitHubDeviceSessionStore(keychain: InMemoryConnectKeychain())
        let refresher = GitHubDeviceSessionRefresher(store: store)
        let session = GitHubDeviceSession(
            schemaVersion: 1,
            clientID: "Iv1.testclient",
            account: GitHubAccount(login: "octocat", id: 1, name: "Octo Cat", email: "octo@example.com"),
            accessToken: "ghu_new",
            refreshToken: "ghr_new",
            accessExpiresAt: Date().addingTimeInterval(3600),
            refreshExpiresAt: Date().addingTimeInterval(15_897_600),
            obtainedAt: Date()
        )
        // Cancelled before the actor hop runs: the boundary re-check inside
        // replaceCurrentSession must prevent the write.
        let task = Task { try await refresher.replaceCurrentSession(with: session) }
        task.cancel()
        do {
            try await task.value
            XCTFail("A cancelled sign-in save must not write.")
        } catch is CancellationError {
            // expected: nothing published, nothing written
        }
        XCTAssertNil(try store.load(), "A cancelled call must not write the session record.")
    }

    func testConnectionPresentationNeverClaimsDisconnectedWhileSignedIn() {
        let deviceAccount = GitHubAccount(login: "octocat", id: 1, name: "Octo Cat", email: "octo@example.com")
        let coordinatorAccount = GitHubAccount(login: "monalisa", id: 2, name: "Mona Lisa", email: nil)
        // A device-flow sign-in alone is shown as signed in, never as
        // disconnected, even before any repositories are accessible.
        XCTAssertEqual(
            SetupView.connectionPresentation(account: nil, deviceAccount: deviceAccount, deviceRepositoryCount: 0),
            .signedInAwaitingRepositories(account: deviceAccount)
        )
        // Once repositories are accessible the header says connected.
        XCTAssertEqual(
            SetupView.connectionPresentation(account: nil, deviceAccount: deviceAccount, deviceRepositoryCount: 2),
            .connected(account: deviceAccount)
        )
        // The device flow is the presented connection path, so its account
        // wins over a restored MSW Connect coordinator session.
        XCTAssertEqual(
            SetupView.connectionPresentation(account: coordinatorAccount, deviceAccount: deviceAccount, deviceRepositoryCount: 1),
            .connected(account: deviceAccount)
        )
        // A coordinator-only session still renders as connected.
        XCTAssertEqual(
            SetupView.connectionPresentation(account: coordinatorAccount, deviceAccount: nil, deviceRepositoryCount: 0),
            .connected(account: coordinatorAccount)
        )
        // No session at all is the only disconnected state.
        XCTAssertEqual(
            SetupView.connectionPresentation(account: nil, deviceAccount: nil, deviceRepositoryCount: 0),
            .notConnected
        )
    }

    func testGitHubDeviceFlowInstallationWithZeroRepositoriesDecodesEmpty() async throws {
        // An installation can exist while granting access to zero repositories;
        // the repositories endpoint must surface that as an empty list so the
        // decision gate stays closed.
        let transport = QueueConnectTransport()
        await transport.enqueue(Data(#"{"repositories":[]}"#.utf8))
        let client = GitHubDeviceFlow(
            configuration: GitHubDeviceFlowConfiguration(clientID: "Iv1.testclient"),
            transport: transport
        )
        let repositories = try await client.repositories(accessToken: "ghu_token", installationID: 7)
        XCTAssertTrue(repositories.isEmpty)
        XCTAssertFalse(
            SetupView.deviceAccessDecided(signedIn: true, repositoryCount: repositories.count),
            "An installation with zero repositories must not decide the GitHub step."
        )
    }

    func testRepositoryPolicyCarriesStableIdentityAndDefaultsReadOnly() throws {
        let policy = GitHubRepositoryPolicy(
            workspace: "dev",
            repositoryID: 101,
            fullName: "acme/one",
            installationID: 42,
            ownerID: 7,
            ownerLogin: "acme",
            ownerType: "Organization"
        )
        let data = try JSONEncoder().encode(policy)
        let decoded = try JSONDecoder().decode(GitHubRepositoryPolicy.self, from: data)
        XCTAssertEqual(decoded, policy)
        XCTAssertEqual(decoded.id, "dev.42.101")
        XCTAssertEqual(decoded.mode, .readOnly)
        XCTAssertEqual(GitHubRepositoryAccessMode.readOnly.label, "Read-only")
        XCTAssertEqual(GitHubRepositoryAccessMode.readWrite.label, "Read & write")
    }

    func testGitHubDeviceSessionExpiryHelpers() {
        let future = Date().addingTimeInterval(3600)
        let past = Date().addingTimeInterval(-3600)
        let active = GitHubDeviceSession(
            schemaVersion: 1, clientID: "Iv1.testclient",
            account: GitHubAccount(login: "octocat", id: 1, name: nil, email: nil),
            accessToken: "ghu_access", refreshToken: "ghr_refresh",
            accessExpiresAt: future, refreshExpiresAt: future, obtainedAt: Date()
        )
        XCTAssertFalse(active.isAccessExpired)
        XCTAssertTrue(active.canRefresh)

        let expired = GitHubDeviceSession(
            schemaVersion: 1, clientID: "Iv1.testclient",
            account: GitHubAccount(login: "octocat", id: 1, name: nil, email: nil),
            accessToken: "ghu_access", refreshToken: nil,
            accessExpiresAt: past, refreshExpiresAt: future, obtainedAt: Date()
        )
        XCTAssertTrue(expired.isAccessExpired)
        XCTAssertFalse(expired.canRefresh)
    }

    func testReviewCompletionRequiresLoadedGitHubContextEvenWithPersistedCompletedChoices() {
        // Review and Done must stay closed until the GitHub context loads.
        XCTAssertFalse(SetupView.allowsReviewCompletion(
            contextLoaded: false,
            systemReady: true,
            githubDecided: true,
            identityDecided: true,
            verificationsAllowCompletion: true
        ), "Persisted completed choices must not enable Review/Done before the GitHub context loads.")
        XCTAssertTrue(SetupView.allowsReviewCompletion(
            contextLoaded: true,
            systemReady: true,
            githubDecided: true,
            identityDecided: true,
            verificationsAllowCompletion: true
        ))
        XCTAssertFalse(SetupView.allowsReviewCompletion(
            contextLoaded: true,
            systemReady: true,
            githubDecided: false,
            identityDecided: true,
            verificationsAllowCompletion: true
        ))
        XCTAssertFalse(SetupView.allowsReviewCompletion(
            contextLoaded: true,
            systemReady: false,
            githubDecided: true,
            identityDecided: true,
            verificationsAllowCompletion: true
        ))
    }

    func testMSWConnectSessionSurvivesRestoreFromAnotherConfiguration() async throws {
        let keychain = InMemoryConnectKeychain()
        let clock = TestConnectClock(Date(timeIntervalSince1970: 1_900_000_000))
        let sessionService = "test-connect-retained-\(UUID().uuidString)"

        let transport = QueueConnectTransport()
        let configuredClient = MSWConnectClient(
            configuration: testConnectConfiguration(),
            transport: transport,
            keychain: keychain,
            now: clock.now,
            sessionService: sessionService
        )
        let start = try await configuredClient.startAuthorization()
        await transport.enqueue(try testJSON(TestCallbackPayload(
            sessionID: UUID(),
            sessionToken: "opaque-service-session",
            account: GitHubAccount(login: "octocat", id: 1, name: nil, email: nil),
            expiresAt: clock.value.addingTimeInterval(3600)
        )))
        _ = try await configuredClient.completeAuthorization(
            callbackURL: testCallbackURL(
                configuration: testConnectConfiguration(),
                state: start.state,
                code: "one-time-code"
            )
        )

        // A different configuration must neither restore nor delete the session.
        let otherClient = MSWConnectClient(
            configuration: MSWConnectConfiguration(
                baseURL: URL(string: "https://other-connect.test")!,
                clientID: "other-client"
            ),
            transport: QueueConnectTransport(),
            keychain: keychain,
            now: clock.now,
            sessionService: sessionService
        )
        let otherRestored = try await otherClient.restoreSession()
        XCTAssertNil(otherRestored)

        // The unconfigured sentinel configuration must also leave it alone.
        let sentinelClient = MSWConnectClient(
            configuration: MSWConnectConfiguration(),
            transport: QueueConnectTransport(),
            keychain: keychain,
            now: clock.now,
            sessionService: sessionService
        )
        let sentinelRestored = try await sentinelClient.restoreSession()
        XCTAssertNil(sentinelRestored)

        // The owning configuration can still restore the retained session.
        let restored = try await configuredClient.restoreSession()
        XCTAssertEqual(restored?.account.login, "octocat")
    }

    func testMSWConnectAuthorizationSurfacesUnavailableCallbackExchange() async throws {
        let transport = QueueConnectTransport()
        let client = MSWConnectClient(
            configuration: testConnectConfiguration(),
            transport: transport,
            keychain: InMemoryConnectKeychain(),
            sessionService: "test-connect-unavailable-\(UUID().uuidString)"
        )

        do {
            _ = try await client.authorize(browser: TestConnectBrowser())
            XCTFail("An unavailable callback exchange must fail.")
        } catch let error as MSWConnectError {
            XCTAssertEqual(error, .transportUnavailable)
        }

        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.httpMethod, "POST")
        XCTAssertEqual(requests.first?.url?.path, "/oauth/callback")
    }

    func testMSWConnectRejectsUnsafeClientConfiguration() {
        let configuration = MSWConnectConfiguration(
            baseURL: URL(string: "https://connect.test")!,
            clientID: "client id",
            redirectURL: URL(string: "msw://connect.microsandbox.dev/oauth/callback")!,
            authorizationPath: "/oauth/authorize",
            callbackPath: "/oauth/callback"
        )

        XCTAssertThrowsError(try configuration.validate()) { error in
            XCTAssertEqual(error as? MSWConnectError, .invalidConfiguration)
        }
    }
    func testMSWConnectAcceptsOnlyConfiguredGitHubInstallationURL() throws {
        let approved = MSWConnectConfiguration(
            baseURL: URL(string: "https://connect.test")!,
            clientID: "test-client",
            redirectURL: URL(string: "msw://connect.microsandbox.dev/oauth/callback")!,
            authorizationPath: "/oauth/authorize",
            callbackPath: "/oauth/callback",
            installationURL: URL(string: "https://github.com/apps/msw/installations/new")!
        )
        XCTAssertNoThrow(try approved.validate())
        XCTAssertTrue(approved.isConfigured)

        let rejected = [
            URL(string: "https://github.com/apps/msw/installations/new?state=1")!,
            URL(string: "https://example.com/apps/msw/installations/new")!,
            URL(string: "https://github.com/apps/msw/installations/../new")!
        ]
        for installationURL in rejected {
            let configuration = MSWConnectConfiguration(
                baseURL: URL(string: "https://connect.test")!,
                clientID: "test-client",
                redirectURL: URL(string: "msw://connect.microsandbox.dev/oauth/callback")!,
                authorizationPath: "/oauth/authorize",
                callbackPath: "/oauth/callback",
                installationURL: installationURL
            )
            XCTAssertThrowsError(try configuration.validate()) { error in
                XCTAssertEqual(error as? MSWConnectError, .invalidConfiguration)
            }
            XCTAssertFalse(configuration.isConfigured)
        }
    }

    func testAuthorizationMapsRemovedInstallationToOwnerNotInstalled() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-installation-removed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let clock = TestConnectClock(Date(timeIntervalSince1970: 1_900_000_000))
        let transport = QueueConnectTransport()
        let keychain = InMemoryConnectKeychain()
        let client = MSWConnectClient(
            configuration: testConnectConfiguration(),
            transport: transport,
            keychain: keychain,
            now: clock.now,
            sessionService: "test-installation-removed-\(UUID().uuidString)"
        )
        let broker = try CredentialBroker(
            keychain: keychain,
            metadataURL: temporary.appendingPathComponent("credentials.json"),
            keychainService: "test-installation-removed-broker-\(UUID().uuidString)"
        )
        let coordinator = GitHubAuthorizationCoordinator(
            broker: broker,
            connect: client,
            now: clock.now,
            journalURL: temporary.appendingPathComponent("authorization-journal.json")
        )
        let owner = GitHubInstallationAccount(login: "acme", id: 42, type: "Organization")
        let installation = GitHubInstallation(id: 42, account: owner, repositorySelection: "selected")
        let repository = GitHubRepository(
            id: 7,
            fullName: "acme/one",
            name: "one",
            owner: owner,
            private: true,
            defaultBranch: "main"
        )

        await transport.enqueue(try testJSON(TestCallbackPayload(
            sessionID: UUID(),
            sessionToken: "opaque-service-session",
            account: GitHubAccount(login: "octocat", id: 1, name: nil, email: nil),
            expiresAt: clock.value.addingTimeInterval(3600)
        )))
        await transport.enqueue(try testJSON(TestInstallationResponse(installations: [installation])))
        let discovery = try await coordinator.beginAuthorization(browser: TestConnectBrowser())

        await transport.enqueue(try testJSON(TestRepositoryResponse(repositories: [repository])))
        await transport.enqueue(
            Data(#"{"error":{"code":"installation_removed","message":"installation removed"}}"#.utf8),
            status: 404
        )
        let policy = GitHubRepositoryPolicy(
            workspace: "dev",
            repositoryID: repository.id,
            fullName: repository.fullName,
            installationID: installation.id,
            ownerID: owner.id,
            ownerLogin: owner.login,
            ownerType: owner.type
        )

        do {
            _ = try await coordinator.commitPolicy(
                sessionID: discovery.sessionID,
                policy: [policy]
            )
            XCTFail("A removed installation must require owner reauthorization.")
        } catch let error as GitHubAuthorizationError {
            XCTAssertEqual(error, .ownerNotInstalled)
        }
    }


    func testRepositoryPolicyRejectsMultipleInstallationsForOneWorkspace() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-policy-partition-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }
        let keychain = InMemoryConnectKeychain()
        let transport = QueueConnectTransport()
        let clock = TestConnectClock(Date(timeIntervalSince1970: 1_900_000_000))
        let connect = MSWConnectClient(
            configuration: testConnectConfiguration(),
            transport: transport,
            keychain: keychain,
            now: clock.now,
            sessionService: "test-policy-partition-\(UUID().uuidString)"
        )
        let broker = try CredentialBroker(
            keychain: keychain,
            metadataURL: temporary.appendingPathComponent("credentials.json"),
            keychainService: "test-policy-partition-broker-\(UUID().uuidString)"
        )
        let coordinator = GitHubAuthorizationCoordinator(broker: broker, connect: connect, now: clock.now)
        let acme = GitHubInstallationAccount(login: "acme", id: 7, type: "Organization")
        let other = GitHubInstallationAccount(login: "other", id: 8, type: "Organization")
        await transport.enqueue(try testJSON(TestCallbackPayload(
            sessionID: UUID(),
            sessionToken: "opaque-service-session",
            account: GitHubAccount(login: "octocat", id: 1, name: nil, email: nil),
            expiresAt: clock.value.addingTimeInterval(3600)
        )))
        await transport.enqueue(try testJSON(TestInstallationResponse(installations: [
            GitHubInstallation(id: 42, account: acme, repositorySelection: "selected"),
            GitHubInstallation(id: 43, account: other, repositorySelection: "selected")
        ])))
        let discovery = try await coordinator.beginAuthorization(browser: TestConnectBrowser())
        let policy = [
            GitHubRepositoryPolicy(workspace: "dev", repositoryID: 1, fullName: "acme/one", installationID: 42, ownerID: 7, ownerLogin: "acme", ownerType: "Organization"),
            GitHubRepositoryPolicy(workspace: "dev", repositoryID: 2, fullName: "other/two", installationID: 43, ownerID: 8, ownerLogin: "other", ownerType: "Organization")
        ]
        do {
            _ = try await coordinator.commitPolicy(sessionID: discovery.sessionID, policy: policy)
            XCTFail("The single host credential slot cannot represent two installations.")
        } catch let error as GitHubAuthorizationError {
            XCTAssertEqual(error, .multipleInstallationsUnsupported("dev"))
        }
        let requests = await transport.requests()
        XCTAssertEqual(requests.filter { $0.url?.path == "/v1/grants" }.count, 0)
    }

    func testOneConnectSessionCommitsIndependentWorkspaceGrants() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-connect-assignments-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let keychain = InMemoryConnectKeychain()
        let transport = QueueConnectTransport()
        let clock = TestConnectClock(Date(timeIntervalSince1970: 1_900_000_000))
        let configuration = testConnectConfiguration()
        let connect = MSWConnectClient(
            configuration: configuration,
            transport: transport,
            keychain: keychain,
            now: clock.now,
            sessionService: "test-connect-\(UUID().uuidString)"
        )
        let broker = try CredentialBroker(
            keychain: keychain,
            metadataURL: temporary.appendingPathComponent("credentials.json"),
            keychainService: "test-scoped-\(UUID().uuidString)"
        )
        let coordinator = GitHubAuthorizationCoordinator(
            broker: broker,
            connect: connect,
            now: clock.now
        )
        let owner = GitHubInstallationAccount(login: "acme", id: 42, type: "Organization")
        let installation = GitHubInstallation(id: 42, account: owner, repositorySelection: "selected")
        let repositories = [
            GitHubRepository(
                id: 7,
                fullName: "acme/one",
                name: "one",
                owner: owner,
                private: true,
                defaultBranch: "main"
            ),
            GitHubRepository(
                id: 8,
                fullName: "acme/two",
                name: "two",
                owner: owner,
                private: true,
                defaultBranch: "main"
            )
        ]

        await transport.enqueue(try testJSON(TestCallbackPayload(
            sessionID: UUID(),
            sessionToken: "opaque-service-session",
            account: GitHubAccount(login: "octocat", id: 1, name: nil, email: nil),
            expiresAt: clock.value.addingTimeInterval(3600)
        )))
        await transport.enqueue(try testJSON(TestInstallationResponse(installations: [installation])))
        let discovery = try await coordinator.beginAuthorization(browser: TestConnectBrowser())
        XCTAssertEqual(discovery.account.login, "octocat")
        XCTAssertEqual(discovery.installations, [installation])

        let devPolicy = GitHubRepositoryPolicy(
            workspace: "dev",
            repositoryID: 7,
            fullName: "acme/one",
            installationID: 42,
            ownerID: owner.id,
            ownerLogin: owner.login,
            ownerType: owner.type
        )
        let personalPolicy = GitHubRepositoryPolicy(
            workspace: "personal",
            repositoryID: 8,
            fullName: "acme/two",
            installationID: 42,
            ownerID: owner.id,
            ownerLogin: owner.login,
            ownerType: owner.type,
            mode: .readWrite
        )

        await transport.enqueue(try testJSON(TestRepositoryResponse(repositories: repositories)))
        await transport.enqueue(try testJSON(MSWConnectGrant(
            id: UUID(),
            workspace: "dev",
            role: .guest,
            accountLogin: "octocat",
            owner: "acme",
            installationID: 42,
            repositoryIDs: [7],
            repositoryNames: ["acme/one"],
            accessMode: "read-only",
            verificationRepository: "acme/one",
            accessToken: "ghs_dev_token",
            accessExpiresAt: clock.value.addingTimeInterval(1800),
            generation: 1
        )))
        await transport.enqueue(try testJSON(TestRepositoryResponse(repositories: repositories)))
        await transport.enqueue(try testJSON(MSWConnectGrant(
            id: UUID(),
            workspace: "personal",
            role: .guest,
            accountLogin: "octocat",
            owner: "acme",
            installationID: 42,
            repositoryIDs: [8],
            repositoryNames: ["acme/two"],
            accessMode: "read-only",
            verificationRepository: "acme/two",
            accessToken: "ghs_personal_read_token",
            accessExpiresAt: clock.value.addingTimeInterval(1800),
            generation: 1
        )))
        await transport.enqueue(try testJSON(MSWConnectGrant(
            id: UUID(),
            workspace: "personal",
            role: .host,
            accountLogin: "octocat",
            owner: "acme",
            installationID: 42,
            repositoryIDs: [8],
            repositoryNames: ["acme/two"],
            accessMode: "host-write",
            verificationRepository: "acme/two",
            accessToken: "ghs_personal_write_token",
            accessExpiresAt: clock.value.addingTimeInterval(1800),
            generation: 1
        )))

        let metadata = try await coordinator.commitPolicy(
            sessionID: discovery.sessionID,
            policy: [devPolicy, personalPolicy]
        )
        XCTAssertEqual(metadata.map(\.id), ["dev.guest", "personal.guest", "personal.host"])
        let personalMetadata = try await broker.metadata(for: "personal", role: .host)
        XCTAssertEqual(personalMetadata?.accessMode, "host-write")
        let devBundle = try await broker.load(workspace: "dev", role: .guest)
        XCTAssertEqual(devBundle.credential.accessToken, "ghs_dev_token")

        do {
            _ = try await coordinator.commitPolicy(
                sessionID: discovery.sessionID,
                policy: [devPolicy]
            )
            XCTFail("A committed authorization session must not be reusable.")
        } catch let error as GitHubAuthorizationError {
            XCTAssertEqual(error, .authorizationSessionExpired)
        }
    }

    func testAuthorizationRecoveryRevokesReplacementAfterIncompleteLocalCommit() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-connect-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let keychain = InMemoryConnectKeychain()
        let transport = QueueConnectTransport()
        let clock = TestConnectClock(Date(timeIntervalSince1970: 1_900_000_000))
        let configuration = testConnectConfiguration()
        let sessionService = "test-connect-recovery-\(UUID().uuidString)"
        let connect = MSWConnectClient(
            configuration: configuration,
            transport: transport,
            keychain: keychain,
            now: clock.now,
            sessionService: sessionService
        )
        let broker = try CredentialBroker(
            keychain: keychain,
            metadataURL: temporary.appendingPathComponent("credentials.json"),
            keychainService: "test-recovery-\(UUID().uuidString)"
        )
        let start = try await connect.startAuthorization()
        let sessionID = UUID()
        await transport.enqueue(try testJSON(TestCallbackPayload(
            sessionID: sessionID,
            sessionToken: "opaque-recovery-session",
            account: GitHubAccount(login: "octocat", id: 1, name: nil, email: nil),
            expiresAt: clock.value.addingTimeInterval(3600)
        )))
        _ = try await connect.completeAuthorization(
            callbackURL: testCallbackURL(configuration: configuration, state: start.state, code: "recovery-code")
        )

        let replacementID = UUID()
        let journalURL = temporary.appendingPathComponent("authorization-transaction.json")
        let formatter = ISO8601DateFormatter()
        let journal: [String: Any] = [
            "transactionID": UUID().uuidString,
            "sessionID": sessionID.uuidString,
            "workspaceKeys": ["dev.guest"],
            "newGrantIDs": [replacementID.uuidString],
            "oldGrantIDs": [],
            "phase": "localCommitted",
            "updatedAt": formatter.string(from: clock.value)
        ]
        try JSONSerialization.data(withJSONObject: journal).write(to: journalURL)

        await transport.enqueue(try testJSON(MSWConnectRevocationReceipt(
            grantID: replacementID,
            revoked: true,
            terminal: true,
            revokedAt: clock.value
        )))
        let coordinator = GitHubAuthorizationCoordinator(
            broker: broker,
            connect: connect,
            now: clock.now,
            journalURL: journalURL
        )

        do {
            try await coordinator.recoverPendingAuthorization()
            XCTFail("An incomplete local commit must remain explicitly recoverable.")
        } catch let error as GitHubAuthorizationError {
            XCTAssertEqual(error, .revocationFailed)
        }

        let requests = await transport.requests()
        let revokeRequest = try XCTUnwrap(requests.last)
        XCTAssertEqual(revokeRequest.httpMethod, "DELETE")
        XCTAssertEqual(revokeRequest.url?.path, "/v1/grants/\(replacementID.uuidString)")

        let persisted = try JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as? [String: Any]
        XCTAssertEqual(persisted?["phase"] as? String, "rollingBack")
        XCTAssertEqual((persisted?["newGrantIDs"] as? [String])?.count, 0)

        try await coordinator.recoverPendingAuthorization()
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
        let quarantined = try await broker.metadata(for: "dev", role: .guest)
        XCTAssertEqual(quarantined?.recoveryState, .quarantined)
        XCTAssertTrue(quarantined?.quarantined == true)
    }
    func testAuthorizationMetadataWaitsForPreparedJournalRecovery() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-connect-startup-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let journalURL = temporary.appendingPathComponent("authorization-transaction.json")
        let formatter = ISO8601DateFormatter()
        let journal: [String: Any] = [
            "transactionID": UUID().uuidString,
            "sessionID": UUID().uuidString,
            "workspaceKeys": ["dev.guest"],
            "newGrantIDs": [],
            "oldGrantIDs": [],
            "phase": "prepared",
            "updatedAt": formatter.string(from: Date())
        ]
        try JSONSerialization.data(withJSONObject: journal).write(to: journalURL)

        let broker = try CredentialBroker(
            keychain: InMemoryConnectKeychain(),
            metadataURL: temporary.appendingPathComponent("credentials.json"),
            keychainService: "test-startup-recovery-\(UUID().uuidString)"
        )
        let coordinator = GitHubAuthorizationCoordinator(
            broker: broker,
            journalURL: journalURL
        )

        let metadata = await coordinator.metadata()

        let entry = try XCTUnwrap(metadata.first { $0.id == "dev.guest" })
        XCTAssertEqual(entry.recoveryState, .quarantined)
        XCTAssertTrue(entry.quarantined)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
    }

    func testPreparedRecoveryQuarantinesPartialLocalCommitAndPreservesJournalOnServiceOutage() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-connect-prepared-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let keychain = InMemoryConnectKeychain()
        let clock = TestConnectClock(Date(timeIntervalSince1970: 1_900_000_000))
        let newGrantID = UUID()
        let broker = try CredentialBroker(
            keychain: keychain,
            metadataURL: temporary.appendingPathComponent("credentials.json"),
            keychainService: "test-prepared-recovery-\(UUID().uuidString)"
        )
        try await broker.storeScopedCredential(
            ScopedInstallationCredential(
                grantID: newGrantID,
                accessToken: "ghs_partial_prepared",
                accessExpiresAt: clock.value.addingTimeInterval(1800),
                generation: 1
            ),
            workspace: "dev",
            accessMode: "read-only",
            verificationRepository: "acme/one",
            installationID: 42,
            role: .guest,
            accountLogin: "octocat",
            owner: "acme",
            repositoryIDs: [7],
            repositoryNames: ["acme/one"]
        )

        let journalURL = temporary.appendingPathComponent("authorization-transaction.json")
        let formatter = ISO8601DateFormatter()
        let journal: [String: Any] = [
            "transactionID": UUID().uuidString,
            "sessionID": UUID().uuidString,
            "workspaceKeys": ["dev.guest", "dev.host"],
            "newGrantIDs": [newGrantID.uuidString],
            "oldGrantIDs": [],
            "phase": "prepared",
            "updatedAt": formatter.string(from: clock.value)
        ]
        try JSONSerialization.data(withJSONObject: journal).write(to: journalURL)

        let connect = MSWConnectClient(
            configuration: testConnectConfiguration(),
            transport: QueueConnectTransport(),
            keychain: keychain,
            now: clock.now,
            sessionService: "test-prepared-connect-\(UUID().uuidString)"
        )
        let coordinator = GitHubAuthorizationCoordinator(
            broker: broker,
            connect: connect,
            now: clock.now,
            journalURL: journalURL
        )

        do {
            try await coordinator.recoverPendingAuthorization()
            XCTFail("A prepared transaction with uncertain cleanup must remain durable.")
        } catch let error as GitHubAuthorizationError {
            XCTAssertEqual(error, .serviceUnavailable)
        }

        for role in CredentialRole.allCases {
            let optionalEntry = try await broker.metadata(for: "dev", role: role)
            let entry = try XCTUnwrap(optionalEntry)
            XCTAssertEqual(entry.recoveryState, .quarantined)
            XCTAssertTrue(entry.quarantined)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))
        let persisted = try JSONSerialization.jsonObject(
            with: Data(contentsOf: journalURL)
        ) as? [String: Any]
        XCTAssertEqual((persisted?["newGrantIDs"] as? [String])?.count, 1)
    }

    func testOldGrantRevokeTransportFailureQuarantinesEveryJournalRole() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-connect-old-revoke-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let keychain = InMemoryConnectKeychain()
        let transport = QueueConnectTransport()
        let clock = TestConnectClock(Date(timeIntervalSince1970: 1_900_000_000))
        let configuration = testConnectConfiguration()
        let sessionService = "test-old-revoke-connect-\(UUID().uuidString)"
        let connect = MSWConnectClient(
            configuration: configuration,
            transport: transport,
            keychain: keychain,
            now: clock.now,
            sessionService: sessionService
        )
        let broker = try CredentialBroker(
            keychain: keychain,
            metadataURL: temporary.appendingPathComponent("credentials.json"),
            keychainService: "test-old-revoke-broker-\(UUID().uuidString)"
        )
        let oldGrantID = UUID()
        for (role, accessMode, token) in [
            (CredentialRole.guest, "read-only", "ghs_old_guest"),
            (CredentialRole.host, "host-write", "ghs_old_host")
        ] as [(CredentialRole, String, String)] {
            try await broker.storeScopedCredential(
                ScopedInstallationCredential(
                    grantID: oldGrantID,
                    accessToken: token,
                    accessExpiresAt: clock.value.addingTimeInterval(1800),
                    generation: 1
                ),
                workspace: "dev",
                accessMode: accessMode,
                verificationRepository: "acme/one",
                installationID: 42,
                role: role,
                accountLogin: "octocat",
                owner: "acme",
                repositoryIDs: [7],
                repositoryNames: ["acme/one"]
            )
        }

        let start = try await connect.startAuthorization()
        let sessionID = UUID()
        await transport.enqueue(try testJSON(TestCallbackPayload(
            sessionID: sessionID,
            sessionToken: "opaque-old-revoke-session",
            account: GitHubAccount(login: "octocat", id: 1, name: nil, email: nil),
            expiresAt: clock.value.addingTimeInterval(3600)
        )))
        _ = try await connect.completeAuthorization(
            callbackURL: testCallbackURL(configuration: configuration, state: start.state, code: "old-revoke")
        )

        let journalURL = temporary.appendingPathComponent("authorization-transaction.json")
        let formatter = ISO8601DateFormatter()
        let journal: [String: Any] = [
            "transactionID": UUID().uuidString,
            "sessionID": sessionID.uuidString,
            "workspaceKeys": ["dev.guest", "dev.host"],
            "newGrantIDs": [],
            "oldGrantIDs": [oldGrantID.uuidString],
            "phase": "revokingOld",
            "updatedAt": formatter.string(from: clock.value)
        ]
        try JSONSerialization.data(withJSONObject: journal).write(to: journalURL)
        let coordinator = GitHubAuthorizationCoordinator(
            broker: broker,
            connect: connect,
            now: clock.now,
            journalURL: journalURL
        )

        do {
            try await coordinator.recoverPendingAuthorization()
            XCTFail("Transport failure must keep old-grant cleanup uncertain.")
        } catch let error as GitHubAuthorizationError {
            XCTAssertEqual(error, .serviceUnavailable)
        }

        for role in CredentialRole.allCases {
            let optionalEntry = try await broker.metadata(for: "dev", role: role)
            let entry = try XCTUnwrap(optionalEntry)
            XCTAssertEqual(entry.recoveryState, .quarantined)
            XCTAssertTrue(entry.quarantined)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))
        let persisted = try JSONSerialization.jsonObject(
            with: Data(contentsOf: journalURL)
        ) as? [String: Any]
        XCTAssertEqual(persisted?["phase"] as? String, "revokingOld")
        XCTAssertEqual((persisted?["oldGrantIDs"] as? [String])?.count, 1)
    }

    func testReadWriteToReadOnlyRecoveryRemovesOldHostRole() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-connect-access-replacement-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let keychain = InMemoryConnectKeychain()
        let transport = QueueConnectTransport()
        let clock = TestConnectClock(Date(timeIntervalSince1970: 1_900_000_000))
        let configuration = testConnectConfiguration()
        let connect = MSWConnectClient(
            configuration: configuration,
            transport: transport,
            keychain: keychain,
            now: clock.now,
            sessionService: "test-access-replacement-connect-\(UUID().uuidString)"
        )
        let broker = try CredentialBroker(
            keychain: keychain,
            metadataURL: temporary.appendingPathComponent("credentials.json"),
            keychainService: "test-access-replacement-broker-\(UUID().uuidString)"
        )
        let oldGuestID = UUID()
        let oldHostID = UUID()
        let newGuestID = UUID()
        try await broker.storeScopedCredential(
            ScopedInstallationCredential(
                grantID: oldGuestID,
                accessToken: "ghs_old_guest_replacement",
                accessExpiresAt: clock.value.addingTimeInterval(1800),
                generation: 1
            ),
            workspace: "dev",
            accessMode: "read-only",
            verificationRepository: "acme/one",
            installationID: 42,
            role: .guest,
            accountLogin: "octocat",
            owner: "acme",
            repositoryIDs: [7],
            repositoryNames: ["acme/one"]
        )
        try await broker.storeScopedCredential(
            ScopedInstallationCredential(
                grantID: oldHostID,
                accessToken: "ghs_old_host_replacement",
                accessExpiresAt: clock.value.addingTimeInterval(1800),
                generation: 1
            ),
            workspace: "dev",
            accessMode: "host-write",
            verificationRepository: "acme/one",
            installationID: 42,
            role: .host,
            accountLogin: "octocat",
            owner: "acme",
            repositoryIDs: [7],
            repositoryNames: ["acme/one"]
        )
        try await broker.storeScopedCredential(
            ScopedInstallationCredential(
                grantID: newGuestID,
                accessToken: "ghs_new_guest_replacement",
                accessExpiresAt: clock.value.addingTimeInterval(1800),
                generation: 2
            ),
            workspace: "dev",
            accessMode: "read-only",
            verificationRepository: "acme/one",
            installationID: 42,
            role: .guest,
            accountLogin: "octocat",
            owner: "acme",
            repositoryIDs: [7],
            repositoryNames: ["acme/one"]
        )

        let start = try await connect.startAuthorization()
        let sessionID = UUID()
        await transport.enqueue(try testJSON(TestCallbackPayload(
            sessionID: sessionID,
            sessionToken: "opaque-access-replacement-session",
            account: GitHubAccount(login: "octocat", id: 1, name: nil, email: nil),
            expiresAt: clock.value.addingTimeInterval(3600)
        )))
        _ = try await connect.completeAuthorization(
            callbackURL: testCallbackURL(
                configuration: configuration,
                state: start.state,
                code: "access-replacement"
            )
        )
        await transport.enqueue(try testJSON(MSWConnectRevocationReceipt(
            grantID: oldGuestID,
            revoked: true,
            terminal: true,
            revokedAt: clock.value
        )))
        await transport.enqueue(try testJSON(MSWConnectRevocationReceipt(
            grantID: oldHostID,
            revoked: true,
            terminal: true,
            revokedAt: clock.value
        )))

        let journalURL = temporary.appendingPathComponent("authorization-transaction.json")
        let formatter = ISO8601DateFormatter()
        let journal: [String: Any] = [
            "transactionID": UUID().uuidString,
            "sessionID": sessionID.uuidString,
            "workspaceKeys": ["dev.guest", "dev.host"],
            "newGrantIDs": [newGuestID.uuidString],
            "oldGrantIDs": [oldGuestID.uuidString, oldHostID.uuidString],
            "phase": "revokingOld",
            "updatedAt": formatter.string(from: clock.value)
        ]
        try JSONSerialization.data(withJSONObject: journal).write(to: journalURL)
        let coordinator = GitHubAuthorizationCoordinator(
            broker: broker,
            connect: connect,
            now: clock.now,
            journalURL: journalURL
        )

        try await coordinator.recoverPendingAuthorization()
        let optionalGuest = try await broker.metadata(for: "dev", role: .guest)
        let guest = try XCTUnwrap(optionalGuest)
        XCTAssertEqual(guest.grantID, newGuestID)
        XCTAssertEqual(guest.recoveryState, .ready)
        XCTAssertFalse(guest.quarantined)
        let host = try await broker.metadata(for: "dev", role: .host)
        XCTAssertNil(host)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
        let revokeRequests = await transport.requests().filter { $0.httpMethod == "DELETE" }
        XCTAssertEqual(revokeRequests.count, 2)
    }

    func testExpiredSessionRecoveryQuarantinesAndAllowsFreshAuthorizationRetry() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-connect-expired-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let keychain = InMemoryConnectKeychain()
        let transport = QueueConnectTransport()
        let clock = TestConnectClock(Date(timeIntervalSince1970: 1_900_000_000))
        let configuration = testConnectConfiguration()
        let connect = MSWConnectClient(
            configuration: configuration,
            transport: transport,
            keychain: keychain,
            now: clock.now,
            sessionService: "test-expired-recovery-connect-\(UUID().uuidString)"
        )
        let broker = try CredentialBroker(
            keychain: keychain,
            metadataURL: temporary.appendingPathComponent("credentials.json"),
            keychainService: "test-expired-recovery-broker-\(UUID().uuidString)"
        )
        let oldGrantID = UUID()
        try await broker.storeScopedCredential(
            ScopedInstallationCredential(
                grantID: oldGrantID,
                accessToken: "ghs_expired_session_old",
                accessExpiresAt: clock.value.addingTimeInterval(1800),
                generation: 1
            ),
            workspace: "dev",
            accessMode: "read-only",
            verificationRepository: "acme/one",
            installationID: 42,
            role: .guest,
            accountLogin: "octocat",
            owner: "acme",
            repositoryIDs: [7],
            repositoryNames: ["acme/one"]
        )

        let journalURL = temporary.appendingPathComponent("authorization-transaction.json")
        let formatter = ISO8601DateFormatter()
        let journal: [String: Any] = [
            "transactionID": UUID().uuidString,
            "sessionID": UUID().uuidString,
            "workspaceKeys": ["dev.guest"],
            "newGrantIDs": [],
            "oldGrantIDs": [oldGrantID.uuidString],
            "phase": "localCommitted",
            "updatedAt": formatter.string(from: clock.value)
        ]
        try JSONSerialization.data(withJSONObject: journal).write(to: journalURL)
        let coordinator = GitHubAuthorizationCoordinator(
            broker: broker,
            connect: connect,
            now: clock.now,
            journalURL: journalURL
        )

        do {
            try await coordinator.recoverPendingAuthorization()
            XCTFail("An expired session cannot be treated as proof of revocation.")
        } catch let error as GitHubAuthorizationError {
            XCTAssertEqual(error, .serviceUnavailable)
        }
        let optionalQuarantined = try await broker.metadata(for: "dev", role: .guest)
        let quarantined = try XCTUnwrap(optionalQuarantined)
        XCTAssertEqual(quarantined.recoveryState, .quarantined)
        XCTAssertTrue(quarantined.quarantined)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))

        let newSessionID = UUID()
        await transport.enqueue(try testJSON(TestCallbackPayload(
            sessionID: newSessionID,
            sessionToken: "opaque-fresh-session",
            account: GitHubAccount(login: "octocat", id: 1, name: nil, email: nil),
            expiresAt: clock.value.addingTimeInterval(3600)
        )))
        await transport.enqueue(try testJSON(TestInstallationResponse(installations: [])))
        let discovery = try await coordinator.beginAuthorization(browser: TestConnectBrowser())
        XCTAssertEqual(discovery.sessionID, newSessionID)
        XCTAssertEqual(discovery.account.login, "octocat")
    }


    func testMSWConnectGrantRequestUsesReviewedRepositoryScope() async throws {
        let keychain = InMemoryConnectKeychain()
        let transport = QueueConnectTransport()
        let clock = TestConnectClock(Date(timeIntervalSince1970: 1_900_000_000))
        let configuration = testConnectConfiguration()
        let client = MSWConnectClient(
            configuration: configuration,
            transport: transport,
            keychain: keychain,
            now: clock.now,
            sessionService: "test-connect-\(UUID().uuidString)"
        )

        let start = try await client.startAuthorization()
        await transport.enqueue(try testJSON(TestCallbackPayload(
            sessionID: UUID(),
            sessionToken: "opaque-service-session",
            account: GitHubAccount(login: "octocat", id: 1, name: nil, email: nil),
            expiresAt: clock.value.addingTimeInterval(3600)
        )))
        _ = try await client.completeAuthorization(
            callbackURL: testCallbackURL(configuration: configuration, state: start.state, code: "code")
        )

        let grant = MSWConnectGrant(
            id: UUID(),
            workspace: "dev",
            role: .guest,
            accountLogin: "octocat",
            owner: "acme",
            installationID: 42,
            repositoryIDs: [7],
            repositoryNames: ["acme/one"],
            accessMode: "read-only",
            verificationRepository: "acme/one",
            accessToken: "ghs_scoped_token",
            accessExpiresAt: clock.value.addingTimeInterval(1800),
            generation: 1
        )
        await transport.enqueue(try testJSON(grant))
        let assignment = MSWConnectGrantAssignment(
            workspace: "dev",
            role: .guest,
            owner: "acme",
            installationID: 42,
            repositoryIDs: [7],
            repositoryNames: ["acme/one"],
            accessMode: "read-only",
            verificationRepository: "acme/one"
        )
        let returned = try await client.createGrant(assignment)
        XCTAssertEqual(returned.credential.accessToken, "ghs_scoped_token")

        let requests = await transport.requests()
        let grantRequest = try XCTUnwrap(requests.last)
        XCTAssertEqual(grantRequest.url?.path, "/v1/grants")
        XCTAssertEqual(grantRequest.value(forHTTPHeaderField: "Authorization"), "Bearer opaque-service-session")
        let body = try XCTUnwrap(grantRequest.httpBody)
        let sent = try JSONDecoder().decode(MSWConnectGrantAssignment.self, from: body)
        XCTAssertEqual(sent, assignment)
        let bodyText = String(decoding: body, as: UTF8.self)
        XCTAssertFalse(bodyText.contains("refresh_token"))
        XCTAssertFalse(bodyText.contains("access_token"))
    }
    func testMSWConnectRejectsGrantWithExtraRepositoryScope() async throws {
        let keychain = InMemoryConnectKeychain()
        let transport = QueueConnectTransport()
        let clock = TestConnectClock(Date(timeIntervalSince1970: 1_900_000_000))
        let configuration = testConnectConfiguration()
        let client = MSWConnectClient(
            configuration: configuration,
            transport: transport,
            keychain: keychain,
            now: clock.now,
            sessionService: "test-connect-\(UUID().uuidString)"
        )

        let start = try await client.startAuthorization()
        await transport.enqueue(try testJSON(TestCallbackPayload(
            sessionID: UUID(),
            sessionToken: "opaque-service-session",
            account: GitHubAccount(login: "octocat", id: 1, name: nil, email: nil),
            expiresAt: clock.value.addingTimeInterval(3600)
        )))
        _ = try await client.completeAuthorization(
            callbackURL: testCallbackURL(configuration: configuration, state: start.state, code: "code")
        )

        await transport.enqueue(try testJSON(MSWConnectGrant(
            id: UUID(),
            workspace: "dev",
            role: .guest,
            accountLogin: "octocat",
            owner: "acme",
            installationID: 42,
            repositoryIDs: [7, 8],
            repositoryNames: ["acme/one", "acme/two"],
            accessMode: "read-only",
            verificationRepository: "acme/one",
            accessToken: "ghs_scoped_token",
            accessExpiresAt: clock.value.addingTimeInterval(1800),
            generation: 1
        )))
        let assignment = MSWConnectGrantAssignment(
            workspace: "dev",
            role: .guest,
            owner: "acme",
            installationID: 42,
            repositoryIDs: [7],
            repositoryNames: ["acme/one"],
            accessMode: "read-only",
            verificationRepository: "acme/one"
        )
        do {
            _ = try await client.createGrant(assignment)
            XCTFail("A grant containing an extra repository must be rejected.")
        } catch let error as MSWConnectError {
            XCTAssertEqual(error, .scopeMismatch)
        }
    }

    func testCredentialBrokerMetadataContainsNoScopedTokenBytes() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-scoped-credential-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let metadataURL = temporary.appendingPathComponent("credentials.json")
        let service = "test-scoped-\(UUID().uuidString)"
        let broker = try CredentialBroker(
            keychain: InMemoryConnectKeychain(),
            metadataURL: metadataURL,
            keychainService: service
        )
        let token = "ghs_test_scoped_token"
        let credential = ScopedInstallationCredential(
            grantID: UUID(),
            accessToken: token,
            accessExpiresAt: Date().addingTimeInterval(1800),
            generation: 1
        )
        try await broker.storeScopedCredential(
            credential,
            workspace: "dev",
            accessMode: "read-only",
            verificationRepository: "acme/one",
            installationID: 42,
            role: .guest,
            accountLogin: "octocat",
            owner: "acme",
            repositoryIDs: [7],
            repositoryNames: ["acme/one"]
        )

        let metadataText = try String(contentsOf: metadataURL, encoding: .utf8)
        XCTAssertFalse(metadataText.contains(token))
        XCTAssertFalse(metadataText.contains("accessToken"))
        XCTAssertFalse(metadataText.contains("refreshToken"))
        let loaded = try await broker.load(workspace: "dev", role: .guest)
        XCTAssertEqual(loaded.credential.grantID, credential.grantID)
        XCTAssertEqual(loaded.credential.accessToken, credential.accessToken)
        XCTAssertEqual(loaded.credential.generation, credential.generation)
        XCTAssertEqual(loaded.credential.accessExpiresAt.timeIntervalSince1970,
                       credential.accessExpiresAt.timeIntervalSince1970,
                       accuracy: 1)
        do {
            try await broker.storeScopedCredential(
                ScopedInstallationCredential(
                    grantID: UUID(),
                    accessToken: "ghp_broad-user-token",
                    accessExpiresAt: Date().addingTimeInterval(1800),
                    generation: 1
                ),
                workspace: "dev",
                accessMode: "read-only",
                verificationRepository: "acme/one",
                installationID: 42,
                role: .guest,
                accountLogin: "octocat",
                owner: "acme",
                repositoryIDs: [7],
                repositoryNames: ["acme/one"]
            )
            XCTFail("A broad GitHub user token must not be stored as an installation credential.")
        } catch let error as CredentialBrokerError {
            XCTAssertEqual(error, .invalidCredential)
        }

        try await broker.remove(workspace: "dev", role: .guest)
    }

    func testLegacyWorkspaceMetadataRequiresExplicitReauthorization() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-legacy-credential-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }
        let metadataURL = temporary.appendingPathComponent("credentials.json")
        let legacy: [String: Any] = [
            "schemaVersion": 2,
            "entries": [
                "dev.guest": [
                    "workspace": "dev",
                    "schemaVersion": 2,
                    "role": "guest",
                    "provider": "github-app-user",
                    "accessMode": "read-only",
                    "verificationRepository": "acme/one",
                    "generation": 1,
                    "quarantined": false,
                    "updatedAt": "2026-08-10T00:00:00Z"
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: legacy).write(to: metadataURL)
        let keychain = InMemoryConnectKeychain()
        try keychain.save(KeychainItem(service: "msw.github.read", account: "dev", secret: Data("legacy-read".utf8)))
        try keychain.save(KeychainItem(service: "msw.github.write", account: "dev", secret: Data("legacy-write".utf8)))
        let broker = try CredentialBroker(keychain: keychain, metadataURL: metadataURL)
        let optionalEntry = try await broker.metadata(for: "dev", role: .guest)
        let entry = try XCTUnwrap(optionalEntry)
        XCTAssertEqual(entry.provider, "legacy-broad-token")
        XCTAssertEqual(entry.recoveryState, .migrationRequired)
        XCTAssertTrue(entry.quarantined)
        do {
            _ = try await broker.load(workspace: "dev", role: .guest)
            XCTFail("Legacy broad credentials must not load as scoped grants.")
        } catch let error as CredentialBrokerError {
            XCTAssertEqual(error, .legacyCredentialRequiresAuthorization)
        }
        XCTAssertThrowsError(try keychain.load(service: "msw.github.read", account: "dev"))
        XCTAssertThrowsError(try keychain.load(service: "msw.github.write", account: "dev"))
    }

    // MARK: - Verified Connect -> Apply integration
    func testVerifiedConnectApplyPersistsScopedMetadataAfterMSWVerification() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-verified-connect-apply-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let keychain = InMemoryConnectKeychain()
        let metadataURL = temporary.appendingPathComponent("credentials.json")
        let service = "test-verified-\(UUID().uuidString)"
        let broker = try CredentialBroker(
            keychain: keychain,
            metadataURL: metadataURL,
            keychainService: service
        )
        let transport = QueueConnectTransport()
        let clock = TestConnectClock(Date(timeIntervalSince1970: 1_900_000_000))
        let configuration = testConnectConfiguration()
        let connect = MSWConnectClient(
            configuration: configuration,
            transport: transport,
            keychain: keychain,
            now: clock.now,
            sessionService: "test-verified-connect-\(UUID().uuidString)"
        )

        let invocationURL = temporary.appendingPathComponent("msw-bind-invocations.log")
        let bindResponse = String(
            decoding: try testJSON(MSWEnvelope(
                schemaVersion: 1,
                requestId: "github-bind",
                ok: true,
                command: "github-bind",
                observedAt: clock.value,
                result: MSWGitHubBindResult(
                    workspace: "dev",
                    accessMode: "read-only",
                    verificationRepository: "acme/two",
                    verified: true,
                    lifecycleRestored: true
                )
            )),
            as: UTF8.self
        )
        let hostBindResponse = String(
            decoding: try testJSON(MSWEnvelope(
                schemaVersion: 1,
                requestId: "github-bind-host",
                ok: true,
                command: "github-bind",
                observedAt: clock.value,
                result: MSWGitHubBindResult(
                    workspace: "dev",
                    accessMode: "host-write",
                    verificationRepository: "acme/two",
                    verified: true,
                    lifecycleRestored: true
                )
            )),
            as: UTF8.self
        )
        let executable = temporary.appendingPathComponent("msw")
        let script = """
        #!/bin/sh
        if [ "$1" = "app" ] && [ "$2" = "handshake" ]; then
            printf '%s\\n' '\(protocolCompatibleHandshake)'
        elif [ "$1" = "app" ] && [ "$2" = "github-bind" ]; then
            printf '%s\\n' "$*" >> "\(invocationURL.path)"
            case "$*" in
                *"--mode host-write"*) printf '%s\\n' '\(hostBindResponse)' ;;
                *) printf '%s\\n' '\(bindResponse)' ;;
            esac
        else
            exit 64
        fi
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let mswClient = MSWClient(
            runner: MSWCommandRunner(configuration: .init(
                homeDirectory: temporary,
                configuredExecutable: executable
            )),
            credentialBroker: broker
        )
        let journalURL = temporary.appendingPathComponent("authorization-journal.json")
        let coordinator = GitHubAuthorizationCoordinator(
            broker: broker,
            connect: connect,
            mswClient: mswClient,
            now: clock.now,
            journalURL: journalURL
        )

        let owner = GitHubInstallationAccount(login: "acme", id: 42, type: "Organization")
        let installation = GitHubInstallation(id: 42, account: owner, repositorySelection: "selected")
        let repositories = [
            GitHubRepository(
                id: 7,
                fullName: "acme/one",
                name: "one",
                owner: owner,
                private: true,
                defaultBranch: "main"
            ),
            GitHubRepository(
                id: 8,
                fullName: "acme/two",
                name: "two",
                owner: owner,
                private: true,
                defaultBranch: "main"
            )
        ]
        await transport.enqueue(try testJSON(TestCallbackPayload(
            sessionID: UUID(),
            sessionToken: "opaque-service-session",
            account: GitHubAccount(login: "octocat", id: 1, name: nil, email: nil),
            expiresAt: clock.value.addingTimeInterval(3600)
        )))
        await transport.enqueue(try testJSON(TestInstallationResponse(installations: [installation])))

        let discovery = try await coordinator.beginAuthorization(browser: TestConnectBrowser())
        XCTAssertEqual(discovery.account.login, "octocat")
        XCTAssertEqual(discovery.installations, [installation])

        await transport.enqueue(try testJSON(TestRepositoryResponse(repositories: repositories)))
        let scopedRepositories = try await coordinator.repositories(
            sessionID: discovery.sessionID,
            installationID: installation.id
        )
        XCTAssertEqual(scopedRepositories.map(\.fullName), ["acme/one", "acme/two"])

        let policy = repositories.map {
            GitHubRepositoryPolicy(
                workspace: "dev",
                repositoryID: $0.id,
                fullName: $0.fullName,
                installationID: installation.id,
                ownerID: owner.id,
                ownerLogin: owner.login,
                ownerType: owner.type,
                mode: $0.id == 8 ? .readWrite : .readOnly
            )
        }
        await transport.enqueue(try testJSON(TestRepositoryResponse(repositories: repositories)))
        await transport.enqueue(try testJSON(MSWConnectGrant(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000071")!,
            workspace: "dev",
            role: .guest,
            accountLogin: "octocat",
            owner: "acme",
            installationID: installation.id,
            repositoryIDs: [7, 8],
            repositoryNames: ["acme/one", "acme/two"],
            accessMode: "read-only",
            verificationRepository: "acme/one",
            accessToken: "ghs_verified_guest",
            accessExpiresAt: clock.value.addingTimeInterval(1800),
            generation: 1
        )))
        await transport.enqueue(try testJSON(MSWConnectGrant(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000072")!,
            workspace: "dev",
            role: .host,
            accountLogin: "octocat",
            owner: "acme",
            installationID: installation.id,
            repositoryIDs: [8],
            repositoryNames: ["acme/two"],
            accessMode: "host-write",
            verificationRepository: "acme/two",
            accessToken: "ghs_verified_host",
            accessExpiresAt: clock.value.addingTimeInterval(1800),
            generation: 1
        )))

        let commit = try await coordinator.commitPolicyWithVerification(
            sessionID: discovery.sessionID,
            policy: policy
        )
        XCTAssertEqual(commit.metadata.map(\.id), ["dev.guest", "dev.host"])
        XCTAssertEqual(commit.verifications.count, 2)
        let guestVerification = try XCTUnwrap(commit.verifications.first { $0.role == .guest })
        XCTAssertEqual(guestVerification.workspace, "dev")
        XCTAssertEqual(guestVerification.accessMode, "read-only")
        XCTAssertEqual(guestVerification.verificationRepository, "acme/one")
        XCTAssertTrue(guestVerification.verified)
        XCTAssertTrue(guestVerification.lifecycleRestored)
        let hostVerification = try XCTUnwrap(commit.verifications.first { $0.role == .host })
        XCTAssertEqual(hostVerification.verificationRepository, "acme/two")
        XCTAssertTrue(hostVerification.verified)

        let guestMetadata = try XCTUnwrap(commit.metadata.first(where: { $0.role == .guest }))
        XCTAssertEqual(guestMetadata.provider, "github-app-installation")
        XCTAssertEqual(guestMetadata.grantID?.uuidString, "00000000-0000-0000-0000-000000000071")
        XCTAssertEqual(guestMetadata.owner, "acme")
        XCTAssertEqual(guestMetadata.accountLogin, "octocat")
        XCTAssertEqual(guestMetadata.installationID, installation.id)
        XCTAssertEqual(guestMetadata.repositoryIDs, [7, 8])
        XCTAssertEqual(guestMetadata.repositoryNames, ["acme/one", "acme/two"])
        XCTAssertEqual(guestMetadata.accessMode, "read-only")
        XCTAssertEqual(guestMetadata.verificationRepository, "acme/one")
        XCTAssertEqual(guestMetadata.recoveryState, .ready)
        XCTAssertFalse(guestMetadata.quarantined)
        XCTAssertFalse(guestMetadata.needsRestart)

        let hostMetadata = try XCTUnwrap(commit.metadata.first(where: { $0.role == .host }))
        XCTAssertEqual(hostMetadata.grantID?.uuidString, "00000000-0000-0000-0000-000000000072")
        XCTAssertEqual(hostMetadata.accessMode, "host-write")
        XCTAssertEqual(hostMetadata.repositoryIDs, [8])
        XCTAssertEqual(hostMetadata.repositoryNames, ["acme/two"])
        XCTAssertEqual(hostMetadata.recoveryState, .ready)
        XCTAssertFalse(hostMetadata.quarantined)
        XCTAssertFalse(hostMetadata.needsRestart)


        let reloadedBroker = try CredentialBroker(
            keychain: keychain,
            metadataURL: metadataURL,
            keychainService: service
        )
        let persisted = await reloadedBroker.allMetadata()
        XCTAssertEqual(persisted.map(\.id), ["dev.guest", "dev.host"])
        let persistedGuest = try await reloadedBroker.load(workspace: "dev", role: .guest)
        let persistedHost = try await reloadedBroker.load(workspace: "dev", role: .host)
        XCTAssertEqual(persistedGuest.credential.accessToken, "ghs_verified_guest")
        XCTAssertEqual(persistedHost.credential.accessToken, "ghs_verified_host")

        let invocations = try String(contentsOf: invocationURL, encoding: .utf8)
        XCTAssertEqual(invocations.split(whereSeparator: { $0.isNewline }).count, 3)
        XCTAssertTrue(invocations.contains("--workspace dev --repository acme/one --mode read-only"))
        XCTAssertTrue(invocations.contains("--workspace dev --repository acme/two --mode host-write"))

        let transportRequests = await transport.requests()
        let grantRequests = transportRequests.filter { $0.url?.path == "/v1/grants" }
        XCTAssertEqual(grantRequests.count, 2)
        for request in grantRequests {
            let body = try XCTUnwrap(request.httpBody)
            let sent = try JSONDecoder().decode(MSWConnectGrantAssignment.self, from: body)
            if sent.role == .guest {
                XCTAssertEqual(sent.repositoryIDs, [7, 8])
                XCTAssertEqual(sent.repositoryNames, ["acme/one", "acme/two"])
                XCTAssertEqual(sent.verificationRepository, "acme/one")
            } else {
                XCTAssertEqual(sent.repositoryIDs, [8])
                XCTAssertEqual(sent.repositoryNames, ["acme/two"])
                XCTAssertEqual(sent.verificationRepository, "acme/two")
            }
            XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("access_token"))
        }
    }

    func testVerifiedConnectApplyRollsBackAfterVerificationFailure() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-verified-connect-rollback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let keychain = InMemoryConnectKeychain()
        let metadataURL = temporary.appendingPathComponent("credentials.json")
        let service = "test-verified-rollback-\(UUID().uuidString)"
        let broker = try CredentialBroker(
            keychain: keychain,
            metadataURL: metadataURL,
            keychainService: service
        )
        let clock = TestConnectClock(Date(timeIntervalSince1970: 1_900_000_000))
        let oldGrantID = UUID(uuidString: "00000000-0000-0000-0000-000000000081")!
        let newGrantID = UUID(uuidString: "00000000-0000-0000-0000-000000000082")!
        try await broker.storeScopedCredential(
            ScopedInstallationCredential(
                grantID: oldGrantID,
                accessToken: "ghs_previous",
                accessExpiresAt: clock.value.addingTimeInterval(1800),
                generation: 1
            ),
            workspace: "dev",
            accessMode: "read-only",
            verificationRepository: "acme/one",
            installationID: 42,
            role: .guest,
            accountLogin: "octocat",
            owner: "acme",
            repositoryIDs: [7],
            repositoryNames: ["acme/one"],
            scopeDigest: "previous-scope"
        )
        try await broker.markBound(workspace: "dev", role: .guest)

        let transport = QueueConnectTransport()
        let configuration = testConnectConfiguration()
        let connect = MSWConnectClient(
            configuration: configuration,
            transport: transport,
            keychain: keychain,
            now: clock.now,
            sessionService: "test-verified-rollback-connect-\(UUID().uuidString)"
        )
        let invocationURL = temporary.appendingPathComponent("msw-rollback-invocations.log")
        let bindMarkerURL = temporary.appendingPathComponent("failed-bind")
        let failedBindResponse = String(
            decoding: try testJSON(MSWEnvelope(
                schemaVersion: 1,
                requestId: "github-bind-failed",
                ok: true,
                command: "github-bind",
                observedAt: clock.value,
                result: MSWGitHubBindResult(
                    workspace: "dev",
                    accessMode: "read-only",
                    verificationRepository: "acme/one",
                    verified: false,
                    lifecycleRestored: false
                )
            )),
            as: UTF8.self
        )
        let restoredBindResponse = String(
            decoding: try testJSON(MSWEnvelope(
                schemaVersion: 1,
                requestId: "github-bind-restored",
                ok: true,
                command: "github-bind",
                observedAt: clock.value,
                result: MSWGitHubBindResult(
                    workspace: "dev",
                    accessMode: "read-only",
                    verificationRepository: "acme/one",
                    verified: true,
                    lifecycleRestored: true
                )
            )),
            as: UTF8.self
        )
        let unbindResponse = String(
            decoding: try testJSON(MSWEnvelope(
                schemaVersion: 1,
                requestId: "github-unbind",
                ok: true,
                command: "github-unbind",
                observedAt: clock.value,
                result: MSWGitHubUnbindResult(workspace: "dev", unbound: true)
            )),
            as: UTF8.self
        )
        let executable = temporary.appendingPathComponent("msw")
        let script = """
        #!/bin/sh
        if [ "$1" = "app" ] && [ "$2" = "handshake" ]; then
            printf '%s\\n' '\(protocolCompatibleHandshake)'
        elif [ "$1" = "app" ] && [ "$2" = "github-bind" ]; then
            printf '%s\\n' "$*" >> "\(invocationURL.path)"
            if [ -e "\(bindMarkerURL.path)" ]; then
                printf '%s\\n' '\(restoredBindResponse)'
            else
                : > "\(bindMarkerURL.path)"
                printf '%s\\n' '\(failedBindResponse)'
            fi
        elif [ "$1" = "app" ] && [ "$2" = "github-unbind" ]; then
            printf '%s\\n' "$*" >> "\(invocationURL.path)"
            printf '%s\\n' '\(unbindResponse)'
        else
            exit 64
        fi
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let mswClient = MSWClient(
            runner: MSWCommandRunner(configuration: .init(
                homeDirectory: temporary,
                configuredExecutable: executable
            )),
            credentialBroker: broker
        )
        let journalURL = temporary.appendingPathComponent("authorization-journal.json")
        let coordinator = GitHubAuthorizationCoordinator(
            broker: broker,
            connect: connect,
            mswClient: mswClient,
            now: clock.now,
            journalURL: journalURL
        )

        let owner = GitHubInstallationAccount(login: "acme", id: 42, type: "Organization")
        let installation = GitHubInstallation(id: 42, account: owner, repositorySelection: "selected")
        let repositories = [
            GitHubRepository(
                id: 7,
                fullName: "acme/one",
                name: "one",
                owner: owner,
                private: true,
                defaultBranch: "main"
            )
        ]
        await transport.enqueue(try testJSON(TestCallbackPayload(
            sessionID: UUID(),
            sessionToken: "opaque-service-session",
            account: GitHubAccount(login: "octocat", id: 1, name: nil, email: nil),
            expiresAt: clock.value.addingTimeInterval(3600)
        )))
        await transport.enqueue(try testJSON(TestInstallationResponse(installations: [installation])))

        let discovery = try await coordinator.beginAuthorization(browser: TestConnectBrowser())
        XCTAssertEqual(discovery.account.login, "octocat")
        await transport.enqueue(try testJSON(TestRepositoryResponse(repositories: repositories)))
        let scopedRepositories = try await coordinator.repositories(
            sessionID: discovery.sessionID,
            installationID: installation.id
        )
        XCTAssertEqual(scopedRepositories.map(\.fullName), ["acme/one"])

        let policy = GitHubRepositoryPolicy(
            workspace: "dev",
            repositoryID: 7,
            fullName: "acme/one",
            installationID: installation.id,
            ownerID: owner.id,
            ownerLogin: owner.login,
            ownerType: owner.type
        )
        await transport.enqueue(try testJSON(TestRepositoryResponse(repositories: repositories)))
        await transport.enqueue(try testJSON(MSWConnectGrant(
            id: newGrantID,
            workspace: "dev",
            role: .guest,
            accountLogin: "octocat",
            owner: "acme",
            installationID: installation.id,
            repositoryIDs: [7],
            repositoryNames: ["acme/one"],
            accessMode: "read-only",
            verificationRepository: "acme/one",
            accessToken: "ghs_replacement",
            accessExpiresAt: clock.value.addingTimeInterval(1800),
            generation: 2
        )))
        await transport.enqueue(try testJSON(MSWConnectRevocationReceipt(
            grantID: newGrantID,
            revoked: true,
            terminal: true,
            revokedAt: clock.value
        )))

        do {
            _ = try await coordinator.commitPolicyWithVerification(
                sessionID: discovery.sessionID,
                policy: [policy]
            )
            XCTFail("A failed MSW verification must not commit replacement access.")
        } catch let error as GitHubAuthorizationError {
            XCTAssertEqual(error, .verificationFailed("dev"))
        }

        let verificationResults = await coordinator.verificationResults()
        let verification = try XCTUnwrap(verificationResults.first)
        XCTAssertFalse(verification.verified)
        XCTAssertFalse(verification.lifecycleRestored)
        XCTAssertTrue(verification.safetyResult.contains("Previous access was restored"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))

        let restoredMetadata = try await broker.metadata(for: "dev", role: .guest)
        let restored = try XCTUnwrap(restoredMetadata)
        XCTAssertEqual(restored.grantID, oldGrantID)
        XCTAssertEqual(restored.recoveryState, .ready)
        XCTAssertFalse(restored.quarantined)
        XCTAssertFalse(restored.needsRestart)
        let restoredBundle = try await broker.load(workspace: "dev", role: .guest)
        XCTAssertEqual(restoredBundle.credential.accessToken, "ghs_previous")

        let invocations = try String(contentsOf: invocationURL, encoding: .utf8)
        XCTAssertEqual(invocations.split(whereSeparator: { $0.isNewline }).count, 3)
        XCTAssertEqual(invocations.components(separatedBy: "github-unbind").count - 1, 1)
        XCTAssertEqual(invocations.components(separatedBy: "--mode read-only").count - 1, 2)
        let requests = await transport.requests()
        let revokedPaths = requests
            .filter { $0.httpMethod == "DELETE" }
            .compactMap { $0.url?.path }
        XCTAssertEqual(revokedPaths, ["/v1/grants/\(newGrantID.uuidString)"])
        XCTAssertFalse(revokedPaths.contains("/v1/grants/\(oldGrantID.uuidString)"))
    }

    func testIdentityVerificationGateDisablesCompletionAfterEdit() {
        let workspaces = Set(["dev", "playgrounds", "personal"])
        let saved = SetupVerifiedIdentity(name: "Ada Lovelace", email: "ada@example.test")
        let verified = Dictionary(uniqueKeysWithValues: workspaces.map { ($0, saved) })
        var visibleName = "Ada Lovelace"

        XCTAssertTrue(
            SetupIdentityVerification.isComplete(
                requiredWorkspaces: workspaces,
                configuredWorkspaces: workspaces,
                verifiedByWorkspace: verified,
                target: "all",
                name: visibleName,
                email: saved.email
            )
        )

        visibleName = "Ada Lovelace (edited)"

        XCTAssertFalse(
            SetupIdentityVerification.isComplete(
                requiredWorkspaces: workspaces,
                configuredWorkspaces: workspaces,
                verifiedByWorkspace: verified,
                target: "all",
                name: visibleName,
                email: saved.email
            ),
            "Done must be disabled after a visible identity edit without a new verification."
        )
    }
    func testIdentityVerificationGateAllowsVerifiedSingleTarget() {
        let requiredWorkspaces = Set(["dev", "playgrounds", "personal"])
        let saved = SetupVerifiedIdentity(name: "Ada Lovelace", email: "ada@example.test")

        XCTAssertTrue(
            SetupIdentityVerification.isComplete(
                requiredWorkspaces: requiredWorkspaces,
                configuredWorkspaces: ["dev"],
                verifiedByWorkspace: ["dev": saved],
                target: "dev",
                name: saved.name,
                email: saved.email
            )
        )

        XCTAssertFalse(
            SetupIdentityVerification.isComplete(
                requiredWorkspaces: requiredWorkspaces,
                configuredWorkspaces: ["dev"],
                verifiedByWorkspace: ["dev": saved],
                target: "all",
                name: saved.name,
                email: saved.email
            ),
            "All-workspace completion must still require every workspace."
        )
    }


    func testDisableWorkspaceGitHubAccessUnbindsHostAndRemovesGrant() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-disable-github-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let keychain = InMemoryConnectKeychain()
        let metadataURL = temporary.appendingPathComponent("credentials.json")
        let service = "test-disable-github-\(UUID().uuidString)"
        let broker = try CredentialBroker(
            keychain: keychain,
            metadataURL: metadataURL,
            keychainService: service
        )
        let clock = TestConnectClock(Date(timeIntervalSince1970: 1_900_000_000))
        let configuration = testConnectConfiguration()
        let transport = QueueConnectTransport()
        let connect = MSWConnectClient(
            configuration: configuration,
            transport: transport,
            keychain: keychain,
            now: clock.now,
            sessionService: "test-disable-github-connect-\(UUID().uuidString)"
        )
        let grantID = UUID(uuidString: "00000000-0000-0000-0000-000000000091")!
        try await broker.storeScopedCredential(
            ScopedInstallationCredential(
                grantID: grantID,
                accessToken: "ghs_disable_github",
                accessExpiresAt: clock.value.addingTimeInterval(3600),
                generation: 1
            ),
            workspace: "dev",
            accessMode: "read-only",
            verificationRepository: "acme/one",
            installationID: 42,
            role: .guest,
            accountLogin: "octocat",
            owner: "acme",
            repositoryIDs: [7],
            repositoryNames: ["acme/one"],
            scopeDigest: "test-scope"
        )

        // Establish a session so the authorized revoke request can be made.
        let start = try await connect.startAuthorization()
        await transport.enqueue(try testJSON(TestCallbackPayload(
            sessionID: UUID(),
            sessionToken: "opaque-disable-session",
            account: GitHubAccount(login: "octocat", id: 1, name: nil, email: nil),
            expiresAt: clock.value.addingTimeInterval(3600)
        )))
        _ = try await connect.completeAuthorization(
            callbackURL: testCallbackURL(configuration: configuration, state: start.state, code: "disable")
        )
        await transport.enqueue(try testJSON(MSWConnectRevocationReceipt(
            grantID: grantID,
            revoked: true,
            terminal: true,
            revokedAt: clock.value
        )))

        let invocationURL = temporary.appendingPathComponent("msw-unbind-invocations.log")
        let unbindResponse = String(
            decoding: try testJSON(MSWEnvelope(
                schemaVersion: 1,
                requestId: "github-unbind",
                ok: true,
                command: "github-unbind",
                observedAt: clock.value,
                result: MSWGitHubUnbindResult(workspace: "dev", unbound: true)
            )),
            as: UTF8.self
        )
        let executable = temporary.appendingPathComponent("msw")
        let script = """
        #!/bin/sh
        if [ "$1" = "app" ] && [ "$2" = "handshake" ]; then
            printf '%s\\n' '\(protocolCompatibleHandshake)'
        elif [ "$1" = "app" ] && [ "$2" = "github-unbind" ]; then
            printf '%s\\n' "$*" >> "\(invocationURL.path)"
            printf '%s\\n' '\(unbindResponse)'
        else
            exit 64
        fi
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let mswClient = MSWClient(
            runner: MSWCommandRunner(configuration: .init(
                homeDirectory: temporary,
                configuredExecutable: executable
            )),
            credentialBroker: broker
        )
        let coordinator = GitHubAuthorizationCoordinator(
            broker: broker,
            connect: connect,
            mswClient: mswClient,
            now: clock.now,
            journalURL: temporary.appendingPathComponent("authorization-transaction.json")
        )

        try await coordinator.disableWorkspaceGitHubAccess("dev")

        let remaining = await broker.allMetadata()
        XCTAssertTrue(
            remaining.isEmpty,
            "Disabling GitHub access must remove every local credential record for the workspace."
        )
        let unbindLog = try String(contentsOf: invocationURL, encoding: .utf8)
        XCTAssertTrue(
            unbindLog.contains("app github-unbind --workspace dev"),
            "The host binding must be unbound so a later bootstrap can complete without GitHub."
        )
        let requests = await transport.requests()
        let revokedPaths = requests
            .filter { $0.httpMethod == "DELETE" }
            .compactMap { $0.url?.path }
        XCTAssertEqual(revokedPaths, ["/v1/grants/\(grantID.uuidString)"])
    }

    func testDisableWorkspaceGitHubAccessTreatsAlreadyRevokedGrantAsSuccess() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-disable-github-retry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let keychain = InMemoryConnectKeychain()
        let metadataURL = temporary.appendingPathComponent("credentials.json")
        let service = "test-disable-github-retry-\(UUID().uuidString)"
        let broker = try CredentialBroker(
            keychain: keychain,
            metadataURL: metadataURL,
            keychainService: service
        )
        let clock = TestConnectClock(Date(timeIntervalSince1970: 1_900_000_000))
        let configuration = testConnectConfiguration()
        let transport = QueueConnectTransport()
        let connect = MSWConnectClient(
            configuration: configuration,
            transport: transport,
            keychain: keychain,
            now: clock.now,
            sessionService: "test-disable-github-retry-connect-\(UUID().uuidString)"
        )
        let grantID = UUID(uuidString: "00000000-0000-0000-0000-000000000092")!
        try await broker.storeScopedCredential(
            ScopedInstallationCredential(
                grantID: grantID,
                accessToken: "ghs_disable_github_retry",
                accessExpiresAt: clock.value.addingTimeInterval(3600),
                generation: 1
            ),
            workspace: "dev",
            accessMode: "read-only",
            verificationRepository: "acme/one",
            installationID: 42,
            role: .guest,
            accountLogin: "octocat",
            owner: "acme",
            repositoryIDs: [7],
            repositoryNames: ["acme/one"],
            scopeDigest: "test-scope"
        )

        let start = try await connect.startAuthorization()
        await transport.enqueue(try testJSON(TestCallbackPayload(
            sessionID: UUID(),
            sessionToken: "opaque-disable-retry-session",
            account: GitHubAccount(login: "octocat", id: 1, name: nil, email: nil),
            expiresAt: clock.value.addingTimeInterval(3600)
        )))
        _ = try await connect.completeAuthorization(
            callbackURL: testCallbackURL(configuration: configuration, state: start.state, code: "disable-retry")
        )
        // The service reports the grant as already revoked; a retry of the
        // disable must treat that as a successful revocation instead of
        // quarantining forever.
        await transport.enqueue(
            Data(#"{"error":{"code":"grant_revoked","message":"grant already revoked"}}"#.utf8),
            status: 409
        )

        let invocationURL = temporary.appendingPathComponent("msw-unbind-retry-invocations.log")
        let unbindResponse = String(
            decoding: try testJSON(MSWEnvelope(
                schemaVersion: 1,
                requestId: "github-unbind",
                ok: true,
                command: "github-unbind",
                observedAt: clock.value,
                result: MSWGitHubUnbindResult(workspace: "dev", unbound: true)
            )),
            as: UTF8.self
        )
        let executable = temporary.appendingPathComponent("msw")
        let script = """
        #!/bin/sh
        if [ "$1" = "app" ] && [ "$2" = "handshake" ]; then
            printf '%s\\n' '\(protocolCompatibleHandshake)'
        elif [ "$1" = "app" ] && [ "$2" = "github-unbind" ]; then
            printf '%s\\n' "$*" >> "\(invocationURL.path)"
            printf '%s\\n' '\(unbindResponse)'
        else
            exit 64
        fi
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let mswClient = MSWClient(
            runner: MSWCommandRunner(configuration: .init(
                homeDirectory: temporary,
                configuredExecutable: executable
            )),
            credentialBroker: broker
        )
        let coordinator = GitHubAuthorizationCoordinator(
            broker: broker,
            connect: connect,
            mswClient: mswClient,
            now: clock.now,
            journalURL: temporary.appendingPathComponent("authorization-transaction.json")
        )

        // A retry after the remote grant was already revoked must succeed and
        // finish the local cleanup, not quarantine the workspace.
        try await coordinator.disableWorkspaceGitHubAccess("dev")

        let remaining = await broker.allMetadata()
        XCTAssertTrue(
            remaining.isEmpty,
            "An already-revoked grant must still be removed locally on retry."
        )
        let unbindLog = try String(contentsOf: invocationURL, encoding: .utf8)
        XCTAssertTrue(
            unbindLog.contains("app github-unbind --workspace dev"),
            "The host binding must still be unbound on retry."
        )
    }

    func testRemoveAllRolesClearsLegacyKeychainRecordsWithoutSchema3Metadata() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-remove-legacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let keychain = InMemoryConnectKeychain()
        try keychain.save(KeychainItem(
            service: "msw.github.read",
            account: "dev",
            secret: Data("legacy-read-token".utf8)
        ))
        try keychain.save(KeychainItem(
            service: "msw.github.write",
            account: "dev",
            secret: Data("legacy-write-token".utf8)
        ))
        let broker = try CredentialBroker(
            keychain: keychain,
            metadataURL: temporary.appendingPathComponent("credentials.json"),
            keychainService: "test-legacy-removal-\(UUID().uuidString)"
        )

        // No schema-3 metadata exists for the workspace, but the legacy
        // Keychain records must still be removed so the host no longer treats
        // the workspace as GitHub-configured.
        try await broker.removeAllRoles(workspace: "dev")

        XCTAssertThrowsError(try keychain.load(service: "msw.github.read", account: "dev"))
        XCTAssertThrowsError(try keychain.load(service: "msw.github.write", account: "dev"))
    }

    private func testConnectConfiguration() -> MSWConnectConfiguration {
        MSWConnectConfiguration(
            baseURL: URL(string: "https://connect.test")!,
            clientID: "test-client",
            redirectURL: URL(string: "msw://connect.microsandbox.dev/oauth/callback")!,
            authorizationPath: "/oauth/authorize",
            callbackPath: "/oauth/callback"
        )
    }

    private func testCallbackURL(configuration: MSWConnectConfiguration, state: String, code: String) -> URL {
        var components = URLComponents(url: configuration.redirectURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "state", value: state)
        ]
        return components.url!
    }
}
private final class InMemoryConnectKeychain: MSWConnectKeychainStoring, CredentialKeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func save(_ item: KeychainItem) throws {
        lock.lock()
        values["\(item.service)|\(item.account)"] = item.secret
        lock.unlock()
    }

    func load(service: String, account: String) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard let value = values["\(service)|\(account)"] else {
            throw KeychainStoreError.itemNotFound
        }
        return value
    }

    func delete(service: String, account: String) throws {
        lock.lock()
        values.removeValue(forKey: "\(service)|\(account)")
        lock.unlock()
    }
}

private func currentSession(of outcome: GitHubDeviceSessionRefreshOutcome) -> GitHubDeviceSession? {
    guard case .current(let session, _) = outcome else { return nil }
    return session
}

/// Keychain fixture with a configurable save-failure window: saves whose
/// 1-based index is in `failingSaves` throw, all others persist. Exercises
/// the fail-closed poison (rotated save fails, poison save succeeds) and the
/// quarantine path (rotated and poison saves both fail).
private final class WindowedFailingSaveKeychain: MSWConnectKeychainStoring, CredentialKeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var saveCount = 0
    private let failingSaves: Set<Int>

    init(failingSaves: Set<Int>) {
        self.failingSaves = failingSaves
    }

    func save(_ item: KeychainItem) throws {
        lock.lock()
        defer { lock.unlock() }
        saveCount += 1
        if failingSaves.contains(saveCount) {
            throw KeychainStoreError.unavailable(-1)
        }
        values["\(item.service)|\(item.account)"] = item.secret
    }

    func load(service: String, account: String) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard let value = values["\(service)|\(account)"] else {
            throw KeychainStoreError.itemNotFound
        }
        return value
    }

    func delete(service: String, account: String) throws {
        lock.lock()
        values.removeValue(forKey: "\(service)|\(account)")
        lock.unlock()
    }
}

/// Keychain fixture with a configurable load-failure window: loads whose
/// 1-based index is in `failingLoads` throw, all others read normally.
/// Exercises the fail-closed quarantine of a consumed generation when the
/// post-refresh generation guard cannot even read the record.
private final class WindowedFailingLoadKeychain: MSWConnectKeychainStoring, CredentialKeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var loadCount = 0
    private let failingLoads: Set<Int>

    init(failingLoads: Set<Int>) {
        self.failingLoads = failingLoads
    }

    /// The number of `load` calls production made. Non-counting inspection:
    /// a test asserting state must not consume an injected failure slot.
    var observedLoadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return loadCount
    }

    /// The stored session record, read without counting as a load and
    /// without throwing — asserts what production actually persisted without
    /// perturbing the injected failure window.
    func storedSession() -> GitHubDeviceSession? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = values["\(GitHubDeviceSessionStore.service)|\(GitHubDeviceSessionStore.account)"],
              let session = try? JSONDecoder().decode(GitHubDeviceSession.self, from: data),
              session.schemaVersion == 1 else {
            return nil
        }
        return session
    }

    func save(_ item: KeychainItem) throws {
        lock.lock()
        values["\(item.service)|\(item.account)"] = item.secret
        lock.unlock()
    }

    func load(service: String, account: String) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        loadCount += 1
        if failingLoads.contains(loadCount) {
            throw KeychainStoreError.malformedItem
        }
        guard let value = values["\(service)|\(account)"] else {
            throw KeychainStoreError.itemNotFound
        }
        return value
    }

    func delete(service: String, account: String) throws {
        lock.lock()
        values.removeValue(forKey: "\(service)|\(account)")
        lock.unlock()
    }
}

private actor QueueConnectTransport: MSWConnectHTTPTransport {
    private struct Response: Sendable {
        let data: Data
        let status: Int
    }

    private var responses: [Response] = []
    private var recordedRequests: [URLRequest] = []

    func enqueue(_ data: Data, status: Int = 200) {
        responses.append(Response(data: data, status: status))
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recordedRequests.append(request)
        guard !responses.isEmpty else { throw MSWConnectError.transportUnavailable }
        let response = responses.removeFirst()
        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: response.status,
            httpVersion: nil,
            headerFields: nil
        )!
        return (response.data, httpResponse)
    }

    func requests() -> [URLRequest] {
        recordedRequests
    }
}

/// Transport whose `send` blocks until the test explicitly releases it, with
/// a `waitUntilSendStarted()` barrier: a concurrent sign-in can determinis-
/// tically land during the network await. Exercises the superseded-outcome
/// reconciliation when a replacement wins the epoch mid-refresh without any
/// sleep-based racing.
private actor GatedConnectTransport: MSWConnectHTTPTransport {
    private struct Response: Sendable {
        let data: Data
        let status: Int
    }

    private var responses: [Response] = []
    private var recordedRequests: [URLRequest] = []
    private var sendEntered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var sendReleased = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enqueue(_ data: Data, status: Int = 200) {
        responses.append(Response(data: data, status: status))
    }

    /// The requests consumed so far; the lifecycle-barrier ordering test uses
    /// the count to observe whether a repository refresh was created after a
    /// close invalidated the setup surface.
    func requests() -> [URLRequest] {
        recordedRequests
    }

    /// Suspends until `send` has entered — which happens only after every
    /// store load the production revalidation performs before the network
    /// await. A replacement issued after this barrier deterministically
    /// lands mid-refresh instead of racing the starting epoch/load.
    func waitUntilSendStarted() async {
        if sendEntered { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    /// Releases the entered `send` so it answers with the enqueued response.
    func resumeSend() {
        sendReleased = true
        for continuation in releaseWaiters {
            continuation.resume()
        }
        releaseWaiters.removeAll()
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recordedRequests.append(request)
        guard !responses.isEmpty else { throw MSWConnectError.transportUnavailable }
        let response = responses.removeFirst()
        if !sendEntered {
            sendEntered = true
            for continuation in enteredWaiters {
                continuation.resume()
            }
            enteredWaiters.removeAll()
        }
        if !sendReleased {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: response.status,
            httpVersion: nil,
            headerFields: nil
        )!
        return (response.data, httpResponse)
    }
}

/// Transport whose EVERY `send` blocks until the test explicitly releases it,
/// in FIFO order, with a per-send entry barrier (`waitUntilSendStarted(nth:)`):
/// the device-flow barrier tests hold the poll-token request in flight while
/// the setup surface closes (or a newer flow starts), then deliver the token —
/// deterministically proving a late token emits no UI state and never cancels
/// or replaces a newer flow's verification. Unlike `GatedConnectTransport`
/// (which gates only its first send), every send is gated so multi-request
/// flows (device code → poll token → verification) are fully deterministic.
private actor StepGatedConnectTransport: MSWConnectHTTPTransport {
    private struct Response: Sendable {
        let data: Data
        let status: Int
    }

    private var responses: [Response] = []
    private var recordedRequests: [URLRequest] = []
    private var enteredCount = 0
    private var enteredWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var releasedCount = 0
    private var releaseWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    func enqueue(_ data: Data, status: Int = 200) {
        responses.append(Response(data: data, status: status))
    }

    /// The requests consumed so far, in FIFO order.
    func requests() -> [URLRequest] {
        recordedRequests
    }

    /// Suspends until the `n`-th send (1-based) has entered, i.e. the request
    /// is in flight and blocked awaiting its release.
    func waitUntilSendStarted(nth: Int) async {
        if enteredCount >= nth { return }
        await withCheckedContinuation { continuation in
            enteredWaiters[nth, default: []].append(continuation)
        }
    }

    /// Releases EXACTLY the `n`-th entered send so it answers with its
    /// enqueued response. Releases are keyed by send ordinal: an overlapping
    /// send (e.g. a superseded flow's poll-token request held next to a newer
    /// flow's verification request) stays blocked until its OWN release, so
    /// one release can never wake multiple sends.
    func resumeSend(nth: Int) {
        releasedCount = max(releasedCount, nth)
        if let waiters = releaseWaiters.removeValue(forKey: nth) {
            for continuation in waiters {
                continuation.resume()
            }
        }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recordedRequests.append(request)
        guard !responses.isEmpty else { throw MSWConnectError.transportUnavailable }
        let response = responses.removeFirst()
        enteredCount += 1
        for (nth, waiters) in enteredWaiters where nth == enteredCount {
            for continuation in waiters {
                continuation.resume()
            }
            enteredWaiters.removeValue(forKey: nth)
        }
        if releasedCount < enteredCount {
            await withCheckedContinuation { continuation in
                releaseWaiters[enteredCount, default: []].append(continuation)
            }
        }
        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: response.status,
            httpVersion: nil,
            headerFields: nil
        )!
        return (response.data, httpResponse)
    }
}

private final class TestConnectClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Date

    init(_ value: Date) {
        storage = value
    }

    var value: Date {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }

    func now() -> Date { value }
}

@MainActor
private struct TestConnectBrowser: MSWConnectBrowserAuthenticating {
    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let state = components.queryItems?.first(where: { $0.name == "state" })?.value
        components.scheme = callbackScheme
        components.host = "connect.microsandbox.dev"
        components.path = "/oauth/callback"
        components.queryItems = [
            URLQueryItem(name: "code", value: "one-time-code"),
            URLQueryItem(name: "state", value: state)
        ]
        return components.url!
    }
}

@MainActor
private final class RecordingConnectBrowser: MSWConnectBrowserAuthenticating, @unchecked Sendable {
    private var storage: URL?

    var openedURL: URL? {
        storage
    }

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        storage = url
        throw MSWConnectError.cancelled
    }
}

private struct TestInstallationResponse: Encodable {
    let installations: [GitHubInstallation]
}

private struct TestRepositoryResponse: Encodable {
    let repositories: [GitHubRepository]
}

private struct TestCallbackPayload: Encodable {
    let sessionID: UUID
    let sessionToken: String
    let account: GitHubAccount
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case sessionToken = "session_token"
        case account
        case expiresAt = "expires_at"
    }
}

private func testJSON<Value: Encodable>(_ value: Value) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(value)
}
