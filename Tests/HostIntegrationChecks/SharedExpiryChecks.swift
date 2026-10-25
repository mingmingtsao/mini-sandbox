import Foundation
import SharedClockSupport
import SandboxHost
import SandboxContracts

typealias SharedModelPulseClock = SharedHostClock
final class SharedModelPulseAudit: SynchronousAuditSink, @unchecked Sendable {
    let audit = Audit()
    let clock: SharedModelPulseClock
    private let lock = NSLock()
    private var positions: [String: Int] = [:]
    init(_ clock: SharedModelPulseClock) { self.clock = clock }
    func append(_ event: SecurityEvent) throws {
        lock.withLock { positions[event.reason] = clock.observation.0 }
        try audit.append(event)
    }
    func position(_ reason: String) -> Int? { lock.withLock { positions[reason] } }
}

/// While F03 is blocked in the actual audit callback, the gateway must already
/// see expiry. An await-return-only reconciliation patch cannot satisfy this.
func testSharedExpiryBeforeAuditReturn() async throws {
    let clock = SharedModelPulseClock(), id = UUID(), credentials = Credentials()
    let sink = SharedModelPulseAudit(clock)
    FixtureProtocol.fixture.reset(sink.audit)
    let scope = try ResourceScope(service: "model", resource: "deepseek-flash", operation: "complete")
    let g = try RunGrant(runID: UUID(), epoch: 1, createdAt: clock.base, expiresAt: clock.base.addingTimeInterval(900), workloadImageDigest: String(repeating: "a", count: 64), agentAdapterVersion: "fixture", workspaceSnapshotID: UUID(), policyDigest: String(repeating: "b", count: 64), approvalSnapshotID: UUID(), connections: [ConnectionGrant(connectionID: id, accountBindingVersion: 7, routeVersion: 11, scopes: [scope])], explicitDenies: [], resourceLimits: ResourceLimits(cpuCount: 1, memoryBytes: 1, diskBytes: 1, messageBytes: 8192, concurrentRequests: 2))
    let gateway = try HostModelGateway(connections: [connection(id, credentials)], auditSink: sink, now: clock.now)
    let handle = try await gateway.install(grant: g)
    let pending = try await gateway.propose(handle: handle, connectionID: id, request: request(), streaming: false)
    let barrier = AuditBarrier("explicit-deny")
    sink.audit.lock.withLock { sink.audit.barrier = barrier }
    clock.arm(2)
    let denial = Task { try await gateway.hostDeny(handle: handle, proposal: pending) }
    do { try await waitUntil { sink.audit.snapshot.contains { $0.reason == "explicit-deny" } } }
    catch { barrier.release.signal(); _ = await denial.result; throw error }
    let observedBeforeReturn = try await gateway.isRevoked(handle: handle)
    barrier.release.signal()
    _ = await denial.result // a persisted denial need not throw
    print("MODEL_CONCURRENT_PULSE audit_blocked_observation=\(observedBeforeReturn) fired=\(clock.observation.1) reads=\(credentials.count) offline_URLProtocol_starts=\(FixtureProtocol.fixture.hits)")
    try require(clock.observation.1 && observedBeforeReturn, "expiry must be immediately observable across actors before authority returns")
    try require(credentials.count == 0 && FixtureProtocol.fixture.hits == 0, "control observation never dispatches")
}

/// The baseline measures real host-clock reads; no guessed completion anchor.
func testSharedModelExpiry(path: String, streaming: Bool = false) async throws {
    var target = 2 // hostDeny validation, then F03 denial timestamp.
    for baseline in (path == "deny" ? [false] : [true, false]) {
        let clock = SharedModelPulseClock(), id = UUID(), credentials = Credentials()
        let sink = SharedModelPulseAudit(clock)
        FixtureProtocol.fixture.reset(sink.audit, stream: streaming)
        let scope = try ResourceScope(service: "model", resource: "deepseek-flash", operation: streaming ? "stream" : "complete")
        let g = try RunGrant(runID: UUID(), epoch: 1, createdAt: clock.base, expiresAt: clock.base.addingTimeInterval(900), workloadImageDigest: String(repeating: "a", count: 64), agentAdapterVersion: "fixture", workspaceSnapshotID: UUID(), policyDigest: String(repeating: "b", count: 64), approvalSnapshotID: UUID(), connections: [ConnectionGrant(connectionID: id, accountBindingVersion: 7, routeVersion: 11, scopes: [scope])], explicitDenies: [], resourceLimits: ResourceLimits(cpuCount: 1, memoryBytes: 1, diskBytes: 1, messageBytes: 8192, concurrentRequests: 2))
        let gateway = try HostModelGateway(connections: [connection(id, credentials)], auditSink: sink, now: clock.now)
        let handle = try await gateway.install(grant: g)
        let b = try await gateway.propose(handle: handle, connectionID: id, request: request(), streaming: streaming)
        let approvedB = try await gateway.hostApprove(handle: handle, proposal: b)
        let a = try await gateway.propose(handle: handle, connectionID: id, request: request(), streaming: streaming)
        let approvedA = path == "deny" ? nil : try await gateway.hostApprove(handle: handle, proposal: a)
        let chunks = Chunks()
        clock.arm(baseline ? Int.max : target)
        var succeeded = false
        var auditFailed = false
        do {
            if path == "deny" { try await gateway.hostDeny(handle: handle, proposal: a) }
            else { _ = try await gateway.execute(handle: handle, approval: approvedA!) { chunks.append($0, audit: sink.audit) } }
            succeeded = true
        } catch { auditFailed = error as? HostModelGatewayError == .auditFailed }
        if baseline {
            try require(succeeded && FixtureProtocol.fixture.hits == 1, "baseline actually starts offline URLProtocol")
            guard let position = sink.position(path == "intent" ? "dispatch-intent" : "dispatch-completion") else { throw Failure("audit clock anchor absent") }
            target = position
            continue
        }
        // Capture before another API could repair local state.
        let revoked = try await gateway.isRevoked(handle: handle)
        let observed = clock.observation
        let reads = credentials.count, hits = FixtureProtocol.fixture.hits
        let terminal = chunks.lock.withLock { chunks.values.filter(\.isTerminal).count }
        let firstEvents = sink.audit.snapshot
        var rollbackSuccess = false
        do { _ = try await gateway.execute(handle: handle, approval: approvedB); rollbackSuccess = true } catch {}
        print("MODEL_PULSE path=\(path) streaming=\(streaming) target=\(target) samples=\(observed.0) fired=\(observed.1) immediate_revoked=\(revoked) succeeded=\(succeeded) reads=\(reads) offline_URLProtocol_starts=\(hits) terminal_callbacks=\(terminal) rollback_success=\(rollbackSuccess) rollback_reads=\(credentials.count - reads) rollback_starts=\(FixtureProtocol.fixture.hits - hits)")
        try require(observed.1 && !auditFailed, "expiry observed without fabricated audit failure")
        if path == "deny" { try require(firstEvents.filter { $0.reason == "explicit-deny" }.count == 1, "denial durable once; normal denial return is allowed") }
        if path == "completion" { try require(firstEvents.filter { $0.reason == "dispatch-completion" && $0.outcome == .completed }.count == 1, "actual supplied completion outcome preserved once") }
        try require(revoked && !rollbackSuccess && credentials.count == reads && FixtureProtocol.fixture.hits == hits, "shared authority expiry must latch immediately and prevent old B dispatch")
        if path != "deny" { try require(!succeeded && terminal == 0, "expired execution cannot release completion or terminal stream signals") }
        if path == "intent" { try require(reads == 0 && hits == 0, "intent expiry gates credential preparation and actual start") }
    }
}
