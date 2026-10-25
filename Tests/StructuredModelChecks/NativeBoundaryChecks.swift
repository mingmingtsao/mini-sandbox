import Foundation
import SandboxHost
import SandboxContracts

func nativeBytes(_ object: [String: ModelJSON]) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(ModelJSON.object(object))
}
func nativePending(_ proposal: HostModelProposal) throws -> PendingAction {
    // Test-only inspection of immutable approval storage; no production export.
    guard let pending = Mirror(reflecting: proposal).children.first(where: { $0.label == "pending" })?.value as? PendingAction else { throw Failure.check("native binding unavailable") }
    return pending
}
func nativeNegativeMatrix() async throws {
    Fixture.install([])
    let credential = Credential(); let audit = Audit()
    let (g, h, id) = try await gateway(credential, audit)
    let seed = try ModelJSON.parse(Data(nativeFixture.utf8)).object!
    var cases: [(String, Data)] = []
    func changed(_ name: String, _ key: String, _ value: ModelJSON) throws {
        var root = seed; root[key] = value; cases.append((name, try nativeBytes(root)))
    }
    try changed("stock tokens", "max_tokens", .integer(32000))
    for n: Int64 in [0, -1, 8193] { try changed("token bound \(n)", "max_tokens", .integer(n)) }
    try changed("token bool", "max_tokens", .bool(true))
    try changed("token string", "max_tokens", .string("32"))
    try changed("model remap", "model", .string("claude-sonnet-4"))
    try changed("stream mismatch", "stream", .bool(true))
    try changed("stream type", "stream", .integer(0))
    for field in ["url", "headers", "context_management", "betas", "temperature", "protocol", "epoch", "account_id", "connectionID"] {
        try changed("unknown top \(field)", field, .object([:]))
    }
    for type in ["adaptive", "enabled"] { try changed("thinking \(type)", "thinking", .object(["type": .string(type)])) }
    try changed("thinking budget", "thinking", .object(["type": .string("disabled"), "budget_tokens": .integer(1)]))
    try changed("thinking null", "thinking", .null)
    try changed("unsupported effort", "output_config", .object(["effort": .string("ultra")]))
    try changed("effort type", "output_config", .object(["effort": .integer(1)]))
    try changed("effort unknown", "output_config", .object(["effort": .string("high"), "format": .object([:])]))
    try changed("metadata unknown", "metadata", .object(["user_id": .string("id"), "tenant": .string("other")]))
    try changed("metadata type", "metadata", .object(["user_id": .integer(1)]))
    try changed("metadata bound", "metadata", .object(["user_id": .string(String(repeating: "x", count: 257))]))
    try changed("system unknown", "system", .array([.object(["type": .string("text"), "text": .string("x"), "unknown": .bool(true)])]))
    try changed("cache TTL", "system", .array([.object(["type": .string("text"), "text": .string("x"), "cache_control": .object(["type": .string("ephemeral"), "ttl": .string("1h")])])]))
    try changed("empty messages", "messages", .array([]))
    try changed("message count", "messages", .array(Array(repeating: .object(["role": .string("user"), "content": .string("x")]), count: 129)))
    try changed("system message", "messages", .array([.object(["role": .string("system"), "content": .string("x")])]))
    try changed("assistant first", "messages", .array([.object(["role": .string("assistant"), "content": .string("x")])]))
    try changed("message unknown", "messages", .array([.object(["role": .string("user"), "content": .string("x"), "name": .string("x")])]))
    for type in ["image", "document", "thinking", "redacted_thinking", "server_tool_use", "web_search_tool_result"] {
        try changed("unsupported block \(type)", "messages", .array([.object(["role": .string("user"), "content": .array([.object(["type": .string(type)])])])]))
    }
    try changed("block count", "messages", .array([.object(["role": .string("user"), "content": .array(Array(repeating: .object(["type": .string("text"), "text": .string("x")]), count: 129))])]))
    var tools = seed["tools"]!.array!
    var tool = tools[0].object!
    tool["type"] = .string("web_search_20250305")
    try changed("server tool", "tools", .array([.object(tool)]))
    tool = tools[0].object!; tool["description"] = .string(String(repeating: "x", count: 4097))
    try changed("description bound", "tools", .array([.object(tool)]))
    tool = tools[0].object!; tool["name"] = .string(String(repeating: "n", count: 65))
    try changed("name bound", "tools", .array([.object(tool)]))
    try changed("duplicate tools", "tools", .array(tools + tools))
    tools = (0..<65).map { .object(["name": .string("t\($0)"), "input_schema": .object(["type": .string("object")])]) }
    try changed("tool count", "tools", .array(tools))
    try changed("choice parallel", "tool_choice", .object(["type": .string("auto"), "disable_parallel_tool_use": .bool(true)]))
    try changed("choice unknown tool", "tool_choice", .object(["type": .string("tool"), "name": .string("missing")]))
    let replacements = [
        ("duplicate root", #""max_tokens":8192"#, #""max_tokens":8192,"max_tokens":1"#),
        ("escaped duplicate", #""max_tokens":8192"#, #""max_tokens":8192,"\u006dax_tokens":1"#),
        ("argument duplicate", #""count":2"#, #""count":2,"count":3"#),
        ("decimal", #""count":2"#, #""count":1.0"#),
        ("exponent", #""count":2"#, #""count":1e1"#),
        ("negative zero", #""count":2"#, #""count":-0"#),
        ("unsafe integer", #""count":2"#, #""count":9007199254740992"#),
        ("ID empty", #""id":"tool_1""#, #""id":"""#),
        ("ID control", #""id":"tool_1""#, #""id":"bad\n""#),
        ("result mismatch", #""tool_use_id":"tool_1""#, #""tool_use_id":"missing""#),
        ("result error type", #""is_error":false"#, #""is_error":"false""#),
        ("result unsupported nested", #""text":"sunny""#, #""text":"sunny","source":{}"#),
        ("result order", #""content":[{"type":"tool_result""#, #""content":[{"type":"text","text":"before"},{"type":"tool_result""#)
    ]
    for (name, old, new) in replacements { cases.append((name, Data(nativeFixture.replacingOccurrences(of: old, with: new).utf8))) }
    var messages = seed["messages"]!.array!
    messages.removeLast(); try changed("missing result", "messages", .array(messages))
    messages = seed["messages"]!.array!
    var assistant = messages[1].object!; assistant["content"] = .array(assistant["content"]!.array! + assistant["content"]!.array!)
    messages[1] = .object(assistant); try changed("duplicate ID", "messages", .array(messages))
    messages = seed["messages"]!.array!
    var user = messages[2].object!; user["content"] = .array(user["content"]!.array! + user["content"]!.array!)
    messages[2] = .object(user); try changed("duplicate result", "messages", .array(messages))
    cases.append(("raw bytes", Data(repeating: 32, count: 65_537)))
    let deep = String(repeating: "[", count: 33) + "0" + String(repeating: "]", count: 33)
    cases.append(("depth", Data(nativeFixture.replacingOccurrences(of: #""count":2"#, with: #""count":"# + deep).utf8)))
    let nodes = "[" + Array(repeating: "0", count: 8192).joined(separator: ",") + "]"
    cases.append(("nodes", Data(nativeFixture.replacingOccurrences(of: #""count":2"#, with: #""count":"# + nodes).utf8)))
    for (name, bytes) in cases {
        do { _ = try await g.proposeNative(handle: h, connectionID: id, body: bytes, streaming: false); throw Failure.check("native negative admitted: \(name)") }
        catch ModelTransportError.invalidRequest("native request") {}
    }
    let resumes = try await g.resumedTaskCount(handle: h)
    try check(credential.reads == 0 && Fixture.requests.isEmpty && resumes == 0 && audit.snapshot.isEmpty, "native negatives side effects")
    print("Native negative cases: \(cases.count); credential_reads=\(credential.reads); resume_calls=\(resumes); arrivals=\(Fixture.requests.count); audit_events=\(audit.snapshot.count)")
}

func nativeExactBoundary() async throws {
    for limit in [2048, 65_536] {
        Fixture.install([[Data(toolReply.utf8)]])
        let credential = Credential(); let audit = Audit()
        let (g, h, id) = try await gateway(credential, audit, messageBytes: limit)
        func request(_ count: Int) throws -> Data {
            try nativeBytes(["model": .string("deepseek-flash"), "max_tokens": .integer(1), "stream": .bool(false), "messages": .array([.object(["role": .string("user"), "content": .string(String(repeating: "x", count: count))])])])
        }
        let sample = try await g.proposeNative(handle: h, connectionID: id, body: request(1), streaming: false)
        let sampleBytes = try nativePending(sample).binding.canonicalRequest.count
        try await g.hostDeny(handle: h, proposal: sample)
        let length = limit - sampleBytes + 1
        let exact = try request(length)
        let proposal = try await g.proposeNative(handle: h, connectionID: id, body: exact, streaming: false)
        let binding = try nativePending(proposal).binding
        try check(binding.canonicalRequest.count == limit, "native exact ActionBinding canonical bytes")
        let before = audit.snapshot.count
        do { _ = try await g.proposeNative(handle: h, connectionID: id, body: request(length + 1), streaming: false); throw Failure.check("native plus-one envelope accepted") }
        catch HostModelGatewayError.messageTooLarge {}
        try check(credential.reads == 0 && Fixture.requests.isEmpty && audit.snapshot.count == before, "native plus-one before effects")
        let beforeResumes = try await g.resumedTaskCount(handle: h)
        try check(beforeResumes == 0, "native plus-one zero resumes")
        let approval = try await g.hostApprove(handle: h, proposal: proposal)
        _ = try await g.execute(handle: h, approval: approval)
        let expected = try ModelJSON.parse(binding.canonicalRequest)["nativeBody"]
        try check(try body(Fixture.requests[0]) == expected, "native exact boundary approved body")
        let resumes = try await g.resumedTaskCount(handle: h)
        try check(credential.reads == 1 && resumes == 1 && Fixture.requests.count == 1, "native exact boundary counters")
        try check(try nativeWireBytes(Fixture.requests[0]) == nativeBytes(expected!.object!), "native exact boundary canonical bytes")
        print("Native boundary grant=\(limit) raw=\(exact.count) approved=\(binding.canonicalRequest.count) credential_reads=\(credential.reads) resume_calls=\(resumes) arrivals=\(Fixture.requests.count)")
    }
}

func nativeStreamVertical() async throws {
    Fixture.install([sse(toolEvents())])
    let credential = Credential(); let audit = Audit()
    let (g, h, id) = try await gateway(credential, audit, streaming: true)
    var object = try ModelJSON.parse(Data(nativeFixture.utf8)).object!; object["stream"] = .bool(true)
    object["thinking"] = .object(["type": .string("disabled")])
    let p = try await g.proposeNative(handle: h, connectionID: id, body: nativeBytes(object), streaming: true)
    let a = try await g.hostApprove(handle: h, proposal: p)
    let output = try await g.makeOutput(handle: h, approval: a)
    try await g.execute(handle: h, approval: a, output: output)
    try check(output.summary.acceptedEvents == 0, "native producer is not consumer")
    while try output.acceptNext() {}
    try check(output.summary.acceptedFinals == 1 && output.summary.acceptedMetadata == 1, "native structured SSE receiver")
    try check(try body(Fixture.requests[0]) == .object(object), "native streamed request changed")
    try check(try nativeWireBytes(Fixture.requests[0]) == nativeBytes(object), "native streamed canonical bytes")
    let resumes = try await g.resumedTaskCount(handle: h)
    try check(credential.reads == 1 && resumes == 1 && Fixture.requests.count == 1, "native stream counters")
    print("Native stream credential_reads=\(credential.reads) resume_calls=\(resumes) arrivals=\(Fixture.requests.count) accepted=\(output.summary.acceptedEvents) finals=\(output.summary.acceptedFinals)")
}
