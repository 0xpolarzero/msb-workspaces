import SwiftUI

struct MonitorView: View {
    static let title = "MSW Monitor"

    @Bindable var model: AppModel
    let quit: () -> Void
    let openDetails: (DetailRoute) -> Void
    let openSettings: () -> Void
    let openSetup: (() -> Void)?

    init(
        model: AppModel,
        quit: @escaping () -> Void,
        openDetails: @escaping (DetailRoute) -> Void = { _ in },
        openSettings: @escaping () -> Void = {},
        openSetup: (() -> Void)? = nil
    ) {
        self.model = model
        self.quit = quit
        self.openDetails = openDetails
        self.openSettings = openSettings
        self.openSetup = openSetup
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(12)

            Divider()

            ForEach(Array(model.workspaces.enumerated()), id: \.element.id) { index, workspace in
                WorkspaceRow(
                    workspace: workspace,
                    operation: currentOperation(for: workspace),
                    publishedSitePorts: publishedSitePorts(for: workspace),
                    model: model,
                    openDetails: openDetails,
                    openSetup: openSetup
                )

                if index < model.workspaces.count - 1 {
                    Divider()
                        .padding(.leading, 38)
                }
            }

            Divider()
            shortcuts
                .padding(10)
        }
        .frame(width: 340)
        .confirmationDialog(
            model.pendingLifecyclePlan.map { "\($0.action.capitalized) \($0.workspace)?" } ?? "Confirm workspace action",
            isPresented: Binding(
                get: { model.pendingLifecyclePlan != nil },
                set: { if !$0 { model.cancelPendingLifecycle() } }
            ),
            titleVisibility: .visible
        ) {
            if let plan = model.pendingLifecyclePlan {
                Button(plan.action.capitalized, role: confirmationRole(for: plan)) {
                    model.confirmPendingLifecycle()
                }
                .accessibilityIdentifier("lifecycle.confirm.button")
                Button("Cancel", role: .cancel) {
                    model.cancelPendingLifecycle()
                }
            }
        } message: {
            if let plan = model.pendingLifecyclePlan {
                Text(confirmationMessage(for: plan))
            } else {
                Text("Review the workspace effect before continuing.")
            }
        }
    }

    private func confirmationMessage(for plan: MSWLifecyclePlan) -> String {
        switch MSWLifecycleAction(rawValue: plan.action) {
        case .start:
            return "The \(plan.workspace) workspace will start."
        case .stop:
            return "The \(plan.workspace) workspace will stop. You can start it again later."
        case .restart:
            return "The \(plan.workspace) workspace will restart. Running processes may be interrupted."
        case nil:
            return plan.effects
        }
    }

    private func confirmationRole(for plan: MSWLifecyclePlan) -> ButtonRole? {
        switch MSWLifecycleAction(rawValue: plan.action) {
        case .stop, .restart:
            return .destructive
        case .start, nil:
            return nil
        }
    }

    private var header: some View {
        let health = model.health
        return HStack(spacing: 8) {
            Text(Self.title)
                .font(.headline)
                .accessibilityIdentifier("monitor.title")
            Spacer()
            Label(health.title, systemImage: health.symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(color(for: health.severity))
                .accessibilityIdentifier("monitor.health")
            if let failure = model.latestOperationFailure {
                Button {
                    openDetails(DetailRoute(
                        workspace: failure.workspace,
                        section: failure.workspace == nil ? .activity : .logs
                    ))
                } label: {
                    Label("View Error Details", systemImage: "doc.text.magnifyingglass")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("error.details.button")
                .help("View error details")
            } else if model.lastError != nil || model.startupRecoveryBlockedReason != nil {
                Button {
                    model.refresh()
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("retry.button")
                .help("Retry workspace observation")
            }
        }
    }

    private var shortcuts: some View {
        HStack(spacing: 8) {
            Button {
                openDetails(DetailRoute(workspace: model.selectedWorkspace, section: .overview))
            } label: {
                Label("Overview", systemImage: "rectangle.split.2x1")
            }
            .accessibilityIdentifier("details.button")

            Spacer()


            Button(action: openSettings) {
                Label("Settings", systemImage: "gearshape")
                    .labelStyle(.iconOnly)
            }
            .accessibilityIdentifier("settings.button")
            .help("Open settings")

            if let openSetup {
                Button(action: openSetup) {
                    Label("Setup", systemImage: "wrench.and.screwdriver")
                        .labelStyle(.iconOnly)
                }
                .accessibilityIdentifier("setup.button")
                .help("Review setup")
            }

            Button(action: quit) {
                Label("Quit", systemImage: "power")
                    .labelStyle(.iconOnly)
            }
            .keyboardShortcut("q")
            .accessibilityIdentifier("quit.button")
            .help("Quit MSW Monitor")
        }
        .controlSize(.small)
    }

    private func currentOperation(for workspace: Workspace) -> MSWOperationState? {
        model.operationStates.values
            .filter { $0.workspace == workspace.id.rawValue && $0.kind == .lifecycle }
            .max { $0.updatedAt < $1.updatedAt }
    }

    private func publishedSitePorts(for workspace: Workspace) -> [String] {
        guard let snapshot = model.portsSnapshot,
              snapshot.workspace == workspace.id.rawValue else {
            return []
        }
        return snapshot.published.map(\.port).filter { !$0.isEmpty && $0 != "3000" }
    }

    private func color(for severity: MonitorHealth.Severity) -> Color {
        switch severity {
        case .normal: return .green
        case .neutral: return .secondary
        case .attention: return .orange
        case .critical: return .red
        }
    }
}

private struct WorkspaceRow: View {
    let workspace: Workspace
    let operation: MSWOperationState?
    let publishedSitePorts: [String]
    @Bindable var model: AppModel
    let openDetails: (DetailRoute) -> Void
    let openSetup: (() -> Void)?
    @State private var isFolderPickerPresented = false


    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(stateColor)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.id.rawValue)
                    .font(.body.weight(.medium))
                    .accessibilityIdentifier("workspace.\(workspace.id.rawValue).name")
                Text(workspace.state.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("workspace.\(workspace.id.rawValue).state")
            }

            Spacer(minLength: 8)

            if operation?.outcome == .pending {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("\(workspace.id.rawValue) \(operation?.action ?? "workspace") in progress")
            } else {
                primaryAction
            }

            actionsMenu
                .labelStyle(.iconOnly)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.\(workspace.id.rawValue).row")
    }

    @ViewBuilder
    private var primaryAction: some View {
        if workspace.state == .quarantined {
            compactButton("Review", systemImage: "exclamationmark.triangle") {
                openDetails(DetailRoute(workspace: workspace.id, section: .diagnostics))
            }
        } else if workspace.freshness != .fresh || workspace.state == .unknown || workspace.state == .unavailable {
            compactButton("Retry", systemImage: "arrow.clockwise") {
                model.refresh()
            }
        } else if workspace.credential == .needsRestart && workspace.canRestart && workspace.state == .running {
            compactButton("Restart", systemImage: "arrow.clockwise") {
                model.restart(workspace.id)
            }
        } else if workspace.credential.needsAttention {
            compactButton("Review access", systemImage: "exclamationmark.shield") {
                if let openSetup {
                    openSetup()
                } else {
                    openDetails(DetailRoute(workspace: workspace.id, section: .github))
                }
            }
        } else if canOpenWorkspace {
            compactButton(model.terminalActionTitle, systemImage: "terminal") {
                model.openTerminal(for: workspace.id)
            }
            .accessibilityIdentifier("workspace.\(workspace.id.rawValue).open-terminal")
        } else if workspace.canStart && workspace.state != .running {
            compactButton("Start", systemImage: "play.fill") {
                model.start(workspace.id)
            }
            .accessibilityIdentifier("workspace.\(workspace.id.rawValue).start")
        } else {
            compactButton("View Details", systemImage: "arrow.up.right") {
                openDetails(DetailRoute(workspace: workspace.id, section: .overview))
            }
        }
    }

    private func compactButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .help(title)
    }

    private var actionsMenu: some View {
        Menu {
            if workspace.canStart && workspace.state != .running {
                Button("Start \(workspace.id.rawValue)") { model.start(workspace.id) }
            }
            if workspace.canStop && (workspace.state == .running || workspace.state == .quarantined) {
                Button("Stop \(workspace.id.rawValue)") { model.stop(workspace.id) }
            }
            if workspace.canRestart && workspace.state == .running {
                Button("Restart \(workspace.id.rawValue)") { model.restart(workspace.id) }
            }
            if workspace.canStart || workspace.canStop || workspace.canRestart {
                Divider()
            }

            Button(model.terminalActionTitle) { model.openTerminal(for: workspace.id) }
                .disabled(!canOpenWorkspace)
                .accessibilityIdentifier("workspace.\(workspace.id.rawValue).open-terminal")
            Button(model.editorActionTitle) {
                model.selectedWorkspace = workspace.id
                isFolderPickerPresented = true
            }
                .disabled(!canOpenWorkspace)
                .accessibilityIdentifier("workspace.\(workspace.id.rawValue).open-editor")
            Menu("Open Site") {
                Button("Port 3000") { model.openSite(for: workspace.id, port: "3000") }
                ForEach(publishedSitePorts, id: \.self) { port in
                    Button("Port \(port)") { model.openSite(for: workspace.id, port: port) }
                }
                Divider()
                Button("Choose Port…") {
                    model.selectedWorkspace = workspace.id
                    openDetails(DetailRoute(workspace: workspace.id, section: .ports))
                }
            }
            .disabled(!canOpenSite)

            Divider()
            Button("Repositories") {
                model.selectedWorkspace = workspace.id
                openDetails(DetailRoute(workspace: workspace.id, section: .repositories))
            }
            Button("Details") {
                model.selectedWorkspace = workspace.id
                openDetails(DetailRoute(workspace: workspace.id, section: .overview))
            }
        } label: {
            Label("Actions for \(workspace.id.rawValue)", systemImage: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityIdentifier("workspace.\(workspace.id.rawValue).actions")
        .help("More actions")
        .popover(isPresented: $isFolderPickerPresented, arrowEdge: .trailing) {
            FolderBrowserView(
                model: model,
                workspace: workspace.id,
                compact: true,
                title: "\(workspace.id.rawValue) folders",
                onClose: { isFolderPickerPresented = false }
            )
            .padding(14)
            .frame(width: 500, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("folders.popover.content")
        }
    }

    private var canOpenWorkspace: Bool {
        workspace.state == .running &&
            workspace.freshness == .fresh &&
            workspace.canOpenTerminal &&
            workspace.credential != .quarantined
    }

    private var canOpenSite: Bool {
        canOpenWorkspace && workspace.networkHost != nil
    }

    private var stateColor: Color {
        switch workspace.state {
        case .running: return .green
        case .quarantined: return .red
        case .unknown, .unavailable, .exited: return .orange
        case .starting, .stopping, .restarting: return .blue
        case .stopped: return .secondary
        }
    }
}
