import Foundation

/// JSON-only, one bounded response; NOT a full Streamable HTTP/SSE/session client.
final class MCPPreparedOperation: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let chunks: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var data = Data()
    // The exact credential used for this request stays transport-owned until the
    // decoded, assembled outbound text is checked. Never re-read the provider.
    private var activeCredential: String?
    private var started = false
    private var resumes = 0
    var resumeCalls: Int { lock.withLock { resumes } }
    private var finished = false
    private let notification: Bool
    private let limit: Int
    private let vmOwner: BusinessVMConnection?
    init(connection: HostMCPConnection, payload: ModelJSON, limit: Int, vmOwner: BusinessVMConnection? = nil) throws {
        self.vmOwner = vmOwner
        if let vmOwner { guard vmOwner.service == .mcp else { throw HostMCPGatewayError.invalidHandle } }
        self.limit = min(limit, 65536)
        notification = payload["method"] == .string("notifications/initialized")
        let pair = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        chunks = pair.stream; continuation = pair.continuation
        let bytes = try MCPProtocol.canonical(payload)
        guard bytes.count <= self.limit else { throw HostMCPGatewayError.denied }
        let credential = try connection.provider.credential(for: connection.binding)
        guard credential.binding == connection.binding, !credential.bearer.isEmpty, credential.bearer.utf8.count <= 4096,
              credential.bearer.utf8.allSatisfy({ (33...126).contains($0) }) else { throw HostMCPGatewayError.invalidConnection }
        activeCredential = credential.bearer
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil; configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 3; configuration.timeoutIntervalForResource = 5
        configuration.httpMaximumConnectionsPerHost = 2; configuration.waitsForConnectivity = false
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session
        var request = URLRequest(url: connection.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
        request.httpMethod = "POST"; request.httpBody = bytes
        request.setValue("Bearer " + credential.bearer, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(connection.profile == .fixture ? "application/json" : "application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(connection.profile.version, forHTTPHeaderField: "MCP-Protocol-Version")
        if connection.profile == .claudeRepository {
            request.setValue(payload["method"]?.string, forHTTPHeaderField: "Mcp-Method")
            request.setValue(payload["params"]?["name"]?.string, forHTTPHeaderField: "Mcp-Name")
        }
        task = session.dataTask(with: request) // suspended; no HTTP start here
    }
    func acquireForStart() { lock.lock(); vmOwner?.acquireNativeStart() }
    func releaseForStart() { vmOwner?.releaseNativeEffect(); lock.unlock() }
    func validateVMOwner(scope: RunEffectScope, lifecycle: RunLifecycle) throws {
        guard let vmOwner else { return }
        guard vmOwner.lifecycle === lifecycle, vmOwner.epoch == scope.generation,
              vmOwner.service == .mcp, scope.connectionID != nil else { throw AuthorizationError.wrongRun }
    }
    func startLocked() throws {
        guard !started, !finished, let task else { throw HostMCPGatewayError.notStarted }
        try vmOwner?.validateNativeEffectLocked()
        started = true; task.resume(); resumes += 1
    }
    func start() throws {
        guard vmOwner == nil else { throw HostMCPGatewayError.denied }
        acquireForStart(); defer { releaseForStart() }; try startLocked()
    }
    func validateOutboundText(_ text: String) throws {
        try lock.withLock {
            defer { activeCredential = nil }
            guard let activeCredential, !text.contains(activeCredential) else { throw HostMCPGatewayError.invalidResponse }
        }
    }
    /// Validate every returned JSON field before a native MCP response exists.
    /// Includes raw canonical spelling and decoded scalar/key representations;
    /// this remains exact matching, not arbitrary encoded-secret detection.
    func validateOutboundJSON(_ value: ModelJSON, joinedText: String) throws {
        try lock.withLock {
            defer { activeCredential = nil }
            guard let secret = activeCredential else { throw HostMCPGatewayError.invalidResponse }
            func reject(_ text: String) throws {
                guard !text.contains(secret) else { throw HostMCPGatewayError.invalidResponse }
            }
            func visit(_ item: ModelJSON) throws {
                switch item {
                case .object(let fields): for (key, child) in fields { try reject(key); try visit(child) }
                case .array(let values): for child in values { try visit(child) }
                case .string(let text): try reject(text)
                case .integer(let number): try reject(String(number))
                case .bool(let value): try reject(value ? "true" : "false")
                case .null: try reject("null")
                }
            }
            try reject(String(decoding: MCPProtocol.canonical(value), as: UTF8.self))
            try reject(joinedText); try visit(value)
        }
    }
    func cancel() {
        lock.withLock { activeCredential = nil }
        finish(.failure(HostMCPGatewayError.outcomeUnknown))
    }
    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true; let session = self.session; self.session = nil; let task = self.task; self.task = nil
        data = Data()
        if case .failure = result { activeCredential = nil }
        lock.unlock()
        switch result {
        case .success(let data): continuation.yield(data); continuation.finish()
        case .failure(let error): continuation.finish(throwing: error)
        }
        task?.cancel(); session?.invalidateAndCancel()
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == (notification ? 202 : 200),
              http.value(forHTTPHeaderField: "Mcp-Session-Id") == nil,
              notification || http.mimeType == "application/json",
              response.expectedContentLength <= Int64(limit) else {
            completionHandler(.cancel); finish(.failure(HostMCPGatewayError.invalidResponse)); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        let exceeded = lock.withLock { () -> Bool in
            guard !finished else { return false }
            guard data.count + chunk.count <= limit else { return true }
            data.append(chunk); return false
        }
        if exceeded { finish(.failure(HostMCPGatewayError.invalidResponse)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil { finish(.failure(HostMCPGatewayError.outcomeUnknown)) }
        else { finish(.success(lock.withLock { data })) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil); finish(.failure(HostMCPGatewayError.invalidResponse))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) { completionHandler(.cancelAuthenticationChallenge, nil) }
}
