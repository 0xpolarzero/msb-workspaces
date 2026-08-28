import Foundation
import XCTest
@testable import MSWMonitor

// MARK: - Fixtures

private let protocolCompatibleHandshake = #"{"schemaVersion":1,"requestId":"test-handshake","ok":true,"command":"handshake","observedAt":"2026-08-08T00:00:00Z","result":{"protocolVersion":1,"mswVersion":"test","platform":{"os":"macOS","architecture":"arm64"},"configurationAvailable":true,"runtimeAvailable":true,"capabilities":{"jsonState":true,"jsonMetrics":true,"jsonLogs":true,"plans":true,"bootstrapEvents":true,"jq":true,"workspaceCount":3},"exitCodes":{}},"warnings":[],"error":null}"#

private func writeSecretsExecutable(
    temporary: URL,
    listResponse: String,
    planResponse: String,
    applyResponse: String,
    argvCapture: URL? = nil,
    planStdinCapture: URL? = nil,
    applyStdinCapture: URL? = nil,
    envCapture: URL? = nil
) throws -> URL {
    let executable = temporary.appendingPathComponent("msw")
    var argvLine = ""
    if let argvCapture {
        argvLine = "printf '%s\\n' \"$@\" > '\(argvCapture.path)' 2>/dev/null || true\n"
    }
    var envLine = ""
    if let envCapture {
        envLine = "/usr/bin/env > '\(envCapture.path)' 2>/dev/null || true\n"
    }
    var planStdinCaptureLine = ""
    if let planStdinCapture {
        planStdinCaptureLine = "/bin/cat > '\(planStdinCapture.path)' 2>/dev/null || true\n"
    }
    var applyStdinCaptureLine = ""
    if let applyStdinCapture {
        applyStdinCaptureLine = "/bin/cat > '\(applyStdinCapture.path)' 2>/dev/null || true\n"
    }
    let script = """
    #!/bin/sh
    \(argvLine)\(envLine)if [ "$1" = "app" ] && [ "$2" = "handshake" ]; then
        printf '%s\\n' '\(protocolCompatibleHandshake)'
    elif [ "$1" = "app" ] && [ "$2" = "secrets-list" ]; then
        /bin/cat '\(listResponse)'
    elif [ "$1" = "app" ] && [ "$2" = "secret-plan" ]; then
        \(planStdinCaptureLine)/bin/cat '\(planResponse)'
    elif [ "$1" = "app" ] && [ "$2" = "secret-apply" ]; then
        \(applyStdinCaptureLine)/bin/cat '\(applyResponse)'
    else
        exit 64
    fi
    """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    return executable
}

private func makeSecretsClient(temporary: URL, executable: URL) -> MSWClient {
    MSWClient(runner: MSWCommandRunner(configuration: .init(
        homeDirectory: temporary,
        testMSWExecutable: executable
    )))
}

private func writeResponse<T: Encodable>(_ value: T, to temporary: URL, name: String) throws -> URL {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let url = temporary.appendingPathComponent(name)
    try encoder.encode(value).write(to: url)
    return url
}

// MARK: - Tests

@MainActor
final class SecretsTests: XCTestCase {

    // MARK: Protocol decoding

    func testSecretsListResponseDecodesExactContractKeys() throws {
        let json = """
        {"entries":[{"name":"OPENAI_API_KEY","workspaces":["dev","personal"],"allowedDomains":["api.openai.com"],"status":"restart-required","pendingOperation":{"type":"add","createdAt":"2026-08-28T09:00:00Z"},"generation":3,"error":null},{"name":"SERVICE_TOKEN","workspaces":["playgrounds"],"allowedDomains":["*.example.com"],"status":"active","pendingOperation":null,"generation":1,"error":null}],"workspaces":[{"workspace":"dev","restartRequired":true,"pendingCount":1},{"workspace":"personal","restartRequired":false,"pendingCount":1},{"workspace":"playgrounds","restartRequired":false,"pendingCount":0}]}
        """
        let response = try MSWProtocolDecoder.decoder().decode(
            MSWSecretsListResponse.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(response.entries.count, 2)
        let pending = try XCTUnwrap(response.entries[0].pendingOperation)
        XCTAssertEqual(pending.type, "add")
                let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        XCTAssertEqual(pending.createdAt, formatter.date(from: "2026-08-28T09:00:00Z"))
        XCTAssertEqual(response.entries[0].status, .restartRequired)
        XCTAssertEqual(response.entries[0].generation, 3)
        XCTAssertNil(response.entries[0].error)
        XCTAssertNil(response.entries[1].pendingOperation)
        XCTAssertEqual(response.entries[1].status, .active)
        XCTAssertEqual(response.entries[1].allowedDomains, ["*.example.com"])
        XCTAssertEqual(response.workspaces.count, 3)
        let dev = try XCTUnwrap(response.workspaces.first { $0.workspace == "dev" })
        XCTAssertTrue(dev.restartRequired)
        XCTAssertEqual(dev.pendingCount, 1)
    }

    func testSecretsWorkspaceSnapshotDecodesExactKeysAndDefaultsWhenAbsent() throws {
        let withSecrets = """
        {"id":"dev","purpose":"Test","lifecycle":"Running","freshness":"fresh","statusObservedAt":null,"metricsObservedAt":null,"githubObservedAt":null,"activityObservedAt":null,"quarantine":{"state":"clear","reason":null},"credential":{"state":"Ready","accessMode":"guest-read","verificationRepository":null,"accountLogin":null,"installationId":null,"accessExpiresAt":null,"refreshExpiresAt":null,"needsRestart":false},"secrets":{"state":"restart-required","pendingCount":2,"reason":"Host-held secret changes are pending."},"resources":{"cpus":"2","maxCpus":"8","memory":"4GiB","maxMemory":"16GiB","rootDisk":"20GiB"},"network":{"host":"dev.msw.test","ip":"127.0.0.10"},"actionCapabilities":{"canStart":true,"canStop":true,"canRestart":true,"canOpenTerminal":true,"canPush":true,"reason":null,"recovery":null},"skippedPorts":[],"portWarning":""}
        """
        let snapshot = try MSWProtocolDecoder.decoder().decode(
            MSWWorkspaceSnapshot.self,
            from: Data(withSecrets.utf8)
        )
        let secrets = try XCTUnwrap(snapshot.secrets)
        XCTAssertEqual(secrets.state, .restartRequired)
        XCTAssertEqual(secrets.pendingCount, 2)
        XCTAssertEqual(secrets.reason, "Host-held secret changes are pending.")

        let withoutSecrets = """
        {"id":"dev","purpose":"Test","lifecycle":"Running","freshness":"fresh","statusObservedAt":null,"metricsObservedAt":null,"githubObservedAt":null,"activityObservedAt":null,"quarantine":{"state":"clear","reason":null},"credential":{"state":"Ready","accessMode":"guest-read","verificationRepository":null,"accountLogin":null,"installationId":null,"accessExpiresAt":null,"refreshExpiresAt":null,"needsRestart":false},"resources":{"cpus":"2","maxCpus":"8","memory":"4GiB","maxMemory":"16GiB","rootDisk":"20GiB"},"network":{"host":"dev.msw.test","ip":"127.0.0.10"},"actionCapabilities":{"canStart":true,"canStop":true,"canRestart":true,"canOpenTerminal":true,"canPush":true,"reason":null,"recovery":null}}
        """
        let legacy = try MSWProtocolDecoder.decoder().decode(
            MSWWorkspaceSnapshot.self,
            from: Data(withoutSecrets.utf8)
        )
        XCTAssertNil(legacy.secrets)
    }

    func testSecretPlanResultAndApplyResultDecodeExactContractKeys() throws {
        let planJSON = """
        {"planId":"plan-42","operation":"add","name":"CI_TOKEN","affectedWorkspaces":["dev","playgrounds"],"requiresSecret":true,"confirmationPhrase":"ADD CI_TOKEN","effects":"Adds CI_TOKEN to dev and playgrounds.","expiresAt":"2026-08-28T09:05:00Z"}
        """
        let plan = try MSWProtocolDecoder.decoder().decode(
            MSWSecretPlanResult.self,
            from: Data(planJSON.utf8)
        )
        XCTAssertEqual(plan.planId, "plan-42")
        XCTAssertEqual(plan.operation, "add")
        XCTAssertEqual(plan.name, "CI_TOKEN")
        XCTAssertEqual(plan.affectedWorkspaces, ["dev", "playgrounds"])
        let planFormatter = ISO8601DateFormatter()
        planFormatter.formatOptions = [.withInternetDateTime]
        XCTAssertEqual(plan.expiresAt, planFormatter.date(from: "2026-08-28T09:05:00Z"))

        let applyJSON = """
        {"applied":true,"operation":"add","name":"CI_TOKEN","workspaces":["dev","playgrounds"],"pending":[{"workspace":"dev","state":"restart-required"},{"workspace":"playgrounds","state":"applies-on-next-start"}],"valueStored":true,"outcome":"staged"}
        """
        let apply = try MSWProtocolDecoder.decoder().decode(
            MSWSecretApplyResult.self,
            from: Data(applyJSON.utf8)
        )
        XCTAssertEqual(apply.applied, true)
        XCTAssertEqual(apply.name, "CI_TOKEN")
        XCTAssertEqual(apply.pending.count, 2)
        XCTAssertEqual(apply.pending.first?.workspace, "dev")
        XCTAssertEqual(apply.pending.first?.state, "restart-required")
        XCTAssertEqual(apply.valueStored, true)
        XCTAssertEqual(apply.outcome, "staged")
    }

    // MARK: Client transport

    func testSecretValueTravelsOnlyOnStdinNeverInArgvOrEnvironment() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("MSWSecretsClient-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let planResult = MSWSecretPlanResult(
            planId: "plan-stdin",
            operation: "add",
            name: "CI_TOKEN",
            affectedWorkspaces: ["dev"],
            requiresSecret: true,
            confirmationPhrase: "ADD CI_TOKEN",
            effects: "Adds CI_TOKEN to dev.",
            expiresAt: Date().addingTimeInterval(300)
        )
        let planURL = try writeResponse(
            MSWEnvelope(
                schemaVersion: 1,
                requestId: "plan-stdin",
                ok: true,
                command: "secret-plan",
                observedAt: Date(),
                result: planResult
            ),
            to: temporary,
            name: "plan.json"
        )
        let applyURL = try writeResponse(
            MSWEnvelope(
                schemaVersion: 1,
                requestId: "apply-stdin",
                ok: true,
                command: "secret-apply",
                observedAt: Date(),
                result: MSWSecretApplyResult(
                    applied: true,
                    operation: "add",
                    name: "CI_TOKEN",
                    workspaces: ["dev"],
                    pending: [.init(workspace: "dev", state: "restart-required")],
                    valueStored: true,
                    outcome: "staged"
                )
            ),
            to: temporary,
            name: "apply.json"
        )
        let listURL = try writeResponse(
            MSWEnvelope(
                schemaVersion: 1,
                requestId: "list-stdin",
                ok: true,
                command: "secrets-list",
                observedAt: Date(),
                result: MSWSecretsListResponse(
                    entries: [],
                    workspaces: [.init(workspace: "dev", restartRequired: false, pendingCount: 0)]
                )
            ),
            to: temporary,
            name: "list.json"
        )
        let argvCapture = temporary.appendingPathComponent("argv.txt")
        let planStdin = temporary.appendingPathComponent("plan-stdin.json")
               let applyStdin = temporary.appendingPathComponent("apply-stdin.json")
        let envCapture = temporary.appendingPathComponent("env.txt")
        let executable = try writeSecretsExecutable(
            temporary: temporary,
            listResponse: listURL.path,
            planResponse: planURL.path,
            applyResponse: applyURL.path,
            argvCapture: argvCapture,
                        planStdinCapture: planStdin,
            applyStdinCapture: applyStdin,
            envCapture: envCapture
        )
        let client = makeSecretsClient(temporary: temporary, executable: executable)

        let list = try await client.secretsList()
        XCTAssertTrue(list.entries.isEmpty)

        let staged = try await client.prepareSecretPlan(
            MSWSecretPlanRequest(
                operation: "add",
                name: "CI_TOKEN",
                workspaces: ["dev"],
                allowedDomains: ["api.openai.com"]
            )
        )
        XCTAssertEqual(staged.planId, "plan-stdin")

        // The plan request carries only nonsecret metadata on stdin.
        let planPayload = try JSONSerialization.jsonObject(
            with: try Data(contentsOf: planStdin)
        ) as? [String: Any]
        let planKeys = try XCTUnwrap(planPayload?.keys).sorted()
        XCTAssertEqual(
            planKeys,
            ["allowedDomains", "name", "operation", "workspaces"],
            "secret-plan stdin must carry exactly the nonsecret metadata keys"
        )
        XCTAssertNil(planPayload?["value"])

        let secretValue = "super-secret-apply-value-9471"
        let applied = try await client.applySecretPlan(
            staged,
            confirmation: "ADD CI_TOKEN",
            value: secretValue
        )
        XCTAssertEqual(applied.applied, true)
        XCTAssertEqual(applied.valueStored, true)

        let applyPayload = try JSONSerialization.jsonObject(
            with: try Data(contentsOf: applyStdin)
        ) as? [String: Any]
        let applyKeys = try XCTUnwrap(applyPayload?.keys).sorted()
        XCTAssertEqual(applyKeys, ["confirmation", "value"])
        XCTAssertEqual(applyPayload?["confirmation"] as? String, "ADD CI_TOKEN")
        XCTAssertEqual(applyPayload?["value"] as? String, secretValue)

        // The value must never appear in argv or the environment.
        let argv = try String(contentsOf: argvCapture, encoding: .utf8)
        XCTAssertFalse(argv.contains(secretValue), "The value must never appear in argv")
        XCTAssertTrue(argv.contains("secret-apply"))
        XCTAssertTrue(argv.contains("--input-fd"))
        XCTAssertTrue(argv.contains("0"))
        let childEnvironment = try String(contentsOf: envCapture, encoding: .utf8)
        XCTAssertFalse(
            childEnvironment.contains(secretValue),
            "The value must never appear in the child process environment"
        )
        XCTAssertFalse(
            String(decoding: try Data(contentsOf: applyURL), as: UTF8.self).contains(secretValue),
            "The value must never appear in command output"
        )
    }

    func testSecretApplyRejectsWrongConfirmation() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("MSWSecretsClient-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let planURL = try writeResponse(
            MSWEnvelope(
                schemaVersion: 1,
                requestId: "plan-x",
                ok: true,
                command: "secret-plan",
                observedAt: Date(),
                result: MSWSecretPlanResult(
                    planId: "plan-x",
                    operation: "edit",
                    name: "SERVICE_TOKEN",
                    affectedWorkspaces: ["playgrounds"],
                    requiresSecret: true,
                    confirmationPhrase: "EDIT SERVICE_TOKEN",
                    effects: "Edits SERVICE_TOKEN.",
                    expiresAt: Date().addingTimeInterval(300)
                )
            ),
            to: temporary,
            name: "plan.json"
        )
        let listURL = try writeResponse(
            MSWEnvelope(
                schemaVersion: 1,
                requestId: "list-x",
                ok: true,
                command: "secrets-list",
                observedAt: Date(),
                result: MSWSecretsListResponse(entries: [], workspaces: [])
            ),
            to: temporary,
            name: "list.json"
        )
        let executable = try writeSecretsExecutable(
            temporary: temporary,
            listResponse: listURL.path,
            planResponse: planURL.path,
            applyResponse: listURL.path
        )
        let client = makeSecretsClient(temporary: temporary, executable: executable)
        let plan = try await client.prepareSecretPlan(
            MSWSecretPlanRequest(
                operation: "edit",
                name: "SERVICE_TOKEN",
                workspaces: ["playgrounds"],
                allowedDomains: ["*.example.com"]
            )
        )
        do {
            _ = try await client.applySecretPlan(plan, confirmation: "WRONG PHRASE", value: "x")
            XCTFail("A wrong confirmation phrase must be rejected before spawning MSW")
        } catch let error as MSWClientError {
            XCTAssertEqual(error, .invalidArguments)
        }
    }

    func testSecretsListRejectsUnsafeMetadata() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("MSWSecretsClient-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let listURL = try writeResponse(
            MSWEnvelope(
                schemaVersion: 1,
                requestId: "list-bad",
                ok: true,
                command: "secrets-list",
                observedAt: Date(),
                result: MSWSecretsListResponse(
                    entries: [
                        .init(
                            name: "OPENAI_API_KEY",
                            workspaces: ["dev;rm -rf"],
                            allowedDomains: ["api.openai.com"],
                            status: .active,
                            pendingOperation: nil,
                            generation: 1,
                            error: nil
                        )
                    ],
                    workspaces: []
                )
            ),
            to: temporary,
            name: "list.json"
        )
        let executable = try writeSecretsExecutable(
            temporary: temporary,
            listResponse: listURL.path,
            planResponse: listURL.path,
            applyResponse: listURL.path
        )
        let client = makeSecretsClient(temporary: temporary, executable: executable)
        do {
            _ = try await client.secretsList()
            XCTFail("Unsafe workspace names in secrets-list must be rejected")
        } catch let error as MSWClientError {
            XCTAssertEqual(error, .malformedJSON(command: "secrets-list"))
        }
    }

    // MARK: Domain and name grammar

    func testSecretDomainRuleAcceptsExactWildcardAndAll() {
        let allowed = [
            "api.openai.com",
            "example.com",
            "localhost",
            "*.example.com",
                       "*.corp.example.com",
            "*.example.co.uk",
            "*",
            "a-b.example.com",
            "xn--bcher-kva.example.com"
        ]
        for domain in allowed {
            XCTAssertTrue(SecretDomainRule.isAllowed(domain), "\(domain) must be allowed")
        }
    }

    func testSecretDomainRuleRejectsSchemesPathsPortsWhitespaceAndBroadWildcards() {
        let rejected = [
            "https://api.openai.com",
            "http://api.openai.com",
            "api.openai.com/path",
            "api.openai.com:443",
            " api.openai.com",
            "api.openai.com ",
            "api.\nopenai.com",
            "*.com",
            "a.*.example.com",
            "example.*",
            "*example.com",
            "example*.com",
            "-foo.example.com",
            "foo-.example.com",
            "foo_bar.example.com",
            "a..example.com",
            "",
            ".",
            ".."
        ]
        for domain in rejected {
            XCTAssertFalse(SecretDomainRule.isAllowed(domain), "\(domain) must be rejected")
        }
    }

    func testSecretNameRuleMatchesEnvVarGrammarAndRejectsReservedNames() {
        let allowed = [
            "OPENAI_API_KEY",
            "CI_TOKEN",
            "_SECRET",
            "a1_b2"
        ]
        for name in allowed {
            XCTAssertTrue(SecretNameRule.isValid(name), "\(name) must be allowed")
        }
        let rejected = [
            "GH_TOKEN",
            "GITHUB_TOKEN",
            "MSW_INTERNAL",
            "msw_anything",
            "PATH",
            "HOME",
            "HTTP_PROXY",
            "LC_ALL",
            "DYLD_INSERT_LIBRARIES",
            "LD_PRELOAD",
            "with space",
            "with-hyphen",
            "1STARTS_WITH_DIGIT",
            "UPPER.lower",
            ""
        ]
        for name in rejected {
            XCTAssertFalse(SecretNameRule.isValid(name), "\(name) must be rejected")
        }
    }

    // MARK: AppModel integration

    func testWorkspaceStateAppliesSecretsSnapshotSeparatelyFromCredentialState() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("MSWSecretsState-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        func snapshot(
            id: String,
            lifecycle: MSWLifecycle,
            credentialNeedsRestart: Bool,
            secrets: MSWSecretsSnapshot?,
            canRestart: Bool = true,
            capabilityReason: String? = nil,
            capabilityRecovery: String? = nil
        ) -> MSWWorkspaceSnapshot {
            MSWWorkspaceSnapshot(
                id: id,
                purpose: "Test workspace",
                lifecycle: lifecycle,
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
                    needsRestart: credentialNeedsRestart
                ),
                secrets: secrets,
                resources: MSWResourceSnapshot(
                    cpus: "2", maxCpus: "8", memory: "4GiB", maxMemory: "16GiB", rootDisk: "20GiB"
                ),
                network: MSWNetworkSnapshot(host: "\(id).msw.test", ip: "127.0.0.10"),
                actionCapabilities: MSWActionCapabilities(
                    canStart: true, canStop: true, canRestart: canRestart,
                    canOpenTerminal: true, canPush: true,
                    reason: capabilityReason,
                    recovery: capabilityRecovery
                )
            )
        }
        let state = MSWStateResponse(
            schemaVersion: 1,
            mswVersion: "test",
            workspaces: [
                snapshot(
                    id: "dev",
                    lifecycle: .running,
                    credentialNeedsRestart: false,
                    secrets: MSWSecretsSnapshot(
                        state: .restartRequired,
                        pendingCount: 1,
                        reason: "Host-held secret changes are pending."
                    ),
                    canRestart: false,
                    capabilityReason: "Workspace storage must be repaired before restarting dev.",
                    capabilityRecovery: "Restore a verified ext4 workspace disk."
                ),
                snapshot(
                    id: "playgrounds",
                    lifecycle: .stopped,
                    credentialNeedsRestart: true,
                    secrets: MSWSecretsSnapshot(
                        state: .appliesOnNextStart,
                        pendingCount: 2,
                        reason: nil
                    )
                ),
                snapshot(id: "personal", lifecycle: .stopped, credentialNeedsRestart: false, secrets: nil)
            ]
        )
        let stateURL = try writeResponse(
            MSWEnvelope(
                schemaVersion: 1,
                requestId: "state-secrets",
                ok: true,
                command: "state",
                observedAt: Date(),
                result: state
            ),
            to: temporary,
            name: "state.json"
        )
        let listURL = try writeResponse(
            MSWEnvelope(
                schemaVersion: 1,
                requestId: "list-secrets",
                ok: true,
                command: "secrets-list",
                observedAt: Date(),
                result: MSWSecretsListResponse(entries: [], workspaces: [])
            ),
            to: temporary,
            name: "list.json"
        )
        let executable = temporary.appendingPathComponent("msw")
        let script = """
        #!/bin/sh
        if [ "$1" = "app" ] && [ "$2" = "handshake" ]; then
            printf '%s\\n' '\(protocolCompatibleHandshake)'
        elif [ "$1" = "app" ] && [ "$2" = "state" ]; then
            /bin/cat '\(stateURL.path)'
        elif [ "$1" = "app" ] && [ "$2" = "secrets-list" ]; then
            /bin/cat '\(listURL.path)'
        else
            exit 64
        fi
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let client = makeSecretsClient(temporary: temporary, executable: executable)
        let model = AppModel(client: client)
        await model.refreshRemote()

        let dev = try XCTUnwrap(model.workspaces.first { $0.id == .dev })
        XCTAssertEqual(dev.secrets.status, .restartRequired)
        XCTAssertEqual(dev.secrets.pendingCount, 1)
        XCTAssertEqual(dev.secrets.reason, "Host-held secret changes are pending.")
        // The GitHub credential state must remain untouched by secret state.
        XCTAssertEqual(dev.credential, .ready)
        XCTAssertFalse(dev.actionAvailability(for: .restart).isAllowed)
        XCTAssertEqual(model.secretsRestartRequiredWorkspaces.map(\.id), [])
        XCTAssertEqual(model.secretsRestartBlockedWorkspaces.map(\.id), [.dev])
        XCTAssertEqual(
            model.secretsRestartBannerMessage,
            "1 workspace requires repair"
        )

        let playgrounds = try XCTUnwrap(model.workspaces.first { $0.id == .playgrounds })
        XCTAssertEqual(playgrounds.secrets.status, .appliesOnNextStart)
        XCTAssertEqual(playgrounds.secrets.pendingCount, 2)
        XCTAssertEqual(playgrounds.credential, .ready)

        let personal = try XCTUnwrap(model.workspaces.first { $0.id == .personal })
        XCTAssertEqual(personal.secrets.status, .active)
        XCTAssertEqual(personal.secrets.pendingCount, 0)
    }

    func testPendingSecretVerificationErrorRemainsRestartable() {
        let pendingError = Workspace.SecretsState(
            status: .error,
            pendingCount: 1,
            reason: "Verification failed."
        )
        XCTAssertTrue(pendingError.restartRequired)

        let terminalError = Workspace.SecretsState(
            status: .error,
            pendingCount: 0,
            reason: "Keychain unavailable."
        )
        XCTAssertFalse(terminalError.restartRequired)
    }

        func testSecretsFixtureAddEditRemoveAndRestartBadges() async throws {
        let model = AppModel()
        model.installSecretsUITestFixture()

        // Deterministic initial fixture state.
        XCTAssertEqual(model.secretEntries.map(\.name), ["OPENAI_API_KEY", "SERVICE_TOKEN"])
                let openAI = try XCTUnwrap(model.secretEntries.first { $0.name == "OPENAI_API_KEY" })
        XCTAssertEqual(openAI.status, .restartRequired)
        XCTAssertEqual(openAI.pendingOperation, .add)
                let service = try XCTUnwrap(model.secretEntries.first { $0.name == "SERVICE_TOKEN" })
        XCTAssertEqual(service.status, .active)
        XCTAssertEqual(service.allowedDomains, ["*.example.com"])

                let dev = try XCTUnwrap(model.workspaces.first { $0.id == .dev })
        XCTAssertEqual(dev.state, .running)
        XCTAssertEqual(dev.secrets.status, .restartRequired)
        XCTAssertEqual(dev.secrets.indicatorText, "Restart required")
                let personal = try XCTUnwrap(model.workspaces.first { $0.id == .personal })
        XCTAssertEqual(personal.secrets.status, .appliesOnNextStart)
        XCTAssertEqual(personal.secrets.indicatorText, "Applies on next start")
                let playgrounds = try XCTUnwrap(model.workspaces.first { $0.id == .playgrounds })
        XCTAssertEqual(playgrounds.secrets.status, .active)
        XCTAssertEqual(playgrounds.secrets.indicatorText, nil)

        XCTAssertEqual(model.secretsRestartBannerMessage, "1 workspace needs restart")
        XCTAssertEqual(model.secretsRestartRequiredWorkspaces.map(\.id.rawValue), ["dev"])
        XCTAssertEqual(
            model.secretsAppliesOnNextStartWorkspaces.map(\.id.rawValue),
            ["personal"]
        )

        // Add: value stays in memory only during the staged apply.
        let stagedAdd = await model.prepareSecretPlan(
            operation: .add,
            name: "CI_TOKEN",
            workspaces: ["playgrounds", "personal"],
            allowedDomains: ["api.example.com"]
        )
        XCTAssertTrue(stagedAdd)
        XCTAssertEqual(model.pendingSecretPlan?.confirmationPhrase, "ADD CI_TOKEN")
        XCTAssertEqual(model.pendingSecretPlan?.requiresSecret, true)
        await model.confirmSecretPlan(confirmation: "ADD CI_TOKEN", value: "ci-value-123")
        XCTAssertNil(model.pendingSecretPlan)
                let added = try XCTUnwrap(model.secretEntries.first { $0.name == "CI_TOKEN" })
        XCTAssertEqual(added.status, .appliesOnNextStart)
        XCTAssertEqual(added.pendingOperation, .add)
        XCTAssertEqual(added.generation, 1)
        XCTAssertFalse(
            "\(model.secretEntries)".contains("ci-value-123"),
            "The value must never be retained in app state"
        )

        // Edit: the name stays fixed; workspaces and domains update.
        let stagedEdit = await model.prepareSecretPlan(
            operation: .edit,
            name: "SERVICE_TOKEN",
            workspaces: ["dev", "playgrounds"],
            allowedDomains: ["*.example.com", "api.example.com"]
        )
        XCTAssertTrue(stagedEdit)
        await model.confirmSecretPlan(confirmation: "EDIT SERVICE_TOKEN", value: "replacement-456")
        let edited = try XCTUnwrap(model.secretEntries.first { $0.name == "SERVICE_TOKEN" })
        XCTAssertEqual(edited.workspaces, ["dev", "playgrounds"])
        XCTAssertEqual(edited.allowedDomains, ["*.example.com", "api.example.com"])
        XCTAssertEqual(edited.status, .restartRequired)
        XCTAssertEqual(edited.pendingOperation, .edit)
        XCTAssertEqual(edited.generation, 2)

        // Remove: destructive staging with a typed phrase. CI_TOKEN is scoped
        // to stopped workspaces, so the removal applies on their next start.
        let stagedRemove = await model.prepareSecretPlan(
            operation: .remove,
            name: "CI_TOKEN",
            workspaces: ["playgrounds", "personal"],
            allowedDomains: ["api.example.com"]
        )
        XCTAssertTrue(stagedRemove)
        XCTAssertEqual(model.pendingSecretPlan?.requiresSecret, false)
        await model.confirmSecretPlan(confirmation: "REMOVE CI_TOKEN", value: nil)
        let removed = try XCTUnwrap(model.secretEntries.first { $0.name == "CI_TOKEN" })
        XCTAssertEqual(removed.status, .appliesOnNextStart)
        XCTAssertEqual(removed.pendingOperation, .remove)

        // Removing SERVICE_TOKEN (pending on running dev and stopped
        // playgrounds) surfaces the removal-pending-restart entry status.
        let stagedRemoveRunning = await model.prepareSecretPlan(
            operation: .remove,
            name: "SERVICE_TOKEN",
            workspaces: ["dev", "playgrounds"],
            allowedDomains: ["*.example.com", "api.example.com"]
        )
        XCTAssertTrue(stagedRemoveRunning)
        await model.confirmSecretPlan(confirmation: "REMOVE SERVICE_TOKEN", value: nil)
        let removedRunning = try XCTUnwrap(model.secretEntries.first { $0.name == "SERVICE_TOKEN" })
        XCTAssertEqual(removedRunning.status, .removalPendingRestart)
        XCTAssertEqual(removedRunning.pendingOperation, .remove)

        // Banner still reflects dev's pending add.
        XCTAssertEqual(model.secretsRestartBannerMessage, "1 workspace needs restart")
    }

    func testSecretsFixtureRestartUsesReviewedLifecycleConfirmationAndClearsPending() async throws {
        let model = AppModel(
            lifecycleVerificationDelays: Array(repeating: .milliseconds(5), count: 5)
        )
        model.installSecretsUITestFixture()
        model.installLifecycleUITestFixture()

        model.restartWorkspacesForSecrets()
        // The batch restart goes through the existing reviewed lifecycle
        // confirmation surface; stopped workspaces are never restarted.
        let pending = try XCTUnwrap(model.pendingLifecyclePlan(for: .unifiedWindow))
        XCTAssertEqual(pending.action, "restart")
        XCTAssertEqual(pending.workspace, "dev")
        XCTAssertEqual(pending.confirmationPhrase, "RESTART dev")
        XCTAssertNil(model.pendingLifecyclePlan(for: .statusPopover))

        model.confirmPendingLifecycle(surface: .unifiedWindow)
        XCTAssertNil(model.pendingLifecyclePlan(for: .unifiedWindow))

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if model.workspaces.first(where: { $0.id == .dev })?.secrets.status == .active {
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
                let dev = try XCTUnwrap(model.workspaces.first { $0.id == .dev })
        XCTAssertEqual(dev.state, .running)
        XCTAssertEqual(dev.secrets.status, .active, "A completed restart must clear pending secret state")
        XCTAssertEqual(dev.secrets.pendingCount, 0)
                let openAI = try XCTUnwrap(model.secretEntries.first { $0.name == "OPENAI_API_KEY" })
        XCTAssertEqual(openAI.status, .appliesOnNextStart, "personal is still pending")
        XCTAssertEqual(openAI.pendingOperation, .add)
                let personal = try XCTUnwrap(model.workspaces.first { $0.id == .personal })
        XCTAssertEqual(personal.secrets.status, .appliesOnNextStart)
    }

    func testSecretsDeepLinksRouteToTheSecretsTab() throws {
        let direct = try XCTUnwrap(AppRoute(deepLink: URL(string: "msw-monitor://secrets")!))
        XCTAssertEqual(direct.tab, .secrets)
        XCTAssertNil(direct.workspace)

        let workspaceScoped = try XCTUnwrap(
            AppRoute(deepLink: URL(string: "msw-monitor://workspace/dev?section=secrets")!)
        )
        XCTAssertEqual(workspaceScoped.tab, .secrets)
        XCTAssertEqual(workspaceScoped.workspace, .dev)
    }

    func testSecretApplyPlanValidationRequiresValueOnlyWhenPlanDoes() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("MSWSecretsClient-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let removePlan = MSWSecretPlanResult(
            planId: "plan-rm",
            operation: "remove",
            name: "CI_TOKEN",
            affectedWorkspaces: ["dev"],
            requiresSecret: false,
            confirmationPhrase: "REMOVE CI_TOKEN",
            effects: "Removes CI_TOKEN from dev.",
            expiresAt: Date().addingTimeInterval(300)
        )
        let planURL = try writeResponse(
            MSWEnvelope(
                schemaVersion: 1,
                requestId: "plan-rm",
                ok: true,
                command: "secret-plan",
                observedAt: Date(),
                result: removePlan
            ),
            to: temporary,
            name: "plan.json"
        )
        let listURL = try writeResponse(
            MSWEnvelope(
                schemaVersion: 1,
                requestId: "list-rm",
                ok: true,
                command: "secrets-list",
                observedAt: Date(),
                result: MSWSecretsListResponse(entries: [], workspaces: [])
            ),
            to: temporary,
            name: "list.json"
        )
        let executable = try writeSecretsExecutable(
            temporary: temporary,
            listResponse: listURL.path,
            planResponse: planURL.path,
            applyResponse: listURL.path
        )
        let client = makeSecretsClient(temporary: temporary, executable: executable)
        let plan = try await client.prepareSecretPlan(
            MSWSecretPlanRequest(
                operation: "remove",
                name: "CI_TOKEN",
                workspaces: ["dev"],
                allowedDomains: ["api.openai.com"]
            )
        )

        do {
            _ = try await client.applySecretPlan(
                plan,
                confirmation: "REMOVE CI_TOKEN",
                value: "must-not-be-sent"
            )
            XCTFail("A removal must reject a supplied value before launching MSW.")
        } catch let error as MSWClientError {
            XCTAssertEqual(error, .invalidArguments)
        }
    }
    func testSecretsEditPlanAppliesWithoutReplacementValue() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("MSWSecretsClient-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        // The backend plans edits with requiresSecret=true; a scopes/domains
        // edit that keeps the current Keychain value sends no value at all.
        let planURL = try writeResponse(
            MSWEnvelope(
                schemaVersion: 1,
                requestId: "plan-keep",
                ok: true,
                command: "secret-plan",
                observedAt: Date(),
                result: MSWSecretPlanResult(
                    planId: "plan-keep",
                    operation: "edit",
                    name: "SERVICE_TOKEN",
                    affectedWorkspaces: ["dev", "playgrounds"],
                    requiresSecret: true,
                    confirmationPhrase: "EDIT SERVICE_TOKEN",
                    effects: "Edits SERVICE_TOKEN.",
                    expiresAt: Date().addingTimeInterval(300)
                )
            ),
            to: temporary,
            name: "plan.json"
        )
        let listURL = try writeResponse(
            MSWEnvelope(
                schemaVersion: 1,
                requestId: "list-keep",
                ok: true,
                command: "secrets-list",
                observedAt: Date(),
                result: MSWSecretsListResponse(entries: [], workspaces: [])
            ),
            to: temporary,
            name: "list.json"
        )
        let applyURL = try writeResponse(
            MSWEnvelope(
                schemaVersion: 1,
                requestId: "apply-keep",
                ok: true,
                command: "secret-apply",
                observedAt: Date(),
                result: MSWSecretApplyResult(
                    applied: true,
                    operation: "edit",
                    name: "SERVICE_TOKEN",
                    workspaces: ["dev", "playgrounds"],
                    pending: [.init(workspace: "dev", state: "restart-required")],
                    valueStored: false,
                    outcome: "staged"
                )
            ),
            to: temporary,
            name: "apply.json"
        )
        let applyStdin = temporary.appendingPathComponent("apply-stdin.json")
        let executable = try writeSecretsExecutable(
            temporary: temporary,
            listResponse: listURL.path,
            planResponse: planURL.path,
            applyResponse: applyURL.path,
            applyStdinCapture: applyStdin
        )
        let client = makeSecretsClient(temporary: temporary, executable: executable)
        let plan = try await client.prepareSecretPlan(
            MSWSecretPlanRequest(
                operation: "edit",
                name: "SERVICE_TOKEN",
                workspaces: ["dev", "playgrounds"],
                allowedDomains: ["*.example.com"]
            )
        )
        let result = try await client.applySecretPlan(
            plan,
            confirmation: "EDIT SERVICE_TOKEN",
            value: nil
        )
        XCTAssertEqual(result.applied, true)
        XCTAssertEqual(result.valueStored, false)
        let payload = try JSONSerialization.jsonObject(
            with: try Data(contentsOf: applyStdin)
        ) as? [String: Any]
        XCTAssertEqual(payload?["confirmation"] as? String, "EDIT SERVICE_TOKEN")
        XCTAssertNil(payload?["value"], "A keep-value edit must omit the value key on stdin")
    }

    func testSecretsApplyFailureIsPreservedAcrossRefreshAndBlocksMutations() async throws {
        let model = AppModel()
        model.installSecretsUITestFixture()

        let staged = await model.prepareSecretPlan(
            operation: .add,
            name: "CI_TOKEN",
            workspaces: ["playgrounds"],
            allowedDomains: ["api.example.com"]
        )
        XCTAssertTrue(staged)
        await model.confirmSecretPlan(confirmation: "WRONG PHRASE", value: "ci-value-123")
        let operationError = try XCTUnwrap(model.secretsOperationError)
        XCTAssertTrue(operationError.contains("confirmation"))
        XCTAssertTrue(model.secretsMutationsBlocked)
        XCTAssertFalse(
            "\(model.secretEntries)".contains("ci-value-123"),
            "The value must never be retained after a failed apply"
        )

        // The follow-up list refresh must not swallow the operation error.
        await model.refreshSecrets()
        XCTAssertNotNil(model.secretsOperationError)
        XCTAssertTrue(model.secretsMutationsBlocked)

        // A cleanly staged operation clears the error and unblocks mutations.
        let restaged = await model.prepareSecretPlan(
            operation: .add,
            name: "CI_TOKEN",
            workspaces: ["playgrounds"],
            allowedDomains: ["api.example.com"]
        )
        XCTAssertTrue(restaged)
        XCTAssertNil(model.secretsOperationError)
        XCTAssertFalse(model.secretsMutationsBlocked)
    }

    func testSecretsMalformedListKeepsCacheAndBlocksMutations() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("MSWSecretsClient-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let listURL = try writeResponse(
            MSWEnvelope(
                schemaVersion: 1,
                requestId: "list-cache",
                ok: true,
                command: "secrets-list",
                observedAt: Date(),
                result: MSWSecretsListResponse(
                    entries: [
                        .init(
                            name: "OPENAI_API_KEY",
                            workspaces: ["dev"],
                            allowedDomains: ["api.openai.com"],
                            status: .active,
                            pendingOperation: nil,
                            generation: 1,
                            error: nil
                        )
                    ],
                    workspaces: [.init(workspace: "dev", restartRequired: false, pendingCount: 0)]
                )
            ),
            to: temporary,
            name: "list.json"
        )
        let planURL = try writeResponse(
            MSWEnvelope(
                schemaVersion: 1,
                requestId: "plan-unused",
                ok: true,
                command: "secret-plan",
                observedAt: Date(),
                result: MSWSecretPlanResult(
                    planId: "plan-unused",
                    operation: "add",
                    name: "UNUSED",
                    affectedWorkspaces: ["dev"],
                    requiresSecret: true,
                    confirmationPhrase: "ADD UNUSED",
                    effects: "Unused.",
                    expiresAt: Date().addingTimeInterval(300)
                )
            ),
            to: temporary,
            name: "plan.json"
        )
        let executable = try writeSecretsExecutable(
            temporary: temporary,
            listResponse: listURL.path,
            planResponse: planURL.path,
            applyResponse: planURL.path
        )
        let client = makeSecretsClient(temporary: temporary, executable: executable)
        let model = AppModel(client: client)

        await model.refreshSecrets()
        XCTAssertEqual(model.secretEntries.map(\.name), ["OPENAI_API_KEY"])
        XCTAssertNil(model.secretsError)
        XCTAssertFalse(model.secretsMutationsBlocked)

        // A malformed refresh keeps the cached rows but blocks mutations.
        try Data("not-json".utf8).write(to: listURL)
        await model.refreshSecrets()
        XCTAssertNotNil(model.secretsError)
        XCTAssertEqual(model.secretEntries.map(\.name), ["OPENAI_API_KEY"])
        XCTAssertTrue(model.secretsMutationsBlocked)

        // An authoritative refresh clears the error and unblocks mutations.
        let responseEncoder = JSONEncoder()
        responseEncoder.dateEncodingStrategy = .iso8601
        try responseEncoder.encode(
            MSWEnvelope(
                schemaVersion: 1,
                requestId: "list-ok",
                ok: true,
                command: "secrets-list",
                observedAt: Date(),
                result: MSWSecretsListResponse(
                    entries: [
                        .init(
                            name: "OPENAI_API_KEY",
                            workspaces: ["dev"],
                            allowedDomains: ["api.openai.com"],
                            status: .active,
                            pendingOperation: nil,
                            generation: 1,
                            error: nil
                        )
                    ],
                    workspaces: [.init(workspace: "dev", restartRequired: false, pendingCount: 0)]
                )
            )
        ).write(to: listURL)
        await model.refreshSecrets()
        XCTAssertNil(model.secretsError)
        XCTAssertFalse(model.secretsMutationsBlocked)
    }

    func testSecretsBatchRestartCancelAbortsRemainingQueue() async throws {
        let model = AppModel(
            lifecycleVerificationDelays: Array(repeating: .milliseconds(5), count: 5)
        )
        model.installSecretsBatchTestFixture()
        model.installLifecycleUITestFixture()
        XCTAssertEqual(
            model.secretsRestartRequiredWorkspaces.map(\.id.rawValue).sorted(),
            ["dev", "personal"]
        )

        model.restartWorkspacesForSecrets()
        XCTAssertEqual(model.pendingLifecyclePlan(for: .unifiedWindow)?.workspace, "dev")
        model.confirmPendingLifecycle(surface: .unifiedWindow)

        // dev's fixture restart completes; the batch advances to personal.
        let deadline = Date().addingTimeInterval(10)
        while model.pendingLifecyclePlan(for: .unifiedWindow)?.workspace != "personal",
              Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(model.pendingLifecyclePlan(for: .unifiedWindow)?.workspace, "personal")

        // Cancelling the current (personal) restart aborts the whole batch.
        model.cancelPendingLifecycle(surface: .unifiedWindow)
        XCTAssertNil(model.pendingLifecyclePlan(for: .unifiedWindow))

        // An unrelated manual dev restart afterwards must not re-launch
        // personal from the cancelled batch.
        model.restart(.dev, surface: .unifiedWindow)
        XCTAssertEqual(model.pendingLifecyclePlan(for: .unifiedWindow)?.workspace, "dev")
        model.confirmPendingLifecycle(surface: .unifiedWindow)
        let end = Date().addingTimeInterval(10)
        while Date() < end {
            if model.workspaces.first(where: { $0.id == .dev })?.secrets.status == .active {
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNil(
            model.pendingLifecyclePlan(for: .unifiedWindow),
            "A cancelled batch must never auto-restart the remaining workspace"
        )
    }

    func testSecretsListRefreshesAfterVerifiedRestart() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("MSWSecretsClient-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        func snapshot(lifecycle: MSWLifecycle, secrets: MSWSecretsSnapshot?) -> MSWWorkspaceSnapshot {
            MSWWorkspaceSnapshot(
                id: "dev",
                purpose: "Test workspace",
                lifecycle: lifecycle,
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
                secrets: secrets,
                resources: MSWResourceSnapshot(
                    cpus: "2", maxCpus: "8", memory: "4GiB", maxMemory: "16GiB", rootDisk: "20GiB"
                ),
                network: MSWNetworkSnapshot(host: "dev.msw.test", ip: "127.0.0.10"),
                actionCapabilities: MSWActionCapabilities(
                    canStart: false, canStop: true, canRestart: true,
                    canOpenTerminal: true, canPush: true
                )
            )
        }
        let restartingState = MSWStateResponse(
            schemaVersion: 1,
            mswVersion: "test",
            workspaces: [
                snapshot(
                    lifecycle: .restarting,
                    secrets: MSWSecretsSnapshot(
                        state: .restartRequired,
                        pendingCount: 1,
                        reason: "Host-held secret changes are pending."
                    )
                )
            ]
        )
        let runningState = MSWStateResponse(
            schemaVersion: 1,
            mswVersion: "test",
            workspaces: [
                snapshot(
                    lifecycle: .running,
                    secrets: MSWSecretsSnapshot(
                        state: .active,
                        pendingCount: 0,
                        reason: nil
                    )
                )
            ]
        )
        let stateURL = try writeResponse(
            MSWEnvelope(
                schemaVersion: 1,
                requestId: "state-restart",
                ok: true,
                command: "state",
                observedAt: Date(),
                result: restartingState
            ),
            to: temporary,
            name: "state.json"
        )
        let listURL = try writeResponse(
            MSWEnvelope(
                schemaVersion: 1,
                requestId: "list-restart",
                ok: true,
                command: "secrets-list",
                observedAt: Date(),
                result: MSWSecretsListResponse(
                    entries: [
                        .init(
                            name: "OPENAI_API_KEY",
                            workspaces: ["dev"],
                            allowedDomains: ["api.openai.com"],
                            status: .active,
                            pendingOperation: nil,
                            generation: 2,
                            error: nil
                        )
                    ],
                    workspaces: [.init(workspace: "dev", restartRequired: false, pendingCount: 0)]
                )
            ),
            to: temporary,
            name: "list.json"
        )
        let executable = temporary.appendingPathComponent("msw")
        let script = """
        #!/bin/sh
        if [ "$1" = "app" ] && [ "$2" = "handshake" ]; then
            printf '%s\\n' '\(protocolCompatibleHandshake)'
        elif [ "$1" = "app" ] && [ "$2" = "state" ]; then
            /bin/cat '\(stateURL.path)'
        elif [ "$1" = "app" ] && [ "$2" = "secrets-list" ]; then
            /bin/cat '\(listURL.path)'
        else
            exit 64
        fi
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let client = makeSecretsClient(temporary: temporary, executable: executable)
        let model = AppModel(client: client)

        await model.refreshRemote()
        XCTAssertEqual(
            model.workspaces.first { $0.id == .dev }?.secrets.status,
            .restartRequired
        )
        XCTAssertTrue(model.secretEntries.isEmpty)

        // Verified restart transition: the model must re-read the list so the
        // Secrets tab reflects the applied state instead of stale rows.
        let stateEncoder = JSONEncoder()
        stateEncoder.dateEncodingStrategy = .iso8601
        try stateEncoder.encode(
            MSWEnvelope(
                schemaVersion: 1,
                requestId: "state-running",
                ok: true,
                command: "state",
                observedAt: Date(),
                result: runningState
            )
        ).write(to: stateURL)
        await model.refreshRemote()
        let deadline = Date().addingTimeInterval(5)
        while model.secretEntries.isEmpty, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
                XCTAssertEqual(model.secretEntries.map(\.name), ["OPENAI_API_KEY"])
        XCTAssertEqual(model.secretEntries.first?.status, .active)
    }

    func testSecretsListRefreshPreservesWorkspaceErrorState() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("MSWSecretsClient-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let errorState = MSWStateResponse(
            schemaVersion: 1,
            mswVersion: "test",
            workspaces: [
                MSWWorkspaceSnapshot(
                    id: "dev",
                    purpose: "Test workspace",
                    lifecycle: .running,
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
                    secrets: MSWSecretsSnapshot(
                        state: .error,
                        pendingCount: 1,
                        reason: "Keychain write failed."
                    ),
                    resources: MSWResourceSnapshot(
                        cpus: "2", maxCpus: "8", memory: "4GiB", maxMemory: "16GiB", rootDisk: "20GiB"
                    ),
                    network: MSWNetworkSnapshot(host: "dev.msw.test", ip: "127.0.0.10"),
                    actionCapabilities: MSWActionCapabilities(
                        canStart: false, canStop: true, canRestart: true,
                        canOpenTerminal: true, canPush: true
                    )
                )
            ]
        )
        let stateURL = try writeResponse(
            MSWEnvelope(
                schemaVersion: 1,
                requestId: "state-error",
                ok: true,
                command: "state",
                observedAt: Date(),
                result: errorState
            ),
            to: temporary,
            name: "state.json"
        )
        // The list summary has no error field: pendingCount 0 must NOT
        // downgrade the authoritative workspace error to Active.
        let listURL = try writeResponse(
            MSWEnvelope(
                schemaVersion: 1,
                requestId: "list-error",
                ok: true,
                command: "secrets-list",
                observedAt: Date(),
                result: MSWSecretsListResponse(
                    entries: [
                        .init(
                            name: "OPENAI_API_KEY",
                            workspaces: ["dev"],
                            allowedDomains: ["api.openai.com"],
                            status: .error,
                            pendingOperation: nil,
                            generation: 1,
                            error: "Keychain write failed."
                        )
                    ],
                    workspaces: [.init(workspace: "dev", restartRequired: false, pendingCount: 0)]
                )
            ),
            to: temporary,
            name: "list.json"
        )
        let executable = temporary.appendingPathComponent("msw")
        let script = """
        #!/bin/sh
        if [ "$1" = "app" ] && [ "$2" = "handshake" ]; then
            printf '%s\\n' '\(protocolCompatibleHandshake)'
        elif [ "$1" = "app" ] && [ "$2" = "state" ]; then
            /bin/cat '\(stateURL.path)'
        elif [ "$1" = "app" ] && [ "$2" = "secrets-list" ]; then
            /bin/cat '\(listURL.path)'
        else
            exit 64
        fi
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let client = makeSecretsClient(temporary: temporary, executable: executable)
        let model = AppModel(client: client)

        await model.refreshRemote()
        let dev = try XCTUnwrap(model.workspaces.first { $0.id == .dev })
        XCTAssertEqual(dev.secrets.status, .error)
        XCTAssertEqual(dev.secrets.indicatorText, "Secrets error")

        // The Secrets-tab refresh must not overwrite the error with an Active
        // derived from the error-free list summary.
        await model.refreshSecrets()
        let afterRefresh = try XCTUnwrap(model.workspaces.first { $0.id == .dev })
        XCTAssertEqual(afterRefresh.secrets.status, .error)
        XCTAssertEqual(afterRefresh.secrets.reason, "Keychain write failed.")
        XCTAssertEqual(model.secretEntries.first?.status, .error)
        XCTAssertEqual(model.secretEntries.first?.error, "Keychain write failed.")
    }

    func testSecretApplyRejectsEmptyOrMismatchedSuccessDocument() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("MSWSecretsClient-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let planURL = try writeResponse(
            MSWEnvelope(
                schemaVersion: 1,
                requestId: "plan-ok",
                ok: true,
                command: "secret-plan",
                observedAt: Date(),
                result: MSWSecretPlanResult(
                    planId: "plan-ok",
                    operation: "add",
                    name: "CI_TOKEN",
                    affectedWorkspaces: ["dev"],
                    requiresSecret: true,
                    confirmationPhrase: "ADD CI_TOKEN",
                    effects: "Adds CI_TOKEN to dev.",
                    expiresAt: Date().addingTimeInterval(300)
                )
            ),
            to: temporary,
            name: "plan.json"
        )
        let listURL = try writeResponse(
            MSWEnvelope(
                schemaVersion: 1,
                requestId: "list-unused",
                ok: true,
                command: "secrets-list",
                observedAt: Date(),
                result: MSWSecretsListResponse(entries: [], workspaces: [])
            ),
            to: temporary,
            name: "list.json"
        )
        // Empty success document: every field is required by the exact schema.
        let emptyApply = temporary.appendingPathComponent("apply-empty.json")
        try Data("""
        {"schemaVersion":1,"requestId":"apply-empty","ok":true,"command":"secret-apply","observedAt":"2026-08-28T09:00:00Z","result":{},"warnings":[],"error":null}
        """.utf8).write(to: emptyApply)
        let mismatchedApply = temporary.appendingPathComponent("apply-mismatched.json")
        try Data("""
        {"schemaVersion":1,"requestId":"apply-mismatch","ok":true,"command":"secret-apply","observedAt":"2026-08-28T09:00:00Z","result":{"applied":true,"operation":"remove","name":"CI_TOKEN","workspaces":["dev"],"pending":[],"valueStored":false,"outcome":"staged"},"warnings":[],"error":null}
        """.utf8).write(to: mismatchedApply)

        let emptyExecutable = try writeSecretsExecutable(
            temporary: temporary,
            listResponse: listURL.path,
            planResponse: planURL.path,
            applyResponse: emptyApply.path
        )
        let emptyClient = makeSecretsClient(temporary: temporary, executable: emptyExecutable)
        let plan = try await emptyClient.prepareSecretPlan(
            MSWSecretPlanRequest(
                operation: "add",
                name: "CI_TOKEN",
                workspaces: ["dev"],
                allowedDomains: ["api.openai.com"]
            )
        )
        do {
            _ = try await emptyClient.applySecretPlan(plan, confirmation: "ADD CI_TOKEN", value: "v")
            XCTFail("An empty success document must be rejected")
        } catch let error as MSWClientError {
            XCTAssertEqual(error, .malformedJSON(command: "secret-apply"))
        }

        let mismatchedExecutable = try writeSecretsExecutable(
            temporary: temporary,
            listResponse: listURL.path,
            planResponse: planURL.path,
            applyResponse: mismatchedApply.path
        )
        let mismatchedClient = makeSecretsClient(temporary: temporary, executable: mismatchedExecutable)
        do {
            _ = try await mismatchedClient.applySecretPlan(plan, confirmation: "ADD CI_TOKEN", value: "v")
            XCTFail("A success document for a different operation must be rejected")
        } catch let error as MSWClientError {
            XCTAssertEqual(error, .malformedJSON(command: "secret-apply"))
        }
    }

    func testSecretPlanRejectsMismatchedStagedPlan() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("MSWSecretsClient-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let listURL = try writeResponse(
            MSWEnvelope(
                schemaVersion: 1,
                requestId: "list-unused",
                ok: true,
                command: "secrets-list",
                observedAt: Date(),
                result: MSWSecretsListResponse(entries: [], workspaces: [])
            ),
            to: temporary,
            name: "list.json"
        )
        // Staged plan names a different secret than the request.
        let wrongNamePlan = temporary.appendingPathComponent("plan-wrong-name.json")
        try Data("""
        {"schemaVersion":1,"requestId":"plan-wrong","ok":true,"command":"secret-plan","observedAt":"2026-08-28T09:00:00Z","result":{"planId":"plan-wrong","operation":"add","name":"OTHER_TOKEN","affectedWorkspaces":["dev"],"requiresSecret":true,"confirmationPhrase":"ADD OTHER_TOKEN","effects":"Adds OTHER_TOKEN to dev.","expiresAt":"2026-08-28T09:05:00Z"},"warnings":[],"error":null}
        """.utf8).write(to: wrongNamePlan)
        let wrongNameExecutable = try writeSecretsExecutable(
            temporary: temporary,
            listResponse: listURL.path,
            planResponse: wrongNamePlan.path,
            applyResponse: listURL.path
        )
        let wrongNameClient = makeSecretsClient(temporary: temporary, executable: wrongNameExecutable)
        do {
            _ = try await wrongNameClient.prepareSecretPlan(
                MSWSecretPlanRequest(
                    operation: "add",
                    name: "CI_TOKEN",
                    workspaces: ["dev"],
                    allowedDomains: ["api.openai.com"]
                )
            )
            XCTFail("A staged plan for a different secret must be rejected")
        } catch let error as MSWClientError {
            XCTAssertEqual(error, .malformedJSON(command: "secret-plan"))
        }

        // Staged plan claims requiresSecret=false for an add.
        let wrongSecretPlan = temporary.appendingPathComponent("plan-wrong-secret.json")
        try Data("""
        {"schemaVersion":1,"requestId":"plan-secret","ok":true,"command":"secret-plan","observedAt":"2026-08-28T09:00:00Z","result":{"planId":"plan-secret","operation":"add","name":"CI_TOKEN","affectedWorkspaces":["dev"],"requiresSecret":false,"confirmationPhrase":"ADD CI_TOKEN","effects":"Adds CI_TOKEN to dev.","expiresAt":"2026-08-28T09:05:00Z"},"warnings":[],"error":null}
        """.utf8).write(to: wrongSecretPlan)
        let wrongSecretExecutable = try writeSecretsExecutable(
            temporary: temporary,
            listResponse: listURL.path,
            planResponse: wrongSecretPlan.path,
            applyResponse: listURL.path
        )
        let wrongSecretClient = makeSecretsClient(temporary: temporary, executable: wrongSecretExecutable)
        do {
            _ = try await wrongSecretClient.prepareSecretPlan(
                MSWSecretPlanRequest(
                    operation: "add",
                    name: "CI_TOKEN",
                    workspaces: ["dev"],
                    allowedDomains: ["api.openai.com"]
                )
            )
            XCTFail("A staged plan with inconsistent requiresSecret must be rejected")
        } catch let error as MSWClientError {
            XCTAssertEqual(error, .malformedJSON(command: "secret-plan"))
        }
    }
}
