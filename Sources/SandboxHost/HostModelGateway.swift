import Foundation
import Darwin
import CryptoKit
import SandboxContracts

/// Trusted-host configuration only. Credentials are bound to this account by the host provider.
/// No URL or caller headers can be supplied through a proposal.
package struct HostModelConnection: Sendable {
    package let connectionID: UUID
    package let accountID: UUID
    package let accountBindingVersion: UInt64
    package let routeVersion: UInt64
    package let model: FixedModel
    package let `protocol`: FixedProtocol
    fileprivate let transport: ModelTransport

    package init(connectionID: UUID, accountID: UUID, accountBindingVersion: UInt64, routeVersion: UInt64,
        model: FixedModel, protocol kind: FixedProtocol, credentialProvider: any ModelCredentialProvider,
        configuration: URLSessionConfiguration? = nil) {
        self.connectionID = connectionID; self.accountID = accountID
        self.accountBindingVersion = accountBindingVersion; self.routeVersion = routeVersion
        self.model = model; self.protocol = kind
        transport = ModelTransport(credentialProvider: credentialProvider, configuration: configuration)
    }
}

package enum HostModelGatewayError: Error, Equatable, Sendable {
    case invalidHandle, revoked, denied, invalidConnection, invalidApproval, busy, messageTooLarge
    case auditFailed, notStarted, outcomeUnknown
    case businessRouteDisabled
}

/// Not Codable, not guest-initializable; identity is checked against this gateway's private state.
package final class HostModelRunHandle: Sendable {
    fileprivate let token = UUID()
    fileprivate init() {}
}
package struct HostModelProposal: Sendable {
    package var actionID: UUID { pending.actionID }
    package var pendingAction: PendingAction { pending }
    fileprivate let handle: HostModelRunHandle
    fileprivate let pending: PendingAction
    fileprivate let connectionGeneration: UInt64
    fileprivate let runGeneration: UInt64
    fileprivate let effectScope: RunEffectScope
}
package struct HostModelApproval: Sendable {
    fileprivate let proposal: HostModelProposal
    fileprivate let approved: ApprovedAction
}

#if DEBUG
package enum HostAttachmentPhase: String, CaseIterable, Sendable { case afterRegistration, beforeExposure }
#endif

/// Composition ownership for attachments and their in-flight uses. Implementations seal registration synchronously;
/// F03 remains the sole lifecycle, clock, start and output authority.
package protocol HostRunAttachmentOwner: Sendable {
    func beginAttachment(grant: RunGrant, existing: HostRunHandle?) throws -> UUID
    func registerAttachment(_ token: UUID, grant: RunGrant, handle: HostRunHandle) throws
    func endAttachment(_ token: UUID)
    func attachmentCleanupFailed(_ token: UUID)
}

/// A host-only integration slice, not a guest listener or an F10 approval UI.
/// Uses the injected F03 authority; retains only gateway/transport bookkeeping.

package actor HostModelGateway {
    private struct Entry {
        let connection: HostModelConnection
        var generation: UInt64 = 0
        var revoked = false
    }
    private final class Run {
        let handle: HostModelRunHandle
        let authorityHandle: HostRunHandle
        let grant: RunGrant
        var generation: UInt64 { authorityHandle.lifecycle.currentGeneration }
        var revoked: Bool { authorityHandle.lifecycle.currentStatus != .active }
        var reserved = 0
        var resumeCalls = 0
        var operations: [UUID: (UUID, ModelPreparedOperation)] = [:]
        init(handle: HostModelRunHandle, authorityHandle: HostRunHandle, grant: RunGrant) {
            self.handle = handle; self.authorityHandle = authorityHandle; self.grant = grant
        }
    }
    private struct Envelope: Codable {
        let schemaVersion: Int
        let runID: UUID
        let epoch: UInt64
        let connectionID: UUID
        let accountID: UUID
        let accountBindingVersion: UInt64
        let routeVersion: UInt64
        let streaming: Bool
        let request: FixedModelRequest?
        let nativeBody: ModelJSON?
        let claudeSelectors: ClaudeRequestSelectors?
    }
    package let authority: RunAuthorizationController
    private let owner: (any HostRunAttachmentOwner)?
#if DEBUG
    private var attachmentBarrier: (@Sendable (HostAttachmentPhase) async -> Void)?
    package func setAttachmentBarrier(_ barrier: (@Sendable (HostAttachmentPhase) async -> Void)?) { attachmentBarrier = barrier }
#endif
    private var registry: [UUID: Entry] = [:]
    private var runs: [UUID: Run] = [:]
    private static let schemaDigest = SHA256.hash(data: Data("host-model-envelope-v2".utf8)).map { String(format: "%02x", $0) }.joined()

    package init(connections: [HostModelConnection], auditSink: any SynchronousAuditSink,
        clock: RunClock = .system(), authority: RunAuthorizationController? = nil,
        owner: (any HostRunAttachmentOwner)? = nil) throws {
        guard Set(connections.map(\.connectionID)).count == connections.count,
              connections.allSatisfy({ $0.accountBindingVersion > 0 && $0.routeVersion > 0 }) else {
            throw HostModelGatewayError.invalidConnection
        }
        registry = Dictionary(uniqueKeysWithValues: connections.map { ($0.connectionID, Entry(connection: $0)) })
        self.authority = authority ?? RunAuthorizationController(auditSink: auditSink, clock: clock)
        self.owner = owner
    }

    package func install(grant: RunGrant, authorityHandle existing: HostRunHandle? = nil) async throws -> HostModelRunHandle {
        let registration = try owner?.beginAttachment(grant: grant, existing: existing)
        defer { if let registration { owner?.endAttachment(registration) } }
        let authorityHandle: HostRunHandle
        if let existing { try await authority.validateAttachment(handle: existing, grant: grant); authorityHandle = existing }
        else { authorityHandle = try await authority.install(grant: grant) }
        if let registration { try owner?.registerAttachment(registration, grant: grant, handle: authorityHandle) }
#if DEBUG
        if let attachmentBarrier { await attachmentBarrier(.afterRegistration) }
#endif
        guard authorityHandle.lifecycle.currentStatus == .active else { throw AuthorizationError.runRevoked }
        // Reclaim only settled gateway bookkeeping, never authority replay state.
        runs = runs.filter { !$0.value.revoked || $0.value.reserved != 0 }
        if let existing = runs.values.first(where: { $0.authorityHandle === authorityHandle }) {
            if let registration { try owner?.registerAttachment(registration, grant: grant, handle: authorityHandle) }
            return existing.handle
        }
        // Installation creates no dispatch permission; all registry/time checks repeat at use.
        let handle = HostModelRunHandle()
        runs[handle.token] = Run(handle: handle, authorityHandle: authorityHandle, grant: grant)
#if DEBUG
        if let attachmentBarrier { await attachmentBarrier(.beforeExposure) }
#endif
        if let registration { try owner?.registerAttachment(registration, grant: grant, handle: authorityHandle) }
        guard authorityHandle.lifecycle.currentStatus == .active else { throw AuthorizationError.runRevoked }
        return handle
    }

    package func propose(handle: HostModelRunHandle, connectionID: UUID, request: FixedModelRequest,
        streaming: Bool) async throws -> HostModelProposal {
        let run = try get(handle)
        do {
            let entry = try live(run, connectionID: connectionID)
            guard request.model == entry.connection.model, request.protocol == entry.connection.protocol else {
                throw HostModelGatewayError.denied
            }
            let scope = try ResourceScope(service: "model", resource: request.model.rawValue, operation: streaming ? "stream" : "complete")
            // Validate this fresh sample before scope priority can hide terminal expiry.
            let scopeTime = try validatedRunTime(run)
            guard run.grant.decision(for: scope, connectionID: connectionID, at: scopeTime) == .allowed else {
                throw HostModelGatewayError.denied
            }
            let envelope = Envelope(schemaVersion: 2, runID: run.grant.runID, epoch: run.grant.epoch,
                connectionID: connectionID, accountID: entry.connection.accountID,
                accountBindingVersion: entry.connection.accountBindingVersion, routeVersion: entry.connection.routeVersion,
                streaming: streaming, request: request, nativeBody: nil, claudeSelectors: nil)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let canonical = try encoder.encode(envelope)
            guard canonical.count <= min(run.grant.resourceLimits.messageBytes, 65_536) else { throw HostModelGatewayError.messageTooLarge }
            let binding = try ActionBinding(runID: run.grant.runID, epoch: run.grant.epoch,
                grantDigest: RunAuthorizationController.grantDigest(for: run.grant), connectionID: connectionID,
                operation: scope.operation, schemaDigest: Self.schemaDigest, resolvedResource: scope.resource, canonicalRequest: canonical)
            let generation = run.generation
            let effectScope = run.authorityHandle.lifecycle.effectScope(connectionID: connectionID)
            let pending = try await authority.propose(handle: run.authorityHandle, binding: binding, display: "Model \(scope.operation): \(scope.resource)")
            try validate(run, generation: generation, connectionID: connectionID, connectionGeneration: entry.generation)
            return HostModelProposal(handle: handle, pending: pending, connectionGeneration: entry.generation, runGeneration: generation, effectScope: effectScope)
        } catch { throw await handleError(error, run: run) }
    }

    package func proposeNative(handle: HostModelRunHandle, connectionID: UUID, body: Data,
        streaming: Bool) async throws -> HostModelProposal {
        let request = try AnthropicNativeRequest.decodeValidated(body, streaming: streaming)
        return try await proposeValidatedNative(handle: handle, connectionID: connectionID, request: request, selectors: nil)
    }

    /// Admission is available for inspection; execution is independently disabled
    /// before ticket consumption and again before credential access in transport.
    package func proposeClaude(handle: HostModelRunHandle, connectionID: UUID,
                               ingress: BusinessHTTPIngress) async throws -> HostModelProposal {
        let selectors = try ingress.claudeSelectors
        let request = try ingress.claudeRequest()
        return try await proposeValidatedNative(handle: handle, connectionID: connectionID, request: request, selectors: selectors)
    }

    private func proposeValidatedNative(handle: HostModelRunHandle, connectionID: UUID,
                                        request: AnthropicNativeRequest, selectors: ClaudeRequestSelectors?) async throws -> HostModelProposal {
        let streaming = request.streaming
        let run = try get(handle)
        do {
            let entry = try live(run, connectionID: connectionID)
            guard entry.connection.model == request.model, entry.connection.protocol == .anthropic else { throw HostModelGatewayError.denied }
            let scope = try ResourceScope(service: "model", resource: request.model.rawValue, operation: streaming ? "stream" : "complete")
            let time = try validatedRunTime(run)
            guard run.grant.decision(for: scope, connectionID: connectionID, at: time) == .allowed else { throw HostModelGatewayError.denied }
            let envelope = Envelope(schemaVersion: selectors == nil ? 3 : 4, runID: run.grant.runID, epoch: run.grant.epoch,
                connectionID: connectionID, accountID: entry.connection.accountID,
                accountBindingVersion: entry.connection.accountBindingVersion, routeVersion: entry.connection.routeVersion,
                streaming: streaming, request: nil, nativeBody: request.body, claudeSelectors: selectors)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let canonical = try encoder.encode(envelope)
            guard canonical.count <= min(run.grant.resourceLimits.messageBytes, 65_536) else { throw HostModelGatewayError.messageTooLarge }
            let domain = selectors == nil ? "host-model-native-envelope-v3" : "host-model-claude-envelope-v4"
            let digest = SHA256.hash(data: Data(domain.utf8)).map { String(format: "%02x", $0) }.joined()
            let binding = try ActionBinding(runID: run.grant.runID, epoch: run.grant.epoch,
                grantDigest: RunAuthorizationController.grantDigest(for: run.grant), connectionID: connectionID,
                operation: scope.operation, schemaDigest: digest, resolvedResource: scope.resource, canonicalRequest: canonical)
            let generation = run.generation
            let effectScope = run.authorityHandle.lifecycle.effectScope(connectionID: connectionID)
            let pending = try await authority.propose(handle: run.authorityHandle, binding: binding, display: "Model \(scope.operation): \(scope.resource)")
            try validate(run, generation: generation, connectionID: connectionID, connectionGeneration: entry.generation)
            return HostModelProposal(handle: handle, pending: pending, connectionGeneration: entry.generation, runGeneration: generation, effectScope: effectScope)
        } catch { throw await handleError(error, run: run) }
    }

    /// Only a trusted host decision may invoke this; there is no low-risk auto-approval path.
    package func hostApprove(handle: HostModelRunHandle, proposal: HostModelProposal) async throws -> HostModelApproval {
        let run = try get(handle)
        do {
            try validate(run, proposal: proposal)
            let approved = try await authority.hostApprove(handle: run.authorityHandle, actionID: proposal.pending.actionID, nonce: proposal.pending.nonce)
            try validate(run, proposal: proposal)
            return HostModelApproval(proposal: proposal, approved: approved)
        } catch { throw await handleError(error, run: run) }
    }

    package func hostDeny(handle: HostModelRunHandle, proposal: HostModelProposal) async throws {
        let run = try get(handle)
        do {
            try validate(run, proposal: proposal)
            try await authority.deny(handle: run.authorityHandle, actionID: proposal.pending.actionID)
            try validate(run, proposal: proposal)
        } catch { throw await handleError(error, run: run) }
    }

    /// Legacy raw-output API. Its callback and returned DTO consumer migration is
    /// NOT complete; use the controlled output overload for fenced acceptance.
    /// Provisional events are not approval. All message_delta metadata and the
    /// success final wait for durable F03 completion. No automatic retry.
    package func execute(handle: HostModelRunHandle, approval: HostModelApproval,
        emit: @escaping @Sendable (ModelStreamChunk) -> Void = { _ in }) async throws -> ModelCompletion {
        try await executeImpl(handle: handle, approval: approval, output: nil, emit: emit)
    }
    package func makeOutput(handle: HostModelRunHandle, approval: HostModelApproval) throws -> ControlledRunOutput {
        let run = try get(handle); try validate(run, proposal: approval.proposal)
        return ControlledRunOutput(lifecycle: run.authorityHandle.lifecycle, scope: effectScope(approval.proposal), actionID: approval.proposal.pending.actionID)
    }
    /// Trusted host accepts and relinquishes one local socket; no guest route or
    /// connection ID is accepted here. Consumes the descriptor even on failure.
    /// Only the existing controlled execute overload can produce into this output.
    package func makeNativeOutput(handle: HostModelRunHandle, approval: HostModelApproval,
                                  takingAcceptedSocket fd: Int32) throws -> ControlledRunOutput {
        var transferred = false
        defer { if !transferred, fd >= 0 { Darwin.close(fd) } }
        let run = try get(handle); try validate(run, proposal: approval.proposal)
        let envelope = try JSONDecoder().decode(Envelope.self, from: approval.proposal.pending.binding.canonicalRequest)
        guard ([3, 4].contains(envelope.schemaVersion) && envelope.nativeBody != nil && envelope.request == nil) ||
              (envelope.schemaVersion == 2 && envelope.nativeBody == nil && envelope.request?.protocol == .anthropic) else { throw NativeResponseError.invalidEvent }
        transferred = true
        return try ControlledRunOutput(lifecycle: run.authorityHandle.lifecycle,
            scope: effectScope(approval.proposal), actionID: approval.proposal.pending.actionID,
            takingAcceptedSocket: fd, streaming: envelope.streaming)
    }
    /// Only a connection minted by the actual installed VM can be adopted. The
    /// final writer owns both receiver and VM connection before the lifecycle
    /// clock, so physical session retirement also prevents a last-hop send.
    package func makeVMNativeOutput(handle: HostModelRunHandle, approval: HostModelApproval,
                                    connection: BusinessVMConnection) throws -> ControlledRunOutput {
        var transferred = false
        defer { if !transferred { connection.retire() } }
        let run = try get(handle); try validate(run, proposal: approval.proposal)
        guard connection.service == .model, connection.lifecycle === run.authorityHandle.lifecycle,
              connection.runID == run.grant.runID, connection.epoch == run.grant.epoch else { throw HostModelGatewayError.invalidHandle }
        let envelope = try JSONDecoder().decode(Envelope.self, from: approval.proposal.pending.binding.canonicalRequest)
        guard envelope.schemaVersion == 4, let selectors = envelope.claudeSelectors,
              envelope.nativeBody != nil, envelope.request == nil else { throw HostModelGatewayError.invalidApproval }
        try selectors.validate()
        transferred = true
        return try ControlledRunOutput(lifecycle: run.authorityHandle.lifecycle,
            scope: effectScope(approval.proposal), actionID: approval.proposal.pending.actionID,
            takingVMConnection: connection, streaming: envelope.streaming)
    }
    /// Controlled-output vertical API: caller drives acceptNext on the owned receiver. Completion
    /// means producer/audit finished, NOT that queued business output was accepted.
    package func execute(handle: HostModelRunHandle, approval: HostModelApproval, output: ControlledRunOutput) async throws {
        _ = try await executeImpl(handle: handle, approval: approval, output: output, emit: { _ in })
    }
    private func effectScope(_ proposal: HostModelProposal) -> RunEffectScope {
        proposal.effectScope
    }
    private func executeImpl(handle: HostModelRunHandle, approval: HostModelApproval, output: ControlledRunOutput?,
        emit: @escaping @Sendable (ModelStreamChunk) -> Void) async throws -> ModelCompletion {
        let run = try get(handle)
        let proposal = approval.proposal
        let activationEnvelope = try JSONDecoder().decode(Envelope.self, from: proposal.pending.binding.canonicalRequest)
        if activationEnvelope.schemaVersion == 4 {
            guard BusinessModelActivation.credentialEgressEnabled else { throw HostModelGatewayError.businessRouteDisabled }
        }
        if let output, !output.matches(run.authorityHandle.lifecycle, effectScope(proposal), actionID: proposal.pending.actionID) { throw HostModelGatewayError.invalidApproval }
        var ownerRegistration: UUID?
        do {
            try validate(run, proposal: proposal)
            ownerRegistration = try owner?.beginAttachment(grant: run.grant, existing: run.authorityHandle)
        }
        catch { throw await handleError(error, run: run) }
        // Keep this resource owned until the existing completion/cancellation
        // bookkeeping below has settled; close must not acknowledge it early.
        defer { if let ownerRegistration { owner?.endAttachment(ownerRegistration) } }
        guard run.reserved < min(run.grant.resourceLimits.concurrentRequests, ModelTransport.maxConcurrentRequests) else { throw HostModelGatewayError.busy }
        run.reserved += 1
        let operationID = UUID()
        defer { run.reserved -= 1; run.authorityHandle.lifecycle.finishEffect(operationID); run.operations.removeValue(forKey: operationID)?.1.cancel() }
        var ticket: DispatchTicket?
        var started = false
        var completionAttempted = false
        do {
            // F03 synchronously persists dispatch-intent before returning this ticket.
            ticket = try await authority.consume(handle: run.authorityHandle, approved: approval.approved)
            try validate(run, proposal: proposal)
            try Task.checkCancellation()
            guard let ticket, ticket.approvedRequest == proposal.pending.binding.canonicalRequest else { throw HostModelGatewayError.invalidApproval }
            // The actual request is reconstructed ONLY from the immutable F03 approved bytes.
            let envelope = try JSONDecoder().decode(Envelope.self, from: ticket.approvedRequest)
            let entry = try live(run, connectionID: envelope.connectionID)
            guard envelope.runID == run.grant.runID, envelope.epoch == run.grant.epoch,
                  envelope.accountID == entry.connection.accountID,
                  envelope.accountBindingVersion == entry.connection.accountBindingVersion,
                  envelope.routeVersion == entry.connection.routeVersion else {
                throw HostModelGatewayError.invalidApproval
            }
            let native: AnthropicNativeRequest?
            if let body = envelope.nativeBody {
                guard [3, 4].contains(envelope.schemaVersion), envelope.request == nil, entry.connection.protocol == .anthropic else { throw HostModelGatewayError.invalidApproval }
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                if envelope.schemaVersion == 4 {
                    guard let selectors = envelope.claudeSelectors else { throw HostModelGatewayError.invalidApproval }
                    native = try AnthropicNativeRequest.decodeClaude(encoder.encode(body), streaming: envelope.streaming, selectors: selectors)
                } else {
                    guard envelope.claudeSelectors == nil else { throw HostModelGatewayError.invalidApproval }
                    native = try AnthropicNativeRequest.decodeValidated(encoder.encode(body), streaming: envelope.streaming)
                }
                guard native?.model == entry.connection.model else { throw HostModelGatewayError.invalidApproval }
            } else {
                guard envelope.schemaVersion == 2, envelope.claudeSelectors == nil, let request = envelope.request,
                      request.model == entry.connection.model, request.protocol == entry.connection.protocol else { throw HostModelGatewayError.invalidApproval }
                native = nil
            }
            // No suspension from final liveness validation through credential access and resume().
            try validatedRunTime(run, startDeadline: proposal.pending.expiresAt)
            let operation: ModelPreparedOperation
            if let native {
                if let selectors = envelope.claudeSelectors { operation = try entry.connection.transport.prepareClaude(native, selectors: selectors) }
                else { operation = try entry.connection.transport.prepareNative(native) }
            }
            else if let request = envelope.request { operation = try entry.connection.transport.prepare(request, streaming: envelope.streaming) }
            else { throw HostModelGatewayError.invalidApproval }
            run.operations[operationID] = (envelope.connectionID, operation)
            try validate(run, proposal: proposal)
            try Task.checkCancellation()
            try validatedRunTime(run, startDeadline: proposal.pending.expiresAt)
            try run.authorityHandle.lifecycle.start(.model(operation), id: operationID,
                scope: proposal.effectScope,
                notBefore: run.grant.createdAt, startDeadline: proposal.pending.expiresAt)
            started = true
            run.resumeCalls += operation.resumeCalls
            var text = ""
            var sawFinal = false
            var completion: ModelCompletion?
            var terminal: [ModelStreamChunk] = []
            try await withTaskCancellationHandler {
                for try await chunk in operation.chunks {
                    try validate(run, proposal: proposal)
                    try Task.checkCancellation()
                    if let value = chunk.completion { completion = value }
                    if chunk.isFinal { sawFinal = true }
                    if chunk.isTerminal { terminal.append(chunk) } else {
                        text += chunk.text
                        if envelope.streaming {
                            if let output { try output.enqueue(.modelChunk(chunk)) } else { emit(chunk) }
                        }
                    }
                }
            } onCancel: { operation.cancel() }
            try validate(run, proposal: proposal)
            try Task.checkCancellation()
            guard sawFinal else { throw HostModelGatewayError.outcomeUnknown }
            completionAttempted = true
            try await authority.complete(handle: run.authorityHandle, ticket: ticket, outcome: .completed)
            try validate(run, proposal: proposal)
            try Task.checkCancellation()
            if envelope.streaming {
                for chunk in terminal {
                    try validate(run, proposal: proposal)
                    try Task.checkCancellation()
                    if let output { try output.enqueue(.modelChunk(chunk)) } else { emit(chunk) }
                }
            }
            let result = completion ?? ModelCompletion(text: text)
            if !envelope.streaming, let output { try output.enqueue(.modelCompletion(result)) }
            return result
        } catch {
            if completionAttempted, error as? AuthorizationError == .auditFailed, let ownerRegistration {
                owner?.attachmentCleanupFailed(ownerRegistration)
            }
            output?.cancel()
            run.operations[operationID]?.1.cancel()
            let sanitized = await handleError(error, run: run)
            if let ticket, !completionAttempted {
                // F03 has no notDispatched completion variant: .failed means known pre-start failure;
                // .unknown means a started call may already have affected the upstream.
                completionAttempted = true
                do { try await authority.complete(handle: run.authorityHandle, ticket: ticket, outcome: started ? .unknown : .failed) }
                catch {
                    if error as? AuthorizationError == .auditFailed, let ownerRegistration {
                        owner?.attachmentCleanupFailed(ownerRegistration)
                    }
                    throw await handleError(error, run: run)
                }
                // No success or further dispatch after this suspension, including a stopped run.
            }
            if sanitized as? HostModelGatewayError == .auditFailed { throw sanitized }
            if started { throw HostModelGatewayError.outcomeUnknown }
            if ticket != nil { throw HostModelGatewayError.notStarted }
            throw sanitized
        }
    }

    package func stop(handle: HostModelRunHandle) async throws {
        let run = try get(handle)
        run.authorityHandle.lifecycle.terminate(.stopped)
        revoke(run) // The linearization point precedes the first await.
        try await authority.stop(handle: run.authorityHandle)
    }
    package func isRevoked(handle: HostModelRunHandle) throws -> Bool { try get(handle).revoked }
    package func resumedTaskCount(handle: HostModelRunHandle) throws -> Int { try get(handle).resumeCalls }
    package func lifecycle(handle: HostModelRunHandle) throws -> RunLifecycle { try get(handle).authorityHandle.lifecycle }

    package func revokeConnection(_ connectionID: UUID) async throws {
        guard var entry = registry[connectionID] else { throw HostModelGatewayError.invalidConnection }
        entry.revoked = true; entry.generation &+= 1; registry[connectionID] = entry
        let affected = affectedRuns(connectionID)
        for run in affected { run.authorityHandle.lifecycle.invalidateConnection(connectionID) }
        for run in affected { cancelConnection(run, connectionID) }
        for run in affected { try? await authority.revokeConnection(handle: run.authorityHandle, connectionID: connectionID) }
    }
    package func updateConnection(_ connection: HostModelConnection) async throws {
        guard let old = registry[connection.connectionID], !old.revoked,
              connection.accountBindingVersion >= old.connection.accountBindingVersion,
              connection.routeVersion >= old.connection.routeVersion,
              connection.accountBindingVersion > old.connection.accountBindingVersion || connection.routeVersion > old.connection.routeVersion,
              connection.accountID == old.connection.accountID || connection.accountBindingVersion > old.connection.accountBindingVersion,
              (connection.model == old.connection.model && connection.protocol == old.connection.protocol) || connection.routeVersion > old.connection.routeVersion else {
            throw HostModelGatewayError.invalidConnection
        }
        registry[connection.connectionID] = Entry(connection: connection, generation: old.generation &+ 1)
        let affected = affectedRuns(connection.connectionID)
        for run in affected { run.authorityHandle.lifecycle.invalidateConnection(connection.connectionID) }
        for run in affected { cancelConnection(run, connection.connectionID) }
        for run in affected {
            try? await authority.updateConnection(handle: run.authorityHandle, connectionID: connection.connectionID,
                accountBindingVersion: connection.accountBindingVersion, routeVersion: connection.routeVersion)
        }
    }
    private func affectedRuns(_ id: UUID) -> [Run] { runs.values.filter { $0.grant.connections.contains { $0.connectionID == id } } }
    private func cancelConnection(_ run: Run, _ id: UUID) { for (_, pair) in run.operations where pair.0 == id { pair.1.cancel() } }
    private func get(_ handle: HostModelRunHandle) throws -> Run {
        guard let run = runs[handle.token], run.handle === handle else { throw HostModelGatewayError.invalidHandle }
        return run
    }
    /// The sole gateway clock read. Every sample validates the run first; start
    /// gates compare the action deadline against that SAME validated sample.
    /// Expiry is terminal before any suspension; early time/action denial is not.
    @discardableResult
    private func validatedRunTime(_ run: Run, startDeadline: Date? = nil) throws -> Date {
        guard !run.revoked else { throw HostModelGatewayError.revoked }
        let observation = run.authorityHandle.lifecycle.observeAndReduce(reason: "model")
        let current = observation.effectiveTime
        if observation.status != .active {
            revoke(run) // Latch and cancel synchronously; callers await F03 reconciliation.
            throw HostModelGatewayError.revoked
        }
        guard observation.wallTime >= run.grant.createdAt else { throw AuthorizationError.grantNotYetValid }
        // Action expiry limits dispatch, never already-started chunks/completion.
        if let startDeadline, current >= startDeadline { throw AuthorizationError.actionExpired }
        return current
    }
    private func live(_ run: Run, connectionID: UUID) throws -> Entry {
        try validatedRunTime(run)
        guard run.authorityHandle.lifecycle.permitsConnection(connectionID),
              let entry = registry[connectionID], !entry.revoked,
              let granted = run.grant.connections.first(where: { $0.connectionID == connectionID }),
              granted.accountBindingVersion == entry.connection.accountBindingVersion,
              granted.routeVersion == entry.connection.routeVersion else { throw HostModelGatewayError.invalidConnection }
        return entry
    }
    private func validate(_ run: Run, generation: UInt64, connectionID: UUID, connectionGeneration: UInt64) throws {
        let entry = try live(run, connectionID: connectionID)
        guard run.generation == generation, entry.generation == connectionGeneration else { throw HostModelGatewayError.revoked }
    }
    private func validate(_ run: Run, proposal: HostModelProposal) throws {
        guard proposal.handle === run.handle else { throw HostModelGatewayError.invalidHandle }
        try validate(run, generation: proposal.runGeneration, connectionID: proposal.pending.binding.connectionID, connectionGeneration: proposal.connectionGeneration)
    }

    private func revoke(_ run: Run) {
        run.authorityHandle.lifecycle.terminate(.revoked)
        for (_, pair) in run.operations { pair.1.cancel() }
    }
    private func handleError(_ error: Error, run: Run) async -> Error {
        let authorizationError = error as? AuthorizationError
        if authorizationError == .auditFailed || authorizationError == .grantExpired || authorizationError == .runRevoked {
            revoke(run)
        }
        // No detached reconciliation: pending approvals are retired before returning.
        // F03 STOP preserves issued tickets so outstanding completions remain recordable.
        if run.revoked { try? await authority.stop(handle: run.authorityHandle) }
        if authorizationError == .auditFailed { return HostModelGatewayError.auditFailed }
        if error is AuthorizationError || error is HostModelGatewayError || error is ModelTransportError { return error }
        return HostModelGatewayError.notStarted
    }
}
