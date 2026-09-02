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
            return "The bundled Silo payload is unavailable."
        case .invalidManifest:
            return "The bundled Silo manifest is invalid."
        case .checksumMismatch(let artifact):
            return "The bundled Silo checksum did not match for \(artifact)."
        case .unsafeArtifact(let artifact):
            return "The bundled Silo artifact is missing or unsafe: \(artifact)."
        case .invalidPermissions(let artifact):
            return "The bundled Silo artifact has invalid permissions: \(artifact)."
        case .handshakeFailed:
            return "The bundled Silo command failed its version handshake."
        case .installFailed:
            return "The bundled Silo payload could not be activated atomically."
        }
    }
}

enum ToolchainLayout {
    static let bundledDirectoryName = "SiloToolchain"
    static let manifestName = "manifest.json"
    static let payloadDirectoryName = "payload"
    static let requiredArtifacts: [String: Bool] = [
        "VERSION": false,
        "MANIFEST.txt": false,
        "config.sh": true,
        "bin/silo": true,
        "bin/silo-git-askpass": true,
        "bin/silo-github-host-token": true,
        "bin/silo-github-proxy": true,
        "bin/silo-keychain-bridge": true,
        "bin/silo-ssh-proxy": true,
        "launchd/org.silo.Silo.github-proxy.plist": false,
        "lib/bootstrap-base.sh": true,
        "lib/silo-github-relay.py": true,
        "lib/silo-github-shuttle.py": true,
        "lib/silo-port-forwarder.py": true,
        "lib/proxy-upstream.py": true,
        "lib/proxycore.py": true,
        "lib/vendor/h11/LICENSE.txt": false,
        "lib/vendor/h11/__init__.py": false,
        "lib/vendor/h11/_abnf.py": false,
        "lib/vendor/h11/_connection.py": false,
        "lib/vendor/h11/_events.py": false,
        "lib/vendor/h11/_headers.py": false,
        "lib/vendor/h11/_readers.py": false,
        "lib/vendor/h11/_receivebuffer.py": false,
        "lib/vendor/h11/_state.py": false,
        "lib/vendor/h11/_util.py": false,
        "lib/vendor/h11/_version.py": false,
        "lib/vendor/h11/_writers.py": false,
        "lib/vendor/h11/py.typed": false
    ]

    static func bundledRoot(in bundle: Bundle = .main) -> URL? {
        bundle.resourceURL?.appendingPathComponent(bundledDirectoryName, isDirectory: true)
    }

    static func managedRoot(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory.appendingPathComponent(
            "Library/Application Support/Silo/Toolchain",
            isDirectory: true
        )
    }
}

enum DefaultSiloConfigurationError: Error, LocalizedError, Sendable, Equatable {
    case sourceUnavailable
    case existingConfigurationInvalid
    case installationFailed

    var errorDescription: String? {
        switch self {
        case .sourceUnavailable:
            return "The bundled default Silo configuration is unavailable."
        case .existingConfigurationInvalid:
            return "The existing Silo configuration is not a safe regular file."
        case .installationFailed:
            return "The default Silo configuration could not be installed."
        }
    }
}

enum DefaultSiloConfigurationInstaller {
    static func installIfNeeded(source: URL, homeDirectory: URL) throws -> URL {
        let fileManager = FileManager.default
        let configurationDirectory = homeDirectory.appending(
            path: ".config/silo",
            directoryHint: .isDirectory
        )
        let destination = configurationDirectory.appending(
            path: "config.sh",
            directoryHint: .notDirectory
        )
        if fileManager.fileExists(atPath: destination.path) {
            guard isValidConfiguration(at: destination) else {
                throw DefaultSiloConfigurationError.existingConfigurationInvalid
            }
            return destination
        }
        guard isValidConfiguration(at: source) else {
            throw DefaultSiloConfigurationError.sourceUnavailable
        }

        do {
            try fileManager.createDirectory(
                at: configurationDirectory,
                withIntermediateDirectories: true
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: configurationDirectory.path
            )
            let data = try Data(contentsOf: source)
            let temporary = configurationDirectory.appending(
                path: ".config-\(UUID().uuidString)",
                directoryHint: .notDirectory
            )
            defer { try? fileManager.removeItem(at: temporary) }
            try data.write(to: temporary, options: .withoutOverwriting)
            try fileManager.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: temporary.path
            )
            do {
                try fileManager.moveItem(at: temporary, to: destination)
            } catch {
                guard fileManager.fileExists(atPath: destination.path),
                      isValidConfiguration(at: destination) else {
                    throw error
                }
            }
            guard isValidConfiguration(at: destination) else {
                throw DefaultSiloConfigurationError.installationFailed
            }
            return destination
        } catch let error as DefaultSiloConfigurationError {
            throw error
        } catch {
            throw DefaultSiloConfigurationError.installationFailed
        }
    }

    static func isValidConfiguration(at url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey
        ]), values.isRegularFile == true,
            values.isSymbolicLink != true,
            let fileSize = values.fileSize,
            fileSize <= 64 * 1024 else {
            return false
        }
        return true
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
            payloadRoot: root.appendingPathComponent(ToolchainLayout.payloadDirectoryName, isDirectory: true),
            manifestInsidePayload: false
        )
    }

    static func validateActivated(root: URL) throws -> ValidatedToolchain {
        try validate(
            manifestURL: root.appendingPathComponent(ToolchainLayout.manifestName),
            payloadRoot: root,
            manifestInsidePayload: true
        )
    }

    private static func validate(
        manifestURL: URL,
        payloadRoot: URL,
        manifestInsidePayload: Bool
    ) throws -> ValidatedToolchain {
        try validateDirectory(manifestURL.deletingLastPathComponent())
        if payloadRoot.standardizedFileURL != manifestURL.deletingLastPathComponent().standardizedFileURL {
            try validateDirectory(payloadRoot)
        }
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
        try validatePayloadEntries(at: payloadRoot, manifestInsidePayload: manifestInsidePayload)

        var declaredArtifacts: [String: Bool] = [:]
        for artifact in manifest.artifacts {
            guard isSafeRelativePath(artifact.path),
                  declaredArtifacts.updateValue(artifact.executable, forKey: artifact.path) == nil,
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
        guard declaredArtifacts == ToolchainLayout.requiredArtifacts else {
            throw ToolchainInstallerError.invalidManifest
        }
        let versionURL = payloadRoot.appendingPathComponent("VERSION")
        let versionData = try readRegularFile(versionURL, maximumBytes: 128)
        guard String(decoding: versionData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines) == manifest.version else {
            throw ToolchainInstallerError.invalidManifest
        }
        let executable = payloadRoot.appendingPathComponent("bin/silo")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ToolchainInstallerError.invalidPermissions("bin/silo")
        }
        return ValidatedToolchain(manifest: manifest, executable: executable)
    }

    static func verifyHandshake(_ toolchain: ValidatedToolchain) throws {
        let process = Process()
        process.executableURL = toolchain.executable
        process.arguments = ["app", "handshake", "--format", "json"]
        let temporaryHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("Silo-Handshake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryHome) }
        let outputURL = temporaryHome.appendingPathComponent("stdout.json")
        guard FileManager.default.createFile(
            atPath: outputURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ), let output = try? FileHandle(forWritingTo: outputURL) else {
            throw ToolchainInstallerError.handshakeFailed
        }
        defer { try? output.close() }
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.environment = [
            "HOME": temporaryHome.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LC_ALL": "C",
            "LANG": "C",
            "NO_COLOR": "1"
        ]
        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        do {
            try process.run()
        } catch {
            throw ToolchainInstallerError.handshakeFailed
        }
        guard terminated.wait(timeout: .now() + .seconds(5)) == .success else {
            Darwin.kill(process.processIdentifier, SIGTERM)
            if terminated.wait(timeout: .now() + .milliseconds(250)) == .timedOut {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = terminated.wait(timeout: .now() + .seconds(1))
            }
            throw ToolchainInstallerError.handshakeFailed
        }
        try? output.close()
        let data: Data
        do {
            data = try readRegularFile(outputURL, maximumBytes: 256 * 1_024)
        } catch {
            throw ToolchainInstallerError.handshakeFailed
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0,
              let envelope = try? SiloProtocolDecoder.decodeStrictHandshake(data),
              let handshake = envelope.result,
              handshake.protocolVersion == 1,
              handshake.siloVersion == toolchain.manifest.version,
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

    private static func validateDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let permissions = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber)?.intValue ?? -1
        guard values.isDirectory == true,
              values.isSymbolicLink != true,
              permissions & 0o777 == 0o755 else {
            throw ToolchainInstallerError.invalidPermissions(url.lastPathComponent)
        }
    }

    private static func validatePayloadEntries(
        at payloadRoot: URL,
        manifestInsidePayload: Bool
    ) throws {
        let expectedFiles = Set(ToolchainLayout.requiredArtifacts.keys)
        let expectedDirectories = Set(expectedFiles.flatMap { path -> [String] in
            let components = path.split(separator: "/").dropLast()
            return components.indices.map { index in
                components[...index].joined(separator: "/")
            }
        })
        guard let enumerator = FileManager.default.enumerator(
            at: payloadRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [],
            errorHandler: { _, _ in false }
        ) else {
            throw ToolchainInstallerError.bundledPayloadUnavailable
        }

        var files = Set<String>()
        var directories = Set<String>()
        let canonicalRoot = payloadRoot.resolvingSymlinksInPath()
        let prefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey
            ])
            guard values.isSymbolicLink != true else {
                throw ToolchainInstallerError.unsafeArtifact(url.lastPathComponent)
            }
            let canonicalURL = url.resolvingSymlinksInPath()
            guard canonicalURL.path.hasPrefix(prefix) else {
                throw ToolchainInstallerError.unsafeArtifact(url.lastPathComponent)
            }
            let relative = String(canonicalURL.path.dropFirst(prefix.count))
            if manifestInsidePayload, relative == ToolchainLayout.manifestName {
                continue
            }
            if values.isDirectory == true {
                directories.insert(relative)
            } else if values.isRegularFile == true {
                files.insert(relative)
            } else {
                throw ToolchainInstallerError.unsafeArtifact(relative)
            }
        }
        guard files == expectedFiles, directories == expectedDirectories else {
            throw ToolchainInstallerError.invalidManifest
        }
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
        let installationValues = try installationRoot.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey
        ])
        guard installationValues.isDirectory == true,
              installationValues.isSymbolicLink != true else {
            throw ToolchainInstallerError.installFailed
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: installationRoot.path)

        let staging = installationRoot.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        let current = installationRoot.appendingPathComponent("current", isDirectory: true)
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path)
            for artifact in bundled.manifest.artifacts {
                let source = bundledRoot
                    .appendingPathComponent(ToolchainLayout.payloadDirectoryName, isDirectory: true)
                    .appendingPathComponent(artifact.path)
                let destination = staging.appendingPathComponent(artifact.path)
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                var directory = destination.deletingLastPathComponent()
                while directory.standardizedFileURL != staging.standardizedFileURL {
                    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
                    directory.deleteLastPathComponent()
                }
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

}

private extension SHA256.Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
