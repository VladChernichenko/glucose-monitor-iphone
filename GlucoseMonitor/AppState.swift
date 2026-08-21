import Foundation
import SwiftUI
import UIKit
import WidgetKit

// MARK: - App state

/// Observable app state (auth, dashboard data, notes); mirrors web AuthContext + EnhancedDashboard.
@MainActor
final class AppState: ObservableObject {

    /// Set during `init` for background refresh handlers (`BGTask`, `UIApplication` background task).
    static weak var shared: AppState?

    @Published var isAuthenticated = false
    @Published var isLoading = false
    @Published var currentReading: GlucoseMonitorAPI.LibreGlucoseCurrent?
    @Published var calculations: BackendAPI.GlucoseCalculationsResponse?
    /// True when the last calculations refresh failed and `calculations` is showing a stale (previously fetched) value.
    @Published var calculationsStale: Bool = false
    @Published var notes: [BackendAPI.GlucoseNote] = []
    @Published var isLoadingNotes = false
    @Published var notesLoadError: String? = nil
    @Published var glucoseHistory: [GlucoseChartPoint] = []
    @Published var errorMessage: String?
    @Published var preferredGlucoseUnit: String = "mmol/L"
    @Published var dataSource: String = "libre"
    @Published var sensorInfo: GlucoseMonitorAPI.LibreSensorInfo?
    /// Insulin preferences (long-acting name + optional daily injection time) for the long-acting logging action.
    @Published var insulinPrefs: BackendAPI.UserInsulinPreferences?
    /// Open hypo prompt awaiting confirm/dismiss, if any. Drives `HypoPromptView` via `.sheet(item:)`.
    @Published var openHypoEvent: BackendAPI.HypoEvent?

    private var autoRefreshTask: Task<Void, Never>?
    private(set) var lastGlucoseRefresh: Date?
    private var fullRefreshTask: Task<Void, Never>?
    private var glucoseRefreshTask: Task<Void, Never>?
    private var backgroundRefreshTask: Task<Void, Never>?
    private var lastCalculationsResponseJSON: Data?
    /// Bumped on every logout so in-flight refresh tasks started before logout can detect that
    /// their results are stale and must not write into a now-logged-out session.
    private var authGeneration = 0
    private var sessionClearedObserver: NSObjectProtocol?

    init() {
        Self.shared = self
        // Resolve auth synchronously from the stored Keychain token *before* the first render, so an
        // already-signed-in user never sees the SignInView flash on launch (the previous default of
        // isAuthenticated=false showed login for one frame until .onAppear ran checkAuthentication()).
        // checkAuthentication() only reads the Keychain + App-Group defaults (no network), so it is
        // safe and instantaneous at init time.
        checkAuthentication()
        restoreFromCacheIfAvailable()
        sessionClearedObserver = NotificationCenter.default.addObserver(
            forName: GlucoseMonitorAPI.sessionClearedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.handleSessionCleared()
            }
        }
    }

    /// Hydrate published state from disk (no network). Call after `checkAuthentication()` when signed in.
    func restoreFromCacheIfAvailable() {
        guard isAuthenticated, let payload = DashboardCache.load() else { return }
        preferredGlucoseUnit = payload.preferredGlucoseUnit
        dataSource = payload.dataSource
        if let r = payload.currentReading {
            currentReading = GlucoseMonitorAPI.LibreGlucoseCurrent(
                timestamp: r.timestamp,
                value: r.value,
                trend: r.trend,
                trendArrow: r.trendArrow,
                status: r.status,
                unit: r.unit
            )
        }
        glucoseHistory = payload.glucoseHistory.map { GlucoseChartPoint(time: $0.time, mmol: $0.mmol) }
        if let json = payload.calculationsResponseJSON {
            lastCalculationsResponseJSON = json
            calculations = BackendAPI.decodeGlucoseCalculationsResponse(from: json)
        }
        notes = payload.notes.map { n in
            BackendAPI.GlucoseNote(
                id: n.id,
                timestamp: n.timestamp,
                carbs: n.carbs,
                insulin: n.insulin,
                meal: n.meal,
                comment: n.comment,
                glucoseValue: n.glucoseValue,
                absorptionMode: n.absorptionMode,
                nutritionProfile: n.nutritionProfile,
                type: n.type,
                photoUrl: n.photoUrl
            )
        }
        lastGlucoseRefresh = payload.savedAt
    }

    deinit {
        if let sessionClearedObserver {
            NotificationCenter.default.removeObserver(sessionClearedObserver)
        }
        autoRefreshTask?.cancel()
        fullRefreshTask?.cancel()
        glucoseRefreshTask?.cancel()
        backgroundRefreshTask?.cancel()
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
        // Invalidate any refresh task started before logout *first*, synchronously, so its
        // eventual completion (after the awaits below) can detect the session changed and
        // skip writing stale post-logout data into @Published state.
        beginLocalSignOut()
        await GlucoseMonitorAPI.logout()
        applyLoggedOutUIState()
    }

    /// Called when Keychain tokens were wiped (e.g. refresh returned 401) without an explicit Sign Out tap.
    private func handleSessionCleared() {
        guard isAuthenticated else { return }
        beginLocalSignOut()
        applyLoggedOutUIState()
    }

    private func beginLocalSignOut() {
        authGeneration += 1
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
        fullRefreshTask?.cancel()
        fullRefreshTask = nil
        glucoseRefreshTask?.cancel()
        glucoseRefreshTask = nil
        backgroundRefreshTask?.cancel()
        backgroundRefreshTask = nil
    }

    private func applyLoggedOutUIState() {
        isAuthenticated = false
        currentReading = nil
        calculations = nil
        calculationsStale = false
        notes = []
        isLoadingNotes = false
        notesLoadError = nil
        glucoseHistory = []
        errorMessage = nil
        sensorInfo = nil
        GlucoseMonitorAPI.sharedDefaults().removeObject(forKey: LockScreenWidgetSnapshot.storageKey)
        DashboardCache.clear()
        WidgetCenter.shared.reloadTimelines(ofKind: LockScreenWidgetSnapshot.widgetKind)
    }

    /// Glucose value in mmol/L for `POST /api/glucose-calculations/` (web sends mmol).
    /// Falls back to the most recent manually logged note glucoseValue (within 4h) when no CGM.
    func currentGlucoseMmolForAPI() -> Double? {
        let cgmStaleCutoff = Date().addingTimeInterval(-30 * 60)
        if let v = currentReading?.value,
           let ts = currentReading?.timestamp, ts >= cgmStaleCutoff {
            let unit = currentReading?.unit ?? "mmol/L"
            return GlucoseUnit.toMmol(v, unit: unit)
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

    /// IOB shown on the dashboard. Single source of truth: the backend's `activeInsulinOnBoard`
    /// from `/api/glucose-calculations/`. We deliberately do NOT fall back to a client-side
    /// note estimate - that fallback made the dashboard disagree with the Experiments tab
    /// (which reads the backend directly). Both screens now show the same backend value.
    var displayedIOB: Double? {
        calculations?.activeInsulinOnBoard
    }

    func predictionChartPoints() -> [PredictionChartPoint] {
        guard let path = calculations?.predictionPath, !path.isEmpty else { return [] }
        return path.compactMap { p -> PredictionChartPoint? in
            guard let y = p.predictedGlucose else { return nil }
            return PredictionChartPoint(time: p.timestamp, mmol: y,
                                        lower: p.predictedGlucoseLower,
                                        upper: p.predictedGlucoseUpper)
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
                await self.refreshGlucoseOnly(silent: true)
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
            async let historyFetch: Void = loadGlucoseHistory(forceServerSync: true)
            async let readingFetch: Void = refreshCurrentReading()
            async let sensorFetch: Void = refreshSensorData()
            async let prefsFetch: Void = refreshInsulinPrefs()
            async let hypoFetch: Void = refreshHypoEvents()
            _ = await (notesFetch, historyFetch, readingFetch, sensorFetch, prefsFetch, hypoFetch)

            await refreshCalculations()
            lastGlucoseRefresh = Date()
            persistDashboardCache()
        }
        fullRefreshTask = task
        defer { fullRefreshTask = nil }
        await task.value
    }

    /// Periodic / lightweight refresh without reloading the full notes list.
    /// - Parameters:
    ///   - silent: when true, no loading spinner (used for auto-refresh and dashboard-open).
    ///   - forceServerSync: force an on-demand LibreLinkUp server sync before reading the cache.
    ///     When `nil`, derives from `!silent` (user-initiated pulls force; periodic ticks don't).
    ///     Pass `true` explicitly for dashboard-open events to get fresh data without a spinner.
    func refreshGlucoseOnly(silent: Bool = false, forceServerSync: Bool? = nil) async {
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
            if !silent { isLoading = true }
            defer { if !silent { isLoading = false } }
            await GlucoseMonitorAPI.proactiveRefreshSessionTokens(minimumInterval: 45 * 60)
            // Force a fresh server sync when explicitly requested (dashboard-open) or, by default,
            // for user-initiated non-silent pulls. Periodic silent auto-refresh relies on the
            // backend scheduler.
            await loadGlucoseHistory(forceServerSync: forceServerSync ?? !silent)
            await refreshCurrentReading()
            await refreshCalculations()
            lastGlucoseRefresh = Date()
            persistDashboardCache()
        }
        glucoseRefreshTask = task
        defer { glucoseRefreshTask = nil }
        await task.value
    }

    /// BG fetch / background task entry: no loading spinner, coalesced with foreground refresh.
    func refreshGlucoseInBackground() async {
        guard isAuthenticated else { return }
        if let full = fullRefreshTask {
            await full.value
            return
        }
        if let existing = backgroundRefreshTask {
            await existing.value
            return
        }
        let task = Task { @MainActor in
            await GlucoseMonitorAPI.proactiveRefreshSessionTokens(minimumInterval: 45 * 60)
            await loadGlucoseHistory()
            await refreshCurrentReading()
            await refreshCalculations()
            lastGlucoseRefresh = Date()
            persistDashboardCache()
        }
        backgroundRefreshTask = task
        defer { backgroundRefreshTask = nil }
        await task.value
    }

    private func persistDashboardCache() {
        DashboardCache.capture(from: self, calculationsResponseJSON: lastCalculationsResponseJSON)
    }

    private func persistWidgetSnapshot() {
        let displayUnit = preferredGlucoseUnit
        let mmol = currentGlucoseMmolForAPI()
        let displayVal = mmol.map { GlucoseUnit.fromMmol($0, displayUnit: displayUnit) }
        let delta: Double?
        if glucoseHistory.count >= 2 {
            let last = glucoseHistory[glucoseHistory.count - 1]
            let prev = glucoseHistory[glucoseHistory.count - 2]
            let deltaMmol = last.mmol - prev.mmol
            delta = GlucoseUnit.fromMmol(deltaMmol, displayUnit: displayUnit)
        } else {
            delta = nil
        }
        let chartCutoff = Date().addingTimeInterval(-4 * 3600)
        let chart = glucoseHistory
            .filter { $0.time >= chartCutoff }
            .sorted { $0.time < $1.time }
            .map { LockScreenWidgetSnapshot.ChartPoint(time: $0.time, mmol: $0.mmol) }
        let readingAgeStart = currentReading?.timestamp ?? glucoseHistory.last?.time ?? Date()
        let snap = LockScreenWidgetSnapshot(
            savedAt: readingAgeStart,
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
        reloadWidgetTimelines()
    }

    /// Push fresh snapshot to Home Screen / Lock Screen widgets (after foreground or background fetch).
    func reloadWidgetTimelines() {
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
        let generation = authGeneration
        do {
            let entries = try await BackendAPI.fetchNightscoutEntriesWithFallbacks(count: 48)
            guard generation == authGeneration else { return }
            currentReading = Self.latestNightscoutEntry(entries)?.toLibreGlucoseCurrent()
        } catch {
            guard generation == authGeneration else { return }
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
        let generation = authGeneration
        // Use any available CGM reading regardless of age - the UI already shows "Updated X ago".
        // Fall back to a recent manual note only when no CGM reading is available at all.
        let mmol: Double?
        if let v = currentReading?.value {
            let unit = currentReading?.unit ?? "mmol/L"
            mmol = GlucoseUnit.toMmol(v, unit: unit)
        } else {
            let cutoff = Date().addingTimeInterval(-4 * 3600)
            mmol = notes
                .filter { $0.glucoseValue != nil && ($0.timestamp ?? .distantPast) >= cutoff }
                .sorted { ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast) }
                .first?.glucoseValue
        }
        guard let mmol else {
            guard generation == authGeneration else { return }
            // Nothing to calculate from yet (e.g. first launch, no CGM/notes) - not a refresh
            // failure, so there's nothing stale to flag.
            calculations = nil
            calculationsStale = false
            persistWidgetSnapshot()
            return
        }
        do {
            let fetched = try await BackendAPI.fetchGlucoseCalculationsWithRawResponse(
                currentGlucose: mmol,
                trendArrow: currentReading?.trendArrow
            )
            guard generation == authGeneration else { return }
            calculations = fetched.response
            lastCalculationsResponseJSON = fetched.rawData
            calculationsStale = false
        } catch {
            do {
                let fetched = try await BackendAPI.fetchGlucoseCalculationsWithRawResponse(
                    currentGlucose: mmol,
                    trendArrow: currentReading?.trendArrow
                )
                guard generation == authGeneration else { return }
                calculations = fetched.response
                lastCalculationsResponseJSON = fetched.rawData
                calculationsStale = false
            } catch {
                guard generation == authGeneration else { return }
                // Keep showing the last-known COB/IOB instead of blanking the dashboard to "--" -
                // a stale-but-real number is more useful (and safer) for a medical app than no
                // number at all. Flag it as stale so the UI can indicate it explicitly.
                calculationsStale = true
            }
        }
        persistWidgetSnapshot()
    }

    /// - Parameter forceServerSync: when true (explicit user refresh), ask the backend to fetch
    ///   fresh LibreLinkUp readings *now* before reading the chart cache, instead of waiting for the
    ///   5-min scheduler. Silent/background refreshes pass false and rely on the scheduler.
    private func loadGlucoseHistory(forceServerSync: Bool = false) async {
        let source = dataSource
        let generation = authGeneration
        do {
            if source == "nightscout" {
                let entries = try await BackendAPI.fetchNightscoutEntriesWithFallbacks(count: 200)
                guard generation == authGeneration else { return }
                glucoseHistory = Self.nightscoutEntriesToChartPoints(entries)
            } else {
                // LLU: on an explicit refresh, trigger an on-demand server sync so the chart cache
                // is fresh; otherwise read whatever the 5-min scheduler last wrote. Best-effort.
                if forceServerSync {
                    _ = try? await BackendAPI.syncLibreNow()
                }
                guard generation == authGeneration else { return }
                // LLU: read from the cached chart data written by the background scheduler
                // (runs every 5 min). Pass the latest cached timestamp so the backend only
                // returns new readings; merge them into the existing history.
                let sinceDate = glucoseHistory.last.map { $0.time }
                let entries = try await BackendAPI.fetchNightscoutChartData(count: 200, since: sinceDate)
                guard generation == authGeneration else { return }
                if !entries.isEmpty {
                    let newPoints = Self.nightscoutEntriesToChartPoints(entries)
                    if sinceDate != nil {
                        // Incremental: append and keep sorted, drop duplicates by time
                        let existing = glucoseHistory
                        let merged = (existing + newPoints).sorted { $0.time < $1.time }
                        let deduped = merged.reduce(into: [GlucoseChartPoint]()) { acc, pt in
                            if acc.last?.time != pt.time { acc.append(pt) }
                        }
                        glucoseHistory = deduped
                    } else {
                        glucoseHistory = newPoints
                    }
                    // iOS-11: derive currentReading from the chart cache so the
                    // "Updated X ago" card and the chart share the same data source.
                    // The live LLU API can return a reading 30-60 min behind the
                    // scheduler's DB cache, causing a stale "Updated X ago" display.
                    if let latest = Self.latestNightscoutEntry(entries) {
                        currentReading = latest.toLibreGlucoseCurrent(isLLU: true)
                    }
                } else {
                    // No cached data yet - fall back to live LLU endpoint.
                    let rows = try await GlucoseMonitorAPI.fetchLibreGlucoseHistory(days: 1)
                    guard generation == authGeneration else { return }
                    let points: [GlucoseChartPoint] = rows.compactMap { r in
                        guard let t = r.timestamp, let v = r.value else { return nil }
                        let mmol = GlucoseUnit.isMmol(r.unit) ? v : GlucoseUnit.mgdlToMmol(v)
                        return GlucoseChartPoint(time: t, mmol: mmol)
                    }
                    .sorted { $0.time < $1.time }
                    glucoseHistory = points
                }
            }
        } catch {
            guard generation == authGeneration else { return }
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
                return GlucoseChartPoint(time: t, mmol: GlucoseUnit.mgdlToMmol(sgv))
            }
            .sorted { $0.time < $1.time }
    }

    // MARK: - Sensor info (LLU only)

    /// Fetches sensor info. No-op for Nightscout.
    private func refreshSensorData() async {
        guard dataSource == "libre" else { return }
        let generation = authGeneration
        if let s = await GlucoseMonitorAPI.fetchSensorInfo() {
            guard generation == authGeneration else { return }
            sensorInfo = s
        }
    }

    /// Fetch the user's insulin preferences (long-acting name + optional injection time) used by the
    /// dashboard long-acting logging action. Best-effort: keeps the cached value on failure.
    func refreshInsulinPrefs() async {
        let generation = authGeneration
        if let prefs = try? await BackendAPI.fetchInsulinPreferences() {
            guard generation == authGeneration else { return }
            insulinPrefs = prefs
        }
    }

    /// True while a confirm request for the open hypo prompt is in flight. Guards against a
    /// second tap (preset or custom) racing a first one to the server before the sheet has a
    /// chance to dismiss - see `confirmHypo(grams:)`.
    private var isConfirmingHypo = false

    /// Poll for an open hypo prompt. Failures are silent: a missing prompt must never
    /// surface an error banner over the dashboard. Importantly, a failed fetch must never
    /// clear an already-open prompt - only a successful fetch that reports no open event may
    /// do that, otherwise a transient network blip yanks the sheet away from a patient mid-hypo.
    func refreshHypoEvents() async {
        do {
            openHypoEvent = try await BackendAPI.fetchOpenHypoEvents().first
        } catch {
            // Leave `openHypoEvent` exactly as it was - no-op on failure.
        }
    }

    /// Log a rescue carb against the open prompt, then refresh so COB reflects it.
    ///
    /// `isConfirmingHypo` closes a race where a patient taps two different presets (or a
    /// preset then Custom) before the first request returns: the backend's confirm endpoint is
    /// idempotent on an already-CONFIRMED event and replays the *first* winner's note without
    /// re-reading grams, so a naive second call would silently succeed while logging the wrong
    /// amount. Since `AppState` is `@MainActor`, the guard check-and-set below runs atomically
    /// with respect to any other call to this method - the second call always loses the race
    /// and returns immediately.
    func confirmHypo(grams: Double) async {
        guard let event = openHypoEvent, !isConfirmingHypo else { return }
        isConfirmingHypo = true
        defer { isConfirmingHypo = false }
        do {
            _ = try await BackendAPI.confirmHypoEvent(id: event.id, grams: grams)
            openHypoEvent = nil
            await refreshAll()
        } catch {
            errorMessage = "Could not log rescue carbs. Please try again."
        }
    }

    func dismissHypo() async {
        guard let event = openHypoEvent else { return }
        openHypoEvent = nil
        _ = try? await BackendAPI.dismissHypoEvent(id: event.id)
    }

    /// Log a long-acting (basal) dose as a note with type "long_acting". Such notes are excluded from
    /// rapid-acting IOB/predictions on both client and server, so no calculations refresh is needed.
    func logLongActingInsulin(dose: Double, name: String, at time: Date) async {
        let input = BackendAPI.NoteInput(
            timestamp: BackendAPI.formatNoteTimestampForRequest(time),
            carbs: 0,
            insulin: dose,
            meal: name,
            comment: nil,
            glucoseValue: nil,
            absorptionMode: nil,
            nutritionProfile: nil,
            type: BackendAPI.NoteType.longActing
        )
        do {
            let note = try await BackendAPI.createNote(input)
            notes.append(note)
        } catch {
            errorMessage = "Failed to log long-acting insulin: \(error.localizedDescription)"
        }
    }

    /// Logs a physical-activity note that drives the model's activity signal.
    func logActivity(
        kind: BackendAPI.ActivityKind,
        intensity: BackendAPI.ActivityIntensityLevel,
        durationMin: Int,
        at time: Date,
        comment: String? = nil
    ) async {
        let input = BackendAPI.NoteInput(
            timestamp: BackendAPI.formatNoteTimestampForRequest(time),
            carbs: 0,
            insulin: 0,
            meal: kind.title,
            comment: comment,
            glucoseValue: nil,
            absorptionMode: nil,
            nutritionProfile: nil,
            type: BackendAPI.NoteType.activity,
            activityType: kind.rawValue,
            intensity: intensity.rawValue,
            durationMin: durationMin
        )
        do {
            let note = try await BackendAPI.createNote(input)
            notes.append(note)
            await refreshCalculations()
        } catch {
            errorMessage = "Failed to log activity: \(error.localizedDescription)"
        }
    }

    // MARK: - Notes

    func fetchNotes() async {
        let generation = authGeneration
        isLoadingNotes = true
        notesLoadError = nil
        defer { if generation == authGeneration { isLoadingNotes = false } }
        do {
            let fetched = try await BackendAPI.fetchNotes()
            guard generation == authGeneration else { return }
            notes = fetched
            persistDashboardCache()
        } catch {
            // Retry once after a short pause - transient network errors (including concurrent
            // token-refresh races) usually clear immediately.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard generation == authGeneration else { return }
            do {
                let fetched = try await BackendAPI.fetchNotes()
                guard generation == authGeneration else { return }
                notes = fetched
                persistDashboardCache()
            } catch {
                guard generation == authGeneration else { return }
                // Only surface the error when there are no cached notes to show. If notes
                // are already loaded, a silent refresh failure is far less disruptive than
                // replacing the list with an error banner.
                if notes.isEmpty {
                    notesLoadError = "Failed to load notes"
                }
            }
        }
    }

    func createNote(_ input: BackendAPI.NoteInput, photo: UIImage? = nil) async {
        // iOS-2 fix: surface errors instead of silently swallowing them with try?
        do {
            var note = try await BackendAPI.createNote(input)
            if let photo {
                note = try await BackendAPI.uploadNotePhoto(noteId: note.id, image: photo)
            }
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
