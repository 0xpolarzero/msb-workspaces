import Foundation

struct SiloWorkspaceNetworkRecord: Codable, Equatable, Sendable {
    let address: String
    let hostname: String
}

enum SiloWorkspaceNetwork {
    static func records(for workspaceNames: [String]) -> [SiloWorkspaceNetworkRecord] {
        workspaceNames.enumerated().map { index, name in
            SiloWorkspaceNetworkRecord(address: "127.0.0.\(10 + index)", hostname: "\(name).silo.test")
        }
    }

    static let fixtureRecords = records(for: ["dev", "playgrounds", "personal"])
}
