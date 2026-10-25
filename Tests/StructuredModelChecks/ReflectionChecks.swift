import Foundation
import SandboxContracts
import SandboxHost

// Every fixture credential is generated in memory and is never printed.
final class ReflectionCredential: ModelCredentialProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let value = "sk-reflection-" + UUID().uuidString
    func credential(for model: FixedModel) throws -> String {
        lock.withLock { count += 1 }
        return value
    }
    var reads: Int { lock.withLock { count } }
}
private func reflectionJSON(_ object: Any) throws -> String {
    String(
        decoding: try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .sortedKeys]),
        as: UTF8.self)
}
private func reflectionEscaped(_ value: String) -> String {
    value.utf16.map { String(format: "\\u%04x", $0) }.joined()
}
private func reflectionReply(_ content: [[String: Any]], id: String = "msg_fixture", stop: String = "end_turn") throws
    -> String
{
    try reflectionJSON([
        "type": "message", "id": id, "role": "assistant", "model": "deepseek-flash", "content": content,
        "stop_reason": stop, "usage": ["input_tokens": 1, "output_tokens": 1],
    ])
}
private func reflectionTextEvents(_ parts: [String], adjacent: Bool = false) throws -> [String] {
    var events = [toolEvents()[0]]
    if !adjacent {
        events.append(
            try reflectionJSON([
                "type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""],
            ]))
    }
    for (index, part) in parts.enumerated() {
        if adjacent {
            events.append(
                try reflectionJSON([
                    "type": "content_block_start", "index": index, "content_block": ["type": "text", "text": part],
                ]))
            events.append(try reflectionJSON(["type": "content_block_stop", "index": index]))
        } else {
            events.append(
                try reflectionJSON([
                    "type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": part],
                ]))
        }
    }
    if !adjacent { events.append(#"{"type":"content_block_stop","index":0}"#) }
    events += [
        #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}"#,
        #"{"type":"message_stop"}"#,
    ]
    return events
}
private func reflectionPayload(_ mode: String, key: String) throws -> (FixedProtocol, Bool, [Data]) {
    let split = key.index(key.startIndex, offsetBy: key.count / 2)
    let pieces = [String(key[..<split]), String(key[split...])]
    switch mode {
    case "plain", "prefixed", "escaped", "adjacent", "id", "tool", "tool-id", "tool-name", "usage-key", "model",
        "stop-sequence":
        var text = mode == "prefixed" ? "prefix Bearer " + key : key
        if mode == "escaped" { text = "ESCAPED_PLACEHOLDER" }
        var blocks: [[String: Any]] = [["type": "text", "text": text]]
        if mode == "adjacent" { blocks = pieces.map { ["type": "text", "text": $0] } }
        if ["tool", "tool-id", "tool-name"].contains(mode) {
            blocks = [
                [
                    "type": "tool_use", "id": mode == "tool-id" ? key : "tool_1",
                    "name": mode == "tool-name" ? key : "weather", "input": ["city": mode == "tool" ? key : "ordinary"],
                ]
            ]
        }
        if ["id", "usage-key", "model", "stop-sequence"].contains(mode) {
            blocks = [["type": "text", "text": "ordinary"]]
        }
        var body = try reflectionReply(
            blocks, id: mode == "id" ? key : "msg_fixture", stop: mode.hasPrefix("tool") ? "tool_use" : "end_turn")
        if mode == "escaped" {
            body = body.replacingOccurrences(of: "ESCAPED_PLACEHOLDER", with: reflectionEscaped(key))
        }
        if mode == "usage-key" { body = body.replacingOccurrences(of: "input_tokens", with: key) }
        if mode == "model" { body = body.replacingOccurrences(of: "deepseek-flash", with: key) }
        if mode == "stop-sequence" {
            body = body.replacingOccurrences(
                of: "\"stop_reason\":", with: "\"stop_sequence\":\"" + key + "\",\"stop_reason\":")
        }
        return (.anthropic, false, [Data(body.utf8)])
    case "openai", "openai-escaped":
        var body = try reflectionJSON([
            "choices": [["message": ["content": mode == "openai-escaped" ? "ESCAPED_PLACEHOLDER" : key]]]
        ])
        if mode == "openai-escaped" {
            body = body.replacingOccurrences(of: "ESCAPED_PLACEHOLDER", with: reflectionEscaped(key))
        }
        return (.openAI, false, [Data(body.utf8)])
    case "sse", "sse-adjacent":
        return (.anthropic, true, sse(try reflectionTextEvents(pieces, adjacent: mode == "sse-adjacent")))
    case "sse-id", "sse-model", "sse-stop-sequence", "sse-usage-key", "sse-escaped":
        var events = try reflectionTextEvents(["ordinary"])
        if mode == "sse-id" { events[0] = events[0].replacingOccurrences(of: "msg_1", with: key) }
        if mode == "sse-model" { events[0] = events[0].replacingOccurrences(of: "deepseek-flash", with: key) }
        if mode == "sse-usage-key" {
            events[events.count - 2] = events[events.count - 2].replacingOccurrences(of: "output_tokens", with: key)
        }
        if mode == "sse-stop-sequence" {
            events[events.count - 2] = events[events.count - 2].replacingOccurrences(
                of: "\"stop_reason\":", with: "\"stop_sequence\":\"" + key + "\",\"stop_reason\":")
        }
        if mode == "sse-escaped" {
            events[2] = events[2].replacingOccurrences(of: "ordinary", with: reflectionEscaped(key))
        }
        return (.anthropic, true, sse(events))
    case "sse-tool-id", "sse-tool-name":
        var events = toolEvents()
        events[1] = events[1].replacingOccurrences(of: mode == "sse-tool-id" ? "tool_1" : "weather", with: key)
        return (.anthropic, true, sse(events))
    case "sse-tool", "sse-tool-escaped":
        var events = toolEvents()
        let args =
            mode == "sse-tool-escaped"
            ? "{\"city\":\"" + reflectionEscaped(key) + "\"}" : try reflectionJSON(["city": key])
        let middle = args.index(args.startIndex, offsetBy: args.count / 2)
        events[2] = try reflectionJSON([
            "type": "content_block_delta", "index": 0,
            "delta": ["type": "input_json_delta", "partial_json": String(args[..<middle])],
        ])
        events[3] = try reflectionJSON([
            "type": "content_block_delta", "index": 0,
            "delta": ["type": "input_json_delta", "partial_json": String(args[middle...])],
        ])
        return (.anthropic, true, sse(events))
    case "openai-sse":
        let events = try pieces.map { try reflectionJSON(["choices": [["delta": ["content": $0]]]]) } + ["[DONE]"]
        return (.openAI, true, sse(events))
    default: throw Failure.check("unknown reflection fixture")
    }
}
private func reflectionExposed(_ chunk: ModelStreamChunk, key: String) throws -> Bool {
    func metadata(_ value: ModelMetadata) -> Bool {
        [value.messageID, value.model, value.stopSequence, value.stopReason].compactMap { $0 }.contains {
            $0.contains(key)
        } || (value.usage?.values.keys.contains { $0.contains(key) } ?? false)
    }
    func block(_ value: ModelBlock) throws -> Bool {
        String(decoding: try JSONEncoder().encode(value.wire), as: UTF8.self).contains(key)
    }
    func completion(_ value: ModelCompletion) throws -> Bool {
        try value.text.contains(key) || metadata(value.metadata) || value.blocks.contains(where: block)
    }
    if chunk.text.contains(key) { return true }
    if let value = chunk.completion, try completion(value) { return true }
    switch chunk.event {
    case .messageStart(let value), .messageDelta(let value): return metadata(value)
    case .blockStart(_, let value), .blockStop(_, let value): return try block(value)
    case .messageStop(let value): return try completion(value)
    case .textDelta(_, let value), .inputJSONDelta(_, let value): return value.contains(key)
    case nil: return false
    }
}

func activeCredentialReflection() async throws {
    let modes = [
        "plain", "prefixed", "escaped", "adjacent", "id", "tool", "tool-id", "tool-name", "usage-key", "model",
        "stop-sequence", "openai", "openai-escaped", "sse", "sse-adjacent", "sse-id", "sse-model", "sse-stop-sequence",
        "sse-usage-key", "sse-escaped", "sse-tool-id", "sse-tool-name", "sse-tool", "sse-tool-escaped", "openai-sse",
    ]
    var failures = 0
    for mode in modes {
        let credential = ReflectionCredential()
        let (kind, streaming, data) = try reflectionPayload(mode, key: credential.value)
        Fixture.install([data])
        defer { Fixture.install([]) }
        let transport = ModelTransport(credentialProvider: credential, configuration: configuration())
        let request = try FixedModelRequest(
            model: .deepSeekFlash, protocol: kind, messages: [FixedMessage(role: .user, content: "fixture")],
            maxOutputTokens: 32)
        let operation = try transport.prepare(request, streaming: streaming)
        var chunks: [ModelStreamChunk] = []
        var rejected = false
        try operation.start()
        do { for try await chunk in operation.chunks { chunks.append(chunk) } } catch let error as ModelTransportError {
            rejected = error == .invalidResponse
        }
        let textLeaked = chunks.map(\.text).joined().contains(credential.value)
        let rawArguments = chunks.compactMap { chunk -> String? in
            if case .inputJSONDelta(_, let part) = chunk.event { return part }
            return nil
        }.joined()
        let escapedLeaked =
            rawArguments.contains(credential.value) || rawArguments.contains(reflectionEscaped(credential.value))
        let dtoLeaked = try chunks.contains { try reflectionExposed($0, key: credential.value) }
        let clean =
            rejected && !textLeaked && !escapedLeaked && !dtoLeaked && !chunks.contains(where: \.isFinal)
            && credential.reads == 1 && operation.resumeCalls == 1 && Fixture.requests.count == 1
        try check(reflectionStateIsCleared(operation), "failed operation clears request-private reflection state")
        operation.cancel()
        if !clean { failures += 1 }
        print(
            "REFLECTION \(mode) rejected=\(rejected) textLeak=\(textLeaked) argumentLeak=\(escapedLeaked) dtoLeak=\(dtoLeaked) reads=\(credential.reads) starts=\(operation.resumeCalls) ingress=\(Fixture.requests.count) pass=\(clean)"
        )
    }
    try check(failures == 0, "active credential reflection matrix")
}

func reflectionPendingAudit(kind: FixedProtocol) async throws {
    var failures = 0
    for mode in ["success", "fail", "stop", "cancel"] {
        let credential = ReflectionCredential()
        let prefix = String(credential.value.prefix(12))
        let events =
            kind == .anthropic
            ? try reflectionTextEvents(["ordinary", prefix])
            : try ["ordinary", prefix].map { try reflectionJSON(["choices": [["delta": ["content": $0]]]]) } + [
                "[DONE]"
            ]
        Fixture.install([sse(events)])
        let audit = Audit()
        let barrier = AuditBarrier()
        audit.barrier = barrier
        audit.fail = mode == "fail"
        let emitted = Emissions()
        let (g, h, id) = try await gateway(credential, audit, streaming: true, kind: kind)
        let request = try FixedModelRequest(
            model: .deepSeekFlash, protocol: kind, messages: [FixedMessage(role: .user, content: "fixture")],
            maxOutputTokens: 32)
        let proposal = try await g.propose(handle: h, connectionID: id, request: request, streaming: true)
        let approval = try await g.hostApprove(handle: h, proposal: proposal)
        let task = Task { try await g.execute(handle: h, approval: approval) { emitted.add($0, audit: audit) } }
        for _ in 0..<1000 {
            if barrier.isEntered { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let before = emitted.snapshot.map(\.text).joined()
        let gated = barrier.isEntered && before == "ordinary" && !emitted.premature
        if mode == "stop" { try await g.lifecycle(handle: h).terminate(.stopped) }
        if mode == "cancel" { task.cancel() }
        barrier.release()
        let result = await task.result
        let after = emitted.snapshot.map(\.text).joined()
        let correct: Bool
        switch result {
        case .success(let completion):
            correct =
                mode == "success" && after == "ordinary" + prefix && completion.text == after && !emitted.premature
        case .failure(let error):
            correct =
                mode != "success" && after == "ordinary" && !emitted.snapshot.contains(where: \.isFinal)
                && (error as? HostModelGatewayError == (mode == "fail" ? .auditFailed : .outcomeUnknown))
        }
        let starts = try await g.resumedTaskCount(handle: h)
        let counters =
            credential.reads == 1 && starts == 1 && Fixture.requests.count == 1
            && audit.snapshot.filter { $0.reason == "dispatch-completion" }.count == (mode == "fail" ? 0 : 1)
        let pass = gated && correct && counters
        if !pass { failures += 1 }
        print(
            "REFLECTION_PENDING \(kind.rawValue) \(mode) gated=\(gated) correct=\(correct) reads=\(credential.reads) starts=\(starts) pass=\(pass)"
        )
        Fixture.install([])
    }
    try check(failures == 0, "pending credential-prefix flush obeys completion audit and cancellation")
}

func reflectionGatewayCounters() async throws {
    for mode in [
        "plain", "escaped", "adjacent", "id", "tool", "sse", "sse-adjacent", "sse-id", "sse-tool-escaped", "openai-sse",
    ] {
        let credential = ReflectionCredential()
        let audit = Audit()
        let (kind, streaming, body) = try reflectionPayload(mode, key: credential.value)
        Fixture.install([body])
        let (g, h, id) = try await gateway(credential, audit, streaming: streaming, kind: kind)
        let request = try FixedModelRequest(
            model: .deepSeekFlash, protocol: kind, messages: [FixedMessage(role: .user, content: "fixture")],
            maxOutputTokens: 32)
        let proposal = try await g.propose(handle: h, connectionID: id, request: request, streaming: streaming)
        let approval = try await g.hostApprove(handle: h, proposal: proposal)
        let emitted = Emissions()
        do {
            _ = try await g.execute(handle: h, approval: approval) { emitted.add($0, audit: audit) }
            throw Failure.check("reflected gateway returned success")
        } catch HostModelGatewayError.outcomeUnknown {}
        let starts = try await g.resumedTaskCount(handle: h)
        try check(
            credential.reads == 1 && starts == 1 && Fixture.requests.count == 1,
            "reflection one actual read/start/arrival")
        try check(
            audit.snapshot.map(\.reason) == ["dispatch-intent", "dispatch-completion"]
                && audit.snapshot.last?.outcome == .unknown, "reflection exactly one unknown, never success audit")
        try check(
            !emitted.snapshot.contains(where: \.isTerminal)
                && !emitted.snapshot.map(\.text).joined().contains(credential.value),
            "reflection no terminal or credential output")
        do {
            _ = try await g.execute(handle: h, approval: approval)
            throw Failure.check("reflection approval replayed")
        } catch AuthorizationError.ticketAlreadyConsumed {}
        try check(credential.reads == 1 && Fixture.requests.count == 1, "reflection no retry or replay credential read")
        let ordinary = "Bearer unrelated-public-word"
        let valid: [Data]
        if streaming {
            valid =
                kind == .anthropic
                ? sse(try reflectionTextEvents([ordinary]))
                : sse([try reflectionJSON(["choices": [["delta": ["content": ordinary]]]]), "[DONE]"])
        } else {
            valid = [Data((try reflectionReply([["type": "text", "text": ordinary]])).utf8)]
        }
        Fixture.install([valid])
        let second = try await g.propose(handle: h, connectionID: id, request: request, streaming: streaming)
        let next = try await g.hostApprove(handle: h, proposal: second)
        let result = try await g.execute(handle: h, approval: next)
        try check(
            result.text == ordinary && credential.reads == 2 && Fixture.requests.count == 1
                && audit.snapshot.last?.outcome == .completed,
            "capacity and ordinary unrelated-Bearer positive after reflection rejection")
        let finalStarts = try await g.resumedTaskCount(handle: h)
        try check(finalStarts == 2, "two requests exactly two starts")
        print("REFLECTION_GATEWAY \(mode) reads=2 starts=2 unknown=1 completed=1 retry=0 capacityReuse=true")
        Fixture.install([])
    }
}

func reflectionErrorChannels() async throws {
    for mode in ["http", "provider", "provider-sse", "malformed", "prefix-eof", "tool-eof", "tool-invalid"] {
        let credential = ReflectionCredential()
        let kind: FixedProtocol = mode.hasPrefix("provider") ? .openAI : .anthropic
        let streaming = ["provider-sse", "prefix-eof", "tool-eof", "tool-invalid"].contains(mode)
        let body: Data
        let expected: ModelTransportError
        switch mode {
        case "http":
            body = Data(credential.value.utf8)
            expected = .httpStatus(401)
        case "provider":
            body = Data(
                (try reflectionJSON([
                    "choices": [["message": ["content": credential.value], "finish_reason": "aborted"]]
                ])).utf8)
            expected = .providerFailure
        case "provider-sse":
            body = sse([
                try reflectionJSON(["choices": [["delta": ["content": credential.value], "finish_reason": "aborted"]]]),
                "[DONE]",
            ]).reduce(Data(), +)
            expected = .providerFailure
        case "malformed":
            body = Data(("invalid JSON " + credential.value).utf8)
            expected = .invalidResponse
        case "prefix-eof":
            body = sse(Array(try reflectionTextEvents([String(credential.value.prefix(12))]).prefix(3))).reduce(
                Data(), +)
            expected = .invalidResponse
        default:
            var events = toolEvents()
            events[2] = try reflectionJSON([
                "type": "content_block_delta", "index": 0,
                "delta": ["type": "input_json_delta", "partial_json": "{invalid " + credential.value],
            ])
            events = Array(events.prefix(3)) + (mode == "tool-invalid" ? [events[4]] : [])
            body = sse(events).reduce(Data(), +)
            expected = .invalidResponse
        }
        OpenReflectionProtocol.state.install(body, status: mode == "http" ? 401 : 200, finish: true)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OpenReflectionProtocol.self]
        let transport = ModelTransport(credentialProvider: credential, configuration: config)
        let request = try FixedModelRequest(
            model: .deepSeekFlash, protocol: kind, messages: [FixedMessage(role: .user, content: "fixture")],
            maxOutputTokens: 32)
        let op = try transport.prepare(request, streaming: streaming)
        try op.start()
        var chunks: [ModelStreamChunk] = []
        var rejected = false
        do { for try await chunk in op.chunks { chunks.append(chunk) } } catch let error as ModelTransportError {
            rejected = error == expected && !String(describing: error).contains(credential.value)
        }
        op.cancel()
        try check(
            rejected && !chunks.contains(where: \.isFinal)
                && chunks.allSatisfy {
                    if case .inputJSONDelta = $0.event { return false }
                    return $0.text.isEmpty
                }, "sanitized error/provisional argument suppression")
        try check(
            credential.reads == 1 && op.resumeCalls == 1
                && OpenReflectionProtocol.state.lock.withLock { OpenReflectionProtocol.state.arrivals } == 1,
            "error-channel reads/starts/arrivals")
        OpenReflectionProtocol.state.install(Data())
        print("REFLECTION_ERROR \(mode) rejected=true reads=1 starts=1 final=0 argumentFragments=0")
    }
}

func reflectionValidTools() async throws {
    let credential = ReflectionCredential()
    var events = toolEvents()
    let rawParts = [#"{"city":"\u5317"#, #"\u4eac","nested":{"list":["Bearer unrelated-public-word",7,true]}}"#]
    for index in 0..<2 {
        events[index + 2] = try reflectionJSON([
            "type": "content_block_delta", "index": 0,
            "delta": ["type": "input_json_delta", "partial_json": rawParts[index]],
        ])
    }
    Fixture.install([sse(events)])
    defer { Fixture.install([]) }
    let decoder = AnthropicStreamDecoder()
    let expected = try events.compactMap { try decoder.consume($0) }
    var actual: [ModelStreamChunk] = []
    let transport = ModelTransport(credentialProvider: credential, configuration: configuration())
    let operation = try transport.prepare(baseRequest(), streaming: true)
    try operation.start()
    for try await chunk in operation.chunks { actual.append(chunk) }
    try check(reflectionStateIsCleared(operation), "successful operation clears response guard")
    operation.cancel()
    try check(actual == expected, "validated tool events and exact raw fragments preserve full order and data")
    try check(
        actual.last?.completion?.blocks.first
            == .toolUse(
                id: "tool_1", name: "weather",
                input: .object([
                    "city": .string("北京"),
                    "nested": .object([
                        "list": .array([.string("Bearer unrelated-public-word"), .integer(7), .bool(true)])
                    ]),
                ])), "escaped positive tool arguments remain complete")
}

// Bool-only white-box lifetime assertion: no diagnostic credential accessor is
// added to production and no reflected values are formatted or retained.
private func reflectionStateIsCleared(_ operation: ModelPreparedOperation) -> Bool {
    guard let delegate = Mirror(reflecting: operation).children.first(where: { $0.label == "delegate" })?.value,
        let guardState = Mirror(reflecting: delegate).children.first(where: { $0.label == "reflection" })?.value
    else { return false }
    let fields = Dictionary(
        uniqueKeysWithValues: Mirror(reflecting: guardState).children.compactMap { child -> (String, Any)? in
            guard let name = child.label else { return nil }
            return (name, child.value)
        })
    guard let credential = fields["credential"], let tool = fields["toolIndex"] else { return false }
    return Mirror(reflecting: credential).children.isEmpty && Mirror(reflecting: tool).children.isEmpty
        && (fields["tail"] as? String)?.isEmpty == true && (fields["unstructuredText"] as? String)?.isEmpty == true
        && (fields["pending"] as? [ModelStreamChunk])?.isEmpty == true && fields["pendingBytes"] as? Int == 0
        && (fields["pattern"] as? [Unicode.Scalar])?.isEmpty == true && (fields["fallback"] as? [Int])?.isEmpty == true
        && fields["matched"] as? Int == 0
}

private final class OpenReflectionState: @unchecked Sendable {
    let lock = NSLock()
    var body = Data()
    var arrivals = 0
    var stops = 0
    var status = 200
    var finish = false
    func install(_ body: Data, status: Int = 200, finish: Bool = false) {
        lock.withLock {
            self.body = body
            arrivals = 0
            stops = 0
            self.status = status
            self.finish = finish
        }
    }
}
private final class OpenReflectionProtocol: URLProtocol {
    static let state = OpenReflectionState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (body, status, finish) = Self.state.lock.withLock {
            Self.state.arrivals += 1
            return (Self.state.body, Self.state.status, Self.state.finish)
        }
        client?.urlProtocol(
            self,
            didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        if finish { client?.urlProtocolDidFinishLoading(self) }
        // Intentionally no EOF and no success final.
    }
    override func stopLoading() { Self.state.lock.withLock { Self.state.stops += 1 } }
}
func reflectionEarlySafeText() async throws {
    let credential = ReflectionCredential()
    let prefix = String(credential.value.prefix(12))
    let ordinary = String(repeating: "ordinary ", count: 1000)
    let events = try reflectionTextEvents([ordinary + prefix])
    let body = Data(events.prefix(3).map { "data: \($0)\n\n" }.joined().utf8)
    OpenReflectionProtocol.state.install(body)
    defer { OpenReflectionProtocol.state.install(Data()) }
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [OpenReflectionProtocol.self]
    let transport = ModelTransport(credentialProvider: credential, configuration: config)
    let operation = try transport.prepare(baseRequest(), streaming: true)
    let emitted = Emissions()
    let audit = Audit()
    try operation.start()
    let task = Task {
        do { for try await chunk in operation.chunks { emitted.add(chunk, audit: audit) } } catch ModelTransportError
            .cancelled
        {}
    }
    for _ in 0..<500 {
        if emitted.snapshot.map(\.text).joined() == ordinary { break }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    let early = emitted.snapshot.map(\.text).joined() == ordinary
    operation.cancel()
    _ = await task.result
    try check(reflectionStateIsCleared(operation), "cancelled operation clears credential and pending output")
    try check(
        early && !emitted.snapshot.contains(where: \.isFinal),
        "safe text before withheld key-prefix must arrive before EOF")
    try check(
        credential.reads == 1 && operation.resumeCalls == 1
            && OpenReflectionProtocol.state.lock.withLock { OpenReflectionProtocol.state.arrivals } == 1,
        "early-stream actual counters")
}
