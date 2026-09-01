import Foundation

protocol SiloUserIntegrationControlling: Sendable {
    func configureUserIntegrationIfAvailable() async throws
}

struct SiloUserIntegrationService: SiloUserIntegrationControlling, Sendable {
    enum Failure: Error, LocalizedError, Sendable, Equatable {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .failed(let message):
                return message.isEmpty ? "The Silo host integration command failed." : message
            }
        }
    }

    private let runner: SiloCommandRunner

    init(runner: SiloCommandRunner = SiloCommandRunner()) {
        self.runner = runner
    }

    func configureUserIntegrationIfAvailable() async throws {
        let command: SiloCommand
        do {
            command = try await runner.makeSiloCommand(
                arguments: ["host", "repair"],
                environment: ["SILO_SKIP_HOST_REPAIR": "1"],
                timeout: .seconds(5 * 60)
            )
        } catch {
            throw Failure.failed(error.localizedDescription)
        }
        _ = try await run(command)
    }

    private func run(_ command: SiloCommand) async throws -> SiloCommandResult {
        let result: SiloCommandResult
        do {
            result = try await runner.run(command)
        } catch let error as SiloClientError {
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
