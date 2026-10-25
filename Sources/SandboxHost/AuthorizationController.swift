import CryptoKit
import Darwin
import Foundation
import SandboxContracts

public enum AuthorizationError: Error, Equatable, Sendable {
    case duplicateRun
    case grantNotYetValid
    case grantExpired
    case invalidHandle
    case runRevoked
    case wrongRun
    case wrongEpoch
    case grantBindingMismatch
    case connectionNotGranted
    case connectionRevoked
    case connectionVersionMismatch
    case resourceNotGranted
    case resourceMappingAmbiguous
    case pendingLimit
    case actionDenied
    case actionExpired
    case actionNotPending
    case approvalMismatch
    case ticketAlreadyConsumed
    case ticketInvalid
    case auditFailed
    case completionAlreadyRecorded
}

/// A host-created capability. It has no public initializer and carries no guest-authenticated run ID.
public final class HostRunHandle: @unchecked Sendable {
    fileprivate let token: UUID
    fileprivate let authorityIdentity: UUID
    fileprivate let installedGrant: RunGrant

    public let lifecycle: RunLifecycle
    public let runID: UUID
    package var installedEpoch: UInt64 { installedGrant.epoch }
    let grantDigest: String
    fileprivate init(token: UUID, lifecycle: RunLifecycle, grant: RunGrant, authorityIdentity: UUID) {
        self.token = token
        self.lifecycle = lifecycle
        self.authorityIdentity = authorityIdentity
        self.installedGrant = grant
        self.runID = grant.runID
        self.grantDigest = RunAuthorizationController.grantDigest(for: grant)
    }
}

/// An immutable, one-use host approval. The request bytes are captured at proposal time.
public struct ApprovedAction: Sendable {
    public let actionID: UUID
    fileprivate let handleToken: UUID
    fileprivate let nonce: UUID
    fileprivate let request: Data
    fileprivate let binding: ActionBinding

    fileprivate init(actionID: UUID, handleToken: UUID, nonce: UUID, request: Data, binding: ActionBinding) {
        self.actionID = actionID
        self.handleToken = handleToken
        self.nonce = nonce
        self.request = request
        self.binding = binding
    }
}

/// An immutable dispatch intent. Its initializer is inaccessible to callers.
public struct DispatchTicket: Sendable {
    public let ticketID: UUID
    public let actionID: UUID
    public let approvedRequest: Data
    fileprivate let handleToken: UUID

    fileprivate init(ticketID: UUID, actionID: UUID, approvedRequest: Data, handleToken: UUID) {
        self.ticketID = ticketID
        self.actionID = actionID
        self.approvedRequest = approvedRequest
        self.handleToken = handleToken
    }
}

public protocol SynchronousAuditSink: Sendable {
    func append(_ event: SecurityEvent) throws
}

public enum JSONLAuditSinkError: Error, Equatable, Sendable {
    case openFailed(Int32)
    case writeFailed(Int32)
    case synchronizeFailed(Int32)
}

/// A synchronous append-only JSONL sink. The target must be a new regular file.
public final class JSONLAuditSink: SynchronousAuditSink, @unchecked Sendable {
    private let fileHandle: FileHandle
    private let lock = NSLock()

    public init(newFileAt url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_APPEND | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw JSONLAuditSinkError.openFailed(errno) }
        self.fileHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    deinit {
        try? fileHandle.close()
    }

    public func append(_ event: SecurityEvent) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload: Data
        do {
            payload = try encoder.encode(event) + Data([0x0A])
        } catch {
            throw JSONLAuditSinkError.writeFailed(EINVAL)
        }

        lock.lock()
        defer { lock.unlock() }
        do {
            try fileHandle.write(contentsOf: payload)
        } catch {
            throw JSONLAuditSinkError.writeFailed(errno)
        }
        do {
            try fileHandle.synchronize()
        } catch {
            throw JSONLAuditSinkError.synchronizeFailed(errno)
        }
    }
}

/// Host-only authorization lifecycle. A guest payload never creates or authenticates a handle.
public actor RunAuthorizationController {
    private nonisolated let attachmentIdentity = UUID()

    /// Immutable provenance only: no liveness check, clock sample, execution or
    /// delivery permission. Intake still must call validateAttachment afterward.
    package nonisolated func installedGrantForOwnership(of handle: HostRunHandle) throws -> RunGrant {
        guard handle.authorityIdentity == attachmentIdentity else { throw AuthorizationError.invalidHandle }
        return handle.installedGrant
    }

    private final class RunState: @unchecked Sendable {
        let grant: RunGrant
        let grantDigest: String
        let handle: HostRunHandle
        var epoch: UInt64 { handle.lifecycle.currentGeneration }
        var revoked: Bool { handle.lifecycle.currentStatus != .active }
        var pending: [UUID: PendingRecord] = [:]
        var tickets: [UUID: DispatchRecord] = [:]
        // Tombstones preserve recent error detail, not permission. Unknown IDs fail closed.
        var terminalActions: [UUID: AuthorizationError] = [:]
        var terminalActionOrder: [UUID] = []
        var completedTickets: [UUID] = []
        var connections: [UUID: LiveConnection]

        init(grant: RunGrant, grantDigest: String, handle: HostRunHandle) {
            self.grant = grant
            self.grantDigest = grantDigest
            self.handle = handle
            self.connections = Dictionary(
                uniqueKeysWithValues: grant.connections.map {
                    (
                        $0.connectionID,
                        LiveConnection(accountBindingVersion: $0.accountBindingVersion, routeVersion: $0.routeVersion)
                    )
                })
        }
    }

    private final class PendingRecord: @unchecked Sendable {
        let action: PendingAction
        var status: PendingStatus = .pending

        init(action: PendingAction) {
            self.action = action
        }
    }

    private struct LiveConnection: Sendable {
        let accountBindingVersion: UInt64
        let routeVersion: UInt64
        var revoked = false
    }

    private enum PendingStatus: Sendable {
        case pending
        case approved
    }

    private struct DispatchRecord: Sendable {
        let actionID: UUID
        let operation: String
        let resourceSummary: String
        var ownership: (owner: any HostRunAttachmentOwner, registration: UUID)? = nil
    }

    private static let activeLimit = 32
    private static let historyLimit = 64

    private let auditSink: any SynchronousAuditSink
    private let clock: RunClock
    private func now() -> Date { clock.now() }
    private var runs: [UUID: RunState] = [:]

    public init(auditSink: any SynchronousAuditSink, clock: RunClock = .system()) {
        self.auditSink = auditSink
        self.clock = clock
    }

    // Do not hash RunGrant's Codable Set representations: their array order is unspecified.
    // Keep this DTO exhaustive when the foundation grant contract gains fields.
    private struct CanonicalGrant: Encodable {
        let runID: UUID
        let epoch: UInt64
        let createdAt: Date
        let expiresAt: Date
        let workloadImageDigest: String
        let agentAdapterVersion: String
        let workspaceSnapshotID: UUID
        let policyDigest: String
        let approvalSnapshotID: UUID
        let connections: [CanonicalConnection]
        let explicitDenies: [ResourceScope]
        let resourceLimits: ResourceLimits

        init(_ grant: RunGrant) {
            runID = grant.runID
            epoch = grant.epoch
            createdAt = grant.createdAt
            expiresAt = grant.expiresAt
            workloadImageDigest = grant.workloadImageDigest
            agentAdapterVersion = grant.agentAdapterVersion
            workspaceSnapshotID = grant.workspaceSnapshotID
            policyDigest = grant.policyDigest
            approvalSnapshotID = grant.approvalSnapshotID
            connections = grant.connections.sorted { $0.connectionID.uuidString < $1.connectionID.uuidString }.map(
                CanonicalConnection.init)
            explicitDenies = grant.explicitDenies.sorted(by: Self.scopeOrder)
            resourceLimits = grant.resourceLimits
        }

        static func scopeOrder(_ lhs: ResourceScope, _ rhs: ResourceScope) -> Bool {
            (lhs.service, lhs.resource, lhs.operation) < (rhs.service, rhs.resource, rhs.operation)
        }
    }

    private struct CanonicalConnection: Encodable {
        let connectionID: UUID
        let accountBindingVersion: UInt64
        let routeVersion: UInt64
        let scopes: [ResourceScope]

        init(_ connection: ConnectionGrant) {
            connectionID = connection.connectionID
            accountBindingVersion = connection.accountBindingVersion
            routeVersion = connection.routeVersion
            scopes = connection.scopes.sorted(by: CanonicalGrant.scopeOrder)
        }
    }

    public static func grantDigest(for grant: RunGrant) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(CanonicalGrant(grant)) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    #if DEBUG || SANDBOX_TEST_FIXTURES
        /// Scheduling fixture before authority acquisition; no lifecycle, operation
        /// or receiver lock is held. Never supplies clock data or effect permission.
        package func withPreAcquisitionBarrier(_ barrier: @Sendable () -> Void) { barrier() }
    #endif

    public func install(grant: RunGrant) throws -> HostRunHandle {
        let installed = clock.sample()
        let current = installed.wall
        guard current >= grant.createdAt else { throw AuthorizationError.grantNotYetValid }
        guard current < grant.expiresAt else { throw AuthorizationError.grantExpired }
        guard runs[grant.runID] == nil else { throw AuthorizationError.duplicateRun }

        let handle = HostRunHandle(
            token: UUID(),
            lifecycle: RunLifecycle(
                expiresAt: grant.expiresAt, epoch: grant.epoch, installedAt: current, clock: clock,
                installedElapsed: installed.elapsed), grant: grant, authorityIdentity: attachmentIdentity)
        let state = RunState(grant: grant, grantDigest: Self.grantDigest(for: grant), handle: handle)
        runs[grant.runID] = state
        return handle
    }

    public func validateAttachment(handle: HostRunHandle, grant: RunGrant) throws {
        let state = try state(for: handle)
        guard state.grantDigest == Self.grantDigest(for: grant) else { throw AuthorizationError.grantBindingMismatch }
        try ensureLive(state)
    }

    public func propose(handle: HostRunHandle, binding: ActionBinding, display: String) throws -> PendingAction {
        let state = try state(for: handle)
        try ensureLive(state)
        let observation = state.handle.lifecycle.observeAndReduce(reason: "authorization")
        let current = observation.effectiveTime
        try ensureGrantTime(state, observation: observation)
        cleanupExpired(state, at: current)
        guard state.pending.count < Self.activeLimit else { throw AuthorizationError.pendingLimit }

        guard binding.runID == state.grant.runID else {
            try reject(state, binding: binding, reason: "wrong-run")
            throw AuthorizationError.wrongRun
        }
        guard binding.epoch == state.epoch else {
            try reject(state, binding: binding, reason: "wrong-epoch")
            throw AuthorizationError.wrongEpoch
        }
        guard binding.grantDigest == state.grantDigest else {
            try reject(state, binding: binding, reason: "grant-binding-mismatch")
            throw AuthorizationError.grantBindingMismatch
        }
        guard let connection = state.grant.connections.first(where: { $0.connectionID == binding.connectionID }) else {
            try reject(state, binding: binding, reason: "connection-not-granted")
            throw AuthorizationError.connectionNotGranted
        }
        try ensureConnection(state, connection: connection)
        guard let scope = matchingScope(for: binding, in: state.grant) else {
            try reject(state, binding: binding, reason: "resource-not-granted")
            throw AuthorizationError.resourceNotGranted
        }
        if state.grant.explicitDenies.contains(scope) {
            try reject(state, binding: binding, reason: "explicit-deny")
            throw AuthorizationError.resourceNotGranted
        }
        guard state.grant.decision(for: scope, connectionID: binding.connectionID, at: current) == .allowed else {
            try reject(state, binding: binding, reason: "scope-denied")
            throw AuthorizationError.resourceNotGranted
        }

        let expiry = min(state.grant.expiresAt, current.addingTimeInterval(300))
        let action = try PendingAction(
            binding: binding, safeDisplaySnapshot: display, createdAt: current, expiresAt: expiry)
        state.pending[action.actionID] = PendingRecord(action: action)
        return action
    }

    public func hostApprove(handle: HostRunHandle, actionID: UUID, nonce: UUID) throws -> ApprovedAction {
        let state = try state(for: handle)
        try ensureLive(state)
        let observation = state.handle.lifecycle.observeAndReduce(reason: "authorization")
        let current = observation.effectiveTime
        try ensureGrantTime(state, observation: observation)
        cleanupExpired(state, at: current)
        guard let record = state.pending[actionID] else {
            let error = state.terminalActions[actionID] ?? .actionNotPending
            throw error == .ticketAlreadyConsumed ? AuthorizationError.actionNotPending : error
        }
        guard record.action.nonce == nonce else { throw AuthorizationError.approvalMismatch }
        guard record.status == .pending else { throw AuthorizationError.actionNotPending }
        guard
            let connection = state.grant.connections.first(where: {
                $0.connectionID == record.action.binding.connectionID
            })
        else {
            throw AuthorizationError.connectionNotGranted
        }
        try ensureConnection(state, connection: connection)
        record.status = .approved
        return ApprovedAction(
            actionID: actionID, handleToken: handle.token, nonce: nonce,
            request: record.action.binding.canonicalRequest, binding: record.action.binding)
    }

    public func deny(handle: HostRunHandle, actionID: UUID) throws {
        let state = try state(for: handle)
        try ensureLive(state)
        guard let record = state.pending[actionID] else { throw AuthorizationError.actionNotPending }
        guard record.status == .pending else { throw AuthorizationError.actionNotPending }
        retireAction(state, actionID: actionID, reason: .actionDenied)
        do {
            try append(
                event: try hostEvent(
                    state: state, actionID: actionID, operation: record.action.binding.operation,
                    resourceSummary: record.action.binding.resolvedResource, decision: .deny, reason: "explicit-deny",
                    outcome: .notDispatched))
        } catch {
            state.handle.lifecycle.terminate(.faulted)
            revoke(state)
            throw AuthorizationError.auditFailed
        }
    }

    public func consume(handle: HostRunHandle, approved: ApprovedAction) throws -> DispatchTicket {
        let state = try state(for: handle)
        try ensureLive(state)
        guard approved.handleToken == handle.token else { throw AuthorizationError.invalidHandle }
        let observation = state.handle.lifecycle.observeAndReduce(reason: "authorization")
        let current = observation.effectiveTime
        try ensureGrantTime(state, observation: observation)
        cleanupExpired(state, at: current)
        guard let record = state.pending[approved.actionID] else {
            throw state.terminalActions[approved.actionID] ?? AuthorizationError.ticketInvalid
        }
        guard record.status == .approved else { throw AuthorizationError.approvalMismatch }
        guard record.action.nonce == approved.nonce,
            record.action.binding == approved.binding,
            record.action.binding.canonicalRequest == approved.request
        else {
            throw AuthorizationError.approvalMismatch
        }
        guard
            let connection = state.grant.connections.first(where: {
                $0.connectionID == record.action.binding.connectionID
            })
        else {
            throw AuthorizationError.connectionNotGranted
        }
        try ensureConnection(state, connection: connection)
        guard let scope = matchingScope(for: record.action.binding, in: state.grant),
            !state.grant.explicitDenies.contains(scope),
            state.grant.decision(for: scope, connectionID: record.action.binding.connectionID, at: current) == .allowed
        else {
            throw AuthorizationError.resourceNotGranted
        }

        // Never evict issued, unfinished tickets: apply recoverable backpressure instead.
        guard state.tickets.count < Self.activeLimit else { throw AuthorizationError.pendingLimit }
        let ticket = DispatchTicket(
            ticketID: UUID(), actionID: approved.actionID, approvedRequest: approved.request, handleToken: handle.token)
        retireAction(state, actionID: approved.actionID, reason: .ticketAlreadyConsumed)
        do {
            try append(
                event: try hostEvent(
                    state: state, actionID: approved.actionID, operation: approved.binding.operation,
                    resourceSummary: approved.binding.resolvedResource, decision: .allow, reason: "dispatch-intent",
                    outcome: .notDispatched))
        } catch {
            state.handle.lifecycle.terminate(.faulted)
            revoke(state)
            throw AuthorizationError.auditFailed
        }
        // A ticket is result-bookkeeping, not permission at the effect entrance.
        state.tickets[ticket.ticketID] = DispatchRecord(
            actionID: approved.actionID, operation: approved.binding.operation,
            resourceSummary: approved.binding.resolvedResource)
        return ticket
    }

    /// Attach only outcome bookkeeping to the issued ticket, with no suspension
    /// between issuance and registration. This grants no start/output authority.
    package func consumeOwned(
        handle: HostRunHandle, approved: ApprovedAction,
        owner: any HostRunAttachmentOwner, registration: UUID
    ) throws -> DispatchTicket {
        let ticket = try consume(handle: handle, approved: approved)
        let state = try state(for: handle)
        state.tickets[ticket.ticketID]?.ownership = (owner, registration)
        return ticket
    }

    public func complete(handle: HostRunHandle, ticket: DispatchTicket, outcome: DispatchOutcome) throws {
        let state = try state(for: handle)
        guard ticket.handleToken == handle.token else { throw AuthorizationError.ticketInvalid }
        guard let record = state.tickets[ticket.ticketID] else {
            throw state.completedTickets.contains(ticket.ticketID)
                ? AuthorizationError.completionAlreadyRecorded : .ticketInvalid
        }
        guard ticket.actionID == record.actionID else { throw AuthorizationError.ticketInvalid }
        guard outcome == .completed || outcome == .failed || outcome == .unknown else {
            throw AuthorizationError.completionAlreadyRecorded
        }
        // Invalid/replayed attempts cannot release an unfinished reservation.
        // The actual ticket, not a caller's UI projection, owns this retirement.
        defer {
            if let ownership = record.ownership { ownership.owner.endAttachment(ownership.registration) }
        }
        state.tickets.removeValue(forKey: ticket.ticketID)
        state.completedTickets.append(ticket.ticketID)
        if state.completedTickets.count > Self.historyLimit { state.completedTickets.removeFirst() }
        do {
            try append(
                event: try hostEvent(
                    state: state, actionID: record.actionID, operation: record.operation,
                    resourceSummary: record.resourceSummary, decision: .allow, reason: "dispatch-completion",
                    outcome: outcome))
        } catch {
            if let ownership = record.ownership { ownership.owner.attachmentCleanupFailed(ownership.registration) }
            state.handle.lifecycle.terminate(.faulted)
            revoke(state)
            throw AuthorizationError.auditFailed
        }
    }

    public func stop(handle: HostRunHandle) throws {
        let state = try state(for: handle)
        state.handle.lifecycle.terminate(.stopped)
        revoke(state)
    }

    public func close(handle: HostRunHandle) throws {
        try stop(handle: handle)
    }

    public func revokeConnection(handle: HostRunHandle, connectionID: UUID) throws {
        let state = try state(for: handle)
        try ensureLive(state)
        guard var connection = state.connections[connectionID] else { throw AuthorizationError.connectionNotGranted }
        state.handle.lifecycle.invalidateConnection(connectionID)
        connection.revoked = true
        state.connections[connectionID] = connection
        invalidateActions(state, connectionID: connectionID, reason: .connectionRevoked)
    }

    public func updateConnection(
        handle: HostRunHandle, connectionID: UUID, accountBindingVersion: UInt64, routeVersion: UInt64
    ) throws {
        let state = try state(for: handle)
        try ensureLive(state)
        guard let connection = state.connections[connectionID] else { throw AuthorizationError.connectionNotGranted }
        guard !connection.revoked else { throw AuthorizationError.connectionRevoked }
        guard accountBindingVersion >= connection.accountBindingVersion,
            routeVersion >= connection.routeVersion
        else { throw AuthorizationError.connectionVersionMismatch }
        if accountBindingVersion != connection.accountBindingVersion || routeVersion != connection.routeVersion {
            state.handle.lifecycle.invalidateConnection(connectionID)
            invalidateActions(state, connectionID: connectionID, reason: .connectionVersionMismatch)
        }
        state.connections[connectionID] = LiveConnection(
            accountBindingVersion: accountBindingVersion, routeVersion: routeVersion)
    }

    /// Guest ingress has no origin parameter and cannot authenticate a control handle.
    public func recordGuestDiagnostic(runID: UUID, operation: String, resourceSummary: String, message: String) throws {
        let digest = runs[runID]?.grantDigest ?? String(repeating: "0", count: 64)
        let observation = runs[runID]?.handle.lifecycle.observeAndReduce(reason: "guest-diagnostic")
        let event = try SecurityEvent(
            eventID: UUID(), hostSequence: observation?.sequence ?? nextSequence(), runID: runID, actionID: nil,
            time: observation?.effectiveTime ?? now(), origin: .guestDiagnostic, operation: operation,
            resourceSummary: resourceSummary, decision: .observe, reason: message, grantDigest: digest,
            outcome: .notDispatched)
        do {
            try append(event: event)
        } catch {
            if let state = runs[runID] {
                state.handle.lifecycle.terminate(.faulted)
                revoke(state)
            }
            throw AuthorizationError.auditFailed
        }
    }

    private var sequence: UInt64 = 0

    private func nextSequence() -> UInt64 {
        sequence &+= 1
        return sequence
    }

    private func append(event: SecurityEvent) throws {
        try auditSink.append(event)
    }

    private func state(for handle: HostRunHandle) throws -> RunState {
        guard let state = runs.values.first(where: { $0.handle === handle && $0.handle.token == handle.token }) else {
            throw AuthorizationError.invalidHandle
        }
        return state
    }

    private func ensureLive(_ state: RunState) throws {
        guard !state.revoked else { throw AuthorizationError.runRevoked }
    }

    private func ensureGrantTime(_ state: RunState, observation: RunObservation) throws {
        guard observation.status == .active else {
            revoke(state)
            throw observation.status == .expired ? AuthorizationError.grantExpired : .runRevoked
        }
        guard observation.wallTime >= state.grant.createdAt else { throw AuthorizationError.grantNotYetValid }
    }

    private func ensureConnection(_ state: RunState, connection: ConnectionGrant) throws {
        guard let live = state.connections[connection.connectionID] else {
            throw AuthorizationError.connectionNotGranted
        }
        guard !live.revoked else { throw AuthorizationError.connectionRevoked }
        guard live.accountBindingVersion == connection.accountBindingVersion,
            live.routeVersion == connection.routeVersion
        else { throw AuthorizationError.connectionVersionMismatch }
    }

    private func retireAction(_ state: RunState, actionID: UUID, reason: AuthorizationError) {
        guard state.pending.removeValue(forKey: actionID) != nil else { return }
        state.terminalActions[actionID] = reason
        state.terminalActionOrder.append(actionID)
        if state.terminalActionOrder.count > Self.historyLimit {
            state.terminalActions.removeValue(forKey: state.terminalActionOrder.removeFirst())
        }
    }

    private func cleanupExpired(_ state: RunState, at current: Date) {
        let expired = state.pending.values.filter { current >= $0.action.expiresAt }.map { $0.action.actionID }
        for actionID in expired { retireAction(state, actionID: actionID, reason: .actionExpired) }
    }

    private func invalidateActions(_ state: RunState, connectionID: UUID, reason: AuthorizationError) {
        let invalidated = state.pending.values.filter { $0.action.binding.connectionID == connectionID }.map {
            $0.action.actionID
        }
        for actionID in invalidated { retireAction(state, actionID: actionID, reason: reason) }
    }

    private func revoke(_ state: RunState) {
        state.handle.lifecycle.terminate(.revoked)
        for actionID in Array(state.pending.keys) {
            retireAction(state, actionID: actionID, reason: .runRevoked)
        }
    }

    private func matchingScope(for binding: ActionBinding, in grant: RunGrant) -> ResourceScope? {
        let candidates =
            grant.connections
            .first(where: { $0.connectionID == binding.connectionID })?.scopes
            .filter { $0.resource == binding.resolvedResource && $0.operation == binding.operation } ?? []
        guard candidates.count == 1 else { return nil }
        return candidates[0]
    }

    private func hostEvent(
        state: RunState, actionID: UUID, operation: String, resourceSummary: String, decision: EventDecision,
        reason: String, outcome: DispatchOutcome
    ) throws -> SecurityEvent {
        let observation = state.handle.lifecycle.observeAndReduce(reason: reason)
        return try SecurityEvent(
            eventID: UUID(), hostSequence: observation.sequence, runID: state.grant.runID, actionID: actionID,
            time: observation.effectiveTime, origin: .hostEnforcement, operation: operation,
            resourceSummary: resourceSummary, decision: decision, reason: reason, grantDigest: state.grantDigest,
            outcome: outcome)
    }

    private func reject(_ state: RunState, binding: ActionBinding, reason: String) throws {
        let observation = state.handle.lifecycle.observeAndReduce(reason: reason)
        do {
            try append(
                event: try SecurityEvent(
                    eventID: UUID(), hostSequence: observation.sequence, runID: state.grant.runID, actionID: nil,
                    time: observation.effectiveTime, origin: .hostEnforcement, operation: binding.operation,
                    resourceSummary: binding.resolvedResource, decision: .deny, reason: reason,
                    grantDigest: state.grantDigest, outcome: .notDispatched))
        } catch {
            state.handle.lifecycle.terminate(.faulted)
            revoke(state)
            throw AuthorizationError.auditFailed
        }
    }
}
