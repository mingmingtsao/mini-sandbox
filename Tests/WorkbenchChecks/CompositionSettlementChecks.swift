import Foundation
import SandboxContracts
import SandboxHost
import SandboxWorkbench

final class CloseMCPCredentials: MCPCredentialProvider, @unchecked Sendable {
    let barrier = CloseBarrier()
    private let lock = NSLock()
    private var reads = 0
    let token: String, fail: Bool
    init(token: String = "synthetic-" + UUID().uuidString, fail: Bool = false) {
        self.token = token
        self.fail = fail
    }
    var count: Int { lock.withLock { reads } }
    func credential(for binding: MCPCredentialBinding) throws -> MCPCredential {
        lock.withLock { reads += 1 }
        barrier.block()
        if fail { throw CredentialProviderError.unavailable }
        return MCPCredential(binding: binding, bearer: token)
    }
}

final class OutcomeReleaseCounter: HostRunAttachmentOwner, @unchecked Sendable {
    private let lock = NSLock()
    private var releases = 0, failures = 0
    var counts: (Int, Int) { lock.withLock { (releases, failures) } }
    func beginAttachment(grant: RunGrant, existing: HostRunHandle?) throws -> UUID { UUID() }
    func registerAttachment(_ token: UUID, grant: RunGrant, handle: HostRunHandle) throws {}
    func endAttachment(_ token: UUID) { lock.withLock { releases += 1 } }
    func attachmentCleanupFailed(_ token: UUID) { lock.withLock { failures += 1 } }
}

@MainActor enum CompositionSettlementChecks {
    static func countedTicketRelease(fails: Bool) async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("counted-ticket-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: path) }
        let audit = try WorkbenchAuditSink(newFileAt: path)
        let authority = RunAuthorizationController(auditSink: audit)
        let grant = try CompositionCloseChecks.modelGrant(UUID())
        let owner = OutcomeReleaseCounter()
        let handle = try await authority.install(grant: grant)
        let binding = try ActionBinding(
            runID: grant.runID, epoch: grant.epoch,
            grantDigest: RunAuthorizationController.grantDigest(for: grant),
            connectionID: grant.connections[0].connectionID,
            operation: "complete", schemaDigest: String(repeating: "c", count: 64), resolvedResource: "deepseek-flash",
            canonicalRequest: Data("{}".utf8))
        let action = try await authority.propose(handle: handle, binding: binding, display: "counted outcome")
        let approval = try await authority.hostApprove(handle: handle, actionID: action.actionID, nonce: action.nonce)
        let ticket = try await authority.consumeOwned(
            handle: handle, approved: approval, owner: owner,
            registration: owner.beginAttachment(grant: grant, existing: handle))
        try await authority.stop(handle: handle)
        do {
            try await authority.complete(handle: handle, ticket: ticket, outcome: .notDispatched)
        } catch AuthorizationError.completionAlreadyRecorded {}
        let before = owner.counts
        var failedExpected = false
        if fails {
            try await WorkbenchChecks.withWritesBlocked {
                do {
                    try await authority.complete(handle: handle, ticket: ticket, outcome: .unknown)
                } catch AuthorizationError.auditFailed { failedExpected = true }
            }
        } else {
            try await authority.complete(handle: handle, ticket: ticket, outcome: .unknown)
        }
        var duplicateRejected = false
        do { try await authority.complete(handle: handle, ticket: ticket, outcome: .unknown) } catch AuthorizationError
            .completionAlreadyRecorded
        { duplicateRejected = true }
        let counts = owner.counts
        try ConnectionSettingsChecks.require(
            before == (0, 0) && counts.0 == 1 && counts.1 == (fails ? 1 : 0) && duplicateRejected
                && failedExpected == fails && handle.lifecycle.currentStatus != .active,
            "actual owner release callback is exactly once, not merely idempotent dictionary removal")
        print("PASS bounds counted ticket release fails=\(fails) releases=\(counts.0) cleanupFailures=\(counts.1)")
    }
    static func mcpGrant(_ id: UUID) throws -> RunGrant {
        var scopes = Set(
            try ["initialize", "notifications/initialized", "tools/list"].map {
                try ResourceScope(service: "mcp", resource: "control", operation: $0)
            })
        scopes.insert(try ResourceScope(service: "mcp", resource: "A", operation: "read"))
        let base = try CompositionCloseChecks.modelGrant(id)
        return try RunGrant(
            runID: base.runID, epoch: base.epoch, createdAt: base.createdAt, expiresAt: base.expiresAt,
            workloadImageDigest: base.workloadImageDigest, agentAdapterVersion: base.agentAdapterVersion,
            workspaceSnapshotID: base.workspaceSnapshotID, policyDigest: base.policyDigest,
            approvalSnapshotID: base.approvalSnapshotID,
            connections: [ConnectionGrant(connectionID: id, accountBindingVersion: 1, routeVersion: 1, scopes: scopes)],
            explicitDenies: [], resourceLimits: base.resourceLimits)
    }
    static func control(_ method: String) -> Data {
        let params =
            method == "initialize"
            ? #"{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"bounded-host-fixture","version":"1"}}"#
            : "{}"
        let id = method == "notifications/initialized" ? "" : "\"id\":\"control\","
        return Data("{\"jsonrpc\":\"2.0\",\(id)\"method\":\"\(method)\",\"params\":\(params)}".utf8)
    }
    static func mcpPrestartSettlementFailure() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-settlement-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: path) }
        let audit = try WorkbenchAuditSink(newFileAt: path)
        let credentials = CloseMCPCredentials(fail: true)
        let id = UUID()
        let connection = try HostMCPConnection.testOnlyLoopback(
            connectionID: id, accountID: UUID(), port: 1, provider: credentials)
        let root = try RunComposition(audit: audit, credentialStore: SettingsStore(), mcpConnections: [connection])
        let gateway = root.mcp
        let handle = try await gateway.install(grant: mcpGrant(id))
        let proposal = try await gateway.propose(handle: handle, connectionID: id, raw: control("initialize"))
        let approval = try await gateway.hostApprove(handle: handle, proposal: proposal)
        credentials.barrier.arm()
        let operation = Task { try await gateway.execute(handle: handle, approval: approval) }
        let entered = await Task.detached { credentials.barrier.wait() }.value
        var rejected = false
        try await WorkbenchChecks.withWritesBlocked {
            credentials.barrier.release.signal()
            do { _ = try await operation.value } catch HostMCPGatewayError.auditFailed { rejected = true }
        }
        let pending = root.pendingOwnedWork
        let closed = await root.close()
        let repeated = await root.close()
        let resumes = try await gateway.resumedTaskCount(handle: handle)
        try ConnectionSettingsChecks.require(
            entered && !credentials.barrier.timedOut && rejected && pending == 0 && !closed && !repeated
                && !root.isClosed && credentials.count == 1 && resumes == 0
                && audit.snapshot().filter { $0.reason == "dispatch-completion" }.isEmpty,
            "MCP failed prestart settlement must not acknowledge close")
        print("PASS bounds MCP prestart failed durable settlement keeps repeated close false")
    }
    static func gatewayAuditFailure(preparationFails: Bool = false) async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("gateway-settlement-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: path) }
        let audit = try WorkbenchAuditSink(newFileAt: path)
        let credentials = CloseCredentials(fail: preparationFails)
        let id = UUID()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloseFixtureProtocol.self]
        CloseFixtureProtocol.traffic.reset(hold: false)
        let connection = HostModelConnection(
            connectionID: id, accountID: UUID(), accountBindingVersion: 1,
            routeVersion: 1, model: .deepSeekFlash, protocol: .openAI, credentialProvider: credentials,
            configuration: configuration)
        let root = try RunComposition(audit: audit, modelConnections: [connection], credentialStore: SettingsStore())
        let gateway = root.model
        let handle = try await gateway.install(grant: CompositionCloseChecks.modelGrant(id))
        let proposal = try await gateway.propose(
            handle: handle, connectionID: id,
            request: FixedModelRequest(
                model: .deepSeekFlash, protocol: .openAI,
                messages: [FixedMessage(role: .user, content: "ordinary fixture")], maxOutputTokens: 8),
            streaming: false)
        let approval = try await gateway.hostApprove(handle: handle, proposal: proposal)
        let output = try await gateway.makeOutput(handle: handle, approval: approval)
        credentials.barrier.arm()
        let operation = Task { try await gateway.execute(handle: handle, approval: approval, output: output) }
        let entered = await Task.detached { credentials.barrier.wait() }.value
        var rejected = false
        try await WorkbenchChecks.withWritesBlocked {
            credentials.barrier.release.signal()
            do { try await operation.value } catch HostModelGatewayError.auditFailed { rejected = true }
        }
        let pending = root.pendingOwnedWork
        let closed = await root.close()
        let repeated = await root.close()
        let resumes = try await gateway.resumedTaskCount(handle: handle)
        try ConnectionSettingsChecks.require(
            entered && !credentials.barrier.timedOut && rejected && pending == 0 && !closed && !repeated
                && !root.isClosed && credentials.count == 1 && resumes == (preparationFails ? 0 : 1)
                && CloseFixtureProtocol.traffic.counts.0 == (preparationFails ? 0 : 1)
                && output.summary.acceptedEvents == 0
                && audit.snapshot().filter { $0.reason == "dispatch-completion" }.isEmpty,
            "gateway failed durable completion must retire once as failed and keep repeated composition close unconfirmed"
        )
        print(
            "PASS bounds model gateway failed durable settlement preparationFails=\(preparationFails) keeps repeated close false"
        )
    }
}
