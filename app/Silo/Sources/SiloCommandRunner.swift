@preconcurrency import Foundation
import Darwin

struct SiloCommand: Sendable {
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

struct SiloCommandResult: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: Data
    let duration: Duration

    var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

struct SiloExecutableResolution: Sendable, Equatable {
    let selected: URL?
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

actor SiloCommandRunner {
    struct Configuration: Sendable {
        let homeDirectory: URL
        let additionalSearchPaths: [URL]
        let managedToolchainRoot: URL
        let testSiloExecutable: URL?

        init(
            homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
            additionalSearchPaths: [URL] = [],
            managedToolchainRoot: URL? = nil,
            testSiloExecutable: URL? = nil
        ) {
            self.homeDirectory = homeDirectory
            self.additionalSearchPaths = additionalSearchPaths
            self.managedToolchainRoot = managedToolchainRoot ?? ToolchainLayout.managedRoot(homeDirectory: homeDirectory)
            self.testSiloExecutable = testSiloExecutable
        }
    }

    private struct RunningProcess: Sendable {
        let processIdentifier: pid_t
    }

    private let configuration: Configuration
    private let redactor = SiloProtocolRedactor()
    private var runningProcesses: [UUID: RunningProcess] = [:]
    private var cancelledOperations: Set<UUID> = []
    private var cachedSiloResolution: SiloExecutableResolution?
    private var cachedSelectedHandshake: (url: URL, handshake: SiloHandshake)?
    private var siloResolutionGeneration = 0

    init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    func run(_ command: SiloCommand, operationID: UUID = UUID()) async throws -> SiloCommandResult {
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
            throw SiloClientError.cancelled
        }
        let duration = startedAt.duration(to: .now)
        let redactedStdout = Data(redactor.redact(String(decoding: stdout, as: UTF8.self)).utf8)
        let redactedStderr = Data(redactor.redact(String(decoding: stderr, as: UTF8.self)).utf8)
        return SiloCommandResult(status: status, stdout: redactedStdout, stderr: redactedStderr, duration: duration)
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
            .appending(path: ".config/silo/workspaces.json")
        guard let values = try? url.resourceValues(forKeys: [
                  .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey
              ]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize <= 256 * 1_024,
              let data = try? Data(contentsOf: url),
              let boundary = SiloBootstrapConfiguration.decodeValidated(from: data) else {
            return nil
        }
        return boundary.setupConfigurations
    }

    func resolveSilo() -> URL? {
        siloCandidates().first?.executable
    }

    func siloResolution(forceRefresh: Bool = false) async -> SiloExecutableResolution {
        if !forceRefresh, let cachedSiloResolution {
            return cachedSiloResolution
        }
        siloResolutionGeneration &+= 1
        let generation = siloResolutionGeneration
        let candidates = siloCandidates()
        for candidate in candidates {
            if let handshake = await handshakeIfCompatible(
                candidate.executable,
                expectedVersion: candidate.expectedVersion
            ) {
                let resolution = SiloExecutableResolution(selected: candidate.executable)
                if generation == siloResolutionGeneration {
                    cachedSiloResolution = resolution
                    cachedSelectedHandshake = (url: candidate.executable, handshake: handshake)
                }
                return resolution
            }
            // Cancellation can interrupt the handshake used for capability
            // detection. Do not poison the shared resolver cache with that
            // transient result; a queued mutation must be able to resolve the
            // same executable after the cancelled process group has exited.
            if Task.isCancelled {
                return SiloExecutableResolution(selected: nil)
            }
        }
        let resolution = SiloExecutableResolution(selected: nil)
        if generation == siloResolutionGeneration {
            cachedSiloResolution = resolution
            cachedSelectedHandshake = nil
        }
        return resolution
    }

    /// Returns the handshake captured during the most recent resolution of the
    /// currently selected runtime, so callers can reuse the spawn instead of
    /// running an identical `silo app handshake` again.
    func handshakeForSelectedRuntime() -> SiloHandshake? {
        guard let selected = cachedSiloResolution?.selected,
              let pair = cachedSelectedHandshake,
              pair.url == selected else { return nil }
        return pair.handshake
    }

    func invalidateSiloResolution() {
        siloResolutionGeneration &+= 1
        cachedSiloResolution = nil
        cachedSelectedHandshake = nil
    }

    private struct SiloCandidate {
        let executable: URL
        let expectedVersion: String?
    }

    private func siloCandidates() -> [SiloCandidate] {
        if let testExecutable = configuration.testSiloExecutable,
           Self.isExecutableCandidate(testExecutable) {
            return [SiloCandidate(executable: testExecutable, expectedVersion: nil)]
        }
        var candidates: [SiloCandidate] = []
        let current = configuration.managedToolchainRoot.appendingPathComponent("current", isDirectory: true)
        if let bundledRoot = ToolchainLayout.bundledRoot(),
           let bundled = try? ToolchainValidator.validateBundled(root: bundledRoot),
           let validated = try? ToolchainValidator.validateActivated(root: current),
           validated.manifest == bundled.manifest {
            candidates.append(SiloCandidate(
                executable: validated.executable,
                expectedVersion: validated.manifest.version
            ))
        }
        return candidates
    }

    /// Runs the exact protocol handshake against one permitted executable.
    /// The handshake is the same command the client
    /// issues later, so callers can reuse it instead of spawning twice.
    private func handshakeIfCompatible(
        _ executable: URL,
        expectedVersion: String?
    ) async -> SiloHandshake? {
        do {
            let output = try await run(SiloCommand(
                executable: executable,
                arguments: ["app", "handshake", "--format", "json"],
                timeout: .seconds(5),
                captureLimit: 256 * 1024
            ))
            let envelope = try SiloProtocolDecoder.decodeStrictHandshake(output.stdout)
            guard envelope.schemaVersion == 1,
                  envelope.command == "handshake",
                  !envelope.requestId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  envelope.observedAt != nil else {
                return nil
            }
            if envelope.ok {
                guard output.status == 0,
                      envelope.error == nil,
                      let result = envelope.result,
                      result.protocolVersion == 1,
                      result.capabilities.isComplete,
                      expectedVersion.map({ result.siloVersion == $0 }) ?? true else {
                    return nil
                }
                return result
            }
            // Only a clean ok envelope with protocolVersion 1 carries a result.
            return nil
        } catch {
            return nil
        }
    }

    func resolveExecutable(named name: String) -> URL? {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return nil }
        if name == "silo" { return resolveSilo() }
        var directories = [configuration.homeDirectory.appending(path: ".local/bin")]
        directories.append(contentsOf: configuration.additionalSearchPaths.map { $0.deletingLastPathComponent() })
        directories.append(contentsOf: [
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
            let result = try await run(SiloCommand(
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

    func makeSiloCommand(
        arguments: [String],
        environment: [String: String] = [:],
        timeout: Duration = .seconds(30),
        stdin: Data? = nil,
        terminationGrace: Duration = .milliseconds(250)
    ) async throws -> SiloCommand {
        let resolution = await siloResolution()
        guard let executable = resolution.selected else {
            throw SiloClientError.invalidExecutable
        }
        return SiloCommand(
            executable: executable,
            arguments: arguments,
            environment: environment,
            timeout: timeout,
            stdin: stdin,
            terminationGrace: terminationGrace
        )
    }

    private func processEnvironment(for command: SiloCommand) -> [String: String] {
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
        // Finder/launchd environments are not part of the app-to-Silo
        // contract. In particular, ambient SILO_* overrides could redirect
        // helper binaries or credential stores. Tests and explicit advanced
        // settings pass narrowly allowed values through command.environment.
        key == "TMPDIR"
    }

    private static func isSafeEnvironmentVariable(_ key: String) -> Bool {
        guard !key.uppercased().contains("TOKEN"),
              !key.uppercased().contains("SECRET"),
              !key.uppercased().contains("PASSWORD"),
              !key.uppercased().contains("PRIVATE_KEY"),
              key != "SILO_EXECUTABLE" else {
            return false
        }
        return key == "SILO_CONFIG_FILE"
            || key == "SILO_SKIP_HOST_REPAIR"
            || key == "SILO_TEST_KEYCHAIN_DIR"
            || key == "SILO_TEST_VISIBLE"
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
        paths.append(configuration.managedToolchainRoot.appending(path: "current/bin").path)
        paths.append(contentsOf: [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"
        ])
        return paths.joined(separator: ":")
    }

    private func wait(for processIdentifier: pid_t, command: SiloCommand) async throws -> Int32 {
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
                        throw SiloClientError.timedOut(command: command.arguments.first ?? "silo")
                    }
                    guard let result = try await group.next() else {
                        throw SiloClientError.cancelled
                    }
                    group.cancelAll()
                    if Task.isCancelled { throw SiloClientError.cancelled }
                    return result
                }
            } onCancel: {
                Task { await Self.terminate(processIdentifier, grace: command.terminationGrace) }
            }
        } catch is CancellationError {
            throw SiloClientError.cancelled
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
            throw SiloClientError.processFailed(command: arguments.first ?? executable.lastPathComponent, status: -1, message: "Could not initialize Silo process controls.")
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
            throw SiloClientError.processFailed(command: arguments.first ?? executable.lastPathComponent, status: actionStatus, message: "Could not configure Silo process pipes.")
        }

        // POSIX_SPAWN_SETPGROUP makes the child become the process-group leader
        // atomically as it is spawned. A post-spawn setpgid call would race the
        // child exec and could leave descendants outside the cleanup boundary.
        let groupFlag = Int16(POSIX_SPAWN_SETPGROUP)
        guard posix_spawnattr_setflags(&attributes, groupFlag) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
            throw SiloClientError.processFailed(command: arguments.first ?? executable.lastPathComponent, status: -1, message: "Could not configure the Silo process group.")
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
            throw SiloClientError.processFailed(
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
