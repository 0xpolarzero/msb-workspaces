import Foundation
import CryptoKit
import XCTest
import UserNotifications
@testable import Silo

@MainActor
private final class RecordingHostService: SiloHostServiceControlling {
    let status: SiloHostServiceStatus = .notRegistered
    private(set) var registerInvocationCount = 0

    func registerIfNeeded() throws -> SiloHostServiceStatus {
        registerInvocationCount += 1
        return .notRegistered
    }

    func openApprovalSettings() {}
}
@MainActor
private final class EnabledHostService: SiloHostServiceControlling {
    let status: SiloHostServiceStatus = .enabled
    private(set) var registerInvocationCount = 0

    func registerIfNeeded() throws -> SiloHostServiceStatus {
        registerInvocationCount += 1
        return .enabled
    }

    func openApprovalSettings() {}
}
@MainActor
private final class UnsignedHostService: SiloHostServiceControlling {
    let status: SiloHostServiceStatus = .notRegistered
    private(set) var registerInvocationCount = 0

    func packagingStatus() async -> SiloHostServicePackagingStatus { .signingUnavailable }

    func registerIfNeeded() throws -> SiloHostServiceStatus {
        registerInvocationCount += 1
        return .notRegistered
    }

    func openApprovalSettings() {}
}

private actor RecordingHostAgent: SiloHostAgentControlling {
    private(set) var ensureAliasInvocationCount = 0
    private(set) var installRecordsInvocationCount = 0
    private(set) var inspectRequests: [[SiloWorkspaceNetworkRecord]] = []

    func inspect(records: [SiloWorkspaceNetworkRecord]) async throws -> SiloHostRecordSnapshot {
        inspectRequests.append(records)
        return snapshot(records: records)
    }

    func ensureFixedLoopbackAliases(records: [SiloWorkspaceNetworkRecord]) async throws -> SiloHostRecordSnapshot {
        ensureAliasInvocationCount += 1
        return snapshot(records: records)
    }

    func installFixedHostRecords(records: [SiloWorkspaceNetworkRecord]) async throws -> SiloHostRecordSnapshot {
        installRecordsInvocationCount += 1
        return snapshot(records: records)
    }

    func uninstall(records: [SiloWorkspaceNetworkRecord]) async throws -> SiloHostRecordSnapshot {
        snapshot(records: records)
    }

    private func snapshot(records: [SiloWorkspaceNetworkRecord]) -> SiloHostRecordSnapshot {
        SiloHostRecordSnapshot(
            fixedAliases: records.map(\.address),
            hostsBlockInstalled: true,
            launchDaemonRegistered: true
        )
    }
}

private struct AvailableUserIntegration: SiloUserIntegrationControlling {
    func configureUserIntegrationIfAvailable() async throws {}
}
private actor RecordingUserIntegration: SiloUserIntegrationControlling {
    private(set) var invocationCount = 0

    func configureUserIntegrationIfAvailable() async throws {
        invocationCount += 1
    }
}

private actor RecordingHostRepair: SiloHostRepairVerifying, SiloHostRepairAuthorizing {
    private let markerURL: URL
    private(set) var authorizationRecords: [[SiloWorkspaceNetworkRecord]] = []
    private(set) var verificationRecords: [[SiloWorkspaceNetworkRecord]] = []

    init(markerURL: URL) {
        self.markerURL = markerURL
    }

    func isReady(records: [SiloWorkspaceNetworkRecord]) async -> Bool {
        verificationRecords.append(records)
        return FileManager.default.fileExists(atPath: markerURL.path)
    }

    func repair(records: [SiloWorkspaceNetworkRecord]) async throws {
        authorizationRecords.append(records)
        try Data("repaired\n".utf8).write(to: markerURL)
    }
}


private actor CommandRecorder {
    private(set) var command: SiloCommand?

    func record(_ command: SiloCommand) {
        self.command = command
    }
}

private let protocolCompatibleHandshake = #"{"schemaVersion":1,"requestId":"test-handshake","ok":true,"command":"handshake","observedAt":"2026-08-08T00:00:00Z","result":{"protocolVersion":1,"siloVersion":"test","platform":{"os":"macOS","architecture":"arm64"},"configurationAvailable":true,"runtimeAvailable":true,"capabilities":{"jsonState":true,"jsonMetrics":true,"jsonLogs":true,"plans":true,"bootstrapEvents":true,"jq":true,"workspaceCount":3},"exitCodes":{}},"warnings":[],"error":null}"#

private func writeBackupExecutable(temporary: URL, response: String) throws -> URL {
    let executable = temporary.appendingPathComponent("silo")
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
    let client = SiloClient(runner: SiloCommandRunner(configuration: .init(
        homeDirectory: temporary,
        testSiloExecutable: executable
    )))
    return AppModel(client: client, diagnostics: SiloDiagnostics(client: client))
}

private final class ControllableNotificationCenter: SiloNotificationCenterControlling {
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
private func makeNotificationEvent() -> SiloNotificationEvent {
    SiloNotificationEvent(
        id: UUID(),
        kind: .operationFailure,
        createdAt: Date(),
        workspace: "dev",
        title: "Operation failed",
        message: "The operation failed.",
        recovery: "Review Activity.",
        deepLink: "silo://workspace/dev?section=activity",
        generation: 1
    )
}

@MainActor
final class AppModelTests: XCTestCase {
    func testStatusIconPreservesDescentMarkAcrossRealModelStates() {
        let healthy = MonitorHealth(
            title: "Ready",
            detail: "Workspace state is current.",
            symbol: "unused",
            severity: .normal
        )
        let attention = MonitorHealth(
            title: "Needs attention",
            detail: "A recovery step is required.",
            symbol: "unused",
            severity: .attention
        )
        let critical = MonitorHealth(
            title: "Action required",
            detail: "Unsafe actions are blocked.",
            symbol: "unused",
            severity: .critical
        )
        let unobserved = MonitorHealth(
            title: "Not observed",
            detail: "No authoritative state is available.",
            symbol: "unused",
            severity: .neutral
        )
        let stopped = Workspace(id: .dev, state: .stopped, freshness: .fresh)
        let running = Workspace(id: .dev, state: .running, freshness: .fresh)

        XCTAssertEqual(
            SiloStatusIcon.state(
                health: healthy,
                runtimeRepairRequired: false,
                workspaces: [stopped],
                hasActiveOperation: false
            ),
            .healthy
        )
        XCTAssertEqual(
            SiloStatusIcon.state(
                health: healthy,
                runtimeRepairRequired: false,
                workspaces: [running],
                hasActiveOperation: false
            ),
            .active
        )
        XCTAssertEqual(
            SiloStatusIcon.state(
                health: attention,
                runtimeRepairRequired: false,
                workspaces: [stopped],
                hasActiveOperation: false
            ),
            .attention
        )
        XCTAssertEqual(
            SiloStatusIcon.state(
                health: critical,
                runtimeRepairRequired: false,
                workspaces: [stopped],
                hasActiveOperation: false
            ),
            .critical
        )
        XCTAssertEqual(
            SiloStatusIcon.state(
                health: unobserved,
                runtimeRepairRequired: false,
                workspaces: [stopped],
                hasActiveOperation: false
            ),
            .offline
        )
        XCTAssertEqual(
            SiloStatusIcon.state(
                health: healthy,
                runtimeRepairRequired: true,
                workspaces: [running],
                hasActiveOperation: true
            ),
            .attention
        )
        XCTAssertTrue(SiloStatusIcon.image(for: .healthy).isTemplate)
        XCTAssertEqual(SiloStatusIcon.image(for: .healthy).size, NSSize(width: 20, height: 20))
    }

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
        let destination = URL(fileURLWithPath: "/tmp/silo-preview-fixture", isDirectory: true)
        let model = AppModel()
        model.installBackupUITestFixture(sourceAllocatedBytes: 16_000_000_000, destination: destination)

        let prepared = await model.prepareBackup(to: destination)
        let preview = try XCTUnwrap(prepared)

        XCTAssertEqual(preview.sourceAllocatedBytes, 16_000_000_000)
        XCTAssertNil(preview.archiveEstimate)
        XCTAssertEqual(preview.destination, destination)
    }

    func testBackupPreviewHistoricalEstimatePreservesConservativeRangeAndProvenance() async throws {
        let destination = URL(fileURLWithPath: "/tmp/silo-preview-history", isDirectory: true)
        let estimate = SiloBackupEstimate(
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
            .appendingPathComponent("silo-backup-preview-integration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let sourceExecutable = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("bin/silo")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: sourceExecutable.path))

        let configDirectory = temporary.appendingPathComponent(".config/silo", isDirectory: true)
        let toolDirectory = temporary.appendingPathComponent(".local/bin", isDirectory: true)
        let managedDirectory = temporary.appendingPathComponent(".microsandbox", isDirectory: true)
        let destination = temporary.appendingPathComponent("Backups", isDirectory: true)
        for directory in [configDirectory, toolDirectory, managedDirectory, destination] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let installedExecutable = toolDirectory.appendingPathComponent("silo")
        try FileManager.default.copyItem(at: sourceExecutable, to: installedExecutable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedExecutable.path)
        try Data(repeating: 0x41, count: 4_096).write(
            to: managedDirectory.appendingPathComponent("managed-state.bin")
        )

        let jq = toolDirectory.appendingPathComponent("jq")
        try Data("#!/bin/sh\ncase \"$1\" in\n  -e) exit 0 ;;\n  -r) printf 'dev\\n' ;;\n  *) exit 1 ;;\nesac\n".utf8).write(to: jq)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: jq.path)
        let config = """
        SILO_VERSION="3.1.0"
        SILO_MSB_BIN="/usr/bin/false"
        SILO_JQ_BIN="\(jq.path)"
        """
        try Data(config.utf8).write(to: configDirectory.appendingPathComponent("config.sh"))
        let workspaces = #"{"schemaVersion":1,"workspaces":[{"name":"dev","cpu":4,"cpuCeiling":4,"memoryGiB":16,"memoryCeilingGiB":16,"workspaceStorageGiB":60,"runtimeStorageGiB":60}]}"#
        try Data(workspaces.utf8).write(to: configDirectory.appendingPathComponent("workspaces.json"))

        let runner = SiloCommandRunner(configuration: .init(
            homeDirectory: temporary,
            testSiloExecutable: installedExecutable
        ))
        let client = SiloClient(runner: runner)
        let model = AppModel(diagnostics: SiloDiagnostics(client: client))

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
            .appendingPathComponent("silo-backup-preview-host-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: destination) }

        let client = SiloClient(runner: SiloCommandRunner())
        guard let handshake = try? await client.handshake().result,
              handshake.configurationAvailable,
              handshake.runtimeAvailable,
              handshake.capabilities.isComplete,
              handshake.capabilities.workspaceCount > 0 else {
            throw XCTSkip("No configured backup-preview-capable host Silo installation is currently resolved.")
        }
        let model = AppModel(diagnostics: SiloDiagnostics(client: client))

        let returnedPreview = await model.prepareBackup(to: destination)
        let executableURL = await client.executableURL()
        let preview = try XCTUnwrap(returnedPreview)
        let resolvedExecutable = try XCTUnwrap(executableURL)

        XCTAssertEqual(resolvedExecutable.lastPathComponent, "silo")
        XCTAssertEqual(preview.destination, destination)
        XCTAssertGreaterThan(preview.sourceAllocatedBytes, 0)
        XCTAssertNil(model.detailError)
    }

    func testBackupFixtureTracksIndependentConcurrentOperationsAndAdvancingProgress() throws {
        let destination = URL(fileURLWithPath: "/tmp/silo-backup-progress", isDirectory: true)
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
        let destination = URL(fileURLWithPath: "/tmp/silo-backup-result-fixtures", isDirectory: true)

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
                XCTAssertEqual(operation.error?.code, "SILO_BACKUP_FAILED")
                XCTAssertNil(operation.result)
            case .running:
                XCTFail("The result fixture test does not include the running scenario.")
            }
        }
    }

    func testBackupListReattachesPersistedRunningAndCompletedOperationsAfterModelRelaunch() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("silo-backup-reattach-\(UUID().uuidString)", isDirectory: true)
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
        let executable = temporary.appendingPathComponent("silo")
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
        let diagnostics = SiloDiagnostics(client: SiloClient(runner: SiloCommandRunner(configuration: .init(
            homeDirectory: temporary, testSiloExecutable: executable
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
            .appendingPathComponent("silo-backup-list-invalid-result-\(UUID().uuidString)", isDirectory: true)
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
        let executable = temporary.appendingPathComponent("silo")
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
        let model = AppModel(diagnostics: SiloDiagnostics(client: SiloClient(runner: SiloCommandRunner(
            configuration: .init(homeDirectory: temporary, testSiloExecutable: executable)
        ))))

        await model.refreshBackupOperations()

        XCTAssertTrue(model.backupOperations.isEmpty)
        XCTAssertFalse(model.runtimeRepairRequired)
        XCTAssertNil(model.detailError)
        XCTAssertEqual(model.backupError, "Silo returned malformed backup data for backup-list.")
    }

    func testBackupListCorruptRecordDoesNotMasqueradeAsRuntimeRepair() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("silo-backup-list-protocol-rejection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }
        let executable = temporary.appendingPathComponent("silo")
        let rejection = #"{"schemaVersion":1,"requestId":"backup-list-rejected","ok":false,"command":"backup-list","observedAt":null,"result":null,"warnings":[],"error":{"code":"SILO_BACKUP_RECORD_INVALID","message":"A durable backup operation record is corrupt.","recovery":"Copy the diagnostic details and inspect the record before retrying.","workspace":null,"retryable":false}}"#
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
        let model = AppModel(diagnostics: SiloDiagnostics(client: SiloClient(runner: SiloCommandRunner(
            configuration: .init(homeDirectory: temporary, testSiloExecutable: executable)
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
            RuntimeRepairIssueClassifier.isRepairRelated(SiloClientError.invalidExecutable)
        )
        XCTAssertFalse(
            RuntimeRepairIssueClassifier.isRepairRelated(
                SiloClientError.timedOut(command: "github-status")
            )
        )
        XCTAssertFalse(
            RuntimeRepairIssueClassifier.isRepairRelated(
                SiloClientError.protocolFailure(SiloProtocolError(
                    code: "SILO_WORKSPACE_DISK_INVALID",
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
            .appendingPathComponent("silo-runtime-repair-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }
        let handshakeURL = temporary.appendingPathComponent("handshake.json")
        let invocationLog = temporary.appendingPathComponent("invocations.log")
        let executable = temporary.appendingPathComponent("silo")
        let incompatibleHandshake = protocolCompatibleHandshake.replacingOccurrences(
            of: #""protocolVersion":1,"siloVersion""#,
            with: #""protocolVersion":2,"siloVersion""#
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

        let client = SiloClient(runner: SiloCommandRunner(configuration: .init(
            homeDirectory: temporary,
            testSiloExecutable: executable
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
            .appendingPathComponent("silo-runtime-repair-cancellation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }
        let executable = temporary.appendingPathComponent("silo")
        let script = """
        #!/bin/sh
        /bin/sleep 2
        printf '%s\\n' '\(protocolCompatibleHandshake)'
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let client = SiloClient(runner: SiloCommandRunner(configuration: .init(
            homeDirectory: temporary,
            testSiloExecutable: executable
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
            .appendingPathComponent("silo-runtime-repair-operation-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }
        let executable = temporary.appendingPathComponent("silo")
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

        let client = SiloClient(runner: SiloCommandRunner(configuration: .init(
            homeDirectory: temporary,
            testSiloExecutable: executable
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
            .appendingPathComponent("silo-runtime-repair-operation-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }
        let destination = temporary.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let executable = temporary.appendingPathComponent("silo")
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

        let client = SiloClient(runner: SiloCommandRunner(configuration: .init(
            homeDirectory: temporary,
            testSiloExecutable: executable
        )))
        let model = AppModel(client: client, diagnostics: SiloDiagnostics(client: client))
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
        XCTAssertEqual(button?.accessibilityLabel(), "Silo")
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
            deepLink: URL(string: "silo://workspace/dev?section=logs")!
        ))
        XCTAssertEqual(logs.tab, .workspaces)
        XCTAssertEqual(logs.workspace, .dev)
        XCTAssertEqual(logs.workspaceSection, .logs)

        let diagnostics = try XCTUnwrap(AppRoute(
            deepLink: URL(string: "silo://diagnostics")!
        ))
        XCTAssertEqual(diagnostics.tab, .overview)
        XCTAssertNil(diagnostics.workspaceSection)

        let activity = try XCTUnwrap(AppRoute(
            deepLink: URL(string: "silo://workspace/dev?section=activity")!
        ))
        XCTAssertEqual(activity.tab, .workspaces)
        XCTAssertEqual(activity.workspace, .dev)
        XCTAssertEqual(activity.workspaceSection, .activity)


        let overview = try XCTUnwrap(AppRoute(
            deepLink: URL(string: "silo://overview")!
        ))
        XCTAssertEqual(overview.tab, .overview)
        XCTAssertNil(overview.workspaceSection)

        let repositories = try XCTUnwrap(AppRoute(
            deepLink: URL(string: "silo://workspace/dev?section=repositories")!
        ))
        XCTAssertEqual(repositories.tab, .workspaces)
        XCTAssertEqual(repositories.workspaceSection, .files)
        XCTAssertEqual(AppNavigationState().tab, .overview)
        XCTAssertEqual(AppNavigationState().workspaceSection, .files)
    }


    func testGitHubSettingsRefreshPreservesCachedState() async throws {
        let provider = GitHubFixtureProvider(scenario: "interaction-states")
        let state = GitHubSettingsState(provider: provider)

        await state.refresh()
        guard case .ready(let account, _, _) = state.connectionState else {
            return XCTFail("Expected the initial GitHub catalog to be cached.")
        }
        XCTAssertEqual(account?.login, "octocat")
        XCTAssertEqual(state.owners.map(\.id), [7])

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
        let state = GitHubSettingsState(provider: provider)

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
        let state = GitHubSettingsState(provider: provider)

        async let first: Void = state.refresh()
        async let second: Void = state.refresh()
        _ = await (first, second)

        let attempts = await provider.catalogLoadAttempts()
        XCTAssertEqual(attempts, 1)
        guard case .ready = state.connectionState else {
            return XCTFail("The shared catalog load should publish one ready state.")
        }
    }

    func testGitHubSettingsLoadIfNeededReusesStartupCatalog() async {
        let provider = GitHubFixtureProvider(scenario: "interaction-states")
        let state = GitHubSettingsState(provider: provider)

        await state.refresh()
        await state.loadIfNeeded()

        let attempts = await provider.catalogLoadAttempts()
        XCTAssertEqual(attempts, 1)
    }

    func testGitHubSettingsPublishesProgressObservedAfterCatalogLoad() async throws {
        let provider = GitHubFixtureProvider(scenario: "sync-completes-during-load")
        _ = try await provider.savePolicy([
            GitHubWorkspacePolicy(workspace: "dev", repositories: [])
        ])
        let state = GitHubSettingsState(provider: provider)

        await state.refresh()

        XCTAssertEqual(state.syncProgress?.phase, .applied)
    }

    func testSystemHealthUsesSetupPreflightChecks() async throws {
        let model = AppModel()
        let coordinator = SiloBootstrapUITestStub()
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
        let payload = Data(#"{"schemaVersion":1,"requestId":"ports","ok":true,"command":"ports","observedAt":"2026-08-08T00:00:00Z","result":{"workspace":"all","workspaces":[{"workspace":"dev","lifecycle":"Running","host":"dev.silo.test","listeningState":"known","ports":[{"port":"3000","configured":true,"listening":true},{"port":"5173","configured":true,"listening":false}]},{"workspace":"personal","lifecycle":"Unknown","host":"personal.silo.test","listeningState":"unknown","ports":[{"port":"3000","configured":true,"listening":null}]}],"freshness":"fresh"},"warnings":[],"error":null}"#.utf8)

        let envelope = try SiloProtocolDecoder.decodeEnvelope(
            payload,
            as: SiloPortsResponse.self,
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
            .appendingPathComponent("silo-logs-capability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let failure = #"{"schemaVersion":1,"requestId":"logs-failed","ok":false,"command":"logs","observedAt":"2026-08-08T00:00:00Z","result":null,"warnings":[],"error":{"code":"SILO_LOGS_UNAVAILABLE","message":"logs unavailable","recovery":"Repair the runtime.","workspace":"dev","retryable":true}}"#
        let executable = temporary.appendingPathComponent("silo")
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

        let client = SiloClient(runner: SiloCommandRunner(configuration: .init(
            homeDirectory: temporary,
            testSiloExecutable: executable
        )))
        let model = AppModel(
            client: client,
            operationService: SiloOperationService(client: client)
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
            .appendingPathComponent("silo-logs-timestamps-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let stream = """
        {"schemaVersion":1,"type":"stream-start","protocolVersion":1,"stream":"logs","requestId":"logs-timestamps","workspace":"dev","observedAt":"2026-08-25T18:10:00Z","available":true,"lifecycle":"Running","freshness":"fresh","reason":null,"safeForDisplay":true}
        {"schemaVersion":1,"type":"log","requestId":"logs-timestamps","workspace":"dev","observedAt":"2026-08-25T18:10:01.125Z","source":"stdout","sessionId":17,"encoding":null,"message":"repeated message","safeForDisplay":true}
        {"schemaVersion":1,"type":"log","requestId":"logs-timestamps","workspace":"dev","observedAt":"2026-08-25T18:10:01.125Z","source":"stderr","sessionId":18,"encoding":"utf-8","message":"repeated message","safeForDisplay":true}
        {"schemaVersion":1,"type":"stream-end","requestId":"logs-timestamps","workspace":"dev","observedAt":"2026-08-25T18:10:02Z","safeForDisplay":true}
        """
        let executable = temporary.appendingPathComponent("silo")
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

        let client = SiloClient(runner: SiloCommandRunner(configuration: .init(
            homeDirectory: temporary,
            testSiloExecutable: executable
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
            executableURL: URL(fileURLWithPath: "/tmp/Silo's/silo"),
            workspaceID: "dev",
            executableSearchPath: "/Users/test/.local/bin:/usr/bin:/bin"
        )

        XCTAssertTrue(script.contains("rm -f -- \"$script_path\""))
        XCTAssertTrue(script.contains(#"exec '/tmp/Silo'"'"'s/silo' 'dev'"#))
        XCTAssertTrue(script.contains("export PATH='/Users/test/.local/bin:/usr/bin:/bin'"))
    }

    func testTerminalLauncherBuildsNativeGhosttyTabAutomation() {
        let script = TerminalLauncher.ghosttyScript(
            executableURL: URL(fileURLWithPath: "/usr/local/bin/silo"),
            workspaceID: "dev",
            executableSearchPath: "/Users/test/.local/bin:/opt/homebrew/bin:/usr/bin:/bin"
        )

        XCTAssertTrue(script.contains("new tab in front window with configuration cfg"))
        XCTAssertTrue(script.contains("set commandText to \"'/usr/local/bin/silo' 'dev'\""))
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

    func testWorkspaceStartupPreferencesDefaultToAllAndPersistSelections() throws {
        let suiteName = "WorkspaceStartupPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(
            WorkspaceStartupPreferences.selectedWorkspaceIDs(
                from: Workspace.ID.fixtureDefaults,
                defaults: defaults
            ),
            Set(Workspace.ID.fixtureDefaults)
        )

        WorkspaceStartupPreferences.setSelectedWorkspaceIDs(
            [.dev, .personal],
            defaults: defaults
        )
        XCTAssertEqual(
            WorkspaceStartupPreferences.selectedWorkspaceIDs(
                from: [.dev, .playgrounds],
                defaults: defaults
            ),
            [.dev]
        )
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
                target: SiloEditorTarget(workspace: "dev", path: ".", host: "dev.msb")
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
        let target = SiloEditorTarget(
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
            let unsafe = SiloEditorTarget(workspace: "dev", path: path, host: "dev.msb")
            XCTAssertFalse(unsafe.isValid)
            XCTAssertNil(unsafe.remoteURL)
            XCTAssertNil(unsafe.zedRemoteURL)
        }
    }

    func testDirectoryClientRejectsUnsafeInputsAndMalformedResponsePaths() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("silo-directory-client-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let executable = temporary.appendingPathComponent("silo")
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
        let client = SiloClient(runner: SiloCommandRunner(configuration: .init(
            homeDirectory: temporary,
            testSiloExecutable: executable
        )))

        do {
            _ = try await client.directories(workspace: "dev", path: "../escape")
            XCTFail("Traversal must be rejected before invoking Silo.")
        } catch { XCTAssertEqual(error as? SiloClientError, .invalidArguments) }
        do {
            _ = try await client.directories(workspace: "dev", path: String(repeating: "x", count: 1_025))
            XCTFail("Oversized paths must be rejected before invoking Silo.")
        } catch { XCTAssertEqual(error as? SiloClientError, .invalidArguments) }
        do {
            _ = try await client.directories(workspace: "dev", query: "bad\u{1b}query")
            XCTFail("Control characters in search queries must be rejected before invoking Silo.")
        } catch { XCTAssertEqual(error as? SiloClientError, .invalidArguments) }
        do {
            _ = try await client.directories(workspace: "dev", limit: 201)
            XCTFail("Unbounded directory limits must be rejected.")
        } catch { XCTAssertEqual(error as? SiloClientError, .invalidArguments) }
        do {
            _ = try await client.directories(workspace: "dev")
            XCTFail("Malformed returned paths must be rejected.")
        } catch { XCTAssertEqual(error as? SiloClientError, .malformedJSON(command: "directory-list")) }
        do {
            _ = try await client.directories(workspace: "dev", path: "Projects")
            XCTFail("Nonrecursive listings must not return folders outside their requested scope.")
        } catch { XCTAssertEqual(error as? SiloClientError, .malformedJSON(command: "directory-list")) }
        do {
            _ = try await client.directories(workspace: "dev", path: "Duplicate")
            XCTFail("Duplicate directory identities must be rejected before SwiftUI consumes them.")
        } catch { XCTAssertEqual(error as? SiloClientError, .malformedJSON(command: "directory-list")) }
        do {
            _ = try await client.editorTarget(workspace: "dev")
            XCTFail("A target for another workspace must be rejected.")
        } catch { XCTAssertEqual(error as? SiloClientError, .malformedJSON(command: "editor-target")) }
    }

    // MARK: - Notifications

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
            SiloNotificationCategory.allCases.map(\.title),
            ["Workspace health", "Action failures", "Backup failures"]
        )
        XCTAssertEqual(
            SiloNotificationCategory.allCases.map(\.detail),
            [
                "Alerts when a workspace remains unavailable, stops unexpectedly, or is quarantined.",
                "Alerts when a workspace action fails.",
                "Alerts when a requested backup does not complete.",
            ]
        )
        XCTAssertEqual(SiloNotificationCategory.category(for: .sustainedUnavailability), .workspaceHealth)
        XCTAssertEqual(SiloNotificationCategory.category(for: .quarantine), .workspaceHealth)
        XCTAssertEqual(SiloNotificationCategory.category(for: .lifecycleLoss), .workspaceHealth)
        XCTAssertEqual(SiloNotificationCategory.category(for: .operationFailure), .actionFailures)
        XCTAssertEqual(SiloNotificationCategory.category(for: .backupFailure), .backupFailures)
    }

    func testClientBackedColdLaunchAndFailedObservationsRemainTruthful() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("silo-cold-launch-truth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let failure = #"{"schemaVersion":1,"requestId":"state-failed","ok":false,"command":"state","observedAt":"2026-08-08T00:00:00Z","result":null,"warnings":[],"error":{"code":"SILO_RUNTIME_UNAVAILABLE","message":"runtime unavailable","recovery":"Repair Silo and retry.","workspace":null,"retryable":true}}"#
        let executable = temporary.appendingPathComponent("silo")
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

        let client = SiloClient(runner: SiloCommandRunner(configuration: .init(
            homeDirectory: temporary,
            testSiloExecutable: executable
        )))
        let model = AppModel(client: client)

        XCTAssertEqual(model.aggregateText, "Not observed")
        XCTAssertTrue(model.workspaces.allSatisfy { $0.state == .unknown && $0.freshness == .unavailable })

        await model.refreshRemote()
        XCTAssertEqual(model.aggregateText, "Unavailable")
        XCTAssertEqual(model.lastRecovery?.code, "SILO_RUNTIME_UNAVAILABLE")
        XCTAssertEqual(model.lastRecovery?.recovery, "Repair Silo and retry.")
        XCTAssertTrue(model.notificationEvents.isEmpty)

        await model.refreshRemote()
        let events = model.drainNotificationEvents()
        XCTAssertEqual(events.map(\.kind), [.sustainedUnavailability])
        XCTAssertEqual(events.first?.deepLink, "silo://diagnostics")
    }

    func testFirstAuthoritativeObservationDoesNotNotifyForExistingQuarantine() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("silo-notification-baseline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let stateURL = temporary.appendingPathComponent("state.json")
        try encoder.encode(makeTestStateEnvelope(devLifecycle: .running, devQuarantine: .quarantined)).write(to: stateURL)
        let executable = temporary.appendingPathComponent("silo")
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

        let client = SiloClient(runner: SiloCommandRunner(configuration: .init(
            homeDirectory: temporary,
            testSiloExecutable: executable
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
            .appendingPathComponent("silo-last-known-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let stateURL = temporary.appendingPathComponent("state.json")
        try encoder.encode(makeTestStateEnvelope(devLifecycle: .running, devQuarantine: .clear)).write(to: stateURL)
        let failureMarker = temporary.appendingPathComponent("fail")
        let executable = temporary.appendingPathComponent("silo")
        let failure = #"{"schemaVersion":1,"requestId":"state-failed","ok":false,"command":"state","observedAt":"2026-08-08T00:00:00Z","result":null,"warnings":[],"error":{"code":"SILO_STATE_UNAVAILABLE","message":"state unavailable","recovery":"Run diagnostics.","workspace":"dev","retryable":true}}"#
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

        let client = SiloClient(runner: SiloCommandRunner(configuration: .init(
            homeDirectory: temporary,
            testSiloExecutable: executable
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

    func testStartupStartsOnlySelectedWorkspaceAfterFreshObservation() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("silo-startup-workspaces-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let stoppedURL = temporary.appendingPathComponent("stopped.json")
        let runningURL = temporary.appendingPathComponent("running.json")
        let planURL = temporary.appendingPathComponent("plan.json")
        let applyURL = temporary.appendingPathComponent("apply.json")
        let started = temporary.appendingPathComponent("started")
        let commandLog = temporary.appendingPathComponent("commands.log")
        try encoder.encode(makeTestStateEnvelope(
            devLifecycle: .stopped,
            devQuarantine: .clear
        )).write(to: stoppedURL)
        try encoder.encode(makeTestStateEnvelope(
            devLifecycle: .running,
            devQuarantine: .clear,
            observedAt: Date().addingTimeInterval(1)
        )).write(to: runningURL)
        try encoder.encode(SiloEnvelope(
            schemaVersion: 1, requestId: "startup-plan", ok: true, command: "plan", observedAt: Date(),
            result: SiloLifecyclePlan(
                planId: "startup-plan", action: "start", workspace: "dev",
                expiresAt: Date().addingTimeInterval(300), confirmationPhrase: "START dev",
                effects: "Starting dev."
            )
        )).write(to: planURL)
        try encoder.encode(SiloEnvelope(
            schemaVersion: 1, requestId: "startup-apply", ok: true, command: "apply", observedAt: Date(),
            result: SiloApplyResult(
                workspace: "dev", action: "start", reconciled: true, outcome: "Start applied."
            )
        )).write(to: applyURL)

        let executable = temporary.appendingPathComponent("silo")
        let script = """
        #!/bin/sh
        printf '%s %s %s\n' "$1" "$2" "$3" >> "\(commandLog.path)"
        if [ "$1" = "app" ] && [ "$2" = "handshake" ]; then
            printf '%s\n' '\(protocolCompatibleHandshake)'
        elif [ "$1" = "app" ] && [ "$2" = "state" ]; then
            if [ -e "\(started.path)" ]; then
                /bin/cat "\(runningURL.path)"
            else
                /bin/cat "\(stoppedURL.path)"
            fi
        elif [ "$1" = "app" ] && [ "$2" = "plan" ]; then
            /bin/cat "\(planURL.path)"
        elif [ "$1" = "app" ] && [ "$2" = "apply" ]; then
            : > "\(started.path)"
            /bin/cat "\(applyURL.path)"
        else
            exit 64
        fi
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let client = SiloClient(runner: SiloCommandRunner(configuration: .init(
            homeDirectory: temporary,
            testSiloExecutable: executable
        )))
        let model = AppModel(
            client: client,
            operationCoordinator: SiloOperationCoordinator(client: client)
        )

        await model.startWorkspacesAtLaunch([.dev])
        for _ in 0..<80 {
            if FileManager.default.fileExists(atPath: started.path) { break }
            try await Task.sleep(for: .milliseconds(25))
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: started.path))
        let commands = try String(contentsOf: commandLog, encoding: .utf8)
        XCTAssertTrue(commands.contains("app apply"))
        XCTAssertFalse(commands.contains("playgrounds"))
        XCTAssertFalse(commands.contains("personal"))
    }

    func testLifecycleOperationStaysVerifyingUntilFreshMatchingObservation() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("silo-operation-verification-\(UUID().uuidString)", isDirectory: true)
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
        try encoder.encode(SiloEnvelope(
            schemaVersion: 1, requestId: "plan-start", ok: true, command: "plan", observedAt: Date(),
            result: SiloLifecyclePlan(
                planId: "plan-start", action: "start", workspace: "dev",
                expiresAt: Date().addingTimeInterval(300), confirmationPhrase: "START dev", effects: "Starting dev."
            )
        )).write(to: planURL)
        try encoder.encode(SiloEnvelope(
            schemaVersion: 1, requestId: "apply-start", ok: true, command: "apply", observedAt: baseline,
            result: SiloApplyResult(workspace: "dev", action: "start", reconciled: true, outcome: "Start applied.")
        )).write(to: applyURL)

        let executable = temporary.appendingPathComponent("silo")
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

        let client = SiloClient(runner: SiloCommandRunner(configuration: .init(
            homeDirectory: temporary,
            testSiloExecutable: executable
        )))
        let model = AppModel(
            client: client,
            operationCoordinator: SiloOperationCoordinator(client: client)
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
            applyFailure: SiloProtocolError(
                code: "SILO_RECONCILE_PENDING",
                message: "The lifecycle operation completed without a matching fresh state observation.",
                recovery: "Refresh after checking the workspace runtime; Silo did not claim final state.",
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
            applyFailure: SiloProtocolError(
                code: "SILO_OPERATION_FAILED",
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
            .appendingPathComponent("silo-managed-runtime-resolution-\(UUID().uuidString)", isDirectory: true)
        let external = temporary.appendingPathComponent(".local/bin/silo")
        let managedRoot = temporary.appendingPathComponent("managed-toolchain", isDirectory: true)
        try FileManager.default.createDirectory(
            at: external.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        try Data("#!/bin/sh\nprintf 'external fake must not run\\n'\nexit 99\n".utf8).write(to: external)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: external.path)

        let runner = SiloCommandRunner(configuration: .init(
            homeDirectory: temporary,
            managedToolchainRoot: managedRoot
        ))
        let beforeRepair = await runner.siloResolution(forceRefresh: true)
        XCTAssertNil(beforeRepair.selected)

        let bundledRoot = try XCTUnwrap(ToolchainLayout.bundledRoot())
        _ = try await ToolchainInstaller(
            bundledRoot: bundledRoot,
            installationRoot: managedRoot
        ).activate()
        await runner.invalidateSiloResolution()

        let afterRepair = await runner.siloResolution()
        XCTAssertEqual(
            afterRepair.selected?.standardizedFileURL,
            managedRoot.appendingPathComponent("current/bin/silo").standardizedFileURL
        )
    }

    func testSupersededRuntimeResolutionCannotOverwriteRepairedRuntimeCache() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("silo-runtime-resolution-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }
        let executable = temporary.appendingPathComponent("silo")
        let firstHandshakeStarted = temporary.appendingPathComponent("first-handshake-started")
        let incompatibleHandshake = protocolCompatibleHandshake.replacingOccurrences(
            of: #""protocolVersion":1,"siloVersion""#,
            with: #""protocolVersion":2,"siloVersion""#
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

        let runner = SiloCommandRunner(configuration: .init(
            homeDirectory: temporary,
            testSiloExecutable: executable
        ))
        let staleResolution = Task { await runner.siloResolution(forceRefresh: true) }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: firstHandshakeStarted.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstHandshakeStarted.path))

        await runner.invalidateSiloResolution()
        let repairedResolution = await runner.siloResolution(forceRefresh: true)
        XCTAssertEqual(repairedResolution.selected?.standardizedFileURL, executable.standardizedFileURL)
        let supersededResolution = await staleResolution.value
        XCTAssertNil(supersededResolution.selected)

        let cachedResolution = await runner.siloResolution()
        XCTAssertEqual(
            cachedResolution.selected?.standardizedFileURL,
            executable.standardizedFileURL,
            "A superseded pre-repair handshake must not replace the repaired runtime cache"
        )
    }

    func testUnknownQuarantineSnapshotAllowsStopButDisablesOtherLifecycleActions() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("silo-unknown-quarantine-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let snapshots = Workspace.ID.fixtureDefaults.map { id in
            let isUnknownQuarantine = id == .dev
            return SiloWorkspaceSnapshot(
                id: id.rawValue,
                purpose: "Test workspace",
                lifecycle: isUnknownQuarantine ? .running : .stopped,
                freshness: .fresh,
                quarantine: SiloQuarantineSnapshot(
                    state: isUnknownQuarantine ? .unknown : .clear,
                    reason: nil
                ),
                secrets: SiloSecretsSnapshot(state: .active, pendingCount: 0, reason: nil),
                resources: SiloResourceSnapshot(
                    cpus: "2",
                    maxCpus: "8",
                    memory: "4GiB",
                    maxMemory: "16GiB",
                    rootDisk: "20GiB"
                ),
                network: SiloNetworkSnapshot(
                    host: "\(id.rawValue).silo.test",
                    ip: "127.0.0.10"
                ),
                actionCapabilities: SiloActionCapabilities(
                    canStart: true,
                    canStop: true,
                    canRestart: true,
                    canOpenTerminal: true,
                    canPush: true
                ),
                skippedPorts: [],
                portWarning: ""
            )
        }
        let state = SiloStateResponse(schemaVersion: 1, siloVersion: "test", workspaces: snapshots)
        let envelope = SiloEnvelope(
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
            SiloEnvelope(
                schemaVersion: 1,
                requestId: "plan-stop",
                ok: true,
                command: "plan",
                observedAt: Date(),
                result: SiloLifecyclePlan(
                    planId: "plan-stop",
                    action: "stop",
                    workspace: "dev",
                    expiresAt: Date().addingTimeInterval(300),
                    confirmationPhrase: "STOP dev",
                    effects: "Stopping dev."
                )
            )
        ).write(to: planURL)

        let executable = temporary.appendingPathComponent("silo")
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

        let runner = SiloCommandRunner(configuration: .init(
            homeDirectory: temporary,
            testSiloExecutable: executable
        ))
        let client = SiloClient(runner: runner)
        let model = AppModel(
            client: client,
            operationCoordinator: SiloOperationCoordinator(client: client)
        )
        await model.refreshRemote()
        XCTAssertNil(model.lastError, "Refresh error: \(model.lastError ?? "nil")")

        let dev = try XCTUnwrap(model.workspaces.first(where: { $0.id == .dev }))
        XCTAssertEqual(dev.state, .quarantined)
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
            .appendingPathComponent("silo-start-failure-notice-\(UUID().uuidString)", isDirectory: true)
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
            SiloEnvelope(
                schemaVersion: 1,
                requestId: "plan-start",
                ok: true,
                command: "plan",
                observedAt: Date(),
                result: SiloLifecyclePlan(
                    planId: "plan-start",
                    action: "start",
                    workspace: "dev",
                    expiresAt: Date().addingTimeInterval(300),
                    confirmationPhrase: "START dev",
                    effects: "Starting dev."
                )
            )
        ).write(to: planURL)

        let executable = temporary.appendingPathComponent("silo")
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

        let runner = SiloCommandRunner(configuration: .init(
            homeDirectory: temporary,
            testSiloExecutable: executable
        ))
        let client = SiloClient(runner: runner)
        let model = AppModel(
            client: client,
            operationCoordinator: SiloOperationCoordinator(client: client)
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
        let notice = SiloOperationFailureNotice(
            action: "start",
            title: "Start failed",
            reason: "The dev workspace could not start.\nignored duplicate summary",
            recovery: "Inspect the named workspace volume.",
            workspace: .dev,
            diagnosticDetails: String(repeating: "earlier diagnostics\n", count: 8_000) + finalLine
        )

        XCTAssertEqual(notice.reason, "The dev workspace could not start.")
        let details = try XCTUnwrap(notice.diagnosticDetails)
        XCTAssertLessThanOrEqual(Data(details.utf8).count, SiloOperationFailureNotice.diagnosticLimit)
        XCTAssertTrue(details.hasSuffix(finalLine))
        XCTAssertEqual(details.components(separatedBy: "The dev workspace could not start.").count, 1)

        let unicodeNotice = SiloOperationFailureNotice(
            action: "start",
            title: "Start failed",
            reason: "Short summary.",
            recovery: "Inspect storage.",
            workspace: .dev,
            diagnosticDetails: String(repeating: "🧱", count: SiloOperationFailureNotice.diagnosticLimit)
        )
        let unicodeDetails = try XCTUnwrap(unicodeNotice.diagnosticDetails)
        XCTAssertLessThanOrEqual(
            Data(unicodeDetails.utf8).count,
            SiloOperationFailureNotice.diagnosticLimit
        )
        XCTAssertFalse(unicodeDetails.contains("�"))
    }

    func testUnsafeRefreshCancelsPendingLifecycleConfirmation() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("silo-stale-lifecycle-plan-test-\(UUID().uuidString)", isDirectory: true)
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
            SiloEnvelope(
                schemaVersion: 1,
                requestId: "plan-stop",
                ok: true,
                command: "plan",
                observedAt: Date(),
                result: SiloLifecyclePlan(
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
            SiloEnvelope(
                schemaVersion: 1,
                requestId: "apply-stop",
                ok: true,
                command: "apply",
                observedAt: Date(),
                result: SiloApplyResult(
                    workspace: "dev",
                    action: "stop",
                    reconciled: true,
                    outcome: "Stopped dev."
                )
            )
        ).write(to: applyURL)

        let executable = temporary.appendingPathComponent("silo")
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

        let runner = SiloCommandRunner(configuration: .init(
            homeDirectory: temporary,
            testSiloExecutable: executable
        ))
        let client = SiloClient(runner: runner)
        let model = AppModel(
            client: client,
            operationCoordinator: SiloOperationCoordinator(client: client)
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
            .appendingPathComponent("silo-stale-push-plan-test-\(UUID().uuidString)", isDirectory: true)
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
            SiloEnvelope(
                schemaVersion: 1,
                requestId: "push-plan",
                ok: true,
                command: "push-plan",
                observedAt: Date(),
                result: SiloPushPlan(
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
            SiloEnvelope(
                schemaVersion: 1,
                requestId: "push-apply",
                ok: true,
                command: "apply",
                observedAt: Date(),
                result: SiloPushApplyResult(
                    workspace: "dev",
                    repositoryPath: "repo",
                    branch: "main",
                    pushed: true,
                    reconciled: true,
                    outcome: "Pushed repo."
                )
            )
        ).write(to: applyURL)

        let executable = temporary.appendingPathComponent("silo")
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

        let runner = SiloCommandRunner(configuration: .init(
            homeDirectory: temporary,
            testSiloExecutable: executable
        ))
        let client = SiloClient(runner: runner)
        let coordinator = SiloOperationCoordinator(client: client)
        let model = AppModel(
            client: client,
            operationCoordinator: coordinator,
            operationService: SiloOperationService(client: client, coordinator: coordinator)
        )
        let repository = SiloRepositorySnapshot(
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
    func testFreshOnboardingTreatsMissingConfigurationAsSetupWork() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("silo-bootstrap-first-run-test-\(UUID().uuidString)", isDirectory: true)
        let bin = temporary.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        for name in ["git", "tar", "zstd", "git-lfs", "msb"] {
            let tool = bin.appendingPathComponent(name)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: tool)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        }

        let handshake = protocolCompatibleHandshake.replacingOccurrences(
            of: #""configurationAvailable":true"#,
            with: #""configurationAvailable":false"#
        )
        let executable = bin.appendingPathComponent("silo")
        let script = """
        #!/bin/sh
        if [ "$1" = "app" ] && [ "$2" = "handshake" ]; then
            printf '%s\\n' '\(handshake)'
            exit 0
        fi
        exit 64
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let runner = SiloCommandRunner(configuration: .init(
            homeDirectory: temporary,
            additionalSearchPaths: [executable],
            testSiloExecutable: executable
        ))
        let coordinator = BootstrapCoordinator(
            client: SiloClient(runner: runner),
            runner: runner,
            stateStore: BootstrapStateStore(url: temporary.appendingPathComponent("bootstrap-state.json")),
            hostService: RecordingHostService()
        )

        let checks = await coordinator.preflight()
        let runtime = try XCTUnwrap(checks.first(where: { $0.id == "silo-runtime" }))
        XCTAssertEqual(runtime.status, .pass)
        XCTAssertEqual(
            runtime.detail,
            "Silo verified its coupled runtime. Setup will create its configuration."
        )
        XCTAssertNil(runtime.remediation)
    }

    func testFailedNonHostPreflightDoesNotRegisterHostService() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("silo-bootstrap-preflight-test-\(UUID().uuidString)", isDirectory: true)
        let bin = ToolchainLayout.managedRoot(homeDirectory: temporary)
            .appendingPathComponent("current/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let passingHandshake = #"""
        {"schemaVersion":1,"requestId":"handshake-pass","ok":true,"command":"handshake","observedAt":"2026-08-08T00:00:00Z","result":{"protocolVersion":1,"siloVersion":"test","platform":{"os":"macOS","architecture":"arm64"},"configurationAvailable":true,"runtimeAvailable":true,"capabilities":{"jsonState":true,"jsonMetrics":true,"jsonLogs":true,"plans":true,"bootstrapEvents":true,"jq":true,"workspaceCount":3},"exitCodes":{}},"warnings":[],"error":null}
        """#
        let failingHandshake = #"""
        {"schemaVersion":1,"requestId":"handshake-fail","ok":false,"command":"handshake","observedAt":"2026-08-08T00:00:00Z","result":null,"warnings":[],"error":{"code":"SILO_RUNTIME_UNAVAILABLE","message":"runtime unavailable","recovery":"Repair Silo","workspace":null,"retryable":true}}
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
        let executable = bin.appendingPathComponent("silo")
        let script = """
        #!/bin/sh
        count=0
        if [ -e "\(marker.path)" ]; then count=$(/bin/cat "\(marker.path)"); fi
        count=$((count + 1))
        printf '%s\n' "$count" > "\(marker.path)"
        if [ "$count" -ge 2 ]; then
            /bin/cat "\(failingURL.path)"
        else
            /bin/cat "\(passingURL.path)"
        fi
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let runner = SiloCommandRunner(configuration: .init(
            homeDirectory: temporary,
            additionalSearchPaths: [executable],
            testSiloExecutable: executable
        ))
        let hostService = RecordingHostService()
        let coordinator = BootstrapCoordinator(
            client: SiloClient(runner: runner),
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
            "A failed setup must not publish an unapplied workspace configuration."
        )
        XCTAssertFalse(SetupView.workspaceConfigurationIsApplied(
            SetupWorkspaceConfiguration.defaults,
            persisted: finalState.workspaceConfigurations
        ))
    }


    func testUnsignedBootstrapRepairsHostNetworkingBeforeCLIAndLeavesSSHToTransaction() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("silo-bootstrap-success-test-\(UUID().uuidString)", isDirectory: true)
        let managedToolchainRoot = ToolchainLayout.managedRoot(homeDirectory: temporary)
        let siloBin = managedToolchainRoot.appendingPathComponent("current/bin", isDirectory: true)
        let toolBin = temporary.appendingPathComponent(".local/bin", isDirectory: true)
        let configDirectory = temporary.appendingPathComponent(".config/silo", isDirectory: true)
        try FileManager.default.createDirectory(at: siloBin, withIntermediateDirectories: true)
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
        let hostRepairMarker = temporary.appendingPathComponent("host-repair-complete")
        let bootstrapResponse = #"""
        {"schemaVersion":1,"requestId":"bootstrap-success","ok":true,"command":"bootstrap","observedAt":"2026-08-08T00:00:00Z","result":{"resumed":false,"phase":"complete","requiresApproval":false,"vmsStarted":false,"message":"Setup complete."},"warnings":[],"error":null}
        """#
        try Data(bootstrapResponse.utf8).write(to: bootstrapURL)

        let executable = siloBin.appendingPathComponent("silo")
        let script = """
        #!/bin/sh
        if [ "$1" = "app" ] && [ "$2" = "handshake" ]; then
            printf '%s\\n' '\(protocolCompatibleHandshake)'
        elif [ "$1" = "app" ] && [ "$2" = "bootstrap" ]; then
            [ -f "\(hostRepairMarker.path)" ] || exit 70
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

        let runner = SiloCommandRunner(configuration: .init(
            homeDirectory: temporary,
            testSiloExecutable: executable
        ))
        XCTAssertTrue(
            DefaultSiloConfigurationInstaller.isValidConfiguration(
                at: configDirectory.appendingPathComponent("config.sh")
            )
        )
        let runtimeResolution = await runner.siloResolution(forceRefresh: true)
        XCTAssertEqual(
            runtimeResolution.selected?.standardizedFileURL,
            executable.standardizedFileURL
        )
        let hostService = UnsignedHostService()
        let hostAgent = RecordingHostAgent()
        let userIntegration = RecordingUserIntegration()
        let hostRepair = RecordingHostRepair(markerURL: hostRepairMarker)
        let coordinator = BootstrapCoordinator(
            client: SiloClient(runner: runner),
            runner: runner,
            stateStore: BootstrapStateStore(
                url: temporary.appendingPathComponent("bootstrap-state.json")
            ),
            hostAgent: hostAgent,
            hostService: hostService,
            userIntegration: userIntegration,
            hostRepairVerifier: hostRepair,
            hostRepairAuthorization: hostRepair,
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

        let userIntegrationInvocationCount = await userIntegration.invocationCount
        XCTAssertEqual(
            userIntegrationInvocationCount,
            0,
            "The unsigned-build fallback must leave user SSH integration inside the CLI bootstrap transaction."
        )
        XCTAssertEqual(result.phase, SiloBootstrapState.Phase.complete.rawValue)
        let ensureAliasCount = await hostAgent.ensureAliasInvocationCount
        let installRecordsCount = await hostAgent.installRecordsInvocationCount
        XCTAssertEqual(ensureAliasCount, 0)
        XCTAssertEqual(installRecordsCount, 0)
        XCTAssertEqual(hostService.registerInvocationCount, 0)
        let authorizationRecords = await hostRepair.authorizationRecords
        let verificationRecords = await hostRepair.verificationRecords
        XCTAssertEqual(authorizationRecords.count, 1)
        XCTAssertEqual(
            authorizationRecords.first?.map(\.hostname),
            ["development.silo.test", "personal.silo.test", "lab.silo.test"],
            "The native unsigned-build fallback still owns privileged networking repair for the selected configuration."
        )
        XCTAssertEqual(
            verificationRecords.last?.map(\.hostname),
            ["development.silo.test", "personal.silo.test", "lab.silo.test"],
            "Post-repair verification must inspect the selected configuration before CLI bootstrap begins."
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
            ["app", "bootstrap", "--resume", "--workspace-config-fd", "0", "--events-fd", "3", "--format", "json"]
        )
        let durations = finalState.phaseDurations
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
            Set(persisted.phaseDurations.keys),
            Set(durations.keys),
            "Per-phase timings must survive persistence so a resumed setup can show them."
        )
        let boundary = try JSONDecoder().decode(
            SiloBootstrapConfiguration.self,
            from: Data(contentsOf: bootstrapInputURL)
        )
        XCTAssertEqual(boundary, SiloBootstrapConfiguration(configurations))
        XCTAssertEqual(boundary.workspaces.map(\.name), ["development", "personal", "lab"])
        XCTAssertEqual(boundary.workspaces[1].cpu, 4)
        XCTAssertEqual(boundary.workspaces[1].cpuCeiling, 8)
        XCTAssertEqual(boundary.workspaces[1].workspaceStorageGiB, 80)
        XCTAssertEqual(boundary.workspaces[1].runtimeStorageGiB, 60)
    }
    func testBootstrapInvalidRequestPreservesTypedCLIError() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("silo-bootstrap-mismatch-test-\(UUID().uuidString)", isDirectory: true)
        let siloBin = ToolchainLayout.managedRoot(homeDirectory: temporary)
            .appendingPathComponent("current/bin", isDirectory: true)
        let toolBin = temporary.appendingPathComponent(".local/bin", isDirectory: true)
        let configDirectory = temporary.appendingPathComponent(".config/silo", isDirectory: true)
        try FileManager.default.createDirectory(at: siloBin, withIntermediateDirectories: true)
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
        {"schemaVersion":1,"requestId":"bootstrap-invalid","ok":false,"command":"bootstrap","observedAt":"2026-08-08T00:00:00Z","result":null,"warnings":[],"error":{"code":"SILO_INVALID_REQUEST","message":"The requested 'silo app' command has invalid arguments.","recovery":"See 'silo app help' for the typed command contract.","workspace":null,"retryable":false}}
        """#
        let handshakeURL = temporary.appendingPathComponent("handshake.json")
        let invalidURL = temporary.appendingPathComponent("bootstrap-invalid.json")
        try Data(protocolCompatibleHandshake.utf8).write(to: handshakeURL)
        try Data(invalidRequest.utf8).write(to: invalidURL)

        let executable = siloBin.appendingPathComponent("silo")
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

        let runner = SiloCommandRunner(configuration: .init(
            homeDirectory: temporary,
            testSiloExecutable: executable
        ))
        let coordinator = BootstrapCoordinator(
            client: SiloClient(runner: runner),
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
            XCTFail("Expected SILO_INVALID_REQUEST to fail setup.")
        } catch let error as SiloClientError {
            guard case .protocolFailure(let protocolError) = error else {
                return XCTFail("Unexpected client error: \(error)")
            }
            XCTAssertEqual(protocolError.code, "SILO_INVALID_REQUEST")
        } catch {
            XCTFail("Unexpected bootstrap error: \(error)")
        }

        let finalState = await coordinator.state()
        XCTAssertTrue(finalState.lastError?.contains("SILO_INVALID_REQUEST") == true)
        XCTAssertNil(
            finalState.workspaceConfigurations,
            "A rejected bootstrap must not publish an unapplied configuration."
        )
    }

    func testProtocolErrorDescriptionIncludesRecoveryAndCode() {
        let error = SiloProtocolError(
            code: "SILO_INVALID_REQUEST",
            message: "The requested 'silo app' command has invalid arguments.",
            recovery: "See 'silo app help' for the typed command contract.",
            workspace: nil,
            retryable: false
        )
        let description = error.localizedDescription
        XCTAssertTrue(description.contains("The requested 'silo app' command has invalid arguments."))
        XCTAssertTrue(description.contains("See 'silo app help' for the typed command contract."))
        XCTAssertTrue(description.contains("SILO_INVALID_REQUEST"))
        let withoutRecovery = SiloProtocolError(
            code: "SILO_RUNTIME_UNAVAILABLE",
            message: "runtime unavailable",
            recovery: nil,
            workspace: nil,
            retryable: true
        )
        XCTAssertEqual(withoutRecovery.localizedDescription, "runtime unavailable (Silo error code: SILO_RUNTIME_UNAVAILABLE.)")
    }

    func testProtocolMismatchDescriptionNamesCommandAndSafeDetail() {
        let error = SiloClientError.protocolMismatch(
            command: "bootstrap events",
            detail: "revision has an incompatible type; expected String."
        )

        XCTAssertEqual(
            error.localizedDescription,
            "Silo returned an incompatible protocol response for bootstrap events: " +
                "revision has an incompatible type; expected String."
        )
    }

    func testJSONLFramerSplitsChunksAndFinishesPendingData() throws {
        var framer = SiloJSONLFramer(maxLineBytes: 8, maxBufferedBytes: 16)

        XCTAssertEqual(try framer.append(Data("one\n".utf8)), [Data("one".utf8)])
        XCTAssertEqual(try framer.append(Data("tail".utf8)), [])
        XCTAssertEqual(try framer.finish(), Data("tail".utf8))
    }

    func testJSONLFramerRejectsAnOversizedUnterminatedLine() {
        var framer = SiloJSONLFramer(maxLineBytes: 4, maxBufferedBytes: 16)

        XCTAssertThrowsError(try framer.append(Data("12345".utf8))) { error in
            XCTAssertEqual(
                error as? SiloClientError,
                .unavailable("Silo JSONL line exceeded the capture limit.")
            )
        }
    }

    func testProtocolDecoderRejectsUnsupportedSchemaAndProtocolErrors() {
        let unsupported = Data(
            #"{"schemaVersion":2,"requestId":"req","ok":true,"command":"handshake","observedAt":null,"result":"ok","warnings":[],"error":null}"#.utf8
        )
        XCTAssertThrowsError(
            try SiloProtocolDecoder.decodeEnvelope(unsupported, as: String.self, expectedCommand: "handshake")
        ) { error in
            XCTAssertEqual(error as? SiloClientError, .unsupportedSchema(2))
        }

        let failed = Data(
            #"{"schemaVersion":1,"requestId":"req","ok":false,"command":"state","observedAt":null,"result":null,"warnings":[],"error":{"code":"SILO_CONFIG_MISSING","message":"setup required","recovery":"Run Setup","workspace":null,"retryable":false}}"#.utf8
        )
        XCTAssertThrowsError(
            try SiloProtocolDecoder.decodeEnvelope(failed, as: String.self, expectedCommand: "state")
        ) { error in
            XCTAssertEqual(
                error as? SiloClientError,
                .protocolFailure(
                    SiloProtocolError(
                        code: "SILO_CONFIG_MISSING",
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
            try SiloProtocolDecoder.decodeEnvelope(missingObservation, as: String.self, expectedCommand: "handshake")
        ) { error in
            XCTAssertEqual(error as? SiloClientError, .malformedJSON(command: "handshake"))
        }

        let missingResult = Data(
            #"{"schemaVersion":1,"requestId":"req","ok":true,"command":"handshake","observedAt":"2026-08-08T00:00:00Z","result":null,"warnings":[],"error":null}"#.utf8
        )
        XCTAssertThrowsError(
            try SiloProtocolDecoder.decodeEnvelope(missingResult, as: String.self, expectedCommand: "handshake")
        ) { error in
            XCTAssertEqual(error as? SiloClientError, .malformedJSON(command: "handshake"))
        }

        let extendedEnvelope = Data(
            #"{"schemaVersion":1,"requestId":"req","ok":true,"command":"handshake","observedAt":"2026-08-08T00:00:00Z","result":"ok","warnings":[],"error":null,"futureField":true}"#.utf8
        )
        XCTAssertThrowsError(
            try SiloProtocolDecoder.decodeEnvelope(extendedEnvelope, as: String.self, expectedCommand: "handshake")
        ) { error in
            XCTAssertEqual(error as? SiloClientError, .malformedJSON(command: "handshake"))
        }

        let nullWarnings = Data(
            #"{"schemaVersion":1,"requestId":"req","ok":true,"command":"handshake","observedAt":"2026-08-08T00:00:00Z","result":"ok","warnings":null,"error":null}"#.utf8
        )
        XCTAssertThrowsError(
            try SiloProtocolDecoder.decodeEnvelope(nullWarnings, as: String.self, expectedCommand: "handshake")
        ) { error in
            XCTAssertEqual(error as? SiloClientError, .malformedJSON(command: "handshake"))
        }
    }

    func testProtocolRedactorRemovesBearerTokenAndCredentialURL() {
        let redactor = SiloProtocolRedactor()
        let input = "Authorization: Bearer ghp_secret https://user:password@example.test/repo.git"

        XCTAssertEqual(
            redactor.redact(input),
            "Authorization: [REDACTED] [REDACTED]example.test/repo.git"
        )
    }

    func testProtocolRedactorPreservesStructuredJSONBoundaries() throws {
        let input = #"{"detail":"GH_TOKEN=ghp_secret","next":"ok"}"#
        let redacted = SiloProtocolRedactor().redact(input)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(redacted.utf8)) as? [String: String])

        XCTAssertEqual(object["detail"], "[REDACTED]")
        XCTAssertEqual(object["next"], "ok")
        XCTAssertFalse(redacted.contains("ghp_secret"))
    }
    func testProtocolRedactorRemovesOpaqueJSONCredentialValues() throws {
        let input = #"{"accessToken":"opaque-access","refresh_token":"opaque-refresh","next":"ok"}"#
        let redacted = SiloProtocolRedactor().redact(input)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(redacted.utf8)) as? [String: String])

        XCTAssertEqual(object["accessToken"], "[REDACTED]")
        XCTAssertEqual(object["refresh_token"], "[REDACTED]")
        XCTAssertEqual(object["next"], "ok")
        XCTAssertFalse(redacted.contains("opaque-access"))
        XCTAssertFalse(redacted.contains("opaque-refresh"))
    }
    func testCommandRunnerCapturesOutputAndFiltersCredentialConfiguration() async throws {
        let runner = SiloCommandRunner()
        let command = SiloCommand(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '%s\\n' \"$SILO_TEST_VISIBLE\"; printf '%s' \"${SILO_TEST_TOKEN-unset}\""],
            environment: [
                "SILO_TEST_VISIBLE": "visible",
                "SILO_TEST_TOKEN": "blocked"
            ],
            timeout: .seconds(5)
        )

        let result = try await runner.run(command)

        XCTAssertEqual(result.stdoutString, "visible\nunset")
        XCTAssertFalse(result.stdoutString.contains("blocked"))
    }

    func testCommandRunnerPreservesTypedProgressProtocolFailure() async {
        let runner = SiloCommandRunner()
        let expected = SiloClientError.protocolMismatch(
            command: "bootstrap events",
            detail: "revision has an incompatible type; expected String."
        )
        let command = SiloCommand(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '%s\\n' '{\"schemaVersion\":1}' >&3"],
            timeout: .seconds(5)
        )

        do {
            _ = try await runner.run(
                command,
                eventsFileDescriptor: SiloCommandRunner.progressEventsFileDescriptor
            ) { _ in
                throw expected
            }
            XCTFail("Expected the typed progress protocol failure.")
        } catch let error as SiloClientError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
    func testCommandRunnerAllowsHostRepairControlWithoutCredentialEnvironment() async throws {
        let runner = SiloCommandRunner()
        let result = try await runner.run(
            SiloCommand(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf '%s' \"${SILO_SKIP_HOST_REPAIR-unset}\""],
                environment: ["SILO_SKIP_HOST_REPAIR": "1"],
                timeout: .seconds(5)
            )
        )

        XCTAssertEqual(result.stdoutString, "1")
    }


    func testCommandRunnerRejectsAHandshakeThatIsNotTheExactSchema() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("silo-protocol-repair-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let future = temporary.appendingPathComponent("silo")
        let extendedHandshake = protocolCompatibleHandshake.replacingOccurrences(
            of: #""workspaceCount":3"#,
            with: #""workspaceCount":3,"futureField":true"#
        )
        try Data("#!/bin/sh\nprintf '%s\\n' '\(extendedHandshake)'\n".utf8).write(to: future)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: future.path)
        let runner = SiloCommandRunner(configuration: .init(
            homeDirectory: temporary,
            testSiloExecutable: future
        ))

        let resolution = await runner.siloResolution()
        XCTAssertNil(resolution.selected)
    }

    func testUnsignedDevelopmentBundleExplainsHostServiceRegistrationFailure() {
        XCTAssertEqual(
            SiloHostPackagingInspector.inspect(bundleURL: Bundle.main.bundleURL),
            .signingUnavailable
        )
    }
    func testHostRepairAuthorizationBuildsFixedAdministratorPayload() async throws {
        let recorder = CommandRecorder()
        let authorization = SiloHostRepairAuthorization { command in
            await recorder.record(command)
            return SiloCommandResult(
                status: 0,
                stdout: Data(),
                stderr: Data(),
                duration: .milliseconds(1)
            )
        }

        try await authorization.repair(records: SiloWorkspaceNetwork.fixtureRecords)

        let recordedCommand = await recorder.command
        let command = try XCTUnwrap(recordedCommand)
        XCTAssertEqual(command.executable.path, "/usr/bin/osascript")
        XCTAssertEqual(command.arguments.first, "-e")
        let script = try XCTUnwrap(command.arguments.dropFirst().first)
        XCTAssertTrue(script.contains("with administrator privileges"))
        XCTAssertTrue(script.contains("127.0.0.10 dev.silo.test"))
        XCTAssertTrue(script.contains("127.0.0.11 playgrounds.silo.test"))
        XCTAssertTrue(script.contains("127.0.0.12 personal.silo.test"))
        XCTAssertFalse(script.contains("sudo"))
    }
    func testHostRepairAuthorizationAppleScriptCompilesWithoutRunning() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("silo-host-repair-script-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let output = temporary.appendingPathComponent("repair.scpt")
        let result = try await SiloCommandRunner().run(
            SiloCommand(
                executable: URL(fileURLWithPath: "/usr/bin/osacompile"),
                arguments: ["-o", output.path, "-e", SiloHostRepairAuthorization.appleScriptForTesting],
                timeout: .seconds(5)
            )
        )

        XCTAssertEqual(result.status, 0, result.stderrString)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    func testCommandRunnerReadsOptionalGitIdentity() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("silo-git-identity-\(UUID().uuidString)", isDirectory: true)
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

        let runner = SiloCommandRunner(configuration: .init(
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
            .appendingPathComponent("silo-git-identity-missing-\(UUID().uuidString)", isDirectory: true)
        let git = temporary.appendingPathComponent("bin/git")
        try FileManager.default.createDirectory(
            at: git.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: git)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: git.path)

        let runner = SiloCommandRunner(configuration: .init(
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
            .appendingPathComponent("silo-source-setup-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let hostRepairMarker = root.appendingPathComponent("host-repair-marker")
        let launcher = root.appendingPathComponent("silo")
        let script = """
        #!/bin/sh
        set -eu
        if [ "$1" = app ] && [ "$2" = handshake ]; then
            printf '%s\\n' '\(protocolCompatibleHandshake)'
        else
            printf '%s %s %s\\n' "$1" "$2" "${SILO_SKIP_HOST_REPAIR:-unset}" > "\(hostRepairMarker.path)"
        fi
        """
        try Data(script.utf8).write(to: launcher)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        let service = SiloUserIntegrationService(runner: SiloCommandRunner(configuration: .init(
            homeDirectory: root,
            testSiloExecutable: launcher
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

    func testRuntimePreparationInstallsCLIAndConfigurationWithoutWorkspaceState() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("silo-runtime-preparation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let runner = SiloCommandRunner(configuration: .init(homeDirectory: temporary))
        let coordinator = BootstrapCoordinator(
            client: SiloClient(runner: runner),
            runner: runner,
            stateStore: BootstrapStateStore(url: temporary.appendingPathComponent("bootstrap-state.json")),
            hostService: EnabledHostService()
        )

        try await coordinator.prepareRuntime()

        let selected = await runner.siloResolution().selected?.standardizedFileURL
        let expected = ToolchainLayout.managedRoot(homeDirectory: temporary)
            .appendingPathComponent("current/bin/silo")
            .standardizedFileURL
        XCTAssertEqual(selected, expected)
        XCTAssertTrue(DefaultSiloConfigurationInstaller.isValidConfiguration(
            at: temporary.appendingPathComponent(".config/silo/config.sh")
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: temporary.appendingPathComponent(".config/silo/workspaces.json").path
        ))
    }


    func testCommandRunnerTerminatesTimedOutProcessGroup() async {
        let runner = SiloCommandRunner()
        let command = SiloCommand(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 30"],
            timeout: .milliseconds(100)
        )

        do {
            _ = try await runner.run(command)
            XCTFail("Expected the command to time out.")
        } catch let error as SiloClientError {
            XCTAssertEqual(error, .timedOut(command: "-c"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCommandRunnerExplicitCancellationReportsCancelled() async {
        let runner = SiloCommandRunner()
        let operationID = UUID()
        let command = SiloCommand(
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
        } catch let error as SiloClientError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testWorkspaceURLValidationRejectsMismatchedOrCredentialedURLs() {
        XCTAssertNotNil(AppModel.validatedWorkspaceURL(
            "http://dev.silo.test:3000",
            expectedWorkspace: "dev",
            responseWorkspace: "dev",
            expectedHost: "dev.silo.test",
            expectedPort: "3000",
            expectedScheme: "http"
        ))
        XCTAssertNil(AppModel.validatedWorkspaceURL(
            "http://user:password@dev.silo.test:3000",
            expectedWorkspace: "dev",
            responseWorkspace: "dev",
            expectedHost: "dev.silo.test",
            expectedPort: "3000",
            expectedScheme: "http"
        ))
        XCTAssertNil(AppModel.validatedWorkspaceURL(
            "https://dev.silo.test:3000/path?token=value",
            expectedWorkspace: "dev",
            responseWorkspace: "personal",
            expectedHost: "dev.silo.test",
            expectedPort: "3000",
            expectedScheme: "http"
        ))
        XCTAssertNil(AppModel.validatedWorkspaceURL(
            "http://attacker.example:3000",
            expectedWorkspace: "dev",
            responseWorkspace: "dev",
            expectedHost: "dev.silo.test",
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
            "VERSION", "MANIFEST.txt", "config.sh", "bin/silo", "bin/silo-git-askpass",
            "bin/silo-github-host-token", "bin/silo-github-proxy", "bin/silo-keychain-bridge",
            "bin/silo-ssh-proxy", "launchd/org.silo.Silo.github-proxy.plist",
            "lib/bootstrap-base.sh", "lib/silo-github-relay.py",
            "lib/silo-github-shuttle.py", "lib/silo-port-forwarder.py", "lib/proxy-upstream.py",
            "lib/proxycore.py", "lib/vendor/h11/LICENSE.txt", "lib/vendor/h11/__init__.py",
            "lib/vendor/h11/_abnf.py", "lib/vendor/h11/_connection.py",
            "lib/vendor/h11/_events.py", "lib/vendor/h11/_headers.py",
            "lib/vendor/h11/_readers.py", "lib/vendor/h11/_receivebuffer.py",
            "lib/vendor/h11/_state.py", "lib/vendor/h11/_util.py",
            "lib/vendor/h11/_version.py", "lib/vendor/h11/_writers.py",
            "lib/vendor/h11/py.typed"
        ])
        XCTAssertTrue(validated.manifest.artifacts.first { $0.path == "bin/silo" }?.executable == true)
        XCTAssertTrue(validated.manifest.artifacts.first { $0.path == "config.sh" }?.executable == true)
        XCTAssertTrue(validated.manifest.artifacts.first { $0.path == "lib/proxycore.py" }?.executable == true)
    }

    func testDefaultConfigurationInstallerCreatesAndPreservesSafeConfiguration() throws {
        let bundledRoot = try XCTUnwrap(ToolchainLayout.bundledRoot())
        let source = bundledRoot.appending(path: "payload/config.sh", directoryHint: .notDirectory)
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("silo-default-config-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let destination = try DefaultSiloConfigurationInstaller.installIfNeeded(
            source: source,
            homeDirectory: temporary
        )
        XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: source))
        XCTAssertTrue(DefaultSiloConfigurationInstaller.isValidConfiguration(at: destination))
        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions]
                as? NSNumber
        )
        XCTAssertEqual(permissions.intValue & 0o777, 0o644)

        let customized = Data("# custom configuration\n".utf8)
        try customized.write(to: destination)
        let preserved = try DefaultSiloConfigurationInstaller.installIfNeeded(
            source: source,
            homeDirectory: temporary
        )
        XCTAssertEqual(try Data(contentsOf: preserved), customized)
    }

    func testBundledToolchainManifestRequiresEveryCoupledArtifact() throws {
        let bundledRoot = try XCTUnwrap(ToolchainLayout.bundledRoot())
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("silo-toolchain-incomplete-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: bundledRoot, to: temporary)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let manifestURL = temporary.appendingPathComponent(ToolchainLayout.manifestName)
        let data = try Data(contentsOf: manifestURL)
        var manifest = try JSONDecoder().decode(ToolchainManifest.self, from: data)
        manifest = ToolchainManifest(
            schemaVersion: manifest.schemaVersion,
            version: manifest.version,
            artifacts: manifest.artifacts.filter { $0.path != "lib/silo-github-relay.py" }
        )
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: manifestURL.path)

        XCTAssertThrowsError(try ToolchainValidator.validateBundled(root: temporary)) { error in
            XCTAssertEqual(error as? ToolchainInstallerError, .invalidManifest)
        }
    }

    func testToolchainActivationAtomicallyReplacesCorruptCurrent() async throws {
        let bundledRoot = try XCTUnwrap(ToolchainLayout.bundledRoot())
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("silo-toolchain-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }
        let installer = ToolchainInstaller(bundledRoot: bundledRoot, installationRoot: temporary)

        let first = try await installer.activate()
        try Data("unexpected".utf8).write(to: first.root.appendingPathComponent("unexpected"))
        XCTAssertThrowsError(try ToolchainValidator.validateActivated(root: first.root)) { error in
            XCTAssertEqual(error as? ToolchainInstallerError, .invalidManifest)
        }
        try Data("corrupt".utf8).write(to: first.root.appendingPathComponent("bin/silo"))
        let repaired = try await installer.activate()

        let validated = try ToolchainValidator.validateActivated(root: repaired.root)
        try ToolchainValidator.verifyHandshake(validated)
        XCTAssertEqual(repaired.version, validated.manifest.version)
    }

    func testBundledToolchainRejectsCorruptPayloadBeforeActivation() throws {
        let bundledRoot = try XCTUnwrap(ToolchainLayout.bundledRoot())
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("silo-toolchain-corrupt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: bundledRoot, to: temporary)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }
        try Data("corrupt".utf8).write(to: temporary.appendingPathComponent("payload/bin/silo"))

        XCTAssertThrowsError(try ToolchainValidator.validateBundled(root: temporary)) { error in
            XCTAssertEqual(error as? ToolchainInstallerError, .checksumMismatch("bin/silo"))
        }
    }

    func testBundledToolchainRejectsAReplacementPayloadDirectorySymlink() throws {
        let bundledRoot = try XCTUnwrap(ToolchainLayout.bundledRoot())
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("silo-toolchain-symlink-\(UUID().uuidString)", isDirectory: true)
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
        devLifecycle: SiloLifecycle,
        devQuarantine: SiloQuarantineSnapshot.State,
        observedAt: Date = Date(),
        devStatusObservedAt: Date? = nil
    ) -> SiloEnvelope<SiloStateResponse> {
        let snapshots = Workspace.ID.fixtureDefaults.map { id in
            let quarantine = id == .dev ? devQuarantine : .clear
            return SiloWorkspaceSnapshot(
                id: id.rawValue,
                purpose: "Test workspace",
                lifecycle: id == .dev ? devLifecycle : .stopped,
                freshness: .fresh,
                quarantine: SiloQuarantineSnapshot(
                    state: quarantine,
                    reason: quarantine == .clear ? nil : "Test quarantine"
                ),
                secrets: SiloSecretsSnapshot(state: .active, pendingCount: 0, reason: nil),
                resources: SiloResourceSnapshot(
                    cpus: "2",
                    maxCpus: "8",
                    memory: "4GiB",
                    maxMemory: "16GiB",
                    rootDisk: "20GiB"
                ),
                network: SiloNetworkSnapshot(
                    host: "\(id.rawValue).silo.test",
                    ip: "127.0.0.10"
                ),
                actionCapabilities: SiloActionCapabilities(
                    canStart: true,
                    canStop: true,
                    canRestart: true,
                    canOpenTerminal: true,
                    canPush: true
                ),
                statusObservedAt: id == .dev ? devStatusObservedAt : nil,
                skippedPorts: [],
                portWarning: ""
            )
        }
        return SiloEnvelope(
            schemaVersion: 1,
            requestId: "state-test",
            ok: true,
            command: "state",
            observedAt: observedAt,
            result: SiloStateResponse(
                schemaVersion: 1,
                siloVersion: "test",
                workspaces: snapshots
            )
        )
    }

    private func testJSON<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    private func makeLifecycleVerificationModel(
        action: SiloLifecycleAction,
        initial: (SiloLifecycle, Date),
        observations: [(SiloLifecycle, Date, Double)],
        applyObservedAt: Date,
        delays: [Duration],
        observationStatusObservedAts: [Date]? = nil,
        failingObservationIndices: Set<Int> = [],
        applyFailure: SiloProtocolError? = nil,
        applyReconciled: Bool = true,
        applyDelay: Double = 0
    ) throws -> AppModel {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("silo-lifecycle-verification-\(UUID().uuidString)", isDirectory: true)
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
        let plan = SiloLifecyclePlan(
            planId: "plan-\(action.rawValue)",
            action: action.rawValue,
            workspace: "dev",
            expiresAt: Date().addingTimeInterval(300),
            confirmationPhrase: "\(action.rawValue.uppercased()) dev",
            effects: "Testing \(action.rawValue)."
        )
        try encoder.encode(SiloEnvelope(
            schemaVersion: 1,
            requestId: "plan-\(action.rawValue)",
            ok: true,
            command: "plan",
            observedAt: applyObservedAt,
            result: plan
        )).write(to: temporary.appendingPathComponent("plan.json"))
        let applyEnvelope = SiloEnvelope<SiloApplyResult>(
            schemaVersion: 1,
            requestId: "apply-\(action.rawValue)",
            ok: applyFailure == nil,
            command: "apply",
            observedAt: applyFailure == nil ? applyObservedAt : nil,
            result: applyFailure == nil
                ? SiloApplyResult(
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
        let executable = temporary.appendingPathComponent("silo")
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

        let client = SiloClient(runner: SiloCommandRunner(configuration: .init(
            homeDirectory: temporary,
            testSiloExecutable: executable
        )))
        return AppModel(
            client: client,
            operationCoordinator: SiloOperationCoordinator(client: client),
            lifecycleVerificationDelays: delays
        )
    }

    private func beginConfirmedLifecycle(
        _ action: SiloLifecycleAction,
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

    private func waitForLifecycleCompletion(in model: AppModel) async throws -> SiloOperationState {
        for _ in 0..<160 {
            if model.operationStates["lifecycle:dev"]?.phase == .finished { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let operation = try XCTUnwrap(model.operationStates["lifecycle:dev"])
        XCTAssertEqual(operation.phase, .finished)
        return operation
    }

    func testSetupPlanHasStableOrderLabelsAndVerificationDependencies() {
        let state = SetupState()
        XCTAssertEqual(state.items.map(\.id), SetupPlan.orderedIDs)
        XCTAssertEqual(
            state.items.map(\.label),
            [
                "Create workspaces",
                "Verify workspaces",
                "Save GitHub access",
                "Verify GitHub access",
                "Save Git identity",
                "Verify Git identity",
                "Finish setup"
            ]
        )

        let revision = state.submitWorkspaces(SetupWorkspaceConfiguration.defaults)
        XCTAssertFalse(state.begin(.workspaceVerify, revision: revision))
        XCTAssertTrue(state.begin(.workspaceRun, revision: revision))
        XCTAssertFalse(state.begin(.workspaceVerify, revision: revision))
        XCTAssertEqual(state.items.filter { $0.status == .running }.count, 1)
        XCTAssertEqual(state.currentLabel, "Create workspaces")
        state.succeed(.workspaceRun, revision: revision)
        XCTAssertTrue(state.begin(.workspaceVerify, revision: revision))
        XCTAssertEqual(state.currentLabel, "Verify workspaces")
    }

    func testSetupQueueRetryRetainsLaterInputsAndResumesFailedItem() {
        let state = SetupState()
        let revision = state.submitWorkspaces(SetupWorkspaceConfiguration.defaults)
        let identity = SetupIdentityQueueInput(
            name: "Taylor Example",
            email: "taylor@example.com",
            target: nil
        )
        state.submitIdentity(identity)
        XCTAssertTrue(state.begin(.workspaceRun, revision: revision))
        state.fail(.workspaceRun, message: "registration rejected", revision: revision)

        XCTAssertEqual(state.retryFailedItem(), .workspaceRun)
        XCTAssertEqual(state.item(.workspaceRun).status, .queued)
        XCTAssertEqual(state.item(.identityRun).input, .identity(identity))
        XCTAssertEqual(state.item(.identityVerify).input, .identity(identity))
        XCTAssertTrue(state.begin(.workspaceRun, revision: revision))
    }

    func testSetupQueueConsumesStringRevisionAtCapturedCandidateRevision() throws {
        let state = SetupState()
        let staleRevision = state.submitWorkspaces(SetupWorkspaceConfiguration.defaults)
        let currentRevision = state.submitWorkspaces(SetupWorkspaceConfiguration.defaults)
        XCTAssertTrue(state.begin(.workspaceRun, revision: currentRevision))
        let protocolRevision = String(repeating: "a", count: 64)
        let event = try JSONDecoder().decode(
            SiloProgressEvent.self,
            from: Data(
                """
                {"schemaVersion":1,"type":"progress","requestId":"setup","phase":"running",\
                "step":"verification","workspace":"dev","revision":"\(protocolRevision)",\
                "fraction":0.5,"message":"Verifying","safeForDisplay":true}
                """.utf8
            )
        )
        XCTAssertEqual(event.revision, protocolRevision)

        state.consume(event, candidateRevision: staleRevision)
        XCTAssertEqual(state.item(.workspaceRun).status, .running)
        XCTAssertEqual(state.item(.workspaceVerify).status, .queued)

        state.consume(event, candidateRevision: currentRevision)
        XCTAssertEqual(state.item(.workspaceRun).status, .succeeded)
        XCTAssertEqual(state.item(.workspaceVerify).status, .running)
        XCTAssertEqual(state.currentLabel, "Verify workspaces")
    }

    func testProgressEventRejectsNumericRevision() {
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                SiloProgressEvent.self,
                from: Data(
                    #"{"schemaVersion":1,"type":"progress","requestId":"setup","phase":"running","revision":1,"fraction":0.5,"message":"Verifying","safeForDisplay":true}"#.utf8
                )
            )
        ) { error in
            guard case DecodingError.typeMismatch(_, let context) = error else {
                return XCTFail("Expected revision type mismatch, got \(error)")
            }
            XCTAssertEqual(context.codingPath.map(\.stringValue), ["revision"])
        }
    }

    func testSetupQueueRejectsStaleRevisionAndDerivesDoneFromFinalItem() {
        let state = SetupState()
        let staleRevision = state.submitWorkspaces(SetupWorkspaceConfiguration.defaults)
        let currentRevision = state.submitWorkspaces(SetupWorkspaceConfiguration.defaults)
        XCTAssertFalse(state.begin(.workspaceRun, revision: staleRevision))
        XCTAssertTrue(state.begin(.workspaceRun, revision: currentRevision))
        state.succeed(.workspaceRun, revision: currentRevision)
        XCTAssertTrue(state.begin(.workspaceVerify, revision: currentRevision))
        state.succeed(.workspaceVerify, revision: currentRevision)
        state.submitGitHubSkip()
        state.submitIdentitySkip()
        state.deriveCompletion(requirementsSatisfied: true)
        XCTAssertTrue(state.isDone)
    }

    func testBootstrapStateRequiresPhaseDurations() throws {
        var state = SiloBootstrapState.initial
        state.updatedAt = Date(timeIntervalSince1970: 0)
        let data = try JSONEncoder().encode(state)
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object.removeValue(forKey: "phaseDurations")
        XCTAssertThrowsError(try JSONDecoder().decode(
            SiloBootstrapState.self,
            from: try JSONSerialization.data(withJSONObject: object)
        ))
    }

    func testSetupLifecycleIsCurrentOnlyWhileUntouched() {
        let gate = SetupLifecycleGate()
        let captured = gate.generation
        XCTAssertTrue(gate.isCurrent(captured))
        gate.invalidate()
        XCTAssertFalse(gate.isCurrent(captured))
        XCTAssertTrue(gate.isCurrent(gate.generation))
    }

    func testRepositoryPolicyCarriesStableIdentityAndDefaultsReadOnly() throws {
        let policy = GitHubRepositoryPolicy(
            workspace: "dev",
            repositoryID: 101,
            fullName: "acme/one",
            ownerID: 7,
            ownerLogin: "acme",
            ownerType: "Organization"
        )
        let data = try JSONEncoder().encode(policy)
        let decoded = try JSONDecoder().decode(GitHubRepositoryPolicy.self, from: data)
        XCTAssertEqual(decoded, policy)
        XCTAssertEqual(decoded.id, "dev.7.101")
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
            verificationsAllowCompletion: true,
            registrationOutstanding: false
        ), "Persisted completed choices must not enable Review/Done before the GitHub context loads.")
        XCTAssertTrue(SetupView.allowsReviewCompletion(
            contextLoaded: true,
            systemReady: true,
            githubDecided: true,
            identityDecided: true,
            verificationsAllowCompletion: true,
            registrationOutstanding: false
        ))
        XCTAssertFalse(SetupView.allowsReviewCompletion(
            contextLoaded: true,
            systemReady: true,
            githubDecided: false,
            identityDecided: true,
            verificationsAllowCompletion: true,
            registrationOutstanding: false
        ))
        XCTAssertFalse(SetupView.allowsReviewCompletion(
            contextLoaded: true,
            systemReady: false,
            githubDecided: true,
            identityDecided: true,
            verificationsAllowCompletion: true,
            registrationOutstanding: false
        ))
        XCTAssertFalse(SetupView.allowsReviewCompletion(
            contextLoaded: true,
            systemReady: true,
            githubDecided: true,
            identityDecided: true,
            verificationsAllowCompletion: false,
            registrationOutstanding: false
        ), "Review must block completion until security verification succeeds.")
        XCTAssertFalse(SetupView.allowsReviewCompletion(
            contextLoaded: true,
            systemReady: true,
            githubDecided: true,
            identityDecided: true,
            verificationsAllowCompletion: true,
            registrationOutstanding: true
        ), "Review must block completion while workspace registration is queued or running.")
    }

    func testWorkspaceContinueRequiresOnlyValidLoadedInput() {
        XCTAssertTrue(SetupView.canSubmitWorkspaceConfiguration(
            validationMessage: nil,
            bootstrapInputReady: true
        ), "Background registration must not turn Workspaces Continue into an operation gate.")
        XCTAssertFalse(SetupView.canSubmitWorkspaceConfiguration(
            validationMessage: "Workspace names must be unique.",
            bootstrapInputReady: true
        ))
        XCTAssertFalse(SetupView.canSubmitWorkspaceConfiguration(
            validationMessage: nil,
            bootstrapInputReady: false
        ))
    }

    func testIdentityContinueRequiresClientAvailabilityAndValidIdentity() {
        XCTAssertTrue(SetupView.allowsIdentitySave(
            clientAvailable: true,
            name: "Taylor Example",
            email: "taylor@example.com"
        ))
        XCTAssertFalse(SetupView.allowsIdentitySave(
            clientAvailable: false,
            name: "Taylor Example",
            email: "taylor@example.com"
        ), "A valid identity still requires the current Silo client dependency.")
        XCTAssertFalse(SetupView.allowsIdentitySave(
            clientAvailable: true,
            name: "   ",
            email: "taylor@example.com"
        ))
        XCTAssertFalse(SetupView.allowsIdentitySave(
            clientAvailable: true,
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
            SiloBootstrapConfiguration(SetupWorkspaceConfiguration.defaults)
        )
        XCTAssertNotNil(SiloBootstrapConfiguration.decodeValidated(from: valid))

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: valid) as? [String: Any]
        )
        var workspaces = try XCTUnwrap(object["workspaces"] as? [[String: Any]])
        workspaces[0]["host"] = "$(touch should-never-run)"
        object["workspaces"] = workspaces
        let unknownWorkspaceField = try JSONSerialization.data(withJSONObject: object)
        XCTAssertNil(SiloBootstrapConfiguration.decodeValidated(from: unknownWorkspaceField))

        object["unexpected"] = true
        let unknownRootField = try JSONSerialization.data(withJSONObject: object)
        XCTAssertNil(SiloBootstrapConfiguration.decodeValidated(from: unknownRootField))
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
            .appendingPathComponent("silo-model-target-reload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }
        let stateLine = String(decoding: try testJSON(makeTestStateEnvelope(
            devLifecycle: .stopped,
            devQuarantine: .clear
        )), as: UTF8.self)
        let executable = temporary.appendingPathComponent("silo")
        try Data("#!/bin/sh\nprintf '%s\\n' '\(stateLine)'\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let client = SiloClient(runner: SiloCommandRunner(configuration: .init(
            homeDirectory: temporary,
            testSiloExecutable: executable
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


    private let expected: [SiloWorkspaceNetworkRecord] = [
        SiloWorkspaceNetworkRecord(address: "127.0.0.10", hostname: "dev.silo.test"),
        SiloWorkspaceNetworkRecord(address: "127.0.0.11", hostname: "playgrounds.silo.test"),
        SiloWorkspaceNetworkRecord(address: "127.0.0.12", hostname: "personal.silo.test")
    ]

    func testManagedBlockMatches() {
        let text = """
        127.0.0.1 localhost
        # BEGIN SILO MANAGED HOSTS
        127.0.0.10 dev.silo.test
        127.0.0.11 playgrounds.silo.test
        127.0.0.12 personal.silo.test
        # END SILO MANAGED HOSTS
        """
        XCTAssertTrue(SiloHostRepairVerifier.managedHostsMatch(text, expected: expected))
    }

    func testMissingBlockFails() {
        let text = """
        127.0.0.1 localhost
        127.0.0.10 dev.silo.test
        """
        XCTAssertFalse(SiloHostRepairVerifier.managedHostsMatch(text, expected: expected))
    }

    func testMismatchedRecordsFail() {
        let text = """
        # BEGIN SILO MANAGED HOSTS
        127.0.0.10 dev.silo.test
        127.0.0.11 playgrounds.silo.local
        127.0.0.12 personal.silo.test
        # END SILO MANAGED HOSTS
        """
        XCTAssertFalse(SiloHostRepairVerifier.managedHostsMatch(text, expected: expected))
    }

    func testReorderedRecordsFail() {
        let text = """
        # BEGIN SILO MANAGED HOSTS
        127.0.0.12 personal.silo.test
        127.0.0.10 dev.silo.test
        127.0.0.11 playgrounds.silo.test
        # END SILO MANAGED HOSTS
        """
        XCTAssertFalse(SiloHostRepairVerifier.managedHostsMatch(text, expected: expected))
    }

    func testDuplicateManagedBlocksFail() {
        let text = """
        # BEGIN SILO MANAGED HOSTS
        127.0.0.10 dev.silo.test
        # END SILO MANAGED HOSTS
        # BEGIN SILO MANAGED HOSTS
        127.0.0.11 playgrounds.silo.test
        # END SILO MANAGED HOSTS
        """
        XCTAssertFalse(SiloHostRepairVerifier.managedHostsMatch(text, expected: expected))
    }

    func testStrayManagedMarkerFails() {
        let text = """
        # BEGIN SILO MANAGED HOSTS
        127.0.0.10 dev.silo.test
        127.0.0.11 playgrounds.silo.test
        127.0.0.12 personal.silo.test
        # END SILO MANAGED HOSTS
        # END SILO MANAGED HOSTS
        """
        XCTAssertFalse(SiloHostRepairVerifier.managedHostsMatch(text, expected: expected))
    }
}
