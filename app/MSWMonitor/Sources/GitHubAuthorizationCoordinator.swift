import Foundation


enum GitHubRepositoryAccessMode: String, Codable, Sendable, CaseIterable, Equatable {
    case readOnly = "read-only"
    case readWrite = "read-write"

    /// JSON schema values stay read-only|read-write; these concise labels mirror
    /// the single push toggle without reintroducing access-mode terminology.
    var label: String {
        switch self {
        case .readOnly: "Pushes off"
        case .readWrite: "Pushes on"
        }
    }
}

/// Canonical non-secret repository policy. Repository identity is never
/// reconstructed from a display name: every selection carries the stable
/// GitHub repository and installation/owner identities used to mint grants.
struct GitHubRepositoryPolicy: Codable, Sendable, Equatable, Identifiable {
    let workspace: String
    let repositoryID: Int
    let fullName: String
    let installationID: Int
    let ownerID: Int
    let ownerLogin: String
    let ownerType: String?
    let mode: GitHubRepositoryAccessMode

    var id: String { "\(workspace).\(installationID).\(repositoryID)" }

    init(
        workspace: String,
        repositoryID: Int,
        fullName: String,
        installationID: Int,
        ownerID: Int,
        ownerLogin: String,
        ownerType: String?,
        mode: GitHubRepositoryAccessMode = .readOnly
    ) {
        self.workspace = workspace
        self.repositoryID = repositoryID
        self.fullName = fullName
        self.installationID = installationID
        self.ownerID = ownerID
        self.ownerLogin = ownerLogin
        self.ownerType = ownerType
        self.mode = mode
    }
}
/// Complete desired state for one workspace. An empty repository list is
/// meaningful: it removes that workspace's existing GitHub access.
struct GitHubWorkspacePolicy: Codable, Sendable, Equatable, Identifiable {
    let workspace: String
    let repositories: [GitHubRepositoryPolicy]

    var id: String { workspace }

    init(workspace: String, repositories: [GitHubRepositoryPolicy]) {
        self.workspace = workspace
        self.repositories = repositories
    }
}


private struct GitHubGrantPartition: Sendable, Equatable {
    let workspace: String
    let installationID: Int
    let ownerID: Int
    let ownerLogin: String
    let ownerType: String?
    let repositories: [GitHubRepositoryPolicy]

    var readRepositories: [GitHubRepositoryPolicy] { repositories }
    var writeRepositories: [GitHubRepositoryPolicy] { repositories.filter { $0.mode == .readWrite } }

}

struct GitHubAuthorizationDiscovery: Sendable, Equatable {
    let sessionID: UUID
    let account: GitHubAccount
    let installations: [GitHubInstallation]
}

struct GitHubWorkspaceVerificationResult: Codable, Sendable, Equatable, Identifiable {
    let workspace: String
    let installationID: Int
    let role: CredentialRole
    let accessMode: String
    let verificationRepository: String
    let verified: Bool
    let lifecycleRestored: Bool
    let safetyResult: String
    let checkedAt: Date

    var id: String { "\(workspace).\(installationID).\(role.rawValue)" }
}

struct GitHubAuthorizationCommitResult: Sendable, Equatable {
    let metadata: [WorkspaceCredentialMetadata]
    let verifications: [GitHubWorkspaceVerificationResult]
}

enum GitHubFeatureAvailability {
    static let unavailableNotice = "GitHub connection couldn’t start."

    static func isAvailable(configuration: MSWConnectConfiguration) -> Bool {
        configuration.isConfigured && configuration.hasTrustedScopeAttestation
    }
}

enum GitHubWorkspaceAccessAction: Equatable {
    case edit
    case retry
    case reconnect
}

struct GitHubWorkspaceAccessPresentation: Equatable {
    let workspace: String
    let status: String
    let reason: String
    let action: GitHubWorkspaceAccessAction

    static func make(
        workspace: String,
        entries: [WorkspaceCredentialMetadata]
    ) -> GitHubWorkspaceAccessPresentation {
        let needsReconnect = entries.first { entry in
            entry.quarantined || ![.ready, .serviceUnavailable, .expired].contains(entry.recoveryState)
        }
        if let entry = needsReconnect {
            return GitHubWorkspaceAccessPresentation(
                workspace: workspace,
                status: "Needs reconnecting",
                reason: reconnectReason(workspace: workspace, entry: entry),
                action: .reconnect
            )
        }
        if entries.contains(where: { $0.recoveryState == .serviceUnavailable }) {
            return GitHubWorkspaceAccessPresentation(
                workspace: workspace,
                status: "Service unavailable",
                reason: "MSW Connect could not renew \(workspace)'s verified grant. Existing access remains blocked; retry does not open a browser.",
                action: .retry
            )
        }
        if entries.contains(where: { $0.recoveryState == .expired }) {
            return GitHubWorkspaceAccessPresentation(
                workspace: workspace,
                status: "Renewing",
                reason: "The short-lived token for \(workspace) expired normally and will be renewed without reconnecting.",
                action: .retry
            )
        }
        return GitHubWorkspaceAccessPresentation(
            workspace: workspace,
            status: entries.contains(where: \.needsRestart) ? "Ready · restart required" : "Ready",
            reason: entries.contains(where: \.needsRestart)
                ? "The verified scope is healthy; restart \(workspace) to finish applying it."
                : "The verified repository scope for \(workspace) is healthy.",
            action: .edit
        )
    }

    private static func reconnectReason(
        workspace: String,
        entry: WorkspaceCredentialMetadata
    ) -> String {
        let quarantineSuffix = entry.quarantined ? " It remains quarantined until a new grant is verified." : ""
        switch entry.recoveryState {
        case .needsAuthorization:
            return "The verified GitHub grant for \(workspace) is missing.\(quarantineSuffix)"
        case .migrationRequired:
            return "The legacy GitHub grant for \(workspace) cannot be verified as repository-scoped.\(quarantineSuffix)"
        case .revoked:
            return "GitHub revoked the verified grant for \(workspace).\(quarantineSuffix)"
        case .installationRemoved:
            return "The GitHub App installation for \(workspace) is missing.\(quarantineSuffix)"
        case .scopeMismatch:
            return "The renewed GitHub grant for \(workspace) no longer matches its verified repository scope.\(quarantineSuffix)"
        case .quarantined:
            return "\(workspace)'s prior grant cannot be used because cleanup or scope verification was not proven; it remains quarantined."
        case .ready, .expired, .serviceUnavailable:
            return "The verified GitHub grant for \(workspace) cannot be resolved safely.\(quarantineSuffix)"
        }
    }
}

enum GitHubAuthorizationError: Error, LocalizedError, Sendable, Equatable {
    case invalidSelection
    case invalidAppConfiguration
    case guestAuthorizationRequired
    case authorizationSessionExpired
    case ownerNotInstalled
    case repositoryNotAllowed
    case accountLookupFailed
    case credentialCommitFailed
    case serviceUnavailable
    case scopeMismatch
    case revocationFailed
    case authorizationCancelled
    case authorizationDenied(String?)
    case reconnectRequired(workspace: String, reason: String)
    case authorizationFailed
    case verificationUnavailable(String)
    case verificationFailed(String)
    case lifecycleRestoreFailed(String)
    case multipleInstallationsUnsupported(String)

    var errorDescription: String? {
        switch self {
        case .invalidSelection:
            return "Your repository choices need review."
        case .invalidAppConfiguration:
            return GitHubFeatureAvailability.unavailableNotice
        case .guestAuthorizationRequired: return "Assign the repository before allowing pushes from the VM."
        case .authorizationSessionExpired: return "The browser authorization expired. Choose Connect or Reconnect again."
        case .ownerNotInstalled: return "The selected repositories are not available yet. Refresh repository access, then reconnect."
        case .repositoryNotAllowed: return "One or more selected repositories are no longer available. Refresh repository access, then reconnect."
        case .accountLookupFailed: return "We could not confirm your GitHub account. Try again."
        case .credentialCommitFailed: return "We could not apply repository access. Existing access stayed unchanged."
        case .serviceUnavailable: return "GitHub could not be reached. Existing workspace access stayed unchanged."
        case .scopeMismatch: return "GitHub returned access that did not match your choices. Existing access stayed unchanged."
        case .revocationFailed: return "We could not finish updating GitHub access. Existing access needs reconnecting."
        case .authorizationCancelled:
            return "GitHub authorization was cancelled. Your existing access and saved setup choices were left unchanged."
        case .authorizationDenied(let reason):
            return reason.map { "GitHub denied authorization: \($0). No workspace access was changed." }
                ?? "GitHub denied authorization. No workspace access was changed."
        case .reconnectRequired(let workspace, let reason):
            return "Reconnect \(workspace): \(reason)"
        case .authorizationFailed:
            return "GitHub authorization failed unexpectedly. Your existing access and saved setup choices were left unchanged."
        case .verificationUnavailable(let workspace):
            return "GitHub access for \(workspace) could not be checked. Existing access stayed unchanged."
        case .verificationFailed(let workspace):
            return "GitHub access for \(workspace) could not be checked. Existing access stayed unchanged."
        case .lifecycleRestoreFailed(let workspace):
            return "GitHub access for \(workspace) needs reconnecting."
        case .multipleInstallationsUnsupported(let workspace):
            return "Each workspace can use repositories from one GitHub owner at a time. Review \(workspace) access."
        }
    }
}

actor GitHubAuthorizationCoordinator {
    private struct PendingAuthorization: Sendable {
        let discovery: GitHubAuthorizationDiscovery
        let expiresAt: Date
    }

    private enum TransactionPhase: String, Codable, Sendable {
        case prepared
        case localCommitted
        case revokingOld
        case rollingBack
        case committed
    }

    private enum PreviousPolicyRestoreState: String, Codable, Sendable {
        case notStarted
        case uncertain
        case cleaned
        case complete
    }

    private struct TransactionJournal: Codable, Sendable {
        let transactionID: UUID
        let sessionID: UUID
        let workspaceKeys: [String]
        var newGrantIDs: [UUID]
        var oldGrantIDs: [UUID]
        /// Workspaces whose host-side GitHub binding was positively removed.
        /// Optional so journals written by older builds decode as unproven.
        var verifiedUnboundWorkspaces: [String]?
        /// Optional so a legacy rollback journal is treated as an uncertain
        /// previous-policy restore and cleaned up conservatively.
        var previousPolicyRestoreState: PreviousPolicyRestoreState?
        var phase: TransactionPhase
        var updatedAt: Date
    }

    private struct PreviousCredential: Sendable {
        let metadata: WorkspaceCredentialMetadata
        let bundle: CredentialBundle?
    }

    private let broker: CredentialBroker
    private let connect: MSWConnectClient
    private let tokenRefreshCoordinator: TokenRefreshCoordinator
    /// Explicit dependency-injection seam for protocol tests whose fake grant
    /// payloads predate signed attestations. Production call sites keep the
    /// default false; UI fixtures bypass the coordinator entirely.
    private let allowsUnattestedTestConfiguration: Bool
    private let mswClient: MSWClient?
    private let now: @Sendable () -> Date
    private let journalURL: URL?
    private var pending: [UUID: PendingAuthorization] = [:]
    private var latestVerifications: [GitHubWorkspaceVerificationResult] = []

    init(
        broker: CredentialBroker,
        connect: MSWConnectClient = MSWConnectClient(),
        tokenRefreshCoordinator: TokenRefreshCoordinator? = nil,
        allowsUnattestedTestConfiguration: Bool = false,
        mswClient: MSWClient? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        journalURL: URL? = nil
    ) {
        self.broker = broker
        self.connect = connect
        self.tokenRefreshCoordinator = tokenRefreshCoordinator ?? TokenRefreshCoordinator(
            broker: broker,
            connect: connect
        )
        self.allowsUnattestedTestConfiguration = allowsUnattestedTestConfiguration
        self.mswClient = mswClient
        self.now = now
        self.journalURL = journalURL ?? Self.defaultJournalURL()
    }
    nonisolated var isConfigured: Bool {
        connect.configuration.isConfigured
    }
    nonisolated var isAvailable: Bool {
        GitHubFeatureAvailability.isAvailable(configuration: connect.configuration) ||
            (allowsUnattestedTestConfiguration && connect.configuration.isConfigured)
    }

    /// Starts one browser authorization session. The resulting session may
    /// create grants for all three workspaces; no workspace credential exists
    /// until commitPolicy has reviewed and applied the complete set.
    func beginAuthorization(
        browser: (any MSWConnectBrowserAuthenticating)? = nil
    ) async throws -> GitHubAuthorizationDiscovery {
        guard isAvailable else {
            throw GitHubAuthorizationError.invalidAppConfiguration
        }
        do {
            try await recoverPendingAuthorization()
        } catch GitHubAuthorizationError.serviceUnavailable {
            // Local roles are quarantined and the journal remains durable when
            // remote cleanup is unavailable. A new browser session can repair
            // that journal on the next commit without relying on an expired
            // session from the interrupted transaction.
        } catch {
            throw error
        }
        let authenticatingBrowser: any MSWConnectBrowserAuthenticating
        if let browser {
            authenticatingBrowser = browser
        } else {
            authenticatingBrowser = await MainActor.run { MSWConnectBrowser.shared }
        }
        do {
            let discovery = try await connect.authorize(browser: authenticatingBrowser)
            pending[discovery.sessionID] = PendingAuthorization(
                discovery: discovery,
                expiresAt: now().addingTimeInterval(15 * 60)
            )
            return discovery
        } catch MSWConnectError.installationUnavailable,
                MSWConnectError.installationRemoved {
            throw GitHubAuthorizationError.ownerNotInstalled
        } catch MSWConnectError.repositoryNotAllowed,
                MSWConnectError.accountBoundaryViolation {
            throw GitHubAuthorizationError.repositoryNotAllowed
        } catch MSWConnectError.transportUnavailable,
                MSWConnectError.httpStatus,
                MSWConnectError.rateLimited,
                MSWConnectError.sessionCleanupFailed {
            throw GitHubAuthorizationError.serviceUnavailable
        } catch MSWConnectError.sessionExpired, MSWConnectError.callbackExpired {
            throw GitHubAuthorizationError.authorizationSessionExpired
        } catch MSWConnectError.cancelled {
            throw GitHubAuthorizationError.authorizationCancelled
        } catch MSWConnectError.authorizationDenied(let reason) {
            throw GitHubAuthorizationError.authorizationDenied(reason)
        } catch MSWConnectError.invalidConfiguration {
            throw GitHubAuthorizationError.invalidAppConfiguration
        } catch MSWConnectError.malformedResponse,
                MSWConnectError.invalidCallback,
                MSWConnectError.callbackStateMismatch,
                MSWConnectError.callbackReplayed {
            throw GitHubAuthorizationError.authorizationFailed
        }
        catch {
            throw GitHubAuthorizationError.authorizationFailed
        }
    }

    /// Restores a nonsecret authorization selection after the setup window or
    /// app is relaunched. This never opens a browser and never creates a grant.
    func resumeAuthorization() async throws -> GitHubAuthorizationDiscovery? {
        try await recoverPendingAuthorization()
        let session: MSWConnectSession
        do {
            guard let restored = try await connect.restoreSession() else { return nil }
            session = restored
        } catch MSWConnectError.sessionExpired {
            throw GitHubAuthorizationError.authorizationSessionExpired
        } catch {
            throw GitHubAuthorizationError.serviceUnavailable
        }
        do {
            let installations = try await connect.installations()
            let discovery = GitHubAuthorizationDiscovery(
                sessionID: session.sessionID,
                account: session.account,
                installations: installations
            )
            pending[session.sessionID] = PendingAuthorization(
                discovery: discovery,
                expiresAt: min(session.expiresAt, now().addingTimeInterval(15 * 60))
            )
            return discovery
        } catch MSWConnectError.installationUnavailable,
                MSWConnectError.installationRemoved {
            throw GitHubAuthorizationError.ownerNotInstalled
        } catch MSWConnectError.repositoryNotAllowed,
                MSWConnectError.accountBoundaryViolation {
            throw GitHubAuthorizationError.repositoryNotAllowed
        } catch MSWConnectError.transportUnavailable,
                MSWConnectError.httpStatus,
                MSWConnectError.rateLimited,
                MSWConnectError.sessionCleanupFailed {
            throw GitHubAuthorizationError.serviceUnavailable
        } catch {
            throw GitHubAuthorizationError.serviceUnavailable
        }
    }

    func repositories(sessionID: UUID, installationID: Int) async throws -> [GitHubRepository] {
        removeExpiredSessions()
        guard let authorization = pending[sessionID] else {
            throw GitHubAuthorizationError.authorizationSessionExpired
        }
        guard let installation = authorization.discovery.installations.first(where: { $0.id == installationID }) else {
            throw GitHubAuthorizationError.ownerNotInstalled
        }
        do {
            let repositories = try await connect.repositories(installationID: installationID)
            guard repositories.allSatisfy({
                $0.owner.login.caseInsensitiveCompare(installation.account.login) == .orderedSame
            }) else {
                throw GitHubAuthorizationError.repositoryNotAllowed
            }
            return repositories
        } catch let error as GitHubAuthorizationError {
            throw error
        } catch MSWConnectError.installationUnavailable,
                MSWConnectError.installationRemoved,
                MSWConnectError.httpStatus(404) {
            throw GitHubAuthorizationError.ownerNotInstalled

        } catch MSWConnectError.accountBoundaryViolation {
            throw GitHubAuthorizationError.repositoryNotAllowed

        } catch {
            throw GitHubAuthorizationError.serviceUnavailable
        }
    }
    func commitPolicy(
        sessionID: UUID,
        policy: [GitHubWorkspacePolicy]
    ) async throws -> [WorkspaceCredentialMetadata] {
        try await commitPolicy(
            sessionID: sessionID,
            policy: policy,
            requireVerification: false
        ).metadata
    }

    func commitPolicyWithVerification(
        sessionID: UUID,
        policy: [GitHubWorkspacePolicy]
    ) async throws -> GitHubAuthorizationCommitResult {
        try await commitPolicy(
            sessionID: sessionID,
            policy: policy,
            requireVerification: true
        )
    }

    private func commitPolicy(
        sessionID: UUID,
        policy: [GitHubWorkspacePolicy],
        requireVerification: Bool
    ) async throws -> GitHubAuthorizationCommitResult {
        removeExpiredSessions()
        try await recoverPendingAuthorization()
        latestVerifications = []
        guard let authorization = pending[sessionID] else {
            throw GitHubAuthorizationError.authorizationSessionExpired
        }
        let repositories = policy.flatMap { $0.repositories }
        guard !policy.isEmpty,
              Set(policy.map(\.workspace)).count == policy.count,
              policy.allSatisfy(Self.isValidPolicy),
              Set(repositories.map(\.id)).count == repositories.count else {
            throw GitHubAuthorizationError.invalidSelection
        }
        let partitions = try Self.partition(repositories)
        let discoveredInstallations = Dictionary(uniqueKeysWithValues: authorization.discovery.installations.map { ($0.id, $0) })
        guard partitions.allSatisfy({
            guard let installation = discoveredInstallations[$0.installationID] else { return false }
            return installation.account.id == $0.ownerID &&
                installation.account.login.caseInsensitiveCompare($0.ownerLogin) == .orderedSame
        }) else {
            throw GitHubAuthorizationError.ownerNotInstalled
        }

        let affectedWorkspaces = Set(policy.map(\.workspace))
        let existingEntries = (await broker.allMetadata()).filter { entry in
            affectedWorkspaces.contains(entry.workspace)
        }
        var previous: [String: PreviousCredential] = [:]
        for entry in existingEntries {
            let key = "\(entry.workspace).\(entry.role.rawValue)"
            previous[key] = PreviousCredential(
                metadata: entry,
                bundle: try? await broker.load(workspace: entry.workspace, role: entry.role)
            )
        }

        var createdGrants: [(workspace: String, role: CredentialRole, grant: MSWConnectGrant)] = []
        var plannedCommits: [(
            partition: GitHubGrantPartition,
            role: CredentialRole,
            grant: MSWConnectGrant,
            verificationRepository: String
        )] = []
        var committed: [(workspace: String, role: CredentialRole)] = []
        var journal = TransactionJournal(
            transactionID: UUID(),
            sessionID: sessionID,
            workspaceKeys: Array(Set(
                existingEntries.map { "\($0.workspace).\($0.role.rawValue)" } +
                    partitions.flatMap { partition in
                        partition.writeRepositories.isEmpty
                            ? ["\(partition.workspace).guest"]
                            : ["\(partition.workspace).guest", "\(partition.workspace).host"]
                    }
            )).sorted(),
            newGrantIDs: [],
            oldGrantIDs: Array(Set(existingEntries.compactMap(\.grantID))).sorted { $0.uuidString < $1.uuidString },
            verifiedUnboundWorkspaces: [],
            previousPolicyRestoreState: .notStarted,
            phase: .prepared,
            updatedAt: now()
        )
        var preserveLocalState = false
        do {
            // Record the prepared transaction before creating any remote grant.
            // Recovery can then revoke grants created before a process crash.
            try persistJournal(journal)
            // Create and validate every remote grant before changing local
            // credentials. A failed partition therefore cannot leave a
            // partially committed workspace set behind.
            for partition in partitions {
                let availableRepositories = try await self.repositories(
                    sessionID: sessionID,
                    installationID: partition.installationID
                )
                let allowed = Dictionary(uniqueKeysWithValues: availableRepositories.map { ($0.id, $0) })
                guard partition.repositories.allSatisfy({ selected in
                    guard let repository = allowed[selected.repositoryID] else { return false }
                    return repository.id == selected.repositoryID &&
                        repository.fullName.caseInsensitiveCompare(selected.fullName) == .orderedSame &&
                        repository.owner.id == partition.ownerID &&
                        repository.owner.login.caseInsensitiveCompare(partition.ownerLogin) == .orderedSame
                }) else {
                    throw GitHubAuthorizationError.repositoryNotAllowed
                }
                let readScope = Self.sortedScope(partition.readRepositories)
                let readVerification = readScope[0].fullName

                let guest = try await createGrant(
                    partition: partition,
                    role: .guest,
                    accessMode: "read-only",
                    scope: readScope,
                    verificationRepository: readVerification
                )
                createdGrants.append((partition.workspace, .guest, guest))
                journal.newGrantIDs.append(guest.id)
                journal.updatedAt = now()
                try persistJournal(journal)
                plannedCommits.append((
                    partition,
                    .guest,
                    guest,
                    readVerification
                ))

                if !partition.writeRepositories.isEmpty {
                    let writeScope = Self.sortedScope(partition.writeRepositories)
                    let writeVerification = writeScope[0].fullName
                    let host = try await createGrant(
                        partition: partition,
                        role: .host,
                        accessMode: "host-write",
                        scope: writeScope,
                        verificationRepository: writeVerification
                    )
                    createdGrants.append((partition.workspace, .host, host))
                    journal.newGrantIDs.append(host.id)
                    journal.updatedAt = now()
                    try persistJournal(journal)
                    plannedCommits.append((
                        partition,
                        .host,
                        host,
                        writeVerification
                    ))
                }
            }


            for plan in plannedCommits {
                committed.append((plan.partition.workspace, plan.role))
                if let verification = try await commit(
                    plan.grant,
                    workspace: plan.partition.workspace,
                    role: plan.role,
                    partition: plan.partition,
                    verificationRepository: plan.verificationRepository,
                    requireVerification: requireVerification
                ) {
                    recordVerification(verification)
                }
            }

            journal.phase = .localCommitted
            journal.updatedAt = now()
            try persistJournal(journal)
            journal.phase = .revokingOld
            journal.updatedAt = now()
            try persistJournal(journal)

            var remainingOldGrants = journal.oldGrantIDs
            for grantID in journal.oldGrantIDs {
                do {
                    try await revokeGrant(grantID)
                    remainingOldGrants.removeAll { $0 == grantID }
                    journal.oldGrantIDs = remainingOldGrants
                    journal.updatedAt = now()
                    try? persistJournal(journal)
                } catch {
                    journal.oldGrantIDs = remainingOldGrants
                    journal.updatedAt = now()
                    try? persistJournal(journal)
                    // The old grant may still be usable remotely. Quarantine
                    // every role named by the journal, including roles being
                    // removed by a read-write to read-only replacement.
                    _ = await quarantineJournalRoles(journal)
                    pending.removeValue(forKey: sessionID)
                    preserveLocalState = true
                    throw GitHubAuthorizationError.revocationFailed
                }
            }

            let replacementKeys = Set(createdGrants.map { "\($0.workspace).\($0.role.rawValue)" })
            var localCleanupFailed = false
            for entry in existingEntries where !replacementKeys.contains("\(entry.workspace).\(entry.role.rawValue)") {
                do {
                    try await broker.remove(workspace: entry.workspace, role: entry.role)
                } catch {
                    localCleanupFailed = true
                }
            }
            if localCleanupFailed {
                _ = await quarantineJournalRoles(journal)
                pending.removeValue(forKey: sessionID)
                preserveLocalState = true
                throw GitHubAuthorizationError.revocationFailed
            }

            var result: [WorkspaceCredentialMetadata] = []
            for (workspace, role) in committed {
                if let entry = try await broker.metadata(for: workspace, role: role) {
                    result.append(entry)
                }
            }
            preserveLocalState = true
            journal.phase = .committed
            journal.updatedAt = now()
            try persistJournal(journal)
            pending.removeValue(forKey: sessionID)
            try? removeJournal()
            return GitHubAuthorizationCommitResult(
                metadata: result,
                verifications: latestVerifications.sorted { $0.id < $1.id }
            )
        } catch let error as GitHubAuthorizationError {
            if preserveLocalState {
                throw error
            }
            journal.phase = .rollingBack
            journal.updatedAt = now()
            try? persistJournal(journal)
            let rollbackSucceeded = await rollback(
                createdGrants: createdGrants,
                committed: committed,
                previous: previous,
                journal: &journal
            )
            pending.removeValue(forKey: sessionID)
            if rollbackSucceeded {
                markVerificationRollback("Previous access was restored and replacement grants were removed.")
                try? removeJournal()
            } else {
                markVerificationRollback("Recovery is incomplete; affected access was quarantined.")
                throw GitHubAuthorizationError.revocationFailed
            }
            throw error
        } catch MSWConnectError.scopeMismatch {
            journal.phase = .rollingBack
            journal.updatedAt = now()
            try? persistJournal(journal)
            let rollbackSucceeded = await rollback(
                createdGrants: createdGrants,
                committed: committed,
                previous: previous,
                journal: &journal
            )
            pending.removeValue(forKey: sessionID)
            if rollbackSucceeded {
                markVerificationRollback("Previous access was restored and replacement grants were removed.")
                try? removeJournal()
            } else {
                markVerificationRollback("Recovery is incomplete; affected access was quarantined.")
                throw GitHubAuthorizationError.revocationFailed
            }
            throw GitHubAuthorizationError.scopeMismatch
        } catch {
            journal.phase = .rollingBack
            journal.updatedAt = now()
            try? persistJournal(journal)
            let rollbackSucceeded = await rollback(
                createdGrants: createdGrants,
                committed: committed,
                previous: previous,
                journal: &journal
            )
            pending.removeValue(forKey: sessionID)
            if rollbackSucceeded {
                markVerificationRollback("Previous access was restored and replacement grants were removed.")
                try? removeJournal()
            } else {
                markVerificationRollback("Recovery is incomplete; affected access was quarantined.")
                throw GitHubAuthorizationError.revocationFailed
            }
            if let connectError = error as? MSWConnectError {
                switch connectError {
                case .sessionExpired, .sessionCleanupFailed:
                    throw GitHubAuthorizationError.authorizationSessionExpired
                case .transportUnavailable, .httpStatus, .rateLimited:
                    throw GitHubAuthorizationError.serviceUnavailable
                case .installationUnavailable, .installationRemoved:
                    throw GitHubAuthorizationError.ownerNotInstalled
                case .accountBoundaryViolation, .repositoryNotAllowed:
                    throw GitHubAuthorizationError.repositoryNotAllowed
                case .scopeAttestationInvalid:
                    throw GitHubAuthorizationError.scopeMismatch
                default:
                    break
                }
            }
            throw GitHubAuthorizationError.credentialCommitFailed
        }
    }

    func metadata() async -> [WorkspaceCredentialMetadata] {
        guard isAvailable else {
            do {
                _ = try await quarantineUnresolvableAccess()
                return await broker.allMetadata()
            } catch {
                return (await broker.allMetadata()).filter {
                    $0.quarantined || $0.recoveryState == .quarantined
                }
            }
        }
        // Settings must never inspect credential metadata while a durable
        // authorization journal is still being reconciled. Recovery errors
        // leave affected roles quarantined and the journal persisted for retry.
        do {
            try await recoverPendingAuthorization()
            await silentlyRenewExpiredGrants()
            return await broker.allMetadata()
        } catch {
            // A malformed or otherwise unrecoverable journal must not expose
            // any ready metadata. Quarantined records remain visible so the
            // user can understand which access needs explicit repair.
            return (await broker.allMetadata()).filter {
                $0.quarantined || $0.recoveryState == .quarantined
            }
        }
    }

    func verificationResults() -> [GitHubWorkspaceVerificationResult] {
        latestVerifications.sorted { $0.id < $1.id }
    }

    /// Preserve Connect-mode's existing identity path. Local onboarding uses
    /// `GitHubLocalProvider` so identity and policy reconciliation share one
    /// mutation coordinator.
    func setIdentity(name: String, email: String, workspace: String? = nil) async throws -> MSWIdentityResult {
        guard let mswClient else { throw GitHubAuthorizationError.serviceUnavailable }
        let response = try await mswClient.setIdentity(name: name, email: email, workspace: workspace)
        guard let result = response.result else { throw GitHubAuthorizationError.authorizationFailed }
        return result
    }

    func connectedAccount() async -> GitHubAccount? {
        guard isAvailable else { return nil }
        if let current = await connect.currentSession() {
            return current.account
        }
        do {
            return try await connect.restoreSession()?.account
        } catch {
            return nil
        }
    }

    func installationURL() async -> URL? {
        isAvailable ? connect.configuration.installationURL : nil
    }

    /// Reads only nonsecret local facts. Used by builds that deliberately do
    /// not ship Connect/attestations and therefore must not attempt recovery.
    func retainedMetadata() async -> [WorkspaceCredentialMetadata] {
        await broker.allMetadata()
    }

    /// A normal release without Connect/attestations cannot prove the state of
    /// retained remote grants. Keep those records visible but unusable; never
    /// imply that remote revocation or host cleanup occurred.
    func quarantineUnresolvableAccess() async throws -> [String] {
        if let journal = try readJournal(), !(await quarantineJournalRoles(journal)) {
            throw GitHubAuthorizationError.revocationFailed
        }
        let entries = await broker.allMetadata()
        for entry in entries where !entry.quarantined || entry.recoveryState != .quarantined {
            try await broker.updateRecoveryState(
                workspace: entry.workspace,
                role: entry.role,
                state: .quarantined,
                quarantined: true
            )
        }
        return Array(Set(entries.map(\.workspace))).sorted()
    }

    /// Retries only token renewal for a temporary outage. This deliberately
    /// never starts browser authorization.
    func retryUnavailableWorkspace(_ workspace: String) async throws {
        guard isAvailable else { throw GitHubAuthorizationError.invalidAppConfiguration }
        let entries = (await broker.allMetadata()).filter {
            $0.workspace == workspace &&
                !$0.quarantined &&
                ($0.recoveryState == .serviceUnavailable || $0.recoveryState == .expired)
        }
        guard !entries.isEmpty else { return }
        for entry in entries {
            do {
                _ = try await tokenRefreshCoordinator.refresh(workspace: workspace, role: entry.role)
            } catch TokenRefreshCoordinatorError.serviceUnavailable {
                throw GitHubAuthorizationError.serviceUnavailable
            } catch TokenRefreshCoordinatorError.missingGrant {
                try? await broker.updateRecoveryState(
                    workspace: workspace,
                    role: entry.role,
                    state: .needsAuthorization,
                    quarantined: true
                )
                let updated = (await broker.allMetadata()).filter { $0.workspace == workspace }
                let reason = GitHubWorkspaceAccessPresentation.make(
                    workspace: workspace,
                    entries: updated
                ).reason
                throw GitHubAuthorizationError.reconnectRequired(
                    workspace: workspace,
                    reason: reason
                )
            } catch TokenRefreshCoordinatorError.reauthorizationRequired {
                let updated = (await broker.allMetadata()).filter { $0.workspace == workspace }
                let reason = GitHubWorkspaceAccessPresentation.make(
                    workspace: workspace,
                    entries: updated
                ).reason
                throw GitHubAuthorizationError.reconnectRequired(
                    workspace: workspace,
                    reason: reason
                )
            } catch {
                throw GitHubAuthorizationError.serviceUnavailable
            }
        }
    }

    private func silentlyRenewExpiredGrants() async {
        let expired = (await broker.allMetadata()).filter { entry in
            !entry.quarantined &&
                (entry.recoveryState == .expired ||
                    (entry.recoveryState == .ready && entry.accessExpiresAt.map { $0 <= now() } == true))
        }
        for entry in expired {
            // The refresh coordinator records the meaningful result: ready,
            // temporary service outage, or a quarantined reconnect reason.
            // Metadata reads never open a browser and need not surface normal
            // token rotation as an authorization error.
            _ = try? await tokenRefreshCoordinator.refresh(
                workspace: entry.workspace,
                role: entry.role
            )
        }
    }

    func removeWorkspace(_ workspace: String) async throws {
        try await recoverPendingAuthorization()
        let entries = await broker.allMetadata().filter { $0.workspace == workspace }
        // With no recorded grant there is no proven binding or credential to
        // remove. Preserve the existing no-op semantics without touching
        // legacy broker records that cannot be paired with unbind proof.
        guard !entries.isEmpty else { return }
        do {
            // Remove the VM-held secret before revoking its service grant. If
            // local removal cannot be proven, keep the grant usable and
            // quarantine instead of creating an unrevocable local secret.
            try await unbindGitHubCredentialsVerified(workspace: workspace)
            for entry in entries {
                if let grantID = entry.grantID {
                    _ = try await connect.revokeGrant(grantID: grantID)
                }
            }
            try await broker.removeAllRoles(workspace: workspace)
        } catch {
            let state: CredentialRecoveryState
            if let connectError = error as? MSWConnectError {
                switch connectError {
                case .grantNotFound, .grantRevoked:
                    state = .revoked
                case .sessionExpired, .transportUnavailable, .httpStatus, .rateLimited:
                    state = .serviceUnavailable
                case .installationUnavailable, .installationRemoved:
                    state = .installationRemoved
                default:
                    state = .quarantined
                }
            } else {
                state = .quarantined
            }
            for entry in entries {
                try? await broker.updateRecoveryState(
                    workspace: workspace,
                    role: entry.role,
                    state: state,
                    quarantined: true
                )
            }
            throw GitHubAuthorizationError.revocationFailed
        }
    }

    /// Disables GitHub access for one workspace so a later bootstrap can
    /// complete without it: unbinds the host-side credential binding even when
    /// no local metadata remains (the host may still expect a credential, as
    /// with `MSW_GITHUB_RECONNECT_REQUIRED`), revokes every remaining remote
    /// grant, then removes local credential metadata. Any step that cannot be
    /// proven leaves the affected roles quarantined and throws
    /// `revocationFailed`, so setup keeps its review gate closed rather than
    /// bypassing cleanup.
    func disableWorkspaceGitHubAccess(_ workspace: String) async throws {
        // Reconcile any durable authorization journal first: prepared or
        // rolling-back transactions can hold remote grants that exist outside
        // broker metadata (journal newGrantIDs, outage-recovery placeholders),
        // so disabling must prove those grants revoked too before reporting
        // success. Recovery failure leaves the journal and its roles
        // quarantined and propagates (fail-closed).
        try await recoverPendingAuthorization()
        let entries = await broker.allMetadata().filter { $0.workspace == workspace }
        do {
            // Remove the VM-held secret first, mirroring removeWorkspace.
            // Unlike removeWorkspace this unbinds unconditionally: the local
            // metadata can already be gone while the host binding remains.
            try await unbindGitHubCredentialsVerified(workspace: workspace)
            for entry in entries {
                if let grantID = entry.grantID {
                    _ = try await connect.revokeGrant(grantID: grantID)
                }
            }
            try await broker.removeAllRoles(workspace: workspace)
        } catch {
            let state: CredentialRecoveryState
            if let connectError = error as? MSWConnectError {
                switch connectError {
                case .grantNotFound, .grantRevoked:
                    state = .revoked
                case .sessionExpired, .transportUnavailable, .httpStatus, .rateLimited:
                    state = .serviceUnavailable
                case .installationUnavailable, .installationRemoved:
                    state = .installationRemoved
                default:
                    state = .quarantined
                }
            } else {
                state = .quarantined
            }
            for entry in entries {
                try? await broker.updateRecoveryState(
                    workspace: workspace,
                    role: entry.role,
                    state: state,
                    quarantined: true
                )
            }
            throw GitHubAuthorizationError.revocationFailed
        }
    }

    func disconnectAccount() async throws {
        try await recoverPendingAuthorization()
        let entries = await broker.allMetadata()
        do {
            let workspaces = Set(entries.map(\.workspace))
            // An account with no credential metadata has no known workspace
            // binding to remove. Otherwise every affected workspace must
            // return positive unbind proof before account-wide revocation.
            for workspace in workspaces {
                try await unbindGitHubCredentialsVerified(workspace: workspace)
            }
            let grantIDs = entries.compactMap(\.grantID)
            try await connect.revokeAccount(expectedGrantIDs: grantIDs)
            for workspace in workspaces {
                try await broker.removeAllRoles(workspace: workspace)
            }
            try await connect.clearSession()
        } catch {
            let state: CredentialRecoveryState
            if let connectError = error as? MSWConnectError {
                switch connectError {
                case .installationUnavailable, .installationRemoved:
                    state = .installationRemoved
                case .sessionExpired, .transportUnavailable, .httpStatus, .rateLimited:
                    state = .serviceUnavailable
                default:
                    state = .quarantined
                }
            } else {
                state = .quarantined
            }
            for entry in entries {
                try? await broker.updateRecoveryState(
                    workspace: entry.workspace,
                    role: entry.role,
                    state: state,
                    quarantined: true
                )
            }
            throw GitHubAuthorizationError.revocationFailed
        }
    }

    /// Proves that MSW removed the host-side workspace binding. Callers must
    /// complete this step before revoking remote grants or deleting local
    /// credentials so an unverified host secret can never be orphaned.
    private func unbindGitHubCredentialsVerified(workspace: String) async throws {
        guard let mswClient else {
            throw GitHubAuthorizationError.serviceUnavailable
        }
        let response = try await mswClient.unbindGitHubCredentials(workspace: workspace)
        guard let result = response.result,
              result.workspace == workspace,
              result.unbound else {
            throw GitHubAuthorizationError.revocationFailed
        }
    }

    func cancelAuthorization(sessionID: UUID) {
        pending.removeValue(forKey: sessionID)
    }

    private func createGrant(
        partition: GitHubGrantPartition,
        role: CredentialRole,
        accessMode: String,
        scope: [GitHubRepositoryPolicy],
        verificationRepository: String
    ) async throws -> MSWConnectGrant {
        let request = MSWConnectGrantAssignment(
            workspace: partition.workspace,
            role: role,
            owner: partition.ownerLogin,
            installationID: partition.installationID,
            repositoryIDs: scope.map(\.repositoryID),
            repositoryNames: scope.map(\.fullName),
            accessMode: accessMode,
            verificationRepository: verificationRepository
        )
        do {
            return try await connect.createGrant(request)
        } catch MSWConnectError.scopeMismatch {
            throw GitHubAuthorizationError.scopeMismatch
        } catch MSWConnectError.sessionExpired {
            throw GitHubAuthorizationError.authorizationSessionExpired
        } catch MSWConnectError.installationUnavailable,
                MSWConnectError.installationRemoved {
            throw GitHubAuthorizationError.ownerNotInstalled
        } catch MSWConnectError.accountBoundaryViolation {
            throw GitHubAuthorizationError.repositoryNotAllowed
        } catch MSWConnectError.transportUnavailable, MSWConnectError.httpStatus {
            throw GitHubAuthorizationError.serviceUnavailable
        }
    }

    private func commit(
        _ grant: MSWConnectGrant,
        workspace: String,
        role: CredentialRole,
        partition: GitHubGrantPartition,
        verificationRepository: String,
        requireVerification: Bool
    ) async throws -> GitHubWorkspaceVerificationResult? {
        let accessMode = role == .host ? "host-write" : "read-only"
        var stored = false
        do {
            try await broker.storeScopedCredential(
                grant.credential,
                workspace: workspace,
                accessMode: accessMode,
                verificationRepository: verificationRepository,
                installationID: grant.installationID,
                role: role,
                accountLogin: grant.accountLogin,
                owner: partition.ownerLogin,
                repositoryIDs: grant.repositoryIDs,
                repositoryNames: grant.repositoryNames,
                scopeDigest: grant.scopeDigest
            )
            stored = true
            if let mswClient {
                let response = try await mswClient.bindGitHubCredentials(
                    workspace: workspace,
                    accessMode: accessMode,
                    verificationRepository: verificationRepository
                )
                guard let result = response.result else {
                    let verification = verificationResult(
                        workspace: workspace,
                        partition: partition,
                        role: role,
                        verificationRepository: verificationRepository,
                        verified: false,
                        lifecycleRestored: false,
                        safetyResult: "MSW returned no verification result; rollback is required."
                    )
                    recordVerification(verification)
                    throw GitHubAuthorizationError.verificationFailed(workspace)
                }
                let verification = verificationResult(
                    workspace: workspace,
                    partition: partition,
                    role: role,
                    verificationRepository: verificationRepository,
                    verified: result.verified,
                    lifecycleRestored: result.lifecycleRestored,
                    safetyResult: result.verified && result.lifecycleRestored
                        ? "Repository permissions verified and the prior VM lifecycle was restored."
                        : "Verification did not complete; rollback is required."
                )
                guard result.verified else {
                    recordVerification(verification)
                    throw GitHubAuthorizationError.verificationFailed(workspace)
                }
                guard result.lifecycleRestored else {
                    recordVerification(verification)
                    throw GitHubAuthorizationError.lifecycleRestoreFailed(workspace)
                }
                try await broker.markBound(workspace: workspace, role: role)
                return verification
            } else if requireVerification {
                let verification = verificationResult(
                    workspace: workspace,
                    partition: partition,
                    role: role,
                    verificationRepository: verificationRepository,
                    verified: false,
                    lifecycleRestored: false,
                    safetyResult: "The MSW verification service is unavailable; rollback is required."
                )
                recordVerification(verification)
                throw GitHubAuthorizationError.verificationUnavailable(workspace)
            }
            return nil
        } catch {
            if stored, !latestVerifications.contains(where: {
                $0.workspace == workspace && $0.installationID == partition.installationID && $0.role == role
            }) {
                recordVerification(verificationResult(
                    workspace: workspace,
                    partition: partition,
                    role: role,
                    verificationRepository: verificationRepository,
                    verified: false,
                    lifecycleRestored: false,
                    safetyResult: "Verification failed before MSW returned a final result; rollback is required."
                ))
            }
            if stored {
                try? await broker.quarantine(workspace: workspace, role: role)
            }
            throw error
        }
    }

    private func verificationResult(
        workspace: String,
        partition: GitHubGrantPartition,
        role: CredentialRole,
        verificationRepository: String,
        verified: Bool,
        lifecycleRestored: Bool,
        safetyResult: String
    ) -> GitHubWorkspaceVerificationResult {
        GitHubWorkspaceVerificationResult(
            workspace: workspace,
            installationID: partition.installationID,
            role: role,
            accessMode: role == .host ? "host-write" : "read-only",
            verificationRepository: verificationRepository,
            verified: verified,
            lifecycleRestored: lifecycleRestored,
            safetyResult: safetyResult,
            checkedAt: now()
        )
    }

    private func recordVerification(_ result: GitHubWorkspaceVerificationResult) {
        latestVerifications.removeAll { $0.id == result.id }
        latestVerifications.append(result)
    }

    private func markVerificationRollback(_ safetyResult: String) {
        latestVerifications = latestVerifications.map {
            GitHubWorkspaceVerificationResult(
                workspace: $0.workspace,
                installationID: $0.installationID,
                role: $0.role,
                accessMode: $0.accessMode,
                verificationRepository: $0.verificationRepository,
                verified: $0.verified,
                lifecycleRestored: $0.lifecycleRestored,
                safetyResult: safetyResult,
                checkedAt: $0.checkedAt
            )
        }
    }

    private func rollback(
        createdGrants: [(workspace: String, role: CredentialRole, grant: MSWConnectGrant)],
        committed: [(workspace: String, role: CredentialRole)],
        previous: [String: PreviousCredential],
        journal: inout TransactionJournal
    ) async -> Bool {
        var succeeded = true
        let workspaceKeys = journal.workspaceKeys
        let workspaces = Set(workspaceKeys.compactMap { $0.split(separator: ".").first.map(String.init) })

        // Remove the newly delivered VM secret while the newly stored guest
        // token is still available. Rebinding an old policy happens only
        // after every rollback step has succeeded.
        if !createdGrants.isEmpty || !committed.isEmpty {
            guard await verifyJournalUnbinds(&journal) else { return false }
        }

        for committedEntry in Set(committed.map { "\($0.workspace).\($0.role.rawValue)" }) {
            let components = committedEntry.split(separator: ".")
            guard components.count == 2,
                  let role = CredentialRole(rawValue: String(components[1])) else {
                succeeded = false
                continue
            }
            let workspace = String(components[0])
            do {
                if let snapshot = previous[committedEntry], let bundle = snapshot.bundle {
                    try await broker.restore(bundle)
                } else {
                    try await broker.remove(workspace: workspace, role: role)
                }
            } catch {
                succeeded = false
                try? await broker.quarantine(workspace: workspace, role: role)
            }
        }

        for created in createdGrants {
            do {
                try await revokeGrant(created.grant.id)
                journal.newGrantIDs.removeAll { $0 == created.grant.id }
                journal.updatedAt = now()
                try persistJournal(journal)
            } catch {
                succeeded = false
            }
        }

        let intendedBindings = workspaces.sorted().flatMap { workspace in
            CredentialRole.allCases.compactMap { role -> (String, CredentialRole, CredentialBundle)? in
                let key = "\(workspace).\(role.rawValue)"
                guard let bundle = previous[key]?.bundle,
                      !bundle.metadata.needsRestart else { return nil }
                return (workspace, role, bundle)
            }
        }
        if succeeded, !intendedBindings.isEmpty {
            guard let mswClient else {
                succeeded = false
                return await finishRollback(succeeded: succeeded, workspaceKeys: workspaceKeys)
            }
            do {
                // Any earlier unbind proof becomes stale as soon as a prior
                // policy bind can run. Persist that uncertainty first so a
                // crash can never make recovery trust the old proof.
                journal.previousPolicyRestoreState = .uncertain
                journal.verifiedUnboundWorkspaces = []
                journal.updatedAt = now()
                try persistJournal(journal)

                for (workspace, role, bundle) in intendedBindings {
                    let accessMode = role == .host ? "host-write" : "read-only"
                    let verificationRepository = bundle.metadata.verificationRepository ?? ""
                    let response = try await mswClient.bindGitHubCredentials(
                        workspace: workspace,
                        accessMode: accessMode,
                        verificationRepository: verificationRepository
                    )
                    guard let result = response.result,
                          result.workspace == workspace,
                          result.accessMode == accessMode,
                          result.verificationRepository == verificationRepository,
                          result.verified,
                          result.lifecycleRestored else {
                        throw GitHubAuthorizationError.revocationFailed
                    }
                    // A missing, mismatched, or false bind result must never
                    // make the restored local credential appear bound.
                    try await broker.markBound(workspace: workspace, role: role)
                }

                journal.previousPolicyRestoreState = .complete
                journal.updatedAt = now()
                try persistJournal(journal)
            } catch {
                succeeded = false
                // A successful bind may have occurred before a later restore
                // failed or returned an invalid result. Do not return while
                // that possibly rebound secret remains live: invalidate the
                // stale proof above, then require a fresh exact unbind now.
                if await verifyJournalUnbinds(&journal) {
                    journal.previousPolicyRestoreState = .cleaned
                    journal.updatedAt = now()
                    try? persistJournal(journal)
                }
            }
        } else if succeeded {
            do {
                journal.previousPolicyRestoreState = .complete
                journal.updatedAt = now()
                try persistJournal(journal)
            } catch {
                succeeded = false
            }
        }
        return await finishRollback(succeeded: succeeded, workspaceKeys: workspaceKeys)
    }

    private func finishRollback(succeeded: Bool, workspaceKeys: [String]) async -> Bool {
        if !succeeded {
            // Never leave a partially restored credential usable when remote
            // revocation, VM unbinding, or local rollback was uncertain.
            for key in workspaceKeys {
                let components = key.split(separator: ".")
                guard components.count == 2,
                      let role = CredentialRole(rawValue: String(components[1])) else { continue }
                try? await broker.quarantine(workspace: String(components[0]), role: role)
            }
        }
        return succeeded
    }

    /// Establishes durable, exact unbind proof for every workspace named by a
    /// rollback journal. A proof is persisted before any grant or credential
    /// cleanup, so recovery never has to repeat a potentially non-idempotent
    /// host unbind after a crash.
    private func verifyJournalUnbinds(_ journal: inout TransactionJournal) async -> Bool {
        let workspaces = Set(journal.workspaceKeys.compactMap { key -> String? in
            let components = key.split(separator: ".")
            guard components.count == 2,
                  CredentialRole(rawValue: String(components[1])) != nil,
                  WorkspaceID.isValid(String(components[0])) else { return nil }
            return String(components[0])
        })
        guard !workspaces.isEmpty,
              journal.workspaceKeys.allSatisfy({ key in
                  let components = key.split(separator: ".")
                  return components.count == 2 &&
                      CredentialRole(rawValue: String(components[1])) != nil &&
                      WorkspaceID.isValid(String(components[0]))
              }) else {
            _ = await quarantineJournalRoles(journal)
            journal.updatedAt = now()
            try? persistJournal(journal)
            return false
        }

        var verified = Set(journal.verifiedUnboundWorkspaces ?? [])
        guard verified.isSubset(of: workspaces) else {
            _ = await quarantineJournalRoles(journal)
            journal.updatedAt = now()
            try? persistJournal(journal)
            return false
        }
        if verified == workspaces { return true }
        guard let mswClient else {
            _ = await quarantineJournalRoles(journal)
            journal.updatedAt = now()
            try? persistJournal(journal)
            return false
        }
        for workspace in workspaces.sorted() where !verified.contains(workspace) {
            do {
                let response = try await mswClient.unbindGitHubCredentials(workspace: workspace)
                guard let result = response.result,
                      result.workspace == workspace,
                      result.unbound else {
                    throw GitHubAuthorizationError.revocationFailed
                }
                verified.insert(workspace)
                journal.verifiedUnboundWorkspaces = verified.sorted()
                journal.updatedAt = now()
                try persistJournal(journal)
            } catch {
                _ = await quarantineJournalRoles(journal)
                journal.updatedAt = now()
                try? persistJournal(journal)
                return false
            }
        }
        return verified == workspaces
    }

    private func revokeGrant(_ grantID: UUID) async throws {
        do {
            _ = try await connect.revokeGrant(grantID: grantID)
        } catch MSWConnectError.grantNotFound, MSWConnectError.grantRevoked, MSWConnectError.httpStatus(404) {
            // DELETE is intentionally idempotent for transaction recovery: a
            // grant that is already gone or already revoked counts as revoked.
        }
    }

    private static func defaultJournalURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("MSW Monitor", isDirectory: true)
            .appendingPathComponent("authorization-transaction.json")
    }

    private func readJournal() throws -> TransactionJournal? {
        guard let journalURL, FileManager.default.fileExists(atPath: journalURL.path) else {
            return nil
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(TransactionJournal.self, from: Data(contentsOf: journalURL))
        } catch {
            throw GitHubAuthorizationError.credentialCommitFailed
        }
    }

    private func persistJournal(_ journal: TransactionJournal) throws {
        guard let journalURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let directory = journalURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try encoder.encode(journal).write(to: journalURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
        } catch {
            throw GitHubAuthorizationError.credentialCommitFailed
        }
    }

    private func removeJournal() throws {
        guard let journalURL, FileManager.default.fileExists(atPath: journalURL.path) else { return }
        try FileManager.default.removeItem(at: journalURL)
    }
    private func quarantineJournalRoles(_ journal: TransactionJournal) async -> Bool {
        var succeeded = true
        for key in journal.workspaceKeys {
            let components = key.split(separator: ".")
            guard components.count == 2,
                  let role = CredentialRole(rawValue: String(components[1])),
                  WorkspaceID.isValid(String(components[0])) else {
                succeeded = false
                continue
            }
            do {
                // `quarantine` creates a durable record when local commit was
                // only partial, so even a role absent from metadata is blocked
                // before remote cleanup is retried.
                try await broker.quarantine(
                    workspace: String(components[0]),
                    role: role
                )
            } catch {
                succeeded = false
            }
        }
        return succeeded
    }


    private func reconcileCommittedJournal(_ journal: TransactionJournal) async throws {
        let expectedGrantIDs = Set(journal.newGrantIDs)
        let relevantEntries = await broker.allMetadata().filter {
            journal.workspaceKeys.contains($0.id)
        }
        let presentGrantIDs = Set(relevantEntries.compactMap(\.grantID))
        guard expectedGrantIDs.isSubset(of: presentGrantIDs) else {
            for key in journal.workspaceKeys {
                let components = key.split(separator: ".")
                guard components.count == 2,
                      let role = CredentialRole(rawValue: String(components[1])) else { continue }
                try? await broker.quarantine(workspace: String(components[0]), role: role)
            }
            throw GitHubAuthorizationError.revocationFailed
        }

        var cleanupFailed = false
        for entry in relevantEntries {
            guard let grantID = entry.grantID,
                  expectedGrantIDs.contains(grantID) else {
                do {
                    try await broker.remove(workspace: entry.workspace, role: entry.role)
                } catch {
                    cleanupFailed = true
                    try? await broker.updateRecoveryState(
                        workspace: entry.workspace,
                        role: entry.role,
                        state: .quarantined,
                        quarantined: true
                    )
                }
                continue
            }
            guard entry.recoveryState == .ready, !entry.quarantined else {
                do {
                    let bundle = try await broker.loadForRecovery(workspace: entry.workspace, role: entry.role)
                    guard !bundle.credential.isAccessExpired else {
                        throw CredentialBrokerError.grantUnavailable
                    }
                    try await broker.updateRecoveryState(
                        workspace: entry.workspace,
                        role: entry.role,
                        state: .ready,
                        quarantined: false
                    )
                } catch {
                    cleanupFailed = true
                    try? await broker.updateRecoveryState(
                        workspace: entry.workspace,
                        role: entry.role,
                        state: .quarantined,
                        quarantined: true
                    )
                }
                continue
            }
        }
        if cleanupFailed {
            throw GitHubAuthorizationError.revocationFailed
        }
    }

    func recoverPendingAuthorization() async throws {
        guard var journal = try readJournal() else { return }
        switch journal.phase {
        case .committed:
            try? removeJournal()
        case .localCommitted, .revokingOld:
            guard await quarantineJournalRoles(journal) else {
                journal.updatedAt = now()
                try? persistJournal(journal)
                throw GitHubAuthorizationError.revocationFailed
            }
            let expectedGrantIDs = Set(journal.newGrantIDs)
            let presentGrantIDs = Set(
                (await broker.allMetadata())
                    .filter { journal.workspaceKeys.contains($0.id) }
                    .compactMap(\.grantID)
            )
            if !expectedGrantIDs.isSubset(of: presentGrantIDs) {
                // Detect a partial local commit before revoking old grants. A
                // crash can leave a replacement secret bound while the journal
                // still says localCommitted, so no remote DELETE is safe until
                // every workspace has durable, exact unbind proof.
                journal.phase = .rollingBack
                journal.updatedAt = now()
                try? persistJournal(journal)
                guard await verifyJournalUnbinds(&journal) else {
                    throw GitHubAuthorizationError.revocationFailed
                }
                var remainingNewGrants = journal.newGrantIDs
                for grantID in journal.newGrantIDs {
                    do {
                        try await revokeGrant(grantID)
                        remainingNewGrants.removeAll { $0 == grantID }
                        journal.newGrantIDs = remainingNewGrants
                        journal.updatedAt = now()
                        try? persistJournal(journal)
                    } catch {
                        journal.newGrantIDs = remainingNewGrants
                        journal.updatedAt = now()
                        try? persistJournal(journal)
                        _ = await quarantineJournalRoles(journal)
                        throw GitHubAuthorizationError.serviceUnavailable
                    }
                }
                journal.previousPolicyRestoreState = .cleaned
                journal.updatedAt = now()
                do {
                    try persistJournal(journal)
                } catch {
                    throw GitHubAuthorizationError.revocationFailed
                }
                throw GitHubAuthorizationError.revocationFailed
            }
            var remaining = journal.oldGrantIDs
            for grantID in journal.oldGrantIDs {
                do {
                    try await revokeGrant(grantID)
                    remaining.removeAll { $0 == grantID }
                    journal.oldGrantIDs = remaining
                    journal.updatedAt = now()
                    try? persistJournal(journal)
                } catch {
                    journal.oldGrantIDs = remaining
                    journal.updatedAt = now()
                    try? persistJournal(journal)
                    // The old grant may still be usable remotely. Keep every
                    // journal role quarantined while the journal is retried.
                    _ = await quarantineJournalRoles(journal)
                    throw GitHubAuthorizationError.serviceUnavailable
                }
            }

            do {
                try await reconcileCommittedJournal(journal)
            } catch {
                journal.updatedAt = now()
                try? persistJournal(journal)
                throw error
            }
            journal.phase = .committed
            journal.updatedAt = now()
            try? persistJournal(journal)
            try? removeJournal()
        case .prepared:
            guard await quarantineJournalRoles(journal) else {
                journal.updatedAt = now()
                try? persistJournal(journal)
                throw GitHubAuthorizationError.revocationFailed
            }
            if !journal.newGrantIDs.isEmpty {
                guard await verifyJournalUnbinds(&journal) else {
                    throw GitHubAuthorizationError.revocationFailed
                }
            }
            var remaining = journal.newGrantIDs
            for grantID in journal.newGrantIDs {
                do {
                    try await revokeGrant(grantID)
                    remaining.removeAll { $0 == grantID }
                    journal.newGrantIDs = remaining
                    journal.updatedAt = now()
                    try? persistJournal(journal)
                } catch {
                    journal.newGrantIDs = remaining
                    journal.updatedAt = now()
                    try? persistJournal(journal)
                    throw GitHubAuthorizationError.serviceUnavailable
                }
            }
            try? removeJournal()
        case .rollingBack:
            if journal.previousPolicyRestoreState == .complete {
                try? removeJournal()
                return
            }
            guard await quarantineJournalRoles(journal) else {
                journal.updatedAt = now()
                try? persistJournal(journal)
                throw GitHubAuthorizationError.revocationFailed
            }
            if journal.previousPolicyRestoreState == .cleaned {
                // Rollback already established fresh exact unbind proof after
                // a failed prior-policy restore. Keep local roles fail-closed,
                // but do not rebind or issue an unnecessary second unbind.
                var remaining = journal.newGrantIDs
                for grantID in journal.newGrantIDs {
                    do {
                        try await revokeGrant(grantID)
                        remaining.removeAll { $0 == grantID }
                        journal.newGrantIDs = remaining
                        journal.updatedAt = now()
                        try? persistJournal(journal)
                    } catch {
                        journal.newGrantIDs = remaining
                        journal.updatedAt = now()
                        try? persistJournal(journal)
                        throw GitHubAuthorizationError.serviceUnavailable
                    }
                }
                try? removeJournal()
                return
            }
            // A legacy, partial, or interrupted prior-policy restore may have
            // rebound a secret after the journal's earlier unbind proof. Clear
            // that stale proof durably and require a fresh exact unbind even
            // when every replacement grant was already revoked.
            journal.verifiedUnboundWorkspaces = []
            journal.updatedAt = now()
            do {
                try persistJournal(journal)
            } catch {
                throw GitHubAuthorizationError.revocationFailed
            }
            guard await verifyJournalUnbinds(&journal) else {
                throw GitHubAuthorizationError.revocationFailed
            }
            var remaining = journal.newGrantIDs
            for grantID in journal.newGrantIDs {
                do {
                    try await revokeGrant(grantID)
                    remaining.removeAll { $0 == grantID }
                    journal.newGrantIDs = remaining
                    journal.updatedAt = now()
                    try? persistJournal(journal)
                } catch {
                    journal.newGrantIDs = remaining
                    journal.updatedAt = now()
                    try? persistJournal(journal)
                    throw GitHubAuthorizationError.serviceUnavailable
                }
            }
            try? removeJournal()
        }
    }
    private static func isValidPolicy(_ policy: GitHubWorkspacePolicy) -> Bool {
        WorkspaceID.isValid(policy.workspace) &&
            policy.repositories.allSatisfy {
                $0.workspace == policy.workspace && isValidPolicy($0)
            }
    }

    private static func isValidPolicy(_ policy: GitHubRepositoryPolicy) -> Bool {
        WorkspaceID.isValid(policy.workspace) &&
            policy.repositoryID > 0 &&
            isSafeRepositoryName(policy.fullName) &&
            policy.installationID > 0 &&
            policy.ownerID > 0 &&
            isSafeIdentifier(policy.ownerLogin) &&
            policy.fullName.split(separator: "/").first.map(String.init)?.caseInsensitiveCompare(policy.ownerLogin) == .orderedSame
    }

    private static func partition(_ policy: [GitHubRepositoryPolicy]) throws -> [GitHubGrantPartition] {
        let byWorkspace = Dictionary(grouping: policy, by: \.workspace)
        for (workspace, entries) in byWorkspace where Set(entries.map(\.installationID)).count != 1 {
            throw GitHubAuthorizationError.multipleInstallationsUnsupported(workspace)
        }
        return try byWorkspace.keys.sorted().map { workspace in
            guard let entries = byWorkspace[workspace],
                  let first = entries.first,
                  entries.allSatisfy({
                      $0.installationID == first.installationID &&
                      $0.ownerID == first.ownerID &&
                      $0.ownerLogin.caseInsensitiveCompare(first.ownerLogin) == .orderedSame &&
                      $0.ownerType == first.ownerType
                  }) else {
                throw GitHubAuthorizationError.invalidSelection
            }
            return GitHubGrantPartition(
                workspace: workspace,
                installationID: first.installationID,
                ownerID: first.ownerID,
                ownerLogin: first.ownerLogin,
                ownerType: first.ownerType,
                repositories: sortedScope(entries)
            )
        }
    }

    private static func sortedScope(_ scope: [GitHubRepositoryPolicy]) -> [GitHubRepositoryPolicy] {
        scope.sorted {
            let left = $0.fullName.lowercased()
            let right = $1.fullName.lowercased()
            return left == right ? $0.repositoryID < $1.repositoryID : left < right
        }
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        !value.isEmpty &&
            !value.contains("/") &&
            !value.unicodeScalars.contains {
                CharacterSet.whitespacesAndNewlines.contains($0) ||
                    CharacterSet.controlCharacters.contains($0)
            }
    }

    private static func isSafeRepositoryName(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 &&
            isSafeIdentifier(String(parts[0])) &&
            isSafeIdentifier(String(parts[1]))
    }

    private func removeExpiredSessions() {
        let current = now()
        pending = pending.filter { $0.value.expiresAt > current }
    }
}
