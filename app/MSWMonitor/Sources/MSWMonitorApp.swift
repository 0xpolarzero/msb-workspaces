import AppKit
import Observation
import SwiftUI
import UserNotifications

@main
struct MSWMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(authorizationCoordinator: appDelegate.authorizationCoordinator)
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
    let authorizationCoordinator: GitHubAuthorizationCoordinator?
    override init() {
        let configuredBaseURL = (Bundle.main.object(forInfoDictionaryKey: "MSWConnectBaseURL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let connectBaseURL = configuredBaseURL.flatMap(URL.init(string:)) ?? MSWConnectConfiguration().baseURL
        let configuredClientID = (Bundle.main.object(forInfoDictionaryKey: "MSWConnectClientID") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let connectClientID = configuredClientID.flatMap { $0.isEmpty ? nil : $0 } ?? MSWConnectConfiguration().clientID
        let configuredAttestation = (Bundle.main.object(forInfoDictionaryKey: "MSWConnectScopeAttestationPublicKey") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let scopeAttestationKey = configuredAttestation.flatMap { value in
            value.isEmpty ? nil : Data(base64Encoded: value)
        }
        let connectConfiguration = MSWConnectConfiguration(
            baseURL: connectBaseURL,
            clientID: connectClientID,
            scopeAttestationPublicKey: scopeAttestationKey,
            requiresScopeAttestation: !(configuredAttestation?.isEmpty ?? true)
        )
        let connect = MSWConnectClient(configuration: connectConfiguration)
        let runner = MSWCommandRunner()
        let broker = try? CredentialBroker()
        let refresher = broker.map {
            TokenRefreshCoordinator(broker: $0, connect: connect)
        }
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
        self.authorizationCoordinator = broker.map {
            GitHubAuthorizationCoordinator(broker: $0, connect: connect, mswClient: mswClient)
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let isUnitTestHost = ProcessInfo.processInfo.environment["XCInjectBundleInto"] == "unused"
        if isUnitTestHost {
            return
        }
        let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
            ProcessInfo.processInfo.environment["XCInjectBundleInto"] != nil
        let fixtureMode = ProcessInfo.processInfo.arguments.contains("--ui-test-open-popover") || isTestHost
        let model: AppModel
        let coordinator: MSWOperationCoordinator?
        if fixtureMode {
            model = AppModel()
            coordinator = nil
        } else {
            coordinator = MSWOperationCoordinator(client: client)
            let service = MSWOperationService(client: client, coordinator: coordinator)
            let diagnostics = MSWDiagnostics(client: client)
            model = AppModel(client: client, operationCoordinator: coordinator, operationService: service, diagnostics: diagnostics)
        }
        let bootstrap = fixtureMode ? nil : BootstrapCoordinator(
            client: client,
            runner: runner,
            hostService: MSWHostServiceController()
        )
        let controller = StatusBarController(
            model: model,
            bootstrapCoordinator: bootstrap,
            authorizationCoordinator: authorizationCoordinator
        )
        statusBarController = controller
        model.setPollingVisible(false)
        UNUserNotificationCenter.current().delegate = self
        observeNotificationEvents(from: model)

        if ProcessInfo.processInfo.arguments.contains("--ui-test-open-popover") {
            Task {
                try? await Task.sleep(for: .milliseconds(100))
                controller.togglePopover()
            }
        } else if !UserDefaults.standard.bool(forKey: "setupCompleted") {
            // Setup is a normal window in first-run mode; the status item remains
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
