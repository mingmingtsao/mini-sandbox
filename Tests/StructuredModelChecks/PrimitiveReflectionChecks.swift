import Foundation
import SandboxContracts
import SandboxHost

// Public, fixed synthetic examples retain the human regression. Never use real
// credentials here; runtime evidence prints only static labels/counts/booleans.
private final class PrimitiveCredential: ModelCredentialProvider, @unchecked Sendable {
    let value: String
    private let lock = NSLock()
    private var count = 0
    init(_ value: String) { self.value = value }
    func credential(for model: FixedModel) throws -> String {
        lock.withLock { count += 1 }
        return value
    }
    var reads: Int { lock.withLock { count } }
}
private struct PrimitiveCase {
    let name: String
    let key: String
    let raw: String
    var usageStart = false
    var usageDelta = false
    var rawOnly = false
}
private let primitiveCases: [PrimitiveCase] = [
    .init(name: "string-contrast", key: "424242", raw: #"{"value":"424242"}"#),
    .init(name: "integer", key: "424242", raw: #"{"value":424242}"#),
    .init(name: "negative-integer", key: "-424242", raw: #"{"value":-424242}"#),
    .init(name: "integer-zero", key: "0", raw: #"{"value":0}"#),
    .init(name: "integer-safe-bound", key: "9007199254740991", raw: #"{"value":9007199254740991}"#),
    .init(name: "integer-substring", key: "4242", raw: #"{"value":14242421}"#),
    .init(name: "boolean-true", key: "true", raw: #"{"value":true}"#),
    .init(name: "boolean-false", key: "false", raw: #"{"value":false}"#),
    .init(name: "null", key: "null", raw: #"{"value":null}"#),
    .init(name: "nested-integer", key: "424242", raw: #"{"outer":[{"inner":[false,null,424242]}]}"#),
    .init(name: "nested-true", key: "true", raw: #"{"outer":[{"inner":[null,true]}]}"#),
    .init(name: "nested-false", key: "false", raw: #"{"outer":[{"inner":[null,false]}]}"#),
    .init(name: "nested-null", key: "null", raw: #"{"outer":[{"inner":[true,null]}]}"#),
    .init(name: "usage-start", key: "424242", raw: #"{"value":7}"#, usageStart: true),
    .init(name: "usage-delta-final", key: "424242", raw: #"{"value":7}"#, usageDelta: true),
    .init(name: "raw-escaped-lexeme", key: #"\u0061"#, raw: #"{"value":"\u0061"}"#, rawOnly: true),
    .init(name: "raw-syntax-span", key: #"value":42"#, raw: #"{"value":424242}"#, rawOnly: true),
    .init(name: "raw-whitespace-span", key: ":  42", raw: #"{"value":  424242}"#, rawOnly: true),
]
private func primitiveJSON(_ object: Any) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
}
private func primitiveEvents(_ c: PrimitiveCase) throws -> [String] {
    var events = toolEvents()
    // Avoid an incidental zero usage reflection in the tool-integer-zero case.
    events[0] = events[0].replacingOccurrences(of: "\"output_tokens\":0", with: "\"output_tokens\":3")
    if c.usageStart {
        events[0] = events[0].replacingOccurrences(of: "\"input_tokens\":12", with: "\"input_tokens\":424242")
    }
    if c.usageDelta {
        events[5] = events[5].replacingOccurrences(of: "\"output_tokens\":9", with: "\"output_tokens\":424242")
    }
    // Split within the reflected literal when present, otherwise within JSON.
    let middle: String.Index
    if let range = c.raw.range(of: c.key), c.key.count > 1 {
        middle = c.raw.index(range.lowerBound, offsetBy: c.key.count / 2)
    } else {
        middle = c.raw.index(c.raw.startIndex, offsetBy: c.raw.count / 2)
    }
    let parts = [String(c.raw[..<middle]), String(c.raw[middle...])]
    for index in 0..<2 {
        events[index + 2] = try primitiveJSON([
            "type": "content_block_delta", "index": 0,
            "delta": ["type": "input_json_delta", "partial_json": parts[index]],
        ])
    }
    return events
}
private func primitiveBody(_ c: PrimitiveCase) -> Data {
    let input = c.usageStart ? 424242 : 12
    let output = c.usageDelta ? 424242 : 9
    return Data(
        "{\"id\":\"msg_fixture\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"deepseek-flash\",\"content\":[{\"type\":\"tool_use\",\"id\":\"tool_fixture\",\"name\":\"weather\",\"input\":\(c.raw)}],\"stop_reason\":\"tool_use\",\"usage\":{\"input_tokens\":\(input),\"output_tokens\":\(output)}}"
            .utf8)
}
private func primitiveExposed(_ chunks: [ModelStreamChunk], key: String) throws -> Bool {
    func metadata(_ m: ModelMetadata) -> Bool {
        (m.usage?.values.contains { $0.key.contains(key) || String($0.value).contains(key) } ?? false)
            || [m.messageID, m.model, m.stopReason, m.stopSequence, m.usage?.serviceTier?.rawValue].compactMap { $0 }
                .contains { $0.contains(key) }
    }
    func block(_ b: ModelBlock) throws -> Bool {
        String(decoding: try JSONEncoder().encode(b.wire), as: UTF8.self).contains(key)
    }
    func completion(_ c: ModelCompletion) throws -> Bool {
        try metadata(c.metadata) || c.text.contains(key) || c.blocks.contains(where: block)
    }
    var raw = ""
    for chunk in chunks {
        if chunk.text.contains(key) { return true }
        if let c = chunk.completion, try completion(c) { return true }
        switch chunk.event {
        case .messageStart(let m), .messageDelta(let m): if metadata(m) { return true }
        case .blockStart(_, let b), .blockStop(_, let b): if try block(b) { return true }
        case .messageStop(let c): if try completion(c) { return true }
        case .inputJSONDelta(_, let part): raw += part
        case .textDelta(_, let text): if text.contains(key) { return true }
        case nil: break
        }
    }
    return raw.contains(key) || chunks.map(\.text).joined().contains(key)
}
private func primitiveToolReleased(_ chunks: [ModelStreamChunk]) -> Bool {
    chunks.contains { chunk in
        switch chunk.event {
        case .blockStart(_, .toolUse), .blockStop(_, .toolUse), .inputJSONDelta: return true
        default: return false
        }
    }
}

func primitiveReflectionTransport(streaming: Bool) async throws {
    var failures = 0
    for c in primitiveCases where streaming || !c.rawOnly {
        let events = try primitiveEvents(c)
        let expected = try AnthropicResponse.decode(primitiveBody(c))
        let decoder = AnthropicStreamDecoder()
        let decoded = try events.compactMap { try decoder.consume($0) }
        try check(
            decoded.last?.completion != nil && expected.blocks.count == 1, "primitive fixture is valid in actual codecs"
        )
        Fixture.install([streaming ? sse(events) : [primitiveBody(c)]])
        let credential = PrimitiveCredential(c.key)
        let transport = ModelTransport(credentialProvider: credential, configuration: configuration())
        let op = try transport.prepare(baseRequest(), streaming: streaming)
        try op.start()
        var chunks: [ModelStreamChunk] = []
        var rejected = false
        do { for try await chunk in op.chunks { chunks.append(chunk) } } catch let error as ModelTransportError {
            rejected = error == .invalidResponse
        }
        let leaked = try primitiveExposed(chunks, key: c.key)
        let toolReleased = primitiveToolReleased(chunks)
        let pass =
            rejected && !leaked && !chunks.contains(where: \.isFinal) && (c.usageStart || c.usageDelta || !toolReleased)
            && credential.reads == 1 && op.resumeCalls == 1 && Fixture.requests.count == 1
        op.cancel()
        Fixture.install([])
        if !pass { failures += 1 }
        print(
            "CR01_TRANSPORT \(streaming ? "sse" : "nonstream") \(c.name) rejected=\(rejected) leaked=\(leaked) toolReleased=\(toolReleased) reads=\(credential.reads) starts=\(op.resumeCalls) pass=\(pass)"
        )
    }
    try check(failures == 0, "primitive reflection rejected before transport release")
}

func primitiveReflectionGateway(failedAudit: Bool) async throws {
    var failures = 0
    for streaming in [false, true] {
        for c in primitiveCases where streaming || !c.rawOnly {
            Fixture.install([streaming ? sse(try primitiveEvents(c)) : [primitiveBody(c)]])
            let credential = PrimitiveCredential(c.key)
            let audit = Audit()
            audit.fail = failedAudit
            let barrier = AuditBarrier()
            audit.barrier = barrier
            let emitted = Emissions()
            let (g, h, id) = try await gateway(credential, audit, streaming: streaming)
            let p = try await g.propose(handle: h, connectionID: id, request: baseRequest(), streaming: streaming)
            let a = try await g.hostApprove(handle: h, proposal: p)
            let task = Task { try await g.execute(handle: h, approval: a) { emitted.add($0, audit: audit) } }
            for _ in 0..<1000 {
                if barrier.isEntered { break }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            // Observe the irreversible callback boundary BEFORE a later audit
            // failure can conceal that a raw argument or usage value escaped.
            let reached = barrier.isEntered
            let earlyLeak = try primitiveExposed(emitted.snapshot, key: c.key)
            let earlyTool = primitiveToolReleased(emitted.snapshot)
            let beforeAudit = audit.snapshot.map(\.reason) == ["dispatch-intent"]
            barrier.release()
            let result = await task.result
            let rejected: Bool
            switch result {
            case .success: rejected = false
            case .failure(let error):
                rejected = error as? HostModelGatewayError == (failedAudit ? .auditFailed : .outcomeUnknown)
            }
            let starts = try await g.resumedTaskCount(handle: h)
            let completions = audit.snapshot.filter { $0.reason == "dispatch-completion" }
            let auditOK =
                failedAudit ? completions.isEmpty : completions.count == 1 && completions.first?.outcome == .unknown
            var replayDenied = false
            do { _ = try await g.execute(handle: h, approval: a) } catch AuthorizationError.ticketAlreadyConsumed {
                replayDenied = !failedAudit
            } catch HostModelGatewayError.revoked { replayDenied = failedAudit }
            let finalLeak = try primitiveExposed(emitted.snapshot, key: c.key)
            let pass =
                reached && beforeAudit && rejected && !earlyLeak && (c.usageStart || c.usageDelta || !earlyTool)
                && !finalLeak && !emitted.snapshot.contains(where: \.isTerminal) && auditOK && replayDenied
                && credential.reads == 1 && starts == 1 && Fixture.requests.count == 1
            if !pass { failures += 1 }
            print(
                "CR01_GATEWAY \(failedAudit ? "failed-audit" : "durable-audit") \(streaming ? "sse" : "nonstream") \(c.name) reached=\(reached) earlyLeak=\(earlyLeak) earlyTool=\(earlyTool) rejected=\(rejected) auditOK=\(auditOK) reads=\(credential.reads) starts=\(starts) replayDenied=\(replayDenied) pass=\(pass)"
            )
            Fixture.install([])
        }
    }
    try check(failures == 0, "primitive gateway return and pre-audit emission boundaries")
}

func primitiveReflectionPositiveControls() async throws {
    let raw = #"{ "nested" : [{"value":[-7,0,7,9007199254740991,true,false,null,"\u0061"]}] }"#
    let controls = [
        PrimitiveCase(name: "ordinary", key: "424242", raw: raw),
        PrimitiveCase(name: "local-final-flag", key: "true", raw: #"{"value":false}"#),
        PrimitiveCase(name: "local-nonfinal-flag", key: "false", raw: #"{"value":true}"#),
        PrimitiveCase(name: "absent-metadata", key: "null", raw: #"{"value":7}"#),
        PrimitiveCase(name: "local-block-index", key: "0", raw: #"{"value":7}"#),
    ]
    for c in controls {
        for streaming in [false, true] {
            let events = try primitiveEvents(c)
            Fixture.install([streaming ? sse(events) : [primitiveBody(c)]])
            let credential = PrimitiveCredential(c.key)
            let audit = Audit()
            let emitted = Emissions()
            let (g, h, id) = try await gateway(credential, audit, streaming: streaming)
            let p = try await g.propose(handle: h, connectionID: id, request: baseRequest(), streaming: streaming)
            let a = try await g.hostApprove(handle: h, proposal: p)
            let result = try await g.execute(handle: h, approval: a) { emitted.add($0, audit: audit) }
            if streaming {
                let decoder = AnthropicStreamDecoder()
                let expected = try events.compactMap { try decoder.consume($0) }
                try check(
                    emitted.snapshot == expected && result == expected.last?.completion,
                    "ordinary primitives and raw fragments retain exact types, bytes and order")
            } else {
                try check(
                    result == AnthropicResponse.decode(primitiveBody(c)), "ordinary primitive DTO remains unchanged")
            }
            try check(
                audit.snapshot.last?.outcome == .completed && credential.reads == 1 && Fixture.requests.count == 1,
                "ordinary primitives complete once")
            print("CR01_POSITIVE \(c.name) \(streaming ? "sse" : "nonstream") exact=true reads=1 ingress=1 completed=1")
            Fixture.install([])
        }
    }
    // Integer tokens accepted by RawJSON are already canonical. Do not invent
    // decimal/exponent/negative-zero reflection cases that cannot reach output.
    for raw in [#"{"v":1.0}"#, #"{"v":1e2}"#, #"{"v":-0}"#, #"{"v":01}"#] {
        do {
            _ = try ModelJSON.parse(Data(raw.utf8))
            throw Failure.check("unsupported numeric grammar accepted")
        } catch ModelTransportError.invalidResponse {}
    }
}
