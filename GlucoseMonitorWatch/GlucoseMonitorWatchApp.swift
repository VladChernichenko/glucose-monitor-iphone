import SwiftUI
import WatchKit

@main
struct GlucoseMonitorWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate

    init() {
        WatchSessionReceiver.shared.activate()
        AlertNotifier.setUp()
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
        }
    }
}
