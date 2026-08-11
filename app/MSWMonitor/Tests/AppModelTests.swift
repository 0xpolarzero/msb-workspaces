import Foundation
import CryptoKit
import XCTest
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
        XCTAssertTrue(model.lastError?.contains("blocked") == true)
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

        let devAssignment = GitHubWorkspaceAssignment(
            workspace: "dev",
            owner: "acme",
            installationID: 42,
            repositoryIDs: [7],
            repositoryNames: ["acme/one"],
            accessMode: "read-only",
            verificationRepository: "acme/one"
        )
        let personalAssignment = GitHubWorkspaceAssignment(
            workspace: "personal",
            owner: "acme",
            installationID: 42,
            repositoryIDs: [8],
            repositoryNames: ["acme/two"],
            accessMode: "read-write",
            verificationRepository: "acme/two"
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

        let metadata = try await coordinator.commitAssignments(
            sessionID: discovery.sessionID,
            assignments: [devAssignment, personalAssignment]
        )
        XCTAssertEqual(metadata.map(\.id), ["dev.guest", "personal.guest", "personal.host"])
        let personalMetadata = try await broker.metadata(for: "personal", role: .host)
        XCTAssertEqual(personalMetadata?.accessMode, "host-write")
        let devBundle = try await broker.load(workspace: "dev", role: .guest)
        XCTAssertEqual(devBundle.credential.accessToken, "ghs_dev_token")

        do {
            _ = try await coordinator.commitAssignments(
                sessionID: discovery.sessionID,
                assignments: [devAssignment]
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
