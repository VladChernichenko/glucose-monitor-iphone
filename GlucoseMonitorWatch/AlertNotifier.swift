import Foundation
import UserNotifications

/// Taps the wrist with a local notification when `AlertBuzzPolicy` says so.
enum AlertNotifier {

    static let memoryKey = "gm_watch_buzz_memory_v1"
    /// One identifier: a new alert replaces the previous one in Notification Center.
    static let requestIdentifier = "glucose-alert"

    private static let presenter = ForegroundPresenter()

    /// Call once at launch: asks for permission and shows alerts even while the app is open.
    static func setUp() {
        let center = UNUserNotificationCenter.current()
        center.delegate = presenter
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Runs the policy on a freshly fetched glance and posts the tap it asks for.
    static func handle(_ glance: WatchGlance, now: Date = Date()) {
        let ud = GlucoseMonitorAPI.sharedDefaults()
        let unit = ud.string(forKey: GlucoseMonitorAPI.StorageKey.glucoseDisplayUnit) ?? "mmol/L"
        let decision = AlertBuzzPolicy.decide(memory: memory(), glance: glance, now: now, unit: unit)
        if let data = try? JSONEncoder().encode(decision.memory) { ud.set(data, forKey: memoryKey) }
        if decision.clearDelivered {
            // Its alert ended or its advice passed the recheck time: an old dose must not stay on the wrist.
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [requestIdentifier])
        }
        if let buzz = decision.buzz { post(buzz) }
    }

    static func post(_ buzz: Buzz) {
        let content = UNMutableNotificationContent()
        content.title = buzz.title
        content.body = buzz.body
        content.sound = .default
        // Breaks through Focus only when the entitlement is granted; otherwise the system treats it as .active.
        content.interruptionLevel = .timeSensitive
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: requestIdentifier, content: content, trigger: nil))
    }

    private static func memory() -> BuzzMemory {
        guard let data = GlucoseMonitorAPI.sharedDefaults().data(forKey: memoryKey),
              let m = try? JSONDecoder().decode(BuzzMemory.self, from: data) else { return BuzzMemory() }
        return m
    }

    private final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
            completionHandler([.banner, .sound, .list])
        }
    }
}
