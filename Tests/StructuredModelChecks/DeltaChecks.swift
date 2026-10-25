import Foundation
import SandboxHost

func messageDelta(_ fields: String, output: Int) -> String {
    "{\"type\":\"message_delta\",\"delta\":{\(fields)},\"usage\":{\"output_tokens\":\(output)}}"
}
func deltaEvents(_ deltas: [String]) -> [String] {
    [toolEvents()[0]] + deltas + [#"{"type":"message_stop"}"#]
}
func collectDeltaStream(_ events: [String]) async throws -> [ModelStreamChunk] {
    Fixture.install([sse(events)])
    let credentials = Credential()
    let transport = ModelTransport(credentialProvider: credentials, configuration: configuration())
    var chunks: [ModelStreamChunk] = []
    for try await chunk in transport.stream(try baseRequest()) { chunks.append(chunk) }
    try check(credentials.reads == 1 && Fixture.requests.count == 1, "single synthetic delta dispatch")
    return chunks
}
func deltaMetadata(_ chunks: [ModelStreamChunk]) -> [ModelMetadata] {
    chunks.compactMap { if case .messageDelta(let metadata) = $0.event { return metadata }; return nil }
}
func multipleToolDeltas() -> [String] {
    Array(toolEvents().prefix(5)) + [
        messageDelta(#""stop_reason":"tool_use""#, output: 1),
        messageDelta(#""stop_reason":"tool_use""#, output: 2),
        messageDelta("", output: 3),
        messageDelta(#""stop_reason":null,"stop_sequence":null"#, output: 4),
        #"{"type":"message_stop"}"#
    ]
}
func nullableDeltaControls() async throws {
    let chunks = try await collectDeltaStream(deltaEvents([
        messageDelta(#""stop_reason":null,"stop_sequence":null"#, output: 0),
        messageDelta(#""stop_sequence":"END""#, output: 1),
        messageDelta(#""stop_reason":null,"stop_sequence":null"#, output: 2),
        messageDelta(#""stop_reason":"stop_sequence""#, output: 3),
        messageDelta(#""stop_reason":"stop_sequence","stop_sequence":"END""#, output: 4),
        messageDelta(#""stop_reason":null,"stop_sequence":null"#, output: 5),
        #"{"type":"message_delta","delta":{}}"#
    ]))
    let metadata = deltaMetadata(chunks)
    try check(metadata.map(\.stopReason) == [nil, nil, nil, "stop_sequence", "stop_sequence", "stop_sequence", "stop_sequence"], "null is no-update before and after known reason")
    try check(metadata.map(\.stopSequence) == [nil, "END", "END", "END", "END", "END", "END"], "null and absence never erase known sequence; identical sequence repeats")
    try check(metadata.map { $0.usage?.outputTokens } == [0, 1, 2, 3, 4, 5, 5], "cumulative usage survives absent usage")
    try check(metadata.allSatisfy { $0.messageID == "msg_1" && $0.model == "deepseek-flash" && $0.usage?.inputTokens == 12 }, "identity and omitted input usage retained")
    try check(chunks.last?.completion?.metadata == metadata.last && chunks.filter(\.isFinal).count == 1, "merged nullable final")
}
func deltaLimitControl() async throws {
    let chunks = try await collectDeltaStream(deltaEvents((1...128).map {
        messageDelta(#""stop_reason":"end_turn""#, output: $0)
    }))
    try check(deltaMetadata(chunks).count == 128 && chunks.last?.completion?.metadata.usage?.outputTokens == 128 && chunks.filter(\.isFinal).count == 1, "exactly 128 compatible metadata deltas accepted")
}
func deltaRejections() async throws {
    let first = messageDelta(#""stop_reason":"end_turn""#, output: 2)
    let cases: [(String, [String], ModelTransportError)] = [
        ("conflicting reason", deltaEvents([first, messageDelta(#""stop_reason":"max_tokens""#, output: 3)]), .malformedSSE),
        ("conflicting sequence before reason", deltaEvents([messageDelta(#""stop_sequence":"END""#, output: 1), messageDelta(#""stop_sequence":"OTHER""#, output: 2), first]), .malformedSSE),
        ("conflicting sequence after reason", deltaEvents([messageDelta(#""stop_reason":"stop_sequence","stop_sequence":"END""#, output: 1), messageDelta(#""stop_sequence":"OTHER""#, output: 2)]), .malformedSSE),
        ("output rollback", deltaEvents([first, messageDelta("", output: 1)]), .malformedSSE),
        ("input rollback", deltaEvents([first, #"{"type":"message_delta","delta":{},"usage":{"input_tokens":11}}"#]), .malformedSSE),
        ("aborted after stop metadata", deltaEvents([first, messageDelta(#""stop_reason":"aborted""#, output: 3)]), .providerFailure),
        ("insufficient resources after stop metadata", deltaEvents([first, messageDelta(#""stop_reason":"insufficient_system_resource""#, output: 3)]), .providerFailure),
        ("provider error after stop metadata", deltaEvents([first, #"{"type":"error","error":{"type":"overloaded_error"}}"#]), .providerFailure),
        ("129 deltas", deltaEvents((1...129).map { messageDelta(#""stop_reason":"end_turn""#, output: $0) }), .malformedSSE),
        ("EOF after repeated stop metadata", Array(deltaEvents([first, first]).dropLast()), .invalidResponse),
        ("null without known reason", deltaEvents([messageDelta(#""stop_reason":null,"stop_sequence":null"#, output: 1)]), .malformedSSE)
    ]
    var failures: [String] = []
    for (name, events, expected) in cases {
        Fixture.install([sse(events)])
        let credentials = Credential()
        let transport = ModelTransport(credentialProvider: credentials, configuration: configuration())
        var chunks: [ModelStreamChunk] = []; var received: ModelTransportError?
        do { for try await chunk in transport.stream(try baseRequest()) { chunks.append(chunk) } }
        catch let error as ModelTransportError { received = error }
        do {
            try check(received == expected, "expected \(expected), received \(String(describing: received))")
            try check(!chunks.contains(where: \.isFinal), "invalid delta stream exposed success final")
            try check(credentials.reads == 1 && Fixture.requests.count == 1, "no retry or extra credential read")
            print("Delta negative PASS \(name)")
        } catch { failures.append("\(name): \(error)") }
    }
    print("Delta negative cases: \(cases.count); failures: \(failures.count)")
    try check(failures.isEmpty, failures.joined(separator: "; "))
}
func repeatedStopDelta() async throws {
    let chunks = try await collectDeltaStream(deltaEvents([
        messageDelta(#""stop_reason":"end_turn""#, output: 1),
        messageDelta(#""stop_reason":"end_turn""#, output: 2)
    ]))
    let metadata = deltaMetadata(chunks)
    try check(metadata.map(\.stopReason) == ["end_turn", "end_turn"] && metadata.map { $0.usage?.outputTokens } == [1, 2], "identical stop reason permits cumulative usage")
    try check(chunks.filter(\.isFinal).count == 1 && chunks.last?.completion?.metadata == metadata.last, "final preserves merged repeated stop")
}
func reasonThenUsageDelta() async throws {
    let chunks = try await collectDeltaStream(deltaEvents([
        messageDelta(#""stop_reason":"end_turn""#, output: 1),
        messageDelta("", output: 2)
    ]))
    try check(deltaMetadata(chunks).map(\.stopReason) == ["end_turn", "end_turn"], "usage-only delta preserves known stop reason")
    try check(chunks.last?.completion?.metadata.usage?.outputTokens == 2 && chunks.filter(\.isFinal).count == 1, "usage-only update reaches final")
}
func sequenceBeforeReasonDelta() async throws {
    let chunks = try await collectDeltaStream(deltaEvents([
        messageDelta(#""stop_sequence":"END""#, output: 1),
        messageDelta(#""stop_reason":"stop_sequence""#, output: 2)
    ]))
    try check(deltaMetadata(chunks).map(\.stopSequence) == ["END", "END"], "omitted stop_sequence erased previously received END")
    try check(chunks.last?.completion?.metadata.stopSequence == "END" && chunks.last?.completion?.metadata.stopReason == "stop_sequence", "final retains earlier sequence and later reason")
}
