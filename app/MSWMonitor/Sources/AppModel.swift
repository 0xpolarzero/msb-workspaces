import AppKit
import Observation

struct Workspace: Identifiable, Equatable, Sendable {
    enum ID: String, CaseIterable, Sendable {
        case dev
        case playgrounds
        case personal
    }

    enum State: String, Equatable, Sendable {
        case running = "Running"
        case stopped = "Stopped"
        case starting = "Starting"
        case stopping = "Stopping"
        case restarting = "Restarting"
        case exited = "Exited"
        case unavailable = "Unavailable"
        case unknown = "Unknown"
        case quarantined = "Quarantined"
    }

    enum CredentialState: String, Equatable, Sendable {
        case unconfigured = "Unconfigured"
        case legacy = "Legacy"
        case ready = "Ready"
        case expiring = "Expiring"
        case needsRestart = "Needs restart"
        case needsAuthorization = "Needs authorization"
        case serviceUnavailable = "Service unavailable"
        case readOnly = "Read-only"
        case removalPending = "Removal pending"
        case quarantined = "Quarantined"
    }

    let id: ID
    let purpose: String
    var state: State
    var credential: CredentialState
    var freshness: MSWFreshness
    var observedAt: Date?
    var networkHost: String?
    var quarantineReason: String?
    var nextAction: String
    var canStart: Bool
    var canStop: Bool
    var canRestart: Bool

    init(
        id: ID,
        purpose: String? = nil,
        state: State = .stopped,
        credential: CredentialState = .unconfigured,
        freshness: MSWFreshness = .neverObserved,
        observedAt: Date? = nil,
        networkHost: String? = nil,
        quarantineReason: String? = nil,
        nextAction: String? = nil,
        canStart: Bool = true,
        canStop: Bool = false,
        canRestart: Bool = false
    ) {
        self.id = id
        self.purpose = purpose ?? Self.defaultPurpose(for: id)
        self.state = state
        self.credential = credential
        self.freshness = freshness
        self.observedAt = observedAt
        self.networkHost = networkHost
        self.quarantineReason = quarantineReason
        self.nextAction = nextAction ?? (state == .running ? "Open Terminal" : "Start")
        self.canStart = canStart
        self.canStop = canStop
        self.canRestart = canRestart
    }

    private static func defaultPurpose(for id: ID) -> String {
        switch id {
        case .dev: return "Primary software development workspace"
        case .playgrounds: return "Experiments and disposable prototypes"
        case .personal: return "Personal projects and services"
        }
    }
}

@Observable
@MainActor
final class AppModel {
    private(set) var workspaces: [Workspace]
    private(set) var observationCount = 0
    private(set) var lastObservedAt: Date?
    private(set) var isRefreshing = false
    private(set) var lastError: String?
    private(set) var activities: [MSWActivity] = []
    private(set) var setupState: MSWBootstrapState = .initial
    private(set) var metricsByWorkspace: [String: MSWMetricsResponse] = [:]
    private(set) var repositoriesByWorkspace: [String: MSWRepositoriesResponse] = [:]
    private(set) var portsSnapshot: MSWPortsResponse?
    private(set) var githubSnapshot: MSWGitHubStateResponse?
    private(set) var detailError: String?
    private(set) var isDetailLoading = false
    private(set) var logsByWorkspace: [String: MSWLogsResponse] = [:]
    private(set) var diagnosticChecks: [MSWDiagnosticCheck] = []
    private(set) var backupResult: MSWBackupResult?
    private(set) var maintenanceMessage: String?
    var selectedWorkspace: Workspace.ID?
    private(set) var pendingLifecyclePlan: MSWLifecyclePlan?
    private(set) var pendingLifecycleAction: MSWLifecycleAction?
    private(set) var pendingLifecycleWorkspace: Workspace.ID?
    private(set) var pendingPushPlan: MSWPushPlan?
    private enum SafetyAction {
        case lifecycle(MSWLifecycleAction)
        case terminal
        case zed
        case site
        case push

        var allowsQuarantine: Bool {
            switch self {
            case .lifecycle(let action):
                return action.rawValue == MSWLifecycleAction.stop.rawValue
            case .terminal, .zed, .site, .push:
                return false
            }
        }
    }

    private var pendingLifecycleOriginalState: Workspace.State?
    private let client: MSWClient?
    private let operationCoordinator: MSWOperationCoordinator?
    private let operationService: MSWOperationService?
    private let diagnostics: MSWDiagnostics?
    private let activityStore: MSWActivityStore
    private var refreshTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var refreshInFlight = 0


    init(
        client: MSWClient? = nil,
        operationCoordinator: MSWOperationCoordinator? = nil,
        operationService: MSWOperationService? = nil,
        diagnostics: MSWDiagnostics? = nil,
        activityStore: MSWActivityStore = MSWActivityStore()
    ) {
        self.client = client
        self.operationCoordinator = operationCoordinator
        self.operationService = operationService
        self.diagnostics = diagnostics
        self.activityStore = activityStore
        let fixtureMode = client == nil
        workspaces = Workspace.ID.allCases.map {
            fixtureMode
                ? Workspace(id: $0)
                : Workspace(id: $0, state: .unknown, freshness: .unavailable, nextAction: "Set up", canStart: false, canStop: false, canRestart: false)
        }
    }


    var observationText: String {
        observationCount == 0 ? "Not yet refreshed" : "Observation #\(observationCount)"
    }

    var aggregateText: String {
        if isRefreshing { return "Refreshing…" }
        if workspaces.contains(where: { $0.state == .quarantined }) { return "Action required" }
        if lastError != nil { return "Needs attention" }
        return "Ready"
    }

    var aggregateDetail: String {
        guard let lastObservedAt else { return "No state observation yet" }
        return "Observed \(lastObservedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    func refresh() {
        observationCount += 1
        guard client != nil else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.refreshRemote(generation: generation)
        }
    }

    func setPollingVisible(_ visible: Bool) {
        pollingTask?.cancel()
        pollingTask = nil
        guard client != nil else { return }
        let configuredCadence = UserDefaults.standard.double(forKey: "pollingCadence")
        let hiddenCadence = configuredCadence > 0 ? min(max(configuredCadence, 15), 60) : 30
        let interval: Duration = visible ? .seconds(5) : .seconds(hiddenCadence)
        pollingTask = Task { [weak self] in
            await self?.refreshRemote()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                await self?.refreshRemote()
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func openTerminal(for id: Workspace.ID) {
        guard requireActionSafety(for: id, action: .terminal, operation: "Open Terminal") else { return }
        guard let workspace = workspaces.first(where: { $0.id == id }),
              workspace.state == .running else {
            lastError = "Open Terminal requires a freshly observed running workspace."
            return
        }
        guard let client else {
            lastError = "MSW is unavailable in fixture mode."
            return
        }
        Task { [weak self] in
            guard let executable = await client.executableURL() else {
                self?.lastError = "The MSW executable is unavailable. Repair the toolchain and retry."
                return
            }
            guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") else {
                self?.lastError = "Ghostty is not installed."
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.arguments = ["-e", executable.path, id.rawValue]
            NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { [weak self] _, error in
                Task { @MainActor in
                    if let error {
                        self?.lastError = "Could not open Ghostty: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    func openZed(for id: Workspace.ID) {
        guard requireActionSafety(for: id, action: .zed, operation: "Open in Zed") else { return }
        guard let workspace = workspaces.first(where: { $0.id == id }),
              workspace.state == .running else {
            lastError = "Open in Zed requires a freshly observed running workspace."
            return
        }
        guard let client else {
            lastError = "MSW is unavailable in fixture mode."
            return
        }
        Task { [weak self] in
            do {
                try await client.openInZed(workspace: id.rawValue)
            } catch {
                self?.lastError = "Could not open Zed: \(error.localizedDescription)"
            }
        }
    }

    func openSite(for id: Workspace.ID, port: String = "3000") {
        guard requireActionSafety(for: id, action: .site, operation: "Open Site") else { return }
        guard let workspace = workspaces.first(where: { $0.id == id }),
              workspace.state == .running,
              let expectedHost = workspace.networkHost else {
            lastError = "Open Site requires a freshly observed running workspace."
            return
        }
        guard let client else {
            lastError = "MSW is unavailable in fixture mode."
            return
        }
        Task { [weak self] in
            do {
                let envelope = try await client.url(workspace: id.rawValue, port: port)
                guard let result = envelope.result,
                      let url = Self.validatedWorkspaceURL(
                        result.url,
                        expectedWorkspace: id.rawValue,
                        responseWorkspace: result.workspace,
                        expectedHost: expectedHost,
                        expectedPort: port,
                        expectedScheme: "http"
                      ) else {
                    throw MSWClientError.malformedJSON(command: "url")
                }
                guard NSWorkspace.shared.open(url) else {
                    throw MSWClientError.unavailable("macOS could not open the validated workspace URL.")
                }
            } catch {
                self?.lastError = error.localizedDescription
            }
        }
    }


    func refreshRemote() async {
        guard client != nil else { return }
        refreshGeneration += 1
        await refreshRemote(generation: refreshGeneration)
    }

    private func refreshRemote(generation: Int) async {
        guard let client else { return }
        refreshInFlight += 1
        isRefreshing = true
        lastError = nil
        defer {
            refreshInFlight -= 1
            if refreshInFlight == 0 {
                isRefreshing = false
            }
        }
        do {
            let response = try await client.state()
            guard generation == refreshGeneration else { return }
            guard let state = response.result else { throw MSWClientError.missingResult(command: "state") }
            apply(state: state, observedAt: response.observedAt)
            let activity = MSWActivity(
                id: UUID(), createdAt: Date(), kind: .observation, title: "State refreshed",
                detail: "MSW returned a state snapshot for \(state.workspaces.count) workspaces.",
                workspace: nil, isFailure: false
            )
            await append(activity)
        } catch {
            guard generation == refreshGeneration else { return }
            markStateStale()
            lastError = error.localizedDescription
            let activity = MSWActivity(
                id: UUID(), createdAt: Date(), kind: .failure, title: "Refresh failed",
                detail: error.localizedDescription, workspace: nil, isFailure: true
            )
            await append(activity)
        }
    }

    func start(_ id: Workspace.ID) {
        runLifecycle(.start, id: id)
    }

    func stop(_ id: Workspace.ID) {
        runLifecycle(.stop, id: id)
    }

    func restart(_ id: Workspace.ID) {
        runLifecycle(.restart, id: id)
    }

    func confirmPendingLifecycle() {
        guard let action = pendingLifecycleAction,
              let workspace = pendingLifecycleWorkspace,
              let plan = pendingLifecyclePlan else { return }
        guard plan.workspace == workspace.rawValue,
              plan.action == action.rawValue,
              requireActionSafety(for: workspace, action: .lifecycle(action), operation: action.rawValue.capitalized) else {
            cancelPendingLifecycle()
            return
        }
        pendingLifecycleAction = nil
        pendingLifecycleWorkspace = nil
        pendingLifecyclePlan = nil
        runLifecycle(action, id: workspace, confirmation: plan.confirmationPhrase, reviewedPlan: plan)
    }

    func cancelPendingLifecycle() {
        if let workspace = pendingLifecycleWorkspace,
           let originalState = pendingLifecycleOriginalState {
            updateState(workspace, to: originalState)
        }
        clearPendingLifecyclePlan()
    }

    private func clearPendingLifecyclePlan() {
        pendingLifecycleOriginalState = nil
        pendingLifecycleAction = nil
        pendingLifecycleWorkspace = nil
        pendingLifecyclePlan = nil
    }

    func loadMetrics(for id: Workspace.ID) {
        guard let operationService else { detailError = "MSW metrics are unavailable in fixture mode."; return }
        isDetailLoading = true
        detailError = nil
        Task { [weak self] in
            do {
                let result = try await operationService.metrics(workspace: id.rawValue)
                self?.metricsByWorkspace[id.rawValue] = result
            } catch {
                self?.detailError = error.localizedDescription
            }
            self?.isDetailLoading = false
        }
    }

    func loadRepositories(for id: Workspace.ID) {
        guard let operationService else { detailError = "Repository inspection is unavailable in fixture mode."; return }
        isDetailLoading = true
        detailError = nil
        Task { [weak self] in
            do {
                let result = try await operationService.repositories(workspace: id.rawValue)
                self?.repositoriesByWorkspace[id.rawValue] = result
            } catch {
                self?.detailError = error.localizedDescription
            }
            self?.isDetailLoading = false
        }
    }

    func reviewPush(for repository: MSWRepositorySnapshot, workspace id: Workspace.ID) {
        guard let operationService else {
            detailError = "Repository pushes are unavailable in fixture mode."
            return
        }
        guard requireActionSafety(for: id, action: .push, operation: "Push", detail: true) else { return }
        isDetailLoading = true
        detailError = nil
        Task { [weak self] in
            do {
                let plan = try await operationService.pushPlan(
                    workspace: id.rawValue,
                    repositories: [repository.path]
                )
                guard let self else { return }
                guard self.requireActionSafety(for: id, action: .push, operation: "Push", detail: true) else {
                    self.isDetailLoading = false
                    return
                }
                self.pendingPushPlan = plan
            } catch {
                self?.detailError = error.localizedDescription
            }
            self?.isDetailLoading = false
        }
    }

    func confirmPendingPush(confirmation: String) {
        guard let operationService, let plan = pendingPushPlan else { return }
        guard let workspace = Workspace.ID(rawValue: plan.workspace) else {
            detailError = "The pending push workspace is invalid."
            pendingPushPlan = nil
            return
        }
        guard requireActionSafety(for: workspace, action: .push, operation: "Push", detail: true) else {
            pendingPushPlan = nil
            return
        }
        guard confirmation == plan.confirmationPhrase else {
            detailError = "Type the exact confirmation phrase before pushing."
            return
        }
        pendingPushPlan = nil
        isDetailLoading = true
        detailError = nil
        Task { [weak self] in
            guard let self else { return }
            guard self.requireActionSafety(for: workspace, action: .push, operation: "Push", detail: true) else {
                self.isDetailLoading = false
                return
            }
            do {
                let result = try await operationService.applyPushPlan(plan, confirmation: confirmation)
                self.maintenanceMessage = "Pushed \(result.repositoryPath) from \(result.workspace)."
                self.loadRepositories(for: workspace)
                await self.refreshRemote()
            } catch {
                self.detailError = error.localizedDescription
                self.isDetailLoading = false
            }
        }
    }

    func cancelPendingPush() {
        pendingPushPlan = nil
    }

    func loadPorts() {
        guard let operationService else { detailError = "Port inspection is unavailable in fixture mode."; return }
        isDetailLoading = true
        detailError = nil
        Task { [weak self] in
            do {
                self?.portsSnapshot = try await operationService.ports()
            } catch {
                self?.detailError = error.localizedDescription
            }
            self?.isDetailLoading = false
        }
    }

    func loadGitHubState() {
        guard let operationService else { detailError = "GitHub state is unavailable in fixture mode."; return }
        isDetailLoading = true
        detailError = nil
        Task { [weak self] in
            do {
                self?.githubSnapshot = try await operationService.githubState()
            } catch {
                self?.detailError = error.localizedDescription
            }
            self?.isDetailLoading = false
        }
    }

    func loadLogs(for id: Workspace.ID) {
        guard let operationService else {
            detailError = "MSW logs are unavailable in fixture mode."
            return
        }
        isDetailLoading = true
        detailError = nil
        Task { [weak self] in
            do {
                let result = try await operationService.logs(workspace: id.rawValue)
                self?.logsByWorkspace[id.rawValue] = result
            } catch {
                self?.detailError = error.localizedDescription
            }
            self?.isDetailLoading = false
        }
    }

    func runDiagnostics() {
        guard let diagnostics else {
            detailError = "Diagnostics are unavailable in fixture mode."
            return
        }
        isDetailLoading = true
        detailError = nil
        Task { [weak self] in
            let result = await diagnostics.checks()
            self?.diagnosticChecks = result
            self?.isDetailLoading = false
        }
    }

    func createBackup(to directory: URL) {
        guard let diagnostics else {
            detailError = "Backups are unavailable in fixture mode."
            return
        }
        isDetailLoading = true
        detailError = nil
        Task { [weak self] in
            do {
                let result = try await diagnostics.backup(to: directory)
                self?.backupResult = result
                self?.maintenanceMessage = "Backup created at \(result.archive.lastPathComponent)."
            } catch {
                self?.detailError = error.localizedDescription
            }
            self?.isDetailLoading = false
        }
    }

    func restoreBackup(archive: URL, confirmation: String) {
        guard let diagnostics else {
            detailError = "Restore is unavailable in fixture mode."
            return
        }
        guard confirmation == "RESTORE" else {
            detailError = "Type RESTORE exactly before replacing workspace state."
            return
        }
        isDetailLoading = true
        detailError = nil
        Task { [weak self] in
            do {
                try await diagnostics.restore(archive: archive, confirmation: confirmation)
                self?.maintenanceMessage = "Restore completed. Refreshing workspace state."
                await self?.refreshRemote()
            } catch {
                self?.detailError = error.localizedDescription
            }
            self?.isDetailLoading = false
        }
    }

    func clearDetailError() { detailError = nil }

    nonisolated static func validatedWorkspaceURL(
        _ raw: String,
        expectedWorkspace: String,
        responseWorkspace: String,
        expectedHost: String,
        expectedPort: String,
        expectedScheme: String
    ) -> URL? {
        guard responseWorkspace == expectedWorkspace,
              !expectedHost.isEmpty,
              let expectedPortNumber = Int(expectedPort),
              let components = URLComponents(string: raw),
              components.scheme?.lowercased() == expectedScheme,
              let host = components.host,
              host.compare(expectedHost, options: .caseInsensitive) == .orderedSame,
              components.user == nil, components.password == nil,
              components.port == expectedPortNumber,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            return nil
        }
        return components.url
    }

    private func isActionSafe(for id: Workspace.ID, action: SafetyAction) -> Bool {
        guard let workspace = workspaces.first(where: { $0.id == id }) else { return false }
        return isActionSafe(for: workspace, action: action)
    }

    private func isActionSafe(for workspace: Workspace, action: SafetyAction) -> Bool {
        guard workspace.freshness == .fresh,
              workspace.state != .unknown,
              workspace.state != .unavailable else {
            return false
        }
        if action.allowsQuarantine {
            return true
        }
        return workspace.state != .quarantined &&
            workspace.credential != .quarantined
    }

    @discardableResult
    private func requireActionSafety(
        for id: Workspace.ID,
        action: SafetyAction,
        operation: String,
        detail: Bool = false
    ) -> Bool {
        guard isActionSafe(for: id, action: action) else {
            let requirement = action.allowsQuarantine
                ? "fresh, known"
                : "fresh, known, quarantine-clear"
            let message = "\(operation) is blocked until \(id.rawValue) has a \(requirement) observation."
            if detail {
                detailError = message
            } else {
                lastError = message
            }
            return false
        }
        return true
    }

    private func invalidatePendingPlansIfUnsafe() {
        if let workspace = pendingLifecycleWorkspace {
            let lifecycleIsSafe = pendingLifecycleAction.map {
                isActionSafe(for: workspace, action: .lifecycle($0))
            } ?? false
            if !lifecycleIsSafe {
                let action = pendingLifecycleAction?.rawValue.capitalized ?? "Lifecycle"
                clearPendingLifecyclePlan()
                lastError = "Pending \(action.lowercased()) confirmation was cancelled because \(workspace.rawValue) is no longer fresh and quarantine-clear."
            }
        }

        if let plan = pendingPushPlan {
            guard let workspace = Workspace.ID(rawValue: plan.workspace) else {
                pendingPushPlan = nil
                detailError = "Pending push confirmation was cancelled because its workspace is invalid."
                return
            }
            if !isActionSafe(for: workspace, action: .push) {
                pendingPushPlan = nil
                detailError = "Pending push confirmation was cancelled because \(workspace.rawValue) is no longer fresh and quarantine-clear."
            }
        }
    }

    private func markStateStale() {
        guard lastObservedAt != nil else { return }
        workspaces = workspaces.map { workspace in
            var stale = workspace
            stale.freshness = .stale
            stale.canStart = false
            stale.canStop = false
            stale.canRestart = false
            stale.nextAction = "Retry"
            return stale
        }
        invalidatePendingPlansIfUnsafe()
    }

    func activitiesSnapshot() async -> [MSWActivity] {
        await activityStore.recent(limit: 100)
    }

    private func runLifecycle(
        _ action: MSWLifecycleAction,
        id: Workspace.ID,
        confirmation: String? = nil,
        reviewedPlan: MSWLifecyclePlan? = nil
    ) {
        guard let operationCoordinator else {
            lastError = "MSW operations are unavailable in fixture mode."
            return
        }
        guard requireActionSafety(for: id, action: .lifecycle(action), operation: action.rawValue.capitalized) else { return }
        if confirmation == nil {
            pendingLifecycleOriginalState = workspaces.first(where: { $0.id == id })?.state
        }
        updateState(id, to: action == .start ? .starting : action == .stop ? .stopping : .restarting)
        Task { [weak self] in
            do {
                let result = try await operationCoordinator.lifecycle(
                    action,
                    workspace: id.rawValue,
                    confirmation: confirmation,
                    reviewedPlan: reviewedPlan
                )
                await MainActor.run {
                    guard let self else { return }
                    guard self.requireActionSafety(for: id, action: .lifecycle(action), operation: action.rawValue.capitalized) else {
                        self.pendingLifecycleOriginalState = nil
                        return
                    }
                    self.apply(result: result)
                    self.pendingLifecycleOriginalState = nil
                }
                let activity = MSWActivity(id: UUID(), createdAt: Date(), kind: .operation, title: "\(action.rawValue.capitalized) completed", detail: result.outcome, workspace: id.rawValue, isFailure: false)
                await self?.append(activity)
                await self?.refreshRemote()
            } catch let error as MSWOperationCoordinator.CoordinatorError {
                if case let .confirmationRequired(plan) = error {
                    await MainActor.run {
                        guard let self else { return }
                        guard self.requireActionSafety(for: id, action: .lifecycle(action), operation: action.rawValue.capitalized) else {
                            self.clearPendingLifecyclePlan()
                            return
                        }
                        self.pendingLifecyclePlan = plan
                        self.pendingLifecycleAction = action
                        self.pendingLifecycleWorkspace = id
                        if let originalState = self.pendingLifecycleOriginalState {
                            self.updateState(id, to: originalState)
                        }
                        self.lastError = nil
                    }
                    return
                }
                await MainActor.run {
                    self?.lastError = error.localizedDescription
                    self?.pendingLifecycleOriginalState = nil
                    self?.updateState(id, to: .unknown)
                }
                let activity = MSWActivity(id: UUID(), createdAt: Date(), kind: .failure, title: "\(action.rawValue.capitalized) failed", detail: error.localizedDescription, workspace: id.rawValue, isFailure: true)
                await self?.append(activity)
                await self?.refreshRemote()
            } catch {
                await MainActor.run {
                    self?.lastError = error.localizedDescription
                    self?.pendingLifecycleOriginalState = nil
                    self?.updateState(id, to: .unknown)
                }
                let activity = MSWActivity(id: UUID(), createdAt: Date(), kind: .failure, title: "\(action.rawValue.capitalized) failed", detail: error.localizedDescription, workspace: id.rawValue, isFailure: true)
                await self?.append(activity)
                await self?.refreshRemote()
            }
        }
    }

    private func apply(state: MSWStateResponse, observedAt: Date?) {
        lastObservedAt = observedAt ?? Date()
        let snapshots = Dictionary(uniqueKeysWithValues: state.workspaces.map { ($0.id, $0) })
        workspaces = Workspace.ID.allCases.map { id in
            guard let snapshot = snapshots[id.rawValue] else {
                return Workspace(id: id, state: .unknown, freshness: .unavailable, nextAction: "Retry", canStart: false)
            }
            // Unknown quarantine state is fail-closed for every action except
            // the safe Stop path, which the CLI exposes independently.
            let isQuarantined = snapshot.quarantine.state != .clear ||
                snapshot.credential.state == .quarantined
            let lifecycle = isQuarantined
                ? Workspace.State.quarantined
                : Workspace.State(rawValue: snapshot.lifecycle.rawValue) ?? .unknown
            let capabilities = isQuarantined
                ? MSWActionCapabilities(canStart: false, canStop: snapshot.actionCapabilities.canStop, canRestart: false, canOpenTerminal: false, canPush: false)
                : snapshot.actionCapabilities
            let stateObservedAt = snapshot.statusObservedAt ?? observedAt
            return Workspace(
                id: id,
                purpose: snapshot.purpose,
                state: lifecycle,
                credential: isQuarantined ? .quarantined : credentialState(snapshot.credential.state),
                freshness: snapshot.freshness,
                observedAt: stateObservedAt,
                networkHost: snapshot.network.host,
                quarantineReason: isQuarantined
                    ? (snapshot.quarantine.reason ?? "Workspace safety state could not be verified.")
                    : nil,
                nextAction: nextAction(snapshot, isQuarantined: isQuarantined),
                canStart: capabilities.canStart,
                canStop: capabilities.canStop,
                canRestart: capabilities.canRestart
            )
        }
        invalidatePendingPlansIfUnsafe()
    }

    private func apply(result: MSWApplyResult) {
        guard let id = Workspace.ID(rawValue: result.workspace) else { return }
        updateState(id, to: result.action == MSWLifecycleAction.start.rawValue ? .running : result.action == MSWLifecycleAction.stop.rawValue ? .stopped : .running)
    }

    private func updateState(_ id: Workspace.ID, to state: Workspace.State) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[index].state = state
        switch state {
        case .running: workspaces[index].nextAction = "Open Terminal"
        case .stopped, .exited: workspaces[index].nextAction = "Start"
        case .starting: workspaces[index].nextAction = "Starting \(id.rawValue)…"
        case .stopping: workspaces[index].nextAction = "Stopping \(id.rawValue)…"
        case .restarting: workspaces[index].nextAction = "Restarting \(id.rawValue)…"
        case .quarantined: workspaces[index].nextAction = workspaces[index].canStop ? "Stop or Repair" : "Repair"
        case .unknown, .unavailable: workspaces[index].nextAction = "Retry"
        }
        switch state {
        case .running:
            workspaces[index].canStart = false
            workspaces[index].canStop = true
            workspaces[index].canRestart = true
        case .stopped, .exited:
            workspaces[index].canStart = true
            workspaces[index].canStop = false
            workspaces[index].canRestart = false
        case .starting, .stopping, .restarting, .unknown, .unavailable:
            workspaces[index].canStart = false
            workspaces[index].canStop = false
            workspaces[index].canRestart = false
        case .quarantined:
            workspaces[index].canStart = false
            workspaces[index].canRestart = false
        }
    }

    private func credentialState(_ state: MSWCredentialSnapshot.State) -> Workspace.CredentialState {
        switch state {
        case .ready: return .ready
        case .expiring: return .expiring
        case .needsRestart: return .needsRestart
        case .needsAuthorization: return .needsAuthorization
        case .serviceUnavailable: return .serviceUnavailable
        case .legacy: return .legacy
        case .removalPending: return .removalPending
        case .readOnly: return .readOnly
        case .quarantined: return .quarantined
        case .unconfigured: return .unconfigured
        }
    }

    private func nextAction(_ snapshot: MSWWorkspaceSnapshot, isQuarantined: Bool = false) -> String {
        guard !isQuarantined else {
            return snapshot.actionCapabilities.canStop ? "Stop or Repair" : "Repair"
        }
        switch snapshot.lifecycle {
        case .running: return snapshot.actionCapabilities.canOpenTerminal ? "Open Terminal" : "Retry"
        case .stopped, .exited: return snapshot.actionCapabilities.canStart ? "Start" : "Repair"
        case .quarantined: return "Repair"
        default: return "Retry"
        }
    }


    private func append(_ activity: MSWActivity) async {
        await activityStore.append(activity)
        activities = await activityStore.recent(limit: 100)
    }
}
