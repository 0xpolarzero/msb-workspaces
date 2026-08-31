import Foundation

struct MSWHostRecordSnapshot: Codable, Sendable, Equatable {
    let fixedAliases: [String]
    let hostsBlockInstalled: Bool
    let launchDaemonRegistered: Bool
}

enum SiloHostAgentError: Error, LocalizedError, Sendable, Equatable {
    case unavailable
    case timeout
    case authorizationDenied
    case invalidInput
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "The privileged MSW host helper is unavailable."
        case .timeout: return "The privileged MSW host helper did not respond within 10 seconds."
        case .authorizationDenied: return "Administrator approval for the MSW host helper was denied."
        case .invalidInput: return "The host integration request was invalid."
        case .rejected(let message): return message
        }
    }
}

@objc protocol SiloHostAgentProtocol {
    func inspect(_ configuration: Data, reply: @escaping (Data?, String?) -> Void)
    func ensureFixedLoopbackAliases(_ configuration: Data, reply: @escaping (Data?, String?) -> Void)
    func installFixedHostRecords(_ configuration: Data, reply: @escaping (Data?, String?) -> Void)
    func uninstall(_ configuration: Data, reply: @escaping (Data?, String?) -> Void)
}
protocol SiloHostAgentControlling: Sendable {
    func inspect(records: [MSWWorkspaceNetworkRecord]) async throws -> MSWHostRecordSnapshot
    func ensureFixedLoopbackAliases(records: [MSWWorkspaceNetworkRecord]) async throws -> MSWHostRecordSnapshot
    func installFixedHostRecords(records: [MSWWorkspaceNetworkRecord]) async throws -> MSWHostRecordSnapshot
    func uninstall(records: [MSWWorkspaceNetworkRecord]) async throws -> MSWHostRecordSnapshot
}


private final class SiloHostAgentCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<MSWHostRecordSnapshot, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var timeoutHandler: (() -> Void)?

    init(_ continuation: CheckedContinuation<MSWHostRecordSnapshot, Error>) {
        self.continuation = continuation
    }

    func setTimeoutHandler(_ handler: @escaping () -> Void) {
        lock.lock()
        guard continuation != nil else {
            lock.unlock()
            return
        }
        timeoutHandler = handler
        lock.unlock()
    }

    func setTimeoutTask(_ task: Task<Void, Never>) {
        lock.lock()
        if continuation == nil {
            lock.unlock()
            task.cancel()
        } else {
            timeoutTask = task
            lock.unlock()
        }
    }

    func finish(
        _ result: Result<MSWHostRecordSnapshot, Error>,
        retiresConnection: Bool = false
    ) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let timeoutTask = self.timeoutTask
        self.timeoutTask = nil
        let timeoutHandler = retiresConnection ? self.timeoutHandler : nil
        self.timeoutHandler = nil
        lock.unlock()
        timeoutTask?.cancel()
        timeoutHandler?()
        continuation?.resume(with: result)
    }
}

actor HostAgentClient: SiloHostAgentControlling {
    private let machServiceName: String
    private var connection: NSXPCConnection?
    private var connectionGeneration: String?

    init(machServiceName: String = "org.microsandbox.Silo.host-agent") {
        self.machServiceName = machServiceName
    }

    func inspect(records: [MSWWorkspaceNetworkRecord]) async throws -> MSWHostRecordSnapshot {
        try await call(records: records) { proxy, data, reply in proxy.inspect(data, reply: reply) }
    }

    func ensureFixedLoopbackAliases(records: [MSWWorkspaceNetworkRecord]) async throws -> MSWHostRecordSnapshot {
        try await call(records: records) { proxy, data, reply in proxy.ensureFixedLoopbackAliases(data, reply: reply) }
    }

    func installFixedHostRecords(records: [MSWWorkspaceNetworkRecord]) async throws -> MSWHostRecordSnapshot {
        try await call(records: records) { proxy, data, reply in proxy.installFixedHostRecords(data, reply: reply) }
    }

    func uninstall(records: [MSWWorkspaceNetworkRecord]) async throws -> MSWHostRecordSnapshot {
        try await call(records: records) { proxy, data, reply in proxy.uninstall(data, reply: reply) }
    }

    private func call(
        records: [MSWWorkspaceNetworkRecord],
        _ invoke: @escaping (SiloHostAgentProtocol, Data, @escaping (Data?, String?) -> Void) -> Void
    ) async throws -> MSWHostRecordSnapshot {
        guard let configuration = try? JSONEncoder().encode(records), configuration.count <= 16 * 1024 else {
            throw SiloHostAgentError.invalidInput
        }
        return try await withCheckedThrowingContinuation { continuation in
            let completion = SiloHostAgentCompletion(continuation)
            do {
                let (proxy, generation) = try remoteProxy { _ in
                    completion.finish(.failure(SiloHostAgentError.unavailable))
                }
                completion.setTimeoutHandler { [weak self] in
                    Task { await self?.connectionTimedOut(generation: generation) }
                }
                let timeoutTask = Task {
                    do {
                        try await Task.sleep(for: .seconds(10))
                        completion.finish(
                            .failure(SiloHostAgentError.timeout),
                            retiresConnection: true
                        )
                    } catch {
                        // The request completed before the timeout.
                    }
                }
                completion.setTimeoutTask(timeoutTask)
                invoke(proxy, configuration) { data, errorMessage in
                    if let errorMessage {
                        completion.finish(.failure(SiloHostAgentError.rejected(errorMessage)))
                    } else if let data,
                              let snapshot = try? JSONDecoder().decode(MSWHostRecordSnapshot.self, from: data) {
                        completion.finish(.success(snapshot))
                    } else {
                        completion.finish(.failure(SiloHostAgentError.unavailable))
                    }
                }
            } catch {
                completion.finish(.failure(error))
            }
        }
    }

    private func remoteProxy(
        errorHandler: @escaping (Error) -> Void
    ) throws -> (proxy: SiloHostAgentProtocol, generation: String) {
        if connection == nil {
            let value = NSXPCConnection(machServiceName: machServiceName, options: .privileged)
            let generation = UUID().uuidString
            value.remoteObjectInterface = NSXPCInterface(with: SiloHostAgentProtocol.self)
            value.invalidationHandler = { [weak self] in
                Task { await self?.connectionInvalidated(generation: generation) }
            }
            value.interruptionHandler = { [weak self] in
                Task { await self?.connectionInvalidated(generation: generation) }
            }
            value.resume()
            connection = value
            connectionGeneration = generation
        }
        guard let connection,
              let generation = connectionGeneration,
              let proxy = connection.remoteObjectProxyWithErrorHandler(errorHandler) as? SiloHostAgentProtocol else {
            throw SiloHostAgentError.unavailable
        }
        return (proxy, generation)
    }

    private func connectionInvalidated(generation: String) {
        guard connectionGeneration == generation else { return }
        connection = nil
        connectionGeneration = nil
    }

    private func connectionTimedOut(generation: String) {
        guard connectionGeneration == generation else { return }
        connection?.invalidate()
        connection = nil
        connectionGeneration = nil
    }
}
