import SwiftUI

@main
struct GlucoseMonitorWatchApp: App {
    init() {
        WatchSessionReceiver.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
        }
    }
}
