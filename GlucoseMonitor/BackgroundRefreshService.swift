import BackgroundTasks
import UIKit

/// Schedules BGAppRefresh and exposes hooks for foreground/background glucose sync.
enum BackgroundRefreshService {
    static let taskIdentifier = "com.che.glucosemonitor.background-refresh"

    static func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handleAppRefresh(task: refreshTask)
        }
    }

    static func scheduleNextRefresh(earliestBeginDate: Date? = nil) {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = earliestBeginDate ?? Date(timeIntervalSinceNow: 5 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Already scheduled or not permitted; safe to ignore.
        }
    }

    /// iOS grants ~30s after backgrounding; use it to refresh before the next launch.
    static func runBackgroundFetchIfNeeded() {
        Task { @MainActor in
            guard AppState.shared?.isAuthenticated == true else { return }
            var taskId: UIBackgroundTaskIdentifier = .invalid
            taskId = UIApplication.shared.beginBackgroundTask(withName: "GlucoseRefresh") {
                if taskId != .invalid {
                    UIApplication.shared.endBackgroundTask(taskId)
                    taskId = .invalid
                }
            }
            guard taskId != .invalid else { return }

            await AppState.shared?.refreshGlucoseInBackground()
            AppState.shared?.reloadWidgetTimelines()
            scheduleNextRefresh()
            if taskId != .invalid {
                UIApplication.shared.endBackgroundTask(taskId)
            }
        }
    }

    private static func handleAppRefresh(task: BGAppRefreshTask) {
        scheduleNextRefresh()

        let work = Task { @MainActor in
            await AppState.shared?.refreshGlucoseInBackground()
            AppState.shared?.reloadWidgetTimelines()
            task.setTaskCompleted(success: true)
        }

        task.expirationHandler = {
            work.cancel()
            task.setTaskCompleted(success: false)
        }
    }
}

final class GlucoseMonitorAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BackgroundRefreshService.register()
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        BackgroundRefreshService.scheduleNextRefresh()
        BackgroundRefreshService.runBackgroundFetchIfNeeded()
    }
}
