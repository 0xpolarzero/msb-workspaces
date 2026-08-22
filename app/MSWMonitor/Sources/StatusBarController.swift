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
    private let settingsNavigation: SettingsNavigationState
    private let startupRecoveryBlockedReason: String?
    private let retryStartupRecovery: () -> Void
    private var detailWindowController: DetailWindowController?
    private var setupWindowController: SetupWindowController?

    init(
        model: AppModel,
        bootstrapCoordinator: (any MSWBootstrapCoordinating)? = nil,
        authorizationCoordinator: GitHubAuthorizationCoordinator? = nil,
        githubInstallationURL: URL? = nil,
        provider: (any GitHubProviding)? = nil,
        accessMode: GitHubAccessMode = .local,
        settingsNavigation: SettingsNavigationState = SettingsNavigationState(),
        startupRecoveryBlockedReason: String? = nil,
        retryStartupRecovery: @escaping () -> Void = {}
    ) {
        self.model = model
        self.bootstrapCoordinator = bootstrapCoordinator
        self.authorizationCoordinator = authorizationCoordinator
        self.githubInstallationURL = githubInstallationURL
        self.provider = provider
        self.accessMode = accessMode
        self.settingsNavigation = settingsNavigation
        self.startupRecoveryBlockedReason = startupRecoveryBlockedReason
        self.retryStartupRecovery = retryStartupRecovery
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        let content = MonitorView(
            model: model,
            quit: { NSApplication.shared.terminate(nil) },
            openDetails: { [weak self] route in self?.showDetails(route: route) },
            openSettings: { [weak self] in
                self?.showSettings(section: .general, dismissingSetup: true)
            },
            openSetup: (bootstrapCoordinator != nil || startupRecoveryBlockedReason != nil)
                ? { [weak self] in self?.showSetup() }
                : nil
        )
        popover.behavior = ProcessInfo.processInfo.arguments.contains("--ui-test-open-popover") ? .applicationDefined : .transient
        popover.animates = false
        popover.contentSize = NSSize(width: 430, height: 620)
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

    private func showDetails(route: DetailRoute) {
        popover.performClose(nil)
        model.setPollingVisible(false)
        if detailWindowController == nil {
            detailWindowController = DetailWindowController(
                model: model,
                openSettings: { [weak self] section in
                    self?.showSettings(section: section, dismissingSetup: true)
                },
                openSetup: { [weak self] in self?.showSetup() },
                onClose: { [weak model] in model?.setPollingVisible(false) }
            )
        }
        detailWindowController?.show(route: route)
        model.setPollingVisible(true)
    }

    func showSetupForFirstLaunch() {
        showSetup()
    }

    func showSetupForGitHubAuthorization() {
        showSetup()
    }

    func showDetails(for deepLink: URL) {
        guard let route = DetailRoute(deepLink: deepLink) else { return }
        showDetails(route: route)
    }

    private func showSettings(section: SettingsSection, dismissingSetup: Bool) {
        popover.performClose(nil)
        model.setPollingVisible(false)
        settingsNavigation.section = section
        if dismissingSetup {
            setupWindowController?.close()
            setupWindowController = nil
        }
        NSApp.activate(ignoringOtherApps: true)
        // Use the Settings scene's real application-menu action. Dispatching
        // lets SwiftUI present and select the requested Settings pane after
        // the navigation state changes. Setup-originated actions retain their
        // window so onboarding can resume when Settings is closed.
        DispatchQueue.main.async {
            let settingsItem = NSApp.mainMenu?.items
                .compactMap(\.submenu)
                .flatMap(\.items)
                .first { $0.title == "Settings…" }
            if let settingsItem, let action = settingsItem.action {
                NSApp.sendAction(action, to: settingsItem.target, from: settingsItem)
            } else {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }
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
                openSettings: { [weak self] section in
                    self?.showSettings(section: section, dismissingSetup: false)
                },
                closeSetup: { [weak self] in self?.setupWindowController?.close() },
                uiTestMode: arguments.contains("--ui-test-setup") ||
                    arguments.contains("--ui-test-setup-review") ||
                    uiTestGitHubScenario != nil,
                uiTestStartsInReview: arguments.contains("--ui-test-setup-review"),
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
            _ = model.aggregateText
            _ = model.aggregateDetail
            _ = model.isRefreshing
            _ = model.lastError
            _ = model.workspaces.map { ($0.state, $0.credential, $0.freshness) }
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
        if health.severity == .critical {
            button.contentTintColor = .systemRed
        } else if health.severity == .attention {
            button.contentTintColor = .systemOrange
        } else {
            button.contentTintColor = nil
        }
        if let image = NSImage(systemSymbolName: health.symbol, accessibilityDescription: "MSW Monitor") {
            image.isTemplate = true
            button.image = image
        }
        button.toolTip = "MSW Monitor — \(health.title). \(health.detail)"
        button.setAccessibilityValue("\(health.title). \(health.detail)")
    }
}
