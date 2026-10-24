import Foundation
import SandboxHost

var passed = 0
@MainActor func check(_ name: String, _ body: () throws -> Bool) {
    do { guard try body() else { throw NSError(domain: name, code: 1) }; passed += 1; print("PASS \(name)") }
    catch { print("FAIL \(name): \(error)"); exit(1) }
}
func rejects(_ expected: VMProtocolError, _ body: () throws -> Void) -> Bool {
    do { try body(); return false } catch { return error as? VMProtocolError == expected }
}
let run = UUID(uuidString: "00010203-0405-0607-0809-0a0b0c0d0e0f")!
let golden = "000000220101000102030405060708090a0b0c0d0e0f00000000000000010000000000000009"
check("golden bytes and partial frame") {
    let bytes = VMFrame(runID: run, epoch: 1, nonce: 9).encoded()
    guard bytes.map({String(format:"%02x", $0)}).joined() == golden else { return false }
    var parser = VMFrameParser()
    var result: VMFrame?
    for byte in bytes { if let frame = try parser.feed(Data([byte])) { result = frame } }
    return result == VMFrame(runID: run, epoch: 1, nonce: 9) && parser.bufferedBytes <= 38
}
for (name, bytes, error) in [
    ("oversize header", Data([0,0,16,1]), VMProtocolError.oversized),
    ("wrong exact length", Data([0,0,0,33]), .length),
    ("zero length", Data([0,0,0,0]), .length)
] {
    check(name) { var p = VMFrameParser(); return rejects(error) { _ = try p.feed(bytes) } && p.bufferedBytes == 4 }
}
for (name, offset, value, error) in [("version", 4, UInt8(2), VMProtocolError.version), ("unknown type", 5, UInt8(255), .type)] {
    check(name) { var b = VMFrame(runID: run, epoch: 1, nonce: 9).encoded(); b[offset] = value; var p = VMFrameParser(); return rejects(error) { _ = try p.feed(b) } }
}
check("truncated") { var p = VMFrameParser(); _ = try p.feed(Data([0,0])); return rejects(.truncated) { try p.finish() } }
check("extra bytes") { var p = VMFrameParser(); return rejects(.extraBytes) { _ = try p.feed(VMFrame(runID: run, epoch: 1, nonce: 9).encoded() + Data([0])) } }
final class Sink: SynchronousAuditSink, @unchecked Sendable {
    var fail = false
    var events: [SecurityEvent] = []
    func append(_ event: SecurityEvent) throws { if fail { throw VMProtocolError.auditFailed }; events.append(event) }
}
let owner = NSObject(), other = NSObject()
@MainActor func session(_ sink: Sink = Sink(), budget: Int = 64) throws -> VMDiagnosticSession {
    try VMDiagnosticSession(owner: owner, runID: run, epoch: 1, workloadDigest: String(repeating: "a", count: 64), sink: sink, frameBudget: budget)
}
check("bound positive") { let s = try session(); try s.open(owner: owner, now: 0); return try s.reply(to: VMFrame(runID: run, epoch: 1, nonce: 9), owner: owner, now: 1).type == 2 }
check("cross context") { let s = try session(); return rejects(.crossContext) { try s.open(owner: other, now: 0) } }
check("one active") { let s = try session(); try s.open(owner: owner, now: 0); return rejects(.busy) { try s.open(owner: owner, now: 0) } }
check("frame budget") { let s = try session(budget: 1); try s.open(owner: owner, now: 0); s.close(); return rejects(.budget) { try s.open(owner: owner, now: 0) } }
check("timeout") { let s = try session(); try s.open(owner: owner, now: 0); return rejects(.timeout) { _ = try s.reply(to: VMFrame(runID: run, epoch: 1, nonce: 9), owner: owner, now: 5) } }
check("forged UUID") { let s = try session(); try s.open(owner: owner, now: 0); return rejects(.uuid) { _ = try s.reply(to: VMFrame(runID: UUID(), epoch: 1, nonce: 9), owner: owner, now: 1) } }
check("wrong epoch") { let s = try session(); try s.open(owner: owner, now: 0); return rejects(.epoch) { _ = try s.reply(to: VMFrame(runID: run, epoch: 2, nonce: 9), owner: owner, now: 1) } }
check("after stop") { let s = try session(); try s.open(owner: owner, now: 0); s.revoke(); return rejects(.stopped) { _ = try s.reply(to: VMFrame(runID: run, epoch: 1, nonce: 9), owner: owner, now: 1) } }
check("audit failure revokes") { let sink = Sink(); let s = try session(sink); try s.open(owner: owner, now: 0); sink.fail = true; let denied = rejects(.auditFailed) { _ = try s.reply(to: VMFrame(runID: run, epoch: 1, nonce: 9), owner: owner, now: 1) }; return denied && s.revoked }
check("guest diagnostics never host rejection") { let sink = Sink(); let s = try session(sink); try s.guestDiagnostic(Data("denied forged UUID".utf8)); return sink.events.count == 1 && !sink.events[0].isHostRejection && s.rejections.isEmpty }
check("parser error is terminal") {
    var p = VMFrameParser()
    guard rejects(.oversized, { _ = try p.feed(Data([0,0,16,1])) }) else { return false }
    return rejects(.extraBytes) { _ = try p.feed(VMFrame(runID: run, epoch: 1, nonce: 9).encoded().dropFirst(4)) }
}
check("cross-context reply") { let s = try session(); try s.open(owner: owner, now: 0); return rejects(.crossContext) { _ = try s.reply(to: VMFrame(runID: run, epoch: 1, nonce: 9), owner: other, now: 1) } }
check("real JSONL sink host rejection") {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("vmcheck-\(UUID()).jsonl")
    defer { try? FileManager.default.removeItem(at: url) }
    let sink = try JSONLAuditSink(newFileAt: url)
    let s = try VMDiagnosticSession(owner: owner, runID: run, epoch: 1, workloadDigest: String(repeating: "a", count: 64), sink: sink)
    try s.open(owner: owner, now: 0)
    guard rejects(.uuid, { _ = try s.reply(to: VMFrame(runID: UUID(), epoch: 1, nonce: 9), owner: owner, now: 1) }) else { return false }
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    return object?["origin"] as? String == "hostEnforcement" && object?["decision"] as? String == "deny" && object?["reason"] as? String == "uuid"
}
check("canonical diagnostic RunGrant digest") {
    let sink = Sink(); let s = try session(sink)
    try s.guestDiagnostic(Data([1]))
    return s.grant.connections.isEmpty && s.grant.workloadImageDigest == String(repeating: "a", count: 64) && sink.events[0].grantDigest == RunAuthorizationController.grantDigest(for: s.grant) && sink.events[0].grantDigest != s.grant.workloadImageDigest
}
check("pending start cannot release initial stopped resources") {
    var lifetime = VMProbeLifetime()
    lifetime.startPending = true
    guard !lifetime.canReleaseResources(actualStopped: true) else { return false }
    lifetime.startPending = false
    guard !lifetime.canReleaseResources(actualStopped: false) else { return false }
    lifetime.stopPending = true
    guard !lifetime.canReleaseResources(actualStopped: true) else { return false }
    lifetime.stopPending = false
    return lifetime.canReleaseResources(actualStopped: true)
}
check("probe run admission is one-shot") {
    let probe = HeadlessVMProbe()
    return probe.claimRun() && !probe.claimRun()
}
print("VMChecks: \(passed) passed")
