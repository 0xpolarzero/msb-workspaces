import Foundation

protocol MSWHostRepairVerifying: Sendable {
    func isReady() async -> Bool
}

struct MSWHostRepairVerifier: MSWHostRepairVerifying, Sendable {
    private let runner: MSWCommandRunner

    init(runner: MSWCommandRunner = MSWCommandRunner()) {
        self.runner = runner
    }

    func isReady() async -> Bool {
        guard hostsFileIsReady(), await loopbackAliasesAreReady(), await launchDaemonIsReady() else {
            return false
        }
        return true
    }

    private func hostsFileIsReady() -> Bool {
        let url = URL(fileURLWithPath: "/etc/hosts")
        guard let data = try? Data(contentsOf: url), data.count <= 1_024 * 1_024 else {
            return false
        }
        let lines = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        let expected = [
            ("127.0.0.10", "dev.msw.test"),
            ("127.0.0.11", "playgrounds.msw.test"),
            ("127.0.0.12", "personal.msw.test")
        ]
        return expected.allSatisfy { address, hostname in
            lines.contains { line in
                let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                return fields.count >= 2 && fields[0] == address && fields[1] == hostname
            }
        }
    }

    private func loopbackAliasesAreReady() async -> Bool {
        guard let result = try? await runner.run(
            MSWCommand(
                executable: URL(fileURLWithPath: "/sbin/ifconfig"),
                arguments: ["lo0"],
                timeout: .seconds(5),
                captureLimit: 64 * 1024
            )
        ), result.status == 0 else {
            return false
        }
        let output = result.stdoutString
        return ["127.0.0.10", "127.0.0.11", "127.0.0.12"].allSatisfy { address in
            output.contains("inet \(address) ")
        }
    }

    private func launchDaemonIsReady() async -> Bool {
        guard let result = try? await runner.run(
            MSWCommand(
                executable: URL(fileURLWithPath: "/bin/launchctl"),
                arguments: ["print", "system/dev.msw.loopback-aliases"],
                timeout: .seconds(5),
                captureLimit: 64 * 1024
            )
        ) else {
            return false
        }
        return result.status == 0
    }
}
