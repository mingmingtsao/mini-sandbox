import Foundation
import Security

package struct ModelCompletion: Equatable, Sendable {
    package let text: String
    package init(text: String) { self.text = text }
}

package struct ModelStreamChunk: Equatable, Sendable {
    package let text: String
    package let isFinal: Bool
    package init(text: String, isFinal: Bool) {
        self.text = text
        self.isFinal = isFinal
    }
}

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
    private let session: URLSession
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
        self.session = URLSession(configuration: configuration, delegate: RedirectRejectingDelegate(), delegateQueue: nil)
        self.limiter = RequestLimiter(limit: Self.maxConcurrentRequests)
        super.init()
    }

    private static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = nil
        return configuration
    }

    deinit { session.invalidateAndCancel() }

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
        try limiter.acquire()
        defer { limiter.release() }

        let credential: String
        do { credential = try credentialProvider.credential(for: request.model) }
        catch let error as CredentialProviderError { throw ModelTransportError.credential(error) }
        catch { throw ModelTransportError.credential(.unavailable) }
        guard !credential.isEmpty, credential.utf8.count <= 16 * 1024,
              !credential.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ModelTransportError.credential(.invalid)
        }

        let endpoint = endpoint(for: request)
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = Self.requestTimeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        switch request.protocol {
        case .openAI: urlRequest.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        case .anthropic:
            urlRequest.setValue(credential, forHTTPHeaderField: "x-api-key")
            urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        urlRequest.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let body = try encode(request, streaming: streaming)
        guard body.count <= Self.maxRequestBodyBytes else { throw ModelTransportError.requestTooLarge }
        urlRequest.httpBody = body

        do {
            let (bytes, response) = try await session.bytes(for: urlRequest)
            defer { bytes.task.cancel() }
            return try await withTaskCancellationHandler {
                guard let http = response as? HTTPURLResponse else { throw ModelTransportError.invalidResponse }
                guard !(300..<400).contains(http.statusCode) else { throw ModelTransportError.redirectRejected }
                guard (200..<300).contains(http.statusCode) else { throw ModelTransportError.httpStatus(http.statusCode) }
                if streaming {
                    try await parseSSE(bytes: bytes, protocol: request.protocol, emit: emit!)
                    return ModelCompletion(text: "")
                }
                let data = try await collect(bytes: bytes)
                return ModelCompletion(text: try decodeText(data, protocol: request.protocol))
            } onCancel: { bytes.task.cancel() }
        } catch is CancellationError {
            throw ModelTransportError.cancelled
        } catch let error as ModelTransportError {
            throw error
        } catch is DecodingError {
            throw ModelTransportError.invalidResponse
        } catch {
            if Task.isCancelled { throw ModelTransportError.cancelled }
            throw ModelTransportError.network
        }
    }

    private func endpoint(for request: FixedModelRequest) -> URL {
        switch request.protocol {
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
                let max_tokens: Int
                let stream: Bool
                let thinking = ["type": "disabled"]
            }
            let system = request.messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
            return try JSONEncoder().encode(Payload(model: request.model.rawValue, messages: request.messages.filter { $0.role != .system }, system: system.isEmpty ? nil : system, max_tokens: request.maxOutputTokens, stream: streaming))
        }
    }

    private func collect(bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            guard data.count < Self.maxResponseBytes else { throw ModelTransportError.responseTooLarge }
            data.append(byte)
        }
        guard !data.isEmpty else { throw ModelTransportError.invalidResponse }
        return data
    }

    private func decodeText(_ data: Data, protocol: FixedProtocol) throws -> String {
        struct OpenAIResponse: Decodable { struct Choice: Decodable { struct Message: Decodable { let content: String? }; let message: Message; let finish_reason: String? }; let choices: [Choice] }
        struct AnthropicResponse: Decodable {
            struct Content: Decodable {
                let text: String?
                private enum CodingKeys: String, CodingKey { case type, text }
                init(from decoder: any Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    let type = try container.decode(String.self, forKey: .type)
                    // Non-text metadata is ignored; text blocks must contain a string.
                    text = type == "text" ? try container.decode(String.self, forKey: .text) : nil
                }
            }
            let content: [Content]
        }
        switch `protocol` {
        case .openAI:
            let response = try JSONDecoder().decode(OpenAIResponse.self, from: data)
            for choice in response.choices { try rejectProviderFailure(choice.finish_reason) }
            guard let text = response.choices.first?.message.content else { throw ModelTransportError.invalidResponse }
            return text
        case .anthropic:
            let response = try JSONDecoder().decode(AnthropicResponse.self, from: data)
            return response.content.compactMap(\.text).joined()
        }
    }

    private func parseSSE(bytes: URLSession.AsyncBytes, protocol kind: FixedProtocol,
        emit: @Sendable (ModelStreamChunk) -> Void) async throws {
        var parser = SSEParser()
        var totalBytes = 0
        for try await byte in bytes {
            try Task.checkCancellation()
            totalBytes += 1
            guard totalBytes <= Self.maxResponseBytes else { throw ModelTransportError.responseTooLarge }
            for event in try parser.consume(byte: byte) {
                let chunk = try decodeSSEEvent(event, protocol: kind)
                if let chunk {
                    emit(chunk)
                    if chunk.isFinal { return }
                }
            }
        }
        // EOF is never completion: require a fully framed provider terminal event.
        throw ModelTransportError.invalidResponse
    }

    private func decodeSSEEvent(_ event: String, protocol kind: FixedProtocol) throws -> ModelStreamChunk? {
        if kind == .openAI && event == "[DONE]" { return ModelStreamChunk(text: "", isFinal: true) }
        guard let object = try? JSONSerialization.jsonObject(with: Data(event.utf8)) as? [String: Any],
              object["error"] == nil else { throw ModelTransportError.malformedSSE }
        switch kind {
        case .openAI:
            guard let choices = object["choices"] as? [[String: Any]] else { throw ModelTransportError.malformedSSE }
            for choice in choices { try rejectProviderFailure(choice["finish_reason"] as? String) }
            if choices.isEmpty { return nil } // Optional usage-only chunk.
            guard let delta = choices.first?["delta"] as? [String: Any] else { throw ModelTransportError.malformedSSE }
            guard let text = delta["content"] as? String, !text.isEmpty else { return nil }
            return ModelStreamChunk(text: text, isFinal: false)
        case .anthropic:
            guard let type = object["type"] as? String else { throw ModelTransportError.malformedSSE }
            switch type {
            case "message_stop": return ModelStreamChunk(text: "", isFinal: true)
            case "content_block_delta":
                guard let delta = object["delta"] as? [String: Any] else { throw ModelTransportError.malformedSSE }
                guard let text = delta["text"] as? String, !text.isEmpty else { return nil }
                return ModelStreamChunk(text: text, isFinal: false)
            case "error": throw ModelTransportError.invalidResponse
            default: return nil // Lifecycle, ping and non-text metadata are not text chunks.
            }
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

private final class RedirectRejectingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
