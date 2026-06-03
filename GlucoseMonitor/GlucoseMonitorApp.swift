import SwiftUI
import UIKit

@main
struct GlucoseMonitorApp: App {
    @UIApplicationDelegateAdaptor(GlucoseMonitorAppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
    }
}

// MARK: - Keyboard helpers (app-wide)

func hideKeyboard() {
    UIApplication.shared.sendAction(
        #selector(UIResponder.resignFirstResponder),
        to: nil, from: nil, for: nil
    )
}

extension View {
    /// Dismisses the keyboard when the user scrolls and adds a "Done" button
    /// in the keyboard toolbar — covers both scroll-away and tap-elsewhere UX.
    func dismissKeyboardOnInteraction() -> some View {
        self
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { hideKeyboard() }
                }
            }
    }
}
