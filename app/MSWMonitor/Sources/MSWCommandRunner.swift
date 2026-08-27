@preconcurrency import Foundation
import Darwin

struct MSWCommand: Sendable {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]
    let timeout: Duration
    let captureLimit: Int
    let preserveOutputTail: Bool
    let stdin: Data?
    let terminationGrace: Duration

    init(
        executable: URL,
        arguments: [String],
        environment: [String: String] = [:],
        timeout: Duration = .seconds(30),
        captureLimit: Int = 4 * 1024 * 1024,
        preserveOutputTail: Bool = false,
        stdin: Data? = nil,
        terminationGrace: Duration = .milliseconds(250)
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.timeout = timeout
        self.captureLimit = captureLimit
        self.preserveOutputTail = preserveOutputTail
        self.stdin = stdin
        self.terminationGrace = terminationGrace
    }
}

struct MSWCommandResult: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: Data
    let duration: Duration

    var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

struct MSWExecutableResolution: Sendable, Equatable {
    let selected: URL?
    let candidates: [URL]
    let incompatibleCandidates: [URL]

    var hasInstalledExecutable: Bool { !candidates.isEmpty }
}

struct GitIdentityConfiguration: Sendable, Equatable {
    let name: String?
    let email: String?

    var isEmpty: Bool { name == nil && email == nil }

    func prefilling(
        name currentName: String,
        email currentEmail: String,
        nameWasEdited: Bool,
        emailWasEdited: Bool
    ) -> GitIdentityPrefill {
        let prefilledName = !nameWasEdited && currentName.isEmpty ? (name ?? currentName) : currentName
        let prefilledEmail = !emailWasEdited && currentEmail.isEmpty ? (email ?? currentEmail) : currentEmail
        return GitIdentityPrefill(
            name: prefilledName,
            email: prefilledEmail,
            didPrefill: prefilledName != currentName || prefilledEmail != currentEmail
        )
    }
}

struct GitIdentityPrefill: Sendable, Equatable {
    let name: String
    let email: String
    let didPrefill: Bool
}

actor MSWCommandRunner {
    struct Configuration: Sendable {
        let homeDirectory: URL
        let configuredExecutable: URL?
        let additionalSearchPaths: [URL]

        init(
            homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
            configuredExecutable: URL? = nil,
            additionalSearchPaths: [URL] = []
        ) {
            self.homeDirectory = homeDirectory
            self.configuredExecutable = configuredExecutable
            self.additionalSearchPaths = additionalSearchPaths
        }
    }

    private struct RunningProcess: Sendable {
        let processIdentifier: pid_t
    }

    private let configuration: Configuration
    private let redactor = MSWProtocolRedactor()
    private var runningProcesses: [UUID: RunningProcess] = [:]
    private var cancelledOperations: Set<UUID> = []
    private var cachedMSWResolution: MSWExecutableResolution?
    private var cachedSelectedHandshake: (url: URL, handshake: MSWHandshake)?
    private var mswResolutionGeneration = 0

    init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    func run(_ command: MSWCommand, operationID: UUID = UUID()) async throws -> MSWCommandResult {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = command.stdin.map { _ in Pipe() }
        let environment = processEnvironment(for: command)
        let processIdentifier: pid_t

        do {
            processIdentifier = try Self.spawn(
                executable: command.executable,
                arguments: command.arguments,
                environment: environment,
                stdinReadDescriptor: stdinPipe?.fileHandleForReading.fileDescriptor,
                stdinWriteDescriptor: stdinPipe?.fileHandleForWriting.fileDescriptor,
                stdoutReadDescriptor: stdoutPipe.fileHandleForReading.fileDescriptor,
                stdoutWriteDescriptor: stdoutPipe.fileHandleForWriting.fileDescriptor,
                stderrReadDescriptor: stderrPipe.fileHandleForReading.fileDescriptor,
                stderrWriteDescriptor: stderrPipe.fileHandleForWriting.fileDescriptor
            )
        } catch {
            try? stdoutPipe.fileHandleForReading.close()
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForWriting.close()
            if let stdinPipe {
                try? stdinPipe.fileHandleForReading.close()
                try? stdinPipe.fileHandleForWriting.close()
            }
            throw error
        }

        // The child has its own copies of the pipe descriptors. Closing the
        // parent's write ends is required for readers to observe EOF.
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        if let stdinPipe {
            try? stdinPipe.fileHandleForReading.close()
        }

        if let stdin = command.stdin, let stdinPipe {
            _ = Darwin.fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            try? stdinPipe.fileHandleForWriting.write(contentsOf: stdin)
            try? stdinPipe.fileHandleForWriting.close()
        }

        runningProcesses[operationID] = RunningProcess(processIdentifier: processIdentifier)
        defer {
            runningProcesses.removeValue(forKey: operationID)
            cancelledOperations.remove(operationID)
        }

        let startedAt = ContinuousClock.now
        let stdoutTask = Task.detached(priority: .userInitiated) {
            Self.readCapped(
                stdoutPipe.fileHandleForReading,
                limit: command.captureLimit,
                preserveTail: command.preserveOutputTail
            )
        }
        let stderrTask = Task.detached(priority: .userInitiated) {
            Self.readCapped(
                stderrPipe.fileHandleForReading,
                limit: command.captureLimit,
                preserveTail: command.preserveOutputTail
            )
        }

        let status: Int32
        do {
            status = try await wait(for: processIdentifier, command: command)
        } catch {
            await Self.terminate(processIdentifier, grace: command.terminationGrace)
            _ = await stdoutTask.value
            _ = await stderrTask.value
            throw error
        }
        let stdout = await stdoutTask.value
        let stderr = await stderrTask.value
        if cancelledOperations.contains(operationID) || Task.isCancelled {
            throw MSWClientError.cancelled
        }
        let duration = startedAt.duration(to: .now)
        let redactedStdout = Data(redactor.redact(String(decoding: stdout, as: UTF8.self)).utf8)
        let redactedStderr = Data(redactor.redact(String(decoding: stderr, as: UTF8.self)).utf8)
        return MSWCommandResult(status: status, stdout: redactedStdout, stderr: redactedStderr, duration: duration)
    }

    func cancel(operationID: UUID) async {
        guard let process = runningProcesses[operationID] else { return }
        cancelledOperations.insert(operationID)
        await Self.terminate(process.processIdentifier, grace: .milliseconds(250))
    }

    func homeDirectory() -> URL {
        configuration.homeDirectory
    }

    /// Reads back the workspace configuration installed for this runner's
    /// deterministic HOME. Bootstrap uses this as the operational boundary:
    /// selected workspaces are not published as applied until the CLI-owned
    /// reconciliation has written the exact validated configuration.
    func installedWorkspaceConfigurations() -> [SetupWorkspaceConfiguration]? {
        let url = configuration.homeDirectory
            .appending(path: ".config/msw/workspaces.json")
        guard let values = try? url.resourceValues(forKeys: [
                  .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey
              ]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize <= 256 * 1_024,
              let data = try? Data(contentsOf: url),
              let boundary = MSWBootstrapConfiguration.decodeValidated(from: data) else {
            return nil
        }
        return boundary.setupConfigurations
    }

    func resolveMSW() -> URL? {
        mswCandidates().first
    }

    func mswResolution(forceRefresh: Bool = false) async -> MSWExecutableResolution {
        if !forceRefresh, let cachedMSWResolution {
            return cachedMSWResolution
        }
        mswResolutionGeneration &+= 1
        let generation = mswResolutionGeneration
        let candidates = mswCandidates()
        var incompatibleCandidates: [URL] = []
        for candidate in candidates {
            if let handshake = await handshakeIfCompatible(candidate) {
                let resolution = MSWExecutableResolution(
                    selected: candidate,
                    candidates: candidates,
                    incompatibleCandidates: incompatibleCandidates
                )
                if generation == mswResolutionGeneration {
                    cachedMSWResolution = resolution
                    cachedSelectedHandshake = (url: candidate, handshake: handshake)
                }
                return resolution
            }
            // Cancellation can interrupt the handshake used for capability
            // detection. Do not poison the shared resolver cache with that
            // transient result; a queued mutation must be able to resolve the
            // same executable after the cancelled process group has exited.
            if Task.isCancelled {
                return MSWExecutableResolution(
                    selected: nil,
                    candidates: candidates,
                    incompatibleCandidates: incompatibleCandidates
                )
            }
            incompatibleCandidates.append(candidate)
        }
        let resolution = MSWExecutableResolution(
            selected: nil,
            candidates: candidates,
            incompatibleCandidates: incompatibleCandidates
        )
        if generation == mswResolutionGeneration {
            cachedMSWResolution = resolution
            cachedSelectedHandshake = nil
        }
        return resolution
    }

    /// Returns the handshake captured during the most recent resolution of the
    /// currently selected runtime, so callers can reuse the spawn instead of
    /// running an identical `msw app handshake` again.
    func handshakeForSelectedRuntime() -> MSWHandshake? {
        guard let selected = cachedMSWResolution?.selected,
              let pair = cachedSelectedHandshake,
              pair.url == selected else { return nil }
        return pair.handshake
    }

    func invalidateMSWResolution() {
        mswResolutionGeneration &+= 1
        cachedMSWResolution = nil
        cachedSelectedHandshake = nil
    }

    private func mswCandidates() -> [URL] {
        var candidates: [URL] = []
        if let configuredExecutable = configuration.configuredExecutable {
            candidates.append(configuredExecutable)
        }
        // An activated managed runtime is the result of the app's repair
        // flow. Prefer it over a compatible but incomplete legacy CLI so a
        // successful repair changes the runtime used by this process.
        candidates.append(configuration.homeDirectory.appending(path: "Library/Application Support/MSW Monitor/Toolchains/current/bin/msw"))
        candidates.append(configuration.homeDirectory.appending(path: ".local/bin/msw"))
        candidates.append(contentsOf: configuration.additionalSearchPaths)
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/msw"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/msw"))
        var seen: Set<String> = []
        return candidates.filter { candidate in
            let path = candidate.standardizedFileURL.path
            return seen.insert(path).inserted && Self.isExecutableCandidate(candidate)
        }
    }

    /// Runs the protocol handshake against one candidate and returns the
    /// decoded handshake when the executable speaks the app-compatible
    /// protocol, otherwise nil. The handshake is the same command the client
    /// issues later, so callers can reuse it instead of spawning twice.
    private func handshakeIfCompatible(_ executable: URL) async -> MSWHandshake? {
        struct HandshakeEnvelope: Decodable {
            let schemaVersion: Int
            let requestId: String
            let ok: Bool
            let command: String
            let observedAt: Date?
            let result: MSWHandshake?
            let error: MSWProtocolError?
        }

        do {
            let output = try await run(MSWCommand(
                executable: executable,
                arguments: ["app", "handshake", "--format", "json"],
                timeout: .seconds(5),
                captureLimit: 256 * 1024
            ))
            let envelope = try MSWProtocolDecoder.decoder().decode(HandshakeEnvelope.self, from: output.stdout)
            guard envelope.schemaVersion == 1,
                  envelope.command == "handshake",
                  !envelope.requestId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  envelope.observedAt != nil else {
                return nil
            }
            if envelope.ok {
                return output.status == 0 &&
                    envelope.error == nil &&
                    envelope.result?.protocolVersion == 1 &&
                    envelope.result?.capabilities.backup.isCompatible == true
                    ? envelope.result
                    : nil
            }
            // A protocol-aware but erroring envelope is incompatible too;
            // only a clean ok envelope with protocolVersion 1 carries a result.
            return nil
        } catch {
            return nil
        }
    }

    func resolveExecutable(named name: String) -> URL? {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return nil }
        if name == "msw", let resolved = resolveMSW() { return resolved }
        var directories = [configuration.homeDirectory.appending(path: ".local/bin")]
        directories.append(contentsOf: configuration.additionalSearchPaths.map { $0.deletingLastPathComponent() })
        directories.append(contentsOf: [
            configuration.homeDirectory.appending(path: "Library/Application Support/MSW Monitor/Toolchains/current/bin"),
            URL(fileURLWithPath: "/opt/homebrew/bin"),
            URL(fileURLWithPath: "/usr/local/bin"),
            URL(fileURLWithPath: "/usr/bin"),
            URL(fileURLWithPath: "/bin")
        ])
        return directories
            .map { $0.appending(path: name) }
            .first(where: Self.isExecutableCandidate)
    }

    /// Reads the host user's effective Git identity through the same deterministic
    /// executable resolution and process environment used by every other app
    /// command. Missing Git, unset values, and unreadable configuration are
    /// all optional onboarding inputs rather than failures.
    func gitIdentityConfiguration() async -> GitIdentityConfiguration? {
        guard let git = resolveExecutable(named: "git") else { return nil }
        let name = await gitConfigurationValue("user.name", executable: git)
        let email = await gitConfigurationValue("user.email", executable: git)
        let configuration = GitIdentityConfiguration(name: name, email: email)
        return configuration.isEmpty ? nil : configuration
    }

    private func gitConfigurationValue(_ key: String, executable: URL) async -> String? {
        do {
            let result = try await run(MSWCommand(
                executable: executable,
                arguments: ["config", "--get", key],
                timeout: .seconds(5),
                captureLimit: 16 * 1024
            ))
            guard result.status == 0 else { return nil }
            let value = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        } catch {
            return nil
        }
    }

    func makeMSWCommand(
        arguments: [String],
        environment: [String: String] = [:],
        timeout: Duration = .seconds(30),
        stdin: Data? = nil,
        terminationGrace: Duration = .milliseconds(250)
    ) async throws -> MSWCommand {
        let resolution = await mswResolution()
        guard let executable = resolution.selected else {
            throw resolution.hasInstalledExecutable
                ? MSWClientError.incompatibleExecutable
                : MSWClientError.invalidExecutable
        }
        return MSWCommand(
            executable: executable,
            arguments: arguments,
            environment: environment,
            timeout: timeout,
            stdin: stdin,
            terminationGrace: terminationGrace
        )
    }

    private func processEnvironment(for command: MSWCommand) -> [String: String] {
        var environment: [String: String] = [
            "HOME": configuration.homeDirectory.path,
            "PATH": deterministicPath(),
            "NO_COLOR": "1",
            "LC_ALL": "C",
            "LANG": "C"
        ]
        for (key, value) in ProcessInfo.processInfo.environment
            where Self.isSafeAmbientVariable(key) {
            environment[key] = value
        }
        for (key, value) in command.environment where Self.isSafeEnvironmentVariable(key) {
            environment[key] = value
        }
        return environment
    }

    private static func isSafeAmbientVariable(_ key: String) -> Bool {
        // Finder/launchd environments are not part of the app-to-MSW
        // contract. In particular, ambient MSW_* overrides could redirect
        // helper binaries or credential stores. Tests and explicit advanced
        // settings pass narrowly allowed values through command.environment.
        key == "TMPDIR"
    }

    private static func isSafeEnvironmentVariable(_ key: String) -> Bool {
        guard !key.uppercased().contains("TOKEN"),
              !key.uppercased().contains("SECRET"),
              !key.uppercased().contains("PASSWORD"),
              !key.uppercased().contains("PRIVATE_KEY"),
              key != "MSW_EXECUTABLE" else {
            return false
        }
        return key == "MSW_CONFIG_FILE"
            || key == "MSW_SKIP_HOST_REPAIR"
            || key == "MSW_TEST_KEYCHAIN_DIR"
            || key == "MSW_TEST_VISIBLE"
            || key == "NONINTERACTIVE"
            || key == "HOMEBREW_NO_AUTO_UPDATE"
            || key == "HOMEBREW_NO_ENV_HINTS"
    }

    func executableSearchPath() -> String {
        deterministicPath()
    }

    private func deterministicPath() -> String {
        var paths = [configuration.homeDirectory.appending(path: ".local/bin").path]
        paths.append(contentsOf: configuration.additionalSearchPaths.map { $0.deletingLastPathComponent().path })
        paths.append(configuration.homeDirectory.appending(path: "Library/Application Support/MSW Monitor/Toolchains/current/bin").path)
        paths.append(contentsOf: [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"
        ])
        return paths.joined(separator: ":")
    }

    private func wait(for processIdentifier: pid_t, command: MSWCommand) async throws -> Int32 {
        let statusTask = Task.detached(priority: .userInitiated) {
            Self.waitForExit(processIdentifier)
        }

        do {
            return try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: Int32.self) { group in
                    group.addTask { await statusTask.value }
                    group.addTask {
                        try await Task.sleep(for: command.timeout)
                        await Self.terminate(processIdentifier, grace: command.terminationGrace)
                        throw MSWClientError.timedOut(command: command.arguments.first ?? "msw")
                    }
                    guard let result = try await group.next() else {
                        throw MSWClientError.cancelled
                    }
                    group.cancelAll()
                    if Task.isCancelled { throw MSWClientError.cancelled }
                    return result
                }
            } onCancel: {
                Task { await Self.terminate(processIdentifier, grace: command.terminationGrace) }
            }
        } catch is CancellationError {
            throw MSWClientError.cancelled
        }
    }

    private nonisolated static func isExecutableCandidate(_ url: URL) -> Bool {
        guard url.isFileURL, url.path.hasPrefix("/"), url.user == nil,
              url.password == nil, url.query == nil, url.fragment == nil else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: url.path)
    }

    private nonisolated static func spawn(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        stdinReadDescriptor: Int32?,
        stdinWriteDescriptor: Int32?,
        stdoutReadDescriptor: Int32,
        stdoutWriteDescriptor: Int32,
        stderrReadDescriptor: Int32,
        stderrWriteDescriptor: Int32
    ) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0,
              posix_spawnattr_init(&attributes) == 0 else {
            throw MSWClientError.processFailed(command: arguments.first ?? executable.lastPathComponent, status: -1, message: "Could not initialize MSW process controls.")
        }
        defer {
            _ = posix_spawn_file_actions_destroy(&actions)
            _ = posix_spawnattr_destroy(&attributes)
        }

        var actionStatus = posix_spawn_file_actions_adddup2(&actions, stdoutWriteDescriptor, STDOUT_FILENO)
        actionStatus = actionStatus == 0 ? posix_spawn_file_actions_addclose(&actions, stdoutReadDescriptor) : actionStatus
        actionStatus = actionStatus == 0 ? posix_spawn_file_actions_addclose(&actions, stdoutWriteDescriptor) : actionStatus
        actionStatus = actionStatus == 0 ? posix_spawn_file_actions_adddup2(&actions, stderrWriteDescriptor, STDERR_FILENO) : actionStatus
        actionStatus = actionStatus == 0 ? posix_spawn_file_actions_addclose(&actions, stderrReadDescriptor) : actionStatus
        actionStatus = actionStatus == 0 ? posix_spawn_file_actions_addclose(&actions, stderrWriteDescriptor) : actionStatus
        if let stdinReadDescriptor, let stdinWriteDescriptor {
            actionStatus = actionStatus == 0 ? posix_spawn_file_actions_adddup2(&actions, stdinReadDescriptor, STDIN_FILENO) : actionStatus
            actionStatus = actionStatus == 0 ? posix_spawn_file_actions_addclose(&actions, stdinReadDescriptor) : actionStatus
            actionStatus = actionStatus == 0 ? posix_spawn_file_actions_addclose(&actions, stdinWriteDescriptor) : actionStatus
        } else if actionStatus == 0 {
            actionStatus = "/dev/null".withCString { path in
                posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, path, O_RDONLY, 0)
            }
        }
        guard actionStatus == 0 else {
            throw MSWClientError.processFailed(command: arguments.first ?? executable.lastPathComponent, status: actionStatus, message: "Could not configure MSW process pipes.")
        }

        // POSIX_SPAWN_SETPGROUP makes the child become the process-group leader
        // atomically as it is spawned. A post-spawn setpgid call would race the
        // child exec and could leave descendants outside the cleanup boundary.
        let groupFlag = Int16(POSIX_SPAWN_SETPGROUP)
        guard posix_spawnattr_setflags(&attributes, groupFlag) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
            throw MSWClientError.processFailed(command: arguments.first ?? executable.lastPathComponent, status: -1, message: "Could not configure the MSW process group.")
        }

        let argumentValues = [executable.path] + arguments
        var argv: [UnsafeMutablePointer<CChar>?] = argumentValues.map { value in
            value.withCString { strdup($0) }
        }
        argv.append(nil)
        let environmentValues = environment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
        var envp: [UnsafeMutablePointer<CChar>?] = environmentValues.map { value in
            value.withCString { strdup($0) }
        }
        envp.append(nil)
        defer {
            for pointer in argv {
                if let pointer { free(pointer) }
            }
            for pointer in envp {
                if let pointer { free(pointer) }
            }
        }

        var processIdentifier: pid_t = 0
        let result = executable.path.withCString { executablePath in
            argv.withUnsafeMutableBufferPointer { argvBuffer in
                envp.withUnsafeMutableBufferPointer { envpBuffer in
                    posix_spawn(
                        &processIdentifier,
                        executablePath,
                        &actions,
                        &attributes,
                        argvBuffer.baseAddress,
                        envpBuffer.baseAddress
                    )
                }
            }
        }
        guard result == 0 else {
            let message = String(cString: strerror(result))
            throw MSWClientError.processFailed(
                command: arguments.first ?? executable.lastPathComponent,
                status: result,
                message: message
            )
        }
        return processIdentifier
    }

    private nonisolated static func terminate(_ processIdentifier: pid_t, grace: Duration) async {
        guard processIdentifier > 0 else { return }
        _ = Darwin.kill(-processIdentifier, SIGTERM)
        _ = Darwin.kill(processIdentifier, SIGTERM)
        let deadline = ContinuousClock.now + grace
        let exited = await Task.detached(priority: .utility) {
            while ContinuousClock.now < deadline {
                if Darwin.kill(processIdentifier, 0) != 0 && errno == ESRCH { return true }
                // Cancellation cleanup must keep its grace period even though
                // the originating Swift task is cancelled. A cancellable
                // Task.sleep would otherwise spin until the deadline.
                Darwin.usleep(10_000)
            }
            return false
        }.value
        if exited { return }
        _ = Darwin.kill(-processIdentifier, SIGKILL)
        _ = Darwin.kill(processIdentifier, SIGKILL)
    }

    private nonisolated static func waitForExit(_ processIdentifier: pid_t) -> Int32 {
        var status: Int32 = 0
        while true {
            let result = waitpid(processIdentifier, &status, 0)
            if result == processIdentifier { break }
            if result == -1 && errno == EINTR { continue }
            return 1
        }
        let signal = status & 0x7f
        if signal == 0 {
            return (status >> 8) & 0xff
        }
        return 128 + signal
    }

    private nonisolated static func readCapped(
        _ handle: FileHandle,
        limit: Int,
        preserveTail: Bool
    ) -> Data {
        var result = Data()
        while true {
            let chunk = handle.readData(ofLength: 64 * 1024)
            guard !chunk.isEmpty else { break }
            if preserveTail {
                result.append(chunk)
                if result.count > limit {
                    result.removeFirst(result.count - limit)
                }
            } else if result.count < limit {
                result.append(chunk.prefix(limit - result.count))
            }
        }
        return result
    }
}
