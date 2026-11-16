import AppIntents

/// "Hey Siri, what is my blood sugar in Glucose Monitor": speaks the current glucose, also with the phone locked.
/// Thin on purpose: all decisions live in `SiriGlucoseResolver` / `SiriGlucoseAnswer`, which are unit-tested.
/// It must not touch `AppState`; Siri may run this with the app not running.
struct CurrentGlucoseIntent: AppIntent {
    static let title: LocalizedStringResource = "Current Blood Sugar"
    static let description = IntentDescription("Hears your current blood sugar.")

    /// Answer without unlocking the phone (the user still has to allow Siri when locked in Settings).
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let reading = await SiriGlucoseResolver.resolve(SiriLiveReading.source)
        let text = SiriGlucoseAnswer.spokenText(reading, displayUnit: SiriLiveReading.displayUnit(), now: Date())
        return .result(dialog: "\(text)")
    }
}

struct GlucoseShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CurrentGlucoseIntent(),
            phrases: [
                "What is my blood sugar in \(.applicationName)",
                "What's my glucose in \(.applicationName)",
                "Check my blood sugar in \(.applicationName)",
            ],
            shortTitle: "Blood Sugar",
            systemImageName: "drop.fill"
        )
    }
}
