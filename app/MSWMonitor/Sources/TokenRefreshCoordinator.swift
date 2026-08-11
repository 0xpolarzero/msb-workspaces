import Foundation

enum TokenRefreshCoordinatorError: Error, LocalizedError, Sendable, Equatable {
    case inProgress
    case missingGrant
    case serviceUnavailable
    case reauthorizationRequired

    var errorDescription: String? {
        switch self {
        case .inProgress:
            return "A GitHub installation grant refresh is already in progress; try again shortly."
        case .missingGrant:
            return "The workspace has no renewable GitHub installation grant. Reauthorize it."
        case .serviceUnavailable:
            return "MSW Connect could not renew the workspace grant. Retry when the service is available; the previous grant remains blocked until it can be verified."
        case .reauthorizationRequired:
            return "The GitHub installation grant was revoked or expired. Reauthorize this workspace."
        }
    }
}

actor TokenRefreshCoordinator {
    private let broker: CredentialBroker
    private let connect: MSWConnectClient
    private var refreshing: Set<String> = []

    init(
        broker: CredentialBroker,
        connect: MSWConnectClient = MSWConnectClient()
    ) {
        self.broker = broker
        self.connect = connect
    }

    func refresh(workspace: String, role: CredentialRole = .guest) async throws -> ScopedInstallationCredential {
        let lockKey = "\(workspace).\(role.rawValue)"
        guard refreshing.insert(lockKey).inserted else {
            throw TokenRefreshCoordinatorError.inProgress
        }
        defer { refreshing.remove(lockKey) }

        guard let metadata = try await broker.metadata(for: workspace, role: role),
              let grantID = metadata.grantID,
              metadata.provider == "github-app-installation",
              metadata.recoveryState == .ready || metadata.recoveryState == .serviceUnavailable,
              !metadata.quarantined else {
            throw TokenRefreshCoordinatorError.missingGrant
        }

        do {
            guard let expectedAccountLogin = metadata.accountLogin,
                  let expectedOwner = metadata.owner,
                  let expectedInstallationID = metadata.installationID,
                  let expectedVerificationRepository = metadata.verificationRepository else {
                throw TokenRefreshCoordinatorError.reauthorizationRequired
            }
            let expectedScope = MSWConnectGrantAssignment(
                workspace: workspace,
                role: role,
                owner: expectedOwner,
                installationID: expectedInstallationID,
                repositoryIDs: metadata.repositoryIDs,
                repositoryNames: metadata.repositoryNames,
                accessMode: metadata.accessMode,
                verificationRepository: expectedVerificationRepository
            )
            let grant = try await connect.renewGrant(
                grantID: grantID,
                expectedScope: expectedScope
            )
            guard grant.workspace == workspace,
                  grant.role == role,
                  grant.id == grantID,
                  grant.accountLogin.caseInsensitiveCompare(expectedAccountLogin) == .orderedSame,
                  grant.owner.caseInsensitiveCompare(expectedOwner) == .orderedSame,
                  grant.installationID == expectedInstallationID,
                  grant.accessMode == metadata.accessMode,
                  Self.normalizeRepositoryName(grant.verificationRepository) ==
                    Self.normalizeRepositoryName(expectedVerificationRepository),
                  grant.repositoryIDs.count == metadata.repositoryIDs.count,
                  grant.repositoryIDs.count == Set(grant.repositoryIDs).count,
                  Set(grant.repositoryIDs) == Set(metadata.repositoryIDs),
                  grant.repositoryNames.count == metadata.repositoryNames.count,
                  Set(grant.repositoryNames.map(Self.normalizeRepositoryName)) ==
                    Set(metadata.repositoryNames.map(Self.normalizeRepositoryName)) else {
                try? await broker.updateRecoveryState(
                    workspace: workspace,
                    role: role,
                    state: .revoked,
                    quarantined: true
                )
                throw TokenRefreshCoordinatorError.reauthorizationRequired
            }
            try await broker.updateScopedCredential(grant.credential, workspace: workspace, role: role)
            return grant.credential
        } catch let error as TokenRefreshCoordinatorError {
            throw error
        } catch MSWConnectError.sessionExpired,
                MSWConnectError.grantNotFound,
                MSWConnectError.grantRevoked,
                MSWConnectError.installationRemoved,
                MSWConnectError.scopeMismatch,
                MSWConnectError.scopeAttestationMissing,
                MSWConnectError.scopeAttestationInvalid,
                MSWConnectError.malformedResponse {
            try? await broker.updateRecoveryState(
                workspace: workspace,
                role: role,
                state: .revoked,
                quarantined: true
            )
            throw TokenRefreshCoordinatorError.reauthorizationRequired
        } catch MSWConnectError.transportUnavailable,
                MSWConnectError.httpStatus,
                MSWConnectError.rateLimited,
                MSWConnectError.sessionCleanupFailed {
            try? await broker.updateRecoveryState(
                workspace: workspace,
                role: role,
                state: .serviceUnavailable,
                quarantined: false
            )
            throw TokenRefreshCoordinatorError.serviceUnavailable
        } catch {
            try? await broker.updateRecoveryState(
                workspace: workspace,
                role: role,
                state: .serviceUnavailable,
                quarantined: false
            )
            throw TokenRefreshCoordinatorError.serviceUnavailable
        }
    }

    func isRefreshing(workspace: String, role: CredentialRole = .guest) -> Bool {
        refreshing.contains("\(workspace).\(role.rawValue)")
    }

    private static func normalizeRepositoryName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
