import Foundation

protocol SiloHostRepairAuthorizing: Sendable {
    func repair(records: [SiloWorkspaceNetworkRecord]) async throws
}

struct SiloHostRepairAuthorization: SiloHostRepairAuthorizing, Sendable {
    enum Failure: Error, LocalizedError, Sendable, Equatable {
        case unavailable
        case cancelled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "Administrator approval is unavailable for host integration."
            case .cancelled:
                return "Host integration approval was cancelled."
            case .failed(let message):
                return message.isEmpty ? "Host integration could not be repaired." : message
            }
        }
    }

    typealias Command = @Sendable (SiloCommand) async throws -> SiloCommandResult

    private let command: Command

    init(runner: SiloCommandRunner = SiloCommandRunner()) {
        self.command = { command in
            try await runner.run(command)
        }
    }

    init(command: @escaping Command) {
        self.command = command
    }

    func repair(records: [SiloWorkspaceNetworkRecord]) async throws {
        guard !records.isEmpty,
              records.count <= 64,
              records.enumerated().allSatisfy({ index, record in
                  record.address == "127.0.0.\(10 + index)" &&
                    record.hostname.range(
                        of: #"^[a-z][a-z0-9-]{0,31}\.silo\.test$"#,
                        options: .regularExpression
                    ) != nil
              }),
              Set(records.map(\.hostname)).count == records.count else {
            throw Failure.failed("The host integration request contained invalid workspace records.")
        }
        let result: SiloCommandResult
        do {
            result = try await command(SiloCommand(
                executable: URL(fileURLWithPath: "/usr/bin/osascript"),
                arguments: ["-e", Self.appleScript(records: records)],
                timeout: .seconds(90),
                captureLimit: 256 * 1024
            ))
        } catch let error as SiloClientError {
            if error == .cancelled {
                throw Failure.cancelled
            }
            throw Failure.failed(error.localizedDescription)
        } catch {
            throw Failure.failed(error.localizedDescription)
        }

        guard result.status == 0 else {
            let detail = [result.stderrString, result.stdoutString]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? ""
            let lowercased = detail.lowercased()
            if lowercased.contains("user canceled") || lowercased.contains("user cancelled") {
                throw Failure.cancelled
            }
            throw Failure.failed(detail)
        }
    }

    static var appleScriptForTesting: String { appleScript(records: SiloWorkspaceNetwork.fixtureRecords) }

    private static let prompt = "Silo needs administrator approval to configure workspace hostnames and local network aliases."

    private static func appleScript(records: [SiloWorkspaceNetworkRecord]) -> String {
        "do shell script \(appleScriptString(rootRepairScript(records: records))) with administrator privileges with prompt \(appleScriptString(prompt))"
    }

    private static func rootRepairScript(records: [SiloWorkspaceNetworkRecord]) -> String {
        let addresses = records.map(\.address)
        let hostRecords = records
            .map { "\($0.address) \($0.hostname)" }
            .joined(separator: "\n")
        let shellAddresses = addresses.map { "\"\($0)\"" }.joined(separator: " ")

        return """
        set -eu
        desired_addresses=" \(addresses.joined(separator: " ")) "
        for suffix in $(/usr/bin/seq 10 73); do
            address="127.0.0.${suffix}"
            case "$desired_addresses" in
                *" $address "*) ;;
                *) /sbin/ifconfig lo0 | /usr/bin/grep -q "inet ${address} " && /sbin/ifconfig lo0 -alias "${address}" || true ;;
            esac
        done
        for address in \(shellAddresses); do
            /sbin/ifconfig lo0 | /usr/bin/grep -q "inet ${address} " || /sbin/ifconfig lo0 alias "${address}" up
        done

        /usr/bin/install -d -o root -g wheel -m 0755 /usr/local/libexec
        loop_script="$(/usr/bin/mktemp /tmp/silo-loopback.XXXXXX)"
        trap '/bin/rm -f "$loop_script"' EXIT
        /bin/cat >"$loop_script" <<'SILO_LOOPBACK'
        #!/bin/sh
        set -eu
        desired_addresses=" \(addresses.joined(separator: " ")) "
        for suffix in $(/usr/bin/seq 10 73); do
            address="127.0.0.${suffix}"
            case "$desired_addresses" in
                *" $address "*) ;;
                *) /sbin/ifconfig lo0 | /usr/bin/grep -q "inet ${address} " && /sbin/ifconfig lo0 -alias "${address}" || true ;;
            esac
        done
        for address in \(shellAddresses); do
            /sbin/ifconfig lo0 | /usr/bin/grep -q "inet ${address} " || /sbin/ifconfig lo0 alias "${address}" up
        done
        SILO_LOOPBACK
        /usr/bin/install -o root -g wheel -m 0755 "$loop_script" /usr/local/libexec/silo-loopback-aliases

        hosts_tmp="$(/usr/bin/mktemp /tmp/silo-hosts.XXXXXX)"
        /usr/bin/awk '/^# BEGIN SILO MANAGED HOSTS$/{skip=1;next}/^# END SILO MANAGED HOSTS$/{skip=0;next}!skip{print}' /etc/hosts >"$hosts_tmp"
        /bin/cat >>"$hosts_tmp" <<'SILO_HOSTS'

        # BEGIN SILO MANAGED HOSTS
        \(hostRecords)
        # END SILO MANAGED HOSTS
        SILO_HOSTS
        /usr/bin/install -o root -g wheel -m 0644 "$hosts_tmp" /etc/hosts
        /bin/rm -f "$hosts_tmp"
        /usr/bin/dscacheutil -flushcache
        /usr/bin/killall -HUP mDNSResponder >/dev/null 2>&1 || true

        daemon_plist="/Library/LaunchDaemons/dev.silo.loopback-aliases.plist"
        plist_tmp="$(/usr/bin/mktemp /tmp/silo-loopback.XXXXXX.plist)"
        /bin/cat >"$plist_tmp" <<'SILO_PLIST'
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>Label</key><string>dev.silo.loopback-aliases</string>
        <key>ProgramArguments</key><array><string>/usr/local/libexec/silo-loopback-aliases</string></array>
        <key>RunAtLoad</key><true/>
        </dict></plist>
        SILO_PLIST
        /usr/bin/plutil -lint "$plist_tmp" >/dev/null
        /usr/bin/install -o root -g wheel -m 0644 "$plist_tmp" "$daemon_plist"
        /bin/rm -f "$plist_tmp"
        /bin/launchctl bootout system "$daemon_plist" >/dev/null 2>&1 || true
        /bin/launchctl bootstrap system "$daemon_plist"
        """
    }

    private static func appleScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}
