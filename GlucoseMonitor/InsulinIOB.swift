import Foundation

/// OpenAPS exponential IOB (matches web `insulinCalculator.ts` / backend curve).
enum InsulinIOB {
    private static let durationHours: Double = 4.5   // iOS-4 fix: align with backend DEFAULT_DIA_HOURS
    private static let peakMinutes: Double = 55

    static func iobOpenApsExponential(insulinUnits: Double, minsAgo: Double, diaHours: Double, peak: Double) -> Double {
        let end = diaHours * 60
        if minsAgo < 0 || minsAgo >= end || insulinUnits <= 0 { return 0 }
        let denom = 1 - (2 * peak) / end
        if abs(denom) < 1e-5 {
            return insulinUnits * max(0, 1 - minsAgo / end)
        }
        let tau = (peak * (1 - peak / end)) / denom
        let a = (2 * tau) / end
        let expNegEndOverTau = exp(-end / tau)
        let s = 1 / (1 - a + (1 + a) * expNegEndOverTau)
        let expNegTOverTau = exp(-minsAgo / tau)
        let bracket = ((minsAgo * minsAgo) / (tau * end * (1 - a)) - minsAgo / tau - 1) * expNegTOverTau + 1
        var iobContrib = insulinUnits * (1 - s * (1 - a) * bracket)
        if !iobContrib.isFinite {
            iobContrib = insulinUnits * max(0, 1 - minsAgo / end)
        }
        return max(0, min(insulinUnits, iobContrib))
    }

    /// Total IOB from meal/correction notes (insulin > 0), same window as web fallback.
    /// Long-acting (basal) notes are excluded — they are not rapid-acting boluses.
    static func currentIOBFromNotes(notes: [BackendAPI.GlucoseNote], at date: Date = Date()) -> Double {
        let doses = notes.compactMap { note -> (Date, Double)? in
            guard let ts = note.timestamp, note.insulin > 0, !note.isLongActing else { return nil }
            return (ts, note.insulin)
        }
        var total = 0.0
        for (ts, units) in doses {
            let minsAgo = date.timeIntervalSince(ts) / 60
            total += iobOpenApsExponential(
                insulinUnits: units,
                minsAgo: minsAgo,
                diaHours: durationHours,
                peak: peakMinutes
            )
        }
        return max(0, total)
    }
}

/// Decides whether the "Log long-acting insulin" action is available, based on the user's
/// configured daily injection time. The action is enabled within a window around that time so
/// the user logs their basal dose close to when they actually take it.
enum LongActingSchedule {
    /// Action becomes available this long before the configured time…
    static let windowBefore: TimeInterval = 60 * 60          // 1 hour
    /// …and stays available this long after it (to allow logging a little late).
    static let windowAfter: TimeInterval = 4 * 60 * 60       // 4 hours

    struct Status {
        let enabled: Bool
        /// Short label for the dashboard row (empty when no schedule is configured).
        let label: String
    }

    /// - Parameter injectionTimeHHmm: daily time as "HH:mm", or nil/empty when unset.
    /// Returns `enabled = true` with an empty label when no time is configured (always available).
    static func status(injectionTimeHHmm: String?,
                       now: Date = Date(),
                       calendar: Calendar = .current) -> Status {
        guard let hhmm = injectionTimeHHmm, !hhmm.isEmpty,
              let base = parse(hhmm, now: now, calendar: calendar) else {
            return Status(enabled: true, label: "")
        }
        // Check the scheduled time on the adjacent days too so the window works across midnight.
        let candidates = [-1, 0, 1].compactMap { calendar.date(byAdding: .day, value: $0, to: base) }
        for target in candidates {
            if now >= target.addingTimeInterval(-windowBefore) && now <= target.addingTimeInterval(windowAfter) {
                let label = now < target ? "Due \(hhmm)" : "Log now"
                return Status(enabled: true, label: label)
            }
        }
        return Status(enabled: false, label: "Next at \(hhmm)")
    }

    private static func parse(_ hhmm: String, now: Date, calendar: Calendar) -> Date? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return calendar.date(bySettingHour: h, minute: m, second: 0, of: now)
    }
}
