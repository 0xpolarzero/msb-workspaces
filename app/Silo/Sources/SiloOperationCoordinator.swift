import Foundation

struct SiloLifecycleApplyReceipt: Sendable {
    let result: SiloApplyResult
    let observedAt: Date?
}

/// Serializes mutations per workspace and refuses to present an operation as
/// complete until the Silo plan/apply response reports reconciliation.
actor SiloOperationCoordinator {
    enum CoordinatorError: Error, LocalizedError, Sendable, Equatable {
        case busy(workspace: String)
        case invalidWorkspace
        case confirmationRequired(SiloLifecyclePlan)
        case unreconciled(workspace: String, action: String)

        var errorDescription: String? {
            switch self {
            case .busy(let workspace): return "An operation is already running for \(workspace)."
            case .invalidWorkspace: return "The requested workspace is invalid."
            case .confirmationRequired(let plan):
                return "\(plan.effects) Confirm \(plan.confirmationPhrase) to continue."
            case .unreconciled(let workspace, let action):
                return "Silo did not reconcile \(action) for \(workspace); refresh before retrying."
            }
        }
    }

    private let client: SiloClient
    private var activeWorkspaces: Set<String> = []

    init(client: SiloClient) {
        self.client = client
    }

    func lifecycle(
        _ action: SiloLifecycleAction,
        workspace: String,
        confirmation: String? = nil,
        reviewedPlan: SiloLifecyclePlan? = nil
    ) async throws -> SiloLifecycleApplyReceipt {
        guard WorkspaceID.isValid(workspace) else { throw CoordinatorError.invalidWorkspace }
        guard activeWorkspaces.insert(workspace).inserted else {
            throw CoordinatorError.busy(workspace: workspace)
        }
        defer { activeWorkspaces.remove(workspace) }

        let plan: SiloLifecyclePlan
        if let reviewedPlan {
            guard reviewedPlan.workspace == workspace, reviewedPlan.action == action.rawValue else {
                throw SiloClientError.invalidArguments
            }
            plan = reviewedPlan
        } else {
            guard let prepared = try await client.prepareLifecyclePlan(action: action, workspace: workspace).result else {
                throw SiloClientError.missingResult(command: "plan")
            }
            plan = prepared
        }
        if action != .start && confirmation == nil {
            throw CoordinatorError.confirmationRequired(plan)
        }
        let phrase = confirmation ?? plan.confirmationPhrase
        let response = try await client.applyLifecyclePlan(plan, confirmation: phrase)
        guard let result = response.result else { throw SiloClientError.missingResult(command: "apply") }
        guard result.reconciled else {
            throw CoordinatorError.unreconciled(workspace: workspace, action: action.rawValue)
        }
        return SiloLifecycleApplyReceipt(result: result, observedAt: response.observedAt)
    }

    func isBusy(workspace: String) -> Bool {
        activeWorkspaces.contains(workspace)
    }

    func applyPushPlan(_ plan: SiloPushPlan, confirmation: String) async throws -> SiloPushApplyResult {
        let workspace = plan.workspace
        guard WorkspaceID.isValid(workspace) else { throw CoordinatorError.invalidWorkspace }
        guard activeWorkspaces.insert(workspace).inserted else {
            throw CoordinatorError.busy(workspace: workspace)
        }
        defer { activeWorkspaces.remove(workspace) }
        guard confirmation == plan.confirmationPhrase else { throw SiloClientError.invalidArguments }
        let response = try await client.applyPushPlan(plan, confirmation: confirmation)
        guard let result = response.result else { throw SiloClientError.missingResult(command: "apply") }
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

actor SiloActivityStore {
    private let limit: Int
    private var activities: [SiloActivity] = []

    init(limit: Int = 200) {
        self.limit = max(10, limit)
    }

    func append(_ activity: SiloActivity) {
        activities.append(activity)
        if activities.count > limit {
            activities.removeFirst(activities.count - limit)
        }
    }

    func recent(limit requestedLimit: Int = 50) -> [SiloActivity] {
        Array(activities.suffix(max(0, requestedLimit)))
    }

    func removeAll() { activities.removeAll(keepingCapacity: true) }
}
