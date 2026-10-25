import Foundation
import SandboxContracts

@testable import SandboxHost

func receiverState(_ output: ControlledRunOutput) -> [Int] {
    let s = output.summary
    return [
        s.queuedEvents, s.acceptedEvents, s.acceptedTextBytes, s.acceptedFinals, s.acceptedMetadata,
        s.acceptedToolResults,
    ]
}
func receiverTransactionChecks() throws {
    // Deliberately synthesized malformed completion: never routed through propose,
    // so ingress validation cannot mask a receiver regression.
    for invalid in ["bad id", "", "bad\nID", "é", String(repeating: "x", count: 129)] {
        let clock = Clock()
        let authority = lifecycle(clock)
        let output = ControlledRunOutput(lifecycle: authority, scope: authority.effectScope(connectionID: UUID()))
        try output.enqueue(.modelChunk(ModelStreamChunk(text: "seed", isFinal: false)))
        try check(try output.acceptNext(), "receiver seed")
        try output.enqueue(.mcpCompletion(.testOnlyUnvalidated(text: "must-not-commit", sourceToolUseID: invalid)))
        let before = receiverState(output)
        for _ in 0..<2 {
            do {
                _ = try output.acceptNext()
                throw Failure(message: "invalid receiver accepted")
            } catch HostMCPGatewayError.denied {}
            try check(
                receiverState(output) == before,
                "rejected receiver mutated text/finals/events/metadata/tool-results or dequeued")
        }
        // A rejected head still owns its queue slot; cancellation discards it,
        // without converting rejection into acceptance, and is idempotent.
        for _ in 0..<255 { try output.enqueue(.modelChunk(ModelStreamChunk(text: "", isFinal: false))) }
        do {
            try output.enqueue(.modelChunk(ModelStreamChunk(text: "", isFinal: false)))
            throw Failure(message: "rejection freed queue capacity")
        } catch HostModelGatewayError.busy {}
        output.cancel()
        output.cancel()
        try check(receiverState(output) == [0, 1, 4, 0, 0, 0], "receiver cleanup changed accepted state")
        do {
            _ = try output.acceptNext()
            throw Failure(message: "cancelled receiver accepted")
        } catch is CancellationError {}
    }
    print(
        "PASS synthetic-mcp-receiver-transaction invalid_cases=5 retries=2 success_mutations=0 dequeue_commits=0 cleanup=idempotent"
    )
    for id: String? in ["valid_tool_1", nil] {
        let clock = Clock()
        let authority = lifecycle(clock)
        let output = ControlledRunOutput(lifecycle: authority, scope: authority.effectScope(connectionID: UUID()))
        try output.enqueue(.mcpCompletion(.testOnlyUnvalidated(text: "ok", sourceToolUseID: id)))
        try check(try output.acceptNext(), "valid receiver rejected")
        try check(receiverState(output) == [0, 1, 2, 1, 0, id == nil ? 0 : 1], "valid receiver commit")
        try check(try !output.acceptNext(), "receiver accepted twice")
    }
    print("PASS synthetic-mcp-receiver-valid-and-nil commits=2 tool_results=1")
}

func mcpTransactionChecks() async throws {
    guard let input = readLine(),
        let config = try JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any],
        let number = config["port"] as? Int, let port = UInt16(exactly: number), let token = config["token"] as? String
    else { throw Failure(message: "fixture input required") }
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
    let now = Date()
    let grant = try RunGrant(
        runID: UUID(), epoch: 1, createdAt: now.addingTimeInterval(-1), expiresAt: now.addingTimeInterval(600),
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
    for invalid in ["bad id", "", "bad\nID", "é", String(repeating: "x", count: 129)] {
        do {
            _ = try await gateway.propose(handle: handle, connectionID: id, raw: raw, sourceToolUseID: invalid)
            throw Failure(message: "malformed sourceToolUseID reached approval proposal")
        } catch HostMCPGatewayError.denied {}
        let resumes = try await gateway.resumedTaskCount(handle: handle)
        try check(
            credentials.count == 3 && resumes == 3 && audit.completions.count == 3,
            "invalid ingress performed credential/start/completion work")
    }
    // Sequential accepted actions at capacity one prove reservation cleanup and
    // exactly-once audit/dispatch; both source-ID and nil paths use real HTTP.
    for source: String? in ["valid_tool_1", nil] {
        let proposal = try await gateway.propose(handle: handle, connectionID: id, raw: raw, sourceToolUseID: source)
        let approval = try await gateway.hostApprove(handle: handle, proposal: proposal)
        let output = try await gateway.makeOutput(handle: handle, approval: approval)
        try await gateway.execute(handle: handle, approval: approval, output: output)
        try check(
            output.summary.queuedEvents == 1 && output.summary.acceptedEvents == 0, "premature receiver acceptance")
        try check(try output.acceptNext(), "real MCP receiver rejected")
        try check(
            output.summary.acceptedFinals == 1 && output.summary.acceptedTextBytes > 0
                && output.summary.acceptedToolResults == (source == nil ? 0 : 1), "real MCP receiver state")
        try check(try !output.acceptNext(), "real MCP receiver accepted twice")
    }
    let resumes = try await gateway.resumedTaskCount(handle: handle)
    try check(
        credentials.count == 5 && resumes == 5 && audit.completions.count == 5
            && audit.completions.allSatisfy { $0.outcome == .completed }, "exactly-once dispatch/audit/capacity")
    print(
        "PASS actual-mcp-ingress-transaction invalid_cases=5 invalid_reads=0 invalid_resumes=0 credential_reads=5 actual_resume_calls=5 completions=5 accepted_tool_results=1"
    )
}
