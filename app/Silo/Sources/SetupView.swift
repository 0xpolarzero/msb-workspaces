import AppKit
import Observation
import SwiftUI

@MainActor
final class SetupWindowController {
    private let window: NSWindow

    init(
        coordinator: (any SiloBootstrapCoordinating)?,
        provider: (any GitHubProviding)? = nil,
        githubState: GitHubSettingsState? = nil,
        commandRunner: SiloCommandRunner = SiloCommandRunner(),
        applicationPreferences: ApplicationPreferenceStore,
        openSettings: @escaping (AppTab) -> Void,
        closeSetup: @escaping ([SetupWorkspaceConfiguration]) -> Void = { _ in },
        uiTestMode: Bool = false,
        uiTestStartsInReview: Bool = false,
        uiTestGitHubScenario: String? = nil
    ) {
        let resolvedGitHubState = githubState ?? GitHubSettingsState(provider: provider)
        let hosting = NSHostingController(
            rootView: SetupView(
                coordinator: coordinator,
                provider: provider,
                githubState: resolvedGitHubState,
                commandRunner: commandRunner,
                applicationPreferences: applicationPreferences,
                openSettings: openSettings,
                closeSetup: closeSetup,
                uiTestMode: uiTestMode,
                uiTestStartsInReview: uiTestStartsInReview,
                uiTestGitHubScenario: uiTestGitHubScenario
            )
        )
        // The setup window owns its size. Dynamic SwiftUI content (notably
        // repository selections) must reflow or scroll instead of changing
        // the surrounding onboarding window.
        hosting.sizingOptions = []
        window = NSWindow(contentViewController: hosting)
        window.identifier = NSUserInterfaceItemIdentifier("setup.window")
        hosting.view.setAccessibilityIdentifier("setup.window")
        window.title = "Set up Silo"
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

extension SetupWorkspaceConfiguration {
    static func initialRepositoryDrafts(
        for configurations: [Self]
    ) -> [String: WorkspaceRepositoryDraft] {
        configurations.reduce(into: [:]) { result, configuration in
            let name = configuration.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, result[name] == nil else { return }
            result[name] = .initial(name)
        }
    }
}

struct WorkspaceRepositoryDraft: Codable, Equatable, Identifiable {
    let workspace: String
    var repositoryModes: [String: GitHubRepositoryAccessMode]

    var id: String { workspace }

    static func initial(_ workspace: String) -> Self {
        Self(
            workspace: workspace,
            repositoryModes: [:]
        )
    }
}

private struct SetupResumeState: Codable {
    var workspaceConfigurations: [SetupWorkspaceConfiguration]?
    var repositoryPolicy: [GitHubWorkspacePolicy]
    var repositoryPolicyApplied: Bool
    var githubSkipped: Bool
    var identityName: String
    var identityEmail: String
    var identityTarget: String
    var identityConfiguredWorkspaces: Set<String>
    var identitySkipped: Bool
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
    case dependencies
    case workspaces
    case github
    case identity
    case review

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dependencies: return "Dependencies"
        case .workspaces: return "Workspaces"
        case .github: return "GitHub"
        case .identity: return "Git"
        case .review: return "Review"
        }
    }

    var symbol: String {
        switch self {
        case .dependencies: return "checkmark.shield"
        case .workspaces: return "server.rack"
        case .github: return "person.crop.circle.badge.checkmark"
        case .identity: return "person.text.rectangle"
        case .review: return "checkmark.circle"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .dependencies: return "setup.step.dependencies"
        case .workspaces: return "setup.step.workspaces"
        case .github: return "setup.step.github"
        case .identity: return "setup.step.identity"
        case .review: return "setup.step.review"
        }
    }
}


enum SetupQueueItemID: String, CaseIterable, Identifiable, Sendable, Hashable {
    case workspaceRun
    case workspaceVerify
    case githubRun
    case githubVerify
    case identityRun
    case identityVerify
    case completion

    var id: String { rawValue }

    var label: String {
        switch self {
        case .workspaceRun: return "Create workspaces"
        case .workspaceVerify: return "Verify workspaces"
        case .githubRun: return "Save GitHub access"
        case .githubVerify: return "Verify GitHub access"
        case .identityRun: return "Save Git identity"
        case .identityVerify: return "Verify Git identity"
        case .completion: return "Finish setup"
        }
    }
}

enum SetupQueueItemStatus: String, Sendable, Equatable {
    case queued
    case running
    case succeeded
    case failed
}

struct SetupIdentityQueueInput: Equatable, Sendable {
    let name: String
    let email: String
    let target: String?
}

enum SetupQueueInput: Equatable, Sendable {
    case workspaces([SetupWorkspaceConfiguration])
    case github([GitHubWorkspacePolicy])
    case identity(SetupIdentityQueueInput)
    case skipped
    case completion
}

struct SetupQueueItem: Identifiable, Equatable, Sendable {
    let id: SetupQueueItemID
    let label: String
    var status: SetupQueueItemStatus
    var input: SetupQueueInput?
    var failure: String?
    var candidateRevision: Int?
}

enum SetupPlan {
    static let orderedIDs = SetupQueueItemID.allCases
    static let dependencies: [SetupQueueItemID: [SetupQueueItemID]] = [
        .workspaceRun: [],
        .workspaceVerify: [.workspaceRun],
        .githubRun: [.workspaceRun],
        .githubVerify: [.githubRun],
        .identityRun: [.githubVerify],
        .identityVerify: [.identityRun],
        .completion: [.workspaceVerify, .identityVerify]
    ]
}

/// The setup queue is the sole owner of operation ordering and presentation.
/// Views submit retained inputs and render this store; they never infer a
/// second progress label from task-local flags.
@MainActor
@Observable
final class SetupState {
    private(set) var items: [SetupQueueItem] = SetupPlan.orderedIDs.map {
        SetupQueueItem(id: $0, label: $0.label, status: .queued)
    }
    private(set) var revision = 0

    var runningItem: SetupQueueItem? { items.first { $0.status == .running } }
    var failedItem: SetupQueueItem? { items.first { $0.status == .failed } }
    var currentLabel: String? { runningItem?.label }
    var isDone: Bool { status(of: .completion) == .succeeded }

    func item(_ id: SetupQueueItemID) -> SetupQueueItem {
        items[SetupPlan.orderedIDs.firstIndex(of: id)!]
    }

    func status(of id: SetupQueueItemID) -> SetupQueueItemStatus {
        item(id).status
    }

    @discardableResult
    func submitWorkspaces(_ configurations: [SetupWorkspaceConfiguration]) -> Int {
        revision &+= 1
        for index in items.indices {
            items[index].status = .queued
            items[index].failure = nil
            items[index].candidateRevision = revision
        }
        setInput(.workspaces(configurations), for: [.workspaceRun, .workspaceVerify])
        return revision
    }

    func submitGitHub(_ input: SetupQueueInput) {
        if item(.githubRun).input != input || status(of: .githubRun) == .succeeded {
            reset(from: .githubRun)
        }
        setInput(input, for: [.githubRun, .githubVerify])
    }

    func submitIdentity(_ input: SetupIdentityQueueInput) {
        let retained = SetupQueueInput.identity(input)
        if item(.identityRun).input != retained || status(of: .identityRun) == .succeeded {
            reset(from: .identityRun)
        }
        setInput(retained, for: [.identityRun, .identityVerify])
    }

    func submitIdentitySkip() {
        if item(.identityRun).input != .skipped { reset(from: .identityRun) }
        setInput(.skipped, for: [.identityRun, .identityVerify])
        settleRetainedDecisions()
    }

    func submitGitHubSkip() {
        if item(.githubRun).input != .skipped { reset(from: .githubRun) }
        setInput(.skipped, for: [.githubRun, .githubVerify])
        settleRetainedDecisions()
    }

    @discardableResult
    func begin(_ id: SetupQueueItemID, revision candidateRevision: Int? = nil) -> Bool {
        guard runningItem == nil, failedItem == nil,
              let index = index(of: id), items[index].status == .queued,
              candidateRevision == nil || candidateRevision == revision,
              dependenciesSucceeded(for: id, revision: items[index].candidateRevision) else {
            return false
        }
        items[index].status = .running
        return true
    }

    func succeed(_ id: SetupQueueItemID, revision candidateRevision: Int? = nil) {
        guard let index = index(of: id),
              candidateRevision == nil || candidateRevision == revision,
              items[index].status == .running || items[index].status == .queued,
              dependenciesSucceeded(for: id, revision: items[index].candidateRevision) else { return }
        items[index].status = .succeeded
        items[index].failure = nil
        settleRetainedDecisions()
    }

    func fail(_ id: SetupQueueItemID, message: String, revision candidateRevision: Int? = nil) {
        guard let index = index(of: id),
              candidateRevision == nil || candidateRevision == revision else { return }
        if let running = runningItem, running.id != id { return }
        items[index].status = .failed
        items[index].failure = message
    }

    func deferItem(_ id: SetupQueueItemID, revision candidateRevision: Int) {
        guard candidateRevision == revision, let index = index(of: id),
              items[index].status == .running else { return }
        items[index].status = .queued
    }

    @discardableResult
    func retryFailedItem() -> SetupQueueItemID? {
        guard let failed = failedItem, let index = index(of: failed.id) else { return nil }
        items[index].status = .queued
        items[index].failure = nil
        return failed.id
    }

    func deriveCompletion(requirementsSatisfied: Bool) {
        guard let index = index(of: .completion) else { return }
        items[index].input = .completion
        if requirementsSatisfied,
           dependenciesSucceeded(for: .completion, revision: items[index].candidateRevision),
           failedItem == nil,
           runningItem == nil {
            items[index].status = .succeeded
            items[index].failure = nil
        } else if items[index].status == .succeeded {
            items[index].status = .queued
        }
    }

    func consume(_ event: SiloProgressEvent, candidateRevision: Int? = nil) {
        guard candidateRevision == nil || candidateRevision == revision else { return }
        let normalized = (event.step ?? event.phase).lowercased()
        let id: SetupQueueItemID = normalized.contains("verif")
            ? .workspaceVerify
            : .workspaceRun
        if id == .workspaceVerify, status(of: .workspaceRun) == .running {
            succeed(.workspaceRun, revision: candidateRevision)
        }
        if status(of: id) == .queued {
            _ = begin(id, revision: candidateRevision)
        }
    }

    func settleRetainedDecisions() {
        for pair in [
            (SetupQueueItemID.githubRun, SetupQueueItemID.githubVerify),
            (.identityRun, .identityVerify)
        ] {
            guard item(pair.0).input == .skipped else { continue }
            if status(of: pair.0) == .queued,
               dependenciesSucceeded(for: pair.0, revision: item(pair.0).candidateRevision) {
                items[index(of: pair.0)!].status = .succeeded
            }
            if status(of: pair.1) == .queued,
               dependenciesSucceeded(for: pair.1, revision: item(pair.1).candidateRevision) {
                items[index(of: pair.1)!].status = .succeeded
            }
        }
    }

    private func setInput(_ input: SetupQueueInput, for ids: [SetupQueueItemID]) {
        for id in ids where index(of: id) != nil {
            let index = index(of: id)!
            items[index].input = input
            items[index].candidateRevision = revision
        }
    }

    private func reset(from id: SetupQueueItemID) {
        guard let first = SetupPlan.orderedIDs.firstIndex(of: id) else { return }
        for candidate in SetupPlan.orderedIDs[first...] {
            guard let index = index(of: candidate) else { continue }
            items[index].status = .queued
            items[index].failure = nil
            items[index].candidateRevision = revision
        }
    }

    private func dependenciesSucceeded(
        for id: SetupQueueItemID,
        revision candidateRevision: Int?
    ) -> Bool {
        (SetupPlan.dependencies[id] ?? []).allSatisfy { dependency in
            let item = item(dependency)
            return item.status == .succeeded && item.candidateRevision == candidateRevision
        }
    }

    private func index(of id: SetupQueueItemID) -> Int? {
        items.firstIndex { $0.id == id }
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
    let coordinator: (any SiloBootstrapCoordinating)?
    let provider: (any GitHubProviding)?
    @Bindable var githubState: GitHubSettingsState
    let commandRunner: SiloCommandRunner
    @Bindable var applicationPreferences: ApplicationPreferenceStore
    let openSettings: (AppTab) -> Void
    let closeSetup: ([SetupWorkspaceConfiguration]) -> Void
    let uiTestMode: Bool
    let uiTestStartsInReview: Bool
    let uiTestGitHubScenario: String?
    let setupLifecycle: SetupLifecycleGate
    @State private var setupQueue = SetupState()
    @State private var checks: [SiloPreflightCheck] = []
    @State private var state = SiloBootstrapState.initial
    @State private var registrationTask: Task<Void, Never>?
    @State private var isChecking = true
    @State private var runtimeSetupPhase = SiloRuntimeSetupPhase.installingRuntime
    @State private var runtimeSetupError: String?
    @State private var workspaceNamesNeedApproval = false
    @State private var lastPreflightAt: Date?
    @State private var passedChecksExpanded = false
    @State private var advisoriesExpanded = false
    @State private var error: String?
    @State private var notice: String?

    @State private var account: GitHubAccount?
    @State private var owners: [GitHubOwner] = []
    @State private var repositoriesByOwner: [Int: [GitHubRepository]] = [:]
    @State private var workspaceConfigurations = SetupWorkspaceConfiguration.defaults
    @State private var drafts = SetupWorkspaceConfiguration.initialRepositoryDrafts(
        for: SetupWorkspaceConfiguration.defaults
    )
    @State private var savedGitHubDrafts = SetupWorkspaceConfiguration.initialRepositoryDrafts(
        for: SetupWorkspaceConfiguration.defaults
    )
    @State private var editedGitHubWorkspaces: Set<String> = []
    @State private var repositoryPolicyApplied = false
    @State private var retainedRepositoryPolicy: [GitHubWorkspacePolicy] = []
    @State private var githubStatus = ""
    @State private var isConnectingGitHub = false
    @State private var githubConnectionTask: Task<Void, Never>?
    @State private var githubConnectionGeneration = 0
    @State private var isRefreshingGitHub = false
    @State private var githubRefreshTask: Task<Void, Never>?
    @State private var githubRefreshGeneration = 0
    @State private var queuedLocalCatalogRefresh = false
    @State private var isResettingGitHub = false
    @State private var githubResetTask: Task<Void, Never>?
    @State private var githubResetAction: GitHubDestructiveAction?
    @State private var isApplyingGitHub = false
    @State private var githubApplyTask: Task<Void, Never>?
    @State private var githubProgressTask: Task<Void, Never>?
    @State private var githubApplyGeneration = 0
    @State private var githubApplyProgress: GitHubApplyProgress?
    @State private var githubSkipped = false
    @State private var isSkippingGitHub = false
    @State private var githubSkipTask: Task<Void, Never>?
    @State private var githubSkipGeneration = 0
    @State private var githubSkipIssue: String?
    @State private var identityName = ""
    @State private var identityEmail = ""
    @State private var identityNameWasEdited = false
    @State private var identityEmailWasEdited = false
    @State private var identityTarget = "all"
    @State private var identityConfiguredWorkspaces: Set<String> = []
    @State private var verifiedIdentityByWorkspace: [String: SetupVerifiedIdentity] = [:]

    @State private var identitySkipped = false
    @State private var isSavingIdentity = false
    @State private var identitySaveTask: Task<Void, Never>?
    @State private var identityStatus = ""
    @State private var activeStep: SetupStep = .dependencies
    @State private var workspaceConfigurationAccepted = false
    @State private var githubContextLoaded = false
    @State private var githubContextTask: Task<Void, Never>?
    @State private var githubContextGeneration = 0
    /// Set once the setup context (resumed configuration, fixture state, or
    /// freshly streamed preflight) is loaded. Only actions that run real
    /// bootstrap work wait for it; pure navigation never does.
    @State private var bootstrapInputReady = false
    @State private var didLoadStartupState = false
    @State private var localCatalogAttempted = false
    @State private var githubHostCredentialPresent = false
    @State private var githubAttentionWorkspace: String?
    @State private var localCatalogIssue: LocalCatalogIssue?
    @State private var deviceFlowSession: GitHubDeviceFlowSession?
    @State private var deviceFlowShown = false

    /// Explicit initializer keeps the setup dependencies visible at call sites.
    init(
        coordinator: (any SiloBootstrapCoordinating)?,
        provider: (any GitHubProviding)?,
        githubState: GitHubSettingsState? = nil,
        commandRunner: SiloCommandRunner = SiloCommandRunner(),
        applicationPreferences: ApplicationPreferenceStore,
        openSettings: @escaping (AppTab) -> Void,
        closeSetup: @escaping ([SetupWorkspaceConfiguration]) -> Void,
        uiTestMode: Bool,
        uiTestStartsInReview: Bool,
        uiTestGitHubScenario: String?,
        setupLifecycle: SetupLifecycleGate = SetupLifecycleGate()
    ) {
        self.coordinator = coordinator
        self.provider = provider
        self.githubState = githubState ?? GitHubSettingsState(provider: provider)
        self.commandRunner = commandRunner
        self.applicationPreferences = applicationPreferences
        self.openSettings = openSettings
        self.closeSetup = closeSetup
        self.uiTestMode = uiTestMode
        self.uiTestStartsInReview = uiTestStartsInReview
        self.uiTestGitHubScenario = uiTestGitHubScenario
        self.setupLifecycle = setupLifecycle
    }

    private static let resumeStateKey = "setup.repository-policy.v4"

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Set up Silo")
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
            guard !didLoadStartupState else { return }
            didLoadStartupState = true
            if uiTestMode && !uiTestInstallsDependencies {
                loadUITestState()
            } else {
                if uiTestMode {
                    loadUITestState()
                    runtimeSetupPhase = .installingRuntime
                    runtimeSetupError = nil
                    checks = []
                    lastPreflightAt = nil
                    isChecking = true
                    bootstrapInputReady = false
                }
                if await prepareDependencies() {
                    await loadSetupStartupState()
                }
                await refreshLocalApplyProgress()
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
        .onChange(of: workspaceConfigurations) { _, _ in
            if !uiTestMode {
                persistResumeState()
                refreshWorkspaceNameApprovalHint()
            }
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
        .onChange(of: verifiedIdentityByWorkspace) { _, _ in
            if !uiTestMode { persistResumeState() }
        }
        .onChange(of: activeStep) { _, step in
            if step == .workspaces { refreshWorkspaceNameApprovalHint() }
        }
        .onChange(of: reviewRequirementsSatisfied, initial: true) { _, satisfied in
            setupQueue.deriveCompletion(requirementsSatisfied: satisfied)
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
                                id: GitHubProvider.stableID(login),
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
        .sheet(item: $githubResetAction) { action in
            GitHubImpactConfirmation(action: action) {
                githubResetAction = nil
            } onConfirm: {
                githubResetAction = nil
                resetGitHubAccess()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup.root")
    }

    private func invalidateSetupLifecycle() {
        setupLifecycle.invalidate()
        cancelGitHubContextLoad()
        githubConnectionGeneration &+= 1
        githubConnectionTask?.cancel()
        githubConnectionTask = nil
        githubRefreshGeneration &+= 1
        githubRefreshTask?.cancel()
        githubRefreshTask = nil
        githubResetTask?.cancel()
        githubResetTask = nil
        githubApplyGeneration &+= 1
        githubApplyTask?.cancel()
        githubApplyTask = nil
        githubProgressTask?.cancel()
        githubProgressTask = nil
        identitySaveTask?.cancel()
        identitySaveTask = nil
        githubSkipTask?.cancel()
        // Saved GitHub intent belongs to the app, not this window. Closing
        // Setup must not cancel durable reconciliation.
    }

    private func handleSetupWindowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window.identifier == NSUserInterfaceItemIdentifier("setup.window") else {
            return
        }
        invalidateSetupLifecycle()
    }

    private var blockingChecks: [SiloPreflightCheck] {
        checks.filter { $0.status != .pass && $0.id != "memory" }
    }

    private var warningChecks: [SiloPreflightCheck] {
        checks.filter { $0.status == .needsAction && $0.id == "memory" }
    }
    private var passedChecks: [SiloPreflightCheck] {
        checks.filter { $0.status == .pass }
    }
    private var canConnectGitHub: Bool {
        if uiTestGitHubScenario == "unavailable" {
            return false
        }
        return provider != nil
    }

    private var registrationOutstanding: Bool {
        [SetupQueueItemID.workspaceRun, .workspaceVerify].contains {
            let status = setupQueue.status(of: $0)
            return status == .queued || status == .running
        } && setupQueue.item(.workspaceRun).input != nil
    }

    private var registrationFailure: String? {
        for id in [SetupQueueItemID.workspaceRun, .workspaceVerify] {
            if let failure = setupQueue.item(id).failure { return failure }
        }
        return nil
    }

    private var systemReady: Bool {
        runtimeSetupPhase == .ready &&
            runtimeSetupError == nil &&
            !isChecking &&
            !checks.isEmpty &&
            blockingChecks.isEmpty
    }

    private var uiTestInstallsDependencies: Bool {
        uiTestMode && ProcessInfo.processInfo.arguments.contains("--ui-test-setup-installing")
    }

    private var canFinishWithoutGitHub: Bool {
        systemReady && state.phase == .complete && workspaceConfigurationIsApplied
    }

    private var workspaceConfigurationIsApplied: Bool {
        Self.workspaceConfigurationIsApplied(
            workspaceConfigurations,
            persisted: state.workspaceConfigurations
        )
    }

    static func workspaceConfigurationIsApplied(
        _ current: [SetupWorkspaceConfiguration],
        persisted: [SetupWorkspaceConfiguration]?
    ) -> Bool {
        guard let persisted else { return false }
        return SiloBootstrapConfiguration(persisted) == SiloBootstrapConfiguration(current)
    }

    private var workspaceValidationMessage: String? {
        SetupWorkspaceConfiguration.validationMessage(for: workspaceConfigurations)
    }

    private var configuredWorkspaceNames: [String] {
        workspaceConfigurations.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private var setupPhases: [SiloBootstrapState.Phase] {
        [.preflight, .toolchain, .hostIntegration, .workspaces, .github, .identity, .complete]
    }

    private var showsGitHubConnectAction: Bool {
        account == nil
    }

    private var isGitHubConnected: Bool {
        account != nil || githubHostCredentialPresent
    }

    /// Connecting an account is not itself a GitHub decision. Keep the
    /// optional path visible until repository access has actually been saved.
    private var showsGitHubSkipAction: Bool {
        !repositoryPolicyApplied
    }

    private var githubDecisionMade: Bool {
        githubSkipped ||
            repositoryPolicyApplied
    }



    private var identityDecisionMade: Bool {
        identitySkipped || SetupIdentityVerification.isComplete(
            requiredWorkspaces: Set(configuredWorkspaceNames),
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
            (githubSkipped
                ? (githubApplyProgress == nil || githubApplyProgress?.isTerminalSuccess == true)
                : githubApplyProgress?.isTerminalSuccess == true)
    }

    /// Pure decision, unit-tested directly: Review/Done stay unavailable until
    /// the restored GitHub context has finished loading, even when persisted
    /// completed choices would otherwise satisfy every other gate.
    static func allowsReviewCompletion(
        contextLoaded: Bool,
        systemReady: Bool,
        githubDecided: Bool,
        identityDecided: Bool,
        verificationsAllowCompletion: Bool,
        registrationOutstanding: Bool
    ) -> Bool {
        contextLoaded &&
            systemReady &&
            githubDecided &&
            identityDecided &&
            verificationsAllowCompletion &&
            !registrationOutstanding
    }

    static func canSubmitWorkspaceConfiguration(
        validationMessage: String?,
        bootstrapInputReady: Bool
    ) -> Bool {
        validationMessage == nil && bootstrapInputReady
    }

    private var reviewRequirementsSatisfied: Bool {
        workspaceValidationMessage == nil && Self.allowsReviewCompletion(
            contextLoaded: githubContextLoaded,
            systemReady: canFinishWithoutGitHub,
            githubDecided: githubDecisionMade,
            identityDecided: identityDecisionMade,
            verificationsAllowCompletion: verificationAllowsCompletion,
            registrationOutstanding: registrationOutstanding
        )
    }

    private var canCompleteReview: Bool { setupQueue.isDone }

    private var hostIntegrationNeedsPackagedBuild: Bool {
        checks.contains { $0.id == "host-integration" && $0.status == .unavailable }
    }

    @ViewBuilder
    private var activeStepContent: some View {
        switch activeStep {
        case .dependencies:
            runtimeInstallationCard
            applicationPreferencesCard
        case .workspaces:
            workspaceConfigurationStep
        case .github:
            githubBoundary
        case .identity:
            identitySection
        case .review:
            finalReview
        }
    }

    private var setupStepper: some View {
        HStack(spacing: 0) {
            ForEach(SetupStep.allCases) { step in
                if step != .dependencies {
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
                .opacity(activeStep == step || canSelectStep(step) ? 1 : 0.55)
                .help(stepHelpText(step))
                .accessibilityIdentifier(step.accessibilityIdentifier)
                .accessibilityValue(
                    stepIsComplete(step)
                        ? "Complete"
                        : (activeStep == step ? "Current step" : stepLockedValue(step))
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup.stepper")
    }

    /// A submitted decision unlocks navigation; verification remains a Review
    /// requirement and never turns an earlier Continue into an operation gate.
    private var githubStepComplete: Bool {
        githubContextLoaded && (githubDecisionMade || isApplyingGitHub)
    }

    private var identityStepComplete: Bool {
        identityDecisionMade || isSavingIdentity
    }

    private func stepIsComplete(_ step: SetupStep) -> Bool {
        switch step {
        case .dependencies: return systemReady
        case .workspaces: return workspaceConfigurationAccepted && workspaceValidationMessage == nil
        case .github: return githubStepComplete
        case .identity: return identityStepComplete
        case .review: return canCompleteReview
        }
    }

    private func canSelectStep(_ step: SetupStep) -> Bool {
        switch step {
        case .dependencies:
            return true
        case .workspaces:
            return systemReady
        case .github:
            return workspaceConfigurationAccepted && workspaceValidationMessage == nil
        case .identity:
            return githubStepComplete
        case .review:
            return githubStepComplete && identityStepComplete
        }
    }
    /// Greyed-out steps stay disabled until their prerequisites are proven;
    /// the tooltip names the missing prerequisite so the lock is legible.
    private func stepHelpText(_ step: SetupStep) -> String {
        if canSelectStep(step) {
            return stepIsComplete(step) ? "Completed" : "Current setup step"
        }
        return "Unavailable: \(stepLockReason(step))"
    }

    private func stepLockedValue(_ step: SetupStep) -> String {
        "Not available yet: \(stepLockReason(step))"
    }

    private func stepLockReason(_ step: SetupStep) -> String {
        switch step {
        case .dependencies:
            return "dependency checks are still loading"
        case .workspaces:
            return "the Workspaces step follows Dependencies"
        case .github:
            return "submit a valid workspace configuration first"
        case .identity:
            return "the GitHub choice must finish loading or be submitted first"
        case .review:
            return "the GitHub and identity choices must be submitted first"
        }
    }
    private func selectStep(_ step: SetupStep) {
        guard canSelectStep(step) else { return }
        activeStep = step
    }
    /// Workspaces consume the runtime and configuration established here, so
    /// navigation stays locked until owner and every blocking check pass.
    private func advanceFromDependencies() {
        guard systemReady else { return }
        activeStep = .workspaces
    }
    private func advanceFromWorkspaces() {
        guard Self.canSubmitWorkspaceConfiguration(
            validationMessage: workspaceValidationMessage,
            bootstrapInputReady: bootstrapInputReady
        ) else { return }
        workspaceConfigurationAccepted = true
        rebuildWorkspaceScopedState()
        if !uiTestMode {
            persistResumeState()
        }
        if case .workspaces(let retained)? = setupQueue.item(.workspaceRun).input,
           retained == workspaceConfigurations {
            // Keep the in-flight candidate and its progress when navigation
            // revisits Workspaces without changing the submitted values.
        } else {
            setupQueue.submitWorkspaces(workspaceConfigurations)
        }
        startWorkspaceRegistration()
        startGitHubContextLoad()
        activeStep = .github
    }
    private func advanceFromGitHub() {
        guard githubStepComplete, !isSkippingGitHub, githubSkipIssue == nil else { return }
        activeStep = .identity
    }

    private func skipGitHub() {
        guard !githubSkipped, !isConnectingGitHub, !isApplyingGitHub, !isSkippingGitHub else { return }
        if let failed = setupQueue.failedItem,
           failed.id == .githubRun || failed.id == .githubVerify {
            _ = setupQueue.retryFailedItem()
        }
        githubSkipped = true
        setupQueue.submitGitHubSkip()
        localCatalogIssue = nil
        githubStatus = "GitHub skipped. You can go back and connect it later."
        activeStep = .identity
    }

    private var skipGitHubButton: some View {
        Button("Skip", action: skipGitHub)
        .buttonStyle(.bordered)
        .disabled(githubSkipped || isConnectingGitHub || isApplyingGitHub || isSkippingGitHub)
        .accessibilityValue(isSkippingGitHub ? "Skipping" : "Ready")
        .accessibilityIdentifier("setup.github.skip.button")
    }

    private func moveBack() {
        switch activeStep {
        case .dependencies:
            break
        case .workspaces:
            activeStep = .dependencies
        case .github:
            activeStep = .workspaces
        case .identity:
            activeStep = .github
        case .review:
            activeStep = .identity
        }
    }


    private var runtimeInstallationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Dependencies")
                    .font(.title3.weight(.semibold))
                Spacer()
                if runtimeSetupPhase != .ready && runtimeSetupError == nil {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityIdentifier("setup.runtime-owner.progress")
                }
            }
            if let runtimeSetupError {
                Text(runtimeSetupError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if runtimeSetupPhase == .ready {
                preflight
            }
            runtimeInstallationRow(
                title: "Bundled Silo tools",
                phase: .installingRuntime,
                identifier: "setup.runtime-owner.tools"
            )
            runtimeInstallationRow(
                title: "Default configuration",
                phase: .installingConfiguration,
                identifier: "setup.runtime-owner.configuration"
            )
            runtimeInstallationRow(
                title: "Installation verification",
                phase: .verifying,
                identifier: "setup.runtime-owner.verification"
            )
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup.runtime-owner")
    }


    private func runtimeInstallationRow(
        title: String,
        phase: SiloRuntimeSetupPhase,
        identifier: String
    ) -> some View {
        let isComplete = runtimeSetupPhase == .ready || runtimeSetupPhase.rawValue > phase.rawValue
        let isActive = runtimeSetupError == nil && runtimeSetupPhase == phase
        return HStack(spacing: 8) {
            if isComplete {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if isActive {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: runtimeSetupError == nil ? "circle" : "xmark.circle.fill")
                    .foregroundStyle(runtimeSetupError == nil ? Color.secondary : Color.red)
            }
            Text(title)
            Spacer()
            Text(isComplete ? "Installed" : (isActive ? "Installing" : "Waiting"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(isComplete ? "Installed" : (isActive ? "Installing" : "Waiting"))
        .accessibilityIdentifier(identifier)
    }

    private var applicationPreferencesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Applications")
                .font(.title3.weight(.semibold))
            ApplicationPreferenceFields(
                applicationPreferences: applicationPreferences,
                accessibilityPrefix: "setup"
            )
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup.applications")
    }

    private var preflight: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Dependency checks").font(.title3.weight(.semibold))
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
                        warningChecks.isEmpty ? "This Mac is ready for Silo." : "This Mac is ready; review the advisory below.",
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

    private var workspaceConfigurationStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Configure workspaces")
                .font(.title3.weight(.semibold))
                .accessibilityIdentifier("setup.workspaces.title")

            HStack {
                Button {
                    addWorkspaceConfiguration()
                } label: {
                    Label("Add workspace", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
                .accessibilityIdentifier("setup.workspaces.add.button")
                Spacer()
            }

            ForEach(Array(workspaceConfigurations.enumerated()), id: \.element.id) { index, configuration in
                workspaceConfigurationRow(configuration, at: index)
            }

            if let workspaceValidationMessage {
                Label(workspaceValidationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("setup.workspaces.validation")
            }

            if workspaceNamesNeedApproval {
                Label("Saving will update these names on your Mac. macOS will ask for your administrator password once.", systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("setup.workspaces.approval-hint")
            }

        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup.workspaces")
    }

    private func workspaceConfigurationRow(
        _ configuration: SetupWorkspaceConfiguration,
        at index: Int
    ) -> some View {
        return GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    TextField("Workspace name", text: workspaceNameBinding(for: configuration.id))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Workspace name")
                        .accessibilityIdentifier("setup.workspaces.row.\(index).name")
                    Button(role: .destructive) {
                        removeWorkspaceConfiguration(id: configuration.id)
                    } label: {
                        Label("Remove", systemImage: "minus.circle")
                    }
                    .accessibilityLabel("Remove \(configuration.name.isEmpty ? "workspace" : configuration.name)")
                    .accessibilityIdentifier("setup.workspaces.row.\(index).remove.button")
                }

                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                    GridRow {
                        resourceLabel("CPU limit")
                        resourcePicker(
                            "CPU limit", selection: workspaceBinding(for: configuration, \.cpus),
                            values: SetupWorkspaceConfiguration.supportedCPUs,
                            suffix: "CPU", identifier: "setup.workspaces.row.\(index).cpus",
                            help: "CPU cores this workspace always gets"
                        )
                        resourceLabel("CPU ceiling")
                        resourcePicker(
                            "CPU ceiling", selection: workspaceBinding(for: configuration, \.maxCPUs),
                            values: SetupWorkspaceConfiguration.supportedCPUs,
                            suffix: "CPU", identifier: "setup.workspaces.row.\(index).max-cpus",
                            help: "Most CPUs it can be resized up to"
                        )
                    }
                    GridRow {
                        resourceLabel("Memory limit")
                        resourcePicker(
                            "Memory limit", selection: workspaceBinding(for: configuration, \.memoryGiB),
                            values: SetupWorkspaceConfiguration.supportedMemoryGiB,
                            suffix: "GB", identifier: "setup.workspaces.row.\(index).memory",
                            help: "RAM this workspace always gets"
                        )
                        resourceLabel("Memory ceiling")
                        resourcePicker(
                            "Memory ceiling", selection: workspaceBinding(for: configuration, \.maxMemoryGiB),
                            values: SetupWorkspaceConfiguration.supportedMemoryGiB,
                            suffix: "GB", identifier: "setup.workspaces.row.\(index).max-memory",
                            help: "Most RAM it can be resized up to"
                        )
                    }
                    GridRow {
                        resourceLabel("Workspace storage")
                        resourcePicker(
                            "Workspace storage", selection: workspaceBinding(for: configuration, \.workspaceStorageGiB),
                            values: SetupWorkspaceConfiguration.supportedStorageGiB,
                            suffix: "GB", identifier: "setup.workspaces.row.\(index).workspace-storage",
                            help: "Disk space for your files"
                        )
                        resourceLabel("Runtime storage")
                        resourcePicker(
                            "Runtime storage", selection: workspaceBinding(for: configuration, \.runtimeStorageGiB),
                            values: SetupWorkspaceConfiguration.supportedStorageGiB,
                            suffix: "GB", identifier: "setup.workspaces.row.\(index).runtime-storage",
                            help: "Disk space for VM images and runtimes"
                        )
                    }
                }
            }
            .padding(.vertical, 2)
        } label: {
            Text(configuration.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Unnamed workspace" : configuration.name)
                .font(.headline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup.workspaces.row.\(index)")
    }

    private func resourceLabel(_ title: String) -> some View {
        Text(title)
    }

    private func resourcePicker(
        _ title: String,
        selection: Binding<Int>,
        values: [Int],
        suffix: String,
        identifier: String,
        help: String
    ) -> some View {
        Picker(title, selection: selection) {
            ForEach(values, id: \.self) { value in
                Text("\(value) \(suffix)").tag(value)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(minWidth: 90, alignment: .leading)
        .accessibilityLabel(title)
        .accessibilityValue("\(selection.wrappedValue) \(suffix)")
        .accessibilityIdentifier(identifier)
        .help(help)
    }

    private func workspaceBinding<Value>(
        for configuration: SetupWorkspaceConfiguration,
        _ keyPath: WritableKeyPath<SetupWorkspaceConfiguration, Value>
    ) -> Binding<Value> {
        Binding(
            get: {
                workspaceConfigurations.first(where: { $0.id == configuration.id })?[keyPath: keyPath]
                    ?? configuration[keyPath: keyPath]
            },
            set: { value in
                guard let index = workspaceConfigurations.firstIndex(where: { $0.id == configuration.id }) else {
                    return
                }
                workspaceConfigurations[index][keyPath: keyPath] = value
                workspaceConfigurationAccepted = false
                cancelGitHubContextLoad()
            }
        )
    }

    private func addWorkspaceConfiguration() {
        let existing = Set(configuredWorkspaceNames.map { $0.lowercased() })
        var suffix = workspaceConfigurations.count + 1
        var name = "workspace-\(suffix)"
        while existing.contains(name) {
            suffix += 1
            name = "workspace-\(suffix)"
        }
        var configuration = SetupWorkspaceConfiguration.defaults[0]
        configuration = SetupWorkspaceConfiguration(
            name: name,
            cpus: configuration.cpus,
            maxCPUs: configuration.maxCPUs,
            memoryGiB: configuration.memoryGiB,
            maxMemoryGiB: configuration.maxMemoryGiB,
            workspaceStorageGiB: configuration.workspaceStorageGiB,
            runtimeStorageGiB: configuration.runtimeStorageGiB
        )
        // Put the new row where it is immediately visible and focusable in
        // the setup window; the row's UUID keeps SwiftUI identity stable.
        workspaceConfigurations.insert(configuration, at: 0)
        resetWorkspaceDependentState()
    }

    private func removeWorkspaceConfiguration(id: UUID) {
        guard let index = workspaceConfigurations.firstIndex(where: { $0.id == id }) else { return }
        workspaceConfigurations.remove(at: index)
        resetWorkspaceDependentState()
    }

    private func workspaceNameBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { workspaceConfigurations.first(where: { $0.id == id })?.name ?? "" },
            set: { newName in
                guard let index = workspaceConfigurations.firstIndex(where: { $0.id == id }),
                      workspaceConfigurations[index].name != newName else { return }
                workspaceConfigurations[index].name = newName
                resetWorkspaceDependentState()
            }
        )
    }

    /// Workspace names scope every later GitHub and Git choice. A structural
    /// edit invalidates those choices so no policy or verification can remain
    /// silently attached to a removed or renamed VM.
    private func resetWorkspaceDependentState() {
        workspaceConfigurationAccepted = false
        cancelGitHubContextLoad()
        drafts = SetupWorkspaceConfiguration.initialRepositoryDrafts(for: workspaceConfigurations)
        savedGitHubDrafts = drafts
        editedGitHubWorkspaces.removeAll()
        retainedRepositoryPolicy.removeAll()
        repositoryPolicyApplied = false
        githubSkipped = false
        githubApplyProgress = nil
        githubAttentionWorkspace = nil
        localCatalogAttempted = false
        identityTarget = "all"
        identityConfiguredWorkspaces.removeAll()
        verifiedIdentityByWorkspace.removeAll()
        identitySkipped = false
        identityStatus = ""
    }

    /// Rebuilds downstream state from the workspace configuration installed
    /// and verified by bootstrap. Stale names from resume data or a prior
    /// provider generation are discarded rather than silently following a rename.
    private func rebuildWorkspaceScopedState() {
        let names = configuredWorkspaceNames
        let configured = Set(names)
        let retainedByWorkspace = Dictionary(
            uniqueKeysWithValues: retainedRepositoryPolicy
                .filter { configured.contains($0.workspace) }
                .map { ($0.workspace, $0) }
        )
        retainedRepositoryPolicy = names.compactMap { retainedByWorkspace[$0] }
        editedGitHubWorkspaces.formIntersection(configured)

        var rebuiltDrafts = SetupWorkspaceConfiguration.initialRepositoryDrafts(
            for: workspaceConfigurations
        )
        for policy in retainedRepositoryPolicy {
            var draft = rebuiltDrafts[policy.workspace] ?? .initial(policy.workspace)
            draft.repositoryModes = Dictionary(uniqueKeysWithValues: policy.repositories.map {
                (GitHubProvider.canonicalize($0.fullName), $0.mode)
            })
            rebuiltDrafts[policy.workspace] = draft
        }
        drafts = rebuiltDrafts
        savedGitHubDrafts = rebuiltDrafts

        if !githubSkipped,
           Set(retainedRepositoryPolicy.map(\.workspace)) != configured {
            repositoryPolicyApplied = false
        }
        identityConfiguredWorkspaces.formIntersection(configured)
        verifiedIdentityByWorkspace = verifiedIdentityByWorkspace.filter {
            configured.contains($0.key)
        }
        if identityTarget != "all", !configured.contains(identityTarget) {
            identityTarget = "all"
        }
        localCatalogAttempted = false
        githubHostCredentialPresent = false
        account = nil
        owners = []
        repositoriesByOwner = [:]
    }

    @ViewBuilder
    private func preflightRow(_ check: SiloPreflightCheck, prominent: Bool) -> some View {
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
        if !githubContextLoaded {
            VStack(alignment: .leading, spacing: 12) {
                Text("GitHub")
                    .font(.title3.weight(.semibold))
                    .accessibilityIdentifier("setup.github.title")
                VStack(alignment: .leading, spacing: 12) {
                    githubLoadingSkeleton
                }
                .accessibilityIdentifier("setup.github.loading")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("setup.github-boundary")
        } else {
            localGitHubBoundary
        }
    }

    private var localGitHubBoundary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GitHub")
                .font(.title3.weight(.semibold))
                .accessibilityIdentifier("setup.github.title")

            Text("Account")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            if showsGitHubLoadingSkeleton {
                githubLoadingSkeleton
            } else {
                if let account {
                    githubConnectedAccountRow("Connected as @\(account.login)")
                } else if githubHostCredentialPresent {
                    githubConnectedAccountRow("GitHub account connected on this Mac")
                }

                if localCatalogAttempted && !isGitHubConnected && !isRefreshingGitHub {
                    HStack {
                        Spacer()
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
                        .disabled(isConnectingGitHub || isResettingGitHub || provider == nil)
                        .accessibilityValue(isConnectingGitHub ? "Connecting" : "Ready")
                        .accessibilityIdentifier("setup.github.connect-account.button")
                    }
                }

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
                    repositoryAccessSection
                }

                githubStatusSlot
                githubApplyProgressView
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup.github-boundary")
    }

    private var showsGitHubLoadingSkeleton: Bool {
        isRefreshingGitHub &&
            account == nil &&
            !githubHostCredentialPresent &&
            owners.isEmpty &&
            repositoriesByOwner.isEmpty
    }

    private var githubLoadingSkeleton: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle().frame(width: 22, height: 22)
                RoundedRectangle(cornerRadius: 4).frame(width: 180, height: 14)
            }
            RoundedRectangle(cornerRadius: 8).frame(height: 72)
            RoundedRectangle(cornerRadius: 8).frame(height: 72)
        }
        .foregroundStyle(.quaternary)
        .overlay(alignment: .topTrailing) {
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading GitHub account and repositories")
        .accessibilityIdentifier("setup.github.catalog.loading")
    }

    private func githubConnectedAccountRow(_ label: String) -> some View {
        HStack(spacing: 10) {
            Label(label, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel(label)
                .accessibilityIdentifier("setup.github.account")
            Spacer()
            if isResettingGitHub {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Resetting GitHub access")
            }
            Button("Reset…", role: .destructive) {
                githubResetAction = .reset
            }
            .disabled(isResettingGitHub || isConnectingGitHub || isApplyingGitHub)
            .accessibilityIdentifier("setup.github.reset")
        }
        .controlSize(.small)
    }

    private var repositoryAccessSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Repository access")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("setup.github.repository-access.title")
            repositoryPolicyEditor
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var githubStatusSlot: some View {
        if !githubStatus.isEmpty {
            Text(githubStatus)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .accessibilityIdentifier("setup.github.status")
        }
    }

    @ViewBuilder
    private var githubApplyProgressView: some View {
        if let progress = githubApplyProgress, progress.phase != .applied {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    if progress.isInFlight {
                        ProgressView().controlSize(.small).accessibilityHidden(true)
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                    }
                    Text(progress.label).fontWeight(.semibold)
                    Text(progress.summary).foregroundStyle(.secondary)
                }
                if let failure = progress.failure {
                    Text(failure.presentationRecovery)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if progress.canRetry {
                    Button("Retry GitHub sync") { retryLocalPolicyApply() }
                        .controlSize(.small)
                        .accessibilityIdentifier("setup.github.apply.retry.button")
                }
                if progress.canCancel {
                    Button("Cancel sync") { cancelLocalPolicyApply() }
                        .controlSize(.small)
                        .accessibilityIdentifier("setup.github.apply.cancel.button")
                }
            }
            .font(.caption)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("setup.github.apply.progress")
            .accessibilityValue("\(progress.label). \(progress.summary)")
        }
    }

    private func localCatalogIssueTitle(_ kind: LocalCatalogIssueKind) -> String {
        switch kind {
        case .unavailable: return "GitHub unavailable"
        case .failed: return "GitHub repositories could not be loaded"
        }
    }

    private func captureGitHubDraftBaseline() {
        savedGitHubDrafts = Dictionary(
            uniqueKeysWithValues: configuredWorkspaceNames.map { workspace in
                (workspace, drafts[workspace] ?? .initial(workspace))
            }
        )
        editedGitHubWorkspaces.removeAll()
    }

    private func reconcileGitHubDraftState() {
        editedGitHubWorkspaces = Set(configuredWorkspaceNames.filter { workspace in
            (drafts[workspace] ?? .initial(workspace)) !=
                (savedGitHubDrafts[workspace] ?? .initial(workspace))
        })
        if !editedGitHubWorkspaces.isEmpty {
            repositoryPolicyApplied = false
        } else if githubApplyProgress?.phase != .cancelled &&
                    (githubApplyProgress != nil || !retainedRepositoryPolicy.isEmpty) {
            repositoryPolicyApplied = true
        }
    }
    private var repositoryPolicyEditor: some View {
        RepositoryWorkspacePolicyEditor(
            workspaces: configuredWorkspaceNames,
            owners: owners,
            repositoriesByOwner: repositoriesByOwner,
            drafts: $drafts,
            editedWorkspaces: $editedGitHubWorkspaces,
            disabled: isApplyingGitHub || isResettingGitHub,
            onEdit: {
                reconcileGitHubDraftState()
                githubSkipped = false
            },
            showsHeading: false,
            highlightsEdits: true,
            usesContainerBackground: false
        )
        .accessibilityIdentifier("setup.github.repository-policy")
    }

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your name for Git changes").font(.title3.weight(.semibold))
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
                Text("All configured workspaces").tag("all")
                ForEach(configuredWorkspaceNames, id: \.self) { workspace in
                    Text(workspace).tag(workspace)
                }
            }
            .accessibilityIdentifier("setup.identity.target")
            Text(identityTarget == "all"
                ? "Targets: \(configuredWorkspaceNames.joined(separator: ", "))."
                : "Target: \(identityTarget) only. Other workspace Git settings remain unchanged.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
            reviewStatusLine(
                title: "Configured workspaces",
                value: workspaceConfigurationReviewSummary,
                ready: workspaceValidationMessage == nil,
                accessibilityIdentifier: "setup.final-review.workspaces"
            )
            setupQueueReview
            githubApplyProgressView
            reviewStatusLine(
                title: "Terminal",
                value: applicationPreferences.resolvedTerminalName,
                ready: true,
                accessibilityIdentifier: "setup.final-review.terminal"
            )
            reviewStatusLine(
                title: "Code editor",
                value: applicationPreferences.resolvedSourceEditorName,
                ready: true,
                accessibilityIdentifier: "setup.final-review.editor"
            )
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var setupQueueReview: some View {
        ForEach(setupQueue.items) { item in
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: queueSymbol(for: item.status))
                    .foregroundStyle(queueColor(for: item.status))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.label).font(.headline)
                    if let failure = item.failure {
                        Text(failure)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("\(queueAccessibilityIdentifier(for: item)).detail")
                    } else if item.id == .identityVerify {
                        Text(identityReviewMessage).font(.caption).foregroundStyle(.secondary)
                    } else if item.id == .githubVerify {
                        Text("Public repositories remain cloneable without a grant.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityElement(children: item.failure == nil ? .combine : .contain)
            .accessibilityLabel(item.label)
            .accessibilityValue(queueAccessibilityValue(for: item))
            .accessibilityIdentifier(queueAccessibilityIdentifier(for: item))
        }
        if let failed = setupQueue.failedItem {
            Button("Retry \(failed.label)", action: retrySetupQueue)
                .controlSize(.small)
                .accessibilityIdentifier("setup.review.verify.button")
        } else if setupQueue.status(of: .workspaceRun) == .succeeded,
                  setupQueue.status(of: .workspaceVerify) == .queued {
            Button("Verify workspaces", action: startWorkspaceRegistration)
                .controlSize(.small)
                .accessibilityIdentifier("setup.review.verify.button")
        }
    }

    private func queueSymbol(for status: SetupQueueItemStatus) -> String {
        switch status {
        case .queued: return "clock"
        case .running: return "ellipsis.circle"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private func queueColor(for status: SetupQueueItemStatus) -> Color {
        switch status {
        case .queued, .running: return .secondary
        case .succeeded: return .green
        case .failed: return .red
        }
    }

    private func queueAccessibilityIdentifier(for item: SetupQueueItem) -> String {
        if item.id == .workspaceRun, item.status == .failed {
            return "setup.review.registration.failure"
        }
        if item.id == .workspaceVerify {
            switch item.status {
            case .queued, .running: return "setup.review.registration.pending"
            case .succeeded: return "setup.review.registration.succeeded"
            case .failed: return "setup.review.registration.failure"
            }
        }
        if item.id == .identityVerify { return "setup.final-review.identity" }
        return "setup.review.queue.\(item.id.rawValue)"
    }

    private func queueAccessibilityValue(for item: SetupQueueItem) -> String {
        if let failure = item.failure { return failure }
        if item.id == .identityVerify { return identityReviewMessage }
        return item.status.rawValue.capitalized
    }

    private var workspaceConfigurationReviewSummary: String {
        workspaceConfigurations.map { configuration in
            "\(configuration.name): \(configuration.cpus)/\(configuration.maxCPUs) CPU, " +
                "\(configuration.memoryGiB)/\(configuration.maxMemoryGiB) GB memory, " +
                "\(configuration.workspaceStorageGiB) GB workspace storage, " +
                "\(configuration.runtimeStorageGiB) GB runtime storage"
        }.joined(separator: "; ")
    }
    private var identityReviewMessage: String {
        if identitySkipped {
            return "Skipped by choice. Git keeps each workspace's existing author identity."
        }
        if isSavingIdentity {
            return "Saving \(identityName.trimmingCharacters(in: .whitespacesAndNewlines)) " +
                "<\(identityEmail.trimmingCharacters(in: .whitespacesAndNewlines))> to the selected workspaces."
        }
        if identityDecisionMade {
            if !identityStatus.isEmpty { return identityStatus }
            return "Saved to \(identityConfiguredWorkspaces.sorted().joined(separator: ", "))."
        }
        if !identityStatus.isEmpty { return identityStatus }
        if identityHasUnverifiedEdits {
            return "The entered name or email changed after the last save. Save the updated details before finishing."
        }
        if canSaveIdentity {
            return "The name and email are entered but have not been saved to the workspaces."
        }
        return "Enter and save a name and valid email, or skip this optional step."
    }

    @ViewBuilder
    private func reviewStatusLine(
        title: String,
        value: String? = nil,
        ready: Bool,
        pending: Bool = false,
        accessibilityIdentifier: String? = nil
    ) -> some View {
        let line = HStack(alignment: .top, spacing: 9) {
            Image(systemName: ready ? "checkmark.circle.fill" : (pending ? "clock.fill" : "exclamationmark.triangle.fill"))
                .foregroundStyle(ready ? Color.green : (pending ? Color.secondary : Color.orange))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let value {
                    Text(value).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        if let accessibilityIdentifier {
            if let value {
                line
                    .accessibilityLabel(title)
                    .accessibilityValue(value)
                    .accessibilityIdentifier(accessibilityIdentifier)
            } else {
                line
                    .accessibilityLabel(title)
                    .accessibilityIdentifier(accessibilityIdentifier)
            }
        } else {
            line
        }
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
            if let failed = setupQueue.failedItem, activeStep != .review {
                VStack(alignment: .leading, spacing: 4) {
                    Label("\(failed.label) failed", systemImage: "exclamationmark.circle.fill")
                    .fontWeight(.semibold)
                    .accessibilityLabel("\(failed.label) failed")
                    .accessibilityIdentifier("setup.registration.failure.title")
                    Text(failed.failure ?? "Setup stopped before this item completed.")
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(failed.failure ?? "Setup stopped before this item completed.")
                        .accessibilityIdentifier("setup.registration.failure.detail")
                }
                .foregroundStyle(.red)
            } else if let running = setupQueue.runningItem {
                Label(running.label, systemImage: "ellipsis.circle")
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            } else if let error {
                Label(error, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
            } else if let notice {
                Label(notice, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else if hostIntegrationNeedsPackagedBuild {
                Label("Install a complete signed Silo build to continue.", systemImage: "lock.circle.fill")
                    .foregroundStyle(.orange)
            } else if activeStep == .workspaces, let workspaceValidationMessage {
                Label(workspaceValidationMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup.status")
    }


    private var footerActions: some View {
        HStack(alignment: .center, spacing: 10) {
            if activeStep == .github && showsGitHubSkipAction {
                skipGitHubButton
            }
            if activeStep == .identity {
                Button("Skip") {
                    identitySkipped = true
                    identityStatus = ""
                    setupQueue.submitIdentitySkip()
                    setupQueue.deriveCompletion(requirementsSatisfied: reviewRequirementsSatisfied)
                    activeStep = .review
                }
                .buttonStyle(.bordered)
                .disabled(isSavingIdentity)
                .accessibilityIdentifier("setup.identity.skip.button")
            }
            if activeStep != .dependencies {
                Button("Back", action: moveBack)
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSkippingGitHub || isApplyingGitHub || isConnectingGitHub || isSavingIdentity)
                    .accessibilityIdentifier("setup.back.button")
            }

            switch activeStep {
            case .dependencies:
                Button("Retry", action: loadDependencies)
                    .buttonStyle(.bordered)
                    .disabled(isChecking || coordinator == nil)
                    .accessibilityIdentifier("setup.retry.button")
                if hostIntegrationNeedsPackagedBuild {
                    Label("Install the complete Silo app", systemImage: "lock.circle")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("setup.signed-build.required")
                } else {
                    Button(
                        "Continue",
                        action: advanceFromDependencies
                    )
                    .buttonStyle(.borderedProminent)
                    .disabled(!systemReady)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityValue(systemReady ? "Ready" : "Installing dependencies")
                    .accessibilityIdentifier("setup.primary-action")
                }
            case .workspaces:
                Button("Continue", action: advanceFromWorkspaces)
                .buttonStyle(.borderedProminent)
                .disabled(!Self.canSubmitWorkspaceConfiguration(
                    validationMessage: workspaceValidationMessage,
                    bootstrapInputReady: bootstrapInputReady
                ))
                .keyboardShortcut(.defaultAction)
                .accessibilityValue(
                    workspaceValidationMessage != nil
                        ? "Invalid configuration"
                        : (bootstrapInputReady ? "Ready" : "Loading setup")
                )
                .accessibilityIdentifier("setup.workspaces.continue.button")
            case .github:
                if githubStepComplete {
                    Button("Continue", action: advanceFromGitHub)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("setup.github.continue.button")
                } else {
                    Button(action: {
                        commitPolicy()
                        activeStep = .identity
                    }) {
                        ZStack {
                            Text("Continue")
                                .opacity(isApplyingGitHub ? 0 : 1)
                            ProgressView()
                                .controlSize(.small)
                                .opacity(isApplyingGitHub ? 1 : 0)
                                .accessibilityHidden(true)
                        }
                    }
                        .buttonStyle(.borderedProminent)
                        .disabled(!isGitHubConnected || !hasValidAssignments || isApplyingGitHub || isSkippingGitHub || githubSkipIssue != nil)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityLabel("Continue")
                        .accessibilityValue(isApplyingGitHub ? "Saving" : "Ready")
                        .accessibilityIdentifier("setup.github.apply.button")
                }
            case .identity:
                Button {
                    if identitySkipped {
                        if canSaveIdentity {
                            saveIdentity()
                        } else {
                            activeStep = .review
                        }
                    } else if identityStepComplete {
                        activeStep = .review
                    } else {
                        saveIdentity()
                    }
                } label: {
                    ZStack {
                        Text("Continue")
                            .opacity(isSavingIdentity ? 0 : 1)
                        ProgressView()
                            .controlSize(.small)
                            .opacity(isSavingIdentity ? 1 : 0)
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled((!identitySkipped && !identityStepComplete && !canSaveIdentity) || isSavingIdentity)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Continue")
                .accessibilityValue(isSavingIdentity ? "Saving" : "Ready")
                .accessibilityIdentifier("setup.identity.continue.button")
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
        configuredWorkspaceNames.compactMap { workspace in
            guard editedGitHubWorkspaces.contains(workspace) else { return nil }
            let draft = drafts[workspace] ?? .initial(workspace)
            return GitHubWorkspacePolicy(
                workspace: workspace,
                repositories: policyEntries(for: draft)
            )
        }
    }

    private func policyEntries(for draft: WorkspaceRepositoryDraft) -> [GitHubRepositoryPolicy] {
        Self.repositoryPolicyEntries(
            workspace: draft.workspace,
            draft: draft,
            owners: owners,
            repositoriesByOwner: repositoriesByOwner
        )
    }

    /// Pure draft-to-policy mapping used by the editor and unit tests.
    static func repositoryPolicyEntries(
        workspace: String,
        draft: WorkspaceRepositoryDraft,
        owners: [GitHubOwner],
        repositoriesByOwner: [Int: [GitHubRepository]]
    ) -> [GitHubRepositoryPolicy] {
        // Canonical repository -> (repository, owner owner) lookup.
        var byCanonical: [String: (GitHubRepository, GitHubOwner)] = [:]
        for owner in owners {
            let repositories = repositoriesByOwner[owner.id] ?? []
            for repository in repositories {
                let canonical = GitHubProvider.canonicalize(repository.fullName)
                byCanonical[canonical] = (repository, owner)
            }
        }
        var result: [GitHubRepositoryPolicy] = []
        for (canonical, mode) in draft.repositoryModes {
            guard let (repository, owner) = byCanonical[canonical] else { continue }
            result.append(GitHubRepositoryPolicy(
                workspace: workspace,
                repositoryID: repository.id,
                fullName: repository.fullName,
                ownerID: owner.account.id,
                ownerLogin: owner.account.login,
                ownerType: owner.account.type,
                mode: repository.effectiveMode(mode)
            ))
        }
        return result
    }


    private var hasValidAssignments: Bool {
        !workspacePolicy.isEmpty
    }


    private func beginAuthorization() {
        guard workspaceConfigurationAccepted, githubContextLoaded else { return }
        loadLocalCatalog(force: true)
    }


    private func loadLocalCatalog(force: Bool = false) {
        guard workspaceConfigurationAccepted, githubContextLoaded else { return }
        guard force || !localCatalogAttempted else { return }
        if isRefreshingGitHub {
            queuedLocalCatalogRefresh = queuedLocalCatalogRefresh || force
            return
        }
        guard provider != nil else {
            localCatalogIssue = LocalCatalogIssue(
                kind: .unavailable,
                message: "GitHub local access is unavailable in this build."
            )
            return
        }
        localCatalogAttempted = true
        githubRefreshGeneration &+= 1
        let generation = githubRefreshGeneration
        isRefreshingGitHub = true
        localCatalogIssue = nil
        githubStatus = ""
        githubRefreshTask?.cancel()
        githubRefreshTask = Task {
            if force {
                await githubState.refresh()
            } else {
                await githubState.loadIfNeeded()
            }
            guard !Task.isCancelled, githubRefreshGeneration == generation else { return }

            account = githubState.connectedAccount
            owners = githubState.owners
            repositoriesByOwner = githubState.repositoriesByOwner
            isRefreshingGitHub = false
            githubRefreshTask = nil

            switch githubState.connectionState {
            case .ready(let account, _, let policy):
                githubHostCredentialPresent = true
                if owners.isEmpty && repositoriesByOwner.isEmpty {
                    githubStatus = "No repositories were found. Reset GitHub access, or skip GitHub. Public repositories remain cloneable without granting access."
                }
                prefillRepositoryPolicyDrafts(policy: policy)
                captureGitHubDraftBaseline()
                if let account {
                    prefillIdentity(from: account)
                }
            case .noCredential:
                githubHostCredentialPresent = false
                githubStatus = "Connect GitHub to grant authenticated repository access, or skip it for now."
            case .catalogUnavailable(let message):
                githubHostCredentialPresent = false
                localCatalogIssue = LocalCatalogIssue(kind: .unavailable, message: message)
            case .catalogFailed(let message):
                githubHostCredentialPresent = false
                localCatalogIssue = LocalCatalogIssue(kind: .failed, message: message)
            default:
                githubHostCredentialPresent = false
                localCatalogIssue = LocalCatalogIssue(
                    kind: .unavailable,
                    message: githubState.error ?? "GitHub local access is unavailable."
                )
            }

            let refreshAgain = queuedLocalCatalogRefresh
            queuedLocalCatalogRefresh = false
            if refreshAgain {
                loadLocalCatalog(force: true)
            }
        }
    }
    private func resetGitHubAccess() {
        guard !isResettingGitHub else { return }
        guard let provider else {
            localCatalogIssue = LocalCatalogIssue(
                kind: .unavailable,
                message: "GitHub access is unavailable in this build."
            )
            return
        }

        isResettingGitHub = true
        localCatalogIssue = nil
        githubStatus = "Resetting GitHub access…"

        // Workspace registration and policy reset both mutate workspace
        // runtime state. Stop the background registration, wait for its CLI
        // operation to release the lock, reset access, then resume it.
        let interruptedRegistration = registrationTask
        interruptedRegistration?.cancel()
        if let running = setupQueue.runningItem,
           running.id == .workspaceRun || running.id == .workspaceVerify {
            setupQueue.deferItem(running.id, revision: setupQueue.revision)
        }
        githubRefreshGeneration &+= 1
        let interruptedRefresh = githubRefreshTask
        interruptedRefresh?.cancel()
        githubRefreshTask = nil
        queuedLocalCatalogRefresh = false
        isRefreshingGitHub = false

        githubResetTask = Task {
            if let interruptedRegistration { await interruptedRegistration.value }
            if let interruptedRefresh { await interruptedRefresh.value }
            guard !Task.isCancelled else {
                isResettingGitHub = false
                githubResetTask = nil
                return
            }

            do {
                let progress = try await provider.resetAccess()
                retainedRepositoryPolicy = []
                drafts = SetupWorkspaceConfiguration.initialRepositoryDrafts(
                    for: workspaceConfigurations
                )
                savedGitHubDrafts = drafts
                editedGitHubWorkspaces.removeAll()
                repositoryPolicyApplied = false
                githubApplyProgress = progress

                isResettingGitHub = false
                githubResetTask = nil
                if interruptedRegistration != nil {
                    startWorkspaceRegistration()
                }
                loadLocalCatalog(force: true)
            } catch is CancellationError {
                isResettingGitHub = false
                githubResetTask = nil
            } catch {
                isResettingGitHub = false
                githubResetTask = nil
                githubStatus = ""
                localCatalogIssue = LocalCatalogIssue(
                    kind: .failed,
                    message: "GitHub access could not be reset: \(error.localizedDescription)"
                )
                if interruptedRegistration != nil {
                    startWorkspaceRegistration()
                }
            }
        }
    }


    /// Runs the CLI-owned host-credential flow. gh reuse completes
    /// in-process. When the CLI reports gh is unauthenticated with no
    /// device-flow client ID (SILO_HOST_OAUTH_NOT_CONFIGURED) the app
    /// launches the installed gh web OAuth flow and then retries auth; when
    /// the CLI reports the Device Flow is available
    /// (SILO_HOST_DEVICE_FLOW_INTERACTIVE_REQUIRED) the app presents the
    /// in-app device sheet. Other typed remedies surface verbatim.
    private func connectGitHubAccount() {
        guard workspaceConfigurationAccepted, githubContextLoaded,
              let provider, !isConnectingGitHub else { return }
        githubConnectionGeneration &+= 1
        let generation = githubConnectionGeneration
        githubConnectionTask?.cancel()
        isConnectingGitHub = true
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

    /// Prefills draft selections from the policy file (authenticated account). Every
    /// policy entry is preserved and keyed by canonical repository. The
    /// provider's catalog merge already keeps policy-only repos selectable on
    /// every load, so this only maps modes and never extends the catalog.
    private func prefillRepositoryPolicyDrafts(policy: GitHubPolicyFile?) {
        guard retainedRepositoryPolicy.isEmpty, let policy else { return }
        for workspace in configuredWorkspaceNames {
            guard !editedGitHubWorkspaces.contains(workspace),
                  var draft = drafts[workspace],
                  draft.repositoryModes.isEmpty,
                  let policyWorkspace = policy.workspaces[workspace] else {
                continue
            }
            let modes = Self.policyPrefill(policyWorkspace: policyWorkspace)
            if !modes.isEmpty {
                draft.repositoryModes = modes
                drafts[workspace] = draft
            }
        }
    }

    /// Pure policy prefill used by `prefillRepositoryPolicyDrafts`
    /// and exercised directly by unit tests. Returns canonical-keyed modes
    /// for EVERY policy entry; malformed canonicals are skipped so they can
    /// never reach a draft.
    static func policyPrefill(
        policyWorkspace: GitHubPolicyWorkspace
    ) -> [String: GitHubRepositoryAccessMode] {
        var modes: [String: GitHubRepositoryAccessMode] = [:]
        for entry in policyWorkspace.repos {
            let canonical = entry.canonical
            guard GitHubProvider.isValidCanonical(canonical) else { continue }
            modes[canonical] = entry.mode
        }
        return modes
    }

    private func commitPolicy(retained: [GitHubWorkspacePolicy]? = nil) {
        guard workspaceConfigurationAccepted, githubContextLoaded else { return }
        let workspacePolicies = retained ?? workspacePolicy
        guard !workspacePolicies.isEmpty else {
            githubStatus = "Choose at least one repository, or skip GitHub."
            return
        }
        let submittedWorkspaceConfigurations = workspaceConfigurations
        setupQueue.submitGitHub(.github(workspacePolicies))

        githubApplyGeneration &+= 1
        let generation = githubApplyGeneration
        isApplyingGitHub = true
        error = nil
        githubStatus = ""
        githubApplyTask?.cancel()

        guard let provider else {
            githubStatus = "GitHub is unavailable in this build."
            isApplyingGitHub = false
            return
        }
            // The apply continues in the background while Review remains
            // gated on its outcome. Only the user's Continue action navigates.
            githubApplyTask = Task {
                let registrationReady = await waitForWorkspaceRegistration(
                    submittedWorkspaceConfigurations
                )
                guard !Task.isCancelled else { return }
                guard registrationReady else {
                    await MainActor.run {
                        guard githubApplyGeneration == generation else { return }
                        isApplyingGitHub = false
                        githubApplyTask = nil
                    }
                    return
                }
                guard setupQueue.begin(.githubRun, revision: setupQueue.revision) else { return }
                do {
                    let progress = try await provider.savePolicy(workspacePolicies)
                    try Task.checkCancellation()
                    await MainActor.run {
                        guard githubApplyGeneration == generation else { return }
                        isApplyingGitHub = false
                        githubApplyTask = nil
                        githubSkipped = false
                        retainedRepositoryPolicy = workspacePolicies
                        repositoryPolicyApplied = true
                        githubApplyProgress = progress
                        setupQueue.succeed(.githubRun, revision: setupQueue.revision)
                        _ = setupQueue.begin(.githubVerify, revision: setupQueue.revision)
                        captureGitHubDraftBaseline()
                        editedGitHubWorkspaces.removeAll()
                        githubStatus = ""
                        monitorLocalPolicyApply(generation: generation)
                    }
                } catch is CancellationError {
                    // The setup surface closed or the lifecycle was invalidated.
                } catch {
                    await MainActor.run {
                        guard githubApplyGeneration == generation else { return }
                        isApplyingGitHub = false
                        githubApplyTask = nil
                        localCatalogIssue = LocalCatalogIssue(kind: .failed, message: error.localizedDescription)
                        setupQueue.fail(.githubRun, message: error.localizedDescription)
                        githubStatus = ""
                    }
                }
            }
    }

    private func refreshLocalApplyProgress() async {
        guard workspaceConfigurationAccepted, githubContextLoaded,
              provider != nil else { return }
        await syncLocalApplyProgress()
    }

    /// Reads the provider's durable apply intent into the step state without
    /// requiring the catalog/context chain to have finished. Runs after
    /// `rebuildWorkspaceScopedState`, which resets `repositoryPolicyApplied`
    /// from the empty per-session retained policy and would otherwise mask a
    /// policy that a previous session durably completed.
    private func syncLocalApplyProgress() async {
        guard let provider,
              let progress = await provider.policySyncProgress() else { return }
        githubApplyProgress = progress
        repositoryPolicyApplied = progress.phase != .cancelled
        if progress.isInFlight {
            monitorLocalPolicyApply(generation: githubApplyGeneration)
        }
    }

    private func monitorLocalPolicyApply(generation: Int) {
        githubProgressTask?.cancel()
        guard let provider else { return }
        githubProgressTask = Task {
            while !Task.isCancelled {
                guard let progress = await provider.policySyncProgress() else { return }
                await MainActor.run {
                    guard githubApplyGeneration == generation else { return }
                    githubApplyProgress = progress
                    isApplyingGitHub = false
                    if progress.isTerminalSuccess {
                        setupQueue.succeed(.githubVerify, revision: setupQueue.revision)
                        editedGitHubWorkspaces.removeAll()
                        githubStatus = ""
                        resumeQueuedSetupWork()
                    } else if progress.phase == .failed {
                        setupQueue.fail(
                            .githubVerify,
                            message: progress.failure?.message ?? "GitHub verification failed."
                        )
                        githubStatus = "GitHub choices are saved, but synchronization needs attention."
                    }
                }
                if !progress.isInFlight { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func retryLocalPolicyApply() {
        guard let provider else { return }
        if setupQueue.failedItem?.id == .githubVerify {
            _ = setupQueue.retryFailedItem()
        }
        _ = setupQueue.begin(.githubVerify, revision: setupQueue.revision)
        githubApplyGeneration &+= 1
        let generation = githubApplyGeneration
        githubStatus = "Retrying GitHub synchronization…"
        githubApplyTask = Task {
            do {
                try await provider.retryPolicySync()
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    monitorLocalPolicyApply(generation: generation)
                }
            } catch {
                await MainActor.run {
                    setupQueue.fail(.githubVerify, message: error.localizedDescription)
                    githubStatus = "GitHub synchronization could not be retried: \(error.localizedDescription)"
                }
            }
        }
    }

    private func cancelLocalPolicyApply() {
        guard let provider else { return }
        githubProgressTask?.cancel()
        setupQueue.deferItem(.githubVerify, revision: setupQueue.revision)
        Task {
            await provider.cancelPolicySync()
            let progress = await provider.policySyncProgress()
            await MainActor.run {
                githubApplyProgress = progress
                if progress?.phase == .cancelled {
                    githubStatus = "GitHub synchronization cancelled. Your saved choices remain available."
                }
            }
        }
    }

    /// Restores a previously applied boundary. A fresh Workspaces Continue
    /// starts GitHub loading immediately while bootstrap installs and verifies
    /// the same boundary in the background.
    @discardableResult
    func loadSetupStartupState() async -> Bool {
        let startupLifecycle = setupLifecycle.generation
        guard setupLifecycle.isCurrent(startupLifecycle) else { return false }
        bootstrapInputReady = true
        guard workspaceConfigurationIsApplied else {
            githubContextLoaded = false
            return true
        }
        setupQueue.submitWorkspaces(workspaceConfigurations)
        _ = setupQueue.begin(.workspaceRun, revision: setupQueue.revision)
        setupQueue.succeed(.workspaceRun, revision: setupQueue.revision)
        if state.phase == .complete {
            _ = setupQueue.begin(.workspaceVerify, revision: setupQueue.revision)
            setupQueue.succeed(.workspaceVerify, revision: setupQueue.revision)
        }
        workspaceConfigurationAccepted = true
        rebuildWorkspaceScopedState()
        let loaded = await loadPublishedWorkspaceContext(
            workspaceConfigurations,
            generation: githubContextGeneration
        )
        if loaded { restoreCompletedQueueDecisions() }
        return loaded
    }

    private func restoreCompletedQueueDecisions() {
        if githubSkipped {
            setupQueue.submitGitHubSkip()
        } else if githubDecisionMade && verificationAllowsCompletion {
            setupQueue.submitGitHub(.github(retainedRepositoryPolicy))
            if setupQueue.begin(.githubRun, revision: setupQueue.revision) {
                setupQueue.succeed(.githubRun, revision: setupQueue.revision)
                _ = setupQueue.begin(.githubVerify, revision: setupQueue.revision)
                setupQueue.succeed(.githubVerify, revision: setupQueue.revision)
            }
        }
        if identitySkipped {
            setupQueue.submitIdentitySkip()
        } else if identityDecisionMade {
            setupQueue.submitIdentity(SetupIdentityQueueInput(
                name: identityName,
                email: identityEmail,
                target: identityTarget == "all" ? nil : identityTarget
            ))
            if setupQueue.begin(.identityRun, revision: setupQueue.revision) {
                setupQueue.succeed(.identityRun, revision: setupQueue.revision)
                _ = setupQueue.begin(.identityVerify, revision: setupQueue.revision)
                setupQueue.succeed(.identityVerify, revision: setupQueue.revision)
            }
        }
    }

    private func startGitHubContextLoad() {
        let submittedWorkspaceConfigurations = workspaceConfigurations
        cancelGitHubContextLoad()
        let generation = githubContextGeneration
        githubContextTask = Task {
            _ = await loadPublishedWorkspaceContext(
                submittedWorkspaceConfigurations,
                generation: generation
            )
            guard githubContextGeneration == generation else { return }
            githubContextTask = nil
        }
    }

    private func cancelGitHubContextLoad() {
        githubContextGeneration &+= 1
        githubContextTask?.cancel()
        githubContextTask = nil
        githubContextLoaded = false
    }

    /// Loads the selected workspace context for onboarding presentation.
    /// Mutations still wait for bootstrap to publish the verified boundary.
    @discardableResult
    private func loadPublishedWorkspaceContext(
        _ configurations: [SetupWorkspaceConfiguration],
        generation: Int
    ) async -> Bool {
        guard workspaceConfigurationAccepted,
              configurations == workspaceConfigurations,
              githubContextGeneration == generation else {
            githubContextLoaded = false
            return false
        }
        do {
            try await provider?.reloadWorkspaceConfiguration(configurations)
        } catch {
            guard githubContextGeneration == generation else { return false }
            localCatalogIssue = LocalCatalogIssue(kind: .failed, message: error.localizedDescription)
            githubContextLoaded = false
            return false
        }
        guard configurations == workspaceConfigurations,
              githubContextGeneration == generation else { return false }
        await prefillIdentityFromLocalGit()
        guard configurations == workspaceConfigurations,
              githubContextGeneration == generation else { return false }
        let loaded = await loadGitHubStartupContext(generation: generation)
        if loaded {
            // The rebuild above resets repositoryPolicyApplied from the
            // per-session retained policy, which starts empty; re-read the
            // durable intent so a policy completed in an earlier session
            // keeps this step decided instead of dead-ending on a disabled
            // Continue.
            await syncLocalApplyProgress()
        }
        return loaded
    }

    /// The GitHub-context chain. Every awaited publication is guarded against
    /// setup teardown or a newer published workspace configuration.
    @discardableResult
    private func loadGitHubStartupContext(generation: Int) async -> Bool {
        guard workspaceConfigurationAccepted,
              githubContextGeneration == generation else {
            githubContextLoaded = false
            return false
        }
        githubContextLoaded = true
        // Bootstrap published the final workspace boundary. Start the
        // account, repository, and policy read immediately; rendering the
        // GitHub step must never be the trigger.
        loadLocalCatalog()
        return true
    }

    private func loadDependencies() {
        Task {
            if await prepareDependencies() {
                await loadSetupStartupState()
            }
        }
    }

    @discardableResult
    private func prepareDependencies() async -> Bool {
        guard let coordinator else {
            runtimeSetupError = "Silo cannot install its dependencies because the setup service is unavailable."
            isChecking = false
            return false
        }
        let startupLifecycle = setupLifecycle.generation
        runtimeSetupError = nil
        runtimeSetupPhase = .installingRuntime
        checks = []
        lastPreflightAt = nil
        isChecking = true
        do {
            try await coordinator.prepareRuntime { phase in
                Task { @MainActor in
                    guard setupLifecycle.isCurrent(startupLifecycle) else { return }
                    runtimeSetupPhase = phase
                }
            }
            guard setupLifecycle.isCurrent(startupLifecycle) else { return false }
            runtimeSetupPhase = .ready
            await refreshPreflightState()
            return setupLifecycle.isCurrent(startupLifecycle)
        } catch is CancellationError {
            return false
        } catch {
            guard setupLifecycle.isCurrent(startupLifecycle) else { return false }
            runtimeSetupError = error.localizedDescription
            isChecking = false
            return false
        }
    }

    private func refreshPreflightState() async {
        guard let coordinator else { return }
        isChecking = true
        checks = []
        let savedState = await coordinator.state()
        let result = await coordinator.preflight { check in
            Task { @MainActor in self.upsertPreflightCheck(check) }
        }
        state = savedState
        checks = result
        lastPreflightAt = Date()
        isChecking = false
    }

    /// Streams one finished dependency check into the checklist while the
    /// remaining checks are still running.
    private func upsertPreflightCheck(_ check: SiloPreflightCheck) {
        if let index = checks.firstIndex(where: { $0.id == check.id }) {
            checks[index] = check
        } else {
            checks.append(check)
        }
    }

    private func openHostApprovalSettings() {
        guard let coordinator else { return }
        Task { await coordinator.openHostApprovalSettings() }
    }

    private func startWorkspaceRegistration() {
        guard let coordinator else { return }
        guard workspaceValidationMessage == nil else { return }
        let submittedWorkspaceConfigurations = workspaceConfigurations
        if registrationTask != nil {
            return
        }
        guard !canFinishWithoutGitHub else {
            if setupQueue.item(.workspaceRun).input == nil {
                setupQueue.submitWorkspaces(submittedWorkspaceConfigurations)
            }
            setupQueue.succeed(.workspaceRun, revision: setupQueue.revision)
            setupQueue.succeed(.workspaceVerify, revision: setupQueue.revision)
            acceptRegisteredWorkspaceConfiguration(submittedWorkspaceConfigurations)
            return
        }
        beginWorkspaceRegistration(
            submittedWorkspaceConfigurations,
            coordinator: coordinator
        )
    }

    private func beginWorkspaceRegistration(
        _ submittedWorkspaceConfigurations: [SetupWorkspaceConfiguration],
        coordinator: any SiloBootstrapCoordinating
    ) {
        let candidateRevision = setupQueue.revision
        let queueID: SetupQueueItemID = setupQueue.status(of: .workspaceRun) == .succeeded
            ? .workspaceVerify
            : .workspaceRun
        guard setupQueue.begin(queueID, revision: candidateRevision) else { return }
        let queue = setupQueue
        notice = nil
        registrationTask = Task {
            do {
                let result = try await coordinator.run(
                    workspaceConfigurations: submittedWorkspaceConfigurations,
                    onProgress: { event in
                        Task { @MainActor in
                            queue.consume(event, candidateRevision: candidateRevision)
                        }
                    }
                )
                let savedState = await coordinator.state()
                let refreshedChecks = await coordinator.preflight()
                guard candidateRevision == setupQueue.revision else {
                    finishWorkspaceRegistration(coordinator: coordinator)
                    return
                }
                state = savedState
                checks = refreshedChecks
                lastPreflightAt = Date()
                setupQueue.succeed(.workspaceRun, revision: candidateRevision)
                _ = setupQueue.begin(.workspaceVerify, revision: candidateRevision)
                // Approval blockers remain visible through Review. A completed,
                // persisted workspace boundary refreshes later-step context below.
                notice = result.requiresApproval
                    ? (result.phase == SiloBootstrapState.Phase.hostIntegration.rawValue
                        ? "Allow Silo in Login Items, then choose Retry."
                        : result.message)
                    : nil
                if !result.requiresApproval {
                    acceptRegisteredWorkspaceConfiguration(submittedWorkspaceConfigurations)
                    setupQueue.succeed(.workspaceVerify, revision: candidateRevision)
                } else {
                    setupQueue.fail(
                        .workspaceVerify,
                        message: notice ?? result.message,
                        revision: candidateRevision
                    )
                }
            } catch is CancellationError {
                // Reset and teardown intentionally interrupt background registration.
                registrationTask = nil
                return
            } catch let clientError as SiloClientError where clientError == .cancelled {
                // The command runner reports cooperative process cancellation
                // through its typed error rather than Swift CancellationError.
                registrationTask = nil
                return
            } catch let setupError {
                let savedState = await coordinator.state()
                state = savedState
                let failedID = setupQueue.runningItem?.id == .workspaceVerify
                    ? SetupQueueItemID.workspaceVerify
                    : .workspaceRun
                setupQueue.fail(
                    failedID,
                    message: setupError.localizedDescription,
                    revision: candidateRevision
                )
            }
            finishWorkspaceRegistration(coordinator: coordinator)
        }
    }

    private func acceptRegisteredWorkspaceConfiguration(
        _ submittedWorkspaceConfigurations: [SetupWorkspaceConfiguration]
    ) {
        guard submittedWorkspaceConfigurations == workspaceConfigurations,
              Self.workspaceConfigurationIsApplied(
                submittedWorkspaceConfigurations,
                persisted: state.workspaceConfigurations
              ) else { return }
        workspaceConfigurationAccepted = true
        if githubContextLoaded {
            loadLocalCatalog(force: true)
        } else {
            startGitHubContextLoad()
        }
    }

    private func finishWorkspaceRegistration(
        coordinator: any SiloBootstrapCoordinating
    ) {
        registrationTask = nil
        guard case .workspaces(let queued)? = setupQueue.item(.workspaceRun).input,
              setupQueue.status(of: .workspaceRun) == .queued else {
            resumeQueuedSetupWork()
            return
        }
        beginWorkspaceRegistration(queued, coordinator: coordinator)
    }

    private func retrySetupQueue() {
        guard let failedID = setupQueue.retryFailedItem() else { return }
        error = nil
        switch failedID {
        case .workspaceRun, .workspaceVerify:
            startWorkspaceRegistration()
        case .githubRun:
            if setupQueue.item(.githubRun).input == .skipped {
                skipGitHub()
            } else if case .github(let policies)? = setupQueue.item(.githubRun).input {
                commitPolicy(retained: policies)
            } else {
                commitPolicy()
            }
        case .githubVerify:
            retryLocalPolicyApply()
        case .identityRun, .identityVerify:
            if case .identity(let input)? = setupQueue.item(.identityRun).input {
                saveIdentity(retained: input)
            } else {
                saveIdentity()
            }
        case .completion:
            setupQueue.deriveCompletion(requirementsSatisfied: reviewRequirementsSatisfied)
        }
    }

    /// Advances only the next dependency-ready item. Inputs captured by later
    /// setup screens stay in their original queue items across a failed retry.
    private func resumeQueuedSetupWork() {
        setupQueue.settleRetainedDecisions()
        if setupQueue.status(of: .workspaceRun) == .succeeded,
           setupQueue.status(of: .workspaceVerify) == .queued,
           setupQueue.status(of: .githubVerify) == .succeeded,
           registrationTask == nil {
            startWorkspaceRegistration()
            return
        }
        if setupQueue.status(of: .githubRun) == .queued,
           case .some(.github(let policies)) = setupQueue.item(.githubRun).input {
            commitPolicy(retained: policies)
            return
        }
        if setupQueue.status(of: .identityRun) == .queued,
           case .some(.identity(let input)) = setupQueue.item(.identityRun).input {
            saveIdentity(retained: input)
            return
        }
        setupQueue.deriveCompletion(requirementsSatisfied: reviewRequirementsSatisfied)
    }

    private func waitForWorkspaceRegistration(
        _ configurations: [SetupWorkspaceConfiguration]
    ) async -> Bool {
        if Self.workspaceConfigurationIsApplied(
            configurations,
            persisted: state.workspaceConfigurations
        ) { return true }
        guard let registrationTask else { return false }
        await registrationTask.value
        guard !Task.isCancelled else { return false }
        return Self.workspaceConfigurationIsApplied(
            configurations,
            persisted: state.workspaceConfigurations
        )
    }

    private func completeSetup() {
        guard canCompleteReview else { return }
        if !uiTestMode {
            UserDefaults.standard.set(true, forKey: "setupCompleted")
            UserDefaults.standard.removeObject(forKey: Self.resumeStateKey)
        }
        closeSetup(workspaceConfigurations)
    }

    static func allowsIdentitySave(
        clientAvailable: Bool,
        name: String,
        email: String
    ) -> Bool {
        clientAvailable &&
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            email.contains("@") &&
            !email.contains(where: \.isWhitespace)
    }

    private var canSaveIdentity: Bool {
        // Identity input is collected immediately; the save task waits for the
        // verified workspace boundary before mutating guest configuration.
        (uiTestMode || provider != nil) &&
            !identityName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            identityEmail.contains("@") &&
            !identityEmail.contains(where: \.isWhitespace)
    }

    private func saveIdentity(retained: SetupIdentityQueueInput? = nil) {
        guard retained != nil || canSaveIdentity else {
            identityStatus = "Enter a name and a valid email, then save."
            return
        }
        isSavingIdentity = true
        identitySkipped = false
        identityStatus = "Saving your name and email…"
        let input = retained ?? SetupIdentityQueueInput(
            name: identityName.trimmingCharacters(in: .whitespacesAndNewlines),
            email: identityEmail.trimmingCharacters(in: .whitespacesAndNewlines),
            target: identityTarget == "all" ? nil : identityTarget
        )
        let name = input.name
        let email = input.email
        let target = input.target
        setupQueue.submitIdentity(input)
        if uiTestMode {
            guard setupQueue.begin(.identityRun, revision: setupQueue.revision) else {
                isSavingIdentity = false
                activeStep = .review
                return
            }
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    let workspaces = target.map { [$0] } ?? configuredWorkspaceNames
                    let savedIdentity = SetupVerifiedIdentity(name: name, email: email)
                    for workspace in workspaces {
                        verifiedIdentityByWorkspace[workspace] = savedIdentity
                    }
                    identityConfiguredWorkspaces.formUnion(workspaces)
                    setupQueue.succeed(.identityRun, revision: setupQueue.revision)
                    _ = setupQueue.begin(.identityVerify, revision: setupQueue.revision)
                    setupQueue.succeed(.identityVerify, revision: setupQueue.revision)
                    isSavingIdentity = false
                    identityStatus = "Saved \(name) <\(email)> for \(workspaces.joined(separator: ", "))."
                    setupQueue.deriveCompletion(requirementsSatisfied: reviewRequirementsSatisfied)
                    activeStep = .review
                }
            }
            return
        }
        // Navigation never waits on the save. Review renders immediately while
        // this task persists identity into the configured workspaces.
        activeStep = .review
        identitySaveTask?.cancel()
        identitySaveTask = Task {
            if !canFinishWithoutGitHub, let registrationTask {
                await registrationTask.value
            }
            guard !Task.isCancelled else { return }
            guard canFinishWithoutGitHub else {
                isSavingIdentity = false
                identitySaveTask = nil
                identityStatus = "Workspace setup did not finish, so your name and email were not saved. Finish workspace setup, then save again."
                return
            }
            guard setupQueue.begin(.identityRun, revision: setupQueue.revision) else {
                isSavingIdentity = false
                identitySaveTask = nil
                return
            }
            do {
                guard let provider else {
                    throw SiloClientError.invalidExecutable
                }
                let result = try await provider.setIdentity(name: name, email: email, workspace: target)
                try Task.checkCancellation()
                await MainActor.run {
                    let verified = SetupVerifiedIdentity(name: name, email: email)
                    for workspace in result.workspaces {
                        verifiedIdentityByWorkspace[workspace] = verified
                    }
                    identityConfiguredWorkspaces.formUnion(result.workspaces)
                    setupQueue.succeed(.identityRun, revision: setupQueue.revision)
                    _ = setupQueue.begin(.identityVerify, revision: setupQueue.revision)
                    setupQueue.succeed(.identityVerify, revision: setupQueue.revision)
                    isSavingIdentity = false
                    identitySaveTask = nil
                    identityStatus = "Saved \(result.name) <\(result.email)> for \(result.workspaces.joined(separator: ", "))."
                    setupQueue.deriveCompletion(requirementsSatisfied: reviewRequirementsSatisfied)
                }
            } catch is CancellationError {
                // Setup teardown owns cancellation; publish nothing after the
                // window disappears.
            } catch {
                await MainActor.run {
                    isSavingIdentity = false
                    identitySaveTask = nil
                    identityStatus = "Your name and email were not changed: \(error.localizedDescription) Try again after workspace setup is available."
                    let failedID = setupQueue.runningItem?.id == .identityVerify
                        ? SetupQueueItemID.identityVerify
                        : .identityRun
                    setupQueue.fail(failedID, message: error.localizedDescription)
                }
            }
        }
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
    }

    private func prefillIdentity(from account: GitHubAccount) {
        if !identityNameWasEdited, identityName.isEmpty, let name = account.name, !name.isEmpty {
            identityName = name
        }
        if !identityEmailWasEdited, identityEmail.isEmpty, let email = account.email, !email.isEmpty {
            identityEmail = email
        }
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
            workspaceConfigurations: workspaceConfigurations,
            repositoryPolicy: workspacePolicy,
            repositoryPolicyApplied: repositoryPolicyApplied,
            githubSkipped: githubSkipped,
            identityName: identityName,
            identityEmail: identityEmail,
            identityTarget: identityTarget,
            identityConfiguredWorkspaces: identityConfiguredWorkspaces,
            identitySkipped: identitySkipped,
            verifiedIdentityByWorkspace: verifiedIdentityByWorkspace
        )
        guard let data = try? JSONEncoder().encode(resume) else { return }
        UserDefaults.standard.set(data, forKey: Self.resumeStateKey)
    }

    /// Live hint for the Workspaces step: tracks the draft names against what
    /// is installed on this Mac so the administrator prompt at save is never
    /// a surprise. Apply-time verification stays authoritative.
    private func refreshWorkspaceNameApprovalHint() {
        guard let coordinator else { return }
        let configurations = workspaceConfigurations
        Task {
            let needed = await coordinator.workspaceNamesNeedApproval(
                workspaceConfigurations: configurations
            )
            workspaceNamesNeedApproval = needed
        }
    }

    private func restoreResumeState() {
        guard let data = UserDefaults.standard.data(forKey: Self.resumeStateKey),
              let resume = try? JSONDecoder().decode(SetupResumeState.self, from: data) else {
            workspaceConfigurations = BootstrapStateStore.persistedWorkspaceConfigurations()
            drafts = SetupWorkspaceConfiguration.initialRepositoryDrafts(for: workspaceConfigurations)
            return
        }
        retainedRepositoryPolicy = resume.repositoryPolicy
        workspaceConfigurations = resume.workspaceConfigurations ?? SetupWorkspaceConfiguration.defaults
        drafts = SetupWorkspaceConfiguration.initialRepositoryDrafts(for: workspaceConfigurations)
        editedGitHubWorkspaces = Set(resume.repositoryPolicy.map(\.workspace))
        repositoryPolicyApplied = resume.repositoryPolicyApplied
        for policy in resume.repositoryPolicy {
            guard configuredWorkspaceNames.contains(policy.workspace) else { continue }
            var draft = drafts[policy.workspace] ?? .initial(policy.workspace)
            draft.repositoryModes = Dictionary(
                uniqueKeysWithValues: policy.repositories.map {
                    (GitHubProvider.canonicalize($0.fullName), $0.mode)
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
    }
    private func loadUITestState() {
        let now = Date()
        checks = [
            SiloPreflightCheck(id: "macos-version", title: "macOS 26 or later", status: .pass, detail: "Detected macOS 26.", remediation: nil),
            SiloPreflightCheck(id: "architecture", title: "Apple Silicon", status: .pass, detail: "Detected arm64.", remediation: nil),
            SiloPreflightCheck(id: "disk-space", title: "Available disk space", status: .pass, detail: "128 GiB available; setup estimates at least 20 GiB.", remediation: nil),
            SiloPreflightCheck(id: "memory", title: "Memory budget", status: .pass, detail: "Detected 64 GiB physical memory.", remediation: nil)
        ]
        state = SiloBootstrapState(
            phase: .complete,
            startedAt: now,
            updatedAt: now,
            lastError: nil,
            completedPhases: Set(SiloBootstrapState.Phase.allCases),
            workspaceConfigurations: workspaceConfigurations
        )
        lastPreflightAt = now
        isChecking = false
        runtimeSetupPhase = .ready
        runtimeSetupError = nil
        bootstrapInputReady = true
        if uiTestStartsInReview {
            setupQueue.submitWorkspaces(workspaceConfigurations)
            _ = setupQueue.begin(.workspaceRun, revision: setupQueue.revision)
            setupQueue.succeed(.workspaceRun, revision: setupQueue.revision)
            _ = setupQueue.begin(.workspaceVerify, revision: setupQueue.revision)
            setupQueue.succeed(.workspaceVerify, revision: setupQueue.revision)
            workspaceConfigurationAccepted = true
            githubSkipped = true
            setupQueue.submitGitHubSkip()
            identitySkipped = true
            setupQueue.submitIdentitySkip()
            identityStatus = ""
            githubStatus = "GitHub access skipped by choice. You can connect later from Settings."
            activeStep = .review
        } else {
            githubSkipped = false
            identitySkipped = false
            identityStatus = ""
            activeStep = .dependencies
        }
        githubContextLoaded = true
    }


    private func guidance(for phase: SiloBootstrapState.Phase) -> String {
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

    private func phaseIsComplete(_ phase: SiloBootstrapState.Phase) -> Bool {
        switch phase {
        case .github: return githubDecisionMade && verificationAllowsCompletion
        case .identity: return identityDecisionMade
        case .complete: return false
        default: return state.completedPhases.contains(phase)
        }
    }

    private func phaseIsCurrent(_ phase: SiloBootstrapState.Phase) -> Bool {
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

    private func label(for phase: SiloBootstrapState.Phase) -> String {
        switch phase {
        case .welcome: return "Welcome"
        case .preflight: return "Requirements"
        case .toolchain: return "Tools"
        case .hostIntegration: return "System access"
        case .workspaces: return "Workspaces"
        case .github: return "GitHub"
        case .identity: return "Git"
        case .complete: return "Final review"
        }
    }

    private func statusLabel(for status: SiloPreflightCheck.Status) -> String {
        switch status {
        case .pass: return "Ready"
        case .needsAction: return "Needs attention"
        case .unavailable: return "Unavailable"
        }
    }

    private func symbol(for status: SiloPreflightCheck.Status) -> String {
        switch status {
        case .pass: return "checkmark.circle.fill"
        case .needsAction: return "exclamationmark.triangle.fill"
        case .unavailable: return "xmark.octagon.fill"
        }
    }

    private func color(for status: SiloPreflightCheck.Status) -> Color {
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
struct RepositoryWorkspacePolicyEditor: View {
    let workspaces: [String]
    let owners: [GitHubOwner]
    let repositoriesByOwner: [Int: [GitHubRepository]]
    @Binding var drafts: [String: WorkspaceRepositoryDraft]
    @Binding var editedWorkspaces: Set<String>
    let disabled: Bool
    let onEdit: () -> Void
    var showsHeading = true
    var highlightsEdits = false
    var usesContainerBackground = true
    private static let workspaceAccessHelp = "Choose which repositories each workspace can use with your GitHub credentials, and whether it can push changes. Public repositories remain cloneable without granting access."
    private static let pushHelp = "Push to GitHub from inside this workspace's VM. You can always push from outside the VM using Silo."
    private static let pushDeniedHelp = "GitHub does not grant push access to this repository. Neither the VM nor Silo can push until that access changes."
    @State private var openPicker: String?
    @State private var searchQueries: [String: String] = [:]

    private var sortedOwners: [GitHubOwner] {
        owners.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsHeading {
                HStack(spacing: 5) {
                    Text("Workspace Access").font(.headline)
                    InformationTooltip(
                        text: Self.workspaceAccessHelp,
                        accessibilityLabel: "Workspace Access information",
                        accessibilityIdentifier: "setup.github.workspace-access.info"
                    )
                }
            }
            ForEach(workspaces, id: \.self) { workspace in
                workspaceSection(workspace)
            }
        }
        .padding(usesContainerBackground ? 10 : 0)
        .background(
            usesContainerBackground ? Color(nsColor: .controlBackgroundColor) : .clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func workspaceSection(_ workspace: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(workspace).font(.callout.weight(.semibold))
                Spacer()
                if highlightsEdits, editedWorkspaces.contains(workspace) {
                    Text("Unsaved")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                Button {
                    searchQueries[workspace] = ""
                    openPicker = workspace
                } label: {
                    Label(selectionTitle(for: workspace), systemImage: "chevron.up.chevron.down")
                        .frame(width: 142, alignment: .leading)
                }
                .disabled(disabled)
                .accessibilityLabel("Choose repositories for \(workspace)")
                .accessibilityValue(selectionTitle(for: workspace))
                .accessibilityIdentifier("github.workspace.\(workspace).repository-picker.button")
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
                                owner: selection.owner
                            )
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 9))
    }

    @ViewBuilder
    private func repositoryPicker(for workspace: String) -> some View {
        let matches = filteredRepositories(for: workspace)
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search repositories", text: searchBinding(for: workspace))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("github.workspace.\(workspace).repository-picker.search")
            if matches.isEmpty {
                Text(searchQueries[workspace, default: ""].isEmpty
                    ? "No repositories" : "No matches")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityIdentifier("github.workspace.\(workspace).repository-picker.empty")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(matches, id: \.repository.id) { entry in
                            Toggle(entry.repository.fullName, isOn: selectionBinding(
                                workspace,
                                repository: entry.repository,
                                owner: entry.owner
                            ))
                            .toggleStyle(.checkbox)
                            .padding(.vertical, 4)
                            .disabled(disabled)
                            .accessibilityIdentifier("github.workspace.\(workspace).repository.\(entry.repository.id)")
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
        _ workspace: String,
        repository: GitHubRepository,
        owner: GitHubOwner
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
                owner: owner
            ))
            .toggleStyle(.switch)
            .accessibilityLabel("Allow pushes")
            .controlSize(.small)
            .disabled(disabled || repository.canPush == false)
            .help(repository.canPush == false ? Self.pushDeniedHelp : Self.pushHelp)
            .accessibilityIdentifier("github.workspace.\(workspace).repository.\(repository.id).allow-pushes")
        }
        .padding(.leading, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("github.workspace.\(workspace).selection.\(repository.id)")
    }

    private typealias RepositoryEntry = (repository: GitHubRepository, owner: GitHubOwner)

    private var allRepositories: [RepositoryEntry] {
        sortedOwners.flatMap { owner in
            (repositoriesByOwner[owner.id] ?? []).map { ($0, owner) }
        }.sorted {
            $0.repository.fullName.localizedCaseInsensitiveCompare($1.repository.fullName) == .orderedAscending
        }
    }

    private func filteredRepositories(for workspace: String) -> [RepositoryEntry] {
        let query = searchQueries[workspace, default: ""]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = query.isEmpty
            ? allRepositories
            : allRepositories.filter { $0.repository.fullName.localizedCaseInsensitiveContains(query) }
        return Self.selectedFirst(matches) {
            isSelected(workspace, repository: $0.repository, owner: $0.owner)
        }
    }

    static func selectedFirst<Value>(
        _ values: [Value],
        isSelected: (Value) -> Bool
    ) -> [Value] {
        var selected: [Value] = []
        var unselected: [Value] = []
        selected.reserveCapacity(values.count)
        unselected.reserveCapacity(values.count)
        for value in values {
            if isSelected(value) {
                selected.append(value)
            } else {
                unselected.append(value)
            }
        }
        selected.append(contentsOf: unselected)
        return selected
    }

    private func selectedRepositories(for workspace: String) -> [RepositoryEntry] {
        allRepositories.filter { isSelected(workspace, repository: $0.repository, owner: $0.owner) }
    }

    private func selectionTitle(for workspace: String) -> String {
        let count = selectedRepositories(for: workspace).count
        return count == 0 ? "Choose repositories" : "\(count) selected"
    }

    private func pickerPresented(for workspace: String) -> Binding<Bool> {
        Binding(
            get: { openPicker == workspace },
            set: { if !$0 { openPicker = nil } }
        )
    }

    private func searchBinding(for workspace: String) -> Binding<String> {
        Binding(
            get: { searchQueries[workspace, default: ""] },
            set: { searchQueries[workspace] = $0 }
        )
    }

    private static func canonicalKey(_ repository: GitHubRepository) -> String {
        GitHubProvider.canonicalize(repository.fullName)
    }

    private func isSelected(
        _ workspace: String,
        repository: GitHubRepository,
        owner _: GitHubOwner
    ) -> Bool {
        let draft = drafts[workspace] ?? .initial(workspace)
        return draft.repositoryModes[Self.canonicalKey(repository)] != nil
    }

    private func selectionBinding(
        _ workspace: String,
        repository: GitHubRepository,
        owner: GitHubOwner
    ) -> Binding<Bool> {
        Binding(
            get: { isSelected(workspace, repository: repository, owner: owner) },
            set: { selected in
                var draft = drafts[workspace] ?? .initial(workspace)
                if selected {
                    draft.repositoryModes[Self.canonicalKey(repository)] = .readOnly
                } else {
                    draft.repositoryModes.removeValue(forKey: Self.canonicalKey(repository))
                }
                drafts[workspace] = draft
                editedWorkspaces.insert(workspace)
                onEdit()
            }
        )
    }

    private func pushBinding(
        _ workspace: String,
        repository: GitHubRepository,
        owner: GitHubOwner
    ) -> Binding<Bool> {
        Binding(
            get: {
                guard isSelected(workspace, repository: repository, owner: owner) else { return false }
                let mode = drafts[workspace]?.repositoryModes[Self.canonicalKey(repository)] ?? .readOnly
                return repository.effectiveMode(mode) == .readWrite
            },
            set: { allowsPushes in
                guard var draft = drafts[workspace],
                      draft.repositoryModes[Self.canonicalKey(repository)] != nil,
                      repository.canPush != false else { return }
                draft.repositoryModes[Self.canonicalKey(repository)] = allowsPushes ? .readWrite : .readOnly
                drafts[workspace] = draft
                editedWorkspaces.insert(workspace)
                onEdit()
            }
        )
    }
}
