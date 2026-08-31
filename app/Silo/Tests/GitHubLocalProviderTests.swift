import Foundation
import XCTest
@testable import Silo

/// Path C Phase 3 unit tests: local provider catalog/commit behavior against
/// a fake `msw` CLI, policy-file strict decoding, the directory watcher, and
/// the §8 user-facing labels.
@MainActor
final class GitHubLocalProviderTests: XCTestCase {
    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-github-local-\(UUID().uuidString)", isDirectory: true)
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

    private static let handshakeLine = #"{"schemaVersion":1,"requestId":"handshake","ok":true,"command":"handshake","observedAt":"2026-08-21T00:00:00Z","result":{"protocolVersion":1,"mswVersion":"3.1.0","platform":{"os":"macOS","architecture":"arm64"},"configurationAvailable":true,"runtimeAvailable":true,"capabilities":{"jsonState":true,"jsonMetrics":true,"jsonLogs":true,"plans":true,"bootstrapEvents":true,"jq":true,"workspaceCount":3},"exitCodes":{}},"warnings":[],"error":null}"#

    private static let policyApplyLine = #"{"schemaVersion":1,"requestId":"apply","ok":true,"command":"github-policy-apply","observedAt":"2026-08-21T00:00:00Z","result":{"applied":true,"provisioned":true,"committed":true,"workspaces":[{"workspace":"dev","capability":"0123456789abcdef0123456789abcdef0123456789abcdef","repos":[]}]},"warnings":[],"error":null}"#
    private static let policyConflictLine = #"{"schemaVersion":1,"requestId":"apply","ok":false,"command":"github-policy-apply","observedAt":"2026-08-21T00:00:00Z","result":null,"warnings":[],"error":{"code":"MSW_OPERATION_CONFLICT","message":"Another GitHub operation is already running for a workspace.","recovery":"Wait for it to finish, then retry the policy apply.","workspace":null,"retryable":true}}"#

    /// Single-quotes a value for /bin/sh so embedded JSON with apostrophes
    /// (e.g. remedies like "Run 'gh auth login'") cannot break the script.
    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    /// Builds a fake `msw` executable that logs every non-handshake call to a
    /// log file (path baked in) and answers `github status`, `github auth`,
    /// `app github-policy-apply` (capturing stdin), and the device flow.
    private func makeFakeMSW(
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
        identityJSON: String? = nil
    ) -> URL {
        let log = directory.appendingPathComponent("calls.log")
        let applyStdin = directory.appendingPathComponent("apply.stdin.json")
        let executable = directory.appendingPathComponent("msw")
        var lines = [
            "#!/bin/sh",
            "LOG=\"\(log.path)\"",
            "APPLY_STDIN=\"\(applyStdin.path)\"",
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

    /// Counts lines in the fake-MSW call log whose command token is
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
        let ownerID = GitHubLocalProvider.stableID(owner)
        return GitHubRepositoryPolicy(
            workspace: workspace,
            repositoryID: GitHubLocalProvider.stableID(fullName),
            fullName: fullName,
            installationID: ownerID,
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

    func testConciseLocalGitHubStrings() {
        XCTAssertEqual(GitHubLocalStrings.noReposCopy, "No repositories found.")
        XCTAssertEqual(GitHubLocalStrings.settingsNoCredential, "GitHub account not connected on this Mac")
    }

    // MARK: - Canonicalization

    func testCanonicalRepositoryNormalization() {
        XCTAssertEqual(GitHubLocalProvider.canonicalize("Acme/One"), "acme/one")
        XCTAssertEqual(GitHubLocalProvider.canonicalize("acme/one.git"), "acme/one")
        XCTAssertEqual(GitHubLocalProvider.canonicalize("  Acme/One.git  "), "acme/one")
        XCTAssertTrue(GitHubLocalProvider.isValidCanonical("acme/one"))
        XCTAssertTrue(GitHubLocalProvider.isValidCanonical("octocat/hello-world"))
        XCTAssertFalse(GitHubLocalProvider.isValidCanonical("acme"))
        XCTAssertFalse(GitHubLocalProvider.isValidCanonical("Acme/One"))
        XCTAssertFalse(GitHubLocalProvider.isValidCanonical("acme/one.git"))
        XCTAssertFalse(GitHubLocalProvider.isValidCanonical(""))
        XCTAssertEqual(GitHubLocalProvider.splitCanonical("acme/one")?.owner, "acme")
        XCTAssertEqual(GitHubLocalProvider.splitCanonical("acme/one")?.name, "one")
        XCTAssertNil(GitHubLocalProvider.splitCanonical("acme"))
        // Stable ids: equal for equal names, distinct for distinct names.
        XCTAssertEqual(GitHubLocalProvider.stableID("acme/one"), GitHubLocalProvider.stableID("acme/one"))
        XCTAssertNotEqual(GitHubLocalProvider.stableID("acme/one"), GitHubLocalProvider.stableID("acme/two"))
        XCTAssertGreaterThan(GitHubLocalProvider.stableID("acme/one"), 0)
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
        try FileManager.default.replaceItemAt(url, withItemAt: tmp)

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
        let executable = makeFakeMSW(
            directory: directory,
            statusJSON: #"{"mode":"local","workspaces":[{"workspace":"dev","capability":"minted","repos":[{"canonical":"acme/one","mode":"read-only"}],"shuttle":"stopped","hostCredential":"present"}]}"#,
            authJSON: #"{"provider":"gh-cli","tokenKind":"oauth","accountLogin":"octocat","verifiedAt":"2026-08-21T00:00:00Z","generation":1,"storedAt":"2026-08-21T00:00:00Z","repoChecks":[]}"#,
            reposJSON: #"{"ok":true,"mode":"local","repos":[{"canonical":"acme/two","name":"two","owner":"acme","private":true,"permissions":{"pull":true,"push":true},"inPolicy":false},{"canonical":"acme/one","name":"one","owner":"acme","private":true,"permissions":{"pull":true,"push":false},"inPolicy":true},{"canonical":"org/repo","name":"repo","owner":"org","private":false,"permissions":{"pull":true,"push":true},"inPolicy":false}]}"#
        )
        let runner = MSWCommandRunner(configuration: .init(homeDirectory: directory, testMSWExecutable: executable))
        let client = MSWClient(runner: runner)
        let store = GitHubPolicyStore(policyURL: policyURL)
        let provider = GitHubLocalProvider(client: client, policyStore: store)

        let catalog = try await provider.loadCatalog()

        XCTAssertTrue(catalog.hostCredentialPresent)
        XCTAssertEqual(catalog.account?.login, "octocat")
        XCTAssertEqual(catalog.installations.count, 2, "One synthetic installation per owner")
        let acmeID = GitHubLocalProvider.stableID("acme")
        let orgID = GitHubLocalProvider.stableID("org")
        XCTAssertEqual(Set(catalog.installations.map(\.id)), [acmeID, orgID])
        XCTAssertNil(catalog.installations.first?.repositorySelection)

        let acmeRepos = try XCTUnwrap(catalog.repositoriesByInstallation[acmeID])
        XCTAssertEqual(acmeRepos.map(\.fullName), ["acme/one", "acme/two"], "Repos sorted by canonical")
        let one = try XCTUnwrap(acmeRepos.first { $0.fullName == "acme/one" })
        XCTAssertEqual(one.id, GitHubLocalProvider.stableID("acme/one"))
        XCTAssertEqual(one.name, "one")
        XCTAssertEqual(one.canPush, false)
        XCTAssertEqual(one.inPolicy, true)
        let two = try XCTUnwrap(acmeRepos.first { $0.fullName == "acme/two" })
        XCTAssertEqual(two.canPush, true)
        XCTAssertEqual(two.inPolicy, false)
        XCTAssertEqual(catalog.repositoriesByInstallation[orgID]?.map(\.fullName), ["org/repo"])
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
        let executable = makeFakeMSW(
            directory: directory,
            statusJSON: #"{"mode":"local","workspaces":[{"workspace":"dev","capability":"minted","repos":[{"canonical":"acme/one","mode":"read-only"}],"shuttle":"stopped","hostCredential":"present"}]}"#,
            authJSON: #"{"provider":"gh-cli","tokenKind":"oauth","accountLogin":"octocat","verifiedAt":"2026-08-21T00:00:00Z","generation":1,"storedAt":"2026-08-21T00:00:00Z","repoChecks":[]}"#,
            reposJSON: #"{"ok":true,"mode":"local","repos":[{"canonical":"acme/two","name":"two","owner":"acme","private":true,"permissions":{"pull":true,"push":true},"inPolicy":false}]}"#
        )
        let runner = MSWCommandRunner(configuration: .init(homeDirectory: directory, testMSWExecutable: executable))
        let provider = GitHubLocalProvider(client: MSWClient(runner: runner), policyStore: GitHubPolicyStore(policyURL: policyURL))

        // Load, then refresh (a second load): BOTH must re-merge the grant.
        let first = try await provider.loadCatalog()
        let refreshed = try await provider.loadCatalog()

        let acmeID = GitHubLocalProvider.stableID("acme")
        let acmeOneID = GitHubLocalProvider.stableID("acme/one")
        for catalog in [first, refreshed] {
            XCTAssertTrue(catalog.hostCredentialPresent)
            let acmeRepos = try XCTUnwrap(catalog.repositoriesByInstallation[acmeID])
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
            installations: refreshed.installations,
            repositoriesByInstallation: refreshed.repositoriesByInstallation,
            accessMode: .local
        )
        XCTAssertEqual(entries.map(\.fullName), ["acme/one"])
        XCTAssertEqual(entries.first?.mode, .readOnly)
    }

    func testLoadCatalogWithoutCredentialSkipsDiscoveryButMergesPolicyGrants() async throws {
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        writePolicy(policyURL, json: "{\"schemaVersion\":1,\"workspaces\":{\"dev\":{\"repos\":[{\"canonical\":\"acme/one\",\"mode\":\"read-only\"}]}}}")
        let executable = makeFakeMSW(
            directory: directory,
            statusJSON: #"{"mode":"local","workspaces":[{"workspace":"dev","capability":"missing","repos":[{"canonical":"acme/one","mode":"read-only"}],"shuttle":"stopped","hostCredential":"missing"}]}"#,
            reposJSON: #"{"ok":true,"mode":"local","repos":[]}"#
        )
        let runner = MSWCommandRunner(configuration: .init(homeDirectory: directory, testMSWExecutable: executable))
        let provider = GitHubLocalProvider(client: MSWClient(runner: runner), policyStore: GitHubPolicyStore(policyURL: policyURL))

        let catalog = try await provider.loadCatalog()

        XCTAssertFalse(catalog.hostCredentialPresent)
        XCTAssertNil(catalog.account)
        // Discovery is skipped without a credential, but the existing
        // policy-only grant is still merged so it stays visible and editable.
        let acmeID = GitHubLocalProvider.stableID("acme")
        XCTAssertEqual(catalog.installations.map(\.id), [acmeID])
        XCTAssertEqual(
            catalog.repositoriesByInstallation[acmeID]?.map(\.fullName),
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
        let executable = makeFakeMSW(
            directory: directory,
            statusJSON: #"{"mode":"local","workspaces":[{"workspace":"dev","capability":"minted","repos":[],"shuttle":"stopped","hostCredential":"present"}]}"#,
            reposJSON: #"{"ok":false,"error":{"code":"MSW_REPOSITORY_DISCOVERY_FAILED","message":"GitHub API discovery failed","remedies":["Retry"]}}"#,
            reposExit: 1
        )
        let runner = MSWCommandRunner(configuration: .init(homeDirectory: directory, testMSWExecutable: executable))
        let provider = GitHubLocalProvider(client: MSWClient(runner: runner), policyStore: GitHubPolicyStore(policyURL: policyURL))

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

    func testLoadCatalogRejectsNonLocalMode() async throws {
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        writePolicy(policyURL, json: "{\"schemaVersion\":1,\"workspaces\":{}}")
        let executable = makeFakeMSW(
            directory: directory,
            statusJSON: #"{"mode":"connect","workspaces":[]}"#
        )
        let runner = MSWCommandRunner(configuration: .init(homeDirectory: directory, testMSWExecutable: executable))
        let provider = GitHubLocalProvider(client: MSWClient(runner: runner), policyStore: GitHubPolicyStore(policyURL: policyURL))

        do {
            _ = try await provider.loadCatalog()
            XCTFail("Expected a non-local-mode error")
        } catch let error as GitHubCatalogError {
            guard case .notLocalMode = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    // MARK: - Provider commit (single apply, full desired policy)

    func testCommitAppliesFullPolicyInOneInvocation() async throws {
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        writePolicy(policyURL, json: """
        {"schemaVersion":1,"workspaces":{"dev":{"capability":"abc","repos":[{"canonical":"acme/one","mode":"read-only"}]},"playgrounds":{"capability":"def","repos":[{"canonical":"acme/three","mode":"read-only"}]}}}
        """)
        let executable = makeFakeMSW(
            directory: directory,
            statusJSON: #"{"mode":"local","workspaces":[]}"#,
            applyJSON: Self.policyApplyLine
        )
        let runner = MSWCommandRunner(configuration: .init(homeDirectory: directory, testMSWExecutable: executable))
        let client = MSWClient(runner: runner)
        let store = GitHubPolicyStore(policyURL: policyURL)
        let provider = GitHubLocalProvider(client: client, policyStore: store)

        let ownerID = GitHubLocalProvider.stableID("acme")
        let desiredPolicy = [
            GitHubWorkspacePolicy(workspace: "dev", repositories: [
                GitHubRepositoryPolicy(
                    workspace: "dev",
                    repositoryID: GitHubLocalProvider.stableID("acme/one"),
                    fullName: "acme/one",
                    installationID: ownerID,
                    ownerID: ownerID,
                    ownerLogin: "acme",
                    ownerType: nil,
                    mode: .readWrite
                ),
                GitHubRepositoryPolicy(
                    workspace: "dev",
                    repositoryID: GitHubLocalProvider.stableID("acme/two"),
                    fullName: "acme/two",
                    installationID: ownerID,
                    ownerID: ownerID,
                    ownerLogin: "acme",
                    ownerType: nil,
                    mode: .readOnly
                )
            ]),
            // An edited workspace with no entries removes all of its access.
            GitHubWorkspacePolicy(workspace: "playgrounds", repositories: [])
        ]

        try await provider.commit(desiredPolicy)

        // ONE apply invocation; no sequential policy-set calls.
        let log = readLog(directory)
        let applyCalls = applyCallCount(directory)
        XCTAssertEqual(applyCalls, 1, "The desired policy must be applied in exactly one invocation")
        XCTAssertFalse(log.contains("policy-set "), "No sequential per-repo policy calls are allowed")

        // Stdin carries the FULL desired policy: every workspace, edited
        // workspaces replaced, untouched workspaces preserved.
        let stdin = readApplyStdin(directory)
        let payload = try XCTUnwrap(
            MSWProtocolDecoder.decoder().decode(MSWGitHubPolicyApplyRequest.self, from: Data(stdin.utf8))
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

    func testCommitRetriesTransientOperationConflict() async throws {
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        writePolicy(policyURL, json: """
        {"schemaVersion":1,"workspaces":{"dev":{"capability":"abc","repos":[{"canonical":"acme/one","mode":"read-only"}]}}}
        """)
        let executable = makeFakeMSW(
            directory: directory,
            statusJSON: #"{"mode":"local","workspaces":[]}"#,
            applyJSON: Self.policyApplyLine,
            applyConflictsBeforeSuccess: 1
        )
        let runner = MSWCommandRunner(configuration: .init(
            homeDirectory: directory,
            testMSWExecutable: executable
        ))
        let provider = GitHubLocalProvider(
            client: MSWClient(runner: runner),
            policyStore: GitHubPolicyStore(policyURL: policyURL)
        )
        let ownerID = GitHubLocalProvider.stableID("acme")
        let policy = [
            GitHubWorkspacePolicy(workspace: "dev", repositories: [
                GitHubRepositoryPolicy(
                    workspace: "dev",
                    repositoryID: GitHubLocalProvider.stableID("acme/one"),
                    fullName: "acme/one",
                    installationID: ownerID,
                    ownerID: ownerID,
                    ownerLogin: "acme",
                    ownerType: nil,
                    mode: .readWrite
                )
            ])
        ]

        try await provider.commit(policy)

        XCTAssertEqual(applyCallCount(directory), 2)
    }

    func testCommitPreservesUntouchedWorkspaceEntries() async throws {
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        writePolicy(policyURL, json: """
        {"schemaVersion":1,"workspaces":{"personal":{"capability":"ghi","repos":[{"canonical":"acme/two","mode":"read-write"}]}}}
        """)
        let executable = makeFakeMSW(
            directory: directory,
            statusJSON: #"{"mode":"local","workspaces":[]}"#,
            applyJSON: Self.policyApplyLine
        )
        let runner = MSWCommandRunner(configuration: .init(homeDirectory: directory, testMSWExecutable: executable))
        let client = MSWClient(runner: runner)
        let store = GitHubPolicyStore(policyURL: policyURL)
        let provider = GitHubLocalProvider(client: client, policyStore: store)

        let ownerID = GitHubLocalProvider.stableID("acme")
        let desiredPolicy = [
            GitHubWorkspacePolicy(workspace: "dev", repositories: [
                GitHubRepositoryPolicy(
                    workspace: "dev",
                    repositoryID: GitHubLocalProvider.stableID("acme/one"),
                    fullName: "acme/one",
                    installationID: ownerID,
                    ownerID: ownerID,
                    ownerLogin: "acme",
                    ownerType: nil,
                    mode: .readOnly
                )
            ])
        ]

        try await provider.commit(desiredPolicy)

        let stdin = readApplyStdin(directory)
        let payload = try XCTUnwrap(
            MSWProtocolDecoder.decoder().decode(MSWGitHubPolicyApplyRequest.self, from: Data(stdin.utf8))
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
        let executable = makeFakeMSW(
            directory: directory,
            statusJSON: #"{"mode":"local","workspaces":[]}"#,
            applyJSON: notApplied
        )
        let runner = MSWCommandRunner(configuration: .init(homeDirectory: directory, testMSWExecutable: executable))
        let client = MSWClient(runner: runner)
        let store = GitHubPolicyStore(policyURL: policyURL)
        let provider = GitHubLocalProvider(client: client, policyStore: store)

        do {
            try await provider.commit([
                GitHubWorkspacePolicy(workspace: "dev", repositories: [
                    repositoryPolicy(workspace: "dev", fullName: "acme/one", mode: .readOnly)
                ])
            ])
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
        let failure = #"{"schemaVersion":1,"requestId":"apply","ok":false,"command":"github-policy-apply","observedAt":null,"result":null,"warnings":[],"error":{"code":"MSW_TRANSPORT_PROVISION_FAILED","message":"Transport provisioning failed; the policy was rolled back","recovery":"Retry the policy apply","workspace":"dev","retryable":true}}"#
        let executable = makeFakeMSW(
            directory: directory,
            statusJSON: #"{"mode":"local","workspaces":[]}"#,
            applyJSON: failure,
            applyExit: 77
        )
        let runner = MSWCommandRunner(configuration: .init(homeDirectory: directory, testMSWExecutable: executable))
        let client = MSWClient(runner: runner)
        let store = GitHubPolicyStore(policyURL: policyURL)
        let provider = GitHubLocalProvider(client: client, policyStore: store)

        do {
            try await provider.commit([
                GitHubWorkspacePolicy(workspace: "dev", repositories: [
                    repositoryPolicy(workspace: "dev", fullName: "acme/one", mode: .readOnly)
                ])
            ])
            XCTFail("Expected commit to throw on the CLI's typed failure")
        } catch let error as GitHubPolicyApplyError {
            guard case .failed(let failure) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(failure.code, "MSW_TRANSPORT_PROVISION_FAILED")
            XCTAssertTrue(failure.message.contains("rolled back"))
        }
    }

    func testBackgroundApplyPersistsIntentAndFinalGatingState() async throws {
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        writePolicy(policyURL, json: "{\"schemaVersion\":1,\"workspaces\":{}}")
        let executable = makeFakeMSW(
            directory: directory,
            statusJSON: #"{"mode":"local","workspaces":[]}"#,
            applyJSON: Self.policyApplyLine,
            applyDelay: 0.25
        )
        let runner = MSWCommandRunner(configuration: .init(homeDirectory: directory, testMSWExecutable: executable))
        let provider = GitHubLocalProvider(
            client: MSWClient(runner: runner),
            policyStore: GitHubPolicyStore(policyURL: policyURL)
        )
        let desired = [GitHubWorkspacePolicy(workspace: "dev", repositories: [
            repositoryPolicy(workspace: "dev", fullName: "acme/one", mode: .readOnly)
        ])]

        let started = try await provider.beginPolicyApply(desired)
        XCTAssertEqual(started.phase, .saving, "Save must return before reconciliation finishes")
        let pending = try XCTUnwrap(GitHubPolicyStore.readIntent(policyURL: policyURL))
        XCTAssertEqual(pending.generation, started.generation)
        XCTAssertEqual(pending.status, .pending)

        try await provider.waitForCurrentPolicyApply()
        let maybeCompleted = await provider.currentPolicyApplyProgress()
        let completed = try XCTUnwrap(maybeCompleted)
        XCTAssertEqual(completed.phase, .completed)
        XCTAssertEqual(completed.generation, started.generation)
        XCTAssertEqual(GitHubPolicyStore.readIntent(policyURL: policyURL)?.status, .completed)
    }

    func testSemanticNoOpDoesNotRestartReconciliation() async throws {
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        writePolicy(policyURL, json: """
        {"schemaVersion":1,"workspaces":{"dev":{"capability":"0123456789abcdef0123456789abcdef0123456789abcdef","repos":[{"canonical":"acme/one","mode":"read-only"}]}}}
        """)
        let executable = makeFakeMSW(
            directory: directory,
            statusJSON: #"{"mode":"local","workspaces":[]}"#
        )
        let runner = MSWCommandRunner(configuration: .init(homeDirectory: directory, testMSWExecutable: executable))
        let provider = GitHubLocalProvider(client: MSWClient(runner: runner), policyStore: GitHubPolicyStore(policyURL: policyURL))

        let progress = try await provider.beginPolicyApply([
            GitHubWorkspacePolicy(workspace: "dev", repositories: [
                repositoryPolicy(workspace: "dev", fullName: "acme/one", mode: .readOnly)
            ])
        ])

        XCTAssertEqual(progress.phase, .completed)
        XCTAssertEqual(applyCallCount(directory), 0)
    }

    func testNewestGenerationSupersedesStaleApplyAndIdentitySerializes() async throws {
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        writePolicy(policyURL, json: "{\"schemaVersion\":1,\"workspaces\":{}}")
        let identity = #"{"schemaVersion":1,"requestId":"identity","ok":true,"command":"identity","observedAt":"2026-08-21T00:00:00Z","result":{"target":"dev","name":"Ada","email":"ada@example.test","workspaces":["dev"]},"warnings":[],"error":null}"#
        let executable = makeFakeMSW(
            directory: directory,
            statusJSON: #"{"mode":"local","workspaces":[]}"#,
            applyJSON: Self.policyApplyLine,
            applyDelay: 0.35,
            identityJSON: identity
        )
        let runner = MSWCommandRunner(configuration: .init(homeDirectory: directory, testMSWExecutable: executable))
        let provider = GitHubLocalProvider(client: MSWClient(runner: runner), policyStore: GitHubPolicyStore(policyURL: policyURL))
        let first = try await provider.beginPolicyApply([
            GitHubWorkspacePolicy(workspace: "dev", repositories: [repositoryPolicy(workspace: "dev", fullName: "acme/one", mode: .readOnly)])
        ])
        try await Task.sleep(for: .milliseconds(60))
        let newest = try await provider.beginPolicyApply([
            GitHubWorkspacePolicy(workspace: "dev", repositories: [repositoryPolicy(workspace: "dev", fullName: "acme/two", mode: .readWrite)])
        ])
        XCTAssertGreaterThan(newest.generation, first.generation)

        async let identityResult = provider.setIdentity(name: "Ada", email: "ada@example.test", workspace: "dev")
        try await provider.waitForCurrentPolicyApply()
        let resolvedIdentity = try await identityResult
        XCTAssertEqual(resolvedIdentity.name, "Ada")
        let maybeProgress = await provider.currentPolicyApplyProgress()
        let progress = try XCTUnwrap(maybeProgress)
        XCTAssertEqual(progress.generation, newest.generation)
        XCTAssertEqual(progress.phase, .completed)
        let appliedRequest = try MSWProtocolDecoder.decoder().decode(
            MSWGitHubPolicyApplyRequest.self,
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

    func testSupersedingPartialEditPreservesPendingIntentAndWaitsForNewestGeneration() async throws {
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        writePolicy(policyURL, json: "{\"schemaVersion\":1,\"workspaces\":{}}")
        let executable = makeFakeMSW(
            directory: directory,
            statusJSON: #"{"mode":"local","workspaces":[]}"#,
            applyJSON: Self.policyApplyLine,
            applyDelay: 0.35
        )
        let runner = MSWCommandRunner(configuration: .init(homeDirectory: directory, testMSWExecutable: executable))
        let provider = GitHubLocalProvider(client: MSWClient(runner: runner), policyStore: GitHubPolicyStore(policyURL: policyURL))

        _ = try await provider.beginPolicyApply([
            GitHubWorkspacePolicy(workspace: "dev", repositories: [
                repositoryPolicy(workspace: "dev", fullName: "acme/one", mode: .readOnly)
            ])
        ])
        let waiter = Task { try await provider.waitForCurrentPolicyApply() }
        try await Task.sleep(for: .milliseconds(60))
        let newest = try await provider.beginPolicyApply([
            GitHubWorkspacePolicy(workspace: "playgrounds", repositories: [
                repositoryPolicy(workspace: "playgrounds", fullName: "acme/two", mode: .readWrite)
            ])
        ])

        try await waiter.value
        let maybeCompleted = await provider.currentPolicyApplyProgress()
        let completed = try XCTUnwrap(maybeCompleted)
        XCTAssertEqual(completed.generation, newest.generation)
        XCTAssertEqual(completed.phase, .completed, "A waiter must follow a superseding generation through completion")
        let appliedRequest = try MSWProtocolDecoder.decoder().decode(
            MSWGitHubPolicyApplyRequest.self,
            from: Data(readApplyStdin(directory).utf8)
        )
        XCTAssertEqual(appliedRequest.workspaces["dev"]?.repos.map(\.canonical), ["acme/one"])
        XCTAssertEqual(appliedRequest.workspaces["playgrounds"]?.repos.map(\.canonical), ["acme/two"])
    }

    func testCancellationCannotClearOrCancelSupersedingGeneration() async throws {
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        writePolicy(policyURL, json: "{\"schemaVersion\":1,\"workspaces\":{}}")
        let executable = makeFakeMSW(
            directory: directory,
            statusJSON: #"{"mode":"local","workspaces":[]}"#,
            applyJSON: Self.policyApplyLine,
            applyDelay: 0.35
        )
        let runner = MSWCommandRunner(configuration: .init(homeDirectory: directory, testMSWExecutable: executable))
        let provider = GitHubLocalProvider(client: MSWClient(runner: runner), policyStore: GitHubPolicyStore(policyURL: policyURL))

        _ = try await provider.beginPolicyApply([
            GitHubWorkspacePolicy(workspace: "dev", repositories: [
                repositoryPolicy(workspace: "dev", fullName: "acme/one", mode: .readOnly)
            ])
        ])
        let cancellation = Task { await provider.cancelCurrentPolicyApply() }
        try await Task.sleep(for: .milliseconds(20))
        let newest = try await provider.beginPolicyApply([
            GitHubWorkspacePolicy(workspace: "dev", repositories: [
                repositoryPolicy(workspace: "dev", fullName: "acme/newest", mode: .readWrite)
            ])
        ])
        await cancellation.value
        try await provider.waitForCurrentPolicyApply()

        let maybeCompleted = await provider.currentPolicyApplyProgress()
        let completed = try XCTUnwrap(maybeCompleted)
        XCTAssertEqual(completed.generation, newest.generation)
        XCTAssertEqual(completed.phase, .completed)
        XCTAssertEqual(GitHubPolicyStore.readIntent(policyURL: policyURL)?.status, .completed)
    }

    func testRemoveAllAccessAppliesEmptyPolicyInOneInvocation() async throws {
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        writePolicy(policyURL, json: """
        {"schemaVersion":1,"workspaces":{"dev":{"capability":"abc","repos":[{"canonical":"acme/one","mode":"read-only"}]},"playgrounds":{"capability":"def","repos":[]},"personal":{"capability":"ghi","repos":[{"canonical":"acme/two","mode":"read-write"}]}}}
        """)
        let executable = makeFakeMSW(
            directory: directory,
            statusJSON: #"{"mode":"local","workspaces":[]}"#,
            applyJSON: Self.policyApplyLine
        )
        let runner = MSWCommandRunner(configuration: .init(homeDirectory: directory, testMSWExecutable: executable))
        let client = MSWClient(runner: runner)
        let store = GitHubPolicyStore(policyURL: policyURL)
        let provider = GitHubLocalProvider(client: client, policyStore: store)

        try await provider.removeAllAccess()

        let applyCalls = applyCallCount(directory)
        XCTAssertEqual(applyCalls, 1, "Removal must be a single apply invocation")
        let stdin = readApplyStdin(directory)
        let payload = try XCTUnwrap(
            MSWProtocolDecoder.decoder().decode(MSWGitHubPolicyApplyRequest.self, from: Data(stdin.utf8))
        )
        for workspace in SetupWorkspaceConfiguration.defaults.map(\.name) {
            let entry = try XCTUnwrap(payload.workspaces[workspace])
            XCTAssertTrue(entry.repos.isEmpty, "\(workspace) must be emptied")
        }
    }

    func testReloadedWorkspaceConfigurationScopesPolicyAndAllWorkspaceIdentity() async throws {
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        writePolicy(policyURL, json: """
        {"schemaVersion":1,"workspaces":{"dev":{"capability":"old","repos":[{"canonical":"acme/old","mode":"read-only"}]},"personal":{"capability":"keep","repos":[]}}}
        """)
        let identity = #"{"schemaVersion":1,"requestId":"identity","ok":true,"command":"identity","observedAt":"2026-08-21T00:00:00Z","result":{"target":"all","name":"Ada","email":"ada@example.test","workspaces":["development","personal","lab"]},"warnings":[],"error":null}"#
        let executable = makeFakeMSW(
            directory: directory,
            statusJSON: #"{"mode":"local","workspaces":[{"workspace":"dev","capability":"old","repos":[],"shuttle":"stopped","hostCredential":"present"}]}"#,
            applyJSON: Self.policyApplyLine,
            identityJSON: identity
        )
        let runner = MSWCommandRunner(configuration: .init(
            homeDirectory: directory,
            testMSWExecutable: executable
        ))
        let provider = GitHubLocalProvider(
            client: MSWClient(runner: runner),
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
        let currentPolicy = await provider.currentPolicy()
        let scopedPolicy = try XCTUnwrap(currentPolicy)
        XCTAssertEqual(Set(scopedPolicy.workspaces.keys), ["development", "personal", "lab"])
        XCTAssertNil(scopedPolicy.workspaces["dev"])
        XCTAssertNil(scopedPolicy.workspaces["playgrounds"])
        let scopedCatalog = try await provider.loadCatalog()
        XCTAssertFalse(
            scopedCatalog.hostCredentialPresent,
            "A credential belonging only to a removed workspace must not make the applied target set look connected."
        )
        try await provider.commit([
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

        let request = try MSWProtocolDecoder.decoder().decode(
            MSWGitHubPolicyApplyRequest.self,
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
        let executable = makeFakeMSW(
            directory: directory,
            statusJSON: #"{"mode":"local","workspaces":[]}"#,
            authJSON: #"{"provider":"gh-cli","tokenKind":"oauth","accountLogin":"octocat","verifiedAt":"2026-08-21T00:00:00Z","generation":2,"storedAt":"2026-08-21T00:00:00Z","repoChecks":[]}"#
        )
        let runner = MSWCommandRunner(configuration: .init(homeDirectory: directory, testMSWExecutable: executable))
        let provider = GitHubLocalProvider(client: MSWClient(runner: runner), policyStore: GitHubPolicyStore(policyURL: policyURL))

        let account = try await provider.connectAccount()

        XCTAssertEqual(account?.login, "octocat")
        XCTAssertTrue(readLog(directory).contains("auth github auth --json"))
    }

    func testConnectAccountSurfacesCLIFailure() async throws {
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        let executable = makeFakeMSW(
            directory: directory,
            statusJSON: #"{"mode":"local","workspaces":[]}"#,
            authJSON: #"{"ok":false,"error":{"code":"MSW_HOST_CREDENTIAL_VERIFICATION_FAILED","message":"verification failed; nothing was stored","remedies":["Retry"]}}"#
        )
        let runner = MSWCommandRunner(configuration: .init(homeDirectory: directory, testMSWExecutable: executable))
        let provider = GitHubLocalProvider(client: MSWClient(runner: runner), policyStore: GitHubPolicyStore(policyURL: policyURL))

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
        let executable = makeFakeMSW(
            directory: directory,
            statusJSON: #"{"mode":"local","workspaces":[]}"#,
            authJSON: #"{"ok":false,"error":{"code":"MSW_HOST_OAUTH_NOT_CONFIGURED","message":"gh is not authenticated and the OAuth Device Flow client ID (MSW_HOST_OAUTH_CLIENT_ID) is not set","remedies":["Run 'gh auth login' then retry","Set MSW_HOST_OAUTH_CLIENT_ID to the release's public client ID, or use the device flow (--device)"]}}"#
        )
        let runner = MSWCommandRunner(configuration: .init(homeDirectory: directory, testMSWExecutable: executable))
        let provider = GitHubLocalProvider(client: MSWClient(runner: runner), policyStore: GitHubPolicyStore(policyURL: policyURL))

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
        let executable = makeFakeMSW(
            directory: directory,
            statusJSON: #"{"mode":"local","workspaces":[]}"#,
            authJSON: #"{"ok":false,"error":{"code":"MSW_HOST_DEVICE_FLOW_INTERACTIVE_REQUIRED","message":"OAuth Device Flow requires an interactive terminal for plain 'msw github auth'","remedies":["Use 'msw github auth --device' and complete it with --device-complete"]}}"#
        )
        let runner = MSWCommandRunner(configuration: .init(homeDirectory: directory, testMSWExecutable: executable))
        let provider = GitHubLocalProvider(client: MSWClient(runner: runner), policyStore: GitHubPolicyStore(policyURL: policyURL))

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
        let runner = MSWCommandRunner(configuration: .init(homeDirectory: directory))
        let client = MSWClient(runner: runner, ghResolver: { fakeGh })
        let provider = GitHubLocalProvider(client: client, policyStore: GitHubPolicyStore(policyURL: policyURL))

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
        let runner = MSWCommandRunner(configuration: .init(homeDirectory: directory))
        let client = MSWClient(runner: runner, ghResolver: { nil })
        let provider = GitHubLocalProvider(client: client, policyStore: GitHubPolicyStore(policyURL: policyURL))

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
        // gh is unauthenticated (MSW_HOST_OAUTH_NOT_CONFIGURED) -> the app
        // launches gh web login -> then retries `msw github auth --json`,
        // which now succeeds via gh reuse.
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        let fakeGh = makeFakeGh(directory)
        let executable = makeFakeMSW(
            directory: directory,
            statusJSON: #"{"mode":"local","workspaces":[]}"#,
            authJSON: #"{"provider":"gh-cli","tokenKind":"oauth","accountLogin":"octocat","verifiedAt":"2026-08-21T00:00:00Z","generation":1,"storedAt":"2026-08-21T00:00:00Z","repoChecks":[]}"#
        )
        let runner = MSWCommandRunner(configuration: .init(homeDirectory: directory, testMSWExecutable: executable))
        let client = MSWClient(runner: runner, ghResolver: { fakeGh })
        let provider = GitHubLocalProvider(client: client, policyStore: GitHubPolicyStore(policyURL: policyURL))

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
        let executable = makeFakeMSW(
            directory: directory,
            statusJSON: #"{"mode":"local","workspaces":[]}"#,
            deviceJSON: #"{"ok":false,"error":{"code":"MSW_HOST_OAUTH_NOT_CONFIGURED","message":"host GitHub credential is not configured: gh is not authenticated and the OAuth Device Flow client ID is not set (MSW_HOST_OAUTH_CLIENT_ID)","remedies":["Run 'gh auth login'"]}}"#,
            deviceExit: 66
        )
        let runner = MSWCommandRunner(configuration: .init(homeDirectory: directory, testMSWExecutable: executable))
        let provider = GitHubLocalProvider(client: MSWClient(runner: runner), policyStore: GitHubPolicyStore(policyURL: policyURL))

        do {
            _ = try await provider.startDeviceFlow()
            XCTFail("Expected notConfigured")
        } catch GitHubCatalogError.notConfigured(let message) {
            XCTAssertTrue(message.contains("MSW_HOST_OAUTH_CLIENT_ID"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testStartDeviceFlowReturnsCodeAndPollHandle() async throws {
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        let executable = makeFakeMSW(
            directory: directory,
            statusJSON: #"{"mode":"local","workspaces":[]}"#,
            deviceJSON: #"{"ok":true,"deviceId":"device-code-1","code":"ABCD-EFGH","verificationUri":"https://github.com/login/device","expiresAt":"2026-08-21T12:00:00Z","interval":5}"#
        )
        let runner = MSWCommandRunner(configuration: .init(homeDirectory: directory, testMSWExecutable: executable))
        let provider = GitHubLocalProvider(client: MSWClient(runner: runner), policyStore: GitHubPolicyStore(policyURL: policyURL))

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
                MSWDeviceFlowStart(
                    deviceId: "d1",
                    code: "CODE-1",
                    verificationUri: "https://github.com/login/device",
                    expiresAt: Date().addingTimeInterval(900),
                    interval: 5
                )
            },
            pollDeviceFlow: { _ in
                MSWDeviceFlowPoll(status: .pending, interval: 5, accountLogin: nil)
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
                MSWDeviceFlowStart(
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
                    return MSWDeviceFlowPoll(status: .slowDown, interval: 15, accountLogin: nil)
                }
                return MSWDeviceFlowPoll(status: .authorized, interval: nil, accountLogin: "octocat")
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
            startDeviceFlow: { MSWDeviceFlowStart(deviceId: "d", code: "C", verificationUri: "https://github.com/login/device", expiresAt: Date(), interval: 5) },
            pollDeviceFlow: { _ in MSWDeviceFlowPoll(status: .expired, interval: nil, accountLogin: nil) }
        )
        _ = await expired.begin()
        let expiredPoll = await expired.poll()
        XCTAssertNil(expiredPoll)
        XCTAssertEqual(expired.phase, .expired)

        let denied = GitHubDeviceFlowSession(
            startDeviceFlow: { MSWDeviceFlowStart(deviceId: "d", code: "C", verificationUri: "https://github.com/login/device", expiresAt: Date(), interval: 5) },
            pollDeviceFlow: { _ in MSWDeviceFlowPoll(status: .denied, interval: nil, accountLogin: nil) }
        )
        _ = await denied.begin()
        let deniedPoll = await denied.poll()
        XCTAssertNil(deniedPoll)
        XCTAssertEqual(denied.phase, .denied)
    }

    func testDeviceFlowSessionStartFailureReportsFailed() async throws {
        let session = GitHubDeviceFlowSession(
            startDeviceFlow: { throw MSWClientError.rawCLIError(code: "MSW_HOST_OAUTH_NOT_CONFIGURED", message: "not configured remedy") },
            pollDeviceFlow: { _ in MSWDeviceFlowPoll(status: .pending, interval: nil, accountLogin: nil) }
        )
        let delay = await session.begin()
        XCTAssertNil(delay)
        guard case .failed(let message) = session.phase else {
            return XCTFail("Expected failed, got \(session.phase)")
        }
        XCTAssertEqual(message, "not configured remedy")
    }

    func testDeviceFlowPollOutcomeMapsTypedCLIErrors() {
        func poll(from error: MSWClientError) -> MSWDeviceFlowPoll {
            GitHubDeviceFlowSession.pollOutcome(for: error)
        }
        XCTAssertEqual(
            poll(from: .rawCLIError(code: "MSW_DEVICE_EXPIRED", message: nil)),
            MSWDeviceFlowPoll(status: .expired, interval: nil, accountLogin: nil)
        )
        XCTAssertEqual(
            poll(from: .rawCLIError(code: "MSW_DEVICE_DENIED", message: nil)),
            MSWDeviceFlowPoll(status: .denied, interval: nil, accountLogin: nil)
        )
        XCTAssertEqual(
            poll(from: .rawCLIError(code: "MSW_DEVICE_SLOW_DOWN", message: nil)),
            MSWDeviceFlowPoll(status: .slowDown, interval: nil, accountLogin: nil)
        )
        XCTAssertEqual(
            poll(from: .rawCLIError(code: "MSW_HOST_CREDENTIAL_VERIFICATION_FAILED", message: nil)),
            MSWDeviceFlowPoll(status: .denied, interval: nil, accountLogin: nil)
        )
        XCTAssertEqual(
            poll(from: .protocolFailure(MSWProtocolError(code: "MSW_DEVICE_EXPIRED", message: "x", recovery: nil, workspace: nil, retryable: false))),
            MSWDeviceFlowPoll(status: .expired, interval: nil, accountLogin: nil)
        )
        XCTAssertEqual(
            poll(from: .unavailable("network")),
            MSWDeviceFlowPoll(status: .denied, interval: nil, accountLogin: nil)
        )
    }

    func testDeviceFlowDeviceCompleteDecodesThroughMSWClient() async throws {
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        let executable = makeFakeMSW(
            directory: directory,
            statusJSON: #"{"mode":"local","workspaces":[]}"#,
            deviceCompleteJSON: #"{"ok":true,"status":"authorized","metadata":{"provider":"oauth-device-flow","tokenKind":"oauth","accountLogin":"octocat","verifiedAt":"2026-08-21T00:00:00Z","generation":1,"storedAt":"2026-08-21T00:00:00Z","repoChecks":[]}}"#
        )
        let runner = MSWCommandRunner(configuration: .init(homeDirectory: directory, testMSWExecutable: executable))
        let client = MSWClient(runner: runner)
        let provider = GitHubLocalProvider(client: client, policyStore: GitHubPolicyStore(policyURL: policyURL))

        let poll = try await provider.pollDeviceFlow(deviceId: "device-code-1")
        XCTAssertEqual(poll.status, .authorized)
        XCTAssertEqual(poll.accountLogin, "octocat")
        XCTAssertTrue(readLog(directory).contains("device-complete github auth --device-complete device-code-1 --format json"))
    }

    func testDeviceFlowDeviceCompleteExpiredAndDenied() async throws {
        let directory = makeTemporaryDirectory()
        let policyURL = directory.appendingPathComponent("github-policy.json")
        let executable = makeFakeMSW(
            directory: directory,
            statusJSON: #"{"mode":"local","workspaces":[]}"#,
            deviceCompleteJSON: #"{"ok":false,"status":"expired","error":{"code":"MSW_DEVICE_EXPIRED","message":"The code expired"}}"#,
            deviceCompleteExit: 76
        )
        let runner = MSWCommandRunner(configuration: .init(homeDirectory: directory, testMSWExecutable: executable))
        let provider = GitHubLocalProvider(client: MSWClient(runner: runner), policyStore: GitHubPolicyStore(policyURL: policyURL))

        let poll = try await provider.pollDeviceFlow(deviceId: "device-code-1")
        XCTAssertEqual(poll.status, .expired)
    }

    // MARK: - Push permission hints

    func testPushDeniedReposStayReadOnly() {
        let blocked = GitHubRepository(
            id: 1,
            fullName: "acme/one",
            name: "one",
            owner: GitHubInstallationAccount(login: "acme", id: 7, type: nil),
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
            owner: GitHubInstallationAccount(login: "acme", id: 7, type: nil),
            private: true,
            defaultBranch: "main",
            canPush: true,
            inPolicy: false
        )
        XCTAssertEqual(writable.effectiveMode(.readWrite), .readWrite)

        // Connect mode (nil canPush) never restricts.
        let connect = GitHubRepository(
            id: 3,
            fullName: "acme/three",
            name: "three",
            owner: GitHubInstallationAccount(login: "acme", id: 7, type: nil),
            private: true,
            defaultBranch: "main"
        )
        XCTAssertEqual(connect.effectiveMode(.readWrite), .readWrite)
    }

    // MARK: - Local picker: multiple owners per workspace (high-risk fix)

    func testLocalPolicyPrefillMapsEveryPolicyEntryToModes() {
        let policyWorkspace = GitHubPolicyWorkspace(
            capability: "abc",
            repos: [
                GitHubPolicyRepository(canonical: "acme/one", mode: .readOnly),
                GitHubPolicyRepository(canonical: "org/two", mode: .readWrite)
            ]
        )

        let modes = SetupView.localPolicyPrefill(policyWorkspace: policyWorkspace)

        // Every policy entry survives the prefill (cross-owner preserved);
        // the provider's catalog merge owns synthesis, so no catalog is
        // extended here.
        XCTAssertEqual(Set(modes.keys), ["acme/one", "org/two"])
        XCTAssertEqual(modes["acme/one"], .readOnly)
        XCTAssertEqual(modes["org/two"], .readWrite)
    }

    func testLocalPolicyPrefillSkipsMalformedCanonicals() {
        let policyWorkspace = GitHubPolicyWorkspace(
            capability: "abc",
            repos: [
                GitHubPolicyRepository(canonical: "acme/one", mode: .readOnly),
                GitHubPolicyRepository(canonical: "not-a-canonical", mode: .readWrite)
            ]
        )

        let modes = SetupView.localPolicyPrefill(policyWorkspace: policyWorkspace)

        XCTAssertEqual(modes, ["acme/one": .readOnly])
    }

    func testEditorSelectionSpansOwnersInLocalMode() {
        let acmeID = GitHubLocalProvider.stableID("acme")
        let orgID = GitHubLocalProvider.stableID("org")
        let acme = GitHubInstallation(
            id: acmeID,
            account: GitHubInstallationAccount(login: "acme", id: acmeID, type: nil),
            repositorySelection: nil
        )
        let org = GitHubInstallation(
            id: orgID,
            account: GitHubInstallationAccount(login: "org", id: orgID, type: "Organization"),
            repositorySelection: nil
        )
        // Local mode: a draft may select repositories from BOTH owners.
        var draft = WorkspaceRepositoryDraft.initial("dev")
        draft.repositoryModes = ["acme/one": .readOnly, "org/two": .readWrite]

        let localEntries = SetupView.repositoryPolicyEntries(
            workspace: "dev",
            draft: draft,
            installations: [acme, org],
            repositoriesByInstallation: [
                acmeID: [GitHubRepository(
                    id: GitHubLocalProvider.stableID("acme/one"),
                    fullName: "acme/one",
                    name: "one",
                    owner: acme.account,
                    private: true,
                    defaultBranch: "main"
                )],
                orgID: [GitHubRepository(
                    id: GitHubLocalProvider.stableID("org/two"),
                    fullName: "org/two",
                    name: "two",
                    owner: org.account,
                    private: true,
                    defaultBranch: "main"
                )]
            ],
            accessMode: .local
        )
        XCTAssertEqual(Set(localEntries.map(\.fullName)), ["acme/one", "org/two"])
        XCTAssertEqual(Set(localEntries.map(\.installationID)), [acmeID, orgID])

        // Connect mode retains the one-installation rule.
        draft.installationID = acmeID
        let connectEntries = SetupView.repositoryPolicyEntries(
            workspace: "dev",
            draft: draft,
            installations: [acme, org],
            repositoriesByInstallation: [
                acmeID: [GitHubRepository(
                    id: GitHubLocalProvider.stableID("acme/one"),
                    fullName: "acme/one",
                    name: "one",
                    owner: acme.account,
                    private: true,
                    defaultBranch: "main"
                )],
                orgID: [GitHubRepository(
                    id: GitHubLocalProvider.stableID("org/two"),
                    fullName: "org/two",
                    name: "two",
                    owner: org.account,
                    private: true,
                    defaultBranch: "main"
                )]
            ],
            accessMode: .connect
        )
        XCTAssertEqual(connectEntries.map(\.fullName), ["acme/one"])
    }

    // MARK: - Port warning surface (PortWarnings contract)

    private func makeSnapshot(
        skippedPorts: [Int]? = nil,
        portWarning: String? = nil
    ) -> MSWWorkspaceSnapshot {
        MSWWorkspaceSnapshot(
            id: "dev",
            purpose: "Test workspace",
            lifecycle: .stopped,
            freshness: .fresh,
            quarantine: MSWQuarantineSnapshot(state: .clear, reason: nil),
            credential: MSWCredentialSnapshot(
                state: .ready,
                accessMode: "guest-read",
                verificationRepository: nil,
                accountLogin: nil,
                installationId: nil,
                accessExpiresAt: nil,
                refreshExpiresAt: nil,
                needsRestart: false
            ),
            resources: MSWResourceSnapshot(
                cpus: "2",
                maxCpus: "8",
                memory: "4GiB",
                maxMemory: "16GiB",
                rootDisk: "20GiB"
            ),
            network: MSWNetworkSnapshot(host: "dev.msw.test", ip: "127.0.0.10"),
            actionCapabilities: MSWActionCapabilities(
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

        let decoded = try MSWProtocolDecoder.decoder().decode(MSWWorkspaceSnapshot.self, from: data)
        XCTAssertEqual(decoded.id, "dev")
        XCTAssertEqual(decoded.skippedPorts, [3000])
        XCTAssertEqual(decoded.portWarning, "Port 3000 is already in use; it was not published.")
    }

    func testWorkspaceSnapshotDecodesWithoutPortFields() throws {
        // Older CLI output has no port fields: decode must yield nil, not fail.
        let data = try JSONEncoder().encode(makeSnapshot())
        let decoded = try MSWProtocolDecoder.decoder().decode(MSWWorkspaceSnapshot.self, from: data)
        XCTAssertNil(decoded.skippedPorts)
        XCTAssertNil(decoded.portWarning)
    }

    // MARK: - Fixture provider (UI-test local flows)

    func testFixtureProviderScenarios() async throws {
        let success = GitHubFixtureProvider(scenario: "success")
        let catalog = try await success.loadCatalog()
        XCTAssertEqual(catalog.account?.login, "octocat")
        XCTAssertEqual(catalog.installations.first?.id, 42)
        XCTAssertEqual(catalog.repositoriesByInstallation[42]?.map(\.id), [1001, 1002])

        let unavailable = GitHubFixtureProvider(scenario: "unavailable")
        do {
            _ = try await unavailable.loadCatalog()
            XCTFail("Expected unavailable")
        } catch let error as GitHubCatalogError {
            guard case .unavailable(let message) = error else { return XCTFail("Unexpected error") }
            XCTAssertEqual(message, "GitHub could not be reached. Try again later.")
        }

        let empty = GitHubFixtureProvider(scenario: "no-installation")
        let emptyCatalog = try await empty.loadCatalog()
        XCTAssertEqual(emptyCatalog.account?.login, "octocat")
        XCTAssertTrue(emptyCatalog.installations.isEmpty)
        XCTAssertTrue(emptyCatalog.repositoriesByInstallation.isEmpty)

        let disconnected = GitHubFixtureProvider(scenario: "disconnected")
        let disconnectedCatalog = try await disconnected.loadCatalog()
        XCTAssertFalse(disconnectedCatalog.hostCredentialPresent)
        XCTAssertNil(disconnectedCatalog.account)
        XCTAssertTrue(disconnectedCatalog.repositoriesByInstallation.isEmpty)
        let connectedAccount = try await disconnected.connectAccount()
        XCTAssertEqual(connectedAccount?.login, "octocat")
        let connectedCatalog = try await disconnected.loadCatalog()
        XCTAssertTrue(connectedCatalog.hostCredentialPresent)
        XCTAssertEqual(connectedCatalog.account?.login, "octocat")
        XCTAssertEqual(connectedCatalog.repositoriesByInstallation[42]?.count, 2)

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
