import Foundation
import SandboxHost
import SandboxContracts

// Pulse only the deadline sample, then return valid time even during error
// reconciliation. This prevents a later clock read from accidentally fixing it.
final class StartGateClock: @unchecked Sendable {
    let source: RunClock; let initial: Date; let expired: Date
    init(initial: Date, expired: Date) { self.initial = initial; self.expired = expired; source = .manual(wall: initial) }
    func arm(afterValidSamples count: Int) { if !didObserve { source.arm(at: count + 1, wall: expired) } }
    func rollback() { source.disarm() }
    var didObserve: Bool { source.observation.1 }
    func now() -> Date { source.now() }
}
final class StartGateAudit: SynchronousAuditSink, @unchecked Sendable {
    let audit = Audit(); let clock: StartGateClock; let preCredential: Bool
    init(_ clock: StartGateClock, preCredential: Bool) { self.clock = clock; self.preCredential = preCredential }
    func append(_ event: SecurityEvent) throws {
        try audit.append(event)
        // After consume: validate/live, envelope/live, then pre-start sample.
        if preCredential && event.reason == "dispatch-intent" { clock.arm(afterValidSamples: 2) }
    }
}
final class StartGateCredentials: ModelCredentialProvider, @unchecked Sendable {
    let credentials = Credentials(); let clock: StartGateClock; let postPreparation: Bool
    init(_ clock: StartGateClock, postPreparation: Bool) { self.clock = clock; self.postPreparation = postPreparation }
    var count: Int { credentials.count }
    func credential(for model: FixedModel) throws -> String {
        let value = try credentials.credential(for: model)
        // After preparation: validate/live, then the final pre-start sample.
        if postPreparation { clock.arm(afterValidSamples: 1) }
        return value
    }
}
func testStartGateRunExpiry(postPreparation: Bool, notYetValid: Bool = false) async throws {
    let id = UUID()
    let scope = try ResourceScope(service: "model", resource: "deepseek-flash", operation: "complete")
    let grant = try grant(connection: id, scope: scope)
    let clock = StartGateClock(initial: grant.createdAt.addingTimeInterval(1),
        expired: notYetValid ? grant.createdAt.addingTimeInterval(-1) : grant.expiresAt)
    let sink = StartGateAudit(clock, preCredential: !postPreparation)
    let credentials = StartGateCredentials(clock, postPreparation: postPreparation)
    FixtureProtocol.fixture.reset(sink.audit)
    let connection = HostModelConnection(connectionID: id, accountID: UUID(), accountBindingVersion: 7, routeVersion: 11,
        model: .deepSeekFlash, protocol: .openAI, credentialProvider: credentials, configuration: configuration())
    let gateway = try HostModelGateway(connections: [connection], auditSink: sink, clock: clock.source)
    let handle = try await gateway.install(grant: grant)
    func approve() async throws -> HostModelApproval {
        let proposal = try await gateway.propose(handle: handle, connectionID: id, request: request(), streaming: false)
        return try await gateway.hostApprove(handle: handle, proposal: proposal)
    }
    let older = try await approve(); let expiring = try await approve()
    var firstError: HostModelGatewayError?
    do { _ = try await gateway.execute(handle: handle, approval: expiring) }
    catch { firstError = error as? HostModelGatewayError }
    // Capture all immediate state BEFORE rollback or any mutating gateway API.
    let observed = clock.didObserve
    let revoked = try await gateway.isRevoked(handle: handle)
    let priorReads = credentials.count; let priorHits = FixtureProtocol.fixture.hits
    let firstEvents = sink.audit.snapshot
    clock.rollback()
    var olderSucceeded = false
    do { _ = try await gateway.execute(handle: handle, approval: older); olderSucceeded = true } catch {}
    let newReads = credentials.count - priorReads; let newHits = FixtureProtocol.fixture.hits - priorHits
    try require(firstError == .notStarted && observed && revoked == !notYetValid && priorReads == (postPreparation ? 1 : 0) && priorHits == 0
        && olderSucceeded == notYetValid && newReads == (notYetValid ? 1 : 0) && newHits == (notYetValid ? 1 : 0),
        "deadline sample run expiry: error=\(String(describing: firstError)), observed=\(observed), immediateRevoked=\(revoked), priorReads=\(priorReads), priorHits=\(priorHits), rollbackSuccess=\(olderSucceeded), newReads=\(newReads), newHits=\(newHits)")
    try require(firstEvents.map(\.reason) == ["dispatch-intent", "dispatch-completion"] && firstEvents.last?.outcome == .failed,
        "issued unstarted ticket completes exactly once despite terminal expiry")
    try require(sink.audit.snapshot.count == firstEvents.count + (notYetValid ? 2 : 0),
        "only a nonterminal not-yet-valid denial allows the older approval; no duplicate completion")
}

final class AdvancingAudit: SynchronousAuditSink, @unchecked Sendable {
    let audit = Audit(); let clock: Clock
    let lock = NSLock(); var reason: String?; var seconds: TimeInterval = 301
    init(_ clock: Clock, reason: String? = nil) { self.clock = clock; self.reason = reason }
    func append(_ event: SecurityEvent) throws {
        try audit.append(event)
        let delay = lock.withLock { reason == event.reason ? seconds : 0 }
        clock.advance(delay)
    }
}
final class AdvancingCredentials: ModelCredentialProvider, @unchecked Sendable {
    let clock: Clock; let lock = NSLock(); var delay: TimeInterval = 0; var reads = 0
    init(_ clock: Clock) { self.clock = clock }
    var count: Int { lock.withLock { reads } }
    func credential(for model: FixedModel) throws -> String {
        let delay = lock.withLock { reads += 1; return self.delay }
        clock.advance(delay)
        return "fixture-only-secret"
    }
}
struct TimedSetup {
    let clock: Clock; let sink: AdvancingAudit; let credentials: AdvancingCredentials
    let id: UUID; let gateway: HostModelGateway; let handle: HostModelRunHandle
    init(reason: String? = nil, credentialDelay: TimeInterval = 0, streaming: Bool = false, hangs: Bool = false) async throws {
        clock = Clock(); sink = AdvancingAudit(clock, reason: reason); credentials = AdvancingCredentials(clock); id = UUID()
        credentials.delay = credentialDelay
        FixtureProtocol.fixture.reset(sink.audit, stream: streaming, hangs: hangs)
        let connection = HostModelConnection(connectionID: id, accountID: UUID(), accountBindingVersion: 7, routeVersion: 11,
            model: .deepSeekFlash, protocol: .openAI, credentialProvider: credentials, configuration: configuration())
        gateway = try HostModelGateway(connections: [connection], auditSink: sink, clock: clock.source)
        let scope = try ResourceScope(service: "model", resource: "deepseek-flash", operation: streaming ? "stream" : "complete")
        let grant = try RunGrant(runID: UUID(), epoch: 1, createdAt: clock.now(), expiresAt: clock.now().addingTimeInterval(600),
            workloadImageDigest: String(repeating: "a", count: 64), agentAdapterVersion: "fixture", workspaceSnapshotID: UUID(),
            policyDigest: String(repeating: "b", count: 64), approvalSnapshotID: UUID(),
            connections: [ConnectionGrant(connectionID: id, accountBindingVersion: 7, routeVersion: 11, scopes: [scope])],
            explicitDenies: [], resourceLimits: ResourceLimits(cpuCount: 1, memoryBytes: 1, diskBytes: 1, messageBytes: 8192, concurrentRequests: 1))
        handle = try await gateway.install(grant: grant)
    }
    func propose(streaming: Bool = false) async throws -> HostModelProposal {
        try await gateway.propose(handle: handle, connectionID: id, request: request(), streaming: streaming)
    }
    func approve(streaming: Bool = false) async throws -> HostModelApproval {
        try await gateway.hostApprove(handle: handle, proposal: propose(streaming: streaming))
    }
}
final class ProposalSequenceClock: @unchecked Sendable {
    let source: RunClock; let initial: Date; let expired: Date
    init(initial: Date, expired: Date) { self.initial = initial; self.expired = expired; source = .manual(wall: initial) }
    func arm() { source.arm(at: 2, wall: expired, persistent: true) }
    func rollback() { source.disarm() }
    func now() -> Date { source.now() }
}
struct ProposalSequenceSetup {
    let clock: ProposalSequenceClock; let audit = Audit(); let credentials = Credentials(); let id = UUID()
    let gateway: HostModelGateway; let handle: HostModelRunHandle
    init(explicitDeny: Bool) async throws {
        let allowed = try ResourceScope(service: "model", resource: "deepseek-flash", operation: "complete")
        let denied = try ResourceScope(service: "model", resource: "deepseek-flash", operation: "stream")
        let grant = try grant(connection: id, scope: allowed, denies: explicitDeny ? [denied] : [])
        clock = ProposalSequenceClock(initial: grant.createdAt.addingTimeInterval(1), expired: grant.expiresAt)
        FixtureProtocol.fixture.reset(audit)
        gateway = try HostModelGateway(connections: [connection(id, credentials)], auditSink: audit, clock: clock.source)
        handle = try await gateway.install(grant: grant)
    }
    func propose(streaming: Bool = false) async throws -> HostModelProposal {
        try await gateway.propose(handle: handle, connectionID: id, request: request(), streaming: streaming)
    }
}
func testProposalSecondSampleExpiry(explicitDeny: Bool) async throws {
    let s = try await ProposalSequenceSetup(explicitDeny: explicitDeny)
    let approval = try await s.gateway.hostApprove(handle: s.handle, proposal: s.propose())
    // Arm only after the older approval exists: live sees valid time, scope sees expiry.
    s.clock.arm()
    try await rejected { _ = try await s.propose(streaming: explicitDeny) }
    let revoked = try await s.gateway.isRevoked(handle: s.handle)
    s.clock.rollback()
    var dispatched = false
    do { _ = try await s.gateway.execute(handle: s.handle, approval: approval); dispatched = true } catch {}
    try require(revoked && !dispatched && s.credentials.count == 0 && FixtureProtocol.fixture.hits == 0,
        "second clock sample expiry must latch immediately; rollback must not revive older approval (revoked=\(revoked), dispatched=\(dispatched), reads=\(s.credentials.count), hits=\(FixtureProtocol.fixture.hits))")
    try require(s.audit.snapshot.isEmpty, "expired proposal has no dispatch audit")
}
func testScopeDenialKeepsApprovalLive() async throws {
    for explicitDeny in [false, true] {
        let s = try await ProposalSequenceSetup(explicitDeny: explicitDeny)
        let approval = try await s.gateway.hostApprove(handle: s.handle, proposal: s.propose())
        do { _ = try await s.propose(streaming: true); throw Failure("scope denial accepted") }
        catch let error as HostModelGatewayError { try require(error == .denied, "ordinary scope denial remains denied") }
        let revoked = try await s.gateway.isRevoked(handle: s.handle)
        try require(!revoked && s.credentials.count == 0 && FixtureProtocol.fixture.hits == 0, "valid scope denial must not revoke")
        let result = try await s.gateway.execute(handle: s.handle, approval: approval)
        try require(result.text == "hello" && s.credentials.count == 1 && FixtureProtocol.fixture.hits == 1,
            "unrelated valid approval remains usable after scope denial")
    }
}
func testActionDeadlineAtStart(credentialDelay: Bool) async throws {
    let s = try await TimedSetup(reason: credentialDelay ? nil : "dispatch-intent", credentialDelay: credentialDelay ? 301 : 0)
    let approval = try await s.approve()
    do { _ = try await s.gateway.execute(handle: s.handle, approval: approval); throw Failure("expired action actually dispatched") }
    catch let error as HostModelGatewayError { try require(error == .notStarted, "expired issued ticket reports notStarted") }
    try require(s.credentials.count == (credentialDelay ? 1 : 0) && FixtureProtocol.fixture.hits == 0, "deadline checked before credentials and again before resume")
    let revoked = try await s.gateway.isRevoked(handle: s.handle)
    try require(!revoked, "action-only expiry while grant is live must remain nonterminal")
    try require(s.sink.audit.snapshot.map(\.reason) == ["dispatch-intent", "dispatch-completion"] && s.sink.audit.snapshot.last?.outcome == .failed, "unstarted ticket completed exactly once as failed")
    try await rejected { _ = try await s.gateway.execute(handle: s.handle, approval: approval) }
    try require(s.sink.audit.snapshot.count == 2 && FixtureProtocol.fixture.hits == 0, "no ticket replay or duplicate completion")
}
func testActionDeadlineDoesNotLimitCompletion() async throws {
    let s = try await TimedSetup(reason: "dispatch-completion", streaming: true); let chunks = Chunks()
    let approval = try await s.approve(streaming: true)
    let result = try await s.gateway.execute(handle: s.handle, approval: approval) { chunks.append($0, audit: s.sink.audit) }
    try require(result.text == "onetwo" && FixtureProtocol.fixture.hits == 1 && s.credentials.count == 1, "on-time start survives action deadline crossed in completion audit")
    try require(chunks.lock.withLock { chunks.values.filter(\.isFinal).count == 1 && chunks.auditedFinal }, "completion remains audited success")
}
func testGrantExpiryLatches(entry: String) async throws {
    let s = try await TimedSetup()
    let approval = try await s.approve(); let pending = try await s.propose()
    s.clock.advance(601)
    try await rejected {
        switch entry {
        case "propose": _ = try await s.propose()
        case "approve": _ = try await s.gateway.hostApprove(handle: s.handle, proposal: pending)
        case "deny": try await s.gateway.hostDeny(handle: s.handle, proposal: pending)
        default: _ = try await s.gateway.execute(handle: s.handle, approval: approval)
        }
    }
    let revoked = try await s.gateway.isRevoked(handle: s.handle)
    s.clock.advance(-601)
    // Always exercise rollback even if the immediate state assertion would fail.
    var dispatched = false
    do { _ = try await s.gateway.execute(handle: s.handle, approval: approval); dispatched = true } catch {}
    try require(revoked && !dispatched && s.credentials.count == 0 && FixtureProtocol.fixture.hits == 0,
        "expiry observation must latch immediately; host clock rollback must not revive approval")
    try require(s.sink.audit.snapshot.isEmpty, "early expiry denial does not invent F03 audit records")
}
func testExpiryPreservesOutstandingCompletion() async throws {
    let s = try await TimedSetup(hangs: true); let approval = try await s.approve()
    let execution = Task { try await s.gateway.execute(handle: s.handle, approval: approval) }
    try await waitUntil { FixtureProtocol.fixture.hits == 1 }
    s.clock.advance(601)
    try await rejected { _ = try await s.propose() }
    let revoked = try await s.gateway.isRevoked(handle: s.handle)
    s.clock.advance(-601)
    // Prevent a hanging RED run without repairing the observed local state.
    if !revoked { execution.cancel() }
    let result = await execution.result
    guard case .failure(let error) = result else { throw Failure("expired in-flight operation succeeded") }
    try require(revoked && error as? HostModelGatewayError == .outcomeUnknown, "expiry latches and cancels outstanding operation")
    try require(s.sink.audit.snapshot.map(\.reason) == ["dispatch-intent", "dispatch-completion"] && s.sink.audit.snapshot.last?.outcome == .unknown,
        "F03 reconciliation preserves issued completion exactly once")
    try require(FixtureProtocol.fixture.hits == 1 && s.credentials.count == 1, "no additional dispatch")
}
func testGatewaySequentialCapacityReuse() async throws {
    let s = try await TimedSetup(credentialDelay: 301)
    let expired = try await s.approve()
    do { _ = try await s.gateway.execute(handle: s.handle, approval: expired); throw Failure("expected pre-start deadline failure") }
    catch let error as HostModelGatewayError { try require(error == .notStarted, "pre-start failure") }
    s.credentials.lock.withLock { s.credentials.delay = 0 }
    for _ in 0..<8 {
        let approval = try await s.approve()
        let result = try await s.gateway.execute(handle: s.handle, approval: approval)
        try require(result.text == "hello", "run/transport capacity reused after pre-start failure and success")
    }
    try require(s.credentials.count == 9 && FixtureProtocol.fixture.hits == 8, "only successful starts hit transport")
    let completions = s.sink.audit.snapshot.filter { $0.reason == "dispatch-completion" }
    try require(completions.count == 9 && completions.first?.outcome == .failed && completions.dropFirst().allSatisfy { $0.outcome == .completed }, "one completion per reused reservation")
}
