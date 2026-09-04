import AppKit
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
    private let runner: SiloCommandRunner
    private let client: SiloClient
    let appNavigation = AppNavigationState()
    let applicationState = ApplicationState()
    let applicationPreferences: ApplicationPreferenceStore
    let policyStore: GitHubPolicyStore
    let provider: any GitHubProviding
    let githubSettingsState: GitHubSettingsState
    private var pendingAppRoute: AppRoute?

    convenience override init() {
        self.init(policyStore: nil)
    }

    init(
        policyStore: GitHubPolicyStore?,
        applicationPreferences: ApplicationPreferenceStore? = nil
    ) {
        self.applicationPreferences = applicationPreferences ?? Self.makeApplicationPreferences()
        let runner = SiloCommandRunner()
        self.runner = runner
        let client = SiloClient(runner: runner)
        self.client = client
        let store = policyStore ?? GitHubPolicyStore.standard()
        self.policyStore = store
        let provider = GitHubProvider(
            client: client,
            policyStore: store,
            workspaceConfigurations: BootstrapStateStore.persistedWorkspaceConfigurations()
        )
        self.provider = provider
        store.startWatching()
        self.githubSettingsState = GitHubSettingsState(provider: provider)
        super.init()
    }

    private static func makeApplicationPreferences() -> ApplicationPreferenceStore {
        let arguments = ProcessInfo.processInfo.arguments
        let folderBrowserFixture = arguments.contains("--ui-test-folder-browser")
        let preferencesFixture = arguments.contains("--ui-test-app-preferences")
        guard folderBrowserFixture || preferencesFixture else {
            return ApplicationPreferenceStore()
        }

        let suiteName = "org.silo.Silo.ApplicationPreferencesUITests"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removeObject(forKey: ApplicationPreferenceStore.terminalOverrideKey)
        defaults.removeObject(forKey: ApplicationPreferenceStore.sourceEditorOverrideKey)
        return ApplicationPreferenceStore(userDefaults: defaults) {
            if preferencesFixture {
                let defaultTerminal = SystemApplication(
                    url: URL(fileURLWithPath: "/Applications/Fixture Terminal.app"),
                    bundleIdentifier: "org.silo.fixture.default-terminal",
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
                bundleIdentifier: "org.silo.fixture.unsupported-editor",
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

    /// Routes user-facing `silo://` deep links.
    /// A cold-launch route is retained until the status controller exists.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
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
            arguments.contains("--ui-test-folder-browser") ||
            arguments.contains("--ui-test-app-preferences") ||
            arguments.contains("--ui-test-secrets") ||
            arguments.contains(where: { $0.hasPrefix("--ui-test-github-") }) ||
            isTestHost
        if fixtureMode {
            installApplication(fixtureMode: true)
            return
        }
        installApplication(fixtureMode: false)
    }

    private func installApplication(fixtureMode: Bool) {
        let arguments = ProcessInfo.processInfo.arguments
        if fixtureMode {
            UserDefaults.standard.removeObject(forKey: "github.settings.access-disabled")
            UserDefaults.standard.removeObject(forKey: "github.settings.disabled-policy")
        }
        let uiTestGitHubScenario = arguments.compactMap { argument -> String? in
            let prefix = "--ui-test-github-"
            return argument.hasPrefix(prefix) ? String(argument.dropFirst(prefix.count)) : nil
        }.first
        let fixtureProvider: (any GitHubProviding)? = fixtureMode
            ? GitHubFixtureProvider(scenario: uiTestGitHubScenario) : nil
        let fixtureOperationFailure = arguments.contains("--ui-test-operation-failure")
            ? SiloOperationFailureNotice(
                action: "start",
                title: "Start failed",
                reason: "The runtime rejected the start request.",
                recovery: "Run Diagnostics and Maintenance before retrying start.",
                workspace: .dev,
                diagnosticDetails: "agentd: init failed\nfailed to mount /dev/vdc at /workspace as ext4: EINVAL: Invalid argument\nSilo error code: SILO_WORKSPACE_DISK_INVALID"
            )
            : nil
        let model: AppModel
        let folderBrowserFixture = arguments.contains("--ui-test-folder-browser")
        let runtimeRepairFixture = arguments.contains("--ui-test-runtime-repair")
        let configuredWorkspaces = fixtureMode
            ? SetupWorkspaceConfiguration.defaults
            : BootstrapStateStore.persistedWorkspaceConfigurations()
        let operationCoordinator: SiloOperationCoordinator?
        if fixtureMode {
            model = AppModel(
                workspaceConfigurations: configuredWorkspaces,
                initialOperationFailure: fixtureOperationFailure,
                applicationPreferences: applicationPreferences,
                initialRuntimeRepairRequired: runtimeRepairFixture
            )
            operationCoordinator = nil
        } else {
            operationCoordinator = SiloOperationCoordinator(client: client)
            let service = SiloOperationService(client: client, coordinator: operationCoordinator)
            let diagnostics = SiloDiagnostics(client: client)
            model = AppModel(
                client: client,
                operationCoordinator: operationCoordinator,
                operationService: service,
                diagnostics: diagnostics,
                workspaceConfigurations: configuredWorkspaces,
                applicationPreferences: applicationPreferences
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
        let activeGitHubProvider = fixtureProvider ?? provider
        githubSettingsState.configure(provider: activeGitHubProvider)
        // Resume a durable pending intent at application startup even when no
        // GitHub view is opened. The provider coalesces this with any later
        // Setup or Settings edit.
        Task { _ = await activeGitHubProvider.policySyncProgress() }
        if runtimeRepairFixture {
            githubSettingsState.installRuntimeRepairUITestFixture()
        }
        let setupFixtureOwnsGitHubLoading = arguments.contains("--ui-test-setup") ||
            arguments.contains("--ui-test-setup-review") ||
            arguments.contains("--ui-test-setup-installing") ||
            arguments.contains("--ui-test-setup-registration-failure")
        githubSettingsState.setPollingVisible(false)
        if appNavigation.workspace == nil {
            appNavigation.workspace = model.selectedWorkspace ?? model.workspaces.first?.id
        }
        let bootstrap: (any SiloBootstrapCoordinating)?
        if arguments.contains("--ui-test-setup-registration-failure") {
            bootstrap = SiloBootstrapUITestStub(
                registrationFailure: "MicroSandbox failed Silo's disk-safety check. Update or repair MicroSandbox, then retry Setup. Safety-check detail: the disposable probe disk changed length after guest fstrim; the runtime truncated the raw image."
            )
        } else if setupFixtureOwnsGitHubLoading {
            bootstrap = SiloBootstrapUITestStub(
                keepsFirstRunPending: arguments.contains("--ui-test-setup-registration-pending"),
                simulatesRuntimeInstallation: arguments.contains("--ui-test-setup-installing")
            )
        } else if fixtureMode {
            bootstrap = nil
        } else {
            bootstrap = BootstrapCoordinator(
                client: client,
                runner: runner,
                hostService: SiloHostServiceController()
            )
        }
        model.configureSystemHealthChecks(using: bootstrap)
        statusBarController?.tearDown()
        let controller = StatusBarController(
            model: model,
            bootstrapCoordinator: bootstrap,
            provider: fixtureProvider ?? provider,
            githubSettingsState: githubSettingsState,
            commandRunner: runner,
            appNavigation: appNavigation,
            applicationPreferences: applicationPreferences,
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
