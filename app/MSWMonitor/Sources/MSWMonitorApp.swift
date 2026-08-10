import AppKit
import SwiftUI

@main
struct MSWMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private let runner: MSWCommandRunner
    private let credentialBroker: CredentialBroker?
    private let tokenRefreshCoordinator: TokenRefreshCoordinator?
    private let client: MSWClient
    override init() {
        let broker = try? CredentialBroker()
        let refresher = broker.map { TokenRefreshCoordinator(broker: $0) }
        let runner = MSWCommandRunner()
        self.runner = runner
        credentialBroker = broker
        tokenRefreshCoordinator = refresher
        client = MSWClient(runner: runner, credentialBroker: broker, tokenRefreshCoordinator: refresher)
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
        let authorization = credentialBroker.map {
            GitHubAuthorizationCoordinator(broker: $0, mswClient: client)
        }
        let controller = StatusBarController(
            model: model,
            bootstrapCoordinator: bootstrap,
            authorizationCoordinator: authorization
        )
        statusBarController = controller
        model.setPollingVisible(false)

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
}
