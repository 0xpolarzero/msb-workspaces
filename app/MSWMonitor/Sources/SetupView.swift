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

private struct WorkspaceAssignmentDraft: Codable, Equatable, Identifiable {
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

private struct SetupResumeState: Codable {
    var drafts: [String: WorkspaceAssignmentDraft]
    var githubSkipped: Bool
    var identityName: String
    var identityEmail: String
    var identityTarget: String
    var identityConfiguredWorkspaces: Set<String>
    var identitySkipped: Bool
    var verificationResults: [GitHubWorkspaceVerificationResult]
}

private enum AuthorizationIssueKind: String {
    case cancelled
    case expired
    case denied
    case unavailable
    case failed
}

private struct AuthorizationIssue: Identifiable {
    let kind: AuthorizationIssueKind
    let message: String
    var id: String { kind.rawValue }
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
    @State private var authorizationMayCancel = false
    @State private var isReviewing = false
    @State private var authorizationTask: Task<Void, Never>?
    @State private var authorizationIssue: AuthorizationIssue?
    @State private var verificationResults: [GitHubWorkspaceVerificationResult] = []
    @State private var githubSkipped = false
    @State private var identityName = ""
    @State private var identityEmail = ""
    @State private var identityTarget = "all"
    @State private var identityConfiguredWorkspaces: Set<String> = []
    @State private var identitySkipped = false
    @State private var isSavingIdentity = false
    @State private var identityStatus = ""
    @State private var isFinalReview = false

    private static let resumeStateKey = "setup.resume.nonsecret.v1"

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Set up MSW Monitor").font(.largeTitle.weight(.semibold))
                Text("A resumable, reviewed setup for this Mac, three isolated workspaces, and optional GitHub access.")
                    .foregroundStyle(.secondary)
                setupOverview
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    setupProgress
                    requirementsCard
                    preflight
                    Divider()
                    githubBoundary
                    Divider()
                    identitySection
                    if isFinalReview {
                        Divider()
                        finalReview
                    }
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
            restoreResumeState()
            loadPreflight()
            await loadExistingMetadata()
            await restoreCachedAuthorization()
        }
        .onDisappear { pauseAuthorization() }
        .onChange(of: drafts) { _, _ in persistResumeState() }
        .onChange(of: githubSkipped) { _, _ in persistResumeState() }
        .onChange(of: identityName) { _, _ in persistResumeState() }
        .onChange(of: identityEmail) { _, _ in persistResumeState() }
        .onChange(of: identityTarget) { _, _ in persistResumeState() }
        .onChange(of: identityConfiguredWorkspaces) { _, _ in persistResumeState() }
        .onChange(of: identitySkipped) { _, _ in persistResumeState() }
        .onChange(of: verificationResults) { _, _ in persistResumeState() }
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

    private var setupPhases: [MSWBootstrapState.Phase] {
        [.preflight, .toolchain, .hostIntegration, .workspaces, .github, .identity, .complete]
    }

    private var githubDecisionMade: Bool {
        githubSkipped || !existingMetadata.isEmpty || !verificationResults.isEmpty
    }

    private var identityDecisionMade: Bool {
        identitySkipped || Set(Workspace.ID.allCases.map(\.rawValue)).isSubset(of: identityConfiguredWorkspaces)
    }

    private var verificationAllowsCompletion: Bool {
        verificationResults.allSatisfy { $0.verified && $0.lifecycleRestored } &&
            existingMetadata.allSatisfy { $0.recoveryState == .ready && !$0.quarantined }
    }

    private var canCompleteReview: Bool {
        canFinishWithoutGitHub && githubDecisionMade && identityDecisionMade && verificationAllowsCompletion
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

    private var setupProgress: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Setup progress").font(.title3.weight(.semibold))
                Spacer()
                if state.completedPhases.isEmpty && state.startedAt == nil {
                    Text("Not started").foregroundStyle(.secondary)
                } else if state.phase == .complete {
                    Text("System verified").foregroundStyle(.green)
                } else {
                    Text("Current: \(label(for: state.phase))").foregroundStyle(.secondary)
                }
            }
            ForEach(Array(setupPhases.enumerated()), id: \.element) { index, phase in
                let complete = phaseIsComplete(phase)
                let current = phaseIsCurrent(phase)
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Image(systemName: complete ? "checkmark.circle.fill" : (current ? "circle.inset.filled" : "circle"))
                        .foregroundStyle(complete ? .green : (current ? Color.accentColor : .secondary))
                        .accessibilityHidden(true)
                    Text("Step \(index + 1): \(label(for: phase))")
                        .font(.callout.weight(current ? .semibold : .regular))
                    Spacer()
                    if current {
                        Text(guidance(for: phase)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Step \(index + 1), \(label(for: phase)), \(complete ? "complete" : (current ? "current" : "pending"))")
                .accessibilityIdentifier("setup.phase.\(phase.rawValue)")
            }
            if let startedAt = state.startedAt, state.phase != .complete {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("Elapsed \(durationLabel(context.date.timeIntervalSince(startedAt))). Closing this window pauses the view, not the saved setup state.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("setup.elapsed")
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("setup.progress")
    }

    private var requirementsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Before continuing").font(.title3.weight(.semibold))
            Label("Apple Silicon Mac running macOS 26 or later, with at least 20 GiB free; 16 GiB memory is recommended.", systemImage: "desktopcomputer")
            Label("A complete signed build may request macOS approval for its host helper. Setup never hides an administrator prompt in Terminal.", systemImage: "lock.shield")
            Label("MSW installs an app-managed signed toolchain when available; a supported local source installer is the recovery path for development builds.", systemImage: "hammer")
            Label("GitHub is optional. Connecting requires the system browser, network access, and an installed MSW GitHub App for each chosen owner.", systemImage: "safari")
            Text("Deep verification may temporarily start workspaces and run test containers. It restores their prior lifecycle before setup can be completed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup.requirements")
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
                    Text(githubIdentityDisclosure(account))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Each workspace is a separate trust domain. Assign is off until you deliberately enable it; no owner or repository is selected automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Connect through the system browser. MSW requests identity (login, display name, and public email when available) plus access only to repositories installed for the selected owner. No grant is created until you review and apply workspace assignments.")
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
                    Button("Manage connected account in Settings", action: openSettings)
                        .disabled(isAuthorizing)
                }

                if isAuthorizing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(authorizationStatus).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if authorizationMayCancel {
                            Button("Cancel wait", action: pauseAuthorization)
                                .keyboardShortcut(.cancelAction)
                                .accessibilityIdentifier("setup.github.cancel.button")
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("setup.github.progress")
                }

                if let authorizationIssue {
                    VStack(alignment: .leading, spacing: 7) {
                        Label(issueTitle(authorizationIssue.kind), systemImage: issueSymbol(authorizationIssue.kind))
                            .font(.callout.weight(.semibold))
                        Text(authorizationIssue.message).font(.caption)
                        Text(issueRecovery(authorizationIssue.kind)).font(.caption).foregroundStyle(.secondary)
                        Button("Retry GitHub authorization", action: beginAuthorization)
                            .disabled(!canConnectGitHub || isAuthorizing)
                            .accessibilityIdentifier("setup.github.retry.button")
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("setup.github.issue.\(authorizationIssue.kind.rawValue)")
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
                            Button("Manage", action: openSettings)
                                .disabled(isAuthorizing)
                        }
                    }
                }

                if !authorizationStatus.isEmpty && !isAuthorizing {
                    Text(authorizationStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .accessibilityIdentifier("setup.github.status")
                }

                if !verificationResults.isEmpty {
                    verificationResultsCard
                }

                if canFinishWithoutGitHub && account == nil && existingMetadata.isEmpty {
                    Button(githubSkipped ? "GitHub will be skipped" : "Continue without GitHub") {
                        githubSkipped = true
                        authorizationIssue = nil
                        authorizationStatus = "GitHub skipped by choice. You can connect later from Settings."
                    }
                    .disabled(githubSkipped)
                    .accessibilityIdentifier("setup.github.skip.button")
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
            if draft.enabled {
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
            }
            if draft.enabled && !repositories.isEmpty {
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
                    ? "Guest: Contents read + Metadata read. Host only: Contents read/write. The write credential is never placed in the VM."
                    : "Guest: Contents read + Metadata read. Direct VM pushes remain rejected by GitHub.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if draft.enabled && draft.installationID != nil {
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
            Text("Review the connected identity, owner, exact repository allowlist, verification repository, and guest/host permissions. Unconfigured workspaces remain unchanged.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(Workspace.ID.allCases, id: \.rawValue) { workspace in
                reviewLine(for: workspace)
            }
            HStack {
                Button("Back") { isReviewing = false }
                    .keyboardShortcut(.cancelAction)
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

    private var verificationResultsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Retained verification results").font(.headline)
            ForEach(verificationResults) { result in
                VStack(alignment: .leading, spacing: 3) {
                    Label(
                        "\(result.workspace): \(result.verified && result.lifecycleRestored ? "Verified" : "Needs recovery")",
                        systemImage: result.verified && result.lifecycleRestored
                            ? "checkmark.shield.fill" : "exclamationmark.shield.fill"
                    )
                    .foregroundStyle(result.verified && result.lifecycleRestored ? .green : .orange)
                    Text("\(result.accessMode) · \(result.verificationRepository)")
                        .font(.caption)
                    Text(result.safetyResult).font(.caption).foregroundStyle(.secondary)
                    Text("Checked \(result.checkedAt.formatted(date: .abbreviated, time: .standard))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("setup.github.verification.\(result.workspace)")
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("setup.github.verifications")
    }

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Git identity").font(.title3.weight(.semibold))
            Text("MSW writes only the reviewed Git author name and email to the selected workspaces. These fields are editable and are never inferred silently from a token.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Full name", text: $identityName)
                .textContentType(.name)
                .accessibilityLabel("Git author full name")
                .accessibilityIdentifier("setup.identity.name")
            TextField("Email", text: $identityEmail)
                .textContentType(.emailAddress)
                .accessibilityLabel("Git author email")
                .accessibilityIdentifier("setup.identity.email")
            Picker("Apply to", selection: $identityTarget) {
                Text("All three workspaces").tag("all")
                ForEach(Workspace.ID.allCases, id: \.rawValue) { workspace in
                    Text(workspace.rawValue).tag(workspace.rawValue)
                }
            }
            .accessibilityIdentifier("setup.identity.target")
            Text(identityTarget == "all"
                ? "Targets: dev, playgrounds, and personal."
                : "Target: \(identityTarget) only. Other workspace identities remain unchanged.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button(isSavingIdentity ? "Saving…" : "Save and verify identity", action: saveIdentity)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSaveIdentity || isSavingIdentity)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("setup.identity.save.button")
                Button(identitySkipped ? "Identity will be skipped" : "Skip identity for now") {
                    identitySkipped = true
                    identityStatus = "Identity skipped by choice. Configure it later in Workspace Settings."
                }
                .disabled(identitySkipped || isSavingIdentity)
                .accessibilityIdentifier("setup.identity.skip.button")
            }
            if !identityStatus.isEmpty {
                Text(identityStatus).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("setup.identity.status")
            }
            if !identityConfiguredWorkspaces.isEmpty {
                Label(
                    "Verified for \(identityConfiguredWorkspaces.sorted().joined(separator: ", "))",
                    systemImage: "checkmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(.green)
            }
        }
        .disabled(!canFinishWithoutGitHub || isRunning)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup.identity")
    }

    private var finalReview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Final review").font(.title2.weight(.semibold))
            Text("Nothing is marked complete until you review this summary and choose Done.")
                .foregroundStyle(.secondary)
            reviewStatusLine(
                title: "System and workspaces",
                value: canFinishWithoutGitHub ? "Deep setup completed and retained state is ready." : "Not verified yet.",
                ready: canFinishWithoutGitHub
            )
            reviewStatusLine(
                title: "GitHub",
                value: githubReviewSummary,
                ready: githubDecisionMade && verificationAllowsCompletion
            )
            reviewStatusLine(
                title: "Git identity",
                value: identityReviewSummary,
                ready: identityDecisionMade
            )
            HStack {
                Button("Back to setup") { isFinalReview = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Done", action: completeSetup)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canCompleteReview)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("setup.done.button")
            }
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("setup.final-review")
    }

    private func reviewStatusLine(title: String, value: String, ready: Bool) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: ready ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ready ? .green : .orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(value).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
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
                Label("System setup is verified. Review GitHub and identity choices before finishing.", systemImage: "checkmark.circle.fill")
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
            Button(isChecking ? "Checking…" : "Retry", action: loadPreflight)
                .disabled(isChecking || isRunning || coordinator == nil)
                .accessibilityIdentifier("setup.retry.button")
            if hostIntegrationNeedsPackagedBuild {
                Label("Install a complete signed build", systemImage: "lock.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("setup.signed-build.required")
            } else {
                if canFinishWithoutGitHub {
                    Button("Review setup") { isFinalReview = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(isRunning)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("setup.review.button")
                } else {
                    Button(isChecking ? "Checking…" : (blockingChecks.isEmpty ? "Continue" : "Repair & Continue"), action: runSetup)
                        .buttonStyle(.borderedProminent)
                        .disabled(isRunning || coordinator == nil || isChecking || checks.isEmpty)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("setup.primary-action")
                }
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
            authorizationIssue = AuthorizationIssue(
                kind: .unavailable,
                message: "GitHub authorization is unavailable in this build."
            )
            return
        }
        pauseAuthorization()
        isAuthorizing = true
        authorizationMayCancel = true
        isReviewing = false
        authorizationIssue = nil
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
                    authorizationMayCancel = false
                    authorizationTask = nil
                    githubSkipped = false
                    authorizationStatus = "Connected as @\(discovery.account.login). Assign repositories to each workspace, then review before applying."
                    prefillIdentity(from: discovery.account)
                }
            } catch {
                await MainActor.run {
                    isAuthorizing = false
                    authorizationMayCancel = false
                    authorizationTask = nil
                    authorizationIssue = issue(for: error)
                    authorizationStatus = ""
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
        authorizationMayCancel = true
        authorizationStatus = "Loading repositories allowed by the selected installation…"
        authorizationTask?.cancel()
        authorizationTask = Task {
            do {
                let repositories = try await authorizationCoordinator.repositories(sessionID: sessionID, installationID: installationID)
                await MainActor.run {
                    repositoriesByInstallation[installationID] = repositories
                    isAuthorizing = false
                    authorizationMayCancel = false
                    authorizationTask = nil
                    authorizationStatus = "Select the repositories for each workspace."
                }
            } catch {
                await MainActor.run {
                    isAuthorizing = false
                    authorizationMayCancel = false
                    authorizationTask = nil
                    authorizationIssue = issue(for: error)
                    authorizationStatus = ""
                }
            }
        }
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
        authorizationMayCancel = false
        authorizationIssue = nil
        authorizationStatus = "Creating reviewed grants, binding guest/host access, and verifying repository boundaries…"
        authorizationTask?.cancel()
        authorizationTask = Task {
            do {
                let result = try await authorizationCoordinator.commitAssignmentsWithVerification(
                    sessionID: sessionID,
                    assignments: assignments
                )
                let refreshed = await authorizationCoordinator.metadata()
                await MainActor.run {
                    existingMetadata = refreshed
                    verificationResults = result.verifications
                    isAuthorizing = false
                    authorizationMayCancel = false
                    authorizationTask = nil
                    authorizationSessionID = nil
                    isReviewing = false
                    authorizationStatus = "Applied \(result.metadata.count) scoped grant records. Verification results are retained below for final review."
                }
            } catch {
                let retained = await authorizationCoordinator.verificationResults()
                let refreshed = await authorizationCoordinator.metadata()
                await MainActor.run {
                    verificationResults = retained
                    existingMetadata = refreshed
                    isAuthorizing = false
                    authorizationMayCancel = false
                    authorizationTask = nil
                    authorizationIssue = issue(for: error)
                    authorizationStatus = ""
                }
            }
        }
    }

    private func pauseAuthorization() {
        guard authorizationMayCancel else {
            if isAuthorizing {
                authorizationStatus = "Applying and verification continue safely. Reopen setup to review the retained result."
            }
            return
        }
        authorizationTask?.cancel()
        authorizationTask = nil
        if isAuthorizing {
            authorizationIssue = AuthorizationIssue(
                kind: .cancelled,
                message: "The browser wait was cancelled. Existing access and saved owner/repository choices were preserved."
            )
        }
        isAuthorizing = false
        authorizationMayCancel = false
    }

    private func openGitHubInstallation() {
        guard let githubInstallationURL else { return }
        NSWorkspace.shared.open(githubInstallationURL)
    }


    private func loadExistingMetadata() async {
        guard let authorizationCoordinator else { return }
        existingMetadata = await authorizationCoordinator.metadata()
    }

    private func restoreCachedAuthorization() async {
        guard let authorizationCoordinator else { return }
        do {
            guard let discovery = try await authorizationCoordinator.resumeAuthorization() else { return }
            account = discovery.account
            installations = discovery.installations
            githubInstallationURL = await authorizationCoordinator.installationURL()
            authorizationSessionID = discovery.sessionID
            authorizationStatus = "Resumed the cached @\(discovery.account.login) authorization. Review saved choices before applying."
            prefillIdentity(from: discovery.account)
            let selectedInstallations = Set(drafts.values.compactMap(\.installationID))
            for installationID in selectedInstallations {
                do {
                    repositoriesByInstallation[installationID] = try await authorizationCoordinator.repositories(
                        sessionID: discovery.sessionID,
                        installationID: installationID
                    )
                } catch {
                    authorizationIssue = issue(for: error)
                }
            }
        } catch {
            authorizationIssue = issue(for: error)
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
            let progressTask = Task {
                while !Task.isCancelled {
                    let latest = await coordinator.state()
                    await MainActor.run { state = latest }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            defer { progressTask.cancel() }
            do {
                let result = try await coordinator.run()
                let savedState = await coordinator.state()
                let refreshedChecks = await coordinator.preflight()
                await MainActor.run {
                    state = savedState
                    checks = refreshedChecks
                    isRunning = false
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

    private func completeSetup() {
        guard canCompleteReview else { return }
        UserDefaults.standard.set(true, forKey: "setupCompleted")
        UserDefaults.standard.removeObject(forKey: Self.resumeStateKey)
        closeSetup()
    }

    private var canSaveIdentity: Bool {
        canFinishWithoutGitHub &&
            !identityName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            identityEmail.contains("@") &&
            !identityEmail.contains(where: \.isWhitespace)
    }

    private func saveIdentity() {
        guard canSaveIdentity, let authorizationCoordinator else {
            identityStatus = "Identity cannot be saved until the verified MSW runtime is available."
            return
        }
        isSavingIdentity = true
        identitySkipped = false
        identityStatus = "Applying and verifying the reviewed identity…"
        let target = identityTarget == "all" ? nil : identityTarget
        Task {
            do {
                let result = try await authorizationCoordinator.setIdentity(
                    name: identityName.trimmingCharacters(in: .whitespacesAndNewlines),
                    email: identityEmail.trimmingCharacters(in: .whitespacesAndNewlines),
                    workspace: target
                )
                await MainActor.run {
                    identityConfiguredWorkspaces.formUnion(result.workspaces)
                    isSavingIdentity = false
                    identityStatus = "Verified \(result.name) <\(result.email)> for \(result.workspaces.joined(separator: ", "))."
                }
            } catch {
                await MainActor.run {
                    isSavingIdentity = false
                    identityStatus = "Identity was not changed: \(error.localizedDescription) Retry after checking the MSW runtime."
                }
            }
        }
    }

    private var githubReviewSummary: String {
        if githubSkipped { return "Skipped by choice; no new grant will be created." }
        if !verificationResults.isEmpty {
            return verificationResults.map {
                "\($0.workspace): \($0.verified && $0.lifecycleRestored ? "verified" : "needs recovery") for \($0.verificationRepository)"
            }.joined(separator: "; ")
        }
        if !existingMetadata.isEmpty {
            return groupedExistingMetadata.map {
                "\($0.workspace): \($0.needsAttention ? "needs attention" : $0.accessModes.joined(separator: " + "))"
            }.joined(separator: "; ")
        }
        return "Choose Connect GitHub or Continue without GitHub."
    }

    private var identityReviewSummary: String {
        if identitySkipped { return "Skipped by choice; configure it later in Workspace Settings." }
        if identityConfiguredWorkspaces.isEmpty { return "Not configured yet." }
        return "Verified for \(identityConfiguredWorkspaces.sorted().joined(separator: ", "))."
    }

    private func prefillIdentity(from account: GitHubAccount) {
        if identityName.isEmpty, let name = account.name, !name.isEmpty {
            identityName = name
            identityStatus = "Name was prefilled from @\(account.login); review or edit it before saving."
        }
        if identityEmail.isEmpty, let email = account.email, !email.isEmpty {
            identityEmail = email
            identityStatus = "Name/email were prefilled from @\(account.login); review or edit them before saving."
        }
    }

    private func githubIdentityDisclosure(_ account: GitHubAccount) -> String {
        let name = account.name?.isEmpty == false ? account.name! : "not disclosed"
        let email = account.email?.isEmpty == false ? account.email! : "not disclosed"
        return "GitHub identity: @\(account.login) · name \(name) · public email \(email). Requested repository permissions are Metadata read + Contents read for guests; host Contents write is requested only when you choose Read + write."
    }

    private func issue(for error: Error) -> AuthorizationIssue {
        if let authorizationError = error as? GitHubAuthorizationError {
            switch authorizationError {
            case .authorizationCancelled:
                return AuthorizationIssue(kind: .cancelled, message: authorizationError.localizedDescription)
            case .authorizationSessionExpired:
                return AuthorizationIssue(kind: .expired, message: authorizationError.localizedDescription)
            case .authorizationDenied:
                return AuthorizationIssue(kind: .denied, message: authorizationError.localizedDescription)
            case .serviceUnavailable, .ownerNotInstalled:
                return AuthorizationIssue(kind: .unavailable, message: authorizationError.localizedDescription)
            default:
                return AuthorizationIssue(kind: .failed, message: authorizationError.localizedDescription)
            }
        }
        if error is CancellationError {
            return AuthorizationIssue(
                kind: .cancelled,
                message: "GitHub authorization was cancelled. Saved choices and existing access were preserved."
            )
        }
        return AuthorizationIssue(kind: .failed, message: error.localizedDescription)
    }

    private func issueTitle(_ kind: AuthorizationIssueKind) -> String {
        switch kind {
        case .cancelled: return "Authorization cancelled"
        case .expired: return "Authorization expired"
        case .denied: return "Authorization denied"
        case .unavailable: return "Authorization unavailable"
        case .failed: return "Authorization failed"
        }
    }

    private func issueSymbol(_ kind: AuthorizationIssueKind) -> String {
        switch kind {
        case .cancelled: return "pause.circle.fill"
        case .expired: return "clock.badge.exclamationmark.fill"
        case .denied: return "hand.raised.fill"
        case .unavailable: return "wifi.exclamationmark"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private func issueRecovery(_ kind: AuthorizationIssueKind) -> String {
        switch kind {
        case .cancelled: return "Retry when ready; no cached assignment or existing credential was removed."
        case .expired: return "Start a fresh browser authorization. Review the restored assignment choices again before applying."
        case .denied: return "Review the requested identity and repository permissions, then retry only if you consent."
        case .unavailable: return "Check the network, GitHub App installation, and MSW Connect availability, then retry."
        case .failed: return "Retry once. If it repeats, leave setup open and use Settings or diagnostics; existing access remains unchanged."
        }
    }

    private func persistResumeState() {
        let resume = SetupResumeState(
            drafts: drafts,
            githubSkipped: githubSkipped,
            identityName: identityName,
            identityEmail: identityEmail,
            identityTarget: identityTarget,
            identityConfiguredWorkspaces: identityConfiguredWorkspaces,
            identitySkipped: identitySkipped,
            verificationResults: verificationResults
        )
        guard let data = try? JSONEncoder().encode(resume) else { return }
        UserDefaults.standard.set(data, forKey: Self.resumeStateKey)
    }

    private func restoreResumeState() {
        guard let data = UserDefaults.standard.data(forKey: Self.resumeStateKey),
              let resume = try? JSONDecoder().decode(SetupResumeState.self, from: data) else { return }
        drafts = resume.drafts
        githubSkipped = resume.githubSkipped
        identityName = resume.identityName
        identityEmail = resume.identityEmail
        identityTarget = resume.identityTarget
        identityConfiguredWorkspaces = resume.identityConfiguredWorkspaces
        identitySkipped = resume.identitySkipped
        verificationResults = resume.verificationResults
        notice = "Resumed saved setup choices. Review them before continuing."
    }

    private func guidance(for phase: MSWBootstrapState.Phase) -> String {
        switch phase {
        case .welcome: return "Review requirements"
        case .preflight: return "Usually under 1 minute"
        case .toolchain: return "Usually 2–10 minutes"
        case .hostIntegration: return "Waiting for macOS approval if required"
        case .workspaces: return "Usually 5–20 minutes"
        case .github: return "Optional browser step"
        case .identity: return "Review name and email"
        case .complete: return "Final review"
        }
    }

    private func phaseIsComplete(_ phase: MSWBootstrapState.Phase) -> Bool {
        switch phase {
        case .github: return githubDecisionMade && verificationAllowsCompletion
        case .identity: return identityDecisionMade
        case .complete: return false
        default: return state.completedPhases.contains(phase)
        }
    }

    private func phaseIsCurrent(_ phase: MSWBootstrapState.Phase) -> Bool {
        if phase == .github {
            return canFinishWithoutGitHub && !phaseIsComplete(.github)
        }
        if phase == .identity {
            return canFinishWithoutGitHub && phaseIsComplete(.github) && !phaseIsComplete(.identity)
        }
        if phase == .complete {
            return canCompleteReview
        }
        return state.phase == phase && !phaseIsComplete(phase)
    }

    private func durationLabel(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let minutes = total / 60
        let seconds = total % 60
        return minutes > 0 ? "\(minutes)m \(seconds)s" : "\(seconds)s"
    }

    private func label(for phase: MSWBootstrapState.Phase) -> String {
        switch phase {
        case .welcome: return "Welcome"
        case .preflight: return "Preflight"
        case .toolchain: return "Tools"
        case .hostIntegration: return "Host"
        case .workspaces: return "Workspaces"
        case .github: return "GitHub"
        case .identity: return "Identity"
        case .complete: return "Final review"
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
