import XCTest
@testable import GlucoseMonitor

/// The phone hands the Apple Watch its own session and tells it about sign-out and unit changes.
@MainActor
final class WatchSessionBridgeTests: XCTestCase {

    private final class FakeTransport: WatchTransport {
        var canReachWatchApp = true
        var transferred: [[String: Any]] = []
        var contexts: [[String: Any]] = []
        func transferUserInfo(_ info: [String: Any]) { transferred.append(info) }
        func updateApplicationContext(_ ctx: [String: Any]) throws { contexts.append(ctx) }
    }

    private struct Boom: Error {}

    private var transport: FakeTransport!
    private var issued = 0
    private var issueResult: Result<(String, String), Error> = .success(("a", "r"))
    private var signedIn = true

    override func setUp() {
        super.setUp()
        transport = FakeTransport()
        issued = 0
        issueResult = .success(("a", "r"))
        signedIn = true
    }

    private func bridge() -> WatchSessionBridge {
        WatchSessionBridge(
            transport: transport,
            issue: { [unowned self] in
                self.issued += 1
                return try self.issueResult.get()
            },
            context: { (backendURL: "https://api.example", displayUnit: "mmol/L", dataSource: "libre") },
            isSignedIn: { [unowned self] in self.signedIn }
        )
    }

    func testPushSessionTransfersPayload() async {
        await bridge().pushSession()

        XCTAssertEqual(transport.transferred.count, 1)
        XCTAssertEqual(WatchHandoff.Message.decode(transport.transferred[0]),
                       .session(accessToken: "a", refreshToken: "r", backendURL: "https://api.example",
                                displayUnit: "mmol/L", dataSource: "libre"))
    }

    func testNoWatchAppNoIssue() async {
        transport.canReachWatchApp = false

        await bridge().pushSession()

        XCTAssertEqual(issued, 0, "no device session is minted for a watch that can't receive it")
        XCTAssertTrue(transport.transferred.isEmpty)
    }

    func testIssueFailureTransfersNothing() async {
        issueResult = .failure(Boom())

        await bridge().pushSession()

        XCTAssertEqual(issued, 1)
        XCTAssertTrue(transport.transferred.isEmpty)
    }

    func testSignOutIsQueuedNotMessaged() {
        bridge().signedOut()

        XCTAssertEqual(transport.transferred.count, 1)
        XCTAssertEqual(WatchHandoff.Message.decode(transport.transferred[0]), .signedOut)
    }

    func testSignOutWithoutWatchAppSendsNothing() {
        transport.canReachWatchApp = false

        bridge().signedOut()

        XCTAssertTrue(transport.transferred.isEmpty)
    }

    func testUnitChangeUpdatesContext() {
        bridge().displayUnitChanged("mg/dL")

        XCTAssertEqual(transport.contexts.count, 1)
        XCTAssertEqual(WatchHandoff.Message.decode(transport.contexts[0]), .displayUnit("mg/dL"))
    }

    func testRequestSessionMessageTriggersPush() async {
        let b = bridge()

        await b.handle(message: WatchHandoff.Message.requestSession.encode())
        XCTAssertEqual(transport.transferred.count, 1)

        signedIn = false
        await b.handle(message: WatchHandoff.Message.requestSession.encode())
        XCTAssertEqual(transport.transferred.count, 1, "a signed-out phone has no session to hand over")
        XCTAssertEqual(issued, 1)
    }
}
