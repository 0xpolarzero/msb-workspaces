import AppKit
import SwiftUI

@MainActor
final class SetupWindowController {
    private let window: NSWindow

    init(
        coordinator: (any MSWBootstrapCoordinating)?,
        authorizationCoordinator: GitHubAuthorizationCoordinator? = nil,
        githubInstallationURL: URL? = nil,
        openSettings: @escaping (SettingsSection) -> Void,
        closeSetup: @escaping () -> Void = {},
        uiTestMode: Bool = false,
        uiTestStartsInReview: Bool = false,
        uiTestGitHubScenario: String? = nil,
        uiTestBootstrapReconnect: Bool = false,
        startupRecoveryBlockedReason: String? = nil,
        retryStartupRecovery: @escaping () -> Void = {}
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
                closeSetup: closeSetup,
                uiTestMode: uiTestMode,
                uiTestStartsInReview: uiTestStartsInReview,
                uiTestGitHubScenario: uiTestGitHubScenario,
                uiTestBootstrapReconnect: uiTestBootstrapReconnect,
                startupRecoveryBlockedReason: startupRecoveryBlockedReason,
                retryStartupRecovery: retryStartupRecovery
            )
        )
        window = NSWindow(contentViewController: hosting)
        window.identifier = NSUserInterfaceItemIdentifier("setup.window")
        hosting.view.setAccessibilityIdentifier("setup.window")
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

private struct WorkspaceRepositoryDraft: Codable, Equatable, Identifiable {
    let workspace: Workspace.ID
    var installationID: Int?
    var repositoryModes: [Int: GitHubRepositoryAccessMode]

    var id: Workspace.ID { workspace }

    static func initial(_ workspace: Workspace.ID) -> Self {
        Self(
            workspace: workspace,
            installationID: nil,
            repositoryModes: [:]
        )
    }
}

private struct SetupResumeState: Codable {
    var repositoryPolicy: [GitHubWorkspacePolicy]
    var repositoryPolicyApplied: Bool
    var githubSkipped: Bool
    var identityName: String
    var identityEmail: String
    var identityTarget: String
    var identityConfiguredWorkspaces: Set<String>
    var identitySkipped: Bool
    var verificationResults: [GitHubWorkspaceVerificationResult]
    var verifiedIdentityByWorkspace: [String: SetupVerifiedIdentity]?
    var disabledGitHubWorkspaces: [String]?
}

struct SetupVerifiedIdentity: Codable, Equatable {
    let name: String
    let email: String
}

enum SetupIdentityVerification {
    static func isComplete(
        requiredWorkspaces: Set<String>,
        configuredWorkspaces: Set<String>,
        verifiedByWorkspace: [String: SetupVerifiedIdentity],
        target: String,
        name: String,
        email: String
    ) -> Bool {
        let targets = target == "all" ? requiredWorkspaces : Set([target])
        guard targets.isSubset(of: configuredWorkspaces) else { return false }
        let expected = SetupVerifiedIdentity(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            email: email.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return targets.allSatisfy { verifiedByWorkspace[$0] == expected }
    }

    static func hasUnverifiedEdits(
        configuredWorkspaces: Set<String>,
        verifiedByWorkspace: [String: SetupVerifiedIdentity],
        target: String,
        name: String,
        email: String
    ) -> Bool {
        guard !configuredWorkspaces.isEmpty else { return false }
        let targets = target == "all" ? configuredWorkspaces : Set([target])
        let expected = SetupVerifiedIdentity(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            email: email.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return targets.contains { verifiedByWorkspace[$0] != expected }
    }
}

private enum AuthorizationIssueKind: String {
    case cancelled
    case expired
    case denied
    case unavailable
    case reconnect
    case failed
}

private struct AuthorizationIssue: Identifiable {
    let kind: AuthorizationIssueKind
    let message: String
    var id: String { kind.rawValue }
}

private enum SetupStep: String, CaseIterable, Identifiable {
    case readiness
    case github
    case identity
    case review

    var id: String { rawValue }

    var title: String {
        switch self {
        case .readiness: return "Readiness"
        case .github: return "GitHub"
        case .identity: return "Identity"
        case .review: return "Review"
        }
    }

    var symbol: String {
        switch self {
        case .readiness: return "checkmark.shield"
        case .github: return "person.crop.circle.badge.checkmark"
        case .identity: return "person.text.rectangle"
        case .review: return "checkmark.circle"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .readiness: return "setup.step.readiness"
        case .github: return "setup.step.github"
        case .identity: return "setup.step.identity"
        case .review: return "setup.step.review"
        }
    }
}

@MainActor
final class SetupLifecycleGate {
    private(set) var generation = 0

    /// Invalidates every previously captured lifecycle: the setup surface is
    /// gone, so no in-flight restore/verification continuation may publish.
    func invalidate() {
        generation &+= 1
    }

    /// Whether a generation captured before the first await is still current.
    func isCurrent(_ captured: Int) -> Bool {
        generation == captured
    }
}

struct SetupView: View {
    let coordinator: (any MSWBootstrapCoordinating)?
    let authorizationCoordinator: GitHubAuthorizationCoordinator?
    let openSettings: (SettingsSection) -> Void
    let closeSetup: () -> Void
    let uiTestMode: Bool
    let uiTestStartsInReview: Bool
    let uiTestGitHubScenario: String?
    let uiTestBootstrapReconnect: Bool
    let startupRecoveryBlockedReason: String?
    let retryStartupRecovery: () -> Void
    let setupLifecycle: SetupLifecycleGate
    @State private var checks: [MSWPreflightCheck] = []
    @State private var state = MSWBootstrapState.initial
    @State private var isRunning = false
    @State private var isChecking = true
    @State private var lastPreflightAt: Date?
    @State private var passedChecksExpanded = false
    @State private var requirementsExpanded = false
    @State private var advisoriesExpanded = false
    @State private var error: String?
    @State private var notice: String?

    @State private var account: GitHubAccount?
    @State private var installations: [GitHubInstallation] = []
    @State private var githubInstallationURL: URL?
    @State private var repositoriesByInstallation: [Int: [GitHubRepository]] = [:]
    @State private var drafts = Dictionary(uniqueKeysWithValues: Workspace.ID.allCases.map {
        ($0.rawValue, WorkspaceRepositoryDraft.initial($0))
    })
    @State private var editedGitHubWorkspaces: Set<String> = []
    @State private var repositoryPolicyApplied = false
    @State private var retainedRepositoryPolicy: [GitHubWorkspacePolicy] = []
    @State private var existingMetadata: [WorkspaceCredentialMetadata] = []
    @State private var authorizationSessionID: UUID?
    @State private var authorizationStatus = ""
    @State private var isAuthorizing = false
    @State private var authorizationMayCancel = false
    @State private var isReviewing = false
    @State private var authorizationTask: Task<Void, Never>?
    @State private var authorizationGeneration = 0
    @State private var uiTestAuthorizationAttempts = 0
    @State private var authorizationIssue: AuthorizationIssue?
    @State private var verificationResults: [GitHubWorkspaceVerificationResult] = []
    @State private var githubSkipped = false
    @State private var githubReconnectRequired = false
    @State private var isSkippingGitHub = false
    @State private var githubSkipTask: Task<Void, Never>?
    @State private var githubSkipGeneration = 0
    @State private var githubSkipIssue: String?
    @State private var githubSkipIssueWorkspace: String?
    @State private var disabledGitHubWorkspaces: [String] = []
    @State private var identityName = ""
    @State private var identityEmail = ""
    @State private var identityTarget = "all"
    @State private var identityConfiguredWorkspaces: Set<String> = []
    @State private var verifiedIdentityByWorkspace: [String: SetupVerifiedIdentity] = [:]

    @State private var identitySkipped = false
    @State private var isSavingIdentity = false
    @State private var identityStatus = ""
    @State private var activeStep: SetupStep = .readiness
    @State private var githubContextLoaded = false
    @State private var githubAttentionWorkspace: String?

    /// Explicit initializer keeps the setup dependencies visible at call sites.
    init(
        coordinator: (any MSWBootstrapCoordinating)?,
        authorizationCoordinator: GitHubAuthorizationCoordinator?,
        openSettings: @escaping (SettingsSection) -> Void,
        closeSetup: @escaping () -> Void,
        uiTestMode: Bool,
        uiTestStartsInReview: Bool,
        uiTestGitHubScenario: String?,
        uiTestBootstrapReconnect: Bool,
        startupRecoveryBlockedReason: String?,
        retryStartupRecovery: @escaping () -> Void,
        setupLifecycle: SetupLifecycleGate = SetupLifecycleGate()
    ) {
        self.coordinator = coordinator
        self.authorizationCoordinator = authorizationCoordinator
        self.openSettings = openSettings
        self.closeSetup = closeSetup
        self.uiTestMode = uiTestMode
        self.uiTestStartsInReview = uiTestStartsInReview
        self.uiTestGitHubScenario = uiTestGitHubScenario
        self.uiTestBootstrapReconnect = uiTestBootstrapReconnect
        self.startupRecoveryBlockedReason = startupRecoveryBlockedReason
        self.retryStartupRecovery = retryStartupRecovery
        self.setupLifecycle = setupLifecycle
    }

    private static let resumeStateKey = "setup.repository-policy.v4"

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Set up MSW Monitor")
                    .font(.largeTitle.weight(.semibold))
                Text("Complete a few quick setup steps.")
                    .foregroundStyle(.secondary)
                setupStepper
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    activeStepContent
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
            if uiTestMode {
                loadUITestState()
            } else {
                await loadGitHubStartupContext()
            }
        }
        .onDisappear {
            invalidateSetupLifecycle()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            handleSetupWindowWillClose(notification)
        }
        .onChange(of: drafts) { _, _ in
            if !uiTestMode { persistResumeState() }
        }
        .onChange(of: editedGitHubWorkspaces) { _, _ in
            if !uiTestMode { persistResumeState() }
        }
        .onChange(of: githubSkipped) { _, _ in
            if !uiTestMode { persistResumeState() }
        }
        .onChange(of: identityName) { _, _ in
            if !uiTestMode { persistResumeState() }
        }
        .onChange(of: identityEmail) { _, _ in
            if !uiTestMode { persistResumeState() }
        }
        .onChange(of: identityTarget) { _, _ in
            if !uiTestMode { persistResumeState() }
        }
        .onChange(of: identityConfiguredWorkspaces) { _, _ in
            if !uiTestMode { persistResumeState() }
        }
        .onChange(of: identitySkipped) { _, _ in
            if !uiTestMode { persistResumeState() }
        }
        .onChange(of: verificationResults) { _, _ in
            if !uiTestMode { persistResumeState() }
        }
        .onChange(of: verifiedIdentityByWorkspace) { _, _ in
            if !uiTestMode { persistResumeState() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup.root")
    }

    private func invalidateSetupLifecycle() {
        setupLifecycle.invalidate()
        pauseAuthorization()
        githubSkipTask?.cancel()
    }

    private func handleSetupWindowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window.identifier == NSUserInterfaceItemIdentifier("setup.window") else {
            return
        }
        invalidateSetupLifecycle()
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
    private var canConnectGitHub: Bool {
        if uiTestGitHubScenario == "unavailable" {
            return false
        }
        return uiTestGitHubScenario != nil ||
            (authorizationCoordinator != nil &&
             authorizationCoordinator?.isAvailable == true &&
             !isRunning)
    }

    private var systemReady: Bool {
        !checks.isEmpty && blockingChecks.isEmpty
    }

    private var canFinishWithoutGitHub: Bool {
        systemReady && state.phase == .complete
    }

    private var setupPhases: [MSWBootstrapState.Phase] {
        [.preflight, .toolchain, .hostIntegration, .workspaces, .github, .identity, .complete]
    }


    /// Pure decision, unit-tested directly: the attention banner clears only
    /// once the attention workspace's scoped grant was actually committed.
    /// An authorization discovery creates no host credential
    /// (`GitHubAuthorizationCoordinator.beginAuthorization`), and committing
    /// other workspaces leaves the attention workspace host-unreadable, so
    /// neither may clear it.
    static func attentionResolved(attentionWorkspace: String?, committedWorkspaces: [String]) -> Bool {
        guard let attentionWorkspace else { return true }
        return committedWorkspaces.contains(attentionWorkspace)
    }

    /// Pure decision, unit-tested directly: a workspace-scoped skip failure is
    /// resolved only when a successful commit actually includes the affected
    /// workspace; committing unrelated workspaces must not reopen the gates
    /// while the failed workspace stays unresolved. Dependency-missing failures
    /// (issueWorkspace nil: no coordinator, no mswClient, or no affected
    /// workspace reported) are never resolved by any commit — only by a
    /// successful skip retry.
    static func skipIssueResolved(issueWorkspace: String?, committedWorkspaces: [String]) -> Bool {
        guard let issueWorkspace else { return false }
        return committedWorkspaces.contains(issueWorkspace)
    }



    /// Show one ordinary Connect action whenever the user can begin or retry
    /// authorization. Reconnect recovery uses the same entry point rather than
    /// adding a separate first-run state or exposing credential diagnostics.
    private var showsGitHubConnectAction: Bool {
        account == nil || installations.isEmpty
    }

    private var githubDecisionMade: Bool {
        githubSkipped ||
            repositoryPolicyApplied ||
            !existingMetadata.isEmpty ||
            !verificationResults.isEmpty
    }



    private var identityDecisionMade: Bool {
        identitySkipped || SetupIdentityVerification.isComplete(
            requiredWorkspaces: Set(Workspace.ID.allCases.map(\.rawValue)),
            configuredWorkspaces: identityConfiguredWorkspaces,
            verifiedByWorkspace: verifiedIdentityByWorkspace,
            target: identityTarget,
            name: identityName,
            email: identityEmail
        )
    }

    private var identityHasUnverifiedEdits: Bool {
        guard !identitySkipped else { return false }
        return SetupIdentityVerification.hasUnverifiedEdits(
            configuredWorkspaces: identityConfiguredWorkspaces,
            verifiedByWorkspace: verifiedIdentityByWorkspace,
            target: identityTarget,
            name: identityName,
            email: identityEmail
        )
    }


    private var verificationAllowsCompletion: Bool {
        // A skip that is in flight or that failed (retryable issue) must close
        // every completion path — githubStepComplete, canCompleteReview, the
        // stepper's Identity/Review selectors, and the review status — not just
        // the footer Continue button.
        !isSkippingGitHub && githubSkipIssue == nil &&
            verificationResults.allSatisfy { $0.verified && $0.lifecycleRestored } &&
            existingMetadata.allSatisfy { $0.recoveryState == .ready && !$0.quarantined }
    }

    /// Pure decision, unit-tested directly: Review/Done stay unavailable until
    /// the restored GitHub context has finished loading, even when persisted
    /// completed choices would otherwise satisfy every other gate.
    static func allowsReviewCompletion(
        contextLoaded: Bool,
        systemReady: Bool,
        githubDecided: Bool,
        identityDecided: Bool,
        verificationsAllowCompletion: Bool
    ) -> Bool {
        contextLoaded &&
            systemReady &&
            githubDecided &&
            identityDecided &&
            verificationsAllowCompletion
    }

    private var canCompleteReview: Bool {
        Self.allowsReviewCompletion(
            contextLoaded: githubContextLoaded,
            systemReady: canFinishWithoutGitHub,
            githubDecided: githubDecisionMade,
            identityDecided: identityDecisionMade,
            verificationsAllowCompletion: verificationAllowsCompletion
        )
    }

    private var hostIntegrationNeedsPackagedBuild: Bool {
        checks.contains { $0.id == "host-integration" && $0.status == .unavailable }
    }

    @ViewBuilder
    private var activeStepContent: some View {
        if let startupRecoveryBlockedReason {
            startupRecoveryBlockedContent(startupRecoveryBlockedReason)
        } else {
            switch activeStep {
            case .readiness:
                requirementsCard
                preflight
            case .github:
                githubBoundary
            case .identity:
                identitySection
            case .review:
                finalReview
            }
        }
    }

    private func startupRecoveryBlockedContent(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Authorization recovery blocked", systemImage: "exclamationmark.octagon.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.red)
            Text("GitHub access could not be recovered after an interrupted update.")
                .font(.callout)
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Retry recovery after checking MSW Connect availability. Existing workspace access remains protected until recovery succeeds.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Retry authorization recovery", action: retryStartupRecovery)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("setup.recovery.retry.button")
                Button("Open GitHub settings") { openSettings(.github) }
                    .accessibilityIdentifier("setup.recovery.settings.button")
            }
        }
        .padding(14)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("setup.recovery-blocked")
    }

    private var setupStepper: some View {
        HStack(spacing: 0) {
            ForEach(SetupStep.allCases) { step in
                if step != .readiness {
                    Rectangle()
                        .fill(.quaternary)
                        .frame(width: 22, height: 1)
                }
                Button {
                    selectStep(step)
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: stepIsComplete(step) ? "checkmark.circle.fill" : step.symbol)
                            .font(.body.weight(.semibold))
                        Text(step.title)
                            .font(.caption.weight(activeStep == step ? .semibold : .regular))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(
                        stepIsComplete(step)
                            ? Color.green
                            : (activeStep == step ? Color.accentColor : Color.secondary)
                    )
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .disabled(!canSelectStep(step))
                .opacity(canSelectStep(step) ? 1 : 0.55)
                .accessibilityIdentifier(step.accessibilityIdentifier)
                .accessibilityValue(
                    stepIsComplete(step)
                        ? "Complete"
                        : (activeStep == step ? "Current step" : "Not available yet")
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup.stepper")
    }

    private var githubStepComplete: Bool {
        githubDecisionMade && verificationAllowsCompletion
    }

    private var identityStepComplete: Bool {
        identityDecisionMade
    }

    private func stepIsComplete(_ step: SetupStep) -> Bool {
        switch step {
        case .readiness: return canFinishWithoutGitHub
        case .github: return githubStepComplete
        case .identity: return identityStepComplete
        case .review: return canCompleteReview
        }
    }

    private func canSelectStep(_ step: SetupStep) -> Bool {
        switch step {
        case .readiness:
            return true
        case .github:
            return githubContextLoaded &&
                (canFinishWithoutGitHub || (systemReady && githubReconnectRequired))
        case .identity:
            return githubContextLoaded && canFinishWithoutGitHub && githubStepComplete
        case .review:
            return canCompleteReview
        }
    }
    private func selectStep(_ step: SetupStep) {
        guard canSelectStep(step) else { return }
        activeStep = step
    }
    private func advanceFromReadiness() {
        guard githubContextLoaded else { return }
        if canFinishWithoutGitHub || githubReconnectRequired {
            activeStep = .github
        } else {
            runSetup()
        }
    }
    private func advanceFromGitHub() {
        guard githubStepComplete, !isSkippingGitHub, githubSkipIssue == nil else { return }
        activeStep = .identity
    }

    /// "Skip GitHub" resolves reconnect-required grants before advancing.
    /// It clears only the verification blockers attributable to the disabled
    /// grant; genuinely remaining requirements continue to gate Review/Done.
    ///
    /// Fail closed when the affected access cannot be proven disabled: remain
    /// on this step with a retryable issue rather than bypassing cleanup.
    private func skipGitHub() {
        guard !githubSkipped, !isAuthorizing, !isSkippingGitHub else { return }
        let affectedWorkspace = githubReconnectRequired ? githubAttentionWorkspace : nil
        guard affectedWorkspace != nil || !githubReconnectRequired else {
            githubSkipIssue = "GitHub recovery is blocked because no affected workspace was reported. No access was changed; retry status before continuing."
            githubSkipIssueWorkspace = nil
            return
        }
        githubSkipGeneration &+= 1
        let generation = githubSkipGeneration
        isSkippingGitHub = true
        githubSkipIssue = nil
        githubSkipIssueWorkspace = nil
        let coordinator = authorizationCoordinator
        // UI fixtures never create a live host binding. Their simulated GitHub
        // state models a verified unbind so test navigation can be exercised
        // without invoking a developer's MSW runtime.
        let usesFixtureGitHubSkip = uiTestMode
        githubSkipTask = Task {
            if let affectedWorkspace, !usesFixtureGitHubSkip {
                guard let coordinator else {
                    await MainActor.run {
                        isSkippingGitHub = false
                        githubSkipTask = nil
                        githubSkipIssue = "GitHub access for \(affectedWorkspace) could not be updated. Existing access remains unchanged; reconnect \(affectedWorkspace) instead."
                        githubSkipIssueWorkspace = nil
                    }
                    return
                }
                do {
                    try await coordinator.disableWorkspaceGitHubAccess(affectedWorkspace)
                } catch {
                    // Refresh the snapshot so any quarantine applied by the
                    // failed disable dominates the gates (fail-closed).
                    let refreshedMetadata = await coordinator.metadata()
                    await MainActor.run {
                        isSkippingGitHub = false
                        githubSkipTask = nil
                        existingMetadata = refreshedMetadata
                        githubSkipIssue = "GitHub access for \(affectedWorkspace) could not be disabled safely: \(error.localizedDescription) Retry when MSW Connect is available, or reconnect GitHub instead."
                        githubSkipIssueWorkspace = affectedWorkspace
                    }
                    return
                }
            }
            var resolvedReconnect = false
            await MainActor.run {
                // The user may have pressed Back (or the window closed) while
                // the disable ran: never force navigation or claim the skip
                // from a stale or cancelled attempt.
                guard !Task.isCancelled,
                      githubSkipGeneration == generation,
                      activeStep == .github,
                      !isReviewing else {
                    isSkippingGitHub = false
                    githubSkipTask = nil
                    return
                }
                resolvedReconnect = affectedWorkspace != nil
                isSkippingGitHub = false
                githubSkipTask = nil
                githubSkipped = true
                authorizationIssue = nil
                githubAttentionWorkspace = nil
                githubReconnectRequired = false
                githubSkipIssue = nil
                githubSkipIssueWorkspace = nil
                if let affectedWorkspace {
                    if !disabledGitHubWorkspaces.contains(affectedWorkspace) {
                        disabledGitHubWorkspaces.append(affectedWorkspace)
                    }
                    // The grant is gone; drop the verification blockers that
                    // were attributable to it so the review gate can open.
                    verificationResults.removeAll { $0.workspace == affectedWorkspace }
                    existingMetadata.removeAll { $0.workspace == affectedWorkspace }
                }
                authorizationStatus = "GitHub skipped."
                activeStep = .identity
            }
            // The skip resolved a reconnect-required grant; re-run bootstrap so
            // setup reaches `.complete` (and Done enables) without an extra
            // manual "Verify workspaces now" step. A further reconnect error
            // routes back to the GitHub step for the next workspace.
            if resolvedReconnect, !Task.isCancelled {
                runSetup()
            }
        }
    }

    private func advanceFromIdentity() {
        guard identityStepComplete else { return }
        activeStep = .review
    }

    private func moveBack() {
        switch activeStep {
        case .readiness:
            break
        case .github:
            activeStep = .readiness
        case .identity:
            activeStep = .github
        case .review:
            activeStep = .identity
        }
    }

    private var requirementsCard: some View {
        DisclosureGroup(isExpanded: $requirementsExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Apple Silicon Mac running macOS 26 or later.", systemImage: "desktopcomputer")
                Label("A signed build may ask to approve its host helper in macOS settings.", systemImage: "lock.shield")
                Label("GitHub is optional and uses your default browser.", systemImage: "safari")
            }
            .padding(.top, 8)
        } label: {
            Label("What you need", systemImage: "list.bullet.clipboard")
                .font(.headline)
        }
        .accessibilityIdentifier("setup.requirements")
    }

    private var preflight: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("System readiness").font(.title3.weight(.semibold))
                Spacer()
                if isChecking { ProgressView().controlSize(.small) }
                if let lastPreflightAt {
                    Text("Checked \(verificationAge(lastPreflightAt))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
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
                    DisclosureGroup(isExpanded: $advisoriesExpanded) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(warningChecks) { check in preflightRow(check, prominent: false) }
                        }
                        .padding(.top, 8)
                    } label: {
                        Label(
                            "\(warningChecks.count) advisory \(warningChecks.count == 1 ? "check" : "checks")",
                            systemImage: "info.circle.fill"
                        )
                        .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("setup.preflight.advisory.toggle")
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
        VStack(alignment: .leading, spacing: 12) {
            Text("GitHub").font(.title3.weight(.semibold))

            if let account {
                HStack(alignment: .firstTextBaseline) {
                    Label("Connected as @\(account.login)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityIdentifier("setup.github.account")
                    if Self.validatedInstallationURL(githubInstallationURL) != nil {
                        Button("Manage repositories on GitHub", action: openGitHubInstallation)
                            .accessibilityIdentifier("setup.github.manage-repositories.button")
                    }
                }
                Text("Choose repository access for each workspace.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if account == nil {
                Text("Connect to review repository access for each workspace, or skip and connect later from Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Keep the skip path reachable whenever this step is open; match
            // the primary action's size so both buttons share one shape.
            HStack(spacing: 12) {
                if showsGitHubConnectAction {
                    Button(
                        isAuthorizing ? "Opening GitHub…" : "Connect GitHub",
                        action: beginAuthorization
                    )
                    .buttonStyle(.borderedProminent)
                    .disabled(isAuthorizing)
                    .accessibilityIdentifier("setup.github.connect.button")
                }
                Button("Skip GitHub") { skipGitHub() }
                    .buttonStyle(.bordered)
                    .disabled(githubSkipped || isAuthorizing || isSkippingGitHub || isReviewing)
                    .accessibilityIdentifier("setup.github.skip.button")
            }
            if isSkippingGitHub {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Disabling GitHub access for the affected workspace…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .contain)
            }
            if let githubSkipIssue {
                Label(githubSkipIssue, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("setup.github.skip.issue")
            }

            if account != nil {
                if installations.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("No repositories are available yet.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Manage repositories on GitHub, then connect GitHub again.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if Self.validatedInstallationURL(githubInstallationURL) != nil {
                            Button("Manage repositories on GitHub", action: openGitHubInstallation)
                                .accessibilityIdentifier("setup.github.install.button")
                        }
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                if !repositoriesByInstallation.isEmpty {
                    repositoryPolicyEditor
                }
                if isReviewing {
                    reviewCard
                }
                Button("Manage connected account in Settings") { openSettings(.github) }
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
                if case .unavailable = authorizationIssue.kind {
                    Label(authorizationIssue.message, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("setup.github.issue.unavailable")
                } else {
                    VStack(alignment: .leading, spacing: 7) {
                        Label(issueTitle(authorizationIssue.kind), systemImage: issueSymbol(authorizationIssue.kind))
                            .font(.callout.weight(.semibold))
                        LabeledContent("Cause", value: authorizationIssue.message)
                        LabeledContent("Affected", value: githubAffectedScope)
                        LabeledContent("Last checked", value: githubVerificationAge)
                        LabeledContent("Blocked", value: "Repository access")
                        Text(issueRecovery(authorizationIssue.kind)).font(.caption).foregroundStyle(.secondary)
                        authorizationIssueAction(authorizationIssue)
                    }
                    .font(.caption)
                    .padding(10)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("setup.github.issue.\(authorizationIssue.kind.rawValue)")
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

        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup.github-boundary")
    }

    @ViewBuilder
    private func authorizationIssueAction(_ issue: AuthorizationIssue) -> some View {
        switch issue.kind {
        case .unavailable:
            EmptyView()
        case .expired, .reconnect:
            if let workspace = firstReconnectWorkspace {
                Button("Reconnect \(workspace)", action: beginAuthorization)
                    .disabled(!canConnectGitHub || isAuthorizing)
                    .accessibilityIdentifier("setup.github.reconnect.button")
            } else {
                Button("Connect GitHub", action: beginAuthorization)
                    .disabled(!canConnectGitHub || isAuthorizing)
                    .accessibilityIdentifier("setup.github.connect-again.button")
            }
        case .cancelled, .denied:
            Button("Connect GitHub", action: beginAuthorization)
                .disabled(!canConnectGitHub || isAuthorizing)
                .accessibilityIdentifier("setup.github.connect-again.button")
        case .failed:
            Text("Review the reason above and your repository choices before continuing.")
                .foregroundStyle(.secondary)
        }
    }

    private var firstReconnectWorkspace: String? {
        if let githubAttentionWorkspace { return githubAttentionWorkspace }
        return Dictionary(grouping: existingMetadata, by: \.workspace)
            .keys
            .sorted()
            .first { workspace in
                GitHubWorkspaceAccessPresentation.make(
                    workspace: workspace,
                    entries: existingMetadata.filter { $0.workspace == workspace }
                ).action == .reconnect
            }
    }




    private var repositoryPolicyEditor: some View {
        RepositoryWorkspacePolicyEditor(
            installations: installations,
            repositoriesByInstallation: repositoriesByInstallation,
            drafts: $drafts,
            editedWorkspaces: $editedGitHubWorkspaces,
            disabled: isAuthorizing,
            onEdit: { repositoryPolicyApplied = false }
        )
        .accessibilityIdentifier("setup.github.repository-policy")
    }

    private var reviewCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Review and apply").font(.headline)
            Text("Review each repository-to-workspace choice. Your access is checked before it is applied.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(Workspace.ID.allCases, id: \.rawValue) { workspace in
                reviewLine(for: workspace)
            }
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("setup.github.review")
    }

    private func reviewLine(for workspace: Workspace.ID) -> some View {
        let workspacePolicy = workspacePolicy.first { $0.workspace == workspace.rawValue }
        let selected = workspacePolicy?.repositories ?? []
        if workspacePolicy != nil, selected.isEmpty {
            return AnyView(
                Text("\(workspace.rawValue): Existing access will be removed")
                    .font(.caption)
                    .accessibilityIdentifier("setup.github.review.\(workspace.rawValue)")
            )
        }
        guard !selected.isEmpty else {
            let hasExistingAccess = existingMetadata.contains { $0.workspace == workspace.rawValue }
            return AnyView(
                Text("\(workspace.rawValue): \(hasExistingAccess ? "Existing access remains unchanged" : "Not configured")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("setup.github.review.\(workspace.rawValue)")
            )
        }
        let access = selected.map { "\($0.fullName) — \($0.mode.label)" }.joined(separator: ", ")
        return AnyView(
            Text("\(workspace.rawValue): \(access)")
                .font(.caption)
                .accessibilityIdentifier("setup.github.review.\(workspace.rawValue)")
        )
    }

    private var verificationResultsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Repository access").font(.headline)
            ForEach(verificationResults) { result in
                VStack(alignment: .leading, spacing: 3) {
                    Label(
                        "\(result.workspace): \(result.verified && result.lifecycleRestored ? "Ready" : "Needs reconnecting")",
                        systemImage: result.verified && result.lifecycleRestored
                            ? "checkmark.shield.fill" : "exclamationmark.shield.fill"
                    )
                    .foregroundStyle(result.verified && result.lifecycleRestored ? .green : .orange)
                    Text(result.role == .host
                        ? GitHubRepositoryAccessMode.readWrite.label
                        : GitHubRepositoryAccessMode.readOnly.label)
                        .font(.caption)
                    Text("Checked \(result.checkedAt.formatted(date: .abbreviated, time: .standard))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if !result.verified || !result.lifecycleRestored {
                        Text("Existing \(result.workspace) access needs reconnecting.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button("Reconnect \(result.workspace)", action: beginAuthorization)
                            .disabled(!canConnectGitHub || isAuthorizing)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("setup.github.verification.\(result.workspace).\(result.role.rawValue)")
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup.github.verifications")
    }

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Git identity").font(.title3.weight(.semibold))
            Text("MSW writes the reviewed author name and email to the selected workspaces.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !canFinishWithoutGitHub {
                Label("You can enter these values now. Saving becomes available after system setup finishes.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextField("Full name", text: $identityName)
                .textContentType(.name)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Git author full name")
                .accessibilityIdentifier("setup.identity.name")
            TextField("Email", text: $identityEmail)
                .textContentType(.emailAddress)
                .textFieldStyle(.roundedBorder)
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
            HStack(spacing: 12) {
                Button(isSavingIdentity ? "Saving…" : "Save and verify identity", action: saveIdentity)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSaveIdentity || isSavingIdentity)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("setup.identity.save.button")
                Button("Skip identity for now") {
                    identitySkipped = true
                    identityStatus = "Identity skipped by choice. Configure it later in Workspace Settings."
                }
                .buttonStyle(.bordered)
                .disabled(identitySkipped || isSavingIdentity)
                .accessibilityIdentifier("setup.identity.skip.button")
            }
            if identityHasUnverifiedEdits {
                Label(
                    "Identity changed since the last verification. Save and verify again before finishing.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("setup.identity.status")
            } else if !identityStatus.isEmpty {
                Text(identityStatus).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("setup.identity.status")
            }
            if !identityConfiguredWorkspaces.isEmpty && !identityHasUnverifiedEdits {
                Label(
                    "Verified for \(identityConfiguredWorkspaces.sorted().joined(separator: ", "))",
                    systemImage: "checkmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(.green)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup.identity")
    }

    private var finalReview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ready to finish")
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("setup.final-review.title")
            Text("Your choices are ready to apply.")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("setup.final-review.summary")
            Text("Nothing is marked complete until you review this summary and choose Done.")
                .foregroundStyle(.secondary)
            reviewStatusLine(
                title: "System and workspaces",
                value: canFinishWithoutGitHub ? "Ready" : "Not verified yet",
                ready: canFinishWithoutGitHub
            )
            if !canFinishWithoutGitHub && systemReady {
                Button(isRunning ? "Verifying workspaces…" : "Verify workspaces now") {
                    runSetup()
                }
                .disabled(isRunning || coordinator == nil)
                .controlSize(.small)
                .accessibilityIdentifier("setup.review.verify.button")
            }
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
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
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

    @ViewBuilder
    private var stickyFooter: some View {
        HStack(alignment: .center, spacing: 10) {
            footerStatus
            Spacer(minLength: 12)
            footerActions
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.bar)
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
            } else if activeStep == .readiness && !blockingChecks.isEmpty {
                Label("Resolve the highlighted checks to continue.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else {
                Label(footerGuidance, systemImage: footerStatusSymbol)
                    .foregroundStyle(activeStep == .review ? .green : .secondary)
            }
        }
        .font(.caption)
        .lineLimit(3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("setup.status")
        .accessibilityValue(error ?? notice ?? footerGuidance)
    }

    private var footerGuidance: String {
        switch activeStep {
        case .readiness:
            return canFinishWithoutGitHub
                ? "System setup is verified. Continue to GitHub."
                : "Continue verifies workspaces, then restores their prior state."
        case .github:
            return githubStepComplete
                ? "GitHub choice saved. Continue to identity."
                : "Connect GitHub or skip it for now."
        case .identity:
            return identityStepComplete
                ? "Identity choice saved. Review before finishing."
                : "Save and verify identity, or skip it for now."
        case .review:
            return canCompleteReview
                ? "Everything is ready. Choose Done to finish setup."
                : "Complete the required choices before finishing."
        }
    }

    private var footerStatusSymbol: String {
        switch activeStep {
        case .readiness: return canFinishWithoutGitHub ? "checkmark.circle.fill" : "info.circle.fill"
        case .github: return githubStepComplete ? "checkmark.circle.fill" : "info.circle.fill"
        case .identity: return identityStepComplete ? "checkmark.circle.fill" : "info.circle.fill"
        case .review: return canCompleteReview ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        }
    }

    private var footerActions: some View {
        HStack(spacing: 10) {
            if activeStep != .readiness && !(activeStep == .github && isReviewing) {
                Button("Back", action: moveBack)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSkippingGitHub)
            }

            switch activeStep {
            case .readiness:
                Button(isChecking ? "Checking…" : "Retry", action: loadPreflight)
                    .disabled(isChecking || isRunning || coordinator == nil)
                    .accessibilityIdentifier("setup.retry.button")
                if hostIntegrationNeedsPackagedBuild {
                    Label("Install a complete signed build", systemImage: "lock.circle")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("setup.signed-build.required")
                } else {
                    Button(
                        isChecking
                            ? "Checking…"
                            : (canFinishWithoutGitHub ? "Continue" : (blockingChecks.isEmpty ? "Continue" : "Repair & Continue")),
                        action: advanceFromReadiness
                    )
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        isRunning ||
                            isChecking ||
                            checks.isEmpty ||
                            !githubContextLoaded ||
                            (!canFinishWithoutGitHub && coordinator == nil)
                    )
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("setup.primary-action")
                }
            case .github:
                if isReviewing {
                    Button("Back") { isReviewing = false }
                        .keyboardShortcut(.cancelAction)
                        .disabled(isSkippingGitHub)
                    Button(isAuthorizing ? "Applying…" : "Apply repository access", action: commitPolicy)
                        .buttonStyle(.borderedProminent)
                        .disabled(isAuthorizing || !hasValidAssignments || isSkippingGitHub)
                        .accessibilityIdentifier("setup.github.apply.button")
                } else {
                    if account != nil {
                        Button("Review workspace access") { isReviewing = true }
                            .buttonStyle(.borderedProminent)
                            .disabled(!hasValidAssignments || isAuthorizing || isSkippingGitHub)
                            .accessibilityIdentifier("setup.github.review.button")
                    }
                    Button("Continue", action: advanceFromGitHub)
                        .buttonStyle(.borderedProminent)
                        .disabled(!githubStepComplete || isAuthorizing || isSkippingGitHub || githubSkipIssue != nil)
                        .keyboardShortcut(.defaultAction)
                }
            case .identity:
                Button("Review setup", action: advanceFromIdentity)
                    .buttonStyle(.borderedProminent)
                    .disabled(!identityStepComplete || isSavingIdentity)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("setup.review.button")
            case .review:
                Button("Done", action: completeSetup)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canCompleteReview)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("setup.done.button")
            }
        }
        .fixedSize()
    }


    /// Only workspaces the user edited are replaced. An edited workspace with
    /// no entries deliberately removes all of its existing repository access.
    private var workspacePolicy: [GitHubWorkspacePolicy] {
        Workspace.ID.allCases.compactMap { workspace in
            guard editedGitHubWorkspaces.contains(workspace.rawValue) else { return nil }
            let draft = drafts[workspace.rawValue] ?? .initial(workspace)
            return GitHubWorkspacePolicy(
                workspace: workspace.rawValue,
                repositories: policyEntries(for: draft)
            )
        }
    }

    private func policyEntries(for draft: WorkspaceRepositoryDraft) -> [GitHubRepositoryPolicy] {
        guard let installationID = draft.installationID,
              let installation = installations.first(where: { $0.id == installationID }),
              let repositories = repositoriesByInstallation[installationID] else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: repositories.map { ($0.id, $0) })
        var result: [GitHubRepositoryPolicy] = []
        for (repositoryID, mode) in draft.repositoryModes {
            guard let repository = byID[repositoryID] else { continue }
            result.append(GitHubRepositoryPolicy(
                workspace: draft.workspace.rawValue,
                repositoryID: repository.id,
                fullName: repository.fullName,
                installationID: installation.id,
                ownerID: installation.account.id,
                ownerLogin: installation.account.login,
                ownerType: installation.account.type,
                mode: mode
            ))
        }
        return result
    }


    private var hasValidAssignments: Bool {
        !workspacePolicy.isEmpty
    }


    private func beginAuthorization() {
        if uiTestGitHubScenario == "unavailable" {
            authorizationIssue = AuthorizationIssue(
                kind: .unavailable,
                message: "GitHub could not be reached. Try again later."
            )
            authorizationStatus = ""
            return
        }
        if uiTestGitHubScenario == nil,
           authorizationCoordinator?.isAvailable != true {
            authorizationIssue = AuthorizationIssue(
                kind: .unavailable,
                message: GitHubFeatureAvailability.unavailableNotice
            )
            return
        }

        pauseAuthorization()
        authorizationGeneration &+= 1
        let generation = authorizationGeneration
        isAuthorizing = true
        authorizationMayCancel = true
        isReviewing = false
        authorizationIssue = nil
        authorizationStatus = "Opening GitHub in your default browser…"
        uiTestAuthorizationAttempts += 1

        if let scenario = uiTestGitHubScenario {
            let shouldHoldForCancellation = scenario == "cancel-retry" && uiTestAuthorizationAttempts == 1
            authorizationTask = Task {
                if shouldHoldForCancellation {
                    try? await Task.sleep(for: .seconds(30))
                } else {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                guard !Task.isCancelled else { return }
                let discovery = Self.uiTestDiscovery(
                    sessionID: Self.uiTestAuthorizationSessionID,
                    includeInstallation: scenario != "no-installation"
                )
                await MainActor.run {
                    guard authorizationGeneration == generation else { return }
                    account = discovery.account
                    installations = discovery.installations
                    githubInstallationURL = Self.validatedInstallationURL(
                        URL(string: "https://github.com/apps/msw/installations/new")
                    )
                    authorizationSessionID = discovery.sessionID
                    if let installation = discovery.installations.first {
                        repositoriesByInstallation[installation.id] = Self.uiTestRepositories
                    }
                    prefillRepositoryPolicyDrafts()
                    isAuthorizing = false
                    authorizationMayCancel = false
                    authorizationTask = nil
                    githubSkipped = false
                    authorizationStatus = discovery.installations.isEmpty
                        ? "No MSW App installation was found. Install the app, then connect GitHub again."
                        : "Choose repository access, then review before applying."
                    prefillIdentity(from: discovery.account)
                }
            }
            return
        }

        guard let authorizationCoordinator else { return }
        let browser = MSWConnectBrowser.shared
        authorizationTask = Task {
            do {
                let discovery = try await authorizationCoordinator.beginAuthorization(browser: browser)
                let installURL = await authorizationCoordinator.installationURL()
                var loadedRepositories: [Int: [GitHubRepository]] = [:]
                for installation in discovery.installations {
                    try Task.checkCancellation()
                    loadedRepositories[installation.id] = try await authorizationCoordinator.repositories(
                        sessionID: discovery.sessionID,
                        installationID: installation.id
                    )
                }
                await MainActor.run {
                    guard authorizationGeneration == generation else { return }
                    account = discovery.account
                    installations = discovery.installations
                    githubInstallationURL = Self.validatedInstallationURL(installURL)
                    authorizationSessionID = discovery.sessionID
                    repositoriesByInstallation = loadedRepositories
                    prefillRepositoryPolicyDrafts()
                    isAuthorizing = false
                    authorizationMayCancel = false
                    authorizationTask = nil
                    githubSkipped = false
                    authorizationStatus = "Choose repository access, then review before applying."
                    prefillIdentity(from: discovery.account)
                }
            } catch {
                await MainActor.run {
                    guard authorizationGeneration == generation else { return }
                    isAuthorizing = false
                    authorizationMayCancel = false
                    authorizationTask = nil
                    authorizationIssue = issue(for: error)
                    authorizationStatus = ""
                }
            }
        }
    }
    private static let uiTestAuthorizationSessionID = UUID(uuidString: "E2E00000-0000-4000-8000-000000000001")!
    private static let uiTestAccount = GitHubAccount(
        login: "octocat",
        id: 1,
        name: "Octo Cat",
        email: "octo@example.com"
    )

    private static let uiTestInstallation = GitHubInstallation(
        id: 42,
        account: GitHubInstallationAccount(login: "acme", id: 7, type: "Organization"),
        repositorySelection: "selected"
    )

    private static let uiTestRepositories = [
        GitHubRepository(
            id: 1001,
            fullName: "acme/one",
            name: "one",
            owner: GitHubInstallationAccount(login: "acme", id: 7, type: "Organization"),
            private: true,
            defaultBranch: "main"
        ),
        GitHubRepository(
            id: 1002,
            fullName: "acme/two",
            name: "two",
            owner: GitHubInstallationAccount(login: "acme", id: 7, type: "Organization"),
            private: true,
            defaultBranch: "main"
        )
    ]

    private static func uiTestDiscovery(
        sessionID: UUID,
        includeInstallation: Bool
    ) -> GitHubAuthorizationDiscovery {
        GitHubAuthorizationDiscovery(
            sessionID: sessionID,
            account: uiTestAccount,
            installations: includeInstallation ? [uiTestInstallation] : []
        )
    }

    private func commitPolicy() {
        let workspacePolicies = workspacePolicy
        guard !workspacePolicies.isEmpty else {
            authorizationStatus = "Choose a workspace to update."
            return
        }
        let policy = workspacePolicies.flatMap { $0.repositories }

        authorizationGeneration &+= 1
        let generation = authorizationGeneration
        isAuthorizing = true
        authorizationMayCancel = false
        authorizationIssue = nil
        authorizationStatus = "Applying repository access…"
        authorizationTask?.cancel()

        if uiTestGitHubScenario != nil {
            authorizationTask = Task {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
                let partitions = Dictionary(grouping: policy, by: { "\($0.workspace).\($0.installationID)" })
                let verifications = partitions.values.flatMap { scope -> [GitHubWorkspaceVerificationResult] in
                    guard let first = scope.first else { return [] }
                    let readVerification = scope.sorted { $0.fullName.lowercased() < $1.fullName.lowercased() }[0]
                    var results = [GitHubWorkspaceVerificationResult(
                        workspace: first.workspace,
                        installationID: first.installationID,
                        role: .guest,
                        accessMode: "read-only",
                        verificationRepository: readVerification.fullName,
                        verified: true,
                        lifecycleRestored: true,
                        safetyResult: "Repository scope and workspace lifecycle verified.",
                        checkedAt: Date()
                    )]
                    let writeScope = scope.filter { $0.mode == .readWrite }
                        .sorted { $0.fullName.lowercased() < $1.fullName.lowercased() }
                    if let writeVerification = writeScope.first {
                        results.append(GitHubWorkspaceVerificationResult(
                            workspace: first.workspace,
                            installationID: first.installationID,
                            role: .host,
                            accessMode: "host-write",
                            verificationRepository: writeVerification.fullName,
                            verified: true,
                            lifecycleRestored: true,
                            safetyResult: "Repository scope and workspace lifecycle verified.",
                            checkedAt: Date()
                        ))
                    }
                    return results
                }
                await MainActor.run {
                    guard authorizationGeneration == generation else { return }
                    existingMetadata = []
                    verificationResults = verifications
                    isAuthorizing = false
                    authorizationMayCancel = false
                    authorizationTask = nil
                    // A successful commit reconnects the committed workspaces:
                    // a skip failure clears only when the affected workspace
                    // itself was committed (never on unrelated commits, and
                    // dependency-missing failures never clear here), the
                    // committed workspaces leave the disabled list, and once
                    // every disabled workspace is reconnected the step stops
                    // reporting as skipped.
                    if Self.skipIssueResolved(
                        issueWorkspace: githubSkipIssueWorkspace,
                        committedWorkspaces: workspacePolicies.map(\.workspace)
                    ) {
                        githubSkipIssue = nil
                        githubSkipIssueWorkspace = nil
                    }
                    if !disabledGitHubWorkspaces.isEmpty {
                        disabledGitHubWorkspaces.removeAll { workspace in
                            workspacePolicies.contains { $0.workspace == workspace }
                        }
                        if disabledGitHubWorkspaces.isEmpty {
                            githubSkipped = false
                        }
                    }
                    if Self.attentionResolved(
                        attentionWorkspace: githubAttentionWorkspace,
                        committedWorkspaces: workspacePolicies.map(\.workspace)
                    ) {
                        githubAttentionWorkspace = nil
                    }
                    repositoryPolicyApplied = true
                    authorizationSessionID = nil
                    isReviewing = false
                    authorizationStatus = "Applied repository access for \(workspacePolicies.count) workspace(s)."
                }
            }
            return
        }

        guard let authorizationCoordinator,
              let sessionID = authorizationSessionID else {
            authorizationStatus = "Connect GitHub before applying repository access."
            isAuthorizing = false
            return
        }
        authorizationTask = Task {
            do {
                let result = try await authorizationCoordinator.commitPolicyWithVerification(
                    sessionID: sessionID,
                    policy: workspacePolicies
                )
                let refreshed = await authorizationCoordinator.metadata()
                await MainActor.run {
                    guard authorizationGeneration == generation else { return }
                    existingMetadata = refreshed
                    verificationResults = result.verifications
                    isAuthorizing = false
                    authorizationMayCancel = false
                    authorizationTask = nil
                    // A successful commit reconnects the committed workspaces:
                    // a skip failure clears only when the affected workspace
                    // itself was committed (never on unrelated commits, and
                    // dependency-missing failures never clear here), the
                    // committed workspaces leave the disabled list, and once
                    // every disabled workspace is reconnected the step stops
                    // reporting as skipped.
                    if Self.skipIssueResolved(
                        issueWorkspace: githubSkipIssueWorkspace,
                        committedWorkspaces: workspacePolicies.map(\.workspace)
                    ) {
                        githubSkipIssue = nil
                        githubSkipIssueWorkspace = nil
                    }
                    if !disabledGitHubWorkspaces.isEmpty {
                        disabledGitHubWorkspaces.removeAll { workspace in
                            workspacePolicies.contains { $0.workspace == workspace }
                        }
                        if disabledGitHubWorkspaces.isEmpty {
                            githubSkipped = false
                        }
                    }
                    if Self.attentionResolved(
                        attentionWorkspace: githubAttentionWorkspace,
                        committedWorkspaces: workspacePolicies.map(\.workspace)
                    ) {
                        githubAttentionWorkspace = nil
                    }
                    repositoryPolicyApplied = true
                    authorizationSessionID = nil
                    isReviewing = false
                }
            } catch {
                let retained = await authorizationCoordinator.verificationResults()
                let refreshed = await authorizationCoordinator.metadata()
                await MainActor.run {
                    guard authorizationGeneration == generation else { return }
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
        authorizationGeneration &+= 1
        authorizationTask?.cancel()
        authorizationTask = nil
        if isAuthorizing {
            authorizationIssue = AuthorizationIssue(
                kind: .cancelled,
                message: "GitHub connection was cancelled. Existing access and saved repository choices were preserved."
            )
        }
        authorizationStatus = "GitHub connection cancelled."
        isAuthorizing = false
        authorizationMayCancel = false
    }

    private static func validatedInstallationURL(_ value: URL?) -> URL? {
        guard let value,
              value.scheme?.lowercased() == "https",
              value.host?.lowercased() == "github.com",
              value.user == nil,
              value.password == nil,
              value.port == nil,
              value.query == nil,
              value.fragment == nil else {
            return nil
        }
        let path = value.path
        guard path.hasPrefix("/apps/"),
              path.hasSuffix("/installations/new"),
              !path.contains("?"),
              !path.contains("#"),
              !path.contains(".."),
              !path.contains("//"),
              path.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            return nil
        }
        return value
    }

    private func openGitHubInstallation() {
        guard let githubInstallationURL = Self.validatedInstallationURL(githubInstallationURL) else {
            return
        }
        NSWorkspace.shared.open(githubInstallationURL)
    }


    /// Loads existing grant metadata. The startup lifecycle token is carried
    /// in (captured at the outermost `.task` entry): the metadata read may
    /// finish after a close, but the publication happens only while the token
    /// is still current. Returns the metadata when published, nil when the
    /// close suppressed it — the deterministic startup-close tests assert the
    /// suppression directly.
    @discardableResult
    func loadExistingMetadata(startupLifecycle: Int) async -> [WorkspaceCredentialMetadata]? {
        guard let authorizationCoordinator else { return nil }
        let metadata = authorizationCoordinator.isAvailable
            ? await authorizationCoordinator.metadata()
            : await authorizationCoordinator.retainedMetadata()
        guard setupLifecycle.isCurrent(startupLifecycle) else { return nil }
        existingMetadata = metadata
        return metadata
    }

    /// Restores the cached MSW Connect authorization. The startup lifecycle
    /// token is carried in and re-checked after EVERY await before any UI
    /// publication — a close during `resumeAuthorization`, the installation
    /// URL read, or a repository listing suppresses the corresponding
    /// account/installations/status/identity/repository/error mutations
    /// (the outer chain guard alone would run too late). Returns the
    /// discovery when published, nil when the close suppressed it.
    @discardableResult
    func restoreCachedAuthorization(startupLifecycle: Int) async -> GitHubAuthorizationDiscovery? {
        guard let authorizationCoordinator else { return nil }
        // An unconfigured build cannot use or validate a stored session;
        // restoration is deferred to a configured build. Sessions are never
        // deleted by configuration mismatches.
        guard authorizationCoordinator.isAvailable else { return nil }
        do {
            guard let discovery = try await authorizationCoordinator.resumeAuthorization() else { return nil }
            // Guard after the resume await: a close during it must suppress
            // the account/installations publications below.
            guard setupLifecycle.isCurrent(startupLifecycle) else { return nil }
            account = discovery.account
            installations = discovery.installations
            let installURL = await authorizationCoordinator.installationURL()
            // Guard after the installation-URL await: never publish it
            // post-close.
            guard setupLifecycle.isCurrent(startupLifecycle) else { return nil }
            githubInstallationURL = Self.validatedInstallationURL(installURL)
            authorizationSessionID = discovery.sessionID
            authorizationStatus = "Resumed the cached @\(discovery.account.login) authorization. Review saved choices before applying."
            prefillIdentity(from: discovery.account)
            for installation in discovery.installations {
                do {
                    let repositories = try await authorizationCoordinator.repositories(
                        sessionID: discovery.sessionID,
                        installationID: installation.id
                    )
                    // Guard after the listing await: never publish a
                    // repository list post-close.
                    guard setupLifecycle.isCurrent(startupLifecycle) else { return nil }
                    repositoriesByInstallation[installation.id] = repositories
                } catch {
                    guard setupLifecycle.isCurrent(startupLifecycle) else { return nil }
                    authorizationIssue = issue(for: error)
                }
            }
            return discovery
        } catch {
            guard setupLifecycle.isCurrent(startupLifecycle) else { return nil }
            authorizationIssue = issue(for: error)
            return nil
        }
    }

    /// The startup GitHub-context chain, driven by the outermost `.task` and
    /// Loads persisted setup and the cached Connect session before enabling
    /// review. Every awaited publication is guarded against setup teardown.
    @discardableResult
    func loadGitHubStartupContext() async -> Bool {
        let startupLifecycle = setupLifecycle.generation
        restoreResumeState()
        loadPreflight()
        await loadExistingMetadata(startupLifecycle: startupLifecycle)
        guard setupLifecycle.isCurrent(startupLifecycle) else { return false }
        await restoreCachedAuthorization(startupLifecycle: startupLifecycle)
        guard setupLifecycle.isCurrent(startupLifecycle) else { return false }
        githubContextLoaded = true
        return true
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
                lastPreflightAt = Date()
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
                    lastPreflightAt = Date()
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
                    if let clientError = error as? MSWClientError,
                       case .protocolFailure(let protocolError) = clientError,
                       protocolError.code == "MSW_GITHUB_RECONNECT_REQUIRED" {
                        // No readiness warning: take the user straight to the
                        // GitHub step, where the attention state lives.
                        githubReconnectRequired = true
                        githubAttentionWorkspace = protocolError.workspace
                        // Each reconnect visit is a fresh decision cycle: a
                        // bootstrap that still fails for another workspace must
                        // re-offer the skip control instead of being blocked by
                        // a previously completed skip.
                        githubSkipped = false
                        activeStep = .github
                    } else {
                        self.error = error.localizedDescription
                    }
                }
            }
        }
    }

    private func completeSetup() {
        guard canCompleteReview else { return }
        if !uiTestMode {
            UserDefaults.standard.set(true, forKey: "setupCompleted")
            UserDefaults.standard.removeObject(forKey: Self.resumeStateKey)
        }
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
        let name = identityName.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = identityEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = identityTarget == "all" ? nil : identityTarget
        Task {
            do {
                let result = try await authorizationCoordinator.setIdentity(
                    name: name,
                    email: email,
                    workspace: target
                )
                await MainActor.run {
                    let verified = SetupVerifiedIdentity(name: name, email: email)
                    for workspace in result.workspaces {
                        verifiedIdentityByWorkspace[workspace] = verified
                    }
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
        if githubSkipped { return "Skipped." }
        if !verificationResults.isEmpty { return "Connected." }
        if !existingMetadata.isEmpty { return "Managed in Settings." }
        return "Not connected."
    }

    private var identityReviewSummary: String {
        if identitySkipped { return "Skipped by choice; configure it later in Workspace Settings." }
        if identityConfiguredWorkspaces.isEmpty { return "Not configured yet." }
        if identityHasUnverifiedEdits { return "Changed since last verification; save and verify again." }
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


    private func issue(for error: Error) -> AuthorizationIssue {
        if let authorizationError = error as? GitHubAuthorizationError {
            switch authorizationError {
            case .authorizationCancelled:
                return AuthorizationIssue(kind: .cancelled, message: authorizationError.localizedDescription)
            case .authorizationSessionExpired:
                return AuthorizationIssue(kind: .expired, message: authorizationError.localizedDescription)
            case .authorizationDenied:
                return AuthorizationIssue(kind: .denied, message: authorizationError.localizedDescription)
            case .serviceUnavailable:
                return AuthorizationIssue(kind: .unavailable, message: authorizationError.localizedDescription)
            case .ownerNotInstalled:
                return AuthorizationIssue(
                    kind: firstReconnectWorkspace == nil ? .failed : .reconnect,
                    message: authorizationError.localizedDescription
                )
            case .scopeMismatch, .reconnectRequired, .revocationFailed:
                return AuthorizationIssue(kind: .reconnect, message: authorizationError.localizedDescription)
            default:
                return AuthorizationIssue(kind: .failed, message: authorizationError.localizedDescription)
            }
        }
        if let connectError = error as? MSWConnectError {
            switch connectError {
            case .cancelled:
                return AuthorizationIssue(kind: .cancelled, message: connectError.localizedDescription)
            case .sessionExpired, .callbackExpired:
                return AuthorizationIssue(kind: .expired, message: connectError.localizedDescription)
            case .authorizationDenied:
                return AuthorizationIssue(kind: .denied, message: connectError.localizedDescription)
            case .installationUnavailable, .installationRemoved:
                return AuthorizationIssue(
                    kind: firstReconnectWorkspace == nil ? .failed : .reconnect,
                    message: connectError.localizedDescription
                )
            case .transportUnavailable, .httpStatus, .rateLimited:
                return AuthorizationIssue(kind: .unavailable, message: connectError.localizedDescription)
            default:
                return AuthorizationIssue(kind: .failed, message: connectError.localizedDescription)
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
        case .reconnect: return "Reconnect required"
        case .failed: return "Authorization failed"
        }
    }

    private func issueSymbol(_ kind: AuthorizationIssueKind) -> String {
        switch kind {
        case .cancelled: return "pause.circle.fill"
        case .expired: return "clock.badge.exclamationmark.fill"
        case .denied: return "hand.raised.fill"
        case .unavailable: return "wifi.exclamationmark"
        case .reconnect: return "arrow.triangle.2.circlepath.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private func issueRecovery(_ kind: AuthorizationIssueKind) -> String {
        switch kind {
        case .cancelled: return "Retry when ready; existing access stayed unchanged."
        case .expired: return "Connect GitHub again, then review repository access."
        case .denied: return "Review your repository choices, then try again."
        case .unavailable: return "Check your connection and try again."
        case .reconnect: return "Reconnect, then review the affected workspace and repository scope."
        case .failed: return "Try again. Existing access remains unchanged."
        }
    }

    private var githubAffectedScope: String {
        let workspaces = workspacePolicy.map(\.workspace).sorted()
        return workspaces.isEmpty ? "GitHub setup" : workspaces.joined(separator: ", ")
    }

    private var githubVerificationAge: String {
        let latest = existingMetadata.map(\.updatedAt).max()
        return latest.map(verificationAge) ?? "Never verified"
    }

    private func verificationAge(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds) seconds ago" }
        if seconds < 3_600 { return "\(seconds / 60) minutes ago" }
        if seconds < 86_400 { return "\(seconds / 3_600) hours ago" }
        return "\(seconds / 86_400) days ago"
    }

    /// Reconstructs the editor's current choices from enforced grant metadata
    /// only after the matching installation repository list is available.
    /// Anything that cannot be proved against that list stays out of the
    /// editor and is surfaced for reconnect rather than silently dropped.
    private func prefillRepositoryPolicyDrafts() {
        guard retainedRepositoryPolicy.isEmpty else { return }

        for workspace in Workspace.ID.allCases {
            guard !editedGitHubWorkspaces.contains(workspace.rawValue),
                  var draft = drafts[workspace.rawValue],
                  draft.repositoryModes.isEmpty else {
                continue
            }
            let entries = existingMetadata.filter { $0.workspace == workspace.rawValue }
            guard let guest = entries.first(where: { $0.role == .guest }),
                  let installationID = guest.installationID,
                  let installation = installations.first(where: { $0.id == installationID }),
                  let owner = guest.owner,
                  owner.caseInsensitiveCompare(installation.account.login) == .orderedSame,
                  let availableRepositories = repositoriesByInstallation[installationID],
                  guest.repositoryIDs.count == guest.repositoryNames.count,
                  guest.repositoryIDs.count == Set(guest.repositoryIDs).count else {
                if !entries.isEmpty { presentUnavailableExistingRepositoryPolicy(workspace: workspace.rawValue) }
                continue
            }

            let guestRepositoryIDs = Set(guest.repositoryIDs)
            let hostEntries = entries.filter { $0.role == .host }
            guard hostEntries.allSatisfy({
                $0.installationID == installationID &&
                    Set($0.repositoryIDs).isSubset(of: guestRepositoryIDs)
            }) else {
                presentUnavailableExistingRepositoryPolicy(workspace: workspace.rawValue)
                continue
            }

            let byID = Dictionary(uniqueKeysWithValues: availableRepositories.map { ($0.id, $0) })
            var modes: [Int: GitHubRepositoryAccessMode] = [:]
            var isCurrent = true
            for (repositoryID, repositoryName) in zip(guest.repositoryIDs, guest.repositoryNames) {
                guard let repository = byID[repositoryID],
                      repository.fullName.caseInsensitiveCompare(repositoryName) == .orderedSame else {
                    isCurrent = false
                    break
                }
                modes[repositoryID] = hostEntries.contains {
                    $0.repositoryIDs.contains(repositoryID)
                } ? .readWrite : .readOnly
            }
            guard isCurrent else {
                presentUnavailableExistingRepositoryPolicy(workspace: workspace.rawValue)
                continue
            }

            draft.installationID = installationID
            draft.repositoryModes = modes
            drafts[workspace.rawValue] = draft
        }
    }

    private func presentUnavailableExistingRepositoryPolicy(workspace: String) {
        guard authorizationIssue == nil else { return }
        authorizationIssue = AuthorizationIssue(
            kind: .reconnect,
            message: "The verified repository scope for \(workspace) no longer matches the repositories available from its GitHub App installation."
        )
    }

    private func persistResumeState() {
        let resume = SetupResumeState(
            repositoryPolicy: workspacePolicy,
            repositoryPolicyApplied: repositoryPolicyApplied,
            githubSkipped: githubSkipped,
            identityName: identityName,
            identityEmail: identityEmail,
            identityTarget: identityTarget,
            identityConfiguredWorkspaces: identityConfiguredWorkspaces,
            identitySkipped: identitySkipped,
            verificationResults: verificationResults,
            verifiedIdentityByWorkspace: verifiedIdentityByWorkspace,
            disabledGitHubWorkspaces: disabledGitHubWorkspaces
        )
        guard let data = try? JSONEncoder().encode(resume) else { return }
        UserDefaults.standard.set(data, forKey: Self.resumeStateKey)
    }

    private func restoreResumeState() {
        guard let data = UserDefaults.standard.data(forKey: Self.resumeStateKey),
              let resume = try? JSONDecoder().decode(SetupResumeState.self, from: data) else { return }
        retainedRepositoryPolicy = resume.repositoryPolicy
        drafts = Dictionary(uniqueKeysWithValues: Workspace.ID.allCases.map {
            ($0.rawValue, WorkspaceRepositoryDraft.initial($0))
        })
        editedGitHubWorkspaces = Set(resume.repositoryPolicy.map(\.workspace))
        repositoryPolicyApplied = resume.repositoryPolicyApplied
        for policy in resume.repositoryPolicy {
            guard let workspace = Workspace.ID(rawValue: policy.workspace) else { continue }
            let installationIDs = Set(policy.repositories.map(\.installationID))
            guard installationIDs.count <= 1 else { continue }
            var draft = drafts[policy.workspace] ?? .initial(workspace)
            draft.installationID = installationIDs.first
            draft.repositoryModes = Dictionary(
                uniqueKeysWithValues: policy.repositories.map { ($0.repositoryID, $0.mode) }
            )
            drafts[policy.workspace] = draft
        }
        githubSkipped = resume.githubSkipped
        identityName = resume.identityName
        identityEmail = resume.identityEmail
        identityTarget = resume.identityTarget
        identityConfiguredWorkspaces = resume.identityConfiguredWorkspaces
        verifiedIdentityByWorkspace = resume.verifiedIdentityByWorkspace ?? [:]
        identitySkipped = resume.identitySkipped
        verificationResults = resume.verificationResults
        disabledGitHubWorkspaces = resume.disabledGitHubWorkspaces ?? []
        notice = "Resumed saved setup choices. Review them before continuing."
    }
    private func loadUITestState() {
        let now = Date()
        checks = [
            MSWPreflightCheck(id: "macos-version", title: "macOS 26 or later", status: .pass, detail: "Detected macOS 26.", remediation: nil),
            MSWPreflightCheck(id: "architecture", title: "Apple Silicon", status: .pass, detail: "Detected arm64.", remediation: nil),
            MSWPreflightCheck(id: "disk-space", title: "Available disk space", status: .pass, detail: "128 GiB available; setup estimates at least 20 GiB.", remediation: nil),
            MSWPreflightCheck(id: "memory", title: "Memory budget", status: .pass, detail: "Detected 64 GiB physical memory.", remediation: nil)
        ]
        state = uiTestBootstrapReconnect
            ? MSWBootstrapState(
                phase: .workspaces,
                startedAt: now,
                updatedAt: now,
                lastError: nil,
                completedPhases: [.preflight, .toolchain, .hostIntegration]
            )
            : MSWBootstrapState(
                phase: .complete,
                startedAt: now,
                updatedAt: now,
                lastError: nil,
                completedPhases: Set(MSWBootstrapState.Phase.allCases)
            )
        lastPreflightAt = now
        isChecking = false
        if uiTestStartsInReview {
            githubSkipped = true
            identitySkipped = true
            identityStatus = "Identity skipped by choice. Configure it later in Workspace Settings."
            authorizationStatus = "GitHub skipped by choice. You can connect later from Settings."
            activeStep = .review
        } else {
            githubSkipped = false
            identitySkipped = false
            identityStatus = ""
            activeStep = .readiness
        }
        githubContextLoaded = true
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


/// The one compact repository-policy editor used by setup and reached from
/// Settings. A checkbox assigns a repository to one workspace; a selected
/// repository starts Read-only and exposes its segmented access control.
private struct RepositoryWorkspacePolicyEditor: View {
    let installations: [GitHubInstallation]
    let repositoriesByInstallation: [Int: [GitHubRepository]]
    @Binding var drafts: [String: WorkspaceRepositoryDraft]
    @Binding var editedWorkspaces: Set<String>
    let disabled: Bool
    let onEdit: () -> Void

    private var sortedInstallations: [GitHubInstallation] {
        installations.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Workspace access").font(.headline)
            if sortedInstallations.count > 1 {
                Text("Each workspace can use repositories from one GitHub owner at a time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(Workspace.ID.allCases, id: \.rawValue) { workspace in
                workspaceSection(workspace)
            }
            Text("Read & write lets MSW push changes. Your workspace never receives a write credential.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func workspaceSection(_ workspace: Workspace.ID) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(workspace.rawValue)
                .font(.callout.weight(.semibold))
            ForEach(sortedInstallations) { installation in
                let repositories = (repositoriesByInstallation[installation.id] ?? [])
                    .sorted {
                        $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending
                    }
                if !repositories.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        if sortedInstallations.count > 1 {
                            Text(installation.displayName)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(repositories) { repository in
                            repositoryRow(
                                workspace,
                                repository: repository,
                                installation: installation
                            )
                        }
                    }
                }
            }
        }
        .padding(8)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func repositoryRow(
        _ workspace: Workspace.ID,
        repository: GitHubRepository,
        installation: GitHubInstallation
    ) -> some View {
        let selected = isSelected(workspace, repository: repository, installation: installation)
        HStack(spacing: 8) {
            Toggle(repository.fullName, isOn: selectionBinding(
                workspace,
                repository: repository,
                installation: installation
            ))
            .toggleStyle(.checkbox)
            .disabled(disabled || selectionBlocked(workspace, installation: installation))
            .accessibilityIdentifier("github.workspace.\(workspace.rawValue).repository.\(repository.id)")
            Spacer(minLength: 8)
            if selected {
                Picker(
                    "Access for \(repository.fullName)",
                    selection: modeBinding(
                        workspace,
                        repository: repository,
                        installation: installation
                    )
                ) {
                    ForEach(GitHubRepositoryAccessMode.allCases, id: \.rawValue) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
                .disabled(disabled)
                .accessibilityIdentifier("github.workspace.\(workspace.rawValue).repository.\(repository.id).mode")
            }
        }
    }

    private func isSelected(
        _ workspace: Workspace.ID,
        repository: GitHubRepository,
        installation: GitHubInstallation
    ) -> Bool {
        let draft = drafts[workspace.rawValue] ?? .initial(workspace)
        return draft.installationID == installation.id && draft.repositoryModes[repository.id] != nil
    }

    private func selectionBlocked(_ workspace: Workspace.ID, installation: GitHubInstallation) -> Bool {
        guard let selectedInstallation = drafts[workspace.rawValue]?.installationID else { return false }
        return selectedInstallation != installation.id
    }

    private func selectionBinding(
        _ workspace: Workspace.ID,
        repository: GitHubRepository,
        installation: GitHubInstallation
    ) -> Binding<Bool> {
        Binding(
            get: { isSelected(workspace, repository: repository, installation: installation) },
            set: { selected in
                var draft = drafts[workspace.rawValue] ?? .initial(workspace)
                if selected {
                    guard draft.installationID == nil || draft.installationID == installation.id else { return }
                    draft.installationID = installation.id
                    draft.repositoryModes[repository.id] = .readOnly
                } else if draft.installationID == installation.id {
                    draft.repositoryModes.removeValue(forKey: repository.id)
                    if draft.repositoryModes.isEmpty { draft.installationID = nil }
                }
                drafts[workspace.rawValue] = draft
                editedWorkspaces.insert(workspace.rawValue)
                onEdit()
            }
        )
    }

    private func modeBinding(
        _ workspace: Workspace.ID,
        repository: GitHubRepository,
        installation: GitHubInstallation
    ) -> Binding<GitHubRepositoryAccessMode> {
        Binding(
            get: {
                guard isSelected(workspace, repository: repository, installation: installation) else { return .readOnly }
                return drafts[workspace.rawValue]?.repositoryModes[repository.id] ?? .readOnly
            },
            set: { mode in
                guard var draft = drafts[workspace.rawValue], draft.installationID == installation.id,
                      draft.repositoryModes[repository.id] != nil else { return }
                draft.repositoryModes[repository.id] = mode
                drafts[workspace.rawValue] = draft
                editedWorkspaces.insert(workspace.rawValue)
                onEdit()
            }
        )
    }
}
