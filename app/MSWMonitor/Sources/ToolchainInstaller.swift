import CryptoKit
import Darwin
import Foundation

struct ToolchainManifest: Codable, Sendable, Equatable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let version: String
    let artifacts: [Artifact]

    struct Artifact: Codable, Sendable, Equatable {
        let path: String
        let sha256: String
        let executable: Bool
    }
}

struct ToolchainInstallResult: Sendable, Equatable {
    let version: String
    let root: URL
    let installedArtifacts: [String]
}

enum ToolchainInstallerError: Error, LocalizedError, Sendable, Equatable {
    case bundledPayloadUnavailable
    case invalidManifest
    case checksumMismatch(String)
    case unsafeArtifact(String)
    case invalidPermissions(String)
    case handshakeFailed
    case installFailed

    var errorDescription: String? {
        switch self {
        case .bundledPayloadUnavailable:
            return "The bundled MSW payload is unavailable."
        case .invalidManifest:
            return "The bundled MSW manifest is invalid."
        case .checksumMismatch(let artifact):
            return "The bundled MSW checksum did not match for \(artifact)."
        case .unsafeArtifact(let artifact):
            return "The bundled MSW artifact is missing or unsafe: \(artifact)."
        case .invalidPermissions(let artifact):
            return "The bundled MSW artifact has invalid permissions: \(artifact)."
        case .handshakeFailed:
            return "The bundled MSW command failed its version handshake."
        case .installFailed:
            return "The bundled MSW payload could not be activated atomically."
        }
    }
}

enum ToolchainLayout {
    static let bundledDirectoryName = "MSWToolchain"
    static let manifestName = "manifest.json"
    static let payloadDirectoryName = "payload"

    static func bundledRoot(in bundle: Bundle = .main) -> URL? {
        bundle.resourceURL?.appendingPathComponent(bundledDirectoryName, isDirectory: true)
    }

    static func managedRoot(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory.appendingPathComponent(
            "Library/Application Support/MSW Monitor/Toolchain",
            isDirectory: true
        )
    }
}

struct ValidatedToolchain: Sendable, Equatable {
    let manifest: ToolchainManifest
    let executable: URL
}

enum ToolchainValidator {
    static func validateBundled(root: URL) throws -> ValidatedToolchain {
        try validate(
            manifestURL: root.appendingPathComponent(ToolchainLayout.manifestName),
            payloadRoot: root.appendingPathComponent(ToolchainLayout.payloadDirectoryName, isDirectory: true)
        )
    }

    static func validateActivated(root: URL) throws -> ValidatedToolchain {
        try validate(
            manifestURL: root.appendingPathComponent(ToolchainLayout.manifestName),
            payloadRoot: root
        )
    }

    private static func validate(manifestURL: URL, payloadRoot: URL) throws -> ValidatedToolchain {
        let manifestData = try readRegularFile(manifestURL, maximumBytes: 2 * 1_024 * 1_024)
        let manifestPermissions = ((try? FileManager.default.attributesOfItem(atPath: manifestURL.path)[.posixPermissions]) as? NSNumber)?.intValue ?? -1
        guard manifestPermissions & 0o777 == 0o644 else {
            throw ToolchainInstallerError.invalidPermissions(ToolchainLayout.manifestName)
        }
        let manifest: ToolchainManifest
        do {
            guard let root = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
                  Set(root.keys) == ["schemaVersion", "version", "artifacts"],
                  let artifacts = root["artifacts"] as? [[String: Any]],
                  artifacts.allSatisfy({ Set($0.keys) == ["path", "sha256", "executable"] }) else {
                throw ToolchainInstallerError.invalidManifest
            }
            manifest = try JSONDecoder().decode(ToolchainManifest.self, from: manifestData)
        } catch let error as ToolchainInstallerError {
            throw error
        } catch {
            throw ToolchainInstallerError.invalidManifest
        }
        guard manifest.schemaVersion == ToolchainManifest.schemaVersion,
              manifest.version.range(
                of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#,
                options: .regularExpression
              ) != nil,
              !manifest.artifacts.isEmpty else {
            throw ToolchainInstallerError.invalidManifest
        }

        var paths = Set<String>()
        for artifact in manifest.artifacts {
            guard isSafeRelativePath(artifact.path),
                  paths.insert(artifact.path).inserted,
                  artifact.sha256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
                throw ToolchainInstallerError.invalidManifest
            }
            let url = payloadRoot.appendingPathComponent(artifact.path)
            let data: Data
            do {
                data = try readRegularFile(url, maximumBytes: 2 * 1_024 * 1_024 * 1_024)
            } catch {
                throw ToolchainInstallerError.unsafeArtifact(artifact.path)
            }
            let digest = SHA256.hash(data: data).hexString
            guard digest == artifact.sha256 else {
                throw ToolchainInstallerError.checksumMismatch(artifact.path)
            }
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let permissions = (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1
            let expected = artifact.executable ? 0o755 : 0o644
            guard permissions & 0o777 == expected else {
                throw ToolchainInstallerError.invalidPermissions(artifact.path)
            }
        }
        guard paths.contains("VERSION"), paths.contains("config.sh"), paths.contains("bin/msw") else {
            throw ToolchainInstallerError.invalidManifest
        }
        let executable = payloadRoot.appendingPathComponent("bin/msw")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ToolchainInstallerError.invalidPermissions("bin/msw")
        }
        return ValidatedToolchain(manifest: manifest, executable: executable)
    }

    static func verifyHandshake(_ toolchain: ValidatedToolchain) throws {
        let process = Process()
        process.executableURL = toolchain.executable
        process.arguments = ["app", "handshake", "--format", "json"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let temporaryHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("MSWMonitor-Handshake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryHome) }
        process.environment = [
            "HOME": temporaryHome.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LC_ALL": "C",
            "LANG": "C",
            "NO_COLOR": "1"
        ]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw ToolchainInstallerError.handshakeFailed
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationReason == .exit, process.terminationStatus == 0,
              data.count <= 256 * 1_024,
              let envelope = try? MSWProtocolDecoder.decodeStrictHandshake(data),
              let handshake = envelope.result,
              handshake.protocolVersion == 1,
              handshake.mswVersion == toolchain.manifest.version,
              handshake.capabilities.isComplete else {
            throw ToolchainInstallerError.handshakeFailed
        }
    }

    private static func readRegularFile(_ url: URL, maximumBytes: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [
            .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size >= 0,
              size <= maximumBytes else {
            throw ToolchainInstallerError.unsafeArtifact(url.lastPathComponent)
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else {
            return false
        }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }
}

actor ToolchainInstaller {
    private let bundledRoot: URL
    private let installationRoot: URL

    init(bundledRoot: URL, installationRoot: URL) {
        self.bundledRoot = bundledRoot.standardizedFileURL
        self.installationRoot = installationRoot.standardizedFileURL
    }

    func activate() throws -> ToolchainInstallResult {
        let bundled = try ToolchainValidator.validateBundled(root: bundledRoot)
        try ToolchainValidator.verifyHandshake(bundled)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: installationRoot, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: installationRoot.path)

        let staging = installationRoot.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        let current = installationRoot.appendingPathComponent("current", isDirectory: true)
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            for artifact in bundled.manifest.artifacts {
                let source = bundledRoot
                    .appendingPathComponent(ToolchainLayout.payloadDirectoryName, isDirectory: true)
                    .appendingPathComponent(artifact.path)
                let destination = staging.appendingPathComponent(artifact.path)
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let data = try Data(contentsOf: source, options: [.mappedIfSafe])
                try data.write(to: destination, options: .withoutOverwriting)
                try fileManager.setAttributes(
                    [.posixPermissions: artifact.executable ? 0o755 : 0o644],
                    ofItemAtPath: destination.path
                )
            }
            let manifestData = try Data(contentsOf: bundledRoot.appendingPathComponent(ToolchainLayout.manifestName))
            let stagedManifest = staging.appendingPathComponent(ToolchainLayout.manifestName)
            try manifestData.write(to: stagedManifest, options: .withoutOverwriting)
            try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: stagedManifest.path)
            let staged = try ToolchainValidator.validateActivated(root: staging)
            try ToolchainValidator.verifyHandshake(staged)

            if fileManager.fileExists(atPath: current.path) {
                guard renameatx_np(AT_FDCWD, staging.path, AT_FDCWD, current.path, UInt32(RENAME_SWAP)) == 0 else {
                    throw ToolchainInstallerError.installFailed
                }
                try fileManager.removeItem(at: staging)
            } else {
                guard Darwin.rename(staging.path, current.path) == 0 else {
                    throw ToolchainInstallerError.installFailed
                }
            }
            try removeNonCurrentEntries(except: current)
            let activated = try ToolchainValidator.validateActivated(root: current)
            try ToolchainValidator.verifyHandshake(activated)
            return ToolchainInstallResult(
                version: activated.manifest.version,
                root: current,
                installedArtifacts: activated.manifest.artifacts.map(\.path)
            )
        } catch let error as ToolchainInstallerError {
            try? fileManager.removeItem(at: staging)
            throw error
        } catch {
            try? fileManager.removeItem(at: staging)
            throw ToolchainInstallerError.installFailed
        }
    }

    private func removeNonCurrentEntries(except current: URL) throws {
        for entry in try FileManager.default.contentsOfDirectory(
            at: installationRoot,
            includingPropertiesForKeys: nil,
            options: []
        ) where entry.standardizedFileURL != current.standardizedFileURL {
            try FileManager.default.removeItem(at: entry)
        }
    }
}

private extension SHA256.Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
