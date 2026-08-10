import Foundation

enum CredentialRole: String, Codable, Sendable, CaseIterable {
    case guest
    case host
}

struct WorkspaceCredentialMetadata: Codable, Sendable, Equatable, Identifiable {
    let workspace: String
    var schemaVersion: Int = 2
    var role: CredentialRole = .guest
    var provider: String = "github-app-user"
    var appClientID: String?
    var accountLogin: String?
    var owner: String?
    var repositoryIDs: [Int] = []
    var accessMode: String
    var verificationRepository: String?
    var installationID: Int?
    var accessExpiresAt: Date?
    var refreshExpiresAt: Date?
    var needsRestart: Bool = false
    var generation: Int
    var quarantined: Bool
    var updatedAt: Date

    var id: String { "\(workspace).\(role.rawValue)" }

    enum CodingKeys: String, CodingKey {
        case workspace, schemaVersion, role, provider, appClientID, accountLogin, owner, repositoryIDs
        case accessMode, verificationRepository, installationID, accessExpiresAt, refreshExpiresAt
        case needsRestart, generation, quarantined, updatedAt
    }

    init(
        workspace: String,
        schemaVersion: Int = 2,
        role: CredentialRole = .guest,
        provider: String = "github-app-user",
        appClientID: String? = nil,
        accountLogin: String? = nil,
        owner: String? = nil,
        repositoryIDs: [Int] = [],
        accessMode: String,
        verificationRepository: String?,
        installationID: Int?,
        accessExpiresAt: Date?,
        refreshExpiresAt: Date?,
        needsRestart: Bool = false,
        generation: Int,
        quarantined: Bool,
        updatedAt: Date
    ) {
        self.workspace = workspace
        self.schemaVersion = schemaVersion
        self.role = role
        self.provider = provider
        self.appClientID = appClientID
        self.accountLogin = accountLogin
        self.owner = owner
        self.repositoryIDs = repositoryIDs
        self.accessMode = accessMode
        self.verificationRepository = verificationRepository
        self.installationID = installationID
        self.accessExpiresAt = accessExpiresAt
        self.refreshExpiresAt = refreshExpiresAt
        self.needsRestart = needsRestart
        self.generation = generation
        self.quarantined = quarantined
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspace = try container.decode(String.self, forKey: .workspace)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        role = try container.decodeIfPresent(CredentialRole.self, forKey: .role) ?? .guest
        provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? "github-app-user"
        appClientID = try container.decodeIfPresent(String.self, forKey: .appClientID)
        accountLogin = try container.decodeIfPresent(String.self, forKey: .accountLogin)
        owner = try container.decodeIfPresent(String.self, forKey: .owner)
        repositoryIDs = try container.decodeIfPresent([Int].self, forKey: .repositoryIDs) ?? []
        accessMode = try container.decodeIfPresent(String.self, forKey: .accessMode) ?? "unknown"
        verificationRepository = try container.decodeIfPresent(String.self, forKey: .verificationRepository)
        installationID = try container.decodeIfPresent(Int.self, forKey: .installationID)
        accessExpiresAt = try container.decodeIfPresent(Date.self, forKey: .accessExpiresAt)
        refreshExpiresAt = try container.decodeIfPresent(Date.self, forKey: .refreshExpiresAt)
        needsRestart = try container.decodeIfPresent(Bool.self, forKey: .needsRestart) ?? false
        generation = try container.decodeIfPresent(Int.self, forKey: .generation) ?? 0
        quarantined = try container.decodeIfPresent(Bool.self, forKey: .quarantined) ?? false
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

struct CredentialBundle: Sendable, Equatable {
    let metadata: WorkspaceCredentialMetadata
    let tokens: GitHubTokenPair
}

enum CredentialBrokerError: Error, LocalizedError, Sendable, Equatable {
    case invalidWorkspace
    case invalidCredential
    case missingCredential
    case metadataWriteFailed
    case quarantineRequired
    case migrationFailed

    var errorDescription: String? {
        switch self {
        case .invalidWorkspace: return "The credential workspace identifier is invalid."
        case .invalidCredential: return "The GitHub credential record is malformed or has an invalid capability."
        case .missingCredential: return "No GitHub credential is configured for this workspace."
        case .metadataWriteFailed: return "Credential metadata could not be committed."
        case .quarantineRequired: return "The workspace is quarantined until its credentials are repaired."
        case .migrationFailed: return "Credential metadata migration could not be completed safely."
        }
    }
}

actor CredentialBroker {
    private static let currentSchemaVersion = 2
    private let keychain: KeychainStore
    private let metadataURL: URL
    private let keychainServiceOverride: String?
    private var metadata: [String: WorkspaceCredentialMetadata]

    init(
        keychain: KeychainStore = KeychainStore(),
        metadataURL: URL? = nil,
        keychainService: String = ""
    ) throws {
        self.keychain = keychain
        self.keychainServiceOverride = keychainService.isEmpty ? nil : keychainService
        let defaultURL = try Self.defaultMetadataURL()
        self.metadataURL = metadataURL ?? defaultURL
        self.metadata = try Self.readMetadata(from: self.metadataURL)
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
        guard let entry = metadata[key], !entry.quarantined else {
            throw metadata[key]?.quarantined == true ? CredentialBrokerError.quarantineRequired : CredentialBrokerError.missingCredential
        }
        let data: Data
        do {
            data = try keychain.load(service: service(for: workspace, role: role), account: account(for: workspace, role: role))
        } catch KeychainStoreError.itemNotFound where entry.provider == "legacy-pat" {
            // Legacy items are read only during the explicit migration window.
            do {
                data = try keychain.load(service: legacyService(for: role), account: workspace)
            } catch {
                throw CredentialBrokerError.missingCredential
            }
        } catch {
            throw CredentialBrokerError.missingCredential
        }
        do {
            let tokens = try Self.jsonDecoder().decode(GitHubTokenPair.self, from: data)
            guard tokens.isValid,
                  (entry.role == .guest && entry.accessMode == "read-only") ||
                    (entry.role == .host && entry.accessMode == "host-write") ||
                    entry.provider == "legacy-pat" else {
                throw CredentialBrokerError.invalidCredential
            }
            return CredentialBundle(metadata: entry, tokens: tokens)
        } catch let error as CredentialBrokerError {
            throw error
        } catch {
            throw CredentialBrokerError.missingCredential
        }
    }

    func store(
        tokens: GitHubTokenPair,
        workspace: String,
        accessMode: String,
        verificationRepository: String?,
        installationID: Int?,
        role: CredentialRole = .guest,
        appClientID: String? = nil,
        accountLogin: String? = nil,
        owner: String? = nil,
        repositoryIDs: [Int] = []
    ) throws {
        guard WorkspaceID.isValid(workspace) else { throw CredentialBrokerError.invalidWorkspace }
        guard tokens.isValid,
              (role == .guest && accessMode == "read-only") ||
                (role == .host && accessMode == "host-write") else {
            throw CredentialBrokerError.invalidCredential
        }
        let key = metadataKey(workspace, role)
        let account = account(for: workspace, role: role)
        let service = service(for: workspace, role: role)
        let oldData = try? keychain.load(service: service, account: account)
        let oldMetadata = metadata[key]
        let entry = WorkspaceCredentialMetadata(
            workspace: workspace,
            role: role,
            appClientID: appClientID,
            accountLogin: accountLogin,
            owner: owner,
            repositoryIDs: repositoryIDs,
            accessMode: accessMode,
            verificationRepository: verificationRepository,
            installationID: installationID,
            accessExpiresAt: tokens.accessExpiresAt,
            refreshExpiresAt: tokens.refreshExpiresAt,
            needsRestart: role == .guest,
            generation: tokens.generation,
            quarantined: false,
            updatedAt: Date()
        )
        do {
            let data = try Self.jsonEncoder().encode(tokens)
            try keychain.save(KeychainItem(service: service, account: account, secret: data))
            metadata[key] = entry
            try persistMetadata()
        } catch {
            metadata[key] = oldMetadata
            if let oldData {
                try? keychain.save(KeychainItem(service: service, account: account, secret: oldData))
            } else {
                try? keychain.delete(service: service, account: account)
            }
            throw CredentialBrokerError.metadataWriteFailed
        }
    }

    func updateMetadata(_ entry: WorkspaceCredentialMetadata) throws {
        guard WorkspaceID.isValid(entry.workspace) else { throw CredentialBrokerError.invalidWorkspace }
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

    func markBound(workspace: String, role: CredentialRole = .guest) throws {
        guard WorkspaceID.isValid(workspace) else { throw CredentialBrokerError.invalidWorkspace }
        let key = metadataKey(workspace, role)
        guard var entry = metadata[key] else { throw CredentialBrokerError.missingCredential }
        entry.needsRestart = false
        entry.updatedAt = Date()
        try updateMetadata(entry)
    }

    func remove(workspace: String, role: CredentialRole = .guest) throws {
        guard WorkspaceID.isValid(workspace) else { throw CredentialBrokerError.invalidWorkspace }
        let key = metadataKey(workspace, role)
        let previous = metadata[key]
        metadata.removeValue(forKey: key)
        do {
            try persistMetadata()
        } catch {
            metadata[key] = previous
            throw CredentialBrokerError.metadataWriteFailed
        }

        do {
            try keychain.delete(service: service(for: workspace, role: role), account: account(for: workspace, role: role))
            try keychain.delete(service: legacyService(for: role), account: workspace)
        } catch {
            // Metadata is already revoked. Preserve only a quarantined,
            // non-usable record so an uncertain cleanup cannot be mistaken for
            // a successfully removed credential.
            if var previous {
                previous.quarantined = true
                previous.updatedAt = Date()
                metadata[key] = previous
                try? persistMetadata()
            }
            throw CredentialBrokerError.quarantineRequired
        }
    }

    func removeAllRoles(workspace: String) throws {
        for role in CredentialRole.allCases { try remove(workspace: workspace, role: role) }
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
            refreshExpiresAt: nil,
            generation: 0,
            quarantined: true,
            updatedAt: Date()
        )
        var quarantined = entry
        quarantined.quarantined = true
        metadata[key] = quarantined
        do {
            try persistMetadata()
        } catch {
            metadata[key] = previous
            throw CredentialBrokerError.metadataWriteFailed
        }
    }
    func legacyCredentialPresent(workspace: String, role: CredentialRole) -> Bool {
        guard WorkspaceID.isValid(workspace) else { return false }
        return keychain.contains(service: legacyService(for: role), account: workspace)
    }

    func removeLegacyCredential(workspace: String, role: CredentialRole) throws {
        guard WorkspaceID.isValid(workspace) else { throw CredentialBrokerError.invalidWorkspace }
        try keychain.delete(service: legacyService(for: role), account: workspace)
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
            metadata = migrated
            try persistMetadata()
            try FileManager.default.moveItem(at: legacyURL, to: legacyURL.appendingPathExtension("migrated"))
        } catch let error as CredentialBrokerError {
            throw error
        } catch {
            throw CredentialBrokerError.migrationFailed
        }
    }

    private func legacyService(for role: CredentialRole) -> String {
        role == .guest ? "msw.github.read" : "msw.github.write"
    }

    private func metadataKey(_ workspace: String, _ role: CredentialRole) -> String { "\(workspace).\(role.rawValue)" }

    private func service(for workspace: String, role: CredentialRole) -> String {
        if let keychainServiceOverride {
            return keychainServiceOverride
        }
        return "msw.github.app.\(workspace).\(role.rawValue).tokens"
    }

    private func account(for workspace: String, role: CredentialRole) -> String {
        keychainServiceOverride == nil ? "profile" : "\(workspace).\(role.rawValue)"
    }

    private func persistMetadata() throws {
        let file = MetadataFile(schemaVersion: Self.currentSchemaVersion, entries: metadata)
        do {
            let data = try Self.jsonEncoder().encode(file)
            let directory = metadataURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try data.write(to: metadataURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadataURL.path)
        } catch {
            throw CredentialBrokerError.metadataWriteFailed
        }
    }

    private static func defaultMetadataURL() throws -> URL {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("MSW Monitor", isDirectory: true)
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
            let file = try Self.jsonDecoder().decode(MetadataFile.self, from: Data(contentsOf: url))
            guard (1...currentSchemaVersion).contains(file.schemaVersion) else {
                throw CredentialBrokerError.migrationFailed
            }
            return try normalize(file.entries)
        } catch {
            do {
                let legacy = try Self.jsonDecoder().decode(LegacyMetadataFile.self, from: Data(contentsOf: url))
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
            guard WorkspaceID.isValid(value.workspace),
                  (1...currentSchemaVersion).contains(value.schemaVersion) else {
                throw CredentialBrokerError.migrationFailed
            }
            let normalizedKey = "\(value.workspace).\(value.role.rawValue)"
            guard result[normalizedKey] == nil else { throw CredentialBrokerError.migrationFailed }
            var normalized = value
            normalized.schemaVersion = currentSchemaVersion
            result[normalizedKey] = normalized
        }
        return result
    }

    private static func makeLegacyEntry(workspace: String, value: LegacyMetadataFile.LegacyEntry) -> WorkspaceCredentialMetadata {
        WorkspaceCredentialMetadata(
            workspace: workspace,
            provider: "legacy-pat",
            accessMode: value.accessMode ?? "unknown",
            verificationRepository: value.verificationRepository,
            installationID: value.installationID,
            accessExpiresAt: value.accessExpiresAt,
            refreshExpiresAt: value.refreshExpiresAt,
            generation: value.generation ?? 0,
            quarantined: value.quarantined ?? false,
            updatedAt: value.updatedAt ?? Date()
        )
    }

    private struct MetadataFile: Codable {
        let schemaVersion: Int
        let entries: [String: WorkspaceCredentialMetadata]
    }

    private struct LegacyMetadataFile: Codable {
        let entries: [String: LegacyEntry]

        struct LegacyEntry: Codable {
            let accessMode: String?
            let verificationRepository: String?
            let installationID: Int?
            let accessExpiresAt: Date?
            let refreshExpiresAt: Date?
            let generation: Int?
            let quarantined: Bool?
            let updatedAt: Date?
        }
    }
}
