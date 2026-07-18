import Foundation

/// Cached dashboard data for the Lock Screen widget (written by the iOS app, read by the widget extension).
public struct LockScreenWidgetSnapshot: Codable, Sendable {
    public static let storageKey = "gm_lock_screen_widget_snapshot_v1"
    /// Must match `GlucoseLockScreenWidget.kind` in the widget extension target.
    public static let widgetKind = "GlucoseMonitorLockScreenWidget"

    public var savedAt: Date
    /// Display glucose in the user's preferred unit (mmol/L values as stored by the app).
    public var glucoseValue: Double?
    public var glucoseUnit: String
    public var trendArrow: String?
    /// Change vs previous reading in the same unit as `glucoseValue`.
    public var deltaValue: Double?
    public var cobGrams: Double?
    public var iobUnits: Double?
    /// Backend 2h prediction in mmol/L (same as `GlucoseCalculations.twoHourPrediction`).
    public var twoHourPredictionMmol: Double?
    public var chartPoints: [ChartPoint]

    public struct ChartPoint: Codable, Sendable {
        public var time: Date
        public var mmol: Double
        public init(time: Date, mmol: Double) {
            self.time = time
            self.mmol = mmol
        }
    }

    public init(
        savedAt: Date,
        glucoseValue: Double?,
        glucoseUnit: String,
        trendArrow: String?,
        deltaValue: Double?,
        cobGrams: Double?,
        iobUnits: Double?,
        twoHourPredictionMmol: Double? = nil,
        chartPoints: [ChartPoint]
    ) {
        self.savedAt = savedAt
        self.glucoseValue = glucoseValue
        self.glucoseUnit = glucoseUnit
        self.trendArrow = trendArrow
        self.deltaValue = deltaValue
        self.cobGrams = cobGrams
        self.iobUnits = iobUnits
        self.twoHourPredictionMmol = twoHourPredictionMmol
        self.chartPoints = chartPoints
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }

    public func save() {
        guard let data = try? Self.encoder.encode(self) else { return }
        GlucoseMonitorAPI.sharedDefaults().set(data, forKey: Self.storageKey)
    }

    public static func load() -> LockScreenWidgetSnapshot? {
        guard let data = GlucoseMonitorAPI.sharedDefaults().data(forKey: storageKey) else { return nil }
        return try? decoder.decode(LockScreenWidgetSnapshot.self, from: data)
    }

    /// No data yet (user should open the main app while signed in).
    public static var empty: LockScreenWidgetSnapshot {
        LockScreenWidgetSnapshot(
            savedAt: Date(),
            glucoseValue: nil,
            glucoseUnit: "mmol/L",
            trendArrow: nil,
            deltaValue: nil,
            cobGrams: nil,
            iobUnits: nil,
            twoHourPredictionMmol: nil,
            chartPoints: []
        )
    }

    /// mmol/L for coloring and sparkline; converts from display if needed.
    public func glucoseMmolForColoring() -> Double? {
        guard let v = glucoseValue else { return nil }
        if glucoseUnit.lowercased().contains("mg") { return v / 18.018 }
        return v
    }

    public func chartPointsMmol() -> [ChartPoint] { chartPoints }

    /// Start of the "reading age" timer (CGM sample time when known).
    public var readingAgeStart: Date { savedAt }

    /// Sample layout for Xcode previews and placeholder timeline.
    public static var preview: LockScreenWidgetSnapshot {
        let now = Date()
        let pts = (0..<16).map { i in
            ChartPoint(time: now.addingTimeInterval(Double(i - 16) * 900), mmol: 7.5 + sin(Double(i) * 0.4) * 1.2)
        }
        return LockScreenWidgetSnapshot(
            savedAt: now,
            glucoseValue: 8.3,
            glucoseUnit: "mmol/L",
            trendArrow: "Flat",
            deltaValue: 0.7,
            cobGrams: 0,
            iobUnits: 0.14,
            twoHourPredictionMmol: 6.2,
            chartPoints: pts
        )
    }
}
