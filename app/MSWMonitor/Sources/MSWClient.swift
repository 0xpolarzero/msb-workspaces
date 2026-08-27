import Foundation

actor MSWClient {
    private let runner: MSWCommandRunner
    private let credentialBroker: CredentialBroker?
    private let tokenRefreshCoordinator: TokenRefreshCoordinator?
    private let ghResolver: @Sendable () async -> URL?
    private var configuredWorkspaces: [String]
    private var lastState: MSWStateResponse?
    private var lastStateObservedAt: Date?

    init(
        runner: MSWCommandRunner = MSWCommandRunner(),
        credentialBroker: CredentialBroker? = nil,
        tokenRefreshCoordinator: TokenRefreshCoordinator? = nil,
        ghResolver: (@Sendable () async -> URL?)? = nil
    ) {
        self.runner = runner
        self.credentialBroker = credentialBroker
        self.tokenRefreshCoordinator = tokenRefreshCoordinator
        self.ghResolver = ghResolver ?? { await runner.resolveExecutable(named: "gh") }
        self.configuredWorkspaces = BootstrapStateStore.persistedWorkspaceConfigurations().map(\.name)
    }

    /// Test seam: local-mode clients must never carry Connect dependencies
    /// (Path C §1 / reviewer blocker 7). A nil broker means `accessToken`
    /// returns immediately without reading any Connect Keychain record.
    nonisolated var hasConnectDependencies: Bool {
        credentialBroker != nil || tokenRefreshCoordinator != nil
    }

    func executableURL() async -> URL? {
        await runner.mswResolution().selected
    }

    /// Resolves only the coupled bundled or activated executable and verifies
    /// its exact app handshake. It never starts or previews a backup.
    func runtimeRepairRequired(forceRefresh: Bool = false) async -> Bool? {
        let resolution = await runner.mswResolution(forceRefresh: forceRefresh)
        // Cancellation deliberately returns an unselected transient resolution
        // so it cannot poison the runner cache. Preserve the last published UI
        // state instead of misreporting that transient as a broken install.
        guard !Task.isCancelled else { return nil }
        return resolution.selected == nil
    }

    func invalidateRuntimeResolution() async {
        await runner.invalidateMSWResolution()
    }

    func executableSearchPath() async -> String {
        await runner.executableSearchPath()
    }

    func reloadWorkspaceConfiguration(_ configurations: [SetupWorkspaceConfiguration]) throws {
        if let validation = SetupWorkspaceConfiguration.validationMessage(for: configurations) {
            throw BootstrapCoordinatorError.invalidWorkspaceConfiguration(validation)
        }
        configuredWorkspaces = configurations.map(\.name)
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
        return try await execute(
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
                guard let observedAt = record.observedAt,
                      let message = record.message else {
                    throw MSWClientError.unavailable("MSW returned a malformed log entry.")
                }
                lines.append(
                    MSWLogEntry(
                        workspace: workspace,
                        observedAt: observedAt,
                        message: message,
                        safeForDisplay: true
                    )
                )
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

    func directories(
        workspace: String,
        path: String = ".",
        query: String? = nil,
        limit: Int = 100
    ) async throws -> MSWEnvelope<MSWDirectoryResponse> {
        guard WorkspaceID.isValid(workspace), Self.isSafeRelativePath(path),
              (1...200).contains(limit),
              query.map({ !$0.isEmpty && $0.count <= 128 && Self.isControlFree($0) }) ?? true else {
            throw MSWClientError.invalidArguments
        }
        let command = query == nil ? "directory-list" : "directory-search"
        var arguments = ["app", command, "--workspace", workspace, "--path", path]
        if let query { arguments += ["--query", query] }
        arguments += ["--limit", String(limit), "--format", "json"]
        let envelope = try await execute(
            arguments: arguments,
            as: MSWDirectoryResponse.self,
            command: command,
            timeout: .seconds(20)
        )
        guard let result = envelope.result else {
            throw MSWClientError.malformedJSON(command: command)
        }
        let flattenedEntries = Self.flattenedDirectoryEntries(result.entries)
        guard result.workspace == workspace,
              result.path == path,
              result.query == query,
              flattenedEntries.count <= limit,
              Set(flattenedEntries.map(\.path)).count == flattenedEntries.count,
              Self.directoryEntriesAreValid(
                  result.entries,
                  within: path,
                  recursive: query != nil
              ) else {
            throw MSWClientError.malformedJSON(command: command)
        }
        return envelope
    }

    func editorTarget(workspace: String, path: String = ".") async throws -> MSWEnvelope<MSWEditorTarget> {
        guard WorkspaceID.isValid(workspace), Self.isSafeRelativePath(path) else {
            throw MSWClientError.invalidArguments
        }
        let envelope = try await execute(
            arguments: ["app", "editor-target", "--workspace", workspace, "--path", path, "--format", "json"],
            as: MSWEditorTarget.self,
            command: "editor-target",
            timeout: .seconds(20)
        )
        guard let result = envelope.result,
              result.workspace == workspace,
              result.path == path,
              result.host == "\(workspace).msb",
              result.isValid,
              result.remoteURL != nil else {
            throw MSWClientError.malformedJSON(command: "editor-target")
        }
        return envelope
    }

    func githubState(workspace: String? = nil) async throws -> MSWEnvelope<MSWGitHubStateResponse> {
        var arguments = ["app", "github-state", "--format", "json"]
        if let workspace { arguments += ["--workspace", workspace] }
        return try await execute(arguments: arguments, as: MSWGitHubStateResponse.self, command: "github-state")
    }

    // MARK: - Path C local mode

    /// `msw github status --format json` (raw, non-envelope CLI output).
    func githubStatus() async throws -> MSWGitHubStatusResponse {
        try await runRawJSON(
            arguments: ["github", "status", "--format", "json"],
            as: MSWGitHubStatusResponse.self,
            command: "github status"
        )
    }

    /// `msw github auth --json`: nonsecret host-credential metadata. Succeeds
    /// fully non-interactively via gh reuse; on failure (gh not authenticated
    /// and no device client ID, or verification failure) the CLI prints a
    /// typed `{ok:false,error}` document to stdout with a nonzero exit.
    func githubAuth(force: Bool = false) async throws -> MSWGitHubAuthMetadata {
        var arguments = ["github", "auth"]
        if force { arguments.append("--force") }
        arguments.append("--json")
        let request = try await runner.makeMSWCommand(arguments: arguments, timeout: .seconds(180))
        let output = try await runner.run(request)
        // Success is the bare nonsecret metadata object. Guard against the
        // failure document decoding as an all-optional metadata struct.
        if let metadata = try? MSWProtocolDecoder.decoder().decode(MSWGitHubAuthMetadata.self, from: output.stdout),
           metadata.accountLogin != nil || metadata.provider != nil {
            guard output.status == 0 else {
                throw MSWClientError.processFailed(
                    command: "github auth",
                    status: output.status,
                    message: "MSW returned success metadata with a failing exit status."
                )
            }
            return metadata
        }
        throw Self.rawCLIError(from: output.stdout, command: "github auth", fallbackStatus: output.status)
    }

    func githubAuthMetadata() async throws -> MSWGitHubAuthMetadata {
        try await githubAuth(force: false)
    }

    /// Launches the installed gh CLI's web OAuth flow
    /// (`gh auth login --hostname github.com --git-protocol https --web
    /// --skip-ssh-key`), which opens the default browser and waits for the
    /// user to complete sign-in. The caller retries `githubAuth()` after
    /// this returns. Throws a typed error when gh is unavailable.
    func githubWebLogin() async throws {
        guard let gh = await ghResolver() else {
            throw MSWClientError.unavailable(
                "The GitHub CLI (gh) is not installed on this Mac. Install it, then sign in again."
            )
        }
        let request = MSWCommand(
            executable: gh,
            arguments: [
                "auth", "login",
                "--hostname", "github.com",
                "--git-protocol", "https",
                "--web",
                "--skip-ssh-key"
            ],
            timeout: .seconds(600)
        )
        let output = try await runner.run(request)
        guard output.status == 0 else {
            let message = output.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MSWClientError.processFailed(
                command: "gh auth login",
                status: output.status,
                message: message.isEmpty ? nil : message
            )
        }
    }

    /// `msw github repos --format json`: paginated repository discovery
    /// (CLI paginates internally; flat, deduped, sorted by canonical).
    func githubRepos() async throws -> [MSWGitHubDiscoveredRepo] {
        let response = try await runRawCLI(arguments: ["github", "repos", "--format", "json"], command: "github repos")
        guard response.ok == true, let repos = response.repos else {
            throw Self.rawCLIError(from: response, command: "github repos")
        }
        return repos
    }

    /// `msw github auth --device --format json`: one-shot device-flow start.
    /// `deviceId` is the poll handle passed to `githubAuthDeviceComplete`.
    func githubAuthDevice() async throws -> MSWDeviceFlowStart {
        let response = try await runRawCLI(arguments: ["github", "auth", "--device", "--format", "json"], command: "github auth --device")
        guard response.ok == true,
              let deviceId = response.deviceId,
              let code = response.code,
              let verificationUri = response.verificationUri,
              let expiresAt = response.expiresAt else {
            throw Self.rawCLIError(from: response, command: "github auth --device")
        }
        return MSWDeviceFlowStart(
            deviceId: deviceId,
            code: code,
            verificationUri: verificationUri,
            expiresAt: expiresAt,
            interval: response.interval ?? 5
        )
    }

    /// `msw github auth --device-complete DEVICE_ID --format json`: exactly
    /// one exchange attempt (the app drives the poll loop with interval
    /// sleeps). Authorization stores and verifies the credential.
    func githubAuthDeviceComplete(deviceId: String) async throws -> MSWDeviceFlowPoll {
        guard !deviceId.isEmpty else { throw MSWClientError.invalidArguments }
        let response = try await runRawCLI(
            arguments: ["github", "auth", "--device-complete", deviceId, "--format", "json"],
            command: "github auth --device-complete"
        )
        if response.ok == true {
            switch response.status {
            case "slow_down":
                return MSWDeviceFlowPoll(status: .slowDown, interval: response.interval, accountLogin: nil)
            case "authorized":
                return MSWDeviceFlowPoll(
                    status: .authorized,
                    interval: nil,
                    accountLogin: response.metadata?.accountLogin
                )
            case "expired":
                return MSWDeviceFlowPoll(status: .expired, interval: nil, accountLogin: nil)
            case "denied":
                return MSWDeviceFlowPoll(status: .denied, interval: nil, accountLogin: nil)
            default:
                return MSWDeviceFlowPoll(status: .pending, interval: response.interval, accountLogin: nil)
            }
        }
        switch response.status {
        case "expired":
            return MSWDeviceFlowPoll(status: .expired, interval: nil, accountLogin: nil)
        case "denied":
            return MSWDeviceFlowPoll(status: .denied, interval: nil, accountLogin: nil)
        default:
            throw Self.rawCLIError(from: response, command: "github auth --device-complete")
        }
    }

    /// Runs a raw CLI command whose output is a `{ok:...,error:...}`-style
    /// JSON document (success fields vary per command; failures go to stdout
    /// with a nonzero exit).
    private func runRawCLI(
        arguments: [String],
        command: String,
        timeout: Duration = .seconds(60)
    ) async throws -> MSWGitHubCLIResponse {
        let request = try await runner.makeMSWCommand(arguments: arguments, timeout: timeout)
        let output = try await runner.run(request)
        do {
            return try MSWProtocolDecoder.decoder().decode(MSWGitHubCLIResponse.self, from: output.stdout)
        } catch {
            let message = output.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MSWClientError.processFailed(
                command: command,
                status: output.status,
                message: message.isEmpty ? nil : message
            )
        }
    }

    /// Converts a decoded raw-CLI response into a typed error.
    private static func rawCLIError(
        from response: MSWGitHubCLIResponse,
        command: String
    ) -> MSWClientError {
        let error = response.error
        return .rawCLIError(
            code: error?.code ?? "MSW_CLI_ERROR",
            message: error?.message ?? "\(command) failed."
        )
    }

    /// Converts raw stdout into a typed raw-CLI error (used by commands whose
    /// success payload is not the union-shaped document).
    private static func rawCLIError(
        from stdout: Data,
        command: String,
        fallbackStatus: Int32
    ) -> MSWClientError {
        if let response = try? MSWProtocolDecoder.decoder().decode(MSWGitHubCLIResponse.self, from: stdout),
           response.ok == false,
           let error = response.error {
            return .rawCLIError(code: error.code ?? "MSW_CLI_ERROR", message: error.message ?? "\(command) failed.")
        }
        let message = String(decoding: stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .processFailed(
            command: command,
            status: fallbackStatus,
            message: message.isEmpty ? nil : message
        )
    }

    /// ONE `msw app github-policy-apply` invocation carrying the FULL desired
    /// policy on stdin. The CLI validates the request, acquires the
    /// per-workspace github locks, provisions/verifies transport for each
    /// semantically changed, non-empty workspace using the final capabilities,
    /// and performs ONE atomic policy-file commit (rolling back byte-exact on
    /// any unproven step).
    /// Typed failures (MSW_INVALID_REQUEST, MSW_GITHUB_MODE_MISMATCH,
    /// MSW_OPERATION_CONFLICT, MSW_TRANSPORT_PROVISION_FAILED,
    /// MSW_POLICY_WRITE_FAILED, MSW_INTERNAL_ERROR) surface as protocol
    /// failures; the caller marks the operation applied only after the CLI
    /// reports provisioned + committed.
    func githubPolicyApply(_ request: MSWGitHubPolicyApplyRequest) async throws -> MSWGitHubPolicyApplyResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let input: Data
        do {
            input = try encoder.encode(request)
        } catch {
            throw MSWClientError.invalidArguments
        }
        let envelope = try await execute(
            arguments: [
                "app", "github-policy-apply",
                "--format", "json"
            ],
            as: MSWGitHubPolicyApplyResult.self,
            command: "github-policy-apply",
            stdin: input,
            timeout: .seconds(600),
            // The CLI's TERM trap restores any temporarily changed workspace
            // lifecycle before releasing locks. Allow its bounded stop stage
            // to finish before process-group SIGKILL escalation.
            terminationGrace: .seconds(65)
        )
        guard let result = envelope.result else {
            throw MSWClientError.missingResult(command: "github-policy-apply")
        }
        return result
    }

    /// Runs a raw (non-envelope) JSON CLI command and decodes its stdout.
    private func runRawJSON<Value: Codable & Sendable>(
        arguments: [String],
        as type: Value.Type,
        command: String,
        timeout: Duration = .seconds(30)
    ) async throws -> Value {
        let request = try await runner.makeMSWCommand(arguments: arguments, timeout: timeout)
        let output = try await runner.run(request)
        guard output.status == 0 else {
            let message = output.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MSWClientError.processFailed(
                command: command,
                status: output.status,
                message: message.isEmpty ? nil : message
            )
        }
        do {
            return try MSWProtocolDecoder.decoder().decode(type, from: output.stdout)
        } catch {
            throw MSWClientError.malformedJSON(command: command)
        }
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

    func bootstrap(
        workspaceConfigurations: [SetupWorkspaceConfiguration]
    ) async throws -> MSWEnvelope<MSWBootstrapResult> {
        guard SetupWorkspaceConfiguration.validationMessage(for: workspaceConfigurations) == nil else {
            throw MSWClientError.invalidArguments
        }
        let input = try JSONEncoder().encode(MSWBootstrapConfiguration(workspaceConfigurations))
        return try await execute(
            arguments: ["app", "bootstrap", "--resume", "--workspace-config-fd", "0", "--format", "json"],
            as: MSWBootstrapResult.self,
            command: "bootstrap",
            includeGuestCredentials: true,
            stdin: input,
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

    func startBackup(directory: URL, requestKey: String) async throws -> MSWEnvelope<MSWBackupOperationResponse> {
        guard requestKey.range(of: #"^[A-Za-z0-9._-]{1,128}$"#, options: .regularExpression) != nil else {
            throw MSWClientError.invalidArguments
        }
        return try await execute(
            arguments: ["app", "backup-start", "--directory", directory.path, "--request-key", requestKey, "--format", "json"],
            as: MSWBackupOperationResponse.self,
            command: "backup-start",
            includeGuestCredentials: true,
            timeout: .seconds(30)
        )
    }

    func listBackups() async throws -> MSWEnvelope<[MSWBackupOperationResponse]> {
        try await execute(
            arguments: ["app", "backup-list", "--format", "json"],
            as: [MSWBackupOperationResponse].self,
            command: "backup-list",
            timeout: .seconds(30)
        )
    }

    func backupStatus(id: String) async throws -> MSWEnvelope<MSWBackupOperationResponse> {
        guard id.range(of: #"^[a-z0-9-]{8,64}$"#, options: .regularExpression) != nil else {
            throw MSWClientError.invalidArguments
        }
        return try await execute(
            arguments: ["app", "backup-status", "--operation-id", id, "--format", "json"],
            as: MSWBackupOperationResponse.self,
            command: "backup-status",
            timeout: .seconds(30)
        )
    }

    func previewBackup(directory: URL) async throws -> MSWEnvelope<MSWBackupPreviewResponse> {
        try await execute(
            arguments: ["app", "backup-preview", "--directory", directory.path, "--format", "json"],
            as: MSWBackupPreviewResponse.self,
            command: "backup-preview",
            timeout: .seconds(300)
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
        timeout: Duration = .seconds(30),
        terminationGrace: Duration = .milliseconds(250)
    ) async throws -> MSWEnvelope<Value> {
        try await prepareCredentials(
            for: workspace,
            includeGuest: includeGuestCredentials,
            includeHost: includeHostCredentials
        )
        let request = try await runner.makeMSWCommand(
            arguments: arguments,
            timeout: timeout,
            stdin: stdin,
            terminationGrace: terminationGrace
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
                command: command,
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
        let workspaces = workspace.map { [$0] } ?? configuredWorkspaces
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
                    canRetry = (entry.recoveryState == .expired ||
                        entry.recoveryState == .serviceUnavailable) && !entry.quarantined
                }
            } catch {
                canRetry = false
            }
            if canRetry, let tokenRefreshCoordinator {
                let refreshed = try await tokenRefreshCoordinator.refresh(workspace: workspace, role: role)
                return refreshed.accessToken
            }
            throw MSWClientError.unavailable("The GitHub installation grant for \(workspace) requires reconnecting.")
        } catch CredentialBrokerError.quarantineRequired {
            throw MSWClientError.unavailable("The GitHub installation grant for \(workspace) requires reconnecting.")
        }
        if !bundle.credential.isAccessExpired {
            return bundle.credential.accessToken
        }
        guard let tokenRefreshCoordinator else {
            throw MSWClientError.unavailable("The GitHub installation token expired, but renewal is unavailable in this build. GitHub access remains blocked.")
        }
        let refreshed = try await tokenRefreshCoordinator.refresh(workspace: workspace, role: role)
        return refreshed.accessToken
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.count <= 1_024, !path.hasPrefix("/"),
              isControlFree(path) else {
            return false
        }
        if path == "." { return true }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    private static func isControlFree(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7f }
    }

    private static func flattenedDirectoryEntries(
        _ entries: [MSWDirectoryResponse.Entry]
    ) -> [MSWDirectoryResponse.Entry] {
        entries.flatMap { entry in
            [entry] + flattenedDirectoryEntries(entry.children)
        }
    }

    private static func directoryEntriesAreValid(
        _ entries: [MSWDirectoryResponse.Entry],
        within scope: String,
        recursive: Bool
    ) -> Bool {
        entries.allSatisfy { entry in
            entry.kind == "directory" &&
                !entry.name.isEmpty &&
                entry.name.count <= 255 &&
                isControlFree(entry.name) &&
                entry.path.count <= 1_024 &&
                isSafeRelativePath(entry.path) &&
                entry.name == entry.path.split(separator: "/").last.map(String.init) &&
                isDirectoryEntryPath(entry.path, within: scope, recursive: recursive) &&
                (entry.children.isEmpty || entry.hasChildren) &&
                (!entry.childrenTruncated || entry.hasChildren) &&
                (recursive
                    ? entry.children.isEmpty && !entry.childrenTruncated
                    : directoryEntriesAreValid(entry.children, within: entry.path, recursive: false))
        }
    }

    private static func isDirectoryEntryPath(
        _ entry: String,
        within scope: String,
        recursive: Bool
    ) -> Bool {
        let scopeComponents = scope == "." ? [] : scope.split(separator: "/")
        let entryComponents = entry.split(separator: "/")
        guard entryComponents.count > scopeComponents.count,
              entryComponents.prefix(scopeComponents.count).elementsEqual(scopeComponents) else {
            return false
        }
        return recursive || entryComponents.count == scopeComponents.count + 1
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
