import Foundation

/// One glucose reading as Siri needs it. Always in mmol/L; converted to the display unit only when spoken.
struct SiriGlucoseReading: Equatable {
    var mmol: Double
    /// CGM sample time (not the time it was fetched).
    var time: Date
    /// Change vs the previous reading, mmol/L. Used only to keep the widget snapshot consistent.
    var deltaMmol: Double?
    var trendArrow: String?
    /// The app knows the source is stale (LibreLinkUp unavailable).
    var flaggedStale: Bool
}

/// What Siri says, and when a cached reading may be trusted without a network call.
enum SiriGlucoseAnswer {
    /// The backend refreshes about every 5 minutes, so a cached reading this young cannot be improved on.
    static let freshCacheWindow: TimeInterval = 5 * 60

    static let unavailableText = "I can't get your blood sugar right now."

    static func isCacheFresh(_ reading: SiriGlucoseReading, now: Date) -> Bool {
        !reading.flaggedStale && age(of: reading, now: now) <= freshCacheWindow
    }

    static func spokenText(_ reading: SiriGlucoseReading?, displayUnit: String, now: Date) -> String {
        guard let reading else { return unavailableText }
        let value = formattedValue(reading.mmol, displayUnit: displayUnit)
        let age = age(of: reading, now: now)
        if !reading.flaggedStale && age <= LockScreenWidgetSnapshot.staleAfter {
            return "Your blood sugar is \(value)."
        }
        return "Your last reading was \(agePhrase(age)): \(value)."
    }

    /// Never negative: a phone clock slightly behind the backend must not read as "-1 minutes ago".
    private static func age(of reading: SiriGlucoseReading, now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(reading.time))
    }

    private static func formattedValue(_ mmol: Double, displayUnit: String) -> String {
        if GlucoseUnit.isMgdl(displayUnit) {
            return String(format: "%.0f mg/dL", GlucoseUnit.mmolToMgdl(mmol))
        }
        return String(format: "%.1f mmol/L", mmol)
    }

    private static func agePhrase(_ age: TimeInterval) -> String {
        let minutes = max(1, Int(age / 60))
        if minutes >= 60 {
            let hours = minutes / 60
            return "\(hours) hour\(hours == 1 ? "" : "s") ago"
        }
        return "\(minutes) minute\(minutes == 1 ? "" : "s") ago"
    }
}
