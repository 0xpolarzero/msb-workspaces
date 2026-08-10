import Darwin
import Foundation
import Security

private let serviceName = "org.microsandbox.MSWMonitor.host-agent"
private let appIdentifier = "org.microsandbox.MSWMonitor"
private let managedStart = "# BEGIN MSW MONITOR MANAGED HOSTS"
private let managedEnd = "# END MSW MONITOR MANAGED HOSTS"
private let hostsURL = URL(fileURLWithPath: "/etc/hosts")
private let fixedRecords = MSWWorkspaceNetwork.records

struct MSWHostRecordSnapshot: Codable, Sendable {
    let fixedAliases: [String]
    let hostsBlockInstalled: Bool
    let launchDaemonRegistered: Bool
}

@objc protocol MSWHostAgentProtocol {
    func inspect(_ reply: @escaping (Data?, String?) -> Void)
    func ensureFixedLoopbackAliases(_ reply: @escaping (Data?, String?) -> Void)
    func installFixedHostRecords(_ reply: @escaping (Data?, String?) -> Void)
    func uninstall(reply: @escaping (Data?, String?) -> Void)
}

private enum HostAgentError: LocalizedError {
    case invalidInput
    case readFailed
    case writeFailed
    case loopbackFailed

    var errorDescription: String? {
        switch self {
        case .invalidInput: return "The fixed host integration state is malformed."
        case .readFailed: return "The MSW-managed host records could not be read."
        case .writeFailed: return "The MSW-managed host records could not be written atomically."
        case .loopbackFailed: return "The fixed MSW loopback aliases could not be configured."
        }
    }
}

private final class LoopbackStore {
    private let executable = URL(fileURLWithPath: "/sbin/ifconfig")

    func installedAddresses() throws -> [String] {
        let output = try run(["lo0"], captureOutput: true)
        let installed = Set(output.split(separator: "\n").compactMap { line -> String? in
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2, fields[0] == "inet" else { return nil }
            return String(fields[1])
        })
        return fixedRecords.map(\.address).filter(installed.contains).sorted()
    }

    func ensureFixedAliases() throws {
        var installed = Set(try installedAddresses())
        for address in fixedRecords.map(\.address) where !installed.contains(address) {
            _ = try run(["lo0", "alias", address, "up"], captureOutput: false)
            installed.insert(address)
        }
    }

    func removeFixedAliases() throws {
        let installed = Set(try installedAddresses())
        for address in fixedRecords.map(\.address) where installed.contains(address) {
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
    func inspect() throws -> Bool {
        let lines = try readValidatedLines()
        guard let range = try managedRange(in: lines) else { return false }
        let expected = fixedRecords.map { "\($0.address)\t\($0.hostname)" }
        return Array(lines[(range.lowerBound + 1)..<range.upperBound]) == expected
    }

    func install() throws {
        var lines = try readValidatedLines()
        lines = try removingManagedBlock(from: lines)
        while lines.last == "" { lines.removeLast() }
        if !lines.isEmpty { lines.append("") }
        lines.append(managedStart)
        lines.append(contentsOf: fixedRecords.map { "\($0.address)\t\($0.hostname)" })
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

    private func managedRange(in lines: [String]) throws -> ClosedRange<Int>? {
        let starts = lines.indices.filter { lines[$0] == managedStart }
        let ends = lines.indices.filter { lines[$0] == managedEnd }
        guard starts.count == ends.count else { throw HostAgentError.invalidInput }
        guard starts.count <= 1 else { throw HostAgentError.invalidInput }
        guard let start = starts.first, let end = ends.first else { return nil }
        guard start < end else { throw HostAgentError.invalidInput }
        return start...end
    }

    private func removingManagedBlock(from lines: [String]) throws -> [String] {
        guard let range = try managedRange(in: lines) else { return lines }
        var result = lines
        result.removeSubrange(range)
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
        let temporary = hostsURL.deletingLastPathComponent().appendingPathComponent(".msw-hosts-\(UUID().uuidString)")
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

private final class HostAgentOperations: NSObject, MSWHostAgentProtocol {
    private let hosts = HostRecordStore()
    private let loopback = LoopbackStore()
    private let lock = NSLock()

    func inspect(_ reply: @escaping (Data?, String?) -> Void) {
        respond(reply) { try snapshot() }
    }

    func ensureFixedLoopbackAliases(_ reply: @escaping (Data?, String?) -> Void) {
        respond(reply) {
            try loopback.ensureFixedAliases()
            return try snapshot()
        }
    }

    func installFixedHostRecords(_ reply: @escaping (Data?, String?) -> Void) {
        respond(reply) {
            try hosts.install()
            return try snapshot()
        }
    }

    func uninstall(reply: @escaping (Data?, String?) -> Void) {
        respond(reply) {
            try hosts.uninstall()
            try loopback.removeFixedAliases()
            return try snapshot()
        }
    }

    private func snapshot() throws -> MSWHostRecordSnapshot {
        MSWHostRecordSnapshot(
            fixedAliases: try loopback.installedAddresses(),
            hostsBlockInstalled: try hosts.inspect(),
            launchDaemonRegistered: true
        )
    }

    private func respond(_ reply: @escaping (Data?, String?) -> Void, operation: () throws -> MSWHostRecordSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        do {
            reply(try JSONEncoder().encode(operation()), nil)
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
        connection.exportedInterface = NSXPCInterface(with: MSWHostAgentProtocol.self)
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
private struct MSWHostAgentMain {
    static func main() {
        let listener = NSXPCListener(machServiceName: serviceName)
        let delegate = HostAgentDelegate()
        listener.delegate = delegate
        listener.resume()
        RunLoop.current.run()
    }
}
