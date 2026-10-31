import Foundation
import UIKit

// MARK: - Assistant chat (backend /api/assistant/messages)

/// The chat backend as the view model sees it; `BackendAssistantService` is the live one and tests
/// substitute a fake.
protocol AssistantChatService {
    /// Posts one message and calls `onEvent` for every NDJSON event, in order. Returns when the stream ends.
    func sendMessage(text: String?, photoJPEG: Data?, clientTime: String, timezone: String,
                     onEvent: @MainActor @escaping (BackendAPI.AssistantEvent) -> Void) async throws
    /// Rows strictly older than `before` (nil = newest), newest first.
    func fetchHistory(before: Date?, limit: Int) async throws -> [BackendAPI.ChatMessageDTO]
    func undo(messageId: String) async throws -> BackendAPI.AssistantUndoResult
    /// How often the frozen twin forecasts were within tolerance of the CGM.
    func fetchHitRate() async throws -> BackendAPI.AssistantHitRate
    /// Took it / Eating now / Not eating on a meal plan card.
    func mealPlanAction(messageId: String, action: BackendAPI.MealPlanAction, clientTime: String,
                        timezone: String) async throws -> BackendAPI.MealPlanActionResult
    /// Low re-check of a chosen dose on a PLANNED plan (history banner).
    func recheckDose(messageId: String, doseUnits: Double, clientTime: String,
                     timezone: String) async throws -> BackendAPI.DoseRecheck
    /// Confirm on a proposed event: saves the note.
    func confirmEvent(messageId: String, clientTime: String, timezone: String) async throws -> BackendAPI.EventConfirmResult
}

struct BackendAssistantService: AssistantChatService {
    func confirmEvent(messageId: String, clientTime: String, timezone: String) async throws -> BackendAPI.EventConfirmResult {
        try await BackendAPI.postEventConfirm(messageId: messageId, clientTime: clientTime, timezone: timezone)
    }

    func recheckDose(messageId: String, doseUnits: Double, clientTime: String,
                     timezone: String) async throws -> BackendAPI.DoseRecheck {
        try await BackendAPI.postDoseRecheck(messageId: messageId, doseUnits: doseUnits, clientTime: clientTime,
                                             timezone: timezone)
    }

    func sendMessage(text: String?, photoJPEG: Data?, clientTime: String, timezone: String,
                     onEvent: @MainActor @escaping (BackendAPI.AssistantEvent) -> Void) async throws {
        try await BackendAPI.streamAssistantMessage(text: text, photoJPEG: photoJPEG, clientTime: clientTime,
                                                    timezone: timezone, onEvent: onEvent)
    }

    func fetchHistory(before: Date?, limit: Int) async throws -> [BackendAPI.ChatMessageDTO] {
        try await BackendAPI.fetchAssistantHistory(before: before, limit: limit)
    }

    func undo(messageId: String) async throws -> BackendAPI.AssistantUndoResult {
        try await BackendAPI.undoAssistantMessage(id: messageId)
    }

    func fetchHitRate() async throws -> BackendAPI.AssistantHitRate {
        try await BackendAPI.fetchAssistantHitRate()
    }

    func mealPlanAction(messageId: String, action: BackendAPI.MealPlanAction, clientTime: String,
                        timezone: String) async throws -> BackendAPI.MealPlanActionResult {
        try await BackendAPI.postMealPlanAction(messageId: messageId, action: action, clientTime: clientTime,
                                                timezone: timezone)
    }
}

extension BackendAPI {

    struct AssistantLogged: Decodable, Equatable {
        let noteIds: [String]
        let summary: String
        let iob: Double?
        let forecastMin: Double?
    }

    struct AssistantDone: Decodable, Equatable {
        let userMessageId: String?
        let assistantMessageId: String?
        let intent: String?
    }

    /// One past event the answer is based on (a similar meal, a correction, an activity or a low). Glucose
    /// is mmol/L, minutes count from `at`, `at` is the user's wall clock (`yyyy-MM-ddTHH:mm`).
    struct AssistantEpisode: Decodable, Equatable, Identifiable {
        enum Kind: String, Decodable { case MEAL, CORRECTION, ACTIVITY, LOW }
        let id: String
        let kind: Kind
        let at: String
        let text: String?
        let carbs: Double?
        let fat: Double?
        let protein: Double?
        let doseUnits: Double?
        let pauseMinutes: Int?
        let startGlucose: Double?
        let peak: Double?
        let peakMinute: Int?
        let nadir: Double?
        let nadirMinute: Int?
        let g60: Double?
        let g120: Double?
        let g240: Double?
        let minutesBelow39: Int?
        let minutesAbove10: Int?
        let activityMinutes: Int?
        let contaminated: Bool?
        let score: Double?
    }

    /// A clinical-library source the reply cites as `[ref]`. Only http(s) links are kept: an entry with
    /// any other URL (or none), or without `ref`/`title`, does not decode and is dropped from the list.
    struct AssistantCitation: Decodable, Equatable, Identifiable {
        let ref: Int
        let title: String
        let source: String?
        let year: Int?
        let url: URL
        var id: Int { ref }

        init(ref: Int, title: String, source: String? = nil, year: Int? = nil, url: URL) {
            self.ref = ref; self.title = title; self.source = source; self.year = year; self.url = url
        }

        private enum CodingKeys: String, CodingKey { case ref, title, source, year, url }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ref = try c.decode(Int.self, forKey: .ref)
            let rawTitle = try c.decode(String.self, forKey: .title).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawTitle.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .title, in: c, debugDescription: "empty title")
            }
            title = rawTitle
            let src = (try? c.decodeIfPresent(String.self, forKey: .source))?.trimmingCharacters(in: .whitespacesAndNewlines)
            source = (src?.isEmpty ?? true) ? nil : src
            year = (try? c.decodeIfPresent(Int.self, forKey: .year)) ?? nil
            let raw = try c.decode(String.self, forKey: .url).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = URL(string: raw), let scheme = parsed.scheme?.lowercased(),
                  scheme == "http" || scheme == "https", parsed.host?.isEmpty == false else {
                throw DecodingError.dataCorruptedError(forKey: .url, in: c, debugDescription: "not an http(s) URL")
            }
            url = parsed
        }

        /// Chip text, e.g. "[1] ADA Standards of Care · ADA 2024".
        var chipLabel: String {
            var tail = [source, year.map(String.init)].compactMap { $0 }.joined(separator: " ")
            if !tail.isEmpty { tail = " · " + tail }
            return "[\(ref)] \(title)\(tail)"
        }
    }

    /// One citation that decodes to nil instead of failing the whole list.
    private struct LossyCitation: Decodable {
        let value: AssistantCitation?
        init(from decoder: Decoder) throws { value = try? AssistantCitation(from: decoder) }
    }

    private static func lossyCitations<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> [AssistantCitation]? {
        guard let items = (try? c.decodeIfPresent([LossyCitation].self, forKey: key)) ?? nil else { return nil }
        return items.compactMap(\.value)
    }

    private struct CitationsEventBody: Decodable {
        let citations: [AssistantCitation]

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            citations = BackendAPI.lossyCitations(c, .citations) ?? []
        }

        private enum CodingKeys: String, CodingKey { case citations }
    }

    /// One NDJSON line of the assistant stream, keyed by its `type`.
    enum AssistantEvent: Equatable {
        case logged(AssistantLogged)
        case token(String)
        case done(AssistantDone)
        case error(String)
        /// Meal prep: the plan card for assistant message `messageId`. The planned dose is valid up to
        /// `doseValidUntil` (user wall time).
        case plan(messageId: String, plan: MealPlan, plannedAt: Date?, doseValidUntil: Date?)
        /// Past events behind the answer (top 5); entries of an unknown kind are dropped.
        case episodes([AssistantEpisode])
        /// History-dose banner for the plan card `messageId` (sent right after `plan`).
        case banner(messageId: String, banner: HistoryBanner)
        /// Sources behind the reply (question path, sent before the first token); unusable entries are dropped.
        case citations([AssistantCitation])
        /// A free-text event proposed as a note (assistant message `messageId`); saved only on Confirm.
        case proposal(messageId: String, tags: [String], comment: String?)
    }

    private struct AssistantEventEnvelope: Decodable {
        let type: String?
        let text: String?
        let message: String?
        let level: String?
    }

    /// One episode that decodes to nil instead of failing the whole list.
    private struct LossyEpisode: Decodable {
        let value: AssistantEpisode?
        init(from decoder: Decoder) throws { value = try? AssistantEpisode(from: decoder) }
    }

    private struct EpisodesEventBody: Decodable {
        let episodes: [AssistantEpisode]

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let items = (try? c.decodeIfPresent([LossyEpisode].self, forKey: .episodes)) ?? nil
            episodes = (items ?? []).compactMap(\.value)
        }

        private enum CodingKeys: String, CodingKey { case episodes }
    }

    private struct BannerEventBody: Decodable {
        let messageId: String
        let banner: HistoryBanner
    }

    private struct PlanEventBody: Decodable {
        let messageId: String
        let plan: MealPlan
        let plannedAt: Date?
        let doseValidUntil: Date?
    }

    /// Decodes one stream line; nil for blank or malformed lines and for unknown event types.
    static func decodeAssistantEvent(line: String) -> AssistantEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        let decoder = GlucoseMonitorAPI.jsonDecoder()
        guard let env = try? decoder.decode(AssistantEventEnvelope.self, from: data), let type = env.type else { return nil }
        switch type {
        case "logged":
            return (try? decoder.decode(AssistantLogged.self, from: data)).map(AssistantEvent.logged)
        case "token":
            return env.text.map(AssistantEvent.token)
        case "done":
            return (try? decoder.decode(AssistantDone.self, from: data)).map(AssistantEvent.done)
        case "error":
            return .error(env.message ?? "Assistant reply failed")
        case "plan":
            return (try? decoder.decode(PlanEventBody.self, from: data)).map {
                .plan(messageId: $0.messageId, plan: $0.plan, plannedAt: $0.plannedAt, doseValidUntil: $0.doseValidUntil)
            }
        case "episodes":
            return (try? decoder.decode(EpisodesEventBody.self, from: data)).map { .episodes($0.episodes) }
        case "banner":
            return (try? decoder.decode(BannerEventBody.self, from: data)).map { .banner(messageId: $0.messageId, banner: $0.banner) }
        case "citations":
            return (try? decoder.decode(CitationsEventBody.self, from: data)).map { .citations($0.citations) }
        case "proposal":
            return (try? decoder.decode(ProposalEventBody.self, from: data)).map {
                .proposal(messageId: $0.messageId, tags: $0.tags ?? [], comment: $0.comment)
            }
        default:
            return nil
        }
    }

    /// Free-form `payload` of a history row. Every field is optional: a USER row carries
    /// `hypoEventId`/`undone`, a quick-log ASSISTANT row carries the logged event plus `userMessageId`.
    struct ChatMessagePayload: Decodable, Equatable {
        let type: String?
        let noteIds: [String]?
        let summary: String?
        let iob: Double?
        let forecastMin: Double?
        let userMessageId: String?
        let undone: Bool?
        let hypoEventId: String?
        /// Question replies store the cards they were shown with (plan replies do not).
        var episodes: [AssistantEpisode]? = nil
        /// Question replies store the sources they cited.
        var citations: [AssistantCitation]? = nil

        fileprivate enum CodingKeys: String, CodingKey {
            case type, noteIds, summary, iob, forecastMin, userMessageId, undone, hypoEventId, episodes, citations
        }
    }

    /// Hand-written so malformed `episodes` are dropped without losing the rest of the payload.
    fileprivate static func decodeLossyEpisodes(_ c: KeyedDecodingContainer<ChatMessagePayload.CodingKeys>) -> [AssistantEpisode]? {
        guard let items = (try? c.decodeIfPresent([LossyEpisode].self, forKey: .episodes)) ?? nil else { return nil }
        return items.compactMap(\.value)
    }

    struct ChatMessageDTO: Decodable, Equatable {
        let id: String
        let createdAt: Date
        let role: String
        let text: String?
        let intent: String?
        let hasPhoto: Bool
        let noteIds: [String]
        let payload: ChatMessagePayload?
        /// The same `payload` read as a meal plan, for intent `meal_plan` rows.
        let mealPlan: MealPlanPayload?
        /// The same `payload` read as an event proposal, for intent `event_proposal` rows.
        let eventProposal: EventProposalPayload?

        init(id: String, createdAt: Date, role: String, text: String?, intent: String?,
             hasPhoto: Bool, noteIds: [String], payload: ChatMessagePayload?, mealPlan: MealPlanPayload? = nil,
             eventProposal: EventProposalPayload? = nil) {
            self.id = id; self.createdAt = createdAt; self.role = role; self.text = text
            self.intent = intent; self.hasPhoto = hasPhoto; self.noteIds = noteIds; self.payload = payload
            self.mealPlan = mealPlan; self.eventProposal = eventProposal
        }

        private enum CodingKeys: String, CodingKey {
            case id, createdAt, role, text, intent, hasPhoto, noteIds, payload
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            createdAt = try c.decode(Date.self, forKey: .createdAt)
            role = try c.decode(String.self, forKey: .role)
            text = try c.decodeIfPresent(String.self, forKey: .text)
            intent = try c.decodeIfPresent(String.self, forKey: .intent)
            hasPhoto = try c.decodeIfPresent(Bool.self, forKey: .hasPhoto) ?? false
            noteIds = try c.decodeIfPresent([String].self, forKey: .noteIds) ?? []
            payload = try? c.decodeIfPresent(ChatMessagePayload.self, forKey: .payload)
            mealPlan = intent == "meal_plan" ? (try? c.decodeIfPresent(MealPlanPayload.self, forKey: .payload)) ?? nil : nil
            eventProposal = intent == "event_proposal"
                ? (try? c.decodeIfPresent(EventProposalPayload.self, forKey: .payload)) ?? nil : nil
        }
    }

    struct AssistantUndoResult: Decodable, Equatable {
        let messageId: String
        let noteIds: [String]
        let undone: Bool
    }

    /// `percent` is nil when no forecast has been checked yet (`checks == 0`).
    struct AssistantHitRate: Decodable, Equatable {
        let hits: Int
        let checks: Int
        let percent: Double?
    }

    // MARK: Request building

    /// Naive local wall time (`yyyy-MM-dd'T'HH:mm:ss`, no offset) in `timeZone`, as `clientTime` requires.
    static func assistantClientTime(_ date: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.string(from: date)
    }

    static func assistantMultipartBody(text: String?, photoJPEG: Data?, clientTime: String,
                                       timezone: String, boundary: String) -> Data {
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        if let text { field("text", text) }
        field("clientTime", clientTime)
        field("timezone", timezone)
        if let photoJPEG {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"photo\"; filename=\"photo.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8))
            body.append(photoJPEG)
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }

    /// Resized JPEG under 1 MB (the backend allows 10 MB; this keeps uploads fast).
    static func assistantPhotoJPEG(_ image: UIImage) -> Data? {
        compressUnder1MB(resizeImage(image, maxSide: 1600))
    }

    /// Question replies wait on the LLM; give the stream the same headroom as photo analysis.
    private static let assistantSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 300
        c.timeoutIntervalForResource = 300
        return URLSession(configuration: c)
    }()

    // MARK: Calls

    static func streamAssistantMessage(text: String?, photoJPEG: Data?, clientTime: String, timezone: String,
                                       onEvent: @MainActor @escaping (AssistantEvent) -> Void) async throws {
        try await runAssistantStream(openLines: {
            var req = try authorizedRequest(path: "/api/assistant/messages", method: "POST")
            let boundary = "Boundary-\(UUID().uuidString)"
            req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            req.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
            req.httpBody = assistantMultipartBody(text: text, photoJPEG: photoJPEG, clientTime: clientTime,
                                                  timezone: timezone, boundary: boundary)
            req.timeoutInterval = 300

            let (bytes, resp) = try await assistantSession.bytes(for: req)
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                // Validation failures come back as a plain JSON error body, not a stream.
                var data = Data()
                for try await b in bytes { data.append(b); if data.count > 16_384 { break } }
                try checkStatus(resp, data: data)
            }
            return bytes.lines
        }, onEvent: onEvent)
    }

    /// Opens the stream and forwards decoded events until `done` or `error` (a failed reply sends `error`
    /// with no `done` after it). A 401 still refreshes and retries; transport errors mid-reply (a slow LLM
    /// hitting the timeout, a mobile connection drop) reach the chat as an error but do NOT sign the user
    /// out - the same rule as other slow-upstream calls (`performWithRefresh` doc).
    static func runAssistantStream<Lines: AsyncSequence>(
        openLines: () async throws -> Lines,
        onEvent: @MainActor @escaping (AssistantEvent) -> Void
    ) async throws where Lines.Element == String {
        try await performWithRefresh(signOutIfUnreachable: false) {
            for try await line in try await openLines() {
                guard let event = decodeAssistantEvent(line: line) else { continue }
                await onEvent(event)
                if case .done = event { break }
                if case .error = event { break }
            }
        }
    }

    static func fetchAssistantHistory(before: Date?, limit: Int) async throws -> [ChatMessageDTO] {
        // The chat loads history on its own; a flaky connection there must not sign the user out.
        try await performWithRefresh(signOutIfUnreachable: false) {
            var path = "/api/assistant/messages?limit=\(limit)"
            if let before {
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                path += "&before=\(f.string(from: before))"
            }
            let req = try authorizedRequest(path: path)
            let (data, resp) = try await URLSession.shared.data(for: req)
            try checkStatus(resp, data: data)
            return try GlucoseMonitorAPI.jsonDecoder().decode([ChatMessageDTO].self, from: data)
        }
    }

    static func undoAssistantMessage(id: String) async throws -> AssistantUndoResult {
        try await performWithRefresh {
            let req = try authorizedRequest(path: "/api/assistant/messages/\(id)/undo", method: "POST")
            let (data, resp) = try await URLSession.shared.data(for: req)
            try checkStatus(resp, data: data)
            return try GlucoseMonitorAPI.jsonDecoder().decode(AssistantUndoResult.self, from: data)
        }
    }

    static func fetchAssistantHitRate() async throws -> AssistantHitRate {
        // A header pill must never sign the user out when the connection is flaky.
        try await performWithRefresh(signOutIfUnreachable: false) {
            let req = try authorizedRequest(path: "/api/assistant/hit-rate")
            let (data, resp) = try await URLSession.shared.data(for: req)
            try checkStatus(resp, data: data)
            return try GlucoseMonitorAPI.jsonDecoder().decode(AssistantHitRate.self, from: data)
        }
    }
}

extension BackendAPI.ChatMessagePayload {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        noteIds = try c.decodeIfPresent([String].self, forKey: .noteIds)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        iob = try c.decodeIfPresent(Double.self, forKey: .iob)
        forecastMin = try c.decodeIfPresent(Double.self, forKey: .forecastMin)
        userMessageId = try c.decodeIfPresent(String.self, forKey: .userMessageId)
        undone = try c.decodeIfPresent(Bool.self, forKey: .undone)
        hypoEventId = try c.decodeIfPresent(String.self, forKey: .hypoEventId)
        episodes = BackendAPI.decodeLossyEpisodes(c)
        citations = BackendAPI.lossyCitations(c, .citations)
    }
}
