import SwiftUI
import UIKit

private func resignKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

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

struct NotesView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingAddNote = false
    @State private var noteToEdit: BackendAPI.GlucoseNote?

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
                }
            }
            .navigationTitle("Notes")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    addNoteButton
                }
            }
            .sheet(isPresented: $showingAddNote) {
                AddNoteSheet { input in
                    await appState.createNote(input)
                }
                .environmentObject(appState)
            }
            .sheet(item: $noteToEdit) { note in
                EditNoteSheet(note: note) { body in
                    await appState.updateNote(id: note.id, body: body)
                }
                .environmentObject(appState)
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
            showingAddNote = true
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
    @State private var carbs = ""
    @State private var insulin = ""
    @State private var comment = ""
    @State private var absorptionMode = "medium"
    @State private var isSaving = false

    private let meals = ["Breakfast", "Lunch", "Dinner", "Snack", "Pre-bolus", "Correction", "Other"]
    private let absorptionModes = ["fast", "medium", "slow"]

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
                    amountRow(label: "Carbs (g)", placeholder: "0", text: $carbs)
                    amountRow(label: "Insulin (u)", placeholder: "0", text: $insulin)
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
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        resignKeyboard()
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
        resignKeyboard()
        Task {
            await MainActor.run { isSaving = true }
            let input = BackendAPI.NoteInput(
                timestamp: BackendAPI.formatNoteTimestampForRequest(noteDate),
                carbs: Double(carbs) ?? 0,
                insulin: Double(insulin) ?? 0,
                meal: meal,
                comment: comment.isEmpty ? nil : comment,
                glucoseValue: appState.glucoseMmolForNewNote(at: noteDate),
                absorptionMode: absorptionMode
            )
            await onCreate(input)
            // Let the text-input session tear down before dismissing the sheet (avoids RTIInputSystemClient / emoji keyboard console noise).
            try? await Task.sleep(nanoseconds: 80_000_000)
            await MainActor.run {
                resignKeyboard()
                isSaving = false
                dismiss()
            }
        }
    }

    private func amountRow(label: String, placeholder: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField(placeholder, text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
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
    @State private var carbs: String
    @State private var insulin: String
    @State private var comment: String
    @State private var absorptionMode: String
    @State private var isSaving = false

    private let meals = ["Breakfast", "Lunch", "Dinner", "Snack", "Pre-bolus", "Correction", "Other"]
    private let absorptionModes = ["fast", "medium", "slow"]

    init(note: BackendAPI.GlucoseNote, onSave: @escaping (BackendAPI.UpdateNoteBody) async -> Void) {
        self.note = note
        self.onSave = onSave
        _noteDate = State(initialValue: note.timestamp ?? Date())
        _meal = State(initialValue: note.meal.isEmpty ? "Other" : note.meal)
        _carbs = State(initialValue: note.carbs > 0 ? String(format: "%.0f", note.carbs) : "")
        _insulin = State(initialValue: note.insulin > 0 ? String(format: "%.1f", note.insulin) : "")
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
                    amountRow(label: "Carbs (g)", placeholder: "0", text: $carbs)
                    amountRow(label: "Insulin (u)", placeholder: "0", text: $insulin)
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
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        resignKeyboard()
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
        resignKeyboard()
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
                resignKeyboard()
                isSaving = false
                dismiss()
            }
        }
    }

    private func amountRow(label: String, placeholder: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField(placeholder, text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
        }
    }
}
