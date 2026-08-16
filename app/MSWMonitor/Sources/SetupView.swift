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
    @State private var deviceRefreshTask: Task<Void, Never>?
    @State private var deviceRefreshGeneration = 0
    @State private var deviceReauthorizationRequired = false
    @State private var devicePollTask: Task<Void, Never>?
    @State private var deviceSession: GitHubDeviceSession?
    @State private var deviceRepositoryCount = 0
    @State private var deviceAccessibleRepositories: [GitHubRepository] = []
    @State private var workspaceAllowlists: [String: Set<String>] = [:]

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
                restoreResumeState()
                loadPreflight()
                await loadExistingMetadata()
                await restoreCachedAuthorization()
                await restoreDeviceSession()
                githubContextLoaded = true
            }
        }
        .onDisappear { pauseAuthorization() }
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
                        deviceRefreshTask?.cancel()
                        deviceRefreshGeneration &+= 1
                        let generation = deviceRefreshGeneration
                        deviceRefreshTask = Task {
                            await performDeviceRepositoryRefresh(accessToken: deviceSession.accessToken)
                            if Self.refreshTaskIsCurrent(storedGeneration: deviceRefreshGeneration, taskGeneration: generation) {
                                deviceRefreshTask = nil
                            }
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
                Button("Connect GitHub", action: startDeviceFlow)
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


    private func loadExistingMetadata() async {
        guard let authorizationCoordinator else { return }
        existingMetadata = await authorizationCoordinator.metadata()
    }

    private func restoreCachedAuthorization() async {
        guard let authorizationCoordinator else { return }
        // An unconfigured build cannot use or validate a stored session;
        // restoration is deferred to a configured build. Sessions are never
        // deleted by configuration mismatches.
        guard authorizationCoordinator.isConfigured else { return }
        do {
            guard let discovery = try await authorizationCoordinator.resumeAuthorization() else { return }
            account = discovery.account
            installations = discovery.installations
            let installURL = await authorizationCoordinator.installationURL()
            githubInstallationURL = Self.validatedInstallationURL(installURL)
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

    /// Restores the stored direct-GitHub session, rotating an expired access
    /// token with its refresh token when available.
    private func restoreDeviceSession() async {
        guard let deviceFlow else { return }
        do {
            let outcome = try await GitHubDeviceSessionRefresher.shared.revalidatedSession(using: deviceFlow)
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
            await refreshDeviceRepositoryCount(accessToken: session.accessToken)
            deviceStatus = Self.deviceRepositorySignedInLine(
                login: session.account.login,
                repositoryCount: deviceRepositoryCount,
                refreshIssue: deviceRefreshIssue
            )
        } catch is CancellationError {
            // Startup restore was cancelled; leave state untouched.
        } catch {
            // A genuinely retryable transport failure must not render as
            // "not connected": publish the stored session and keep Check
            // again available.
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

    private func startDeviceFlow() {
        guard let deviceFlow else { return }
        cancelDeviceFlow()
        isConnectingDevice = true
        deviceIssue = nil
        deviceRefreshIssue = nil
        deviceStatus = "Requesting a GitHub code…"
        devicePollTask = Task {
            do {
                let authorization = try await deviceFlow.requestDeviceCode()
                await MainActor.run {
                    deviceAuthorization = authorization
                    deviceStatus = "Enter the code on GitHub, then approve."
                    _ = NSWorkspace.shared.open(GitHubDeviceFlow.verificationURL(for: authorization))
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
                            finishDeviceFlow(token: token)
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
                    isConnectingDevice = false
                    deviceAuthorization = nil
                    deviceStatus = ""
                    deviceIssue = (error as? LocalizedError)?.errorDescription
                        ?? "GitHub connection failed. Try again."
                    devicePollTask = nil
                }
            }
        }
    }

    private func finishDeviceFlow(token: GitHubDeviceToken) {
        guard let deviceFlow else { return }
        Task {
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
                try await GitHubDeviceSessionRefresher.shared.replaceCurrentSession(with: session)
                await MainActor.run {
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

                await MainActor.run {
                    isConnectingDevice = false
                    deviceAuthorization = nil
                    devicePollTask = nil
                    deviceStatus = ""
                    deviceIssue = "GitHub approved the code, but the account could not be verified: \(error.localizedDescription)"
                }
            }
        }
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
    /// submitted twice. Keep this signature stable — Issue 1's poller calls it.
    func refreshDeviceRepositoryCount(accessToken: String) async {
        if let inFlight = deviceRefreshTask {
            await inFlight.value
            return
        }
        deviceRefreshGeneration &+= 1
        let generation = deviceRefreshGeneration
        let task = Task { await performDeviceRepositoryRefresh(accessToken: accessToken) }
        deviceRefreshTask = task
        await task.value
        if Self.refreshTaskIsCurrent(storedGeneration: deviceRefreshGeneration, taskGeneration: generation) {
            deviceRefreshTask = nil
        }
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
            outcome = try await GitHubDeviceSessionRefresher.shared.revalidatedSession(using: deviceFlow)
        } catch is CancellationError {
            return false
        } catch {
            await MainActor.run {
                failDeviceRepositoryRefresh(with: Self.deviceRefreshIssueMessage(for: error, action: "refreshing your GitHub session"))
            }
            return
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
            await MainActor.run {
                guard deviceRepositoryRefreshIsCurrent(generation: generation) else { return }
                // Expired and unrefreshable (or a poisoned consumed
                // generation): reauthorization-ONLY — no session, no Check
                // again, no polling.
                deviceReauthorizationRequired = true
                deviceSession = nil
                failDeviceRepositoryRefresh(with: "Your GitHub session has expired and cannot be refreshed. Reconnect to GitHub, then check again.")
            }
            return
        }
        if let session {
            // Publish the persisted (possibly rotated) session before the
            // fallible listing: a failed listing must never leave memory
            // holding a consumed pair while the Keychain holds the fresh one.
            await MainActor.run { deviceSession = session }
        }

        let token = session?.accessToken ?? accessToken
        let installations: [GitHubInstallation]
        do {
            installations = try await deviceFlow.installations(accessToken: token)
        } catch is CancellationError {
            return
        } catch {
            await MainActor.run {
                failDeviceRepositoryRefresh(with: Self.deviceRefreshIssueMessage(for: error, action: "listing installations"))
            }
            return
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
                return
            } catch {
                await MainActor.run {
                    failDeviceRepositoryRefresh(with: Self.deviceRefreshIssueMessage(
                        for: error,
                        action: "listing repositories for installation \(installation.id)"
                    ))
                }
                return
            }
        }
        await MainActor.run {
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
        }
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
