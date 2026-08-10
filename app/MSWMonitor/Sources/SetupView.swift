import AppKit
import SwiftUI

@MainActor
final class SetupWindowController {
    private let window: NSWindow

    init(
        coordinator: BootstrapCoordinator?,
        authorizationCoordinator: GitHubAuthorizationCoordinator? = nil,
        openSettings: @escaping () -> Void,
        closeSetup: @escaping () -> Void = {}
    ) {
        let fallbackBroker = try? CredentialBroker()
        let authorization = authorizationCoordinator ??
            fallbackBroker.map { GitHubAuthorizationCoordinator(broker: $0) }
        let hosting = NSHostingController(
            rootView: SetupView(
                coordinator: coordinator,
                authorizationCoordinator: authorization,
                openSettings: openSettings,
                closeSetup: closeSetup
            )
        )
        window = NSWindow(contentViewController: hosting)
        window.title = "Set up MSW Monitor"
        window.setContentSize(NSSize(width: 560, height: 620))
        window.minSize = NSSize(width: 520, height: 520)
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.center()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window.close()
    }
}

struct SetupView: View {
    let coordinator: BootstrapCoordinator?
    let authorizationCoordinator: GitHubAuthorizationCoordinator?
    let openSettings: () -> Void
    let closeSetup: () -> Void
    @AppStorage("githubClientID.dev.guest") private var devGuestClientID = ""
    @AppStorage("githubClientID.dev.host") private var devHostClientID = ""
    @AppStorage("githubClientID.playgrounds.guest") private var playgroundsGuestClientID = ""
    @AppStorage("githubClientID.playgrounds.host") private var playgroundsHostClientID = ""
    @AppStorage("githubClientID.personal.guest") private var personalGuestClientID = ""
    @AppStorage("githubClientID.personal.host") private var personalHostClientID = ""
    @State private var checks: [MSWPreflightCheck] = []
    @State private var state = MSWBootstrapState.initial
    @State private var isRunning = false
    @State private var isChecking = true
    @State private var passedChecksExpanded = false
    @State private var githubExpanded = false
    @State private var error: String?
    @State private var notice: String?
    @State private var selectedWorkspace: Workspace.ID = .dev
    @State private var activeAuthorizationRole: CredentialRole?
    @State private var authorizationSessionID: UUID?
    @State private var installations: [GitHubInstallation] = []
    @State private var selectedInstallationID: Int?
    @State private var repositories: [GitHubRepository] = []
    @State private var selectedRepositoryIDs: Set<Int> = []
    @State private var verificationRepositoryID: Int?
    @State private var authorizationStatus = ""
    @State private var deviceCode = ""
    @State private var deviceVerificationURL: URL?
    @State private var isAuthorizing = false
    @State private var authorizationTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Set up MSW Monitor").font(.largeTitle.weight(.semibold))
                Text("First, make sure this Mac is ready. GitHub can be connected now or later.")
                    .foregroundStyle(.secondary)
                setupOverview
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    preflight
                    Divider()
                    githubBoundary
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.bottom, 22)
            }

            Divider()
            stickyFooter
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 520, idealHeight: 620)
        .task { loadPreflight() }
        .onDisappear { cancelAuthorization() }
        .accessibilityIdentifier("setup.window")
    }

    private var blockingChecks: [MSWPreflightCheck] {
        checks.filter { check in
            check.status != .pass && check.id != "memory"
        }
    }

    private var warningChecks: [MSWPreflightCheck] {
        checks.filter { check in
            check.status == .needsAction && check.id == "memory"
        }
    }

    private var attentionChecks: [MSWPreflightCheck] {
        blockingChecks
    }

    private var passedChecks: [MSWPreflightCheck] {
        checks.filter { $0.status == .pass }
    }

    private var systemReady: Bool {
        !checks.isEmpty && blockingChecks.isEmpty
    }

    private var hostIntegrationNeedsPackagedBuild: Bool {
        checks.contains {
            $0.id == "host-integration" && $0.status == .unavailable
        }
    }

    private var canAuthorizeGitHub: Bool {
        systemReady && state.phase == .complete && !isRunning && !isChecking
    }

    private var hasConfiguredGuestClient: Bool {
        !selectedClientID(for: .guest).isEmpty
    }

    private var hasConfiguredHostClient: Bool {
        !selectedClientID(for: .host).isEmpty
    }

    private var hasConfiguredGitHubClient: Bool {
        hasConfiguredGuestClient || hasConfiguredHostClient
    }

    private var canFinishWithoutGitHub: Bool {
        systemReady && state.phase == .complete
    }

    private var setupOverview: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(checks.isEmpty
                    ? "Checking system readiness…"
                    : "\(passedChecks.count) of \(checks.count) checks ready")
                    .font(.subheadline.weight(.medium))
                Spacer()
                if isRunning {
                    Text("Working on \(label(for: state.phase).lowercased())…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !attentionChecks.isEmpty {
                    Text("\(attentionChecks.count) need attention")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                } else if !warningChecks.isEmpty {
                    Text("\(warningChecks.count) advisory")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(
                value: checks.isEmpty ? 0 : Double(passedChecks.count),
                total: Double(max(checks.count, 1))
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("setup.overview")
    }

    private var preflight: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("System readiness").font(.title3.weight(.semibold))
                Spacer()
                if isChecking { ProgressView().controlSize(.small) }
            }
            if checks.isEmpty {
                Text("Checking this Mac…")
                    .foregroundStyle(.secondary)
            } else {
                if attentionChecks.isEmpty {
                    Label(
                        warningChecks.isEmpty
                            ? "This Mac is ready for MSW Monitor."
                            : "This Mac is ready; review the advisory below.",
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("setup.preflight.ready")
                } else {
                    VStack(spacing: 10) {
                        ForEach(attentionChecks) { check in
                            preflightRow(check, prominent: true)
                        }
                    }
                    .accessibilityIdentifier("setup.preflight.attention")
                }

                if !warningChecks.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Advisory", systemImage: "info.circle.fill")
                            .foregroundStyle(.secondary)
                        ForEach(warningChecks) { check in
                            preflightRow(check, prominent: false)
                        }
                    }
                }

                if !passedChecks.isEmpty {
                    DisclosureGroup(isExpanded: $passedChecksExpanded) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(passedChecks) { check in
                                preflightRow(check, prominent: false)
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        Label("\(passedChecks.count) checks passed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("setup.preflight.passed.toggle")
                }
            }
        }
        .accessibilityIdentifier("setup.preflight")
    }

    @ViewBuilder
    private func preflightRow(_ check: MSWPreflightCheck, prominent: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol(for: check.status))
                .foregroundStyle(color(for: check.status))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: prominent ? 5 : 1) {
                Text(check.title).font(.body.weight(prominent ? .semibold : .regular))
                if prominent {
                    Text(check.detail).font(.callout).foregroundStyle(.secondary)
                    if let remediation = check.remediation {
                        Text(remediation).font(.callout).foregroundStyle(.primary)
                    }
                    if check.id == "host-integration",
                       check.status == .needsAction,
                       check.remediation?.localizedCaseInsensitiveContains("Login Items") == true {
                        Button("Open Login Items Settings") { openHostApprovalSettings() }
                            .accessibilityIdentifier("setup.host.settings.button")
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(prominent ? 12 : 0)
        .background {
            if prominent {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(color(for: check.status).opacity(0.45), lineWidth: 1)
                    }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue("\(statusLabel(for: check.status)). \(check.detail)")
        .accessibilityIdentifier("setup.check.\(check.id)")
    }

    private var githubBoundary: some View {
        DisclosureGroup(isExpanded: $githubExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Connect GitHub now to clone repositories in a workspace. You can skip this and connect later from Settings.")
                if hasConfiguredGitHubClient {
                    HStack {
                        if hasConfiguredGuestClient {
                            Button(isAuthorizing ? "Authorizing…" : "Authorize guest (read-only)") {
                                beginAuthorization(role: .guest)
                            }
                            .disabled(!canAuthorizeGitHub || authorizationSessionID != nil)
                        }
                        if hasConfiguredHostClient {
                            Button(isAuthorizing ? "Authorizing…" : "Authorize host (read/write)") {
                                beginAuthorization(role: .host)
                            }
                            .disabled(!canAuthorizeGitHub || authorizationSessionID != nil || !hasConfiguredGuestClient)
                        }
                        if isAuthorizing || authorizationSessionID != nil {
                            Button("Cancel") { cancelAuthorization() }
                        }
                    }
                    if hasConfiguredHostClient && !hasConfiguredGuestClient {
                        Text("Authorize guest read-only access for this workspace before enabling host write access.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if hasConfiguredGitHubClient && !canAuthorizeGitHub && authorizationSessionID == nil {
                    Text("Complete system setup before connecting GitHub.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            if hasConfiguredGitHubClient {
                Text("Configured public client IDs for \(selectedWorkspace.rawValue): guest \(selectedClientID(for: .guest).isEmpty ? "missing" : "ready"), host \(selectedClientID(for: .host).isEmpty ? "missing" : "ready").")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("GitHub authorization is not configured yet.")
                        .font(.callout.weight(.medium))
                    Text("Add the public GitHub App client IDs in Settings, or continue without GitHub.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open Settings", action: openSettings)
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Open Settings")
                        .accessibilityHint("Open MSW Monitor Settings")
                        .accessibilityIdentifier("setup.github.settings.button")
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
            if !deviceCode.isEmpty {
                Text("Device code: \(deviceCode)").font(.caption.monospaced())
            }
            if let deviceVerificationURL {
                Link("Open GitHub verification page", destination: deviceVerificationURL)
                    .font(.caption)
            }
            if authorizationSessionID != nil {
                if installations.isEmpty {
                    Text("This GitHub App has no authorized installations. Install it for the intended owner in GitHub, then cancel and authorize again.")
                        .font(.caption2).foregroundStyle(.orange)
                } else {
                    Picker("Owner installation", selection: $selectedInstallationID) {
                        Text("Choose an owner").tag(Int?.none)
                        ForEach(installations) { installation in
                            Text(installation.displayName).tag(Optional(installation.id))
                        }
                    }
                    .onChange(of: selectedInstallationID) { _, value in
                        loadRepositories(installationID: value)
                    }
                }
                if !repositories.isEmpty {
                    Text("Repositories allowed for this role").font(.caption.weight(.semibold))
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(repositories) { repository in
                                Toggle(repository.fullName, isOn: repositoryBinding(repository.id))
                                    .toggleStyle(.checkbox)
                            }
                        }
                    }
                    .frame(maxHeight: 120)
                    Picker("Verification repository", selection: $verificationRepositoryID) {
                        Text("Choose a selected repository").tag(Int?.none)
                        ForEach(repositories.filter { selectedRepositoryIDs.contains($0.id) }) { repository in
                            Text(repository.fullName).tag(Optional(repository.id))
                        }
                    }
                    Button("Save and verify \(activeAuthorizationRole?.rawValue ?? "GitHub") authorization") {
                        commitAuthorization()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedRepositoryIDs.isEmpty || verificationRepositoryID == nil || isAuthorizing)
                }
            }
            if !authorizationStatus.isEmpty {
                Text(authorizationStatus).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            }
            .padding(.top, 10)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("GitHub access (optional)").font(.title3.weight(.semibold))
                Text("Connect now or later")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("setup.github-boundary")
    }

    private var stickyFooter: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 10) {
                footerStatus
                footerActions
            }
            VStack(alignment: .leading, spacing: 8) {
                footerStatus
                footerActions.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.bar)
        .accessibilityIdentifier("setup.footer")
    }

    private var footerStatus: some View {
        Group {
            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
            } else if let notice {
                Label(notice, systemImage: "info.circle.fill")
                    .foregroundStyle(.secondary)
            } else if hostIntegrationNeedsPackagedBuild {
                Label(
                    "Install a complete signed MSW Monitor build to continue.",
                    systemImage: "lock.circle.fill"
                )
                .foregroundStyle(.orange)
            } else if !attentionChecks.isEmpty {
                Label(
                    "Resolve the highlighted checks to continue.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
            } else if state.phase == .complete && systemReady {
                Label(
                    "System setup is complete. GitHub can be connected later from Settings.",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
            } else {
                Label(
                    "Continue verifies workspaces, then restores their prior state.",
                    systemImage: "info.circle.fill"
                )
                .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .lineLimit(3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("setup.status")
        .accessibilityValue(
            error ??
            notice ??
            (hostIntegrationNeedsPackagedBuild
                ? "Install a complete signed MSW Monitor build to continue."
                : !attentionChecks.isEmpty
                    ? "Resolve the highlighted checks to continue."
                    : state.phase == .complete && systemReady
                        ? "Ready."
                        : "Continue verifies workspaces, then restores their prior state.")
        )
    }

    private var footerActions: some View {
        HStack(spacing: 10) {
            if canFinishWithoutGitHub {
                Button("Finish without GitHub") { finishWithoutGitHub() }
                    .help("Finish setup and connect GitHub later.")
                    .accessibilityIdentifier("setup.github.skip.button")
            }
            Button(isChecking ? "Checking…" : "Retry") { loadPreflight() }
                .disabled(isChecking || isRunning || coordinator == nil)
                .accessibilityIdentifier("setup.retry.button")
            if hostIntegrationNeedsPackagedBuild {
                Label("Install a complete signed build", systemImage: "lock.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("setup.signed-build.required")
            } else {
                Button(isChecking ? "Checking…" : (attentionChecks.isEmpty ? "Continue" : "Repair & Continue")) {
                    runSetup()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRunning || coordinator == nil || isChecking || checks.isEmpty)
                .help("Complete the system checks and configure host integration.")
                .accessibilityIdentifier("setup.primary-action")
            }
        }
        .fixedSize()
    }

    private func beginAuthorization(role: CredentialRole) {
        guard let authorizationCoordinator else { return }
        let clientID = selectedClientID(for: role)
        guard !clientID.isEmpty else {
            authorizationStatus = "The selected role has no configured public GitHub App client ID."
            return
        }
        isAuthorizing = true
        authorizationStatus = "Starting GitHub Device Flow…"
        deviceCode = ""
        deviceVerificationURL = nil
        activeAuthorizationRole = role
        let workspace = selectedWorkspace.rawValue
        let configuration = GitHubDeviceFlow.Configuration(clientID: clientID)
        authorizationTask = Task {
            do {
                let discovery = try await authorizationCoordinator.beginAuthorization(
                    workspace: workspace,
                    role: role,
                    deviceConfiguration: configuration,
                    onEvent: { event in
                        Task { @MainActor in
                            if case let .deviceCodeIssued(userCode, verificationURI, _) = event {
                                deviceCode = userCode
                                deviceVerificationURL = verificationURI
                            }
                        }
                    }
                )
                if Task.isCancelled {
                    await authorizationCoordinator.cancelAuthorization(sessionID: discovery.sessionID)
                    return
                }
                await MainActor.run {
                    isAuthorizing = false
                    authorizationTask = nil
                    authorizationSessionID = discovery.sessionID
                    installations = discovery.installations
                    selectedInstallationID = discovery.installations.first?.id
                    authorizationStatus = "Authorized as \(discovery.account.login). Select the owner installation and repositories to commit this role."
                    if let installationID = selectedInstallationID {
                        loadRepositories(installationID: installationID)
                    }
                }
            } catch {
                await MainActor.run {
                    isAuthorizing = false
                    authorizationTask = nil
                    authorizationStatus = error.localizedDescription
                    activeAuthorizationRole = nil
                }
            }
        }
    }

    private func loadRepositories(installationID: Int?) {
        guard let authorizationCoordinator,
              let sessionID = authorizationSessionID,
              let installationID else {
            repositories = []
            selectedRepositoryIDs = []
            verificationRepositoryID = nil
            return
        }
        isAuthorizing = true
        authorizationStatus = "Loading repositories allowed by this installation…"
        authorizationTask?.cancel()
        authorizationTask = Task {
            do {
                let discovered = try await authorizationCoordinator.repositories(
                    sessionID: sessionID,
                    installationID: installationID
                )
                await MainActor.run {
                    repositories = discovered
                    selectedRepositoryIDs = []
                    verificationRepositoryID = nil
                    isAuthorizing = false
                    authorizationTask = nil
                    authorizationStatus = discovered.isEmpty
                        ? "This installation exposes no repositories to the selected GitHub App."
                        : "Select the repositories this workspace role may access."
                }
            } catch {
                await MainActor.run {
                    repositories = []
                    selectedRepositoryIDs = []
                    verificationRepositoryID = nil
                    isAuthorizing = false
                    authorizationTask = nil
                    authorizationStatus = error.localizedDescription
                }
            }
        }
    }

    private func commitAuthorization() {
        guard let authorizationCoordinator,
              let sessionID = authorizationSessionID,
              let installationID = selectedInstallationID,
              let installation = installations.first(where: { $0.id == installationID }),
              let verificationID = verificationRepositoryID,
              let verification = repositories.first(where: { $0.id == verificationID }),
              selectedRepositoryIDs.contains(verificationID) else {
            authorizationStatus = "Choose an owner, at least one repository, and one selected verification repository."
            return
        }
        isAuthorizing = true
        authorizationStatus = "Binding and verifying the selected GitHub permissions…"
        let selection = GitHubAuthorizationSelection(
            owner: installation.account.login,
            installationID: installationID,
            repositoryIDs: selectedRepositoryIDs.sorted(),
            verificationRepository: verification.fullName
        )
        authorizationTask?.cancel()
        authorizationTask = Task {
            do {
                let metadata = try await authorizationCoordinator.commitAuthorization(
                    sessionID: sessionID,
                    selection: selection
                )
                await MainActor.run {
                    resetAuthorizationSelection(keepingStatus: true)
                    authorizationStatus = "\(metadata.role.rawValue.capitalized) authorization verified for \(metadata.accountLogin ?? "the selected account")."
                }
            } catch {
                await MainActor.run {
                    resetAuthorizationSelection(keepingStatus: true)
                    authorizationStatus = error.localizedDescription
                }
            }
        }
    }

    private func cancelAuthorization() {
        authorizationTask?.cancel()
        authorizationTask = nil
        if let sessionID = authorizationSessionID, let authorizationCoordinator {
            Task { await authorizationCoordinator.cancelAuthorization(sessionID: sessionID) }
        }
        resetAuthorizationSelection()
    }

    private func resetAuthorizationSelection(keepingStatus: Bool = false) {
        isAuthorizing = false
        authorizationTask = nil
        activeAuthorizationRole = nil
        authorizationSessionID = nil
        installations = []
        selectedInstallationID = nil
        repositories = []
        selectedRepositoryIDs = []
        verificationRepositoryID = nil
        deviceCode = ""
        deviceVerificationURL = nil
        if !keepingStatus { authorizationStatus = "" }
    }

    private func repositoryBinding(_ id: Int) -> Binding<Bool> {
        Binding(
            get: { selectedRepositoryIDs.contains(id) },
            set: { selected in
                if selected {
                    selectedRepositoryIDs.insert(id)
                } else {
                    selectedRepositoryIDs.remove(id)
                    if verificationRepositoryID == id { verificationRepositoryID = nil }
                }
            }
        )
    }

    private func selectedClientID(for role: CredentialRole) -> String {
        switch (selectedWorkspace, role) {
        case (.dev, .guest): return devGuestClientID
        case (.dev, .host): return devHostClientID
        case (.playgrounds, .guest): return playgroundsGuestClientID
        case (.playgrounds, .host): return playgroundsHostClientID
        case (.personal, .guest): return personalGuestClientID
        case (.personal, .host): return personalHostClientID
        }
    }

    private func loadPreflight() {
        guard let coordinator else { return }
        isChecking = true
        Task {
            let savedState = await coordinator.state()
            let result = await coordinator.preflight()
            await MainActor.run {
                state = savedState
                checks = result
                isChecking = false
            }
        }
    }

    private func openHostApprovalSettings() {
        guard let coordinator else { return }
        Task { await coordinator.openHostApprovalSettings() }
    }

    private func runSetup() {
        guard let coordinator else { return }
        isRunning = true
        error = nil
        notice = nil
        Task {
            do {
                let result = try await coordinator.run()
                let savedState = await coordinator.state()
                let refreshedChecks = await coordinator.preflight()
                await MainActor.run {
                    state = savedState
                    checks = refreshedChecks
                    isRunning = false
                    if !result.requiresApproval && result.phase == MSWBootstrapState.Phase.complete.rawValue {
                        UserDefaults.standard.set(true, forKey: "setupCompleted")
                    }
                    notice = result.requiresApproval
                        ? (result.phase == MSWBootstrapState.Phase.hostIntegration.rawValue
                            ? "Approve the host helper in Login Items, then choose Retry."
                            : result.message)
                        : result.message
                }
            } catch {
                await MainActor.run {
                    isRunning = false
                    self.error = error.localizedDescription
                }
            }
        }
    }

    private func finishWithoutGitHub() {
        guard canFinishWithoutGitHub else { return }
        UserDefaults.standard.set(true, forKey: "setupCompleted")
        closeSetup()
    }

    private func label(for phase: MSWBootstrapState.Phase) -> String {
        switch phase {
        case .welcome: return "Welcome"
        case .preflight: return "Preflight"
        case .toolchain: return "Tools"
        case .hostIntegration: return "Host"
        case .workspaces: return "Workspaces"
        case .github: return "GitHub"
        case .identity: return "Finish"
        case .complete: return "Ready"
        }
    }

    private func statusLabel(for status: MSWPreflightCheck.Status) -> String {
        switch status {
        case .pass: return "Ready"
        case .needsAction: return "Needs attention"
        case .unavailable: return "Unavailable"
        }
    }

    private func symbol(for status: MSWPreflightCheck.Status) -> String {
        switch status {
        case .pass: return "checkmark.circle.fill"
        case .needsAction: return "exclamationmark.triangle.fill"
        case .unavailable: return "xmark.octagon.fill"
        }
    }

    private func color(for status: MSWPreflightCheck.Status) -> Color {
        switch status {
        case .pass: return .green
        case .needsAction: return .orange
        case .unavailable: return .red
        }
    }
}
