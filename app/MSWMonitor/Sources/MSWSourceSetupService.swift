import Foundation

protocol MSWSourceSetupControlling: Sendable {
    var isAvailable: Bool { get }
    func configureUserIntegrationIfAvailable() async throws
}

struct MSWSourceSetupService: MSWSourceSetupControlling, Sendable {
    enum Failure: Error, LocalizedError, Sendable, Equatable {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .failed(let message):
                return message.isEmpty ? "The MSW host integration command failed." : message
            }
        }
    }

    private let runner: MSWCommandRunner
    private let bundleURL: URL
    private let workingDirectory: URL

    init(
        runner: MSWCommandRunner = MSWCommandRunner(),
        bundleURL: URL = Bundle.main.bundleURL,
        workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) {
        self.runner = runner
        self.bundleURL = bundleURL
        self.workingDirectory = workingDirectory
    }
    var isAvailable: Bool {
        sourceRoot() != nil
    }

    func configureUserIntegrationIfAvailable() async throws {
        guard let root = sourceRoot() else { return }
        let launcher = root.appending(path: "bin/msw")
        _ = try await run(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [launcher.path, "host", "repair"],
            timeout: .seconds(5 * 60)
        )
    }

    private func run(
        executable: URL,
        arguments: [String],
        timeout: Duration,
        captureLimit: Int = 256 * 1024,
        environment: [String: String] = [:],
        preserveOutputTail: Bool = false
    ) async throws -> MSWCommandResult {
        let result: MSWCommandResult
        do {
            result = try await runner.run(
                MSWCommand(
                    executable: executable,
                    arguments: arguments,
                    environment: environment.merging(["MSW_SKIP_HOST_REPAIR": "1"]) { _, required in required },
                    timeout: timeout,
                    captureLimit: captureLimit,
                    preserveOutputTail: preserveOutputTail
                )
            )
        } catch let error as MSWClientError {
            throw Failure.failed(error.localizedDescription)
        } catch {
            throw Failure.failed(error.localizedDescription)
        }

        guard result.status == 0 else {
            let detail = [result.stdoutString, result.stderrString]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            throw Failure.failed(detail)
        }
        return result
    }

    private func sourceRoot() -> URL? {
#if DEBUG
        var roots: [URL] = []
        if let explicit = ProcessInfo.processInfo.environment["MSW_SOURCE_ROOT"], !explicit.isEmpty {
            roots.append(URL(fileURLWithPath: explicit, isDirectory: true))
        }
        roots.append(contentsOf: ancestors(of: bundleURL))
        roots.append(contentsOf: ancestors(of: workingDirectory))

        var seen: Set<String> = []
        for root in roots {
            let candidate = root.standardizedFileURL
            guard seen.insert(candidate.path).inserted else { continue }
            guard isSourceRoot(candidate) else { continue }
            return candidate
        }
#endif
        return nil
    }

    private func ancestors(of url: URL) -> [URL] {
        var result: [URL] = []
        var current = url.standardizedFileURL
        for _ in 0..<10 {
            result.append(current)
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return result
    }

    private func isSourceRoot(_ root: URL) -> Bool {
        let fileManager = FileManager.default
        let config = root.appending(path: "config.sh")
        let launcher = root.appending(path: "bin/msw")
        return fileManager.isReadableFile(atPath: config.path)
            && fileManager.isExecutableFile(atPath: launcher.path)
    }
}
