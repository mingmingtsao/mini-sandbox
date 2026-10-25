import Foundation
import SandboxHost
import SandboxContracts

final class AuditBarrier: @unchecked Sendable {
    let lock = NSLock(); var entered = false
    let semaphore = DispatchSemaphore(value: 0)
    var isEntered: Bool { lock.withLock { entered } }
    func wait() { lock.withLock { entered = true }; semaphore.wait() }
    func release() { semaphore.signal() }
}
func auditGate(mode: String) async throws {
    Fixture.install([sse(multipleToolDeltas())])
    let credentials = Credential(); let audit = Audit(); let barrier = AuditBarrier(); audit.barrier = barrier
    audit.fail = mode == "fail"
    let emitted = Emissions()
    let (g, h, id) = try await gateway(credentials, audit, streaming: true)
    let p = try await g.propose(handle: h, connectionID: id, request: toolRequest(), streaming: true)
    let a = try await g.hostApprove(handle: h, proposal: p)
    let task = Task { try await g.execute(handle: h, approval: a) { emitted.add($0, audit: audit) } }
    defer { barrier.release(); task.cancel() }
    for _ in 0..<1000 { if barrier.isEntered { break }; try await Task.sleep(nanoseconds: 1_000_000) }
    try check(barrier.isEntered, "completion audit reached")
    try check(!emitted.snapshot.isEmpty && !emitted.snapshot.contains(where: \.isTerminal), "no terminal metadata or final before durable append")
    try check(audit.snapshot.map(\.reason) == ["dispatch-intent"], "append deliberately not durable yet")
    var control: Task<Void, Error>?
    switch mode {
    case "stop":
        control = Task { try await g.stop(handle: h) }
        var revoked = false
        for _ in 0..<1000 { revoked = try await g.isRevoked(handle: h); if revoked { break }; await Task.yield() }
        try check(revoked, "STOP linearized before audit release")
    case "revoke":
        control = Task { try await g.revokeConnection(id) }
        var observed = false
        // Wrong operation is denied before F03; never wait on the held audit.
        for _ in 0..<1000 {
            do { _ = try await g.propose(handle: h, connectionID: id, request: baseRequest(), streaming: false) }
            catch HostModelGatewayError.invalidConnection { observed = true }
            catch HostModelGatewayError.denied { }
            if observed { break }; await Task.yield()
        }
        try check(observed, "connection revocation observed before audit release")
    case "cancel": task.cancel()
    default: break
    }
    barrier.release()
    if let control { _ = await control.result }
    let result = await task.result
    if mode == "success" {
        let completion = try result.get()
        let metadata = deltaMetadata(emitted.snapshot)
        try check(completion.metadata.stopReason == "tool_use" && emitted.snapshot.filter(\.isTerminal).count == 5, "all four metadata deltas and message_stop released after audit")
        try check(metadata.map { $0.usage?.outputTokens } == [1, 2, 3, 4] && metadata.allSatisfy { $0.stopReason == "tool_use" }, "ordered compatible metadata retained")
        try check(emitted.snapshot.last?.completion == completion && !emitted.premature, "every terminal callback follows durable append")
    } else {
        guard case .failure = result else { throw Failure.check("terminal success after \(mode)") }
        try check(!emitted.snapshot.contains(where: \.isTerminal), "no terminal metadata after \(mode)")
    }
    try check(credentials.reads == 1 && Fixture.requests.count == 1, "no retry/read after audit boundary")
}
final class TerminalTaskHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<ModelCompletion, Error>?
    private var cancellations = 0
    func install(_ task: Task<ModelCompletion, Error>) { lock.withLock { self.task = task } }
    func clear() { lock.withLock { task = nil } }
    func cancelSynchronously() {
        let current = lock.withLock { cancellations += 1; return task }
        current?.cancel()
    }
    var count: Int { lock.withLock { cancellations } }
}
func cancelFirstTerminalCallback() async throws {
    Fixture.install([sse(multipleToolDeltas())])
    let credentials = Credential(); let audit = Audit(); let barrier = AuditBarrier(); audit.barrier = barrier
    let emitted = Emissions(); let holder = TerminalTaskHolder()
    let (g, h, id) = try await gateway(credentials, audit, streaming: true)
    let p = try await g.propose(handle: h, connectionID: id, request: toolRequest(), streaming: true)
    let a = try await g.hostApprove(handle: h, proposal: p)
    let task = Task {
        try await g.execute(handle: h, approval: a) { chunk in
            emitted.add(chunk, audit: audit)
            // Runs on the execute task itself, with no asynchronous cancellation hop.
            if chunk.isTerminal { holder.cancelSynchronously() }
        }
    }
    // The completion barrier prevents terminal callbacks before publication.
    holder.install(task)
    defer { barrier.release(); task.cancel(); holder.clear() }
    for _ in 0..<1000 { if barrier.isEntered { break }; try await Task.sleep(nanoseconds: 1_000_000) }
    try check(barrier.isEntered, "callback cancellation reached held completion append")
    try check(!emitted.snapshot.isEmpty && !emitted.snapshot.contains(where: \.isTerminal), "all metadata held before durable completion")
    try check(audit.snapshot.map(\.reason) == ["dispatch-intent"] && holder.count == 0, "no callback cancellation before append")
    barrier.release()
    let result = await task.result
    guard case .failure(let error) = result else { throw Failure.check("callback cancellation returned success") }
    try check(error as? HostModelGatewayError == .outcomeUnknown, "started callback cancellation has truthful outcomeUnknown")
    let terminal = emitted.snapshot.filter(\.isTerminal)
    try check(terminal.count == 1 && deltaMetadata(terminal).first?.usage?.outputTokens == 1, "only first metadata callback delivered")
    try check(!emitted.premature && !emitted.snapshot.contains(where: \.isFinal), "first callback after append; later deltas and message_stop suppressed")
    try check(holder.count == 1 && task.isCancelled, "synchronous callback cancelled the installed task exactly once")
    try check(audit.snapshot.map(\.reason) == ["dispatch-intent", "dispatch-completion"] && audit.snapshot.last?.outcome == .completed, "single durable upstream completion; no invented second completion")
    try check(credentials.reads == 1 && Fixture.requests.count == 1, "callback cancellation never retries or rereads credentials")
}
func envelopeLimits() async throws {
    for limit in [1024, 65_536] {
        Fixture.install([])
        let credentials = Credential(); let audit = Audit()
        let (g, h, id) = try await gateway(credentials, audit, messageBytes: limit)
        let request = try FixedModelRequest(model: .deepSeekFlash, protocol: .anthropic, messages: [FixedMessage(role: .user, content: String(repeating: "x", count: limit))], maxOutputTokens: 1)
        do { _ = try await g.propose(handle: h, connectionID: id, request: request, streaming: false); throw Failure.check("canonical envelope cap") }
        catch HostModelGatewayError.messageTooLarge {}
        try check(credentials.reads == 0 && Fixture.requests.isEmpty && audit.snapshot.isEmpty, "oversized proposal zero reads/dispatch/audit")
    }
}
func rawCompletionRejections() async throws {
    let invalid = [
        toolReply.replacingOccurrences(of: #""city":"北京""#, with: #""city":"北京","city":"duplicate""#),
        toolReply.replacingOccurrences(of: #""city":"北京""#, with: #""city":9007199254740992"#),
        toolReply.replacingOccurrences(of: #""city":"北京""#, with: #""city":1.25"#),
        toolReply.replacingOccurrences(of: #"{"city":"北京"}"#, with: String(repeating: #"{"x":"#, count: 34) + "{}" + String(repeating: "}", count: 34)),
        toolReply.replacingOccurrences(of: #""city":"北京""#, with: #""city":""# + String(repeating: "x", count: 65_536) + #"""#),
        #"{"content":[],"stop_reason":"tool_use"}"#,
        #"{"content":[{"type":"image","source":{}}]}"#,
        #"{"content":[{"type":"thinking","thinking":"hidden"}]}"#,
        toolReply.replacingOccurrences(of: #""stop_reason":"tool_use""#, with: #""stop_reason":"aborted""#)
    ]
    for raw in invalid {
        Fixture.install([[Data(raw.utf8)]])
        let transport = ModelTransport(credentialProvider: Credential(), configuration: configuration())
        do { _ = try await transport.complete(baseRequest()); throw Failure.check("invalid completion admitted") } catch is ModelTransportError {}
    }
}
