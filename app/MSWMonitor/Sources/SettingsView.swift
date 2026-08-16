import AppKit
import Observation
import ServiceManagement
import SwiftUI
import UserNotifications

@MainActor
@Observable
final class SettingsNavigationState {
    var section: SettingsSection

    init(section: SettingsSection = .general) {
        self.section = section
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case workspaces = "Workspaces"
    case github = "GitHub"
    case notifications = "Notifications"
    case backup = "Backup"
    case about = "About"

    var id: String { rawValue }

    init(deepLinkValue: String) {
        switch deepLinkValue.lowercased() {
        case "workspaces", "workspace": self = .workspaces
        case "github", "github-access": self = .github
        case "notifications", "notification": self = .notifications
        case "backup", "backups": self = .backup
        case "about": self = .about
        default: self = .general
        }
    }
}

private struct WorkspaceGrantGroup: Identifiable, Equatable {
    let workspace: String
    let entries: [WorkspaceCredentialMetadata]
    let owner: String?
    let repositoryNames: [String]
    let accessModes: [String]
    let verifiedAt: Date?

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

private enum GitHubConnectionState {
    case loading
    case unavailable
    case signedOut
    case sessionExpired
    case connected
}

struct SettingsView: View {
    @Bindable private var navigation: SettingsNavigationState
    let authorizationCoordinator: GitHubAuthorizationCoordinator?
    let deviceFlow: GitHubDeviceFlow?
    let githubInstallationURL: URL?
    let onConnect: () -> Void
    private let notificationCoordinator: NotificationCoordinator

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage("pollingCadence") private var pollingCadence = 30.0
    @AppStorage("reducedMotion") private var reducedMotion = false
    @AppStorage("backupDestination") private var backupDestination = ""

    @State private var loginItemStatus: SMAppService.Status = .notRegistered
    @State private var loginItemError: String?
    @State private var metadata: [WorkspaceCredentialMetadata] = []
    @State private var connectedAccount: GitHubAccount?
    @State private var githubConnectionState: GitHubConnectionState = .loading
    @State private var githubError: String?
    @State private var isUpdatingGitHub = false
    @State private var destructiveAction: GitHubDestructiveAction?
    @State private var deviceAccount: GitHubAccount?
    @State private var deviceRepositories: [GitHubRepository] = []
    @State private var deviceAllowlists: [String: Set<String>] = [:]
    @State private var deviceAccessLoaded = false
    @State private var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    @State private var enabledNotificationCategories: Set<MSWNotificationCategory> = []
    @State private var notificationMessage: String?
    @State private var updatingNotificationCategories: Set<MSWNotificationCategory> = []

    init(
        navigation: SettingsNavigationState,
        authorizationCoordinator: GitHubAuthorizationCoordinator? = nil,
        deviceFlow: GitHubDeviceFlow? = nil,
        githubInstallationURL: URL? = nil,
        notificationCoordinator: NotificationCoordinator = .shared,
        onConnect: @escaping () -> Void = {
            NSApp.sendAction(#selector(AppDelegate.openGitHubSetup), to: nil, from: nil)
        }
    ) {
        self.navigation = navigation
        self.authorizationCoordinator = authorizationCoordinator
        self.deviceFlow = deviceFlow
        self.githubInstallationURL = githubInstallationURL
        self.notificationCoordinator = notificationCoordinator
        self.onConnect = onConnect
        if ProcessInfo.processInfo.arguments.contains("--ui-test-device-access") {
            _deviceAccount = State(initialValue: GitHubAccount(login: "octocat", id: 1, name: "Octo Cat", email: nil))
            _deviceRepositories = State(initialValue: [
                GitHubRepository(
                    id: 1001,
                    fullName: "acme/one",
                    name: "one",
                    owner: GitHubInstallationAccount(login: "acme", id: 7, type: "Organization"),
                    private: true,
                    defaultBranch: "main"
                )
            ])
            _deviceAllowlists = State(initialValue: ["dev": ["acme/one"]])
            _deviceAccessLoaded = State(initialValue: true)
        }
    }

    var body: some View {
        TabView(selection: $navigation.section) {
            generalSettings
                .tabItem { Label("General", systemImage: "gear") }
                .tag(SettingsSection.general)

            workspaceSettings
                .tabItem { Label("Workspaces", systemImage: "square.grid.3x3") }
                .tag(SettingsSection.workspaces)

            githubSettings
                .tabItem { Label("GitHub", systemImage: "person.crop.circle.badge.checkmark") }
                .tag(SettingsSection.github)

            notificationSettings
                .tabItem { Label("Notifications", systemImage: "bell") }
                .tag(SettingsSection.notifications)

            backupSettings
                .tabItem { Label("Backup", systemImage: "externaldrive") }
                .tag(SettingsSection.backup)

            aboutSettings
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsSection.about)
        }
        .accessibilityIdentifier("settings.tabs")
        .frame(minWidth: 680, idealWidth: 700, minHeight: 560, idealHeight: 620)
        .transaction { transaction in
            if effectiveReducedMotion {
                transaction.disablesAnimations = true
            }
        }
        .task { await loadDeviceAccess() }
        .sheet(item: $destructiveAction) { action in
            GitHubImpactConfirmation(action: action) {
                destructiveAction = nil
            } onConfirm: {
                destructiveAction = nil
                switch action {
                case .remove(let group): removeWorkspace(group.workspace)
                case .disconnect: disconnectAccount()
                }
            }
        }
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
                LabeledContent("Current value", value: loginItemStatusText)
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
                LabeledContent("Current value", value: "Every \(Int(pollingCadence)) seconds")
            }

            Section("Accessibility") {
                Toggle("Reduce motion in Settings", isOn: $reducedMotion)
                LabeledContent("Current value", value: reducedMotionStatus)
                Text("The macOS Reduce Motion setting always takes precedence.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { refreshLoginItemStatus() }
    }

    private var workspaceSettings: some View {
        Form {
            Section("Configuration") {
                LabeledContent("Source", value: "MSW typed configuration")
                LabeledContent("Managed values", value: "Resources, links, and Git identity")
                Text("Workspace changes are reviewed and applied through MSW. Settings never displays credential values.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var githubSettings: some View {
        Form {
            Section("Account") {
                LabeledContent("Status", value: githubStatusText)
                    .accessibilityIdentifier("settings.github.status")
                if let connectedAccount {
                    LabeledContent("Account", value: "@\(connectedAccount.login)")
                }
                githubPrimaryAction
                if let githubError {
                    recoveryMessage(githubError)
                    Button("Retry GitHub status") {
                        Task { await loadGitHubState() }
                    }
                }
            }

            Section("Workspace access") {
                deviceWorkspaceAccessContent
            }

            Section("Workspace grants") {
                if groupedMetadata.isEmpty {
                    ContentUnavailableView(
                        "No workspace grants",
                        systemImage: "lock.shield",
                        description: Text("Sign in to GitHub, then review repository access for each workspace.")
                    )
                } else {
                    ForEach(groupedMetadata) { group in
                        workspaceGrantRow(group)
                    }
                }
            }

            Section("Credential safety") {
                Text("Tokens, private keys, authorization codes, and service sessions are never displayed or copied here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Disconnect GitHub…", role: .destructive) {
                    destructiveAction = .disconnect(groupedMetadata, connectedAccount)
                }
                .disabled((metadata.isEmpty && connectedAccount == nil) || isUpdatingGitHub)
            }
        }
        .formStyle(.grouped)
        .task { await loadGitHubState() }
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

    private var backupSettings: some View {
        Form {
            Section("Archive destination") {
                TextField("Backup destination", text: $backupDestination)
                    .textContentType(.URL)
                LabeledContent(
                    "Current value",
                    value: backupDestination.isEmpty ? "Choose for each backup" : backupDestination
                )
                Text("Backup archives exclude Keychain records and contain sensitive workspace data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var aboutSettings: some View {
        Form {
            Section("MSW Monitor") {
                LabeledContent("App", value: "Native macOS workspace monitor")
                LabeledContent("Integration", value: "Typed MSW protocol")
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var deviceWorkspaceAccessContent: some View {
        if let deviceAccount {
            LabeledContent("Account", value: "@\(deviceAccount.login)")
                .accessibilityIdentifier("settings.github.account")
            if deviceRepositories.isEmpty {
                Text("No repositories are selected on GitHub yet. Open the App installation page, pick repositories, then check again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                WorkspaceGitHubAccessEditor(
                    repositories: deviceRepositories,
                    allowlists: deviceAllowlists,
                    onToggle: setDeviceWorkspaceAllowlist
                )
                .accessibilityIdentifier("settings.github.workspace-access")
            }
            HStack {
                if let url = githubInstallationURL {
                    Button("Manage repositories on GitHub") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Check again") {
                    Task { await loadDeviceAccess() }
                }
            }
        } else {
            Text("Connect GitHub from the setup window or Settings → Connect to manage workspace access.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func setDeviceWorkspaceAllowlist(workspace: String, repository: String, allowed: Bool) {
        var current = deviceAllowlists[workspace] ?? []
        if allowed {
            current.insert(repository)
        } else {
            current.remove(repository)
        }
        deviceAllowlists[workspace] = current
        let access = WorkspaceGitHubAccess(
            repositoriesByWorkspace: deviceAllowlists.mapValues { Array($0).sorted() }
        )
        try? WorkspaceGitHubAccessStore().save(access)
    }

    private func loadDeviceAccess() async {
        if ProcessInfo.processInfo.arguments.contains("--ui-test-device-access") {
            return
        }
        guard let deviceFlow else { return }
        do {
            let store = GitHubDeviceSessionStore()
            guard var session = try store.load() else {
                deviceAccessLoaded = true
                return
            }
            if session.isAccessExpired, session.canRefresh, let refreshToken = session.refreshToken {
                let token = try await deviceFlow.refreshToken(clientID: session.clientID, refreshToken: refreshToken)
                session = GitHubDeviceSession(
                    schemaVersion: 1,
                    clientID: session.clientID,
                    account: session.account,
                    accessToken: token.accessToken,
                    refreshToken: token.refreshToken ?? session.refreshToken,
                    accessExpiresAt: token.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) },
                    refreshExpiresAt: token.refreshExpiresIn.map { Date().addingTimeInterval(TimeInterval($0)) } ?? session.refreshExpiresAt,
                    obtainedAt: Date()
                )
                try store.save(session)
            }
            var accessibleRepositories: [GitHubRepository] = []
            let installations = try await deviceFlow.installations(accessToken: session.accessToken)
            for installation in installations {
                let repositories = try await deviceFlow.repositories(
                    accessToken: session.accessToken,
                    installationID: installation.id
                )
                accessibleRepositories.append(contentsOf: repositories)
            }
            let accessibleNames = Set(accessibleRepositories.map(\.fullName))
            let accessStore = WorkspaceGitHubAccessStore()
            if let stored = accessStore.load() {
                let pruned = stored.pruned(toAccessibleNames: accessibleNames)
                if pruned.repositoriesByWorkspace != stored.repositoriesByWorkspace {
                    try accessStore.save(pruned)
                }
                deviceAllowlists = pruned.repositoriesByWorkspace.mapValues(Set.init)
            } else {
                deviceAllowlists = [:]
            }
            deviceAccount = session.account
            deviceRepositories = accessibleRepositories
            deviceAccessLoaded = true
        } catch {
            deviceAccessLoaded = true
        }
    }

    @ViewBuilder
    private var githubPrimaryAction: some View {
        switch githubConnectionState {
        case .loading:
            ProgressView("Loading GitHub status…")
        case .unavailable:
            Button("Retry GitHub status") {
                Task { await loadGitHubState() }
            }
        case .signedOut:
            Button("Sign in to GitHub", action: onConnect)
                .buttonStyle(.borderedProminent)
                .disabled(isUpdatingGitHub)
                .accessibilityIdentifier("settings.github.connect.button")
        case .sessionExpired:
            Button("Sign in again", action: onConnect)
                .buttonStyle(.borderedProminent)
                .disabled(isUpdatingGitHub)
                .accessibilityIdentifier("settings.github.connect.button")
        case .connected:
            Button("Review or add workspace access", action: onConnect)
                .disabled(isUpdatingGitHub)
                .accessibilityIdentifier("settings.github.connect.button")
        }
    }

    private func workspaceGrantRow(_ group: WorkspaceGrantGroup) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(group.workspace).font(.body.weight(.semibold))
                Spacer()
                Text(credentialStatus(for: group))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(credentialStatusColor(for: group))
            }
            LabeledContent("Owner", value: group.owner ?? "Unavailable")
                .font(.caption)
            LabeledContent("Repositories", value: repositorySummary(for: group))
                .font(.caption)
            LabeledContent("Access", value: group.accessModes.joined(separator: " + "))
                .font(.caption)
            LabeledContent("Last verified", value: verificationAge(group.verifiedAt))
                .font(.caption)
            if needsRetry(group) {
                Text("Blocked: GitHub-backed repository access and host pushes for \(group.workspace).")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                if needsRetry(group) {
                    Button(recoveryActionTitle(for: group), action: onConnect)
                        .disabled(isUpdatingGitHub)
                }
                Button("Remove \(group.workspace) access…", role: .destructive) {
                    destructiveAction = .remove(group)
                }
                .disabled(isUpdatingGitHub)
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
                    owner: entries.compactMap(\.owner).first,
                    repositoryNames: Array(Set(entries.flatMap { $0.repositoryNames })).sorted(),
                    accessModes: Array(Set(entries.map(\.accessMode))).sorted(),
                    verifiedAt: entries.map(\.updatedAt).max()
                )
            }
            .sorted { $0.workspace < $1.workspace }
    }

    private var effectiveReducedMotion: Bool {
        reducedMotion || systemReduceMotion
    }

    private var reducedMotionStatus: String {
        if systemReduceMotion { return "On (macOS setting)" }
        return reducedMotion ? "On" : "Off"
    }

    private var loginItemStatusText: String {
        switch loginItemStatus {
        case .enabled: return "Enabled"
        case .requiresApproval: return "Denied until approved in System Settings"
        case .notRegistered: return "Disabled"
        case .notFound: return "Unavailable in this build"
        @unknown default: return "Unavailable — retry the status check"
        }
    }

    private var githubStatusText: String {
        switch githubConnectionState {
        case .loading: return "Loading…"
        case .unavailable: return "Unavailable — retry"
        case .signedOut: return "Signed out"
        case .sessionExpired: return "Sign-in expired — workspace grants need review"
        case .connected: return "Connected · \(groupedMetadata.count) workspace grant\(groupedMetadata.count == 1 ? "" : "s")"
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

    private func credentialStatus(for group: WorkspaceGrantGroup) -> String {
        let states = Set(group.entries.map(\.recoveryState))
        if group.entries.contains(where: \.quarantined) || states.contains(.quarantined) {
            return "Quarantined — reauthorize"
        }
        if states.contains(.expired) { return "Expired — reauthorize" }
        if states.contains(.revoked) { return "Denied or revoked — reauthorize" }
        if states.contains(.installationRemoved) { return "GitHub App unavailable — reinstall" }
        if states.contains(.serviceUnavailable) { return "Service unavailable — retry" }
        if states.contains(.needsAuthorization) { return "Authorization required" }
        if states.contains(.migrationRequired) { return "Update required" }
        if group.entries.contains(where: \.needsRestart) { return "Ready after workspace restart" }
        return "Ready"
    }

    private func credentialStatusColor(for group: WorkspaceGrantGroup) -> Color {
        credentialStatus(for: group) == "Ready" ? .secondary : .orange
    }

    private func needsRetry(_ group: WorkspaceGrantGroup) -> Bool {
        group.entries.contains {
            $0.recoveryState != .ready || $0.quarantined || $0.needsRestart
        }
    }

    private func recoveryActionTitle(for group: WorkspaceGrantGroup) -> String {
        if group.entries.contains(where: { $0.recoveryState == .serviceUnavailable }) {
            return "Retry access"
        }
        if group.entries.contains(where: { $0.recoveryState == .installationRemoved }) {
            return "Reinstall or reauthorize"
        }
        if group.entries.contains(where: \.needsRestart) {
            return "Open Setup to Review Restart"
        }
        return "Reauthorize"
    }

    private func verificationAge(_ date: Date?) -> String {
        guard let date else { return "Never verified" }
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        let age: String
        if seconds < 60 {
            age = "\(seconds) seconds ago"
        } else if seconds < 3_600 {
            age = "\(seconds / 60) minutes ago"
        } else if seconds < 86_400 {
            age = "\(seconds / 3_600) hours ago"
        } else {
            age = "\(seconds / 86_400) days ago"
        }
        return "\(age) · \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private func repositorySummary(for group: WorkspaceGrantGroup) -> String {
        group.repositoryNames.isEmpty ? "None recorded" : group.repositoryNames.joined(separator: ", ")
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
        guard let authorizationCoordinator else {
            githubConnectionState = .unavailable
            return
        }
        githubConnectionState = .loading
        let account = await authorizationCoordinator.connectedAccount()
        let refreshedMetadata = await authorizationCoordinator.metadata()
        connectedAccount = account
        metadata = refreshedMetadata

        if account != nil {
            githubConnectionState = .connected
        } else if refreshedMetadata.isEmpty {
            githubConnectionState = .signedOut
        } else if refreshedMetadata.contains(where: { $0.recoveryState == .serviceUnavailable }) {
            githubConnectionState = .unavailable
        } else {
            githubConnectionState = .sessionExpired
        }
    }

    private func removeWorkspace(_ workspace: String) {
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
                githubError = "Removal could not be verified. \(workspace) remains visible and may be quarantined. Retry or reauthorize: \(error.localizedDescription)"
                await loadGitHubStatePreservingError()
            }
        }
    }

    private func disconnectAccount() {
        guard let authorizationCoordinator else { return }
        isUpdatingGitHub = true
        githubError = nil
        Task {
            do {
                try await authorizationCoordinator.disconnectAccount()
                isUpdatingGitHub = false
                metadata = []
                connectedAccount = nil
                githubConnectionState = .signedOut
            } catch {
                isUpdatingGitHub = false
                githubError = "Disconnect could not be verified. Affected grants remain visible and may be quarantined. Retry or reauthorize: \(error.localizedDescription)"
                await loadGitHubStatePreservingError()
            }
        }
    }

    private func loadGitHubStatePreservingError() async {
        let message = githubError
        await loadGitHubState()
        githubError = message
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

            GroupBox("Credential impact") {
                VStack(alignment: .leading, spacing: 7) {
                    Text("• VM-held secrets and local Keychain records for the affected grants are removed.")
                    Text("• MSW Connect is asked to revoke the corresponding service grants.")
                    Text("• If remote revocation cannot be proven, access is quarantined and remains visible for retry.")
                    Text("• Workspace files and repositories are not deleted. Access can be restored later by reauthorizing and reviewing scope again.")
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
        case .disconnect: return "Disconnect this GitHub account?"
        }
    }

    private var introduction: String {
        switch action {
        case .remove:
            return "Review this workspace-specific revocation before any credential changes are made."
        case .disconnect(_, let account):
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
            Text("Owner: \(group.owner ?? "Unavailable")")
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
        case .disconnect: return "DISCONNECT"
        }
    }

    private var confirmButtonTitle: String {
        switch action {
        case .remove: return "Remove Workspace Access"
        case .disconnect: return "Disconnect Account"
        }
    }
}
