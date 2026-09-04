import Foundation
import XCTest
@testable import Silo

/// Host-proxy GitHub provider unit tests: catalog/commit behavior against
/// a fake `silo` CLI, policy-file strict decoding, the directory watcher, and
/// the §8 user-facing labels.
@MainActor
final class GitHubProviderTests: XCTestCase {
    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("silo-github-provider-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func writeExecutable(_ url: URL, content: String) {
        try! Data(content.utf8).write(to: url)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func writePolicy(_ url: URL, json: String) {
        try! Data(json.utf8).write(to: url)
    }

    private static let handshakeLine = #"{"schemaVersion":1,"requestId":"handshake","ok":true,"command":"handshake","observedAt":"2026-08-21T00:00:00Z","result":{"protocolVersion":1,"siloVersion":"3.1.0","platform":{"os":"macOS","architecture":"arm64"},"configurationAvailable":true,"runtimeAvailable":true,"capabilities":{"jsonState":true,"jsonMetrics":true,"jsonLogs":true,"plans":true,"bootstrapEvents":true,"jq":true,"workspaceCount":3},"exitCodes":{}},"warnings":[],"error":null}"#

    private static let policyApplyLine = #"{"schemaVersion":1,"requestId":"apply","ok":true,"command":"github-policy-apply","observedAt":"2026-08-21T00:00:00Z","result":{"applied":true,"provisioned":true,"committed":true,"workspaces":[{"workspace":"dev","capability":"0123456789abcdef0123456789abcdef0123456789abcdef","repos":[]}]},"warnings":[],"error":null}"#
    private static let policyConflictLine = #"{"schemaVersion":1,"requestId":"apply","ok":false,"command":"github-policy-apply","observedAt":"2026-08-21T00:00:00Z","result":null,"warnings":[],"error":{"code":"SILO_OPERATION_CONFLICT","message":"Another GitHub operation is already running for a workspace.","recovery":"Wait for it to finish, then retry the policy apply.","workspace":null,"retryable":true}}"#

    /// Single-quotes a value for /bin/sh so embedded JSON with apostrophes
    /// (e.g. remedies like "Run 'gh auth login'") cannot break the script.
    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    /// Builds a fake `silo` executable that logs every non-handshake call to a
    /// log file (path baked in) and answers `github status`, `github auth`,
    /// `app github-policy-apply` (capturing stdin), and the device flow.
    private func makeFakeSilo(
        directory: URL,
        statusJSON: String,
        authJSON: String? = nil,
        reposJSON: String? = nil,
        reposExit: Int32 = 0,
        deviceJSON: String? = nil,
        deviceExit: Int32 = 0,
        deviceCompleteJSON: String? = nil,
        deviceCompleteExit: Int32 = 0,
        applyJSON: String? = nil,
        applyExit: Int32 = 0,
        applyDelay: TimeInterval = 0,
        applyConflictsBeforeSuccess: Int = 0,
        identityJSON: String? = nil,
        resetCommandsSucceed: Bool = false
    ) -> URL {
        let log = directory.appendingPathComponent("calls.log")
        let applyStdin = directory.appendingPathComponent("apply.stdin.json")
        let policy = directory.appendingPathComponent("github-policy.json")
        let executable = directory.appendingPathComponent("silo")
        var lines = [
            "#!/bin/sh",
            "LOG=\"\(log.path)\"",
            "APPLY_STDIN=\"\(applyStdin.path)\"",
            "POLICY=\"\(policy.path)\"",
            "APPLY_COUNT=\"\(directory.appendingPathComponent("apply.count").path)\"",
            "case \"$*\" in",
            "  \"app handshake\"*)",
            "    printf '%s\\n' \(Self.shellQuote(Self.handshakeLine))",
            "    ;;",
            "  \"github status\"*)",
            "    echo \"status $*\" >> \"$LOG\"",
            "    printf '%s\\n' \(Self.shellQuote(statusJSON))",
            "    ;;",
        ]
        if let deviceCompleteJSON {
            // Must precede both --device and the plain auth pattern:
            // --device-complete starts with --device.
            lines.append("  \"github auth --device-complete\"*)")
            lines.append("    echo \"device-complete $*\" >> \"$LOG\"")
            if deviceCompleteExit != 0 {
                lines.append("    printf '%s\\n' \(Self.shellQuote(deviceCompleteJSON))")
                lines.append("    exit \(deviceCompleteExit)")
            } else {
                lines.append("    printf '%s\\n' \(Self.shellQuote(deviceCompleteJSON))")
            }
            lines.append("    ;;")
        }
        if let deviceJSON {
            lines.append("  \"github auth --device\"*)")
            lines.append("    echo \"device $*\" >> \"$LOG\"")
            if deviceExit != 0 {
                lines.append("    printf '%s\\n' \(Self.shellQuote(deviceJSON))")
                lines.append("    exit \(deviceExit)")
            } else {
                lines.append("    printf '%s\\n' \(Self.shellQuote(deviceJSON))")
            }
            lines.append("    ;;")
        }
        if resetCommandsSucceed {
            lines += [
                "  \"github disconnect\"*)",
                "    echo \"reset-remove $*\" >> \"$LOG\"",
                "    ;;",
            ]
        }
        lines += [
            "  \"github auth\"*)",
            "    echo \"auth $*\" >> \"$LOG\"",
        ]
        if let authJSON {
            lines.append("    printf '%s\\n' \(Self.shellQuote(authJSON))")
            lines.append("    ;;")
        } else {
            lines.append("    echo 'sign-in did not complete' >&2")
            lines.append("    exit 1")
            lines.append("    ;;")
        }
        if let reposJSON {
            lines.append("  \"github repos\"*)")
            lines.append("    echo \"repos $*\" >> \"$LOG\"")
            if reposExit != 0 {
                lines.append("    printf '%s\\n' \(Self.shellQuote(reposJSON))")
                lines.append("    exit \(reposExit)")
            } else {
                lines.append("    printf '%s\\n' \(Self.shellQuote(reposJSON))")
            }
            lines.append("    ;;")
        }
        if let applyJSON {
            lines += [
                "  \"app github-policy-apply\"*)",
                "    echo \"policy-apply $*\" >> \"$LOG\"",
                "    cat > \"$APPLY_STDIN\"",
            ]
            if applyConflictsBeforeSuccess > 0 {
                lines += [
                    "    count=0",
                    "    [ ! -f \"$APPLY_COUNT\" ] || count=$(cat \"$APPLY_COUNT\")",
                    "    count=$((count + 1))",
                    "    printf '%s\\n' \"$count\" > \"$APPLY_COUNT\"",
                    "    if [ \"$count\" -le \(applyConflictsBeforeSuccess) ]; then",
                    "      printf '%s\\n' \(Self.shellQuote(Self.policyConflictLine))",
                    "      exit 73",
                    "    fi",
                ]
            }
            if applyDelay > 0 {
                lines.append("    sleep \(applyDelay)")
            }
            if applyExit == 0, applyJSON == Self.policyApplyLine {
                // A successful real CLI apply atomically publishes the
                // effective policy before returning confirmation.
                lines.append("    cp \"$APPLY_STDIN\" \"$POLICY\"")
            }
            lines.append("    echo \"policy-end $*\" >> \"$LOG\"")
            if applyExit != 0 {
                lines.append("    printf '%s\\n' \(Self.shellQuote(applyJSON))")
                lines.append("    exit \(applyExit)")
            } else {
                lines.append("    printf '%s\\n' \(Self.shellQuote(applyJSON))")
            }
            lines.append("    ;;")
        }
        if let identityJSON {
            lines += [
                "  \"app identity\"*)",
                "    echo \"identity $*\" >> \"$LOG\"",
                "    printf '%s\\n' \(Self.shellQuote(identityJSON))",
                "    ;;",
            ]
        }
        lines += [
            "  *)",
            "    echo \"unknown $*\" >> \"$LOG\"",
            "    echo \"unknown command: $*\" >&2",
            "    exit 1",
            "    ;;",
            "esac",
        ]
        writeExecutable(executable, content: lines.joined(separator: "\n") + "\n")
        return executable
    }

    private func readLog(_ directory: URL) -> String {
        let log = directory.appendingPathComponent("calls.log")
        return (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    }

    /// Counts lines in the fake-Silo call log whose command token is
    /// `github-policy-apply` (the log line is
    /// `policy-apply app github-policy-apply --format json`, so the substring
    /// appears twice per line — count LINES, not occurrences).
    private func applyCallCount(_ directory: URL) -> Int {
        readLog(directory)
            .split(separator: "\n")
            .filter { $0.contains("policy-apply app github-policy-apply") }
            .count
    }

    private func readApplyStdin(_ directory: URL) -> String {
        let file = directory.appendingPathComponent("apply.stdin.json")
        return (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    }

    private func repositoryPolicy(
        workspace: String,
        fullName: String,
        mode: GitHubRepositoryAccessMode
    ) -> GitHubRepositoryPolicy {
        let owner = fullName.split(separator: "/").first.map(String.init) ?? "acme"
        let ownerID = GitHubProvider.stableID(owner)
        return GitHubRepositoryPolicy(
            workspace: workspace,
            repositoryID: GitHubProvider.stableID(fullName),
            fullName: fullName,
            ownerID: ownerID,
            ownerLogin: owner,
            ownerType: nil,
            mode: mode
        )
    }

    // MARK: - Access semantics

    func testAccessModeLabelsMatchContract() {
        XCTAssertEqual(GitHubRepositoryAccessMode.readOnly.label, "Pushes off")
        XCTAssertEqual(GitHubRepositoryAccessMode.readWrite.label, "Pushes on")
        // JSON schema values stay read-only|read-write (D6).
        XCTAssertEqual(GitHubRepositoryAccessMode.readOnly.rawValue, "read-only")
        XCTAssertEqual(GitHubRepositoryAccessMode.readWrite.rawValue, "read-write")
    }

    func testConciseGitHubStrings() {
        XCTAssertEqual(GitHubStrings.noReposCopy, "No repositories found.")
        XCTAssertEqual(GitHubStrings.settingsNoCredential, "GitHub account not connected on this Mac")
    }

    func testRepositoryPickerPlacesSelectedRepositoriesFirst() {
        let repositories = ["acme/alpha", "acme/bravo", "acme/charlie", "acme/delta"]
        let selected = Set(["acme/bravo", "acme/delta"])

        let ordered = RepositoryWorkspacePolicyEditor.selectedFirst(repositories) {
            selected.contains($0)
        }

        XCTAssertEqual(
            ordered,
            ["acme/bravo", "acme/delta", "acme/alpha", "acme/charlie"],
            "Selected and unchecked groups must preserve the catalog's alphabetical order"
        )
    }

    func testPolicySyncPresentationUsesTruthfulStatesAndActions() {
        let phases: [(GitHubApplyPhase, String, Bool)] = [
            (.saved, "Saved", false),
            (.applying, "Applying", false),
            (.delayed, "Delayed", false),
            (.applied, "Applied", false),
            (.cancelled, "Cancelled", true)
        ]
        for (phase, label, canRetry) in phases {
            let progress = GitHubApplyProgress(
                generation: 1,
                phase: phase,
                workspace: "dev",
                failure: nil
            )
            XCTAssertEqual(progress.label, label)
            XCTAssertEqual(progress.canRetry, canRetry)
            XCTAssertEqual(progress.canCancel, phase == .delayed)
            XCTAssertFalse(progress.summary.localizedCaseInsensitiveContains("lock"))
            XCTAssertFalse(progress.summary.localizedCaseInsensitiveContains("operation conflict"))
            XCTAssertFalse(progress.summary.localizedCaseInsensitiveContains("another operation"))
        }

        let permanent = GitHubApplyProgress(
            generation: 2,
            phase: .failed,
            workspace: "dev",
            failure: GitHubApplyFailure(
                code: "SILO_INVALID_REQUEST",
                message: "The repository policy is invalid.",
                recovery: "Review the repository selection.",
                workspace: "dev",
                retryable: false
            )
        )
        XCTAssertEqual(permanent.label, "Couldn’t apply")
        XCTAssertFalse(permanent.canRetry)
        XCTAssertEqual(permanent.summary, "The repository policy is invalid.")

        let retryable = GitHubApplyProgress(
            generation: 3,
            phase: .failed,
            workspace: "dev",
            failure: GitHubApplyFailure(
                code: "SILO_TRANSPORT_PROVISION_FAILED",
                message: "GitHub transport could not be configured.",
                recovery: "Retry synchronization.",
                workspace: "dev",
                retryable: true
            )
        )
        XCTAssertTrue(retryable.canRetry)

        let internalFailure = GitHubApplyProgress(
            generation: 4,
            phase: .failed,
            workspace: "dev",
            failure: GitHubApplyFailure(
                code: "SILO_OPERATION_CONFLICT",
                message: "Another GitHub operation is already running.",
                recovery: "Delete the stale lock and retry.",
                workspace: "dev",
                retryable: false
            )
        )
        XCTAssertEqual(internalFailure.summary, "GitHub synchronization could not continue.")
        XCTAssertEqual(
            internalFailure.failure?.presentationRecovery,
            "Review the saved GitHub choices and runtime status."
        )
    }

    // MARK: - Canonicalization

    func testCanonicalRepositoryNormalization() {
        XCTAssertEqual(GitHubProvider.canonicalize("Acme/One"), "acme/one")
        XCTAssertEqual(GitHubProvider.canonicalize("acme/one.git"), "acme/one")
        XCTAssertEqual(GitHubProvider.canonicalize("  Acme/One.git  "), "acme/one")
        XCTAssertTrue(GitHubProvider.isValidCanonical("acme/one"))
        XCTAssertTrue(GitHubProvider.isValidCanonical("octocat/hello-world"))
        XCTAssertFalse(GitHubProvider.isValidCanonical("acme"))
        XCTAssertFalse(GitHubProvider.isValidCanonical("Acme/One"))
        XCTAssertFalse(GitHubProvider.isValidCanonical("acme/one.git"))
        XCTAssertFalse(GitHubProvider.isValidCanonical(""))
        XCTAssertEqual(GitHubProvider.splitCanonical("acme/one")?.owner, "acme")
        XCTAssertEqual(GitHubProvider.splitCanonical("acme/one")?.name, "one")
        XCTAssertNil(GitHubProvider.splitCanonical("acme"))
        // Stable ids: equal for equal names, distinct for distinct names.
        XCTAssertEqual(GitHubProvider.stableID("acme/one"), GitHubProvider.stableID("acme/one"))
        XCTAssertNotEqual(GitHubProvider.stableID("acme/one"), GitHubProvider.stableID("acme/two"))
        XCTAssertGreaterThan(GitHubProvider.stableID("acme/one"), 0)
    }

    // MARK: - Policy file decoding (fail-closed)

    func testPolicyFileDecodesValidSchema() throws {
        let directory = makeTemporaryDirectory()
        let url = directory.appendingPathComponent("github-policy.json")
        writePolicy(url, json: """
        {"schemaVersion":1,"workspaces":{"dev":{"capability":"abc","repos":[{"canonical":"acme/one","mode":"read-only"}]},"playgrounds":{"repos":[]}},"updatedAt":"2026-08-21T12:00:00Z"}
        """)
        let store = GitHubPolicyStore(policyURL: url)
        let policy = try XCTUnwrap(store.current)
        XCTAssertEqual(policy.schemaVersion, 1)
        XCTAssertEqual(policy.workspaces["dev"]?.repos.first?.canonical, "acme/one")
        XCTAssertEqual(policy.workspaces["dev"]?.repos.first?.mode, .readOnly)
        XCTAssertEqual(policy.workspaces["playgrounds"]?.repos, [])
        XCTAssertNil(policy.workspaces["personal"])
        let expectedDate = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-21T12:00:00Z"))
        XCTAssertEqual(policy.updatedAt, expectedDate)
    }

    func testPolicyFileMissingReturnsNil() {
        let directory = makeTemporaryDirectory()
        let store = GitHubPolicyStore(policyURL: directory.appendingPathComponent("missing.json"))
        XCTAssertNil(store.current)
    }

    func testPolicyFileMalformedReturnsNil() {
        let directory = makeTemporaryDirectory()
        let url = directory.appendingPathComponent("github-policy.json")
        writePolicy(url, json: "{not json")
        let store = GitHubPolicyStore(policyURL: url)
        XCTAssertNil(store.current)
    }

    func testPolicyFileWrongSchemaVersionReturnsNil() {
        let directory = makeTemporaryDirectory()
        let url = directory.appendingPathComponent("github-policy.json")
        writePolicy(url, json: "{\"schemaVersion\":2,\"workspaces\":{}}")
        let store = GitHubPolicyStore(policyURL: url)
        XCTAssertNil(store.current)
    }

    func testPolicyFileUnknownModeReturnsNil() {
        let directory = makeTemporaryDirectory()
        let url = directory.appendingPathComponent("github-policy.json")
        writePolicy(url, json: "{\"schemaVersion\":1,\"workspaces\":{\"dev\":{\"repos\":[{\"canonical\":\"acme/one\",\"mode\":\"read-write-extra\"}]}}}")
        let store = GitHubPolicyStore(policyURL: url)
        XCTAssertNil(store.current)
    }

    // MARK: - Directory watcher

    func testWatcherReloadsOnAtomicReplace() throws {
        let directory = makeTemporaryDirectory()
        let url = directory.appendingPathComponent("github-policy.json")
        writePolicy(url, json: "{\"schemaVersion\":1,\"workspaces\":{\"dev\":{\"repos\":[]}}}")
        let store = GitHubPolicyStore(policyURL: url)
        store.startWatching()

        let changed = expectation(forNotification: .githubPolicyDidChange, object: nil)

        // CLI-style atomic tmp+rename replaces the inode; the directory
        // watcher must observe it and notify consumers.
        let tmp = directory.appendingPathComponent("github-policy.json.tmp")
        try Data("{\"schemaVersion\":1,\"workspaces\":{\"dev\":{\"repos\":[{\"canonical\":\"acme/one\",\"mode\":\"read-write\"}]}}}".utf8).write(to: tmp)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)

        wait(for: [changed], timeout: 5)
        // `current` always re-reads the file, so the fresh policy is visible
        // immediately after the notification.
        XCTAssertEqual(store.current?.workspaces["dev"]?.repos.first?.canonical, "acme/one")
        XCTAssertEqual(store.current?.workspaces["dev"]?.repos.first?.mode, .readWrite)
        store.stopWatching()
    }

    // MARK: - Provider catalog (policy read-back via the CLI)

    func testLoadCatalogGroupsDiscoveredReposByOwner() async throws {
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        writePolicy(policyURL, json: """
        {"schemaVersion":1,"workspaces":{"dev":{"capability":"abc","repos":[{"canonical":"acme/one","mode":"read-only"}]}}}
        """)
        let executable = makeFakeSilo(
            directory: directory,
            statusJSON: #"{"hostCredential":"present","workspaces":[{"workspace":"dev","capability":"minted","repos":[{"canonical":"acme/one","mode":"read-only"}],"shuttle":"stopped"}]}"#,
            authJSON: #"{"provider":"gh-cli","tokenKind":"oauth","accountLogin":"octocat","verifiedAt":"2026-08-21T00:00:00Z","generation":1,"storedAt":"2026-08-21T00:00:00Z","repoChecks":[]}"#,
            reposJSON: #"{"ok":true,"repos":[{"canonical":"acme/two","name":"two","owner":"acme","private":true,"permissions":{"pull":true,"push":true},"inPolicy":false},{"canonical":"acme/one","name":"one","owner":"acme","private":true,"permissions":{"pull":true,"push":false},"inPolicy":true},{"canonical":"org/repo","name":"repo","owner":"org","private":false,"permissions":{"pull":true,"push":true},"inPolicy":false}]}"#
        )
        let runner = SiloCommandRunner(configuration: .init(homeDirectory: directory, testSiloExecutable: executable))
        let client = SiloClient(runner: runner)
        let store = GitHubPolicyStore(policyURL: policyURL)
        let provider = GitHubProvider(client: client, policyStore: store)

        let catalog = try await provider.loadCatalog()

        XCTAssertTrue(catalog.hostCredentialPresent)
        XCTAssertEqual(catalog.account?.login, "octocat")
        XCTAssertEqual(catalog.owners.count, 2, "One catalog entry per owner")
        let acmeID = GitHubProvider.stableID("acme")
        let orgID = GitHubProvider.stableID("org")
        XCTAssertEqual(Set(catalog.owners.map(\.id)), [acmeID, orgID])
        let acmeRepos = try XCTUnwrap(catalog.repositoriesByOwner[acmeID])
        XCTAssertEqual(acmeRepos.map(\.fullName), ["acme/one", "acme/two"], "Repos sorted by canonical")
        let one = try XCTUnwrap(acmeRepos.first { $0.fullName == "acme/one" })
        XCTAssertEqual(one.id, GitHubProvider.stableID("acme/one"))
        XCTAssertEqual(one.name, "one")
        XCTAssertEqual(one.canPush, false)
        XCTAssertEqual(one.inPolicy, true)
        let two = try XCTUnwrap(acmeRepos.first { $0.fullName == "acme/two" })
        XCTAssertEqual(two.canPush, true)
        XCTAssertEqual(two.inPolicy, false)
        XCTAssertEqual(catalog.repositoriesByOwner[orgID]?.map(\.fullName), ["org/repo"])
        XCTAssertTrue(readLog(directory).contains("repos github repos --format json"))
    }

    func testLoadCatalogRefreshReMergesPolicyOnlyGrantForMapping() async throws {
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        // The policy grants acme/one, but GitHub discovery no longer lists it
        // (only acme/two is discovered): acme/one is a policy-only grant.
        writePolicy(policyURL, json: """
        {"schemaVersion":1,"workspaces":{"dev":{"capability":"abc","repos":[{"canonical":"acme/one","mode":"read-only"}]},"playgrounds":{"capability":"def","repos":[]}}}
        """)
        let executable = makeFakeSilo(
            directory: directory,
            statusJSON: #"{"hostCredential":"present","workspaces":[{"workspace":"dev","capability":"minted","repos":[{"canonical":"acme/one","mode":"read-only"}],"shuttle":"stopped"}]}"#,
            authJSON: #"{"provider":"gh-cli","tokenKind":"oauth","accountLogin":"octocat","verifiedAt":"2026-08-21T00:00:00Z","generation":1,"storedAt":"2026-08-21T00:00:00Z","repoChecks":[]}"#,
            reposJSON: #"{"ok":true,"repos":[{"canonical":"acme/two","name":"two","owner":"acme","private":true,"permissions":{"pull":true,"push":true},"inPolicy":false}]}"#
        )
        let runner = SiloCommandRunner(configuration: .init(homeDirectory: directory, testSiloExecutable: executable))
        let provider = GitHubProvider(client: SiloClient(runner: runner), policyStore: GitHubPolicyStore(policyURL: policyURL))

        // Load, then refresh (a second load): BOTH must re-merge the grant.
        let first = try await provider.loadCatalog()
        let refreshed = try await provider.loadCatalog()

        let acmeID = GitHubProvider.stableID("acme")
        let acmeOneID = GitHubProvider.stableID("acme/one")
        for catalog in [first, refreshed] {
            XCTAssertTrue(catalog.hostCredentialPresent)
            let acmeRepos = try XCTUnwrap(catalog.repositoriesByOwner[acmeID])
            XCTAssertEqual(
                acmeRepos.map(\.fullName),
                ["acme/two", "acme/one"],
                "Every load must re-merge the policy-only grant into the fresh catalog"
            )
            let synthetic = try XCTUnwrap(acmeRepos.first { $0.id == acmeOneID })
            XCTAssertEqual(synthetic.fullName, "acme/one")
        }

        // The refreshed catalog keeps the grant available for draft-to-policy
        // mapping: a draft selecting it still yields a policy entry.
        var draft = WorkspaceRepositoryDraft.initial("dev")
        draft.repositoryModes = ["acme/one": .readOnly]
        let entries = SetupView.repositoryPolicyEntries(
            workspace: "dev",
            draft: draft,
            owners: refreshed.owners,
            repositoriesByOwner: refreshed.repositoriesByOwner
        )
        XCTAssertEqual(entries.map(\.fullName), ["acme/one"])
        XCTAssertEqual(entries.first?.mode, .readOnly)
    }

    func testLoadCatalogWithoutCredentialSkipsDiscoveryButMergesPolicyGrants() async throws {
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        writePolicy(policyURL, json: "{\"schemaVersion\":1,\"workspaces\":{\"dev\":{\"repos\":[{\"canonical\":\"acme/one\",\"mode\":\"read-only\"}]}}}")
        let executable = makeFakeSilo(
            directory: directory,
            statusJSON: #"{"hostCredential":"missing","workspaces":[{"workspace":"dev","capability":"missing","repos":[{"canonical":"acme/one","mode":"read-only"}],"shuttle":"stopped"}]}"#,
            reposJSON: #"{"ok":true,"repos":[]}"#
        )
        let runner = SiloCommandRunner(configuration: .init(homeDirectory: directory, testSiloExecutable: executable))
        let provider = GitHubProvider(client: SiloClient(runner: runner), policyStore: GitHubPolicyStore(policyURL: policyURL))

        let catalog = try await provider.loadCatalog()

        XCTAssertFalse(catalog.hostCredentialPresent)
        XCTAssertNil(catalog.account)
        // Discovery is skipped without a credential, but the existing
        // policy-only grant is still merged so it stays visible and editable.
        let acmeID = GitHubProvider.stableID("acme")
        XCTAssertEqual(catalog.owners.map(\.id), [acmeID])
        XCTAssertEqual(
            catalog.repositoriesByOwner[acmeID]?.map(\.fullName),
            ["acme/one"]
        )
        let log = readLog(directory)
        XCTAssertFalse(log.contains("auth "), "auth must not run without a credential")
        XCTAssertFalse(log.contains("repos "), "discovery must not run without a credential")
    }

    func testLoadCatalogSurfacesDiscoveryFailure() async throws {
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        writePolicy(policyURL, json: "{\"schemaVersion\":1,\"workspaces\":{}}")
        let executable = makeFakeSilo(
            directory: directory,
            statusJSON: #"{"hostCredential":"present","workspaces":[{"workspace":"dev","capability":"minted","repos":[],"shuttle":"stopped"}]}"#,
            reposJSON: #"{"ok":false,"error":{"code":"SILO_REPOSITORY_DISCOVERY_FAILED","message":"GitHub API discovery failed","remedies":["Retry"]}}"#,
            reposExit: 1
        )
        let runner = SiloCommandRunner(configuration: .init(homeDirectory: directory, testSiloExecutable: executable))
        let provider = GitHubProvider(client: SiloClient(runner: runner), policyStore: GitHubPolicyStore(policyURL: policyURL))

        do {
            _ = try await provider.loadCatalog()
            XCTFail("Expected discovery failure")
        } catch let error as GitHubCatalogError {
            guard case .unavailable(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("GitHub API discovery failed"))
        }
    }

    // MARK: - Provider commit (single apply, full desired policy)

    func testCommitAppliesFullPolicyInOneInvocation() async throws {
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        writePolicy(policyURL, json: """
        {"schemaVersion":1,"workspaces":{"dev":{"capability":"abc","repos":[{"canonical":"acme/one","mode":"read-only"}]},"playgrounds":{"capability":"def","repos":[{"canonical":"acme/three","mode":"read-only"}]}}}
        """)
        let executable = makeFakeSilo(
            directory: directory,
            statusJSON: #"{"workspaces":[]}"#,
            applyJSON: Self.policyApplyLine
        )
        let runner = SiloCommandRunner(configuration: .init(homeDirectory: directory, testSiloExecutable: executable))
        let client = SiloClient(runner: runner)
        let store = GitHubPolicyStore(policyURL: policyURL)
        let provider = GitHubProvider(client: client, policyStore: store)

        let ownerID = GitHubProvider.stableID("acme")
        let desiredPolicy = [
            GitHubWorkspacePolicy(workspace: "dev", repositories: [
                GitHubRepositoryPolicy(
                    workspace: "dev",
                    repositoryID: GitHubProvider.stableID("acme/one"),
                    fullName: "acme/one",
                    ownerID: ownerID,
                    ownerLogin: "acme",
                    ownerType: nil,
                    mode: .readWrite
                ),
                GitHubRepositoryPolicy(
                    workspace: "dev",
                    repositoryID: GitHubProvider.stableID("acme/two"),
                    fullName: "acme/two",
                    ownerID: ownerID,
                    ownerLogin: "acme",
                    ownerType: nil,
                    mode: .readOnly
                )
            ]),
            // An edited workspace with no entries removes all of its access.
            GitHubWorkspacePolicy(workspace: "playgrounds", repositories: [])
        ]

        _ = try await provider.savePolicy(desiredPolicy)
        try await provider.waitForPolicySync()

        // ONE apply invocation; no sequential policy-set calls.
        let log = readLog(directory)
        let applyCalls = applyCallCount(directory)
        XCTAssertEqual(applyCalls, 1, "The desired policy must be applied in exactly one invocation")
        XCTAssertFalse(log.contains("policy-set "), "No sequential per-repo policy calls are allowed")

        // Stdin carries the FULL desired policy: every workspace, edited
        // workspaces replaced, untouched workspaces preserved.
        let stdin = readApplyStdin(directory)
        let payload = try XCTUnwrap(
            SiloProtocolDecoder.decoder().decode(SiloGitHubPolicyApplyRequest.self, from: Data(stdin.utf8))
        )
        XCTAssertEqual(payload.schemaVersion, 1)
        XCTAssertEqual(
            Set(payload.workspaces.keys),
            Set(SetupWorkspaceConfiguration.defaults.map(\.name))
        )
        let dev = try XCTUnwrap(payload.workspaces["dev"])
        XCTAssertEqual(dev.repos.map(\.canonical), ["acme/one", "acme/two"])
        XCTAssertEqual(dev.repos.first { $0.canonical == "acme/one" }?.mode, .readWrite)
        XCTAssertEqual(dev.repos.first { $0.canonical == "acme/two" }?.mode, .readOnly)
        let playgrounds = try XCTUnwrap(payload.workspaces["playgrounds"])
        XCTAssertTrue(playgrounds.repos.isEmpty, "Edited workspace with no entries clears its access")
        let personal = try XCTUnwrap(payload.workspaces["personal"])
        XCTAssertTrue(personal.repos.isEmpty, "Untouched workspace with no prior entries stays empty")
    }

    func testPolicySyncRetriesTransientContention() async throws {
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        writePolicy(policyURL, json: """
        {"schemaVersion":1,"workspaces":{"dev":{"capability":"abc","repos":[{"canonical":"acme/one","mode":"read-only"}]}}}
        """)
        let executable = makeFakeSilo(
            directory: directory,
            statusJSON: #"{"workspaces":[]}"#,
            applyJSON: Self.policyApplyLine,
            applyConflictsBeforeSuccess: 1
        )
        let runner = SiloCommandRunner(configuration: .init(
            homeDirectory: directory,
            testSiloExecutable: executable
        ))
        let provider = GitHubProvider(
            client: SiloClient(runner: runner),
            policyStore: GitHubPolicyStore(policyURL: policyURL)
        )
        let ownerID = GitHubProvider.stableID("acme")
        let policy = [
            GitHubWorkspacePolicy(workspace: "dev", repositories: [
                GitHubRepositoryPolicy(
                    workspace: "dev",
                    repositoryID: GitHubProvider.stableID("acme/one"),
                    fullName: "acme/one",
                    ownerID: ownerID,
                    ownerLogin: "acme",
                    ownerType: nil,
                    mode: .readWrite
                )
            ])
        ]

        _ = try await provider.savePolicy(policy)
        try await provider.waitForPolicySync()

        XCTAssertEqual(applyCallCount(directory), 2)
    }

    func testContentionBeyondOldRetryWindowBecomesDelayedThenAppliesWithoutFailure() async throws {
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        writePolicy(policyURL, json: "{\"schemaVersion\":1,\"workspaces\":{}}")
        let executable = makeFakeSilo(
            directory: directory,
            statusJSON: #"{"workspaces":[]}"#,
            applyJSON: Self.policyApplyLine,
            applyConflictsBeforeSuccess: 5
        )
        let provider = GitHubProvider(
            client: SiloClient(runner: SiloCommandRunner(configuration: .init(
                homeDirectory: directory,
                testSiloExecutable: executable
            ))),
            policyStore: GitHubPolicyStore(policyURL: policyURL),
            contentionBackoff: { _ in .milliseconds(80) }
        )

        let saved = try await provider.savePolicy([
            GitHubWorkspacePolicy(workspace: "dev", repositories: [
                repositoryPolicy(workspace: "dev", fullName: "acme/one", mode: .readWrite)
            ])
        ])
        XCTAssertEqual(saved.label, "Saved")

        var delayed: GitHubApplyProgress?
        for _ in 0..<80 {
            let progress = await provider.policySyncProgress()
            if progress?.phase == .delayed {
                delayed = progress
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let visible = try XCTUnwrap(delayed)
        XCTAssertEqual(visible.label, "Delayed")
        XCTAssertNil(visible.failure, "Routine contention must never become a visible failure")
        XCTAssertFalse(visible.summary.localizedCaseInsensitiveContains("lock"))
        XCTAssertFalse(visible.summary.localizedCaseInsensitiveContains("operation conflict"))
        XCTAssertFalse(visible.summary.localizedCaseInsensitiveContains("another operation"))

        try await provider.waitForPolicySync()
        let finalProgress = await provider.policySyncProgress()
        let applied = try XCTUnwrap(finalProgress)
        XCTAssertEqual(applied.phase, .applied)
        XCTAssertEqual(applyCallCount(directory), 6)
    }

    func testPendingIntentResumesAfterProviderReinitialization() async throws {
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        writePolicy(policyURL, json: "{\"schemaVersion\":1,\"workspaces\":{}}")
        let desired = SiloGitHubPolicyApplyRequest(
            schemaVersion: 1,
            workspaces: [
                "dev": GitHubPolicyWorkspace(
                    capability: nil,
                    repos: [GitHubPolicyRepository(canonical: "acme/one", mode: .readOnly)]
                ),
                "playgrounds": GitHubPolicyWorkspace(capability: nil, repos: []),
                "personal": GitHubPolicyWorkspace(capability: nil, repos: [])
            ]
        )
        try GitHubPolicyStore.writeIntent(
            GitHubApplyPersistentState(
                schemaVersion: 1,
                generation: 41,
                semanticHash: "persisted-generation",
                status: .pending,
                desired: desired,
                updatedAt: Date(),
                failure: nil
            ),
            policyURL: policyURL
        )
        let executable = makeFakeSilo(
            directory: directory,
            statusJSON: #"{"workspaces":[]}"#,
            applyJSON: Self.policyApplyLine
        )
        let reloaded = GitHubProvider(
            client: SiloClient(runner: SiloCommandRunner(configuration: .init(
                homeDirectory: directory,
                testSiloExecutable: executable
            ))),
            policyStore: GitHubPolicyStore(policyURL: policyURL)
        )

        let resumedProgress = await reloaded.policySyncProgress()
        let resumed = try XCTUnwrap(resumedProgress)
        XCTAssertEqual(resumed.generation, 41)
        XCTAssertTrue(resumed.isInFlight)
        let reloadedDesired = await reloaded.desiredPolicy()
        XCTAssertEqual(reloadedDesired?.workspaces["dev"]?.repos.first?.canonical, "acme/one")
        try await reloaded.waitForPolicySync()
        let finalReloadedProgress = await reloaded.policySyncProgress()
        XCTAssertEqual(finalReloadedProgress?.phase, .applied)
        XCTAssertEqual(applyCallCount(directory), 1)
    }

    func testReinitializationScopesPendingIntentToCurrentWorkspaceConfiguration() async throws {
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        writePolicy(policyURL, json: "{\"schemaVersion\":1,\"workspaces\":{}}")
        let staleDesired = SiloGitHubPolicyApplyRequest(
            schemaVersion: 1,
            workspaces: [
                "dev": GitHubPolicyWorkspace(
                    capability: nil,
                    repos: [GitHubPolicyRepository(canonical: "acme/old", mode: .readOnly)]
                )
            ]
        )
        try GitHubPolicyStore.writeIntent(
            GitHubApplyPersistentState(
                schemaVersion: 1,
                generation: 12,
                semanticHash: "stale-workspace-set",
                status: .pending,
                desired: staleDesired,
                updatedAt: Date(),
                failure: nil
            ),
            policyURL: policyURL
        )
        let executable = makeFakeSilo(
            directory: directory,
            statusJSON: #"{"workspaces":[]}"#,
            applyJSON: Self.policyApplyLine
        )
        var renamedWorkspace = SetupWorkspaceConfiguration.defaults[0]
        renamedWorkspace.name = "development"
        let configured = [renamedWorkspace]
        let reloaded = GitHubProvider(
            client: SiloClient(runner: SiloCommandRunner(configuration: .init(
                homeDirectory: directory,
                testSiloExecutable: executable
            ))),
            policyStore: GitHubPolicyStore(policyURL: policyURL),
            workspaceConfigurations: configured
        )

        _ = await reloaded.policySyncProgress()
        try await reloaded.waitForPolicySync()

        let appliedRequest = try SiloProtocolDecoder.decoder().decode(
            SiloGitHubPolicyApplyRequest.self,
            from: Data(readApplyStdin(directory).utf8)
        )
        XCTAssertEqual(Set(appliedRequest.workspaces.keys), ["development"])
        XCTAssertTrue(appliedRequest.workspaces["development"]?.repos.isEmpty == true)
        XCTAssertEqual(
            Set(GitHubPolicyStore.readIntent(policyURL: policyURL)?.desired.workspaces.keys.map { $0 } ?? []),
            ["development"]
        )
    }

    func testAppliedProgressReconcilesEffectivePolicyDrift() async throws {
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        writePolicy(policyURL, json: "{\"schemaVersion\":1,\"workspaces\":{}}")
        let executable = makeFakeSilo(
            directory: directory,
            statusJSON: #"{"workspaces":[]}"#,
            applyJSON: Self.policyApplyLine
        )
        let provider = GitHubProvider(
            client: SiloClient(runner: SiloCommandRunner(configuration: .init(
                homeDirectory: directory,
                testSiloExecutable: executable
            ))),
            policyStore: GitHubPolicyStore(policyURL: policyURL)
        )

        _ = try await provider.savePolicy([
            GitHubWorkspacePolicy(workspace: "dev", repositories: [
                repositoryPolicy(workspace: "dev", fullName: "acme/desired", mode: .readOnly)
            ])
        ])
        try await provider.waitForPolicySync()
        XCTAssertEqual(applyCallCount(directory), 1)

        writePolicy(policyURL, json: "{\"schemaVersion\":1,\"workspaces\":{}}")
        let drifted = await provider.policySyncProgress()
        XCTAssertTrue(drifted?.isInFlight == true)
        XCTAssertNil(drifted?.failure)

        try await provider.waitForPolicySync()
        let reconciled = await provider.policySyncProgress()
        XCTAssertEqual(reconciled?.phase, .applied)
        XCTAssertEqual(applyCallCount(directory), 2)
    }

    func testSaveWaitsForWorkspaceConfigurationReloadBeforeBuildingIntent() async throws {
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        writePolicy(policyURL, json: "{\"schemaVersion\":1,\"workspaces\":{}}")
        let executable = makeFakeSilo(
            directory: directory,
            statusJSON: #"{"workspaces":[]}"#,
            applyJSON: Self.policyApplyLine,
            applyDelay: 0.4
        )
        let provider = GitHubProvider(
            client: SiloClient(runner: SiloCommandRunner(configuration: .init(
                homeDirectory: directory,
                testSiloExecutable: executable
            ))),
            policyStore: GitHubPolicyStore(policyURL: policyURL)
        )
        _ = try await provider.savePolicy([
            GitHubWorkspacePolicy(workspace: "dev", repositories: [
                repositoryPolicy(workspace: "dev", fullName: "acme/old", mode: .readOnly)
            ])
        ])
        try await Task.sleep(for: .milliseconds(60))

        var development = SetupWorkspaceConfiguration.defaults[0]
        development.name = "development"
        let reload = Task {
            try await provider.reloadWorkspaceConfiguration([development])
        }
        try await Task.sleep(for: .milliseconds(20))
        let save = Task {
            try await provider.savePolicy([
                GitHubWorkspacePolicy(workspace: "development", repositories: [
                    self.repositoryPolicy(
                        workspace: "development",
                        fullName: "acme/new",
                        mode: .readWrite
                    )
                ])
            ])
        }

        try await reload.value
        let newest = try await save.value
        try await provider.waitForPolicySync()

        let finalProgress = await provider.policySyncProgress()
        XCTAssertEqual(finalProgress?.generation, newest.generation)
        let appliedRequest = try SiloProtocolDecoder.decoder().decode(
            SiloGitHubPolicyApplyRequest.self,
            from: Data(readApplyStdin(directory).utf8)
        )
        XCTAssertEqual(Set(appliedRequest.workspaces.keys), ["development"])
        XCTAssertEqual(appliedRequest.workspaces["development"]?.repos.map(\.canonical), ["acme/new"])
    }

    func testSavedDesiredPolicyIsVisibleBeforeCLIConfirmation() async throws {
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        writePolicy(policyURL, json: "{\"schemaVersion\":1,\"workspaces\":{}}")
        let executable = makeFakeSilo(
            directory: directory,
            statusJSON: #"{"workspaces":[]}"#,
            applyJSON: Self.policyApplyLine,
            applyDelay: 0.3
        )
        let provider = GitHubProvider(
            client: SiloClient(runner: SiloCommandRunner(configuration: .init(
                homeDirectory: directory,
                testSiloExecutable: executable
            ))),
            policyStore: GitHubPolicyStore(policyURL: policyURL)
        )

        let saved = try await provider.savePolicy([
            GitHubWorkspacePolicy(workspace: "dev", repositories: [
                repositoryPolicy(workspace: "dev", fullName: "acme/instant", mode: .readOnly)
            ])
        ])
        XCTAssertEqual(saved.phase, .saved)
        let desiredPolicy = await provider.desiredPolicy()
        XCTAssertEqual(desiredPolicy?.workspaces["dev"]?.repos.first?.canonical, "acme/instant")
        XCTAssertTrue(GitHubPolicyStore.read(policyURL: policyURL)?.workspaces.isEmpty == true)
        try await provider.waitForPolicySync()
    }

    func testCommitPreservesUntouchedWorkspaceEntries() async throws {
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        writePolicy(policyURL, json: """
        {"schemaVersion":1,"workspaces":{"personal":{"capability":"ghi","repos":[{"canonical":"acme/two","mode":"read-write"}]}}}
        """)
        let executable = makeFakeSilo(
            directory: directory,
            statusJSON: #"{"workspaces":[]}"#,
            applyJSON: Self.policyApplyLine
        )
        let runner = SiloCommandRunner(configuration: .init(homeDirectory: directory, testSiloExecutable: executable))
        let client = SiloClient(runner: runner)
        let store = GitHubPolicyStore(policyURL: policyURL)
        let provider = GitHubProvider(client: client, policyStore: store)

        let ownerID = GitHubProvider.stableID("acme")
        let desiredPolicy = [
            GitHubWorkspacePolicy(workspace: "dev", repositories: [
                GitHubRepositoryPolicy(
                    workspace: "dev",
                    repositoryID: GitHubProvider.stableID("acme/one"),
                    fullName: "acme/one",
                    ownerID: ownerID,
                    ownerLogin: "acme",
                    ownerType: nil,
                    mode: .readOnly
                )
            ])
        ]

        _ = try await provider.savePolicy(desiredPolicy)
        try await provider.waitForPolicySync()

        let stdin = readApplyStdin(directory)
        let payload = try XCTUnwrap(
            SiloProtocolDecoder.decoder().decode(SiloGitHubPolicyApplyRequest.self, from: Data(stdin.utf8))
        )
        // Unedited personal workspace keeps its existing cross-owner entry.
        let personal = try XCTUnwrap(payload.workspaces["personal"])
        XCTAssertEqual(personal.repos.map(\.canonical), ["acme/two"])
        XCTAssertEqual(personal.repos.first?.mode, .readWrite)
        XCTAssertNil(personal.capability, "Desired intent must not duplicate effective bearer capabilities")
    }

    func testCommitThrowsWhenCLINotProvisionedAndCommitted() async throws {
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        writePolicy(policyURL, json: "{\"schemaVersion\":1,\"workspaces\":{}}")
        // CLI reports applied=false (e.g. provisioning failed and the policy
        // was rolled back): the app must NOT claim the operation applied.
        let notApplied = #"{"schemaVersion":1,"requestId":"apply","ok":true,"command":"github-policy-apply","observedAt":"2026-08-21T00:00:00Z","result":{"applied":false,"provisioned":false,"committed":false,"workspaces":[]},"warnings":[],"error":null}"#
        let executable = makeFakeSilo(
            directory: directory,
            statusJSON: #"{"workspaces":[]}"#,
            applyJSON: notApplied
        )
        let runner = SiloCommandRunner(configuration: .init(homeDirectory: directory, testSiloExecutable: executable))
        let client = SiloClient(runner: runner)
        let store = GitHubPolicyStore(policyURL: policyURL)
        let provider = GitHubProvider(client: client, policyStore: store)

        do {
            _ = try await provider.savePolicy([
                GitHubWorkspacePolicy(workspace: "dev", repositories: [
                    repositoryPolicy(workspace: "dev", fullName: "acme/one", mode: .readOnly)
                ])
            ])
            try await provider.waitForPolicySync()
            XCTFail("Expected commit to throw when the CLI did not confirm provisioning")
        } catch let error as GitHubPolicyApplyError {
            guard case .failed(let failure) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(failure.message.contains("provisioned and committed"))
        }
    }

    func testCommitSurfacesTypedCLIFailure() async throws {
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        writePolicy(policyURL, json: "{\"schemaVersion\":1,\"workspaces\":{}}")
        // Typed rollback/failure envelope (transport provisioning failed).
        let failure = #"{"schemaVersion":1,"requestId":"apply","ok":false,"command":"github-policy-apply","observedAt":null,"result":null,"warnings":[],"error":{"code":"SILO_TRANSPORT_PROVISION_FAILED","message":"Transport provisioning failed; the policy was rolled back","recovery":"Retry the policy apply","workspace":"dev","retryable":true}}"#
        let executable = makeFakeSilo(
            directory: directory,
            statusJSON: #"{"workspaces":[]}"#,
            applyJSON: failure,
            applyExit: 77
        )
        let runner = SiloCommandRunner(configuration: .init(homeDirectory: directory, testSiloExecutable: executable))
        let client = SiloClient(runner: runner)
        let store = GitHubPolicyStore(policyURL: policyURL)
        let provider = GitHubProvider(client: client, policyStore: store)

        do {
            _ = try await provider.savePolicy([
                GitHubWorkspacePolicy(workspace: "dev", repositories: [
                    repositoryPolicy(workspace: "dev", fullName: "acme/one", mode: .readOnly)
                ])
            ])
            try await provider.waitForPolicySync()
            XCTFail("Expected commit to throw on the CLI's typed failure")
        } catch let error as GitHubPolicyApplyError {
            guard case .failed(let failure) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(failure.code, "SILO_TRANSPORT_PROVISION_FAILED")
            XCTAssertTrue(failure.message.contains("rolled back"))
        }
    }

    func testNonRetryableContentionDetailsStayOutOfPresentation() async throws {
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        writePolicy(policyURL, json: "{\"schemaVersion\":1,\"workspaces\":{}}")
        let failure = #"{"schemaVersion":1,"requestId":"apply","ok":false,"command":"github-policy-apply","observedAt":null,"result":null,"warnings":[],"error":{"code":"SILO_OPERATION_CONFLICT","message":"Another GitHub operation is already running for a workspace.","recovery":"Remove the stale lock and retry.","workspace":"dev","retryable":false}}"#
        let executable = makeFakeSilo(
            directory: directory,
            statusJSON: #"{"workspaces":[]}"#,
            applyJSON: failure,
            applyExit: 75
        )
        let provider = GitHubProvider(
            client: SiloClient(runner: SiloCommandRunner(configuration: .init(
                homeDirectory: directory,
                testSiloExecutable: executable
            ))),
            policyStore: GitHubPolicyStore(policyURL: policyURL)
        )

        _ = try await provider.savePolicy([
            GitHubWorkspacePolicy(workspace: "dev", repositories: [
                repositoryPolicy(workspace: "dev", fullName: "acme/one", mode: .readOnly)
            ])
        ])
        do {
            try await provider.waitForPolicySync()
            XCTFail("Expected terminal failure")
        } catch let error as GitHubPolicyApplyError {
            guard case .failed(let visible) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            let presentation = "\(visible.message) \(visible.recovery)"
            XCTAssertFalse(presentation.localizedCaseInsensitiveContains("lock"))
            XCTAssertFalse(presentation.localizedCaseInsensitiveContains("operation conflict"))
            XCTAssertFalse(presentation.localizedCaseInsensitiveContains("another"))
        }
    }

    func testBackgroundApplyPersistsIntentAndFinalGatingState() async throws {
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        writePolicy(policyURL, json: "{\"schemaVersion\":1,\"workspaces\":{}}")
        let executable = makeFakeSilo(
            directory: directory,
            statusJSON: #"{"workspaces":[]}"#,
            applyJSON: Self.policyApplyLine,
            applyDelay: 0.25
        )
        let runner = SiloCommandRunner(configuration: .init(homeDirectory: directory, testSiloExecutable: executable))
        let provider = GitHubProvider(
            client: SiloClient(runner: runner),
            policyStore: GitHubPolicyStore(policyURL: policyURL)
        )
        let desired = [GitHubWorkspacePolicy(workspace: "dev", repositories: [
            repositoryPolicy(workspace: "dev", fullName: "acme/one", mode: .readOnly)
        ])]

        let started = try await provider.savePolicy(desired)
        XCTAssertEqual(started.phase, .saved, "Save must return before reconciliation finishes")
        let pending = try XCTUnwrap(GitHubPolicyStore.readIntent(policyURL: policyURL))
        XCTAssertEqual(pending.generation, started.generation)
        XCTAssertEqual(pending.status, .pending)

        try await provider.waitForPolicySync()
        let maybeCompleted = await provider.policySyncProgress()
        let completed = try XCTUnwrap(maybeCompleted)
        XCTAssertEqual(completed.phase, .applied)
        XCTAssertEqual(completed.generation, started.generation)
        XCTAssertEqual(GitHubPolicyStore.readIntent(policyURL: policyURL)?.status, .completed)
    }

    func testSemanticNoOpDoesNotRerunReconciliation() async throws {
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        writePolicy(policyURL, json: """
        {"schemaVersion":1,"workspaces":{"dev":{"capability":"0123456789abcdef0123456789abcdef0123456789abcdef","repos":[{"canonical":"acme/one","mode":"read-only"}]}}}
        """)
        let executable = makeFakeSilo(
            directory: directory,
            statusJSON: #"{"workspaces":[]}"#
        )
        let runner = SiloCommandRunner(configuration: .init(homeDirectory: directory, testSiloExecutable: executable))
        let provider = GitHubProvider(client: SiloClient(runner: runner), policyStore: GitHubPolicyStore(policyURL: policyURL))

        let progress = try await provider.savePolicy([
            GitHubWorkspacePolicy(workspace: "dev", repositories: [
                repositoryPolicy(workspace: "dev", fullName: "acme/one", mode: .readOnly)
            ])
        ])

        XCTAssertEqual(progress.phase, .applied)
        XCTAssertEqual(applyCallCount(directory), 0)
    }

    func testNewestGenerationSupersedesStaleApplyAndIdentitySerializes() async throws {
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        writePolicy(policyURL, json: "{\"schemaVersion\":1,\"workspaces\":{}}")
        let identity = #"{"schemaVersion":1,"requestId":"identity","ok":true,"command":"identity","observedAt":"2026-08-21T00:00:00Z","result":{"target":"dev","name":"Ada","email":"ada@example.test","workspaces":["dev"]},"warnings":[],"error":null}"#
        let executable = makeFakeSilo(
            directory: directory,
            statusJSON: #"{"workspaces":[]}"#,
            applyJSON: Self.policyApplyLine,
            applyDelay: 0.35,
            identityJSON: identity
        )
        let runner = SiloCommandRunner(configuration: .init(homeDirectory: directory, testSiloExecutable: executable))
        let provider = GitHubProvider(client: SiloClient(runner: runner), policyStore: GitHubPolicyStore(policyURL: policyURL))
        let first = try await provider.savePolicy([
            GitHubWorkspacePolicy(workspace: "dev", repositories: [repositoryPolicy(workspace: "dev", fullName: "acme/one", mode: .readOnly)])
        ])
        try await Task.sleep(for: .milliseconds(60))
        let newest = try await provider.savePolicy([
            GitHubWorkspacePolicy(workspace: "dev", repositories: [repositoryPolicy(workspace: "dev", fullName: "acme/two", mode: .readWrite)])
        ])
        XCTAssertGreaterThan(newest.generation, first.generation)

        async let identityResult = provider.setIdentity(name: "Ada", email: "ada@example.test", workspace: "dev")
        try await provider.waitForPolicySync()
        let resolvedIdentity = try await identityResult
        XCTAssertEqual(resolvedIdentity.name, "Ada")
        let maybeProgress = await provider.policySyncProgress()
        let progress = try XCTUnwrap(maybeProgress)
        XCTAssertEqual(progress.generation, newest.generation)
        XCTAssertEqual(progress.phase, .applied)
        let appliedRequest = try SiloProtocolDecoder.decoder().decode(
            SiloGitHubPolicyApplyRequest.self,
            from: Data(readApplyStdin(directory).utf8)
        )
        XCTAssertEqual(appliedRequest.workspaces["dev"]?.repos.map(\.canonical), ["acme/two"])
        let calls = readLog(directory)
        XCTAssertLessThan(
            try XCTUnwrap(calls.range(of: "policy-end")?.lowerBound),
            try XCTUnwrap(calls.range(of: "identity app identity")?.lowerBound),
            "Identity must enter the shared mutation queue only after GitHub reconciliation releases it"
        )
    }

    func testConcurrentRapidSavesApplyNewestAcceptedGeneration() async throws {
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        writePolicy(policyURL, json: "{\"schemaVersion\":1,\"workspaces\":{}}")
        let executable = makeFakeSilo(
            directory: directory,
            statusJSON: #"{"workspaces":[]}"#,
            applyJSON: Self.policyApplyLine,
            applyDelay: 0.25
        )
        let provider = GitHubProvider(
            client: SiloClient(runner: SiloCommandRunner(configuration: .init(
                homeDirectory: directory,
                testSiloExecutable: executable
            ))),
            policyStore: GitHubPolicyStore(policyURL: policyURL)
        )
        let ownerID = GitHubProvider.stableID("acme")

        let accepted = try await withThrowingTaskGroup(
            of: (generation: Int, repository: String).self
        ) { group in
            for index in 0..<8 {
                group.addTask {
                    let repository = "acme/rapid-\(index)"
                    let progress = try await provider.savePolicy([
                        GitHubWorkspacePolicy(workspace: "dev", repositories: [
                            GitHubRepositoryPolicy(
                                workspace: "dev",
                                repositoryID: GitHubProvider.stableID(repository),
                                fullName: repository,
                                ownerID: ownerID,
                                ownerLogin: "acme",
                                ownerType: nil,
                                mode: .readOnly
                            )
                        ])
                    ])
                    return (progress.generation, repository)
                }
            }
            var results: [(generation: Int, repository: String)] = []
            while let result = try await group.next() {
                results.append(result)
            }
            return results
        }
        let latest = try XCTUnwrap(accepted.max(by: { $0.generation < $1.generation }))

        try await provider.waitForPolicySync()

        let finalProgress = await provider.policySyncProgress()
        XCTAssertEqual(finalProgress?.generation, latest.generation)
        XCTAssertEqual(finalProgress?.phase, .applied)
        let appliedRequest = try SiloProtocolDecoder.decoder().decode(
            SiloGitHubPolicyApplyRequest.self,
            from: Data(readApplyStdin(directory).utf8)
        )
        XCTAssertEqual(appliedRequest.workspaces["dev"]?.repos.map(\.canonical), [latest.repository])
    }

    func testFailedIntentPersistenceDoesNotCancelAcceptedGeneration() async throws {
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        writePolicy(policyURL, json: "{\"schemaVersion\":1,\"workspaces\":{}}")
        let executable = makeFakeSilo(
            directory: directory,
            statusJSON: #"{"workspaces":[]}"#,
            applyJSON: Self.policyApplyLine,
            applyDelay: 0.4
        )
        let provider = GitHubProvider(
            client: SiloClient(runner: SiloCommandRunner(configuration: .init(
                homeDirectory: directory,
                testSiloExecutable: executable
            ))),
            policyStore: GitHubPolicyStore(policyURL: policyURL)
        )
        let accepted = try await provider.savePolicy([
            GitHubWorkspacePolicy(workspace: "dev", repositories: [
                repositoryPolicy(workspace: "dev", fullName: "acme/accepted", mode: .readOnly)
            ])
        ])
        let intentURL = GitHubPolicyStore.intentURL(for: policyURL)
        try FileManager.default.removeItem(at: intentURL)
        try FileManager.default.createDirectory(at: intentURL, withIntermediateDirectories: false)

        do {
            _ = try await provider.savePolicy([
                GitHubWorkspacePolicy(workspace: "dev", repositories: [
                    repositoryPolicy(workspace: "dev", fullName: "acme/rejected", mode: .readWrite)
                ])
            ])
            XCTFail("Expected durable intent write to fail")
        } catch {
            // The already accepted generation must remain owned and running.
        }
        try FileManager.default.removeItem(at: intentURL)

        try await provider.waitForPolicySync()
        let finalProgress = await provider.policySyncProgress()
        XCTAssertEqual(finalProgress?.generation, accepted.generation)
        XCTAssertEqual(finalProgress?.phase, .applied)
        let appliedRequest = try SiloProtocolDecoder.decoder().decode(
            SiloGitHubPolicyApplyRequest.self,
            from: Data(readApplyStdin(directory).utf8)
        )
        XCTAssertEqual(appliedRequest.workspaces["dev"]?.repos.map(\.canonical), ["acme/accepted"])
    }

    func testConfirmedApplyStaysAppliedWhenCompletionMarkerCannotBeWritten() async throws {
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        writePolicy(policyURL, json: "{\"schemaVersion\":1,\"workspaces\":{}}")
        let executable = makeFakeSilo(
            directory: directory,
            statusJSON: #"{"workspaces":[]}"#,
            applyJSON: Self.policyApplyLine,
            applyDelay: 0.3
        )
        let provider = GitHubProvider(
            client: SiloClient(runner: SiloCommandRunner(configuration: .init(
                homeDirectory: directory,
                testSiloExecutable: executable
            ))),
            policyStore: GitHubPolicyStore(policyURL: policyURL)
        )

        _ = try await provider.savePolicy([
            GitHubWorkspacePolicy(workspace: "dev", repositories: [
                repositoryPolicy(workspace: "dev", fullName: "acme/confirmed", mode: .readOnly)
            ])
        ])
        let intentURL = GitHubPolicyStore.intentURL(for: policyURL)
        try FileManager.default.removeItem(at: intentURL)
        try FileManager.default.createDirectory(at: intentURL, withIntermediateDirectories: false)

        try await provider.waitForPolicySync()
        let progress = await provider.policySyncProgress()
        XCTAssertEqual(progress?.phase, .applied)
        XCTAssertNil(progress?.failure)
    }

    func testSupersedingPartialEditPreservesPendingIntentAndWaitsForNewestGeneration() async throws {
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        writePolicy(policyURL, json: "{\"schemaVersion\":1,\"workspaces\":{}}")
        let executable = makeFakeSilo(
            directory: directory,
            statusJSON: #"{"workspaces":[]}"#,
            applyJSON: Self.policyApplyLine,
            applyDelay: 0.35
        )
        let runner = SiloCommandRunner(configuration: .init(homeDirectory: directory, testSiloExecutable: executable))
        let provider = GitHubProvider(client: SiloClient(runner: runner), policyStore: GitHubPolicyStore(policyURL: policyURL))

        _ = try await provider.savePolicy([
            GitHubWorkspacePolicy(workspace: "dev", repositories: [
                repositoryPolicy(workspace: "dev", fullName: "acme/one", mode: .readOnly)
            ])
        ])
        let waiter = Task { try await provider.waitForPolicySync() }
        try await Task.sleep(for: .milliseconds(60))
        let newest = try await provider.savePolicy([
            GitHubWorkspacePolicy(workspace: "playgrounds", repositories: [
                repositoryPolicy(workspace: "playgrounds", fullName: "acme/two", mode: .readWrite)
            ])
        ])

        try await waiter.value
        let maybeCompleted = await provider.policySyncProgress()
        let completed = try XCTUnwrap(maybeCompleted)
        XCTAssertEqual(completed.generation, newest.generation)
        XCTAssertEqual(completed.phase, .applied, "A waiter must follow a superseding generation through completion")
        let appliedRequest = try SiloProtocolDecoder.decoder().decode(
            SiloGitHubPolicyApplyRequest.self,
            from: Data(readApplyStdin(directory).utf8)
        )
        XCTAssertEqual(appliedRequest.workspaces["dev"]?.repos.map(\.canonical), ["acme/one"])
        XCTAssertEqual(appliedRequest.workspaces["playgrounds"]?.repos.map(\.canonical), ["acme/two"])
    }

    func testCancellationCannotClearOrCancelSupersedingGeneration() async throws {
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        writePolicy(policyURL, json: "{\"schemaVersion\":1,\"workspaces\":{}}")
        let executable = makeFakeSilo(
            directory: directory,
            statusJSON: #"{"workspaces":[]}"#,
            applyJSON: Self.policyApplyLine,
            applyDelay: 0.35
        )
        let runner = SiloCommandRunner(configuration: .init(homeDirectory: directory, testSiloExecutable: executable))
        let provider = GitHubProvider(client: SiloClient(runner: runner), policyStore: GitHubPolicyStore(policyURL: policyURL))

        _ = try await provider.savePolicy([
            GitHubWorkspacePolicy(workspace: "dev", repositories: [
                repositoryPolicy(workspace: "dev", fullName: "acme/one", mode: .readOnly)
            ])
        ])
        let cancellation = Task { await provider.cancelPolicySync() }
        try await Task.sleep(for: .milliseconds(20))
        let newest = try await provider.savePolicy([
            GitHubWorkspacePolicy(workspace: "dev", repositories: [
                repositoryPolicy(workspace: "dev", fullName: "acme/newest", mode: .readWrite)
            ])
        ])
        await cancellation.value
        try await provider.waitForPolicySync()

        let maybeCompleted = await provider.policySyncProgress()
        let completed = try XCTUnwrap(maybeCompleted)
        XCTAssertEqual(completed.generation, newest.generation)
        XCTAssertEqual(completed.phase, .applied)
        XCTAssertEqual(GitHubPolicyStore.readIntent(policyURL: policyURL)?.status, .completed)
    }

    func testRemoveAllAccessAppliesEmptyPolicyInOneInvocation() async throws {
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        writePolicy(policyURL, json: """
        {"schemaVersion":1,"workspaces":{"dev":{"capability":"abc","repos":[{"canonical":"acme/one","mode":"read-only"}]},"playgrounds":{"capability":"def","repos":[]},"personal":{"capability":"ghi","repos":[{"canonical":"acme/two","mode":"read-write"}]}}}
        """)
        let executable = makeFakeSilo(
            directory: directory,
            statusJSON: #"{"workspaces":[]}"#,
            applyJSON: Self.policyApplyLine
        )
        let runner = SiloCommandRunner(configuration: .init(homeDirectory: directory, testSiloExecutable: executable))
        let client = SiloClient(runner: runner)
        let store = GitHubPolicyStore(policyURL: policyURL)
        let provider = GitHubProvider(client: client, policyStore: store)

        _ = try await provider.clearPolicy()
        try await provider.waitForPolicySync()

        let applyCalls = applyCallCount(directory)
        XCTAssertEqual(applyCalls, 1, "Removal must be a single apply invocation")
        let stdin = readApplyStdin(directory)
        let payload = try XCTUnwrap(
            SiloProtocolDecoder.decoder().decode(SiloGitHubPolicyApplyRequest.self, from: Data(stdin.utf8))
        )
        for workspace in SetupWorkspaceConfiguration.defaults.map(\.name) {
            let entry = try XCTUnwrap(payload.workspaces[workspace])
            XCTAssertTrue(entry.repos.isEmpty, "\(workspace) must be emptied")
        }
    }

    func testResetAccessWaitsForPolicyCleanupThenRemovesCredential() async throws {
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        writePolicy(policyURL, json: """
        {"schemaVersion":1,"workspaces":{"dev":{"capability":"abc","repos":[{"canonical":"acme/one","mode":"read-only"}]}}}
        """)
        let executable = makeFakeSilo(
            directory: directory,
            statusJSON: #"{"workspaces":[]}"#,
            applyJSON: Self.policyApplyLine,
            resetCommandsSucceed: true
        )
        let provider = GitHubProvider(
            client: SiloClient(runner: SiloCommandRunner(configuration: .init(
                homeDirectory: directory,
                testSiloExecutable: executable
            ))),
            policyStore: GitHubPolicyStore(policyURL: policyURL)
        )

        let progress = try await provider.resetAccess()

        XCTAssertEqual(progress.phase, .applied)
        let calls = readLog(directory).split(separator: "\n").map(String.init)
        let applyEnd = try XCTUnwrap(calls.firstIndex { $0.contains("policy-end") })
        let removal = try XCTUnwrap(calls.firstIndex { $0.contains("reset-remove github disconnect") })
        XCTAssertLessThan(applyEnd, removal)
        XCTAssertFalse(calls.contains { $0.contains("secret-plan") || $0.contains("secret-apply") })
    }

    func testReloadedWorkspaceConfigurationScopesPolicyAndAllWorkspaceIdentity() async throws {
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        writePolicy(policyURL, json: """
        {"schemaVersion":1,"workspaces":{"dev":{"capability":"old","repos":[{"canonical":"acme/old","mode":"read-only"}]},"personal":{"capability":"keep","repos":[]}}}
        """)
        let identity = #"{"schemaVersion":1,"requestId":"identity","ok":true,"command":"identity","observedAt":"2026-08-21T00:00:00Z","result":{"target":"all","name":"Ada","email":"ada@example.test","workspaces":["development","personal","lab"]},"warnings":[],"error":null}"#
        let executable = makeFakeSilo(
            directory: directory,
            statusJSON: #"{"hostCredential":"present","workspaces":[{"workspace":"dev","capability":"old","repos":[],"shuttle":"stopped"}]}"#,
            authJSON: #"{"provider":"gh-cli","tokenKind":"oauth","accountLogin":"octocat","verifiedAt":"2026-08-21T00:00:00Z","generation":1,"storedAt":"2026-08-21T00:00:00Z","repoChecks":[]}"#,
            reposJSON: #"{"ok":true,"repos":[]}"#,
            applyJSON: Self.policyApplyLine,
            identityJSON: identity
        )
        let runner = SiloCommandRunner(configuration: .init(
            homeDirectory: directory,
            testSiloExecutable: executable
        ))
        let provider = GitHubProvider(
            client: SiloClient(runner: runner),
            policyStore: GitHubPolicyStore(policyURL: policyURL),
            workspaceConfigurations: SetupWorkspaceConfiguration.defaults
        )
        let selected = [
            SetupWorkspaceConfiguration(
                name: "development", cpus: 8, maxCPUs: 12,
                memoryGiB: 32, maxMemoryGiB: 48,
                workspaceStorageGiB: 120, runtimeStorageGiB: 100
            ),
            SetupWorkspaceConfiguration.defaults[2],
            SetupWorkspaceConfiguration(
                name: "lab", cpus: 4, maxCPUs: 12,
                memoryGiB: 16, maxMemoryGiB: 32,
                workspaceStorageGiB: 60, runtimeStorageGiB: 60
            )
        ]

        try await provider.reloadWorkspaceConfiguration(selected)
        let currentPolicy = await provider.desiredPolicy()
        let scopedPolicy = try XCTUnwrap(currentPolicy)
        XCTAssertEqual(Set(scopedPolicy.workspaces.keys), ["development", "personal", "lab"])
        XCTAssertNil(scopedPolicy.workspaces["dev"])
        XCTAssertNil(scopedPolicy.workspaces["playgrounds"])
        let scopedCatalog = try await provider.loadCatalog()
        XCTAssertTrue(
            scopedCatalog.hostCredentialPresent,
            "The host credential is global and must not disappear when the selected workspace set changes."
        )
        _ = try await provider.savePolicy([
            GitHubWorkspacePolicy(
                workspace: "development",
                repositories: [repositoryPolicy(
                    workspace: "development",
                    fullName: "acme/one",
                    mode: .readOnly
                )]
            ),
            GitHubWorkspacePolicy(workspace: "personal", repositories: []),
            GitHubWorkspacePolicy(workspace: "lab", repositories: [])
        ])
        try await provider.waitForPolicySync()

        let request = try SiloProtocolDecoder.decoder().decode(
            SiloGitHubPolicyApplyRequest.self,
            from: Data(readApplyStdin(directory).utf8)
        )
        XCTAssertEqual(Set(request.workspaces.keys), ["development", "personal", "lab"])
        XCTAssertNil(request.workspaces["dev"])
        XCTAssertNil(request.workspaces["playgrounds"])

        let result = try await provider.setIdentity(
            name: "Ada",
            email: "ada@example.test",
            workspace: nil
        )
        XCTAssertEqual(result.workspaces, ["development", "personal", "lab"])
        XCTAssertTrue(readLog(directory).contains("identity app identity --name Ada --email ada@example.test --format json"))
    }

    // MARK: - Provider account connection

    func testConnectAccountReturnsAccountFromAuthMetadata() async throws {
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        let executable = makeFakeSilo(
            directory: directory,
            statusJSON: #"{"workspaces":[]}"#,
            authJSON: #"{"provider":"gh-cli","tokenKind":"oauth","accountLogin":"octocat","verifiedAt":"2026-08-21T00:00:00Z","generation":2,"storedAt":"2026-08-21T00:00:00Z","repoChecks":[]}"#
        )
        let runner = SiloCommandRunner(configuration: .init(homeDirectory: directory, testSiloExecutable: executable))
        let provider = GitHubProvider(client: SiloClient(runner: runner), policyStore: GitHubPolicyStore(policyURL: policyURL))

        let account = try await provider.connectAccount()

        XCTAssertEqual(account?.login, "octocat")
        XCTAssertTrue(readLog(directory).contains("auth github auth --json"))
    }

    func testConnectAccountSurfacesCLIFailure() async throws {
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        let executable = makeFakeSilo(
            directory: directory,
            statusJSON: #"{"workspaces":[]}"#,
            authJSON: #"{"ok":false,"error":{"code":"SILO_HOST_CREDENTIAL_VERIFICATION_FAILED","message":"verification failed; nothing was stored","remedies":["Retry"]}}"#
        )
        let runner = SiloCommandRunner(configuration: .init(homeDirectory: directory, testSiloExecutable: executable))
        let provider = GitHubProvider(client: SiloClient(runner: runner), policyStore: GitHubPolicyStore(policyURL: policyURL))

        do {
            _ = try await provider.connectAccount()
            XCTFail("Expected connectAccount to fail")
        } catch let error as GitHubCatalogError {
            guard case .unavailable(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("verification failed"))
        }
    }

    func testConnectAccountRoutesToGhWebLoginWhenNotConfigured() async throws {
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        let executable = makeFakeSilo(
            directory: directory,
            statusJSON: #"{"workspaces":[]}"#,
            authJSON: #"{"ok":false,"error":{"code":"SILO_HOST_OAUTH_NOT_CONFIGURED","message":"gh is not authenticated and the OAuth Device Flow client ID (SILO_HOST_OAUTH_CLIENT_ID) is not set","remedies":["Run 'gh auth login' then retry","Set SILO_HOST_OAUTH_CLIENT_ID to the release's public client ID, or use the device flow (--device)"]}}"#
        )
        let runner = SiloCommandRunner(configuration: .init(homeDirectory: directory, testSiloExecutable: executable))
        let provider = GitHubProvider(client: SiloClient(runner: runner), policyStore: GitHubPolicyStore(policyURL: policyURL))

        do {
            _ = try await provider.connectAccount()
            XCTFail("Expected ghWebLoginRequired")
        } catch GitHubCatalogError.ghWebLoginRequired {
            // The view launches the installed gh web OAuth flow and retries.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testConnectAccountRoutesToDeviceFlowWhenClientIDConfigured() async throws {
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        let executable = makeFakeSilo(
            directory: directory,
            statusJSON: #"{"workspaces":[]}"#,
            authJSON: #"{"ok":false,"error":{"code":"SILO_HOST_DEVICE_FLOW_INTERACTIVE_REQUIRED","message":"OAuth Device Flow requires an interactive terminal for plain 'silo github auth'","remedies":["Use 'silo github auth --device' and complete it with --device-complete"]}}"#
        )
        let runner = SiloCommandRunner(configuration: .init(homeDirectory: directory, testSiloExecutable: executable))
        let provider = GitHubProvider(client: SiloClient(runner: runner), policyStore: GitHubPolicyStore(policyURL: policyURL))

        do {
            _ = try await provider.connectAccount()
            XCTFail("Expected deviceFlowAvailable")
        } catch GitHubCatalogError.deviceFlowAvailable {
            // Client ID is explicitly configured: the in-app device sheet is
            // the intended path.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Clean login: gh web OAuth (no unavailable device-flow input)

    private func makeFakeGh(_ directory: URL, exit: Int32 = 0) -> URL {
        let gh = directory.appendingPathComponent("gh")
        writeExecutable(gh, content: """
        #!/bin/sh
        echo "gh $*" >> "\(directory.appendingPathComponent("gh.log").path)"
        exit \(exit)
        """)
        return gh
    }

    func testLaunchGhWebLoginRunsInstalledGhWithWebFlags() async throws {
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        let fakeGh = makeFakeGh(directory)
        let runner = SiloCommandRunner(configuration: .init(homeDirectory: directory))
        let client = SiloClient(runner: runner, ghResolver: { fakeGh })
        let provider = GitHubProvider(client: client, policyStore: GitHubPolicyStore(policyURL: policyURL))

        try await provider.launchGhWebLogin()

        let ghLog = directory.appendingPathComponent("gh.log")
        let log = try String(contentsOf: ghLog, encoding: .utf8)
        XCTAssertTrue(
            log.contains("auth login --hostname github.com --git-protocol https --web --skip-ssh-key"),
            "gh web OAuth must use the exact documented flags, got: \(log)"
        )
    }

    func testLaunchGhWebLoginSurfacesMissingGh() async throws {
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        // The injected resolver reports no gh; the real host gh must never
        // be launched from a unit test.
        let runner = SiloCommandRunner(configuration: .init(homeDirectory: directory))
        let client = SiloClient(runner: runner, ghResolver: { nil })
        let provider = GitHubProvider(client: client, policyStore: GitHubPolicyStore(policyURL: policyURL))

        do {
            try await provider.launchGhWebLogin()
            XCTFail("Expected launchGhWebLogin to fail without gh")
        } catch {
            // The typed remedy must surface (gh unavailable, no device-flow
            // client ID either).
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func testGhWebLoginThenRetryAuthSucceeds() async throws {
        // gh is unauthenticated (SILO_HOST_OAUTH_NOT_CONFIGURED) -> the app
        // launches gh web login -> then retries `silo github auth --json`,
        // which now succeeds via gh reuse.
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        let fakeGh = makeFakeGh(directory)
        let executable = makeFakeSilo(
            directory: directory,
            statusJSON: #"{"workspaces":[]}"#,
            authJSON: #"{"provider":"gh-cli","tokenKind":"oauth","accountLogin":"octocat","verifiedAt":"2026-08-21T00:00:00Z","generation":1,"storedAt":"2026-08-21T00:00:00Z","repoChecks":[]}"#
        )
        let runner = SiloCommandRunner(configuration: .init(homeDirectory: directory, testSiloExecutable: executable))
        let client = SiloClient(runner: runner, ghResolver: { fakeGh })
        let provider = GitHubProvider(client: client, policyStore: GitHubPolicyStore(policyURL: policyURL))

        // Retry-auth path: launch gh web login, then acquire the account.
        try await provider.launchGhWebLogin()
        let account = try await provider.connectAccount()
        XCTAssertEqual(account?.login, "octocat")
        let ghLog = try String(contentsOf: directory.appendingPathComponent("gh.log"), encoding: .utf8)
        XCTAssertTrue(ghLog.contains("auth login"), "gh web login must be launched before the retry")
    }

    func testStartDeviceFlowSurfacesNotConfiguredRemedyVerbatim() async throws {
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        let executable = makeFakeSilo(
            directory: directory,
            statusJSON: #"{"workspaces":[]}"#,
            deviceJSON: #"{"ok":false,"error":{"code":"SILO_HOST_OAUTH_NOT_CONFIGURED","message":"host GitHub credential is not configured: gh is not authenticated and the OAuth Device Flow client ID is not set (SILO_HOST_OAUTH_CLIENT_ID)","remedies":["Run 'gh auth login'"]}}"#,
            deviceExit: 66
        )
        let runner = SiloCommandRunner(configuration: .init(homeDirectory: directory, testSiloExecutable: executable))
        let provider = GitHubProvider(client: SiloClient(runner: runner), policyStore: GitHubPolicyStore(policyURL: policyURL))

        do {
            _ = try await provider.startDeviceFlow()
            XCTFail("Expected notConfigured")
        } catch GitHubCatalogError.notConfigured(let message) {
            XCTAssertTrue(message.contains("SILO_HOST_OAUTH_CLIENT_ID"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testStartDeviceFlowReturnsCodeAndPollHandle() async throws {
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        let executable = makeFakeSilo(
            directory: directory,
            statusJSON: #"{"workspaces":[]}"#,
            deviceJSON: #"{"ok":true,"deviceId":"device-code-1","code":"ABCD-EFGH","verificationUri":"https://github.com/login/device","expiresAt":"2026-08-21T12:00:00Z","interval":5}"#
        )
        let runner = SiloCommandRunner(configuration: .init(homeDirectory: directory, testSiloExecutable: executable))
        let provider = GitHubProvider(client: SiloClient(runner: runner), policyStore: GitHubPolicyStore(policyURL: policyURL))

        let start = try await provider.startDeviceFlow()
        XCTAssertEqual(start.deviceId, "device-code-1")
        XCTAssertEqual(start.code, "ABCD-EFGH")
        XCTAssertEqual(start.verificationUri, "https://github.com/login/device")
        XCTAssertEqual(start.interval, 5)
        XCTAssertNotNil(start.expiresAt)
        XCTAssertTrue(readLog(directory).contains("device github auth --device --format json"))
    }

    // MARK: - Device-flow state machine

    func testDeviceFlowSessionPollingAndCompletion() async throws {
        let session = GitHubDeviceFlowSession(
            startDeviceFlow: {
                SiloDeviceFlowStart(
                    deviceId: "d1",
                    code: "CODE-1",
                    verificationUri: "https://github.com/login/device",
                    expiresAt: Date().addingTimeInterval(900),
                    interval: 5
                )
            },
            pollDeviceFlow: { _ in
                SiloDeviceFlowPoll(status: .pending, interval: 5, accountLogin: nil)
            }
        )
        let firstDelay = await session.begin()
        XCTAssertEqual(firstDelay, 5)
        guard case .showingCode(let code, _, _, _) = session.phase else {
            return XCTFail("Expected showingCode, got \(session.phase)")
        }
        XCTAssertEqual(code, "CODE-1")
        let firstPoll = await session.poll()
        XCTAssertEqual(firstPoll, 5)
        XCTAssertEqual(session.phase, .polling)
        let secondPoll = await session.poll()
        XCTAssertEqual(secondPoll, 5)
    }

    func testDeviceFlowSessionSlowDownBacksOffThenAuthorizes() async throws {
        var polls = 0
        let session = GitHubDeviceFlowSession(
            startDeviceFlow: {
                SiloDeviceFlowStart(
                    deviceId: "d1",
                    code: "CODE-1",
                    verificationUri: "https://github.com/login/device",
                    expiresAt: Date().addingTimeInterval(900),
                    interval: 5
                )
            },
            pollDeviceFlow: { _ in
                polls += 1
                if polls == 1 {
                    return SiloDeviceFlowPoll(status: .slowDown, interval: 15, accountLogin: nil)
                }
                return SiloDeviceFlowPoll(status: .authorized, interval: nil, accountLogin: "octocat")
            }
        )
        _ = await session.begin()
        let backoff = await session.poll()
        XCTAssertEqual(backoff, 15)
        XCTAssertEqual(session.phase, .backoff(seconds: 15))
        let finalPoll = await session.poll()
        XCTAssertNil(finalPoll)
        XCTAssertEqual(session.phase, .complete(accountLogin: "octocat"))
    }

    func testDeviceFlowSessionExpiredAndDeniedEndTheFlow() async throws {
        let expired = GitHubDeviceFlowSession(
            startDeviceFlow: { SiloDeviceFlowStart(deviceId: "d", code: "C", verificationUri: "https://github.com/login/device", expiresAt: Date(), interval: 5) },
            pollDeviceFlow: { _ in SiloDeviceFlowPoll(status: .expired, interval: nil, accountLogin: nil) }
        )
        _ = await expired.begin()
        let expiredPoll = await expired.poll()
        XCTAssertNil(expiredPoll)
        XCTAssertEqual(expired.phase, .expired)

        let denied = GitHubDeviceFlowSession(
            startDeviceFlow: { SiloDeviceFlowStart(deviceId: "d", code: "C", verificationUri: "https://github.com/login/device", expiresAt: Date(), interval: 5) },
            pollDeviceFlow: { _ in SiloDeviceFlowPoll(status: .denied, interval: nil, accountLogin: nil) }
        )
        _ = await denied.begin()
        let deniedPoll = await denied.poll()
        XCTAssertNil(deniedPoll)
        XCTAssertEqual(denied.phase, .denied)
    }

    func testDeviceFlowSessionStartFailureReportsFailed() async throws {
        let session = GitHubDeviceFlowSession(
            startDeviceFlow: { throw SiloClientError.rawCLIError(code: "SILO_HOST_OAUTH_NOT_CONFIGURED", message: "not configured remedy") },
            pollDeviceFlow: { _ in SiloDeviceFlowPoll(status: .pending, interval: nil, accountLogin: nil) }
        )
        let delay = await session.begin()
        XCTAssertNil(delay)
        guard case .failed(let message) = session.phase else {
            return XCTFail("Expected failed, got \(session.phase)")
        }
        XCTAssertEqual(message, "not configured remedy")
    }

    func testDeviceFlowPollOutcomeMapsTypedCLIErrors() {
        func poll(from error: SiloClientError) -> SiloDeviceFlowPoll {
            GitHubDeviceFlowSession.pollOutcome(for: error)
        }
        XCTAssertEqual(
            poll(from: .rawCLIError(code: "SILO_DEVICE_EXPIRED", message: nil)),
            SiloDeviceFlowPoll(status: .expired, interval: nil, accountLogin: nil)
        )
        XCTAssertEqual(
            poll(from: .rawCLIError(code: "SILO_DEVICE_DENIED", message: nil)),
            SiloDeviceFlowPoll(status: .denied, interval: nil, accountLogin: nil)
        )
        XCTAssertEqual(
            poll(from: .rawCLIError(code: "SILO_DEVICE_SLOW_DOWN", message: nil)),
            SiloDeviceFlowPoll(status: .slowDown, interval: nil, accountLogin: nil)
        )
        XCTAssertEqual(
            poll(from: .rawCLIError(code: "SILO_HOST_CREDENTIAL_VERIFICATION_FAILED", message: nil)),
            SiloDeviceFlowPoll(status: .denied, interval: nil, accountLogin: nil)
        )
        XCTAssertEqual(
            poll(from: .protocolFailure(SiloProtocolError(code: "SILO_DEVICE_EXPIRED", message: "x", recovery: nil, workspace: nil, retryable: false))),
            SiloDeviceFlowPoll(status: .expired, interval: nil, accountLogin: nil)
        )
        XCTAssertEqual(
            poll(from: .unavailable("network")),
            SiloDeviceFlowPoll(status: .denied, interval: nil, accountLogin: nil)
        )
    }

    func testDeviceFlowDeviceCompleteDecodesThroughSiloClient() async throws {
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        let executable = makeFakeSilo(
            directory: directory,
            statusJSON: #"{"workspaces":[]}"#,
            deviceCompleteJSON: #"{"ok":true,"status":"authorized","metadata":{"provider":"oauth-device-flow","tokenKind":"oauth","accountLogin":"octocat","verifiedAt":"2026-08-21T00:00:00Z","generation":1,"storedAt":"2026-08-21T00:00:00Z","repoChecks":[]}}"#
        )
        let runner = SiloCommandRunner(configuration: .init(homeDirectory: directory, testSiloExecutable: executable))
        let client = SiloClient(runner: runner)
        let provider = GitHubProvider(client: client, policyStore: GitHubPolicyStore(policyURL: policyURL))

        let poll = try await provider.pollDeviceFlow(deviceId: "device-code-1")
        XCTAssertEqual(poll.status, .authorized)
        XCTAssertEqual(poll.accountLogin, "octocat")
        XCTAssertTrue(readLog(directory).contains("device-complete github auth --device-complete device-code-1 --format json"))
    }

    func testDeviceFlowDeviceCompleteExpiredAndDenied() async throws {
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        let executable = makeFakeSilo(
            directory: directory,
            statusJSON: #"{"workspaces":[]}"#,
            deviceCompleteJSON: #"{"ok":false,"status":"expired","error":{"code":"SILO_DEVICE_EXPIRED","message":"The code expired"}}"#,
            deviceCompleteExit: 76
        )
        let runner = SiloCommandRunner(configuration: .init(homeDirectory: directory, testSiloExecutable: executable))
        let provider = GitHubProvider(client: SiloClient(runner: runner), policyStore: GitHubPolicyStore(policyURL: policyURL))

        let poll = try await provider.pollDeviceFlow(deviceId: "device-code-1")
        XCTAssertEqual(poll.status, .expired)
    }

    // MARK: - Push permission hints

    func testPushDeniedReposStayReadOnly() {
        let blocked = GitHubRepository(
            id: 1,
            fullName: "acme/one",
            name: "one",
            owner: GitHubOwnerAccount(login: "acme", id: 7, type: nil),
            private: true,
            defaultBranch: "main",
            canPush: false,
            inPolicy: true
        )
        XCTAssertEqual(blocked.effectiveMode(.readWrite), .readOnly)
        XCTAssertEqual(blocked.effectiveMode(.readOnly), .readOnly)

        let writable = GitHubRepository(
            id: 2,
            fullName: "acme/two",
            name: "two",
            owner: GitHubOwnerAccount(login: "acme", id: 7, type: nil),
            private: true,
            defaultBranch: "main",
            canPush: true,
            inPolicy: false
        )
        XCTAssertEqual(writable.effectiveMode(.readWrite), .readWrite)

        // A missing push capability keeps writes disabled until the host policy allows them.
        let connect = GitHubRepository(
            id: 3,
            fullName: "acme/three",
            name: "three",
            owner: GitHubOwnerAccount(login: "acme", id: 7, type: nil),
            private: true,
            defaultBranch: "main"
        )
        XCTAssertEqual(connect.effectiveMode(.readWrite), .readWrite)
    }

    // MARK: - Repository picker: multiple owners per workspace

    func testPolicyPrefillMapsEveryPolicyEntryToModes() {
        let policyWorkspace = GitHubPolicyWorkspace(
            capability: "abc",
            repos: [
                GitHubPolicyRepository(canonical: "acme/one", mode: .readOnly),
                GitHubPolicyRepository(canonical: "org/two", mode: .readWrite)
            ]
        )

        let modes = SetupView.policyPrefill(policyWorkspace: policyWorkspace)

        // Every policy entry survives the prefill (cross-owner preserved);
        // the provider's catalog merge owns synthesis, so no catalog is
        // extended here.
        XCTAssertEqual(Set(modes.keys), ["acme/one", "org/two"])
        XCTAssertEqual(modes["acme/one"], .readOnly)
        XCTAssertEqual(modes["org/two"], .readWrite)
    }

    func testPolicyPrefillSkipsMalformedCanonicals() {
        let policyWorkspace = GitHubPolicyWorkspace(
            capability: "abc",
            repos: [
                GitHubPolicyRepository(canonical: "acme/one", mode: .readOnly),
                GitHubPolicyRepository(canonical: "not-a-canonical", mode: .readWrite)
            ]
        )

        let modes = SetupView.policyPrefill(policyWorkspace: policyWorkspace)

        XCTAssertEqual(modes, ["acme/one": .readOnly])
    }

    func testEditorSelectionSpansOwners() {
        let acmeID = GitHubProvider.stableID("acme")
        let orgID = GitHubProvider.stableID("org")
        let acme = GitHubOwner(
            id: acmeID,
            account: GitHubOwnerAccount(login: "acme", id: acmeID, type: nil)
        )
        let org = GitHubOwner(
            id: orgID,
            account: GitHubOwnerAccount(login: "org", id: orgID, type: "Organization")
        )
        var draft = WorkspaceRepositoryDraft.initial("dev")
        draft.repositoryModes = ["acme/one": .readOnly, "org/two": .readWrite]

        let entries = SetupView.repositoryPolicyEntries(
            workspace: "dev",
            draft: draft,
            owners: [acme, org],
            repositoriesByOwner: [
                acmeID: [GitHubRepository(
                    id: GitHubProvider.stableID("acme/one"),
                    fullName: "acme/one",
                    name: "one",
                    owner: acme.account,
                    private: true,
                    defaultBranch: "main"
                )],
                orgID: [GitHubRepository(
                    id: GitHubProvider.stableID("org/two"),
                    fullName: "org/two",
                    name: "two",
                    owner: org.account,
                    private: true,
                    defaultBranch: "main"
                )]
            ]
        )
        XCTAssertEqual(Set(entries.map(\.fullName)), ["acme/one", "org/two"])
        XCTAssertEqual(Set(entries.map(\.ownerID)), [acmeID, orgID])
    }

    // MARK: - Port warning surface (PortWarnings contract)

    private func makeSnapshot(
        skippedPorts: [Int] = [],
        portWarning: String = ""
    ) -> SiloWorkspaceSnapshot {
        SiloWorkspaceSnapshot(
            id: "dev",
            purpose: "Test workspace",
            lifecycle: .stopped,
            freshness: .fresh,
            quarantine: SiloQuarantineSnapshot(state: .clear, reason: nil),
            secrets: SiloSecretsSnapshot(state: .active, pendingCount: 0, reason: nil),
            resources: SiloResourceSnapshot(
                cpus: "2",
                maxCpus: "8",
                memory: "4GiB",
                maxMemory: "16GiB",
                rootDisk: "20GiB"
            ),
            network: SiloNetworkSnapshot(host: "dev.silo.test", ip: "127.0.0.10"),
            actionCapabilities: SiloActionCapabilities(
                canStart: true,
                canStop: true,
                canRestart: true,
                canOpenTerminal: true,
                canPush: true
            ),
            skippedPorts: skippedPorts,
            portWarning: portWarning
        )
    }

    func testWorkspaceSnapshotDecodesSkippedPortsAndWarning() throws {
        let snapshot = makeSnapshot(
            skippedPorts: [3000],
            portWarning: "Port 3000 is already in use; it was not published."
        )
        let data = try JSONEncoder().encode(snapshot)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"skippedPorts\""), "Skipped ports must be encoded")
        XCTAssertTrue(json.contains("\"portWarning\""), "Port warning must be encoded")

        let decoded = try SiloProtocolDecoder.decoder().decode(SiloWorkspaceSnapshot.self, from: data)
        XCTAssertEqual(decoded.id, "dev")
        XCTAssertEqual(decoded.skippedPorts, [3000])
        XCTAssertEqual(decoded.portWarning, "Port 3000 is already in use; it was not published.")
    }

    // MARK: - Fixture provider

    func testFixtureProviderScenarios() async throws {
        let success = GitHubFixtureProvider(scenario: "success")
        let catalog = try await success.loadCatalog()
        XCTAssertEqual(catalog.account?.login, "octocat")
        XCTAssertEqual(catalog.owners.first?.id, 7)
        XCTAssertEqual(catalog.repositoriesByOwner[7]?.map(\.id), [1001, 1002])

        let unavailable = GitHubFixtureProvider(scenario: "unavailable")
        do {
            _ = try await unavailable.loadCatalog()
            XCTFail("Expected unavailable")
        } catch let error as GitHubCatalogError {
            guard case .unavailable(let message) = error else { return XCTFail("Unexpected error") }
            XCTAssertEqual(message, "GitHub could not be reached. Try again later.")
        }

        let empty = GitHubFixtureProvider(scenario: "no-owner")
        let emptyCatalog = try await empty.loadCatalog()
        XCTAssertEqual(emptyCatalog.account?.login, "octocat")
        XCTAssertTrue(emptyCatalog.owners.isEmpty)
        XCTAssertTrue(emptyCatalog.repositoriesByOwner.isEmpty)

        let disconnected = GitHubFixtureProvider(scenario: "disconnected")
        let disconnectedCatalog = try await disconnected.loadCatalog()
        XCTAssertFalse(disconnectedCatalog.hostCredentialPresent)
        XCTAssertNil(disconnectedCatalog.account)
        XCTAssertTrue(disconnectedCatalog.repositoriesByOwner.isEmpty)
        let connectedAccount = try await disconnected.connectAccount()
        XCTAssertEqual(connectedAccount?.login, "octocat")
        let connectedCatalog = try await disconnected.loadCatalog()
        XCTAssertTrue(connectedCatalog.hostCredentialPresent)
        XCTAssertEqual(connectedCatalog.account?.login, "octocat")
        XCTAssertEqual(connectedCatalog.repositoriesByOwner[7]?.count, 2)

        let retry = GitHubFixtureProvider(scenario: "cancel-retry")
        do {
            _ = try await retry.loadCatalog()
            XCTFail("First load must fail")
        } catch {
            // Expected.
        }
        let second = try await retry.loadCatalog()
        XCTAssertEqual(second.account?.login, "octocat")
    }
}
