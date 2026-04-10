import SwiftUI

// MARK: - Notes List

struct NotesView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingAddNote = false

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
                        }
                        .onDelete { indexSet in
                            Task {
                                for i in indexSet {
                                    await appState.deleteNote(id: sortedNotes[i].id)
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
            }
            .task {
                if appState.isAuthenticated && appState.notes.isEmpty {
                    await appState.fetchNotes()
                }
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
                if let gv = note.glucoseValue {
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
    @Environment(\.dismiss) private var dismiss

    @State private var meal = "Lunch"
    @State private var carbs = ""
    @State private var insulin = ""
    @State private var glucoseValue = ""
    @State private var comment = ""
    @State private var absorptionMode = "medium"
    @State private var isSaving = false

    private let meals = ["Breakfast", "Lunch", "Dinner", "Snack", "Pre-bolus", "Correction", "Other"]
    private let absorptionModes = ["fast", "medium", "slow"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Meal") {
                    Picker("Type", selection: $meal) {
                        ForEach(meals, id: \.self) { Text($0) }
                    }
                }

                Section("Amounts") {
                    amountRow(label: "Carbs (g)", placeholder: "0", text: $carbs)
                    amountRow(label: "Insulin (u)", placeholder: "0", text: $insulin)
                    amountRow(label: "Glucose", placeholder: "optional", text: $glucoseValue)
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
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
        Task {
            await MainActor.run { isSaving = true }
            let input = BackendAPI.NoteInput(
                timestamp: ISO8601DateFormatter().string(from: Date()),
                carbs: Double(carbs) ?? 0,
                insulin: Double(insulin) ?? 0,
                meal: meal,
                comment: comment.isEmpty ? nil : comment,
                glucoseValue: Double(glucoseValue),
                absorptionMode: absorptionMode
            )
            await onCreate(input)
            await MainActor.run {
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
