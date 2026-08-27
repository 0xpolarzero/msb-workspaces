import AppKit
import SwiftUI

@MainActor
final class StatusBarController {
    let model: AppModel
    let statusItem: NSStatusItem
    let popover: NSPopover

    private let bootstrapCoordinator: (any MSWBootstrapCoordinating)?
    private let authorizationCoordinator: GitHubAuthorizationCoordinator?
    private let githubInstallationURL: URL?
    private let provider: (any GitHubProviding)?
    private let accessMode: GitHubAccessMode
    private let commandRunner: MSWCommandRunner
    private let appNavigation: AppNavigationState
    private let applicationPreferences: ApplicationPreferenceStore
    private let startupRecoveryBlockedReason: String?
    private let retryStartupRecovery: () -> Void
    private var setupWindowController: SetupWindowController?

    init(
        model: AppModel,
        bootstrapCoordinator: (any MSWBootstrapCoordinating)? = nil,
        authorizationCoordinator: GitHubAuthorizationCoordinator? = nil,
        githubInstallationURL: URL? = nil,
        provider: (any GitHubProviding)? = nil,
        accessMode: GitHubAccessMode = .local,
        commandRunner: MSWCommandRunner = MSWCommandRunner(),
        appNavigation: AppNavigationState = AppNavigationState(),
        applicationPreferences: ApplicationPreferenceStore,
        startupRecoveryBlockedReason: String? = nil,
        retryStartupRecovery: @escaping () -> Void = {}
    ) {
        self.model = model
        self.bootstrapCoordinator = bootstrapCoordinator
        self.authorizationCoordinator = authorizationCoordinator
        self.githubInstallationURL = githubInstallationURL
        self.provider = provider
        self.accessMode = accessMode
        self.commandRunner = commandRunner
        self.appNavigation = appNavigation
        self.applicationPreferences = applicationPreferences
        self.startupRecoveryBlockedReason = startupRecoveryBlockedReason
        self.retryStartupRecovery = retryStartupRecovery
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        popover = NSPopover()
        let content = MonitorView(
            model: model,
            quit: { NSApplication.shared.terminate(nil) },
            openRoute: { [weak self] route in self?.showMain(route: route) }
        )
        popover.behavior = ProcessInfo.processInfo.arguments.contains("--ui-test-open-popover") ? .applicationDefined : .transient
        popover.animates = false
        popover.contentSize = NSSize(width: 340, height: 280)
        let hostingController = NSHostingController(rootView: content)
        hostingController.view.setAccessibilityIdentifier("monitor.popover")
        popover.contentViewController = hostingController

        guard let button = statusItem.button else {
            preconditionFailure("NSStatusItem did not provide a button")
        }
        if let image = NSImage(systemSymbolName: "circle.dotted", accessibilityDescription: "MSW Monitor") {
            image.isTemplate = true
            button.image = image
        }
        button.title = ""
        button.identifier = NSUserInterfaceItemIdentifier("statusItem.button")
        button.setAccessibilityIdentifier("statusItem.button")
        button.setAccessibilityLabel("MSW Monitor")
        let initialHealth = model.health
        button.toolTip = "MSW Monitor — \(initialHealth.title). \(initialHealth.detail)"
        button.target = self
        button.action = #selector(togglePopover)
        observeModelStatus()
    }

    var statusButton: NSStatusBarButton? { statusItem.button }
    func tearDown() {
        setupWindowController?.close()
        popover.performClose(nil)
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            model.setPollingVisible(false)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            model.setPollingVisible(true)
        }
    }
    func closePopover() {
        if popover.isShown {
            popover.performClose(nil)
        }
        model.setPollingVisible(false)
    }

    func showMain(route: AppRoute, dismissingSetup: Bool = true) {
        popover.performClose(nil)
        model.setPollingVisible(false)
        appNavigation.apply(route)
        if let workspace = route.workspace {
            model.selectedWorkspace = workspace
        }
        if dismissingSetup {
            setupWindowController?.close()
            setupWindowController = nil
        }
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            let settingsItem = NSApp.mainMenu?.items
                .compactMap(\.submenu)
                .flatMap(\.items)
                .first { $0.title == "Settings…" }
            if let settingsItem, let action = settingsItem.action {
                NSApp.sendAction(action, to: settingsItem.target, from: settingsItem)
            }
            DispatchQueue.main.async {
                self.appNavigation.pendingPresentation = false
                NSApp.keyWindow?.title = "MSW Monitor"
            }
        }
    }

    func showSetupForFirstLaunch() {
        showSetup()
    }


    func showMain(for deepLink: URL) {
        guard let route = AppRoute(deepLink: deepLink) else { return }
        showMain(route: route)
    }

    private func showSetup() {
        popover.performClose(nil)
        model.setPollingVisible(false)
        if setupWindowController == nil {
            let arguments = ProcessInfo.processInfo.arguments
            let uiTestGitHubScenario = arguments.compactMap { argument -> String? in
                let prefix = "--ui-test-github-"
                return argument.hasPrefix(prefix) ? String(argument.dropFirst(prefix.count)) : nil
            }.first
            setupWindowController = SetupWindowController(
                coordinator: bootstrapCoordinator,
                authorizationCoordinator: authorizationCoordinator,
                githubInstallationURL: githubInstallationURL,
                provider: provider,
                accessMode: accessMode,
                commandRunner: commandRunner,
                applicationPreferences: applicationPreferences,
                openSettings: { [weak self] tab in
                    self?.showMain(route: AppRoute(tab: tab), dismissingSetup: false)
                },
                closeSetup: { [weak self] configurations in
                    self?.setupWindowController?.close()
                    self?.model.reloadWorkspaceConfiguration(configurations)
                    self?.model.setupRepairDidSucceed()
                },
                uiTestMode: arguments.contains("--ui-test-setup") ||
                    arguments.contains("--ui-test-setup-review") ||
                    arguments.contains("--ui-test-runtime-repair") ||
                    uiTestGitHubScenario != nil,
                uiTestStartsInReview: arguments.contains("--ui-test-setup-review") ||
                    arguments.contains("--ui-test-runtime-repair"),
                uiTestGitHubScenario: uiTestGitHubScenario,
                uiTestBootstrapReconnect: arguments.contains("--ui-test-setup-reconnect"),
                startupRecoveryBlockedReason: startupRecoveryBlockedReason,
                retryStartupRecovery: retryStartupRecovery
            )
        }
        setupWindowController?.show()
    }

    private func observeModelStatus() {
        withObservationTracking {
            _ = model.health
            _ = model.runtimeRepairRequired
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observeModelStatus()
            }
        }
        updateStatusItem()
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let health = model.health
        if model.runtimeRepairRequired {
            button.contentTintColor = .systemOrange
        } else if health.severity == .critical {
            button.contentTintColor = .systemRed
        } else if health.severity == .attention {
            button.contentTintColor = .systemOrange
        } else {
            button.contentTintColor = nil
        }
        let symbol = model.runtimeRepairRequired ? "wrench.and.screwdriver.fill" : health.symbol
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "MSW Monitor") {
            image.isTemplate = true
            button.image = image
        }
        if model.runtimeRepairRequired {
            button.toolTip = "MSW Monitor — MSW installation needs repair"
            button.setAccessibilityValue("MSW Monitor. Repair needed. MSW installation needs repair.")
            button.setAccessibilityHelp(RuntimeRepairAccessibilityIdentifier.statusWarning)
            popover.contentSize = NSSize(width: 340, height: 324)
        } else {
            button.toolTip = "MSW Monitor — \(health.title). \(health.detail)"
            button.setAccessibilityValue("\(health.title). \(health.detail)")
            button.setAccessibilityHelp(nil)
            popover.contentSize = NSSize(width: 340, height: 280)
        }
    }
}
