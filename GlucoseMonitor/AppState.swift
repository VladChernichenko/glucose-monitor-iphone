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
    @Published var dataSource: String = "libre"
    @Published var sensorInfo: GlucoseMonitorAPI.LibreSensorInfo?
    @Published var libreAlarms: GlucoseMonitorAPI.LibreAlarms?

    private var autoRefreshTask: Task<Void, Never>?
    private(set) var lastGlucoseRefresh: Date?
    private var fullRefreshTask: Task<Void, Never>?
    private var glucoseRefreshTask: Task<Void, Never>?

    deinit {
        autoRefreshTask?.cancel()
        fullRefreshTask?.cancel()
        glucoseRefreshTask?.cancel()
    }

    // MARK: - Auth

    func checkAuthentication() {
        let token = GlucoseMonitorAPI.storedAccessToken()
        isAuthenticated = !(token?.isEmpty ?? true)
        let stored = GlucoseMonitorAPI.sharedDefaults().string(forKey: GlucoseMonitorAPI.StorageKey.glucoseDisplayUnit)
        preferredGlucoseUnit = stored ?? "mmol/L"
        dataSource = GlucoseMonitorAPI.sharedDefaults().string(forKey: GlucoseMonitorAPI.StorageKey.dataSource) ?? "libre"
    }

    func setPreferredGlucoseUnit(_ unit: String) {
        preferredGlucoseUnit = unit
        GlucoseMonitorAPI.sharedDefaults().set(unit, forKey: GlucoseMonitorAPI.StorageKey.glucoseDisplayUnit)
        persistWidgetSnapshot()
    }

    func setDataSource(_ source: String) {
        dataSource = source
        GlucoseMonitorAPI.sharedDefaults().set(source, forKey: GlucoseMonitorAPI.StorageKey.dataSource)
        Task { await refreshAll() }
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
        sensorInfo = nil
        libreAlarms = nil
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

    /// CGM reading only if received within the last 4 hours; nil if stale.
    var freshCGMReading: GlucoseMonitorAPI.LibreGlucoseCurrent? {
        guard let r = currentReading, let ts = r.timestamp,
              ts >= Date().addingTimeInterval(-4 * 3600) else { return nil }
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
            // Wall-clock timestamp - survives OS suspension unlike Task.sleep's monotonic clock.
            var lastFireTime = Date()
            while !Task.isCancelled {
                // Wake every minute so we can detect when wall-clock time has passed 5 min
                // even after a long background suspension (where Task.sleep effectively pauses).
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard let self, self.isAuthenticated else { continue }
                guard Date().timeIntervalSince(lastFireTime) >= 5 * 60 else { continue }
                lastFireTime = Date()
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
        if let existing = fullRefreshTask {
            await existing.value
            return
        }
        let task = Task { @MainActor in
            isLoading = true
            errorMessage = nil
            defer { isLoading = false }

            await GlucoseMonitorAPI.proactiveRefreshSessionTokens(minimumInterval: 45 * 60)

            async let notesFetch: Void = fetchNotes()
            async let historyFetch: Void = loadGlucoseHistory()
            async let readingFetch: Void = refreshCurrentReading()
            async let sensorFetch: Void = refreshSensorData()
            _ = await (notesFetch, historyFetch, readingFetch, sensorFetch)

            await refreshCalculations()
            lastGlucoseRefresh = Date()
        }
        fullRefreshTask = task
        defer { fullRefreshTask = nil }
        await task.value
    }

    /// Periodic refresh without reloading the full notes list.
    func refreshGlucoseOnly() async {
        guard isAuthenticated else { return }
        if let full = fullRefreshTask {
            await full.value
            return
        }
        if let existing = glucoseRefreshTask {
            await existing.value
            return
        }
        let task = Task { @MainActor in
            isLoading = true
            defer { isLoading = false }
            await GlucoseMonitorAPI.proactiveRefreshSessionTokens(minimumInterval: 45 * 60)
            await loadGlucoseHistory()
            await refreshCurrentReading()
            await refreshCalculations()
            lastGlucoseRefresh = Date()
        }
        glucoseRefreshTask = task
        defer { glucoseRefreshTask = nil }
        await task.value
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
        // LLU: currentReading is populated from nightscout_chart_data inside
        // loadGlucoseHistory() so both the chart and the "Updated X ago" label
        // share the same data source (scheduler DB cache, updated every 5 min).
        // Calling the live LLU API here caused a mismatch: the live endpoint can
        // return a reading that is 30-60 min older than what the scheduler has cached,
        // making the card show "Updated 58 min ago" while the chart looked current.
        guard dataSource == "nightscout" else { return }
        do {
            let entries = try await BackendAPI.fetchNightscoutEntriesWithFallbacks(count: 48)
            currentReading = Self.latestNightscoutEntry(entries)?.toLibreGlucoseCurrent()
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
        // Use any available CGM reading regardless of age - the UI already shows "Updated X ago".
        // Fall back to a recent manual note only when no CGM reading is available at all.
        let mmol: Double?
        if let v = currentReading?.value {
            let unit = currentReading?.unit ?? "mmol/L"
            mmol = unit.lowercased().contains("mg") ? v / 18.018 : v
        } else {
            let cutoff = Date().addingTimeInterval(-4 * 3600)
            mmol = notes
                .filter { $0.glucoseValue != nil && ($0.timestamp ?? .distantPast) >= cutoff }
                .sorted { ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast) }
                .first?.glucoseValue
        }
        guard let mmol else {
            calculations = nil
            persistWidgetSnapshot()
            return
        }
        do {
            calculations = try await BackendAPI.fetchGlucoseCalculations(currentGlucose: mmol)
        } catch {
            // Retry once - predictions are important; a transient failure shouldn't blank them.
            do {
                calculations = try await BackendAPI.fetchGlucoseCalculations(currentGlucose: mmol)
            } catch {
                calculations = nil
            }
        }
        persistWidgetSnapshot()
    }

    private func loadGlucoseHistory() async {
        let source = dataSource
        do {
            if source == "nightscout" {
                let entries = try await BackendAPI.fetchNightscoutEntriesWithFallbacks(count: 200)
                glucoseHistory = Self.nightscoutEntriesToChartPoints(entries)
            } else {
                // LLU: read from the cached chart data written by the background scheduler
                // (runs every 5 min) rather than making a live LLU API call on every refresh.
                let entries = try await BackendAPI.fetchNightscoutChartData(count: 200)
                if !entries.isEmpty {
                    glucoseHistory = Self.nightscoutEntriesToChartPoints(entries)
                    // iOS-11: derive currentReading from the chart cache so the
                    // "Updated X ago" card and the chart share the same data source.
                    // The live LLU API can return a reading 30-60 min behind the
                    // scheduler's DB cache, causing a stale "Updated X ago" display.
                    if let latest = Self.latestNightscoutEntry(entries) {
                        currentReading = latest.toLibreGlucoseCurrent()
                    }
                } else {
                    // No cached data yet - fall back to live LLU endpoint.
                    let rows = try await GlucoseMonitorAPI.fetchLibreGlucoseHistory(days: 1)
                    let points: [GlucoseChartPoint] = rows.compactMap { r in
                        guard let t = r.timestamp, let v = r.value else { return nil }
                        let mmol = r.unit?.lowercased().contains("mmol") == true ? v : v / 18.018
                        return GlucoseChartPoint(time: t, mmol: mmol)
                    }
                    .sorted { $0.time < $1.time }
                    glucoseHistory = points
                }
            }
        } catch {
            if errorMessage == nil {
                errorMessage = error.localizedDescription
            }
        }
    }

    private static func nightscoutEntriesToChartPoints(_ entries: [BackendAPI.NightscoutEntry]) -> [GlucoseChartPoint] {
        entries
            .filter { $0.type == nil || ($0.type?.lowercased() == "sgv") }
            .compactMap { e -> GlucoseChartPoint? in
                guard let t = e.timestamp, let sgv = e.sgv else { return nil }
                return GlucoseChartPoint(time: t, mmol: sgv / 18.018)
            }
            .sorted { $0.time < $1.time }
    }

    // MARK: - Sensor info & alarms (LLU only)

    /// Fetches sensor info and alarm configuration concurrently. No-op for Nightscout.
    private func refreshSensorData() async {
        guard dataSource == "libre" else { return }
        async let sensor = GlucoseMonitorAPI.fetchSensorInfo()
        async let alarms = GlucoseMonitorAPI.fetchAlarms()
        let (s, a) = await (sensor, alarms)
        if let s { sensorInfo = s }
        if let a { libreAlarms = a }
    }

    /// Call once after a successful LLU login to auto-set the preferred glucose unit
    /// from the user's LibreLinkUp account profile (saves a manual Settings step).
    func applyProfileDefaults() async {
        guard dataSource == "libre" else { return }
        if let profile = await GlucoseMonitorAPI.fetchUserProfile() {
            let unit = profile.preferredGlucoseUnit
            if preferredGlucoseUnit != unit {
                setPreferredGlucoseUnit(unit)
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
            // Retry once after a short pause - transient network errors usually clear immediately.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            do {
                notes = try await BackendAPI.fetchNotes()
            } catch {
                notesLoadError = "Failed to load notes"
            }
        }
    }

    func createNote(_ input: BackendAPI.NoteInput) async {
        // iOS-2 fix: surface errors instead of silently swallowing them with try?
        do {
            let note = try await BackendAPI.createNote(input)
            notes.append(note)
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
        // I4 fix: surface errors instead of silently swallowing them with try?
        do {
            let updated = try await BackendAPI.uploadNotePhoto(noteId: noteId, image: image)
            if let idx = notes.firstIndex(where: { $0.id == noteId }) {
                notes[idx] = updated
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
