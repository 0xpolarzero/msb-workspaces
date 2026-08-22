import AppKit
import SwiftUI

@MainActor
final class SetupWindowController {
    private let window: NSWindow

    init(
        coordinator: (any MSWBootstrapCoordinating)?,
        authorizationCoordinator: GitHubAuthorizationCoordinator? = nil,
        githubInstallationURL: URL? = nil,
        provider: (any GitHubProviding)? = nil,
        accessMode: GitHubAccessMode = .local,
        commandRunner: MSWCommandRunner = MSWCommandRunner(),
        openSettings: @escaping (SettingsSection) -> Void,
        closeSetup: @escaping () -> Void = {},
        uiTestMode: Bool = false,
        uiTestStartsInReview: Bool = false,
        uiTestGitHubScenario: String? = nil,
        uiTestBootstrapReconnect: Bool = false,
        startupRecoveryBlockedReason: String? = nil,
        retryStartupRecovery: @escaping () -> Void = {}
    ) {
        let authorization = Self.resolvedAuthorization(
            accessMode: accessMode,
            authorizationCoordinator: authorizationCoordinator
        )
        let hosting = NSHostingController(
            rootView: SetupView(
                coordinator: coordinator,
                authorizationCoordinator: authorization,
                provider: provider,
                accessMode: accessMode,
                commandRunner: commandRunner,
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
        // The setup window owns its size. Dynamic SwiftUI content (notably
        // repository selections) must reflow or scroll instead of changing
        // the surrounding onboarding window.
        hosting.sizingOptions = []
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

    /// Resolves the coordinator passed to SetupView. Local mode NEVER
    /// instantiates or passes a Connect broker/coordinator — even when a
    /// caller supplies one, local mode drops it (Path C §1 / reviewer
    /// blocker 7). Connect mode keeps the pre-existing fallback behavior.
    static func resolvedAuthorization(
        accessMode: GitHubAccessMode,
        authorizationCoordinator: GitHubAuthorizationCoordinator?
    ) -> GitHubAuthorizationCoordinator? {
        guard accessMode == .connect else { return nil }
        return authorizationCoordinator ?? (try? CredentialBroker()).map {
            GitHubAuthorizationCoordinator(broker: $0)
        }
    }
}

struct WorkspaceRepositoryDraft: Codable, Equatable, Identifiable {
    let workspace: Workspace.ID
    /// Connect mode only: the single installation scoping this workspace's
    /// selections (one-installation rule). Local mode leaves this nil so a
    /// workspace may select repositories from MULTIPLE owners.
    var installationID: Int?
    /// Selections keyed by canonical repository (owner/name). Local mode
    /// spans owners; connect mode is scoped to `installationID`.
    var repositoryModes: [String: GitHubRepositoryAccessMode]

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

private enum LocalCatalogIssueKind: String {
    case unavailable
    case failed
}

private struct LocalCatalogIssue: Identifiable {
    let kind: LocalCatalogIssueKind
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
    let provider: (any GitHubProviding)?
    let accessMode: GitHubAccessMode
    let commandRunner: MSWCommandRunner
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
    @State private var githubStatus = ""
    @State private var isConnectingGitHub = false
    @State private var githubConnectionMayCancel = false
    @State private var githubConnectionTask: Task<Void, Never>?
    @State private var githubConnectionGeneration = 0
    @State private var isRefreshingGitHub = false
    @State private var githubRefreshTask: Task<Void, Never>?
    @State private var githubRefreshGeneration = 0
    @State private var isApplyingGitHub = false
    @State private var githubApplyTask: Task<Void, Never>?
    @State private var githubApplyGeneration = 0
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
    @State private var identityNameWasEdited = false
    @State private var identityEmailWasEdited = false
    @State private var identityTarget = "all"
    @State private var identityConfiguredWorkspaces: Set<String> = []
    @State private var verifiedIdentityByWorkspace: [String: SetupVerifiedIdentity] = [:]

    @State private var identitySkipped = false
    @State private var isSavingIdentity = false
    @State private var identityStatus = ""
    @State private var activeStep: SetupStep = .readiness
    @State private var githubContextLoaded = false
    @State private var localCatalogAttempted = false
    @State private var githubHostCredentialPresent = false
    @State private var githubAttentionWorkspace: String?
    @State private var localCatalogIssue: LocalCatalogIssue?
    @State private var addedRepositoryInput = ""
    @State private var manualEntryExpanded = SetupView.manualEntryInitiallyExpanded
    @State private var deviceFlowSession: GitHubDeviceFlowSession?
    @State private var deviceFlowShown = false

    /// Manual OWNER/REPO entry is a collapsible fallback below the discovery
    /// list and starts collapsed.
    static let manualEntryInitiallyExpanded = false

    /// Explicit initializer keeps the setup dependencies visible at call sites.
    init(
        coordinator: (any MSWBootstrapCoordinating)?,
        authorizationCoordinator: GitHubAuthorizationCoordinator?,
        provider: (any GitHubProviding)?,
        accessMode: GitHubAccessMode,
        commandRunner: MSWCommandRunner = MSWCommandRunner(),
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
        self.provider = provider
        self.accessMode = accessMode
        self.commandRunner = commandRunner
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
        .frame(
            minWidth: 560,
            maxWidth: .infinity,
            minHeight: 560,
            maxHeight: .infinity
        )
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
        .onChange(of: activeStep) { _, step in
            loadLocalCatalogWhenNeeded(for: step)
        }
        .sheet(isPresented: $deviceFlowShown) {
            if let session = deviceFlowSession {
                GitHubDeviceFlowView(
                    session: session,
                    onComplete: { login in
                        deviceFlowShown = false
                        deviceFlowSession = nil
                        if let login, !login.isEmpty {
                            account = GitHubAccount(
                                login: login,
                                id: GitHubLocalProvider.stableID(login),
                                name: nil,
                                email: nil
                            )
                            githubStatus = "Connected as @\(login)."
                        } else {
                            githubStatus = "GitHub account connected."
                        }
                        loadLocalCatalog(force: true)
                    },
                    onCancel: {
                        deviceFlowShown = false
                        deviceFlowSession = nil
                        githubStatus = "GitHub sign-in cancelled."
                    }
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup.root")
    }

    private func invalidateSetupLifecycle() {
        setupLifecycle.invalidate()
        githubConnectionGeneration &+= 1
        githubConnectionTask?.cancel()
        githubConnectionTask = nil
        githubRefreshGeneration &+= 1
        githubRefreshTask?.cancel()
        githubRefreshTask = nil
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
        if accessMode == .local {
            return provider != nil
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



    private var showsGitHubConnectAction: Bool {
        account == nil
    }

    private var isGitHubConnected: Bool {
        account != nil || (accessMode == .local && githubHostCredentialPresent)
    }

    /// Connecting an account is not itself a GitHub decision. Keep the
    /// optional path visible until repository access has actually been saved.
    private var showsGitHubSkipAction: Bool {
        !repositoryPolicyApplied
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
            Label("GitHub access needs attention", systemImage: "exclamationmark.octagon.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.red)
            Text("GitHub access could not be recovered after an interrupted update.")
                .font(.callout)
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Try again when MSW Monitor can reach your workspaces. Existing GitHub access stays protected until this succeeds.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Try GitHub recovery again", action: retryStartupRecovery)
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
            // Local mode has no Connect recovery gate: the policy can be
            // configured as soon as preflight passes, even while bootstrap
            // finishes creating workspaces.
            return githubContextLoaded &&
                (canFinishWithoutGitHub ||
                 (systemReady && (githubReconnectRequired || accessMode == .local)))
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
        if canFinishWithoutGitHub || githubReconnectRequired ||
            (accessMode == .local && systemReady) {
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
        guard !githubSkipped, !isConnectingGitHub, !isApplyingGitHub, !isSkippingGitHub else { return }
        if accessMode == .local {
            // Local mode has no Connect grants to disable; skipping just
            // marks the step decided.
            githubSkipped = true
            authorizationIssue = nil
            localCatalogIssue = nil
            githubStatus = "GitHub skipped. You can go back and connect it later."
            activeStep = .identity
            return
        }
        let affectedWorkspace = githubReconnectRequired ? githubAttentionWorkspace : nil
        guard affectedWorkspace != nil || !githubReconnectRequired else {
            githubSkipIssue = "MSW Monitor could not identify which workspace needs attention. No access was changed; check again before continuing."
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
                        githubSkipIssue = "GitHub access for \(affectedWorkspace) could not be turned off safely: \(error.localizedDescription) Try again when the workspace is available, or reconnect GitHub instead."
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
                      activeStep == .github else {
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
                githubStatus = "GitHub skipped. You can go back and connect it later."
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

    private var skipGitHubButton: some View {
        Button(action: skipGitHub) {
            HStack(spacing: 7) {
                ZStack {
                    Image(systemName: "forward")
                        .opacity(isSkippingGitHub ? 0 : 1)
                        .accessibilityHidden(true)
                    ProgressView()
                        .controlSize(.small)
                        .opacity(isSkippingGitHub ? 1 : 0)
                        .accessibilityHidden(true)
                }
                .frame(width: 16, height: 16)
                Text("Skip GitHub")
            }
        }
        .buttonStyle(.bordered)
        .disabled(githubSkipped || isConnectingGitHub || isApplyingGitHub || isSkippingGitHub)
        .accessibilityValue(isSkippingGitHub ? "Skipping" : "Ready")
        .accessibilityIdentifier("setup.github.skip.button")
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
                Label("macOS may ask you to allow MSW Monitor to run in the background.", systemImage: "lock.shield")
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

    @ViewBuilder
    private var githubBoundary: some View {
        if accessMode == .local {
            localGitHubBoundary
        } else {
            connectGitHubBoundary
        }
    }

    private var connectGitHubBoundary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GitHub").font(.title3.weight(.semibold))

            if let account {
                Label("Connected as @\(account.login)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("setup.github.account")
            }

            HStack(spacing: 12) {
                if showsGitHubSkipAction {
                    skipGitHubButton
                }
                if showsGitHubConnectAction {
                    Button(action: beginAuthorization) {
                        HStack(spacing: 7) {
                            ZStack {
                                Image(systemName: "link")
                                    .opacity(isConnectingGitHub ? 0 : 1)
                                    .accessibilityHidden(true)
                                ProgressView()
                                    .controlSize(.small)
                                    .opacity(isConnectingGitHub ? 1 : 0)
                                    .accessibilityHidden(true)
                            }
                            .frame(width: 16, height: 16)
                            Text("Connect GitHub")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isConnectingGitHub)
                    .accessibilityValue(isConnectingGitHub ? "Connecting" : "Ready")
                    .accessibilityIdentifier("setup.github.connect.button")
                }
                Button("Cancel", action: cancelGitHubConnection)
                    .keyboardShortcut(.cancelAction)
                    .opacity(githubConnectionMayCancel ? 1 : 0)
                    .disabled(!githubConnectionMayCancel)
                    .accessibilityHidden(!githubConnectionMayCancel)
                    .accessibilityIdentifier("setup.github.cancel.button")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
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
                        Text("Manage the connected account below, or skip GitHub and continue without it.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                if !repositoriesByInstallation.isEmpty {
                    repositoryPolicyEditor
                }
                Button("Manage Connected Account") { openSettings(.github) }
                    .accessibilityIdentifier("setup.github.manage-account.button")
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


            githubStatusSlot

            if !verificationResults.isEmpty {
                verificationResultsCard
            }

        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup.github-boundary")
    }

    private var localGitHubBoundary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GitHub").font(.title3.weight(.semibold))

            if let account {
                Label("Connected as @\(account.login)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("setup.github.account")
            } else if githubHostCredentialPresent {
                Label("GitHub account connected on this Mac", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("setup.github.account")
            }

            HStack(spacing: 12) {
                if showsGitHubSkipAction {
                    skipGitHubButton
                }
                if isGitHubConnected {
                    Button(action: { loadLocalCatalog(force: true) }) {
                        HStack(spacing: 6) {
                            ZStack {
                                Image(systemName: "arrow.clockwise")
                                    .opacity(isRefreshingGitHub ? 0 : 1)
                                    .accessibilityHidden(true)
                                ProgressView()
                                    .controlSize(.small)
                                    .opacity(isRefreshingGitHub ? 1 : 0)
                                    .accessibilityHidden(true)
                            }
                            .frame(width: 16, height: 16)
                            Text("Refresh")
                        }
                    }
                    .controlSize(.small)
                    .disabled(isRefreshingGitHub || isConnectingGitHub || provider == nil)
                    .accessibilityValue(isRefreshingGitHub ? "Refreshing repositories" : "Ready")
                    .accessibilityIdentifier("setup.github.refresh.button")
                } else if isRefreshingGitHub {
                    Button(action: {}) {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityHidden(true)
                            Text("Refresh")
                        }
                    }
                    .controlSize(.small)
                    .disabled(true)
                    .accessibilityValue("Refreshing repositories")
                    .accessibilityIdentifier("setup.github.refresh.button")
                } else if localCatalogAttempted {
                    Button(action: connectGitHubAccount) {
                        HStack(spacing: 7) {
                            ZStack {
                                Image(systemName: "link")
                                    .opacity(isConnectingGitHub ? 0 : 1)
                                    .accessibilityHidden(true)
                                ProgressView()
                                    .controlSize(.small)
                                    .opacity(isConnectingGitHub ? 1 : 0)
                                    .accessibilityHidden(true)
                            }
                            .frame(width: 16, height: 16)
                            Text("Connect GitHub")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isConnectingGitHub || provider == nil)
                    .accessibilityValue(isConnectingGitHub ? "Connecting" : "Ready")
                    .accessibilityIdentifier("setup.github.connect-account.button")
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            if let localCatalogIssue {
                VStack(alignment: .leading, spacing: 7) {
                    Label(localCatalogIssueTitle(localCatalogIssue.kind), systemImage: "wifi.exclamationmark")
                        .font(.callout.weight(.semibold))
                    Text(localCatalogIssue.message)
                        .font(.callout)
                        .accessibilityIdentifier("setup.github.issue.\(localCatalogIssue.kind.rawValue)")
                    Button("Try again", action: beginAuthorization)
                        .disabled(isRefreshingGitHub)
                        .accessibilityIdentifier("setup.github.retry.button")
                }
                .padding(10)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityElement(children: .contain)
            }

            if isGitHubConnected {
                // Manual OWNER/REPO entry is always available while a local
                // account is connected — including zero-result and error
                // states, where discovery found nothing to pick from.
                DisclosureGroup(isExpanded: $manualEntryExpanded) {
                    addRepositoryRow
                } label: {
                    Text("Add a repository manually")
                }
                .accessibilityIdentifier("setup.github.manual-add")
                if !repositoriesByInstallation.isEmpty {
                    repositoryPolicyEditor
                }
                Button("Manage Connected Account") { openSettings(.github) }
                    .accessibilityIdentifier("setup.github.manage-account.button")
            }

            githubStatusSlot
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup.github-boundary")
    }

    private var addRepositoryRow: some View {
        HStack(spacing: 8) {
            TextField("owner/repository", text: $addedRepositoryInput)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("setup.github.add-repository.field")
            Button("Add repository", action: addEnteredRepository)
                .disabled(!Self.isValidRepositoryInput(addedRepositoryInput) || isApplyingGitHub)
                .accessibilityIdentifier("setup.github.add-repository.button")
        }
        .padding(.top, 2)
    }

    private var githubStatusSlot: some View {
        Text(githubStatus.isEmpty ? " " : githubStatus)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .frame(maxWidth: .infinity, minHeight: 54, maxHeight: 54, alignment: .topLeading)
            .accessibilityHidden(githubStatus.isEmpty)
            .accessibilityIdentifier("setup.github.status")
    }

    private func localCatalogIssueTitle(_ kind: LocalCatalogIssueKind) -> String {
        switch kind {
        case .unavailable: return "GitHub unavailable"
        case .failed: return "GitHub repositories could not be loaded"
        }
    }

    private static func isValidRepositoryInput(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return GitHubLocalProvider.isValidCanonical(GitHubLocalProvider.canonicalize(trimmed))
    }

    private func addEnteredRepository() {
        let canonical = GitHubLocalProvider.canonicalize(addedRepositoryInput)
        guard Self.isValidRepositoryInput(canonical),
              let (owner, name) = GitHubLocalProvider.splitCanonical(canonical) else {
            return
        }
        let ownerID = GitHubLocalProvider.stableID(owner)
        let ownerAccount = GitHubInstallationAccount(login: owner, id: ownerID, type: nil)
        let repository = GitHubRepository(
            id: GitHubLocalProvider.stableID(canonical),
            fullName: canonical,
            name: name,
            owner: ownerAccount,
            private: true,
            defaultBranch: nil
        )
        if !installations.contains(where: { $0.id == ownerID }) {
            installations.append(GitHubInstallation(
                id: ownerID,
                account: ownerAccount,
                repositorySelection: nil
            ))
        }
        if !(repositoriesByInstallation[ownerID]?.contains(where: { $0.id == repository.id }) ?? false) {
            repositoriesByInstallation[ownerID, default: []].append(repository)
        }
        addedRepositoryInput = ""
    }

    @ViewBuilder
    private func authorizationIssueAction(_ issue: AuthorizationIssue) -> some View {
        switch issue.kind {
        case .unavailable:
            EmptyView()
        case .expired, .reconnect:
            if let workspace = firstReconnectWorkspace {
                Button("Reconnect \(workspace)", action: beginAuthorization)
                    .disabled(!canConnectGitHub || isConnectingGitHub)
                    .accessibilityIdentifier("setup.github.reconnect.button")
            } else {
                Button("Connect GitHub", action: beginAuthorization)
                    .disabled(!canConnectGitHub || isConnectingGitHub)
                    .accessibilityIdentifier("setup.github.connect-again.button")
            }
        case .cancelled, .denied:
            Button("Connect GitHub", action: beginAuthorization)
                .disabled(!canConnectGitHub || isConnectingGitHub)
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
            accessMode: accessMode,
            drafts: $drafts,
            editedWorkspaces: $editedGitHubWorkspaces,
            disabled: isApplyingGitHub,
            onEdit: {
                repositoryPolicyApplied = false
                if accessMode == .local || disabledGitHubWorkspaces.isEmpty {
                    githubSkipped = false
                }
            }
        )
        .accessibilityIdentifier("setup.github.repository-policy")
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
                            .disabled(!canConnectGitHub || isConnectingGitHub)
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
            Text("Your name for Git changes").font(.title3.weight(.semibold))
            Text("Choose the name and email shown on changes you make in these workspaces.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !canFinishWithoutGitHub {
                Label("You can enter these details now. Saving becomes available when workspace setup finishes.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextField("Full name", text: identityNameBinding)
                .textContentType(.name)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Git author full name")
                .accessibilityIdentifier("setup.identity.name")
            TextField("Email", text: identityEmailBinding)
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
                Button("Skip identity for now") {
                    identitySkipped = true
                    identityStatus = "Identity skipped by choice. Configure it later in Workspace Settings."
                    activeStep = .review
                }
                .buttonStyle(.bordered)
                .disabled(identitySkipped || isSavingIdentity)
                .accessibilityIdentifier("setup.identity.skip.button")
                Button(action: saveIdentity) {
                    HStack(spacing: 7) {
                        ZStack {
                            Image(systemName: "checkmark")
                                .opacity(isSavingIdentity ? 0 : 1)
                                .accessibilityHidden(true)
                            ProgressView()
                                .controlSize(.small)
                                .opacity(isSavingIdentity ? 1 : 0)
                                .accessibilityHidden(true)
                        }
                        .frame(width: 16, height: 16)
                        Text("Save and review")
                    }
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSaveIdentity || isSavingIdentity)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityValue(isSavingIdentity ? "Saving" : "Ready")
                    .accessibilityIdentifier("setup.identity.save.button")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            identityStatusSlot
            if !identityConfiguredWorkspaces.isEmpty && !identityHasUnverifiedEdits {
                Label(
                    "Saved for \(identityConfiguredWorkspaces.sorted().joined(separator: ", "))",
                    systemImage: "checkmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(.green)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup.identity")
    }

    @ViewBuilder
    private var identityStatusSlot: some View {
        Group {
            if identityHasUnverifiedEdits {
                Label(
                    "These details changed since they were last saved. Save them again before finishing.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                .accessibilityIdentifier("setup.identity.status")
            } else {
                Text(identityStatus.isEmpty ? " " : identityStatus)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(identityStatus.isEmpty)
                    .accessibilityIdentifier("setup.identity.status")
            }
        }
        .font(.caption)
        .lineLimit(2)
        .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36, alignment: .topLeading)
    }

    private var finalReview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Review setup")
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("setup.final-review.title")
            Text("The GitHub and identity choices below are saved.")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("setup.final-review.summary")
            Text("Finish any remaining workspace setup, then choose Done to close onboarding.")
                .foregroundStyle(.secondary)
            reviewStatusLine(
                title: "System and workspaces",
                value: canFinishWithoutGitHub ? "Finished" : "Still in progress",
                ready: canFinishWithoutGitHub
            )
            if !canFinishWithoutGitHub && systemReady {
                Button(isRunning ? "Finishing workspace setup…" : "Finish workspace setup") {
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
                title: "Name for Git changes",
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
            footerActions
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("setup.actions")
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
        .lineLimit(2)
        .frame(maxWidth: .infinity, minHeight: 38, maxHeight: 38, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("setup.status")
        .accessibilityValue(error ?? notice ?? footerGuidance)
    }

    private var footerGuidance: String {
        switch activeStep {
        case .readiness:
            if !githubContextLoaded { return "Loading your saved setup choices before you continue." }
            return canFinishWithoutGitHub
                ? "System setup is finished. Continue to GitHub."
                : "Continue prepares your workspaces, then returns them to their current state."
        case .github:
            if isRefreshingGitHub { return "Refreshing repositories. You can keep editing your choices." }
            if isConnectingGitHub {
                return accessMode == .connect
                    ? "Finish GitHub sign-in in your browser, or cancel the connection."
                    : "Finish GitHub sign-in in your browser to continue."
            }
            if isApplyingGitHub { return "Saving GitHub access. You will continue automatically." }
            if isSkippingGitHub { return "Keeping GitHub optional. You will continue automatically." }
            if githubSkipIssue != nil { return "Retry the GitHub action above before continuing." }
            if githubStepComplete { return "Your GitHub choice is saved. Continue when ready." }
            if isGitHubConnected && !hasValidAssignments {
                return "Choose at least one repository, add one manually, or skip GitHub."
            }
            return "Connect GitHub or skip it for now."
        case .identity:
            if isSavingIdentity { return "Saving your name and email. Review will open automatically." }
            if !canFinishWithoutGitHub { return "Workspace setup must finish before your name and email can be saved." }
            if !uiTestMode && authorizationCoordinator == nil {
                return "Workspace identity settings are unavailable. Try setup again."
            }
            if identityName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Enter your name, or skip identity for now."
            }
            if !identityEmail.contains("@") || identityEmail.contains(where: \.isWhitespace) {
                return "Enter a valid email address, or skip identity for now."
            }
            return identityStepComplete
                ? "Your identity choice is saved."
                : "Save your name and email, or skip identity for now."
        case .review:
            if !githubContextLoaded { return "Loading your saved GitHub choice before setup can finish." }
            if !canFinishWithoutGitHub { return "Finish workspace setup before choosing Done." }
            if !githubDecisionMade { return "Go back and connect GitHub or skip it." }
            if !identityDecisionMade { return "Go back and save your identity or skip it." }
            if !verificationAllowsCompletion { return "GitHub access needs attention before setup can finish." }
            return "Everything is finished. Choose Done to close onboarding."
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
        HStack(alignment: .center, spacing: 10) {
            if activeStep != .readiness {
                Button("Back", action: moveBack)
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSkippingGitHub || isApplyingGitHub || isConnectingGitHub || isSavingIdentity)
                    .accessibilityIdentifier("setup.back.button")
            }

            switch activeStep {
            case .readiness:
                Button(isChecking ? "Checking…" : "Retry", action: loadPreflight)
                    .buttonStyle(.bordered)
                    .disabled(isChecking || isRunning || coordinator == nil)
                    .accessibilityIdentifier("setup.retry.button")
                if hostIntegrationNeedsPackagedBuild {
                    Label("Install the complete MSW Monitor app", systemImage: "lock.circle")
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
                if githubStepComplete {
                    Button("Continue", action: advanceFromGitHub)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("setup.github.continue.button")
                } else {
                    Button(action: commitPolicy) {
                        HStack(spacing: 7) {
                            ZStack {
                                Image(systemName: "checkmark")
                                    .opacity(isApplyingGitHub ? 0 : 1)
                                    .accessibilityHidden(true)
                                ProgressView()
                                    .controlSize(.small)
                                    .opacity(isApplyingGitHub ? 1 : 0)
                                    .accessibilityHidden(true)
                            }
                            .frame(width: 16, height: 16)
                            Text("Save and continue")
                        }
                    }
                        .buttonStyle(.borderedProminent)
                        .disabled(!isGitHubConnected || !hasValidAssignments || isApplyingGitHub || isSkippingGitHub || githubSkipIssue != nil)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityValue(isApplyingGitHub ? "Saving" : "Ready")
                        .accessibilityIdentifier("setup.github.apply.button")
                }
            case .identity:
                if identityStepComplete {
                    Button("Continue to review") { activeStep = .review }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("setup.identity.continue.button")
                }
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
        Self.repositoryPolicyEntries(
            workspace: draft.workspace,
            draft: draft,
            installations: installations,
            repositoriesByInstallation: repositoriesByInstallation,
            accessMode: accessMode
        )
    }

    /// Pure draft -> policy mapping used by `policyEntries(for:)` and
    /// exercised directly by unit tests. Local mode spans ALL owners; connect
    /// mode is scoped to the draft's single installation.
    static func repositoryPolicyEntries(
        workspace: Workspace.ID,
        draft: WorkspaceRepositoryDraft,
        installations: [GitHubInstallation],
        repositoriesByInstallation: [Int: [GitHubRepository]],
        accessMode: GitHubAccessMode
    ) -> [GitHubRepositoryPolicy] {
        // Canonical repository -> (repository, owner installation) lookup.
        var byCanonical: [String: (GitHubRepository, GitHubInstallation)] = [:]
        for installation in installations {
            let repositories = repositoriesByInstallation[installation.id] ?? []
            for repository in repositories {
                let canonical = GitHubLocalProvider.canonicalize(repository.fullName)
                byCanonical[canonical] = (repository, installation)
            }
        }
        var result: [GitHubRepositoryPolicy] = []
        for (canonical, mode) in draft.repositoryModes {
            guard let (repository, installation) = byCanonical[canonical] else { continue }
            if accessMode == .connect, let scopedInstallationID = draft.installationID,
               scopedInstallationID != installation.id {
                continue
            }
            result.append(GitHubRepositoryPolicy(
                workspace: workspace.rawValue,
                repositoryID: repository.id,
                fullName: repository.fullName,
                installationID: installation.id,
                ownerID: installation.account.id,
                ownerLogin: installation.account.login,
                ownerType: installation.account.type,
                mode: repository.effectiveMode(mode)
            ))
        }
        return result
    }


    private var hasValidAssignments: Bool {
        !workspacePolicy.isEmpty
    }


    private func beginAuthorization() {
        if accessMode == .local {
            // This path is now used only for explicit recovery actions. The
            // first load is automatic when the GitHub step appears, so a
            // retry must bypass the one-shot render guard.
            loadLocalCatalog(force: true)
            return
        }
        if uiTestGitHubScenario == "unavailable" {
            authorizationIssue = AuthorizationIssue(
                kind: .unavailable,
                message: "GitHub could not be reached. Try again later."
            )
            githubStatus = ""
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

        cancelGitHubConnection()
        githubConnectionGeneration &+= 1
        let generation = githubConnectionGeneration
        isConnectingGitHub = true
        githubConnectionMayCancel = true
        authorizationIssue = nil
        githubStatus = "Opening GitHub in your browser…"
        uiTestAuthorizationAttempts += 1

        if let scenario = uiTestGitHubScenario {
            let shouldHoldForCancellation = scenario == "cancel-retry" && uiTestAuthorizationAttempts == 1
            githubConnectionTask = Task {
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
                    guard githubConnectionGeneration == generation else { return }
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
                    isConnectingGitHub = false
                    githubConnectionMayCancel = false
                    githubConnectionTask = nil
                    githubSkipped = false
                    githubStatus = discovery.installations.isEmpty
                        ? "No repositories are available for this account. You can refresh, add one manually, or skip GitHub."
                        : "Choose which repositories each workspace can use."
                    prefillIdentity(from: discovery.account)
                }
            }
            return
        }

        guard let authorizationCoordinator else { return }
        let browser = MSWConnectBrowser.shared
        githubConnectionTask = Task {
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
                    guard githubConnectionGeneration == generation else { return }
                    account = discovery.account
                    installations = discovery.installations
                    githubInstallationURL = Self.validatedInstallationURL(installURL)
                    authorizationSessionID = discovery.sessionID
                    repositoriesByInstallation = loadedRepositories
                    prefillRepositoryPolicyDrafts()
                    isConnectingGitHub = false
                    githubConnectionMayCancel = false
                    githubConnectionTask = nil
                    githubSkipped = false
                    githubStatus = "Choose which repositories each workspace can use."
                    prefillIdentity(from: discovery.account)
                }
            } catch {
                await MainActor.run {
                    guard githubConnectionGeneration == generation else { return }
                    isConnectingGitHub = false
                    githubConnectionMayCancel = false
                    githubConnectionTask = nil
                    authorizationIssue = issue(for: error)
                    githubStatus = ""
                }
            }
        }
    }

    /// Local mode: loads the repo catalog (policy read-back via the CLI) into
    /// the existing picker models and prefills drafts from the policy file.
    private func loadLocalCatalogWhenNeeded(for step: SetupStep) {
        guard accessMode == .local, step == .github, !localCatalogAttempted else { return }
        loadLocalCatalog()
    }

    private func loadLocalCatalog(force: Bool = false) {
        guard force || !localCatalogAttempted else { return }
        guard !isRefreshingGitHub else { return }
        guard let provider else {
            authorizationIssue = AuthorizationIssue(
                kind: .unavailable,
                message: "GitHub local access is unavailable in this build."
            )
            return
        }
        localCatalogAttempted = true
        githubRefreshGeneration &+= 1
        let generation = githubRefreshGeneration
        isRefreshingGitHub = true
        authorizationIssue = nil
        localCatalogIssue = nil
        githubStatus = ""
        githubRefreshTask?.cancel()
        githubRefreshTask = Task {
            do {
                let catalog = try await provider.loadCatalog()
                let policy = await provider.currentPolicy()
                try Task.checkCancellation()
                await MainActor.run {
                    guard githubRefreshGeneration == generation else { return }
                    account = catalog.account
                    githubHostCredentialPresent = catalog.hostCredentialPresent
                    installations = catalog.installations
                    repositoriesByInstallation = catalog.repositoriesByInstallation
                    githubInstallationURL = nil
                    authorizationSessionID = nil
                    isRefreshingGitHub = false
                    githubRefreshTask = nil
                    if !catalog.hostCredentialPresent {
                        githubStatus = "Connect GitHub to choose repositories, or skip it for now."
                    } else if catalog.installations.isEmpty && catalog.repositoriesByInstallation.isEmpty {
                        githubStatus = "No repositories found. Add one manually, refresh, or skip GitHub."
                    } else {
                        githubStatus = "Repositories are up to date."
                    }
                    prefillLocalRepositoryPolicyDrafts(policy: policy)
                    if let account {
                        prefillIdentity(from: account)
                    }
                }
            } catch is CancellationError {
                // Setup closed or the lifecycle was invalidated; no publication.
            } catch {
                await MainActor.run {
                    guard githubRefreshGeneration == generation else { return }
                    isRefreshingGitHub = false
                    githubRefreshTask = nil
                    let kind: LocalCatalogIssueKind
                    if case .unavailable? = error as? GitHubCatalogError {
                        kind = .unavailable
                    } else {
                        kind = .failed
                    }
                    localCatalogIssue = LocalCatalogIssue(
                        kind: kind,
                        message: error.localizedDescription
                    )
                    githubStatus = ""
                }
            }
        }
    }

    /// Runs the CLI-owned host-credential flow. gh reuse completes
    /// in-process. When the CLI reports gh is unauthenticated with no
    /// device-flow client ID (MSW_HOST_OAUTH_NOT_CONFIGURED) the app
    /// launches the installed gh web OAuth flow and then retries auth; when
    /// the CLI reports the Device Flow is available
    /// (MSW_HOST_DEVICE_FLOW_INTERACTIVE_REQUIRED) the app presents the
    /// in-app device sheet. Other typed remedies surface verbatim.
    private func connectGitHubAccount() {
        guard let provider, !isConnectingGitHub else { return }
        githubConnectionGeneration &+= 1
        let generation = githubConnectionGeneration
        githubConnectionTask?.cancel()
        isConnectingGitHub = true
        githubConnectionMayCancel = false
        authorizationIssue = nil
        localCatalogIssue = nil
        githubStatus = "Waiting for GitHub sign-in in your browser…"
        githubConnectionTask = Task {
            do {
                let account = try await provider.connectAccount()
                try Task.checkCancellation()
                guard githubConnectionGeneration == generation else { return }
                isConnectingGitHub = false
                githubConnectionTask = nil
                if let account {
                    self.account = account
                    githubStatus = "Connected as @\(account.login)."
                } else {
                    githubStatus = "GitHub account connected."
                }
                loadLocalCatalog(force: true)
            } catch GitHubCatalogError.ghWebLoginRequired {
                // gh is unauthenticated and no device-flow client ID is
                // configured: launch the installed gh web OAuth flow, then
                // retry the host-credential acquisition.
                await launchGhWebLoginAndRetry(generation: generation)
            } catch GitHubCatalogError.deviceFlowAvailable {
                // The CLI reported the Device Flow is available (a client ID
                // is explicitly configured); present the in-app device sheet.
                await beginDeviceFlow(generation: generation)
            } catch is CancellationError {
                // Setup closed or a newer connection attempt replaced this one.
            } catch {
                guard githubConnectionGeneration == generation else { return }
                isConnectingGitHub = false
                githubConnectionTask = nil
                localCatalogIssue = LocalCatalogIssue(
                    kind: .unavailable,
                    message: error.localizedDescription
                )
            }
        }
    }

    /// Launches the installed gh web OAuth flow (`gh auth login --web`),
    /// surfaces the waiting state, and retries `connectAccount()` once gh
    /// reports the browser sign-in completed.
    private func launchGhWebLoginAndRetry(generation: Int) async {
        guard let provider else {
            isConnectingGitHub = false
            githubConnectionTask = nil
            return
        }
        githubStatus = "Waiting for GitHub sign-in in your browser…"
        do {
            try await provider.launchGhWebLogin()
            // gh stored the token; retry the host-credential acquisition.
            let account = try await provider.connectAccount()
            try Task.checkCancellation()
            guard githubConnectionGeneration == generation else { return }
            isConnectingGitHub = false
            githubConnectionTask = nil
            if let account {
                self.account = account
                githubStatus = "Connected as @\(account.login)."
            } else {
                githubStatus = "GitHub account connected."
            }
            loadLocalCatalog(force: true)
        } catch GitHubCatalogError.ghWebLoginRequired {
            guard githubConnectionGeneration == generation else { return }
            isConnectingGitHub = false
            githubConnectionTask = nil
            localCatalogIssue = LocalCatalogIssue(
                kind: .unavailable,
                message: "GitHub sign-in did not complete. Retry when ready."
            )
        } catch is CancellationError {
            // Setup closed or a newer connection attempt replaced this one.
        } catch {
            guard githubConnectionGeneration == generation else { return }
            isConnectingGitHub = false
            githubConnectionTask = nil
            localCatalogIssue = LocalCatalogIssue(
                kind: .unavailable,
                message: error.localizedDescription
            )
        }
    }

    private func beginDeviceFlow(generation: Int) async {
        guard githubConnectionGeneration == generation, !Task.isCancelled else { return }
        guard let provider else {
            isConnectingGitHub = false
            githubConnectionTask = nil
            return
        }
        let session = GitHubDeviceFlowSession(
            startDeviceFlow: { try await provider.startDeviceFlow() },
            pollDeviceFlow: { deviceId in try await provider.pollDeviceFlow(deviceId: deviceId) }
        )
        isConnectingGitHub = false
        githubConnectionTask = nil
        deviceFlowSession = session
        deviceFlowShown = true
    }

    /// Prefills draft selections from the policy file (local mode). Every
    /// policy entry is preserved and keyed by canonical repository — owners
    /// missing from the discovery catalog get a synthetic installation/repo
    /// (like manual entry) so cross-owner entries stay visible and editable.
    private func prefillLocalRepositoryPolicyDrafts(policy: GitHubPolicyFile?) {
        guard retainedRepositoryPolicy.isEmpty, let policy else { return }
        for workspace in Workspace.ID.allCases {
            guard !editedGitHubWorkspaces.contains(workspace.rawValue),
                  var draft = drafts[workspace.rawValue],
                  draft.repositoryModes.isEmpty,
                  let policyWorkspace = policy.workspaces[workspace.rawValue] else {
                continue
            }
            let prefilled = Self.localPolicyPrefill(
                policyWorkspace: policyWorkspace,
                installations: installations,
                repositoriesByInstallation: repositoriesByInstallation
            )
            if !prefilled.modes.isEmpty {
                draft.installationID = nil
                draft.repositoryModes = prefilled.modes
                drafts[workspace.rawValue] = draft
                installations = prefilled.installations
                repositoriesByInstallation = prefilled.repositoriesByInstallation
            }
        }
    }

    /// Pure local-mode prefill used by `prefillLocalRepositoryPolicyDrafts`
    /// and exercised directly by unit tests. Returns canonical-keyed modes
    /// for EVERY policy entry plus the (possibly extended) catalog; owners
    /// missing from the loaded catalog are synthesized so cross-owner policy
    /// entries are never dropped.
    static func localPolicyPrefill(
        policyWorkspace: GitHubPolicyWorkspace,
        installations: [GitHubInstallation],
        repositoriesByInstallation: [Int: [GitHubRepository]]
    ) -> (
        modes: [String: GitHubRepositoryAccessMode],
        installations: [GitHubInstallation],
        repositoriesByInstallation: [Int: [GitHubRepository]]
    ) {
        var modes: [String: GitHubRepositoryAccessMode] = [:]
        var updatedInstallations = installations
        var updatedRepositories = repositoriesByInstallation
        for entry in policyWorkspace.repos {
            let canonical = entry.canonical
            guard let (owner, name) = GitHubLocalProvider.splitCanonical(canonical) else { continue }
            let ownerID = GitHubLocalProvider.stableID(owner)
            let repositoryID = GitHubLocalProvider.stableID(canonical)
            if !(updatedRepositories[ownerID]?.contains(where: { $0.id == repositoryID }) ?? false) {
                if !updatedInstallations.contains(where: { $0.id == ownerID }) {
                    updatedInstallations.append(GitHubInstallation(
                        id: ownerID,
                        account: GitHubInstallationAccount(login: owner, id: ownerID, type: nil),
                        repositorySelection: nil
                    ))
                }
                updatedRepositories[ownerID, default: []].append(GitHubRepository(
                    id: repositoryID,
                    fullName: canonical,
                    name: name,
                    owner: GitHubInstallationAccount(login: owner, id: ownerID, type: nil),
                    private: true,
                    defaultBranch: nil
                ))
            }
            modes[canonical] = entry.mode
        }
        return (modes, updatedInstallations, updatedRepositories)
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
            githubStatus = "Choose at least one repository, or skip GitHub."
            return
        }
        let policy = workspacePolicies.flatMap { $0.repositories }

        githubApplyGeneration &+= 1
        let generation = githubApplyGeneration
        isApplyingGitHub = true
        authorizationIssue = nil
        githubStatus = ""
        githubApplyTask?.cancel()

        if accessMode == .local {
            guard let provider else {
                githubStatus = "GitHub is unavailable in this build."
                isApplyingGitHub = false
                return
            }
            githubApplyTask = Task {
                do {
                    try await provider.commit(workspacePolicies)
                    try Task.checkCancellation()
                    await MainActor.run {
                        guard githubApplyGeneration == generation else { return }
                        existingMetadata = []
                        verificationResults = []
                        isApplyingGitHub = false
                        githubApplyTask = nil
                        githubSkipped = false
                        repositoryPolicyApplied = true
                        authorizationSessionID = nil
                        githubStatus = "GitHub access saved for \(workspacePolicies.count) workspace(s)."
                        activeStep = .identity
                    }
                } catch is CancellationError {
                    // The setup surface closed or the lifecycle was invalidated.
                } catch {
                    await MainActor.run {
                        guard githubApplyGeneration == generation else { return }
                        isApplyingGitHub = false
                        githubApplyTask = nil
                        authorizationIssue = issue(for: error)
                        githubStatus = ""
                    }
                }
            }
            return
        }

        if uiTestGitHubScenario != nil {
            githubApplyTask = Task {
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
                    guard githubApplyGeneration == generation else { return }
                    existingMetadata = []
                    verificationResults = verifications
                    isApplyingGitHub = false
                    githubApplyTask = nil
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
                    githubStatus = "GitHub access saved for \(workspacePolicies.count) workspace(s)."
                    activeStep = .identity
                }
            }
            return
        }

        guard let authorizationCoordinator,
              let sessionID = authorizationSessionID else {
            githubStatus = "Connect GitHub before saving repository access."
            isApplyingGitHub = false
            return
        }
        githubApplyTask = Task {
            do {
                let result = try await authorizationCoordinator.commitPolicyWithVerification(
                    sessionID: sessionID,
                    policy: workspacePolicies
                )
                let refreshed = await authorizationCoordinator.metadata()
                await MainActor.run {
                    guard githubApplyGeneration == generation else { return }
                    existingMetadata = refreshed
                    verificationResults = result.verifications
                    isApplyingGitHub = false
                    githubApplyTask = nil
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
                    githubStatus = "GitHub access saved for \(workspacePolicies.count) workspace(s)."
                    activeStep = .identity
                }
            } catch {
                let retained = await authorizationCoordinator.verificationResults()
                let refreshed = await authorizationCoordinator.metadata()
                await MainActor.run {
                    guard githubApplyGeneration == generation else { return }
                    verificationResults = retained
                    existingMetadata = refreshed
                    isApplyingGitHub = false
                    githubApplyTask = nil
                    authorizationIssue = issue(for: error)
                    githubStatus = ""
                }
            }
        }
    }

    private func cancelGitHubConnection() {
        guard githubConnectionMayCancel else { return }
        githubConnectionGeneration &+= 1
        githubConnectionTask?.cancel()
        githubConnectionTask = nil
        if isConnectingGitHub {
            authorizationIssue = AuthorizationIssue(
                kind: .cancelled,
                message: "GitHub connection was cancelled. Your existing access and repository choices were kept."
            )
        }
        githubStatus = "GitHub connection cancelled."
        isConnectingGitHub = false
        githubConnectionMayCancel = false
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
            githubStatus = "Reconnected as @\(discovery.account.login). Review your saved repository choices."
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
        await prefillIdentityFromLocalGit()
        if accessMode == .local {
            githubContextLoaded = true
            loadLocalCatalogWhenNeeded(for: activeStep)
            return true
        }
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
                            ? "Allow MSW Monitor in Login Items, then choose Retry."
                            : result.message)
                        : result.message
                }
            } catch {
                await MainActor.run {
                    isRunning = false
                    if accessMode == .connect,
                       let clientError = error as? MSWClientError,
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
        (uiTestMode || authorizationCoordinator != nil) &&
            canFinishWithoutGitHub &&
            !identityName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            identityEmail.contains("@") &&
            !identityEmail.contains(where: \.isWhitespace)
    }

    private func saveIdentity() {
        guard canSaveIdentity else {
            identityStatus = "Your name and email can be saved after workspace setup finishes."
            return
        }
        isSavingIdentity = true
        identitySkipped = false
        identityStatus = "Saving your name and email…"
        let name = identityName.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = identityEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = identityTarget == "all" ? nil : identityTarget
        if uiTestMode {
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    let workspaces = target.map { [$0] } ?? Workspace.ID.allCases.map(\.rawValue)
                    let savedIdentity = SetupVerifiedIdentity(name: name, email: email)
                    for workspace in workspaces {
                        verifiedIdentityByWorkspace[workspace] = savedIdentity
                    }
                    identityConfiguredWorkspaces.formUnion(workspaces)
                    isSavingIdentity = false
                    identityStatus = "Saved \(name) <\(email)> for \(workspaces.joined(separator: ", "))."
                    activeStep = .review
                }
            }
            return
        }
        guard let authorizationCoordinator else {
            isSavingIdentity = false
            identityStatus = "Workspace identity settings are unavailable. Try setup again."
            return
        }
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
                    identityStatus = "Saved \(result.name) <\(result.email)> for \(result.workspaces.joined(separator: ", "))."
                    activeStep = .review
                }
            } catch {
                await MainActor.run {
                    isSavingIdentity = false
                    identityStatus = "Your name and email were not changed: \(error.localizedDescription) Try again after workspace setup is available."
                }
            }
        }
    }

    private var githubReviewSummary: String {
        if accessMode == .local {
            if githubSkipped { return "Skipped." }
            if repositoryPolicyApplied { return "Configured." }
            return "Not configured yet."
        }
        if githubSkipped { return "Skipped." }
        if !verificationResults.isEmpty { return "Connected." }
        if !existingMetadata.isEmpty { return "Managed in Settings." }
        return "Not connected."
    }

    private var identityReviewSummary: String {
        if identitySkipped { return "Skipped by choice; configure it later in Workspace Settings." }
        if identityConfiguredWorkspaces.isEmpty { return "Not configured yet." }
        if identityHasUnverifiedEdits { return "Changed since last save; save again." }
        return "Saved for \(identityConfiguredWorkspaces.sorted().joined(separator: ", "))."
    }

    private var identityNameBinding: Binding<String> {
        Binding(
            get: { identityName },
            set: { value in
                identityNameWasEdited = true
                identityName = value
            }
        )
    }

    private var identityEmailBinding: Binding<String> {
        Binding(
            get: { identityEmail },
            set: { value in
                identityEmailWasEdited = true
                identityEmail = value
            }
        )
    }

    private func prefillIdentityFromLocalGit() async {
        guard let configuration = await commandRunner.gitIdentityConfiguration(),
              !Task.isCancelled else { return }
        let prefill = configuration.prefilling(
            name: identityName,
            email: identityEmail,
            nameWasEdited: identityNameWasEdited,
            emailWasEdited: identityEmailWasEdited
        )
        identityName = prefill.name
        identityEmail = prefill.email
        if prefill.didPrefill {
            identityStatus = "Name/email were prefilled from this Mac's Git configuration; review or edit them before saving."
        }
    }

    private func prefillIdentity(from account: GitHubAccount) {
        if !identityNameWasEdited, identityName.isEmpty, let name = account.name, !name.isEmpty {
            identityName = name
            identityStatus = "Name was prefilled from @\(account.login); review or edit it before saving."
        }
        if !identityEmailWasEdited, identityEmail.isEmpty, let email = account.email, !email.isEmpty {
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
                message: "GitHub connection was cancelled. Your saved choices and existing access were kept."
            )
        }
        return AuthorizationIssue(kind: .failed, message: error.localizedDescription)
    }

    private func issueTitle(_ kind: AuthorizationIssueKind) -> String {
        switch kind {
        case .cancelled: return "GitHub connection cancelled"
        case .expired: return "GitHub connection expired"
        case .denied: return "GitHub connection declined"
        case .unavailable: return "GitHub unavailable"
        case .reconnect: return "Reconnect required"
        case .failed: return "GitHub connection failed"
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
        case .reconnect: return "Reconnect, then review the repositories available to the affected workspace."
        case .failed: return "Try again. Existing access remains unchanged."
        }
    }

    private var githubAffectedScope: String {
        let workspaces = workspacePolicy.map(\.workspace).sorted()
        return workspaces.isEmpty ? "GitHub setup" : workspaces.joined(separator: ", ")
    }

    private var githubVerificationAge: String {
        let latest = existingMetadata.map(\.updatedAt).max()
        return latest.map(verificationAge) ?? "Not checked yet"
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
            var modes: [String: GitHubRepositoryAccessMode] = [:]
            var isCurrent = true
            for (repositoryID, repositoryName) in zip(guest.repositoryIDs, guest.repositoryNames) {
                guard let repository = byID[repositoryID],
                      repository.fullName.caseInsensitiveCompare(repositoryName) == .orderedSame else {
                    isCurrent = false
                    break
                }
                modes[GitHubLocalProvider.canonicalize(repository.fullName)] = hostEntries.contains {
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
            message: "The repositories previously chosen for \(workspace) no longer match those available from GitHub. Reconnect to review them."
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
            var draft = drafts[policy.workspace] ?? .initial(workspace)
            let installationIDs = Set(policy.repositories.map(\.installationID))
            if accessMode == .connect {
                // Connect retains the one-installation-per-workspace rule.
                guard installationIDs.count <= 1 else { continue }
                draft.installationID = installationIDs.first
            } else {
                // Local mode spans owners; entries are canonical-keyed.
                draft.installationID = nil
            }
            draft.repositoryModes = Dictionary(
                uniqueKeysWithValues: policy.repositories.map {
                    (GitHubLocalProvider.canonicalize($0.fullName), $0.mode)
                }
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
            githubStatus = "GitHub skipped by choice. You can connect later from Settings."
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
        case .preflight: return "Requirements"
        case .toolchain: return "Tools"
        case .hostIntegration: return "System access"
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


private struct HoverTooltipModifier: ViewModifier {
    let text: String
    let accessibilityIdentifier: String
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .onHover { isPresented = $0 }
            .popover(isPresented: $isPresented, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                Text(text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(width: 300, alignment: .leading)
                    .accessibilityIdentifier(accessibilityIdentifier)
            }
    }
}


private extension View {
    func hoverTooltip(_ text: String, accessibilityIdentifier: String) -> some View {
        modifier(HoverTooltipModifier(
            text: text,
            accessibilityIdentifier: accessibilityIdentifier
        ))
    }
}


private struct InformationTooltip: View {
    let text: String
    let accessibilityLabel: String
    let accessibilityIdentifier: String

    var body: some View {
        Image(systemName: "info.circle")
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
            .hoverTooltip(text, accessibilityIdentifier: "\(accessibilityIdentifier).tooltip")
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier(accessibilityIdentifier)
    }
}


/// Compact, searchable multi-selection picker. The persisted modes remain the
/// policy source of truth; the push toggle maps directly to read-only/read-write.
private struct RepositoryWorkspacePolicyEditor: View {
    let installations: [GitHubInstallation]
    let repositoriesByInstallation: [Int: [GitHubRepository]]
    let accessMode: GitHubAccessMode
    @Binding var drafts: [String: WorkspaceRepositoryDraft]
    @Binding var editedWorkspaces: Set<String>
    let disabled: Bool
    let onEdit: () -> Void
    private static let pushHelp = "Push to GitHub from inside this workspace's VM. You can always push from outside the VM using MSW Monitor."
    private static let pushDeniedHelp = "GitHub does not grant push access to this repository. Neither the VM nor MSW Monitor can push until that access changes."
    @State private var openPicker: String?
    @State private var searchQueries: [String: String] = [:]

    private var sortedInstallations: [GitHubInstallation] {
        installations.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Text("Workspace Access").font(.headline)
                InformationTooltip(
                    text: Self.pushHelp,
                    accessibilityLabel: "Workspace Access information",
                    accessibilityIdentifier: "setup.github.workspace-access.info"
                )
            }
            ForEach(Workspace.ID.allCases, id: \.rawValue) { workspace in
                workspaceSection(workspace)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func workspaceSection(_ workspace: Workspace.ID) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(workspace.rawValue).font(.callout.weight(.semibold))
                Spacer()
                Button {
                    searchQueries[workspace.rawValue] = ""
                    openPicker = workspace.rawValue
                } label: {
                    Label(selectionTitle(for: workspace), systemImage: "chevron.up.chevron.down")
                        .frame(width: 142, alignment: .leading)
                }
                .disabled(disabled)
                .accessibilityLabel("Choose repositories for \(workspace.rawValue)")
                .accessibilityValue(selectionTitle(for: workspace))
                .accessibilityIdentifier("github.workspace.\(workspace.rawValue).repository-picker.button")
                .popover(isPresented: pickerPresented(for: workspace), arrowEdge: .bottom) {
                    repositoryPicker(for: workspace)
                }
            }
            let selected = selectedRepositories(for: workspace)
            if !selected.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(selected, id: \.repository.id) { selection in
                            selectedRepositoryRow(
                                workspace,
                                repository: selection.repository,
                                installation: selection.installation
                            )
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
        }
        .padding(8)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func repositoryPicker(for workspace: Workspace.ID) -> some View {
        let matches = filteredRepositories(for: workspace)
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search repositories", text: searchBinding(for: workspace))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("github.workspace.\(workspace.rawValue).repository-picker.search")
            if matches.isEmpty {
                Text(searchQueries[workspace.rawValue, default: ""].isEmpty
                    ? "No repositories" : "No matches")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityIdentifier("github.workspace.\(workspace.rawValue).repository-picker.empty")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(matches, id: \.repository.id) { entry in
                            Toggle(entry.repository.fullName, isOn: selectionBinding(
                                workspace,
                                repository: entry.repository,
                                installation: entry.installation
                            ))
                            .toggleStyle(.checkbox)
                            .padding(.vertical, 4)
                            .disabled(disabled || selectionBlocked(workspace, installation: entry.installation))
                            .accessibilityIdentifier("github.workspace.\(workspace.rawValue).repository.\(entry.repository.id)")
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(12)
        .frame(width: 340)
    }

    @ViewBuilder
    private func selectedRepositoryRow(
        _ workspace: Workspace.ID,
        repository: GitHubRepository,
        installation: GitHubInstallation
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text(repository.fullName).lineLimit(1)
            Spacer(minLength: 8)
            Toggle("Allow pushes", isOn: pushBinding(
                workspace,
                repository: repository,
                installation: installation
            ))
            .toggleStyle(.switch)
            .accessibilityLabel("Allow pushes")
            .controlSize(.small)
            .disabled(disabled || repository.canPush == false)
            .hoverTooltip(
                repository.canPush == false ? Self.pushDeniedHelp : Self.pushHelp,
                accessibilityIdentifier: "github.workspace.\(workspace.rawValue).repository.\(repository.id).allow-pushes.tooltip"
            )
            .accessibilityIdentifier("github.workspace.\(workspace.rawValue).repository.\(repository.id).allow-pushes")
        }
        .padding(.leading, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("github.workspace.\(workspace.rawValue).selection.\(repository.id)")
    }

    private typealias RepositoryEntry = (repository: GitHubRepository, installation: GitHubInstallation)

    private var allRepositories: [RepositoryEntry] {
        sortedInstallations.flatMap { installation in
            (repositoriesByInstallation[installation.id] ?? []).map { ($0, installation) }
        }.sorted {
            $0.repository.fullName.localizedCaseInsensitiveCompare($1.repository.fullName) == .orderedAscending
        }
    }

    private func filteredRepositories(for workspace: Workspace.ID) -> [RepositoryEntry] {
        let query = searchQueries[workspace.rawValue, default: ""]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return allRepositories }
        return allRepositories.filter { $0.repository.fullName.localizedCaseInsensitiveContains(query) }
    }

    private func selectedRepositories(for workspace: Workspace.ID) -> [RepositoryEntry] {
        allRepositories.filter { isSelected(workspace, repository: $0.repository, installation: $0.installation) }
    }

    private func selectionTitle(for workspace: Workspace.ID) -> String {
        let count = selectedRepositories(for: workspace).count
        return count == 0 ? "Choose repositories" : "\(count) selected"
    }

    private func pickerPresented(for workspace: Workspace.ID) -> Binding<Bool> {
        Binding(
            get: { openPicker == workspace.rawValue },
            set: { if !$0 { openPicker = nil } }
        )
    }

    private func searchBinding(for workspace: Workspace.ID) -> Binding<String> {
        Binding(
            get: { searchQueries[workspace.rawValue, default: ""] },
            set: { searchQueries[workspace.rawValue] = $0 }
        )
    }

    private static func canonicalKey(_ repository: GitHubRepository) -> String {
        GitHubLocalProvider.canonicalize(repository.fullName)
    }

    private func isSelected(
        _ workspace: Workspace.ID,
        repository: GitHubRepository,
        installation: GitHubInstallation
    ) -> Bool {
        let draft = drafts[workspace.rawValue] ?? .initial(workspace)
        guard draft.repositoryModes[Self.canonicalKey(repository)] != nil else { return false }
        if accessMode == .connect {
            return draft.installationID == installation.id
        }
        // Local mode spans owners: any selected canonical repo counts.
        return true
    }

    private func selectionBlocked(_ workspace: Workspace.ID, installation: GitHubInstallation) -> Bool {
        guard accessMode == .connect,
              let selectedInstallation = drafts[workspace.rawValue]?.installationID else { return false }
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
                    if accessMode == .connect {
                        guard draft.installationID == nil || draft.installationID == installation.id else { return }
                        draft.installationID = installation.id
                    }
                    draft.repositoryModes[Self.canonicalKey(repository)] = .readOnly
                } else {
                    draft.repositoryModes.removeValue(forKey: Self.canonicalKey(repository))
                    if draft.repositoryModes.isEmpty { draft.installationID = nil }
                }
                drafts[workspace.rawValue] = draft
                editedWorkspaces.insert(workspace.rawValue)
                onEdit()
            }
        )
    }

    private func pushBinding(
        _ workspace: Workspace.ID,
        repository: GitHubRepository,
        installation: GitHubInstallation
    ) -> Binding<Bool> {
        Binding(
            get: {
                guard isSelected(workspace, repository: repository, installation: installation) else { return false }
                let mode = drafts[workspace.rawValue]?.repositoryModes[Self.canonicalKey(repository)] ?? .readOnly
                return repository.effectiveMode(mode) == .readWrite
            },
            set: { allowsPushes in
                guard var draft = drafts[workspace.rawValue],
                      draft.repositoryModes[Self.canonicalKey(repository)] != nil,
                      repository.canPush != false else { return }
                if accessMode == .connect, draft.installationID != installation.id { return }
                draft.repositoryModes[Self.canonicalKey(repository)] = allowsPushes ? .readWrite : .readOnly
                drafts[workspace.rawValue] = draft
                editedWorkspaces.insert(workspace.rawValue)
                onEdit()
            }
        )
    }
}
