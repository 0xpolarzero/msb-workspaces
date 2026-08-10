import Foundation

struct MSWWorkspaceNetworkRecord: Equatable, Sendable {
    let address: String
    let hostname: String
}

enum MSWWorkspaceNetwork {
    static let records = [
        MSWWorkspaceNetworkRecord(address: "127.0.0.10", hostname: "dev.msw.test"),
        MSWWorkspaceNetworkRecord(address: "127.0.0.11", hostname: "playgrounds.msw.test"),
        MSWWorkspaceNetworkRecord(address: "127.0.0.12", hostname: "personal.msw.test")
    ]

    static var addresses: [String] {
        records.map(\.address)
    }
}
