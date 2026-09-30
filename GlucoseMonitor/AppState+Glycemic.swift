import Foundation

/// Glycemic events: fetch for the chart, the one-tap prompt, answers, and device-local snooze.
/// Mirrors the hypo-prompt rules - a failed fetch never clears what is shown, and an in-flight answer
/// blocks a second tap until it succeeds or fails.
extension AppState {

    static let glycemicSnoozeKey = "glycemicSnoozedEventIds"
    private static let maxSnoozed = 50

    /// The prompt to show: hidden while a hypo prompt is open (a hypo always wins) or when snoozed here.
    var visibleGlycemicPrompt: BackendAPI.GlycemicEvent? {
        guard openHypoEvent == nil, let prompt = glycemicPrompt, !snoozedGlycemicIds.contains(prompt.id) else { return nil }
        return prompt
    }

    private var snoozedGlycemicIds: [String] {
        UserDefaults.standard.stringArray(forKey: Self.glycemicSnoozeKey) ?? []
    }

    func refreshGlycemicEvents() async {
        let now = Date()
        do {
            glycemicEvents = try await BackendAPI.fetchGlycemicEvents(from: now.addingTimeInterval(-24 * 3600),
                                                                      to: now.addingTimeInterval(3600))
        } catch {
            // Keep the markers already on screen.
        }
    }

    func refreshGlycemicPrompt() async {
        do {
            glycemicPrompt = try await BackendAPI.fetchGlycemicPrompt()
        } catch {
            // A failed poll must never yank the card away mid-answer.
        }
    }

    func answerGlycemicPrompt(category: String, carbs: Double? = nil, insulin: Double? = nil) async -> Bool {
        guard let event = glycemicPrompt else { return true }
        return await answerGlycemicEvent(event, category: category, carbs: carbs, insulin: insulin)
    }

    func answerGlycemicEvent(_ event: BackendAPI.GlycemicEvent, category: String?, carbs: Double? = nil,
                             insulin: Double? = nil) async -> Bool {
        guard !isAnsweringGlycemicPrompt else { return true }
        isAnsweringGlycemicPrompt = true
        defer { isAnsweringGlycemicPrompt = false }
        do {
            _ = try await BackendAPI.confirmGlycemicEvent(id: event.id, category: category, carbs: carbs, insulin: insulin)
            if glycemicPrompt?.id == event.id { glycemicPrompt = nil }
            await refreshGlycemicEvents()
            return true
        } catch {
            errorMessage = "Couldn't save your answer. Try again."
            return false
        }
    }

    func dismissGlycemicPrompt() async -> Bool {
        guard let event = glycemicPrompt else { return true }
        return await dismissGlycemicEvent(event)
    }

    func dismissGlycemicEvent(_ event: BackendAPI.GlycemicEvent) async -> Bool {
        guard !isAnsweringGlycemicPrompt else { return true }
        isAnsweringGlycemicPrompt = true
        defer { isAnsweringGlycemicPrompt = false }
        do {
            _ = try await BackendAPI.dismissGlycemicEvent(id: event.id)
            if glycemicPrompt?.id == event.id { glycemicPrompt = nil }
            await refreshGlycemicEvents()
            return true
        } catch {
            errorMessage = "Couldn't save your answer. Try again."
            return false
        }
    }

    /// Logout: the previous user's markers, questions and device-local snoozes must not carry over.
    func clearEventPromptState() {
        glycemicEvents = []
        glycemicPrompt = nil
        isAnsweringGlycemicPrompt = false
        openHypoEvent = nil
        UserDefaults.standard.removeObject(forKey: Self.glycemicSnoozeKey)
    }

    /// "Not sure": hide this event's question on this device only. It stays OPEN server-side and can be
    /// answered later from the event list.
    func snoozeGlycemicPrompt() {
        guard let prompt = glycemicPrompt else { return }
        var ids = snoozedGlycemicIds.filter { $0 != prompt.id }
        ids.append(prompt.id)
        UserDefaults.standard.set(Array(ids.suffix(Self.maxSnoozed)), forKey: Self.glycemicSnoozeKey)
        objectWillChange.send()
    }
}
