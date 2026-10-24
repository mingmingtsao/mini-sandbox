import Foundation
import SandboxHost

// Synthetic shapes: validation projections must not double-count escaped slashes.
func nativeProjectionRequest(_ kind: String, _ character: String, _ count: Int) -> [String: ModelJSON] {
    let text = String(repeating: character, count: count)
    var root: [String: ModelJSON] = ["model": .string("deepseek-flash"), "max_tokens": .integer(1), "stream": .bool(false), "messages": .array([.object(["role": .string("user"), "content": .string("x")])])]
    let block: ModelJSON = .object(["type": .string("text"), "text": .string(text)])
    if kind == "string" { root["messages"] = .array([.object(["role": .string("user"), "content": .string(text)])]) }
    if kind == "blocks" { root["messages"] = .array([.object(["role": .string("user"), "content": .array([block])])]) }
    if kind == "system" { root["system"] = .array([block]) }
    if ["schema", "input", "result", "result_blocks"].contains(kind) {
        var schema: [String: ModelJSON] = ["type": .string("object")]
        if kind == "schema" { schema["description"] = .string(text) }
        root["tools"] = .array([.object(["name": .string("tool"), "input_schema": .object(schema)])])
        if kind != "schema" {
            let input: ModelJSON = kind == "input" ? .object(["data": .string(text)]) : .object([:])
            let result: ModelJSON = kind == "result" ? .string(text) : (kind == "result_blocks" ? .array([block]) : .string("ok"))
            root["messages"] = .array([
                .object(["role": .string("user"), "content": .string("x")]),
                .object(["role": .string("assistant"), "content": .array([.object(["type": .string("tool_use"), "id": .string("id1"), "name": .string("tool"), "input": input])])]),
                .object(["role": .string("user"), "content": .array([.object(["type": .string("tool_result"), "tool_use_id": .string("id1"), "content": result])])])])
        }
    }
    return root
}

func nativeProjectionAccepted(_ kind: String, _ character: String = "/") async throws {
    Fixture.install([[Data(toolReply.utf8)]])
    let credential = Credential(); let audit = Audit()
    let (g, h, id) = try await gateway(credential, audit)
    let root = nativeProjectionRequest(kind, character, 40_000)
    let raw = try nativeBytes(root)
    _ = try ModelJSON.parse(raw)
    // Measure the actual envelope overhead with a valid small request first.
    let small = try await g.proposeNative(handle: h, connectionID: id, body: nativeBytes(nativeProjectionRequest(kind, character, 1)), streaming: false)
    var envelope = try ModelJSON.parse(nativePending(small).binding.canonicalRequest).object!
    var approved = root; approved["thinking"] = .object(["type": .string("disabled")])
    envelope["nativeBody"] = .object(approved)
    let wrapped = try nativeBytes(envelope).count
    try check(raw.count < 65_536 && wrapped < 65_536, "projection fixture must fit raw and wrapped caps")
    try await g.hostDeny(handle: h, proposal: small)
    let before = audit.snapshot.count
    let proposal: HostModelProposal
    do {
        proposal = try await g.proposeNative(handle: h, connectionID: id, body: raw, streaming: false)
    } catch ModelTransportError.invalidRequest("native request") {
        let resumes = try await g.resumedTaskCount(handle: h)
        try check(credential.reads == 0 && resumes == 0 && Fixture.requests.isEmpty && audit.snapshot.count == before, "projection rejection effects")
        print("Native projection kind=\(kind) ordinary=\(character == "x") raw=\(raw.count) wrapped=\(wrapped) typed_rejection=true credential_reads=0 resume_calls=0 arrivals=0 audit_new=0")
        throw Failure.check("within-bound native projection rejected")
    }
    try check(try nativePending(proposal).binding.canonicalRequest.count == wrapped, "projection actual wrapped bytes")
    let prestart = try await g.resumedTaskCount(handle: h)
    try check(credential.reads == 0 && prestart == 0 && Fixture.requests.isEmpty && audit.snapshot.count == before, "projection proposal effects")
    let approval = try await g.hostApprove(handle: h, proposal: proposal)
    _ = try await g.execute(handle: h, approval: approval)
    let resumes = try await g.resumedTaskCount(handle: h)
    try check(credential.reads == 1 && resumes == 1 && Fixture.requests.count == 1 && audit.snapshot.count - before == 2 && audit.snapshot.last?.outcome == .completed, "projection exact counters")
    try check(try nativeWireBytes(Fixture.requests[0]) == nativeBytes(approved), "projection canonical outgoing bytes")
    print("Native projection kind=\(kind) ordinary=\(character == "x") raw=\(raw.count) wrapped=\(wrapped) exact=true credential_reads=\(credential.reads) resume_calls=\(resumes) arrivals=\(Fixture.requests.count) audit_new=\(audit.snapshot.count - before)")
}

func nativeProjectionControls() async throws {
    for kind in ["string", "blocks", "schema", "input", "system", "result", "result_blocks"] {
        try await nativeProjectionAccepted(kind, "x")
    }
    for kind in ["system", "result", "result_blocks"] { try await nativeProjectionAccepted(kind) }
}

func nativeProjectionRejections() async throws {
    for mode in ["oversize", "unknown", "unpaired"] {
        Fixture.install([])
        let credential = Credential(); let audit = Audit()
        let (g, h, id) = try await gateway(credential, audit)
        var root = nativeProjectionRequest("string", "x", mode == "oversize" ? 65_536 : 40_000)
        if mode == "unknown" { root["headers"] = .object([:]) }
        if mode == "unpaired" {
            root = nativeProjectionRequest("result", "/", 40_000)
            var messages = root["messages"]!.array!; messages.remove(at: 1); root["messages"] = .array(messages)
        }
        do {
            _ = try await g.proposeNative(handle: h, connectionID: id, body: nativeBytes(root), streaming: false)
            throw Failure.check("projection negative admitted")
        } catch ModelTransportError.invalidRequest("native request") {}
        let resumes = try await g.resumedTaskCount(handle: h)
        try check(credential.reads == 0 && resumes == 0 && Fixture.requests.isEmpty && audit.snapshot.isEmpty, "projection negative zero effects")
        print("Native projection negative=\(mode) typed_rejection=true credential_reads=\(credential.reads) resume_calls=\(resumes) arrivals=\(Fixture.requests.count) audit_events=\(audit.snapshot.count)")
    }
}
