import Foundation
import SandboxContracts

/// Immutable quota metadata authenticated against F03's installed handle. NOT an
/// execution, file-access, connection or export permit. No clock/lifecycle copy.
/// ResourceLimits are conservative upper ceilings for this measured subdomain,
/// not a claim that the VM's entire memory/disk allocation is free host capacity.
final class WorkspaceGrantQuota: @unchecked Sendable {
    let handle: HostRunHandle
    let snapshotID: UUID
    let notBefore: Date
    let memory: WorkspaceTransferBudget
    let disk: WorkspaceTransferBudget
    let byteCeiling: Int
    let messageBytes: Int
    let memoryCeiling: Int
    let diskCeiling: Int
    private let taskLock = NSLock()
    private var taskValue: TaskQuotaLedger?
    private var transferStarted = false
    private var workspaceBindingValue: WorkspaceRunBinding?
    var workspaceBinding: WorkspaceRunBinding? { taskLock.withLock { workspaceBindingValue } }

    func bindWorkspace(storeOwner: UUID, snapshot: WorkspaceSnapshotID, workflow: WorkspaceWorkflowBinding) throws {
        try taskLock.withLock {
            guard snapshot.grantSnapshotID == snapshotID else { throw WorkspaceError.foreignSnapshot }
            if let existing = workspaceBindingValue {
                guard existing.storeOwner == storeOwner, existing.snapshot == snapshot,
                      existing.workflowOwner == workflow.owner, existing.workflowGeneration == workflow.generation else { throw WorkspaceError.foreignSnapshot }
                return
            }
            workspaceBindingValue = WorkspaceRunBinding(handle: handle, notBefore: notBefore, snapshot: snapshot, storeOwner: storeOwner, workflow: workflow)
        }
    }
    var task: TaskQuotaLedger? { taskLock.withLock { taskValue } }

    func createTask(storeOwner: UUID, limits: WorkspaceTaskLimits, store: WorkspaceLimits,
                    workflow: WorkspaceWorkflowBinding) throws -> TaskQuotaLedger {
        try taskLock.withLock {
            if let taskValue {
                guard taskValue.storeOwner == storeOwner, taskValue.hostLimits == limits else { throw WorkspaceTransferError.rejected }
                try taskValue.workflow.validate()
                return taskValue
            }
            // Installing limits after ingress would erase prior cumulative input.
            guard !transferStarted else { throw WorkspaceTransferError.rejected }
            let value = try TaskQuotaLedger(storeOwner: storeOwner, snapshotID: snapshotID, limits: limits,
                                            store: store, quota: self, workflow: workflow)
            taskValue = value
            return value
        }
    }
    func beginTransfer() throws {
        try taskLock.withLock {
            try taskValue?.claimTransfer()
            transferStarted = true
        }
    }

    private init(handle: HostRunHandle, grant: RunGrant) {
        self.handle = handle
        snapshotID = grant.workspaceSnapshotID
        notBefore = grant.createdAt
        // Clamp in UInt64 BEFORE conversion; UInt64.max must never trap/wrap.
        let memoryBytes = Int(min(UInt64(128 * 1024 * 1024), grant.resourceLimits.memoryBytes))
        let diskBytes = Int(min(UInt64(128 * 1024 * 1024), grant.resourceLimits.diskBytes))
        memoryCeiling = memoryBytes; diskCeiling = diskBytes
        memory = WorkspaceTransferBudget(capacity: memoryBytes)
        disk = WorkspaceTransferBudget(capacity: diskBytes)
        byteCeiling = min(memoryBytes, diskBytes)
        messageBytes = min(16384, grant.resourceLimits.messageBytes)
    }

    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        // Strong retention deliberately preserves orphan charges and handle
        // identity. No eviction/reset API; bounded fail-closed fixture lifetime.
        var runs: [ObjectIdentifier: WorkspaceGrantQuota] = [:]
    }
    private static let registry = Registry()

    static func authenticated(authority: RunAuthorizationController,
                              handle: HostRunHandle, grant: RunGrant) async throws -> WorkspaceGrantQuota {
        try await authority.validateAttachment(handle: handle, grant: grant)
        return try installed(handle: handle, grant: grant)
    }

    /// Host-only synchronous attachment for a store whose exclusive ownership is
    /// transferred into WorkspaceRunSession. Provenance is immutable; all future
    /// effects still sample the existing lifecycle at their actual commit.
    static func authenticatedForSession(authority: RunAuthorizationController,
                                        handle: HostRunHandle, grant: RunGrant) throws -> WorkspaceGrantQuota {
        guard try authority.installedGrantForOwnership(of: handle) == grant else { throw AuthorizationError.grantBindingMismatch }
        let observation = handle.lifecycle.observeAndReduce(reason: "workspace-session-install")
        guard observation.status == .active, observation.generation == grant.epoch else { throw AuthorizationError.runRevoked }
        guard observation.wallTime >= grant.createdAt else { throw AuthorizationError.grantNotYetValid }
        return try installed(handle: handle, grant: grant)
    }
    private static func installed(handle: HostRunHandle, grant: RunGrant) throws -> WorkspaceGrantQuota {
        return try registry.lock.withLock {
            let key = ObjectIdentifier(handle)
            if let existing = registry.runs[key] { return existing }
            guard registry.runs.count < 256 else { throw WorkspaceTransferError.rejected }
            let value = WorkspaceGrantQuota(handle: handle, grant: grant)
            registry.runs[key] = value
            return value
        }
    }

    func limits(store: WorkspaceLimits, channel: WorkspaceLimits = WorkspaceLimits()) -> WorkspaceLimits {
        var value = WorkspaceTransferWire.effectiveLimits(store)
        value.entries = min(value.entries, channel.entries)
        value.fileBytes = min(value.fileBytes, channel.fileBytes, byteCeiling)
        value.totalBytes = min(value.totalBytes, channel.totalBytes, byteCeiling)
        value.depth = min(value.depth, channel.depth)
        value.pathBytes = min(value.pathBytes, channel.pathBytes)
        if let task { value = task.intersect(value) }
        return value
    }
}

/// NEW host task policy. These fields were never present in RunGrant. They are
/// chosen only at WorkspaceStore task creation, not decoded from guest frames.
package struct WorkspaceTaskLimits: Equatable, Sendable {
    package let retainedPayloadBytes: UInt64
    package let diskBytes: UInt64
    package let cumulativeInputBytes: UInt64
    package var fileBytes: UInt64 = 4 * 1024 * 1024
    package var entries: UInt64 = 1000
    package var depth: UInt64 = 15
    package var pathBytes: UInt64 = 1024
    package var messageBytes: UInt64 = 16384
    package var transferInstances: UInt64 = 64
    package var materializations: UInt64 = 64
    package init(retainedPayloadBytes: UInt64, diskBytes: UInt64, cumulativeInputBytes: UInt64,
                 fileBytes: UInt64 = 4 * 1024 * 1024, entries: UInt64 = 1000, depth: UInt64 = 15,
                 pathBytes: UInt64 = 1024, messageBytes: UInt64 = 16384,
                 transferInstances: UInt64 = 64, materializations: UInt64 = 64) {
        self.retainedPayloadBytes = retainedPayloadBytes; self.diskBytes = diskBytes
        self.cumulativeInputBytes = cumulativeInputBytes; self.fileBytes = fileBytes
        self.entries = entries; self.depth = depth; self.pathBytes = pathBytes
        self.messageBytes = messageBytes; self.transferInstances = transferInstances
        self.materializations = materializations
    }

}

/// One task domain retained by the authenticated run's bounded registry. It
/// spans every file/channel/reconnect/transfer instance of this workspace task.
/// No eviction: committed/orphaned bytes require actual settlement proof before
/// any future retirement API may release them. No clock or run authorization.
final class TaskQuotaLedger: @unchecked Sendable {
    let storeOwner: UUID
    let snapshotID: UUID
    let hostLimits: WorkspaceTaskLimits
    let workflow: WorkspaceWorkflowBinding
    let memory: WorkspaceTransferBudget
    let disk: WorkspaceTransferBudget
    let messageBytes: Int
    private let treeLimits: WorkspaceLimits
    private let attemptLock = NSLock()
    private var transfers = 0, writes = 0
    fileprivate init(storeOwner: UUID, snapshotID: UUID, limits: WorkspaceTaskLimits,
                     store: WorkspaceLimits, quota: WorkspaceGrantQuota,
                     workflow: WorkspaceWorkflowBinding) throws {
        guard limits.retainedPayloadBytes > 0, limits.diskBytes > 0, limits.cumulativeInputBytes > 0,
              limits.fileBytes > 0, limits.entries > 0, limits.depth > 0,
              limits.pathBytes > 0, limits.messageBytes > 0, limits.transferInstances > 0,
              limits.materializations > 0 else { throw WorkspaceTransferError.rejected }
        try workflow.validate()
        self.storeOwner = storeOwner; self.snapshotID = snapshotID
        hostLimits = limits; self.workflow = workflow
        func bound(_ value: UInt64, _ cap: Int) -> Int { Int(min(value, UInt64(cap))) }
        let payload = bound(limits.retainedPayloadBytes, min(store.totalBytes, quota.memoryCeiling, 128 * 1024 * 1024))
        let diskBytes = bound(limits.diskBytes, min(store.totalBytes, quota.diskCeiling, 128 * 1024 * 1024))
        memory = WorkspaceTransferBudget(capacity: payload, cumulativeLimit: bound(limits.cumulativeInputBytes, 128 * 1024 * 1024))
        disk = WorkspaceTransferBudget(capacity: diskBytes, retainCommitted: true)
        messageBytes = bound(limits.messageBytes, quota.messageBytes)
        var tree = WorkspaceTransferWire.effectiveLimits(store)
        tree.totalBytes = min(tree.totalBytes, payload, diskBytes)
        tree.fileBytes = bound(limits.fileBytes, min(tree.fileBytes, tree.totalBytes))
        tree.entries = bound(limits.entries, tree.entries)
        tree.depth = bound(limits.depth, tree.depth)
        tree.pathBytes = bound(limits.pathBytes, tree.pathBytes)
        treeLimits = tree
    }
    func cancel() { workflow.cancel() }
    func claimTransfer() throws {
        try workflow.validate()
        try attemptLock.withLock {
            guard transfers < Int(min(hostLimits.transferInstances, 64)) else { throw WorkspaceTransferError.rejected }
            transfers += 1
        }
    }
    func claimMaterialization() throws {
        // Includes independent postStop exports. Attempts are never refunded:
        // zero-byte trees still allocate filesystem metadata and flow objects.
        try attemptLock.withLock {
            guard writes < Int(min(hostLimits.materializations, 64)) else { throw WorkspaceTransferError.rejected }
            writes += 1
        }
    }
    func intersect(_ other: WorkspaceLimits) -> WorkspaceLimits {
        var value = other
        value.totalBytes = min(value.totalBytes, treeLimits.totalBytes)
        value.fileBytes = min(value.fileBytes, treeLimits.fileBytes)
        value.entries = min(value.entries, treeLimits.entries)
        value.depth = min(value.depth, treeLimits.depth)
        value.pathBytes = min(value.pathBytes, treeLimits.pathBytes)
        return value
    }
}
