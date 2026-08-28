import Foundation
import Observation
import UserNotifications

enum MSWNotificationCategory: String, CaseIterable, Identifiable {
    case availability
    case safety
    case operations
    case backups
    case credentials

    var id: String { rawValue }

    var title: String {
        switch self {
        case .availability: return "Sustained unavailability"
        case .safety: return "Quarantine and lifecycle loss"
        case .operations: return "Operation failures"
        case .backups: return "Backup failures"
        case .credentials: return "Credential deadlines"
        }
    }

    var detail: String {
        switch self {
        case .availability:
            return "Alert only after repeated state observations fail."
        case .safety:
            return "Alert when a workspace is quarantined or unexpectedly loses its lifecycle."
        case .operations:
            return "Alert when a reviewed workspace operation fails."
        case .backups:
            return "Alert when a requested backup cannot be completed."
        case .credentials:
            return "Alert before workspace credentials require reauthorization."
        }
    }

    fileprivate var preferenceKey: String {
        "notifications.category.\(rawValue).enabled"
    }

    fileprivate func contains(_ kind: MSWNotificationEvent.Kind) -> Bool {
        switch (self, kind) {
        case (.availability, .sustainedUnavailability),
             (.safety, .quarantine),
             (.safety, .lifecycleLoss),
             (.operations, .operationFailure),
             (.backups, .backupFailure),
             (.credentials, .credentialDeadline):
            return true
        default:
            return false
        }
    }

    fileprivate static func category(for kind: MSWNotificationEvent.Kind) -> Self? {
        allCases.first { $0.contains(kind) }
    }
}

@MainActor
protocol MSWNotificationCenterControlling: AnyObject {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
}

@MainActor
private final class SystemNotificationCenter: MSWNotificationCenterControlling {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter) {
        self.center = center
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        try await center.requestAuthorization(options: options)
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await center.add(request)
    }
}

struct MSWNotificationDeliveryFailure: Identifiable, Equatable, Sendable {
    let event: MSWNotificationEvent
    let attempts: Int

    var id: UUID { event.id }
}

@Observable
@MainActor
final class NotificationCoordinator {
    static let shared = NotificationCoordinator()
    private static let enabledPreferenceKey = "notifications.enabled"

    private struct RetryEntry {
        let event: MSWNotificationEvent
        let attempts: Int
    }

    private let notificationCenter: any MSWNotificationCenterControlling
    private let defaults: UserDefaults
    private let retryDelays: [Duration]
    private var deliveredKeys: Set<String> = []
    private var retryableEvents: [RetryEntry] = []
    private var retryTask: Task<Void, Never>?
    private(set) var permanentFailures: [MSWNotificationDeliveryFailure] = []

    init(
        center: UNUserNotificationCenter = .current(),
        defaults: UserDefaults = .standard,
        notificationCenter: (any MSWNotificationCenterControlling)? = nil,
        retryDelays: [Duration] = [.seconds(5), .seconds(15)]
    ) {
        self.notificationCenter = notificationCenter ?? SystemNotificationCenter(center: center)
        self.defaults = defaults
        self.retryDelays = retryDelays
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await notificationCenter.authorizationStatus()
    }

    func clearPermanentFailures() {
        permanentFailures.removeAll(keepingCapacity: true)
    }

    func retryFailedNotifications() async {
        let failedEvents = permanentFailures.map(\.event)
        permanentFailures.removeAll(keepingCapacity: true)
        await deliverEvents(failedEvents)
    }

    var notificationFailureMessage: String? {
        guard let failure = permanentFailures.last else { return nil }
        let scope = failure.event.workspace.map { " for \($0)" } ?? ""
        return "A notification\(scope) could not be delivered after \(failure.attempts) attempts. Check Notification Settings and retry the alert category."
    }

    func enabledCategories() -> Set<MSWNotificationCategory> {
        Set(MSWNotificationCategory.allCases.filter { defaults.bool(forKey: $0.preferenceKey) })
    }

    func notificationsEnabled() -> Bool {
        defaults.bool(forKey: Self.enabledPreferenceKey)
    }

    @discardableResult
    func setNotificationsEnabled(_ enabled: Bool) async -> Bool {
        guard enabled else {
            defaults.set(false, forKey: Self.enabledPreferenceKey)
            return false
        }

        let status = await self.authorizationStatus()
        let authorized: Bool
        switch status {
        case .authorized, .provisional, .ephemeral:
            authorized = true
        case .notDetermined:
            authorized = (try? await notificationCenter.requestAuthorization(options: [.alert, .sound])) == true
        case .denied:
            authorized = false
        @unknown default:
            authorized = false
        }

        defaults.set(authorized, forKey: Self.enabledPreferenceKey)
        return authorized
    }

    @discardableResult
    func setEnabled(_ enabled: Bool, for category: MSWNotificationCategory) async -> Bool {
        guard enabled else {
            defaults.set(false, forKey: category.preferenceKey)
            return false
        }

        guard await setNotificationsEnabled(true) else { return false }
        defaults.set(true, forKey: category.preferenceKey)
        return true
    }

    private enum DeliveryResult {
        case delivered
        case skipped
        case failed
    }

    private var maxAttempts: Int {
        retryDelays.count + 1
    }

    func deliver(_ events: [MSWNotificationEvent]) async {
        await deliverEvents(events)
    }

    func deliverPendingEvents(from model: AppModel) async {
        await deliverEvents(model.drainNotificationEvents())
    }

    func deliver(_ event: MSWNotificationEvent) async {
        await deliverEvents([event])
    }

    private func deliverEvents(_ events: [MSWNotificationEvent]) async {
        for event in events {
            if await deliverEvent(event) == .failed {
                enqueueRetry(for: event, attempts: 1)
            }
        }
        scheduleRetry()
    }

    private func enqueueRetry(for event: MSWNotificationEvent, attempts: Int) {
        guard attempts < maxAttempts else {
            recordPermanentFailure(event, attempts: maxAttempts)
            return
        }
        if let index = retryableEvents.firstIndex(where: { $0.event.id == event.id }) {
            retryableEvents[index] = RetryEntry(event: event, attempts: max(retryableEvents[index].attempts, attempts))
        } else {
            retryableEvents.append(RetryEntry(event: event, attempts: attempts))
        }
    }

    private func recordPermanentFailure(_ event: MSWNotificationEvent, attempts: Int) {
        guard !permanentFailures.contains(where: { $0.event.id == event.id }) else { return }
        permanentFailures.append(MSWNotificationDeliveryFailure(event: event, attempts: attempts))
        if permanentFailures.count > 32 {
            permanentFailures.removeFirst(permanentFailures.count - 32)
        }
    }

    private func scheduleRetry() {
        guard retryTask == nil, let nextAttempt = retryableEvents.map(\.attempts).min(),
              retryDelays.indices.contains(nextAttempt - 1) else { return }
        let delay = retryDelays[nextAttempt - 1]
        retryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            let entries = self.retryableEvents
            self.retryableEvents.removeAll(keepingCapacity: true)
            self.retryTask = nil
            await self.deliverRetryEntries(entries)
        }
    }

    private func deliverRetryEntries(_ entries: [RetryEntry]) async {
        for entry in entries {
            if await deliverEvent(entry.event) == .failed {
                enqueueRetry(for: entry.event, attempts: entry.attempts + 1)
            }
        }
        scheduleRetry()
    }

    private func deliverEvent(_ event: MSWNotificationEvent) async -> DeliveryResult {
        guard notificationsEnabled(),
              let category = MSWNotificationCategory.category(for: event.kind),
              defaults.bool(forKey: category.preferenceKey),
              (await self.authorizationStatus()).allowsDelivery,
              let payload = Self.deepLinkPayload(for: event) else {
            return .skipped
        }

        let deduplicationKey = [
            event.kind.rawValue,
            event.workspace ?? "all",
            String(event.generation),
        ].joined(separator: "|")
        guard !deliveredKeys.contains(deduplicationKey) else { return .delivered }

        let content = UNMutableNotificationContent()
        content.title = Self.title(for: event.kind)
        content.body = Self.body(for: event.kind, workspace: event.workspace)
        content.sound = .default
        content.categoryIdentifier = event.kind.rawValue
        content.userInfo = [
            "workspace": payload.workspace,
            "destination": payload.destination,
            "deepLink": payload.url.absoluteString,
        ]

        let identifier = "msw-monitor.\(event.kind.rawValue).\(payload.workspace).\(event.generation)"
        do {
            try await notificationCenter.add(
                UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            )
            deliveredKeys.insert(deduplicationKey)
            if deliveredKeys.count > 512 {
                deliveredKeys = Set(deliveredKeys.sorted().suffix(512))
            }
            return .delivered
        } catch {
            return .failed
        }
    }

    nonisolated static func deepLink(from response: UNNotificationResponse) -> URL? {
        guard let raw = response.notification.request.content.userInfo["deepLink"] as? String else {
            return nil
        }
        return validatedDeepLink(raw)
    }

    private static func deepLinkPayload(
        for event: MSWNotificationEvent
    ) -> (url: URL, workspace: String, destination: String)? {
        guard let url = validatedDeepLink(event.deepLink) else { return nil }
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        let destination = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "section" })?
            .value ?? pathComponents.last ?? url.host ?? "overview"
        return (url, event.workspace ?? "all", destination)
    }

    nonisolated private static func validatedDeepLink(_ raw: String) -> URL? {
        guard var components = URLComponents(string: raw),
              components.scheme == "msw-monitor",
              components.user == nil,
              components.password == nil else {
            return nil
        }
        let section = components.queryItems?
            .first(where: { $0.name == "section" })?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        components.queryItems = section.flatMap { $0.isEmpty ? nil : [URLQueryItem(name: "section", value: $0)] }
        components.fragment = nil
        return components.url
    }

    private static func title(for kind: MSWNotificationEvent.Kind) -> String {
        switch kind {
        case .sustainedUnavailability: return "MSW remains unavailable"
        case .quarantine: return "Workspace quarantined"
        case .lifecycleLoss: return "Workspace stopped unexpectedly"
        case .operationFailure: return "Workspace operation failed"
        case .backupFailure: return "Backup failed"
        case .credentialDeadline: return "GitHub access needs attention"
        }
    }

    private static func body(for kind: MSWNotificationEvent.Kind, workspace: String?) -> String {
        let scope = workspace.map { "Workspace \($0)" } ?? "MSW Monitor"
        switch kind {
        case .sustainedUnavailability:
            return "\(scope) could not be observed after repeated attempts. Open Diagnostics to retry."
        case .quarantine:
            return "\(scope) is quarantined. Review the safety reason before taking action."
        case .lifecycleLoss:
            return "\(scope) lost its expected lifecycle. Review its current state before restarting."
        case .operationFailure:
            return "A reviewed operation for \(scope.lowercased()) failed. Open Activity for recovery."
        case .backupFailure:
            return "The requested backup did not complete. Open Backups to retry safely."
        case .credentialDeadline:
            return "\(scope) needs GitHub reauthorization soon. Open GitHub Settings to review access."
        }
    }
}

private extension UNAuthorizationStatus {
    var allowsDelivery: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral: return true
        case .notDetermined, .denied: return false
        @unknown default: return false
        }
    }
}
