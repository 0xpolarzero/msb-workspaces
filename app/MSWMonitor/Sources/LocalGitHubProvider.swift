import Foundation

/// Path C mode switch (§1): decided once at app launch. `local` is the
/// default; `connect` is used only when the build carries a trusted Connect
/// scope attestation.
enum GitHubAccessMode: String, Sendable, Equatable {
    case local
    case connect
}

/// The app-facing GitHub surface. SetupView/SettingsView depend on this
/// behavior, not on the Connect types. `GitHubLocalProvider` conforms in
/// local mode; `GitHubAuthorizationCoordinator` is NOT retrofitted (it stays
/// Connect-only).
protocol GitHubProviding: Sendable {
    var isAvailable: Bool { get }
    func loadCatalog() async throws -> GitHubCatalog
    func commit(_ policy: [GitHubWorkspacePolicy]) async throws
    func currentPolicy() async -> GitHubPolicyFile?
    func removeAllAccess() async throws
    /// Runs the CLI-owned host-credential acquisition (gh reuse, fully
    /// non-TTY). Throws `.ghWebLoginRequired` when gh is not authenticated
    /// and no device-flow client ID is configured (the app then launches the
    /// installed gh web OAuth flow and retries), or `.deviceFlowAvailable`
    /// when the CLI reports the OAuth Device Flow is the intended path
    /// (MSW_HOST_DEVICE_FLOW_INTERACTIVE_REQUIRED from `github auth --json`).
    func connectAccount() async throws -> GitHubAccount?
    /// Launches the installed gh CLI's web OAuth flow
    /// (`gh auth login --hostname github.com --git-protocol https --web
    /// --skip-ssh-key`), which opens the default browser and waits for the
    /// user to complete sign-in. The caller retries `connectAccount()` after
    /// it returns. Throws when gh is unavailable or the flow fails.
    func launchGhWebLogin() async throws
    /// One-shot device-flow start; the caller drives polling with
    /// `pollDeviceFlow(deviceId:)` at `interval` sleeps.
    func startDeviceFlow() async throws -> MSWDeviceFlowStart
    func pollDeviceFlow(deviceId: String) async throws -> MSWDeviceFlowPoll
    /// Local onboarding's desired/effective cutover. Implementations that do
    /// not support the background contract may use the synchronous default.
    func beginPolicyApply(_ policy: [GitHubWorkspacePolicy]) async throws -> GitHubApplyProgress
    func currentPolicyApplyProgress() async -> GitHubApplyProgress?
    func waitForCurrentPolicyApply() async throws
    func retryCurrentPolicyApply() async throws
    func cancelCurrentPolicyApply() async
    func setIdentity(name: String, email: String, workspace: String?) async throws -> MSWIdentityResult
    /// Rebuilds every workspace-scoped target after the selected bootstrap
    /// configuration has been operationally applied and read back.
    func reloadWorkspaceConfiguration(_ configurations: [SetupWorkspaceConfiguration]) async throws
}

enum GitHubApplyPhase: String, Codable, Sendable, Equatable {
    case validating
    case saving
    case configuring
    case restoring
    case activating
    case completed
    case failed
    case cancelled
}

struct GitHubApplyFailure: Codable, Sendable, Equatable {
    let code: String
    let message: String
    let recovery: String
    let workspace: String?
    let retryable: Bool
}

enum GitHubPolicyApplyError: Error, LocalizedError, Sendable, Equatable {
    case failed(GitHubApplyFailure)

    var errorDescription: String? {
        guard case .failed(let failure) = self else { return nil }
        return failure.message
    }
}

struct GitHubApplyProgress: Sendable, Equatable {
    let generation: Int
    let phase: GitHubApplyPhase
    let workspace: String?
    let failure: GitHubApplyFailure?

    var isTerminalSuccess: Bool { phase == .completed }
    var isInFlight: Bool {
        [.validating, .saving, .configuring, .restoring, .activating].contains(phase)
    }

    var summary: String {
        let scope = workspace.map { " for \($0)" } ?? ""
        switch phase {
        case .validating: return "Validating GitHub access\(scope)…"
        case .saving: return "Saving your GitHub repository choices…"
        case .configuring: return "Configuring GitHub transport\(scope)…"
        case .restoring: return "Restoring workspace lifecycle\(scope)…"
        case .activating: return "Applying your GitHub repository choices…"
        case .completed: return "Your GitHub repository choices are active."
        case .failed: return failure?.message ?? "GitHub reconciliation failed."
        case .cancelled: return "GitHub reconciliation was cancelled."
        }
    }
}

extension GitHubProviding {
    func beginPolicyApply(_ policy: [GitHubWorkspacePolicy]) async throws -> GitHubApplyProgress {
        try await commit(policy)
        return GitHubApplyProgress(generation: 0, phase: .completed, workspace: nil, failure: nil)
    }
    func currentPolicyApplyProgress() async -> GitHubApplyProgress? { nil }
    func waitForCurrentPolicyApply() async throws {}
    func retryCurrentPolicyApply() async throws {
        throw GitHubCatalogError.unavailable("This GitHub provider cannot retry local policy reconciliation.")
    }
    func cancelCurrentPolicyApply() async {}
    func setIdentity(name: String, email: String, workspace: String?) async throws -> MSWIdentityResult {
        throw GitHubCatalogError.unavailable("Workspace Git identity is unavailable for this GitHub provider.")
    }
    func reloadWorkspaceConfiguration(_ configurations: [SetupWorkspaceConfiguration]) async throws {}
}

/// Catalog for the existing picker models. `installations` is a synthetic
/// one-installation-per-owner adaptation: in local mode the owner scope
/// replaces the GitHub App installation scope.
struct GitHubCatalog: Sendable, Equatable {
    var account: GitHubAccount?
    var hostCredentialPresent: Bool
    var installations: [GitHubInstallation]
    var repositoriesByInstallation: [Int: [GitHubRepository]]
}

enum GitHubCatalogError: Error, LocalizedError, Sendable, Equatable {
    case notLocalMode(String)
    case unavailable(String)
    case commitFailed(String)
    /// gh is not authenticated and no device-flow client ID is configured;
    /// the app must launch the installed gh CLI's web OAuth flow and then
    /// retry host-credential acquisition.
    case ghWebLoginRequired
    /// The CLI reported that the OAuth Device Flow is available (a client ID
    /// is explicitly configured); the app presents the in-app device sheet.
    case deviceFlowAvailable
    /// The CLI reported the device flow cannot run (typed remedy to surface
    /// verbatim).
    case notConfigured(String)

    var errorDescription: String? {
        switch self {
        case .notLocalMode(let message): return message
        case .unavailable(let message): return message
        case .commitFailed(let message): return message
        case .ghWebLoginRequired: return "GitHub sign-in on this Mac is required."
        case .deviceFlowAvailable: return "GitHub Device Flow authorization is required."
        case .notConfigured(let message): return message
        }
    }
}

enum GitHubLocalStrings {
    static let settingsNoCredential = "GitHub account not connected on this Mac"
    static let settingsConnectAccount = "Connect GitHub account on this Mac…"
    static let noReposCopy = "No repositories found."
    static let detailFootnote = "GitHub access is enforced by the local proxy on this Mac. Your workspace never receives a GitHub credential. Local editing and commits always work."
}

/// Local-mode provider. The repo catalog is assembled from the policy file
/// (read-back through `msw github status --format json`, which lists every
/// workspace's ticked repos) plus repositories the user enters by
/// OWNER/REPO in the picker; the CLI exposes no GitHub repo enumeration, so
/// the app never adds one. Credential/account state comes from the CLI
/// (`github status`, `github auth --json`) — the app only reads status and
/// never holds the token.
actor GitHubLocalProvider: GitHubProviding {
    private let client: MSWClient
    private let policyStore: GitHubPolicyStore
    private let policyURL: URL
    private var applyProgress: GitHubApplyProgress?
    private var currentApplyTask: Task<Void, Never>?
    private var currentApplyGeneration: Int?
    private var mutationTail: Task<Void, Never>?
    private var desiredRequest: MSWGitHubPolicyApplyRequest?
    private var desiredHash: String?
    private var nextGeneration: Int
    private var persistedCompletionNeedsVerification: Bool
    private var configuredWorkspaces: [String]

    init(
        client: MSWClient,
        policyStore: GitHubPolicyStore,
        workspaceConfigurations: [SetupWorkspaceConfiguration] = SetupWorkspaceConfiguration.defaults
    ) {
        self.client = client
        self.policyStore = policyStore
        self.policyURL = policyStore.policyURL
        self.configuredWorkspaces = workspaceConfigurations.map(\.name)
        let persisted = GitHubPolicyStore.readIntent(policyURL: policyStore.policyURL)
        let persistedDesired = persisted.map { Self.intentRequest($0.desired) }
        self.nextGeneration = persisted?.generation ?? 0
        self.persistedCompletionNeedsVerification = persisted?.status == .completed
        self.desiredRequest = persistedDesired
        self.desiredHash = persisted?.semanticHash
        if let persisted {
            let phase: GitHubApplyPhase
            switch persisted.status {
            case .pending: phase = .saving
            case .failed: phase = .failed
            case .completed: phase = .completed
            case .cancelled: phase = .cancelled
            }
            self.applyProgress = GitHubApplyProgress(
                generation: persisted.generation,
                phase: phase,
                workspace: persisted.failure?.workspace,
                failure: persisted.failure
            )
            // Older prerelease intent files may have duplicated effective
            // capability values. Intent is repository-only; scrub those
            // bearer values at the first provider construction.
            if let persistedDesired, persistedDesired != persisted.desired {
                try? GitHubPolicyStore.writeIntent(
                    GitHubApplyPersistentState(
                        schemaVersion: persisted.schemaVersion,
                        generation: persisted.generation,
                        semanticHash: persisted.semanticHash,
                        status: persisted.status,
                        desired: persistedDesired,
                        updatedAt: Date(),
                        failure: persisted.failure
                    ),
                    policyURL: policyStore.policyURL
                )
            }
        }
    }

    nonisolated var isAvailable: Bool { true }

    func reloadWorkspaceConfiguration(_ configurations: [SetupWorkspaceConfiguration]) async throws {
        if let validation = SetupWorkspaceConfiguration.validationMessage(for: configurations) {
            throw BootstrapCoordinatorError.invalidWorkspaceConfiguration(validation)
        }
        await cancelCurrentPolicyApply()
        let names = configurations.map(\.name)
        try await client.reloadWorkspaceConfiguration(configurations)
        configuredWorkspaces = names
        let persisted = GitHubPolicyStore.readIntent(policyURL: policyURL)
        let intentMatchesConfiguration = persisted.map {
            Set($0.desired.workspaces.keys) == Set(names)
        } ?? false
        nextGeneration = max(nextGeneration, persisted?.generation ?? 0)
        desiredRequest = persisted.map { Self.scopedRequest($0.desired, workspaces: names) }
        desiredHash = intentMatchesConfiguration
            ? desiredRequest.map { Self.semanticHash($0, workspaces: names) }
            : nil
        persistedCompletionNeedsVerification = intentMatchesConfiguration && persisted?.status == .completed
        if let persisted, intentMatchesConfiguration {
            let phase: GitHubApplyPhase
            switch persisted.status {
            case .pending: phase = .saving
            case .failed: phase = .failed
            case .completed: phase = .completed
            case .cancelled: phase = .cancelled
            }
            applyProgress = GitHubApplyProgress(
                generation: persisted.generation,
                phase: phase,
                workspace: persisted.failure?.workspace.flatMap { names.contains($0) ? $0 : nil },
                failure: persisted.failure.flatMap { failure in
                    (failure.workspace.map(names.contains) ?? true) ? failure : nil
                }
            )
        } else {
            applyProgress = nil
        }
    }

    func loadCatalog() async throws -> GitHubCatalog {
        let status = try await client.githubStatus()
        guard status.mode == GitHubAccessMode.local.rawValue else {
            throw GitHubCatalogError.notLocalMode(
                "GitHub is in \(status.mode) mode on this Mac; local repository access is unavailable."
            )
        }
        let configured = Set(configuredWorkspaces)
        let hasCredential = status.workspaces.contains {
            configured.contains($0.workspace) && $0.hostCredential == "present"
        }
        var account: GitHubAccount?
        if hasCredential, let metadata = try? await client.githubAuthMetadata(),
           let login = metadata.accountLogin, !login.isEmpty {
            account = GitHubAccount(login: login, id: Self.stableID(login), name: nil, email: nil)
        }
        // Discovery requires the host credential; without one the catalog is
        // empty and the caller surfaces the no-credential state.
        let discovered: [MSWGitHubDiscoveredRepo]
        if hasCredential {
            do {
                discovered = try await client.githubRepos()
            } catch {
                throw GitHubCatalogError.unavailable(error.localizedDescription)
            }
        } else {
            discovered = []
        }
        var installations: [GitHubInstallation] = []
        var repositoriesByInstallation: [Int: [GitHubRepository]] = [:]
        var seenOwners: [Int: GitHubInstallationAccount] = [:]
        for repo in discovered.sorted(by: { $0.canonical < $1.canonical }) {
            let ownerID = Self.stableID(repo.owner)
            let ownerAccount = seenOwners[ownerID]
                ?? GitHubInstallationAccount(login: repo.owner, id: ownerID, type: nil)
            seenOwners[ownerID] = ownerAccount
            if repositoriesByInstallation[ownerID] == nil {
                installations.append(GitHubInstallation(
                    id: ownerID,
                    account: ownerAccount,
                    repositorySelection: nil
                ))
            }
            let repository = GitHubRepository(
                id: Self.stableID(repo.canonical),
                fullName: repo.canonical,
                name: repo.name,
                owner: ownerAccount,
                `private`: repo.private,
                defaultBranch: nil,
                canPush: repo.permissions.push,
                inPolicy: repo.inPolicy
            )
            if !(repositoriesByInstallation[ownerID]?.contains(where: { $0.id == repository.id }) ?? false) {
                repositoriesByInstallation[ownerID, default: []].append(repository)
            }
        }
        return GitHubCatalog(
            account: account,
            hostCredentialPresent: hasCredential,
            installations: installations,
            repositoriesByInstallation: repositoriesByInstallation
        )
    }

    func currentPolicy() async -> GitHubPolicyFile? {
        guard let policy = await policyStore.current else { return nil }
        return GitHubPolicyFile(
            schemaVersion: policy.schemaVersion,
            workspaces: Dictionary(uniqueKeysWithValues: configuredWorkspaces.map {
                ($0, policy.workspaces[$0] ?? GitHubPolicyWorkspace(capability: nil, repos: []))
            }),
            updatedAt: policy.updatedAt
        )
    }

    /// Validates and durably records intent, then returns immediately. The
    /// generation's CLI transaction runs in a child task; newer generations
    /// cancel it and are serialized behind cleanup by `mutationTail`.
    func beginPolicyApply(_ policy: [GitHubWorkspacePolicy]) async throws -> GitHubApplyProgress {
        let request = try await makeRequest(policy, preserving: desiredRequest)
        let hash = Self.semanticHash(request, workspaces: configuredWorkspaces)
        if hash == desiredHash, let applyProgress {
            if applyProgress.isInFlight { return applyProgress }
            if applyProgress.phase == .completed, await matchesEffectivePolicy(request) {
                return applyProgress
            }
        }

        nextGeneration &+= 1
        let generation = nextGeneration
        let supersedesInFlight = applyProgress?.isInFlight == true && currentApplyTask != nil
        currentApplyTask?.cancel()
        desiredRequest = request
        desiredHash = hash
        let firstChanged = await firstChangedNonEmptyWorkspace(in: request)
        let progress = GitHubApplyProgress(
            generation: generation,
            phase: .saving,
            workspace: firstChanged,
            failure: nil
        )
        try persist(request: request, hash: hash, progress: progress, status: .pending)
        applyProgress = progress

        // A semantic match with the effective policy is a true no-op: it
        // supersedes stale work without restarting transport.
        if !supersedesInFlight, await matchesEffectivePolicy(request) {
            let completed = GitHubApplyProgress(
                generation: generation,
                phase: .completed,
                workspace: nil,
                failure: nil
            )
            applyProgress = completed
            try persist(request: request, hash: hash, progress: completed, status: .completed)
            return completed
        }

        startReconciliation(request: request, hash: hash, generation: generation, workspace: firstChanged)
        return progress
    }

    func currentPolicyApplyProgress() async -> GitHubApplyProgress? {
        if persistedCompletionNeedsVerification,
           applyProgress?.phase == .completed,
           let desiredRequest, let desiredHash {
            persistedCompletionNeedsVerification = false
            if !(await matchesEffectivePolicy(desiredRequest)) {
                nextGeneration &+= 1
                let generation = nextGeneration
                let workspace = await firstChangedNonEmptyWorkspace(in: desiredRequest)
                let pending = GitHubApplyProgress(
                    generation: generation,
                    phase: .saving,
                    workspace: workspace,
                    failure: nil
                )
                applyProgress = pending
                try? persist(request: desiredRequest, hash: desiredHash, progress: pending, status: .pending)
                startReconciliation(
                    request: desiredRequest,
                    hash: desiredHash,
                    generation: generation,
                    workspace: workspace
                )
            }
        }
        if currentApplyTask == nil, let applyProgress,
           applyProgress.phase == .saving, let desiredRequest, let desiredHash {
            let generation = applyProgress.generation
            startReconciliation(
                request: desiredRequest,
                hash: desiredHash,
                generation: generation,
                workspace: applyProgress.workspace
            )
        }
        return applyProgress
    }

    func waitForCurrentPolicyApply() async throws {
        while true {
            _ = await currentPolicyApplyProgress()
            guard let task = currentApplyTask, let generation = currentApplyGeneration else { break }
            await task.value
            // A Back/edit may supersede the generation while this caller is
            // waiting. Gate Review/Done on the newest task, never the task
            // that happened to be current when the wait began.
            if currentApplyGeneration != generation { continue }
            break
        }
        guard let progress = applyProgress else { return }
        if progress.phase == .failed {
            let failure = progress.failure ?? GitHubApplyFailure(
                code: "MSW_GITHUB_RECONCILIATION_FAILED",
                message: "GitHub reconciliation failed.",
                recovery: "Check the workspace runtime, then retry GitHub reconciliation.",
                workspace: progress.workspace,
                retryable: true
            )
            throw GitHubPolicyApplyError.failed(failure)
        }
        if progress.phase == .cancelled { throw CancellationError() }
    }

    func retryCurrentPolicyApply() async throws {
        guard let desiredRequest, let desiredHash else {
            throw GitHubCatalogError.commitFailed("There is no saved GitHub policy to retry.")
        }
        nextGeneration &+= 1
        let generation = nextGeneration
        let workspace = await firstChangedNonEmptyWorkspace(in: desiredRequest)
        let progress = GitHubApplyProgress(generation: generation, phase: .saving, workspace: workspace, failure: nil)
        try persist(request: desiredRequest, hash: desiredHash, progress: progress, status: .pending)
        applyProgress = progress
        currentApplyTask?.cancel()
        startReconciliation(request: desiredRequest, hash: desiredHash, generation: generation, workspace: workspace)
    }

    func cancelCurrentPolicyApply() async {
        guard let task = currentApplyTask, let generation = currentApplyGeneration else { return }
        task.cancel()
        await task.value
        // Actor reentrancy permits a newer generation to start during the
        // await above. Never clear or cancel that newer task/state.
        guard currentApplyGeneration == generation else { return }
        currentApplyTask = nil
        currentApplyGeneration = nil
        guard let progress = applyProgress, progress.isInFlight,
              progress.generation == generation,
              let desiredRequest, let desiredHash else { return }
        let cancelled = GitHubApplyProgress(
            generation: progress.generation,
            phase: .cancelled,
            workspace: progress.workspace,
            failure: nil
        )
        applyProgress = cancelled
        try? persist(request: desiredRequest, hash: desiredHash, progress: cancelled, status: .cancelled)
    }

    func setIdentity(name: String, email: String, workspace: String?) async throws -> MSWIdentityResult {
        let expected = workspace.map { [$0] } ?? configuredWorkspaces
        guard !expected.isEmpty,
              expected.allSatisfy({ configuredWorkspaces.contains($0) }) else {
            throw MSWClientError.invalidArguments
        }
        let result = try await performMutation { [client] in
            let response = try await client.setIdentity(name: name, email: email, workspace: workspace)
            guard let result = response.result else {
                throw MSWClientError.missingResult(command: "identity")
            }
            return result
        }
        guard Set(result.workspaces) == Set(expected) else {
            throw GitHubCatalogError.commitFailed(
                "Git identity was not verified for the selected workspace configuration."
            )
        }
        return result
    }

    /// Applies the desired per-workspace policy through ONE journaled CLI
    /// transaction (`msw app github-policy-apply`) that carries the full
    /// desired policy on stdin, provisions/verifies transport only for changed
    /// non-empty workspaces, and commits atomically (rollback on an unproven
    /// step).
    /// Only returns once the CLI confirms provisioned + committed; unedited
    /// workspaces keep their current policy entries.
    func commit(_ policy: [GitHubWorkspacePolicy]) async throws {
        _ = try await beginPolicyApply(policy)
        try await waitForCurrentPolicyApply()
    }

    private func makeRequest(
        _ policy: [GitHubWorkspacePolicy],
        preserving pendingRequest: MSWGitHubPolicyApplyRequest?
    ) async throws -> MSWGitHubPolicyApplyRequest {
        let current = await policyStore.current
        var edited: [String: GitHubWorkspacePolicy] = [:]
        for workspacePolicy in policy {
            guard edited[workspacePolicy.workspace] == nil else {
                throw GitHubCatalogError.commitFailed(
                    "Workspace \(workspacePolicy.workspace) appears more than once in the desired GitHub policy."
                )
            }
            edited[workspacePolicy.workspace] = workspacePolicy
        }
        var workspaces: [String: GitHubPolicyWorkspace] = [:]
        guard Set(edited.keys).isSubset(of: Set(configuredWorkspaces)) else {
            throw GitHubCatalogError.commitFailed(
                "GitHub policy includes a workspace outside the applied configuration."
            )
        }
        for workspace in configuredWorkspaces {
            guard WorkspaceID.isValid(workspace) else {
                throw GitHubCatalogError.commitFailed("Invalid workspace \(workspace).")
            }
            if let workspacePolicy = edited[workspace] {
                var repos: [GitHubPolicyRepository] = []
                for repository in workspacePolicy.repositories {
                    let canonical = Self.canonicalize(repository.fullName)
                    guard Self.isValidCanonical(canonical) else {
                        throw GitHubCatalogError.commitFailed(
                            "\(repository.fullName) is not a valid OWNER/REPOSITORY identifier."
                        )
                    }
                    repos.append(GitHubPolicyRepository(canonical: canonical, mode: repository.mode))
                }
                repos.sort { $0.canonical < $1.canonical }
                workspaces[workspace] = GitHubPolicyWorkspace(
                    capability: nil,
                    repos: repos
                )
            } else if let pending = pendingRequest?.workspaces[workspace] {
                // A new partial edit while reconciliation is pending builds on
                // the newest desired generation, not the still-old effective
                // file. Otherwise editing playgrounds could silently discard
                // a pending dev choice.
                workspaces[workspace] = GitHubPolicyWorkspace(capability: nil, repos: pending.repos)
            } else if let existing = current?.workspaces[workspace] {
                // Unedited workspace: keep its current entries so a missing
                // key never clears it (the CLI treats absence as "clear").
                workspaces[workspace] = GitHubPolicyWorkspace(
                    capability: nil,
                    repos: existing.repos
                )
            } else {
                workspaces[workspace] = GitHubPolicyWorkspace(capability: nil, repos: [])
            }
        }
        return MSWGitHubPolicyApplyRequest(schemaVersion: 1, workspaces: workspaces)
    }

    private static func apply(
        _ request: MSWGitHubPolicyApplyRequest,
        with client: MSWClient
    ) async throws {
        let result = try await client.githubPolicyApply(request)
        guard result.applied == true, result.provisioned == true, result.committed == true else {
            throw GitHubCatalogError.commitFailed(
                "The CLI did not confirm the policy was provisioned and committed."
            )
        }
    }

    private func startReconciliation(
        request: MSWGitHubPolicyApplyRequest,
        hash: String,
        generation: Int,
        workspace: String?
    ) {
        let configuring = GitHubApplyProgress(
            generation: generation,
            phase: .configuring,
            workspace: workspace,
            failure: nil
        )
        if applyProgress?.generation == generation { applyProgress = configuring }
        let operation = makeMutationTask { [client] in
            try await Self.apply(request, with: client)
        }
        currentApplyTask = Task { [weak self] in
            await self?.finishReconciliation(
                operation: operation,
                request: request,
                hash: hash,
                generation: generation,
                workspace: workspace
            )
        }
        currentApplyGeneration = generation
    }

    private func finishReconciliation(
        operation: Task<Void, Error>,
        request: MSWGitHubPolicyApplyRequest,
        hash: String,
        generation: Int,
        workspace: String?
    ) async {
        do {
            try await withTaskCancellationHandler {
                try await operation.value
            } onCancel: {
                operation.cancel()
            }
            guard applyProgress?.generation == generation else { return }
            let restoring = GitHubApplyProgress(
                generation: generation,
                phase: .restoring,
                workspace: workspace,
                failure: nil
            )
            applyProgress = restoring
            await Task.yield()
            let activating = GitHubApplyProgress(
                generation: generation,
                phase: .activating,
                workspace: nil,
                failure: nil
            )
            applyProgress = activating
            let completed = GitHubApplyProgress(
                generation: generation,
                phase: .completed,
                workspace: nil,
                failure: nil
            )
            applyProgress = completed
            persistedCompletionNeedsVerification = false
            try persist(request: request, hash: hash, progress: completed, status: .completed)
            if currentApplyGeneration == generation {
                currentApplyTask = nil
                currentApplyGeneration = nil
            }
        } catch is CancellationError {
            // A newer generation owns the visible state. Setup-close
            // cancellation is finalized by `cancelCurrentPolicyApply` after
            // the process group and CLI locks have been released.
        } catch let error as MSWClientError where error == .cancelled {
            // Same cancellation contract as Swift CancellationError.
        } catch {
            guard applyProgress?.generation == generation else { return }
            let failure = Self.failure(for: error, workspace: workspace)
            let failed = GitHubApplyProgress(
                generation: generation,
                phase: .failed,
                workspace: failure.workspace,
                failure: failure
            )
            applyProgress = failed
            try? persist(request: request, hash: hash, progress: failed, status: .failed)
            if currentApplyGeneration == generation {
                currentApplyTask = nil
                currentApplyGeneration = nil
            }
        }
    }

    private func performMutation<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let task = makeMutationTask(operation)
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func makeMutationTask<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) -> Task<Value, Error> {
        let predecessor = mutationTail
        let task = Task<Value, Error> {
            if let predecessor { await predecessor.value }
            try Task.checkCancellation()
            return try await operation()
        }
        mutationTail = Task { _ = try? await task.value }
        return task
    }

    private func matchesEffectivePolicy(_ request: MSWGitHubPolicyApplyRequest) async -> Bool {
        guard let current = await policyStore.current else {
            return request.workspaces.values.allSatisfy(\.repos.isEmpty)
        }
        for workspace in configuredWorkspaces {
            let desired = request.workspaces[workspace]?.repos ?? []
            let effective = current.workspaces[workspace]?.repos ?? []
            if desired != effective { return false }
        }
        return true
    }

    private func firstChangedNonEmptyWorkspace(
        in request: MSWGitHubPolicyApplyRequest
    ) async -> String? {
        let current = await policyStore.current
        return configuredWorkspaces.first { workspace in
            let desired = request.workspaces[workspace]?.repos ?? []
            let effective = current?.workspaces[workspace]?.repos ?? []
            return !desired.isEmpty && desired != effective
        }
    }

    private func persist(
        request: MSWGitHubPolicyApplyRequest,
        hash: String,
        progress: GitHubApplyProgress,
        status: GitHubApplyPersistenceStatus
    ) throws {
        try GitHubPolicyStore.writeIntent(
            GitHubApplyPersistentState(
                schemaVersion: 1,
                generation: progress.generation,
                semanticHash: hash,
                status: status,
                desired: Self.intentRequest(request),
                updatedAt: Date(),
                failure: progress.failure
            ),
            policyURL: policyURL
        )
    }

    private static func semanticHash(
        _ request: MSWGitHubPolicyApplyRequest,
        workspaces: [String]
    ) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for workspace in workspaces {
            for repo in (request.workspaces[workspace]?.repos ?? []).sorted(by: { $0.canonical < $1.canonical }) {
                for byte in "\(workspace)\u{0}\(repo.canonical)\u{0}\(repo.mode.rawValue)\u{0}".utf8 {
                    hash ^= UInt64(byte)
                    hash &*= 1_099_511_628_211
                }
            }
        }
        return String(format: "%016llx", hash)
    }

    /// Desired intent deliberately excludes effective proxy capabilities.
    /// The CLI preserves or mints them while holding the policy locks.
    private static func intentRequest(
        _ request: MSWGitHubPolicyApplyRequest
    ) -> MSWGitHubPolicyApplyRequest {
        MSWGitHubPolicyApplyRequest(
            schemaVersion: request.schemaVersion,
            workspaces: request.workspaces.mapValues {
                GitHubPolicyWorkspace(capability: nil, repos: $0.repos)
            }
        )
    }

    private static func scopedRequest(
        _ request: MSWGitHubPolicyApplyRequest,
        workspaces: [String]
    ) -> MSWGitHubPolicyApplyRequest {
        MSWGitHubPolicyApplyRequest(
            schemaVersion: request.schemaVersion,
            workspaces: Dictionary(uniqueKeysWithValues: workspaces.map {
                ($0, GitHubPolicyWorkspace(
                    capability: nil,
                    repos: request.workspaces[$0]?.repos ?? []
                ))
            })
        )
    }

    private static func failure(for error: Error, workspace: String?) -> GitHubApplyFailure {
        if let clientError = error as? MSWClientError,
           case .protocolFailure(let protocolError) = clientError {
            return GitHubApplyFailure(
                code: protocolError.code,
                message: protocolError.message,
                recovery: protocolError.recovery ?? "Retry GitHub reconciliation.",
                workspace: protocolError.workspace ?? workspace,
                retryable: protocolError.retryable
            )
        }
        return GitHubApplyFailure(
            code: "MSW_GITHUB_RECONCILIATION_FAILED",
            message: error.localizedDescription,
            recovery: "Check the workspace runtime, then retry GitHub reconciliation.",
            workspace: workspace,
            retryable: true
        )
    }

    func removeAllAccess() async throws {
        let cleared = configuredWorkspaces.map {
            GitHubWorkspacePolicy(workspace: $0, repositories: [])
        }
        try await commit(cleared)
    }

    func connectAccount() async throws -> GitHubAccount? {
        do {
            let metadata = try await client.githubAuth()
            guard let login = metadata.accountLogin, !login.isEmpty else { return nil }
            return GitHubAccount(login: login, id: Self.stableID(login), name: nil, email: nil)
        } catch let error as MSWClientError {
            if case .rawCLIError(let code, _) = error {
                switch code {
                case "MSW_HOST_OAUTH_NOT_CONFIGURED":
                    // gh is not authenticated and no device-flow client ID
                    // is configured: the in-app device sheet cannot run.
                    // The app must launch the installed gh web OAuth flow.
                    throw GitHubCatalogError.ghWebLoginRequired
                case "MSW_HOST_DEVICE_FLOW_INTERACTIVE_REQUIRED":
                    // A device-flow client ID is explicitly configured; the
                    // in-app device sheet is the intended path.
                    throw GitHubCatalogError.deviceFlowAvailable
                default:
                    throw GitHubCatalogError.unavailable(error.localizedDescription)
                }
            }
            throw GitHubCatalogError.unavailable(error.localizedDescription)
        }
    }

    func launchGhWebLogin() async throws {
        do {
            try await client.githubWebLogin()
        } catch let error as MSWClientError {
            if case .rawCLIError(let code, let message) = error {
                throw GitHubCatalogError.notConfigured(
                    message ?? "GitHub CLI (gh) sign-in could not be started."
                )
            }
            throw GitHubCatalogError.unavailable(error.localizedDescription)
        }
    }

    func startDeviceFlow() async throws -> MSWDeviceFlowStart {
        do {
            return try await client.githubAuthDevice()
        } catch let error as MSWClientError {
            if case .rawCLIError(let code, let message) = error, code == "MSW_HOST_OAUTH_NOT_CONFIGURED" {
                throw GitHubCatalogError.notConfigured(
                    message ?? "GitHub sign-in is not configured on this Mac."
                )
            }
            throw GitHubCatalogError.unavailable(error.localizedDescription)
        }
    }

    func pollDeviceFlow(deviceId: String) async throws -> MSWDeviceFlowPoll {
        try await client.githubAuthDeviceComplete(deviceId: deviceId)
    }

    /// Stable 31-bit FNV-1a hash used to synthesize stable local-mode
    /// repository/owner identifiers from canonical names. The same catalog
    /// and policy read-back share these ids, so drafts and prefills agree.
    static func stableID(_ value: String) -> Int {
        var hash: UInt32 = 2_166_136_261
        for byte in value.utf8 {
            hash ^= UInt32(byte)
            hash &*= 16_777_619
        }
        return Int(hash & 0x7FFF_FFFF)
    }

    static func canonicalize(_ value: String) -> String {
        var canonical = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if canonical.hasSuffix(".git") {
            canonical.removeLast(4)
        }
        return canonical
    }

    static func isValidCanonical(_ value: String) -> Bool {
        guard value.range(of: #"^[a-z0-9][a-z0-9_.-]*/[a-z0-9][a-z0-9_.-]*$"#, options: .regularExpression) != nil else {
            return false
        }
        // Canonical repo ids never carry a trailing .git (Path C §2).
        return !value.hasSuffix(".git")
    }

    /// Splits a canonical `owner/name` into (owner, name).
    static func splitCanonical(_ value: String) -> (owner: String, name: String)? {
        guard isValidCanonical(value), let slash = value.firstIndex(of: "/") else { return nil }
        return (String(value[..<slash]), String(value[value.index(after: slash)...]))
    }
}

/// UI-test fixture provider: simulates local-mode catalog loads and policy
/// commits so the `--ui-test-github-*` flows never invoke a developer's MSW
/// runtime.
actor GitHubFixtureProvider: GitHubProviding {
    let scenario: String?
    private var loadAttempts = 0
    private var connected: Bool

    init(scenario: String?) {
        self.scenario = scenario
        self.connected = scenario != "disconnected"
    }

    nonisolated var isAvailable: Bool { true }

    func loadCatalog() async throws -> GitHubCatalog {
        loadAttempts += 1
        if scenario == "interaction-states", loadAttempts > 1 {
            try await Task.sleep(for: .seconds(2))
        }
        if scenario == "unavailable" {
            throw GitHubCatalogError.unavailable("GitHub could not be reached. Try again later.")
        }
        if scenario == "cancel-retry" {
            if loadAttempts == 1 {
                throw GitHubCatalogError.unavailable("GitHub could not be reached. Try again later.")
            }
        }
        if scenario == "no-installation" {
            return GitHubCatalog(
                account: Self.fixtureAccount,
                hostCredentialPresent: true,
                installations: [],
                repositoriesByInstallation: [:]
            )
        }
        if !connected {
            return GitHubCatalog(
                account: nil,
                hostCredentialPresent: false,
                installations: [],
                repositoriesByInstallation: [:]
            )
        }
        return GitHubCatalog(
            account: Self.fixtureAccount,
            hostCredentialPresent: true,
            installations: [Self.fixtureInstallation],
            repositoriesByInstallation: [Self.fixtureInstallation.id: Self.fixtureRepositories]
        )
    }

    func currentPolicy() async -> GitHubPolicyFile? { nil }

    func commit(_ policy: [GitHubWorkspacePolicy]) async throws {
        if scenario == "interaction-states" {
            try await Task.sleep(for: .seconds(2))
        }
    }

    func removeAllAccess() async throws {}

    func connectAccount() async throws -> GitHubAccount? {
        if scenario == "disconnected" {
            try await Task.sleep(for: .seconds(3))
        }
        connected = true
        return Self.fixtureAccount
    }

    func launchGhWebLogin() async throws {}

    func startDeviceFlow() async throws -> MSWDeviceFlowStart {
        MSWDeviceFlowStart(
            deviceId: "fixture-device",
            code: "FIXT-CODE",
            verificationUri: "https://github.com/login/device",
            expiresAt: Date().addingTimeInterval(900),
            interval: 5
        )
    }

    func pollDeviceFlow(deviceId: String) async throws -> MSWDeviceFlowPoll {
        MSWDeviceFlowPoll(status: .authorized, interval: nil, accountLogin: "octocat")
    }

    static let fixtureAccount = GitHubAccount(login: "octocat", id: 1, name: nil, email: nil)
    static let fixtureInstallation = GitHubInstallation(
        id: 42,
        account: GitHubInstallationAccount(login: "acme", id: 7, type: "Organization"),
        repositorySelection: nil
    )
    static let fixtureRepositories = [
        GitHubRepository(
            id: 1001,
            fullName: "acme/one",
            name: "one",
            owner: GitHubInstallationAccount(login: "acme", id: 7, type: "Organization"),
            private: true,
            defaultBranch: "main"
        ),
        GitHubRepository(
            id: 1002,
            fullName: "acme/two",
            name: "two",
            owner: GitHubInstallationAccount(login: "acme", id: 7, type: "Organization"),
            private: true,
            defaultBranch: "main"
        )
    ]
}
