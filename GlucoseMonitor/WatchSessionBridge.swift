import Foundation
import WatchConnectivity

/// The slice of `WCSession` the bridge uses, so tests can stand in for the watch.
protocol WatchTransport: AnyObject {
    /// Activated, paired, and the watch app is installed.
    var canReachWatchApp: Bool { get }
    /// Queued, delivered even when the watch is asleep.
    func transferUserInfo(_ info: [String: Any])
    func updateApplicationContext(_ ctx: [String: Any]) throws
}

final class WCSessionTransport: WatchTransport {
    var canReachWatchApp: Bool {
        guard WCSession.isSupported() else { return false }
        let s = WCSession.default
        return s.activationState == .activated && s.isPaired && s.isWatchAppInstalled
    }

    func transferUserInfo(_ info: [String: Any]) { WCSession.default.transferUserInfo(info) }

    func updateApplicationContext(_ ctx: [String: Any]) throws { try WCSession.default.updateApplicationContext(ctx) }
}

/// Gives the Apple Watch its own session (a separate token chain, so phone and watch never spend each
/// other's single-use refresh tokens) and keeps it in step with sign-out and the display unit.
final class WatchSessionBridge: NSObject, WCSessionDelegate {

    static let shared = WatchSessionBridge(
        transport: WCSessionTransport(),
        issue: { try await BackendAPI.issueDeviceSession() },
        context: {
            let ud = GlucoseMonitorAPI.sharedDefaults()
            return (backendURL: GlucoseMonitorAPI.effectiveBackendBaseURL(),
                    displayUnit: ud.string(forKey: GlucoseMonitorAPI.StorageKey.glucoseDisplayUnit) ?? "mmol/L",
                    dataSource: ud.string(forKey: GlucoseMonitorAPI.StorageKey.dataSource) ?? "libre")
        },
        isSignedIn: { !(GlucoseMonitorAPI.storedAccessToken()?.isEmpty ?? true) }
    )

    private let transport: WatchTransport
    private let issue: () async throws -> (String, String)
    private let context: () -> (backendURL: String, displayUnit: String, dataSource: String)
    private let isSignedIn: () -> Bool

    init(transport: WatchTransport,
         issue: @escaping () async throws -> (String, String),
         context: @escaping () -> (backendURL: String, displayUnit: String, dataSource: String),
         isSignedIn: @escaping () -> Bool) {
        self.transport = transport
        self.issue = issue
        self.context = context
        self.isSignedIn = isSignedIn
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Mints a device session and queues it for the watch. Nothing is minted for a watch that can't receive it.
    func pushSession() async {
        guard transport.canReachWatchApp else { return }
        do {
            let (access, refresh) = try await issue()
            let c = context()
            transport.transferUserInfo(WatchHandoff.Message.session(
                accessToken: access, refreshToken: refresh, backendURL: c.backendURL,
                displayUnit: c.displayUnit, dataSource: c.dataSource).encode())
        } catch {
            // The watch asks again (it sends requestSession whenever it has no session).
        }
    }

    /// Queued, so a sleeping watch still drops its session when it wakes.
    func signedOut() {
        guard transport.canReachWatchApp else { return }
        transport.transferUserInfo(WatchHandoff.Message.signedOut.encode())
    }

    func displayUnitChanged(_ unit: String) {
        guard transport.canReachWatchApp else { return }
        try? transport.updateApplicationContext(WatchHandoff.Message.displayUnit(unit).encode())
    }

    /// A message from the watch (live message or queued user info).
    func handle(message: [String: Any]) async {
        guard WatchHandoff.Message.decode(message) == .requestSession, isSignedIn() else { return }
        await pushSession()
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {}

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // The user switched watches: activate again for the new one.
        WCSession.default.activate()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { await handle(message: message) }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        Task {
            await handle(message: message)
            replyHandler([:])
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { await handle(message: userInfo) }
    }
}

extension BackendAPI {
    /// `POST /api/auth/device-session`: a second, independent token pair for the Apple Watch.
    static func issueDeviceSession() async throws -> (String, String) {
        try await performWithRefresh {
            let req = try authorizedRequest(path: "/api/auth/device-session", method: "POST")
            let (data, resp) = try await URLSession.shared.data(for: req)
            try checkStatus(resp, data: data)
            let body = try JSONDecoder().decode(GlucoseMonitorAPI.AuthResponseBody.self, from: data)
            guard let refresh = body.refreshToken, !refresh.isEmpty else {
                throw GlucoseMonitorAPI.APIError.missingToken
            }
            return (body.accessToken, refresh)
        }
    }
}
