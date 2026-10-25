import Foundation
import SandboxHost

func nativeCanonicalReconstruction() async throws {
    Fixture.install([[Data(toolReply.utf8)]])
    let credential = Credential(); let audit = Audit()
    let (g, h, id) = try await gateway(credential, audit)
    func request(_ count: Int) throws -> Data {
        try nativeBytes(["model": .string("deepseek-flash"), "max_tokens": .integer(1), "stream": .bool(false),
            "system": .array([.object(["type": .string("text"), "text": .string(String(repeating: "/", count: count))])]),
            "messages": .array([.object(["role": .string("user"), "content": .string("x")])])])
    }
    let sample = try await g.proposeNative(handle: h, connectionID: id, body: request(1), streaming: false)
    let overhead = try nativePending(sample).binding.canonicalRequest.count - 1
    try await g.hostDeny(handle: h, proposal: sample)
    let p = try await g.proposeNative(handle: h, connectionID: id, body: request(65_536 - overhead), streaming: false)
    let binding = try nativePending(p).binding
    try check(binding.canonicalRequest.count == 65_536, "native slash exact canonical cap")
    let a = try await g.hostApprove(handle: h, proposal: p)
    _ = try await g.execute(handle: h, approval: a)
    let expected = try ModelJSON.parse(binding.canonicalRequest)["nativeBody"]!.object!
    try check(try nativeWireBytes(Fixture.requests[0]) == nativeBytes(expected), "native canonical reconstruction slash bytes")
    let resumes = try await g.resumedTaskCount(handle: h)
    try check(credential.reads == 1 && resumes == 1 && Fixture.requests.count == 1, "native slash counters")
    print("Native canonical reconstruction approved=\(binding.canonicalRequest.count) credential_reads=\(credential.reads) resume_calls=\(resumes) arrivals=\(Fixture.requests.count)")
}
