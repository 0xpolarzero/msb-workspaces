import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let window: NSWindow

    init(
        authorizationCoordinator: GitHubAuthorizationCoordinator? = nil,
        onConnect: @escaping () -> Void = {}
    ) {
        let hosting = NSHostingController(
            rootView: SettingsView(
                authorizationCoordinator: authorizationCoordinator,
                onConnect: onConnect
            )
        )
        window = NSWindow(contentViewController: hosting)
        window.title = "MSW Monitor Settings"
        window.setContentSize(NSSize(width: 620, height: 470))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.center()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    let authorizationCoordinator: GitHubAuthorizationCoordinator?
    let onConnect: () -> Void
    @AppStorage("pollingCadence") private var pollingCadence = 30.0
    @AppStorage("reducedMotion") private var reducedMotion = false
    @AppStorage("backupDestination") private var backupDestination = ""
    @State private var loginItemStatus: SMAppService.Status = .notRegistered
    @State private var loginItemError: String?
    @State private var metadata: [WorkspaceCredentialMetadata] = []
    @State private var connectedAccount: GitHubAccount?
    @State private var githubStatus = "Loading connection state…"
    @State private var githubError: String?
    @State private var isUpdatingGitHub = false

    init(
        authorizationCoordinator: GitHubAuthorizationCoordinator? = nil,
        onConnect: @escaping () -> Void = {
            NSApp.sendAction(#selector(AppDelegate.openGitHubSetup), to: nil, from: nil)
        }
    ) {
        if let authorizationCoordinator {
            self.authorizationCoordinator = authorizationCoordinator
        } else {
            let broker = try? CredentialBroker()
            self.authorizationCoordinator = broker.map {
                GitHubAuthorizationCoordinator(broker: $0)
            }
        }
        self.onConnect = onConnect
    }

    var body: some View {
        TabView {
            Form {
                Toggle(
                    "Launch MSW Monitor at login",
                    isOn: Binding(
                        get: { loginItemStatus == .enabled },
                        set: { setLaunchAtLogin($0) }
                    )
                )
                Text(loginItemStatusText)
                    .font(.caption)
                    .foregroundStyle(loginItemStatus == .requiresApproval ? .orange : .secondary)
                if let loginItemError {
                    Text(loginItemError)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if loginItemStatus == .requiresApproval {
                    Button("Open Login Items Settings", action: openLoginItemsSettings)
                }
                Picker("Polling cadence", selection: $pollingCadence) {
                    Text("15 seconds").tag(15.0)
                    Text("30 seconds").tag(30.0)
                    Text("60 seconds").tag(60.0)
                }
                Toggle("Reduce motion in operational views", isOn: $reducedMotion)
            }
            .task { refreshLoginItemStatus() }
            .tabItem { Label("General", systemImage: "gear") }

            Form {
                Text("Per-workspace resources, browser links, and Git identity are managed by MSW's typed configuration.")
                    .foregroundStyle(.secondary)
                Text("No credential values are displayed in Settings.")
                    .font(.caption)
            }
            .tabItem { Label("Workspaces", systemImage: "square.grid.3x3") }

            Form {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("GitHub access").font(.headline)
                        Text("Authorize once through MSW Connect, then review each workspace grant separately.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Connect GitHub", action: onConnect)
                        .buttonStyle(.borderedProminent)
                        .disabled(isUpdatingGitHub)
                        .accessibilityIdentifier("settings.github.connect.button")
                }
                Text(githubStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.github.status")
                if let githubError {
                    Text(githubError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if metadata.isEmpty {
                    ContentUnavailableView(
                        "No workspace grants",
                        systemImage: "lock.shield",
                        description: Text("Connect GitHub and assign repositories to a workspace from the setup review.")
                    )
                } else {
                    ForEach(groupedMetadata, id: \.workspace) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(group.workspace).font(.body.weight(.semibold))
                                Text(group.accessModes.joined(separator: " + "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if group.entries.contains(where: { $0.recoveryState != .ready || $0.quarantined }) {
                                    Text("Needs attention")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                            }
                            Text("\(group.owner ?? "Unknown owner") · \(group.repositoryNames.joined(separator: ", "))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            HStack {
                                Button("Reauthorize") { onConnect() }
                                    .disabled(isUpdatingGitHub)
                                Button("Remove workspace access", role: .destructive) {
                                    removeWorkspace(group.workspace)
                                }
                                .disabled(isUpdatingGitHub)
                            }
                        }
                        .padding(.vertical, 5)
                    }
                }
                HStack {
                    Spacer()
                    Button("Disconnect GitHub", role: .destructive) { disconnectAccount() }
                        .disabled((metadata.isEmpty && connectedAccount == nil) || isUpdatingGitHub)
                }
                Text("Tokens, private keys, authorization codes, and service session material are never displayed or copied here.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .task { await loadGitHubState() }
            .tabItem { Label("GitHub", systemImage: "person.crop.circle.badge.checkmark") }

            Form {
                TextField("Backup destination", text: $backupDestination)
                    .textContentType(.URL)
                Text("Backup archives exclude Keychain records and are treated as sensitive workspace data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .tabItem { Label("Backup", systemImage: "externaldrive") }

            Form {
                Text("MSW Monitor").font(.headline)
                Text("Native macOS menu-bar monitor with typed MSW integration.")
            }
            .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 620, height: 470)
    }

    private var groupedMetadata: [(
        workspace: String,
        entries: [WorkspaceCredentialMetadata],
        owner: String?,
        repositoryNames: [String],
        accessModes: [String]
    )] {
        Dictionary(grouping: metadata, by: \.workspace)
            .map { workspace, entries in
                (
                    workspace: workspace,
                    entries: entries,
                    owner: entries.compactMap(\.owner).first,
                    repositoryNames: Array(Set(entries.flatMap { $0.repositoryNames })).sorted(),
                    accessModes: Array(Set(entries.map(\.accessMode))).sorted()
                )
            }
            .sorted { $0.workspace < $1.workspace }
    }

    private var loginItemStatusText: String {
        switch loginItemStatus {
        case .enabled:
            return "Login item enabled. Launch observes MSW state and never starts a workspace."
        case .requiresApproval:
            return "Approval is required in System Settings."
        case .notRegistered:
            return "Login item is disabled."
        case .notFound:
            return "Login item is unavailable in this build."
        @unknown default:
            return "Login item status is unavailable."
        }
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
            loginItemError = error.localizedDescription
            refreshLoginItemStatus()
        }
    }

    private func loadGitHubState() async {
        guard let authorizationCoordinator else {
            githubStatus = "GitHub authorization is unavailable in this build."
            return
        }
        connectedAccount = await authorizationCoordinator.connectedAccount()
        metadata = await authorizationCoordinator.metadata()
        if let connectedAccount {
            githubStatus = "Connected as @\(connectedAccount.login). \(metadata.count) workspace grant\(metadata.count == 1 ? "" : "s") configured."
        } else {
            githubStatus = "Not connected. Connect GitHub to configure workspace grants."
        }
    }

    private func removeWorkspace(_ workspace: String) {
        guard let authorizationCoordinator else { return }
        isUpdatingGitHub = true
        githubError = nil
        Task {
            do {
                try await authorizationCoordinator.removeWorkspace(workspace)
                await MainActor.run {
                    isUpdatingGitHub = false
                    Task { await loadGitHubState() }
                }
            } catch {
                await MainActor.run {
                    isUpdatingGitHub = false
                    githubError = error.localizedDescription
                }
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
                await MainActor.run {
                    isUpdatingGitHub = false
                    metadata = []
                    connectedAccount = nil
                    githubStatus = "Not connected."
                }
            } catch {
                await MainActor.run {
                    isUpdatingGitHub = false
                    githubError = error.localizedDescription
                }
            }
        }
    }

    private func openLoginItemsSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings") else { return }
        NSWorkspace.shared.open(url)
    }
}
