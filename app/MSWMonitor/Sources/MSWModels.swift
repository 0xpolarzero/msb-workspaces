import Foundation

struct SetupWorkspaceConfiguration: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var cpus: Int
    var maxCPUs: Int
    var memoryGiB: Int
    var maxMemoryGiB: Int
    var workspaceStorageGiB: Int
    var runtimeStorageGiB: Int

    init(
        id: UUID = UUID(),
        name: String,
        cpus: Int,
        maxCPUs: Int,
        memoryGiB: Int,
        maxMemoryGiB: Int,
        workspaceStorageGiB: Int,
        runtimeStorageGiB: Int
    ) {
        self.id = id
        self.name = name
        self.cpus = cpus
        self.maxCPUs = maxCPUs
        self.memoryGiB = memoryGiB
        self.maxMemoryGiB = maxMemoryGiB
        self.workspaceStorageGiB = workspaceStorageGiB
        self.runtimeStorageGiB = runtimeStorageGiB
    }

    static let supportedCPUs = [4, 6, 8, 12]
    static let supportedMemoryGiB = [16, 32, 48]
    static let supportedStorageGiB = [60, 80, 100, 120]

    static var defaults: [Self] {
        [
            Self(
                name: "dev", cpus: 8, maxCPUs: 12, memoryGiB: 32, maxMemoryGiB: 48,
                workspaceStorageGiB: 120, runtimeStorageGiB: 100
            ),
            Self(
                name: "playgrounds", cpus: 4, maxCPUs: 12, memoryGiB: 32, maxMemoryGiB: 48,
                workspaceStorageGiB: 60, runtimeStorageGiB: 60
            ),
            Self(
                name: "personal", cpus: 6, maxCPUs: 12, memoryGiB: 16, maxMemoryGiB: 32,
                workspaceStorageGiB: 100, runtimeStorageGiB: 80
            )
        ]
    }

    static func validationMessage(for configurations: [Self]) -> String? {
        guard !configurations.isEmpty else { return "Add at least one workspace." }
        guard configurations.count <= 64 else { return "Configure no more than 64 workspaces." }
        let names = configurations.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
        if names.contains(where: \.isEmpty) {
            return "Every workspace needs a name."
        }
        if zip(configurations, names).contains(where: { $0.name != $1 }) {
            return "Workspace names cannot begin or end with spaces."
        }
        let normalized = names.map { $0.lowercased() }
        if Set(normalized).count != normalized.count {
            return "Workspace names must be unique."
        }
        if names.contains(where: { name in
            name.range(of: #"^[a-z][a-z0-9-]{0,31}$"#, options: .regularExpression) == nil
        }) {
            return "Workspace names must start with a lowercase letter and contain only lowercase letters, numbers, or hyphens (32 characters maximum)."
        }
        for configuration in configurations {
            guard supportedCPUs.contains(configuration.cpus),
                  supportedCPUs.contains(configuration.maxCPUs),
                  supportedMemoryGiB.contains(configuration.memoryGiB),
                  supportedMemoryGiB.contains(configuration.maxMemoryGiB),
                  supportedStorageGiB.contains(configuration.workspaceStorageGiB),
                  supportedStorageGiB.contains(configuration.runtimeStorageGiB) else {
                return "Choose supported CPU, memory, and storage values."
            }
            if configuration.cpus > configuration.maxCPUs {
                return "A workspace CPU limit cannot exceed its resize ceiling."
            }
            if configuration.memoryGiB > configuration.maxMemoryGiB {
                return "A workspace memory limit cannot exceed its resize ceiling."
            }
        }
        return nil
    }
}

struct MSWBootstrapConfiguration: Codable, Equatable, Sendable {
    private static let rootKeys: Set<String> = ["schemaVersion", "workspaces"]
    private static let workspaceKeys: Set<String> = [
        "name", "cpu", "cpuCeiling", "memoryGiB", "memoryCeilingGiB",
        "workspaceStorageGiB", "runtimeStorageGiB"
    ]

    let schemaVersion: Int
    let workspaces: [Workspace]

    struct Workspace: Codable, Equatable, Sendable {
        let name: String
        let cpu: Int
        let cpuCeiling: Int
        let memoryGiB: Int
        let memoryCeilingGiB: Int
        let workspaceStorageGiB: Int
        let runtimeStorageGiB: Int
    }

    init(_ configurations: [SetupWorkspaceConfiguration]) {
        schemaVersion = 1
        workspaces = configurations.map {
            Workspace(
                name: $0.name,
                cpu: $0.cpus,
                cpuCeiling: $0.maxCPUs,
                memoryGiB: $0.memoryGiB,
                memoryCeilingGiB: $0.maxMemoryGiB,
                workspaceStorageGiB: $0.workspaceStorageGiB,
                runtimeStorageGiB: $0.runtimeStorageGiB
            )
        }
    }

    var setupConfigurations: [SetupWorkspaceConfiguration] {
        workspaces.map {
            SetupWorkspaceConfiguration(
                name: $0.name,
                cpus: $0.cpu,
                maxCPUs: $0.cpuCeiling,
                memoryGiB: $0.memoryGiB,
                maxMemoryGiB: $0.memoryCeilingGiB,
                workspaceStorageGiB: $0.workspaceStorageGiB,
                runtimeStorageGiB: $0.runtimeStorageGiB
            )
        }
    }

    /// Strict external-file decoder. `JSONDecoder` intentionally ignores
    /// unknown keys, which is useful for many app payloads but unsafe for this
    /// versioned configuration boundary: every downstream consumer must agree
    /// on exactly the same fields.
    static func decodeValidated(from data: Data) -> Self? {
        guard data.count <= 256 * 1_024,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == rootKeys,
              let workspaceObjects = root["workspaces"] as? [[String: Any]],
              workspaceObjects.allSatisfy({ Set($0.keys) == workspaceKeys }),
              let decoded = try? JSONDecoder().decode(Self.self, from: data),
              decoded.schemaVersion == 1,
              SetupWorkspaceConfiguration.validationMessage(for: decoded.setupConfigurations) == nil else {
            return nil
        }
        return decoded
    }
}

// MARK: - Machine-readable MSW contract

struct MSWEnvelope<Value: Codable & Sendable>: Codable, Sendable {
    let schemaVersion: Int
    let requestId: String
    let ok: Bool
    let command: String
    let observedAt: Date?
    let result: Value?
    let warnings: [String]
    let error: MSWProtocolError?

    init(
        schemaVersion: Int,
        requestId: String,
        ok: Bool,
        command: String,
        observedAt: Date? = nil,
        result: Value? = nil,
        warnings: [String] = [],
        error: MSWProtocolError? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.requestId = requestId
        self.ok = ok
        self.command = command
        self.observedAt = observedAt
        self.result = result
        self.warnings = warnings
        self.error = error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        requestId = try container.decode(String.self, forKey: .requestId)
        ok = try container.decode(Bool.self, forKey: .ok)
        command = try container.decode(String.self, forKey: .command)
        observedAt = try container.decodeIfPresent(Date.self, forKey: .observedAt)
        result = try container.decodeIfPresent(Value.self, forKey: .result)
        warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
        error = try container.decodeIfPresent(MSWProtocolError.self, forKey: .error)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, requestId, ok, command, observedAt, result, warnings, error
    }
}

struct MSWProtocolError: Codable, Error, LocalizedError, Sendable, Equatable {
    let code: String
    let message: String
    let recovery: String?
    let workspace: String?
    let retryable: Bool

    var errorDescription: String? {
        var description = message
        if let recovery, !recovery.isEmpty {
            description += " \(recovery)"
        }
        description += " (MSW error code: \(code).)"
        return description
    }
}

struct MSWHandshake: Codable, Sendable {
    let protocolVersion: Int
    let mswVersion: String
    let platform: Platform
    let configurationAvailable: Bool
    let runtimeAvailable: Bool
    let capabilities: Capabilities
    let exitCodes: [String: Int]

    struct Platform: Codable, Sendable {
        let os: String
        let architecture: String
    }

    struct Capabilities: Codable, Sendable {
        let jsonState: Bool
        let jsonMetrics: Bool
        let jsonLogs: Bool
        let plans: Bool
        let bootstrapEvents: Bool
        let jq: Bool
        let workspaceCount: Int
    }
}

struct MSWStateResponse: Codable, Sendable {
    let schemaVersion: Int
    let mswVersion: String
    let workspaces: [MSWWorkspaceSnapshot]
}

struct MSWWorkspaceSnapshot: Codable, Identifiable, Sendable {
    let id: String
    let purpose: String
    let lifecycle: MSWLifecycle
    let freshness: MSWFreshness
    let statusObservedAt: Date?
    let metricsObservedAt: Date?
    let githubObservedAt: Date?
    let activityObservedAt: Date?
    let quarantine: MSWQuarantineSnapshot
    let credential: MSWCredentialSnapshot
    let resources: MSWResourceSnapshot
    let network: MSWNetworkSnapshot
    let actionCapabilities: MSWActionCapabilities
    /// Published ports skipped by the workspace proxy because they were
    /// already in use ([] when none). Absent in older CLI output.
    let skippedPorts: [Int]?
    /// Human-readable warning about skipped published ports ("" when none).
    let portWarning: String?

    init(
        id: String,
        purpose: String,
        lifecycle: MSWLifecycle,
        freshness: MSWFreshness,
        quarantine: MSWQuarantineSnapshot,
        credential: MSWCredentialSnapshot,
        resources: MSWResourceSnapshot,
        network: MSWNetworkSnapshot,
        actionCapabilities: MSWActionCapabilities,
        statusObservedAt: Date? = nil,
        metricsObservedAt: Date? = nil,
        githubObservedAt: Date? = nil,
        activityObservedAt: Date? = nil,
        skippedPorts: [Int]? = nil,
        portWarning: String? = nil
    ) {
        self.id = id
        self.purpose = purpose
        self.lifecycle = lifecycle
        self.freshness = freshness
        self.statusObservedAt = statusObservedAt
        self.metricsObservedAt = metricsObservedAt
        self.githubObservedAt = githubObservedAt
        self.activityObservedAt = activityObservedAt
        self.quarantine = quarantine
        self.credential = credential
        self.resources = resources
        self.network = network
        self.actionCapabilities = actionCapabilities
        self.skippedPorts = skippedPorts
        self.portWarning = portWarning
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        purpose = try container.decode(String.self, forKey: .purpose)
        lifecycle = try container.decode(MSWLifecycle.self, forKey: .lifecycle)
        freshness = try container.decode(MSWFreshness.self, forKey: .freshness)
        statusObservedAt = try container.decodeIfPresent(Date.self, forKey: .statusObservedAt)
        metricsObservedAt = try container.decodeIfPresent(Date.self, forKey: .metricsObservedAt)
        githubObservedAt = try container.decodeIfPresent(Date.self, forKey: .githubObservedAt)
        activityObservedAt = try container.decodeIfPresent(Date.self, forKey: .activityObservedAt)
        quarantine = try container.decode(MSWQuarantineSnapshot.self, forKey: .quarantine)
        credential = try container.decode(MSWCredentialSnapshot.self, forKey: .credential)
        resources = try container.decode(MSWResourceSnapshot.self, forKey: .resources)
        network = try container.decode(MSWNetworkSnapshot.self, forKey: .network)
        actionCapabilities = try container.decode(MSWActionCapabilities.self, forKey: .actionCapabilities)
        skippedPorts = try container.decodeIfPresent([Int].self, forKey: .skippedPorts)
        portWarning = try container.decodeIfPresent(String.self, forKey: .portWarning)
    }

    private enum CodingKeys: String, CodingKey {
        case id, purpose, lifecycle, freshness, statusObservedAt, metricsObservedAt
        case githubObservedAt, activityObservedAt, quarantine, credential, resources, network, actionCapabilities
        case skippedPorts, portWarning
    }

    var identity: String { id }
}

enum MSWLifecycle: String, Codable, Sendable {
    case running = "Running"
    case stopped = "Stopped"
    case starting = "Starting"
    case stopping = "Stopping"
    case restarting = "Restarting"
    case exited = "Exited"
    case unavailable = "Unavailable"
    case unknown = "Unknown"
    case quarantined = "Quarantined"

    var isKnown: Bool {
        self != .unknown && self != .unavailable
    }
}

enum MSWFreshness: String, Codable, Sendable {
    case fresh
    case stale
    case unavailable
    case neverObserved = "never-observed"
}

struct MSWQuarantineSnapshot: Codable, Sendable {
    let state: State
    let reason: String?

    enum State: String, Codable, Sendable {
        case clear
        case quarantined
        case unknown
    }
}

struct MSWCredentialSnapshot: Codable, Sendable {
    let state: State
    let accessMode: String
    let verificationRepository: String?
    let accountLogin: String?
    let installationId: String?
    let accessExpiresAt: Date?
    let refreshExpiresAt: Date?
    let needsRestart: Bool

    enum State: String, Codable, Sendable {
        case unconfigured = "Unconfigured"
        case legacy = "Legacy"
        case needsAuthorization = "Needs authorization"
        case serviceUnavailable = "Service unavailable"
        case ready = "Ready"
        case expiring = "Expiring"
        case needsRestart = "Needs restart"
        case readOnly = "Read-only"
        case removalPending = "Removal pending"
        case quarantined = "Quarantined"
    }
}

struct MSWResourceSnapshot: Codable, Sendable {
    let cpus: String
    let maxCpus: String
    let memory: String
    let maxMemory: String
    let rootDisk: String
}

struct MSWNetworkSnapshot: Codable, Sendable {
    let host: String
    let ip: String
}

struct MSWActionCapabilities: Codable, Sendable, Equatable {
    let canStart: Bool
    let canStop: Bool
    let canRestart: Bool
    let canOpenTerminal: Bool
    let canPush: Bool
    let reason: String?
    let recovery: String?

    init(
        canStart: Bool,
        canStop: Bool,
        canRestart: Bool,
        canOpenTerminal: Bool,
        canPush: Bool,
        reason: String? = nil,
        recovery: String? = nil
    ) {
        self.canStart = canStart
        self.canStop = canStop
        self.canRestart = canRestart
        self.canOpenTerminal = canOpenTerminal
        self.canPush = canPush
        self.reason = reason
        self.recovery = recovery
    }
}

struct MSWPortsResponse: Codable, Sendable {
    let workspace: String
    let published: [Port]
    let activeListening: String
    let freshness: MSWFreshness

    struct Port: Codable, Identifiable, Sendable {
        let port: String
        let configured: Bool
        var id: String { port }
    }
}

struct MSWMetricsResponse: Codable, Sendable {
    let workspace: String
    let available: Bool
    let lifecycle: MSWLifecycle
    let freshness: MSWFreshness
    let reason: String?
    let snapshot: JSONValue?
}

struct MSWLogsResponse: Codable, Sendable {
    let workspace: String
    let available: Bool
    let lifecycle: MSWLifecycle
    let freshness: MSWFreshness
    let reason: String?
    let lines: [MSWLogEntry]
}

struct MSWLogEntry: Codable, Sendable {
    let workspace: String
    let message: String
    let safeForDisplay: Bool
}

struct MSWRepositoriesResponse: Codable, Sendable {
    let workspace: String
    let repositories: [MSWRepositorySnapshot]
    let needsStart: Bool
    let freshness: MSWFreshness
    let worktreeStatusIncluded: Bool
    let notice: String?
}

struct MSWDirectoryResponse: Codable, Sendable, Equatable {
    let workspace: String
    let path: String
    let query: String?
    let entries: [Entry]
    let truncated: Bool

    struct Entry: Codable, Sendable, Equatable, Identifiable {
        let name: String
        let path: String
        let kind: String
        let hasChildren: Bool
        let children: [Entry]
        let childrenTruncated: Bool

        init(
            name: String,
            path: String,
            kind: String,
            hasChildren: Bool = false,
            children: [Entry] = [],
            childrenTruncated: Bool = false
        ) {
            self.name = name
            self.path = path
            self.kind = kind
            self.hasChildren = hasChildren
            self.children = children
            self.childrenTruncated = childrenTruncated
        }

        var id: String { path }
    }
}

struct MSWEditorTarget: Codable, Sendable, Equatable {
    let workspace: String
    let path: String
    let host: String

    var isValid: Bool {
        WorkspaceID.isValid(workspace) &&
            host == "\(workspace).msb" &&
            Self.isSafeRelativePath(path)
    }

    var remoteURL: URL? {
        guard isValid else { return nil }
        var components = URLComponents()
        components.scheme = "ssh"
        components.user = "root"
        components.host = host
        components.path = path == "." ? "/workspace" : "/workspace/\(path)"
        return components.url
    }

    var zedRemoteURL: URL? {
        guard isValid else { return nil }
        var components = URLComponents()
        components.scheme = "zed"
        components.host = "ssh"
        components.path = "/root@\(host)" + (path == "." ? "/workspace" : "/workspace/\(path)")
        return components.url
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.count <= 1_024, !path.hasPrefix("/"),
              path.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) else {
            return false
        }
        if path == "." { return true }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }
}

struct MSWRepositorySnapshot: Codable, Identifiable, Sendable {
    let path: String
    let canonicalRemote: String?
    let branch: String?
    let upstreamRef: String?
    let worktreeState: WorktreeState
    let destinationState: DestinationState
    let stagedCount: Int
    let modifiedCount: Int
    let deletedCount: Int
    let untrackedCount: Int
    let aheadCount: Int
    let behindCount: Int
    let localCommit: String?
    let remoteCommit: String?
    let pushability: Pushability
    let needsStart: Bool
    let freshness: MSWFreshness
    let checkedAt: Date?

    var id: String { path }

    enum WorktreeState: String, Codable, Sendable {
        case clean
        case localChanges
        case detached
        case unavailable
    }

    enum DestinationState: String, Codable, Sendable {
        case absent
        case upToDate
        case ahead
        case behind
        case diverged
        case unavailable
    }

    enum Pushability: String, Codable, Sendable {
        case pushable
        case publish
        case blocked
        case unavailable
    }
}

struct MSWGitHubStateResponse: Codable, Sendable {
    let workspaces: [MSWGitHubWorkspaceState]
}

struct MSWGitHubBindResult: Codable, Sendable {
    let workspace: String
    let accessMode: String
    let verificationRepository: String
    let verified: Bool
    let lifecycleRestored: Bool
}
struct MSWGitHubUnbindResult: Codable, Sendable {
    let workspace: String
    let unbound: Bool
}


struct MSWGitHubWorkspaceState: Codable, Identifiable, Sendable {
    let workspace: String
    let provider: String
    let configured: Bool
    let accessMode: String
    let verificationRepository: String?
    let accountLogin: String?
    let installationId: String?
    let accessExpiresAt: Date?
    let refreshExpiresAt: Date?
    let needsRestart: Bool
    let quarantined: Bool
    /// Local-mode only: the ticked repositories for this workspace from the
    /// policy file. Absent in Connect-mode CLI output.
    let repos: [MSWGitHubPolicyRepo]?
    let policyUpdatedAt: Date?
    let hostCredential: String?

    var id: String { workspace }
}

/// A ticked repository as rendered from the local policy file.
struct MSWGitHubPolicyRepo: Codable, Identifiable, Sendable, Equatable {
    let canonical: String
    let mode: GitHubRepositoryAccessMode

    var id: String { canonical }
    var modeLabel: String { mode.label }
}

/// `msw github status --format json` (local mode): top-level mode plus one
/// entry per workspace with policy/capability/shuttle/credential presence.
struct MSWGitHubStatusResponse: Codable, Sendable {
    let mode: String
    let workspaces: [MSWGitHubStatusWorkspace]
}

struct MSWGitHubStatusWorkspace: Codable, Sendable {
    let workspace: String
    let capability: String?
    let repos: [MSWGitHubStatusRepo]?
    let shuttle: String?
    let hostCredential: String?
}

struct MSWGitHubStatusRepo: Codable, Sendable, Equatable {
    let canonical: String
    let mode: String
}

/// Nonsecret host-credential metadata from `msw github auth --json`. Never
/// contains token bytes.
struct MSWGitHubAuthMetadata: Codable, Sendable {
    let provider: String?
    let tokenKind: String?
    let accountLogin: String?
    let verifiedAt: Date?
    let generation: Int?
    let storedAt: Date?
    let repoChecks: [MSWGitHubAuthRepoCheck]?
}

struct MSWGitHubAuthRepoCheck: Codable, Sendable {
    let canonical: String?
    let mode: String?
    let push: Bool?
    let checkedAt: Date?
}

/// `msw app github-policy-apply` request: the FULL desired policy file
/// carried on stdin. Missing workspace keys are treated by the CLI as
/// "clear this workspace", so the app always sends every configured workspace.
struct MSWGitHubPolicyApplyRequest: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let workspaces: [String: GitHubPolicyWorkspace]
}

/// `msw app github-policy-apply` success result. The app marks the operation
/// applied ONLY when `applied`, `provisioned`, and `committed` are all true.
struct MSWGitHubPolicyApplyResult: Codable, Sendable {
    let applied: Bool?
    let provisioned: Bool?
    let committed: Bool?
    let workspaces: [MSWGitHubPolicyApplyWorkspace]?
}

struct MSWGitHubPolicyApplyWorkspace: Codable, Sendable {
    let workspace: String
    let capability: String?
    let repos: [MSWGitHubStatusRepo]?
}

/// Repository discovery entry from `msw github repos --format json`.
struct MSWGitHubDiscoveredRepo: Codable, Sendable, Equatable {
    let canonical: String
    let name: String
    let owner: String
    let `private`: Bool
    let permissions: MSWGitHubRepoPermissions
    let inPolicy: Bool
}

struct MSWGitHubRepoPermissions: Codable, Sendable, Equatable {
    let pull: Bool
    let push: Bool
}

/// Typed raw-CLI error document (non-app-protocol commands):
/// `{"ok":false,"error":{"code":...,"message":...,"remedies":[...]}}`.
struct MSWGitHubRawError: Codable, Sendable, Equatable {
    let code: String?
    let message: String?
    let remedies: [String]?
}

/// Union-shaped JSON document for the raw `github` commands
/// (`repos`, `auth --device`, `auth --device-complete`). All fields optional;
/// callers validate the fields their command needs.
struct MSWGitHubCLIResponse: Codable, Sendable {
    let ok: Bool?
    let mode: String?
    let repos: [MSWGitHubDiscoveredRepo]?
    let status: String?
    let interval: Int?
    let deviceId: String?
    let code: String?
    let verificationUri: String?
    let expiresAt: Date?
    let metadata: MSWGitHubAuthMetadata?
    let error: MSWGitHubRawError?
}

struct MSWLifecyclePlan: Codable, Sendable, Equatable {
    let planId: String
    let action: String
    let workspace: String
    let expiresAt: Date
    let confirmationPhrase: String
    let effects: String
}

struct MSWApplyResult: Codable, Sendable {
    let workspace: String
    let action: String
    let reconciled: Bool
    let outcome: String
}
 
struct MSWPushPlan: Codable, Sendable {
    let planId: String
    let workspace: String
    let repositoryPath: String
    let branch: String
    let localCommit: String
    let remoteCommit: String?
    let aheadCount: Int
    let behindCount: Int
    let forceWithLease: Bool
    let expiresAt: Date
    let confirmationPhrase: String
    let effects: String
}

struct MSWPushApplyResult: Codable, Sendable {
    let workspace: String
    let repositoryPath: String
    let branch: String
    let pushed: Bool
    let reconciled: Bool
    let outcome: String
}

struct MSWBootstrapResult: Codable, Sendable {
    let resumed: Bool
    let phase: String
    let requiresApproval: Bool
    let vmsStarted: Bool
    let message: String
}

struct MSWURLResult: Codable, Sendable {
    let workspace: String
    let url: String
    let started: Bool
}

struct MSWWorkspaceOperationResult: Codable, Sendable {
    let workspace: String
    let operation: String
    let target: String?
    let changed: Bool
    let outcome: String
}

struct MSWIdentityResult: Codable, Sendable {
    let target: String
    let name: String
    let email: String
    let workspaces: [String]
}

struct MSWResourceResult: Codable, Sendable {
    let workspace: String
    let memory: String
    let cpus: String?
    let effective: Bool
    let outcome: String
}

struct MSWMaintenanceResult: Codable, Sendable {
    let target: String
    let operation: String
    let volumesRemoved: Bool
    let outcome: String
}

struct MSWCheckResult: Codable, Sendable {
    let deep: Bool
    let passed: Bool
    let checks: [MSWDiagnosticCheck]
    let outcome: String
}

struct MSWBackupResponse: Codable, Sendable {
    let archive: String
    let checksum: String?
    let stoppedWorkspaces: [String]
    let restartedWorkspaces: [String]
}

// JSON values are used only for opaque, schema-validated snapshots such as
// one-shot metrics. They are never used for credentials or command arguments.
enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

struct MSWProgressEvent: Codable, Sendable {
    let schemaVersion: Int
    let type: String
    let requestId: String
    let phase: String
    let workspace: String?
    let fraction: Double?
    let message: String
    let safeForDisplay: Bool
}

struct MSWRecoveryContext: Codable, Sendable, Equatable {
    let code: String
    let reason: String
    let recovery: String?
    let workspace: String?
    let retryable: Bool
}

struct MSWOperationState: Identifiable, Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case lifecycle
        case push
        case backup
        case restore
    }

    enum Phase: String, Codable, Sendable {
        case preparing
        case awaitingConfirmation = "awaiting-confirmation"
        case running
        case verifying
        case finished
    }

    enum Outcome: String, Codable, Sendable {
        case pending
        case succeeded
        case failed
        case unknown
    }

    let id: UUID
    let kind: Kind
    let workspace: String?
    let action: String
    let startedAt: Date
    var updatedAt: Date
    var phase: Phase
    var fraction: Double?
    var message: String
    var outcome: Outcome
    var recovery: MSWRecoveryContext?
}

struct MSWNotificationEvent: Identifiable, Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case sustainedUnavailability = "sustained-unavailability"
        case quarantine
        case lifecycleLoss = "lifecycle-loss"
        case operationFailure = "operation-failure"
        case backupFailure = "backup-failure"
        case credentialDeadline = "credential-deadline"
    }

    let id: UUID
    let kind: Kind
    let createdAt: Date
    let workspace: String?
    let title: String
    let message: String
    let recovery: String?
    let deepLink: String
    let generation: Int
}

struct MSWActivity: Identifiable, Codable, Sendable {
    let id: UUID
    let createdAt: Date
    let kind: Kind
    let title: String
    let detail: String?
    let workspace: String?
    let isFailure: Bool

    enum Kind: String, Codable, Sendable {
        case observation
        case operation
        case warning
        case failure
        case setup
        case authentication
    }
}
