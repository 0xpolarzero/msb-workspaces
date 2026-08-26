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
        try await coordinator.lifecycle(action, workspace: workspace)
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
    let checksum: URL?
    let stoppedWorkspaces: [String]
    let restartedWorkspaces: [String]
}

struct MSWBackupPreview: Codable, Sendable, Equatable {
    let destination: URL
    let requiredBytes: Int64
    let runningWorkspaces: [String]
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
              result.requiredBytes > 0,
              Set(result.runningWorkspaces).count == result.runningWorkspaces.count,
              result.runningWorkspaces.allSatisfy(WorkspaceID.isValid) else {
            throw MSWClientError.malformedJSON(command: "backup-preview")
        }
        return MSWBackupPreview(
            destination: previewDestination,
            requiredBytes: result.requiredBytes,
            runningWorkspaces: result.runningWorkspaces
        )
    }

    func backup(to directory: URL) async throws -> MSWBackupResult {
        try validateDirectory(directory)
        let envelope = try await client.backup(directory: directory)
        guard let result = envelope.result else { throw MSWClientError.missingResult(command: "backup") }
        guard result.archive.hasPrefix("/"), !result.archive.contains("\0"),
              result.checksum.map({ $0.hasPrefix("/") && !$0.contains("\0") }) ?? true else {
            throw MSWClientError.malformedJSON(command: "backup")
        }
        return MSWBackupResult(
            archive: URL(fileURLWithPath: result.archive),
            checksum: result.checksum.map { URL(fileURLWithPath: $0) },
            stoppedWorkspaces: result.stoppedWorkspaces,
            restartedWorkspaces: result.restartedWorkspaces
        )
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

}
