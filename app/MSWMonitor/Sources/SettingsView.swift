import AppKit
import SwiftUI
import ServiceManagement

@MainActor
final class SettingsWindowController {
    private let window: NSWindow

    init() {
        let hosting = NSHostingController(rootView: SettingsView())
        window = NSWindow(contentViewController: hosting)
        window.title = "MSW Monitor Settings"
        window.setContentSize(NSSize(width: 560, height: 360))
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
    @AppStorage("githubClientID.dev.guest") private var devGuestClientID = ""
    @AppStorage("githubClientID.dev.host") private var devHostClientID = ""
    @AppStorage("githubClientID.playgrounds.guest") private var playgroundsGuestClientID = ""
    @AppStorage("githubClientID.playgrounds.host") private var playgroundsHostClientID = ""
    @AppStorage("githubClientID.personal.guest") private var personalGuestClientID = ""
    @AppStorage("githubClientID.personal.host") private var personalHostClientID = ""
    @AppStorage("pollingCadence") private var pollingCadence = 30.0
    @AppStorage("reducedMotion") private var reducedMotion = false
    @AppStorage("backupDestination") private var backupDestination = ""
    @State private var loginItemStatus: SMAppService.Status = .notRegistered
    @State private var loginItemError: String?
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
                    Button("Open Login Items Settings") {
                        openLoginItemsSettings()
                    }
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
                Text("GitHub authorization uses Device Flow and the Mac Keychain.")
                GroupBox("dev") {
                    TextField("Guest app client ID", text: $devGuestClientID)
                    TextField("Host app client ID", text: $devHostClientID)
                }
                GroupBox("playgrounds") {
                    TextField("Guest app client ID", text: $playgroundsGuestClientID)
                    TextField("Host app client ID", text: $playgroundsHostClientID)
                }
                GroupBox("personal") {
                    TextField("Guest app client ID", text: $personalGuestClientID)
                    TextField("Host app client ID", text: $personalHostClientID)
                }
                Text("Client IDs are public identifiers. Access and refresh tokens are never displayed or copied.")
                    .foregroundStyle(.secondary)
            }
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
                Text("Native macOS 26 menu-bar monitor with typed MSW integration.")
            }
            .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 360)
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

    private func openLoginItemsSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings") else { return }
        NSWorkspace.shared.open(url)
    }
}
