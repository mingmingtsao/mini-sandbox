import Foundation
import SandboxContracts

@testable import SandboxHost

final class LoopbackCredentials: MCPCredentialProvider, @unchecked Sendable {
    let token: String
    let lock = NSLock()
    private var reads = 0
    init(_ token: String) { self.token = token }
    func credential(for binding: MCPCredentialBinding) throws -> MCPCredential {
        lock.withLock { reads += 1 }
        return MCPCredential(binding: binding, bearer: token)
    }
    var count: Int { lock.withLock { reads } }
}
func mcpControl(_ method: String) -> Data {
    let params =
        method == "initialize"
        ? "{\"protocolVersion\":\"2025-03-26\",\"capabilities\":{},\"clientInfo\":{\"name\":\"bounded-host-fixture\",\"version\":\"1\"}}"
        : "{}"
    let id = method == "notifications/initialized" ? "" : "\"id\":\"control\","
    return Data("{\"jsonrpc\":\"2.0\",\(id)\"method\":\"\(method)\",\"params\":\(params)}".utf8)
}
func actualMCPOutput(port: UInt16, token: String, stopBeforeConsumer: Bool) async throws {
    let id = UUID()
    let audit = Audit()
    let credentials = LoopbackCredentials(token)
    let connection = try HostMCPConnection.testOnlyLoopback(
        connectionID: id, accountID: UUID(), port: port, provider: credentials)
    let gateway = try HostMCPGateway(connections: [connection], auditSink: audit)
    var scopes = Set(
        try ["initialize", "notifications/initialized", "tools/list"].map {
            try ResourceScope(service: "mcp", resource: "control", operation: $0)
        })
    scopes.insert(try ResourceScope(service: "mcp", resource: "A", operation: "read"))
    let grant = try RunGrant(
        runID: UUID(), epoch: 1, createdAt: Date().addingTimeInterval(-1), expiresAt: Date().addingTimeInterval(600),
        workloadImageDigest: String(repeating: "a", count: 64), agentAdapterVersion: "offline",
        workspaceSnapshotID: UUID(), policyDigest: String(repeating: "b", count: 64), approvalSnapshotID: UUID(),
        connections: [ConnectionGrant(connectionID: id, accountBindingVersion: 1, routeVersion: 1, scopes: scopes)],
        explicitDenies: [],
        resourceLimits: ResourceLimits(
            cpuCount: 1, memoryBytes: 1, diskBytes: 1, messageBytes: 65536, concurrentRequests: 1))
    let handle = try await gateway.install(grant: grant)
    for method in ["initialize", "notifications/initialized", "tools/list"] {
        let proposal = try await gateway.propose(handle: handle, connectionID: id, raw: mcpControl(method))
        let approval = try await gateway.hostApprove(handle: handle, proposal: proposal)
        _ = try await gateway.execute(handle: handle, approval: approval)
    }
    let raw = Data(
        #"{"jsonrpc":"2.0","id":"read","method":"tools/call","params":{"name":"repo_read","arguments":{"repo":"A"}}}"#
            .utf8)
    let proposal = try await gateway.propose(
        handle: handle, connectionID: id, raw: raw, sourceToolUseID: "controlled_tool_1")
    let approval = try await gateway.hostApprove(handle: handle, proposal: proposal)
    let output = try await gateway.makeOutput(handle: handle, approval: approval)
    try await gateway.execute(handle: handle, approval: approval, output: output)
    try check(output.summary.queuedEvents == 1 && output.summary.acceptedEvents == 0, "MCP enqueue is not acceptance")
    if stopBeforeConsumer {
        let lifecycle = try await gateway.lifecycle(handle: handle)
        lifecycle.terminate(.stopped)
        do {
            _ = try output.acceptNext()
            throw Failure(message: "late MCP handoff accepted")
        } catch is AuthorizationError {}
    } else {
        try check(try output.acceptNext(), "MCP consumer did not accept")
    }
    try check(
        output.summary.acceptedEvents == (stopBeforeConsumer ? 0 : 1)
            && output.summary.acceptedToolResults == (stopBeforeConsumer ? 0 : 1), "MCP actual consumer/handoff state")
    let resumes = try await gateway.resumedTaskCount(handle: handle)
    try check(
        credentials.count == 4 && resumes == 4 && audit.completions.count == 4,
        "MCP reads/resumes/completion exactly once")
    print(
        "PASS actual-mcp-\(stopBeforeConsumer ? "stop" : "accept") credential_reads=4 actual_resume_calls=4 accepted_tool_results=\(output.summary.acceptedToolResults)"
    )
}
func mcpOutputChecks() async throws {
    guard let input = readLine(),
        let config = try JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any],
        let port = config["port"] as? Int, let token = config["token"] as? String, let port = UInt16(exactly: port)
    else { throw Failure(message: "fixture input required") }
    for stop in [false, true] { try await actualMCPOutput(port: port, token: token, stopBeforeConsumer: stop) }
}
