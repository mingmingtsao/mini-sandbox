import Foundation
import SandboxHost

private let metadataMutations: [(String, String, ModelJSON?)] = [
    ("wrong type", "type", .string("response")),
    ("missing type", "type", nil),
    ("wrong role", "role", .string("user")),
    ("missing role", "role", nil),
    ("missing id", "id", nil),
    ("empty id", "id", .string("")),
    ("control id", "id", .string("opaque\nid")),
    ("space id", "id", .string("opaque id")),
    ("nonASCII id", "id", .string("opaque中")),
    ("oversized id", "id", .string(String(repeating: "i", count: 129))),
    ("missing model", "model", nil),
    ("empty model", "model", .string("")),
    ("C0 model", "model", .string("private-body-marker\nmodel")),
    ("DEL model", "model", .string("model\u{7f}")),
    ("C1 model", "model", .string("model\u{85}")),
    ("oversized model", "model", .string(String(repeating: "m", count: 257))),
    ("missing usage", "usage", nil),
    ("empty usage", "usage", .object([:])),
    ("missing input tokens", "usage", .object(["output_tokens": .integer(0)])),
    ("missing output tokens", "usage", .object(["input_tokens": .integer(0)])),
    ("negative input tokens", "usage", .object(["input_tokens": .integer(-1), "output_tokens": .integer(0)])),
    ("negative output tokens", "usage", .object(["input_tokens": .integer(0), "output_tokens": .integer(-1)])),
]

func metadataRejections(streaming: Bool) async throws {
    let source = try ModelJSON.parse(Data((streaming ? toolEvents()[0] : toolReply).utf8))
    let original = streaming ? source["message"]!.object! : source.object!
    var mutations = metadataMutations
    if !streaming {
        mutations += [
            ("wrong stop reason", "stop_reason", .string("end_turn")), ("missing stop reason", "stop_reason", nil),
        ]
    }
    var failures: [String] = []
    for (name, key, value) in mutations {
        var body = original
        body[key] = value
        let raw: Data
        if streaming {
            var start = source.object!
            start["message"] = .object(body)
            var events = toolEvents()
            events[0] = String(decoding: try JSONEncoder().encode(ModelJSON.object(start)), as: UTF8.self)
            raw = Data(events.map { "data: \($0)\n\n" }.joined().utf8)
        } else {
            raw = try JSONEncoder().encode(ModelJSON.object(body))
        }
        Fixture.install([[raw]])
        let credential = Credential()
        let transport = ModelTransport(credentialProvider: credential, configuration: configuration())
        let operation = try transport.prepare(baseRequest(), streaming: streaming)
        var chunks: [ModelStreamChunk] = []
        var receivedError: ModelTransportError?
        do {
            try operation.start()
            for try await chunk in operation.chunks { chunks.append(chunk) }
        } catch let error as ModelTransportError { receivedError = error }
        operation.cancel()
        do {
            try check(receivedError != nil, "accepted invalid metadata")
            try check(chunks.isEmpty, "invalid body exposed metadata, blocks or success final")
            try check(
                receivedError == .invalidResponse || (streaming && receivedError == .malformedSSE),
                "meaningful metadata error")
            let description = String(describing: receivedError!)
            try check(
                description == "invalid upstream response" || description == "malformed upstream SSE",
                "sanitized error without raw body")
            try check(!description.contains("private-body-marker"), "raw model leaked")
            try check(credential.reads == 1 && Fixture.requests.count == 1, "single synthetic dispatch")
        } catch { failures.append("\(name): \(error)") }
    }
    print("Metadata \(streaming ? "SSE" : "completion") cases: \(mutations.count); failures: \(failures.count)")
    try check(failures.isEmpty, failures.joined(separator: "; "))
}

func metadataCompatibility() async throws {
    // Opaque IDs do not need an Anthropic prefix; exact bounds remain valid.
    var body = try ModelJSON.parse(Data(toolReply.utf8)).object!
    body["id"] = .string(String(repeating: "x", count: 128))
    body["model"] = .string(String(repeating: "m", count: 256))
    body["usage"] = .object(["input_tokens": .integer(0), "output_tokens": .integer(0)])
    Fixture.install([[try JSONEncoder().encode(ModelJSON.object(body))]])
    let transport = ModelTransport(credentialProvider: Credential(), configuration: configuration())
    let completion = try await transport.complete(baseRequest())
    try check(
        completion.metadata.messageID == body["id"]?.string && completion.metadata.model == body["model"]?.string
            && completion.metadata.usage?.inputTokens == 0 && completion.metadata.usage?.outputTokens == 0,
        "valid bounded full tool completion")
    Fixture.install([[Data(#"{"content":[{"type":"text","text":"legacy"}]}"#.utf8)]])
    let legacy = try await transport.complete(baseRequest())
    try check(
        legacy.text == "legacy" && legacy.metadata == ModelMetadata(), "legacy text-only missing metadata remains valid"
    )
    body["content"] = .array([])
    body["stop_reason"] = .null
    let start = try JSONEncoder().encode(
        ModelJSON.object(["type": .string("message_start"), "message": .object(body)]))
    Fixture.install([
        sse([
            String(decoding: start, as: UTF8.self),
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":0}}"#,
            #"{"type":"message_stop"}"#,
        ])
    ])
    var chunks: [ModelStreamChunk] = []
    for try await chunk in transport.stream(try baseRequest()) { chunks.append(chunk) }
    try check(
        chunks.count == 3 && chunks.filter(\.isFinal).count == 1 && chunks.last?.completion?.blocks == []
            && chunks.last?.completion?.metadata.messageID == body["id"]?.string,
        "valid empty full SSE with bounded opaque identity")
}
