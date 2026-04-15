import Foundation
import SwiftUI
import UIKit
import WidgetKit

// MARK: - Local glucose prediction (IOB + COB + trend)

/// Builds a prediction path using:
///   • OpenAPS exponential IOB curve
///   • Linear carb absorption (duration depends on absorption mode)
///   • Short-horizon trend extrapolation (asymptotic, 15-min time constant)
///
/// Parameters are population-average defaults for T1D.
private enum GlucosePrediction {

    /// Insulin Sensitivity Factor: mmol/L drop per unit of insulin.
    static let isf: Double = 2.5
    /// Insulin-to-Carb ratio: grams covered per unit.
    static let icr: Double = 10.0
    private static let stepMinutes: Double = 5

    /// Generate prediction points from `now` forward.
    /// Horizon: until active IOB + COB expire, clamped to [2 h, 4 h].
    static func localPath(
        currentGlucose: Double,
        history: [GlucoseChartPoint],
        notes: [BackendAPI.GlucoseNote],
        now: Date = Date()
    ) -> [PredictionChartPoint] {
        guard currentGlucose > 0 else { return [] }

        let velocity   = recentVelocity(history: history, now: now)
        let horizonMin = horizon(notes: notes, now: now)
        let iobNow     = InsulinIOB.currentIOBFromNotes(notes: notes, at: now)

        var points: [PredictionChartPoint] = []
        var t = stepMinutes
        while t <= horizonMin {
            let future = now.addingTimeInterval(t * 60)

            // Trend: asymptotic toward (velocity × 15 min), time-constant 15 min
            let trend = velocity * 15.0 * (1.0 - exp(-t / 15.0))

            // Insulin drop: ISF × IOB consumed between now and future
            let iobFuture   = InsulinIOB.currentIOBFromNotes(notes: notes, at: future)
            let insulinDrop = isf * max(0, iobNow - iobFuture)

            // Carb rise: (ISF/ICR) × grams absorbed now→future
            let carbRise = (isf / icr) * totalCarbsAbsorbed(notes: notes, from: now, to: future)

            let predicted = max(2.0, min(22.0, currentGlucose + trend - insulinDrop + carbRise))
            points.append(PredictionChartPoint(time: future, mmol: predicted))
            t += stepMinutes
        }
        return points
    }

    // MARK: Helpers

    private static func recentVelocity(history: [GlucoseChartPoint], now: Date) -> Double {
        let window = history.filter { now.timeIntervalSince($0.time) <= 20 * 60 }
        guard window.count >= 2, let first = window.first, let last = window.last else { return 0 }
        let dtMin = last.time.timeIntervalSince(first.time) / 60
        guard dtMin > 1 else { return 0 }
        return (last.mmol - first.mmol) / dtMin
    }

    private static func horizon(notes: [BackendAPI.GlucoseNote], now: Date) -> Double {
        var maxMin = 120.0
        for note in notes {
            guard let t0 = note.timestamp, t0 <= now else { continue }
            if note.insulin > 0 {
                let left = t0.addingTimeInterval(4 * 3600).timeIntervalSince(now) / 60
                if left > 0 { maxMin = max(maxMin, left) }
            }
            if note.carbs > 0 {
                let dur  = absorptionDuration(for: note.absorptionMode)
                let left = t0.addingTimeInterval(dur * 60).timeIntervalSince(now) / 60
                if left > 0 { maxMin = max(maxMin, left) }
            }
        }
        return min(240, maxMin)
    }

    private static func totalCarbsAbsorbed(
        notes: [BackendAPI.GlucoseNote],
        from: Date,
        to: Date
    ) -> Double {
        notes.reduce(0.0) { sum, note in
            guard let t0 = note.timestamp, note.carbs > 0, t0 <= from else { return sum }
            let dur      = absorptionDuration(for: note.absorptionMode)
            let fracFrom = min(1, max(0, from.timeIntervalSince(t0) / 60 / dur))
            let fracTo   = min(1, max(0, to.timeIntervalSince(t0)   / 60 / dur))
            return sum + note.carbs * (fracTo - fracFrom)
        }
    }

    private static func absorptionDuration(for mode: String?) -> Double {
        switch mode?.lowercased() {
        case "fast": return 90
        case "slow": return 300
        default:     return 180
        }
    }
}

// MARK: - App state

/// Observable app state (auth, dashboard data, notes); mirrors web AuthContext + EnhancedDashboard.
@MainActor
final class AppState: ObservableObject {

    @Published var isAuthenticated = false
    @Published var isLoading = false
    @Published var currentReading: GlucoseMonitorAPI.LibreGlucoseCurrent?
    @Published var calculations: BackendAPI.GlucoseCalculationsResponse?
    @Published var notes: [BackendAPI.GlucoseNote] = []
    @Published var glucoseHistory: [GlucoseChartPoint] = []
    @Published var errorMessage: String?
    @Published var preferredGlucoseUnit: String = "mmol/L"

    private var autoRefreshTask: Task<Void, Never>?

    // MARK: - Auth

    func checkAuthentication() {
        let token = GlucoseMonitorAPI.sharedDefaults().string(forKey: GlucoseMonitorAPI.StorageKey.accessToken)
        isAuthenticated = !(token?.isEmpty ?? true)
        let stored = GlucoseMonitorAPI.sharedDefaults().string(forKey: GlucoseMonitorAPI.StorageKey.glucoseDisplayUnit)
        preferredGlucoseUnit = stored ?? "mmol/L"
    }

    func setPreferredGlucoseUnit(_ unit: String) {
        preferredGlucoseUnit = unit
        GlucoseMonitorAPI.sharedDefaults().set(unit, forKey: GlucoseMonitorAPI.StorageKey.glucoseDisplayUnit)
        persistWidgetSnapshot()
    }

    func logout() async {
        await GlucoseMonitorAPI.logout()
        isAuthenticated = false
        currentReading = nil
        calculations = nil
        notes = []
        glucoseHistory = []
        errorMessage = nil
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
        GlucoseMonitorAPI.sharedDefaults().removeObject(forKey: LockScreenWidgetSnapshot.storageKey)
        WidgetCenter.shared.reloadTimelines(ofKind: LockScreenWidgetSnapshot.widgetKind)
    }

    /// Glucose value in mmol/L for `POST /api/glucose-calculations/` (web sends mmol).
    func currentGlucoseMmolForAPI() -> Double? {
        guard let v = currentReading?.value else { return nil }
        let unit = currentReading?.unit ?? "mmol/L"
        if unit.lowercased().contains("mg") {
            return v / 18.018
        }
        return v
    }

    /// Nearest chart point in mmol/L to `target` if within `maxDelta` seconds.
    func glucoseMmolFromChartNearest(to target: Date, maxDelta: TimeInterval = 24 * 3600) -> Double? {
        guard !glucoseHistory.isEmpty else { return nil }
        guard let best = glucoseHistory.min(by: { abs($0.time.timeIntervalSince(target)) < abs($1.time.timeIntervalSince(target)) }) else {
            return nil
        }
        guard abs(best.time.timeIntervalSince(target)) <= maxDelta else { return nil }
        return best.mmol
    }

    /// Read-only label for note forms: stored value, else chart near `target`, else current reading.
    func formattedGlucoseAtNoteTime(_ target: Date, storedOnNote: Double?) -> String {
        if let s = storedOnNote {
            return String(format: "%.1f mmol/L", s)
        }
        if let g = glucoseMmolFromChartNearest(to: target) {
            return String(format: "%.1f mmol/L", g)
        }
        if let cur = currentGlucoseMmolForAPI() {
            return String(format: "%.1f mmol/L", cur)
        }
        return "--"
    }

    /// Value to send when creating a note: chart at `target`, else current reading.
    func glucoseMmolForNewNote(at target: Date) -> Double? {
        glucoseMmolFromChartNearest(to: target) ?? currentGlucoseMmolForAPI()
    }

    /// mmol/L for note list rows: stored on note, else nearest chart point, else current reading if the note is very recent (sensor snapshot may not be persisted).
    func glucoseMmolForNoteRowDisplay(_ note: BackendAPI.GlucoseNote) -> Double? {
        if let g = note.glucoseValue { return g }
        guard let t = note.timestamp else { return nil }
        if let g = glucoseMmolFromChartNearest(to: t) { return g }
        let age = abs(t.timeIntervalSinceNow)
        if age <= 6 * 3600 {
            return currentGlucoseMmolForAPI()
        }
        return nil
    }

    /// IOB: backend when > 0, otherwise estimate from notes (web parity).
    var displayedIOB: Double? {
        let backend = calculations?.activeInsulinOnBoard
        let fromNotes = InsulinIOB.currentIOBFromNotes(notes: notes)
        if let b = backend, b > 0 { return b }
        if fromNotes > 0 { return fromNotes }
        return backend
    }

    func predictionChartPoints() -> [PredictionChartPoint] {
        // Prefer backend prediction path when the server provides it.
        if let path = calculations?.predictionPath, !path.isEmpty {
            let pts = path.compactMap { p -> PredictionChartPoint? in
                guard let y = p.predictedGlucose else { return nil }
                return PredictionChartPoint(time: p.timestamp, mmol: y)
            }
            if !pts.isEmpty { return pts }
        }
        // Fall back to local IOB + COB model so the curve is always visible.
        guard let mmol = currentGlucoseMmolForAPI() else { return [] }
        return GlucosePrediction.localPath(
            currentGlucose: mmol,
            history: glucoseHistory,
            notes: notes
        )
    }

    // MARK: - Refresh

    func startAutoRefreshIfNeeded() {
        autoRefreshTask?.cancel()
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000_000)
                guard let self, self.isAuthenticated else { continue }
                await self.refreshGlucoseOnly()
            }
        }
    }

    func stopAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }

    /// Full refresh: notes, history, current reading, calculations.
    func refreshAll() async {
        guard isAuthenticated else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        await fetchNotes()
        await loadGlucoseHistory()
        await refreshCurrentReading()
        await refreshCalculations()
    }

    /// Periodic refresh without reloading the full notes list.
    func refreshGlucoseOnly() async {
        guard isAuthenticated else { return }
        await GlucoseMonitorAPI.proactiveRefreshSessionTokens(minimumInterval: 45 * 60)
        await loadGlucoseHistory()
        await refreshCurrentReading()
        await refreshCalculations()
    }

    private func persistWidgetSnapshot() {
        let displayUnit = preferredGlucoseUnit
        let isMg = displayUnit.lowercased().contains("mg")
        let mmol = currentGlucoseMmolForAPI()
        let displayVal = mmol.map { isMg ? $0 * 18.018 : $0 }
        let delta: Double?
        if glucoseHistory.count >= 2 {
            let last = glucoseHistory[glucoseHistory.count - 1]
            let prev = glucoseHistory[glucoseHistory.count - 2]
            let deltaMmol = last.mmol - prev.mmol
            delta = isMg ? deltaMmol * 18.018 : deltaMmol
        } else {
            delta = nil
        }
        let chartCutoff = Date().addingTimeInterval(-4 * 3600)
        let chart = glucoseHistory
            .filter { $0.time >= chartCutoff }
            .map { LockScreenWidgetSnapshot.ChartPoint(time: $0.time, mmol: $0.mmol) }
        let snap = LockScreenWidgetSnapshot(
            savedAt: Date(),
            glucoseValue: displayVal,
            glucoseUnit: displayUnit,
            trendArrow: currentReading?.trendArrow,
            deltaValue: delta,
            cobGrams: calculations?.activeCarbsOnBoard,
            iobUnits: displayedIOB,
            twoHourPredictionMmol: calculations?.twoHourPrediction,
            chartPoints: Array(chart)
        )
        snap.save()
        WidgetCenter.shared.reloadTimelines(ofKind: LockScreenWidgetSnapshot.widgetKind)
    }

    private func refreshCurrentReading() async {
        let source = GlucoseMonitorAPI.sharedDefaults().string(forKey: GlucoseMonitorAPI.StorageKey.dataSource) ?? "libre"
        do {
            if source == "nightscout" {
                let entries = try await BackendAPI.fetchNightscoutEntriesWithFallbacks(count: 48)
                currentReading = Self.latestNightscoutEntry(entries)?.toLibreGlucoseCurrent()
            } else {
                currentReading = try await GlucoseMonitorAPI.fetchCurrentGlucose()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Newest SGV point (Nightscout order varies: live often newest-first, DB cache often ascending).
    private static func latestNightscoutEntry(_ entries: [BackendAPI.NightscoutEntry]) -> BackendAPI.NightscoutEntry? {
        entries
            .filter { $0.type == nil || ($0.type?.lowercased() == "sgv") }
            .compactMap { e -> (Date, BackendAPI.NightscoutEntry)? in
                guard let t = e.timestamp else { return nil }
                return (t, e)
            }
            .max(by: { $0.0 < $1.0 })?
            .1
    }

    private func refreshCalculations() async {
        guard let mmol = currentGlucoseMmolForAPI() else {
            calculations = nil
            persistWidgetSnapshot()
            return
        }
        calculations = try? await BackendAPI.fetchGlucoseCalculations(currentGlucose: mmol)
        persistWidgetSnapshot()
    }

    private func loadGlucoseHistory() async {
        let source = GlucoseMonitorAPI.sharedDefaults().string(forKey: GlucoseMonitorAPI.StorageKey.dataSource) ?? "libre"
        do {
            if source == "nightscout" {
                let entries = try await BackendAPI.fetchNightscoutEntriesWithFallbacks(count: 200)
                let filtered = entries.filter { $0.type == nil || ($0.type?.lowercased() == "sgv") }
                let points: [GlucoseChartPoint] = filtered.compactMap { e in
                    guard let t = e.timestamp, let sgv = e.sgv else { return nil }
                    return GlucoseChartPoint(time: t, mmol: sgv / 18.018)
                }
                .sorted { $0.time < $1.time }
                glucoseHistory = points
            } else {
                let rows = try await GlucoseMonitorAPI.fetchLibreGlucoseHistory(days: 1)
                let points: [GlucoseChartPoint] = rows.compactMap { r in
                    guard let t = r.timestamp, let v = r.value else { return nil }
                    let mmol = r.unit?.lowercased().contains("mmol") == true ? v : v / 18.018
                    return GlucoseChartPoint(time: t, mmol: mmol)
                }
                .sorted { $0.time < $1.time }
                glucoseHistory = points
            }
        } catch {
            if errorMessage == nil {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Notes

    func fetchNotes() async {
        notes = (try? await BackendAPI.fetchNotes()) ?? []
    }

    func createNote(_ input: BackendAPI.NoteInput) async {
        if let note = try? await BackendAPI.createNote(input) {
            notes.append(note)
            await refreshGlucoseOnly()
            await refreshCalculations()
        }
    }

    func updateNote(id: String, body: BackendAPI.UpdateNoteBody) async {
        if let updated = try? await BackendAPI.updateNote(id: id, body: body) {
            if let idx = notes.firstIndex(where: { $0.id == id }) {
                notes[idx] = updated
            }
            await refreshGlucoseOnly()
            await refreshCalculations()
        }
    }

    func deleteNote(id: String) async {
        try? await BackendAPI.deleteNote(id: id)
        notes.removeAll { $0.id == id }
        await refreshCalculations()
    }

    func uploadNotePhoto(noteId: String, image: UIImage) async {
        if let updated = try? await BackendAPI.uploadNotePhoto(noteId: noteId, image: image) {
            if let idx = notes.firstIndex(where: { $0.id == noteId }) {
                notes[idx] = updated
            }
        }
    }
}
