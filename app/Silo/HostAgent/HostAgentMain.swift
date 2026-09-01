import Darwin
import Foundation
import Security

private let serviceName = "org.silo.Silo.host-agent"
private let appIdentifier = "org.silo.Silo"
private let managedStart = "# BEGIN SILO MANAGED HOSTS"
private let managedEnd = "# END SILO MANAGED HOSTS"
private let hostsURL = URL(fileURLWithPath: "/etc/hosts")

struct SiloHostRecordSnapshot: Codable, Sendable {
    let fixedAliases: [String]
    let hostsBlockInstalled: Bool
    let launchDaemonRegistered: Bool
}

@objc protocol SiloHostAgentProtocol {
    func inspect(_ configuration: Data, reply: @escaping (Data?, String?) -> Void)
    func ensureFixedLoopbackAliases(_ configuration: Data, reply: @escaping (Data?, String?) -> Void)
    func installFixedHostRecords(_ configuration: Data, reply: @escaping (Data?, String?) -> Void)
    func uninstall(_ configuration: Data, reply: @escaping (Data?, String?) -> Void)
}

private enum HostAgentError: LocalizedError {
    case invalidInput
    case readFailed
    case writeFailed
    case loopbackFailed

    var errorDescription: String? {
        switch self {
        case .invalidInput: return "The fixed host integration state is malformed."
        case .readFailed: return "The Silo-managed host records could not be read."
        case .writeFailed: return "The Silo-managed host records could not be written atomically."
        case .loopbackFailed: return "The fixed Silo loopback aliases could not be configured."
        }
    }
}

private final class LoopbackStore {
    private let executable = URL(fileURLWithPath: "/sbin/ifconfig")
    private let managedAddresses = Set((10...73).map { "127.0.0.\($0)" })

    private func currentAddresses() throws -> Set<String> {
        let output = try run(["lo0"], captureOutput: true)
        return Set(output.split(separator: "\n").compactMap { line -> String? in
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2, fields[0] == "inet" else { return nil }
            return String(fields[1])
        })
    }

    func installedAddresses(records: [SiloWorkspaceNetworkRecord]) throws -> [String] {
        let installed = try currentAddresses()
        return records.map(\.address).filter(installed.contains).sorted()
    }

    func ensureFixedAliases(records: [SiloWorkspaceNetworkRecord]) throws {
        let desired = Set(records.map(\.address))
        var installed = try currentAddresses()
        for address in installed.intersection(managedAddresses).subtracting(desired).sorted() {
            _ = try run(["lo0", "-alias", address], captureOutput: false)
            installed.remove(address)
        }
        for address in desired.subtracting(installed).sorted() {
            _ = try run(["lo0", "alias", address, "up"], captureOutput: false)
            installed.insert(address)
        }
    }

    func removeManagedAliases() throws {
        let installed = try currentAddresses().intersection(managedAddresses)
        for address in installed.sorted() {
            _ = try run(["lo0", "-alias", address], captureOutput: false)
        }
    }

    private func run(_ arguments: [String], captureOutput: Bool) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        if captureOutput {
            process.standardOutput = output
        } else {
            process.standardOutput = FileHandle.nullDevice
        }
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw HostAgentError.loopbackFailed
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw HostAgentError.loopbackFailed
        }
        guard captureOutput else { return "" }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard data.count <= 64 * 1024 else { throw HostAgentError.loopbackFailed }
        return String(decoding: data, as: UTF8.self)
    }
}

private final class HostRecordStore {
    func inspect(records: [SiloWorkspaceNetworkRecord]) throws -> Bool {
        let lines = try readValidatedLines()
        guard let range = try managedRange(in: lines, startMarker: managedStart, endMarker: managedEnd) else {
            return false
        }
        let expected = records.map { "\($0.address)\t\($0.hostname)" }
        return Array(lines[(range.lowerBound + 1)..<range.upperBound]) == expected
    }

    func install(records: [SiloWorkspaceNetworkRecord]) throws {
        var lines = try readValidatedLines()
        lines = try removingManagedBlock(from: lines)
        while lines.last == "" { lines.removeLast() }
        if !lines.isEmpty { lines.append("") }
        lines.append(managedStart)
        lines.append(contentsOf: records.map { "\($0.address)\t\($0.hostname)" })
        lines.append(managedEnd)
        try atomicWrite(lines.joined(separator: "\n") + "\n")
    }

    func uninstall() throws {
        let original = try readValidatedLines()
        let cleaned = try removingManagedBlock(from: original)
        guard cleaned != original else { return }
        var normalized = cleaned
        while normalized.count > 1, normalized.last == "", normalized[normalized.count - 2] == "" {
            normalized.removeLast()
        }
        try atomicWrite(normalized.joined(separator: "\n"))
    }

    private func readValidatedLines() throws -> [String] {
        do {
            let values = try hostsURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  (values.fileSize ?? Int.max) <= 1_048_576 else {
                throw HostAgentError.invalidInput
            }
            let text = try String(contentsOf: hostsURL, encoding: .utf8)
            return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        } catch let error as HostAgentError {
            throw error
        } catch {
            throw HostAgentError.readFailed
        }
    }

    private func managedRange(
        in lines: [String],
        startMarker: String,
        endMarker: String
    ) throws -> ClosedRange<Int>? {
        let starts = lines.indices.filter { lines[$0] == startMarker }
        let ends = lines.indices.filter { lines[$0] == endMarker }
        guard starts.count == ends.count else { throw HostAgentError.invalidInput }
        guard starts.count <= 1 else { throw HostAgentError.invalidInput }
        guard let start = starts.first, let end = ends.first else { return nil }
        guard start < end else { throw HostAgentError.invalidInput }
        return start...end
    }

    private func removingManagedBlock(from lines: [String]) throws -> [String] {
        var result = lines
        if let range = try managedRange(
            in: result,
            startMarker: managedStart,
            endMarker: managedEnd
        ) {
            result.removeSubrange(range)
        }
        return result
    }

    private func atomicWrite(_ text: String) throws {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: hostsURL.path)
        } catch {
            throw HostAgentError.readFailed
        }
        let mode = mode_t((attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644)
        let owner = uid_t((attributes[.ownerAccountID] as? NSNumber)?.uint32Value ?? 0)
        let group = gid_t((attributes[.groupOwnerAccountID] as? NSNumber)?.uint32Value ?? 0)
        let temporary = hostsURL.deletingLastPathComponent().appendingPathComponent(".silo-hosts-\(UUID().uuidString)")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode)
        guard descriptor >= 0 else { throw HostAgentError.writeFailed }
        var shouldRemove = true
        defer {
            Darwin.close(descriptor)
            if shouldRemove { _ = Darwin.unlink(temporary.path) }
        }
        let bytes = Array(text.utf8)
        let wroteAll = bytes.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return bytes.isEmpty }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += count
            }
            return true
        }
        guard wroteAll,
              Darwin.fchmod(descriptor, mode) == 0,
              Darwin.fchown(descriptor, owner, group) == 0,
              Darwin.fsync(descriptor) == 0,
              Darwin.rename(temporary.path, hostsURL.path) == 0 else {
            throw HostAgentError.writeFailed
        }
        shouldRemove = false
    }
}

private final class HostAgentOperations: NSObject, SiloHostAgentProtocol {
    private let hosts = HostRecordStore()
    private let loopback = LoopbackStore()
    private let lock = NSLock()

    func inspect(_ configuration: Data, reply: @escaping (Data?, String?) -> Void) {
        respond(configuration, reply: reply) { records in try snapshot(records: records) }
    }

    func ensureFixedLoopbackAliases(_ configuration: Data, reply: @escaping (Data?, String?) -> Void) {
        respond(configuration, reply: reply) { records in
            try loopback.ensureFixedAliases(records: records)
            return try snapshot(records: records)
        }
    }

    func installFixedHostRecords(_ configuration: Data, reply: @escaping (Data?, String?) -> Void) {
        respond(configuration, reply: reply) { records in
            try hosts.install(records: records)
            return try snapshot(records: records)
        }
    }

    func uninstall(_ configuration: Data, reply: @escaping (Data?, String?) -> Void) {
        respond(configuration, reply: reply) { records in
            try hosts.uninstall()
            try loopback.removeManagedAliases()
            return try snapshot(records: records)
        }
    }

    private func snapshot(records: [SiloWorkspaceNetworkRecord]) throws -> SiloHostRecordSnapshot {
        SiloHostRecordSnapshot(
            fixedAliases: try loopback.installedAddresses(records: records),
            hostsBlockInstalled: try hosts.inspect(records: records),
            launchDaemonRegistered: true
        )
    }

    private func respond(
        _ configuration: Data,
        reply: @escaping (Data?, String?) -> Void,
        operation: ([SiloWorkspaceNetworkRecord]) throws -> SiloHostRecordSnapshot
    ) {
        lock.lock()
        defer { lock.unlock() }
        do {
            guard configuration.count <= 16 * 1024,
                  let records = try? JSONDecoder().decode([SiloWorkspaceNetworkRecord].self, from: configuration),
                  !records.isEmpty,
                  records.count <= 64,
                  records.enumerated().allSatisfy({ index, record in
                      record.address == "127.0.0.\(10 + index)" &&
                      record.hostname.range(of: #"^[a-z][a-z0-9-]{0,31}\.silo\.test$"#, options: .regularExpression) != nil
                  }),
                  Set(records.map(\.hostname)).count == records.count else {
                throw HostAgentError.invalidInput
            }
            reply(try JSONEncoder().encode(operation(records)), nil)
        } catch {
            reply(nil, error.localizedDescription)
        }
    }
}

private final class HostAgentDelegate: NSObject, NSXPCListenerDelegate {
    private let operations = HostAgentOperations()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard isAuthorized(connection) else {
            connection.invalidate()
            return false
        }
        connection.exportedInterface = NSXPCInterface(with: SiloHostAgentProtocol.self)
        connection.exportedObject = operations
        connection.invalidationHandler = {}
        connection.interruptionHandler = {}
        connection.resume()
        return true
    }

    private func isAuthorized(_ connection: NSXPCConnection) -> Bool {
        let ownURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        var ownCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(ownURL as CFURL, [], &ownCode) == errSecSuccess,
              let ownCode,
              SecStaticCodeCheckValidity(ownCode, [], nil) == errSecSuccess,
              let own = signingIdentity(of: ownCode),
              own.teamIdentifier.range(of: #"^[A-Z0-9]{10}$"#, options: String.CompareOptions.regularExpression) != nil else {
            return false
        }

        // Ask Security.framework for the code attached to the XPC peer PID;
        // do not trust a bundle URL reported by Launch Services.
        let attributes = [
            kSecGuestAttributePid as String: NSNumber(value: connection.processIdentifier)
        ] as CFDictionary
        var clientCode: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &clientCode) == errSecSuccess,
              let clientCode else {
            return false
        }
        let requirementText = "identifier \"\(appIdentifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(own.teamIdentifier)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecCodeCheckValidity(clientCode, [], requirement) == errSecSuccess,
              connection.effectiveUserIdentifier != 0 else {
            return false
        }
        var clientStaticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(clientCode, [], &clientStaticCode) == errSecSuccess,
              let clientStaticCode,
              let client = signingIdentity(of: clientStaticCode) else { return false }
        return client.identifier == appIdentifier && client.teamIdentifier == own.teamIdentifier
    }

    private func signingIdentity(of code: SecStaticCode) -> (identifier: String, teamIdentifier: String)? {
        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &signingInformation) == errSecSuccess,
              let information = signingInformation as? [String: Any],
              let identifier = information[kSecCodeInfoIdentifier as String] as? String,
              let teamIdentifier = information[kSecCodeInfoTeamIdentifier as String] as? String else {
            return nil
        }
        return (identifier, teamIdentifier)
    }
}

@main
private struct SiloHostAgentMain {
    static func main() {
        let listener = NSXPCListener(machServiceName: serviceName)
        let delegate = HostAgentDelegate()
        listener.delegate = delegate
        listener.resume()
        RunLoop.current.run()
    }
}
