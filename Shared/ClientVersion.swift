import Foundation

/// Client identity for API calls. Keep `semanticVersionFallback` in sync with
/// `glucose-monitor-fe/src/config/version.ts` (`VERSION_CONFIG.version`) and `app.version` in the backend.
public enum ClientVersion {
    public static let semanticVersionFallback = "1.0.0"
    public static let apiVersion = "v1"

    /// Normalized semver for compatibility checks (matches backend lists like `1.0.0`).
    public static func resolvedSemanticVersion() -> String {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.isEmpty { return semanticVersionFallback }
        let parts = raw.split(separator: ".").map(String.init)
        if parts.count == 1 { return "\(parts[0]).0.0" }
        if parts.count == 2 { return "\(parts[0]).\(parts[1]).0" }
        return raw
    }

    public static var clientPlatform: String {
        #if os(watchOS)
        return "watchos"
        #else
        return "ios"
        #endif
    }
}
