import Foundation

protocol MSWHostRepairVerifying: Sendable {
    func isReady(records: [MSWWorkspaceNetworkRecord]) async -> Bool
}

struct MSWHostRepairVerifier: MSWHostRepairVerifying, Sendable {
    private let runner: MSWCommandRunner

    init(runner: MSWCommandRunner = MSWCommandRunner()) {
        self.runner = runner
    }

    func isReady(records: [MSWWorkspaceNetworkRecord]) async -> Bool {
        guard hostsFileIsReady(records: records),
              await loopbackAliasesAreReady(records: records),
              await launchDaemonIsReady() else {
            return false
        }
        return true
    }

    private func hostsFileIsReady(records: [MSWWorkspaceNetworkRecord]) -> Bool {
        let url = URL(fileURLWithPath: "/etc/hosts")
        guard let data = try? Data(contentsOf: url), data.count <= 1_024 * 1_024 else {
            return false
        }
        let lines = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        let managedStart = "# BEGIN MSW MONITOR MANAGED HOSTS"
        let managedEnd = "# END MSW MONITOR MANAGED HOSTS"
        let starts = lines.indices.filter { lines[$0] == managedStart }
        let ends = lines.indices.filter { lines[$0] == managedEnd }
        guard starts.count == 1, ends.count == 1,
              let start = starts.first, let end = ends.first,
              start < end else { return false }
        let actual = lines[(start + 1)..<end].map { line in
            line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        }
        return actual == records.map { [$0.address, $0.hostname] }
    }

    private func loopbackAliasesAreReady(records: [MSWWorkspaceNetworkRecord]) async -> Bool {
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
        let installedManagedAddresses = Set(result.stdoutString
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> String? in
                let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard fields.count >= 2, fields[0] == "inet" else { return nil }
                let address = String(fields[1])
                guard let suffix = Int(address.split(separator: ".").last ?? ""),
                      address.hasPrefix("127.0.0."),
                      (10...73).contains(suffix) else { return nil }
                return address
            })
        let expectedAddresses = Set(records.map(\.address))
        return installedManagedAddresses == expectedAddresses
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
