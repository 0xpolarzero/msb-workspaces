import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum DetailSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case metrics = "Metrics"
    case logs = "Logs"
    case repositories = "Repositories"
    case ports = "Ports and tunnels"
    case github = "GitHub Access"
    case activity = "Activity"
    case backup = "Backup and Restore"
    case diagnostics = "Diagnostics and Maintenance"

    var id: String { rawValue }

    var requiresWorkspace: Bool {
        switch self {
        case .metrics, .logs, .repositories:
            return true
        default:
            return false
        }
    }

    init(deepLinkValue: String) {
        switch deepLinkValue.lowercased() {
        case "metrics": self = .metrics
        case "logs": self = .logs
        case "repositories": self = .repositories
        case "ports": self = .ports
        case "github", "github-access": self = .github
        case "activity": self = .activity
        case "backup", "backups", "restore": self = .backup
        case "diagnostics", "maintenance": self = .diagnostics
        default: self = .overview
        }
    }
}

struct DetailRoute: Equatable {
    let workspace: Workspace.ID?
    let section: DetailSection

    init(workspace: Workspace.ID?, section: DetailSection) {
        self.workspace = workspace
        self.section = section
    }

    init?(deepLink: URL) {
        guard deepLink.scheme == "msw-monitor" else { return nil }
        let components = URLComponents(url: deepLink, resolvingAgainstBaseURL: false)
        let workspace = deepLink.host == "workspace"
            ? deepLink.pathComponents
                .filter { $0 != "/" }
                .first
                .flatMap(Workspace.ID.init(rawValue:))
            : nil
        let requestedSection = components?.queryItems?
            .first(where: { $0.name == "section" })?
            .value ?? (deepLink.host == "workspace" ? "overview" : deepLink.host ?? "overview")
        self.init(workspace: workspace, section: DetailSection(deepLinkValue: requestedSection))
    }
}

@Observable
@MainActor
private final class DetailNavigationState {
    var workspace: Workspace.ID?
    var section: DetailSection

    init(route: DetailRoute) {
        workspace = route.workspace
        section = route.section
    }

    func apply(_ route: DetailRoute) {
        workspace = route.workspace
        section = route.section
    }
}

@MainActor
final class DetailWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let navigation: DetailNavigationState
    private let model: AppModel
    private let openSettings: @MainActor (SettingsSection) -> Void
    private let openSetup: @MainActor () -> Void
    private let onClose: @MainActor () -> Void

    init(
        model: AppModel,
        openSettings: @escaping @MainActor (SettingsSection) -> Void,
        openSetup: @escaping @MainActor () -> Void,
        onClose: @escaping @MainActor () -> Void
    ) {
        self.model = model
        navigation = DetailNavigationState(
            route: DetailRoute(workspace: model.selectedWorkspace, section: .overview)
        )
        self.openSettings = openSettings
        self.openSetup = openSetup
        let view = DetailView(
            model: model,
            navigation: navigation,
            openSettings: openSettings,
            openSetup: openSetup
        )
        let hosting = NSHostingController(rootView: view)
        window = NSWindow(contentViewController: hosting)
        self.onClose = onClose
        super.init()
        window.title = "MSW Monitor Details"
        window.setContentSize(NSSize(width: 900, height: 640))
        window.minSize = NSSize(width: 700, height: 480)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("MSWMonitorDetailWindow")
        window.delegate = self
        window.center()
    }

    func show(route: DetailRoute) {
        navigation.apply(route)
        model.selectedWorkspace = route.workspace
        window.title = route.workspace.map { "\($0.rawValue) — \(route.section.rawValue)" } ?? "MSW Monitor — \(route.section.rawValue)"
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

struct DetailView: View {
    @Bindable var model: AppModel
    @Bindable private var navigation: DetailNavigationState
    let openSettings: (SettingsSection) -> Void
    let openSetup: () -> Void
    @State private var restoreArchive: URL?
    @State private var backupDestination: URL?
    @State private var reviewBackup = false
    @State private var confirmRestore = false
    @State private var restoreConfirmation = ""
    @State private var pushConfirmation = ""
    @State private var maintenanceOperation: MaintenanceOperation?

    fileprivate init(
        model: AppModel,
        navigation: DetailNavigationState,
        openSettings: @escaping (SettingsSection) -> Void,
        openSetup: @escaping () -> Void
    ) {
        self.model = model
        self.navigation = navigation
        self.openSettings = openSettings
        self.openSetup = openSetup
    }

    var body: some View {
        NavigationSplitView {
            List(DetailSection.allCases, selection: $navigation.section) { section in
                Label(section.rawValue, systemImage: icon(for: section))
                    .tag(section)
            }
            .navigationTitle("MSW Monitor")
            .frame(minWidth: 200, idealWidth: 220)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                detailHeader
                    .padding(.horizontal, 22)
                    .padding(.vertical, 14)
                Divider()
                Group {
                    if navigation.section.requiresWorkspace && navigation.workspace == nil {
                        ContentUnavailableView(
                            "Choose a workspace",
                            systemImage: "square.stack.3d.up.badge.a",
                            description: Text("Select dev, playgrounds, or personal above. No workspace is selected implicitly.")
                        )
                    } else {
                        sectionContent
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(22)
            }
            .task(id: routeIdentity) { loadSelectedSection() }
        }
        .frame(minWidth: 700, minHeight: 480)
        .sheet(isPresented: Binding(
            get: { model.pendingPushPlan != nil },
            set: { presented in
                if !presented {
                    pushConfirmation = ""
                    model.cancelPendingPush()
                }
            }
        )) {
            if let plan = model.pendingPushPlan {
                PushConfirmationView(
                    plan: plan,
                    confirmation: $pushConfirmation,
                    cancel: {
                        pushConfirmation = ""
                        model.cancelPendingPush()
                    },
                    apply: {
                        let phrase = pushConfirmation
                        pushConfirmation = ""
                        model.confirmPendingPush(confirmation: phrase)
                    }
                )
            }
        }
        .sheet(isPresented: $reviewBackup) {
            if let backupDestination {
                BackupReviewView(
                    destination: backupDestination,
                    workspaces: model.workspaces,
                    isBusy: model.isMaintenanceOperationInFlight,
                    cancel: { reviewBackup = false },
                    apply: {
                        reviewBackup = false
                        beginBackup(to: backupDestination)
                    }
                )
            }
        }
        .sheet(isPresented: $confirmRestore, onDismiss: { restoreConfirmation = "" }) {
            if let restoreArchive {
                RestoreConfirmationView(
                    archive: restoreArchive,
                    workspaces: model.workspaces,
                    isBusy: model.isMaintenanceOperationInFlight,
                    confirmation: $restoreConfirmation,
                    cancel: { confirmRestore = false },
                    apply: {
                        let phrase = restoreConfirmation
                        confirmRestore = false
                        beginRestore(archive: restoreArchive, confirmation: phrase)
                    }
                )
            }
        }
        .onChange(of: model.isDetailLoading) { wasLoading, isLoading in
            guard wasLoading, !isLoading, maintenanceOperation != nil else { return }
            finishMaintenanceOperation()
        }
    }

    private var routeIdentity: String {
        "\(navigation.section.rawValue):\(navigation.workspace?.rawValue ?? "all")"
    }

    private var detailHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(navigation.section.rawValue)
                    .font(.title2.weight(.semibold))
                Text(scopeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Picker("Workspace", selection: workspaceBinding) {
                Text("All workspaces").tag(nil as Workspace.ID?)
                ForEach(Workspace.ID.allCases, id: \.rawValue) { id in
                    Text(id.rawValue).tag(Optional(id))
                }
            }
            .pickerStyle(.menu)
            .frame(width: 190)
            .accessibilityIdentifier("details.workspace-picker")
            .help("Select the workspace used by scoped detail actions")
        }
    }

    private var workspaceBinding: Binding<Workspace.ID?> {
        Binding(
            get: { navigation.workspace },
            set: { value in
                navigation.workspace = value
                model.selectedWorkspace = value
            }
        )
    }

    private var scopeDescription: String {
        navigation.workspace.map { "Workspace: \($0.rawValue)" } ?? "Scope: all workspaces"
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch navigation.section {
        case .overview: overview
        case .metrics: metrics
        case .logs: logs
        case .repositories: repositories
        case .ports: ports
        case .github: github
        case .activity: activity
        case .backup: backup
        case .diagnostics: diagnostics
        }
    }

    private func loadSelectedSection() {
        model.clearDetailError()
        switch navigation.section {
        case .metrics:
            if let workspace = navigation.workspace { model.loadMetrics(for: workspace) }
        case .logs:
            if let workspace = navigation.workspace { model.loadLogs(for: workspace) }
        case .repositories:
            if let workspace = navigation.workspace { model.loadRepositories(for: workspace) }
        case .ports: model.loadPorts()
        case .github: model.loadGitHubState()
        case .diagnostics: model.runDiagnostics()
        default: break
        }
    }

    private var selectedWorkspace: Workspace? {
        guard let id = navigation.workspace else { return nil }
        return model.workspaces.first { $0.id == id }
    }

    private var selectedWorkspaceID: Workspace.ID? { navigation.workspace }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AggregateStatusView(model: model)
                ForEach(scopedWorkspaces) { workspace in
                    DetailWorkspaceCard(
                        workspace: workspace,
                        model: model,
                        openRepositories: {
                            navigation.workspace = workspace.id
                            model.selectedWorkspace = workspace.id
                            navigation.section = .repositories
                        }
                    )
                }
            }
        }
        .accessibilityIdentifier("details.overview")
    }

    private var scopedWorkspaces: [Workspace] {
        guard let workspace = navigation.workspace else { return model.workspaces }
        return model.workspaces.filter { $0.id == workspace }
    }

    private var metrics: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionToolbar(actionTitle: "Refresh") {
                if let id = selectedWorkspaceID { model.loadMetrics(for: id) }
            }
            if let id = selectedWorkspaceID, let value = model.metricsByWorkspace[id.rawValue] {
                FreshnessNotice(freshness: value.freshness, observedAt: selectedWorkspace?.observedAt, reason: value.reason)
                LabeledContent("Lifecycle", value: value.lifecycle.rawValue)
                LabeledContent("Available", value: value.available ? "Yes" : "No")
                if let snapshot = value.snapshot {
                    ScrollView {
                        Text(String(describing: snapshot))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                }
                loadingOverlay("Updating metrics snapshot")
            } else if model.isDetailLoading {
                OperationRow(phase: "Requesting metrics", scope: navigation.workspace?.rawValue, detail: "Waiting for a bounded metrics snapshot.")
            } else {
                ContentUnavailableView("No metrics snapshot", systemImage: "gauge", description: Text("Metrics are available only while the selected workspace is running."))
            }
            detailError
        }
    }

    private var logs: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionToolbar(actionTitle: "Refresh") {
                if let id = selectedWorkspaceID { model.loadLogs(for: id) }
            }
            Text("Logs are bounded and redacted before they reach the app.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let id = selectedWorkspaceID, let value = model.logsByWorkspace[id.rawValue] {
                FreshnessNotice(freshness: value.freshness, observedAt: selectedWorkspace?.observedAt, reason: value.reason)
                if value.lines.isEmpty {
                    ContentUnavailableView("No log lines", systemImage: "text.alignleft", description: Text(value.available ? "The runtime returned no bounded log lines." : "Logs are unavailable while the workspace is stopped."))
                } else {
                    List(Array(value.lines.enumerated()), id: \.offset) { _, line in
                        Text(line.message)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    .listStyle(.inset)
                }
                loadingOverlay("Updating bounded logs")
            } else if model.isDetailLoading {
                OperationRow(phase: "Requesting logs", scope: navigation.workspace?.rawValue, detail: "Waiting for sanitized log lines.")
            } else {
                ContentUnavailableView("No log snapshot", systemImage: "text.alignleft", description: Text("Refresh to inspect the bounded, redacted log stream."))
            }
            detailError
        }
    }

    private var repositories: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionToolbar(actionTitle: "Refresh") {
                if let id = selectedWorkspaceID { model.loadRepositories(for: id) }
            }
            if let id = selectedWorkspaceID, let value = model.repositoriesByWorkspace[id.rawValue] {
                FreshnessNotice(freshness: value.freshness, observedAt: newestRepositoryDate(value), reason: value.notice)
                if value.repositories.isEmpty {
                    ContentUnavailableView(value.needsStart ? "Workspace is stopped" : "No repositories reported", systemImage: "shippingbox", description: Text(value.needsStart ? "Start the selected workspace, then retry repository inspection." : "The runtime returned no repository records."))
                } else {
                    List(value.repositories) { repository in
                        RepositoryRow(repository: repository) {
                            model.reviewPush(for: repository, workspace: id)
                        }
                    }
                    .listStyle(.inset)
                }
                loadingOverlay("Updating repository state")
            } else if model.isDetailLoading {
                OperationRow(phase: "Inspecting repositories", scope: navigation.workspace?.rawValue, detail: "Checking branches, worktrees, and destinations.")
            } else {
                ContentUnavailableView("No repository snapshot", systemImage: "shippingbox", description: Text("Refresh to inspect repository state."))
            }
            detailError
        }
    }

    private func newestRepositoryDate(_ value: MSWRepositoriesResponse) -> Date? {
        value.repositories.compactMap(\.checkedAt).max()
    }

    private var ports: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionToolbar(actionTitle: "Refresh") { model.loadPorts(for: navigation.workspace) }
            if let warning = scopedPortWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("details.ports.warning")
            }
            if let value = model.portsSnapshot {
                FreshnessNotice(freshness: value.freshness, observedAt: nil, reason: nil)
                LabeledContent("Reported scope", value: value.workspace)
                LabeledContent("Active listeners", value: value.activeListening)
                if value.published.isEmpty {
                    ContentUnavailableView("No published ports", systemImage: "network.slash", description: Text("The runtime reported no configured ports."))
                } else {
                    List(value.published) { port in
                        HStack {
                            Text(port.port).monospacedDigit()
                            Spacer()
                            Text(port.configured ? "Configured" : "Not configured").foregroundStyle(.secondary)
                            if let id = navigation.workspace,
                               value.workspace == id.rawValue,
                               let workspace = model.workspaces.first(where: { $0.id == id }),
                               workspace.state == .running,
                               workspace.freshness == .fresh,
                               workspace.networkHost != nil,
                               workspace.credential != .quarantined {
                                Button("Open") { model.openSite(for: id, port: port.port) }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("Open port \(port.port)")
                            }
                        }
                    }
                    .listStyle(.inset)
                }
                loadingOverlay("Updating ports")
            } else if model.isDetailLoading {
                OperationRow(phase: "Inspecting ports", scope: navigation.workspace?.rawValue, detail: "Requesting configured ports and active listeners.")
            } else {
                ContentUnavailableView("No port snapshot", systemImage: "network", description: Text("Refresh to inspect configured ports and active listeners."))
            }
            detailError
        }
    }

    private var scopedPortWarning: String? {
        guard let workspace = navigation.workspace,
              let snapshot = model.workspaces.first(where: { $0.id == workspace }),
              let warning = snapshot.portWarning,
              !warning.isEmpty else {
            return nil
        }
        return warning
    }

    private var github: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionToolbar(actionTitle: "Refresh") { model.loadGitHubState() }
            if model.accessMode == .local {
                Text(GitHubLocalStrings.detailFootnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Token values remain in the Mac Keychain and are never rendered here. VM access is read-only; pushes are performed by the Mac host when configured.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let value = model.githubSnapshot {
                let items = navigation.workspace.map { id in
                    value.workspaces.filter { $0.workspace == id.rawValue }
                } ?? value.workspaces
                if items.isEmpty {
                    ContentUnavailableView("No access record", systemImage: "person.crop.circle.badge.questionmark", description: Text("No GitHub authorization metadata was reported for this scope."))
                } else {
                    List(items) { item in GitHubWorkspaceRow(item: item) }
                        .listStyle(.inset)
                }
                loadingOverlay("Updating authorization metadata")
            } else if model.isDetailLoading {
                OperationRow(phase: "Loading GitHub access", scope: navigation.workspace?.rawValue, detail: "Requesting nonsecret authorization metadata.")
            } else {
                ContentUnavailableView("No GitHub snapshot", systemImage: "person.crop.circle.badge.questionmark", description: Text("Refresh to inspect nonsecret authorization metadata."))
            }
            detailError
        }
        .onReceive(NotificationCenter.default.publisher(for: .githubPolicyDidChange)) { _ in
            model.loadGitHubState()
        }
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sanitized operation, observation, and failure history. Times use your Mac’s current time zone.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if scopedActivities.isEmpty {
                ContentUnavailableView("No activity for this scope", systemImage: "clock", description: Text("Refresh or run an operation to create a sanitized activity entry."))
            } else {
                List(scopedActivities) { entry in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: entry.isFailure ? "xmark.circle.fill" : "checkmark.circle")
                            .foregroundStyle(entry.isFailure ? .red : .secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(entry.title).font(.body.weight(.medium))
                                Spacer()
                                Text(entry.createdAt.formatted(date: .abbreviated, time: .standard))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Text(entry.workspace.map { "Workspace: \($0)" } ?? "All workspaces")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                            if let detail = entry.detail {
                                Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                .listStyle(.inset)
            }
        }
        .accessibilityIdentifier("details.activity")
    }

    private var scopedActivities: [MSWActivity] {
        guard let workspace = navigation.workspace else { return model.activities }
        return model.activities.filter { $0.workspace == workspace.rawValue }
    }

    private var backup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Archive scope") {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Includes managed workspace code and data, VM state, databases, Docker images and volumes, guest-side credentials, and bounded diagnostics.", systemImage: "archivebox")
                        Label("Excludes Mac Keychain records and host credentials.", systemImage: "key.slash")
                        Text("Treat the archive as sensitive. Store it only in a trusted destination with appropriate disk encryption and access controls.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack {
                    Button("Review New Backup…") { chooseBackupDirectory() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isMaintenanceOperationInFlight)
                    Button("Choose Restore Archive…") { chooseRestoreArchive() }
                        .disabled(model.isMaintenanceOperationInFlight)
                    Spacer()
                }

                if let backupDestination {
                    LabeledContent("Backup destination", value: backupDestination.path(percentEncoded: false))
                        .font(.caption)
                        .textSelection(.enabled)
                }

                if let restoreArchive {
                    GroupBox("Restore preview") {
                        VStack(alignment: .leading, spacing: 8) {
                            LabeledContent("Archive", value: restoreArchive.lastPathComponent)
                            LabeledContent("Size", value: archiveSize(restoreArchive))
                            Text("Impact: replaces managed state for dev, playgrounds, and personal. All workspaces are stopped; the current restore contract does not promise automatic restart.")
                                .font(.caption)
                            Text("Checksum verification and rollback status are not available before the runtime reviews the archive. If apply fails, treat the outcome as unknown until diagnostics and a fresh observation confirm state.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Button("Review Destructive Restore…", role: .destructive) { confirmRestore = true }
                                .disabled(model.isMaintenanceOperationInFlight)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if let operation = latestModelMaintenanceOperation {
                    ModelOperationView(operation: operation) {
                        retryMaintenance(kind: operation.kind)
                    }
                } else if let operation = maintenanceOperation {
                    MaintenanceOperationView(operation: operation) {
                        if operation.kind == .backup, let destination = backupDestination {
                            beginBackup(to: destination)
                        } else if operation.kind == .restore, restoreArchive != nil {
                            confirmRestore = true
                        }
                    }
                }

                if let result = model.backupResult {
                    GroupBox("Latest backup result") {
                        VStack(alignment: .leading, spacing: 7) {
                            Label("Archive created", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            LabeledContent("Archive", value: result.archive.lastPathComponent)
                            LabeledContent("Completed", value: maintenanceOperation?.finishedAt?.formatted(date: .abbreviated, time: .standard) ?? "Time not retained")
                            LabeledContent("Stopped for backup", value: result.stoppedWorkspaces.isEmpty ? "None reported" : result.stoppedWorkspaces.joined(separator: ", "))
                            LabeledContent("Restarted afterward", value: result.restartedWorkspaces.isEmpty ? "None reported" : result.restartedWorkspaces.joined(separator: ", "))
                            if let checksum = result.checksum {
                                LabeledContent("Checksum sidecar", value: checksum.lastPathComponent)
                                Text("The runtime reported a checksum file. This UI does not claim verification of its contents.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Label("No checksum was reported by the runtime.", systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            let notRestarted = Set(result.stoppedWorkspaces).subtracting(result.restartedWorkspaces)
                            if !notRestarted.isEmpty {
                                Text("Needs attention: \(notRestarted.sorted().joined(separator: ", ")) stopped for backup but was not reported restarted. Refresh state before acting.")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                detailError
            }
        }
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionToolbar(actionTitle: "Run Checks") { model.runDiagnostics() }
            Text("Checks report protocol availability and credential-broker reachability without rendering secret material. Diagnostics run globally; the workspace picker is retained as navigation context.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.diagnosticChecks.isEmpty && !model.isDetailLoading {
                ContentUnavailableView("No diagnostic run", systemImage: "wrench.and.screwdriver", description: Text("Run checks to inspect the local MSW installation."))
            } else {
                List(model.diagnosticChecks) { check in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Label(check.title, systemImage: diagnosticSymbol(check.status))
                                .font(.body.weight(.medium))
                            Spacer()
                            Text(check.status.rawValue.capitalized)
                                .foregroundStyle(diagnosticColor(check.status))
                        }
                        Text(check.detail).font(.caption).foregroundStyle(.secondary)
                        if let recovery = check.recovery {
                            Text("Recovery: \(recovery)").font(.caption).foregroundStyle(.orange)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                .listStyle(.inset)
            }
            if model.isDetailLoading {
                OperationRow(phase: "Running checks", scope: navigation.workspace?.rawValue, detail: "Checking protocol, runtime, and credential-broker availability.")
            }
            detailError
        }
    }

    @ViewBuilder
    private func sectionToolbar(actionTitle: String, action: @escaping () -> Void) -> some View {
        HStack {
            if let observedAt = selectedWorkspace?.observedAt {
                Text("Last workspace observation: \(observedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(actionTitle, action: action)
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(model.isDetailLoading)
        }
    }

    @ViewBuilder
    private func loadingOverlay(_ phase: String) -> some View {
        if model.isDetailLoading {
            OperationRow(phase: phase, scope: navigation.workspace?.rawValue, detail: "Cached content remains visible while the request is in progress.")
        }
    }

    @ViewBuilder
    private var detailError: some View {
        if let error = model.detailError {
            VStack(alignment: .leading, spacing: 8) {
                Label("Request failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(error).font(.caption).textSelection(.enabled)
                Text("Cached content above is last known, not a fresh verification.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button("Retry", action: loadSelectedSection)
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("details.error")
        }
    }

    private func chooseBackupDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose Backup Destination"
        panel.prompt = "Review Destination"
        panel.message = "Selecting a directory does not start the backup. You will review scope and workspace impact next."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            backupDestination = url
            reviewBackup = true
        }
    }

    private func chooseRestoreArchive() {
        let panel = NSOpenPanel()
        panel.title = "Choose MSW Backup Archive"
        panel.prompt = "Preview Restore"
        panel.message = "Selecting an archive does not restore it. You will review impact and type a confirmation next."
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "zst")].compactMap { $0 }
        if panel.runModal() == .OK {
            restoreArchive = panel.url
        }
    }

    private func beginBackup(to destination: URL) {
        maintenanceOperation = MaintenanceOperation(kind: .backup, phase: "Preparing archive", startedAt: Date(), finishedAt: nil, outcome: .running)
        model.createBackup(to: destination)
        if !model.isDetailLoading { finishMaintenanceOperation() }
    }

    private func beginRestore(archive: URL, confirmation: String) {
        maintenanceOperation = MaintenanceOperation(kind: .restore, phase: "Applying archive", startedAt: Date(), finishedAt: nil, outcome: .running)
        model.restoreBackup(archive: archive, confirmation: confirmation)
        if !model.isDetailLoading { finishMaintenanceOperation() }
    }

    private func finishMaintenanceOperation() {
        guard var operation = maintenanceOperation else { return }
        operation.finishedAt = Date()
        if let error = model.detailError {
            operation.phase = operation.kind == .restore ? "Outcome unknown" : "Backup failed"
            operation.outcome = .failed(error)
        } else {
            operation.phase = operation.kind == .restore ? "Refreshing and verifying" : "Archive and result reported"
            operation.outcome = .succeeded(model.maintenanceMessage ?? "The operation completed.")
        }
        maintenanceOperation = operation
    }

    private var latestModelMaintenanceOperation: MSWOperationState? {
        model.operationStates.values
            .filter { $0.kind == .backup || $0.kind == .restore }
            .max { $0.updatedAt < $1.updatedAt }
    }

    private func retryMaintenance(kind: MSWOperationState.Kind) {
        if kind == .backup, backupDestination != nil {
            reviewBackup = true
        } else if kind == .restore, restoreArchive != nil {
            confirmRestore = true
        }
    }

    private func archiveSize(_ url: URL) -> String {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return "Unavailable" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    private func icon(for section: DetailSection) -> String {
        switch section {
        case .overview: return "rectangle.grid.1x2"
        case .metrics: return "gauge.with.dots.needle.67percent"
        case .logs: return "text.alignleft"
        case .repositories: return "shippingbox"
        case .ports: return "network"
        case .github: return "person.crop.circle.badge.checkmark"
        case .activity: return "clock"
        case .backup: return "externaldrive"
        case .diagnostics: return "wrench.and.screwdriver"
        }
    }

    private func diagnosticSymbol(_ status: MSWDiagnosticCheck.Status) -> String {
        switch status {
        case .pass: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .unavailable: return "questionmark.circle.fill"
        }
    }

    private func diagnosticColor(_ status: MSWDiagnosticCheck.Status) -> Color {
        switch status {
        case .pass: return .green
        case .failed: return .red
        case .unavailable: return .orange
        }
    }
}

private struct AggregateStatusView: View {
    @Bindable var model: AppModel

    var body: some View {
        let health = model.health
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: health.symbol)
                .font(.title2)
                .foregroundStyle(color(health.severity))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(health.title).font(.headline)
                Text(health.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Refresh") { model.refresh() }
                .disabled(model.isRefreshing)
        }
        .padding(14)
        .background(color(health.severity).opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    private func color(_ severity: MonitorHealth.Severity) -> Color {
        switch severity {
        case .normal: return .green
        case .neutral: return .secondary
        case .attention: return .orange
        case .critical: return .red
        }
    }
}

private struct DetailWorkspaceCard: View {
    let workspace: Workspace
    @Bindable var model: AppModel
    let openRepositories: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(workspace.id.rawValue).font(.headline)
                    Text(workspace.purpose).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(workspace.state.rawValue).font(.body.weight(.medium))
            }
            HStack {
                LabeledContent("Freshness", value: workspace.freshness.rawValue)
                LabeledContent("Credential", value: workspace.credential.rawValue)
            }
            if let reason = workspace.quarantineReason {
                Label(reason, systemImage: "exclamationmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                if workspace.canStart && workspace.state != .running {
                    Button("Start \(workspace.id.rawValue)") { model.start(workspace.id) }
                        .buttonStyle(.borderedProminent)
                }
                if workspace.canStop && (workspace.state == .running || workspace.state == .quarantined) {
                    Button("Stop \(workspace.id.rawValue)") { model.stop(workspace.id) }
                }
                Button("Repositories", action: openRepositories)
                Spacer()
                Text("Next: \(workspace.nextAction)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }
}

private struct FreshnessNotice: View {
    let freshness: MSWFreshness
    let observedAt: Date?
    let reason: String?

    var body: some View {
        if freshness != .fresh || reason != nil {
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(freshness == .fresh ? Color.secondary : Color.orange)
                if let observedAt {
                    Text("Last known: \(observedAt.formatted(date: .abbreviated, time: .standard))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let reason { Text(reason).font(.caption2).foregroundStyle(.secondary) }
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .combine)
        }
    }

    private var title: String {
        switch freshness {
        case .fresh: return "Fresh snapshot"
        case .stale: return "Showing last known snapshot"
        case .unavailable: return "Current snapshot unavailable"
        case .neverObserved: return "Not yet observed"
        }
    }

    private var symbol: String {
        freshness == .fresh ? "checkmark.circle" : "clock.badge.exclamationmark"
    }
}

private struct OperationRow: View {
    let phase: String
    let scope: String?
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Phase: \(phase)").font(.caption.weight(.semibold))
                    Spacer()
                    Text(scope.map { "Workspace: \($0)" } ?? "Global")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Text(detail).font(.caption2).foregroundStyle(.secondary)
                Text("Progress: indeterminate; no fraction is exposed by the current model contract.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

private struct RepositoryRow: View {
    let repository: MSWRepositorySnapshot
    let push: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(repository.path).font(.body.weight(.medium)).textSelection(.enabled)
                Text("\(repository.branch ?? "detached") • \(repository.pushability.rawValue) • \(repository.aheadCount) ahead, \(repository.behindCount) behind")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Worktree: \(repository.worktreeState.rawValue) • checked \(repository.checkedAt?.formatted(date: .abbreviated, time: .shortened) ?? "at an unknown time")")
                    .font(.caption2).foregroundStyle(.secondary)
                if repository.worktreeState == .localChanges {
                    Text("Uncommitted changes are not included in a push.")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            Spacer()
            if repository.pushability == .pushable || repository.pushability == .publish {
                Button(repository.pushability == .publish ? "Publish Branch" : "Push \(repository.aheadCount)", action: push)
                    .disabled(repository.pushability != .publish && repository.aheadCount < 1)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct GitHubWorkspaceRow: View {
    let item: MSWGitHubWorkspaceState

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(item.workspace).font(.body.weight(.medium))
                Spacer()
                if item.quarantined {
                    Label("Quarantined", systemImage: "exclamationmark.octagon.fill").foregroundStyle(.red)
                } else if item.needsRestart {
                    Label("Restart required", systemImage: "arrow.clockwise.circle").foregroundStyle(.orange)
                }
            }
            if item.provider == "local-policy" {
                if !item.configured {
                    Text("No repository access recorded for this workspace.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let repos = item.repos, repos.isEmpty {
                    Text("No repositories assigned; repository access is blocked.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Repository access ready.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if item.quarantined || !item.configured {
                Text("Repository access needs reconnecting.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if item.needsRestart {
                Text("Repository access is updating.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Repository access ready.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let repos = item.repos, !repos.isEmpty {
                Text(repos.map { "\($0.canonical) — \($0.modeLabel)" }.joined(separator: "\n"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct PushConfirmationView: View {
    let plan: MSWPushPlan
    @Binding var confirmation: String
    let cancel: () -> Void
    let apply: () -> Void
    @FocusState private var cancelFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Push committed changes from \(plan.workspace)?").font(.title2.weight(.semibold))
            Text(plan.effects)
            LabeledContent("Workspace", value: plan.workspace)
            LabeledContent("Repository", value: plan.repositoryPath)
            LabeledContent("Branch", value: plan.branch)
            LabeledContent("Commits", value: "\(plan.aheadCount) ahead, \(plan.behindCount) behind")
            LabeledContent("Plan expires", value: plan.expiresAt.formatted(date: .abbreviated, time: .standard))
            TextField("Type \(plan.confirmationPhrase) exactly", text: $confirmation)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Type \(plan.confirmationPhrase) exactly to confirm push")
                .accessibilityHint(confirmation == plan.confirmationPhrase ? "Confirmation is valid" : "Push remains disabled until the exact phrase is entered")
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .focused($cancelFocused)
                Button("Push", role: .destructive, action: apply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(confirmation != plan.confirmationPhrase)
            }
        }
        .padding(24)
        .frame(minWidth: 460, idealWidth: 520, maxWidth: 620)
        .onAppear { cancelFocused = true }
    }
}

private struct BackupReviewView: View {
    let destination: URL
    let workspaces: [Workspace]
    let isBusy: Bool
    let cancel: () -> Void
    let apply: () -> Void
    @FocusState private var cancelFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review backup").font(.title2.weight(.semibold))
            LabeledContent("Destination", value: destination.path(percentEncoded: false))
            Text("Includes managed code and data, VM state, databases, Docker images and volumes, guest-side credentials, and bounded diagnostics. Mac Keychain records are excluded.")
            let running = workspaces.filter { $0.state == .running }.map { $0.id.rawValue }
            LabeledContent("Running workspaces", value: running.isEmpty ? "None" : running.joined(separator: ", "))
            Text(running.isEmpty ? "No running workspace stop is expected." : "Running workspaces may be stopped to create a consistent archive, then restarted when the runtime can do so safely. The result will list both sets.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Required free space is not exposed by the current contract. Confirm adequate capacity before continuing.")
                .font(.caption)
                .foregroundStyle(.orange)
            if isBusy {
                Text("Another backup or restore is already in progress. Wait for it to finish before starting this operation.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction).focused($cancelFocused)
                Button("Create Backup", action: apply)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isBusy)
            }
        }
        .padding(24)
        .frame(minWidth: 500, idealWidth: 560, maxWidth: 660)
        .onAppear { cancelFocused = true }
    }
}

private struct RestoreConfirmationView: View {
    let archive: URL
    let workspaces: [Workspace]
    let isBusy: Bool
    @Binding var confirmation: String
    let cancel: () -> Void
    let apply: () -> Void
    @FocusState private var cancelFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Destructive restore", systemImage: "exclamationmark.triangle.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.red)
            Text("Restoring \(archive.lastPathComponent) replaces managed state for dev, playgrounds, and personal, including code, data, VM state, databases, Docker artifacts, and guest-side credentials.")
            LabeledContent("Currently running", value: workspaces.filter { $0.state == .running }.map { $0.id.rawValue }.joined(separator: ", ").nilIfEmpty ?? "None")
            LabeledContent("After restore", value: "All workspaces stopped")
            Text("The runtime validates the archive during restore. This UI cannot preview checksum validity or guarantee rollback. If an error occurs after mutation starts, the outcome may be unknown; run diagnostics and refresh before retrying.")
                .font(.caption)
                .foregroundStyle(.orange)
            TextField("Type RESTORE exactly", text: $confirmation)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Type RESTORE exactly to confirm destructive restore")
                .accessibilityHint(confirmation == "RESTORE" ? "Confirmation is valid" : "Restore remains disabled until RESTORE is entered in uppercase")
            if isBusy {
                Text("Another backup or restore is already in progress. Wait for it to finish before starting this operation.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction).focused($cancelFocused)
                Button("Restore All Workspaces", role: .destructive, action: apply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isBusy || confirmation != "RESTORE")
            }
        }
        .padding(24)
        .frame(minWidth: 500, idealWidth: 580, maxWidth: 680)
        .onAppear { cancelFocused = true }
    }
}

private struct MaintenanceOperation: Equatable {
    enum Kind { case backup, restore }
    enum Outcome: Equatable {
        case running
        case succeeded(String)
        case failed(String)
    }

    let kind: Kind
    var phase: String
    let startedAt: Date
    var finishedAt: Date?
    var outcome: Outcome
}

private struct MaintenanceOperationView: View {
    let operation: MaintenanceOperation
    let retry: () -> Void

    var body: some View {
        GroupBox(operation.kind == .backup ? "Backup operation" : "Restore operation") {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    if operation.outcome == .running { ProgressView().controlSize(.small) }
                    Text("Phase: \(operation.phase)").font(.body.weight(.medium))
                    Spacer()
                    Text(operation.startedAt.formatted(date: .abbreviated, time: .standard))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                switch operation.outcome {
                case .running:
                    Text("Progress is indeterminate because the current model does not expose event fractions. Do not close the app or replay the operation.")
                        .font(.caption).foregroundStyle(.secondary)
                case .succeeded(let message):
                    Label(message, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                    if operation.kind == .restore {
                        Text("Verification: a refresh was requested. Treat the restore as fully verified only when fresh workspace state is visible.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                case .failed(let message):
                    Label(message, systemImage: "xmark.circle.fill").font(.caption).foregroundStyle(.red)
                    Text(operation.kind == .restore ? "Rollback status was not reported. Outcome is unknown; run diagnostics and refresh before retrying." : "No archive result was reported. Review the destination and available space before retrying.")
                        .font(.caption).foregroundStyle(.orange)
                    Button(operation.kind == .restore ? "Review Retry" : "Retry Backup", action: retry)
                }
                if let finishedAt = operation.finishedAt {
                    LabeledContent("Finished", value: finishedAt.formatted(date: .abbreviated, time: .standard))
                        .font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct ModelOperationView: View {
    let operation: MSWOperationState
    let retry: () -> Void

    var body: some View {
        GroupBox(operation.kind == .backup ? "Backup operation" : "Restore operation") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if operation.outcome == .pending {
                        if let fraction = operation.fraction {
                            ProgressView(value: fraction).frame(maxWidth: 120)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    Label(phaseTitle, systemImage: outcomeSymbol)
                        .font(.body.weight(.medium))
                        .foregroundStyle(outcomeColor)
                    Spacer()
                    Text("Started \(operation.startedAt.formatted(date: .abbreviated, time: .standard))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(operation.message).font(.caption).textSelection(.enabled)
                LabeledContent("Updated", value: operation.updatedAt.formatted(date: .abbreviated, time: .standard))
                    .font(.caption)
                if operation.phase == .verifying {
                    Text("The mutation returned; MSW Monitor is waiting for a fresh matching observation before declaring success.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if operation.outcome == .unknown {
                    Text("The runtime did not provide a verified outcome. Do not replay automatically; refresh and run diagnostics first.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let recovery = operation.recovery {
                    Text("Recovery: \(recovery.recovery ?? recovery.reason)")
                        .font(.caption).foregroundStyle(.orange)
                }
                if operation.outcome == .failed || operation.outcome == .unknown {
                    Button("Review Retry", action: retry)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }

    private var phaseTitle: String {
        switch operation.phase {
        case .preparing: return "Preparing"
        case .awaitingConfirmation: return "Awaiting confirmation"
        case .running: return operation.fraction.map { "Running — \(Int($0 * 100))%" } ?? "Running — progress indeterminate"
        case .verifying: return "Verifying outcome"
        case .finished:
            switch operation.outcome {
            case .succeeded: return "Succeeded and verified"
            case .failed: return "Failed"
            case .unknown: return "Outcome unknown"
            case .pending: return "Finishing"
            }
        }
    }

    private var outcomeSymbol: String {
        switch operation.outcome {
        case .pending: return "arrow.triangle.2.circlepath"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    private var outcomeColor: Color {
        switch operation.outcome {
        case .pending: return .accentColor
        case .succeeded: return .green
        case .failed: return .red
        case .unknown: return .orange
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
