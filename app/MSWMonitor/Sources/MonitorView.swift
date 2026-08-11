import SwiftUI

struct MonitorView: View {
    static let title = "MSW Monitor"

    @Bindable var model: AppModel
    let quit: () -> Void
    let openDetails: () -> Void
    let openSettings: () -> Void
    let openSetup: (() -> Void)?

    init(
        model: AppModel,
        quit: @escaping () -> Void,
        openDetails: @escaping () -> Void = {},
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
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            workspaceList
            Divider()
            observationFooter
        }
        .padding(16)
        .frame(width: 410)
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
                Text("\(plan.effects)\nThis applies only the reviewed \(plan.confirmationPhrase) plan and is rejected if workspace state changes first.")
            } else {
                Text("Review the workspace effect before continuing.")
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.title)
                    .font(.headline)
                    .accessibilityIdentifier("monitor.title")
                Text(model.aggregateText)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(model.lastError == nil ? Color.secondary : Color.orange)
                    .accessibilityIdentifier("monitor.health")
                Text(model.aggregateDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("monitor.observed-at")
            }
            Spacer(minLength: 8)
            Button {
                model.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("r")
            .accessibilityIdentifier("refresh.button")
            .help("Refresh workspace state")
        }
    }

    private var workspaceList: some View {
        VStack(spacing: 10) {
            ForEach(model.workspaces) { workspace in
                WorkspaceCard(workspace: workspace, model: model, openDetails: openDetails)
            }
        }
    }

    private var observationFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.observationText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("observation.value")
                    if let error = model.lastError {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                            .accessibilityIdentifier("monitor.error")
                    }
                }
                Spacer()
                if let openSetup {
                    Button("Setup", action: openSetup)
                        .accessibilityIdentifier("setup.button")
                        .help("Review or repair MSW Monitor setup")
                }
                Button("Activity", action: openDetails)
                    .accessibilityIdentifier("activity.button")
                Button("Settings", action: openSettings)
                    .accessibilityIdentifier("settings.button")
            }
            HStack {
                Button("Open Details", action: openDetails)
                    .accessibilityIdentifier("details.button")
                Spacer()
                Button("Quit", action: quit)
                    .keyboardShortcut("q")
                    .accessibilityIdentifier("quit.button")
            }
        }
    }
}


private struct WorkspaceCard: View {
    let workspace: Workspace
    @Bindable var model: AppModel
    let openDetails: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                Text(workspace.id.rawValue)
                        .font(.body.weight(.semibold))
                        .accessibilityIdentifier("workspace.\(workspace.id.rawValue).name")
                    Text(workspace.purpose)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(workspace.state.rawValue)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(stateColor)
                    .accessibilityIdentifier("workspace.\(workspace.id.rawValue).state")
            }
            HStack(spacing: 8) {
                Label(workspace.credential.rawValue, systemImage: credentialSymbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("workspace.\(workspace.id.rawValue).credential")
                Text(workspace.freshness.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("workspace.\(workspace.id.rawValue).freshness")
                Spacer()
                Text(workspace.nextAction)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                if workspace.canStart && workspace.state != .running {
                    Button("Start") { model.start(workspace.id) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .accessibilityIdentifier("workspace.\(workspace.id.rawValue).start")
                }
                if workspace.canStop && (workspace.state == .running || workspace.state == .quarantined) {
                    Button("Stop") { model.stop(workspace.id) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("workspace.\(workspace.id.rawValue).stop")
                }
                if workspace.canRestart && workspace.state == .running {
                    Button("Restart") { model.restart(workspace.id) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("workspace.\(workspace.id.rawValue).restart")
                }
                Spacer()
                Menu("Actions") {
                    Button("Start") { model.start(workspace.id) }
                        .disabled(!workspace.canStart || workspace.state == .running)
                    Button("Stop") { model.stop(workspace.id) }
                        .disabled(!workspace.canStop || (workspace.state != .running && workspace.state != .quarantined))
                    Button("Restart") { model.restart(workspace.id) }
                        .disabled(!workspace.canRestart || workspace.state != .running)
                    Divider()
                    Button("Open Site") { model.openSite(for: workspace.id) }
                        .disabled(workspace.state != .running || workspace.freshness != .fresh)
                    Button("Open Terminal") { model.openTerminal(for: workspace.id) }
                        .disabled(workspace.state != .running || workspace.freshness != .fresh)
                    Button("Open in Zed") { model.openZed(for: workspace.id) }
                        .disabled(workspace.state != .running || workspace.freshness != .fresh)
                    Button("Repositories") {
                        model.selectedWorkspace = workspace.id
                        openDetails()
                    }
                }
                .accessibilityIdentifier("workspace.\(workspace.id.rawValue).actions")
            }
        }
        .padding(11)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(workspace.id.rawValue), \(workspace.state.rawValue), \(workspace.credential.rawValue), \(workspace.freshness.rawValue). Next action: \(workspace.nextAction)\(workspace.quarantineReason.map { ". Quarantine reason: \($0)" } ?? "")")
        .accessibilityIdentifier("workspace.\(workspace.id.rawValue).card")
    }

    private var stateColor: Color {
        switch workspace.state {
        case .running: return .green
        case .unknown, .unavailable, .quarantined: return .orange
        default: return .secondary
        }
    }

    private var credentialSymbol: String {
        switch workspace.credential {
        case .ready, .readOnly:
            return "checkmark.shield"
        case .needsAuthorization, .legacy, .removalPending, .quarantined,
             .serviceUnavailable, .unconfigured, .expiring, .needsRestart:
            return "exclamationmark.shield"
        }
    }
}
