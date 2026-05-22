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
