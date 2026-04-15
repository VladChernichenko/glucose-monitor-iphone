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

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let n): return n.id
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
                    addNoteButton
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
    @State private var absorptionMode = "medium"
    @State private var isSaving = false

    private let meals = ["Breakfast", "Lunch", "Dinner", "Snack", "Pre-bolus", "Correction", "Other"]
    private let absorptionModes = ["fast", "medium", "slow"]
    private let carbOptions   = Array(stride(from: 0, through: 200, by: 10))
    private let insulinOptions = Array(stride(from: 0, through: 30,  by: 1))

    var body: some View {
        NavigationStack {
            Form {
                Section("Time") {
                    DatePicker("Date & time", selection: $noteDate, displayedComponents: [.date, .hourAndMinute])
                }

                Section("Meal") {
                    Picker("Type", selection: $meal) {
                        ForEach(meals, id: \.self) { Text($0) }
                    }
                }

                Section("Amounts") {
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

                    formReadonlyRow(
                        label: "Glucose at time",
                        valueText: appState.formattedGlucoseAtNoteTime(noteDate, storedOnNote: nil)
                    )
                }

                Section("Absorption") {
                    Picker("Mode", selection: $absorptionMode) {
                        ForEach(absorptionModes, id: \.self) { Text($0.capitalized) }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Comment") {
                    TextField("Optional note", text: $comment, axis: .vertical)
                        .lineLimit(3...)
                }
            }
            .navigationTitle("Add Note")
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
            let input = BackendAPI.NoteInput(
                timestamp: BackendAPI.formatNoteTimestampForRequest(noteDate),
                carbs: Double(carbs),
                insulin: Double(insulin),
                meal: meal,
                comment: comment.isEmpty ? nil : comment,
                glucoseValue: appState.glucoseMmolForNewNote(at: noteDate),
                absorptionMode: absorptionMode
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
    @State private var absorptionMode: String
    @State private var isSaving = false

    private let meals = ["Breakfast", "Lunch", "Dinner", "Snack", "Pre-bolus", "Correction", "Other"]
    private let absorptionModes = ["fast", "medium", "slow"]
    private let carbOptions    = Array(stride(from: 0, through: 200, by: 10))
    private let insulinOptions = Array(stride(from: 0, through: 30,  by: 1))

    init(note: BackendAPI.GlucoseNote, onSave: @escaping (BackendAPI.UpdateNoteBody) async -> Void) {
        self.note = note
        self.onSave = onSave
        _noteDate = State(initialValue: note.timestamp ?? Date())
        _meal = State(initialValue: note.meal.isEmpty ? "Other" : note.meal)
        // Round to nearest picker step; clamp to range.
        let roundedCarbs = min(200, max(0, Int((note.carbs / 10).rounded()) * 10))
        let roundedInsulin = min(30, max(0, Int(note.insulin.rounded())))
        _carbs = State(initialValue: roundedCarbs)
        _insulin = State(initialValue: roundedInsulin)
        _comment = State(initialValue: note.comment ?? "")
        _absorptionMode = State(initialValue: note.absorptionMode ?? "medium")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Time") {
                    DatePicker("Date & time", selection: $noteDate, displayedComponents: [.date, .hourAndMinute])
                }
                Section("Meal") {
                    Picker("Type", selection: $meal) {
                        ForEach(meals, id: \.self) { Text($0) }
                    }
                }
                Section("Amounts") {
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

                    formReadonlyRow(
                        label: "Glucose at time",
                        valueText: appState.formattedGlucoseAtNoteTime(noteDate, storedOnNote: note.glucoseValue)
                    )
                }
                Section("Absorption") {
                    Picker("Mode", selection: $absorptionMode) {
                        ForEach(absorptionModes, id: \.self) { Text($0.capitalized) }
                    }
                    .pickerStyle(.segmented)
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
            let body = BackendAPI.UpdateNoteBody(
                timestamp: ts,
                carbs: Double(carbs),
                insulin: Double(insulin),
                meal: meal,
                comment: comment.isEmpty ? nil : comment,
                glucoseValue: nil,
                absorptionMode: absorptionMode
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
