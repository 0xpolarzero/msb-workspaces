import Foundation

struct GitHubAccount: Codable, Sendable, Equatable {
    let login: String
    let id: Int
    let name: String?
    let email: String?
}

struct GitHubInstallation: Codable, Sendable, Equatable, Identifiable {
    let id: Int
    let account: GitHubInstallationAccount
    let repositorySelection: String?

    var displayName: String { account.login }
}

struct GitHubInstallationAccount: Codable, Sendable, Equatable {
    let login: String
    let id: Int
    let type: String?
}

struct GitHubRepository: Codable, Sendable, Equatable, Identifiable {
    let id: Int
    let fullName: String
    let name: String
    let owner: GitHubInstallationAccount
    let `private`: Bool
    let defaultBranch: String?

    enum CodingKeys: String, CodingKey {
        case id
        case fullName = "full_name"
        case name
        case owner
        case `private`
        case defaultBranch = "default_branch"
    }
}

enum GitHubAPIError: Error, LocalizedError, Sendable, Equatable {
    case unauthorized
    case forbidden
    case notFound
    case rateLimited
    case httpStatus(Int)
    case invalidResponse
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "GitHub authorization has expired or is invalid."
        case .forbidden: return "GitHub denied access to this resource."
        case .notFound: return "GitHub could not find the requested resource."
        case .rateLimited: return "GitHub rate-limited this request. Try again later."
        case .httpStatus(let status): return "GitHub returned HTTP status \(status)."
        case .invalidResponse: return "GitHub returned an invalid response."
        case .malformedResponse: return "GitHub returned an unexpected response."
        }
    }
}

actor GitHubAPIClient {
    private let baseURL: URL
    private let session: URLSession
    private var accessToken: String?

    init(
        accessToken: String? = nil,
        baseURL: URL = URL(string: "https://api.github.com")!,
        session: URLSession = .shared
    ) {
        self.accessToken = accessToken
        self.baseURL = baseURL
        self.session = session
    }

    func setAccessToken(_ token: String?) { accessToken = token }

    func currentUser() async throws -> GitHubAccount {
        try await request(path: "/user")
    }

    func installations() async throws -> [GitHubInstallation] {
        struct Response: Decodable { let installations: [GitHubInstallation] }
        let response: Response = try await request(path: "/user/installations")
        return response.installations
    }

    func repositories(installationID: Int) async throws -> [GitHubRepository] {
        struct Response: Decodable { let repositories: [GitHubRepository] }
        let response: Response = try await request(path: "/user/installations/\(installationID)/repositories")
        return response.repositories
    }

    func repository(owner: String, name: String) async throws -> GitHubRepository {
        guard Self.isSafePathComponent(owner), Self.isSafePathComponent(name) else {
            throw GitHubAPIError.invalidResponse
        }
        return try await request(path: "/repos/\(owner)/\(name)")
    }

    private func request<Value: Decodable>(path: String) async throws -> Value {
        var request = URLRequest(url: baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let accessToken { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw GitHubAPIError.invalidResponse }
        switch httpResponse.statusCode {
        case 200..<300: break
        case 401: throw GitHubAPIError.unauthorized
        case 403: throw httpResponse.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" ? GitHubAPIError.rateLimited : GitHubAPIError.forbidden
        case 404: throw GitHubAPIError.notFound
        case 429: throw GitHubAPIError.rateLimited
        default: throw GitHubAPIError.httpStatus(httpResponse.statusCode)
        }
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw GitHubAPIError.malformedResponse
        }
    }

    private static func isSafePathComponent(_ value: String) -> Bool {
        !value.isEmpty && value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
    }
}
