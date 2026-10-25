import Foundation
import SandboxHost
import SandboxContracts

struct Failure: Error { let message: String }
func check(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
final class Probe: @unchecked Sendable {
    let lock = NSLock()
    let arrived = DispatchSemaphore(value: 0)
    let stopped = DispatchSemaphore(value: 0)
    var hits = 0
    var response: Data?
    var cleanup: (@Sendable () -> Void)?
    func setCleanup(_ callback: (@Sendable () -> Void)?) { lock.withLock { cleanup = callback } }
    func didStop() {
        let callback = lock.withLock { cleanup }
        callback?()
        stopped.signal()
    }
    func setResponse(_ data: Data) { lock.withLock { response = data } }
    var body: Data? { lock.withLock { response } }
    func hit() { lock.withLock { hits += 1 }; arrived.signal() }
    var count: Int { lock.withLock { hits } }
    func awaitArrival() -> Bool { arrived.wait(timeout: .now() + 3) == .success }
    func awaitStop() -> Bool { stopped.wait(timeout: .now() + 1) == .success }
}
final class OfflineProtocol: URLProtocol {
    static let probe = Probe()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.probe.hit()
        if let body = Self.probe.body {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { Self.probe.didStop() }
}
final class Credentials: ModelCredentialProvider, @unchecked Sendable {
    let lock = NSLock(); private var reads = 0
    func credential(for model: FixedModel) throws -> String { lock.withLock { reads += 1 }; return "offline-synthetic-value" }
    var count: Int { lock.withLock { reads } }
}
final class Audit: SynchronousAuditSink, @unchecked Sendable {
    let lock = NSLock(); private var events: [SecurityEvent] = []
    func append(_ event: SecurityEvent) throws { lock.withLock { events.append(event) } }
    var completions: [SecurityEvent] { lock.withLock { events.filter { $0.reason == "dispatch-completion" } } }
}
func sharedStopCancelsStarted() async throws {
    let id = UUID(), audit = Audit(), credentials = Credentials()
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [OfflineProtocol.self]
    let connection = HostModelConnection(connectionID: id, accountID: UUID(), accountBindingVersion: 1, routeVersion: 1, model: .deepSeekFlash, protocol: .openAI, credentialProvider: credentials, configuration: config)
    let scope = try ResourceScope(service: "model", resource: "deepseek-flash", operation: "complete")
    let grant = try RunGrant(runID: UUID(), epoch: 1, createdAt: Date().addingTimeInterval(-1), expiresAt: Date().addingTimeInterval(600), workloadImageDigest: String(repeating: "a", count: 64), agentAdapterVersion: "offline", workspaceSnapshotID: UUID(), policyDigest: String(repeating: "b", count: 64), approvalSnapshotID: UUID(), connections: [ConnectionGrant(connectionID: id, accountBindingVersion: 1, routeVersion: 1, scopes: [scope])], explicitDenies: [], resourceLimits: ResourceLimits(cpuCount: 1, memoryBytes: 1, diskBytes: 1, messageBytes: 8192, concurrentRequests: 1))
    let gateway = try HostModelGateway(connections: [connection], auditSink: audit)
    let handle = try await gateway.install(grant: grant)
    let lifecycle = try await gateway.lifecycle(handle: handle)
    OfflineProtocol.probe.setCleanup {
        _ = lifecycle.currentStatus
        lifecycle.terminate(.stopped) // OS cleanup re-enters the same authority.
    }
    defer { OfflineProtocol.probe.setCleanup(nil) }
    let request = try FixedModelRequest(model: .deepSeekFlash, protocol: .openAI, messages: [FixedMessage(role: .user, content: "offline")], maxOutputTokens: 32)
    let proposal = try await gateway.propose(handle: handle, connectionID: id, request: request, streaming: false)
    let approval = try await gateway.hostApprove(handle: handle, proposal: proposal)
    let task = Task { try await gateway.execute(handle: handle, approval: approval) }
    try check(OfflineProtocol.probe.awaitArrival(), "actual URLProtocol arrival missing")
    lifecycle.terminate(.stopped)
    let cancelled = OfflineProtocol.probe.awaitStop()
    task.cancel() // bounded cleanup also on the RED baseline
    do { _ = try await task.value; throw Failure(message: "late business success") }
    catch let error as HostModelGatewayError { try check(error == .outcomeUnknown, "started outcome must stay unknown") }
    try check(credentials.count == 1 && OfflineProtocol.probe.count == 1, "credential and actual arrival counters")
    try check(audit.completions.count == 1 && audit.completions.first?.outcome == .unknown, "exactly one unknown completion")
    try check(cancelled, "shared terminal did not proactively cancel the actual registered URLSession task")
    try check(lifecycle.registeredEffectCount == 0, "terminal registration retained")
    print("OBS R3-I gateway_completion_count=\(audit.completions.count) audit_sequence=\(audit.completions.first!.hostSequence) registered=\(lifecycle.registeredEffectCount) actual_arrivals=\(OfflineProtocol.probe.count)")
}
func queuedOutputStopsAtConsumer() async throws {
    let now = Date(), id = UUID()
    let scope = try ResourceScope(service: "model", resource: "deepseek-flash", operation: "stream")
    let grant = try RunGrant(runID: UUID(), epoch: 1, createdAt: now.addingTimeInterval(-1), expiresAt: now.addingTimeInterval(600), workloadImageDigest: String(repeating: "a", count: 64), agentAdapterVersion: "offline", workspaceSnapshotID: UUID(), policyDigest: String(repeating: "b", count: 64), approvalSnapshotID: UUID(), connections: [ConnectionGrant(connectionID: id, accountBindingVersion: 1, routeVersion: 1, scopes: [scope])], explicitDenies: [], resourceLimits: ResourceLimits(cpuCount: 1, memoryBytes: 1, diskBytes: 1, messageBytes: 8192, concurrentRequests: 1))
    let authority = RunAuthorizationController(auditSink: Audit())
    let handle = try await authority.install(grant: grant)
    let output = ControlledRunOutput(lifecycle: handle.lifecycle, scope: handle.lifecycle.effectScope(connectionID: id))
    try output.enqueue(.modelChunk(ModelStreamChunk(text: "queued", isFinal: false)))
    handle.lifecycle.terminate(.stopped)
    do { _ = try output.acceptNext() } catch is AuthorizationError {}
    try check(output.summary.acceptedEvents == 0, "queue insertion was mistaken for consumer acceptance")
}
@main struct ExecutionBoundaryChecks {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--final-effect-clock"] {
            do {
                try r3FinalEffectChecks(); try r3ExpandedChecks()
                try await nativeActualGateway(streaming: false, nativeRequest: true)
                try await nativeActualGateway(streaming: true, nativeRequest: true)
                return
            }
            catch { print("FAIL final-effect-clock: \(error)"); exit(1) }
        }
        if arguments == ["--native-repairs"] {
            do { try nativeRepairChecks(); return }
            catch { print("FAIL native-repairs: \(error)"); exit(1) }
        }
        if arguments == ["--native-response"] {
            do { try await nativeResponseChecks(); return }
            catch { print("FAIL native-response: \(error)"); exit(1) }
        }
        if arguments == ["--mcp-transaction"] {
            do { try await mcpTransactionChecks(); return }
            catch { print("FAIL mcp-transaction: \(error)"); exit(1) }
        }
        if arguments == ["--receiver-transaction"] {
            do { try receiverTransactionChecks(); return }
            catch { print("FAIL receiver-transaction: \(error)"); exit(1) }
        }
        if arguments == ["--mcp"] {
            do { try await mcpOutputChecks(); return }
            catch { print("FAIL controlled MCP output"); exit(1) }
        }
        guard arguments.isEmpty else { exit(64) }
        do { try await queuedOutputStopsAtConsumer(); print("PASS queued-output-stop-before-consumer") }
        catch { print("FAIL queued-output-stop-before-consumer: \(error)"); exit(1) }
        do { try await sharedStopCancelsStarted(); print("PASS shared-terminal-cancels-started credential_reads=1 callback_arrivals=1 completion_unknown=1") }
        catch { print("FAIL shared-terminal-cancels-started: \(error)"); exit(1) }
        do {
            try await boundaryChecks()
            for stream in [false, true] {
                for stop in [false, true] { try await actualQueuedModel(streaming: stream, stopBeforeConsumer: stop) }
            }
            try await actualQueuedModel(streaming: true, stopBeforeConsumer: true, acceptFirst: true)
            try await actualQueuedModel(streaming: true, stopBeforeConsumer: false, anthropic: true)
            try await actualQueuedModel(streaming: true, stopBeforeConsumer: true, anthropic: true)
            try await actualQueuedModel(streaming: true, stopBeforeConsumer: true, acceptFirst: true, anthropic: true)
            try receiverTransactionChecks()
        } catch { print("FAIL execution-boundary: \(error)"); exit(1) }
    }
}
