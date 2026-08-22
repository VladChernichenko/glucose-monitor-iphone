import XCTest
@testable import GlucoseMonitor

/// Tests covering the Hovorka-model iOS changes:
///   1. `BackendAPI.COBSettings` - `bodyWeightKg` Codable round-trips
///   2. `BackendAPI.PredictionPathPoint` - `"HOVORKA_2COMP"` absorptionMode decoding
///   3. `BackendAPI.GlucoseCalculationsResponse` - backward compatibility with Hovorka path
///   4. `SettingsView.bodyWeightBinding` logic - optional ↔ Double bridge
final class BackendAPIHovorkaTests: XCTestCase {

    // MARK: - Helpers

    private let decoder = GlucoseMonitorAPI.jsonDecoder()

    // -- COBSettings JSON helpers ---------------------------------------------

    private func cobSettingsJSON(
        carbRatio: Double = 2.0,
        isf: Double = 2.2,
        carbHalfLife: Int = 45,
        maxCOBDuration: Int = 240,
        bodyWeightKg: Double? = nil
    ) -> Data {
        var fields = """
        {
          "carbRatio": \(carbRatio),
          "isf": \(isf),
          "carbHalfLife": \(carbHalfLife),
          "maxCOBDuration": \(maxCOBDuration)
        """
        if let w = bodyWeightKg {
            fields += ",\n  \"bodyWeightKg\": \(w)"
        }
        fields += "\n}"
        return fields.data(using: .utf8)!
    }

    // ---
    // MARK: 1 - COBSettings: bodyWeightKg Codable
    // ---

    /// Server returns bodyWeightKg - must decode to the stored value.
    func testCOBSettings_decode_withBodyWeightKg() throws {
        let data = cobSettingsJSON(bodyWeightKg: 82.5)
        let settings = try decoder.decode(BackendAPI.COBSettings.self, from: data)

        XCTAssertEqual(settings.bodyWeightKg ?? 0, 82.5, accuracy: 0.001,
            "bodyWeightKg must decode from JSON when the server returns it")
    }

    /// Legacy server response (no bodyWeightKg field) must decode without throwing.
    func testCOBSettings_decode_withoutBodyWeightKg_isNil() throws {
        let data = cobSettingsJSON() // no bodyWeightKg key
        let settings = try decoder.decode(BackendAPI.COBSettings.self, from: data)

        XCTAssertNil(settings.bodyWeightKg,
            "bodyWeightKg must be nil when the legacy server response omits the field - "
            + "ensures backward compatibility")
    }

    /// Explicit null in JSON must also decode to nil.
    func testCOBSettings_decode_bodyWeightKgNull_isNil() throws {
        let json = """
        { "carbRatio": 2.0, "isf": 2.2, "carbHalfLife": 45,
          "maxCOBDuration": 240, "bodyWeightKg": null }
        """.data(using: .utf8)!
        let settings = try decoder.decode(BackendAPI.COBSettings.self, from: json)

        XCTAssertNil(settings.bodyWeightKg,
            "bodyWeightKg null in JSON must decode to Optional.none")
    }

    /// Encoding a COBSettings with bodyWeightKg must include the field in JSON.
    func testCOBSettings_encode_withBodyWeightKg() throws {
        let settings = BackendAPI.COBSettings(
            carbRatio: 2.0, isf: 2.2, carbHalfLife: 45, maxCOBDuration: 240,
            bodyWeightKg: 75.0
        )
        let data = try JSONEncoder().encode(settings)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        let encoded = json["bodyWeightKg"] as? Double
        XCTAssertNotNil(encoded, "bodyWeightKg must be present in encoded JSON when set")
        XCTAssertEqual(encoded!, 75.0, accuracy: 0.001)
    }

    /// Encoding a COBSettings with nil bodyWeightKg must omit the field or send null.
    /// Either is acceptable - the backend treats both as "use population default".
    func testCOBSettings_encode_withoutBodyWeightKg_graceful() throws {
        let settings = BackendAPI.COBSettings(
            carbRatio: 2.0, isf: 2.2, carbHalfLife: 45, maxCOBDuration: 240,
            bodyWeightKg: nil
        )
        let data = try JSONEncoder().encode(settings)
        // Must not throw, and other fields must still be present
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual((json["carbRatio"] as? Double) ?? 0, 2.0, accuracy: 0.001,
            "carbRatio must still be present when bodyWeightKg is nil")
        XCTAssertEqual((json["isf"] as? Double) ?? 0, 2.2, accuracy: 0.001,
            "isf must still be present when bodyWeightKg is nil")
    }

    /// Full round-trip: encode then decode must preserve bodyWeightKg.
    func testCOBSettings_roundTrip_preservesBodyWeightKg() throws {
        let original = BackendAPI.COBSettings(
            carbRatio: 1.8, isf: 3.1, carbHalfLife: 50, maxCOBDuration: 300,
            bodyWeightKg: 68.0
        )
        let data    = try JSONEncoder().encode(original)
        let decoded = try decoder.decode(BackendAPI.COBSettings.self, from: data)

        XCTAssertEqual(decoded.carbRatio,     original.carbRatio,     accuracy: 0.001)
        XCTAssertEqual(decoded.isf,           original.isf,           accuracy: 0.001)
        XCTAssertEqual(decoded.carbHalfLife,  original.carbHalfLife,  accuracy: 0.001)
        XCTAssertEqual(decoded.maxCOBDuration,original.maxCOBDuration,accuracy: 0.001)
        XCTAssertEqual(decoded.bodyWeightKg ?? 0, original.bodyWeightKg ?? 0, accuracy: 0.001,
            "bodyWeightKg must survive a full encode->decode round-trip")
    }

    // ---
    // MARK: 2 - PredictionPathPoint: absorptionMode variations
    // ---

    private func predictionPointJSON(absorptionMode: String?) -> Data {
        var json = """
        {
          "timestamp": "2025-06-09T12:00:00",
          "predictedGlucose": 6.8,
          "carbAbsorptionEffect": 0.4,
          "insulinActivityEffect": -0.2
        """
        if let mode = absorptionMode {
            json += ",\n  \"absorptionMode\": \"\(mode)\""
        }
        json += "\n}"
        return json.data(using: .utf8)!
    }

    /// Hovorka path returns "HOVORKA_2COMP" - must decode without error.
    func testPredictionPathPoint_decode_hovorka2CompMode() throws {
        let data  = predictionPointJSON(absorptionMode: "HOVORKA_2COMP")
        let point = try decoder.decode(BackendAPI.PredictionPathPoint.self, from: data)

        XCTAssertEqual(point.absorptionMode, "HOVORKA_2COMP",
            "HOVORKA_2COMP must decode as the absorptionMode string value")
        XCTAssertEqual(point.predictedGlucose ?? 0, 6.8, accuracy: 0.01)
    }

    /// Legacy OpenAPS path returns "DEFAULT_DECAY" - must still decode correctly.
    func testPredictionPathPoint_decode_defaultDecayMode() throws {
        let data  = predictionPointJSON(absorptionMode: "DEFAULT_DECAY")
        let point = try decoder.decode(BackendAPI.PredictionPathPoint.self, from: data)

        XCTAssertEqual(point.absorptionMode, "DEFAULT_DECAY")
    }

    /// Enhanced nutrition mode - must still decode correctly.
    func testPredictionPathPoint_decode_giGlEnhancedMode() throws {
        let data  = predictionPointJSON(absorptionMode: "GI_GL_ENHANCED")
        let point = try decoder.decode(BackendAPI.PredictionPathPoint.self, from: data)

        XCTAssertEqual(point.absorptionMode, "GI_GL_ENHANCED")
    }

    /// Missing absorptionMode field - must decode to nil (not throw).
    func testPredictionPathPoint_decode_missingAbsorptionMode_isNil() throws {
        let data  = predictionPointJSON(absorptionMode: nil)
        let point = try decoder.decode(BackendAPI.PredictionPathPoint.self, from: data)

        XCTAssertNil(point.absorptionMode,
            "absorptionMode must be nil when the field is absent - backward compatibility")
    }

    /// Unknown future mode string - must decode to that string (open-world assumption).
    func testPredictionPathPoint_decode_unknownMode_forwardCompatible() throws {
        let data  = predictionPointJSON(absorptionMode: "FUTURE_UNKNOWN_MODE")
        let point = try decoder.decode(BackendAPI.PredictionPathPoint.self, from: data)

        XCTAssertEqual(point.absorptionMode, "FUTURE_UNKNOWN_MODE",
            "An unrecognised absorptionMode must decode to its raw string value - "
            + "forward compatibility for future model variants")
    }

    /// Digital-twin confidence band - predictedGlucoseLower/Upper must decode as the band edges.
    func testPredictionPathPoint_decode_confidenceBand() throws {
        let json = """
        {
          "timestamp": "2025-06-09T12:00:00",
          "predictedGlucose": 6.8,
          "predictedGlucoseLower": 5.9,
          "predictedGlucoseUpper": 7.7
        }
        """.data(using: .utf8)!
        let point = try decoder.decode(BackendAPI.PredictionPathPoint.self, from: json)

        XCTAssertEqual(point.predictedGlucoseLower ?? 0, 5.9, accuracy: 0.01,
            "predictedGlucoseLower must decode as the lower band edge")
        XCTAssertEqual(point.predictedGlucoseUpper ?? 0, 7.7, accuracy: 0.01,
            "predictedGlucoseUpper must decode as the upper band edge")
    }

    /// Band absent (replay / uncalibrated twin) - edges must be nil, not throw.
    func testPredictionPathPoint_decode_missingBand_isNil() throws {
        let data  = predictionPointJSON(absorptionMode: "HOVORKA_2COMP")
        let point = try decoder.decode(BackendAPI.PredictionPathPoint.self, from: data)

        XCTAssertNil(point.predictedGlucoseLower,
            "band edges must be nil when the backend emits no uncertainty band")
        XCTAssertNil(point.predictedGlucoseUpper)
    }

    // ---
    // MARK: 3 - GlucoseCalculationsResponse: Hovorka path backward compatibility
    // ---

    /// Full GlucoseCalculationsResponse with a Hovorka prediction path.
    func testGlucoseCalcResponse_decode_hovorkaPath_fullResponse() throws {
        let json = """
        {
          "backendMode": true,
          "data": {
            "activeCarbsOnBoard": 12.5,
            "activeInsulinOnBoard": 0.85,
            "twoHourPrediction": 7.2,
            "fourHourPrediction": 6.1,
            "eightHourPrediction": null,
            "predictionTrend": "falling",
            "confidence": 0.78,
            "factors": {
              "carbContribution": 1.1,
              "insulinContribution": -1.8,
              "baselineContribution": 0.0,
              "trendContribution": 0.0
            },
            "predictionPath": [
              {
                "timestamp": "2025-06-09T12:05:00",
                "predictedGlucose": 7.5,
                "carbAbsorptionEffect": 0.45,
                "insulinActivityEffect": -0.22,
                "absorptionMode": "HOVORKA_2COMP"
              },
              {
                "timestamp": "2025-06-09T12:10:00",
                "predictedGlucose": 7.3,
                "carbAbsorptionEffect": 0.40,
                "insulinActivityEffect": -0.28,
                "absorptionMode": "HOVORKA_2COMP"
              }
            ]
          }
        }
        """.data(using: .utf8)!

        let envelope = try decoder.decode(BackendAPI.GlucoseCalculationsResponse.Envelope.self, from: json)
        let resp = try XCTUnwrap(envelope.data, "data field must decode correctly")

        // Core predictions
        XCTAssertEqual(resp.activeCarbsOnBoard,   12.5,  accuracy: 0.01)
        XCTAssertEqual(resp.activeInsulinOnBoard,  0.85,  accuracy: 0.01)
        XCTAssertEqual(resp.twoHourPrediction,     7.2,   accuracy: 0.01)
        XCTAssertEqual(resp.fourHourPrediction ?? 0, 6.1, accuracy: 0.01)
        XCTAssertNil(resp.eightHourPrediction,
            "null eightHourPrediction must decode to nil")
        XCTAssertEqual(resp.predictionTrend, "falling")

        // Factors still present when Hovorka model is active
        let factors = try XCTUnwrap(resp.factors, "factors must be present alongside Hovorka path")
        XCTAssertEqual(factors.carbContribution ?? 0,     1.1,  accuracy: 0.01)
        XCTAssertEqual(factors.insulinContribution ?? 0, -1.8,  accuracy: 0.01)

        // Prediction path with HOVORKA_2COMP mode
        let path = try XCTUnwrap(resp.predictionPath)
        XCTAssertEqual(path.count, 2)
        XCTAssertEqual(path[0].absorptionMode, "HOVORKA_2COMP")
        XCTAssertEqual(path[0].predictedGlucose ?? 0, 7.5, accuracy: 0.01)
        XCTAssertEqual(path[1].absorptionMode, "HOVORKA_2COMP")
    }

    /// Response without predictionPath (minimal/legacy response) must still decode.
    func testGlucoseCalcResponse_decode_noPredictionPath_graceful() throws {
        let json = """
        {
          "backendMode": true,
          "data": {
            "activeCarbsOnBoard": 0,
            "activeInsulinOnBoard": 0,
            "twoHourPrediction": 5.5,
            "predictionTrend": "stable",
            "confidence": 0.9
          }
        }
        """.data(using: .utf8)!

        let envelope = try decoder.decode(BackendAPI.GlucoseCalculationsResponse.Envelope.self, from: json)
        let resp = try XCTUnwrap(envelope.data)

        XCTAssertNil(resp.predictionPath,
            "Missing predictionPath must decode to nil - not throw")
        XCTAssertNil(resp.factors,
            "Missing factors must decode to nil - not throw")
        XCTAssertNil(resp.fourHourPrediction,
            "Missing fourHourPrediction must decode to nil")
        XCTAssertNil(resp.eightHourPrediction)
    }

    /// Mixed path: some points Hovorka, some OpenAPS (future partial migration scenario).
    func testGlucoseCalcResponse_decode_mixedAbsorptionModes() throws {
        let json = """
        {
          "backendMode": true,
          "data": {
            "activeCarbsOnBoard": 5.0,
            "activeInsulinOnBoard": 0.0,
            "twoHourPrediction": 6.0,
            "predictionTrend": "stable",
            "confidence": 0.8,
            "predictionPath": [
              { "timestamp": "2025-06-09T12:05:00", "predictedGlucose": 6.1,
                "absorptionMode": "HOVORKA_2COMP" },
              { "timestamp": "2025-06-09T12:10:00", "predictedGlucose": 6.2 },
              { "timestamp": "2025-06-09T12:15:00", "predictedGlucose": 6.0,
                "absorptionMode": "DEFAULT_DECAY" }
            ]
          }
        }
        """.data(using: .utf8)!

        let envelope = try decoder.decode(BackendAPI.GlucoseCalculationsResponse.Envelope.self, from: json)
        let path = try XCTUnwrap(envelope.data?.predictionPath)

        XCTAssertEqual(path.count, 3)
        XCTAssertEqual(path[0].absorptionMode, "HOVORKA_2COMP")
        XCTAssertNil(path[1].absorptionMode, "Missing absorptionMode must be nil")
        XCTAssertEqual(path[2].absorptionMode, "DEFAULT_DECAY")
    }

    // ---
    // MARK: 4 - bodyWeightBinding logic (SettingsView)
    // ---
    // The binding itself is a SwiftUI computed property on SettingsView; we test
    // the underlying get/set logic as pure functions mirroring the implementation.

    // Mirrors SettingsView.bodyWeightBinding.get
    private func bodyWeightGet(from settings: BackendAPI.COBSettings) -> Double {
        settings.bodyWeightKg ?? 70.0
    }

    // Mirrors SettingsView.bodyWeightBinding.set
    private func bodyWeightSet(_ value: Double,
                                into settings: inout BackendAPI.COBSettings) {
        settings.bodyWeightKg = value > 0 ? value : nil
    }

    /// Nil bodyWeightKg -> binding returns population default 70 kg.
    func testBodyWeightBinding_get_nilReturnsDefault70() {
        let settings = BackendAPI.COBSettings(
            carbRatio: 2.0, isf: 2.2, carbHalfLife: 45, maxCOBDuration: 240,
            bodyWeightKg: nil
        )
        XCTAssertEqual(bodyWeightGet(from: settings), 70.0, accuracy: 0.001,
            "nil bodyWeightKg must return 70.0 (population default) via the binding getter")
    }

    /// Set bodyWeightKg -> binding returns the stored value.
    func testBodyWeightBinding_get_returnsStoredValue() {
        let settings = BackendAPI.COBSettings(
            carbRatio: 2.0, isf: 2.2, carbHalfLife: 45, maxCOBDuration: 240,
            bodyWeightKg: 88.0
        )
        XCTAssertEqual(bodyWeightGet(from: settings), 88.0, accuracy: 0.001,
            "A stored bodyWeightKg must be returned as-is by the binding getter")
    }

    /// Setting a positive value stores it in bodyWeightKg.
    func testBodyWeightBinding_set_positiveValueStored() {
        var settings = BackendAPI.COBSettings(
            carbRatio: 2.0, isf: 2.2, carbHalfLife: 45, maxCOBDuration: 240,
            bodyWeightKg: nil
        )
        bodyWeightSet(65.0, into: &settings)

        XCTAssertEqual(settings.bodyWeightKg ?? 0, 65.0, accuracy: 0.001,
            "Setting a positive weight must store it in bodyWeightKg")
    }

    /// Setting 0 clears bodyWeightKg to nil (use population default).
    func testBodyWeightBinding_set_zeroClears() {
        var settings = BackendAPI.COBSettings(
            carbRatio: 2.0, isf: 2.2, carbHalfLife: 45, maxCOBDuration: 240,
            bodyWeightKg: 75.0
        )
        bodyWeightSet(0, into: &settings)

        XCTAssertNil(settings.bodyWeightKg,
            "Setting weight = 0 must clear bodyWeightKg to nil (use server-side population default)")
    }

    /// Setting a negative value also clears bodyWeightKg to nil.
    func testBodyWeightBinding_set_negativeClears() {
        var settings = BackendAPI.COBSettings(
            carbRatio: 2.0, isf: 2.2, carbHalfLife: 45, maxCOBDuration: 240,
            bodyWeightKg: 75.0
        )
        bodyWeightSet(-10.0, into: &settings)

        XCTAssertNil(settings.bodyWeightKg,
            "Setting a negative weight must clear bodyWeightKg to nil - "
            + "guards against invalid user input reaching the backend")
    }

    /// Updating weight value replaces the previous one.
    func testBodyWeightBinding_set_updatesExistingValue() {
        var settings = BackendAPI.COBSettings(
            carbRatio: 2.0, isf: 2.2, carbHalfLife: 45, maxCOBDuration: 240,
            bodyWeightKg: 70.0
        )
        bodyWeightSet(80.5, into: &settings)

        XCTAssertEqual(settings.bodyWeightKg ?? 0, 80.5, accuracy: 0.001,
            "Setting a new positive value must overwrite the previous bodyWeightKg")
    }

    // ---
    // MARK: 5 - COBSettings default initializer still works (API stability)
    // ---

    /// The default 5-arg initializer (without bodyWeightKg) still compiles
    /// and produces bodyWeightKg = nil.
    func testCOBSettings_legacyInit_noBodyWeight() {
        // This is the initialiser used in SettingsView's @State default.
        let settings = BackendAPI.COBSettings(
            carbRatio: 2.0, isf: 2.5, carbHalfLife: 60, maxCOBDuration: 240
        )
        XCTAssertNil(settings.bodyWeightKg,
            "The 4-field memberwise init must leave bodyWeightKg nil - "
            + "backward compatibility for all existing call sites")
    }

    /// The 5-arg initializer with explicit nil also compiles.
    func testCOBSettings_init_explicitNilBodyWeight() {
        let settings = BackendAPI.COBSettings(
            carbRatio: 2.0, isf: 2.5, carbHalfLife: 60, maxCOBDuration: 240,
            bodyWeightKg: nil
        )
        XCTAssertNil(settings.bodyWeightKg)
    }
}
