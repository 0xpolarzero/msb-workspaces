import AppKit
import Observation
import ServiceManagement
import SwiftUI
import UserNotifications

@MainActor
@Observable
final class ApplicationState {
    var model: AppModel?
}

enum AppTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case workspaces = "Workspaces"
    case github = "GitHub"
    case notifications = "Notifications"
    case backup = "Backup"
    case general = "General"

    var id: String { rawValue }
}

struct AppRoute: Equatable {
    let tab: AppTab
    let workspace: Workspace.ID?
    let workspaceSection: WorkspaceSection?

    init(
        tab: AppTab,
        workspace: Workspace.ID? = nil,
        workspaceSection: WorkspaceSection? = nil
    ) {
        self.tab = tab
        self.workspace = workspace
        self.workspaceSection = workspaceSection
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
        let requested = components?.queryItems?
            .first(where: { $0.name == "section" })?
            .value ?? (deepLink.host == "workspace" ? "summary" : deepLink.host ?? "overview")
        switch requested.lowercased() {
        case "github", "github-access":
            self.init(tab: .github, workspace: workspace)
        case "backup", "backups", "restore":
            self.init(tab: .backup, workspace: workspace)
        case "activity":
            self.init(tab: .workspaces, workspace: workspace, workspaceSection: .activity)
        case "overview", "summary", "metrics", "diagnostics", "maintenance":
            self.init(tab: .overview, workspace: workspace)
        case "notifications", "notification":
            self.init(tab: .notifications)
        case "general", "settings":
            self.init(tab: .general)
        default:
            self.init(
                tab: .workspaces,
                workspace: workspace,
                workspaceSection: WorkspaceSection(deepLinkValue: requested)
            )
        }
    }
}

@MainActor
@Observable
final class AppNavigationState {
    var tab: AppTab
    var workspace: Workspace.ID?
    var workspaceSection: WorkspaceSection
    var pendingPresentation = false

    init(
        tab: AppTab = .overview,
        workspace: Workspace.ID? = nil,
        workspaceSection: WorkspaceSection = .files
    ) {
        self.tab = tab
        self.workspace = workspace
        self.workspaceSection = workspaceSection
    }

    func apply(_ route: AppRoute) {
        pendingPresentation = true
        tab = route.tab
        if let workspace = route.workspace {
            self.workspace = workspace
        }
        if let workspaceSection = route.workspaceSection {
            self.workspaceSection = workspaceSection
        }
    }
}

private struct WorkspaceGrantGroup: Identifiable, Equatable {
    let workspace: String
    let entries: [WorkspaceCredentialMetadata]
    let repositoryNames: [String]

    var id: String { workspace }
}

private enum GitHubDestructiveAction: Identifiable {
    case remove(WorkspaceGrantGroup)
    case disconnect([WorkspaceGrantGroup], GitHubAccount?)

    var id: String {
        switch self {
        case .remove(let group): return "remove-\(group.workspace)"
        case .disconnect: return "disconnect"
        }
    }
}

private enum GitHubConnectionState: Equatable {
    case loading
    case notAvailable
    case readyNoAccess
    case temporaryOutage
    case recoveryRequired
    case connected
    // Local mode (Path C): policy-file driven.
    case noCredential(String?)
    case catalogFailed(String)
    case ready(account: GitHubAccount?, owners: [String], policy: GitHubPolicyFile?)
}

struct ApplicationPreferenceFields: View {
    @Bindable var applicationPreferences: ApplicationPreferenceStore
    let accessibilityPrefix: String

    var body: some View {
        Group {
            Picker("Terminal", selection: $applicationPreferences.terminalSelection) {
                Text(applicationPreferences.systemDefaultTerminalLabel).tag("")
                ForEach(applicationPreferences.catalog.terminals, id: \.bundleIdentifier) { application in
                    Text(application.displayName).tag(application.bundleIdentifier)
                }
            }
            .accessibilityIdentifier("\(accessibilityPrefix).applications.terminal.picker")
            .onAppear { applicationPreferences.refreshInstalledApplications() }


            Picker("Code editor", selection: $applicationPreferences.sourceEditorSelection) {
                Text(applicationPreferences.systemDefaultSourceEditorLabel).tag("")
                ForEach(applicationPreferences.catalog.sourceEditors, id: \.bundleIdentifier) { application in
                    Text(application.displayName).tag(application.bundleIdentifier)
                }
            }
            .accessibilityIdentifier("\(accessibilityPrefix).applications.editor.picker")


            Text("System Default follows the app macOS currently chooses. An override applies only in MSW Monitor; choosing System Default clears it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("\(accessibilityPrefix).applications.help")
        }
    }
}

struct SettingsView: View {
    @Bindable private var navigation: AppNavigationState
    @Bindable private var applicationState: ApplicationState
    @Bindable private var applicationPreferences: ApplicationPreferenceStore
    let authorizationCoordinator: GitHubAuthorizationCoordinator?
    let provider: (any GitHubProviding)?
    let accessMode: GitHubAccessMode
    let onConnect: () -> Void
    private let notificationCoordinator: NotificationCoordinator

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage("pollingCadence") private var pollingCadence = 30.0
    @AppStorage("reducedMotion") private var reducedMotion = false

    @State private var loginItemStatus: SMAppService.Status = .notRegistered
    @State private var loginItemError: String?
    @State private var metadata: [WorkspaceCredentialMetadata] = []
    @State private var connectedAccount: GitHubAccount?
    @State private var githubConnectionState: GitHubConnectionState = .loading
    @State private var githubError: String?
    @State private var isUpdatingGitHub = false
    @State private var localPolicy: GitHubPolicyFile?
    @State private var isConnectingAccount = false
    @State private var deviceFlowSession: GitHubDeviceFlowSession?
    @State private var deviceFlowShown = false
    @State private var destructiveAction: GitHubDestructiveAction?
    @State private var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    @State private var enabledNotificationCategories: Set<MSWNotificationCategory> = []
    @State private var notificationMessage: String?
    @State private var updatingNotificationCategories: Set<MSWNotificationCategory> = []

    init(
        navigation: AppNavigationState,
        applicationState: ApplicationState,
        applicationPreferences: ApplicationPreferenceStore,
        authorizationCoordinator: GitHubAuthorizationCoordinator? = nil,
        provider: (any GitHubProviding)? = nil,
        accessMode: GitHubAccessMode = .local,
        notificationCoordinator: NotificationCoordinator = .shared,
        onConnect: @escaping () -> Void = {
            NSApp.sendAction(#selector(AppDelegate.openGitHubSetup), to: nil, from: nil)
        }
    ) {
        self.navigation = navigation
        self.applicationState = applicationState
        self.applicationPreferences = applicationPreferences
        self.authorizationCoordinator = authorizationCoordinator
        self.provider = provider
        self.accessMode = accessMode
        self.notificationCoordinator = notificationCoordinator
        self.onConnect = onConnect
    }

    var body: some View {
        Group {
            if let model = applicationState.model {
                TabView(selection: $navigation.tab) {
                    DetailView(model: model, navigation: navigation, mode: .overview)
                        .tabItem {
                            Label("Overview", systemImage: "rectangle.grid.1x2")
                        }
                        .tag(AppTab.overview)

                    VStack(spacing: 0) {
                        workspaceSectionMenu
                        DetailView(model: model, navigation: navigation, mode: .workspaces)
                    }
                    .tabItem {
                        Label("Workspaces", systemImage: "square.grid.3x3")
                    }
                    .tag(AppTab.workspaces)

                    githubSettings
                        .tabItem {
                            Label("GitHub", systemImage: "person.crop.circle.badge.checkmark")
                        }
                        .tag(AppTab.github)

                    notificationSettings
                        .tabItem {
                            Label("Notifications", systemImage: "bell")
                        }
                        .tag(AppTab.notifications)

                    DetailView(model: model, navigation: navigation, mode: .backup)
                        .tabItem {
                            Label("Backup", systemImage: "externaldrive")
                        }
                        .tag(AppTab.backup)

                    generalSettings
                        .tabItem {
                            Label("General", systemImage: "gear")
                        }
                        .tag(AppTab.general)
                }
                .accessibilityIdentifier("settings.tabs")
            } else {
                ProgressView("Loading MSW Monitor…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            NSApp.sendAction(#selector(AppDelegate.closeStatusPopover), to: nil, from: nil)
            applicationState.model?.setPollingVisible(true)
            if navigation.pendingPresentation {
                navigation.pendingPresentation = false
            } else {
                navigation.tab = .general
            }
        }
        .onDisappear {
            applicationState.model?.setPollingVisible(false)
        }
        .frame(minWidth: 820, idealWidth: 900, minHeight: 600, idealHeight: 680)
        .transaction { transaction in
            if effectiveReducedMotion {
                transaction.disablesAnimations = true
            }
        }
        .sheet(item: $destructiveAction) { action in
            GitHubImpactConfirmation(action: action, accessMode: accessMode) {
                destructiveAction = nil
            } onConfirm: {
                destructiveAction = nil
                switch action {
                case .remove(let group): removeWorkspace(group.workspace)
                case .disconnect: disconnectAccount()
                }
            }
        }
        .sheet(isPresented: $deviceFlowShown) {
            if let session = deviceFlowSession {
                GitHubDeviceFlowView(
                    session: session,
                    onComplete: { _ in
                        deviceFlowShown = false
                        deviceFlowSession = nil
                        Task { await loadGitHubState() }
                    },
                    onCancel: {
                        deviceFlowShown = false
                        deviceFlowSession = nil
                    }
                )
            }
        }
    }

    private var workspaceSectionMenu: some View {
        HStack(spacing: 8) {
            ForEach(WorkspaceSection.allCases) { section in
                let isSelected = navigation.workspaceSection == section
                Button {
                    navigation.workspaceSection = section
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: section.symbol)
                            .font(.body)
                        Text(section.rawValue)
                            .font(.caption)
                    }
                    .frame(width: 82, height: 42)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .help(section.rawValue)
                .accessibilityIdentifier("workspace.section.\(section.rawValue)")
                .accessibilityValue(isSelected ? "Selected" : "Not selected")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 2)
    }

    private var generalSettings: some View {
        Form {
            Section("Startup") {
                Toggle(
                    "Launch MSW Monitor at login",
                    isOn: Binding(
                        get: { loginItemStatus == .enabled },
                        set: { setLaunchAtLogin($0) }
                    )
                )
                if let loginItemError {
                    recoveryMessage(loginItemError)
                    Button("Retry login item update") {
                        setLaunchAtLogin(loginItemStatus != .enabled)
                    }
                }
                if loginItemStatus == .requiresApproval {
                    Button("Open Login Items Settings", action: openLoginItemsSettings)
                } else if loginItemStatus == .notFound {
                    Button("Retry status check", action: refreshLoginItemStatus)
                }
                Text("Launching at login observes MSW state. It never starts a workspace.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Observation") {
                Picker("Polling cadence", selection: $pollingCadence) {
                    Text("15 seconds").tag(15.0)
                    Text("30 seconds").tag(30.0)
                    Text("60 seconds").tag(60.0)
                }
            }

            Section("Applications") {
                ApplicationPreferenceFields(
                    applicationPreferences: applicationPreferences,
                    accessibilityPrefix: "settings"
                )
            }

            Section("Accessibility") {
                Toggle("Reduce motion in Settings", isOn: $reducedMotion)
                Text("The macOS Reduce Motion setting always takes precedence.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { refreshLoginItemStatus() }
    }


    private var githubSettings: some View {
        Form {
            if accessMode == .local {
                localGitHubAccountSection
                localGitHubAccessSection
            } else {
                Section("Account") {
                    if let connectedAccount {
                        Label("Connected as @\(connectedAccount.login)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .accessibilityLabel("Connected as @\(connectedAccount.login)")
                            .accessibilityIdentifier("settings.github.status")
                    } else {
                        LabeledContent("Status", value: githubStatusText)
                            .accessibilityIdentifier("settings.github.status")
                    }
                    githubPrimaryAction
                    Button("Remove all GitHub access…", role: .destructive) {
                        destructiveAction = .disconnect(groupedMetadata, connectedAccount)
                    }
                    .disabled(
                        !githubFeatureAvailable ||
                            (metadata.isEmpty && connectedAccount == nil) ||
                            isUpdatingGitHub
                    )
                    if let githubError {
                        recoveryMessage(githubError)
                        Button("Retry GitHub status") {
                            Task { await loadGitHubState() }
                        }
                    }
                }

                Section("Repository access") {
                    if groupedMetadata.isEmpty {
                        ContentUnavailableView(
                            "No workspace access",
                            systemImage: "lock.shield",
                            description: Text(
                                githubFeatureAvailable
                                    ? "Connect GitHub to review repository access for each workspace."
                                    : GitHubFeatureAvailability.unavailableNotice
                            )
                        )
                    } else {
                        ForEach(groupedMetadata) { group in
                            workspaceGrantRow(group)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await loadGitHubState() }
        .onReceive(NotificationCenter.default.publisher(for: .githubPolicyDidChange)) { _ in
            Task { await loadGitHubState() }
        }
    }

    private var localGitHubAccountSection: some View {
        Section("Account") {
            switch githubConnectionState {
            case .loading:
                LabeledContent("Status", value: githubStatusText)
                    .accessibilityIdentifier("settings.github.status")
            case .ready(let account, _, _):
                if let account {
                    Label("Connected as @\(account.login)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel("Connected as @\(account.login)")
                        .accessibilityIdentifier("settings.github.status")
                } else {
                    LabeledContent("Status", value: githubStatusText)
                        .accessibilityIdentifier("settings.github.status")
                }
            case .noCredential:
                LabeledContent("Status", value: githubStatusText)
                    .accessibilityIdentifier("settings.github.status")
            case .catalogFailed:
                LabeledContent("Status", value: githubStatusText)
                    .accessibilityIdentifier("settings.github.status")
            default:
                LabeledContent("Status", value: githubStatusText)
                    .accessibilityIdentifier("settings.github.status")
            }
            localGitHubPrimaryAction
            Button("Remove all GitHub access…", role: .destructive) {
                destructiveAction = .disconnect([], connectedAccount)
            }
            .disabled(!githubFeatureAvailable || isUpdatingGitHub)
            if let githubError {
                recoveryMessage(githubError)
                Button("Retry GitHub status") {
                    Task { await loadGitHubState() }
                }
            }
        }
    }

    @ViewBuilder
    private var localGitHubPrimaryAction: some View {
        switch githubConnectionState {
        case .loading:
            ProgressView("Loading GitHub status…")
        case .noCredential:
            Button("Connect GitHub account on this Mac…", action: connectGitHubAccount)
                .buttonStyle(.borderedProminent)
                .disabled(isUpdatingGitHub || isConnectingAccount)
                .accessibilityIdentifier("settings.github.connect.button")
        case .catalogFailed:
            Button("Retry") {
                Task { await loadGitHubState() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isUpdatingGitHub)
            .accessibilityIdentifier("settings.github.retry.button")
        case .ready:
            Button("Choose repository access…", action: onConnect)
                .buttonStyle(.borderedProminent)
                .disabled(isUpdatingGitHub)
                .accessibilityIdentifier("settings.github.setup.button")
        default:
            EmptyView()
        }
    }

    private var localGitHubAccessSection: some View {
        Section("Repository access") {
            let workspaceNames = localPolicy.map { Array($0.workspaces.keys) } ?? []
            let workspaces = workspaceNames.sorted().compactMap(Workspace.ID.init(rawValue:))
            if workspaces.isEmpty {
                ContentUnavailableView(
                    "No repository access",
                    systemImage: "lock.shield",
                    description: Text("Choose repository access for each workspace here.")
                )
            } else {
                ForEach(workspaces, id: \.rawValue) { workspace in
                    localWorkspaceAccessRow(workspace)
                }
            }
        }
    }

    private func localWorkspaceAccessRow(_ workspace: Workspace.ID) -> some View {
        let repos = localPolicy?.workspaces[workspace.rawValue]?.repos ?? []
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(workspace.rawValue).font(.body.weight(.semibold))
                Spacer()
                Text(repos.isEmpty ? "No access" : "\(repos.count) repositor\(repos.count == 1 ? "y" : "ies")")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            if repos.isEmpty {
                Text("No repositories are assigned to this workspace.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(repos.map { "\($0.canonical) — \($0.mode.label)" }.joined(separator: "\n"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack {
                Button("Edit \(workspace.rawValue)", action: onConnect)
                    .disabled(isUpdatingGitHub)
                Button("Remove \(workspace.rawValue) access…", role: .destructive) {
                    destructiveAction = .remove(WorkspaceGrantGroup(
                        workspace: workspace.rawValue,
                        entries: [],
                        repositoryNames: repos.map(\.canonical)
                    ))
                }
                .disabled(isUpdatingGitHub)
            }
        }
        .padding(.vertical, 4)
    }

    private var notificationSettings: some View {
        Form {
            Section("Permission") {
                LabeledContent("System authorization", value: notificationAuthorizationText)
                Text("Notifications stay off until you enable a category. The system permission prompt appears only after that deliberate choice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if notificationAuthorizationStatus == .denied {
                    Button("Open Notification Settings", action: openNotificationSettings)
                }
                Button("Retry permission check") {
                    Task { await loadNotificationState() }
                }
            }

            Section("Alert categories") {
                ForEach(MSWNotificationCategory.allCases) { category in
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(
                            category.title,
                            isOn: Binding(
                                get: { enabledNotificationCategories.contains(category) },
                                set: { updateNotificationCategory(category, enabled: $0) }
                            )
                        )
                        .disabled(updatingNotificationCategories.contains(category))
                        Text(category.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let notificationFailureMessage = notificationCoordinator.notificationFailureMessage {
                    recoveryMessage(notificationFailureMessage)
                    Button("Retry failed notification") {
                        Task { await notificationCoordinator.retryFailedNotifications() }
                    }
                    Button("Dismiss notification failure") {
                        notificationCoordinator.clearPermanentFailures()
                    }
                }
            }

            Section("Privacy and routing") {
                Text("Alerts identify only the affected workspace and recovery destination. Repository content, account names, tokens, and command output are excluded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await loadNotificationState() }
    }



    @ViewBuilder
    private var githubPrimaryAction: some View {
        switch githubConnectionState {
        case .loading:
            ProgressView("Loading GitHub status…")
        case .notAvailable:
            Label(GitHubFeatureAvailability.unavailableNotice, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("settings.github.unavailable")
        case .readyNoAccess:
            Button("Connect GitHub", action: onConnect)
                .buttonStyle(.borderedProminent)
                .disabled(isUpdatingGitHub)
                .accessibilityIdentifier("settings.github.connect.button")
        case .temporaryOutage:
            Button("Retry", action: retryTemporaryOutages)
            .buttonStyle(.borderedProminent)
            .disabled(isUpdatingGitHub)
            .accessibilityIdentifier("settings.github.retry.button")
        case .recoveryRequired:
            Text("Use the workspace-specific Reconnect action below.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .connected:
            Button("Edit repository access", action: onConnect)
                .disabled(isUpdatingGitHub)
                .accessibilityIdentifier("settings.github.connect.button")
        case .noCredential, .catalogFailed, .ready:
            // Local-mode states render through localGitHubPrimaryAction.
            EmptyView()
        }
    }

    private func workspaceGrantRow(_ group: WorkspaceGrantGroup) -> some View {
        let presentation = GitHubWorkspaceAccessPresentation.make(
            workspace: group.workspace,
            entries: group.entries
        )
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(group.workspace).font(.body.weight(.semibold))
                Spacer()
                Text(presentation.status)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(presentation.action == .edit ? Color.secondary : Color.orange)
            }
            LabeledContent("Repositories", value: repositorySummary(for: group))
                .font(.caption)
            Text(presentation.reason)
                .font(.caption)
                .foregroundStyle(presentation.action == .edit ? Color.secondary : Color.orange)
            HStack {
                if githubFeatureAvailable {
                    switch presentation.action {
                    case .edit:
                        Button("Edit \(group.workspace)", action: onConnect)
                            .disabled(isUpdatingGitHub)
                    case .retry:
                        Button("Retry") { retryWorkspace(group.workspace) }
                            .disabled(isUpdatingGitHub)
                            .accessibilityIdentifier("settings.github.\(group.workspace).retry.button")
                    case .reconnect:
                        Button("Reconnect \(group.workspace)", action: onConnect)
                            .disabled(isUpdatingGitHub)
                            .accessibilityIdentifier("settings.github.\(group.workspace).reconnect.button")
                    }
                }
                Button("Remove \(group.workspace) access…", role: .destructive) {
                    destructiveAction = .remove(group)
                }
                .disabled(!githubFeatureAvailable || isUpdatingGitHub)
            }
            if !githubFeatureAvailable {
                Text("This build cannot prove remote revocation or removal. The retained grant stays quarantined and no removal is claimed.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }

    private func recoveryMessage(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
            .textSelection(.enabled)
    }

    private var groupedMetadata: [WorkspaceGrantGroup] {
        Dictionary(grouping: metadata, by: \.workspace)
            .map { workspace, entries in
                WorkspaceGrantGroup(
                    workspace: workspace,
                    entries: entries,
                    repositoryNames: Array(Set(entries.flatMap { $0.repositoryNames })).sorted()
                )
            }
            .sorted { $0.workspace < $1.workspace }
    }

    private var effectiveReducedMotion: Bool {
        reducedMotion || systemReduceMotion
    }


    private var githubStatusText: String {
        switch githubConnectionState {
        case .loading: return "Loading…"
        case .notAvailable: return "Not available in this build"
        case .readyNoAccess: return "Ready to connect · no workspace access"
        case .temporaryOutage: return "Service unavailable · retry without reconnecting"
        case .recoveryRequired: return "Workspace access needs reconnecting"
        case .connected: return "Connected · \(groupedMetadata.count) workspace\(groupedMetadata.count == 1 ? "" : "s")"
        case .noCredential: return GitHubLocalStrings.settingsNoCredential
        case .catalogFailed: return "GitHub repositories could not be loaded"
        case .ready(let account, let owners, _):
            if let account { return "Connected as @\(account.login)" }
            return owners.isEmpty ? "Connected · no repository access" : "Connected · \(owners.count) owner\(owners.count == 1 ? "" : "s")"
        }
    }

    private var notificationAuthorizationText: String {
        switch notificationAuthorizationStatus {
        case .notDetermined: return "Not requested"
        case .denied: return "Denied in System Settings"
        case .authorized: return "Allowed"
        case .provisional: return "Allowed provisionally"
        case .ephemeral: return "Allowed for this session"
        @unknown default: return "Unavailable — retry"
        }
    }

    private var githubFeatureAvailable: Bool {
        if accessMode == .local { return provider?.isAvailable == true }
        return authorizationCoordinator?.isAvailable == true
    }


    private func repositorySummary(for group: WorkspaceGrantGroup) -> String {
        let writable = Set(group.entries.filter { $0.role == .host }.flatMap(\.repositoryNames))
        let values = group.repositoryNames.map { repository in
            "\(repository) — \(writable.contains(repository) ? GitHubRepositoryAccessMode.readWrite.label : GitHubRepositoryAccessMode.readOnly.label)"
        }
        return values.isEmpty ? "None recorded" : values.joined(separator: ", ")
    }

    private func refreshLoginItemStatus() {
        loginItemStatus = SMAppService.mainApp.status
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
            refreshLoginItemStatus()
        } catch {
            loginItemError = "The login item update was denied or unavailable: \(error.localizedDescription)"
            refreshLoginItemStatus()
        }
    }

    private func loadGitHubState() async {
        githubError = nil
        if accessMode == .local {
            guard let provider else {
                githubConnectionState = .catalogFailed("GitHub local access is unavailable in this build.")
                localPolicy = nil
                return
            }
            githubConnectionState = .loading
            do {
                let catalog = try await provider.loadCatalog()
                let policy = await provider.currentPolicy()
                connectedAccount = catalog.account
                localPolicy = policy
                if catalog.hostCredentialPresent {
                    githubConnectionState = .ready(
                        account: catalog.account,
                        owners: Set(catalog.installations.map(\.account.login)).sorted(),
                        policy: policy
                    )
                } else {
                    githubConnectionState = .noCredential(GitHubLocalStrings.settingsNoCredential)
                }
            } catch {
                connectedAccount = nil
                githubConnectionState = .catalogFailed(error.localizedDescription)
            }
            return
        }
        guard let authorizationCoordinator else {
            githubConnectionState = .notAvailable
            return
        }
        githubConnectionState = .loading
        guard authorizationCoordinator.isAvailable else {
            connectedAccount = nil
            metadata = await authorizationCoordinator.retainedMetadata()
            githubConnectionState = .notAvailable
            return
        }
        let refreshedMetadata = await authorizationCoordinator.metadata()
        let account = await authorizationCoordinator.connectedAccount()
        connectedAccount = account
        metadata = refreshedMetadata

        let presentations = Dictionary(grouping: refreshedMetadata, by: \.workspace).map {
            GitHubWorkspaceAccessPresentation.make(workspace: $0.key, entries: $0.value)
        }
        if refreshedMetadata.isEmpty {
            githubConnectionState = .readyNoAccess
        } else if presentations.contains(where: { $0.action == .reconnect }) {
            githubConnectionState = .recoveryRequired
        } else if presentations.contains(where: { $0.action == .retry }) {
            githubConnectionState = .temporaryOutage
        } else {
            githubConnectionState = .connected
        }
    }

    private func retryWorkspace(_ workspace: String) {
        guard let authorizationCoordinator else { return }
        isUpdatingGitHub = true
        githubError = nil
        Task {
            do {
                try await authorizationCoordinator.retryUnavailableWorkspace(workspace)
            } catch {
                githubError = "Retry for \(workspace) did not succeed: \(error.localizedDescription)"
            }
            isUpdatingGitHub = false
            await loadGitHubStatePreservingError()
        }
    }

    private func retryTemporaryOutages() {
        guard let authorizationCoordinator else { return }
        let workspaces = Set(metadata.compactMap { entry in
            !entry.quarantined &&
                (entry.recoveryState == .serviceUnavailable || entry.recoveryState == .expired)
                ? entry.workspace
                : nil
        })
        isUpdatingGitHub = true
        githubError = nil
        Task {
            for workspace in workspaces.sorted() {
                do {
                    try await authorizationCoordinator.retryUnavailableWorkspace(workspace)
                } catch {
                    githubError = "Retry for \(workspace) did not succeed: \(error.localizedDescription)"
                    break
                }
            }
            isUpdatingGitHub = false
            await loadGitHubStatePreservingError()
        }
    }

    private func removeWorkspace(_ workspace: String) {
        if accessMode == .local {
            guard let provider else {
                githubError = "GitHub local access is unavailable in this build."
                return
            }
            isUpdatingGitHub = true
            githubError = nil
            Task {
                do {
                    // An empty repository list clears the workspace's access
                    // through the journaled CLI.
                    try await provider.commit([GitHubWorkspacePolicy(workspace: workspace, repositories: [])])
                    isUpdatingGitHub = false
                    await loadGitHubState()
                } catch {
                    isUpdatingGitHub = false
                    githubError = "Removal could not be applied. \(workspace) access remains unchanged: \(error.localizedDescription)"
                    await loadGitHubStatePreservingError()
                }
            }
            return
        }
        guard let authorizationCoordinator else { return }
        isUpdatingGitHub = true
        githubError = nil
        Task {
            do {
                try await authorizationCoordinator.removeWorkspace(workspace)
                isUpdatingGitHub = false
                await loadGitHubState()
            } catch {
                isUpdatingGitHub = false
                githubError = "Removal could not be verified. \(workspace) remains visible and may be quarantined. Retry or reconnect: \(error.localizedDescription)"
                await loadGitHubStatePreservingError()
            }
        }
    }

    private func disconnectAccount() {
        if accessMode == .local {
            guard let provider else {
                githubError = "GitHub local access is unavailable in this build."
                return
            }
            isUpdatingGitHub = true
            githubError = nil
            Task {
                do {
                    try await provider.removeAllAccess()
                    isUpdatingGitHub = false
                    localPolicy = await provider.currentPolicy()
                    connectedAccount = nil
                    githubConnectionState = .ready(account: nil, owners: [], policy: localPolicy)
                } catch {
                    isUpdatingGitHub = false
                    githubError = "Removal could not be applied. Repository access remains unchanged: \(error.localizedDescription)"
                    await loadGitHubStatePreservingError()
                }
            }
            return
        }
        guard let authorizationCoordinator else { return }
        isUpdatingGitHub = true
        githubError = nil
        Task {
            do {
                try await authorizationCoordinator.disconnectAccount()
                isUpdatingGitHub = false
                metadata = []
                connectedAccount = nil
                githubConnectionState = .readyNoAccess
            } catch {
                isUpdatingGitHub = false
                githubError = "Removal could not be verified. Affected grants remain visible and may be quarantined. Retry or reconnect: \(error.localizedDescription)"
                await loadGitHubStatePreservingError()
            }
        }
    }

    private func loadGitHubStatePreservingError() async {
        let message = githubError
        await loadGitHubState()
        githubError = message
    }

    /// Runs the CLI-owned host-credential flow. gh reuse completes
    /// in-process; when the CLI routes to the OAuth Device Flow the app
    /// presents the in-app device sheet (typed not-configured remedies are
    /// Runs the CLI-owned host-credential flow. gh reuse completes
    /// in-process. When the CLI reports gh is unauthenticated with no
    /// device-flow client ID (MSW_HOST_OAUTH_NOT_CONFIGURED) the app
    /// launches the installed gh web OAuth flow and then retries auth; when
    /// the CLI reports the Device Flow is available
    /// (MSW_HOST_DEVICE_FLOW_INTERACTIVE_REQUIRED) the app presents the
    /// in-app device sheet. Other typed remedies surface verbatim.
    private func connectGitHubAccount() {
        guard let provider, !isConnectingAccount else { return }
        isConnectingAccount = true
        githubError = nil
        Task {
            do {
                let account = try await provider.connectAccount()
                isConnectingAccount = false
                connectedAccount = account
                await loadGitHubStatePreservingError()
            } catch GitHubCatalogError.ghWebLoginRequired {
                await launchGhWebLoginAndRetry()
            } catch GitHubCatalogError.deviceFlowAvailable {
                let session = GitHubDeviceFlowSession(
                    startDeviceFlow: { try await provider.startDeviceFlow() },
                    pollDeviceFlow: { deviceId in try await provider.pollDeviceFlow(deviceId: deviceId) }
                )
                isConnectingAccount = false
                deviceFlowSession = session
                deviceFlowShown = true
            } catch {
                isConnectingAccount = false
                githubError = error.localizedDescription
                await loadGitHubStatePreservingError()
            }
        }
    }

    /// Launches the installed gh web OAuth flow (`gh auth login --web`),
    /// surfaces the waiting state, and retries the host-credential
    /// acquisition once gh reports the browser sign-in completed.
    private func launchGhWebLoginAndRetry() async {
        guard let provider else {
            isConnectingAccount = false
            return
        }
        do {
            try await provider.launchGhWebLogin()
            let account = try await provider.connectAccount()
            isConnectingAccount = false
            connectedAccount = account
            await loadGitHubStatePreservingError()
        } catch GitHubCatalogError.ghWebLoginRequired {
            isConnectingAccount = false
            githubError = "GitHub sign-in did not complete. Retry when ready."
            await loadGitHubStatePreservingError()
        } catch {
            isConnectingAccount = false
            githubError = error.localizedDescription
            await loadGitHubStatePreservingError()
        }
    }

    private func loadNotificationState() async {
        notificationAuthorizationStatus = await notificationCoordinator.authorizationStatus()
        enabledNotificationCategories = notificationCoordinator.enabledCategories()
        if (notificationAuthorizationStatus == .denied || notificationAuthorizationStatus == .notDetermined),
           !enabledNotificationCategories.isEmpty {
            enabledNotificationCategories = []
            for category in MSWNotificationCategory.allCases {
                _ = await notificationCoordinator.setEnabled(false, for: category)
            }
        }
    }

    private func updateNotificationCategory(_ category: MSWNotificationCategory, enabled: Bool) {
        updatingNotificationCategories.insert(category)
        notificationMessage = nil
        Task {
            let resultingValue = await notificationCoordinator.setEnabled(enabled, for: category)
            if resultingValue {
                enabledNotificationCategories.insert(category)
            } else {
                enabledNotificationCategories.remove(category)
                if enabled {
                    notificationMessage = "Notification permission was denied or is unavailable. Open Notification Settings, allow MSW Monitor, then retry."
                }
            }
            notificationAuthorizationStatus = await notificationCoordinator.authorizationStatus()
            updatingNotificationCategories.remove(category)
        }
    }

    private func openLoginItemsSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings") else { return }
        NSWorkspace.shared.open(url)
    }

    private func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct GitHubImpactConfirmation: View {
    let action: GitHubDestructiveAction
    let accessMode: GitHubAccessMode
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @State private var confirmation = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.red)

            Text(introduction)
            impactList

            GroupBox("Access impact") {
                VStack(alignment: .leading, spacing: 7) {
                    if accessMode == .local {
                        Text("• The workspace's repositories are removed from the local GitHub policy.")
                        Text("• Workspace files and repositories are not deleted. Access can be restored later by adding the repository again.")
                    } else {
                        Text("• GitHub access is removed for the affected workspace.")
                        Text("• If removal cannot be verified, access remains visible for retry.")
                        Text("• Workspace files and repositories are not deleted. Access can be restored later by reconnecting and reviewing scope again.")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .font(.caption)
            }

            Text("Type **\(requiredPhrase)** exactly to continue.")
            TextField(requiredPhrase, text: $confirmation)
                .accessibilityLabel("Confirmation phrase. Type \(requiredPhrase) exactly")

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(confirmButtonTitle, role: .destructive, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(confirmation != requiredPhrase)
            }
        }
        .padding(24)
        .frame(width: 570)
    }

    private var title: String {
        switch action {
        case .remove(let group): return "Remove GitHub access from \(group.workspace)?"
        case .disconnect: return "Remove all GitHub access?"
        }
    }

    private var introduction: String {
        switch action {
        case .remove:
            if accessMode == .local {
                return "This removes the workspace's repositories from the local GitHub policy."
            }
            return "Review this workspace-specific access change before it is applied."
        case .disconnect(_, let account):
            if accessMode == .local {
                return "This clears every workspace's repository list from the local GitHub policy."
            }
            return account.map { "This removes every listed workspace grant associated with @\($0.login)." }
                ?? "This removes every listed workspace grant associated with the current account."
        }
    }

    @ViewBuilder
    private var impactList: some View {
        switch action {
        case .remove(let group):
            grantImpact(group)
        case .disconnect(let groups, _):
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(groups) { group in
                        grantImpact(group)
                    }
                }
            }
            .frame(maxHeight: 180)
        }
    }

    private func grantImpact(_ group: WorkspaceGrantGroup) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(group.workspace).font(.body.weight(.semibold))
            Text("Repositories: \(group.repositoryNames.isEmpty ? "None recorded" : group.repositoryNames.joined(separator: ", "))")
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var requiredPhrase: String {
        switch action {
        case .remove(let group): return group.workspace
        case .disconnect: return "REMOVE"
        }
    }

    private var confirmButtonTitle: String {
        switch action {
        case .remove: return "Remove Workspace Access"
        case .disconnect: return "Remove All Access"
        }
    }
}
