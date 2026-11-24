import Foundation
import WatchConnectivity

/// The watch side of the handoff: stores the session the phone sends, drops it on sign-out, and asks the
/// phone for a new one whenever the watch has none (or its refresh token was rejected).
final class WatchSessionReceiver: NSObject, WCSessionDelegate, ObservableObject {

    static let shared = WatchSessionReceiver()

    @Published private(set) var isSignedIn = WatchSessionReceiver.hasStoredSession()
    /// Bumped when a new session or display unit arrives, so the screen refetches and redraws.
    @Published private(set) var generation = 0

    private var clearedObserver: NSObjectProtocol?

    override init() {
        super.init()
        clearedObserver = NotificationCenter.default.addObserver(
            forName: GlucoseMonitorAPI.sessionClearedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.sessionLost()
        }
    }

    deinit {
        if let clearedObserver { NotificationCenter.default.removeObserver(clearedObserver) }
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Asks the phone for a session: a live message when the phone is reachable (it wakes the phone app),
    /// otherwise one queued request (never several: each would mint its own session).
    func requestSessionIfNeeded() {
        guard !isSignedIn, WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        let message = WatchHandoff.Message.requestSession.encode()
        if session.isReachable {
            session.sendMessage(message, replyHandler: nil) { _ in
                Self.queueOnce(message)
            }
        } else {
            Self.queueOnce(message)
        }
    }

    private static func queueOnce(_ message: [String: Any]) {
        let pending = WCSession.default.outstandingUserInfoTransfers
            .contains { WatchHandoff.Message.decode($0.userInfo) == .requestSession }
        if !pending { WCSession.default.transferUserInfo(message) }
    }

    private static func hasStoredSession() -> Bool {
        !(GlucoseMonitorAPI.storedRefreshToken()?.isEmpty ?? true)
    }

    private func apply(_ payload: [String: Any]) {
        guard let message = WatchHandoff.Message.decode(payload) else { return }
        DispatchQueue.main.async { [self] in
            let ud = GlucoseMonitorAPI.sharedDefaults()
            switch message {
            case let .session(access, refresh, url, unit, source):
                GlucoseMonitorAPI.storeSessionTokens(accessToken: access, refreshToken: refresh)
                GlucoseMonitorAPI.storeBackendBaseURL(url)
                ud.set(unit, forKey: GlucoseMonitorAPI.StorageKey.glucoseDisplayUnit)
                ud.set(source, forKey: GlucoseMonitorAPI.StorageKey.dataSource)
                isSignedIn = true
                generation += 1
            case .signedOut:
                // notify: false - a sign-out must not turn into a request for a new session.
                GlucoseMonitorAPI.clearSession(notify: false)
                GlanceStore.clear()
                isSignedIn = false
                generation += 1
            case let .displayUnit(unit):
                ud.set(unit, forKey: GlucoseMonitorAPI.StorageKey.glucoseDisplayUnit)
                generation += 1
            case .requestSession:
                break
            }
        }
    }

    /// The refresh token was rejected: drop what we have and ask the phone again.
    private func sessionLost() {
        GlanceStore.clear()
        isSignedIn = false
        generation += 1
        requestSessionIfNeeded()
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        guard activationState == .activated else { return }
        if !session.receivedApplicationContext.isEmpty { apply(session.receivedApplicationContext) }
        DispatchQueue.main.async { self.requestSessionIfNeeded() }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) { apply(userInfo) }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        apply(applicationContext)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) { apply(message) }
}
