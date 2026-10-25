import Foundation

/// A real URLSession producer fixture that keeps the upstream response open.
/// This is not an external provider or a TCP-upstream interoperability claim.
final class NativeHeldState: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: (() -> Void)?
    private var arrivals = 0
    func install(_ value: @escaping () -> Void) { lock.withLock { arrivals += 1; tail = value } }
    func finish() { let value = lock.withLock { let value = tail; tail = nil; return value }; value?() }
    func cancel() { lock.withLock { tail = nil } }
    var count: Int { lock.withLock { arrivals } }
}
final class NativeHeldProtocol: URLProtocol {
    static let state = NativeHeldState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let events = try nativeStreamFixture().map { Data(("data: " + $0.1 + "\n\n").utf8) }
            Self.state.install { [self] in
                for event in events.dropFirst(3) { client?.urlProtocol(self, didLoad: event) }
                client?.urlProtocolDidFinishLoading(self)
            }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
            for event in events.prefix(3) { client?.urlProtocol(self, didLoad: event) }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { Self.state.cancel() }
}
