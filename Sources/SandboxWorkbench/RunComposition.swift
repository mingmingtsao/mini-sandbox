import Foundation
import SandboxContracts
import SandboxHost
import Darwin

/// An ownership ledger, not a second authorization lifecycle. Gateway actors
/// register here synchronously before exposing execution-eligible attachments.
/// No audit, clock, provider or cancellation callback runs under this lock.
private final class CompositionRunOwnership: HostRunAttachmentOwner, @unchecked Sendable {
    private let lock = NSLock()
    private let authority: RunAuthorizationController
    private var sealed = false
    private var cleanupFailed = false
    private var generation = UUID()
    private struct Reservation {
        let generation: UUID
        var handleID: ObjectIdentifier?
    }
    private static let capacity = 32
    private var pending: [UUID: Reservation] = [:]
    private var runs: [ObjectIdentifier: (RunGrant, HostRunHandle)] = [:]
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(authority: RunAuthorizationController) { self.authority = authority }

    func beginAttachment(grant: RunGrant, existing: HostRunHandle?) throws -> UUID {
        // Authenticate provenance without awaiting the actor. Genuine local
        // intake must be close-owned even while attachment validation is pending;
        // neither a foreign handle nor caller-supplied metadata may enter runs.
        let installedGrant = try existing.map { try authority.installedGrantForOwnership(of: $0) }
        return try lock.withLock {
            guard !sealed else { throw AuthorizationError.runRevoked }
            retireSettledLocked()
            guard pending.count < Self.capacity else { throw AuthorizationError.pendingLimit }
            let id = existing.map(ObjectIdentifier.init)
            // Reserve a unique-run slot before authority/object allocation. A
            // second attachment to the same genuine handle shares that slot.
            if id == nil || runs[id!] == nil {
                let unbound = pending.values.filter { $0.handleID == nil }.count
                guard runs.count + unbound < Self.capacity else { throw AuthorizationError.pendingLimit }
            }
            let token = UUID()
            pending[token] = Reservation(generation: generation, handleID: id)
            if let existing, let installedGrant, let id, runs[id] == nil {
                runs[id] = (installedGrant, existing)
            }
            return token
        }
    }
    func registerAttachment(_ token: UUID, grant: RunGrant, handle: HostRunHandle) throws {
        let installedGrant = try authority.installedGrantForOwnership(of: handle)
        let allowed = lock.withLock {
            guard var reservation = pending[token] else { return false }
            let id = ObjectIdentifier(handle)
            guard reservation.handleID == nil || reservation.handleID == id else { return false }
            reservation.handleID = id
            pending[token] = reservation
            runs[id] = (installedGrant, handle)
            return !sealed && reservation.generation == generation
        }
        guard allowed else {
            handle.lifecycle.terminate(.stopped)
            throw AuthorizationError.runRevoked
        }
    }
    // Only our terminal, unreferenced ledger records retire. F03 records,
    // issued tickets and replay protection are never removed here.
    private func retireSettledLocked() {
        let retained = Set(pending.values.compactMap(\.handleID))
        runs = runs.filter { retained.contains($0.key) || $0.value.1.lifecycle.currentStatus == .active }
    }
    func attachmentCleanupFailed(_ token: UUID) {
        lock.withLock { if pending[token] != nil { cleanupFailed = true } }
    }
    var cleanupSucceeded: Bool { lock.withLock { !cleanupFailed } }
    func endAttachment(_ token: UUID) {
        let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            pending.removeValue(forKey: token)
            guard pending.isEmpty else { return [] }
            let result = waiters; waiters.removeAll(); return result
        }
        ready.forEach { $0.resume() }
    }
    func seal() {
        let handles = lock.withLock { () -> [HostRunHandle] in
            sealed = true
            return runs.values.map { $0.1 }
        }
        handles.forEach { $0.lifecycle.terminate(.stopped) }
    }
    func retire(_ connections: Set<UUID>) {
        let handles = lock.withLock {
            generation = UUID()
            return runs.values.filter { grant, _ in
                grant.connections.contains { connections.contains($0.connectionID) }
            }.map { $0.1 }
        }
        handles.forEach { $0.lifecycle.terminate(.stopped) }
    }
    func drainAttachments() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                if pending.isEmpty { return true }
                waiters.append(continuation); return false
            }
            if ready { continuation.resume() }
        }
    }
    var handles: [HostRunHandle] { lock.withLock { runs.values.map { $0.1 } } }
#if DEBUG
    var pendingCount: Int { lock.withLock { pending.count } }
    var retainedCount: Int { lock.withLock { runs.count } }
#endif
}

/// App-owned composition. Settings replace only the future-run gateway, keeping
/// one F03 authority and terminalizing old model-bound runs before storage I/O.
@MainActor package final class RunComposition {
    package let authority: RunAuthorizationController
    package let workbench: WorkbenchModel
    package private(set) var model: HostModelGateway
    package let mcp: HostMCPGateway
    package let connectionSettings: ConnectionSettingsController
    package private(set) var isClosing = false
    package var isClosed: Bool { workbench.isClosed }
    private let audit: WorkbenchAuditSink
    private let ownership: CompositionRunOwnership
    private var configurationGeneration = UUID()
    private var modelConnectionIDs: Set<UUID>
    private var businessStorage: BusinessTaskController?
    private var fixtureTaskDirectory: URL?
    package private(set) var isLocalFixture = false
    package var businessRouteAvailable: Bool {
#if SANDBOX_TEST_FIXTURES
        if isLocalFixture { return true }
#endif
        return BusinessModelActivation.credentialEgressEnabled
    }
    package var businessTaskDirectory: URL {
        fixtureTaskDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MiniSandbox/Tasks", isDirectory: true)
    }
    package var business: BusinessTaskController {
        if let businessStorage { return businessStorage }
        let controller = BusinessTaskController(composition: self)
        businessStorage = controller
        return controller
    }

    package enum InstallationPhase: String, CaseIterable, Sendable {
        case beforeAuthority, afterAuthority, beforeModel, afterModel
        case beforeMCP, afterMCP, beforeWorkbench, afterWorkbench
    }
#if DEBUG
    /// Deterministic scheduling seam only; never supplies authority or output.
    package var installationBarrier: ((InstallationPhase) async -> Void)?
    package var pendingOwnedWork: Int { ownership.pendingCount }
    package var retainedOwnedRuns: Int { ownership.retainedCount }
#endif
    private func checkpoint(_ phase: InstallationPhase, generation: UUID, handle: HostRunHandle? = nil) async throws {
#if DEBUG
        if let installationBarrier { await installationBarrier(phase) }
#endif
        guard generation == configurationGeneration, !isClosing, !connectionSettings.isClosed,
              !connectionSettings.isBusy else { throw HostModelGatewayError.revoked }
        if let handle { try validateInstallation(generation, handle) }
    }

    package struct InstalledRun: Sendable {
        package let grant: RunGrant
        package let authorityHandle: HostRunHandle
        package let modelHandle: HostModelRunHandle
        package let modelGateway: HostModelGateway
        package let mcpHandle: HostMCPRunHandle
    }

    package init(audit: WorkbenchAuditSink, modelConnections: [HostModelConnection] = [],
                 credentialStore: (any FixedModelCredentialStore)? = nil,
                 mcpConnections: [HostMCPConnection] = [],
                 clock: RunClock = .system()) throws {
        self.audit = audit
        modelConnectionIDs = Set(modelConnections.map(\.connectionID))
        connectionSettings = ConnectionSettingsController(store: credentialStore ?? KeychainFixedModelStore())
        let authority = RunAuthorizationController(auditSink: audit, clock: clock)
        self.authority = authority
        let ownership = CompositionRunOwnership(authority: authority)
        self.ownership = ownership
        workbench = WorkbenchModel(audit: audit, authority: authority)
        model = try HostModelGateway(connections: modelConnections, auditSink: audit, authority: authority, owner: ownership)
        mcp = try HostMCPGateway(connections: mcpConnections, auditSink: audit, authority: authority, owner: ownership)
        workbench.attachmentOwner = ownership
        workbench.willClose = { [weak self] in self?.beginClose() }
        connectionSettings.willClose = { [weak self] in self?.beginClose() }
        workbench.closeOwnedRuns = { [weak self, ownership, authority] in
            await self?.businessStorage?.waitForCleanup()
            await ownership.drainAttachments()
            var succeeded = true
            for handle in ownership.handles {
                do { try await authority.stop(handle: handle) } catch { succeeded = false }
            }
            return succeeded && ownership.cleanupSucceeded
        }
        connectionSettings.invalidate = { [weak self] in
            guard let self else { throw HostModelGatewayError.revoked }
            return try self.retireModelConfiguration()
        }
        connectionSettings.publish = { [weak self] configuration, provider in
            guard let self, !self.isClosing, !self.connectionSettings.isClosed else { throw HostModelGatewayError.revoked }
            self.model = try HostModelGateway(connections: [configuration.connection(provider: provider)],
                auditSink: audit, authority: authority, owner: self.ownership)
            self.modelConnectionIDs = [configuration.connectionID]
        }
    }

    package func install(_ grant: RunGrant) async throws -> InstalledRun {
        guard !isClosing, !connectionSettings.isBusy, !connectionSettings.isClosed, !workbench.isClosing else { throw HostModelGatewayError.revoked }
        let generation = configurationGeneration, model = model
        let registration = try ownership.beginAttachment(grant: grant, existing: nil)
        defer { ownership.endAttachment(registration) }
        try await checkpoint(.beforeAuthority, generation: generation)
        let handle = try await authority.install(grant: grant)
        do {
            try ownership.registerAttachment(registration, grant: grant, handle: handle)
            try await checkpoint(.afterAuthority, generation: generation, handle: handle)
            try await checkpoint(.beforeModel, generation: generation, handle: handle)
            let modelHandle = try await model.install(grant: grant, authorityHandle: handle)
            try await checkpoint(.afterModel, generation: generation, handle: handle)
            try await checkpoint(.beforeMCP, generation: generation, handle: handle)
            let mcpHandle = try await mcp.install(grant: grant, authorityHandle: handle)
            try await checkpoint(.afterMCP, generation: generation, handle: handle)
            try await checkpoint(.beforeWorkbench, generation: generation, handle: handle)
            try await workbench.installTrustedGrant(grant, authorityHandle: handle)
            try await checkpoint(.afterWorkbench, generation: generation, handle: handle)
            return InstalledRun(grant: grant, authorityHandle: handle, modelHandle: modelHandle, modelGateway: model, mcpHandle: mcpHandle)
        } catch {
            handle.lifecycle.terminate(.faulted)
            try? await authority.stop(handle: handle)
            throw error
        }
    }

    private func validateInstallation(_ generation: UUID, _ handle: HostRunHandle) throws {
        guard generation == configurationGeneration, !isClosing, !connectionSettings.isBusy, !connectionSettings.isClosed,
              !workbench.isClosing, handle.lifecycle.currentStatus == .active else { throw HostModelGatewayError.revoked }
    }

    /// Retain the concrete VM/workspace owner until its asynchronous cleanup
    /// settles; native close cannot finish merely because F03 was revoked.
    package func beginBusinessOwnership(_ run: InstalledRun) throws -> UUID {
        try validateInstallation(configurationGeneration, run.authorityHandle)
        let token = try ownership.beginAttachment(grant: run.grant, existing: run.authorityHandle)
        do {
            try ownership.registerAttachment(token, grant: run.grant, handle: run.authorityHandle)
            return token
        } catch { ownership.endAttachment(token); throw error }
    }
    package func finishBusinessOwnership(_ token: UUID, succeeded: Bool) {
        if !succeeded { ownership.attachmentCleanupFailed(token) }
        ownership.endAttachment(token)
    }

    /// Native termination must call this synchronously, before creating a Task.
    package func beginClose() {
        guard !isClosing else { return }
        isClosing = true
        configurationGeneration = UUID()
        ownership.seal()
        businessStorage?.beginClose()
        connectionSettings.close()
        workbench.beginClose()
    }
    package func close() async -> Bool {
        beginClose()
        await businessStorage?.waitForCleanup()
        return await workbench.close()
    }

    /// No update-after-revoke, no mutation of old transport/account bindings.
    private func retireModelConfiguration() throws -> ModelConfigurationRetirement {
        let retired = ModelConfigurationRetirement(gateway: model, connectionIDs: modelConnectionIDs)
        configurationGeneration = UUID()
        ownership.retire(modelConnectionIDs)
        businessStorage?.retireModelConnections(modelConnectionIDs)
        workbench.retireModelConnections(modelConnectionIDs)
        modelConnectionIDs = []
        if !isClosing {
            model = try HostModelGateway(connections: [], auditSink: audit, authority: authority, owner: ownership)
        }
        return retired
    }

    /// Session hook only; this does not launch a VM or provide a guest data plane.
    package func diagnosticSession(owner: AnyObject, run: InstalledRun) throws -> VMDiagnosticSession {
        // Authenticate before observing or retaining the lifecycle. Equal run IDs
        // and grant metadata do not establish ownership by this composition.
        _ = try authority.installedGrantForOwnership(of: run.authorityHandle)
        guard !isClosing, run.authorityHandle.lifecycle.currentStatus == .active else { throw AuthorizationError.runRevoked }
        return try VMDiagnosticSession(owner: owner, runID: run.grant.runID, epoch: run.grant.epoch,
            workloadDigest: run.grant.workloadImageDigest, sink: audit,
            authorityHandle: run.authorityHandle, installedGrant: run.grant)
    }

    package static func application() throws -> RunComposition {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MiniSandbox/Audit", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        return try RunComposition(audit: WorkbenchAuditSink(newFileAt: directory.appendingPathComponent("\(UUID()).jsonl")))
    }
#if SANDBOX_TEST_FIXTURES
    package static func localBusinessFixture(port: UInt16, newRoot: URL) throws -> RunComposition {
        let connection = try HostModelConnection.localClaudeFixture(port: port)
        guard newRoot.path.hasPrefix("/"), mkdir(newRoot.path, 0o700) == 0 else { throw BusinessTaskFailure.unavailable }
        let audit = try WorkbenchAuditSink(newFileAt: newRoot.appendingPathComponent("audit.jsonl"))
        let composition = try RunComposition(audit: audit, modelConnections: [connection], credentialStore: LocalBusinessNoCredentialStore())
        composition.isLocalFixture = true
        composition.fixtureTaskDirectory = newRoot.appendingPathComponent("Tasks", isDirectory: true)
        try composition.connectionSettings.installLocalFixture(FixedModelConnectionConfiguration(connectionID: connection.connectionID,
            accountID: connection.accountID, accountBindingVersion: 1, routeVersion: 1))
        return composition
    }
#endif
}
