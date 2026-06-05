import Foundation
import UserNotifications

/// Schedules and cancels local notifications for experiment checkpoints.
@MainActor
final class ExperimentAlarmManager {

    static let shared = ExperimentAlarmManager()
    private init() {}

    // MARK: - Permission

    func requestPermissionIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    // MARK: - Schedule

    /// Schedule alarms for an experiment starting now.
    /// Fixed-interval "record your glucose" reminders are omitted — readings are
    /// auto-captured from the CGM. Safety alerts are fired dynamically by
    /// ExperimentRunView via fireSafetyNotification(_:title:body:).
    func scheduleAlarms(for type: ExperimentType, experimentId: UUID) async {
        await requestPermissionIfNeeded()
        await cancelAlarms(for: experimentId)
    }

    /// Fire an immediate safety notification. The same `id` will not fire again
    /// within 30 minutes to prevent alert spam.
    func fireSafetyNotification(id: String, title: String, body: String) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }

        // Enforce 30-minute cooldown using a pending-notification sentinel
        let cooldownId = "safety-cooldown-\(id)"
        let pending = await center.pendingNotificationRequests()
        if pending.contains(where: { $0.identifier == cooldownId }) { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body  = body
        content.sound = .default
        if #available(iOS 15, *) { content.interruptionLevel = .timeSensitive }

        // Fire in 1 s
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let notifId = "safety-\(id)"
        center.removePendingNotificationRequests(withIdentifiers: [notifId])
        let request = UNNotificationRequest(identifier: notifId, content: content, trigger: trigger)
        try? await center.add(request)

        // Schedule a 30-minute silent sentinel so the cooldown check above fires
        let sentinel = UNMutableNotificationContent()
        sentinel.title = ""
        sentinel.body  = ""
        let sentinelTrigger = UNTimeIntervalNotificationTrigger(timeInterval: 30 * 60, repeats: false)
        let sentinelRequest = UNNotificationRequest(identifier: cooldownId, content: sentinel, trigger: sentinelTrigger)
        try? await center.add(sentinelRequest)
    }

    /// Schedule a "background is clean, you can start your experiment" notification.
    func scheduleBackgroundCleanNotification(in minutes: Int, experimentType: ExperimentType) async {
        await requestPermissionIfNeeded()
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }

        let content = UNMutableNotificationContent()
        content.title = "🧹 Background Clean"
        content.body  = "Your IOB and COB are clear — you can start the \(experimentType.title) now."
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: TimeInterval(max(minutes, 1) * 60),
            repeats: false
        )
        let id = "background-clean-\(experimentType.rawValue)"
        await center.removePendingNotificationRequests(withIdentifiers: [id])
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        try? await center.add(request)
    }

    // MARK: - Cancel

    func cancelAlarms(for experimentId: UUID) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let ids = pending
            .filter { $0.identifier.hasPrefix("exp-\(experimentId.uuidString)") }
            .map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    // MARK: - Helpers

    private func notificationId(experimentId: UUID, minutes: Int) -> String {
        "exp-\(experimentId.uuidString)-\(minutes)min"
    }
}
