import AppKit
import SwiftUI

@MainActor
final class SetupWindowController {
    private let window: NSWindow

    init(
        coordinator: (any MSWBootstrapCoordinating)?,
        authorizationCoordinator: GitHubAuthorizationCoordinator? = nil,
        deviceFlow: GitHubDeviceFlow? = nil,
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
                deviceFlow: deviceFlow,
                deviceInstallationURL: githubInstallationURL,
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
    var verifiedIdentityByWorkspace: [String: SetupVerifiedIdentity]?
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
    case failed
}

private struct AuthorizationIssue: Identifiable {
    let kind: AuthorizationIssueKind
    let message: String
    var id: String { kind.rawValue }
}
private struct RepositoryLoadIdentity: Equatable, Sendable {
    let generation: Int
    let workspace: Workspace.ID
    let installationID: Int
    let sessionID: UUID
}

/// Single source of truth for the GitHub connection header so it can never
/// contradict the connection section (device flow when configured).
enum GitHubConnectionPresentation: Equatable {
    case notConnected
    case signedInAwaitingRepositories(account: GitHubAccount)
    case refreshFailed(account: GitHubAccount)
    case connected(account: GitHubAccount)
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

/// Authoritative setup-window/device-flow lifecycle barrier, separate from
/// the task generations (`deviceRefreshGeneration`,
/// `deviceVerificationGeneration`, `deviceRepositoryPollGeneration`).
/// Teardown that makes the setup surface invalid — window `willClose`,
/// `.onDisappear`, and explicit device-flow cancellation — bumps the
/// generation; restore/verification continuations captured it before their
/// first await and must re-check it after every await that could create a
/// refresh, assign UI state, publish a timestamp/status, or restart polling.
/// A reference type so the generation is shared across SwiftUI struct copies
/// (and observable by the barrier ordering tests).
@MainActor
final class DeviceSetupLifecycleGate {
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
    let deviceFlow: GitHubDeviceFlow?
    let deviceInstallationURL: URL?
    let openSettings: (SettingsSection) -> Void
    let closeSetup: () -> Void
    let uiTestMode: Bool
    let uiTestStartsInReview: Bool
    let uiTestGitHubScenario: String?
    let uiTestBootstrapReconnect: Bool
    let startupRecoveryBlockedReason: String?
    let retryStartupRecovery: () -> Void
    /// Authoritative UI barrier for this setup window/device flow (see
    /// `DeviceSetupLifecycleGate`). Teardown paths bump it; restore and
    /// verification continuations capture it before their first await and
    /// guard their publications against it.
    let setupLifecycle: DeviceSetupLifecycleGate
    /// Session revalidation seam: production uses the process-wide shared
    /// refresher; the barrier ordering tests inject a store-backed instance
    /// so revalidation can be driven deterministically.
    let deviceSessionRefresher: GitHubDeviceSessionRefresher
    /// Opens GitHub's device verification page in the browser. Injectable so
    /// the deterministic device-flow barrier tests never launch a real
    /// browser (same convention as `MSWConnectBrowser(opener:)`).
    let openDeviceVerificationPage: (URL) -> Bool
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
        ($0.rawValue, WorkspaceAssignmentDraft.initial($0))
    })
    @State private var existingMetadata: [WorkspaceCredentialMetadata] = []
    @State private var authorizationSessionID: UUID?
    @State private var authorizationStatus = ""
    @State private var isAuthorizing = false
    @State private var authorizationMayCancel = false
    @State private var isReviewing = false
    @State private var authorizationTask: Task<Void, Never>?
    @State private var authorizationGeneration = 0
    @State private var uiTestAuthorizationAttempts = 0
    @State private var repositoryLoadGeneration = 0
    @State private var activeRepositoryLoad: RepositoryLoadIdentity?
    @State private var authorizationIssue: AuthorizationIssue?
    @State private var verificationResults: [GitHubWorkspaceVerificationResult] = []
    @State private var githubSkipped = false
    @State private var githubReconnectRequired = false
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
    @State private var deviceAccount: GitHubAccount?
    @State private var deviceAuthorization: GitHubDeviceAuthorization?
    @State private var isConnectingDevice = false
    @State private var deviceStatus = ""
    @State private var deviceIssue: String?
    @State private var deviceRefreshIssue: String?
    @State private var deviceRefreshTask: Task<Bool, Never>?
    @State private var deviceRefreshGeneration = 0
    @State private var deviceReauthorizationRequired = false
    @State private var devicePollTask: Task<Void, Never>?
    @State private var deviceSession: GitHubDeviceSession?
    @State private var deviceRepositoryCount = 0
    @State private var deviceRepositoryPollTask: Task<Void, Never>?
    @State private var deviceRepositoryPollGeneration = 0
    @State private var deviceRepositoryCheckInFlight = false
    @State private var lastDeviceRepositoryCheckAt: Date?
    @State private var deviceAccessibleRepositories: [GitHubRepository] = []
    @State private var workspaceAllowlists: [String: Set<String>] = [:]

    /// Memberwise init re-declared because a struct containing property
    /// wrappers drops defaulted stored properties from the synthesized
    /// memberwise init: `setupLifecycle` and `deviceSessionRefresher` are the
    /// deterministic seams the barrier ordering tests inject (production uses
    /// the defaults — a fresh gate and the process-wide shared refresher).
    init(
        coordinator: (any MSWBootstrapCoordinating)?,
        authorizationCoordinator: GitHubAuthorizationCoordinator?,
        deviceFlow: GitHubDeviceFlow?,
        deviceInstallationURL: URL?,
        openSettings: @escaping (SettingsSection) -> Void,
        closeSetup: @escaping () -> Void,
        uiTestMode: Bool,
        uiTestStartsInReview: Bool,
        uiTestGitHubScenario: String?,
        uiTestBootstrapReconnect: Bool,
        startupRecoveryBlockedReason: String?,
        retryStartupRecovery: @escaping () -> Void,
        setupLifecycle: DeviceSetupLifecycleGate = DeviceSetupLifecycleGate(),
        deviceSessionRefresher: GitHubDeviceSessionRefresher = .shared,
        openDeviceVerificationPage: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.coordinator = coordinator
        self.authorizationCoordinator = authorizationCoordinator
        self.deviceFlow = deviceFlow
        self.deviceInstallationURL = deviceInstallationURL
        self.openSettings = openSettings
        self.closeSetup = closeSetup
        self.uiTestMode = uiTestMode
        self.uiTestStartsInReview = uiTestStartsInReview
        self.uiTestGitHubScenario = uiTestGitHubScenario
        self.uiTestBootstrapReconnect = uiTestBootstrapReconnect
        self.startupRecoveryBlockedReason = startupRecoveryBlockedReason
        self.retryStartupRecovery = retryStartupRecovery
        self.setupLifecycle = setupLifecycle
        self.deviceSessionRefresher = deviceSessionRefresher
        self.openDeviceVerificationPage = openDeviceVerificationPage
    }

    private static let resumeStateKey = "setup.resume.nonsecret.v1"

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Set up MSW Monitor")
                    .font(.largeTitle.weight(.semibold))
                Text("Complete four quick steps. GitHub and Git identity are optional and can be configured later.")
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
            // The setup surface is gone: bump the authoritative lifecycle so
            // no in-flight restore/verification continuation can create a
            // refresh, publish state, stamp the schedule, or restart polling.
            // The poll and verification tasks are cancelled as well, so a
            // late device-code token or verification stops immediately.
            setupLifecycle.invalidate()
            pauseAuthorization()
            stopDeviceRepositoryPolling()
            deviceRefreshTask?.cancel()
            deviceRefreshTask = nil
            devicePollTask?.cancel()
            devicePollTask = nil
            deviceVerificationTask?.cancel()
            deviceVerificationTask = nil
            githubSkipTask?.cancel()
        }
        .onChange(of: activeStep) { _, newStep in
            if newStep == .github {
                startDeviceRepositoryPollingIfNeeded()
            } else {
                stopDeviceRepositoryPolling()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            handleDeviceWindowBecameKey(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            handleDeviceWindowWillClose(notification)
        }
        .onChange(of: githubDecisionMade) { _, decided in
            if decided { stopDeviceRepositoryPolling() }
        }
        .onChange(of: drafts) { _, _ in
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
             authorizationCoordinator?.isConfigured == true &&
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

    /// Pure decision, unit-tested directly: a device-flow sign-in alone is not
    /// enough — GitHub must confirm at least one repository is actually
    /// accessible to the App (an installation with zero accessible
    /// repositories grants nothing). Skipping, or existing grant metadata,
    /// still decides it explicitly.
    static func deviceAccessDecided(signedIn: Bool, repositoryCount: Int) -> Bool {
        signedIn && repositoryCount > 0
    }

    /// Maps a repository re-check failure to a user-facing, actionable message
    /// so an auth/transport/decode error is never mistaken for a genuine empty
    /// selection. Pure and static for direct unit testing.
    static func deviceRefreshIssueMessage(for error: Error, action: String) -> String {
        let detail = (error as? LocalizedError)?.errorDescription ?? "Unexpected error."
        return "GitHub reported an error \(action): \(detail)"
    }

    /// The account label for the device section. A refresh failure takes
    /// precedence over the zero-selection wording: while `refreshIssue` is
    /// set the section must never claim nothing is selected, because the
    /// re-check itself failed to establish that.
    static func deviceAccountLabel(login: String, repositoryCount: Int, refreshIssue: String?) -> String {
        if deviceAccessDecided(signedIn: true, repositoryCount: repositoryCount) {
            return "Connected as @\(login)"
        }
        if refreshIssue != nil {
            return "Signed in as @\(login), but repository status could not be refreshed."
        }
        return "Signed in as @\(login), but no repositories are selected yet."
    }

    /// The signed-in status line for the device section. Same precedence
    /// rule as `deviceAccountLabel`: an active refresh failure replaces the
    /// zero-selection wording instead of coexisting with it.
    static func deviceRepositorySignedInLine(login: String, repositoryCount: Int, refreshIssue: String?) -> String {
        if deviceAccessDecided(signedIn: true, repositoryCount: repositoryCount) {
            return "Connected as @\(login). Repositories selected on GitHub are available."
        }
        if refreshIssue != nil {
            return "Signed in as @\(login), but repository status could not be refreshed."
        }
        return "Signed in as @\(login), but no repositories are selected yet. Install the MSW App and pick repositories, or continue without GitHub."
    }
    /// Pure derivation, unit-tested: which state the GitHub connection header
    /// must present. A device account is authoritative whenever present
    /// because it only exists on the device-flow path this build presents.
    static func connectionPresentation(
        account: GitHubAccount?,
        deviceAccount: GitHubAccount?,
        deviceRepositoryCount: Int,
        deviceRefreshIssue: String? = nil
    ) -> GitHubConnectionPresentation {
        if let deviceAccount {
            if deviceAccessDecided(signedIn: true, repositoryCount: deviceRepositoryCount) {
                return .connected(account: deviceAccount)
            }
            // Issue 2 owns the refresh-error input: while a re-check failed,
            // the header must not claim nothing is selected — the re-check
            // itself failed to establish that.
            if deviceRefreshIssue != nil {
                return .refreshFailed(account: deviceAccount)
            }
            return .signedInAwaitingRepositories(account: deviceAccount)
        }
        if let account {
            return .connected(account: account)
        }
        return .notConnected
    }

    private var githubConnectionPresentation: GitHubConnectionPresentation {
        // Device sessions only exist on the device-flow path this build
        // presents, so its account is authoritative over any restored MSW
        // Connect coordinator session.
        Self.connectionPresentation(
            account: account,
            deviceAccount: deviceAccount,
            deviceRepositoryCount: deviceRepositoryCount,
            deviceRefreshIssue: deviceRefreshIssue
        )
    }
    private var githubDecisionMade: Bool {
        githubSkipped ||
            Self.deviceAccessDecided(signedIn: deviceAccount != nil, repositoryCount: deviceRepositoryCount) ||
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
            Text("MSW Monitor did not expose workspace credentials because an interrupted GitHub authorization transaction could not be reconciled safely.")
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
        guard githubStepComplete else { return }
        activeStep = .identity
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
            VStack(alignment: .leading, spacing: 2) {
                Text("GitHub access").font(.title3.weight(.semibold))
                Text("Optional — connect, review, and apply per workspace")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            switch githubConnectionPresentation {
            case .notConnected:
                Label("GitHub is not connected", systemImage: "person.crop.circle.badge.questionmark")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("setup.github.disconnected")
                Text("GitHub is optional. You can connect it now or configure it later in Settings.")
                    .font(.caption)
            case .signedInAwaitingRepositories(let account):
                Label("Signed in as @\(account.login), but no repositories are selected yet.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("setup.github.account")
                Text("GitHub identity is stored in the Mac Keychain. Pick repositories on GitHub, then check again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .refreshFailed(let account):
                Label("Signed in as @\(account.login), but repository status could not be refreshed.", systemImage: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("setup.github.account")
                Text(deviceReauthorizationRequired
                    ? "Reconnect to GitHub to continue."
                    : "Check the network connection and try checking again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .connected(let account):
                Label("Connected as @\(account.login)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("setup.github.account")
                Text(githubIdentityDisclosure(account))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Choose which workspaces can see which repositories. Nothing is changed until you review and apply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let workspace = githubAttentionWorkspace {
                Label(
                    githubAttentionReapplyRequired
                        ? "GitHub access for \(workspace) needs attention. Re-apply GitHub access for \(workspace) to finish reconnecting."
                        : "GitHub access for \(workspace) needs attention.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("setup.github.attention")
            }

            if (authorizationCoordinator == nil && uiTestGitHubScenario == nil) ||
                uiTestGitHubScenario == "unavailable" {
                Text(uiTestGitHubScenario == "unavailable"
                    ? "GitHub connection is unavailable. The existing access and saved choices remain unchanged; retry after MSW Connect is available."
                    : "GitHub connection is unavailable in this build. You can continue without it and configure it later from Settings.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("setup.github.unavailable")
            } else if uiTestGitHubScenario != nil {
                Button(isAuthorizing ? "Opening GitHub…" : "Connect GitHub", action: beginAuthorization)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canConnectGitHub || isAuthorizing)
                    .accessibilityIdentifier("setup.github.connect.button")
            } else if deviceFlow != nil {
                deviceFlowSection
            } else if !(authorizationCoordinator?.isConfigured ?? false) {
                Text("GitHub connection isn't available yet. Continue and connect later in Settings.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("setup.github.unavailable")
            } else {
                Text("Connect GitHub opens the authorization page in your default browser.")
                    .foregroundStyle(.secondary)
                Button(isAuthorizing ? "Opening GitHub…" : "Connect GitHub", action: beginAuthorization)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canConnectGitHub || isAuthorizing)
                    .accessibilityIdentifier("setup.github.connect.button")
            }
            if canFinishWithoutGitHub {
                Button("Continue without GitHub") {
                    githubSkipped = true
                    authorizationIssue = nil
                    githubAttentionWorkspace = nil
                    authorizationStatus = "GitHub skipped by choice. You can connect later from Settings."
                    activeStep = .identity
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(githubSkipped)
                .accessibilityIdentifier("setup.github.skip.button")
            }

            if account != nil {
                if installations.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("MSW App is not installed for an owner yet.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Install the MSW App for the GitHub owner that should provide repositories, then connect GitHub again.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if Self.validatedInstallationURL(githubInstallationURL) != nil {
                            Button("Install MSW App in GitHub", action: openGitHubInstallation)
                                .accessibilityIdentifier("setup.github.install.button")
                        } else {
                            Text("This build has no verified GitHub App installation link. Ask your release administrator for the approved installation URL.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
                VStack(alignment: .leading, spacing: 7) {
                    Label(issueTitle(authorizationIssue.kind), systemImage: issueSymbol(authorizationIssue.kind))
                        .font(.callout.weight(.semibold))
                    LabeledContent("Cause", value: authorizationIssue.message)
                    LabeledContent("Affected", value: githubAffectedScope)
                    LabeledContent("Last verified", value: githubVerificationAge)
                    LabeledContent("Blocked", value: "Applying reviewed GitHub workspace grants")
                    Text(issueRecovery(authorizationIssue.kind)).font(.caption).foregroundStyle(.secondary)
                    Button("Retry GitHub authorization", action: beginAuthorization)
                        .disabled(!canConnectGitHub || isAuthorizing)
                        .accessibilityIdentifier("setup.github.retry.button")
                }
                .font(.caption)
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
                        Button("Manage") { openSettings(.github) }
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

            if canFinishWithoutGitHub && !existingMetadata.isEmpty && account == nil {
                Button("Continue with existing GitHub access") {
                    githubSkipped = false
                    authorizationStatus = "Existing access will be kept. Connect again only if you need to change repository assignments."
                }
                .accessibilityIdentifier("setup.github.keep.button")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup.github-boundary")
    }

    private var deviceFlowSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let deviceAccount {
                let connected = Self.deviceAccessDecided(signedIn: true, repositoryCount: deviceRepositoryCount)
                Label(
                    Self.deviceAccountLabel(
                        login: deviceAccount.login,
                        repositoryCount: deviceRepositoryCount,
                        refreshIssue: deviceRefreshIssue
                    ),
                    systemImage: connected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(connected ? Color.green : (deviceRefreshIssue != nil ? Color.red : Color.orange))
                .accessibilityIdentifier("setup.github.account")
                Text("Your credential is stored in the Mac Keychain. Workspaces never see it; GitHub access for workspaces is host-mediated.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if Self.validatedInstallationURL(deviceInstallationURL) != nil {
                    Button("Choose repositories on GitHub", action: openDeviceInstallation)
                        .accessibilityIdentifier("setup.github.pick.button")
                } else {
                    Text("Repositories are chosen on GitHub's App installation page. This build has no installation link configured.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if deviceRepositoryCount == 0, let deviceSession, !deviceReauthorizationRequired {
                    Button("Check again") {
                        // Tracked wrapper over the single-flight entry: the
                        // guarded entry owns the refresh task, so a manual
                        // press coalesces with any in-flight re-check instead
                        // of bypassing it. Recording the completion time keeps
                        // the poller's wait satisfied by this check too — but
                        // only when the check actually completed and
                        // published, so a cancelled attempt never throttles
                        // later real checks.
                        Task {
                            let completed = await refreshDeviceRepositoryCount(accessToken: deviceSession.accessToken)
                            if completed { lastDeviceRepositoryCheckAt = Date() }
                        }
                    }
                    .accessibilityIdentifier("setup.github.refresh.button")
                }
                if deviceReauthorizationRequired {
                    // A consumed/poisoned generation has no retry path: the
                    // only recovery is a fresh device-flow authorization.
                    Button("Reconnect GitHub", action: reconnectDeviceAccount)
                        .accessibilityIdentifier("setup.github.reconnect.button")
                }
                if let deviceRefreshIssue {
                    Label(deviceRefreshIssue, systemImage: "exclamationmark.octagon.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("setup.github.refresh.issue")
                }
                if deviceRepositoryPollTask != nil, deviceRefreshIssue == nil {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for repository selection on GitHub…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("setup.github.waiting")
                }
                if !deviceAccessibleRepositories.isEmpty {
                    workspaceAccessSection
                }
            } else if isConnectingDevice {
                if let authorization = deviceAuthorization {
                    Text("Enter this code on GitHub: \(authorization.userCode)")
                        .font(.body.weight(.semibold))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("setup.github.device-code")
                    Text("GitHub opened in your default browser. Approve the code there, then wait.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(deviceStatus).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel wait", action: cancelDeviceFlow)
                        .accessibilityIdentifier("setup.github.cancel.button")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("setup.github.progress")
            } else {
                Text("Connect GitHub opens GitHub in your default browser: approve the code there and pick your repositories on the App installation page. The credential stays in the Mac Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Connect GitHub") { _ = startDeviceFlow() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("setup.github.connect.button")
                if let deviceIssue {
                    Text(deviceIssue)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("setup.github.issue")
                }
            }
            if !deviceStatus.isEmpty && !isConnectingDevice {
                Text(deviceStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("setup.github.status")
            }
        }
    }

    private var workspaceAccessSection: some View {
        WorkspaceGitHubAccessEditor(
            repositories: deviceAccessibleRepositories,
            allowlists: workspaceAllowlists,
            onToggle: setWorkspaceAllowlist
        )
        .accessibilityIdentifier("setup.github.workspace-access")
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
                    .disabled(isAuthorizing)
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
                .disabled(isAuthorizing)
                .accessibilityIdentifier("setup.github.workspace.\(workspace.rawValue).owner")
            }
            if draft.enabled && !repositories.isEmpty {
                Text("Allowed repositories").font(.caption.weight(.semibold))
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(repositories) { repository in
                        Toggle(repository.fullName, isOn: repositoryBinding(for: workspace, repositoryID: repository.id))
                            .toggleStyle(.checkbox)
                            .disabled(isAuthorizing)
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
                .disabled(isAuthorizing)
                .accessibilityIdentifier("setup.github.workspace.\(workspace.rawValue).verification")
                Picker("Access mode", selection: draftBinding(for: workspace).accessMode) {
                    Text("Read-only").tag("read-only")
                    Text("Read + write").tag("read-write")
                }
                .disabled(isAuthorizing)
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
                    if !result.verified || !result.lifecycleRestored {
                        Text("Blocked: GitHub repository access for \(result.workspace) until verification and lifecycle restoration succeed.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button("Reauthorize \(result.workspace)", action: beginAuthorization)
                            .disabled(!canConnectGitHub || isAuthorizing)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("setup.github.verification.\(result.workspace)")
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
            HStack {
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
                .controlSize(.large)
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
                : "Connect GitHub or continue without it."
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
                    Button(isAuthorizing ? "Applying…" : "Apply assignments", action: commitAssignments)
                        .buttonStyle(.borderedProminent)
                        .disabled(isAuthorizing || !hasValidAssignments)
                        .accessibilityIdentifier("setup.github.apply.button")
                } else {
                    if account != nil {
                        Button("Review workspace access") { isReviewing = true }
                            .buttonStyle(.borderedProminent)
                            .disabled(!hasValidAssignments || isAuthorizing)
                            .accessibilityIdentifier("setup.github.review.button")
                    }
                    Button("Continue", action: advanceFromGitHub)
                        .buttonStyle(.borderedProminent)
                        .disabled(!githubStepComplete || isAuthorizing)
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

    private var validDrafts: [WorkspaceAssignmentDraft] {
        drafts.values.filter(isReviewable).sorted { $0.workspace.rawValue < $1.workspace.rawValue }
    }

    private var enabledDrafts: [WorkspaceAssignmentDraft] {
        drafts.values.filter(\.enabled)
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

    private var hasValidAssignments: Bool {
        !enabledDrafts.isEmpty && enabledDrafts.allSatisfy(isReviewable)
    }

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
        if uiTestGitHubScenario == "unavailable" {
            authorizationIssue = AuthorizationIssue(
                kind: .unavailable,
                message: "The deterministic test service is unavailable. Existing access and saved choices remain unchanged."
            )
            authorizationStatus = ""
            return
        }
        if uiTestGitHubScenario == nil, authorizationCoordinator == nil {
            authorizationIssue = AuthorizationIssue(
                kind: .unavailable,
                message: "GitHub authorization is unavailable in this build."
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
                    isAuthorizing = false
                    authorizationMayCancel = false
                    authorizationTask = nil
                    githubSkipped = false
                    githubAttentionWorkspace = nil
                    authorizationStatus = discovery.installations.isEmpty
                        ? "Connected as @\(discovery.account.login), but no MSW App installation was found. Install the app, then connect GitHub again."
                        : "Connected as @\(discovery.account.login). Assign repositories to each workspace, then review before applying."
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
                await MainActor.run {
                    guard authorizationGeneration == generation else { return }
                    account = discovery.account
                    installations = discovery.installations
                    githubInstallationURL = Self.validatedInstallationURL(installURL)
                    authorizationSessionID = discovery.sessionID
                    isAuthorizing = false
                    authorizationMayCancel = false
                    authorizationTask = nil
                    githubSkipped = false
                    githubAttentionWorkspace = nil
                    authorizationStatus = "Connected as @\(discovery.account.login). Assign repositories to each workspace, then review before applying."
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

    private func invalidateRepositoryLoad() -> Bool {
        guard activeRepositoryLoad != nil else { return false }
        authorizationGeneration &+= 1
        authorizationTask?.cancel()
        activeRepositoryLoad = nil
        repositoryLoadGeneration += 1
        return true
    }

    private func loadRepositories(for workspace: Workspace.ID, installationID: Int?) {
        let cancelledLoad = invalidateRepositoryLoad()
        if cancelledLoad {
            authorizationTask = nil
            isAuthorizing = false
            authorizationMayCancel = false
            authorizationIssue = nil
            authorizationStatus = "Select the repositories for each workspace."
        }
        guard let sessionID = authorizationSessionID,
              let installationID else {
            return
        }
        if uiTestGitHubScenario != nil {
            repositoriesByInstallation[installationID] = Self.uiTestRepositories
            isAuthorizing = false
            authorizationMayCancel = false
            authorizationTask = nil
            authorizationStatus = "Select the repositories for each workspace."
            return
        }
        guard let authorizationCoordinator else {
            return
        }
        if repositoriesByInstallation[installationID] != nil {
            if cancelledLoad {
                authorizationIssue = nil
                authorizationStatus = "Select the repositories for each workspace."
            }
            return
        }
        repositoryLoadGeneration += 1
        let identity = RepositoryLoadIdentity(
            generation: repositoryLoadGeneration,
            workspace: workspace,
            installationID: installationID,
            sessionID: sessionID
        )
        activeRepositoryLoad = identity
        isAuthorizing = true
        authorizationMayCancel = true
        authorizationIssue = nil
        authorizationStatus = "Loading repositories allowed by the selected installation…"
        authorizationTask = Task {
            do {
                let repositories = try await authorizationCoordinator.repositories(
                    sessionID: sessionID,
                    installationID: installationID
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard activeRepositoryLoad == identity,
                          repositoryLoadGeneration == identity.generation else {
                        return
                    }
                    activeRepositoryLoad = nil
                    repositoriesByInstallation[installationID] = repositories
                    isAuthorizing = false
                    authorizationMayCancel = false
                    authorizationTask = nil
                    authorizationStatus = "Select the repositories for each workspace."
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard activeRepositoryLoad == identity,
                          repositoryLoadGeneration == identity.generation else {
                        return
                    }
                    activeRepositoryLoad = nil
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

        authorizationGeneration &+= 1
        let generation = authorizationGeneration
        isAuthorizing = true
        authorizationMayCancel = false
        authorizationIssue = nil
        authorizationStatus = "Creating reviewed grants, binding guest/host access, and verifying repository boundaries…"
        authorizationTask?.cancel()

        if uiTestGitHubScenario != nil {
            authorizationTask = Task {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
                let verifications = assignments.map {
                    GitHubWorkspaceVerificationResult(
                        workspace: $0.workspace,
                        accessMode: $0.accessMode,
                        verificationRepository: $0.verificationRepository,
                        verified: true,
                        lifecycleRestored: true,
                        safetyResult: "Repository scope and workspace lifecycle verified.",
                        checkedAt: Date()
                    )
                }
                await MainActor.run {
                    guard authorizationGeneration == generation else { return }
                    existingMetadata = []
                    verificationResults = verifications
                    isAuthorizing = false
                    authorizationMayCancel = false
                    authorizationTask = nil
                    githubAttentionWorkspace = nil
                    authorizationSessionID = nil
                    isReviewing = false
                    authorizationStatus = "Applied \(assignments.count) scoped grant records. Verification results are retained below for final review."
                }
            }
            return
        }

        guard let authorizationCoordinator,
              let sessionID = authorizationSessionID else {
            authorizationStatus = "Connect GitHub before applying workspace assignments."
            isAuthorizing = false
            return
        }
        authorizationTask = Task {
            do {
                let result = try await authorizationCoordinator.commitAssignmentsWithVerification(
                    sessionID: sessionID,
                    assignments: assignments
                )
                let refreshed = await authorizationCoordinator.metadata()
                await MainActor.run {
                    guard authorizationGeneration == generation else { return }
                    existingMetadata = refreshed
                    verificationResults = result.verifications
                    isAuthorizing = false
                    authorizationMayCancel = false
                    authorizationTask = nil
                    githubAttentionWorkspace = nil
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
        let wasRepositoryLoad = activeRepositoryLoad != nil
        if wasRepositoryLoad {
            _ = invalidateRepositoryLoad()
        } else {
            authorizationGeneration &+= 1
            authorizationTask?.cancel()
        }
        authorizationTask = nil
        if isAuthorizing {
            authorizationIssue = AuthorizationIssue(
                kind: .cancelled,
                message: wasRepositoryLoad
                    ? "Repository loading was cancelled. Existing access and saved owner/repository choices were preserved."
                    : "The browser wait was cancelled. Existing access and saved owner/repository choices were preserved."
            )
        }
        if wasRepositoryLoad {
            authorizationStatus = "Repository loading cancelled. Choose an owner to try again."
        }
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
        let metadata = await authorizationCoordinator.metadata()
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
        guard authorizationCoordinator.isConfigured else { return nil }
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
            let selectedInstallations = Set(drafts.values.compactMap(\.installationID))
            for installationID in selectedInstallations {
                do {
                    let repositories = try await authorizationCoordinator.repositories(
                        sessionID: discovery.sessionID,
                        installationID: installationID
                    )
                    // Guard after the listing await: never publish a
                    // repository list post-close.
                    guard setupLifecycle.isCurrent(startupLifecycle) else { return nil }
                    repositoriesByInstallation[installationID] = repositories
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
    /// testable directly: captures the setup-window/device-flow lifecycle at
    /// the OUTERMOST entry — before any startup await — and re-checks it
    /// after every await. A close that lands while `loadExistingMetadata`,
    /// `restoreCachedAuthorization`, or the restore itself is pending bumps
    /// the stored generation; the guards below then return silently: the
    /// restore is never invoked, no status/context is published, and nothing
    /// polls. Returns whether the startup completed (and may publish
    /// `githubContextLoaded`).
    @discardableResult
    func loadGitHubStartupContext() async -> Bool {
        let startupLifecycle = setupLifecycle.generation
        restoreResumeState()
        loadPreflight()
        await loadExistingMetadata(startupLifecycle: startupLifecycle)
        guard setupLifecycle.isCurrent(startupLifecycle) else { return false }
        await restoreCachedAuthorization(startupLifecycle: startupLifecycle)
        guard setupLifecycle.isCurrent(startupLifecycle) else { return false }
        await restoreDeviceSession(startupLifecycle: startupLifecycle)
        guard setupLifecycle.isCurrent(startupLifecycle) else { return false }
        githubContextLoaded = true
        return true
    }

    /// Restores the stored direct-GitHub session, rotating an expired access
    /// token with its refresh token when available. The setup-window/device-
    /// flow lifecycle token is captured by the OUTERMOST `.task` entry and
    /// passed in (never re-read here): teardown (willClose, onDisappear,
    /// cancelDeviceFlow) bumps the stored generation, so a close that lands
    /// while revalidation is pending — or after a child re-check completed
    /// true but before this continuation — is a terminal no-op. The shared
    /// actor may still finish its Keychain work (credential integrity is
    /// preserved), but nothing revives UI or poll state. Internal so the
    /// barrier ordering tests can drive it deterministically.
    func restoreDeviceSession(startupLifecycle: Int) async {
        guard let deviceFlow else { return }
        let lifecycleGeneration = startupLifecycle
        do {
            let outcome = try await deviceSessionRefresher.revalidatedSession(using: deviceFlow)
            // Guard A: never assign UI state from a restore whose setup
            // surface was torn down while revalidation was pending.
            guard setupLifecycle.isCurrent(lifecycleGeneration) else { return }
            guard case .current(let session, _) = outcome else {
                if case .superseded = outcome {
                    // A concurrent replacement won the epoch; publish nothing.
                    return
                }
                // Quarantine: the consumed generation could not be poisoned.
                // Reauthorization-ONLY — surface the account so the header
                // offers the reconnect control, but never a Check-again retry
                // of the consumed pair.
                deviceRefreshIssue = Self.deviceRefreshIssueMessage(for: GitHubDeviceSessionRefreshError.keychainSaveFailed, action: "refreshing your GitHub session")
                deviceReauthorizationRequired = true
                if let stored = try? GitHubDeviceSessionStore().load() {
                    deviceAccount = stored.account
                    prefillIdentity(from: stored.account)
                }
                return
            }
            guard let session else { return }
            deviceAccount = session.account
            prefillIdentity(from: session.account)
            if session.isAccessExpired {
                // Expired and unrefreshable (or a consumed generation that was
                // poisoned fail-closed): reauthorization-ONLY — no session, no
                // Check again, no polling.
                deviceRefreshIssue = "Your GitHub session has expired and cannot be refreshed. Reconnect to GitHub, then check again."
                deviceReauthorizationRequired = true
                return
            }
            deviceSession = session
            // Guard point 1: never create a NEW refresh task after teardown —
            // `refreshDeviceRepositoryCount` would create it even though the
            // earlier cancellation could only reach a nil/current handle.
            guard setupLifecycle.isCurrent(lifecycleGeneration) else { return }
            let completed = await refreshDeviceRepositoryCount(accessToken: session.accessToken)
            // Guard point 2: after the child returns, still no status, stamp,
            // or poll restart — the child may have completed true (its cancel
            // raced a finished publish) with the close landing in this
            // continuation's scheduling gap. `publishDeviceRepositoryRestoreResult`
            // is the same guarded continuation the ordering test drives.
            publishDeviceRepositoryRestoreResult(
                lifecycleGeneration: lifecycleGeneration,
                completed: completed
            )
        } catch is CancellationError {
            // Startup restore was cancelled; leave state untouched.
        } catch {
            // A genuinely retryable transport failure must not render as
            // "not connected": publish the stored session and keep Check
            // again available — but never after teardown.
            guard setupLifecycle.isCurrent(lifecycleGeneration) else { return }
            if let stored = try? GitHubDeviceSessionStore().load() {
                deviceSession = stored
                deviceAccount = stored.account
                prefillIdentity(from: stored.account)
                deviceRefreshIssue = Self.deviceRefreshIssueMessage(for: error, action: "refreshing your GitHub session")
                deviceStatus = Self.deviceRepositorySignedInLine(
                    login: stored.account.login,
                    repositoryCount: deviceRepositoryCount,
                    refreshIssue: deviceRefreshIssue
                )
            }
            // Without a stored session there is nothing to restore; the user
            // can connect again.
        }
    }

    /// Guarded stamp/status/poll publication of the restore continuation,
    /// shared with the barrier ordering test: both the captured setup
    /// lifecycle AND a completed re-check are required. A stale lifecycle
    /// (close during revalidation or during the child re-check) is a terminal
    /// no-op — nothing is stamped, published, or restarted. Returns whether
    /// the continuation published, which is how the ordering test observes
    /// the decision deterministically.
    @discardableResult
    func publishDeviceRepositoryRestoreResult(lifecycleGeneration: Int, completed: Bool) -> Bool {
        guard setupLifecycle.isCurrent(lifecycleGeneration),
              Self.shouldContinueSetupAfterRecheck(completed: completed) else {
            return false
        }
        lastDeviceRepositoryCheckAt = Date()
        startDeviceRepositoryPollingIfNeeded()
        deviceStatus = Self.deviceRepositorySignedInLine(
            login: deviceAccount?.login ?? "",
            repositoryCount: deviceRepositoryCount,
            refreshIssue: deviceRefreshIssue
        )
        return true
    }

    /// Starts reauthorization from the reauthorization-ONLY state: drop the
    /// stale account so the account-nil branch renders the device-flow states
    /// (code entry, progress, cancellation, failures) end to end;
    /// finishDeviceFlow repopulates the account on success. The
    /// reauthorization-required flag is cleared only by a successful new
    /// session, never by the attempt itself.
    private func reconnectDeviceAccount() {
        deviceAccount = nil
        startDeviceFlow()
    }

    /// Begins a new device flow, returning the poll task so the barrier tests
    /// can AWAIT its terminal completion (a task's completion implies the
    /// carried `finishDeviceFlow` invocation has fully run — a deterministic
    /// barrier, never a sleep). Internal so the device-flow barrier tests can
    /// drive it deterministically.
    @discardableResult
    func startDeviceFlow() -> Task<Void, Never>? {
        guard let deviceFlow else { return nil }
        cancelDeviceFlow()
        // Authoritative token for THIS flow: captured after the reset (which
        // bumped the lifecycle), so the exact epoch the poll and verification
        // continuations must still match after their awaits. The token is
        // carried through the poll task into finishDeviceFlow — never re-read
        // after the poll returns — so a token that arrives after teardown
        // (which bumps the stored generation and cancels the poll) can only
        // be stale.
        let flowLifecycle = setupLifecycle.generation
        isConnectingDevice = true
        deviceIssue = nil
        deviceRefreshIssue = nil
        deviceStatus = "Requesting a GitHub code…"
        let pollTask = Task {
            do {
                let authorization = try await deviceFlow.requestDeviceCode()
                await MainActor.run {
                    // Code/progress publication: terminal after teardown.
                    guard !Task.isCancelled, setupLifecycle.isCurrent(flowLifecycle) else { return }
                    deviceAuthorization = authorization
                    deviceStatus = "Enter the code on GitHub, then approve."
                    _ = openDeviceVerificationPage(GitHubDeviceFlow.verificationURL(for: authorization))
                }
                var interval = authorization.interval
                let deadline = Date().addingTimeInterval(TimeInterval(authorization.expiresIn))
                while true {
                    try await Task.sleep(for: .seconds(interval))
                    if Date() >= deadline {
                        throw GitHubDeviceFlowError.expired
                    }
                    do {
                        let token = try await deviceFlow.pollToken(
                            clientID: deviceFlow.configuration.clientID,
                            deviceCode: authorization.deviceCode
                        )
                        await MainActor.run {
                            _ = finishDeviceFlow(token: token, lifecycleGeneration: flowLifecycle)
                        }
                        return
                    } catch GitHubDeviceFlowError.authorizationPending {
                        continue
                    } catch GitHubDeviceFlowError.slowDown(let slowed) {
                        interval = slowed
                    }
                }
            } catch is CancellationError {
                // Cancelled by the user; state already reset by cancelDeviceFlow.
            } catch {
                await MainActor.run {
                    // Error publication: terminal after teardown.
                    guard !Task.isCancelled, setupLifecycle.isCurrent(flowLifecycle) else { return }
                    isConnectingDevice = false
                    deviceAuthorization = nil
                    deviceStatus = ""
                    deviceIssue = (error as? LocalizedError)?.errorDescription
                        ?? "GitHub connection failed. Try again."
                    devicePollTask = nil
                }
            }
        }
        devicePollTask = pollTask
        return pollTask
    }

    /// Handles a device-code token that the poll obtained. Returns whether
    /// the token was ACCEPTED (a verification was started): a stale carried
    /// lifecycle token is rejected AT ENTRY — before `deviceVerificationTask`
    /// is cancelled, `deviceVerificationGeneration` is bumped, or any status
    /// changes — so a late old-flow token can never cancel or replace a newer
    /// flow's verification. Internal so the barrier tests can invoke the
    /// finish entry synchronously and observe the rejection.
    @discardableResult
    func finishDeviceFlow(token: GitHubDeviceToken, lifecycleGeneration: Int) -> Bool {
        guard let deviceFlow else { return false }
        // A stale carried token (this flow was torn down or superseded while
        // the token was in flight) is terminal AT ENTRY — BEFORE any shared
        // verification state is touched. A late old-flow token must neither
        // cancel the newer valid verification nor bump its generation: the
        // verification identity guard is captured AFTER this check, so the
        // newer flow's generation is untouched and its publication proceeds.
        guard setupLifecycle.isCurrent(lifecycleGeneration) else { return false }
        deviceVerificationTask?.cancel()
        deviceVerificationGeneration &+= 1
        let generation = deviceVerificationGeneration
        // The lifecycle token was captured at startDeviceFlow (after the
        // reset) and carried through the poll: it is NEVER re-read here, so a
        // token that arrives after teardown (which bumps the stored
        // generation and cancels the poll/verification tasks) can only be
        // stale, and every publication below — including the verification's
        // very first await — requires it to still be current. A stale
        // verification emits no fetches, no Keychain write, and no UI.
        deviceVerificationTask = Task {
            // Fail closed BEFORE any verification network work: a late token
            // must not start account/installation fetches, a session write,
            // or any publication.
            guard Self.deviceVerificationMayPublish(
                taskCancelled: Task.isCancelled,
                storedGeneration: deviceVerificationGeneration,
                taskGeneration: generation,
                storedLifecycle: setupLifecycle.generation,
                capturedLifecycle: lifecycleGeneration
            ) else { return }
            do {
                let account = try await deviceFlow.account(accessToken: token.accessToken)
                // A sign-in alone grants nothing: verify that at least one
                // repository is actually accessible to the App before
                // counting the GitHub step as decided.
                let installations = try await deviceFlow.installations(accessToken: token.accessToken)
                var accessibleRepositories: [GitHubRepository] = []
                for installation in installations {
                    let repositories = try await deviceFlow.repositories(
                        accessToken: token.accessToken,
                        installationID: installation.id
                    )
                    accessibleRepositories.append(contentsOf: repositories)
                }
                let accessibleRepositoryCount = accessibleRepositories.count
                let session = GitHubDeviceSession(
                    schemaVersion: 1,
                    clientID: deviceFlow.configuration.clientID,
                    account: account,
                    accessToken: token.accessToken,
                    refreshToken: token.refreshToken,
                    accessExpiresAt: token.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) },
                    refreshExpiresAt: token.refreshExpiresIn.map { Date().addingTimeInterval(TimeInterval($0)) },
                    obtainedAt: Date()
                )
                // Cancelled invocations publish nothing: a cancelled
                // predecessor must neither write the session nor clear a
                // successor's handle.
                guard Self.deviceVerificationMayPublish(
                    taskCancelled: Task.isCancelled,
                    storedGeneration: deviceVerificationGeneration,
                    taskGeneration: generation,
                    storedLifecycle: setupLifecycle.generation,
                    capturedLifecycle: lifecycleGeneration
                ) else { return }
                // Credential integrity: the Keychain write may still finish
                // after a close; the publication guards below keep the UI
                // unrevived.
                try await deviceSessionRefresher.replaceCurrentSession(with: session)
                await MainActor.run {
                    // Cancellation and teardown are terminal for the
                    // publish/stamp/poll block: a stale sign-in publication
                    // or polling restart must never revive state the teardown
                    // owns.
                    guard Self.deviceVerificationMayPublish(
                        taskCancelled: Task.isCancelled,
                        storedGeneration: deviceVerificationGeneration,
                        taskGeneration: generation,
                        storedLifecycle: setupLifecycle.generation,
                        capturedLifecycle: lifecycleGeneration
                    ) else { return }
                    deviceSession = session
                    deviceAccount = account
                    deviceRepositoryCount = accessibleRepositoryCount
                    deviceAccessibleRepositories = accessibleRepositories
                    loadWorkspaceAllowlists(accessibleRepositories: accessibleRepositories)
                    githubAttentionWorkspace = nil
                    deviceRefreshIssue = nil
                    deviceReauthorizationRequired = false
                    isConnectingDevice = false
                    deviceAuthorization = nil
                    devicePollTask = nil
                    lastDeviceRepositoryCheckAt = Date()
                    startDeviceRepositoryPollingIfNeeded()
                    deviceStatus = Self.deviceRepositorySignedInLine(
                        login: account.login,
                        repositoryCount: accessibleRepositories.count,
                        refreshIssue: deviceRefreshIssue
                    )
                    prefillIdentity(from: account)
                }
            } catch is CancellationError {
                // A transport-reported cancellation does not set the
                // task-cancel bit, so it must be caught explicitly: publish
                // nothing (cancelDeviceFlow owns the cancelled state).
                return
            } catch {
                // Cancelled invocations publish nothing: the generation guard
                // keeps a cancelled predecessor from overwriting the explicit
                // cancellation state set by cancelDeviceFlow.
                guard Self.deviceVerificationMayPublish(
                    taskCancelled: Task.isCancelled,
                    storedGeneration: deviceVerificationGeneration,
                    taskGeneration: generation,
                    storedLifecycle: setupLifecycle.generation,
                    capturedLifecycle: lifecycleGeneration
                ) else { return }
                await MainActor.run {
                    guard Self.deviceVerificationMayPublish(
                        taskCancelled: Task.isCancelled,
                        storedGeneration: deviceVerificationGeneration,
                        taskGeneration: generation,
                        storedLifecycle: setupLifecycle.generation,
                        capturedLifecycle: lifecycleGeneration
                    ) else { return }
                    isConnectingDevice = false
                    deviceAuthorization = nil
                    devicePollTask = nil
                    deviceStatus = ""
                    deviceIssue = "GitHub approved the code, but the account could not be verified: \(error.localizedDescription)"
                }
            }
        }
        return true
    }

    /// Pure publication guard, unit-tested directly: a device-flow
    /// verification may publish only while its task is not cancelled, it is
    /// still the current verification, AND the setup-window/device-flow
    /// lifecycle it captured before its first await is still current. Window
    /// close, disappear, or explicit flow cancellation during verification is
    /// terminal for the publish/stamp/poll block — the verification identity
    /// guard alone cannot observe teardown.
    static func deviceVerificationMayPublish(
        taskCancelled: Bool,
        storedGeneration: Int,
        taskGeneration: Int,
        storedLifecycle: Int,
        capturedLifecycle: Int
    ) -> Bool {
        !taskCancelled &&
            verificationTaskIsCurrent(storedGeneration: storedGeneration, taskGeneration: taskGeneration) &&
            storedLifecycle == capturedLifecycle
    }

    /// True while a repository re-check is running (manual button or poller);
    /// Issue 1's poller uses this as an additional in-flight arbiter before
    /// starting its own check.
    var isDeviceRepositoryRefreshInFlight: Bool {
        deviceRefreshTask != nil
    }

    /// Single-flight entry for repository re-checks: concurrent callers (the
    /// poller, focus re-checks, startup restore, the manual "Check again")
    /// coalesce onto the in-flight refresh. Session revalidation
    /// (load → rotate → persist) is additionally serialized by the shared
    /// `GitHubDeviceSessionRefresher` so a single-use refresh token is never
    /// submitted twice. Returns `true` when the re-check completed and
    /// published a result (success or failure); `false` when it was cancelled
    /// or superseded and published nothing — callers stamp the schedule
    /// timestamp only on completed outcomes so a cancelled attempt (window
    /// teardown) never throttles a later real check.
    @discardableResult
    func refreshDeviceRepositoryCount(accessToken: String) async -> Bool {
        if let inFlight = deviceRefreshTask {
            return await inFlight.value
        }
        deviceRefreshGeneration &+= 1
        let generation = deviceRefreshGeneration
        let task = Task { await performDeviceRepositoryRefresh(accessToken: accessToken, generation: generation) }
        deviceRefreshTask = task
        let completed = await task.value
        if Self.refreshTaskIsCurrent(storedGeneration: deviceRefreshGeneration, taskGeneration: generation) {
            deviceRefreshTask = nil
        }
        return completed
    }

    /// Pure identity check, unit-tested directly: a refresh task may clear
    /// the stored handle only while it is still the current refresh. A
    /// cancelled or replaced predecessor must never erase the successor's
    /// handle, or teardown would lose the live task.
    static func refreshTaskIsCurrent(storedGeneration: Int, taskGeneration: Int) -> Bool {
        storedGeneration == taskGeneration
    }

    /// Applies the failure outcome of a re-check: records the issue and
    /// replaces any zero-selection status with neutral failure wording, so
    /// the UI never claims nothing is selected while the re-check itself
    /// failed.
    private func failDeviceRepositoryRefresh(with issue: String) {
        deviceRefreshIssue = issue
        if deviceAccount != nil {
            deviceStatus = Self.deviceRepositorySignedInLine(
                login: deviceAccount?.login ?? "",
                repositoryCount: deviceRepositoryCount,
                refreshIssue: issue
            )
        }
    }

    /// Whether this refresh invocation may still publish its result. The
    /// single-flight entry bumps the generation for every new invocation and
    /// teardown cancels the stored task, so a stale or cancelled predecessor
    /// must never overwrite a newer result (a stale zero could otherwise
    /// reopen the GitHub decision after a positive one already closed it).
    /// A cancelled invocation publishes nothing: the transport folds
    /// cancellation into `transportUnavailable`, so the silent-drop guard is
    /// what keeps cancellation from surfacing as a bogus failure.
    private func deviceRepositoryRefreshIsCurrent(generation: Int) -> Bool {
        !Task.isCancelled && Self.refreshTaskIsCurrent(
            storedGeneration: deviceRefreshGeneration,
            taskGeneration: generation
        )
    }

    /// Re-checks GitHub for repositories actually accessible to the App. An
    /// expired access token is rotated first through the shared refresher,
    /// the (possibly rotated) session is published to state before any
    /// fallible listing, and every failure surfaces as `deviceRefreshIssue`
    /// instead of collapsing into a misleading "no repositories selected"
    /// state.
    /// Re-checks GitHub for repositories actually accessible to the App. An
    /// expired access token is rotated first through the shared refresher,
    /// the (possibly rotated) session is published to state before any
    /// fallible listing, and every failure surfaces as `deviceRefreshIssue`
    /// instead of collapsing into a misleading "no repositories selected"
    /// state. Returns `true` only when a result was actually published
    /// (success or failure); `false` when the invocation was cancelled or
    /// superseded and published nothing.
    private func performDeviceRepositoryRefresh(accessToken: String, generation: Int) async -> Bool {
        guard let deviceFlow else { return false }
        let outcome: GitHubDeviceSessionRefreshOutcome
        do {
            outcome = try await deviceSessionRefresher.revalidatedSession(using: deviceFlow)
        } catch is CancellationError {
            return false
        } catch let refreshError as GitHubDeviceSessionRefreshError {
            return await MainActor.run { () -> Bool in
                guard deviceRepositoryRefreshIsCurrent(generation: generation) else { return false }
                // Quarantine: the consumed generation could not be poisoned.
                // Reauthorization-ONLY — no session, no Check again, no
                // polling.
                deviceReauthorizationRequired = true
                deviceSession = nil
                failDeviceRepositoryRefresh(with: Self.deviceRefreshIssueMessage(for: refreshError, action: "refreshing your GitHub session"))
                return true
            }
        } catch {
            return await MainActor.run { () -> Bool in
                guard deviceRepositoryRefreshIsCurrent(generation: generation) else { return false }
                failDeviceRepositoryRefresh(with: Self.deviceRefreshIssueMessage(for: error, action: "refreshing your GitHub session"))
                return true
            }
        }
        guard case .current(let session, _) = outcome else {
            if case .superseded = outcome {
                // A concurrent replacement won the epoch; publish nothing.
                return false
            }
            // Quarantine: the consumed generation could not be poisoned.
            // Reauthorization-ONLY — no session, no Check again, no polling.
            return await MainActor.run { () -> Bool in
                guard deviceRepositoryRefreshIsCurrent(generation: generation) else { return false }
                deviceReauthorizationRequired = true
                deviceSession = nil
                failDeviceRepositoryRefresh(with: Self.deviceRefreshIssueMessage(for: GitHubDeviceSessionRefreshError.keychainSaveFailed, action: "refreshing your GitHub session"))
                return true
            }
        }
        if let session, session.isAccessExpired {
            return await MainActor.run { () -> Bool in
                guard deviceRepositoryRefreshIsCurrent(generation: generation) else { return false }
                // Expired and unrefreshable (or a poisoned consumed
                // generation): reauthorization-ONLY — no session, no Check
                // again, no polling.
                deviceReauthorizationRequired = true
                deviceSession = nil
                failDeviceRepositoryRefresh(with: "Your GitHub session has expired and cannot be refreshed. Reconnect to GitHub, then check again.")
                return true
            }
        }
        if let session {
            // Publish the persisted (possibly rotated) session before the
            // fallible listing: a failed listing must never leave memory
            // holding a consumed pair while the Keychain holds the fresh one.
            let sessionPublished = await MainActor.run { () -> Bool in
                guard deviceRepositoryRefreshIsCurrent(generation: generation) else { return false }
                deviceSession = session
                return true
            }
            if !sessionPublished { return false }
        }

        let token = session?.accessToken ?? accessToken
        let installations: [GitHubInstallation]
        do {
            installations = try await deviceFlow.installations(accessToken: token)
        } catch is CancellationError {
            return false
        } catch {
            return await MainActor.run { () -> Bool in
                guard deviceRepositoryRefreshIsCurrent(generation: generation) else { return false }
                failDeviceRepositoryRefresh(with: Self.deviceRefreshIssueMessage(for: error, action: "listing installations"))
                return true
            }
        }
        var accessibleRepositories: [GitHubRepository] = []
        for installation in installations {
            do {
                let repositories = try await deviceFlow.repositories(
                    accessToken: token,
                    installationID: installation.id
                )
                accessibleRepositories.append(contentsOf: repositories)
            } catch is CancellationError {
                return false
            } catch {
                return await MainActor.run { () -> Bool in
                    guard deviceRepositoryRefreshIsCurrent(generation: generation) else { return false }
                    failDeviceRepositoryRefresh(with: Self.deviceRefreshIssueMessage(
                        for: error,
                        action: "listing repositories for installation \(installation.id)"
                    ))
                    return true
                }
            }
        }
        return await MainActor.run { () -> Bool in
            guard deviceRepositoryRefreshIsCurrent(generation: generation) else { return false }
            deviceRepositoryCount = accessibleRepositories.count
            deviceAccessibleRepositories = accessibleRepositories
            deviceRefreshIssue = nil
            deviceReauthorizationRequired = false
            loadWorkspaceAllowlists(accessibleRepositories: accessibleRepositories)
            if deviceAccount != nil {
                deviceStatus = Self.deviceRepositorySignedInLine(
                    login: deviceAccount?.login ?? "",
                    repositoryCount: accessibleRepositories.count,
                    refreshIssue: nil
                )
            }
            return true
        }
    }

    /// Automatic re-check polling while the GitHub decision is still
    /// undecided: after the device-flow sign-in, repository selection happens
    /// on GitHub's App installation page, so the app re-checks every few
    /// seconds instead of waiting for a manual "Check again" press.
    private static let deviceRepositoryPollInterval: TimeInterval = 8

    /// Minimum gap between focus-triggered re-checks; the automatic interval
    /// never goes below this.
    private static let deviceRepositoryMinRecheckInterval: TimeInterval = 5

    /// Pure decision, unit-tested directly: automatic re-check polling runs
    /// only while the full GitHub decision gate is still undecided — the
    /// device-flow sign-in exists, zero accessible repositories, existing
    /// grant metadata and retained verification results are both empty, the
    /// GitHub step is the active step, and GitHub has not been skipped.
    static func deviceRepositoryPollingActive(
        signedIn: Bool,
        repositoryCount: Int,
        stepActive: Bool,
        skipped: Bool,
        alreadyDecided: Bool
    ) -> Bool {
        signedIn && repositoryCount == 0 && stepActive && !skipped && !alreadyDecided
    }

    /// Pure identity check, unit-tested directly: a poll task may clear the
    /// stored handle only while it is still the current poller. A cancelled
    /// predecessor must never erase the successor that replaced it, or
    /// teardown would lose the live task's handle (leaking the poll and its
    /// waiting UI).
    static func pollingTaskIsCurrent(storedGeneration: Int, taskGeneration: Int) -> Bool {
        storedGeneration == taskGeneration
    }

    /// Pure decision, unit-tested directly: a focus-regain may trigger an
    /// immediate re-check only when the last check is older than the minimum
    /// interval, so rapid focus churn cannot hammer the API.
    static func shouldRecheckNow(lastCheckAt: Date?, now: Date, minimumInterval: TimeInterval) -> Bool {
        guard let lastCheckAt else { return true }
        return now.timeIntervalSince(lastCheckAt) >= minimumInterval
    }

    /// Pure derivation, unit-tested directly: when the poller may next run a
    /// re-check. The deadline is measured from the last COMPLETED re-check of
    /// any source (manual button included), so a check that finishes during
    /// the poller's wait satisfies it and the next check follows a full
    /// interval later instead of firing immediately. The deadline is capped
    /// at `now + interval`: a stamp in the future (corrupted clock) yields
    /// the normal cadence from now instead of an unbounded wait.
    static func nextRepositoryCheckDate(lastCheckAt: Date?, now: Date, interval: TimeInterval) -> Date {
        guard let lastCheckAt else { return .distantPast }
        return min(lastCheckAt.addingTimeInterval(interval), now.addingTimeInterval(interval))
    }

    /// Pure decision, unit-tested directly: whether a re-check is due at
    /// `now`, given the last completed re-check of any source. The poller
    /// re-evaluates this after every wake, so a check that completed during
    /// the wait (manual button or startup restore) extends the wait instead
    /// of the poller refreshing early. A clock rollback — `now` regressed
    /// below the stamp — is treated as due so the poller re-checks and
    /// re-stamps instead of parking indefinitely.
    static func repositoryCheckIsDue(lastCheckAt: Date?, now: Date, interval: TimeInterval) -> Bool {
        guard let lastCheckAt else { return true }
        if now < lastCheckAt { return true }
        return now >= nextRepositoryCheckDate(lastCheckAt: lastCheckAt, now: now, interval: interval)
    }

    /// Pure decision, unit-tested directly: a `false` re-check outcome
    /// (cancelled, superseded, no completed publication) is a terminal no-op
    /// for the surrounding flow — teardown owns the state and must not be
    /// revived by a status publication or a polling restart. `true` allows
    /// the flow to stamp the schedule and continue.
    static func shouldContinueSetupAfterRecheck(completed: Bool) -> Bool {
        completed
    }

    /// Terminal decision for one poller cycle, shared with the ordering test:
    /// a `false` re-check outcome — `.superseded`, a transport-reported
    /// CancellationError that never set the poll task's cancel bit, or a
    /// teardown — ends THIS poller with no schedule stamp and no retry on the
    /// next wake. `true` stamps the schedule and lets the loop re-evaluate
    /// its other exit gates. Returns whether the poller may continue.
    @discardableResult
    func continueDeviceRepositoryPolling(completed: Bool) -> Bool {
        guard Self.shouldContinueSetupAfterRecheck(completed: completed) else { return false }
        lastDeviceRepositoryCheckAt = Date()
        return true
    }

    /// Whether the GitHub step is already decided by state outside the
    /// device-flow sign-in itself (existing grant metadata or retained
    /// verification results). Those disjuncts of `githubDecisionMade` do not
    /// come from re-checks, so polling must not start or continue under them.
    private var deviceRepositoryDecisionAlreadyMade: Bool {
        !existingMetadata.isEmpty || !verificationResults.isEmpty
    }

    /// Starts the automatic re-check poll, cancelling any previous task so
    /// there is exactly one at a time: an immediate re-check, then one every
    /// 8 seconds while the GitHub decision is still undecided. The loop stops
    /// itself as soon as the decision gate closes (repositories detected,
    /// GitHub skipped, existing access present, step left, or the device
    /// session is gone). When `checkImmediately` is set (focus regain), the
    /// first re-check bypasses the poller's due gate — the focus handler has
    /// already applied the 5 s throttle, so a coherent policy is one check
    /// now, then the normal cadence.
    private func startDeviceRepositoryPollingIfNeeded(checkImmediately: Bool = false) {
        guard Self.deviceRepositoryPollingActive(
            signedIn: deviceAccount != nil,
            repositoryCount: deviceRepositoryCount,
            stepActive: activeStep == .github,
            skipped: githubSkipped,
            alreadyDecided: deviceRepositoryDecisionAlreadyMade
        ), deviceSession != nil else {
            return
        }
        deviceRepositoryPollGeneration &+= 1
        let generation = deviceRepositoryPollGeneration
        deviceRepositoryPollTask?.cancel()
        deviceRepositoryPollTask = Task {
            defer {
                // Only the task that is still the stored poller clears the
                // handle; a cancelled predecessor must never erase a
                // successor that replaced it, or teardown would lose the
                // live task (identity guard, unit-tested).
                if Self.pollingTaskIsCurrent(
                    storedGeneration: deviceRepositoryPollGeneration,
                    taskGeneration: generation
                ) {
                    deviceRepositoryPollTask = nil
                }
            }
            var skipFirstWait = checkImmediately
            while !Task.isCancelled {
                if skipFirstWait {
                    // Focus-triggered restart: re-check right away (the
                    // focus handler already satisfied the 5 s throttle).
                    skipFirstWait = false
                } else {
                    // The poll interval is measured from the last COMPLETED
                    // re-check of any source (this poller, the manual button,
                    // or the startup restore). The deadline is RE-EVALUATED
                    // after every wake — capped at now + interval, with a
                    // clock rollback treated as due — so a check that
                    // completes during the sleep moves the deadline and the
                    // poller keeps waiting instead of refreshing early.
                    while !Task.isCancelled, !Self.repositoryCheckIsDue(
                        lastCheckAt: lastDeviceRepositoryCheckAt,
                        now: Date(),
                        interval: Self.deviceRepositoryPollInterval
                    ) {
                        // Sleep only the remaining wait, capped at 2 s slices,
                        // so the deadline is re-evaluated promptly and hit
                        // exactly (never a full 2 s past it).
                        let remaining = Self.nextRepositoryCheckDate(
                            lastCheckAt: lastDeviceRepositoryCheckAt,
                            now: Date(),
                            interval: Self.deviceRepositoryPollInterval
                        ).timeIntervalSince(Date())
                        try? await Task.sleep(for: .seconds(min(max(remaining, 0), 2)))
                    }
                }
                guard !Task.isCancelled else { return }
                guard Self.deviceRepositoryPollingActive(
                    signedIn: deviceAccount != nil,
                    repositoryCount: deviceRepositoryCount,
                    stepActive: activeStep == .github,
                    skipped: githubSkipped,
                    alreadyDecided: deviceRepositoryDecisionAlreadyMade
                ), let accessToken = deviceSession?.accessToken else {
                    return
                }
                // Poller-level in-flight arbiter: never start a re-check
                // while one is still running (a focus-triggered restart's
                // predecessor may still be unwinding; the guarded refresh
                // entry also coalesces with the manual button).
                if deviceRepositoryCheckInFlight {
                    try? await Task.sleep(for: .seconds(2))
                    continue
                }
                // The token is re-read from the live session on every pass so
                // a rotation performed by refreshDeviceRepositoryCount is
                // picked up. The timestamp advances only when the re-check
                // completed and published (a cancelled attempt must not
                // throttle later real checks).
                deviceRepositoryCheckInFlight = true
                let completed = await refreshDeviceRepositoryCount(accessToken: accessToken)
                deviceRepositoryCheckInFlight = false
                // A false outcome is terminal for THIS poller: the re-check
                // was cancelled or superseded (a `.superseded` epoch, a
                // transport-reported CancellationError that never set the
                // task-cancel bit, or a teardown) with the poll task itself
                // still live. Continuing the loop would re-check on the next
                // due wake and restart the very refresh cadence the terminal
                // outcome was meant to end — no stamp, no retry. The manual
                // and restore flows keep their own terminal handling.
                guard continueDeviceRepositoryPolling(completed: completed) else { return }
                guard !Task.isCancelled else { return }
                if githubDecisionMade { return }
            }
        }
    }

    private func stopDeviceRepositoryPolling() {
        deviceRepositoryPollTask?.cancel()
        deviceRepositoryPollTask = nil
    }

    /// The common case for a focus regain is the user returning from the
    /// browser after choosing repositories on GitHub: re-check immediately,
    /// subject to a 5 second minimum gap so rapid focus churn cannot hammer
    /// the API. The focus throttle is the one coherent gate: once it passes,
    /// the restarted poller's first re-check bypasses its separate 8 s due
    /// gate (`checkImmediately`), so the documented immediate re-check
    /// actually happens. Restarting cancels the previous task, keeping
    /// exactly one polling task alive.
    private func handleDeviceWindowBecameKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window.identifier == NSUserInterfaceItemIdentifier("setup.window") else {
            return
        }
        guard Self.deviceRepositoryPollingActive(
            signedIn: deviceAccount != nil,
            repositoryCount: deviceRepositoryCount,
            stepActive: activeStep == .github,
            skipped: githubSkipped,
            alreadyDecided: deviceRepositoryDecisionAlreadyMade
        ), Self.shouldRecheckNow(
            lastCheckAt: lastDeviceRepositoryCheckAt,
            now: Date(),
            minimumInterval: Self.deviceRepositoryMinRecheckInterval
        ) else {
            return
        }
        startDeviceRepositoryPollingIfNeeded(checkImmediately: true)
    }

    /// Ends the polling scope when the setup window closes (the view may not
    /// disappear when the window is merely hidden). The skip task is cancelled
    /// here as well so a grant-disable that is still awaiting the network is
    /// not left running past the window's lifetime; the disable itself runs on
    /// the coordinator actor and completes (revocation is idempotent), while
    /// any post-await navigation is discarded with the window. The lifecycle
    /// bump is the authoritative barrier: a restore/verification continuation
    /// that captured the generation before its first await can no longer
    /// create a refresh, publish, stamp, or restart polling — even when its
    /// child task is not (or no longer) cancellable. The device-code poll and
    /// verification tasks are cancelled so a late token or verification stops
    /// immediately.
    private func handleDeviceWindowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window.identifier == NSUserInterfaceItemIdentifier("setup.window") else {
            return
        }
        setupLifecycle.invalidate()
        stopDeviceRepositoryPolling()
        deviceRefreshTask?.cancel()
        deviceRefreshTask = nil
        devicePollTask?.cancel()
        devicePollTask = nil
        deviceVerificationTask?.cancel()
        deviceVerificationTask = nil
        githubSkipTask?.cancel()
    }

    /// Loads the persisted per-workspace allowlist and prunes repositories
    /// that are no longer accessible to the App installation.
    private func loadWorkspaceAllowlists(accessibleRepositories: [GitHubRepository]) {
        let accessibleNames = Set(accessibleRepositories.map(\.fullName))
        let store = WorkspaceGitHubAccessStore()
        guard let stored = store.load() else {
            workspaceAllowlists = [:]
            return
        }
        let pruned = stored.pruned(toAccessibleNames: accessibleNames)
        if pruned.repositoriesByWorkspace != stored.repositoriesByWorkspace {
            try? store.save(pruned)
        }
        workspaceAllowlists = pruned.repositoriesByWorkspace.mapValues(Set.init)
    }

    /// Updates one workspace's allowlist and persists it.
    private func setWorkspaceAllowlist(workspace: String, repository: String, allowed: Bool) {
        var current = workspaceAllowlists[workspace] ?? []
        if allowed {
            current.insert(repository)
        } else {
            current.remove(repository)
        }
        workspaceAllowlists[workspace] = current
        let access = WorkspaceGitHubAccess(
            repositoriesByWorkspace: workspaceAllowlists.mapValues { Array($0).sorted() }
        )
        try? WorkspaceGitHubAccessStore().save(access)
    }

    private func cancelDeviceFlow() {
        devicePollTask?.cancel()
        devicePollTask = nil
        deviceRefreshTask?.cancel()
        deviceRefreshTask = nil
        deviceVerificationTask?.cancel()
        deviceVerificationTask = nil
        // Invalidate any in-flight verification so its completion blocks
        // publish nothing (they check the generation identity guard).
        deviceVerificationGeneration &+= 1
        // Explicit device-flow cancellation/reset also bumps the authoritative
        // setup lifecycle: a restore/verification continuation that captured
        // it before its first await can no longer create a refresh, publish
        // state, stamp the schedule, or restart polling. The generation is the
        // barrier, not merely cancelling the existing child tasks.
        setupLifecycle.invalidate()
        stopDeviceRepositoryPolling()
        isConnectingDevice = false
        deviceAuthorization = nil
        deviceStatus = ""
        deviceIssue = "GitHub connection was cancelled. Nothing was stored."
    }

    private func openDeviceInstallation() {
        guard let url = Self.validatedInstallationURL(deviceInstallationURL) else { return }
        _ = NSWorkspace.shared.open(url)
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
        if githubSkipped { return "Not connected — you can connect later in Settings." }
        if let deviceAccount { return "Connected as @\(deviceAccount.login). Repositories are chosen on GitHub." }
        if !verificationResults.isEmpty {
            return verificationResults.map {
                "\($0.workspace): \($0.verified && $0.lifecycleRestored ? "verified" : "needs attention") for \($0.verificationRepository)"
            }.joined(separator: "; ")
        }
        if !existingMetadata.isEmpty {
            return groupedExistingMetadata.map {
                $0.needsAttention
                    ? "\($0.workspace): needs attention"
                    : "\($0.workspace): \($0.repositoryNames.joined(separator: ", "))"
            }.joined(separator: "; ")
        }
        return "Not connected yet."
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
        if let connectError = error as? MSWConnectError {
            switch connectError {
            case .cancelled:
                return AuthorizationIssue(kind: .cancelled, message: connectError.localizedDescription)
            case .sessionExpired, .callbackExpired:
                return AuthorizationIssue(kind: .expired, message: connectError.localizedDescription)
            case .authorizationDenied:
                return AuthorizationIssue(kind: .denied, message: connectError.localizedDescription)
            case .installationUnavailable, .installationRemoved,
                 .transportUnavailable, .httpStatus, .rateLimited:
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

    private var githubAffectedScope: String {
        let workspaces = validDrafts.map { $0.workspace.rawValue }
        return workspaces.isEmpty ? "GitHub setup for all workspaces" : workspaces.joined(separator: ", ")
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

    private func persistResumeState() {
        let resume = SetupResumeState(
            drafts: drafts,
            githubSkipped: githubSkipped,
            identityName: identityName,
            identityEmail: identityEmail,
            identityTarget: identityTarget,
            identityConfiguredWorkspaces: identityConfiguredWorkspaces,
            identitySkipped: identitySkipped,
            verificationResults: verificationResults,
            verifiedIdentityByWorkspace: verifiedIdentityByWorkspace
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
        verifiedIdentityByWorkspace = resume.verifiedIdentityByWorkspace ?? [:]
        identitySkipped = resume.identitySkipped
        verificationResults = resume.verificationResults
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


/// Shared per-workspace repository allowlist editor, used by first-run setup
/// and by Settings → GitHub after onboarding. Backed by the persisted
/// `WorkspaceGitHubAccessStore`; enforcement lives in the host-mediated
/// workspace operations.
struct WorkspaceGitHubAccessEditor: View {
    let repositories: [GitHubRepository]
    let allowlists: [String: Set<String>]
    let onToggle: (String, String, Bool) -> Void
    @State private var expanded = Set(Workspace.ID.allCases.map(\.rawValue))

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Workspace access").font(.headline)
            Text("Choose which of the selected repositories each workspace may use. This list is saved now; enforcement starts when workspace GitHub operations are connected. Adding or removing repositories happens on GitHub.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(Workspace.ID.allCases, id: \.rawValue) { workspace in
                DisclosureGroup(isExpanded: Binding(
                    get: { expanded.contains(workspace.rawValue) },
                    set: { isExpanded in
                        if isExpanded {
                            expanded.insert(workspace.rawValue)
                        } else {
                            expanded.remove(workspace.rawValue)
                        }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 4) {
                        let allowed = allowlists[workspace.rawValue] ?? []
                        ForEach(repositories, id: \.id) { repository in
                            Toggle(
                                repository.fullName,
                                isOn: Binding(
                                    get: { allowed.contains(repository.fullName) },
                                    set: { selected in
                                        onToggle(workspace.rawValue, repository.fullName, selected)
                                    }
                                )
                            )
                            .toggleStyle(.checkbox)
                            .accessibilityIdentifier("github.workspace.\(workspace.rawValue).repository.\(repository.id)")
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text(workspace.rawValue)
                        .font(.callout.weight(.medium))
                }
                .accessibilityIdentifier("github.workspace.\(workspace.rawValue).access")
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }
}
