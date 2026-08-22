import AppKit
import CryptoKit
import Foundation

struct MSWConnectConfiguration: Sendable, Equatable {
    let baseURL: URL
    let clientID: String
    let redirectURL: URL
    let authorizationPath: String
    let callbackPath: String
    let installationURL: URL?
    let scopeAttestationPublicKey: Data?
    let requiresScopeAttestation: Bool

    init(
        baseURL: URL = URL(string: "https://connect.invalid")!,
        clientID: String = "",
        redirectURL: URL = URL(string: "msw://connect.microsandbox.dev/oauth/callback")!,
        authorizationPath: String = "/oauth/authorize",
        callbackPath: String = "/oauth/callback",
        installationURL: URL? = nil,
        scopeAttestationPublicKey: Data? = nil,
        requiresScopeAttestation: Bool = false
    ) {
        self.baseURL = baseURL
        self.clientID = clientID
        self.redirectURL = redirectURL
        self.authorizationPath = authorizationPath
        self.callbackPath = callbackPath
        self.installationURL = installationURL
        self.scopeAttestationPublicKey = scopeAttestationPublicKey
        self.requiresScopeAttestation = requiresScopeAttestation
    }
    private static func isSafeEndpointPath(_ value: String) -> Bool {
        !value.isEmpty &&
            value.first == "/" &&
            !value.contains("?") &&
            !value.contains("#") &&
            !value.contains("..") &&
            !value.contains("//") &&
            value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
    }

    private static func isSafeInstallationURL(_ value: URL) -> Bool {
        value.scheme?.lowercased() == "https" &&
            value.host?.lowercased() == "github.com" &&
            value.user == nil &&
            value.password == nil &&
            value.port == nil &&
            value.query == nil &&
            value.fragment == nil &&
            value.path.hasPrefix("/apps/") &&
            value.path.hasSuffix("/installations/new") &&
            isSafeEndpointPath(value.path)
    }

    var isConfigured: Bool {
        guard !clientID.isEmpty,
              baseURL.host?.lowercased() != "connect.invalid" else {
            return false
        }
        do {
            try validate()
            return true
        } catch {
            return false
        }
    }

    /// Repository access is offered only when the release supplies a trusted
    /// signing key and therefore requires token-bound scope attestations.
    var hasTrustedScopeAttestation: Bool {
        requiresScopeAttestation && Self.isValidScopeAttestationKey(scopeAttestationPublicKey)
    }


    func validate() throws {
        guard Self.isSafeClientID(clientID),
              let scheme = baseURL.scheme?.lowercased(),
              scheme == "https" || (scheme == "http" && baseURL.host?.isLoopback == true),
              baseURL.host != nil,
              baseURL.user == nil,
              baseURL.password == nil,
              baseURL.port == nil,
              baseURL.query == nil,
              baseURL.fragment == nil,
              baseURL.path.isEmpty || baseURL.path == "/",
              Self.isSafeEndpointPath(authorizationPath),
              Self.isSafeEndpointPath(callbackPath),
              callbackPath == redirectURL.path,
              installationURL.map(Self.isSafeInstallationURL) ?? true,
              let redirectScheme = redirectURL.scheme?.lowercased(),
              redirectScheme == "msw",
              redirectURL.user == nil,
              redirectURL.password == nil,
              redirectURL.port == nil,
              redirectURL.query == nil,
              redirectURL.fragment == nil,
              redirectURL.path == "/oauth/callback",
              redirectURL.host?.lowercased() == "connect.microsandbox.dev",
              !requiresScopeAttestation || Self.isValidScopeAttestationKey(scopeAttestationPublicKey) else {
            throw MSWConnectError.invalidConfiguration
        }
    }

    private static func isValidScopeAttestationKey(_ value: Data?) -> Bool {
        guard let value, value.count == 32 else { return false }
        return (try? Curve25519.Signing.PublicKey(rawRepresentation: value)) != nil
    }

    private static func isSafeClientID(_ value: String) -> Bool {
        !value.isEmpty &&
            value.count <= 128 &&
            value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0)
            }
    }

    var callbackScheme: String { redirectURL.scheme ?? "msw" }
}

enum MSWConnectError: Error, LocalizedError, Sendable, Equatable {
    case invalidConfiguration
    case invalidCallback
    case callbackStateMismatch
    case callbackExpired
    case callbackReplayed
    case authorizationDenied(String?)
    case cancelled
    case transportUnavailable
    case httpStatus(Int)
    case malformedResponse
    case sessionExpired
    case sessionCleanupFailed
    case grantNotFound
    case grantRevoked
    case scopeMismatch
    case scopeAttestationMissing
    case scopeAttestationInvalid
    case accountBoundaryViolation
    case repositoryNotAllowed
    case installationUnavailable
    case installationRemoved
    case rateLimited(Int?)
    case serviceValidation(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "GitHub connection couldn’t start."
        case .invalidCallback, .callbackStateMismatch, .callbackReplayed:
            return "GitHub connection could not be completed. Try again."
        case .callbackExpired:
            return "The GitHub connection expired. Try again."
        case .authorizationDenied(let reason):
            return reason.map { "GitHub authorization was denied: \($0)" } ?? "GitHub authorization was denied."
        case .cancelled:
            return "GitHub authorization was cancelled."
        case .transportUnavailable, .httpStatus:
            return "GitHub could not be reached. Check your connection and try again."
        case .malformedResponse:
            return "GitHub returned an unexpected response. Try again."
        case .sessionExpired:
            return "Your GitHub sign-in expired. Connect GitHub again."
        case .sessionCleanupFailed:
            return "GitHub access needs reconnecting."
        case .grantNotFound, .grantRevoked:
            return "Existing GitHub access needs reconnecting."
        case .scopeMismatch, .scopeAttestationMissing, .scopeAttestationInvalid:
            return "GitHub returned access that did not match your choices. Existing access stayed unchanged."
        case .accountBoundaryViolation, .repositoryNotAllowed:
            return "One or more selected repositories are no longer available. Refresh repository access, then reconnect."
        case .installationUnavailable, .installationRemoved:
            return "The selected repositories are no longer available. Refresh repository access, then reconnect."
        case .rateLimited(let retryAfter):
            if let retryAfter {
                return "GitHub is busy. Try again in \(retryAfter) seconds."
            }
            return "GitHub is busy. Try again later."
        case .serviceValidation:
            return "GitHub access could not be completed. Try again."
        }
    }
}

protocol MSWConnectHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionMSWConnectTransport: MSWConnectHTTPTransport, Sendable {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw MSWConnectError.transportUnavailable
            }
            return (data, httpResponse)
        } catch let error as MSWConnectError {
            throw error
        } catch is CancellationError {
            throw MSWConnectError.cancelled
        } catch {
            throw MSWConnectError.transportUnavailable
        }
    }
}

@MainActor
protocol MSWConnectBrowserAuthenticating: Sendable {
    func authenticate(url: URL, callbackScheme: String) async throws -> URL
}

/// Opens the Connect authorization page in the user's default browser and
/// resumes when macOS delivers the `msw://` callback URL to the app.
///
/// The wait is bound to the exact authorization it opened: the expected
/// callback scheme, host, path, and `state` are parsed from the authorize URL,
/// and any other callback is ignored. A stale tab from a cancelled attempt
/// therefore cannot terminate the retry that replaced it.
@MainActor
final class MSWConnectBrowser: MSWConnectBrowserAuthenticating, @unchecked Sendable {
    /// Single shared instance. The app delegate routes `msw://` URL events to
    /// this instance, so any pending authorization must live here rather than
    /// in a view-local instance.
    static let shared = MSWConnectBrowser()

    private struct ExpectedCallback {
        let scheme: String
        let host: String
        let path: String
        let state: String

        init?(authorizeURL: URL, scheme: String) {
            guard let components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false),
                  let state = components.queryItems?.first(where: { $0.name == "state" })?.value,
                  !state.isEmpty,
                  let redirect = components.queryItems?.first(where: { $0.name == "redirect_uri" })?.value,
                  let redirectComponents = URLComponents(string: redirect),
                  let host = redirectComponents.host?.lowercased(),
                  !host.isEmpty else {
                return nil
            }
            self.scheme = scheme.lowercased()
            self.host = host
            self.path = redirectComponents.path
            self.state = state
        }

        func matches(_ callback: URL) -> Bool {
            guard callback.scheme?.lowercased() == scheme,
                  callback.host?.lowercased() == host,
                  callback.path == path,
                  let components = URLComponents(url: callback, resolvingAgainstBaseURL: false),
                  let state = components.queryItems?.first(where: { $0.name == "state" })?.value else {
                return false
            }
            return state == self.state
        }
    }

    private let opener: (URL) -> Bool
    private var continuation: CheckedContinuation<URL, Error>?
    private var generation = 0
    private var expectedCallback: ExpectedCallback?
    private var timeoutTask: Task<Void, Never>?

    /// The authorization page expires after ten minutes
    /// (`MSWConnectClient.startAuthorization`), so abandon the wait at the
    /// same point rather than hanging forever on a browser tab nobody returns to.
    private static let callbackTimeout: Duration = .seconds(600)

    init(opener: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.opener = opener
    }

    /// True while a callback wait is installed. Test support.
    var isWaiting: Bool { continuation != nil }

    /// The `state` value of the callback currently being waited for. Test support.
    var expectedState: String? { expectedCallback?.state }

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        guard !Task.isCancelled else {
            throw MSWConnectError.cancelled
        }
        guard let expected = ExpectedCallback(authorizeURL: url, scheme: callbackScheme) else {
            throw MSWConnectError.invalidConfiguration
        }
        // Displace any previous attempt's wait before installing this one, so
        // a cancel/retry cannot leave two generations competing for the slot.
        clearPending()
        generation &+= 1
        let currentGeneration = generation
        expectedCallback = expected

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard expectedCallback != nil, self.continuation == nil else {
                    continuation.resume(throwing: MSWConnectError.cancelled)
                    return
                }
                self.continuation = continuation
                guard opener(url) else {
                    complete(.failure(MSWConnectError.transportUnavailable))
                    return
                }
                timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: Self.callbackTimeout)
                    guard !Task.isCancelled else { return }
                    self?.fail(generation: currentGeneration, with: MSWConnectError.callbackExpired)
                }
            }
        }, onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(generation: currentGeneration)
            }
        })
    }

    /// Handles a URL event delivered to the app. Returns true when this
    /// browser consumed the URL; otherwise the caller may ignore it. A URL
    /// that does not match the pending authorization (wrong scheme, host,
    /// path, or state) is left untouched so the correct callback can arrive.
    @discardableResult
    func handleCallback(_ url: URL) -> Bool {
        guard let expected = expectedCallback, continuation != nil, expected.matches(url) else {
            return false
        }
        complete(.success(url))
        return true
    }

    private func clearPending() {
        timeoutTask?.cancel()
        timeoutTask = nil
        expectedCallback = nil
        complete(.failure(MSWConnectError.cancelled))
    }

    private func cancel(generation: Int) {
        guard generation == self.generation else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        complete(.failure(MSWConnectError.cancelled))
    }

    private func fail(generation: Int, with error: Error) {
        guard generation == self.generation else { return }
        timeoutTask = nil
        complete(.failure(error))
    }

    private func complete(_ result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        expectedCallback = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        switch result {
        case .success(let callbackURL):
            continuation.resume(returning: callbackURL)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

protocol MSWConnectKeychainStoring: CredentialKeychainStoring {}

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

    enum CodingKeys: String, CodingKey {
        case id
        case account
        case repositorySelection = "repository_selection"
    }

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
    /// Local mode only: whether the host credential may push to this repo
    /// (GitHub `permissions.push`). Nil in Connect mode.
    var canPush: Bool? = nil
    /// Local mode only: whether the repo is already ticked in the policy file.
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

    /// The effective access mode when the host credential cannot push to this
    /// repository: write access is never offered or committed for
    /// push-denied repos (nil = no restriction, e.g. Connect mode).
    func effectiveMode(_ requested: GitHubRepositoryAccessMode) -> GitHubRepositoryAccessMode {
        canPush == false ? .readOnly : requested
    }
}



struct MSWConnectAuthorizationStart: Sendable, Equatable {
    let url: URL
    let state: String
    let codeVerifier: String
    let expiresAt: Date
}

struct MSWConnectSession: Sendable, Equatable {
    let sessionID: UUID
    let opaqueServiceToken: String
    let account: GitHubAccount
    let expiresAt: Date
}
struct MSWConnectScopeAttestation: Codable, Sendable, Equatable {
    let digest: String
    let signature: String
    let keyID: String

    enum CodingKeys: String, CodingKey {
        case digest
        case signature
        case keyID = "key_id"
    }
}

struct MSWConnectRevocationReceipt: Codable, Sendable, Equatable {
    let grantID: UUID
    let revoked: Bool
    let terminal: Bool
    let revokedAt: Date?

    enum CodingKeys: String, CodingKey {
        case grantID = "grant_id"
        case revoked
        case terminal
        case revokedAt = "revoked_at"
    }
}

struct MSWConnectDisconnectReceipt: Codable, Sendable, Equatable {
    let revokedGrantIDs: [UUID]
    let terminal: Bool

    enum CodingKeys: String, CodingKey {
        case revokedGrantIDs = "revoked_grant_ids"
        case terminal
    }
}

struct MSWConnectGrantAssignment: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let workspace: String
    let role: CredentialRole
    let owner: String
    let installationID: Int
    let repositoryIDs: [Int]
    let repositoryNames: [String]
    let accessMode: String
    let verificationRepository: String

    init(
        id: UUID = UUID(),
        workspace: String,
        role: CredentialRole,
        owner: String,
        installationID: Int,
        repositoryIDs: [Int],
        repositoryNames: [String],
        accessMode: String,
        verificationRepository: String
    ) {
        self.id = id
        self.workspace = workspace
        self.role = role
        self.owner = owner
        self.installationID = installationID
        self.repositoryIDs = repositoryIDs
        self.repositoryNames = repositoryNames
        self.accessMode = accessMode
        self.verificationRepository = verificationRepository
    }
    enum CodingKeys: String, CodingKey {
        case id
        case workspace, role, owner
        case installationID = "installation_id"
        case repositoryIDs = "repository_ids"
        case repositoryNames = "repository_names"
        case accessMode = "access_mode"
        case verificationRepository = "verification_repository"
    }
}

struct MSWConnectGrant: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let workspace: String
    let role: CredentialRole
    let accountLogin: String
    let owner: String
    let installationID: Int
    let repositoryIDs: [Int]
    let repositoryNames: [String]
    let accessMode: String
    let verificationRepository: String
    let accessToken: String
    let accessExpiresAt: Date
    let generation: Int
    let issuedAt: Date?
    let scopeDigest: String?
    let scopeSignature: String?
    let scopeKeyID: String?
    let credentialDigest: String?

    enum CodingKeys: String, CodingKey {
        case id = "grant_id"
        case workspace, role, accountLogin = "account_login", owner
        case installationID = "installation_id"
        case repositoryIDs = "repository_ids"
        case repositoryNames = "repository_names"
        case accessMode = "access_mode"
        case verificationRepository = "verification_repository"
        case accessToken = "access_token"
        case accessExpiresAt = "access_expires_at"
        case generation
        case issuedAt = "issued_at"
        case scopeDigest = "scope_digest"
        case scopeSignature = "scope_signature"
        case scopeKeyID = "scope_key_id"
        case credentialDigest = "credential_digest"
    }

    init(
        id: UUID,
        workspace: String,
        role: CredentialRole,
        accountLogin: String,
        owner: String,
        installationID: Int,
        repositoryIDs: [Int],
        repositoryNames: [String],
        accessMode: String,
        verificationRepository: String,
        accessToken: String,
        accessExpiresAt: Date,
        generation: Int,
        issuedAt: Date? = nil,
        scopeDigest: String? = nil,
        scopeSignature: String? = nil,
        scopeKeyID: String? = nil,
        credentialDigest: String? = nil
    ) {
        self.id = id
        self.workspace = workspace
        self.role = role
        self.accountLogin = accountLogin
        self.owner = owner
        self.installationID = installationID
        self.repositoryIDs = repositoryIDs
        self.repositoryNames = repositoryNames
        self.accessMode = accessMode
        self.verificationRepository = verificationRepository
        self.accessToken = accessToken
        self.accessExpiresAt = accessExpiresAt
        self.generation = generation
        self.issuedAt = issuedAt
        self.scopeDigest = scopeDigest
        self.scopeSignature = scopeSignature
        self.scopeKeyID = scopeKeyID
        self.credentialDigest = credentialDigest
    }

    var credential: ScopedInstallationCredential {
        ScopedInstallationCredential(
            grantID: id,
            accessToken: accessToken,
            accessExpiresAt: accessExpiresAt,
            generation: generation
        )
    }
}

actor MSWConnectClient {
    let configuration: MSWConnectConfiguration
    private let transport: any MSWConnectHTTPTransport
    private let keychain: any MSWConnectKeychainStoring
    private let now: @Sendable () -> Date
    private let sessionService: String
    private let sessionAccount: String
    private var pending: [String: PendingAuthorization]
    private var consumedStates: Set<String>
    private var session: MSWConnectSession?

    private struct PendingAuthorization: Sendable {
        let codeVerifier: String
        let expiresAt: Date
    }

    init(
        configuration: MSWConnectConfiguration = MSWConnectConfiguration(),
        transport: any MSWConnectHTTPTransport = URLSessionMSWConnectTransport(),
        keychain: any MSWConnectKeychainStoring = KeychainStore(),
        now: @escaping @Sendable () -> Date = Date.init,
        sessionService: String = "org.microsandbox.MSWMonitor.connect-session",
        sessionAccount: String = "session"
    ) {
        self.configuration = configuration
        self.transport = transport
        self.keychain = keychain
        self.now = now
        self.sessionService = sessionService
        self.sessionAccount = sessionAccount
        self.pending = [:]
        self.consumedStates = []
        self.session = nil
    }

    func startAuthorization() throws -> MSWConnectAuthorizationStart {
        try configuration.validate()
        let currentDate = now()
        pending = pending.filter { $0.value.expiresAt > currentDate }
        if pending.count >= 64 {
            let expiredOrOld = pending.sorted { $0.value.expiresAt < $1.value.expiresAt }
            for (state, _) in expiredOrOld.prefix(pending.count - 63) {
                pending.removeValue(forKey: state)
            }
        }
        let state = Self.randomURLSafeString(byteCount: 32)
        let verifier = Self.randomURLSafeString(byteCount: 48)
        let expiresAt = currentDate.addingTimeInterval(10 * 60)
        pending[state] = PendingAuthorization(codeVerifier: verifier, expiresAt: expiresAt)
        var components = URLComponents(
            url: configuration.baseURL.appendingPathComponent(configuration.authorizationPath),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURL.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: Self.pkceChallenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        guard let url = components?.url else { throw MSWConnectError.invalidConfiguration }
        return MSWConnectAuthorizationStart(url: url, state: state, codeVerifier: verifier, expiresAt: expiresAt)
    }


    func authorize(browser: MSWConnectBrowserAuthenticating) async throws -> GitHubAuthorizationDiscovery {
        try configuration.validate()
        if let restored = try restoreSession() {
            let installations = try await self.installations()
            return GitHubAuthorizationDiscovery(
                sessionID: restored.sessionID,
                account: restored.account,
                installations: installations
            )
        }
        let start = try startAuthorization()
        do {
            let callback = try await browser.authenticate(url: start.url, callbackScheme: configuration.callbackScheme)
            let connected = try await completeAuthorization(callbackURL: callback)
            let installations = try await self.installations()
            return GitHubAuthorizationDiscovery(
                sessionID: connected.sessionID,
                account: connected.account,
                installations: installations
            )
        } catch {
            pending.removeValue(forKey: start.state)
            throw error
        }
    }

    func completeAuthorization(callbackURL: URL) async throws -> MSWConnectSession {
        try configuration.validate()
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              callbackURL.scheme?.lowercased() == configuration.redirectURL.scheme?.lowercased(),
              callbackURL.host?.lowercased() == configuration.redirectURL.host?.lowercased(),
              callbackURL.port == configuration.redirectURL.port,
              callbackURL.path == configuration.redirectURL.path,
              callbackURL.user == nil,
              callbackURL.password == nil,
              components.fragment == nil,
              let queryItems = components.queryItems,
              queryItems.filter({ $0.name == "state" }).count == 1,
              let state = queryItems.first(where: { $0.name == "state" })?.value,
              !state.isEmpty else {
            throw MSWConnectError.invalidCallback
        }
        guard let authorization = pending.removeValue(forKey: state) else {
            if consumedStates.contains(state) {
                throw MSWConnectError.callbackReplayed
            }
            throw MSWConnectError.callbackStateMismatch
        }
        consumedStates.insert(state)
        if consumedStates.count > 1024 {
            consumedStates.removeAll(keepingCapacity: true)
            consumedStates.insert(state)
        }
        guard authorization.expiresAt > now() else {
            throw MSWConnectError.callbackExpired
        }
        let codeItems = queryItems.filter { $0.name == "code" }
        let errorItems = queryItems.filter { $0.name == "error" || $0.name == "error_description" }
        guard codeItems.count <= 1 else { throw MSWConnectError.invalidCallback }
        if codeItems.first?.value != nil, !errorItems.isEmpty {
            throw MSWConnectError.invalidCallback
        }
        guard let code = codeItems.first?.value, !code.isEmpty else {
            let reason = errorItems.first(where: { $0.name == "error_description" })?.value
                ?? errorItems.first(where: { $0.name == "error" })?.value
            throw MSWConnectError.authorizationDenied(reason)
        }

        var request = try makeRequest(path: configuration.callbackPath, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encoder.encode(CallbackExchange(
            code: code,
            state: state,
            codeVerifier: authorization.codeVerifier,
            redirectURI: configuration.redirectURL.absoluteString
        ))
        let response: CallbackResponse = try await send(request)
        let connected = MSWConnectSession(
            sessionID: response.sessionID,
            opaqueServiceToken: response.sessionToken,
            account: response.account,
            expiresAt: response.expiresAt
        )
        guard Self.isSafeServiceToken(connected.opaqueServiceToken),
              connected.account.id > 0,
              Self.isSafeGitHubIdentifier(connected.account.login),
              connected.expiresAt > now() else {
            throw MSWConnectError.malformedResponse
        }
        try persistSession(connected)
        session = connected
        return connected
    }

    func restoreSession() throws -> MSWConnectSession? {
        let data: Data
        do {
            data = try keychain.load(service: sessionService, account: sessionAccount)
        } catch KeychainStoreError.itemNotFound {
            return nil
        } catch {
            throw MSWConnectError.transportUnavailable
        }
        do {
            let stored = try Self.decoder.decode(StoredSession.self, from: data)
            guard stored.issuer == configuration.baseURL.absoluteString,
                  stored.clientID == configuration.clientID,
                  stored.redirectURI == configuration.redirectURL.absoluteString else {
                // A session minted by another configuration — or read by an
                // unconfigured build whose sentinel base URL can never match —
                // must be retained, never deleted: the owning configuration
                // can still restore it later.
                return nil
            }
            guard stored.expiresAt > now() else {
                try keychain.delete(service: sessionService, account: sessionAccount)
                return nil
            }
            guard Self.isSafeServiceToken(stored.sessionToken),
                  stored.account.id > 0,
                  Self.isSafeGitHubIdentifier(stored.account.login) else {
                try keychain.delete(service: sessionService, account: sessionAccount)
                throw MSWConnectError.malformedResponse
            }
            let restored = MSWConnectSession(
                sessionID: stored.sessionID,
                opaqueServiceToken: stored.sessionToken,
                account: stored.account,
                expiresAt: stored.expiresAt
            )
            session = restored
            return restored
        } catch let error as MSWConnectError {
            throw error
        } catch {
            throw MSWConnectError.malformedResponse
        }
    }
    func currentSession() -> MSWConnectSession? {
        guard let session, session.expiresAt > now() else { return nil }
        return session
    }

    func disconnectAccount(expectedGrantIDs: [UUID] = []) async throws {
        try await revokeAccount(expectedGrantIDs: expectedGrantIDs)
        try clearSession()
    }

    /// Revokes the service-side workspace grants but keeps the local Connect
    /// session available until the caller has completed local credential
    /// cleanup.
    func revokeAccount(expectedGrantIDs: [UUID] = []) async throws {
        let connected = try requiredSession()
        var request = try makeAuthorizedRequest(path: "/v1/session/revoke", method: "POST", session: connected)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encoder.encode(DisconnectRequest(grantIDs: expectedGrantIDs))
        let receipt: MSWConnectDisconnectReceipt = try await send(request)
        guard receipt.terminal,
              Set(expectedGrantIDs).isSubset(of: Set(receipt.revokedGrantIDs)) else {
            throw MSWConnectError.malformedResponse
        }
    }

    func clearSession() throws {
        do {
            try keychain.delete(service: sessionService, account: sessionAccount)
        } catch {
            throw MSWConnectError.sessionCleanupFailed
        }
        session = nil
    }

    func installations() async throws -> [GitHubInstallation] {
        let response: InstallationResponse = try await sendAuthorized(
            path: "/v1/installations",
            method: "GET"
        )
        let installations = response.installations
        guard installations.count == Set(installations.map(\.id)).count,
              installations.allSatisfy(Self.isValidInstallationResponse) else {
            throw MSWConnectError.accountBoundaryViolation
        }
        return installations
    }

    func repositories(installationID: Int) async throws -> [GitHubRepository] {
        guard installationID > 0 else { throw MSWConnectError.installationUnavailable }
        let path = "/v1/installations/\(installationID)/repositories"
        let response: RepositoryResponse = try await sendAuthorized(path: path, method: "GET")
        let repositories = response.repositories
        guard repositories.count == Set(repositories.map(\.id)).count,
              repositories.allSatisfy(Self.isValidRepositoryResponse) else {
            throw MSWConnectError.accountBoundaryViolation
        }
        return repositories
    }

    func createGrant(_ assignment: MSWConnectGrantAssignment) async throws -> MSWConnectGrant {
        let normalizedNames = assignment.repositoryNames.map(Self.normalizedRepositoryName)
        let normalizedVerification = Self.normalizedRepositoryName(assignment.verificationRepository)
        let roleMatchesAccessMode =
            (assignment.role == .guest && assignment.accessMode == "read-only") ||
            (assignment.role == .host && assignment.accessMode == "host-write")
        guard WorkspaceID.isValid(assignment.workspace),
              Self.isSafeGitHubIdentifier(assignment.owner),
              assignment.installationID > 0,
              roleMatchesAccessMode,
              !assignment.repositoryIDs.isEmpty,
              assignment.repositoryIDs.count == Set(assignment.repositoryIDs).count,
              assignment.repositoryIDs.count == assignment.repositoryNames.count,
              assignment.repositoryIDs.allSatisfy({ $0 > 0 }),
              normalizedNames.count == Set(normalizedNames).count,
              normalizedNames.allSatisfy(Self.isSafeRepositoryName),
              normalizedNames.contains(normalizedVerification),
              Self.isSafeRepositoryName(assignment.verificationRepository) else {
            throw GitHubAuthorizationError.invalidSelection
        }
        let connected = try requiredSession()
        let body = try Self.encoder.encode(assignment)
        var request = try makeAuthorizedRequest(path: "/v1/grants", method: "POST", session: connected)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let grant: MSWConnectGrant = try await send(request)
        let grantNames = grant.repositoryNames.map(Self.normalizedRepositoryName)
        guard grant.workspace == assignment.workspace,
              grant.role == assignment.role,
              Self.isSafeGitHubIdentifier(grant.accountLogin),
              grant.accountLogin.caseInsensitiveCompare(connected.account.login) == .orderedSame,
              Self.isSafeGitHubIdentifier(grant.owner),
              grant.owner.caseInsensitiveCompare(assignment.owner) == .orderedSame,
              grant.installationID == assignment.installationID,
              grant.accessMode == assignment.accessMode,
              Self.isSafeRepositoryName(grant.verificationRepository),
              Self.normalizedRepositoryName(grant.verificationRepository) == normalizedVerification,
              grant.repositoryIDs.count == assignment.repositoryIDs.count,
              grant.repositoryIDs.count == Set(grant.repositoryIDs).count,
              grant.repositoryIDs.allSatisfy({ $0 > 0 }),
              Set(grant.repositoryIDs) == Set(assignment.repositoryIDs),
              grant.repositoryNames.count == assignment.repositoryNames.count,
              grantNames.allSatisfy({ normalizedNames.contains($0) }),
              Set(grantNames) == Set(normalizedNames),
              grant.repositoryNames.allSatisfy(Self.isSafeRepositoryName),
              assignment.repositoryIDs.allSatisfy({ grant.repositoryIDs.contains($0) }) else {
            throw MSWConnectError.scopeMismatch
        }
        guard grant.credential.isStructurallyValid,
              Self.isValidGrantLifetime(grant, now: now()) else {
            throw MSWConnectError.malformedResponse
        }
        try validateScopeAttestation(grant: grant, assignment: assignment)
        return grant
    }

    private func validateScopeAttestation(
        grant: MSWConnectGrant,
        assignment: MSWConnectGrantAssignment
    ) throws {
        let expectedDigest = Self.scopeDigest(assignment)
        guard Self.scopeDigest(grant) == expectedDigest else {
            throw MSWConnectError.scopeMismatch
        }
        if let grantDigest = grant.scopeDigest, grantDigest != expectedDigest {
            throw MSWConnectError.scopeMismatch
        }
        let hasAttestationFields = grant.scopeDigest != nil ||
            grant.scopeSignature != nil ||
            grant.scopeKeyID != nil ||
            grant.credentialDigest != nil
        guard configuration.requiresScopeAttestation || hasAttestationFields else { return }
        guard let digest = grant.scopeDigest,
              let signatureValue = grant.scopeSignature,
              let keyID = grant.scopeKeyID,
              let credentialDigest = grant.credentialDigest else {
            throw configuration.requiresScopeAttestation
                ? MSWConnectError.scopeAttestationMissing
                : MSWConnectError.scopeAttestationInvalid
        }
        guard digest == expectedDigest,
              Self.isSafeGitHubIdentifier(keyID),
              Self.isValidCredentialDigest(credentialDigest),
              credentialDigest == Self.tokenDigest(grant.accessToken),
              let issuedAt = grant.issuedAt,
              grant.accessExpiresAt > issuedAt,
              grant.accessExpiresAt <= issuedAt.addingTimeInterval(2 * 60 * 60),
              issuedAt <= now(),
              let signedPayload = Self.scopeAttestationPayload(
                grant: grant,
                scopeDigest: digest,
                credentialDigest: credentialDigest
              ),
              let signature = Data(base64Encoded: signatureValue),
              let publicKeyData = configuration.scopeAttestationPublicKey,
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData),
              publicKey.isValidSignature(signature, for: signedPayload) else {
            throw MSWConnectError.scopeAttestationInvalid
        }
    }

    private func requiredSession() throws -> MSWConnectSession {
        if let session, session.expiresAt > now() { return session }
        if let restored = try restoreSession() {
            return restored
        }
        throw MSWConnectError.sessionExpired
    }

    func renewGrant(
        grantID: UUID,
        expectedScope: MSWConnectGrantAssignment? = nil
    ) async throws -> MSWConnectGrant {
        let connected = try requiredSession()
        var request = try makeAuthorizedRequest(
            path: "/v1/grants/\(grantID.uuidString)",
            method: "POST",
            session: connected
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encoder.encode(GrantRenewalRequest(
            grantID: grantID,
            scopeDigest: expectedScope.map(Self.scopeDigest)
        ))
        do {
            let grant: MSWConnectGrant = try await send(request)
            guard grant.id == grantID,
                  Self.isSafeGitHubIdentifier(grant.accountLogin),
                  grant.accountLogin.caseInsensitiveCompare(connected.account.login) == .orderedSame,
                  grant.credential.isStructurallyValid,
                  Self.isValidGrantLifetime(grant, now: now()) else {
                throw MSWConnectError.malformedResponse
            }
            if let expectedScope {
                let expectedNames = Set(expectedScope.repositoryNames.map(Self.normalizedRepositoryName))
                let returnedNames = grant.repositoryNames.map(Self.normalizedRepositoryName)
                guard grant.workspace == expectedScope.workspace,
                      grant.role == expectedScope.role,
                      Self.isSafeGitHubIdentifier(grant.owner),
                      grant.owner.caseInsensitiveCompare(expectedScope.owner) == .orderedSame,
                      grant.installationID == expectedScope.installationID,
                      grant.repositoryIDs.count == expectedScope.repositoryIDs.count,
                      grant.repositoryIDs.count == Set(grant.repositoryIDs).count,
                      Set(grant.repositoryIDs) == Set(expectedScope.repositoryIDs),
                      grant.accessMode == expectedScope.accessMode,
                      Self.isSafeRepositoryName(grant.verificationRepository),
                      Self.normalizedRepositoryName(grant.verificationRepository) ==
                        Self.normalizedRepositoryName(expectedScope.verificationRepository),
                      returnedNames.count == expectedScope.repositoryNames.count,
                      Set(returnedNames) == expectedNames,
                      grant.repositoryNames.allSatisfy(Self.isSafeRepositoryName) else {
                    throw MSWConnectError.scopeMismatch
                }
                try validateScopeAttestation(grant: grant, assignment: expectedScope)
            } else if configuration.requiresScopeAttestation {
                throw MSWConnectError.scopeAttestationMissing
            }
            return grant
        } catch MSWConnectError.httpStatus(404) {
            throw MSWConnectError.grantNotFound
        }
    }

    func revokeGrant(grantID: UUID) async throws -> MSWConnectRevocationReceipt {
        let request = try makeAuthorizedRequest(
            path: "/v1/grants/\(grantID.uuidString)",
            method: "DELETE",
            session: try requiredSession()
        )
        do {
            let receipt: MSWConnectRevocationReceipt = try await send(request)
            guard receipt.grantID == grantID, receipt.revoked, receipt.terminal else {
                throw MSWConnectError.malformedResponse
            }
            return receipt
        } catch MSWConnectError.grantNotFound, MSWConnectError.grantRevoked, MSWConnectError.httpStatus(404) {
            // DELETE is intentionally idempotent for transaction recovery: a
            // grant that is already gone or already revoked counts as revoked.
            return MSWConnectRevocationReceipt(
                grantID: grantID,
                revoked: true,
                terminal: true,

                revokedAt: nil
            )
        }
    }

    private func sendAuthorized<Value: Decodable>(
        path: String,
        method: String
    ) async throws -> Value {
        let request = try makeAuthorizedRequest(
            path: path,
            method: method,
            session: try requiredSession()
        )
        return try await send(request)
    }
    private func makeRequest(path: String, method: String) throws -> URLRequest {
        try configuration.validate()
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-MSW-Connect-Version")
        return request
    }

    private func makeAuthorizedRequest(path: String, method: String, session: MSWConnectSession?) throws -> URLRequest {
        guard let session else { throw MSWConnectError.sessionExpired }
        var request = try makeRequest(path: path, method: method)
        request.setValue("Bearer \(session.opaqueServiceToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func send<Value: Decodable>(_ request: URLRequest) async throws -> Value {
        let (data, response) = try await transport.send(request)
        try validate(response, data: data, path: request.url?.path ?? "")
        do { return try Self.decoder.decode(Value.self, from: data) }
        catch { throw MSWConnectError.malformedResponse }
    }

    private func validate(_ response: HTTPURLResponse, data: Data, path: String) throws {
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 {
                session = nil
                do {
                    try keychain.delete(service: sessionService, account: sessionAccount)
                } catch {
                    throw MSWConnectError.sessionCleanupFailed
                }
                throw MSWConnectError.sessionExpired
            }
            if response.statusCode == 429 {
                let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
                throw MSWConnectError.rateLimited(retryAfter)
            }
            if let serviceError = try? Self.decoder.decode(ServiceErrorResponse.self, from: data),
               let code = serviceError.resolvedCode {
                switch code {
                case "grant_not_found": throw MSWConnectError.grantNotFound
                case "grant_revoked": throw MSWConnectError.grantRevoked
                case "installation_removed": throw MSWConnectError.installationRemoved
                case "repository_not_allowed": throw MSWConnectError.repositoryNotAllowed
                case "account_boundary_violation": throw MSWConnectError.accountBoundaryViolation
                default:
                    throw MSWConnectError.serviceValidation(
                        serviceError.resolvedMessage ?? "MSW Connect rejected the request for \(path)."
                    )
                }
            }
            throw MSWConnectError.httpStatus(response.statusCode)
        }
    }


    private func persistSession(_ session: MSWConnectSession) throws {
        let stored = StoredSession(
            sessionID: session.sessionID,
            sessionToken: session.opaqueServiceToken,
            account: session.account,
            expiresAt: session.expiresAt,
            issuer: configuration.baseURL.absoluteString,
            clientID: configuration.clientID,
            redirectURI: configuration.redirectURL.absoluteString
        )
        try keychain.save(KeychainItem(
            service: sessionService,
            account: sessionAccount,
            secret: try Self.encoder.encode(stored)
        ))
    }
    private struct GrantRenewalRequest: Encodable {
        let grantID: UUID
        let scopeDigest: String?

        enum CodingKeys: String, CodingKey {
            case grantID = "grant_id"
            case scopeDigest = "scope_digest"
        }
    }

    private struct DisconnectRequest: Encodable {
        let grantIDs: [UUID]

        enum CodingKeys: String, CodingKey {
            case grantIDs = "grant_ids"
        }
    }

    private struct ServiceErrorResponse: Decodable {
        struct Detail: Decodable {
            let code: String?
            let message: String?
        }

        let error: Detail?
        let code: String?
        let message: String?

        var resolvedCode: String? {
            (error?.code ?? code)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        var resolvedMessage: String? {
            error?.message ?? message
        }
    }


    private struct CallbackExchange: Encodable {
        let code: String
        let state: String
        let codeVerifier: String
        let redirectURI: String

        enum CodingKeys: String, CodingKey {
            case code, state
            case codeVerifier = "code_verifier"
            case redirectURI = "redirect_uri"
        }
    }

    private struct CallbackResponse: Decodable {
        let sessionID: UUID
        let sessionToken: String
        let account: GitHubAccount
        let expiresAt: Date

        enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case sessionToken = "session_token"
            case account
            case expiresAt = "expires_at"
        }
    }

    private struct StoredSession: Codable, Sendable {
        let sessionID: UUID
        let sessionToken: String
        let account: GitHubAccount
        let expiresAt: Date
        let issuer: String
        let clientID: String
        let redirectURI: String

        init(
            sessionID: UUID,
            sessionToken: String,
            account: GitHubAccount,
            expiresAt: Date,
            issuer: String,
            clientID: String,
            redirectURI: String
        ) {
            self.sessionID = sessionID
            self.sessionToken = sessionToken
            self.account = account
            self.expiresAt = expiresAt
            self.issuer = issuer
            self.clientID = clientID
            self.redirectURI = redirectURI
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sessionID = try container.decode(UUID.self, forKey: .sessionID)
            sessionToken = try container.decode(String.self, forKey: .sessionToken)
            account = try container.decode(GitHubAccount.self, forKey: .account)
            expiresAt = try container.decode(Date.self, forKey: .expiresAt)
            issuer = try container.decodeIfPresent(String.self, forKey: .issuer) ?? ""
            clientID = try container.decodeIfPresent(String.self, forKey: .clientID) ?? ""
            redirectURI = try container.decodeIfPresent(String.self, forKey: .redirectURI) ?? ""
        }

        enum CodingKeys: String, CodingKey {
            case sessionID
            case sessionToken
            case account
            case expiresAt
            case issuer
            case clientID
            case redirectURI
        }
    }

    private struct InstallationResponse: Decodable {
        let installations: [GitHubInstallation]
    }

    private struct RepositoryResponse: Decodable {
        let repositories: [GitHubRepository]
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private struct ScopeRepository: Encodable {
        let id: Int
        let name: String
    }

    private struct ScopePayload: Encodable {
        let workspace: String
        let role: String
        let owner: String
        let installationID: Int
        let repositories: [ScopeRepository]
        let accessMode: String
        let verificationRepository: String
    }

    /// The service signs this canonical payload, binding the reviewed scope to
    /// the exact opaque installation credential and grant it issued.
    private struct TokenBoundScopeAttestationPayload: Encodable {
        let schemaVersion: Int
        let grantID: String
        let scopeDigest: String
        let credentialDigest: String
        let accessExpiresAtMilliseconds: Int64
        let generation: Int
        let issuedAtMilliseconds: Int64
    }

    private static let canonicalScopeEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static func scopeDigest(_ assignment: MSWConnectGrantAssignment) -> String {
        scopeDigest(
            workspace: assignment.workspace,
            role: assignment.role,
            owner: assignment.owner,
            installationID: assignment.installationID,
            repositoryIDs: assignment.repositoryIDs,
            repositoryNames: assignment.repositoryNames,
            accessMode: assignment.accessMode,
            verificationRepository: assignment.verificationRepository
        )
    }

    private static func scopeDigest(_ grant: MSWConnectGrant) -> String {
        scopeDigest(
            workspace: grant.workspace,
            role: grant.role,
            owner: grant.owner,
            installationID: grant.installationID,
            repositoryIDs: grant.repositoryIDs,
            repositoryNames: grant.repositoryNames,
            accessMode: grant.accessMode,
            verificationRepository: grant.verificationRepository
        )
    }

    private static func scopeDigest(
        workspace: String,
        role: CredentialRole,
        owner: String,
        installationID: Int,
        repositoryIDs: [Int],
        repositoryNames: [String],
        accessMode: String,
        verificationRepository: String
    ) -> String {
        let repositories = zip(repositoryIDs, repositoryNames)
            .map { ScopeRepository(id: $0.0, name: normalizedRepositoryName($0.1)) }
            .sorted { $0.id < $1.id }
        let payload = ScopePayload(
            workspace: workspace,
            role: role.rawValue,
            owner: owner.lowercased(),
            installationID: installationID,
            repositories: repositories,
            accessMode: accessMode,
            verificationRepository: normalizedRepositoryName(verificationRepository)
        )
        let data = (try? canonicalScopeEncoder.encode(payload)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isValidGrantLifetime(_ grant: MSWConnectGrant, now: Date) -> Bool {
        guard grant.accessExpiresAt > now else { return false }
        if let issuedAt = grant.issuedAt {
            return issuedAt <= now &&
                grant.accessExpiresAt > issuedAt &&
                grant.accessExpiresAt <= issuedAt.addingTimeInterval(2 * 60 * 60)
        }
        return grant.accessExpiresAt <= now.addingTimeInterval(2 * 60 * 60)
    }

    private static func tokenDigest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func isValidCredentialDigest(_ value: String) -> Bool {
        value.count == 64 &&
            value == value.lowercased() &&
            value.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "0123456789abcdef").contains($0)
            }
    }

    private static func scopeAttestationPayload(
        grant: MSWConnectGrant,
        scopeDigest: String,
        credentialDigest: String
    ) -> Data? {
        guard let issuedAt = grant.issuedAt else { return nil }
        let payload = TokenBoundScopeAttestationPayload(
            schemaVersion: 1,
            grantID: grant.id.uuidString.lowercased(),
            scopeDigest: scopeDigest,
            credentialDigest: credentialDigest,
            accessExpiresAtMilliseconds: unixMilliseconds(grant.accessExpiresAt),
            generation: grant.generation,
            issuedAtMilliseconds: unixMilliseconds(issuedAt)
        )
        return try? canonicalScopeEncoder.encode(payload)
    }

    private static func unixMilliseconds(_ value: Date) -> Int64 {
        Int64((value.timeIntervalSince1970 * 1_000).rounded(.towardZero))
    }

    private static func isSafeEndpointPath(_ value: String) -> Bool {
        !value.isEmpty &&
            value.first == "/" &&
            !value.contains("?") &&
            !value.contains("#") &&
            !value.contains("..") &&
            !value.contains("//") &&
            value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
    }

    private static func isSafeGitHubIdentifier(_ value: String) -> Bool {
        !value.isEmpty &&
            value.count <= 100 &&
            value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0)
            }
    }
    private static func isSafeServiceToken(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed == value,
              trimmed.count <= 4096,
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
    private static func isValidInstallationResponse(_ installation: GitHubInstallation) -> Bool {
        installation.id > 0 &&
            installation.account.id > 0 &&
            isSafeGitHubIdentifier(installation.account.login)
    }

    private static func isSafeRepositoryName(_ value: String) -> Bool {
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2 else { return false }
        return isSafeGitHubIdentifier(String(components[0])) &&
            isSafeGitHubIdentifier(String(components[1]))
    }

    private static func isValidRepositoryResponse(_ repository: GitHubRepository) -> Bool {
        guard repository.id > 0,
              repository.owner.id > 0,
              isSafeGitHubIdentifier(repository.owner.login),
              isSafeGitHubIdentifier(repository.name),
              isSafeRepositoryName(repository.fullName) else {
            return false
        }
        return normalizedRepositoryName(repository.fullName) ==
            normalizedRepositoryName("\(repository.owner.login)/\(repository.name)")
    }

    static func pkceChallenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8)))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    private static func randomURLSafeString(byteCount: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<byteCount).map { _ in UInt8.random(in: 0...255, using: &generator) }
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    private static func normalizedRepositoryName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

private extension String {
    var isLoopback: Bool {
        let lowercased = lowercased()
        return lowercased == "localhost" || lowercased == "127.0.0.1" || lowercased == "::1"
    }
}
