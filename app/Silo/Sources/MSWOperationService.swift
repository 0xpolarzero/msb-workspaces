import Foundation

struct MSWPushReview: Codable, Sendable, Equatable, Identifiable {
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

enum MSWOperationServiceError: Error, LocalizedError, Sendable, Equatable {
    case invalidWorkspace
    case repositoryUnavailable
    case pushBlocked
    case unsupportedURL

    var errorDescription: String? {
        switch self {
        case .invalidWorkspace: return "The workspace identifier is invalid."
        case .repositoryUnavailable: return "The repository state is unavailable; refresh before continuing."
        case .pushBlocked: return "MSW policy does not allow a push for this repository state."
        case .unsupportedURL: return "MSW returned a URL with an unsupported scheme."
        }
    }
}

actor MSWOperationService {
    private let client: MSWClient
    private let coordinator: MSWOperationCoordinator

    init(client: MSWClient, coordinator: MSWOperationCoordinator? = nil) {
        self.client = client
        self.coordinator = coordinator ?? MSWOperationCoordinator(client: client)
    }

    func state(workspace: String? = nil) async throws -> MSWStateResponse {
        let response = try await client.state(workspace: workspace)
        guard let result = response.result else { throw MSWClientError.missingResult(command: "state") }
        return result
    }

    func repositories(workspace: String, includeWorktreeStatus: Bool = true) async throws -> MSWRepositoriesResponse {
        guard WorkspaceID.isValid(workspace) else { throw MSWOperationServiceError.invalidWorkspace }
        let response = try await client.repositories(workspace: workspace, ifRunning: true, includeWorktreeStatus: includeWorktreeStatus)
        guard let result = response.result else { throw MSWClientError.missingResult(command: "repositories") }
        return result
    }

    func metrics(workspace: String) async throws -> MSWMetricsResponse {
        guard WorkspaceID.isValid(workspace) else { throw MSWOperationServiceError.invalidWorkspace }
        let response = try await client.metrics(workspace: workspace)
        guard let result = response.result else { throw MSWClientError.missingResult(command: "metrics") }
        return result
    }
    func logs(workspace: String) async throws -> MSWLogsResponse {
        guard WorkspaceID.isValid(workspace) else { throw MSWOperationServiceError.invalidWorkspace }
        return try await client.logs(workspace: workspace)
    }

    func ports(workspace: String? = nil) async throws -> MSWPortsResponse {
        let response = try await client.ports(workspace: workspace)
        guard let result = response.result else { throw MSWClientError.missingResult(command: "ports") }
        return result
    }

    func githubState(workspace: String? = nil) async throws -> MSWGitHubStateResponse {
        let response = try await client.githubState(workspace: workspace)
        guard let result = response.result else { throw MSWClientError.missingResult(command: "github-state") }
        return result
    }

    func lifecycle(_ action: MSWLifecycleAction, workspace: String) async throws -> MSWApplyResult {
        (try await coordinator.lifecycle(action, workspace: workspace)).result
    }
 
    func pushPlan(workspace: String, repositories: [String]) async throws -> MSWPushPlan {
        guard WorkspaceID.isValid(workspace), !repositories.isEmpty else {
            throw MSWOperationServiceError.repositoryUnavailable
        }
        let response = try await client.preparePushPlan(workspace: workspace, repositories: repositories)
        guard let plan = response.result else { throw MSWClientError.missingResult(command: "push-plan") }
        return plan
    }

    func applyPushPlan(_ plan: MSWPushPlan, confirmation: String) async throws -> MSWPushApplyResult {
        let result = try await coordinator.applyPushPlan(plan, confirmation: confirmation)
        guard result.pushed, result.reconciled else { throw MSWOperationServiceError.pushBlocked }
        return result
    }


    func pushReview(workspace: String, repository: MSWRepositorySnapshot) throws -> MSWPushReview {
        guard WorkspaceID.isValid(workspace), let branch = repository.branch, let localCommit = repository.localCommit else {
            throw MSWOperationServiceError.repositoryUnavailable
        }
        guard repository.pushability == .pushable || repository.pushability == .publish else { throw MSWOperationServiceError.pushBlocked }
        guard repository.pushability == .publish || repository.aheadCount > 0 else { throw MSWOperationServiceError.pushBlocked }
        let warning = repository.worktreeState == .localChanges ? "Uncommitted changes will not be included." : nil
        return MSWPushReview(
            id: UUID(), workspace: workspace, repositoryPath: repository.path, branch: branch,
            localCommit: localCommit, remoteCommit: repository.remoteCommit, aheadCount: repository.aheadCount,
            behindCount: repository.behindCount, warning: warning, confirmationPhrase: "PUSH"
        )
    }
}



struct MSWDiagnosticCheck: Codable, Sendable, Equatable, Identifiable {
    enum Status: String, Codable, Sendable { case pass, failed, unavailable }
    let id: String
    let title: String
    let status: Status
    let detail: String
    let recovery: String?
}

struct MSWBackupResult: Codable, Sendable, Equatable {
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

struct MSWBackupEstimate: Codable, Sendable, Equatable {
    let lowerBytes: Int64
    let upperBytes: Int64
    let basisRatio: Double
    let changedSourceRatio: Double
    let provenance: String
}

struct MSWBackupPreview: Codable, Sendable, Equatable {
    let destination: URL
    let sourceAllocatedBytes: Int64
    let archiveEstimate: MSWBackupEstimate?
    let runningWorkspaces: [String]
}

struct MSWBackupOperation: Codable, Sendable, Equatable, Identifiable {
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
    let archiveEstimate: MSWBackupEstimate?
    let processedBytes: Int64
    let writtenBytes: Int64
    let throughputBytesPerSecond: Int64
    let totalBytes: Int64?
    let etaSeconds: Int64?
    let result: MSWBackupResult?
    let error: MSWBackupOperationErrorResponse?
    let warnings: [String]
}

actor MSWDiagnostics {
    private let client: MSWClient

    init(client: MSWClient) {
        self.client = client
    }


    func previewBackup(to directory: URL) async throws -> MSWBackupPreview {
        try validateDirectory(directory)
        let envelope = try await client.previewBackup(directory: directory)
        guard let result = envelope.result else { throw MSWClientError.missingResult(command: "backup-preview") }
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
            throw MSWClientError.malformedJSON(command: "backup-preview")
        }
        return MSWBackupPreview(
            destination: previewDestination,
            sourceAllocatedBytes: result.sourceAllocatedBytes,
            archiveEstimate: result.archiveEstimate.map {
                MSWBackupEstimate(
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

    func startBackup(to directory: URL, requestKey: String) async throws -> MSWBackupOperation {
        try validateDirectory(directory)
        let envelope = try await client.startBackup(directory: directory, requestKey: requestKey)
        guard let result = envelope.result else { throw MSWClientError.missingResult(command: "backup-start") }
        return try validate(result, command: "backup-start")
    }

    func listBackups() async throws -> [MSWBackupOperation] {
        let envelope = try await client.listBackups()
        guard let results = envelope.result else { throw MSWClientError.missingResult(command: "backup-list") }
        let operations = try results.map { try validate($0, command: "backup-list") }
        guard Set(operations.map(\.id)).count == operations.count else {
            throw MSWClientError.malformedJSON(command: "backup-list")
        }
        return operations
    }

    func backupStatus(id: String) async throws -> MSWBackupOperation {
        let envelope = try await client.backupStatus(id: id)
        guard let result = envelope.result else { throw MSWClientError.missingResult(command: "backup-status") }
        return try validate(result, command: "backup-status")
    }

    func restore(archive: URL, confirmation: String) async throws {
        guard confirmation == "RESTORE", archive.pathExtension == "zst", FileManager.default.fileExists(atPath: archive.path) else {
            throw MSWClientError.invalidArguments
        }
        let envelope = try await client.restore(archive: archive, confirmation: confirmation)
        guard envelope.result != nil else { throw MSWClientError.missingResult(command: "restore") }
    }

    private func validateDirectory(_ directory: URL) throws {
        guard directory.isFileURL,
              directory.path.hasPrefix("/"),
              directory.path.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw MSWClientError.invalidArguments
        }
    }

    private func validate(_ value: MSWBackupOperationResponse, command: String) throws -> MSWBackupOperation {
        guard value.kind == "backup",
              value.operationId.range(of: #"^[a-z0-9-]{8,64}$"#, options: .regularExpression) != nil,
              value.requestKey.range(of: #"^[A-Za-z0-9._-]{1,128}$"#, options: .regularExpression) != nil,
              let state = MSWBackupOperation.State(rawValue: value.state),
              let phase = MSWBackupOperation.Phase(rawValue: value.phase),
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
            throw MSWClientError.malformedJSON(command: command)
        }
        let result: MSWBackupResult?
        if let final = value.result {
            guard final.archive.hasPrefix("/"), !final.archive.contains("\0"), final.archiveBytes > 0,
                  final.checksum.hasPrefix("/"), !final.checksum.contains("\0"),
                  final.info.hasPrefix("/"), !final.info.contains("\0"),
                  Set(final.stoppedWorkspaces).count == final.stoppedWorkspaces.count,
                  Set(final.restartedWorkspaces).isSubset(of: Set(final.stoppedWorkspaces)),
                  final.stoppedWorkspaces == value.runningWorkspaces,
                  final.stoppedWorkspaces.allSatisfy(WorkspaceID.isValid),
                  final.restartedWorkspaces.allSatisfy(WorkspaceID.isValid) else {
                throw MSWClientError.malformedJSON(command: command)
            }
            result = MSWBackupResult(
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
            throw MSWClientError.malformedJSON(command: command)
        }
        return MSWBackupOperation(
            id: value.operationId, requestKey: value.requestKey, state: state, phase: phase,
            message: value.message, destination: URL(fileURLWithPath: value.destination),
            startedAt: value.startedAt, updatedAt: value.updatedAt, completedAt: value.completedAt,
            elapsedSeconds: value.elapsedSeconds, ownerPID: value.ownerPid,
            ownerProcessState: value.ownerProcessState, sourceAllocatedBytes: value.sourceAllocatedBytes,
            archiveEstimate: value.archiveEstimate.map {
                MSWBackupEstimate(lowerBytes: $0.lowerBytes, upperBytes: $0.upperBytes,
                    basisRatio: $0.basisRatio, changedSourceRatio: $0.changedSourceRatio,
                    provenance: $0.provenance)
            }, processedBytes: value.progress.processedBytes, writtenBytes: value.progress.writtenBytes,
            throughputBytesPerSecond: value.progress.throughputBytesPerSecond,
            totalBytes: value.progress.totalBytes, etaSeconds: value.progress.etaSeconds,
            result: result, error: value.error, warnings: value.warnings
        )
    }

}
