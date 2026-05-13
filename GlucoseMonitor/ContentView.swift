import SwiftUI
import UIKit

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("Dashboard", systemImage: "waveform.path.ecg") }
            NotesView()
                .tabItem { Label("Notes", systemImage: "note.text") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .onAppear {
            appState.checkAuthentication()
            if appState.isAuthenticated {
                Task {
                    await GlucoseMonitorAPI.proactiveRefreshSessionTokensOnLaunch()
                    appState.checkAuthentication()
                }
                appState.startAutoRefreshIfNeeded()
            }
        }
        .onChange(of: scenePhase) { newPhase in
            guard newPhase == .active, appState.isAuthenticated else { return }
            Task {
                await GlucoseMonitorAPI.proactiveRefreshSessionTokens(minimumInterval: 10 * 60)
                await MainActor.run { appState.checkAuthentication() }
            }
        }
        .onChange(of: appState.isAuthenticated) { ok in
            if ok {
                Task {
                    await GlucoseMonitorAPI.proactiveRefreshSessionTokensOnLaunch()
                    await MainActor.run { appState.checkAuthentication() }
                }
                appState.startAutoRefreshIfNeeded()
            } else {
                appState.stopAutoRefresh()
            }
        }
    }
}

// MARK: - Dashboard

struct DashboardView: View {
    @EnvironmentObject var appState: AppState
    @State private var showAddNote = false
    @State private var showExtendedForecast = false
    @State private var showAI = false
    @State private var showNutrition = false
    @State private var showVersion = false
    @State private var noteToEdit: BackendAPI.GlucoseNote?

    var body: some View {
        NavigationStack {
            Group {
                if !appState.isAuthenticated {
                    notSignedInPlaceholder
                } else {
                    ScrollView {
                        VStack(spacing: 16) {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                compactGlucoseCard(at: context.date)
                            }
                            chartSection
                            recentNotesSection
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
                    Button { showAddNote = true } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(!appState.isAuthenticated)
                }
            }
            .sheet(isPresented: $showAddNote) {
                AddNoteSheet { input in
                    await appState.createNote(input)
                }
                .environmentObject(appState)
            }
            .sheet(isPresented: $showAI) { AIInsightsSheet() }
            .sheet(isPresented: $showNutrition) { NutritionAnalyzerSheet() }
            .sheet(isPresented: $showVersion) { VersionInfoSheet() }
            .sheet(item: $noteToEdit) { note in
                EditNoteSheet(note: note) { body in
                    await appState.updateNote(id: note.id, body: body)
                }
                .environmentObject(appState)
            }
            .task {
                guard appState.isAuthenticated else { return }
                if appState.currentReading == nil {
                    await appState.refreshAll()
                } else {
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
                                if let arrow = r.trendArrow, !arrow.isEmpty {
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
            } else if let lastNote = appState.notes
                        .filter({ $0.glucoseValue != nil && $0.timestamp != nil })
                        .sorted(by: { ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast) })
                        .first,
                      let gv = lastNote.glucoseValue,
                      let ts = lastNote.timestamp {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Manual reading")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(String(format: "%.1f", gv))
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Color.orange)
                        Text("mmol/L")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    (Text("From note · ") + Text(ts, style: .relative) + Text(" ago"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
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

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Glucose")
                .font(.headline)
            GlucoseHistoryChart(
                history: appState.glucoseHistory,
                prediction: appState.predictionChartPoints(),
                notes: appState.notes
            )
        }
        .padding()
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.07), radius: 8, y: 2)
        .overlay {
            ChartLongPressOverlay(minimumDuration: 0.3) {
                guard appState.isAuthenticated else { return }
                showAddNote = true
            }
        }
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
            } else if let err = appState.notesLoadError {
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

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Actions")
                .font(.headline)
            VStack(spacing: 0) {
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
        return srcIsMg ? value / 18.018 : value * 18.018
    }

    private func formatGlucose(_ value: Double, unit: String) -> String {
        unit.lowercased().contains("mg")
            ? String(format: "%.0f", value)
            : String(format: "%.1f", value)
    }

    /// Backend predictions are mmol/L; convert to the display unit.
    private func formatBackendGlucoseMmol(_ mmol: Double, displayUnit: String) -> String {
        if displayUnit.lowercased().contains("mg") {
            return String(format: "%.0f", mmol * 18.018)
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

// MARK: - UIKit long-press bridge (SwiftUI gestures are cancelled by Chart internals)
//
// Behaviour mirrors the lock-screen torch:
//   • touch-down  → immediate haptic ("press")
//   • lift after ≥ minimumDuration → second haptic ("release") + action fires
//   • lift before threshold           → nothing

private struct ChartLongPressOverlay: UIViewRepresentable {
    let minimumDuration: TimeInterval
    let onLongPress: () -> Void

    func makeUIView(context: Context) -> LongPressTrackingView {
        LongPressTrackingView(minimumDuration: minimumDuration, onLongPress: onLongPress)
    }

    func updateUIView(_ uiView: LongPressTrackingView, context: Context) {}
}

final class LongPressTrackingView: UIView {
    private let minimumDuration: TimeInterval
    private let onLongPress: () -> Void
    private var touchDownTime: Date?

    init(minimumDuration: TimeInterval, onLongPress: @escaping () -> Void) {
        self.minimumDuration = minimumDuration
        self.onLongPress = onLongPress
        super.init(frame: .zero)
        backgroundColor = .clear
        isMultipleTouchEnabled = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchDownTime = Date()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()  // "press down" click
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        defer { touchDownTime = nil }
        guard let t = touchDownTime,
              Date().timeIntervalSince(t) >= minimumDuration else { return }
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()   // "release" click
        onLongPress()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchDownTime = nil
    }

    // Pass all hits through so chart interactions still work.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit == self ? self : nil
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
