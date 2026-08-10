import Foundation

enum TokenRefreshCoordinatorError: Error, LocalizedError, Sendable, Equatable {
    case inProgress

    var errorDescription: String? {
        "A GitHub credential refresh is already in progress; try again shortly."
    }
}
actor TokenRefreshCoordinator {
    private let clientID: String?
    private let broker: CredentialBroker
    private let session: URLSession
    private let refreshURL: URL
    private var refreshing: Set<String> = []

    init(
        clientID: String? = nil,
        broker: CredentialBroker,
        session: URLSession = .shared,
        refreshURL: URL = URL(string: "https://github.com/login/oauth/access_token")!
    ) {
        self.clientID = clientID
        self.broker = broker
        self.session = session
        self.refreshURL = refreshURL
    }

    func refresh(workspace: String, role: CredentialRole = .guest) async throws -> GitHubTokenPair {
        let lockKey = "\(workspace).\(role.rawValue)"
        guard refreshing.insert(lockKey).inserted else {
            throw TokenRefreshCoordinatorError.inProgress
        }
        defer { refreshing.remove(lockKey) }
        let bundle = try await broker.load(workspace: workspace, role: role)
        guard !bundle.tokens.isRefreshExpired else {
            try? await broker.quarantine(workspace: workspace, role: role)
            throw GitHubDeviceFlowError.expiredToken
        }
        guard let resolvedClientID = clientID ?? bundle.metadata.appClientID,
              !resolvedClientID.isEmpty else {
            throw GitHubDeviceFlowError.clientIDMissing
        }
        var request = URLRequest(url: refreshURL)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = [
            "client_id": resolvedClientID,
            "grant_type": "refresh_token",
            "refresh_token": bundle.tokens.refreshToken
        ].map { key, value in
            "\(key.formEncoded)=\(value.formEncoded)"
        }.joined(separator: "&").data(using: .utf8)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // Once the refresh request has left the process, a transport
            // failure cannot prove whether GitHub accepted it and invalidated
            // the previous one-time pair. Fail closed and require Device Flow.
            try? await broker.quarantine(workspace: workspace, role: role)
            throw GitHubDeviceFlowError.invalidResponse
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            try? await broker.quarantine(workspace: workspace, role: role)
            throw GitHubDeviceFlowError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            try? await broker.quarantine(workspace: workspace, role: role)
            if httpResponse.statusCode == 400 || httpResponse.statusCode == 401 {
                throw GitHubDeviceFlowError.expiredToken
            }
            throw GitHubDeviceFlowError.httpStatus(httpResponse.statusCode)
        }
        let payload: RefreshResponse
        do {
            payload = try JSONDecoder().decode(RefreshResponse.self, from: data)
        } catch {
            try? await broker.quarantine(workspace: workspace, role: role)
            throw GitHubDeviceFlowError.malformedTokenResponse
        }
        guard let accessToken = payload.accessToken,
              !accessToken.isEmpty,
              let refreshToken = payload.refreshToken,
              !refreshToken.isEmpty,
              let expiresIn = payload.expiresIn,
              expiresIn > 0,
              let refreshExpiresIn = payload.refreshTokenExpiresIn,
              refreshExpiresIn > 0 else {
            try? await broker.quarantine(workspace: workspace, role: role)
            throw GitHubDeviceFlowError.malformedTokenResponse
        }
        let refreshed = GitHubTokenPair(
            accessToken: accessToken,
            refreshToken: refreshToken,
            accessExpiresAt: Date().addingTimeInterval(TimeInterval(expiresIn)),
            refreshExpiresAt: Date().addingTimeInterval(TimeInterval(refreshExpiresIn)),
            generation: bundle.tokens.generation + 1
        )
        do {
            try await broker.store(
                tokens: refreshed,
                workspace: workspace,
                accessMode: bundle.metadata.accessMode,
                verificationRepository: bundle.metadata.verificationRepository,
                installationID: bundle.metadata.installationID,
                role: role,
                appClientID: bundle.metadata.appClientID,
                accountLogin: bundle.metadata.accountLogin,
                owner: bundle.metadata.owner,
                repositoryIDs: bundle.metadata.repositoryIDs
            )
        } catch {
            // GitHub may already have invalidated the old pair. Never claim a
            // rollback; quarantine and require explicit Device Flow reauth.
            try? await broker.quarantine(workspace: workspace, role: role)
            throw error
        }
        return refreshed
    }

    func isRefreshing(workspace: String, role: CredentialRole = .guest) -> Bool {
        refreshing.contains("\(workspace).\(role.rawValue)")
    }

    private struct RefreshResponse: Decodable {
        let accessToken: String?
        let refreshToken: String?
        let expiresIn: Int?
        let refreshTokenExpiresIn: Int?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case refreshTokenExpiresIn = "refresh_token_expires_in"
        }
    }
}

private extension String {
    var formEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
