import Foundation
import Security

/// Shared API client for the Spring backend (`glucose-monitor-be`).
/// Used by the iOS app and the watchOS app; non-secret settings use App Group `UserDefaults`, JWTs use Keychain.
public enum GlucoseMonitorAPI {

    // MARK: - Single-flight JWT refresh (iOS-P0-3)

    private actor TokenRefreshCoordinator {
        static let shared = TokenRefreshCoordinator()
        private var inFlight: Task<Void, Error>?

        func refresh() async throws {
            if let existing = inFlight {
                try await existing.value
                return
            }
            let task = Task<Void, Error> {
                try await GlucoseMonitorAPI.performRefreshTokenRequest()
            }
            inFlight = task
            defer { inFlight = nil }
            try await task.value
        }
    }

    public static let appGroupIdentifier = "group.che.glucosemonitor"

    /// Production API hosted on Railway.
    public static let defaultBackendBaseURL = "https://glucose-monitor-be-production.up.railway.app"

    public enum StorageKey {
        public static let backendURL = "gm_backend_url"
        public static let accessToken = "gm_access_token"
        public static let refreshToken = "gm_refresh_token"
        public static let patientId = "gm_patient_id"
        public static let libreEmail = "gm_libre_email"
        public static let librePassword = "gm_libre_password"
        /// User-selected LibreLinkUp region locale, e.g. "fr-FR". Overrides device locale.
        public static let libreRegion = "gm_libre_region"
        /// Last backend (Spring) sign-in username/password for Settings prefill (App Group).
        public static let appUsername = "gm_app_username"
        public static let appPassword = "gm_app_password"
        public static let dataSource = "gm_data_source"
        /// Last time proactive JWT refresh succeeded (throttles refresh calls).
        public static let lastSessionRefreshAt = "gm_last_session_refresh_at"
        /// User-preferred glucose display unit: "mmol/L" or "mg/dL".
        public static let glucoseDisplayUnit = "gm_glucose_display_unit"
        /// User-configured local backend IP (e.g. "192.168.1.10"), port 8080 appended automatically.
        public static let localIP = "gm_local_ip"
    }

    // MARK: - Credential secrets (Keychain, App Group - iOS-P0-4)
    //
    // gm_app_password and gm_libre_password are moved from App Group UserDefaults to Keychain.
    // Any process with the App Group entitlement (Watch, widgets) could read UD; Keychain is
    // scoped to the app group but requires explicit entitlement grant and is encrypted at rest.

    private enum CredentialsStorage {
        private static let service = "com.che.glucosemonitor.credentials"

        private static func baseQuery(account: String) -> [String: Any] {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) != nil {
                query[kSecAttrAccessGroup as String] = appGroupIdentifier
            }
            return query
        }

        /// Migrate a legacy UserDefaults value into Keychain once, then remove it from UD.
        private static func migrateFromUserDefaultsIfNeeded(account: String) {
            let ud = sharedDefaults()
            guard let legacy = ud.string(forKey: account), !legacy.isEmpty else { return }
            _ = save(account: account, value: legacy)
            ud.removeObject(forKey: account)
            ud.synchronize()
        }

        static func load(account: String) -> String? {
            migrateFromUserDefaultsIfNeeded(account: account)
            var query = baseQuery(account: account)
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            query[kSecReturnData as String] = true
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            guard status == errSecSuccess,
                  let data = item as? Data,
                  let value = String(data: data, encoding: .utf8),
                  !value.isEmpty else {
                return nil
            }
            return value
        }

        @discardableResult
        static func save(account: String, value: String) -> Bool {
            let data = Data(value.utf8)
            var query = baseQuery(account: account)
            let attributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if updateStatus == errSecSuccess { return true }
            if updateStatus == errSecItemNotFound {
                query.merge(attributes) { _, new in new }
                return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
            }
            return false
        }

        static func delete(account: String) {
            let query = baseQuery(account: account)
            SecItemDelete(query as CFDictionary)
            sharedDefaults().removeObject(forKey: account)
        }
    }

    // MARK: - Session tokens (Keychain, App Group - I1)

    private enum SessionTokenStorage {
        private static let service = "com.che.glucosemonitor.jwt"

        private static func baseQuery(account: String) -> [String: Any] {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) != nil {
                query[kSecAttrAccessGroup as String] = appGroupIdentifier
            }
            return query
        }

        private static func migrateFromUserDefaultsIfNeeded(account: String) {
            let ud = sharedDefaults()
            guard let legacy = ud.string(forKey: account), !legacy.isEmpty else { return }
            _ = save(account: account, value: legacy)
            ud.removeObject(forKey: account)
            ud.synchronize()
        }

        static func load(account: String) -> String? {
            migrateFromUserDefaultsIfNeeded(account: account)
            var query = baseQuery(account: account)
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            query[kSecReturnData as String] = true
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            guard status == errSecSuccess,
                  let data = item as? Data,
                  let value = String(data: data, encoding: .utf8),
                  !value.isEmpty else {
                return nil
            }
            return value
        }

        @discardableResult
        static func save(account: String, value: String) -> Bool {
            let data = Data(value.utf8)
            var query = baseQuery(account: account)
            let attributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if updateStatus == errSecSuccess {
                return true
            }
            if updateStatus == errSecItemNotFound {
                query.merge(attributes) { _, new in new }
                return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
            }
            return false
        }

        static func delete(account: String) {
            let query = baseQuery(account: account)
            SecItemDelete(query as CFDictionary)
            sharedDefaults().removeObject(forKey: account)
        }

        static func store(accessToken: String, refreshToken: String?) {
            save(account: StorageKey.accessToken, value: accessToken)
            if let refreshToken, !refreshToken.isEmpty {
                save(account: StorageKey.refreshToken, value: refreshToken)
            } else {
                delete(account: StorageKey.refreshToken)
            }
            sharedDefaults().removeObject(forKey: StorageKey.accessToken)
            sharedDefaults().removeObject(forKey: StorageKey.refreshToken)
            sharedDefaults().synchronize()
        }

        static func clear() {
            delete(account: StorageKey.accessToken)
            delete(account: StorageKey.refreshToken)
            sharedDefaults().removeObject(forKey: StorageKey.accessToken)
            sharedDefaults().removeObject(forKey: StorageKey.refreshToken)
            sharedDefaults().synchronize()
        }
    }

    public static func storedAccessToken() -> String? {
        SessionTokenStorage.load(account: StorageKey.accessToken)
    }

    public static func storedRefreshToken() -> String? {
        SessionTokenStorage.load(account: StorageKey.refreshToken)
    }

    public static func storeSessionTokens(accessToken: String, refreshToken: String?) {
        SessionTokenStorage.store(accessToken: accessToken, refreshToken: refreshToken)
    }

    public struct AuthLoginBody: Encodable {
        public let username: String
        public let password: String
    }

    public struct AuthRegisterBody: Encodable {
        public let username: String
        public let email: String
        public let fullName: String
        public let password: String
    }

    public struct AuthResponseBody: Decodable {
        public let accessToken: String
        public let refreshToken: String?
        public let tokenType: String?
        public let expiresIn: Int64?
    }

    public struct LibreLoginBody: Encodable {
        public let email: String
        public let password: String
        /// IETF BCP 47 locale tag (e.g. "fr-FR") - tells the backend which regional
        /// LibreLinkUp endpoint to probe first so French accounts aren't rejected by api-eu.
        public let locale: String
    }

    public struct LibreGlucoseCurrent: Decodable {
        public let timestamp: Date?
        public let value: Double?
        public let trend: Int?
        public let trendArrow: String?
        public let status: String?
        public let unit: String?

        public init(timestamp: Date?, value: Double?, trend: Int?, trendArrow: String?, status: String?, unit: String?) {
            self.timestamp = timestamp
            self.value = value
            self.trend = trend
            self.trendArrow = trendArrow
            self.status = status
            self.unit = unit
        }

        // Custom Decodable so the timestamp is always interpreted as UTC.
        // The backend's global Spring date-format ("yyyy-MM-dd'T'HH:mm:ss") emits naive UTC
        // strings with no timezone suffix.  The shared jsonDecoder() fallback uses
        // TimeZone.current which misinterprets UTC times as local time - causing an offset
        // equal to the device's UTC offset (e.g. "Updated 3 hrs ago" on a UTC+3 device).
        private enum CodingKeys: String, CodingKey {
            case timestamp, value, trend, trendArrow, status, unit
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            value = try? c.decodeIfPresent(Double.self, forKey: .value)
            trend = try? c.decodeIfPresent(Int.self, forKey: .trend)
            trendArrow = try? c.decodeIfPresent(String.self, forKey: .trendArrow)
            status = try? c.decodeIfPresent(String.self, forKey: .status)
            unit = try? c.decodeIfPresent(String.self, forKey: .unit)
            timestamp = Self.decodeCGMTimestamp(c)
        }

        /// Parses the timestamp field as UTC regardless of the backend's timezone setting.
        /// Handles epoch-ms integers, ISO-8601 with explicit offset, and naive strings.
        private static func decodeCGMTimestamp(_ c: KeyedDecodingContainer<CodingKeys>) -> Date? {
            // Epoch milliseconds (integer or double)
            if let ms = try? c.decodeIfPresent(Int64.self, forKey: .timestamp) {
                return Date(timeIntervalSince1970: Double(ms) / 1000.0)
            }
            if let ms = try? c.decodeIfPresent(Double.self, forKey: .timestamp) {
                return Date(timeIntervalSince1970: ms / 1000.0)
            }
            guard let s = try? c.decodeIfPresent(String.self, forKey: .timestamp), !s.isEmpty else {
                return nil
            }
            // ISO-8601 with explicit timezone (Z or +/-HH:MM) - parsed correctly by iOS
            let f1 = ISO8601DateFormatter()
            f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f1.date(from: s) { return d }
            let f2 = ISO8601DateFormatter()
            f2.formatOptions = [.withInternetDateTime]
            if let d = f2.date(from: s) { return d }
            // Naive string (no timezone suffix): Spring emits UTC time without 'Z' due to the
            // global date-format setting.  Interpret as UTC - NOT device local time.
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(identifier: "UTC")
            for fmt in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss"] {
                df.dateFormat = fmt
                if let d = df.date(from: s) { return d }
            }
            return nil
        }
    }

    public enum APIError: Error, LocalizedError {
        case invalidURL
        case missingBackendURL
        case missingPatientId
        case missingToken
        case httpStatus(Int, String?)
        case decoding(Error)

        public var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid backend URL."
            case .missingBackendURL: return "Backend URL is not configured."
            case .missingPatientId: return "Libre patient ID is not configured."
            case .missingToken: return "Not signed in. Use the iPhone app to sign in."
            case .httpStatus(let code, let body):
                return "Server error (\(code)): \(body ?? "")"
            case .decoding(let err):
                return "Could not read response: \(err.localizedDescription)"
            }
        }
    }

    /// App Group `UserDefaults` only when this process has a provisioned container.
    /// Otherwise falls back to `standard` (avoids CFPreferences container-null / cfprefsd detach noise in Previews and targets without the group entitlement).
    public static func sharedDefaults() -> UserDefaults {
        guard FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) != nil else {
            return .standard
        }
        return UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }

    public static func jsonDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            let s = try c.decode(String.self)
            let f1 = ISO8601DateFormatter()
            f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = f1.date(from: s) { return date }
            let f2 = ISO8601DateFormatter()
            f2.formatOptions = [.withInternetDateTime]
            if let date = f2.date(from: s) { return date }
            // Spring NoteDto LocalDateTime: JsonFormat pattern yyyy-MM-dd'T'HH:mm:ss (no timezone suffix)
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone.current
            for format in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss"] {
                df.dateFormat = format
                if let date = df.date(from: s) { return date }
            }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad date: \(s)")
        }
        return d
    }

    private static func normalizeBaseURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// Stored backend base URL, or `defaultBackendBaseURL` if the user has not set one.
    public static func effectiveBackendBaseURL() -> String {
        let raw = sharedDefaults().string(forKey: StorageKey.backendURL)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.isEmpty { return normalizeBaseURL(defaultBackendBaseURL) }
        let normalized = normalizeBaseURL(raw)
        #if !DEBUG
        // Release builds must never talk to a cleartext backend (credentials / JWTs on LAN HTTP).
        if normalized.lowercased().hasPrefix("http://") {
            return normalizeBaseURL(defaultBackendBaseURL)
        }
        #endif
        return normalized
    }

    /// Saves the REST base URL (trimmed, no trailing slash), e.g. when the user picks a preset in Settings.
    public static func storeBackendBaseURL(_ raw: String) {
        let normalized = normalizeBaseURL(raw)
        #if !DEBUG
        if normalized.lowercased().hasPrefix("http://") {
            sharedDefaults().set(normalizeBaseURL(defaultBackendBaseURL), forKey: StorageKey.backendURL)
            return
        }
        #endif
        sharedDefaults().set(normalized, forKey: StorageKey.backendURL)
    }

    /// Persists the user-entered local IP address.
    public static func storeLocalIP(_ ip: String) {
        sharedDefaults().set(ip.trimmingCharacters(in: .whitespacesAndNewlines), forKey: StorageKey.localIP)
    }

    /// Builds the local backend URL from the stored IP (port 8080).
    public static func localBackendURL() -> String {
        let ip = sharedDefaults().string(forKey: StorageKey.localIP) ?? ""
        let trimmed = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "http://192.168.1.1:8080" }
        return "http://\(trimmed):8080"
    }

    /// Persists backend login fields for Settings (survives app restarts).
    /// iOS-P0-4 fix: username stays in UserDefaults (non-secret); password moves to Keychain.
    public static func saveAppLoginCredentials(username: String, password: String) {
        let ud = sharedDefaults()
        ud.set(username, forKey: StorageKey.appUsername)
        ud.synchronize()
        CredentialsStorage.save(account: StorageKey.appPassword, value: password)
    }

    public static func storedAppUsername() -> String {
        sharedDefaults().string(forKey: StorageKey.appUsername) ?? ""
    }

    /// iOS-P0-4 fix: reads from Keychain (migrates legacy UserDefaults value on first call).
    public static func storedAppPassword() -> String {
        CredentialsStorage.load(account: StorageKey.appPassword) ?? ""
    }

    /// iOS-P0-4 fix: reads LibreLinkUp password from Keychain (migrates legacy UD value on first call).
    public static func storedLibrePassword() -> String {
        CredentialsStorage.load(account: StorageKey.librePassword) ?? ""
    }

    /// Logs into the backend and stores tokens in the App Group.
    public static func loginAppAccount(username: String, password: String, baseURL: String) async throws {
        let base = normalizeBaseURL(baseURL)
        guard let url = URL(string: base + "/api/auth/login") else { throw APIError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(AuthLoginBody(username: username, password: password))

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.httpStatus(-1, nil) }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw APIError.httpStatus(http.statusCode, String(data: data, encoding: .utf8))
        }
        let body = try jsonDecoder().decode(AuthResponseBody.self, from: data)
        let ud = sharedDefaults()
        ud.set(base, forKey: StorageKey.backendURL)
        storeSessionTokens(accessToken: body.accessToken, refreshToken: body.refreshToken)
        ud.synchronize()
    }

    /// Registers a new account and stores the returned tokens.
    public static func registerAppAccount(username: String, email: String, fullName: String, password: String, baseURL: String) async throws {
        let base = normalizeBaseURL(baseURL)
        guard let url = URL(string: base + "/api/auth/register") else { throw APIError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(AuthRegisterBody(username: username, email: email, fullName: fullName, password: password))

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.httpStatus(-1, nil) }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw APIError.httpStatus(http.statusCode, String(data: data, encoding: .utf8))
        }
        let body = try jsonDecoder().decode(AuthResponseBody.self, from: data)
        let ud = sharedDefaults()
        ud.set(base, forKey: StorageKey.backendURL)
        storeSessionTokens(accessToken: body.accessToken, refreshToken: body.refreshToken)
        ud.synchronize()
    }

    /// Proxies LibreLinkUp login through the backend (requires a valid JWT).
    /// After a successful login the first available connection is fetched automatically
    /// so users never have to enter a patient / connection ID.
    /// - Parameter regionLocale: explicit BCP 47 tag chosen by the user (e.g. "fr-FR").
    ///   Falls back to the stored preference, then to the device locale.
    public static func loginLibre(email: String, password: String, regionLocale: String? = nil) async throws {
        let ud = sharedDefaults()
        let base = effectiveBackendBaseURL()
        guard let url = URL(string: base + "/api/libre/auth/login") else { throw APIError.invalidURL }
        guard let token = storedAccessToken(), !token.isEmpty else { throw APIError.missingToken }

        // Priority: explicit arg -> stored preference -> device locale
        let locale: String
        if let explicit = regionLocale, !explicit.isEmpty {
            locale = explicit
        } else if let stored = ud.string(forKey: StorageKey.libreRegion), !stored.isEmpty {
            locale = stored
        } else {
            locale = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONEncoder().encode(LibreLoginBody(email: email, password: password, locale: locale))

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.httpStatus(-1, nil) }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw APIError.httpStatus(http.statusCode, String(data: data, encoding: .utf8))
        }
        // iOS-P0-4 fix: libreEmail is non-secret (kept in UD); librePassword moves to Keychain.
        ud.set(email, forKey: StorageKey.libreEmail)
        ud.synchronize()
        CredentialsStorage.save(account: StorageKey.librePassword, value: password)

        // Auto-resolve the first connection so no manual patient ID entry is needed.
        if let pid = try? await fetchFirstConnectionId() {
            savePatientId(pid)
        }
    }

    /// Returns the `patientId` of the first LibreLinkUp connection, or `nil` if none found.
    private static func fetchFirstConnectionId() async throws -> String? {
        let ud = sharedDefaults()
        let base = effectiveBackendBaseURL()
        guard let url = URL(string: base + "/api/libre/connections") else { return nil }
        guard let token = storedAccessToken(), !token.isEmpty else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else { return nil }

        struct Connection: Decodable { let patientId: String? }
        let connections = (try? JSONDecoder().decode([Connection].self, from: data)) ?? []
        return connections.first?.patientId
    }

    public static func savePatientId(_ id: String) {
        let ud = sharedDefaults()
        ud.set(id.trimmingCharacters(in: .whitespacesAndNewlines), forKey: StorageKey.patientId)
        ud.synchronize()
    }

    /// Current Libre reading; auto-refreshes JWT once on 401.
    public static func fetchCurrentGlucose() async throws -> LibreGlucoseCurrent {
        do {
            return try await _fetchCurrentGlucose()
        } catch APIError.httpStatus(401, _) {
            try await refreshToken()
            return try await _fetchCurrentGlucose()
        }
    }

    private static func _fetchCurrentGlucose() async throws -> LibreGlucoseCurrent {
        let ud = sharedDefaults()
        let base = effectiveBackendBaseURL()
        guard let pid = ud.string(forKey: StorageKey.patientId)?.trimmingCharacters(in: .whitespacesAndNewlines), !pid.isEmpty else {
            throw APIError.missingPatientId
        }
        guard let token = storedAccessToken(), !token.isEmpty else { throw APIError.missingToken }

        guard let url = URL(string: base + "/api/libre/connections/\(pid)/current") else { throw APIError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.httpStatus(-1, nil) }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw APIError.httpStatus(http.statusCode, String(data: data, encoding: .utf8))
        }
        do {
            return try jsonDecoder().decode(LibreGlucoseCurrent.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    /// Posted after local session tokens are wiped (e.g. refresh failure). UI should treat the user as logged out.
    public static let sessionClearedNotification = Notification.Name("gm.sessionCleared")

    /// Clears stored JWTs. When `notify` is true (default), posts `sessionClearedNotification` so `AppState` can leave the authenticated UI.
    /// Pass `notify: false` from an explicit logout path that already updates UI state.
    public static func clearSession(notify: Bool = true) {
        SessionTokenStorage.clear()
        let ud = sharedDefaults()
        ud.removeObject(forKey: StorageKey.lastSessionRefreshAt)
        ud.synchronize()
        if notify {
            NotificationCenter.default.post(name: sessionClearedNotification, object: nil)
        }
    }

    /// Exchanges the stored refresh token for a new access token (single-flight).
    public static func refreshToken() async throws {
        try await TokenRefreshCoordinator.shared.refresh()
    }

    /// HTTP refresh implementation - call only via `TokenRefreshCoordinator`.
    private static func performRefreshTokenRequest() async throws {
        let ud = sharedDefaults()
        let base = effectiveBackendBaseURL()
        guard let storedRefresh = storedRefreshToken(), !storedRefresh.isEmpty else {
            throw APIError.missingToken
        }
        guard let url = URL(string: base + "/api/auth/refresh") else { throw APIError.invalidURL }

        struct Body: Encodable { let refreshToken: String }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(Body(refreshToken: storedRefresh))

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.httpStatus(-1, nil) }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw APIError.httpStatus(http.statusCode, String(data: data, encoding: .utf8))
        }
        let body = try jsonDecoder().decode(AuthResponseBody.self, from: data)
        storeSessionTokens(accessToken: body.accessToken, refreshToken: body.refreshToken)
        ud.synchronize()
    }

    /// Refreshes access/refresh tokens without clearing the session on failure (network, expired refresh, etc.).
    public static func proactiveRefreshSessionTokens(minimumInterval: TimeInterval) async {
        let ud = sharedDefaults()
        guard let storedRefresh = storedRefreshToken(), !storedRefresh.isEmpty else {
            return
        }
        let now = Date()
        if let last = ud.object(forKey: StorageKey.lastSessionRefreshAt) as? Date,
           now.timeIntervalSince(last) < minimumInterval {
            return
        }
        do {
            try await refreshToken()
            ud.set(now, forKey: StorageKey.lastSessionRefreshAt)
            ud.synchronize()
        } catch {
            // Keep existing tokens; next API call may still work or trigger reactive refresh on 401.
        }
    }

    /// Runs a refresh immediately when the app opens so the refresh token keeps sliding.
    public static func proactiveRefreshSessionTokensOnLaunch() async {
        let ud = sharedDefaults()
        guard storedRefreshToken()?.isEmpty == false else { return }
        do {
            try await refreshToken()
            ud.set(Date(), forKey: StorageKey.lastSessionRefreshAt)
            ud.synchronize()
        } catch {
            // Ignore: offline or refresh not yet valid.
        }
    }

    /// Calls `POST /api/auth/logout` to blacklist tokens on the backend, then clears local session.
    public static func logout() async {
        let ud = sharedDefaults()
        let base = effectiveBackendBaseURL()
        if let token = storedAccessToken(), !token.isEmpty,
           let url = URL(string: base + "/api/auth/logout") {
            struct Body: Encodable { let accessToken: String; let refreshToken: String? }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.httpBody = try? JSONEncoder().encode(
                Body(accessToken: token, refreshToken: storedRefreshToken())
            )
            _ = try? await URLSession.shared.data(for: req)
        }
        // AppState.logout already flips isAuthenticated - avoid a second sessionCleared round-trip.
        clearSession(notify: false)
    }

    // MARK: - Libre history (dashboard chart)

    public struct LibreGlucoseHistoryData: Decodable {
        public let data: [LibreHistoryPoint]
    }

    public struct LibreHistoryPoint: Decodable {
        public let timestamp: Date?
        public let value: Double?
        public let trend: Int?
        public let trendArrow: String?
        public let status: String?
        public let unit: String?

        enum CodingKeys: String, CodingKey {
            case timestamp, value, trend, trendArrow, status, unit
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            value = try Self.decodeDouble(c, forKey: .value)
            trend = try c.decodeIfPresent(Int.self, forKey: .trend)
            trendArrow = try c.decodeIfPresent(String.self, forKey: .trendArrow)
            status = try c.decodeIfPresent(String.self, forKey: .status)
            unit = try c.decodeIfPresent(String.self, forKey: .unit)
            timestamp = Self.decodeDate(c)
        }

        private static func decodeDouble(_ c: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) throws -> Double? {
            if let x = try? c.decodeIfPresent(Double.self, forKey: key) { return x }
            if let x = try? c.decodeIfPresent(Int.self, forKey: key) { return Double(x) }
            return nil
        }

        private static func decodeDate(_ c: KeyedDecodingContainer<CodingKeys>) -> Date? {
            if let ms = try? c.decodeIfPresent(Int64.self, forKey: .timestamp) {
                return Date(timeIntervalSince1970: Double(ms) / 1000.0)
            }
            if let ms = try? c.decodeIfPresent(Double.self, forKey: .timestamp) {
                return Date(timeIntervalSince1970: ms / 1000.0)
            }
            if let s = try? c.decodeIfPresent(String.self, forKey: .timestamp), !s.isEmpty {
                let f1 = ISO8601DateFormatter()
                f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let d = f1.date(from: s) { return d }
                let f2 = ISO8601DateFormatter()
                f2.formatOptions = [.withInternetDateTime]
                if let d = f2.date(from: s) { return d }
                // Spring jackson.date-format: "yyyy-MM-dd'T'HH:mm:ss" - no timezone suffix.
                // History timestamps are UTC sensor readings; interpret as UTC, not local time.
                let df = DateFormatter()
                df.locale = Locale(identifier: "en_US_POSIX")
                df.timeZone = TimeZone(identifier: "UTC")
                for format in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss"] {
                    df.dateFormat = format
                    if let d = df.date(from: s) { return d }
                }
            }
            return nil
        }

        public func toLibreGlucoseCurrent() -> LibreGlucoseCurrent {
            LibreGlucoseCurrent(
                timestamp: timestamp,
                value: value,
                trend: trend,
                trendArrow: trendArrow,
                status: status,
                unit: unit
            )
        }
    }

    // MARK: - Sensor info

    public struct LibreSensorInfo: Decodable {
        public let serialNumber: String?
        public let sensorModel: String?
        public let activationDate: Date?
        public let expiryDate: Date?
        /// Days the sensor has been active (0-based).
        public let sensorAgeDays: Int?
        /// Maximum sensor lifetime in days (14 for Libre 1/2/3).
        public let sensorMaxDays: Int?
        /// "active" | "warmup" | "expired" | "unknown"
        public let status: String?
        /// Remaining days (negative = overdue).
        public let daysRemaining: Int?
    }

    /// Fetch active sensor information for the stored patient ID.
    /// Returns `nil` on any error (sensor info is non-critical).
    public static func fetchSensorInfo() async -> LibreSensorInfo? {
        guard let pid = sharedDefaults().string(forKey: StorageKey.patientId)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !pid.isEmpty else { return nil }
        do {
            return try await _fetchSensorInfo(patientId: pid)
        } catch APIError.httpStatus(401, _) {
            try? await refreshToken()
            return try? await _fetchSensorInfo(patientId: pid)
        } catch {
            return nil
        }
    }

    private static func _fetchSensorInfo(patientId: String) async throws -> LibreSensorInfo {
        let base = effectiveBackendBaseURL()
        guard let token = storedAccessToken(), !token.isEmpty else {
            throw APIError.missingToken
        }
        guard let url = URL(string: base + "/api/libre/connections/\(patientId)/sensor") else {
            throw APIError.invalidURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.httpStatus(-1, nil) }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw APIError.httpStatus(http.statusCode, String(data: data, encoding: .utf8))
        }
        return try jsonDecoder().decode(LibreSensorInfo.self, from: data)
    }

    /// Historical Libre points for charts (`GET .../history`).
    public static func fetchLibreGlucoseHistory(days: Int = 1) async throws -> [LibreHistoryPoint] {
        do {
            return try await _fetchLibreGlucoseHistory(days: days)
        } catch APIError.httpStatus(401, _) {
            try await refreshToken()
            return try await _fetchLibreGlucoseHistory(days: days)
        }
    }

    private static func _fetchLibreGlucoseHistory(days: Int) async throws -> [LibreHistoryPoint] {
        let ud = sharedDefaults()
        let base = effectiveBackendBaseURL()
        guard let pid = ud.string(forKey: StorageKey.patientId)?.trimmingCharacters(in: .whitespacesAndNewlines), !pid.isEmpty else {
            throw APIError.missingPatientId
        }
        guard let token = storedAccessToken(), !token.isEmpty else { throw APIError.missingToken }

        guard let url = URL(string: base + "/api/libre/connections/\(pid)/history?days=\(days)") else { throw APIError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.httpStatus(-1, nil) }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw APIError.httpStatus(http.statusCode, String(data: data, encoding: .utf8))
        }
        let decoded = try jsonDecoder().decode(LibreGlucoseHistoryData.self, from: data)
        return decoded.data
    }
}
