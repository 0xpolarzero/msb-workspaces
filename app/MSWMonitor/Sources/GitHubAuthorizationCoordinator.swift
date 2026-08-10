import Foundation

struct GitHubAuthorizationSelection: Sendable, Equatable {
    let owner: String
    let installationID: Int
    let repositoryIDs: [Int]
    let verificationRepository: String?
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

    var errorDescription: String? {
        switch self {
        case .invalidSelection: return "The GitHub owner or repository selection is invalid."
        case .invalidAppConfiguration: return "Each workspace role must use its own GitHub App client ID. Review the six public client IDs in Settings."
        case .guestAuthorizationRequired: return "Authorize guest read access for this workspace before authorizing host write access."
        case .authorizationSessionExpired: return "The GitHub authorization selection expired. Start Device Flow again."
        case .ownerNotInstalled: return "The selected GitHub owner has not installed the required GitHub App."
        case .repositoryNotAllowed: return "One or more selected repositories are outside the GitHub App installation scope."
        case .accountLookupFailed: return "GitHub authorization succeeded, but the account could not be verified."
        case .credentialCommitFailed: return "GitHub authorization could not be committed to the credential broker."
        }
    }
}

actor GitHubAuthorizationCoordinator {
    private struct PendingAuthorization: Sendable {
        let workspace: String
        let role: CredentialRole
        let clientID: String
        let tokens: GitHubTokenPair
        let account: GitHubAccount
        let installations: [GitHubInstallation]
        let expiresAt: Date
    }

    private let broker: CredentialBroker
    private let api: GitHubAPIClient
    private let mswClient: MSWClient?
    private var pending: [UUID: PendingAuthorization] = [:]

    init(
        broker: CredentialBroker,
        api: GitHubAPIClient = GitHubAPIClient(),
        mswClient: MSWClient? = nil
    ) {
        self.broker = broker
        self.api = api
        self.mswClient = mswClient
    }

    /// Completes Device Flow and returns only nonsecret discovery data. The
    /// access/refresh pair remains actor-isolated until the user commits an
    /// installation and repository selection.
    func beginAuthorization(
        workspace: String,
        role: CredentialRole,
        deviceConfiguration: GitHubDeviceFlow.Configuration,
        onEvent: (@Sendable (GitHubDeviceFlowEvent) -> Void)? = nil
    ) async throws -> GitHubAuthorizationDiscovery {
        guard WorkspaceID.isValid(workspace),
              !deviceConfiguration.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GitHubAuthorizationError.invalidSelection
        }
        if role == .host {
            do {
                _ = try await broker.load(workspace: workspace, role: .guest)
            } catch {
                throw GitHubAuthorizationError.guestAuthorizationRequired
            }
        }
        let profiles = await broker.allMetadata()
        if profiles.contains(where: {
            $0.appClientID == deviceConfiguration.clientID &&
                !($0.workspace == workspace && $0.role == role)
        }) {
            throw GitHubAuthorizationError.invalidAppConfiguration
        }

        let flow = GitHubDeviceFlow(configuration: deviceConfiguration)
        let deviceSession = try await flow.start()
        onEvent?(.deviceCodeIssued(
            userCode: deviceSession.userCode,
            verificationURI: deviceSession.verificationURI,
            expiresAt: deviceSession.expiresAt
        ))
        let tokens = try await flow.poll(session: deviceSession, onEvent: onEvent)
        await api.setAccessToken(tokens.accessToken)
        let account = try await api.currentUser()
        let installations = try await api.installations()
        let sessionID = UUID()
        removeExpiredSessions()
        pending[sessionID] = PendingAuthorization(
            workspace: workspace,
            role: role,
            clientID: deviceConfiguration.clientID,
            tokens: tokens,
            account: account,
            installations: installations,
            expiresAt: min(tokens.accessExpiresAt, Date().addingTimeInterval(15 * 60))
        )
        return GitHubAuthorizationDiscovery(
            sessionID: sessionID,
            account: account,
            installations: installations
        )
    }

    func repositories(sessionID: UUID, installationID: Int) async throws -> [GitHubRepository] {
        removeExpiredSessions()
        guard let authorization = pending[sessionID] else {
            throw GitHubAuthorizationError.authorizationSessionExpired
        }
        guard authorization.installations.contains(where: { $0.id == installationID }) else {
            throw GitHubAuthorizationError.ownerNotInstalled
        }
        await api.setAccessToken(authorization.tokens.accessToken)
        return try await api.repositories(installationID: installationID)
    }

    func commitAuthorization(
        sessionID: UUID,
        selection: GitHubAuthorizationSelection
    ) async throws -> WorkspaceCredentialMetadata {
        removeExpiredSessions()
        guard let authorization = pending.removeValue(forKey: sessionID) else {
            throw GitHubAuthorizationError.authorizationSessionExpired
        }
        return try await commit(authorization: authorization, selection: selection)
    }

    func cancelAuthorization(sessionID: UUID) {
        pending.removeValue(forKey: sessionID)
    }

    /// Convenience path retained for callers that already have a selection;
    /// selection is still verified against post-Device-Flow discovery.
    func authorize(
        workspace: String,
        role: CredentialRole,
        deviceConfiguration: GitHubDeviceFlow.Configuration,
        selection: GitHubAuthorizationSelection,
        onEvent: (@Sendable (GitHubDeviceFlowEvent) -> Void)? = nil
    ) async throws -> WorkspaceCredentialMetadata {
        let discovery = try await beginAuthorization(
            workspace: workspace,
            role: role,
            deviceConfiguration: deviceConfiguration,
            onEvent: onEvent
        )
        return try await commitAuthorization(sessionID: discovery.sessionID, selection: selection)
    }

    private func commit(
        authorization: PendingAuthorization,
        selection: GitHubAuthorizationSelection
    ) async throws -> WorkspaceCredentialMetadata {
        let uniqueRepositoryIDs = Set(selection.repositoryIDs)
        guard !selection.owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              selection.installationID > 0,
              !uniqueRepositoryIDs.isEmpty,
              uniqueRepositoryIDs.count == selection.repositoryIDs.count,
              selection.repositoryIDs.allSatisfy({ $0 > 0 }),
              let verificationRepository = selection.verificationRepository,
              !verificationRepository.isEmpty else {
            throw GitHubAuthorizationError.invalidSelection
        }
        guard let installation = authorization.installations.first(where: {
            $0.id == selection.installationID &&
                $0.account.login.caseInsensitiveCompare(selection.owner) == .orderedSame
        }) else {
            throw GitHubAuthorizationError.ownerNotInstalled
        }
        await api.setAccessToken(authorization.tokens.accessToken)
        let repositories = try await api.repositories(installationID: installation.id)
        let repositoriesByID = Dictionary(uniqueKeysWithValues: repositories.map { ($0.id, $0) })
        guard uniqueRepositoryIDs.allSatisfy({ repositoriesByID[$0] != nil }),
              let verification = repositories.first(where: {
                  $0.fullName.caseInsensitiveCompare(verificationRepository) == .orderedSame
              }),
              uniqueRepositoryIDs.contains(verification.id) else {
            throw GitHubAuthorizationError.repositoryNotAllowed
        }

        let accessMode = authorization.role == .host ? "host-write" : "read-only"
        do {
            try await broker.store(
                tokens: authorization.tokens,
                workspace: authorization.workspace,
                accessMode: accessMode,
                verificationRepository: verification.fullName,
                installationID: installation.id,
                role: authorization.role,
                appClientID: authorization.clientID,
                accountLogin: authorization.account.login,
                owner: installation.account.login,
                repositoryIDs: selection.repositoryIDs
            )
            if let mswClient {
                _ = try await mswClient.bindGitHubCredentials(
                    workspace: authorization.workspace,
                    accessMode: accessMode,
                    verificationRepository: verification.fullName
                )
                try await broker.markBound(workspace: authorization.workspace, role: authorization.role)
            }
            try await broker.removeLegacyCredential(
                workspace: authorization.workspace,
                role: authorization.role
            )
            guard let metadata = try await broker.metadata(
                for: authorization.workspace,
                role: authorization.role
            ) else {
                throw GitHubAuthorizationError.credentialCommitFailed
            }
            return metadata
        } catch let error as GitHubAuthorizationError {
            try? await broker.quarantine(workspace: authorization.workspace, role: authorization.role)
            throw error
        } catch {
            try? await broker.quarantine(workspace: authorization.workspace, role: authorization.role)
            throw GitHubAuthorizationError.credentialCommitFailed
        }
    }

    private func removeExpiredSessions() {
        let now = Date()
        pending = pending.filter { $0.value.expiresAt > now }
    }
}
