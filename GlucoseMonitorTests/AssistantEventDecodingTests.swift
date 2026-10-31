import XCTest
@testable import GlucoseMonitor

/// Pins the NDJSON event shapes of `POST /api/assistant/messages` and the history rows of
/// `GET /api/assistant/messages`. Events the backend does not send yet (plan, episodes, banner,
/// citations) must decode; unknown types and junk lines are ignored instead of crashing.
final class AssistantEventDecodingTests: XCTestCase {

    func testDecodesLoggedWithForecastMin() throws {
        let line = #"{"type":"logged","noteIds":["n1"],"summary":"Logged 5 U + 50 g. IOB 5.3 U, lowest 5.8 in the next 4 h.","iob":5.3,"forecastMin":5.8}"#
        guard case .logged(let logged)? = BackendAPI.decodeAssistantEvent(line: line) else {
            return XCTFail("expected logged")
        }
        XCTAssertEqual(logged.noteIds, ["n1"])
        XCTAssertEqual(logged.summary, "Logged 5 U + 50 g. IOB 5.3 U, lowest 5.8 in the next 4 h.")
        XCTAssertEqual(logged.iob, 5.3)
        XCTAssertEqual(logged.forecastMin, 5.8)
    }

    func testDecodesLoggedWithNullForecastMin() throws {
        let line = #"{"type":"logged","noteIds":["n1"],"summary":"Записано 5 ЕД. IOB 5 ЕД.","iob":5.0,"forecastMin":null}"#
        guard case .logged(let logged)? = BackendAPI.decodeAssistantEvent(line: line) else {
            return XCTFail("expected logged")
        }
        XCTAssertNil(logged.forecastMin)
        XCTAssertEqual(logged.iob, 5.0)
    }

    func testDecodesToken() {
        XCTAssertEqual(BackendAPI.decodeAssistantEvent(line: #"{"type":"token","text":"Your glucose rose because"}"#),
                       .token("Your glucose rose because"))
    }

    func testDecodesDone() {
        let line = #"{"type":"done","userMessageId":"u1","assistantMessageId":"a1","intent":"quick_log"}"#
        XCTAssertEqual(BackendAPI.decodeAssistantEvent(line: line),
                       .done(BackendAPI.AssistantDone(userMessageId: "u1", assistantMessageId: "a1", intent: "quick_log")))
    }

    func testDecodesError() {
        XCTAssertEqual(BackendAPI.decodeAssistantEvent(line: #"{"type":"error","message":"Assistant reply failed"}"#),
                       .error("Assistant reply failed"))
    }

    func testPlanWithNullPeakAndMinStillDecodes() {
        // The backend sends peak/min as null for an empty forecast curve (never "NaN").
        let line = #"{"type":"plan","messageId":"a1","plan":{"carbs":{"low":40,"mid":45,"high":50},"#
            + #""fat":{"low":0,"mid":0,"high":0},"protein":{"low":0,"mid":0,"high":0},"fiber":{"low":0,"mid":0,"high":0},"#
            + #""doseUnits":4.5,"refusalCode":null,"stale":false,"#
            + #""pause":{"pauseMinutes":null,"curve":[],"peak":null,"min":null,"reason":"Every pause...","inFlight":false}}}"#
        guard case .plan(let id, let plan, _, _)? = BackendAPI.decodeAssistantEvent(line: line) else {
            return XCTFail("plan with null peak/min was dropped")
        }
        XCTAssertEqual(id, "a1")
        XCTAssertEqual(plan.doseUnits, 4.5)
        XCTAssertNil(plan.pause?.peak)
        XCTAssertNil(plan.pause?.min)
        XCTAssertEqual(plan.pause?.curve.count, 0)
    }

    func testPlanSupersededByLoggedInsulinSaysSo() throws {
        let json = #"{"state":"SUPERSEDED","supersededByNoteId":"n7","supersededAt":"2026-10-31T12:05:00"}"#
        let p = try GlucoseMonitorAPI.jsonDecoder().decode(BackendAPI.MealPlanPayload.self, from: Data(json.utf8))
        XCTAssertEqual(p.phase, .superseded)
        XCTAssertEqual(p.supersededByNoteId, "n7")
        XCTAssertEqual(MealPlanRules.replacedTitle(p), "Insulin logged after this plan: make a new plan")
        let newer = try GlucoseMonitorAPI.jsonDecoder().decode(BackendAPI.MealPlanPayload.self,
                                                              from: Data(#"{"state":"SUPERSEDED","supersededBy":"a2"}"#.utf8))
        XCTAssertEqual(MealPlanRules.replacedTitle(newer), "Replaced by a newer plan")
    }

    func testDecodesNotYetEmittedEventsWithoutCrashing() {
        // A plan that does not match the MealPlan contract is dropped, not a crash (MealPlanCardTests covers the real shape).
        XCTAssertNil(BackendAPI.decodeAssistantEvent(line: #"{"type":"plan","plan":{"dose":4,"nested":{"a":[1,2]}}}"#))
        XCTAssertNil(BackendAPI.decodeAssistantEvent(line: #"{"type":"banner","level":"warning","text":"Falling fast"}"#))
    }

    private func citations(_ line: String) -> [BackendAPI.AssistantCitation]? {
        guard case .citations(let list)? = BackendAPI.decodeAssistantEvent(line: line) else { return nil }
        return list
    }

    func testDecodesCitationsEvent() {
        let list = citations(#"{"type":"citations","citations":[{"ref":1,"id":"x","title":"Glycemic Goals","source":"ADA","year":2024,"url":"https://doi.org/10.2337/dc25-S006","citation":"ADA. Diabetes Care 2025"},{"ref":2,"title":"Bell et al.","url":"http://example.org/p"}]}"#)
        XCTAssertEqual(list?.map(\.ref), [1, 2])
        XCTAssertEqual(list?[0].url.absoluteString, "https://doi.org/10.2337/dc25-S006")
        XCTAssertEqual(list?[0].chipLabel, "[1] Glycemic Goals · ADA 2024")
        XCTAssertEqual(list?[1].chipLabel, "[2] Bell et al.")
    }

    func testMalformedAndNonHttpCitationsAreDropped() {
        let line = #"{"type":"citations","citations":[{"ref":1,"title":"Good","url":"https://a.org"},{"title":"no ref","url":"https://a.org"},{"ref":3,"title":"js","url":"javascript:alert(1)"},{"ref":4,"title":"file","url":"file:///etc/passwd"},{"ref":5,"title":"no url"},{"ref":6,"title":"  ","url":"https://a.org"},"junk",{"ref":7,"title":"Fine","url":"https://b.org"}]}"#
        XCTAssertEqual(citations(line)?.map(\.ref), [1, 7])
        XCTAssertEqual(citations(#"{"type":"citations","citations":"nope"}"#), [])
    }

    func testHistoryPayloadCarriesCitationsLossily() throws {
        let json = #"""
        [{"id":"a1","createdAt":"2026-10-30T11:00:00Z","role":"ASSISTANT","text":"Answer [1].","intent":"question","hasPhoto":false,"noteIds":[],"payload":{"citations":[{"ref":1,"title":"T","source":"ADA","year":2024,"url":"https://a.org"},{"ref":2,"title":"bad","url":"ftp://a.org"}]}}]
        """#
        let rows = try GlucoseMonitorAPI.jsonDecoder().decode([BackendAPI.ChatMessageDTO].self, from: Data(json.utf8))
        XCTAssertEqual(rows[0].payload?.citations?.map(\.ref), [1])
    }

    private func episodes(_ line: String) -> [BackendAPI.AssistantEpisode]? {
        guard case .episodes(let list)? = BackendAPI.decodeAssistantEvent(line: line) else { return nil }
        return list
    }

    func testDecodesFullEpisodesEvent() throws {
        let line = #"{"type":"episodes","episodes":[{"id":"6f1c","kind":"MEAL","at":"2026-10-12T13:00","text":"lunch, pork chop, rice 150 g","carbs":55.0,"fat":22.0,"protein":30.0,"doseUnits":5.0,"pauseMinutes":15,"startGlucose":6.4,"peak":11.2,"peakMinute":95,"nadir":5.8,"nadirMinute":230,"g60":9.1,"g120":10.8,"g240":6.0,"minutesBelow39":0,"minutesAbove10":70,"activityMinutes":0,"contaminated":true,"score":0.83},{"id":"c1","kind":"LOW","at":"2026-10-22T03:15","text":"hypo confirmed","startGlucose":3.5,"carbs":15.0,"nadir":3.2,"nadirMinute":20}]}"#
        let list = try XCTUnwrap(episodes(line))
        XCTAssertEqual(list.map(\.kind), [.MEAL, .LOW])
        let meal = list[0]
        XCTAssertEqual(meal.id, "6f1c")
        XCTAssertEqual(meal.at, "2026-10-12T13:00")
        XCTAssertEqual(meal.doseUnits, 5.0)
        XCTAssertEqual(meal.pauseMinutes, 15)
        XCTAssertEqual(meal.peak, 11.2)
        XCTAssertEqual(meal.peakMinute, 95)
        XCTAssertEqual(meal.g240, 6.0)
        XCTAssertEqual(meal.minutesAbove10, 70)
        XCTAssertEqual(meal.contaminated, true)
        XCTAssertEqual(meal.score, 0.83)
    }

    func testEpisodeWithOnlyRequiredFieldsDecodes() throws {
        let list = try XCTUnwrap(episodes(#"{"type":"episodes","episodes":[{"id":"a1","kind":"ACTIVITY","at":"2026-10-21T18:00"}]}"#))
        XCTAssertEqual(list.count, 1)
        XCTAssertNil(list[0].text)
        XCTAssertNil(list[0].doseUnits)
        XCTAssertNil(list[0].contaminated)
        XCTAssertNil(list[0].score)
    }

    func testEmptyEpisodesList() {
        XCTAssertEqual(episodes(#"{"type":"episodes","episodes":[]}"#), [])
        XCTAssertEqual(episodes(#"{"type":"episodes"}"#), [])
    }

    func testEpisodeOfUnknownKindIsIgnoredOthersKept() throws {
        let line = #"{"type":"episodes","episodes":[{"id":"x","kind":"SLEEP","at":"2026-10-12T13:00"},{"id":"m","kind":"MEAL","at":"2026-10-12T13:00"},{"nope":1}]}"#
        XCTAssertEqual(try XCTUnwrap(episodes(line)).map(\.id), ["m"])
    }

    func testUnknownTypeAndJunkAreIgnored() {
        XCTAssertNil(BackendAPI.decodeAssistantEvent(line: #"{"type":"hologram","x":1}"#))
        XCTAssertNil(BackendAPI.decodeAssistantEvent(line: ""))
        XCTAssertNil(BackendAPI.decodeAssistantEvent(line: "not json"))
        XCTAssertNil(BackendAPI.decodeAssistantEvent(line: #"{"text":"no type"}"#))
    }

    func testDecodesHistoryPage() throws {
        let json = """
        [
          {"id":"a1","createdAt":"2026-10-30T11:00:00.123Z","role":"ASSISTANT","text":"Logged 5 U + 50 g. IOB 5.3 U.","intent":"quick_log","hasPhoto":false,"noteIds":[],"payload":{"type":"logged","noteIds":["n1"],"summary":"Logged 5 U + 50 g. IOB 5.3 U.","iob":5.3,"forecastMin":null,"userMessageId":"u1"}},
          {"id":"u1","createdAt":"2026-10-30T11:00:00.100Z","role":"USER","text":"5u 50g","intent":"quick_log","hasPhoto":false,"noteIds":["n1"],"payload":{"hypoEventId":"h1","undone":true}},
          {"id":"u0","createdAt":"2026-10-30T10:00:00Z","role":"USER","text":null,"intent":null,"hasPhoto":true,"noteIds":[],"payload":null}
        ]
        """
        let rows = try GlucoseMonitorAPI.jsonDecoder().decode([BackendAPI.ChatMessageDTO].self, from: Data(json.utf8))
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].role, "ASSISTANT")
        XCTAssertEqual(rows[0].payload?.type, "logged")
        XCTAssertEqual(rows[0].payload?.userMessageId, "u1")
        XCTAssertEqual(rows[0].payload?.summary, "Logged 5 U + 50 g. IOB 5.3 U.")
        XCTAssertEqual(rows[1].payload?.undone, true)
        XCTAssertEqual(rows[1].noteIds, ["n1"])
        XCTAssertNil(rows[2].text)
        XCTAssertTrue(rows[2].hasPhoto)
        XCTAssertEqual(rows[2].createdAt, Date(timeIntervalSince1970: 1_793_354_400))
    }

    func testDecodesUndoResult() throws {
        let json = #"{"messageId":"u1","noteIds":["n1"],"undone":true}"#
        let r = try GlucoseMonitorAPI.jsonDecoder().decode(BackendAPI.AssistantUndoResult.self, from: Data(json.utf8))
        XCTAssertEqual(r, BackendAPI.AssistantUndoResult(messageId: "u1", noteIds: ["n1"], undone: true))
    }

    func testMultipartBodyCarriesContractFields() throws {
        let body = BackendAPI.assistantMultipartBody(text: "5u 50g", photoJPEG: Data([0xFF, 0xD8]),
                                                     clientTime: "2026-10-30T12:00:00", timezone: "Europe/Berlin",
                                                     boundary: "B")
        let s = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(s.contains("name=\"text\"\r\n\r\n5u 50g\r\n"))
        XCTAssertTrue(s.contains("name=\"clientTime\"\r\n\r\n2026-10-30T12:00:00\r\n"))
        XCTAssertTrue(s.contains("name=\"timezone\"\r\n\r\nEurope/Berlin\r\n"))
        XCTAssertTrue(s.contains("name=\"photo\"; filename=\"photo.jpg\"\r\nContent-Type: image/jpeg"))
        XCTAssertTrue(s.hasSuffix("--B--\r\n"))
    }

    func testMultipartBodyOmitsMissingTextAndPhoto() {
        let s = String(decoding: BackendAPI.assistantMultipartBody(text: nil, photoJPEG: nil,
                                                                   clientTime: "2026-10-30T12:00:00",
                                                                   timezone: "UTC", boundary: "B"), as: UTF8.self)
        XCTAssertFalse(s.contains("name=\"text\""))
        XCTAssertFalse(s.contains("name=\"photo\""))
    }

    @MainActor func testConnectionLostMidReplyKeepsTheUserSignedIn() async {
        // A slow LLM or a mobile drop must not throw the user to sign-in mid-conversation.
        let cleared = expectation(forNotification: GlucoseMonitorAPI.sessionClearedNotification, object: nil)
        cleared.isInverted = true
        defer { GlucoseMonitorAPI.sharedDefaults().removeObject(forKey: BackendAPI.signOutReasonKey) }
        let lines = AsyncThrowingStream<String, Error> { c in
            c.yield(#"{"type":"token","text":"Your glucose"}"#)
            c.finish(throwing: URLError(.networkConnectionLost))
        }
        var received: [BackendAPI.AssistantEvent] = []

        do {
            try await BackendAPI.runAssistantStream(openLines: { lines }) { received.append($0) }
            XCTFail("the transport error must reach the chat")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
        }

        XCTAssertEqual(received, [.token("Your glucose")])
        await fulfillment(of: [cleared], timeout: 0.3)
        XCTAssertNil(GlucoseMonitorAPI.sharedDefaults().string(forKey: BackendAPI.signOutReasonKey))
    }

    @MainActor func testStreamStopsReadingAfterError() async throws {
        let lines = AsyncThrowingStream<String, Error> { c in
            c.yield(#"{"type":"token","text":"partial"}"#)
            c.yield(#"{"type":"error","message":"Assistant reply failed"}"#)
            c.yield(#"{"type":"token","text":"never"}"#)
            c.finish()
        }
        var received: [BackendAPI.AssistantEvent] = []
        try await BackendAPI.runAssistantStream(openLines: { lines }) { received.append($0) }
        XCTAssertEqual(received, [.token("partial"), .error("Assistant reply failed")])
    }

    func testClientTimeIsNaiveLocalWallTime() {
        let berlin = TimeZone(identifier: "Europe/Berlin")!
        // 2026-10-30T11:00:00Z is 12:00 in Berlin (CET, after the October switch).
        let s = BackendAPI.assistantClientTime(Date(timeIntervalSince1970: 1_793_358_000), timeZone: berlin)
        XCTAssertEqual(s, "2026-10-30T12:00:00")
    }
}
