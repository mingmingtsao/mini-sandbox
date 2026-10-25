import Foundation
import SandboxContracts
import SandboxHost

func testUngrantedConnection() async throws {
    let audit = Audit()
    let credentials = Credentials()
    let grantedID = UUID()
    let extraID = UUID()
    FixtureProtocol.fixture.reset(audit)
    let direct = ModelTransport(credentialProvider: credentials, configuration: configuration())
    _ = try await direct.complete(request())
    try require(FixtureProtocol.fixture.hits == 1, "same upstream/provider permits baseline")
    FixtureProtocol.fixture.reset(audit)
    let gateway = try HostModelGateway(
        connections: [connection(grantedID, credentials), connection(extraID, credentials)], auditSink: audit)
    let handle = try await gateway.install(
        grant: grant(
            connection: grantedID,
            scope: ResourceScope(service: "model", resource: "deepseek-flash", operation: "complete")))
    try await rejected {
        _ = try await gateway.propose(handle: handle, connectionID: extraID, request: request(), streaming: false)
    }
    try require(
        FixtureProtocol.fixture.hits == 0 && credentials.count == 1,
        "configured but ungranted connection cannot use provider authority")
}
func testGatewayIncremental() async throws {
    let s = try await Setup(streaming: true, hangs: true)
    let chunks = Chunks()
    FixtureProtocol.fixture.lock.withLock { FixtureProtocol.fixture.partialBeforeHang = true }
    let approval = try await s.approve(streaming: true)
    let execution = Task {
        try await s.gateway.execute(handle: s.handle, approval: approval) { chunks.append($0, audit: s.audit) }
    }
    try await waitUntil { chunks.lock.withLock { chunks.values.map(\.text) == ["early"] } }
    try require(s.audit.snapshot.count == 1, "text delivered while upstream is open, before completion audit")
    try await s.gateway.stop(handle: s.handle)
    try await rejected { _ = try await execution.value }
    try require(
        chunks.lock.withLock { !chunks.values.contains(where: \.isFinal) },
        "cancelled incremental stream never succeeds")
    try require(
        s.audit.snapshot.last?.outcome == .unknown && FixtureProtocol.fixture.hits == 1,
        "incremental cancellation no retry")
}
func testHostDenial() async throws {
    let s = try await Setup()
    let pending = try await s.gateway.propose(
        handle: s.handle, connectionID: s.id, request: request(), streaming: false)
    try await s.gateway.hostDeny(handle: s.handle, proposal: pending)
    try await rejected { _ = try await s.gateway.hostApprove(handle: s.handle, proposal: pending) }
    try require(s.credentials.count == 0 && FixtureProtocol.fixture.hits == 0, "host denial never dispatches")
    try require(s.audit.snapshot.count == 1 && s.audit.snapshot[0].decision == .deny, "F03 host denial audited")
}
func testCompletionAuditFailure() async throws {
    let s = try await Setup()
    let approval = try await s.approve()
    s.audit.lock.withLock { s.audit.failureReason = "dispatch-completion" }
    do {
        _ = try await s.gateway.execute(handle: s.handle, approval: approval)
        throw Failure("unaudited completion delivered success")
    } catch let error as HostModelGatewayError { try require(error == .auditFailed, "completion audit fail-closed") }
    try require(
        FixtureProtocol.fixture.hits == 1 && s.audit.snapshot.count == 1, "no completion retry and no duplicate request"
    )
}
func testNetworkFailure() async throws {
    let s = try await Setup()
    let approval = try await s.approve()
    FixtureProtocol.fixture.lock.withLock { FixtureProtocol.fixture.networkFailure = true }
    do {
        _ = try await s.gateway.execute(handle: s.handle, approval: approval)
        throw Failure("failed network completed")
    } catch let error as HostModelGatewayError {
        try require(error == .outcomeUnknown, "started network failure is conservatively unknown")
    }
    try require(
        FixtureProtocol.fixture.hits == 1 && s.audit.snapshot.last?.outcome == .unknown,
        "network failure audited once with no retry")
}
func testDurableAudit() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("host-model-integration-\(UUID()).jsonl")
    defer { try? FileManager.default.removeItem(at: path) }
    let sink = try JSONLAuditSink(newFileAt: path)
    let id = UUID()
    let credentials = Credentials()
    FixtureProtocol.fixture.reset()
    FixtureProtocol.fixture.lock.withLock { FixtureProtocol.fixture.auditPath = path }
    let gateway = try HostModelGateway(connections: [connection(id, credentials)], auditSink: sink)
    let handle = try await gateway.install(
        grant: grant(
            connection: id, scope: ResourceScope(service: "model", resource: "deepseek-flash", operation: "complete")))
    let pending = try await gateway.propose(handle: handle, connectionID: id, request: request(), streaming: false)
    let approved = try await gateway.hostApprove(handle: handle, proposal: pending)
    _ = try await gateway.execute(handle: handle, approval: approved)
    let lines = try String(contentsOf: path, encoding: .utf8).split(separator: "\n")
    struct Event: Decodable { let reason: String }
    let events = try lines.map { try JSONDecoder().decode(Event.self, from: Data($0.utf8)) }
    try require(
        events.map(\.reason) == ["dispatch-intent", "dispatch-completion"], "real F03 JSONL sink persists audit pair")
    try require(
        FixtureProtocol.fixture.lock.withLock { FixtureProtocol.fixture.intentSeen == [true] },
        "durable intent file visible at actual upstream hit")
}
final class Clock: @unchecked Sendable {
    let source = RunClock.manual(wall: Date())
    func now() -> Date { source.now() }
    func advance(_ seconds: TimeInterval) { source.advance(seconds) }
}
func testApprovalExpiration() async throws {
    let clock = Clock()
    let audit = Audit()
    let credentials = Credentials()
    let id = UUID()
    FixtureProtocol.fixture.reset(audit)
    let gateway = try HostModelGateway(
        connections: [connection(id, credentials)], auditSink: audit, clock: clock.source)
    let handle = try await gateway.install(
        grant: grant(
            connection: id, scope: ResourceScope(service: "model", resource: "deepseek-flash", operation: "complete")))
    let pending = try await gateway.propose(handle: handle, connectionID: id, request: request(), streaming: false)
    clock.advance(301)
    try await rejected { _ = try await gateway.hostApprove(handle: handle, proposal: pending) }
    try require(
        credentials.count == 0 && FixtureProtocol.fixture.hits == 0, "expired proposal never accesses credentials")
}
func testStopDuringCompletionAudit() async throws {
    let s = try await Setup(streaming: true)
    let approval = try await s.approve(streaming: true)
    let chunks = Chunks()
    let barrier = AuditBarrier("dispatch-completion")
    s.audit.lock.withLock { s.audit.barrier = barrier }
    let execution = Task {
        try await s.gateway.execute(handle: s.handle, approval: approval) { chunks.append($0, audit: s.audit) }
    }
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
        chunks.lock.withLock { !chunks.values.contains(where: \.isFinal) },
        "STOP suppresses late final after completion audit await")
    try require(
        FixtureProtocol.fixture.hits == 1 && s.audit.snapshot.count == 2,
        "completion already observed upstream remains one audit; no compensating duplicate")
}
