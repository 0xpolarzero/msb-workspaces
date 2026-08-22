import Foundation

/// Path C §2: the local GitHub policy file is the single source of truth for
/// enforcement. The app never writes it directly — policy writes go through
/// the journaled `msw app github-policy-apply` CLI so capability
/// preservation, transport provisioning, atomic tmp+rename, and the
/// per-workspace GitHub lock stay CLI-owned. This store only READS the file
/// (for Settings/Detail/setup display) and watches the policy directory so
/// external/CLI edits refresh the UI live.
///
/// Decoding is deliberately strict: any missing/malformed/schema-mismatched
/// file yields `nil`, and every consumer treats `nil` as refuse-all (the
/// proxy's fail-closed posture).
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

struct GitHubPolicyRepository: Codable, Sendable, Equatable, Identifiable {
    let canonical: String
    let mode: GitHubRepositoryAccessMode

    var id: String { canonical }
}

/// App-side watcher + reader for `github-policy.json`.
///
/// `current` re-reads the file on every access, so consumers can never
/// observe stale enforcement state (the file is small and the CLI writes it
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

    /// Fresh read of the policy file (nil = missing/malformed → deny).
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
            .appendingPathComponent("MSW Monitor", isDirectory: true)
            .appendingPathComponent("github-policy.json", isDirectory: false)
    }

    /// Strict failable read. Any decode failure (missing file, malformed
    /// JSON, wrong schemaVersion, unknown mode value) returns nil.
    static func read(policyURL: URL) -> GitHubPolicyFile? {
        guard let data = try? Data(contentsOf: policyURL) else { return nil }
        guard let file = try? MSWProtocolDecoder.decoder().decode(GitHubPolicyFile.self, from: data),
              file.schemaVersion == 1 else {
            return nil
        }
        return file
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
    static let githubPolicyDidChange = Notification.Name("org.microsandbox.MSWMonitor.GitHubPolicyChanged")
}
