import Foundation

/// Single source of truth for blood-glucose unit conversion (mg/dL ⇄ mmol/L).
///
/// Replaces the `18.018` factor that was duplicated across the app and widget (iOS iM2).
/// Keeping one definition avoids subtle inconsistencies in a medical calculation.
enum GlucoseUnit {

    /// mg/dL per mmol/L. 1 mmol/L of glucose ≈ 18.018 mg/dL.
    static let mgdlPerMmol: Double = 18.018

    static func mgdlToMmol(_ mgdl: Double) -> Double { mgdl / mgdlPerMmol }
    static func mmolToMgdl(_ mmol: Double) -> Double { mmol * mgdlPerMmol }

    /// True when the unit string denotes mg/dL.
    static func isMgdl(_ unit: String?) -> Bool {
        unit?.lowercased().contains("mg") == true
    }

    /// True when the unit string denotes mmol/L.
    static func isMmol(_ unit: String?) -> Bool {
        unit?.lowercased().contains("mmol") == true
    }

    /// Convert a value expressed in `unit` to mmol/L. Unknown/`nil` units are assumed to already be mmol/L.
    static func toMmol(_ value: Double, unit: String?) -> Double {
        isMgdl(unit) ? mgdlToMmol(value) : value
    }

    /// Convert an mmol/L value into `displayUnit`. Unknown/`nil` units render as mmol/L.
    static func fromMmol(_ mmol: Double, displayUnit: String?) -> Double {
        isMgdl(displayUnit) ? mmolToMgdl(mmol) : mmol
    }
}
