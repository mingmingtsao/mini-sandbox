import Foundation
import SandboxHost
import SandboxContracts

// Synthetic native wire shape, not a captured CLI/provider request.
let nativeFixture = #"{"model":"deepseek-flash","max_tokens":8192,"stream":false,"system":[{"type":"text","text":"first","cache_control":{"type":"ephemeral"}},{"type":"text","text":"second"}],"tools":[{"name":"weather","description":"forecast","input_schema":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"],"additionalProperties":false},"cache_control":{"type":"ephemeral"}}],"messages":[{"role":"user","content":[{"type":"text","text":"weather","cache_control":{"type":"ephemeral"}}]},{"role":"assistant","content":[{"type":"tool_use","id":"tool_1","name":"weather","input":{"city":"北京","count":2}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"tool_1","content":[{"type":"text","text":"sunny"}],"is_error":false}]}],"metadata":{"user_id":"synthetic-user"}}"#

func nativeVertical() async throws {
    Fixture.install([[Data(toolReply.utf8)]])
    let credential = Credential(); let audit = Audit()
    let (g, h, id) = try await gateway(credential, audit)
    var input = Data(nativeFixture.utf8)
    var expected = try ModelJSON.parse(input).object!
    expected["thinking"] = .object(["type": .string("disabled")])
    let proposal = try await g.proposeNative(handle: h, connectionID: id, body: input, streaming: false)
    input.resetBytes(in: 0..<input.count)
    let approvedBody = try ModelJSON.parse(nativePending(proposal).binding.canonicalRequest)["nativeBody"]
    try check(approvedBody == .object(expected), "native approved full tree")
    try check(credential.reads == 0 && Fixture.requests.isEmpty, "native proposal read credential")
    let approval = try await g.hostApprove(handle: h, proposal: proposal)
    try check(credential.reads == 0 && Fixture.requests.isEmpty, "native approval started transport")
    let output = try await g.makeOutput(handle: h, approval: approval)
    try await g.execute(handle: h, approval: approval, output: output)
    try check(Fixture.requests.count == 1, "native actual dispatch count")
    let wire = try nativeWireBytes(Fixture.requests[0])
    let actual = try ModelJSON.parse(wire)
    try check(actual == .object(expected), "native approved supported structures changed")
    try check(wire == nativeBytes(expected), "native canonical body bytes changed")
    try check(Fixture.requests[0].url?.absoluteString == "https://api.deepseek.com/anthropic/v1/messages" && Fixture.requests[0].httpMethod == "POST" && Fixture.requests[0].value(forHTTPHeaderField: "anthropic-version") == "2023-06-01", "native host routing")
    try check(try output.acceptNext(), "native receiver missing completion")
    try check(try !output.acceptNext(), "native receiver duplicate completion")
    try check(credential.reads == 1 && audit.snapshot.last?.outcome == .completed, "native audit/read counters")
    let resumes = try await g.resumedTaskCount(handle: h)
    try check(resumes == 1, "native actual resume count")
    print("Native nonstream credential_reads=\(credential.reads) resume_calls=\(resumes) arrivals=\(Fixture.requests.count) accepted=\(output.summary.acceptedEvents) finals=\(output.summary.acceptedFinals)")
}

func nativeWireBytes(_ request: URLRequest) throws -> Data {
    if let data = request.httpBody { return data }
    guard let stream = request.httpBodyStream else { throw Failure.check("native missing body") }
    stream.open(); defer { stream.close() }
    var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let n = stream.read(&buffer, maxLength: buffer.count)
        guard n >= 0 else { throw Failure.check("native body stream") }
        if n == 0 { break }; data.append(contentsOf: buffer.prefix(n))
        try check(data.count <= 65_536, "native body bound")
    }
    return data
}
