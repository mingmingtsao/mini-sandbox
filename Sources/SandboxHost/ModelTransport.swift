import Foundation
import Security


package enum ModelTransportError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidRequest(String)
    case credential(CredentialProviderError)
    case httpStatus(Int)
    case invalidResponse
    case providerFailure
    case responseTooLarge
    case sseLineTooLarge
    case requestTooLarge
    case malformedSSE
    case redirectRejected
    case cancelled
    case network
    case busy

    package var description: String {
        switch self {
        case .invalidRequest(let field): return "invalid request: \(field)"
        case .credential(let error): return error.description
        case .httpStatus(let status): return "upstream HTTP status \(status)"
        case .invalidResponse: return "invalid upstream response"
        case .providerFailure: return "upstream generation failed"
        case .responseTooLarge: return "upstream response too large"
        case .sseLineTooLarge: return "upstream SSE line too large"
        case .requestTooLarge: return "request too large"
        case .malformedSSE: return "malformed upstream SSE"
        case .redirectRejected: return "upstream redirect rejected"
        case .cancelled: return "request cancelled"
        case .network: return "upstream network failure"
        case .busy: return "model transport busy"
        }
    }
}

package final class ModelTransport: NSObject, @unchecked Sendable {
    package static let maxResponseBytes = 4 * 1024 * 1024
    package static let maxSSELineBytes = 256 * 1024
    package static let maxRequestBodyBytes = 1 * 1024 * 1024
    package static let maxConcurrentRequests = 4
    package static let requestTimeout: TimeInterval = 60
    package static let resourceTimeout: TimeInterval = 120

    private let credentialProvider: any ModelCredentialProvider
    private let configuration: URLSessionConfiguration
    private let limiter: RequestLimiter

    package init(credentialProvider: any ModelCredentialProvider, configuration: URLSessionConfiguration? = nil) {
        self.credentialProvider = credentialProvider
        let configuration = configuration ?? Self.defaultConfiguration()
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = Self.requestTimeout
        configuration.timeoutIntervalForResource = Self.resourceTimeout
        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.limiter = RequestLimiter(limit: Self.maxConcurrentRequests)
        super.init()
    }

    private static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = nil
        return configuration
    }


    package func complete(_ request: FixedModelRequest) async throws -> ModelCompletion {
        do { return try await perform(request, streaming: false) }
        catch { throw Self.sanitize(error) }
    }

    package func stream(_ request: FixedModelRequest) -> AsyncThrowingStream<ModelStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    _ = try await self.perform(request, streaming: true) { chunk in
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.sanitize(error))
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private func perform(_ request: FixedModelRequest, streaming: Bool,
        emit: (@Sendable (ModelStreamChunk) -> Void)? = nil) async throws -> ModelCompletion {
        guard !Task.isCancelled else { throw ModelTransportError.cancelled }
        let operation = try prepare(request, streaming: streaming)
        defer { operation.cancel() }
        return try await withTaskCancellationHandler {
            try operation.start()
            var text = ""
            var sawFinal = false
            var completion: ModelCompletion?
            for try await chunk in operation.chunks {
                try Task.checkCancellation()
                if chunk.isFinal { sawFinal = true }
                if let value = chunk.completion { completion = value }
                if streaming { emit?(chunk) } else { text += chunk.text }
            }
            // Cancellation can terminate AsyncThrowingStream iteration without throwing.
            try Task.checkCancellation()
            guard sawFinal else { throw ModelTransportError.invalidResponse }
            return completion ?? ModelCompletion(text: text)
        } onCancel: { operation.cancel() }
    }

    /// Synchronous preparation only; the URLSession task remains suspended.
    /// The owner must authorize/audit before calling this (credential access occurs here).
    package func prepare(_ request: FixedModelRequest, streaming: Bool) throws -> ModelPreparedOperation {
        try prepareEncoded(encode(request, streaming: streaming), model: request.model, protocol: request.protocol, streaming: streaming)
    }

    package func prepareNative(_ request: AnthropicNativeRequest) throws -> ModelPreparedOperation {
        guard request.dialect == .native else { throw HostModelGatewayError.businessRouteDisabled }
        return try prepareEncoded(request.canonicalBody, model: request.model, protocol: .anthropic, streaming: request.streaming)
    }

    package func prepareClaude(_ request: AnthropicNativeRequest, selectors: ClaudeRequestSelectors) throws -> ModelPreparedOperation {
        // Immutable production gate, before credential preparation or URLSession.
        guard BusinessModelActivation.credentialEgressEnabled else { throw HostModelGatewayError.businessRouteDisabled }
        guard request.dialect == .claude else { throw ModelTransportError.invalidRequest("claude dialect") }
        try selectors.validate()
        return try prepareEncoded(request.canonicalBody, model: request.model, protocol: .anthropic,
                                  streaming: request.streaming, claudeSelectors: selectors)
    }

    private func prepareEncoded(_ body: Data, model: FixedModel, protocol kind: FixedProtocol, streaming: Bool,
                                claudeSelectors: ClaudeRequestSelectors? = nil) throws -> ModelPreparedOperation {
        if claudeSelectors != nil {
            guard BusinessModelActivation.credentialEgressEnabled else { throw HostModelGatewayError.businessRouteDisabled }
        }
        try limiter.acquire()
        do {
            guard body.count <= Self.maxRequestBodyBytes else { throw ModelTransportError.requestTooLarge }
            let credential: String
            do { credential = try credentialProvider.credential(for: model) }
            catch let error as CredentialProviderError { throw ModelTransportError.credential(error) }
            catch { throw ModelTransportError.credential(.unavailable) }
            guard !credential.isEmpty, credential.utf8.count <= 16 * 1024,
                  !credential.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw ModelTransportError.credential(.invalid)
            }

            if let claudeSelectors { try claudeSelectors.validate(); guard kind == .anthropic else { throw ModelTransportError.invalidRequest("claude protocol") } }
            // The closed host route is unreachable while activation is disabled.
            let endpoint = claudeSelectors == nil ? endpoint(for: kind) : URL(string: "https://api.deepseek.com/anthropic/v1/messages?beta=true")!
            var urlRequest = URLRequest(url: endpoint)
            urlRequest.httpMethod = "POST"
            urlRequest.timeoutInterval = Self.requestTimeout
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            switch kind {
            case .openAI: urlRequest.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
            case .anthropic:
                urlRequest.setValue(credential, forHTTPHeaderField: "x-api-key")
                urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                if let claudeSelectors {
                    urlRequest.setValue(claudeSelectors.beta, forHTTPHeaderField: "anthropic-beta")
                    urlRequest.setValue(claudeSelectors.directBrowserAccess, forHTTPHeaderField: "anthropic-dangerous-direct-browser-access")
                }
            }
            urlRequest.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            urlRequest.httpBody = body
            let anthropicDecoder = AnthropicStreamDecoder()
            return ModelPreparedOperation(request: urlRequest, configuration: configuration, streaming: streaming, activeCredential: credential,
                decodeText: { try self.decodeText($0, protocol: kind) },
                decodeEvent: { kind == .anthropic ? try anthropicDecoder.consume($0) : try self.decodeSSEEvent($0, protocol: .openAI) },
                release: { self.limiter.release() })
        } catch {
            limiter.release()
            throw Self.sanitize(error)
        }
    }

    private func endpoint(for kind: FixedProtocol) -> URL {
        switch kind {
        case .openAI: return URL(string: "https://api.deepseek.com/chat/completions")!
        case .anthropic: return URL(string: "https://api.deepseek.com/anthropic/v1/messages")!
        }
    }

    private func encode(_ request: FixedModelRequest, streaming: Bool) throws -> Data {
        switch request.protocol {
        case .openAI:
            struct Payload: Encodable {
                let model: String
                let messages: [FixedMessage]
                let max_tokens: Int
                let stream: Bool
                let thinking = ["type": "disabled"]
            }
            return try JSONEncoder().encode(Payload(model: request.model.rawValue, messages: request.messages, max_tokens: request.maxOutputTokens, stream: streaming))
        case .anthropic:
            struct Payload: Encodable {
                let model: String
                let messages: [FixedMessage]
                let system: String?
                let tools: [ModelToolDefinition]?
                let tool_choice: ModelToolChoice?
                let max_tokens: Int
                let stream: Bool
                let thinking = ["type": "disabled"]
            }
            let system = request.messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
            return try JSONEncoder().encode(Payload(model: request.model.rawValue, messages: request.messages.filter { $0.role != .system }, system: system.isEmpty ? nil : system, tools: request.tools.isEmpty ? nil : request.tools, tool_choice: request.toolChoice, max_tokens: request.maxOutputTokens, stream: streaming))
        }
    }


    private func decodeText(_ data: Data, protocol: FixedProtocol) throws -> ModelCompletion {
        struct OpenAIResponse: Decodable { struct Choice: Decodable { struct Message: Decodable { let content: String? }; let message: Message; let finish_reason: String? }; let choices: [Choice] }

        switch `protocol` {
        case .openAI:
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let choices = root["choices"] as? [[String: Any]] else { throw ModelTransportError.invalidResponse }
            for choice in choices {
                if let message = choice["message"] as? [String: Any] { try rejectStructuredOpenAI(message) }
            }
            let response = try JSONDecoder().decode(OpenAIResponse.self, from: data)
            for choice in response.choices { try rejectProviderFailure(choice.finish_reason) }
            guard let text = response.choices.first?.message.content else { throw ModelTransportError.invalidResponse }
            return ModelCompletion(text: text)
        case .anthropic:
            return try AnthropicResponse.decode(data)
        }
    }


    private func decodeSSEEvent(_ event: String, protocol kind: FixedProtocol) throws -> ModelStreamChunk? {
        if kind == .openAI && event == "[DONE]" { return ModelStreamChunk(text: "", isFinal: true) }
        guard let object = try? JSONSerialization.jsonObject(with: Data(event.utf8)) as? [String: Any],
              object["error"] == nil else { throw ModelTransportError.malformedSSE }
        switch kind {
        case .openAI:
            guard let choices = object["choices"] as? [[String: Any]] else { throw ModelTransportError.malformedSSE }
            for choice in choices {
                try rejectProviderFailure(choice["finish_reason"] as? String)
                if let delta = choice["delta"] as? [String: Any] { try rejectStructuredOpenAI(delta) }
            }
            if choices.isEmpty { return nil } // Optional usage-only chunk.
            guard let delta = choices.first?["delta"] as? [String: Any] else { throw ModelTransportError.malformedSSE }
            guard let text = delta["content"] as? String, !text.isEmpty else { return nil }
            return ModelStreamChunk(text: text, isFinal: false)
        case .anthropic:
            // Anthropic always uses the per-request stateful decoder above.
            throw ModelTransportError.malformedSSE
        }
    }

    private func rejectStructuredOpenAI(_ object: [String: Any]) throws {
        if let content = object["content"], !(content is NSNull), !(content is String) { throw ModelTransportError.invalidResponse }
        for key in ["tool_calls", "function_call"] {
            if let value = object[key], !(value is NSNull) { throw ModelTransportError.invalidResponse }
        }
    }

    private func rejectProviderFailure(_ reason: String?) throws {
        if reason == "insufficient_system_resource" || reason == "aborted" {
            throw ModelTransportError.providerFailure
        }
    }

    private static func sanitize(_ error: Error) -> Error {
        if let error = error as? ModelTransportError { return error }
        if error is CancellationError { return ModelTransportError.cancelled }
        return ModelTransportError.network
    }
}

private struct SSEParser: Sendable {
    private var line = Data()
    private var eventData: [String] = []
    private var afterCR = false
    private var firstLine = true

    mutating func consume(byte: UInt8) throws -> [String] {
        if afterCR {
            afterCR = false
            if byte == 0x0A { return [] }
        }
        if byte == 0x0D || byte == 0x0A {
            afterCR = byte == 0x0D
            guard var text = String(data: line, encoding: .utf8) else { throw ModelTransportError.malformedSSE }
            line.removeAll(keepingCapacity: true)
            if firstLine {
                firstLine = false
                if text.first == "\u{FEFF}" { text.removeFirst() }
            }
            if text.isEmpty {
                let result = eventData.joined(separator: "\n")
                eventData.removeAll(keepingCapacity: true)
                return result.isEmpty ? [] : [result]
            }
            if text == "data" { eventData.append(""); return [] }
            guard text.hasPrefix("data:") else { return [] }
            var value = String(text.dropFirst(5))
            if value.first == " " { value.removeFirst() }
            eventData.append(value)
            return []
        }
        line.append(byte)
        guard line.count <= ModelTransport.maxSSELineBytes else { throw ModelTransportError.sseLineTooLarge }
        return []
    }
}

private final class RequestLimiter: @unchecked Sendable {
    private let limit: Int
    private var active = 0
    private let lock = NSLock()
    init(limit: Int) { self.limit = limit }
    func acquire() throws {
        lock.lock(); defer { lock.unlock() }
        guard active < limit else { throw ModelTransportError.busy }
        active += 1
    }
    func release() {
        lock.lock(); defer { lock.unlock() }
        active -= 1
    }
}

/// Owns a real suspended task. start() calls resume() before returning, never via a Task.
/// Cancellation cannot prove an upstream side effect did not occur after start.
package final class ModelPreparedOperation: @unchecked Sendable {
    package let chunks: AsyncThrowingStream<ModelStreamChunk, Error>
    private let session: URLSession
    private let task: URLSessionDataTask
    private let delegate: ModelOperationDelegate
    private let lock = NSLock()
    private var started = false
    private var cancelled = false
    private var resumes = 0
    package var resumeCalls: Int { lock.withLock { resumes } }

    fileprivate init(request: URLRequest, configuration: URLSessionConfiguration, streaming: Bool, activeCredential: String,
        decodeText: @escaping @Sendable (Data) throws -> ModelCompletion,
        decodeEvent: @escaping @Sendable (String) throws -> ModelStreamChunk?,
        release: @escaping @Sendable () -> Void) {
        let pair = AsyncThrowingStream<ModelStreamChunk, Error>.makeStream()
        chunks = pair.stream
        delegate = ModelOperationDelegate(continuation: pair.continuation, streaming: streaming, activeCredential: activeCredential,
            decodeText: decodeText, decodeEvent: decodeEvent, release: release)
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        task = session.dataTask(with: request)
    }
    func acquireForStart() { lock.lock() }
    func releaseForStart() { lock.unlock() }
    func startLocked() throws {
        guard !started, !cancelled else { throw ModelTransportError.cancelled }
        started = true
        task.resume()
        resumes += 1
    }
    package func start() throws { try lock.withLock { try startLocked() } }
    package func cancel() {
        lock.withLock { cancelled = true }
        task.cancel()
        delegate.finish(ModelTransportError.cancelled)
        session.invalidateAndCancel()
    }
    deinit { cancel() }
}

/// URLSession serializes these delegate callbacks. Only terminal state is shared with cancel().
private final class ModelOperationDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let continuation: AsyncThrowingStream<ModelStreamChunk, Error>.Continuation
    let streaming: Bool
    let decodeText: @Sendable (Data) throws -> ModelCompletion
    let decodeEvent: @Sendable (String) throws -> ModelStreamChunk?
    let release: @Sendable () -> Void
    private let lock = NSLock()
    private var ended = false
    private var parser = SSEParser()
    private var data = Data()
    private var total = 0
    private let reflection: ModelCredentialReflection
    private var isEnded: Bool { lock.withLock { ended } }

    init(continuation: AsyncThrowingStream<ModelStreamChunk, Error>.Continuation, streaming: Bool, activeCredential: String,
        decodeText: @escaping @Sendable (Data) throws -> ModelCompletion,
        decodeEvent: @escaping @Sendable (String) throws -> ModelStreamChunk?, release: @escaping @Sendable () -> Void) {
        self.continuation = continuation; self.streaming = streaming
        reflection = ModelCredentialReflection(activeCredential)
        self.decodeText = decodeText; self.decodeEvent = decodeEvent; self.release = release
    }
    func finish(_ error: Error? = nil) {
        let first = lock.withLock { if ended { return false }; ended = true; return true }
        guard first else { return }
        reflection.clear()
        release()
        if let error { continuation.finish(throwing: error) } else { continuation.finish() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
        finish(ModelTransportError.redirectRejected)
        session.invalidateAndCancel()
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            finish(ModelTransportError.invalidResponse); completionHandler(.cancel); return
        }
        guard (200..<300).contains(http.statusCode) else {
            finish((300..<400).contains(http.statusCode) ? ModelTransportError.redirectRejected : .httpStatus(http.statusCode))
            completionHandler(.cancel); return
        }
        completionHandler(isEnded ? .cancel : .allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive incoming: Data) {
        guard !isEnded else { return }
        do {
            if streaming {
                for byte in incoming {
                    guard !isEnded else { return }
                    total += 1
                    guard total <= ModelTransport.maxResponseBytes else { throw ModelTransportError.responseTooLarge }
                    for event in try parser.consume(byte: byte) {
                        if let chunk = try decodeEvent(event) {
                            for safe in try reflection.consume(chunk) {
                                guard !isEnded else { return }
                                continuation.yield(safe)
                            }
                            if chunk.isFinal { finish(); session.invalidateAndCancel(); return }
                        }
                    }
                }
            } else {
                guard incoming.count <= ModelTransport.maxResponseBytes - data.count else { throw ModelTransportError.responseTooLarge }
                data.append(incoming)
            }
        } catch {
            finish(error as? ModelTransportError ?? ModelTransportError.invalidResponse)
            session.invalidateAndCancel()
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { session.finishTasksAndInvalidate() }
        guard !isEnded else { return }
        if let error {
            finish((error as NSError).code == NSURLErrorCancelled ? ModelTransportError.cancelled : .network)
            return
        }
        do {
            guard !streaming, !data.isEmpty else { throw ModelTransportError.invalidResponse }
            let result = try decodeText(data)
            try reflection.validate(result)
            guard !isEnded else { return }
            continuation.yield(ModelStreamChunk(text: result.text, isFinal: false))
            continuation.yield(ModelStreamChunk(event: .messageStop(result), completion: result))
            finish()
        } catch { finish(error as? ModelTransportError ?? ModelTransportError.invalidResponse) }
    }
}
