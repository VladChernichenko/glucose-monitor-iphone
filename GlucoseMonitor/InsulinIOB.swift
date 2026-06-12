import Foundation

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
