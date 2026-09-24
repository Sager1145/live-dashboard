import Foundation
import UserNotifications
import LiveIngestionCore

/// Schedules local notifications for deadlines the user chose (e.g. "remind
/// me a day before applyEndAt"). Per DESIGN.md 七.3, a changed deadline must
/// replace the old reminder rather than stack a second one, so every
/// reminder is scheduled under a stable identifier derived from the entity.
public protocol ReminderScheduling: Sendable {
    func requestAuthorizationIfNeeded() async -> Bool
    func authorizationStatus() async -> UNAuthorizationStatus
    func scheduleDeadlineReminder(
        identifier: ReminderIdentifier,
        title: String,
        body: String,
        fireAt: Date
    ) async throws
    func cancelReminder(identifier: ReminderIdentifier) async
}

/// Deep-links a reminder to a specific event/performance/tab/card, per
/// DESIGN.md 七.3: "所有提醒应深链到正确公演、正确场次、正确 Tab、正确卡片".
public struct ReminderIdentifier: Hashable, Sendable {
    public let eventID: String
    public let performanceID: String
    public let tab: String
    public let cardType: CardType
    public let entityID: String

    public init(eventID: String, performanceID: String, tab: String, cardType: CardType, entityID: String) {
        self.eventID = eventID
        self.performanceID = performanceID
        self.tab = tab
        self.cardType = cardType
        self.entityID = entityID
    }

    /// Stable UNNotificationRequest identifier: scheduling again with the
    /// same identifier replaces the previous request instead of stacking.
    public var stableID: String {
        "live-dashboard.reminder.\(eventID).\(performanceID).\(tab).\(cardType.rawValue).\(entityID)"
    }
}

public final class ReminderService: ReminderScheduling, @unchecked Sendable {
    private let center: UNUserNotificationCenter

    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    public func requestAuthorizationIfNeeded() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        @unknown default:
            return false
        }
    }

    public func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    public func scheduleDeadlineReminder(
        identifier: ReminderIdentifier,
        title: String,
        body: String,
        fireAt: Date
    ) async throws {
        // Replace-by-identifier: remove any existing request first so a
        // changed deadline never leaves a stale reminder behind.
        center.removePendingNotificationRequests(withIdentifiers: [identifier.stableID])

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = [
            "eventID": identifier.eventID,
            "performanceID": identifier.performanceID,
            "tab": identifier.tab,
            "cardType": identifier.cardType.rawValue,
            "entityID": identifier.entityID
        ]

        let interval = fireAt.timeIntervalSinceNow
        guard interval > 0 else { return }
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: identifier.stableID, content: content, trigger: trigger)
        try await center.add(request)
    }

    public func cancelReminder(identifier: ReminderIdentifier) async {
        center.removePendingNotificationRequests(withIdentifiers: [identifier.stableID])
    }
}
