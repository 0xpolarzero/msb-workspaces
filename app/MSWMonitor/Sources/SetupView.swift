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
        let authorization = authorizationCoordinator ?? fallbackBroker.map {
            GitHubAuthorizationCoordinator(broker: $0)
        }
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
        window.setContentSize(NSSize(width: 620, height: 700))
        window.minSize = NSSize(width: 560, height: 560)
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.center()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() { window.close() }
}

private struct WorkspaceAssignmentDraft: Equatable, Identifiable {
    let workspace: Workspace.ID
    var installationID: Int?
    var repositoryIDs: Set<Int>
    var verificationRepositoryID: Int?
    var accessMode: String
    var enabled: Bool

    var id: Workspace.ID { workspace }

    static func initial(_ workspace: Workspace.ID) -> Self {
        Self(
            workspace: workspace,
            installationID: nil,
            repositoryIDs: [],
            verificationRepositoryID: nil,
            accessMode: "read-only",
            enabled: false
        )
    }
}

struct SetupView: View {
    let coordinator: BootstrapCoordinator?
    let authorizationCoordinator: GitHubAuthorizationCoordinator?
    let openSettings: () -> Void
    let closeSetup: () -> Void

    @State private var checks: [MSWPreflightCheck] = []
    @State private var state = MSWBootstrapState.initial
    @State private var isRunning = false
    @State private var isChecking = true
    @State private var passedChecksExpanded = false
    @State private var githubExpanded = true
    @State private var error: String?
    @State private var notice: String?

    @State private var account: GitHubAccount?
    @State private var installations: [GitHubInstallation] = []
    @State private var githubInstallationURL: URL?
    @State private var repositoriesByInstallation: [Int: [GitHubRepository]] = [:]
    @State private var drafts = Dictionary(uniqueKeysWithValues: Workspace.ID.allCases.map {
        ($0.rawValue, WorkspaceAssignmentDraft.initial($0))
    })
    @State private var existingMetadata: [WorkspaceCredentialMetadata] = []
    @State private var authorizationSessionID: UUID?
    @State private var authorizationStatus = ""
    @State private var isAuthorizing = false
    @State private var isReviewing = false
    @State private var authorizationTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Set up MSW Monitor").font(.largeTitle.weight(.semibold))
                Text("Make sure this Mac is ready, then connect GitHub once and assign access per workspace.")
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
        .frame(minWidth: 560, idealWidth: 620, minHeight: 560, idealHeight: 700)
        .task {
            loadPreflight()
            await loadExistingMetadata()
        }
        .onDisappear { cancelAuthorization() }
        .accessibilityIdentifier("setup.window")
    }

    private var blockingChecks: [MSWPreflightCheck] {
        checks.filter { $0.status != .pass && $0.id != "memory" }
    }

    private var warningChecks: [MSWPreflightCheck] {
        checks.filter { $0.status == .needsAction && $0.id == "memory" }
    }

    private var passedChecks: [MSWPreflightCheck] {
        checks.filter { $0.status == .pass }
    }

    private var systemReady: Bool {
        !checks.isEmpty && blockingChecks.isEmpty
    }

    private var canConnectGitHub: Bool {
        systemReady && state.phase == .complete && !isRunning && !isChecking
    }

    private var canFinishWithoutGitHub: Bool {
        systemReady && state.phase == .complete
    }

    private var hostIntegrationNeedsPackagedBuild: Bool {
        checks.contains { $0.id == "host-integration" && $0.status == .unavailable }
    }

    private var setupOverview: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(checks.isEmpty ? "Checking system readiness…" : "\(passedChecks.count) of \(checks.count) checks ready")
                    .font(.subheadline.weight(.medium))
                Spacer()
                if isRunning {
                    Text("Working on \(label(for: state.phase).lowercased())…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !blockingChecks.isEmpty {
                    Text("\(blockingChecks.count) need attention")
                        .font(.caption.weight(.medium))
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
                Text("Checking this Mac…").foregroundStyle(.secondary)
            } else {
                if blockingChecks.isEmpty {
                    Label(
                        warningChecks.isEmpty ? "This Mac is ready for MSW Monitor." : "This Mac is ready; review the advisory below.",
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("setup.preflight.ready")
                } else {
                    VStack(spacing: 10) {
                        ForEach(blockingChecks) { check in preflightRow(check, prominent: true) }
                    }
                    .accessibilityIdentifier("setup.preflight.attention")
                }
                if !warningChecks.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Advisory", systemImage: "info.circle.fill")
                            .foregroundStyle(.secondary)
                        ForEach(warningChecks) { check in preflightRow(check, prominent: false) }
                    }
                }
                if !passedChecks.isEmpty {
                    DisclosureGroup(isExpanded: $passedChecksExpanded) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(passedChecks) { check in preflightRow(check, prominent: false) }
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
                        Button("Open Login Items Settings", action: openHostApprovalSettings)
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
            VStack(alignment: .leading, spacing: 12) {
                if let account {
                    Label("Connected as @\(account.login)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityIdentifier("setup.github.account")
                    Text("Choose the owner, repositories, and access mode for each workspace. Read-only is the default; write access is opt-in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Connect GitHub through the system browser. The browser session returns to MSW Monitor before any workspace grant is created.")
                        .foregroundStyle(.secondary)
                    Button("Connect GitHub", action: beginAuthorization)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canConnectGitHub || isAuthorizing)
                        .accessibilityIdentifier("setup.github.connect.button")
                }
                if account != nil {
                    if installations.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("MSW App is not installed for an owner yet.", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("Install the MSW App for the GitHub owner that should provide repositories, then connect GitHub again.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if githubInstallationURL != nil {
                                Button("Install MSW App in GitHub", action: openGitHubInstallation)
                                    .accessibilityIdentifier("setup.github.install.button")
                            }
                        }
                        .padding(10)
                        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                    ForEach(Workspace.ID.allCases, id: \.rawValue) { workspace in
                        assignmentCard(for: workspace)
                    }
                    if isReviewing {
                        reviewCard
                    } else {
                        Button("Review workspace access") { isReviewing = true }
                            .buttonStyle(.borderedProminent)
                            .disabled(!hasValidAssignments || isAuthorizing)
                            .accessibilityIdentifier("setup.github.review.button")
                    }
                    Button("Disconnect GitHub", role: .destructive) { disconnectGitHub() }
                        .disabled(isAuthorizing)
                }

                if !existingMetadata.isEmpty {
                    Text("Existing assignments").font(.headline)
                    ForEach(groupedExistingMetadata, id: \.workspace) { group in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.workspace)
                                    .font(.callout.weight(.medium))
                                if group.needsAttention {
                                    Text("Needs attention: \(group.states.joined(separator: ", "))")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                } else {
                                    Text("\(group.accessModes.joined(separator: " + ")) · \(group.repositoryNames.joined(separator: ", "))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("Reauthorize") { beginAuthorization() }
                                .disabled(isAuthorizing || !canConnectGitHub)
                            Button("Remove", role: .destructive) { removeWorkspace(group.workspace) }
                                .disabled(isAuthorizing)
                        }
                    }
                }

                if !authorizationStatus.isEmpty {
                    Text(authorizationStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .accessibilityIdentifier("setup.github.status")
                }
            }
            .padding(.top, 10)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("GitHub access").font(.title3.weight(.semibold))
                Text("Connect once, assign per workspace")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("setup.github-boundary")
    }

    private func assignmentCard(for workspace: Workspace.ID) -> some View {
        let draft = drafts[workspace.rawValue] ?? .initial(workspace)
        let installationsForWorkspace = installations
        let repositories = draft.installationID.flatMap { repositoriesByInstallation[$0] } ?? []
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(workspace.rawValue).font(.headline)
                Spacer()
                Toggle("Assign", isOn: draftBinding(for: workspace).enabled)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("setup.github.workspace.\(workspace.rawValue).assign")
            }
            Picker("Owner installation", selection: draftBinding(for: workspace).installationID) {
                Text("Choose an owner").tag(Int?.none)
                ForEach(installationsForWorkspace) { installation in
                    Text(installation.displayName).tag(Optional(installation.id))
                }
            }
            .onChange(of: draft.installationID) { _, value in
                selectInstallation(for: workspace, installationID: value)
            }
            .accessibilityIdentifier("setup.github.workspace.\(workspace.rawValue).owner")
            if !repositories.isEmpty {
                Text("Allowed repositories").font(.caption.weight(.semibold))
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(repositories) { repository in
                        Toggle(repository.fullName, isOn: repositoryBinding(for: workspace, repositoryID: repository.id))
                            .toggleStyle(.checkbox)
                            .accessibilityIdentifier("setup.github.workspace.\(workspace.rawValue).repository.\(repository.id)")
                    }
                }
                .padding(.leading, 4)
                Picker("Verification repository", selection: draftBinding(for: workspace).verificationRepositoryID) {
                    Text("Choose a selected repository").tag(Int?.none)
                    ForEach(repositories.filter { draft.repositoryIDs.contains($0.id) }) { repository in
                        Text(repository.fullName).tag(Optional(repository.id))
                    }
                }
                .accessibilityIdentifier("setup.github.workspace.\(workspace.rawValue).verification")
                Picker("Access mode", selection: draftBinding(for: workspace).accessMode) {
                    Text("Read-only").tag("read-only")
                    Text("Read + write").tag("read-write")
                }
                .accessibilityIdentifier("setup.github.workspace.\(workspace.rawValue).access")
                Text(draft.accessMode == "read-write"
                    ? "Write access is a separate host grant and requires explicit approval."
                    : "This workspace receives read-only repository access.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if draft.installationID != nil {
                Text("No repositories are available for this installation.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).stroke(.quaternary, lineWidth: 1)
        }
        .accessibilityIdentifier("setup.github.workspace.\(workspace.rawValue)")
    }

    private var reviewCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Review and apply").font(.headline)
            Text("Review every workspace. Assigned workspaces receive the grant shown below; unconfigured workspaces remain unchanged.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(Workspace.ID.allCases, id: \.rawValue) { workspace in
                reviewLine(for: workspace)
            }
            HStack {
                Button("Back") { isReviewing = false }
                Button(isAuthorizing ? "Applying…" : "Apply assignments") { commitAssignments() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isAuthorizing || !hasValidAssignments)
                    .accessibilityIdentifier("setup.github.apply.button")
            }
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("setup.github.review")
    }

    private func reviewLine(for workspace: Workspace.ID) -> some View {
        let draft = drafts[workspace.rawValue] ?? .initial(workspace)
        guard isReviewable(draft),
              let installationID = draft.installationID,
              let installation = installations.first(where: { $0.id == installationID }) else {
            let hasExistingAccess = existingMetadata.contains { $0.workspace == workspace.rawValue }
            return AnyView(
                Text("\(workspace.rawValue): \(hasExistingAccess ? "Existing access remains unchanged" : "Not configured — no grant will be created")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("setup.github.review.\(workspace.rawValue)")
            )
        }
        let repositories = repositoriesByInstallation[installationID] ?? []
        let selected = repositories.filter { draft.repositoryIDs.contains($0.id) }
        let verification = selected.first(where: { $0.id == draft.verificationRepositoryID })?.fullName ?? "Unknown"
        return AnyView(
            Text("\(workspace.rawValue): owner \(installation.displayName) · repositories \(selected.map(\.fullName).joined(separator: ", ")) · verification \(verification) · \(draft.accessMode == "read-write" ? "Read + write" : "Read-only")")
                .font(.caption)
                .accessibilityIdentifier("setup.github.review.\(workspace.rawValue)")
        )
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
                Label(error, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
            } else if let notice {
                Label(notice, systemImage: "info.circle.fill").foregroundStyle(.secondary)
            } else if hostIntegrationNeedsPackagedBuild {
                Label("Install a complete signed MSW Monitor build to continue.", systemImage: "lock.circle.fill")
                    .foregroundStyle(.orange)
            } else if !blockingChecks.isEmpty {
                Label("Resolve the highlighted checks to continue.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else if state.phase == .complete && systemReady {
                Label("System setup is complete. GitHub can be connected now or later.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label("Continue verifies workspaces, then restores their prior state.", systemImage: "info.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .lineLimit(3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("setup.status")
        .accessibilityValue(error ?? notice ?? (state.phase == .complete && systemReady ? "Ready." : "Continue verifies workspaces, then restores their prior state."))
    }

    private var footerActions: some View {
        HStack(spacing: 10) {
            if canFinishWithoutGitHub {
                Button("Finish without GitHub", action: finishWithoutGitHub)
                    .accessibilityIdentifier("setup.github.skip.button")
            }
            Button(isChecking ? "Checking…" : "Retry", action: loadPreflight)
                .disabled(isChecking || isRunning || coordinator == nil)
                .accessibilityIdentifier("setup.retry.button")
            if hostIntegrationNeedsPackagedBuild {
                Label("Install a complete signed build", systemImage: "lock.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("setup.signed-build.required")
            } else {
                Button(isChecking ? "Checking…" : (blockingChecks.isEmpty ? "Continue" : "Repair & Continue"), action: runSetup)
                    .buttonStyle(.borderedProminent)
                    .disabled(isRunning || coordinator == nil || isChecking || checks.isEmpty)
                    .accessibilityIdentifier("setup.primary-action")
            }
        }
        .fixedSize()
    }

    private var validDrafts: [WorkspaceAssignmentDraft] {
        drafts.values.filter(isReviewable).sorted { $0.workspace.rawValue < $1.workspace.rawValue }
    }

    private var groupedExistingMetadata: [(
        workspace: String,
        accessModes: [String],
        repositoryNames: [String],
        states: [String],
        needsAttention: Bool
    )] {
        Dictionary(grouping: existingMetadata, by: \.workspace)
            .map { workspace, entries in
                let states = Array(Set(entries.map { $0.recoveryState.rawValue })).sorted()
                return (
                    workspace: workspace,
                    accessModes: Array(Set(entries.map(\.accessMode))).sorted(),
                    repositoryNames: Array(Set(entries.flatMap { $0.repositoryNames })).sorted(),
                    states: states,
                    needsAttention: entries.contains { $0.recoveryState != .ready || $0.quarantined }
                )
    }
            .sorted { $0.workspace < $1.workspace }
    }

    private var hasValidAssignments: Bool { !validDrafts.isEmpty }

    private func isReviewable(_ draft: WorkspaceAssignmentDraft) -> Bool {
        guard draft.enabled,
              let installationID = draft.installationID,
              let verificationID = draft.verificationRepositoryID,
              let repositories = repositoriesByInstallation[installationID] else {
            return false
        }
        let selected = repositories.filter { draft.repositoryIDs.contains($0.id) }
        return !selected.isEmpty &&
            selected.count == draft.repositoryIDs.count &&
            selected.contains { $0.id == verificationID }
    }

    private func draftBinding(for workspace: Workspace.ID) -> Binding<WorkspaceAssignmentDraft> {
        Binding(
            get: { drafts[workspace.rawValue] ?? .initial(workspace) },
            set: { drafts[workspace.rawValue] = $0 }
        )
    }

    private func repositoryBinding(for workspace: Workspace.ID, repositoryID: Int) -> Binding<Bool> {
        Binding(
            get: { drafts[workspace.rawValue]?.repositoryIDs.contains(repositoryID) == true },
            set: { selected in
                var draft = drafts[workspace.rawValue] ?? .initial(workspace)
                if selected {
                    draft.repositoryIDs.insert(repositoryID)
                } else {
                    draft.repositoryIDs.remove(repositoryID)
                    if draft.verificationRepositoryID == repositoryID {
                        draft.verificationRepositoryID = nil
                    }
                }
                drafts[workspace.rawValue] = draft
            }
        )
    }
    private func selectInstallation(for workspace: Workspace.ID, installationID: Int?) {
        var draft = drafts[workspace.rawValue] ?? .initial(workspace)
        if draft.installationID != installationID {
            draft.installationID = installationID
            draft.repositoryIDs = []
            draft.verificationRepositoryID = nil
            drafts[workspace.rawValue] = draft
        }
        loadRepositories(for: workspace, installationID: installationID)
    }


    private func beginAuthorization() {
        guard let authorizationCoordinator else {
            authorizationStatus = "GitHub authorization is unavailable in this build."
            return
        }
        cancelAuthorization()
        drafts = Dictionary(uniqueKeysWithValues: Workspace.ID.allCases.map {
            ($0.rawValue, WorkspaceAssignmentDraft.initial($0))
        })
        isAuthorizing = true
        isReviewing = false
        authorizationStatus = "Opening MSW Connect in the system browser…"
        let browser = MSWConnectBrowser()
        authorizationTask = Task {
            do {
                let discovery = try await authorizationCoordinator.beginAuthorization(browser: browser)
                let installURL = await authorizationCoordinator.installationURL()
                await MainActor.run {
                    account = discovery.account
                    installations = discovery.installations
                    githubInstallationURL = installURL
                    authorizationSessionID = discovery.sessionID
                    isAuthorizing = false
                    authorizationTask = nil
                    authorizationStatus = "Connected as @\(discovery.account.login). Assign repositories to each workspace, then review before applying."
                    seedInstallations()
                }
            } catch {
                await MainActor.run {
                    isAuthorizing = false
                    authorizationTask = nil
                    authorizationStatus = error.localizedDescription
                }
            }
        }
    }

    private func loadRepositories(for workspace: Workspace.ID, installationID: Int?) {
        guard let authorizationCoordinator,
              let sessionID = authorizationSessionID,
              let installationID else {
            return
        }
        if repositoriesByInstallation[installationID] != nil { return }
        isAuthorizing = true
        authorizationStatus = "Loading repositories allowed by the selected installation…"
        authorizationTask?.cancel()
        authorizationTask = Task {
            do {
                let repositories = try await authorizationCoordinator.repositories(sessionID: sessionID, installationID: installationID)
                await MainActor.run {
                    repositoriesByInstallation[installationID] = repositories
                    isAuthorizing = false
                    authorizationTask = nil
                    authorizationStatus = "Select the repositories for each workspace."
                }
            } catch {
                await MainActor.run {
                    isAuthorizing = false
                    authorizationTask = nil
                    authorizationStatus = error.localizedDescription
                }
            }
        }
    }

    private func seedInstallations() {
        guard let first = installations.first else { return }
        for workspace in Workspace.ID.allCases {
            var draft = drafts[workspace.rawValue] ?? .initial(workspace)
            if draft.installationID == nil { draft.installationID = first.id }
            drafts[workspace.rawValue] = draft
        }
        loadRepositories(for: .dev, installationID: first.id)
    }

    private func commitAssignments() {
        guard let authorizationCoordinator,
              let sessionID = authorizationSessionID else {
            authorizationStatus = "Connect GitHub before applying workspace assignments."
            return
        }
        let assignments: [GitHubWorkspaceAssignment] = validDrafts.compactMap { draft in
            guard let installationID = draft.installationID,
                  let verificationID = draft.verificationRepositoryID,
                  let repositories = repositoriesByInstallation[installationID],
                  let verification = repositories.first(where: { $0.id == verificationID }) else { return nil }
            let selected = repositories.filter { draft.repositoryIDs.contains($0.id) }
            return GitHubWorkspaceAssignment(
                workspace: draft.workspace.rawValue,
                owner: installations.first(where: { $0.id == installationID })?.account.login ?? verification.owner.login,
                installationID: installationID,
                repositoryIDs: selected.map(\.id),
                repositoryNames: selected.map(\.fullName),
                accessMode: draft.accessMode,
                verificationRepository: verification.fullName
            )
        }
        guard assignments.count == validDrafts.count else {
            authorizationStatus = "Choose a selected verification repository for every assigned workspace."
            return
        }
        isAuthorizing = true
        authorizationStatus = "Applying and verifying the reviewed workspace grants…"
        authorizationTask?.cancel()
        authorizationTask = Task {
            do {
                let metadata = try await authorizationCoordinator.commitAssignments(sessionID: sessionID, assignments: assignments)
                let refreshed = await authorizationCoordinator.metadata()
                await MainActor.run {
                    existingMetadata = refreshed
                    isAuthorizing = false
                    authorizationTask = nil
                    authorizationSessionID = nil
                    isReviewing = false
                    authorizationStatus = "Applied \(metadata.count) workspace grant records. Each grant is independently scoped and renewable."
                }
            } catch {
                await MainActor.run {
                    isAuthorizing = false
                    authorizationTask = nil
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
        authorizationSessionID = nil
        account = nil
        installations = []
        githubInstallationURL = nil
        repositoriesByInstallation = [:]
        isReviewing = false
    }

    private func removeWorkspace(_ workspace: String) {
        guard let authorizationCoordinator else { return }
        isAuthorizing = true
        authorizationStatus = "Revoking \(workspace) workspace access…"
        authorizationTask = Task {
            do {
                try await authorizationCoordinator.removeWorkspace(workspace)
                let refreshed = await authorizationCoordinator.metadata()
                await MainActor.run {
                    existingMetadata = refreshed
                    isAuthorizing = false
                    authorizationTask = nil
                    authorizationStatus = "Removed \(workspace) workspace access."
                }
            } catch {
                await MainActor.run {
                    isAuthorizing = false
                    authorizationTask = nil
                    authorizationStatus = error.localizedDescription
                }
            }
        }
    }

    private func disconnectGitHub() {
        guard let authorizationCoordinator else { return }
        isAuthorizing = true
        authorizationStatus = "Revoking all workspace grants…"
        authorizationTask = Task {
            do {
                try await authorizationCoordinator.disconnectAccount()
                await MainActor.run {
                    existingMetadata = []
                    account = nil
                    authorizationSessionID = nil
                    isAuthorizing = false
                    authorizationTask = nil
                    authorizationStatus = "GitHub disconnected."
                }
            } catch {
                await MainActor.run {
                    isAuthorizing = false
                    authorizationTask = nil
                    authorizationStatus = error.localizedDescription
                }
            }
        }
    }
    private func openGitHubInstallation() {
        guard let githubInstallationURL else { return }
        NSWorkspace.shared.open(githubInstallationURL)
    }


    private func loadExistingMetadata() async {
        guard let authorizationCoordinator else { return }
        existingMetadata = await authorizationCoordinator.metadata()
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
