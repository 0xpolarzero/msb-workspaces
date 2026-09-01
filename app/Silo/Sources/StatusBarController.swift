import AppKit
import SwiftUI

@MainActor
final class StatusBarController {
    let model: AppModel
    let statusItem: NSStatusItem
    let popover: NSPopover

    private let bootstrapCoordinator: (any SiloBootstrapCoordinating)?
    private let authorizationCoordinator: GitHubAuthorizationCoordinator?
    private let githubInstallationURL: URL?
    private let provider: (any GitHubProviding)?
    private let githubSettingsState: GitHubSettingsState
    private let accessMode: GitHubAccessMode
    private let commandRunner: SiloCommandRunner
    private let appNavigation: AppNavigationState
    private let applicationPreferences: ApplicationPreferenceStore
    private let startupRecoveryBlockedReason: String?
    private let retryStartupRecovery: () -> Void
    private let runtimeRepairDidSucceed: () -> Void
    private var setupWindowController: SetupWindowController?
    private var runtimeRepairWindowController: RuntimeRepairWindowController?

    init(
        model: AppModel,
        bootstrapCoordinator: (any SiloBootstrapCoordinating)? = nil,
        authorizationCoordinator: GitHubAuthorizationCoordinator? = nil,
        githubInstallationURL: URL? = nil,
        provider: (any GitHubProviding)? = nil,
        githubSettingsState: GitHubSettingsState? = nil,
        accessMode: GitHubAccessMode = .local,
        commandRunner: SiloCommandRunner = SiloCommandRunner(),
        appNavigation: AppNavigationState = AppNavigationState(),
        applicationPreferences: ApplicationPreferenceStore,
        startupRecoveryBlockedReason: String? = nil,
        retryStartupRecovery: @escaping () -> Void = {},
        runtimeRepairDidSucceed: @escaping () -> Void = {}
    ) {
        self.model = model
        self.bootstrapCoordinator = bootstrapCoordinator
        self.authorizationCoordinator = authorizationCoordinator
        self.githubInstallationURL = githubInstallationURL
        self.provider = provider
        self.githubSettingsState = githubSettingsState ?? GitHubSettingsState(
            authorizationCoordinator: authorizationCoordinator,
            provider: provider,
            accessMode: accessMode
        )
        self.accessMode = accessMode
        self.commandRunner = commandRunner
        self.appNavigation = appNavigation
        self.applicationPreferences = applicationPreferences
        self.startupRecoveryBlockedReason = startupRecoveryBlockedReason
        self.retryStartupRecovery = retryStartupRecovery
        self.runtimeRepairDidSucceed = runtimeRepairDidSucceed
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
        button.image = SiloStatusIcon.image(for: model.statusIconState)
        button.title = ""
        button.identifier = NSUserInterfaceItemIdentifier("statusItem.button")
        button.setAccessibilityIdentifier("statusItem.button")
        button.setAccessibilityLabel("Silo")
        let initialHealth = model.health
        button.toolTip = "Silo — \(initialHealth.title). \(initialHealth.detail)"
        button.target = self
        button.action = #selector(togglePopover)
        observeModelStatus()
    }

    var statusButton: NSStatusBarButton? { statusItem.button }
    func tearDown() {
        setupWindowController?.close()
        runtimeRepairWindowController?.close()
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
                NSApp.keyWindow?.title = "Silo"
            }
        }
    }

    func showSetupForFirstLaunch() {
        showSetup()
    }

    func showRuntimeRepair() {
        popover.performClose(nil)
        model.setPollingVisible(false)
        if runtimeRepairWindowController == nil {
            runtimeRepairWindowController = RuntimeRepairWindowController(
                coordinator: bootstrapCoordinator,
                uiTestMode: ProcessInfo.processInfo.arguments.contains("--ui-test-runtime-repair"),
                repairDidSucceed: { [weak self] in
                    self?.model.runtimeRepairDidSucceed()
                    self?.runtimeRepairDidSucceed()
                },
                close: { [weak self] in
                    self?.closeRuntimeRepair()
                }
            )
        }
        runtimeRepairWindowController?.show()
    }

    func closeRuntimeRepair() {
        runtimeRepairWindowController?.close()
        runtimeRepairWindowController = nil
    }


    func showMain(for deepLink: URL) {
        guard let route = AppRoute(deepLink: deepLink) else { return }
        showMain(route: route)
    }

    private func showSetup() {
        popover.performClose(nil)
        model.setPollingVisible(false)
        closeRuntimeRepair()
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
                githubState: githubSettingsState,
                accessMode: accessMode,
                commandRunner: commandRunner,
                applicationPreferences: applicationPreferences,
                openSettings: { [weak self] tab in
                    self?.showMain(route: AppRoute(tab: tab), dismissingSetup: false)
                },
                closeSetup: { [weak self] configurations in
                    self?.setupWindowController?.close()
                    self?.model.reloadWorkspaceConfiguration(configurations)
                },
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
            _ = model.health
            _ = model.runtimeRepairRequired
            _ = model.statusIconState
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
        let iconState = model.statusIconState
        button.contentTintColor = SiloStatusIcon.tint(for: iconState)
        button.image = SiloStatusIcon.image(for: iconState)
        if model.runtimeRepairRequired {
            button.toolTip = "Silo — \(RuntimeRepairPresentation.message)"
            button.setAccessibilityValue(RuntimeRepairPresentation.statusValue)
            button.setAccessibilityHelp(RuntimeRepairAccessibilityIdentifier.statusWarning)
            popover.contentSize = NSSize(width: 340, height: 324)
        } else {
            button.toolTip = "Silo — \(health.title). \(health.detail)"
            button.setAccessibilityValue("\(health.title). \(health.detail)")
            button.setAccessibilityHelp(nil)
            popover.contentSize = NSSize(width: 340, height: 280)
        }
    }
}

@MainActor
private final class RuntimeRepairWindowController {
    private let window: NSWindow

    init(
        coordinator: (any SiloBootstrapCoordinating)?,
        uiTestMode: Bool,
        repairDidSucceed: @escaping () -> Void,
        close: @escaping () -> Void
    ) {
        var uiTestRepairAttempt = 0
        let repair: @MainActor () async throws -> Void = {
            if uiTestMode {
                uiTestRepairAttempt += 1
                try await Task.sleep(for: .milliseconds(800))
                if uiTestRepairAttempt == 1 {
                    throw RuntimeRepairFailure(diagnosticDetails: """
                    Installing dependency fixture
                    Final fixture error: package metadata was unavailable.
                    """)
                }
                return
            }
            guard let coordinator else { throw RuntimeRepairPageError.unavailable }
            try await coordinator.repairRuntime()
        }
        let hosting = NSHostingController(rootView: RuntimeRepairView(
            repair: repair,
            repairDidSucceed: repairDidSucceed,
            close: close
        ))
        hosting.sizingOptions = []
        window = NSWindow(contentViewController: hosting)
        window.identifier = NSUserInterfaceItemIdentifier(RuntimeRepairAccessibilityIdentifier.repairWindow)
        hosting.view.setAccessibilityIdentifier(RuntimeRepairAccessibilityIdentifier.repairWindow)
        window.title = "Repair Silo Installation"
        window.setContentSize(NSSize(width: 500, height: 430))
        window.minSize = NSSize(width: 460, height: 360)
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() { window.close() }
}

private enum RuntimeRepairPageError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "Runtime repair is unavailable in this app session."
    }
}

private struct RuntimeRepairView: View {
    private enum Phase: Equatable {
        case needed
        case repairing
        case succeeded
        case failed(String)
    }

    let repair: @MainActor () async throws -> Void
    let repairDidSucceed: () -> Void
    let close: () -> Void
    @State private var phase: Phase = .needed
    @State private var diagnosticDetails: String?
    @State private var detailsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .accessibilityHidden(true)
                Text("Silo installation needs repair")
                    .accessibilityIdentifier(RuntimeRepairAccessibilityIdentifier.repairTitle)
            }
            .font(.title2.weight(.semibold))
            .foregroundStyle(.orange)

            Text("Reinstall the bundled Silo runtime and verify its exact command identity.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(RuntimeRepairAccessibilityIdentifier.repairMessage)

            switch phase {
            case .needed:
                EmptyView()
            case .repairing:
                ProgressView("Repairing installation…")
                    .accessibilityIdentifier(RuntimeRepairAccessibilityIdentifier.repairProgress)
            case .succeeded:
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .accessibilityHidden(true)
                    Text("Installation repaired")
                        .accessibilityIdentifier(RuntimeRepairAccessibilityIdentifier.repairResult)
                }
                .foregroundStyle(.green)
            case .failed(let message):
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .accessibilityHidden(true)
                    Text(message)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(RuntimeRepairAccessibilityIdentifier.repairResult)
                }
                .foregroundStyle(.primary)
            }

            if case .failed = phase, let diagnosticDetails {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        detailsExpanded.toggle()
                    } label: {
                        Label(
                            detailsExpanded ? "Hide Details" : "Show Details",
                            systemImage: detailsExpanded ? "chevron.down" : "chevron.right"
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(RuntimeRepairAccessibilityIdentifier.repairDetailsDisclosure)

                    if detailsExpanded {
                        ScrollView([.horizontal, .vertical]) {
                            Text(diagnosticDetails)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier(RuntimeRepairAccessibilityIdentifier.repairDetails)
                        }
                        .frame(maxHeight: 150)
                        .padding(8)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))

                        Button("Copy Details") {
                            NSPasteboard.general.clearContents()
                            _ = NSPasteboard.general.setString(diagnosticDetails, forType: .string)
                        }
                        .accessibilityIdentifier(RuntimeRepairAccessibilityIdentifier.repairCopyDetails)
                    }
                }
            }

            Spacer()

            HStack {
                Spacer()
                Button("Close", action: close)
                    .disabled(phase == .repairing)
                    .accessibilityIdentifier(RuntimeRepairAccessibilityIdentifier.repairClose)
                Button("Repair Installation") {
                    runRepair()
                }
                .buttonStyle(.borderedProminent)
                .disabled(phase == .repairing || phase == .succeeded)
                .accessibilityIdentifier(RuntimeRepairAccessibilityIdentifier.repairAction)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .overlay(alignment: .topLeading) {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityLabel("Runtime repair")
                .accessibilityIdentifier(RuntimeRepairAccessibilityIdentifier.repairPage)
        }
    }

    private func runRepair() {
        guard phase != .repairing else { return }
        diagnosticDetails = nil
        detailsExpanded = false
        phase = .repairing
        Task { @MainActor in
            do {
                try await repair()
                diagnosticDetails = nil
                phase = .succeeded
                repairDidSucceed()
            } catch {
                let failure = (error as? RuntimeRepairFailure) ?? RuntimeRepairFailure(error: error)
                diagnosticDetails = failure.diagnosticDetails
                phase = .failed(failure.localizedDescription)
            }
        }
    }
}
