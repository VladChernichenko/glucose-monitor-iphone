import Foundation

/// Sick mode commands. `sickMode` itself follows the newest dashboard calculations (see `calculations`'
/// didSet); a command stores its own result immediately, then the dashboard is refreshed. A failed
/// command leaves `sickMode` untouched and reports the error.
extension AppState {

    func startSickMode(_ severity: SickSeverity, since: SickSince) async {
        await runSickCommand { try await BackendAPI.startSickMode(severity, since: since) }
    }

    func changeSickSeverity(_ severity: SickSeverity) async {
        await runSickCommand { try await BackendAPI.changeSickSeverity(severity) }
    }

    func confirmStillSick() async {
        await runSickCommand { try await BackendAPI.confirmStillSick() }
    }

    func endSickMode(reason: String) async {
        await runSickCommand { try await BackendAPI.endSickMode(reason: reason) }
    }

    /// Answers the pending step-up proposal; does nothing when there is none.
    func decideSickStepUp(accept: Bool) async {
        guard let noteId = sickMode?.stepUp?.noteId else { return }
        await runSickCommand { try await BackendAPI.decideSickStepUp(noteId: noteId, accept: accept) }
    }

    private func runSickCommand(_ command: () async throws -> SickModeStatus) async {
        let generation = authGeneration
        do {
            let status = try await command()
            guard generation == authGeneration else { return }
            sickMode = status
        } catch {
            errorMessage = "Couldn't update sick mode. Try again."
            return
        }
        await refreshGlucoseOnly(silent: true, forceServerSync: false)
    }
}
