import Foundation
import WidgetKit

/// Real-world plumbing behind the Siri intent: backend entries and the widget snapshot in, `SiriGlucoseReading` out.
/// Deliberately independent of `AppState` (which is main-actor bound and may not even exist when Siri runs the intent).
enum SiriLiveReading {

    /// Newest usable sgv reading. Backend order varies, so entries are sorted here; entries without a value
    /// or timestamp are skipped rather than hiding an older usable one.
    static func latest(from entries: [BackendAPI.NightscoutEntry], isLLU: Bool) -> SiriGlucoseReading? {
        let usable = entries
            .filter { $0.type == nil || $0.type?.lowercased() == "sgv" }
            .compactMap { e -> (time: Date, sgv: Double, entry: BackendAPI.NightscoutEntry)? in
                guard let time = e.timestamp, let sgv = e.sgv else { return nil }
                return (time, sgv, e)
            }
            .sorted { $0.time > $1.time }
        guard let newest = usable.first else { return nil }
        let delta = usable.dropFirst().first.map { GlucoseUnit.mgdlToMmol(newest.sgv - $0.sgv) }
        return SiriGlucoseReading(
            mmol: GlucoseUnit.mgdlToMmol(newest.sgv),
            time: newest.time,
            deltaMmol: delta,
            trendArrow: newest.entry.toLibreGlucoseCurrent(isLLU: isLLU).trendArrow,
            flaggedStale: false
        )
    }

    /// The cached reading, or nil when the snapshot has no value yet (e.g. the app was never opened).
    static func reading(from snapshot: LockScreenWidgetSnapshot) -> SiriGlucoseReading? {
        guard let value = snapshot.glucoseValue else { return nil }
        return SiriGlucoseReading(
            mmol: GlucoseUnit.toMmol(value, unit: snapshot.glucoseUnit),
            time: snapshot.savedAt,
            deltaMmol: snapshot.deltaValue.map { GlucoseUnit.toMmol($0, unit: snapshot.glucoseUnit) },
            trendArrow: snapshot.trendArrow,
            flaggedStale: snapshot.dataStale == true
        )
    }

    /// Writes a fetched reading into the snapshot so the widget and the next Siri call benefit,
    /// leaving IOB, COB, the prediction and the chart as the app last wrote them.
    static func merged(_ reading: SiriGlucoseReading, into snapshot: LockScreenWidgetSnapshot) -> LockScreenWidgetSnapshot {
        var merged = snapshot
        merged.glucoseValue = GlucoseUnit.fromMmol(reading.mmol, displayUnit: snapshot.glucoseUnit)
        merged.deltaValue = reading.deltaMmol.map { GlucoseUnit.fromMmol($0, displayUnit: snapshot.glucoseUnit) }
        merged.trendArrow = reading.trendArrow
        // IOB, COB and the forecast were computed when the app last refreshed. If that was long before this
        // reading, showing them beside it would present old numbers as current, so drop them (the app
        // recomputes them on its next refresh). The chart is just history and stays.
        if reading.time.timeIntervalSince(snapshot.savedAt) > LockScreenWidgetSnapshot.staleAfter {
            merged.twoHourPredictionMmol = nil
            merged.iobUnits = nil
            merged.cobGrams = nil
        }
        merged.savedAt = reading.time
        merged.dataStale = reading.flaggedStale
        return merged
    }

    /// The unit the user chose in Settings (same shared-defaults key the app writes).
    static func displayUnit() -> String {
        GlucoseMonitorAPI.sharedDefaults().string(forKey: GlucoseMonitorAPI.StorageKey.glucoseDisplayUnit) ?? "mmol/L"
    }

    /// Cache = widget snapshot; live = the same two backend calls `AppState.loadGlucoseHistory` uses.
    static var source: SiriReadingSource {
        SiriReadingSource(
            loadCached: {
                LockScreenWidgetSnapshot.load().flatMap { reading(from: $0) }
            },
            fetchLatest: {
                let isNightscout = GlucoseMonitorAPI.sharedDefaults()
                    .string(forKey: GlucoseMonitorAPI.StorageKey.dataSource) == "nightscout"
                let entries = isNightscout
                    ? try await BackendAPI.fetchNightscoutEntriesWithFallbacks(count: 3)
                    : try await BackendAPI.fetchNightscoutChartData(count: 3)
                return latest(from: entries, isLLU: !isNightscout)
            },
            storeFetched: { fetched in
                guard let snapshot = LockScreenWidgetSnapshot.load() else { return }
                merged(fetched, into: snapshot).save()
                LockScreenWidgetSnapshot.allWidgetKinds.forEach { WidgetCenter.shared.reloadTimelines(ofKind: $0) }
            }
        )
    }
}
