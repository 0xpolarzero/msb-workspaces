import Foundation

struct SiloPushReview: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let workspace: String
    let repositoryPath: String
    let branch: String
    let localCommit: String
    let remoteCommit: String?
    let aheadCount: Int
    let behindCount: Int
    let warning: String?
    let confirmationPhrase: String
}

enum SiloOperationServiceError: Error, LocalizedError, Sendable, Equatable {
    case invalidWorkspace
    case repositoryUnavailable
    case pushBlocked
    case unsupportedURL

    var errorDescription: String? {
        switch self {
        case .invalidWorkspace: return "The workspace identifier is invalid."
        case .repositoryUnavailable: return "The repository state is unavailable; refresh before continuing."
        case .pushBlocked: return "Silo policy does not allow a push for this repository state."
        case .unsupportedURL: return "Silo returned a URL with an unsupported scheme."
        }
    }
}

actor SiloOperationService {
    private let client: SiloClient
    private let coordinator: SiloOperationCoordinator

    init(client: SiloClient, coordinator: SiloOperationCoordinator? = nil) {
        self.client = client
        self.coordinator = coordinator ?? SiloOperationCoordinator(client: client)
    }

    func state(workspace: String? = nil) async throws -> SiloStateResponse {
        let response = try await client.state(workspace: workspace)
        guard let result = response.result else { throw SiloClientError.missingResult(command: "state") }
        return result
    }

    func repositories(workspace: String, includeWorktreeStatus: Bool = true) async throws -> SiloRepositoriesResponse {
        guard WorkspaceID.isValid(workspace) else { throw SiloOperationServiceError.invalidWorkspace }
        let response = try await client.repositories(workspace: workspace, ifRunning: true, includeWorktreeStatus: includeWorktreeStatus)
        guard let result = response.result else { throw SiloClientError.missingResult(command: "repositories") }
        return result
    }

    func metrics(workspace: String) async throws -> SiloMetricsResponse {
        guard WorkspaceID.isValid(workspace) else { throw SiloOperationServiceError.invalidWorkspace }
        let response = try await client.metrics(workspace: workspace)
        guard let result = response.result else { throw SiloClientError.missingResult(command: "metrics") }
        return result
    }
    func logs(workspace: String) async throws -> SiloLogsResponse {
        guard WorkspaceID.isValid(workspace) else { throw SiloOperationServiceError.invalidWorkspace }
        return try await client.logs(workspace: workspace)
    }

    func ports(workspace: String? = nil) async throws -> SiloPortsResponse {
        let response = try await client.ports(workspace: workspace)
        guard let result = response.result else { throw SiloClientError.missingResult(command: "ports") }
        return result
    }

    func githubState(workspace: String? = nil) async throws -> SiloGitHubStateResponse {
        let response = try await client.githubState(workspace: workspace)
        guard let result = response.result else { throw SiloClientError.missingResult(command: "github-state") }
        return result
    }

    func lifecycle(_ action: SiloLifecycleAction, workspace: String) async throws -> SiloApplyResult {
        (try await coordinator.lifecycle(action, workspace: workspace)).result
    }
 
    func pushPlan(workspace: String, repositories: [String]) async throws -> SiloPushPlan {
        guard WorkspaceID.isValid(workspace), !repositories.isEmpty else {
            throw SiloOperationServiceError.repositoryUnavailable
        }
        let response = try await client.preparePushPlan(workspace: workspace, repositories: repositories)
        guard let plan = response.result else { throw SiloClientError.missingResult(command: "push-plan") }
        return plan
    }

    func applyPushPlan(_ plan: SiloPushPlan, confirmation: String) async throws -> SiloPushApplyResult {
        let result = try await coordinator.applyPushPlan(plan, confirmation: confirmation)
        guard result.pushed, result.reconciled else { throw SiloOperationServiceError.pushBlocked }
        return result
    }


    func pushReview(workspace: String, repository: SiloRepositorySnapshot) throws -> SiloPushReview {
        guard WorkspaceID.isValid(workspace), let branch = repository.branch, let localCommit = repository.localCommit else {
            throw SiloOperationServiceError.repositoryUnavailable
        }
        guard repository.pushability == .pushable || repository.pushability == .publish else { throw SiloOperationServiceError.pushBlocked }
        guard repository.pushability == .publish || repository.aheadCount > 0 else { throw SiloOperationServiceError.pushBlocked }
        let warning = repository.worktreeState == .localChanges ? "Uncommitted changes will not be included." : nil
        return SiloPushReview(
            id: UUID(), workspace: workspace, repositoryPath: repository.path, branch: branch,
            localCommit: localCommit, remoteCommit: repository.remoteCommit, aheadCount: repository.aheadCount,
            behindCount: repository.behindCount, warning: warning, confirmationPhrase: "PUSH"
        )
    }
}



struct SiloDiagnosticCheck: Codable, Sendable, Equatable, Identifiable {
    enum Status: String, Codable, Sendable { case pass, failed, unavailable }
    let id: String
    let title: String
    let status: Status
    let detail: String
    let recovery: String?
}

struct SiloBackupResult: Codable, Sendable, Equatable {
    let archive: URL
    let archiveBytes: Int64
    let completedAt: Date
    let checksum: URL?
    let stoppedWorkspaces: [String]
    let restartedWorkspaces: [String]

    var workspacesNeedingRestart: [String] {
        Array(Set(stoppedWorkspaces).subtracting(restartedWorkspaces)).sorted()
    }
}

struct SiloBackupEstimate: Codable, Sendable, Equatable {
    let lowerBytes: Int64
    let upperBytes: Int64
    let basisRatio: Double
    let changedSourceRatio: Double
    let provenance: String
}

struct SiloBackupPreview: Codable, Sendable, Equatable {
    let destination: URL
    let sourceAllocatedBytes: Int64
    let archiveEstimate: SiloBackupEstimate?
    let runningWorkspaces: [String]
}

struct SiloBackupOperation: Codable, Sendable, Equatable, Identifiable {
    enum State: String, Codable, Sendable { case queued, running, completed, failed }
    enum Phase: String, Codable, Sendable {
        case preparing
        case archiveWriting = "archive-writing"
        case checksumming
        case finalizing
        case completed
        case failed
    }

    let id: String
    let requestKey: String
    let state: State
    let phase: Phase
    let message: String
    let destination: URL
    let startedAt: Date
    let updatedAt: Date
    let completedAt: Date?
    let elapsedSeconds: Int64
    let ownerPID: Int32?
    let ownerProcessState: String
    let sourceAllocatedBytes: Int64
    let archiveEstimate: SiloBackupEstimate?
    let processedBytes: Int64
    let writtenBytes: Int64
    let throughputBytesPerSecond: Int64
    let totalBytes: Int64?
    let etaSeconds: Int64?
    let result: SiloBackupResult?
    let error: SiloBackupOperationErrorResponse?
    let warnings: [String]
}

actor SiloDiagnostics {
    private let client: SiloClient

    init(client: SiloClient) {
        self.client = client
    }


    func previewBackup(to directory: URL) async throws -> SiloBackupPreview {
        try validateDirectory(directory)
        let envelope = try await client.previewBackup(directory: directory)
        guard let result = envelope.result else { throw SiloClientError.missingResult(command: "backup-preview") }
        let selectedDestination = directory.resolvingSymlinksInPath().standardizedFileURL
        let previewDestination = URL(fileURLWithPath: result.destination)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard result.destination.hasPrefix("/"),
              !result.destination.contains("\0"),
              previewDestination.path == selectedDestination.path,
              result.sourceAllocatedBytes > 0,
              result.archiveEstimate.map({
                  $0.lowerBytes > 0 && $0.upperBytes >= $0.lowerBytes &&
                    $0.basisRatio > 0 && $0.changedSourceRatio > 0 && !$0.provenance.isEmpty
              }) ?? true,
              Set(result.runningWorkspaces).count == result.runningWorkspaces.count,
              result.runningWorkspaces.allSatisfy(WorkspaceID.isValid) else {
            throw SiloClientError.malformedJSON(command: "backup-preview")
        }
        return SiloBackupPreview(
            destination: previewDestination,
            sourceAllocatedBytes: result.sourceAllocatedBytes,
            archiveEstimate: result.archiveEstimate.map {
                SiloBackupEstimate(
                    lowerBytes: $0.lowerBytes,
                    upperBytes: $0.upperBytes,
                    basisRatio: $0.basisRatio,
                    changedSourceRatio: $0.changedSourceRatio,
                    provenance: $0.provenance
                )
            },
            runningWorkspaces: result.runningWorkspaces
        )
    }

    func startBackup(to directory: URL, requestKey: String) async throws -> SiloBackupOperation {
        try validateDirectory(directory)
        let envelope = try await client.startBackup(directory: directory, requestKey: requestKey)
        guard let result = envelope.result else { throw SiloClientError.missingResult(command: "backup-start") }
        return try validate(result, command: "backup-start")
    }

    func listBackups() async throws -> [SiloBackupOperation] {
        let envelope = try await client.listBackups()
        guard let results = envelope.result else { throw SiloClientError.missingResult(command: "backup-list") }
        let operations = try results.map { try validate($0, command: "backup-list") }
        guard Set(operations.map(\.id)).count == operations.count else {
            throw SiloClientError.malformedJSON(command: "backup-list")
        }
        return operations
    }

    func backupStatus(id: String) async throws -> SiloBackupOperation {
        let envelope = try await client.backupStatus(id: id)
        guard let result = envelope.result else { throw SiloClientError.missingResult(command: "backup-status") }
        return try validate(result, command: "backup-status")
    }

    func restore(archive: URL, confirmation: String) async throws {
        guard confirmation == "RESTORE", archive.pathExtension == "zst", FileManager.default.fileExists(atPath: archive.path) else {
            throw SiloClientError.invalidArguments
        }
        let envelope = try await client.restore(archive: archive, confirmation: confirmation)
        guard envelope.result != nil else { throw SiloClientError.missingResult(command: "restore") }
    }

    private func validateDirectory(_ directory: URL) throws {
        guard directory.isFileURL,
              directory.path.hasPrefix("/"),
              directory.path.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw SiloClientError.invalidArguments
        }
    }

    private func validate(_ value: SiloBackupOperationResponse, command: String) throws -> SiloBackupOperation {
        guard value.kind == "backup",
              value.operationId.range(of: #"^[a-z0-9-]{8,64}$"#, options: .regularExpression) != nil,
              value.requestKey.range(of: #"^[A-Za-z0-9._-]{1,128}$"#, options: .regularExpression) != nil,
              let state = SiloBackupOperation.State(rawValue: value.state),
              let phase = SiloBackupOperation.Phase(rawValue: value.phase),
              !value.message.isEmpty,
              value.destination.hasPrefix("/"), !value.destination.contains("\0"),
              value.updatedAt >= value.startedAt, value.elapsedSeconds >= 0,
              value.ownerPid.map({ $0 > 1 }) ?? true,
              value.sourceAllocatedBytes > 0,
              value.archiveEstimate.map({
                  $0.lowerBytes > 0 && $0.upperBytes >= $0.lowerBytes &&
                    $0.basisRatio > 0 && $0.changedSourceRatio > 0 && !$0.provenance.isEmpty
              }) ?? true,
              Set(value.runningWorkspaces).count == value.runningWorkspaces.count,
              value.runningWorkspaces.allSatisfy(WorkspaceID.isValid),
              value.progress.processedBytes >= 0, value.progress.writtenBytes >= 0,
              value.progress.throughputBytesPerSecond >= 0,
              value.progress.totalBytes.map({ $0 > 0 }) ?? true,
              value.progress.totalBytes.map({ value.progress.processedBytes <= $0 }) ?? true,
              value.progress.etaSeconds == nil || value.progress.totalBytes != nil,
              value.progress.etaSeconds.map({ $0 >= 0 }) ?? true else {
            throw SiloClientError.malformedJSON(command: command)
        }
        let result: SiloBackupResult?
        if let final = value.result {
            guard final.archive.hasPrefix("/"), !final.archive.contains("\0"), final.archiveBytes > 0,
                  final.checksum.hasPrefix("/"), !final.checksum.contains("\0"),
                  final.info.hasPrefix("/"), !final.info.contains("\0"),
                  Set(final.stoppedWorkspaces).count == final.stoppedWorkspaces.count,
                  Set(final.restartedWorkspaces).isSubset(of: Set(final.stoppedWorkspaces)),
                  final.stoppedWorkspaces == value.runningWorkspaces,
                  final.stoppedWorkspaces.allSatisfy(WorkspaceID.isValid),
                  final.restartedWorkspaces.allSatisfy(WorkspaceID.isValid) else {
                throw SiloClientError.malformedJSON(command: command)
            }
            result = SiloBackupResult(
                archive: URL(fileURLWithPath: final.archive), archiveBytes: final.archiveBytes,
                completedAt: final.completedAt, checksum: URL(fileURLWithPath: final.checksum),
                stoppedWorkspaces: final.stoppedWorkspaces, restartedWorkspaces: final.restartedWorkspaces
            )
        } else {
            result = nil
        }
        let phaseMatchesState = switch state {
        case .queued: phase == .preparing
        case .running: phase == .preparing || phase == .archiveWriting || phase == .checksumming || phase == .finalizing
        case .completed: phase == .completed
        case .failed: phase == .failed
        }
        guard phaseMatchesState,
              (state == .completed) == (result != nil),
              (state == .completed) == (phase == .completed),
              (state == .failed) == (value.error != nil),
              (state == .failed) == (phase == .failed),
              (state == .completed || state == .failed) == (value.completedAt != nil),
              (state == .queued || state == .running) == (result == nil && value.error == nil),
              result.map({ value.progress.writtenBytes == $0.archiveBytes }) ?? true else {
            throw SiloClientError.malformedJSON(command: command)
        }
        return SiloBackupOperation(
            id: value.operationId, requestKey: value.requestKey, state: state, phase: phase,
            message: value.message, destination: URL(fileURLWithPath: value.destination),
            startedAt: value.startedAt, updatedAt: value.updatedAt, completedAt: value.completedAt,
            elapsedSeconds: value.elapsedSeconds, ownerPID: value.ownerPid,
            ownerProcessState: value.ownerProcessState, sourceAllocatedBytes: value.sourceAllocatedBytes,
            archiveEstimate: value.archiveEstimate.map {
                SiloBackupEstimate(lowerBytes: $0.lowerBytes, upperBytes: $0.upperBytes,
                    basisRatio: $0.basisRatio, changedSourceRatio: $0.changedSourceRatio,
                    provenance: $0.provenance)
            }, processedBytes: value.progress.processedBytes, writtenBytes: value.progress.writtenBytes,
            throughputBytesPerSecond: value.progress.throughputBytesPerSecond,
            totalBytes: value.progress.totalBytes, etaSeconds: value.progress.etaSeconds,
            result: result, error: value.error, warnings: value.warnings
        )
    }

}
