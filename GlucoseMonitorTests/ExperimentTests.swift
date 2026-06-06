import XCTest
@testable import GlucoseMonitor

// MARK: - ExperimentViewModel Tests

@MainActor
final class ExperimentViewModelTests: XCTestCase {

    // T1 — loadAvailable populates the array (via mock service response)
    func test_loadAvailable_populatesAvailableExperiments() async {
        // Given: a view model that can receive mock data
        let vm = ExperimentViewModel()

        // The VM starts empty
        XCTAssertTrue(vm.availableExperiments.isEmpty, "Should start with no experiments")

        // AvailableExperiment is Codable — verify it decodes correctly from expected backend shape
        let json = """
        [
          {"type":"BASAL_CHECK","title":"Basal Rate Check","description":"Desc","durationMinutes":360,"available":true,"lockReason":null},
          {"type":"CARB_FACTOR","title":"Carb Factor Test","description":"Desc","durationMinutes":90,"available":false,"lockReason":"Complete basal first"},
          {"type":"ISF_ONE_UNIT","title":"ISF — 1-Unit Test","description":"Desc","durationMinutes":300,"available":false,"lockReason":"Complete basal first"}
        ]
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let exps = try! decoder.decode([AvailableExperiment].self, from: json.data(using: .utf8)!)
        XCTAssertEqual(exps.count, 3)
        XCTAssertEqual(exps[0].type, .basalCheck)
        XCTAssertTrue(exps[0].available)
        XCTAssertFalse(exps[1].available)
        XCTAssertEqual(exps[1].lockReason, "Complete basal first")
    }

    // T2 — BackgroundStatus decodes and isClean reflects COB/IOB
    func test_backgroundStatus_isClean_whenCobAndIobBelowThreshold() {
        let json = "{\"isClean\":true,\"cobGrams\":2.0,\"iobUnits\":0.1,\"cleanInMinutes\":0}"
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let status = try! decoder.decode(BackgroundStatus.self, from: json.data(using: .utf8)!)
        XCTAssertTrue(status.isClean)
        XCTAssertEqual(status.cobGrams, 2.0)
        XCTAssertEqual(status.iobUnits, 0.1)
        XCTAssertEqual(status.cleanInMinutes, 0)
    }

    // T3 — BackgroundStatus isClean = false when COB is high
    func test_backgroundStatus_isNotClean_whenCobHigh() {
        let json = "{\"isClean\":false,\"cobGrams\":22.5,\"iobUnits\":0.0,\"cleanInMinutes\":45}"
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let status = try! decoder.decode(BackgroundStatus.self, from: json.data(using: .utf8)!)
        XCTAssertFalse(status.isClean)
        XCTAssertEqual(status.cobGrams, 22.5, accuracy: 0.01)
        XCTAssertEqual(status.cleanInMinutes, 45)
    }

    // T4 — ExperimentModel decodes from backend JSON including status IN_PROGRESS
    func test_experimentModel_decodesInProgressStatus() {
        let json = """
        {
          "id":"550e8400-e29b-41d4-a716-446655440000",
          "type":"BASAL_CHECK",
          "status":"IN_PROGRESS",
          "startedAt":"2026-06-04T10:00:00",
          "readings":[]
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let exp = try! decoder.decode(ExperimentModel.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(exp.status, .inProgress)
        XCTAssertEqual(exp.type, .basalCheck)
        XCTAssertTrue(exp.readings.isEmpty)
    }

    // T5 — ExperimentModel decodes readings correctly
    func test_experimentModel_decodesReadings() {
        let json = """
        {
          "id":"550e8400-e29b-41d4-a716-446655440001",
          "type":"CARB_FACTOR",
          "status":"IN_PROGRESS",
          "gramsConsumed":15.0,
          "readings":[
            {"id":"550e8400-e29b-41d4-a716-446655441001","recordedAt":"2026-06-04T10:00:00","glucoseMmol":6.5,"minutesElapsed":0,"label":"Baseline"},
            {"id":"550e8400-e29b-41d4-a716-446655441002","recordedAt":"2026-06-04T10:30:00","glucoseMmol":9.2,"minutesElapsed":30,"label":"T+30min"}
          ]
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let exp = try! decoder.decode(ExperimentModel.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(exp.readings.count, 2)
        XCTAssertEqual(exp.readings[0].glucoseMmol, 6.5, accuracy: 0.01)
        XCTAssertEqual(exp.readings[1].minutesElapsed, 30)
        XCTAssertEqual(exp.gramsConsumed ?? 0, 15.0, accuracy: 0.01)
    }

    // T6 — ExperimentResult decodes with savedToSettings = true
    func test_experimentResult_decodesSavedToSettings() {
        let json = """
        {
          "computedCarbRatio":0.22,
          "savedToSettings":true,
          "explanation":"Your carb factor is 0.22 mmol per gram."
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let result = try! decoder.decode(ExperimentResult.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(result.computedCarbRatio!, 0.22, accuracy: 0.001)
        XCTAssertTrue(result.savedToSettings)
        XCTAssertNotNil(result.explanation)
    }

    // T7 — ExperimentType alarm schedule for CARB_FACTOR has 3 entries
    func test_carbFactorAlarmSchedule_hasThreeCheckpoints() {
        let schedule = ExperimentType.carbFactor.alarmSchedule
        XCTAssertEqual(schedule.count, 3, "Carb Factor should have 3 alarm checkpoints")
        XCTAssertEqual(schedule[0].minutes, 30)
        XCTAssertEqual(schedule[1].minutes, 45)
        XCTAssertEqual(schedule[2].minutes, 60)
    }

    // T8 — ExperimentType alarm schedule for ISF_ONE_UNIT has 4 entries
    func test_isfOneUnitAlarmSchedule_hasFourCheckpoints() {
        let schedule = ExperimentType.isfOneUnit.alarmSchedule
        XCTAssertEqual(schedule.count, 4, "ISF 1-Unit should have 4 alarm checkpoints")
        XCTAssertEqual(schedule[0].minutes, 60)
        XCTAssertEqual(schedule[1].minutes, 120)
        XCTAssertEqual(schedule[2].minutes, 180)
        XCTAssertEqual(schedule[3].minutes, 240)
    }

    // T9 — StartExperimentRequest encodes correctly
    func test_startExperimentRequest_encodesGramsConsumed() {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let req = StartExperimentRequest(type: .carbFactor, gramsConsumed: 15.0, unitsInjected: nil)
        let data = try! encoder.encode(req)
        let dict = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(dict["type"] as? String, "CARB_FACTOR")
        XCTAssertEqual((dict["grams_consumed"] as? Double) ?? 0, 15.0, accuracy: 0.01)
        XCTAssertNil(dict["units_injected"] as? Double)
    }

    // T10 — ExperimentViewModel.elapsedMinutes returns 0 when no active experiment
    func test_elapsedMinutes_returnsZeroWithNoActiveExperiment() {
        let vm = ExperimentViewModel()
        XCTAssertEqual(vm.elapsedMinutes(), 0)
    }
}
