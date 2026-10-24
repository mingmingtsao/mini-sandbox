import Foundation
@testable import SandboxHost
import SandboxContracts

final class Clock: @unchecked Sendable {
    let lock = NSLock(); var value = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.withLock { value } }
    func advance(_ amount: TimeInterval) { lock.withLock { value = value.addingTimeInterval(amount) } }
}
final class Gate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    func block() { entered.signal(); _ = release.wait(timeout: .now() + 5) }
    func awaitEntry() -> Bool { entered.wait(timeout: .now() + 3) == .success }
    func open() { release.signal() }
}
final class BlockedCredentials: ModelCredentialProvider, @unchecked Sendable {
    let gate = Gate(); let lock = NSLock(); private var reads = 0
    func credential(for model: FixedModel) throws -> String {
        lock.withLock { reads += 1 }; gate.block(); return "synthetic-blocked-preparation"
    }
    var count: Int { lock.withLock { reads } }
}
func lifecycle(_ clock: Clock) -> RunLifecycle {
    RunLifecycle(expiresAt: clock.now().addingTimeInterval(600), epoch: 1, installedAt: clock.now(), wall: { clock.now() }, monotonic: { .zero })
}
func transportRequest() throws -> FixedModelRequest {
    try FixedModelRequest(model: .deepSeekFlash, protocol: .openAI, messages: [FixedMessage(role: .user, content: "offline")], maxOutputTokens: 32)
}
func testActualStartGate(_ mode: String) async throws {
    let clock = Clock(), credentials = Credentials(), id = UUID()
    let authority = lifecycle(clock), config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [OfflineProtocol.self]
    let op = try ModelTransport(credentialProvider: credentials, configuration: config).prepare(transportRequest(), streaming: false)
    defer { op.cancel() }
    let scope = authority.effectScope(connectionID: id), startDeadline = clock.now().addingTimeInterval(300)
    switch mode {
    case "stop": authority.terminate(.stopped)
    case "expiry-rollback": clock.advance(600); _ = authority.observeAndReduce(reason: "test"); clock.advance(-600)
    case "action-deadline": clock.advance(300)
    case "connection": authority.invalidateConnection(id)
    case "cancelled-prepared": op.cancel()
    default: throw Failure(message: "invalid test")
    }
    do {
        try authority.start(.model(op), id: UUID(), scope: scope, notBefore: clock.now().addingTimeInterval(-1), startDeadline: startDeadline)
        throw Failure(message: "start after invalidation")
    } catch is AuthorizationError {} catch is ModelTransportError {}
    try check(op.resumeCalls == 0 && credentials.count == 1, "actual resume gate failed")
    if mode == "action-deadline" { try check(authority.currentStatus == .active, "action expiry killed sibling run") }
    print("PASS actual-resume-\(mode) credential_reads=1 actual_resume_calls=0")
}
func testBlockedPreparation() async throws {
    let clock = Clock(), authority = lifecycle(clock), credentials = BlockedCredentials()
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [OfflineProtocol.self]
    let transport = ModelTransport(credentialProvider: credentials, configuration: config)
    let scope = authority.effectScope(connectionID: UUID()), deadline = clock.now().addingTimeInterval(300)
    let prep = Task.detached { try transport.prepare(transportRequest(), streaming: false) }
    try check(credentials.gate.awaitEntry(), "credential barrier not entered")
    authority.terminate(.stopped) // must not wait for credential provider
    credentials.gate.open()
    let op = try await prep.value; defer { op.cancel() }
    do { try authority.start(.model(op), id: UUID(), scope: scope, notBefore: clock.now(), startDeadline: deadline); throw Failure(message: "late preparation started") }
    catch is AuthorizationError {}
    try check(credentials.count == 1 && op.resumeCalls == 0, "returned preparation escaped stop")
    print("PASS blocked-preparation-stop credential_reads=1 actual_resume_calls=0")
}
func testConsumerSequence() throws {
    let clock = Clock(), authority = lifecycle(clock), id = UUID()
    let output = ControlledRunOutput(lifecycle: authority, scope: authority.effectScope(connectionID: id))
    try output.enqueue(.modelChunk(ModelStreamChunk(text: "first", isFinal: false)))
    try output.enqueue(.modelChunk(ModelStreamChunk(text: "second", isFinal: false)))
    try output.enqueue(.modelChunk(ModelStreamChunk(event: .messageDelta(ModelMetadata(stopReason: "end_turn")))))
    try output.enqueue(.modelChunk(ModelStreamChunk(text: "", isFinal: true)))
    try check(try output.acceptNext(), "first chunk was not accepted")
    authority.terminate(.stopped)
    do { _ = try output.acceptNext(); throw Failure(message: "next chunk accepted after stop") } catch is AuthorizationError {}
    try check(output.summary.acceptedEvents == 1 && output.summary.acceptedTextBytes == 5 && output.summary.acceptedFinals == 0 && output.summary.acceptedMetadata == 0, "terminal event consumer leak")
    print("PASS first-consumer-chunk-then-stop accepted=1 next_metadata_final=0")
}
func testConnectionIsolation(revisionOnly: Bool = false) throws {
    let clock = Clock(), authority = lifecycle(clock), a = UUID(), b = UUID()
    let left = ControlledRunOutput(lifecycle: authority, scope: authority.effectScope(connectionID: a))
    let right = ControlledRunOutput(lifecycle: authority, scope: authority.effectScope(connectionID: b))
    try left.enqueue(.modelCompletion(ModelCompletion(text: "left")))
    try right.enqueue(.modelCompletion(ModelCompletion(text: "right")))
    if revisionOnly { authority.advanceConnection(a) } else { authority.invalidateConnection(a) }
    do { _ = try left.acceptNext(); throw Failure(message: "invalid connection delivered") } catch is AuthorizationError {}
    try check(try right.acceptNext(), "unrelated connection invalidated")
    try check(left.summary.acceptedEvents == 0 && right.summary.acceptedEvents == 1 && authority.currentStatus == .active, "connection isolation")
    print("PASS \(revisionOnly ? "catalog-revision" : "connection")-consumer-isolation revoked_deliveries=0 sibling_deliveries=1")
}
func testMCPPreResumeStop() throws {
    let clock = Clock(), authority = lifecycle(clock), credentials = LoopbackCredentials("synthetic-mcp-boundary")
    let id = UUID()
    let connection = try HostMCPConnection.testOnlyLoopback(connectionID: id, accountID: UUID(), port: 1, provider: credentials)
    let op = try MCPPreparedOperation(connection: connection, payload: ModelJSON.parse(mcpControl("tools/list")), limit: 65536)
    defer { op.cancel() }
    let scope = authority.effectScope(connectionID: id)
    authority.terminate(.stopped)
    do { try authority.start(.mcp(op), id: UUID(), scope: scope, notBefore: clock.now(), startDeadline: clock.now().addingTimeInterval(300)); throw Failure(message: "MCP late resume") }
    catch is AuthorizationError {}
    try check(credentials.count == 1 && op.resumeCalls == 0, "MCP actual resume count")
    print("PASS actual-mcp-pre-resume-stop credential_reads=1 actual_resume_calls=0")
}
final class StartClock: @unchecked Sendable {
    let lock = NSLock(), gate = Gate(); var armed = false
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date {
        let block = lock.withLock { let value = armed; armed = false; return value }
        if block { gate.block() }
        return date
    }
    func arm() { lock.withLock { armed = true } }
}
func testStopDuringFinalObservation() async throws {
    let clock = StartClock(), credentials = Credentials()
    let authority = RunLifecycle(expiresAt: clock.date.addingTimeInterval(600), epoch: 1, installedAt: clock.date, wall: { clock.now() }, monotonic: { .zero })
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [OfflineProtocol.self]
    let op = try ModelTransport(credentialProvider: credentials, configuration: config).prepare(transportRequest(), streaming: false)
    defer { op.cancel() }
    let scope = authority.effectScope(connectionID: UUID())
    clock.arm()
    let start = Task.detached { try authority.start(.model(op), id: UUID(), scope: scope, notBefore: clock.date, startDeadline: clock.date.addingTimeInterval(300)) }
    try check(clock.gate.awaitEntry(), "final observation not reached")
    authority.terminate(.stopped)
    clock.gate.open()
    do { try await start.value; throw Failure(message: "final observation escaped terminal fence") } catch is AuthorizationError {}
    try check(op.resumeCalls == 0 && credentials.count == 1, "final observation actual start count")
    print("PASS stop-during-final-observation credential_reads=1 actual_resume_calls=0")
}
func boundaryChecks() async throws {
    for mode in ["stop", "expiry-rollback", "action-deadline", "connection", "cancelled-prepared"] { try await testActualStartGate(mode) }
    try await testBlockedPreparation()
    try testMCPPreResumeStop()
    try await testStopDuringFinalObservation()
    try testConsumerSequence()
    try testConnectionIsolation()
    try testConnectionIsolation(revisionOnly: true)
}
