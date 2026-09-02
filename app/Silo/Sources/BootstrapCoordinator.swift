import Foundation
import Darwin
import Security
import ServiceManagement

struct SiloPreflightCheck: Codable, Identifiable, Sendable, Equatable {
    enum Status: String, Codable, Sendable { case pass, needsAction, unavailable }
    let id: String
    let title: String
    let status: Status
    let detail: String
    let remediation: String?
}

struct SiloBootstrapState: Codable, Sendable, Equatable {
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
    var workspaceConfigurations: [SetupWorkspaceConfiguration]? = nil
    var reconnectWorkspace: String? = nil
    /// Wall-clock seconds per phase for the most recent `run()`, keyed by
    /// `Phase.rawValue`; `preflight` accumulates both read-only passes.
    /// Optional so state persisted by older builds still decodes.
    var phaseDurations: [String: TimeInterval]? = nil

    static var initial: Self {
        Self(phase: .welcome, startedAt: nil, updatedAt: Date(), lastError: nil, completedPhases: [])
    }

    /// Adds elapsed wall-clock time for one timed span into `phaseDurations`.
    mutating func recordPhaseDuration(_ key: String, from start: Date) {
        var durations = phaseDurations ?? [:]
        durations[key, default: 0] += max(0, Date().timeIntervalSince(start))
        phaseDurations = durations
    }
}
enum BootstrapCoordinatorError: Error, LocalizedError, Sendable, Equatable {
    case busy
    case preflightBlocked
    case unavailable
    case toolchainUnavailable
    case configurationUnavailable
    case configurationInstallationFailed(String)
    case invalidWorkspaceConfiguration(String)
    case toolchainInstallationFailed(String)
    case hostRegistrationFailed(String)

    var errorDescription: String? {
        switch self {
        case .busy: return "Setup is already running."
        case .preflightBlocked: return "Setup cannot continue until required preflight checks pass."
        case .unavailable: return "Setup is unavailable until the Silo runtime is installed."
        case .toolchainUnavailable:
            return "The Silo runtime is not bundled with this build."
        case .configurationUnavailable: return "The default Silo configuration is not included in this app build."
        case .configurationInstallationFailed(let detail): return "The Silo configuration could not be installed: \(detail)"
        case .invalidWorkspaceConfiguration(let detail): return "Workspace configuration is invalid: \(detail)"
        case .toolchainInstallationFailed(let detail): return "Silo runtime setup failed: \(detail)"
        case .hostRegistrationFailed(let detail): return "Host integration could not be completed: \(detail)"
        }
    }
}

struct RuntimeRepairFailure: Error, LocalizedError, Sendable, Equatable {
    static let diagnosticLimit = 256 * 1024
    static let summary = "Silo runtime repair could not complete. Show details, then retry."

    let diagnosticDetails: String?

    var errorDescription: String? { Self.summary }

    init(error: Error) {
        let rawDetails: String
        if case BootstrapCoordinatorError.toolchainInstallationFailed(let detail) = error {
            rawDetails = detail
        } else {
            rawDetails = error.localizedDescription
        }
        diagnosticDetails = Self.boundedDetails(rawDetails)
    }

    init(diagnosticDetails: String) {
        self.diagnosticDetails = Self.boundedDetails(diagnosticDetails)
    }

    static func boundedDetails(_ value: String) -> String? {
        let withoutANSI = value.replacingOccurrences(
            of: "\u{001B}\\[[0-?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !withoutANSI.isEmpty, withoutANSI != summary else { return nil }
        let data = Data(withoutANSI.utf8)
        guard data.count > diagnosticLimit else { return withoutANSI }
        let notice = "Earlier diagnostic output omitted.\n"
        let suffixLimit = max(0, diagnosticLimit - Data(notice.utf8).count)
        return notice + String(decoding: data.suffix(suffixLimit), as: UTF8.self)
    }
}
enum SiloHostServiceStatus: String, Sendable {
    case enabled
    case requiresApproval
    case notRegistered
    case notFound
    case unknown
}

enum SiloHostServicePackagingStatus: Sendable, Equatable {
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
            return "This app build is not signed with an Apple team identity. Host integration requires a signed Silo build."
        }
    }

    var remediation: String {
        switch self {
        case .ready:
            return ""
        case .signingUnavailable:
            return "Install a signed Silo build from the project team."
        case .missingPropertyList, .invalidPropertyList, .missingExecutable:
            return "Reinstall a complete, signed copy of Silo."
        }
    }
}

@MainActor
protocol SiloHostServiceControlling: AnyObject, Sendable {
    var status: SiloHostServiceStatus { get }
    func packagingStatus() async -> SiloHostServicePackagingStatus
    func registerIfNeeded() async throws -> SiloHostServiceStatus
    func openApprovalSettings()
}

extension SiloHostServiceControlling {
    func packagingStatus() async -> SiloHostServicePackagingStatus { .ready }
}

/// Code-signature validation hashes every binary in the bundle and can take
/// hundreds of milliseconds on large builds, so it must never run on the
/// main actor. Callers on background executors invoke it directly.

enum SiloHostPackagingInspector {
    /// The constants below mirror the launchd plist contract enforced by the
    /// controller; keep them in sync with SiloHostServiceController.
    private static let plistName = "org.silo.Silo.host-agent.plist"
    private static let serviceName = "org.silo.Silo.host-agent"
    private static let executablePath = "Contents/Resources/SiloHostAgent"

    static func inspect(bundleURL: URL) -> SiloHostServicePackagingStatus {
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

@MainActor
final class SiloHostServiceController: SiloHostServiceControlling {
    static let plistName = "org.silo.Silo.host-agent.plist"
    static let serviceName = "org.silo.Silo.host-agent"
    static let executablePath = "Contents/Resources/SiloHostAgent"

    private let service: SMAppService

    init() {
        service = SMAppService.daemon(plistName: Self.plistName)
    }

    var status: SiloHostServiceStatus {
        switch service.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        @unknown default: return .unknown
        }
    }

    /// Witnessed nonisolated so signature validation runs on the caller's
    /// background executor instead of the main thread.
    nonisolated func packagingStatus() async -> SiloHostServicePackagingStatus {
        SiloHostPackagingInspector.inspect(bundleURL: Bundle.main.bundleURL)
    }

    func registerIfNeeded() async throws -> SiloHostServiceStatus {
        let packaging = await packagingStatus()
        guard packaging == .ready else {
            throw BootstrapCoordinatorError.hostRegistrationFailed(packaging.detail)
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

}

actor BootstrapStateStore {
    private let url: URL
    private var value: SiloBootstrapState

    init(url: URL? = nil) {
        let defaultDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?.appendingPathComponent("Silo", isDirectory: true)
        let fallbackDirectory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support/Silo", isDirectory: true)
        self.url = url ?? (defaultDirectory ?? fallbackDirectory).appendingPathComponent("bootstrap-state.json")
        if FileManager.default.fileExists(atPath: self.url.path) {
            do { value = try JSONDecoder().decode(SiloBootstrapState.self, from: Data(contentsOf: self.url)) }
            catch { value = .initial }
        } else {
            value = .initial
        }
    }
    nonisolated static func persistedWorkspaceConfigurations() -> [SetupWorkspaceConfiguration] {
        let workspaceConfigurationURL: URL = {
            if let explicit = ProcessInfo.processInfo.environment["SILO_WORKSPACES_FILE"],
               !explicit.isEmpty {
                return URL(fileURLWithPath: explicit)
            }
            return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent(".config/silo/workspaces.json")
        }()
        var workspaceFileMetadata = stat()
        let workspaceFileExists = Darwin.lstat(
            workspaceConfigurationURL.path,
            &workspaceFileMetadata
        ) == 0
        if let values = try? workspaceConfigurationURL.resourceValues(forKeys: [
               .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey
           ]),
           values.isRegularFile == true,
           values.isSymbolicLink != true,
           let fileSize = values.fileSize,
           fileSize <= 256 * 1_024,
           let data = try? Data(contentsOf: workspaceConfigurationURL),
           let boundary = SiloBootstrapConfiguration.decodeValidated(from: data) {
            return boundary.setupConfigurations
        }
        if workspaceFileExists {
            return []
        }

        let defaultDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?.appendingPathComponent("Silo", isDirectory: true)
        let fallbackDirectory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support/Silo", isDirectory: true)
        let url = (defaultDirectory ?? fallbackDirectory).appendingPathComponent("bootstrap-state.json")
        guard let values = try? url.resourceValues(forKeys: [
                  .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey
              ]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize <= 256 * 1_024,
              let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(SiloBootstrapState.self, from: data),
              let configurations = state.workspaceConfigurations,
              SetupWorkspaceConfiguration.validationMessage(for: configurations) == nil else {
            return SetupWorkspaceConfiguration.defaults
        }
        return configurations
    }

    func load() -> SiloBootstrapState { value }

    func save(_ state: SiloBootstrapState) throws {
        value = state
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let data = try JSONEncoder().encode(state)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
enum SiloRuntimeSetupPhase: Int, CaseIterable, Sendable, Equatable {
    case installingRuntime
    case installingConfiguration
    case verifying
    case ready
}

protocol SiloBootstrapCoordinating: AnyObject, Sendable {
    func state() async -> SiloBootstrapState
    /// Runs every dependency check. When `onCheck` is provided it is invoked
    /// once per finished check so callers can surface results progressively
    /// while the remaining checks are still running.
    func preflight(onCheck: (@Sendable (SiloPreflightCheck) -> Void)?) async -> [SiloPreflightCheck]
    func prepareRuntime(
        onProgress: (@Sendable (SiloRuntimeSetupPhase) -> Void)?
    ) async throws
    func run(
        workspaceConfigurations: [SetupWorkspaceConfiguration],
        onProgress: (@Sendable (SiloProgressEvent) -> Void)?
    ) async throws -> SiloBootstrapResult
    /// Repairs and verifies only the app-managed runtime. This path does not
    /// apply host integration, workspace configuration, or GitHub setup.
    func repairRuntime() async throws
    /// True when saving these workspaces will require the one-time
    /// administrator-approved hosts update (unsigned-build fallback whose
    /// installed records differ from the desired names).
    func workspaceNamesNeedApproval(
        workspaceConfigurations: [SetupWorkspaceConfiguration]
    ) async -> Bool
    func openHostApprovalSettings() async
}

extension SiloBootstrapCoordinating {
    func run() async throws -> SiloBootstrapResult {
        try await run(
            workspaceConfigurations: SetupWorkspaceConfiguration.defaults,
            onProgress: nil
        )
    }

    func run(
        workspaceConfigurations: [SetupWorkspaceConfiguration]
    ) async throws -> SiloBootstrapResult {
        try await run(workspaceConfigurations: workspaceConfigurations, onProgress: nil)
    }
}

extension SiloBootstrapCoordinating {
    /// Non-streaming convenience for callers that only consume the final set.
    func preflight() async -> [SiloPreflightCheck] {
        await preflight(onCheck: nil)
    }
}

actor BootstrapCoordinator: SiloBootstrapCoordinating {
    private let client: SiloClient
    private let runner: SiloCommandRunner
    private let stateStore: BootstrapStateStore
    private let hostAgent: any SiloHostAgentControlling
    private let hostService: any SiloHostServiceControlling
    private let userIntegration: any SiloUserIntegrationControlling
    private let hostRepairVerifier: any SiloHostRepairVerifying
    private let hostRepairAuthorization: any SiloHostRepairAuthorizing
    private let freeDiskBytes: @Sendable () -> Int64?
    private var running = false
    /// Session cache for the expensive signature-validation query; packaging
    /// does not change while the app runs.
    private var cachedPackagingStatus: SiloHostServicePackagingStatus?
    init(
        client: SiloClient,
        runner: SiloCommandRunner,
        stateStore: BootstrapStateStore = BootstrapStateStore(),
        hostAgent: any SiloHostAgentControlling = HostAgentClient(),
        hostService: any SiloHostServiceControlling,
        userIntegration: (any SiloUserIntegrationControlling)? = nil,
        hostRepairVerifier: (any SiloHostRepairVerifying)? = nil,
        hostRepairAuthorization: (any SiloHostRepairAuthorizing)? = nil,
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
        self.userIntegration = userIntegration ?? SiloUserIntegrationService(runner: runner)
        self.hostRepairVerifier = hostRepairVerifier ?? SiloHostRepairVerifier(runner: runner)
        self.hostRepairAuthorization = hostRepairAuthorization ?? SiloHostRepairAuthorization(runner: runner)
        self.freeDiskBytes = freeDiskBytes
    }

    func state() async -> SiloBootstrapState { await stateStore.load() }

    func hostServiceStatus() async -> SiloHostServiceStatus {
        await hostService.status
    }

    func openHostApprovalSettings() async {
        await hostService.openApprovalSettings()
    }


    func preflight(
        onCheck: (@Sendable (SiloPreflightCheck) -> Void)? = nil
    ) async -> [SiloPreflightCheck] {
        await preflight(workspaceConfigurations: nil, onCheck: onCheck)
    }

    /// Host integration is workspace-scoped. During an onboarding run the
    /// selected configuration is not persisted until bootstrap has applied
    /// and read it back, so post-repair verification must use the submitted
    /// boundary rather than the previously persisted/default boundary.
    private func preflight(
        workspaceConfigurations: [SetupWorkspaceConfiguration]?,
        onCheck: (@Sendable (SiloPreflightCheck) -> Void)? = nil
    ) async -> [SiloPreflightCheck] {
        let persistedWorkspaceConfigurations = (await stateStore.load()).workspaceConfigurations
        let targetWorkspaceConfigurations = workspaceConfigurations
            ?? persistedWorkspaceConfigurations
            ?? SetupWorkspaceConfiguration.defaults
        var checks: [SiloPreflightCheck] = []
        let osMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        checks.append(SiloPreflightCheck(
            id: "macos-version",
            title: "macOS 26 or later",
            status: osMajor >= 26 ? .pass : .needsAction,
            detail: "Detected macOS \(osMajor).",
            remediation: osMajor >= 26 ? nil : "Update macOS before installing Silo."
        ))
        let architecture = await commandOutput(executable: URL(fileURLWithPath: "/usr/bin/uname"), arguments: ["-m"])
        let isArm64 = architecture?.trimmingCharacters(in: .whitespacesAndNewlines) == "arm64"
        checks.append(SiloPreflightCheck(
            id: "architecture",
            title: "Apple Silicon",
            status: architecture == nil ? .unavailable : (isArm64 ? .pass : .needsAction),
            detail: architecture.map { "Detected \($0.trimmingCharacters(in: .whitespacesAndNewlines))." } ?? "Architecture could not be detected.",
            remediation: isArm64 ? nil : "Silo requires an arm64 Mac."
        ))
        let freeBytes = freeDiskBytes()
        let diskPass = (freeBytes ?? 0) >= 20 * 1_024 * 1_024 * 1_024
        checks.append(SiloPreflightCheck(
            id: "disk-space",
            title: "Available disk space",
            status: freeBytes == nil ? .unavailable : (diskPass ? .pass : .needsAction),
            detail: freeBytes.map { "\($0 / (1_024 * 1_024 * 1_024)) GiB available; setup estimates at least 20 GiB." } ?? "Disk space could not be measured.",
            remediation: diskPass ? nil : "Free at least 20 GiB before continuing."
        ))
        let memoryGiB = ProcessInfo.processInfo.physicalMemory / (1_024 * 1_024 * 1_024)
        checks.append(SiloPreflightCheck(
            id: "memory",
            title: "Memory budget",
            status: memoryGiB >= 16 ? .pass : .needsAction,
            detail: "Detected \(memoryGiB) GiB physical memory.",
            remediation: memoryGiB >= 16 ? nil : "At least 16 GiB is recommended for the configured workspaces."
        ))

        // Tool resolution and the Silo-runtime handshake wait on subprocesses
        // while host integration waits on its own XPC chain. Running both
        // tails concurrently bounds checking by the slower branch instead of
        // the sum of both, and every finished check streams to `onCheck`.
        async let runtimeChecks = runtimePreflight(report: onCheck)
        async let hostChecks = hostIntegrationPreflight(
            targetWorkspaceConfigurations,
            report: onCheck
        )
        checks.append(contentsOf: await runtimeChecks)
        checks.append(contentsOf: await hostChecks)
        return checks
    }

    /// Tool availability plus the Silo runtime handshake. Each finished check
    /// is reported immediately so setup can render results progressively.
    private func runtimePreflight(
        report: (@Sendable (SiloPreflightCheck) -> Void)?
    ) async -> [SiloPreflightCheck] {
        var checks: [SiloPreflightCheck] = []
        func record(_ check: SiloPreflightCheck) {
            checks.append(check)
            report?(check)
        }
        for name in ["git", "tar", "zstd", "git-lfs", "msb"] {
            let resolved = await runner.resolveExecutable(named: name)
            let available = resolved != nil
            record(SiloPreflightCheck(
                id: "tool-\(name)",
                title: name,
                status: available ? .pass : .needsAction,
                detail: resolved.map { "\($0.path) is executable." } ?? "\(name) was not found in an app-managed or supported system location.",
                remediation: available ? nil : "Install or select \(name) in Silo setup."
            ))
        }
        let siloResolution = await runner.siloResolution(forceRefresh: true)
        let canInstallToolchain = bundledToolchainAvailable
        let repairRuntimeAction = "Use Repair… to reinstall the bundled Silo runtime."
        if siloResolution.selected == nil {
            record(SiloPreflightCheck(
                id: "silo-runtime",
                title: "Silo runtime",
                status: canInstallToolchain ? .needsAction : .unavailable,
                detail: canInstallToolchain
                    ? "The activated bundled Silo runtime needs repair."
                    : "This app build is missing its bundled Silo runtime.",
                remediation: canInstallToolchain
                    ? repairRuntimeAction
                    : "Reinstall Silo from a complete app bundle."
            ))
        } else {
            // Resolution already handshook the selected candidate; only fall
            // back to a second spawn when that result is unavailable.
            var handshake = await runner.handshakeForSelectedRuntime()
            if handshake == nil {
                handshake = (try? await client.handshake())?.result
            }
            if let handshake {
                let runtimeReady = handshake.runtimeAvailable && handshake.capabilities.jq
                let detail: String
                if runtimeReady {
                    detail = handshake.configurationAvailable
                        ? "Silo verified its coupled runtime."
                        : "Silo verified its coupled runtime. Setup will create its configuration."
                } else {
                    detail = "Silo is present, but its JSON adapter or MicroSandbox runtime is incomplete."
                }
                record(SiloPreflightCheck(
                    id: "silo-runtime",
                    title: "Silo runtime",
                    status: runtimeReady ? .pass : .needsAction,
                    detail: detail,
                    remediation: runtimeReady ? nil : (canInstallToolchain
                        ? repairRuntimeAction
                        : "Reinstall Silo from a complete app bundle.")
                ))
            } else {
                record(SiloPreflightCheck(
                    id: "silo-runtime",
                    title: "Silo runtime",
                    status: .needsAction,
                    detail: "Silo could not verify the installed runtime.",
                    remediation: canInstallToolchain
                        ? repairRuntimeAction
                        : "Reinstall Silo from a complete app bundle."
                ))
            }
        }
        return checks
    }

    /// Packaging, registration state, and helper reachability. Runs off the
    /// main actor; code-signature validation never touches the UI thread.
    private func hostIntegrationPreflight(
        _ targetWorkspaceConfigurations: [SetupWorkspaceConfiguration],
        report: (@Sendable (SiloPreflightCheck) -> Void)?
    ) async -> [SiloPreflightCheck] {
        var checks: [SiloPreflightCheck] = []
        func record(_ check: SiloPreflightCheck) {
            checks.append(check)
            report?(check)
        }
        let hostPackaging = await hostService.packagingStatus()
        if hostPackaging == .signingUnavailable {
            let records = SiloWorkspaceNetwork.records(for: targetWorkspaceConfigurations.map(\.name))
            let ready = await hostRepairVerifier.isReady(records: records)
            if ready {
                record(SiloPreflightCheck(
                    id: "host-integration",
                    title: "Host integration",
                    status: .pass,
                    detail: "Host networking is configured for this Mac.",
                    remediation: nil
                ))
                return checks
            }
            // Auto-fixed by the activated CLI plus the administrator prompt
            // during workspace apply. The Workspaces step surfaces the
            // save-time hint instead of treating this as a missing dependency.
            return checks
        }
        if hostPackaging != .ready {
            record(SiloPreflightCheck(
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
                let records = SiloWorkspaceNetwork.records(for: targetWorkspaceConfigurations.map(\.name))
                let snapshot = try await hostAgent.inspect(records: records)
                let expectedAliases = records.map(\.address)
                let ready = snapshot.fixedAliases == expectedAliases && snapshot.hostsBlockInstalled
                record(SiloPreflightCheck(
                    id: "host-integration",
                    title: "Host integration",
                    status: ready ? .pass : .needsAction,
                    detail: ready ? "The fixed loopback aliases and managed host records are installed." : "The helper is enabled, but fixed loopback aliases or managed host records need repair.",
                    remediation: ready ? nil : "Continue setup to repair only the fixed Silo-owned host integration."
                ))
            } catch {
                record(SiloPreflightCheck(
                    id: "host-integration",
                    title: "Host integration",
                    status: .needsAction,
                    detail: "The registered host helper is not reachable.",
                    remediation: "Restart or repair the Silo host helper, then check again."
                ))
            }
        case .notRegistered:
            record(SiloPreflightCheck(
                id: "host-integration",
                title: "Host integration",
                status: .needsAction,
                detail: "The typed privileged host helper is not registered.",
                remediation: "Continue setup to register the helper and request administrator approval."
            ))
        case .requiresApproval:
            record(SiloPreflightCheck(
                id: "host-integration",
                title: "Host integration",
                status: .needsAction,
                detail: "Administrator approval is required for the typed privileged host helper.",
                remediation: "Open Login Items settings and approve the Silo host helper."
            ))
        case .notFound, .unknown:
            record(SiloPreflightCheck(
                id: "host-integration",
                title: "Host integration",
                status: .unavailable,
                detail: "The bundled host helper is present and signed, but macOS could not load its registration state.",
                remediation: "Continue setup. If the problem remains, reinstall Silo."
            ))
        }
        return checks
    }

    /// Cheap, keystroke-friendly check for the Workspaces step: packaging
    /// state is cached (signature validation is expensive) and only the
    /// hosts file is compared. The apply phase re-verifies aliases and the
    /// daemon authoritatively before it repairs anything.
    func workspaceNamesNeedApproval(
        workspaceConfigurations: [SetupWorkspaceConfiguration]
    ) async -> Bool {
        if let cachedPackagingStatus {
            guard cachedPackagingStatus == .signingUnavailable else { return false }
        } else {
            let status = await hostService.packagingStatus()
            cachedPackagingStatus = status
            guard status == .signingUnavailable else { return false }
        }
        let records = SiloWorkspaceNetwork.records(for: workspaceConfigurations.map(\.name))
        return !SiloHostRepairVerifier.hostsFileMatches(records: records)
    }
    func installBundledToolchain() async throws -> ToolchainInstallResult {
        guard let bundledRoot = ToolchainLayout.bundledRoot() else {
            throw BootstrapCoordinatorError.toolchainUnavailable
        }
        do {
            let homeDirectory = await runner.homeDirectory()
            let installer = ToolchainInstaller(
                bundledRoot: bundledRoot,
                installationRoot: ToolchainLayout.managedRoot(homeDirectory: homeDirectory)
            )
            return try await installer.activate()
        } catch {
            throw BootstrapCoordinatorError.toolchainInstallationFailed(error.localizedDescription)
        }
    }

    private func installDefaultConfigurationIfNeeded(
        activatedRoot: URL? = nil
    ) async throws {
        let sourceRoot: URL
        if let activatedRoot {
            sourceRoot = activatedRoot
        } else {
            guard let bundledRoot = ToolchainLayout.bundledRoot() else {
                throw BootstrapCoordinatorError.configurationUnavailable
            }
            sourceRoot = bundledRoot.appending(
                path: ToolchainLayout.payloadDirectoryName,
                directoryHint: .isDirectory
            )
        }
        do {
            _ = try DefaultSiloConfigurationInstaller.installIfNeeded(
                source: sourceRoot.appending(path: "config.sh", directoryHint: .notDirectory),
                homeDirectory: await runner.homeDirectory()
            )
        } catch {
            throw BootstrapCoordinatorError.configurationInstallationFailed(
                error.localizedDescription
            )
        }
    }

    func prepareRuntime(
        onProgress: (@Sendable (SiloRuntimeSetupPhase) -> Void)? = nil
    ) async throws {
        guard !running else { throw BootstrapCoordinatorError.busy }
        running = true
        defer { running = false }

        onProgress?(.installingRuntime)
        let activated = try await installBundledToolchain()
        onProgress?(.installingConfiguration)
        try await installDefaultConfigurationIfNeeded(activatedRoot: activated.root)
        onProgress?(.verifying)
        await runner.invalidateSiloResolution()
        let expectedExecutable = activated.root
            .appendingPathComponent("bin/silo")
            .standardizedFileURL
        guard await runtimeInstallationIsReady(expectedExecutable: expectedExecutable) else {
            throw BootstrapCoordinatorError.unavailable
        }
        onProgress?(.ready)
    }

    func repairRuntime() async throws {
        do {
            try await prepareRuntime()
        } catch {
            throw RuntimeRepairFailure(error: error)
        }
    }

    func run(
        workspaceConfigurations: [SetupWorkspaceConfiguration],
        onProgress: (@Sendable (SiloProgressEvent) -> Void)?
    ) async throws -> SiloBootstrapResult {
        guard !running else { throw BootstrapCoordinatorError.busy }
        if let validation = SetupWorkspaceConfiguration.validationMessage(for: workspaceConfigurations) {
            throw BootstrapCoordinatorError.invalidWorkspaceConfiguration(validation)
        }
        running = true
        defer { running = false }

        var current = await stateStore.load()
        current.startedAt = current.startedAt ?? Date()
        current.updatedAt = Date()
        current.lastError = nil
        current.reconnectWorkspace = nil
        try await stateStore.save(current)
        current.phase = .toolchain
        try await stateStore.save(current)
        let toolchainStartedAt = Date()
        do {
            try await installDefaultConfigurationIfNeeded()
            guard await runtimeInstallationIsReady() else {
                throw BootstrapCoordinatorError.unavailable
            }
            current = await stateStore.load()
            current.completedPhases.insert(.toolchain)
            current.phase = .hostIntegration
            current.updatedAt = Date()
            current.recordPhaseDuration(SiloBootstrapState.Phase.toolchain.rawValue, from: toolchainStartedAt)
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
        let initialPreflightStartedAt = Date()
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

        current.recordPhaseDuration(
            SiloBootstrapState.Phase.preflight.rawValue,
            from: initialPreflightStartedAt
        )
        let hostIntegrationStartedAt = Date()
        let hostPackaging = await hostService.packagingStatus()
        if hostPackaging == .signingUnavailable {
            let records = SiloWorkspaceNetwork.records(for: workspaceConfigurations.map(\.name))
            if !(await hostRepairVerifier.isReady(records: records)) {
                do {
                    try await hostRepairAuthorization.repair(records: records)
                } catch {
                    let failure = BootstrapCoordinatorError.hostRegistrationFailed(error.localizedDescription)
                    current.lastError = failure.localizedDescription
                    current.phase = .hostIntegration
                    current.updatedAt = Date()
                    try? await stateStore.save(current)
                    throw failure
                }
                guard await hostRepairVerifier.isReady(records: records) else {
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
            let registrationStatus: SiloHostServiceStatus
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
                return SiloBootstrapResult(
                    resumed: current.startedAt != nil,
                    phase: SiloBootstrapState.Phase.hostIntegration.rawValue,
                    requiresApproval: true,
                    vmsStarted: false,
                    message: "Approve the Silo host helper in Login Items settings, then continue setup."
                )
            }

            do {
                let records = SiloWorkspaceNetwork.records(for: workspaceConfigurations.map(\.name))
                _ = try await hostAgent.ensureFixedLoopbackAliases(records: records)
                _ = try await hostAgent.installFixedHostRecords(records: records)
            } catch {
                let failure = BootstrapCoordinatorError.hostRegistrationFailed(error.localizedDescription)
                current.lastError = failure.localizedDescription
                current.phase = .hostIntegration
                current.updatedAt = Date()
                try? await stateStore.save(current)
                throw failure
            }
        }

        current.recordPhaseDuration(
            SiloBootstrapState.Phase.hostIntegration.rawValue,
            from: hostIntegrationStartedAt
        )
        let finalPreflightStartedAt = Date()
        let checks = await preflight(workspaceConfigurations: workspaceConfigurations)
        guard checks.allSatisfy(isPassingOrAdvisory) else {
            current.phase = .preflight
            current.updatedAt = Date()
            try? await stateStore.save(current)
            throw BootstrapCoordinatorError.preflightBlocked
        }

        current.recordPhaseDuration(
            SiloBootstrapState.Phase.preflight.rawValue,
            from: finalPreflightStartedAt
        )
        current.phase = .workspaces
        try await stateStore.save(current)
        do {
            let workspacesStartedAt = Date()
            let response = try await client.bootstrap(
                workspaceConfigurations: workspaceConfigurations,
                onProgress: onProgress
            )
            guard let result = response.result else { throw SiloClientError.missingResult(command: "bootstrap") }
            guard let installed = await runner.installedWorkspaceConfigurations(),
                  SiloBootstrapConfiguration(installed) == SiloBootstrapConfiguration(workspaceConfigurations) else {
                throw BootstrapCoordinatorError.configurationInstallationFailed(
                    "The installed workspace configuration did not match the selected configuration after bootstrap."
                )
            }
            current.phase = SiloBootstrapState.Phase(rawValue: result.phase) ?? .workspaces
            if !result.requiresApproval && result.phase == SiloBootstrapState.Phase.complete.rawValue {
                current.completedPhases.formUnion([.preflight, .toolchain, .hostIntegration, .workspaces])
                current.workspaceConfigurations = workspaceConfigurations
            } else {
                current.completedPhases.insert(.preflight)
            }
            current.updatedAt = Date()
            current.recordPhaseDuration(SiloBootstrapState.Phase.workspaces.rawValue, from: workspacesStartedAt)
            try await stateStore.save(current)
            return result
        } catch {
            if let clientError = error as? SiloClientError,
               case .protocolFailure(let protocolError) = clientError,
               protocolError.code == "SILO_GITHUB_RECONNECT_REQUIRED" {
                // Reconnect can interrupt first-run bootstrap while the CLI's
                // selected configuration is still staged. Route to GitHub,
                // but only mark the workspace boundary applied when a prior
                // committed configuration already matches the selection.
                if let installed = await runner.installedWorkspaceConfigurations(),
                   SiloBootstrapConfiguration(installed) == SiloBootstrapConfiguration(workspaceConfigurations) {
                    current.workspaceConfigurations = workspaceConfigurations
                    current.completedPhases.formUnion([.preflight, .toolchain, .hostIntegration, .workspaces])
                }
                current.phase = .github
                current.reconnectWorkspace = protocolError.workspace
            }
            current.lastError = error.localizedDescription
            current.updatedAt = Date()
            try? await stateStore.save(current)
            throw error
        }
    }

    private func isPassingOrAdvisory(_ check: SiloPreflightCheck) -> Bool {
        check.status == .pass || (check.id == "memory" && check.status == .needsAction)
    }

    private var bundledToolchainAvailable: Bool {
        guard let root = ToolchainLayout.bundledRoot() else { return false }
        return (try? ToolchainValidator.validateBundled(root: root)) != nil
    }

    private func commandOutput(executable: URL, arguments: [String]) async -> String? {
        do {
            let result = try await runner.run(SiloCommand(executable: executable, arguments: arguments, timeout: .seconds(5)))
            return result.stdoutString
        } catch {
            return nil
        }
    }

    private func runtimeInstallationIsReady(
        expectedExecutable: URL? = nil
    ) async -> Bool {
        let homeDirectory = await runner.homeDirectory()
        let configuration = homeDirectory.appending(
            path: ".config/silo/config.sh",
            directoryHint: .notDirectory
        )
        guard DefaultSiloConfigurationInstaller.isValidConfiguration(at: configuration) else {
            return false
        }
        let resolution = await runner.siloResolution(forceRefresh: true)
        let expected = expectedExecutable ?? ToolchainLayout
            .managedRoot(homeDirectory: homeDirectory)
            .appending(path: "current/bin/silo", directoryHint: .notDirectory)
            .standardizedFileURL
        return resolution.selected?.standardizedFileURL == expected
    }
}

/// Deterministic bootstrap fixture for UI tests. The first `run()` throws the
/// typed GitHub reconnect protocol error a real `silo app bootstrap` reports for
/// a configured workspace whose credential is unavailable; later `run()` calls
/// report a completed verification, mirroring a successful resume after the
/// user reconnects GitHub.
@MainActor
final class SiloBootstrapUITestStub: SiloBootstrapCoordinating {
    private var current: SiloBootstrapState
    private var runCount = 0
    private let failureWorkspace: String
    private let keepsFirstRunPending: Bool
    private let completesFirstRun: Bool
    private let simulatesRuntimeInstallation: Bool
    private let registrationFailure: String?

    init(
        failureWorkspace: String,
        keepsFirstRunPending: Bool = false,
        completesFirstRun: Bool = false,
        simulatesRuntimeInstallation: Bool = false,
        registrationFailure: String? = nil
    ) {
        self.failureWorkspace = failureWorkspace
        self.keepsFirstRunPending = keepsFirstRunPending
        self.completesFirstRun = completesFirstRun
        self.simulatesRuntimeInstallation = simulatesRuntimeInstallation
        self.registrationFailure = registrationFailure
        let now = Date()
        self.current = SiloBootstrapState(
            phase: .workspaces,
            startedAt: now,
            updatedAt: now,
            lastError: nil,
            completedPhases: [.preflight, .toolchain, .hostIntegration]
        )
    }

    func state() async -> SiloBootstrapState { current }

    func prepareRuntime(
        onProgress: (@Sendable (SiloRuntimeSetupPhase) -> Void)?
    ) async throws {
        guard simulatesRuntimeInstallation else {
            onProgress?(.ready)
            return
        }
        for phase in [
            SiloRuntimeSetupPhase.installingRuntime,
            .installingConfiguration,
            .verifying,
            .ready
        ] {
            onProgress?(phase)
            if phase != .ready {
                let delay: Duration = phase == .installingRuntime
                    ? .seconds(5)
                    : .milliseconds(500)
                try await Task.sleep(for: delay)
            }
        }
    }

    func preflight(
        onCheck: (@Sendable (SiloPreflightCheck) -> Void)? = nil
    ) async -> [SiloPreflightCheck] {
        let checks: [SiloPreflightCheck] = [
            SiloPreflightCheck(id: "macos-version", title: "macOS 26 or later", status: .pass, detail: "Detected macOS 26.", remediation: nil),
            SiloPreflightCheck(id: "architecture", title: "Apple Silicon", status: .pass, detail: "Detected arm64.", remediation: nil),
            SiloPreflightCheck(id: "disk-space", title: "Available disk space", status: .pass, detail: "128 GiB available; setup estimates at least 20 GiB.", remediation: nil),
            SiloPreflightCheck(id: "memory", title: "Memory budget", status: .pass, detail: "Detected 64 GiB physical memory.", remediation: nil)
        ]
        checks.forEach { onCheck?($0) }
        return checks
    }

    func run(
        workspaceConfigurations: [SetupWorkspaceConfiguration],
        onProgress: (@Sendable (SiloProgressEvent) -> Void)?
    ) async throws -> SiloBootstrapResult {
        if let validation = SetupWorkspaceConfiguration.validationMessage(for: workspaceConfigurations) {
            throw BootstrapCoordinatorError.invalidWorkspaceConfiguration(validation)
        }
        runCount += 1
        if runCount == 1, keepsFirstRunPending {
            let (pending, continuation) = AsyncStream<Void>.makeStream()
            defer { continuation.finish() }
            for await _ in pending {}
            try Task.checkCancellation()
        }
        if runCount == 1, let registrationFailure {
            current.workspaceConfigurations = workspaceConfigurations
            current.phase = .workspaces
            current.lastError = registrationFailure
            current.updatedAt = Date()
            throw BootstrapCoordinatorError.hostRegistrationFailed(registrationFailure)
        }
        if runCount == 1, !completesFirstRun {
            current.workspaceConfigurations = workspaceConfigurations
            current.completedPhases.insert(.workspaces)
            current.phase = .github
            current.reconnectWorkspace = failureWorkspace
            let failure = SiloClientError.protocolFailure(SiloProtocolError(
                code: "SILO_GITHUB_RECONNECT_REQUIRED",
                message: "GitHub is configured for '\(failureWorkspace)', but its credential is unavailable.",
                recovery: "Reconnect '\(failureWorkspace)' in Silo, then resume Setup.",
                workspace: failureWorkspace,
                retryable: true
            ))
            current.lastError = String(describing: failure)
            current.updatedAt = Date()
            throw failure
        }
        current.phase = .complete
        current.completedPhases = Set(SiloBootstrapState.Phase.allCases)
        current.workspaceConfigurations = workspaceConfigurations
        current.reconnectWorkspace = nil
        current.lastError = nil
        current.updatedAt = Date()
        return SiloBootstrapResult(
            resumed: true,
            phase: SiloBootstrapState.Phase.complete.rawValue,
            requiresApproval: false,
            vmsStarted: true,
            message: "Workspace bootstrap and deep verification completed; the previous running set was restored."
        )
    }

    func openHostApprovalSettings() async {}

    func repairRuntime() async {}

    func workspaceNamesNeedApproval(
        workspaceConfigurations: [SetupWorkspaceConfiguration]
    ) async -> Bool { false }
}
