import Foundation

/// Serializes mutations per workspace and refuses to present an operation as
/// complete until the MSW plan/apply response reports reconciliation.
actor MSWOperationCoordinator {
    enum CoordinatorError: Error, LocalizedError, Sendable, Equatable {
        case busy(workspace: String)
        case invalidWorkspace
        case confirmationRequired(MSWLifecyclePlan)
        case unreconciled(workspace: String, action: String)

        var errorDescription: String? {
            switch self {
            case .busy(let workspace): return "An operation is already running for \(workspace)."
            case .invalidWorkspace: return "The requested workspace is invalid."
            case .confirmationRequired(let plan):
                return "\(plan.effects) Confirm \(plan.confirmationPhrase) to continue."
            case .unreconciled(let workspace, let action):
                return "MSW did not reconcile \(action) for \(workspace); refresh before retrying."
            }
        }
    }

    private let client: MSWClient
    private var activeWorkspaces: Set<String> = []

    init(client: MSWClient) {
        self.client = client
    }

    func lifecycle(
        _ action: MSWLifecycleAction,
        workspace: String,
        confirmation: String? = nil,
        reviewedPlan: MSWLifecyclePlan? = nil
    ) async throws -> MSWApplyResult {
        guard WorkspaceID.isValid(workspace) else { throw CoordinatorError.invalidWorkspace }
        guard activeWorkspaces.insert(workspace).inserted else {
            throw CoordinatorError.busy(workspace: workspace)
        }
        defer { activeWorkspaces.remove(workspace) }

        let plan: MSWLifecyclePlan
        if let reviewedPlan {
            guard reviewedPlan.workspace == workspace, reviewedPlan.action == action.rawValue else {
                throw MSWClientError.invalidArguments
            }
            plan = reviewedPlan
        } else {
            guard let prepared = try await client.prepareLifecyclePlan(action: action, workspace: workspace).result else {
                throw MSWClientError.missingResult(command: "plan")
            }
            plan = prepared
        }
        if action != .start && confirmation == nil {
            throw CoordinatorError.confirmationRequired(plan)
        }
        let phrase = confirmation ?? plan.confirmationPhrase
        let result = try await client.applyLifecyclePlan(plan, confirmation: phrase).result
        guard let result else { throw MSWClientError.missingResult(command: "apply") }
        guard result.reconciled else {
            throw CoordinatorError.unreconciled(workspace: workspace, action: action.rawValue)
        }
        return result
    }

    func isBusy(workspace: String) -> Bool {
        activeWorkspaces.contains(workspace)
    }

    func applyPushPlan(_ plan: MSWPushPlan, confirmation: String) async throws -> MSWPushApplyResult {
        let workspace = plan.workspace
        guard WorkspaceID.isValid(workspace) else { throw CoordinatorError.invalidWorkspace }
        guard activeWorkspaces.insert(workspace).inserted else {
            throw CoordinatorError.busy(workspace: workspace)
        }
        defer { activeWorkspaces.remove(workspace) }
        guard confirmation == plan.confirmationPhrase else { throw MSWClientError.invalidArguments }
        let response = try await client.applyPushPlan(plan, confirmation: confirmation)
        guard let result = response.result else { throw MSWClientError.missingResult(command: "apply") }
        return result
    }

    func busyWorkspaces() -> Set<String> { activeWorkspaces }
}

enum WorkspaceID {
    static var all: [String] {
        BootstrapStateStore.persistedWorkspaceConfigurations().map(\.name)
    }

    static func isValid(_ value: String) -> Bool {
        value.range(of: #"^[a-z][a-z0-9-]{0,31}$"#, options: .regularExpression) != nil
    }
}

actor MSWActivityStore {
    private let limit: Int
    private var activities: [MSWActivity] = []

    init(limit: Int = 200) {
        self.limit = max(10, limit)
    }

    func append(_ activity: MSWActivity) {
        activities.append(activity)
        if activities.count > limit {
            activities.removeFirst(activities.count - limit)
        }
    }

    func recent(limit requestedLimit: Int = 50) -> [MSWActivity] {
        Array(activities.suffix(max(0, requestedLimit)))
    }

    func removeAll() { activities.removeAll(keepingCapacity: true) }
}
