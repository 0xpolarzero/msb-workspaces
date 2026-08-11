import Foundation

enum CredentialRole: String, Codable, Sendable, CaseIterable {
    case guest
    case host
}

enum CredentialRecoveryState: String, Codable, Sendable, Equatable {
    case ready
    case needsAuthorization
    case migrationRequired
    case expired
    case revoked
    case installationRemoved
    case serviceUnavailable
    case quarantined
}

/// The only credential material that may be stored for a workspace. This is a
/// short-lived GitHub App installation token minted by MSW Connect. It is not
/// a GitHub user token and has no refresh capability.
struct ScopedInstallationCredential: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 3

    let schemaVersion: Int
    let grantID: UUID
    let accessToken: String
    let accessExpiresAt: Date
    let generation: Int

    init(
        schemaVersion: Int = ScopedInstallationCredential.currentSchemaVersion,
        grantID: UUID,
        accessToken: String,
        accessExpiresAt: Date,
        generation: Int
    ) {
        self.schemaVersion = schemaVersion
        self.grantID = grantID
        self.accessToken = accessToken
        self.accessExpiresAt = accessExpiresAt
        self.generation = generation
    }

    var isAccessExpired: Bool { accessExpiresAt <= Date() }

    var isStructurallyValid: Bool {
        schemaVersion == Self.currentSchemaVersion &&
            Self.isSafeInstallationToken(accessToken) &&
            accessExpiresAt > Date.distantPast &&
            generation > 0
    }

    private static func isSafeInstallationToken(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed == value,
              trimmed.count <= 4096,
              trimmed.hasPrefix("ghs_"),
              !trimmed.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0) ||
                    CharacterSet.controlCharacters.contains($0)
              }) else {
            return false
        }
        let lowercased = trimmed.lowercased()
        return !["ghp_", "gho_", "ghu_", "ghr_", "github_pat_"].contains {
            lowercased.hasPrefix($0)
        }
    }
}

struct WorkspaceCredentialMetadata: Codable, Sendable, Equatable, Identifiable {
    let workspace: String
    var schemaVersion: Int = 3
    var role: CredentialRole = .guest
    var provider: String = "github-app-installation"
    var grantID: UUID?
    var scopeDigest: String?
    var accountLogin: String?
    var owner: String?
    var repositoryIDs: [Int] = []
    var repositoryNames: [String] = []
    var accessMode: String
    var verificationRepository: String?
    var installationID: Int?
    var accessExpiresAt: Date?
    var needsRestart: Bool = false
    var generation: Int
    var quarantined: Bool
    var recoveryState: CredentialRecoveryState = .needsAuthorization
    var updatedAt: Date

    var id: String { "\(workspace).\(role.rawValue)" }

    init(
        workspace: String,
        schemaVersion: Int = 3,
        role: CredentialRole = .guest,
        provider: String = "github-app-installation",
        grantID: UUID? = nil,
        scopeDigest: String? = nil,
        accountLogin: String? = nil,
        owner: String? = nil,
        repositoryIDs: [Int] = [],
        repositoryNames: [String] = [],
        accessMode: String,
        verificationRepository: String?,
        installationID: Int?,
        accessExpiresAt: Date?,
        needsRestart: Bool = false,
        generation: Int,
        quarantined: Bool,
        recoveryState: CredentialRecoveryState = .needsAuthorization,
        updatedAt: Date
    ) {
        self.workspace = workspace
        self.schemaVersion = schemaVersion
        self.role = role
        self.provider = provider
        self.scopeDigest = scopeDigest
        self.grantID = grantID
        self.accountLogin = accountLogin
        self.owner = owner
        self.repositoryIDs = repositoryIDs
        self.repositoryNames = repositoryNames
        self.accessMode = accessMode
        self.verificationRepository = verificationRepository
        self.installationID = installationID
        self.accessExpiresAt = accessExpiresAt
        self.needsRestart = needsRestart
        self.generation = generation
        self.quarantined = quarantined
        self.recoveryState = recoveryState
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspace = try container.decode(String.self, forKey: .workspace)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        role = try container.decodeIfPresent(CredentialRole.self, forKey: .role) ?? .guest
        provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? "github-app-user"
        grantID = try container.decodeIfPresent(UUID.self, forKey: .grantID)
        scopeDigest = try container.decodeIfPresent(String.self, forKey: .scopeDigest)
        accountLogin = try container.decodeIfPresent(String.self, forKey: .accountLogin)
        owner = try container.decodeIfPresent(String.self, forKey: .owner)
        repositoryIDs = try container.decodeIfPresent([Int].self, forKey: .repositoryIDs) ?? []
        repositoryNames = try container.decodeIfPresent([String].self, forKey: .repositoryNames) ?? []
        accessMode = try container.decodeIfPresent(String.self, forKey: .accessMode) ?? "unknown"
        verificationRepository = try container.decodeIfPresent(String.self, forKey: .verificationRepository)
        installationID = try container.decodeIfPresent(Int.self, forKey: .installationID)
        accessExpiresAt = try container.decodeIfPresent(Date.self, forKey: .accessExpiresAt)
        needsRestart = try container.decodeIfPresent(Bool.self, forKey: .needsRestart) ?? false
        generation = try container.decodeIfPresent(Int.self, forKey: .generation) ?? 0
        quarantined = try container.decodeIfPresent(Bool.self, forKey: .quarantined) ?? false
        recoveryState = try container.decodeIfPresent(CredentialRecoveryState.self, forKey: .recoveryState)
            ?? (quarantined ? .quarantined : .needsAuthorization)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
    private enum CodingKeys: String, CodingKey {
        case workspace, schemaVersion, role, provider, grantID, scopeDigest, accountLogin, owner
        case repositoryIDs, repositoryNames, accessMode, verificationRepository, installationID
        case accessExpiresAt, needsRestart, generation, quarantined, recoveryState, updatedAt
    }
}

struct CredentialBundle: Sendable, Equatable {
    let metadata: WorkspaceCredentialMetadata
    let credential: ScopedInstallationCredential
}

enum CredentialBrokerError: Error, LocalizedError, Sendable, Equatable {
    case invalidWorkspace
    case invalidCredential
    case missingCredential
    case metadataWriteFailed
    case quarantineRequired
    case migrationFailed
    case grantUnavailable
    case legacyCredentialRequiresAuthorization

    var errorDescription: String? {
        switch self {
        case .invalidWorkspace: return "The credential workspace identifier is invalid."
        case .invalidCredential: return "The GitHub installation credential record is malformed or has an invalid scope."
        case .missingCredential: return "No GitHub installation grant is configured for this workspace."
        case .metadataWriteFailed: return "Credential metadata could not be committed."
        case .quarantineRequired: return "The workspace is quarantined until its credentials are repaired."
        case .migrationFailed: return "Credential metadata migration could not be completed safely."
        case .grantUnavailable: return "The workspace grant is unavailable and must be renewed or reauthorized."
        case .legacyCredentialRequiresAuthorization: return "This workspace has a legacy broad GitHub credential. Explicit reauthorization is required."
        }
    }
}

struct MSWAuthorizationAuditEvent: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let createdAt: Date
    let event: String
    let workspace: String
    let role: CredentialRole
    let grantID: UUID?
    let detail: String
}

/// Persists only grant lifecycle facts. Token bytes, repository names, and
/// authorization codes never enter this file.
final class MSWAuthorizationAuditStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    init(url: URL) {
        self.url = url
    }

    func append(
        event: String,
        workspace: String,
        role: CredentialRole,
        grantID: UUID?,
        detail: String
    ) {
        lock.lock()
        defer { lock.unlock() }
        var events = load()
        events.append(MSWAuthorizationAuditEvent(
            id: UUID(),
            createdAt: Date(),
            event: event,
            workspace: workspace,
            role: role,
            grantID: grantID,
            detail: detail
        ))
        if events.count > 200 {
            events.removeFirst(events.count - 200)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(events) else { return }
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // Audit persistence must never make a credential operation fail.
        }
    }

    func recent(limit: Int = 50) -> [MSWAuthorizationAuditEvent] {
        lock.lock()
        defer { lock.unlock() }
        return Array(load().suffix(max(0, min(limit, 200))))
    }

    private func load() -> [MSWAuthorizationAuditEvent] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([MSWAuthorizationAuditEvent].self, from: data)) ?? []
    }
}

actor CredentialBroker {
    private static let currentSchemaVersion = ScopedInstallationCredential.currentSchemaVersion
    private let keychain: any CredentialKeychainStoring
    private let metadataURL: URL
    private let keychainServiceOverride: String?
    private let audit: MSWAuthorizationAuditStore
    private var metadata: [String: WorkspaceCredentialMetadata]

    init(
        keychain: any CredentialKeychainStoring = KeychainStore(),
        metadataURL: URL? = nil,
        keychainService: String = "",
        auditStore: MSWAuthorizationAuditStore? = nil
    ) throws {
        self.keychain = keychain
        self.keychainServiceOverride = keychainService.isEmpty ? nil : keychainService
        let defaultURL = try Self.defaultMetadataURL()
        let resolvedMetadataURL = metadataURL ?? defaultURL
        self.metadataURL = resolvedMetadataURL
        self.audit = auditStore ?? MSWAuthorizationAuditStore(
            url: resolvedMetadataURL.deletingLastPathComponent().appendingPathComponent("authorization-events.json")
        )
        let loaded = try Self.readMetadata(from: resolvedMetadataURL)
        let normalized = try Self.normalize(loaded)
        let didNormalize = normalized != loaded
        if didNormalize {
            do {
                try Self.persistMetadata(normalized, to: self.metadataURL)
            } catch {
                throw CredentialBrokerError.migrationFailed
            }
        }
        self.metadata = normalized
        for entry in normalized.values where entry.provider == "legacy-broad-token" {
            // Legacy schema versions could have stored separate broad guest
            // and host records, while only one role was present in metadata.
            // Clear both legacy slots for the workspace before requiring
            // explicit reauthorization.
            for role in CredentialRole.allCases {
                try? self.keychain.delete(
                    service: Self.legacyService(for: role),
                    account: entry.workspace
                )
            }
            if didNormalize {
                audit.append(
                    event: "legacyMigrated",
                    workspace: entry.workspace,
                    role: entry.role,
                    grantID: nil,
                    detail: "explicit-reauthorization-required"
                )
            }
        }
    }

    func metadata(for workspace: String, role: CredentialRole = .guest) throws -> WorkspaceCredentialMetadata? {
        guard WorkspaceID.isValid(workspace) else { throw CredentialBrokerError.invalidWorkspace }
        return metadata[metadataKey(workspace, role)]
    }

    func allMetadata() -> [WorkspaceCredentialMetadata] {
        metadata.values.sorted { $0.id < $1.id }
    }

    func load(workspace: String, role: CredentialRole = .guest) throws -> CredentialBundle {
        guard WorkspaceID.isValid(workspace) else { throw CredentialBrokerError.invalidWorkspace }
        let key = metadataKey(workspace, role)
        guard let entry = metadata[key] else { throw CredentialBrokerError.missingCredential }
        guard entry.provider == "github-app-installation",
              Self.isValidScopedMetadata(entry),
              entry.recoveryState == .ready,
              !entry.quarantined,
              let grantID = entry.grantID else {
            if entry.provider == "legacy-broad-token" || entry.recoveryState == .migrationRequired {
                throw CredentialBrokerError.legacyCredentialRequiresAuthorization
            }
            throw entry.quarantined || entry.recoveryState == .quarantined
                ? CredentialBrokerError.quarantineRequired
                : CredentialBrokerError.grantUnavailable
        }
        let data: Data
        do {
            data = try keychain.load(service: service(for: workspace, role: role), account: account(for: workspace, role: role))
        } catch {
            throw CredentialBrokerError.missingCredential
        }
        do {
            let credential = try Self.jsonDecoder().decode(ScopedInstallationCredential.self, from: data)
            guard credential.isStructurallyValid,
                  credential.grantID == grantID,
                  credential.generation == entry.generation,
                  Self.timestampsMatch(credential.accessExpiresAt, entry.accessExpiresAt) else {
                throw CredentialBrokerError.invalidCredential
            }
            return CredentialBundle(metadata: entry, credential: credential)
        } catch let error as CredentialBrokerError {
            throw error
        } catch {
            throw CredentialBrokerError.invalidCredential
        }
    }

    func storeScopedCredential(
        _ credential: ScopedInstallationCredential,
        workspace: String,
        accessMode: String,
        verificationRepository: String?,
        installationID: Int?,
        role: CredentialRole,
        accountLogin: String?,
        owner: String?,
        repositoryIDs: [Int],
        repositoryNames: [String],
        scopeDigest: String? = nil
    ) throws {
        guard WorkspaceID.isValid(workspace),
              credential.isStructurallyValid,
              !credential.isAccessExpired,
              (role == .guest && accessMode == "read-only") ||
                (role == .host && accessMode == "host-write"),
              let verificationRepository,
              Self.isValidRepositoryScope(
                repositoryNames,
                verificationRepository: verificationRepository
              ),
              let accountLogin,
              Self.isSafeGitHubIdentifier(accountLogin),
              let owner,
              Self.isSafeGitHubIdentifier(owner),
              installationID ?? 0 > 0,
              !repositoryIDs.isEmpty,
              repositoryIDs.count == Set(repositoryIDs).count,
              repositoryIDs.count == repositoryNames.count,
              repositoryIDs.allSatisfy({ $0 > 0 }) else {
            throw CredentialBrokerError.invalidCredential
        }
        let key = metadataKey(workspace, role)
        let previousMetadata = metadata[key]
        if let previousMetadata,
           previousMetadata.provider == "github-app-installation",
           previousMetadata.grantID == credential.grantID,
           credential.generation <= previousMetadata.generation {
            throw CredentialBrokerError.invalidCredential
        }
        let service = service(for: workspace, role: role)
        let account = account(for: workspace, role: role)
        let legacyService = Self.legacyService(for: role)
        let previousData = try? keychain.load(service: service, account: account)
        let previousLegacyData = try? keychain.load(service: legacyService, account: workspace)
        let entry = WorkspaceCredentialMetadata(
            workspace: workspace,
            role: role,
            provider: "github-app-installation",
            grantID: credential.grantID,
            scopeDigest: scopeDigest,
            accountLogin: accountLogin,
            owner: owner,
            repositoryIDs: repositoryIDs,
            repositoryNames: repositoryNames,
            accessMode: accessMode,
            verificationRepository: verificationRepository,
            installationID: installationID,
            accessExpiresAt: credential.accessExpiresAt,
            needsRestart: role == .guest,
            generation: credential.generation,
            quarantined: false,
            recoveryState: .ready,
            updatedAt: Date()
        )
        do {
            let data = try Self.jsonEncoder().encode(credential)
            // A scoped replacement is the only operation allowed to remove a
            // legacy broad token. Failure to delete it aborts the cutover.
            try keychain.delete(service: legacyService, account: workspace)
            try keychain.save(KeychainItem(service: service, account: account, secret: data))
            metadata[key] = entry
            try persistMetadata()
            audit.append(
                event: "grantStored",
                workspace: workspace,
                role: role,
                grantID: credential.grantID,
                detail: "scoped-installation-token"
            )
        } catch {
            metadata[key] = previousMetadata
            var rollbackSucceeded = true
            do {
                if let previousData {
                    try keychain.save(KeychainItem(service: service, account: account, secret: previousData))
                } else {
                    try keychain.delete(service: service, account: account)
                }
            } catch {
                rollbackSucceeded = false
            }
            do {
                if let previousLegacyData {
                    try keychain.save(KeychainItem(service: legacyService, account: workspace, secret: previousLegacyData))
                } else {
                    try keychain.delete(service: legacyService, account: workspace)
                }
            } catch {
                rollbackSucceeded = false
            }
            guard rollbackSucceeded else {
                var quarantined = previousMetadata ?? entry
                quarantined.quarantined = true
                quarantined.recoveryState = CredentialRecoveryState.quarantined
                quarantined.needsRestart = true
                quarantined.updatedAt = Date()
                metadata[key] = quarantined
                try? persistMetadata()
                throw CredentialBrokerError.quarantineRequired
            }
            throw CredentialBrokerError.metadataWriteFailed
        }
    }
    func updateScopedCredential(
        _ credential: ScopedInstallationCredential,
        workspace: String,
        role: CredentialRole
    ) throws {
        guard WorkspaceID.isValid(workspace),
              credential.isStructurallyValid,
              !credential.isAccessExpired else { throw CredentialBrokerError.invalidCredential }
        let key = metadataKey(workspace, role)
        guard var entry = metadata[key],
              entry.provider == "github-app-installation",
              Self.isValidScopedMetadata(entry),
              entry.grantID == credential.grantID,
              credential.generation > entry.generation,
              credential.accessExpiresAt > (entry.accessExpiresAt ?? .distantPast),
              !entry.quarantined else { throw CredentialBrokerError.grantUnavailable }
        let previous = entry
        let service = service(for: workspace, role: role)
        let account = account(for: workspace, role: role)
        let previousData = try? keychain.load(service: service, account: account)
        entry.accessExpiresAt = credential.accessExpiresAt
        entry.generation = credential.generation
        entry.recoveryState = .ready
        entry.updatedAt = Date()
        do {
            try keychain.save(KeychainItem(
                service: service,
                account: account,
                secret: try Self.jsonEncoder().encode(credential)
            ))
            metadata[key] = entry
            try persistMetadata()
            audit.append(
                event: "grantRenewed",
                workspace: workspace,
                role: role,
                grantID: credential.grantID,
                detail: "short-lived-token-replaced"
            )
        } catch {
            metadata[key] = previous
            var rollbackSucceeded = true
            do {
                if let previousData {
                    try keychain.save(KeychainItem(service: service, account: account, secret: previousData))
                } else {
                    try keychain.delete(service: service, account: account)
                }
            } catch {
                rollbackSucceeded = false
            }
            guard rollbackSucceeded else {
                var quarantined = previous
                quarantined.quarantined = true
                quarantined.recoveryState = .quarantined
                quarantined.needsRestart = true
                quarantined.updatedAt = Date()
                metadata[key] = quarantined
                try? persistMetadata()
                throw CredentialBrokerError.quarantineRequired
            }
            throw CredentialBrokerError.metadataWriteFailed
        }
    }
    /// Restores a previously captured scoped bundle during an authorization
    /// transaction rollback. The metadata and opaque Keychain payload must
    /// describe the same grant and generation.
    func restore(_ bundle: CredentialBundle) throws {
        let entry = bundle.metadata
        let credential = bundle.credential
        guard WorkspaceID.isValid(entry.workspace),
              entry.provider == "github-app-installation",
              Self.isValidScopedMetadata(entry),
              entry.grantID == credential.grantID,
              entry.generation == credential.generation,
              Self.timestampsMatch(credential.accessExpiresAt, entry.accessExpiresAt),
              credential.isStructurallyValid else {
            throw CredentialBrokerError.invalidCredential
        }
        let key = metadataKey(entry.workspace, entry.role)
        let previousMetadata = metadata[key]
        let service = service(for: entry.workspace, role: entry.role)
        let account = account(for: entry.workspace, role: entry.role)
        let previousData = try? keychain.load(service: service, account: account)
        do {
            let data = try Self.jsonEncoder().encode(credential)
            try keychain.save(KeychainItem(service: service, account: account, secret: data))
            metadata[key] = entry
            try persistMetadata()
        } catch {
            metadata[key] = previousMetadata
            if let previousData {
                try? keychain.save(KeychainItem(service: service, account: account, secret: previousData))
            } else {
                try? keychain.delete(service: service, account: account)
            }
            throw CredentialBrokerError.metadataWriteFailed
        }
    }


    func updateRecoveryState(
        workspace: String,
        role: CredentialRole = .guest,
        state: CredentialRecoveryState,
        quarantined: Bool? = nil
    ) throws {
        guard WorkspaceID.isValid(workspace) else { throw CredentialBrokerError.invalidWorkspace }
        let key = metadataKey(workspace, role)
        guard var entry = metadata[key] else { throw CredentialBrokerError.missingCredential }
        let previous = entry
        entry.recoveryState = state
        entry.quarantined = quarantined ?? (state == .quarantined || state == .migrationRequired)
        entry.updatedAt = Date()
        metadata[key] = entry
        do {
            try persistMetadata()
            audit.append(
                event: "recoveryStateChanged",
                workspace: workspace,
                role: role,
                grantID: entry.grantID,
                detail: "state=\(state.rawValue);quarantined=\(entry.quarantined)"
            )
        } catch {
            metadata[key] = previous
            throw CredentialBrokerError.metadataWriteFailed
        }
    }

    func markBound(workspace: String, role: CredentialRole = .guest) throws {
        guard WorkspaceID.isValid(workspace) else { throw CredentialBrokerError.invalidWorkspace }
        let key = metadataKey(workspace, role)
        guard var entry = metadata[key] else { throw CredentialBrokerError.missingCredential }
        entry.needsRestart = false
        entry.updatedAt = Date()
        try updateMetadata(entry)
    }

    func updateMetadata(_ entry: WorkspaceCredentialMetadata) throws {
        guard WorkspaceID.isValid(entry.workspace),
              entry.provider == "github-app-installation",
              entry.grantID != nil,
              Self.isValidScopedMetadata(entry) else {
            throw CredentialBrokerError.invalidCredential
        }
        let key = metadataKey(entry.workspace, entry.role)
        let previous = metadata[key]
        metadata[key] = entry
        do {
            try persistMetadata()
        } catch {
            metadata[key] = previous
            throw CredentialBrokerError.metadataWriteFailed
        }
    }

    /// Revocation is fail-closed: metadata is removed before secret cleanup. If
    /// Keychain deletion cannot be proven, a quarantined record is retained.
    func remove(workspace: String, role: CredentialRole = .guest) throws {
        guard WorkspaceID.isValid(workspace) else { throw CredentialBrokerError.invalidWorkspace }
        let key = metadataKey(workspace, role)
        let previous = metadata[key]
        let previousGrantID = previous?.grantID
        metadata.removeValue(forKey: key)
        do {
            try persistMetadata()
        } catch {
            metadata[key] = previous
            throw CredentialBrokerError.metadataWriteFailed
        }

        do {
            try keychain.delete(service: service(for: workspace, role: role), account: account(for: workspace, role: role))
            try keychain.delete(service: Self.legacyService(for: role), account: workspace)
            audit.append(
                event: "grantRevoked",
                workspace: workspace,
                role: role,
                grantID: previousGrantID,
                detail: "local-credential-removed"
            )
        } catch {
            if var previous {
                previous.quarantined = true
                previous.recoveryState = .quarantined
                previous.updatedAt = Date()
                metadata[key] = previous
                try? persistMetadata()
                audit.append(
                    event: "quarantined",
                    workspace: workspace,
                    role: role,
                    grantID: previousGrantID,
                    detail: "keychain-removal-unproven"
                )
            }
            throw CredentialBrokerError.quarantineRequired
        }
    }

    func removeAllRoles(workspace: String) throws {
        for role in CredentialRole.allCases {
            if metadata[metadataKey(workspace, role)] != nil {
                try remove(workspace: workspace, role: role)
            }
        }
    }

    func quarantine(workspace: String, role: CredentialRole = .guest) throws {
        guard WorkspaceID.isValid(workspace) else { throw CredentialBrokerError.invalidWorkspace }
        let key = metadataKey(workspace, role)
        let previous = metadata[key]
        let entry = previous ?? WorkspaceCredentialMetadata(
            workspace: workspace,
            role: role,
            accessMode: "unknown",
            verificationRepository: nil,
            installationID: nil,
            accessExpiresAt: nil,
            generation: 0,
            quarantined: true,
            recoveryState: .quarantined,
            updatedAt: Date()
        )
        var quarantined = entry
        quarantined.quarantined = true
        quarantined.recoveryState = .quarantined
        quarantined.updatedAt = Date()
        metadata[key] = quarantined
        do {
            try persistMetadata()
            audit.append(
                event: "quarantined",
                workspace: workspace,
                role: role,
                grantID: quarantined.grantID,
                detail: "credential-use-blocked"
            )
        } catch {
            metadata[key] = previous
            throw CredentialBrokerError.metadataWriteFailed
        }
    }

    func migrateLegacyMetadata(from legacyURL: URL) throws {
        guard !FileManager.default.fileExists(atPath: metadataURL.path),
              FileManager.default.fileExists(atPath: legacyURL.path) else { return }
        do {
            let legacy = try Self.jsonDecoder().decode(LegacyMetadataFile.self, from: Data(contentsOf: legacyURL))
            var migrated: [String: WorkspaceCredentialMetadata] = [:]
            for (workspace, value) in legacy.entries {
                guard WorkspaceID.isValid(workspace) else { throw CredentialBrokerError.migrationFailed }
                migrated[metadataKey(workspace, .guest)] = Self.makeLegacyEntry(workspace: workspace, value: value)
            }
            metadata = try Self.normalize(migrated)
            for entry in metadata.values {
                for role in CredentialRole.allCases {
                    try? keychain.delete(service: Self.legacyService(for: role), account: entry.workspace)
                }
            }
            try persistMetadata()
            try FileManager.default.moveItem(at: legacyURL, to: legacyURL.appendingPathExtension("migrated"))
        } catch let error as CredentialBrokerError {
            throw error
        } catch {
            throw CredentialBrokerError.migrationFailed
        }
    }

    private func metadataKey(_ workspace: String, _ role: CredentialRole) -> String {
        "\(workspace).\(role.rawValue)"
    }
    private static func isSafeMetadataValue(_ value: String) -> Bool {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 256 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F
        }
    }

    private static func isSafeGitHubIdentifier(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == value, trimmed.count <= 100 else { return false }
        return trimmed.allSatisfy { character in
            character.isLetter || character.isNumber || "-_.".contains(character)
        }
    }

    private static func isValidRepositoryScope(
        _ repositoryNames: [String],
        verificationRepository: String
    ) -> Bool {
        let normalized = repositoryNames.compactMap(normalizedRepositoryName)
        guard normalized.count == repositoryNames.count,
              !normalized.isEmpty,
              normalized.count == Set(normalized).count,
              normalized.allSatisfy({ isSafeRepositoryName($0) }),
              let verification = normalizedRepositoryName(verificationRepository),
              normalized.contains(verification) else {
            return false
        }
        return true
    }

    private static func normalizedRepositoryName(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              !parts[0].isEmpty,
              !parts[1].isEmpty else { return nil }
        return "\(parts[0])/\(parts[1])"
    }

    private static func isSafeRepositoryName(_ value: String) -> Bool {
        guard let normalized = normalizedRepositoryName(value) else { return false }
        return normalized.split(separator: "/").allSatisfy { component in
            component.allSatisfy { character in
                character.isLetter || character.isNumber || "-_.".contains(character)
            }
        }
    }
    private static func isValidScopedMetadata(_ value: WorkspaceCredentialMetadata) -> Bool {
        guard value.schemaVersion == currentSchemaVersion,
              value.provider == "github-app-installation",
              value.grantID != nil,
              Self.isSafeGitHubIdentifier(value.accountLogin ?? ""),
              Self.isSafeGitHubIdentifier(value.owner ?? ""),
              value.installationID ?? 0 > 0,
              !value.repositoryIDs.isEmpty,
              value.repositoryIDs.count == Set(value.repositoryIDs).count,
              value.repositoryIDs.allSatisfy({ $0 > 0 }),
              value.repositoryIDs.count == value.repositoryNames.count,
              let verificationRepository = value.verificationRepository,
              Self.isValidRepositoryScope(
                  value.repositoryNames,
                  verificationRepository: verificationRepository
              ),
              value.generation > 0,
              value.accessExpiresAt != nil else {
            return false
        }
        return (value.role == .guest && value.accessMode == "read-only") ||
            (value.role == .host && value.accessMode == "host-write")
    }
    private static func timestampsMatch(_ credentialDate: Date, _ metadataDate: Date?) -> Bool {
        guard let metadataDate else { return false }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(credentialDate)) == (try? encoder.encode(metadataDate))
    }



    private static func legacyService(for role: CredentialRole) -> String {
        role == .guest ? "msw.github.read" : "msw.github.write"
    }

    private func service(for workspace: String, role: CredentialRole) -> String {
        if let keychainServiceOverride { return keychainServiceOverride }
        return "msw.github.app.\(workspace).\(role.rawValue).tokens"
    }

    private func account(for workspace: String, role: CredentialRole) -> String {
        keychainServiceOverride == nil ? "profile" : "\(workspace).\(role.rawValue)"
    }

    private func persistMetadata() throws {
        try Self.persistMetadata(metadata, to: metadataURL)
    }

    private static func persistMetadata(_ metadata: [String: WorkspaceCredentialMetadata], to url: URL) throws {
        let file = MetadataFile(schemaVersion: currentSchemaVersion, entries: metadata)
        do {
            let data = try jsonEncoder().encode(file)
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw CredentialBrokerError.metadataWriteFailed
        }
    }

    private static func defaultMetadataURL() throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("MSW Monitor", isDirectory: true)
        return directory.appendingPathComponent("credentials.json")
    }

    private static func jsonEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func jsonDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self),
               let date = ISO8601DateFormatter().date(from: value) {
                return date
            }
            if let value = try? container.decode(Double.self) {
                return Date(timeIntervalSinceReferenceDate: value)
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected an ISO-8601 or reference-date value.")
        }
        return decoder
    }

    private static func readMetadata(from url: URL) throws -> [String: WorkspaceCredentialMetadata] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        do {
            let file = try jsonDecoder().decode(MetadataFile.self, from: Data(contentsOf: url))
            guard (1...currentSchemaVersion).contains(file.schemaVersion) else {
                throw CredentialBrokerError.migrationFailed
            }
            return file.entries
        } catch let error as CredentialBrokerError {
            throw error
        } catch {
            do {
                let legacy = try jsonDecoder().decode(LegacyMetadataFile.self, from: Data(contentsOf: url))
                var result: [String: WorkspaceCredentialMetadata] = [:]
                for (workspace, value) in legacy.entries {
                    guard WorkspaceID.isValid(workspace) else { throw CredentialBrokerError.migrationFailed }
                    result["\(workspace).guest"] = makeLegacyEntry(workspace: workspace, value: value)
                }
                return result
            } catch let error as CredentialBrokerError {
                throw error
            } catch {
                throw CredentialBrokerError.migrationFailed
            }
        }
    }

    private static func normalize(_ entries: [String: WorkspaceCredentialMetadata]) throws -> [String: WorkspaceCredentialMetadata] {
        var result: [String: WorkspaceCredentialMetadata] = [:]
        for (_, value) in entries {
            guard WorkspaceID.isValid(value.workspace) else { throw CredentialBrokerError.migrationFailed }
            let key = "\(value.workspace).\(value.role.rawValue)"
            guard result[key] == nil else { throw CredentialBrokerError.migrationFailed }
            var normalized = value
            let isExplicitQuarantine = value.quarantined &&
                value.recoveryState == .quarantined &&
                value.grantID == nil
            let isLegacy = !isExplicitQuarantine && (
                value.schemaVersion < currentSchemaVersion ||
                value.provider != "github-app-installation" ||
                value.grantID == nil
            )
            normalized.schemaVersion = currentSchemaVersion
            if isLegacy {
                // Preserve the fact that the record was broad. Never attach a
                // new grant ID or claim repositoryIDs were enforced.
                normalized.provider = "legacy-broad-token"
                normalized.grantID = nil
                normalized.quarantined = true
                normalized.recoveryState = .migrationRequired
                normalized.needsRestart = true
            } else if !isValidScopedMetadata(normalized) {
                // A current-schema record that fails the scope invariant is
                // unusable, even if its Keychain bytes look well formed.
                normalized.quarantined = true
                normalized.recoveryState = .quarantined
                normalized.needsRestart = true
            }
            result[key] = normalized
        }
        return result
    }

    private static func makeLegacyEntry(workspace: String, value: LegacyMetadataFile.LegacyEntry) -> WorkspaceCredentialMetadata {
        WorkspaceCredentialMetadata(
            workspace: workspace,
            schemaVersion: 1,
            provider: "legacy-broad-token",
            accountLogin: value.accountLogin,
            owner: value.owner,
            repositoryIDs: value.repositoryIDs,
            repositoryNames: value.repositoryNames,
            accessMode: value.accessMode ?? "unknown",
            verificationRepository: value.verificationRepository,
            installationID: value.installationID,
            accessExpiresAt: value.accessExpiresAt,
            needsRestart: true,
            generation: value.generation ?? 0,
            quarantined: true,
            recoveryState: .migrationRequired,
            updatedAt: value.updatedAt ?? Date()
        )
    }

    private struct MetadataFile: Codable, Equatable {
        let schemaVersion: Int
        let entries: [String: WorkspaceCredentialMetadata]
    }

    private struct LegacyMetadataFile: Codable {
        let entries: [String: LegacyEntry]

        struct LegacyEntry: Codable {
            let accountLogin: String?
            let owner: String?
            let repositoryIDs: [Int]
            let repositoryNames: [String]
            let accessMode: String?
            let verificationRepository: String?
            let installationID: Int?
            let accessExpiresAt: Date?
            let generation: Int?
            let updatedAt: Date?

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                accountLogin = try container.decodeIfPresent(String.self, forKey: .accountLogin)
                owner = try container.decodeIfPresent(String.self, forKey: .owner)
                repositoryIDs = try container.decodeIfPresent([Int].self, forKey: .repositoryIDs) ?? []
                repositoryNames = try container.decodeIfPresent([String].self, forKey: .repositoryNames) ?? []
                accessMode = try container.decodeIfPresent(String.self, forKey: .accessMode)
                verificationRepository = try container.decodeIfPresent(String.self, forKey: .verificationRepository)
                installationID = try container.decodeIfPresent(Int.self, forKey: .installationID)
                accessExpiresAt = try container.decodeIfPresent(Date.self, forKey: .accessExpiresAt)
                generation = try container.decodeIfPresent(Int.self, forKey: .generation)
                updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
            }

            private enum CodingKeys: String, CodingKey {
                case accountLogin, owner, repositoryIDs, repositoryNames, accessMode
                case verificationRepository, installationID, accessExpiresAt, generation, updatedAt
            }
        }
    }
}
