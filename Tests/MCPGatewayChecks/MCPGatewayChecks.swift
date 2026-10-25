import Foundation
import SandboxHost
import SandboxContracts

struct Failure: Error { let message: String }
func check(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
func output(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
final class CredentialEvidence: @unchecked Sendable {
    static let shared = CredentialEvidence()
    private let lock = NSLock()
    private var total = 0; private var name: String?; private var before = 0
    func recordRead() { lock.withLock { total += 1 } }
    func begin(_ name: String) throws -> Int {
        try lock.withLock {
            try check(self.name == nil, "previous phase missing report")
            self.name = name; before = total; return total
        }
    }
    func end(_ name: String, expected: Int) throws -> (Int, Int) {
        try lock.withLock {
            try check(self.name == name, "phase/report mismatch")
            try check(total - before == expected, "actual credential delta mismatch")
            self.name = nil; return (before, total)
        }
    }
}
func phase(_ name: String) throws {
    let before = try CredentialEvidence.shared.begin(name)
    output("SYNC \(name) \(before)")
    guard readLine() == "go" else { throw Failure(message: "driver handshake") }
}
func report(_ name: String, hits: Int, reads: Int) throws {
    let (before, after) = try CredentialEvidence.shared.end(name, expected: reads)
    output("CHECK \(name) \(hits) \(after - before) \(before) \(after) \(reads)")
}
final class Audit: SynchronousAuditSink, @unchecked Sendable {
    let lock = NSLock(); var events: [SecurityEvent] = []; var fail: String?
    var barrier: Barrier?
    var afterAppend: (@Sendable (SecurityEvent) -> Void)?
    let disk: JSONLAuditSink?; let diskURL: URL?
    private var readbacks = 0
    init() { disk = nil; diskURL = nil }
    init(diskAt url: URL) throws { disk = try JSONLAuditSink(newFileAt: url); diskURL = url }
    var diskReadbacks: Int { lock.withLock { readbacks } }
    var snapshot: [SecurityEvent] { lock.withLock { events } }
    func readDisk() throws -> [DiskEvent] {
        guard let diskURL else { throw Failure(message: "disk audit not configured") }
        return try Data(contentsOf: diskURL).split(separator: 0x0A).map { try JSONDecoder().decode(DiskEvent.self, from: Data($0)) }
    }
    func append(_ event: SecurityEvent) throws {
        try lock.withLock {
            if fail == event.reason { throw Failure(message: "injected audit append failure") }
            if let disk {
                try disk.append(event)
                try check(try readDisk().last?.eventID == event.eventID, "disk append readback before return")
                readbacks += 1
            }
            events.append(event)
        }
        if let barrier, barrier.reason == event.reason { barrier.wait() }
        afterAppend?(event)
    }
}
struct DiskEvent: Decodable {
    let eventID: UUID; let actionID: UUID?; let reason: String; let outcome: String
}
enum CredentialFault { case none, failure, bindingMismatch }
final class Credentials: MCPCredentialProvider, @unchecked Sendable {
    let lock = NSLock(); let token: String; let audit: Audit; var reads = 0; var intentObserved = true
    private var fault = CredentialFault.none; private var diskObservations = 0
    var afterRead: (@Sendable () -> Void)?
    init(_ token: String, _ audit: Audit) { self.token = token; self.audit = audit }
    var count: Int { lock.withLock { reads } }
    var diskIntentReadbacks: Int { lock.withLock { diskObservations } }
    func inject(_ fault: CredentialFault) { lock.withLock { self.fault = fault } }
    func credential(for binding: MCPCredentialBinding) throws -> MCPCredential {
        CredentialEvidence.shared.recordRead()
        let fault = try lock.withLock {
            reads += 1; intentObserved = intentObserved && audit.snapshot.last?.reason == "dispatch-intent"
            if audit.diskURL != nil {
                let event = try audit.readDisk().last
                try check(event?.reason == "dispatch-intent" && event?.outcome == "notDispatched" && event?.eventID == audit.snapshot.last?.eventID, "disk intent before credential access")
                diskObservations += 1
            }
            return self.fault
        }
        if fault == .failure { throw Failure(message: "synthetic provider failure") }
        if fault == .bindingMismatch {
            return MCPCredential(binding: MCPCredentialBinding(connectionID: binding.connectionID, accountID: UUID(), accountBindingVersion: binding.accountBindingVersion, audience: binding.audience), bearer: token)
        }
        afterRead?()
        return MCPCredential(binding: binding, bearer: token)
    }
}
func grant(_ id: UUID, write: Bool = false) throws -> RunGrant {
    var scopes = Set(try ["initialize", "notifications/initialized", "tools/list"].map { try ResourceScope(service: "mcp", resource: "control", operation: $0) })
    scopes.insert(try ResourceScope(service: "mcp", resource: "A", operation: "read"))
    if write { scopes.insert(try ResourceScope(service: "mcp", resource: "A", operation: "write")) }
    return try RunGrant(runID: UUID(), epoch: 1, createdAt: Date().addingTimeInterval(-5), expiresAt: Date().addingTimeInterval(120), workloadImageDigest: String(repeating: "a", count: 64), agentAdapterVersion: "fixture", workspaceSnapshotID: UUID(), policyDigest: String(repeating: "b", count: 64), approvalSnapshotID: UUID(), connections: [ConnectionGrant(connectionID: id, accountBindingVersion: 1, routeVersion: 1, scopes: scopes)], explicitDenies: [], resourceLimits: ResourceLimits(cpuCount: 1, memoryBytes: 1, diskBytes: 1, messageBytes: 65536, concurrentRequests: 2))
}
func call(_ repo: String, write: Bool = false) -> Data {
    Data((write ? "{\"jsonrpc\":\"2.0\",\"id\":\"test\",\"method\":\"tools/call\",\"params\":{\"name\":\"repo_write\",\"arguments\":{\"repo\":\"\(repo)\",\"content\":\"changed\"}}}" : "{\"jsonrpc\":\"2.0\",\"id\":\"test\",\"method\":\"tools/call\",\"params\":{\"name\":\"repo_read\",\"arguments\":{\"repo\":\"\(repo)\"}}}").utf8)
}
func control(_ method: String) -> Data {
    let params = method == "initialize" ? "{\"protocolVersion\":\"2025-03-26\",\"capabilities\":{},\"clientInfo\":{\"name\":\"bounded-host-fixture\",\"version\":\"1\"}}" : "{}"
    let id = method == "notifications/initialized" ? "" : "\"id\":\"control\","
    return Data("{\"jsonrpc\":\"2.0\",\(id)\"method\":\"\(method)\",\"params\":\(params)}".utf8)
}
struct Context {
    let gateway: HostMCPGateway; let handle: HostMCPRunHandle; let id: UUID; let account: UUID
    let audit: Audit; let credentials: Credentials; let port: UInt16
    func proposal(_ raw: Data, source: String? = nil) async throws -> HostMCPProposal { try await gateway.propose(handle: handle, connectionID: id, raw: raw, sourceToolUseID: source) }
    func approve(_ raw: Data, source: String? = nil) async throws -> HostMCPApproval { let p = try await proposal(raw, source: source); return try await gateway.hostApprove(handle: handle, proposal: p) }
    func execute(_ approval: HostMCPApproval) async throws -> MCPCompletion { try await gateway.execute(handle: handle, approval: approval) }
    func send(_ raw: Data) async throws -> MCPCompletion { try await execute(approve(raw)) }
}
func expectError<E: Error & Equatable>(_ expected: E, _ body: @Sendable () async throws -> Void) async throws {
    do { try await body() }
    catch let error as E { try check(error == expected, "wrong typed negative-case error"); return }
    catch { throw Failure(message: "unexpected negative-case error type") }
    throw Failure(message: "unexpected authorization/success")
}
func denied(_ expected: HostMCPGatewayError = .denied, _ body: @Sendable () async throws -> Void) async throws { try await expectError(expected, body) }
func denied(_ expected: AuthorizationError, _ body: @Sendable () async throws -> Void) async throws { try await expectError(expected, body) }
func make(_ port: UInt16, _ token: String, write: Bool = false, audit: Audit = Audit()) async throws -> Context {
    let id = UUID(); let account = UUID(); let credentials = Credentials(token, audit)
    let connection = try HostMCPConnection.testOnlyLoopback(connectionID: id, accountID: account, port: port, provider: credentials)
    let gateway = try HostMCPGateway(connections: [connection], auditSink: audit)
    let handle = try await gateway.install(grant: grant(id, write: write))
    return Context(gateway: gateway, handle: handle, id: id, account: account, audit: audit, credentials: credentials, port: port)
}
func discover(_ c: Context, name: String) async throws {
    try phase(name)
    try check(try await c.gateway.discovery(connectionID: c.id) == .unknown, "unknown before discovery")
    try await denied { _ = try await c.proposal(call("A")) }
    let before = c.credentials.count
    for method in ["initialize", "notifications/initialized", "tools/list"] { _ = try await c.send(control(method)) }
    try check(c.credentials.count - before == 3, "all three control credential reads")
    try check(c.audit.snapshot.suffix(6).map(\.reason) == ["dispatch-intent", "dispatch-completion", "dispatch-intent", "dispatch-completion", "dispatch-intent", "dispatch-completion"], "control audit pairs")
    try check(c.credentials.intentObserved, "intent before credentials")
    try report(name, hits: 3, reads: 3)
}
@main struct Checks {
    static func main() async {
        let selector = Array(CommandLine.arguments.dropFirst())
        guard selector.isEmpty || selector == ["--independent"] || selector == ["--transport-unit"] || selector == ["--claude-native"] else { output("invalid selector"); exit(64) }
        do {
            if selector == ["--transport-unit"] { try await transportUnitChecks(); exit(0) }
            guard let line = readLine(), let config = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let port = config["port"] as? Int, let token = config["token"] as? String, let p = UInt16(exactly: port) else { throw Failure(message: "loopback driver input required") }
            if selector == ["--claude-native"] { try await claudeClientChecks(p, token); exit(0) }
            if selector == ["--independent"] {
                try await independentChecks(p, token)
                output("PASS MCP independent scope; default suite not run here"); exit(0)
            }
            let c = try await make(p, token)
            try await discover(c, name: "discovery")
            try await reflectionChecks(c)
            try check(try await c.gateway.discovery(connectionID: c.id) == .knownReady, "ready")
            try phase("approved-read")
            let approval = try await c.approve(call("A"), source: "offline-tool-1")
            let result = try await c.execute(approval)
            try check(result.text == "repo-A-initial" && result.sourceToolUseID == "offline-tool-1", "approved A/read result and source binding")
            try await denied(AuthorizationError.ticketAlreadyConsumed) { _ = try await c.execute(approval) }
            try report("approved-read", hits: 1, reads: 1)
            try phase("denied-ingress")
            let before = c.credentials.count
            for raw in [call("B"), call("A", write: true), call("B", write: true)] { try await denied { _ = try await c.proposal(raw) } }
            for method in ["resources/list", "resources/read", "prompts/list", "prompts/get", "roots/list", "sampling/createMessage", "elicitation/create", "notifications/tools/list_changed", "ping", "unknown"] { try await denied { _ = try await c.proposal(control(method)) } }
            let rawBad = ["[]", "{\"jsonrpc\":\"2.0\",\"jsonrpc\":\"2.0\",\"id\":\"x\",\"method\":\"tools/list\",\"params\":{}}", String(decoding: call("A"), as: UTF8.self).replacingOccurrences(of: "\"repo\":\"A\"", with: "\"repo\":\"A\",\"extra\":true"), String(decoding: call("A"), as: UTF8.self).replacingOccurrences(of: "\"repo\":\"A\"", with: "\"repo\":\"%41\""), String(decoding: call("A"), as: UTF8.self).replacingOccurrences(of: "\"repo\":\"A\"", with: "\"repo\":true"), String(decoding: control("initialize"), as: UTF8.self).replacingOccurrences(of: "2025-03-26", with: "2024-11-05"), String(repeating: " ", count: 65537)]
            for (index, raw) in rawBad.enumerated() {
                try await denied(index == 1 || index == 6 ? HostMCPGatewayError.notStarted : .denied) { _ = try await c.proposal(Data(raw.utf8)) }
            }
            try check(c.credentials.count == before, "denials read no credentials")
            try report("denied-ingress", hits: 0, reads: 0)
            try phase("frozen-args")
            var original = call("A")
            let frozen = try await c.proposal(original)
            original = call("B")
            let frozenApproval = try await c.gateway.hostApprove(handle: c.handle, proposal: frozen)
            try check(try await c.execute(frozenApproval).text == "repo-A-initial", "only immutable approved arguments")
            let changed = original
            try await denied { _ = try await c.proposal(changed) }
            try report("frozen-args", hits: 1, reads: 1)
            try await modelHandoff(c)
            let w = try await make(p, token, write: true); try await discover(w, name: "write-discovery")
            try phase("denied-write")
            let pending = try await w.proposal(call("A", write: true))
            try check(w.credentials.count == 3, "unapproved write no credential")
            try await w.gateway.hostDeny(handle: w.handle, proposal: pending)
            try await denied(AuthorizationError.actionDenied) { _ = try await w.gateway.hostApprove(handle: w.handle, proposal: pending) }
            try report("denied-write", hits: 0, reads: 0)
            try phase("approved-write")
            let wa = try await w.approve(call("A", write: true)); let wr = try await w.execute(wa)
            try check(wr.text == "changed", "approved write")
            try await denied(AuthorizationError.ticketAlreadyConsumed) { _ = try await w.execute(wa) }
            try report("approved-write", hits: 1, reads: 1)
            for fault in ["wrong-id", "http-status", "tool-error", "rpc-error", "redirect", "drop-write"] {
                try phase(fault)
                let a = try await w.approve(call("A", write: fault == "drop-write"))
                try await denied(.outcomeUnknown) { _ = try await w.execute(a) }
                try await denied(AuthorizationError.ticketAlreadyConsumed) { _ = try await w.execute(a) }
                try check(w.audit.snapshot.last?.outcome == .unknown, "failure completion unknown")
                try report(fault, hits: 1, reads: 1)
            }
            try phase("schema-change")
            let schemaStale = try await c.approve(call("A"))
            try await denied(.outcomeUnknown) { _ = try await c.send(control("tools/list")) }
            try check(try await c.gateway.discovery(connectionID: c.id) == .unknown, "unrecognized replacement schema must invalidate catalog")
            try await denied(.revoked) { _ = try await c.execute(schemaStale) }
            try report("schema-change", hits: 1, reads: 1)
            try phase("catalog-reload")
            _ = try await c.send(control("tools/list"))
            try report("catalog-reload", hits: 1, reads: 1)
            try phase("catalog-replacement")
            let stale = try await c.approve(call("A"))
            try await c.gateway.invalidateCatalog(connectionID: c.id)
            try check(try await c.gateway.discovery(connectionID: c.id) == .unknown, "invalidated unknown")
            try await denied(.revoked) { _ = try await c.execute(stale) }
            try await denied { _ = try await c.proposal(call("A")) }
            try report("catalog-replacement", hits: 0, reads: 0)
            try phase("empty-catalog")
            _ = try await c.send(control("tools/list"))
            try check(try await c.gateway.discovery(connectionID: c.id) == .knownEmpty, "empty not unknown")
            try await denied { _ = try await c.proposal(call("A")) }
            try report("empty-catalog", hits: 1, reads: 1)
            for kind in ["intent-audit", "completion-audit", "stop", "revoke", "account", "route", "cancel"] {
                let x = try await make(p, token); try await discover(x, name: kind + "-discovery")
                try phase(kind)
                let a = try await x.approve(call("A")); let n = x.credentials.count
                switch kind {
                case "intent-audit": x.audit.fail = "dispatch-intent"
                case "completion-audit": x.audit.fail = "dispatch-completion"
                case "stop": try await x.gateway.stop(handle: x.handle)
                case "revoke": try await x.gateway.revokeConnection(x.id)
                case "account", "route":
                    let updated = try HostMCPConnection.testOnlyLoopback(connectionID: x.id, accountID: kind == "account" ? UUID() : x.account, accountBindingVersion: kind == "account" ? 2 : 1, routeVersion: kind == "route" ? 2 : 1, port: p, provider: x.credentials)
                    try await x.gateway.updateConnection(updated)
                default: break
                }
                if kind == "cancel" {
                    let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await x.execute(a) }
                    try await denied(.notStarted) { _ = try await task.value }
                } else {
                    let expected: HostMCPGatewayError = kind == "stop" ? .revoked : (kind.hasSuffix("audit") ? .auditFailed : .invalidConnection)
                    try await denied(expected) { _ = try await x.execute(a) }
                }
                let expected = kind == "completion-audit" ? 1 : 0
                try check(x.credentials.count - n == expected, "lifecycle credential count")
                try report(kind, hits: expected, reads: expected)
            }
            try await lifecycleBarriers(p, token)
            try await credentialGateChecks(p, token)
            try await diskAuditChecks(p, token)
            try await responseBoundaryChecks(p, token)
            try await clockPulseChecks(p, token)
            output("PASS MCP loopback checks"); exit(0)
        } catch let failure as Failure { output("FAIL MCP " + failure.message); exit(1) }
        catch { output("FAIL MCP unexpected error"); exit(1) }
    }
}
