import Foundation

actor SiloClient {
    private let runner: SiloCommandRunner
    private let ghResolver: @Sendable () async -> URL?
    private var configuredWorkspaces: [String]
    private var lastState: SiloStateResponse?
    private var lastStateObservedAt: Date?

    init(
        runner: SiloCommandRunner = SiloCommandRunner(),
        ghResolver: (@Sendable () async -> URL?)? = nil
    ) {
        self.runner = runner
        self.ghResolver = ghResolver ?? { await runner.resolveExecutable(named: "gh") }
        self.configuredWorkspaces = BootstrapStateStore.persistedWorkspaceConfigurations().map(\.name)
    }

    func executableURL() async -> URL? {
        await runner.siloResolution().selected
    }

    /// Resolves only the coupled bundled or activated executable and verifies
    /// its exact app handshake. It never starts or previews a backup.
    func runtimeRepairRequired(forceRefresh: Bool = false) async -> Bool? {
        let resolution = await runner.siloResolution(forceRefresh: forceRefresh)
        // Cancellation deliberately returns an unselected transient resolution
        // so it cannot poison the runner cache. Preserve the last published UI
        // state instead of misreporting that transient as a broken install.
        guard !Task.isCancelled else { return nil }
        return resolution.selected == nil
    }

    func invalidateRuntimeResolution() async {
        await runner.invalidateSiloResolution()
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

    func handshake() async throws -> SiloEnvelope<SiloHandshake> {
        try await execute(arguments: ["app", "handshake", "--format", "json"], as: SiloHandshake.self, command: "handshake")
    }

    func state(workspace: String? = nil) async throws -> SiloEnvelope<SiloStateResponse> {
        var arguments = ["app", "state", "--format", "json"]
        if let workspace { arguments += ["--workspace", workspace] }
        do {
            let envelope = try await execute(
                arguments: arguments,
                as: SiloStateResponse.self,
                command: "state"
            )
            if let result = envelope.result {
                guard result.schemaVersion == 1,
                      !result.workspaces.isEmpty,
                      Set(result.workspaces.map(\.id)).count == result.workspaces.count,
                      result.workspaces.allSatisfy({ WorkspaceID.isValid($0.id) }) else {
                    throw SiloClientError.malformedJSON(command: "state")
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

    func cachedState() -> (state: SiloStateResponse, observedAt: Date)? {
        guard let lastState else { return nil }
        return (lastState, lastStateObservedAt ?? .distantPast)
    }

    func ports(workspace: String? = nil) async throws -> SiloEnvelope<SiloPortsResponse> {
        var arguments = ["app", "ports", "--format", "json"]
        if let workspace { arguments += ["--workspace", workspace] }
        return try await execute(arguments: arguments, as: SiloPortsResponse.self, command: "ports")
    }

    func metrics(workspace: String) async throws -> SiloEnvelope<SiloMetricsResponse> {
        return try await execute(
            arguments: ["app", "metrics", "--workspace", workspace, "--format", "json", "--once"],
            as: SiloMetricsResponse.self,
            command: "metrics",
            timeout: .seconds(20)
        )
    }
    func logs(workspace: String) async throws -> SiloLogsResponse {
        let request = try await runner.makeSiloCommand(
            arguments: ["app", "logs", "--workspace", workspace, "--format", "jsonl"],
            timeout: .seconds(30)
        )
        let output = try await runner.run(request)
        let data = output.stdout
        if output.status != 0 {
            do {
                _ = try SiloProtocolDecoder.decodeEnvelope(data, as: LogEnvelopeResult.self, expectedCommand: "logs")
            } catch let error as SiloClientError {
                if case .protocolFailure = error { throw error }
                let message = output.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
                throw SiloClientError.processFailed(
                    command: "logs",
                    status: output.status,
                    message: message.isEmpty ? nil : message
                )
            }
        }
        if let header = try? SiloProtocolDecoder.decoder().decode(LogEnvelopeHeader.self, from: data),
           header.command == "logs" {
            let envelope = try SiloProtocolDecoder.decodeEnvelope(data, as: LogEnvelopeResult.self, expectedCommand: "logs")
            guard let result = envelope.result else { throw SiloClientError.missingResult(command: "logs") }
            return SiloLogsResponse(
                workspace: result.workspace,
                available: result.available,
                lifecycle: result.lifecycle,
                freshness: result.freshness,
                reason: result.reason,
                lines: result.lines
            )
        }
        var framer = SiloJSONLFramer()
        var records = try framer.append(data)
        if let line = try framer.finish() { records.append(line) }
        let decoded = try records.map { record -> LogStreamRecord in
            do { return try SiloProtocolDecoder.decoder().decode(LogStreamRecord.self, from: record) }
            catch { throw SiloClientError.unavailable("Silo returned a malformed log stream record.") }
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
            throw SiloClientError.unavailable("Silo returned a malformed or unsafe log stream.")
        }
        var lines: [SiloLogEntry] = []
        for record in decoded.dropFirst().dropLast() {
            switch record.type {
            case "log":
                guard let observedAt = record.observedAt,
                      let source = record.source,
                      let message = record.message else {
                    throw SiloClientError.unavailable("Silo returned a malformed log entry.")
                }
                lines.append(
                    SiloLogEntry(
                        workspace: workspace,
                        observedAt: observedAt,
                        source: source,
                        sessionID: record.sessionID,
                        encoding: record.encoding,
                        message: message,
                        safeForDisplay: true
                    )
                )
            case "failed":
                throw SiloClientError.unavailable(record.message ?? "The Silo log stream failed.")
            default:
                throw SiloClientError.unavailable("Silo returned an unsupported log stream record.")
            }
        }
        return SiloLogsResponse(
            workspace: workspace,
            available: start.available ?? false,
            lifecycle: start.lifecycle ?? .unknown,
            freshness: start.freshness ?? .unavailable,
            reason: start.reason,
            lines: lines
        )
    }

    func repositories(workspace: String, ifRunning: Bool = true, includeWorktreeStatus: Bool = false) async throws -> SiloEnvelope<SiloRepositoriesResponse> {
        var arguments = ["app", "repositories", "--workspace", workspace]
        if ifRunning { arguments.append("--if-running") }
        if includeWorktreeStatus { arguments.append("--include-worktree-status") }
        arguments += ["--format", "json"]
        return try await execute(
            arguments: arguments,
            as: SiloRepositoriesResponse.self,
            command: "repositories"
        )
    }

    func directories(
        workspace: String,
        path: String = ".",
        query: String? = nil,
        limit: Int = 100
    ) async throws -> SiloEnvelope<SiloDirectoryResponse> {
        guard WorkspaceID.isValid(workspace), Self.isSafeRelativePath(path),
              (1...200).contains(limit),
              query.map({ !$0.isEmpty && $0.count <= 128 && Self.isControlFree($0) }) ?? true else {
            throw SiloClientError.invalidArguments
        }
        let command = query == nil ? "directory-list" : "directory-search"
        var arguments = ["app", command, "--workspace", workspace, "--path", path]
        if let query { arguments += ["--query", query] }
        arguments += ["--limit", String(limit), "--format", "json"]
        let envelope = try await execute(
            arguments: arguments,
            as: SiloDirectoryResponse.self,
            command: command,
            timeout: .seconds(20)
        )
        guard let result = envelope.result else {
            throw SiloClientError.malformedJSON(command: command)
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
            throw SiloClientError.malformedJSON(command: command)
        }
        return envelope
    }

    func editorTarget(workspace: String, path: String = ".") async throws -> SiloEnvelope<SiloEditorTarget> {
        guard WorkspaceID.isValid(workspace), Self.isSafeRelativePath(path) else {
            throw SiloClientError.invalidArguments
        }
        let envelope = try await execute(
            arguments: ["app", "editor-target", "--workspace", workspace, "--path", path, "--format", "json"],
            as: SiloEditorTarget.self,
            command: "editor-target",
            timeout: .seconds(20)
        )
        guard let result = envelope.result,
              result.workspace == workspace,
              result.path == path,
              result.host == "\(workspace).msb",
              result.isValid,
              result.remoteURL != nil else {
            throw SiloClientError.malformedJSON(command: "editor-target")
        }
        return envelope
    }

    // MARK: - Host-held secrets

    /// `silo app secrets-list --format json`: nonsecret secret metadata. Real
    /// values live only in the Mac Keychain and never appear in this response.
    func secretsList() async throws -> SiloSecretsListResponse {
        let envelope = try await execute(
            arguments: ["app", "secrets-list", "--format", "json"],
            as: SiloSecretsListResponse.self,
            command: "secrets-list",
            timeout: .seconds(30)
        )
        guard let result = envelope.result else {
            throw SiloClientError.missingResult(command: "secrets-list")
        }
        let entryNames = result.entries.map(\.name)
        let summaryNames = result.workspaces.map(\.workspace)
        guard Set(entryNames).count == entryNames.count,
              Set(summaryNames).count == summaryNames.count,
              result.entries.allSatisfy({ entry in
                  let statusIsConsistent: Bool
                  switch entry.status {
                  case .active:
                      statusIsConsistent = entry.pendingOperation == nil && entry.error == nil
                  case .error:
                      statusIsConsistent = entry.error?.isEmpty == false
                  case .restartRequired, .removalPendingRestart, .appliesOnNextStart:
                      statusIsConsistent = entry.pendingOperation != nil
                  }
                  return SecretNameRule.isValid(entry.name) &&
                      entry.generation >= 1 &&
                      !entry.workspaces.isEmpty &&
                      Set(entry.workspaces).count == entry.workspaces.count &&
                      entry.workspaces.allSatisfy(WorkspaceID.isValid) &&
                      !entry.allowedDomains.isEmpty &&
                      Set(entry.allowedDomains).count == entry.allowedDomains.count &&
                      entry.allowedDomains.allSatisfy(SecretDomainRule.isAllowed) &&
                      entry.pendingOperation.map {
                          SecretOperation(rawValue: $0.type) != nil
                      } ?? true &&
                      statusIsConsistent
              }),
              result.workspaces.allSatisfy({
                  WorkspaceID.isValid($0.workspace) &&
                      $0.pendingCount >= 0 &&
                      (!$0.restartRequired || $0.pendingCount > 0)
              }) else {
            throw SiloClientError.malformedJSON(command: "secrets-list")
        }
        return result
    }

    /// `silo app secret-plan --input-fd 0 --format json`: stages a host-held
    /// secret change. Only nonsecret metadata travels on stdin; the value is
    /// requested at apply time.
    func prepareSecretPlan(_ request: SiloSecretPlanRequest) async throws -> SiloSecretPlanResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let input: Data
        do {
            input = try encoder.encode(request)
        } catch {
            throw SiloClientError.invalidArguments
        }
        let envelope = try await execute(
            arguments: ["app", "secret-plan", "--input-fd", "0", "--format", "json"],
            as: SiloSecretPlanResult.self,
            command: "secret-plan",
            stdin: input,
            timeout: .seconds(60)
        )
        guard let result = envelope.result else {
            throw SiloClientError.missingResult(command: "secret-plan")
        }
        // The staged plan must match the reviewed request exactly; a
        // mismatched plan could pair the entered value with a different
        // target secret or workspace scope.
        guard !result.planId.isEmpty,
              !result.name.isEmpty,
              !result.confirmationPhrase.isEmpty,
              !result.effects.isEmpty,
              result.operation == request.operation,
              result.name == request.name,
              Set(result.affectedWorkspaces) == Set(request.workspaces),
              result.requiresSecret == (request.operation != "remove"),
              result.expiresAt > Date(),
              result.affectedWorkspaces.allSatisfy(WorkspaceID.isValid) else {
            throw SiloClientError.malformedJSON(command: "secret-plan")
        }
        return result
    }

    /// `silo app secret-apply PLAN_ID --input-fd 0 --format json`: commits a
    /// staged secret change. The confirmation phrase and the (optional) value
    /// travel exclusively on stdin; the value is never placed in argv, the
    /// environment, or any persisted app state.
    func applySecretPlan(
        _ plan: SiloSecretPlanResult,
        confirmation: String,
        value: String?
    ) async throws -> SiloSecretApplyResult {
        guard !plan.planId.isEmpty,
              confirmation == plan.confirmationPhrase else {
            throw SiloClientError.invalidArguments
        }
        // The value is mandatory for additions; edits may keep the current
        // Keychain value (nil), and removals never carry one.
        switch plan.operation {
        case "add":
            guard let value, !value.isEmpty else {
                throw SiloClientError.invalidArguments
            }
        case "edit":
            guard value.map({ !$0.isEmpty }) ?? true else {
                throw SiloClientError.invalidArguments
            }
        default:
            guard value == nil else {
                throw SiloClientError.invalidArguments
            }
        }
        let request = SiloSecretApplyRequest(confirmation: confirmation, value: value)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let input: Data
        do {
            input = try encoder.encode(request)
        } catch {
            throw SiloClientError.invalidArguments
        }
        let envelope = try await execute(
            arguments: ["app", "secret-apply", plan.planId, "--input-fd", "0", "--format", "json"],
            as: SiloSecretApplyResult.self,
            command: "secret-apply",
            stdin: input,
            timeout: .seconds(120)
        )
        guard let result = envelope.result else {
            throw SiloClientError.missingResult(command: "secret-apply")
        }
        // The success document must be complete and consistent with the
        // reviewed plan; an empty or mismatched document is malformed.
        guard result.applied,
              result.operation == plan.operation,
              result.name == plan.name,
              Set(result.workspaces) == Set(plan.affectedWorkspaces),
              result.valueStored == (value != nil),
              !result.outcome.isEmpty,
              result.pending.allSatisfy({ WorkspaceID.isValid($0.workspace) }) else {
            throw SiloClientError.malformedJSON(command: "secret-apply")
        }
        return result
    }

    // MARK: - GitHub

    /// `silo github status --format json` (raw, non-envelope CLI output).
    func githubStatus() async throws -> SiloGitHubStatusResponse {
        try await runRawJSON(
            arguments: ["github", "status", "--format", "json"],
            as: SiloGitHubStatusResponse.self,
            command: "github status"
        )
    }

    /// `silo github auth --json`: nonsecret host-credential metadata. Succeeds
    /// fully non-interactively via gh reuse; on failure (gh not authenticated
    /// and no device client ID, or verification failure) the CLI prints a
    /// typed `{ok:false,error}` document to stdout with a nonzero exit.
    func githubAuth(force: Bool = false) async throws -> SiloGitHubAuthMetadata {
        var arguments = ["github", "auth"]
        if force { arguments.append("--force") }
        arguments.append("--json")
        let request = try await runner.makeSiloCommand(arguments: arguments, timeout: .seconds(180))
        let output = try await runner.run(request)
        // Success is the bare nonsecret metadata object. Guard against the
        // failure document decoding as an all-optional metadata struct.
        if let metadata = try? SiloProtocolDecoder.decoder().decode(SiloGitHubAuthMetadata.self, from: output.stdout),
           metadata.accountLogin != nil || metadata.provider != nil {
            guard output.status == 0 else {
                throw SiloClientError.processFailed(
                    command: "github auth",
                    status: output.status,
                    message: "Silo returned success metadata with a failing exit status."
                )
            }
            return metadata
        }
        throw Self.rawCLIError(from: output.stdout, command: "github auth", fallbackStatus: output.status)
    }

    func githubAuthMetadata() async throws -> SiloGitHubAuthMetadata {
        try await githubAuth(force: false)
    }

    /// Revokes the current local host credential. Generic Silo secrets use a
    /// separate metadata and Keychain domain and are intentionally untouched.
    func disconnectGitHub() async throws {
        let request = try await runner.makeSiloCommand(
            arguments: ["github", "disconnect"],
            timeout: .seconds(180)
        )
        let output = try await runner.run(request)
        guard output.status == 0 else {
            let message = output.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SiloClientError.processFailed(
                command: "github disconnect",
                status: output.status,
                message: message.isEmpty ? nil : message
            )
        }
    }

    /// Launches the installed gh CLI's web OAuth flow
    /// (`gh auth login --hostname github.com --git-protocol https --web
    /// --skip-ssh-key`), which opens the default browser and waits for the
    /// user to complete sign-in. The caller retries `githubAuth()` after
    /// this returns. Throws a typed error when gh is unavailable.
    func githubWebLogin() async throws {
        guard let gh = await ghResolver() else {
            throw SiloClientError.unavailable(
                "The GitHub CLI (gh) is not installed on this Mac. Install it, then sign in again."
            )
        }
        let request = SiloCommand(
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
            throw SiloClientError.processFailed(
                command: "gh auth login",
                status: output.status,
                message: message.isEmpty ? nil : message
            )
        }
    }

    /// `silo github repos --format json`: paginated repository discovery
    /// (CLI paginates internally; flat, deduped, sorted by canonical).
    func githubRepos() async throws -> [SiloGitHubDiscoveredRepo] {
        let response = try await runRawCLI(arguments: ["github", "repos", "--format", "json"], command: "github repos")
        guard response.ok == true, let repos = response.repos else {
            throw Self.rawCLIError(from: response, command: "github repos")
        }
        return repos
    }

    /// `silo github auth --device --format json`: one-shot device-flow start.
    /// `deviceId` is the poll handle passed to `githubAuthDeviceComplete`.
    func githubAuthDevice() async throws -> SiloDeviceFlowStart {
        let response = try await runRawCLI(arguments: ["github", "auth", "--device", "--format", "json"], command: "github auth --device")
        guard response.ok == true,
              let deviceId = response.deviceId,
              let code = response.code,
              let verificationUri = response.verificationUri,
              let expiresAt = response.expiresAt else {
            throw Self.rawCLIError(from: response, command: "github auth --device")
        }
        return SiloDeviceFlowStart(
            deviceId: deviceId,
            code: code,
            verificationUri: verificationUri,
            expiresAt: expiresAt,
            interval: response.interval ?? 5
        )
    }

    /// `silo github auth --device-complete DEVICE_ID --format json`: exactly
    /// one exchange attempt (the app drives the poll loop with interval
    /// sleeps). Authorization stores and verifies the credential.
    func githubAuthDeviceComplete(deviceId: String) async throws -> SiloDeviceFlowPoll {
        guard !deviceId.isEmpty else { throw SiloClientError.invalidArguments }
        let response = try await runRawCLI(
            arguments: ["github", "auth", "--device-complete", deviceId, "--format", "json"],
            command: "github auth --device-complete"
        )
        if response.ok == true {
            switch response.status {
            case "slow_down":
                return SiloDeviceFlowPoll(status: .slowDown, interval: response.interval, accountLogin: nil)
            case "authorized":
                return SiloDeviceFlowPoll(
                    status: .authorized,
                    interval: nil,
                    accountLogin: response.metadata?.accountLogin
                )
            case "expired":
                return SiloDeviceFlowPoll(status: .expired, interval: nil, accountLogin: nil)
            case "denied":
                return SiloDeviceFlowPoll(status: .denied, interval: nil, accountLogin: nil)
            default:
                return SiloDeviceFlowPoll(status: .pending, interval: response.interval, accountLogin: nil)
            }
        }
        switch response.status {
        case "expired":
            return SiloDeviceFlowPoll(status: .expired, interval: nil, accountLogin: nil)
        case "denied":
            return SiloDeviceFlowPoll(status: .denied, interval: nil, accountLogin: nil)
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
    ) async throws -> SiloGitHubCLIResponse {
        let request = try await runner.makeSiloCommand(arguments: arguments, timeout: timeout)
        let output = try await runner.run(request)
        do {
            return try SiloProtocolDecoder.decoder().decode(SiloGitHubCLIResponse.self, from: output.stdout)
        } catch {
            let message = output.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SiloClientError.processFailed(
                command: command,
                status: output.status,
                message: message.isEmpty ? nil : message
            )
        }
    }

    /// Converts a decoded raw-CLI response into a typed error.
    private static func rawCLIError(
        from response: SiloGitHubCLIResponse,
        command: String
    ) -> SiloClientError {
        let error = response.error
        return .rawCLIError(
            code: error?.code ?? "SILO_CLI_ERROR",
            message: error?.message ?? "\(command) failed."
        )
    }

    /// Converts raw stdout into a typed raw-CLI error (used by commands whose
    /// success payload is not the union-shaped document).
    private static func rawCLIError(
        from stdout: Data,
        command: String,
        fallbackStatus: Int32
    ) -> SiloClientError {
        if let response = try? SiloProtocolDecoder.decoder().decode(SiloGitHubCLIResponse.self, from: stdout),
           response.ok == false,
           let error = response.error {
            return .rawCLIError(code: error.code ?? "SILO_CLI_ERROR", message: error.message ?? "\(command) failed.")
        }
        let message = String(decoding: stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .processFailed(
            command: command,
            status: fallbackStatus,
            message: message.isEmpty ? nil : message
        )
    }

    /// ONE `silo app github-policy-apply` invocation carrying the FULL desired
    /// policy on stdin. The CLI validates the request, acquires the
    /// per-workspace github locks, provisions/verifies transport for each
    /// semantically changed, non-empty workspace using the final capabilities,
    /// and performs ONE atomic policy-file commit (rolling back byte-exact on
    /// any unproven step).
    /// Typed failures (SILO_INVALID_REQUEST,
    /// SILO_OPERATION_CONFLICT, SILO_TRANSPORT_PROVISION_FAILED,
    /// SILO_POLICY_WRITE_FAILED, SILO_INTERNAL_ERROR) surface as protocol
    /// failures; the caller marks the operation applied only after the CLI
    /// reports provisioned + committed.
    func githubPolicyApply(_ request: SiloGitHubPolicyApplyRequest) async throws -> SiloGitHubPolicyApplyResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let input: Data
        do {
            input = try encoder.encode(request)
        } catch {
            throw SiloClientError.invalidArguments
        }
        let envelope = try await execute(
            arguments: [
                "app", "github-policy-apply",
                "--format", "json"
            ],
            as: SiloGitHubPolicyApplyResult.self,
            command: "github-policy-apply",
            stdin: input,
            timeout: .seconds(600),
            // The CLI's TERM trap restores any temporarily changed workspace
            // lifecycle before releasing locks. Allow its bounded stop stage
            // to finish before process-group SIGKILL escalation.
            terminationGrace: .seconds(65)
        )
        guard let result = envelope.result else {
            throw SiloClientError.missingResult(command: "github-policy-apply")
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
        let request = try await runner.makeSiloCommand(arguments: arguments, timeout: timeout)
        let output = try await runner.run(request)
        guard output.status == 0 else {
            let message = output.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SiloClientError.processFailed(
                command: command,
                status: output.status,
                message: message.isEmpty ? nil : message
            )
        }
        do {
            return try SiloProtocolDecoder.decoder().decode(type, from: output.stdout)
        } catch {
            throw SiloClientError.malformedJSON(command: command)
        }
    }

 
    func preparePushPlan(workspace: String, repositories: [String]) async throws -> SiloEnvelope<SiloPushPlan> {
        guard WorkspaceID.isValid(workspace), repositories.count == 1,
              repositories.allSatisfy(Self.isSafeRelativePath) else {
            throw SiloClientError.invalidArguments
        }
        return try await execute(
            arguments: ["app", "push-plan", "--workspace", workspace, "--repositories"] + repositories + ["--format", "json"],
            as: SiloPushPlan.self,
            command: "push-plan"
        )
    }

    func applyPushPlan(_ plan: SiloPushPlan, confirmation: String) async throws -> SiloEnvelope<SiloPushApplyResult> {
        guard WorkspaceID.isValid(plan.workspace),
              plan.expiresAt > Date(),
              confirmation == plan.confirmationPhrase else {
            throw SiloClientError.invalidArguments
        }
        let input = Data((confirmation + "\n").utf8)
        return try await execute(
            arguments: ["app", "apply", plan.planId, "--confirmation-fd", "0", "--format", "json"],
            as: SiloPushApplyResult.self,
            command: "apply",
            stdin: input,
            timeout: .seconds(120)
        )
    }


    func prepareLifecyclePlan(action: SiloLifecycleAction, workspace: String) async throws -> SiloEnvelope<SiloLifecyclePlan> {
        guard WorkspaceID.isValid(workspace) else { throw SiloClientError.invalidArguments }
        return try await execute(
            arguments: ["app", "plan", action.rawValue, "--workspace", workspace, "--format", "json"],
            as: SiloLifecyclePlan.self,
            command: "plan"
        )
    }

    func applyLifecyclePlan(_ plan: SiloLifecyclePlan, confirmation: String) async throws -> SiloEnvelope<SiloApplyResult> {
        guard WorkspaceID.isValid(plan.workspace),
              SiloLifecycleAction(rawValue: plan.action) != nil,
              plan.expiresAt > Date(),
              confirmation == plan.confirmationPhrase else {
            throw SiloClientError.invalidArguments
        }
        return try await execute(
            arguments: ["app", "apply", plan.planId, "--confirmation-fd", "0", "--format", "json"],
            as: SiloApplyResult.self,
            command: "apply",
            stdin: Data((confirmation + "\n").utf8),
            timeout: .seconds(120)
        )
    }

    func bootstrap(
        workspaceConfigurations: [SetupWorkspaceConfiguration],
        onProgress: (@Sendable (SiloProgressEvent) -> Void)? = nil
    ) async throws -> SiloEnvelope<SiloBootstrapResult> {
        guard SetupWorkspaceConfiguration.validationMessage(for: workspaceConfigurations) == nil else {
            throw SiloClientError.invalidArguments
        }
        let input = try JSONEncoder().encode(SiloBootstrapConfiguration(workspaceConfigurations))
        let eventsFileDescriptor = SiloCommandRunner.progressEventsFileDescriptor
        let request = try await runner.makeSiloCommand(
            arguments: [
                "app", "bootstrap", "--resume", "--workspace-config-fd", "0",
                "--events-fd", String(eventsFileDescriptor), "--format", "json"
            ],
            timeout: .seconds(1800),
            stdin: input
        )
        let output = try await runner.run(
            request,
            eventsFileDescriptor: eventsFileDescriptor
        ) { line in
            let event: SiloProgressEvent
            do {
                event = try SiloProtocolDecoder.decoder().decode(SiloProgressEvent.self, from: line)
            } catch {
                throw SiloClientError.protocolMismatch(
                    command: "bootstrap events",
                    detail: Self.progressProtocolDetail(for: error)
                )
            }
            guard event.schemaVersion == 1 else {
                throw SiloClientError.unsupportedSchema(event.schemaVersion)
            }
            guard event.type == "progress" else {
                throw SiloClientError.protocolMismatch(
                    command: "bootstrap events",
                    detail: "type must be progress."
                )
            }
            guard !event.requestId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SiloClientError.protocolMismatch(
                    command: "bootstrap events",
                    detail: "requestId must not be empty."
                )
            }
            guard !event.phase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SiloClientError.protocolMismatch(
                    command: "bootstrap events",
                    detail: "phase must not be empty."
                )
            }
            onProgress?(event)
        }
        do {
            let envelope = try SiloProtocolDecoder.decodeEnvelope(
                output.stdout,
                as: SiloBootstrapResult.self,
                expectedCommand: "bootstrap"
            )
            guard output.status == 0 else {
                throw SiloClientError.processFailed(
                    command: "bootstrap",
                    status: output.status,
                    message: "Silo returned a success envelope with a failing exit status."
                )
            }
            return envelope
        } catch let error as SiloClientError {
            if case .protocolFailure = error { throw error }
            guard output.status != 0 else { throw error }
            let message = output.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SiloClientError.processFailed(
                command: "bootstrap",
                status: output.status,
                message: message.isEmpty ? nil : message
            )
        }
    }

    private nonisolated static func progressProtocolDetail(for error: Error) -> String {
        func field(_ codingPath: [any CodingKey]) -> String {
            let path = codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? "event" : path
        }

        switch error {
        case DecodingError.typeMismatch(let type, let context):
            return "\(field(context.codingPath)) has an incompatible type; expected \(type)."
        case DecodingError.valueNotFound(let type, let context):
            return "\(field(context.codingPath)) is null; expected \(type)."
        case DecodingError.keyNotFound(let key, _):
            return "required field \(key.stringValue) is missing."
        case DecodingError.dataCorrupted(let context):
            return "\(field(context.codingPath)) is invalid."
        default:
            return "event does not match the progress protocol."
        }
    }
    func url(workspace: String, port: String = "3000", scheme: String = "http") async throws -> SiloEnvelope<SiloURLResult> {
        guard WorkspaceID.isValid(workspace),
              let portNumber = Int(port), (1...65_535).contains(portNumber),
              scheme == "http" || scheme == "https" else {
            throw SiloClientError.invalidArguments
        }
        return try await execute(
            arguments: ["app", "url", "--workspace", workspace, "--port", port, "--scheme", scheme, "--format", "json"],
            as: SiloURLResult.self,
            command: "url"
        )
    }

    func clone(workspace: String, repository: String, destination: String? = nil) async throws -> SiloEnvelope<SiloWorkspaceOperationResult> {
        guard WorkspaceID.isValid(workspace),
              repository.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil,
              destination.map(Self.isSafeRelativePath) ?? true else {
            throw SiloClientError.invalidArguments
        }
        var arguments = ["app", "clone", "--workspace", workspace, "--repository", repository]
        if let destination { arguments += ["--destination", destination] }
        arguments += ["--format", "json"]
        return try await execute(
            arguments: arguments,
            as: SiloWorkspaceOperationResult.self,
            command: "clone",
            timeout: .seconds(600)
        )
    }

    func pull(workspace: String, path: String = "all") async throws -> SiloEnvelope<SiloWorkspaceOperationResult> {
        guard WorkspaceID.isValid(workspace), path == "all" || Self.isSafeRelativePath(path) else {
            throw SiloClientError.invalidArguments
        }
        return try await execute(
            arguments: ["app", "pull", "--workspace", workspace, "--path", path, "--format", "json"],
            as: SiloWorkspaceOperationResult.self,
            command: "pull",
            timeout: .seconds(600)
        )
    }

    func setIdentity(name: String, email: String, workspace: String? = nil) async throws -> SiloEnvelope<SiloIdentityResult> {
        var arguments = ["app", "identity", "--name", name, "--email", email]
        if let workspace { arguments += ["--workspace", workspace] }
        arguments += ["--format", "json"]
        return try await execute(
            arguments: arguments,
            as: SiloIdentityResult.self,
            command: "identity",
            timeout: .seconds(300)
        )
    }

    func disk(workspace: String? = nil) async throws -> SiloEnvelope<SiloWorkspaceOperationResult> {
        var arguments = ["app", "disk"]
        if let workspace { arguments += ["--workspace", workspace] }
        arguments += ["--format", "json"]
        return try await execute(
            arguments: arguments,
            as: SiloWorkspaceOperationResult.self,
            command: "disk",
            timeout: .seconds(300)
        )
    }

    func resize(workspace: String, memory: String, cpus: String? = nil) async throws -> SiloEnvelope<SiloResourceResult> {
        var arguments = ["app", "resize", "--workspace", workspace, "--memory", memory]
        if let cpus { arguments += ["--cpus", cpus] }
        arguments += ["--format", "json"]
        return try await execute(
            arguments: arguments,
            as: SiloResourceResult.self,
            command: "resize",
            timeout: .seconds(120)
        )
    }

    func clean(workspace: String = "all", removeVolumes: Bool = false, confirmation: String) async throws -> SiloEnvelope<SiloMaintenanceResult> {
        guard workspace == "all" || WorkspaceID.isValid(workspace),
              confirmation == (removeVolumes ? "DELETE VOLUMES \(workspace)" : "CLEAN \(workspace)") else {
            throw SiloClientError.invalidArguments
        }
        let input = Data((confirmation + "\n").utf8)
        var arguments = ["app", "clean", "--workspace", workspace]
        if removeVolumes { arguments.append("--volumes") }
        arguments += ["--confirmation-fd", "0", "--format", "json"]
        return try await execute(
            arguments: arguments,
            as: SiloMaintenanceResult.self,
            command: "clean",
            stdin: input,
            timeout: .seconds(600)
        )
    }

    func upgrade(workspace: String = "all", confirmation: String) async throws -> SiloEnvelope<SiloMaintenanceResult> {
        guard workspace == "all" || WorkspaceID.isValid(workspace),
              confirmation == "UPGRADE \(workspace)" else {
            throw SiloClientError.invalidArguments
        }
        let input = Data((confirmation + "\n").utf8)
        return try await execute(
            arguments: ["app", "upgrade", "--workspace", workspace, "--confirmation-fd", "0", "--format", "json"],
            as: SiloMaintenanceResult.self,
            command: "upgrade",
            stdin: input,
            timeout: .seconds(1800)
        )
    }

    func update(confirmation: String) async throws -> SiloEnvelope<SiloMaintenanceResult> {
        guard confirmation == "UPDATE" else { throw SiloClientError.invalidArguments }
        return try await execute(
            arguments: ["app", "update", "--confirmation-fd", "0", "--format", "json"],
            as: SiloMaintenanceResult.self,
            command: "update",
            stdin: Data("UPDATE\n".utf8),
            timeout: .seconds(900)
        )
    }

    func check(deep: Bool = false, confirmation: String? = nil) async throws -> SiloEnvelope<SiloCheckResult> {
        var arguments = ["app", "check"]
        var stdin: Data?
        if deep {
            guard confirmation == "DEEP CHECK" else { throw SiloClientError.invalidArguments }
            arguments += ["--deep", "--confirmation-fd", "0"]
            stdin = Data("DEEP CHECK\n".utf8)
        } else if confirmation != nil {
            throw SiloClientError.invalidArguments
        }
        arguments += ["--format", "json"]
        return try await execute(
            arguments: arguments,
            as: SiloCheckResult.self,
            command: "check",
            stdin: stdin,
            timeout: deep ? .seconds(1800) : .seconds(120)
        )
    }

    func startBackup(directory: URL, requestKey: String) async throws -> SiloEnvelope<SiloBackupOperationResponse> {
        guard requestKey.range(of: #"^[A-Za-z0-9._-]{1,128}$"#, options: .regularExpression) != nil else {
            throw SiloClientError.invalidArguments
        }
        return try await execute(
            arguments: ["app", "backup-start", "--directory", directory.path, "--request-key", requestKey, "--format", "json"],
            as: SiloBackupOperationResponse.self,
            command: "backup-start",
            timeout: .seconds(30)
        )
    }

    func listBackups() async throws -> SiloEnvelope<[SiloBackupOperationResponse]> {
        try await execute(
            arguments: ["app", "backup-list", "--format", "json"],
            as: [SiloBackupOperationResponse].self,
            command: "backup-list",
            timeout: .seconds(30)
        )
    }

    func backupStatus(id: String) async throws -> SiloEnvelope<SiloBackupOperationResponse> {
        guard id.range(of: #"^[a-z0-9-]{8,64}$"#, options: .regularExpression) != nil else {
            throw SiloClientError.invalidArguments
        }
        return try await execute(
            arguments: ["app", "backup-status", "--operation-id", id, "--format", "json"],
            as: SiloBackupOperationResponse.self,
            command: "backup-status",
            timeout: .seconds(30)
        )
    }

    func previewBackup(directory: URL) async throws -> SiloEnvelope<SiloBackupPreviewResponse> {
        try await execute(
            arguments: ["app", "backup-preview", "--directory", directory.path, "--format", "json"],
            as: SiloBackupPreviewResponse.self,
            command: "backup-preview",
            timeout: .seconds(300)
        )
    }

    func restore(archive: URL, confirmation: String) async throws -> SiloEnvelope<SiloWorkspaceOperationResult> {
        guard confirmation == "RESTORE", archive.isFileURL, archive.pathExtension == "zst" else {
            throw SiloClientError.invalidArguments
        }
        let input = Data((confirmation + "\n").utf8)
        return try await execute(
            arguments: ["app", "restore", "--archive", archive.path, "--confirmation-fd", "0", "--format", "json"],
            as: SiloWorkspaceOperationResult.self,
            command: "restore",
            stdin: input,
            timeout: .seconds(1800)
        )
    }


    private func execute<Value: Codable & Sendable>(
        arguments: [String],
        as type: Value.Type,
        command: String,
        stdin: Data? = nil,
        timeout: Duration = .seconds(30),
        terminationGrace: Duration = .milliseconds(250)
    ) async throws -> SiloEnvelope<Value> {
        let request = try await runner.makeSiloCommand(
            arguments: arguments,
            timeout: timeout,
            stdin: stdin,
            terminationGrace: terminationGrace
        )
        let output = try await runner.run(request)
        do {
            let envelope = try SiloProtocolDecoder.decodeEnvelope(output.stdout, as: type, expectedCommand: command)
            guard output.status == 0 else {
                throw SiloClientError.processFailed(
                    command: command,
                    status: output.status,
                    message: "Silo returned a success envelope with a failing exit status."
                )
            }
            return envelope
        } catch let error as SiloClientError {
            if case .protocolFailure = error {
                throw error
            }
            guard output.status != 0 else { throw error }
            let message = output.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SiloClientError.processFailed(
                command: command,
                status: output.status,
                message: message.isEmpty ? nil : message
            )
        }
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
        _ entries: [SiloDirectoryResponse.Entry]
    ) -> [SiloDirectoryResponse.Entry] {
        entries.flatMap { entry in
            [entry] + flattenedDirectoryEntries(entry.children)
        }
    }

    private static func directoryEntriesAreValid(
        _ entries: [SiloDirectoryResponse.Entry],
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
        let lifecycle: SiloLifecycle
        let freshness: SiloFreshness
        let reason: String?
        let lines: [SiloLogEntry]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            workspace = try container.decode(String.self, forKey: .workspace)
            available = try container.decode(Bool.self, forKey: .available)
            lifecycle = try container.decode(SiloLifecycle.self, forKey: .lifecycle)
            freshness = try container.decode(SiloFreshness.self, forKey: .freshness)
            reason = try container.decodeIfPresent(String.self, forKey: .reason)
            lines = try container.decode([SiloLogEntry].self, forKey: .lines)
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
        let lifecycle: SiloLifecycle?
        let freshness: SiloFreshness?
        let reason: String?
        let source: String?
        let sessionID: Int?
        let encoding: String?
        let message: String?
        let safeForDisplay: Bool

        enum CodingKeys: String, CodingKey {
            case schemaVersion, type, protocolVersion, stream, requestId, workspace
            case observedAt, available, lifecycle, freshness, reason, source, encoding
            case message, safeForDisplay
            case sessionID = "sessionId"
        }
    }
}

enum SiloLifecycleAction: String, Codable, Sendable {
    case start
    case stop
    case restart
}
