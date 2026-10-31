import Foundation

/// A quick log shown in the chat, with its Undo state.
struct ChatLoggedEntry: Equatable {
    let summary: String
    let forecastMin: Double?
    /// Message id the undo endpoint takes; nil until the stream's `done` event names it.
    var undoMessageId: String?
    var undone: Bool
}

struct ChatItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case user(text: String, hasPhoto: Bool)
        case assistant(text: String)
        case logged(ChatLoggedEntry)
        case error(String)
        /// The glycemic event engine's pending question, pinned last; `text` is the preview line.
        case glycemicPrompt(BackendAPI.GlycemicEvent, text: String)
        /// Meal prep plan card (Took it / Eating now / Not eating).
        case mealPlan(MealPlanCard)
        /// Past events behind a reply, listed above it. Question replies carry them in history too; plan replies do not.
        case episodes([BackendAPI.AssistantEpisode])
        /// Sources a question reply cites, listed right under it.
        case citations([BackendAPI.AssistantCitation])
        /// A free-text event ("hot shower") proposed as a note: Confirm saves it, No dismisses it locally.
        case eventProposal(EventProposalCard)
        /// A logged note proposed for removal ("remove the 1 U"): Remove deletes it, Keep dismisses locally.
        case noteRemoval(NoteRemovalCard)
    }

    let id: String
    let createdAt: Date
    var kind: Kind
    /// A reply the backend could not finish (history intent `question_failed`); shown muted.
    var isFailed = false

    /// The reply placeholder before its first token arrives (the "thinking..." state).
    var isThinking: Bool { kind == .assistant(text: "") }

    /// One-line text for the dashboard peek.
    var previewText: String {
        switch kind {
        case .user(let text, let hasPhoto): return text.isEmpty && hasPhoto ? "Photo" : text
        case .assistant(let text): return text
        // An undone log (its notes deleted) is history, not news: the peek falls back to the line before it.
        case .logged(let entry): return entry.undone ? "" : entry.summary
        case .error(let message): return message
        case .glycemicPrompt(_, let text): return text
        case .episodes, .citations: return ""
        case .mealPlan(let card): return "Meal plan: \(MealPlanRules.midText(card.plan.carbs)) carbs"
        case .eventProposal(let card): return card.text
        case .noteRemoval(let card): return card.text
        }
    }
}

/// Display formatting for the chat. The backend works in mmol/L; mg/dL users see mg/dL.
enum ChatFormatting {

    static func glucose(mmol: Double, unit: String) -> String {
        GlucoseUnit.isMgdl(unit)
            ? String(format: "%.0f", GlucoseUnit.mmolToMgdl(mmol))
            : String(format: "%.1f", mmol)
    }

    /// e.g. "Unexplained rise 14:10-14:55, +58 mg/dL above forecast. Anything to log?"
    static func promptText(_ event: BackendAPI.GlycemicEvent, unit: String) -> String {
        "\(event.displayLabel): \(GlycemicEventCopy.summary(for: event, displayUnit: unit)). \(GlycemicEventCopy.question(for: event))"
    }

    static func promptConfirmation(category: String, carbs: Double?, insulin: Double?) -> String {
        var text = "Noted: \(GlycemicCategory.buttonTitle(category))"
        if let carbs { text += ", \(backendNumber(carbs)) g" }
        if let insulin { text += ", \(backendNumber(insulin)) U" }
        return text + "."
    }

    static func iobCob(iob: Double?, cob: Double?) -> String {
        let i = iob.map { String(format: "%.1f U", $0) } ?? "--"
        let c = cob.map { String(format: "%.0f g", $0) } ?? "--"
        return "IOB \(i) · COB \(c)"
    }

    /// The backend writes the 4 h forecast low into `summary` in mmol/L ("lowest 5.8", "минимум 5.8").
    /// For mg/dL users that number is replaced with the mg/dL value; everything else is kept as sent.
    static func loggedSummary(_ summary: String, forecastMin: Double?, unit: String) -> String {
        guard let forecastMin, GlucoseUnit.isMgdl(unit) else { return summary }
        let sent = backendNumber(forecastMin)
        let shown = glucose(mmol: forecastMin, unit: unit)
        var result = summary
        for label in ["lowest ", "минимум "] {
            result = result.replacingOccurrences(of: label + sent, with: label + shown)
        }
        return result
    }

    /// Mirrors the backend's `AssistantService.fmt`: one decimal, whole numbers without ".0".
    static func backendNumber(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        return r == r.rounded() ? String(Int(r)) : String(r)
    }
}
