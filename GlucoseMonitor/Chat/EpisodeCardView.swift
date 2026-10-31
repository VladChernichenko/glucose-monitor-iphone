import SwiftUI

/// Compact list of the past events an answer is based on (spec screens 3 and 8):
/// `date · food text · dose · peak ✓/✗`. Glucose is shown in the user's unit.
struct EpisodeCardView: View {
    let episodes: [BackendAPI.AssistantEpisode]
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(EpisodeFormatting.title(episodes)).font(.subheadline.weight(.semibold))
            ForEach(episodes) { episode in
                let row = EpisodeFormatting.row(episode, unit: unit)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(row.text)
                        .font(.footnote)
                        .foregroundStyle(episode.contaminated == true ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let mark = row.mark {
                        Text(mark ? "✓" : "✗")
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(mark ? Color.green : Color.red)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.25)))
        .accessibilityElement(children: .contain)
    }
}

/// Text of an episode row; separate from the view so it can be tested.
enum EpisodeFormatting {
    /// In range (mmol/L) for the ✓/✗ mark.
    static let low = 3.9
    static let high = 10.0

    struct Row: Equatable {
        let text: String
        /// true = in range / hit, false = out of range / miss, nil = nothing to judge.
        let mark: Bool?
    }

    static func title(_ episodes: [BackendAPI.AssistantEpisode]) -> String {
        let kinds = Set(episodes.map(\.kind))
        if kinds == [.MEAL] { return "Similar meals" }
        if kinds == [.CORRECTION] { return "Past corrections" }
        if kinds == [.ACTIVITY] { return "Past activity" }
        if kinds == [.LOW] { return "Past lows" }
        return "Past events"
    }

    static func row(_ e: BackendAPI.AssistantEpisode, unit: String) -> Row {
        func g(_ v: Double) -> String { ChatFormatting.glucose(mmol: v, unit: unit) }
        var parts = [dateLabel(e.at)]
        if let text = e.text, !text.isEmpty { parts.append(text) }
        if let dose = e.doseUnits { parts.append(String(format: "%.1f U", dose)) }
        var mark: Bool?
        switch e.kind {
        case .MEAL:
            if let peak = e.peak {
                parts.append("peak \(g(peak))")
                mark = peak <= high && (e.nadir ?? low) >= low
            }
        case .CORRECTION:
            if let after = e.g120 ?? e.g240 {
                parts.append("\(g(after)) after \(e.g120 != nil ? "2" : "4") h")
                mark = after >= low && after <= high
            }
        case .ACTIVITY:
            if let m = e.activityMinutes { parts.append("\(m) min") }
            if let nadir = e.nadir {
                parts.append("low \(g(nadir))")
                mark = nadir >= low
            }
        case .LOW:
            if let nadir = e.nadir {
                parts.append("low \(g(nadir))")
                mark = false
            }
        }
        return Row(text: parts.joined(separator: " · "), mark: mark)
    }

    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// "Oct 12" from the wall-clock `yyyy-MM-ddTHH:mm`; the raw text if it does not parse.
    static func dateLabel(_ at: String) -> String {
        let day = at.prefix(10).split(separator: "-")
        guard day.count == 3, let m = Int(day[1]), (1...12).contains(m), let d = Int(day[2]) else { return at }
        return "\(months[m - 1]) \(d)"
    }
}
