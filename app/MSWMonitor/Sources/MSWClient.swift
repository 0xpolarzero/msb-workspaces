import Foundation

actor MSWClient {
    private let runner: MSWCommandRunner
    private let credentialBroker: CredentialBroker?
    private let tokenRefreshCoordinator: TokenRefreshCoordinator?
    private var lastState: MSWStateResponse?
    private var lastStateObservedAt: Date?

    init(
        runner: MSWCommandRunner = MSWCommandRunner(),
        credentialBroker: CredentialBroker? = nil,
        tokenRefreshCoordinator: TokenRefreshCoordinator? = nil
    ) {
        self.runner = runner
        self.credentialBroker = credentialBroker
        self.tokenRefreshCoordinator = tokenRefreshCoordinator
    }

    func executableURL() async -> URL? {
        await runner.mswResolution().selected
    }

    func openInZed(workspace: String) async throws {
        guard WorkspaceID.isValid(workspace) else {
            throw MSWClientError.invalidArguments
        }
        let request = try await runner.makeMSWCommand(
            arguments: ["zed", workspace],
            timeout: .seconds(30)
        )
        let output = try await runner.run(request)
        guard output.status == 0 else {
            let message = output.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MSWClientError.processFailed(
                command: "zed",
                status: output.status,
                message: message.isEmpty ? nil : message
            )
        }
    }

    func handshake() async throws -> MSWEnvelope<MSWHandshake> {
        try await execute(arguments: ["app", "handshake", "--format", "json"], as: MSWHandshake.self, command: "handshake")
    }

    func state(workspace: String? = nil) async throws -> MSWEnvelope<MSWStateResponse> {
        var arguments = ["app", "state", "--format", "json"]
        if let workspace { arguments += ["--workspace", workspace] }
        do {
            let envelope = try await execute(
                arguments: arguments,
                as: MSWStateResponse.self,
                command: "state"
            )
            if let result = envelope.result {
                guard result.schemaVersion == 1,
                      !result.workspaces.isEmpty,
                      Set(result.workspaces.map(\.id)).count == result.workspaces.count,
                      result.workspaces.allSatisfy({ WorkspaceID.isValid($0.id) }) else {
                    throw MSWClientError.malformedJSON(command: "state")
                }
                lastState = result
                lastStateObservedAt = envelope.observedAt
            }
            return envelope
        } catch {
            // The caller decides whether a stale snapshot is displayable. This
            // method never turns a transport error into Stopped.
            throw error
        }
    }

    func cachedState() -> (state: MSWStateResponse, observedAt: Date)? {
        guard let lastState else { return nil }
        return (lastState, lastStateObservedAt ?? .distantPast)
    }

    func ports(workspace: String? = nil) async throws -> MSWEnvelope<MSWPortsResponse> {
        var arguments = ["app", "ports", "--format", "json"]
        if let workspace { arguments += ["--workspace", workspace] }
        return try await execute(arguments: arguments, as: MSWPortsResponse.self, command: "ports")
    }

    func metrics(workspace: String) async throws -> MSWEnvelope<MSWMetricsResponse> {
        try await execute(
            arguments: ["app", "metrics", "--workspace", workspace, "--format", "json", "--once"],
            as: MSWMetricsResponse.self,
            command: "metrics",
            timeout: .seconds(20)
        )
    }
    func logs(workspace: String) async throws -> MSWLogsResponse {
        let request = try await runner.makeMSWCommand(
            arguments: ["app", "logs", "--workspace", workspace, "--format", "jsonl"],
            timeout: .seconds(30)
        )
        let output = try await runner.run(request)
        let data = output.stdout
        if output.status != 0 {
            do {
                _ = try MSWProtocolDecoder.decodeEnvelope(data, as: LogEnvelopeResult.self, expectedCommand: "logs")
            } catch let error as MSWClientError {
                if case .protocolFailure = error { throw error }
                let message = output.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
                throw MSWClientError.processFailed(
                    command: "logs",
                    status: output.status,
                    message: message.isEmpty ? nil : message
                )
            }
        }
        if let header = try? MSWProtocolDecoder.decoder().decode(LogEnvelopeHeader.self, from: data),
           header.command == "logs" {
            let envelope = try MSWProtocolDecoder.decodeEnvelope(data, as: LogEnvelopeResult.self, expectedCommand: "logs")
            guard let result = envelope.result else { throw MSWClientError.missingResult(command: "logs") }
            return MSWLogsResponse(
                workspace: result.workspace,
                available: result.available,
                lifecycle: result.lifecycle,
                freshness: result.freshness,
                reason: result.reason,
                lines: result.lines
            )
        }
        var framer = MSWJSONLFramer()
        var records = try framer.append(data)
        if let line = try framer.finish() { records.append(line) }
        let decoded = try records.map { record -> LogStreamRecord in
            do { return try MSWProtocolDecoder.decoder().decode(LogStreamRecord.self, from: record) }
            catch { throw MSWClientError.unavailable("MSW returned a malformed log stream record.") }
        }
        guard let start = decoded.first,
              let end = decoded.last,
              start.type == "stream-start",
              start.protocolVersion == 1,
              start.stream == "logs",
              end.type == "stream-end",
              !start.requestId.isEmpty,
              decoded.allSatisfy({
                  $0.schemaVersion == 1 &&
                    $0.requestId == start.requestId &&
                    $0.workspace == workspace &&
                    $0.observedAt != nil &&
                    $0.safeForDisplay
              }) else {
            throw MSWClientError.unavailable("MSW returned a malformed or unsafe log stream.")
        }
        var lines: [MSWLogEntry] = []
        for record in decoded.dropFirst().dropLast() {
            switch record.type {
            case "log":
                guard let message = record.message else {
                    throw MSWClientError.unavailable("MSW returned a malformed log entry.")
                }
                lines.append(MSWLogEntry(workspace: workspace, message: message, safeForDisplay: true))
            case "failed":
                throw MSWClientError.unavailable(record.message ?? "The MSW log stream failed.")
            default:
                throw MSWClientError.unavailable("MSW returned an unsupported log stream record.")
            }
        }
        return MSWLogsResponse(
            workspace: workspace,
            available: start.available ?? false,
            lifecycle: start.lifecycle ?? .unknown,
            freshness: start.freshness ?? .unavailable,
            reason: start.reason,
            lines: lines
        )
    }

    func repositories(workspace: String, ifRunning: Bool = true, includeWorktreeStatus: Bool = false) async throws -> MSWEnvelope<MSWRepositoriesResponse> {
        var arguments = ["app", "repositories", "--workspace", workspace]
        if ifRunning { arguments.append("--if-running") }
        if includeWorktreeStatus { arguments.append("--include-worktree-status") }
        arguments += ["--format", "json"]
        return try await execute(
            arguments: arguments,
            as: MSWRepositoriesResponse.self,
            command: "repositories",
            credentialsFor: workspace,
            includeGuestCredentials: true
        )
    }

    func githubState(workspace: String? = nil) async throws -> MSWEnvelope<MSWGitHubStateResponse> {
        var arguments = ["app", "github-state", "--format", "json"]
        if let workspace { arguments += ["--workspace", workspace] }
        return try await execute(arguments: arguments, as: MSWGitHubStateResponse.self, command: "github-state")
    }

    func bindGitHubCredentials(
        workspace: String,
        accessMode: String,
        verificationRepository: String
    ) async throws -> MSWEnvelope<MSWGitHubBindResult> {
        guard accessMode == "read-only" || accessMode == "host-write",
              !verificationRepository.isEmpty else {
            throw MSWClientError.invalidArguments
        }
        if accessMode == "host-write" {
            _ = try await execute(
                arguments: [
                    "app", "github-bind",
                    "--workspace", workspace,
                    "--repository", verificationRepository,
                    "--mode", "read-only",
                    "--format", "json"
                ],
                as: MSWGitHubBindResult.self,
                command: "github-bind",
                credentialsFor: workspace,
                includeGuestCredentials: true,
                timeout: .seconds(300)
            )
            return try await execute(
                arguments: [
                    "app", "github-bind",
                    "--workspace", workspace,
                    "--repository", verificationRepository,
                    "--mode", "host-write",
                    "--format", "json"
                ],
                as: MSWGitHubBindResult.self,
                command: "github-bind",
                credentialsFor: workspace,
                includeGuestCredentials: true,
                includeHostCredentials: true,
                timeout: .seconds(300)
            )
        }
        return try await execute(
            arguments: [
                "app", "github-bind",
                "--workspace", workspace,
                "--repository", verificationRepository,
                "--mode", accessMode,
                "--format", "json"
            ],
            as: MSWGitHubBindResult.self,
            command: "github-bind",
            credentialsFor: workspace,
            includeGuestCredentials: true,
            timeout: .seconds(300)
        )
    }
    func unbindGitHubCredentials(workspace: String) async throws -> MSWEnvelope<MSWGitHubUnbindResult> {
        guard WorkspaceID.isValid(workspace) else {
            throw MSWClientError.invalidArguments
        }
        return try await execute(
            arguments: [
                "app", "github-unbind",
                "--workspace", workspace,
                "--format", "json"
            ],
            as: MSWGitHubUnbindResult.self,
            command: "github-unbind",
            timeout: .seconds(300)
        )
    }

 
    func preparePushPlan(workspace: String, repositories: [String]) async throws -> MSWEnvelope<MSWPushPlan> {
        guard WorkspaceID.isValid(workspace), repositories.count == 1,
              repositories.allSatisfy(Self.isSafeRelativePath) else {
            throw MSWClientError.invalidArguments
        }
        return try await execute(
            arguments: ["app", "push-plan", "--workspace", workspace, "--repositories"] + repositories + ["--format", "json"],
            as: MSWPushPlan.self,
            command: "push-plan",
            credentialsFor: workspace,
            includeGuestCredentials: true
        )
    }

    func applyPushPlan(_ plan: MSWPushPlan, confirmation: String) async throws -> MSWEnvelope<MSWPushApplyResult> {
        guard WorkspaceID.isValid(plan.workspace),
              plan.expiresAt > Date(),
              confirmation == plan.confirmationPhrase else {
            throw MSWClientError.invalidArguments
        }
        let input = Data((confirmation + "\n").utf8)
        return try await execute(
            arguments: ["app", "apply", plan.planId, "--confirmation-fd", "0", "--format", "json"],
            as: MSWPushApplyResult.self,
            command: "apply",
            credentialsFor: plan.workspace,
            includeGuestCredentials: true,
            includeHostCredentials: true,
            stdin: input,
            timeout: .seconds(120)
        )
    }


    func prepareLifecyclePlan(action: MSWLifecycleAction, workspace: String) async throws -> MSWEnvelope<MSWLifecyclePlan> {
        guard WorkspaceID.isValid(workspace) else { throw MSWClientError.invalidArguments }
        return try await execute(
            arguments: ["app", "plan", action.rawValue, "--workspace", workspace, "--format", "json"],
            as: MSWLifecyclePlan.self,
            command: "plan"
        )
    }

    func applyLifecyclePlan(_ plan: MSWLifecyclePlan, confirmation: String) async throws -> MSWEnvelope<MSWApplyResult> {
        guard WorkspaceID.isValid(plan.workspace),
              let action = MSWLifecycleAction(rawValue: plan.action),
              plan.expiresAt > Date(),
              confirmation == plan.confirmationPhrase else {
            throw MSWClientError.invalidArguments
        }
        let includeGuestCredentials: Bool
        switch action {
        case .stop:
            includeGuestCredentials = false
        case .start, .restart:
            includeGuestCredentials = true
        }
        return try await execute(
            arguments: ["app", "apply", plan.planId, "--confirmation-fd", "0", "--format", "json"],
            as: MSWApplyResult.self,
            command: "apply",
            credentialsFor: includeGuestCredentials ? plan.workspace : nil,
            includeGuestCredentials: includeGuestCredentials,
            stdin: Data((confirmation + "\n").utf8),
            timeout: .seconds(120)
        )
    }

    func bootstrap() async throws -> MSWEnvelope<MSWBootstrapResult> {
        return try await execute(
            arguments: ["app", "bootstrap", "--resume", "--format", "json"],
            as: MSWBootstrapResult.self,
            command: "bootstrap",
            includeGuestCredentials: true,
            timeout: .seconds(1800)
        )
    }
    func url(workspace: String, port: String = "3000", scheme: String = "http") async throws -> MSWEnvelope<MSWURLResult> {
        guard WorkspaceID.isValid(workspace),
              let portNumber = Int(port), (1...65_535).contains(portNumber),
              scheme == "http" || scheme == "https" else {
            throw MSWClientError.invalidArguments
        }
        return try await execute(
            arguments: ["app", "url", "--workspace", workspace, "--port", port, "--scheme", scheme, "--format", "json"],
            as: MSWURLResult.self,
            command: "url"
        )
    }

    func clone(workspace: String, repository: String, destination: String? = nil) async throws -> MSWEnvelope<MSWWorkspaceOperationResult> {
        guard WorkspaceID.isValid(workspace),
              repository.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil,
              destination.map(Self.isSafeRelativePath) ?? true else {
            throw MSWClientError.invalidArguments
        }
        var arguments = ["app", "clone", "--workspace", workspace, "--repository", repository]
        if let destination { arguments += ["--destination", destination] }
        arguments += ["--format", "json"]
        return try await execute(
            arguments: arguments,
            as: MSWWorkspaceOperationResult.self,
            command: "clone",
            credentialsFor: workspace,
            includeGuestCredentials: true,
            timeout: .seconds(600)
        )
    }

    func pull(workspace: String, path: String = "all") async throws -> MSWEnvelope<MSWWorkspaceOperationResult> {
        guard WorkspaceID.isValid(workspace), path == "all" || Self.isSafeRelativePath(path) else {
            throw MSWClientError.invalidArguments
        }
        return try await execute(
            arguments: ["app", "pull", "--workspace", workspace, "--path", path, "--format", "json"],
            as: MSWWorkspaceOperationResult.self,
            command: "pull",
            credentialsFor: workspace,
            includeGuestCredentials: true,
            timeout: .seconds(600)
        )
    }

    func setIdentity(name: String, email: String, workspace: String? = nil) async throws -> MSWEnvelope<MSWIdentityResult> {
        var arguments = ["app", "identity", "--name", name, "--email", email]
        if let workspace { arguments += ["--workspace", workspace] }
        arguments += ["--format", "json"]
        return try await execute(
            arguments: arguments,
            as: MSWIdentityResult.self,
            command: "identity",
            credentialsFor: workspace,
            includeGuestCredentials: true,
            timeout: .seconds(300)
        )
    }

    func disk(workspace: String? = nil) async throws -> MSWEnvelope<MSWWorkspaceOperationResult> {
        var arguments = ["app", "disk"]
        if let workspace { arguments += ["--workspace", workspace] }
        arguments += ["--format", "json"]
        return try await execute(
            arguments: arguments,
            as: MSWWorkspaceOperationResult.self,
            command: "disk",
            credentialsFor: workspace,
            includeGuestCredentials: true,
            timeout: .seconds(300)
        )
    }

    func resize(workspace: String, memory: String, cpus: String? = nil) async throws -> MSWEnvelope<MSWResourceResult> {
        var arguments = ["app", "resize", "--workspace", workspace, "--memory", memory]
        if let cpus { arguments += ["--cpus", cpus] }
        arguments += ["--format", "json"]
        return try await execute(
            arguments: arguments,
            as: MSWResourceResult.self,
            command: "resize",
            credentialsFor: workspace,
            includeGuestCredentials: true,
            timeout: .seconds(120)
        )
    }

    func clean(workspace: String = "all", removeVolumes: Bool = false, confirmation: String) async throws -> MSWEnvelope<MSWMaintenanceResult> {
        guard workspace == "all" || WorkspaceID.isValid(workspace),
              confirmation == (removeVolumes ? "DELETE VOLUMES \(workspace)" : "CLEAN \(workspace)") else {
            throw MSWClientError.invalidArguments
        }
        let input = Data((confirmation + "\n").utf8)
        var arguments = ["app", "clean", "--workspace", workspace]
        if removeVolumes { arguments.append("--volumes") }
        arguments += ["--confirmation-fd", "0", "--format", "json"]
        return try await execute(
            arguments: arguments,
            as: MSWMaintenanceResult.self,
            command: "clean",
            credentialsFor: workspace == "all" ? nil : workspace,
            includeGuestCredentials: true,
            stdin: input,
            timeout: .seconds(600)
        )
    }

    func upgrade(workspace: String = "all", confirmation: String) async throws -> MSWEnvelope<MSWMaintenanceResult> {
        guard workspace == "all" || WorkspaceID.isValid(workspace),
              confirmation == "UPGRADE \(workspace)" else {
            throw MSWClientError.invalidArguments
        }
        let input = Data((confirmation + "\n").utf8)
        return try await execute(
            arguments: ["app", "upgrade", "--workspace", workspace, "--confirmation-fd", "0", "--format", "json"],
            as: MSWMaintenanceResult.self,
            command: "upgrade",
            credentialsFor: workspace == "all" ? nil : workspace,
            includeGuestCredentials: true,
            stdin: input,
            timeout: .seconds(1800)
        )
    }

    func update(confirmation: String) async throws -> MSWEnvelope<MSWMaintenanceResult> {
        guard confirmation == "UPDATE" else { throw MSWClientError.invalidArguments }
        return try await execute(
            arguments: ["app", "update", "--confirmation-fd", "0", "--format", "json"],
            as: MSWMaintenanceResult.self,
            command: "update",
            stdin: Data("UPDATE\n".utf8),
            timeout: .seconds(900)
        )
    }

    func check(deep: Bool = false, confirmation: String? = nil) async throws -> MSWEnvelope<MSWCheckResult> {
        var arguments = ["app", "check"]
        var stdin: Data?
        if deep {
            guard confirmation == "DEEP CHECK" else { throw MSWClientError.invalidArguments }
            arguments += ["--deep", "--confirmation-fd", "0"]
            stdin = Data("DEEP CHECK\n".utf8)
        } else if confirmation != nil {
            throw MSWClientError.invalidArguments
        }
        arguments += ["--format", "json"]
        return try await execute(
            arguments: arguments,
            as: MSWCheckResult.self,
            command: "check",
            includeGuestCredentials: deep,
            stdin: stdin,
            timeout: deep ? .seconds(1800) : .seconds(120)
        )
    }

    func backup(directory: URL) async throws -> MSWEnvelope<MSWBackupResponse> {
        try await execute(
            arguments: ["app", "backup", "--directory", directory.path, "--format", "json"],
            as: MSWBackupResponse.self,
            command: "backup",
            includeGuestCredentials: true,
            timeout: .seconds(1800)
        )
    }

    func restore(archive: URL, confirmation: String) async throws -> MSWEnvelope<MSWWorkspaceOperationResult> {
        guard confirmation == "RESTORE", archive.isFileURL, archive.pathExtension == "zst" else {
            throw MSWClientError.invalidArguments
        }
        let input = Data((confirmation + "\n").utf8)
        return try await execute(
            arguments: ["app", "restore", "--archive", archive.path, "--confirmation-fd", "0", "--format", "json"],
            as: MSWWorkspaceOperationResult.self,
            command: "restore",
            includeGuestCredentials: true,
            stdin: input,
            timeout: .seconds(1800)
        )
    }


    private func execute<Value: Codable & Sendable>(
        arguments: [String],
        as type: Value.Type,
        command: String,
        credentialsFor workspace: String? = nil,
        includeGuestCredentials: Bool = false,
        includeHostCredentials: Bool = false,
        stdin: Data? = nil,
        timeout: Duration = .seconds(30)
    ) async throws -> MSWEnvelope<Value> {
        try await prepareCredentials(
            for: workspace,
            includeGuest: includeGuestCredentials,
            includeHost: includeHostCredentials
        )
        let request = try await runner.makeMSWCommand(
            arguments: arguments,
            timeout: timeout,
            stdin: stdin
        )
        let output = try await runner.run(request)
        do {
            let envelope = try MSWProtocolDecoder.decodeEnvelope(output.stdout, as: type, expectedCommand: command)
            guard output.status == 0 else {
                throw MSWClientError.processFailed(
                    command: command,
                    status: output.status,
                    message: "MSW returned a success envelope with a failing exit status."
                )
            }
            return envelope
        } catch let error as MSWClientError {
            if case .protocolFailure = error {
                throw error
            }
            guard output.status != 0 else { throw error }
            let message = output.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MSWClientError.processFailed(
                command: arguments.first ?? command,
                status: output.status,
                message: message.isEmpty ? nil : message
            )
        }
    }

    /// Refreshes expiring records in Keychain before invoking MSW. Token bytes
    /// are not copied into the app-to-CLI environment; MSW obtains the fixed
    /// workspace/role record only at the narrow binding or host-askpass edge.
    private func prepareCredentials(
        for workspace: String?,
        includeGuest: Bool,
        includeHost: Bool
    ) async throws {
        let workspaces = workspace.map { [$0] } ?? WorkspaceID.all
        for workspace in workspaces {
            if includeGuest { _ = try await accessToken(workspace: workspace, role: .guest) }
            if includeHost { _ = try await accessToken(workspace: workspace, role: .host) }
        }
    }

    private func accessToken(workspace: String, role: CredentialRole) async throws -> String? {
        guard let credentialBroker else { return nil }
        let bundle: CredentialBundle
        do {
            bundle = try await credentialBroker.load(workspace: workspace, role: role)
        } catch CredentialBrokerError.missingCredential,
                CredentialBrokerError.legacyCredentialRequiresAuthorization {
            return nil
        } catch CredentialBrokerError.grantUnavailable {
            var canRetry = false
            do {
                if let entry = try await credentialBroker.metadata(for: workspace, role: role) {
                    canRetry = entry.recoveryState == .serviceUnavailable && !entry.quarantined
                }
            } catch {
                canRetry = false
            }
            if canRetry, let tokenRefreshCoordinator {
                let refreshed = try await tokenRefreshCoordinator.refresh(workspace: workspace, role: role)
                return refreshed.accessToken
            }
            throw MSWClientError.unavailable("The GitHub installation grant for \(workspace) requires reauthorization.")
        } catch CredentialBrokerError.quarantineRequired {
            throw MSWClientError.unavailable("The GitHub installation grant for \(workspace) requires reauthorization.")
        }
        if !bundle.credential.isAccessExpired {
            return bundle.credential.accessToken
        }
        guard let tokenRefreshCoordinator else {
            throw MSWClientError.unavailable("The GitHub installation grant has expired; authorize the workspace again.")
        }
        let refreshed = try await tokenRefreshCoordinator.refresh(workspace: workspace, role: role)
        return refreshed.accessToken
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"),
              !path.contains("\n"), !path.contains("\r"), !path.contains("\t") else {
            return false
        }
        if path == "." { return true }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    private struct LogEnvelopeHeader: Decodable {
        let command: String
    }

    private struct LogEnvelopeResult: Codable, Sendable {
        let workspace: String
        let available: Bool
        let lifecycle: MSWLifecycle
        let freshness: MSWFreshness
        let reason: String?
        let lines: [MSWLogEntry]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            workspace = try container.decode(String.self, forKey: .workspace)
            available = try container.decode(Bool.self, forKey: .available)
            lifecycle = try container.decodeIfPresent(MSWLifecycle.self, forKey: .lifecycle) ?? .unknown
            freshness = try container.decodeIfPresent(MSWFreshness.self, forKey: .freshness) ?? .unavailable
            reason = try container.decodeIfPresent(String.self, forKey: .reason)
            lines = try container.decodeIfPresent([MSWLogEntry].self, forKey: .lines) ?? []
        }
    }

    private struct LogStreamRecord: Decodable {
        let schemaVersion: Int
        let type: String
        let protocolVersion: Int?
        let stream: String?
        let requestId: String
        let workspace: String
        let observedAt: Date?
        let available: Bool?
        let lifecycle: MSWLifecycle?
        let freshness: MSWFreshness?
        let reason: String?
        let message: String?
        let safeForDisplay: Bool
    }
}

enum MSWLifecycleAction: String, Codable, Sendable {
    case start
    case stop
    case restart
}
