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
    private(set) var inspectRequests: [[MSWWorkspaceNetworkRecord]] = []

    func inspect(records: [MSWWorkspaceNetworkRecord]) async throws -> MSWHostRecordSnapshot {
        inspectRequests.append(records)
        return snapshot(records: records)
    }

    func ensureFixedLoopbackAliases(records: [MSWWorkspaceNetworkRecord]) async throws -> MSWHostRecordSnapshot {
        ensureAliasInvocationCount += 1
        return snapshot(records: records)
    }

    func installFixedHostRecords(records: [MSWWorkspaceNetworkRecord]) async throws -> MSWHostRecordSnapshot {
        installRecordsInvocationCount += 1
        return snapshot(records: records)
    }

    func uninstall(records: [MSWWorkspaceNetworkRecord]) async throws -> MSWHostRecordSnapshot {
        snapshot(records: records)
    }

    private func snapshot(records: [MSWWorkspaceNetworkRecord]) -> MSWHostRecordSnapshot {
        MSWHostRecordSnapshot(
            fixedAliases: records.map(\.address),
            hostsBlockInstalled: true,
            launchDaemonRegistered: true
        )
    }
}

private struct AvailableUserIntegration: MSWUserIntegrationControlling {
    func configureUserIntegrationIfAvailable() async throws {}
}

private actor CommandRecorder {
    private(set) var command: MSWCommand?

    func record(_ command: MSWCommand) {
        self.command = command
    }
}

private let protocolCompatibleHandshake = #"{"schemaVersion":1,"requestId":"test-handshake","ok":true,"command":"handshake","observedAt":"2026-08-08T00:00:00Z","result":{"protocolVersion":1,"mswVersion":"test","platform":{"os":"macOS","architecture":"arm64"},"configurationAvailable":true,"runtimeAvailable":true,"capabilities":{"jsonState":true,"jsonMetrics":true,"jsonLogs":true,"plans":true,"bootstrapEvents":true,"jq":true,"workspaceCount":3},"exitCodes":{}},"warnings":[],"error":null}"#

private func writeBackupExecutable(temporary: URL, response: String) throws -> URL {
    let executable = temporary.appendingPathComponent("msw")
    let script = """
    #!/bin/sh
    if [ "$1" = "app" ] && [ "$2" = "handshake" ]; then
        printf '%s\\n' '\(protocolCompatibleHandshake)'
    elif [ "$1" = "app" ] && [ "$2" = "backup" ]; then
        printf '%s\\n' '\(response)'
    else
        exit 64
    fi
    """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    return executable
}

@MainActor
private func makeBackupModel(temporary: URL, response: String) throws -> AppModel {
    let executable = try writeBackupExecutable(temporary: temporary, response: response)
    let client = MSWClient(runner: MSWCommandRunner(configuration: .init(
        homeDirectory: temporary,
        testMSWExecutable: executable
    )))
    return AppModel(client: client, diagnostics: MSWDiagnostics(client: client))
}

private final class ControllableNotificationCenter: MSWNotificationCenterControlling {
    var status: UNAuthorizationStatus
    var authorizationResult: Result<Bool, Error>
    var shouldFailDelivery: Bool
    private(set) var requestedOptions: [UNAuthorizationOptions] = []
    private(set) var addInvocationCount = 0

    init(
        status: UNAuthorizationStatus = .authorized,
        authorizationResult: Result<Bool, Error> = .success(true),
        shouldFailDelivery: Bool = false
    ) {
        self.status = status
        self.authorizationResult = authorizationResult
        self.shouldFailDelivery = shouldFailDelivery
    }

    func authorizationStatus() async -> UNAuthorizationStatus { status }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        requestedOptions.append(options)
        let result = try authorizationResult.get()
        if result { status = .authorized }
        return result
    }

    func add(_ request: UNNotificationRequest) async throws {
        addInvocationCount += 1
        if shouldFailDelivery {
            throw NSError(domain: "NotificationTest", code: 1)
        }
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
    func testBackupDestinationPickerUsesStandardMacWording() {
        let panel = BackupDestinationPicker.makePanel()

        XCTAssertEqual(panel.title, "Choose Backup Destination")
        XCTAssertEqual(panel.prompt, "Choose Destination…")
        XCTAssertEqual(
            panel.message,
            "Selecting a directory does not start the backup. You will review scope and workspace impact next."
        )
        XCTAssertNotEqual(panel.prompt, "Review Destination")
    }

    func testBackupPreviewFirstRunShowsAllocatedSourceWithoutArchiveEstimate() async throws {
        let destination = URL(fileURLWithPath: "/tmp/msw-preview-fixture", isDirectory: true)
        let model = AppModel()
        model.installBackupUITestFixture(sourceAllocatedBytes: 16_000_000_000, destination: destination)

        let prepared = await model.prepareBackup(to: destination)
        let preview = try XCTUnwrap(prepared)

        XCTAssertEqual(preview.sourceAllocatedBytes, 16_000_000_000)
        XCTAssertNil(preview.archiveEstimate)
        XCTAssertEqual(preview.destination, destination)
    }

    func testBackupPreviewHistoricalEstimatePreservesConservativeRangeAndProvenance() async throws {
        let destination = URL(fileURLWithPath: "/tmp/msw-preview-history", isDirectory: true)
        let estimate = MSWBackupEstimate(
            lowerBytes: 3_000_000_000, upperBytes: 6_000_000_000, basisRatio: 0.25,
            changedSourceRatio: 1.2, provenance: "same managed scope, prior completed backup"
        )
        let model = AppModel()
        model.installBackupUITestFixture(
            sourceAllocatedBytes: 20_000_000_000, archiveEstimate: estimate, destination: destination
        )

        let prepared = await model.prepareBackup(to: destination)
        let preview = try XCTUnwrap(prepared)

        XCTAssertEqual(preview.archiveEstimate, estimate)
        XCTAssertLessThan(preview.archiveEstimate!.lowerBytes, preview.archiveEstimate!.upperBytes)
        XCTAssertEqual(preview.archiveEstimate?.changedSourceRatio, 1.2)
    }

    func testBackupPreviewUsesResolvedInstalledShippedCLIAndReturnsEstimatedSourceBytes() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-backup-preview-integration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let sourceExecutable = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("bin/msw")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: sourceExecutable.path))

        let configDirectory = temporary.appendingPathComponent(".config/msw", isDirectory: true)
        let toolDirectory = temporary.appendingPathComponent(".local/bin", isDirectory: true)
        let managedDirectory = temporary.appendingPathComponent(".microsandbox", isDirectory: true)
        let destination = temporary.appendingPathComponent("Backups", isDirectory: true)
        for directory in [configDirectory, toolDirectory, managedDirectory, destination] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let installedExecutable = toolDirectory.appendingPathComponent("msw")
        try FileManager.default.copyItem(at: sourceExecutable, to: installedExecutable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedExecutable.path)
        try Data(repeating: 0x41, count: 4_096).write(
            to: managedDirectory.appendingPathComponent("managed-state.bin")
        )

        let jq = toolDirectory.appendingPathComponent("jq")
        try Data("#!/bin/sh\ncase \"$1\" in\n  -e) exit 0 ;;\n  -r) printf 'dev\\n' ;;\n  *) exit 1 ;;\nesac\n".utf8).write(to: jq)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: jq.path)
        let config = """
        MSW_VERSION="3.1.0"
        MSW_MSB_BIN="/usr/bin/false"
        MSW_JQ_BIN="\(jq.path)"
        MSW_GITHUB_MODE="local"
        """
        try Data(config.utf8).write(to: configDirectory.appendingPathComponent("config.sh"))
        let workspaces = #"{"schemaVersion":1,"workspaces":[{"name":"dev","cpu":4,"cpuCeiling":4,"memoryGiB":16,"memoryCeilingGiB":16,"workspaceStorageGiB":60,"runtimeStorageGiB":60}]}"#
        try Data(workspaces.utf8).write(to: configDirectory.appendingPathComponent("workspaces.json"))

        let runner = MSWCommandRunner(configuration: .init(
            homeDirectory: temporary,
            testMSWExecutable: installedExecutable
        ))
        let client = MSWClient(runner: runner)
        let model = AppModel(diagnostics: MSWDiagnostics(client: client))

        let returnedPreview = await model.prepareBackup(to: destination)
        let preview = try XCTUnwrap(returnedPreview)
        let resolvedExecutable = await client.executableURL()

        XCTAssertEqual(resolvedExecutable, installedExecutable)
        XCTAssertEqual(preview.destination, destination)
        XCTAssertGreaterThan(preview.sourceAllocatedBytes, 4_096)
        XCTAssertNil(preview.archiveEstimate)
        XCTAssertEqual(preview.runningWorkspaces, [])
        XCTAssertNil(model.detailError)
    }

    func testBackupPreviewDecodesCurrentlyResolvedHostCLIWhenAvailable() async throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-backup-preview-host-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: destination) }

        let client = MSWClient(runner: MSWCommandRunner())
        guard let handshake = try? await client.handshake().result,
              handshake.configurationAvailable,
              handshake.runtimeAvailable,
              handshake.capabilities.isComplete else {
            throw XCTSkip("No configured backup-preview-capable host MSW installation is currently resolved.")
        }
        let model = AppModel(diagnostics: MSWDiagnostics(client: client))

        let returnedPreview = await model.prepareBackup(to: destination)
        let executableURL = await client.executableURL()
        let preview = try XCTUnwrap(returnedPreview)
        let resolvedExecutable = try XCTUnwrap(executableURL)

        XCTAssertEqual(resolvedExecutable.lastPathComponent, "msw")
        XCTAssertEqual(preview.destination, destination)
        XCTAssertGreaterThan(preview.sourceAllocatedBytes, 0)
        XCTAssertNil(model.detailError)
    }

    func testBackupFixtureTracksIndependentConcurrentOperationsAndAdvancingProgress() throws {
        let destination = URL(fileURLWithPath: "/tmp/msw-backup-progress", isDirectory: true)
        let model = AppModel()
        model.installConcurrentBackupReattachmentFixture(destination: destination)
        let initial = try XCTUnwrap(model.backupOperations.first(where: { $0.state == .running }))

        model.installConcurrentBackupReattachmentFixture(destination: destination, advanced: true)
        let updated = try XCTUnwrap(model.backupOperations.first(where: { $0.id == initial.id }))
        XCTAssertEqual(model.backupOperations.count, 2)
        XCTAssertGreaterThan(updated.updatedAt, initial.updatedAt)
        XCTAssertGreaterThan(updated.processedBytes, initial.processedBytes)
        XCTAssertNotNil(model.backupOperations.first(where: { $0.state == .completed })?.result)
        XCTAssertFalse(model.isMaintenanceOperationInFlight)
    }

    func testBackupFixtureModelsFullPartialAndFailureResultsIndependently() throws {
        let destination = URL(fileURLWithPath: "/tmp/msw-backup-result-fixtures", isDirectory: true)

        for scenario in [AppModel.BackupUITestResultScenario.success, .partial, .failure] {
            let model = AppModel()
            model.installBackupUITestFixture(destination: destination, resultScenario: scenario)
            model.createBackup(to: destination)
            let operation = try XCTUnwrap(model.backupOperations.first)

            switch scenario {
            case .success:
                XCTAssertEqual(operation.state, .completed)
                XCTAssertEqual(operation.result?.archiveBytes, 7_340_032)
                XCTAssertEqual(operation.result?.workspacesNeedingRestart, [])
            case .partial:
                XCTAssertEqual(operation.state, .completed)
                XCTAssertEqual(operation.result?.workspacesNeedingRestart, ["personal"])
                XCTAssertEqual(model.maintenanceMessage, "Archive created. Restart required for: personal.")
            case .failure:
                XCTAssertEqual(operation.state, .failed)
                XCTAssertEqual(operation.phase, .failed)
                XCTAssertEqual(operation.error?.code, "MSW_BACKUP_FAILED")
                XCTAssertNil(operation.result)
            case .running:
                XCTFail("The result fixture test does not include the running scenario.")
            }
        }
    }

    func testBackupListReattachesPersistedRunningAndCompletedOperationsAfterModelRelaunch() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-backup-reattach-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }
        let destination = temporary.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let archive = destination.appendingPathComponent("persisted.tar.zst")
        let listResponse = #"""
        {"schemaVersion":1,"requestId":"backup-list","ok":true,"command":"backup-list","observedAt":"2026-08-26T12:00:10Z","result":[{"kind":"backup","operationId":"persisted-running-0001","requestKey":"request-running","state":"running","phase":"archive-writing","message":"Archiving persisted operation.","destination":"DESTINATION","startedAt":"2026-08-26T12:00:00Z","updatedAt":"2026-08-26T12:00:10Z","completedAt":null,"elapsedSeconds":10,"ownerPid":1234,"ownerProcessState":"running","sourceAllocatedBytes":12000000,"archiveEstimate":null,"runningWorkspaces":[],"progress":{"processedBytes":6000000,"writtenBytes":2000000,"throughputBytesPerSecond":600000,"totalBytes":null,"etaSeconds":null},"result":null,"error":null,"warnings":[]},{"kind":"backup","operationId":"persisted-completed-0002","requestKey":"request-completed","state":"completed","phase":"completed","message":"Archive completed.","destination":"DESTINATION","startedAt":"2026-08-26T11:59:00Z","updatedAt":"2026-08-26T11:59:10Z","completedAt":"2026-08-26T11:59:10Z","elapsedSeconds":10,"ownerPid":null,"ownerProcessState":"exited","sourceAllocatedBytes":8000000,"archiveEstimate":null,"runningWorkspaces":["dev"],"progress":{"processedBytes":8000000,"writtenBytes":3145728,"throughputBytesPerSecond":800000,"totalBytes":null,"etaSeconds":null},"result":{"archive":"ARCHIVE","archiveBytes":3145728,"checksum":"ARCHIVE.sha256","info":"ARCHIVE.info.txt","completedAt":"2026-08-26T11:59:10Z","stoppedWorkspaces":["dev"],"restartedWorkspaces":["dev"]},"error":null,"warnings":[]}],"warnings":[],"error":null}
        """#
            .replacingOccurrences(of: "DESTINATION", with: destination.path)
            .replacingOccurrences(of: "ARCHIVE", with: archive.path)
        let executable = temporary.appendingPathComponent("msw")
        let script = """
        #!/bin/sh
        if [ "$1" = "app" ] && [ "$2" = "handshake" ]; then
            printf '%s\\n' '\(protocolCompatibleHandshake)'
        elif [ "$1" = "app" ] && [ "$2" = "backup-list" ]; then
            printf '%s\\n' '\(listResponse)'
        else
            exit 64
        fi
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let diagnostics = MSWDiagnostics(client: MSWClient(runner: MSWCommandRunner(configuration: .init(
            homeDirectory: temporary, testMSWExecutable: executable
        ))))

        let relaunchedModel = AppModel(diagnostics: diagnostics)
        await relaunchedModel.refreshBackupOperations()

        XCTAssertEqual(relaunchedModel.backupOperations.count, 2)
        XCTAssertEqual(relaunchedModel.backupOperations.first?.id, "persisted-running-0001")
        XCTAssertEqual(relaunchedModel.backupOperations.first?.processedBytes, 6_000_000)
        let completed = try XCTUnwrap(relaunchedModel.backupOperations.first(where: { $0.state == .completed }))
        XCTAssertEqual(completed.result?.archive, archive)
        XCTAssertEqual(completed.result?.archiveBytes, 3_145_728)
        XCTAssertNil(relaunchedModel.detailError)
    }

    func testBackupListRejectsMalformedCompletedResultWithoutRuntimeRepair() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-backup-list-old-result-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }
        let destination = temporary.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let archive = destination.appendingPathComponent("persisted.tar.zst")
        let listResponse = #"""
        {"schemaVersion":1,"requestId":"backup-list","ok":true,"command":"backup-list","observedAt":"2026-08-26T12:00:10Z","result":[{"kind":"backup","operationId":"persisted-completed-0002","requestKey":"request-completed","state":"completed","phase":"completed","message":"Archive completed.","destination":"DESTINATION","startedAt":"2026-08-26T11:59:00Z","updatedAt":"2026-08-26T11:59:10Z","completedAt":"2026-08-26T11:59:10Z","elapsedSeconds":10,"ownerPid":null,"ownerProcessState":"exited","sourceAllocatedBytes":8000000,"archiveEstimate":null,"runningWorkspaces":["dev"],"progress":{"processedBytes":8000000,"writtenBytes":3145728,"throughputBytesPerSecond":800000,"totalBytes":null,"etaSeconds":null},"result":{"archive":"ARCHIVE","checksum":"ARCHIVE.sha256","info":"ARCHIVE.info.txt","completedAt":"2026-08-26T11:59:10Z","stoppedWorkspaces":["dev"],"restartedWorkspaces":["dev"]},"error":null,"warnings":[]}],"warnings":[],"error":null}
        """#
            .replacingOccurrences(of: "DESTINATION", with: destination.path)
            .replacingOccurrences(of: "ARCHIVE", with: archive.path)
        let executable = temporary.appendingPathComponent("msw")
        let script = """
        #!/bin/sh
        if [ "$1" = "app" ] && [ "$2" = "handshake" ]; then
            printf '%s\\n' '\(protocolCompatibleHandshake)'
        elif [ "$1" = "app" ] && [ "$2" = "backup-list" ]; then
            printf '%s\\n' '\(listResponse)'
        else
            exit 64
        fi
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let model = AppModel(diagnostics: MSWDiagnostics(client: MSWClient(runner: MSWCommandRunner(
            configuration: .init(homeDirectory: temporary, testMSWExecutable: executable)
        ))))

        await model.refreshBackupOperations()

        XCTAssertTrue(model.backupOperations.isEmpty)
        XCTAssertFalse(model.runtimeRepairRequired)
        XCTAssertNil(model.detailError)
        XCTAssertEqual(model.backupError, "MSW returned malformed backup data for backup-list.")
    }

    func testBackupListCorruptRecordDoesNotMasqueradeAsRuntimeRepair() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-backup-list-protocol-rejection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }
        let executable = temporary.appendingPathComponent("msw")
        let rejection = #"{"schemaVersion":1,"requestId":"backup-list-rejected","ok":false,"command":"backup-list","observedAt":null,"result":null,"warnings":[],"error":{"code":"MSW_BACKUP_RECORD_INVALID","message":"A durable backup operation record is corrupt.","recovery":"Copy the diagnostic details and inspect the record before retrying.","workspace":null,"retryable":false}}"#
        let script = """
        #!/bin/sh
        if [ "$1" = "app" ] && [ "$2" = "handshake" ]; then
            printf '%s\\n' '\(protocolCompatibleHandshake)'
        elif [ "$1" = "app" ] && [ "$2" = "backup-list" ]; then
            printf '%s\\n' '\(rejection)'
            exit 78
        else
            exit 64
        fi
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let model = AppModel(diagnostics: MSWDiagnostics(client: MSWClient(runner: MSWCommandRunner(
            configuration: .init(homeDirectory: temporary, testMSWExecutable: executable)
        ))))

        await model.refreshBackupOperations()

        XCTAssertTrue(model.backupOperations.isEmpty)
        XCTAssertFalse(model.runtimeRepairRequired)
        XCTAssertNil(model.detailError)
        XCTAssertTrue(model.backupError?.contains("durable backup operation record is corrupt") == true)
        XCTAssertNotNil(model.presentedBackupError)
    }

    func testRuntimeRepairPresentationOwnsOnlyClassifiedRuntimeErrors() {
        let model = AppModel(initialRuntimeRepairRequired: true)
        model.installRuntimeRepairUITestFixture()

        XCTAssertNotNil(model.detailError)
        XCTAssertNil(model.presentedDetailError)
        XCTAssertNotNil(model.backupError)
        XCTAssertNil(model.presentedBackupError)
        XCTAssertFalse(model.backupOperations.isEmpty)
        XCTAssertTrue(model.presentedBackupOperations.isEmpty)
        XCTAssertEqual(
            RuntimeRepairIssueClassifier.presentedMessage(
                "GitHub request timed out.",
                repairRequired: true
            ),
            "GitHub request timed out."
        )
        XCTAssertTrue(
            RuntimeRepairIssueClassifier.isRepairRelated(MSWClientError.invalidExecutable)
        )
        XCTAssertFalse(
            RuntimeRepairIssueClassifier.isRepairRelated(
                MSWClientError.timedOut(command: "github-status")
            )
        )
        XCTAssertFalse(
            RuntimeRepairIssueClassifier.isRepairRelated(
                MSWClientError.protocolFailure(MSWProtocolError(
                    code: "MSW_WORKSPACE_DISK_INVALID",
                    message: "The workspace disk could not be mounted as ext4.",
                    recovery: "Inspect the named volume.",
                    workspace: "dev",
                    retryable: false
                ))
            )
        )

        model.runtimeRepairDidSucceed()

        XCTAssertFalse(model.runtimeRepairRequired)
        XCTAssertNil(model.detailError)
        XCTAssertNil(model.backupError)
    }

    func testRuntimeRepairStateUsesExactHandshakeAndDedicatedRetryWithoutBackupProbe() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-runtime-repair-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }
        let handshakeURL = temporary.appendingPathComponent("handshake.json")
        let invocationLog = temporary.appendingPathComponent("invocations.log")
        let executable = temporary.appendingPathComponent("msw")
        let incompatibleHandshake = protocolCompatibleHandshake.replacingOccurrences(
            of: #""protocolVersion":1,"mswVersion""#,
            with: #""protocolVersion":2,"mswVersion""#
        )
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" >> "\(invocationLog.path)"
        if [ "$1" = "app" ] && [ "$2" = "handshake" ]; then
            /bin/cat "\(handshakeURL.path)"
        else
            exit 64
        fi
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data(protocolCompatibleHandshake.utf8).write(to: handshakeURL)

        let client = MSWClient(runner: MSWCommandRunner(configuration: .init(
            homeDirectory: temporary,
            testMSWExecutable: executable
        )))
        let model = AppModel(client: client)

        await model.refreshRuntimeRepairState(forceRefresh: true)
        XCTAssertFalse(model.runtimeRepairRequired)

        try Data(incompatibleHandshake.utf8).write(to: handshakeURL)
        await model.refreshRuntimeRepairState(forceRefresh: true)
        XCTAssertTrue(model.runtimeRepairRequired)

        try Data(protocolCompatibleHandshake.utf8).write(to: handshakeURL)
        model.runtimeRepairDidSucceed()
        for _ in 0..<100 where model.runtimeRepairRequired {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(model.runtimeRepairRequired)
        let invocations = try String(contentsOf: invocationLog, encoding: .utf8)
        XCTAssertFalse(invocations.contains("backup-"), "Runtime negotiation must never probe by launching a backup")
    }

    func testCancelledRuntimeNegotiationPreservesPublishedRepairState() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-runtime-repair-cancellation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }
        let executable = temporary.appendingPathComponent("msw")
        let script = """
        #!/bin/sh
        /bin/sleep 2
        printf '%s\\n' '\(protocolCompatibleHandshake)'
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let client = MSWClient(runner: MSWCommandRunner(configuration: .init(
            homeDirectory: temporary,
            testMSWExecutable: executable
        )))
        let model = AppModel(client: client, initialRuntimeRepairRequired: true)
        let refresh = Task { await model.refreshRuntimeRepairState(forceRefresh: true) }
        try await Task.sleep(for: .milliseconds(50))
        refresh.cancel()
        await refresh.value

        XCTAssertTrue(
            model.runtimeRepairRequired,
            "A cancelled handshake must not turn its transient nil resolution into new UI state"
        )
    }

    func testFailedOperationRefreshesRuntimeRepairStateWhenCachedExecutableDisappears() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-runtime-repair-operation-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }
        let executable = temporary.appendingPathComponent("msw")
        let script = """
        #!/bin/sh
        if [ "$1" = "app" ] && [ "$2" = "handshake" ]; then
            printf '%s\\n' '\(protocolCompatibleHandshake)'
        else
            exit 64
        fi
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let client = MSWClient(runner: MSWCommandRunner(configuration: .init(
            homeDirectory: temporary,
            testMSWExecutable: executable
        )))
        let model = AppModel(client: client)
        await model.refreshRuntimeRepairState(forceRefresh: true)
        XCTAssertFalse(model.runtimeRepairRequired)

        try FileManager.default.removeItem(at: executable)
        await model.refreshRemote()
        for _ in 0..<100 where !model.runtimeRepairRequired {
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertTrue(
            model.runtimeRepairRequired,
            "An operation failure must invalidate stale compatible state and re-resolve the executable"
        )
    }

    func testConcurrentExactHandshakeProbeDoesNotCorruptBackupPreviewState() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-runtime-repair-operation-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }
        let destination = temporary.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let executable = temporary.appendingPathComponent("msw")
        let firstHandshakeStarted = temporary.appendingPathComponent("first-handshake-started")
        let releaseFirstHandshake = temporary.appendingPathComponent("release-first-handshake")
        let previewResponse = #"{"schemaVersion":1,"requestId":"preview","ok":true,"command":"backup-preview","observedAt":"2026-08-26T12:00:00Z","result":{"destination":"DESTINATION","sourceAllocatedBytes":1024,"archiveEstimate":null,"runningWorkspaces":[]},"warnings":[],"error":null}"#
            .replacingOccurrences(of: "DESTINATION", with: destination.path)
        let script = """
        #!/bin/sh
        if [ "$1" = "app" ] && [ "$2" = "handshake" ]; then
            if (set -C; : > "\(firstHandshakeStarted.path)") 2>/dev/null; then
                while [ ! -f "\(releaseFirstHandshake.path)" ]; do /bin/sleep 0.01; done
            fi
            printf '%s\\n' '\(protocolCompatibleHandshake)'
        elif [ "$1" = "app" ] && [ "$2" = "backup-preview" ]; then
            printf '%s\\n' '\(previewResponse)'
        else
            exit 64
        fi
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let client = MSWClient(runner: MSWCommandRunner(configuration: .init(
            homeDirectory: temporary,
            testMSWExecutable: executable
        )))
        let model = AppModel(client: client, diagnostics: MSWDiagnostics(client: client))
        let staleProbe = Task { await model.refreshRuntimeRepairState(forceRefresh: true) }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: firstHandshakeStarted.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstHandshakeStarted.path))

        let preview = await model.prepareBackup(to: destination)
        XCTAssertNotNil(preview)
        XCTAssertFalse(model.runtimeRepairRequired)

        try Data().write(to: releaseFirstHandshake)
        await staleProbe.value

        XCTAssertFalse(model.runtimeRepairRequired)
    }

    func testStatusItemPublishesRepairStateWithoutChangingItsStableIdentityOrProductionBehavior() {
        let model = AppModel(initialRuntimeRepairRequired: true)
        let controller = StatusBarController(
            model: model,
            applicationPreferences: model.applicationPreferences
        )
        defer { controller.tearDown() }

        let button = controller.statusButton
        XCTAssertEqual(button?.accessibilityIdentifier(), "statusItem.button")
        XCTAssertEqual(button?.accessibilityLabel(), "MSW Monitor")
        XCTAssertEqual(button?.accessibilityValue() as? String, RuntimeRepairPresentation.statusValue)
        XCTAssertEqual(
            button?.accessibilityHelp(),
            RuntimeRepairAccessibilityIdentifier.statusWarning
        )
        XCTAssertEqual(controller.popover.behavior, .transient)
    }

    func testInitialWorkspacesAreFixedAndStopped() {
        let model = AppModel()

        XCTAssertEqual(model.workspaces.map(\.id), [.dev, .playgrounds, .personal])
        XCTAssertEqual(model.workspaces.map(\.state), [.stopped, .stopped, .stopped])
    }

    func testLifecycleConfirmationOwnershipAndCancellationAreSurfaceIsolated() {
        let model = AppModel()
        model.installLifecycleUITestFixture()

        model.stop(.dev, surface: .unifiedWindow)
        XCTAssertEqual(model.pendingLifecyclePlan(for: .unifiedWindow)?.action, "stop")
        XCTAssertNil(model.pendingLifecyclePlan(for: .statusPopover))

        model.restart(.dev, surface: .statusPopover)
        XCTAssertEqual(model.pendingLifecyclePlan(for: .statusPopover)?.action, "restart")
        XCTAssertEqual(model.pendingLifecyclePlan(for: .unifiedWindow)?.action, "stop")

        model.cancelPendingLifecycle(surface: .unifiedWindow)
        XCTAssertNil(model.pendingLifecyclePlan(for: .unifiedWindow))
        XCTAssertEqual(model.pendingLifecyclePlan(for: .statusPopover)?.action, "restart")
    }

    func testAppRouteMapsDeepLinksIntoUnifiedTabs() throws {
        let logs = try XCTUnwrap(AppRoute(
            deepLink: URL(string: "msw-monitor://workspace/dev?section=logs")!
        ))
        XCTAssertEqual(logs.tab, .workspaces)
        XCTAssertEqual(logs.workspace, .dev)
        XCTAssertEqual(logs.workspaceSection, .logs)

        let diagnostics = try XCTUnwrap(AppRoute(
            deepLink: URL(string: "msw-monitor://diagnostics")!
        ))
        XCTAssertEqual(diagnostics.tab, .overview)
        XCTAssertNil(diagnostics.workspaceSection)

        let activity = try XCTUnwrap(AppRoute(
            deepLink: URL(string: "msw-monitor://workspace/dev?section=activity")!
        ))
        XCTAssertEqual(activity.tab, .workspaces)
        XCTAssertEqual(activity.workspace, .dev)
        XCTAssertEqual(activity.workspaceSection, .activity)


        let overview = try XCTUnwrap(AppRoute(
            deepLink: URL(string: "msw-monitor://overview")!
        ))
        XCTAssertEqual(overview.tab, .overview)
        XCTAssertNil(overview.workspaceSection)

        let repositories = try XCTUnwrap(AppRoute(
            deepLink: URL(string: "msw-monitor://workspace/dev?section=repositories")!
        ))
        XCTAssertEqual(repositories.tab, .workspaces)
        XCTAssertEqual(repositories.workspaceSection, .files)
        XCTAssertEqual(AppNavigationState().tab, .overview)
        XCTAssertEqual(AppNavigationState().workspaceSection, .files)
    }


    func testGitHubSettingsRefreshPreservesCachedState() async throws {
        let provider = GitHubFixtureProvider(scenario: "interaction-states")
        let state = GitHubSettingsState(
            authorizationCoordinator: nil,
            provider: provider,
            accessMode: .local
        )

        await state.refresh()
        guard case .ready(let account, _, _) = state.connectionState else {
            return XCTFail("Expected the initial GitHub catalog to be cached.")
        }
        XCTAssertEqual(account?.login, "octocat")
        XCTAssertEqual(state.installations.map(\.id), [42])

        let refresh = Task { await state.refresh() }
        try await Task.sleep(for: .milliseconds(50))
        if case .loading = state.connectionState {
            XCTFail("A background refresh must preserve the cached GitHub settings.")
        }
        await refresh.value
        guard case .ready(let refreshedAccount, _, _) = state.connectionState else {
            return XCTFail("Expected the refreshed GitHub catalog to remain ready.")
        }
        XCTAssertEqual(refreshedAccount?.login, "octocat")
    }

    func testGitHubSettingsInitialLoadRetriesTransientFailure() async {
        let provider = GitHubFixtureProvider(scenario: "cancel-retry")
        let state = GitHubSettingsState(
            authorizationCoordinator: nil,
            provider: provider,
            accessMode: .local
        )

        await state.refresh()

        guard case .ready(let account, _, _) = state.connectionState else {
            return XCTFail("A transient startup failure must recover before publishing an error state.")
        }
        XCTAssertEqual(account?.login, "octocat")
        let attempts = await provider.catalogLoadAttempts()
        XCTAssertEqual(attempts, 2)
        XCTAssertNil(state.error)
    }

    func testGitHubSettingsConcurrentRefreshesShareOneCatalogLoad() async {
        let provider = GitHubFixtureProvider(scenario: "slow-first-load")
        let state = GitHubSettingsState(
            authorizationCoordinator: nil,
            provider: provider,
            accessMode: .local
        )

        async let first: Void = state.refresh()
        async let second: Void = state.refresh()
        _ = await (first, second)

        let attempts = await provider.catalogLoadAttempts()
        XCTAssertEqual(attempts, 1)
        guard case .ready = state.connectionState else {
            return XCTFail("The shared catalog load should publish one ready state.")
        }
    }

    func testSystemHealthUsesSetupPreflightChecks() async throws {
        let model = AppModel()
        let coordinator = MSWBootstrapUITestStub(failureWorkspace: "dev")
        model.configureSystemHealthChecks(using: coordinator)

        model.runSystemHealthChecks()
        for _ in 0..<100 {
            if !model.isSystemHealthLoading { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(
            model.systemHealthChecks.map(\.id),
            ["macos-version", "architecture", "disk-space", "memory"]
        )
        XCTAssertTrue(model.systemHealthChecks.allSatisfy { $0.status == .pass })
        XCTAssertFalse(model.isSystemHealthLoading)
    }

    func testPortsProtocolDecodesPerWorkspaceListeningState() throws {
        let payload = Data(#"{"schemaVersion":1,"requestId":"ports","ok":true,"command":"ports","observedAt":"2026-08-08T00:00:00Z","result":{"workspace":"all","workspaces":[{"workspace":"dev","lifecycle":"Running","host":"dev.msw.test","listeningState":"known","ports":[{"port":"3000","configured":true,"listening":true},{"port":"5173","configured":true,"listening":false}]},{"workspace":"personal","lifecycle":"Unknown","host":"personal.msw.test","listeningState":"unknown","ports":[{"port":"3000","configured":true,"listening":null}]}],"freshness":"fresh"},"warnings":[],"error":null}"#.utf8)

        let envelope = try MSWProtocolDecoder.decodeEnvelope(
            payload,
            as: MSWPortsResponse.self,
            expectedCommand: "ports"
        )
        let result = try XCTUnwrap(envelope.result)

        XCTAssertEqual(result.workspaces.map(\.workspace), ["dev", "personal"])
        XCTAssertEqual(result.workspaces[0].ports.map(\.listening), [true, false])
        XCTAssertEqual(result.workspaces[1].listeningState, .unknown)
        XCTAssertNil(result.workspaces[1].ports[0].listening)
    }

    func testUnavailableLogsBecomeQuietPerWorkspaceCapabilityState() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-logs-capability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let failure = #"{"schemaVersion":1,"requestId":"logs-failed","ok":false,"command":"logs","observedAt":"2026-08-08T00:00:00Z","result":null,"warnings":[],"error":{"code":"MSW_LOGS_UNAVAILABLE","message":"logs unavailable","recovery":"Repair the runtime.","workspace":"dev","retryable":true}}"#
        let executable = temporary.appendingPathComponent("msw")
        let script = """
        #!/bin/sh
        if [ "$1" = "app" ] && [ "$2" = "handshake" ]; then
            printf '%s\n' '\(protocolCompatibleHandshake)'
        elif [ "$1" = "app" ] && [ "$2" = "logs" ]; then
            printf '%s\n' '\(failure)'
            exit 69
        else
            exit 64
        fi
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let client = MSWClient(runner: MSWCommandRunner(configuration: .init(
            homeDirectory: temporary,
            testMSWExecutable: executable
        )))
        let model = AppModel(
            client: client,
            operationService: MSWOperationService(client: client)
        )
        let workspaces: [Workspace.ID] = [.dev, .personal]

        model.loadLogs(for: workspaces)
        for _ in 0..<100 {
            if !model.isDetailLoading { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(model.logsUnavailableWorkspaces, Set(["dev", "personal"]))
        XCTAssertTrue(model.logsByWorkspace.isEmpty)
        XCTAssertNil(model.detailError)
        XCTAssertFalse(model.isDetailLoading)

        model.loadLogs(for: workspaces)
        XCTAssertFalse(model.isDetailLoading)
        XCTAssertNil(model.detailError)
    }

    func testLogStreamPreservesPerLineObservedAt() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-logs-timestamps-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let stream = """
        {"schemaVersion":1,"type":"stream-start","protocolVersion":1,"stream":"logs","requestId":"logs-timestamps","workspace":"dev","observedAt":"2026-08-25T18:10:00Z","available":true,"lifecycle":"Running","freshness":"fresh","reason":null,"safeForDisplay":true}
        {"schemaVersion":1,"type":"log","requestId":"logs-timestamps","workspace":"dev","observedAt":"2026-08-25T18:10:01.125Z","source":"stdout","sessionId":17,"encoding":null,"message":"repeated message","safeForDisplay":true}
        {"schemaVersion":1,"type":"log","requestId":"logs-timestamps","workspace":"dev","observedAt":"2026-08-25T18:10:01.125Z","source":"stderr","sessionId":18,"encoding":"utf-8","message":"repeated message","safeForDisplay":true}
        {"schemaVersion":1,"type":"stream-end","requestId":"logs-timestamps","workspace":"dev","observedAt":"2026-08-25T18:10:02Z","safeForDisplay":true}
        """
        let executable = temporary.appendingPathComponent("msw")
        let script = """
        #!/bin/sh
        if [ "$1" = "app" ] && [ "$2" = "handshake" ]; then
            printf '%s\n' '\(protocolCompatibleHandshake)'
        elif [ "$1" = "app" ] && [ "$2" = "logs" ]; then
            cat <<'EOF'
        \(stream)
        EOF
        else
            exit 64
        fi
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let client = MSWClient(runner: MSWCommandRunner(configuration: .init(
            homeDirectory: temporary,
            testMSWExecutable: executable
        )))
        let response = try await client.logs(workspace: "dev")

        XCTAssertEqual(response.lines.count, 2)
        XCTAssertEqual(response.lines.map(\.message), ["repeated message", "repeated message"])
        XCTAssertEqual(response.lines.map(\.source), ["stdout", "stderr"])
        XCTAssertEqual(response.lines.map(\.sessionID), [17, 18])
        XCTAssertEqual(response.lines.map(\.encoding), [nil, "utf-8"])
        XCTAssertEqual(
            response.lines.map(\.observedAt),
            [
                Date(timeIntervalSince1970: 1_787_681_401.125),
                Date(timeIntervalSince1970: 1_787_681_401.125)
            ]
        )
    }

    func testLogTimestampsStayClockOnlyForASingleCalendarDay() {
        let utc = TimeZone(identifier: "UTC")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let locale = Locale(identifier: "en_US")

        let morning = Date(timeIntervalSince1970: 1_787_654_400)    // 2026-08-25T10:40:00Z
        let evening = Date(timeIntervalSince1970: 1_787_681_401.125) // 2026-08-25T18:10:01.125Z

        XCTAssertFalse(LogTimestamp.spansMultipleDays([morning, evening], calendar: calendar))
        XCTAssertFalse(LogTimestamp.spansMultipleDays([], calendar: calendar))
        XCTAssertFalse(LogTimestamp.spansMultipleDays([evening], calendar: calendar))

        let rendered = LogTimestamp.display(evening, spanningDays: false, locale: locale, timeZone: utc)
        XCTAssertTrue(rendered.contains("6:10:01"))
        XCTAssertFalse(rendered.contains("2026"))
    }

    func testLogTimestampsSpanningMidnightAddDayContext() {
        let utc = TimeZone(identifier: "UTC")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let locale = Locale(identifier: "en_US")

        let beforeMidnight = Date(timeIntervalSince1970: 1_787_702_399) // 2026-08-25T23:59:59Z
        let afterMidnight = Date(timeIntervalSince1970: 1_787_702_401)  // 2026-08-26T00:00:01Z

        XCTAssertTrue(LogTimestamp.spansMultipleDays([beforeMidnight, afterMidnight], calendar: calendar))

        let clockOnly = LogTimestamp.display(afterMidnight, spanningDays: false, locale: locale, timeZone: utc)
        let withDate = LogTimestamp.display(afterMidnight, spanningDays: true, locale: locale, timeZone: utc)
        XCTAssertTrue(withDate.contains("Aug 26, 2026"))
        XCTAssertTrue(withDate.contains(clockOnly))
        XCTAssertTrue(
            LogTimestamp.display(beforeMidnight, spanningDays: true, locale: locale, timeZone: utc)
                .contains("Aug 25, 2026")
        )
    }

    func testLogTimestampsAcrossMultipleDaysAreDatedAndOrderIndependent() {
        let utc = TimeZone(identifier: "UTC")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let locale = Locale(identifier: "en_US")

        let dayOne = Date(timeIntervalSince1970: 1_787_681_401.125)  // 2026-08-25T18:10:01.125Z
        let dayTwo = Date(timeIntervalSince1970: 1_787_767_801.125)  // 2026-08-26T18:10:01.125Z
        let dayThree = Date(timeIntervalSince1970: 1_787_854_201.125) // 2026-08-27T18:10:01.125Z

        XCTAssertTrue(LogTimestamp.spansMultipleDays([dayOne, dayTwo, dayThree], calendar: calendar))
        XCTAssertTrue(LogTimestamp.spansMultipleDays([dayThree, dayOne], calendar: calendar))

        let clockOnly = LogTimestamp.display(dayOne, spanningDays: false, locale: locale, timeZone: utc)
        let withDate = LogTimestamp.display(dayOne, spanningDays: true, locale: locale, timeZone: utc)
        XCTAssertTrue(withDate.contains("Aug 25, 2026"))
        XCTAssertTrue(withDate.contains(clockOnly))
        XCTAssertTrue(
            LogTimestamp.display(dayTwo, spanningDays: true, locale: locale, timeZone: utc)
                .contains("Aug 26, 2026")
        )
    }

    func testLogTimestampCopyCarriesFullISO8601WithOffset() throws {
        let dates = [
            Date(timeIntervalSince1970: 1_787_681_401.125), // 2026-08-25T18:10:01.125Z
            Date(timeIntervalSince1970: 1_787_702_400),     // 2026-08-26T00:00:00Z (midnight)
            Date(timeIntervalSince1970: 0)                  // 1970-01-01T00:00:00Z
        ]
        let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}(Z|[+-]\d{2}:\d{2})$"#
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withColonSeparatorInTimeZone]

        for date in dates {
            let copied = LogTimestamp.copy(date)
            XCTAssertNotNil(
                copied.range(of: pattern, options: .regularExpression),
                "Expected full ISO 8601 with offset, got \(copied)"
            )
            let parsed = try XCTUnwrap(parser.date(from: copied), "copy \(copied) must parse as ISO 8601")
            XCTAssertEqual(parsed.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.001)
        }
    }

    func testAppNavigationAppliesRouteWithoutDroppingWorkspaceContext() {
        let navigation = AppNavigationState(
            tab: .workspaces,
            workspace: .dev,
            workspaceSection: .files
        )
        navigation.apply(AppRoute(tab: .general))
        XCTAssertEqual(navigation.tab, .general)
        XCTAssertEqual(navigation.workspace, .dev)
        XCTAssertEqual(navigation.workspaceSection, .files)
    }

    func testTerminalLauncherBuildsSelfDeletingCommandScript() {
        let script = TerminalLauncher.commandScript(
            executableURL: URL(fileURLWithPath: "/tmp/MSW Monitor's/msw"),
            workspaceID: "dev",
            executableSearchPath: "/Users/test/.local/bin:/usr/bin:/bin"
        )

        XCTAssertTrue(script.contains("rm -f -- \"$script_path\""))
        XCTAssertTrue(script.contains(#"exec '/tmp/MSW Monitor'"'"'s/msw' 'dev'"#))
        XCTAssertTrue(script.contains("export PATH='/Users/test/.local/bin:/usr/bin:/bin'"))
    }

    func testTerminalLauncherBuildsNativeGhosttyTabAutomation() {
        let script = TerminalLauncher.ghosttyScript(
            executableURL: URL(fileURLWithPath: "/usr/local/bin/msw"),
            workspaceID: "dev",
            executableSearchPath: "/Users/test/.local/bin:/opt/homebrew/bin:/usr/bin:/bin"
        )

        XCTAssertTrue(script.contains("new tab in front window with configuration cfg"))
        XCTAssertTrue(script.contains("set commandText to \"'/usr/local/bin/msw' 'dev'\""))
        XCTAssertTrue(script.contains(
            "set environment variables of cfg to {\"PATH=/Users/test/.local/bin:/opt/homebrew/bin:/usr/bin:/bin\"}"
        ))
    }

    func testApplicationOverridesPersistByBundleIdentifierAndSystemDefaultClearsThem() throws {
        let suiteName = "ApplicationPreferenceStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let catalog = applicationCatalogFixture()

        let preferences = ApplicationPreferenceStore(
            userDefaults: defaults,
            catalogProvider: { catalog }
        )
        preferences.setTerminalOverride("com.mitchellh.ghostty")
        preferences.setSourceEditorOverride("dev.zed.Zed")

        XCTAssertEqual(defaults.string(forKey: ApplicationPreferenceStore.terminalOverrideKey), "com.mitchellh.ghostty")
        XCTAssertEqual(defaults.string(forKey: ApplicationPreferenceStore.sourceEditorOverrideKey), "dev.zed.Zed")
        let restored = ApplicationPreferenceStore(userDefaults: defaults, catalogProvider: { catalog })
        XCTAssertEqual(restored.resolvedTerminal?.displayName, "Ghostty")
        XCTAssertEqual(restored.resolvedSourceEditor?.displayName, "Zed")

        restored.terminalSelection = ""
        restored.sourceEditorSelection = ""
        XCTAssertNil(defaults.string(forKey: ApplicationPreferenceStore.terminalOverrideKey))
        XCTAssertNil(defaults.string(forKey: ApplicationPreferenceStore.sourceEditorOverrideKey))
        XCTAssertEqual(restored.resolvedTerminal?.displayName, "Fixture Terminal")
        XCTAssertEqual(restored.resolvedSourceEditor?.displayName, "Xcode")
    }

    func testMissingApplicationOverrideIsClearedAndFallsBackToSystemDefault() throws {
        let suiteName = "ApplicationPreferenceMissingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("dev.zed.Zed-Nightly", forKey: ApplicationPreferenceStore.sourceEditorOverrideKey)

        let preferences = ApplicationPreferenceStore(userDefaults: defaults) {
            self.applicationCatalogFixture()
        }

        XCTAssertNil(preferences.sourceEditorOverrideBundleIdentifier)
        XCTAssertEqual(preferences.sourceEditorSelection, "")
        XCTAssertEqual(preferences.resolvedSourceEditor?.displayName, "Xcode")
        XCTAssertEqual(preferences.systemDefaultSourceEditorLabel, "System Default — Xcode")
        XCTAssertNil(defaults.string(forKey: ApplicationPreferenceStore.sourceEditorOverrideKey))
    }

    func testInstalledApplicationRefreshClearsAnUninstalledOverrideAndFallsBackLive() throws {
        let suiteName = "ApplicationPreferenceRefreshTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var catalog = applicationCatalogFixture()
        let preferences = ApplicationPreferenceStore(
            userDefaults: defaults,
            catalogProvider: { catalog }
        )
        preferences.setSourceEditorOverride("dev.zed.Zed")
        XCTAssertEqual(preferences.resolvedSourceEditor?.displayName, "Zed")

        catalog = SystemApplicationCatalog(
            defaults: catalog.defaults,
            terminals: catalog.terminals,
            sourceEditors: []
        )
        preferences.refreshInstalledApplications()

        XCTAssertNil(preferences.sourceEditorOverrideBundleIdentifier)
        XCTAssertEqual(preferences.sourceEditorSelection, "")
        XCTAssertEqual(preferences.resolvedSourceEditor?.displayName, "Xcode")
        XCTAssertNil(defaults.string(forKey: ApplicationPreferenceStore.sourceEditorOverrideKey))
    }

    func testApplicationPreferenceChangesUpdateActionLabelsLive() throws {
        let suiteName = "ApplicationPreferenceLabelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let catalog = applicationCatalogFixture()
        let preferences = ApplicationPreferenceStore(
            userDefaults: defaults,
            catalogProvider: { catalog }
        )
        let model = AppModel(applicationPreferences: preferences)

        XCTAssertEqual(model.terminalActionTitle, "Open in Fixture Terminal")
        XCTAssertEqual(model.editorActionTitle, "Open in Xcode…")
        preferences.setTerminalOverride("com.mitchellh.ghostty")
        preferences.setSourceEditorOverride("dev.zed.Zed")
        XCTAssertEqual(model.terminalActionTitle, "Open in Ghostty")
        XCTAssertEqual(model.editorActionTitle, "Open in Zed…")
        XCTAssertEqual(model.editorOpenActionTitle, "Open in Zed")
    }

    func testResolvedLaunchTargetsUseSelectedAdaptersAndCatalogIsStable() throws {
        let suiteName = "ApplicationPreferenceLaunchTargetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let duplicateZed = SystemApplication(
            url: URL(fileURLWithPath: "/Applications/Zed Duplicate.app"),
            bundleIdentifier: "dev.zed.Zed",
            displayName: "Zed Duplicate"
        )
        var catalog = applicationCatalogFixture()
        catalog = SystemApplicationCatalog(
            defaults: catalog.defaults,
            terminals: Array(catalog.terminals.reversed()),
            sourceEditors: [duplicateZed] + catalog.sourceEditors
        )
        let preferences = ApplicationPreferenceStore(
            userDefaults: defaults,
            catalogProvider: { catalog }
        )
        preferences.setTerminalOverride("com.mitchellh.ghostty")
        preferences.setSourceEditorOverride("dev.zed.Zed")

        XCTAssertEqual(preferences.catalog.terminals.map(\.displayName), ["Ghostty", "iTerm"])
        XCTAssertEqual(preferences.catalog.sourceEditors.count, 1)
        XCTAssertEqual(preferences.resolvedTerminal?.bundleIdentifier, "com.mitchellh.ghostty")
        XCTAssertEqual(preferences.resolvedSourceEditor?.bundleIdentifier, "dev.zed.Zed")
        XCTAssertEqual(
            TerminalLauncher.handoffAdapter(bundleIdentifier: preferences.resolvedTerminal?.bundleIdentifier),
            .ghosttyNativeTab
        )
        XCTAssertEqual(
            TerminalLauncher.handoffAdapter(bundleIdentifier: "com.googlecode.iterm2"),
            .commandFile
        )
    }

    private func applicationCatalogFixture() -> SystemApplicationCatalog {
        let terminal = SystemApplication(
            url: URL(fileURLWithPath: "/Applications/Fixture Terminal.app"),
            bundleIdentifier: "fixture.default-terminal",
            displayName: "Fixture Terminal"
        )
        let xcode = SystemApplication(
            url: URL(fileURLWithPath: "/Applications/Xcode.app"),
            bundleIdentifier: "com.apple.dt.Xcode",
            displayName: "Xcode"
        )
        return SystemApplicationCatalog(
            defaults: SystemApplicationDefaults(terminal: terminal, sourceEditor: xcode),
            terminals: [
                SystemApplication(
                    url: URL(fileURLWithPath: "/Applications/iTerm.app"),
                    bundleIdentifier: "com.googlecode.iterm2",
                    displayName: "iTerm"
                ),
                SystemApplication(
                    url: URL(fileURLWithPath: "/Applications/Ghostty.app"),
                    bundleIdentifier: "com.mitchellh.ghostty",
                    displayName: "Ghostty"
                )
            ],
            sourceEditors: [
                SystemApplication(
                    url: URL(fileURLWithPath: "/Applications/Zed.app"),
                    bundleIdentifier: "dev.zed.Zed",
                    displayName: "Zed"
                )
            ]
        )
    }

    func testExternalApplicationActionTitlesUseDiscoveredBundleNames() {
        let defaults = SystemApplicationDefaults(
            terminal: SystemApplication(
                url: URL(fileURLWithPath: "/Applications/ExampleTerminal.app"),
                bundleIdentifier: "example.terminal",
                displayName: "Example Terminal"
            ),
            sourceEditor: SystemApplication(
                url: URL(fileURLWithPath: "/Applications/ExampleEditor.app"),
                bundleIdentifier: "example.editor",
                displayName: "Example Editor"
            )
        )
        let model = AppModel(applicationDefaults: defaults)

        XCTAssertEqual(model.terminalActionTitle, "Open in Example Terminal")
        XCTAssertEqual(model.editorActionTitle, "Open in Example Editor…")
        XCTAssertEqual(model.editorOpenActionTitle, "Open in Example Editor")
        XCTAssertTrue(
            model.actionAvailability(for: .dev, action: .openTerminal).recovery?
                .contains("open in example terminal") == true
        )
        XCTAssertTrue(
            model.actionAvailability(for: .dev, action: .openEditor).recovery?
                .contains("open in example editor") == true
        )
    }

    func testUnsupportedDefaultEditorFailsWithoutFallback() async {
        let application = SystemApplication(
            url: URL(fileURLWithPath: "/Applications/Xcode.app"),
            bundleIdentifier: "com.apple.dt.Xcode",
            displayName: "Xcode"
        )
        do {
            try await SourceEditorLauncher().open(
                application: application,
                target: MSWEditorTarget(workspace: "dev", path: ".", host: "dev.msb")
            )
            XCTFail("An unverified editor must not be opened.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Xcode"))
            XCTAssertTrue(error.localizedDescription.contains("no fallback was opened"))
        }
    }

    func testZedIsAnExplicitVerifiedSourceEditorAdapter() throws {
        for bundleIdentifier in [
            "dev.zed.Zed",
            "dev.zed.Zed-Preview",
            "dev.zed.Zed-Nightly",
            "dev.zed.Zed-Dev"
        ] {
            let application = SystemApplication(
                url: URL(fileURLWithPath: "/Applications/Zed.app"),
                bundleIdentifier: bundleIdentifier,
                displayName: "Fixture Editor"
            )

            XCTAssertEqual(
                try SourceEditorLauncher().validate(application: application),
                application
            )
        }
    }

    func testEditorTargetEncodesExactFolderPathForVerifiedZedAdapter() throws {
        let target = MSWEditorTarget(
            workspace: "dev",
            path: "Projects/Demo #1",
            host: "dev.msb"
        )

        XCTAssertEqual(
            try XCTUnwrap(target.remoteURL).absoluteString,
            "ssh://root@dev.msb/workspace/Projects/Demo%20%231"
        )
        XCTAssertEqual(
            try XCTUnwrap(target.zedRemoteURL).absoluteString,
            "zed://ssh/root@dev.msb/workspace/Projects/Demo%20%231"
        )

        for path in ["../escape", "/workspace", "safe//nested", "bad\u{7f}path"] {
            let unsafe = MSWEditorTarget(workspace: "dev", path: path, host: "dev.msb")
            XCTAssertFalse(unsafe.isValid)
            XCTAssertNil(unsafe.remoteURL)
            XCTAssertNil(unsafe.zedRemoteURL)
        }
    }

    func testDirectoryClientRejectsUnsafeInputsAndMalformedResponsePaths() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-directory-client-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let executable = temporary.appendingPathComponent("msw")
        let malformed = #"{"schemaVersion":1,"requestId":"directories","ok":true,"command":"directory-list","observedAt":"2026-08-08T00:00:00Z","result":{"workspace":"dev","path":".","query":null,"entries":[{"name":"escape","path":"../escape","kind":"directory"}],"truncated":false},"warnings":[],"error":null}"#
        let outOfScope = #"{"schemaVersion":1,"requestId":"directories","ok":true,"command":"directory-list","observedAt":"2026-08-08T00:00:00Z","result":{"workspace":"dev","path":"Projects","query":null,"entries":[{"name":"Other","path":"Other","kind":"directory"}],"truncated":false},"warnings":[],"error":null}"#
        let duplicate = #"{"schemaVersion":1,"requestId":"directories","ok":true,"command":"directory-list","observedAt":"2026-08-08T00:00:00Z","result":{"workspace":"dev","path":"Duplicate","query":null,"entries":[{"name":"Child","path":"Duplicate/Child","kind":"directory"},{"name":"Child","path":"Duplicate/Child","kind":"directory"}],"truncated":false},"warnings":[],"error":null}"#
        let malformedTarget = #"{"schemaVersion":1,"requestId":"editor-target","ok":true,"command":"editor-target","observedAt":"2026-08-08T00:00:00Z","result":{"workspace":"dev","path":".","host":"personal.msb"},"warnings":[],"error":null}"#
        let script = """
        #!/bin/sh
        if [ "$1" = "app" ] && [ "$2" = "handshake" ]; then
            printf '%s\n' '\(protocolCompatibleHandshake)'
        elif [ "$1" = "app" ] && [ "$2" = "directory-list" ]; then
            if [ "$6" = "Projects" ]; then
                printf '%s\n' '\(outOfScope)'
            elif [ "$6" = "Duplicate" ]; then
                printf '%s\n' '\(duplicate)'
            else
                printf '%s\n' '\(malformed)'
            fi
        elif [ "$1" = "app" ] && [ "$2" = "editor-target" ]; then
            printf '%s\n' '\(malformedTarget)'
        else
            exit 64
        fi
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let client = MSWClient(runner: MSWCommandRunner(configuration: .init(
            homeDirectory: temporary,
            testMSWExecutable: executable
        )))

        do {
            _ = try await client.directories(workspace: "dev", path: "../escape")
            XCTFail("Traversal must be rejected before invoking MSW.")
        } catch { XCTAssertEqual(error as? MSWClientError, .invalidArguments) }
        do {
            _ = try await client.directories(workspace: "dev", path: String(repeating: "x", count: 1_025))
            XCTFail("Oversized paths must be rejected before invoking MSW.")
        } catch { XCTAssertEqual(error as? MSWClientError, .invalidArguments) }
        do {
            _ = try await client.directories(workspace: "dev", query: "bad\u{1b}query")
            XCTFail("Control characters in search queries must be rejected before invoking MSW.")
        } catch { XCTAssertEqual(error as? MSWClientError, .invalidArguments) }
        do {
            _ = try await client.directories(workspace: "dev", limit: 201)
            XCTFail("Unbounded directory limits must be rejected.")
        } catch { XCTAssertEqual(error as? MSWClientError, .invalidArguments) }
        do {
            _ = try await client.directories(workspace: "dev")
            XCTFail("Malformed returned paths must be rejected.")
        } catch { XCTAssertEqual(error as? MSWClientError, .malformedJSON(command: "directory-list")) }
        do {
            _ = try await client.directories(workspace: "dev", path: "Projects")
            XCTFail("Nonrecursive listings must not return folders outside their requested scope.")
        } catch { XCTAssertEqual(error as? MSWClientError, .malformedJSON(command: "directory-list")) }
        do {
            _ = try await client.directories(workspace: "dev", path: "Duplicate")
            XCTFail("Duplicate directory identities must be rejected before SwiftUI consumes them.")
        } catch { XCTAssertEqual(error as? MSWClientError, .malformedJSON(command: "directory-list")) }
        do {
            _ = try await client.editorTarget(workspace: "dev")
            XCTFail("A target for another workspace must be rejected.")
        } catch { XCTAssertEqual(error as? MSWClientError, .malformedJSON(command: "editor-target")) }
    }

    // MARK: - Local-mode init never builds Connect dependencies (blocker 7)

    func testAppDelegateLocalModeConstructsNoConnectDependencies() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-local-init-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        // No trusted scope attestation => local mode.
        let configuration = MSWConnectConfiguration()
        XCTAssertFalse(configuration.hasTrustedScopeAttestation)
        let policyStore = GitHubPolicyStore(policyURL: temporary.appendingPathComponent("github-policy.json"))

        let delegate = AppDelegate(connectConfiguration: configuration, policyStore: policyStore)

        XCTAssertEqual(delegate.accessMode, .local)
        XCTAssertFalse(delegate.hasConnectDependencies,
                       "Local init must not instantiate or pass broker/client/coordinator")
        XCTAssertFalse(delegate.clientHasConnectDependencies,
                       "Local-mode CLI client must not carry a Connect broker")
        XCTAssertNotNil(delegate.provider, "Local mode must build the local provider")
        XCTAssertNotNil(delegate.policyStore, "Local mode must build the policy store")
    }

    func testAppDelegateLocalModeDoesNotReadConnectStores() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-local-no-connect-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        // A poisoned credentials.json at the real location must not be
        // touched by local init. The AppDelegate seam takes an explicit
        // policy store, so no Connect metadata path is ever consulted.
        let configuration = MSWConnectConfiguration()
        let delegate = AppDelegate(
            connectConfiguration: configuration,
            policyStore: GitHubPolicyStore(policyURL: temporary.appendingPathComponent("github-policy.json"))
        )
        XCTAssertEqual(delegate.accessMode, .local)
        XCTAssertFalse(delegate.hasConnectDependencies)
        XCTAssertFalse(delegate.clientHasConnectDependencies)
    }

    func testAppDelegateConnectModeStillBuildsConnectDependencies() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-connect-init-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        // A trusted scope attestation => connect mode keeps the Connect stack.
        let signingKey = Curve25519.Signing.PrivateKey()
        let configuration = testConnectConfiguration(
            scopeAttestationPublicKey: signingKey.publicKey.rawRepresentation,
            requiresScopeAttestation: true
        )
        XCTAssertTrue(configuration.hasTrustedScopeAttestation)

        let delegate = AppDelegate(
            connectConfiguration: configuration,
            policyStore: GitHubPolicyStore(policyURL: temporary.appendingPathComponent("github-policy.json")),
            makeBroker: {
                try? CredentialBroker(
                    keychain: InMemoryConnectKeychain(),
                    metadataURL: temporary.appendingPathComponent("credentials.json")
                )
            }
        )
        XCTAssertEqual(delegate.accessMode, .connect)
        XCTAssertTrue(delegate.hasConnectDependencies,
                      "Connect mode keeps the dormant Connect stack compiling")
        XCTAssertTrue(delegate.clientHasConnectDependencies,
                      "Connect-mode CLI client carries the broker")
        XCTAssertNil(delegate.provider)
    }

    func testSetupWindowControllerLocalModeNeverCreatesFallbackBroker() {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-fallback-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)

        // Local mode must drop even a passed-in coordinator: never pass or
        // instantiate the Connect coordinator in local mode.
        XCTAssertNil(SetupWindowController.resolvedAuthorization(accessMode: .local, authorizationCoordinator: nil))
        if let broker = try? CredentialBroker(
            keychain: InMemoryConnectKeychain(),
            metadataURL: temporary.appendingPathComponent("credentials.json")
        ) {
            let coordinator = GitHubAuthorizationCoordinator(broker: broker)
            XCTAssertNil(SetupWindowController.resolvedAuthorization(
                accessMode: .local,
                authorizationCoordinator: coordinator
            ))
            // Connect mode passes the supplied coordinator through.
            XCTAssertTrue(SetupWindowController.resolvedAuthorization(
                accessMode: .connect,
                authorizationCoordinator: coordinator
            ) === coordinator)
        }
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
    }

    func testNotificationDeliveryCapsPersistentFailures() async {
        let defaults = UserDefaults(suiteName: "notification-retry-\(UUID().uuidString)")!
        defaults.set(true, forKey: "notifications.enabled")
        defaults.set(true, forKey: "notifications.category.actionFailures.enabled")
        let center = ControllableNotificationCenter(shouldFailDelivery: true)
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

    func testDirectNotificationEnablementRequestsAlertAndSoundPermission() async {
        let defaults = UserDefaults(suiteName: "notification-enable-\(UUID().uuidString)")!
        let center = ControllableNotificationCenter(status: .notDetermined)
        let coordinator = NotificationCoordinator(defaults: defaults, notificationCenter: center)

        let enabled = await coordinator.setNotificationsEnabled(true)
        XCTAssertTrue(enabled)
        XCTAssertTrue(coordinator.notificationsEnabled())
        XCTAssertEqual(center.requestedOptions, [[.alert, .sound]])
    }

    func testEnablingCategoryEnablesNotificationsFirst() async {
        let defaults = UserDefaults(suiteName: "notification-category-enable-\(UUID().uuidString)")!
        let center = ControllableNotificationCenter(status: .notDetermined)
        let coordinator = NotificationCoordinator(defaults: defaults, notificationCenter: center)

        let enabled = await coordinator.setEnabled(true, for: .actionFailures)
        XCTAssertTrue(enabled)
        XCTAssertTrue(coordinator.notificationsEnabled())
        XCTAssertEqual(coordinator.enabledCategories(), [.actionFailures])
        XCTAssertEqual(center.requestedOptions.count, 1)
    }

    func testDeniedNotificationEnablementStaysOffWithoutRequestingPermission() async {
        let defaults = UserDefaults(suiteName: "notification-denied-\(UUID().uuidString)")!
        let center = ControllableNotificationCenter(status: .denied)
        let coordinator = NotificationCoordinator(defaults: defaults, notificationCenter: center)

        let enabled = await coordinator.setNotificationsEnabled(true)
        XCTAssertFalse(enabled)
        XCTAssertFalse(coordinator.notificationsEnabled())
        XCTAssertTrue(center.requestedOptions.isEmpty)
    }

    func testFailedPermissionDoesNotClearSavedCategories() async {
        for (status, result) in [
            (UNAuthorizationStatus.notDetermined, Result<Bool, Error>.success(false)),
            (.denied, .success(true)),
        ] {
            let defaults = UserDefaults(suiteName: "notification-preserve-\(UUID().uuidString)")!
            defaults.set(true, forKey: "notifications.category.actionFailures.enabled")
            let center = ControllableNotificationCenter(status: status, authorizationResult: result)
            let coordinator = NotificationCoordinator(defaults: defaults, notificationCenter: center)

            let enabled = await coordinator.setEnabled(true, for: .actionFailures)
            XCTAssertFalse(enabled)
            XCTAssertEqual(coordinator.enabledCategories(), [.actionFailures])
            XCTAssertFalse(coordinator.notificationsEnabled())
        }
    }

    func testGlobalNotificationDisableSuppressesDeliveryAndPreservesCategories() async {
        let defaults = UserDefaults(suiteName: "notification-suppression-\(UUID().uuidString)")!
        defaults.set(true, forKey: "notifications.enabled")
        defaults.set(true, forKey: "notifications.category.actionFailures.enabled")
        let center = ControllableNotificationCenter()
        let coordinator = NotificationCoordinator(defaults: defaults, notificationCenter: center)

        let enabled = await coordinator.setNotificationsEnabled(false)
        XCTAssertFalse(enabled)
        await coordinator.deliver(makeNotificationEvent())

        XCTAssertEqual(center.addInvocationCount, 0)
        XCTAssertEqual(coordinator.enabledCategories(), [.actionFailures])
    }

    func testNotificationCategoriesUseApprovedLabelsAndMapEveryEventOnce() {
        XCTAssertEqual(
            MSWNotificationCategory.allCases.map(\.title),
            ["Workspace health", "Action failures", "Backup failures", "Credential reminders"]
        )
        XCTAssertEqual(
            MSWNotificationCategory.allCases.map(\.detail),
            [
                "Alerts when a workspace remains unavailable, stops unexpectedly, or is quarantined.",
                "Alerts when a workspace action fails.",
                "Alerts when a requested backup does not complete.",
                "Reminders when workspace credentials need attention.",
            ]
        )
        XCTAssertEqual(MSWNotificationCategory.category(for: .sustainedUnavailability), .workspaceHealth)
        XCTAssertEqual(MSWNotificationCategory.category(for: .quarantine), .workspaceHealth)
        XCTAssertEqual(MSWNotificationCategory.category(for: .lifecycleLoss), .workspaceHealth)
        XCTAssertEqual(MSWNotificationCategory.category(for: .operationFailure), .actionFailures)
        XCTAssertEqual(MSWNotificationCategory.category(for: .backupFailure), .backupFailures)
        XCTAssertEqual(MSWNotificationCategory.category(for: .credentialDeadline), .credentialReminders)
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
            testMSWExecutable: executable
        )))
        let model = AppModel(client: client)

        XCTAssertEqual(model.aggregateText, "Not observed")
        XCTAssertTrue(model.workspaces.allSatisfy { $0.state == .unknown && $0.freshness == .unavailable })

        await model.refreshRemote()
        XCTAssertEqual(model.aggregateText, "Unavailable")
        XCTAssertEqual(model.lastRecovery?.code, "MSW_RUNTIME_UNAVAILABLE")
        XCTAssertEqual(model.lastRecovery?.recovery, "Repair MSW and retry.")
        XCTAssertTrue(model.notificationEvents.isEmpty)

        await model.refreshRemote()
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
            testMSWExecutable: executable
        )))
        let model = AppModel(client: client)

        await model.refreshRemote()
        let stateActivityCount = model.activities.filter { $0.title == "State changed" }.count
        await model.refreshRemote()
        XCTAssertEqual(model.activities.filter { $0.title == "State changed" }.count, stateActivityCount)
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
            testMSWExecutable: executable
        )))
        let model = AppModel(client: client)
        await model.refreshRemote()

        let fresh = try XCTUnwrap(model.workspaces.first(where: { $0.id == .dev }))
        XCTAssertEqual(model.aggregateText, "Ready")
        XCTAssertEqual(fresh.state, .running)
        XCTAssertTrue(fresh.canOpenTerminal)
        XCTAssertTrue(fresh.canPush)
        XCTAssertTrue(fresh.serverCapabilities.canOpenTerminal)
        XCTAssertTrue(fresh.serverCapabilities.canPush)

        try Data().write(to: failureMarker)
        await model.refreshRemote()

        let stale = try XCTUnwrap(model.workspaces.first(where: { $0.id == .dev }))
        XCTAssertEqual(model.aggregateText, "Last known state")
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
        let baseline = Date()
        try encoder.encode(makeTestStateEnvelope(
            devLifecycle: .stopped,
            devQuarantine: .clear,
            observedAt: baseline.addingTimeInterval(-1)
        )).write(to: stoppedURL)
        try encoder.encode(makeTestStateEnvelope(
            devLifecycle: .running,
            devQuarantine: .clear,
            observedAt: baseline.addingTimeInterval(2)
        )).write(to: runningURL)
        try encoder.encode(MSWEnvelope(
            schemaVersion: 1, requestId: "plan-start", ok: true, command: "plan", observedAt: Date(),
            result: MSWLifecyclePlan(
                planId: "plan-start", action: "start", workspace: "dev",
                expiresAt: Date().addingTimeInterval(300), confirmationPhrase: "START dev", effects: "Starting dev."
            )
        )).write(to: planURL)
        try encoder.encode(MSWEnvelope(
            schemaVersion: 1, requestId: "apply-start", ok: true, command: "apply", observedAt: baseline,
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
            testMSWExecutable: executable
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

    func testRestartVerificationAcceptsGapOnlyAfterFreshRunningObservation() async throws {
        let baseline = Date().addingTimeInterval(5)
        let model = try makeLifecycleVerificationModel(
            action: .restart,
            initial: (.running, baseline.addingTimeInterval(-1)),
            observations: [
                (.stopped, baseline.addingTimeInterval(1), 0),
                (.running, baseline.addingTimeInterval(2), 0)
            ],
            applyObservedAt: baseline,
            delays: [.milliseconds(100)]
        )

        await model.refreshRemote()
        try await beginConfirmedLifecycle(.restart, model: model)
        for _ in 0..<80 {
            if model.workspaces.first(where: { $0.id == .dev })?.state == .stopped { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let gap = try XCTUnwrap(model.workspaces.first(where: { $0.id == .dev }))
        XCTAssertEqual(gap.state, .stopped)
        XCTAssertFalse(gap.canStart)
        XCTAssertFalse(gap.canStop)
        XCTAssertFalse(gap.canRestart)
        let operation = try await waitForLifecycleCompletion(in: model)

        XCTAssertEqual(operation.outcome, .succeeded)
        XCTAssertEqual(model.workspaces.first(where: { $0.id == .dev })?.state, .running)
    }

    func testStopVerificationAcceptsFreshStoppedObservation() async throws {
        let baseline = Date().addingTimeInterval(5)
        let model = try makeLifecycleVerificationModel(
            action: .stop,
            initial: (.running, baseline.addingTimeInterval(-1)),
            observations: [(.stopped, baseline.addingTimeInterval(1), 0)],
            applyObservedAt: baseline,
            delays: []
        )

        await model.refreshRemote()
        try await beginConfirmedLifecycle(.stop, model: model)
        let operation = try await waitForLifecycleCompletion(in: model)

        XCTAssertEqual(operation.outcome, .succeeded)
        XCTAssertEqual(model.workspaces.first(where: { $0.id == .dev })?.state, .stopped)
    }

    func testLifecycleVerificationTimeoutIsTruthfulAndProvidesCopyableDiagnostics() async throws {
        let baseline = Date().addingTimeInterval(5)
        let model = try makeLifecycleVerificationModel(
            action: .restart,
            initial: (.running, baseline.addingTimeInterval(-1)),
            observations: [(.stopped, baseline.addingTimeInterval(1), 0)],
            applyObservedAt: baseline,
            delays: [.milliseconds(1)]
        )

        await model.refreshRemote()
        try await beginConfirmedLifecycle(.restart, model: model)
        let operation = try await waitForLifecycleCompletion(in: model)

        XCTAssertEqual(operation.outcome, .unknown)
        XCTAssertTrue(operation.message.contains("Timed out waiting for a fresh running observation"))
        let notice = try XCTUnwrap(model.latestOperationFailure)
        XCTAssertEqual(notice.reason, operation.message)
        XCTAssertTrue(notice.diagnosticDetails?.contains("Required workspace observation after:") == true)
        XCTAssertTrue(notice.diagnosticDetails?.contains("Latest workspace observation:") == true)
        XCTAssertTrue(notice.diagnosticDetails?.contains("Latest state envelope:") == true)
    }

    func testLifecycleVerificationRejectsStalePreOperationGeneration() async throws {
        let baseline = Date().addingTimeInterval(5)
        let stale = baseline.addingTimeInterval(-1)
        let model = try makeLifecycleVerificationModel(
            action: .restart,
            initial: (.running, stale),
            observations: [(.running, baseline.addingTimeInterval(1), 0)],
            applyObservedAt: baseline,
            delays: [],
            observationStatusObservedAts: [stale]
        )

        await model.refreshRemote()
        try await beginConfirmedLifecycle(.restart, model: model)
        let operation = try await waitForLifecycleCompletion(in: model)

        XCTAssertEqual(operation.outcome, .unknown)
        XCTAssertTrue(operation.message.contains("Timed out"))
    }

    func testConcurrentPeriodicRefreshCannotOverwriteNewerLifecycleVerification() async throws {
        let baseline = Date().addingTimeInterval(5)
        let model = try makeLifecycleVerificationModel(
            action: .restart,
            initial: (.running, baseline.addingTimeInterval(-1)),
            observations: [
                (.stopped, baseline.addingTimeInterval(1), 0.25),
                (.running, baseline.addingTimeInterval(2), 0)
            ],
            applyObservedAt: baseline,
            delays: [.milliseconds(20)]
        )

        await model.refreshRemote()
        try await beginConfirmedLifecycle(.restart, model: model)
        try await Task.sleep(for: .milliseconds(50))
        await model.refreshRemote()
        let operation = try await waitForLifecycleCompletion(in: model)
        try await Task.sleep(for: .milliseconds(250))

        XCTAssertEqual(operation.outcome, .succeeded)
        XCTAssertEqual(model.operationStates["lifecycle:dev"]?.outcome, .succeeded)
        XCTAssertEqual(model.workspaces.first(where: { $0.id == .dev })?.state, .running)
    }

    func testLatePeriodicRefreshFailureCannotOverwriteNewerLifecycleVerification() async throws {
        let baseline = Date().addingTimeInterval(5)
        let model = try makeLifecycleVerificationModel(
            action: .restart,
            initial: (.running, baseline.addingTimeInterval(-1)),
            observations: [
                (.stopped, baseline.addingTimeInterval(1), 0.25),
                (.running, baseline.addingTimeInterval(2), 0)
            ],
            applyObservedAt: baseline,
            delays: [.milliseconds(20)],
            failingObservationIndices: [0]
        )

        await model.refreshRemote()
        try await beginConfirmedLifecycle(.restart, model: model)
        try await Task.sleep(for: .milliseconds(50))
        await model.refreshRemote()
        let operation = try await waitForLifecycleCompletion(in: model)
        try await Task.sleep(for: .milliseconds(250))

        XCTAssertEqual(operation.outcome, .succeeded)
        XCTAssertEqual(model.operationStates["lifecycle:dev"]?.outcome, .succeeded)
        XCTAssertEqual(model.workspaces.first(where: { $0.id == .dev })?.state, .running)
        XCTAssertEqual(model.workspaces.first(where: { $0.id == .dev })?.freshness, .fresh)
        XCTAssertNil(model.lastError)
    }

    func testRestartSuccessWithUnavailableStateRemainsNonErrorVerifying() async throws {
        let baseline = Date().addingTimeInterval(5)
        let model = try makeLifecycleVerificationModel(
            action: .restart,
            initial: (.running, baseline.addingTimeInterval(-1)),
            observations: [
                (.stopped, baseline.addingTimeInterval(1), 0.2),
                (.stopped, baseline.addingTimeInterval(2), 0.2)
            ],
            applyObservedAt: baseline,
            delays: [.milliseconds(50)],
            failingObservationIndices: [0, 1]
        )

        await model.refreshRemote()
        try await beginConfirmedLifecycle(.restart, model: model)
        for _ in 0..<80 {
            if model.operationStates["lifecycle:dev"]?.phase == .verifying { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let periodicRefresh = Task { await model.refreshRemote() }
        await periodicRefresh.value

        XCTAssertEqual(model.operationStates["lifecycle:dev"]?.outcome, .pending)
        XCTAssertEqual(model.workspaces.first(where: { $0.id == .dev })?.state, .restarting)
        XCTAssertNil(model.latestOperationFailure)
        XCTAssertNil(model.lastError)
        _ = try await waitForLifecycleCompletion(in: model)
    }

    func testFreshRunningAfterDeadlineReconcilesTimeoutAndClearsErrors() async throws {
        let baseline = Date().addingTimeInterval(5)
        let model = try makeLifecycleVerificationModel(
            action: .restart,
            initial: (.running, baseline.addingTimeInterval(-1)),
            observations: [
                (.stopped, baseline.addingTimeInterval(1), 0),
                (.running, baseline.addingTimeInterval(2), 0)
            ],
            applyObservedAt: baseline,
            delays: []
        )

        await model.refreshRemote()
        try await beginConfirmedLifecycle(.restart, model: model)
        let timedOut = try await waitForLifecycleCompletion(in: model)
        XCTAssertEqual(timedOut.outcome, .unknown)
        XCTAssertNotNil(model.latestOperationFailure)

        await model.refreshRemote()

        XCTAssertEqual(model.operationStates["lifecycle:dev"]?.outcome, .succeeded)
        XCTAssertEqual(model.workspaces.first(where: { $0.id == .dev })?.state, .running)
        XCTAssertNil(model.latestOperationFailure)
        XCTAssertNil(model.lastError)
    }

    func testPeriodicFailureAfterLifecycleTimeoutMarksStateStaleWithoutPreventingLaterReconciliation() async throws {
        let baseline = Date().addingTimeInterval(5)
        let model = try makeLifecycleVerificationModel(
            action: .restart,
            initial: (.running, baseline.addingTimeInterval(-1)),
            observations: [
                (.stopped, baseline.addingTimeInterval(1), 0),
                (.stopped, baseline.addingTimeInterval(2), 0),
                (.running, baseline.addingTimeInterval(3), 0)
            ],
            applyObservedAt: baseline,
            delays: [],
            failingObservationIndices: [1]
        )

        await model.refreshRemote()
        try await beginConfirmedLifecycle(.restart, model: model)
        let timedOut = try await waitForLifecycleCompletion(in: model)
        XCTAssertEqual(timedOut.outcome, .unknown)
        let timeoutNotice = try XCTUnwrap(model.latestOperationFailure)

        await model.refreshRemote()

        XCTAssertEqual(model.operationStates["lifecycle:dev"]?.id, timedOut.id)
        XCTAssertEqual(model.operationStates["lifecycle:dev"]?.outcome, .unknown)
        XCTAssertEqual(model.latestOperationFailure, timeoutNotice)
        XCTAssertEqual(model.workspaces.first(where: { $0.id == .dev })?.freshness, .stale)
        XCTAssertNotNil(model.lastError)
        XCTAssertTrue(model.activities.contains { $0.title == "Refresh failed" })

        await model.refreshRemote()

        XCTAssertEqual(model.operationStates["lifecycle:dev"]?.id, timedOut.id)
        XCTAssertEqual(model.operationStates["lifecycle:dev"]?.outcome, .succeeded)
        XCTAssertEqual(model.workspaces.first(where: { $0.id == .dev })?.state, .running)
        XCTAssertEqual(model.workspaces.first(where: { $0.id == .dev })?.freshness, .fresh)
        XCTAssertNil(model.latestOperationFailure)
        XCTAssertNil(model.lastError)
    }

    func testSameSecondPostCommandObservationUsesNewerAppGeneration() async throws {
        let baseline = Date(
            timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down) + 5
        )
        let model = try makeLifecycleVerificationModel(
            action: .restart,
            initial: (.running, baseline.addingTimeInterval(-1)),
            observations: [(.running, baseline, 0)],
            applyObservedAt: baseline,
            delays: []
        )

        await model.refreshRemote()
        try await beginConfirmedLifecycle(.restart, model: model)
        let operation = try await waitForLifecycleCompletion(in: model)

        XCTAssertEqual(operation.outcome, .succeeded)
        XCTAssertEqual(model.workspaces.first(where: { $0.id == .dev })?.state, .running)
        XCTAssertNil(model.latestOperationFailure)
    }

    func testPreCommandInFlightRunningCannotReconcileRestart() async throws {
        let baseline = Date().addingTimeInterval(5)
        let model = try makeLifecycleVerificationModel(
            action: .restart,
            initial: (.running, baseline.addingTimeInterval(-1)),
            observations: [
                (.running, baseline.addingTimeInterval(2), 0.1),
                (.stopped, baseline.addingTimeInterval(1), 0)
            ],
            applyObservedAt: baseline,
            delays: [],
            failingObservationIndices: [1],
            applyDelay: 0.3
        )

        await model.refreshRemote()
        let preCommandRefresh = Task { await model.refreshRemote() }
        try await Task.sleep(for: .milliseconds(30))
        try await beginConfirmedLifecycle(.restart, model: model)
        let operation = try await waitForLifecycleCompletion(in: model)
        await preCommandRefresh.value

        XCTAssertEqual(operation.outcome, .unknown)
        XCTAssertEqual(model.operationStates["lifecycle:dev"]?.outcome, .unknown)
        XCTAssertEqual(model.workspaces.first(where: { $0.id == .dev })?.state, .restarting)
        XCTAssertNotEqual(model.workspaces.first(where: { $0.id == .dev })?.state, .running)
        XCTAssertNotNil(model.latestOperationFailure)
    }

    func testCancelledOlderRefreshCannotOverwriteNewerRestartSuccess() async throws {
        let baseline = Date().addingTimeInterval(5)
        let model = try makeLifecycleVerificationModel(
            action: .restart,
            initial: (.running, baseline.addingTimeInterval(-1)),
            observations: [
                (.stopped, baseline.addingTimeInterval(1), 0.25),
                (.running, baseline.addingTimeInterval(2), 0)
            ],
            applyObservedAt: baseline,
            delays: []
        )

        await model.refreshRemote()
        let olderRefresh = Task { await model.refreshRemote() }
        try await Task.sleep(for: .milliseconds(30))
        try await beginConfirmedLifecycle(.restart, model: model)
        let operation = try await waitForLifecycleCompletion(in: model)
        olderRefresh.cancel()
        await olderRefresh.value

        XCTAssertEqual(operation.outcome, .succeeded)
        XCTAssertEqual(model.operationStates["lifecycle:dev"]?.outcome, .succeeded)
        XCTAssertEqual(model.workspaces.first(where: { $0.id == .dev })?.state, .running)
        XCTAssertNil(model.latestOperationFailure)
        XCTAssertNil(model.lastError)
    }

    func testPreCommandFailureCannotMarkTimedOutRestartStateStale() async throws {
        let baseline = Date().addingTimeInterval(5)
        let model = try makeLifecycleVerificationModel(
            action: .restart,
            initial: (.running, baseline.addingTimeInterval(-1)),
            observations: [
                (.stopped, baseline.addingTimeInterval(1), 0.3),
                (.stopped, baseline.addingTimeInterval(2), 0),
                (.running, baseline.addingTimeInterval(3), 0)
            ],
            applyObservedAt: baseline,
            delays: [],
            failingObservationIndices: [0, 1],
            applyDelay: 0.1
        )

        await model.refreshRemote()
        let preCommandRefresh = Task { await model.refreshRemote() }
        try await Task.sleep(for: .milliseconds(30))
        try await beginConfirmedLifecycle(.restart, model: model)
        let timedOut = try await waitForLifecycleCompletion(in: model)
        let timeoutNotice = try XCTUnwrap(model.latestOperationFailure)
        await preCommandRefresh.value

        XCTAssertEqual(timedOut.outcome, .unknown)
        XCTAssertEqual(model.latestOperationFailure, timeoutNotice)
        XCTAssertEqual(model.workspaces.first(where: { $0.id == .dev })?.freshness, .fresh)
        XCTAssertNil(model.lastError)
        XCTAssertFalse(model.activities.contains { $0.title == "Refresh failed" })

        await model.refreshRemote()

        XCTAssertEqual(model.operationStates["lifecycle:dev"]?.outcome, .succeeded)
        XCTAssertEqual(model.workspaces.first(where: { $0.id == .dev })?.state, .running)
        XCTAssertNil(model.latestOperationFailure)
    }

    func testReconcilePendingRestartEventuallyAcceptsFreshRunningState() async throws {
        let baseline = Date().addingTimeInterval(5)
        let model = try makeLifecycleVerificationModel(
            action: .restart,
            initial: (.running, baseline.addingTimeInterval(-1)),
            observations: [
                (.stopped, baseline.addingTimeInterval(1), 0),
                (.running, baseline.addingTimeInterval(2), 0)
            ],
            applyObservedAt: baseline,
            delays: [.milliseconds(20)],
            applyFailure: MSWProtocolError(
                code: "MSW_RECONCILE_PENDING",
                message: "The lifecycle operation completed without a matching fresh state observation.",
                recovery: "Refresh after checking the workspace runtime; MSW did not claim final state.",
                workspace: "dev",
                retryable: true
            )
        )

        await model.refreshRemote()
        try await beginConfirmedLifecycle(.restart, model: model)
        let operation = try await waitForLifecycleCompletion(in: model)

        XCTAssertEqual(operation.outcome, .succeeded)
        XCTAssertEqual(model.workspaces.first(where: { $0.id == .dev })?.state, .running)
        XCTAssertNil(model.latestOperationFailure)
        XCTAssertNil(model.lastError)
        XCTAssertFalse(model.activities.contains { $0.title == "Restart failed" })
    }

    func testUnreconciledReceiptEventuallyAcceptsFreshRunningState() async throws {
        let baseline = Date().addingTimeInterval(5)
        let model = try makeLifecycleVerificationModel(
            action: .restart,
            initial: (.running, baseline.addingTimeInterval(-1)),
            observations: [
                (.stopped, baseline.addingTimeInterval(1), 0),
                (.running, baseline.addingTimeInterval(2), 0)
            ],
            applyObservedAt: baseline,
            delays: [.milliseconds(20)],
            applyReconciled: false
        )

        await model.refreshRemote()
        try await beginConfirmedLifecycle(.restart, model: model)
        let operation = try await waitForLifecycleCompletion(in: model)

        XCTAssertEqual(operation.outcome, .succeeded)
        XCTAssertEqual(model.workspaces.first(where: { $0.id == .dev })?.state, .running)
        XCTAssertNil(model.latestOperationFailure)
        XCTAssertFalse(model.activities.contains { $0.title == "Restart failed" })
    }

    func testGenuineRestartCommandFailureStaysFailed() async throws {
        let baseline = Date().addingTimeInterval(5)
        let model = try makeLifecycleVerificationModel(
            action: .restart,
            initial: (.running, baseline.addingTimeInterval(-1)),
            observations: [(.running, baseline.addingTimeInterval(1), 0)],
            applyObservedAt: baseline,
            delays: [],
            applyFailure: MSWProtocolError(
                code: "MSW_OPERATION_FAILED",
                message: "The restart command failed.",
                recovery: "Repair the runtime and retry.",
                workspace: "dev",
                retryable: true
            )
        )

        await model.refreshRemote()
        try await beginConfirmedLifecycle(.restart, model: model)
        let operation = try await waitForLifecycleCompletion(in: model)

        XCTAssertEqual(operation.outcome, .failed)
        XCTAssertEqual(model.latestOperationFailure?.reason, "The restart command failed.")
    }

    func testRepairInvalidatesResolutionAndSelectsOnlyActivatedRuntime() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-managed-runtime-resolution-\(UUID().uuidString)", isDirectory: true)
        let legacy = temporary.appendingPathComponent(".local/bin/msw")
        let managedRoot = temporary.appendingPathComponent("managed-toolchain", isDirectory: true)
        try FileManager.default.createDirectory(
            at: legacy.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        try Data("#!/bin/sh\nprintf 'external fake must not run\\n'\nexit 99\n".utf8).write(to: legacy)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: legacy.path)

        let runner = MSWCommandRunner(configuration: .init(
            homeDirectory: temporary,
            managedToolchainRoot: managedRoot
        ))
        let beforeRepair = await runner.mswResolution(forceRefresh: true)
        XCTAssertNil(beforeRepair.selected)

        let bundledRoot = try XCTUnwrap(ToolchainLayout.bundledRoot())
        _ = try await ToolchainInstaller(
            bundledRoot: bundledRoot,
            installationRoot: managedRoot
        ).activate()
        await runner.invalidateMSWResolution()

        let afterRepair = await runner.mswResolution()
        XCTAssertEqual(
            afterRepair.selected?.standardizedFileURL,
            managedRoot.appendingPathComponent("current/bin/msw").standardizedFileURL
        )
    }

    func testSupersededRuntimeResolutionCannotOverwriteRepairedRuntimeCache() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-runtime-resolution-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }
        let executable = temporary.appendingPathComponent("msw")
        let firstHandshakeStarted = temporary.appendingPathComponent("first-handshake-started")
        let incompatibleHandshake = protocolCompatibleHandshake.replacingOccurrences(
            of: #""protocolVersion":1,"mswVersion""#,
            with: #""protocolVersion":2,"mswVersion""#
        )
        let script = """
        #!/bin/sh
        if (set -C; : > "\(firstHandshakeStarted.path)") 2>/dev/null; then
            /bin/sleep 1
            printf '%s\\n' '\(incompatibleHandshake)'
        else
            printf '%s\\n' '\(protocolCompatibleHandshake)'
        fi
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let runner = MSWCommandRunner(configuration: .init(
            homeDirectory: temporary,
            testMSWExecutable: executable
        ))
        let staleResolution = Task { await runner.mswResolution(forceRefresh: true) }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: firstHandshakeStarted.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstHandshakeStarted.path))

        await runner.invalidateMSWResolution()
        let repairedResolution = await runner.mswResolution(forceRefresh: true)
        XCTAssertEqual(repairedResolution.selected?.standardizedFileURL, executable.standardizedFileURL)
        let supersededResolution = await staleResolution.value
        XCTAssertNil(supersededResolution.selected)

        let cachedResolution = await runner.mswResolution()
        XCTAssertEqual(
            cachedResolution.selected?.standardizedFileURL,
            executable.standardizedFileURL,
            "A superseded pre-repair handshake must not replace the repaired runtime cache"
        )
    }

    func testUnknownQuarantineSnapshotAllowsStopButDisablesOtherLifecycleActions() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-unknown-quarantine-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let snapshots = Workspace.ID.fixtureDefaults.map { id in
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
            testMSWExecutable: executable
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
        XCTAssertEqual(model.workspaces.first(where: { $0.id == .dev })?.state, .quarantined)
        XCTAssertFalse(model.operationStates.values.contains {
            $0.kind == .lifecycle && $0.workspace == "dev" && $0.outcome == .pending
        })
        XCTAssertNil(model.lastError, "Stop plan error: \(model.lastError ?? "nil")")

        model.start(.dev)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(model.lastError?.contains("quarantined") == true)
        XCTAssertNotNil(model.pendingLifecyclePlan)
        model.cancelPendingLifecycle()
    }

    func testFailedStartPersistsNoticeAndDetailedActivityAfterRefresh() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-start-failure-notice-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let stateURL = temporary.appendingPathComponent("state.json")
        try encoder.encode(
            makeTestStateEnvelope(devLifecycle: .stopped, devQuarantine: .clear)
        ).write(to: stateURL)

        let planURL = temporary.appendingPathComponent("plan.json")
        try encoder.encode(
            MSWEnvelope(
                schemaVersion: 1,
                requestId: "plan-start",
                ok: true,
                command: "plan",
                observedAt: Date(),
                result: MSWLifecyclePlan(
                    planId: "plan-start",
                    action: "start",
                    workspace: "dev",
                    expiresAt: Date().addingTimeInterval(300),
                    confirmationPhrase: "START dev",
                    effects: "Starting dev."
                )
            )
        ).write(to: planURL)

        let executable = temporary.appendingPathComponent("msw")
        let script = """
        #!/bin/sh
        if [ "$1" = "app" ] && [ "$2" = "handshake" ]; then
            printf '%s\n' '\(protocolCompatibleHandshake)'
        elif [ "$1" = "app" ] && [ "$2" = "state" ]; then
            /bin/cat "\(stateURL.path)"
        elif [ "$1" = "app" ] && [ "$2" = "plan" ]; then
            /bin/cat "\(planURL.path)"
        elif [ "$1" = "app" ] && [ "$2" = "apply" ]; then
            printf '%s\n' 'The dev workspace could not start.' 'failed to mount /dev/vdc at /workspace as ext4: EINVAL' >&2
            exit 7
        else
            exit 64
        fi
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let runner = MSWCommandRunner(configuration: .init(
            homeDirectory: temporary,
            testMSWExecutable: executable
        ))
        let client = MSWClient(runner: runner)
        let model = AppModel(
            client: client,
            operationCoordinator: MSWOperationCoordinator(client: client)
        )

        await model.refreshRemote()
        model.start(.dev)
        for _ in 0..<80 {
            if model.latestOperationFailure != nil,
               model.workspaces.first(where: { $0.id == .dev })?.state == .stopped {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }

        let notice = try XCTUnwrap(model.latestOperationFailure)
        XCTAssertEqual(notice.title, "Start failed")
        XCTAssertEqual(notice.workspace, .dev)
        XCTAssertEqual(notice.reason, "The dev workspace could not start.")
        XCTAssertEqual(notice.recovery, "Run Diagnostics and Maintenance before retrying start.")
        XCTAssertEqual(
            notice.diagnosticDetails,
            "failed to mount /dev/vdc at /workspace as ext4: EINVAL"
        )
        XCTAssertEqual(model.health.title, "Start failed")
        XCTAssertNil(model.lastError)
        XCTAssertTrue(model.activities.contains {
            $0.kind == .failure &&
                $0.workspace == "dev" &&
                $0.detail?.contains("The dev workspace could not start.") == true
        })

        model.start(.dev)
        XCTAssertNil(
            model.latestOperationFailure,
            "A retry must hide the previous details before an identical failure arrives."
        )
        for _ in 0..<80 {
            if model.latestOperationFailure != nil,
               model.workspaces.first(where: { $0.id == .dev })?.state == .stopped {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(model.latestOperationFailure, notice)
    }

    func testLifecycleFailureNoticeKeepsConciseSummaryAndBoundedFinalDiagnostics() throws {
        let finalLine = "failed to mount /dev/vdc at /workspace as ext4: EINVAL"
        let notice = MSWOperationFailureNotice(
            action: "start",
            title: "Start failed",
            reason: "The dev workspace could not start.\nignored duplicate summary",
            recovery: "Inspect the named workspace volume.",
            workspace: .dev,
            diagnosticDetails: String(repeating: "earlier diagnostics\n", count: 8_000) + finalLine
        )

        XCTAssertEqual(notice.reason, "The dev workspace could not start.")
        let details = try XCTUnwrap(notice.diagnosticDetails)
        XCTAssertLessThanOrEqual(Data(details.utf8).count, MSWOperationFailureNotice.diagnosticLimit)
        XCTAssertTrue(details.hasSuffix(finalLine))
        XCTAssertEqual(details.components(separatedBy: "The dev workspace could not start.").count, 1)

        let unicodeNotice = MSWOperationFailureNotice(
            action: "start",
            title: "Start failed",
            reason: "Short summary.",
            recovery: "Inspect storage.",
            workspace: .dev,
            diagnosticDetails: String(repeating: "🧱", count: MSWOperationFailureNotice.diagnosticLimit)
        )
        let unicodeDetails = try XCTUnwrap(unicodeNotice.diagnosticDetails)
        XCTAssertLessThanOrEqual(
            Data(unicodeDetails.utf8).count,
            MSWOperationFailureNotice.diagnosticLimit
        )
        XCTAssertFalse(unicodeDetails.contains("�"))
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
            testMSWExecutable: executable
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
            testMSWExecutable: executable
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
        XCTAssertEqual(model.workspaces.first(where: { $0.id == .dev })?.state, .running)
        XCTAssertFalse(model.operationStates.values.contains {
            $0.kind == .lifecycle && $0.workspace == "dev" && $0.outcome == .pending
        })

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
            testMSWExecutable: executable
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
            additionalSearchPaths: [executable],
            testMSWExecutable: executable
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
        XCTAssertNil(
            finalState.workspaceConfigurations,
            "A failed setup must not publish an unapplied configuration or unlock GitHub."
        )
        XCTAssertFalse(SetupView.workspaceConfigurationIsApplied(
            SetupWorkspaceConfiguration.defaults,
            persisted: finalState.workspaceConfigurations
        ))
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
        let bootstrapArgumentsURL = temporary.appendingPathComponent("bootstrap-arguments.txt")
        let bootstrapInputURL = temporary.appendingPathComponent("bootstrap-input.json")
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
            printf '%s\\n' "$@" > "\(bootstrapArgumentsURL.path)"
            /usr/bin/tee "\(bootstrapInputURL.path)" > "\(configDirectory.appendingPathComponent("workspaces.json").path)"
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
            testMSWExecutable: executable
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
            userIntegration: AvailableUserIntegration(),
            freeDiskBytes: { Int64(20 * 1_024 * 1_024 * 1_024) }
        )

        let defaults = SetupWorkspaceConfiguration.defaults
        let configurations = [
            SetupWorkspaceConfiguration(
                name: "development", cpus: 12, maxCPUs: 12,
                memoryGiB: 48, maxMemoryGiB: 48,
                workspaceStorageGiB: 120, runtimeStorageGiB: 100
            ),
            SetupWorkspaceConfiguration(
                name: defaults[2].name, cpus: 4, maxCPUs: 8,
                memoryGiB: 16, maxMemoryGiB: 32,
                workspaceStorageGiB: 80, runtimeStorageGiB: 60
            ),
            SetupWorkspaceConfiguration(
                name: "lab", cpus: 6, maxCPUs: 12,
                memoryGiB: 32, maxMemoryGiB: 48,
                workspaceStorageGiB: 100, runtimeStorageGiB: 80
            )
        ]
        let result = try await coordinator.run(workspaceConfigurations: configurations)

        XCTAssertEqual(result.phase, MSWBootstrapState.Phase.complete.rawValue)
        let ensureAliasCount = await hostAgent.ensureAliasInvocationCount
        let installRecordsCount = await hostAgent.installRecordsInvocationCount
        let inspectRequests = await hostAgent.inspectRequests
        XCTAssertEqual(ensureAliasCount, 1)
        XCTAssertEqual(installRecordsCount, 1)
        XCTAssertEqual(
            inspectRequests.last?.map(\.hostname),
            ["development.msw.test", "personal.msw.test", "lab.msw.test"],
            "Post-repair verification must inspect the selected configuration before bootstrap can unlock GitHub."
        )
        let finalState = await coordinator.state()
        XCTAssertEqual(finalState.phase, .complete)
        XCTAssertTrue(finalState.completedPhases.contains(.hostIntegration))
        XCTAssertTrue(finalState.completedPhases.contains(.workspaces))
        XCTAssertEqual(
            finalState.workspaceConfigurations?.map(\.name),
            ["development", "personal", "lab"]
        )
        XCTAssertEqual(
            try String(contentsOf: bootstrapArgumentsURL, encoding: .utf8)
                .split(whereSeparator: \.isNewline).map(String.init),
            ["app", "bootstrap", "--resume", "--workspace-config-fd", "0", "--format", "json"]
        )
        let durations = try XCTUnwrap(finalState.phaseDurations)
        XCTAssertEqual(
            Set(durations.keys),
            ["toolchain", "preflight", "hostIntegration", "workspaces"]
        )
        XCTAssertTrue(durations.values.allSatisfy { $0.isFinite && $0 >= 0 })
        let persistedStore = BootstrapStateStore(
            url: temporary.appendingPathComponent("bootstrap-state.json")
        )
        let persisted = await persistedStore.load()
        XCTAssertEqual(
            Set((persisted.phaseDurations ?? [:]).keys),
            Set(durations.keys),
            "Per-phase timings must survive persistence so a resumed setup can show them."
        )
        let boundary = try JSONDecoder().decode(
            MSWBootstrapConfiguration.self,
            from: Data(contentsOf: bootstrapInputURL)
        )
        XCTAssertEqual(boundary, MSWBootstrapConfiguration(configurations))
        XCTAssertEqual(boundary.workspaces.map(\.name), ["development", "personal", "lab"])
        XCTAssertEqual(boundary.workspaces[1].cpu, 4)
        XCTAssertEqual(boundary.workspaces[1].cpuCeiling, 8)
        XCTAssertEqual(boundary.workspaces[1].workspaceStorageGiB, 80)
        XCTAssertEqual(boundary.workspaces[1].runtimeStorageGiB, 60)
    }
    func testBootstrapInvalidRequestPreservesTypedCLIError() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-bootstrap-mismatch-test-\(UUID().uuidString)", isDirectory: true)
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

        let invalidRequest = #"""
        {"schemaVersion":1,"requestId":"bootstrap-invalid","ok":false,"command":"bootstrap","observedAt":"2026-08-08T00:00:00Z","result":null,"warnings":[],"error":{"code":"MSW_INVALID_REQUEST","message":"The requested MSW Monitor command has invalid arguments.","recovery":"See 'msw app help' for the typed command contract.","workspace":null,"retryable":false}}
        """#
        let handshakeURL = temporary.appendingPathComponent("handshake.json")
        let invalidURL = temporary.appendingPathComponent("bootstrap-invalid.json")
        try Data(protocolCompatibleHandshake.utf8).write(to: handshakeURL)
        try Data(invalidRequest.utf8).write(to: invalidURL)

        let executable = mswBin.appendingPathComponent("msw")
        let script = """
        #!/bin/sh
        if [ "$1" = "app" ] && [ "$2" = "handshake" ]; then
            /bin/cat "\(handshakeURL.path)"
        elif [ "$1" = "app" ] && [ "$2" = "bootstrap" ]; then
            /bin/cat "\(invalidURL.path)"
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
            testMSWExecutable: executable
        ))
        let coordinator = BootstrapCoordinator(
            client: MSWClient(runner: runner),
            runner: runner,
            stateStore: BootstrapStateStore(
                url: temporary.appendingPathComponent("bootstrap-state.json")
            ),
            hostAgent: RecordingHostAgent(),
            hostService: EnabledHostService(),
            userIntegration: AvailableUserIntegration(),
            freeDiskBytes: { Int64(20 * 1_024 * 1_024 * 1_024) }
        )

        do {
            _ = try await coordinator.run(workspaceConfigurations: SetupWorkspaceConfiguration.defaults)
            XCTFail("Expected MSW_INVALID_REQUEST to fail setup.")
        } catch let error as MSWClientError {
            guard case .protocolFailure(let protocolError) = error else {
                return XCTFail("Unexpected client error: \(error)")
            }
            XCTAssertEqual(protocolError.code, "MSW_INVALID_REQUEST")
        } catch {
            XCTFail("Unexpected bootstrap error: \(error)")
        }

        let finalState = await coordinator.state()
        XCTAssertTrue(finalState.lastError?.contains("MSW_INVALID_REQUEST") == true)
        XCTAssertNil(
            finalState.workspaceConfigurations,
            "A rejected bootstrap must not publish an unapplied configuration."
        )
    }

    func testProtocolErrorDescriptionIncludesRecoveryAndCode() {
        let error = MSWProtocolError(
            code: "MSW_INVALID_REQUEST",
            message: "The requested MSW Monitor command has invalid arguments.",
            recovery: "See 'msw app help' for the typed command contract.",
            workspace: nil,
            retryable: false
        )
        let description = error.localizedDescription
        XCTAssertTrue(description.contains("The requested MSW Monitor command has invalid arguments."))
        XCTAssertTrue(description.contains("See 'msw app help' for the typed command contract."))
        XCTAssertTrue(description.contains("MSW_INVALID_REQUEST"))
        let withoutRecovery = MSWProtocolError(
            code: "MSW_RUNTIME_UNAVAILABLE",
            message: "runtime unavailable",
            recovery: nil,
            workspace: nil,
            retryable: true
        )
        XCTAssertEqual(withoutRecovery.localizedDescription, "runtime unavailable (MSW error code: MSW_RUNTIME_UNAVAILABLE.)")
    }

    func testRealBootstrapReconnectReadbackPrecedesGitHubEntry() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-bootstrap-reconnect-test-\(UUID().uuidString)", isDirectory: true)
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

        let reconnectResponse = #"{"schemaVersion":1,"requestId":"bootstrap-reconnect","ok":false,"command":"bootstrap","observedAt":"2026-08-23T00:00:00Z","result":null,"warnings":[],"error":{"code":"MSW_GITHUB_RECONNECT_REQUIRED","message":"GitHub is configured for development, but its credential is unavailable.","recovery":"Reconnect development.","workspace":"development","retryable":true}}"#
        let executable = mswBin.appendingPathComponent("msw")
        let script = """
        #!/bin/sh
        if [ "$1" = "app" ] && [ "$2" = "handshake" ]; then
            printf '%s\\n' '\(protocolCompatibleHandshake)'
        elif [ "$1" = "app" ] && [ "$2" = "bootstrap" ]; then
            /bin/cat > "\(configDirectory.appendingPathComponent("workspaces.json").path)"
            printf '%s\\n' '\(reconnectResponse)'
            exit 69
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
            testMSWExecutable: executable
        ))
        let coordinator = BootstrapCoordinator(
            client: MSWClient(runner: runner),
            runner: runner,
            stateStore: BootstrapStateStore(
                url: temporary.appendingPathComponent("bootstrap-state.json")
            ),
            hostAgent: RecordingHostAgent(),
            hostService: EnabledHostService(),
            userIntegration: AvailableUserIntegration(),
            freeDiskBytes: { Int64(20 * 1_024 * 1_024 * 1_024) }
        )
        let selected = [
            SetupWorkspaceConfiguration(
                name: "development", cpus: 8, maxCPUs: 12,
                memoryGiB: 32, maxMemoryGiB: 48,
                workspaceStorageGiB: 120, runtimeStorageGiB: 100
            ),
            SetupWorkspaceConfiguration.defaults[2],
            SetupWorkspaceConfiguration(
                name: "lab", cpus: 4, maxCPUs: 12,
                memoryGiB: 16, maxMemoryGiB: 32,
                workspaceStorageGiB: 60, runtimeStorageGiB: 60
            )
        ]

        do {
            _ = try await coordinator.run(workspaceConfigurations: selected)
            XCTFail("Expected reconnect to interrupt deep verification.")
        } catch let error as MSWClientError {
            guard case .protocolFailure(let protocolError) = error else {
                return XCTFail("Expected typed reconnect, got \(error).")
            }
            XCTAssertEqual(protocolError.workspace, "development")
        }

        let state = await coordinator.state()
        XCTAssertEqual(state.phase, .github)
        XCTAssertEqual(state.reconnectWorkspace, "development")
        XCTAssertEqual(state.workspaceConfigurations?.map(\.name), ["development", "personal", "lab"])
        XCTAssertTrue(SetupView.workspaceConfigurationIsApplied(
            selected,
            persisted: state.workspaceConfigurations
        ))
    }

    @MainActor
    func testReconnectPublishesAppliedConfigurationBeforeGitHubEntry() async throws {
        let coordinator = MSWBootstrapUITestStub(failureWorkspace: "dev")
        var configurations = SetupWorkspaceConfiguration.defaults
        configurations[0].name = "development"
        configurations[0].memoryGiB = 16

        do {
            _ = try await coordinator.run(workspaceConfigurations: configurations)
            XCTFail("Expected reconnect to interrupt deep bootstrap verification.")
        } catch let error as MSWClientError {
            guard case .protocolFailure(let protocolError) = error else {
                return XCTFail("Expected a typed reconnect error, got \(error).")
            }
            XCTAssertEqual(protocolError.code, "MSW_GITHUB_RECONNECT_REQUIRED")
        }
        let state = await coordinator.state()

        XCTAssertEqual(state.phase, .github)
        XCTAssertEqual(state.reconnectWorkspace, "dev")
        XCTAssertEqual(state.workspaceConfigurations, configurations)
        XCTAssertTrue(SetupView.workspaceConfigurationIsApplied(
            configurations,
            persisted: state.workspaceConfigurations
        ))
    }

    func testConnectCoordinatorReloadScopesRetainedTargetsToAppliedConfiguration() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-connect-target-reload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }
        let broker = try CredentialBroker(
            keychain: InMemoryConnectKeychain(),
            metadataURL: temporary.appendingPathComponent("credentials.json"),
            keychainService: "test-target-reload-\(UUID().uuidString)"
        )
        for workspace in ["dev", "personal"] {
            try await broker.storeScopedCredential(
                ScopedInstallationCredential(
                    grantID: UUID(),
                    accessToken: "ghs_target_reload_\(workspace)",
                    accessExpiresAt: Date().addingTimeInterval(1_800),
                    generation: 1
                ),
                workspace: workspace,
                accessMode: "read-only",
                verificationRepository: "acme/one",
                installationID: 42,
                role: .guest,
                accountLogin: "octocat",
                owner: "acme",
                repositoryIDs: [7],
                repositoryNames: ["acme/one"]
            )
        }
        let coordinator = GitHubAuthorizationCoordinator(
            broker: broker,
            journalURL: temporary.appendingPathComponent("authorization-journal.json")
        )
        let selected = [
            SetupWorkspaceConfiguration(
                name: "development", cpus: 8, maxCPUs: 12,
                memoryGiB: 32, maxMemoryGiB: 48,
                workspaceStorageGiB: 120, runtimeStorageGiB: 100
            ),
            SetupWorkspaceConfiguration.defaults[2],
            SetupWorkspaceConfiguration(
                name: "lab", cpus: 4, maxCPUs: 12,
                memoryGiB: 16, maxMemoryGiB: 32,
                workspaceStorageGiB: 60, runtimeStorageGiB: 60
            )
        ]

        try await coordinator.reloadWorkspaceConfiguration(selected)
        let visible = await coordinator.retainedMetadata()

        XCTAssertEqual(visible.map(\.workspace), ["personal"])
        XCTAssertFalse(visible.contains { ["dev", "playgrounds"].contains($0.workspace) })
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

        let extendedEnvelope = Data(
            #"{"schemaVersion":1,"requestId":"req","ok":true,"command":"handshake","observedAt":"2026-08-08T00:00:00Z","result":"ok","warnings":[],"error":null,"futureField":true}"#.utf8
        )
        XCTAssertThrowsError(
            try MSWProtocolDecoder.decodeEnvelope(extendedEnvelope, as: String.self, expectedCommand: "handshake")
        ) { error in
            XCTAssertEqual(error as? MSWClientError, .malformedJSON(command: "handshake"))
        }

        let nullWarnings = Data(
            #"{"schemaVersion":1,"requestId":"req","ok":true,"command":"handshake","observedAt":"2026-08-08T00:00:00Z","result":"ok","warnings":null,"error":null}"#.utf8
        )
        XCTAssertThrowsError(
            try MSWProtocolDecoder.decodeEnvelope(nullWarnings, as: String.self, expectedCommand: "handshake")
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


    func testCommandRunnerIgnoresEveryFormerExternalMSWCandidate() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-protocol-resolution-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let handshake = protocolCompatibleHandshake.replacingOccurrences(of: "test-handshake", with: "compatible")
        let formerCandidates = [
            "configured/msw",
            ".local/bin/msw",
            "homebrew/bin/msw",
            "usr-local/bin/msw",
            "source-checkout/bin/msw",
            "Library/Application Support/MSW Monitor/Toolchains/current/bin/msw",
            "path-entry/bin/msw"
        ].map { temporary.appendingPathComponent($0) }
        for candidate in formerCandidates {
            try FileManager.default.createDirectory(
                at: candidate.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("#!/bin/sh\nprintf '%s\\n' '\(handshake)'\n".utf8).write(to: candidate)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: candidate.path)
        }

        let runner = MSWCommandRunner(configuration: .init(
            homeDirectory: temporary,
            additionalSearchPaths: formerCandidates
        ))
        let resolution = await runner.mswResolution()
        let namedResolution = await runner.resolveExecutable(named: "msw")

        XCTAssertNil(resolution.selected)
        XCTAssertNil(namedResolution)
    }

    func testCommandRunnerRejectsAHandshakeThatIsNotTheExactSchema() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-protocol-repair-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let future = temporary.appendingPathComponent("msw")
        let extendedHandshake = protocolCompatibleHandshake.replacingOccurrences(
            of: #""workspaceCount":3"#,
            with: #""workspaceCount":3,"futureField":true"#
        )
        try Data("#!/bin/sh\nprintf '%s\\n' '\(extendedHandshake)'\n".utf8).write(to: future)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: future.path)
        let runner = MSWCommandRunner(configuration: .init(
            homeDirectory: temporary,
            testMSWExecutable: future
        ))

        let resolution = await runner.mswResolution()
        XCTAssertNil(resolution.selected)
    }

    func testUnsignedDevelopmentBundleExplainsHostServiceRegistrationFailure() {
        XCTAssertEqual(
            MSWHostPackagingInspector.inspect(bundleURL: Bundle.main.bundleURL),
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

        try await authorization.repair(records: MSWWorkspaceNetwork.fixtureRecords)

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

    func testCommandRunnerReadsOptionalGitIdentity() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-git-identity-\(UUID().uuidString)", isDirectory: true)
        let git = temporary.appendingPathComponent("bin/git")
        try FileManager.default.createDirectory(
            at: git.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let script = """
        #!/bin/sh
        [ "$1" = config ] && [ "$2" = --get ] || exit 2
        case "$3" in
          user.name) printf '%s\n' 'Taylor Example' ;;
          user.email) printf '%s\n' 'taylor@example.test' ;;
          *) exit 1 ;;
        esac
        """
        try Data(script.utf8).write(to: git)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: git.path)

        let runner = MSWCommandRunner(configuration: .init(
            homeDirectory: temporary,
            additionalSearchPaths: [git]
        ))
        let identity = await runner.gitIdentityConfiguration()

        XCTAssertEqual(identity, GitIdentityConfiguration(
            name: "Taylor Example",
            email: "taylor@example.test"
        ))
    }

    func testCommandRunnerTreatsMissingGitIdentityAsOptional() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-git-identity-missing-\(UUID().uuidString)", isDirectory: true)
        let git = temporary.appendingPathComponent("bin/git")
        try FileManager.default.createDirectory(
            at: git.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: git)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: git.path)

        let runner = MSWCommandRunner(configuration: .init(
            homeDirectory: temporary,
            additionalSearchPaths: [git]
        ))

        let identity = await runner.gitIdentityConfiguration()
        XCTAssertNil(identity)
    }

    func testGitIdentityPrefillNeverOverwritesUserEdits() {
        let configuration = GitIdentityConfiguration(
            name: "Configured Name",
            email: "configured@example.test"
        )

        XCTAssertEqual(
            configuration.prefilling(
                name: "Typed Name",
                email: "",
                nameWasEdited: true,
                emailWasEdited: false
            ),
            GitIdentityPrefill(
                name: "Typed Name",
                email: "configured@example.test",
                didPrefill: true
            )
        )
        XCTAssertEqual(
            configuration.prefilling(
                name: "",
                email: "",
                nameWasEdited: true,
                emailWasEdited: true
            ),
            GitIdentityPrefill(name: "", email: "", didPrefill: false)
        )
    }

    func testUserIntegrationUsesOnlyResolvedCoupledRuntime() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-source-setup-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let hostRepairMarker = root.appendingPathComponent("host-repair-marker")
        let launcher = root.appendingPathComponent("msw")
        let script = """
        #!/bin/sh
        set -eu
        if [ "$1" = app ] && [ "$2" = handshake ]; then
            printf '%s\\n' '\(protocolCompatibleHandshake)'
        else
            printf '%s %s %s\\n' "$1" "$2" "${MSW_SKIP_HOST_REPAIR:-unset}" > "\(hostRepairMarker.path)"
        fi
        """
        try Data(script.utf8).write(to: launcher)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        let service = MSWUserIntegrationService(runner: MSWCommandRunner(configuration: .init(
            homeDirectory: root,
            testMSWExecutable: launcher
        )))

        try await service.configureUserIntegrationIfAvailable()
        XCTAssertEqual(try String(contentsOf: hostRepairMarker, encoding: .utf8), "host repair 1\n")
    }

    func testRuntimeRepairFailureKeepsConciseSummaryAndBoundedFinalDiagnostics() {
        let finalError = "Final fixture error: dependency installation failed."
        let failure = RuntimeRepairFailure(
            diagnosticDetails: String(repeating: "fixture transcript\n", count: 30_000) + finalError
        )

        XCTAssertEqual(failure.localizedDescription, RuntimeRepairFailure.summary)
        XCTAssertFalse(failure.localizedDescription.contains("fixture transcript"))
        XCTAssertNotNil(failure.diagnosticDetails)
        XCTAssertLessThanOrEqual(
            Data((failure.diagnosticDetails ?? "").utf8).count,
            RuntimeRepairFailure.diagnosticLimit
        )
        XCTAssertTrue(failure.diagnosticDetails?.hasSuffix(finalError) == true)
    }

    func testRuntimeRepairVerifiesExactActivatedCLIWithoutRuntimePrerequisites() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-runtime-repair-exact-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let runner = MSWCommandRunner(configuration: .init(homeDirectory: temporary))
        let coordinator = BootstrapCoordinator(
            client: MSWClient(runner: runner),
            runner: runner,
            stateStore: BootstrapStateStore(url: temporary.appendingPathComponent("bootstrap-state.json")),
            hostService: EnabledHostService()
        )

        try await coordinator.repairRuntime()

        let selected = await runner.mswResolution().selected?.standardizedFileURL
        let expected = ToolchainLayout.managedRoot(homeDirectory: temporary)
            .appendingPathComponent("current/bin/msw")
            .standardizedFileURL
        XCTAssertEqual(selected, expected)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: temporary.appendingPathComponent(".config/msw/config.sh").path
        ))
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

    func testBundledToolchainManifestHashesPermissionsAndHandshakeAreExact() throws {
        let bundledRoot = try XCTUnwrap(ToolchainLayout.bundledRoot())
        let validated = try ToolchainValidator.validateBundled(root: bundledRoot)
        try ToolchainValidator.verifyHandshake(validated)

        XCTAssertEqual(validated.manifest.schemaVersion, 1)
        XCTAssertEqual(Set(validated.manifest.artifacts.map(\.path)), [
            "VERSION", "MANIFEST.txt", "config.sh", "bin/msw", "bin/msw-git-askpass",
            "bin/msw-github-host-token", "bin/msw-github-proxy", "bin/msw-keychain-bridge",
            "bin/msw-ssh-proxy", "launchd/org.microsandbox.MSWMonitor.github-proxy.plist",
            "lib/bootstrap-base.sh", "lib/msw-github-relay.py",
            "lib/msw-github-shuttle.py", "lib/msw-port-forwarder.py", "lib/proxy-upstream.py",
            "lib/proxycore.py", "lib/vendor/h11/LICENSE.txt", "lib/vendor/h11/__init__.py",
            "lib/vendor/h11/_abnf.py", "lib/vendor/h11/_connection.py",
            "lib/vendor/h11/_events.py", "lib/vendor/h11/_headers.py",
            "lib/vendor/h11/_readers.py", "lib/vendor/h11/_receivebuffer.py",
            "lib/vendor/h11/_state.py", "lib/vendor/h11/_util.py",
            "lib/vendor/h11/_version.py", "lib/vendor/h11/_writers.py",
            "lib/vendor/h11/py.typed"
        ])
        XCTAssertTrue(validated.manifest.artifacts.first { $0.path == "bin/msw" }?.executable == true)
        XCTAssertTrue(validated.manifest.artifacts.first { $0.path == "config.sh" }?.executable == true)
        XCTAssertTrue(validated.manifest.artifacts.first { $0.path == "lib/proxycore.py" }?.executable == true)
    }

    func testBundledToolchainManifestRequiresEveryCoupledArtifact() throws {
        let bundledRoot = try XCTUnwrap(ToolchainLayout.bundledRoot())
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-toolchain-incomplete-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: bundledRoot, to: temporary)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let manifestURL = temporary.appendingPathComponent(ToolchainLayout.manifestName)
        let data = try Data(contentsOf: manifestURL)
        var manifest = try JSONDecoder().decode(ToolchainManifest.self, from: data)
        manifest = ToolchainManifest(
            schemaVersion: manifest.schemaVersion,
            version: manifest.version,
            artifacts: manifest.artifacts.filter { $0.path != "lib/msw-github-relay.py" }
        )
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: manifestURL.path)

        XCTAssertThrowsError(try ToolchainValidator.validateBundled(root: temporary)) { error in
            XCTAssertEqual(error as? ToolchainInstallerError, .invalidManifest)
        }
    }

    func testToolchainUpdateAtomicallyReplacesCorruptionAndLeavesOnlyCurrent() async throws {
        let bundledRoot = try XCTUnwrap(ToolchainLayout.bundledRoot())
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-toolchain-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }
        let installer = ToolchainInstaller(bundledRoot: bundledRoot, installationRoot: temporary)

        let first = try await installer.activate()
        try Data("unexpected".utf8).write(to: first.root.appendingPathComponent("unexpected"))
        XCTAssertThrowsError(try ToolchainValidator.validateActivated(root: first.root)) { error in
            XCTAssertEqual(error as? ToolchainInstallerError, .invalidManifest)
        }
        try Data("corrupt".utf8).write(to: first.root.appendingPathComponent("bin/msw"))
        try FileManager.default.createDirectory(
            at: temporary.appendingPathComponent("historical-1.0.0"),
            withIntermediateDirectories: true
        )
        let repaired = try await installer.activate()

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporary.path), ["current"])
        let validated = try ToolchainValidator.validateActivated(root: repaired.root)
        try ToolchainValidator.verifyHandshake(validated)
        XCTAssertEqual(repaired.version, validated.manifest.version)
    }

    func testBundledToolchainRejectsCorruptPayloadBeforeActivation() throws {
        let bundledRoot = try XCTUnwrap(ToolchainLayout.bundledRoot())
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-toolchain-corrupt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: bundledRoot, to: temporary)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }
        try Data("corrupt".utf8).write(to: temporary.appendingPathComponent("payload/bin/msw"))

        XCTAssertThrowsError(try ToolchainValidator.validateBundled(root: temporary)) { error in
            XCTAssertEqual(error as? ToolchainInstallerError, .checksumMismatch("bin/msw"))
        }
    }

    func testBundledToolchainRejectsAReplacementPayloadDirectorySymlink() throws {
        let bundledRoot = try XCTUnwrap(ToolchainLayout.bundledRoot())
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-toolchain-symlink-\(UUID().uuidString)", isDirectory: true)
        let externalPayload = temporary.appendingPathComponent("external-payload", isDirectory: true)
        let candidate = temporary.appendingPathComponent("candidate", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: bundledRoot.appendingPathComponent(ToolchainLayout.payloadDirectoryName),
            to: externalPayload
        )
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: bundledRoot.appendingPathComponent(ToolchainLayout.manifestName),
            to: candidate.appendingPathComponent(ToolchainLayout.manifestName)
        )
        try FileManager.default.createSymbolicLink(
            at: candidate.appendingPathComponent(ToolchainLayout.payloadDirectoryName),
            withDestinationURL: externalPayload
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        XCTAssertThrowsError(try ToolchainValidator.validateBundled(root: candidate)) { error in
            XCTAssertEqual(
                error as? ToolchainInstallerError,
                .invalidPermissions(ToolchainLayout.payloadDirectoryName)
            )
        }
    }

    private func makeTestStateEnvelope(
        devLifecycle: MSWLifecycle,
        devQuarantine: MSWQuarantineSnapshot.State,
        observedAt: Date = Date(),
        devStatusObservedAt: Date? = nil
    ) -> MSWEnvelope<MSWStateResponse> {
        let snapshots = Workspace.ID.fixtureDefaults.map { id in
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
                ),
                statusObservedAt: id == .dev ? devStatusObservedAt : nil
            )
        }
        return MSWEnvelope(
            schemaVersion: 1,
            requestId: "state-test",
            ok: true,
            command: "state",
            observedAt: observedAt,
            result: MSWStateResponse(
                schemaVersion: 1,
                mswVersion: "test",
                workspaces: snapshots
            )
        )
    }

    private func makeLifecycleVerificationModel(
        action: MSWLifecycleAction,
        initial: (MSWLifecycle, Date),
        observations: [(MSWLifecycle, Date, Double)],
        applyObservedAt: Date,
        delays: [Duration],
        observationStatusObservedAts: [Date]? = nil,
        failingObservationIndices: Set<Int> = [],
        applyFailure: MSWProtocolError? = nil,
        applyReconciled: Bool = true,
        applyDelay: Double = 0
    ) throws -> AppModel {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-lifecycle-verification-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let responses = [initial] + observations.map { ($0.0, $0.1) }
        for (index, response) in responses.enumerated() {
            let statusObservedAt = index == 0
                ? response.1
                : observationStatusObservedAts?[index - 1] ?? response.1
            try encoder.encode(makeTestStateEnvelope(
                devLifecycle: response.0,
                devQuarantine: .clear,
                observedAt: response.1,
                devStatusObservedAt: statusObservedAt
            )).write(to: temporary.appendingPathComponent("state-\(index + 1).json"))
        }
        let plan = MSWLifecyclePlan(
            planId: "plan-\(action.rawValue)",
            action: action.rawValue,
            workspace: "dev",
            expiresAt: Date().addingTimeInterval(300),
            confirmationPhrase: "\(action.rawValue.uppercased()) dev",
            effects: "Testing \(action.rawValue)."
        )
        try encoder.encode(MSWEnvelope(
            schemaVersion: 1,
            requestId: "plan-\(action.rawValue)",
            ok: true,
            command: "plan",
            observedAt: applyObservedAt,
            result: plan
        )).write(to: temporary.appendingPathComponent("plan.json"))
        let applyEnvelope = MSWEnvelope<MSWApplyResult>(
            schemaVersion: 1,
            requestId: "apply-\(action.rawValue)",
            ok: applyFailure == nil,
            command: "apply",
            observedAt: applyFailure == nil ? applyObservedAt : nil,
            result: applyFailure == nil
                ? MSWApplyResult(
                    workspace: "dev",
                    action: action.rawValue,
                    reconciled: applyReconciled,
                    outcome: "\(action.rawValue.capitalized) applied."
                )
                : nil,
            error: applyFailure
        )
        try encoder.encode(applyEnvelope).write(
            to: temporary.appendingPathComponent("apply.json")
        )
        try Data("0\n".utf8).write(to: temporary.appendingPathComponent("state-count"))

        let lastResponse = responses.count
        let responseCases = observations.enumerated().compactMap { index, observation -> String? in
            let delay = observation.2 > 0 ? "/bin/sleep \(observation.2)" : ""
            if failingObservationIndices.contains(index) {
                let separator = delay.isEmpty ? "" : "; "
                return "\(index + 2)) \(delay)\(separator)exit 70 ;;"
            }
            guard observation.2 > 0 else { return nil }
            return "\(index + 2)) \(delay) ;;"
        }.joined(separator: "\n")
        let executable = temporary.appendingPathComponent("msw")
        let script = """
        #!/bin/sh
        if [ "$1" = "app" ] && [ "$2" = "handshake" ]; then
            printf '%s\n' '\(protocolCompatibleHandshake)'
        elif [ "$1" = "app" ] && [ "$2" = "state" ]; then
            while ! /bin/mkdir "\(temporary.path)/state-lock" 2>/dev/null; do /bin/sleep 0.01; done
            count=$(/bin/cat "\(temporary.path)/state-count")
            count=$((count + 1))
            printf '%s\n' "$count" > "\(temporary.path)/state-count"
            /bin/rmdir "\(temporary.path)/state-lock"
            selected="$count"
            if [ "$selected" -gt "\(lastResponse)" ]; then selected="\(lastResponse)"; fi
            case "$count" in
        \(responseCases)
            esac
            /bin/cat "\(temporary.path)/state-$selected.json"
        elif [ "$1" = "app" ] && [ "$2" = "plan" ]; then
            /bin/cat "\(temporary.path)/plan.json"
        elif [ "$1" = "app" ] && [ "$2" = "apply" ]; then
            if [ "\(applyDelay)" != "0.0" ]; then /bin/sleep "\(applyDelay)"; fi
            /bin/cat "\(temporary.path)/apply.json"
        else
            exit 64
        fi
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let client = MSWClient(runner: MSWCommandRunner(configuration: .init(
            homeDirectory: temporary,
            testMSWExecutable: executable
        )))
        return AppModel(
            client: client,
            operationCoordinator: MSWOperationCoordinator(client: client),
            lifecycleVerificationDelays: delays
        )
    }

    private func beginConfirmedLifecycle(
        _ action: MSWLifecycleAction,
        model: AppModel
    ) async throws {
        switch action {
        case .start:
            model.start(.dev, surface: .unifiedWindow)
        case .stop:
            model.stop(.dev, surface: .unifiedWindow)
        case .restart:
            model.restart(.dev, surface: .unifiedWindow)
        }
        guard action != .start else { return }
        for _ in 0..<80 {
            if model.pendingLifecyclePlan(for: .unifiedWindow) != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(model.pendingLifecyclePlan(for: .unifiedWindow))
        model.confirmPendingLifecycle(surface: .unifiedWindow)
    }

    private func waitForLifecycleCompletion(in model: AppModel) async throws -> MSWOperationState {
        for _ in 0..<160 {
            if model.operationStates["lifecycle:dev"]?.phase == .finished { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let operation = try XCTUnwrap(model.operationStates["lifecycle:dev"])
        XCTAssertEqual(operation.phase, .finished)
        return operation
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

    func testAttentionResolvedRequiresTheAttentionWorkspaceToCommit() {
        XCTAssertTrue(SetupView.attentionResolved(attentionWorkspace: nil, committedWorkspaces: []))
        XCTAssertTrue(SetupView.attentionResolved(attentionWorkspace: nil, committedWorkspaces: ["dev"]))
        XCTAssertFalse(SetupView.attentionResolved(attentionWorkspace: "dev", committedWorkspaces: []))
        XCTAssertFalse(SetupView.attentionResolved(
            attentionWorkspace: "dev",
            committedWorkspaces: ["playgrounds"]
        ))
        XCTAssertTrue(SetupView.attentionResolved(attentionWorkspace: "dev", committedWorkspaces: ["dev"]))
        XCTAssertTrue(SetupView.attentionResolved(
            attentionWorkspace: "dev",
            committedWorkspaces: ["playgrounds", "dev"]
        ))
    }

    func testSkipIssueResolvedOnlyByCommittingTheAffectedWorkspace() {
        XCTAssertFalse(SetupView.skipIssueResolved(issueWorkspace: nil, committedWorkspaces: []))
        XCTAssertFalse(SetupView.skipIssueResolved(issueWorkspace: nil, committedWorkspaces: ["dev"]))
        XCTAssertFalse(SetupView.skipIssueResolved(issueWorkspace: "dev", committedWorkspaces: []))
        XCTAssertFalse(SetupView.skipIssueResolved(
            issueWorkspace: "dev",
            committedWorkspaces: ["playgrounds"]
        ))
        XCTAssertTrue(SetupView.skipIssueResolved(issueWorkspace: "dev", committedWorkspaces: ["dev"]))
        XCTAssertTrue(SetupView.skipIssueResolved(
            issueWorkspace: "dev",
            committedWorkspaces: ["playgrounds", "dev"]
        ))
    }

    func testBootstrapPhaseProgressCoversEveryPhaseWithPlainLanguage() {
        for phase in MSWBootstrapState.Phase.allCases {
            XCTAssertFalse(SetupView.bootstrapPhaseProgress(for: phase).isEmpty)
        }
        XCTAssertEqual(SetupView.bootstrapPhaseProgress(for: .toolchain), "Checking the MSW runtime")
        XCTAssertEqual(SetupView.bootstrapPhaseProgress(for: .hostIntegration), "Updating system records")
        XCTAssertEqual(SetupView.bootstrapPhaseProgress(for: .workspaces), "Registering your workspaces")
    }

    func testBootstrapStateWithoutPhaseDurationsStillDecodes() throws {
        var state = MSWBootstrapState.initial
        state.updatedAt = Date(timeIntervalSince1970: 0)
        let data = try JSONEncoder().encode(state)
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object.removeValue(forKey: "phaseDurations")
        let legacy = try JSONDecoder().decode(
            MSWBootstrapState.self,
            from: try JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNil(legacy.phaseDurations)
    }

    func testSetupLifecycleIsCurrentOnlyWhileUntouched() {
        let gate = SetupLifecycleGate()
        let captured = gate.generation
        XCTAssertTrue(gate.isCurrent(captured))
        gate.invalidate()
        XCTAssertFalse(gate.isCurrent(captured))
        XCTAssertTrue(gate.isCurrent(gate.generation))
    }

    func testCloseDuringCachedAuthorizationRestoreSuppressesStartupPublication() async throws {
        let signingKey = Curve25519.Signing.PrivateKey()
        let connectConfiguration = testConnectConfiguration(
            scopeAttestationPublicKey: signingKey.publicKey.rawRepresentation,
            requiresScopeAttestation: true
        )
        let keychain = InMemoryConnectKeychain()
        let sessionService = "test-startup-connect-\(UUID().uuidString)"
        let clock = TestConnectClock(Date(timeIntervalSince1970: 1_900_000_000))
        let seedTransport = QueueConnectTransport()
        let seedClient = MSWConnectClient(
            configuration: connectConfiguration,
            transport: seedTransport,
            keychain: keychain,
            now: clock.now,
            sessionService: sessionService
        )
        let start = try await seedClient.startAuthorization()
        await seedTransport.enqueue(try testJSON(TestCallbackPayload(
            sessionID: UUID(),
            sessionToken: "opaque-service-session",
            account: GitHubAccount(login: "octocat", id: 1, name: nil, email: nil),
            expiresAt: clock.value.addingTimeInterval(3600)
        )))
        _ = try await seedClient.completeAuthorization(
            callbackURL: testCallbackURL(
                configuration: connectConfiguration,
                state: start.state,
                code: "one-time-code"
            )
        )

        let restoreTransport = GatedConnectTransport()
        await restoreTransport.enqueue(Data(#"{"installations":[]}"#.utf8))
        let restoreClient = MSWConnectClient(
            configuration: connectConfiguration,
            transport: restoreTransport,
            keychain: keychain,
            now: clock.now,
            sessionService: sessionService
        )
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
            connect: restoreClient,
            now: clock.now,
            journalURL: temporary.appendingPathComponent("authorization-journal.json")
        )
        let view = SetupView(
            coordinator: nil,
            authorizationCoordinator: coordinator,
            provider: nil,
            accessMode: .connect,
            applicationPreferences: ApplicationPreferenceStore(),
            openSettings: { _ in },
            closeSetup: { _ in },
            uiTestMode: false,
            uiTestStartsInReview: false,
            uiTestGitHubScenario: nil,
            uiTestBootstrapReconnect: false,
            startupRecoveryBlockedReason: nil,
            retryStartupRecovery: {}
        )

        let lifecycle = view.setupLifecycle.generation
        let startupTask = Task {
            await view.restoreCachedAuthorization(startupLifecycle: lifecycle) != nil
        }
        await restoreTransport.waitUntilSendStarted()
        view.setupLifecycle.invalidate()
        await restoreTransport.resumeSend()

        let startupCompleted = await startupTask.value
        let staleMetadata = await view.loadExistingMetadata(
            startupLifecycle: view.setupLifecycle.generation - 1
        )
        let currentMetadata = await view.loadExistingMetadata(
            startupLifecycle: view.setupLifecycle.generation
        )
        XCTAssertFalse(
            startupCompleted,
            "A closed startup chain must not publish its cached authorization."
        )
        XCTAssertNil(staleMetadata)
        XCTAssertNotNil(currentMetadata)
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
        XCTAssertEqual(GitHubRepositoryAccessMode.readOnly.label, "Pushes off")
        XCTAssertEqual(GitHubRepositoryAccessMode.readWrite.label, "Pushes on")
        XCTAssertEqual(GitHubRepositoryAccessMode.readOnly.rawValue, "read-only")
        XCTAssertEqual(GitHubRepositoryAccessMode.readWrite.rawValue, "read-write")
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

    func testIdentityContinueRequiresClientAvailabilityAndValidIdentity() {
        XCTAssertTrue(SetupView.allowsIdentitySave(
            clientAvailable: true,
            systemReady: true,
            name: "Taylor Example",
            email: "taylor@example.com"
        ))
        XCTAssertFalse(SetupView.allowsIdentitySave(
            clientAvailable: false,
            systemReady: true,
            name: "Taylor Example",
            email: "taylor@example.com"
        ), "A valid identity still requires the migrated MSW client dependency.")
        XCTAssertFalse(SetupView.allowsIdentitySave(
            clientAvailable: true,
            systemReady: false,
            name: "Taylor Example",
            email: "taylor@example.com"
        ), "Git identity must remain blocked until workspace setup is ready.")
        XCTAssertFalse(SetupView.allowsIdentitySave(
            clientAvailable: true,
            systemReady: true,
            name: "   ",
            email: "taylor@example.com"
        ))
        XCTAssertFalse(SetupView.allowsIdentitySave(
            clientAvailable: true,
            systemReady: true,
            name: "Taylor Example",
            email: "taylor @example.com"
        ))
    }

    func testSetupWorkspaceDefaultsMatchRepositoryConfiguration() {
        let configurations = SetupWorkspaceConfiguration.defaults
        XCTAssertEqual(configurations.map(\.name), ["dev", "playgrounds", "personal"])
        XCTAssertEqual(
            configurations.map {
                [$0.cpus, $0.maxCPUs, $0.memoryGiB, $0.maxMemoryGiB,
                 $0.workspaceStorageGiB, $0.runtimeStorageGiB]
            },
            [
                [8, 12, 32, 48, 120, 100],
                [4, 12, 32, 48, 60, 60],
                [6, 12, 16, 32, 100, 80]
            ]
        )
        XCTAssertNil(SetupWorkspaceConfiguration.validationMessage(for: configurations))
    }

    func testWorkspaceResourceEditInvalidatesPreviouslyAppliedSetup() {
        let applied = SetupWorkspaceConfiguration.defaults
        var edited = applied
        edited[0].cpus = 12

        XCTAssertTrue(SetupView.workspaceConfigurationIsApplied(applied, persisted: applied))
        XCTAssertFalse(SetupView.workspaceConfigurationIsApplied(edited, persisted: applied))
        XCTAssertFalse(SetupView.workspaceConfigurationIsApplied(applied, persisted: nil))
    }

    func testStrictBootstrapConfigurationDecoderRejectsUnknownFields() throws {
        let valid = try JSONEncoder().encode(
            MSWBootstrapConfiguration(SetupWorkspaceConfiguration.defaults)
        )
        XCTAssertNotNil(MSWBootstrapConfiguration.decodeValidated(from: valid))

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: valid) as? [String: Any]
        )
        var workspaces = try XCTUnwrap(object["workspaces"] as? [[String: Any]])
        workspaces[0]["host"] = "$(touch should-never-run)"
        object["workspaces"] = workspaces
        let unknownWorkspaceField = try JSONSerialization.data(withJSONObject: object)
        XCTAssertNil(MSWBootstrapConfiguration.decodeValidated(from: unknownWorkspaceField))

        object["unexpected"] = true
        let unknownRootField = try JSONSerialization.data(withJSONObject: object)
        XCTAssertNil(MSWBootstrapConfiguration.decodeValidated(from: unknownRootField))
    }

    @MainActor
    func testAppModelDiscoversConfiguredWorkspaceListInsteadOfFixtureDefaults() {
        let configurations = [
            SetupWorkspaceConfiguration(
                name: "development", cpus: 12, maxCPUs: 12,
                memoryGiB: 48, maxMemoryGiB: 48,
                workspaceStorageGiB: 120, runtimeStorageGiB: 100
            ),
            SetupWorkspaceConfiguration(
                name: "personal", cpus: 4, maxCPUs: 8,
                memoryGiB: 16, maxMemoryGiB: 32,
                workspaceStorageGiB: 80, runtimeStorageGiB: 60
            ),
            SetupWorkspaceConfiguration(
                name: "lab", cpus: 6, maxCPUs: 12,
                memoryGiB: 32, maxMemoryGiB: 48,
                workspaceStorageGiB: 100, runtimeStorageGiB: 80
            )
        ]

        let model = AppModel(workspaceConfigurations: configurations)

        XCTAssertEqual(model.workspaces.map(\.id.rawValue), ["development", "personal", "lab"])
        XCTAssertFalse(model.workspaces.contains { $0.id.rawValue == "dev" })
        XCTAssertFalse(model.workspaces.contains { $0.id.rawValue == "playgrounds" })
    }

    @MainActor
    func testAppModelDoesNotReplaceAnExplicitEmptyConfigurationWithFixtures() {
        let model = AppModel(workspaceConfigurations: [])

        XCTAssertTrue(model.workspaces.isEmpty)
    }

    @MainActor
    func testAppModelReloadsAppliedWorkspaceTargetsWithoutStaleFixtureNames() {
        let model = AppModel(workspaceConfigurations: SetupWorkspaceConfiguration.defaults)
        let selected = [
            SetupWorkspaceConfiguration(
                name: "development", cpus: 8, maxCPUs: 12,
                memoryGiB: 32, maxMemoryGiB: 48,
                workspaceStorageGiB: 120, runtimeStorageGiB: 100
            ),
            SetupWorkspaceConfiguration.defaults[2],
            SetupWorkspaceConfiguration(
                name: "lab", cpus: 4, maxCPUs: 12,
                memoryGiB: 16, maxMemoryGiB: 32,
                workspaceStorageGiB: 60, runtimeStorageGiB: 60
            )
        ]

        model.reloadWorkspaceConfiguration(selected)

        XCTAssertEqual(model.workspaces.map(\.id.rawValue), ["development", "personal", "lab"])
        XCTAssertFalse(model.workspaces.contains { ["dev", "playgrounds"].contains($0.id.rawValue) })
    }

    @MainActor
    func testAppModelRejectsAnOldWorkspaceSnapshotAfterAppliedTargetReload() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-model-target-reload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }
        let stateLine = String(decoding: try testJSON(makeTestStateEnvelope(
            devLifecycle: .stopped,
            devQuarantine: .clear
        )), as: UTF8.self)
        let executable = temporary.appendingPathComponent("msw")
        try Data("#!/bin/sh\nprintf '%s\\n' '\(stateLine)'\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let client = MSWClient(runner: MSWCommandRunner(configuration: .init(
            homeDirectory: temporary,
            testMSWExecutable: executable
        )))
        let model = AppModel(client: client)
        let selected = [
            SetupWorkspaceConfiguration(
                name: "development", cpus: 8, maxCPUs: 12,
                memoryGiB: 32, maxMemoryGiB: 48,
                workspaceStorageGiB: 120, runtimeStorageGiB: 100
            ),
            SetupWorkspaceConfiguration.defaults[2],
            SetupWorkspaceConfiguration(
                name: "lab", cpus: 4, maxCPUs: 12,
                memoryGiB: 16, maxMemoryGiB: 32,
                workspaceStorageGiB: 60, runtimeStorageGiB: 60
            )
        ]

        model.reloadWorkspaceConfiguration(selected)
        await model.refreshRemote()

        XCTAssertEqual(model.workspaces.map(\.id.rawValue), ["development", "personal", "lab"])
        XCTAssertTrue(model.workspaces.allSatisfy { $0.state == .unknown })
    }

    func testSetupWorkspaceValidationRejectsMissingDuplicateAndUnsupportedValues() {
        XCTAssertEqual(
            SetupWorkspaceConfiguration.validationMessage(for: []),
            "Add at least one workspace."
        )
        XCTAssertEqual(
            SetupWorkspaceConfiguration.validationMessage(
                for: (0...64).map {
                    SetupWorkspaceConfiguration(
                        name: "workspace-\($0)", cpus: 4, maxCPUs: 4,
                        memoryGiB: 16, maxMemoryGiB: 16,
                        workspaceStorageGiB: 60, runtimeStorageGiB: 60
                    )
                }
            ),
            "Configure no more than 64 workspaces."
        )
        var configurations = SetupWorkspaceConfiguration.defaults
        configurations[0].name = "  "
        XCTAssertEqual(
            SetupWorkspaceConfiguration.validationMessage(for: configurations),
            "Every workspace needs a name."
        )
        configurations = SetupWorkspaceConfiguration.defaults
        configurations[0].name = " dev"
        XCTAssertEqual(
            SetupWorkspaceConfiguration.validationMessage(for: configurations),
            "Workspace names cannot begin or end with spaces."
        )
        configurations = SetupWorkspaceConfiguration.defaults
        configurations[1].name = "DEV"
        XCTAssertEqual(
            SetupWorkspaceConfiguration.validationMessage(for: configurations),
            "Workspace names must be unique."
        )
        configurations = SetupWorkspaceConfiguration.defaults
        configurations[0].cpus = 16
        XCTAssertEqual(
            SetupWorkspaceConfiguration.validationMessage(for: configurations),
            "Choose supported CPU, memory, and storage values."
        )
        configurations = SetupWorkspaceConfiguration.defaults
        configurations[0].cpus = 12
        configurations[0].maxCPUs = 8
        XCTAssertEqual(
            SetupWorkspaceConfiguration.validationMessage(for: configurations),
            "A workspace CPU limit cannot exceed its resize ceiling."
        )
        configurations = SetupWorkspaceConfiguration.defaults
        configurations[0].memoryGiB = 48
        configurations[0].maxMemoryGiB = 32
        XCTAssertEqual(
            SetupWorkspaceConfiguration.validationMessage(for: configurations),
            "A workspace memory limit cannot exceed its resize ceiling."
        )
    }

    func testSetupWorkspaceDraftConstructionToleratesInvalidPersistedNames() {
        var configurations = SetupWorkspaceConfiguration.defaults
        configurations[1].name = "dev"
        configurations[2].name = "  "

        let drafts = SetupWorkspaceConfiguration.initialRepositoryDrafts(for: configurations)

        XCTAssertEqual(Set(drafts.keys), ["dev"])
        XCTAssertEqual(drafts["dev"]?.workspace, "dev")
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

    func testScopedRepositoryAccessRequiresTrustedScopeAttestation() {
        let unsigned = testConnectConfiguration()
        XCTAssertFalse(unsigned.hasTrustedScopeAttestation)

        let signingKey = Curve25519.Signing.PrivateKey()
        let attested = testConnectConfiguration(
            scopeAttestationPublicKey: signingKey.publicKey.rawRepresentation,
            requiresScopeAttestation: true
        )
        XCTAssertTrue(attested.hasTrustedScopeAttestation)
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

    func testUnconfiguredBuildUsesConciseConnectionFailure() {
        let configuration = MSWConnectConfiguration()

        XCTAssertFalse(GitHubFeatureAvailability.isAvailable(configuration: configuration))
        XCTAssertEqual(
            GitHubFeatureAvailability.unavailableNotice,
            "GitHub connection couldn’t start."
        )
    }

    func testConfiguredConnectWithoutTrustedAttestationCannotOpenAuthorization() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-untrusted-connect-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }
        let broker = try CredentialBroker(
            keychain: InMemoryConnectKeychain(),
            metadataURL: temporary.appendingPathComponent("credentials.json"),
            keychainService: "test-untrusted-connect-\(UUID().uuidString)"
        )
        let coordinator = GitHubAuthorizationCoordinator(
            broker: broker,
            connect: MSWConnectClient(configuration: testConnectConfiguration()),
            journalURL: temporary.appendingPathComponent("authorization-journal.json")
        )
        let browser = RecordingConnectBrowser()

        do {
            _ = try await coordinator.beginAuthorization(browser: browser)
            XCTFail("A build without trusted attestations must not start browser authorization.")
        } catch let error as GitHubAuthorizationError {
            XCTAssertEqual(error, .invalidAppConfiguration)
        }

        XCTAssertNil(browser.openedURL)
    }

    func testWorkspacePresentationSeparatesHealthyRetryAndReconnectActions() {
        let signingKey = Curve25519.Signing.PrivateKey()
        let configured = testConnectConfiguration(
            scopeAttestationPublicKey: signingKey.publicKey.rawRepresentation,
            requiresScopeAttestation: true
        )
        XCTAssertTrue(GitHubFeatureAvailability.isAvailable(configuration: configured))

        let ready = testCredentialMetadata(recoveryState: .ready, needsRestart: true)
        XCTAssertEqual(
            GitHubWorkspaceAccessPresentation.make(workspace: "dev", entries: [ready]),
            GitHubWorkspaceAccessPresentation(
                workspace: "dev",
                status: "Ready · restart required",
                reason: "The verified scope is healthy; restart dev to finish applying it.",
                action: .edit
            )
        )

        let outage = testCredentialMetadata(recoveryState: .serviceUnavailable)
        let retry = GitHubWorkspaceAccessPresentation.make(workspace: "dev", entries: [outage])
        XCTAssertEqual(retry.action, .retry)
        XCTAssertTrue(retry.reason.contains("does not open a browser"))

        let revoked = testCredentialMetadata(recoveryState: .revoked, quarantined: true)
        let reconnect = GitHubWorkspaceAccessPresentation.make(workspace: "dev", entries: [revoked])
        XCTAssertEqual(reconnect.action, .reconnect)
        XCTAssertTrue(reconnect.reason.contains("dev"))
        XCTAssertTrue(reconnect.reason.contains("quarantined"))

        let mismatched = testCredentialMetadata(recoveryState: .scopeMismatch, quarantined: true)
        let scopeReconnect = GitHubWorkspaceAccessPresentation.make(
            workspace: "dev",
            entries: [mismatched]
        )
        XCTAssertEqual(scopeReconnect.action, .reconnect)
        XCTAssertTrue(scopeReconnect.reason.contains("no longer matches"))
    }

    func testTokenRenewalSuccessReturnsMetadataToReady() async throws {
        let fixture = try await makeTokenRefreshFixture()
        try await fixture.broker.updateRecoveryState(
            workspace: "dev",
            role: .guest,
            state: .expired,
            quarantined: false
        )
        await fixture.transport.enqueue(try testJSON(MSWConnectGrant(
            id: fixture.grantID,
            workspace: "dev",
            role: .guest,
            accountLogin: "octocat",
            owner: "acme",
            installationID: 42,
            repositoryIDs: [7],
            repositoryNames: ["acme/one"],
            accessMode: "read-only",
            verificationRepository: "acme/one",
            accessToken: "ghs_renewed_token",
            accessExpiresAt: fixture.clock.value.addingTimeInterval(1800),
            generation: 2
        )))

        let renewed = try await fixture.refresher.refresh(workspace: "dev")

        XCTAssertEqual(renewed.accessToken, "ghs_renewed_token")
        let optionalMetadata = try await fixture.broker.metadata(for: "dev", role: .guest)
        let metadata = try XCTUnwrap(optionalMetadata)
        XCTAssertEqual(metadata.recoveryState, .ready)
        XCTAssertFalse(metadata.quarantined)
        XCTAssertEqual(metadata.generation, 2)
    }

    func testExpiredTokenRenewsSilentlyDuringConfiguredMetadataLoad() async throws {
        let fixture = try await makeTokenRefreshFixture()
        try await fixture.broker.updateRecoveryState(
            workspace: "dev",
            role: .guest,
            state: .expired,
            quarantined: false
        )
        await fixture.transport.enqueue(try testJSON(MSWConnectGrant(
            id: fixture.grantID,
            workspace: "dev",
            role: .guest,
            accountLogin: "octocat",
            owner: "acme",
            installationID: 42,
            repositoryIDs: [7],
            repositoryNames: ["acme/one"],
            accessMode: "read-only",
            verificationRepository: "acme/one",
            accessToken: "ghs_silently_renewed",
            accessExpiresAt: fixture.clock.value.addingTimeInterval(1800),
            generation: 2
        )))
        let coordinator = GitHubAuthorizationCoordinator(
            broker: fixture.broker,
            connect: fixture.client,
            tokenRefreshCoordinator: fixture.refresher,
            allowsUnattestedTestConfiguration: true,
            now: fixture.clock.now,
            journalURL: fixture.journalURL
        )

        let metadata = await coordinator.metadata()

        let renewed = try XCTUnwrap(metadata.first { $0.id == "dev.guest" })
        XCTAssertEqual(renewed.recoveryState, .ready)
        XCTAssertFalse(renewed.quarantined)
        XCTAssertEqual(renewed.generation, 2)
    }

    func testTokenRenewalOutageBecomesRetryWithoutQuarantine() async throws {
        let fixture = try await makeTokenRefreshFixture()

        do {
            _ = try await fixture.refresher.refresh(workspace: "dev")
            XCTFail("A transport outage must not look like a successful renewal.")
        } catch let error as TokenRefreshCoordinatorError {
            XCTAssertEqual(error, .serviceUnavailable)
        }

        let optionalMetadata = try await fixture.broker.metadata(for: "dev", role: .guest)
        let metadata = try XCTUnwrap(optionalMetadata)
        XCTAssertEqual(metadata.recoveryState, .serviceUnavailable)
        XCTAssertFalse(metadata.quarantined)
        XCTAssertEqual(
            GitHubWorkspaceAccessPresentation.make(workspace: "dev", entries: [metadata]).action,
            .retry
        )
    }

    func testTokenRenewalMissingGrantBecomesReconnectAndQuarantine() async throws {
        let fixture = try await makeTokenRefreshFixture()
        await fixture.transport.enqueue(Data(), status: 404)

        do {
            _ = try await fixture.refresher.refresh(workspace: "dev")
            XCTFail("A missing remote grant must require reconnecting.")
        } catch let error as TokenRefreshCoordinatorError {
            XCTAssertEqual(error, .reauthorizationRequired)
        }

        let optionalMetadata = try await fixture.broker.metadata(for: "dev", role: .guest)
        let metadata = try XCTUnwrap(optionalMetadata)
        XCTAssertEqual(metadata.recoveryState, .needsAuthorization)
        XCTAssertTrue(metadata.quarantined)
        XCTAssertEqual(
            GitHubWorkspaceAccessPresentation.make(workspace: "dev", entries: [metadata]).action,
            .reconnect
        )
    }

    func testTokenRenewalScopeDriftBecomesWorkspaceSpecificReconnect() async throws {
        let fixture = try await makeTokenRefreshFixture()
        await fixture.transport.enqueue(try testJSON(MSWConnectGrant(
            id: fixture.grantID,
            workspace: "dev",
            role: .guest,
            accountLogin: "octocat",
            owner: "acme",
            installationID: 42,
            repositoryIDs: [8],
            repositoryNames: ["acme/different"],
            accessMode: "read-only",
            verificationRepository: "acme/different",
            accessToken: "ghs_wrong_scope",
            accessExpiresAt: fixture.clock.value.addingTimeInterval(1800),
            generation: 2
        )))

        do {
            _ = try await fixture.refresher.refresh(workspace: "dev")
            XCTFail("Scope drift must never replace the verified workspace grant.")
        } catch let error as TokenRefreshCoordinatorError {
            XCTAssertEqual(error, .reauthorizationRequired)
        }

        let optionalMetadata = try await fixture.broker.metadata(for: "dev", role: .guest)
        let metadata = try XCTUnwrap(optionalMetadata)
        XCTAssertEqual(metadata.recoveryState, .scopeMismatch)
        XCTAssertTrue(metadata.quarantined)
        let presentation = GitHubWorkspaceAccessPresentation.make(
            workspace: "dev",
            entries: [metadata]
        )
        XCTAssertEqual(presentation.action, .reconnect)
        XCTAssertTrue(presentation.reason.contains("dev"))
        XCTAssertTrue(presentation.reason.contains("no longer matches"))
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
            allowsUnattestedTestConfiguration: true,
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
                policy: [GitHubWorkspacePolicy(workspace: "dev", repositories: [policy])]
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
        let coordinator = GitHubAuthorizationCoordinator(
            broker: broker,
            connect: connect,
            allowsUnattestedTestConfiguration: true,
            now: clock.now
        )
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
            _ = try await coordinator.commitPolicy(
                sessionID: discovery.sessionID,
                policy: [GitHubWorkspacePolicy(workspace: "dev", repositories: policy)]
            )
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
            allowsUnattestedTestConfiguration: true,
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
            policy: [
                GitHubWorkspacePolicy(workspace: "dev", repositories: [devPolicy]),
                GitHubWorkspacePolicy(workspace: "personal", repositories: [personalPolicy])
            ]
        )
        XCTAssertEqual(metadata.map(\.id), ["dev.guest", "personal.guest", "personal.host"])
        let personalMetadata = try await broker.metadata(for: "personal", role: .host)
        XCTAssertEqual(personalMetadata?.accessMode, "host-write")
        let devBundle = try await broker.load(workspace: "dev", role: .guest)
        XCTAssertEqual(devBundle.credential.accessToken, "ghs_dev_token")

        do {
            _ = try await coordinator.commitPolicy(
                sessionID: discovery.sessionID,
                policy: [GitHubWorkspacePolicy(workspace: "dev", repositories: [devPolicy])]
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
            "verifiedUnboundWorkspaces": ["dev"],
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
            allowsUnattestedTestConfiguration: true,
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
    func testUnconfiguredAuthorizationMetadataQuarantinesAndRetainsPreparedJournal() async throws {
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
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: journalURL.path),
            "An unconfigured build must retain the journal because it cannot prove remote cleanup."
        )
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
            "verifiedUnboundWorkspaces": ["dev"],
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

    func testInProcessRollbackRequiresVerifiedUnbindBeforeReplacementRevocation() async throws {
        for proof in [
            GitHubRemovalUnbindProof.missingClient,
            .absent,
            .wrongWorkspace,
            .refused,
            .commandError
        ] {
            let fixture = try await makeGitHubRemovalFixture(unbindProof: proof)
            let owner = GitHubInstallationAccount(login: "acme", id: 42, type: "Organization")
            let installation = GitHubInstallation(
                id: 42,
                account: owner,
                repositorySelection: "selected"
            )
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
            await fixture.transport.enqueue(try testJSON(TestInstallationResponse(
                installations: [installation]
            )))
            let discovery = try await fixture.coordinator.beginAuthorization(
                browser: TestConnectBrowser()
            )
            await fixture.transport.enqueue(try testJSON(TestRepositoryResponse(
                repositories: repositories
            )))
            let replacementID = UUID()
            await fixture.transport.enqueue(try testJSON(MSWConnectGrant(
                id: replacementID,
                workspace: "dev",
                role: .guest,
                accountLogin: "octocat",
                owner: "acme",
                installationID: 42,
                repositoryIDs: [7, 8],
                repositoryNames: ["acme/one", "acme/two"],
                accessMode: "read-only",
                verificationRepository: "acme/one",
                accessToken: "ghs_unverified_rollback",
                accessExpiresAt: fixture.clock.value.addingTimeInterval(1800),
                generation: 2
            )))
            let policy = [
                GitHubRepositoryPolicy(
                    workspace: "dev",
                    repositoryID: 7,
                    fullName: "acme/one",
                    installationID: 42,
                    ownerID: owner.id,
                    ownerLogin: owner.login,
                    ownerType: owner.type
                ),
                GitHubRepositoryPolicy(
                    workspace: "dev",
                    repositoryID: 8,
                    fullName: "acme/two",
                    installationID: 42,
                    ownerID: owner.id,
                    ownerLogin: owner.login,
                    ownerType: owner.type,
                    mode: .readWrite
                )
            ]

            do {
                _ = try await fixture.coordinator.commitPolicy(
                    sessionID: discovery.sessionID,
                    policy: [GitHubWorkspacePolicy(workspace: "dev", repositories: policy)]
                )
                XCTFail("Rollback must reject \(proof) unbind proof.")
            } catch let error as GitHubAuthorizationError {
                XCTAssertEqual(error, .revocationFailed)
            }

            let cleanupRequests = await githubCleanupRequests(fixture.transport)
            XCTAssertTrue(cleanupRequests.isEmpty, "Rollback must not DELETE after \(proof) proof.")
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.journalURL.path))
            let persisted = try JSONSerialization.jsonObject(
                with: Data(contentsOf: fixture.journalURL)
            ) as? [String: Any]
            XCTAssertEqual(persisted?["phase"] as? String, "rollingBack")
            XCTAssertEqual(persisted?["newGrantIDs"] as? [String], [replacementID.uuidString])
            for role in CredentialRole.allCases {
                let optionalEntry = try await fixture.broker.metadata(
                    for: "dev",
                    role: role
                )
                let entry = try XCTUnwrap(optionalEntry)
                XCTAssertEqual(entry.recoveryState, .quarantined)
                XCTAssertTrue(entry.quarantined)
            }
        }
    }

    func testDurableRollbackRequiresVerifiedUnbindBeforeReplacementRevocation() async throws {
        for proof in [
            GitHubRemovalUnbindProof.missingClient,
            .absent,
            .wrongWorkspace,
            .refused,
            .commandError
        ] {
            let fixture = try await makeGitHubRemovalFixture(unbindProof: proof)
            let journal: [String: Any] = [
                "transactionID": UUID().uuidString,
                "sessionID": UUID().uuidString,
                "workspaceKeys": ["dev.guest", "dev.host"],
                "newGrantIDs": [fixture.grantID.uuidString],
                "oldGrantIDs": [],
                "phase": "prepared",
                "updatedAt": ISO8601DateFormatter().string(from: fixture.clock.value)
            ]
            try JSONSerialization.data(withJSONObject: journal).write(to: fixture.journalURL)

            do {
                try await fixture.coordinator.recoverPendingAuthorization()
                XCTFail("Durable recovery must reject \(proof) unbind proof.")
            } catch let error as GitHubAuthorizationError {
                XCTAssertEqual(error, .revocationFailed)
            }

            let cleanupRequests = await githubCleanupRequests(fixture.transport)
            XCTAssertTrue(cleanupRequests.isEmpty, "Recovery must not DELETE after \(proof) proof.")
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.journalURL.path))
            for role in CredentialRole.allCases {
                let optionalEntry = try await fixture.broker.metadata(
                    for: "dev",
                    role: role
                )
                let entry = try XCTUnwrap(optionalEntry)
                XCTAssertEqual(entry.recoveryState, .quarantined)
                XCTAssertTrue(entry.quarantined)
            }
        }
    }

    func testPartialLocalCommitRequiresVerifiedUnbindBeforeAnyGrantRevocation() async throws {
        for proof in [
            GitHubRemovalUnbindProof.missingClient,
            .absent,
            .wrongWorkspace,
            .refused,
            .commandError
        ] {
            let fixture = try await makeGitHubRemovalFixture(unbindProof: proof)
            let replacementID = UUID()
            let journal: [String: Any] = [
                "transactionID": UUID().uuidString,
                "sessionID": UUID().uuidString,
                "workspaceKeys": ["dev.guest", "dev.host"],
                "newGrantIDs": [replacementID.uuidString],
                "oldGrantIDs": [fixture.grantID.uuidString],
                "phase": "localCommitted",
                "updatedAt": ISO8601DateFormatter().string(from: fixture.clock.value)
            ]
            try JSONSerialization.data(withJSONObject: journal).write(to: fixture.journalURL)

            do {
                try await fixture.coordinator.recoverPendingAuthorization()
                XCTFail("Partial local commit must reject \(proof) unbind proof.")
            } catch let error as GitHubAuthorizationError {
                XCTAssertEqual(error, .revocationFailed)
            }

            let cleanupRequests = await githubCleanupRequests(fixture.transport)
            XCTAssertTrue(
                cleanupRequests.isEmpty,
                "Partial recovery must not DELETE old or replacement grants after \(proof) proof."
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.journalURL.path))
            let persisted = try JSONSerialization.jsonObject(
                with: Data(contentsOf: fixture.journalURL)
            ) as? [String: Any]
            XCTAssertEqual(persisted?["phase"] as? String, "rollingBack")
            XCTAssertEqual(persisted?["newGrantIDs"] as? [String], [replacementID.uuidString])
            XCTAssertEqual(persisted?["oldGrantIDs"] as? [String], [fixture.grantID.uuidString])
            for role in CredentialRole.allCases {
                let optionalEntry = try await fixture.broker.metadata(
                    for: "dev",
                    role: role
                )
                let entry = try XCTUnwrap(optionalEntry)
                XCTAssertEqual(entry.recoveryState, .quarantined)
                XCTAssertTrue(entry.quarantined)
            }
        }
    }

    func testDurableRollbackReusesPersistedUnbindProofAfterDeleteInterruption() async throws {
        let fixture = try await makeGitHubRemovalFixture(unbindProof: .verified)
        let journal: [String: Any] = [
            "transactionID": UUID().uuidString,
            "sessionID": UUID().uuidString,
            "workspaceKeys": ["dev.guest"],
            "newGrantIDs": [fixture.grantID.uuidString],
            "oldGrantIDs": [],
            "phase": "prepared",
            "updatedAt": ISO8601DateFormatter().string(from: fixture.clock.value)
        ]
        try JSONSerialization.data(withJSONObject: journal).write(to: fixture.journalURL)

        do {
            try await fixture.coordinator.recoverPendingAuthorization()
            XCTFail("The first replacement DELETE is intentionally interrupted.")
        } catch let error as GitHubAuthorizationError {
            XCTAssertEqual(error, .serviceUnavailable)
        }
        let interrupted = try JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.journalURL)
        ) as? [String: Any]
        XCTAssertEqual(interrupted?["verifiedUnboundWorkspaces"] as? [String], ["dev"])

        await fixture.transport.enqueue(try testJSON(MSWConnectRevocationReceipt(
            grantID: fixture.grantID,
            revoked: true,
            terminal: true,
            revokedAt: fixture.clock.value
        )))
        let recoveredWithoutClient = GitHubAuthorizationCoordinator(
            broker: fixture.broker,
            connect: fixture.connect,
            now: fixture.clock.now,
            journalURL: fixture.journalURL
        )
        try await recoveredWithoutClient.recoverPendingAuthorization()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.journalURL.path))
        let invocations = try String(contentsOf: fixture.invocationURL, encoding: .utf8)
        XCTAssertEqual(invocations.components(separatedBy: "github-unbind").count - 1, 1)
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
            allowsUnattestedTestConfiguration: true,
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
    func testMSWConnectAcceptsPortableSignedScopeAttestation() async throws {
        let signingKey = Curve25519.Signing.PrivateKey()
        let keychain = InMemoryConnectKeychain()
        let transport = QueueConnectTransport()
        let clock = TestConnectClock(Date(timeIntervalSince1970: 1_900_000_000))
        let configuration = testConnectConfiguration(
            scopeAttestationPublicKey: signingKey.publicKey.rawRepresentation,
            requiresScopeAttestation: true
        )
        let client = try await authenticatedConnectClient(
            configuration: configuration,
            transport: transport,
            keychain: keychain,
            clock: clock
        )
        let assignment = testAttestedScopeAssignment()
        let grant = try testSignedAttestedScopeGrant(
            assignment: assignment,
            now: clock.value,
            signingKey: signingKey
        )
        await transport.enqueue(try testJSON(grant))

        let returned = try await client.createGrant(assignment)

        XCTAssertEqual(returned.scopeDigest, try testAttestedScopeDigest(for: assignment))
        XCTAssertEqual(returned.scopeKeyID, "test-key")
        XCTAssertEqual(returned.credentialDigest, testCredentialDigest(returned.accessToken))
    }

    func testMSWConnectRejectsMissingOrTamperedScopeAttestation() async throws {
        let signingKey = Curve25519.Signing.PrivateKey()
        let configuration = testConnectConfiguration(
            scopeAttestationPublicKey: signingKey.publicKey.rawRepresentation,
            requiresScopeAttestation: true
        )
        let clock = TestConnectClock(Date(timeIntervalSince1970: 1_900_000_000))
        let assignment = testAttestedScopeAssignment()

        let missingTransport = QueueConnectTransport()
        let missingClient = try await authenticatedConnectClient(
            configuration: configuration,
            transport: missingTransport,
            keychain: InMemoryConnectKeychain(),
            clock: clock
        )
        await missingTransport.enqueue(try testJSON(testAttestedScopeGrant(
            assignment: assignment,
            now: clock.value
        )))
        do {
            _ = try await missingClient.createGrant(assignment)
            XCTFail("A configured attestation key requires a signed scope.")
        } catch let error as MSWConnectError {
            XCTAssertEqual(error, .scopeAttestationMissing)
        } catch {
            XCTFail("Unexpected attestation error: \(error)")
        }

        let tamperedTransport = QueueConnectTransport()
        let tamperedClient = try await authenticatedConnectClient(
            configuration: configuration,
            transport: tamperedTransport,
            keychain: InMemoryConnectKeychain(),
            clock: clock
        )
        let signed = try testSignedAttestedScopeGrant(
            assignment: assignment,
            now: clock.value,
            signingKey: signingKey
        )
        await tamperedTransport.enqueue(try testJSON(testAttestedScopeGrant(
            assignment: assignment,
            now: clock.value,
            id: signed.id,
            accessToken: signed.accessToken,
            scopeDigest: signed.scopeDigest,
            scopeSignature: Data(repeating: 0, count: 64).base64EncodedString(),
            scopeKeyID: signed.scopeKeyID,
            credentialDigest: signed.credentialDigest
        )))
        do {
            _ = try await tamperedClient.createGrant(assignment)
            XCTFail("A tampered scope signature must be rejected.")
        } catch let error as MSWConnectError {
            XCTAssertEqual(error, .scopeAttestationInvalid)
        } catch {
            XCTFail("Unexpected attestation error: \(error)")
        }
    }

    func testMSWConnectRejectsSignedScopeAttestationWithTamperedScope() async throws {
        let signingKey = Curve25519.Signing.PrivateKey()
        let keychain = InMemoryConnectKeychain()
        let transport = QueueConnectTransport()
        let clock = TestConnectClock(Date(timeIntervalSince1970: 1_900_000_000))
        let configuration = testConnectConfiguration(
            scopeAttestationPublicKey: signingKey.publicKey.rawRepresentation,
            requiresScopeAttestation: true
        )
        let client = try await authenticatedConnectClient(
            configuration: configuration,
            transport: transport,
            keychain: keychain,
            clock: clock
        )
        let assignment = testAttestedScopeAssignment()
        let signed = try testSignedAttestedScopeGrant(
            assignment: assignment,
            now: clock.value,
            signingKey: signingKey
        )
        await transport.enqueue(try testJSON(testAttestedScopeGrant(
            assignment: assignment,
            now: clock.value,
            id: signed.id,
            accessToken: signed.accessToken,
            scopeDigest: signed.scopeDigest,
            scopeSignature: signed.scopeSignature,
            scopeKeyID: signed.scopeKeyID,
            credentialDigest: signed.credentialDigest,
            repositoryNames: ["acme/tampered"],
            verificationRepository: "acme/tampered"
        )))

        do {
            _ = try await client.createGrant(assignment)
            XCTFail("A signed grant whose repository scope changed must be rejected.")
        } catch let error as MSWConnectError {
            XCTAssertEqual(error, .scopeMismatch)
        } catch {
            XCTFail("Unexpected attestation error: \(error)")
        }
    }

    func testMSWConnectRejectsTokenSwappedAfterScopeAttestation() async throws {
        let signingKey = Curve25519.Signing.PrivateKey()
        let transport = QueueConnectTransport()
        let clock = TestConnectClock(Date(timeIntervalSince1970: 1_900_000_000))
        let configuration = testConnectConfiguration(
            scopeAttestationPublicKey: signingKey.publicKey.rawRepresentation,
            requiresScopeAttestation: true
        )
        let client = try await authenticatedConnectClient(
            configuration: configuration,
            transport: transport,
            keychain: InMemoryConnectKeychain(),
            clock: clock
        )
        let assignment = testAttestedScopeAssignment()
        let signed = try testSignedAttestedScopeGrant(
            assignment: assignment,
            now: clock.value,
            signingKey: signingKey
        )
        await transport.enqueue(try testJSON(testAttestedScopeGrant(
            assignment: assignment,
            now: clock.value,
            id: signed.id,
            accessToken: "ghs_token_swapped_after_attestation",
            scopeDigest: signed.scopeDigest,
            scopeSignature: signed.scopeSignature,
            scopeKeyID: signed.scopeKeyID,
            credentialDigest: signed.credentialDigest
        )))

        do {
            _ = try await client.createGrant(assignment)
            XCTFail("A signed scope must bind the returned installation credential.")
        } catch let error as MSWConnectError {
            XCTAssertEqual(error, .scopeAttestationInvalid)
        } catch {
            XCTFail("Unexpected attestation error: \(error)")
        }
    }

    func testMSWConnectRejectsGrantIDSwappedAfterScopeAttestation() async throws {
        let signingKey = Curve25519.Signing.PrivateKey()
        let transport = QueueConnectTransport()
        let clock = TestConnectClock(Date(timeIntervalSince1970: 1_900_000_000))
        let configuration = testConnectConfiguration(
            scopeAttestationPublicKey: signingKey.publicKey.rawRepresentation,
            requiresScopeAttestation: true
        )
        let client = try await authenticatedConnectClient(
            configuration: configuration,
            transport: transport,
            keychain: InMemoryConnectKeychain(),
            clock: clock
        )
        let assignment = testAttestedScopeAssignment()
        let signed = try testSignedAttestedScopeGrant(
            assignment: assignment,
            now: clock.value,
            signingKey: signingKey
        )
        await transport.enqueue(try testJSON(testAttestedScopeGrant(
            assignment: assignment,
            now: clock.value,
            id: UUID(),
            accessToken: signed.accessToken,
            scopeDigest: signed.scopeDigest,
            scopeSignature: signed.scopeSignature,
            scopeKeyID: signed.scopeKeyID,
            credentialDigest: signed.credentialDigest
        )))

        do {
            _ = try await client.createGrant(assignment)
            XCTFail("A signed scope must bind the returned grant ID.")
        } catch let error as MSWConnectError {
            XCTAssertEqual(error, .scopeAttestationInvalid)
        } catch {
            XCTFail("Unexpected attestation error: \(error)")
        }
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

    func testLegacyDirectGitHubCredentialRetirementDeletesPriorCredential() throws {
        let keychain = InMemoryConnectKeychain()
        try keychain.save(KeychainItem(
            service: LegacyDirectGitHubCredentialRetirement.service,
            account: LegacyDirectGitHubCredentialRetirement.account,
            secret: Data("retired-user-token".utf8)
        ))

        try LegacyDirectGitHubCredentialRetirement.remove(using: keychain)

        XCTAssertThrowsError(try keychain.load(
            service: LegacyDirectGitHubCredentialRetirement.service,
            account: LegacyDirectGitHubCredentialRetirement.account
        ))
    }

    func testLegacyDirectGitHubCredentialRetirementFailsClosedWhenDeletionCannotBeProven() {
        XCTAssertThrowsError(
            try LegacyDirectGitHubCredentialRetirement.remove(using: FailingCredentialKeychain())
        ) { error in
            XCTAssertEqual(
                error as? LegacyDirectGitHubCredentialRetirementError,
                .removalUnconfirmed
            )
        }
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
                testMSWExecutable: executable
            )),
            credentialBroker: broker
        )
        let journalURL = temporary.appendingPathComponent("authorization-journal.json")
        let coordinator = GitHubAuthorizationCoordinator(
            broker: broker,
            connect: connect,
            allowsUnattestedTestConfiguration: true,
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
            policy: [GitHubWorkspacePolicy(workspace: "dev", repositories: policy)]
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

    func testRepositoryPolicyDowngradeAndRemovalReplaceEveryScope() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-policy-replacement-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let clock = TestConnectClock(Date(timeIntervalSince1970: 1_900_000_000))
        let keychain = InMemoryConnectKeychain()
        let transport = QueueConnectTransport()
        let connect = MSWConnectClient(
            configuration: testConnectConfiguration(),
            transport: transport,
            keychain: keychain,
            now: clock.now,
            sessionService: "test-policy-replacement-\(UUID().uuidString)"
        )
        let broker = try CredentialBroker(
            keychain: keychain,
            metadataURL: temporary.appendingPathComponent("credentials.json"),
            keychainService: "test-policy-replacement-broker-\(UUID().uuidString)"
        )
        let coordinator = GitHubAuthorizationCoordinator(
            broker: broker,
            connect: connect,
            allowsUnattestedTestConfiguration: true,
            now: clock.now,
            journalURL: temporary.appendingPathComponent("authorization-journal.json")
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
        let readOnly = GitHubRepositoryPolicy(
            workspace: "dev",
            repositoryID: 7,
            fullName: "acme/one",
            installationID: installation.id,
            ownerID: owner.id,
            ownerLogin: owner.login,
            ownerType: owner.type
        )
        let readWrite = GitHubRepositoryPolicy(
            workspace: "dev",
            repositoryID: 8,
            fullName: "acme/two",
            installationID: installation.id,
            ownerID: owner.id,
            ownerLogin: owner.login,
            ownerType: owner.type,
            mode: .readWrite
        )
        let guestOne = UUID(uuidString: "00000000-0000-0000-0000-000000000091")!
        let hostOne = UUID(uuidString: "00000000-0000-0000-0000-000000000092")!
        let guestTwo = UUID(uuidString: "00000000-0000-0000-0000-000000000093")!
        let guestThree = UUID(uuidString: "00000000-0000-0000-0000-000000000094")!

        func grant(
            id: UUID,
            role: CredentialRole,
            repositoryIDs: [Int],
            repositoryNames: [String],
            accessMode: String,
            verificationRepository: String
        ) -> MSWConnectGrant {
            MSWConnectGrant(
                id: id,
                workspace: "dev",
                role: role,
                accountLogin: "octocat",
                owner: owner.login,
                installationID: installation.id,
                repositoryIDs: repositoryIDs,
                repositoryNames: repositoryNames,
                accessMode: accessMode,
                verificationRepository: verificationRepository,
                accessToken: "ghs_\(id.uuidString.lowercased())",
                accessExpiresAt: clock.value.addingTimeInterval(1800),
                generation: 1
            )
        }

        func enqueueInstallations() async throws {
            await transport.enqueue(try testJSON(TestInstallationResponse(installations: [installation])))
        }

        func enqueueAuthorization() async throws {
            await transport.enqueue(try testJSON(TestCallbackPayload(
                sessionID: UUID(),
                sessionToken: "opaque-service-session",
                account: GitHubAccount(login: "octocat", id: 1, name: nil, email: nil),
                expiresAt: clock.value.addingTimeInterval(3600)
            )))
            try await enqueueInstallations()
        }

        func enqueueRevocation(_ grantID: UUID) async throws {
            await transport.enqueue(try testJSON(MSWConnectRevocationReceipt(
                grantID: grantID,
                revoked: true,
                terminal: true,
                revokedAt: clock.value
            )))
        }

        try await enqueueAuthorization()
        let initial = try await coordinator.beginAuthorization(browser: TestConnectBrowser())
        await transport.enqueue(try testJSON(TestRepositoryResponse(repositories: repositories)))
        await transport.enqueue(try testJSON(grant(
            id: guestOne,
            role: .guest,
            repositoryIDs: [7, 8],
            repositoryNames: ["acme/one", "acme/two"],
            accessMode: "read-only",
            verificationRepository: "acme/one"
        )))
        await transport.enqueue(try testJSON(grant(
            id: hostOne,
            role: .host,
            repositoryIDs: [8],
            repositoryNames: ["acme/two"],
            accessMode: "host-write",
            verificationRepository: "acme/two"
        )))
        _ = try await coordinator.commitPolicy(
            sessionID: initial.sessionID,
            policy: [GitHubWorkspacePolicy(workspace: "dev", repositories: [readOnly, readWrite])]
        )

        try await enqueueInstallations()
        let resumedDowngrade = try await coordinator.resumeAuthorization()
        let downgrade = try XCTUnwrap(resumedDowngrade)
        await transport.enqueue(try testJSON(TestRepositoryResponse(repositories: repositories)))
        await transport.enqueue(try testJSON(grant(
            id: guestTwo,
            role: .guest,
            repositoryIDs: [7, 8],
            repositoryNames: ["acme/one", "acme/two"],
            accessMode: "read-only",
            verificationRepository: "acme/one"
        )))
        try await enqueueRevocation(guestOne)
        try await enqueueRevocation(hostOne)
        _ = try await coordinator.commitPolicy(
            sessionID: downgrade.sessionID,
            policy: [GitHubWorkspacePolicy(workspace: "dev", repositories: [
                readOnly,
                GitHubRepositoryPolicy(
                    workspace: "dev",
                    repositoryID: 8,
                    fullName: "acme/two",
                    installationID: installation.id,
                    ownerID: owner.id,
                    ownerLogin: owner.login,
                    ownerType: owner.type
                )
            ])]
        )
        let guestAfterDowngrade = try await broker.metadata(for: "dev", role: .guest)
        let hostAfterDowngrade = try await broker.metadata(for: "dev", role: .host)
        XCTAssertEqual(guestAfterDowngrade?.repositoryIDs, [7, 8])
        XCTAssertNil(hostAfterDowngrade)

        try await enqueueInstallations()
        let resumedRemoval = try await coordinator.resumeAuthorization()
        let removal = try XCTUnwrap(resumedRemoval)
        await transport.enqueue(try testJSON(TestRepositoryResponse(repositories: repositories)))
        await transport.enqueue(try testJSON(grant(
            id: guestThree,
            role: .guest,
            repositoryIDs: [7],
            repositoryNames: ["acme/one"],
            accessMode: "read-only",
            verificationRepository: "acme/one"
        )))
        try await enqueueRevocation(guestTwo)
        _ = try await coordinator.commitPolicy(
            sessionID: removal.sessionID,
            policy: [GitHubWorkspacePolicy(workspace: "dev", repositories: [readOnly])]
        )
        let guestAfterRemoval = try await broker.metadata(for: "dev", role: .guest)
        XCTAssertEqual(guestAfterRemoval?.repositoryIDs, [7])
        let hostAfterRemoval = try await broker.metadata(for: "dev", role: .host)
        XCTAssertNil(hostAfterRemoval)

        try await enqueueInstallations()
        let resumedClear = try await coordinator.resumeAuthorization()
        let clear = try XCTUnwrap(resumedClear)
        try await enqueueRevocation(guestThree)
        let cleared = try await coordinator.commitPolicy(
            sessionID: clear.sessionID,
            policy: [GitHubWorkspacePolicy(workspace: "dev", repositories: [])]
        )
        XCTAssertTrue(cleared.isEmpty)
        let guestAfterClear = try await broker.metadata(for: "dev", role: .guest)
        let hostAfterClear = try await broker.metadata(for: "dev", role: .host)
        XCTAssertNil(guestAfterClear)
        XCTAssertNil(hostAfterClear)

        let requests = await transport.requests()
        let assignments = try requests
            .filter { $0.url?.path == "/v1/grants" }
            .map { request in
                try JSONDecoder().decode(
                    MSWConnectGrantAssignment.self,
                    from: XCTUnwrap(request.httpBody)
                )
            }
        XCTAssertEqual(assignments.count, 4)
        XCTAssertEqual(assignments.filter { $0.role == .guest }.map(\.repositoryIDs), [[7, 8], [7, 8], [7]])
        XCTAssertEqual(assignments.filter { $0.role == .host }.map(\.repositoryIDs), [[8]])
        let revokedGrantIDs = Set(
            requests
                .filter { $0.httpMethod == "DELETE" }
                .compactMap { $0.url?.lastPathComponent }
        )
        XCTAssertEqual(
            revokedGrantIDs,
            Set([guestOne, hostOne, guestTwo, guestThree].map(\.uuidString))
        )
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
                testMSWExecutable: executable
            )),
            credentialBroker: broker
        )
        let journalURL = temporary.appendingPathComponent("authorization-journal.json")
        let coordinator = GitHubAuthorizationCoordinator(
            broker: broker,
            connect: connect,
            allowsUnattestedTestConfiguration: true,
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
                policy: [GitHubWorkspacePolicy(workspace: "dev", repositories: [policy])]
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

    func testPartialPreviousPolicyRebindIsImmediatelyUnboundAndDurablyCleaned() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-partial-rollback-rebind-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let keychain = InMemoryConnectKeychain()
        let broker = try CredentialBroker(
            keychain: keychain,
            metadataURL: temporary.appendingPathComponent("credentials.json"),
            keychainService: "test-partial-rollback-rebind-\(UUID().uuidString)"
        )
        let clock = TestConnectClock(Date(timeIntervalSince1970: 1_900_000_000))
        let oldGuestGrantID = UUID()
        let oldHostGrantID = UUID()
        let newGrantID = UUID()
        for (role, grantID, accessMode, token) in [
            (CredentialRole.guest, oldGuestGrantID, "read-only", "ghs_previous_guest"),
            (.host, oldHostGrantID, "host-write", "ghs_previous_host")
        ] {
            try await broker.storeScopedCredential(
                ScopedInstallationCredential(
                    grantID: grantID,
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
                repositoryNames: ["acme/one"],
                scopeDigest: "previous-\(role.rawValue)-scope"
            )
            try await broker.markBound(workspace: "dev", role: role)
        }

        let transport = QueueConnectTransport()
        let connect = MSWConnectClient(
            configuration: testConnectConfiguration(),
            transport: transport,
            keychain: keychain,
            now: clock.now,
            sessionService: "test-partial-rollback-connect-\(UUID().uuidString)"
        )
        let invocationURL = temporary.appendingPathComponent("msw-partial-rollback.log")
        let bindCountURL = temporary.appendingPathComponent("bind-count")
        let liveBindingURL = temporary.appendingPathComponent("live-binding")
        func bindResponse(accessMode: String, verified: Bool) throws -> String {
            String(
                decoding: try testJSON(MSWEnvelope(
                    schemaVersion: 1,
                    requestId: "github-bind-\(accessMode)",
                    ok: true,
                    command: "github-bind",
                    observedAt: clock.value,
                    result: MSWGitHubBindResult(
                        workspace: "dev",
                        accessMode: accessMode,
                        verificationRepository: "acme/one",
                        verified: verified,
                        lifecycleRestored: verified
                    )
                )),
                as: UTF8.self
            )
        }
        let failedReplacementResponse = try bindResponse(accessMode: "read-only", verified: false)
        let restoredGuestResponse = try bindResponse(accessMode: "read-only", verified: true)
        let failedHostResponse = try bindResponse(accessMode: "host-write", verified: false)
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
            count=0
            if [ -f "\(bindCountURL.path)" ]; then count=$(<"\(bindCountURL.path)"); fi
            count=$((count + 1))
            printf '%s\\n' "$count" > "\(bindCountURL.path)"
            if [ "$count" -eq 1 ]; then
                printf '%s\\n' '\(failedReplacementResponse)'
            elif [ "$*" != "${*--mode host-write}" ]; then
                printf '%s\\n' '\(failedHostResponse)'
            else
                : > "\(liveBindingURL.path)"
                printf '%s\\n' '\(restoredGuestResponse)'
            fi
        elif [ "$1" = "app" ] && [ "$2" = "github-unbind" ]; then
            printf '%s\\n' "$*" >> "\(invocationURL.path)"
            rm -f "\(liveBindingURL.path)"
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
                testMSWExecutable: executable
            )),
            credentialBroker: broker
        )
        let journalURL = temporary.appendingPathComponent("authorization-journal.json")
        let coordinator = GitHubAuthorizationCoordinator(
            broker: broker,
            connect: connect,
            allowsUnattestedTestConfiguration: true,
            mswClient: mswClient,
            now: clock.now,
            journalURL: journalURL
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
        await transport.enqueue(try testJSON(MSWConnectGrant(
            id: newGrantID,
            workspace: "dev",
            role: .guest,
            accountLogin: "octocat",
            owner: "acme",
            installationID: 42,
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
        let policy = GitHubRepositoryPolicy(
            workspace: "dev",
            repositoryID: 7,
            fullName: "acme/one",
            installationID: 42,
            ownerID: owner.id,
            ownerLogin: owner.login,
            ownerType: owner.type
        )

        do {
            _ = try await coordinator.commitPolicyWithVerification(
                sessionID: discovery.sessionID,
                policy: [GitHubWorkspacePolicy(workspace: "dev", repositories: [policy])]
            )
            XCTFail("A false host restore result must fail rollback.")
        } catch let error as GitHubAuthorizationError {
            XCTAssertEqual(error, .revocationFailed)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: liveBindingURL.path),
            "Rollback must not return while a possibly rebound guest secret remains live."
        )
        let interrupted = try JSONSerialization.jsonObject(
            with: Data(contentsOf: journalURL)
        ) as? [String: Any]
        XCTAssertEqual(interrupted?["phase"] as? String, "rollingBack")
        XCTAssertEqual(interrupted?["previousPolicyRestoreState"] as? String, "cleaned")
        XCTAssertEqual(interrupted?["newGrantIDs"] as? [String], [])
        XCTAssertEqual(interrupted?["verifiedUnboundWorkspaces"] as? [String], ["dev"])
        let immediateInvocations = try String(contentsOf: invocationURL, encoding: .utf8)
        XCTAssertEqual(immediateInvocations.components(separatedBy: "github-unbind").count - 1, 2)

        let recoveryCoordinator = GitHubAuthorizationCoordinator(
            broker: broker,
            connect: connect,
            allowsUnattestedTestConfiguration: true,
            mswClient: mswClient,
            now: clock.now,
            journalURL: journalURL
        )
        try await recoveryCoordinator.recoverPendingAuthorization()

        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: liveBindingURL.path))
        let invocations = try String(contentsOf: invocationURL, encoding: .utf8)
        // Recovery trusts the distinct cleaned state and does not perform an
        // unnecessary unbind or accidentally rebind either prior role.
        XCTAssertEqual(invocations.components(separatedBy: "github-unbind").count - 1, 2)
        XCTAssertEqual(invocations.components(separatedBy: "github-bind").count - 1, 4)
        for role in CredentialRole.allCases {
            let metadata = try await broker.metadata(for: "dev", role: role)
            XCTAssertTrue(metadata?.quarantined == true)
            XCTAssertEqual(metadata?.recoveryState, .quarantined)
        }
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


    func testUnconfiguredCoordinatorDisablesReconnectOnlyWorkspace() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-disable-unconfigured-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let keychain = InMemoryConnectKeychain()
        let broker = try CredentialBroker(
            keychain: keychain,
            metadataURL: temporary.appendingPathComponent("credentials.json"),
            keychainService: "test-disable-unconfigured-\(UUID().uuidString)"
        )
        let invocationURL = temporary.appendingPathComponent("msw-unbind-invocations.log")
        let unbindResponse = String(
            decoding: try testJSON(MSWEnvelope(
                schemaVersion: 1,
                requestId: "github-unbind",
                ok: true,
                command: "github-unbind",
                observedAt: Date(),
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
                testMSWExecutable: executable
            )),
            credentialBroker: broker
        )
        let coordinator = GitHubAuthorizationCoordinator(
            broker: broker,
            connect: MSWConnectClient(
                configuration: MSWConnectConfiguration(),
                keychain: keychain,
                sessionService: "test-disable-unconfigured-connect-\(UUID().uuidString)"
            ),
            mswClient: mswClient,
            journalURL: temporary.appendingPathComponent("authorization-transaction.json")
        )

        XCTAssertFalse(coordinator.isAvailable)
        try await coordinator.disableWorkspaceGitHubAccess("dev")

        let invocations = try String(contentsOf: invocationURL, encoding: .utf8)
        XCTAssertTrue(
            invocations.contains("app github-unbind --workspace dev"),
            "An unconfigured coordinator must still remove a stale host binding before setup skips GitHub."
        )
        let remaining = await broker.allMetadata()
        XCTAssertTrue(remaining.isEmpty)
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
                testMSWExecutable: executable
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
                testMSWExecutable: executable
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

    func testRemoveWorkspaceRequiresMSWClientBeforeCleanup() async throws {
        let fixture = try await makeGitHubRemovalFixture(unbindProof: .missingClient)

        do {
            try await fixture.coordinator.removeWorkspace("dev")
            XCTFail("Workspace removal must fail without an MSW client.")
        } catch let error as GitHubAuthorizationError {
            XCTAssertEqual(error, .revocationFailed)
        }

        try await assertRemovalStayedQuarantined(fixture)
    }

    func testRemoveWorkspaceRejectsUnverifiedUnbindProofs() async throws {
        for proof in GitHubRemovalUnbindProof.unverifiedCases {
            let fixture = try await makeGitHubRemovalFixture(unbindProof: proof)

            do {
                try await fixture.coordinator.removeWorkspace("dev")
                XCTFail("Workspace removal must reject \(proof) unbind proof.")
            } catch let error as GitHubAuthorizationError {
                XCTAssertEqual(error, .revocationFailed)
            }

            try await assertRemovalStayedQuarantined(fixture)
        }
    }

    func testRemoveWorkspaceCompletesOnlyAfterVerifiedUnbind() async throws {
        let fixture = try await makeGitHubRemovalFixture(unbindProof: .verified)
        await fixture.transport.enqueue(try testJSON(MSWConnectRevocationReceipt(
            grantID: fixture.grantID,
            revoked: true,
            terminal: true,
            revokedAt: fixture.clock.value
        )))

        try await fixture.coordinator.removeWorkspace("dev")

        let remainingMetadata = await fixture.broker.allMetadata()
        XCTAssertTrue(remainingMetadata.isEmpty)
        let cleanupRequests = await githubCleanupRequests(fixture.transport)
        XCTAssertEqual(cleanupRequests.map(\.httpMethod), ["DELETE"])
        XCTAssertEqual(cleanupRequests.compactMap { $0.url?.path }, [
            "/v1/grants/\(fixture.grantID.uuidString)"
        ])
        let invocations = try String(contentsOf: fixture.invocationURL, encoding: .utf8)
        XCTAssertTrue(invocations.contains("app github-unbind --workspace dev"))
    }

    func testDisconnectAccountRequiresMSWClientBeforeCleanup() async throws {
        let fixture = try await makeGitHubRemovalFixture(unbindProof: .missingClient)

        do {
            try await fixture.coordinator.disconnectAccount()
            XCTFail("Account disconnect must fail without an MSW client.")
        } catch let error as GitHubAuthorizationError {
            XCTAssertEqual(error, .revocationFailed)
        }

        try await assertRemovalStayedQuarantined(fixture)
        let remainingSession = await fixture.connect.currentSession()
        XCTAssertNotNil(remainingSession)
    }

    func testDisconnectAccountRejectsUnverifiedUnbindProofs() async throws {
        for proof in GitHubRemovalUnbindProof.unverifiedCases {
            let fixture = try await makeGitHubRemovalFixture(unbindProof: proof)

            do {
                try await fixture.coordinator.disconnectAccount()
                XCTFail("Account disconnect must reject \(proof) unbind proof.")
            } catch let error as GitHubAuthorizationError {
                XCTAssertEqual(error, .revocationFailed)
            }

            try await assertRemovalStayedQuarantined(fixture)
            let remainingSession = await fixture.connect.currentSession()
            XCTAssertNotNil(remainingSession)
        }
    }

    func testDisconnectAccountCompletesOnlyAfterVerifiedUnbind() async throws {
        let fixture = try await makeGitHubRemovalFixture(unbindProof: .verified)
        await fixture.transport.enqueue(try testJSON(MSWConnectDisconnectReceipt(
            revokedGrantIDs: [fixture.grantID],
            terminal: true
        )))

        try await fixture.coordinator.disconnectAccount()

        let remainingMetadata = await fixture.broker.allMetadata()
        let remainingSession = await fixture.connect.currentSession()
        XCTAssertTrue(remainingMetadata.isEmpty)
        XCTAssertNil(remainingSession)
        let cleanupRequests = await githubCleanupRequests(fixture.transport)
        XCTAssertEqual(cleanupRequests.map(\.httpMethod), ["POST"])
        XCTAssertEqual(cleanupRequests.compactMap { $0.url?.path }, ["/v1/session/revoke"])
        let invocations = try String(contentsOf: fixture.invocationURL, encoding: .utf8)
        XCTAssertTrue(invocations.contains("app github-unbind --workspace dev"))
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

    private func testCredentialMetadata(
        recoveryState: CredentialRecoveryState,
        needsRestart: Bool = false,
        quarantined: Bool = false
    ) -> WorkspaceCredentialMetadata {
        WorkspaceCredentialMetadata(
            workspace: "dev",
            role: .guest,
            provider: "github-app-installation",
            grantID: UUID(),
            accountLogin: "octocat",
            owner: "acme",
            repositoryIDs: [7],
            repositoryNames: ["acme/one"],
            accessMode: "read-only",
            verificationRepository: "acme/one",
            installationID: 42,
            accessExpiresAt: Date().addingTimeInterval(1800),
            needsRestart: needsRestart,
            generation: 1,
            quarantined: quarantined,
            recoveryState: recoveryState,
            updatedAt: Date()
        )
    }

    private enum GitHubRemovalUnbindProof: CustomStringConvertible {
        case missingClient
        case absent
        case wrongWorkspace
        case refused
        case commandError
        case verified

        static let unverifiedCases: [GitHubRemovalUnbindProof] = [
            .absent,
            .wrongWorkspace,
            .refused,
            .commandError
        ]

        var description: String {
            switch self {
            case .missingClient: "missing-client"
            case .absent: "absent"
            case .wrongWorkspace: "wrong-workspace"
            case .refused: "unbound-false"
            case .commandError: "command-error"
            case .verified: "verified"
            }
        }
    }

    private typealias GitHubRemovalFixture = (
        coordinator: GitHubAuthorizationCoordinator,
        broker: CredentialBroker,
        connect: MSWConnectClient,
        transport: QueueConnectTransport,
        clock: TestConnectClock,
        grantID: UUID,
        invocationURL: URL,
        journalURL: URL
    )

    private func makeGitHubRemovalFixture(
        unbindProof: GitHubRemovalUnbindProof
    ) async throws -> GitHubRemovalFixture {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-github-removal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let keychain = InMemoryConnectKeychain()
        let broker = try CredentialBroker(
            keychain: keychain,
            metadataURL: temporary.appendingPathComponent("credentials.json"),
            keychainService: "test-github-removal-\(UUID().uuidString)"
        )
        let clock = TestConnectClock(Date(timeIntervalSince1970: 1_900_000_000))
        let transport = QueueConnectTransport()
        let configuration = testConnectConfiguration()
        let connect = try await authenticatedConnectClient(
            configuration: configuration,
            transport: transport,
            keychain: keychain,
            clock: clock
        )
        let grantID = UUID()
        try await broker.storeScopedCredential(
            ScopedInstallationCredential(
                grantID: grantID,
                accessToken: "ghs_removal_fixture",
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

        let invocationURL = temporary.appendingPathComponent("msw-unbind-invocations.log")
        var mswClient: MSWClient?
        if unbindProof == .missingClient {
            mswClient = nil
        } else {
            let envelope: MSWEnvelope<MSWGitHubUnbindResult>
            switch unbindProof {
            case .absent, .commandError:
                envelope = MSWEnvelope(
                    schemaVersion: 1,
                    requestId: "github-unbind",
                    ok: true,
                    command: "github-unbind",
                    observedAt: clock.value
                )
            case .wrongWorkspace:
                envelope = MSWEnvelope(
                    schemaVersion: 1,
                    requestId: "github-unbind",
                    ok: true,
                    command: "github-unbind",
                    observedAt: clock.value,
                    result: MSWGitHubUnbindResult(workspace: "personal", unbound: true)
                )
            case .refused:
                envelope = MSWEnvelope(
                    schemaVersion: 1,
                    requestId: "github-unbind",
                    ok: true,
                    command: "github-unbind",
                    observedAt: clock.value,
                    result: MSWGitHubUnbindResult(workspace: "dev", unbound: false)
                )
            case .verified:
                envelope = MSWEnvelope(
                    schemaVersion: 1,
                    requestId: "github-unbind",
                    ok: true,
                    command: "github-unbind",
                    observedAt: clock.value,
                    result: MSWGitHubUnbindResult(workspace: "dev", unbound: true)
                )
            case .missingClient:
                fatalError("The missing-client fixture does not create an MSW executable.")
            }
            let response = String(decoding: try testJSON(envelope), as: UTF8.self)
            let commandBehavior = unbindProof == .commandError
                ? "printf '%s\\n' 'unbind failed' >&2\n    exit 70"
                : "printf '%s\\n' '\(response)'"
            let executable = temporary.appendingPathComponent("msw")
            let script = """
            #!/bin/sh
            if [ "$1" = "app" ] && [ "$2" = "handshake" ]; then
                printf '%s\\n' '\(protocolCompatibleHandshake)'
            elif [ "$1" = "app" ] && [ "$2" = "github-unbind" ]; then
                printf '%s\\n' "$*" >> "\(invocationURL.path)"
                \(commandBehavior)
            else
                exit 64
            fi
            """
            try Data(script.utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            mswClient = MSWClient(
                runner: MSWCommandRunner(configuration: .init(
                    homeDirectory: temporary,
                    testMSWExecutable: executable
                )),
                credentialBroker: broker
            )
        }

        return (
            GitHubAuthorizationCoordinator(
                broker: broker,
                connect: connect,
                allowsUnattestedTestConfiguration: true,
                mswClient: mswClient,
                now: clock.now,
                journalURL: temporary.appendingPathComponent("authorization-transaction.json")
            ),
            broker,
            connect,
            transport,
            clock,
            grantID,
            invocationURL,
            temporary.appendingPathComponent("authorization-transaction.json")
        )
    }

    private func assertRemovalStayedQuarantined(
        _ fixture: GitHubRemovalFixture
    ) async throws {
        let metadata = await fixture.broker.allMetadata()
        let entry = try XCTUnwrap(metadata.first)
        XCTAssertEqual(entry.workspace, "dev")
        XCTAssertEqual(entry.recoveryState, .quarantined)
        XCTAssertTrue(entry.quarantined)
        let cleanupRequests = await githubCleanupRequests(fixture.transport)
        XCTAssertTrue(cleanupRequests.isEmpty)
    }

    private func githubCleanupRequests(
        _ transport: QueueConnectTransport
    ) async -> [URLRequest] {
        await transport.requests().filter { request in
            request.url?.path.hasPrefix("/v1/grants/") == true ||
                request.url?.path == "/v1/session/revoke"
        }
    }

    private func makeTokenRefreshFixture() async throws -> (
        broker: CredentialBroker,
        transport: QueueConnectTransport,
        refresher: TokenRefreshCoordinator,
        client: MSWConnectClient,
        clock: TestConnectClock,
        grantID: UUID,
        journalURL: URL
    ) {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-token-renewal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }
        let keychain = InMemoryConnectKeychain()
        let transport = QueueConnectTransport()
        let clock = TestConnectClock(Date(timeIntervalSince1970: 1_900_000_000))
        let configuration = testConnectConfiguration()
        let client = try await authenticatedConnectClient(
            configuration: configuration,
            transport: transport,
            keychain: keychain,
            clock: clock
        )
        let broker = try CredentialBroker(
            keychain: keychain,
            metadataURL: temporary.appendingPathComponent("credentials.json"),
            keychainService: "test-token-renewal-\(UUID().uuidString)"
        )
        let grantID = UUID()
        try await broker.storeScopedCredential(
            ScopedInstallationCredential(
                grantID: grantID,
                accessToken: "ghs_initial_token",
                accessExpiresAt: clock.value.addingTimeInterval(600),
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
        return (
            broker,
            transport,
            TokenRefreshCoordinator(broker: broker, connect: client),
            client,
            clock,
            grantID,
            temporary.appendingPathComponent("authorization-journal.json")
        )
    }

    private func testConnectConfiguration(
        scopeAttestationPublicKey: Data? = nil,
        requiresScopeAttestation: Bool = false
    ) -> MSWConnectConfiguration {
        MSWConnectConfiguration(
            baseURL: URL(string: "https://connect.test")!,
            clientID: "test-client",
            redirectURL: URL(string: "msw://connect.microsandbox.dev/oauth/callback")!,
            authorizationPath: "/oauth/authorize",
            callbackPath: "/oauth/callback",
            scopeAttestationPublicKey: scopeAttestationPublicKey,
            requiresScopeAttestation: requiresScopeAttestation
        )
    }

    private func authenticatedConnectClient(
        configuration: MSWConnectConfiguration,
        transport: QueueConnectTransport,
        keychain: InMemoryConnectKeychain,
        clock: TestConnectClock
    ) async throws -> MSWConnectClient {
        let client = MSWConnectClient(
            configuration: configuration,
            transport: transport,
            keychain: keychain,
            now: clock.now,
            sessionService: "test-attested-connect-\(UUID().uuidString)"
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
        return client
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

private struct TestAttestedScopeRepository: Encodable {
    let id: Int
    let name: String
}

private struct TestTokenBoundScopeAttestationPayload: Encodable {
    let schemaVersion: Int
    let grantID: String
    let scopeDigest: String
    let credentialDigest: String
    let accessExpiresAtMilliseconds: Int64
    let generation: Int
    let issuedAtMilliseconds: Int64
}

private struct TestAttestedScopePayload: Encodable {
    let workspace: String
    let role: String
    let owner: String
    let installationID: Int
    let repositories: [TestAttestedScopeRepository]
    let accessMode: String
    let verificationRepository: String
}

private func testAttestedScopeAssignment() -> MSWConnectGrantAssignment {
    MSWConnectGrantAssignment(
        workspace: "dev",
        role: .guest,
        owner: "acme",
        installationID: 42,
        repositoryIDs: [7],
        repositoryNames: ["acme/attested"],
        accessMode: "read-only",
        verificationRepository: "acme/attested"
    )
}

/// Intentionally independent of MSWConnectClient. A repository full name
/// contains `/`, so the signature detects escaped-slash canonicalization.
private func testAttestedScopeDigest(for assignment: MSWConnectGrantAssignment) throws -> String {
    let repositories = zip(assignment.repositoryIDs, assignment.repositoryNames)
        .map { TestAttestedScopeRepository(id: $0.0, name: $0.1.lowercased()) }
        .sorted { $0.id < $1.id }
    let payload = TestAttestedScopePayload(
        workspace: assignment.workspace,
        role: assignment.role.rawValue,
        owner: assignment.owner.lowercased(),
        installationID: assignment.installationID,
        repositories: repositories,
        accessMode: assignment.accessMode,
        verificationRepository: assignment.verificationRepository.lowercased()
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(payload)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func testCredentialDigest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func testTokenBoundScopeAttestationPayload(
    grant: MSWConnectGrant,
    scopeDigest: String,
    credentialDigest: String
) throws -> Data {
    let issuedAt = try XCTUnwrap(grant.issuedAt)
    let payload = TestTokenBoundScopeAttestationPayload(
        schemaVersion: 1,
        grantID: grant.id.uuidString.lowercased(),
        scopeDigest: scopeDigest,
        credentialDigest: credentialDigest,
        accessExpiresAtMilliseconds: Int64((grant.accessExpiresAt.timeIntervalSince1970 * 1_000).rounded(.towardZero)),
        generation: grant.generation,
        issuedAtMilliseconds: Int64((issuedAt.timeIntervalSince1970 * 1_000).rounded(.towardZero))
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(payload)
}

private func testSignedAttestedScopeGrant(
    assignment: MSWConnectGrantAssignment,
    now: Date,
    signingKey: Curve25519.Signing.PrivateKey
) throws -> MSWConnectGrant {
    let unsigned = testAttestedScopeGrant(assignment: assignment, now: now)
    let scopeDigest = try testAttestedScopeDigest(for: assignment)
    let credentialDigest = testCredentialDigest(unsigned.accessToken)
    let payload = try testTokenBoundScopeAttestationPayload(
        grant: unsigned,
        scopeDigest: scopeDigest,
        credentialDigest: credentialDigest
    )
    let signature = try signingKey.signature(for: payload).base64EncodedString()
    return testAttestedScopeGrant(
        assignment: assignment,
        now: now,
        id: unsigned.id,
        accessToken: unsigned.accessToken,
        scopeDigest: scopeDigest,
        scopeSignature: signature,
        scopeKeyID: "test-key",
        credentialDigest: credentialDigest
    )
}

private func testAttestedScopeGrant(
    assignment: MSWConnectGrantAssignment,
    now: Date,
    id: UUID = UUID(),
    accessToken: String = "ghs_attested_scope_token",
    scopeDigest: String? = nil,
    scopeSignature: String? = nil,
    scopeKeyID: String? = nil,
    credentialDigest: String? = nil,
    repositoryNames: [String]? = nil,
    verificationRepository: String? = nil
) -> MSWConnectGrant {
    MSWConnectGrant(
        id: id,
        workspace: assignment.workspace,
        role: assignment.role,
        accountLogin: "octocat",
        owner: assignment.owner,
        installationID: assignment.installationID,
        repositoryIDs: assignment.repositoryIDs,
        repositoryNames: repositoryNames ?? assignment.repositoryNames,
        accessMode: assignment.accessMode,
        verificationRepository: verificationRepository ?? assignment.verificationRepository,
        accessToken: accessToken,
        accessExpiresAt: now.addingTimeInterval(1800),
        generation: 1,
        issuedAt: now,
        scopeDigest: scopeDigest,
        scopeSignature: scopeSignature,
        scopeKeyID: scopeKeyID,
        credentialDigest: credentialDigest
    )
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

private struct FailingCredentialKeychain: CredentialKeychainStoring {
    func save(_ item: KeychainItem) throws {
        throw KeychainStoreError.unavailable(-1)
    }

    func load(service: String, account: String) throws -> Data {
        throw KeychainStoreError.unavailable(-1)
    }

    func delete(service: String, account: String) throws {
        throw KeychainStoreError.unavailable(-1)
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

/// A one-shot request gate for deterministic teardown tests. It blocks the
/// first request until the test invalidates the setup lifecycle, proving that
/// async cached-authorization results cannot publish after the setup closes.
private actor GatedConnectTransport: MSWConnectHTTPTransport {
    private struct Response: Sendable {
        let data: Data
        let status: Int
    }

    private var responses: [Response] = []
    private var sendEntered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var sendReleased = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enqueue(_ data: Data, status: Int = 200) {
        responses.append(Response(data: data, status: status))
    }

    func waitUntilSendStarted() async {
        if sendEntered { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func resumeSend() {
        sendReleased = true
        for continuation in releaseWaiters {
            continuation.resume()
        }
        releaseWaiters.removeAll()
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
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
        return (
            response.data,
            HTTPURLResponse(
                url: request.url!,
                statusCode: response.status,
                httpVersion: nil,
                headerFields: nil
            )!
        )
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

final class MSWHostRepairVerifierHostsParsingTests: XCTestCase {
    private let expected: [MSWWorkspaceNetworkRecord] = [
        MSWWorkspaceNetworkRecord(address: "127.0.0.10", hostname: "dev.msw.test"),
        MSWWorkspaceNetworkRecord(address: "127.0.0.11", hostname: "playgrounds.msw.test"),
        MSWWorkspaceNetworkRecord(address: "127.0.0.12", hostname: "personal.msw.test")
    ]

    func testManagedBlockMatches() {
        let text = """
        127.0.0.1 localhost
        # BEGIN MSW MONITOR MANAGED HOSTS
        127.0.0.10 dev.msw.test
        127.0.0.11 playgrounds.msw.test
        127.0.0.12 personal.msw.test
        # END MSW MONITOR MANAGED HOSTS
        """
        XCTAssertTrue(MSWHostRepairVerifier.managedHostsMatch(text, expected: expected))
    }

    func testLegacyBlockMatches() {
        let text = """
        127.0.0.1 localhost
        # BEGIN MSW WORKSPACES
        127.0.0.10 dev.msw.test
        127.0.0.11 playgrounds.msw.test
        127.0.0.12 personal.msw.test
        # END MSW WORKSPACES
        """
        XCTAssertTrue(MSWHostRepairVerifier.managedHostsMatch(text, expected: expected))
    }

    func testMissingBlockFails() {
        let text = """
        127.0.0.1 localhost
        127.0.0.10 dev.msw.test
        """
        XCTAssertFalse(MSWHostRepairVerifier.managedHostsMatch(text, expected: expected))
    }

    func testMismatchedRecordsFail() {
        let text = """
        # BEGIN MSW WORKSPACES
        127.0.0.10 dev.msw.test
        127.0.0.11 playgrounds.msw.local
        127.0.0.12 personal.msw.test
        # END MSW WORKSPACES
        """
        XCTAssertFalse(MSWHostRepairVerifier.managedHostsMatch(text, expected: expected))
    }

    func testReorderedRecordsFail() {
        let text = """
        # BEGIN MSW MONITOR MANAGED HOSTS
        127.0.0.12 personal.msw.test
        127.0.0.10 dev.msw.test
        127.0.0.11 playgrounds.msw.test
        # END MSW MONITOR MANAGED HOSTS
        """
        XCTAssertFalse(MSWHostRepairVerifier.managedHostsMatch(text, expected: expected))
    }

    func testMixedDialectsFail() {
        let text = """
        # BEGIN MSW MONITOR MANAGED HOSTS
        127.0.0.10 dev.msw.test
        # END MSW MONITOR MANAGED HOSTS
        # BEGIN MSW WORKSPACES
        127.0.0.11 playgrounds.msw.test
        # END MSW WORKSPACES
        """
        XCTAssertFalse(MSWHostRepairVerifier.managedHostsMatch(text, expected: expected))
    }

    func testDuplicateManagedBlocksFail() {
        let text = """
        # BEGIN MSW MONITOR MANAGED HOSTS
        127.0.0.10 dev.msw.test
        # END MSW MONITOR MANAGED HOSTS
        # BEGIN MSW MONITOR MANAGED HOSTS
        127.0.0.11 playgrounds.msw.test
        # END MSW MONITOR MANAGED HOSTS
        """
        XCTAssertFalse(MSWHostRepairVerifier.managedHostsMatch(text, expected: expected))
    }

    func testStrayForeignMarkerFails() {
        let text = """
        # BEGIN MSW MONITOR MANAGED HOSTS
        127.0.0.10 dev.msw.test
        127.0.0.11 playgrounds.msw.test
        127.0.0.12 personal.msw.test
        # END MSW MONITOR MANAGED HOSTS
        # END MSW WORKSPACES
        """
        XCTAssertFalse(MSWHostRepairVerifier.managedHostsMatch(text, expected: expected))
    }
}
