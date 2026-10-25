import Foundation
import SandboxContracts
import SandboxHost

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw Failure(message) }
}
final class Fixture: @unchecked Sendable {
    let lock = NSLock()
    var requests: [URLRequest] = []
    var response = Data("{\"choices\":[{\"message\":{\"content\":\"hello\"}}]}".utf8)
    var hangs = false
    var networkFailure = false
    var partialBeforeHang = false
    var streaming = false
    var auditPath: URL?
    var intentSeen: [Bool] = []
    var sink: Audit?
    func reset(_ audit: Audit? = nil, stream: Bool = false, hangs: Bool = false) {
        lock.withLock {
            requests = []
            intentSeen = []
            sink = audit
            self.hangs = hangs
            networkFailure = false
            partialBeforeHang = false
            auditPath = nil
            streaming = stream
            response =
                stream
                ? Data(
                    "data: {\"choices\":[{\"delta\":{\"content\":\"one\"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"two\"}}]}\n\ndata: [DONE]\n\n"
                        .utf8) : Data("{\"choices\":[{\"message\":{\"content\":\"hello\"}}]}".utf8)
        }
    }
    var hits: Int { lock.withLock { requests.count } }
}
final class FixtureProtocol: URLProtocol {
    static let fixture = Fixture()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (body, hangs, failure, partial, streaming) = Self.fixture.lock.withLock {
            Self.fixture.requests.append(request)
            let fileIntent =
                Self.fixture.auditPath.flatMap { try? String(contentsOf: $0, encoding: .utf8) }?.contains(
                    "dispatch-intent") ?? false
            Self.fixture.intentSeen.append(
                fileIntent || (Self.fixture.sink?.snapshot.contains { $0.reason == "dispatch-intent" } ?? false))
            return (
                Self.fixture.response, Self.fixture.hangs, Self.fixture.networkFailure, Self.fixture.partialBeforeHang,
                Self.fixture.streaming
            )
        }
        if failure {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        client?.urlProtocol(
            self,
            didReceive: HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": streaming ? "text/event-stream" : "application/json"])!,
            cacheStoragePolicy: .notAllowed)
        if hangs && partial {
            client?.urlProtocol(
                self, didLoad: Data("data: {\"choices\":[{\"delta\":{\"content\":\"early\"}}]}\n\n".utf8))
        }
        if !hangs {
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
final class Credentials: ModelCredentialProvider, @unchecked Sendable {
    let lock = NSLock()
    var reads = 0
    var count: Int { lock.withLock { reads } }
    func credential(for model: FixedModel) throws -> String {
        lock.withLock { reads += 1 }
        return "fixture-only-secret"
    }
}
final class Audit: SynchronousAuditSink, @unchecked Sendable {
    let lock = NSLock()
    var events: [SecurityEvent] = []
    var failureReason: String?
    var barrier: AuditBarrier?
    var snapshot: [SecurityEvent] { lock.withLock { events } }
    func append(_ event: SecurityEvent) throws {
        try lock.withLock {
            if failureReason == event.reason { throw Failure("fixture audit failure") }
            events.append(event)
        }
        if let barrier = lock.withLock({ barrier }), barrier.reason == event.reason { barrier.wait() }
    }
}
func configuration() -> URLSessionConfiguration {
    let result = URLSessionConfiguration.ephemeral
    result.protocolClasses = [FixtureProtocol.self]
    return result
}
func request(_ text: String = "original-private-prompt") throws -> FixedModelRequest {
    try FixedModelRequest(
        model: .deepSeekFlash, protocol: .openAI, messages: [FixedMessage(role: .user, content: text)],
        maxOutputTokens: 32)
}
func testPreparedStart() async throws {
    FixtureProtocol.fixture.reset()
    let transport = ModelTransport(credentialProvider: Credentials(), configuration: configuration())
    let operation = try transport.prepare(request(), streaming: false)
    try require(FixtureProtocol.fixture.hits == 0, "prepare must not start network")
    try operation.start()
    var text = ""
    for try await chunk in operation.chunks { text += chunk.text }
    try require(text == "hello" && FixtureProtocol.fixture.hits == 1, "actual synchronous start reaches URLProtocol")
    do {
        try operation.start()
        throw Failure("operation replay accepted")
    } catch is ModelTransportError {}
}
func grant(
    connection: UUID, scope: ResourceScope, denies: Set<ResourceScope> = [], messageBytes: Int = 8192,
    concurrency: Int = 2
) throws -> RunGrant {
    try RunGrant(
        runID: UUID(), epoch: 1, createdAt: Date().addingTimeInterval(-10), expiresAt: Date().addingTimeInterval(600),
        workloadImageDigest: String(repeating: "a", count: 64), agentAdapterVersion: "fixture",
        workspaceSnapshotID: UUID(), policyDigest: String(repeating: "b", count: 64), approvalSnapshotID: UUID(),
        connections: [
            ConnectionGrant(connectionID: connection, accountBindingVersion: 7, routeVersion: 11, scopes: [scope])
        ], explicitDenies: denies,
        resourceLimits: ResourceLimits(
            cpuCount: 1, memoryBytes: 1, diskBytes: 1, messageBytes: messageBytes, concurrentRequests: concurrency))
}
func connection(_ id: UUID, _ credentials: Credentials, accountVersion: UInt64 = 7, routeVersion: UInt64 = 11)
    -> HostModelConnection
{
    HostModelConnection(
        connectionID: id, accountID: UUID(), accountBindingVersion: accountVersion, routeVersion: routeVersion,
        model: .deepSeekFlash, protocol: .openAI, credentialProvider: credentials, configuration: configuration())
}
func testGatewayPositive() async throws {
    let audit = Audit()
    let credentials = Credentials()
    let id = UUID()
    FixtureProtocol.fixture.reset(audit)
    let gateway = try HostModelGateway(connections: [connection(id, credentials)], auditSink: audit)
    let scope = try ResourceScope(service: "model", resource: "deepseek-flash", operation: "complete")
    let handle = try await gateway.install(grant: grant(connection: id, scope: scope))
    var original = try request()
    let proposal = try await gateway.propose(handle: handle, connectionID: id, request: original, streaming: false)
    original = try request("changed-after-proposal")
    try require(
        credentials.count == 0 && FixtureProtocol.fixture.hits == 0, "proposal never reads credential or starts")
    let approval = try await gateway.hostApprove(handle: handle, proposal: proposal)
    let result = try await gateway.execute(handle: handle, approval: approval)
    try require(
        result.text == "hello" && credentials.count == 1 && FixtureProtocol.fixture.hits == 1,
        "approved actual transport completion")
    try require(
        FixtureProtocol.fixture.lock.withLock { FixtureProtocol.fixture.intentSeen == [true] },
        "F03 intent precedes actual network")
    let sent = FixtureProtocol.fixture.lock.withLock { FixtureProtocol.fixture.requests[0] }
    let body = try bodyData(sent)
    try require(
        String(decoding: body, as: UTF8.self).contains("original-private-prompt")
            && !String(decoding: body, as: UTF8.self).contains("changed-after-proposal"),
        "immutable approved bytes build actual request")
    let events = audit.snapshot
    try require(
        events.map(\.reason) == ["dispatch-intent", "dispatch-completion"] && events.last?.outcome == .completed,
        "actual F03 audit pair")
    let rendered = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
    try require(
        !rendered.contains("original-private-prompt") && !rendered.contains("fixture-only-secret"),
        "audit excludes body and key")
    _ = original
}
@main struct HostIntegrationChecks {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--live"] { exit(await runGatewayLiveChecks()) }
        guard arguments.isEmpty else {
            print("Usage: HostIntegrationChecks [--live]")
            exit(64)
        }
        let checks: [(String, @Sendable () async throws -> Void)] = [
            ("shared expiry is visible before authority audit returns", testSharedExpiryBeforeAuditReturn),
            ("shared expiry denial audit pulse", { try await testSharedModelExpiry(path: "deny") }),
            ("shared expiry intent audit pulse", { try await testSharedModelExpiry(path: "intent") }),
            ("shared expiry completion audit pulse", { try await testSharedModelExpiry(path: "completion") }),
            (
                "shared expiry stream completion audit pulse",
                { try await testSharedModelExpiry(path: "completion", streaming: true) }
            ),
            (
                "pre-credential deadline sample observes run expiry",
                { try await testStartGateRunExpiry(postPreparation: false) }
            ),
            (
                "post-preparation deadline sample observes run expiry",
                { try await testStartGateRunExpiry(postPreparation: true) }
            ),
            (
                "pre-credential not-yet-valid sample is nonterminal",
                { try await testStartGateRunExpiry(postPreparation: false, notYetValid: true) }
            ),
            (
                "post-preparation not-yet-valid sample is nonterminal",
                { try await testStartGateRunExpiry(postPreparation: true, notYetValid: true) }
            ),
            ("proposal second clock expiry latches", { try await testProposalSecondSampleExpiry(explicitDeny: false) }),
            (
                "proposal explicit deny cannot hide observed expiry",
                { try await testProposalSecondSampleExpiry(explicitDeny: true) }
            ),
            ("valid scope denial preserves approval", testScopeDenialKeepsApprovalLive),
            ("action deadline after intent audit", { try await testActionDeadlineAtStart(credentialDelay: false) }),
            (
                "action deadline after credential preparation",
                { try await testActionDeadlineAtStart(credentialDelay: true) }
            ),
            ("action deadline does not limit completion", testActionDeadlineDoesNotLimitCompletion),
            ("gateway sequential capacity reuse", testGatewaySequentialCapacityReuse),
            ("grant expiry at propose latches", { try await testGrantExpiryLatches(entry: "propose") }),
            ("grant expiry at approve latches", { try await testGrantExpiryLatches(entry: "approve") }),
            ("grant expiry at deny latches", { try await testGrantExpiryLatches(entry: "deny") }),
            ("grant expiry at execute latches", { try await testGrantExpiryLatches(entry: "execute") }),
            ("expiry preserves outstanding completion", testExpiryPreservesOutstandingCompletion),
            ("prepared transport start is one-shot", testPreparedStart),
            ("gateway audited actual transport", testGatewayPositive),
            ("direct upstream baseline and exact scope deny", testDirectBaselineAndDefaultDeny),
            ("connection protocol handle denials", testConnectionAndHandleDenials),
            ("explicit deny", testExplicitDeny),
            ("concurrent consumption and replay", testReplayConcurrent),
            ("STOP at real consume audit boundary", testStopAtConsumeAudit),
            ("STOP late approval", testStopAndLateApproval),
            ("connection revoke update rollback", testConnectionRevocationAndUpdate),
            ("started cancellation is unknown", testStartedCancellationUnknown),
            ("intent audit failure zero dispatch", testIntentAuditFailure),
            ("stream ordered audited final", { try await testStreamingAudit(fail: false) }),
            ("completion audit failure no final", { try await testStreamingAudit(fail: true) }),
            ("run message and concurrency bounds", testRunLimits),
            ("trusted host denial", testHostDenial),
            ("nonstream completion audit failure", testCompletionAuditFailure),
            ("network failure unknown no retry", testNetworkFailure),
            ("durable JSONL precedes actual start", testDurableAudit),
            ("expired approval", testApprovalExpiration),
            ("STOP during completion audit suppresses final", testStopDuringCompletionAudit),
            ("configured but ungranted connection", testUngrantedConnection),
            ("gateway incremental stream before EOF", testGatewayIncremental),
        ]
        var failures = 0
        for (name, test) in checks {
            do {
                try await test()
                print("PASS \(name)")
            } catch {
                failures += 1
                print("FAIL \(name): \(error)")
            }
        }
        print("HostIntegrationChecks: PASS \(checks.count - failures); FAIL \(failures); TOTAL \(checks.count)")
        if failures != 0 { exit(1) }
    }
}
