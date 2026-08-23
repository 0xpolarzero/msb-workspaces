import Foundation

struct MSWWorkspaceNetworkRecord: Codable, Equatable, Sendable {
    let address: String
    let hostname: String
}

enum MSWWorkspaceNetwork {
    static func records(for workspaceNames: [String]) -> [MSWWorkspaceNetworkRecord] {
        workspaceNames.enumerated().map { index, name in
            MSWWorkspaceNetworkRecord(address: "127.0.0.\(10 + index)", hostname: "\(name).msw.test")
        }
    }

    static let fixtureRecords = records(for: ["dev", "playgrounds", "personal"])
}
