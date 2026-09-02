import Foundation

private struct SiloAnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private func requireExactKeys<Key: CodingKey & CaseIterable>(
    in decoder: Decoder,
    _: Key.Type
) throws {
    // A container keyed by the concrete CodingKeys enum silently omits keys
    // that the enum does not know about. Inspect through a dynamic key first
    // so future fields are rejected instead of being mistaken for the current
    // canonical protocol contract.
    let container = try decoder.container(keyedBy: SiloAnyCodingKey.self)
    let actual = Set(container.allKeys.map(\.stringValue))
    let expected = Set(Key.allCases.map(\.stringValue))
    guard actual == expected else {
        throw DecodingError.dataCorrupted(
            .init(codingPath: decoder.codingPath, debugDescription: "Wire object keys do not match the supported protocol schema.")
        )
    }
}

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

struct SiloBootstrapConfiguration: Codable, Equatable, Sendable {
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

// MARK: - Machine-readable Silo contract

struct SiloEnvelope<Value: Codable & Sendable>: Codable, Sendable {
    let schemaVersion: Int
    let requestId: String
    let ok: Bool
    let command: String
    let observedAt: Date?
    let result: Value?
    let warnings: [String]
    let error: SiloProtocolError?

    init(
        schemaVersion: Int,
        requestId: String,
        ok: Bool,
        command: String,
        observedAt: Date? = nil,
        result: Value? = nil,
        warnings: [String] = [],
        error: SiloProtocolError? = nil
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
        try requireExactKeys(in: decoder, CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        requestId = try container.decode(String.self, forKey: .requestId)
        ok = try container.decode(Bool.self, forKey: .ok)
        command = try container.decode(String.self, forKey: .command)
        observedAt = try container.decodeIfPresent(Date.self, forKey: .observedAt)
        result = try container.decodeIfPresent(Value.self, forKey: .result)
        warnings = try container.decode([String].self, forKey: .warnings)
        error = try container.decodeIfPresent(SiloProtocolError.self, forKey: .error)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(requestId, forKey: .requestId)
        try container.encode(ok, forKey: .ok)
        try container.encode(command, forKey: .command)
        if let observedAt {
            try container.encode(observedAt, forKey: .observedAt)
        } else {
            try container.encodeNil(forKey: .observedAt)
        }
        if let result {
            try container.encode(result, forKey: .result)
        } else {
            try container.encodeNil(forKey: .result)
        }
        try container.encode(warnings, forKey: .warnings)
        if let error {
            try container.encode(error, forKey: .error)
        } else {
            try container.encodeNil(forKey: .error)
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, requestId, ok, command, observedAt, result, warnings, error
    }
}

struct SiloProtocolError: Codable, Error, LocalizedError, Sendable, Equatable {
    let code: String
    let message: String
    let recovery: String?
    let workspace: String?
    let retryable: Bool

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case code, message, recovery, workspace, retryable
    }

    init(
        code: String,
        message: String,
        recovery: String?,
        workspace: String?,
        retryable: Bool
    ) {
        self.code = code
        self.message = message
        self.recovery = recovery
        self.workspace = workspace
        self.retryable = retryable
    }

    init(from decoder: Decoder) throws {
        try requireExactKeys(in: decoder, CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(String.self, forKey: .code)
        message = try container.decode(String.self, forKey: .message)
        recovery = try container.decodeIfPresent(String.self, forKey: .recovery)
        workspace = try container.decodeIfPresent(String.self, forKey: .workspace)
        retryable = try container.decode(Bool.self, forKey: .retryable)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(message, forKey: .message)
        if let recovery {
            try container.encode(recovery, forKey: .recovery)
        } else {
            try container.encodeNil(forKey: .recovery)
        }
        if let workspace {
            try container.encode(workspace, forKey: .workspace)
        } else {
            try container.encodeNil(forKey: .workspace)
        }
        try container.encode(retryable, forKey: .retryable)
    }

    var errorDescription: String? {
        var description = message
        if let recovery, !recovery.isEmpty {
            description += " \(recovery)"
        }
        description += " (Silo error code: \(code).)"
        return description
    }
}

struct SiloHandshake: Codable, Sendable {
    let protocolVersion: Int
    let siloVersion: String
    let platform: Platform
    let configurationAvailable: Bool
    let runtimeAvailable: Bool
    let capabilities: Capabilities
    let exitCodes: [String: Int]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case protocolVersion, siloVersion, platform, configurationAvailable, runtimeAvailable
        case capabilities, exitCodes
    }

    init(from decoder: Decoder) throws {
        try requireExactKeys(in: decoder, CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        siloVersion = try container.decode(String.self, forKey: .siloVersion)
        platform = try container.decode(Platform.self, forKey: .platform)
        configurationAvailable = try container.decode(Bool.self, forKey: .configurationAvailable)
        runtimeAvailable = try container.decode(Bool.self, forKey: .runtimeAvailable)
        capabilities = try container.decode(Capabilities.self, forKey: .capabilities)
        exitCodes = try container.decode([String: Int].self, forKey: .exitCodes)
    }

    struct Platform: Codable, Sendable {
        let os: String
        let architecture: String

        private enum CodingKeys: String, CodingKey, CaseIterable { case os, architecture }

        init(from decoder: Decoder) throws {
            try requireExactKeys(in: decoder, CodingKeys.self)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            os = try container.decode(String.self, forKey: .os)
            architecture = try container.decode(String.self, forKey: .architecture)
        }
    }

    struct Capabilities: Codable, Sendable {
        let jsonState: Bool
        let jsonMetrics: Bool
        let jsonLogs: Bool
        let plans: Bool
        let bootstrapEvents: Bool
        let jq: Bool
        let workspaceCount: Int

        var isComplete: Bool {
            jsonState && jsonMetrics && jsonLogs && plans && bootstrapEvents
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case jsonState, jsonMetrics, jsonLogs, plans, bootstrapEvents
            case jq, workspaceCount
        }

        init(from decoder: Decoder) throws {
            try requireExactKeys(in: decoder, CodingKeys.self)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            jsonState = try container.decode(Bool.self, forKey: .jsonState)
            jsonMetrics = try container.decode(Bool.self, forKey: .jsonMetrics)
            jsonLogs = try container.decode(Bool.self, forKey: .jsonLogs)
            plans = try container.decode(Bool.self, forKey: .plans)
            bootstrapEvents = try container.decode(Bool.self, forKey: .bootstrapEvents)
            jq = try container.decode(Bool.self, forKey: .jq)
            workspaceCount = try container.decode(Int.self, forKey: .workspaceCount)
        }
    }
}

struct SiloStateResponse: Codable, Sendable {
    let schemaVersion: Int
    let siloVersion: String
    let workspaces: [SiloWorkspaceSnapshot]
}

struct SiloWorkspaceSnapshot: Codable, Identifiable, Sendable {
    let id: String
    let purpose: String
    let lifecycle: SiloLifecycle
    let freshness: SiloFreshness
    let statusObservedAt: Date?
    let metricsObservedAt: Date?
    let githubObservedAt: Date?
    let activityObservedAt: Date?
    let quarantine: SiloQuarantineSnapshot
    let credential: SiloCredentialSnapshot
    /// Per-workspace host-secret configuration state. Absent in older CLI
    /// output, which the app reads as "no pending secret configuration".
    let secrets: SiloSecretsSnapshot?
    let resources: SiloResourceSnapshot
    let network: SiloNetworkSnapshot
    let actionCapabilities: SiloActionCapabilities
    /// Published ports skipped by the workspace proxy because they were
    /// already in use ([] when none). Absent in older CLI output.
    let skippedPorts: [Int]?
    /// Human-readable warning about skipped published ports ("" when none).
    let portWarning: String?

    init(
        id: String,
        purpose: String,
        lifecycle: SiloLifecycle,
        freshness: SiloFreshness,
        quarantine: SiloQuarantineSnapshot,
        credential: SiloCredentialSnapshot,
        secrets: SiloSecretsSnapshot? = nil,
        resources: SiloResourceSnapshot,
        network: SiloNetworkSnapshot,
        actionCapabilities: SiloActionCapabilities,
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
        self.secrets = secrets
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
        lifecycle = try container.decode(SiloLifecycle.self, forKey: .lifecycle)
        freshness = try container.decode(SiloFreshness.self, forKey: .freshness)
        statusObservedAt = try container.decodeIfPresent(Date.self, forKey: .statusObservedAt)
        metricsObservedAt = try container.decodeIfPresent(Date.self, forKey: .metricsObservedAt)
        githubObservedAt = try container.decodeIfPresent(Date.self, forKey: .githubObservedAt)
        activityObservedAt = try container.decodeIfPresent(Date.self, forKey: .activityObservedAt)
        quarantine = try container.decode(SiloQuarantineSnapshot.self, forKey: .quarantine)
        credential = try container.decode(SiloCredentialSnapshot.self, forKey: .credential)
        secrets = try container.decodeIfPresent(SiloSecretsSnapshot.self, forKey: .secrets)
        resources = try container.decode(SiloResourceSnapshot.self, forKey: .resources)
        network = try container.decode(SiloNetworkSnapshot.self, forKey: .network)
        actionCapabilities = try container.decode(SiloActionCapabilities.self, forKey: .actionCapabilities)
        skippedPorts = try container.decodeIfPresent([Int].self, forKey: .skippedPorts)
        portWarning = try container.decodeIfPresent(String.self, forKey: .portWarning)
    }

    private enum CodingKeys: String, CodingKey {
        case id, purpose, lifecycle, freshness, statusObservedAt, metricsObservedAt
        case githubObservedAt, activityObservedAt, quarantine, credential, resources, network, actionCapabilities
        case secrets, skippedPorts, portWarning
    }

    var identity: String { id }
}

enum SiloLifecycle: String, Codable, Sendable {
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

enum SiloFreshness: String, Codable, Sendable {
    case fresh
    case stale
    case unavailable
    case neverObserved = "never-observed"
}

struct SiloQuarantineSnapshot: Codable, Sendable {
    let state: State
    let reason: String?

    enum State: String, Codable, Sendable {
        case clear
        case quarantined
        case unknown
    }
}

struct SiloCredentialSnapshot: Codable, Sendable {
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

struct SiloResourceSnapshot: Codable, Sendable {
    let cpus: String
    let maxCpus: String
    let memory: String
    let maxMemory: String
    let rootDisk: String
}

struct SiloNetworkSnapshot: Codable, Sendable {
    let host: String
    let ip: String
}

struct SiloActionCapabilities: Codable, Sendable, Equatable {
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

struct SiloPortsResponse: Codable, Sendable {
    let workspace: String
    let workspaces: [WorkspacePorts]
    let freshness: SiloFreshness

    struct WorkspacePorts: Codable, Identifiable, Sendable {
        let workspace: String
        let lifecycle: SiloLifecycle
        let host: String
        let listeningState: ListeningState
        let ports: [Port]

        var id: String { workspace }
    }

    struct Port: Codable, Identifiable, Sendable {
        let port: String
        let configured: Bool
        let listening: Bool?

        var id: String { port }
    }

    enum ListeningState: String, Codable, Sendable {
        case known
        case unknown
    }
}

struct SiloMetricsResponse: Codable, Sendable {
    let workspace: String
    let available: Bool
    let lifecycle: SiloLifecycle
    let freshness: SiloFreshness
    let reason: String?
    let snapshot: JSONValue?
}

struct SiloLogsResponse: Codable, Sendable {
    let workspace: String
    let available: Bool
    let lifecycle: SiloLifecycle
    let freshness: SiloFreshness
    let reason: String?
    let lines: [SiloLogEntry]
}

struct SiloLogEntry: Codable, Sendable {
    let workspace: String
    let observedAt: Date
    let source: String
    let sessionID: Int?
    let encoding: String?
    let message: String
    let safeForDisplay: Bool

    enum CodingKeys: String, CodingKey {
        case workspace, observedAt, source, encoding, message, safeForDisplay
        case sessionID = "sessionId"
    }
}

struct SiloRepositoriesResponse: Codable, Sendable {
    let workspace: String
    let repositories: [SiloRepositorySnapshot]
    let needsStart: Bool
    let freshness: SiloFreshness
    let worktreeStatusIncluded: Bool
    let notice: String?
}

struct SiloDirectoryResponse: Codable, Sendable, Equatable {
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

struct SiloEditorTarget: Codable, Sendable, Equatable {
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

struct SiloRepositorySnapshot: Codable, Identifiable, Sendable {
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
    let freshness: SiloFreshness
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

struct SiloGitHubStateResponse: Codable, Sendable {
    let workspaces: [SiloGitHubWorkspaceState]
}

/// Per-workspace host-secret configuration state from the app state protocol.
/// Deliberately separate from `SiloCredentialSnapshot`; secret restart
/// requirements must never ride the GitHub credential state.
struct SiloSecretsSnapshot: Codable, Sendable, Equatable {
    let state: State
    let pendingCount: Int
    let reason: String?

    enum State: String, Codable, Sendable {
        case active
        case restartRequired = "restart-required"
        case appliesOnNextStart = "applies-on-next-start"
        case error
    }
}

/// Nonsecret host-secret metadata from `silo app secrets-list --format json`.
/// Never contains secret values.
struct SiloSecretsListResponse: Codable, Sendable {
    let entries: [Entry]
    let workspaces: [WorkspaceSummary]

    struct Entry: Codable, Identifiable, Sendable {
        let name: String
        let workspaces: [String]
        let allowedDomains: [String]
        let status: Status
        let pendingOperation: SiloSecretPendingOperation?
        let generation: Int
        /// Safe, nonsecret failure detail; `null` when there is none.
        let error: String?

        enum Status: String, Codable, Sendable {
            case active
            case restartRequired = "restart-required"
            case removalPendingRestart = "removal-pending-restart"
            case appliesOnNextStart = "applies-on-next-start"
            case error
        }

        /// Pending mutation attached to the entry, or `null` when the entry
        /// has no staged change.
        struct SiloSecretPendingOperation: Codable, Sendable, Equatable {
            let type: String
            let createdAt: Date
        }

        var id: String { name }
    }

    struct WorkspaceSummary: Codable, Identifiable, Sendable {
        let workspace: String
        let restartRequired: Bool
        let pendingCount: Int

        var id: String { workspace }
    }
}

/// `silo app secret-plan --input-fd 0` request: operation plus nonsecret
/// metadata, carried on stdin. The value is never part of planning.
struct SiloSecretPlanRequest: Codable, Sendable, Equatable {
    let operation: String
    let name: String
    let workspaces: [String]
    let allowedDomains: [String]
}

/// `silo app secret-plan --input-fd 0` result. Nonsecret; the real value is
/// requested only at apply time and travels exclusively on stdin.
struct SiloSecretPlanResult: Codable, Sendable, Equatable {
    let planId: String
    let operation: String
    let name: String
    let affectedWorkspaces: [String]
    let requiresSecret: Bool
    let confirmationPhrase: String
    let effects: String
    let expiresAt: Date
}

/// `silo app secret-apply PLAN_ID --input-fd 0` request. `value` is required
/// only when the plan reports `requiresSecret`, and it must never appear in
/// argv, the environment, output, logs, or persisted metadata.
struct SiloSecretApplyRequest: Codable, Sendable, Equatable {
    let confirmation: String
    let value: String?
}

/// `silo app secret-apply` success result. Never contains the value. The app
/// treats the operation as applied only when the envelope reports success,
/// the result matches the reviewed plan, and `applied` is true; statuses are
/// re-read from `secrets-list` afterwards.
struct SiloSecretApplyResult: Codable, Sendable, Equatable {
    let applied: Bool
    let operation: String
    let name: String
    let workspaces: [String]
    let pending: [PendingWorkspace]
    let valueStored: Bool
    let outcome: String

    struct PendingWorkspace: Codable, Sendable, Equatable {
        let workspace: String
        let state: String
    }
}

struct SiloGitHubBindResult: Codable, Sendable {
    let workspace: String
    let accessMode: String
    let verificationRepository: String
    let verified: Bool
    let lifecycleRestored: Bool
}
struct SiloGitHubUnbindResult: Codable, Sendable {
    let workspace: String
    let unbound: Bool
}


struct SiloGitHubWorkspaceState: Codable, Identifiable, Sendable {
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
    let repos: [SiloGitHubPolicyRepo]?
    let policyUpdatedAt: Date?
    let hostCredential: String?

    var id: String { workspace }
}

/// A ticked repository as rendered from the local policy file.
struct SiloGitHubPolicyRepo: Codable, Identifiable, Sendable, Equatable {
    let canonical: String
    let mode: GitHubRepositoryAccessMode

    var id: String { canonical }
    var modeLabel: String { mode.label }
}

/// `silo github status --format json`: global host-credential state plus
/// workspace-scoped policy, capability, and shuttle state.
struct SiloGitHubStatusResponse: Codable, Sendable {
    let mode: String
    let hostCredential: String?
    let workspaces: [SiloGitHubStatusWorkspace]
}

struct SiloGitHubStatusWorkspace: Codable, Sendable {
    let workspace: String
    let capability: String?
    let repos: [SiloGitHubStatusRepo]?
    let shuttle: String?
}

struct SiloGitHubStatusRepo: Codable, Sendable, Equatable {
    let canonical: String
    let mode: String
}

/// Nonsecret host-credential metadata from `silo github auth --json`. Never
/// contains token bytes.
struct SiloGitHubAuthMetadata: Codable, Sendable {
    let provider: String?
    let tokenKind: String?
    let accountLogin: String?
    let verifiedAt: Date?
    let generation: Int?
    let storedAt: Date?
    let repoChecks: [SiloGitHubAuthRepoCheck]?
}

struct SiloGitHubAuthRepoCheck: Codable, Sendable {
    let canonical: String?
    let mode: String?
    let push: Bool?
    let checkedAt: Date?
}

/// `silo app github-policy-apply` request: the FULL desired policy file
/// carried on stdin. Missing workspace keys are treated by the CLI as
/// "clear this workspace", so the app always sends every configured workspace.
struct SiloGitHubPolicyApplyRequest: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let workspaces: [String: GitHubPolicyWorkspace]
}

/// `silo app github-policy-apply` success result. The app marks the operation
/// applied ONLY when `applied`, `provisioned`, and `committed` are all true.
struct SiloGitHubPolicyApplyResult: Codable, Sendable {
    let applied: Bool?
    let provisioned: Bool?
    let committed: Bool?
    let workspaces: [SiloGitHubPolicyApplyWorkspace]?
}

struct SiloGitHubPolicyApplyWorkspace: Codable, Sendable {
    let workspace: String
    let capability: String?
    let repos: [SiloGitHubStatusRepo]?
}

/// Repository discovery entry from `silo github repos --format json`.
struct SiloGitHubDiscoveredRepo: Codable, Sendable, Equatable {
    let canonical: String
    let name: String
    let owner: String
    let `private`: Bool
    let permissions: SiloGitHubRepoPermissions
    let inPolicy: Bool
}

struct SiloGitHubRepoPermissions: Codable, Sendable, Equatable {
    let pull: Bool
    let push: Bool
}

/// Typed raw-CLI error document (non-app-protocol commands):
/// `{"ok":false,"error":{"code":...,"message":...,"remedies":[...]}}`.
struct SiloGitHubRawError: Codable, Sendable, Equatable {
    let code: String?
    let message: String?
    let remedies: [String]?
}

/// Union-shaped JSON document for the raw `github` commands
/// (`repos`, `auth --device`, `auth --device-complete`). All fields optional;
/// callers validate the fields their command needs.
struct SiloGitHubCLIResponse: Codable, Sendable {
    let ok: Bool?
    let mode: String?
    let repos: [SiloGitHubDiscoveredRepo]?
    let status: String?
    let interval: Int?
    let deviceId: String?
    let code: String?
    let verificationUri: String?
    let expiresAt: Date?
    let metadata: SiloGitHubAuthMetadata?
    let error: SiloGitHubRawError?
}

struct SiloLifecyclePlan: Codable, Sendable, Equatable {
    let planId: String
    let action: String
    let workspace: String
    let expiresAt: Date
    let confirmationPhrase: String
    let effects: String
}

struct SiloApplyResult: Codable, Sendable {
    let workspace: String
    let action: String
    let reconciled: Bool
    let outcome: String
}
 
struct SiloPushPlan: Codable, Sendable {
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

struct SiloPushApplyResult: Codable, Sendable {
    let workspace: String
    let repositoryPath: String
    let branch: String
    let pushed: Bool
    let reconciled: Bool
    let outcome: String
}

struct SiloBootstrapResult: Codable, Sendable {
    let resumed: Bool
    let phase: String
    let requiresApproval: Bool
    let vmsStarted: Bool
    let message: String
}

struct SiloURLResult: Codable, Sendable {
    let workspace: String
    let url: String
    let started: Bool
}

struct SiloWorkspaceOperationResult: Codable, Sendable {
    let workspace: String
    let operation: String
    let target: String?
    let changed: Bool
    let outcome: String
}

struct SiloIdentityResult: Codable, Sendable {
    let target: String
    let name: String
    let email: String
    let workspaces: [String]
}

struct SiloResourceResult: Codable, Sendable {
    let workspace: String
    let memory: String
    let cpus: String?
    let effective: Bool
    let outcome: String
}

struct SiloMaintenanceResult: Codable, Sendable {
    let target: String
    let operation: String
    let volumesRemoved: Bool
    let outcome: String
}

struct SiloCheckResult: Codable, Sendable {
    let deep: Bool
    let passed: Bool
    let checks: [SiloDiagnosticCheck]
    let outcome: String
}

struct SiloBackupFinalResponse: Codable, Sendable, Equatable {
    let archive: String
    let archiveBytes: Int64
    let checksum: String
    let info: String
    let completedAt: Date
    let stoppedWorkspaces: [String]
    let restartedWorkspaces: [String]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case archive, archiveBytes, checksum, info, completedAt
        case stoppedWorkspaces, restartedWorkspaces
    }

    init(from decoder: Decoder) throws {
        try requireExactKeys(in: decoder, CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        archive = try container.decode(String.self, forKey: .archive)
        archiveBytes = try container.decode(Int64.self, forKey: .archiveBytes)
        checksum = try container.decode(String.self, forKey: .checksum)
        info = try container.decode(String.self, forKey: .info)
        completedAt = try container.decode(Date.self, forKey: .completedAt)
        stoppedWorkspaces = try container.decode([String].self, forKey: .stoppedWorkspaces)
        restartedWorkspaces = try container.decode([String].self, forKey: .restartedWorkspaces)
    }
}

struct SiloBackupEstimateResponse: Codable, Sendable, Equatable {
    let lowerBytes: Int64
    let upperBytes: Int64
    let basisRatio: Double
    let changedSourceRatio: Double
    let provenance: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case lowerBytes, upperBytes, basisRatio, changedSourceRatio, provenance
    }

    init(from decoder: Decoder) throws {
        try requireExactKeys(in: decoder, CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lowerBytes = try container.decode(Int64.self, forKey: .lowerBytes)
        upperBytes = try container.decode(Int64.self, forKey: .upperBytes)
        basisRatio = try container.decode(Double.self, forKey: .basisRatio)
        changedSourceRatio = try container.decode(Double.self, forKey: .changedSourceRatio)
        provenance = try container.decode(String.self, forKey: .provenance)
    }
}

struct SiloBackupPreviewResponse: Codable, Sendable {
    let destination: String
    let sourceAllocatedBytes: Int64
    let archiveEstimate: SiloBackupEstimateResponse?
    let runningWorkspaces: [String]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case destination, sourceAllocatedBytes, archiveEstimate, runningWorkspaces
    }

    init(from decoder: Decoder) throws {
        try requireExactKeys(in: decoder, CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        destination = try container.decode(String.self, forKey: .destination)
        sourceAllocatedBytes = try container.decode(Int64.self, forKey: .sourceAllocatedBytes)
        archiveEstimate = try container.decodeIfPresent(SiloBackupEstimateResponse.self, forKey: .archiveEstimate)
        runningWorkspaces = try container.decode([String].self, forKey: .runningWorkspaces)
    }
}

struct SiloBackupProgressResponse: Codable, Sendable, Equatable {
    let processedBytes: Int64
    let writtenBytes: Int64
    let throughputBytesPerSecond: Int64
    let totalBytes: Int64?
    let etaSeconds: Int64?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case processedBytes, writtenBytes, throughputBytesPerSecond, totalBytes, etaSeconds
    }

    init(from decoder: Decoder) throws {
        try requireExactKeys(in: decoder, CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        processedBytes = try container.decode(Int64.self, forKey: .processedBytes)
        writtenBytes = try container.decode(Int64.self, forKey: .writtenBytes)
        throughputBytesPerSecond = try container.decode(Int64.self, forKey: .throughputBytesPerSecond)
        totalBytes = try container.decodeIfPresent(Int64.self, forKey: .totalBytes)
        etaSeconds = try container.decodeIfPresent(Int64.self, forKey: .etaSeconds)
    }
}

struct SiloBackupOperationErrorResponse: Codable, Sendable, Equatable {
    let code: String
    let message: String
    let recovery: String
    let retryable: Bool

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case code, message, recovery, retryable
    }

    init(code: String, message: String, recovery: String, retryable: Bool) {
        self.code = code
        self.message = message
        self.recovery = recovery
        self.retryable = retryable
    }

    init(from decoder: Decoder) throws {
        try requireExactKeys(in: decoder, CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(String.self, forKey: .code)
        message = try container.decode(String.self, forKey: .message)
        recovery = try container.decode(String.self, forKey: .recovery)
        retryable = try container.decode(Bool.self, forKey: .retryable)
    }
}

struct SiloBackupOperationResponse: Codable, Sendable, Equatable {
    let kind: String
    let operationId: String
    let requestKey: String
    let state: String
    let phase: String
    let message: String
    let destination: String
    let startedAt: Date
    let updatedAt: Date
    let completedAt: Date?
    let elapsedSeconds: Int64
    let ownerPid: Int32?
    let ownerProcessState: String
    let sourceAllocatedBytes: Int64
    let archiveEstimate: SiloBackupEstimateResponse?
    let runningWorkspaces: [String]
    let progress: SiloBackupProgressResponse
    let result: SiloBackupFinalResponse?
    let error: SiloBackupOperationErrorResponse?
    let warnings: [String]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind, operationId, requestKey, state, phase, message, destination
        case startedAt, updatedAt, completedAt, elapsedSeconds, ownerPid, ownerProcessState
        case sourceAllocatedBytes, archiveEstimate, runningWorkspaces, progress, result, error, warnings
    }

    init(from decoder: Decoder) throws {
        try requireExactKeys(in: decoder, CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(String.self, forKey: .kind)
        operationId = try container.decode(String.self, forKey: .operationId)
        requestKey = try container.decode(String.self, forKey: .requestKey)
        state = try container.decode(String.self, forKey: .state)
        phase = try container.decode(String.self, forKey: .phase)
        message = try container.decode(String.self, forKey: .message)
        destination = try container.decode(String.self, forKey: .destination)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        elapsedSeconds = try container.decode(Int64.self, forKey: .elapsedSeconds)
        ownerPid = try container.decodeIfPresent(Int32.self, forKey: .ownerPid)
        ownerProcessState = try container.decode(String.self, forKey: .ownerProcessState)
        sourceAllocatedBytes = try container.decode(Int64.self, forKey: .sourceAllocatedBytes)
        archiveEstimate = try container.decodeIfPresent(SiloBackupEstimateResponse.self, forKey: .archiveEstimate)
        runningWorkspaces = try container.decode([String].self, forKey: .runningWorkspaces)
        progress = try container.decode(SiloBackupProgressResponse.self, forKey: .progress)
        result = try container.decodeIfPresent(SiloBackupFinalResponse.self, forKey: .result)
        error = try container.decodeIfPresent(SiloBackupOperationErrorResponse.self, forKey: .error)
        warnings = try container.decode([String].self, forKey: .warnings)
    }
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

struct SiloProgressEvent: Codable, Sendable {
    let schemaVersion: Int
    let type: String
    let requestId: String
    let phase: String
    let workspace: String?
    let fraction: Double?
    let message: String
    let safeForDisplay: Bool
}

struct SiloRecoveryContext: Codable, Sendable, Equatable {
    let code: String
    let reason: String
    let recovery: String?
    let workspace: String?
    let retryable: Bool
}

struct SiloOperationState: Identifiable, Codable, Sendable, Equatable {
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
    var recovery: SiloRecoveryContext?
}

struct SiloNotificationEvent: Identifiable, Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case sustainedUnavailability = "sustained-unavailability"
        case quarantine
        case lifecycleLoss = "lifecycle-loss"
        case operationFailure = "operation-failure"
        case backupFailure = "backup-failure"
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

struct SiloActivity: Identifiable, Codable, Sendable {
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
