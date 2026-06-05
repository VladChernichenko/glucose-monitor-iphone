import SwiftUI
import UIKit

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: Int = 0
    @StateObject private var experimentVM = ExperimentViewModel()

    private static let dashboardTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView()
                .tag(Self.dashboardTab)
                .tabItem { Label("Dashboard", systemImage: "waveform.path.ecg") }
                .environmentObject(experimentVM)
            NotesView(selectedTab: $selectedTab)
                .tag(1)
                .tabItem { Label("Notes", systemImage: "note.text") }
            ExperimentsListView()
                .tag(2)
                .tabItem { Label("Experiments", systemImage: "flask.fill") }
                .environmentObject(experimentVM)
            SettingsView()
                .tag(3)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .onChange(of: selectedTab) { newTab in
            // Refresh glucose values whenever the user opens (selects) the Dashboard tab. Force an
            // on-demand server sync so the data is fresh on open (no spinner). Safe to call
            // unconditionally: the backend serialises/coalesces per-user syncs, refreshGlucoseOnly
            // coalesces with any in-flight refresh, and the token refresh has its own 45-min throttle.
            guard newTab == Self.dashboardTab, appState.isAuthenticated else { return }
            Task { await appState.refreshGlucoseOnly(silent: true, forceServerSync: true) }
        }
        .onAppear {
            appState.checkAuthentication()
            if appState.isAuthenticated {
                Task {
                    await GlucoseMonitorAPI.proactiveRefreshSessionTokensOnLaunch()
                    appState.checkAuthentication()
                    let hasCache = appState.currentReading != nil || !appState.glucoseHistory.isEmpty
                    if hasCache {
                        // Dashboard opened with cached data: force a fresh server sync (no spinner).
                        await appState.refreshGlucoseOnly(silent: true, forceServerSync: true)
                    } else if appState.currentReading == nil {
                        await appState.refreshAll()
                    }
                    await experimentVM.loadAvailable()
                }
                appState.startAutoRefreshIfNeeded()
                BackgroundRefreshService.scheduleNextRefresh()
            }
        }
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .background:
                guard appState.isAuthenticated else { return }
                BackgroundRefreshService.runBackgroundFetchIfNeeded()
            case .active:
                guard appState.isAuthenticated else { return }
                Task {
                    await GlucoseMonitorAPI.proactiveRefreshSessionTokens(minimumInterval: 10 * 60)
                    await MainActor.run { appState.checkAuthentication() }
                    let elapsed = appState.lastGlucoseRefresh.map { Date().timeIntervalSince($0) } ?? .infinity
                    guard elapsed > 45 else { return }
                    if appState.currentReading == nil {
                        await appState.refreshAll()
                    } else {
                        await appState.refreshGlucoseOnly(silent: true, forceServerSync: true)
                    }
                    await experimentVM.loadAvailable()
                }
            default:
                break
            }
        }
        .onChange(of: appState.isAuthenticated) { ok in
            if ok {
                selectedTab = Self.dashboardTab
                Task {
                    await GlucoseMonitorAPI.proactiveRefreshSessionTokensOnLaunch()
                    await MainActor.run { appState.checkAuthentication() }
                    await experimentVM.loadAvailable()
                }
                appState.startAutoRefreshIfNeeded()
            } else {
                appState.stopAutoRefresh()
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { !appState.isAuthenticated },
            set: { _ in }
        )) {
            SignInView()
                .environmentObject(appState)
        }
    }
}

// MARK: - Dashboard

struct DashboardView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var experimentVM: ExperimentViewModel
    @State private var showAddNote = false
    @State private var showExtendedForecast = false
    @State private var showAI = false
    @State private var showNutrition = false
    @State private var showVersion = false
    @State private var showBedsideMode = false
    @State private var showLongActing = false
    @State private var noteToEdit: BackendAPI.GlucoseNote?

    var body: some View {
        NavigationStack {
            Group {
                if !appState.isAuthenticated {
                    notSignedInPlaceholder
                } else {
                    ScrollView {
                        VStack(spacing: 16) {
                            if experimentVM.hasActiveExperiment, let exp = experimentVM.activeExperiment {
                                HStack(spacing: 10) {
                                    Image(systemName: "flask.fill")
                                        .foregroundStyle(.orange)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Experiment in Progress")
                                            .font(.subheadline.bold())
                                        Text(exp.type.title)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding()
                                .background(Color.orange.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14)
                                        .strokeBorder(Color.orange.opacity(0.4), lineWidth: 1)
                                )
                            }
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                compactGlucoseCard(at: context.date)
                            }
                            extendedChartSection
                            recentNotesSection
                            if appState.dataSource == "libre" {
                                sensorAlarmsBar
                            }
                            quickActions
                            if let msg = appState.errorMessage {
                                Text(msg)
                                    .font(.footnote)
                                    .foregroundColor(.red)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal)
                            }
                        }
                        .padding()
                    }
                    .refreshable { await appState.refreshAll() }
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await appState.refreshAll() }
                    } label: {
                        if appState.isLoading {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(appState.isLoading || !appState.isAuthenticated)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showBedsideMode = true } label: {
                        Image(systemName: "moon.stars")
                    }
                    .disabled(!appState.isAuthenticated)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showAddNote = true } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(!appState.isAuthenticated)
                }
            }
            .sheet(isPresented: $showAddNote) {
                NoteEditorSheet { input in
                    await appState.createNote(input)
                }
                .environmentObject(appState)
            }
            .sheet(isPresented: $showAI) { AIInsightsSheet() }
            .sheet(isPresented: $showNutrition) { NutritionAnalyzerSheet() }
            .fullScreenCover(isPresented: $showBedsideMode) {
                BedsideModeView().environmentObject(appState)
            }
            .sheet(isPresented: $showVersion) { VersionInfoSheet() }
            .sheet(isPresented: $showLongActing) {
                LongActingInsulinSheet(
                    insulinName: appState.insulinPrefs?.longActingInsulin.displayName ?? "Long-acting insulin"
                )
                .environmentObject(appState)
            }
            .sheet(item: $noteToEdit) { note in
                EditNoteSheet(note: note) { body in
                    await appState.updateNote(id: note.id, body: body)
                }
                .environmentObject(appState)
            }
            .task {
                guard appState.isAuthenticated else { return }
                if appState.currentReading == nil && appState.glucoseHistory.isEmpty {
                    await appState.refreshAll()
                } else {
                    let elapsed = appState.lastGlucoseRefresh.map { Date().timeIntervalSince($0) } ?? .infinity
                    if elapsed > 90 {
                        await appState.refreshGlucoseOnly(silent: true, forceServerSync: true)
                    }
                    await appState.fetchNotes()
                }
            }
        }
    }

    // MARK: - Compact glucose card (widget-style current to prediction + stacked COB/IOB)

    private static let dashboardGlucoseOrange = Color(red: 1, green: 0.58, blue: 0)
    private static let dashboardCobTint = Color(red: 0.92, green: 0.55, blue: 0.12)
    private static let dashboardIobTint = Color(red: 0.35, green: 0.45, blue: 0.95)

    private func compactGlucoseCard(at date: Date) -> some View {
        let calc = appState.calculations
        let pre = PreBolusTimer.state(notes: appState.notes, now: date)
        let cobStr = calc.map { String(format: "%.1f g", $0.activeCarbsOnBoard) } ?? "--"
        let iobStr = appState.displayedIOB.map { String(format: "%.2f u", $0) } ?? "--"

        return Group {
            if appState.isLoading && appState.currentReading == nil {
                ProgressView("Loading...")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else if let r = appState.currentReading, let v = r.value {
                let displayUnit = appState.preferredGlucoseUnit
                let displayValue = convertGlucose(v, from: r.unit, to: displayUnit)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 8) {
                            glucosePredictionHeadline(current: displayValue, unit: displayUnit, calc: calc, expanded: showExtendedForecast)
                                .minimumScaleFactor(0.55)
                                .lineLimit(1)
                                .animation(.easeInOut(duration: 0.2), value: showExtendedForecast)
                                .onTapGesture {
                                    guard calc?.predictionPath?.isEmpty == false else { return }
                                    withAnimation(.easeInOut(duration: 0.2)) { showExtendedForecast.toggle() }
                                }

                            HStack(alignment: .center, spacing: 10) {
                                if let arrow = r.trendArrow, !arrow.isEmpty, arrow != "?" {
                                    Text(arrow)
                                        .font(.system(size: 22, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }
                                if let status = r.status {
                                    statusBadge(status)
                                }
                            }

                            if let ts = r.timestamp {
                                (Text("Updated ") + Text(ts, style: .relative) + Text(" ago"))
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        VStack(alignment: .leading, spacing: 8) {
                            compactStackedMetric(
                                icon: "fork.knife",
                                title: "COB",
                                value: cobStr,
                                tint: Self.dashboardCobTint
                            )
                            compactStackedMetric(
                                icon: "syringe.fill",
                                title: "IOB",
                                value: iobStr,
                                tint: Self.dashboardIobTint
                            )
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.primary.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                        )
                    }

                    if pre.visible {
                        HStack(spacing: 6) {
                            Image(systemName: "timer")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.green)
                            Text("Pre-bolus \(pre.label)")
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.green)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.green.opacity(0.12)))
                    }
                }
            } else if let manual = appState.latestManualGlucose {
                let effectiveCurrent = appState.effectiveManualGlucoseMmol ?? manual.value
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 8) {
                            glucosePredictionHeadline(
                                current: effectiveCurrent,
                                unit: "mmol/L",
                                calc: calc,
                                expanded: showExtendedForecast
                            )
                            .minimumScaleFactor(0.55)
                            .lineLimit(1)
                            .animation(.easeInOut(duration: 0.2), value: showExtendedForecast)
                            .onTapGesture {
                                guard calc?.predictionPath?.isEmpty == false else { return }
                                withAnimation(.easeInOut(duration: 0.2)) { showExtendedForecast.toggle() }
                            }
                            (Text("Updated ") + Text(manual.timestamp, style: .relative) + Text(" ago"))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        VStack(alignment: .leading, spacing: 8) {
                            compactStackedMetric(icon: "fork.knife",  title: "COB", value: cobStr, tint: Self.dashboardCobTint)
                            compactStackedMetric(icon: "syringe.fill", title: "IOB", value: iobStr, tint: Self.dashboardIobTint)
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 12)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.04)))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "drop.circle")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No reading yet")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text("Pull down to refresh")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.07), radius: 10, y: 3)
    }

    @ViewBuilder
    private func glucosePredictionHeadline(current: Double, unit: String, calc: BackendAPI.GlucoseCalculationsResponse?, expanded: Bool = false) -> some View {
        let unitStr = unitLabel(unit)
        let fourHour = calc?.predictionPath?.last?.predictedGlucose

        if let calc {
            VStack(alignment: .leading, spacing: 2) {
                // Label row
                HStack(spacing: 0) {
                    Text("Now")
                        .frame(minWidth: 60, alignment: .leading)
                    Spacer().frame(width: 36)
                    Text("2h forecast")
                    if expanded, fourHour != nil {
                        Spacer().frame(width: 36)
                        Text("4h forecast")
                    }
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

                // Number row
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(formatGlucose(current, unit: unit))
                        .frame(minWidth: 60, alignment: .leading)
                    Text("\u{2192}")
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundStyle(Self.dashboardGlucoseOrange.opacity(0.7))
                    Text(formatBackendGlucoseMmol(calc.twoHourPrediction, displayUnit: unit))
                    if expanded, let fh = fourHour {
                        Text("\u{2192}")
                            .font(.system(size: 24, weight: .semibold, design: .rounded))
                            .foregroundStyle(Self.dashboardGlucoseOrange.opacity(0.7))
                        Text(formatBackendGlucoseMmol(fh, displayUnit: unit))
                    }
                    Text(unitStr)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Self.dashboardGlucoseOrange)
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("Now")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(formatGlucose(current, unit: unit))
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Self.dashboardGlucoseOrange)
                    Text(unitStr)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func compactStackedMetric(icon: String, title: String, value: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 16, alignment: .center)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(tint.opacity(0.9))
                Text(value)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.primary)
            }
        }
    }

    // MARK: - Chart

    // MARK: - Sensor & Alarms bar (LLU only)

    @ViewBuilder
    private var sensorAlarmsBar: some View {
        VStack(spacing: 8) {
            // Sensor row
            if let sensor = appState.sensorInfo, sensor.status != "unknown" {
                HStack(spacing: 8) {
                    Image(systemName: sensorStatusIcon(sensor.status))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(sensorStatusColor(sensor))
                    Text(sensor.sensorModel ?? "FreeStyle Libre")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    if let remaining = sensor.daysRemaining {
                        Text(sensorRemainingLabel(remaining))
                            .font(.caption.weight(.medium).monospacedDigit())
                            .foregroundStyle(sensorStatusColor(sensor))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(sensorStatusColor(sensor).opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(sensorStatusColor(sensor).opacity(0.18), lineWidth: 1)
                )
            }

        }
    }

    private func sensorStatusIcon(_ status: String?) -> String {
        switch status {
        case "active":  return "sensor.tag.radiowaves.forward.fill"
        case "warmup":  return "timer"
        case "expired": return "exclamationmark.triangle.fill"
        default:        return "sensor.tag.radiowaves.forward"
        }
    }

    private func sensorStatusColor(_ sensor: GlucoseMonitorAPI.LibreSensorInfo) -> Color {
        let remaining = sensor.daysRemaining ?? 99
        switch sensor.status {
        case "expired": return .red
        case "warmup":  return .orange
        case "active":
            if remaining <= 1 { return .red }
            if remaining <= 3 { return .orange }
            return .green
        default: return .secondary
        }
    }

    private func sensorRemainingLabel(_ days: Int) -> String {
        if days < 0  { return "Expired" }
        if days == 0 { return "Expires today" }
        if days == 1 { return "1 day left" }
        return "\(days) days left"
    }

    private var extendedChartSection: some View {
        let is8h = appState.calculations?.eightHourPrediction != nil
        let window: GlucoseChartWindow = is8h ? .extended : .standard
        return VStack(alignment: .leading, spacing: 8) {
            Text(is8h ? "Forecast (4h / 8h)" : "Forecast (4h)")
                .font(.headline)
            GlucoseHistoryChart(
                history: appState.glucoseHistory,
                prediction: appState.predictionChartPoints(),
                notes: appState.notes,
                window: window,
                currentGlucose: appState.currentGlucoseMmolForAPI()
            )
        }
        .padding()
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.07), radius: 8, y: 2)
    }

    // MARK: - Recent notes (12h)

    private var recentNotesSection: some View {
        let slice = recentNotesLast12Hours
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent notes (12h)")
                    .font(.headline)
                Spacer()
                if appState.isLoadingNotes {
                    ProgressView()
                        .scaleEffect(0.75)
                }
            }
            if appState.isLoadingNotes && appState.notes.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading notes…")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            } else if let err = appState.notesLoadError, slice.isEmpty {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundColor(.orange)
            } else if slice.isEmpty {
                Text("No notes in the last 12 hours.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                // swipeActions only apply inside a List (not plain VStack/ScrollView rows).
                List {
                    ForEach(slice) { note in
                        RecentNoteRow(note: note)
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.visible)
                            .contentShape(Rectangle())
                            .onTapGesture { noteToEdit = note }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    Task { await appState.deleteNote(id: note.id) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .environment(\.defaultMinListRowHeight, 72)
                .frame(height: CGFloat(slice.count) * 100)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.07), radius: 8, y: 2)
    }

    private var recentNotesLast12Hours: [BackendAPI.GlucoseNote] {
        let now = Date()
        let start = now.addingTimeInterval(-12 * 3600)
        return appState.notes
            .filter {
                guard let t = $0.timestamp else { return false }
                return t >= start && t <= now
            }
            .sorted { ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast) }
            .prefix(8)
            .map { $0 }
    }

    // MARK: - Quick actions

    /// Long-acting (basal) logging row. Enabled only within the window around the user's configured
    /// injection time (always enabled when no time is set). Shows the schedule as a subtitle.
    private var longActingActionRow: some View {
        let status = LongActingSchedule.status(injectionTimeHHmm: appState.insulinPrefs?.longActingInjectionTime)
        return Button { showLongActing = true } label: {
            HStack {
                Label("Long-acting insulin", systemImage: "syringe")
                    .font(.subheadline)
                Spacer()
                if !status.label.isEmpty {
                    Text(status.label)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .foregroundColor(.primary)
        }
        .disabled(!status.enabled)
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Actions")
                .font(.headline)
            VStack(spacing: 0) {
                longActingActionRow
                Divider()
                Button { showAI = true } label: {
                    quickActionRow(title: "AI insights", systemImage: "sparkles")
                }
                Divider()
                Button { showNutrition = true } label: {
                    quickActionRow(title: "Nutrition GI/GL", systemImage: "leaf")
                }
                Divider()
                Button { showVersion = true } label: {
                    quickActionRow(title: "Version & compatibility", systemImage: "info.circle")
                }
                Divider()
                NavigationLink(destination: SettingsView()) {
                    quickActionRow(title: "Data source & account", systemImage: "gearshape")
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.07), radius: 8, y: 2)
    }

    private func quickActionRow(title: String, systemImage: String) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
                .font(.subheadline)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .foregroundColor(.primary)
    }

    // MARK: Placeholder

    private var notSignedInPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.badge.key")
                .font(.system(size: 56))
                .foregroundColor(.secondary)
            Text("Not signed in")
                .font(.title2.bold())
            Text("Open Settings to configure your backend and sign in.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    // MARK: Helpers

    private func statusBadge(_ status: String) -> some View {
        let label: String
        let color: Color
        switch status.lowercased() {
        case "critical": label = "Critical"; color = .red
        case "low":      label = "Low";      color = .orange
        case "high":     label = "High";     color = Color(red: 0.85, green: 0.55, blue: 0)
        default:         label = "Normal";   color = .green
        }
        return Text(label)
            .font(.caption.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .clipShape(Capsule())
    }

    /// Convert a glucose value between units. `from` is the source unit string (nil treated as mmol/L).
    private func convertGlucose(_ value: Double, from sourceUnit: String?, to targetUnit: String) -> Double {
        let srcIsMg = (sourceUnit ?? "mmol/L").lowercased().contains("mg")
        let dstIsMg = targetUnit.lowercased().contains("mg")
        if srcIsMg == dstIsMg { return value }
        return srcIsMg ? GlucoseUnit.mgdlToMmol(value) : GlucoseUnit.mmolToMgdl(value)
    }

    private func formatGlucose(_ value: Double, unit: String) -> String {
        unit.lowercased().contains("mg")
            ? String(format: "%.0f", value)
            : String(format: "%.1f", value)
    }

    /// Backend predictions are mmol/L; convert to the display unit.
    private func formatBackendGlucoseMmol(_ mmol: Double, displayUnit: String) -> String {
        if displayUnit.lowercased().contains("mg") {
            return String(format: "%.0f", GlucoseUnit.mmolToMgdl(mmol))
        }
        return String(format: "%.1f", mmol)
    }

    private func unitLabel(_ unit: String) -> String {
        unit.lowercased().contains("mg") ? "mg/dL" : "mmol/L"
    }

}

// MARK: - Recent note row (dashboard)

private struct RecentNoteRow: View {
    let note: BackendAPI.GlucoseNote
    @EnvironmentObject private var appState: AppState
    @State private var confirmDelete = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(Color.green.opacity(0.6))
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 4) {
                Text(note.meal.isEmpty ? "Note" : note.meal)
                    .font(.subheadline.weight(.medium))
                if let ts = note.timestamp {
                    Text(ts, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                HStack(spacing: 8) {
                    if note.carbs > 0 {
                        Text(String(format: "%.0f g", note.carbs))
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    if note.insulin > 0 {
                        Text(String(format: "%.1f u", note.insulin))
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.purple.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    if let gv = appState.glucoseMmolForNoteRowDisplay(note) {
                        Label(String(format: "%.1f", gv), systemImage: "drop.fill")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
            if let photoUrl = note.photoUrl, !photoUrl.isEmpty {
                NotePhotoThumbnail(urlString: photoUrl)
            }
            Button {
                confirmDelete = true
            } label: {
                Text("Del")
                    .font(.caption2.weight(.medium))
                    .foregroundColor(.blue)
            }
            .buttonStyle(.plain)
            .frame(alignment: .center)
            .alert("Delete note?", isPresented: $confirmDelete) {
                Button("Yes", role: .destructive) {
                    Task { await appState.deleteNote(id: note.id) }
                }
                Button("No", role: .cancel) {}
            }
        }
        .padding(.vertical, 6)
    }
}


private struct NotePhotoThumbnail: View {
    let urlString: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 52, height: 52)
                    .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            }
        }
        .task(id: urlString) {
            image = await loadImage(from: urlString)
        }
    }

    private func loadImage(from urlString: String) async -> UIImage? {
        let base = GlucoseMonitorAPI.effectiveBackendBaseURL()
        let fullURL: String
        if urlString.hasPrefix("http://") || urlString.hasPrefix("https://") {
            fullURL = urlString
        } else {
            fullURL = base + (urlString.hasPrefix("/") ? urlString : "/\(urlString)")
        }
        guard let url = URL(string: fullURL),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return UIImage(data: data)
    }
}
