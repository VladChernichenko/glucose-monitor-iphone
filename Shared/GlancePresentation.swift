import Foundation

/// What the Apple Watch screen and complication draw from a glance, with the phone's rules:
/// an old or flagged reading is greyed and loses its forecast and strip; an expired dose and a strip
/// from a calculation over 10 min old are never shown.
struct GlancePresentation: Equatable {

    struct Banner: Equatable {
        let title: String
        let detail: String
        /// Red (urgent) or green (calm) for a strip; stale banners are orange and never urgent.
        let urgent: Bool
    }

    enum RangeColor: Equatable { case low, inRange, high, urgent, none }

    /// A reading older than this is not shown as current (`CgmFreshnessService.MAX_AGE`, `LockScreenWidgetSnapshot.staleAfter`).
    static let staleAfter: TimeInterval = 15 * 60
    /// A strip from a calculation older than this is not shown (`AppState.watchStripMaxAge`).
    static let stripMaxAge: TimeInterval = 600

    let valueText: String
    let arrow: String
    let unitLabel: String
    let readingAt: Date?
    let isStale: Bool
    let predictionText: String?
    let rangeColor: RangeColor
    let stale: Banner?
    let strip: Banner?

    init(glance: WatchGlance, now: Date, fetchedAt: Date, unit: String) {
        let reading = glance.reading
        unitLabel = GlucoseText.unitLabel(unit)
        readingAt = reading?.at
        valueText = reading.map { GlucoseText.glucose(mmol: $0.mmol, unit: unit) } ?? "--"
        arrow = reading.map { TrendArrow.display($0.arrow) } ?? ""

        let tooOld = reading.map { now.timeIntervalSince($0.at) > Self.staleAfter } ?? true
        isStale = tooOld || glance.staleCause != .none

        stale = LibreStaleCause(glance.staleCause).map {
            Banner(title: $0.title, detail: $0.detail(lastReading: reading?.at, now: now), urgent: false)
        }

        if isStale {
            predictionText = nil
            rangeColor = .none
            strip = nil
            return
        }
        predictionText = glance.twoHourPredictionMmol.map { GlucoseText.glucose(mmol: $0, unit: unit) }
        rangeColor = reading.map { Self.color($0.mmol) } ?? .none
        if let s = glance.watch, s.isKnown, !s.suggestionExpired(at: now),
           now.timeIntervalSince(fetchedAt) <= Self.stripMaxAge {
            strip = Banner(title: WatchStripText.headline(s, unit: unit), detail: WatchStripText.detail(s, unit: unit),
                           urgent: s.state != .calm)
        } else {
            strip = nil
        }
    }

    private static func color(_ mmol: Double) -> RangeColor {
        if mmol < 3.5 || mmol >= 14 { return .urgent }
        if mmol < 4.0 { return .low }
        if mmol >= 10.0 { return .high }
        return .inRange
    }
}
