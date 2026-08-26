import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum WorkspaceSection: String, CaseIterable, Identifiable {
    case files = "Files"
    case logs = "Logs"
    case activity = "Activity"
    case ports = "Network"

    var id: String { rawValue }


    var symbol: String {
        switch self {
        case .files: return "folder"
        case .logs: return "text.alignleft"
        case .activity: return "clock"
        case .ports: return "network"
        }
    }

    init(deepLinkValue: String) {
        switch deepLinkValue.lowercased() {
        case "logs": self = .logs
        case "activity": self = .activity
        case "ports", "network": self = .ports
        case "files", "folders", "repositories": self = .files
        default: self = .files
        }
    }
}

enum DetailMode {
    case overview
    case workspaces
    case backup
}

enum BackupDestinationPicker {
    @MainActor
    static func makePanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = "Choose Backup Destination"
        panel.prompt = "Choose Destination…"
        panel.message = "Selecting a directory does not start the backup. You will review scope and workspace impact next."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        return panel
    }
}

private enum WorkspaceAttentionDestination {
    case network
    case github
    case maintenance
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
    @State private var hiddenWorkspaces: Set<Workspace.ID> = []
    @State private var expandedInactivePortWorkspaces: Set<String> = []
    @State private var visitedWorkspaceSections: Set<WorkspaceSection>
    @State private var logSearch = ""
    @State private var logSelection: Set<LogRowID> = []
    @State private var followsLogs = true
    @State private var wrapsLogs = false

    init(
        model: AppModel,
        navigation: AppNavigationState,
        mode: DetailMode
    ) {
        self.model = model
        self.navigation = navigation
        self.mode = mode
        _visitedWorkspaceSections = State(initialValue: [navigation.workspaceSection])
    }

    var body: some View {
        Group {
            switch mode {
            case .overview: overviewDashboard
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
        .sheet(isPresented: $reviewBackup, onDismiss: {
            model.cancelPendingBackup()
        }) {
            if let preview = model.pendingBackupPreview {
                BackupReviewView(
                    preview: preview,
                    isBusy: model.isMaintenanceOperationInFlight,
                    cancel: {
                        reviewBackup = false
                        model.cancelPendingBackup()
                    },
                    apply: {
                        reviewBackup = false
                        beginBackup(to: preview.destination)
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
        VStack(spacing: 0) {
            workspaceFilterBar
                .padding(.horizontal, 20)
                .padding(.vertical, 12)

            Divider()

            sectionContent
                .padding(20)
                .frame(
                    maxWidth: .infinity,
                    minHeight: 400,
                    maxHeight: .infinity,
                    alignment: .topLeading
                )
        }
        .onChange(of: navigation.workspaceSection) { _, section in
            visitedWorkspaceSections.insert(section)
        }
        .task(id: routeIdentity) {
            model.clearDetailError()
            if navigation.workspaceSection != .logs || followsLogs {
                loadSelectedSection()
            }
            while automaticallyRefreshesSelectedSection {
                do {
                    try await Task.sleep(for: .seconds(15))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                loadSelectedSection()
            }
        }
    }

    private var routeIdentity: String {
        let hidden = hiddenWorkspaces.map(\.rawValue).sorted().joined(separator: ",")
        let follow = navigation.workspaceSection == .logs ? followsLogs.description : ""
        return "\(navigation.workspaceSection.rawValue):\(hidden):\(follow)"
    }

    private var automaticallyRefreshesSelectedSection: Bool {
        switch navigation.workspaceSection {
        case .files, .ports: return true
        case .logs: return followsLogs
        case .activity: return false
        }
    }



    private var sectionContent: some View {
        ZStack {
            ForEach(
                WorkspaceSection.allCases.filter { visitedWorkspaceSections.contains($0) }
            ) { section in
                workspaceSectionContent(section)
                    .opacity(navigation.workspaceSection == section ? 1 : 0)
                    .allowsHitTesting(navigation.workspaceSection == section)
                    .accessibilityHidden(navigation.workspaceSection != section)
                    .zIndex(navigation.workspaceSection == section ? 1 : 0)
            }
        }
    }

    @ViewBuilder
    private func workspaceSectionContent(_ section: WorkspaceSection) -> some View {
        switch section {
        case .files: filesAndRepositories
        case .logs: logs
        case .activity: activity
        case .ports: ports
        }
    }

    private func loadSelectedSection() {
        switch navigation.workspaceSection {
        case .files:
            model.loadRepositories(
                for: visibleWorkspaces.map(\.id),
                clearsError: false
            )
        case .logs:
            model.loadLogs(for: visibleWorkspaces.map(\.id), clearsError: false)
        case .ports:
            model.loadPorts(clearsError: false)
        case .activity:
            break
        }
    }



    private var overviewDashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Workspaces")
                        .font(.title3.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    workspaceSummary
                }

                VStack(alignment: .leading, spacing: 10) {
                    systemHealthHeader
                    systemHealth
                }
                .accessibilityIdentifier("overview.system-health")
            }
            .padding(20)
        }
        .accessibilityIdentifier("details.overview")
    }

    private var systemHealthHeader: some View {
        HStack {
            Text("System health")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if needsInstallationRepair {
                Button("Repair MSW installation…") {
                    NSApp.sendAction(#selector(AppDelegate.openSetupRepair), to: nil, from: nil)
                }
                .accessibilityIdentifier("maintenance.repair.button")
            }
            Button("Run checks") {
                model.runSystemHealthChecks()
            }
            .disabled(model.isSystemHealthLoading)
            .accessibilityIdentifier("overview.run-checks.button")
        }
    }

    private var workspaceSummary: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(model.workspaces) { workspace in
                WorkspaceSummaryRow(
                    workspace: workspace,
                    model: model,
                    latestError: latestError(for: workspace),
                    openLogs: {
                        hiddenWorkspaces = Set(model.workspaces.map(\.id).filter { $0 != workspace.id })
                        navigation.tab = .workspaces
                        navigation.workspaceSection = .logs
                    },
                    openAttention: openAttention
                )
            }
        }
        .accessibilityIdentifier("workspace.summary")
    }

    private func latestError(for workspace: Workspace) -> String? {
        if let failure = model.latestOperationFailure, failure.workspace == workspace.id {
            return failure.reason
        }
        return model.activities.first {
            $0.workspace == workspace.id.rawValue && $0.isFailure
        }.flatMap { $0.detail ?? $0.title }
    }

    private func openAttention(_ destination: WorkspaceAttentionDestination) {
        switch destination {
        case .network:
            navigation.tab = .workspaces
            navigation.workspaceSection = .ports
        case .github:
            navigation.tab = .github
        case .maintenance:
            navigation.tab = .overview
        }
    }

    @ViewBuilder
    private var filesAndRepositories: some View {
        if visibleWorkspaces.isEmpty {
            ContentUnavailableView(
                "No workspaces selected",
                systemImage: "line.3.horizontal.decrease.circle",
                description: Text("Select at least one workspace to browse its files and repositories.")
            )
        } else {
            HSplitView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Repositories")
                        .font(.headline)
                        .accessibilityIdentifier("files.repositories.title")
                    repositories
                }
                .padding(.leading, 16)
                .padding(.trailing, 12)
                .frame(minWidth: 300, idealWidth: 360, maxWidth: .infinity, maxHeight: .infinity)

                workspaceFileTrees
                    .padding(.horizontal, 16)
                    .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
            }
            .accessibilityIdentifier("details.files")
        }
    }

    private var workspaceFileTrees: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("File tree")
                .font(.headline)
                .accessibilityIdentifier("files.tree.title")
            CombinedWorkspaceFileTree(model: model, workspaces: visibleWorkspaces)
        }
    }


    private struct LogRowID: Hashable {
        let workspace: Workspace.ID
        let observedAt: Date
        let ordinal: Int
    }

    private struct TaggedLogLine: Identifiable {
        let id: LogRowID
        let workspace: Workspace.ID
        let observedAt: Date
        let timestamp: String
        let message: String
        let prettyJSON: String?
    }

    @ViewBuilder
    private var logs: some View {
        let allRows = visibleLogLines
        let rows = Self.filteredLogLines(allRows, query: logSearch)
        let selectedRows = rows.filter { logSelection.contains($0.id) }

        VStack(alignment: .leading, spacing: 10) {
            if let failure = model.latestOperationFailure,
               failure.workspace.map({ !hiddenWorkspaces.contains($0) }) ?? true {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(failure.reason)
                            .font(.caption.weight(.semibold))
                        Text(failure.recovery)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("View system health") {
                            navigation.tab = .overview
                        }
                        .accessibilityIdentifier("details.latest-operation-error.action")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("details.latest-operation-error")
            }

            if visibleWorkspaces.isEmpty {
                ContentUnavailableView(
                    "No workspaces selected",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("Select at least one workspace to see its logs.")
                )
            } else {
                logToolbar(rows: rows, selectedRows: selectedRows)

                if allRows.isEmpty, model.isDetailLoading {
                    logLoadingSkeleton
                } else if allRows.isEmpty {
                    ContentUnavailableView(
                        "No logs yet",
                        systemImage: "text.alignleft",
                        description: Text("Logs from the selected workspaces will appear here.")
                    )
                } else if rows.isEmpty {
                    ContentUnavailableView.search(text: logSearch)
                } else {
                    ScrollViewReader { proxy in
                        Table(rows, selection: $logSelection) {
                            TableColumn("Timestamp") { row in
                                Text(row.timestamp)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .accessibilityIdentifier(
                                        "logs.row.\(row.workspace.rawValue).\(row.id.ordinal).timestamp"
                                    )
                            }
                            .width(min: 84, ideal: 92, max: 112)

                            TableColumn("Workspace") { row in
                                Text(row.workspace.rawValue)
                                    .font(.system(.caption, design: .monospaced).weight(.medium))
                                    .lineLimit(1)
                            }
                            .width(min: 88, ideal: 104, max: 140)

                            TableColumn("Message") { row in
                                Text(row.message)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .lineLimit(wrapsLogs ? nil : 1)
                                    .fixedSize(horizontal: false, vertical: wrapsLogs)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .accessibilityIdentifier(
                                        "logs.row.\(row.workspace.rawValue).\(row.id.ordinal).message"
                                    )
                            }
                        }
                        .tableStyle(.inset(alternatesRowBackgrounds: true))
                        .environment(\.defaultMinListRowHeight, wrapsLogs ? 28 : 22)
                        .accessibilityIdentifier("logs.table")
                        .contextMenu(forSelectionType: LogRowID.self) { identifiers in
                            if let row = rows.first(where: { identifiers.contains($0.id) }) {
                                Button("Copy Message") {
                                    copyToPasteboard(row.message)
                                }
                                Button("Copy Row") {
                                    copyToPasteboard(Self.formattedLogText([row]))
                                }
                                Divider()
                                Button("Include Workspace") {
                                    hiddenWorkspaces = Set(
                                        model.workspaces.map(\.id).filter { $0 != row.workspace }
                                    )
                                }
                                Button("Exclude Workspace") {
                                    hiddenWorkspaces.insert(row.workspace)
                                }
                            }
                        }
                        .onAppear {
                            if followsLogs, let last = rows.last {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                        .onChange(of: rows.last?.id) { _, lastID in
                            if followsLogs, let lastID {
                                proxy.scrollTo(lastID, anchor: .bottom)
                            }
                        }
                        .onChange(of: followsLogs) { _, follows in
                            if follows, let last = rows.last {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                    .inspector(isPresented: Binding(
                        get: { selectedRows.count == 1 },
                        set: { if !$0 { logSelection.removeAll() } }
                    )) {
                        if let row = selectedRows.first {
                            logInspector(row)
                                .inspectorColumnWidth(min: 240, ideal: 300, max: 420)
                        }
                    }
                    .onChange(of: Set(rows.map(\.id))) { _, visibleIDs in
                        logSelection.formIntersection(visibleIDs)
                    }
                }
            }
            detailError
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func logToolbar(
        rows: [TaggedLogLine],
        selectedRows: [TaggedLogLine]
    ) -> some View {
        HStack(spacing: 8) {
            TextField("Search logs", text: $logSearch)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .accessibilityIdentifier("logs.search")

            Button {
                followsLogs.toggle()
            } label: {
                Label(followsLogs ? "Pause" : "Follow", systemImage: followsLogs ? "pause" : "arrow.down.to.line")
            }
            .accessibilityIdentifier("logs.follow")

            Toggle(isOn: $wrapsLogs) {
                Label("Wrap", systemImage: "text.justify")
            }
            .toggleStyle(.button)
            .accessibilityIdentifier("logs.wrap")

            Spacer()

            if model.isDetailLoading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Refreshing logs")
            }
            Text("\(rows.count) lines")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Copy Selected") {
                copyToPasteboard(Self.formattedLogText(selectedRows))
            }
            .disabled(selectedRows.isEmpty)
            .accessibilityIdentifier("logs.copy.selected")

            Button("Copy Visible") {
                copyToPasteboard(Self.formattedLogText(rows))
            }
            .disabled(rows.isEmpty)
            .accessibilityIdentifier("logs.copy.visible")
        }
        .controlSize(.small)
    }

    private func logInspector(_ row: TaggedLogLine) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(row.prettyJSON == nil ? "Log details" : "JSON details")
                .font(.headline)
            LabeledContent("Timestamp", value: row.observedAt.formatted())
            LabeledContent("Workspace", value: row.workspace.rawValue)
            Divider()
            ScrollView {
                Text(row.prettyJSON ?? row.message)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            HStack {
                Button("Copy Message") {
                    copyToPasteboard(row.message)
                }
                Button("Copy Row") {
                    copyToPasteboard(Self.formattedLogText([row]))
                }
            }
            .controlSize(.small)
        }
        .padding()
        .accessibilityIdentifier("logs.inspector")
    }

    private var logLoadingSkeleton: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(0..<8, id: \.self) { index in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.quaternary)
                        .frame(width: 84, height: 10)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.quaternary)
                        .frame(width: 96, height: 10)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.quaternary)
                        .frame(width: index.isMultiple(of: 3) ? 260 : 420, height: 10)
                }
            }
        }
        .padding(.top, 8)
        .accessibilityHidden(true)
    }

    private var visibleLogLines: [TaggedLogLine] {
        var result: [TaggedLogLine] = []
        for workspace in visibleWorkspaces {
            guard let response = model.logsByWorkspace[workspace.id.rawValue] else {
                continue
            }
            let startIndex = max(0, response.lines.count - 100)
            for (offset, line) in response.lines.suffix(100).enumerated() where line.safeForDisplay {
                let message = Self.cleanedLogMessage(line.message)
                guard !message.isEmpty else { continue }
                result.append(
                    TaggedLogLine(
                        id: LogRowID(
                            workspace: workspace.id,
                            observedAt: line.observedAt,
                            ordinal: startIndex + offset
                        ),
                        workspace: workspace.id,
                        observedAt: line.observedAt,
                        timestamp: line.observedAt.formatted(date: .omitted, time: .standard),
                        message: message,
                        prettyJSON: Self.prettyJSON(from: message)
                    )
                )
            }
        }
        result.sort {
            if $0.observedAt != $1.observedAt {
                return $0.observedAt < $1.observedAt
            }
            if $0.workspace != $1.workspace {
                return $0.workspace.rawValue < $1.workspace.rawValue
            }
            return $0.id.ordinal < $1.id.ordinal
        }
        return result
    }

    private static func filteredLogLines(
        _ lines: [TaggedLogLine],
        query: String
    ) -> [TaggedLogLine] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return lines }
        return lines.filter {
            $0.timestamp.localizedCaseInsensitiveContains(query)
                || $0.workspace.rawValue.localizedCaseInsensitiveContains(query)
                || $0.message.localizedCaseInsensitiveContains(query)
        }
    }

    private static func formattedLogText(_ lines: [TaggedLogLine]) -> String {
        let timestampWidth = lines.map(\.timestamp.count).max() ?? 0
        let workspaceWidth = lines.map(\.workspace.rawValue.count).max() ?? 0
        return lines.map { line in
            let timestamp = line.timestamp.padding(
                toLength: timestampWidth,
                withPad: " ",
                startingAt: 0
            )
            let workspace = line.workspace.rawValue.padding(
                toLength: workspaceWidth,
                withPad: " ",
                startingAt: 0
            )
            let firstPrefix = "\(timestamp) │ \(workspace) │ "
            let continuationPrefix = "\(String(repeating: " ", count: timestampWidth)) │ \(String(repeating: " ", count: workspaceWidth)) │ "
            return line.message
                .split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
                .map { index, content in
                    "\(index == 0 ? firstPrefix : continuationPrefix)\(content)"
                }
                .joined(separator: "\n")
        }
        .joined(separator: "\n")
    }

    private static func cleanedLogMessage(_ message: String) -> String {
        strippingRepeatedPrefix(from: message)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func prettyJSON(from message: String) -> String? {
        guard let data = message.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let prettyData = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ) else {
            return nil
        }
        return String(data: prettyData, encoding: .utf8)
    }

    private static func strippingRepeatedPrefix(from message: String) -> String {
        guard let first = message.first else { return message }
        var cursor = message.startIndex
        var repeated = 0
        while cursor < message.endIndex, message[cursor] == first {
            repeated += 1
            cursor = message.index(after: cursor)
        }
        guard repeated >= 8 else { return message }
        return cursor < message.endIndex ? String(message[cursor...]) : ""
    }




    private var visibleWorkspaces: [Workspace] {
        model.workspaces.filter { !hiddenWorkspaces.contains($0.id) }
    }

    private var workspaceFilterBar: some View {
        HStack(spacing: 8) {
            Button(hiddenWorkspaces.isEmpty ? "Clear" : "All") {
                if hiddenWorkspaces.isEmpty {
                    hiddenWorkspaces = Set(model.workspaces.map(\.id))
                } else {
                    hiddenWorkspaces.removeAll()
                }
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("workspace.filter.toggle-all")
            .accessibilityLabel(
                hiddenWorkspaces.isEmpty ? "Clear all workspaces" : "Select all workspaces"
            )
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.workspaces) { workspace in
                        workspaceFilterChip(for: workspace)
                    }
                }
            }
        }
        .controlSize(.small)
    }

    private func workspaceFilterChip(for workspace: Workspace) -> some View {
        let isSelected = !hiddenWorkspaces.contains(workspace.id)
        return Button {
            if isSelected {
                hiddenWorkspaces.insert(workspace.id)
            } else {
                hiddenWorkspaces.remove(workspace.id)
            }
        } label: {
            Label(
                workspace.id.rawValue,
                systemImage: isSelected ? "checkmark.circle.fill" : "circle"
            )
            .font(.caption.weight(.medium))
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .tint(isSelected ? Color.accentColor : Color.secondary)
        .accessibilityIdentifier("workspace.filter.\(workspace.id.rawValue)")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var repositories: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(visibleWorkspaces) { workspace in
                        repositorySection(for: workspace)
                    }
                }
                .padding(.vertical, 4)
            }
            detailError
        }
    }

    @ViewBuilder
    private func repositorySection(for workspace: Workspace) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(workspace.id.rawValue)
                    .font(.headline)
                Spacer()
                Text(workspace.state.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let value = model.repositoriesByWorkspace[workspace.id.rawValue] {
                FreshnessNotice(
                    freshness: value.freshness,
                    observedAt: newestRepositoryDate(value),
                    reason: value.notice
                )
                if value.repositories.isEmpty {
                    Text(value.needsStart ? "Workspace is stopped" : "No repositories")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(value.repositories) { repository in
                        RepositoryRow(repository: repository) {
                            model.reviewPush(for: repository, workspace: workspace.id)
                        }
                    }
                }
            } else if model.repositoryLoadingWorkspaces.contains(workspace.id.rawValue) {
                RepositoryLoadingSkeleton()
            } else if workspace.state == .stopped || workspace.state == .exited {
                Text("Workspace is stopped")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(
                    model.repositoryUnavailableWorkspaces.contains(workspace.id.rawValue)
                        ? "Repository information is unavailable"
                        : "No repository information"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("repositories.workspace.\(workspace.id.rawValue)")
    }

}
private struct RepositoryLoadingSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.14))
                .frame(width: 150, height: 13)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.1))
                .frame(width: 110, height: 10)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading repositories")
        .accessibilityIdentifier("repositories.loading-skeleton")
    }
}


private struct CombinedWorkspaceFileTree: View {
    @Bindable var model: AppModel
    let workspaces: [Workspace]
    @State private var expandedWorkspaces: Set<Workspace.ID>

    init(model: AppModel, workspaces: [Workspace]) {
        self.model = model
        self.workspaces = workspaces
        _expandedWorkspaces = State(initialValue: Set(workspaces.map(\.id)))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(workspaces) { workspace in
                    VStack(alignment: .leading, spacing: 4) {
                        Button {
                            if expandedWorkspaces.contains(workspace.id) {
                                expandedWorkspaces.remove(workspace.id)
                            } else {
                                expandedWorkspaces.insert(workspace.id)
                            }
                        } label: {
                            HStack(spacing: 7) {
                                Image(
                                    systemName: expandedWorkspaces.contains(workspace.id)
                                        ? "chevron.down"
                                        : "chevron.right"
                                )
                                .font(.caption2.weight(.semibold))
                                .frame(width: 14)
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(.secondary)
                                Text(workspace.id.rawValue)
                                    .font(.body.weight(.medium))
                                Spacer()
                                Text(workspace.state.rawValue)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("files.tree.workspace.\(workspace.id.rawValue)")

                        if expandedWorkspaces.contains(workspace.id) {
                            if workspace.state == .running && workspace.canOpenTerminal {
                                FolderBrowserView(
                                    model: model,
                                    workspace: workspace.id,
                                    compact: true,
                                    treeOnly: true
                                )
                                .id(workspace.id)
                                .padding(.leading, 21)
                            } else {
                                Text(
                                    workspace.state == .stopped
                                        ? "Workspace is stopped"
                                        : "File browsing is unavailable"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 35)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .accessibilityIdentifier("files.workspace-tree")
    }
}

struct FolderBrowserView: View {
    @Bindable var model: AppModel
    let workspace: Workspace.ID
    var compact = false
    var treeOnly = false
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
        Group {
            if treeOnly {
                browserContent
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    header

                    TextField("Search folders", text: $folderSearch)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("folders.search.field")

                    browserContent

                    if let editorError {
                        Label(editorError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("folders.error")
                    }

                    breadcrumbBar
                }
            }
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
            if let snapshot, folderSearch.isEmpty, !snapshot.entries.isEmpty {
                folderTree(entries: snapshot.entries)
                    .redacted(reason: .placeholder)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            } else {
                folderLoadingSkeleton
            }
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

    private var folderLoadingSkeleton: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(0..<(treeOnly ? 3 : 6), id: \.self) { index in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.14))
                        .frame(width: 16, height: 16)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.14))
                        .frame(width: CGFloat(110 + (index % 3) * 35), height: 12)
                }
            }
        }
        .padding(10)
        .frame(
            maxWidth: .infinity,
            minHeight: treeOnly ? 60 : (compact ? 170 : 240),
            idealHeight: treeOnly ? 80 : (compact ? 190 : 320),
            maxHeight: treeOnly ? nil : (compact ? 210 : .infinity),
            alignment: .topLeading
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(folderSearch.isEmpty ? "Loading folders" : "Searching folders")
        .accessibilityIdentifier("folders.loading-skeleton")
    }

    @ViewBuilder
    private func folderTree(entries: [MSWDirectoryResponse.Entry]) -> some View {
        if treeOnly {
            folderTreeRows(entries)
                .padding(.vertical, 2)
                .accessibilityIdentifier("folders.tree")
        } else {
            ScrollView {
                folderTreeRows(entries)
                    .padding(6)
            }
            .frame(
                minHeight: compact ? 170 : 240,
                idealHeight: compact ? 190 : 320,
                maxHeight: compact ? 210 : .infinity
            )
            .accessibilityIdentifier("folders.tree")
        }
    }

    private func folderTreeRows(
        _ entries: [MSWDirectoryResponse.Entry]
    ) -> some View {
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
                    onNavigate: handleTreeNavigation
                )
            }
        }
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
    private func handleTreeNavigation(_ path: String) {
        if treeOnly {
            selectedFolderPath = path
            expandedPaths.insert(path)
            loadChildren(path)
        } else {
            navigateToFolder(path)
        }
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
            VStack(alignment: .leading, spacing: 7) {
                ForEach(0..<2, id: \.self) { index in
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.secondary.opacity(0.14))
                            .frame(width: 14, height: 14)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.14))
                            .frame(width: CGFloat(90 + index * 30), height: 10)
                    }
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading folders")
            .accessibilityIdentifier("folders.entry.\(entry.path).loading-skeleton")
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
        VStack(alignment: .leading, spacing: 12) {
            if visibleWorkspaces.isEmpty {
                ContentUnavailableView(
                    "No workspaces selected",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("Select at least one workspace to see its network services.")
                )
            } else {
                Text("Each workspace has its own .msw.test address, so the same port can be active in multiple workspaces.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let snapshot = model.portsSnapshot {
                    FreshnessNotice(freshness: snapshot.freshness, observedAt: nil, reason: nil)
                    if visibleNetworkSnapshots(snapshot).isEmpty {
                        ContentUnavailableView(
                            "No active services",
                            systemImage: "network.slash",
                            description: Text("Start a workspace service to see it here. Inactive configured ports stay hidden.")
                        )
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                ForEach(visibleNetworkSnapshots(snapshot)) { workspacePorts in
                                    if let workspace = model.workspaces.first(where: {
                                        $0.id.rawValue == workspacePorts.workspace
                                    }) {
                                        networkRow(workspace: workspace, snapshot: workspacePorts)
                                    }
                                }
                            }
                        }
                    }
                } else {
                    Text("Port information is not available yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            detailError
        }
        .accessibilityIdentifier("details.ports")
    }

    private func visibleNetworkSnapshots(
        _ response: MSWPortsResponse
    ) -> [MSWPortsResponse.WorkspacePorts] {
        response.workspaces
            .filter { snapshot in
                guard let id = Workspace.ID(rawValue: snapshot.workspace),
                      !hiddenWorkspaces.contains(id) else {
                    return false
                }
                let workspace = model.workspaces.first { $0.id == id }
                let hasWarning = workspace?.portWarning?.isEmpty == false
                let isStopped = snapshot.lifecycle == .stopped || snapshot.lifecycle == .exited
                return activePorts(snapshot).isEmpty == false || hasWarning || !isStopped
            }
            .sorted { lhs, rhs in
                let leftActive = activePorts(lhs).count
                let rightActive = activePorts(rhs).count
                if leftActive != rightActive { return leftActive > rightActive }
                if lhs.lifecycle == .running, rhs.lifecycle != .running { return true }
                if rhs.lifecycle == .running, lhs.lifecycle != .running { return false }
                return lhs.workspace < rhs.workspace
            }
    }

    private func networkRow(
        workspace: Workspace,
        snapshot: MSWPortsResponse.WorkspacePorts
    ) -> some View {
        let active = activePorts(snapshot)
        let inactive = inactivePorts(snapshot)
        return GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if let warning = workspace.portWarning, !warning.isEmpty {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !active.isEmpty {
                    Label("Active", systemImage: "circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                    portStrip(active, workspace: workspace, snapshot: snapshot, active: true)
                } else if snapshot.listeningState == .unknown {
                    Label(
                        "Listening state unavailable",
                        systemImage: "questionmark.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Text("No active services")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !inactive.isEmpty {
                    DisclosureGroup(
                        snapshot.listeningState == .known
                            ? "Other configured ports (\(inactive.count))"
                            : "Configured ports (\(inactive.count))",
                        isExpanded: inactivePortsBinding(snapshot.workspace)
                    ) {
                        portStrip(
                            inactive,
                            workspace: workspace,
                            snapshot: snapshot,
                            active: false
                        )
                        .padding(.top, 6)
                    }
                    .font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack {
                Text(snapshot.workspace)
                Text(snapshot.host)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(snapshot.lifecycle.rawValue)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("network.workspace.\(snapshot.workspace)")
    }

    private func portStrip(
        _ ports: [MSWPortsResponse.Port],
        workspace: Workspace,
        snapshot: MSWPortsResponse.WorkspacePorts,
        active: Bool
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(ports) { port in
                    HStack(spacing: 6) {
                        Text(port.port)
                            .font(.callout.monospacedDigit().weight(.medium))
                        if active && canOpen(port: port, in: workspace) {
                            Button("Open") {
                                model.openSite(for: workspace.id, port: port.port)
                            }
                            .controlSize(.small)
                            .accessibilityIdentifier(
                                "network.\(workspace.id.rawValue).port.\(port.port).open"
                            )
                        }
                        let url = networkURL(host: snapshot.host, port: port.port)
                        Button {
                            copyToPasteboard(url)
                        } label: {
                            Label("Copy URL", systemImage: "doc.on.doc")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Copy \(url)")
                        .accessibilityIdentifier(
                            "network.\(workspace.id.rawValue).port.\(port.port).copy"
                        )
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        active ? Color.green.opacity(0.09) : Color.secondary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 7)
                    )
                }
            }
        }
    }

    private func activePorts(
        _ snapshot: MSWPortsResponse.WorkspacePorts
    ) -> [MSWPortsResponse.Port] {
        snapshot.ports
            .filter { $0.listening == true }
            .sorted(by: portOrder)
    }

    private func inactivePorts(
        _ snapshot: MSWPortsResponse.WorkspacePorts
    ) -> [MSWPortsResponse.Port] {
        snapshot.ports
            .filter { $0.listening != true }
            .sorted(by: portOrder)
    }

    private func portOrder(_ lhs: MSWPortsResponse.Port, _ rhs: MSWPortsResponse.Port) -> Bool {
        (Int(lhs.port) ?? .max) < (Int(rhs.port) ?? .max)
    }

    private func inactivePortsBinding(_ workspace: String) -> Binding<Bool> {
        Binding(
            get: { expandedInactivePortWorkspaces.contains(workspace) },
            set: { expanded in
                if expanded {
                    expandedInactivePortWorkspaces.insert(workspace)
                } else {
                    expandedInactivePortWorkspaces.remove(workspace)
                }
            }
        )
    }

    private func canOpen(port: MSWPortsResponse.Port, in workspace: Workspace) -> Bool {
        port.configured &&
            port.listening == true &&
            workspace.state == .running &&
            workspace.freshness == .fresh &&
            workspace.networkHost != nil &&
            workspace.credential != .quarantined &&
            !(workspace.skippedPorts ?? []).contains(Int(port.port) ?? -1)
    }

    private func networkURL(host: String, port: String) -> String {
        "http://\(host):\(port)"
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        _ = NSPasteboard.general.setString(value, forType: .string)
    }


    private var activity: some View {
        VStack(alignment: .leading, spacing: 12) {
            if visibleWorkspaces.isEmpty {
                ContentUnavailableView(
                    "No workspaces selected",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("Select at least one workspace to see its activity.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if filteredActivities.isEmpty {
                            ContentUnavailableView(
                                "No recent activity",
                                systemImage: "clock",
                                description: Text("Actions for the selected workspaces will appear here.")
                            )
                        } else {
                            ForEach(filteredActivities.prefix(50)) { entry in
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
                                                .font(.caption.weight(.medium))
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
                }
            }
        }
        .accessibilityIdentifier("details.activity")
    }

    private var filteredActivities: [MSWActivity] {
        model.activities.filter { entry in
            guard let workspace = entry.workspace,
                  let id = Workspace.ID(rawValue: workspace) else {
                return true
            }
            return !hiddenWorkspaces.contains(id)
        }
    }

    private var backup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Archive scope")
                        .font(.title3.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Label("Includes managed workspace code and data, VM state, databases, Docker images and volumes, guest-side credentials, and bounded diagnostics.", systemImage: "archivebox")
                    Label("Excludes Mac Keychain records and host credentials.", systemImage: "key.slash")
                    Text("Treat the archive as sensitive. Store it only in a trusted destination with appropriate disk encryption and access controls.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Backup")
                            .font(.title3.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        Spacer()
                        Button("Create New Backup…") { chooseBackupDirectory() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isMaintenanceOperationInFlight || model.isBackupPreviewLoading)
                            .accessibilityIdentifier("backup.create-new.button")
                    }

                    if model.isBackupPreviewLoading {
                        ProgressView("Calculating required disk space…")
                            .accessibilityIdentifier("backup.preview.loading")
                    }
                    if let backupDestination {
                        LabeledContent("Backup destination", value: backupDestination.path(percentEncoded: false))
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Restore")
                            .font(.title3.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        Spacer()
                        Button("Choose Restore Archive…") { chooseRestoreArchive() }
                            .disabled(model.isMaintenanceOperationInFlight)
                    }

                    if let restoreArchive {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Restore preview")
                                .font(.headline)
                                .accessibilityAddTraits(.isHeader)
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
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Operation")
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                        ModelOperationView(operation: operation) {
                            retryMaintenance(kind: operation.kind)
                        }
                    }
                } else if let operation = maintenanceOperation {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Operation")
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                        MaintenanceOperationView(operation: operation) {
                            if operation.kind == .backup, let destination = backupDestination {
                                beginBackup(to: destination)
                            } else if operation.kind == .restore, restoreArchive != nil {
                                confirmRestore = true
                            }
                        }
                    }
                }

                if let result = model.backupResult {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Latest backup result")
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
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

                detailError
            }
            .padding(20)
        }
    }

    private var systemHealth: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(model.systemHealthChecks) { check in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Label(check.title, systemImage: diagnosticSymbol(check.status))
                            .font(.body.weight(.medium))
                        Spacer()
                        Text(healthStatusTitle(check.status))
                            .foregroundStyle(diagnosticColor(check.status))
                    }
                    Text(check.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let recovery = check.remediation {
                            Text(recovery)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("diagnostics.\(check.id)")
                }

            if model.isSystemHealthLoading {
                OperationRow(
                    phase: "Running checks",
                    scope: nil,
                    detail: "Checking the same system dependencies used during setup."
                )
            }
        }
    }

    private var needsInstallationRepair: Bool {
        model.startupRecoveryBlockedReason != nil || model.systemHealthChecks.contains { check in
            let repairable = check.id == "msw-runtime" ||
                check.id == "host-integration" ||
                check.id.hasPrefix("tool-")
            return repairable && check.status != .pass
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
                if model.backupRequiresRuntimeRepair {
                    Button("Repair MSW installation…") {
                        NSApp.sendAction(#selector(AppDelegate.openSetupRepair), to: nil, from: nil)
                    }
                    .accessibilityIdentifier("backup.repair-runtime.button")
                } else {
                    Button("Retry", action: retryDetailFailure)
                        .keyboardShortcut("r", modifiers: [.command, .shift])
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("details.error")
        }
    }

    private func chooseBackupDirectory() {
        let panel = BackupDestinationPicker.makePanel()
        panel.directoryURL = model.backupUITestDestinationIfAvailable()
        if panel.runModal() == .OK, let url = panel.url {
            backupDestination = url
            prepareBackupReview(to: url)
        }
    }

    private func retryDetailFailure() {
        if let backupDestination {
            prepareBackupReview(to: backupDestination)
        } else {
            loadSelectedSection()
        }
    }

    private func prepareBackupReview(to destination: URL) {
        Task { @MainActor in
            guard let preview = await model.prepareBackup(to: destination) else { return }
            backupDestination = preview.destination
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
        if kind == .backup, let backupDestination {
            prepareBackupReview(to: backupDestination)
        } else if kind == .restore, restoreArchive != nil {
            confirmRestore = true
        }
    }

    private func archiveSize(_ url: URL) -> String {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return "Unavailable" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }


    private func diagnosticSymbol(_ status: MSWPreflightCheck.Status) -> String {
        switch status {
        case .pass: return "checkmark.circle.fill"
        case .needsAction: return "exclamationmark.triangle.fill"
        case .unavailable: return "questionmark.circle.fill"
        }
    }

    private func diagnosticColor(_ status: MSWPreflightCheck.Status) -> Color {
        switch status {
        case .pass: return .green
        case .needsAction: return .orange
        case .unavailable: return .secondary
        }
    }

    private func healthStatusTitle(_ status: MSWPreflightCheck.Status) -> String {
        switch status {
        case .pass: return "Passed"
        case .needsAction: return "Needs action"
        case .unavailable: return "Unavailable"
        }
    }
}


private struct WorkspaceSummaryRow: View {
    private struct Attention {
        let message: String
        let destination: WorkspaceAttentionDestination
        let isCritical: Bool
    }

    let workspace: Workspace
    @Bindable var model: AppModel
    let latestError: String?
    let openLogs: () -> Void
    let openAttention: (WorkspaceAttentionDestination) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(workspace.id.rawValue)
                    .font(.headline)
                HStack(spacing: 5) {
                    Circle()
                        .fill(stateColor)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(workspace.state.rawValue)
                        .font(.callout.weight(.medium))
                        .accessibilityIdentifier("workspace.\(workspace.id.rawValue).summary-state")
                }
                Spacer()
                if workspace.canStart && workspace.state != .running {
                    Button("Start") { model.start(workspace.id) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                if workspace.canStop && (workspace.state == .running || workspace.state == .quarantined) {
                    Button("Stop") { model.stop(workspace.id) }
                        .controlSize(.small)
                }
                if workspace.canRestart && workspace.state == .running {
                    Button("Restart") { model.restart(workspace.id) }
                        .controlSize(.small)
                }
            }

            if let latestError {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label(latestError, systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .accessibilityIdentifier("workspace.\(workspace.id.rawValue).summary-error")
                    Spacer()
                    Button("View logs", action: openLogs)
                        .buttonStyle(.link)
                        .accessibilityIdentifier("workspace.\(workspace.id.rawValue).summary-error-link")
                }
            }

            if let attention {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label(
                        attention.message,
                        systemImage: attention.isCritical
                            ? "exclamationmark.octagon.fill"
                            : "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(attention.isCritical ? Color.red : Color.orange)
                    .lineLimit(2)
                    .accessibilityIdentifier("workspace.\(workspace.id.rawValue).summary-warning")
                    Spacer()
                    Button("View") { openAttention(attention.destination) }
                        .buttonStyle(.link)
                        .accessibilityIdentifier("workspace.\(workspace.id.rawValue).summary-warning-link")
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.\(workspace.id.rawValue).summary-row")
    }

    private var attention: Attention? {
        if let reason = workspace.quarantineReason {
            return Attention(message: reason, destination: .maintenance, isCritical: true)
        }
        if let warning = workspace.portWarning, !warning.isEmpty {
            return Attention(message: warning, destination: .network, isCritical: false)
        }
        if workspace.credential.needsAttention {
            return Attention(
                message: "GitHub access: \(workspace.credential.rawValue)",
                destination: .github,
                isCritical: false
            )
        }
        if workspace.freshness != .fresh {
            return Attention(
                message: workspace.statusReason ?? "Workspace information is \(workspace.freshness.rawValue.lowercased()).",
                destination: .maintenance,
                isCritical: false
            )
        }
        return nil
    }

    private var stateColor: Color {
        switch workspace.state {
        case .running: return .green
        case .quarantined: return .red
        case .starting, .stopping, .restarting, .exited, .unavailable, .unknown: return .orange
        case .stopped: return .secondary
        }
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
                Text("\(repository.branch ?? "detached") • \(repository.aheadCount) ahead, \(repository.behindCount) behind")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if repository.pushability == .pushable || repository.pushability == .publish {
                Button(repository.pushability == .publish ? "Publish Branch" : "Push \(repository.aheadCount)", action: push)
                    .disabled(repository.pushability != .publish && repository.aheadCount < 1)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("repository.\(repository.path)")
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
    let preview: MSWBackupPreview
    let isBusy: Bool
    let cancel: () -> Void
    let apply: () -> Void
    @FocusState private var cancelFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create new backup")
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("backup.confirmation.title")
            LabeledContent("Destination", value: preview.destination.path(percentEncoded: false))
            Text("Includes managed code and data, VM state, databases, Docker images and volumes, guest-side credentials, and bounded diagnostics. Mac Keychain records are excluded.")
            let running = preview.runningWorkspaces
            LabeledContent("Running workspaces", value: running.isEmpty ? "None" : running.joined(separator: ", "))
            Text(running.isEmpty ? "No running workspace stop is expected." : "Running workspaces may be stopped to create a consistent archive, then restarted when the runtime can do so safely. The result will list both sets.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text("Required disk space")
                    .accessibilityIdentifier("backup.required-space.label")
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: preview.requiredBytes, countStyle: .file))
                    .accessibilityIdentifier("backup.required-space.value")
            }
            if isBusy {
                Text("Another backup or restore is already in progress. Wait for it to finish before starting this operation.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .focused($cancelFocused)
                    .accessibilityIdentifier("backup.confirmation.cancel")
                Button("Create Backup", action: apply)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isBusy)
                    .accessibilityIdentifier("backup.confirmation.create")
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
                    Text("Do not close the app or replay the operation.")
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
        case .running: return operation.fraction.map { "Running — \(Int($0 * 100))%" } ?? "Running"
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
