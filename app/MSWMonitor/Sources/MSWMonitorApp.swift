import AppKit
import Observation
import SwiftUI
import UserNotifications

@main
struct MSWMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(
                navigation: appDelegate.settingsNavigation,
                authorizationCoordinator: appDelegate.authorizationCoordinator,
            )
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private let runner: MSWCommandRunner
    private let credentialBroker: CredentialBroker?
    private let connect: MSWConnectClient
    private let tokenRefreshCoordinator: TokenRefreshCoordinator?
    private let client: MSWClient
    let settingsNavigation = SettingsNavigationState()
    let authorizationCoordinator: GitHubAuthorizationCoordinator?
    let githubInstallationURL: URL?
    override init() {
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
        let connectConfiguration = MSWConnectConfiguration(
            baseURL: connectBaseURL,
            clientID: connectClientID,
            installationURL: installationURL,
            scopeAttestationPublicKey: scopeAttestationKey,
            requiresScopeAttestation: !(configuredAttestation?.isEmpty ?? true)
        )
        let connect = MSWConnectClient(configuration: connectConfiguration)
        let runner = MSWCommandRunner()
        let broker = try? CredentialBroker()
        let scopeEnforcementConfigured = connectConfiguration.hasTrustedScopeAttestation
        let refresher = scopeEnforcementConfigured ? broker.map {
            TokenRefreshCoordinator(broker: $0, connect: connect)
        } : nil
        self.runner = runner
        self.credentialBroker = broker
        self.connect = connect
        self.tokenRefreshCoordinator = refresher
        let mswClient = MSWClient(
            runner: runner,
            credentialBroker: broker,
            tokenRefreshCoordinator: refresher
        )
        self.client = mswClient
        self.authorizationCoordinator = scopeEnforcementConfigured ? broker.map {
            GitHubAuthorizationCoordinator(broker: $0, connect: connect, mswClient: mswClient)
        } : nil
        self.githubInstallationURL = installationURL
        super.init()
    }
    /// Routes `msw://` callback URLs from the default browser to the pending
    /// authorization session (the same route as `NSApplicationDelegate`
    /// URL-event delivery).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where MSWConnectBrowser.shared.handleCallback(url) {
            return
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
        let recoveryResult: Result<Void, Error>
        do {
            try LegacyDirectGitHubCredentialRetirement.remove()
            if let authorizationCoordinator {
                try await authorizationCoordinator.recoverPendingAuthorization()
            }
            recoveryResult = .success(())
        } catch {
            recoveryResult = .failure(error)
        }

        switch recoveryResult {
        case .success:
            installApplication(fixtureMode: false, credentialAccessAllowed: true)
        case .failure(let error):
            installApplication(
                fixtureMode: false,
                credentialAccessAllowed: false,
                startupRecoveryBlockedReason: error.localizedDescription
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
        startupRecoveryBlockedReason: String? = nil
    ) {
        let model: AppModel
        let operationCoordinator: MSWOperationCoordinator?
        let startupRecoveryRetry: (() -> Void)? = startupRecoveryBlockedReason == nil
            ? nil
            : { [weak self] in self?.retryStartupRecovery() }
        if fixtureMode || !credentialAccessAllowed {
            model = AppModel(
                startupRecoveryBlockedReason: fixtureMode ? nil : startupRecoveryBlockedReason,
                startupRecoveryRetry: fixtureMode ? nil : startupRecoveryRetry
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
                diagnostics: diagnostics
            )
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
        statusBarController?.tearDown()
        let controller = StatusBarController(
            model: model,
            bootstrapCoordinator: bootstrap,
            authorizationCoordinator: authorizationCoordinator,
            githubInstallationURL: githubInstallationURL,
            settingsNavigation: settingsNavigation,
            startupRecoveryBlockedReason: startupRecoveryBlockedReason,
            retryStartupRecovery: retryStartupRecovery
        )
        statusBarController = controller
        model.setPollingVisible(false)
        UNUserNotificationCenter.current().delegate = self
        observeNotificationEvents(from: model)
        let arguments = ProcessInfo.processInfo.arguments
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

    @objc func openGitHubSetup() {
        statusBarController?.showSetupForGitHubAuthorization()
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
            statusBarController?.showDetails(for: deepLink)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
