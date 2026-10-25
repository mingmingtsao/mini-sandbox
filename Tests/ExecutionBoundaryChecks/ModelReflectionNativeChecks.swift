import Darwin
import Foundation
import SandboxContracts

@testable import SandboxHost

/// Test-only fixed loopback forwarding; production endpoint selection is unchanged.
/// The same active synthetic header is consumed by the real HTTP fixture. No
/// arbitrary caller URL, personal Keychain item or external provider is involved.
private final class ReflectionRelayConfiguration: @unchecked Sendable {
    let lock = NSLock()
    private var value: Int = 0
    func install(_ port: Int) { lock.withLock { value = port } }
    var port: Int { lock.withLock { value } }
}
private final class ReflectionLoopbackProtocol: URLProtocol {
    static let settings = ReflectionRelayConfiguration()
    private let ownerLock = NSLock()
    private var forwarding: URLSession?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard request.url?.absoluteString == "https://api.deepseek.com/anthropic/v1/messages",
                request.httpMethod == "POST", (1...65535).contains(Self.settings.port)
            else { throw Failure(message: "fixed relay input") }
            var forwarded = request
            forwarded.url = URL(string: "http://127.0.0.1:\(Self.settings.port)/reflection")!
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = []
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            configuration.connectionProxyDictionary = [:]
            configuration.timeoutIntervalForRequest = 5
            configuration.timeoutIntervalForResource = 10
            let session = URLSession(
                configuration: configuration, delegate: ReflectionRelayDelegate(self), delegateQueue: nil)
            ownerLock.withLock { forwarding = session }
            session.dataTask(with: forwarded).resume()
        } catch {
            client?.urlProtocol(self, didFailWithError: ModelTransportError.invalidRequest("fixed fixture relay"))
        }
    }
    override func stopLoading() {
        let session = ownerLock.withLock {
            let value = forwarding
            forwarding = nil
            return value
        }
        session?.invalidateAndCancel()
    }
}
private final class ReflectionRelayDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let owner: ReflectionLoopbackProtocol
    init(_ owner: ReflectionLoopbackProtocol) { self.owner = owner }
    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        owner.client?.urlProtocol(owner, didReceive: response, cacheStoragePolicy: .notAllowed)
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        owner.client?.urlProtocol(owner, didLoad: data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil {
            owner.client?.urlProtocol(owner, didFailWithError: ModelTransportError.network)
        } else {
            owner.client?.urlProtocolDidFinishLoading(owner)
        }
        session.finishTasksAndInvalidate()
    }
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
        owner.client?.urlProtocol(owner, didFailWithError: ModelTransportError.redirectRejected)
        session.invalidateAndCancel()
    }
}
private final class NativeReflectionCredential: ModelCredentialProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let value = "sk-native-canary-" + UUID().uuidString
    func credential(for model: FixedModel) throws -> String {
        lock.withLock { count += 1 }
        return value
    }
    var reads: Int { lock.withLock { count } }
}
private final class NativeReflectionResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    func finish(_ result: Result<Void, Error>) { lock.withLock { self.result = result } }
    var value: Result<Void, Error>? { lock.withLock { result } }
}

func nativeModelReflectionLoopback() async throws {
    guard let input = readLine(), input.utf8.count < 128,
        let data = input.data(using: .utf8),
        let fields = try JSONSerialization.jsonObject(with: data) as? [String: Int],
        fields.count == 1, let port = fields["port"], (1...65535).contains(port)
    else { throw Failure(message: "fixture port") }
    ReflectionLoopbackProtocol.settings.install(port)
    let modes = [
        "plain", "escaped", "adjacent", "tool", "tool-escaped", "sse-split", "sse-escaped", "sse-tool-escaped", "error",
        "ordinary", "ordinary-sse", "ordinary-tool", "prefix-sse",
    ]
    for mode in modes { try await nativeReflectionCase(mode) }
}

private func nativeReflectionCase(_ mode: String) async throws {
    let streaming = mode.contains("sse")
    let positive = mode.hasPrefix("ordinary") || mode == "prefix-sse"
    let credential = NativeReflectionCredential()
    let audit = Audit()
    let pair = try NativeSocketPair()
    let id = UUID()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ReflectionLoopbackProtocol.self]
    let connection = HostModelConnection(
        connectionID: id, accountID: UUID(), accountBindingVersion: 1,
        routeVersion: 1, model: .deepSeekFlash, protocol: .anthropic, credentialProvider: credential,
        configuration: configuration)
    let gateway = try HostModelGateway(connections: [connection], auditSink: audit)
    let scope = try ResourceScope(
        service: "model", resource: "deepseek-flash", operation: streaming ? "stream" : "complete")
    let now = Date()
    let grant = try RunGrant(
        runID: UUID(), epoch: 1, createdAt: now.addingTimeInterval(-1), expiresAt: now.addingTimeInterval(60),
        workloadImageDigest: String(repeating: "a", count: 64), agentAdapterVersion: "native-reflection-loopback",
        workspaceSnapshotID: UUID(), policyDigest: String(repeating: "b", count: 64), approvalSnapshotID: UUID(),
        connections: [ConnectionGrant(connectionID: id, accountBindingVersion: 1, routeVersion: 1, scopes: [scope])],
        explicitDenies: [],
        resourceLimits: ResourceLimits(
            cpuCount: 1, memoryBytes: 1024 * 1024, diskBytes: 1024 * 1024, messageBytes: 65536, concurrentRequests: 1))
    let handle = try await gateway.install(grant: grant)
    let body = try JSONSerialization.data(
        withJSONObject: [
            "model": "deepseek-flash", "max_tokens": 32, "stream": streaming,
            "messages": [["role": "user", "content": mode]],
        ], options: [.sortedKeys])
    let proposal = try await gateway.proposeNative(handle: handle, connectionID: id, body: body, streaming: streaming)
    let approval = try await gateway.hostApprove(handle: handle, proposal: proposal)
    let output = try await gateway.makeNativeOutput(
        handle: handle, approval: approval, takingAcceptedSocket: pair.takeWriter())
    let result = NativeReflectionResult()
    let task = Task {
        do {
            try await gateway.execute(handle: handle, approval: approval, output: output)
            result.finish(.success(()))
        } catch { result.finish(.failure(error)) }
    }
    var bytes = Data()
    // Pump the actual consumer while the upstream is still producing; otherwise
    // cancellation could erase a leaky queue before this test observed its bytes.
    for _ in 0..<10_000 {
        do { _ = try output.acceptNext() } catch is CancellationError {} catch is AuthorizationError {}
        bytes.append(try pair.readAvailable())
        if result.value != nil && output.nativeProgress!.closed { break }
        try await Task.sleep(for: .milliseconds(1))
    }
    task.cancel()
    await task.value
    bytes.append(try pair.readAvailable())
    defer { output.cancel() }
    guard let outcome = result.value else { throw Failure(message: "native-reflection completion timeout") }
    let succeeded: Bool
    switch outcome {
    case .success: succeeded = true
    case .failure(let error):
        try check(error as? HostModelGatewayError == .outcomeUnknown, "native-reflection rejection outcome")
        succeeded = false
    }
    let text = String(decoding: bytes, as: UTF8.self)
    let escaped = credential.value.utf16.map { String(format: "\\u%04x", $0) }.joined()
    try check(!text.contains(credential.value) && !text.contains(escaped), "native-reflection secret in actual socket")
    // Reconstruct semantic text and tool fragments from actual emitted HTTP/SSE,
    // independently of the host's in-memory completion or summary counters.
    let payload = text.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
    var textValues = ""
    var toolValues = ""
    if streaming {
        for line in payload.components(separatedBy: "\n") where line.hasPrefix("data: ") {
            let value = try JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as! [String: Any]
            if let block = value["content_block"] as? [String: Any], let value = block["text"] as? String {
                textValues += value
            }
            if let delta = value["delta"] as? [String: Any] {
                if let value = delta["text"] as? String { textValues += value }
                if let value = delta["partial_json"] as? String { toolValues += value }
            }
        }
    }
    try check(
        !textValues.contains(credential.value) && !toolValues.contains(credential.value)
            && !toolValues.contains(escaped), "native-reflection reconstructed leak")
    try check(
        succeeded == positive && output.nativeProgress!.acceptedFinals == (positive ? 1 : 0),
        "native-reflection final result")
    let resumes = try await gateway.resumedTaskCount(handle: handle)
    try check(credential.reads == 1 && resumes == 1, "native-reflection read/resume count")
    try check(output.nativeProgress!.committedBytes == bytes.count, "native-reflection peer byte accounting")
    let expected: DispatchOutcome = positive ? .completed : .unknown
    try check(
        audit.completions.count == 1 && audit.completions[0].outcome == expected, "native-reflection audit outcome")
    if positive {
        try check(text.contains("ordinary"), "native-reflection positive payload missing")
        if mode == "prefix-sse" {
            try check(
                textValues == "ordinary " + credential.value.prefix(12), "native-reflection harmless suffix omitted")
        }
    } else if !streaming {
        try check(bytes.isEmpty, "native-reflection JSON/error output released")
    }
    print(
        "PASS native-reflection \(mode) peer_bytes=\(bytes.count) secret_occurrences=0 reads=1 resumes=1 audit=\(positive ? "completed" : "unknown")"
    )
}
