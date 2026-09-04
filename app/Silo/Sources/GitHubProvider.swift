import Foundation

/// The app-facing GitHub surface. SetupView/SettingsView depend on this
/// behavior, not on transport details.
protocol GitHubProviding: Sendable {
    var isAvailable: Bool { get }
    func loadCatalog() async throws -> GitHubCatalog
    func savePolicy(_ policy: [GitHubWorkspacePolicy]) async throws -> GitHubApplyProgress
    func desiredPolicy() async -> GitHubPolicyFile?
    func clearPolicy() async throws -> GitHubApplyProgress
    func resetAccess() async throws -> GitHubApplyProgress
    /// Runs the CLI-owned host-credential acquisition (gh reuse, fully
    /// non-TTY). Throws `.ghWebLoginRequired` when gh is not authenticated
    /// and no device-flow client ID is configured (the app then launches the
    /// installed gh web OAuth flow and retries), or `.deviceFlowAvailable`
    /// when the CLI reports the OAuth Device Flow is the intended path
    /// (SILO_HOST_DEVICE_FLOW_INTERACTIVE_REQUIRED from `github auth --json`).
    func connectAccount() async throws -> GitHubAccount?
    /// Launches the installed gh CLI's web OAuth flow
    /// (`gh auth login --hostname github.com --git-protocol https --web
    /// --skip-ssh-key`), which opens the default browser and waits for the
    /// user to complete sign-in. The caller retries `connectAccount()` after
    /// it returns. Throws when gh is unavailable or the flow fails.
    func launchGhWebLogin() async throws
    /// One-shot device-flow start; the caller drives polling with
    /// `pollDeviceFlow(deviceId:)` at `interval` sleeps.
    func startDeviceFlow() async throws -> SiloDeviceFlowStart
    func pollDeviceFlow(deviceId: String) async throws -> SiloDeviceFlowPoll
    /// Onboarding's desired/effective cutover. Implementations that do
    /// not support the background contract may use the synchronous default.
    func policySyncProgress() async -> GitHubApplyProgress?
    func waitForPolicySync() async throws
    func retryPolicySync() async throws
    func cancelPolicySync() async
    func setIdentity(name: String, email: String, workspace: String?) async throws -> SiloIdentityResult
    /// Rebuilds every workspace-scoped target from the validated configuration
    /// installed and verified by bootstrap.
    func reloadWorkspaceConfiguration(_ configurations: [SetupWorkspaceConfiguration]) async throws
}

enum GitHubApplyPhase: String, Codable, Sendable, Equatable {
    case saved
    case applying
    case delayed
    case applied
    case failed
    case cancelled
}

struct GitHubApplyFailure: Codable, Sendable, Equatable {
    let code: String
    let message: String
    let recovery: String
    let workspace: String?
    let retryable: Bool

    var presentationMessage: String {
        Self.containsInternalContentionLanguage(message)
            ? "GitHub synchronization could not continue."
            : message
    }

    var presentationRecovery: String {
        guard Self.containsInternalContentionLanguage(recovery) else { return recovery }
        return retryable
            ? "Retry GitHub synchronization."
            : "Review the saved GitHub choices and runtime status."
    }

    static func containsInternalContentionLanguage(_ value: String) -> Bool {
        let normalized = value.lowercased()
        let words = Set(normalized.split(whereSeparator: { !$0.isLetter }).map(String.init))
        return !words.isDisjoint(with: ["lock", "locks", "locked", "locking", "deadlock"]) ||
            normalized.contains("operation conflict") ||
            (normalized.contains("another") && normalized.contains("operation"))
    }
}

enum GitHubPolicyApplyError: Error, LocalizedError, Sendable, Equatable {
    case failed(GitHubApplyFailure)

    var errorDescription: String? {
        guard case .failed(let failure) = self else { return nil }
        return failure.presentationMessage
    }
}

struct GitHubApplyProgress: Sendable, Equatable {
    let generation: Int
    let phase: GitHubApplyPhase
    let workspace: String?
    let failure: GitHubApplyFailure?

    var isTerminalSuccess: Bool { phase == .applied }
    var isInFlight: Bool {
        [.saved, .applying, .delayed].contains(phase)
    }

    var canRetry: Bool {
        (phase == .failed && failure?.retryable == true) || phase == .cancelled
    }

    var canCancel: Bool { phase == .delayed }

    var label: String {
        switch phase {
        case .saved: return "Saved"
        case .applying: return "Applying"
        case .delayed: return "Delayed"
        case .applied: return "Applied"
        case .failed: return "Couldn’t apply"
        case .cancelled: return "Cancelled"
        }
    }

    var summary: String {
        let scope = workspace.map { " for \($0)" } ?? ""
        switch phase {
        case .saved: return "Saved locally. Waiting to apply\(scope)."
        case .applying: return "Applying GitHub access\(scope)…"
        case .delayed: return "Saved locally. Sync is taking longer than usual; Silo will keep trying."
        case .applied: return "GitHub changes are applied."
        case .failed: return failure?.presentationMessage ?? "GitHub access could not be applied."
        case .cancelled: return "GitHub synchronization was cancelled."
        }
    }
}

/// Catalog of the authenticated account's GitHub owners and repositories.
struct GitHubCatalog: Sendable, Equatable {
    var account: GitHubAccount?
    var hostCredentialPresent: Bool
    var owners: [GitHubOwner]
    var repositoriesByOwner: [Int: [GitHubRepository]]
}

enum GitHubCatalogError: Error, LocalizedError, Sendable, Equatable {
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
        case .unavailable(let message): return message
        case .commitFailed(let message): return message
        case .ghWebLoginRequired: return "GitHub sign-in on this Mac is required."
        case .deviceFlowAvailable: return "GitHub Device Flow authorization is required."
        case .notConfigured(let message): return message
        }
    }
}

enum GitHubStrings {
    static let settingsNoCredential = "GitHub account not connected on this Mac"
    static let settingsConnectAccount = "Connect GitHub account on this Mac…"
    static let noReposCopy = "No repositories found."
    static let detailFootnote = "Authenticated GitHub access is enforced by the local proxy on this Mac. Your workspace never receives a GitHub credential. Local editing and commits always work."
}

/// The repo catalog is assembled from the policy file
/// read-back through `silo github status --format json`, which lists every
/// workspace's granted repos; the CLI exposes no GitHub repo enumeration,
/// so the app never adds one. On EVERY successful load, grants
/// whose repos are missing from the discovered catalog are restored
/// into the fresh catalog so a refresh can never drop a granted repo from
/// the picker or from the draft-to-policy mapping. Credential/account state
/// comes from the CLI (`github status`, `github auth --json`) — the app
/// only reads status and never holds the token.
actor GitHubProvider: GitHubProviding {
    private let client: SiloClient
    private let policyURL: URL
    private var applyProgress: GitHubApplyProgress?
    private var currentApplyTask: Task<Void, Never>?
    private var currentApplyGeneration: Int?
    private var mutationTail: Task<Void, Never>?
    private var desiredRequest: SiloGitHubPolicyApplyRequest?
    private var desiredHash: String?
    private var nextGeneration: Int
    private var configuredWorkspaces: [String]
    private var configurationReloadInProgress = false
    private var configurationReloadWaiters: [CheckedContinuation<Void, Never>] = []
    private let contentionBackoff: @Sendable (Int) -> Duration

    init(
        client: SiloClient,
        policyStore: GitHubPolicyStore,
        workspaceConfigurations: [SetupWorkspaceConfiguration] = SetupWorkspaceConfiguration.defaults,
        contentionBackoff: @escaping @Sendable (Int) -> Duration = { attempt in
            let exponent = min(max(attempt - 1, 0), 5)
            let milliseconds = min(15_000, 500 * (1 << exponent))
            return .milliseconds(milliseconds)
        }
    ) {
        self.client = client
        self.policyURL = policyStore.policyURL
        let configuredWorkspaceNames = workspaceConfigurations.map(\.name)
        self.configuredWorkspaces = configuredWorkspaceNames
        self.contentionBackoff = contentionBackoff
        let persisted = GitHubPolicyStore.readIntent(policyURL: policyStore.policyURL)
        let persistedDesired = persisted.map {
            Self.scopedRequest(
                Self.intentRequest($0.desired),
                workspaces: configuredWorkspaceNames
            )
        }
        let persistedHash = persistedDesired.map {
            Self.semanticHash($0, workspaces: configuredWorkspaceNames)
        }
        self.nextGeneration = persisted?.generation ?? 0
        self.desiredRequest = persistedDesired
        self.desiredHash = persistedHash
        if let persisted {
            let failure = persisted.failure.map {
                Self.scopedFailure($0, workspaces: configuredWorkspaceNames)
            }
            let phase: GitHubApplyPhase
            switch persisted.status {
            case .pending: phase = .saved
            case .failed: phase = .failed
            case .completed: phase = .applied
            case .cancelled: phase = .cancelled
            }
            self.applyProgress = GitHubApplyProgress(
                generation: persisted.generation,
                phase: phase,
                workspace: failure?.workspace,
                failure: failure
            )
            // Intent is repository-only and scoped to the current configured
            // workspace set. Rewriting obsolete keys here prevents a pending
            // pre-rename generation from being replayed on the next launch.
            if let persistedDesired, let persistedHash,
               persistedDesired != persisted.desired ||
                    persistedHash != persisted.semanticHash ||
                    failure != persisted.failure {
                try? GitHubPolicyStore.writeIntent(
                    GitHubApplyPersistentState(
                        schemaVersion: persisted.schemaVersion,
                        generation: persisted.generation,
                        semanticHash: persistedHash,
                        status: persisted.status,
                        desired: persistedDesired,
                        updatedAt: Date(),
                        failure: failure
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
        await waitForConfigurationReload()
        configurationReloadInProgress = true
        defer { finishConfigurationReload() }

        await stopReconciliation()
        let names = configurations.map(\.name)
        do {
            try await client.reloadWorkspaceConfiguration(configurations)
        } catch {
            resumeInterruptedReconciliation()
            throw error
        }
        configuredWorkspaces = names
        let persisted = GitHubPolicyStore.readIntent(policyURL: policyURL)
        nextGeneration = max(nextGeneration, persisted?.generation ?? 0)
        desiredRequest = persisted.map { Self.scopedRequest($0.desired, workspaces: names) }
        desiredHash = desiredRequest.map { Self.semanticHash($0, workspaces: names) }
        if let persisted, let desiredRequest, let desiredHash {
            let failure = persisted.failure.map {
                Self.scopedFailure($0, workspaces: names)
            }
            if desiredRequest != persisted.desired ||
                desiredHash != persisted.semanticHash ||
                failure != persisted.failure {
                try GitHubPolicyStore.writeIntent(
                    GitHubApplyPersistentState(
                        schemaVersion: persisted.schemaVersion,
                        generation: persisted.generation,
                        semanticHash: desiredHash,
                        status: persisted.status,
                        desired: desiredRequest,
                        updatedAt: Date(),
                        failure: failure
                    ),
                    policyURL: policyURL
                )
            }
            let phase: GitHubApplyPhase
            switch persisted.status {
            case .pending: phase = .saved
            case .failed: phase = .failed
            case .completed: phase = .applied
            case .cancelled: phase = .cancelled
            }
            applyProgress = GitHubApplyProgress(
                generation: persisted.generation,
                phase: phase,
                workspace: failure?.workspace,
                failure: failure
            )
        } else {
            applyProgress = nil
        }
        resumePendingReconciliationIfNeeded()
    }

    func loadCatalog() async throws -> GitHubCatalog {
        await waitForConfigurationReload()
        let status = try await client.githubStatus()
        let hasCredential = status.hostCredential == "present"
        var account: GitHubAccount?
        if hasCredential, let metadata = try? await client.githubAuthMetadata(),
           let login = metadata.accountLogin, !login.isEmpty {
            account = GitHubAccount(login: login, id: Self.stableID(login), name: nil, email: nil)
        }
        // Discovery requires the host credential; without one the catalog is
        // empty and the caller surfaces the no-credential state.
        let discovered: [SiloGitHubDiscoveredRepo]
        if hasCredential {
            do {
                discovered = try await client.githubRepos()
            } catch {
                throw GitHubCatalogError.unavailable(error.localizedDescription)
            }
        } else {
            discovered = []
        }
        var owners: [GitHubOwner] = []
        var repositoriesByOwner: [Int: [GitHubRepository]] = [:]
        var seenOwners: [Int: GitHubOwnerAccount] = [:]
        for repo in discovered.sorted(by: { $0.canonical < $1.canonical }) {
            let ownerID = Self.stableID(repo.owner)
            let ownerAccount = seenOwners[ownerID]
                ?? GitHubOwnerAccount(login: repo.owner, id: ownerID, type: nil)
            seenOwners[ownerID] = ownerAccount
            if repositoriesByOwner[ownerID] == nil {
                owners.append(GitHubOwner(
                    id: ownerID,
                    account: ownerAccount
                ))
            }
            let repository = GitHubRepository(
                id: Self.stableID(repo.canonical),
                fullName: repo.canonical,
                name: repo.name,
                owner: ownerAccount,
                private: repo.private,
                defaultBranch: nil,
                canPush: repo.permissions.push,
                inPolicy: repo.inPolicy
            )
            if !(repositoriesByOwner[ownerID]?.contains(where: { $0.id == repository.id }) ?? false) {
                repositoriesByOwner[ownerID, default: []].append(repository)
            }
        }
        // Every successful load re-merges policy-only grants into the fresh
        // catalog BEFORE any draft-to-policy mapping, so a refresh can never
        // make an existing grant disappear or be silently dropped on save.
        let merged = Self.mergingPolicyOnlyRepositories(
            owners: owners,
            repositoriesByOwner: repositoriesByOwner,
            policy: await desiredPolicy(),
            configuredWorkspaces: Set(configuredWorkspaces)
        )
        return GitHubCatalog(
            account: account,
            hostCredentialPresent: hasCredential,
            owners: merged.owners,
            repositoriesByOwner: merged.repositoriesByOwner
        )
    }

    /// Pure merge used by `loadCatalog` on EVERY successful catalog load,
    /// before any draft-to-policy mapping: policy-only credential grants
    /// (canonical repos absent from the discovered catalog, e.g. an owner
    /// GitHub no longer lists or a missing host credential) are re-added as
    /// selectable entries so a refresh keeps them visible and the
    /// draft-to-policy mapping still resolves them. Deselected entries are
    /// never repopulated — drafts are untouched; the entries merely stay
    /// available in the catalog. Entries from workspaces outside
    /// `configuredWorkspaces` are ignored.
    static func mergingPolicyOnlyRepositories(
        owners: [GitHubOwner],
        repositoriesByOwner: [Int: [GitHubRepository]],
        policy: GitHubPolicyFile?,
        configuredWorkspaces: Set<String>
    ) -> (owners: [GitHubOwner], repositoriesByOwner: [Int: [GitHubRepository]]) {
        guard let policy else { return (owners, repositoriesByOwner) }
        var updatedOwners = owners
        var updatedRepositories = repositoriesByOwner
        for workspaceName in policy.workspaces.keys where configuredWorkspaces.contains(workspaceName) {
            for entry in policy.workspaces[workspaceName]?.repos ?? [] {
                let canonical = entry.canonical
                guard let (owner, name) = Self.splitCanonical(canonical) else { continue }
                let ownerID = Self.stableID(owner)
                let repositoryID = Self.stableID(canonical)
                guard !(updatedRepositories[ownerID]?.contains(where: { $0.id == repositoryID }) ?? false) else {
                    continue
                }
                if !updatedOwners.contains(where: { $0.id == ownerID }) {
                    updatedOwners.append(GitHubOwner(
                        id: ownerID,
                        account: GitHubOwnerAccount(login: owner, id: ownerID, type: nil)
                    ))
                }
                updatedRepositories[ownerID, default: []].append(GitHubRepository(
                    id: repositoryID,
                    fullName: canonical,
                    name: name,
                    owner: GitHubOwnerAccount(login: owner, id: ownerID, type: nil),
                    private: true,
                    defaultBranch: nil
                ))
            }
        }
        return (updatedOwners, updatedRepositories)
    }

    /// Returns the newest durable desired state for responsive local-first UI.
    /// Capabilities still come only from the effective CLI-owned policy file.
    func desiredPolicy() async -> GitHubPolicyFile? {
        await waitForConfigurationReload()
        let effective = GitHubPolicyStore.read(policyURL: policyURL)
        guard let desiredRequest else {
            guard let effective else { return nil }
            return Self.scopedPolicy(effective, workspaces: configuredWorkspaces)
        }
        let intent = GitHubPolicyStore.readIntent(policyURL: policyURL)
        return GitHubPolicyFile(
            schemaVersion: desiredRequest.schemaVersion,
            workspaces: Dictionary(uniqueKeysWithValues: configuredWorkspaces.map {
                ($0, GitHubPolicyWorkspace(
                    capability: effective?.workspaces[$0]?.capability,
                    repos: desiredRequest.workspaces[$0]?.repos ?? []
                ))
            }),
            updatedAt: intent?.updatedAt ?? effective?.updatedAt
        )
    }

    /// Validates and durably records intent, then returns immediately. The
    /// generation's CLI transaction runs in a child task; newer generations
    /// cancel it and are serialized behind cleanup by `mutationTail`.
    func savePolicy(_ policy: [GitHubWorkspacePolicy]) async throws -> GitHubApplyProgress {
        await waitForConfigurationReload()
        let request = try makeRequest(policy, preserving: desiredRequest)
        let hash = Self.semanticHash(request, workspaces: configuredWorkspaces)
        if hash == desiredHash, let applyProgress {
            if applyProgress.isInFlight { return applyProgress }
            if applyProgress.phase == .applied, matchesEffectivePolicy(request) {
                return applyProgress
            }
        }

        nextGeneration &+= 1
        let generation = nextGeneration
        let supersedesInFlight = applyProgress?.isInFlight == true && currentApplyTask != nil
        let firstChanged = firstChangedNonEmptyWorkspace(in: request)
        let progress = GitHubApplyProgress(
            generation: generation,
            phase: .saved,
            workspace: firstChanged,
            failure: nil
        )
        try persist(request: request, hash: hash, progress: progress, status: .pending)
        currentApplyTask?.cancel()
        desiredRequest = request
        desiredHash = hash
        applyProgress = progress

        // A semantic match with the effective policy is a true no-op: it
        // supersedes stale work without restarting transport.
        if !supersedesInFlight, matchesEffectivePolicy(request) {
            let completed = GitHubApplyProgress(
                generation: generation,
                phase: .applied,
                workspace: nil,
                failure: nil
            )
            applyProgress = completed
            // The effective policy already matches. If only the non-secret
            // completion marker fails, keep Applied in memory; the durable
            // pending intent safely re-verifies on the next launch.
            try? persist(request: request, hash: hash, progress: completed, status: .completed)
            return completed
        }

        startReconciliation(request: request, hash: hash, generation: generation, workspace: firstChanged)
        return progress
    }

    func policySyncProgress() async -> GitHubApplyProgress? {
        await waitForConfigurationReload()
        if applyProgress?.phase == .applied,
           let desiredRequest, let desiredHash {
            if !matchesEffectivePolicy(desiredRequest) {
                nextGeneration &+= 1
                let generation = nextGeneration
                let workspace = firstChangedNonEmptyWorkspace(in: desiredRequest)
                let pending = GitHubApplyProgress(
                    generation: generation,
                    phase: .saved,
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
        resumePendingReconciliationIfNeeded()
        return applyProgress
    }

    func waitForPolicySync() async throws {
        while true {
            _ = await policySyncProgress()
            guard let task = currentApplyTask, let generation = currentApplyGeneration else { break }
            await task.value
            // A Back/edit may supersede the generation while this caller is
            // waiting. Gate Review/Done on the newest task, never the task
            // that happened to be current when the wait began.
            if currentApplyGeneration != generation { continue }
            if task.isCancelled {
                await Task.yield()
                continue
            }
            break
        }
        guard let progress = applyProgress else { return }
        if progress.phase == .failed {
            let failure = progress.failure ?? GitHubApplyFailure(
                code: "SILO_GITHUB_RECONCILIATION_FAILED",
                message: "GitHub reconciliation failed.",
                recovery: "Check the workspace runtime, then retry GitHub reconciliation.",
                workspace: progress.workspace,
                retryable: true
            )
            throw GitHubPolicyApplyError.failed(failure)
        }
        if progress.phase == .cancelled { throw CancellationError() }
    }

    func retryPolicySync() async throws {
        await waitForConfigurationReload()
        guard let desiredRequest, let desiredHash else {
            throw GitHubCatalogError.commitFailed("There is no saved GitHub policy to retry.")
        }
        nextGeneration &+= 1
        let generation = nextGeneration
        let workspace = firstChangedNonEmptyWorkspace(in: desiredRequest)
        let progress = GitHubApplyProgress(generation: generation, phase: .saved, workspace: workspace, failure: nil)
        try persist(request: desiredRequest, hash: desiredHash, progress: progress, status: .pending)
        applyProgress = progress
        currentApplyTask?.cancel()
        startReconciliation(request: desiredRequest, hash: desiredHash, generation: generation, workspace: workspace)
    }

    func cancelPolicySync() async {
        await waitForConfigurationReload()
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

    func setIdentity(name: String, email: String, workspace: String?) async throws -> SiloIdentityResult {
        await waitForConfigurationReload()
        let expected = workspace.map { [$0] } ?? configuredWorkspaces
        guard !expected.isEmpty,
              expected.allSatisfy({ configuredWorkspaces.contains($0) }) else {
            throw SiloClientError.invalidArguments
        }
        let result = try await performMutation { [client] in
            let response = try await client.setIdentity(name: name, email: email, workspace: workspace)
            guard let result = response.result else {
                throw SiloClientError.missingResult(command: "identity")
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
    /// transaction (`silo app github-policy-apply`) that carries the full
    /// desired policy on stdin, provisions/verifies transport only for changed
    /// non-empty workspaces, and commits atomically (rollback on an unproven
    /// step).
    /// Only returns once the CLI confirms provisioned + committed; unedited
    /// workspaces keep their current policy entries.
    private func makeRequest(
        _ policy: [GitHubWorkspacePolicy],
        preserving pendingRequest: SiloGitHubPolicyApplyRequest?
    ) throws -> SiloGitHubPolicyApplyRequest {
        let current = GitHubPolicyStore.read(policyURL: policyURL)
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
        return SiloGitHubPolicyApplyRequest(schemaVersion: 1, workspaces: workspaces)
    }

    private static func apply(
        _ request: SiloGitHubPolicyApplyRequest,
        with client: SiloClient,
        contentionBackoff: @escaping @Sendable (Int) -> Duration,
        onContention: @escaping @Sendable (Int) async -> Void
    ) async throws {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                let result = try await client.githubPolicyApply(request)
                guard result.applied == true,
                      result.provisioned == true,
                      result.committed == true else {
                    throw GitHubCatalogError.commitFailed(
                        "The CLI did not confirm the policy was provisioned and committed."
                    )
                }
                return
            } catch SiloClientError.protocolFailure(let error)
                where error.code == "SILO_OPERATION_CONFLICT" && error.retryable {
                attempt += 1
                await onContention(attempt)
                try await Task.sleep(for: contentionBackoff(attempt))
            }
        }
    }

    private func startReconciliation(
        request: SiloGitHubPolicyApplyRequest,
        hash: String,
        generation: Int,
        workspace: String?
    ) {
        let applying = GitHubApplyProgress(
            generation: generation,
            phase: .applying,
            workspace: workspace,
            failure: nil
        )
        if applyProgress?.generation == generation { applyProgress = applying }
        let coordinator = self
        let operation = makeMutationTask { [client, contentionBackoff, coordinator] in
            try await Self.apply(
                request,
                with: client,
                contentionBackoff: contentionBackoff
            ) { attempt in
                guard attempt >= 3 else { return }
                await coordinator.markContentionDelayed(generation: generation, workspace: workspace)
            }
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
        request: SiloGitHubPolicyApplyRequest,
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
            let completed = GitHubApplyProgress(
                generation: generation,
                phase: .applied,
                workspace: nil,
                failure: nil
            )
            applyProgress = completed
            // CLI confirmation is authoritative for effective state. If the
            // non-secret completion marker cannot be updated, keep the
            // truthful Applied state in memory; the existing pending marker
            // safely replays and verifies the same desired intent on the next launch.
            do {
                try persist(request: request, hash: hash, progress: completed, status: .completed)
            } catch {
                // The current session already has CLI confirmation. A
                // surviving pending marker will be replayed on the next launch;
                // if no marker survives, the effective CLI-owned policy is
                // still the source of truth.
            }
            if currentApplyGeneration == generation {
                currentApplyTask = nil
                currentApplyGeneration = nil
            }
        } catch is CancellationError {
            // A newer generation owns the visible state. Setup-close
            // cancellation is finalized by `cancelPolicySync` after
            // the process group and CLI locks have been released.
        } catch let error as SiloClientError where error == .cancelled {
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

    private func markContentionDelayed(generation: Int, workspace: String?) {
        guard applyProgress?.generation == generation,
              applyProgress?.isInFlight == true else { return }
        applyProgress = GitHubApplyProgress(
            generation: generation,
            phase: .delayed,
            workspace: workspace,
            failure: nil
        )
    }

    private func stopReconciliation() async {
        guard let task = currentApplyTask, let generation = currentApplyGeneration else { return }
        task.cancel()
        await task.value
        guard currentApplyGeneration == generation else { return }
        currentApplyTask = nil
        currentApplyGeneration = nil
    }

    private func waitForConfigurationReload() async {
        while configurationReloadInProgress {
            await withCheckedContinuation { continuation in
                configurationReloadWaiters.append(continuation)
            }
        }
    }

    private func finishConfigurationReload() {
        configurationReloadInProgress = false
        let waiters = configurationReloadWaiters
        configurationReloadWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func resumeInterruptedReconciliation() {
        guard currentApplyTask == nil, let progress = applyProgress, progress.isInFlight else { return }
        applyProgress = GitHubApplyProgress(
            generation: progress.generation,
            phase: .saved,
            workspace: progress.workspace,
            failure: nil
        )
        resumePendingReconciliationIfNeeded()
    }

    private func resumePendingReconciliationIfNeeded() {
        guard currentApplyTask == nil, let applyProgress,
              applyProgress.phase == .saved, let desiredRequest, let desiredHash else { return }
        startReconciliation(
            request: desiredRequest,
            hash: desiredHash,
            generation: applyProgress.generation,
            workspace: applyProgress.workspace
        )
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

    private func matchesEffectivePolicy(_ request: SiloGitHubPolicyApplyRequest) -> Bool {
        guard let current = GitHubPolicyStore.read(policyURL: policyURL) else {
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
        in request: SiloGitHubPolicyApplyRequest
    ) -> String? {
        let current = GitHubPolicyStore.read(policyURL: policyURL)
        return configuredWorkspaces.first { workspace in
            let desired = request.workspaces[workspace]?.repos ?? []
            let effective = current?.workspaces[workspace]?.repos ?? []
            return !desired.isEmpty && desired != effective
        }
    }

    private func persist(
        request: SiloGitHubPolicyApplyRequest,
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
        _ request: SiloGitHubPolicyApplyRequest,
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
        _ request: SiloGitHubPolicyApplyRequest
    ) -> SiloGitHubPolicyApplyRequest {
        SiloGitHubPolicyApplyRequest(
            schemaVersion: request.schemaVersion,
            workspaces: request.workspaces.mapValues {
                GitHubPolicyWorkspace(capability: nil, repos: $0.repos)
            }
        )
    }

    private static func scopedRequest(
        _ request: SiloGitHubPolicyApplyRequest,
        workspaces: [String]
    ) -> SiloGitHubPolicyApplyRequest {
        SiloGitHubPolicyApplyRequest(
            schemaVersion: request.schemaVersion,
            workspaces: Dictionary(uniqueKeysWithValues: workspaces.map {
                ($0, GitHubPolicyWorkspace(
                    capability: nil,
                    repos: request.workspaces[$0]?.repos ?? []
                ))
            })
        )
    }

    private static func scopedPolicy(
        _ policy: GitHubPolicyFile,
        workspaces: [String]
    ) -> GitHubPolicyFile {
        GitHubPolicyFile(
            schemaVersion: policy.schemaVersion,
            workspaces: Dictionary(uniqueKeysWithValues: workspaces.map {
                ($0, policy.workspaces[$0] ?? GitHubPolicyWorkspace(capability: nil, repos: []))
            }),
            updatedAt: policy.updatedAt
        )
    }

    private static func scopedFailure(
        _ failure: GitHubApplyFailure,
        workspaces: [String]
    ) -> GitHubApplyFailure {
        GitHubApplyFailure(
            code: failure.code,
            message: failure.message,
            recovery: failure.recovery,
            workspace: failure.workspace.flatMap { workspaces.contains($0) ? $0 : nil },
            retryable: failure.retryable
        )
    }

    private static func failure(for error: Error, workspace: String?) -> GitHubApplyFailure {
        if let clientError = error as? SiloClientError,
           case .protocolFailure(let protocolError) = clientError {
            let containsInternalContentionLanguage = [
                protocolError.message,
                protocolError.recovery ?? ""
            ].contains(where: GitHubApplyFailure.containsInternalContentionLanguage)
            return GitHubApplyFailure(
                code: protocolError.code,
                message: containsInternalContentionLanguage
                    ? "GitHub synchronization could not continue."
                    : protocolError.message,
                recovery: containsInternalContentionLanguage
                    ? "Retry GitHub synchronization."
                    : protocolError.recovery ?? "Retry GitHub synchronization.",
                workspace: protocolError.workspace ?? workspace,
                retryable: protocolError.retryable
            )
        }
        let message = error.localizedDescription
        return GitHubApplyFailure(
            code: "SILO_GITHUB_RECONCILIATION_FAILED",
            message: GitHubApplyFailure.containsInternalContentionLanguage(message)
                ? "GitHub synchronization could not continue."
                : message,
            recovery: "Check the workspace runtime, then retry GitHub synchronization.",
            workspace: workspace,
            retryable: true
        )
    }

    func clearPolicy() async throws -> GitHubApplyProgress {
        let cleared = configuredWorkspaces.map {
            GitHubWorkspacePolicy(workspace: $0, repositories: [])
        }
        return try await savePolicy(cleared)
    }

    func resetAccess() async throws -> GitHubApplyProgress {
        let saved = try await clearPolicy()
        try await waitForPolicySync()
        let completed = await policySyncProgress() ?? saved
        guard completed.phase == .applied else {
            throw GitHubCatalogError.commitFailed(
                "GitHub policy cleanup did not complete before account reset."
            )
        }
        try await client.disconnectGitHub()
        return completed
    }

    func connectAccount() async throws -> GitHubAccount? {
        do {
            let metadata = try await client.githubAuth()
            guard let login = metadata.accountLogin, !login.isEmpty else { return nil }
            return GitHubAccount(login: login, id: Self.stableID(login), name: nil, email: nil)
        } catch let error as SiloClientError {
            if case .rawCLIError(let code, _) = error {
                switch code {
                case "SILO_HOST_OAUTH_NOT_CONFIGURED":
                    // gh is not authenticated and no device-flow client ID
                    // is configured: the in-app device sheet cannot run.
                    // The app must launch the installed gh web OAuth flow.
                    throw GitHubCatalogError.ghWebLoginRequired
                case "SILO_HOST_DEVICE_FLOW_INTERACTIVE_REQUIRED":
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
        } catch let error as SiloClientError {
            if case .rawCLIError(_, let message) = error {
                throw GitHubCatalogError.notConfigured(
                    message ?? "GitHub CLI (gh) sign-in could not be started."
                )
            }
            throw GitHubCatalogError.unavailable(error.localizedDescription)
        }
    }

    func startDeviceFlow() async throws -> SiloDeviceFlowStart {
        do {
            return try await client.githubAuthDevice()
        } catch let error as SiloClientError {
            if case .rawCLIError(let code, let message) = error, code == "SILO_HOST_OAUTH_NOT_CONFIGURED" {
                throw GitHubCatalogError.notConfigured(
                    message ?? "GitHub sign-in is not configured on this Mac."
                )
            }
            throw GitHubCatalogError.unavailable(error.localizedDescription)
        }
    }

    func pollDeviceFlow(deviceId: String) async throws -> SiloDeviceFlowPoll {
        try await client.githubAuthDeviceComplete(deviceId: deviceId)
    }

    /// Stable 31-bit FNV-1a hash used to derive stable repository and owner
    /// identifiers from canonical names. The same catalog
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
        // Canonical repository IDs never carry a trailing .git.
        return !value.hasSuffix(".git")
    }

    /// Splits a canonical `owner/name` into (owner, name).
    static func splitCanonical(_ value: String) -> (owner: String, name: String)? {
        guard isValidCanonical(value), let slash = value.firstIndex(of: "/") else { return nil }
        return (String(value[..<slash]), String(value[value.index(after: slash)...]))
    }
}

/// UI-test fixture provider: simulates catalog loads and policy
/// commits so the `--ui-test-github-*` flows never invoke a developer's Silo
/// runtime.
actor GitHubFixtureProvider: GitHubProviding {
    let scenario: String?
    private var loadAttempts = 0
    private var connected: Bool
    private var savedPolicy: GitHubPolicyFile?
    private var syncProgress: GitHubApplyProgress?
    private var syncGeneration = 0
    private var configuredWorkspaces = SetupWorkspaceConfiguration.defaults.map(\.name)

    init(scenario: String?) {
        self.scenario = scenario
        self.connected = scenario != "disconnected"
    }

    nonisolated var isAvailable: Bool { true }

    func catalogLoadAttempts() -> Int { loadAttempts }

    func loadCatalog() async throws -> GitHubCatalog {
        loadAttempts += 1
        if scenario == "sync-completes-during-load",
           let progress = syncProgress, progress.isInFlight {
            try await Task.sleep(for: .milliseconds(50))
            syncProgress = GitHubApplyProgress(
                generation: progress.generation,
                phase: .applied,
                workspace: nil,
                failure: nil
            )
        }
        if scenario == "slow-first-load", loadAttempts == 1 {
            try await Task.sleep(for: .milliseconds(250))
        }
        if scenario == "setup-loading-skeleton", loadAttempts == 1 {
            try await Task.sleep(for: .seconds(15))
        }
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
        if scenario == "no-owner" {
            return GitHubCatalog(
                account: Self.fixtureAccount,
                hostCredentialPresent: true,
                owners: [],
                repositoriesByOwner: [:]
            )
        }
        if !connected {
            return GitHubCatalog(
                account: nil,
                hostCredentialPresent: false,
                owners: [],
                repositoriesByOwner: [:]
            )
        }
        return GitHubCatalog(
            account: Self.fixtureAccount,
            hostCredentialPresent: true,
            owners: [Self.fixtureOwner],
            repositoriesByOwner: [Self.fixtureOwner.id: Self.fixtureRepositories]
        )
    }

    func desiredPolicy() async -> GitHubPolicyFile? { savedPolicy }

    func savePolicy(_ policy: [GitHubWorkspacePolicy]) async throws -> GitHubApplyProgress {
        syncGeneration += 1
        var desired = Dictionary(uniqueKeysWithValues: configuredWorkspaces.map { workspace in
            (workspace, savedPolicy?.workspaces[workspace] ?? GitHubPolicyWorkspace(
                capability: nil,
                repos: []
            ))
        })
        for item in policy where desired[item.workspace] != nil {
            desired[item.workspace] = GitHubPolicyWorkspace(
                capability: nil,
                repos: item.repositories.map {
                    GitHubPolicyRepository(
                        canonical: GitHubProvider.canonicalize($0.fullName),
                        mode: $0.mode
                    )
                }
            )
        }
        savedPolicy = GitHubPolicyFile(
            schemaVersion: 1,
            workspaces: desired,
            updatedAt: Date()
        )
        let phase: GitHubApplyPhase
        switch scenario {
        case "sync-delayed": phase = .delayed
        case "sync-completes-during-load": phase = .applying
        default: phase = .applied
        }
        let progress = GitHubApplyProgress(
            generation: syncGeneration,
            phase: phase,
            workspace: phase == .delayed ? policy.first?.workspace : nil,
            failure: nil
        )
        syncProgress = progress
        return progress
    }

    func clearPolicy() async throws -> GitHubApplyProgress {
        try await savePolicy(configuredWorkspaces.map {
            GitHubWorkspacePolicy(workspace: $0, repositories: [])
        })
    }

    func resetAccess() async throws -> GitHubApplyProgress {
        connected = false
        return try await clearPolicy()
    }

    func policySyncProgress() async -> GitHubApplyProgress? { syncProgress }

    func waitForPolicySync() async throws {
        if syncProgress?.phase == .cancelled { throw CancellationError() }
    }

    func retryPolicySync() async throws {
        guard let progress = syncProgress else { return }
        syncProgress = GitHubApplyProgress(
            generation: progress.generation,
            phase: .applied,
            workspace: nil,
            failure: nil
        )
    }

    func cancelPolicySync() async {
        guard let progress = syncProgress, progress.isInFlight else { return }
        syncProgress = GitHubApplyProgress(
            generation: progress.generation,
            phase: .cancelled,
            workspace: progress.workspace,
            failure: nil
        )
    }

    func connectAccount() async throws -> GitHubAccount? {
        if scenario == "disconnected" {
            try await Task.sleep(for: .seconds(3))
        }
        connected = true
        return Self.fixtureAccount
    }

    func launchGhWebLogin() async throws {}

    func startDeviceFlow() async throws -> SiloDeviceFlowStart {
        SiloDeviceFlowStart(
            deviceId: "fixture-device",
            code: "FIXT-CODE",
            verificationUri: "https://github.com/login/device",
            expiresAt: Date().addingTimeInterval(900),
            interval: 5
        )
    }

    func pollDeviceFlow(deviceId: String) async throws -> SiloDeviceFlowPoll {
        SiloDeviceFlowPoll(status: .authorized, interval: nil, accountLogin: "octocat")
    }

    func setIdentity(name: String, email: String, workspace: String?) async throws -> SiloIdentityResult {
        SiloIdentityResult(
            target: workspace ?? "all",
            name: name,
            email: email,
            workspaces: workspace.map { [$0] } ?? SetupWorkspaceConfiguration.defaults.map(\.name)
        )
    }

    func reloadWorkspaceConfiguration(_ configurations: [SetupWorkspaceConfiguration]) async throws {
        configuredWorkspaces = configurations.map(\.name)
        guard let savedPolicy else { return }
        self.savedPolicy = GitHubPolicyFile(
            schemaVersion: savedPolicy.schemaVersion,
            workspaces: Dictionary(uniqueKeysWithValues: configuredWorkspaces.map {
                ($0, savedPolicy.workspaces[$0] ?? GitHubPolicyWorkspace(capability: nil, repos: []))
            }),
            updatedAt: savedPolicy.updatedAt
        )
    }

    static let fixtureAccount = GitHubAccount(login: "octocat", id: 1, name: nil, email: nil)
    static let fixtureOwner = GitHubOwner(
        id: 7,
        account: GitHubOwnerAccount(login: "acme", id: 7, type: "Organization")
    )
    static let fixtureRepositories = [
        GitHubRepository(
            id: 1001,
            fullName: "acme/one",
            name: "one",
            owner: GitHubOwnerAccount(login: "acme", id: 7, type: "Organization"),
            private: true,
            defaultBranch: "main"
        ),
        GitHubRepository(
            id: 1002,
            fullName: "acme/two",
            name: "two",
            owner: GitHubOwnerAccount(login: "acme", id: 7, type: "Organization"),
            private: true,
            defaultBranch: "main"
        )
    ]
}
