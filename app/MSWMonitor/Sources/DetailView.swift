import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class DetailWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let onClose: @MainActor () -> Void

    init(model: AppModel, onClose: @escaping @MainActor () -> Void) {
        let view = DetailView(model: model)
        let hosting = NSHostingController(rootView: view)
        window = NSWindow(contentViewController: hosting)
        self.onClose = onClose
        super.init()
        window.title = "MSW Monitor Details"
        window.setContentSize(NSSize(width: 760, height: 520))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

struct DetailView: View {
    @Bindable var model: AppModel
    @State private var selection: Section = .overview
    @State private var restoreArchive: URL?
    @State private var confirmRestore = false
    @State private var restoreConfirmation = ""
    @State private var pushConfirmation = ""
    enum Section: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case metrics = "Metrics"
        case logs = "Logs"
        case repositories = "Repositories"
        case ports = "Ports and tunnels"
        case github = "GitHub Access"
        case activity = "Activity"
        case backup = "Backup"
        case diagnostics = "Diagnostics and Maintenance"

        var id: String { rawValue }
    }

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: icon(for: section))
                    .tag(section)
            }
            .navigationTitle("MSW Monitor")
            .frame(minWidth: 190)
        } detail: {
            Group {
                switch selection {
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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(22)
            .task(id: selection) { loadSelectedSection() }
        }
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
    }

    private var selectedWorkspaceID: Workspace.ID {
        model.selectedWorkspace ?? .dev
    }

    private func loadSelectedSection() {
        switch selection {
        case .metrics: model.loadMetrics(for: selectedWorkspaceID)
        case .logs: model.loadLogs(for: selectedWorkspaceID)
        case .repositories: model.loadRepositories(for: selectedWorkspaceID)
        case .ports: model.loadPorts()
        case .github: model.loadGitHubState()
        case .diagnostics: model.runDiagnostics()
        default: break
        }
    }

    private var metrics: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Metrics").font(.title2.weight(.semibold))
                Spacer()
                Button("Refresh") { model.loadMetrics(for: selectedWorkspaceID) }
            }
            Text("Workspace: \(selectedWorkspaceID.rawValue)").foregroundStyle(.secondary)
            if let value = model.metricsByWorkspace[selectedWorkspaceID.rawValue] {
                LabeledContent("Lifecycle", value: value.lifecycle.rawValue)
                LabeledContent("Freshness", value: value.freshness.rawValue)
                LabeledContent("Available", value: value.available ? "Yes" : "No")
                if let reason = value.reason { Text(reason).foregroundStyle(.secondary) }
                if let snapshot = value.snapshot { Text(String(describing: snapshot)).font(.caption.monospaced()) }
            } else if model.isDetailLoading {
                ProgressView("Loading metrics…")
            } else {
                ContentUnavailableView("No metrics snapshot", systemImage: "gauge", description: Text("Metrics are available only while the selected workspace is running."))
            }
            detailError
        }
    }

    private var logs: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Logs").font(.title2.weight(.semibold))
                Spacer()
                Button("Refresh") { model.loadLogs(for: selectedWorkspaceID) }
            }
            Text("Workspace: \(selectedWorkspaceID.rawValue). Logs are bounded and redacted before they reach the app.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let value = model.logsByWorkspace[selectedWorkspaceID.rawValue] {
                LabeledContent("Lifecycle", value: value.lifecycle.rawValue)
                LabeledContent("Freshness", value: value.freshness.rawValue)
                if let reason = value.reason {
                    Text(reason).foregroundStyle(.secondary)
                }
                if value.lines.isEmpty {
                    ContentUnavailableView("No log lines", systemImage: "text.alignleft", description: Text(value.available ? "The runtime returned no bounded log lines." : "Logs are unavailable while the workspace is stopped."))
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(value.lines.enumerated()), id: \.offset) { _, line in
                                Text(line.message)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxHeight: 360)
                }
            } else if model.isDetailLoading {
                ProgressView("Loading logs…")
            } else {
                ContentUnavailableView("No log snapshot", systemImage: "text.alignleft", description: Text("Refresh to inspect the bounded, redacted log stream."))
            }
            detailError
        }
    }

    private var repositories: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Repositories").font(.title2.weight(.semibold))
                Spacer()
                Button("Refresh") { model.loadRepositories(for: selectedWorkspaceID) }
            }
            Text("Workspace: \(selectedWorkspaceID.rawValue)").foregroundStyle(.secondary)
            if let value = model.repositoriesByWorkspace[selectedWorkspaceID.rawValue] {
                if let notice = value.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                if value.repositories.isEmpty {
                    ContentUnavailableView(value.needsStart ? "Workspace is stopped" : "No repositories reported", systemImage: "shippingbox", description: Text(value.needsStart ? "Start the workspace before inspecting repositories." : "The runtime returned no repository records."))
                } else {
                    List(value.repositories) { repository in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(repository.path).font(.body.weight(.medium))
                                Text("\(repository.branch ?? "detached") • \(repository.pushability.rawValue) • \(repository.aheadCount) ahead, \(repository.behindCount) behind")
                                    .font(.caption).foregroundStyle(.secondary)
                                if repository.worktreeState == .localChanges {
                                    Text("Uncommitted changes will not be included.")
                                        .font(.caption2).foregroundStyle(.orange)
                                }
                            }
                            Spacer()
                            if repository.pushability == .pushable || repository.pushability == .publish {
                                Button(repository.pushability == .publish ? "Publish Branch" : "Push \(repository.aheadCount)") {
                                    model.reviewPush(for: repository, workspace: selectedWorkspaceID)
                                }
                                .disabled(repository.pushability != .publish && repository.aheadCount < 1)
                            }
                        }
                    }
                    .listStyle(.inset)
                }
            } else if model.isDetailLoading {
                ProgressView("Inspecting repositories…")
            } else {
                ContentUnavailableView("No repository snapshot", systemImage: "shippingbox", description: Text("Refresh to inspect repository state."))
            }
            detailError
        }
    }

    private var ports: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Ports and tunnels").font(.title2.weight(.semibold))
                Spacer()
                Button("Refresh") { model.loadPorts() }
            }
            if let value = model.portsSnapshot {
                LabeledContent("Scope", value: value.workspace)
                LabeledContent("Listening", value: value.activeListening)
                List(value.published) { port in
                    HStack {
                        Text(port.port)
                        Spacer()
                        Text(port.configured ? "Configured" : "Not configured").foregroundStyle(.secondary)
                    }
                }
                .listStyle(.inset)
            } else if model.isDetailLoading {
                ProgressView("Inspecting ports…")
            } else {
                ContentUnavailableView("No port snapshot", systemImage: "network", description: Text("Refresh to inspect configured ports and active listeners."))
            }
            detailError
        }
    }

    private var github: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("GitHub Access").font(.title2.weight(.semibold))
                Spacer()
                Button("Refresh") { model.loadGitHubState() }
            }
            Text("Token values are held by the Mac Keychain and are never rendered here.").foregroundStyle(.secondary)
            if let value = model.githubSnapshot {
                List(value.workspaces) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.workspace).font(.body.weight(.medium))
                        Text("\(item.provider) • \(item.accessMode) • \(item.configured ? "configured" : "unconfigured")")
                            .font(.caption).foregroundStyle(.secondary)
                        if item.provider == "legacy-pat" {
                            Text("Legacy PAT detected. Complete GitHub App authorization to migrate this workspace.")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                        if let repository = item.verificationRepository {
                            Text("Verification: \(repository)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.inset)
            } else if model.isDetailLoading {
                ProgressView("Loading GitHub state…")
            } else {
                ContentUnavailableView("No GitHub snapshot", systemImage: "person.crop.circle.badge.questionmark", description: Text("Refresh to inspect nonsecret authorization metadata."))
            }
            detailError
        }
    }

    @ViewBuilder
    private var detailError: some View {
        if let error = model.detailError {
            Text(error).font(.caption).foregroundStyle(.orange).lineLimit(3)
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Overview").font(.title2.weight(.semibold))
                    Text(model.aggregateDetail).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh") { model.refresh() }
            }
            ForEach(model.workspaces) { workspace in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(workspace.id.rawValue).font(.headline)
                        Text(workspace.purpose).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(workspace.state.rawValue)
                    Text(workspace.credential.rawValue).font(.caption).foregroundStyle(.secondary)
                }
                .padding(12)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 9))
            }
        }
        .accessibilityIdentifier("details.overview")
    }

    private var backup: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Backup").font(.title2.weight(.semibold))
            Text("Backups contain workspace data and diagnostics only. Mac Keychain records are never archived.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Create Backup") { chooseBackupDirectory() }
                    .buttonStyle(.borderedProminent)
                Button("Choose Restore Archive") { chooseRestoreArchive() }
            }
            if let restoreArchive {
                LabeledContent("Selected archive", value: restoreArchive.lastPathComponent)
                Button("Restore archive") { confirmRestore = true }
                    .buttonStyle(.bordered)
                    .tint(.red)
            }
            if let result = model.backupResult {
                Text("Latest archive: \(result.archive.lastPathComponent)")
                    .font(.caption)
                if let checksum = result.checksum {
                    Text("Checksum: \(checksum.lastPathComponent)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let message = model.maintenanceMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            if model.isDetailLoading {
                ProgressView("Working…")
            }
            detailError
        }
        .sheet(isPresented: $confirmRestore, onDismiss: {
            restoreConfirmation = ""
        }) {
            if let restoreArchive {
                RestoreConfirmationView(
                    archive: restoreArchive,
                    confirmation: $restoreConfirmation,
                    cancel: { confirmRestore = false },
                    apply: {
                        let phrase = restoreConfirmation
                        confirmRestore = false
                        model.restoreBackup(archive: restoreArchive, confirmation: phrase)
                    }
                )
            }
        }
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Diagnostics and Maintenance").font(.title2.weight(.semibold))
                Spacer()
                Button("Run Checks") { model.runDiagnostics() }
            }
            Text("Checks report protocol availability and credential-broker reachability without rendering secret material.")
                .foregroundStyle(.secondary)
            if model.diagnosticChecks.isEmpty {
                ContentUnavailableView("No diagnostic run", systemImage: "wrench.and.screwdriver", description: Text("Run checks to inspect the local MSW installation."))
            } else {
                List(model.diagnosticChecks) { check in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(check.title).font(.body.weight(.medium))
                            Spacer()
                            Text(check.status.rawValue.capitalized)
                                .foregroundStyle(check.status == .pass ? .green : check.status == .failed ? .red : .orange)
                        }
                        Text(check.detail).font(.caption).foregroundStyle(.secondary)
                        if let recovery = check.recovery {
                            Text(recovery).font(.caption2).foregroundStyle(.orange)
                        }
                    }
                }
                .listStyle(.inset)
            }
            if model.isDetailLoading {
                ProgressView("Running checks…")
            }
            detailError
        }
    }

    private func chooseBackupDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            model.createBackup(to: url)
        }
    }

    private func chooseRestoreArchive() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "zst")].compactMap { $0 }
        if panel.runModal() == .OK {
            restoreArchive = panel.url
        }
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Activity").font(.title2.weight(.semibold))
            if model.activities.isEmpty {
                ContentUnavailableView("No activity yet", systemImage: "clock", description: Text("Refresh or run an operation to create a sanitized activity entry."))
            } else {
                List(model.activities) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.title).font(.body.weight(.medium))
                        if let detail = entry.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .listStyle(.inset)
            }
        }
        .accessibilityIdentifier("details.activity")
    }


    private func icon(for section: Section) -> String {
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
}

private struct PushConfirmationView: View {
    let plan: MSWPushPlan
    @Binding var confirmation: String
    let cancel: () -> Void
    let apply: () -> Void
    @FocusState private var cancelFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Push committed changes?").font(.title2.weight(.semibold))
            Text(plan.effects)
            LabeledContent("Repository", value: plan.repositoryPath)
            LabeledContent("Branch", value: plan.branch)
            LabeledContent("Commits", value: "\(plan.aheadCount) ahead, \(plan.behindCount) behind")
            TextField("Type \(plan.confirmationPhrase)", text: $confirmation)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Push confirmation phrase")
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
        .frame(width: 480)
        .onAppear { cancelFocused = true }
    }
}

private struct RestoreConfirmationView: View {
    let archive: URL
    @Binding var confirmation: String
    let cancel: () -> Void
    let apply: () -> Void
    @FocusState private var cancelFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Restore workspace backup?").font(.title2.weight(.semibold))
            Text("Restoring \(archive.lastPathComponent) replaces managed workspace state and leaves all workspaces stopped.")
            TextField("Type RESTORE", text: $confirmation)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Restore confirmation phrase")
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .focused($cancelFocused)
                Button("Restore", role: .destructive, action: apply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(confirmation != "RESTORE")
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear { cancelFocused = true }
    }
}
