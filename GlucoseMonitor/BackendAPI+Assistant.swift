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
}

struct BackendAssistantService: AssistantChatService {
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

    /// One NDJSON line of the assistant stream, keyed by its `type`. `plan`, `episodes`, `banner` and
    /// `citations` are not sent by the backend yet; they decode so a newer backend never breaks the stream.
    enum AssistantEvent: Equatable {
        case logged(AssistantLogged)
        case token(String)
        case done(AssistantDone)
        case error(String)
        case plan
        case episodes
        case banner(level: String?, text: String)
        case citations([String])
    }

    private struct AssistantEventEnvelope: Decodable {
        let type: String?
        let text: String?
        let message: String?
        let level: String?
        let ids: [String]?
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
            return .plan
        case "episodes":
            return .episodes
        case "banner":
            return env.text.map { .banner(level: env.level, text: $0) }
        case "citations":
            return .citations(env.ids ?? [])
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

        init(id: String, createdAt: Date, role: String, text: String?, intent: String?,
             hasPhoto: Bool, noteIds: [String], payload: ChatMessagePayload?) {
            self.id = id; self.createdAt = createdAt; self.role = role; self.text = text
            self.intent = intent; self.hasPhoto = hasPhoto; self.noteIds = noteIds; self.payload = payload
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
        }
    }

    struct AssistantUndoResult: Decodable, Equatable {
        let messageId: String
        let noteIds: [String]
        let undone: Bool
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
}
