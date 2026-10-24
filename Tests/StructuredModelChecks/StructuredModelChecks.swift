import Foundation
import SandboxHost
import SandboxContracts

enum Failure: Error { case check(String) }
func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw Failure.check(message) }
}
final class Credential: ModelCredentialProvider, @unchecked Sendable {
    let lock = NSLock()
    var count = 0
    func credential(for model: FixedModel) throws -> String { lock.withLock { count += 1 }; return "synthetic-only" }
    var reads: Int { lock.withLock { count } }
}
final class FixtureState: @unchecked Sendable {
    let lock = NSLock()
    var bodies: [[Data]] = []
    var requests: [URLRequest] = []
}
final class Fixture: URLProtocol {
    static let state = FixtureState()
    static func install(_ bodies: [[Data]]) { state.lock.withLock { state.bodies = bodies; state.requests = [] } }
    static var requests: [URLRequest] { state.lock.withLock { state.requests } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let chunks: [Data]? = Self.state.lock.withLock {
            Self.state.requests.append(request)
            return Self.state.bodies.isEmpty ? nil : Self.state.bodies.removeFirst()
        }
        guard let chunks else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
func configuration() -> URLSessionConfiguration {
    let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [Fixture.self]; return c
}
func baseRequest() throws -> FixedModelRequest {
    try FixedModelRequest(model: .deepSeekFlash, protocol: .anthropic, messages: [FixedMessage(role: .user, content: "weather")], maxOutputTokens: 32)
}
let toolReply = #"{"id":"msg_1","type":"message","role":"assistant","model":"deepseek-flash","content":[{"type":"tool_use","id":"tool_1","name":"weather","input":{"city":"北京"}}],"stop_reason":"tool_use","usage":{"input_tokens":12,"output_tokens":9}}"#
func toolOnlyRegression() async throws {
    Fixture.install([[Data(toolReply.utf8)]])
    let credential = Credential()
    let result = try await ModelTransport(credentialProvider: credential, configuration: configuration()).complete(baseRequest())
    // The initial RED used reflection against the old DTO; now assert exact data.
    try check(result.blocks == [.toolUse(id: "tool_1", name: "weather", input: .object(["city": .string("北京")]))] && result.metadata.stopReason == "tool_use", "tool-only Anthropic reply silently became empty-text success")
    try check(credential.reads == 1 && Fixture.requests.count == 1, "one fake credential read and synthetic dispatch")
}
final class Audit: SynchronousAuditSink, @unchecked Sendable {
    let lock = NSLock(); var events: [SecurityEvent] = []; var fail = false
    var snapshot: [SecurityEvent] { lock.withLock { events } }
    var barrier: AuditBarrier?
    func append(_ event: SecurityEvent) throws {
        if event.reason == "dispatch-completion" { barrier?.wait() }
        try lock.withLock {
            if fail && event.reason == "dispatch-completion" { throw Failure.check("audit fault") }
            events.append(event)
        }
    }
}
func gateway(_ credential: Credential, _ audit: Audit, streaming: Bool = false, messageBytes: Int = 65_536) async throws -> (HostModelGateway, HostModelRunHandle, UUID) {
    let id = UUID()
    let connection = HostModelConnection(connectionID: id, accountID: UUID(), accountBindingVersion: 1, routeVersion: 1, model: .deepSeekFlash, protocol: .anthropic, credentialProvider: credential, configuration: configuration())
    let g = try HostModelGateway(connections: [connection], auditSink: audit)
    let scope = try ResourceScope(service: "model", resource: "deepseek-flash", operation: streaming ? "stream" : "complete")
    let grant = try RunGrant(runID: UUID(), epoch: 1, createdAt: Date().addingTimeInterval(-10), expiresAt: Date().addingTimeInterval(600), workloadImageDigest: String(repeating: "a", count: 64), agentAdapterVersion: "fixture", workspaceSnapshotID: UUID(), policyDigest: String(repeating: "b", count: 64), approvalSnapshotID: UUID(), connections: [ConnectionGrant(connectionID: id, accountBindingVersion: 1, routeVersion: 1, scopes: [scope])], explicitDenies: [], resourceLimits: ResourceLimits(cpuCount: 1, memoryBytes: 1, diskBytes: 1, messageBytes: messageBytes, concurrentRequests: 2))
    return (g, try await g.install(grant: grant), id)
}
func gatewayToolRegression() async throws {
    Fixture.install([[Data(toolReply.utf8)]])
    let credentials = Credential(); let audit = Audit()
    let (g, h, id) = try await gateway(credentials, audit)
    let p = try await g.propose(handle: h, connectionID: id, request: baseRequest(), streaming: false)
    let a = try await g.hostApprove(handle: h, proposal: p)
    let result = try await g.execute(handle: h, approval: a)
    try check(result.blocks == [.toolUse(id: "tool_1", name: "weather", input: .object(["city": .string("北京")]))], "gateway must preserve structured tool reply")
    try check(result.metadata.messageID == "msg_1" && result.metadata.stopReason == "tool_use", "gateway metadata")
    try check(credentials.reads == 1 && Fixture.requests.count == 1 && audit.snapshot.last?.outcome == .completed, "audited actual transport")
}
func structuredRequestRegression() async throws {
    let raw = #"{"model":"deepseek-flash","protocol":"anthropic","messages":[{"role":"user","content":[{"type":"text","text":"weather"}]}],"maxOutputTokens":32,"tools":[{"name":"weather","input_schema":{"type":"object","properties":{"city":{"type":"string"}}}}],"tool_choice":{"type":"tool","name":"weather"}}"#
    let request = try JSONDecoder().decode(FixedModelRequest.self, from: Data(raw.utf8))
    let roundtrip = try ModelJSON.parse(JSONEncoder().encode(request))
    try check(roundtrip["tools"]?.array?.count == 1 && roundtrip["tool_choice"]?["name"]?.string == "weather", "tools and tool choice survive canonical encoding")
}
func toolEvents() -> [String] {
    [
        #"{"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"deepseek-flash","content":[],"stop_reason":null,"usage":{"input_tokens":12,"output_tokens":0}}}"#,
        #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tool_1","name":"weather","input":{}}}"#,
        #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"city\":"}}"#,
        #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\"北京\"}"}}"#,
        #"{"type":"content_block_stop","index":0}"#,
        #"{"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":9}}"#,
        #"{"type":"message_stop"}"#
    ]
}
func sse(_ events: [String]) -> [Data] { events.map { "data: \($0)\r\n\r\n" }.joined().utf8.map { Data([$0]) } }
func structuredStreamRegression() async throws {
    Fixture.install([sse(toolEvents())])
    var chunks: [ModelStreamChunk] = []
    let transport = ModelTransport(credentialProvider: Credential(), configuration: configuration())
    for try await chunk in transport.stream(try baseRequest()) { chunks.append(chunk) }
    try check(chunks.last?.completion?.blocks == [.toolUse(id: "tool_1", name: "weather", input: .object(["city": .string("北京")]))], "stateful SSE retains fragmented tool JSON")
    try check(chunks.last?.completion?.metadata.usage?.outputTokens == 9 && chunks.filter(\.isTerminal).count == 2, "retain message_delta and message_stop")
}
func malformedStreamRegression() async throws {
    Fixture.install([sse([#"{"type":"message_stop"}"#])])
    let t = ModelTransport(credentialProvider: Credential(), configuration: configuration())
    do {
        for try await _ in t.stream(try baseRequest()) {}
        throw Failure.check("bare message_stop accepted")
    } catch is ModelTransportError { }
}
@main struct StructuredModelChecks {
    static func main() async {
        switch StructuredCheckMode.parse(Array(CommandLine.arguments.dropFirst())) {
        case .fixtures: break
        case .live(let path): Foundation.exit(await runStructuredLiveChecks(evidencePath: path))
        case .invalid:
            print("USAGE: StructuredModelChecks [--live --evidence-dir ABSOLUTE_NEW_DIR]")
            Foundation.exit(64)
        }
        let checks: [(String, () async throws -> Void)] = [
            ("native slash user string projection", { try await nativeProjectionAccepted("string") }),
            ("native slash user text block projection", { try await nativeProjectionAccepted("blocks") }),
            ("native slash tool schema projection", { try await nativeProjectionAccepted("schema") }),
            ("native slash paired tool input projection", { try await nativeProjectionAccepted("input") }),
            ("native projection positive controls", nativeProjectionControls),
            ("native projection independent rejections", nativeProjectionRejections),
            ("native immutable transport vertical", nativeVertical),
            ("native fail-closed matrix", nativeNegativeMatrix),
            ("native exact wrapped boundary", nativeExactBoundary),
            ("native structured SSE controlled receiver", nativeStreamVertical),
            ("native identity mismatch gates", nativeIdentityRejections),
            ("native shape controls", nativeShapeControls),
            ("native effort preserved under disabled policy", nativeEffortControls),
            ("native canonical reconstruction boundary", nativeCanonicalReconstruction),
            ("tool-only regression", toolOnlyRegression),
            ("gateway tool preservation", gatewayToolRegression),
            ("structured request", structuredRequestRegression),
            ("fragmented structured SSE", structuredStreamRegression),
            ("bare terminal rejected", malformedStreamRegression),
            ("nonstream roundtrip", { try await roundTrip(streaming: false, multiple: false) }),
            ("nonstream multiple tools", { try await roundTrip(streaming: false, multiple: true) }),
            ("SSE roundtrip", { try await roundTrip(streaming: true, multiple: false) }),
            ("SSE multiple tools", { try await roundTrip(streaming: true, multiple: true) }),
            ("JSON and pairing bounds", jsonAndPairingChecks),
            ("malformed SSE matrix", malformedStreams),
            ("OpenAI structured rejection", openAIRejectStructured),
            ("terminal audit gate", { try await auditGate(mode: "success") }),
            ("failed audit suppresses terminal", { try await auditGate(mode: "fail") }),
            ("STOP suppresses terminal", { try await auditGate(mode: "stop") }),
            ("cancel suppresses terminal", { try await auditGate(mode: "cancel") }),
            ("revocation suppresses terminal", { try await auditGate(mode: "revoke") }),
            ("canonical grant and 65536 bounds", envelopeLimits),
            ("raw response validation", rawCompletionRejections),
            ("completion metadata validation", { try await metadataRejections(streaming: false) }),
            ("SSE start metadata validation", { try await metadataRejections(streaming: true) }),
            ("metadata compatibility controls", metadataCompatibility),
            ("repeated stop-bearing cumulative deltas", repeatedStopDelta),
            ("reason then usage-only delta", reasonThenUsageDelta),
            ("sequence before omitted-field final reason", sequenceBeforeReasonDelta),
            ("nullable delta no-update controls", nullableDeltaControls),
            ("128 compatible delta boundary", deltaLimitControl),
            ("delta conflicts failures and EOF", deltaRejections),
            ("first terminal callback synchronous cancellation", cancelFirstTerminalCallback),
            ("usage official completion tiers", { try await usageOfficialTiers(streaming: false) }),
            ("usage official fragmented SSE tiers", { try await usageOfficialTiers(streaming: true) }),
            ("usage numeric tier rejected", usageNumericTierRejected),
            ("usage nullable and optional counter controls", usageNullableAndCounters),
            ("usage strict rejection matrix", usageStrictRejections),
            ("usage tier cumulative merge controls", usageMergeControls),
            ("usage tier conflicts and counter rollback", usageMergeRejections),
            ("usage gateway preservation and audit gate", usageGatewayAudit)
        ]
        var failures = 0
        for (name, run) in checks {
            do { try await run(); print("PASS \(name)") }
            catch { failures += 1; print("FAIL \(name): \(error)") }
        }
        print("StructuredModelChecks: PASS \(checks.count - failures); FAIL \(failures); TOTAL \(checks.count)")
        if failures > 0 { Foundation.exit(1) }
    }
}
