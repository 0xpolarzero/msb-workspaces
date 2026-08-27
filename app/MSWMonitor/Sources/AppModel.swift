import AppKit
import Observation
import UniformTypeIdentifiers

struct Workspace: Identifiable, Equatable, Sendable {
    struct ID: RawRepresentable, Hashable, Codable, Sendable, Identifiable {
        let rawValue: String
        var id: String { rawValue }

        init?(rawValue: String) {
            guard WorkspaceID.isValid(rawValue) else { return nil }
            self.rawValue = rawValue
        }

        private init(_ value: String) { rawValue = value }

        static let dev = Self("dev")
        static let playgrounds = Self("playgrounds")
        static let personal = Self("personal")
        static let fixtureDefaults: [Self] = [.dev, .playgrounds, .personal]
    }

    enum State: String, Equatable, Sendable {
        case running = "Running"
        case stopped = "Stopped"
        case starting = "Starting"
        case stopping = "Stopping"
        case restarting = "Restarting"
        case exited = "Exited"
        case unavailable = "Unavailable"
        case unknown = "Unknown"
        case quarantined = "Quarantined"
    }

    enum CredentialState: String, Equatable, Sendable {
        case unconfigured = "Unconfigured"
        case legacy = "Legacy"
        case ready = "Ready"
        case expiring = "Expiring"
        case needsRestart = "Needs restart"
        case needsAuthorization = "Needs authorization"
        case serviceUnavailable = "Service unavailable"
        case readOnly = "Read-only"
        case removalPending = "Removal pending"
        case quarantined = "Quarantined"
    }

    let id: ID
    let purpose: String
    var state: State
    var credential: CredentialState
    var freshness: MSWFreshness
    var observedAt: Date?
    var networkHost: String?
    var quarantineReason: String?
    var statusReason: String?
    var recoveryAction: String?
    var nextAction: String
    var serverCapabilities: MSWActionCapabilities
    var canStart: Bool
    var canStop: Bool
    var canRestart: Bool
    var canOpenTerminal: Bool
    var canPush: Bool
    /// Published ports skipped by the workspace proxy (already in use).
    var skippedPorts: [Int]?
    /// Human-readable warning about skipped published ports.
    var portWarning: String?

    init(
        id: ID,
        purpose: String? = nil,
        state: State = .stopped,
        credential: CredentialState = .unconfigured,
        freshness: MSWFreshness = .neverObserved,
        observedAt: Date? = nil,
        networkHost: String? = nil,
        quarantineReason: String? = nil,
        statusReason: String? = nil,
        recoveryAction: String? = nil,
        nextAction: String? = nil,
        canStart: Bool = true,
        canStop: Bool = false,
        canRestart: Bool = false,
        canOpenTerminal: Bool = false,
        canPush: Bool = false,
        skippedPorts: [Int]? = nil,
        portWarning: String? = nil,
        serverCapabilities: MSWActionCapabilities? = nil
    ) {
        self.id = id
        self.purpose = purpose ?? Self.defaultPurpose(for: id)
        self.state = state
        self.credential = credential
        self.freshness = freshness
        self.observedAt = observedAt
        self.networkHost = networkHost
        self.quarantineReason = quarantineReason
        self.statusReason = statusReason
        self.recoveryAction = recoveryAction
        self.nextAction = nextAction ?? (state == .running ? "Open Terminal" : "Start")
        self.serverCapabilities = serverCapabilities ?? MSWActionCapabilities(
            canStart: canStart,
            canStop: canStop,
            canRestart: canRestart,
            canOpenTerminal: canOpenTerminal,
            canPush: canPush,
            reason: statusReason,
            recovery: recoveryAction
        )
        self.canStart = canStart
        self.canStop = canStop
        self.canRestart = canRestart
        self.canOpenTerminal = canOpenTerminal
        self.canPush = canPush
        self.skippedPorts = skippedPorts
        self.portWarning = portWarning
    }

    private static func defaultPurpose(for id: ID) -> String {
        switch id {
        case .dev: return "Primary software development workspace"
        case .playgrounds: return "Experiments and disposable prototypes"
        case .personal: return "Personal projects and services"
        default: return "Configured MSW workspace"
        }
    }
}

enum WorkspaceAction: Equatable, Sendable {
    case start
    case stop
    case restart
    case openTerminal
    case openEditor
    case openSite
    case push

    var title: String {
        switch self {
        case .start: return "Start"
        case .stop: return "Stop"
        case .restart: return "Restart"
        case .openTerminal: return "Open Terminal"
        case .openEditor: return "Open in source-code editor"
        case .openSite: return "Open Site"
        case .push: return "Push"
        }
    }
}

extension Workspace.CredentialState {
    var needsAttention: Bool {
        switch self {
        case .ready, .readOnly, .unconfigured:
            return false
        case .legacy, .expiring, .needsRestart, .needsAuthorization, .serviceUnavailable,
             .removalPending, .quarantined:
            return true
        }
    }
}

struct WorkspaceActionAvailability: Equatable, Sendable {
    let isAllowed: Bool
    let reason: String?
    let recovery: String?
}

extension Workspace {
    func actionAvailability(
        for action: WorkspaceAction,
        title: String? = nil
    ) -> WorkspaceActionAvailability {
        let actionTitle = title ?? action.title
        guard freshness == .fresh else {
            return WorkspaceActionAvailability(
                isAllowed: false,
                reason: freshness == .neverObserved
                    ? "No authoritative state has been observed for \(id.rawValue)."
                    : "The last known state for \(id.rawValue) is not fresh.",
                recovery: "Retry the observation before attempting \(actionTitle.lowercased())."
            )
        }
        guard state != .unknown, state != .unavailable else {
            return WorkspaceActionAvailability(
                isAllowed: false,
                reason: "The authoritative state for \(id.rawValue) is unavailable.",
                recovery: serverCapabilities.recovery ?? recoveryAction
            )
        }
        if action != .stop, state == .quarantined || credential == .quarantined {
            return WorkspaceActionAvailability(
                isAllowed: false,
                reason: "\(actionTitle) is blocked because \(id.rawValue) is quarantined. \(quarantineReason ?? "Workspace safety state could not be verified.")",
                recovery: serverCapabilities.recovery ?? recoveryAction
            )
        }

        let capability: Bool
        switch action {
        case .start: capability = serverCapabilities.canStart
        case .stop: capability = serverCapabilities.canStop
        case .restart: capability = serverCapabilities.canRestart
        case .openTerminal, .openEditor, .openSite: capability = serverCapabilities.canOpenTerminal
        case .push: capability = serverCapabilities.canPush
        }
        return WorkspaceActionAvailability(
            isAllowed: capability,
            reason: capability ? nil : (serverCapabilities.reason ?? "MSW did not authorize \(actionTitle.lowercased()) for \(id.rawValue)."),
            recovery: capability ? nil : (serverCapabilities.recovery ?? recoveryAction)
        )
    }
}

struct MonitorHealth: Equatable, Sendable {
    enum Severity: Equatable, Sendable {
        case normal
        case neutral
        case attention
        case critical
    }

    let title: String
    let detail: String
    let symbol: String
    let severity: Severity
}

struct MSWOperationFailureNotice: Equatable, Sendable {
    static let diagnosticLimit = 64 * 1024

    let action: String
    let title: String
    let reason: String
    let recovery: String
    let workspace: Workspace.ID?
    let diagnosticDetails: String?

    init(
        action: String,
        title: String,
        reason: String,
        recovery: String,
        workspace: Workspace.ID?,
        diagnosticDetails: String? = nil
    ) {
        self.action = action
        self.title = title
        self.reason = reason.components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?
            .trimmingCharacters(in: .whitespaces) ?? reason
        self.recovery = recovery
        self.workspace = workspace
        self.diagnosticDetails = Self.boundedDiagnostics(
            diagnosticDetails,
            removingSummary: self.reason
        )
    }

    private static func boundedDiagnostics(
        _ value: String?,
        removingSummary summary: String
    ) -> String? {
        guard let value else { return nil }
        let cleaned = value.replacingOccurrences(
            of: "\u{001B}\\[[0-?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        )
        let lines = cleaned.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != summary }
        let unique = lines.reduce(into: [String]()) { result, line in
            if result.last != line { result.append(line) }
        }
        guard !unique.isEmpty else { return nil }
        let joined = unique.joined(separator: "\n")
        let data = Data(joined.utf8)
        guard data.count > diagnosticLimit else { return joined }
        let notice = "Earlier diagnostic output omitted.\n"
        let remaining = diagnosticLimit - Data(notice.utf8).count
        return notice + String(decoding: data.suffix(max(0, remaining)), as: UTF8.self)
    }
}
@MainActor
struct SystemApplication: Equatable, Sendable {
    let url: URL
    let bundleIdentifier: String
    let displayName: String

    init?(url: URL) {
        guard let bundle = Bundle(url: url),
              let bundleIdentifier = bundle.bundleIdentifier else { return nil }
        let displayName = [
            bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String,
            bundle.localizedInfoDictionary?["CFBundleName"] as? String,
            bundle.infoDictionary?["CFBundleDisplayName"] as? String,
            bundle.infoDictionary?["CFBundleName"] as? String,
            url.deletingPathExtension().lastPathComponent
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let displayName else { return nil }
        self.url = url
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
    }

    init(url: URL, bundleIdentifier: String, displayName: String) {
        self.url = url
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
    }
}

@MainActor
struct SystemApplicationDefaults: Equatable, Sendable {
    let terminal: SystemApplication?
    let sourceEditor: SystemApplication?

    static func discover(workspace: NSWorkspace = .shared) -> Self {
        Self(
            terminal: workspace.urlForApplication(toOpen: .unixExecutable).flatMap(SystemApplication.init(url:)),
            sourceEditor: workspace.urlForApplication(toOpen: .sourceCode).flatMap(SystemApplication.init(url:))
        )
    }
}

@MainActor
struct SystemApplicationCatalog: Equatable, Sendable {
    let defaults: SystemApplicationDefaults
    let terminals: [SystemApplication]
    let sourceEditors: [SystemApplication]

    private static let terminalBundleIdentifiers = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty"
    ]

    static func discover(workspace: NSWorkspace = .shared) -> Self {
        let defaults = SystemApplicationDefaults.discover(workspace: workspace)
        return Self(
            defaults: defaults,
            terminals: applications(
                bundleIdentifiers: terminalBundleIdentifiers,
                workspace: workspace
            ),
            sourceEditors: applications(
                bundleIdentifiers: SourceEditorLauncher.supportedBundleIdentifiers,
                workspace: workspace
            )
        )
    }

    func normalized() -> Self {
        Self(
            defaults: defaults,
            terminals: Self.deduplicatedAndSorted(terminals),
            sourceEditors: Self.deduplicatedAndSorted(sourceEditors)
        )
    }

    private static func applications(
        bundleIdentifiers: [String],
        workspace: NSWorkspace
    ) -> [SystemApplication] {
        var byBundleIdentifier: [String: SystemApplication] = [:]
        for bundleIdentifier in bundleIdentifiers {
            guard let url = workspace.urlForApplication(withBundleIdentifier: bundleIdentifier),
                  let application = SystemApplication(url: url) else { continue }
            byBundleIdentifier[application.bundleIdentifier] = application
        }
        return deduplicatedAndSorted(Array(byBundleIdentifier.values))
    }

    private static func deduplicatedAndSorted(_ applications: [SystemApplication]) -> [SystemApplication] {
        let byBundleIdentifier = Dictionary(
            applications.map { ($0.bundleIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return byBundleIdentifier.values.sorted {
            let nameOrder = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            if nameOrder == .orderedSame {
                return $0.bundleIdentifier < $1.bundleIdentifier
            }
            return nameOrder == .orderedAscending
        }
    }
}

enum RuntimeRepairAccessibilityIdentifier {
    static let windowBanner = "runtime-repair.window.banner"
    static let windowMessage = "runtime-repair.window.message"
    static let windowAction = "runtime-repair.window.action"
    static let windowChrome = "runtime-repair.window.chrome"
    static let statusWarning = "runtime-repair.status-item.warning"
    static let popoverRow = "runtime-repair.popover.row"
    static let popoverMessage = "runtime-repair.popover.message"
    static let popoverAction = "runtime-repair.popover.action"
    static let repairWindow = "runtime-repair.window"
    static let repairPage = "runtime-repair.page"
    static let repairTitle = "runtime-repair.title"
    static let repairMessage = "runtime-repair.message"
    static let repairAction = "runtime-repair.installation.action"
    static let repairProgress = "runtime-repair.progress"
    static let repairResult = "runtime-repair.result"
    static let repairDetailsDisclosure = "runtime-repair.details.disclosure"
    static let repairDetails = "runtime-repair.details.text"
    static let repairCopyDetails = "runtime-repair.details.copy"
    static let repairClose = "runtime-repair.close"
}

enum RuntimeRepairPresentation {
    static let message = "MSW installation needs repair"
    static let actionTitle = "Repair…"
    static let statusValue = "MSW Monitor. Repair needed. MSW installation needs repair."
}

enum RuntimeRepairIssueClassifier {
    static func isRepairRelated(_ error: Error) -> Bool {
        guard let clientError = error as? MSWClientError else { return false }
        switch clientError {
        case .invalidExecutable:
            return true
        default:
            return false
        }
    }

    static func isRepairRelated(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return repairMessageMarkers.contains { normalized.contains($0) }
    }

    static func presentedMessage(_ message: String?, repairRequired: Bool) -> String? {
        guard let message else { return nil }
        return repairRequired && isRepairRelated(message) ? nil : message
    }

    static func isRepairRelated(_ operation: MSWBackupOperation) -> Bool {
        isRepairRelated(operation.message)
    }

    private static let repairMessageMarkers = [
        "msw executable is unavailable",
        "bundled msw payload is unavailable",
        "bundled msw command failed its version handshake"
    ]
}

@Observable
@MainActor
final class ApplicationPreferenceStore {
    static let terminalOverrideKey = "applications.terminal.bundleIdentifier"
    static let sourceEditorOverrideKey = "applications.sourceEditor.bundleIdentifier"

    private let userDefaults: UserDefaults
    private let catalogProvider: @MainActor () -> SystemApplicationCatalog
    private(set) var catalog: SystemApplicationCatalog
    private(set) var terminalOverrideBundleIdentifier: String?
    private(set) var sourceEditorOverrideBundleIdentifier: String?

    init(
        userDefaults: UserDefaults = .standard,
        catalogProvider: @escaping @MainActor () -> SystemApplicationCatalog = {
            SystemApplicationCatalog.discover()
        }
    ) {
        self.userDefaults = userDefaults
        self.catalogProvider = catalogProvider
        self.catalog = catalogProvider().normalized()
        self.terminalOverrideBundleIdentifier = userDefaults.string(forKey: Self.terminalOverrideKey)
        self.sourceEditorOverrideBundleIdentifier = userDefaults.string(forKey: Self.sourceEditorOverrideKey)
        discardMissingOverrides()
    }

    var resolvedTerminal: SystemApplication? {
        resolvedApplication(
            overrideBundleIdentifier: terminalOverrideBundleIdentifier,
            choices: catalog.terminals,
            systemDefault: catalog.defaults.terminal
        )
    }

    var resolvedSourceEditor: SystemApplication? {
        resolvedApplication(
            overrideBundleIdentifier: sourceEditorOverrideBundleIdentifier,
            choices: catalog.sourceEditors,
            systemDefault: catalog.defaults.sourceEditor
        )
    }

    var terminalSelection: String {
        get { terminalOverrideBundleIdentifier ?? "" }
        set { setTerminalOverride(newValue.isEmpty ? nil : newValue) }
    }

    var sourceEditorSelection: String {
        get { sourceEditorOverrideBundleIdentifier ?? "" }
        set { setSourceEditorOverride(newValue.isEmpty ? nil : newValue) }
    }

    var systemDefaultTerminalLabel: String {
        systemDefaultLabel(for: catalog.defaults.terminal)
    }

    var systemDefaultSourceEditorLabel: String {
        systemDefaultLabel(for: catalog.defaults.sourceEditor)
    }

    var resolvedTerminalName: String {
        resolvedTerminal?.displayName ?? "Unavailable"
    }

    var resolvedSourceEditorName: String {
        resolvedSourceEditor?.displayName ?? "Unavailable"
    }

    func setTerminalOverride(_ bundleIdentifier: String?) {
        terminalOverrideBundleIdentifier = validOverride(bundleIdentifier, choices: catalog.terminals)
        persist(terminalOverrideBundleIdentifier, key: Self.terminalOverrideKey)
    }

    func setSourceEditorOverride(_ bundleIdentifier: String?) {
        sourceEditorOverrideBundleIdentifier = validOverride(bundleIdentifier, choices: catalog.sourceEditors)
        persist(sourceEditorOverrideBundleIdentifier, key: Self.sourceEditorOverrideKey)
    }

    func refreshInstalledApplications() {
        catalog = catalogProvider().normalized()
        discardMissingOverrides()
    }

    private func resolvedApplication(
        overrideBundleIdentifier: String?,
        choices: [SystemApplication],
        systemDefault: SystemApplication?
    ) -> SystemApplication? {
        guard let overrideBundleIdentifier else { return systemDefault }
        return choices.first { $0.bundleIdentifier == overrideBundleIdentifier } ?? systemDefault
    }

    private func validOverride(
        _ bundleIdentifier: String?,
        choices: [SystemApplication]
    ) -> String? {
        guard let bundleIdentifier,
              choices.contains(where: { $0.bundleIdentifier == bundleIdentifier }) else { return nil }
        return bundleIdentifier
    }

    private func discardMissingOverrides() {
        let terminal = validOverride(terminalOverrideBundleIdentifier, choices: catalog.terminals)
        if terminal != terminalOverrideBundleIdentifier {
            terminalOverrideBundleIdentifier = terminal
            persist(nil, key: Self.terminalOverrideKey)
        }
        let editor = validOverride(sourceEditorOverrideBundleIdentifier, choices: catalog.sourceEditors)
        if editor != sourceEditorOverrideBundleIdentifier {
            sourceEditorOverrideBundleIdentifier = editor
            persist(nil, key: Self.sourceEditorOverrideKey)
        }
    }

    private func persist(_ value: String?, key: String) {
        if let value {
            userDefaults.set(value, forKey: key)
        } else {
            userDefaults.removeObject(forKey: key)
        }
    }

    private func systemDefaultLabel(for application: SystemApplication?) -> String {
        "System Default — \(application?.displayName ?? "Unavailable")"
    }
}

@MainActor
struct TerminalLauncher {
    enum HandoffAdapter: Equatable {
        case ghosttyNativeTab
        case commandFile
    }

    enum LaunchError: LocalizedError {
        case noDefaultTerminal
        case openFailed(String)

        var errorDescription: String? {
            switch self {
            case .noDefaultTerminal:
                return "No default terminal app is configured."
            case .openFailed(let message):
                return "The selected terminal could not open a new tab: \(message)"
            }
        }
    }

    func open(
        applicationURL: URL,
        executableURL: URL,
        workspaceID: String,
        executableSearchPath: String
    ) async throws {
        if Self.handoffAdapter(
            bundleIdentifier: Bundle(url: applicationURL)?.bundleIdentifier
        ) == .ghosttyNativeTab {
            try openGhostty(
                executableURL: executableURL,
                workspaceID: workspaceID,
                executableSearchPath: executableSearchPath
            )
            return
        }

        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("msw-monitor-\(UUID().uuidString).command")
        do {
            try Data(Self.commandScript(
                executableURL: executableURL,
                workspaceID: workspaceID,
                executableSearchPath: executableSearchPath
            ).utf8).write(to: scriptURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: scriptURL.path
            )
        } catch {
            try? FileManager.default.removeItem(at: scriptURL)
            throw LaunchError.openFailed(error.localizedDescription)
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.promptsUserIfNeeded = false
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                NSWorkspace.shared.open(
                    [scriptURL],
                    withApplicationAt: applicationURL,
                    configuration: configuration
                ) { _, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: scriptURL)
            throw LaunchError.openFailed(error.localizedDescription)
        }

        Task {
            try? await Task.sleep(for: .seconds(30))
            try? FileManager.default.removeItem(at: scriptURL)
        }
    }

    static func handoffAdapter(bundleIdentifier: String?) -> HandoffAdapter {
        bundleIdentifier == "com.mitchellh.ghostty" ? .ghosttyNativeTab : .commandFile
    }

    static func ghosttyScript(
        executableURL: URL,
        workspaceID: String,
        executableSearchPath: String
    ) -> String {
        let command = "\(shellQuoted(executableURL.path)) \(shellQuoted(workspaceID))"
        let commandText = appleScriptQuoted(command)
        let pathVariable = appleScriptQuoted("PATH=\(executableSearchPath)")
        return """
        set commandText to \(commandText)
        tell application id "com.mitchellh.ghostty"
            activate
            set cfg to new surface configuration
            set command of cfg to commandText
            set environment variables of cfg to {\(pathVariable)}
            if (count of windows) is 0 then
                new window with configuration cfg
            else
                set targetTab to new tab in front window with configuration cfg
                select tab targetTab
            end if
        end tell
        """
    }

    private func openGhostty(
        executableURL: URL,
        workspaceID: String,
        executableSearchPath: String
    ) throws {
        guard let script = NSAppleScript(source: Self.ghosttyScript(
            executableURL: executableURL,
            workspaceID: workspaceID,
            executableSearchPath: executableSearchPath
        )) else {
            throw LaunchError.openFailed("MSW Monitor could not prepare the Ghostty command.")
        }
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo["NSAppleScriptErrorMessage"] as? String
                ?? "Ghostty automation was denied or failed."
            throw LaunchError.openFailed(message)
        }
    }

    static func commandScript(
        executableURL: URL,
        workspaceID: String,
        executableSearchPath: String
    ) -> String {
        """
        #!/bin/zsh
        script_path=$0
        rm -f -- "$script_path"
        export PATH=\(shellQuoted(executableSearchPath))
        exec \(shellQuoted(executableURL.path)) \(shellQuoted(workspaceID))
        """
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private static func appleScriptQuoted(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}

@MainActor
struct SourceEditorLauncher {
    nonisolated static let supportedBundleIdentifiers = [
        "dev.zed.Zed",
        "dev.zed.Zed-Preview",
        "dev.zed.Zed-Nightly",
        "dev.zed.Zed-Dev"
    ]

    enum LaunchError: LocalizedError {
        case noDefaultEditor
        case unsupportedEditor(String)
        case invalidTarget
        case openFailed(String)

        var errorDescription: String? {
            switch self {
            case .noDefaultEditor:
                return "No default source-code editor is configured."
            case .unsupportedEditor(let name):
                return "\(name) is the default source-code editor, but MSW Monitor has no verified remote-workspace adapter for it. Choose a supported editor as the macOS default; no fallback was opened."
            case .invalidTarget:
                return "MSW returned an invalid remote folder target."
            case .openFailed(let message):
                return "The selected source-code editor could not open the selected folder: \(message)"
            }
        }
    }

    private enum Adapter {
        case zed

        init?(bundleIdentifier: String) {
            switch bundleIdentifier {
            case let identifier where SourceEditorLauncher.supportedBundleIdentifiers.contains(identifier):
                self = .zed
            default: return nil
            }
        }

        func remoteURL(for target: MSWEditorTarget) -> URL? {
            switch self {
            case .zed: return target.zedRemoteURL
            }
        }
    }

    func validate(application: SystemApplication?) throws -> SystemApplication {
        guard let application else { throw LaunchError.noDefaultEditor }
        guard Adapter(bundleIdentifier: application.bundleIdentifier) != nil else {
            throw LaunchError.unsupportedEditor(application.displayName)
        }
        return application
    }

    func open(application: SystemApplication?, target: MSWEditorTarget?) async throws {
        let application = try validate(application: application)
        guard let target,
              let adapter = Adapter(bundleIdentifier: application.bundleIdentifier),
              let remoteURL = adapter.remoteURL(for: target) else {
            throw LaunchError.invalidTarget
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.promptsUserIfNeeded = false
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                NSWorkspace.shared.open(
                    [remoteURL],
                    withApplicationAt: application.url,
                    configuration: configuration
                ) { _, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
        } catch {
            throw LaunchError.openFailed(error.localizedDescription)
        }
    }
}


@Observable
@MainActor
final class AppModel {
    enum BackupUITestResultScenario: Equatable {
        case running
        case success
        case partial
        case failure
    }

    private(set) var workspaces: [Workspace]
    private(set) var lastObservedAt: Date?
    private(set) var lastError: String?
    private(set) var lastRecovery: MSWRecoveryContext?
    private(set) var latestOperationFailure: MSWOperationFailureNotice?
    private(set) var activities: [MSWActivity] = []
    private(set) var operationStates: [String: MSWOperationState] = [:]
    private(set) var notificationEvents: [MSWNotificationEvent] = []
    private(set) var setupState: MSWBootstrapState = .initial
    private(set) var startupRecoveryBlockedReason: String?
    private(set) var repositoriesByWorkspace: [String: MSWRepositoriesResponse] = [:]
    private(set) var repositoryLoadingWorkspaces: Set<String> = []
    private(set) var repositoryUnavailableWorkspaces: Set<String> = []
    private(set) var portsSnapshot: MSWPortsResponse?
    private(set) var githubSnapshot: MSWGitHubStateResponse?
    private(set) var detailError: String?
    private(set) var backupError: String?
    private(set) var isDetailLoading = false
    private(set) var logsByWorkspace: [String: MSWLogsResponse] = [:]
    private(set) var logsUnavailableWorkspaces: Set<String> = []
    private(set) var systemHealthChecks: [MSWPreflightCheck] = []
    private(set) var isSystemHealthLoading = false
    private(set) var backupOperations: [MSWBackupOperation] = []
    private(set) var pendingBackupPreview: MSWBackupPreview?
    private(set) var isBackupPreviewLoading = false
    /// Single application-wide runtime repair state. The authoritative
    /// value comes from executable resolution plus the protocol handshake.
    private(set) var runtimeRepairRequired: Bool
    private(set) var maintenanceMessage: String?
    var selectedWorkspace: Workspace.ID?
    private(set) var pendingLifecyclePlan: MSWLifecyclePlan?
    private(set) var pendingLifecycleAction: MSWLifecycleAction?
    private(set) var pendingLifecycleWorkspace: Workspace.ID?
    private(set) var pendingPushPlan: MSWPushPlan?
    private enum SafetyAction {
        case lifecycle(MSWLifecycleAction)
        case terminal
        case editor
        case site
        case push
    }

    private struct DirectoryCacheKey: Hashable {
        let workspace: Workspace.ID
        let path: String
        let query: String?
    }

    private struct CachedDirectoryResponse {
        let response: MSWDirectoryResponse
        let cachedAt: Date
    }

    private var startupRecoveryRetry: (() -> Void)?
    private let client: MSWClient?
    let applicationPreferences: ApplicationPreferenceStore
    private let operationCoordinator: MSWOperationCoordinator?
    private let operationService: MSWOperationService?
    private let diagnostics: MSWDiagnostics?
    private var systemHealthCoordinator: (any MSWBootstrapCoordinating)?
    private let provider: (any GitHubProviding)?
    let accessMode: GitHubAccessMode
    private let activityStore: MSWActivityStore
    private var pollingTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var runtimeRepairFailureRefreshTask: Task<Void, Never>?
    private var runtimeRepairRefreshGeneration = 0
    private var refreshGeneration = 0
    private var consecutiveRefreshFailures = 0
    private var sustainedUnavailableNotified = false
    private var notificationGeneration = 0
    private var detailRequestGeneration = 0
    private var systemHealthGeneration = 0
    private var directoryFixture: [MSWDirectoryResponse] = []
    private var backupPreviewFixtureSourceAllocatedBytes: Int64?
    private var backupPreviewFixtureArchiveEstimate: MSWBackupEstimate?
    private var backupPreviewFixtureDestination: URL?
    private var backupUITestResultScenario: BackupUITestResultScenario?
    private var directoryCache: [DirectoryCacheKey: CachedDirectoryResponse] = [:]
    private var configuredWorkspaceIDs: [Workspace.ID]
    private enum RefreshResult {
        case applied(MSWStateResponse)
        case failed
        case superseded
    }



    init(
        client: MSWClient? = nil,
        operationCoordinator: MSWOperationCoordinator? = nil,
        operationService: MSWOperationService? = nil,
        diagnostics: MSWDiagnostics? = nil,
        provider: (any GitHubProviding)? = nil,
        accessMode: GitHubAccessMode = .local,
        activityStore: MSWActivityStore = MSWActivityStore(),
        workspaceConfigurations: [SetupWorkspaceConfiguration]? = nil,
        startupRecoveryBlockedReason: String? = nil,
        startupRecoveryRetry: (() -> Void)? = nil,
        initialOperationFailure: MSWOperationFailureNotice? = nil,
        applicationPreferences: ApplicationPreferenceStore? = nil,
        applicationDefaults: SystemApplicationDefaults? = nil,
        initialRuntimeRepairRequired: Bool = false
    ) {
        self.client = client
        self.operationCoordinator = operationCoordinator
        self.operationService = operationService
        self.diagnostics = diagnostics
        self.provider = provider
        self.accessMode = accessMode
        self.activityStore = activityStore
        self.startupRecoveryBlockedReason = startupRecoveryBlockedReason
        self.startupRecoveryRetry = startupRecoveryRetry
        self.latestOperationFailure = initialOperationFailure
        self.runtimeRepairRequired = initialRuntimeRepairRequired
        self.applicationPreferences = applicationPreferences ?? ApplicationPreferenceStore(
            catalogProvider: {
                let defaults = applicationDefaults ?? .discover()
                return SystemApplicationCatalog(defaults: defaults, terminals: [], sourceEditors: [])
            }
        )
        let configured = workspaceConfigurations ?? SetupWorkspaceConfiguration.defaults
        let resolvedWorkspaceIDs = configured.compactMap { Workspace.ID(rawValue: $0.name) }
        let initialWorkspaceIDs = resolvedWorkspaceIDs
        configuredWorkspaceIDs = initialWorkspaceIDs
        workspaces = initialWorkspaceIDs.map {
            if let startupRecoveryBlockedReason {
                return Workspace(
                    id: $0,
                    state: .quarantined,
                    credential: .quarantined,
                    freshness: .unavailable,
                    quarantineReason: startupRecoveryBlockedReason,
                    statusReason: "Startup authorization recovery is blocked.",
                    recoveryAction: "Retry authorization recovery before using workspace credentials.",
                    nextAction: "Recover authorization",
                    canStart: false,
                    canStop: false,
                    canRestart: false
                )
            }
            return client == nil
                ? Workspace(
                    id: $0,
                    statusReason: "No authoritative state has been observed.",
                    recoveryAction: "Connect MSW and retry the observation.",
                    nextAction: "Observe",
                    canStart: false
                )
                : Workspace(
                    id: $0,
                    state: .unknown,
                    freshness: .unavailable,
                    statusReason: "No authoritative state has been observed.",
                    recoveryAction: "Retry the observation or run setup.",
                    nextAction: "Set up",
                    canStart: false,
                    canStop: false,
                    canRestart: false
                )
        }
    }

    /// Replaces the monitor's workspace target list immediately after Setup
    /// applies a validated configuration. A subsequent authoritative refresh
    /// fills the new rows, but stale removed/renamed fixture IDs never remain
    /// visible while that observation is in flight or unavailable.
    func reloadWorkspaceConfiguration(_ configurations: [SetupWorkspaceConfiguration]) {
        guard SetupWorkspaceConfiguration.validationMessage(for: configurations) == nil else { return }
        refreshGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        detailRequestGeneration &+= 1
        isDetailLoading = false
        detailError = nil
        backupError = nil
        logsUnavailableWorkspaces.removeAll()
        directoryCache.removeAll()
        let ids = configurations.compactMap { Workspace.ID(rawValue: $0.name) }
        let previous = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
        configuredWorkspaceIDs = ids
        workspaces = ids.map { id in
            if let existing = previous[id] { return existing }
            return Workspace(
                id: id,
                state: client == nil ? .stopped : .unknown,
                freshness: client == nil ? .fresh : .unavailable,
                statusReason: client == nil
                    ? "Deterministic fixture workspace."
                    : "Awaiting an authoritative observation for the applied workspace configuration.",
                recoveryAction: client == nil ? nil : "Retry the observation or run diagnostics.",
                nextAction: client == nil ? nil : "Observe",
                canStart: false,
                canStop: false,
                canRestart: false
            )
        }
        githubSnapshot = nil
        pendingLifecyclePlan = nil
        pendingPushPlan = nil
    }


    var isMaintenanceOperationInFlight: Bool {
        operationStates.values.contains { operation in
            operation.kind == .restore &&
                operation.outcome == .pending
        }
    }

    var hasActiveBackupOperations: Bool {
        backupOperations.contains { $0.state == .queued || $0.state == .running }
    }

    var presentedDetailError: String? {
        RuntimeRepairIssueClassifier.presentedMessage(
            detailError,
            repairRequired: runtimeRepairRequired
        )
    }

    var presentedBackupError: String? {
        RuntimeRepairIssueClassifier.presentedMessage(
            backupError,
            repairRequired: runtimeRepairRequired
        )
    }

    var presentedBackupOperations: [MSWBackupOperation] {
        guard runtimeRepairRequired else { return backupOperations }
        return backupOperations.filter { !RuntimeRepairIssueClassifier.isRepairRelated($0) }
    }


    var aggregateText: String {
        health.title
    }

    var aggregateDetail: String {
        health.detail
    }

    var terminalActionTitle: String {
        applicationPreferences.resolvedTerminal.map { "Open in \($0.displayName)" } ?? "Open in Default Terminal"
    }

    var editorActionTitle: String {
        applicationPreferences.resolvedSourceEditor.map { "Open in \($0.displayName)…" } ?? "Open in Default Source-Code Editor…"
    }

    var editorOpenActionTitle: String {
        applicationPreferences.resolvedSourceEditor.map { "Open in \($0.displayName)" } ?? "Open in Default Source-Code Editor"
    }

    var health: MonitorHealth {
        if let startupRecoveryBlockedReason {
            return MonitorHealth(
                title: "Authorization recovery blocked",
                detail: "Workspace credentials remain protected until startup recovery succeeds. \(startupRecoveryBlockedReason)",
                symbol: "exclamationmark.octagon.fill",
                severity: .critical
            )
        }
        if workspaces.contains(where: { $0.state == .quarantined || $0.credential == .quarantined }) {
            return MonitorHealth(
                title: "Action required",
                detail: "A workspace is quarantined. Unsafe actions are blocked.",
                symbol: "exclamationmark.octagon.fill",
                severity: .critical
            )
        }
        if let failure = latestOperationFailure {
            return MonitorHealth(
                title: failure.title,
                detail: failure.reason,
                symbol: "exclamationmark.triangle.fill",
                severity: .attention
            )
        }
        if lastError == nil,
           workspaces.allSatisfy({ $0.freshness == .neverObserved || $0.state == .unknown }) {
            return MonitorHealth(
                title: "Not observed",
                detail: "No authoritative workspace state is available yet.",
                symbol: "questionmark.circle",
                severity: .neutral
            )
        }
        if workspaces.contains(where: { $0.state == .unavailable || $0.freshness == .unavailable }) {
            return MonitorHealth(
                title: "Unavailable",
                detail: lastError ?? "Some workspace state is unavailable.",
                symbol: "exclamationmark.triangle.fill",
                severity: .attention
            )
        }
        if lastError != nil || workspaces.contains(where: { $0.freshness == .stale }) {
            return MonitorHealth(
                title: "Last known state",
                detail: lastError ?? "Workspace data is stale; fresh-state actions are blocked.",
                symbol: "clock.badge.exclamationmark",
                severity: .attention
            )
        }
        if workspaces.contains(where: { $0.state == .exited || $0.credential.needsAttention }) {
            return MonitorHealth(
                title: "Needs attention",
                detail: "One or more workspaces has a recovery step.",
                symbol: "exclamationmark.triangle.fill",
                severity: .attention
            )
        }
        return MonitorHealth(
            title: "Ready",
            detail: "Workspace state is current and actions are available.",
            symbol: "checkmark.circle.fill",
            severity: .normal
        )
    }

    func refresh() {
        if startupRecoveryBlockedReason != nil {
            startupRecoveryRetry?()
            return
        }
        if client == nil {
            return
        }
        refreshGeneration += 1
        let generation = refreshGeneration
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.refreshRuntimeRepairState()
            guard self?.runtimeRepairRequired == false else { return }
            _ = await self?.refreshRemote(generation: generation)
        }
    }

    /// Revalidates the resolved runtime without invoking a backup command.
    /// Startup and polling use the resolver cache; dedicated repair success
    /// forces a new resolution so the verified managed runtime is visible.
    func refreshRuntimeRepairState(forceRefresh: Bool = false) async {
        guard let client else { return }
        runtimeRepairRefreshGeneration &+= 1
        let generation = runtimeRepairRefreshGeneration
        guard let required = await client.runtimeRepairRequired(forceRefresh: forceRefresh),
              !Task.isCancelled,
              generation == runtimeRepairRefreshGeneration else {
            return
        }
        runtimeRepairRequired = required
    }

    func runtimeRepairDidSucceed() {
        runtimeRepairFailureRefreshTask?.cancel()
        runtimeRepairFailureRefreshTask = nil
        runtimeRepairRefreshGeneration &+= 1
        runtimeRepairRequired = false
        if let detailError, RuntimeRepairIssueClassifier.isRepairRelated(detailError) {
            self.detailError = nil
        }
        if let backupError, RuntimeRepairIssueClassifier.isRepairRelated(backupError) {
            self.backupError = nil
        }
        if let lastError, RuntimeRepairIssueClassifier.isRepairRelated(lastError) {
            self.lastError = nil
        }
        guard let client else {
            // Deterministic UI fixtures have no process-backed runtime.
            return
        }
        Task { [weak self] in
            await client.invalidateRuntimeResolution()
            await self?.refreshRuntimeRepairState(forceRefresh: true)
            self?.refresh()
        }
    }

    func setPollingVisible(_ visible: Bool) {
        pollingTask?.cancel()
        pollingTask = nil
        guard client != nil else { return }
        let configuredCadence = UserDefaults.standard.double(forKey: "pollingCadence")
        let hiddenCadence = configuredCadence > 0 ? min(max(configuredCadence, 15), 60) : 30
        let interval: Duration = visible ? .seconds(5) : .seconds(hiddenCadence)
        pollingTask = Task { [weak self] in
            await self?.refreshRuntimeRepairState()
            if self?.runtimeRepairRequired == false {
                await self?.refreshRemote()
                await self?.refreshBackupOperations()
            }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                await self?.refreshRuntimeRepairState(forceRefresh: true)
                if self?.runtimeRepairRequired == false {
                    await self?.refreshRemote()
                    await self?.refreshBackupOperations()
                }
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func openTerminal(for id: Workspace.ID) {
        guard requireActionSafety(for: id, action: .terminal, operation: terminalActionTitle) else { return }
        guard let workspace = workspaces.first(where: { $0.id == id }),
              workspace.state == .running else {
            lastError = "\(terminalActionTitle) requires a freshly observed running workspace."
            return
        }
        guard let client else {
            lastError = "MSW is unavailable in fixture mode."
            return
        }
        applicationPreferences.refreshInstalledApplications()
        guard let terminal = applicationPreferences.resolvedTerminal else {
            lastError = TerminalLauncher.LaunchError.noDefaultTerminal.localizedDescription
            return
        }
        Task { [weak self] in
            guard let executable = await client.executableURL() else {
                self?.runtimeRepairRequired = true
                self?.lastError = "The MSW executable is unavailable. Repair the toolchain and retry."
                return
            }
            do {
                let executableSearchPath = await client.executableSearchPath()
                try await TerminalLauncher().open(
                    applicationURL: terminal.url,
                    executableURL: executable,
                    workspaceID: id.rawValue,
                    executableSearchPath: executableSearchPath
                )
            } catch {
                self?.lastError = error.localizedDescription
            }
        }
    }

    func openEditor(for id: Workspace.ID, path: String = ".") async -> String? {
        guard requireActionSafety(for: id, action: .editor, operation: editorActionTitle) else {
            return lastError
        }
        guard let workspace = workspaces.first(where: { $0.id == id }),
              workspace.state == .running else {
            lastError = "\(editorActionTitle) requires a freshly observed running workspace."
            return lastError
        }
        let editor: SystemApplication
        do {
            applicationPreferences.refreshInstalledApplications()
            editor = try SourceEditorLauncher().validate(application: applicationPreferences.resolvedSourceEditor)
        } catch {
            lastError = error.localizedDescription
            return lastError
        }
        guard let client else {
            let message = "MSW is unavailable in fixture mode."
            lastError = message
            return message
        }
        do {
            let envelope = try await client.editorTarget(workspace: id.rawValue, path: path)
            guard let target = envelope.result else {
                throw MSWClientError.missingResult(command: "editor-target")
            }
            try await SourceEditorLauncher().open(application: editor, target: target)
            return nil
        } catch {
            noteRuntimeRepairFailure(error)
            lastError = error.localizedDescription
            return lastError
        }
    }

    func directories(
        for id: Workspace.ID,
        path: String = ".",
        query: String? = nil
    ) async throws -> MSWDirectoryResponse {
        guard let workspace = workspaces.first(where: { $0.id == id }) else {
            throw MSWClientError.unavailable(
                "The selected workspace is unavailable. Refresh workspace state and select a valid workspace."
            )
        }
        let availability = actionAvailability(for: workspace, action: .editor)
        guard availability.isAllowed else {
            throw MSWClientError.unavailable(
                [availability.reason, availability.recovery]
                    .compactMap { $0 }
                    .joined(separator: " ")
            )
        }
        let normalizedQuery = query?.isEmpty == false ? query : nil
        let cacheKey = DirectoryCacheKey(
            workspace: id,
            path: path,
            query: normalizedQuery
        )
        if let cached = directoryCache[cacheKey],
           Date().timeIntervalSince(cached.cachedAt) < 60 {
            return cached.response
        }
        if client == nil, !directoryFixture.isEmpty {
            let fixture = directoryFixture.first { value in
                value.workspace == id.rawValue && value.path == path && value.query == query
            } ?? directoryFixture.first { value in
                value.workspace == id.rawValue && value.path == path && value.query == nil
            }.map { value in
                guard let query, !query.isEmpty else { return value }
                return MSWDirectoryResponse(
                    workspace: value.workspace,
                    path: value.path,
                    query: query,
                    entries: value.entries.filter {
                        $0.name.localizedCaseInsensitiveContains(query) ||
                            $0.path.localizedCaseInsensitiveContains(query)
                    },
                    truncated: false
                )
            }
            guard let fixture else {
                throw MSWClientError.unavailable("The requested fixture folder is unavailable.")
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-test-folder-loading-skeleton") {
                try await Task.sleep(for: .seconds(3))
            }
            directoryCache[cacheKey] = CachedDirectoryResponse(
                response: fixture,
                cachedAt: Date()
            )
            return fixture
        }
        guard let client else {
            throw MSWClientError.unavailable("Folder browsing is unavailable in fixture mode.")
        }
        let response: MSWEnvelope<MSWDirectoryResponse>
        do {
            response = try await client.directories(
                workspace: id.rawValue,
                path: path,
                query: normalizedQuery
            )
        } catch {
            noteRuntimeRepairFailure(error)
            throw error
        }
        guard let result = response.result else {
            throw MSWClientError.missingResult(
                command: normalizedQuery == nil ? "directory-list" : "directory-search"
            )
        }
        directoryCache[cacheKey] = CachedDirectoryResponse(
            response: result,
            cachedAt: Date()
        )
        return result
    }

    func installDirectoryUITestFixture() {
        guard let index = workspaces.firstIndex(where: { $0.id == .dev }) else { return }
        workspaces[index].state = .running
        workspaces[index].freshness = .fresh
        workspaces[index].canOpenTerminal = true
        workspaces[index].networkHost = "dev.msw.test"
        workspaces[index].serverCapabilities = MSWActionCapabilities(
            canStart: false,
            canStop: true,
            canRestart: true,
            canOpenTerminal: true,
            canPush: false
        )
        workspaces[index].nextAction = "Open Terminal"
        portsSnapshot = MSWPortsResponse(
            workspace: "all",
            workspaces: [
                .init(
                    workspace: "dev",
                    lifecycle: .running,
                    host: "dev.msw.test",
                    listeningState: .known,
                    ports: [
                        .init(port: "3000", configured: true, listening: true),
                        .init(port: "5173", configured: true, listening: false),
                        .init(port: "8080", configured: true, listening: false)
                    ]
                ),
                .init(
                    workspace: "playgrounds",
                    lifecycle: .stopped,
                    host: "playgrounds.msw.test",
                    listeningState: .known,
                    ports: [
                        .init(port: "3000", configured: true, listening: false),
                        .init(port: "5173", configured: true, listening: false),
                        .init(port: "8080", configured: true, listening: false)
                    ]
                ),
                .init(
                    workspace: "personal",
                    lifecycle: .stopped,
                    host: "personal.msw.test",
                    listeningState: .known,
                    ports: [
                        .init(port: "3000", configured: true, listening: false),
                        .init(port: "5173", configured: true, listening: false),
                        .init(port: "8080", configured: true, listening: false)
                    ]
                )
            ],
            freshness: .fresh
        )
        repositoriesByWorkspace["dev"] = MSWRepositoriesResponse(
            workspace: "dev",
            repositories: [
                MSWRepositorySnapshot(
                    path: "ui-playground-repo",
                    canonicalRemote: nil,
                    branch: "main",
                    upstreamRef: nil,
                    worktreeState: .localChanges,
                    destinationState: .unavailable,
                    stagedCount: 0,
                    modifiedCount: 0,
                    deletedCount: 0,
                    untrackedCount: 1,
                    aheadCount: 0,
                    behindCount: 0,
                    localCommit: "5dce308cb96398eb220378edd913ce1c1167c7ac",
                    remoteCommit: nil,
                    pushability: .blocked,
                    needsStart: false,
                    freshness: .fresh,
                    checkedAt: Date()
                )
            ],
            needsStart: false,
            freshness: .fresh,
            worktreeStatusIncluded: true,
            notice: nil
        )
        logsByWorkspace = [
            "dev": MSWLogsResponse(
                workspace: "dev",
                available: true,
                lifecycle: .running,
                freshness: .fresh,
                reason: nil,
                lines: [
                    MSWLogEntry(
                        workspace: "dev",
                        observedAt: Date(timeIntervalSince1970: 1_786_118_400),
                        message: "Development service ready",
                        safeForDisplay: true
                    ),
                    MSWLogEntry(
                        workspace: "dev",
                        observedAt: Date(timeIntervalSince1970: 1_786_118_403),
                        message: #"{"event":"build","level":"info","ok":true}"#,
                        safeForDisplay: true
                    )
                ]
            ),
            "playgrounds": MSWLogsResponse(
                workspace: "playgrounds",
                available: true,
                lifecycle: .stopped,
                freshness: .fresh,
                reason: nil,
                lines: [
                    MSWLogEntry(
                        workspace: "playgrounds",
                        observedAt: Date(timeIntervalSince1970: 1_786_118_401),
                        message: "Playground task completed",
                        safeForDisplay: true
                    )
                ]
            ),
            "personal": MSWLogsResponse(
                workspace: "personal",
                available: true,
                lifecycle: .stopped,
                freshness: .fresh,
                reason: nil,
                lines: [
                    MSWLogEntry(
                        workspace: "personal",
                        observedAt: Date(timeIntervalSince1970: 1_786_118_402),
                        message: "Personal task completed",
                        safeForDisplay: true
                    )
                ]
            )
        ]
        directoryFixture = [
            MSWDirectoryResponse(
                workspace: "dev",
                path: ".",
                query: nil,
                entries: [
                    .init(
                        name: "Projects",
                        path: "Projects",
                        kind: "directory",
                        hasChildren: true,
                        children: [
                            .init(name: "Demo", path: "Projects/Demo", kind: "directory")
                        ]
                    ),
                    .init(name: "Scratch", path: "Scratch", kind: "directory")
                ],
                truncated: true
            ),
            MSWDirectoryResponse(
                workspace: "dev",
                path: "Projects",
                query: nil,
                entries: [.init(name: "Demo", path: "Projects/Demo", kind: "directory")],
                truncated: false
            ),
            MSWDirectoryResponse(
                workspace: "dev",
                path: "Scratch",
                query: nil,
                entries: [],
                truncated: false
            )
        ]
    }

    func nextActionTitle(for workspace: Workspace) -> String {
        workspace.nextAction == "Open Terminal" ? terminalActionTitle : workspace.nextAction
    }

    func openSite(for id: Workspace.ID, port: String = "3000") {
        guard requireActionSafety(for: id, action: .site, operation: "Open Site") else { return }
        guard let workspace = workspaces.first(where: { $0.id == id }),
              workspace.state == .running,
              let expectedHost = workspace.networkHost else {
            lastError = "Open Site requires a freshly observed running workspace."
            return
        }
        guard let client else {
            lastError = "MSW is unavailable in fixture mode."
            return
        }
        Task { [weak self] in
            do {
                let envelope = try await client.url(workspace: id.rawValue, port: port)
                guard let result = envelope.result,
                      let url = Self.validatedWorkspaceURL(
                        result.url,
                        expectedWorkspace: id.rawValue,
                        responseWorkspace: result.workspace,
                        expectedHost: expectedHost,
                        expectedPort: port,
                        expectedScheme: "http"
                      ) else {
                    throw MSWClientError.malformedJSON(command: "url")
                }
                guard NSWorkspace.shared.open(url) else {
                    throw MSWClientError.unavailable("macOS could not open the validated workspace URL.")
                }
            } catch {
                self?.noteRuntimeRepairFailure(error)
                self?.lastError = error.localizedDescription
            }
        }
    }


    func refreshRemote() async {
        _ = await refreshRemoteResult()
    }

    private func refreshRemoteResult() async -> RefreshResult {
        guard client != nil else { return .failed }
        refreshGeneration += 1
        return await refreshRemote(generation: refreshGeneration)
    }

    private func refreshRemote(generation: Int) async -> RefreshResult {
        guard let client else { return .failed }
        do {
            let response = try await client.state()
            guard generation == refreshGeneration else { return .superseded }
            guard let state = response.result else { throw MSWClientError.missingResult(command: "state") }
            let previousWorkspaces = workspaces
            let reconciledOperations = apply(state: state, observedAt: response.observedAt)
            let stateChanged = workspaces != previousWorkspaces
            if lastError != nil {
                lastError = nil
            }
            consecutiveRefreshFailures = 0
            sustainedUnavailableNotified = false
            lastRecovery = nil
            if stateChanged {
                let activity = MSWActivity(
                    id: UUID(), createdAt: Date(), kind: .observation, title: "State changed",
                    detail: "MSW returned updated state for \(state.workspaces.count) workspaces.",
                    workspace: nil, isFailure: false
                )
                await append(activity)
            }
            for operation in reconciledOperations {
                let succeeded = operation.outcome == .succeeded
                let activity = MSWActivity(
                    id: UUID(), createdAt: Date(), kind: succeeded ? .operation : .failure,
                    title: succeeded ? "\(operation.action.capitalized) verified" : "\(operation.action.capitalized) outcome unknown",
                    detail: operation.message, workspace: operation.workspace, isFailure: !succeeded
                )
                await append(activity)
            }
            return .applied(state)
        } catch {
            guard generation == refreshGeneration else { return .superseded }
            noteRuntimeRepairFailure(error)
            lastError = error.localizedDescription
            lastRecovery = recoveryContext(for: error, fallbackRecovery: "Retry the observation or run diagnostics.")
            markStateStale()
            consecutiveRefreshFailures += 1
            markVerifyingOperationsUnknown(reason: "A fresh state observation was unavailable, so the final outcome could not be verified.")
            if consecutiveRefreshFailures >= 2, !sustainedUnavailableNotified {
                sustainedUnavailableNotified = true
                emitNotification(
                    kind: .sustainedUnavailability,
                    workspace: nil,
                    title: "MSW remains unavailable",
                    message: "Workspace state could not be observed after repeated attempts.",
                    recovery: lastRecovery?.recovery ?? "Retry or run diagnostics.",
                    deepLink: "msw-monitor://diagnostics"
                )
            }
            let activity = MSWActivity(
                id: UUID(), createdAt: Date(), kind: .failure, title: "Refresh failed",
                detail: error.localizedDescription, workspace: nil, isFailure: true
            )
            await append(activity)
            return .failed
        }
    }

    func start(_ id: Workspace.ID) {
        runLifecycle(.start, id: id)
    }

    func stop(_ id: Workspace.ID) {
        runLifecycle(.stop, id: id)
    }

    func restart(_ id: Workspace.ID) {
        runLifecycle(.restart, id: id)
    }

    func confirmPendingLifecycle() {
        guard let action = pendingLifecycleAction,
              let workspace = pendingLifecycleWorkspace,
              let plan = pendingLifecyclePlan else { return }
        guard plan.workspace == workspace.rawValue,
              plan.action == action.rawValue,
              requireActionSafety(for: workspace, action: .lifecycle(action), operation: action.rawValue.capitalized) else {
            cancelPendingLifecycle()
            return
        }
        pendingLifecycleAction = nil
        pendingLifecycleWorkspace = nil
        pendingLifecyclePlan = nil
        runLifecycle(action, id: workspace, confirmation: plan.confirmationPhrase, reviewedPlan: plan)
    }

    func cancelPendingLifecycle() {
        clearPendingLifecyclePlan()
    }

    private func clearPendingLifecyclePlan() {
        pendingLifecycleAction = nil
        pendingLifecycleWorkspace = nil
        pendingLifecyclePlan = nil
    }

    private func beginDetailRequest(clearsError: Bool = true) -> Int {
        detailRequestGeneration += 1
        isDetailLoading = true
        if clearsError {
            detailError = nil
        }
        return detailRequestGeneration
    }

    private func finishDetailRequest(_ generation: Int) {
        guard generation == detailRequestGeneration else { return }
        isDetailLoading = false
    }

    private static func protocolFailure(_ error: any Error, hasCode code: String) -> Bool {
        guard let clientError = error as? MSWClientError,
              case .protocolFailure(let protocolError) = clientError else {
            return false
        }
        return protocolError.code == code
    }


    func loadRepositories(for id: Workspace.ID, clearsError: Bool = true) {
        loadRepositories(for: [id], clearsError: clearsError)
    }

    func loadRepositories(for ids: [Workspace.ID], clearsError: Bool = true) {
        guard !ids.isEmpty, let operationService else { return }
        let workspaceNames = Set(ids.map(\.rawValue))
        repositoryLoadingWorkspaces.formUnion(workspaceNames)
        repositoryUnavailableWorkspaces.subtract(workspaceNames)
        let request = beginDetailRequest(clearsError: clearsError)
        Task { [weak self] in
            var loaded: [String: MSWRepositoriesResponse] = [:]
            var failed: Set<String> = []
            var failureMessage: String?
            for id in ids {
                do {
                    loaded[id.rawValue] = try await operationService.repositories(
                        workspace: id.rawValue
                    )
                } catch {
                    self?.noteRuntimeRepairFailure(error)
                    failed.insert(id.rawValue)
                    failureMessage = failureMessage ?? error.localizedDescription
                }
            }
            guard let self, request == self.detailRequestGeneration else { return }
            self.repositoryLoadingWorkspaces.subtract(workspaceNames)
            self.repositoryUnavailableWorkspaces.formUnion(failed)
            self.repositoryUnavailableWorkspaces.subtract(loaded.keys)
            for (workspace, result) in loaded {
                self.repositoriesByWorkspace[workspace] = result
            }
            self.detailError = failureMessage
            self.finishDetailRequest(request)
        }
    }


    func reviewPush(for repository: MSWRepositorySnapshot, workspace id: Workspace.ID) {
        guard let operationService else {
            detailError = "Repository pushes are unavailable in fixture mode."
            return
        }
        guard requireActionSafety(for: id, action: .push, operation: "Push", detail: true) else { return }
        let request = beginDetailRequest()
        Task { [weak self] in
            do {
                let plan = try await operationService.pushPlan(
                    workspace: id.rawValue,
                    repositories: [repository.path]
                )
                guard let self, request == self.detailRequestGeneration else { return }
                guard self.requireActionSafety(for: id, action: .push, operation: "Push", detail: true) else {
                    self.finishDetailRequest(request)
                    return
                }
                self.pendingPushPlan = plan
            } catch {
                guard let self, request == self.detailRequestGeneration else { return }
                self.noteRuntimeRepairFailure(error)
                self.detailError = error.localizedDescription
            }
            self?.finishDetailRequest(request)
        }
    }

    func confirmPendingPush(confirmation: String) {
        guard let operationService, let plan = pendingPushPlan else { return }
        guard let workspace = Workspace.ID(rawValue: plan.workspace) else {
            detailError = "The pending push workspace is invalid."
            pendingPushPlan = nil
            return
        }
        guard requireActionSafety(for: workspace, action: .push, operation: "Push", detail: true) else {
            pendingPushPlan = nil
            return
        }
        guard confirmation == plan.confirmationPhrase else {
            detailError = "Type the exact confirmation phrase before pushing."
            return
        }
        pendingPushPlan = nil
        isDetailLoading = true
        detailError = nil
        beginOperation(kind: .push, workspace: workspace.rawValue, action: "push", message: "Pushing reviewed changes.")
        Task { [weak self] in
            guard let self else { return }
            guard self.requireActionSafety(for: workspace, action: .push, operation: "Push", detail: true) else {
                self.isDetailLoading = false
                return
            }
            do {
                let result = try await operationService.applyPushPlan(plan, confirmation: confirmation)
                self.maintenanceMessage = "Pushed \(result.repositoryPath) from \(result.workspace)."
                self.finishOperation(
                    key: self.operationKey(kind: .push, workspace: workspace.rawValue),
                    outcome: result.reconciled ? .succeeded : .unknown,
                    message: result.reconciled ? result.outcome : "The push returned without authoritative reconciliation."
                )
                self.loadRepositories(for: workspace)
                await self.refreshRemote()
            } catch {
                self.detailError = error.localizedDescription
                self.isDetailLoading = false
                self.failOperation(kind: .push, workspace: workspace.rawValue, action: "push", error: error)
            }
        }
    }

    func cancelPendingPush() {
        pendingPushPlan = nil
    }

    func loadPorts(for id: Workspace.ID? = nil, clearsError: Bool = true) {
        guard let operationService else { return }
        let request = beginDetailRequest(clearsError: clearsError)
        Task { [weak self] in
            do {
                let result = try await operationService.ports(workspace: id?.rawValue)
                guard let self, request == self.detailRequestGeneration else { return }
                self.portsSnapshot = result
                self.detailError = nil
            } catch {
                guard let self, request == self.detailRequestGeneration else { return }
                self.noteRuntimeRepairFailure(error)
                self.detailError = error.localizedDescription
            }
            self?.finishDetailRequest(request)
        }
    }

    func loadGitHubState() {
        if accessMode == .local {
            guard let provider else {
                detailError = "GitHub state is unavailable in fixture mode."
                return
            }
            let request = beginDetailRequest()
            Task { [weak self] in
                do {
                    let catalog = try await provider.loadCatalog()
                    let policy = await provider.currentPolicy()
                    guard let self, request == self.detailRequestGeneration else { return }
                    self.githubSnapshot = Self.localGitHubSnapshot(
                        policy: policy,
                        catalog: catalog,
                        workspaceIDs: self.configuredWorkspaceIDs
                    )
                } catch {
                    guard let self, request == self.detailRequestGeneration else { return }
                    self.noteRuntimeRepairFailure(error)
                    self.detailError = error.localizedDescription
                }
                self?.finishDetailRequest(request)
            }
            return
        }
        guard let operationService else { detailError = "GitHub state is unavailable in fixture mode."; return }
        let request = beginDetailRequest()
        Task { [weak self] in
            do {
                let result = try await operationService.githubState()
                guard let self, request == self.detailRequestGeneration else { return }
                self.githubSnapshot = result
            } catch {
                guard let self, request == self.detailRequestGeneration else { return }
                self.noteRuntimeRepairFailure(error)
                self.detailError = error.localizedDescription
            }
            self?.finishDetailRequest(request)
        }
    }

    /// Builds the Detail GitHub snapshot from the policy file (single source
    /// of truth) plus the CLI-reported credential/account presence.
    static func localGitHubSnapshot(
        policy: GitHubPolicyFile?,
        catalog: GitHubCatalog,
        workspaceIDs: [Workspace.ID] = Workspace.ID.fixtureDefaults
    ) -> MSWGitHubStateResponse {
        let workspaces = workspaceIDs.map { id in
            let workspace = policy?.workspaces[id.rawValue]
            let repos = workspace?.repos ?? []
            let hasWrite = repos.contains { $0.mode == .readWrite }
            let accessMode: String
            if hasWrite {
                accessMode = "read-write"
            } else if repos.isEmpty {
                accessMode = "none"
            } else {
                accessMode = "read-only"
            }
            return MSWGitHubWorkspaceState(
                workspace: id.rawValue,
                provider: "local-policy",
                configured: workspace != nil,
                accessMode: accessMode,
                verificationRepository: nil,
                accountLogin: catalog.account?.login,
                installationId: nil,
                accessExpiresAt: nil,
                refreshExpiresAt: nil,
                needsRestart: false,
                quarantined: false,
                repos: repos.map { MSWGitHubPolicyRepo(canonical: $0.canonical, mode: $0.mode) },
                policyUpdatedAt: policy?.updatedAt,
                hostCredential: catalog.hostCredentialPresent ? "present" : "missing"
            )
        }
        return MSWGitHubStateResponse(workspaces: workspaces)
    }

    func loadLogs(for id: Workspace.ID, clearsError: Bool = true) {
        loadLogs(for: [id], clearsError: clearsError)
    }

    func loadLogs(for ids: [Workspace.ID], clearsError: Bool = true) {
        let requested = Array(Set(ids)).sorted { $0.rawValue < $1.rawValue }
        guard !requested.isEmpty else { return }
        guard let operationService else {
            logsUnavailableWorkspaces.formUnion(requested.map(\.rawValue))
            return
        }
        let pending = requested.filter { !logsUnavailableWorkspaces.contains($0.rawValue) }
        guard !pending.isEmpty else { return }

        let request = beginDetailRequest(clearsError: clearsError)
        Task { [weak self] in
            var snapshots: [String: MSWLogsResponse] = [:]
            var unavailable: Set<String> = []
            var firstError: String?
            for id in pending {
                do {
                    snapshots[id.rawValue] = try await operationService.logs(workspace: id.rawValue)
                } catch {
                    self?.noteRuntimeRepairFailure(error)
                    if Self.protocolFailure(error, hasCode: "MSW_LOGS_UNAVAILABLE") {
                        unavailable.insert(id.rawValue)
                    } else if firstError == nil {
                        firstError = error.localizedDescription
                    }
                }
            }

            guard let self, request == self.detailRequestGeneration else { return }
            for (workspace, snapshot) in snapshots {
                self.logsByWorkspace[workspace] = snapshot
                self.logsUnavailableWorkspaces.remove(workspace)
            }
            for workspace in unavailable {
                self.logsByWorkspace.removeValue(forKey: workspace)
                self.logsUnavailableWorkspaces.insert(workspace)
            }
            self.detailError = firstError
            self.finishDetailRequest(request)
        }
    }

    func configureSystemHealthChecks(using coordinator: (any MSWBootstrapCoordinating)?) {
        systemHealthGeneration &+= 1
        systemHealthCoordinator = coordinator
        systemHealthChecks = []
        isSystemHealthLoading = false
    }

    func runSystemHealthChecks() {
        guard let systemHealthCoordinator, !isSystemHealthLoading else { return }
        systemHealthGeneration &+= 1
        let generation = systemHealthGeneration
        isSystemHealthLoading = true
        Task { [weak self] in
            let checks = await systemHealthCoordinator.preflight()
            guard let self, generation == self.systemHealthGeneration else { return }
            self.systemHealthChecks = checks
            self.isSystemHealthLoading = false
        }
    }

    func installBackupUITestFixture(
        sourceAllocatedBytes: Int64 = 16_000_000_000,
        archiveEstimate: MSWBackupEstimate? = nil,
        destination: URL? = nil,
        resultScenario: BackupUITestResultScenario? = nil
    ) {
        backupPreviewFixtureSourceAllocatedBytes = sourceAllocatedBytes
        backupPreviewFixtureArchiveEstimate = archiveEstimate
        backupPreviewFixtureDestination = destination
        backupUITestResultScenario = resultScenario
    }

    func installRuntimeRepairUITestFixture() {
        detailError = MSWClientError.invalidExecutable.localizedDescription
        backupError = MSWClientError.invalidExecutable.localizedDescription
        let now = Date()
        let error = MSWBackupOperationErrorResponse(
            code: "MSW_RUNTIME_UNAVAILABLE",
            message: MSWClientError.invalidExecutable.localizedDescription,
            recovery: "Use Repair… to reinstall the bundled runtime.",
            retryable: false
        )
        backupOperations = [MSWBackupOperation(
            id: "runtime-repair-fixture", requestKey: "runtime-repair-fixture",
            state: .failed, phase: .failed, message: error.message,
            destination: URL(fileURLWithPath: "/tmp", isDirectory: true),
            startedAt: now, updatedAt: now, completedAt: now, elapsedSeconds: 0,
            ownerPID: nil, ownerProcessState: "fixture-exited", sourceAllocatedBytes: 1,
            archiveEstimate: nil, processedBytes: 0, writtenBytes: 0,
            throughputBytesPerSecond: 0, totalBytes: nil, etaSeconds: nil,
            result: nil, error: error, warnings: []
        )]
    }

    func installConcurrentBackupReattachmentFixture(
        destination: URL,
        advanced: Bool = false
    ) {
        installBackupUITestFixture(destination: destination)
        let now = Date()
        let completedResult = MSWBackupResult(
            archive: destination.appendingPathComponent("fixture-completed.tar.zst"),
            archiveBytes: 3_145_728, completedAt: now.addingTimeInterval(-2),
            checksum: destination.appendingPathComponent("fixture-completed.tar.zst.sha256"),
            stoppedWorkspaces: [], restartedWorkspaces: []
        )
        let completed = MSWBackupOperation(
            id: "fixture-completed-0001", requestKey: "fixture-completed-key",
            state: .completed, phase: .completed, message: "Fixture archive and checksum completed.",
            destination: destination, startedAt: now.addingTimeInterval(-12),
            updatedAt: now.addingTimeInterval(-2), completedAt: now.addingTimeInterval(-2),
            elapsedSeconds: 10, ownerPID: nil, ownerProcessState: "fixture-exited",
            sourceAllocatedBytes: 12_000_000, archiveEstimate: nil,
            processedBytes: 12_000_000, writtenBytes: completedResult.archiveBytes,
            throughputBytesPerSecond: 1_200_000, totalBytes: nil, etaSeconds: nil,
            result: completedResult, error: nil, warnings: []
        )
        let active = MSWBackupOperation(
            id: "fixture-active-0002", requestKey: "fixture-active-key",
            state: .running, phase: .archiveWriting,
            message: advanced
                ? "Fixture counters advanced after reattachment."
                : "Fixture reattached to CLI-owned operation.",
            destination: destination, startedAt: now.addingTimeInterval(-6), updatedAt: now,
            completedAt: nil, elapsedSeconds: 6, ownerPID: 4242,
            ownerProcessState: "fixture-running", sourceAllocatedBytes: 24_000_000,
            archiveEstimate: MSWBackupEstimate(lowerBytes: 4_000_000, upperBytes: 8_000_000,
                basisRatio: 0.25, changedSourceRatio: 1.1, provenance: "fixture same-scope history"),
            processedBytes: advanced ? 10_485_760 : 6_291_456,
            writtenBytes: advanced ? 3_145_728 : 2_097_152,
            throughputBytesPerSecond: 1_048_576, totalBytes: nil, etaSeconds: nil,
            result: nil, error: nil, warnings: []
        )
        backupOperations = [active, completed]
    }

    func backupUITestDestinationIfAvailable() -> URL? {
        guard backupPreviewFixtureSourceAllocatedBytes != nil else { return nil }
        return backupPreviewFixtureDestination
    }

    func installMalformedBackupUITestFixture() {
        backupError = "MSW returned malformed backup data for backup-list."
    }

    func prepareBackup(to directory: URL) async -> MSWBackupPreview? {
        guard !isMaintenanceOperationInFlight, !isBackupPreviewLoading else { return nil }
        backupError = nil
        pendingBackupPreview = nil
        if let sourceAllocatedBytes = backupPreviewFixtureSourceAllocatedBytes {
            let preview = MSWBackupPreview(
                destination: directory,
                sourceAllocatedBytes: sourceAllocatedBytes,
                archiveEstimate: backupPreviewFixtureArchiveEstimate,
                runningWorkspaces: workspaces.filter { $0.state == .running }.map(\.id.rawValue)
            )
            pendingBackupPreview = preview
            return preview
        }
        guard let diagnostics else {
            backupError = "Backups are unavailable in fixture mode."
            return nil
        }
        isBackupPreviewLoading = true
        defer { isBackupPreviewLoading = false }
        do {
            let preview = try await diagnostics.previewBackup(to: directory)
            pendingBackupPreview = preview
            return preview
        } catch {
            noteRuntimeRepairFailure(error)
            backupError = backupErrorMessage(error)
            return nil
        }
    }

    func cancelPendingBackup() {
        pendingBackupPreview = nil
    }

    func createBackup(to directory: URL) {
        pendingBackupPreview = nil
        maintenanceMessage = nil
        backupError = nil
        if let scenario = backupUITestResultScenario {
            let now = Date()
            let id = UUID().uuidString.lowercased()
            let base = MSWBackupOperation(
                id: id, requestKey: "ui-fixture-\(id)", state: .running, phase: .archiveWriting,
                message: "Fixture archive pipeline is advancing.", destination: directory,
                startedAt: now.addingTimeInterval(-4), updatedAt: now, completedAt: nil,
                elapsedSeconds: 4, ownerPID: 4242, ownerProcessState: "fixture-running",
                sourceAllocatedBytes: 16_000_000_000, archiveEstimate: nil,
                processedBytes: 4_194_304, writtenBytes: 1_048_576,
                throughputBytesPerSecond: 1_048_576, totalBytes: nil, etaSeconds: nil,
                result: nil, error: nil, warnings: []
            )
            switch scenario {
            case .running:
                backupOperations.insert(base, at: 0)
            case .success, .partial:
                let result = MSWBackupResult(
                    archive: directory.appendingPathComponent("microsandbox-all-20260826-120000.tar.zst"),
                    archiveBytes: 7_340_032,
                    completedAt: Date(timeIntervalSince1970: 1_787_745_600),
                    checksum: nil,
                    stoppedWorkspaces: scenario == .partial ? ["dev", "personal"] : ["dev"],
                    restartedWorkspaces: ["dev"]
                )
                backupOperations.insert(MSWBackupOperation(
                    id: id, requestKey: base.requestKey, state: .completed, phase: .completed,
                    message: "Fixture archive, checksum, and result completed.", destination: directory,
                    startedAt: base.startedAt, updatedAt: result.completedAt, completedAt: result.completedAt,
                    elapsedSeconds: 8, ownerPID: nil, ownerProcessState: "fixture-exited",
                    sourceAllocatedBytes: base.sourceAllocatedBytes, archiveEstimate: nil,
                    processedBytes: 16_000_000_000, writtenBytes: result.archiveBytes,
                    throughputBytesPerSecond: 2_000_000_000, totalBytes: nil, etaSeconds: nil,
                    result: result, error: nil, warnings: []
                ), at: 0)
                maintenanceMessage = result.workspacesNeedingRestart.isEmpty
                    ? "Archive created."
                    : "Archive created. Restart required for: \(result.workspacesNeedingRestart.joined(separator: ", "))."
            case .failure:
                let operationError = MSWBackupOperationErrorResponse(
                    code: "MSW_BACKUP_FAILED", message: "The fixture backup could not be created.",
                    recovery: "Retry the fixture with a distinct request key.", retryable: true
                )
                backupOperations.insert(MSWBackupOperation(
                    id: id, requestKey: base.requestKey, state: .failed, phase: .failed,
                    message: operationError.message, destination: directory, startedAt: base.startedAt,
                    updatedAt: now, completedAt: now, elapsedSeconds: 4, ownerPID: nil,
                    ownerProcessState: "fixture-exited", sourceAllocatedBytes: base.sourceAllocatedBytes,
                    archiveEstimate: nil, processedBytes: base.processedBytes, writtenBytes: base.writtenBytes,
                    throughputBytesPerSecond: base.throughputBytesPerSecond, totalBytes: nil, etaSeconds: nil,
                    result: nil, error: operationError, warnings: []
                ), at: 0)
            }
            return
        }
        guard let diagnostics else {
            backupError = "Backups are unavailable in fixture mode."
            return
        }
        isDetailLoading = true
        let requestKey = UUID().uuidString.lowercased()
        Task { [weak self] in
            do {
                let operation = try await diagnostics.startBackup(to: directory, requestKey: requestKey)
                self?.upsertBackupOperation(operation)
            } catch {
                self?.noteRuntimeRepairFailure(error)
                self?.backupError = self?.backupErrorMessage(error)
            }
            self?.isDetailLoading = false
        }
    }

    func refreshBackupOperations() async {
        guard let diagnostics else { return }
        do {
            let operations = try await diagnostics.listBackups()
            backupOperations = operations.sorted { $0.startedAt > $1.startedAt }
            if let newest = backupOperations.first, let result = newest.result {
                maintenanceMessage = result.workspacesNeedingRestart.isEmpty
                    ? "Archive created."
                    : "Archive created. Restart required for: \(result.workspacesNeedingRestart.joined(separator: ", "))."
            }
            backupError = nil
        } catch {
            noteRuntimeRepairFailure(error)
            backupError = backupErrorMessage(error)
        }
    }

    private func noteRuntimeRepairFailure(_ error: Error) {
        if isRuntimeRepairFailure(error) {
            // An operation-level protocol failure is newer evidence than any
            // runtime probe already in flight. Supersede that probe so its
            // stale result cannot hide the repair warning.
            runtimeRepairRefreshGeneration &+= 1
            runtimeRepairFailureRefreshTask?.cancel()
            runtimeRepairFailureRefreshTask = nil
            runtimeRepairRequired = true
            return
        }
        guard !runtimeRepairRequired, !Self.isCancellation(error), client != nil else { return }
        runtimeRepairFailureRefreshTask?.cancel()
        runtimeRepairFailureRefreshTask = Task { [weak self] in
            await self?.refreshRuntimeRepairState(forceRefresh: true)
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        return (error as? MSWClientError) == .cancelled
    }

    private func isRuntimeRepairFailure(_ error: Error) -> Bool {
        RuntimeRepairIssueClassifier.isRepairRelated(error)
    }

    private func backupErrorMessage(_ error: Error) -> String {
        if let clientError = error as? MSWClientError,
           case .malformedJSON(let command) = clientError,
           ["backup-preview", "backup-start", "backup-list", "backup-status"].contains(command) {
            return "MSW returned malformed backup data for \(command)."
        }
        return error.localizedDescription
    }

    private func upsertBackupOperation(_ operation: MSWBackupOperation) {
        backupOperations.removeAll { $0.id == operation.id }
        backupOperations.append(operation)
        backupOperations.sort { $0.startedAt > $1.startedAt }
    }

    func refreshBackupWorkspaceState() {
        guard !isMaintenanceOperationInFlight else { return }
        refresh()
    }

    func restoreBackup(archive: URL, confirmation: String) {
        guard let diagnostics else {
            detailError = "Restore is unavailable in fixture mode."
            return
        }
        guard confirmation == "RESTORE" else {
            detailError = "Type RESTORE exactly before replacing workspace state."
            return
        }
        guard !isMaintenanceOperationInFlight else {
            detailError = "Another backup or restore is already in progress. Wait for its outcome before starting a new maintenance operation."
            return
        }
        isDetailLoading = true
        detailError = nil
        beginOperation(kind: .restore, workspace: nil, action: "restore", message: "Restoring backup.")
        Task { [weak self] in
            do {
                try await diagnostics.restore(archive: archive, confirmation: confirmation)
                self?.maintenanceMessage = "Restore completed. Refreshing workspace state."
                self?.markOperationVerifying(kind: .restore, workspace: nil, message: "Verifying restored workspace state.")
                let refreshResult = await self?.refreshRemoteResult()
                guard let self else { return }
                let operationKey = self.operationKey(kind: .restore, workspace: nil)
                switch refreshResult ?? .superseded {
                case .applied(let state):
                    guard self.restoreStateIsVerified(state) else {
                        let message = "Restore completed, but the follow-up observation did not prove that every workspace is fresh and stopped. Review Activity before retrying."
                        self.detailError = message
                        self.markOperationUnknown(key: operationKey, reason: message)
                        break
                    }
                    self.finishOperation(
                        key: operationKey,
                        outcome: .succeeded,
                        message: "Restore was followed by a successful state observation."
                    )
                case .failed:
                    let message = self.lastError ?? "Restore completed, but the restored state could not be verified."
                    self.detailError = message
                    self.markOperationUnknown(key: operationKey, reason: "The restore completed, but a fresh state observation was unavailable.")
                case .superseded:
                    let message = "Restore completed, but a newer state observation superseded its verification. Review Activity before retrying."
                    self.detailError = message
                    self.markOperationUnknown(key: operationKey, reason: message)
                }
            } catch {
                self?.detailError = error.localizedDescription
                self?.failOperation(kind: .restore, workspace: nil, action: "restore", error: error)
            }
            self?.isDetailLoading = false
        }
    }

    func clearDetailError() {
        detailRequestGeneration += 1
        detailError = nil
        if !isMaintenanceOperationInFlight {
            isDetailLoading = false
        }
    }

    nonisolated static func validatedWorkspaceURL(
        _ raw: String,
        expectedWorkspace: String,
        responseWorkspace: String,
        expectedHost: String,
        expectedPort: String,
        expectedScheme: String
    ) -> URL? {
        guard responseWorkspace == expectedWorkspace,
              !expectedHost.isEmpty,
              let expectedPortNumber = Int(expectedPort),
              let components = URLComponents(string: raw),
              components.scheme?.lowercased() == expectedScheme,
              let host = components.host,
              host.compare(expectedHost, options: .caseInsensitive) == .orderedSame,
              components.user == nil, components.password == nil,
              components.port == expectedPortNumber,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            return nil
        }
        return components.url
    }

    private func isActionSafe(for id: Workspace.ID, action: SafetyAction) -> Bool {
        guard let workspace = workspaces.first(where: { $0.id == id }) else { return false }
        return isActionSafe(for: workspace, action: action)
    }

    private func isActionSafe(for workspace: Workspace, action: SafetyAction) -> Bool {
        actionAvailability(for: workspace, action: action).isAllowed
    }

    func actionAvailability(for id: Workspace.ID, action: WorkspaceAction) -> WorkspaceActionAvailability {
        guard let workspace = workspaces.first(where: { $0.id == id }) else {
            return WorkspaceActionAvailability(
                isAllowed: false,
                reason: "The selected workspace is unavailable.",
                recovery: "Refresh workspace state and select a valid workspace."
            )
        }
        return workspace.actionAvailability(for: action, title: actionTitle(for: action))
    }

    private func actionAvailability(for workspace: Workspace, action: SafetyAction) -> WorkspaceActionAvailability {
        switch action {
        case .lifecycle(let lifecycle):
            switch lifecycle {
            case .start: return workspace.actionAvailability(for: .start)
            case .stop: return workspace.actionAvailability(for: .stop)
            case .restart: return workspace.actionAvailability(for: .restart)
            }
        case .terminal:
            return workspace.actionAvailability(for: .openTerminal, title: terminalActionTitle)
        case .editor:
            return workspace.actionAvailability(for: .openEditor, title: editorOpenActionTitle)
        case .site: return workspace.actionAvailability(for: .openSite)
        case .push: return workspace.actionAvailability(for: .push)
        }
    }

    private func actionTitle(for action: WorkspaceAction) -> String {
        switch action {
        case .openTerminal: return terminalActionTitle
        case .openEditor: return editorOpenActionTitle
        default: return action.title
        }
    }

    @discardableResult
    private func requireActionSafety(
        for id: Workspace.ID,
        action: SafetyAction,
        operation: String,
        detail: Bool = false
    ) -> Bool {
        guard let workspace = workspaces.first(where: { $0.id == id }) else {
            let message = "The selected workspace is unavailable. Refresh workspace state and select a valid workspace."
            if detail {
                detailError = message
            } else {
                lastError = message
            }
            return false
        }
        let availability = actionAvailability(for: workspace, action: action)
        guard availability.isAllowed else {
            let message = [availability.reason, availability.recovery]
                .compactMap { $0 }
                .joined(separator: " ")
            if detail {
                detailError = message
            } else {
                lastError = message
            }
            return false
        }
        return true
    }

    private func invalidatePendingPlansIfUnsafe() {
        if let workspace = pendingLifecycleWorkspace {
            let lifecycleIsSafe = pendingLifecycleAction.map {
                isActionSafe(for: workspace, action: .lifecycle($0))
            } ?? false
            if !lifecycleIsSafe {
                let action = pendingLifecycleAction?.rawValue.capitalized ?? "Lifecycle"
                clearPendingLifecyclePlan()
                lastError = "Pending \(action.lowercased()) confirmation was cancelled because \(workspace.rawValue) is no longer fresh and quarantine-clear."
            }
        }

        if let plan = pendingPushPlan {
            guard let workspace = Workspace.ID(rawValue: plan.workspace) else {
                pendingPushPlan = nil
                detailError = "Pending push confirmation was cancelled because its workspace is invalid."
                return
            }
            if !isActionSafe(for: workspace, action: .push) {
                pendingPushPlan = nil
                detailError = "Pending push confirmation was cancelled because \(workspace.rawValue) is no longer fresh and quarantine-clear."
            }
        }
    }

    private func markStateStale() {
        guard lastObservedAt != nil else { return }
        workspaces = workspaces.map { workspace in
            var stale = workspace
            stale.freshness = .stale
            stale.statusReason = "The latest observation failed; this is the last known snapshot."
            stale.recoveryAction = lastRecovery?.recovery ?? "Retry the observation or run diagnostics."
            stale.canStart = false
            stale.canStop = false
            stale.canRestart = false
            stale.canOpenTerminal = false
            stale.canPush = false
            stale.nextAction = "Retry"
            return stale
        }
        invalidatePendingPlansIfUnsafe()
    }

    func activitiesSnapshot() async -> [MSWActivity] {
        await activityStore.recent(limit: 100)
    }

    private func runLifecycle(
        _ action: MSWLifecycleAction,
        id: Workspace.ID,
        confirmation: String? = nil,
        reviewedPlan: MSWLifecyclePlan? = nil
    ) {
        guard let operationCoordinator else {
            lastError = "MSW operations are unavailable in fixture mode."
            return
        }
        guard requireActionSafety(
            for: id,
            action: .lifecycle(action),
            operation: action.rawValue.capitalized
        ) else {
            return
        }

        let isPlanning = action != .start && confirmation == nil
        if !isPlanning {
            beginOperation(
                kind: .lifecycle,
                workspace: id.rawValue,
                action: action.rawValue,
                message: "Applying the reviewed operation."
            )
            updateState(
                id,
                to: action == .start ? .starting : action == .stop ? .stopping : .restarting
            )
        }

        Task { [weak self] in
            do {
                let result = try await operationCoordinator.lifecycle(
                    action,
                    workspace: id.rawValue,
                    confirmation: confirmation,
                    reviewedPlan: reviewedPlan
                )
                await MainActor.run {
                    guard let self else { return }
                    self.markOperationVerifying(
                        kind: .lifecycle,
                        workspace: id.rawValue,
                        message: "\(result.outcome) Verifying with a fresh state observation."
                    )
                }
                await self?.refreshRemote()
            } catch let error as MSWOperationCoordinator.CoordinatorError {
                if case let .confirmationRequired(plan) = error {
                    await MainActor.run {
                        guard let self else { return }
                        guard self.requireActionSafety(
                            for: id,
                            action: .lifecycle(action),
                            operation: action.rawValue.capitalized
                        ) else {
                            self.clearPendingLifecyclePlan()
                            return
                        }
                        self.pendingLifecyclePlan = plan
                        self.pendingLifecycleAction = action
                        self.pendingLifecycleWorkspace = id
                        self.lastError = nil
                    }
                    return
                }
                await MainActor.run {
                    self?.lastError = error.localizedDescription
                    self?.lastRecovery = self?.recoveryContext(
                        for: error,
                        workspace: id.rawValue,
                        fallbackRecovery: "Refresh state before retrying."
                    )
                    if !isPlanning {
                        self?.updateState(id, to: .unknown)
                    }
                    self?.failOperation(
                        kind: .lifecycle,
                        workspace: id.rawValue,
                        action: action.rawValue,
                        error: error
                    )
                }
                let activity = MSWActivity(
                    id: UUID(),
                    createdAt: Date(),
                    kind: .failure,
                    title: "\(action.rawValue.capitalized) failed",
                    detail: error.localizedDescription,
                    workspace: id.rawValue,
                    isFailure: true
                )
                await self?.append(activity)
                await self?.refreshRemote()
            } catch {
                await MainActor.run {
                    self?.lastError = error.localizedDescription
                    self?.lastRecovery = self?.recoveryContext(
                        for: error,
                        workspace: id.rawValue,
                        fallbackRecovery: "Refresh state before retrying."
                    )
                    if !isPlanning {
                        self?.updateState(id, to: .unknown)
                    }
                    self?.failOperation(
                        kind: .lifecycle,
                        workspace: id.rawValue,
                        action: action.rawValue,
                        error: error
                    )
                }
                let activity = MSWActivity(
                    id: UUID(),
                    createdAt: Date(),
                    kind: .failure,
                    title: "\(action.rawValue.capitalized) failed",
                    detail: error.localizedDescription,
                    workspace: id.rawValue,
                    isFailure: true
                )
                await self?.append(activity)
                await self?.refreshRemote()
            }
        }
    }

    @discardableResult
    private func apply(state: MSWStateResponse, observedAt: Date?) -> [MSWOperationState] {
        let previousByID = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
        let hadAuthoritativeObservation = lastObservedAt != nil
        lastObservedAt = observedAt ?? Date()
        let snapshots = Dictionary(uniqueKeysWithValues: state.workspaces.map { ($0.id, $0) })
        let nextWorkspaces = configuredWorkspaceIDs.map { id in
            guard let snapshot = snapshots[id.rawValue] else {
                return Workspace(
                    id: id,
                    state: .unknown,
                    freshness: .unavailable,
                    statusReason: "MSW omitted this workspace from the latest observation.",
                    recoveryAction: "Retry the observation or run diagnostics.",
                    nextAction: "Retry",
                    canStart: false
                )
            }
            // Unknown quarantine state is fail-closed for every action except
            // the safe Stop path, which the CLI exposes independently.
            let isQuarantined = snapshot.quarantine.state != .clear ||
                snapshot.credential.state == .quarantined
            let lifecycle = isQuarantined
                ? Workspace.State.quarantined
                : Workspace.State(rawValue: snapshot.lifecycle.rawValue) ?? .unknown
            let safeCapabilities = isQuarantined
                ? MSWActionCapabilities(canStart: false, canStop: snapshot.actionCapabilities.canStop, canRestart: false, canOpenTerminal: false, canPush: false)
                : snapshot.actionCapabilities
            let capabilities = snapshot.freshness == .fresh
                ? safeCapabilities
                : MSWActionCapabilities(canStart: false, canStop: false, canRestart: false, canOpenTerminal: false, canPush: false)
            let stateObservedAt = snapshot.statusObservedAt ?? observedAt
            let reason: String? = isQuarantined
                ? (snapshot.quarantine.reason ?? "Workspace safety state could not be verified.")
                : snapshot.freshness == .fresh ? snapshot.actionCapabilities.reason : "This is not a fresh authoritative snapshot."
            let recovery: String? = isQuarantined
                ? (snapshot.actionCapabilities.recovery ?? "Stop safely or run diagnostics before retrying other actions.")
                : snapshot.actionCapabilities.recovery
            var candidate = Workspace(
                id: id,
                purpose: snapshot.purpose,
                state: lifecycle,
                credential: isQuarantined ? .quarantined : credentialState(snapshot.credential.state),
                freshness: snapshot.freshness,
                observedAt: stateObservedAt,
                networkHost: snapshot.network.host,
                quarantineReason: isQuarantined ? reason : nil,
                statusReason: reason,
                recoveryAction: recovery,
                nextAction: nextAction(snapshot, isQuarantined: isQuarantined),
                canStart: capabilities.canStart,
                canStop: capabilities.canStop,
                canRestart: capabilities.canRestart,
                canOpenTerminal: capabilities.canOpenTerminal,
                canPush: capabilities.canPush,
                skippedPorts: snapshot.skippedPorts,
                portWarning: snapshot.portWarning,
                serverCapabilities: snapshot.actionCapabilities
            )
            if let previous = previousByID[id] {
                candidate.observedAt = previous.observedAt
                if candidate == previous {
                    return previous
                }
                candidate.observedAt = stateObservedAt
            }
            return candidate
        }
        for workspace in nextWorkspaces
        where workspace.state == .running && previousByID[workspace.id]?.state != .running {
            logsUnavailableWorkspaces.remove(workspace.id.rawValue)
        }
        if nextWorkspaces != workspaces {
            workspaces = nextWorkspaces
        }
        for workspace in workspaces {
            let previous = previousByID[workspace.id]
            if hadAuthoritativeObservation,
               previous != nil,
               workspace.state == .quarantined,
               previous?.state != .quarantined {
                emitNotification(
                    kind: .quarantine,
                    workspace: workspace.id.rawValue,
                    title: "\(workspace.id.rawValue) is quarantined",
                    message: workspace.quarantineReason ?? "Workspace safety could not be verified.",
                    recovery: workspace.recoveryAction,
                    deepLink: workspaceDeepLink(workspace.id.rawValue, section: "overview")
                )
            }
            let lifecycleOperation = operationStates[operationKey(kind: .lifecycle, workspace: workspace.id.rawValue)]
            let lifecycleExpected = lifecycleOperation?.phase == .running || lifecycleOperation?.phase == .verifying
            if previous?.freshness == .fresh,
               previous?.state == .running,
               workspace.freshness == .fresh,
               workspace.state == .stopped || workspace.state == .exited,
               !lifecycleExpected {
                emitNotification(
                    kind: .lifecycleLoss,
                    workspace: workspace.id.rawValue,
                    title: "\(workspace.id.rawValue) stopped",
                    message: "A fresh observation shows that the workspace is no longer running.",
                    recovery: workspace.canStart ? "Start the workspace when ready." : workspace.recoveryAction,
                    deepLink: workspaceDeepLink(workspace.id.rawValue, section: "overview")
                )
            }
            if hadAuthoritativeObservation,
               previous != nil,
               credentialDeadlineIsVisible(workspace: workspace, snapshot: snapshots[workspace.id.rawValue]),
               previous?.credential != workspace.credential {
                emitNotification(
                    kind: .credentialDeadline,
                    workspace: workspace.id.rawValue,
                    title: "\(workspace.id.rawValue) credentials need attention",
                    message: "The current credential state is \(workspace.credential.rawValue).",
                    recovery: workspace.recoveryAction ?? "Review GitHub access for this workspace.",
                    deepLink: workspaceDeepLink(workspace.id.rawValue, section: "github")
                )
            }
        }
        invalidatePendingPlansIfUnsafe()
        return reconcileVerifyingOperations()
    }

    private func updateState(_ id: Workspace.ID, to state: Workspace.State) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[index].state = state
        switch state {
        case .running: workspaces[index].nextAction = "Open Terminal"
        case .stopped, .exited: workspaces[index].nextAction = "Start"
        case .starting: workspaces[index].nextAction = "Starting \(id.rawValue)…"
        case .stopping: workspaces[index].nextAction = "Stopping \(id.rawValue)…"
        case .restarting: workspaces[index].nextAction = "Restarting \(id.rawValue)…"
        case .quarantined: workspaces[index].nextAction = workspaces[index].canStop ? "Stop or Repair" : "Repair"
        case .unknown, .unavailable: workspaces[index].nextAction = "Retry"
        }
        workspaces[index].canStart = false
        workspaces[index].canStop = false
        workspaces[index].canRestart = false
        workspaces[index].canOpenTerminal = false
        workspaces[index].canPush = false
        guard workspaces[index].freshness == .fresh || client == nil else { return }
        let capabilities = workspaces[index].serverCapabilities
        switch state {
        case .running:
            workspaces[index].canStop = capabilities.canStop
            workspaces[index].canRestart = capabilities.canRestart
            workspaces[index].canOpenTerminal = capabilities.canOpenTerminal
            workspaces[index].canPush = capabilities.canPush
        case .stopped, .exited:
            workspaces[index].canStart = capabilities.canStart
            workspaces[index].canPush = capabilities.canPush
        case .starting, .stopping, .restarting, .unknown, .unavailable:
            break
        case .quarantined:
            workspaces[index].canStop = capabilities.canStop
        }
    }

    private func credentialState(_ state: MSWCredentialSnapshot.State) -> Workspace.CredentialState {
        switch state {
        case .ready: return .ready
        case .expiring: return .expiring
        case .needsRestart: return .needsRestart
        case .needsAuthorization: return .needsAuthorization
        case .serviceUnavailable: return .serviceUnavailable
        case .legacy: return .legacy
        case .removalPending: return .removalPending
        case .readOnly: return .readOnly
        case .quarantined: return .quarantined
        case .unconfigured: return .unconfigured
        }
    }

    private func nextAction(_ snapshot: MSWWorkspaceSnapshot, isQuarantined: Bool = false) -> String {
        guard snapshot.freshness == .fresh else { return "Retry" }
        guard !isQuarantined else {
            return snapshot.actionCapabilities.canStop ? "Stop or Repair" : "Repair"
        }
        switch snapshot.lifecycle {
        case .running: return snapshot.actionCapabilities.canOpenTerminal ? "Open Terminal" : "Retry"
        case .stopped, .exited: return snapshot.actionCapabilities.canStart ? "Start" : "Repair"
        case .quarantined: return "Repair"
        default: return "Retry"
        }
    }

    func recordProgress(_ event: MSWProgressEvent) {
        guard event.safeForDisplay else { return }
        let candidates = operationStates.keys.filter { key in
            guard let operation = operationStates[key] else { return false }
            return operation.outcome == .pending &&
                (event.workspace == nil || operation.workspace == event.workspace)
        }
        guard let key = candidates.sorted().first, var operation = operationStates[key] else { return }
        operation.phase = .running
        operation.fraction = event.fraction.map { min(max($0, 0), 1) }
        operation.message = event.message
        operation.updatedAt = Date()
        operationStates[key] = operation
    }

    func drainNotificationEvents() -> [MSWNotificationEvent] {
        defer { notificationEvents.removeAll(keepingCapacity: true) }
        return notificationEvents
    }

    private func operationKey(kind: MSWOperationState.Kind, workspace: String?) -> String {
        "\(kind.rawValue):\(workspace ?? "all")"
    }

    private func beginOperation(
        kind: MSWOperationState.Kind,
        workspace: String?,
        action: String,
        message: String
    ) {
        let key = operationKey(kind: kind, workspace: workspace)
        let now = Date()
        if var existing = operationStates[key], existing.outcome == .pending {
            existing.phase = .running
            existing.updatedAt = now
            existing.message = message
            operationStates[key] = existing
            return
        }
        operationStates[key] = MSWOperationState(
            id: UUID(), kind: kind, workspace: workspace, action: action,
            startedAt: now, updatedAt: now, phase: .running, fraction: nil,
            message: message, outcome: .pending, recovery: nil
        )
    }

    private func updateOperation(
        kind: MSWOperationState.Kind,
        workspace: String?,
        phase: MSWOperationState.Phase,
        outcome: MSWOperationState.Outcome,
        message: String
    ) {
        let key = operationKey(kind: kind, workspace: workspace)
        guard var operation = operationStates[key] else { return }
        operation.phase = phase
        operation.outcome = outcome
        operation.message = message
        operation.updatedAt = Date()
        operationStates[key] = operation
    }

    private func markOperationVerifying(
        kind: MSWOperationState.Kind,
        workspace: String?,
        message: String
    ) {
        updateOperation(kind: kind, workspace: workspace, phase: .verifying, outcome: .pending, message: message)
    }

    private func finishOperation(
        key: String,
        outcome: MSWOperationState.Outcome,
        message: String
    ) {
        guard var operation = operationStates[key] else { return }
        operation.phase = .finished
        operation.outcome = outcome
        operation.message = message
        operation.fraction = outcome == .succeeded ? 1 : operation.fraction
        operation.updatedAt = Date()
        operationStates[key] = operation
        if outcome == .succeeded,
           latestOperationFailure?.action == operation.action,
           latestOperationFailure?.workspace?.rawValue == operation.workspace {
            latestOperationFailure = nil
        }
    }

    private func recordOperationFailure(
        action: String,
        workspace: String?,
        reason: String,
        recovery: String,
        diagnosticDetails: String? = nil
    ) {
        latestOperationFailure = MSWOperationFailureNotice(
            action: action,
            title: "\(action.capitalized) failed",
            reason: reason,
            recovery: recovery,
            workspace: workspace.flatMap(Workspace.ID.init(rawValue:)),
            diagnosticDetails: diagnosticDetails
        )
    }

    private func failOperation(
        kind: MSWOperationState.Kind,
        workspace: String?,
        action: String,
        error: Error,
        notificationKind: MSWNotificationEvent.Kind = .operationFailure
    ) {
        noteRuntimeRepairFailure(error)
        let key = operationKey(kind: kind, workspace: workspace)
        if operationStates[key] == nil {
            beginOperation(kind: kind, workspace: workspace, action: action, message: error.localizedDescription)
        }
        let recovery = recoveryContext(
            for: error,
            workspace: workspace,
            fallbackRecovery: "Run Diagnostics and Maintenance before retrying \(action)."
        )
        recordOperationFailure(
            action: action,
            workspace: workspace,
            reason: recovery.reason,
            recovery: recovery.recovery ?? "Run Diagnostics and Maintenance before retrying \(action).",
            diagnosticDetails: operationDiagnostics(for: error, summary: recovery.reason)
        )
        finishOperation(key: key, outcome: .failed, message: error.localizedDescription)
        if var operation = operationStates[key] {
            operation.recovery = recovery
            operationStates[key] = operation
        }
        emitNotification(
            kind: notificationKind,
            workspace: workspace,
            title: "\(action.capitalized) failed",
            message: recovery.reason,
            recovery: recovery.recovery,
            deepLink: workspace.map { workspaceDeepLink($0, section: "activity") } ?? "msw-monitor://activity"
        )
    }

    private func operationDiagnostics(for error: Error, summary: String) -> String? {
        if case let MSWClientError.protocolFailure(protocolError) = error {
            return "\(protocolError.message)\nMSW error code: \(protocolError.code)"
        }
        let detail = error.localizedDescription
        let summaryLine = summary.components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?
            .trimmingCharacters(in: .whitespaces) ?? summary
        let hasAdditionalLine = detail.components(separatedBy: .newlines).contains {
            let line = $0.trimmingCharacters(in: .whitespaces)
            return !line.isEmpty && line != summaryLine
        }
        return detail == summaryLine && !hasAdditionalLine ? nil : detail
    }

    private func reconcileVerifyingOperations() -> [MSWOperationState] {
        var reconciled: [MSWOperationState] = []
        for (key, current) in operationStates where current.phase == .verifying && current.kind == .lifecycle {
            guard let workspaceID = current.workspace,
                  let workspace = workspaces.first(where: { $0.id.rawValue == workspaceID }) else {
                continue
            }
            let matches: Bool
            switch current.action {
            case MSWLifecycleAction.start.rawValue, MSWLifecycleAction.restart.rawValue:
                matches = workspace.state == .running
            case MSWLifecycleAction.stop.rawValue:
                matches = workspace.state == .stopped || workspace.state == .exited
            default:
                matches = false
            }
            guard workspace.freshness == .fresh else {
                finishOperation(
                    key: key,
                    outcome: .unknown,
                    message: "The operation returned, but no fresh workspace state was available to verify it."
                )
                if let operation = operationStates[key] { reconciled.append(operation) }
                continue
            }
            finishOperation(
                key: key,
                outcome: matches ? .succeeded : .unknown,
                message: matches
                    ? "A fresh observation verified the \(current.action) outcome."
                    : "A fresh observation did not match the expected \(current.action) outcome."
            )
            if !matches {
                recordOperationFailure(
                    action: current.action,
                    workspace: workspaceID,
                    reason: "The workspace returned \(workspace.state.rawValue.lowercased()) after \(current.action), so the requested change did not take effect.",
                    recovery: "Run Diagnostics and Maintenance, then retry \(current.action) only if the checks pass."
                )
                emitNotification(
                    kind: .operationFailure,
                    workspace: workspaceID,
                    title: "\(current.action.capitalized) outcome unknown",
                    message: "The latest state did not match the expected operation outcome.",
                    recovery: "Review the workspace state before taking another action.",
                    deepLink: workspaceDeepLink(workspaceID, section: "activity")
                )
            }
            if let operation = operationStates[key] { reconciled.append(operation) }
        }
        return reconciled
    }

    private func markOperationUnknown(key: String, reason: String) {
        guard let operation = operationStates[key], operation.phase == .verifying else { return }
        finishOperation(key: key, outcome: .unknown, message: reason)
        recordOperationFailure(
            action: operation.action,
            workspace: operation.workspace,
            reason: reason,
            recovery: "Run Diagnostics and Maintenance before retrying \(operation.action)."
        )
        emitNotification(
            kind: .operationFailure,
            workspace: operation.workspace,
            title: "\(operation.action.capitalized) outcome unknown",
            message: reason,
            recovery: "Re-establish observation and review state; do not replay automatically.",
            deepLink: operation.workspace.map { workspaceDeepLink($0, section: "activity") } ?? "msw-monitor://activity"
        )
    }

    private func markVerifyingOperationsUnknown(reason: String) {
        let keys = operationStates.compactMap { key, operation in
            operation.phase == .verifying ? key : nil
        }
        for key in keys {
            markOperationUnknown(key: key, reason: reason)
        }
    }
    private func restoreStateIsVerified(_ state: MSWStateResponse) -> Bool {
        let expectedIDs = Set(configuredWorkspaceIDs.map(\.rawValue))
        guard state.workspaces.count == expectedIDs.count,
              Set(state.workspaces.map(\.id)) == expectedIDs else {
            return false
        }
        return state.workspaces.allSatisfy { snapshot in
            snapshot.freshness == .fresh &&
                (snapshot.lifecycle == .stopped || snapshot.lifecycle == .exited)
        }
    }


    private func recoveryContext(
        for error: Error,
        workspace: String? = nil,
        fallbackRecovery: String
    ) -> MSWRecoveryContext {
        if case let MSWClientError.protocolFailure(protocolError) = error {
            return MSWRecoveryContext(
                code: protocolError.code,
                reason: protocolError.message,
                recovery: protocolError.recovery ?? fallbackRecovery,
                workspace: protocolError.workspace ?? workspace,
                retryable: protocolError.retryable
            )
        }
        if case let MSWClientError.processFailed(command, status, message) = error {
            let reason = message?.trimmingCharacters(in: .whitespacesAndNewlines)
            return MSWRecoveryContext(
                code: "MSW_PROCESS_FAILED",
                reason: reason.flatMap { $0.isEmpty ? nil : $0 }
                    ?? "MSW \(command) exited with status \(status) without returning error details.",
                recovery: fallbackRecovery,
                workspace: workspace,
                retryable: true
            )
        }
        return MSWRecoveryContext(
            code: "MSW_UNAVAILABLE",
            reason: error.localizedDescription,
            recovery: fallbackRecovery,
            workspace: workspace,
            retryable: true
        )
    }

    private func credentialDeadlineIsVisible(
        workspace: Workspace,
        snapshot: MSWWorkspaceSnapshot?
    ) -> Bool {
        if workspace.credential == .expiring { return true }
        let deadline = [snapshot?.credential.accessExpiresAt, snapshot?.credential.refreshExpiresAt]
            .compactMap { $0 }
            .min()
        return deadline.map { $0 <= Date().addingTimeInterval(7 * 24 * 60 * 60) } ?? false
    }

    private func emitNotification(
        kind: MSWNotificationEvent.Kind,
        workspace: String?,
        title: String,
        message: String,
        recovery: String?,
        deepLink: String
    ) {
        notificationGeneration += 1
        notificationEvents.append(MSWNotificationEvent(
            id: UUID(), kind: kind, createdAt: Date(), workspace: workspace,
            title: title, message: message, recovery: recovery,
            deepLink: deepLink, generation: notificationGeneration
        ))
    }

    private func workspaceDeepLink(_ workspace: String, section: String) -> String {
        "msw-monitor://workspace/\(workspace)?section=\(section)"
    }

    private func append(_ activity: MSWActivity) async {
        await activityStore.append(activity)
        activities = await activityStore.recent(limit: 100)
    }
}
