import Foundation
import SandboxContracts
import SandboxHost

final class AuditBarrier: @unchecked Sendable {
    let reason: String
    let entered = AsyncStream<Void>.makeStream()
    let release = DispatchSemaphore(value: 0)
    init(_ reason: String) { self.reason = reason }
    func wait() {
        entered.continuation.yield(())
        release.wait()
    }
    func waitForEntry() async {
        var iterator = entered.stream.makeAsyncIterator()
        _ = await iterator.next()
    }
}
func bodyData(_ request: URLRequest) throws -> Data {
    if let data = request.httpBody { return data }
    guard let stream = request.httpBodyStream else { throw Failure("missing body") }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var bytes = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let count = stream.read(&bytes, maxLength: bytes.count)
        guard count >= 0 else { throw Failure("body read") }
        if count == 0 { break }
        data.append(contentsOf: bytes.prefix(count))
    }
    return data
}
func rejected(_ body: () async throws -> Void) async throws {
    do { try await body() } catch is HostModelGatewayError { return } catch is AuthorizationError { return }
    throw Failure("expected fail-closed rejection")
}
struct Setup {
    let audit: Audit
    let credentials: Credentials
    let id: UUID
    let gateway: HostModelGateway
    let handle: HostModelRunHandle
    init(
        streaming: Bool = false, scope: ResourceScope? = nil, deny: Bool = false, messageBytes: Int = 8192,
        concurrency: Int = 2, hangs: Bool = false
    ) async throws {
        audit = Audit()
        credentials = Credentials()
        id = UUID()
        FixtureProtocol.fixture.reset(audit, stream: streaming, hangs: hangs)
        gateway = try HostModelGateway(connections: [connection(id, credentials)], auditSink: audit)
        let wanted = try ResourceScope(
            service: "model", resource: "deepseek-flash", operation: streaming ? "stream" : "complete")
        handle = try await gateway.install(
            grant: grant(
                connection: id, scope: scope ?? wanted, denies: deny ? [wanted] : [], messageBytes: messageBytes,
                concurrency: concurrency))
    }
    func approve(streaming: Bool = false) async throws -> HostModelApproval {
        let proposal = try await gateway.propose(
            handle: handle, connectionID: id, request: request(), streaming: streaming)
        return try await gateway.hostApprove(handle: handle, proposal: proposal)
    }
}
func waitUntil(_ predicate: () async -> Bool) async throws {
    for _ in 0..<1000 {
        if await predicate() { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    throw Failure("fixture boundary timeout")
}
func testDirectBaselineAndDefaultDeny() async throws {
    for scope in [
        try ResourceScope(service: "model", resource: "wrong-model", operation: "complete"),
        try ResourceScope(service: "other-service", resource: "deepseek-flash", operation: "complete"),
        try ResourceScope(service: "model", resource: "deepseek-flash", operation: "stream"),
    ] {
        let s = try await Setup(scope: scope)
        let direct = ModelTransport(credentialProvider: s.credentials, configuration: configuration())
        _ = try await direct.complete(request())
        try require(FixtureProtocol.fixture.hits == 1, "upstream accepts request outside granted scope")
        FixtureProtocol.fixture.reset(s.audit)
        let reads = s.credentials.count
        try await rejected { _ = try await s.approve() }
        try require(
            FixtureProtocol.fixture.hits == 0 && s.credentials.count == reads,
            "exact service/resource/operation default deny prevents credential/network access")
    }
}
func testConnectionAndHandleDenials() async throws {
    let s = try await Setup()
    try await rejected {
        _ = try await s.gateway.propose(handle: s.handle, connectionID: UUID(), request: request(), streaming: false)
    }
    let other = try HostModelGateway(connections: [connection(s.id, s.credentials)], auditSink: s.audit)
    try await rejected {
        _ = try await other.propose(handle: s.handle, connectionID: s.id, request: request(), streaming: false)
    }
    let another = try await s.gateway.install(
        grant: grant(
            connection: s.id, scope: ResourceScope(service: "model", resource: "deepseek-flash", operation: "complete"))
    )
    let approval = try await s.approve()
    try await rejected { _ = try await s.gateway.execute(handle: another, approval: approval) }
    let wrongProtocol = try FixedModelRequest(
        model: .deepSeekFlash, protocol: .anthropic, messages: request().messages, maxOutputTokens: 32)
    try await rejected {
        _ = try await s.gateway.propose(handle: s.handle, connectionID: s.id, request: wrongProtocol, streaming: false)
    }
    try require(
        FixtureProtocol.fixture.hits == 0 && s.credentials.count == 0,
        "wrong connection/protocol/cross-gateway/cross-run zero hits")
}
func testExplicitDeny() async throws {
    let s = try await Setup(deny: true)
    try await rejected { _ = try await s.approve() }
    try require(FixtureProtocol.fixture.hits == 0 && s.credentials.count == 0, "explicit deny zero hits")
}
func testReplayConcurrent() async throws {
    let s = try await Setup()
    let approval = try await s.approve()
    let values = await withTaskGroup(of: Bool.self) { group in
        for _ in 0..<8 {
            group.addTask {
                do {
                    _ = try await s.gateway.execute(handle: s.handle, approval: approval)
                    return true
                } catch { return false }
            }
        }
        var result: [Bool] = []
        for await value in group { result.append(value) }
        return result
    }
    try require(
        values.filter { $0 }.count == 1 && FixtureProtocol.fixture.hits == 1,
        "one real dispatch among concurrent consumers")
    try await rejected { _ = try await s.gateway.execute(handle: s.handle, approval: approval) }
    try require(
        s.audit.snapshot.filter { $0.reason == "dispatch-intent" }.count == 1
            && s.audit.snapshot.filter { $0.reason == "dispatch-completion" }.count == 1, "one audit pair, no replay")
}
func testStopAtConsumeAudit() async throws {
    let s = try await Setup()
    let approval = try await s.approve()
    let barrier = AuditBarrier("dispatch-intent")
    s.audit.lock.withLock { s.audit.barrier = barrier }
    let execution = Task { try await s.gateway.execute(handle: s.handle, approval: approval) }
    await barrier.waitForEntry()
    let stopping = Task { try await s.gateway.stop(handle: s.handle) }
    do { try await waitUntil { (try? await s.gateway.isRevoked(handle: s.handle)) == true } } catch {
        barrier.release.signal()
        throw error
    }
    barrier.release.signal()
    try await stopping.value
    try await rejected { _ = try await execution.value }
    try require(
        s.credentials.count == 0 && FixtureProtocol.fixture.hits == 0,
        "STOP during consume audit prevents actual task start and credential access")
    try require(
        s.audit.snapshot.map(\.reason) == ["dispatch-intent", "dispatch-completion"]
            && s.audit.snapshot.last?.outcome == .failed,
        "issued but unstarted ticket completed once as failed, not unknown/success")
}
func testStopAndLateApproval() async throws {
    let s = try await Setup()
    let pending = try await s.gateway.propose(
        handle: s.handle, connectionID: s.id, request: request(), streaming: false)
    try await s.gateway.stop(handle: s.handle)
    try await rejected { _ = try await s.gateway.hostApprove(handle: s.handle, proposal: pending) }
    try require(s.credentials.count == 0 && FixtureProtocol.fixture.hits == 0, "late approval after STOP cannot revive")
}
func testConnectionRevocationAndUpdate() async throws {
    for update in [false, true] {
        let s = try await Setup()
        let approval = try await s.approve()
        if update {
            try await s.gateway.updateConnection(connection(s.id, s.credentials, accountVersion: 8, routeVersion: 12))
        } else {
            try await s.gateway.revokeConnection(s.id)
        }
        try await rejected { _ = try await s.gateway.execute(handle: s.handle, approval: approval) }
        try await rejected { _ = try await s.approve() }
        try await rejected { try await s.gateway.updateConnection(connection(s.id, s.credentials)) }
        try require(
            s.credentials.count == 0 && FixtureProtocol.fixture.hits == 0,
            "connection revocation/update/rollback prevent new dispatch")
    }
}
func testStartedCancellationUnknown() async throws {
    let s = try await Setup(hangs: true)
    let approval = try await s.approve()
    let execution = Task { try await s.gateway.execute(handle: s.handle, approval: approval) }
    try await waitUntil { FixtureProtocol.fixture.hits == 1 }
    try await s.gateway.stop(handle: s.handle)
    do {
        _ = try await execution.value
        throw Failure("cancelled call succeeded")
    } catch let error as HostModelGatewayError {
        try require(error == .outcomeUnknown, "started cancellation is unknown")
    }
    try require(
        s.audit.snapshot.last?.outcome == .unknown && s.audit.snapshot.count == 2 && FixtureProtocol.fixture.hits == 1,
        "unknown completion exactly once, no retry")
}
func testIntentAuditFailure() async throws {
    let s = try await Setup()
    let approval = try await s.approve()
    s.audit.lock.withLock { s.audit.failureReason = "dispatch-intent" }
    do {
        _ = try await s.gateway.execute(handle: s.handle, approval: approval)
        throw Failure("audit failure allowed")
    } catch let error as HostModelGatewayError { try require(error == .auditFailed, "audit error sanitized") }
    s.audit.lock.withLock { s.audit.failureReason = nil }
    try await rejected { _ = try await s.approve() }
    try require(
        s.credentials.count == 0 && FixtureProtocol.fixture.hits == 0,
        "audit failure never accesses key or starts network; run stays revoked")
}
final class Chunks: @unchecked Sendable {
    let lock = NSLock()
    var values: [ModelStreamChunk] = []
    var auditedFinal = false
    func append(_ chunk: ModelStreamChunk, audit: Audit) {
        lock.withLock {
            values.append(chunk)
            if chunk.isFinal { auditedFinal = audit.snapshot.last?.outcome == .completed }
        }
    }
}
func testStreamingAudit(fail: Bool) async throws {
    let s = try await Setup(streaming: true)
    let approval = try await s.approve(streaming: true)
    let chunks = Chunks()
    if fail { s.audit.lock.withLock { s.audit.failureReason = "dispatch-completion" } }
    do {
        let result = try await s.gateway.execute(handle: s.handle, approval: approval) {
            chunks.append($0, audit: s.audit)
        }
        try require(!fail && result.text == "onetwo", "stream completes only after audited success")
    } catch let error as HostModelGatewayError {
        try require(fail && error == .auditFailed, "completion audit failure denies success")
    }
    let values = chunks.lock.withLock { chunks.values }
    try require(
        values.filter { !$0.isFinal }.map(\.text) == ["one", "two"] && values.filter(\.isFinal).count == (fail ? 0 : 1),
        "ordered text and audit-gated single final")
    if !fail { try require(chunks.lock.withLock { chunks.auditedFinal }, "success final follows completion audit") }
    try require(FixtureProtocol.fixture.hits == 1, "stream uses actual transport once")
}
func testRunLimits() async throws {
    let small = try await Setup(messageBytes: 64)
    try await rejected { _ = try await small.approve() }
    try require(
        small.credentials.count == 0 && FixtureProtocol.fixture.hits == 0,
        "canonical message bound precedes credentials")
    let s = try await Setup(concurrency: 1, hangs: true)
    let first = try await s.approve()
    let second = try await s.approve()
    let execution = Task { try await s.gateway.execute(handle: s.handle, approval: first) }
    try await waitUntil { FixtureProtocol.fixture.hits == 1 }
    do {
        _ = try await s.gateway.execute(handle: s.handle, approval: second)
        throw Failure("run concurrency exceeded")
    } catch let error as HostModelGatewayError { try require(error == .busy, "run concurrency fails fast") }
    try await s.gateway.stop(handle: s.handle)
    _ = await execution.result
    try require(s.credentials.count == 1 && FixtureProtocol.fixture.hits == 1, "bounded in-flight")
}
