import Foundation
import WatchConnectivity
import WatchKit
import WidgetKit

/// One path for every fetch, foreground or background: glance → store → wrist tap → complication.
enum GlanceRefresher {

    /// watchOS grants a few background refreshes an hour (more with the complication on the active face).
    static let interval: TimeInterval = 15 * 60

    /// False when there is no session or the fetch failed; the stored glance is then left as it was.
    @discardableResult
    static func refresh(now: Date = Date()) async -> Bool {
        guard !(GlucoseMonitorAPI.storedRefreshToken()?.isEmpty ?? true) else { return false }
        do {
            let glance = try await GlanceClient.fetch()
            GlanceStore.save(glance, fetchedAt: now)
            AlertNotifier.handle(glance, now: now)
            WidgetCenter.shared.reloadAllTimelines()
            return true
        } catch {
            return false
        }
    }

    static func scheduleNext() {
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: Date().addingTimeInterval(interval), userInfo: nil) { _ in }
    }
}

/// Background refresh and WatchConnectivity wake-ups.
final class WatchAppDelegate: NSObject, WKApplicationDelegate {

    func applicationDidFinishLaunching() {
        GlanceRefresher.scheduleNext()
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            switch task {
            case let refresh as WKApplicationRefreshBackgroundTask:
                Task {
                    await GlanceRefresher.refresh()
                    GlanceRefresher.scheduleNext()
                    refresh.setTaskCompletedWithSnapshot(false)
                }
            case let connectivity as WKWatchConnectivityRefreshBackgroundTask:
                // Keep the app awake until the phone's queued messages (session, sign-out) are delivered.
                Task {
                    for _ in 0..<10 where WCSession.default.hasContentPending {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                    connectivity.setTaskCompletedWithSnapshot(false)
                }
            default:
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}
