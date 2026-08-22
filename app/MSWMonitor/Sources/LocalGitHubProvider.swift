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

    init(client: MSWClient, policyStore: GitHubPolicyStore) {
        self.client = client
        self.policyStore = policyStore
    }

    nonisolated var isAvailable: Bool { true }

    func loadCatalog() async throws -> GitHubCatalog {
        let status = try await client.githubStatus()
        guard status.mode == GitHubAccessMode.local.rawValue else {
            throw GitHubCatalogError.notLocalMode(
                "GitHub is in \(status.mode) mode on this Mac; local repository access is unavailable."
            )
        }
        let hasCredential = status.workspaces.contains { $0.hostCredential == "present" }
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
        await policyStore.current
    }

    /// Applies the desired per-workspace policy through ONE journaled CLI
    /// transaction (`msw app github-policy-apply`) that carries the full
    /// desired policy on stdin, provisions/verifies the transport for every
    /// workspace, and commits atomically (rollback on any unproven step).
    /// Only returns once the CLI confirms provisioned + committed; unedited
    /// workspaces keep their current policy entries.
    func commit(_ policy: [GitHubWorkspacePolicy]) async throws {
        let current = await policyStore.current
        let edited = Dictionary(uniqueKeysWithValues: policy.map { ($0.workspace, $0) })
        var workspaces: [String: GitHubPolicyWorkspace] = [:]
        for workspace in WorkspaceID.all {
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
                    capability: current?.workspaces[workspace]?.capability,
                    repos: repos
                )
            } else if let existing = current?.workspaces[workspace] {
                // Unedited workspace: keep its current entries so a missing
                // key never clears it (the CLI treats absence as "clear").
                workspaces[workspace] = GitHubPolicyWorkspace(
                    capability: existing.capability,
                    repos: existing.repos
                )
            } else {
                workspaces[workspace] = GitHubPolicyWorkspace(capability: nil, repos: [])
            }
        }
        let request = MSWGitHubPolicyApplyRequest(schemaVersion: 1, workspaces: workspaces)
        let result = try await client.githubPolicyApply(request)
        guard result.applied == true, result.provisioned == true, result.committed == true else {
            throw GitHubCatalogError.commitFailed(
                "The CLI did not confirm the policy was provisioned and committed."
            )
        }
    }

    func removeAllAccess() async throws {
        let current = await policyStore.current
        var workspaces: [String: GitHubPolicyWorkspace] = [:]
        for workspace in WorkspaceID.all {
            workspaces[workspace] = GitHubPolicyWorkspace(
                capability: current?.workspaces[workspace]?.capability,
                repos: []
            )
        }
        let request = MSWGitHubPolicyApplyRequest(schemaVersion: 1, workspaces: workspaces)
        let result = try await client.githubPolicyApply(request)
        guard result.applied == true, result.provisioned == true, result.committed == true else {
            throw GitHubCatalogError.commitFailed(
                "The CLI did not confirm repository access was removed."
            )
        }
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
