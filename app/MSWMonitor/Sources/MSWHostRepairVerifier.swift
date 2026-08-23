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
        return Self.managedHostsMatch(String(decoding: data, as: UTF8.self), expected: records)
    }

    /// Managed `/etc/hosts` block dialects. The administrator repair script
    /// strips both spellings and rewrites the managed form; verification
    /// accepts either single complete block so machines configured by earlier
    /// releases or the msw CLI are not flagged for repair when the records
    /// already match.
    private static let managedMarkers = (
        begin: "# BEGIN MSW MONITOR MANAGED HOSTS",
        end: "# END MSW MONITOR MANAGED HOSTS"
    )
    private static let legacyMarkers = (
        begin: "# BEGIN MSW WORKSPACES",
        end: "# END MSW WORKSPACES"
    )

    static func managedHostsMatch(_ text: String, expected records: [MSWWorkspaceNetworkRecord]) -> Bool {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map(String.init)

        func soleIndex(of line: String) -> Int? {
            let found = lines.indices.filter { lines[$0] == line }
            return found.count == 1 ? found[0] : nil
        }

        for (markers, other) in [(Self.managedMarkers, Self.legacyMarkers), (Self.legacyMarkers, Self.managedMarkers)] {
            guard let start = soleIndex(of: markers.begin),
                  let end = soleIndex(of: markers.end),
                  start < end else {
                continue
            }
            // Exactly one unambiguous managed block may exist: any trace of
            // the other dialect means the file needs a real repair pass.
            guard !lines.contains(other.begin), !lines.contains(other.end) else {
                return false
            }
            let actual = lines[(start + 1)..<end].map { line in
                line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            }
            return actual == records.map { [$0.address, $0.hostname] }
        }
        return false
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
