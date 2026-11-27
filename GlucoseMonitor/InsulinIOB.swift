import Foundation

/// Hint shown on the "Long-acting insulin" dashboard action, based on the user's configured daily
/// injection time. It only labels the row ("Due 22:00" / "Log now" / "Next at 22:00"); it never
/// blocks logging - a dose taken early, late or off-schedule must still be loggable.
enum LongActingSchedule {
    /// "Due" is shown from this long before the configured time...
    static let windowBefore: TimeInterval = 60 * 60          // 1 hour
    /// ...and "Log now" until this long after it.
    static let windowAfter: TimeInterval = 4 * 60 * 60       // 4 hours

    struct Status: Equatable {
        /// Short label for the dashboard row (empty when no schedule is configured).
        let label: String
    }

    /// - Parameter injectionTimeHHmm: daily time as "HH:mm", or nil/empty when unset.
    /// Returns an empty label when no time is configured.
    static func status(injectionTimeHHmm: String?,
                       now: Date = Date(),
                       calendar: Calendar = .current) -> Status {
        guard let hhmm = injectionTimeHHmm, !hhmm.isEmpty,
              let base = parse(hhmm, now: now, calendar: calendar) else {
            return Status(label: "")
        }
        // Check the scheduled time on the adjacent days too so the window works across midnight.
        let candidates = [-1, 0, 1].compactMap { calendar.date(byAdding: .day, value: $0, to: base) }
        for target in candidates {
            if now >= target.addingTimeInterval(-windowBefore) && now <= target.addingTimeInterval(windowAfter) {
                let label = now < target ? "Due \(hhmm)" : "Log now"
                return Status(label: label)
            }
        }
        return Status(label: "Next at \(hhmm)")
    }

    private static func parse(_ hhmm: String, now: Date, calendar: Calendar) -> Date? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return calendar.date(bySettingHour: h, minute: m, second: 0, of: now)
    }
}
