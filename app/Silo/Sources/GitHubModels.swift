import Foundation

struct GitHubAccount: Codable, Sendable, Equatable {
    let login: String
    let id: Int
    let name: String?
    let email: String?
}

struct GitHubOwner: Codable, Sendable, Equatable, Identifiable {
    let id: Int
    let account: GitHubOwnerAccount

    var displayName: String { account.login }
}

struct GitHubOwnerAccount: Codable, Sendable, Equatable {
    let login: String
    let id: Int
    let type: String?
}

struct GitHubRepository: Codable, Sendable, Equatable, Identifiable {
    let id: Int
    let fullName: String
    let name: String
    let owner: GitHubOwnerAccount
    let `private`: Bool
    let defaultBranch: String?
    var canPush: Bool? = nil
    var inPolicy: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case fullName = "full_name"
        case name
        case owner
        case `private`
        case defaultBranch = "default_branch"
        case canPush = "can_push"
        case inPolicy = "in_policy"
    }

    func effectiveMode(_ requested: GitHubRepositoryAccessMode) -> GitHubRepositoryAccessMode {
        canPush == false ? .readOnly : requested
    }
}

enum GitHubRepositoryAccessMode: String, Codable, Sendable, CaseIterable, Equatable {
    case readOnly = "read-only"
    case readWrite = "read-write"

    var label: String {
        switch self {
        case .readOnly: "Pushes off"
        case .readWrite: "Pushes on"
        }
    }
}

struct GitHubRepositoryPolicy: Codable, Sendable, Equatable, Identifiable {
    let workspace: String
    let repositoryID: Int
    let fullName: String
    let ownerID: Int
    let ownerLogin: String
    let ownerType: String?
    let mode: GitHubRepositoryAccessMode

    var id: String { "\(workspace).\(ownerID).\(repositoryID)" }

    init(workspace: String, repositoryID: Int, fullName: String, ownerID: Int,
         ownerLogin: String, ownerType: String?,
         mode: GitHubRepositoryAccessMode = .readOnly) {
        self.workspace = workspace
        self.repositoryID = repositoryID
        self.fullName = fullName
        self.ownerID = ownerID
        self.ownerLogin = ownerLogin
        self.ownerType = ownerType
        self.mode = mode
    }
}

struct GitHubWorkspacePolicy: Codable, Sendable, Equatable, Identifiable {
    let workspace: String
    let repositories: [GitHubRepositoryPolicy]
    var id: String { workspace }
}
