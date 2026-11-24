import Foundation

/// Messages between the phone app and the Apple Watch app over WatchConnectivity, as plist dictionaries.
enum WatchHandoff {

    static let version = 1

    enum Message: Equatable {
        /// Phone → watch: the watch's own session (from `POST /api/auth/device-session`) and settings.
        case session(accessToken: String, refreshToken: String, backendURL: String, displayUnit: String, dataSource: String)
        /// Phone → watch: the user signed out; drop tokens and cached data.
        case signedOut
        /// Phone → watch: the display unit changed.
        case displayUnit(String)
        /// Watch → phone: the watch has no working session.
        case requestSession

        func encode() -> [String: Any] {
            var d: [String: Any] = ["v": WatchHandoff.version]
            switch self {
            case let .session(access, refresh, url, unit, source):
                d["kind"] = "session"
                d["accessToken"] = access
                d["refreshToken"] = refresh
                d["backendURL"] = url
                d["displayUnit"] = unit
                d["dataSource"] = source
            case .signedOut:
                d["kind"] = "signedOut"
            case let .displayUnit(unit):
                d["kind"] = "displayUnit"
                d["displayUnit"] = unit
            case .requestSession:
                d["kind"] = "requestSession"
            }
            return d
        }

        /// Nil for an unknown kind or a message missing a field.
        static func decode(_ d: [String: Any]) -> Message? {
            switch d["kind"] as? String {
            case "session":
                guard let access = d["accessToken"] as? String, let refresh = d["refreshToken"] as? String,
                      let url = d["backendURL"] as? String, let unit = d["displayUnit"] as? String,
                      let source = d["dataSource"] as? String else { return nil }
                return .session(accessToken: access, refreshToken: refresh, backendURL: url,
                                displayUnit: unit, dataSource: source)
            case "signedOut":
                return .signedOut
            case "displayUnit":
                guard let unit = d["displayUnit"] as? String else { return nil }
                return .displayUnit(unit)
            case "requestSession":
                return .requestSession
            default:
                return nil
            }
        }
    }
}
