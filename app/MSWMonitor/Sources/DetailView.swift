import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum WorkspaceSection: String, CaseIterable, Identifiable {
    case summary = "Summary"
    case files = "Files"
    case logs = "Logs"
    case ports = "Network"
    case repositories = "Repositories"
    case diagnostics = "Maintenance"

    var id: String { rawValue }

    var requiresWorkspace: Bool {
        switch self {
        case .summary, .logs, .repositories, .files:
            return true
        case .ports, .diagnostics:
            return false
        }
    }

    init(deepLinkValue: String) {
        switch deepLinkValue.lowercased() {
        case "metrics", "summary", "overview": self = .summary
        case "logs": self = .logs
        case "repositories": self = .repositories
        case "files", "folders": self = .files
        case "ports", "network": self = .ports
        case "diagnostics", "maintenance": self = .diagnostics
        default: self = .summary
        }
    }
}

enum DetailMode {
    case overview
    case workspaces
    case backup
}

struct DetailView: View {
    @Bindable var model: AppModel
    @Bindable private var navigation: AppNavigationState
    let mode: DetailMode
    @State private var restoreArchive: URL?
    @State private var backupDestination: URL?
    @State private var reviewBackup = false
    @State private var confirmRestore = false
    @State private var restoreConfirmation = ""
    @State private var pushConfirmation = ""
    @State private var maintenanceOperation: MaintenanceOperation?

    init(
        model: AppModel,
        navigation: AppNavigationState,
        mode: DetailMode
    ) {
        self.model = model
        self.navigation = navigation
        self.mode = mode
    }

    var body: some View {
        Group {
            switch mode {
            case .overview: overview
            case .workspaces: workspacePane
            case .backup: backup
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

    private var workspacePane: some View {
        VStack(alignment: .leading, spacing: 0) {
            workspaceToolbar
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            Divider()
            Group {
                if navigation.workspaceSection.requiresWorkspace && navigation.workspace == nil {
                    ContentUnavailableView(
                        "Choose a workspace",
                        systemImage: "square.stack.3d.up.badge.a"
                    )
                } else {
                    sectionContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(20)
        }
        .task(id: routeIdentity) {
            if navigation.workspace == nil {
                navigation.workspace = model.selectedWorkspace ?? model.workspaces.first?.id
                model.selectedWorkspace = navigation.workspace
            }
            loadSelectedSection()
        }
    }

    private var routeIdentity: String {
        "\(navigation.workspaceSection.rawValue):\(navigation.workspace?.rawValue ?? "none")"
    }

    private var workspaceToolbar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(navigation.workspaceSection.rawValue)
                    .font(.headline)
                    .accessibilityIdentifier("details.section-title")
                Spacer()
                Picker("Workspace", selection: workspaceBinding) {
                    ForEach(model.workspaces.map(\.id), id: \.rawValue) { id in
                        Text(id.rawValue).tag(Optional(id))
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 180)
                .accessibilityIdentifier("details.workspace-picker")
            }
            Picker("Section", selection: $navigation.workspaceSection) {
                ForEach(WorkspaceSection.allCases) { section in
                    Text(section.rawValue)
                        .tag(section)
                        .accessibilityIdentifier("workspace.section.\(section.rawValue)")
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("workspace.section-picker")
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

    @ViewBuilder
    private var sectionContent: some View {
        switch navigation.workspaceSection {
        case .summary: workspaceSummary
        case .logs: logs
        case .repositories: repositories
        case .files:
            if let workspace = selectedWorkspaceID {
                FolderBrowserView(model: model, workspace: workspace)
                    .id(workspace)
            }
        case .ports: ports
        case .diagnostics: diagnostics
        }
    }

    private func loadSelectedSection() {
        model.clearDetailError()
        switch navigation.workspaceSection {
        case .summary:
            if let workspace = navigation.workspace { model.loadMetrics(for: workspace) }
        case .logs:
            if let workspace = navigation.workspace { model.loadLogs(for: workspace) }
        case .repositories:
            if let workspace = navigation.workspace { model.loadRepositories(for: workspace) }
        case .ports: model.loadPorts(for: navigation.workspace)
        case .diagnostics: model.runDiagnostics()
        case .files: break
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
                ForEach(model.workspaces) { workspace in
                    DetailWorkspaceCard(
                        workspace: workspace,
                        model: model,
                        openRepositories: {
                            navigation.tab = .workspaces
                            navigation.workspace = workspace.id
                            model.selectedWorkspace = workspace.id
                            navigation.workspaceSection = .repositories
                        }
                    )
                }
                Divider()
                Text("Recent activity")
                    .font(.headline)
                activity
            }
            .padding(20)
        }
        .accessibilityIdentifier("details.overview")
    }

    private var workspaceSummary: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let workspace = selectedWorkspace {
                    DetailWorkspaceCard(
                        workspace: workspace,
                        model: model,
                        openRepositories: {
                            navigation.workspaceSection = .repositories
                        }
                    )
                }
                metrics
            }
        }
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
            Text("Current operation errors appear first. Runtime logs below are bounded and redacted.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let failure = model.latestOperationFailure,
               failure.workspace == navigation.workspace {
                GroupBox(failure.title) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("What happened")
                            .font(.caption.weight(.semibold))
                        Text(failure.reason)
                            .font(.caption)
                            .accessibilityIdentifier("details.latest-operation-error.message")
                            .textSelection(.enabled)
                        Divider()
                        Text("What to do")
                            .font(.caption.weight(.semibold))
                        Text(failure.recovery)
                            .font(.caption)
                            .accessibilityIdentifier("details.latest-operation-error.recovery")
                            .textSelection(.enabled)
                        Button("Run Diagnostics") {
                            navigation.workspaceSection = .diagnostics
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("details.latest-operation-error")
            }
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

}

struct FolderBrowserView: View {
    @Bindable var model: AppModel
    let workspace: Workspace.ID
    var compact = false
    var title: String?
    var onClose: (() -> Void)?
    @State private var folderPath = "."
    @State private var folderSearch = ""
    @State private var selectedFolderPath: String?
    @State private var snapshot: MSWDirectoryResponse?
    @State private var directoryError: String?
    @State private var editorError: String?
    @State private var isDirectoryLoading = false
    @State private var isEditorOpening = false
    @State private var editorOpenRequestID: UUID?
    @State private var childrenByPath: [String: [MSWDirectoryResponse.Entry]] = [:]
    @State private var expandedPaths: Set<String> = []
    @State private var loadingChildPaths: Set<String> = []
    @State private var childErrors: [String: String] = [:]
    @State private var truncatedChildPaths: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            TextField("Search folders", text: $folderSearch)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("folders.search.field")

            browserContent

            if snapshot?.truncated == true {
                Text("Results reached the bounded response limit. Refine the search to see a narrower set.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("folders.truncated")
            }

            if let editorError {
                Label(editorError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("folders.error")
            }

            breadcrumbBar
        }
        .frame(maxWidth: .infinity, maxHeight: compact ? nil : .infinity, alignment: .topLeading)
        .task(id: requestIdentity) {
            editorOpenRequestID = nil
            editorError = nil
            isEditorOpening = false
            selectedFolderPath = nil
            directoryError = nil

            if folderSearch.isEmpty, let cachedEntries = childrenByPath[folderPath] {
                snapshot = cachedSnapshot(path: folderPath, entries: cachedEntries)
                isDirectoryLoading = false
                return
            }

            snapshot = nil
            isDirectoryLoading = true
            if !folderSearch.isEmpty {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
            do {
                let result = try await model.directories(
                    for: workspace,
                    path: folderPath,
                    query: folderSearch.isEmpty ? nil : folderSearch
                )
                guard !Task.isCancelled else { return }
                snapshot = result
                if folderSearch.isEmpty {
                    childrenByPath[folderPath] = result.entries
                    hydratePrefetchedTree(result.entries)
                    if result.truncated {
                        truncatedChildPaths.insert(folderPath)
                    } else {
                        truncatedChildPaths.remove(folderPath)
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                directoryError = error.localizedDescription
            }
            isDirectoryLoading = false
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let title {
                Text(title)
                    .font(.headline)
                    .accessibilityIdentifier("folders.popover.title")
            }
            Spacer()
            if let onClose {
                Button("Close", action: onClose)
                    .accessibilityIdentifier("folders.popover.close")
            }
            editorButton
        }
    }

    private var editorButton: some View {
        Button(model.editorOpenActionTitle) {
            let path = selectedFolderPath ?? folderPath
            Task { await openSelectedFolder(path) }
        }
        .disabled(isDirectoryLoading || snapshot == nil || isEditorOpening)
        .accessibilityIdentifier("folders.open.button")
        .accessibilityValue(selectedFolderAccessibilityPath)
    }

    @ViewBuilder
    private var browserContent: some View {
        if isDirectoryLoading {
            OperationRow(
                phase: folderSearch.isEmpty ? "Listing folders" : "Searching folders",
                scope: workspace.rawValue,
                detail: "Reading a bounded folder snapshot from the running VM."
            )
        } else if let snapshot {
            if snapshot.entries.isEmpty {
                folderUnavailableView(
                    title: folderSearch.isEmpty ? "No folders" : "No matching folders",
                    systemImage: "folder",
                    description: "",
                    accessibilityIdentifier: "folders.empty"
                )
            } else if folderSearch.isEmpty {
                folderTree(entries: snapshot.entries)
            } else {
                searchResults(entries: snapshot.entries)
            }
        } else if let directoryError {
            folderUnavailableView(
                title: "Couldn’t load folders",
                systemImage: "exclamationmark.triangle",
                description: directoryError,
                accessibilityIdentifier: "folders.load-error"
            )
        } else {
            folderUnavailableView(
                title: "Folder browser unavailable",
                systemImage: "folder.badge.questionmark",
                description: "Start the selected workspace, then retry.",
                accessibilityIdentifier: "folders.unavailable"
            )
        }
    }

    private func folderTree(entries: [MSWDirectoryResponse.Entry]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(entries) { entry in
                    FolderTreeBranch(
                        entry: entry,
                        childrenByPath: $childrenByPath,
                        expandedPaths: $expandedPaths,
                        loadingPaths: $loadingChildPaths,
                        errorsByPath: $childErrors,
                        truncatedPaths: $truncatedChildPaths,
                        selection: $selectedFolderPath,
                        onExpand: loadChildren,
                        onNavigate: navigateToFolder
                    )
                }
            }
            .padding(6)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
        .frame(
            minHeight: compact ? 170 : 240,
            idealHeight: compact ? 190 : 320,
            maxHeight: compact ? 210 : .infinity
        )
        .accessibilityIdentifier("folders.tree")
    }

    private func searchResults(entries: [MSWDirectoryResponse.Entry]) -> some View {
        List(entries) { entry in
            Button {
                selectedFolderPath = entry.path
            } label: {
                HStack {
                    Label(entry.name, systemImage: "folder")
                    Spacer()
                    Text(entry.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    selectedFolderPath = entry.path
                    navigateToFolder(entry.path)
                }
            )
            .accessibilityIdentifier("folders.entry.\(entry.path)")
        }
        .listStyle(.inset)
        .frame(
            minHeight: compact ? 170 : 240,
            idealHeight: compact ? 190 : 320,
            maxHeight: compact ? 210 : .infinity
        )
        .accessibilityIdentifier("folders.search-results")
    }

    private var breadcrumbBar: some View {
        VStack(spacing: 5) {
            Divider()
            ScrollView(.horizontal) {
                HStack(spacing: 5) {
                    Button {
                        navigateToFolder(".")
                    } label: {
                        Label("workspace", systemImage: "externaldrive")
                            .font(.caption.monospaced())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("folders.breadcrumb.root")

                    ForEach(Array(breadcrumbComponents.enumerated()), id: \.offset) { _, component in
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                        Button(component.name) {
                            navigateToFolder(component.path)
                        }
                        .buttonStyle(.plain)
                        .font(.caption.monospaced())
                        .accessibilityIdentifier("folders.breadcrumb.\(component.path)")
                    }
                }
                .padding(.horizontal, 2)
            }
            .scrollIndicators(.hidden)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("folders.path-bar")
        .accessibilityValue(currentFolderAccessibilityPath)
    }

    private var breadcrumbComponents: [(name: String, path: String)] {
        guard folderPath != "." else { return [] }
        var path = ""
        return folderPath
            .split(separator: "/")
            .map { component in
                path = path.isEmpty ? String(component) : "\(path)/\(component)"
                return (String(component), path)
            }
    }

    private var currentFolderAccessibilityPath: String {
        folderPath == "." ? "/workspace" : "/workspace/\(folderPath)"
    }

    private var selectedFolderAccessibilityPath: String {
        let path = selectedFolderPath ?? folderPath
        return path == "." ? "/workspace" : "/workspace/\(path)"
    }
    private func navigateToFolder(_ path: String) {
        folderSearch = ""
        selectedFolderPath = nil
        if let cachedEntries = childrenByPath[path] {
            snapshot = cachedSnapshot(path: path, entries: cachedEntries)
            directoryError = nil
            isDirectoryLoading = false
        } else {
            snapshot = nil
            isDirectoryLoading = true
        }
        folderPath = path
    }
 
    private func cachedSnapshot(
        path: String,
        entries: [MSWDirectoryResponse.Entry]
    ) -> MSWDirectoryResponse {
        MSWDirectoryResponse(
            workspace: workspace.rawValue,
            path: path,
            query: nil,
            entries: entries,
            truncated: truncatedChildPaths.contains(path)
        )
    }

    private func loadChildren(_ path: String) {
        guard childrenByPath[path] == nil, !loadingChildPaths.contains(path) else { return }
        loadingChildPaths.insert(path)
        childErrors[path] = nil
        Task {
            do {
                let result = try await model.directories(for: workspace, path: path)
                guard !Task.isCancelled else { return }
                childrenByPath[path] = result.entries
                hydratePrefetchedTree(result.entries)
                if result.truncated {
                    truncatedChildPaths.insert(path)
                } else {
                    truncatedChildPaths.remove(path)
                }
            } catch {
                guard !Task.isCancelled else { return }
                childErrors[path] = error.localizedDescription
            }
            loadingChildPaths.remove(path)
        }
    }

    private func hydratePrefetchedTree(_ entries: [MSWDirectoryResponse.Entry]) {
        for entry in entries {
            if !entry.hasChildren || !entry.children.isEmpty {
                childrenByPath[entry.path] = entry.children
            }
            if entry.childrenTruncated {
                truncatedChildPaths.insert(entry.path)
            } else {
                truncatedChildPaths.remove(entry.path)
            }
            hydratePrefetchedTree(entry.children)
        }
    }

    private func openSelectedFolder(_ path: String) async {
        let requestID = UUID()
        editorOpenRequestID = requestID
        editorError = nil
        isEditorOpening = true
        let error = await model.openEditor(for: workspace, path: path)
        guard editorOpenRequestID == requestID else { return }
        editorError = error
        isEditorOpening = false
    }


    private var requestIdentity: String {
        "\(workspace.rawValue):\(folderPath):\(folderSearch)"
    }

    @ViewBuilder
    private func folderUnavailableView(
        title: String,
        systemImage: String,
        description: String,
        accessibilityIdentifier: String
    ) -> some View {
        if compact {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.callout.weight(.medium))
                if !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(accessibilityIdentifier)
        } else {
            ContentUnavailableView(
                title,
                systemImage: systemImage,
                description: Text(description)
            )
            .accessibilityIdentifier(accessibilityIdentifier)
        }
    }
}

private struct FolderTreeBranch: View {
    let entry: MSWDirectoryResponse.Entry
    @Binding var childrenByPath: [String: [MSWDirectoryResponse.Entry]]
    @Binding var expandedPaths: Set<String>
    @Binding var loadingPaths: Set<String>
    @Binding var errorsByPath: [String: String]
    @Binding var truncatedPaths: Set<String>
    @Binding var selection: String?
    let onExpand: (String) -> Void
    let onNavigate: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                if !entry.hasChildren {
                    Color.clear
                        .frame(width: 16, height: 16)
                        .accessibilityHidden(true)
                } else {
                    Button {
                        expansionBinding.wrappedValue.toggle()
                    } label: {
                        Image(systemName: expandedPaths.contains(entry.path) ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("folders.entry.\(entry.path).expand")
                    .accessibilityLabel(expandedPaths.contains(entry.path) ? "Collapse \(entry.name)" : "Expand \(entry.name)")
                }
                folderLabel
            }

            if expandedPaths.contains(entry.path) {
                childContent
                    .padding(.leading, 18)
            }
        }
    }

    @ViewBuilder
    private var childContent: some View {
        if loadingPaths.contains(entry.path) {
            ProgressView("Loading folders…")
                .controlSize(.small)
        } else if let error = errorsByPath[entry.path] {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
        } else if let children = childrenByPath[entry.path] {
            ForEach(children) { child in
                FolderTreeBranch(
                    entry: child,
                    childrenByPath: $childrenByPath,
                    expandedPaths: $expandedPaths,
                    loadingPaths: $loadingPaths,
                    errorsByPath: $errorsByPath,
                    truncatedPaths: $truncatedPaths,
                    selection: $selection,
                    onExpand: onExpand,
                    onNavigate: onNavigate
                )
            }
            if truncatedPaths.contains(entry.path) {
                Text("More folders exist. Navigate into this folder to refine the view.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var folderLabel: some View {
        Button {
            selection = entry.path
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(entry.name)
                    .lineLimit(1)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                selection == entry.path ? Color.accentColor.opacity(0.18) : .clear,
                in: RoundedRectangle(cornerRadius: 5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                selection = entry.path
                onNavigate(entry.path)
            }
        )
        .accessibilityIdentifier("folders.entry.\(entry.path)")
        .accessibilityValue(selection == entry.path ? "Selected" : "")
    }

    private var expansionBinding: Binding<Bool> {
        Binding(
            get: { expandedPaths.contains(entry.path) },
            set: { expanded in
                if expanded {
                    expandedPaths.insert(entry.path)
                    onExpand(entry.path)
                } else {
                    expandedPaths.remove(entry.path)
                }
            }
        )
    }
}

private extension DetailView {

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


    private var activity: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.activities.isEmpty {
                Text("No recent activity")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(model.activities.prefix(10))) { entry in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: entry.isFailure ? "xmark.circle.fill" : "checkmark.circle")
                            .foregroundStyle(entry.isFailure ? .red : .secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(entry.title).font(.body.weight(.medium))
                                Spacer()
                                Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            if let workspace = entry.workspace {
                                Text(workspace)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let detail = entry.detail {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                    Divider()
                }
            }
        }
        .accessibilityIdentifier("details.activity")
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
                            Text("Impact: replaces managed state for every configured workspace. All workspaces are stopped; the current restore contract does not promise automatic restart.")
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
            Button("Repair MSW installation…") {
                NSApp.sendAction(#selector(AppDelegate.openSetupRepair), to: nil, from: nil)
            }
            .accessibilityIdentifier("maintenance.repair.button")
            Text("Checks verify MSW without showing credentials.")
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
                    .accessibilityIdentifier("diagnostics.\(check.id)")
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                Text("Next: \(model.nextActionTitle(for: workspace))").font(.caption).foregroundStyle(.secondary)
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
            Text("Restoring \(archive.lastPathComponent) replaces managed state for every configured workspace, including code, data, VM state, databases, Docker artifacts, and guest-side credentials.")
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
