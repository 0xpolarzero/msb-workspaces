import Foundation

struct GitHubTokenPair: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let accessToken: String
    let refreshToken: String
    let accessExpiresAt: Date
    let refreshExpiresAt: Date
    let generation: Int

    init(
        schemaVersion: Int = 2,
        accessToken: String,
        refreshToken: String,
        accessExpiresAt: Date,
        refreshExpiresAt: Date,
        generation: Int
    ) {
        self.schemaVersion = schemaVersion
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accessExpiresAt = accessExpiresAt
        self.refreshExpiresAt = refreshExpiresAt
        self.generation = generation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        accessToken = try container.decode(String.self, forKey: .accessToken)
        refreshToken = try container.decode(String.self, forKey: .refreshToken)
        accessExpiresAt = try container.decode(Date.self, forKey: .accessExpiresAt)
        refreshExpiresAt = try container.decode(Date.self, forKey: .refreshExpiresAt)
        generation = try container.decodeIfPresent(Int.self, forKey: .generation) ?? 0
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, accessToken, refreshToken, accessExpiresAt, refreshExpiresAt, generation
    }

    var isAccessExpired: Bool { accessExpiresAt <= Date() }
    var isRefreshExpired: Bool { refreshExpiresAt <= Date() }
    var isValid: Bool {
        schemaVersion == 2 &&
            !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            accessExpiresAt < refreshExpiresAt &&
            generation > 0
    }
}

struct GitHubDeviceSession: Sendable, Equatable {
    let deviceCode: String
    let userCode: String
    let verificationURI: URL
    let expiresAt: Date
    let interval: Int
}

enum GitHubDeviceFlowEvent: Sendable, Equatable {
    case deviceCodeIssued(userCode: String, verificationURI: URL, expiresAt: Date)
    case waiting(interval: Int)
    case slowDown(interval: Int)
    case authorized
}

enum GitHubDeviceFlowError: Error, LocalizedError, Sendable, Equatable {
    case invalidResponse
    case httpStatus(Int)
    case authorizationPending
    case slowDown
    case expiredToken
    case accessDenied
    case deviceFlowDisabled
    case malformedTokenResponse
    case clientIDMissing
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "GitHub returned an invalid authorization response."
        case .httpStatus(let status): return "GitHub authorization failed with HTTP status \(status)."
        case .authorizationPending: return "GitHub authorization is still pending."
        case .slowDown: return "GitHub requested a slower authorization poll."
        case .expiredToken: return "The GitHub device code expired. Start authorization again."
        case .accessDenied: return "GitHub authorization was denied."
        case .deviceFlowDisabled: return "Device Flow is disabled for this GitHub App."
        case .malformedTokenResponse: return "GitHub returned an incomplete token response."
        case .clientIDMissing: return "The GitHub App client ID is not configured for this credential."
        case .cancelled: return "GitHub authorization was cancelled."
        }
    }
}

actor GitHubDeviceFlow {
    struct Configuration: Sendable {
        let deviceCodeURL: URL
        let accessTokenURL: URL
        let clientID: String
        let scope: String?

        init(
            deviceCodeURL: URL = URL(string: "https://github.com/login/device/code")!,
            accessTokenURL: URL = URL(string: "https://github.com/login/oauth/access_token")!,
            clientID: String,
            scope: String? = nil
        ) {
            self.deviceCodeURL = deviceCodeURL
            self.accessTokenURL = accessTokenURL
            self.clientID = clientID
            self.scope = scope
        }
    }

    private let configuration: Configuration
    private let session: URLSession
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void

    init(
        configuration: Configuration,
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.configuration = configuration
        self.session = session
        self.now = now
        self.sleep = sleep
    }

    func start() async throws -> GitHubDeviceSession {
        guard !configuration.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GitHubDeviceFlowError.clientIDMissing
        }
        var fields = ["client_id": configuration.clientID]
        if let scope = configuration.scope { fields["scope"] = scope }
        let (data, response) = try await post(configuration.deviceCodeURL, fields: fields)
        guard response.statusCode == 200 else { throw GitHubDeviceFlowError.httpStatus(response.statusCode) }
        let payload: DeviceCodeResponse
        do {
            payload = try JSONDecoder().decode(DeviceCodeResponse.self, from: data)
        } catch {
            throw GitHubDeviceFlowError.invalidResponse
        }
        guard let deviceCode = payload.deviceCode,
              !deviceCode.isEmpty,
              let userCode = payload.userCode,
              !userCode.isEmpty,
              let verificationURI = URL(string: payload.verificationURI ?? ""),
              verificationURI.scheme?.lowercased() == "https",
              let host = verificationURI.host?.lowercased(),
              host == "github.com" || host == "www.github.com",
              let expiresIn = payload.expiresIn,
              expiresIn > 0 else {
            if payload.error == "device_flow_disabled" { throw GitHubDeviceFlowError.deviceFlowDisabled }
            throw GitHubDeviceFlowError.invalidResponse
        }
        return GitHubDeviceSession(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURI: verificationURI,
            expiresAt: now().addingTimeInterval(TimeInterval(expiresIn)),
            interval: max(5, payload.interval ?? 5)
        )
    }

    func poll(
        session: GitHubDeviceSession,
        onEvent: (@Sendable (GitHubDeviceFlowEvent) -> Void)? = nil
    ) async throws -> GitHubTokenPair {
        var interval = session.interval
        while now() < session.expiresAt {
            do {
                try Task.checkCancellation()
                onEvent?(.waiting(interval: interval))
                try await sleep(.seconds(interval))
            } catch is CancellationError {
                throw GitHubDeviceFlowError.cancelled
            }
            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await post(configuration.accessTokenURL, fields: [
                    "client_id": configuration.clientID,
                    "device_code": session.deviceCode,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
                ])
            } catch is CancellationError {
                throw GitHubDeviceFlowError.cancelled
            } catch let error as URLError where error.code == .cancelled {
                throw GitHubDeviceFlowError.cancelled
            }
            guard response.statusCode == 200 else { throw GitHubDeviceFlowError.httpStatus(response.statusCode) }
            let payload: TokenResponse
            do {
                payload = try JSONDecoder().decode(TokenResponse.self, from: data)
            } catch {
                throw GitHubDeviceFlowError.invalidResponse
            }
            if let accessToken = payload.accessToken,
               !accessToken.isEmpty,
               let refreshToken = payload.refreshToken,
               !refreshToken.isEmpty,
               let expiresIn = payload.expiresIn,
               expiresIn > 0,
               let refreshExpiresIn = payload.refreshTokenExpiresIn,
               refreshExpiresIn > 0 {
                onEvent?(.authorized)
                return GitHubTokenPair(
                    accessToken: accessToken,
                    refreshToken: refreshToken,
                    accessExpiresAt: now().addingTimeInterval(TimeInterval(expiresIn)),
                    refreshExpiresAt: now().addingTimeInterval(TimeInterval(refreshExpiresIn)),
                    generation: 1
                )
            }
            switch payload.error {
            case "authorization_pending": continue
            case "slow_down":
                interval += 5
                onEvent?(.slowDown(interval: interval))
            case "expired_token": throw GitHubDeviceFlowError.expiredToken
            case "access_denied": throw GitHubDeviceFlowError.accessDenied
            case "device_flow_disabled": throw GitHubDeviceFlowError.deviceFlowDisabled
            default: throw GitHubDeviceFlowError.malformedTokenResponse
            }
        }
        throw GitHubDeviceFlowError.expiredToken
    }

    private func post(_ url: URL, fields: [String: String]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = fields
            .sorted(by: { $0.key < $1.key })
            .map { "\(formEncode($0.key))=\(formEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw GitHubDeviceFlowError.invalidResponse }
        return (data, httpResponse)
    }

    private func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private struct DeviceCodeResponse: Decodable {
        let deviceCode: String?
        let userCode: String?
        let verificationURI: String?
        let expiresIn: Int?
        let interval: Int?
        let error: String?

        enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code"
            case userCode = "user_code"
            case verificationURI = "verification_uri"
            case expiresIn = "expires_in"
            case interval
            case error
        }
    }

    private struct TokenResponse: Decodable {
        let accessToken: String?
        let refreshToken: String?
        let expiresIn: Int?
        let refreshTokenExpiresIn: Int?
        let error: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case refreshTokenExpiresIn = "refresh_token_expires_in"
            case error
        }
    }
}
