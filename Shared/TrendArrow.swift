import Foundation

/// CGM trend arrows, shared by the phone, the Apple Watch and its complication.
///
/// Must stay identical to the backend's `PhoneTrendParity`: the watch glance builds its dashboard
/// request with these tables, and the dashboard's alert holds are shared by every caller.
enum TrendArrow {

    /// Arrow for a stored reading: LibreLinkUp `TrendArrow` 1-5 when `libreEntry`, else the Nightscout direction.
    static func arrow(trend: Int?, direction: String?, libreEntry: Bool) -> String {
        if libreEntry {
            guard let t = trend, (1...5).contains(t) else { return "?" }
            return libreArrow(t)
        }
        return directionArrow(direction)
    }

    /// LibreLinkUp `TrendArrow` 1-5 (stable readings are usually 3).
    static func libreArrow(_ trend: Int) -> String {
        switch trend {
        case 1: return "\u{2193}\u{2193}"
        case 2: return "\u{2198}"
        case 3: return "\u{2192}"
        case 4: return "\u{2197}"
        case 5: return "\u{2191}\u{2191}"
        default: return "?"
        }
    }

    static func directionArrow(_ direction: String?) -> String {
        guard let d = direction?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty else {
            return "\u{2192}"
        }
        switch d {
        case "DoubleUp": return "\u{2191}\u{2191}"
        case "SingleUp": return "\u{2191}"
        case "FortyFiveUp": return "\u{2197}"
        case "Flat": return "\u{2192}"
        case "FortyFiveDown": return "\u{2198}"
        case "SingleDown": return "\u{2193}"
        case "DoubleDown": return "\u{2193}\u{2193}"
        default: return "\u{2192}"
        }
    }

    /// Maps a CGM trend arrow string to mmol/L per minute velocity.
    static func velocity(_ arrow: String?) -> Double {
        switch arrow {
        case "\u{2191}\u{2191}": return  0.100
        case "\u{2191}":         return  0.067
        case "\u{2197}":         return  0.033
        case "\u{2192}":         return  0.000
        case "\u{2198}":         return -0.033
        case "\u{2193}":         return -0.067
        case "\u{2193}\u{2193}": return -0.100
        default:                  return  0.000
        }
    }

    /// What to draw: an unknown or missing arrow shows as flat (the lock-screen widget's rule).
    static func display(_ arrow: String?) -> String {
        guard let arrow, !arrow.isEmpty, arrow != "?" else { return "\u{2192}" }
        return arrow
    }
}
