import Foundation
import Security
import ServiceManagement

struct MSWPreflightCheck: Codable, Identifiable, Sendable, Equatable {
    enum Status: String, Codable, Sendable { case pass, needsAction, unavailable }
    let id: String
    let title: String
    let status: Status
    let detail: String
    let remediation: String?
}

struct MSWBootstrapState: Codable, Sendable, Equatable {
    enum Phase: String, Codable, Sendable, CaseIterable {
        case welcome
        case preflight
        case toolchain
        case hostIntegration
        case workspaces
        case github
        case identity
        case complete
    }

    var phase: Phase
    var startedAt: Date?
    var updatedAt: Date
    var lastError: String?
    var completedPhases: Set<Phase>

    static var initial: Self {
        Self(phase: .welcome, startedAt: nil, updatedAt: Date(), lastError: nil, completedPhases: [])
    }
}
enum BootstrapCoordinatorError: Error, LocalizedError, Sendable, Equatable {
    case busy
    case preflightBlocked
    case unavailable
    case toolchainUnavailable
    case configurationUnavailable
    case configurationInstallationFailed(String)
    case toolchainInstallationFailed(String)
    case hostRegistrationFailed(String)

    var errorDescription: String? {
        switch self {
        case .busy: return "Setup is already running."
        case .preflightBlocked: return "Setup cannot continue until required preflight checks pass."
        case .unavailable: return "Setup is unavailable until the MSW runtime is installed."
        case .toolchainUnavailable:
            return "The MSW runtime is not bundled with this build, and the source setup installer could not be found."
        case .configurationUnavailable: return "The default MSW configuration is not included in this app build."
        case .configurationInstallationFailed(let detail): return "The MSW configuration could not be installed: \(detail)"
        case .toolchainInstallationFailed(let detail): return "MSW runtime setup failed: \(detail)"
        case .hostRegistrationFailed(let detail): return "Host integration could not be completed: \(detail)"
        }
    }
}
enum MSWHostServiceStatus: String, Sendable {
    case enabled
    case requiresApproval
    case notRegistered
    case notFound
    case unknown
}

enum MSWHostServicePackagingStatus: Sendable, Equatable {
    case ready
    case missingPropertyList
    case invalidPropertyList
    case missingExecutable
    case signingUnavailable

    var detail: String {
        switch self {
        case .ready:
            return "The bundled host helper is packaged and signed for registration."
        case .missingPropertyList:
            return "The app bundle does not contain the host helper registration file."
        case .invalidPropertyList:
            return "The bundled host helper registration file does not match the expected service."
        case .missingExecutable:
            return "The app bundle does not contain the executable host helper."
        case .signingUnavailable:
            return "This app build is not signed with an Apple team identity. Host integration requires a signed MSW Monitor build."
        }
    }

    var remediation: String {
        switch self {
        case .ready:
            return ""
        case .signingUnavailable:
            return "Install a signed MSW Monitor build from the project team."
        case .missingPropertyList, .invalidPropertyList, .missingExecutable:
            return "Reinstall a complete, signed copy of MSW Monitor."
        }
    }
}

@MainActor
protocol MSWHostServiceControlling: AnyObject, Sendable {
    var status: MSWHostServiceStatus { get }
    var packagingStatus: MSWHostServicePackagingStatus { get }
    func registerIfNeeded() throws -> MSWHostServiceStatus
    func openApprovalSettings()
}

extension MSWHostServiceControlling {
    var packagingStatus: MSWHostServicePackagingStatus { .ready }
}


@MainActor
final class MSWHostServiceController: MSWHostServiceControlling {
    static let plistName = "org.microsandbox.MSWMonitor.host-agent.plist"
    static let serviceName = "org.microsandbox.MSWMonitor.host-agent"
    static let executablePath = "Contents/Resources/MSWHostAgent"

    private let service: SMAppService

    init() {
        service = SMAppService.daemon(plistName: Self.plistName)
    }

    var status: MSWHostServiceStatus {
        switch service.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        @unknown default: return .unknown
        }
    }

    var packagingStatus: MSWHostServicePackagingStatus {
        Self.inspectPackaging(bundleURL: Bundle.main.bundleURL)
    }

    func registerIfNeeded() throws -> MSWHostServiceStatus {
        guard packagingStatus == .ready else {
            throw BootstrapCoordinatorError.hostRegistrationFailed(packagingStatus.detail)
        }
        switch status {
        case .enabled, .requiresApproval, .notFound, .unknown:
            return status
        case .notRegistered:
            try service.register()
            return status
        }
    }

    func unregister() throws {
        guard status != .notRegistered else { return }
        try service.unregister()
    }

    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    static func inspectPackaging(bundleURL: URL) -> MSWHostServicePackagingStatus {
        let propertyListURL = bundleURL
            .appending(path: "Contents/Library/LaunchDaemons", directoryHint: .isDirectory)
            .appending(path: plistName)
        guard let propertyListData = try? Data(contentsOf: propertyListURL) else {
            return .missingPropertyList
        }
        guard let propertyList = try? PropertyListSerialization.propertyList(
            from: propertyListData,
            options: [],
            format: nil
        ) as? [String: Any],
              propertyList["Label"] as? String == serviceName,
              propertyList["BundleProgram"] as? String == executablePath,
              propertyList["UserName"] as? String == "root",
              let machServices = propertyList["MachServices"] as? [String: Any],
              machServices[serviceName] as? Bool == true else {
            return .invalidPropertyList
        }

        let executableURL = bundleURL.appending(path: executablePath)
        guard let values = try? executableURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .isExecutableKey
        ]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              values.isExecutable == true else {
            return .missingExecutable
        }

        guard let appTeam = teamIdentifier(for: bundleURL),
              let helperTeam = teamIdentifier(for: executableURL),
              appTeam == helperTeam else {
            return .signingUnavailable
        }
        return .ready
    }

    private static func teamIdentifier(for url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode,
              SecStaticCodeCheckValidity(staticCode, [], nil) == errSecSuccess else {
            return nil
        }
        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &signingInformation) == errSecSuccess,
              let information = signingInformation as? [String: Any],
              let teamIdentifier = information[kSecCodeInfoTeamIdentifier as String] as? String,
              teamIdentifier.range(
                of: #"^[A-Z0-9]{10}$"#,
                options: String.CompareOptions.regularExpression
              ) != nil else {
            return nil
        }
        return teamIdentifier
    }
}

actor BootstrapStateStore {
    private let url: URL
    private var value: MSWBootstrapState

    init(url: URL? = nil) {
        let defaultDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?.appendingPathComponent("MSW Monitor", isDirectory: true)
        let fallbackDirectory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support/MSW Monitor", isDirectory: true)
        self.url = url ?? (defaultDirectory ?? fallbackDirectory).appendingPathComponent("bootstrap-state.json")
        if FileManager.default.fileExists(atPath: self.url.path) {
            do { value = try JSONDecoder().decode(MSWBootstrapState.self, from: Data(contentsOf: self.url)) }
            catch { value = .initial }
        } else {
            value = .initial
        }
    }

    func load() -> MSWBootstrapState { value }

    func save(_ state: MSWBootstrapState) throws {
        value = state
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let data = try JSONEncoder().encode(state)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
protocol MSWBootstrapCoordinating: AnyObject, Sendable {
    func state() async -> MSWBootstrapState
    func preflight() async -> [MSWPreflightCheck]
    func run() async throws -> MSWBootstrapResult
    func openHostApprovalSettings() async
}

actor BootstrapCoordinator: MSWBootstrapCoordinating {
    private let client: MSWClient
    private let runner: MSWCommandRunner
    private let stateStore: BootstrapStateStore
    private let hostAgent: any MSWHostAgentControlling
    private let hostService: any MSWHostServiceControlling
    private let sourceSetup: any MSWSourceSetupControlling
    private let hostRepairVerifier: any MSWHostRepairVerifying
    private let hostRepairAuthorization: any MSWHostRepairAuthorizing
    private let freeDiskBytes: @Sendable () -> Int64?
    private var running = false
    init(
        client: MSWClient,
        runner: MSWCommandRunner,
        stateStore: BootstrapStateStore = BootstrapStateStore(),
        hostAgent: any MSWHostAgentControlling = HostAgentClient(),
        hostService: any MSWHostServiceControlling,
        sourceSetup: (any MSWSourceSetupControlling)? = nil,
        hostRepairVerifier: (any MSWHostRepairVerifying)? = nil,
        hostRepairAuthorization: (any MSWHostRepairAuthorizing)? = nil,
        freeDiskBytes: @escaping @Sendable () -> Int64? = {
            let attributes = try? FileManager.default
                .attributesOfFileSystem(forPath: NSHomeDirectory())
            return (attributes?[.systemFreeSize] as? NSNumber)?.int64Value
        }
    ) {
        self.client = client
        self.runner = runner
        self.stateStore = stateStore
        self.hostAgent = hostAgent
        self.hostService = hostService
        self.sourceSetup = sourceSetup ?? MSWSourceSetupService(runner: runner)
        self.hostRepairVerifier = hostRepairVerifier ?? MSWHostRepairVerifier(runner: runner)
        self.hostRepairAuthorization = hostRepairAuthorization ?? MSWHostRepairAuthorization(runner: runner)
        self.freeDiskBytes = freeDiskBytes
    }

    func state() async -> MSWBootstrapState { await stateStore.load() }

    func hostServiceStatus() async -> MSWHostServiceStatus {
        await hostService.status
    }

    func openHostApprovalSettings() async {
        await hostService.openApprovalSettings()
    }


    func preflight() async -> [MSWPreflightCheck] {
        var checks: [MSWPreflightCheck] = []
        let osMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        checks.append(MSWPreflightCheck(
            id: "macos-version",
            title: "macOS 26 or later",
            status: osMajor >= 26 ? .pass : .needsAction,
            detail: "Detected macOS \(osMajor).",
            remediation: osMajor >= 26 ? nil : "Update macOS before installing MSW Monitor."
        ))
        let architecture = await commandOutput(executable: URL(fileURLWithPath: "/usr/bin/uname"), arguments: ["-m"])
        let isArm64 = architecture?.trimmingCharacters(in: .whitespacesAndNewlines) == "arm64"
        checks.append(MSWPreflightCheck(
            id: "architecture",
            title: "Apple Silicon",
            status: architecture == nil ? .unavailable : (isArm64 ? .pass : .needsAction),
            detail: architecture.map { "Detected \($0.trimmingCharacters(in: .whitespacesAndNewlines))." } ?? "Architecture could not be detected.",
            remediation: isArm64 ? nil : "MSW Monitor requires an arm64 Mac."
        ))
        let freeBytes = freeDiskBytes()
        let diskPass = (freeBytes ?? 0) >= 20 * 1_024 * 1_024 * 1_024
        checks.append(MSWPreflightCheck(
            id: "disk-space",
            title: "Available disk space",
            status: freeBytes == nil ? .unavailable : (diskPass ? .pass : .needsAction),
            detail: freeBytes.map { "\($0 / (1_024 * 1_024 * 1_024)) GiB available; setup estimates at least 20 GiB." } ?? "Disk space could not be measured.",
            remediation: diskPass ? nil : "Free at least 20 GiB before continuing."
        ))
        let memoryGiB = ProcessInfo.processInfo.physicalMemory / (1_024 * 1_024 * 1_024)
        checks.append(MSWPreflightCheck(
            id: "memory",
            title: "Memory budget",
            status: memoryGiB >= 16 ? .pass : .needsAction,
            detail: "Detected \(memoryGiB) GiB physical memory.",
            remediation: memoryGiB >= 16 ? nil : "At least 16 GiB is recommended for all three workspaces."
        ))
        for name in ["git", "tar", "zstd", "git-lfs", "msb"] {
            let resolved = await runner.resolveExecutable(named: name)
            let available = resolved != nil
            checks.append(MSWPreflightCheck(
                id: "tool-\(name)",
                title: name,
                status: available ? .pass : .needsAction,
                detail: resolved.map { "\($0.path) is executable." } ?? "\(name) was not found in an app-managed or supported system location.",
                remediation: available ? nil : "Install or select \(name) in MSW Monitor setup."
            ))
        }
        let mswResolution = await runner.mswResolution(forceRefresh: true)
        let canInstallToolchain = bundledToolchainConfigurationAvailable || sourceSetup.isAvailable
        let repairRuntimeAction = bundledToolchainConfigurationAvailable
            ? "Choose Repair & Continue to install the signed MSW toolchain."
            : "Choose Repair & Continue to run the local MSW setup installer."
        if mswResolution.selected == nil, !mswResolution.hasInstalledExecutable {
            checks.append(MSWPreflightCheck(
                id: "msw-runtime",
                title: "MSW runtime",
                status: canInstallToolchain ? .needsAction : .unavailable,
                detail: canInstallToolchain
                    ? "MSW is not installed yet. Repair & Continue will install it and verify the runtime."
                    : "No compatible MSW runtime is installed, and this build has no runtime installer.",
                remediation: canInstallToolchain
                    ? repairRuntimeAction
                    : "Use an MSW Monitor build that bundles the runtime, or launch this app from the source checkout."
            ))
        } else if mswResolution.selected == nil {
            checks.append(MSWPreflightCheck(
                id: "msw-runtime",
                title: "MSW runtime",
                status: canInstallToolchain ? .needsAction : .unavailable,
                detail: canInstallToolchain
                    ? "The installed MSW command is from an older release and does not support MSW Monitor."
                    : "The installed MSW command is incompatible, and this build has no runtime installer.",
                remediation: canInstallToolchain
                    ? "Choose Repair & Continue to replace it with a protocol-compatible runtime."
                    : "Use an MSW Monitor build with a compatible runtime, or repair the MSW source checkout."
            ))
        } else {
            do {
                let envelope = try await client.handshake()
                guard let handshake = envelope.result else {
                    throw MSWClientError.missingResult(command: "handshake")
                }
                let ready = handshake.configurationAvailable && handshake.runtimeAvailable && handshake.capabilities.jq
                checks.append(MSWPreflightCheck(
                    id: "msw-runtime",
                    title: "MSW runtime",
                    status: ready ? .pass : .needsAction,
                    detail: ready
                        ? (mswResolution.incompatibleCandidates.isEmpty
                            ? "MSW Monitor can communicate with the installed runtime."
                            : "MSW Monitor is using a compatible runtime and ignoring an older command found earlier.")
                        : "MSW is present, but its configuration, JSON adapter, or MicroSandbox runtime is incomplete.",
                    remediation: ready ? nil : (canInstallToolchain
                        ? repairRuntimeAction
                        : "Repair the MSW installation or use a build with a compatible runtime.")
                ))
            } catch {
                checks.append(MSWPreflightCheck(
                    id: "msw-runtime",
                    title: "MSW runtime",
                    status: .needsAction,
                    detail: "MSW Monitor could not verify the installed runtime.",
                    remediation: canInstallToolchain
                        ? repairRuntimeAction
                        : "Repair the MSW installation or use a build with a compatible runtime."
                ))
            }
        }
        let hostPackaging = await hostService.packagingStatus
        if hostPackaging == .signingUnavailable {
            let ready = await hostRepairVerifier.isReady()
            let directRepairAvailable = sourceSetup.isAvailable
            let status: MSWPreflightCheck.Status = ready
                ? .pass
                : (directRepairAvailable ? .needsAction : .unavailable)
            let detail: String
            let remediation: String?
            if ready {
                detail = "Host networking is configured for this Mac."
                remediation = nil
            } else if directRepairAvailable {
                detail = "Host networking needs one-time administrator approval on this Mac."
                remediation = "Choose Repair & Continue to configure the fixed aliases and host records."
            } else {
                detail = hostPackaging.detail
                remediation = hostPackaging.remediation
            }
            checks.append(MSWPreflightCheck(
                id: "host-integration",
                title: "Host integration",
                status: status,
                detail: detail,
                remediation: remediation
            ))
            return checks
        }
        if hostPackaging != .ready {
            checks.append(MSWPreflightCheck(
                id: "host-integration",
                title: "Host integration",
                status: .unavailable,
                detail: hostPackaging.detail,
                remediation: hostPackaging.remediation
            ))
            return checks
        }
        let hostStatus = await hostService.status
        switch hostStatus {
        case .enabled:
            do {
                let snapshot = try await hostAgent.inspect()
                let expectedAliases = MSWWorkspaceNetwork.addresses
                let ready = snapshot.fixedAliases == expectedAliases && snapshot.hostsBlockInstalled
                checks.append(MSWPreflightCheck(
                    id: "host-integration",
                    title: "Host integration",
                    status: ready ? .pass : .needsAction,
                    detail: ready ? "The fixed loopback aliases and managed host records are installed." : "The helper is enabled, but fixed loopback aliases or managed host records need repair.",
                    remediation: ready ? nil : "Continue setup to repair only the fixed MSW-owned host integration."
                ))
            } catch {
                checks.append(MSWPreflightCheck(
                    id: "host-integration",
                    title: "Host integration",
                    status: .needsAction,
                    detail: "The registered host helper is not reachable.",
                    remediation: "Restart or repair the MSW host helper, then check again."
                ))
            }
        case .notRegistered:
            checks.append(MSWPreflightCheck(
                id: "host-integration",
                title: "Host integration",
                status: .needsAction,
                detail: "The typed privileged host helper is not registered.",
                remediation: "Continue setup to register the helper and request administrator approval."
            ))
        case .requiresApproval:
            checks.append(MSWPreflightCheck(
                id: "host-integration",
                title: "Host integration",
                status: .needsAction,
                detail: "Administrator approval is required for the typed privileged host helper.",
                remediation: "Open Login Items settings and approve the MSW Monitor host helper."
            ))
        case .notFound, .unknown:
            checks.append(MSWPreflightCheck(
                id: "host-integration",
                title: "Host integration",
                status: .unavailable,
                detail: "The bundled host helper is present and signed, but macOS could not load its registration state.",
                remediation: "Choose Repair & Continue. If the problem remains, reinstall MSW Monitor."
            ))
        }
        return checks
    }
    func installToolchain(
        manifestData: Data,
        installationRoot: URL,
        trustedManifestPublicKey: Data,
        sourceRoot: URL? = nil,
        allowNetworkSources: Bool = false,
        allowExternalFileSources: Bool = true
    ) async throws -> ToolchainInstallResult {
        do {
            let installer = try ToolchainInstaller(
                installationRoot: installationRoot,
                sourceRoot: sourceRoot,
                trustedManifestPublicKey: trustedManifestPublicKey,
                allowNetworkSources: allowNetworkSources,
                allowExternalFileSources: allowExternalFileSources
            )
            let result = try await installer.install(manifestData: manifestData)
            var current = await stateStore.load()
            current.phase = .hostIntegration
            current.completedPhases.insert(.toolchain)
            current.updatedAt = Date()
            try await stateStore.save(current)
            return result
        } catch let error as BootstrapCoordinatorError {
            throw error
        } catch {
            throw BootstrapCoordinatorError.toolchainInstallationFailed(error.localizedDescription)
        }
    }

    func installBundledToolchain() async throws -> ToolchainInstallResult {
        let bundledURL = Bundle.main.url(forResource: "ToolchainManifest", withExtension: "json")
        let configuredURL = (Bundle.main.object(forInfoDictionaryKey: "MSWToolchainManifestURL") as? String)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { value -> URL? in
                guard !value.isEmpty, !value.hasPrefix("$(") else { return nil }
                return URL(string: value)
            }
        guard let manifestURL = bundledURL ?? configuredURL,
              let keyString = Bundle.main.object(forInfoDictionaryKey: "MSWToolchainManifestPublicKey") as? String,
              !keyString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !keyString.hasPrefix("$("),
              let publicKey = Data(base64Encoded: keyString),
              publicKey.count == 32 else {
            throw BootstrapCoordinatorError.toolchainUnavailable
        }
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("MSW Monitor/Toolchains", isDirectory: true)
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support/MSW Monitor/Toolchains", isDirectory: true)
        do {
            let manifestData = try await loadManifestData(from: manifestURL)
            return try await installToolchain(
                manifestData: manifestData,
                installationRoot: root,
                trustedManifestPublicKey: publicKey,
                sourceRoot: manifestURL.isFileURL ? manifestURL.deletingLastPathComponent() : nil,
                allowNetworkSources: true,
                allowExternalFileSources: false
            )
        } catch let error as BootstrapCoordinatorError {
            throw error
        } catch {
            throw BootstrapCoordinatorError.toolchainInstallationFailed(error.localizedDescription)
        }
    }

    private func loadManifestData(from url: URL) async throws -> Data {
        if url.isFileURL {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let fileSize = values.fileSize,
                  fileSize >= 0,
                  fileSize <= 16 * 1024 * 1024 else {
                throw BootstrapCoordinatorError.toolchainInstallationFailed("The signed MSW toolchain manifest could not be read.")
            }
            do {
                return try Data(contentsOf: url)
            } catch {
                throw BootstrapCoordinatorError.toolchainInstallationFailed("The signed MSW toolchain manifest could not be read.")
            }
        }
        guard url.scheme?.lowercased() == "https",
              url.host != nil,
              url.user == nil,
              url.password == nil,
              url.fragment == nil else {
            throw BootstrapCoordinatorError.toolchainUnavailable
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  response.url?.scheme?.lowercased() == "https",
                  data.count <= 16 * 1024 * 1024 else {
                throw BootstrapCoordinatorError.toolchainInstallationFailed("The signed MSW toolchain manifest could not be downloaded.")
            }
            return data
        } catch let error as BootstrapCoordinatorError {
            throw error
        } catch {
            throw BootstrapCoordinatorError.toolchainInstallationFailed("The signed MSW toolchain manifest could not be downloaded.")
        }
    }

    private func installDefaultConfigurationIfNeeded() async throws {
        let homeDirectory = await runner.homeDirectory()
        let configurationDirectory = homeDirectory.appending(
            path: ".config/msw",
            directoryHint: .isDirectory
        )
        let destination = configurationDirectory.appending(
            path: "config.sh",
            directoryHint: .notDirectory
        )
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }

        let bundles = [Bundle.main, Bundle(identifier: "org.microsandbox.MSWMonitor")].compactMap { $0 }
        guard let source = bundles.lazy.compactMap({
            $0.url(forResource: "config", withExtension: "sh")
        }).first,
              let values = try? source.resourceValues(forKeys: [
                  .fileSizeKey,
                  .isRegularFileKey,
                  .isSymbolicLinkKey
              ]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize <= 64 * 1024 else {
            throw BootstrapCoordinatorError.configurationUnavailable
        }

        let data: Data
        do {
            data = try Data(contentsOf: source)
        } catch {
            throw BootstrapCoordinatorError.configurationInstallationFailed(
                "The bundled default configuration could not be read."
            )
        }
        do {
            try FileManager.default.createDirectory(
                at: configurationDirectory,
                withIntermediateDirectories: true
            )
            let temporary = configurationDirectory.appending(
                path: ".config-\(UUID().uuidString)",
                directoryHint: .notDirectory
            )
            defer { try? FileManager.default.removeItem(at: temporary) }
            try data.write(to: temporary, options: .withoutOverwriting)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: temporary.path
            )
            do {
                try FileManager.default.moveItem(at: temporary, to: destination)
            } catch {
                if !FileManager.default.fileExists(atPath: destination.path) {
                    throw error
                }
            }
        } catch let error as BootstrapCoordinatorError {
            throw error
        } catch {
            throw BootstrapCoordinatorError.configurationInstallationFailed(
                "The app could not write \(destination.path)."
            )
        }
    }

    private func installAvailableToolchain() async throws {
        do {
            _ = try await installBundledToolchain()
        } catch let error as BootstrapCoordinatorError where error == .toolchainUnavailable {
            do {
                try await sourceSetup.installRuntime()
            } catch let error as MSWSourceSetupService.Failure {
                switch error {
                case .unavailable:
                    throw BootstrapCoordinatorError.toolchainUnavailable
                case .failed(let detail):
                    throw BootstrapCoordinatorError.toolchainInstallationFailed(detail)
                }
            }
        }
    }

    func run() async throws -> MSWBootstrapResult {
        guard !running else { throw BootstrapCoordinatorError.busy }
        running = true
        defer { running = false }

        var current = await stateStore.load()
        current.startedAt = current.startedAt ?? Date()
        current.updatedAt = Date()
        current.lastError = nil
        try await stateStore.save(current)
        current.phase = .toolchain
        try await stateStore.save(current)
        do {
            try await installDefaultConfigurationIfNeeded()
            let resolution = await runner.mswResolution(forceRefresh: true)
            var runtimeReady = false
            if resolution.selected != nil {
                runtimeReady = await runtimeIsReady()
            }
            if !runtimeReady {
                try await installAvailableToolchain()
                await runner.invalidateMSWResolution()
                runtimeReady = await runtimeIsReady()
            }
            guard runtimeReady else { throw BootstrapCoordinatorError.unavailable }
            current = await stateStore.load()
            current.completedPhases.insert(.toolchain)
            current.phase = .hostIntegration
            current.updatedAt = Date()
            try await stateStore.save(current)
        } catch {
            let failure = (error as? BootstrapCoordinatorError)
                ?? .toolchainInstallationFailed(error.localizedDescription)
            current.lastError = failure.localizedDescription
            current.phase = .toolchain
            current.updatedAt = Date()
            try? await stateStore.save(current)
            throw failure
        }

        // Read-only preflight must pass before the helper is registered or
        // any host-owned files are changed. Advisory checks such as memory
        // remain visible but do not block setup.
        let initialChecks = await preflight()
        guard initialChecks
            .filter({ $0.id != "host-integration" })
            .allSatisfy(isPassingOrAdvisory) else {
            current.phase = .preflight
            current.lastError = BootstrapCoordinatorError.preflightBlocked.localizedDescription
            current.updatedAt = Date()
            try? await stateStore.save(current)
            throw BootstrapCoordinatorError.preflightBlocked
        }

        let hostPackaging = await hostService.packagingStatus
        if hostPackaging == .signingUnavailable {
            if !(await hostRepairVerifier.isReady()) {
                guard sourceSetup.isAvailable else {
                    let failure = BootstrapCoordinatorError.hostRegistrationFailed(hostPackaging.detail)
                    current.lastError = failure.localizedDescription
                    current.phase = .hostIntegration
                    current.updatedAt = Date()
                    try? await stateStore.save(current)
                    throw failure
                }
                do {
                    try await sourceSetup.configureUserIntegrationIfAvailable()
                    try await hostRepairAuthorization.repair()
                } catch {
                    let failure = BootstrapCoordinatorError.hostRegistrationFailed(error.localizedDescription)
                    current.lastError = failure.localizedDescription
                    current.phase = .hostIntegration
                    current.updatedAt = Date()
                    try? await stateStore.save(current)
                    throw failure
                }
                guard await hostRepairVerifier.isReady() else {
                    let failure = BootstrapCoordinatorError.hostRegistrationFailed(
                        "The administrator-approved repair did not complete the fixed aliases and host records."
                    )
                    current.lastError = failure.localizedDescription
                    current.phase = .hostIntegration
                    current.updatedAt = Date()
                    try? await stateStore.save(current)
                    throw failure
                }
            }
            current.completedPhases.insert(.hostIntegration)
            current.phase = .hostIntegration
            current.updatedAt = Date()
            try await stateStore.save(current)
        } else {
            let registrationStatus: MSWHostServiceStatus
            do {
                registrationStatus = try await hostService.registerIfNeeded()
            } catch {
                let failure = (error as? BootstrapCoordinatorError)
                    ?? BootstrapCoordinatorError.hostRegistrationFailed(error.localizedDescription)
                current.lastError = failure.localizedDescription
                current.phase = .hostIntegration
                current.updatedAt = Date()
                try? await stateStore.save(current)
                throw failure
            }
            guard registrationStatus == .enabled else {
                guard registrationStatus == .requiresApproval || registrationStatus == .notRegistered else {
                    let failure = BootstrapCoordinatorError.hostRegistrationFailed("The bundled service is \(registrationStatus.rawValue).")
                    current.lastError = failure.localizedDescription
                    current.phase = .hostIntegration
                    current.updatedAt = Date()
                    try? await stateStore.save(current)
                    throw failure
                }
                current.phase = .hostIntegration
                current.completedPhases.insert(.preflight)
                current.updatedAt = Date()
                try await stateStore.save(current)
                return MSWBootstrapResult(
                    resumed: current.startedAt != nil,
                    phase: MSWBootstrapState.Phase.hostIntegration.rawValue,
                    requiresApproval: true,
                    vmsStarted: false,
                    message: "Approve the MSW Monitor host helper in Login Items settings, then continue setup."
                )
            }

            do {
                _ = try await hostAgent.ensureFixedLoopbackAliases()
                _ = try await hostAgent.installFixedHostRecords()
            } catch {
                let failure = BootstrapCoordinatorError.hostRegistrationFailed(error.localizedDescription)
                current.lastError = failure.localizedDescription
                current.phase = .hostIntegration
                current.updatedAt = Date()
                try? await stateStore.save(current)
                throw failure
            }
        }

        let checks = await preflight()
        guard checks.allSatisfy(isPassingOrAdvisory) else {
            current.phase = .preflight
            current.updatedAt = Date()
            try? await stateStore.save(current)
            throw BootstrapCoordinatorError.preflightBlocked
        }

        current.phase = .workspaces
        try await stateStore.save(current)
        do {
            let response = try await client.bootstrap()
            guard let result = response.result else { throw MSWClientError.missingResult(command: "bootstrap") }
            current.phase = MSWBootstrapState.Phase(rawValue: result.phase) ?? .workspaces
            if !result.requiresApproval && result.phase == MSWBootstrapState.Phase.complete.rawValue {
                current.completedPhases.formUnion([.preflight, .toolchain, .hostIntegration, .workspaces])
            } else {
                current.completedPhases.insert(.preflight)
            }
            current.updatedAt = Date()
            try await stateStore.save(current)
            return result
        } catch {
            current.lastError = String(describing: error)
            current.updatedAt = Date()
            try? await stateStore.save(current)
            throw error
        }
    }

    private func isPassingOrAdvisory(_ check: MSWPreflightCheck) -> Bool {
        check.status == .pass || (check.id == "memory" && check.status == .needsAction)
    }

    private var bundledToolchainConfigurationAvailable: Bool {
        let bundledURL = Bundle.main.url(forResource: "ToolchainManifest", withExtension: "json")
        let configuredURL = (Bundle.main.object(forInfoDictionaryKey: "MSWToolchainManifestURL") as? String)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { value -> URL? in
                guard !value.isEmpty, !value.hasPrefix("$(") else { return nil }
                return URL(string: value)
            }
        guard let manifestURL = bundledURL ?? configuredURL,
              (manifestURL.isFileURL || manifestURL.scheme?.lowercased() == "https"),
              let keyString = Bundle.main.object(forInfoDictionaryKey: "MSWToolchainManifestPublicKey") as? String,
              let publicKey = Data(base64Encoded: keyString.trimmingCharacters(in: .whitespacesAndNewlines)),
              publicKey.count == 32 else {
            return false
        }
        if manifestURL.isFileURL {
            guard let values = try? manifestURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                return false
            }
        }
        return true
    }

    private func commandOutput(executable: URL, arguments: [String]) async -> String? {
        do {
            let result = try await runner.run(MSWCommand(executable: executable, arguments: arguments, timeout: .seconds(5)))
            return result.stdoutString
        } catch {
            return nil
        }
    }

    private func runtimeIsReady() async -> Bool {
        do {
            let handshake = try await client.handshake()
            guard let value = handshake.result,
                  value.protocolVersion == 1,
                  value.configurationAvailable,
                  value.runtimeAvailable,
                  value.capabilities.jq else {
                return false
            }
            for name in ["git", "tar", "zstd", "git-lfs", "msb"] {
                guard await runner.resolveExecutable(named: name) != nil else {
                    return false
                }
            }
            return true
        } catch {
            return false
        }
    }
}

/// Deterministic bootstrap fixture for UI tests. The first `run()` throws the
/// typed GitHub reconnect protocol error a real `msw app bootstrap` reports for
/// a configured workspace whose credential is unavailable; later `run()` calls
/// report a completed verification, mirroring a successful resume after the
/// user reconnects GitHub.
@MainActor
final class MSWBootstrapUITestStub: MSWBootstrapCoordinating {
    private var current: MSWBootstrapState
    private var runCount = 0
    private let failureWorkspace: String

    init(failureWorkspace: String) {
        self.failureWorkspace = failureWorkspace
        let now = Date()
        self.current = MSWBootstrapState(
            phase: .workspaces,
            startedAt: now,
            updatedAt: now,
            lastError: nil,
            completedPhases: [.preflight, .toolchain, .hostIntegration]
        )
    }

    func state() async -> MSWBootstrapState { current }

    func preflight() async -> [MSWPreflightCheck] {
        [
            MSWPreflightCheck(id: "macos-version", title: "macOS 26 or later", status: .pass, detail: "Detected macOS 26.", remediation: nil),
            MSWPreflightCheck(id: "architecture", title: "Apple Silicon", status: .pass, detail: "Detected arm64.", remediation: nil),
            MSWPreflightCheck(id: "disk-space", title: "Available disk space", status: .pass, detail: "128 GiB available; setup estimates at least 20 GiB.", remediation: nil),
            MSWPreflightCheck(id: "memory", title: "Memory budget", status: .pass, detail: "Detected 64 GiB physical memory.", remediation: nil)
        ]
    }

    func run() async throws -> MSWBootstrapResult {
        runCount += 1
        if runCount == 1 {
            let failure = MSWClientError.protocolFailure(MSWProtocolError(
                code: "MSW_GITHUB_RECONNECT_REQUIRED",
                message: "GitHub is configured for '\(failureWorkspace)', but its credential is unavailable.",
                recovery: "Connect GitHub for '\(failureWorkspace)' in MSW Monitor, then resume Setup.",
                workspace: failureWorkspace,
                retryable: true
            ))
            current.lastError = String(describing: failure)
            current.updatedAt = Date()
            throw failure
        }
        current.phase = .complete
        current.completedPhases = Set(MSWBootstrapState.Phase.allCases)
        current.lastError = nil
        current.updatedAt = Date()
        return MSWBootstrapResult(
            resumed: true,
            phase: MSWBootstrapState.Phase.complete.rawValue,
            requiresApproval: false,
            vmsStarted: true,
            message: "Workspace bootstrap and deep verification completed; the previous running set was restored."
        )
    }

    func openHostApprovalSettings() async {}
}
