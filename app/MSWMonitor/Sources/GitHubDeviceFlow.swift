import Foundation
import Observation
import SwiftUI

/// App-serviceable GitHub OAuth Device Flow (§5 / plan.md §3.5). The CLI owns
/// the token; the app only prints the code, opens the verification URI, and
/// polls `--device-complete` until authorization, slow-down, expiry, or
/// denial. These models mirror the CLI's JSON contract (raw CLI translation
/// lives in MSWClient).

struct MSWDeviceFlowStart: Codable, Sendable, Equatable {
    let deviceId: String
    let code: String
    let verificationUri: String
    let expiresAt: Date
    let interval: Int
}

enum MSWDeviceFlowPollStatus: String, Codable, Sendable, Equatable {
    case pending
    case authorized
    case slowDown = "slow_down"
    case expired
    case denied
}

struct MSWDeviceFlowPoll: Codable, Sendable, Equatable {
    let status: MSWDeviceFlowPollStatus
    let interval: Int?
    let accountLogin: String?
}

/// Injectable device-flow transport so the session state machine is unit
/// testable with a mocked implementation.
protocol DeviceFlowPolling: Sendable {
    func startDeviceFlow() async throws -> MSWDeviceFlowStart
    func pollDeviceFlow(deviceId: String) async throws -> MSWDeviceFlowPoll
}

/// Deterministic device-flow state machine (plan.md §3.5): begin -> show
/// code -> poll (pending repeats; slow_down backs off; authorized completes;
/// expired/denied end) -> restart/cancel. The view drives the timer loop; the
/// session owns every transition and is fully testable with scripted
/// start/poll closures.
@MainActor
@Observable
final class GitHubDeviceFlowSession {
    enum Phase: Equatable {
        case idle
        case starting
        case showingCode(code: String, verificationURI: URL, expiresAt: Date, interval: Int)
        case polling
        case backoff(seconds: Int)
        case expired
        case denied
        case failed(String)
        case complete(accountLogin: String?)
    }

    private(set) var phase: Phase = .idle
    private(set) var deviceId: String?

    private let startDeviceFlow: () async throws -> MSWDeviceFlowStart
    private let pollDeviceFlow: (String) async throws -> MSWDeviceFlowPoll

    init(
        startDeviceFlow: @escaping () async throws -> MSWDeviceFlowStart,
        pollDeviceFlow: @escaping (String) async throws -> MSWDeviceFlowPoll
    ) {
        self.startDeviceFlow = startDeviceFlow
        self.pollDeviceFlow = pollDeviceFlow
    }

    /// Begins the flow and returns the next poll delay in seconds, or nil
    /// when the session ended immediately (failed start).
    func begin() async -> Int? {
        phase = .starting
        deviceId = nil
        do {
            let start = try await startDeviceFlow()
            deviceId = start.deviceId
            guard let uri = URL(string: start.verificationUri),
                  start.verificationUri.hasPrefix("https://") else {
                phase = .failed("The device-flow verification URI is invalid.")
                return nil
            }
            phase = .showingCode(
                code: start.code,
                verificationURI: uri,
                expiresAt: start.expiresAt,
                interval: start.interval
            )
            return start.interval
        } catch {
            phase = .failed(error.localizedDescription)
            return nil
        }
    }

    /// Applies one poll result and returns the next delay in seconds, or nil
    /// when the session ended.
    func handlePoll(_ poll: MSWDeviceFlowPoll) -> Int? {
        switch poll.status {
        case .pending:
            phase = .polling
            return poll.interval ?? 5
        case .slowDown:
            phase = .backoff(seconds: poll.interval ?? 10)
            return poll.interval ?? 10
        case .authorized:
            phase = .complete(accountLogin: poll.accountLogin)
            return nil
        case .expired:
            phase = .expired
            return nil
        case .denied:
            phase = .denied
            return nil
        }
    }

    /// Maps a poll transport failure (typed CLI errors) into a poll result.
    static func pollOutcome(for error: Error) -> MSWDeviceFlowPoll {
        if let clientError = error as? MSWClientError {
            switch clientError {
            case .rawCLIError(let code, _) where code == "MSW_DEVICE_EXPIRED" || code == "MSW_DEVICE_AUTHORIZATION_EXPIRED":
                return MSWDeviceFlowPoll(status: .expired, interval: nil, accountLogin: nil)
            case .rawCLIError(let code, _) where code == "MSW_DEVICE_DENIED" || code == "MSW_DEVICE_AUTHORIZATION_DENIED":
                return MSWDeviceFlowPoll(status: .denied, interval: nil, accountLogin: nil)
            case .rawCLIError(let code, let message) where code == "MSW_DEVICE_SLOW_DOWN":
                return MSWDeviceFlowPoll(status: .slowDown, interval: nil, accountLogin: nil)
            case .rawCLIError(let code, _) where code == "MSW_HOST_CREDENTIAL_VERIFICATION_FAILED":
                return MSWDeviceFlowPoll(
                    status: .denied,
                    interval: nil,
                    accountLogin: nil
                )
            case .protocolFailure(let protocolError):
                switch protocolError.code {
                case "MSW_DEVICE_EXPIRED", "MSW_DEVICE_AUTHORIZATION_EXPIRED":
                    return MSWDeviceFlowPoll(status: .expired, interval: nil, accountLogin: nil)
                case "MSW_DEVICE_DENIED", "MSW_DEVICE_AUTHORIZATION_DENIED":
                    return MSWDeviceFlowPoll(status: .denied, interval: nil, accountLogin: nil)
                case "MSW_DEVICE_SLOW_DOWN":
                    return MSWDeviceFlowPoll(status: .slowDown, interval: nil, accountLogin: nil)
                default:
                    return MSWDeviceFlowPoll(status: .denied, interval: nil, accountLogin: nil)
                }
            default:
                // Unknown/transient failures end the flow; the UI offers a
                // fresh start (the CLI reports every device status as a typed
                // code, so anything else is a genuine failure).
                return MSWDeviceFlowPoll(status: .denied, interval: nil, accountLogin: nil)
            }
        }
        return MSWDeviceFlowPoll(status: .denied, interval: nil, accountLogin: nil)
    }

    /// Re-arms the session for a fresh code.
    func restart() {
        phase = .idle
        deviceId = nil
    }

    func cancel() {
        phase = .idle
        deviceId = nil
    }

    /// Polls once through the injected transport and applies the outcome.
    func poll() async -> Int? {
        guard let deviceId else { return nil }
        do {
            return handlePoll(try await pollDeviceFlow(deviceId))
        } catch {
            return handlePoll(Self.pollOutcome(for: error))
        }
    }
}

/// Device-flow authorization sheet: code, verification URI, countdown, poll
/// loop, and terminal states (expired/denied/failed with a fresh start).
/// Completion reports the authorized account login (or nil) to the caller.
struct GitHubDeviceFlowView: View {
    let session: GitHubDeviceFlowSession
    let onComplete: (String?) -> Void
    let onCancel: () -> Void
    @State private var flowGeneration = 0
    @State private var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Authorize MSW Monitor on GitHub", systemImage: "lock.open")
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("setup.github.device.title")
            switch session.phase {
            case .idle, .starting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Starting GitHub sign-in…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .contain)
            case .showingCode(let code, let uri, let expiresAt, _):
                Text("In your browser, enter this code on the GitHub device page:")
                    .font(.callout)
                Text(code)
                    .font(.system(size: 30, weight: .bold, design: .monospaced))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("setup.github.device.code")
                HStack(spacing: 12) {
                    Button("Open GitHub") { NSWorkspace.shared.open(uri) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("setup.github.device.open")
                    Text("Code expires in \(expiresIn(expiresAt))")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("setup.github.device.expiry")
                }
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for authorization…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .contain)
            case .polling:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking authorization…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .contain)
            case .backoff(let seconds):
                Text("GitHub is busy. Retrying in \(seconds) seconds…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .expired:
                Label("The code expired.", systemImage: "clock.badge.exclamationmark.fill")
                    .foregroundStyle(.orange)
                Button("Start over", action: restart)
                    .accessibilityIdentifier("setup.github.device.restart")
            case .denied:
                Label("Authorization was denied or could not be completed.", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                Button("Start over", action: restart)
                    .accessibilityIdentifier("setup.github.device.restart")
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            case .complete:
                EmptyView()
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("setup.github.device.cancel")
            }
        }
        .padding(24)
        .frame(width: 520)
        .task(id: flowGeneration) { await run() }
        .task { await ticker() }
    }

    private func expiresIn(_ date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        return "\(seconds)s"
    }

    private func restart() {
        session.restart()
        flowGeneration += 1
    }

    private func run() async {
        var delay = await session.begin()
        while let seconds = delay, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(seconds))
            delay = await session.poll()
        }
        if case .complete(let login) = session.phase {
            onComplete(login)
        }
    }

    private func ticker() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            now = Date()
        }
    }
}
