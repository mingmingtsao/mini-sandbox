import Foundation
import SandboxContracts

package enum HostMCPGatewayError: Error, Equatable, Sendable {
    case denied, invalidHandle, invalidConnection, invalidApproval, invalidResponse, revoked, busy
    case notStarted, outcomeUnknown, auditFailed
}
package final class HostMCPRunHandle: Sendable { fileprivate let token = UUID(); fileprivate init() {} }
package struct HostMCPProposal: Sendable {
    fileprivate let handle: HostMCPRunHandle
    fileprivate let pending: PendingAction
    fileprivate let generation: UInt64
    fileprivate let effectScope: RunEffectScope
}
package struct HostMCPApproval: Sendable { fileprivate let proposal: HostMCPProposal; fileprivate let approved: ApprovedAction }
package struct MCPCompletion: Sendable {
    package let text: String
    package let sourceToolUseID: String?
    fileprivate init(text: String, sourceToolUseID: String?) { self.text = text; self.sourceToolUseID = sourceToolUseID }
#if DEBUG
    // Synthetic receiver-defense fixture; not an authenticated transport result.
    static func testOnlyUnvalidated(text: String, sourceToolUseID: String?) -> MCPCompletion {
        MCPCompletion(text: text, sourceToolUseID: sourceToolUseID)
    }
#endif
}
/// Host-only gateway using injected F03 authority. No guest/model object conveys approval.
package actor HostMCPGateway {
    private struct Entry {
        let connection: HostMCPConnection
        var generation: UInt64 = 0
        var revoked = false
        var initialized = false
        var notified = false
        var discovery: MCPDiscoveryState = .unknown
        var schemaDigest = MCPProtocol.digest(Data("unknown".utf8))
    }
    private final class Run {
        let handle: HostMCPRunHandle
        let authorityHandle: HostRunHandle
        let grant: RunGrant
        var revoked: Bool { authorityHandle.lifecycle.currentStatus != .active }
        var reserved = 0
        var resumeCalls = 0
        var operations: [UUID: (UUID, MCPPreparedOperation)] = [:]
        init(_ h: HostMCPRunHandle, _ a: HostRunHandle, _ g: RunGrant) { handle = h; authorityHandle = a; grant = g }
    }
    private struct Envelope: Codable {
        let runID: UUID
        let epoch: UInt64
        let grantDigest: String
        let connectionID: UUID
        let accountID: UUID
        let accountBindingVersion: UInt64
        let routeVersion: UInt64
        let audience: String
        let route: String
        let protocolVersion: String
        let adapter: String
        let server: String
        let catalogGeneration: UInt64
        let schemaDigest: String
        let resource: String
        let operation: String
        let sourceToolUseID: String?
        let payload: ModelJSON
    }
    package let authority: RunAuthorizationController
    private var registry: [UUID: Entry]
    private var runs: [UUID: Run] = [:]
    private var installing = 0
    private let owner: (any HostRunAttachmentOwner)?
#if DEBUG
    private var attachmentBarrier: (@Sendable (HostAttachmentPhase) async -> Void)?
    package func setAttachmentBarrier(_ barrier: (@Sendable (HostAttachmentPhase) async -> Void)?) { attachmentBarrier = barrier }
#endif
    package init(connections: [HostMCPConnection], auditSink: any SynchronousAuditSink, now: @escaping @Sendable () -> Date = { Date() }, authority: RunAuthorizationController? = nil,
                 owner: (any HostRunAttachmentOwner)? = nil) throws {
        guard connections.count <= 32, Set(connections.map(\.connectionID)).count == connections.count else { throw HostMCPGatewayError.invalidConnection }
        registry = Dictionary(uniqueKeysWithValues: connections.map { ($0.connectionID, Entry(connection: $0)) })
        self.authority = authority ?? RunAuthorizationController(auditSink: auditSink, now: now)
        self.owner = owner
    }
    package func install(grant: RunGrant, authorityHandle existing: HostRunHandle? = nil) async throws -> HostMCPRunHandle {
        let registration = try owner?.beginAttachment(grant: grant, existing: existing)
        defer { if let registration { owner?.endAttachment(registration) } }
        runs = runs.filter { !$0.value.revoked || $0.value.reserved != 0 }
        let duplicate = existing.map { a in runs.values.contains { $0.authorityHandle === a } } ?? false
        guard installing < 32, duplicate || runs.count + installing < 32 else { throw HostMCPGatewayError.busy }
        installing += 1; defer { installing -= 1 }
        let a: HostRunHandle
        if let existing { try await authority.validateAttachment(handle: existing, grant: grant); a = existing }
        else { a = try await authority.install(grant: grant) }
        if let registration { try owner?.registerAttachment(registration, grant: grant, handle: a) }
#if DEBUG
        if let attachmentBarrier { await attachmentBarrier(.afterRegistration) }
#endif
        if let existing = runs.values.first(where: { $0.authorityHandle === a }) {
            if let registration { try owner?.registerAttachment(registration, grant: grant, handle: a) }
            try time(existing); return existing.handle
        }
        let h = HostMCPRunHandle(); let run = Run(h, a, grant); runs[h.token] = run
#if DEBUG
        if let attachmentBarrier { await attachmentBarrier(.beforeExposure) }
#endif
        do {
            if let registration { try owner?.registerAttachment(registration, grant: grant, handle: a) }
            try time(run); return h
        } catch { throw await reconcile(error, run) }
    }
    package func discovery(connectionID: UUID) throws -> MCPDiscoveryState {
        guard let entry = registry[connectionID], !entry.revoked else { throw HostMCPGatewayError.invalidConnection }
        return entry.discovery
    }
    package func propose(handle: HostMCPRunHandle, connectionID: UUID, raw: Data, sourceToolUseID: String? = nil) async throws -> HostMCPProposal {
        let run = try get(handle)
        do {
            let entry = try live(run, connectionID)
            let request = try MCPProtocol.ingress(raw, maxBytes: min(run.grant.resourceLimits.messageBytes, 65536))
            if let sourceToolUseID { guard ModelBlock.validID(sourceToolUseID), request.method == "tools/call" else { throw HostMCPGatewayError.denied } }
            switch request.method {
            case "initialize": guard !entry.initialized else { throw HostMCPGatewayError.denied }
            case "notifications/initialized": guard entry.initialized, !entry.notified else { throw HostMCPGatewayError.denied }
            case "tools/list": guard entry.notified else { throw HostMCPGatewayError.denied }
            case "tools/call": guard entry.discovery == .knownReady, request.resource == "A" else { throw HostMCPGatewayError.denied }
            default: throw HostMCPGatewayError.denied
            }
            let scope = try ResourceScope(service: "mcp", resource: request.resource, operation: request.operation)
            let current = try time(run)
            guard run.grant.decision(for: scope, connectionID: connectionID, at: current) == .allowed else { throw HostMCPGatewayError.denied }
            let c = entry.connection
            let envelope = Envelope(runID: run.grant.runID, epoch: run.grant.epoch, grantDigest: RunAuthorizationController.grantDigest(for: run.grant), connectionID: connectionID, accountID: c.accountID, accountBindingVersion: c.accountBindingVersion, routeVersion: c.routeVersion, audience: c.audience, route: "POST /mcp", protocolVersion: MCPProtocol.version, adapter: MCPProtocol.adapter, server: MCPProtocol.server, catalogGeneration: entry.generation, schemaDigest: entry.schemaDigest, resource: request.resource, operation: request.operation, sourceToolUseID: sourceToolUseID, payload: request.payload)
            let bytes = try MCPProtocol.canonical(envelope)
            guard bytes.count <= min(run.grant.resourceLimits.messageBytes, 65536) else { throw HostMCPGatewayError.denied }
            let binding = try ActionBinding(runID: run.grant.runID, epoch: run.grant.epoch, grantDigest: envelope.grantDigest, connectionID: connectionID, operation: request.operation, schemaDigest: entry.schemaDigest, resolvedResource: request.resource, canonicalRequest: bytes)
            let effectScope = run.authorityHandle.lifecycle.effectScope(connectionID: connectionID)
            let pending = try await authority.propose(handle: run.authorityHandle, binding: binding, display: "MCP \(request.operation): \(request.resource)")
            try validate(run, connectionID, entry.generation)
            return HostMCPProposal(handle: handle, pending: pending, generation: entry.generation, effectScope: effectScope)
        } catch { throw await reconcile(error, run) }
    }
    package func hostApprove(handle: HostMCPRunHandle, proposal: HostMCPProposal) async throws -> HostMCPApproval {
        let run = try get(handle)
        do {
            try validate(run, proposal)
            let approved = try await authority.hostApprove(handle: run.authorityHandle, actionID: proposal.pending.actionID, nonce: proposal.pending.nonce)
            try validate(run, proposal)
            return HostMCPApproval(proposal: proposal, approved: approved)
        } catch { throw await reconcile(error, run) }
    }
    package func hostDeny(handle: HostMCPRunHandle, proposal: HostMCPProposal) async throws {
        let run = try get(handle)
        do {
            try validate(run, proposal)
            try await authority.deny(handle: run.authorityHandle, actionID: proposal.pending.actionID)
            try validate(run, proposal)
        } catch { throw await reconcile(error, run) }
    }
    /// Legacy raw DTO surface; downstream acceptance is not fenced by this overload.
    package func execute(handle: HostMCPRunHandle, approval: HostMCPApproval) async throws -> MCPCompletion {
        try await executeImpl(handle: handle, approval: approval, output: nil)
    }
    package func makeOutput(handle: HostMCPRunHandle, approval: HostMCPApproval) throws -> ControlledRunOutput {
        let run = try get(handle); try validate(run, approval.proposal)
        // Discovery is still the legacy registry-mutation surface, not this consumer.
        guard approval.proposal.pending.binding.resolvedResource == "A" else { throw HostMCPGatewayError.denied }
        return ControlledRunOutput(lifecycle: run.authorityHandle.lifecycle, scope: approval.proposal.effectScope, actionID: approval.proposal.pending.actionID)
    }
    package func execute(handle: HostMCPRunHandle, approval: HostMCPApproval, output: ControlledRunOutput) async throws {
        _ = try await executeImpl(handle: handle, approval: approval, output: output)
    }
    private func executeImpl(handle: HostMCPRunHandle, approval: HostMCPApproval, output: ControlledRunOutput?) async throws -> MCPCompletion {
        let run = try get(handle); let proposal = approval.proposal
        if let output, !output.matches(run.authorityHandle.lifecycle, proposal.effectScope, actionID: proposal.pending.actionID) { throw HostMCPGatewayError.invalidApproval }
        var ownerRegistration: UUID?
        do {
            try validate(run, proposal)
            ownerRegistration = try owner?.beginAttachment(grant: run.grant, existing: run.authorityHandle)
        } catch { throw await reconcile(error, run) }
        defer { if let ownerRegistration { owner?.endAttachment(ownerRegistration) } }
        guard run.reserved < min(run.grant.resourceLimits.concurrentRequests, 2) else { throw HostMCPGatewayError.busy }
        run.reserved += 1; let operationID = UUID()
        defer { run.reserved -= 1; run.authorityHandle.lifecycle.finishEffect(operationID); run.operations.removeValue(forKey: operationID)?.1.cancel() }
        var ticket: DispatchTicket?; var started = false; var completionAttempted = false
        do {
            ticket = try await authority.consume(handle: run.authorityHandle, approved: approval.approved)
            try validate(run, proposal); try Task.checkCancellation()
            guard let ticket, ticket.approvedRequest == proposal.pending.binding.canonicalRequest else { throw HostMCPGatewayError.invalidApproval }
            let e = try JSONDecoder().decode(Envelope.self, from: ticket.approvedRequest)
            let entry = try live(run, e.connectionID); let c = entry.connection
            guard e.runID == run.grant.runID, e.epoch == run.grant.epoch, e.grantDigest == RunAuthorizationController.grantDigest(for: run.grant),
                  e.accountID == c.accountID, e.accountBindingVersion == c.accountBindingVersion, e.routeVersion == c.routeVersion,
                  e.audience == c.audience, e.route == "POST /mcp", e.protocolVersion == MCPProtocol.version, e.adapter == MCPProtocol.adapter,
                  e.server == MCPProtocol.server, e.schemaDigest == entry.schemaDigest, e.catalogGeneration == entry.generation else { throw HostMCPGatewayError.invalidApproval }
            try time(run, deadline: proposal.pending.expiresAt)
            let op = try MCPPreparedOperation(connection: c, payload: e.payload, limit: run.grant.resourceLimits.messageBytes)
            run.operations[operationID] = (e.connectionID, op)
            try validate(run, proposal); try Task.checkCancellation(); try time(run, deadline: proposal.pending.expiresAt)
            try run.authorityHandle.lifecycle.start(.mcp(op), id: operationID, scope: proposal.effectScope,
                notBefore: run.grant.createdAt, startDeadline: proposal.pending.expiresAt)
            started = true
            run.resumeCalls += op.resumeCalls
            var body: Data?
            try await withTaskCancellationHandler {
                for try await bytes in op.chunks { try validate(run, proposal); try Task.checkCancellation(); body = bytes }
            } onCancel: { op.cancel() }
            try validate(run, proposal); try Task.checkCancellation()
            guard let body else { throw HostMCPGatewayError.invalidResponse }
            let result = try MCPProtocol.response(body, request: e.payload)
            let method = e.payload["method"]!.string!
            var text = ""; var catalog: (MCPDiscoveryState, String)?
            switch method {
            case "initialize": try MCPProtocol.validateInitialization(result)
            case "notifications/initialized": break
            case "tools/list": catalog = try MCPProtocol.catalog(result)
            case "tools/call": text = try MCPProtocol.toolText(result)
            default: throw HostMCPGatewayError.invalidResponse
            }
            // Check the actual decoded/joined text, before success audit or any
            // caller/model DTO can exist (JSON escapes and split items included).
            try op.validateOutboundText(text)
            completionAttempted = true
            try await authority.complete(handle: run.authorityHandle, ticket: ticket, outcome: .completed)
            try validate(run, proposal); try Task.checkCancellation()
            if method != "tools/call" {
                var updated = entry; updated.generation &+= 1
                if method == "initialize" { updated.initialized = true }
                if method == "notifications/initialized" { updated.notified = true }
                if let catalog { updated.discovery = catalog.0; updated.schemaDigest = catalog.1 }
                for affected in runs.values where affected.grant.connections.contains(where: { $0.connectionID == e.connectionID }) {
                    affected.authorityHandle.lifecycle.advanceConnection(e.connectionID)
                }
                registry[e.connectionID] = updated; cancelConnection(e.connectionID)
            }
            let completion = MCPCompletion(text: text, sourceToolUseID: e.sourceToolUseID)
            if let output { try output.enqueue(.mcpCompletion(completion)) }
            return completion
        } catch {
            if completionAttempted, error as? AuthorizationError == .auditFailed, let ownerRegistration {
                owner?.attachmentCleanupFailed(ownerRegistration)
            }
            output?.cancel()
            run.operations[operationID]?.1.cancel()
            // A failed refresh cannot preserve authority derived from an old catalog.
            // Invalidate synchronously before audit reconciliation can suspend.
            if started && proposal.pending.binding.operation == "tools/list" {
                try? invalidateCatalog(connectionID: proposal.pending.binding.connectionID)
            }
            let sanitized = await reconcile(error, run)
            if let ticket, !completionAttempted {
                do { try await authority.complete(handle: run.authorityHandle, ticket: ticket, outcome: started ? .unknown : .failed) }
                catch {
                    if error as? AuthorizationError == .auditFailed, let ownerRegistration {
                        owner?.attachmentCleanupFailed(ownerRegistration)
                    }
                    throw await reconcile(error, run)
                }
            }
            if sanitized as? HostMCPGatewayError == .auditFailed { throw sanitized }
            if started { throw HostMCPGatewayError.outcomeUnknown }
            if ticket != nil { throw HostMCPGatewayError.notStarted }
            throw sanitized
        }
    }
    package func isRevoked(handle: HostMCPRunHandle) throws -> Bool { try get(handle).revoked }
    package func resumedTaskCount(handle: HostMCPRunHandle) throws -> Int { try get(handle).resumeCalls }
    package func lifecycle(handle: HostMCPRunHandle) throws -> RunLifecycle { try get(handle).authorityHandle.lifecycle }
    package func stop(handle: HostMCPRunHandle) async throws {
        let run = try get(handle); run.authorityHandle.lifecycle.terminate(.stopped); revoke(run); try await authority.stop(handle: run.authorityHandle)
    }
    package func revokeConnection(_ id: UUID) async throws {
        guard var entry = registry[id] else { throw HostMCPGatewayError.invalidConnection }
        entry.revoked = true; entry.generation &+= 1; registry[id] = entry
        let affected = runs.values.filter { $0.grant.connections.contains { $0.connectionID == id } }
        for run in affected { run.authorityHandle.lifecycle.invalidateConnection(id) }
        cancelConnection(id)
        for run in affected { try? await authority.revokeConnection(handle: run.authorityHandle, connectionID: id) }
    }
    /// Host-side catalog invalidation; every outstanding approval is stale before return.
    package func invalidateCatalog(connectionID: UUID) throws {
        guard var entry = registry[connectionID], !entry.revoked else { throw HostMCPGatewayError.invalidConnection }
        entry.generation &+= 1; entry.discovery = .unknown; entry.schemaDigest = MCPProtocol.digest(Data("unknown".utf8))
        for run in runs.values where run.grant.connections.contains(where: { $0.connectionID == connectionID }) {
            run.authorityHandle.lifecycle.advanceConnection(connectionID)
        }
        registry[connectionID] = entry; cancelConnection(connectionID)
    }
    package func updateConnection(_ c: HostMCPConnection) async throws {
        guard let old = registry[c.connectionID], !old.revoked, c.accountBindingVersion >= old.connection.accountBindingVersion, c.routeVersion >= old.connection.routeVersion,
              c.accountBindingVersion > old.connection.accountBindingVersion || c.routeVersion > old.connection.routeVersion,
              c.accountID == old.connection.accountID || c.accountBindingVersion > old.connection.accountBindingVersion,
              c.audience == old.connection.audience || c.routeVersion > old.connection.routeVersion else { throw HostMCPGatewayError.invalidConnection }
        registry[c.connectionID] = Entry(connection: c, generation: old.generation &+ 1)
        let affected = runs.values.filter { $0.grant.connections.contains { $0.connectionID == c.connectionID } }
        for run in affected { run.authorityHandle.lifecycle.invalidateConnection(c.connectionID) }
        cancelConnection(c.connectionID)
        for run in affected { try? await authority.updateConnection(handle: run.authorityHandle, connectionID: c.connectionID, accountBindingVersion: c.accountBindingVersion, routeVersion: c.routeVersion) }
    }
    private func get(_ h: HostMCPRunHandle) throws -> Run {
        guard let run = runs[h.token], run.handle === h else { throw HostMCPGatewayError.invalidHandle }; return run
    }
    @discardableResult private func time(_ run: Run, deadline: Date? = nil) throws -> Date {
        guard !run.revoked else { throw HostMCPGatewayError.revoked }
        let observation = run.authorityHandle.lifecycle.observeAndReduce(reason: "mcp")
        let current = observation.effectiveTime
        if observation.status != .active { revoke(run); throw HostMCPGatewayError.revoked }
        guard observation.wallTime >= run.grant.createdAt else { throw AuthorizationError.grantNotYetValid }
        if let deadline, current >= deadline { throw AuthorizationError.actionExpired }; return current
    }
    private func live(_ run: Run, _ id: UUID) throws -> Entry {
        try time(run)
        guard run.authorityHandle.lifecycle.permitsConnection(id), let entry = registry[id], !entry.revoked, let c = run.grant.connections.first(where: { $0.connectionID == id }), c.accountBindingVersion == entry.connection.accountBindingVersion, c.routeVersion == entry.connection.routeVersion else { throw HostMCPGatewayError.invalidConnection }; return entry
    }
    private func validate(_ run: Run, _ id: UUID, _ generation: UInt64) throws {
        let entry = try live(run, id); guard entry.generation == generation else { throw HostMCPGatewayError.revoked }
    }
    private func validate(_ run: Run, _ p: HostMCPProposal) throws {
        guard p.handle === run.handle else { throw HostMCPGatewayError.invalidHandle }; try validate(run, p.pending.binding.connectionID, p.generation)
    }
    private func cancelConnection(_ id: UUID) { for run in runs.values { for (_, pair) in run.operations where pair.0 == id { pair.1.cancel() } } }
    private func revoke(_ run: Run) { run.authorityHandle.lifecycle.terminate(.revoked); for (_, pair) in run.operations { pair.1.cancel() } }
    private func reconcile(_ error: Error, _ run: Run) async -> Error {
        if let a = error as? AuthorizationError, [.auditFailed, .grantExpired, .runRevoked].contains(a) { revoke(run) }
        if run.revoked { try? await authority.stop(handle: run.authorityHandle) }
        if error as? AuthorizationError == .auditFailed { return HostMCPGatewayError.auditFailed }
        if error is AuthorizationError || error is HostMCPGatewayError { return error }
        return HostMCPGatewayError.notStarted
    }
}
