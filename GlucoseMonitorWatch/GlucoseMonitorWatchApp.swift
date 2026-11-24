import SwiftUI

@main
struct GlucoseMonitorWatchApp: App {
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
