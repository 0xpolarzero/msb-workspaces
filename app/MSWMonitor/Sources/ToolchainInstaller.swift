import CryptoKit
import Darwin
import Foundation
import Security

struct ToolchainManifest: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let version: String
    let architecture: String
    let artifacts: [Artifact]
    let signature: String?

    struct Artifact: Codable, Sendable, Equatable, Identifiable {
        let id: String
        let source: URL
        let destination: String
        let sha256: String
        let executable: Bool
        let architecture: String?
        let codeSigningRequirement: String?

        init(
            id: String,
            source: URL,
            destination: String,
            sha256: String,
            executable: Bool,
            architecture: String? = nil,
            codeSigningRequirement: String? = nil
        ) {
            self.id = id
            self.source = source
            self.destination = destination
            self.sha256 = sha256
            self.executable = executable
            self.architecture = architecture
            self.codeSigningRequirement = codeSigningRequirement
        }
    }
}

struct ToolchainInstallResult: Sendable, Equatable {
    let version: String
    let root: URL
    let installedArtifacts: [String]
}

enum ToolchainInstallerError: Error, LocalizedError, Sendable, Equatable {
    case invalidManifest
    case unsupportedArchitecture
    case invalidSignature
    case checksumMismatch(String)
    case unsafeDestination(String)
    case invalidArtifactSource(String)
    case downloadFailed(String)
    case installFailed

    var errorDescription: String? {
        switch self {
        case .invalidManifest: return "The MSW toolchain manifest is invalid."
        case .unsupportedArchitecture: return "The selected MSW toolchain is not built for Apple Silicon."
        case .invalidSignature: return "The MSW toolchain manifest signature is invalid."
        case .checksumMismatch(let artifact): return "The MSW toolchain checksum did not match for \(artifact)."
        case .unsafeDestination(let path): return "The MSW toolchain contains an unsafe destination path: \(path)."
        case .invalidArtifactSource(let artifact): return "The MSW toolchain source is invalid for \(artifact)."
        case .downloadFailed(let artifact): return "The MSW toolchain artifact could not be downloaded: \(artifact)."
        case .installFailed: return "The MSW toolchain could not be installed atomically."
        }
    }
}

actor ToolchainInstaller {
    private static let maxTransferBytes = 2 * 1024 * 1024 * 1024

    private let installationRoot: URL
    private let sourceRoot: URL?
    private let trustedManifestKey: Curve25519.Signing.PublicKey?
    private let session: URLSession
    private let allowNetworkSources: Bool
    private let allowExternalFileSources: Bool

    init(
        installationRoot: URL,
        sourceRoot: URL? = nil,
        trustedManifestPublicKey: Data? = nil,
        session: URLSession = .shared,
        allowNetworkSources: Bool = false,
        allowExternalFileSources: Bool = true
    ) throws {
        self.installationRoot = installationRoot
        self.sourceRoot = sourceRoot?.standardizedFileURL
        self.session = session
        self.allowNetworkSources = allowNetworkSources
        self.allowExternalFileSources = allowExternalFileSources
        if let trustedManifestPublicKey {
            self.trustedManifestKey = try Curve25519.Signing.PublicKey(rawRepresentation: trustedManifestPublicKey)
        } else {
            self.trustedManifestKey = nil
        }
    }

    func install(manifestData: Data) async throws -> ToolchainInstallResult {
        let manifest = try decodeManifest(manifestData)
        guard manifest.schemaVersion == 1,
              !manifest.version.isEmpty,
              isSafeVersion(manifest.version),
              !manifest.artifacts.isEmpty else {
            throw ToolchainInstallerError.invalidManifest
        }
        guard manifest.architecture == "arm64" else {
            throw ToolchainInstallerError.unsupportedArchitecture
        }
        guard let trustedManifestKey else { throw ToolchainInstallerError.invalidSignature }
        guard let signature = manifest.signature,
              let signatureData = Data(base64Encoded: signature) else {
            throw ToolchainInstallerError.invalidSignature
        }
        let unsigned = try Self.canonicalEncoder().encode(UnsignedManifest(
            schemaVersion: manifest.schemaVersion,
            version: manifest.version,
            architecture: manifest.architecture,
            artifacts: manifest.artifacts
        ))
        guard trustedManifestKey.isValidSignature(signatureData, for: unsigned) else {
            throw ToolchainInstallerError.invalidSignature
        }

        var seenArtifactIDs = Set<String>()
        var seenDestinations = Set<String>()
        guard manifest.artifacts.allSatisfy({ artifact in
            !artifact.id.isEmpty &&
                seenArtifactIDs.insert(artifact.id).inserted &&
                seenDestinations.insert(artifact.destination).inserted
        }) else {
            throw ToolchainInstallerError.invalidManifest
        }

        let versionRoot = installationRoot.appendingPathComponent(manifest.version, isDirectory: true)
        let stagingRoot = installationRoot.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
            var installed: [String] = []
            for artifact in manifest.artifacts {
                guard isSafeRelativePath(artifact.destination) else {
                    throw ToolchainInstallerError.unsafeDestination(artifact.destination)
                }
                guard let source = resolvedSource(for: artifact.source) else {
                    throw ToolchainInstallerError.invalidArtifactSource(artifact.id)
                }
                let artifactData = try await loadArtifactData(from: source, artifactID: artifact.id)
                let digest = SHA256.hash(data: artifactData).hexString
                guard digest.caseInsensitiveCompare(artifact.sha256) == .orderedSame else {
                    throw ToolchainInstallerError.checksumMismatch(artifact.id)
                }
                let destination = stagingRoot.appendingPathComponent(artifact.destination)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try artifactData.write(to: destination, options: .withoutOverwriting)
                try FileManager.default.setAttributes(
                    [.posixPermissions: artifact.executable ? 0o755 : 0o644],
                    ofItemAtPath: destination.path
                )
                if let architecture = artifact.architecture {
                    guard architecture == "arm64", try verifyArchitecture(of: destination) else {
                        throw ToolchainInstallerError.unsupportedArchitecture
                    }
                }
                if let requirement = artifact.codeSigningRequirement {
                    guard artifact.executable, verifyCodeSignature(of: destination, requirement: requirement) else {
                        throw ToolchainInstallerError.invalidSignature
                    }
                }
                installed.append(artifact.id)
            }
            try FileManager.default.createDirectory(at: installationRoot, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: versionRoot.path) {
                _ = try FileManager.default.replaceItemAt(
                    versionRoot,
                    withItemAt: stagingRoot,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly]
                )
            } else {
                try FileManager.default.moveItem(at: stagingRoot, to: versionRoot)
            }
            try activate(version: manifest.version)
            return ToolchainInstallResult(version: manifest.version, root: versionRoot, installedArtifacts: installed)
        } catch let error as ToolchainInstallerError {
            try? FileManager.default.removeItem(at: stagingRoot)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: stagingRoot)
            throw ToolchainInstallerError.installFailed
        }
    }

    private func decodeManifest(_ data: Data) throws -> ToolchainManifest {
        do { return try JSONDecoder().decode(ToolchainManifest.self, from: data) }
        catch { throw ToolchainInstallerError.invalidManifest }
    }

    private func loadArtifactData(from source: URL, artifactID: String) async throws -> Data {
        if source.isFileURL {
            guard let values = try? source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let fileSize = values.fileSize,
                  fileSize >= 0,
                  fileSize <= Self.maxTransferBytes else {
                throw ToolchainInstallerError.installFailed
            }
            do {
                return try Data(contentsOf: source)
            } catch {
                throw ToolchainInstallerError.installFailed
            }
        }

        var request = URLRequest(
            url: source,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 300
        )
        request.setValue("MSW-Monitor-Toolchain/1", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  response.url?.scheme?.lowercased() == "https",
                  data.count <= Self.maxTransferBytes else {
                throw ToolchainInstallerError.downloadFailed(artifactID)
            }
            return data
        } catch let error as ToolchainInstallerError {
            throw error
        } catch {
            throw ToolchainInstallerError.downloadFailed(artifactID)
        }
    }

    private func isSafeVersion(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._+-]*$"#, options: .regularExpression) != nil
    }

    private func activate(version: String) throws {
        let stable = installationRoot.appendingPathComponent("current")
        let temporary = installationRoot.appendingPathComponent(".current-\(UUID().uuidString)")
        do {
            try FileManager.default.createSymbolicLink(atPath: temporary.path, withDestinationPath: version)
            guard Darwin.rename(temporary.path, stable.path) == 0 else {
                throw ToolchainInstallerError.installFailed
            }
        } catch let error as ToolchainInstallerError {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw ToolchainInstallerError.installFailed
        }
    }

    private func resolvedSource(for source: URL) -> URL? {
        if source.isFileURL {
            if !allowExternalFileSources {
                guard let sourceRoot, isDescendant(source, of: sourceRoot) else { return nil }
            }
            return source
        }
        if source.scheme?.lowercased() == "https" {
            guard allowNetworkSources,
                  source.host != nil,
                  source.user == nil,
                  source.password == nil,
                  source.fragment == nil else { return nil }
            return source
        }
        guard source.scheme == nil,
              let sourceRoot,
              isSafeRelativePath(source.path) else { return nil }
        return sourceRoot.appendingPathComponent(source.path, isDirectory: false)
    }

    private func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : "\(rootPath)/")
    }

    private func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.contains("\0") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    private func verifyArchitecture(of executable: URL) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lipo")
        process.arguments = ["-archs", executable.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw ToolchainInstallerError.unsupportedArchitecture
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return false }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard data.count <= 4_096 else { return false }
        let architectures = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        return architectures == ["arm64"]
    }

    private func verifyCodeSignature(of executable: URL, requirement: String) -> Bool {
        guard !requirement.isEmpty else { return false }
        var staticCode: SecStaticCode?
        var securityRequirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode,
              SecRequirementCreateWithString(requirement as CFString, [], &securityRequirement) == errSecSuccess,
              let securityRequirement else {
            return false
        }
        return SecStaticCodeCheckValidity(staticCode, [], securityRequirement) == errSecSuccess
    }

    private struct UnsignedManifest: Codable {
        let schemaVersion: Int
        let version: String
        let architecture: String
        let artifacts: [ToolchainManifest.Artifact]
    }

    private static func canonicalEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

private extension SHA256.Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
