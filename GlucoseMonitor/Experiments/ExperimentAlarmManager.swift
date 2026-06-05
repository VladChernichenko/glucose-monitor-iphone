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

    /// Schedule checkpoint alarms for an experiment starting now.
    func scheduleAlarms(for type: ExperimentType, experimentId: UUID) async {
        await requestPermissionIfNeeded()

        // Cancel any leftover alarms from a previous experiment
        await cancelAlarms(for: experimentId)

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }

        for alarm in type.alarmSchedule {
            let content = UNMutableNotificationContent()
            content.title  = type.title
            content.body   = alarm.message
            content.sound  = .default
            content.userInfo = ["experimentId": experimentId.uuidString, "type": type.rawValue]

            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: TimeInterval(alarm.minutes * 60),
                repeats: false
            )
            let id = notificationId(experimentId: experimentId, minutes: alarm.minutes)
            let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
            try? await center.add(request)
        }
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
