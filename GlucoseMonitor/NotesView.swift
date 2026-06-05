import SwiftUI
import AVFoundation

private func formReadonlyRow(label: String, valueText: String) -> some View {
    HStack {
        Text(label)
        Spacer()
        Text(valueText)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
    }
}

// MARK: - Notes List

// MARK: - Sheet state

private enum NoteSheet: Identifiable {
    case add
    case edit(BackendAPI.GlucoseNote)
    case foodScan

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let n): return n.id
        case .foodScan: return "foodScan"
        }
    }
}

struct NotesView: View {
    @EnvironmentObject var appState: AppState
    @Binding var selectedTab: Int
    @State private var activeSheet: NoteSheet?

    private var sortedNotes: [BackendAPI.GlucoseNote] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
        return appState.notes
            .filter { ($0.timestamp ?? .distantPast) >= cutoff }
            .sorted { ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if !appState.isAuthenticated {
                    notSignedInPlaceholder
                } else if sortedNotes.isEmpty {
                    emptyPlaceholder
                } else {
                    List {
                        ForEach(sortedNotes) { note in
                            NoteRowView(note: note)
                                .contentShape(Rectangle())
                                .onTapGesture { activeSheet = .edit(note) }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        Task { await appState.deleteNote(id: note.id) }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                    }
                }
            }
            .navigationTitle("Notes")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 4) {
                        scanFoodButton
                        addNoteButton
                    }
                }
            }
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .add:
                    NoteEditorSheet { input in
                        await appState.createNote(input)
                        selectedTab = 0
                    }
                    .environmentObject(appState)
                case .edit(let note):
                    EditNoteSheet(note: note) { body in
                        await appState.updateNote(id: note.id, body: body)
                        selectedTab = 0
                    }
                    .environmentObject(appState)
                case .foodScan:
                    FoodScanSheet { input in
                        await appState.createNote(input)
                        selectedTab = 0
                    }
                    .environmentObject(appState)
                }
            }
            .task(id: appState.isAuthenticated) {
                guard appState.isAuthenticated else { return }
                await appState.fetchNotes()
                await appState.refreshGlucoseOnly()
            }
        }
    }

    private var addNoteButton: some View {
        Button {
            activeSheet = .add
        } label: {
            Image(systemName: "plus")
        }
        .disabled(!appState.isAuthenticated)
    }

    private var scanFoodButton: some View {
        Button {
            activeSheet = .foodScan
        } label: {
            Image(systemName: "camera.viewfinder")
        }
        .disabled(!appState.isAuthenticated)
    }

    private var notSignedInPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.badge.key")
                .font(.system(size: 56))
                .foregroundColor(.secondary)
            Text("Not signed in")
                .font(.title2.bold())
            Text("Sign in from Settings to manage notes.")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    private var emptyPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "note.text")
                .font(.system(size: 56))
                .foregroundColor(.secondary)
            Text("No notes yet")
                .font(.title2.bold())
            Text("Tap + to log a meal or insulin dose.")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }
}

// MARK: - Note Row

struct NoteRowView: View {
    let note: BackendAPI.GlucoseNote
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(note.meal.isEmpty ? "Note" : note.meal)
                    .font(.headline)
                if note.isLongActing {
                    Text("Long-acting")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.indigo.opacity(0.15))
                        .foregroundColor(.indigo)
                        .clipShape(Capsule())
                }
                Spacer()
                if let ts = note.timestamp {
                    Text(ts, style: .relative)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            HStack(spacing: 12) {
                if note.carbs > 0 {
                    Label(String(format: "%.0f g carbs", note.carbs), systemImage: "fork.knife")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if note.insulin > 0 {
                    Label(String(format: "%.1f u", note.insulin), systemImage: "cross.vial")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if let gv = appState.glucoseMmolForNoteRowDisplay(note) {
                    Label(String(format: "%.1f", gv), systemImage: "drop.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if let comment = note.comment, !comment.isEmpty {
                Text(comment)
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.75))
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Note amount sliders

private struct NoteIntStepSliderRow: View {
    let title: String
    let unit: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(value) \(unit)")
                    .font(.subheadline.monospacedDigit().weight(.medium))
            }
            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { raw in
                        let stepped = Int((raw / Double(step)).rounded()) * step
                        value = min(range.upperBound, max(range.lowerBound, stepped))
                    }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: Double(step)
            )
        }
        .padding(.vertical, 6)
    }
}

private struct NoteDoubleStepSliderRow: View {
    let title: String
    let unit: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f %@", value, unit))
                    .font(.subheadline.monospacedDigit().weight(.medium))
            }
            Slider(
                value: Binding(
                    get: { value },
                    set: { raw in
                        let stepped = (raw / step).rounded() * step
                        value = min(range.upperBound, max(range.lowerBound, stepped))
                    }
                ),
                in: range,
                step: step
            )
        }
        .padding(.vertical, 6)
    }
}

/// Glucose at note time; `0` means not set (shown as em dash).
private struct NoteGlucoseSliderRow: View {
    @Binding var mmol: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Glucose (mmol/L)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(mmol > 0 ? String(format: "%.1f", mmol) : "-")
                    .font(.subheadline.monospacedDigit().weight(.medium))
            }
            Slider(
                value: Binding(
                    get: { mmol },
                    set: { raw in
                        if raw < 0.5 {
                            mmol = 0
                        } else {
                            mmol = (min(25.0, max(1.0, raw)) * 10).rounded() / 10
                        }
                    }
                ),
                in: 0...25,
                step: 0.1
            )
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Unified Note Editor

/// Single sheet for both manual note entry and food-scan result review.
/// Shows captured image and detected nutrition when available; falls back to plain form.
struct NoteEditorSheet: View {
    var image: UIImage? = nil
    var snapshot: BackendAPI.NutritionSnapshot? = nil
    var arVolumeReport: NutrientSummary? = nil
    let onCreate: (BackendAPI.NoteInput) async -> Void

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var noteDate = Date()
    @State private var meal = "Lunch"
    @State private var carbs: Int = 0
    @State private var insulin: Double = 0.0
    @State private var glucoseWheelValue: Double = 0.0
    @State private var comment = ""
    @State private var isSaving = false
    @State private var prospectiveCalc: BackendAPI.GlucoseCalculationsResponse? = nil
    @State private var isFetchingProspective = false

    private let meals = ["Breakfast", "Lunch", "Dinner", "Snack", "Pre-bolus", "Correction", "Other"]
    private static let glucoseOptions: [Double] = [0.0] + stride(from: 1.0, through: 25.0, by: 0.1)
                                                       .map { ($0 * 10).rounded() / 10 }

    var body: some View {
        NavigationStack {
            List {
                // ── Image (food scan photo or AR frame) ─────────────────────
                if let img = image {
                    Section {
                        Image(uiImage: img)
                            .resizable().scaledToFit()
                            .frame(maxHeight: 220).frame(maxWidth: .infinity)
                            .cornerRadius(10)
                            .listRowInsets(EdgeInsets())
                    }
                }

                // ── AR volume scan card ──────────────────────────────────────
                if let summary = arVolumeReport {
                    Section {
                        NutrientScanCard(summary: summary)
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                            .listRowBackground(Color.clear)
                    }
                }

                // ── Pre-bolus advice ─────────────────────────────────────────
                if let pause = snapshot?.preBolusPauseMinutes {
                    Section { preBolusBanner(pause: pause) }
                }

                // ── Detected foods ───────────────────────────────────────────
                if let foods = snapshot?.normalizedFoods, !foods.isEmpty {
                    Section("Detected foods") {
                        ForEach(foods, id: \.self) { Text($0.capitalized) }
                    }
                }

                // ── Nutrition summary (read-only) ────────────────────────────
                if let snap = snapshot {
                    Section("Nutrition") {
                        nutritionRow("Carbs",          value: snap.totalCarbs,   unit: "g")
                        nutritionRow("Fiber",          value: snap.fiber,        unit: "g")
                        nutritionRow("Protein",        value: snap.protein,      unit: "g")
                        nutritionRow("Fat",            value: snap.fat,          unit: "g")
                        nutritionRow("Glycemic Index", value: snap.estimatedGi,  unit: "")
                        nutritionRow("Glycemic Load",  value: snap.glycemicLoad, unit: "")
                        if let speed = snap.absorptionSpeedClass {
                            HStack { Text("Absorption"); Spacer()
                                Text(speed.capitalized).foregroundColor(.secondary) }
                        }
                        if let strategy = snap.bolusStrategy {
                            HStack { Text("Bolus type"); Spacer()
                                Text(strategy).foregroundColor(.secondary) }
                        }
                    }
                    if let curve = snap.curveDescription {
                        Section("Glucose curve") {
                            Text(curve).font(.subheadline).foregroundStyle(.secondary)
                            glucoseForecastRow()
                        }
                    }
                }

                // ── Editable fields ──────────────────────────────────────────
                Section("Time") {
                    DatePicker("Date & time", selection: $noteDate, in: ...Date(),
                               displayedComponents: [.date, .hourAndMinute])
                }
                Section("Meal") {
                    Picker("Type", selection: $meal) {
                        ForEach(meals, id: \.self) { Text($0) }
                    }
                }
                Section("Amounts") {
                    NoteIntStepSliderRow(
                        title: "Carbs (g)", unit: "g",
                        value: $carbs, range: 0...200, step: 5
                    )
                    NoteDoubleStepSliderRow(
                        title: "Insulin (u)", unit: "u",
                        value: $insulin, range: 0...30, step: 0.5
                    )
                    NoteGlucoseSliderRow(mmol: $glucoseWheelValue)
                }
                Section("Comment") {
                    TextField("Optional note", text: $comment, axis: .vertical).lineLimit(3...)
                }
                Section {
                    Button(action: saveTapped) {
                        if isSaving { ProgressView().frame(maxWidth: .infinity) }
                        else { Text(snapshot != nil ? "Add to Note" : "Save Note")
                                .frame(maxWidth: .infinity).bold() }
                    }
                    .disabled(isSaving)
                }
            }
            .navigationTitle(snapshot != nil ? "Nutrition" : "Add Note")
            .navigationBarTitleDisplayMode(.inline)
            .dismissKeyboardOnInteraction()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { hideKeyboard(); dismiss() }
                }
            }
            .task {
                await appState.refreshGlucoseOnly()
                prefillFromSnapshot()
                prefillGlucoseIfEmpty(appState.glucoseMmolForNewNote(at: noteDate))
                if snapshot != nil { await fetchProspectivePrediction() }
            }
            .onChange(of: noteDate) { _ in
                glucoseWheelValue = 0.0
                prefillGlucoseIfEmpty(appState.glucoseMmolForNewNote(at: noteDate))
            }
        }
    }

    // MARK: Prefill

    private func prefillFromSnapshot() {
        guard let snap = snapshot else { return }
        let rounded = Int((snap.totalCarbs ?? 0).rounded())
        carbs = max(0, min(200, (rounded / 5) * 5))
    }

    private func prefillGlucoseIfEmpty(_ value: Double?) {
        guard glucoseWheelValue == 0.0, let v = value else { return }
        let snapped = (v * 10).rounded() / 10
        glucoseWheelValue = Self.glucoseOptions.contains(snapped) ? snapped : 0.0
    }

    // MARK: Glucose forecast

    private func fetchProspectivePrediction() async {
        guard !isFetchingProspective, let snap = snapshot,
              let currentGlucose = appState.currentGlucoseMmolForAPI() else { return }
        isFetchingProspective = true
        defer { isFetchingProspective = false }
        prospectiveCalc = try? await BackendAPI.fetchGlucoseCalculations(
            currentGlucose: currentGlucose, prospectiveSnapshot: snap)
    }

    @ViewBuilder
    private func glucoseForecastRow() -> some View {
        let calc = prospectiveCalc ?? appState.calculations
        let cur  = appState.currentGlucoseMmolForAPI()
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                forecastCell(label: "Now", value: cur)
                forecastArrow()
                forecastCell(label: "2 h",  value: calc?.twoHourPrediction)
                forecastArrow()
                forecastCell(label: "4 h",  value: calc?.fourHourPrediction)
                if calc?.eightHourPrediction != nil {
                    forecastArrow()
                    forecastCell(label: "8 h", value: calc?.eightHourPrediction)
                }
            }
            .padding(.vertical, 4)
            if isFetchingProspective {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7)
                    Text("Calculating meal impact…").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private func forecastArrow() -> some View {
        Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func forecastCell(label: String, value: Double?) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.tertiary)
            if let v = value {
                Text(String(format: "%.1f", v)).font(.title3.bold()).foregroundStyle(glucoseColor(v))
            } else {
                Text("—").font(.title3.bold()).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func glucoseColor(_ mmol: Double) -> Color {
        if mmol < 4.0 { return .red }
        if mmol > 10.0 { return .orange }
        return .green
    }

    // MARK: Sub-views

    private func nutritionRow(_ label: String, value: Double?, unit: String) -> some View {
        HStack {
            Text(label); Spacer()
            if let v = value {
                Text(unit.isEmpty ? String(format: "%.0f", v)
                                  : String(format: "%.1f %@", v, unit))
                    .foregroundColor(.secondary)
            } else { Text("—").foregroundColor(.secondary) }
        }
    }

    @ViewBuilder
    private func preBolusBanner(pause: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "syringe.fill").font(.title2).foregroundStyle(.white)
                .frame(width: 40, height: 40).background(Circle().fill(Color.purple))
            VStack(alignment: .leading, spacing: 2) {
                if pause == 0 {
                    Text("Bolus at meal start").font(.headline)
                    Text("Split or post-meal bolus — inject when you begin eating")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Inject \(pause) min before eating").font(.headline)
                    Text(preBolusPauseReason(pause: pause)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func preBolusPauseReason(pause: Int) -> String {
        switch pause {
        case 20...: return "High-GI food — early injection prevents post-meal spike"
        case 15..<20: return "Medium-GI food — pre-bolus improves peak control"
        case 10..<15: return "Low-medium GI — short head-start recommended"
        default:     return "Low-GI / high-fiber — minimal pre-bolus needed"
        }
    }

    // MARK: Save

    private func saveTapped() {
        guard !isSaving else { return }
        hideKeyboard()
        Task {
            await MainActor.run { isSaving = true }
            let glucoseVal: Double? = glucoseWheelValue > 0 ? glucoseWheelValue
                : appState.glucoseMmolForNewNote(at: noteDate)
            let input = BackendAPI.NoteInput(
                timestamp: BackendAPI.formatNoteTimestampForRequest(noteDate),
                carbs: Double(carbs),
                insulin: insulin,
                meal: meal,
                comment: buildComment(),
                glucoseValue: glucoseVal,
                absorptionMode: snapshot?.absorptionMode,
                nutritionProfile: snapshot.map { BackendAPI.snapshotToNutritionProfileJson($0) } ?? nil
            )
            await onCreate(input)
            try? await Task.sleep(nanoseconds: 80_000_000)
            await MainActor.run { hideKeyboard(); isSaving = false; dismiss() }
        }
    }

    private func buildComment() -> String? {
        var parts: [String] = []
        if let foods = snapshot?.normalizedFoods, !foods.isEmpty {
            parts.append(foods.joined(separator: ", "))
        }
        if !comment.isEmpty { parts.append(comment) }
        if let gi = snapshot?.estimatedGi { parts.append("GI \(Int(gi))") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Edit note

struct EditNoteSheet: View {
    let note: BackendAPI.GlucoseNote
    let onSave: (BackendAPI.UpdateNoteBody) async -> Void
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var noteDate: Date
    @State private var meal: String
    @State private var carbs: Int           // steps of 5 g  (iOS-3 fix)
    @State private var insulin: Double      // steps of 0.5 u (iOS-3 fix)
    @State private var comment: String
    @State private var glucoseWheelValue: Double
    @State private var isSaving = false

    private let meals = ["Breakfast", "Lunch", "Dinner", "Snack", "Pre-bolus", "Correction", "Other"]

    init(note: BackendAPI.GlucoseNote, onSave: @escaping (BackendAPI.UpdateNoteBody) async -> Void) {
        self.note = note
        self.onSave = onSave
        _noteDate = State(initialValue: note.timestamp ?? Date())
        _meal = State(initialValue: note.meal.isEmpty ? "Other" : note.meal)
        // iOS-3 fix: snap to 5g steps instead of 10g (35g → 35, not 40g)
        let roundedCarbs = min(200, max(0, Int((note.carbs / 5).rounded()) * 5))
        // iOS-3 fix: snap to 0.5u steps instead of 1u (2.7u → 2.5, not 3u)
        let roundedInsulin = min(30.0, max(0.0, (note.insulin * 2).rounded() / 2))
        _carbs = State(initialValue: roundedCarbs)
        _insulin = State(initialValue: roundedInsulin)
        _comment = State(initialValue: note.comment ?? "")
        let snapped = note.glucoseValue.map { (($0 * 10).rounded() / 10) } ?? 0.0
        _glucoseWheelValue = State(initialValue: snapped)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Time") {
                    DatePicker("Date & time", selection: $noteDate, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                }
                Section("Meal") {
                    Picker("Type", selection: $meal) {
                        ForEach(meals, id: \.self) { Text($0) }
                    }
                }
                Section("Amounts") {
                    NoteIntStepSliderRow(
                        title: "Carbs (g)", unit: "g",
                        value: $carbs, range: 0...200, step: 5
                    )
                    NoteDoubleStepSliderRow(
                        title: "Insulin (u)", unit: "u",
                        value: $insulin, range: 0...30, step: 0.5
                    )
                    NoteGlucoseSliderRow(mmol: $glucoseWheelValue)
                }
                Section("Comment") {
                    TextField("Optional note", text: $comment, axis: .vertical)
                        .lineLimit(3...)
                }
            }
            .navigationTitle("Edit Note")
            .task {
                await appState.refreshGlucoseOnly()
            }
            .navigationBarTitleDisplayMode(.inline)
            .dismissKeyboardOnInteraction()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        hideKeyboard()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: saveTapped)
                        .disabled(isSaving)
                }
            }
        }
    }

    private func saveTapped() {
        guard !isSaving else { return }
        hideKeyboard()
        Task {
            await MainActor.run { isSaving = true }
            let ts = BackendAPI.formatNoteTimestampForRequest(noteDate)
            let glucoseVal: Double? = glucoseWheelValue > 0 ? glucoseWheelValue : nil
            let body = BackendAPI.UpdateNoteBody(
                timestamp: ts,
                carbs: Double(carbs),
                insulin: insulin,          // iOS-3 fix: already Double (0.5u steps)
                meal: meal,
                comment: comment.isEmpty ? nil : comment,
                glucoseValue: glucoseVal
            )
            await onSave(body)
            try? await Task.sleep(nanoseconds: 80_000_000)
            await MainActor.run {
                hideKeyboard()
                isSaving = false
                dismiss()
            }
        }
    }
}

// MARK: - Camera Picker

struct CameraPickerView: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    var sourceType: UIImagePickerController.SourceType = .camera
    let onCapture: (UIImage) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(sourceType) ? sourceType : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: CameraPickerView
        init(_ parent: CameraPickerView) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let image = info[.originalImage] as? UIImage else {
                parent.isPresented = false
                return
            }
            // iOS-5 fix: removed UIImageWriteToSavedPhotosAlbum — silently saved every
            // food/note photo to the user's Camera Roll without permission or consent.
            parent.isPresented = false
            parent.onCapture(image)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.isPresented = false
        }
    }
}

// MARK: - Food Scan Sheet

struct FoodScanSheet: View {
    let onCreate: (BackendAPI.NoteInput) async -> Void
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var showCamera = false
    @State private var showLibrary = false
    @State private var showARScanner = false
    @State private var showSourcePicker = true
    @State private var isAnalyzing = false
    @State private var analysisError: String? = nil
    @State private var capturedImage: UIImage?
    @State private var arSummary: NutrientSummary? = nil
    @State private var editorSnapshot: BackendAPI.NutritionSnapshot? = nil
    @State private var showNoteEditor = false
    @State private var noteSaved = false

    var body: some View {
        NavigationStack {
            Group {
                if showCamera || showLibrary {
                    Color.black.ignoresSafeArea()
                } else if showARScanner {
                    // ARFoodScannerView runs the full pipeline internally
                    // (segmentation → LiDAR volume → local nutrition lookup) and returns NutrientSummary.
                    ARFoodScannerView(
                        onResult: { summary in
                            Task { @MainActor in
                                showARScanner = false
                                arSummary      = summary
                                editorSnapshot = snapshotFrom(summary)
                                showNoteEditor = true
                            }
                        },
                        onDismiss: {
                            showARScanner = false
                            dismiss()
                        }
                    )
                    .ignoresSafeArea()
                } else if isAnalyzing {
                    analyzingView
                } else if let msg = analysisError {
                    errorView(msg)
                } else {
                    // Default background while confirmationDialog is visible or being dismissed.
                    // fullScreenCover requires a non-empty view hierarchy to present correctly.
                    Color(.systemBackground).ignoresSafeArea()
                }
            }
            .navigationTitle("Scan Food")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showNoteEditor, onDismiss: {
                if noteSaved { dismiss() }
            }) {
                NoteEditorSheet(
                    image: capturedImage ?? arSummary?.capturedImage,
                    snapshot: editorSnapshot,
                    arVolumeReport: arSummary,
                    onCreate: { input in
                        await onCreate(input)
                        await MainActor.run { noteSaved = true }
                    }
                )
                .environmentObject(appState)
            }
            .confirmationDialog("Choose Analysis Method", isPresented: $showSourcePicker, titleVisibility: .visible) {
                Button("AR Volume Scan") { showARScanner = true }
                Button("Take Photo")     { requestCameraAndOpen() }
                Button("Choose from Library") { showLibrary = true }
                Button("Cancel", role: .cancel) { dismiss() }
            }
            .fullScreenCover(isPresented: $showCamera, onDismiss: {
                if capturedImage == nil { dismiss() }
            }) {
                CameraPickerView(isPresented: $showCamera, sourceType: .camera) { image in
                    Task { @MainActor in capturedImage = image; await analyzePhoto(image) }
                }
                .ignoresSafeArea()
            }
            .fullScreenCover(isPresented: $showLibrary, onDismiss: {
                if capturedImage == nil { dismiss() }
            }) {
                CameraPickerView(isPresented: $showLibrary, sourceType: .photoLibrary) { image in
                    Task { @MainActor in capturedImage = image; await analyzePhoto(image) }
                }
                .ignoresSafeArea()
            }
        }
    }

    private var analyzingView: some View {
        VStack(spacing: 20) {
            if let img = capturedImage {
                Image(uiImage: img).resizable().scaledToFit()
                    .frame(maxHeight: 240).cornerRadius(12).padding(.horizontal)
            }
            ProgressView("Recognizing nutrition…").font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 48)).foregroundColor(.orange)
            Text("Analysis failed").font(.title2.bold())
            Text(message).foregroundColor(.secondary).multilineTextAlignment(.center).padding(.horizontal, 32)
            Button("Try Again") { analysisError = nil; showSourcePicker = true }.buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Camera permission gate

    private func requestCameraAndOpen() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            showCamera = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { if granted { showCamera = true } else { dismiss() } }
            }
        default:
            // Denied/restricted — open Settings so the user can re-enable
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        }
    }

    // MARK: - Photo analysis path (unchanged)

    @MainActor
    private func analyzePhoto(_ image: UIImage) async {
        isAnalyzing = true; analysisError = nil
        do {
            editorSnapshot = try await BackendAPI.analyzePhotoNutrition(image: image)
            showNoteEditor = true
        } catch {
            analysisError = error.localizedDescription
        }
        isAnalyzing = false
    }

    // MARK: - NutrientSummary → NutritionSnapshot bridge

    /// Converts a NutrientSummary into the BackendAPI snapshot format needed by
    /// NoteEditorSheet for carb prefill and glucose forecasting.
    private func snapshotFrom(_ s: NutrientSummary) -> BackendAPI.NutritionSnapshot {
        BackendAPI.NutritionSnapshot(
            absorptionMode:       "DEFAULT_DECAY",
            source:               "AR_LIDAR",
            confidence:           1.0,
            totalCarbs:           s.totalCarbsG,
            fiber:                nil,
            protein:              s.totalProteinG,
            fat:                  s.totalFatG,
            estimatedGi:          s.averageGI,
            glycemicLoad:         s.totalGL,
            absorptionSpeedClass: s.totalGL > 20 ? "FAST" : s.totalGL > 10 ? "MEDIUM" : "SLOW",
            normalizedFoods:      s.components.map(\.label),
            foodMassBreakdown:    nil,
            patternName:          nil,
            bolusStrategy:        nil,
            suggestedDurationHours: nil,
            mealSequencingPriority: nil,
            curveDescription:     nil,
            preBolusPauseMinutes: 15
        )
    }
}

// MARK: - Long-acting insulin

/// Sheet for logging a long-acting (basal) insulin dose. The insulin name is pre-filled from the
/// user's configured long-acting preference; the dose is saved as a note with type "long_acting".
struct LongActingInsulinSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let insulinName: String

    @State private var dose: Double = 10
    @State private var time: Date = Date()
    @State private var isSaving = false

    private static let lastDoseKey = "lastLongActingDose"

    var body: some View {
        NavigationStack {
            Form {
                Section("Long-acting insulin") {
                    HStack {
                        Text("Insulin")
                        Spacer()
                        Text(insulinName).foregroundColor(.secondary)
                    }
                    Stepper(value: $dose, in: 0...100, step: 0.5) {
                        HStack {
                            Text("Dose")
                            Spacer()
                            Text(String(format: "%.1f U", dose))
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                    }
                    DatePicker("Time", selection: $time, displayedComponents: [.hourAndMinute])
                }
            }
            .navigationTitle("Log long-acting")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        isSaving = true
                        UserDefaults.standard.set(dose, forKey: Self.lastDoseKey)
                        Task {
                            await appState.logLongActingInsulin(dose: dose, name: insulinName, at: time)
                            dismiss()
                        }
                    }
                    .disabled(isSaving || dose <= 0)
                }
            }
            .onAppear { dose = previousDose }
        }
    }

    /// Returns the last-used long-acting dose, preferring a recent note in appState
    /// over the UserDefaults persisted value, falling back to 10 U.
    private var previousDose: Double {
        // 1. Most recent long-acting note already loaded in appState (last 12 h)
        let longActing = appState.notes.filter { $0.isLongActing && $0.insulin > 0 }
        let sorted = longActing.sorted { ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast) }
        if let recentDose = sorted.first?.insulin { return recentDose }
        // 2. Persisted from a previous session / earlier in the day
        let stored = UserDefaults.standard.double(forKey: Self.lastDoseKey)
        if stored > 0 { return stored }
        // 3. Hardcoded fallback
        return 10
    }
}

