import Foundation
import SandboxHost
import SandboxContracts

func toolDefinition() throws -> ModelToolDefinition {
    try ModelToolDefinition(name: "weather", description: "Synthetic schema, never executed", inputSchema: .object(["type": .string("object"), "properties": .object(["city": .object(["type": .string("string")])]), "required": .array([.string("city")])]))
}
func toolRequest(_ messages: [FixedMessage]? = nil) throws -> FixedModelRequest {
    try FixedModelRequest(model: .deepSeekFlash, protocol: .anthropic, messages: messages ?? baseRequest().messages, maxOutputTokens: 32, tools: [toolDefinition()], toolChoice: ModelToolChoice(type: .auto, disableParallelToolUse: true))
}
func body(_ request: URLRequest) throws -> ModelJSON {
    var data = request.httpBody ?? Data()
    if data.isEmpty, let stream = request.httpBodyStream {
        stream.open(); defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            guard n >= 0 else { throw Failure.check("body stream") }
            if n == 0 { break }; data.append(contentsOf: buffer.prefix(n))
        }
    }
    return try ModelJSON.parse(data)
}
func finalEvents() -> [String] {
    [
        toolEvents()[0].replacingOccurrences(of: "msg_1", with: "msg_2"),
        #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
        #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"晴天"}}"#,
        #"{"type":"content_block_stop","index":0}"#,
        #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}"#,
        #"{"type":"message_stop"}"#
    ]
}
let finalReply = #"{"id":"msg_2","type":"message","role":"assistant","model":"deepseek-flash","content":[{"type":"text","text":"晴天"}],"stop_reason":"end_turn","usage":{"input_tokens":20,"output_tokens":3}}"#
final class Emissions: @unchecked Sendable {
    let lock = NSLock(); var chunks: [ModelStreamChunk] = []; var premature = false
    func add(_ chunk: ModelStreamChunk, audit: Audit) {
        lock.withLock { chunks.append(chunk); if chunk.isTerminal && !audit.snapshot.contains(where: { $0.reason == "dispatch-completion" }) { premature = true } }
    }
    var snapshot: [ModelStreamChunk] { lock.withLock { chunks } }
}
func roundTrip(streaming: Bool, multiple: Bool) async throws {
    var events = toolEvents()
    var reply = try ModelJSON.parse(Data(toolReply.utf8)).object!
    if multiple {
        let second = Array(events[1...4]).map { $0.replacingOccurrences(of: #""index":0"#, with: #""index":1"#).replacingOccurrences(of: "tool_1", with: "tool_2") }
        events.insert(contentsOf: second, at: 5)
        reply["content"] = .array(reply["content"]!.array! + [.object(["type": .string("tool_use"), "id": .string("tool_2"), "name": .string("weather"), "input": .object(["city": .string("北京")])])])
    }
    Fixture.install(streaming ? [sse(events), sse(finalEvents())] : [[try JSONEncoder().encode(ModelJSON.object(reply))], [Data(finalReply.utf8)]])
    let credential = Credential(); let audit = Audit(); let emissions = Emissions()
    let (g, h, id) = try await gateway(credential, audit, streaming: streaming)
    var request = try toolRequest()
    let proposal = try await g.propose(handle: h, connectionID: id, request: request, streaming: streaming)
    request = try FixedModelRequest(model: .deepSeekFlash, protocol: .anthropic, messages: [FixedMessage(role: .user, content: "mutated")], maxOutputTokens: 1)
    let approval = try await g.hostApprove(handle: h, proposal: proposal)
    try check(credential.reads == 0 && Fixture.requests.isEmpty, "approval has no credential or dispatch")
    let first = try await g.execute(handle: h, approval: approval) { emissions.add($0, audit: audit) }
    try check(first.blocks.count == (multiple ? 2 : 1) && first.metadata.stopReason == "tool_use", "tool-only/multi-tool result")
    let results = try first.blocks.map { block -> ModelBlock in
        guard case .toolUse(let id, _, _) = block else { throw Failure.check("expected tool use") }
        return .toolResult(toolUseID: id, content: "synthetic result", isError: true)
    }
    let continuation = try toolRequest(baseRequest().messages + [FixedMessage(role: .assistant, blocks: first.blocks), FixedMessage(role: .user, blocks: results)])
    let p2 = try await g.propose(handle: h, connectionID: id, request: continuation, streaming: streaming)
    let a2 = try await g.hostApprove(handle: h, proposal: p2)
    let final = try await g.execute(handle: h, approval: a2) { emissions.add($0, audit: audit) }
    try check(final.text == "晴天" && final.metadata.messageID == "msg_2" && final.metadata.stopReason == "end_turn", "tool result to final text")
    let sent = try Fixture.requests.map(body)
    try check(sent[0]["tools"]?.array?.first?["input_schema"] == toolDefinition().inputSchema, "actual schema encoded")
    try check(sent[0]["tool_choice"]?["disable_parallel_tool_use"] == .bool(true), "wire flag preserved without provider guarantee")
    try check(sent[0]["messages"]?.array?.first?["content"]?.string == "weather", "immutable approved values, not mutated request")
    try check(sent[1]["messages"]?.array?.last?["content"]?.array?.first?["is_error"] == .bool(true), "tool result wire field preserved")
    try check(credential.reads == 2 && Fixture.requests.count == 2 && audit.snapshot.filter { $0.reason == "dispatch-completion" }.count == 2, "two authorized reads/dispatches/completions")
    if streaming {
        try check(emissions.snapshot.filter(\.isFinal).count == 2 && emissions.snapshot.filter(\.isTerminal).count == 4 && !emissions.premature, "all terminal metadata follows audit")
    }
    _ = request
}
func openAIRejectStructured() async throws {
    let request = try FixedModelRequest(model: .deepSeekFlash, protocol: .openAI, messages: baseRequest().messages, maxOutputTokens: 32)
    for payload in [#"{"choices":[{"message":{"content":"ok","tool_calls":[{"id":"x"}]}}]}"#, #"{"choices":[{"delta":{"content":"ok","tool_calls":[{"id":"x"}]}}]}"#, #"{"choices":[{"delta":{"content":[{"type":"text","text":"hidden"}]}}]}"#] {
        let streaming = payload.contains("delta")
        Fixture.install([streaming ? sse([payload, "[DONE]"]) : [Data(payload.utf8)]])
        let transport = ModelTransport(credentialProvider: Credential(), configuration: configuration())
        do {
            if streaming { for try await _ in transport.stream(request) {} } else { _ = try await transport.complete(request) }
            throw Failure.check("structured OpenAI reply silently dropped")
        } catch is ModelTransportError {}
    }
}
func jsonAndPairingChecks() async throws {
    for extra in [#""unexpected":true"#, #""tools":[{"name":"weather","input_schema":{"type":"object"},"cache_control":{"type":"ephemeral"}}]"#] {
        let raw = #"{"model":"deepseek-flash","protocol":"anthropic","messages":[{"role":"user","content":"hi"}],"maxOutputTokens":1,"# + extra + "}"
        do { _ = try FixedModelRequest.decodeValidated(Data(raw.utf8)); throw Failure.check("unsupported request fields dropped") } catch is ModelTransportError {}
    }
    let invalid = [#"{"x":1,"\u0078":2}"#, #"{"x":{"a":1,"a":2}}"#, "9007199254740992", "-9007199254740992", "1.0", "1e2", "NaN", "Infinity", "-0", "01", #""\uD800""#, String(repeating: "[", count: 34) + "0" + String(repeating: "]", count: 34), "\"" + String(repeating: "x", count: 65_536) + "\""]
    for raw in invalid {
        do { _ = try ModelJSON.parse(Data(raw.utf8)); throw Failure.check("invalid JSON admitted: \(raw.prefix(30))") } catch is ModelTransportError {}
    }
    for raw in ["9007199254740991", "-9007199254740991", #"{"identifier":"9007199254740993123456789"}"#] {
        let value = try ModelJSON.parse(Data(raw.utf8))
        try check(try ModelJSON.parse(JSONEncoder().encode(value)) == value, "supported exact domain roundtrip")
    }
    let use = ModelBlock.toolUse(id: "t1", name: "weather", input: .object([:]))
    let result = ModelBlock.toolResult(toolUseID: "t1", content: "ok", isError: false)
    let histories: [[FixedMessage]] = try [
        [FixedMessage(role: .assistant, blocks: [use])],
        baseRequest().messages + [FixedMessage(role: .assistant, blocks: [use])],
        baseRequest().messages + [FixedMessage(role: .assistant, blocks: [use, use]), FixedMessage(role: .user, blocks: [result])],
        baseRequest().messages + [FixedMessage(role: .assistant, blocks: [use]), FixedMessage(role: .user, blocks: [result, result])],
        baseRequest().messages + [FixedMessage(role: .assistant, blocks: [use]), FixedMessage(role: .user, blocks: [.toolResult(toolUseID: "wrong", content: "x", isError: false)])],
        baseRequest().messages + [FixedMessage(role: .user, blocks: [result])]
    ]
    for history in histories {
        do { _ = try toolRequest(history); throw Failure.check("bad role/pairing accepted") } catch is ModelTransportError {}
    }
    do { _ = try FixedModelRequest(model: .deepSeekFlash, protocol: .openAI, messages: baseRequest().messages, maxOutputTokens: 1, tools: [toolDefinition()]); throw Failure.check("structured OpenAI request") } catch is ModelTransportError {}
}
func malformedStreams() async throws {
    let good = toolEvents()
    var badIndex = good; badIndex[2] = badIndex[2].replacingOccurrences(of: #""index":0"#, with: #""index":1"#)
    var partial = good; partial.remove(at: 3)
    var duplicate = good; duplicate.insert(good[1], at: 2)
    var noBlockStop = good; noBlockStop.remove(at: 4)
    var providerError = good; providerError.insert(#"{"type":"error","error":{"type":"overloaded_error"}}"#, at: 5)
    var unsupported = good; unsupported[1] = #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"hidden"}}"#
    for events in [badIndex, partial, duplicate, noBlockStop, providerError, unsupported, Array(good.dropLast()), Array(good.dropFirst()), [good[0], good[2], good[6]]] {
        Fixture.install([sse(events)])
        let t = ModelTransport(credentialProvider: Credential(), configuration: configuration())
        var finals = 0
        do { for try await c in t.stream(try baseRequest()) { if c.isFinal { finals += 1 } }; throw Failure.check("malformed stream accepted") } catch is ModelTransportError {}
        try check(finals == 0, "no final after malformed stream")
    }
}
