import Foundation

/// Path C §2: the local GitHub policy file is the single source of truth for
/// host-credential grants. The app never writes it directly — policy writes
/// go through the journaled `silo app github-policy-apply` CLI so capability
/// preservation, transport provisioning, atomic tmp+rename, and the
/// per-workspace GitHub lock stay CLI-owned. This store only READS the file
/// (for Settings/Detail/setup display) and watches the policy directory so
/// external/CLI edits refresh the UI live.
///
/// Decoding is deliberately strict: any missing/malformed/schema-mismatched
/// file yields `nil`, and every consumer treats `nil` as "no credential
/// grants" — the host OAuth/token is never injected in that state. It does
/// not deny anonymous public GitHub traffic, which needs no grant.
struct GitHubPolicyFile: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let workspaces: [String: GitHubPolicyWorkspace]
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case workspaces
        case updatedAt
    }
}

struct GitHubPolicyWorkspace: Codable, Sendable, Equatable {
    let capability: String?
    let repos: [GitHubPolicyRepository]

    enum CodingKeys: String, CodingKey {
        case capability
        case repos
    }
}

enum GitHubApplyPersistenceStatus: String, Codable, Sendable, Equatable {
    case pending
    case failed
    case completed
    case cancelled
}

/// Durable, non-secret onboarding intent. The effective policy remains
/// `github-policy.json`; this record only says which generation still needs
/// reconciliation, so a crash can never make an old verification look
/// current or activate unprovisioned access.
struct GitHubApplyPersistentState: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let generation: Int
    let semanticHash: String
    let status: GitHubApplyPersistenceStatus
    let desired: SiloGitHubPolicyApplyRequest
    let updatedAt: Date
    let failure: GitHubApplyFailure?
}

struct GitHubPolicyRepository: Codable, Sendable, Equatable, Identifiable {
    let canonical: String
    let mode: GitHubRepositoryAccessMode

    var id: String { canonical }
}

/// App-side watcher + reader for `github-policy.json`.
///
/// `current` re-reads the file on every access, so consumers can never
/// observe stale grant state (the file is small and the CLI writes it
/// atomically via tmp+rename).
///
/// The watcher watches the policy DIRECTORY (atomic writes replace the file
/// inode, so the directory inode is the stable observation point). The
/// DispatchSource handler deliberately does NO Swift concurrency work — it
/// only posts a thread-safe notification; consumers observe `.githubPolicyDidChange`
/// on the main queue and re-read `current`.
@MainActor
final class GitHubPolicyStore {
    let policyURL: URL

    /// Fresh read of the policy file (nil = missing/malformed → no credential
    /// grants; anonymous public GitHub access is unaffected).
    var current: GitHubPolicyFile? {
        Self.read(policyURL: policyURL)
    }

    private var source: DispatchSourceFileSystemObject?

    init(policyURL: URL) {
        self.policyURL = policyURL
    }

    deinit {
        // The DispatchSource cancel handler owns closing the descriptor; the
        // source must be cancelled (never just dropped) so the kernel stops
        // watching a descriptor that is about to be recycled.
        source?.cancel()
    }

    /// The production policy location, overridable with the
    /// `--ui-test-github-policy-path` launch argument (UI-test seam).
    static func standard() -> GitHubPolicyStore {
        let arguments = ProcessInfo.processInfo.arguments
        let override = arguments.firstIndex(of: "--ui-test-github-policy-path")
            .flatMap { index -> URL? in
                guard arguments.indices.contains(index + 1) else { return nil }
                return URL(fileURLWithPath: arguments[index + 1])
            }
        return GitHubPolicyStore(policyURL: override ?? Self.defaultPolicyURL)
    }

    static var defaultPolicyURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Silo", isDirectory: true)
            .appendingPathComponent("github-policy.json", isDirectory: false)
    }

    /// Strict failable read. Any decode failure (missing file, malformed
    /// JSON, wrong schemaVersion, unknown mode value) returns nil, meaning
    /// "no credential grants".
    nonisolated static func read(policyURL: URL) -> GitHubPolicyFile? {
        guard let data = try? Data(contentsOf: policyURL) else { return nil }
        guard let file = try? SiloProtocolDecoder.decoder().decode(GitHubPolicyFile.self, from: data),
              file.schemaVersion == 1 else {
            return nil
        }
        return file
    }

    nonisolated static func intentURL(for policyURL: URL) -> URL {
        policyURL.deletingLastPathComponent()
            .appendingPathComponent("github-policy-apply.json", isDirectory: false)
    }

    nonisolated static func readIntent(policyURL: URL) -> GitHubApplyPersistentState? {
        let url = intentURL(for: policyURL)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let state = try? SiloProtocolDecoder.decoder().decode(
            GitHubApplyPersistentState.self,
            from: data
        ), state.schemaVersion == 1, state.desired.schemaVersion == 1 else {
            return nil
        }
        return state
    }

    /// Writes a private sibling temporary file, fsyncs it, renames it, then
    /// fsyncs the directory. The generation boundary is durable before Setup
    /// advances to the next screen.
    nonisolated static func writeIntent(
        _ state: GitHubApplyPersistentState,
        policyURL: URL
    ) throws {
        let url = intentURL(for: policyURL)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        let temporary = directory.appendingPathComponent(".github-policy-apply.\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var writeError: Error?
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let count = Darwin.write(descriptor, base.advanced(by: written), rawBuffer.count - written)
                if count < 0 {
                    if errno == EINTR { continue }
                    writeError = POSIXError(.init(rawValue: errno) ?? .EIO)
                    break
                }
                written += count
            }
        }
        if writeError == nil, fsync(descriptor) != 0 {
            writeError = POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        if close(descriptor) != 0, writeError == nil {
            writeError = POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        if let writeError {
            try? FileManager.default.removeItem(at: temporary)
            throw writeError
        }
        guard rename(temporary.path, url.path) == 0 else {
            let error = POSIXError(.init(rawValue: errno) ?? .EIO)
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        let directoryDescriptor = open(directory.path, O_RDONLY)
        guard directoryDescriptor >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        var directoryError: Error?
        if fsync(directoryDescriptor) != 0 {
            directoryError = POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        if close(directoryDescriptor) != 0, directoryError == nil {
            directoryError = POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        if let directoryError {
            throw directoryError
        }
    }

    func startWatching() {
        stopWatching()
        guard let watcher = Self.makeDirectoryWatcher(directoryURL: policyURL.deletingLastPathComponent()) else {
            return
        }
        source = watcher.source
        watcher.source.resume()
    }

    func stopWatching() {
        source?.cancel()
        source = nil
    }

    /// Creates the directory watcher OUTSIDE any global-actor context. Swift's
    /// default closure isolation would otherwise inherit `@MainActor` into the
    /// DispatchSource event handler and trap when GCD runs it on a background
    /// queue. The handler only posts a thread-safe notification; consumers
    /// observe `.githubPolicyDidChange` on the main queue and re-read
    /// `current` (which always re-reads the file).
    private nonisolated static func makeDirectoryWatcher(
        directoryURL: URL
    ) -> (source: DispatchSourceFileSystemObject, fd: Int32)? {
        let fd = open(directoryURL.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler {
            NotificationCenter.default.post(name: .githubPolicyDidChange, object: nil)
        }
        source.setCancelHandler { [fd] in
            close(fd)
        }
        return (source, fd)
    }
}

extension Notification.Name {
    /// Posted after the policy file changes (app write through the CLI, an
    /// external/CLI edit, or the directory watcher observing an atomic
    /// replace). Consumers re-read the shared store on receipt.
    static let githubPolicyDidChange = Notification.Name("org.silo.Silo.GitHubPolicyChanged")
}
