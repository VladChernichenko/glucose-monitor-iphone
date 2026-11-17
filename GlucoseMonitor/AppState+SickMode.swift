import Foundation

/// Sick mode commands. `sickMode` itself follows the newest dashboard calculations (see `calculations`'
/// didSet); a command stores its own result immediately, then the dashboard is refreshed. A failed
/// command leaves `sickMode` untouched and reports the error.
extension AppState {

    @discardableResult
    func startSickMode(_ severity: SickSeverity, since: SickSince) async -> SickModeStatus? {
        return await runSickCommand { try await BackendAPI.startSickMode(severity, since: since) }
    }

    @discardableResult
    func changeSickSeverity(_ severity: SickSeverity) async -> SickModeStatus? {
        return await runSickCommand { try await BackendAPI.changeSickSeverity(severity) }
    }

    @discardableResult
    func confirmStillSick() async -> SickModeStatus? {
        return await runSickCommand { try await BackendAPI.confirmStillSick() }
    }

    @discardableResult
    func endSickMode(reason: String) async -> SickModeStatus? {
        return await runSickCommand { try await BackendAPI.endSickMode(reason: reason) }
    }

    /// Answers the pending step-up proposal; does nothing when there is none.
    @discardableResult
    func decideSickStepUp(accept: Bool) async -> SickModeStatus? {
        guard let noteId = sickMode?.stepUp?.noteId else { return nil }
        return await runSickCommand { try await BackendAPI.decideSickStepUp(noteId: noteId, accept: accept) }
    }

    /// Returns the server's status on success, nil on any failure (including a sign-out mid-command).
    private func runSickCommand(_ command: () async throws -> SickModeStatus) async -> SickModeStatus? {
        let generation = authGeneration
        var result: SickModeStatus?
        do {
            let status = try await command()
            guard generation == authGeneration else { return nil }
            sickMode = status
            result = status
        } catch {
            errorMessage = "Couldn't update sick mode. Try again."
            return nil
        }
        await refreshGlucoseOnly(silent: true, forceServerSync: false)
        return result
    }
}
