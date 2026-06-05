import Foundation
import SwiftUI

@MainActor
final class ExperimentViewModel: ObservableObject {

    // MARK: - Published state

    @Published var availableExperiments: [AvailableExperiment] = []
    @Published var history: [ExperimentModel] = []
    @Published var activeExperiment: ExperimentModel?
    @Published var backgroundStatus: BackgroundStatus?
    @Published var lastResult: ExperimentResult?

    @Published var isLoadingAvailable = false
    @Published var isLoadingBackground = false
    @Published var isRecordingReading  = false
    @Published var isCompleting        = false
    @Published var error: String?

    // MARK: - Load available

    func loadAvailable() async {
        isLoadingAvailable = true
        error = nil
        defer { isLoadingAvailable = false }
        do {
            availableExperiments = try await ExperimentService.getAvailable()
            history = try await ExperimentService.getHistory()
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Background check

    func checkBackground() async {
        isLoadingBackground = true
        defer { isLoadingBackground = false }
        do {
            backgroundStatus = try await ExperimentService.checkBackground()
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Start

    func startExperiment(type: ExperimentType,
                         gramsConsumed: Double? = nil,
                         unitsInjected: Double? = nil) async throws {
        let req = StartExperimentRequest(type: type, gramsConsumed: gramsConsumed, unitsInjected: unitsInjected)
        activeExperiment = try await ExperimentService.start(req)
        if let id = activeExperiment?.id {
            await ExperimentAlarmManager.shared.scheduleAlarms(for: type, experimentId: id)
        }
    }

    // MARK: - Record reading

    func recordReading(glucoseMmol: Double, minutesElapsed: Int, label: String? = nil) async {
        guard let expId = activeExperiment?.id else { return }
        isRecordingReading = true
        defer { isRecordingReading = false }
        do {
            let req = RecordReadingRequest(glucoseMmol: glucoseMmol, minutesElapsed: minutesElapsed, label: label)
            activeExperiment = try await ExperimentService.recordReading(experimentId: expId, reading: req)
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Complete

    func completeExperiment() async {
        guard let expId = activeExperiment?.id else { return }
        isCompleting = true
        defer { isCompleting = false }
        do {
            lastResult = try await ExperimentService.complete(experimentId: expId)
            activeExperiment = lastResult?.experiment
            if let id = activeExperiment?.id {
                await ExperimentAlarmManager.shared.cancelAlarms(for: id)
            }
            await loadAvailable()   // refresh list + history
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Abandon

    func abandonExperiment() async {
        guard let expId = activeExperiment?.id else { return }
        do {
            if let type = activeExperiment?.type {
                await ExperimentAlarmManager.shared.cancelAlarms(for: expId)
                _ = type   // silence unused warning
            }
            activeExperiment = try await ExperimentService.abandon(experimentId: expId)
            activeExperiment = nil
            await loadAvailable()
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Elapsed time helper

    func elapsedMinutes() -> Int {
        guard let startedAt = activeExperiment?.startedAt,
              let date = ISO8601DateFormatter().date(from: startedAt) else { return 0 }
        return Int(Date().timeIntervalSince(date) / 60)
    }

    // MARK: - Convenience

    var hasActiveExperiment: Bool { activeExperiment?.status == .inProgress }

    var nextAlarmLabel: String? {
        guard let type = activeExperiment?.type else { return nil }
        let elapsed = elapsedMinutes()
        return type.alarmSchedule.first(where: { $0.minutes > elapsed })?.message
    }
}
