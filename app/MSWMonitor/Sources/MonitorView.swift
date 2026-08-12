import SwiftUI

struct MonitorHealth {
    enum Severity {
        case normal
        case neutral
        case attention
        case critical
    }

    let title: String
    let detail: String
    let symbol: String
    let severity: Severity

    @MainActor
    static func resolve(_ model: AppModel) -> MonitorHealth {
        let observed = model.lastObservedAt.map {
            "Last observed \($0.formatted(date: .abbreviated, time: .shortened))"
        } ?? "No successful state observation yet"

        if model.workspaces.contains(where: { $0.state == .quarantined || $0.credential == .quarantined }) {
            return MonitorHealth(
                title: "Action required",
                detail: "A workspace is quarantined. Unsafe actions are blocked. \(observed)",
                symbol: "exclamationmark.octagon.fill",
                severity: .critical
            )
        }
        if let error = model.lastError {
            return MonitorHealth(
                title: "Needs attention",
                detail: "Refresh failed; showing last known state. \(error)",
                symbol: "exclamationmark.triangle.fill",
                severity: .attention
            )
        }
        if model.lastObservedAt == nil || model.workspaces.contains(where: {
            $0.state == .unknown || $0.freshness == .neverObserved
        }) {
            return MonitorHealth(
                title: model.isRefreshing ? "Observing…" : "Not observed",
                detail: model.isRefreshing ? "Requesting an authoritative workspace snapshot." : observed,
                symbol: model.isRefreshing ? "arrow.triangle.2.circlepath" : "questionmark.circle",
                severity: .neutral
            )
        }
        if model.workspaces.contains(where: { $0.state == .unavailable || $0.freshness == .unavailable }) {
            return MonitorHealth(
                title: "Unavailable",
                detail: "Some workspace state is unavailable. Last-known values remain visible. \(observed)",
                symbol: "exclamationmark.triangle.fill",
                severity: .attention
            )
        }
        if model.workspaces.contains(where: { $0.freshness == .stale }) {
            return MonitorHealth(
                title: "Showing last known state",
                detail: "Workspace data is stale; actions that require fresh state are blocked. \(observed)",
                symbol: "clock.badge.exclamationmark",
                severity: .attention
            )
        }
        if model.workspaces.contains(where: { $0.state == .exited || $0.credential.needsAttention }) {
            return MonitorHealth(
                title: "Needs attention",
                detail: "One or more workspaces has a recovery step. \(observed)",
                symbol: "exclamationmark.triangle.fill",
                severity: .attention
            )
        }
        if model.isRefreshing {
            return MonitorHealth(
                title: "Refreshing…",
                detail: "Keeping the last verified snapshot visible. \(observed)",
                symbol: "arrow.triangle.2.circlepath",
                severity: .normal
            )
        }
        return MonitorHealth(
            title: "Ready",
            detail: observed,
            symbol: "checkmark.circle.fill",
            severity: .normal
        )
    }
}

private extension Workspace.CredentialState {
    var needsAttention: Bool {
        switch self {
        case .ready, .readOnly, .unconfigured:
            return false
        case .legacy, .expiring, .needsRestart, .needsAuthorization, .serviceUnavailable,
             .removalPending, .quarantined:
            return true
        }
    }
}

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
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            ScrollView {
                workspaceList
                    .padding(.vertical, 2)
            }
            Divider()
            observationFooter
        }
        .padding(16)
        .frame(minWidth: 360, idealWidth: 420, maxWidth: 480, minHeight: 360, idealHeight: 590, maxHeight: 720)
        .confirmationDialog(
            "Confirm workspace action",
            isPresented: Binding(
                get: { model.pendingLifecyclePlan != nil },
                set: { if !$0 { model.cancelPendingLifecycle() } }
            ),
            titleVisibility: .visible
        ) {
            if let plan = model.pendingLifecyclePlan {
                Button("Confirm \(plan.action.capitalized)", role: .destructive) {
                    model.confirmPendingLifecycle()
                }
                Button("Cancel", role: .cancel) {
                    model.cancelPendingLifecycle()
                }
            }
        } message: {
            if let plan = model.pendingLifecyclePlan {
                Text("Workspace: \(plan.workspace)\n\(plan.effects)\nThe reviewed plan expires at \(plan.expiresAt.formatted(date: .omitted, time: .shortened)) and will be rejected if state changes.")
            } else {
                Text("Review the workspace effect before continuing.")
            }
        }
    }

    private var health: MonitorHealth { MonitorHealth.resolve(model) }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: health.symbol)
                .font(.title3)
                .foregroundStyle(color(for: health.severity))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.title)
                    .font(.headline)
                    .accessibilityIdentifier("monitor.title")
                Text(health.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(color(for: health.severity))
                    .accessibilityIdentifier("monitor.health")
                Text(health.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("monitor.observed-at")
            }
            Spacer(minLength: 8)
            Button {
                model.refresh()
            } label: {
                Label(model.lastError == nil ? "Refresh" : "Retry", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("r")
            .disabled(model.isRefreshing)
            .accessibilityIdentifier("refresh.button")
            .help("Request a fresh workspace state snapshot")
        }
        .accessibilityElement(children: .contain)
    }

    private var workspaceList: some View {
        LazyVStack(spacing: 10) {
            ForEach(model.workspaces) { workspace in
                WorkspaceCard(
                    workspace: workspace,
                    model: model,
                    openDetails: openDetails,
                    openSetup: openSetup
                )
            }
        }
    }

    private var observationFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.observationText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("observation.value")
            if let error = model.lastError {
                RecoveryNotice(
                    title: "Refresh failed",
                    message: error,
                    actionTitle: "Retry",
                    action: model.refresh
                )
                .accessibilityIdentifier("monitor.error")
            }
            HStack {
                if let openSetup {
                    Button("Setup", action: openSetup)
                        .accessibilityIdentifier("setup.button")
                        .help("Review or repair MSW Monitor setup")
                }
                Button("Activity") {
                    openDetails(DetailRoute(workspace: nil, section: .activity))
                }
                .accessibilityIdentifier("activity.button")
                Button("Settings", action: openSettings)
                    .accessibilityIdentifier("settings.button")
                Spacer()
            }
            HStack {
                Button("Open Details") {
                    openDetails(DetailRoute(workspace: model.selectedWorkspace, section: .overview))
                }
                .accessibilityIdentifier("details.button")
                Spacer()
                Button("Quit", action: quit)
                    .keyboardShortcut("q")
                    .accessibilityIdentifier("quit.button")
            }
        }
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

private struct WorkspaceCard: View {
    let workspace: Workspace
    @Bindable var model: AppModel
    let openDetails: (DetailRoute) -> Void
    let openSetup: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(workspace.id.rawValue)
                        .font(.body.weight(.semibold))
                        .accessibilityIdentifier("workspace.\(workspace.id.rawValue).name")
                    Text(workspace.purpose)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    Image(systemName: stateSymbol).accessibilityHidden(true)
                    Text(workspace.state.rawValue)
                        .accessibilityIdentifier("workspace.\(workspace.id.rawValue).state")
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(stateColor)
            }

            if showsFreshnessNotice {
                Label(freshnessMessage, systemImage: freshnessSymbol)
                    .font(.caption)
                    .foregroundStyle(workspace.freshness == .stale ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("workspace.\(workspace.id.rawValue).freshness")
            }

            if let reason = workspace.quarantineReason ?? workspace.statusReason,
               workspace.state == .quarantined || workspace.state == .unknown || workspace.state == .unavailable {
                Text(workspace.state == .quarantined ? "Quarantine reason: \(reason)" : reason)
                    .font(.caption)
                    .foregroundStyle(workspace.state == .quarantined ? .red : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let recovery = workspace.recoveryAction,
               workspace.freshness != .fresh || workspace.credential.needsAttention {
                Text("Recovery: \(recovery)")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Label(workspace.credential.rawValue, systemImage: credentialSymbol)
                    .font(.caption)
                    .foregroundStyle(credentialColor)
                    .accessibilityIdentifier("workspace.\(workspace.id.rawValue).credential")
                Spacer()
                Text("Next: \(workspace.nextAction)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if let operation = currentOperation {
                OperationPhaseView(operation: operation)
            }

            HStack(spacing: 8) {
                primaryAction
                if workspace.canStop && (workspace.state == .running || workspace.state == .quarantined) {
                    Button(workspace.state == .quarantined ? "Stop Safely" : "Stop") {
                        model.stop(workspace.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("workspace.\(workspace.id.rawValue).stop")
                }
                Spacer()
                actionsMenu
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(stateColor.opacity(0.22))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityIdentifier("workspace.\(workspace.id.rawValue).card")
    }

    @ViewBuilder
    private var primaryAction: some View {
        if workspace.state == .quarantined {
            Button("Review Recovery") {
                openDetails(DetailRoute(workspace: workspace.id, section: .diagnostics))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        } else if workspace.freshness == .stale || workspace.freshness == .unavailable || workspace.state == .unknown || workspace.state == .unavailable {
            Button("Retry Observation") { model.refresh() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(model.isRefreshing)
        } else if workspace.credential == .needsRestart && workspace.canRestart && workspace.state == .running {
            Button("Restart to Apply Access") { model.restart(workspace.id) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        } else if workspace.credential == .needsAuthorization || workspace.credential == .legacy || workspace.credential == .expiring {
            if let openSetup {
                Button(workspace.credential == .legacy ? "Migrate Access" : "Review Authorization") { openSetup() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            } else {
                Button("Review Access") {
                    openDetails(DetailRoute(workspace: workspace.id, section: .github))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        } else if workspace.credential == .serviceUnavailable || workspace.credential == .removalPending || workspace.credential == .quarantined {
            Button("Review Access Recovery") {
                openDetails(DetailRoute(workspace: workspace.id, section: .github))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        } else if workspace.state == .running && workspace.freshness == .fresh && workspace.canOpenTerminal {
            Button("Open Terminal") { model.openTerminal(for: workspace.id) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        } else if workspace.canStart && workspace.state != .running {
            Button("Start") { model.start(workspace.id) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier("workspace.\(workspace.id.rawValue).start")
        } else {
            Button("View Details") {
                openDetails(DetailRoute(workspace: workspace.id, section: .overview))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    private var actionsMenu: some View {
        Menu("Actions") {
            Button("Start \(workspace.id.rawValue)") { model.start(workspace.id) }
                .disabled(!workspace.canStart || workspace.state == .running)
            Button("Stop \(workspace.id.rawValue)") { model.stop(workspace.id) }
                .disabled(!workspace.canStop || (workspace.state != .running && workspace.state != .quarantined))
            Button("Restart \(workspace.id.rawValue)") { model.restart(workspace.id) }
                .disabled(!workspace.canRestart || workspace.state != .running)
            Divider()
            Menu("Open Site for \(workspace.id.rawValue)") {
                Button("Port 3000") { model.openSite(for: workspace.id, port: "3000") }
                ForEach(publishedSitePorts, id: \.self) { port in
                    Button("Port \(port)") { model.openSite(for: workspace.id, port: port) }
                }
                Divider()
                Button("Choose another port…") {
                    model.selectedWorkspace = workspace.id
                    openDetails(DetailRoute(workspace: workspace.id, section: .ports))
                }
            }
            .disabled(!canOpenSiteAction)
            Button("Open Terminal for \(workspace.id.rawValue)") { model.openTerminal(for: workspace.id) }
                .disabled(!canOpenTerminalAction)
            Button("Open \(workspace.id.rawValue) in Zed") { model.openZed(for: workspace.id) }
                .disabled(!canOpenZedAction)
            Divider()
            Button("Repositories for \(workspace.id.rawValue)") {
                model.selectedWorkspace = workspace.id
                openDetails(DetailRoute(workspace: workspace.id, section: .repositories))
            }
            Button("All details for \(workspace.id.rawValue)") {
                model.selectedWorkspace = workspace.id
                openDetails(DetailRoute(workspace: workspace.id, section: .overview))
            }
        }
        .accessibilityIdentifier("workspace.\(workspace.id.rawValue).actions")
        .help("Actions scoped to \(workspace.id.rawValue)")
    }

    private var canOpenTerminalAction: Bool {
        workspace.state == .running &&
            workspace.freshness == .fresh &&
            workspace.canOpenTerminal &&
            workspace.credential != .quarantined
    }

    private var canOpenZedAction: Bool {
        workspace.state == .running &&
            workspace.freshness == .fresh &&
            workspace.credential != .quarantined
    }

    private var canOpenSiteAction: Bool {
        canOpenZedAction && workspace.networkHost != nil
    }

    private var publishedSitePorts: [String] {
        guard let snapshot = model.portsSnapshot,
              snapshot.workspace == workspace.id.rawValue else {
            return []
        }
        return snapshot.published.map(\.port).filter { !$0.isEmpty && $0 != "3000" }
    }

    private var currentOperation: MSWOperationState? {
        model.operationStates.values
            .filter { $0.workspace == workspace.id.rawValue && $0.kind == .lifecycle }
            .max { $0.updatedAt < $1.updatedAt }
    }

    private var showsFreshnessNotice: Bool {
        workspace.freshness != .fresh || workspace.observedAt != nil
    }

    private var freshnessMessage: String {
        let age = workspace.observedAt.map {
            " Last observed \($0.formatted(date: .abbreviated, time: .shortened))."
        } ?? " No successful observation is available."
        switch workspace.freshness {
        case .fresh: return "Fresh.\(age)"
        case .stale: return "Showing last known state; fresh-state actions are blocked.\(age)"
        case .unavailable: return "Current state unavailable; last-known content may be shown.\(age)"
        case .neverObserved: return "Not observed.\(age)"
        }
    }

    private var freshnessSymbol: String {
        switch workspace.freshness {
        case .fresh: return "checkmark.circle"
        case .stale: return "clock.badge.exclamationmark"
        case .unavailable: return "wifi.exclamationmark"
        case .neverObserved: return "questionmark.circle"
        }
    }

    private var stateSymbol: String {
        switch workspace.state {
        case .running: return "play.circle.fill"
        case .stopped: return "stop.circle"
        case .starting, .stopping, .restarting: return "arrow.triangle.2.circlepath"
        case .quarantined: return "exclamationmark.octagon.fill"
        case .unknown, .unavailable, .exited: return "exclamationmark.triangle.fill"
        }
    }

    private var stateColor: Color {
        switch workspace.state {
        case .running: return .green
        case .quarantined: return .red
        case .unknown, .unavailable, .exited: return .orange
        case .starting, .stopping, .restarting: return .accentColor
        case .stopped: return .secondary
        }
    }

    private var credentialColor: Color {
        workspace.credential.needsAttention ? .orange : .secondary
    }

    private var credentialSymbol: String {
        switch workspace.credential {
        case .ready, .readOnly:
            return "checkmark.shield"
        case .unconfigured:
            return "shield"
        case .legacy, .needsAuthorization, .expiring:
            return "exclamationmark.shield"
        case .needsRestart:
            return "arrow.clockwise.circle"
        case .serviceUnavailable, .removalPending, .quarantined:
            return "xmark.shield"
        }
    }

    private var accessibilitySummary: String {
        "\(workspace.id.rawValue), \(workspace.state.rawValue), credential \(workspace.credential.rawValue), \(freshnessMessage) Next action: \(workspace.nextAction)\(workspace.quarantineReason.map { ". Quarantine reason: \($0)" } ?? "")"
    }
}

private struct OperationPhaseView: View {
    let operation: MSWOperationState

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let fraction = operation.fraction {
                ProgressView(value: fraction)
            } else if operation.outcome == .pending {
                ProgressView().controlSize(.small)
            }
            HStack {
                Text("Phase: \(phaseTitle)")
                    .font(.caption.weight(.medium))
                Spacer()
                Text(operation.workspace ?? "global")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Text(operation.message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if operation.outcome == .failed || operation.outcome == .unknown {
                Text(operation.recovery?.recovery ?? "Refresh state and review the latest activity before retrying.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(operation.workspace ?? "Global") \(operation.action) operation. \(phaseTitle). \(operation.message)")
    }

    private var phaseTitle: String {
        switch operation.phase {
        case .preparing: return "Preparing"
        case .awaitingConfirmation: return "Awaiting confirmation"
        case .running: return operation.fraction.map { "Running, \(Int($0 * 100)) percent" } ?? "Running, progress indeterminate"
        case .verifying: return "Verifying observed state"
        case .finished:
            switch operation.outcome {
            case .succeeded: return "Succeeded and verified"
            case .failed: return "Failed"
            case .unknown: return "Outcome unknown"
            case .pending: return "Finishing"
            }
        }
    }
}

private struct RecoveryNotice: View {
    let title: String
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(actionTitle, action: action)
                .controlSize(.small)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
