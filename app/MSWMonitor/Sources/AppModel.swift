import Foundation
import Observation

struct Workspace: Identifiable, Equatable, Sendable {
    enum ID: String, CaseIterable, Sendable {
        case dev
        case playgrounds
        case personal
    }

    enum State: String, Equatable, Sendable {
        case stopped = "Stopped"
    }

    let id: ID
    var state: State
}

@Observable
@MainActor
final class AppModel {
    private(set) var workspaces: [Workspace]
    private(set) var observationCount = 0

    init() {
        workspaces = Workspace.ID.allCases.map {
            Workspace(id: $0, state: .stopped)
        }
    }

    var observationText: String {
        observationCount == 0
            ? "Not yet refreshed"
            : "Observation #\(observationCount)"
    }

    func refresh() {
        observationCount += 1
    }
}
