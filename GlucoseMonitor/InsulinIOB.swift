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
    static func currentIOBFromNotes(notes: [BackendAPI.GlucoseNote], at date: Date = Date()) -> Double {
        let doses = notes.compactMap { note -> (Date, Double)? in
            guard let ts = note.timestamp, note.insulin > 0 else { return nil }
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
