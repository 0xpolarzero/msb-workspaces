import Foundation

protocol MSWUserIntegrationControlling: Sendable {
    func configureUserIntegrationIfAvailable() async throws
}

struct MSWUserIntegrationService: MSWUserIntegrationControlling, Sendable {
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

    init(runner: MSWCommandRunner = MSWCommandRunner()) {
        self.runner = runner
    }

    func configureUserIntegrationIfAvailable() async throws {
        let command: MSWCommand
        do {
            command = try await runner.makeMSWCommand(
                arguments: ["host", "repair"],
                environment: ["MSW_SKIP_HOST_REPAIR": "1"],
                timeout: .seconds(5 * 60)
            )
        } catch {
            throw Failure.failed(error.localizedDescription)
        }
        _ = try await run(command)
    }

    private func run(_ command: MSWCommand) async throws -> MSWCommandResult {
        let result: MSWCommandResult
        do {
            result = try await runner.run(command)
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
}
