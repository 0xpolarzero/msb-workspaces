import Foundation


struct GitHubWorkspaceAssignment: Sendable, Equatable, Identifiable {
    let id: UUID
    let workspace: String
    let owner: String
    let installationID: Int
    let repositoryIDs: [Int]
    let repositoryNames: [String]
    let accessMode: String
    let verificationRepository: String

    init(
        id: UUID = UUID(),
        workspace: String,
        owner: String,
        installationID: Int,
        repositoryIDs: [Int],
        repositoryNames: [String],
        accessMode: String = "read-only",
        verificationRepository: String
    ) {
        self.id = id
        self.workspace = workspace
        self.owner = owner
        self.installationID = installationID
        self.repositoryIDs = repositoryIDs
        self.repositoryNames = repositoryNames
        self.accessMode = accessMode
        self.verificationRepository = verificationRepository
    }
}

struct GitHubAuthorizationDiscovery: Sendable, Equatable {
    let sessionID: UUID
    let account: GitHubAccount
    let installations: [GitHubInstallation]
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

    var errorDescription: String? {
        switch self {
        case .invalidSelection: return "The GitHub owner, repository, or workspace assignment is invalid."
        case .invalidAppConfiguration: return "MSW Connect authorization is not configured safely."
        case .guestAuthorizationRequired: return "Authorize guest read access before enabling host write access."
        case .authorizationSessionExpired: return "The MSW Connect authorization selection expired. Start Connect GitHub again."
        case .ownerNotInstalled: return "The selected GitHub owner has not installed the MSW App."
        case .repositoryNotAllowed: return "One or more selected repositories are outside the GitHub App installation scope."
        case .accountLookupFailed: return "GitHub authorization succeeded, but the account could not be verified."
        case .credentialCommitFailed: return "GitHub authorization could not be committed to the credential broker."
        case .serviceUnavailable: return "MSW Connect is unavailable. The existing workspace access was left unchanged."
        case .scopeMismatch: return "The authorization service returned broader access than requested. The grant was rejected."
        case .revocationFailed: return "The service could not prove that the requested GitHub grant was revoked."
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

    private struct TransactionJournal: Codable, Sendable {
        let transactionID: UUID
        let sessionID: UUID
        let workspaceKeys: [String]
        var newGrantIDs: [UUID]
        var oldGrantIDs: [UUID]
        var phase: TransactionPhase
        var updatedAt: Date
    }

    private struct PreviousCredential: Sendable {
        let metadata: WorkspaceCredentialMetadata
        let bundle: CredentialBundle?
    }

    private let broker: CredentialBroker
    private let connect: MSWConnectClient
    private let mswClient: MSWClient?
    private let now: @Sendable () -> Date
    private let journalURL: URL?
    private var pending: [UUID: PendingAuthorization] = [:]

    init(
        broker: CredentialBroker,
        connect: MSWConnectClient = MSWConnectClient(),
        mswClient: MSWClient? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        journalURL: URL? = nil
    ) {
        self.broker = broker
        self.connect = connect
        self.mswClient = mswClient
        self.now = now
        self.journalURL = journalURL ?? Self.defaultJournalURL()
    }

    /// Starts one browser authorization session. The resulting session may
    /// create grants for all three workspaces; no workspace credential exists
    /// until commitAssignments has reviewed and applied the complete set.
    func beginAuthorization(
        browser: (any MSWConnectBrowserAuthenticating)? = nil
    ) async throws -> GitHubAuthorizationDiscovery {
        try await recoverPendingAuthorization()
        let authenticatingBrowser: any MSWConnectBrowserAuthenticating
        if let browser {
            authenticatingBrowser = browser
        } else {
            authenticatingBrowser = await MainActor.run { MSWConnectBrowser() }
        }
        do {
            let discovery = try await connect.authorize(browser: authenticatingBrowser)
            pending[discovery.sessionID] = PendingAuthorization(
                discovery: discovery,
                expiresAt: now().addingTimeInterval(15 * 60)
            )
            return discovery
        } catch MSWConnectError.transportUnavailable,
                MSWConnectError.httpStatus,
                MSWConnectError.rateLimited,
                MSWConnectError.sessionCleanupFailed {
            throw GitHubAuthorizationError.serviceUnavailable
        } catch MSWConnectError.sessionExpired {
            throw GitHubAuthorizationError.authorizationSessionExpired
        } catch MSWConnectError.cancelled {
            throw MSWConnectError.cancelled
        }
        catch {
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
        } catch MSWConnectError.installationUnavailable, MSWConnectError.httpStatus(404) {
            throw GitHubAuthorizationError.ownerNotInstalled
        } catch MSWConnectError.accountBoundaryViolation {
            throw GitHubAuthorizationError.repositoryNotAllowed
        } catch {
            throw GitHubAuthorizationError.serviceUnavailable
        }
    }
    func commitAssignments(
        sessionID: UUID,
        assignments: [GitHubWorkspaceAssignment]
    ) async throws -> [WorkspaceCredentialMetadata] {
        removeExpiredSessions()
        try await recoverPendingAuthorization()
        guard let authorization = pending[sessionID] else {
            throw GitHubAuthorizationError.authorizationSessionExpired
        }
        guard !assignments.isEmpty,
              Set(assignments.map(\.workspace)).count == assignments.count,
              assignments.allSatisfy(Self.isValidAssignment) else {
            throw GitHubAuthorizationError.invalidSelection
        }
        let discoveredInstallations = Dictionary(uniqueKeysWithValues: authorization.discovery.installations.map { ($0.id, $0) })
        guard assignments.allSatisfy({
            guard let installation = discoveredInstallations[$0.installationID] else { return false }
            return installation.account.login.caseInsensitiveCompare($0.owner) == .orderedSame
        }) else {
            throw GitHubAuthorizationError.ownerNotInstalled
        }

        let existingEntries = (await broker.allMetadata()).filter { entry in
            assignments.contains { $0.workspace == entry.workspace }
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
            assignment: GitHubWorkspaceAssignment,
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
                    assignments.flatMap { assignment in
                        assignment.accessMode == "read-write"
                            ? ["\(assignment.workspace).guest", "\(assignment.workspace).host"]
                            : ["\(assignment.workspace).guest"]
                    }
            )).sorted(),
            newGrantIDs: [],
            oldGrantIDs: Array(Set(existingEntries.compactMap(\.grantID))),
            phase: .prepared,
            updatedAt: now()
        )
        var preserveLocalState = false
        do {
            // Record the prepared transaction before creating any remote grant.
            // Recovery can then revoke grants created before a process crash.
            try persistJournal(journal)
            // Create and validate every remote grant before changing local
            // credentials. A failed assignment therefore cannot leave a
            // partially committed workspace set behind.
            for assignment in assignments {
                let repositories = try await repositories(
                    sessionID: sessionID,
                    installationID: assignment.installationID
                )
                let allowed = Dictionary(uniqueKeysWithValues: repositories.map { ($0.id, $0) })
                guard assignment.repositoryIDs.allSatisfy({
                    guard let repository = allowed[$0] else { return false }
                    return repository.owner.login.caseInsensitiveCompare(assignment.owner) == .orderedSame
                }),
                let verification = repositories.first(where: {
                    $0.fullName.caseInsensitiveCompare(assignment.verificationRepository) == .orderedSame &&
                        $0.owner.login.caseInsensitiveCompare(assignment.owner) == .orderedSame
                }),
                assignment.repositoryIDs.contains(verification.id) else {
                    throw GitHubAuthorizationError.repositoryNotAllowed
                }
                let names = assignment.repositoryIDs.compactMap { allowed[$0]?.fullName }
                guard names.count == assignment.repositoryIDs.count else {
                    throw GitHubAuthorizationError.repositoryNotAllowed
                }

                let guest = try await createGrant(
                    assignment: assignment,
                    role: .guest,
                    accessMode: "read-only",
                    repositoryNames: names
                )
                createdGrants.append((assignment.workspace, .guest, guest))
                journal.newGrantIDs.append(guest.id)
                journal.updatedAt = now()
                try persistJournal(journal)
                plannedCommits.append((
                    assignment,
                    .guest,
                    guest,
                    verification.fullName
                ))

                if assignment.accessMode == "read-write" {
                    let host = try await createGrant(
                        assignment: assignment,
                        role: .host,
                        accessMode: "host-write",
                        repositoryNames: names
                    )
                    createdGrants.append((assignment.workspace, .host, host))
                    journal.newGrantIDs.append(host.id)
                    journal.updatedAt = now()
                    try persistJournal(journal)
                    plannedCommits.append((
                        assignment,
                        .host,
                        host,
                        verification.fullName
                    ))
                }
            }


            for plan in plannedCommits {
                committed.append((plan.assignment.workspace, plan.role))
                try await commit(
                    plan.grant,
                    workspace: plan.assignment.workspace,
                    role: plan.role,
                    assignment: plan.assignment,
                    verificationRepository: plan.verificationRepository
                )
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
                    for created in createdGrants {
                        try? await broker.updateRecoveryState(
                            workspace: created.workspace,
                            role: created.role,
                            state: .quarantined,
                            quarantined: true
                        )
                    }
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
                    try? await broker.updateRecoveryState(
                        workspace: entry.workspace,
                        role: entry.role,
                        state: .quarantined,
                        quarantined: true
                    )
                }
            }
            if localCleanupFailed {
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
            return result
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
                workspaceKeys: journal.workspaceKeys
            )
            pending.removeValue(forKey: sessionID)
            if rollbackSucceeded {
                try? removeJournal()
            } else {
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
                workspaceKeys: journal.workspaceKeys
            )
            pending.removeValue(forKey: sessionID)
            if rollbackSucceeded {
                try? removeJournal()
            } else {
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
                workspaceKeys: journal.workspaceKeys
            )
            pending.removeValue(forKey: sessionID)
            if rollbackSucceeded {
                try? removeJournal()
            } else {
                throw GitHubAuthorizationError.revocationFailed
            }
            if let connectError = error as? MSWConnectError {
                switch connectError {
                case .sessionExpired:
                    throw GitHubAuthorizationError.authorizationSessionExpired
                case .transportUnavailable, .httpStatus, .rateLimited:
                    throw GitHubAuthorizationError.serviceUnavailable
                default:
                    break
                }
            }
            throw GitHubAuthorizationError.credentialCommitFailed
        }
    }

    func commitAuthorization(
        sessionID: UUID,
        assignment: GitHubWorkspaceAssignment
    ) async throws -> [WorkspaceCredentialMetadata] {
        try await commitAssignments(sessionID: sessionID, assignments: [assignment])
    }

    func metadata() async -> [WorkspaceCredentialMetadata] {
        await broker.allMetadata()
    }

    func connectedAccount() async -> GitHubAccount? {
        if let current = await connect.currentSession() {
            return current.account
        }
        do {
            return try await connect.restoreSession()?.account
        } catch {
            return nil
        }
    }

    func installationURL() async -> URL {
        connect.configuration.installationURL
    }

    func removeWorkspace(_ workspace: String) async throws {
        let entries = await broker.allMetadata().filter { $0.workspace == workspace }
        do {
            // Remove the VM-held secret before revoking its service grant. If
            // local removal cannot be proven, keep the grant usable and
            // quarantine instead of creating an unrevocable local secret.
            if let mswClient, !entries.isEmpty {
                _ = try await mswClient.unbindGitHubCredentials(workspace: workspace)
            }
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
                case .installationRemoved:
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
        let entries = await broker.allMetadata()
        do {
            let workspaces = Set(entries.map(\.workspace))
            if let mswClient {
                for workspace in workspaces {
                    _ = try await mswClient.unbindGitHubCredentials(workspace: workspace)
                }
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
                case .installationRemoved:
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

    func cancelAuthorization(sessionID: UUID) {
        pending.removeValue(forKey: sessionID)
    }

    private func createGrant(
        assignment: GitHubWorkspaceAssignment,
        role: CredentialRole,
        accessMode: String,
        repositoryNames: [String]
    ) async throws -> MSWConnectGrant {
        let request = MSWConnectGrantAssignment(
            workspace: assignment.workspace,
            role: role,
            owner: assignment.owner,
            installationID: assignment.installationID,
            repositoryIDs: assignment.repositoryIDs,
            repositoryNames: repositoryNames,
            accessMode: accessMode,
            verificationRepository: assignment.verificationRepository
        )
        do {
            return try await connect.createGrant(request)
        } catch MSWConnectError.scopeMismatch {
            throw GitHubAuthorizationError.scopeMismatch
        } catch MSWConnectError.sessionExpired {
            throw GitHubAuthorizationError.authorizationSessionExpired
        } catch MSWConnectError.installationUnavailable, MSWConnectError.accountBoundaryViolation {
            throw GitHubAuthorizationError.repositoryNotAllowed
        } catch MSWConnectError.transportUnavailable, MSWConnectError.httpStatus {
            throw GitHubAuthorizationError.serviceUnavailable
        }
    }

    private func commit(
        _ grant: MSWConnectGrant,
        workspace: String,
        role: CredentialRole,
        assignment: GitHubWorkspaceAssignment,
        verificationRepository: String
    ) async throws {
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
                owner: assignment.owner,
                repositoryIDs: grant.repositoryIDs,
                repositoryNames: grant.repositoryNames,
                scopeDigest: grant.scopeDigest
            )
            stored = true
            if let mswClient {
                _ = try await mswClient.bindGitHubCredentials(
                    workspace: workspace,
                    accessMode: accessMode,
                    verificationRepository: verificationRepository
                )
                try await broker.markBound(workspace: workspace, role: role)
            }
        } catch {
            if stored {
                try? await broker.quarantine(workspace: workspace, role: role)
            }
            throw error
        }
    }

    private func rollback(
        createdGrants: [(workspace: String, role: CredentialRole, grant: MSWConnectGrant)],
        committed: [(workspace: String, role: CredentialRole)],
        previous: [String: PreviousCredential],
        workspaceKeys: [String]
    ) async -> Bool {
        var succeeded = true
        let workspaces = Set(workspaceKeys.compactMap { $0.split(separator: ".").first.map(String.init) })

        // Remove the newly delivered VM secret while the newly stored guest
        // token is still available. Rebinding an old assignment happens only
        // after every rollback step has succeeded.
        if let mswClient {
            for workspace in workspaces {
                do {
                    _ = try await mswClient.unbindGitHubCredentials(workspace: workspace)
                } catch {
                    succeeded = false
                }
            }
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
            } catch {
                succeeded = false
            }
        }

        if succeeded, let mswClient {
            for workspace in workspaces {
                let guestKey = "\(workspace).guest"
                if let snapshot = previous[guestKey],
                   let bundle = snapshot.bundle,
                   !bundle.metadata.needsRestart {
                    do {
                        _ = try await mswClient.bindGitHubCredentials(
                            workspace: workspace,
                            accessMode: "read-only",
                            verificationRepository: bundle.metadata.verificationRepository ?? ""
                        )
                        try await broker.markBound(workspace: workspace, role: .guest)
                    } catch {
                        succeeded = false
                    }
                }
                let hostKey = "\(workspace).host"
                if let snapshot = previous[hostKey],
                   let bundle = snapshot.bundle,
                   !bundle.metadata.needsRestart {
                    do {
                        _ = try await mswClient.bindGitHubCredentials(
                            workspace: workspace,
                            accessMode: "host-write",
                            verificationRepository: bundle.metadata.verificationRepository ?? ""
                        )
                        try await broker.markBound(workspace: workspace, role: .host)
                    } catch {
                        succeeded = false
                    }
                }
            }
        }
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

    private func revokeGrant(_ grantID: UUID) async throws {
        do {
            _ = try await connect.revokeGrant(grantID: grantID)
        } catch MSWConnectError.grantNotFound, MSWConnectError.httpStatus(404) {
            // DELETE is intentionally idempotent for transaction recovery.
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
                    let bundle = try await broker.load(workspace: entry.workspace, role: entry.role)
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
                    throw GitHubAuthorizationError.serviceUnavailable
                }
            }
            let expectedGrantIDs = Set(journal.newGrantIDs)
            let presentGrantIDs = Set(
                (await broker.allMetadata())
                    .filter { journal.workspaceKeys.contains($0.id) }
                    .compactMap(\.grantID)
            )
            if !expectedGrantIDs.isSubset(of: presentGrantIDs) {
                // A crash can leave a local commit only partially written.
                // Revoke every replacement grant before quarantining the
                // affected workspace records; otherwise a remote grant can
                // outlive the local metadata that proves its scope.
                for key in journal.workspaceKeys {
                    let components = key.split(separator: ".")
                    guard components.count == 2,
                          let role = CredentialRole(rawValue: String(components[1])) else { continue }
                    try? await broker.quarantine(workspace: String(components[0]), role: role)
                }
                journal.phase = .rollingBack
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
                        throw GitHubAuthorizationError.serviceUnavailable
                    }
                }
                throw GitHubAuthorizationError.revocationFailed
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
        case .prepared, .rollingBack:
            for key in journal.workspaceKeys {
                let components = key.split(separator: ".")
                guard components.count == 2,
                      let role = CredentialRole(rawValue: String(components[1])) else { continue }
                try? await broker.quarantine(workspace: String(components[0]), role: role)
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
    private static func isValidAssignment(_ assignment: GitHubWorkspaceAssignment) -> Bool {
        let names = assignment.repositoryNames.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return WorkspaceID.isValid(assignment.workspace) &&
            isSafeIdentifier(assignment.owner) &&
            assignment.installationID > 0 &&
            !assignment.repositoryIDs.isEmpty &&
            assignment.repositoryIDs.count == Set(assignment.repositoryIDs).count &&
            assignment.repositoryIDs.count == names.count &&
            assignment.repositoryIDs.allSatisfy({ $0 > 0 }) &&
            names.count == Set(names).count &&
            names.allSatisfy(isSafeRepositoryName) &&
            names.contains(assignment.verificationRepository.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) &&
            (assignment.accessMode == "read-only" || assignment.accessMode == "read-write")
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
