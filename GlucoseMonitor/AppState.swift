import Foundation
import SwiftUI
import UIKit
import WidgetKit

// MARK: - App state

/// Observable app state (auth, dashboard data, notes); mirrors web AuthContext + EnhancedDashboard.
@MainActor
final class AppState: ObservableObject {

    @Published var isAuthenticated = false
    @Published var isLoading = false
    @Published var currentReading: GlucoseMonitorAPI.LibreGlucoseCurrent?
    @Published var calculations: BackendAPI.GlucoseCalculationsResponse?
    @Published var notes: [BackendAPI.GlucoseNote] = []
    @Published var isLoadingNotes = false
    @Published var notesLoadError: String? = nil
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
        isLoadingNotes = false
        notesLoadError = nil
        glucoseHistory = []
        errorMessage = nil
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
        GlucoseMonitorAPI.sharedDefaults().removeObject(forKey: LockScreenWidgetSnapshot.storageKey)
        WidgetCenter.shared.reloadTimelines(ofKind: LockScreenWidgetSnapshot.widgetKind)
    }

    /// Glucose value in mmol/L for `POST /api/glucose-calculations/` (web sends mmol).
    /// Falls back to the most recent manually logged note glucoseValue (within 4h) when no CGM.
    func currentGlucoseMmolForAPI() -> Double? {
        let cgmStaleCutoff = Date().addingTimeInterval(-30 * 60)
        if let v = currentReading?.value,
           let ts = currentReading?.timestamp, ts >= cgmStaleCutoff {
            let unit = currentReading?.unit ?? "mmol/L"
            return unit.lowercased().contains("mg") ? v / 18.018 : v
        }
        let cutoff = Date().addingTimeInterval(-4 * 3600)
        return notes
            .filter { $0.glucoseValue != nil && ($0.timestamp ?? .distantPast) >= cutoff }
            .sorted { ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast) }
            .first?.glucoseValue
    }

    /// CGM reading only if received within the last 30 minutes; nil if stale.
    var freshCGMReading: GlucoseMonitorAPI.LibreGlucoseCurrent? {
        guard let r = currentReading, let ts = r.timestamp,
              ts >= Date().addingTimeInterval(-30 * 60) else { return nil }
        return r
    }

    /// Most recent manually logged glucose from notes (within 4h), regardless of CGM.
    var latestManualGlucose: (value: Double, timestamp: Date)? {
        let cutoff = Date().addingTimeInterval(-4 * 3600)
        guard let note = notes
            .filter({ $0.glucoseValue != nil && ($0.timestamp ?? .distantPast) >= cutoff })
            .sorted(by: { ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast) })
            .first,
              let gv = note.glucoseValue, let ts = note.timestamp
        else { return nil }
        return (gv, ts)
    }

    /// Effective current glucose in manual mode: prediction-path value at now (accounts for IOB
    /// decay since logging time), or the raw logged value if no path is available.
    var effectiveManualGlucoseMmol: Double? {
        guard let manual = latestManualGlucose else { return nil }
        guard let path = calculations?.predictionPath, !path.isEmpty,
              let iob = displayedIOB, iob > 0 else {
            return manual.value
        }
        let now = Date()
        guard let nearest = path.compactMap({ p -> (TimeInterval, Double)? in
            guard let g = p.predictedGlucose else { return nil }
            return (abs(p.timestamp.timeIntervalSince(now)), g)
        }).min(by: { $0.0 < $1.0 }) else {
            return manual.value
        }
        // Only use path value if it's within 10 minutes of now
        guard nearest.0 <= 10 * 60 else { return manual.value }
        return nearest.1
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
        guard let path = calculations?.predictionPath, !path.isEmpty else { return [] }
        return path.compactMap { p -> PredictionChartPoint? in
            guard let y = p.predictedGlucose else { return nil }
            return PredictionChartPoint(time: p.timestamp, mmol: y)
        }
    }

    // MARK: - Refresh

    func startAutoRefreshIfNeeded() {
        autoRefreshTask?.cancel()
        autoRefreshTask = Task { [weak self] in
            var cycle = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000_000)   // 5-minute glucose tick
                guard let self, self.isAuthenticated else { continue }
                await self.refreshGlucoseOnly()
                cycle += 1
                // iOS-8 fix: sync notes every other glucose cycle (~10 min) so
                // notes added on other devices appear without a manual pull-to-refresh.
                if cycle % 2 == 0 {
                    await self.fetchNotes()
                }
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
        isLoadingNotes = true
        notesLoadError = nil
        defer { isLoadingNotes = false }
        do {
            notes = try await BackendAPI.fetchNotes()
        } catch {
            notesLoadError = "Failed to load notes"
        }
    }

    func createNote(_ input: BackendAPI.NoteInput) async {
        // iOS-2 fix: surface errors instead of silently swallowing them with try?
        do {
            let note = try await BackendAPI.createNote(input)
            notes.append(note)
            await refreshGlucoseOnly()
            await refreshCalculations()
        } catch {
            errorMessage = "Failed to save note: \(error.localizedDescription)"
        }
    }

    func updateNote(id: String, body: BackendAPI.UpdateNoteBody) async {
        // iOS-2 fix: surface errors instead of silently swallowing them with try?
        do {
            let updated = try await BackendAPI.updateNote(id: id, body: body)
            if let idx = notes.firstIndex(where: { $0.id == id }) {
                notes[idx] = updated  // note with new glucoseValue in place before calculations
            }
            await refreshGlucoseOnly()
            await refreshCalculations()
        } catch {
            errorMessage = "Failed to update note: \(error.localizedDescription)"
        }
    }

    func deleteNote(id: String) async {
        // iOS-1 fix: only remove from local list when the backend delete succeeds
        do {
            try await BackendAPI.deleteNote(id: id)
            notes.removeAll { $0.id == id }
            await refreshCalculations()
        } catch {
            errorMessage = "Failed to delete note: \(error.localizedDescription)"
        }
    }

    func uploadNotePhoto(noteId: String, image: UIImage) async {
        if let updated = try? await BackendAPI.uploadNotePhoto(noteId: noteId, image: image) {
            if let idx = notes.firstIndex(where: { $0.id == noteId }) {
                notes[idx] = updated
            }
        }
    }
}
