import Foundation

protocol SiloHostRepairVerifying: Sendable {
    func isReady(records: [SiloWorkspaceNetworkRecord]) async -> Bool
}

struct SiloHostRepairVerifier: SiloHostRepairVerifying, Sendable {
    private let runner: SiloCommandRunner

    init(runner: SiloCommandRunner = SiloCommandRunner()) {
        self.runner = runner
    }

    func isReady(records: [SiloWorkspaceNetworkRecord]) async -> Bool {
        guard hostsFileIsReady(records: records),
              await loopbackAliasesAreReady(records: records),
              await launchDaemonIsReady() else {
            return false
        }
        return true
    }

    private func hostsFileIsReady(records: [SiloWorkspaceNetworkRecord]) -> Bool {
        Self.hostsFileMatches(records: records)
    }

    /// Reads /etc/hosts and reports whether the managed block exactly matches
    /// the desired records. Cheap enough for keystroke-frequency UI checks;
    /// the authoritative pre-apply verification still covers aliases and the
    /// daemon as well.
    static func hostsFileMatches(records: [SiloWorkspaceNetworkRecord]) -> Bool {
        let url = URL(fileURLWithPath: "/etc/hosts")
        guard let data = try? Data(contentsOf: url), data.count <= 1_024 * 1_024 else {
            return false
        }
        return Self.managedHostsMatch(String(decoding: data, as: UTF8.self), expected: records)
    }

    /// The administrator repair script and verifier share one canonical
    /// `/etc/hosts` block format.
    private static let managedMarkers = (
        begin: "# BEGIN SILO MANAGED HOSTS",
        end: "# END SILO MANAGED HOSTS"
    )

    static func managedHostsMatch(_ text: String, expected records: [SiloWorkspaceNetworkRecord]) -> Bool {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map(String.init)

        func soleIndex(of line: String) -> Int? {
            let found = lines.indices.filter { lines[$0] == line }
            return found.count == 1 ? found[0] : nil
        }

        guard let start = soleIndex(of: Self.managedMarkers.begin),
              let end = soleIndex(of: Self.managedMarkers.end),
              start < end else {
            return false
        }
        let actual = lines[(start + 1)..<end].map { line in
            line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        }
        return actual == records.map { [$0.address, $0.hostname] }
    }

    private func loopbackAliasesAreReady(records: [SiloWorkspaceNetworkRecord]) async -> Bool {
        guard let result = try? await runner.run(
            SiloCommand(
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
            SiloCommand(
                executable: URL(fileURLWithPath: "/bin/launchctl"),
                arguments: ["print", "system/dev.silo.loopback-aliases"],
                timeout: .seconds(5),
                captureLimit: 64 * 1024
            )
        ) else {
            return false
        }
        return result.status == 0
    }
}
