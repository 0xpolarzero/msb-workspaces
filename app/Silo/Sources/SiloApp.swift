import AppKit
import Observation
import SwiftUI
import UserNotifications

@main
struct SiloApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(
                navigation: appDelegate.appNavigation,
                applicationState: appDelegate.applicationState,
                applicationPreferences: appDelegate.applicationPreferences,
                githubState: appDelegate.githubSettingsState
            )
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private let runner: MSWCommandRunner
    private let credentialBroker: CredentialBroker?
    private let connect: MSWConnectClient?
    private let tokenRefreshCoordinator: TokenRefreshCoordinator?
    private let client: MSWClient
    let appNavigation = AppNavigationState()
    let applicationState = ApplicationState()
    let applicationPreferences: ApplicationPreferenceStore
    let authorizationCoordinator: GitHubAuthorizationCoordinator?
    let githubInstallationURL: URL?
    let accessMode: GitHubAccessMode
    let policyStore: GitHubPolicyStore?
    let provider: (any GitHubProviding)?
    let githubSettingsState: GitHubSettingsState
    private var pendingAppRoute: AppRoute?

    /// Test seam: local-mode init must never build or pass any Connect
    /// dependency (broker, client, refresher, coordinator).
    var hasConnectDependencies: Bool {
        credentialBroker != nil || connect != nil ||
            tokenRefreshCoordinator != nil || authorizationCoordinator != nil
    }

    /// Test seam: the CLI client itself must be broker-free in local mode.
    var clientHasConnectDependencies: Bool {
        client.hasConnectDependencies
    }

    convenience override init() {
        let configuration = Self.readConnectConfiguration()
        self.init(connectConfiguration: configuration, policyStore: nil)
    }

    /// Test seam + single construction path: resolves the mode BEFORE
    /// constructing any Connect dependency, so local mode never instantiates
    /// or passes the Connect broker/client/coordinator (no credentials.json
    /// reads, no Connect Keychain access, no fallback broker creation).
    init(
        connectConfiguration: MSWConnectConfiguration,
        policyStore: GitHubPolicyStore?,
        applicationPreferences: ApplicationPreferenceStore? = nil,
        makeBroker: () -> CredentialBroker? = { try? CredentialBroker() }
    ) {
        let accessMode: GitHubAccessMode = connectConfiguration.hasTrustedScopeAttestation ? .connect : .local
        self.accessMode = accessMode
        self.githubInstallationURL = connectConfiguration.installationURL
        self.applicationPreferences = applicationPreferences ?? Self.makeApplicationPreferences()
        let runner = MSWCommandRunner()
        self.runner = runner
        if accessMode == .connect {
            let connect = MSWConnectClient(configuration: connectConfiguration)
            let broker = makeBroker()
            let refresher = broker.map {
                TokenRefreshCoordinator(broker: $0, connect: connect)
            }
            let mswClient = MSWClient(
                runner: runner,
                credentialBroker: broker,
                tokenRefreshCoordinator: refresher
            )
            self.connect = connect
            self.credentialBroker = broker
            self.tokenRefreshCoordinator = refresher
            self.client = mswClient
            self.authorizationCoordinator = broker.map {
                GitHubAuthorizationCoordinator(
                    broker: $0,
                    connect: connect,
                    tokenRefreshCoordinator: refresher,
                    mswClient: mswClient
                )
            }
            self.policyStore = nil
            self.provider = nil
        } else {
            // Local mode: no Connect broker, client, refresher, or
            // coordinator. The CLI client is broker-free, so routine local
            // operations never request Connect Keychain records.
            self.connect = nil
            self.credentialBroker = nil
            self.tokenRefreshCoordinator = nil
            self.client = MSWClient(runner: runner)
            self.authorizationCoordinator = nil
            let store = policyStore ?? GitHubPolicyStore.standard()
            self.policyStore = store
            self.provider = GitHubLocalProvider(
                client: self.client,
                policyStore: store,
                workspaceConfigurations: BootstrapStateStore.persistedWorkspaceConfigurations()
            )
            store.startWatching()
        }
        self.githubSettingsState = GitHubSettingsState(
            authorizationCoordinator: self.authorizationCoordinator,
            provider: self.provider,
            accessMode: accessMode
        )
        super.init()
    }

    private static func makeApplicationPreferences() -> ApplicationPreferenceStore {
        let arguments = ProcessInfo.processInfo.arguments
        let folderBrowserFixture = arguments.contains("--ui-test-folder-browser")
        let preferencesFixture = arguments.contains("--ui-test-app-preferences")
        guard folderBrowserFixture || preferencesFixture else {
            return ApplicationPreferenceStore()
        }

        let suiteName = "org.microsandbox.Silo.ApplicationPreferencesUITests"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removeObject(forKey: ApplicationPreferenceStore.terminalOverrideKey)
        defaults.removeObject(forKey: ApplicationPreferenceStore.sourceEditorOverrideKey)
        return ApplicationPreferenceStore(userDefaults: defaults) {
            if preferencesFixture {
                let defaultTerminal = SystemApplication(
                    url: URL(fileURLWithPath: "/Applications/Fixture Terminal.app"),
                    bundleIdentifier: "org.microsandbox.fixture.default-terminal",
                    displayName: "Fixture Terminal"
                )
                let defaultEditor = SystemApplication(
                    url: URL(fileURLWithPath: "/Applications/Xcode.app"),
                    bundleIdentifier: "com.apple.dt.Xcode",
                    displayName: "Xcode"
                )
                let ghostty = SystemApplication(
                    url: URL(fileURLWithPath: "/Applications/Ghostty.app"),
                    bundleIdentifier: "com.mitchellh.ghostty",
                    displayName: "Ghostty"
                )
                let zed = SystemApplication(
                    url: URL(fileURLWithPath: "/Applications/Zed.app"),
                    bundleIdentifier: "dev.zed.Zed",
                    displayName: "Zed"
                )
                return SystemApplicationCatalog(
                    defaults: SystemApplicationDefaults(
                        terminal: defaultTerminal,
                        sourceEditor: defaultEditor
                    ),
                    terminals: [ghostty],
                    sourceEditors: [zed]
                )
            }

            let discovered = SystemApplicationCatalog.discover()
            let unsupported = SystemApplication(
                url: URL(fileURLWithPath: "/Applications/Unsupported Editor.app"),
                bundleIdentifier: "org.microsandbox.fixture.unsupported-editor",
                displayName: "Unsupported Editor"
            )
            return SystemApplicationCatalog(
                defaults: SystemApplicationDefaults(
                    terminal: discovered.defaults.terminal,
                    sourceEditor: unsupported
                ),
                terminals: discovered.terminals,
                sourceEditors: discovered.sourceEditors
            )
        }
    }

    /// Reads the Connect build configuration from Info.plist. Reading the
    /// bundle's own Info.plist is not a Connect store access.
    static func readConnectConfiguration() -> MSWConnectConfiguration {
        let configuredBaseURL = (Bundle.main.object(forInfoDictionaryKey: "MSWConnectBaseURL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let connectBaseURL = configuredBaseURL.flatMap { value in
            value.isEmpty ? nil : URL(string: value)
        } ?? MSWConnectConfiguration().baseURL
        let configuredClientID = (Bundle.main.object(forInfoDictionaryKey: "MSWConnectClientID") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let connectClientID = configuredClientID.flatMap { value in
            value.isEmpty ? nil : value
        } ?? MSWConnectConfiguration().clientID
        let configuredInstallationURL = (Bundle.main.object(forInfoDictionaryKey: "MSWConnectInstallationURL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let installationURL = configuredInstallationURL.flatMap { value in
            value.isEmpty ? nil : URL(string: value)
        }
        let configuredAttestation = (Bundle.main.object(forInfoDictionaryKey: "MSWConnectScopeAttestationPublicKey") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let scopeAttestationKey = configuredAttestation.flatMap { value in
            value.isEmpty ? nil : Data(base64Encoded: value)
        }
        return MSWConnectConfiguration(
            baseURL: connectBaseURL,
            clientID: connectClientID,
            installationURL: installationURL,
            scopeAttestationPublicKey: scopeAttestationKey,
            requiresScopeAttestation: !(configuredAttestation?.isEmpty ?? true)
        )
    }
    /// Routes OAuth callbacks and user-facing `silo://` deep links.
    /// A cold-launch route is retained until the status controller exists.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.scheme == "msw", accessMode == .connect,
               MSWConnectBrowser.shared.handleCallback(url) {
                continue
            }
            guard let route = AppRoute(deepLink: url) else { continue }
            if let statusBarController {
                statusBarController.showMain(route: route)
            } else {
                pendingAppRoute = route
            }
        }
    }


    func applicationDidFinishLaunching(_ notification: Notification) {
        let isUnitTestHost = ProcessInfo.processInfo.environment["XCInjectBundleInto"] == "unused"
        if isUnitTestHost {
            return
        }
        let arguments = ProcessInfo.processInfo.arguments
        let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
            ProcessInfo.processInfo.environment["XCInjectBundleInto"] != nil
        let fixtureMode = arguments.contains("--ui-test-open-popover") ||
            arguments.contains("--ui-test-setup") ||
            arguments.contains("--ui-test-setup-review") ||
            arguments.contains("--ui-test-setup-reconnect") ||
            arguments.contains("--ui-test-folder-browser") ||
            arguments.contains("--ui-test-app-preferences") ||
            arguments.contains("--ui-test-secrets") ||
            arguments.contains(where: { $0.hasPrefix("--ui-test-github-") }) ||
            isTestHost
        if fixtureMode {
            installApplication(fixtureMode: true, credentialAccessAllowed: true)
            return
        }

        // Do not expose the credential-backed model until every durable
        // authorization journal has been reconciled.
        Task { @MainActor [weak self] in
            await self?.recoverAndInstall()
        }
    }

    private func recoverAndInstall() async {
        var runtimeActivationFailed = false
        if let bundledRoot = ToolchainLayout.bundledRoot() {
            do {
                let installer = ToolchainInstaller(
                    bundledRoot: bundledRoot,
                    installationRoot: ToolchainLayout.managedRoot()
                )
                _ = try await installer.activate()
                await runner.invalidateMSWResolution()
            } catch {
                runtimeActivationFailed = true
            }
        } else {
            runtimeActivationFailed = true
        }
        let recoveryResult: Result<Void, Error>
        do {
            try LegacyDirectGitHubCredentialRetirement.remove()
            if accessMode == .connect, let authorizationCoordinator {
                if authorizationCoordinator.isAvailable {
                    try await authorizationCoordinator.recoverPendingAuthorization()
                } else {
                    _ = try await authorizationCoordinator.quarantineUnresolvableAccess()
                }
            }
            recoveryResult = .success(())
        } catch {
            recoveryResult = .failure(error)
        }

        switch recoveryResult {
        case .success:
            installApplication(
                fixtureMode: false,
                credentialAccessAllowed: true,
                startupRuntimeRepairRequired: runtimeActivationFailed
            )
        case .failure(let error):
            installApplication(
                fixtureMode: false,
                credentialAccessAllowed: false,
                startupRecoveryBlockedReason: error.localizedDescription,
                startupRuntimeRepairRequired: runtimeActivationFailed
            )
        }
    }

    private func retryStartupRecovery() {
        Task { @MainActor [weak self] in
            await self?.recoverAndInstall()
        }
    }

    private func installApplication(
        fixtureMode: Bool,
        credentialAccessAllowed: Bool,
        startupRecoveryBlockedReason: String? = nil,
        startupRuntimeRepairRequired: Bool = false
    ) {
        let arguments = ProcessInfo.processInfo.arguments
        if fixtureMode {
            UserDefaults.standard.removeObject(forKey: "github.settings.access-disabled")
            UserDefaults.standard.removeObject(forKey: "github.settings.disabled-policy")
        }
        let uiTestGitHubScenario = arguments.compactMap { argument -> String? in
            let prefix = "--ui-test-github-"
            return argument.hasPrefix(prefix) ? String(argument.dropFirst(prefix.count)) : nil
        }.first
        let fixtureProvider: (any GitHubProviding)? = (fixtureMode && accessMode == .local)
            ? GitHubFixtureProvider(scenario: uiTestGitHubScenario)
            : nil
        let fixtureOperationFailure = arguments.contains("--ui-test-operation-failure")
            ? MSWOperationFailureNotice(
                action: "start",
                title: "Start failed",
                reason: "The runtime rejected the start request.",
                recovery: "Run Diagnostics and Maintenance before retrying start.",
                workspace: .dev,
                diagnosticDetails: "agentd: init failed\nfailed to mount /dev/vdc at /workspace as ext4: EINVAL: Invalid argument\nMSW error code: MSW_WORKSPACE_DISK_INVALID"
            )
            : nil
        let model: AppModel
        let folderBrowserFixture = arguments.contains("--ui-test-folder-browser")
        let runtimeRepairFixture = arguments.contains("--ui-test-runtime-repair")
        let configuredWorkspaces = fixtureMode
            ? SetupWorkspaceConfiguration.defaults
            : BootstrapStateStore.persistedWorkspaceConfigurations()
        let operationCoordinator: MSWOperationCoordinator?
        let startupRecoveryRetry: (() -> Void)? = startupRecoveryBlockedReason == nil
            ? nil
            : { [weak self] in self?.retryStartupRecovery() }
        if fixtureMode || !credentialAccessAllowed {
            model = AppModel(
                provider: fixtureProvider ?? provider,
                accessMode: accessMode,
                workspaceConfigurations: configuredWorkspaces,
                startupRecoveryBlockedReason: fixtureMode ? nil : startupRecoveryBlockedReason,
                startupRecoveryRetry: fixtureMode ? nil : startupRecoveryRetry,
                initialOperationFailure: fixtureMode ? fixtureOperationFailure : nil,
                applicationPreferences: applicationPreferences,
                initialRuntimeRepairRequired: runtimeRepairFixture || startupRuntimeRepairRequired
            )
            operationCoordinator = nil
        } else {
            operationCoordinator = MSWOperationCoordinator(client: client)
            let service = MSWOperationService(client: client, coordinator: operationCoordinator)
            let diagnostics = MSWDiagnostics(client: client)
            model = AppModel(
                client: client,
                operationCoordinator: operationCoordinator,
                operationService: service,
                diagnostics: diagnostics,
                provider: provider,
                accessMode: accessMode,
                workspaceConfigurations: configuredWorkspaces,
                applicationPreferences: applicationPreferences,
                initialRuntimeRepairRequired: startupRuntimeRepairRequired
            )
        }
        if folderBrowserFixture {
            model.installDirectoryUITestFixture()
        }
        if arguments.contains("--ui-test-lifecycle") {
            model.installLifecycleUITestFixture()
        }
        if arguments.contains("--ui-test-secrets") {
            model.installSecretsUITestFixture()
        }
        if arguments.contains("--ui-test-workspace-repair") {
            model.installWorkspaceRepairUITestFixture()
        }
        if fixtureMode {
            let backupDestination = arguments.compactMap { argument -> URL? in
                let prefix = "--ui-test-backup-destination="
                guard argument.hasPrefix(prefix) else { return nil }
                let path = String(argument.dropFirst(prefix.count))
                guard path.hasPrefix("/") else { return nil }
                return URL(fileURLWithPath: path, isDirectory: true)
            }.first
            let backupResultScenario = arguments.compactMap { argument -> AppModel.BackupUITestResultScenario? in
                guard argument.hasPrefix("--ui-test-backup-result=") else { return nil }
                switch argument.dropFirst("--ui-test-backup-result=".count) {
                case "running": return .running
                case "success": return .success
                case "partial": return .partial
                case "failure": return .failure
                default: return nil
                }
            }.first
            model.installBackupUITestFixture(
                destination: backupDestination,
                resultScenario: backupResultScenario
            )
            if arguments.contains("--ui-test-backup-reattach"), let backupDestination {
                model.installConcurrentBackupReattachmentFixture(
                    destination: backupDestination,
                    advanced: arguments.contains("--ui-test-backup-reattach-advanced")
                )
            }
            if runtimeRepairFixture {
                model.installRuntimeRepairUITestFixture()
            }
            if arguments.contains("--ui-test-malformed-backup") {
                model.installMalformedBackupUITestFixture()
            }
        }
        applicationState.model = model
        githubSettingsState.configure(provider: fixtureProvider ?? provider)
        if runtimeRepairFixture {
            githubSettingsState.installRuntimeRepairUITestFixture()
        }
        let setupFixtureOwnsGitHubLoading = arguments.contains("--ui-test-setup") ||
            arguments.contains("--ui-test-setup-review") ||
            arguments.contains("--ui-test-setup-reconnect")
        if !setupFixtureOwnsGitHubLoading {
            githubSettingsState.setPollingVisible(false)
        }
        if appNavigation.workspace == nil {
            appNavigation.workspace = model.selectedWorkspace ?? model.workspaces.first?.id
        }
        let bootstrap: (any MSWBootstrapCoordinating)?
        if ProcessInfo.processInfo.arguments.contains("--ui-test-setup-reconnect") {
            bootstrap = MSWBootstrapUITestStub(failureWorkspace: "dev")
        } else if fixtureMode || !credentialAccessAllowed {
            bootstrap = nil
        } else {
            bootstrap = BootstrapCoordinator(
                client: client,
                runner: runner,
                hostService: MSWHostServiceController()
            )
        }
        model.configureSystemHealthChecks(using: bootstrap)
        statusBarController?.tearDown()
        let controller = StatusBarController(
            model: model,
            bootstrapCoordinator: bootstrap,
            authorizationCoordinator: authorizationCoordinator,
            githubInstallationURL: githubInstallationURL,
            provider: fixtureProvider ?? provider,
            accessMode: accessMode,
            commandRunner: runner,
            appNavigation: appNavigation,
            applicationPreferences: applicationPreferences,
            startupRecoveryBlockedReason: startupRecoveryBlockedReason,
            retryStartupRecovery: retryStartupRecovery,
            runtimeRepairDidSucceed: { [weak githubSettingsState = self.githubSettingsState] in
                githubSettingsState?.runtimeRepairDidSucceed()
            }
        )
        statusBarController = controller
        if let pendingAppRoute {
            self.pendingAppRoute = nil
            controller.showMain(route: pendingAppRoute)
        }
        let startupWorkspaceIDs = WorkspaceStartupPreferences.selectedWorkspaceIDs(
            from: model.workspaces.map(\.id)
        )
        if !fixtureMode,
           credentialAccessAllowed,
           UserDefaults.standard.bool(forKey: WorkspaceStartupPreferences.enabledKey),
           !startupWorkspaceIDs.isEmpty {
            Task { @MainActor [weak model] in
                guard let model else { return }
                await model.startWorkspacesAtLaunch(startupWorkspaceIDs)
                model.setPollingVisible(false)
            }
        } else {
            model.setPollingVisible(false)
        }
        UNUserNotificationCenter.current().delegate = self
        observeNotificationEvents(from: model)
        let uiTestGitHubFlow = arguments.contains(where: { $0.hasPrefix("--ui-test-github-") })
        if arguments.contains("--ui-test-open-popover") ||
            arguments.contains("--ui-test-setup") ||
            arguments.contains("--ui-test-setup-review") ||
            uiTestGitHubFlow {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                if arguments.contains("--ui-test-open-popover") {
                    controller.togglePopover()
                } else {
                    controller.showSetupForFirstLaunch()
                }
            }
        } else if !UserDefaults.standard.bool(forKey: "setupCompleted") {
            // available so setup can be resumed or closed without losing state.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                controller.showSetupForFirstLaunch()
            }
        }
    }


    @objc func openGeneralSettings() {
        statusBarController?.showMain(route: AppRoute(tab: .general))
    }

    @objc func openRuntimeRepair() {
        statusBarController?.showRuntimeRepair()
    }

    @objc func closeRuntimeRepair() {
        statusBarController?.closeRuntimeRepair()
    }

    @objc func closeStatusPopover() {
        statusBarController?.closePopover()
    }

    private func observeNotificationEvents(from model: AppModel) {
        withObservationTracking {
            _ = model.notificationEvents.count
        } onChange: { [weak self, weak model] in
            Task { @MainActor in
                guard let self, let model else { return }
                await NotificationCoordinator.shared.deliverPendingEvents(from: model)
                self.observeNotificationEvents(from: model)
            }
        }
        if !model.notificationEvents.isEmpty {
            Task { await NotificationCoordinator.shared.deliverPendingEvents(from: model) }
        }
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let deepLink = NotificationCoordinator.deepLink(from: response) else { return }
        await MainActor.run {
            statusBarController?.showMain(for: deepLink)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
