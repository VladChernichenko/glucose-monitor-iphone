import Foundation

/// URLProtocol that causes all requests to fail with a network error.
/// Used in unit tests to simulate API failures without live networking.
final class FailingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let error = URLError(.notConnectedToInternet)
        client?.urlProtocol(self, didFailWithError: error)
    }
    override func stopLoading() {}
}

/// Programmable URLProtocol stub. Each path can be assigned a sequence of canned
/// responses; successive requests to the same path consume the queue in order so a
/// single test can model "first call fails, second call succeeds".
///
/// Always call `StubURLProtocol.reset()` from your test's tearDown - the registry is
/// process-global because URLProtocol registration is global.
final class StubURLProtocol: URLProtocol {

    struct Response {
        let status: Int
        let body: Data
        let headers: [String: String]

        init(status: Int, body: Data = Data(), headers: [String: String] = ["Content-Type": "application/json"]) {
            self.status = status
            self.body = body
            self.headers = headers
        }

        /// Convenience for `{ "error": "...", "message": "..." }` Spring-style 4xx/5xx bodies.
        static func jsonError(status: Int, message: String) -> Response {
            let envelope = "{\"status\":\(status),\"error\":\"Error\",\"message\":\"\(message)\",\"path\":\"/\",\"timestamp\":\"\"}"
            return Response(status: status, body: Data(envelope.utf8))
        }
    }

    private static let lock = NSLock()
    private static var queues: [String: [Response]] = [:]
    private static var requestLog: [(path: String, hits: Int)] = []
    private static var hitCounts: [String: Int] = [:]

    /// Push one or more canned responses for `path` (matched by URL.path suffix). Calls dequeue in order.
    static func enqueue(path: String, _ responses: Response...) {
        lock.lock(); defer { lock.unlock() }
        queues[path, default: []].append(contentsOf: responses)
    }

    /// How many requests this path actually received during the test.
    static func hits(for path: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return hitCounts[path] ?? 0
    }

    /// Clear all queued responses and counters. Always call from tearDown.
    static func reset() {
        lock.lock(); defer { lock.unlock() }
        queues.removeAll()
        hitCounts.removeAll()
        requestLog.removeAll()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let response: Response = StubURLProtocol.lock.withLock {
            StubURLProtocol.hitCounts[path, default: 0] += 1
            if StubURLProtocol.queues[path]?.isEmpty == false {
                return StubURLProtocol.queues[path]!.removeFirst()
            }
            // Default: 404 to make missing stubs loud.
            return Response(status: 404, body: Data("{\"error\":\"no stub for \(path)\"}".utf8))
        }

        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: response.headers
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
