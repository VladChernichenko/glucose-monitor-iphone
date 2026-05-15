import SwiftUI

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
    @State private var activeSheet: NoteSheet?

    private var sortedNotes: [BackendAPI.GlucoseNote] {
        appState.notes.sorted {
            ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast)
        }
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
                    AddNoteSheet { input in
                        await appState.createNote(input)
                    }
                    .environmentObject(appState)
                case .edit(let note):
                    EditNoteSheet(note: note) { body in
                        await appState.updateNote(id: note.id, body: body)
                    }
                    .environmentObject(appState)
                case .foodScan:
                    FoodScanSheet { input in
                        await appState.createNote(input)
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

// MARK: - Add Note Sheet

struct AddNoteSheet: View {
    let onCreate: (BackendAPI.NoteInput) async -> Void
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var noteDate = Date()
    @State private var meal = "Lunch"
    @State private var carbs: Int = 0       // steps of 10 g
    @State private var insulin: Int = 0     // steps of 1 u
    @State private var comment = ""
    @State private var glucoseWheelValue: Double = 0.0  // 0.0 = not set
    @State private var isSaving = false

    private let meals = ["Breakfast", "Lunch", "Dinner", "Snack", "Pre-bolus", "Correction", "Other"]
    private let carbOptions   = Array(stride(from: 0, through: 200, by: 10))
    private let insulinOptions = Array(stride(from: 0, through: 30,  by: 1))
    private static let glucoseOptions: [Double] = [0.0] + stride(from: 1.0, through: 25.0, by: 0.1).map { (($0 * 10).rounded() / 10) }

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
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Insulin (u)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("Insulin", selection: $insulin) {
                            ForEach(insulinOptions, id: \.self) { Text("\($0) u").tag($0) }
                        }
                        .pickerStyle(.wheel)
                        .frame(height: 120)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Carbs (g)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("Carbs", selection: $carbs) {
                            ForEach(carbOptions, id: \.self) { Text("\($0) g").tag($0) }
                        }
                        .pickerStyle(.wheel)
                        .frame(height: 120)
                    }

                    glucoseWheelRow()
                }

                Section("Comment") {
                    TextField("Optional note", text: $comment, axis: .vertical)
                        .lineLimit(3...)
                }
            }
            .navigationTitle("Add Note")
            .task {
                await appState.refreshGlucoseOnly()
                prefillGlucoseIfEmpty(appState.glucoseMmolForNewNote(at: noteDate))

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

    @ViewBuilder
    private func glucoseWheelRow() -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Glucose (mmol/L)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Glucose", selection: $glucoseWheelValue) {
                Text("—").tag(0.0)
                ForEach(Self.glucoseOptions.dropFirst(), id: \.self) { v in
                    Text(String(format: "%.1f", v)).tag(v)
                }
            }
            .pickerStyle(.wheel)
            .frame(height: 120)
        }
    }

    private func prefillGlucoseIfEmpty(_ value: Double?) {
        guard glucoseWheelValue == 0.0, let v = value else { return }
        let snapped = (v * 10).rounded() / 10
        glucoseWheelValue = Self.glucoseOptions.contains(snapped) ? snapped : 0.0
    }

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
                insulin: Double(insulin),
                meal: meal,
                comment: comment.isEmpty ? nil : comment,
                glucoseValue: glucoseVal,
                absorptionMode: nil
            )
            await onCreate(input)
            try? await Task.sleep(nanoseconds: 80_000_000)
            await MainActor.run {
                hideKeyboard()
                isSaving = false
                dismiss()
            }
        }
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
    @State private var carbs: Int           // steps of 10 g
    @State private var insulin: Int         // steps of 1 u
    @State private var comment: String
    @State private var glucoseWheelValue: Double
    @State private var isSaving = false

    private let meals = ["Breakfast", "Lunch", "Dinner", "Snack", "Pre-bolus", "Correction", "Other"]
    private let carbOptions    = Array(stride(from: 0, through: 200, by: 10))
    private let insulinOptions = Array(stride(from: 0, through: 30,  by: 1))
    private static let glucoseOptions: [Double] = [0.0] + stride(from: 1.0, through: 25.0, by: 0.1).map { (($0 * 10).rounded() / 10) }

    init(note: BackendAPI.GlucoseNote, onSave: @escaping (BackendAPI.UpdateNoteBody) async -> Void) {
        self.note = note
        self.onSave = onSave
        _noteDate = State(initialValue: note.timestamp ?? Date())
        _meal = State(initialValue: note.meal.isEmpty ? "Other" : note.meal)
        let roundedCarbs = min(200, max(0, Int((note.carbs / 10).rounded()) * 10))
        let roundedInsulin = min(30, max(0, Int(note.insulin.rounded())))
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
                  

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Insulin (u)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("Insulin", selection: $insulin) {
                            ForEach(insulinOptions, id: \.self) { Text("\($0) u").tag($0) }
                        }
                        .pickerStyle(.wheel)
                        .frame(height: 120)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Carbs (g)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("Carbs", selection: $carbs) {
                            ForEach(carbOptions, id: \.self) { Text("\($0) g").tag($0) }
                        }
                        .pickerStyle(.wheel)
                        .frame(height: 120)
                    }

                    editGlucoseRow()
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

    @ViewBuilder
    private func editGlucoseRow() -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Glucose (mmol/L)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Glucose", selection: $glucoseWheelValue) {
                Text("—").tag(0.0)
                ForEach(Self.glucoseOptions.dropFirst(), id: \.self) { v in
                    Text(String(format: "%.1f", v)).tag(v)
                }
            }
            .pickerStyle(.wheel)
            .frame(height: 120)
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
                insulin: Double(insulin),
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
            UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
            parent.isPresented = false
            parent.onCapture(image)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.isPresented = false
        }
    }
}

// MARK: - Food Scan Sheet

private enum FoodScanStep {
    case analyzing
    case result(BackendAPI.NutritionSnapshot)
    case error(String)
}

struct FoodScanSheet: View {
    let onCreate: (BackendAPI.NoteInput) async -> Void
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var showCamera = false
    @State private var showLibrary = false
    @State private var showARScanner = false
    @State private var showSourcePicker = true
    @State private var step: FoodScanStep = .analyzing
    @State private var capturedImage: UIImage?
    /// Volume report from the AR pipeline (attached alongside nutrition snap when available)
    @State private var arVolumeReport: FoodVolumeReport?

    var body: some View {
        NavigationStack {
            Group {
                if showCamera || showLibrary {
                    Color.black.ignoresSafeArea()
                } else if showARScanner {
                    ARFoodScannerView(
                        onResult: { report in
                            Task { @MainActor in
                                showARScanner = false
                                arVolumeReport = report
                                await analyzeARReport(report)
                            }
                        },
                        onDismiss: {
                            showARScanner = false
                            if case .analyzing = step { dismiss() }
                        }
                    )
                    .ignoresSafeArea()
                } else {
                    switch step {
                    case .analyzing:
                        analyzingView
                    case .result(let snap):
                        NutritionResultView(
                            snapshot: snap,
                            image: capturedImage,
                            arVolumeReport: arVolumeReport,
                            onCreate: onCreate
                        )
                        .environmentObject(appState)
                    case .error(let msg):
                        errorView(msg)
                    }
                }
            }
            .navigationTitle("Scan Food")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .confirmationDialog("Choose Analysis Method", isPresented: $showSourcePicker, titleVisibility: .visible) {
                Button("AR Volume Scan") { showARScanner = true }
                Button("Take Photo") { showCamera = true }
                Button("Choose from Library") { showLibrary = true }
                Button("Cancel", role: .cancel) { dismiss() }
            }
            .fullScreenCover(isPresented: $showCamera, onDismiss: {
                if capturedImage == nil { dismiss() }
            }) {
                CameraPickerView(isPresented: $showCamera, sourceType: .camera) { image in
                    Task { @MainActor in
                        capturedImage = image
                        await analyzePhoto(image)
                    }
                }
                .ignoresSafeArea()
            }
            .fullScreenCover(isPresented: $showLibrary, onDismiss: {
                if capturedImage == nil { dismiss() }
            }) {
                CameraPickerView(isPresented: $showLibrary, sourceType: .photoLibrary) { image in
                    Task { @MainActor in
                        capturedImage = image
                        await analyzePhoto(image)
                    }
                }
                .ignoresSafeArea()
            }
        }
    }

    private var analyzingView: some View {
        VStack(spacing: 20) {
            if let img = capturedImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 240)
                    .cornerRadius(12)
                    .padding(.horizontal)
            }
            ProgressView("Recognizing nutrition…")
                .font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundColor(.orange)
            Text("Analysis failed")
                .font(.title2.bold())
            Text(message)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Try Again") { showSourcePicker = true }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Analysis paths

    @MainActor
    private func analyzePhoto(_ image: UIImage) async {
        step = .analyzing
        do {
            let snap = try await BackendAPI.analyzePhotoNutrition(image: image)
            step = .result(snap)
        } catch {
            step = .error(error.localizedDescription)
        }
    }

    /// Convert AR volume report → text description → backend nutrition analysis.
    /// The backend enriches the mass-based description with GI/GL/pattern data.
    @MainActor
    private func analyzeARReport(_ report: FoodVolumeReport) async {
        step = .analyzing
        guard !report.detectedObjects.isEmpty else {
            step = .error("No food detected. Try rescanning from a different angle.")
            return
        }
        do {
            // Build a food description string: "гречка 120g, котлета 95g"
            // The backend keyword-GI enrichment pipeline uses this to estimate GI/GL.
            let description = report.noteDescription
            let snap = try await BackendAPI.analyzeNutrition(
                ingredientsText: description,
                fallbackCarbs: report.detectedObjects.reduce(0) { $0 + $1.estimatedMassG * 0.15 }
            )
            step = .result(snap)
        } catch {
            // Fallback: build a minimal snapshot directly from mass data
            step = .result(fallbackSnapshot(from: report))
        }
    }

    private func fallbackSnapshot(from report: FoodVolumeReport) -> BackendAPI.NutritionSnapshot {
        // Estimate carbs as 15% of total mass (rough cross-category average)
        let totalMass = report.totalMassG
        return BackendAPI.NutritionSnapshot(
            absorptionMode: "DEFAULT_DECAY",
            source: "AR_VOLUME",
            confidence: report.segmentedPointRatio,
            totalCarbs: totalMass * 0.15,
            fiber: nil, protein: nil, fat: nil,
            estimatedGi: nil, glycemicLoad: nil,
            absorptionSpeedClass: "DEFAULT",
            normalizedFoods: report.detectedObjects.map(\.label),
            patternName: nil, bolusStrategy: nil,
            suggestedDurationHours: nil,
            mealSequencingPriority: nil,
            curveDescription: nil,
            preBolusPauseMinutes: 15
        )
    }
}

// MARK: - Nutrition Result View

struct NutritionResultView: View {
    let snapshot: BackendAPI.NutritionSnapshot
    let image: UIImage?
    /// Optional AR volume report shown as an additional card below the photo
    var arVolumeReport: FoodVolumeReport? = nil
    let onCreate: (BackendAPI.NoteInput) async -> Void
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var meal = "Lunch"
    @State private var isSaving = false
    private let meals = ["Breakfast", "Lunch", "Dinner", "Snack", "Pre-bolus", "Correction", "Other"]

    var body: some View {
        List {
            if let img = image {
                Section {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 200)
                        .frame(maxWidth: .infinity)
                        .cornerRadius(10)
                        .listRowInsets(EdgeInsets())
                }
            }

            // AR volumetric scan card (shown when AR pipeline was used)
            if let report = arVolumeReport {
                Section {
                    ARVolumeResultCard(report: report)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowBackground(Color.clear)
                }
            }

            // Pre-bolus recommendation banner
            if let pause = snapshot.preBolusPauseMinutes {
                Section {
                    preBolusBanner(pause: pause)
                }
            }

            Section("Detected foods") {
                if let foods = snapshot.normalizedFoods, !foods.isEmpty {
                    ForEach(foods, id: \.self) { food in
                        Text(food.capitalized)
                    }
                } else {
                    Text("No foods identified")
                        .foregroundColor(.secondary)
                }
            }

            Section("Nutrition") {
                nutritionRow("Carbs", value: snapshot.totalCarbs, unit: "g")
                nutritionRow("Fiber", value: snapshot.fiber, unit: "g")
                nutritionRow("Protein", value: snapshot.protein, unit: "g")
                nutritionRow("Fat", value: snapshot.fat, unit: "g")
                nutritionRow("Glycemic Index", value: snapshot.estimatedGi, unit: "")
                nutritionRow("Glycemic Load", value: snapshot.glycemicLoad, unit: "")
                if let speed = snapshot.absorptionSpeedClass {
                    HStack {
                        Text("Absorption")
                        Spacer()
                        Text(speed.capitalized)
                            .foregroundColor(.secondary)
                    }
                }
                if let strategy = snapshot.bolusStrategy {
                    HStack {
                        Text("Bolus type")
                        Spacer()
                        Text(strategy)
                            .foregroundColor(.secondary)
                    }
                }
                if let h = snapshot.suggestedDurationHours {
                    HStack {
                        Text("Absorption window")
                        Spacer()
                        Text(String(format: "%.0f h", h))
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Glucose forecast based on food type
            if let curve = snapshot.curveDescription {
                Section("Glucose curve") {
                    Text(curve)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    glucoseForecastRow()
                }
            }

            Section("Add to note as") {
                Picker("Meal type", selection: $meal) {
                    ForEach(meals, id: \.self) { Text($0) }
                }
            }

            Section {
                Button(action: addToNote) {
                    if isSaving {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Add to Note")
                            .frame(maxWidth: .infinity)
                            .bold()
                    }
                }
                .disabled(isSaving)
            }
        }
        .navigationTitle("Nutrition")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func preBolusBanner(pause: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "syringe.fill")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.purple))
            VStack(alignment: .leading, spacing: 2) {
                if pause == 0 {
                    Text("Bolus at meal start")
                        .font(.headline)
                    Text("Split or post-meal bolus — inject when you begin eating")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Inject \(pause) min before eating")
                        .font(.headline)
                    Text(preBolusPauseReason(pause: pause))
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

    @ViewBuilder
    private func glucoseForecastRow() -> some View {
        let calc = appState.calculations
        let cur = appState.currentGlucoseMmolForAPI()
        HStack(spacing: 0) {
            forecastCell(label: "Now", value: cur)
            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
            forecastCell(label: "2 h", value: calc?.twoHourPrediction)
            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
            forecastCell(label: "4 h", value: calc?.fourHourPrediction)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func forecastCell(label: String, value: Double?) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if let v = value {
                Text(String(format: "%.1f", v))
                    .font(.title3.bold())
                    .foregroundStyle(glucoseColor(v))
            } else {
                Text("—")
                    .font(.title3.bold())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func glucoseColor(_ mmol: Double) -> Color {
        if mmol < 4.0 { return .red }
        if mmol > 10.0 { return .orange }
        return .green
    }

    private func nutritionRow(_ label: String, value: Double?, unit: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            if let v = value {
                Text(unit.isEmpty ? String(format: "%.0f", v) : String(format: "%.1f %@", v, unit))
                    .foregroundColor(.secondary)
            } else {
                Text("—").foregroundColor(.secondary)
            }
        }
    }

    private func addToNote() {
        guard !isSaving else { return }
        isSaving = true
        let carbs = Int((snapshot.totalCarbs ?? 0).rounded())
        let input = BackendAPI.NoteInput(
            timestamp: BackendAPI.formatNoteTimestampForRequest(Date()),
            carbs: Double(carbs),
            insulin: 0,
            meal: meal,
            comment: buildComment(),
            glucoseValue: appState.glucoseMmolForNewNote(at: Date()),
            absorptionMode: snapshot.absorptionMode
        )
        Task {
            await onCreate(input)
            try? await Task.sleep(nanoseconds: 80_000_000)
            await MainActor.run {
                isSaving = false
                dismiss()
            }
        }
    }

    private func buildComment() -> String? {
        var parts: [String] = []
        if let foods = snapshot.normalizedFoods, !foods.isEmpty {
            parts.append(foods.joined(separator: ", "))
        }
        if let gi = snapshot.estimatedGi {
            parts.append("GI \(Int(gi))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
