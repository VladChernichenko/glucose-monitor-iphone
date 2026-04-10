import Foundation
import SwiftUI

/// Shared observable state for the entire iOS app.
/// Mirrors the role of AuthContext + EnhancedDashboard state in the web frontend.
@MainActor
final class AppState: ObservableObject {

    @Published var isAuthenticated = false
    @Published var isLoading = false
    @Published var currentReading: GlucoseMonitorAPI.LibreGlucoseCurrent?
    @Published var calculations: BackendAPI.GlucoseCalculationsResponse?
    @Published var notes: [BackendAPI.GlucoseNote] = []
    @Published var errorMessage: String?

    // MARK: - Auth

    func checkAuthentication() {
        let token = GlucoseMonitorAPI.sharedDefaults().string(forKey: GlucoseMonitorAPI.StorageKey.accessToken)
        isAuthenticated = !(token?.isEmpty ?? true)
    }

    func logout() async {
        await GlucoseMonitorAPI.logout()
        isAuthenticated = false
        currentReading = nil
        calculations = nil
        notes = []
        errorMessage = nil
    }

    // MARK: - Glucose

    /// Fetches the current glucose reading from the configured data source
    /// (LibreLinkUp or Nightscout), then loads COB/IOB calculations.
    func refreshAll() async {
        guard isAuthenticated else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let source = GlucoseMonitorAPI.sharedDefaults().string(forKey: GlucoseMonitorAPI.StorageKey.dataSource) ?? "libre"

        do {
            if source == "nightscout" {
                let entries = try await BackendAPI.fetchNightscoutEntries(count: 1)
                currentReading = entries.first?.toLibreGlucoseCurrent()
            } else {
                currentReading = try await GlucoseMonitorAPI.fetchCurrentGlucose()
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        // Glucose calculations run independently — failure is non-fatal
        if let glucose = currentReading?.value {
            calculations = try? await BackendAPI.fetchGlucoseCalculations(currentGlucose: glucose)
        }
    }

    // MARK: - Notes

    func fetchNotes() async {
        notes = (try? await BackendAPI.fetchNotes()) ?? []
    }

    func createNote(_ input: BackendAPI.NoteInput) async {
        if let note = try? await BackendAPI.createNote(input) {
            notes.append(note)
        }
    }

    func deleteNote(id: String) async {
        try? await BackendAPI.deleteNote(id: id)
        notes.removeAll { $0.id == id }
    }
}