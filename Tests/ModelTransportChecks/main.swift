import Foundation
import Security
import SandboxHost

private enum CheckFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String { switch self { case .failed(let message): return "check failed: " + message } }
}

private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw CheckFailure.failed(message) }
}

private final class InMemoryCredentialProvider: ModelCredentialProvider, @unchecked Sendable {
    let value: String
    init(_ value: String) { self.value = value }
    package func credential(for model: FixedModel) throws -> String { value }
}

private struct FixtureResponse {
    let status: Int
    let headers: [String: String]
    let bodyChunks: [Data]
    let redirect: URL?
    let finish: Bool
    let delayBeforeFinish: UInt64

    init(status: Int = 200, headers: [String: String] = ["Content-Type": "application/json"], bodyChunks: [Data] = [], redirect: URL? = nil, finish: Bool = true, delayBeforeFinish: UInt64 = 0) {
        self.status = status
        self.headers = headers
        self.bodyChunks = bodyChunks
        self.redirect = redirect
        self.finish = finish
        self.delayBeforeFinish = delayBeforeFinish
    }
}

private final class FixtureState: @unchecked Sendable {
    let lock = NSLock()
    var handler: ((URLRequest) -> FixtureResponse?)?
    var requests: [URLRequest] = []
    var stopCount = 0
}

private final class FixtureURLProtocol: URLProtocol {
    static let state = FixtureState()

    static func install(_ handler: @escaping (URLRequest) -> FixtureResponse?) {
        state.lock.lock(); defer { state.lock.unlock() }
        state.handler = handler
        state.requests = []
        state.stopCount = 0
    }

    static func snapshotRequests() -> [URLRequest] {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.requests
    }

    static func snapshotStopCount() -> Int {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.stopCount
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response: FixtureResponse?
        Self.state.lock.lock()
        Self.state.requests.append(request)
        response = Self.state.handler?(request)
        Self.state.lock.unlock()
        guard let response else { return }

        if let redirect = response.redirect {
            let redirectResponse = HTTPURLResponse(
                url: request.url!, statusCode: response.status,
                httpVersion: nil, headerFields: response.headers)!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: redirect), redirectResponse: redirectResponse)
            client?.urlProtocol(self, didReceive: redirectResponse, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let httpResponse = HTTPURLResponse(
            url: request.url!, statusCode: response.status,
            httpVersion: nil, headerFields: response.headers)!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        for chunk in response.bodyChunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        if response.delayBeforeFinish > 0 {
            Thread.sleep(forTimeInterval: Double(response.delayBeforeFinish) / 1_000_000_000)
        }
        if response.finish { client?.urlProtocolDidFinishLoading(self) }
    }

    override func stopLoading() {
        Self.state.lock.lock(); Self.state.stopCount += 1; Self.state.lock.unlock()
    }
}

private func makeTransport(_ response: @escaping (URLRequest) -> FixtureResponse?) -> ModelTransport {
    FixtureURLProtocol.install(response)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [FixtureURLProtocol.self]
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    return ModelTransport(
        credentialProvider: InMemoryCredentialProvider("test-secret-that-must-never-appear"),
        configuration: configuration)
}

private func requestBody(_ request: URLRequest) throws -> [String: Any] {
    var data = request.httpBody ?? Data()
    if data.isEmpty, let stream = request.httpBodyStream {
        stream.open(); defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw CheckFailure.failed("request body stream") }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
    guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw CheckFailure.failed("request body JSON")
    }
    return body
}

private func baseRequest(protocol protocolKind: FixedProtocol = .openAI) throws -> FixedModelRequest {
    try FixedModelRequest(
        model: .deepSeekFlash,
        protocol: protocolKind,
        messages: [FixedMessage(role: .user, content: "Say hello")],
        maxOutputTokens: 32)
}

private func expectTransportError(_ operation: () async throws -> Void, _ predicate: (ModelTransportError) -> Bool, _ message: String) async throws {
    do {
        try await operation()
        throw CheckFailure.failed("expected error: \(message)")
    } catch let error as ModelTransportError {
        try check(predicate(error), message + ": \(error)")
    } catch {
        throw CheckFailure.failed("wrong error for \(message): \(error)")
    }
}

private func testUnsupportedModelAndBounds() async throws {
    try check(FixedModel(rawValue: "other-model") == nil, "unsupported model must be rejected")
    try check(FixedModelRequest.maxOutputTokens == 8192, "output bound must be finite")
    try expectRequestFailure {
        _ = try FixedModelRequest(model: .deepSeekFlash, protocol: .openAI, messages: [FixedMessage(role: .user, content: String(repeating: "x", count: FixedModelRequest.maxMessageBytes + 1))], maxOutputTokens: 1)
    }
    try expectRequestFailure {
        _ = try FixedModelRequest(model: .deepSeekFlash, protocol: .openAI, messages: [], maxOutputTokens: 0)
    }
}

private func testDecodedRequestCannotBypassBounds() async throws {
    let valid = try JSONEncoder().encode(baseRequest())
    var object = try JSONSerialization.jsonObject(with: valid) as! [String: Any]
    object["maxOutputTokens"] = 0
    try expectRequestFailure { _ = try JSONDecoder().decode(FixedModelRequest.self, from: JSONSerialization.data(withJSONObject: object)) }
    object["maxOutputTokens"] = 32
    object["messages"] = [["role": "user", "content": ""]]
    try expectRequestFailure { _ = try JSONDecoder().decode(FixedModelRequest.self, from: JSONSerialization.data(withJSONObject: object)) }
}

private func expectRequestFailure(_ operation: () throws -> Void) throws {
    do {
        try operation()
        throw CheckFailure.failed("invalid request was accepted")
    } catch is ModelTransportError {
        return
    } catch {
        throw error
    }
}

private func testOpenAIRequestPathModelAndBody() async throws {
    let transport = makeTransport { _ in
        let response = try? JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": "hello"]]]])
        return FixtureResponse(bodyChunks: [response!])
    }
    let result = try await transport.complete(baseRequest())
    try check(result.text == "hello", "OpenAI completion text")
    let requests = FixtureURLProtocol.snapshotRequests()
    try check(requests.count == 1, "one request expected")
    let request = requests[0]
    let body = try requestBody(request)
    try check(request.url?.absoluteString == "https://api.deepseek.com/chat/completions", "OpenAI URL must be fixed")
    try check(body["model"] as? String == "deepseek-flash", "allowlisted model encoded")
    try check(body["stream"] as? Bool == false, "completion must be nonstreaming")
    try check((body["thinking"] as? [String: String])?["type"] == "disabled", "text-only transport explicitly disables thinking")
    try check(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-secret-that-must-never-appear", "host auth")
    try check(request.value(forHTTPHeaderField: "X-Caller-Auth") == nil, "no caller auth")
}

private func testProviderFailure(_ reason: String, streaming: Bool) async throws {
    let secret = "provider-private-body-test-secret-that-must-never-appear"
    let completion = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": secret], "finish_reason": reason]]])
    let payload = "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\n" +
        "data: {\"choices\":[{\"delta\":{\"content\":\"\(secret)\"},\"finish_reason\":\"\(reason)\"}]}\n\n" +
        "data: [DONE]\n\n"
    let transport = makeTransport { _ in FixtureResponse(bodyChunks: [streaming ? Data(payload.utf8) : completion]) }
    var chunks: [ModelStreamChunk] = []
    try await expectTransportError({
        if streaming {
            for try await chunk in transport.stream(try baseRequest()) { chunks.append(chunk) }
        } else { _ = try await transport.complete(baseRequest()) }
    }, { String(describing: $0) == "upstream generation failed" }, "provider failure must be sanitized")
    if streaming {
        try check(chunks.map(\.text) == ["partial"], "failed event must not emit its text")
        try check(!chunks.contains(where: \.isFinal), "failed stream must not emit success final")
    }
}

private func testAnthropicTrustedPath() async throws {
    let transport = makeTransport { _ in
        let response = try? JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": "anthropic"]]])
        return FixtureResponse(bodyChunks: [response!])
    }
    let input = try FixedModelRequest(model: .deepSeekFlash, protocol: .anthropic,
        messages: [FixedMessage(role: .system, content: "Keep instructions"), FixedMessage(role: .user, content: "hello")], maxOutputTokens: 32)
    let result = try await transport.complete(input)
    try check(result.text == "anthropic", "Anthropic completion text")
    let sent = FixtureURLProtocol.snapshotRequests()[0]
    let body = try requestBody(sent)
    try check(sent.url?.absoluteString == "https://api.deepseek.com/anthropic/v1/messages", "Anthropic fixed URL")
    try check(body["model"] as? String == "deepseek-flash", "Anthropic model")
    try check(body["system"] as? String == "Keep instructions", "system instructions must not disappear")
    try check(sent.value(forHTTPHeaderField: "x-api-key") == "test-secret-that-must-never-appear", "Anthropic credential header")
    try check(sent.value(forHTTPHeaderField: "Host") == nil, "no Host override")
}

private func testAnthropicInvalidTextBlocks() async throws {
    for block in ["{\"type\":\"text\"}", "{\"type\":\"text\",\"text\":null}", "{\"type\":\"text\",\"text\":42}"] {
        let payload = "{\"content\":[{\"type\":\"text\",\"text\":\"valid prefix\"},\(block)]}"
        let transport = makeTransport { _ in FixtureResponse(bodyChunks: [Data(payload.utf8)]) }
        try await expectTransportError({ _ = try await transport.complete(baseRequest(protocol: .anthropic)) },
            { $0 == .invalidResponse }, "every text block requires string text")
    }
}

private func testAnthropicMixedBlocks() async throws {
    let payload = "{\"content\":[{\"type\":\"text\",\"text\":\"hello\"},{\"type\":\"thinking\",\"thinking\":\"metadata\"},{\"type\":\"text\",\"text\":\"\"},{\"type\":\"text\",\"text\":\" world\"}]}"
    let transport = makeTransport { _ in FixtureResponse(bodyChunks: [Data(payload.utf8)]) }
    let result = try await transport.complete(baseRequest(protocol: .anthropic))
    try check(result.text == "hello world", "only valid text blocks are joined in order")
}

private func testDecodingErrorsAreInvalidResponse() async throws {
    for kind in [FixedProtocol.openAI, .anthropic] {
        for payload in ["not JSON test-secret-that-must-never-appear", "{}"] {
            let transport = makeTransport { _ in FixtureResponse(bodyChunks: [Data(payload.utf8)]) }
            try await expectTransportError({ _ = try await transport.complete(baseRequest(protocol: kind)) },
                { $0 == .invalidResponse && String(describing: $0) == "invalid upstream response" }, "decode failure is not network failure")
        }
    }
}

private func testLegitimateFinishReasons() async throws {
    for reason in ["stop", "length", "content_filter", "tool_calls"] {
        let completion = "{\"choices\":[{\"message\":{\"content\":\"text\"},\"finish_reason\":\"\(reason)\"}]}"
        let transport = makeTransport { _ in FixtureResponse(bodyChunks: [Data(completion.utf8)]) }
        let result = try await transport.complete(baseRequest())
        try check(result.text == "text", "legitimate finish reason preserves text")
        let payload = "data: {\"choices\":[{\"delta\":{\"content\":\"text\"},\"finish_reason\":\"\(reason)\"}]}\n\ndata: [DONE]\n\n"
        let stream = makeTransport { _ in FixtureResponse(bodyChunks: [Data(payload.utf8)]) }
        var chunks: [ModelStreamChunk] = []
        for try await chunk in stream.stream(try baseRequest()) { chunks.append(chunk) }
        try check(chunks.map(\.text).joined() == "text" && chunks.filter(\.isFinal).count == 1, "legitimate finish still requires DONE")
    }
}

private func testStatusErrorIsSanitized() async throws {
    let secret = "response-body-private-key"
    let transport = makeTransport { _ in
        FixtureResponse(status: 401, headers: ["Content-Type": "text/plain"], bodyChunks: [Data(secret.utf8)])
    }
    try await expectTransportError({ _ = try await transport.complete(try baseRequest()) }, { error in
        guard case .httpStatus(401) = error else { return false }
        let rendered = String(describing: error)
        return !rendered.contains(secret) && !rendered.contains("test-secret")
    }, "status error must not expose response body or key")
}

private func testRedirectIsRejected() async throws {
    let target = URL(string: "https://attacker.invalid/collect")!
    let transport = makeTransport { request in
        if request.url == target { return FixtureResponse(bodyChunks: [Data("forwarded".utf8)]) }
        return FixtureResponse(status: 302, redirect: target)
    }
    try await expectTransportError({ _ = try await transport.complete(try baseRequest()) }, { error in
        if case .redirectRejected = error { return true }
        return false
    }, "redirect must be rejected")
    try check(FixtureURLProtocol.snapshotRequests().allSatisfy { $0.url != target }, "redirect target must not receive a request")
}

private func testFragmentedUTF8SSEAndDone() async throws {
    let event1 = Data("data: {\"choices\":[{\"delta\":{\"content\":\"你\"}}]}\n\n".utf8)
    let event2 = Data("data: {\"choices\":[{\"delta\":{\"content\":\"好\"}}]}\n\n".utf8)
    let done = Data("data: [DONE]\n\n".utf8)
    let bytes = event1 + event2 + done
    // One byte per fragment splits every multibyte UTF-8 code point.
    let chunks = bytes.map { Data([$0]) }
    let transport = makeTransport { _ in FixtureResponse(headers: ["Content-Type": "text/event-stream"], bodyChunks: chunks) }
    var values: [String] = []
    var finalCount = 0
    for try await chunk in transport.stream(try baseRequest()) {
        if chunk.isFinal { finalCount += 1 } else { values.append(chunk.text) }
    }
    try check(values == ["你", "好"], "SSE chunks must preserve UTF8 and order")
    try check(finalCount == 1, "DONE must produce one final marker")
}

private func testOversizedResponseAndOversizedSSELine() async throws {
    let oversized = Data(repeating: 0x61, count: ModelTransport.maxResponseBytes + 1)
    let transport = makeTransport { _ in FixtureResponse(headers: ["Content-Type": "application/json"], bodyChunks: [oversized]) }
    try await expectTransportError({ _ = try await transport.complete(try baseRequest()) }, { error in
        if case .responseTooLarge = error { return true }
        return false
    }, "oversized response")

    let longLine = Data(("data: " + String(repeating: "a", count: ModelTransport.maxSSELineBytes) + "\n\n").utf8)
    let lineTransport = makeTransport { _ in FixtureResponse(headers: ["Content-Type": "text/event-stream"], bodyChunks: [longLine]) }
    try await expectTransportError({
        for try await _ in lineTransport.stream(try baseRequest()) { }
    }, { error in
        if case .sseLineTooLarge = error { return true }
        return false
    }, "oversized SSE line")
}

private final class ObservedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    func set() { lock.lock(); stored = true; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return stored }
}

private func testIncrementalBeforeEOF() async throws {
    let received = ObservedFlag()
    let transport = makeTransport { _ in
        FixtureResponse(headers: ["Content-Type": "text/event-stream"],
            bodyChunks: [Data("data: {\"choices\":[{\"delta\":{\"content\":\"first\"}}]}\n\n".utf8)], finish: false)
    }
    let consumer = Task {
        do { for try await chunk in transport.stream(try baseRequest()) {
            if chunk.text == "first" { received.set() }
        } } catch { }
    }
    for _ in 0..<50 {
        if received.get() { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    consumer.cancel()
    _ = await consumer.result
    try check(received.get(), "first SSE chunk must arrive before EOF/DONE")
}

private func testAnthropicSSELifecycle() async throws {
    let payload = ": ping\r\nevent: message_start\r\ndata: {\"type\":\"message_start\"}\r\n\r\n" +
        "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"hi\"}}\n\n" +
        "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
    let transport = makeTransport { _ in FixtureResponse(headers: ["Content-Type": "text/event-stream"], bodyChunks: payload.utf8.map { Data([$0]) }) }
    var chunks: [ModelStreamChunk] = []
    for try await chunk in transport.stream(try baseRequest(protocol: .anthropic)) { chunks.append(chunk) }
    try check(chunks.map(\.text).joined() == "hi" && chunks.filter(\.isFinal).count == 1, "Anthropic lifecycle and terminal event")
}

private func testSSELoneCRAndInvalidUTF8() async throws {
    let valid = "data: {\"choices\":[{\"delta\":{\"content\":\"CR\"}}]}\r\rdata: [DONE]\r\r"
    let transport = makeTransport { _ in FixtureResponse(headers: ["Content-Type": "text/event-stream"], bodyChunks: [Data(valid.utf8)]) }
    var text = ""
    for try await chunk in transport.stream(try baseRequest()) { text += chunk.text }
    try check(text == "CR", "lone CR must delimit SSE lines")
    let invalid = Data("data: ".utf8) + Data([0xff, 0x0a, 0x0a])
    let bad = makeTransport { _ in FixtureResponse(headers: ["Content-Type": "text/event-stream"], bodyChunks: [invalid]) }
    try await expectTransportError({ for try await _ in bad.stream(try baseRequest()) {} }, { $0 == .malformedSSE }, "invalid UTF8 is rejected")
}

private func testTruncatedStreamRejected() async throws {
    let transport = makeTransport { _ in FixtureResponse(headers: ["Content-Type": "text/event-stream"], bodyChunks: [Data("data: [DONE]".utf8)]) }
    try await expectTransportError({ for try await _ in transport.stream(try baseRequest()) {} },
        { $0 == .invalidResponse || $0 == .malformedSSE }, "unterminated event is not a completed stream")
}

private func testCancellationStopsTask() async throws {
    let transport = makeTransport { _ in FixtureResponse(headers: ["Content-Type": "text/event-stream"], bodyChunks: [], finish: false) }
    let consumer = Task {
        do {
            for try await _ in transport.stream(try baseRequest()) { }
        } catch { }
    }
    try await Task.sleep(nanoseconds: 100_000_000)
    consumer.cancel()
    _ = await consumer.result
    try await Task.sleep(nanoseconds: 100_000_000)
    let stopped = FixtureURLProtocol.snapshotStopCount()
    try check(stopped > 0, "cancellation must stop URLSession task")
}

private func testInvalidCredentialRejectedBeforeDispatch() async throws {
    FixtureURLProtocol.install { _ in FixtureResponse(bodyChunks: [Data("{\"choices\":[{\"message\":{\"content\":\"bad\"}}]}".utf8)]) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [FixtureURLProtocol.self]
    let transport = ModelTransport(credentialProvider: InMemoryCredentialProvider("bad\r\nheader"), configuration: configuration)
    try await expectTransportError({ _ = try await transport.complete(baseRequest()) }, { $0 == .credential(.invalid) }, "invalid credential rejected")
    try check(FixtureURLProtocol.snapshotRequests().isEmpty, "invalid credential must never dispatch")
}

private func testEncodedRequestSizeLimit() async throws {
    let transport = makeTransport { _ in FixtureResponse() }
    let message = try FixedMessage(role: .user, content: String(repeating: "a", count: FixedModelRequest.maxMessageBytes))
    let request = try FixedModelRequest(model: .deepSeekFlash, protocol: .openAI, messages: Array(repeating: message, count: 18), maxOutputTokens: 1)
    try await expectTransportError({ _ = try await transport.complete(request) }, { $0 == .requestTooLarge }, "encoded request bound")
    try check(FixtureURLProtocol.snapshotRequests().isEmpty, "oversized request never dispatched")
}

private func testConcurrencyBoundAndReuse() async throws {
    let transport = makeTransport { _ in FixtureResponse(bodyChunks: [], finish: false) }
    let active = (0..<ModelTransport.maxConcurrentRequests).map { _ in Task { try await transport.complete(baseRequest()) } }
    for _ in 0..<100 {
        if FixtureURLProtocol.snapshotRequests().count == ModelTransport.maxConcurrentRequests { break }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    let resultSeen = ObservedFlag()
    let overflow = Task { () -> String in
        do { _ = try await transport.complete(baseRequest()); resultSeen.set(); return "allowed" }
        catch { resultSeen.set(); return String(describing: error) }
    }
    for _ in 0..<40 {
        if resultSeen.get() { break }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    let rejectedPromptly = resultSeen.get()
    overflow.cancel()
    for task in active { task.cancel() }
    for task in active { _ = await task.result }
    let overflowResult = await overflow.value
    try check(rejectedPromptly && overflowResult == "model transport busy", "excess concurrency must fail fast without unbounded waiters")
    FixtureURLProtocol.install { _ in FixtureResponse(bodyChunks: [Data("{\"choices\":[{\"message\":{\"content\":\"reused\"}}]}".utf8)]) }
    for _ in 0..<6 {
        let result = try await transport.complete(baseRequest())
        try check(result.text == "reused", "cancelled requests release slots")
    }
}

private func testKeychainCRUDIsolated() throws {
    let service = "dev.mini-sandbox.test." + UUID().uuidString
    let account = "account." + UUID().uuidString
    let store = KeychainModelCredentialProvider(service: service, account: account)
    defer { try? store.remove() }
    try store.setCredential("dummy-keychain-value")
    try check(try store.credential(for: .deepSeekFlash) == "dummy-keychain-value", "Keychain readback")
    try store.setCredential("updated-dummy-keychain-value")
    try check(try store.credential(for: .deepSeekFlash) == "updated-dummy-keychain-value", "Keychain update readback")
    try store.remove()
    do {
        _ = try store.credential(for: .deepSeekFlash)
        throw CheckFailure.failed("deleted Keychain item still returned")
    } catch let error as CredentialProviderError {
        try check(error == .missing, "deleted Keychain item must be missing")
    }
}

private struct NamedCheck: Sendable {
    let name: String
    let run: @Sendable () async throws -> Void
}

private let checks: [NamedCheck] = [
    NamedCheck(name: "Anthropic invalid text blocks", run: testAnthropicInvalidTextBlocks),
    NamedCheck(name: "Anthropic mixed blocks", run: testAnthropicMixedBlocks),
    NamedCheck(name: "decoding errors are invalid response", run: testDecodingErrorsAreInvalidResponse),
    NamedCheck(name: "legitimate finish reasons", run: testLegitimateFinishReasons),
    NamedCheck(name: "provider failure insufficient completion", run: { try await testProviderFailure("insufficient_system_resource", streaming: false) }),
    NamedCheck(name: "provider failure aborted completion", run: { try await testProviderFailure("aborted", streaming: false) }),
    NamedCheck(name: "provider failure insufficient SSE", run: { try await testProviderFailure("insufficient_system_resource", streaming: true) }),
    NamedCheck(name: "provider failure aborted SSE", run: { try await testProviderFailure("aborted", streaming: true) }),
    NamedCheck(name: "SSE CR and invalid UTF8", run: testSSELoneCRAndInvalidUTF8),
    NamedCheck(name: "invalid credential", run: testInvalidCredentialRejectedBeforeDispatch),
    NamedCheck(name: "encoded request limit", run: testEncodedRequestSizeLimit),
    NamedCheck(name: "concurrency slots", run: testConcurrencyBoundAndReuse),
    NamedCheck(name: "stream before EOF", run: testIncrementalBeforeEOF),
    NamedCheck(name: "Anthropic SSE lifecycle", run: testAnthropicSSELifecycle),
    NamedCheck(name: "truncated SSE", run: testTruncatedStreamRejected),
    NamedCheck(name: "decoded bounds", run: testDecodedRequestCannotBypassBounds),
    NamedCheck(name: "unsupported model and bounds", run: testUnsupportedModelAndBounds),
    NamedCheck(name: "OpenAI request", run: testOpenAIRequestPathModelAndBody),
    NamedCheck(name: "Anthropic trusted path", run: testAnthropicTrustedPath),
    NamedCheck(name: "sanitized status error", run: testStatusErrorIsSanitized),
    NamedCheck(name: "redirect rejection", run: testRedirectIsRejected),
    NamedCheck(name: "fragmented UTF8 SSE", run: testFragmentedUTF8SSEAndDone),
    NamedCheck(name: "response limits", run: testOversizedResponseAndOversizedSSELine),
    NamedCheck(name: "cancellation", run: testCancellationStopsTask),
    NamedCheck(name: "isolated Keychain CRUD", run: { try testKeychainCRUDIsolated() })
]

private func runLiveSmoke() async {
    guard let key = ProcessInfo.processInfo.environment["TEST_DEEPSEEK_KEY"], !key.isEmpty else {
        print("BLOCKED live host transport: TEST_DEEPSEEK_KEY not set")
        Foundation.exit(2)
    }
    let transport = ModelTransport(credentialProvider: InMemoryCredentialProvider(key))
    var passed = 0
    for kind in [FixedProtocol.openAI, .anthropic] {
        do {
            let request = try FixedModelRequest(model: .deepSeekFlash, protocol: kind,
                messages: [FixedMessage(role: .user, content: "Reply with exactly OK.")], maxOutputTokens: 32)
            let completion = try await transport.complete(request)
            try check(!completion.text.isEmpty, "live nonstream returned text")
            passed += 1; print("PASS live \(kind.rawValue) completion")
            var text = ""; var finals = 0
            for try await chunk in transport.stream(request) {
                text += chunk.text
                if chunk.isFinal { finals += 1 }
            }
            try check(!text.isEmpty && finals == 1, "live stream text and terminal marker")
            passed += 1; print("PASS live \(kind.rawValue) stream")
        } catch {
            print("FAIL live \(kind.rawValue): \(error)")
        }
    }
    print("LIVE_HOST_TRANSPORT \(passed)/4; Keychain/VM/Agent integration NOT_RUN")
    if passed != 4 { Foundation.exit(1) }
}

@main
private struct ModelTransportChecks {
    static func main() async {
        if CommandLine.arguments.contains("--live") { await runLiveSmoke(); return }
        var failures = 0
        var blocked = 0
        let selected = checks.filter { CommandLine.arguments.count < 2 || $0.name.contains(CommandLine.arguments[1]) }
        guard !selected.isEmpty else {
            print("ERROR: no tests matched the selector")
            Foundation.exit(64)
        }
        for check in selected {
            do {
                try await check.run()
                print("PASS \(check.name)")
            } catch CredentialProviderError.storageUnavailable(let status) where [-60008, -25308, -25291].contains(status) && check.name == "isolated Keychain CRUD" {
                blocked += 1
                print("BLOCKED \(check.name): host Keychain authorization unavailable (\(status))")
            } catch {
                failures += 1
                print("FAIL \(check.name): \(error)")
            }
        }
        print("PASS \(selected.count - failures - blocked); FAIL \(failures); BLOCKED \(blocked); TOTAL \(selected.count)")
        if failures > 0 { Foundation.exit(1) }
        if blocked > 0 { Foundation.exit(2) }
    }
}
