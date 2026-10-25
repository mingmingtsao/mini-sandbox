import Combine
import Darwin
import Foundation
import SandboxContracts
import SandboxHost

/// Disk is authoritative: only synchronized writes enter the bounded activity cache.
public final class WorkbenchAuditSink: SynchronousAuditSink, @unchecked Sendable {
    private let file: FileHandle
    private let lock = NSLock()
    private var events: [SecurityEvent] = []
    private var failed = false
    private let capacity: Int
    public let url: URL

    public init(newFileAt url: URL, capacity: Int = 200) throws {
        self.url = url
        self.capacity = max(1, capacity)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_APPEND | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw JSONLAuditSinkError.openFailed(errno) }
        file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        // A real lifecycle write, not a synthetic run or SecurityEvent.
        let startup = try JSONSerialization.data(
            withJSONObject: ["type": "workbenchStarted", "time": Date().timeIntervalSince1970], options: [.sortedKeys])
        try file.write(contentsOf: startup + Data([10]))
        try file.synchronize()
    }

    public func append(_ event: SecurityEvent) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !failed else { throw AuthorizationError.auditFailed }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            try file.write(contentsOf: encoder.encode(event) + Data([10]))
            try file.synchronize()
            events.append(event)
            if events.count > capacity { events.removeFirst(events.count - capacity) }
        } catch {
            failed = true
            throw error
        }
    }

    public func snapshot() -> [SecurityEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

/// Presentation state only; permission and terminal state remain in the model's authority.
@MainActor public final class WorkbenchApprovalController: ObservableObject {
    public struct Presentation: Identifiable {
        public let action: PendingAction
        public var id: UUID { action.actionID }
    }
    @Published public var presentation: Presentation?
    private var lastPresented: PendingAction?
    private let model: WorkbenchModel
    public init(model: WorkbenchModel) { self.model = model }
    public var ordinaryControlsDisabled: Bool { model.isBusy || model.isClosing || !model.authorityAvailable }
    public func present(_ action: PendingAction) {
        guard lastPresented == nil, !ordinaryControlsDisabled,
            model.pending.contains(where: { $0.actionID == action.actionID })
        else { return }
        lastPresented = action
        presentation = Presentation(action: action)
    }
    private func clear(_ action: PendingAction) {
        if presentation?.id == action.actionID { presentation = nil }
    }
    public func reconcile() {
        if let action = presentation?.action, !model.pending.contains(where: { $0.actionID == action.actionID }) {
            clear(action)
        }
    }
    public func dismiss(_ action: PendingAction) async {
        await model.dismiss(action)
        clear(action)
    }
    public func didDismiss() async {
        let action = lastPresented
        lastPresented = nil
        if let action { await model.dismiss(action) }
    }
    public func approve(_ action: PendingAction) async throws {
        defer { clear(action) }
        _ = try await model.approveOnce(action)
    }
    public func stop(runID: UUID) async throws {
        // Remove the modal immediately; model.stop establishes the shared terminal
        // before waiting for the in-flight denial's audit. Dismissal remains deny-only.
        if let action = presentation?.action, action.binding.runID == runID { clear(action) }
        try await model.stop(runID: runID)
    }
}

@MainActor public final class WorkbenchModel: ObservableObject {
    @Published public private(set) var grants: [RunGrant] = []
    @Published public private(set) var pending: [PendingAction] = []
    @Published public private(set) var approvedActions: [UUID: ApprovedAction] = [:]
    @Published public private(set) var authorityAvailable = false
    @Published public private(set) var errorMessage: String?
    public let auditURL: URL
    private var audit: WorkbenchAuditSink?
    private var controller: RunAuthorizationController?
    private var handles: [UUID: HostRunHandle] = [:]
    private var approvedSnapshots: [UUID: PendingAction] = [:]

    @Published public private(set) var activity: [SecurityEvent] = []
    @Published public private(set) var runStatus: [UUID: String] = [:]
    @Published public private(set) var isBusy = false
    @Published public private(set) var isClosing = false
    @Published public private(set) var isClosed = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var closeTask: Task<Bool, Never>?
    package var attachmentOwner: (any HostRunAttachmentOwner)?
    package var willClose: (() -> Void)?
    package var closeOwnedRuns: (() async -> Bool)?
    public var trustedDenialCount: Int { activity.filter(\.isHostRejection).count }

    public static func applicationModel() -> WorkbenchModel {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MiniSandbox/Audit", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            let model = WorkbenchModel(newAuditFileAt: directory.appendingPathComponent("unavailable/\(UUID()).jsonl"))
            model.errorMessage = "Audit directory unavailable; authority disabled: \(error)"
            return model
        }
        return WorkbenchModel(newAuditFileAt: directory.appendingPathComponent("\(UUID()).jsonl"))
    }

    private func begin() throws -> RunAuthorizationController {
        guard !isClosing else { throw AuthorizationError.runRevoked }
        guard authorityAvailable, let controller else { throw AuthorizationError.auditFailed }
        guard !isBusy else { throw WorkbenchError.busy }
        isBusy = true
        return controller
    }
    private func finish() {
        activity = audit?.snapshot() ?? []
        isBusy = false
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
    private func waitForIdle() async {
        while isBusy { await withCheckedContinuation { idleWaiters.append($0) } }
    }
    private func handle(_ runID: UUID) throws -> HostRunHandle {
        guard let handle = handles[runID] else { throw AuthorizationError.invalidHandle }
        return handle
    }
    private func clearRun(_ runID: UUID, status: String) {
        pending.removeAll { $0.binding.runID == runID }
        for (id, action) in approvedSnapshots where action.binding.runID == runID {
            approvedActions.removeValue(forKey: id)
            approvedSnapshots.removeValue(forKey: id)
        }
        runStatus[runID] = status
    }
    private func failed(_ error: Error, runID: UUID?) async {
        errorMessage = String(describing: error)
        if error as? AuthorizationError == .auditFailed {
            authorityAvailable = false
            for handle in handles.values { handle.lifecycle.terminate(.faulted) }
            for (id, handle) in handles {
                try? await controller?.stop(handle: handle)
                clearRun(id, status: "Revoked — audit unavailable")
            }
        } else if let runID, let failure = error as? AuthorizationError,
            [.runRevoked, .grantExpired].contains(failure)
        {
            clearRun(runID, status: "Revoked / expired")
        }
    }

    /// Trusted in-process ingress only. Never expose this as a guest JSON handler.
    public func installTrustedGrant(_ grant: RunGrant, authorityHandle existing: HostRunHandle? = nil) async throws {
        let controller = try begin()
        defer { finish() }
        let registration = try attachmentOwner?.beginAttachment(grant: grant, existing: existing)
        defer { if let registration { attachmentOwner?.endAttachment(registration) } }
        do {
            let handle: HostRunHandle
            if let existing {
                try await controller.validateAttachment(handle: existing, grant: grant)
                handle = existing
            } else {
                handle = try await controller.install(grant: grant)
            }
            if let registration { try attachmentOwner?.registerAttachment(registration, grant: grant, handle: handle) }
            guard !isClosing, handle.lifecycle.currentStatus == .active else {
                handle.lifecycle.terminate(.stopped)
                try? await controller.stop(handle: handle)
                throw AuthorizationError.runRevoked
            }
            handles[grant.runID] = handle
            if !grants.contains(where: { $0.runID == grant.runID }) { grants.append(grant) }
            runStatus[grant.runID] = "Authorized — runtime not connected"
        } catch {
            await failed(error, runID: grant.runID)
            throw error
        }
    }
    public func proposeTrustedAction(binding: ActionBinding, display: String) async throws -> PendingAction {
        let controller = try begin()
        defer { finish() }
        do {
            let handle = try handle(binding.runID)
            let action = try await controller.propose(handle: handle, binding: binding, display: display)
            guard !isClosing, handle.lifecycle.currentStatus == .active else { throw AuthorizationError.runRevoked }
            pending.append(action)
            return action
        } catch {
            await failed(error, runID: binding.runID)
            throw error
        }
    }
    public func approveOnce(_ action: PendingAction) async throws -> ApprovedAction {
        let controller = try begin()
        defer { finish() }
        do {
            let handle = try handle(action.binding.runID)
            let approved = try await controller.hostApprove(
                handle: handle, actionID: action.actionID, nonce: action.nonce)
            guard !isClosing, handle.lifecycle.currentStatus == .active else { throw AuthorizationError.runRevoked }
            pending.removeAll { $0.actionID == action.actionID }
            approvedActions[action.actionID] = approved
            approvedSnapshots[action.actionID] = action
            return approved
        } catch {
            pending.removeAll { $0.actionID == action.actionID }
            await failed(error, runID: action.binding.runID)
            throw error
        }
    }
    public func deny(_ action: PendingAction) async throws {
        let controller = try begin()
        defer { finish() }
        do { try await controller.deny(handle: handle(action.binding.runID), actionID: action.actionID) } catch {
            if error as? AuthorizationError == .actionNotPending {
                // F03 confirms only that this is no longer pending, not that an
                // existing approval was revoked. Reconcile the proposal alone.
                pending.removeAll { $0.actionID == action.actionID }
            } else {
                await failed(error, runID: action.binding.runID)
            }
            throw error
        }
        pending.removeAll { $0.actionID == action.actionID }
    }
    public func dismiss(_ action: PendingAction) async {
        await waitForIdle()
        guard pending.contains(where: { $0.actionID == action.actionID }) else { return }
        do { try await deny(action) } catch AuthorizationError.actionNotPending { /* Already reconciled by deny. */
        } catch { errorMessage = String(describing: error) }
    }
    /// Called by a trusted broker, never by the view. Does not perform external I/O.
    public func consumeForTrustedHost(runID: UUID, approved: ApprovedAction) async throws -> DispatchTicket {
        let controller = try begin()
        defer { finish() }
        let authorityHandle = try handle(runID)
        let installed = try controller.installedGrantForOwnership(of: authorityHandle)
        let registration = try attachmentOwner?.beginAttachment(grant: installed, existing: authorityHandle)
        var transferred = false
        defer { if !transferred, let registration { attachmentOwner?.endAttachment(registration) } }
        do {
            let ticket: DispatchTicket
            if let registration, let attachmentOwner {
                ticket = try await controller.consumeOwned(
                    handle: authorityHandle, approved: approved,
                    owner: attachmentOwner, registration: registration)
                transferred = true
            } else {
                ticket = try await controller.consume(handle: authorityHandle, approved: approved)
            }
            approvedActions.removeValue(forKey: approved.actionID)
            approvedSnapshots.removeValue(forKey: approved.actionID)
            return ticket
        } catch {
            if let failure = error as? AuthorizationError,
                [
                    .actionExpired, .connectionRevoked, .connectionVersionMismatch, .ticketAlreadyConsumed,
                    .ticketInvalid,
                ].contains(failure)
            {
                approvedActions.removeValue(forKey: approved.actionID)
                approvedSnapshots.removeValue(forKey: approved.actionID)
            }
            await failed(error, runID: runID)
            throw error
        }
    }
    public func completeForTrustedHost(runID: UUID, ticket: DispatchTicket, outcome: DispatchOutcome) async throws {
        await waitForIdle()
        guard let controller else { throw AuthorizationError.auditFailed }
        isBusy = true
        defer { finish() }
        do {
            try await controller.complete(handle: handle(runID), ticket: ticket, outcome: outcome)
        } catch {
            await failed(error, runID: runID)
            throw error
        }
    }
    public func recordGuestDiagnostic(runID: UUID, operation: String, resource: String, message: String) async throws {
        let controller = try begin()
        defer { finish() }
        do {
            try await controller.recordGuestDiagnostic(
                runID: runID, operation: operation, resourceSummary: resource, message: message)
        } catch {
            await failed(error, runID: runID)
            throw error
        }
    }
    /// Retire shared authority before credential I/O, without waiting on audit.
    package func retireModelConnections(_ connectionIDs: Set<UUID>) {
        for grant in grants where grant.connections.contains(where: { connectionIDs.contains($0.connectionID) }) {
            handles[grant.runID]?.lifecycle.terminate(.stopped)
            clearRun(grant.runID, status: "Stopped — model configuration changed; new grant required")
        }
    }
    package func retireMCPConnections(_ connectionIDs: Set<UUID>) {
        for grant in grants where grant.connections.contains(where: { connectionIDs.contains($0.connectionID) }) {
            handles[grant.runID]?.lifecycle.terminate(.stopped)
            clearRun(grant.runID, status: "Stopped — MCP configuration changed; new grant required")
        }
    }

    /// Stop is an interrupt, not ordinary approval work: busy must not hide it.
    /// Terminal/closing runs need no further UI intent; cleanup remains idempotent.
    public func canStop(runID: UUID) -> Bool {
        guard authorityAvailable, !isClosing, !isClosed, let handle = handles[runID] else { return false }
        return handle.lifecycle.currentStatus == .active
    }
    public func stop(runID: UUID) async throws {
        // Synchronous shared terminal before waiting for UI work or F03 audit.
        try handle(runID).lifecycle.terminate(.stopped)
        clearRun(runID, status: "Stopped — authorization revoked")
        await waitForIdle()
        guard let controller else { throw AuthorizationError.auditFailed }
        isBusy = true
        defer { finish() }
        do {
            try await controller.stop(handle: handle(runID))
            clearRun(runID, status: "Stopped — authorization revoked")
        } catch {
            await failed(error, runID: runID)
            throw error
        }
    }
    public func revokeConnection(runID: UUID, connectionID: UUID) async throws {
        let controller = try begin()
        defer { finish() }
        do {
            try await controller.revokeConnection(handle: handle(runID), connectionID: connectionID)
            pending.removeAll { $0.binding.runID == runID && $0.binding.connectionID == connectionID }
            for (id, action) in approvedSnapshots
            where action.binding.runID == runID && action.binding.connectionID == connectionID {
                approvedActions.removeValue(forKey: id)
                approvedSnapshots.removeValue(forKey: id)
            }
            runStatus[runID] = "Connection revoked: \(connectionID)"
        } catch {
            await failed(error, runID: runID)
            throw error
        }
    }
    public func expirePending() async {
        guard !isClosing else { return }
        for grant in grants {
            guard let handle = handles[grant.runID] else { continue }
            let observation = handle.lifecycle.observeAndReduce(reason: "ui-projection")
            if observation.status != .active {
                clearRun(
                    grant.runID,
                    status: observation.status == .expired ? "Expired — authorization revoked" : "Revoked / expired")
                continue
            }
            if isBusy { continue }
            for action in pending
            where action.binding.runID == grant.runID && observation.effectiveTime >= action.expiresAt {
                await dismiss(action)
            }
            for (id, action) in approvedSnapshots
            where action.binding.runID == grant.runID && observation.effectiveTime >= action.expiresAt {
                approvedActions.removeValue(forKey: id)
                approvedSnapshots.removeValue(forKey: id)
            }
        }
    }
    /// The native close callback calls this before spawning asynchronous cleanup.
    public func beginClose() {
        guard !isClosing else { return }
        isClosing = true
        willClose?()
        for (id, handle) in handles {
            handle.lifecycle.terminate(.stopped)
            clearRun(id, status: "Stopped — authorization revoked")
        }
    }
    /// No termination reply is sent until every owned attachment is revoked.
    public func close() async -> Bool {
        beginClose()
        if let closeTask { return await closeTask.value }
        let task = Task { @MainActor in
            await self.waitForIdle()
            for id in self.handles.keys {
                do { try await self.stop(runID: id) } catch { return false }
            }
            if let closeOwnedRuns = self.closeOwnedRuns, !(await closeOwnedRuns()) { return false }
            self.isClosed = true
            self.authorityAvailable = false
            return true
        }
        closeTask = task
        return await task.value
    }
    public func service(for action: PendingAction) -> String {
        grants.first { $0.runID == action.binding.runID }?.connections
            .first { $0.connectionID == action.binding.connectionID }?.scopes
            .first { $0.resource == action.binding.resolvedResource && $0.operation == action.binding.operation }?
            .service ?? "Unavailable"
    }
    public enum WorkbenchError: Error { case busy }

    public func lifecycle(runID: UUID) throws -> RunLifecycle { try handle(runID).lifecycle }
    public init(unavailable error: String) {
        auditURL = URL(fileURLWithPath: "/dev/null")
        errorMessage = error
    }
    public init(audit: WorkbenchAuditSink, authority: RunAuthorizationController) {
        self.auditURL = audit.url
        self.audit = audit
        self.controller = authority
        self.authorityAvailable = true
    }

    public init(
        newAuditFileAt url: URL, clock: RunClock = .system(),
        authority: RunAuthorizationController? = nil
    ) {
        auditURL = url
        do {
            let sink = try WorkbenchAuditSink(newFileAt: url)
            audit = sink
            controller = authority ?? RunAuthorizationController(auditSink: sink, clock: clock)
            authorityAvailable = true
        } catch { errorMessage = "Audit unavailable; authority disabled: \(error)" }
    }
}
