import Foundation

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

    var errorDescription: String? { message }
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
        activityObservedAt: Date? = nil
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
    }

    private enum CodingKeys: String, CodingKey {
        case id, purpose, lifecycle, freshness, statusObservedAt, metricsObservedAt
        case githubObservedAt, activityObservedAt, quarantine, credential, resources, network, actionCapabilities
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

struct MSWActionCapabilities: Codable, Sendable {
    let canStart: Bool
    let canStop: Bool
    let canRestart: Bool
    let canOpenTerminal: Bool
    let canPush: Bool
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

    var id: String { workspace }
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
