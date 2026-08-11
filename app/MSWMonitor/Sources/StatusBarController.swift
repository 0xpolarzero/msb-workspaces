import AppKit
import SwiftUI

@MainActor
final class StatusBarController {
    let model: AppModel
    let statusItem: NSStatusItem
    let popover: NSPopover

    private let bootstrapCoordinator: BootstrapCoordinator?
    private let authorizationCoordinator: GitHubAuthorizationCoordinator?
    private var detailWindowController: DetailWindowController?
    private var setupWindowController: SetupWindowController?
    private var settingsWindowController: SettingsWindowController?

    init(
        model: AppModel,
        bootstrapCoordinator: BootstrapCoordinator? = nil,
        authorizationCoordinator: GitHubAuthorizationCoordinator? = nil
    ) {
        self.model = model
        self.bootstrapCoordinator = bootstrapCoordinator
        self.authorizationCoordinator = authorizationCoordinator
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        let content = MonitorView(
            model: model,
            quit: { NSApplication.shared.terminate(nil) },
            openDetails: { [weak self] in self?.showDetails() },
            openSettings: { [weak self] in self?.showSettings() },
            openSetup: bootstrapCoordinator == nil ? nil : { [weak self] in self?.showSetup() }
        )
        popover.behavior = ProcessInfo.processInfo.arguments.contains("--ui-test-open-popover") ? .applicationDefined : .transient
        popover.animates = false
        popover.contentSize = NSSize(width: 410, height: 600)
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
        button.toolTip = "MSW Monitor — \(model.aggregateText)"
        button.target = self
        button.action = #selector(togglePopover)
        observeModelStatus()
    }

    var statusButton: NSStatusBarButton? { statusItem.button }

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

    private func showDetails() {
        popover.performClose(nil)
        model.setPollingVisible(false)
        if detailWindowController == nil {
            detailWindowController = DetailWindowController(
                model: model,
                onClose: { [weak model] in model?.setPollingVisible(false) }
            )
        }
        detailWindowController?.show()
        model.setPollingVisible(true)
    }

    func showSetupForFirstLaunch() {
        showSetup()
    }

    func showSetupForGitHubAuthorization() {
        showSetup()
    }

    private func showSettings() {
        popover.performClose(nil)
        model.setPollingVisible(false)
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                authorizationCoordinator: authorizationCoordinator,
                onConnect: { [weak self] in
                    self?.showSetup()
                }
            )
        }
        settingsWindowController?.show()
    }

    private func showSetup() {
        popover.performClose(nil)
        model.setPollingVisible(false)
        if setupWindowController == nil {
            setupWindowController = SetupWindowController(
                coordinator: bootstrapCoordinator,
                authorizationCoordinator: authorizationCoordinator,
                openSettings: { [weak self] in self?.showSettings() },
                closeSetup: { [weak self] in self?.setupWindowController?.close() }
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
        let hasCritical = model.workspaces.contains {
            guard $0.state != .quarantined else { return true }
            switch $0.credential {
            case .legacy, .removalPending, .quarantined:
                return true
            default:
                return false
            }
        }
        let hasAttention = model.lastError != nil || model.workspaces.contains {
            $0.freshness == .stale || $0.freshness == .unavailable ||
                $0.credential != .ready && $0.credential != .readOnly
        }
        let symbol: String
        if hasCritical {
            symbol = "exclamationmark.octagon.fill"
            button.contentTintColor = .systemRed
        } else if hasAttention {
            symbol = "exclamationmark.triangle.fill"
            button.contentTintColor = .systemOrange
        } else if model.isRefreshing {
            symbol = "arrow.triangle.2.circlepath"
            button.contentTintColor = nil
        } else {
            symbol = "circle.dotted"
            button.contentTintColor = nil
        }
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "MSW Monitor") {
            image.isTemplate = true
            button.image = image
        }
        button.toolTip = "MSW Monitor — \(model.aggregateText). \(model.aggregateDetail)"
        button.setAccessibilityValue("\(model.aggregateText). \(model.aggregateDetail)")
    }
}
